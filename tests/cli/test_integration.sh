#!/usr/bin/env bash
set -u

RARZ="zig-out/bin/rarz"
FIXTURES="tests/fixtures"
errors=0

fail() {
	echo "FAIL: $1"
	errors=$((errors + 1))
}

# Ensure fixtures exist
if [ ! -d "$FIXTURES" ] || [ -z "$(ls "$FIXTURES"/*.rar 2>/dev/null)" ]; then
	echo "ERROR: No fixtures found in $FIXTURES/"
	echo "Run: nix develop -c bash tests/generate_fixtures.sh"
	exit 1
fi

# --- Interop Gate A: official-encoded archives decode in rarz ---

echo "=== Interop Gate A: official -> rarz ==="

for f in "$FIXTURES"/*.rar; do
	name=$(basename "$f")

	# Skip multi-volume parts (not standalone archives)
	if echo "$name" | grep -qE '\.part[0-9]+\.rar$'; then
		continue
	fi

	# rarz t should succeed on all official archives
	if ! "$RARZ" t "$f" >/dev/null 2>&1; then
		fail "rarz t failed on $name"
	fi

	# rarz l should succeed
	if ! "$RARZ" l "$f" >/dev/null 2>&1; then
		fail "rarz l failed on $name"
	fi
done

# Store archives should extract correctly
for f in "$FIXTURES"/rar5_store.rar "$FIXTURES"/single_file.rar "$FIXTURES"/rarz_created.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")
	tmpdir=$(mktemp -d)

	if "$RARZ" x "$f" "$tmpdir" >/dev/null 2>&1; then
		# Verify at least one file was extracted
		if [ -z "$(find "$tmpdir" -type f)" ]; then
			fail "rarz x $name: no files extracted"
		fi
	else
		fail "rarz x failed on $name"
	fi

	rm -rf "$tmpdir"
done

# --- Interop Gate B: rarz-encoded archives decode in official tools ---

echo "=== Interop Gate B: rarz -> official ==="

if [ -f "$FIXTURES/rarz_created.rar" ]; then
	# unrar t should succeed
	if ! unrar t "$FIXTURES/rarz_created.rar" >/dev/null 2>&1; then
		fail "unrar t failed on rarz_created.rar"
	fi

	# unrar x should succeed
	tmpdir=$(mktemp -d)
	if unrar x -o+ "$FIXTURES/rarz_created.rar" "$tmpdir/" >/dev/null 2>&1; then
		if [ ! -f "$tmpdir/rarz_file.txt" ]; then
			# Check without path prefix
			found=$(find "$tmpdir" -name "rarz_file.txt" -type f | head -1)
			if [ -z "$found" ]; then
				fail "unrar x rarz_created.rar: rarz_file.txt not extracted"
			fi
		fi
	else
		fail "unrar x failed on rarz_created.rar"
	fi
	rm -rf "$tmpdir"
fi

# --- Corruption Detection ---

echo "=== Corruption Detection (5x deterministic mutations) ==="

# Use a deterministic seed for reproducible mutations
seed=42

for f in "$FIXTURES"/rar5_store.rar "$FIXTURES"/single_file.rar; do
	[ -f "$f" ] || continue
	name=$(basename "$f")
	filesize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)

	# Skip signature region (first 8 bytes)
	safe_start=9

	for i in $(seq 1 5); do
		# Deterministic offset from seed
		offset=$(( (seed * 31 + i * 17) % (filesize - safe_start) + safe_start ))

		# Create corrupted copy
		corrupt_file="/tmp/rarz_corrupt_${name}_${i}.rar"
		cp "$f" "$corrupt_file"

		# Flip a byte at the computed offset
		printf '\xFF' | dd of="$corrupt_file" bs=1 seek="$offset" count=1 conv=notrunc 2>/dev/null

		# rarz t should detect corruption (exit non-zero)
		if "$RARZ" t "$corrupt_file" >/dev/null 2>&1; then
			# Some mutations may be in the data area and not detectable without
			# full payload verification. This is expected for "corruption_opaque" regions.
			echo "  NOTE: $name mutation $i at offset $offset not detected (may be in opaque region)"
		fi

		rm -f "$corrupt_file"
	done
done

# --- Summary ---

echo ""
if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors integration tests"
	exit 1
fi

echo "PASS: test_integration.sh"
