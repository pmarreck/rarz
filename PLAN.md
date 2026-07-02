# PLAN

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
- [ ] Follow-up: `tests/diagnose_crc.zig` (`zig build diagnose`) does not compile under
  Zig 0.16 (removed `std.heap.GeneralPurposeAllocator`, `std.process.argsWithAllocator`).
  Modernize when next needed (diagnostic-only, out of the CRC-fix scope).


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
