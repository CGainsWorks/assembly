#!/usr/bin/env python3
"""Compute the CRC-32C of a file, bit by bit, in pure Python.

This exists to check the compiled library from outside itself. It shares no
code, no tables and no language with the assembly kernels, and it works one bit
at a time straight from the polynomial, so agreement between this and hpscan is
real evidence rather than two copies of the same idea agreeing with each other.

It is slow on purpose. Use it on sample files, not on production volumes.
"""

import argparse
import sys

# CRC-32C (Castagnoli) generator polynomial 0x1EDC6F41 in reflected form.
POLY = 0x82F63B78


def crc32c(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ POLY
            else:
                crc >>= 1
    return crc ^ 0xFFFFFFFF


def main():
    parser = argparse.ArgumentParser(
        description="print the CRC-32C of a file as eight hex digits"
    )
    parser.add_argument("path", help="file to read, or - for standard input")
    args = parser.parse_args()

    if args.path == "-":
        data = sys.stdin.buffer.read()
    else:
        with open(args.path, "rb") as handle:
            data = handle.read()

    print("%08X" % crc32c(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
