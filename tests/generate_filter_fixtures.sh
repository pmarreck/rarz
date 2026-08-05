#!/usr/bin/env bash
# Fixtures for two false-positive classes found by differential sweep against
# unrar on 2026-08-05. Both are archives unrar tests CLEAN that rarz called
# damaged — an integrity tool condemning good data.
#
# 1. x86 FILTER (rar5_x86_filter / rar4_x86_filter)
#    RAR applies an E8/E8E9 filter to executable content, rewriting CALL/JMP
#    targets to absolute addresses before compressing. Reversing it needs the
#    CUMULATIVE file offset and a FIXED 0x1000000 wrap constant (unrar 7.20
#    unpack50.cpp:427). rarz passed the file offset where the constant belonged
#    and dropped it from the offset term, so every filtered region decoded to
#    the wrong bytes and the CRC32 failed.
#
#    Proven causally, not inferred: the SAME content archived with `-mc-`
#    (filters disabled) validated fine, and with filters on it did not.
#
#    Content is a self-owned program generated here and compiled from source, so
#    the corpus carries no third-party binary. It needs REAL x86 structure —
#    synthetic E8-sprinkled bytes do not trip rar's filter heuristic, so a
#    hand-rolled byte pattern would have produced a fixture that proves nothing.
#
# 2. RAR4 WINDOW WRAP (rar4_large_window)
#    Any RAR4 file larger than the 4 MB dictionary failed to decode. The
#    boundary was measured exactly: 4096 KB validates, 4608 KB does not.
#
# ONE-TIME, OFF-LINE. Generated archives are committed; the suite never needs
# rar or a C compiler.
#
# Usage:  nix develop -c bash tests/generate_filter_fixtures.sh
set -u

FIXTURES="tests/fixtures"
RAR4_NIXPKGS="github:NixOS/nixpkgs/nixos-23.11"   # rar 6.21 — RAR 7.x cannot write RAR4

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v unrar >/dev/null 2>&1 || die "unrar is required (run under: nix develop -c)"
command -v zig   >/dev/null 2>&1 || die "zig is required (run under: nix develop -c)"
export NIXPKGS_ALLOW_UNFREE=1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"

# --- Self-owned x86 payload -------------------------------------------------
# Many small mutually-recursive functions, so the compiler emits a dense field
# of CALL rel32 — exactly what the E8 filter targets. -O1 keeps the calls from
# being inlined away; -s strips symbols so the fixture stays small.
awk -v n=200 'BEGIN{
	print "#include <stdint.h>"
	for (i=0;i<n;i++) printf "int f%d(int);\n", i
	for (i=0;i<n;i++) {
		printf "int f%d(int x){ x = x*%d + %d;", i, (i*7+3)%997, i
		printf " if (x & 1) x += f%d(x>>1);", (i*31+7)%n
		printf " if (x & 2) x ^= f%d(x>>2);", (i*53+11)%n
		printf " return x; }\n"
	}
	printf "int main(void){ int s=0; "
	for (i=0;i<n;i++) printf "s += f%d(%d);", i, i
	print " return s; }"
}' > "$work/gen.c"
zig cc -O1 -s -target x86_64-linux-musl -o "$work/prog" "$work/gen.c" 2>/dev/null \
	|| die "failed to compile the x86 payload"

# --- RAR4 window-wrap payload ----------------------------------------------
# Comfortably past the 4 MB RAR4 dictionary, and highly compressible so the
# committed archive stays small.
awk 'BEGIN { for (i = 1; i <= 100000; i++)
	printf "line %d: the quick brown fox jumps over the lazy dog\n", i }' > "$work/large.txt"

emit() { # emit <output> <4|5> <file> <rar-args...>
	local out="$FIXTURES/$1" fam="$2" file="$3"; shift 3
	rm -f "$out"
	if [ "$fam" = 4 ]; then
		nix shell --impure "$RAR4_NIXPKGS#rar" --command \
			bash -c "cd '$work' && rar a -ma4 -idq $* '$project_root/$out' '$file'" \
			|| die "rar failed generating $1"
	else
		( cd "$work" && rar a -idq $* "$project_root/$out" "$file" ) \
			|| die "rar failed generating $1"
	fi
	[ -f "$out" ] || die "rar produced no $out"

	local magic want
	magic=$(head -c 7 "$out" | od -An -tx1 | tr -d ' \n')
	want=$([ "$fam" = 4 ] && echo 526172211a0700 || echo 526172211a0701)
	[ "$magic" = "$want" ] || die "$out: wrong family (magic $magic)"

	# unrar is the oracle. Every one of these fixtures exists to assert that
	# rarz agrees with it, so a fixture unrar rejects would make the test
	# meaningless.
	unrar t "$out" >/dev/null 2>&1 || die "$out failed unrar verification"
	echo "  wrote $out ($(wc -c < "$out") bytes)"
}

emit rar5_x86_filter.rar   5 prog      -m5
emit rar4_x86_filter.rar   4 prog      -m5
emit rar4_large_window.rar 4 large.txt -m5
emit rar5_large_window.rar 5 large.txt -m5

echo "Filter and window fixtures generated."
