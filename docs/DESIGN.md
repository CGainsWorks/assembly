# Design notes

Why each kernel is shaped the way it is, and which choices were deliberate
trade-offs rather than the only option.

## Why assembly at all

Compilers vectorise loops they can prove are safe and profitable. Every kernel
here is a whole buffer reduction with a data dependent exit or an accumulator
that needs draining before it overflows. gcc 11 at `-O2` vectorises none of them.
At `-O3 -march=native` the tables in [BENCHMARKS.md](BENCHMARKS.md) show the
ASCII check coming within reach of the assembly, while the byte count stays more
than ten times behind on buffers of 1 KiB and up, and the CRC and the hex encoder
gain little or nothing.

The fairer test is against libraries that already do the job, and there the
picture is mixed. glibc's `memchr` beats `hp_find_byte` and google/crc32c beats
`hp_crc32c` on the development machine, both by margins larger than the noise.
The case for this code rests on the byte count and the hex encoder, where nothing
off the shelf competes, on the ASCII check, which is level with simdutf, and on
having all five behind one dispatch layer and one test suite.

Intrinsics were the obvious alternative. They were not used for the CRC kernel
because the three way pipeline depends on the compiler keeping three specific
values in three specific registers across a tight loop, which is a request rather
than a guarantee. For the byte kernels intrinsics would have been close to
equivalent, and keeping all five in the same language and the same file layout
was worth more than the small convenience.

## CRC-32C: latency, and the Galois field argument

`crc32` consumes eight bytes per issue but feeds its own result straight back in.
On every Intel and AMD part that implements it the instruction has a throughput
of one per cycle and a latency of three, so a single stream runs at eight bytes
every three cycles and leaves two thirds of the unit idle.

The fix is to split the buffer into three blocks and run three independent CRC
registers, which fills the pipeline. The problem is that three CRCs over three
blocks are not a CRC over the concatenation, so they have to be stitched.

A CRC is the remainder of the message polynomial modulo the generator, over
GF(2). Appending n zero bytes to a message multiplies its remainder by x^(8n).
That map is linear over GF(2), so it can be written as a 32 by 32 bit matrix, and
advancing a CRC register across a block of known length needs no memory traffic
at all. Repeated squaring builds the matrix for any power of two length, and
flattening it into four 256 entry tables turns applying it into four loads and
three exclusive ors.

So for three blocks of length L:

```
crc = shift_L(shift_L(crc0) xor crc1) xor crc2
```

Two block sizes are used, 8192 and 256 bytes, both powers of two as the matrix
construction requires. The long one amortises the stitching over a large buffer,
the short one keeps mid sized buffers off the single stream path, and the
remainder falls through to eight byte and then one byte steps.

The constants come from `tools/gen_crc32c_tables.py`, which checks each operator
against a direct CRC over real zero bytes, checks the three way recombination
identity end to end, and checks the published check value, all before it writes
anything. Getting the maths wrong is the main risk in this kernel, so the
generator refuses to emit tables it cannot verify, and CI regenerates the file
and fails on any difference.

The measured result is around 21 GB/s at 64 KiB against 0.49 GB/s for a byte at
a time table. google/crc32c 1.1.2, which uses the same instruction, reaches about
27 GB/s on the same machine and is ahead from 1 KiB upwards, by between a tenth
and a quarter; where that comes from has not been worked out yet. See [BENCHMARKS.md](BENCHMARKS.md).

### What was left out

Folding with `PCLMULQDQ` would let the three streams be combined without any
lookup tables, and would also handle block sizes that are not powers of two. It
is the technique used by the widest CRC implementations. It was not done because
the table approach already reaches the pipeline limit of the `crc32` instruction,
so the remaining gain is in the stitching only, which is a small fraction of the
time on the buffer sizes this library targets.

## count_byte: draining the accumulator

`vpcmpeqb` produces 0x00 or 0xFF per lane, so subtracting its result from an
accumulator with `vpsubb` adds one per match. That accumulator is eight bits per
lane, so a lane saturates after 255 blocks and the count silently goes wrong.

The loop is therefore two levels. The inner one processes four 32 byte vectors
per iteration into a byte accumulator, capped at 63 iterations, since 63 times
four is 252 and stays under the ceiling. The outer one drains with `vpsadbw`,
which sums groups of eight bytes into 64 bit lanes in a single instruction, and
accumulates those into a wide running total.

The cap is the kind of detail that is easy to get slightly wrong and hard to
notice, because it only shows up on buffers above eight kilobytes with a very
high match density. `tests/test_differential.c` runs a sweep with sixty percent
of bytes forced to the needle for exactly this reason.

Four vectors per iteration rather than one is worth little on this machine, since
the dependency chain through `vpsubb` is one cycle and the loop is bound by load
throughput either way. It is there because it costs nothing and helps on cores
with a narrower front end.

## find_byte: one branch per 32 bytes

`vpmovmskb` collapses a comparison to one bit per byte, so a whole 32 byte window
is tested with a single `test` and a single branch. On a hit, `bsf` gives the
index directly.

glibc's AVX2 `memchr` is faster than this from 1 KiB upwards, by 1.5 to 1.9
times on the development machine. It tests several vectors per branch where
this kernel tests one, which is the same idea the AVX-512 version here uses with
`korq`, and is the obvious next change to the AVX2 kernel.

`bsf` rather than `tzcnt` is deliberate. `tzcnt` needs BMI1, and using it would
make the AVX2 tier require a feature that has nothing to do with AVX2. The two
have identical behaviour when the input is non-zero, which is guaranteed here
because the branch was taken. `bsf` is slower on some parts, but it executes once
per call rather than once per iteration.

## is_ascii: no branching on data

Only the sign bit of each byte matters, so the whole buffer folds into one
register with `vpor` and gets inspected once at the end with `vpmovmskb`. The
loop has no data dependent branch at all, which means no branch mispredictions
regardless of the input.

An early exit on the first high byte was considered and rejected. It would help
on input that fails immediately and hurt on input that passes, and the case this
library is built for is a validation pass over data that is almost always valid.

## hex_encode: pshufb as a nibble lookup

The nibble to character map has exactly sixteen entries, which is exactly what
`pshufb` indexes. Sixteen input bytes become thirty two output characters per
iteration with two shuffles and two interleaves and no branching.

Extracting the high nibbles uses the standard trick of shifting the 16 bit lanes
right by four and masking with 0x0F. Shifting words rather than bytes pulls bits
in from the neighbouring byte, and the mask removes exactly those, which is why
the sequence is correct despite looking as though it should not be.

`punpcklbw` and `punpckhbw` then interleave the high and low nibble characters
back into order.

### Why this is 128 bit at every tier

A 256 bit version is possible but `vpunpcklbw` works within 128 bit lanes, so the
result comes out interleaved wrongly across the two halves and needs a `vpermq`
to repair. On the buffer sizes this library targets that extra shuffle gives most
of the gain back, so the same SSSE3 kernel serves the `sse42` and `avx2` tiers.

This has a useful side effect. Two columns of the benchmark table run identical
code, so the gap between them is a direct measurement of the noise floor, which
is what makes the rest of the table readable on a machine that is not quiet. The
benchmark output says so under each heading.

## Tails never read past the buffer

No kernel finishes with an overlapping vector load or a load that reads up to the
end of the containing page. Both are common, both are faster, and both read bytes
the caller did not offer. That is invisible until a buffer ends within a few bytes
of an unmapped page, at which point it becomes a rare crash in somebody else's
process.

Up to AVX2 the tails are therefore scalar, which costs a few cycles per call on
short buffers. The AVX-512 kernels use the one form of short load that is safe: a
masked load, whose masked out bytes the architecture guarantees will not fault.
The mask for a tail of `n` bytes is built with `bzhi` from an all ones register,
and the compare after it is masked as well, since the zeroed lanes would otherwise
match a zero needle.

`tests/test_overread.c` is what makes the promise checkable rather than asserted:
two pages, all access revoked on the second, buffer placed so its last byte is the
last byte of the first page, every length from zero to a full page, every kernel,
every tier. For the AVX-512 tier that runs under Intel SDE with `-ptr-raise`, so
an unmasked read of the guard page arrives as a fault and fails the test. Swapping
one masked tail load for an unmasked one was tried while writing this, and the
test failed on it from a one byte buffer upwards.

## AVX-512 kernels

Three of the five kernels have an AVX-512 version, in `src/asm/bytes_avx512.S`.
The CRC is bound by the `crc32` instruction rather than by vector width, and the
hex encoder is shared for the reason given above, so neither changes.

- **count_byte.** `vpcmpeqb` writes a `k` mask with one bit per byte, so a 64 byte
  block is counted with `kmovq` and `popcnt`. There is no eight bit accumulator,
  so the draining logic that the AVX2 kernel needs disappears. Four blocks per
  iteration keep four independent `popcnt` chains in flight.
- **find_byte.** Four compares per 256 bytes are folded with `korq` into one
  `kortestq` and one branch. On a hit the kernel drops into the 64 byte loop at the
  same address, which finds the block within four iterations, so the hit path
  stays simple.
- **is_ascii.** Two `vpord` accumulators so consecutive loads do not wait on each
  other, folded at the end, and `vpmovb2m` lifts the sign bit of every byte into a
  mask.

Only `zmm16` and up are used. Their upper halves are outside the state that
`vzeroupper` manages, so no SSE transition penalty can follow and no `vzeroupper`
is needed, and `xmm16` to `xmm31` are volatile under the Windows convention as
well as System V.

The tier needs AVX512F, AVX512BW, BMI2 for `bzhi` and POPCNT, and XCR0 has to
report opmask, ZMM_Hi256 and Hi16_ZMM state as enabled. A hypervisor that hides
those bits is the realistic way to get this wrong, and the result would be silent
corruption, so the check is the same shape as the YMM one.

It is not selected automatically. Every instruction in it has executed under
Intel SDE on emulated Skylake server, Ice Lake server and Sapphire Rapids parts,
but none has been timed, because no AVX-512 hardware was available. On several
Intel parts sustained 512 bit work lowers the clock, so whether this tier is
faster than `avx2` in a real process is a measurement, not an assumption. Until
it is measured it is reached through `HOTPATH_BACKEND=avx512` or
`hp_set_backend`.

## Dispatch

The public entry points are thin wrappers over a table of function pointers
filled once from CPUID before `main` runs. One binary then runs correctly on a
machine without AVX2 and reaches full speed on one with it. Building separate
binaries per microarchitecture moves the problem to whoever deploys the software,
and `-march=native` moves it to whoever builds it.

Detecting AVX2 is not sufficient on its own. The operating system also has to be
preserving the upper halves of the YMM registers across a context switch, which
is reported through XCR0 rather than CPUID. `XGETBV` faults with `#UD` unless
`OSXSAVE` is set, so the two have to be read in order, and that ordering is why
`src/asm/cpuid.S` exposes them as two separate functions rather than one.

CPUID itself is in assembly because it clobbers `rbx`, which is callee saved in
both calling conventions, and because inline assembly constraints for that are
famously easy to get wrong under `-fPIC`. The kernel keeps `rbx` in `r11`, which
is volatile under both, rather than pushing it, so no kernel body moves the stack.

CI checks the dispatch decisions themselves, not only the kernels. Under Intel SDE
the CPU detection runs on emulated Merom, Nehalem, Haswell, Sierra Forest, Skylake
server, Ice Lake server and Sapphire Rapids parts, and for each one the job
asserts which tiers are offered and which is chosen. SDE runs in chip check mode,
so a tier that strayed outside its instruction set would stop the run on an
emulated part that lacks the instruction.

`GNU ifunc` would remove the indirect call, which is a measurable share of the
work at 64 bytes. It was not used because it makes forcing a tier from a test
much harder, and running the whole suite against every tier inside one process
was judged worth more for a library at this stage. It is written up in
[../LIMITATIONS.md](../LIMITATIONS.md).

## Register discipline

Every kernel body stays inside registers that are caller saved under both the
System V and the Windows x64 conventions, so none of them has a prologue or an
epilogue of its own. That is not a micro-optimisation, it is what keeps each
kernel short enough to read in one screen and check against the ABI by eye. The
vector registers in use are `xmm0` to `xmm5`, `ymm0` to `ymm4` and `zmm16` and up;
Windows makes `xmm6` to `xmm15` callee saved and none of them is touched.

`tests/test_abi.c` checks this rather than trusting the reading. It calls every
kernel of every tier through `tests/abi_check.S`, which fills each register the
platform says a callee must preserve with a canary and reports any that come back
changed: `rbx`, `rbp` and `r12` to `r15` everywhere, plus `rdi`, `rsi` and `xmm6`
to `xmm15` on Windows. Adding a single `pxor xmm6, xmm6` to the hex encoder makes
the Windows build of that test fail by name.

Every AVX2 exit path runs `vzeroupper` first. Leaving the upper halves of the YMM
registers dirty imposes a transition penalty on whatever SSE code the caller runs
next, and a library that quietly slows down its caller's unrelated code is a
worse neighbour than one that is simply slower.

## Windows x64

The kernels are written once, against System V. On Windows the arguments arrive
in `rcx`, `rdx`, `r8` and `r9`, and `rdi` and `rsi` are callee saved rather than
argument registers. `src/asm/hp_asm.h` handles both with three macros that wrap
every kernel: on entry it saves `rdi` and `rsi` and moves the four argument
registers into their System V positions, and every return restores the two. That
is six instructions in and two out, on a call that already goes through a
function pointer.

The saves are described with `.seh_pushreg` and `.seh_endprologue`, so the Windows
unwinder can walk through a kernel if a fault is ever raised inside one. The guard
page test on Windows depends on exactly that: it recovers from deliberate access
violations with a vectored exception handler.

The build is MinGW-w64, with either gcc and GNU as or clang and its integrated
assembler, and produces a static library. MSVC is not supported: `ml64` does not
read GNU syntax, and maintaining a second copy of every kernel in MASM would
double the code that has to be trusted.
