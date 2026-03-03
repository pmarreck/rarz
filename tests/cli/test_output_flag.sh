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
mkdir -p "$tmpdir/mydir/sub"
echo "hello" > "$tmpdir/mydir/root.txt"
echo "world" > "$tmpdir/mydir/sub/nested.txt"
echo "standalone" > "$tmpdir/file1.txt"
echo "another" > "$tmpdir/file2.txt"

# ========================================================================
# Test 1: -o <dir> with directory input -> derives name from dir basename
# ========================================================================
echo "=== Test 1: -o <dir> with directory input ==="

mkdir -p "$tmpdir/outdir1"
if ! "$RARZ" a -o "$tmpdir/outdir1" "$tmpdir/mydir/" 2>/dev/null; then
	fail "test1: rarz a -o <dir> failed"
elif [ ! -f "$tmpdir/outdir1/mydir.rar" ]; then
	fail "test1: expected mydir.rar in outdir1, not found"
	ls -la "$tmpdir/outdir1/" 2>/dev/null || true
else
	# Verify it's a valid archive
	if ! "$RARZ" t "$tmpdir/outdir1/mydir.rar" >/dev/null 2>&1; then
		fail "test1: derived archive fails validation"
	fi
	echo "  OK: -o <dir> derived mydir.rar"
fi

# ========================================================================
# Test 2: -o <dir> with file inputs -> derives name from first file
# ========================================================================
echo "=== Test 2: -o <dir> with file inputs ==="

mkdir -p "$tmpdir/outdir2"
if ! "$RARZ" a -o "$tmpdir/outdir2" "$tmpdir/file1.txt" "$tmpdir/file2.txt" 2>/dev/null; then
	fail "test2: rarz a -o <dir> with files failed"
elif [ ! -f "$tmpdir/outdir2/file1.rar" ]; then
	fail "test2: expected file1.rar in outdir2, not found"
	ls -la "$tmpdir/outdir2/" 2>/dev/null || true
else
	if ! "$RARZ" t "$tmpdir/outdir2/file1.rar" >/dev/null 2>&1; then
		fail "test2: derived archive fails validation"
	fi
	echo "  OK: -o <dir> derived file1.rar from first file"
fi

# ========================================================================
# Test 3: -o <file> -> uses explicit path
# ========================================================================
echo "=== Test 3: -o <file> (explicit path) ==="

if ! "$RARZ" a -o "$tmpdir/custom.rar" "$tmpdir/file1.txt" 2>/dev/null; then
	fail "test3: rarz a -o <file> failed"
elif [ ! -f "$tmpdir/custom.rar" ]; then
	fail "test3: expected custom.rar, not found"
else
	if ! "$RARZ" t "$tmpdir/custom.rar" >/dev/null 2>&1; then
		fail "test3: explicit archive fails validation"
	fi
	echo "  OK: -o <file> created custom.rar"
fi

# ========================================================================
# Test 4: -mN and -o in any order
# ========================================================================
echo "=== Test 4: -mN and -o in any order ==="

# -m0 before -o
if ! "$RARZ" a -m0 -o "$tmpdir/order1.rar" "$tmpdir/file1.txt" 2>/dev/null; then
	fail "test4a: rarz a -m0 -o failed"
elif [ ! -f "$tmpdir/order1.rar" ]; then
	fail "test4a: order1.rar not found"
else
	echo "  OK: -m0 -o works"
fi

# -o before -mN
if ! "$RARZ" a -o "$tmpdir/order2.rar" -m0 "$tmpdir/file1.txt" 2>/dev/null; then
	fail "test4b: rarz a -o -m0 failed"
elif [ ! -f "$tmpdir/order2.rar" ]; then
	fail "test4b: order2.rar not found"
else
	echo "  OK: -o -m0 works"
fi

# --output long form
if ! "$RARZ" a --output "$tmpdir/order3.rar" "$tmpdir/file1.txt" 2>/dev/null; then
	fail "test4c: rarz a --output failed"
elif [ ! -f "$tmpdir/order3.rar" ]; then
	fail "test4c: order3.rar not found"
else
	echo "  OK: --output works"
fi

# ========================================================================
# Test 5: No -o -> backward compatible
# ========================================================================
echo "=== Test 5: No -o (backward compatible) ==="

if ! "$RARZ" a "$tmpdir/compat.rar" "$tmpdir/file1.txt" 2>/dev/null; then
	fail "test5: backward-compatible rarz a failed"
elif [ ! -f "$tmpdir/compat.rar" ]; then
	fail "test5: compat.rar not found"
else
	echo "  OK: backward-compatible mode works"
fi

# ========================================================================
# Test 6: Error — -o with no argument
# ========================================================================
echo "=== Test 6: -o with no argument (error) ==="

if "$RARZ" a -o 2>/dev/null; then
	fail "test6: expected error for -o with no argument, but got success"
else
	echo "  OK: -o with no argument correctly errors"
fi

# ========================================================================
# Test 7: Archive validates and extracts correctly
# ========================================================================
echo "=== Test 7: -o archive round-trip extract ==="

mkdir -p "$tmpdir/outdir7"
if ! "$RARZ" a -m3 -o "$tmpdir/outdir7" "$tmpdir/mydir/" 2>/dev/null; then
	fail "test7: rarz a -m3 -o <dir> failed"
elif [ ! -f "$tmpdir/outdir7/mydir.rar" ]; then
	fail "test7: mydir.rar not created"
else
	mkdir -p "$tmpdir/extract7"
	if ! "$RARZ" x "$tmpdir/outdir7/mydir.rar" "$tmpdir/extract7" 2>/dev/null; then
		fail "test7: extraction failed"
	else
		content=$(cat "$tmpdir/extract7/mydir/sub/nested.txt" 2>/dev/null || echo "")
		if [ "$content" != "world" ]; then
			fail "test7: content mismatch after extract: '$content'"
		else
			echo "  OK: -o archive round-trips correctly"
		fi
	fi
fi

# ========================================================================
# Summary
# ========================================================================
echo ""
if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors output-flag tests"
	exit 1
fi

echo "PASS: test_output_flag.sh"
