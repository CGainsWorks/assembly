# Benchmarks

CPU: AMD Ryzen 7 5700X 8-Core Processor             

Throughput in GB/s, higher is better. Every column is the same
build and the same data, only the dispatch tier differs. Numbers
come from one desktop machine and are meant for comparing the
columns against each other, not for comparing machines.

Two of the kernels are shared between the sse42 and avx2 tiers,
as noted under each heading. The gap between two columns that run
identical code is pure measurement noise, so it doubles as a read
on how much of any other gap in the table is real.

## hp_crc32c

CRC-32C over the whole buffer. The sse42 and avx2 tiers share one kernel.

| size | baseline | sse42 | avx2 | best speedup |
| ---: | ---: | ---: | ---: | ---: |
| 64 B | 0.58 | 6.77 | 6.38 | 11.68x |
| 256 B | 0.52 | 10.95 | 10.63 | 20.99x |
| 1 KiB | 0.49 | 19.15 | 19.68 | 39.91x |
| 4 KiB | 0.43 | 16.48 | 15.77 | 38.73x |
| 64 KiB | 0.49 | 21.89 | 22.44 | 46.26x |
| 1 MiB | 0.49 | 26.70 | 25.41 | 54.62x |
| 16 MiB | 0.49 | 17.07 | 16.76 | 34.91x |

## hp_count_byte

Counts newlines at roughly one per 64 bytes.

| size | baseline | sse42 | avx2 | best speedup |
| ---: | ---: | ---: | ---: | ---: |
| 64 B | 1.55 | 1.73 | 12.38 | 7.98x |
| 256 B | 1.82 | 1.80 | 45.71 | 25.05x |
| 1 KiB | 1.91 | 1.64 | 102.02 | 53.49x |
| 4 KiB | 1.89 | 1.77 | 118.23 | 62.47x |
| 64 KiB | 1.82 | 1.70 | 110.37 | 60.77x |
| 1 MiB | 1.76 | 1.61 | 82.05 | 46.55x |
| 16 MiB | 1.66 | 1.52 | 22.64 | 13.61x |

## hp_find_byte

The needle is absent, so the whole buffer is scanned.

| size | baseline | sse42 | avx2 | best speedup |
| ---: | ---: | ---: | ---: | ---: |
| 64 B | 2.36 | 2.27 | 14.32 | 6.08x |
| 256 B | 2.27 | 2.76 | 31.28 | 13.77x |
| 1 KiB | 2.61 | 2.72 | 51.27 | 19.61x |
| 4 KiB | 2.82 | 2.96 | 48.62 | 17.24x |
| 64 KiB | 1.62 | 1.61 | 50.53 | 31.20x |
| 1 MiB | 1.61 | 1.56 | 26.81 | 16.61x |
| 16 MiB | 3.19 | 2.60 | 14.46 | 4.53x |

## hp_is_ascii

All ASCII input, so the whole buffer is scanned.

| size | baseline | sse42 | avx2 | best speedup |
| ---: | ---: | ---: | ---: | ---: |
| 64 B | 3.05 | 2.95 | 14.61 | 4.78x |
| 256 B | 2.84 | 2.95 | 55.69 | 19.63x |
| 1 KiB | 2.64 | 2.62 | 101.05 | 38.21x |
| 4 KiB | 2.82 | 3.07 | 119.11 | 42.18x |
| 64 KiB | 3.54 | 3.42 | 126.59 | 35.72x |
| 1 MiB | 3.82 | 3.82 | 86.02 | 22.52x |
| 16 MiB | 3.52 | 3.43 | 23.90 | 6.80x |

## hp_hex_encode

Two output bytes per input byte. The sse42 and avx2 tiers share one kernel.

| size | baseline | sse42 | avx2 | best speedup |
| ---: | ---: | ---: | ---: | ---: |
| 64 B | 1.24 | 10.86 | 11.09 | 8.98x |
| 256 B | 1.16 | 17.51 | 17.50 | 15.06x |
| 1 KiB | 1.35 | 18.37 | 18.11 | 13.64x |
| 4 KiB | 1.37 | 21.03 | 20.89 | 15.41x |
| 64 KiB | 1.40 | 21.77 | 21.28 | 15.55x |
| 1 MiB | 1.36 | 19.46 | 20.12 | 14.79x |
| 16 MiB | 1.31 | 3.84 | 3.87 | 2.96x |

