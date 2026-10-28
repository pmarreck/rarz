#!/usr/bin/env bash
# Exact suffix-deletion misses retained by the statistical campaign.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
fixture=tests/fixtures/rar2_v20_m3.rar
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
observe_rarz_test "$RARZ" "$fixture"
[[ $rarz_t_class == valid ]] || fail 'pristine RAR2 rejected'
observe_unrar_test "$fixture"
[[ $unrar_t_class == valid ]] || fail 'reference pristine control failed'

for boundary in 11991 12136 12396; do
	# Vintage archives may end exactly after a complete file without ENDARC.
	head -c "$boundary" "$fixture" > "$scratch/boundary.rar" || exit 1
	observe_rarz_test "$RARZ" "$scratch/boundary.rar"
	[[ $rarz_t_class == valid ]] || fail "complete boundary $boundary rejected"
	out='' err='' rc=0
	capture "$RARZ" verify "$scratch/boundary.rar"
	[[ $rc == 0 ]] || fail "FFI rejects complete vintage boundary $boundary"
	observe_unrar_test "$scratch/boundary.rar"
	[[ $unrar_t_class == valid ]] || fail "reference rejects boundary $boundary"
	for suffix in 1 2 3 4 5 6; do
		head -c "$((boundary+suffix))" "$fixture" > "$scratch/partial.rar" || exit 1
		observe_rarz_test "$RARZ" "$scratch/partial.rar"
		[[ $rarz_t_class == damaged ]] || fail "partial header at $boundary+$suffix returned $rarz_t_class"
		out='' err='' rc=0
		capture "$RARZ" verify "$scratch/partial.rar"
		[[ $rc != 0 ]] || fail "FFI verified the surviving prefix at $boundary+$suffix"
		observe_unrar_test "$scratch/partial.rar"
		[[ $unrar_t_class == damaged ]] || fail "reference outcome at $boundary+$suffix is $unrar_t_class"
	done
done
for family in rar4 rar5; do
	# Damage the final header of the last volume after earlier volumes parsed.
	directory="$scratch/$family"
	mkdir "$directory" || exit 1
	while IFS= read -r -d '' part; do cp "$part" "$directory/" || exit 1; done < <(command find tests/fixtures -maxdepth 1 -name "${family}_vol_m3.part*.rar" -print0)
	first="$directory/${family}_vol_m3.part01.rar"
	last="$directory/${family}_vol_m3.part02.rar"
	[[ $family == rar4 ]] && last="$directory/${family}_vol_m3.part04.rar"
	chmod u+w "$last" || exit 1
	out='' err='' rc=0
	capture "$RARZ" verify "$first"
	[[ $rc == 0 ]] || fail "$family pristine volume verification failed"
	observe_unrar_test "$first"
	[[ $unrar_t_class == valid ]] || fail "$family pristine volume reference failed"
	if [[ $family == rar4 ]]; then
		# The reference tolerates a shortened optional end-record body. Preserve
		# that existing FFI behavior; it is not a confirmed-damage control.
		truncate -s -1 "$last" || exit 1
		observe_unrar_test "$first"
		[[ $unrar_t_class == valid ]] || fail 'RAR4 optional end-record reference control changed'
		capture "$RARZ" verify "$first"
		[[ $rc == 0 ]] || fail 'RAR4 optional end-record was over-rejected'
		# Offset 20 begins the required continuation file header in part04.
		truncate -s 26 "$last" || exit 1
	else
		truncate -s -1 "$last" || exit 1
	fi
	observe_unrar_test "$first"
	if [[ $family == rar4 ]]; then
		# UNRAR requests a nonexistent fifth part (exit 6). Keep this
		# inconclusive; the missing base-header bytes establish our API refusal.
		[[ $unrar_t_class == tool-error && $unrar_t_status == 6 ]] || fail 'RAR4 missing-volume reference outcome changed'
	else
		[[ $unrar_t_class == damaged ]] || fail "$family truncated volume reference is $unrar_t_class"
	fi
	capture "$RARZ" verify "$first"
	[[ $rc != 0 ]] || fail "$family FFI verified truncated final volume"
done
[[ $errors == 0 ]] || exit 1
echo 'PASS: RAR2 incomplete headers rejected; complete vintage boundaries preserved'
