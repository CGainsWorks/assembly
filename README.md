# hotpath

Hand written x86-64 assembly kernels for the passes an ingestion pipeline makes
over every byte it accepts, with run time CPU dispatch, a plain C ABI and a test
suite built around not trusting the assembly.

A collector that accepts a batch of log lines usually has to confirm the batch
arrived intact, count the records in it, check the encoding and record a
fingerprint before it can do anything useful with the contents. That is four
passes over the same bytes, none of which the customer is paying for. They are
also the passes a compiler is worst at, because each one is a whole buffer
reduction that maps onto two or three vector instructions the compiler will not
reach for on its own.

On the development machine, with a 64 KiB batch, replacing those passes with the
kernels in this repository gives:

| pass | portable C | this library | speedup |
| --- | ---: | ---: | ---: |
| CRC-32C integrity check | 0.49 GB/s | 22.44 GB/s | 46x |
| count records by newline | 1.82 GB/s | 110.37 GB/s | 61x |
| find a delimiter | 1.62 GB/s | 50.53 GB/s | 31x |
| validate 7-bit ASCII | 3.54 GB/s | 126.59 GB/s | 36x |
| hex encode a digest | 1.40 GB/s | 21.77 GB/s | 16x |

Both columns are the same build with the same compiler and the same flags on the
same machine. The only difference is which dispatch tier is installed. Full
tables across seven buffer sizes are in [docs/BENCHMARKS.md](docs/BENCHMARKS.md),
along with a built in read on the measurement noise floor.

## What is in here

Five kernels, each with a portable C reference and one or more assembly
implementations:

| entry point | what it does | instructions that carry it |
| --- | --- | --- |
| `hp_crc32c` | CRC-32C, the Castagnoli polynomial | `crc32`, three way pipelined |
| `hp_count_byte` | counts occurrences of a byte | `vpcmpeqb`, `vpsubb`, `vpsadbw` |
| `hp_find_byte` | first occurrence of a byte, like `memchr` | `vpcmpeqb`, `vpmovmskb`, `bsf` |
| `hp_is_ascii` | is every byte below 0x80 | `vpor`, `vpmovmskb` |
| `hp_hex_encode` | lowercase hex, two chars per byte | `pshufb`, `punpcklbw` |

Plus a CPUID layer that decides at run time which of them a given machine may
use, and `hpscan`, a small command line tool that runs the whole pipeline over a
file so the library can be pointed at real data in one command.

## Building and running

Nothing beyond a C compiler is needed. The kernels are `.S` files in Intel
syntax, which gcc and clang both hand to their own assembler after running the
preprocessor, so there is no separate assembler to install.

```bash
make && make check
```

`make check` regenerates the CRC constant tables and compares them with the
checked in copy, runs the three test programs against every dispatch tier the
machine supports, confirms the shared library did not end up asking for an
executable stack, reads the expected instructions back out of the compiled
archive, and finishes with an end to end run against tools that share no code
with this project.

Other targets:

```bash
make bench          # full throughput tables, writes markdown to stdout
make sanitize       # rebuild and retest under AddressSanitizer and UBSan
make demo           # the end to end check on its own
make CC=clang check # the same, through clang
```

To point it at a file:

```bash
./build/hpscan /var/log/syslog
```

```
/var/log/syslog
  bytes       : 19313600
  lines       : 200000
  ascii clean : yes
  crc32c      : 0x56797204
  fingerprint : 567972046c3dc8d7
  backend     : avx2
  throughput  : 4.94 GB/s over 1 pass(es) of three scans
```

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

Link against `build/libhotpath.a` or `build/libhotpath.so`. The full interface
is in [include/hotpath.h](include/hotpath.h).

## How the right kernel gets chosen

One binary has to run on a machine without AVX2 and still reach full speed on
one with it, otherwise the problem is pushed onto whoever deploys the software.
So the public entry points are thin wrappers over a table of function pointers,
filled once from CPUID before `main` runs.

Three tiers exist. `baseline` is portable C and runs anywhere. `sse42` adds the
CRC32 instruction and the `pshufb` hex encoder. `avx2` vectorises the counting
and scanning kernels as well.

A CPU reporting AVX2 is not on its own enough. The operating system also has to
be preserving the upper halves of the YMM registers across a context switch, so
XCR0 is consulted through `XGETBV` before the AVX2 tier is allowed, and `XGETBV`
itself is only executed once CPUID has confirmed `OSXSAVE`. Getting this wrong
does not produce a crash, it produces silently corrupted results on a machine
somebody else owns.

Setting `HOTPATH_BACKEND` to `baseline`, `sse42` or `avx2` overrides the choice
at start up. CI uses it to prove the override works, and the test programs walk
every supported tier from inside the process, so the portable paths are covered
on the same run as the vector ones.

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

**The build is checked for the things that go wrong specifically because there is
assembly in it.** Hand written `.S` files are the usual reason a shared object
ends up requesting an executable stack, so every kernel carries a
`.note.GNU-stack` marker and `make check` confirms it survived into the linked
object. A build that quietly lost the assembly would still pass every functional
test, because the portable references would answer for it, so `make check` also
reads the expected instructions back out of the compiled archive.

## Layout

```
include/hotpath.h      public interface
src/cpu.c              CPUID decoding and the dispatch table
src/asm/cpuid.S        CPUID and XGETBV, which need rbx preserved
src/asm/crc32c.S       three way pipelined CRC-32C
src/asm/bytes_avx2.S   count, find and ASCII validation
src/asm/hex_ssse3.S    hex encoding
src/ref/               portable C references for every kernel
src/crc32c_tables.c    generated, see tools/gen_crc32c_tables.py
tests/                 known answers, differential sweep, guard pages
bench/bench.c          throughput harness
tools/hpscan.c         command line front end
scripts/demo.sh        end to end check against wc and Python
```

[docs/DESIGN.md](docs/DESIGN.md) covers why each kernel is shaped the way it is,
including the Galois field argument behind the three way CRC.

## Limitations

The AVX-512 tier is absent, there is no ARM port, and the benchmark numbers come
from a shared desktop rather than a quiet machine. Every one of those is a
consequence of the hardware available for this work, and each is written up with
what it would take to close in [LIMITATIONS.md](LIMITATIONS.md).

## Licence

MIT. See [LICENSE](LICENSE).
