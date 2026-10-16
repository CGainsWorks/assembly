/*
 * Internal declarations shared by the dispatch layer, the tests and the
 * benchmarks. Not installed and not part of the public ABI.
 */
#ifndef HOTPATH_INTERNAL_H
#define HOTPATH_INTERNAL_H

#include "hotpath.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Raw CPUID access, implemented in src/asm/cpuid.S. */
void     hp_asm_cpuid(uint32_t leaf, uint32_t subleaf, uint32_t out[4]);
uint64_t hp_asm_xgetbv0(void);

/* Portable C reference implementations, under src/ref. */
uint32_t    hp_crc32c_ref(uint32_t crc, const void *buf, size_t len);
size_t      hp_count_byte_ref(const void *buf, size_t len, uint8_t needle);
const void *hp_find_byte_ref(const void *buf, size_t len, uint8_t needle);
int         hp_is_ascii_ref(const void *buf, size_t len);
void        hp_hex_encode_ref(char *dst, const void *src, size_t len);

/*
 * Bit at a time CRC-32C. Deliberately slow and obviously correct, used by the
 * tests as a third independent opinion so a bad table cannot pass unnoticed.
 */
uint32_t hp_crc32c_bitwise(uint32_t crc, const void *buf, size_t len);

/* Assembly implementations, under src/asm. */
uint32_t    hp_crc32c_sse42(uint32_t crc, const void *buf, size_t len);
size_t      hp_count_byte_avx2(const void *buf, size_t len, uint8_t needle);
const void *hp_find_byte_avx2(const void *buf, size_t len, uint8_t needle);
int         hp_is_ascii_avx2(const void *buf, size_t len);
void        hp_hex_encode_ssse3(char *dst, const void *src, size_t len);
size_t      hp_count_byte_avx512(const void *buf, size_t len, uint8_t needle);
const void *hp_find_byte_avx512(const void *buf, size_t len, uint8_t needle);
int         hp_is_ascii_avx512(const void *buf, size_t len);

/* One row of the dispatch table, one row per tier. */
typedef struct {
    uint32_t    (*crc32c)(uint32_t, const void *, size_t);
    size_t      (*count_byte)(const void *, size_t, uint8_t);
    const void *(*find_byte)(const void *, size_t, uint8_t);
    int         (*is_ascii)(const void *, size_t);
    void        (*hex_encode)(char *, const void *, size_t);
} hp_impl_table;

/* The table for a tier, or NULL if the tier index is out of range. */
const hp_impl_table *hp_table_for(hp_backend_t backend);

#ifdef __cplusplus
}
#endif

#endif /* HOTPATH_INTERNAL_H */
