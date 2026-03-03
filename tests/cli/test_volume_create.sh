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

# Create test input files of varying sizes
mkdir -p "$tmpdir/data"
# ~2KB per file, 5 files = ~10KB of data
for i in $(seq 1 5); do
	python3 -c "print('File $i content is here and has some data. ' * 50)" > "$tmpdir/data/file$i.txt"
done

# Create a larger file for split testing
python3 -c "print('X' * 5000)" > "$tmpdir/data/big.txt"

# ========================================================================
# Test 1: Creates correct number of volume files
# ========================================================================
echo "=== Test 1: Volume creation (store mode) ==="

if ! "$RARZ" a -m0 -v2k "$tmpdir/vol1.rar" "$tmpdir/data/"* 2>/dev/null; then
	fail "test1: rarz a -v200 failed"
else
	# Check that part1.rar exists
	if [ ! -f "$tmpdir/vol1.part1.rar" ]; then
		fail "test1: vol1.part1.rar not found"
		ls "$tmpdir"/vol1.* 2>/dev/null || true
	else
		# Count parts
		part_count=$(ls "$tmpdir"/vol1.part*.rar 2>/dev/null | wc -l | tr -d ' ')
		if [ "$part_count" -lt 2 ]; then
			fail "test1: expected at least 2 volumes, got $part_count"
		else
			echo "  OK: created $part_count volumes"
		fi
	fi
fi

# ========================================================================
# Test 2: Each volume validates individually
# ========================================================================
echo "=== Test 2: Individual volume validation ==="

valid=1
for f in "$tmpdir"/vol1.part*.rar; do
	[ -f "$f" ] || continue
	if ! "$RARZ" t "$f" >/dev/null 2>&1; then
		fail "test2: $f failed validation"
		valid=0
	fi
done
if [ "$valid" -eq 1 ]; then
	echo "  OK: all volumes validate individually"
fi

# ========================================================================
# Test 3: Extraction via rarz x archive.part1.rar
# ========================================================================
echo "=== Test 3: Volume extraction ==="

if [ -f "$tmpdir/vol1.part1.rar" ]; then
	mkdir -p "$tmpdir/extract3"
	if ! "$RARZ" x "$tmpdir/vol1.part1.rar" "$tmpdir/extract3" 2>/dev/null; then
		fail "test3: rarz x failed on volume set"
	else
		# Count extracted files
		extracted=$(find "$tmpdir/extract3" -type f | wc -l | tr -d ' ')
		if [ "$extracted" -lt 1 ]; then
			fail "test3: no files extracted from volumes"
		else
			echo "  OK: extracted $extracted files from volumes"
		fi
	fi
fi

# ========================================================================
# Test 4: Interop — unrar can extract rarz-created volumes
# ========================================================================
echo "=== Test 4: Interop with unrar ==="

if [ -f "$tmpdir/vol1.part1.rar" ]; then
	mkdir -p "$tmpdir/unrar_vol"
	if unrar x -o+ "$tmpdir/vol1.part1.rar" "$tmpdir/unrar_vol/" >/dev/null 2>&1; then
		# Verify at least some files extracted
		unrar_count=$(find "$tmpdir/unrar_vol" -type f | wc -l | tr -d ' ')
		if [ "$unrar_count" -lt 1 ]; then
			fail "test4: unrar extracted no files"
		else
			echo "  OK: unrar extracted $unrar_count files from rarz volumes"
		fi
	else
		fail "test4: unrar x failed on rarz-created volumes"
	fi
fi

# ========================================================================
# Test 5: Combined with -o and -mN
# ========================================================================
echo "=== Test 5: Combined -o -m3 -v ==="

mkdir -p "$tmpdir/outdir5"
if ! "$RARZ" a -m3 -o "$tmpdir/outdir5" -v3k "$tmpdir/data/"* 2>/dev/null; then
	fail "test5: combined -o -m3 -v failed"
else
	# Check for volumes in outdir5
	part_count=$(ls "$tmpdir/outdir5"/*.part*.rar 2>/dev/null | wc -l | tr -d ' ')
	if [ "$part_count" -lt 1 ]; then
		fail "test5: no volume files found in outdir5"
		ls "$tmpdir/outdir5/" 2>/dev/null || true
	else
		echo "  OK: combined flags created $part_count volumes"
	fi
fi

# ========================================================================
# Test 6: Volume_size larger than archive -> single part1.rar
# ========================================================================
echo "=== Test 6: Large volume size -> single volume ==="

echo "tiny" > "$tmpdir/tiny.txt"
if ! "$RARZ" a -v1m "$tmpdir/vol6.rar" "$tmpdir/tiny.txt" 2>/dev/null; then
	fail "test6: rarz a -v1m failed"
else
	if [ ! -f "$tmpdir/vol6.part1.rar" ]; then
		fail "test6: vol6.part1.rar not found"
	else
		part_count=$(ls "$tmpdir"/vol6.part*.rar 2>/dev/null | wc -l | tr -d ' ')
		if [ "$part_count" -ne 1 ]; then
			fail "test6: expected 1 volume for tiny file, got $part_count"
		else
			echo "  OK: single volume for tiny file"
		fi
	fi
fi

# ========================================================================
# Test 7: Compressed volumes with extraction verification
# ========================================================================
echo "=== Test 7: Compressed volume round-trip ==="

if ! "$RARZ" a -m3 -v2k "$tmpdir/vol7.rar" "$tmpdir/data/"* 2>/dev/null; then
	fail "test7: rarz a -m3 -v300 failed"
else
	if [ -f "$tmpdir/vol7.part1.rar" ]; then
		mkdir -p "$tmpdir/extract7"
		if "$RARZ" x "$tmpdir/vol7.part1.rar" "$tmpdir/extract7" 2>/dev/null; then
			# Verify content of first file
			orig_content=$(cat "$tmpdir/data/file1.txt")
			extr_content=$(cat "$tmpdir/extract7/file1.txt" 2>/dev/null || echo "")
			if [ "$orig_content" = "$extr_content" ]; then
				echo "  OK: compressed volume round-trip content matches"
			else
				fail "test7: content mismatch after extract"
			fi
		else
			fail "test7: extraction of compressed volumes failed"
		fi
	else
		fail "test7: vol7.part1.rar not found"
	fi
fi

# ========================================================================
# Summary
# ========================================================================
echo ""
if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors volume-create tests"
	exit 1
fi

echo "PASS: test_volume_create.sh"
