# PLAN

Completed records: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Historical decisions and measurements: [development context](docs/plan_context/development-history.md). Current evidence limits: [archive evidence index](docs/ARCHIVE_EVIDENCE_INDEX.md).

## Current milestone

- [ ] Publish the RAR2 partial-header fix after its complete 452-unit/CLI acceptance and verify exact-commit CI (context: docs/plan_context/rar2-truncation.md).
- [ ] Qualify native macOS ARM64, Linux ARM64, and Windows runtime/isolation on their respective runners; current evidence is Linux AMD64 runtime plus five-target cross-build/publication checks (context: docs/plan_context/build-layout.md).

## Correctness queue

- [ ] Reproduce and prevent FFI collection from swallowing parser errors and verifying a surviving archive prefix; cover single and multi-volume readers.
- [ ] Determine whether header/checksum damage can be proved before returning UNVERIFIABLE for the six corrupted inputs resembling encrypted headers (context: docs/COVERAGE_20261015.md).
- [ ] Reproduce and fix writer header overflow for names near 4096 bytes (#20).
- [ ] Verify unknown-block skip semantics against the format contract and add rejection controls where required (#29).
- [ ] Recognize recovery-volume signatures without claiming recovery-data verification (#36).
- [ ] Reject invalid initial Huffman repeat symbols without desynchronizing the stream (#3).
- [ ] Reject overflowing tenth-byte VINT values (#8).
- [ ] Reproduce the RAR2 embedded-comment header CRC report with an independent fixture (#21).
- [ ] Add per-part packed CRC checks to split-volume validation (#26).
- [ ] Verify binary/decimal volume-size suffix behavior against the producer CLI (#33).
- [ ] Validate RAR5 UTF-8 filenames without conflating invalid encoding with unsupported decoding (#30).
- [ ] Parse RAR5 file-version extra records and prevent versioned-name collisions (#32).
- [ ] Restore extraction metadata, including directory times after children and RAR4 executable permissions (#35).
- [ ] Define timestamp presence and time basis in a richer metadata API before closing the remaining normalization scope of #31 (context: docs/plan_context/timestamps.md).
- [ ] Correct RAR5 Unix host-OS metadata from 3 to the specified value 1 and add independent attribute interoperability controls.
- [ ] Account for encrypted RAR4 service/comment blocks and parse SALT/EXT_TIME fields (#11, #5).
- [ ] Test extra-area bounds and forward-compatible record traversal (#4).

## Evidence and resource follow-ups

- [ ] Add tested interruption propagation from ./test to its admitted runtime scope; retain the distinction between interrupted parent and still-running child.
- [ ] Adjudicate the two RAR5 header-CRC disagreements and three RAR4 reference missing-volume outcomes from the statistical campaign without treating generic failures as damage (context: docs/COVERAGE_20261015.md).
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

## Recent completions

- [x] Reject the three RAR2 partial-header campaign misses and all 18 related cuts while preserving valid vintage EOF; complete ./test passed 452 units and all CLI suites (done 2026-10-27 23:19 EDT; commit pending, context: docs/plan_context/rar2-truncation.md).
- [x] Publish corruption assessment, v70 memory correction, timestamps, and Nix target publication; exact commit 5e11586 passed Mechatron Prime CI in 87 seconds (done 2026-10-27 23:11 EDT; context: docs/plan_context/build-layout.md).
- [x] Implement cross-platform-project-build-arch build/run/test layout, verified five-target publication, native profile checks, and assessment selection; complete ./test passed with native runtime limits documented (done 2026-10-27 23:02 EDT; commit 5e11586, context: docs/plan_context/build-layout.md).
- [x] Trace and fix eager dictionary writes; pass 450 ReleaseSafe units and the full pristine/two-mutation v70 gate at 11.03 GiB peak, preserving source corpus bytes (done 2026-10-27 21:41 EDT; uncommitted, context: docs/plan_context/v70-memory.md).
