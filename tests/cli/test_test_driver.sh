#!/usr/bin/env bash
# The complete entrypoint must prepare Nix outputs and propagate runtime failure.
set -u
source tests/support/capture.bash || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/project/tests" "$scratch/bin" "$scratch/products" "$scratch/tmp" || exit 1
cp test "$scratch/project/test" || exit 1
printf '#!%s\n' "$(command -v bash)" > "$scratch/bin/nix"
cat >> "$scratch/bin/nix" <<'STUB'
printf '%s\n' "$*" >> "$DRIVER_RECORD"
case "$1" in
 build)
	if [[ $DRIVER_MODE == preparation-failure && $2 == .#test-artifacts ]]; then exit 17; fi
	if [[ $DRIVER_MODE == smoke-failure && $* == *package-smoke* ]]; then exit 19; fi
	if [[ $DRIVER_MODE == publication-failure && $* == *build-publication* ]]; then exit 20; fi
	while [[ $# -gt 0 ]]; do
		if [[ $1 == --out-link ]]; then ln -s "$DRIVER_PRODUCT" "$2" || exit 1; break; fi
		shift
	done ;;
 eval) printf 'x86_64-linux\n' ;;
 develop) [[ $DRIVER_MODE == runtime-failure ]] && exit 23; exit 0 ;;
 *) exit 74 ;;
esac
STUB
chmod +x "$scratch/bin/nix" || exit 1
export DRIVER_RECORD="$scratch/calls" DRIVER_PRODUCT="$scratch/products"
errors=0
for mode in runtime-failure smoke-failure publication-failure preparation-failure success; do
: > "$DRIVER_RECORD"
out='' err='' rc=0
# Omit optional host admission tools: these stubs never execute a workload.
capture env PATH="$scratch/bin:$(dirname "$(command -v bash)"):$(dirname "$(command -v mkdir)")" DRIVER_MODE="$mode" RARZ_TEST_TMPDIR="$scratch/tmp" bash "$scratch/project/test"
calls=$(cat "$DRIVER_RECORD")
[[ $calls == *'build .#test-artifacts --out-link'* ]] || { echo 'FAIL: exact test products were not prepared'; errors=$((errors+1)); }
[[ $calls != *'zig build'* ]] || { echo 'FAIL: test used a direct compiler backend'; errors=$((errors+1)); }
if [[ $mode == preparation-failure ]]; then
	[[ $rc != 0 && $calls != *develop* ]] || { echo 'FAIL: runtime ran without prepared products'; errors=$((errors+1)); }
else
	[[ $calls == *'checks.x86_64-linux.package-smoke'* ]] || { echo 'FAIL: installed product smoke missing'; errors=$((errors+1)); }
	[[ $calls == *'checks.x86_64-linux.build-publication'* ]] || { echo 'FAIL: cross-target publication gate missing'; errors=$((errors+1)); }
	[[ $calls == *'develop -c bash tests/support/run-suite '* ]] || { echo "FAIL: $mode prevented required runtime suites"; errors=$((errors+1)); }
	case "$mode:$rc" in
		runtime-failure:23|smoke-failure:1|publication-failure:1|success:0) ;;
		*) echo "FAIL: $mode returned $rc"; errors=$((errors+1)) ;;
	esac
fi
done
[[ $errors == 0 ]] || exit 1
echo 'PASS: Nix test preparation, runtime dispatch, and failure propagation'
