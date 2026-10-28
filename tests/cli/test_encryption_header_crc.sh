#!/usr/bin/env bash
# Replay the six corruption cases that previously resembled header encryption.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
for family in rar4 rar5; do
	observe_rarz_test "$RARZ" "tests/fixtures/${family}_hp.rar"
	[[ $rarz_t_class == unverifiable ]] || fail "$family genuine header encryption changed verdict"
done
for id in 357 5796 5806 5933 6060 6075; do
	record=$(jq -c --argjson id "$id" 'select(.id == $id)' docs/evidence/coverage-20261015-cases.jsonl)
	[[ -n $record ]] || { fail "missing replay $id"; continue; }
	fixture=$(jq -r .fixture <<< "$record")
	expected=$(jq -r .mutant_sha256 <<< "$record")
	mutant="$scratch/$id.rar"
	jq -c .record <<< "$record" > "$scratch/case.json" || exit 1
	out='' err='' rc=0
	capture timeout 15 corruption-reader apply --case "$scratch/case.json" -o "$mutant" "tests/fixtures/$fixture"
	[[ $rc == 0 ]] || { fail "replay $id failed: $err"; continue; }
	actual=$(sha256sum "$mutant"); actual=${actual%% *}
	[[ $actual == "$expected" ]] || { fail "replay $id bytes changed"; continue; }
	capture timeout 15 unrar t -p- -idq "$mutant"
	reference=$(classify_unrar_test "$rc" "$err")
	[[ $reference == damaged ]] || fail "reference no longer confirms damage for $id (exit $rc; $err)"
	observe_rarz_test "$RARZ" "$mutant"
	[[ $rarz_t_class == damaged ]] || fail "case $id returned $rarz_t_class"
done
[[ $errors == 0 ]] || exit 1
echo 'PASS: exact encrypted-looking corruption replays and genuine encryption controls'
