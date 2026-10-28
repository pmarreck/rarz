#!/usr/bin/env bash
# Adjudicate exact retained cases using format facts, without reclassifying tool errors.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
seen=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
crc32_hex() { gzip -n -c | tail -c 8 | head -c 4 | od -An -tx4 --endian=little | tr -d ' \n'; }
[[ $(printf 123456789 | crc32_hex) == cbf43926 ]] || { fail 'independent gzip CRC control failed'; exit 1; }
for fixture in rar2_v20_m3.rar rar4_m3.rar rar5_m3.rar; do
	out='' err='' rc=0
	capture unrar t -p- -idq -qo- "tests/fixtures/$fixture"
	[[ $rc == 0 ]] || fail "reference rejected pristine $fixture"
done
for seed in 43 44; do
	records=docs/evidence/coverage-20261028-cases.jsonl
	[[ $seed == 43 ]] || records=docs/evidence/coverage-20261028-seed44-cases.jsonl
	while IFS= read -r record; do
		seen=$((seen+1))
		id=$(jq -r .id <<< "$record")
		fixture="tests/fixtures/$(jq -r .fixture <<< "$record")"
		expected=$(jq -r .mutant_sha256 <<< "$record")
		input_expected=$(jq -r .input_sha256 <<< "$record")
		actual=$(sha256sum "$fixture"); actual=${actual%% *}
		[[ $actual == "$input_expected" ]] || { fail "$seed:$id pristine identity differs"; continue; }
		jq -c .record <<< "$record" > "$scratch/case.json" || exit 1
		mutant="$scratch/$seed-$id.rar"
		out='' err='' rc=0
		capture timeout 15 corruption-reader apply --case "$scratch/case.json" -o "$mutant" "$fixture"
		[[ $rc == 0 ]] || { fail "$seed:$id replay failed"; continue; }
		actual=$(sha256sum "$mutant"); actual=${actual%% *}
		[[ $actual == "$expected" ]] || { fail "$seed:$id mutant identity differs"; continue; }
		case "$seed:$id" in
			43:1237) offset=7854; declared=48994 ;;
			43:3483) offset=4645; declared=33459 ;;
			43:3551) offset=4645; declared=62581 ;;
			43:3566) offset=4645; declared=30043 ;;
			43:3587) offset=4645; declared=7980 ;;
			44:1228) offset=7854; declared=47468 ;;
			44:1387) offset=11991; declared=36133 ;;
			44:3778) offset=4645; declared=29621 ;;
			43:5379) offset=9176; declared=0 ;;
			*) fail "unexpected historical case $seed:$id"; continue ;;
		esac
		if [[ $declared != 0 ]]; then
			actual=$(od -An -tu2 --endian=little -j "$((offset+5))" -N2 "$mutant" | tr -d ' \n')
			size=$(wc -c < "$mutant")
			[[ $actual == "$declared" && $actual -gt $((size-offset)) ]] || fail "$seed:$id oversized header evidence changed"
			original=$(od -An -tu2 --endian=little -j "$((offset+5))" -N2 "$fixture" | tr -d ' \n')
			[[ $original -ge 7 && $original -le $((size-offset)) ]] || fail "$seed:$id pristine header boundary invalid"
			[[ $(jq -r .reference.exit <<< "$record") == 6 ]] || fail "$seed:$id historical missing-volume outcome changed"
		else
			# This exact header has one size byte (39) followed by 39 body bytes.
			stored=$(od -An -tx4 --endian=little -j "$offset" -N4 "$mutant" | tr -d ' \n')
			original=$(dd if="$fixture" bs=1 skip=9180 count=40 status=none | crc32_hex)
			actual=$(dd if="$mutant" bs=1 skip=9180 count=40 status=none | crc32_hex)
			[[ $original == 6fc0a9b7 && $stored == "$original" && $actual == 1409d3bb && $stored != "$actual" ]] || fail 'RAR5 independent header CRC evidence changed'
			[[ $(jq -r .reference.exit <<< "$record") == 8 ]] || fail 'historical reference memory-limit outcome changed'
		fi
		[[ $(jq -r .reference.class <<< "$record") == tool-error ]] || fail "$seed:$id historical reference class changed"
		observe_rarz_test "$RARZ" "$mutant"
		[[ $rarz_t_class == damaged ]] || fail "$seed:$id candidate missed proven structural damage"
	done < <(jq -c 'select(.outcome=="inconclusive")' "$records")
done
[[ $seen == 9 ]] || fail "expected nine historical reference exceptions, got $seen"
[[ $errors == 0 ]] || exit 1
printf 'PASS: nine reference exceptions have independent structural-damage evidence\n'
