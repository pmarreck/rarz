#!/usr/bin/env bash
# RAR3 PPMd ("text compression") fixtures — rar 6.21 with -mct+ forces the
# PPMd path that -m5 chooses on its own for text-like data.
#
# WHY THIS CORPUS EXISTS
#   ppm.zig shipped as a simplified stand-in whose model never learned, whose
#   init misread the header, and whose 18 unit tests validated the stand-in
#   against itself. Nothing in the committed corpus was PPMd-compressed, so a
#   non-functional decoder survived every gate until a real-world archive
#   (validate's 1115 MB witness, 2026-08-27) hit both symptoms at once: an
#   instant false positive on one entry and minutes-per-entry escape churn on
#   others. These two fixtures reproduce both symptoms in ~4-14 KB.
#
# ONE-TIME, OFF-LINE. Generated archives are committed; the suite never needs
# rar. NOT BYTE-REPRODUCIBLE (mtimes embed) — `git checkout --` anything you
# did not mean to regenerate.
#
# Usage:  nix develop -c bash tests/generate_ppm_fixtures.sh
set -u

FIXTURES="tests/fixtures"
RAR4_NIXPKGS="github:NixOS/nixpkgs/nixos-23.11"   # rar 6.21

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v unrar >/dev/null 2>&1 || die "unrar is required (run under: nix develop -c)"
export NIXPKGS_ALLOW_UNFREE=1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"

# XML-ish content (the witness's failing entry was an Audacity project file)
# and plain prose — two different symbol distributions through the model.
awk 'BEGIN{print "<?xml version=\"1.0\"?>"; print "<project rate=\"44100\">";
	for(i=1;i<=3000;i++) printf "  <track name=\"t%d\" gain=\"%d.%02d\" pan=\"0.0\"><clip offset=\"%d\"/></track>\n", i, i%3, i%100, i*17;
	print "</project>"}' > "$work/doc.xml"
awk 'BEGIN{for(i=1;i<=2500;i++) printf "Paragraph %d. The quick brown fox jumps over the lazy dog near the river bank at dawn, %d times.\n", i, i%7}' > "$work/prose.txt"

gen() { # gen <output> <input>
	local out="$FIXTURES/$1" in="$2"
	rm -f "$out"
	nix shell --impure "$RAR4_NIXPKGS#rar" --command \
		bash -c "cd '$work' && rar a -ma4 -idq -m5 -mct+ '$project_root/$out' '$in'" \
		|| die "rar failed generating $1"
	[ -f "$out" ] || die "rar produced no $out"
	unrar t "$out" >/dev/null 2>&1 || die "$out failed unrar verification"
	echo "  wrote $out ($(wc -c < "$out") bytes)"
}

gen rar4_ppm_xml.rar   doc.xml
gen rar4_ppm_prose.rar prose.txt

echo "PPMd fixtures generated."
