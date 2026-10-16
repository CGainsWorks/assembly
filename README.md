# hotpath

[![ci](https://github.com/CGainsWorks/assembly/actions/workflows/ci.yml/badge.svg)](https://github.com/CGainsWorks/assembly/actions/workflows/ci.yml)

Hand written x86-64 assembly kernels for the passes an ingestion pipeline makes
over every byte it accepts, with run time CPU dispatch, a plain C ABI and a test
suite built around not trusting the assembly.

A collector that accepts a batch of log lines usually has to confirm the batch
arrived intact, count the records in it, check the encoding and record a
fingerprint before it can do anything useful with the contents. That is four
passes over the same bytes, none of which the customer is paying for, and each is
a whole buffer reduction that maps onto two or three vector instructions.

## How it compares

Each kernel is measured against the fastest thing that does the same job: the
same C rebuilt with `-O3 -march=native`, and where one exists, an established
library. With a 64 KiB batch, on an AMD Ryzen 7 5700X (Zen 3) under WSL2, gcc
11.4, on a desktop that was busy with other work at the time:

| pass | fastest baseline | baseline | hotpath | hotpath vs baseline |
| --- | --- | ---: | ---: | ---: |
| CRC-32C integrity check | google/crc32c 1.1.2 | 27.10 GB/s | 21.55 GB/s | **0.80x** |
| count records by newline | C, `-O3 -march=native` | 4.90 GB/s | 86.73 GB/s | 17.7x |
| find a delimiter | glibc 2.35 `memchr` | 92.11 GB/s | 50.58 GB/s | **0.55x** |
| validate 7-bit ASCII | simdutf 9.2.1 | 81.27 GB/s | 93.55 GB/s | 1.15x, within noise |
| hex encode a digest | C, `-O3 -march=native` | 1.07 GB/s | 13.62 GB/s | 12.8x |

Two of the five lose. glibc's `memchr` is itself hand written vector assembly and
is 1.5 to 1.9 times faster than `hp_find_byte` from 1 KiB upwards, and
google/crc32c is between a tenth and a quarter faster than `hp_crc32c` from 1 KiB
upwards. The ASCII check is clearly ahead of simdutf at 1 and 4 KiB and level with
it, within the noise of this run, from 64 KiB up. The byte count and the hex
encoder have no library to compare with, and compiled C, even with
`-march=native`, is far behind on both.

Against this project's own C at `-O2`, which is what earlier versions of this
README quoted, every kernel looks between 16 and about 100 times faster at
64 KiB. That comparison is correct but flattering, which is why it is no longer
the headline. Full tables across seven buffer sizes, every column, and the noise
floor of the run are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md). The numbers are
true of that machine only.

## What is in here

Five kernels, each with a portable C reference and one or more assembly
implementations:

| entry point | what it does | instructions that carry it | AVX-512 version |
| --- | --- | --- | --- |
| `hp_crc32c` | CRC-32C, the Castagnoli polynomial | `crc32`, three way pipelined | no, bound by `crc32` |
| `hp_count_byte` | counts occurrences of a byte | `vpcmpeqb`, `vpsubb`, `vpsadbw` | `k` masks and `popcnt` |
| `hp_find_byte` | first occurrence of a byte, like `memchr` | `vpcmpeqb`, `vpmovmskb`, `bsf` | `korq`, `kortestq` |
| `hp_is_ascii` | is every byte below 0x80 | `vpor`, `vpmovmskb` | `vpord`, `vpmovb2m` |
| `hp_hex_encode` | lowercase hex, two chars per byte | `pshufb`, `punpcklbw` | no, shared SSSE3 kernel |

Plus a CPUID layer that decides at run time which of them a given machine may
use, and `hpscan`, a small command line tool that runs the whole pipeline over a
file so the library can be pointed at real data in one command.

## Building and running

Nothing beyond a C compiler is needed. The kernels are `.S` files in Intel
syntax for the GNU assembler: gcc runs the preprocessor and hands them to GNU as,
and clang assembles them with its integrated assembler, so there is no separate
assembler to install. CI pins both (gcc 13 with binutils 2.42, and clang 18).

```bash
make && make check
```

`make check` regenerates the CRC constant tables and compares them with the
checked in copy, runs the four test programs against every dispatch tier the
machine supports, confirms the shared library did not end up asking for an
executable stack, reads the expected instructions back out of the compiled
archive, checks that the shared library exports the documented interface and
nothing else, and finishes with an end to end run against tools that share no
code with this project.

Other targets:

```bash
make test-tiers      # the suite once per tier, each tier on its own
make bench           # throughput against compiled C and libc memchr
make bench-full      # also simdutf and google/crc32c, fetched at pinned versions
make sanitize        # rebuild and retest under AddressSanitizer and UBSan
make demo            # the end to end check on its own
make CC=clang check  # the same, through clang
make RUNNER="sde64 -skx -ptr-raise --" test-tiers   # every tier under Intel SDE
```

On Windows, from an MSYS2 UCRT64 or CLANG64 shell, the same `make check` builds a
static library with MinGW-w64 and runs the suite under the Windows x64 calling
convention. Linux and Windows are the two supported targets; both are x86-64.

To point it at a file:

```bash
./build/hpscan sample.log
```

```
sample.log
  bytes       : 19313600
  lines       : 200000
  ascii clean : yes
  crc32c      : 0x56797204
  fingerprint : 567972046c3dc8d7
  backend     : avx2
  throughput  : 27.05 GB/s over 1 pass(es) of three scans
```

That is a nineteen megabyte log checksummed, counted and encoding checked in
one command. `make demo` builds exactly that file and verifies the answers.

`./build/hpscan --cpu` reports the detected features and which tiers are live.

## Using it from C

```c
#include "hotpath.h"

uint32_t crc   = hp_crc32c(0, buf, len);      /* chainable, seed with 0 */
size_t   lines = hp_count_byte(buf, len, '\n');
int      ok    = hp_is_ascii(buf, len);
const void *nl = hp_find_byte(buf, len, '\n');

char hex[2 * 8];
hp_hex_encode(hex, digest, 8);                /* writes 2 * len, no NUL */
```

Link against `build/libhotpath.a`, or on Linux `build/libhotpath.so`. The full interface
is in [include/hotpath.h](include/hotpath.h).

## How the right kernel gets chosen

One binary has to run on a machine without AVX2 and still reach full speed on
one with it, otherwise the problem is pushed onto whoever deploys the software.
So the public entry points are thin wrappers over a table of function pointers,
filled once from CPUID before `main` runs.

Four tiers exist. `baseline` is portable C and runs anywhere. `sse42` adds the
CRC32 instruction and the `pshufb` hex encoder. `avx2` vectorises the counting
and scanning kernels as well. `avx512` replaces those three with 512 bit kernels
whose tails are single masked loads instead of scalar loops.

`avx512` is never chosen automatically. It runs in full under Intel SDE in CI but
has never been timed on AVX-512 hardware, and on several Intel parts sustained
512 bit work lowers the clock, so whether it beats `avx2` in a real process is a
measurement still to be made. On an AVX-512 machine the automatic choice is
`avx2` and `avx512` is one environment variable away.

A CPU reporting AVX2 is not on its own enough. The operating system also has to
be preserving the upper halves of the YMM registers across a context switch, so
XCR0 is consulted through `XGETBV` before the AVX2 tier is allowed, and `XGETBV`
itself is only executed once CPUID has confirmed `OSXSAVE`. Getting this wrong
does not produce a crash, it produces silently corrupted results on a machine
somebody else owns.

An AVX-512 tier has the same problem one level up: XCR0 must also report the
opmask and full ZMM state as enabled, which a hypervisor can withhold.

Setting `HOTPATH_BACKEND` to `baseline`, `sse42`, `avx2` or `avx512` overrides
the choice at start up. CI uses it to prove the override works, and the test
programs walk every supported tier from inside the process, so the portable paths
are covered on the same run as the vector ones. `HOTPATH_TEST_TIERS` turns that
walk into a requirement: a listed tier the CPU cannot run fails the test instead
of being skipped.

## Why you should believe the assembly

Assembly is worth writing when the win is this size, and it is worth distrusting
for exactly the same reasons that make it fast. The suite is built around that.

**Every kernel is compared against a portable reference**, over a sweep of
lengths chosen from the boundaries where the code changes strategy: vector
widths, unroll widths, and the 768 and 24576 byte thresholds where the CRC
kernel switches between its single stream, short block and long block paths.
Each length runs at a range of offsets inside a padded buffer, so an alignment
assumption that happens to hold for `malloc` has nowhere to hide.

**The CRC has three independent implementations.** The assembly, a table driven
reference, and a bit at a time reference that depends on nothing but the
polynomial. A corrupted table cannot make the first two agree on a wrong answer
without the third noticing.

**The published check values are tested.** `0xE3069283` for `123456789` is the
CRC-32C check value from the catalogues, and `0x8A9136AA` for thirty two zero
bytes is the first vector in RFC 3720. A checksum that no other program agrees
with is not a checksum.

**No kernel reads or writes outside its buffer, and that is proved rather than
asserted.** A SIMD kernel that finishes its tail with an overlapping load is
faster and, on almost every input, indistinguishable from a correct one. It only
misbehaves when a buffer ends within a few bytes of an unmapped page, which in
production means a rare crash in a library that passed every functional test.
`tests/test_overread.c` maps two pages, revokes all access to the second, and
places the buffer so its last byte is the last byte of the first page, at every
length from zero to a full page. The destination of the hex encoder gets the same
treatment. Before any of that the test reads the guard page itself and requires a
fault, because a mapping that silently failed would otherwise make the whole file
pass while proving nothing.

**The constants are generated, not pasted.** `tools/gen_crc32c_tables.py` derives
the CRC tables from the polynomial, checks them against a direct computation over
real zero bytes and against the published check value, and only then writes the
file. CI regenerates it and fails on any difference.

**The end to end check leaves the project.** `scripts/demo.sh` builds a log file,
scans it, and compares the line count against `wc` and the checksum against a
pure Python bit at a time implementation. Two implementations of mine agreeing is
weak evidence. Agreement with `wc` and with a different language is not.

**Every tier runs on a CPU that has exactly its features.** A runner that has
AVX2 can only prove the AVX2 tier and below, and one without AVX-512 cannot run
the AVX-512 tier at all. CI therefore runs the suite under Intel SDE 10.13.1 on
emulated Merom, Nehalem, Haswell, Skylake server, Ice Lake server and Sapphire
Rapids parts, in chip check mode, where an instruction the emulated part lacks
stops the run. That proves each tier both computes the right answers and stays
inside its own instruction set, and the same job asserts which tiers the CPU
detection offers and chooses on each part, Sierra Forest included. All of this is
emulation: it establishes correctness, not speed.

**The calling convention is checked, not assumed.** `tests/test_abi.c` calls
every kernel of every tier through a small assembly harness that fills each
register the platform says a callee must preserve with a canary and reports any
that come back changed. On Windows that includes `rdi`, `rsi` and `xmm6` to
`xmm15`, which is exactly where a kernel written for System V goes wrong. CI runs
it on Linux and on Windows, with MinGW-w64 gcc and with clang, and runs the
AVX-512 tier under the Windows build of SDE as well.

**The same suite runs on more than one vendor's silicon.** Development and
measurement happened on an AMD Zen 3 desktop. GitHub's hosted runners have
reported Intel Xeon and several AMD EPYC generations, so the native tiers are
exercised on microarchitectures the author never touched, under both gcc and
clang. When a runner happens to have AVX-512 the native jobs run the `avx512`
tier as well, but only SDE makes that a guarantee.

**The build is checked for the things that go wrong specifically because there is
assembly in it.** Hand written `.S` files are the usual reason a shared object
ends up requesting an executable stack, so every kernel carries a
`.note.GNU-stack` marker and `make check` confirms it survived into the linked
object. A build that quietly lost the assembly would still pass every functional
test, because the portable references would answer for it, so `make check` also
reads the expected instructions back out of the compiled archive.

## Layout

```
include/hotpath.h        public interface
src/cpu.c                CPUID decoding and the dispatch table
src/asm/hp_asm.h         entry and exit macros for System V and Windows x64
src/asm/cpuid.S          CPUID and XGETBV, which need rbx preserved
src/asm/crc32c.S         three way pipelined CRC-32C
src/asm/bytes_avx2.S     count, find and ASCII validation, AVX2
src/asm/bytes_avx512.S   the same three on AVX-512 with masked tails
src/asm/hex_ssse3.S      hex encoding
src/ref/                 portable C references for every kernel
src/crc32c_tables.c      generated, see tools/gen_crc32c_tables.py
tests/                   known answers, differential sweep, guard pages,
                         calling convention checker
bench/bench.c            throughput harness against compiled C and libraries
bench/fetch-baselines.sh pinned simdutf and google/crc32c for bench-full
tools/hpscan.c           command line front end
scripts/demo.sh          end to end check against wc and Python
```

[docs/DESIGN.md](docs/DESIGN.md) covers why each kernel is shaped the way it is,
including the Galois field argument behind the three way CRC.

## Limitations

The AVX-512 tier has been verified under emulation but never timed, there is no
ARM port, Windows means MinGW-w64 and a static library, and the benchmark numbers
come from a shared desktop rather than a quiet machine. Each is written up with
what it would take to close in [LIMITATIONS.md](LIMITATIONS.md), and the current
state of the work is in [STATUS.md](STATUS.md).

## Licence

MIT. See [LICENSE](LICENSE).
