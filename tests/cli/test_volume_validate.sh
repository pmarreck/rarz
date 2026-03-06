#!/usr/bin/env bash
set -euo pipefail

RARZ="zig-out/bin/rarz"
errors=0

fail() {
	echo "FAIL: $1"
	errors=$((errors + 1))
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Create test input files
mkdir -p "$tmpdir/data"
python3 -c "print('File content for volume validation testing. ' * 80)" > "$tmpdir/data/file1.txt"
python3 -c "print('Another test file with different content. ' * 80)" > "$tmpdir/data/file2.txt"
python3 -c "print('X' * 5000)" > "$tmpdir/data/big.txt"

# ========================================================================
# Test 1: Multi-volume store archive validates as VALID
# ========================================================================
echo "=== Test 1: Multi-volume store validation (valid) ==="

if ! "$RARZ" a -m0 -v2k "$tmpdir/store.rar" "$tmpdir/data/"* 2>/dev/null; then
	fail "test1: rarz a failed"
else
	part_count=$(ls "$tmpdir"/store.part*.rar 2>/dev/null | wc -l | tr -d ' ')
	if [ "$part_count" -lt 2 ]; then
		fail "test1: expected at least 2 volumes, got $part_count"
	else
		output=$("$RARZ" t "$tmpdir/store.part1.rar" 2>&1)
		if echo "$output" | grep -q "Validation: VALID"; then
			echo "  OK: multi-volume store validation VALID ($part_count volumes)"
		else
			fail "test1: expected VALID, got: $output"
		fi
	fi
fi

# ========================================================================
# Test 2: Corrupted multi-volume store archive detects INVALID
# ========================================================================
echo "=== Test 2: Multi-volume store validation (corrupted) ==="

# Copy volumes to a new location for corruption
mkdir -p "$tmpdir/corrupt_store"
cp "$tmpdir"/store.part*.rar "$tmpdir/corrupt_store/"

# Corrupt a byte in the data area of volume 2
part2="$tmpdir/corrupt_store/store.part2.rar"
if [ -f "$part2" ]; then
	# Corrupt near the middle of the volume (likely data area)
	part2_size=$(wc -c < "$part2" | tr -d ' ')
	corrupt_pos=$((part2_size / 2))
	printf '\xFF' | dd of="$part2" bs=1 seek="$corrupt_pos" conv=notrunc 2>/dev/null
	output=$("$RARZ" t "$tmpdir/corrupt_store/store.part1.rar" 2>&1) || true
	if echo "$output" | grep -q "Validation: INVALID"; then
		echo "  OK: corrupted multi-volume store detected as INVALID"
	else
		fail "test2: expected INVALID, got: $output"
	fi
else
	fail "test2: part2 not found for corruption test"
fi

# ========================================================================
# Test 3: Multi-volume compressed archive validates as VALID
# ========================================================================
echo "=== Test 3: Multi-volume compressed validation (valid) ==="

if ! "$RARZ" a -m3 -v3k "$tmpdir/comp.rar" "$tmpdir/data/"* 2>/dev/null; then
	fail "test3: rarz a -m3 failed"
else
	part_count=$(ls "$tmpdir"/comp.part*.rar 2>/dev/null | wc -l | tr -d ' ')
	if [ "$part_count" -lt 2 ]; then
		# Compressed data may fit in fewer volumes; at least check single validates
		output=$("$RARZ" t "$tmpdir/comp.part1.rar" 2>&1)
		if echo "$output" | grep -q "Validation: VALID"; then
			echo "  OK: compressed archive validates VALID ($part_count volume(s))"
		else
			fail "test3: expected VALID, got: $output"
		fi
	else
		output=$("$RARZ" t "$tmpdir/comp.part1.rar" 2>&1)
		if echo "$output" | grep -q "Validation: VALID"; then
			echo "  OK: multi-volume compressed validation VALID ($part_count volumes)"
		else
			fail "test3: expected VALID, got: $output"
		fi
	fi
fi

# ========================================================================
# Test 4: Single volume still works as before
# ========================================================================
echo "=== Test 4: Single volume validation ==="

if ! "$RARZ" a -m0 "$tmpdir/single.rar" "$tmpdir/data/file1.txt" 2>/dev/null; then
	fail "test4: rarz a failed"
else
	output=$("$RARZ" t "$tmpdir/single.rar" 2>&1)
	if echo "$output" | grep -q "Validation: VALID"; then
		echo "  OK: single volume validation VALID"
	else
		fail "test4: expected VALID, got: $output"
	fi
fi

# ========================================================================
# Test 5: Multi-volume shows volume count in output
# ========================================================================
echo "=== Test 5: Volume count in output ==="

output=$("$RARZ" t "$tmpdir/store.part1.rar" 2>&1) || true
if echo "$output" | grep -q "volumes)"; then
	echo "  OK: volume count shown in output"
else
	fail "test5: expected volume count in output, got: $output"
fi

# ========================================================================
# Summary
# ========================================================================
echo ""
if [ "$errors" -gt 0 ]; then
	echo "FAIL: test_volume_validate.sh ($errors errors)"
	exit 1
fi
echo "PASS: test_volume_validate.sh"
