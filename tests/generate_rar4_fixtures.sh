#!/usr/bin/env bash
# Generate RAR4 (RAR 1.5-4.x) fixtures using the OFFICIAL rar tool.
#
# WHY THIS EXISTS SEPARATELY FROM generate_fixtures.sh
#   1. It is ADDITIVE. generate_fixtures.sh starts with `rm -rf tests/fixtures`,
#      so running it would destroy every committed fixture. This script only
#      writes the rar4_* files it owns.
#   2. It needs a DIFFERENT rar. RAR 7.x removed RAR4 creation (`-ma4` is gone;
#      7.20 accepts only -ma5). The devshell ships 7.20, so we reach back to
#      nixpkgs nixos-23.11, which packages rar 6.21 — the last series that can
#      still write RAR4.
#
# This is a ONE-TIME, OFF-LINE step. The generated .rar files are committed, so
# neither the test suite nor CI depends on the old rar. Re-run it only when the
# RAR4 corpus needs to change.
#
# WHY OFFICIAL-TOOL OUTPUT MATTERS (MFIC: producer != checker)
#   The archives must be produced by real RAR tooling, not by us. rarz's RAR4
#   parser was returning empty filenames, ~2^32 unpacked sizes and month-00
#   dates while still reporting VALID; fixtures generated from our own
#   understanding of the format would have encoded the same misreading and
#   happily agreed with the bug. Only a genuine producer is an independent
#   oracle. The CONTENT, by contrast, is entirely our own deterministic data —
#   so there is no third-party payload or licensing question in the repo.
#
# Usage:  bash tests/generate_rar4_fixtures.sh
set -u

FIXTURES="tests/fixtures"
RAR4_NIXPKGS="github:NixOS/nixpkgs/nixos-23.11"   # rar 6.21

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

tree="$tmpdir/tree"
mkdir -p "$tree/subdir"

# --- Deterministic, self-owned content -------------------------------------
# Three entropy regimes, so the corpus exercises real compression rather than
# only trivially-compressible input:
#   text.txt   highly compressible (repeating structure)
#   mixed.bin  partly compressible (normal-distributed bytes cluster, so the
#              entropy sits between "runs of one character" and pure noise)
#   noise.bin  effectively incompressible (uniform bytes)
# `random --seed` implies deterministic PCG32, so reruns are byte-identical.
for i in $(seq 1 120); do
	printf 'Line %s: the quick brown fox jumps over the lazy dog %04d\n' "$i" "$i"
done > "$tree/text.txt"

random -b -c 6144 --seed 4242 --normalized > "$tree/mixed.bin" 2>/dev/null \
	|| die "random --normalized failed (is the 'random' tool on PATH?)"
random -b -c 4096 --seed 1337 > "$tree/noise.bin" 2>/dev/null \
	|| die "random failed"

printf 'nested payload for path-preservation checks\n' > "$tree/subdir/nested.txt"

# --- Generate with the OFFICIAL RAR4-capable rar ---------------------------
echo "Fetching rar 6.21 from $RAR4_NIXPKGS (one-time; RAR 7.x cannot write RAR4)..."
export NIXPKGS_ALLOW_UNFREE=1

gen() {
	# gen <output-name> <rar-args...>
	local out="$1"; shift
	nix shell --impure "$RAR4_NIXPKGS#rar" --command \
		bash -c "cd '$tree' && rar a -ma4 -idq $* '$tmpdir/$out' ." \
		|| die "rar failed generating $out"
	[ -f "$tmpdir/$out" ] || die "rar produced no $out"
	# Verify the magic really is RAR4 (52 61 72 21 1A 07 00), not RAR5.
	local magic
	magic=$(head -c 7 "$tmpdir/$out" | od -An -tx1 | tr -d ' \n')
	[ "$magic" = "526172211a0700" ] || die "$out is not RAR4 (magic $magic)"
	cp "$tmpdir/$out" "$FIXTURES/$out"
	echo "  wrote $FIXTURES/$out ($(wc -c < "$FIXTURES/$out") bytes)"
}

gen rar4_store.rar -m0     # store method — payload verifiable byte-for-byte
gen rar4_m3.rar    -m3     # default compression (v29 decoder path)
gen rar4_m5.rar    -m5     # maximum compression

# --- Independent verification ----------------------------------------------
# unrar is the oracle: every generated fixture must test clean, or the corpus
# itself is untrustworthy and any rarz result measured against it is noise.
echo "Verifying generated fixtures with unrar..."
for f in rar4_store.rar rar4_m3.rar rar4_m5.rar; do
	if unrar t "$FIXTURES/$f" >/dev/null 2>&1; then
		echo "  OK   $f (unrar: All OK)"
	else
		die "$f failed unrar verification — corpus is not trustworthy"
	fi
done

echo "RAR4 fixtures generated."
