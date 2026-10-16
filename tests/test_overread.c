/*
 * Guard page tests: proof that no kernel touches a byte outside its buffer.
 *
 * A SIMD kernel that finishes its tail with an overlapping or masked vector
 * load is faster and, on almost every input, indistinguishable from a correct
 * one. It only misbehaves when the buffer ends within a few bytes of an
 * unmapped page, which in production means a rare crash in a library that
 * passed every functional test. Reviewers are right to be suspicious of hand
 * written assembly on exactly this point, so the promise is tested rather than
 * asserted.
 *
 * The method is to map two pages, revoke all access to the second, and place
 * the buffer so its last byte is the last byte of the first page. Any read
 * beyond the buffer lands on the guard page and faults. Every length from zero
 * to a full page is tried, so every possible tail configuration is covered.
 * That includes the AVX-512 tier, whose tails are masked loads: the
 * architecture promises that masked out bytes never fault, and this is where
 * that promise is checked.
 *
 * The same is done for the destination of the hex encoder, which proves it
 * writes exactly two bytes per input byte and not one byte more.
 *
 * Before any of that, the test deliberately reads the guard page and requires
 * a fault. Without that step a mapping that silently failed to take effect
 * would make the whole file pass while proving nothing.
 *
 * Two platform layers provide the same four operations. On Linux the guard is
 * mprotect and recovery is SIGSEGV plus siglongjmp. On Windows the guard is
 * VirtualProtect with PAGE_NOACCESS, and recovery is a vectored exception
 * handler that resumes at a context captured just before the kernel was called.
 */
#include <stdio.h>
#include <string.h>

#include "testutil.h"

/* Sinks, so that nothing here can be optimised away as unused. */
static volatile uint32_t sink_u32;
static volatile size_t sink_size;
static volatile int sink_int;
static const void *volatile sink_ptr;

static void run_kernel(int which, const unsigned char *buf, size_t len,
                       char *hex_dst)
{
    switch (which) {
    case 0: sink_u32  = hp_crc32c(0, buf, len);            break;
    case 1: sink_size = hp_count_byte(buf, len, 0x5A);     break;
    case 2: sink_ptr  = hp_find_byte(buf, len, 0x00);      break;
    case 3: sink_int  = hp_is_ascii(buf, len);             break;
    case 4: hp_hex_encode(hex_dst, buf, len);              break;
    default: break;
    }
}

/* ------------------------------------------------------------- Windows -- */
#if defined(_WIN32)

#define HP_GUARD_SUPPORTED 1

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

static CONTEXT g_resume;
static volatile LONG g_armed;
static volatile LONG g_faulted;

/*
 * Only an access violation raised while a guarded call is in flight is
 * handled. Anything else, or a fault outside a guarded call, is left to the
 * normal handlers so a genuine crash still looks like one.
 */
static LONG CALLBACK guard_handler(PEXCEPTION_POINTERS info)
{
    if (g_armed &&
        info->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        g_armed = 0;
        g_faulted = 1;
        *info->ContextRecord = g_resume;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static size_t page_size(void)
{
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (size_t)si.dwPageSize;
}

static void install_handler(void)
{
    if (AddVectoredExceptionHandler(1, guard_handler) == NULL) {
        fprintf(stderr, "AddVectoredExceptionHandler failed\n");
        exit(1);
    }
}

static unsigned char *make_guarded_region(size_t page)
{
    DWORD old;
    unsigned char *base = VirtualAlloc(NULL, page * 2, MEM_RESERVE | MEM_COMMIT,
                                       PAGE_READWRITE);
    if (base == NULL) {
        fprintf(stderr, "VirtualAlloc failed\n");
        exit(1);
    }
    if (!VirtualProtect(base + page, page, PAGE_NOACCESS, &old)) {
        fprintf(stderr, "VirtualProtect failed\n");
        exit(1);
    }
    memset(base, 0x5A, page);
    return base;
}

/*
 * RtlCaptureContext returns a second time when the handler resumes from the
 * captured context, and g_faulted, being volatile, is read fresh both times.
 * Nothing that is live across the capture is modified before the kernel call,
 * so resuming leaves this frame exactly as it was.
 */
static int run_guarded(int which, const unsigned char *buf, size_t len,
                       char *hex_dst)
{
    g_faulted = 0;
    RtlCaptureContext(&g_resume);
    if (g_faulted) {
        return -1;
    }
    g_armed = 1;
    run_kernel(which, buf, len, hex_dst);
    g_armed = 0;
    return 0;
}

static int address_faults(const unsigned char *addr)
{
    volatile unsigned char probe;

    g_faulted = 0;
    RtlCaptureContext(&g_resume);
    if (g_faulted) {
        return 1;
    }
    g_armed = 1;
    probe = *(const volatile unsigned char *)addr;
    (void)probe;
    g_armed = 0;
    return 0;
}

/* --------------------------------------------------------------- Linux -- */
#elif defined(__linux__)

#define HP_GUARD_SUPPORTED 1

#include <setjmp.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>

static sigjmp_buf g_jmp;

static void segv_handler(int sig)
{
    (void)sig;
    siglongjmp(g_jmp, 1);
}

static size_t page_size(void)
{
    return (size_t)sysconf(_SC_PAGESIZE);
}

static void install_handler(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = segv_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    if (sigaction(SIGSEGV, &sa, NULL) != 0 ||
        sigaction(SIGBUS, &sa, NULL) != 0) {
        perror("sigaction");
        exit(1);
    }
}

/*
 * Two pages, the second one unreadable. Returns the address of the first, so
 * that base + page is the first byte that must never be touched.
 */
static unsigned char *make_guarded_region(size_t page)
{
    unsigned char *base = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    if (mprotect(base + page, page, PROT_NONE) != 0) {
        perror("mprotect");
        exit(1);
    }
    memset(base, 0x5A, page);
    return base;
}

/*
 * Both helpers keep sigsetjmp in a frame of their own and hand back a value
 * rather than doing the checking in place. Two reasons. A local that is live
 * across sigsetjmp and modified afterwards is indeterminate once siglongjmp
 * unwinds, which is what -Wclobbered warns about and which the loop counters
 * in main would otherwise trip. And bookkeeping written inline around a
 * faulting load can be hoisted above that load by the optimiser, which records
 * a failure even when the fault being tested for did happen.
 */
static int run_guarded(int which, const unsigned char *buf, size_t len,
                       char *hex_dst)
{
    if (sigsetjmp(g_jmp, 1) != 0) {
        return -1;
    }
    run_kernel(which, buf, len, hex_dst);
    return 0;
}

/* 1 if reading the address faults, which is what a guard page has to do. */
static int address_faults(const unsigned char *addr)
{
    volatile unsigned char probe;

    if (sigsetjmp(g_jmp, 1) != 0) {
        return 1;
    }
    probe = *addr;
    (void)probe;
    return 0;
}

#endif

#if !defined(HP_GUARD_SUPPORTED)

int main(void)
{
    (void)run_kernel;
    printf("test_overread: skipped, no guard page support for this platform\n");
    return 0;
}

#else

static const char *kernel_name(int which)
{
    static const char *names[] = {
        "hp_crc32c", "hp_count_byte", "hp_find_byte", "hp_is_ascii",
        "hp_hex_encode"
    };
    return names[which];
}

int main(void)
{
    size_t page = page_size();
    unsigned char *src_region;
    unsigned char *dst_region;
    int backend;

    install_handler();
    hp_test_check_tier_list();

    src_region = make_guarded_region(page);
    dst_region = make_guarded_region(page);

    /* The guards have to bite, otherwise everything below is theatre. */
    {
        int src_armed = address_faults(src_region + page);
        int dst_armed = address_faults(dst_region + page);

        HP_CHECK(src_armed, "the source guard page was readable");
        HP_CHECK(dst_armed, "the destination guard page was readable");
        if (src_armed && dst_armed) {
            printf("guard pages are armed\n");
        }
    }

    for (backend = 0; backend < HP_BACKEND_COUNT; backend++) {
        size_t len;

        if (!hp_test_use_tier((hp_backend_t)backend)) {
            continue;
        }

        for (len = 0; len <= page; len++) {
            /* Buffer ends flush against the guard page. */
            const unsigned char *buf = src_region + page - len;
            int which;

            for (which = 0; which < 5; which++) {
                char *hex_dst = NULL;

                if (which == 4) {
                    /*
                     * The encoder writes two bytes per input byte, so only
                     * half a page of input fits with its output flush against
                     * the destination guard page.
                     */
                    if (len > page / 2) {
                        continue;
                    }
                    hex_dst = (char *)(dst_region + page - 2 * len);
                }

                if (run_guarded(which, buf, len, hex_dst) != 0) {
                    HP_CHECK(0, "%s stepped outside the buffer at len=%zu",
                             kernel_name(which), len);
                }
            }
        }
    }

    return hp_test_report("test_overread");
}

#endif /* HP_GUARD_SUPPORTED */
