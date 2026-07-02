#!/usr/bin/env bash
# Regression test for inbox/false-positive-payload-crc32-2026-05-03.md
#
# rarz reports "payload CRC32 mismatch" on a real-world RAR5 archive that
# unrar t says is "All OK". The fixture is a 2.5 KB minimal RAR5 archive
# extracted from the original (containing one m3-compressed entry that
# triggers the decompression bug). See tests/fixtures/rar5_decomp_regression.rar.
set -u

RARZ="zig-out/bin/rarz"
FIXTURE="tests/fixtures/rar5_decomp_regression.rar"

if [[ ! -f "$FIXTURE" ]]; then
	echo "FAIL: regression fixture missing at $FIXTURE"
	exit 1
fi

errors=0
output=$("$RARZ" t "$FIXTURE" 2>&1 || true)

if [[ "$output" == *"payload CRC32 mismatch"* ]]; then
	echo "FAIL: rarz reports false-positive 'payload CRC32 mismatch' on archive that unrar t says is OK"
	echo "Output:"
	echo "$output" | sed 's/^/  /'
	errors=$((errors + 1))
fi

if [[ "$output" != *"Validation: VALID"* ]]; then
	echo "FAIL: rarz did not report Validation: VALID"
	echo "Output:"
	echo "$output" | sed 's/^/  /'
	errors=$((errors + 1))
fi

if (( errors > 0 )); then
	exit 1
fi

echo "PASS: regression payload CRC false-positive test"
