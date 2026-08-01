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

RARZ="${RARZ:-zig-out/bin/rarz}"
FIXTURES="tests/fixtures"
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

echo "=== Precondition: intact volume sets validate, and agree with unrar ==="

for set_name in $SETS; do
	first=$(find "$FIXTURES" -maxdepth 1 -name "${set_name}.part1.rar" -o -maxdepth 1 -name "${set_name}.part01.rar" | head -1)
	[ -n "$first" ] || continue

	d="$work/intact_$set_name"
	mkdir -p "$d"
	find "$FIXTURES" -maxdepth 1 -name "${set_name}.part*.rar" -exec cp {} "$d/" \;
	entry="$d/$(basename "$first")"

	r=$("$RARZ" t "$entry" 2>&1 | grep -c "Validation: VALID")
	unrar t "$entry" >/dev/null 2>&1 && u=ok || u=damaged

	if [ "$u" = ok ] && [ "$r" -eq 1 ]; then
		ok "$set_name: intact set VALID, agrees with unrar"
	else
		fail "$set_name: intact set disagrees (rarz_valid=$r unrar=$u)"
	fi
done

echo ""
echo "=== Damage sweep: unrar damaged => rarz must NOT report VALID ==="

for set_name in $SETS; do
	first=$(find "$FIXTURES" -maxdepth 1 -name "${set_name}.part1.rar" -o -maxdepth 1 -name "${set_name}.part01.rar" | head -1)
	[ -n "$first" ] || continue
	base=$(basename "$first")

	total=0
	agreed=0
	false_pass=0
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
			unrar t "$d/$base" >/dev/null 2>&1 && u=ok || u=damaged
			if "$RARZ" t "$d/$base" 2>&1 | grep -q "Validation: VALID"; then r=valid; else r=invalid; fi

			if [ "$u" = damaged ] && [ "$r" = valid ]; then
				false_pass=$((false_pass + 1))
				echo "      MISSED: $volname truncated by $amount — unrar damaged, rarz VALID"
			elif [ "$u" = ok ] && [ "$r" = invalid ]; then
				stricter=$((stricter + 1))
			else
				agreed=$((agreed + 1))
			fi
		done
	done < <(find "$FIXTURES" -maxdepth 1 -name "${set_name}.part*.rar" | sort)

	if [ "$total" -eq 0 ]; then
		continue
	fi

	if [ "$false_pass" -eq 0 ]; then
		ok "$set_name: $total damaged sets, 0 reported VALID ($agreed agreed, $stricter rarz-stricter)"
	else
		fail "$set_name: $false_pass/$total damaged sets reported VALID"
	fi
done

echo ""
echo "Results: $pass passed, $errors failed"

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors assertion(s)"
	exit 1
fi

echo "PASS: test_precision_volumes.sh"
