/*
 * Small helpers shared by the test programs.
 *
 * Every test walks the dispatch tiers the host supports rather than only the
 * fastest one, so the scalar fallbacks are exercised on the same machine as
 * the vector kernels.
 */
#ifndef HOTPATH_TESTUTIL_H
#define HOTPATH_TESTUTIL_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "internal.h"

static int hp_test_failures;

#define HP_CHECK(cond, ...)                                                   \
    do {                                                                      \
        if (!(cond)) {                                                        \
            hp_test_failures++;                                               \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);              \
            fprintf(stderr, __VA_ARGS__);                                     \
            fputc('\n', stderr);                                              \
            if (hp_test_failures > 20) {                                      \
                fprintf(stderr, "too many failures, stopping\n");             \
                exit(1);                                                      \
            }                                                                 \
        }                                                                     \
    } while (0)

/* xorshift64star: deterministic, so a failing run reproduces exactly. */
typedef struct {
    uint64_t state;
} hp_rng;

static inline void hp_rng_seed(hp_rng *rng, uint64_t seed)
{
    rng->state = seed ? seed : 0x9E3779B97F4A7C15ULL;
}

static inline uint64_t hp_rng_next(hp_rng *rng)
{
    uint64_t x = rng->state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng->state = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static inline void hp_rng_fill(hp_rng *rng, unsigned char *dst, size_t len)
{
    size_t i;
    for (i = 0; i < len; i++) {
        dst[i] = (unsigned char)(hp_rng_next(rng) >> 24);
    }
}

static inline int hp_test_report(const char *name)
{
    if (hp_test_failures != 0) {
        printf("%s: %d failure(s)\n", name, hp_test_failures);
        return 1;
    }
    printf("%s: ok\n", name);
    return 0;
}

#endif /* HOTPATH_TESTUTIL_H */
