#!/usr/bin/env bash
# Independent producer names must survive validation and extraction unchanged.
set -u
export LC_ALL=C.UTF-8
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
cd "$scratch" || exit 1
names=('plain.txt' 'café.txt' 'λ-😀.txt' $'e\xcc\x81.txt')
for name in "${names[@]}"; do printf 'UTF-8 filename control: %s\n' "$name" > "$name"; done
for method in 0 3; do
	capture rar a "-m$method" -idq "archive-$method.rar" "${names[@]}"
	[[ $rc == 0 ]] || { fail "producer m$method failed: $err"; continue; }
	capture unrar t -p- -idq "archive-$method.rar"
	[[ $rc == 0 ]] || fail "reference rejected Unicode m$method archive"
	for command in t verify; do
		capture "$RARZ" "$command" "archive-$method.rar"
		[[ $rc == 0 ]] || fail "m$method $command rejected valid UTF-8 names"
	done
	mkdir "extract-$method" || exit 1
	capture "$RARZ" x "archive-$method.rar" "extract-$method"
	[[ $rc == 0 ]] || { fail "m$method extraction failed: $err"; continue; }
	for name in "${names[@]}"; do
		[[ -f "extract-$method/$name" ]] || { fail "m$method changed an encoded name"; continue; }
		cmp "$name" "extract-$method/$name" >/dev/null || fail "m$method changed file contents"
	done
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: independent UTF-8 producer names and byte-preserving extraction\n'
