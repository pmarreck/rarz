#!/usr/bin/env bash
# Generate the RAR4/v29 SOLID fixture using the official RAR4-capable rar (6.21).
#
# WHY SEPARATE FROM generate_rar4_fixtures.sh
#   That script rewrites all three rar4_* archives every run, which churns their
#   embedded timestamps and therefore the committed bytes. This one is additive:
#   it writes exactly the archive it owns.
#
# WHY A v29 SOLID FIXTURE SPECIFICALLY
#   RAR3 (v29) solid is by far the most common solid archive in the wild -- it
#   was the default for the entire RAR 3.x/4.x era, which is precisely the
#   vintage a file-integrity product meets in the field. The RAR2 and RAR5 solid
#   fixtures bracket it, but neither exercises the v29 decoder's own
#   carry-over state (PPM block mode, the v29 rep-distance array, and the
#   filter machinery that RAR3 alone has).
#
# ONE-TIME, OFF-LINE. The generated archive is committed; the suite and CI never
# need rar 6.21.
#
# Usage:  bash tests/generate_rar4_solid_fixture.sh
set -u

FIXTURES="tests/fixtures"
RAR4_NIXPKGS="github:NixOS/nixpkgs/nixos-23.11"   # rar 6.21; 7.x dropped -ma4

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v random >/dev/null 2>&1 || die "the 'random' utility is required for deterministic payloads"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

tree="$tmpdir/tree"
mkdir -p "$tree/sub"

# --- Deterministic, self-owned content --------------------------------------
# Two files quote a third verbatim, so the encoder emits matches that reach BACK
# ACROSS a file boundary. That cross-file match is the only thing separating a
# correct solid decoder from a broken one: files that share nothing round-trip
# even when the window resets, so such a fixture could not falsify the bug.
awk 'BEGIN { for (i = 1; i <= 400; i++)
	printf "shared line %d: the quick brown fox jumps over the lazy dog\n", i }' \
	> "$tree/a_shared.txt"

{
	printf 'file b prologue\n'
	cat "$tree/a_shared.txt"
	printf 'file b epilogue\n'
} > "$tree/b_quotes_a.txt"

{
	printf 'file c prologue\n'
	cat "$tree/a_shared.txt"
	cat "$tree/a_shared.txt"
	printf 'file c epilogue\n'
} > "$tree/sub/c_quotes_a_twice.txt"

# Partially compressible: normal-distributed bytes cluster around a mean, so the
# entropy coder is genuinely exercised rather than the payload being stored.
random -b -c 16384 --seed 6001 --normalized > "$tree/mixed.bin" 2>/dev/null \
	|| die "random --normalized failed (is 'random' on PATH?)"
# Effectively incompressible: forces a stored entry inside a solid stream.
random -b -c 4096 --seed 6002 > "$tree/noise.bin" 2>/dev/null || die "random failed"

printf 'nested payload for path handling\n' > "$tree/sub/nested.txt"

# --- Generate ---------------------------------------------------------------
out="rar4_v29_solid.rar"

echo "Fetching rar 6.21 from $RAR4_NIXPKGS (one-time; RAR 7.x cannot write RAR4)..."
export NIXPKGS_ALLOW_UNFREE=1
nix shell --impure "$RAR4_NIXPKGS#rar" --command \
	bash -c "cd '$tree' && rar a -s -m3 -ma4 -idq -r '$tmpdir/$out' ." \
	|| die "rar failed generating $out"
[ -f "$tmpdir/$out" ] || die "rar produced no $out"

magic=$(head -c 7 "$tmpdir/$out" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "526172211a0700" ] || die "$out is not RAR4 (magic $magic)"

dest="$FIXTURES/$out"
cp "$tmpdir/$out" "$dest"

# --- Independent verification -----------------------------------------------
# unrar is the oracle. Assert the archive really IS solid and really IS v29:
# `rar a -s` silently emits a non-solid archive when there is nothing to share,
# and a non-solid or non-v29 fixture cannot falsify the bug it exists to catch.
unrar t "$dest" >/dev/null 2>&1 || die "$out failed unrar verification"
unrar lt "$dest" 2>&1 | grep -qi 'solid' || die "$out is not actually solid"
unrar lt "$dest" 2>&1 | grep -q 'v29' || die "$out is not v29"

echo "  wrote $dest ($(wc -c < "$dest") bytes)"
echo "RAR4 v29 solid fixture generated."
