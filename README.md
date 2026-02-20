# rarz

[![CI](https://github.com/pmarreck/rarz/actions/workflows/ci.yml/badge.svg)](https://github.com/pmarreck/rarz/actions/workflows/ci.yml)
[![built with garnix](https://img.shields.io/endpoint.svg?url=https://garnix.io/api/badges/pmarreck/rarz)](https://garnix.io/repo/pmarreck/rarz)

A clean-room RAR archive toolkit: parser, validator, extractor, and writer.

Written in Zig with a C FFI and drop-in C CLI.

## Status

**Phase 1 complete** — structural parsing, store-method extraction/creation, and full validation for RAR 1.4, RAR 1.5-4.x, and RAR5+ archives.

**Phase 2 in progress** — decompression engine for compressed archives.

## Architecture

```
Any CLI / consumer ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

- **Zig core library** — all parsing, validation, compression/decompression logic; performs no I/O
- **C FFI** (`rarz.h`) — the public API surface; opaque handles, buffer-based operations
- **C CLI** (`rarz`) — dogfoods the C FFI; handles all file I/O and argument parsing

## Building

### With Zig (0.14+)

```sh
zig build              # build library + CLI
zig build test         # run unit tests
zig build run -- help  # run CLI
```

### With Nix

```sh
nix develop            # enter dev shell with zig, rar, unrar
zig build
```

## Usage

### CLI

```sh
# List files
rarz list archive.rar
rarz l archive.rar

# Test integrity
rarz test archive.rar
rarz t archive.rar

# Extract files
rarz extract archive.rar
rarz x archive.rar

# Verbose listing
rarz verbose archive.rar
rarz v archive.rar

# Create store-only archive
rarz add output.rar file1.txt file2.txt
rarz a output.rar file1.txt file2.txt
```

### C API

```c
#include "rarz.h"

// Detect format
int32_t family = rarz_detect_format(data, len);

// Open and list files
rarz_archive *ar = rarz_open(data, len);
uint32_t count = rarz_file_count(ar);
for (uint32_t i = 0; i < count; i++) {
    rarz_file_entry entry;
    rarz_file_info(ar, i, &entry);
    printf("%.*s (%llu bytes)\n", entry.name_len, entry.name, entry.unpacked_size);
}

// Validate
rarz_validation_result r = rarz_validate(data, len);
// r.depth: 0=signature, 1=structural, 2=full

// Extract
uint8_t buf[4096];
int64_t written = rarz_extract_to_buffer(ar, 0, buf, sizeof(buf));

rarz_close(ar);
```

### Zig Package

Add to your `build.zig.zon` dependencies:

```zon
.rarz = .{
    .url = "https://github.com/pmarreck/rarz/archive/refs/heads/yolo.tar.gz",
    .hash = "...",  // zig build --fetch will provide this
},
```

## Supported Formats

| Family | Signature | Status |
|--------|-----------|--------|
| RAR 1.4 | `52 45 7E 5E` | Detection only |
| RAR 1.5-4.x | `52 61 72 21 1A 07 00` | Parse + validate + store extract |
| RAR5+ | `52 61 72 21 1A 07 01 00` | Parse + validate + store extract + create |

## Validation Depth

rarz validates archives to the deepest level possible:

- **Signature** — recognized RAR magic bytes (with SFX prefix scanning)
- **Structural** — all header checksums (CRC16 for RAR4, CRC32 for RAR5) pass
- **Full** — structural + payload integrity (CRC32 data verification for store-method files)

## Clean-Room Implementation

This is a clean-room implementation derived from format specification documents only, not from reading proprietary source code. See `RAR_SPECIFICATION.md` and `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` for the specifications used.

## License

[MIT](LICENSE)
