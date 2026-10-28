#!/usr/bin/env bash
# Seed-44 case 214 changes a trailing match in a RAR2 producer fixture.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
fixture=tests/fixtures/rar2_v20_m3.rar
observe_rarz_test "$RARZ" "$fixture"
[[ $rarz_t_class == valid ]] || fail 'pristine RAR2 rejected'
cp "$fixture" "$scratch/mutant.rar" || exit 1
chmod u+w "$scratch/mutant.rar" || exit 1
printf '\xfd' | dd of="$scratch/mutant.rar" bs=1 seek=12393 conv=notrunc 2>/dev/null || exit 1
actual=$(sha256sum "$scratch/mutant.rar"); actual=${actual%% *}
[[ $actual == 43d9c3f33b8a3733c22259b3657d8f3a86b342304361016ead15c367d5c58d57 ]] || exit 1
out='' err='' rc=0
capture timeout 15 unrar t -p- -idq -qo- "$scratch/mutant.rar"
[[ $(classify_unrar_test "$rc" "$err") == damaged ]] || fail 'reference did not confirm exact case damage'
observe_rarz_test "$RARZ" "$scratch/mutant.rar"
[[ $rarz_t_class == damaged ]] || fail "case 214 returned $rarz_t_class"
[[ $errors == 0 ]] || exit 1
echo 'PASS: RAR2 seed-44 decoded-size regression'
