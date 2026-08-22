# Limitations and open work

Everything here is a real boundary of the current work rather than a wish list.
Each entry says what is missing, why it is missing, and what closing it would
take. The first group exists because of the hardware available for this project,
the second because of scope.

## Constrained by available hardware

Development and measurement happened on one machine: an AMD Ryzen 7 5700X, Zen 3,
eight cores, running Ubuntu 22.04 under WSL2 on Windows 11. No other hardware was
available, and several things follow from that.

### No AVX-512 tier

Zen 3 has no AVX-512, so an AVX-512 tier could not be executed once, let alone
tested or measured. GitHub's hosted runners do not guarantee it either, so CI
could not stand in.

The dispatch layer is already shaped to take one. `hp_backend_t` is an ordered
enum, `hp_backend_supported` is the single place that decides what a machine may
run, and the dispatch table is one row per tier, so adding `HP_BACKEND_AVX512`
means adding a row and a feature test rather than restructuring anything.

What it would take: a Zen 4, Zen 5 or Ice Lake or later Xeon machine. The
kernels worth writing first are `hp_count_byte` and `hp_is_ascii` on 512 bit
registers with `k` mask registers replacing the scalar tails, and a `vpermb`
based hex encoder, which is the one case where AVX-512 VBMI does something
128 bit SSSE3 genuinely cannot. Note that on several Intel parts sustained
512 bit work lowers the clock, so the tier would need measuring before being
enabled by default rather than being assumed faster.

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

### No Windows or MSVC support

Only the System V AMD64 ABI is implemented. The Microsoft x64 ABI passes
arguments in different registers and, more awkwardly for these kernels, makes
`xmm6` through `xmm15` callee saved. No MSVC or MinGW toolchain was installed on
the development machine, so a second ABI could have been written but not built or
run, and untested assembly is worse than absent assembly.

What it would take: MSVC or a MinGW cross toolchain, plus a Windows CI job. The
kernels themselves stay within `xmm0` to `xmm5` and `ymm0` to `ymm4`, so the
register save requirement happens to be satisfied already. The work is the
argument register mapping and a build path, not the kernels.

### Benchmark numbers come from a contended desktop

The machine that produced [docs/BENCHMARKS.md](docs/BENCHMARKS.md) was running a
browser and other work at the time, at a load average above two. There was no
access to a quiet machine with boost disabled, cores isolated and the governor
pinned, which is what performance numbers of this kind normally deserve.

Three things were done about it rather than ignoring it. Tiers are timed in
rotation rather than one after another, so drift over the run is shared between
columns instead of landing on one. The fastest run of several is kept rather than
the mean, since contention only ever makes a run slower. And two kernels are
shared between the `sse42` and `avx2` tiers, so those two columns run identical
code and the gap between them is a direct read on the noise floor, currently a
few percent.

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
