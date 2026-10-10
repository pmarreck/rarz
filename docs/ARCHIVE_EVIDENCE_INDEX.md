# Archive validation evidence index

This indexes existing tests and historical findings for the Mecha Validate
release milestone. It does not claim a new standalone `corruption-probe`
campaign or complete coverage of every RAR variant. The decoder baseline is
`80ec687`; the dependency refresh changes progrez, not decoder behavior.

## Replay

Run `./test` for the complete local entry point. On a shared Linux build host:

```sh
build-budget --project rarz -- nix develop -c timeout 2400 ./test
```

The script builds ReleaseSafe unit tests and CLI code, then runs every
`tests/cli/test_*.sh` suite. `./build` produces the ReleaseFast Nix package.
The committed Mechatron Prime CI manifest selects the package and a separate
ReleaseSafe unit-test derivation; it does not currently run the CLI suites.
Local full-suite evidence therefore has a wider scope than that CI result.

Individual existing CLI cases can be replayed after building the CLI, for
example `nix develop -c bash tests/cli/test_solid.sh`. Apply a process timeout
and memory budget when running corruption cases. Existing scripts do not
consistently cap each individual oracle invocation.

Use the fixtures from the exact tested revision. Their content hashes are in
[`evidence/rar-fixtures.sha256`](evidence/rar-fixtures.sha256), checked with
`sha256sum -c docs/evidence/rar-fixtures.sha256` from the repository root.
Most fixture generators invoke independent RAR producers; their scripts and
the committed output bytes remain the provenance and replay inputs.

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

## Existing evidence by feature

| Feature | Replayable checks and fixtures | What they establish and what remains |
|---------|--------------------------------|-------------------------------------|
| RAR2 / v20 | `test_solid.sh`, `test_verify.sh`, `root.zig` producer corpus; `rar2_v20_*` fixtures | Pristine decode, solid-state carry, large-window cases, and audio fixtures. A v26 dispatch alias is not evidence of a separately produced v26 stream. |
| RAR3/4 / v29 | `test_solid.sh`, `test_verify.sh`, `root.zig`; `rar4_m*`, `rar4_v29_*`, `rar4_large_window` | Pristine extraction comparisons and legacy deterministic mutations. |
| RAR3 PPMd | `root.zig` pristine-corpus classifier; `rar4_ppm_xml`, `rar4_ppm_prose`; `generate_ppm_fixtures.sh` | Committed positive regressions. The historical 12/12 mutation result is described in the coverage report; the report alone is not an executable replay of those exact mutation trials. |
| RAR2 audio | `root.zig` pristine-corpus classifier; `rar2_v20_audio_mono`, `rar2_v20_audio_stereo`; `generate_rar2_audio_fixtures.sh` | Real producer audio regressions. The historical 10/10 mutation count must not be presented as a newly replayed audio mutation campaign. |
| RAR5 / v50 | `test_decompress.sh`, `test_verify.sh`, `test_integration.sh`; `rar5_m1` through `rar5_m5`, store/stream/filter fixtures | Method and extraction checks. Some older corruption loops have weak acceptance conditions; see below. |
| RAR5 solid filters | `root.zig` pristine classifier; `rar5_solid_wrap_filter`; `generate_wrap_filter_fixture.sh` | Regression for corruption of shared raw decoder history by in-place output filtering. |
| RAR5 store payload accounting | `root.zig`: `rarz_verify_archive accounts for every pristine and payload-mutated entry` | Five deterministic payload positions per nonempty file, XOR `0x01`; exactly one damaged entry and complete entry accounting are asserted. |
| Solid v20/v29/v50 | `test_solid.sh` | Three pristine extraction comparisons and 12 fixed-byte overwrite trials per archive. The negative gate catches false acceptance, but does not distinguish every non-VALID outcome. |
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
- The v70 gate skips with exit zero if the local corpus is missing. Such a run
  is incomplete for v70 acceptance, regardless of the master script's exit.
  It also mutates the local fixture in place with an EXIT restoration trap.
  Preserve a verified recoverable copy before running it; a future gate should
  mutate only a private trial copy and assert restoration explicitly.
- `test_solid.sh` writes `0xA5`; it does not XOR a single bit, and can write an
  unchanged byte. `test_v70_corpus.sh` XORs `0xA5`, changing four bits. Neither
  is the current canonical sniper operation despite legacy wording.
- Several CLI gates classify oracle nonzero exit or absence of `VALID` as
  rejection. Crashes, timeouts, unsupported results, and resource failures
  require separate outcome accounting before these can support stronger
  corruption-detection claims.
- `test_integration.sh` logs surviving mutations without failing them;
  `test_decompress.sh` requires only some of five mutations to be rejected.
  Its pristine validation check searches for `VALID`, which also occurs within
  `INVALID`. These are existing test-quality gaps, not coverage proofs.
- Independent producer coverage remains absent for RAR 1.4 parsing and v15
  decoding, and incomplete for some VM-filter variants such as RGB/Itanium.
- Recovery/service/quick-open data payloads are not all hashed. Header checks
  do not establish every-byte verification. `.rev` recognition remains work.
- Password support, checksum-less cases, PPM heap admission, and extraction
  metadata fidelity retain their documented limitations. Do not turn unknown,
  unsupported, encrypted, or resource-limited outcomes into damage.

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
