#!/usr/bin/env bash
# Multi-volume precision: damage anywhere in a volume set must not read as VALID.
#
# WHY THIS SUITE EXISTS
#   The single-volume path had been hardened against truncation twice (PLAN 4
#   precision passes 1-3a), but the MULTI-VOLUME path collected file chunks
#   through a guard that silently DROPPED any chunk whose declared payload ran
#   past the end of its volume:
#
#       if (payload_end <= vol_data.len) { chunks.append(...); }
#
#   A dropped chunk is a file that left the verification set. Step 3 then
#   verified whatever it happened to collect and reported VALID — absence of
#   evidence becoming evidence of correctness, on exactly the input a
#   file-integrity product exists to catch.
#
# WHAT THIS ASSERTS, AND IN WHICH DIRECTION
#   The property is one-directional: **unrar says damaged => rarz must not say
#   VALID.** rarz is allowed to be STRICTER than unrar (it already is on at
#   least one case: lopping 40 bytes off a middle volume removes that volume's
#   end block, which unrar tolerates and rarz reports as truncation — the bytes
#   really are gone, so refusing is the defensible call). What is never
#   allowed is the other direction.
set -u
source tests/support/validation-outcome.bash || exit 1

RARZ="${RARZ:-zig-out/bin/rarz}"
FIXTURES="${FIXTURES:-tests/fixtures}"
errors=0
pass=0

fail() { echo "  FAIL: $1"; errors=$((errors + 1)); }
ok() { echo "  OK: $1"; pass=$((pass + 1)); }

if [ ! -x "$RARZ" ]; then
	echo "ERROR: rarz binary not found at $RARZ"
	exit 1
fi
if ! command -v unrar >/dev/null 2>&1; then
	echo "ERROR: unrar not found — run under 'nix develop -c'."
	echo "Without the oracle every assertion here is vacuous."
	exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Volume sets in the corpus, named by their first part.
SETS="rar5_vol_store rar5_vol_m3 rar5_vol_large"
required_volumes=()
for set_name in $SETS; do
	if [[ $set_name == rar5_vol_m3 ]]; then parts=(01 02); else parts=(1 2 3 4 5 6); fi
	for part in "${parts[@]}"; do required_volumes+=("$FIXTURES/$set_name.part$part.rar"); done
done
require_fixture_paths "${required_volumes[@]}" || exit 1

echo "=== Precondition: intact volume sets validate, and agree with unrar ==="

for set_name in $SETS; do
	first=$(find "$FIXTURES" -maxdepth 1 -name "${set_name}.part1.rar" -o -maxdepth 1 -name "${set_name}.part01.rar" | head -1)
	[ -n "$first" ] || { fail "$set_name: INCOMPLETE first volume"; continue; }

	d="$work/intact_$set_name"
	mkdir -p "$d"
	find "$FIXTURES" -maxdepth 1 -name "${set_name}.part*.rar" -exec cp {} "$d/" \;
	entry="$d/$(basename "$first")"

	observe_rarz_test "$RARZ" "$entry"
	observe_unrar_test "$entry"

	if [[ $unrar_t_class == valid && $rarz_t_class == valid ]]; then
		ok "$set_name: intact set VALID, agrees with unrar"
	else
		fail "$set_name: intact set unrar=$unrar_t_class/$unrar_t_status rarz=$rarz_t_class/$rarz_t_status"
	fi
done

echo ""
echo "=== Damage sweep: require explicit verdicts, reject inconclusive runs ==="

for set_name in $SETS; do
	first=$(find "$FIXTURES" -maxdepth 1 -name "${set_name}.part1.rar" -o -maxdepth 1 -name "${set_name}.part01.rar" | head -1)
	[ -n "$first" ] || { fail "$set_name: INCOMPLETE first volume"; continue; }
	base=$(basename "$first")
	if [[ $set_name == rar5_vol_m3 ]]; then expected_trials=6; else expected_trials=18; fi
	controls_passed=0

	total=0
	detected=0
	benign=0
	failed=0
	stricter=0

	# Copy the set ONCE and restore only the damaged volume between iterations.
	# Re-copying every time made this suite 124s on its own — the sets run to
	# several MB and there are 42 combinations.
	d="$work/dmg_$set_name"
	mkdir -p "$d"
	find "$FIXTURES" -maxdepth 1 -name "${set_name}.part*.rar" -exec cp {} "$d/" \;

	# Sweep every volume in the set, truncating and mutating each. Exactly ONE
	# volume is damaged per iteration — restoring the previously damaged one is
	# what keeps that true, since otherwise moving to the next volume would leave
	# the last one broken and start testing compound damage instead.
	last_damaged=""
	while IFS= read -r vol; do
		volname=$(basename "$vol")
		for amount in 24 128 700; do
			[ -n "$last_damaged" ] && cp "$FIXTURES/$last_damaged" "$d/$last_damaged"
			cp "$FIXTURES/$volname" "$d/$volname"
			last_damaged="$volname"
			target="$d/$volname"
			sz=$(stat -c%s "$target" 2>/dev/null || stat -f%z "$target")
			[ "$sz" -gt "$amount" ] || continue

			# Truncation
			head -c $((sz - amount)) "$target" > "$target.t" && mv "$target.t" "$target"

			total=$((total + 1))
			observe_unrar_test "$d/$base"
			observe_rarz_test "$RARZ" "$d/$base"
			pair=$(classify_mutation_pair "$unrar_t_class" "$rarz_t_class")
			# Removing 700 bytes from the first volume is the known payload
			# truncation control. Shorter/end-block trials may be stricter.
			if [[ $volname == "$base" && $amount == 700 && $pair == detected ]]; then
				controls_passed=$((controls_passed + 1))
			fi
			case "$pair" in
				detected) detected=$((detected + 1)) ;;
				benign) benign=$((benign + 1)) ;;
				stricter) stricter=$((stricter + 1)) ;;
				*)
					failed=$((failed + 1))
					fail "$volname truncated by $amount: unrar=$unrar_t_class/$unrar_t_status rarz=$rarz_t_class/$rarz_t_status"
					;;
			esac
		done
	done < <(find "$FIXTURES" -maxdepth 1 -name "${set_name}.part*.rar" | sort)

	if [[ $(classify_required_trials "$expected_trials" "$total" 1 "$controls_passed") != complete ]]; then
		fail "$set_name: INCOMPLETE ($total/$expected_trials trials, $controls_passed/1 known damage controls)"
	elif [ "$failed" -eq 0 ]; then
		ok "$set_name: $total truncations, $detected detected, $benign benign, $stricter stricter"
	fi
done

echo ""
echo "Results: $pass passed, $errors failed"

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors assertion(s)"
	exit 1
fi

echo "PASS: test_precision_volumes.sh"
