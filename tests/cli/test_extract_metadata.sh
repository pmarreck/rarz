#!/usr/bin/env bash
# Compare extracted metadata with producer inputs and an independent RAR4 reader.
set -u
umask 077
export TZ=UTC0 LC_ALL=C
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
legacy=$(realpath tests/fixtures/rar4_x86_filter.rar) || exit 1
append_file=$(realpath tests/support/append-rar5-file.lua) || exit 1
scratch=$(mktemp -d) || exit 1
trap 'chmod -R u+rwx "$scratch"; rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
cd "$scratch" || exit 1
mkdir -p source/nested source/empty || exit 1
printf '#!/bin/sh\nexit 0\n' > source/script.sh
printf 'Metadata payload\n' > source/nested/data
chmod 710 source
chmod 731 source/nested
chmod 750 source/empty
chmod 751 source/script.sh
chmod 640 source/nested/data
touch -d @0 source/nested/data || exit 1
touch -d @951782400 source/script.sh source/empty source/nested source || exit 1
for method in 0 3; do
	capture rar a "-m$method" -idq "archive-$method.rar" source
	[[ $rc == 0 ]] || { fail "producer failed: $err"; continue; }
	mkdir "candidate-$method" || exit 1
	capture "$RARZ" x "archive-$method.rar" "candidate-$method"
	[[ $rc == 0 ]] || { fail "m$method extraction failed: $err"; continue; }
	for path in source source/nested source/empty source/script.sh source/nested/data; do
		[[ $(stat -c %a "candidate-$method/$path") == $(stat -c %a "$path") ]] || fail "m$method mode differs for $path"
		[[ $(stat -c %Y "candidate-$method/$path") == $(stat -c %Y "$path") ]] || fail "m$method mtime differs for $path"
	done
	cmp source/script.sh "candidate-$method/source/script.sh" >/dev/null || fail "m$method script contents changed"
	cmp source/nested/data "candidate-$method/source/nested/data" >/dev/null || fail "m$method nested contents changed"
done
# Assemble unchanged producer records with a read-only parent before its child.
# Applying that mode during traversal would prevent creating the child.
mkdir readonly || exit 1
chmod 500 readonly
touch -d @951782400 readonly || exit 1
capture rar a -m0 -idq parent.rar readonly
[[ $rc == 0 ]] || fail 'read-only directory producer failed'
chmod 700 readonly
printf 'child after directory header\n' > readonly/child
capture rar a -m0 -idq child.rar readonly/child
[[ $rc == 0 ]] || fail 'child producer failed'
luajit "$append_file" parent.rar child.rar parent-first.rar || exit 1
capture unrar t -qo- -p- -idq parent-first.rar
[[ $rc == 0 ]] || fail 'reference rejected parent-before-child archive'
mkdir parent-first || exit 1
capture "$RARZ" x parent-first.rar parent-first
[[ $rc == 0 ]] || fail "parent-before-child extraction failed: $err"
[[ $(stat -c %a parent-first/readonly) == 500 ]] || fail 'read-only parent mode lost'
[[ $(stat -c %Y parent-first/readonly) == 951782400 ]] || fail 'parent time changed after child creation'
cmp readonly/child parent-first/readonly/child >/dev/null || fail 'child contents changed'
mkdir legacy-reference legacy-candidate || exit 1
capture unrar x -p- -idq "$legacy" legacy-reference/
[[ $rc == 0 ]] || fail 'reference RAR4 extraction failed'
capture "$RARZ" x "$legacy" legacy-candidate
[[ $rc == 0 ]] || fail 'candidate RAR4 extraction failed'
[[ $(stat -c %a legacy-reference/prog) == 755 ]] || fail 'RAR4 control lacks executable mode'
[[ $(stat -c %a legacy-candidate/prog) == 755 ]] || fail 'RAR4 executable mode lost'
cmp legacy-reference/prog legacy-candidate/prog >/dev/null || fail 'RAR4 executable bytes differ'
[[ $errors == 0 ]] || exit 1
printf 'PASS: RAR5 extraction modes/timestamps and RAR4 executable mode\n'
