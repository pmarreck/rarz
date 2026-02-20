#!/usr/bin/env bash
set -euo pipefail

RARZ="zig-out/bin/rarz"
FIXTURES="tests/fixtures"
errors=0
pass=0

fail() {
	echo "  FAIL: $1"
	((errors++))
}

ok() {
	echo "  OK: $1"
	((pass++))
}

# Ensure fixtures exist
if [ ! -d "$FIXTURES" ] || [ -z "$(ls "$FIXTURES"/*.rar 2>/dev/null)" ]; then
	echo "ERROR: No fixtures found in $FIXTURES/"
	echo "Run: nix develop -c bash tests/generate_fixtures.sh"
	exit 1
fi

# Ensure rarz binary exists
if [ ! -x "$RARZ" ]; then
	echo "ERROR: rarz binary not found at $RARZ"
	echo "Run: nix develop -c zig build"
	exit 1
fi

# =============================================================================
# Interop Gate A: Compressed extraction matches unrar byte-for-byte
# =============================================================================

echo "=== Interop Gate A: rarz extract vs unrar extract (byte-for-byte) ==="

for f in "$FIXTURES"/rar5_m*.rar "$FIXTURES"/single_compressed.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")

	rarz_dir=$(mktemp -d)
	unrar_dir=$(mktemp -d)

	# Extract with rarz
	if ! "$RARZ" x "$f" "$rarz_dir" >/dev/null 2>&1; then
		fail "$name: rarz extract failed"
		rm -rf "$rarz_dir" "$unrar_dir"
		continue
	fi

	# Extract with unrar
	if ! unrar x -o+ "$f" "$unrar_dir/" >/dev/null 2>&1; then
		fail "$name: unrar extract failed"
		rm -rf "$rarz_dir" "$unrar_dir"
		continue
	fi

	# Compare all extracted files byte-for-byte
	mismatch=0
	while IFS= read -r relpath; do
		rarz_file="$rarz_dir/$relpath"
		unrar_file="$unrar_dir/$relpath"

		if [ ! -f "$rarz_file" ]; then
			fail "$name: rarz missing file '$relpath'"
			mismatch=1
			continue
		fi

		if ! cmp -s "$rarz_file" "$unrar_file"; then
			rarz_size=$(stat -f%z "$rarz_file" 2>/dev/null || stat -c%s "$rarz_file" 2>/dev/null)
			unrar_size=$(stat -f%z "$unrar_file" 2>/dev/null || stat -c%s "$unrar_file" 2>/dev/null)
			fail "$name: content mismatch for '$relpath' (rarz=${rarz_size}B, unrar=${unrar_size}B)"
			mismatch=1
		fi
	done < <(cd "$unrar_dir" && find . -type f | sed 's|^\./||' | sort)

	if [ "$mismatch" -eq 0 ]; then
		file_count=$(cd "$unrar_dir" && find . -type f | wc -l | tr -d ' ')
		ok "$name: all $file_count files match"
	fi

	rm -rf "$rarz_dir" "$unrar_dir"
done

# =============================================================================
# Interop Gate B: Large file decompression (multi-block)
# =============================================================================

echo ""
echo "=== Interop Gate B: Large file decompression ==="

if [ -f "$FIXTURES/large_compressed.rar" ]; then
	rarz_dir=$(mktemp -d)
	unrar_dir=$(mktemp -d)

	if ! "$RARZ" x "$FIXTURES/large_compressed.rar" "$rarz_dir" >/dev/null 2>&1; then
		fail "large_compressed.rar: rarz extract failed"
	elif ! unrar x -o+ "$FIXTURES/large_compressed.rar" "$unrar_dir/" >/dev/null 2>&1; then
		fail "large_compressed.rar: unrar extract failed"
	else
		# Find the extracted file
		rarz_file=$(find "$rarz_dir" -type f | head -1)
		unrar_file=$(find "$unrar_dir" -type f | head -1)

		if [ -z "$rarz_file" ] || [ -z "$unrar_file" ]; then
			fail "large_compressed.rar: no files extracted"
		elif cmp -s "$rarz_file" "$unrar_file"; then
			fsize=$(stat -f%z "$unrar_file" 2>/dev/null || stat -c%s "$unrar_file" 2>/dev/null)
			ok "large_compressed.rar: ${fsize}B file matches"
		else
			rarz_size=$(stat -f%z "$rarz_file" 2>/dev/null || stat -c%s "$rarz_file" 2>/dev/null)
			unrar_size=$(stat -f%z "$unrar_file" 2>/dev/null || stat -c%s "$unrar_file" 2>/dev/null)
			fail "large_compressed.rar: content mismatch (rarz=${rarz_size}B, unrar=${unrar_size}B)"
		fi
	fi

	rm -rf "$rarz_dir" "$unrar_dir"
fi

# =============================================================================
# Interop Gate C: Validation depth for compressed archives
# =============================================================================

echo ""
echo "=== Interop Gate C: Validation depth for compressed archives ==="

for f in "$FIXTURES"/rar5_m*.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")

	output=$("$RARZ" t "$f" 2>&1)
	if echo "$output" | grep -q "VALID"; then
		ok "$name: validation reports VALID"
	else
		fail "$name: validation did not report VALID"
	fi
done

# =============================================================================
# Interop Gate D: Corruption detection for compressed archives
# =============================================================================

echo ""
echo "=== Interop Gate D: Corruption detection (compressed archives) ==="

seed=42
for f in "$FIXTURES"/rar5_m3.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")
	filesize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
	safe_start=16  # skip past signature + headers

	detected=0
	total=5
	for i in $(seq 1 $total); do
		offset=$(( (seed * 31 + i * 17) % (filesize - safe_start) + safe_start ))
		corrupt_file="/tmp/rarz_corrupt_${name}_${i}.rar"
		cp "$f" "$corrupt_file"
		printf '\xFF' | dd of="$corrupt_file" bs=1 seek="$offset" count=1 conv=notrunc 2>/dev/null

		if ! "$RARZ" t "$corrupt_file" >/dev/null 2>&1; then
			((detected++))
		fi

		rm -f "$corrupt_file"
	done

	if [ "$detected" -gt 0 ]; then
		ok "$name: detected $detected/$total corruptions"
	else
		fail "$name: detected 0/$total corruptions"
	fi
done

# =============================================================================
# Interop Gate E: Store archives still work (regression check)
# =============================================================================

echo ""
echo "=== Interop Gate E: Store archive regression check ==="

for f in "$FIXTURES"/rar5_store.rar "$FIXTURES"/single_file.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")

	rarz_dir=$(mktemp -d)
	unrar_dir=$(mktemp -d)

	"$RARZ" x "$f" "$rarz_dir" >/dev/null 2>&1 || true
	unrar x -o+ "$f" "$unrar_dir/" >/dev/null 2>&1 || true

	mismatch=0
	while IFS= read -r relpath; do
		rarz_file="$rarz_dir/$relpath"
		unrar_file="$unrar_dir/$relpath"
		[ -f "$rarz_file" ] || { mismatch=1; break; }
		cmp -s "$rarz_file" "$unrar_file" || { mismatch=1; break; }
	done < <(cd "$unrar_dir" && find . -type f | sed 's|^\./||' | sort)

	if [ "$mismatch" -eq 0 ]; then
		ok "$name: store extraction matches"
	else
		fail "$name: store extraction mismatch"
	fi

	rm -rf "$rarz_dir" "$unrar_dir"
done

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "================================"
echo "Results: $pass passed, $errors failed"
echo "================================"

if [ "$errors" -gt 0 ]; then
	exit 1
fi

echo "PASS: test_decompress.sh"
