#!/usr/bin/env bash
# Fixture for GH #15: a SOLID RAR5 archive whose x86-filter region straddles
# the circular-window wrap while the entry itself FITS the window.
#
# unpack50 applied filters only when the region was linear in the buffer; a
# wrapped region was silently skipped, its bytes emitted untransformed, and
# the CRC then blamed the ARCHIVE: unrar OK, rarz "payload CRC32 mismatch".
# The streaming path (entries larger than the window) already staged wrapped
# regions; the fit-in-window path did not. Reported by unxed in June.
#
# Shape: four self-owned x86 binaries of odd sizes, solid, -md128k — solid
# decoding walks the window to misaligned positions until some entry's filter
# region crosses the physical end of the buffer.
#
# ONE-TIME, OFF-LINE; committed archive; NOT byte-reproducible (mtimes).
# Usage:  nix develop -c bash tests/generate_wrap_filter_fixture.sh
set -u
FIXTURES="tests/fixtures"
die() { echo "ERROR: $*" >&2; exit 1; }
[ -d "$FIXTURES" ] || die "run from the repo root"
command -v rar >/dev/null 2>&1 || die "rar required (nix develop -c)"
command -v unrar >/dev/null 2>&1 || die "unrar required"
command -v zig >/dev/null 2>&1 || die "zig required"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"

for n in 90 130 170 210; do
	awk -v n=$n 'BEGIN{
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
	}' > "$work/g$n.c"
	zig cc -O1 -s -target x86_64-linux-musl -o "$work/prog$n" "$work/g$n.c" 2>/dev/null \
		|| die "compile failed for n=$n"
done

out="$FIXTURES/rar5_solid_wrap_filter.rar"
rm -f "$out"
( cd "$work" && rar a -idq -s -m5 -md128k "$project_root/$out" prog90 prog130 prog170 prog210 ) \
	|| die "rar failed"
unrar t "$out" >/dev/null 2>&1 || die "$out failed unrar verification"
echo "  wrote $out ($(wc -c < "$out") bytes)"
