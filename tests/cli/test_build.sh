#!/usr/bin/env bash
set -u
luajit tests/unit/build_test.lua || exit 1
source tests/support/capture.bash || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/project with spaces/scripts" "$scratch/bin" "$scratch/bad/bin" || exit 1
cp build "$scratch/project with spaces/" || exit 1
cp run "$scratch/project with spaces/" || exit 1
cp -R scripts/. "$scratch/project with spaces/scripts/" || exit 1
product=$(dirname "$(dirname "$(realpath "${RARZ:-zig-out/bin/rarz}")")")
cp "$product/bin/rarz" "$scratch/bad/bin/rarz" || exit 1
chmod u+w "$scratch/bad/bin/rarz" || exit 1
# An independent malformed-product control, never written into the store.
printf 'broken' > "$scratch/bad/bin/rarz"
printf '#!%s\n' "$(command -v bash)" > "$scratch/bin/nix"
cat >> "$scratch/bin/nix" <<'STUB'
printf '%s\n' "$*" >> "$BUILD_RECORD"
if [[ $1 == develop ]]; then shift; [[ ${1-} == -c ]] && shift; exec "$@"; fi
[[ $1 == build ]] || exit 74
[[ ${BUILD_FAIL:-0} == 0 ]] || exit 42
destination=result
while [[ $# -gt 0 ]]; do
	if [[ $1 == --out-link ]]; then destination=$2; shift; fi
	shift
done
ln -s "${BUILD_PRODUCT}" "$destination" || exit 1
STUB
chmod +x "$scratch/bin/nix" || exit 1
export BUILD_PRODUCT="$product" BUILD_RECORD="$scratch/record" PATH="$scratch/bin:$PATH"
project="$scratch/project with spaces"
host=$(luajit -e 'package.path="scripts/?.lua;"..package.path; local c=require("build-core"); local function read(s) local f=assert(io.popen(s)); local v=f:read("*l"); f:close(); return v end; print(assert(c.platform(read("uname -s"),read("uname -m"))))')
entry="$project/bin/$host/rarz"
variant=''; package_variant=''
if [[ $host == linux-* ]]; then variant=musl/; package_variant=-musl; fi
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
capture bash -c 'cd "$1" && bash build test' child "$project"
[[ $rc == 0 ]] || fail "host publication failed: $err"
[[ -L $entry && -x $entry ]] || fail 'native entrypoint is not a direct executable link'
[[ -d $project/zig-out/$host/${variant}ReleaseSafe ]] || fail 'complete profile product missing'
[[ $(cat "$BUILD_RECORD") == *".#$host$package_variant-ReleaseSafe"* ]] || fail 'wrong Nix package selected'
before=$(readlink "$entry")
capture bash -c 'cd "$1" && bash build test' child "$project"
[[ $rc == 0 && $(readlink "$entry") == "$before" ]] || fail 'identical build changed selection'
mkdir -p "$project/.build-work/publish-$host.lock" || exit 1
printf 'another publisher' > "$project/.build-work/publish-$host.lock/owner"
capture bash -c 'cd "$1" && bash build test' child "$project"
[[ $rc != 0 && $(readlink "$entry") == "$before" ]] || fail 'competing publisher changed selection'
[[ $(cat "$project/.build-work/publish-$host.lock/owner") == 'another publisher' ]] || fail 'competing lock was modified'
rm "$project/.build-work/publish-$host.lock/owner"
rmdir "$project/.build-work/publish-$host.lock"
for failure in builder malformed; do
	if [[ $failure == builder ]]; then export BUILD_FAIL=1; else export BUILD_FAIL=0 BUILD_PRODUCT="$scratch/bad"; fi
	capture bash -c 'cd "$1" && bash build test' child "$project"
	[[ $rc != 0 ]] || fail "$failure was accepted"
	[[ $(readlink "$entry") == "$before" ]] || fail "$failure changed the selected product"
done
export BUILD_FAIL=0 BUILD_PRODUCT="$product"
# run must use the freshly returned product, preserving CLI arguments/status.
mkdir -p "$scratch/run-product/bin"
printf '#!%s\nprintf "arg=<%%s>\\n" "$@"\nexit 23\n' "$(command -v bash)" > "$scratch/run-product/bin/rarz"
chmod +x "$scratch/run-product/bin/rarz"
mv "$project/build" "$project/build-real"
printf '#!%s\nprintf "%%s\\n" "$RUN_PRODUCT"\n' "$(command -v bash)" > "$project/build"
chmod +x "$project/build"
export RUN_PRODUCT="$scratch/run-product"
capture bash "$project/run" 'argument with spaces' '--flag'
[[ $rc == 23 && $out == $'arg=<argument with spaces>\narg=<--flag>' ]] || fail 'run lost the exact product, arguments, or exit status'
mv "$project/build-real" "$project/build"
if [[ -L $entry ]]; then
	mv "$entry" "$scratch/saved-link" || exit 1
	printf 'unmanaged' > "$entry"
	capture bash -c 'cd "$1" && bash build test' child "$project"
	[[ $rc != 0 && $(cat "$entry") == unmanaged ]] || fail 'unmanaged entrypoint was overwritten'
fi
mv "$entry" "$scratch/unmanaged-entry"
mv "$scratch/saved-link" "$entry"
mv "$project/.nix-out" "$project/saved-roots"
mkdir "$scratch/escape"
ln -s "$scratch/escape" "$project/.nix-out"
capture bash -c 'cd "$1" && bash build test' child "$project"
[[ $rc != 0 && ! -e $scratch/escape/$host ]] || fail 'publication followed a symlink outside its output tree'
[[ $errors == 0 ]] || exit 1
echo 'PASS: real-header publication, Nix selection, failure rollback, and unmanaged entries'
