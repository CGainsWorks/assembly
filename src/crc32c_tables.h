/*
 * Declarations for the generated CRC-32C constant tables.
 *
 * The tables are hidden from the dynamic symbol table so that the assembly
 * kernel can reach them with a plain rip relative lea instead of an indirect
 * load through the global offset table.
 */
#ifndef HOTPATH_CRC32C_TABLES_H
#define HOTPATH_CRC32C_TABLES_H

#include <stdint.h>

#if defined(__GNUC__)
#define HP_HIDDEN __attribute__((visibility("hidden")))
#else
#define HP_HIDDEN
#endif

/* Byte at a time reflected CRC-32C table, used by the portable reference. */
HP_HIDDEN extern const uint32_t hp_crc32c_byte_table[256];

/*
 * Operators that advance a raw CRC register over a run of zero bytes. Index
 * [k][b] holds the contribution of byte k of the register when its value is b.
 * The block sizes match HP_CRC32C_SHORT and HP_CRC32C_LONG in src/asm/crc32c.S.
 */
HP_HIDDEN extern const uint32_t hp_crc32c_zeros_short[4][256];
HP_HIDDEN extern const uint32_t hp_crc32c_zeros_long[4][256];

#endif /* HOTPATH_CRC32C_TABLES_H */
