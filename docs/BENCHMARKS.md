# Benchmarks

CPU: AMD Ryzen 7 5700X 8-Core Processor             

Host: WSL2 (Ubuntu 22.04) on Windows 11, desktop shared with other work

Run: 2026-10-16, `make bench-full` with the benchmark pinned to one core
(`taskset -c 5`). The machine was busy throughout: the load average was 6.27 when
the run started and 11.06 when it finished, on 16 hardware threads, and Windows
reported the CPU over 90 percent busy. The two columns below that run identical
code differ by up to about 15 percent, which is the noise floor of this run;
gaps smaller than that mean nothing.

Regenerate with `make bench-full BENCH_ARGS=--host="..." > docs/BENCHMARKS.md`.

Compiler: gcc 11.4.0

simdutf selected its `haswell` kernel on this CPU.

Throughput in GB/s, higher is better, measured on the machine named
above and true of nowhere else. The columns before the hotpath tiers
are baselines: the project's own C at -O2, the same C rebuilt with
`-O3 -march=native`, and established libraries where one does the
same job. The last two columns name the fastest baseline and give
hotpath's fastest tier as a multiple of it, so a figure below 1.00x
means the baseline wins.

Two of the kernels are shared between the sse42 and avx2 tiers,
as noted under each heading. The gap between two columns that run
identical code is pure measurement noise, so it doubles as a read
on how much of any other gap in the table is real.

This CPU has no AVX-512, so the avx512 tier is absent here. It is
verified for correctness under Intel SDE in CI and has never been
timed.

## hp_crc32c

CRC-32C over the whole buffer. The sse42 and avx2 tiers share one kernel.

| size | C -O2 | C -O3 native | google crc32c | sse42 | avx2 | best baseline | hotpath vs best baseline |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 64 B | 0.60 | 0.59 | 6.63 | 7.06 | 7.52 | google crc32c | 1.13x |
| 256 B | 0.52 | 0.50 | 12.18 | 11.75 | 11.98 | google crc32c | 0.98x |
| 1 KiB | 0.48 | 0.51 | 20.59 | 17.87 | 18.28 | google crc32c | 0.89x |
| 4 KiB | 0.46 | 0.47 | 23.61 | 19.35 | 20.40 | google crc32c | 0.86x |
| 64 KiB | 0.49 | 0.52 | 27.10 | 21.40 | 21.55 | google crc32c | 0.80x |
| 1 MiB | 0.48 | 0.48 | 25.39 | 19.92 | 19.42 | google crc32c | 0.78x |
| 16 MiB | 0.47 | 0.43 | 14.17 | 12.73 | 11.08 | google crc32c | 0.90x |

## hp_count_byte

Counts newlines at roughly one per 64 bytes. No widely used library exports a byte count, so the comparison is against compiled C only.

| size | C -O2 | C -O3 native | sse42 | avx2 | best baseline | hotpath vs best baseline |
| ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 64 B | 0.75 | 3.97 | 0.76 | 9.23 | C -O3 native | 2.32x |
| 256 B | 0.74 | 4.99 | 0.83 | 28.96 | C -O3 native | 5.80x |
| 1 KiB | 0.80 | 4.96 | 0.84 | 73.59 | C -O3 native | 14.85x |
| 4 KiB | 0.86 | 5.08 | 0.80 | 101.12 | C -O3 native | 19.91x |
| 64 KiB | 0.84 | 4.90 | 0.84 | 86.73 | C -O3 native | 17.70x |
| 1 MiB | 0.87 | 4.69 | 0.87 | 76.79 | C -O3 native | 16.37x |
| 16 MiB | 0.83 | 4.90 | 0.92 | 25.73 | C -O3 native | 5.25x |

## hp_find_byte

The needle is absent, so the whole buffer is scanned.

| size | C -O2 | C -O3 native | libc memchr | sse42 | avx2 | best baseline | hotpath vs best baseline |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 64 B | 1.39 | 1.46 | 7.66 | 1.42 | 10.91 | libc memchr | 1.42x |
| 256 B | 2.13 | 2.13 | 30.58 | 2.15 | 30.23 | libc memchr | 0.99x |
| 1 KiB | 2.00 | 1.89 | 60.90 | 1.95 | 39.56 | libc memchr | 0.65x |
| 4 KiB | 1.82 | 1.75 | 88.55 | 1.88 | 46.29 | libc memchr | 0.52x |
| 64 KiB | 1.83 | 1.91 | 92.11 | 1.98 | 50.58 | libc memchr | 0.55x |
| 1 MiB | 1.89 | 1.94 | 75.38 | 1.95 | 48.03 | libc memchr | 0.64x |
| 16 MiB | 2.34 | 2.07 | 15.18 | 2.17 | 10.16 | libc memchr | 0.67x |

## hp_is_ascii

All ASCII input, so the whole buffer is scanned.

| size | C -O2 | C -O3 native | simdutf | sse42 | avx2 | best baseline | hotpath vs best baseline |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 64 B | 1.85 | 10.08 | 5.31 | 1.92 | 10.07 | C -O3 native | 1.00x |
| 256 B | 1.89 | 26.73 | 18.86 | 1.86 | 36.84 | C -O3 native | 1.38x |
| 1 KiB | 1.99 | 47.33 | 52.84 | 2.07 | 89.44 | simdutf | 1.69x |
| 4 KiB | 2.23 | 67.36 | 81.64 | 2.19 | 123.28 | simdutf | 1.51x |
| 64 KiB | 2.12 | 59.05 | 81.27 | 2.06 | 93.55 | simdutf | 1.15x |
| 1 MiB | 2.27 | 59.80 | 76.21 | 2.33 | 78.49 | simdutf | 1.03x |
| 16 MiB | 2.01 | 9.70 | 13.57 | 2.04 | 14.46 | simdutf | 1.07x |

## hp_hex_encode

Two output bytes per input byte. The sse42 and avx2 tiers share one kernel. No library baseline was found that is a fair like for like, so the comparison is against compiled C only.

| size | C -O2 | C -O3 native | sse42 | avx2 | best baseline | hotpath vs best baseline |
| ---: | ---: | ---: | ---: | ---: | --- | ---: |
| 64 B | 0.74 | 0.92 | 6.88 | 6.66 | C -O3 native | 7.48x |
| 256 B | 0.78 | 1.06 | 11.05 | 11.70 | C -O3 native | 11.02x |
| 1 KiB | 0.79 | 1.05 | 11.29 | 11.02 | C -O3 native | 10.77x |
| 4 KiB | 0.87 | 1.03 | 13.70 | 12.42 | C -O3 native | 13.27x |
| 64 KiB | 0.84 | 1.07 | 13.62 | 12.10 | C -O3 native | 12.77x |
| 1 MiB | 0.78 | 1.08 | 11.35 | 11.74 | C -O3 native | 10.90x |
| 16 MiB | 0.77 | 0.98 | 2.72 | 3.05 | C -O3 native | 3.10x |

