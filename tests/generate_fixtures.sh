#!/usr/bin/env bash
set -euo pipefail

FIXTURES="tests/fixtures"
rm -rf "$FIXTURES"
mkdir -p "$FIXTURES"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Generate a deterministic fake file tree
gen-fake-tree --seed 0xDEADBEEF --path "$tmpdir/tree" --max-files 10 --max-size 10K --max-depth 3

# Also create some specific test files
echo "Hello, rarz!" > "$tmpdir/tree/hello.txt"
printf '\x00\x01\x02\x03\x04\x05\x06\x07' > "$tmpdir/tree/binary.bin"
mkdir -p "$tmpdir/tree/subdir"
echo "nested file" > "$tmpdir/tree/subdir/nested.txt"

# Save project root for later
project_root="$(pwd)"

# Generate fixtures with official rar tool
cd "$tmpdir/tree"

# RAR5 store (recursive to pick up all subdirs)
rar a -m0 -r "$project_root/$FIXTURES/rar5_store.rar" . >/dev/null 2>&1

# RAR5 compressed (default method, recursive)
rar a -r "$project_root/$FIXTURES/rar5_compressed.rar" . >/dev/null 2>&1

# Single file archive
rar a -m0 "$project_root/$FIXTURES/single_file.rar" hello.txt >/dev/null 2>&1

# Archive with directories
mkdir -p empty_dir
rar a -m0 -r "$project_root/$FIXTURES/with_dirs.rar" empty_dir subdir >/dev/null 2>&1

# Archive created by rarz itself (for round-trip testing)
cd "$project_root"
nix develop -c zig build >/dev/null 2>&1
echo "rarz created this" > "$tmpdir/rarz_file.txt"
zig-out/bin/rarz a "$FIXTURES/rarz_created.rar" "$tmpdir/rarz_file.txt"

echo "Generated $(ls "$FIXTURES"/*.rar | wc -l | tr -d ' ') fixture archives in $FIXTURES/"
ls -la "$FIXTURES"/*.rar
