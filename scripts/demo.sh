#!/bin/sh
#
# End to end check, and a demonstration of what the library is actually for.
#
# A synthetic log file is built, scanned with hpscan, and the answers are
# compared against tools that share no code with this project: wc for the line
# count, and a pure Python bit at a time CRC-32C for the checksum. Agreement
# across a language boundary is what makes this worth running in CI, since the
# unit tests can only ever compare the library against itself.
#
# Usage: sh scripts/demo.sh [path-to-hpscan]

set -eu

HPSCAN="${1:-build/hpscan}"
PYTHON="${PYTHON:-python3}"
# Optional wrapper, for example wine or Intel SDE, set by make demo RUNNER=...
HPSCAN_RUNNER="${HPSCAN_RUNNER:-}"

# Windows binaries write CRLF line endings, which would end up inside every
# field parsed below, so carriage returns are dropped on the way in.
hpscan() {
    $HPSCAN_RUNNER "$HPSCAN" "$@" | tr -d '\r'
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

LOG="$WORK/sample.log"
LINES=200000

echo "building a $LINES line sample log"
awk -v n="$LINES" 'BEGIN {
    for (i = 1; i <= n; i++) {
        printf "2026-08-22T09:%02d:%02dZ host-%03d level=info request_id=%08x latency_ms=%d msg=\"request served\"\n",
               (i % 60), ((i * 7) % 60), (i % 512), (i * 2654435761) % 4294967296, (i % 250) + 1
    }
}' > "$LOG"

BYTES=$(wc -c < "$LOG" | tr -d ' ')
echo "sample is $BYTES bytes"

OUT="$WORK/hpscan.out"
hpscan "$LOG" > "$OUT"
cat "$OUT"

got_lines=$(awk '/^  lines/ {print $3}' "$OUT")
got_bytes=$(awk '/^  bytes/ {print $3}' "$OUT")
got_crc=$(awk '/^  crc32c/ {print $3}' "$OUT" | sed 's/^0x//')
got_ascii=$(awk '/^  ascii clean/ {print $4}' "$OUT")

want_lines=$(wc -l < "$LOG" | tr -d ' ')

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

[ "$got_bytes" = "$BYTES" ] || fail "byte count $got_bytes, wc says $BYTES"
[ "$got_lines" = "$want_lines" ] || fail "line count $got_lines, wc says $want_lines"
[ "$got_ascii" = "yes" ] || fail "the sample is ASCII but hpscan says $got_ascii"

# The Python reference works one bit at a time and is far too slow for twenty
# megabytes, so the cross language check runs on a smaller file of the same
# shape. It is the algorithm being checked, not the volume.
echo "cross checking the checksum against a pure Python implementation"
SMALL="$WORK/small.log"
head -n 2000 "$LOG" > "$SMALL"
hpscan "$SMALL" > "$WORK/small.out"
small_crc=$(awk '/^  crc32c/ {print $3}' "$WORK/small.out" | sed 's/^0x//')
want_crc=$("$PYTHON" tools/crc32c_ref.py "$SMALL")
[ "$small_crc" = "$want_crc" ] || fail "crc32c $small_crc, Python says $want_crc"

# Forcing the portable tier has to give byte for byte identical answers.
echo "re-scanning with the baseline tier"
BASE="$WORK/baseline.out"
hpscan --backend=baseline "$LOG" > "$BASE"
base_crc=$(awk '/^  crc32c/ {print $3}' "$BASE" | sed 's/^0x//')
base_lines=$(awk '/^  lines/ {print $3}' "$BASE")
[ "$base_crc" = "$got_crc" ] || fail "baseline crc32c $base_crc differs from $got_crc"
[ "$base_lines" = "$got_lines" ] || fail "baseline line count differs"

echo "demo passed: line count matches wc, checksum matches Python, tiers agree"
