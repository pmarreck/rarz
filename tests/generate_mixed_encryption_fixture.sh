#!/usr/bin/env bash
# Generate the mixed-encryption fixture: one PLAIN entry and one ENCRYPTED entry
# in a single archive.
#
# WHY THIS ARCHIVE EXISTS
#   `validate_rar*_payload` bailed out of the ENTIRE archive the moment any
#   encrypted content was seen:
#
#       if (structural.has_encrypted_content) return structural;   // is_valid=true
#
#   So one encrypted entry disabled payload verification for every other entry,
#   including unencrypted ones whose CRC32 we could check perfectly well. With
#   the plain entry's payload smashed:
#
#       unrar t -pSECRET  ->  data.txt - checksum error, Total errors: 1
#       rarz t            ->  VALID
#
#   That is a false pass on PROVEN damage in READABLE data — strictly worse than
#   the wholly-encrypted case, where at least nothing was checkable.
#
#   A wholly-encrypted fixture cannot catch this; the bug needs both kinds of
#   entry in one archive. That is why the earlier audit missed it.
#
# ONE-TIME, OFF-LINE. The generated archive is committed; the suite never needs
# `rar`. The password is in this script on purpose — the fixture is a test
# artifact, not a secret.
set -u

FIXTURES="tests/fixtures"
PW=SECRET

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$FIXTURES" ] || die "run from the repo root (missing $FIXTURES)"
command -v rar >/dev/null 2>&1 || die "rar is required (run under: nix develop -c)"
command -v unrar >/dev/null 2>&1 || die "unrar is required (run under: nix develop -c)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
project_root="$(pwd)"

# Deterministic, self-owned content. Compressible so the payload is genuinely
# decoded rather than stored.
awk 'BEGIN { for (i = 1; i <= 300; i++)
	printf "plain line %d: the quick brown fox jumps over the lazy dog\n", i }' \
	> "$work/plain.txt"
awk 'BEGIN { for (i = 1; i <= 300; i++)
	printf "secret line %d: the quick brown fox jumps over the lazy dog\n", i }' \
	> "$work/secret.txt"

out="$FIXTURES/rar5_encrypted_mixed.rar"
rm -f "$out"

# Two separate `rar a` invocations: the first entry unencrypted, the second
# encrypted. `-p` applies per invocation, which is how a real archive ends up
# with both kinds.
( cd "$work" && rar a -idq -m3 "$project_root/$out" plain.txt ) || die "rar failed (plain)"
( cd "$work" && rar a -idq -m3 -p$PW "$project_root/$out" secret.txt ) || die "rar failed (encrypted)"
[ -f "$out" ] || die "rar produced no $out"

# --- Independent verification ----------------------------------------------
# The fixture is worthless unless it really does contain BOTH kinds of entry.
# unrar marks encrypted entries with a leading '*' in its listing.
listing=$(unrar l "$out" 2>&1)
echo "$listing" | grep -qE '^\s+[^*].*plain\.txt'  || die "$out: plain.txt is not unencrypted"
echo "$listing" | grep -qE '^\*.*secret\.txt'      || die "$out: secret.txt is not encrypted"
unrar t -p$PW "$out" >/dev/null 2>&1 || die "$out failed unrar verification"

echo "  wrote $out ($(wc -c < "$out") bytes)"
echo "  plain.txt unencrypted + secret.txt encrypted, unrar: All OK"
echo "Mixed-encryption fixture generated."
