#!/usr/bin/env bash
set -euo pipefail

RARZ="zig-out/bin/rarz"
errors=0

# Generate a test archive
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "hello rarz" > "$tmpdir/hello.txt"
echo "world" > "$tmpdir/world.txt"

# Create archive with official rar (store mode, RAR5 format)
(cd "$tmpdir" && rar a -m0 -ma5 test.rar hello.txt world.txt) >/dev/null 2>&1

# Test: rarz t
if ! "$RARZ" t "$tmpdir/test.rar" >/dev/null 2>&1; then
	echo "FAIL: rarz t should succeed on valid archive"
	((errors++))
fi

# Test: rarz test (long form)
if ! "$RARZ" test "$tmpdir/test.rar" >/dev/null 2>&1; then
	echo "FAIL: rarz test (long form) should succeed"
	((errors++))
fi

# Test: rarz t output contains VALID
output=$("$RARZ" t "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"VALID"* ]]; then
	echo "FAIL: rarz t should report VALID"
	((errors++))
fi

# Test: rarz l
output=$("$RARZ" l "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"hello.txt"* ]]; then
	echo "FAIL: rarz l should list hello.txt"
	((errors++))
fi

# Test: rarz list (long form)
output=$("$RARZ" list "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"world.txt"* ]]; then
	echo "FAIL: rarz list should list world.txt"
	((errors++))
fi

# Test: rarz v (verbose list)
output=$("$RARZ" v "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"Unpacked"* ]]; then
	echo "FAIL: rarz v should show verbose header"
	((errors++))
fi
if [[ "$output" != *"hello.txt"* ]]; then
	echo "FAIL: rarz v should list hello.txt"
	((errors++))
fi

# Test: rarz list-verbose (long form)
output=$("$RARZ" list-verbose "$tmpdir/test.rar" 2>&1)
if [[ "$output" != *"Packed"* ]]; then
	echo "FAIL: rarz list-verbose should show Packed column"
	((errors++))
fi

# Test: rarz x (extract)
mkdir "$tmpdir/out"
if "$RARZ" x "$tmpdir/test.rar" "$tmpdir/out" >/dev/null 2>&1; then
	# Check extracted files exist and match
	if [ ! -f "$tmpdir/out/hello.txt" ]; then
		echo "FAIL: hello.txt not extracted"
		((errors++))
	elif [ "$(cat "$tmpdir/out/hello.txt")" != "hello rarz" ]; then
		echo "FAIL: hello.txt content mismatch"
		((errors++))
	fi

	if [ ! -f "$tmpdir/out/world.txt" ]; then
		echo "FAIL: world.txt not extracted"
		((errors++))
	elif [ "$(cat "$tmpdir/out/world.txt")" != "world" ]; then
		echo "FAIL: world.txt content mismatch"
		((errors++))
	fi
else
	echo "FAIL: rarz x should succeed on store archive"
	((errors++))
fi

# Test: rarz extract (long form)
mkdir "$tmpdir/out2"
if ! "$RARZ" extract "$tmpdir/test.rar" "$tmpdir/out2" >/dev/null 2>&1; then
	echo "FAIL: rarz extract (long form) should succeed"
	((errors++))
fi

# Test: rarz a (should be stubbed)
if "$RARZ" a "$tmpdir/new.rar" "$tmpdir/hello.txt" 2>/dev/null; then
	echo "FAIL: rarz a should exit non-zero (not yet implemented)"
	((errors++))
fi

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors tests"
	exit 1
fi

echo "PASS: test_commands.sh"
