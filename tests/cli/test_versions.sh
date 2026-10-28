#!/usr/bin/env bash
# Independent producer histories must retain each revision's name and bytes.
set -u
source tests/support/capture.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
append_file=$(realpath tests/support/append-rar5-file.lua) || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
cd "$scratch" || exit 1
for method in 0 3; do
	mkdir "case-$method" || exit 1
	cd "case-$method" || exit 1
	printf 'First revision\n' > version.txt
	capture rar a "-m$method" -idq archive.rar version.txt
	[[ $rc == 0 ]] || exit 1
	printf 'Second revision with different bytes\n' > version.txt
	capture rar a "-m$method" -ver -idq archive.rar version.txt
	[[ $rc == 0 ]] || exit 1
	printf 'Third revision, longer again, is the current file\n' > version.txt
	capture rar a "-m$method" -ver -idq archive.rar version.txt
	[[ $rc == 0 ]] || exit 1
	mkdir reference candidate || exit 1
	capture unrar x -ver -p- -idq archive.rar reference/
	[[ $rc == 0 ]] || { fail "reference history extraction: $err"; cd ..; continue; }
	for name in version.txt 'version.txt;1' 'version.txt;2'; do
		[[ -f reference/$name ]] || fail "producer history lacks $name"
	done
	for command in t verify; do
		capture "$RARZ" "$command" archive.rar
		[[ $rc == 0 ]] || fail "m$method $command rejected valid history"
	done
	capture "$RARZ" x archive.rar candidate
	[[ $rc == 0 ]] || fail "m$method history extraction: $err"
	capture diff -r reference candidate
	[[ $rc == 0 ]] || fail "m$method lost a revision's name or bytes: $out $err"
	# A literal suffix can collide with the name of a historical revision.
	printf 'Literal semicolon filename\n' > 'version.txt;1'
	capture rar a "-m$method" -idq literal.rar 'version.txt;1'
	[[ $rc == 0 ]] || { fail "producer literal-suffix control: $err"; cd ..; continue; }
	luajit "$append_file" archive.rar literal.rar collision.rar || exit 1
	capture unrar t -qo- -p- -idq collision.rar
	[[ $rc == 0 ]] || fail "reference rejected literal-suffix control"
	capture unrar lb -qo- -ver -p- collision.rar
	[[ $rc == 0 && $(printf '%s\n' "$out" | awk '$0 == "version.txt;1" { n++ } END { print n+0 }') == 2 ]] || fail "reference did not see two colliding names"
	for command in t verify; do
		capture "$RARZ" "$command" collision.rar
		[[ $rc == 0 ]] || fail "m$method $command confused a name collision with damaged data"
	done
	mkdir collision || exit 1
	capture "$RARZ" x collision.rar collision
	[[ $rc == 1 && $err == *'duplicate extraction path'* ]] || fail "m$method did not refuse a colliding output path"
	[[ -z $(ls -A collision) ]] || fail "m$method wrote files before checking name collisions"
	cd .. || exit 1
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: independent RAR5 version histories retain names and bytes\n'
