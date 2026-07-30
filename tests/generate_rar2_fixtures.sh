#!/usr/bin/env bash
# Generate RAR 2.x (unpack version 20) fixtures using the ORIGINAL RAR 2.90.
#
# WHY A THIRD GENERATOR
#   generate_fixtures.sh      -> RAR5, and it starts with `rm -rf tests/fixtures`
#   generate_rar4_fixtures.sh -> RAR4/v29, needs rar 6.21 (7.x dropped -ma4)
#   this one                  -> RAR4/v20, needs rar 2.90 (6.x always emits v29)
#
# The unpack version is chosen by the ENCODER, not by a switch: every modern rar
# writes v29 for compressed data even with -ma4. Only a period-correct binary
# emits v20, so this reaches for RAR 2.90 (2001) and runs it under wine.
#
# ONE-TIME, OFF-LINE. Generated archives are committed; the suite and CI never
# need wine or the old binary.
#
# WHY THIS CORPUS EXISTS AT ALL
#   unpack20.zig had ~1160 lines and 18 unit tests but had NEVER decoded a real
#   v20 archive — the tests were written from the same understanding as the
#   decoder, so they agreed with it. unpack29 had six defects hiding behind
#   exactly that arrangement. Old RAR files are also the ones most likely to be
#   met in the field by a file-integrity product, so they matter most.
#
# WHY MULTIPLE ARCHIVES PER VERSION
#   A single fixture only proves the paths that one archive happens to take.
#   Each compression level selects different encoder behaviour, and payload
#   entropy decides whether the LZ/Huffman machinery is exercised at all (an
#   incompressible file is simply stored, which round-trips even with a broken
#   decoder). This emits several archives across methods, entropy levels, file
#   counts and directory shapes.
#
# Usage:  bash tests/generate_rar2_fixtures.sh
set -u

FIXTURES="tests/fixtures"
RAR290_URL="https://www.rarlab.com/rar/wrar290.exe"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v wine >/dev/null 2>&1 || die "wine is required to run RAR 2.90"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- Obtain the period-correct encoder -------------------------------------
# wrar290.exe is itself a RAR self-extracting archive, so unrar can pull the
# console Rar.exe out of it without executing the installer.
echo "Fetching RAR 2.90 (one-time; modern rar cannot emit v20)..."
curl -sS -o "$work/wrar290.exe" "$RAR290_URL" || die "download failed"
unrar x -o+ "$work/wrar290.exe" Rar.exe "$work/" >/dev/null 2>&1 \
	|| die "could not extract Rar.exe from the SFX"
[ -f "$work/Rar.exe" ] || die "Rar.exe missing after extraction"

# --- Deterministic, self-owned content, spanning entropy levels -------------
tree="$work/tree"
mkdir -p "$tree/sub/deeper"

for i in 1 2 3; do
	awk -v n="$i" 'BEGIN { for (j = 1; j <= 120; j++)
		printf "File %s line %d: the quick brown fox jumps over the lazy dog\n", n, j }' \
		> "$tree/text$i.txt"
done
# Partially compressible: normal-distributed bytes cluster around a mean, so the
# entropy coder is genuinely exercised — unlike pure repetition or pure noise,
# either of which can round-trip even when the decoder is wrong.
random -b -c 8192 --seed 2001 --normalized > "$tree/mixed.bin" 2>/dev/null \
	|| die "random --normalized failed (is 'random' on PATH?)"
random -b -c 4096 --seed 2002 > "$tree/noise.bin" 2>/dev/null || die "random failed"
printf 'nested payload for path handling\n' > "$tree/sub/nested.txt"
printf 'deeper payload\n' > "$tree/sub/deeper/deep.txt"

# --- Generate ---------------------------------------------------------------
# Rar.exe must live in the directory we run from, and paths must be relative:
# wine does not resolve absolute Unix paths passed as program arguments.
cp "$work/Rar.exe" "$tree/Rar.exe"

gen() {
	# gen <output-name> <rar-args...>
	local out="$1"; shift
	( cd "$tree" && WINEDEBUG=-all wine Rar.exe a -inul -r '-x*.exe' "$@" "$out" . ) \
		>/dev/null 2>&1
	[ -f "$tree/$out" ] || die "RAR 2.90 produced no $out"
	mv "$tree/$out" "$work/$out"
	local magic
	magic=$(head -c 7 "$work/$out" | od -An -tx1 | tr -d ' \n')
	[ "$magic" = "526172211a0700" ] || die "$out is not RAR4-family (magic $magic)"
	local dest="$FIXTURES/$out"
	case "$out" in rar2_v20_store.rar) ;; *) mkdir -p "$FIXTURES/known_gaps"; dest="$FIXTURES/known_gaps/$out" ;; esac
	cp "$work/$out" "$dest"
	echo "  wrote $dest ($(wc -c < "$dest") bytes)"
}

# NOTE: only the store archive lands in tests/fixtures/ proper. Interop Gate A
# treats that directory as "archives rarz must accept", and the COMPRESSED v20
# archives below cannot be decoded yet (unpack20 is broken on real data — see
# PLAN.md). They are still generated and committed, under known_gaps/, so the
# gap is measurable and the fixtures are ready the moment the decoder works.
gen rar2_v20_store.rar   -m0        # store: header/CRC paths, no decoder
gen rar2_v20_m1.rar      -m1        # fastest compression
gen rar2_v20_m3.rar      -m3        # default
gen rar2_v20_m5.rar      -m5        # maximum
gen rar2_v20_mm.rar      -mm -m3    # multimedia compression (v20 audio path)
gen rar2_v20_solid.rar   -s -m3     # solid: shared window/tables across files

# --- Independent verification ----------------------------------------------
# unrar is the oracle. If a generated fixture does not test clean, the corpus is
# untrustworthy and any rarz result measured against it is noise.
echo "Verifying with unrar..."
for f in rar2_v20_store rar2_v20_m1 rar2_v20_m3 rar2_v20_m5 rar2_v20_mm rar2_v20_solid; do
	if unrar t "$FIXTURES/$f.rar" >/dev/null 2>&1; then
		p="$FIXTURES/$f.rar"; [ -f "$p" ] || p="$FIXTURES/known_gaps/$f.rar"
		v=$(unrar lt "$p" 2>&1 | grep -o 'RAR [0-9.]*(v[0-9]*)' | sort -u | tr '\n' ' ')
		echo "  OK   $f.rar  ($v)"
	else
		die "$f.rar failed unrar verification"
	fi
done

echo "RAR 2.x (v20) fixtures generated."
