/*
 * Calling convention tests.
 *
 * Every kernel is called through tests/abi_check.S, which fills each register
 * the platform convention says a callee must preserve with a canary and checks
 * it afterwards. On System V that is rbx, rbp and r12 to r15. On Windows x64 it
 * is those plus rdi, rsi and xmm6 to xmm15, which is exactly where a kernel
 * written for System V goes wrong, so the Windows CI job is where this test
 * earns its keep.
 *
 * The answer that comes back through the checker is also compared with a
 * direct call, which confirms the arguments arrived in the right registers.
 * That matters on Windows, where the shim in src/asm/hp_asm.h moves four
 * argument registers into their System V positions on every entry.
 */
#include <string.h>

#include "testutil.h"

typedef struct {
    void (*fn)(void);
    uint64_t args[4];
    uint64_t result;
    uint64_t clobbered;
} hp_abi_frame;

void hp_abi_call(hp_abi_frame *frame);

static const char *const reg_names[] = {
    "rbx", "rbp", "r12", "r13", "r14", "r15", "rdi", "rsi",
    "xmm6", "xmm7", "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13",
    "xmm14", "xmm15"
};

static void report_clobbers(const char *what, size_t len, uint64_t mask)
{
    size_t i;
    for (i = 0; i < sizeof(reg_names) / sizeof(reg_names[0]); i++) {
        if (mask & ((uint64_t)1 << i)) {
            HP_CHECK(0, "%s len=%zu clobbered callee saved %s", what, len,
                     reg_names[i]);
        }
    }
}

static uint64_t call4(void (*fn)(void), uint64_t a, uint64_t b, uint64_t c,
                      uint64_t d, const char *what, size_t len)
{
    hp_abi_frame frame;

    memset(&frame, 0, sizeof(frame));
    frame.fn = fn;
    frame.args[0] = a;
    frame.args[1] = b;
    frame.args[2] = c;
    frame.args[3] = d;
    hp_abi_call(&frame);
    report_clobbers(what, len, frame.clobbered);
    return frame.result;
}

#define MAX_LEN 30000

static unsigned char g_src[MAX_LEN];
static char g_hex_direct[2 * MAX_LEN];
static char g_hex_checked[2 * MAX_LEN];

static const size_t lengths[] = { 0, 1, 7, 31, 32, 63, 64, 100, 255, 256, 1000,
                                  4096, 24577, MAX_LEN };

static void check_table(const hp_impl_table *t)
{
    size_t i;

    for (i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        size_t len = lengths[i];
        uint64_t p = (uint64_t)(uintptr_t)g_src;
        uint64_t got;

        got = call4((void (*)(void))t->crc32c, 0x12345678U, p, len, 0,
                    "crc32c", len);
        HP_CHECK((uint32_t)got == t->crc32c(0x12345678U, g_src, len),
                 "crc32c len=%zu through the checker disagrees", len);

        got = call4((void (*)(void))t->count_byte, p, len, '\n', 0,
                    "count_byte", len);
        HP_CHECK((size_t)got == t->count_byte(g_src, len, '\n'),
                 "count_byte len=%zu through the checker disagrees", len);

        got = call4((void (*)(void))t->find_byte, p, len, 0x7F, 0,
                    "find_byte", len);
        HP_CHECK((const void *)(uintptr_t)got == t->find_byte(g_src, len, 0x7F),
                 "find_byte len=%zu through the checker disagrees", len);

        got = call4((void (*)(void))t->is_ascii, p, len, 0, 0,
                    "is_ascii", len);
        HP_CHECK((int)(uint32_t)got == t->is_ascii(g_src, len),
                 "is_ascii len=%zu through the checker disagrees", len);

        memset(g_hex_direct, 0, 2 * len);
        memset(g_hex_checked, 1, 2 * len);
        (void)call4((void (*)(void))t->hex_encode,
                    (uint64_t)(uintptr_t)g_hex_checked, p, len, 0,
                    "hex_encode", len);
        t->hex_encode(g_hex_direct, g_src, len);
        HP_CHECK(memcmp(g_hex_direct, g_hex_checked, 2 * len) == 0,
                 "hex_encode len=%zu through the checker disagrees", len);
    }
}

static void check_cpuid_helpers(void)
{
    uint32_t direct[4];
    uint32_t checked[4];

    /*
     * The checked call goes first throughout this file. A kernel that does
     * clobber a preserved register will corrupt whichever C function calls it
     * directly, and the report should be printed before that happens.
     */
    memset(checked, 0, sizeof(checked));
    (void)call4((void (*)(void))hp_asm_cpuid, 0, 0,
                (uint64_t)(uintptr_t)checked, 0, "hp_asm_cpuid", 0);
    hp_asm_cpuid(0, 0, direct);
    HP_CHECK(memcmp(direct, checked, sizeof(direct)) == 0,
             "hp_asm_cpuid through the checker disagrees");

    if (hp_cpu()->osxsave) {
        uint64_t got = call4((void (*)(void))hp_asm_xgetbv0, 0, 0, 0, 0,
                             "hp_asm_xgetbv0", 0);
        HP_CHECK(got == hp_asm_xgetbv0(),
                 "hp_asm_xgetbv0 through the checker disagrees");
    }
}

int main(void)
{
    hp_rng rng;
    int backend;
    size_t i;

    hp_rng_seed(&rng, 0xAB1C0DEULL);
    hp_rng_fill(&rng, g_src, sizeof(g_src));
    /* Some newlines to count, and one 0x7F near the end to find. */
    for (i = 0; i < sizeof(g_src); i += 61) {
        g_src[i] = '\n';
    }
    for (i = 0; i < sizeof(g_src); i++) {
        if (g_src[i] == 0x7F) {
            g_src[i] = 0x7E;
        }
    }
    g_src[sizeof(g_src) - 3] = 0x7F;

    hp_test_check_tier_list();
    check_cpuid_helpers();

    for (backend = 0; backend < HP_BACKEND_COUNT; backend++) {
        if (!hp_test_use_tier((hp_backend_t)backend)) {
            continue;
        }
        check_table(hp_table_for((hp_backend_t)backend));
    }

    return hp_test_report("test_abi");
}
