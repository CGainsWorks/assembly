# Status

Last updated 2026-10-16.

## Complete

- Five kernels (CRC-32C, byte count, byte find, ASCII validation, hex encode),
  each with a portable C reference and assembly implementations, behind run time
  CPU dispatch with four tiers: `baseline`, `sse42`, `avx2` and `avx512`.
- `avx512` tier for count, find and ASCII validation, with masked tails. Opt in
  only (`HOTPATH_BACKEND=avx512`), for the reason under Limitations.
- Two calling conventions from one source: System V AMD64 on Linux (static and
  shared library) and Microsoft x64 on Windows through MinGW-w64 (static
  library), via the entry and exit macros in `src/asm/hp_asm.h`.
- Four test programs, each run against every tier the CPU offers, and again once
  per tier by `make test-tiers`:
  - `test_vectors`: published CRC-32C check values and known answers
  - `test_differential`: every kernel against its reference over 68 boundary
    lengths at up to 32 offsets, plus every length from 0 to 4096
  - `test_overread`: guard page tests at every length from 0 to a page, on
    Linux (mprotect) and Windows (VirtualProtect)
  - `test_abi`: every kernel called through a register checker that fails on
    any clobbered callee saved register, including `rdi`, `rsi` and `xmm6` to
    `xmm15` on Windows
- CI, ten jobs, all green on the latest commit:
  - `test` with gcc 13 and clang 18 on ubuntu-24.04: `make check` and
    `make test-tiers`
  - `sanitizers` with gcc 13 and clang 18: AddressSanitizer and UBSan
  - `sde`: Intel SDE 10.13.1 (pinned by checksum, cached) in chip check mode.
    CPU detection is asserted on seven emulated parts (Merom, Nehalem, Haswell,
    Sierra Forest, Skylake server, Ice Lake server, Sapphire Rapids), and the
    suite runs per tier on Merom (`baseline`), Nehalem (`sse42`), Haswell
    (`avx2`), Skylake server (all four), Ice Lake server and Sapphire Rapids
    (`avx512`).
  - `windows` on windows-2025 with MinGW-w64 gcc and with clang from MSYS2:
    `make check`, `make test-tiers`, and the `avx512` tier under the Windows
    build of SDE.
  - `dispatch`, `bench-smoke` (including the simdutf and google/crc32c build)
    and `generated` (the CRC tables regenerate byte for byte).
- Benchmarks against fair baselines: the same C at `-O3 -march=native`, libc
  `memchr`, simdutf 9.2.1 `validate_ascii` and google/crc32c 1.1.2, regenerated
  on the development machine on 2026-10-16. Results in
  [docs/BENCHMARKS.md](docs/BENCHMARKS.md). At 64 KiB hotpath leads on the byte
  count (17.7x over `-O3 -march=native` C), the hex encoder (12.8x) and, within
  the noise of the run, the ASCII check (1.15x over simdutf), and loses on the CRC (0.80x of google/crc32c) and
  the byte find (0.55x of glibc `memchr`).

## In progress

Nothing.

## Not started

- Timing the `avx512` tier on AVX-512 hardware, and deciding from that whether
  it becomes the automatic choice.
- A `vpermb` hex encoder (AVX-512 VBMI).
- A DLL for Windows (needs a `.def` export list) and any MSVC build.
- An ARM64 port, NEON and the ARMv8 CRC32 extension.
- UTF-8 validation and base64 decoding kernels.
- A faster `hp_find_byte`: glibc `memchr` is 1.5 to 1.9 times faster from 1 KiB
  upwards on the development machine.
- Working out why google/crc32c is a tenth to a quarter faster than `hp_crc32c`
  from 1 KiB upwards on the same machine.
- Python or Rust bindings.

## Limitations

- Everything AVX-512 has been verified under emulation, which establishes
  correctness and says nothing about speed. Hosted runners occasionally have
  AVX-512 and then run the tier natively, but that is not guaranteed.
- Benchmark numbers come from one contended desktop (AMD Ryzen 7 5700X, Zen 3,
  WSL2), with the load recorded alongside them. They rank implementations; they
  are not precise figures and are true of that machine only.
- No Windows machine was used for development. All Windows execution is on CI
  runners, plus wine in a container while the shim was written.
- No hardware performance counters were available, so there are no cycle level
  measurements.

Detail on each, with what it would take to close, is in
[LIMITATIONS.md](LIMITATIONS.md).
