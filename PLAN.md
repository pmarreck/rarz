# PLAN

## Phase 0: Specification and Design
- [x] Create initial RAR format specification draft (`RAR_SPECIFICATION.md`) (2026-02-19 EST)
- [x] Add architecture constraints: Zig in-memory core + C FFI + C drop-in CLI (`rarz`) (2026-02-19 EST)
- [x] Add required LLM cleanroom attestation header template with signed/date requirement (2026-02-19 EST)
- [x] Add exhaustive English compression-algorithm spec derived from unRAR eval (`RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md`) (2026-02-20 EST)

## Phase 1: Infrastructure + Structural Parser
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
- [x] Add project documentation: overview, code minimap, plan update (2026-02-20 EST)
- [ ] Implement C CLI wrapper `rarz` that routes all operations through C FFI (dogfood gate)
- [ ] Build argument-compatibility matrix against official `rar` CLI grammar (supported subset)

## Phase 2: Store-Method I/O + Interop
- [ ] Build binary fixture corpus (official-tool generated + real-world samples)
- [ ] Add interoperability gate A: official-encoded archives decode in `rarz`
- [ ] Add interoperability gate B: `rarz` store-only output decodes in official tools
- [ ] Add BLAKE2sp payload verification for RAR5 files
- [ ] CLI add and extract commands (a, x)
- [ ] CLI list and test commands (l, v, t)

## Phase 3: Decompression Engine
- [ ] Canonical Huffman decode builder (shared across generations)
- [ ] LZ match-copy primitive with corruption hardening (overlap, wrap, zero-fill)
- [ ] v50/v70 decoder (most common in modern archives)
- [ ] v29 LZ + PPMd + VM filters
- [ ] v20 decoder + audio mode
- [ ] v15 decoder

## Phase 4: Polish + Interop
- [ ] Add deterministic 5x corruption harness with seed-based PRNG
- [ ] Classify corruption opacity per RAR profile (`transparent|opaque|mixed`)
- [ ] Two-way interop gates (official <-> rarz) for compressed archives
- [ ] Multi-volume awareness and reconstruction
- [ ] RAR5 compression for write path
- [ ] Expand method support and multi-volume reconstruction behavior
