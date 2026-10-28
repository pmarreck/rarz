#!/usr/bin/env bash
# Independent producer/reference controls for optional legacy header fields.
set -u
export TZ=UTC0 LC_ALL=C
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
fixture=$(realpath tests/fixtures/rar4_extended_times.rar) || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
capture unrar t -p- -idq "$fixture"
[[ $rc == 0 ]] || fail 'reference rejected timestamp producer fixture'
capture unrar lt -p- "$fixture"
[[ $rc == 0 && $out == *'mtime: 2000-02-29 00:00:01,123456700'* && $out == *'atime: 2000-02-29 00:00:03,765432100'* ]] || fail 'independent extended-time oracle changed'
capture "$RARZ" t "$fixture"
[[ $rc == 0 ]] || fail 'candidate rejected timestamp producer fixture'
capture "$RARZ" verify "$fixture"
[[ $rc == 0 ]] || fail 'candidate could not verify timestamp producer fixture'
capture "$RARZ" x "$fixture" "$scratch"
[[ $rc == 0 ]] || fail 'candidate could not extract timestamp producer fixture'
printf 'independent optional-field control\n' > "$scratch/expected"
cmp "$scratch/expected" "$scratch/data" >/dev/null || fail 'timestamp fixture payload differs'
[[ $errors == 0 ]] || exit 1
printf 'PASS: RAR4 optional fields retain independent timestamp and payload evidence\n'
