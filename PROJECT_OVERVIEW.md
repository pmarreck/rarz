# rarz - Clean-Room RAR Archive Toolkit

## Goals

rarz is a clean-room implementation of a RAR archive parser, validator, decompressor, and (eventually) compressor, written in Zig with a C FFI and a drop-in C CLI.

### Primary uses:
- **Standalone library**: Any language can consume the C FFI to read/write/validate RAR archives
- **CLI tool**: `rarz` is a drop-in replacement for the official `rar` command (supported subset)
- **Validation backend**: Powers RAR validation in the `validate` / Entropy Shield project

## Architecture

- **Zig core library** (no I/O): All business logic, parsing, validation, compression/decompression
- **C FFI** (`rarz.h`): The public API surface — opaque handles, buffer-based operations
- **C CLI** (`rarz`): Dogfoods the C FFI; handles all file I/O, argument parsing, formatting

## Terminology

| Term | Definition |
|------|-----------|
| **UnpVer** | Decompression algorithm version (15/20/26/29/50/70), determines which decoder to use |
| **Method** | Compression level within an algorithm generation (0=store/uncompressed, 1-5=increasing compression) |
| **vint** | RAR5 variable-length integer: 7 value bits per byte, high bit = continuation |
| **SFX** | Self-extracting archive: executable prefix before the RAR signature |
| **Store** | Method 0 — data is stored uncompressed; packed data = unpacked data |
| **Structural validation** | Verifying header checksums and block framing without decoding payload |
| **Full validation** | Structural + payload integrity (CRC32/BLAKE2sp after decode) |
| **BLAKE2sp** | Parallelized BLAKE2s tree hash (8 leaves, used by RAR5 for file integrity) |
| **Clean-room** | Implementation derived from spec documents only, not from reading proprietary source code |

## RAR Format Families

| Family | Signature | Algorithm versions |
|--------|-----------|-------------------|
| RAR 1.4 | `52 45 7E 5E` | Ancient (pre-Windows) |
| RAR 1.5-4.x | `52 61 72 21 1A 07 00` | UnpVer 15, 20, 26, 29 |
| RAR5+ | `52 61 72 21 1A 07 01 00` | UnpVer 50, 70 |
