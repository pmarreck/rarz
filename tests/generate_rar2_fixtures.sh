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
# NOT BYTE-REPRODUCIBLE: RAR stores each file's mtime in the header, and the
# payloads are created fresh in a temp dir on every run, so re-running this
# rewrites every fixture with different bytes for identical content. When adding
# a fixture, `git checkout --` the ones you did not mean to touch. Churning them
# would silently invalidate the byte-exact regression tests built on them.
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
	# Only solid remains unsupported (see PLAN.md 4f); everything else is
	# verified byte-identical to unrar and belongs in the all-valid gate.
	# Solid support landed 2026-07-31; every fixture now belongs in the all-valid gate.
	cp "$work/$out" "$dest"
	echo "  wrote $dest ($(wc -c < "$dest") bytes)"
}

# All six land in tests/fixtures/ proper, which Interop Gate A treats as
# "archives rarz must accept". They did not always: the compressed archives sat
# in known_gaps/ until unpack20 was fixed (2026-07-30), and the solid one until
# sequential decoding landed (2026-07-31). Promotion out of known_gaps/ is how
# this project records that a gap actually closed.
gen rar2_v20_store.rar   -m0        # store: header/CRC paths, no decoder
gen rar2_v20_m1.rar      -m1        # fastest compression
gen rar2_v20_m3.rar      -m3        # default
gen rar2_v20_m5.rar      -m5        # maximum
gen rar2_v20_mm.rar      -mm -m3    # multimedia compression (v20 audio path)
gen rar2_v20_solid.rar   -s -m3     # solid: shared window/tables across files

# --- Entries LARGER than the dictionary -------------------------------------
# The corpus above is all small files, so it never exercised what happens when
# an entry exceeds the sliding window. Two separate defects hid behind that,
# both reporting DAMAGE on archives unrar tests clean:
#
#   md64   — v20 held the whole entry in the window and emitted once at the
#            end, so anything past the window had overwritten its own opening
#            bytes. With RAR 2.x windows being 64 KB-1 MB (not RAR4's 4 MB),
#            ordinary files trip this. Boundary measured: 58 KB validated,
#            88 KB did not, with a 64 KB dictionary.
#   md1024 — rarz capped the v20 dictionary at 256 KB, but the reference
#            applies one uncapped formula for every RAR4 unpack version
#            (arcread.cpp:268, `0x10000 << ((Flags & LHD_WINDOWMASK) >> 5)`).
#            RAR 2.x accepts -md512 and -md1024, so the cap silently gave the
#            decoder a window smaller than the encoder used.
#
# Both files are ~750 KB of compressible text, so the committed archives stay
# under 30 KB while the DECODED entry is comfortably past both limits.
big="$tree/big.txt"
awk 'BEGIN { for (i = 1; i <= 13000; i++)
	printf "line %d: the quick brown fox jumps over the lazy dog %d\n", i, i % 991 }' > "$big"

gen_one() {
	# gen_one <output-name> <rar-args...> — single file, not the whole tree.
	local out="$1"; shift
	( cd "$tree" && WINEDEBUG=-all wine Rar.exe a -inul "$@" "$out" big.txt ) >/dev/null 2>&1
	[ -f "$tree/$out" ] || die "RAR 2.90 produced no $out"
	mv "$tree/$out" "$FIXTURES/$out"
	echo "  wrote $FIXTURES/$out ($(wc -c < "$FIXTURES/$out") bytes)"
}
gen_one rar2_v20_md64_large.rar   -m3 -md64     # entry >> window
gen_one rar2_v20_md1024_large.rar -m3 -md1024   # dictionary above the old cap

# --- Independent verification ----------------------------------------------
# unrar is the oracle. If a generated fixture does not test clean, the corpus is
# untrustworthy and any rarz result measured against it is noise.
echo "Verifying with unrar..."
for f in rar2_v20_store rar2_v20_m1 rar2_v20_m3 rar2_v20_m5 rar2_v20_mm rar2_v20_solid \
		rar2_v20_md64_large rar2_v20_md1024_large; do
	if unrar t "$FIXTURES/$f.rar" >/dev/null 2>&1; then
		v=$(unrar lt "$FIXTURES/$f.rar" 2>&1 | grep -o 'RAR [0-9.]*(v[0-9]*)' | sort -u | tr '\n' ' ')
		echo "  OK   $f.rar  ($v)"
	else
		die "$f.rar failed unrar verification"
	fi
done

echo "RAR 2.x (v20) fixtures generated."
