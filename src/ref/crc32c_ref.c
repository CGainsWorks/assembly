/*
 * Portable CRC-32C reference implementations.
 *
 * Two of them. The table driven one is the baseline the assembly kernel is
 * measured against, and is what most software uses when no CRC instruction is
 * available. The bit at a time one is deliberately slow and depends on nothing
 * but the polynomial, so the tests can use it as an independent opinion and
 * catch a corrupt table.
 */
#include "internal.h"
#include "crc32c_tables.h"

#define HP_CRC32C_POLY 0x82F63B78U

uint32_t hp_crc32c_ref(uint32_t crc, const void *buf, size_t len)
{
    const unsigned char *p = (const unsigned char *)buf;
    uint32_t c = ~crc;

    while (len--) {
        c = (c >> 8) ^ hp_crc32c_byte_table[(c ^ *p++) & 0xFF];
    }

    return ~c;
}

uint32_t hp_crc32c_bitwise(uint32_t crc, const void *buf, size_t len)
{
    const unsigned char *p = (const unsigned char *)buf;
    uint32_t c = ~crc;

    while (len--) {
        int bit;
        c ^= *p++;
        for (bit = 0; bit < 8; bit++) {
            c = (c >> 1) ^ (HP_CRC32C_POLY & (uint32_t)(-(int32_t)(c & 1)));
        }
    }

    return ~c;
}
