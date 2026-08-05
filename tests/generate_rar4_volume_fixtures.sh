#!/usr/bin/env bash
# RAR4 multi-volume corpus. The gate doc listed RAR4 split volumes as having no
# committed producer corpus at all, and a differential check confirmed why that
# mattered: rarz reported INVALID on a RAR4 volume set unrar tests clean.
#
# Reporting DAMAGE for an unsupported feature is the worst possible framing —
# a missing capability is a tooling gap, not evidence the user's data is bad.
#
# Two sets, because the two paths differ:
#   store     — payload verifiable byte-for-byte, no decoder involved
#   compressed — exercises v29 decode across a volume boundary
#
# ONE-TIME, OFF-LINE. Generated archives are committed; the suite never needs rar.
#
# Usage:  nix develop -c bash tests/generate_rar4_volume_fixtures.sh
set -u

FIXTURES="tests/fixtures"
RAR4_NIXPKGS="github:NixOS/nixpkgs/nixos-23.11"   # rar 6.21 — RAR 7.x cannot write RAR4

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v unrar >/dev/null 2>&1 || die "unrar is required (run under: nix develop -c)"
export NIXPKGS_ALLOW_UNFREE=1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"

# Deterministic content. Big enough to span several volumes, and mixed entropy
# so the compressed set is not trivially all-literals.
awk 'BEGIN { for (i = 1; i <= 6000; i++)
	printf "line %d: the quick brown fox jumps over the lazy dog\n", i }' > "$work/text.txt"
random -b -c 120000 --seed 7777 > "$work/noise.bin" 2>/dev/null \
	|| die "random failed (is the 'random' tool on PATH?)"

gen() { # gen <prefix> <rar-args...>
	local prefix="$1"; shift
	rm -f "$FIXTURES/$prefix".part*.rar
	nix shell --impure "$RAR4_NIXPKGS#rar" --command \
		bash -c "cd '$work' && rar a -ma4 -idq $* '$work/$prefix.rar' text.txt noise.bin" \
		|| die "rar failed generating $prefix"

	local n=0
	for f in "$work/$prefix".part*.rar; do
		[ -f "$f" ] || continue
		cp "$f" "$FIXTURES/$(basename "$f")"
		n=$((n + 1))
	done
	[ "$n" -ge 2 ] || die "$prefix: expected a multi-volume set, got $n part(s)"

	# unrar is the oracle: it must test the whole set clean from part1, or the
	# fixture cannot support an "rarz should agree" assertion.
	# Volume numbering is zero-padded to the SET size (part1 vs part01), so the
	# first part is discovered, not assumed.
	local first
	first=$(ls "$FIXTURES/$prefix".part*.rar | sort | head -1)
	unrar t "$first" >/dev/null 2>&1 \
		|| die "$prefix failed unrar verification"
	echo "  wrote $n volumes for $prefix (unrar: All OK)"
}

gen rar4_vol_store -m0 -v100k
gen rar4_vol_m3    -m3 -v40k

echo "RAR4 multi-volume corpus generated."
