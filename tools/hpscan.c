/*
 * hpscan: a worked example of what the library is for.
 *
 * An ingestion pipeline that accepts a batch of log lines usually has to do
 * four things before it can do anything useful: confirm the batch arrived
 * intact, find out how many records it holds, check the encoding, and record a
 * fingerprint for deduplication. Those are four passes over the same bytes and
 * on a busy collector they are pure overhead, which is exactly the kind of work
 * worth pushing down into a handful of vector instructions.
 *
 * Usage:
 *   hpscan [options] [file ...]      reads standard input when given no file
 *
 * Options:
 *   --backend=NAME   force baseline, sse42, avx2 or avx512
 *   --repeat=N       process each input N times for a steadier throughput figure
 *   --cpu            print the detected CPU features and exit
 *   --help
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hotpath.h"
#include "timing.h"

#define CHUNK (1u << 20)

static void print_cpu(void)
{
    const hp_cpu_info *cpu = hp_cpu();

    printf("cpu          : %s\n", cpu->brand[0] ? cpu->brand : "unknown");
    printf("features     : sse2=%d ssse3=%d sse42=%d pclmul=%d avx=%d avx2=%d bmi2=%d\n",
           cpu->sse2, cpu->ssse3, cpu->sse42, cpu->pclmul, cpu->avx,
           cpu->avx2, cpu->bmi2);
    printf("avx-512      : f=%d bw=%d popcnt=%d\n", cpu->avx512f, cpu->avx512bw,
           cpu->popcnt);
    printf("os ymm state : %d\n", cpu->ymm_enabled);
    printf("os zmm state : %d\n", cpu->zmm_enabled);
    printf("tiers        : ");
    {
        int i;
        for (i = 0; i < HP_BACKEND_COUNT; i++) {
            printf("%s=%s ", hp_backend_name((hp_backend_t)i),
                   hp_backend_supported((hp_backend_t)i) ? "yes" : "no");
        }
    }
    printf("\n");
    printf("selected     : %s\n", hp_backend_name(hp_backend()));
}

/* Read a whole stream into memory. Returns NULL on failure. */
static unsigned char *slurp(FILE *fp, size_t *out_len)
{
    size_t cap = CHUNK;
    size_t len = 0;
    unsigned char *buf = malloc(cap);

    if (buf == NULL) {
        return NULL;
    }

    for (;;) {
        size_t got;
        if (len == cap) {
            unsigned char *bigger;
            if (cap > (size_t)-1 / 2) {
                free(buf);
                return NULL;
            }
            cap *= 2;
            bigger = realloc(buf, cap);
            if (bigger == NULL) {
                free(buf);
                return NULL;
            }
            buf = bigger;
        }
        got = fread(buf + len, 1, cap - len, fp);
        len += got;
        if (got == 0) {
            break;
        }
    }

    if (ferror(fp)) {
        free(buf);
        return NULL;
    }

    *out_len = len;
    return buf;
}

static int scan_stream(const char *name, FILE *fp, long repeat)
{
    unsigned char *buf;
    size_t len = 0;
    size_t lines = 0;
    uint32_t crc = 0;
    int ascii = 1;
    char fingerprint[17];
    double start;
    double elapsed;
    long r;

    buf = slurp(fp, &len);
    if (buf == NULL) {
        fprintf(stderr, "hpscan: %s: read failed\n", name);
        return 1;
    }

    start = hp_now_seconds();
    for (r = 0; r < repeat; r++) {
        crc = hp_crc32c(0, buf, len);
        lines = hp_count_byte(buf, len, '\n');
        ascii = hp_is_ascii(buf, len);
    }
    elapsed = hp_now_seconds() - start;

    /* Eight bytes of the CRC seeded digest, as a short human readable tag. */
    {
        unsigned char tag[8];
        int i;
        uint32_t a = crc;
        uint32_t b = hp_crc32c(crc, buf, len < 4096 ? len : 4096);
        for (i = 0; i < 4; i++) {
            tag[i] = (unsigned char)(a >> (8 * (3 - i)));
            tag[i + 4] = (unsigned char)(b >> (8 * (3 - i)));
        }
        hp_hex_encode(fingerprint, tag, sizeof(tag));
        fingerprint[16] = '\0';
    }

    printf("%s\n", name);
    printf("  bytes       : %zu\n", len);
    printf("  lines       : %zu\n", lines);
    printf("  ascii clean : %s\n", ascii ? "yes" : "no");
    printf("  crc32c      : 0x%08X\n", crc);
    printf("  fingerprint : %s\n", fingerprint);
    printf("  backend     : %s\n", hp_backend_name(hp_backend()));
    if (elapsed > 0.0 && len > 0) {
        double bytes = (double)len * (double)repeat * 3.0; /* three passes */
        printf("  throughput  : %.2f GB/s over %ld pass(es) of three scans\n",
               bytes / elapsed / 1e9, repeat);
    }

    free(buf);
    return 0;
}

static void usage(const char *argv0)
{
    printf("usage: %s [--backend=baseline|sse42|avx2|avx512] [--repeat=N] [--cpu] [file ...]\n",
           argv0);
}

int main(int argc, char **argv)
{
    long repeat = 1;
    int status = 0;
    int i;
    int files = 0;

    for (i = 1; i < argc; i++) {
        const char *arg = argv[i];

        if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
            usage(argv[0]);
            return 0;
        }
        if (strcmp(arg, "--cpu") == 0) {
            print_cpu();
            return 0;
        }
        if (strncmp(arg, "--backend=", 10) == 0) {
            const char *want = arg + 10;
            int b;
            int found = 0;
            for (b = 0; b < HP_BACKEND_COUNT; b++) {
                if (strcmp(want, hp_backend_name((hp_backend_t)b)) == 0) {
                    found = 1;
                    if (hp_set_backend((hp_backend_t)b) != 0) {
                        fprintf(stderr,
                                "hpscan: this cpu cannot run the %s tier\n", want);
                        return 2;
                    }
                }
            }
            if (!found) {
                fprintf(stderr, "hpscan: unknown backend \"%s\"\n", want);
                return 2;
            }
            continue;
        }
        if (strncmp(arg, "--repeat=", 9) == 0) {
            repeat = strtol(arg + 9, NULL, 10);
            if (repeat < 1) {
                fprintf(stderr, "hpscan: --repeat needs a positive count\n");
                return 2;
            }
            continue;
        }
        if (arg[0] == '-' && arg[1] != '\0') {
            fprintf(stderr, "hpscan: unknown option \"%s\"\n", arg);
            usage(argv[0]);
            return 2;
        }

        {
            FILE *fp = fopen(arg, "rb");
            if (fp == NULL) {
                fprintf(stderr, "hpscan: cannot open %s\n", arg);
                status = 1;
                continue;
            }
            files++;
            if (scan_stream(arg, fp, repeat) != 0) {
                status = 1;
            }
            fclose(fp);
        }
    }

    if (files == 0) {
        if (scan_stream("<stdin>", stdin, repeat) != 0) {
            status = 1;
        }
    }

    return status;
}
