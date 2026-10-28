# Archive validation evidence index

This indexes current tests and historical findings for the Mecha Validate
release milestone. It does not claim complete coverage of every RAR variant.
The dependency-refresh evidence below used decoder baseline `80ec687`;
subsequent sections and linked reports identify later changes separately.

The later [October 15 corruption-reader assessment](COVERAGE_20261015.md)
provides a separate 18-pair statistical campaign, exact candidate identities,
and replayable findings. It does not replace the historical acceptance
evidence below.

The [seed-44 follow-up](COVERAGE_20261028_SEED44.md) disables reference quick-open
and meets the same 18-pair precision target. It records 6,929 detections, one
RAR2 decoded-size miss, and three reference-inconclusive cases. Its historical
miss remains recorded after the targeted decoder correction.

The [reference-exception adjudication](REFERENCE_EXCEPTION_ADJUDICATION_20261028.md)
establishes concrete structural damage in all nine reference-inconclusive
cases from seeds 43 and 44. Their original classifications and statistical
denominators remain unchanged.

## Replay

Run `./test` for the complete local entry point:

```sh
./test
```

The script prepares ReleaseSafe products through Nix, then runs every
`tests/cli/test_*.sh` suite inside private filesystem isolation. On a shared
Linux host, it admits the prepared runtime through `build-budget` itself.
`./build` produces the ReleaseFast Nix package. The committed Mechatron Prime
CI manifest also selects classifier, driver, publication, and Windows
emulation checks; it does not run every CLI suite or the large v70 corpus.
Local full-suite evidence therefore has a wider scope than that CI result.

Individual existing CLI cases can be replayed after building the CLI, for
example `nix develop -c bash tests/cli/test_solid.sh`. Apply a process timeout
and memory budget when running corruption cases. Existing scripts do not
consistently cap each individual oracle invocation.

Use the fixtures from the exact tested revision. Their content hashes are in
[`evidence/rar-fixtures.sha256`](evidence/rar-fixtures.sha256), checked with
`sha256sum -c docs/evidence/rar-fixtures.sha256` from the repository root.
That manifest covers the original 72-fixture set. Later fixture additions have
their own provenance documents and regressions. Most fixture generators invoke
independent RAR producers; their scripts and committed output bytes remain the
provenance and replay inputs.

## Dependency-refresh acceptance, October 9, 2026

Dependency commit `3b5a352` pins progrez to
`9f7cc53d6ecdf216d15fe8dd8327b00fc240ec09`. With that dependency, the
ReleaseSafe unit tests and all 16 CLI suites passed through `./test`. The
existing v70 gate ran rather than skipping: its pristine archive and both
legacy mutation cases passed. A byte comparison against a verified pre-run
backup confirmed that the local v70 archive was restored. All 72 committed
fixture hashes in the manifest matched.

The full run used a 16 GiB hard memory cap, disabled swap, and a 2400-second
timeout. Its initial 12 GiB soft threshold repeatedly throttled the v70 working
set without any hard-limit or OOM events. An operator explicitly approved and
applied a runtime-only 14 GiB soft threshold to that same live job. No gate was
restarted or skipped; the hard cap and timeout stayed unchanged. The sampled
cgroup peak was 13,363,650,560 bytes; the completion receipt did not retain a
final peak, so the sample is not claimed as the exact whole-run maximum.

These are acceptance results for the existing gates, subject to the limits
below. They do not strengthen the older mutation operators or classifications.

`./build` and both existing Nix manifest targets passed. A direct execution
smoke check of the resulting ReleaseFast CLI failed on the NixOS test host:
the ELF requests `/lib/ld-musl-x86_64.so.1`, which is absent there. This matches
the packaging limitation already documented in the August baseline plan.
The native ReleaseSafe CLI used by `./test` ran successfully. The bounded
dependency refresh does not repair or claim resolution of that packaging gap.

## Installed-package execution, October 10, 2026

The Linux package now explicitly targets musl and requests static executable
linkage while retaining libc/pthread support. The persistent
`tests/integration/package-smoke` fails on the previous package and passes on
the corrected ReleaseFast artifact. It executes `--about` and `--help`, accepts
the producer-created RAR5 store fixture, rejects a one-bit payload mutation,
and round-trips two compressed files through the C-hosted pthread path. On
Linux it also rejects ELF artifacts with an interpreter or shared-library
dependency. Both `./test` and the committed Mechatron Prime CI target list run
this actual package check.

The full ReleaseSafe unit and 16-suite CLI gate passed, including the existing
v70 cases. An earlier attempt reached passing subsuites but exited 2 because
the runner was edited while Bash was reading it; that attempt is not a passing
master gate. The successful replacement ran with frozen sources, whose hashes
and Git index tree matched before and after. The v70 archive also matched its
pre-run backup afterward. Its approved job-specific memory limits were 14 GiB
soft, 16 GiB hard, no swap, and a 2400-second timeout. The sampled cgroup peak
was 13,363,724,288 bytes; the final completion receipt did not retain a peak.
Neither the decoder nor the legacy mutation classifiers changed.

ReleaseFast compilation succeeded for all five intended targets with the
pinned Zig toolchain. Native execution was checked only on Linux x86-64.

| Target | Compilation | Execution |
|--------|-------------|-----------|
| `x86_64-linux-musl` | Nix package, static ELF | Package smoke passed |
| `aarch64-linux-musl` | Cross-compiled, static ELF | Not run |
| `aarch64-macos` | Cross-compiled, Mach-O arm64 | Not run |
| `x86_64-windows-gnu` | Cross-compiled, PE32+ x86-64 | Not run |
| `aarch64-windows-gnu` | Cross-compiled, PE32+ AArch64 | Not run |

## Bounded CLI outcome controls

`tests/support/validation-outcome.bash` classifies recorded process outcomes
before the bounded CLI suites count a mutation. `rarz t` requires exactly one
stdout verdict and its matching exit status: 0/VALID, 1/INVALID, or
69/UNVERIFIABLE. Missing, conflicting, malformed, or mismatched verdicts are
tool errors. A verdict printed before a crash or timeout cannot count as
damage detection. The command's VALID label retains its existing semantics;
it does not claim that encrypted entries were decrypted.

The reference classifier accepts UNRAR success status 0 and checksum-error
status 3. UNRAR 7.20 reports some truncated service blocks with warning status
1; only the exact stderr line `Unexpected end of archive` identifies that
warning as structural damage. Generic warnings remain inconclusive. The
paired classifier distinguishes detected damage, benign mutation, stricter
rarz validation, missed damage, and inconclusive execution. Misses and
inconclusive runs fail the bounded mutation gates.

`test_validation_outcome.sh` sweeps 4,096 rarz records and 1,280 reference
records across all 256 shell exit statuses, checks all 12 pairs of reference
and rarz outcome categories, and runs seven small real-process controls.
`./test` discovers it as a CLI suite; `checks.classifiers` runs it against the
installed package in Nix. Synthetic statuses test classification only. The
real controls cover pristine data, a payload mutation, encryption, missing
input, and the reference tool's truncated-service-block warning.

The existing solid sweep yields 36 explicit reference/rarz damage agreements.
The 42 volume truncations yield 25 reference-confirmed damage detections and
17 separately reported stricter rarz verdicts. The mutation positions and
operators are unchanged. The large v70 gate is also unchanged and retains its
older classification limits; this work does not replay its campaign or give
it the stronger classifier's guarantees.

Solid, precision-volume, and verify gates now require their declared fixture
sets, exact nonempty trial counts, and one designated must-detect control per
archive or volume set. `test_required_cases.sh` injects complete and incomplete
fixture sets, zero/missing/extra trial records, and missing control results.
It also runs the three real drivers against an empty injected corpus and
requires an explicit incomplete failure. Other trials may still be benign or
unadjudicated stricter results.

The designated controls reuse existing trials, with fixture identities in
`docs/evidence/rar-fixtures.sha256`. Solid controls overwrite `0xA5` at offsets
11280 (`rar2_v20_solid`), 13305 (`rar4_v29_solid`), and 13290 (`rar5_solid`).
Verify controls use offsets 3747 (`rar5_m3`), 4119 (`rar4_m3`), and 7774
(`rar5_solid`), requiring reference-confirmed damage and a named FAIL with
exit 1. Each precision-volume set designates its existing 700-byte truncation
of the first volume. These cases were confirmed as damage by both tools;
their presence is checked separately from the may-ignore trial counts.

## Existing evidence by feature

| Feature | Replayable checks and fixtures | What they establish and what remains |
|---------|--------------------------------|-------------------------------------|
| RAR2 / v20 | `test_solid.sh`, `test_verify.sh`, `root.zig` producer corpus; `rar2_v20_*` fixtures | Pristine decode, solid-state carry, large-window cases, and audio fixtures. A v26 dispatch alias is not evidence of a separately produced v26 stream. |
| RAR3/4 / v29 | `test_solid.sh`, `test_verify.sh`, `root.zig`; `rar4_m*`, `rar4_v29_*`, `rar4_large_window` | Pristine extraction comparisons and legacy deterministic mutations. |
| RAR3 PPMd | `root.zig` pristine-corpus classifier; `rar4_ppm_xml`, `rar4_ppm_prose`; `generate_ppm_fixtures.sh` | Committed positive regressions. The historical 12/12 mutation result is described in the coverage report; the report alone is not an executable replay of those exact mutation trials. |
| RAR2 audio | `root.zig` pristine-corpus classifier; `rar2_v20_audio_mono`, `rar2_v20_audio_stereo`; `generate_rar2_audio_fixtures.sh` | Real producer audio regressions. The historical 10/10 mutation count must not be presented as a newly replayed audio mutation campaign. |
| RAR5 / v50 | `test_decompress.sh`, `test_verify.sh`, `test_integration.sh`; `rar5_m1` through `rar5_m5`, store/stream/filter fixtures | Method and extraction checks. Bounded mutation loops require explicit verdicts and fail on missed or inconclusive trials. |
| RAR5 solid filters | `root.zig` pristine classifier; `rar5_solid_wrap_filter`; `generate_wrap_filter_fixture.sh` | Regression for corruption of shared raw decoder history by in-place output filtering. |
| RAR5 store payload accounting | `root.zig`: `rarz_verify_archive accounts for every pristine and payload-mutated entry` | Five deterministic payload positions per nonempty file, XOR `0x01`; exactly one damaged entry and complete entry accounting are asserted. |
| Solid v20/v29/v50 | `test_solid.sh` | Three pristine extraction comparisons and 12 fixed-byte overwrite trials per archive, classified separately as detected, benign, stricter, missed, or inconclusive. |
| RAR5 volumes | `test_precision_volumes.sh`, `test_volume_validate.sh`, `test_volumes.sh` | Intact sets, missing volumes, and tail truncations of 24/128/700 bytes per volume. Historical count: 42 damaged sets. |
| RAR4 volumes | `test_rar4_volumes.sh` | Stored/compressed intact sets and one fixed-byte overwrite at two-thirds of each volume; historical count: nine damaged sets. |
| Encryption | `root.zig` none/mixed/all classifier and header-encryption tests; `test_verify.sh` Gate G | Encrypted and unsupported content remains incomplete/unverifiable. Header encryption must not become damage or a zero-entry verified success. This does not prove decryption support. |
| RAR7 / v70 | `test_v70_corpus.sh`, `generate_v70_corpus.sh`, local `tests/fixtures_large/v70_longrange.rar` | Large distances and fractional dictionary witness; two mutations at 41% and 83% of archive length using XOR `0xA5`. The multi-GiB fixture is local, not committed. |

`docs/MECHA_VALIDATE_V1_RAR_GATE.md` retains the broader feature matrix and
historical aggregate counts. Those counts describe their original revisions
and mutation definitions; this index does not rename or strengthen them.

## Evidence limits and remaining work

- No recorded standalone `corruption-probe` campaign was found during the
  September context recovery. A cross-format campaign remains separate work.
- The v70 gate now fails if the required local corpus is missing and mutates
  private copies with a read-only source. Its persistent driver controls check
  missing inputs, source preservation, and misleading validator outcomes.
- `test_solid.sh` writes `0xA5`; it does not XOR a single bit, and can write an
  unchanged byte. `test_v70_corpus.sh` XORs `0xA5`, changing four bits. Neither
  is the current canonical sniper operation despite legacy wording.
- The v70 gate now requires explicit damage from both validators for both
  designated mutations. Crashes, timeouts, unsupported results, and resource
  failures cannot satisfy that control. More detailed execution categories
  remain part of the legacy-gate migration.
- The bounded mutation gates retain their legacy sampling positions and
  fixed-byte overwrites. Explicit outcome classification improves the evidence
  for those trials; it does not prove complete byte or format coverage.
- A `stricter` result is an unadjudicated reference-valid/rarz-damaged
  disagreement. It does not establish stronger correctness or the absence of
  false positives. Each such case needs its fixture, exact mutation position,
  and a format invariant before it can be counted as justified rejection; an
  independently known-valid alternate belongs in a specificity regression.
- Required-case guards cover the solid, precision-volume, verify, and v70
  gates. This does not establish fixture-completeness enforcement in every
  other legacy suite.
- Independent producer coverage remains absent for RAR 1.4 parsing and v15
  decoding, and incomplete for some VM-filter variants such as RGB/Itanium.
- Recovery/service/quick-open data payloads are not all hashed. Header checks
  do not establish every-byte verification. Recovery volumes are now recognized
  explicitly; recognition does not verify their payloads.
- Password support, checksum-less cases, and PPM heap admission retain their
  documented limitations. Extraction now restores supported mode/mtime fields;
  extended-time fidelity and native platform qualification remain limited.
  Do not turn unknown, unsupported, encrypted, or resource-limited outcomes
  into damage.

## Mutation vocabulary for future work

Preserve old artifacts under their original definitions. New reports must
record the operator definition/version, exact parameters, input hash, decoder
revision, and seed or exact changed positions needed for replay.

| Operator | Current contract |
|----------|------------------|
| sniper | XOR one selected bit; exactly one bit changes. |
| bolter (`boltgun` legacy alias) | XOR one selected byte with `0xFF`. |
| shotgun | XOR 8–16 distinct bit positions in a fully contained 32-byte window; reject inputs too small for that window. |
| nuke | Deterministic pseudorandom overwrite of a fully contained window, 4096 bytes by default; replacement must differ from the original. |
| badonkachomp | Delete a nonempty suffix while retaining at least one byte; preserve the producer's specified sampling distribution. |

Old dense-shotgun statistics are not comparable to new sparse-shotgun rates.
Prefix deletion remains a proposal. Any future campaign must preserve pristine
inputs and separate rejection, surviving-valid mutation, false acceptance,
crash, signal, timeout, and resource-limit outcomes.
