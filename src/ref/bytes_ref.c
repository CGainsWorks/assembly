/*
 * Portable reference implementations of the byte oriented kernels.
 *
 * These are written as plain loops with no intrinsics so that they compile
 * anywhere. They are compiled at the same optimisation level as the rest of
 * the library, which means the compiler is free to vectorise them. That is
 * deliberate: the benchmark should compare hand written assembly against what
 * a competent compiler produces from readable C, not against a strawman.
 */
#include "internal.h"

size_t hp_count_byte_ref(const void *buf, size_t len, uint8_t needle)
{
    const unsigned char *p = (const unsigned char *)buf;
    size_t count = 0;
    size_t i;

    for (i = 0; i < len; i++) {
        count += (p[i] == needle);
    }

    return count;
}

const void *hp_find_byte_ref(const void *buf, size_t len, uint8_t needle)
{
    const unsigned char *p = (const unsigned char *)buf;
    size_t i;

    for (i = 0; i < len; i++) {
        if (p[i] == needle) {
            return p + i;
        }
    }

    return NULL;
}

int hp_is_ascii_ref(const void *buf, size_t len)
{
    const unsigned char *p = (const unsigned char *)buf;
    unsigned char acc = 0;
    size_t i;

    /* Accumulate rather than branch, so the loop stays vectorisable. */
    for (i = 0; i < len; i++) {
        acc |= p[i];
    }

    return (acc & 0x80) == 0;
}

void hp_hex_encode_ref(char *dst, const void *src, size_t len)
{
    static const char digits[16] = {
        '0', '1', '2', '3', '4', '5', '6', '7',
        '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'
    };
    const unsigned char *p = (const unsigned char *)src;
    size_t i;

    for (i = 0; i < len; i++) {
        dst[2 * i]     = digits[p[i] >> 4];
        dst[2 * i + 1] = digits[p[i] & 0x0F];
    }
}
