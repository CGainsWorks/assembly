/*
 * A monotonic wall clock for the benchmark and for hpscan.
 *
 * clock_gettime is POSIX and is not reliably present on Windows toolchains,
 * where QueryPerformanceCounter is the documented monotonic source. Not part
 * of the library and not installed.
 */
#ifndef HOTPATH_TIMING_H
#define HOTPATH_TIMING_H

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

static double hp_now_seconds(void)
{
    LARGE_INTEGER freq;
    LARGE_INTEGER count;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&count);
    return (double)count.QuadPart / (double)freq.QuadPart;
}

#else
#include <time.h>

static double hp_now_seconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

#endif

#endif /* HOTPATH_TIMING_H */
