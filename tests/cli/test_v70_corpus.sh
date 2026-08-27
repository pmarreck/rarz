#!/usr/bin/env bash
# RAR7 (v70) large-dictionary gate, driven by the LOCAL deterministic corpus
# (tests/generate_v70_corpus.sh; regenerable anywhere via drandomz seeds).
#
# SKIPS when the cache is absent — a machine without ~11 GiB of cache and
# ~13 GiB of RAM headroom reports the skip honestly rather than failing.
# The corpus is the only positively-identified v70 stream we have: rar 7.20
# emits v70 only for >4 GiB dictionaries, which need multi-GiB payloads.
set -u
RARZ="${RARZ:-zig-out/bin/rarz}"
CORPUS="tests/fixtures_large/v70_longrange.rar"
errors=0; pass=0
fail() { echo "  FAIL: $1"; errors=$((errors + 1)); }
ok() { echo "  OK: $1"; pass=$((pass + 1)); }

if [ ! -f "$CORPUS" ]; then
	echo "SKIP: test_v70_corpus.sh (no local corpus; run tests/generate_v70_corpus.sh to enable)"
	exit 0
fi
[ -x "$RARZ" ] || { echo "ERROR: rarz not found"; exit 1; }
command -v unrar >/dev/null 2>&1 || { echo "ERROR: unrar not found"; exit 1; }

echo "=== v70: intact corpus validates (8 GiB window, >4 GiB distances) ==="
out=$("$RARZ" t "$CORPUS" 2>&1)
echo "$out" | grep -q "Validation: VALID" && ok "corpus VALID" || fail "corpus not VALID: $(echo "$out" | tail -1)"

echo "=== v70: damage is refused (sniper, 2 deterministic positions) ==="
# In-place single-byte flips with restore afterwards: copying 4.7 GB per shot
# is slower than flipping twice. trap restores even on interrupt.
sz=$(stat -c%s "$CORPUS")
for frac in 41 83; do
	off=$((sz * frac / 100))
	orig=$(dd if="$CORPUS" bs=1 skip=$off count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
	flip=$(( (orig ^ 165) ))
	trap 'printf "\\$(printf %03o $orig)" | dd of="$CORPUS" bs=1 seek=$off count=1 conv=notrunc 2>/dev/null' EXIT
	printf "\\$(printf %03o $flip)" | dd of="$CORPUS" bs=1 seek=$off count=1 conv=notrunc 2>/dev/null
	if unrar t -mdx8g "$CORPUS" >/dev/null 2>&1; then
		echo "  (benign flip @$frac%)"
	else
		"$RARZ" t "$CORPUS" 2>&1 | grep -q "Validation: VALID" \
			&& fail "damaged corpus blessed @$frac%" || ok "damage refused @$frac%"
	fi
	printf "\\$(printf %03o $orig)" | dd of="$CORPUS" bs=1 seek=$off count=1 conv=notrunc 2>/dev/null
	trap - EXIT
done

echo ""
echo "Results: $pass passed, $errors failed"
[ "$errors" -gt 0 ] && { echo "FAILED: $errors assertion(s)"; exit 1; }
echo "PASS: test_v70_corpus.sh"
