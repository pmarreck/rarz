# PLAN

Completed records: [docs/PLAN_LOG.md](docs/PLAN_LOG.md). Historical decisions and measurements: [development context](docs/plan_context/development-history.md). Current evidence limits: [archive evidence index](docs/ARCHIVE_EVIDENCE_INDEX.md).

## Current milestone

- [ ] Complete cross-platform-project-build-arch conformance through native runtime qualification: complete macOS CLI/isolation suite and Linux ARM64/Windows runtime; macOS ARM64 units and package smoke pass (context: docs/plan_context/build-layout.md).

## Correctness queue

- [ ] Account for encrypted RAR4 service/comment blocks without overstating file-only verification; awaiting a valid producer fixture after the guessed CMT conversion failed reference validation (#11).
- [x] Verify exact-commit CI for the RAR5 multi-volume encryption fix; complete 503-unit/CLI/v70 suite, native macOS checks, and optimized build passed, followed by exact CI in 81 seconds (done 2026-10-28 05:23 EDT; commit 343ad30; context: docs/plan_context/mixed-encryption-volumes.md).
- [x] Verify exact-commit CI for encrypted-entry evidence in the multi-volume C API; complete 505-unit/CLI/v70 suite, native macOS checks, and optimized build passed, followed by exact CI in 58 seconds (done 2026-10-28 06:13 EDT; commit c2212c9; context: docs/plan_context/volume-verification-encryption.md).

## Evidence and resource follow-ups

- [ ] Add tested interruption propagation from ./test to its admitted runtime scope; awaiting the shared wrapper's owning-scope cancellation contract before integration.
- [x] Verify exact-commit CI for independent adjudication of all nine reference exceptions; full 503-unit/CLI/v70 suite and optimized build passed, followed by exact CI in 46 seconds, with historical classifications and confidence intervals preserved (done 2026-10-28 05:33 EDT; commit d0cbdea; context: docs/REFERENCE_EXCEPTION_ADJUDICATION_20261028.md).
- [x] Verify exact-commit CI for versioned legacy mutation gates and distinct execution outcomes; full 503-unit/CLI/v70 suite, optimized build, and native macOS classifier/driver checks passed, followed by exact CI in 53 seconds (done 2026-10-28 05:51 EDT; commit d79d607; context: docs/plan_context/legacy-mutation-records.md).
- [ ] Verify exact-commit CI for the 17 stricter volume cases; full 505-unit/CLI/v70 suite and optimized build pass, and exact replay proves partial declared quick-open payloads while reference file validation succeeds (context: docs/QUICKOPEN_TRUNCATION_ADJUDICATION_20261028.md).
- [ ] Coordinate a PPM heap admission contract with the consumer; requested its authoritative contract, since header dictionary size omits the stream-declared heap of up to 256 MiB (context: docs/plan_context/development-history.md).
- [x] Audit current no-checksum, unsupported-filter, and service-payload reporting against the published consumer contract; the adapter preserves incomplete counts but file verification does not cover ancillary payloads, and PPM/packed-input admission remains open (done 2026-10-28 06:11 EDT; context: docs/plan_context/consumer-contract-audit.md).
- [ ] Reconcile the existing flake lock with the current nixpkgs freshness policy in a separate toolchain milestone.
- [ ] Resolve provenance remediation scope after the published review and README correction; exact source/license audit versus independent replacement planning awaits an owner decision (context: docs/PROVENANCE_REVIEW_20261028.md).

## Explicitly deferred

- [ ] Keep password support deferred until its scope and input channel are approved; preserve the settled mixed-encryption accounting and open-time password design (context: docs/plan_context/development-history.md).
- [ ] Keep the proposed three-dimension result redesign deferred; resolve its per-entry evidence and ABI issues against the current consumer contract before implementation (context: docs/plan_context/development-history.md).
- [ ] Keep RAR 1.4 parsing and v15 support outside the current milestone until independent producer fixtures and scope are established (context: docs/ARCHIVE_EVIDENCE_INDEX.md).
- [ ] Complete remaining VM filter variants only with independent producer evidence; v26 uses the v20 decoder and is not a separate multimedia implementation (context: docs/ARCHIVE_EVIDENCE_INDEX.md).
- [ ] Revisit input-side streaming only if a consumer requires it; output-side streaming verification is already delivered (context: docs/plan_context/development-history.md).
- [ ] Consider handle arenas, FFI/helper separation, shared writer construction, and endian helper cleanup only when touching those paths for a measured need.
- [ ] Build the remaining CLI argument-compatibility matrix against official rar behavior.
