# Design notes

Why each kernel is shaped the way it is, and which choices were deliberate
trade-offs rather than the only option.

## Why assembly at all

Compilers vectorise loops they can prove are safe and profitable. Every kernel
here is a whole buffer reduction with a data dependent exit or an accumulator
that needs draining before it overflows, and gcc at `-O2` reaches for none of
them. The reference implementations in `src/ref` are written to be as friendly to
the vectoriser as plain C can be, with accumulation instead of branching, and the
tables in [BENCHMARKS.md](BENCHMARKS.md) show what the compiler does with that.
The gap is between fifteen and sixty times, which is enough to justify assembly
in a way that a twenty percent gap would not be.

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

The measured result is around 22 GB/s against 0.49 GB/s for a byte at a time
table, on a machine whose single stream ceiling would be roughly a third of that.

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

## Tails are always scalar

No kernel finishes with an overlapping vector load, a masked load or a load that
reads up to the end of the containing page. All three are common, all three are
faster, and all three read bytes the caller did not offer. That is invisible until
a buffer ends within a few bytes of an unmapped page, at which point it becomes a
rare crash in somebody else's process.

The scalar tail costs a few cycles per call on short buffers. `tests/test_overread.c`
is what makes the promise checkable: two pages, all access revoked on the second,
buffer placed so its last byte is the last byte of the first page, every length
from zero to a full page, every kernel, every tier.

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
the System V AMD64 ABI, and because inline assembly constraints for that are
famously easy to get wrong under `-fPIC`.

`GNU ifunc` would remove the indirect call, which is a measurable share of the
work at 64 bytes. It was not used because it makes forcing a tier from a test
much harder, and running the whole suite against every tier inside one process
was judged worth more for a library at this stage. It is written up in
[../LIMITATIONS.md](../LIMITATIONS.md).

## Register discipline

Every kernel stays inside the caller saved registers of the System V AMD64 ABI,
so none of them has a prologue or an epilogue. That is not a micro-optimisation,
it is what keeps each kernel short enough to read in one screen and check against
the ABI by eye.

Every AVX2 exit path runs `vzeroupper` first. Leaving the upper halves of the YMM
registers dirty imposes a transition penalty on whatever SSE code the caller runs
next, and a library that quietly slows down its caller's unrelated code is a
worse neighbour than one that is simply slower.
