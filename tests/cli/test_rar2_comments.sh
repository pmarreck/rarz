#!/usr/bin/env bash
# Original RAR 2.90 comments have separate outer, nested, and payload CRCs.
set -u
source tests/support/validation-outcome.bash || exit 1
RARZ=${RARZ:-zig-out/bin/rarz}
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
errors=0
out='' err='' rc=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
for name in rar2_v20_comment_control rar2_v20_comment; do
 fixture="tests/fixtures/$name.rar"
 capture unrar t -p- -idq -qo- "$fixture"
 [[ $rc == 0 && -z $err ]] || fail "reference rejected $name"
 observe_rarz_test "$RARZ" "$fixture"
 [[ $rarz_t_class == valid ]] || fail "rarz rejected $name"
done
for offset in 7 10 20 27 31 45; do
 cp tests/fixtures/rar2_v20_comment.rar "$scratch/mutant.rar" || exit 1
 chmod u+w "$scratch/mutant.rar" || exit 1
 luajit - "$scratch/mutant.rar" "$offset" <<'LUA' || exit 1
local f=assert(io.open(arg[1],"r+b"))
assert(f:seek("set",tonumber(arg[2])))
local byte=assert(f:read(1)):byte()
assert(f:seek("cur",-1))
assert(f:write(string.char(require("bit").bxor(byte,1))))
assert(f:close())
LUA
 capture unrar t -p- -idq -qo- "$scratch/mutant.rar"
 expected=3
 [[ $offset != 45 ]] || expected=0
 [[ $rc == "$expected" && $err == *'The archive comment is corrupt'* ]] || fail "reference comment diagnostic changed at offset $offset"
 [[ $(classify_unrar_test "$rc" "$err") == damaged ]] || fail "reference damage was misclassified at offset $offset"
 observe_rarz_test "$RARZ" "$scratch/mutant.rar"
 [[ $rarz_t_class == damaged ]] || fail "corrupted comment at $offset returned $rarz_t_class"
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: independent RAR2 archive comment and six checksum controls\n'
