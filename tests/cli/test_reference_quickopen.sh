#!/usr/bin/env bash
# Cached header copies must not replace primary-header integrity evidence.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
seen=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
out='' err='' rc=0
capture timeout 15 unrar t -p- -idq -qo- tests/fixtures/rar5_m3.rar
[[ $rc == 0 ]] || fail 'uncached reference rejected the pristine fixture'
for records in docs/evidence/coverage-20261015-cases.jsonl docs/evidence/coverage-20261028-cases.jsonl; do
	while IFS= read -r record; do
		seen=$((seen+1))
		id=$(jq -r .id <<< "$record")
		expected=$(jq -r .mutant_sha256 <<< "$record")
		jq -c .record <<< "$record" > "$scratch/case.json" || exit 1
		mutant="$scratch/$id.rar"
		capture timeout 15 corruption-reader apply --case "$scratch/case.json" -o "$mutant" tests/fixtures/rar5_m3.rar
		[[ $rc == 0 ]] || { fail "case $id replay failed"; continue; }
		actual=$(sha256sum "$mutant"); actual=${actual%% *}
		[[ $actual == "$expected" ]] || { fail "case $id bytes changed"; continue; }
		capture timeout 15 unrar t -p- -idq "$mutant"
		[[ $rc == 0 ]] || fail "case $id cached-header control changed"
		capture timeout 15 unrar t -p- -idq -qo- "$mutant"
		[[ $(classify_unrar_test "$rc" "$err") == damaged ]] || fail "case $id uncached reference did not confirm damage"
		observe_rarz_test "$RARZ" "$mutant"
		[[ $rarz_t_class == damaged ]] || fail "case $id rarz did not reject damaged primary header"
	done < <(jq -c 'select(.outcome == "disagreement")' "$records")
done
[[ $seen == 6 ]] || fail "expected all six recorded disagreements, got $seen"
[[ $errors == 0 ]] || exit 1
echo 'PASS: all six quick-open disagreements resolve to primary-header damage'
