/*
 * Feature detection and run time dispatch.
 *
 * Every public entry point is a thin wrapper over a function pointer. The
 * pointers are filled once from CPUID, which means one binary runs correctly
 * on a machine without AVX2 and still reaches full speed on one with it. The
 * alternative, building separate binaries per microarchitecture, pushes the
 * problem onto whoever deploys the software.
 *
 * The environment variable HOTPATH_BACKEND overrides the choice at start up
 * with one of "baseline", "sse42" or "avx2". CI uses it to run the whole test
 * suite against every tier the runner can execute, so the scalar paths are
 * covered even on a host that has AVX2.
 */
#include <stdlib.h>
#include <string.h>

#include "internal.h"

/* ---------------------------------------------------------------- CPUID -- */

static hp_cpu_info g_cpu;
static hp_backend_t g_backend = HP_BACKEND_BASELINE;
static const hp_impl_table *g_active;
static int g_cpu_detected;
static int g_initialised;

static void detect_cpu(hp_cpu_info *info)
{
    uint32_t regs[4];
    uint32_t max_leaf;
    uint32_t max_ext;

    memset(info, 0, sizeof(*info));

    hp_asm_cpuid(0, 0, regs);
    max_leaf = regs[0];

    if (max_leaf >= 1) {
        hp_asm_cpuid(1, 0, regs);
        info->sse2    = (regs[3] >> 26) & 1;   /* edx bit 26 */
        info->pclmul  = (regs[2] >>  1) & 1;   /* ecx bit 1  */
        info->ssse3   = (regs[2] >>  9) & 1;   /* ecx bit 9  */
        info->sse42   = (regs[2] >> 20) & 1;   /* ecx bit 20 */
        info->osxsave = (regs[2] >> 27) & 1;   /* ecx bit 27 */
        info->avx     = (regs[2] >> 28) & 1;   /* ecx bit 28 */
    }

    if (max_leaf >= 7) {
        hp_asm_cpuid(7, 0, regs);
        info->avx2 = (regs[1] >> 5) & 1;       /* ebx bit 5 */
        info->bmi2 = (regs[1] >> 8) & 1;       /* ebx bit 8 */
    }

    /*
     * A CPU can report AVX2 while the operating system declines to preserve
     * YMM state across a context switch. Using 256 bit registers in that
     * situation silently corrupts them, so XCR0 has to agree before the AVX2
     * tier is allowed. XGETBV itself faults unless OSXSAVE is set, hence the
     * guard.
     */
    if (info->osxsave) {
        uint64_t xcr0 = hp_asm_xgetbv0();
        info->ymm_enabled = ((xcr0 & 0x6) == 0x6);  /* XMM and YMM state */
    }

    hp_asm_cpuid(0x80000000U, 0, regs);
    max_ext = regs[0];
    if (max_ext >= 0x80000004U) {
        uint32_t leaf;
        char *out = info->brand;
        for (leaf = 0x80000002U; leaf <= 0x80000004U; leaf++) {
            hp_asm_cpuid(leaf, 0, regs);
            memcpy(out, regs, 16);
            out += 16;
        }
        info->brand[48] = '\0';
    }
}

/* ------------------------------------------------------- dispatch tables -- */

static const hp_impl_table g_tables[HP_BACKEND_COUNT] = {
    /* HP_BACKEND_BASELINE: portable C everywhere. */
    {
        hp_crc32c_ref,
        hp_count_byte_ref,
        hp_find_byte_ref,
        hp_is_ascii_ref,
        hp_hex_encode_ref
    },
    /*
     * HP_BACKEND_SSE42: the CRC32 instruction and the pshufb hex encoder. The
     * counting and scanning kernels stay on C here because a useful 128 bit
     * version of them would add a second set of kernels to test for a fraction
     * of the AVX2 gain.
     */
    {
        hp_crc32c_sse42,
        hp_count_byte_ref,
        hp_find_byte_ref,
        hp_is_ascii_ref,
        hp_hex_encode_ssse3
    },
    /* HP_BACKEND_AVX2: everything vectorised. */
    {
        hp_crc32c_sse42,
        hp_count_byte_avx2,
        hp_find_byte_avx2,
        hp_is_ascii_avx2,
        hp_hex_encode_ssse3
    }
};

const hp_impl_table *hp_table_for(hp_backend_t backend)
{
    if ((int)backend < 0 || (int)backend >= HP_BACKEND_COUNT) {
        return NULL;
    }
    return &g_tables[backend];
}

int hp_backend_supported(hp_backend_t backend)
{
    const hp_cpu_info *cpu = hp_cpu();

    switch (backend) {
    case HP_BACKEND_BASELINE:
        return 1;
    case HP_BACKEND_SSE42:
        return cpu->sse42 && cpu->ssse3;
    case HP_BACKEND_AVX2:
        return cpu->sse42 && cpu->ssse3 && cpu->avx2 && cpu->ymm_enabled;
    default:
        return 0;
    }
}

hp_backend_t hp_best_backend(void)
{
    if (hp_backend_supported(HP_BACKEND_AVX2)) {
        return HP_BACKEND_AVX2;
    }
    if (hp_backend_supported(HP_BACKEND_SSE42)) {
        return HP_BACKEND_SSE42;
    }
    return HP_BACKEND_BASELINE;
}

const char *hp_backend_name(hp_backend_t backend)
{
    switch (backend) {
    case HP_BACKEND_BASELINE: return "baseline";
    case HP_BACKEND_SSE42:    return "sse42";
    case HP_BACKEND_AVX2:     return "avx2";
    default:                  return "unknown";
    }
}

static int backend_from_name(const char *name, hp_backend_t *out)
{
    int i;
    for (i = 0; i < HP_BACKEND_COUNT; i++) {
        if (strcmp(name, hp_backend_name((hp_backend_t)i)) == 0) {
            *out = (hp_backend_t)i;
            return 0;
        }
    }
    return -1;
}

static void hp_init(void)
{
    const char *forced;

    (void)hp_cpu();
    g_backend = hp_best_backend();

    forced = getenv("HOTPATH_BACKEND");
    if (forced != NULL && *forced != '\0') {
        hp_backend_t want;
        /*
         * An unusable or misspelled request is ignored rather than fatal. A
         * library has no business aborting somebody else's process over an
         * environment variable, and the chosen tier is reportable through
         * hp_backend() if the caller cares.
         */
        if (backend_from_name(forced, &want) == 0 && hp_backend_supported(want)) {
            g_backend = want;
        }
    }

    g_active = &g_tables[g_backend];
    g_initialised = 1;
}

#if defined(__GNUC__)
__attribute__((constructor))
static void hp_init_ctor(void)
{
    hp_init();
}
#endif

static inline const hp_impl_table *active(void)
{
    /*
     * The constructor above normally runs first. This fallback covers a
     * toolchain without constructor support and any caller that reaches the
     * library from another constructor before ours has run. Two threads racing
     * here would each compute the same table from the same CPUID, so the race
     * is benign.
     */
    if (!g_initialised) {
        hp_init();
    }
    return g_active;
}

const hp_cpu_info *hp_cpu(void)
{
    /*
     * Kept separate from the dispatch flag so that hp_init can ask for the
     * feature bits while it is still deciding which tier to install.
     */
    if (!g_cpu_detected) {
        detect_cpu(&g_cpu);
        g_cpu_detected = 1;
    }
    return &g_cpu;
}

hp_backend_t hp_backend(void)
{
    (void)active();
    return g_backend;
}

int hp_set_backend(hp_backend_t backend)
{
    (void)active();
    if (!hp_backend_supported(backend)) {
        return -1;
    }
    g_backend = backend;
    g_active = &g_tables[backend];
    return 0;
}

/* ------------------------------------------------------- public wrappers -- */

uint32_t hp_crc32c(uint32_t crc, const void *buf, size_t len)
{
    return active()->crc32c(crc, buf, len);
}

size_t hp_count_byte(const void *buf, size_t len, uint8_t needle)
{
    return active()->count_byte(buf, len, needle);
}

const void *hp_find_byte(const void *buf, size_t len, uint8_t needle)
{
    return active()->find_byte(buf, len, needle);
}

int hp_is_ascii(const void *buf, size_t len)
{
    return active()->is_ascii(buf, len);
}

void hp_hex_encode(char *dst, const void *src, size_t len)
{
    active()->hex_encode(dst, src, len);
}
