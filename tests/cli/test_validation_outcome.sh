#!/usr/bin/env bash
# Classify recorded outcomes independently of decoder behavior, then exercise
# the real process adapter. Synthetic statuses never substitute for decoding.
set -u
source tests/support/validation-outcome.bash || exit 1
errors=0
cases=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors + 1)); }

# Each row declares the complete set of exit codes accepted in each category.
# Sweep every shell exit code, including signal and timeout outcomes, against
# every output shape. A misleading line cannot override process failure.
check_sets() {
	local label=$1 output=$2 want_valid=$3 want_damage=$4 want_incomplete=$5
	local status outcome valid='' damaged='' incomplete=''
	for ((status = 0; status <= 255; status++)); do
		outcome=$(classify_rarz_test "$status" "$output")
		case "$outcome" in
			valid) valid+="$status " ;;
			damaged) damaged+="$status " ;;
			unverifiable) incomplete+="$status " ;;
			tool-error) ;;
			*) fail "$label: unrecognized classification '$outcome' for exit $status" ;;
		esac
		cases=$((cases + 1))
	done
	[[ $valid == "$want_valid" ]] || fail "$label: valid exit set '$valid', expected '$want_valid'"
	[[ $damaged == "$want_damage" ]] || fail "$label: damaged exit set '$damaged', expected '$want_damage'"
	[[ $incomplete == "$want_incomplete" ]] || fail "$label: incomplete exit set '$incomplete', expected '$want_incomplete'"
}

check_sets valid 'Validation: VALID' '0 ' '' ''
check_sets invalid 'Validation: INVALID' '' '1 ' ''
check_sets encrypted 'Validation: UNVERIFIABLE' '' '' '69 '
check_sets multiline $'Testing archive: fixture.rar\nFormat: RAR5\nValidation: VALID\n' '0 ' '' ''
check_sets crlf $'Format: RAR5\r\nValidation: INVALID\r\n' '' '1 ' ''
check_sets empty '' '' '' ''
check_sets bare-valid 'VALID' '' '' ''
check_sets bare-invalid 'INVALID' '' '' ''
check_sets prefix 'Validation: VALIDATED' '' '' ''
check_sets suffix 'Validation: VALID extra' '' '' ''
check_sets filename 'Testing archive: Validation: VALID' '' '' ''
check_sets unknown 'Validation: UNKNOWN' '' '' ''
check_sets duplicate $'Validation: VALID\nValidation: VALID' '' '' ''
check_sets conflicting $'Validation: INVALID\nValidation: VALID' '' '' ''
check_sets truncated 'Validation: INVAL' '' '' ''
check_sets malformed-duplicate $'Validation:VALID\nValidation: VALID' '' '' ''

reference_cases=0
check_reference_sets() {
	local label=$1 diagnostic=$2 want_valid=$3 want_damage=$4
	local status outcome valid_codes='' damaged_codes=''
	for ((status = 0; status <= 255; status++)); do
		outcome=$(classify_unrar_test "$status" "$diagnostic")
		case "$outcome" in
			valid) valid_codes+="$status " ;;
			damaged) damaged_codes+="$status " ;;
			tool-error) ;;
			*) fail "$label: unrar exit $status: unexpected classification '$outcome'" ;;
		esac
		reference_cases=$((reference_cases + 1))
	done
	[[ $valid_codes == "$want_valid" && $damaged_codes == "$want_damage" ]] || fail "$label: unrar valid='$valid_codes' damaged='$damaged_codes', expected '$want_valid'/'$want_damage'"
}
check_reference_sets ordinary '' '0 ' '3 '
check_reference_sets corrupt-comment 'The archive comment is corrupt' '' '0 3 '
check_reference_sets corrupt-comment-crlf $'The archive comment is corrupt\r\n' '' '0 3 '
check_reference_sets corrupt-comment-prefix 'Cannot open The archive comment is corrupt' '0 ' '3 '
check_reference_sets corrupt-comment-filename 'The archive comment is corrupt.rar' '0 ' '3 '
check_reference_sets generic-warning 'Unrecognized warning' '0 ' '3 '
check_reference_sets truncated 'Unexpected end of archive' '' '1 3 '
check_reference_sets truncated-crlf $'Unexpected end of archive\r\nTruncated at the service block: quick open information\r\n' '' '1 3 '
check_reference_sets filename 'Cannot open Unexpected end of archive.rar' '0 ' '3 '

while read -r reference actual expected; do
	result=$(classify_mutation_pair "$reference" "$actual")
	[[ $result == "$expected" ]] || fail "mutation pair $reference/$actual: $result, expected $expected"
done <<'CASES'
valid valid benign
valid damaged stricter
valid unverifiable inconclusive
valid tool-error inconclusive
damaged valid missed
damaged damaged detected
damaged unverifiable inconclusive
damaged tool-error inconclusive
tool-error valid inconclusive
tool-error damaged inconclusive
tool-error unverifiable inconclusive
tool-error tool-error inconclusive
CASES

RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/rarz-outcomes.XXXXXXXX") || exit 1
trap 'rm -rf "$scratch"' EXIT
real_case() {
	local label=$1 expected=$2 path=$3
	observe_rarz_test "$RARZ" "$path"
	[[ $rarz_t_class == "$expected" ]] || fail "$label: $rarz_t_class (exit $rarz_t_status), expected $expected"
}
real_case pristine valid tests/fixtures/rar5_store.rar
real_case encrypted unverifiable tests/fixtures/rar5_hp.rar
real_case missing tool-error "$scratch/missing.rar"
[[ $rarz_t_status == 1 && -n $rarz_t_stderr ]] || fail 'missing-file adapter must retain exit 1 and diagnostic stderr'
cp tests/fixtures/rar5_store.rar "$scratch/damaged.rar" || exit 1
chmod u+w "$scratch/damaged.rar" || exit 1
printf '\104' | dd of="$scratch/damaged.rar" bs=1 seek=128 count=1 conv=notrunc status=none || exit 1
real_case payload damaged "$scratch/damaged.rar"
observe_unrar_test tests/fixtures/rar5_store.rar
[[ $unrar_t_class == valid ]] || fail "reference pristine: $unrar_t_class (exit $unrar_t_status)"
observe_unrar_test "$scratch/damaged.rar"
[[ $unrar_t_class == damaged ]] || fail "reference checksum mutation: $unrar_t_class (exit $unrar_t_status)"
cp tests/fixtures/rar5_vol_store.part*.rar "$scratch/" || exit 1
tail_volume="$scratch/rar5_vol_store.part6.rar"
size=$(wc -c < "$tail_volume")
head -c "$((size - 24))" "$tail_volume" > "$tail_volume.cut" || exit 1
mv "$tail_volume.cut" "$tail_volume" || exit 1
observe_unrar_test "$scratch/rar5_vol_store.part1.rar"
[[ $unrar_t_status == 1 && $unrar_t_class == damaged ]] || fail "reference service-block truncation: $unrar_t_class (exit $unrar_t_status)"

[[ $errors == 0 ]] || exit 1
printf 'PASS: validation outcome sets (%s rarz + %s reference records), 12 mutation pairs, and seven real controls\n' "$cases" "$reference_cases"
