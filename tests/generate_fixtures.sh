#!/usr/bin/env bash
set -euo pipefail

FIXTURES="tests/fixtures"
rm -rf "$FIXTURES"
mkdir -p "$FIXTURES"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Create deterministic test data (no external tool dependency)
mkdir -p "$tmpdir/tree/subdir"

echo "Hello, rarz!" > "$tmpdir/tree/hello.txt"
printf '\x00\x01\x02\x03\x04\x05\x06\x07' > "$tmpdir/tree/binary.bin"
echo "nested file" > "$tmpdir/tree/subdir/nested.txt"

# Create a larger text file for compression testing (repeating content compresses well)
for i in $(seq 1 200); do
	echo "Line $i: The quick brown fox jumps over the lazy dog. ABCDEFGHIJKLMNOP $(printf '%04d' $i)"
done > "$tmpdir/tree/medium.txt"

# Create a binary-ish file with some entropy
dd if=/dev/urandom bs=1024 count=8 of="$tmpdir/tree/random.bin" 2>/dev/null

# Save project root for later
project_root="$(pwd)"

# Generate fixtures with official rar tool
cd "$tmpdir/tree"

# RAR5 store (recursive to pick up all subdirs)
rar a -m0 -r "$project_root/$FIXTURES/rar5_store.rar" . >/dev/null 2>&1

# RAR5 compressed at each level
for level in 1 2 3 4 5; do
	rar a -m${level} -r "$project_root/$FIXTURES/rar5_m${level}.rar" . >/dev/null 2>&1
done

# Default compression (for backwards compat with existing test names)
cp "$project_root/$FIXTURES/rar5_m3.rar" "$project_root/$FIXTURES/rar5_compressed.rar"

# Single file archive (store)
rar a -m0 "$project_root/$FIXTURES/single_file.rar" hello.txt >/dev/null 2>&1

# Archive with directories
mkdir -p empty_dir
rar a -m0 -r "$project_root/$FIXTURES/with_dirs.rar" empty_dir subdir >/dev/null 2>&1

# Single file compressed (for simple decompression test)
rar a -m3 "$project_root/$FIXTURES/single_compressed.rar" hello.txt >/dev/null 2>&1

# Large file for multi-block decompression testing (~1.6MB text)
for i in $(seq 1 20000); do
	echo "Block test line $i: $(printf '%080d' $i) padding data to ensure multi-block"
done > "$tmpdir/tree/large.txt"
rar a -m3 "$project_root/$FIXTURES/large_compressed.rar" "$tmpdir/tree/large.txt" >/dev/null 2>&1

# Multi-volume RAR5 store (500KB per volume → ~4 volumes for tree data)
rar a -v500k -m0 -r "$project_root/$FIXTURES/rar5_vol_store.rar" . >/dev/null 2>&1

# Multi-volume RAR5 compressed (50KB per volume → 2+ volumes for compressed tree)
rar a -v50k -m3 -r "$project_root/$FIXTURES/rar5_vol_m3.rar" . >/dev/null 2>&1

# Multi-volume with a single large file spanning 3+ volumes (500KB per volume)
rar a -v500k -m0 "$project_root/$FIXTURES/rar5_vol_large.rar" "$tmpdir/tree/large.txt" >/dev/null 2>&1

# Archive created by rarz itself (for round-trip testing)
cd "$project_root"
nix develop -c zig build >/dev/null 2>&1
echo "rarz created this" > "$tmpdir/rarz_file.txt"
zig-out/bin/rarz a "$FIXTURES/rarz_created.rar" "$tmpdir/rarz_file.txt"

echo "Generated $(ls "$FIXTURES"/*.rar | wc -l | tr -d ' ') fixture archives in $FIXTURES/"
ls -la "$FIXTURES"/*.rar
