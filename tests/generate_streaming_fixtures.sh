#!/usr/bin/env bash
# Fixtures for STREAMING verification: RAR5 entries far larger than their own
# dictionary window.
#
# WHY
#   unpack50 held each entry in the circular window and emitted once at the
#   end, so an entry past the window had already overwritten its own opening
#   bytes — the same defect fixed in unpack29 (2026-08-05, at 4 MB) and
#   unpack20 (2026-08-06, at 64 KB). RAR5 made it rare because rar sizes the
#   dictionary to the file by default, but -md picks it explicitly:
#
#       rar a -m3 -md128k big.rar 18MB.txt   ->  unrar OK, rarz INVALID
#
#   A false positive, and the blocker behind validate's 1 GiB deep-validation
#   cap (Peter, 2026-08-27: "NOTHING is too large for deep validation").
#
#   Two fixtures: plain text (the pure streaming path), and x86 content (the
#   streaming path INTERACTING with filters, whose regions must be transformed
#   before their bytes leave the window).
#
# ONE-TIME, OFF-LINE. Generated archives are committed; the suite never needs
# rar or a C compiler.
#
# Usage:  nix develop -c bash tests/generate_streaming_fixtures.sh
set -u

FIXTURES="tests/fixtures"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v rar   >/dev/null 2>&1 || die "rar is required (run under: nix develop -c)"
command -v unrar >/dev/null 2>&1 || die "unrar is required (run under: nix develop -c)"
command -v zig   >/dev/null 2>&1 || die "zig is required (run under: nix develop -c)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"

# ~3.6 MB of compressible text against a 128 KB dictionary: entry is ~28x the
# window while the committed archive stays around 100 KB.
awk 'BEGIN { for (i = 1; i <= 60000; i++)
	printf "line %d: the quick brown fox jumps over the lazy dog %d\n", i, i % 997 }' \
	> "$work/big.txt"

# Self-owned x86 payload, same generator as tests/generate_filter_fixtures.sh:
# dense mutually-recursive CALLs so rar's E8 filter engages. n=1500 gives a
# ~2 MB binary — 16x the 128 KB window.
awk -v n=1500 'BEGIN{
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

emit() { # emit <output> <file> <rar-args...>
	local out="$FIXTURES/$1" file="$2"; shift 2
	rm -f "$out"
	( cd "$work" && rar a -idq "$@" "$project_root/$out" "$file" ) \
		|| die "rar failed generating $1"
	[ -f "$out" ] || die "rar produced no $out"
	unrar t "$out" >/dev/null 2>&1 || die "$out failed unrar verification"
	echo "  wrote $out ($(wc -c < "$out") bytes)"
}

emit rar5_stream_text.rar   big.txt -m3 -md128k
emit rar5_stream_filter.rar prog    -m5 -md128k

echo "Streaming fixtures generated."
