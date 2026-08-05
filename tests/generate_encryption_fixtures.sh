#!/usr/bin/env bash
# Generate the ENCRYPTION CLASSIFIER corpus: the three classes an archive can
# fall into, in both RAR4 and RAR5.
#
#   none   — no entry is encrypted
#   mixed  — some entries encrypted, some not
#   all    — every entry encrypted
#
# WHY A SET AND NOT ONE EXAMPLE
#   "Is this archive mixed-encryption?" is a CLASSIFIER over archives, not a
#   predicate over one file. A single mixed fixture can be passed by code that
#   answers "mixed" unconditionally. Only the full set — none/mixed/all, in
#   both families — separates a real classifier from a stuck one, so the test
#   that consumes these asserts on all three.
#
# WHY RAR4 IS HERE
#   `rarz_verify_file` checked for encryption on the RAR5 path and NOT on the
#   RAR4 path. An encrypted RAR4 STORE entry therefore had its ciphertext
#   hashed against the plaintext CRC32 stored in the header:
#
#       unrar t -pSECRET rar4_encrypted_all.rar  ->  All OK
#       rarz verify      rar4_encrypted_all.rar  ->  damaged
#
#   That is a false positive on a perfectly intact archive — the worst class of
#   error for an integrity tool, because it condemns good data. The store path
#   is the one that produces it (a compressed encrypted entry usually fails to
#   decode instead), so every all/mixed fixture here carries BOTH a stored and
#   a compressed encrypted entry.
#
# ONE-TIME, OFF-LINE. Generated archives are committed; the suite never needs
# `rar`. The password is in this script on purpose — these are test artifacts,
# not secrets.
#
# Usage:  nix develop -c bash tests/generate_encryption_fixtures.sh
set -u

FIXTURES="tests/fixtures"
PW=SECRET
RAR4_NIXPKGS="github:NixOS/nixpkgs/nixos-23.11"   # rar 6.21 — RAR 7.x cannot write RAR4

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v unrar >/dev/null 2>&1 || die "unrar is required (run under: nix develop -c)"
export NIXPKGS_ALLOW_UNFREE=1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"

# Deterministic, self-owned content. Compressible, so a compressed entry really
# exercises the decoder rather than falling back to store.
mk() {
	awk -v tag="$1" 'BEGIN { for (i = 1; i <= 300; i++)
		printf "%s line %d: the quick brown fox jumps over the lazy dog\n", tag, i }'
}
mk plain  > "$work/plain.txt"
mk plain2 > "$work/plain2.txt"
mk secret > "$work/secret.txt"
mk stored > "$work/secret_stored.txt"

# RAR4 needs the pinned rar 6.21; RAR5 uses whatever `rar` the flake provides.
# Each `rar a` invocation applies one -p setting, which is exactly how a real
# archive ends up holding both kinds of entry: it takes two separate calls.
rar4() { nix shell --impure "$RAR4_NIXPKGS#rar" --command \
	bash -c "cd '$work' && rar a -ma4 -idq $* " ; }
rar5() { bash -c "cd '$work' && rar a -idq $*" ; }

# $1 = output basename, $2 = 4|5, $3 = class (none|mixed|all)
build() {
	local out="$FIXTURES/$1" fam="$2" class="$3" add
	add=rar$fam
	rm -f "$out"
	case "$class" in
		none)
			$add "-m3 '$project_root/$out' plain.txt plain2.txt" || die "$1: plain"
			;;
		mixed)
			$add "-m3 '$project_root/$out' plain.txt"                  || die "$1: plain"
			$add "-m3 -p$PW '$project_root/$out' secret.txt"           || die "$1: secret"
			$add "-m0 -p$PW '$project_root/$out' secret_stored.txt"    || die "$1: stored"
			;;
		all)
			$add "-m3 -p$PW '$project_root/$out' secret.txt"           || die "$1: secret"
			$add "-m0 -p$PW '$project_root/$out' secret_stored.txt"    || die "$1: stored"
			;;
	esac
	[ -f "$out" ] || die "rar produced no $out"

	# Confirm the family really is what we asked for.
	local magic want
	magic=$(head -c 7 "$out" | od -An -tx1 | tr -d ' \n')
	want=$([ "$fam" = 4 ] && echo 526172211a0700 || echo 526172211a0701)
	[ "$magic" = "$want" ] || die "$out: wrong family (magic $magic, wanted $want)"

	# --- Independent verification ------------------------------------------
	# The fixture is worthless unless it really holds the classes it claims.
	# unrar marks an encrypted entry with a leading '*' in its listing, which is
	# an oracle we did not write.
	local listing enc_count plain_count
	listing=$(unrar l -p$PW "$out" 2>&1)
	enc_count=$(echo "$listing"   | grep -cE '^\*')
	plain_count=$(echo "$listing" | grep -cE '^[[:space:]]+[-rwx.]{7,}.*\.txt')
	case "$class" in
		none)  [ "$enc_count" -eq 0 ] || die "$out: expected 0 encrypted, got $enc_count" ;;
		mixed) { [ "$enc_count" -gt 0 ] && [ "$plain_count" -gt 0 ]; } \
			|| die "$out: not mixed (encrypted=$enc_count plain=$plain_count)" ;;
		all)   { [ "$enc_count" -gt 0 ] && [ "$plain_count" -eq 0 ]; } \
			|| die "$out: not wholly encrypted (encrypted=$enc_count plain=$plain_count)" ;;
	esac

	# The archive must be INTACT. Every test built on it asserts that rarz does
	# not cry damage; if the fixture were genuinely corrupt those tests would
	# pass for the wrong reason.
	unrar t -p$PW "$out" >/dev/null 2>&1 || die "$out failed unrar verification"

	echo "  wrote $out ($(wc -c < "$out") bytes, class=$class, encrypted=$enc_count plain=$plain_count)"
}

echo "Fetching rar 6.21 from $RAR4_NIXPKGS (one-time; RAR 7.x cannot write RAR4)..."
build rar4_encrypted_none.rar  4 none
build rar4_encrypted_mixed.rar 4 mixed
build rar4_encrypted_all.rar   4 all
build rar5_encrypted_none.rar  5 none
build rar5_encrypted_all.rar   5 all

echo "Encryption classifier corpus generated (rar5_encrypted_mixed.rar already committed)."
