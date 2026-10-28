#!/usr/bin/env bash
set -u
luajit tests/unit/coverage_test.lua || exit 1
source tests/support/capture.bash || exit 1
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
out='' err='' rc=0
errors=0
fail() { printf 'FAIL: %s\n' "$1"; errors=$((errors+1)); }
host=$(luajit -e 'package.path="scripts/?.lua;"..package.path; local c=require("build-core"); local function r(s) local f=assert(io.popen(s)); local v=f:read("*l"); f:close(); return v end; print(assert(c.platform(r("uname -s"),r("uname -m"))))')
capture ./assess-coverage --about
[[ $rc == 0 && $out == *"PF=$host" && $out != *$'\n'* ]] || fail 'assessment identity lacks canonical execution platform'
mkdir -p "$scratch/project/tests/support" "$scratch/project/scripts" "$scratch/project/bin/$host" "$scratch/project/zig-out/bin" || exit 1
cp assess-coverage "$scratch/project/" || exit 1
cp tests/support/assess-coverage.lua tests/support/coverage.lua "$scratch/project/tests/support/" || exit 1
cp scripts/build-core.lua "$scratch/project/scripts/" || exit 1
ln -s "$(realpath "${RARZ:-zig-out/bin/rarz}")" "$scratch/project/bin/$host/rarz" || exit 1
printf '#!%s\nexit 77\n' "$(command -v bash)" > "$scratch/project/zig-out/bin/rarz"
chmod +x "$scratch/project/zig-out/bin/rarz"
capture env -u RARZ bash "$scratch/project/assess-coverage" --profile bolter --margin 0.49 --max-attempts 12 --output "$scratch/published" "$(realpath tests/fixtures/rar5_m3.rar)"
[[ $rc == 0 || $rc == 1 ]] || fail "default assessment used stale flat product: $err"
capture ./assess-coverage --profile bolter --margin 0.49 --max-attempts 12 --output "$scratch/real" tests/fixtures/rar5_m3.rar
[[ $rc == 0 || $rc == 1 ]] || fail "real assessment did not complete (exit $rc): $err"
jq -e '.cells[0].eligible == 4 and .cells[0].precision_met and .inputs_unchanged' "$scratch/real/summary.json" >/dev/null 2>&1 || fail 'real summary lacks fixed sample and integrity evidence'
if [[ -f $scratch/real/trials.jsonl ]]; then
	jq -c 'select(.id == 1) | .mutation.record' "$scratch/real/trials.jsonl" > "$scratch/case.json"
	capture corruption-reader apply --case "$scratch/case.json" -o "$scratch/replay.rar" tests/fixtures/rar5_m3.rar
	[[ $rc == 0 ]] || fail 'record did not replay'
	actual=$(sha256sum "$scratch/replay.rar"); actual=${actual%% *}
	expected=$(jq -r 'select(.id == 1) | .mutant_sha256' "$scratch/real/trials.jsonl")
	[[ $actual == "$expected" ]] || fail 'replay hash differs from observed mutation'
fi
capture ./assess-coverage --profile identity --margin 0.49 --max-attempts 4 --output "$scratch/identity" tests/fixtures/rar5_m3.rar
[[ $rc == 2 ]] || fail 'unchanged identity cases must not establish coverage'
jq -e '.cells[0].eligible == 0 and (.cells[0].precision_met|not)' "$scratch/identity/summary.json" >/dev/null 2>&1 || fail 'identity incorrectly counted'
cat > "$scratch/primary-header.json" <<'PROFILE'
{"profile":1,"name":"primary_header_crc","root":{"zone":{"kind":"range","unit":"bytes","anchor":"start","start":937,"length":1,"count":1},"do":{"op":"flip"}}}
PROFILE
capture ./assess-coverage --profile "$scratch/primary-header.json" --margin 0.49 --max-attempts 4 --output "$scratch/primary-header" tests/fixtures/rar5_m3.rar
[[ $rc == 0 ]] || fail "reference must read damaged primary headers instead of cached quick-open copies (exit $rc): $err"
jq -e '.cells[0].eligible == 4 and .cells[0].detected == 4 and .cells[0].counts.disagreement == 0' "$scratch/primary-header/summary.json" >/dev/null 2>&1 || fail 'primary-header corruption escaped the reference oracle'
jq -e '.reference_args == ["t","-p-","-idq","-qo-"]' "$scratch/primary-header/summary.json" >/dev/null 2>&1 || fail 'reference invocation is missing from evidence'
cat > "$scratch/comment-payload.json" <<'PROFILE'
{"profile":1,"name":"comment_payload","root":{"zone":{"kind":"range","unit":"bits","anchor":"start","start":367,"length":1,"count":1},"do":{"op":"flip"}}}
PROFILE
capture ./assess-coverage --profile "$scratch/comment-payload.json" --margin 0.49 --max-attempts 4 --output "$scratch/comment-payload" tests/fixtures/rar2_v20_comment.rar
[[ $rc == 0 ]] || fail "comment damage with reference exit zero was misclassified (exit $rc): $err"
jq -e '.cells[0].eligible == 4 and .cells[0].detected == 4 and .cells[0].counts.disagreement == 0' "$scratch/comment-payload/summary.json" >/dev/null 2>&1 || fail 'comment damage did not enter the confirmed-damage denominator'
jq -s -e 'length == 4 and all(.[]; .reference.exit == 0 and .reference.class == "damaged")' "$scratch/comment-payload/trials.jsonl" >/dev/null 2>&1 || fail 'comment diagnostic control did not exercise reference exit zero'
cat > "$scratch/accept-all" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == --about ]]; then printf 'test validator\n'; else printf 'Validation: VALID\n'; fi
MOCK
chmod +x "$scratch/accept-all"
capture ./assess-coverage --rarz "$scratch/accept-all" --profile bolter --margin 0.49 --max-attempts 12 --output "$scratch/misses" tests/fixtures/rar5_m3.rar
[[ $rc == 1 ]] || fail 'accept-all validator must expose misses'
jq -e '.cells[0].detected == 0 and .cells[0].counts.missed == 4' "$scratch/misses/summary.json" >/dev/null 2>&1 || fail 'misses were not counted'
cat > "$scratch/reject-all" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == --about ]]; then printf 'test validator\n'; else printf 'Validation: INVALID\n'; exit 1; fi
MOCK
chmod +x "$scratch/reject-all"
capture ./assess-coverage --rarz "$scratch/reject-all" --output "$scratch/rejected" tests/fixtures/rar5_m3.rar
[[ $rc == 2 ]] || fail 'reject-all validator must fail the pristine control'
cat > "$scratch/crash" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == --about ]]; then printf 'test validator\n'
elif [[ $2 == */mutant.rar ]]; then printf 'Validation: INVALID\n'; kill -SEGV "$$"
else printf 'Validation: VALID\n'; fi
MOCK
chmod +x "$scratch/crash"
capture ./assess-coverage --rarz "$scratch/crash" --profile bolter --margin 0.49 --max-attempts 12 --output "$scratch/crashed" tests/fixtures/rar5_m3.rar
[[ $rc == 2 ]] || fail 'crash must make the assessment incomplete'
jq -e '.cells[0].detected == 0 and .cells[0].counts.inconclusive >= 4' "$scratch/crashed/summary.json" >/dev/null 2>&1 || fail 'crash counted as detection'
capture ./assess-coverage --profile bolter --margin 0.49 --max-attempts 12 --output "$scratch/stdin" - < tests/fixtures/rar5_m3.rar
[[ $rc == 0 || $rc == 1 ]] || fail 'stdin archive did not complete'
jq -e '.cells[0].eligible == 4 and .inputs_unchanged' "$scratch/stdin/summary.json" >/dev/null 2>&1 || fail 'stdin lacks verification evidence'
cat > "$scratch/broken-mutator" <<'MOCK'
#!/usr/bin/env bash
if [[ $1 == --about ]]; then printf 'corruption-reader 0.7.0\n'; exit 0; fi
while [[ $# -gt 0 ]]; do
	if [[ $1 == --report ]]; then printf '{broken\n' > "$2"; exit 0; fi
	shift
done
exit 2
MOCK
chmod +x "$scratch/broken-mutator"
capture ./assess-coverage --mutator "$scratch/broken-mutator" --output "$scratch/broken" tests/fixtures/rar5_m3.rar
[[ $rc == 2 ]] || fail 'broken mutation report must fail'
[[ -f $scratch/broken/mutation.jsonl ]] || fail 'failed mutation diagnostic was discarded'
cat > "$scratch/failed-identity" <<'MOCK'
#!/usr/bin/env bash
printf 'fixture resource setup failed\n' >&2
exit 125
MOCK
chmod +x "$scratch/failed-identity"
capture ./assess-coverage --mutator "$scratch/failed-identity" --output "$scratch/identity-failure" tests/fixtures/rar5_m3.rar
[[ $rc == 2 ]] || fail 'failed identity probe must return incomplete'
jq -e '.status == "incomplete" and (.error | contains("mutator identity probe failed")) and .tools.mutator.identity.exit == 125 and (.tools.mutator.identity.stderr | contains("fixture resource setup failed"))' "$scratch/identity-failure/summary.json" >/dev/null 2>&1 || fail 'identity probe failure was mislabeled or its evidence lost'
[[ $errors == 0 ]] || exit 1
printf 'PASS: assessment adapters, no-op accounting, misses and pristine control\n'
