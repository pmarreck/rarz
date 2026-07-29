# PLAN

## ACTIVE QUEUE (2026-07-29 — thelio-nixos, git-only, Mecha Validate release push)

Context: new main dev machine (thelio-nixos = mechatron-prime, our own CI); jj
retired, **git only**; Garnix dead. Downstream driver: **Mecha Validate**
(`../validate_gui` → `../validate` → rarz) is heading to release, so RAR
coverage must be *precise* (never forgiving) with *actionable* error detail.

### 0. Machine/branch reconciliation
- [x] Local was 11 commits behind `origin/yolo` with a stale duplicate of
  already-landed work in the tree. Verified every local source change was 100%
  present upstream, backed up the full diff, discarded the duplicates, and
  fast-forwarded to `6304b55`. Preserved the 2 genuinely-unique changes:
  Einstein's ReleaseSafe floor + the `ZIG_RECENT_API_CHANGES.md` symlink fix
  (origin still pointed at the dead `/Users/pmarreck/Documents-CloudManaged`
  Mac path). Backups: scratchpad `backup/`. (2026-07-29 EDT)

### 1. Get the suite honestly green (BLOCKS everything else) — DONE
- [x] True RED baseline established on this machine: **5 failing suites**
  (test_commands, test_directories, test_output_flag, test_volume_create,
  test_volume_validate). (2026-07-29 EDT)
- [x] **Root cause A — real product bug, C-hosted UB.** Everything rarz
  *created* with 2+ files was silently corrupt (`unrar t` = "checksum error",
  `rarz x` = "file has no data size", yet `rarz t` said VALID). Boundary was
  exactly `compressible_count >= 2` → the parallel-compression path.
  `std.Thread.spawn` was selecting Zig's raw-`clone` Linux impl, which reads
  `linux.tls.area_desc` — initialized only by `std.start`, which NEVER RUNS
  because `main()` is C (our dogfooding architecture). Alignment stayed 0 →
  ReleaseSafe panics at `assert(isValidAlignGeneric)`; ReleaseFast compiled the
  assert out → UB → all compression results null → `results[i].data.?`
  null-unwrap → `packed_size == 0`. Fix: `.link_libc = true` on the **library**
  module (exe already had it), selecting the pthread-backed impl that needs no
  Zig TLS bootstrap. Latent on macOS (always pthread-backed) — surfaced only on
  moving to Linux. (2026-07-29 EDT)
- [x] **Root cause B — environmental + rules violation.** The 2 volume suites
  shelled out to `python3`, absent from the devshell, silently writing EMPTY
  input files → nothing to split → "expected at least 2 volumes, got 1".
  Replaced with an `awk` `repeat_str` helper (byte-identical output). Peter's
  brief forbids Python; a test dep that isn't in the flake is invisible rot.
  (2026-07-29 EDT)
- [x] Master `./test` in-env: **ALL TESTS PASSED**, exit 0, ~59s. (2026-07-29 EDT)
- [x] ReleaseSafe floor committed (Einstein's ask; Peter item #7).

### 2. ReleaseSafe UB triage (Peter item #7) — DONE (this round)
- [x] Extended the floor beyond Einstein's `flake.nix`/CI change to the master
  `./test`, covering BOTH the Zig unit tests and **the C-hosted CLI binary** —
  the FFI boundary is exactly where the UB above lived, and ReleaseSafe turned
  silent archive corruption into a loud panic at the true fault site.
- [x] Full suite is green under ReleaseSafe with no further panics; the
  `link_libc` defect above was the one real UB finding. Re-triage whenever new
  parallel/FFI code lands.

### 3. Inbox: RAR4 payload CRC32 false positive (2026-05-03, from validate)
- [ ] Real-world 17.5 MB RAR4 (`unrar t` = All OK) fails rarz with "payload
  CRC32 mismatch". **This is exactly the precision/trust bug class that matters
  for the Mecha Validate release.** Reproduce with a committed fixture first.
  Suspects listed in the note: polynomial variant, byte range (compressed vs
  decompressed), endianness, init/final-XOR. NOTE: the RAR5 multi-volume
  analogue of this was already fixed (CRC lives in the LAST part) — check
  whether RAR4 has a related "which header holds the authoritative CRC" issue.

### 4. Mecha Validate release polish (Peter item #9) — precision + error detail
- [ ] Audit RAR coverage for *precision over forgiveness*: no silently-skipped
  chunks, no "valid" verdicts on unverified data. (Prior finding: a
  `payload_end <= vol_data.len` guard silently DROPPED chunks — that class of
  thing must fail loudly, not pass quietly.)
- [ ] Upgrade error reporting for the `validate` consumer: structured, detailed
  messages carrying **byte offset / block type / entry name / expected-vs-actual**,
  not bare strings like "payload CRC32 mismatch". Design the API with validate's
  needs in mind (coordinate via LLMsend if the shape is unclear).

### 5. Inbox: streaming verification API (2026-07-10, from validate-archive-streaming)
- [ ] `validate` wants a sibling to `policy.validate(data)` that does not
  require the whole archive as `[]const u8` (it has a seekable `FileSource`).
  Deliverable per the note: either a narrow implementation + tests, OR a
  concise design with the smallest first API and concrete blockers. Start by
  tracing which parse/decompress paths genuinely need random access.
  Keep `policy.validate(data)` compatible.

### 6. Housekeeping
- [ ] Mechatron Prime CI: `MECHATRON_PRIME_CI.md` is untracked; wire rarz onto
  the Thelio runner (`mechatron-ci` skill owns targets/webhook/badge) now that
  Garnix is gone.
- [ ] Trash/process the 3 inbox notes once each is handled.

## CI migration off Garnix (2026-07-08 EST — Garnix shutting down 2026-07-15)
- [x] Garnix is shutting down 2026-07-15 (joining Shopify, open-sourcing; ALL user
  data + build artifacts deleted that day). The fleet-wide "All Garnix checks"
  aggregate wedge since ~07-01 was the wind-down degradation — not an account or
  repo bug. Confirmed via blog.garnix.io/blog/shutting-down/.
- [x] Replaced Garnix's nix-sandbox verification with a GitHub Actions `nix` job
  (DeterminateSystems/nix-installer-action; `nix build .#checks.x86_64-linux.default`
  + `.#packages.x86_64-linux.default`). Omitted magic-nix-cache (archived/deprecated).
  Native 4-platform zig CI unchanged; flake path is CI-verified again.
- [x] Removed the dead Garnix badge from README. (2026-07-08 EST)

## Recent Fixes (2026-07-02 EST — dedicated-owner onboarding)
- [x] Harness: `./test` now runs CLI suites in-env (`nix develop -c` for unrar/rar);
  stripped forbidden `set -euo pipefail` (→ `set -u`) and the `((errors++))` errexit
  footgun (→ `errors=$((errors + 1))`) across all suites. Revealed 2 hidden failures.
- [x] Fixtures: moved `fuzz_filter_type_invalid.rar` → `tests/fixtures/invalid/` (Interop
  Gate A treats `tests/fixtures/` as all-valid).
- [x] **Multi-volume verify bug**: `rarz t` reported false "payload CRC32 mismatch" on
  valid split-file archives. RAR5 stores the full-file CRC in the LAST volume part
  (split_after==false), not the first; `validate_volumes` + `collectRar5FilesUnified`
  now use the last part's CRC. Hermetic regression test embeds the official-rar m3
  fixtures. Master `./test` green in-env; agrees with unrar oracle.
- [x] `tests/diagnose_crc.zig` modernized for Zig 0.16 (Juicy Main + `std.Io`);
  its compilation is now gated on `zig build test` so CI enforces 0.16 compat
  and it can't silently rot again. (2026-07-03 EST)


## Phase 0: Specification and Design
- [x] Create initial RAR format specification draft (`RAR_SPECIFICATION.md`) (2026-02-19 EST)
- [x] Add architecture constraints: Zig in-memory core + C FFI + C drop-in CLI (`rarz`) (2026-02-19 EST)
- [x] Add required LLM cleanroom attestation header template with signed/date requirement (2026-02-19 EST)
- [x] Add exhaustive English compression-algorithm spec derived from unRAR eval (`RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md`) (2026-02-20 EST)

## Phase 1: Infrastructure + Structural Parser + Store-Method I/O
- [x] Define and freeze C ABI surface (versioning, opaque handles, memory-buffer-first APIs) (2026-02-20 EST)
- [x] Scaffold Zig core library crate with no direct filesystem/process I/O (2026-02-20 EST)
- [x] Implement signature scanner with SFX prefix support (`detect.zig`) (2026-02-20 EST)
- [x] Implement bounded reader primitives: LE, vint, checked seeks (`reader.zig`) (2026-02-20 EST)
- [x] Implement integrity primitives: CRC32, CRC16, BLAKE2sp (`integrity.zig`) (2026-02-20 EST)
- [x] Implement RAR 1.5-4.x structural parser + header CRC checks (`rar4_headers.zig`) (2026-02-20 EST)
- [x] Implement RAR5 structural parser + header CRC checks + extras parser (`rar5_headers.zig`) (2026-02-20 EST)
- [x] Implement validation policy mapping: signature/structural/full, encrypted-content handling (`policy.zig`) (2026-02-20 EST)
- [x] Add payload integrity verification for store-method files: CRC32 (`policy.zig`) (2026-02-20 EST)
- [x] Add writer MVP: RAR5 store-only archive creation (`writer.zig`) (2026-02-20 EST)
- [x] C FFI exports: open/close/detect/validate/file_info/extract/create (`root.zig`) (2026-02-20 EST)
- [x] C CLI: t/l/v/x/a commands with full-word aliases (`main.c`) (2026-02-20 EST)
- [x] Build binary fixture corpus + interop gates (official <-> rarz) (2026-02-20 EST)
- [x] Add project documentation: overview, code minimap (2026-02-20 EST)
- [x] Fix rarz_validate to delegate to policy.validate (2026-02-20 EST)
- [x] Consolidate encode_vint into reader.zig; remove dead CRC in writer (2026-02-20 EST)

## Phase 2: Decompression Engine
See: `docs/plans/2026-02-20-phase2-decompression.md`

### 2A: Cleanup & Foundation
- [ ] Fix RAR4 block iterator for >4GB files (data_size ?u32 → ?u64)
- [ ] Remove 64-file stack allocation limit in FFI archive creation
- [ ] Expose SFX detection through FFI (`rarz_detect_format_sfx`)
- [ ] Migrate from page_allocator to arena allocator for ArchiveHandle
- [ ] Add BLAKE2sp payload verification for RAR5 files

### 2B: Decompression Infrastructure
- [ ] BitReader for compressed streams (`decompress/bitreader.zig`)
- [ ] Canonical Huffman decoder (`decompress/huffman.zig`)
- [ ] LZ window buffer + match-copy primitive (`decompress/lz.zig`)

### 2C: RAR5/7 Decoder
- [ ] v50/v70 block reader + Huffman table loading (`decompress/unpack50.zig`)
- [ ] v50/v70 main decoder loop with LZ matches
- [ ] RAR5 filter subsystem: Delta, E8, E8E9, ARM (`decompress/filters.zig`)

### 2D: Wire Into FFI + Validation
- [ ] Dispatch by algo_version (`decompress/dispatch.zig`)
- [ ] Wire into rarz_extract_to_buffer (replace method!=0 rejection)
- [ ] Enable full-depth validation for compressed files in policy.zig

### 2E: RAR3 Decoder
- [ ] v29 LZ branch (`decompress/unpack29.zig`)
- [ ] PPMd model + range coder (`decompress/ppm.zig`)
- [ ] v29 PPM integration + block switching
- [ ] v29 VM filter subsystem (standard filters by CRC recognition)

### 2F: Legacy Decoders
- [ ] v20/v26 decoder + audio mode (`decompress/unpack20.zig`)
- [ ] v15 decoder + adaptive Huffman (`decompress/unpack15.zig`)

### 2G: Final Integration
- [ ] Compressed archive interop tests (rar → rarz → verify vs unrar)
- [ ] Full-depth validation for compressed archives
- [ ] Update PLAN.md, CODE_MINIMAP.md

## Phase 3: Polish + Advanced Features
- [x] Remove `circumvented_trivial_protection` from ValidationResult (PDF-specific, doesn't belong in rarz) (2026-02-24 EST)
- [ ] Multi-volume awareness and reconstruction
- [x] RAR5 compression for write path (2026-02-22 EST)
- [ ] RAR5 encryption (read + write)
  - [ ] AES-256-CBC decryption of encrypted file data (CRYPT block + per-file encryption)
  - [ ] PBKDF2-HMAC-SHA256 key derivation from password + salt
  - [ ] `--password` CLI flag for extraction and validation of encrypted archives
  - [ ] AES-256-CBC encryption for archive creation (`-p` flag)
  - [ ] Header encryption support (encrypted headers mode)
  - [ ] Interop tests: `rar -p` encrypted → `rarz --password` decrypts, and vice versa
  - [ ] Validation integration: full payload verification when password provided
- [ ] Build argument-compatibility matrix against official `rar` CLI grammar

## Phase 4: Distribution + CI
- [x] Add MIT License (`LICENSE`) (2026-02-20 EST)
- [x] Add `build.zig.zon` for Zig package manager consumption (2026-02-20 EST)
- [x] Create `rarz` repo on GitHub, set SSH remote, push (2026-02-20 EST)
- [x] Create README.md with project overview and usage (2026-02-20 EST)
- [x] Add Garnix CI configuration (`garnix.yaml` + `flake.nix` CI outputs) (2026-02-20 EST)
- [x] Add GitHub Actions CI across 4 platforms: macOS ARM, Linux Intel/ARM, Windows Intel (2026-02-20 EST)
- [x] Verify CI passes on all platforms (2026-02-20 EST)
- [x] Add CI badges to top of README.md (2026-02-20 EST)
- [x] Neutralize implementation-facing upstream-internal wording in source comments and README for legal-surface review (2026-02-22 EST)
- [x] Resolve `v` command surface collision by keeping `v`/`list-verbose` as listing aliases and adding explicit `vol`/`volumes` command; ensure `./test` rebuilds CLI before CLI tests (2026-02-22 EST)

## Fleet Code Review Follow-ups (2026-06-01)

Triaged 5 finding-notes from the fleet code review. Verified each against source before acting.

### Fixed (TDD: failing test first)
- [x] **CRITICAL** — `is_encrypted` hard-coded `0` for RAR5 + unified multi-volume files. Added non-allocating `rar5_headers.extra_has_encryption()` (detects file-encryption extra record, type `0x01`) and wired it into both `root.zig` FFI paths (RAR5 + unified) and the validation `has_encrypted_content` path in `policy.zig` (the `-p` per-file case the CRYPT-block check missed). (2026-06-02)
- [x] **WARN** — `vol_buf` leak on the error path of `writer.zig` `write_volumes_from_payloads`. Added per-iteration (block-scoped) `errdefer allocator.free(vol_buf)`. Regression covered by `checkAllAllocationFailures` test. (2026-06-02)
- [x] **WARN** — `page_allocator` per-file allocation in `validate_rar5_payload` hot loop. Replaced `parse_extra_records` + `extract_blake2sp_hash` with non-allocating `extract_blake2sp_hash_raw()` — zero allocation per file. (Decompression-branch `page_allocator` left as-is: large MB output, acceptable.) (2026-06-02)

### Declined (verified not applicable)
- microbench.zig `page_allocator`: the 1 MB buffer is one-time setup *outside* the timed loop, so it does not affect measured allocator overhead. Left unchanged to avoid perturbing the benchmark baseline.

### Deferred (non-bug refactors — record, do not churn blindly)
- [ ] **WARN** — Decompose large files: `root.zig` (~2173 lines) mixes FFI surface with collection helpers (`collectRar5FilesUnified`, `build_rar5_volume`); 220-line `rarz_extract_to_buffer` FFI export should be a thin shim over a Zig helper. `writer.zig`/`policy.zig` block-construction vs validation logic could split. Consider when next touching these files.
- [ ] **WARN** — `write_archive_compressed` / `write_archive_volumes` / `write_archive_volumes_compressed` likely share prelude/epilogue structure; factor shared helpers (unverified — flagged for confirmation).
- [ ] **INFO** — Duplicated trivial `write_u16_le`/`write_u32_le` wrappers in `rar4_headers.zig` and `policy.zig`; inline or move to a shared `endian.zig`. Cosmetic.
