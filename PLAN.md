# PLAN

Completed records: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Historical decisions and measurements: [development context](docs/plan_context/development-history.md). Current evidence limits: [archive evidence index](docs/ARCHIVE_EVIDENCE_INDEX.md).

## Current milestone

- [ ] Qualify the complete macOS CLI/isolation suite and native Linux ARM64/Windows runtime; macOS ARM64 units and package smoke now pass (context: docs/plan_context/build-layout.md).

## Correctness queue

- [ ] Recognize recovery-volume signatures without claiming recovery-data verification (#36).
- [ ] Verify exact-commit CI for archive-comment checksums and the UNRAR exit-zero diagnostic rule; complete 473-unit/CLI/v70 and native macOS acceptance passed (#21; context: docs/plan_context/rar2-comments.md).
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

## Recent completions

- [x] Publish seed-44 evidence and reject its overlong RAR2 match; full 471-unit/CLI/v70 and native macOS acceptance passed, followed by exact CI in 51 seconds (done 2026-10-28 01:53 EDT; commit a2f7550, context: docs/COVERAGE_20261028_SEED44.md).
- [x] Bound Nix compilation inputs and verify documentation reuse plus source invalidation; full 469-unit/CLI/v70 and native macOS checks passed, then exact CI passed in 69 seconds (done 2026-10-28 01:38 EDT; commit e80ea1e, context: docs/plan_context/compilation-source.md).
- [x] Reject initial Huffman repeats and overflowing tenth-byte VINT values; full 469-unit/CLI/v70 acceptance and exact CI passed in 147 seconds (done 2026-10-28 01:12 EDT; commit 752511b, context: docs/plan_context/integer-and-table-bounds.md).
- [x] Verify exact-commit CI for uncached reference and seed-43 evidence commit c2cb48d; passed in 95 seconds (done 2026-10-28 00:58 EDT; context: docs/COVERAGE_20261028.md).
- [x] Correct writer header/caller-buffer bounds and reject impossible volume capacity; full 465-unit/CLI/v70 and native macOS checks passed, then exact-commit CI passed in 103 seconds (done 2026-10-28 00:36 EDT; commit 1251857, context: docs/plan_context/writer-bounds.md).
- [x] Resolve #29 unknown-block skip semantics: both flag values remain readable in eight RAR4/RAR5 reference controls; eight CRC mutations are rejected, so flag absence alone is not a damage rule (done 2026-10-28 00:22 EDT; context: docs/plan_context/unknown-blocks.md).
- [x] Propagate FFI parser errors and preserve complete vintage EOF and ENDARC padding; full 457-unit/CLI/v70 and native macOS checks passed, then exact-commit CI passed in 216 seconds (done 2026-10-28 00:01 EDT; commit 67fa938, context: docs/plan_context/archive-collection.md).
- [x] Reject the three RAR2 partial-header campaign misses and all 18 related cuts while preserving valid vintage EOF; complete ./test passed 452 units and all CLI suites, and exact-commit CI passed in 112 seconds (done 2026-10-27 23:34 EDT; commit 279bb66, context: docs/plan_context/rar2-truncation.md).
