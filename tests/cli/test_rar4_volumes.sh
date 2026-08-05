#!/usr/bin/env bash
# RAR4 multi-volume validation.
#
# WHY THIS EXISTS
#   validate_volumes() handled RAR5 only and returned INVALID for every other
#   family. A RAR4 volume set that unrar tests clean was therefore reported as
#   DAMAGED — not "unsupported", but positive evidence of corruption that did
#   not exist. Reporting damage for a missing capability is the worst framing
#   available: a tooling gap is not the user's data being bad.
#
#   RAR4 .rar/.r00/.r01 sets are among the most common archives in the wild, and
#   the committed corpus contained none, which is exactly why this survived.
#
# THE GATES
#   A. Agreement — rarz agrees with unrar on an intact set.
#   B. Damage is still caught — corrupting a payload byte must flip the verdict.
#      Without this, a validate_volumes that returns VALID unconditionally
#      would pass gate A.
set -u

RARZ="${RARZ:-zig-out/bin/rarz}"
FIXTURES="tests/fixtures"
errors=0
pass=0

fail() { echo "  FAIL: $1"; errors=$((errors + 1)); }
ok() { echo "  OK: $1"; pass=$((pass + 1)); }

[ -x "$RARZ" ] || { echo "ERROR: rarz not found at $RARZ"; exit 1; }
command -v unrar >/dev/null 2>&1 || { echo "ERROR: unrar not found — run under 'nix develop -c'."; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Volume numbering is zero-padded to the SET size (part1 vs part01), so the
# first part is discovered rather than assumed.
first_part() { ls "$FIXTURES/$1".part*.rar 2>/dev/null | sort | head -1; }

echo "=== Gate A: intact RAR4 volume sets agree with unrar ==="
for name in rar4_vol_store rar4_vol_m3; do
	f=$(first_part "$name")
	[ -n "$f" ] || { fail "$name: no fixture"; continue; }

	unrar t "$f" >/dev/null 2>&1 && u=OK || u=damaged
	out=$("$RARZ" t "$f" 2>&1)
	if echo "$out" | grep -q "Validation: VALID"; then t=valid; else t=invalid; fi

	if [ "$u" = OK ] && [ "$t" = valid ]; then
		ok "$name: VALID, agrees with unrar"
	else
		fail "$name: unrar=$u rarz=$t — $(echo "$out" | grep -oE 'Error: .*' | head -1)"
	fi

	# verify must reach the same conclusion as t.
	"$RARZ" verify "$f" >/dev/null 2>&1
	rc=$?
	[ "$rc" -eq 0 ] && ok "$name: verify exits 0" || fail "$name: verify exit $rc, expected 0"
done

echo ""
echo "=== Gate B: damage in any volume is still caught ==="
# Corrupt one payload byte per volume, in turn. A whole-set verdict that cannot
# see past the first volume would pass for the early parts and fail here.
for name in rar4_vol_store rar4_vol_m3; do
	src=$(first_part "$name")
	[ -n "$src" ] || continue
	caught=0
	total=0
	for vol in $(ls "$FIXTURES/$name".part*.rar | sort); do
		rm -rf "$work/set"; mkdir -p "$work/set"
		cp "$FIXTURES/$name".part*.rar "$work/set/"
		target="$work/set/$(basename "$vol")"
		sz=$(stat -c%s "$target" 2>/dev/null || stat -f%z "$target")
		# Two-thirds in: past the headers, inside the payload.
		printf '\xA5' | dd of="$target" bs=1 seek=$((sz * 2 / 3)) count=1 conv=notrunc 2>/dev/null
		total=$((total + 1))

		mfirst=$(ls "$work/set/$name".part*.rar | sort | head -1)
		# Only count volumes where the mutation actually damaged the archive —
		# unrar is the arbiter of that, not us.
		if unrar t "$mfirst" >/dev/null 2>&1; then
			total=$((total - 1))
			continue
		fi
		if "$RARZ" t "$mfirst" 2>&1 | grep -q "Validation: VALID"; then
			fail "$name: damage in $(basename "$vol") reported VALID"
		else
			caught=$((caught + 1))
		fi
	done
	[ "$total" -gt 0 ] && ok "$name: $caught/$total damaged volumes refused" \
		|| fail "$name: no mutation damaged the set — gate B proved nothing"
done

echo ""
echo "Results: $pass passed, $errors failed"
[ "$errors" -gt 0 ] && { echo "FAILED: $errors assertion(s)"; exit 1; }
echo "PASS: test_rar4_volumes.sh"
