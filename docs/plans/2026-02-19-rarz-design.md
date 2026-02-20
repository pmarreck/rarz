# rarz Design Document

Status: Approved
Date: 2026-02-19

## 1. Purpose

Clean-room Zig implementation of a RAR archive parser, validator, decompressor, and (eventually) compressor. Serves as:
- A standalone library with C FFI for any consumer
- A drop-in CLI replacement for the official `rar` command (supported subset)
- The RAR validation backend for the `validate` / Entropy Shield project

## 2. Architecture

```
+---------------------------------------------+
|  C CLI (rarz)                               |
|  - arg parsing, file I/O, stdio, exit codes |
|  - drop-in rar grammar: t, l, v, x, a      |
|  - calls ONLY through C FFI                 |
+------------------+---------------------------+
                   | C FFI (rarz.h)
                   | opaque handles, ptr+len buffers
                   | rarz_abi_version()
+------------------+---------------------------+
|  Zig Core Library (no I/O)                  |
|  +----------+ +------------+ +-----------+  |
|  |detect.zig| |reader.zig  | |integrity  |  |
|  |sig/SFX   | |LE+vint     | |CRC16/32   |  |
|  |dispatch  | |bounds check| |BLAKE2sp   |  |
|  +----------+ +------------+ +-----------+  |
|  +----------------+ +------------------+    |
|  |rar4_headers.zig| |rar5_headers.zig  |    |
|  |legacy parse    | |RAR5 blocks+extras|    |
|  +----------------+ +------------------+    |
|  +-----------+ +----------+                 |
|  |policy.zig | |writer.zig|                 |
|  |validation | |store-only|                 |
|  |depth map  | |RAR5 emit |                 |
|  +-----------+ +----------+                 |
|  +--- decompress/ -------------------------+|
|  | huffman.zig  lz.zig    ppm.zig          ||
|  | unpack15.zig unpack20.zig unpack29.zig  ||
|  | unpack50.zig filters.zig               ||
|  +-----------------------------------------+|
+---------------------------------------------+
```

### Key Constraints
- Zig core performs NO I/O (hexagonal boundary)
- C CLI dogfoods the same C FFI used by external consumers
- All dependencies via `flake.nix` (Zig 0.15.x, rar, unrar)
- No dynamic allocation from untrusted lengths without max clamps (2 MiB header cap)
- Arena allocator per parse operation

## 3. CLI Commands

| Short | Long           | Description                    |
|-------|----------------|--------------------------------|
| `a`   | `add`          | Add files to archive           |
| `x`   | `extract`      | Extract with full paths        |
| `t`   | `test`         | Test archive integrity         |
| `l`   | `list`         | List archive contents          |
| `v`   | `list-verbose` | Verbose list with details      |

Unsupported commands return non-zero with `"unsupported command: <cmd>"`.

## 4. Format Coverage

### Signatures
- RAR 1.4: `52 45 7E 5E` (detect + structural parse when specimens available)
- RAR 1.5-4.x: `52 61 72 21 1A 07 00`
- RAR5+: `52 61 72 21 1A 07 01 00`
- SFX prefix scanning up to configurable max offset
- Future marker handling (byte 6 > 1 and < 5)

### Decompression (all generations, dispatched by UnpVer)
- **v15** (RAR 1.4/1.5): adaptive Huffman + LZ, 4 symbol sets, flag buffer + moving averages
- **v20/v26** (RAR 2.x): multi-table Huffman + LZ + dedicated audio predictor mode
- **v29** (RAR 3.x): dual-mode LZ/PPMd, range coder, VM filter stack (E8/E8E9/Itanium/RGB/Audio/Delta)
- **v50/v70** (RAR 5/7): block-chunked Huffman + LZ, 4 filter types (E8/E8E9/ARM/Delta), RAR7 extends distance alphabet (DCB=64 -> DCX=80)

### Compression (write path)
- Store-only (method=0) initially
- RAR5 default compression as follow-on

## 5. Validation Policy

Three validation depths:
- `signature`: magic bytes only
- `structural`: header/block walk + header checksums (CRC16 legacy, CRC32 RAR5)
- `full`: payload integrity (CRC32 + BLAKE2sp) via decode

Encrypted content without key: `structural` + `has_encrypted_content=true`.
Empty password success: `full` + `circumvented_trivial_protection=true`.

## 6. Implementation Phases

### Phase 1: Infrastructure + Structural Parser
- `flake.nix`, `build.zig`, `./build`, `./test` scripts
- Signature detection (all 3 families + SFX scan)
- Bounded reader (LE + vint)
- RAR 1.5-4.x header parser + CRC16
- RAR5 header/block/extras parser + CRC32
- Validation policy (signature/structural/full)
- C FFI surface + C CLI skeleton (t/l/v commands)

### Phase 2: Store-Method I/O
- Store-method extract (x)
- Store-method archive creation (a)
- Payload CRC32 + BLAKE2sp verification
- CLI add and extract commands

### Phase 3: Decompression Engine
- Canonical Huffman decode builder (shared across generations)
- LZ match-copy primitive with corruption hardening (overlap, wrap, zero-fill)
- v50/v70 decoder (most common in modern archives)
- v29 LZ + PPMd + VM filters
- v20 decoder + audio mode
- v15 decoder

### Phase 4: Polish + Interop
- Corruption harness (5x deterministic mutations, seeded PRNG)
- Two-way interop gates (official <-> rarz)
- Multi-volume awareness
- RAR5 compression for write path

## 7. File Layout

```
src/
  lib/
    detect.zig          # signature/SFX scan, family dispatch
    reader.zig          # bounded LE + vint reader
    rar4_headers.zig    # RAR 1.5-4.x header parsing
    rar5_headers.zig    # RAR5 block/extras parser
    integrity.zig       # CRC16/CRC32/BLAKE2sp
    policy.zig          # validation depth mapping
    writer.zig          # RAR5 archive creation
    decompress/
      huffman.zig       # canonical Huffman builder + DecodeNumber
      lz.zig            # LZ match-copy with overlap/wrap handling
      unpack15.zig      # RAR 1.5 decoder
      unpack20.zig      # RAR 2.x decoder + audio
      unpack29.zig      # RAR 3.x LZ + PPM + VM filters
      unpack50.zig      # RAR 5/7 decoder + filters
      ppm.zig           # PPMd model + range coder
      filters.zig       # filter subsystem (v3 VM + v5 native)
    root.zig            # public API + C FFI exports
  cli/
    main.c              # C CLI
include/
  rarz.h                # C FFI header
tests/
  unit/
  integration/
  cli/
  fixtures/
```

## 8. Test Strategy

- Test fixtures generated via `rar` on `gen-fake-tree --seed <N>` output
- Deterministic corruption: 5 mutations per copy, seeded PRNG, exclude signature windows
- Interop gates: official encode -> rarz decode, rarz encode -> official decode
- Corruption opacity classification per profile (transparent/opaque/mixed)
- CLI tests driven by bash in tests/cli/

## 9. Decisions Made During Design

- **Zig 0.15.x** pinned via flake.nix
- **RAR 1.4**: full structural parse (not just detection) — "ACHIEVEMENT UNLOCKED" for ancient formats
- **CLI scope**: t + l + v + x + a with full-word aliases from day one
- **Compression spec**: delivered concurrently by spec lane (RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md)
- **validate integration**: rarz as Zig module import for validate, C FFI for all other consumers
- **Allocator**: arena per parse, max-clamped untrusted lengths
