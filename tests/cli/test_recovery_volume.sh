#!/usr/bin/env bash
# A recognized recovery signature identifies a container, not verified data.
set -u
export LC_ALL=C
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
fixture=$(realpath tests/fixtures/rar5_recovery.rev) || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
[[ $(sha256sum "$fixture" | cut -d ' ' -f1) == ee84c5495032d3791bbe900fe6eb5879a2fcf70ebc597dcf20842e356494c9a8 ]] || exit 1
capture unrar t -p- -idq "$fixture"
[[ $rc == 0 && -z $err ]] || fail 'independent producer recovery volume failed reference test'
cp "$fixture" "$scratch/renamed.bin" || exit 1
printf 'Rar!\x1aRev' > "$scratch/signature-only.bin"
printf 'Rar!\x1aRevgarbage payload' > "$scratch/opaque.bin"
printf 'MZstubRar!\x1aRevgarbage payload' > "$scratch/prefixed.bin"
for path in "$fixture" "$scratch/renamed.bin" "$scratch/signature-only.bin" "$scratch/opaque.bin"; do
	for command in t verify; do
		capture "$RARZ" "$command" "$path"
		[[ $rc == 69 ]] || fail "$command must report unavailable verification, got $rc"
		[[ $out != *'Validation: VALID'* && $out != *'Validation: INVALID'* && $out != *'Result: INVALID'* ]] || fail "$command made an integrity claim"
		[[ $out != *'Encrypted: yes'* && $err != *'encrypted'* ]] || fail "$command mislabeled recovery as encryption"
		[[ $out == *'Info: recovery data verification is not supported'* ]] || fail "$command omitted recovery classification"
	done
done
capture "$RARZ" t "$scratch/prefixed.bin"
[[ $rc == 69 && $out == *'recovery'* ]] || fail 'SFX scan missed recovery signature'
[[ $errors == 0 ]] || exit 1
printf 'PASS: recovery signature, independent producer, and unavailable verification\n'
