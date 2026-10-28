#!/usr/bin/env bash
# Unknown-block framing does not exempt its plaintext header from CRC checks.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
for family in rar4 rar5; do
	fixture="tests/fixtures/${family}_store.rar"
	end_size=7
	[[ $family == rar5 ]] && end_size=8
	for flag in clear skip data skip-data; do
		case "$family-$flag" in
			rar5-clear) header='\x45\x68\x62\x54\x02\x7f\x00';;
			rar5-skip) header='\x5c\xac\x0f\x53\x02\x7f\x04';;
			rar4-clear) header='\xc4\x16\x7f\x00\x00\x07\x00';;
			rar4-skip) header='\x04\x9b\x7f\x00\x40\x07\x00';;
			rar5-data) header='\x28\x98\x09\xb7\x03\x7f\x02\x06opaque';;
			rar5-skip-data) header='\x2c\x5d\x65\xd3\x03\x7f\x06\x06opaque';;
			rar4-data) header='\x47\x5d\x7f\x00\x80\x0b\x00\x06\x00\x00\x00opaque';;
			rar4-skip-data) header='\x3e\x28\x7f\x00\xc0\x0b\x00\x06\x00\x00\x00opaque';;
		esac
		# Type-127 headers have independently calculated CRCs; data cases
		# include a six-byte opaque payload that the reader must skip.
		# Insert immediately before the producer's ENDARC record.
		archive="$scratch/$family-$flag.rar"
		head -c "-$end_size" "$fixture" > "$archive" || exit 1
		printf '%b' "$header" >> "$archive" || exit 1
		tail -c "$end_size" "$fixture" >> "$archive" || exit 1
		observe_unrar_test "$archive"
		[[ $unrar_t_class == valid ]] || fail "$family/$flag reference=$unrar_t_class status=$unrar_t_status"
		observe_rarz_test "$RARZ" "$archive"
		[[ $rarz_t_class == valid ]] || fail "$family/$flag rarz=$rarz_t_class"
		offset=$(( $(stat -c%s "$fixture") - end_size ))
		printf '\0' | dd of="$archive" bs=1 seek="$offset" conv=notrunc 2>/dev/null || exit 1
		observe_rarz_test "$RARZ" "$archive"
		[[ $rarz_t_class == damaged ]] || fail "$family/$flag corrupt unknown header returned $rarz_t_class"
	done
done
[[ $errors == 0 ]] || exit 1
echo 'PASS: unknown blocks with either update flag remain readable'
