# rarz

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Frarz.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

A RAR archive toolkit: parser, validator, extractor, and writer.

Written in Zig with a C FFI and drop-in C CLI.

See [project intent](INTENT.md) for scope and verification requirements, and
[terminology](TERMINOLOGY.md) for format definitions.

## Status

**Decompression** — extracts RAR5 archives at all compression levels (m0-m5), plus legacy RAR 1.5-4.x store-method extraction. Verified byte-perfect against independent reference extraction tooling.

**Compression** — creates RAR5 archives with LZ77 + Huffman compression at levels m0 (store) through m5 (best). Output is extractable by rarz and mainstream RAR extractors.

**Parsing & validation** — evidence-backed payload validation for the committed RAR2/v20, RAR3/4/v29, and RAR5/v50 corpus. RAR 1.4 is recognised but explicitly incomplete. See [`docs/MECHA_VALIDATE_V1_RAR_GATE.md`](docs/MECHA_VALIDATE_V1_RAR_GATE.md) for the exact matrix.

## Architecture

```
Any CLI / consumer ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

- **Zig core library** — all parsing, validation, compression/decompression logic; performs no I/O
- **C FFI** (`rarz.h`) — the public API surface; opaque handles, buffer-based operations
- **C CLI** (`rarz`) — dogfoods the C FFI; handles all file I/O and argument parsing

## Building

Nix is required for development builds; `flake.lock` pins the compiler and
dependencies. Language compilation runs inside Nix derivations.

```sh
./build                         # current platform, ReleaseFast
./build test                    # ReleaseSafe
./build debug                   # Debug
./build --all-platforms         # all five targets
./build --platform mswin-arm64  # one cross target
./run help                      # build current source, execute that exact product
./test                          # complete required acceptance suite
```

The single Zig/C implementation supports `linux-amd64`, `linux-arm64`,
`macos-arm64`, `mswin-amd64`, and `mswin-arm64`. `--all-impls` selects that
implementation; combining it with `--all-plats` is equivalent to `--all`.
Linux uses static musl, including pthread support for C-hosted Zig threads.
Windows uses the GNU compiler ABI and system DLLs; macOS links system libraries.
Nix builders run on Linux or macOS. Windows products can be built from WSL or
a cross builder; end users do not need Nix to execute the distributed CLI.

Complete products appear under `zig-out/PF/[musl/]PROFILE/`, backed by retained
Nix output roots. `bin/PF/rarz` directly selects a verified executable; Windows
gets a real `rarz.exe` copy. Only the current platform's directory belongs on
PATH. Publication preserves other platforms, unknown files, and the previous
selection on build or verification failure. Existing flat `zig-out` products
are preserved. See [build qualification](docs/plan_context/build-layout.md)
for checks, rollback, and native runtime limits.

`./test` prepares ReleaseSafe products through Nix, checks the installed
ReleaseFast package and all five target publications, then runs every unit and
CLI suite in a disposable Linux filesystem boundary. The large-corpus gate
requires the separately provisioned fixtures and disk-backed scratch; missing
fixtures or an unavailable isolation boundary fail explicitly. macOS and
Windows runtime acceptance still require qualified native test runners.

`./assess-coverage [RAR ...]` measures corrupt-input detection using replayable
mutations and independent UNRAR checks, with 95% confidence intervals and a
default precision of ±5 percentage points per archive/profile pair. See
[the assessment guide](docs/ASSESS_COVERAGE.md) for inputs, replay, and limits.

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

# Create archive (default -m3 compression)
rarz add output.rar file1.txt file2.txt
rarz a output.rar file1.txt file2.txt

# Create archive with specific compression level
rarz a -m0 output.rar file1.txt    # store (no compression)
rarz a -m1 output.rar file1.txt    # fastest
rarz a -m5 output.rar file1.txt    # best compression
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

// Verify every entry and retain incomplete evidence separately from damage
rarz_verify_archive_summary summary;
int32_t status = rarz_verify_archive(ar, &summary);
if (status == RARZ_ARCHIVE_VERIFY_DAMAGED) {
    fprintf(stderr, "%u damaged entries\n", summary.damaged_entry_count);
} else if (status == RARZ_ARCHIVE_VERIFY_INCOMPLETE) {
    fprintf(stderr, "%u unsupported entries\n", summary.unsupported_entry_count);
}

// Extract (handles both stored and compressed files)
uint8_t buf[4096];
int64_t written = rarz_extract_to_buffer(ar, 0, buf, sizeof(buf));

rarz_close(ar);

// Create compressed archive
rarz_create_file_entry files[] = { /* ... */ };
int64_t size = rarz_create_archive_compressed(files, count, out, out_len, 3); // -m3
```

### Zig Package

Add to your `build.zig.zon` dependencies:

```zon
.rarz = .{
    .url = "https://github.com/pmarreck/rarz/archive/refs/heads/yolo.tar.gz",
    .hash = "...",  // zig build --fetch will provide this
},
```

## Performance

Hardware-accelerated hot paths for compression, decompression, and validation:

- **CRC32**: ARM hardware CRC instructions (aarch64) + slicing-by-8 software fallback — 10-20x faster than naive table lookup
- **Match finding**: SIMD 16-byte vector comparison (`@Vector(16, u8)`) for LZ77 match extension
- **Bit I/O**: Bulk u64 load/store for BitReader refill and BitWriter flush
- **LZ window**: Stride copy for overlapping matches, split `@memcpy` for wrapping

Benchmark results on Apple Silicon (M-series, 4MB corpus, hyperfine):

| Operation | rar/unrar | rarz | Ratio |
|-----------|-----------|------|-------|
| Compress m0 (store) | 6.6 ms | 4.4 ms | **rarz 1.5x faster** |
| Compress m3 | 24 ms | 45 ms | rar 1.9x faster |
| Extract m0 | 3.9 ms | 2.7 ms | **rarz 1.5x faster** |
| Extract m3 | 7.2 ms | 8.5 ms | rar 1.2x faster |
| Validate m0 | — | 3.2 ms | — |
| Validate m3 | — | 7.7 ms | — |
| CRC32 throughput | — | ~10 GB/s | — |

## Supported Formats

| Family | Signature | Status |
|--------|-----------|--------|
| RAR 1.4 | `52 45 7E 5E` | Detection only |
| RAR 1.5-4.x | `52 61 72 21 1A 07 00` | Parse + validate + extract (store) |
| RAR5+ | `52 61 72 21 1A 07 01 00` | Parse + validate + extract (m0-m5) + create (m0-m5) |

## Validation Depth

rarz validates archives to the deepest level possible:

- **Signature** — recognized RAR magic bytes (with SFX prefix scanning)
- **Structural** — all header checksums (CRC16 for RAR4, CRC32 for RAR5) pass
- **Full** — structural + payload integrity (CRC32 data verification for store-method files)

## Implementation provenance

Clean-room development is the project's intended constraint. Historical
specifications include reference-source evaluation, and the PPMd implementation
is documented as a reference decoder port. The repository therefore does not
currently substantiate a specification-only implementation claim. See the
[provenance review](docs/PROVENANCE_REVIEW_20261028.md) for the evidence and
unresolved remediation decision.

## License

[MIT](LICENSE)
