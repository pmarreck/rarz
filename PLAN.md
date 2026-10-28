# PLAN

Completed records: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Historical decisions and measurements: [development context](docs/plan_context/development-history.md). Current evidence limits: [archive evidence index](docs/ARCHIVE_EVIDENCE_INDEX.md).

## Current milestone

- [ ] Complete cross-platform-project-build-arch conformance through native runtime qualification: complete macOS CLI/isolation suite and Linux ARM64/Windows runtime; macOS ARM64 units and package smoke pass (context: docs/plan_context/build-layout.md).

## Correctness queue

- [x] Recognize recovery volumes without integrity claims and normalize directory names; complete 475-unit/CLI/v70 and native macOS acceptance passed, followed by exact CI in 71 seconds (done 2026-10-28 03:06 EDT; commit c6a8b25; #36; context: docs/plan_context/recovery-volumes.md).
- [x] Verify exact-commit CI for packed-part CRC validation and writer correction; complete 477-unit/CLI/v70 and native macOS acceptance passed, followed by exact CI in 76 seconds (done 2026-10-28 03:20 EDT; commit e4904a7; #26; context: docs/plan_context/packed-crc.md).
- [x] Match producer integer volume units and reject overflow; complete 479-unit/CLI/v70, native macOS checks, and optimized build passed, then exact CI passed in 57 seconds (done 2026-10-28 03:46 EDT; commit 0945c7a; #33; context: docs/plan_context/volume-size-units.md).
- [x] Validate RAR5 UTF-8 names independently of decoder support; complete 479-unit/CLI/v70, native macOS checks, and optimized build passed, then exact CI passed in 57 seconds (done 2026-10-28 03:46 EDT; commit 0945c7a; #30; context: docs/plan_context/utf8-names.md).
- [x] Bound RAR5 headers and extra-record traversal; complete 486-unit/CLI/v70, native macOS checks, and optimized build passed, then exact CI passed in 51 seconds (done 2026-10-28 04:00 EDT; commit d20bcd4; #4; context: docs/plan_context/extra-record-bounds.md).
- [x] Preserve RAR5 version records, distinct historical names, and extraction collision checks; complete 489-unit/CLI/v70, native macOS checks, optimized build, and exact CI passed in 85 seconds (done 2026-10-28 04:23 EDT; commit bd04561; #32; context: docs/plan_context/file-versions.md).
- [ ] Verify exact-commit CI for extraction metadata and the additive timestamp API; complete 492-unit/CLI/v70 suite, native macOS checks, Windows emulation gate, and optimized build passed (#35, #31; context: docs/plan_context/extraction-metadata.md).
- [ ] Account for encrypted RAR4 service/comment blocks and parse SALT/EXT_TIME fields (#11, #5).

## Evidence and resource follow-ups

- [ ] Add tested interruption propagation from ./test to its admitted runtime scope; awaiting the shared wrapper's owning-scope cancellation contract before integration.
- [ ] Adjudicate reference missing-volume and memory-limit outcomes from both campaigns without treating generic failures as damage; all six header-CRC disagreements resolve with quick-open disabled (context: docs/COVERAGE_20261028.md).
- [ ] Migrate remaining legacy mutation gates to versioned definitions with distinct crash, timeout, and resource outcomes (context: docs/ARCHIVE_EVIDENCE_INDEX.md).
- [ ] Adjudicate stricter reference disagreements using exact mutations and format invariants before making stronger coverage claims (context: docs/ARCHIVE_EVIDENCE_INDEX.md).
- [ ] Coordinate a PPM heap admission contract with the consumer; header dictionary size does not include the stream-declared heap of up to 256 MiB (context: docs/plan_context/development-history.md).
- [ ] Audit current no-checksum, unsupported-filter, and service-payload reporting against the published consumer contract before changing verdicts (context: docs/ARCHIVE_EVIDENCE_INDEX.md).
- [ ] Reconcile the existing flake lock with the current nixpkgs freshness policy in a separate toolchain milestone.
- [ ] Review implementation provenance against the accepted clean-room requirement (context: INTENT.md).

## Explicitly deferred

- [ ] Keep password support deferred until its scope and input channel are approved; preserve the settled mixed-encryption accounting and open-time password design (context: docs/plan_context/development-history.md).
- [ ] Keep the proposed three-dimension result redesign deferred; resolve its per-entry evidence and ABI issues against the current consumer contract before implementation (context: docs/plan_context/development-history.md).
- [ ] Keep RAR 1.4 parsing and v15 support outside the current milestone until independent producer fixtures and scope are established (context: docs/ARCHIVE_EVIDENCE_INDEX.md).
- [ ] Complete remaining VM filter variants only with independent producer evidence; v26 uses the v20 decoder and is not a separate multimedia implementation (context: docs/ARCHIVE_EVIDENCE_INDEX.md).
- [ ] Revisit input-side streaming only if a consumer requires it; output-side streaming verification is already delivered (context: docs/plan_context/development-history.md).
- [ ] Consider handle arenas, FFI/helper separation, shared writer construction, and endian helper cleanup only when touching those paths for a measured need.
- [ ] Build the remaining CLI argument-compatibility matrix against official rar behavior.
