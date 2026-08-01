#!/usr/bin/env bash
# `rarz verify` — per-entry, verify-only decoding through the C FFI.
#
# HOW THIS DIFFERS FROM `rarz t`
#   `t` answers one question about the whole archive: intact or not. `verify`
#   decodes EVERY entry and reports each one's checksum result individually, so
#   a caller learns WHICH file is damaged, not merely that something is.
#
# WHY IT IS "VERIFY-ONLY"
#   It never materialises decoded output. Before this existed, a C consumer that
#   wanted to check entry N had to allocate `unpacked_size` bytes and call
#   `rarz_extract_to_buffer` — paying for bytes it intended to throw away. The
#   new FFI entry point drives the same decoder into a hashing sink instead, so
#   peak memory is the LZ window plus the hash state regardless of entry size.
#
#   On a SOLID archive this also means one pass: the decoder cache on the
#   archive handle is keyed by next-expected-index, so verifying 0,1,2,... reuses
#   the shared window rather than replaying predecessors per entry.
#
# THE GATES
#   A. Agreement — on a clean archive every entry verifies, and the summary
#      agrees with `rarz t` and with unrar.
#   B. Localisation — a corrupted entry is reported as failing, BY NAME, and the
#      command exits non-zero. This is the half that stops `verify` from being
#      satisfiable by printing OK unconditionally.
#   C. Coverage — verify must actually examine every entry unrar lists. A
#      `verify` that silently skipped entries would pass gate A trivially.
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
	exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A spread of formats and methods: RAR5 store/compressed, RAR4 v29, RAR2 v20,
# and one solid archive per family (the sequential path).
TARGETS="rar5_store rar5_m3 rar5_solid rar4_store rar4_m3 rar4_v29_solid rar2_v20_m3 rar2_v20_solid"

echo "=== Gate A: clean archives verify, and agree with t and unrar ==="

for name in $TARGETS; do
	f="$FIXTURES/$name.rar"
	[ -f "$f" ] || continue

	out=$("$RARZ" verify "$f" 2>&1)
	rc=$?

	unrar t "$f" >/dev/null 2>&1 && u=ok || u=damaged
	if "$RARZ" t "$f" 2>&1 | grep -q "Validation: VALID"; then t=valid; else t=invalid; fi

	if [ "$rc" -eq 0 ] && [ "$u" = ok ] && [ "$t" = valid ]; then
		ok "$name: verify exit 0, agrees with t and unrar"
	else
		fail "$name: verify rc=$rc, t=$t, unrar=$u — $(echo "$out" | tail -1)"
	fi
done

echo ""
echo "=== Gate C: verify examines every entry unrar lists ==="

for name in $TARGETS; do
	f="$FIXTURES/$name.rar"
	[ -f "$f" ] || continue

	# unrar's file count (files only, not directories).
	want=$(unrar lb "$f" 2>/dev/null | while IFS= read -r n; do
		unrar lt "$f" 2>/dev/null | grep -A1 -F "Name: $n" | grep -q "Type: Directory" || echo x
	done | wc -l | tr -d ' ')

	got=$("$RARZ" verify "$f" 2>/dev/null | grep -cE '^\s+(OK|FAIL)\b')

	if [ "$got" -eq "$want" ] && [ "$want" -gt 0 ]; then
		ok "$name: verified all $got entries"
	else
		fail "$name: verified $got entries, unrar lists $want files"
	fi
done

echo ""
echo "=== Gate B: a corrupted entry is reported BY NAME and exits non-zero ==="

for name in rar5_m3 rar4_m3 rar5_solid; do
	f="$FIXTURES/$name.rar"
	[ -f "$f" ] || continue

	sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
	detected=0
	total=0
	# Corrupt deep in the payload region, past the headers.
	for i in 1 2 3 4 5; do
		off=$(( sz / 3 + (i * 613) % (sz / 2) ))
		[ "$off" -lt "$sz" ] || continue
		c="$work/c.rar"
		cp "$f" "$c"
		printf '\xA5' | dd of="$c" bs=1 seek="$off" count=1 conv=notrunc 2>/dev/null

		unrar t "$c" >/dev/null 2>&1 && u=ok || u=damaged
		[ "$u" = ok ] && continue   # unrar says fine; nothing to require

		total=$((total + 1))
		out=$("$RARZ" verify "$c" 2>&1)
		rc=$?
		# Must exit non-zero AND name a failing entry, not just fail globally.
		if [ "$rc" -ne 0 ] && echo "$out" | grep -qE '^\s+FAIL\b'; then
			detected=$((detected + 1))
		fi
	done

	if [ "$total" -eq 0 ]; then
		continue
	fi
	if [ "$detected" -eq "$total" ]; then
		ok "$name: $detected/$total corruptions localised to a named entry"
	else
		fail "$name: only $detected/$total corruptions localised (rest not reported per-entry)"
	fi
done

echo ""
echo "=== Missing file and bad args behave ==="

if "$RARZ" verify /nonexistent/archive.rar >/dev/null 2>&1; then
	fail "verify on a missing file should exit non-zero"
else
	ok "verify on a missing file exits non-zero"
fi

if "$RARZ" verify >/dev/null 2>&1; then
	fail "verify with no argument should exit non-zero"
else
	ok "verify with no argument exits non-zero"
fi

echo ""
echo "Results: $pass passed, $errors failed"

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors assertion(s)"
	exit 1
fi

echo "PASS: test_verify.sh"
