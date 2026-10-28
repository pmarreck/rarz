#!/usr/bin/env bash
# Qualify the real runner using disposable protected files, never live data.
set -u
source tests/support/capture.bash || exit 1
root=$(mktemp -d) || exit 1
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/source/tests/cli" "$root/source/tests/support" "$root/source/tests/unit" "$root/source/tests/fixtures" "$root/product/bin" "$root/work" || exit 1
printf 'before' > "$root/protected"
printf 'unconfined' > "$root/protected" || exit 1
printf 'before' > "$root/protected"
printf '#!%s\nexit 0\n' "$(command -v bash)" > "$root/product/bin/rarz-tests"
cp "$root/product/bin/rarz-tests" "$root/product/bin/rarz" || exit 1
chmod +x "$root/product/bin/rarz-tests" "$root/product/bin/rarz" || exit 1
touch "$root/source/assess-coverage" "$root/source/test"
cat > "$root/source/tests/cli/test_boundary.sh" <<'PROBE'
set -u
[[ -z $(declare -F find) ]] || exit 1
[[ $HOME == "$BOUNDARY_WORK/home" && $XDG_STATE_HOME == "$BOUNDARY_WORK/state" ]] || exit 1
printf 'private' > "$HOME/private" || exit 1
ln -s "$BOUNDARY_PROTECTED" "$HOME/escape" || exit 1
for target in "$BOUNDARY_PROTECTED" "$HOME/escape"; do
	if (printf 'damaged' > "$target") 2>/dev/null; then exit 1; fi
done
if chmod 777 "$BOUNDARY_PROTECTED" 2>/dev/null; then exit 1; fi
if mv "$BOUNDARY_PROTECTED" "$HOME/moved" 2>/dev/null; then exit 1; fi
if touch "${BOUNDARY_PROTECTED}.new" 2>/dev/null; then exit 1; fi
[[ $(cat "$BOUNDARY_PROTECTED") == before ]] || exit 1
PROBE
export BOUNDARY_PROTECTED="$root/protected" BOUNDARY_WORK="$root/work"
find() { return 73; }
export -f find
out='' err='' rc=0
capture bash tests/support/run-suite "$root/product" "$root/source" "$root/work"
[[ $rc == 0 ]] || { printf 'FAIL: runner confinement control: %s %s\n' "$out" "$err"; exit 1; }
[[ $(cat "$root/protected") == before && $(cat "$root/work/home/private") == private ]] || exit 1
echo 'PASS: isolated runner rejects protected writes and permits private state'
