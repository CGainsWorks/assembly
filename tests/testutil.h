/*
 * Small helpers shared by the test programs.
 *
 * Every test walks the dispatch tiers the host supports rather than only the
 * fastest one, so the scalar fallbacks are exercised on the same machine as
 * the vector kernels.
 *
 * HOTPATH_TEST_TIERS turns that from best effort into a requirement. Set to a
 * comma separated list such as "baseline,avx512", a test runs exactly those
 * tiers and fails if the CPU cannot run any one of them. CI uses it under
 * Intel SDE, where a silently skipped AVX-512 tier would otherwise look like a
 * pass, and make test-tiers uses it to run each tier on its own.
 */
#ifndef HOTPATH_TESTUTIL_H
#define HOTPATH_TESTUTIL_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* 1 if name appears as a whole entry in a comma separated list. */
static inline int hp_test_listed(const char *list, const char *name)
{
    size_t n = strlen(name);
    const char *p = list;

    while (*p != '\0') {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len == n && strncmp(p, name, n) == 0) {
            return 1;
        }
        if (end == NULL) {
            break;
        }
        p = end + 1;
    }
    return 0;
}

/* A misspelled entry would otherwise just mean a tier quietly not tested. */
static inline void hp_test_check_tier_list(void)
{
    const char *list = getenv("HOTPATH_TEST_TIERS");
    const char *p = list;

    if (list == NULL || *list == '\0') {
        return;
    }
    while (*p != '\0') {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        int known = 0;
        int b;
        for (b = 0; b < HP_BACKEND_COUNT; b++) {
            const char *name = hp_backend_name((hp_backend_t)b);
            if (strlen(name) == len && strncmp(p, name, len) == 0) {
                known = 1;
            }
        }
        HP_CHECK(known, "HOTPATH_TEST_TIERS names an unknown tier \"%.*s\"",
                 (int)len, p);
        if (end == NULL) {
            break;
        }
        p = end + 1;
    }
}

/*
 * Decide whether to run a tier and, if so, install it. Returns 1 when the
 * tier is now active and the caller should test it.
 */
static inline int hp_test_use_tier(hp_backend_t backend)
{
    const char *list = getenv("HOTPATH_TEST_TIERS");
    const char *name = hp_backend_name(backend);

    if (list != NULL && *list != '\0') {
        if (!hp_test_listed(list, name)) {
            printf("skipping %s, not requested\n", name);
            return 0;
        }
        if (!hp_backend_supported(backend)) {
            HP_CHECK(0, "HOTPATH_TEST_TIERS requires %s but this CPU cannot run it",
                     name);
            return 0;
        }
    } else if (!hp_backend_supported(backend)) {
        printf("skipping %s, not supported here\n", name);
        return 0;
    }

    if (hp_set_backend(backend) != 0 || hp_backend() != backend) {
        HP_CHECK(0, "hp_set_backend(%s) failed although it reported support", name);
        return 0;
    }
    printf("backend %s\n", name);
    return 1;
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
