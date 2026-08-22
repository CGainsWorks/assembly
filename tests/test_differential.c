/*
 * Differential tests.
 *
 * Known answer tests only prove the cases somebody thought to write down. What
 * actually catches assembly bugs is running every kernel against its portable
 * reference over a large sweep of lengths and alignments, because the bugs live
 * in the tails and at the boundaries between one blocking strategy and the next.
 *
 * The interesting lengths list is built from those boundaries: vector widths,
 * unroll widths, and the 768 and 24576 byte thresholds where the CRC kernel
 * switches between its single stream, short block and long block paths. Each
 * length is then run at a range of offsets within a padded buffer, so an
 * alignment assumption that happens to hold for malloc cannot hide. Short
 * buffers get every offset from 0 to 31, long ones get a representative set,
 * for the reason given above the long_offsets table.
 *
 * CRC results are checked against two independent references, the table driven
 * one and the bit at a time one, so a corrupted table cannot make both the
 * assembly and its reference agree on a wrong answer.
 */
#include <string.h>

#include "testutil.h"

#define MAX_LEN     100032
#define MAX_OFFSET  32
#define BUF_BYTES   (MAX_LEN + MAX_OFFSET)

static unsigned char g_buf[BUF_BYTES];
static char g_hex_asm[2 * MAX_LEN];
static char g_hex_ref[2 * MAX_LEN];

static const size_t interesting_lengths[] = {
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 23, 24, 25, 31, 32, 33,
    47, 48, 63, 64, 65, 95, 96, 97, 127, 128, 129, 159, 160, 191, 192,
    255, 256, 257, 383, 384, 511, 512, 513, 639, 640,
    /* CRC short block boundary is three times 256 bytes. */
    767, 768, 769, 775, 1535, 1536, 1537, 2303, 2304,
    /* CRC long block boundary is three times 8192 bytes. */
    24575, 24576, 24577, 24583, 32768, 49151, 49152, 49153,
    73727, 73728, 73729, 98303, 98304, 98305, 100000
};

#define N_LENGTHS (sizeof(interesting_lengths) / sizeof(interesting_lengths[0]))

/*
 * Fill the buffer with a mix that gives the kernels something to find. Pure
 * random data almost never contains a chosen needle in a short buffer, so a
 * share of the bytes is forced to the needle value.
 */
static void fill_buffer(hp_rng *rng, unsigned char needle, int density)
{
    size_t i;

    hp_rng_fill(rng, g_buf, BUF_BYTES);

    if (density > 0) {
        for (i = 0; i < BUF_BYTES; i++) {
            if ((int)(hp_rng_next(rng) % 100) < density) {
                g_buf[i] = needle;
            }
        }
    }
}

static void clear_high_bits(size_t len)
{
    size_t i;
    for (i = 0; i < len; i++) {
        g_buf[i] &= 0x7F;
    }
}

static void check_length(const unsigned char *p, size_t len, unsigned char needle)
{
    uint32_t crc_asm = hp_crc32c(0, p, len);
    uint32_t crc_ref = hp_crc32c_ref(0, p, len);
    size_t count_asm, count_ref;
    const void *find_asm;
    const void *find_ref;
    int ascii_asm, ascii_ref;

    HP_CHECK(crc_asm == crc_ref,
             "crc32c len=%zu: dispatched 0x%08X, table reference 0x%08X",
             len, crc_asm, crc_ref);
    /*
     * The bitwise reference exists to validate the generated table, not the
     * blocking strategy, and it costs roughly eight times a table lookup per
     * byte. Running it on the shorter buffers is enough to make that point
     * without dominating the runtime of the suite under a sanitiser.
     */
    if (len <= 8192) {
        uint32_t crc_bit = hp_crc32c_bitwise(0, p, len);
        HP_CHECK(crc_ref == crc_bit,
                 "crc32c len=%zu: table reference 0x%08X, bitwise reference 0x%08X",
                 len, crc_ref, crc_bit);
    }

    count_asm = hp_count_byte(p, len, needle);
    count_ref = hp_count_byte_ref(p, len, needle);
    HP_CHECK(count_asm == count_ref,
             "count_byte len=%zu needle=0x%02X: %zu, expected %zu",
             len, needle, count_asm, count_ref);

    find_asm = hp_find_byte(p, len, needle);
    find_ref = hp_find_byte_ref(p, len, needle);
    HP_CHECK(find_asm == find_ref,
             "find_byte len=%zu needle=0x%02X: offset %ld, expected %ld",
             len, needle,
             find_asm ? (long)((const unsigned char *)find_asm - p) : -1L,
             find_ref ? (long)((const unsigned char *)find_ref - p) : -1L);

    ascii_asm = hp_is_ascii(p, len);
    ascii_ref = hp_is_ascii_ref(p, len);
    HP_CHECK(ascii_asm == ascii_ref,
             "is_ascii len=%zu: %d, expected %d", len, ascii_asm, ascii_ref);

    if (len <= MAX_LEN) {
        memset(g_hex_asm, 0, 2 * len);
        memset(g_hex_ref, 1, 2 * len);
        hp_hex_encode(g_hex_asm, p, len);
        hp_hex_encode_ref(g_hex_ref, p, len);
        HP_CHECK(memcmp(g_hex_asm, g_hex_ref, 2 * len) == 0,
                 "hex_encode len=%zu disagrees with the reference", len);
    }
}

/*
 * Short buffers get every offset. Long ones get a representative set, because
 * the alignment behaviour of a kernel is decided in its first and last vector,
 * not in the middle, and a full sweep of every offset at a hundred kilobytes
 * apiece buys nothing for the time it costs.
 */
static const size_t long_offsets[] = { 0, 1, 3, 7, 8, 15, 16, 17, 31 };

#define N_LONG_OFFSETS (sizeof(long_offsets) / sizeof(long_offsets[0]))

static void sweep(unsigned char needle, int density, int force_ascii)
{
    hp_rng rng;
    size_t li;
    size_t oi;

    hp_rng_seed(&rng, 0x1234ABCD5678EF90ULL + needle + (uint64_t)density);

    for (li = 0; li < N_LENGTHS; li++) {
        size_t len = interesting_lengths[li];
        size_t n_offsets = (len <= 4096) ? MAX_OFFSET : N_LONG_OFFSETS;

        fill_buffer(&rng, needle, density);
        if (force_ascii) {
            clear_high_bits(BUF_BYTES);
        }

        for (oi = 0; oi < n_offsets; oi++) {
            size_t offset = (len <= 4096) ? oi : long_offsets[oi];
            if (len + offset > BUF_BYTES) {
                continue;
            }
            check_length(g_buf + offset, len, needle);
        }
    }
}

/* A pass over every length from 0 to 4096 catches off by one tails. */
static void dense_short_sweep(unsigned char needle)
{
    hp_rng rng;
    size_t len;

    hp_rng_seed(&rng, 0xFEEDFACEC0FFEEULL + needle);
    fill_buffer(&rng, needle, 5);

    for (len = 0; len <= 4096; len++) {
        check_length(g_buf + (len % MAX_OFFSET), len, needle);
    }
}

static void run_all(void)
{
    /*
     * Newline is the needle that matters for log ingestion, but a byte that
     * never appears and one that appears constantly are the cases that break
     * accumulator draining, so all three get a pass.
     */
    sweep('\n', 5, 0);       /* sparse matches, arbitrary bytes            */
    sweep(0x00, 0, 0);       /* matches only where random data happens to  */
    sweep(0xFF, 60, 0);      /* dense matches, stresses the byte counters  */
    sweep('\n', 3, 1);       /* pure ASCII, so is_ascii returns true       */
    dense_short_sweep('\n');
}

int main(void)
{
    int backend;
    int ran = 0;

    for (backend = 0; backend < HP_BACKEND_COUNT; backend++) {
        if (!hp_backend_supported((hp_backend_t)backend)) {
            printf("skipping %s, not supported here\n",
                   hp_backend_name((hp_backend_t)backend));
            continue;
        }
        if (hp_set_backend((hp_backend_t)backend) != 0) {
            HP_CHECK(0, "hp_set_backend(%s) failed although it reported support",
                     hp_backend_name((hp_backend_t)backend));
            continue;
        }
        printf("backend %s\n", hp_backend_name(hp_backend()));
        run_all();
        ran++;
    }

    HP_CHECK(ran > 0, "no backend was exercised");

    return hp_test_report("test_differential");
}
