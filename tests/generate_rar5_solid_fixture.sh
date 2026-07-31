#!/usr/bin/env bash
# Generate the RAR5 solid fixture with the modern devshell `rar`.
#
# WHY A FOURTH GENERATOR
#   generate_fixtures.sh      -> RAR5 bulk corpus, but it opens with
#                                `rm -rf tests/fixtures`, so it cannot be run to
#                                add ONE archive without destroying the RAR2/RAR4
#                                corpora that took a wine install and a
#                                nixos-23.11 pin to produce.
#   generate_rar4_fixtures.sh -> RAR4/v29, needs rar 6.21 (7.x dropped -ma4)
#   generate_rar2_fixtures.sh -> RAR4/v20, needs rar 2.90 (6.x always emits v29)
#   this one                  -> RAR5 solid, additive and idempotent.
#
# WHY A SOLID FIXTURE MATTERS
#   In a solid archive every file is compressed as ONE continuous stream: the LZ
#   window and the Huffman tables carry over from file N-1 into file N. A decoder
#   that starts each file from a fresh state decodes file 0 correctly and garbage
#   thereafter — which for a file-integrity product is a FALSE POSITIVE on a
#   perfectly valid archive. The RAR2 corpus already carries `rar2_v20_solid.rar`;
#   without a RAR5 counterpart the gap would look like a legacy-format quirk
#   rather than the cross-format API defect it actually is.
#
#   The content is deliberately arranged so solidity has something to carry:
#   three files share a large amount of text, so the encoder emits cross-file
#   matches. Files whose content is independent would round-trip even with a
#   window that resets, so they cannot falsify the bug.
#
# ONE-TIME, OFF-LINE. The generated archive is committed; the suite and CI never
# need `rar`.
#
# Usage:  nix develop -c bash tests/generate_rar5_solid_fixture.sh
set -u

FIXTURES="tests/fixtures"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v rar >/dev/null 2>&1 || die "rar is required (run under: nix develop -c)"
command -v unrar >/dev/null 2>&1 || die "unrar is required (run under: nix develop -c)"
command -v random >/dev/null 2>&1 || die "the 'random' utility is required for deterministic payloads"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

project_root="$(pwd)"
tree="$work/tree"
mkdir -p "$tree/sub"

# --- Deterministic, self-owned content --------------------------------------
# shared.txt is quoted verbatim by two later files, so a solid stream can match
# ACROSS file boundaries. That cross-file match is the only thing that separates
# a correct solid decoder from a broken one; without it the fixture is vacuous.
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
random -b -c 16384 --seed 5001 --normalized > "$tree/mixed.bin" 2>/dev/null \
	|| die "random --normalized failed (is 'random' on PATH?)"
# Incompressible: forces a stored-in-a-solid-stream entry, a distinct code path.
random -b -c 4096 --seed 5002 > "$tree/noise.bin" 2>/dev/null || die "random failed"

printf 'nested payload for path handling\n' > "$tree/sub/nested.txt"

# --- Generate ---------------------------------------------------------------
# Solid decoding landed 2026-07-31, so this belongs in tests/fixtures/ proper,
# which Interop Gate A treats as "archives rarz must accept".
out="$FIXTURES/rar5_solid.rar"
rm -f "$out"
( cd "$tree" && rar a -s -m3 -r -idq "$project_root/$out" . ) \
	|| die "rar failed to produce $out"
[ -f "$out" ] || die "rar produced no $out"

magic=$(head -c 8 "$out" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "526172211a070100" ] || die "$out is not RAR5 (magic $magic)"

# --- Independent verification -----------------------------------------------
# unrar is the oracle. A fixture that does not test clean makes every rarz result
# measured against it noise. Also assert the archive really IS solid: `rar a -s`
# silently produces a NON-solid archive when there is nothing to share, and a
# non-solid fixture cannot falsify the bug it exists to catch.
unrar t "$out" >/dev/null 2>&1 || die "$out failed unrar verification"
unrar lt "$out" 2>&1 | grep -qi 'solid' || die "$out is not actually solid"

echo "  wrote $out ($(wc -c < "$out") bytes)"
echo "RAR5 solid fixture generated."
