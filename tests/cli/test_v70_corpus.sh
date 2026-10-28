#!/usr/bin/env bash
# RAR7 (v70) large-dictionary gate, driven by the LOCAL deterministic corpus
# (tests/generate_v70_corpus.sh; regenerable anywhere via drandomz seeds).
#
# Missing corpus or inconclusive validation makes the required gate incomplete.
# The corpus is the only positively-identified v70 stream we have: rar 7.20
# emits v70 only for >4 GiB dictionaries, which need multi-GiB payloads.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ="${RARZ:-zig-out/bin/rarz}"
CORPUS="tests/fixtures_large/v70_longrange.rar"
errors=0; pass=0
fail() { echo "  FAIL: $1"; errors=$((errors + 1)); }
ok() { echo "  OK: $1"; pass=$((pass + 1)); }

if [ ! -f "$CORPUS" ]; then
	echo "INCOMPLETE: required v70 corpus is unavailable"
	exit 1
fi
[ -x "$RARZ" ] || { echo "ERROR: rarz not found"; exit 1; }
command -v unrar >/dev/null 2>&1 || { echo "ERROR: unrar not found"; exit 1; }

echo "=== v70: intact corpus validates (8 GiB window, >4 GiB distances) ==="
out='' err='' rc=0
capture timeout 600 "$RARZ" t "$CORPUS"
[[ $(classify_rarz_test "$rc" "$out") == valid ]] || { fail "pristine corpus not VALID (exit $rc)"; exit 1; }
capture timeout 600 unrar t -p- -qo- -mdx8g "$CORPUS"
[[ $(classify_unrar_test "$rc" "$out"$'\n'"$err") == valid ]] || { fail "reference pristine check incomplete (exit $rc)"; exit 1; }
ok "corpus VALID in both validators"

echo "=== v70: damage is refused (xor-byte-v1, 2 deterministic positions) ==="
# Mutations belong to private copies. A trap cannot make source mutations safe
# against SIGKILL or concurrent readers. Large scratch must be disk-backed so
# its bytes do not consume the decoder's memory budget a second time.
sz=$(stat -c%s "$CORPUS")
scratch=$(mktemp -d "${RARZ_CORPUS_TMPDIR:-${TMPDIR:-/tmp}}/rarz-v70.XXXXXXXX") || exit 1
trap 'rm -rf "$scratch"' EXIT
if [[ $sz -gt 1073741824 && $(stat -f -c %T "$scratch") == tmpfs ]]; then
	echo 'INCOMPLETE: set RARZ_CORPUS_TMPDIR to disk-backed scratch for the large corpus'
	exit 1
fi
detected=0
for frac in 41 83; do
	mutant="$scratch/mutant.rar"
	off=$((sz * frac / 100))
	legacy_mutate "$CORPUS" "$mutant" xor-byte-v1 "$off" 165 || exit 1
	capture timeout 600 unrar t -p- -qo- -mdx8g "$mutant"
	reference=$(classify_unrar_test "$rc" "$out"$'\n'"$err")
	reference_execution=$(classify_execution_status unrar "$rc")
	capture timeout 600 "$RARZ" t "$mutant"
	actual=$(classify_rarz_test "$rc" "$out")
	actual_execution=$(classify_execution_status rarz "$rc")
	if [[ $reference == damaged && $actual == damaged ]]; then
		detected=$((detected+1)); ok "damage detected @$frac%"
	else
		fail "mutation @$frac%: reference=$reference/$reference_execution rarz=$actual/$actual_execution"
	fi
done
[[ $detected == 2 ]] || fail "both designated mutations must be confirmed damage and detected"

echo ""
echo "Results: $pass passed, $errors failed"
[ "$errors" -gt 0 ] && { echo "FAILED: $errors assertion(s)"; exit 1; }
echo "PASS: test_v70_corpus.sh"
