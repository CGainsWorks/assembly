/*
 * hotpath - hand-written x86-64 SIMD assembly kernels for ingestion hot paths.
 *
 * Every entry point below has a portable C reference implementation and one or
 * more assembly implementations. The implementation actually used is chosen at
 * run time from CPUID, so a binary built once runs everywhere x86-64 runs.
 *
 * Licence: MIT. See LICENSE.
 */
#ifndef HOTPATH_H
#define HOTPATH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HOTPATH_VERSION_MAJOR 0
#define HOTPATH_VERSION_MINOR 2
#define HOTPATH_VERSION_PATCH 0
#define HOTPATH_VERSION_STRING "0.2.0"

/*
 * Dispatch tiers, ordered by capability. A tier is selectable only if the host
 * CPU reports every feature the tier needs.
 *
 * HP_BACKEND_AVX512 is never chosen automatically. It has been verified for
 * correctness under Intel SDE but has not been timed on real AVX-512 hardware,
 * and on several Intel parts sustained 512 bit work lowers the clock, so it is
 * opt in through HOTPATH_BACKEND=avx512 or hp_set_backend().
 */
typedef enum {
    HP_BACKEND_BASELINE = 0, /* portable C, no SIMD, runs on any x86-64 */
    HP_BACKEND_SSE42    = 1, /* SSE4.2 CRC32 plus SSSE3 shuffles           */
    HP_BACKEND_AVX2     = 2, /* 256-bit integer SIMD                       */
    HP_BACKEND_AVX512   = 3  /* AVX-512 BW with masked tails, opt in       */
} hp_backend_t;

#define HP_BACKEND_COUNT 4

/* Decoded CPUID feature bits, filled once on first use. */
typedef struct {
    int sse2;
    int ssse3;
    int sse42;
    int pclmul;
    int avx;
    int avx2;
    int bmi2;
    int osxsave;
    int ymm_enabled; /* XCR0 says the OS saves and restores YMM state */
    char brand[49];  /* NUL terminated CPU brand string, may be empty  */
    /* Added in 0.2.0, after the fields above so their offsets are unchanged. */
    int popcnt;
    int avx512f;
    int avx512bw;
    int zmm_enabled; /* XCR0 says the OS saves opmask and all ZMM state */
} hp_cpu_info;

/* Feature detection and dispatch control. */
const hp_cpu_info *hp_cpu(void);
hp_backend_t       hp_backend(void);
hp_backend_t       hp_best_backend(void);
const char        *hp_backend_name(hp_backend_t backend);
int                hp_backend_supported(hp_backend_t backend);

/*
 * Force a tier. Returns 0 on success, -1 if the host CPU cannot run it.
 *
 * This rewrites a process wide dispatch table and is intended for tests and
 * benchmarks. It is not safe to call while another thread is inside a hotpath
 * entry point.
 */
int hp_set_backend(hp_backend_t backend);

/*
 * CRC-32C (Castagnoli, polynomial 0x1EDC6F41, reflected). Follows the zlib
 * calling convention: seed with 0 and feed successive chunks to accumulate.
 *   crc = hp_crc32c(0, a, na);
 *   crc = hp_crc32c(crc, b, nb);
 * The check value for the ASCII string "123456789" is 0xE3069283.
 */
uint32_t hp_crc32c(uint32_t crc, const void *buf, size_t len);

/* Number of bytes in buf equal to needle. Used for line counting. */
size_t hp_count_byte(const void *buf, size_t len, uint8_t needle);

/* First byte in buf equal to needle, or NULL. Same contract as memchr. */
const void *hp_find_byte(const void *buf, size_t len, uint8_t needle);

/* 1 if every byte of buf is 7-bit ASCII (below 0x80), 0 otherwise. */
int hp_is_ascii(const void *buf, size_t len);

/*
 * Lowercase hex encode. dst must have room for 2 * len bytes. No NUL is
 * written. dst and src must not overlap.
 */
void hp_hex_encode(char *dst, const void *src, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* HOTPATH_H */
