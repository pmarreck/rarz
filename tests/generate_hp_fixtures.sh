#!/usr/bin/env bash
# Header-encrypted (-hp) fixtures, both families. rarz cannot read these
# without a password; the point of the corpus is that it must SAY so — the
# prior behavior CRC-checked ciphertext as if it were headers and reported
# "header CRC mismatch" / INVALID: false damage on intact archives.
# ONE-TIME, OFF-LINE; committed; password is a test artifact, not a secret.
# Usage:  nix develop -c bash tests/generate_hp_fixtures.sh
set -u
FIXTURES="tests/fixtures"; PW=SECRET
die() { echo "ERROR: $*" >&2; exit 1; }
[ -d "$FIXTURES" ] || die "run from repo root"
command -v rar >/dev/null 2>&1 || die "rar required (nix develop -c)"
command -v unrar >/dev/null 2>&1 || die "unrar required"
export NIXPKGS_ALLOW_UNFREE=1
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"
echo "secret contents here, deterministic" > "$work/f.txt"
( cd "$work" && rar a -idq -m3 -hp$PW "$project_root/$FIXTURES/rar5_hp.rar" f.txt ) || die "rar5 -hp"
nix shell --impure github:NixOS/nixpkgs/nixos-23.11#rar --command \
	bash -c "cd '$work' && rar a -ma4 -idq -m3 -hp$PW '$project_root/$FIXTURES/rar4_hp.rar' f.txt" || die "rar4 -hp"
for f in rar5_hp rar4_hp; do
	unrar t -p$PW "$FIXTURES/$f.rar" >/dev/null 2>&1 || die "$f fails unrar even with password"
	echo "  wrote $FIXTURES/$f.rar ($(wc -c < "$FIXTURES/$f.rar") bytes)"
done
