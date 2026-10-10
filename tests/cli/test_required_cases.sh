#!/usr/bin/env bash
# Tiny injected campaign records pin completeness independently of decoding.
set -u
source tests/support/validation-outcome.bash || exit 1
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors + 1)); }

fixture_case() {
	local expected=$1 required=$2 present=$3
	local result
	result=$(classify_required_fixture_set "$required" "$present")
	[[ $result == "$expected" ]] || fail "fixture set classified $result, expected $expected"
}
# Exhaust every subset of {a,b,c}; a and b are required, c is optional.
fixture_case incomplete $'a\nb' ''
fixture_case incomplete $'a\nb' a
fixture_case incomplete $'a\nb' b
fixture_case incomplete $'a\nb' c
fixture_case complete $'a\nb' $'a\nb'
fixture_case incomplete $'a\nb' $'a\nc'
fixture_case incomplete $'a\nb' $'b\nc'
fixture_case complete $'a\nb' $'a\nb\nc'
fixture_case complete $'a\nb' $'b\na\na'
fixture_case incomplete '' ''

while read -r expected_cases exercised required_controls passed_controls expected; do
	result=$(classify_required_trials "$expected_cases" "$exercised" "$required_controls" "$passed_controls")
	[[ $result == "$expected" ]] || fail "trials $expected_cases/$exercised controls $required_controls/$passed_controls: $result, expected $expected"
done <<'CASES'
12 12 1 1 complete
12 0 1 0 incomplete
0 0 1 0 incomplete
0 0 0 0 incomplete
12 12 0 0 incomplete
12 12 1 0 incomplete
12 11 1 1 incomplete
12 13 1 1 incomplete
12 12 1 2 incomplete
1 1 1 1 complete
5 5 2 1 incomplete
5 5 2 2 complete
bad 5 1 1 incomplete
CASES

scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
: > "$scratch/present"
out='' err='' rc=0
capture require_fixture_paths "$scratch/present"
[[ $rc == 0 ]] || fail 'existing required fixture must pass the real presence adapter'
capture require_fixture_paths "$scratch/present" "$scratch/missing"
[[ $rc != 0 ]] || fail 'missing required fixture must fail the real presence adapter'
capture require_fixture_paths
[[ $rc != 0 ]] || fail 'empty required fixture declaration must fail'

# Exercise the actual driver boundary with an empty injected corpus. Failure
# must come from the completeness guard, not a crash or missing executable.
RARZ=${RARZ:-zig-out/bin/rarz}
for driver in test_solid.sh test_precision_volumes.sh test_verify.sh; do
	capture env FIXTURES="$scratch" RARZ="$RARZ" bash "tests/cli/$driver"
	[[ $rc == 1 && $out == *'INCOMPLETE: required fixture set'* ]] || fail "$driver accepted or misclassified an unavailable required corpus (exit $rc)"
done

[[ $errors == 0 ]] || exit 1
printf 'PASS: required fixture sets, nonempty trials, designated must-detect controls, and presence adapter\n'
