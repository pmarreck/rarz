#!/usr/bin/env bash
# Reference-confirmed assembled volumes with encryption before/after readable data.
set -u
source tests/support/capture.bash || exit 1
source tests/support/validation-outcome.bash || exit 1
RARZ=$(realpath "${RARZ:-zig-out/bin/rarz}") || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
for order in plain-first encrypted-first; do
	prefix="rar5_mixed_$order"
	luajit tests/support/make-mixed-volumes.lua tests/fixtures/rar5_encrypted_mixed.rar "$scratch/$prefix" "$order" || exit 1
	for part in 1 2; do
		cmp "tests/fixtures/$prefix.part$part.rar" "$scratch/$prefix.part$part.rar" >/dev/null || fail "$order fixture reproduction differs"
	done
	first="$scratch/$prefix.part1.rar"
	capture unrar t -pSECRET -qo- -idq "$first"
	[[ $rc == 0 ]] || { fail "$order reference rejected pristine volumes"; continue; }
	capture "$RARZ" t "$first"
	[[ $rc == 0 && $out == *'Encrypted: yes'* ]] || fail "$order intact mixed-volume classification failed"
	capture "$RARZ" verify "$first"
	[[ $rc == 69 && $out != *'FAIL'* ]] || fail "$order per-file verification must report encrypted content as incomplete, not damage (exit $rc)"
	part=1; [[ $order == plain-first ]] || part=2
	# Change only the first plaintext payload byte; preserve all header checksums.
	luajit - "$scratch/$prefix.part$part.rar" <<'LUA'
local bit=require('bit')
local path=arg[1]; local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close()
local function vint(p)
 local value,factor=0,1
 for _=1,8 do local b=assert(s:byte(p));p=p+1;value=value+bit.band(b,127)*factor;if b<128 then return value,p end;factor=factor*128 end
 error('invalid fixture VINT')
end
local n,p=vint(13);local file=p+n
n,p=vint(file+4);local payload=p+n
assert(s:byte(p)==2,'expected FILE record')
local out=assert(io.open(path,'wb'));out:write(s:sub(1,payload-1),string.char(bit.bxor(s:byte(payload),0xa5)),s:sub(payload+1));out:close()
LUA
	[[ $? == 0 ]] || exit 1
	capture unrar t -pSECRET -qo- "$first"
	[[ $(classify_unrar_test "$rc" "$out"$'\n'"$err") == damaged ]] || { fail "$order reference did not confirm payload damage"; continue; }
	capture "$RARZ" t "$first"
	[[ $rc == 1 && $out == *'Validation: INVALID'* && $out == *'Encrypted: yes'* ]] || fail "$order encryption hid readable payload damage (exit $rc)"
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: mixed encryption does not bypass other volume payload checks\n'
