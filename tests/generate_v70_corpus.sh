#!/usr/bin/env bash
# RAR7 (v70) large-dictionary corpus — LOCAL CACHE, not committed (multi-GiB).
# Deterministic via the `random` CLI (seeded BLAKE3 XOF), so any machine can
# regenerate the identical corpus; only the generator is under version control.
#
# WHY THIS SHAPE
#   rar 7.20 clamps the dictionary to roughly twice the file size and emits
#   v50 whenever the dictionary fits v50's ceiling, so small probes can never
#   produce a v70 stream. The payload here is A ++ B ++ A with A and B
#   INDEPENDENTLY SEEDED random blocks (incompressible on their own): the only
#   compression win is the second copy of A at distance |A|+|B| ≈ 4.4 GiB,
#   which forces the encoder to keep a >4 GiB window and use extended
#   distances — the two things that distinguish v70 from v50.
#
# Cache: tests/fixtures_large/ (gitignored). Verified against unrar at
# generation time. Budget: ~11 GiB in the cache dir, ~20 GiB RAM during
# encode.
#
# Usage:  nix develop -c bash tests/generate_v70_corpus.sh
set -u
CACHE="tests/fixtures_large"
die() { echo "ERROR: $*" >&2; exit 1; }
command -v rar >/dev/null 2>&1 || die "rar required (nix develop -c)"
command -v unrar >/dev/null 2>&1 || die "unrar required"
command -v drandomz >/dev/null 2>&1 || die "the drandomz CLI is required (../random, zig build)"
mkdir -p "$CACHE"

if [ -f "$CACHE/v70_longrange.rar" ]; then
	echo "cached: $CACHE/v70_longrange.rar ($(stat -c%s "$CACHE/v70_longrange.rar") bytes)"
	unrar lt "$CACHE/v70_longrange.rar" 2>/dev/null | grep Compression
	exit 0
fi

GB=1073741824
A_BYTES=$((2 * GB + 200 * 1024 * 1024))   # 2.2 GiB
B_BYTES=$((2 * GB + 200 * 1024 * 1024))   # 2.2 GiB

echo "generating deterministic payload (A=B=2.2 GiB, layout A B A)..."
[ -f "$CACHE/blob_a.bin" ] || drandomz -b -c "$A_BYTES" --seed 0x700A > "$CACHE/blob_a.bin"
[ -f "$CACHE/blob_b.bin" ] || drandomz -b -c "$B_BYTES" --seed 0x700B > "$CACHE/blob_b.bin"
cat "$CACHE/blob_a.bin" "$CACHE/blob_b.bin" "$CACHE/blob_a.bin" > "$CACHE/v70_payload.bin"

echo "archiving with rar $(rar -iver 2>/dev/null | tail -1) at -m1 -md8g..."
rm -f "$CACHE/v70_longrange.rar"
( cd "$CACHE" && rar a -idq -m1 -md8g v70_longrange.rar v70_payload.bin ) || die "rar failed"

# unrar refuses >4 GiB dictionaries without explicit opt-in (-mdx): its own
# admission policy. The opt-in is part of the oracle invocation.
unrar t -mdx8g "$CACHE/v70_longrange.rar" >/dev/null 2>&1 || die "unrar refuses the corpus"
echo "  wrote $CACHE/v70_longrange.rar ($(stat -c%s "$CACHE/v70_longrange.rar") bytes)"
unrar lt "$CACHE/v70_longrange.rar" 2>/dev/null | grep -E "Compression|Size"
