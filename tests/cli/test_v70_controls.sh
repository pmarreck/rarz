#!/usr/bin/env bash
# Exercise the real large-corpus driver with tiny private inputs and recorded
# validator outcomes. No large archive or decoder is invoked here.
set -u
source tests/support/capture.bash || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/project/tests/cli" "$scratch/project/tests/support" "$scratch/project/tests/fixtures_large" "$scratch/bin" || exit 1
cp tests/cli/test_v70_corpus.sh "$scratch/project/tests/cli/" || exit 1
cp tests/support/capture.bash tests/support/validation-outcome.bash tests/support/legacy-mutation.bash "$scratch/project/tests/support/" || exit 1
printf 'abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789' > "$scratch/original"
export V70_ORIGINAL="$scratch/original" V70_SOURCE="$scratch/project/tests/fixtures_large/v70_longrange.rar" V70_TOUCHED="$scratch/touched"
printf '#!%s\n' "$(command -v bash)" > "$scratch/bin/rarz"
cat >> "$scratch/bin/rarz" <<'FIXTURE'
if ! cmp -s "$V70_ORIGINAL" "$V70_SOURCE"; then printf 'source mutated\n' > "$V70_TOUCHED"; fi
if cmp -s "$V70_ORIGINAL" "$2"; then printf 'Validation: VALID\n'; exit 0; fi
case "$V70_MODE" in
 crash) printf 'Validation: INVALID\n'; exit 137 ;;
 unavailable) printf 'Validation: UNVERIFIABLE\n'; exit 69 ;;
 missed) printf 'Validation: VALID\n'; exit 0 ;;
 *) printf 'Validation: INVALID\n'; exit 1 ;;
esac
FIXTURE
printf '#!%s\n' "$(command -v bash)" > "$scratch/bin/unrar"
cat >> "$scratch/bin/unrar" <<'FIXTURE'
if ! cmp -s "$V70_ORIGINAL" "$V70_SOURCE"; then printf 'source mutated\n' > "$V70_TOUCHED"; fi
if cmp -s "$V70_ORIGINAL" "${@: -1}"; then exit 0; fi
case "$V70_MODE" in
 reference-error) exit 2 ;;
 benign) exit 0 ;;
 *) exit 3 ;;
esac
FIXTURE
chmod +x "$scratch/bin/rarz" "$scratch/bin/unrar" || exit 1
export PATH="$scratch/bin:$PATH" RARZ="$scratch/bin/rarz"
errors=0
for mode in detected crash unavailable missed reference-error benign missing; do
	cp "$scratch/original" "$V70_SOURCE" || exit 1
	if [[ $mode == missing ]]; then mv "$V70_SOURCE" "$scratch/absent" || exit 1; fi
	out='' err='' rc=0
	capture bash -c 'cd "$1" && V70_MODE="$2" bash tests/cli/test_v70_corpus.sh' child "$scratch/project" "$mode"
	if [[ $mode == detected ]]; then
		[[ $rc == 0 ]] || { printf 'FAIL: confirmed detection rejected\n'; errors=$((errors+1)); }
	else
		[[ $rc != 0 ]] || { printf 'FAIL: %s was accepted as a complete gate\n' "$mode"; errors=$((errors+1)); }
	fi
	[[ ! -e $V70_TOUCHED ]] || { printf 'FAIL: source corpus was mutated during %s\n' "$mode"; errors=$((errors+1)); }
done
[[ $errors == 0 ]] || exit 1
printf 'PASS: v70 driver isolation and seven outcome controls\n'
