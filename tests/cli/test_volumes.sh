#!/usr/bin/env bash
set -euo pipefail

RARZ="zig-out/bin/rarz"
FIXTURES="tests/fixtures"
errors=0

fail() {
	echo "FAIL: $1"
	((errors++))
}

pass() {
	echo "  PASS: $1"
}

# Ensure fixtures exist
if [ ! -f "$FIXTURES/rar5_vol_store.part1.rar" ]; then
	echo "ERROR: No volume fixtures found in $FIXTURES/"
	echo "Run: nix develop -c bash tests/generate_fixtures.sh"
	exit 1
fi

# --- Helper: recreate original test data for comparison ---

origdir=$(mktemp -d)
trap 'rm -rf "$origdir"' EXIT

mkdir -p "$origdir/subdir" "$origdir/empty_dir"
echo "Hello, rarz!" > "$origdir/hello.txt"
printf '\x00\x01\x02\x03\x04\x05\x06\x07' > "$origdir/binary.bin"
echo "nested file" > "$origdir/subdir/nested.txt"
for i in $(seq 1 200); do
	echo "Line $i: The quick brown fox jumps over the lazy dog. ABCDEFGHIJKLMNOP $(printf '%04d' $i)"
done > "$origdir/medium.txt"
dd if=/dev/urandom bs=1024 count=8 of="$origdir/random.bin" 2>/dev/null
for i in $(seq 1 20000); do
	echo "Block test line $i: $(printf '%080d' $i) padding data to ensure multi-block"
done > "$origdir/large.txt"

# Note: random.bin is random each time, so we can't diff it byte-for-byte
# against the archive contents. We'll just verify size.

# ============================================================================
# Test 1: Multi-volume store extraction (rar creates → rarz extracts)
# ============================================================================
echo "=== Test 1: Multi-volume store extraction ==="

tmpdir=$(mktemp -d)
if "$RARZ" x "$FIXTURES/rar5_vol_store.part1.rar" "$tmpdir" 2>&1; then
	# Verify deterministic files match byte-for-byte
	for f in hello.txt binary.bin subdir/nested.txt medium.txt large.txt; do
		if [ -f "$tmpdir/$f" ]; then
			if diff -q "$origdir/$f" "$tmpdir/$f" >/dev/null 2>&1; then
				pass "store vol extract: $f matches"
			else
				fail "store vol extract: $f content mismatch"
			fi
		else
			fail "store vol extract: $f not found"
		fi
	done
	# Verify random.bin exists and has correct size
	if [ -f "$tmpdir/random.bin" ]; then
		actual_size=$(stat -f%z "$tmpdir/random.bin" 2>/dev/null || stat -c%s "$tmpdir/random.bin" 2>/dev/null)
		if [ "$actual_size" = "8192" ]; then
			pass "store vol extract: random.bin correct size"
		else
			fail "store vol extract: random.bin size $actual_size != 8192"
		fi
	else
		fail "store vol extract: random.bin not found"
	fi
else
	fail "rarz x failed on rar5_vol_store.part1.rar"
fi
rm -rf "$tmpdir"

# ============================================================================
# Test 2: Multi-volume compressed extraction (rar creates → rarz extracts)
# ============================================================================
echo "=== Test 2: Multi-volume compressed extraction ==="

tmpdir=$(mktemp -d)
if "$RARZ" x "$FIXTURES/rar5_vol_m3.part01.rar" "$tmpdir" 2>&1; then
	for f in hello.txt binary.bin subdir/nested.txt medium.txt large.txt; do
		if [ -f "$tmpdir/$f" ]; then
			if diff -q "$origdir/$f" "$tmpdir/$f" >/dev/null 2>&1; then
				pass "m3 vol extract: $f matches"
			else
				fail "m3 vol extract: $f content mismatch"
			fi
		else
			fail "m3 vol extract: $f not found"
		fi
	done
else
	fail "rarz x failed on rar5_vol_m3.part01.rar"
fi
rm -rf "$tmpdir"

# ============================================================================
# Test 3: Multi-volume list shows all files with correct sizes
# ============================================================================
echo "=== Test 3: Multi-volume list ==="

list_output=$("$RARZ" l "$FIXTURES/rar5_vol_store.part1.rar" 2>&1) || fail "rarz l failed on vol_store"

# Check that key files appear in the listing
for f in hello.txt medium.txt large.txt random.bin binary.bin; do
	if echo "$list_output" | grep -q "$f"; then
		pass "vol list: $f present"
	else
		fail "vol list: $f missing from listing"
	fi
done

# ============================================================================
# Test 4: Multi-volume test validates all volumes
# ============================================================================
echo "=== Test 4: Multi-volume test ==="

if "$RARZ" t "$FIXTURES/rar5_vol_store.part1.rar" >/dev/null 2>&1; then
	pass "vol test: rar5_vol_store validates"
else
	fail "rarz t failed on rar5_vol_store"
fi

if "$RARZ" t "$FIXTURES/rar5_vol_m3.part01.rar" >/dev/null 2>&1; then
	pass "vol test: rar5_vol_m3 validates"
else
	fail "rarz t failed on rar5_vol_m3"
fi

# ============================================================================
# Test 5: Single large file spanning 6 volumes (store)
# ============================================================================
echo "=== Test 5: Large file spanning 6 volumes ==="

tmpdir=$(mktemp -d)
if "$RARZ" x "$FIXTURES/rar5_vol_large.part1.rar" "$tmpdir" 2>&1; then
	# The large.txt is the only file; find it wherever extracted
	extracted=$(find "$tmpdir" -name "large.txt" -type f | head -1)
	if [ -n "$extracted" ]; then
		if diff -q "$origdir/large.txt" "$extracted" >/dev/null 2>&1; then
			pass "large vol extract: large.txt matches"
		else
			fail "large vol extract: large.txt content mismatch"
		fi
	else
		fail "large vol extract: large.txt not found"
	fi
else
	fail "rarz x failed on rar5_vol_large.part1.rar"
fi
rm -rf "$tmpdir"

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors volume tests"
	exit 1
fi

echo "PASS: test_volumes.sh — all multi-volume tests passed"
