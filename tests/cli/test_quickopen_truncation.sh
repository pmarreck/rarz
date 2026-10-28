#!/usr/bin/env bash
# Prove the specific ancillary-header contradiction behind 17 stricter results.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0; seen=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
for set_name in rar5_vol_store rar5_vol_m3 rar5_vol_large; do
	mkdir "$scratch/$set_name" || exit 1
	mapfile -t volumes < <(find tests/fixtures -maxdepth 1 -name "$set_name.part*.rar" | sort)
	[[ ${#volumes[@]} -gt 0 ]] || exit 1
	for source in "${volumes[@]}"; do cp "$source" "$scratch/$set_name/" || exit 1; done
	first="$scratch/$set_name/$(basename "${volumes[0]}")"
	observe_unrar_test "$first"
	[[ $unrar_t_class == valid ]] || fail "$set_name pristine reference control failed"
	observe_rarz_test "$RARZ" "$first"
	[[ $rarz_t_class == valid ]] || fail "$set_name pristine candidate control failed"
	while read -r name amount header expected_hex; do
		[[ $name == "$set_name".* ]] || continue
		seen=$((seen+1)); source="tests/fixtures/$name"; target="$scratch/$set_name/$name"
		expected_hash=$(awk -v path="$source" '$2==path {print $1}' docs/evidence/rar-fixtures.sha256)
		actual_hash=$(sha256sum "$source"); actual_hash=${actual_hash%% *}
		[[ ${#expected_hash} == 64 && $actual_hash == "$expected_hash" ]] || { fail "$name fixture identity differs"; continue; }
		hex=$(od -An -v -tx1 -j "$header" -N19 "$source" | tr -d ' \n')
		[[ $hex == "$expected_hex" ]] || { fail "$name independent QO header changed"; continue; }
		# All three literal producer headers encode size=14, type=3, flags=6,
		# a two-byte packed-size VINT, and the service name QO. The second
		# VINT byte is zero, so its low seven bits give the complete data size.
		first_size_byte=$(od -An -tu1 -j "$((header+7))" -N1 "$source" | tr -d ' \n')
		data_start=$((header+4+1+14)); data_end=$((data_start+(first_size_byte & 127)))
		size=$(wc -c < "$source"); cut=$((size-amount))
		[[ $data_start -le $cut && $cut -lt $data_end && $data_end -le $size ]] || { fail "$name/$amount lacks declared service-data shortfall"; continue; }
		out='' err='' rc=0
		capture legacy_mutate "$source" "$target" drop-suffix-v1 "$amount"
		[[ $rc == 0 ]] || { fail "$name/$amount mutation failed"; continue; }
		printf '%s\n' "$out"
		[[ $(wc -c < "$target") == "$cut" ]] && cmp -s -n "$cut" "$source" "$target" || fail "$name/$amount is not the exact source prefix"
		observe_unrar_test "$first"
		observe_rarz_test "$RARZ" "$first"
		[[ $unrar_t_class == valid && $rarz_t_class == damaged ]] || fail "$name/$amount expected specific stricter result, got $unrar_t_class/$rarz_t_class"
		cp "$source" "$target" || exit 1
	done <<'CASES'
rar5_vol_store.part1.rar 24 511842 826920060e0306f50000f5000080000102514f
rar5_vol_store.part1.rar 128 511842 826920060e0306f50000f5000080000102514f
rar5_vol_store.part2.rar 24 511905 bf51dbd90e0306bc0000bc000080000102514f
rar5_vol_store.part3.rar 24 511905 bf51dbd90e0306bc0000bc000080000102514f
rar5_vol_store.part4.rar 24 511905 bf51dbd90e0306bc0000bc000080000102514f
rar5_vol_store.part5.rar 24 511905 bf51dbd90e0306bc0000bc000080000102514f
rar5_vol_m3.part01.rar 24 51105 bf51dbd90e0306bc0000bc000080000102514f
rar5_vol_large.part1.rar 24 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part1.rar 128 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part2.rar 24 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part2.rar 128 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part3.rar 24 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part3.rar 128 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part4.rar 24 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part4.rar 128 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part5.rar 24 511850 e8b5079a0e0306f30000f3000080000102514f
rar5_vol_large.part5.rar 128 511850 e8b5079a0e0306f30000f3000080000102514f
CASES
done
[[ $seen == 17 ]] || fail "expected 17 exact stricter cases, saw $seen"
[[ $errors == 0 ]] || exit 1
printf 'PASS: 17 stricter volume results have declared quick-open payload shortfalls\n'
