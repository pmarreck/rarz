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
	observe_unrar_test "$scratch/boundary.rar"
	[[ $unrar_t_class == valid ]] || fail "reference rejects boundary $boundary"
	for suffix in 1 2 3 4 5 6; do
		head -c "$((boundary+suffix))" "$fixture" > "$scratch/partial.rar" || exit 1
		observe_rarz_test "$RARZ" "$scratch/partial.rar"
		[[ $rarz_t_class == damaged ]] || fail "partial header at $boundary+$suffix returned $rarz_t_class"
		observe_unrar_test "$scratch/partial.rar"
		[[ $unrar_t_class == damaged ]] || fail "reference outcome at $boundary+$suffix is $unrar_t_class"
	done
done
[[ $errors == 0 ]] || exit 1
echo 'PASS: RAR2 incomplete headers rejected; complete vintage boundaries preserved'
