# Limitations and open work

Everything here is a real boundary of the current work rather than a wish list.
Each entry says what is missing, why it is missing, and what closing it would
take. The first group exists because of the hardware available for this project,
the second because of scope.

## Constrained by available hardware

Development and measurement happened on one machine: an AMD Ryzen 7 5700X, Zen 3,
eight cores, running Ubuntu 22.04 under WSL2 on Windows 11. No other hardware was
available, and several things follow from that.

### The AVX-512 tier is verified under emulation only

Zen 3 has no AVX-512, so the `avx512` tier was written without access to an
AVX-512 machine. It runs, in full, under Intel SDE 10.13.1 in CI: emulated
Skylake server, Ice Lake server and Sapphire Rapids parts, every test program,
every length and alignment in the differential sweep, and the guard page test
with SDE delivering bad accesses as faults. It also runs under the Windows build
of SDE, against the Windows calling convention.

GitHub's hosted runners are a mix of parts, and some have AVX-512: one run on
2026-10-16 landed its dispatch job on an AMD EPYC 9V45, where `avx512` was offered,
selected on request and agreed with the other tiers on a sample file. The native
test jobs run every tier the runner offers, so on such a runner they cover
`avx512` too. That is luck of the draw rather than a guarantee, which is why SDE
is the check that is relied on.

SDE proves the instructions are used correctly. It says nothing about speed, so
the tier has never been timed, and on several Intel parts sustained 512 bit work
lowers the clock. For that reason `hp_best_backend()` does not choose it; it is
reached through `HOTPATH_BACKEND=avx512` or `hp_set_backend`.

What it would take: an Ice Lake or later Xeon, or a Zen 4 or Zen 5 machine, to
time it against `avx2` and decide whether it should become the default. The
obvious next kernel is a `vpermb` based hex encoder, which needs AVX-512 VBMI and
is the one case where AVX-512 does something 128 bit SSSE3 genuinely cannot.

### No ARM or NEON port

There is no ARM hardware here. A NEON port could be written and run under QEMU
for correctness, but QEMU tells you nothing useful about throughput, and a set
of vector kernels whose performance has never been observed is not something to
publish speedup claims about.

What it would take: an Apple silicon Mac, a Graviton instance or a Raspberry Pi 5.
The counting and scanning kernels map onto NEON cleanly. `hp_crc32c` maps onto
the ARMv8 CRC32 extension almost directly, and the three way pipelining and the
Galois field stitching in `src/asm/crc32c.S` carry over unchanged, since that
argument is about the polynomial and not about the instruction set.

### Windows means MinGW-w64, static library only

The Microsoft x64 calling convention is supported through the shim in
`src/asm/hp_asm.h` and tested on GitHub's `windows-2025` runners with MinGW-w64
gcc and with clang from MSYS2. `tests/test_abi.c` checks that `rdi`, `rsi` and
`xmm6` to `xmm15` survive every kernel. The Windows runners seen so far report an
AMD EPYC 7763, so `baseline`, `sse42` and `avx2` run natively there and `avx512`
under the Windows build of Intel SDE.

Two things are not done. There is no DLL, only a static library, because the
export list is a GNU linker version script and an equivalent `.def` file has not
been written. And there is no MSVC build: `ml64` does not read GNU assembler
syntax, and a second copy of every kernel in MASM would double the code that has
to be trusted. No Windows machine was used for development; all Windows execution
is on CI runners, plus wine in a container while writing the shim.

### Benchmark numbers come from a contended desktop

The machine that produced [docs/BENCHMARKS.md](docs/BENCHMARKS.md) is a desktop
that was running other interactive work and build jobs at the time;
the load average before and after the run is recorded at the top of that file.
There was no access to a quiet machine with boost disabled, cores isolated and
the governor pinned, which is what performance numbers of this kind normally
deserve.

Three things were done about it rather than ignoring it. Columns are timed in
rotation rather than one after another, so drift over the run is shared between
columns instead of landing on one. The fastest run of several is kept rather than
the mean, since contention only ever makes a run slower. And two kernels are
shared between the `sse42` and `avx2` tiers, so those two columns run identical
code and the gap between them is a direct read on the noise floor.

Treat the tables as a sound ranking with roughly correct magnitudes, not as
precise figures.

### No cycle level profiling

`perf` is not installed and installing it needs administrative rights that were
not used here, so every measurement is wall clock throughput. There are no cycles
per byte, instructions per cycle, cache miss or branch misprediction numbers, and
no way to confirm from counters that the three way CRC loop is actually issuing
one `crc32` per cycle rather than merely being faster than the alternative.

What it would take: `perf` with a usable `perf_event_paranoid`, on hardware that
exposes the PMU.

### Untuned memory behaviour at large sizes

Every kernel converges towards memory bandwidth past a megabyte, which the tables
show plainly. Software prefetch distance and non-temporal stores for the hex
encoder are the usual next lever, and both are strongly machine specific. Tuning
them against one contended desktop would produce numbers that mean nothing
anywhere else, so neither was attempted.

## Constrained by scope

### Some baselines are missing because nothing fair exists

`hp_count_byte` and `hp_hex_encode` are compared only with compiled C, at `-O2`
and at `-O3 -march=native`, because no widely used library exports a plain byte
count or a bare hex encoder with the same contract. Faster published techniques
exist for both, inside larger projects, and a comparison with those would need
extracting them first.

### The dispatch layer is not thread safe to reconfigure

`hp_set_backend` rewrites a process wide table. It is meant for tests and
benchmarks and it is documented as such, but a caller could still invoke it while
another thread is inside a kernel. The initial detection is safe, since a race
there has two threads computing the same answer from the same CPUID. Making
reconfiguration safe would mean either an atomic pointer swap or, better,
GNU indirect functions, which resolve once at load time and remove the indirect
call as well.

### The indirect call is a real cost on small buffers

At 64 bytes the call through the function pointer is a measurable share of the
work, which is visible in the tables as a lower speedup at the smallest size.
An `ifunc` resolver would remove it. That was not done because `ifunc` makes
forcing a tier from a test much harder, and being able to run the whole suite
against every tier in one process was judged the better trade for a library at
this stage.

### Kernels that are not here yet

UTF-8 validation is the natural next one, since `hp_is_ascii` is already the
fast path that a full validator would sit behind. Base64 decoding is the other
obvious candidate for an ingestion pipeline. Both are larger pieces of work than
anything currently in the repository, mostly in the number of edge cases rather
than the vector code.

### The hex encoder is 128 bit at every tier

A 256 bit version has to repair the lane crossing that `vpunpcklbw` introduces
with a `vpermq`, and on the buffer sizes this library targets the extra shuffle
gives most of the gain back. It is written up in
[docs/DESIGN.md](docs/DESIGN.md). Left as it is deliberately, and the benchmark
output labels the two columns as sharing one kernel so the table is not read as
claiming otherwise.

### The CRC is single threaded

Splitting a large buffer across cores and stitching the results uses exactly the
same Galois field argument the three way pipeline already relies on, so the
arithmetic is present and tested. Nothing in this library spawns threads, and
deciding how it should interact with a caller's thread pool is a design question
rather than a coding one.
