/*
 * Known answer tests.
 *
 * The CRC-32C values below are the published ones. 0xE3069283 for the string
 * "123456789" is the check value quoted in every CRC catalogue, and 0x8A9136AA
 * for thirty two zero bytes is the first test vector in RFC 3720. Agreeing with
 * those means this library computes the same CRC-32C as everybody else, which
 * matters because the whole point of a checksum is that two different programs
 * reach the same answer.
 */
#include <string.h>

#include "testutil.h"

typedef struct {
    const char *name;
    const char *data;
    size_t len;
    uint32_t expected;
} crc_case;

static const crc_case crc_cases[] = {
    { "empty",   "",                                            0,  0x00000000U },
    { "a",       "a",                                           1,  0xC1D04330U },
    { "abc",     "abc",                                         3,  0x364B3FB7U },
    { "check",   "123456789",                                   9,  0xE3069283U },
    { "fox",     "The quick brown fox jumps over the lazy dog", 43, 0x22620404U }
};

static void test_crc_vectors(void)
{
    size_t i;

    for (i = 0; i < sizeof(crc_cases) / sizeof(crc_cases[0]); i++) {
        const crc_case *c = &crc_cases[i];
        uint32_t got = hp_crc32c(0, c->data, c->len);
        HP_CHECK(got == c->expected,
                 "crc32c(%s) = 0x%08X, expected 0x%08X",
                 c->name, got, c->expected);
    }

    {
        /* RFC 3720 section B.4: thirty two zero bytes. */
        unsigned char zeros[32];
        uint32_t got;
        memset(zeros, 0, sizeof(zeros));
        got = hp_crc32c(0, zeros, sizeof(zeros));
        HP_CHECK(got == 0x8A9136AAU,
                 "crc32c(32 zero bytes) = 0x%08X, expected 0x8A9136AA", got);
    }

    {
        /*
         * Feeding the buffer in pieces has to give the same answer as feeding
         * it whole, otherwise streaming callers cannot use this at all.
         */
        uint32_t crc = hp_crc32c(0, "123", 3);
        crc = hp_crc32c(crc, "456789", 6);
        HP_CHECK(crc == 0xE3069283U,
                 "chained crc32c = 0x%08X, expected 0xE3069283", crc);
    }

    {
        /*
         * A buffer long enough to reach the three way pipelined path and its
         * stitching arithmetic, with a value pinned by the generator script.
         */
        static unsigned char pattern[100000];
        uint32_t got;
        size_t i2;
        for (i2 = 0; i2 < sizeof(pattern); i2++) {
            pattern[i2] = (unsigned char)((i2 * 167 + 13) & 0xFF);
        }
        got = hp_crc32c(0, pattern, sizeof(pattern));
        HP_CHECK(got == 0x503465F5U,
                 "crc32c(100000 byte pattern) = 0x%08X, expected 0x503465F5", got);
    }
}

static void test_byte_kernels(void)
{
    static const char line[] = "alpha\nbeta\ngamma\n";
    const size_t line_len = sizeof(line) - 1;
    const void *hit;

    HP_CHECK(hp_count_byte(line, line_len, '\n') == 3,
             "count_byte newline = %zu, expected 3",
             hp_count_byte(line, line_len, '\n'));
    /* alpha has two, beta has one, gamma has two. */
    HP_CHECK(hp_count_byte(line, line_len, 'a') == 5,
             "count_byte 'a' = %zu, expected 5",
             hp_count_byte(line, line_len, 'a'));
    HP_CHECK(hp_count_byte(line, line_len, 'z') == 0, "count_byte 'z' should be 0");
    HP_CHECK(hp_count_byte(line, 0, 'a') == 0, "count_byte over zero length");

    hit = hp_find_byte(line, line_len, '\n');
    HP_CHECK(hit == line + 5, "find_byte newline landed at the wrong offset");
    hit = hp_find_byte(line, line_len, 'z');
    HP_CHECK(hit == NULL, "find_byte should miss on 'z'");
    HP_CHECK(hp_find_byte(line, 0, 'a') == NULL, "find_byte over zero length");
    HP_CHECK(hp_find_byte(line, line_len, 'a') == line,
             "find_byte should match at offset zero");

    HP_CHECK(hp_is_ascii(line, line_len) == 1, "plain text should be ASCII");
    HP_CHECK(hp_is_ascii("", 0) == 1, "an empty buffer is ASCII");

    {
        unsigned char buf[64];
        size_t i;
        memset(buf, 'x', sizeof(buf));
        HP_CHECK(hp_is_ascii(buf, sizeof(buf)) == 1, "all 'x' should be ASCII");
        /* One high byte anywhere in the buffer has to be caught. */
        for (i = 0; i < sizeof(buf); i++) {
            buf[i] = 0x80;
            HP_CHECK(hp_is_ascii(buf, sizeof(buf)) == 0,
                     "high bit at offset %zu was missed", i);
            buf[i] = 'x';
        }
    }
}

static void test_hex(void)
{
    static const unsigned char src[] = {
        0x00, 0x01, 0x0F, 0x10, 0x7F, 0x80, 0xAB, 0xCD,
        0xEF, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32,
        0x10, 0xFF
    };
    static const char expected[] =
        "00010f107f80abcdeffedcba9876543210ff";
    char out[sizeof(src) * 2 + 1];

    memset(out, '?', sizeof(out));
    hp_hex_encode(out, src, sizeof(src));
    out[sizeof(src) * 2] = '\0';
    HP_CHECK(strcmp(out, expected) == 0,
             "hex_encode gave \"%s\", expected \"%s\"", out, expected);

    /* Zero length must not touch the destination at all. */
    out[0] = '!';
    hp_hex_encode(out, src, 0);
    HP_CHECK(out[0] == '!', "hex_encode wrote to dst for a zero length input");
}

int main(void)
{
    int backend;

    printf("cpu: %s\n", hp_cpu()->brand[0] ? hp_cpu()->brand : "unknown");

    hp_test_check_tier_list();

    for (backend = 0; backend < HP_BACKEND_COUNT; backend++) {
        if (!hp_test_use_tier((hp_backend_t)backend)) {
            continue;
        }
        test_crc_vectors();
        test_byte_kernels();
        test_hex();
    }

    /* Asking for a tier that does not exist must fail rather than crash. */
    HP_CHECK(hp_set_backend((hp_backend_t)99) == -1,
             "hp_set_backend accepted an out of range tier");
    HP_CHECK(hp_table_for((hp_backend_t)99) == NULL,
             "hp_table_for accepted an out of range tier");

    return hp_test_report("test_vectors");
}
