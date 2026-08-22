#!/usr/bin/env python3
"""Generate the constant tables used by the CRC-32C kernels.

Three tables come out of this script.

``hp_crc32c_byte_table``
    The ordinary 256 entry byte at a time table used by the portable C
    reference implementation.

``hp_crc32c_zeros_short`` and ``hp_crc32c_zeros_long``
    Operators that advance a CRC register over a run of SHORT or LONG zero
    bytes without touching memory. The three way pipelined assembly kernel
    needs these to stitch its three independent CRC registers back together.

A CRC is a remainder in GF(2)[x] modulo the generator polynomial, so appending
n zero bytes to a message is multiplication by x^(8n) modulo that polynomial.
That map is linear over GF(2), so it can be written as a 32 by 32 bit matrix.
Repeated squaring builds the matrix for any power of two length in log time,
and flattening it into four 256 entry lookup tables turns applying it into four
loads and three exclusive ors.

The script checks its own output against a direct CRC over real zero bytes and
against the published CRC-32C check value before writing anything, so a silent
arithmetic slip cannot reach the generated file.
"""

import argparse
import pathlib
import random
import sys

# CRC-32C (Castagnoli) generator polynomial 0x1EDC6F41 in reflected form.
POLY = 0x82F63B78

# Block sizes used by the pipelined kernel. Both must be powers of two and
# multiples of eight, and both must match the constants in src/asm/crc32c.S.
SHORT_BLOCK = 256
LONG_BLOCK = 8192


def byte_table():
    """The classic 256 entry reflected CRC-32C table."""
    table = []
    for n in range(256):
        crc = n
        for _ in range(8):
            crc = (crc >> 1) ^ (POLY if crc & 1 else 0)
        table.append(crc)
    return table


def crc_raw(crc, data, table):
    """Advance a raw CRC register over data. No input or output inversion."""
    for byte in data:
        crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
    return crc


def gf2_matrix_times(matrix, vec):
    """Multiply a 32 by 32 GF(2) matrix by a 32 bit column vector."""
    total = 0
    index = 0
    while vec:
        if vec & 1:
            total ^= matrix[index]
        vec >>= 1
        index += 1
    return total


def gf2_matrix_square(matrix):
    """Square a GF(2) matrix, which doubles the run length it represents."""
    return [gf2_matrix_times(matrix, matrix[n]) for n in range(32)]


def zeros_operator(length):
    """Build the matrix that advances a CRC over `length` zero bytes.

    `length` must be a power of two. The seed matrix is the operator for a
    single zero bit, and each squaring doubles the number of bits covered.
    """
    if length <= 0 or (length & (length - 1)) != 0:
        raise ValueError("length must be a positive power of two")

    odd = [0] * 32
    odd[0] = POLY
    row = 1
    for n in range(1, 32):
        odd[n] = row
        row <<= 1

    even = gf2_matrix_square(odd)   # two zero bits
    odd = gf2_matrix_square(even)   # four zero bits

    # The next squaring reaches eight zero bits, one byte, so from here each
    # squaring consumes one bit of the byte count.
    while True:
        even = gf2_matrix_square(odd)
        length >>= 1
        if length == 0:
            return even
        odd = gf2_matrix_square(even)
        length >>= 1
        if length == 0:
            return odd


def zeros_tables(length):
    """Flatten the zeros operator into four byte indexed lookup tables."""
    operator = zeros_operator(length)
    return [
        [gf2_matrix_times(operator, n << (8 * k)) for n in range(256)]
        for k in range(4)
    ]


def apply_zeros(tables, crc):
    """Apply a flattened zeros operator to a raw CRC register."""
    return (
        tables[0][crc & 0xFF]
        ^ tables[1][(crc >> 8) & 0xFF]
        ^ tables[2][(crc >> 16) & 0xFF]
        ^ tables[3][(crc >> 24) & 0xFF]
    )


def self_check(table, short_tables, long_tables):
    """Refuse to emit tables that do not reproduce a direct computation."""
    crc = crc_raw(0xFFFFFFFF, b"123456789", table) ^ 0xFFFFFFFF
    if crc != 0xE3069283:
        raise SystemExit("byte table fails the CRC-32C check value")

    rng = random.Random(20260822)
    for length, tables in ((SHORT_BLOCK, short_tables), (LONG_BLOCK, long_tables)):
        zeros = bytes(length)
        for _ in range(16):
            start = rng.getrandbits(32)
            expected = crc_raw(start, zeros, table)
            if apply_zeros(tables, start) != expected:
                raise SystemExit(
                    "zeros operator for %d bytes disagrees with a direct CRC" % length
                )

    # A three way split has to recombine into the same CRC as one pass.
    payload = bytes(rng.getrandbits(8) for _ in range(3 * LONG_BLOCK))
    one_pass = crc_raw(0xFFFFFFFF, payload, table)
    a = crc_raw(0xFFFFFFFF, payload[:LONG_BLOCK], table)
    b = crc_raw(0, payload[LONG_BLOCK:2 * LONG_BLOCK], table)
    c = crc_raw(0, payload[2 * LONG_BLOCK:], table)
    combined = apply_zeros(long_tables, apply_zeros(long_tables, a) ^ b) ^ c
    if combined != one_pass:
        raise SystemExit("three way recombination does not match a single pass")


def format_rows(values, indent, per_line=8):
    lines = []
    pad = " " * indent
    for i in range(0, len(values), per_line):
        chunk = values[i:i + per_line]
        lines.append(pad + " ".join("0x%08XU," % v for v in chunk))
    return "\n".join(lines)


def render(table, short_tables, long_tables):
    out = []
    out.append("/*")
    out.append(" * Generated by tools/gen_crc32c_tables.py. Do not edit by hand.")
    out.append(" *")
    out.append(" * Regenerate with:")
    out.append(" *     python3 tools/gen_crc32c_tables.py --output src/crc32c_tables.c")
    out.append(" *")
    out.append(" * CI regenerates this file and fails if the result differs, so the")
    out.append(" * constants below always trace back to the script that built them.")
    out.append(" */")
    out.append('#include "crc32c_tables.h"')
    out.append("")
    out.append("const uint32_t hp_crc32c_byte_table[256] = {")
    out.append(format_rows(table, 4))
    out.append("};")
    out.append("")
    for name, tables in (
        ("hp_crc32c_zeros_short", short_tables),
        ("hp_crc32c_zeros_long", long_tables),
    ):
        out.append("const uint32_t %s[4][256] = {" % name)
        for k, sub in enumerate(tables):
            out.append("    {")
            out.append(format_rows(sub, 8))
            out.append("    }," if k < 3 else "    }")
        out.append("};")
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def main():
    parser = argparse.ArgumentParser(description="generate CRC-32C constant tables")
    parser.add_argument("--output", required=True, help="path of the C file to write")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non zero if the file on disk differs from freshly generated output",
    )
    args = parser.parse_args()

    table = byte_table()
    short_tables = zeros_tables(SHORT_BLOCK)
    long_tables = zeros_tables(LONG_BLOCK)
    self_check(table, short_tables, long_tables)

    text = render(table, short_tables, long_tables)
    path = pathlib.Path(args.output)

    if args.check:
        if not path.exists():
            print("%s does not exist" % path, file=sys.stderr)
            return 1
        current = path.read_text(encoding="utf-8")
        if current != text:
            print("%s is stale, rerun the generator" % path, file=sys.stderr)
            return 1
        print("%s is up to date" % path)
        return 0

    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("wrote %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
