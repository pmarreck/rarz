#!/usr/bin/env bash
# Exact-byte controls for versioned preservation of the older mutation operators.
set -u
source tests/support/capture.bash || exit 1
source tests/support/legacy-mutation.bash || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
printf '\x00\x01\xa5\xff\x7f' > "$scratch/source"
cp "$scratch/source" "$scratch/original" || exit 1
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
for op in overwrite-byte-v1 xor-byte-v1 drop-suffix-v1; do
	case $op in
		overwrite*) parameter=1; value=165; expected='\x00\xa5\xa5\xff\x7f' ;;
		xor*) parameter=1; value=165; expected='\x00\xa4\xa5\xff\x7f' ;;
		drop*) parameter=2; value=0; expected='\x00\x01\xa5' ;;
	esac
	out='' err='' rc=0
	capture legacy_mutate "$scratch/source" "$scratch/mutant" "$op" "$parameter" "$value"
	[[ $rc == 0 ]] || { fail "$op failed: $err"; continue; }
	printf '%b' "$expected" > "$scratch/expected"
	cmp -s "$scratch/expected" "$scratch/mutant" || fail "$op bytes differ"
	jq -e --arg op "$op" '.schema=="rarz-legacy-mutation/v1" and .operator==$op and .unchanged==false and (.input_sha256|length)==64 and (.mutant_sha256|length)==64' <<< "$out" >/dev/null || fail "$op record invalid"
	jq -c .record <<< "$out" > "$scratch/case.json" || exit 1
	capture corruption-reader apply --case "$scratch/case.json" -o "$scratch/replay" "$scratch/source"
	[[ $rc == 0 ]] && cmp -s "$scratch/mutant" "$scratch/replay" || fail "$op exact replay failed"
done
capture legacy_mutate "$scratch/source" "$scratch/mutant" overwrite-byte-v1 2 165
[[ $rc == 0 ]] && jq -e '.unchanged==true' <<< "$out" >/dev/null || fail 'unchanged overwrite was hidden'
for spec in 'overwrite-byte-v1 5 165' 'xor-byte-v1 0 256' 'drop-suffix-v1 5 0' 'drop-suffix-v1 0 0' 'unknown-v1 0 0'; do
	read -r op parameter value <<< "$spec"
	printf 'sentinel' > "$scratch/mutant"
	capture legacy_mutate "$scratch/source" "$scratch/mutant" "$op" "$parameter" "$value"
	[[ $rc != 0 && $(cat "$scratch/mutant") == sentinel ]] || fail "invalid $spec changed output"
done
capture legacy_mutate "$scratch/source" "$scratch/source" xor-byte-v1 0 165
[[ $rc != 0 ]] || fail 'source alias accepted'
ln "$scratch/source" "$scratch/hardlink" || exit 1
capture legacy_mutate "$scratch/source" "$scratch/hardlink" xor-byte-v1 0 165
[[ $rc != 0 ]] || fail 'source hardlink accepted'
ln -s "$scratch/source" "$scratch/symlink" || exit 1
capture legacy_mutate "$scratch/source" "$scratch/symlink" xor-byte-v1 0 165
[[ $rc != 0 ]] || fail 'source symlink accepted'
cmp -s "$scratch/source" "$scratch/original" || fail 'source changed'
[[ $errors == 0 ]] || exit 1
printf 'PASS: versioned legacy mutations preserve exact bytes, replay, no-ops, and source isolation\n'
