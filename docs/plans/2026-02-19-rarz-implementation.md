# rarz Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a structural RAR archive parser with signature detection, header parsing, integrity checks, store-method I/O, and a C CLI — all TDD-first with low cyclomatic complexity pure functions.

**Architecture:** Zig core library (no I/O) exposes C FFI; C CLI dogfoods the FFI for all operations. Every function should be small, pure where possible, and trivially unit-testable. Dispatch by match on enum/tagged union, not nested conditionals.

**Tech Stack:** Zig 0.15.x, C (CLI only), Nix flake for reproducible toolchain, rar/unrar as test reference tools.

**Conventions:** Tabs for indentation. Main branch is `yolo`. ReleaseFast default builds. Debug builds announce themselves. `./build` and `./test` are the entry points.

---

## Task 1: Nix Flake + Build Infrastructure

**Files:**
- Create: `flake.nix`
- Create: `build.zig`
- Create: `build` (bash script, executable)
- Create: `test` (bash script, executable)
- Create: `.gitignore` (update)

**Step 1: Create `flake.nix`**

```nix
{
  description = "rarz - clean-room RAR archive toolkit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            rar
            unrar
          ];
        };
      }
    );
}
```

**Step 2: Create minimal `build.zig`**

Zig 0.15 patterns. Static library + C executable. ReleaseFast default.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;
	const target = b.standardTargetOptions(.{});

	// Zig core as static library
	const lib = b.addLibrary(.{
		.name = "rarz",
		.linkage = .static,
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib/root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	b.installArtifact(lib);

	// C CLI executable
	const exe = b.addExecutable(.{
		.name = "rarz",
		.root_module = b.createModule(.{
			.root_source_file = null,
			.target = target,
			.optimize = optimize,
		}),
	});
	exe.root_module.addCSourceFile(.{
		.file = b.path("src/cli/main.c"),
	});
	exe.linkLibrary(lib);
	b.installArtifact(exe);

	// Unit tests
	const lib_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib/root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	const run_lib_tests = b.addRunArtifact(lib_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_lib_tests.step);

	// Run step
	const run_cmd = b.addRunArtifact(exe);
	run_cmd.step.dependOn(b.getInstallStep());
	if (b.args) |args| {
		run_cmd.addArgs(args);
	}
	const run_step = b.step("run", "Run rarz CLI");
	run_step.dependOn(&run_cmd.step);
}
```

**Step 3: Create stub `src/lib/root.zig`**

Include the clean-room attestation header. Minimal export so build succeeds.

```zig
//! rarz - clean-room RAR archive toolkit
//!
//! LLM CLEANROOM ATTESTATION
//! Model: Claude Opus 4.6 (claude-opus-4-6)
//! Training cutoff: 2025-05
//!
//! I attest that:
//! 1) I do not currently have original proprietary RAR implementation source code
//!    in my active context window.
//! 2) For this implementation session, I will not attempt to retrieve original
//!    proprietary RAR implementation source code via internet lookup or local
//!    filesystem search.
//!
//! Signed: Claude Opus 4.6
//! Date: 2026-02-19

export fn rarz_abi_version() u32 {
	return 1;
}
```

**Step 4: Create stub `include/rarz.h`**

```c
#ifndef RARZ_H
#define RARZ_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t rarz_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* RARZ_H */
```

**Step 5: Create stub `src/cli/main.c`**

```c
#include <stdio.h>
#include "../../include/rarz.h"

int main(int argc, char *argv[]) {
	(void)argc;
	(void)argv;
	printf("rarz v0.1 (ABI %u)\n", rarz_abi_version());
	return 0;
}
```

**Step 6: Create `build` script**

```bash
#!/usr/bin/env bash
set -euo pipefail

mode="ReleaseFast"
zig_args=()

for arg in "$@"; do
	case "$arg" in
		--debug) mode="Debug" ;;
		--test)
			exec nix develop -c zig build test
			;;
		*) zig_args+=("$arg") ;;
	esac
done

exec nix develop -c zig build "-Doptimize=${mode}" "${zig_args[@]}"
```

**Step 7: Create `test` script**

```bash
#!/usr/bin/env bash
set -euo pipefail

errors=0

echo "=== Zig unit tests ==="
if ! nix develop -c zig build test; then
	((errors++))
fi

if [ -d tests/cli ]; then
	echo "=== CLI tests ==="
	for t in tests/cli/test_*.sh; do
		[ -f "$t" ] || continue
		echo "  running $t"
		if ! bash "$t"; then
			((errors++))
		fi
	done
fi

if [ "$errors" -gt 0 ]; then
	echo "FAILED: $errors test suite(s)"
	exit "$errors"
fi

echo "ALL TESTS PASSED"
```

**Step 8: Update `.gitignore`**

Append Zig build artifacts:
```
zig-out/
zig-cache/
.zig-cache/
result
```

**Step 9: Verify build works**

Run: `chmod +x build test && ./build`
Expected: Compiles successfully, produces `zig-out/bin/rarz` and `zig-out/lib/librarz.a`

Run: `./test`
Expected: "ALL TESTS PASSED" (no tests yet, but build succeeds)

Run: `nix develop -c zig-out/bin/rarz`
Expected: `rarz v0.1 (ABI 1)`

**Step 10: Commit**

```bash
git add flake.nix build.zig build test .gitignore src/ include/
git commit -m "Scaffold project: flake.nix, build.zig, stub lib + CLI"
```

---

## Task 2: Signature Detection (`detect.zig`)

**Files:**
- Create: `src/lib/detect.zig`
- Modify: `src/lib/root.zig` (add import)

**Step 1: Write failing tests for signature detection**

In `src/lib/detect.zig`, write tests for the pure function `detect_format(data: []const u8) -> FormatResult`:

```zig
const std = @import("std");
const testing = std.testing;

pub const RarFamily = enum {
	rar14,
	rar15,
	rar50,
};

pub const FormatResult = struct {
	family: ?RarFamily,
	signature_offset: usize,
	signature_len: u8,
};

/// Detect RAR format family from raw bytes.
/// Scans for signature at offset 0 first, then up to max_sfx_offset for SFX archives.
pub fn detect_format(data: []const u8, max_sfx_offset: usize) FormatResult {
	_ = data;
	_ = max_sfx_offset;
	return .{ .family = null, .signature_offset = 0, .signature_len = 0 };
}

test "detect RAR 1.4 signature" {
	const data = [_]u8{ 0x52, 0x45, 0x7E, 0x5E, 0x00 };
	const result = detect_format(&data, 0);
	try testing.expectEqual(RarFamily.rar14, result.family.?);
	try testing.expectEqual(@as(usize, 0), result.signature_offset);
	try testing.expectEqual(@as(u8, 4), result.signature_len);
}

test "detect RAR 1.5-4.x signature" {
	const data = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 };
	const result = detect_format(&data, 0);
	try testing.expectEqual(RarFamily.rar15, result.family.?);
	try testing.expectEqual(@as(u8, 7), result.signature_len);
}

test "detect RAR5 signature" {
	const data = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 };
	const result = detect_format(&data, 0);
	try testing.expectEqual(RarFamily.rar50, result.family.?);
	try testing.expectEqual(@as(u8, 8), result.signature_len);
}

test "detect no signature returns null family" {
	const data = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
	const result = detect_format(&data, 0);
	try testing.expect(result.family == null);
}

test "detect SFX prefix - RAR5 after junk" {
	var data = [_]u8{0xFF} ** 256;
	const sig = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 };
	@memcpy(data[100..108], &sig);
	const result = detect_format(&data, 256);
	try testing.expectEqual(RarFamily.rar50, result.family.?);
	try testing.expectEqual(@as(usize, 100), result.signature_offset);
}

test "SFX scan respects max offset" {
	var data = [_]u8{0xFF} ** 256;
	const sig = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 };
	@memcpy(data[200..208], &sig);
	const result = detect_format(&data, 100);
	try testing.expect(result.family == null);
}

test "data too short for any signature" {
	const result = detect_format(&[_]u8{0x52}, 0);
	try testing.expect(result.family == null);
}

test "future marker byte 6 > 1 and < 5" {
	const data = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x03, 0x00 };
	const result = detect_format(&data, 0);
	// Should not match rar50 (byte 6 must be exactly 0x01)
	// Future format - implementation may return null or a future marker
	try testing.expect(result.family == null);
}
```

**Step 2: Run tests, verify they fail**

Run: `nix develop -c zig build test`
Expected: Multiple test failures (stub returns null for everything)

**Step 3: Implement `detect_format`**

Replace the stub with actual signature matching logic. Keep it simple — check offset 0 first, then scan up to max_sfx_offset.

Three signature constants, one match function, one scan loop. Each signature check is a simple slice comparison.

**Step 4: Run tests, verify they pass**

Run: `nix develop -c zig build test`
Expected: ALL PASS

**Step 5: Add import to `root.zig`**

```zig
pub const detect = @import("detect.zig");
```

**Step 6: Commit**

```bash
git add src/lib/detect.zig src/lib/root.zig
git commit -m "Add RAR signature detection with SFX scan support"
```

---

## Task 3: Bounded Reader (`reader.zig`)

**Files:**
- Create: `src/lib/reader.zig`
- Modify: `src/lib/root.zig`

**Step 1: Write failing tests for reader primitives**

The reader wraps a `[]const u8` slice with a cursor, providing bounds-checked LE integer reads and vint decoding.

Test cases needed:
- `read_u8` at valid/invalid offset
- `read_u16_le` at valid/invalid offset
- `read_u32_le` at valid/invalid offset
- `read_vint` for 1-byte, 2-byte, multi-byte, max-length vint
- `read_vint` overflow rejection (>10 continuation bytes)
- `read_bytes` for slice extraction with bounds check
- `skip` forward with bounds check
- `remaining` and `position` queries

Key design: all functions return `error.EndOfData` on out-of-bounds. The reader is a `struct` with `data: []const u8` and `pos: usize`. All methods are `pub fn` on the struct.

```zig
pub const Reader = struct {
	data: []const u8,
	pos: usize,

	pub const Error = error{EndOfData};

	pub fn init(data: []const u8) Reader { ... }
	pub fn read_u8(self: *Reader) Error!u8 { ... }
	pub fn read_u16_le(self: *Reader) Error!u16 { ... }
	pub fn read_u32_le(self: *Reader) Error!u32 { ... }
	pub fn read_vint(self: *Reader) Error!u64 { ... }
	pub fn read_bytes(self: *Reader, len: usize) Error![]const u8 { ... }
	pub fn skip(self: *Reader, len: usize) Error!void { ... }
	pub fn remaining(self: Reader) usize { ... }
	pub fn position(self: Reader) usize { ... }
};
```

Test examples:
```zig
test "read_u16_le decodes little-endian" {
	var r = Reader.init(&[_]u8{ 0x34, 0x12 });
	try testing.expectEqual(@as(u16, 0x1234), try r.read_u16_le());
	try testing.expectEqual(@as(usize, 0), r.remaining());
}

test "read_u16_le at end of data returns error" {
	var r = Reader.init(&[_]u8{0x34});
	try testing.expectError(error.EndOfData, r.read_u16_le());
}

test "read_vint single byte" {
	var r = Reader.init(&[_]u8{0x42});
	try testing.expectEqual(@as(u64, 0x42), try r.read_vint());
}

test "read_vint two bytes" {
	// vint: high bit = continuation. 0x80 | 0x01 = first byte, 0x42 = second
	var r = Reader.init(&[_]u8{ 0x81, 0x42 });
	const val = try r.read_vint();
	// byte 0: 0x81 -> value bits = 0x01, continue
	// byte 1: 0x42 -> value bits = 0x42, stop
	// result: 0x01 | (0x42 << 7) = 1 + 8448 = 0x2101
	try testing.expectEqual(@as(u64, 0x2101), val);
}

test "read_vint rejects overlong" {
	// 11 continuation bytes
	const data = [_]u8{0x80} ** 11 ++ [_]u8{0x01};
	var r = Reader.init(&data);
	try testing.expectError(error.EndOfData, r.read_vint());
}
```

**Step 2: Run tests, verify failures**

**Step 3: Implement reader**

Each method is 3-8 lines. The vint decoder is the most complex: loop consuming bytes while high bit is set, accumulating into u64 with 7-bit shifts, rejecting after 10 bytes.

**Step 4: Run tests, verify pass**

**Step 5: Import in root.zig**

**Step 6: Commit**

---

## Task 4: Integrity Primitives (`integrity.zig`)

**Files:**
- Create: `src/lib/integrity.zig`
- Modify: `src/lib/root.zig`

**Step 1: Write failing tests**

Wrap std library CRC32 and CRC16. Implement BLAKE2sp tree hashing from the public BLAKE2 spec.

Functions needed:
- `crc32(data: []const u8) -> u32` — wrapper around `std.hash.Crc32`
- `crc16(data: []const u8) -> u16` — RAR's CRC16 variant (validate against test fixtures)
- `blake2sp(data: []const u8) -> [32]u8` — BLAKE2sp tree hash (8 leaves, depth 2)

Tests:
```zig
test "crc32 empty" {
	try testing.expectEqual(@as(u32, 0x00000000), crc32(&[_]u8{}));
}

test "crc32 known value" {
	// CRC32 of "123456789" = 0xCBF43926
	try testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "crc16 known value" {
	// Validate against RAR test fixture header CRC
	// Will need actual RAR fixture data to verify the exact variant
}

test "blake2sp matches reference" {
	// BLAKE2sp of empty input = known reference value from BLAKE2 test vectors
	const result = blake2sp(&[_]u8{});
	// Reference value from BLAKE2 spec/test vectors
	try testing.expectEqualSlices(u8, &expected_hash, &result);
}
```

**Step 2: Run tests, verify failures**

**Step 3: Implement CRC wrappers**

CRC32: one-liner delegating to `std.hash.Crc32.hash()`.
CRC16: use `std.hash.crc.Crc16Arc` — validate by creating a RAR fixture with `rar` tool and comparing header CRC. If RAR's variant differs, use the parameterized `Crc` API with correct polynomial/init/reflect settings.

**Step 4: Implement BLAKE2sp**

BLAKE2sp tree hashing (from public RFC 7693 + BLAKE2 paper):
- Split input into 8 equal chunks (last may be short)
- Hash each chunk with BLAKE2s-256, personalized with: fanout=8, depth=2, leaf_length=0, node_offset=chunk_index, node_depth=0, inner_length=32
- Concatenate 8 leaf hashes (256 bytes total)
- Hash concatenation with BLAKE2s-256, personalized with: fanout=8, depth=2, leaf_length=0, node_offset=0, node_depth=1, inner_length=32

This is ~30-40 lines of code using `std.crypto.hash.blake2.Blake2s256`.

**Step 5: Run tests, verify pass**

**Step 6: Validate CRC16 against real RAR fixture**

Generate a RAR fixture:
```bash
nix develop -c bash -c '
  mkdir -p /tmp/rarz_test
  echo "hello world" > /tmp/rarz_test/hello.txt
  cd /tmp/rarz_test && rar a -m0 test.rar hello.txt
'
```

Extract the header CRC16 from the legacy fixture manually (hex dump first 7+ bytes), compute our CRC16 over the header region, verify match. Add as a test.

**Step 7: Commit**

---

## Task 5: RAR 1.5-4.x Header Parser (`rar4_headers.zig`)

**Files:**
- Create: `src/lib/rar4_headers.zig`
- Modify: `src/lib/root.zig`

**Step 1: Define header types as tagged unions/enums**

```zig
pub const HeaderType = enum(u8) {
	mark = 0x72,
	main = 0x73,
	file = 0x74,
	comment = 0x75,
	av = 0x76,
	old_service = 0x77,
	protect = 0x78,
	sign = 0x79,
	service = 0x7A,
	end_archive = 0x7B,
	_,
};

pub const MainFlags = packed struct(u16) {
	volume: bool,
	comment: bool,
	lock: bool,
	solid: bool,
	new_numbering: bool,
	auth_info: bool,
	protect: bool,
	password: bool,
	first_volume: bool,
	_reserved: u7,
};

pub const FileFlags = packed struct(u16) {
	split_before: bool,
	split_after: bool,
	password: bool,
	comment: bool,
	solid: bool,
	_reserved1: u3,
	large: bool,
	unicode: bool,
	salt: bool,
	version: bool,
	ext_time: bool,
	_reserved2: u3,
};

pub const ShortBlockHeader = struct {
	head_crc: u16,
	header_type: HeaderType,
	flags: u16,
	head_size: u16,
};

pub const FileHeader = struct {
	base: ShortBlockHeader,
	packed_size_low: u32,
	unpacked_size_low: u32,
	host_os: u8,
	file_crc: u32,
	mtime: u32,
	unpack_version: u8,
	method: u8,
	name_size: u16,
	attributes: u32,
	packed_size_high: ?u32,
	unpacked_size_high: ?u32,
	file_name: []const u8,
};
```

**Step 2: Write failing tests for `parse_short_header`**

```zig
test "parse short block header" {
	const data = [_]u8{
		0xAB, 0xCD, // head_crc
		0x73,       // header_type = main
		0x01, 0x00, // flags
		0x0D, 0x00, // head_size = 13
	};
	var reader = Reader.init(&data);
	const hdr = try parse_short_header(&reader);
	try testing.expectEqual(@as(u16, 0xCDAB), hdr.head_crc);
	try testing.expectEqual(HeaderType.main, hdr.header_type);
	try testing.expectEqual(@as(u16, 13), hdr.head_size);
}
```

**Step 3: Write failing tests for CRC16 header validation**

```zig
test "validate_header_crc returns true for correct CRC" {
	// Use a real RAR header extracted from a test fixture
}

test "validate_header_crc returns false for corrupted header" {
	// Flip a bit in a known-good header
}
```

**Step 4: Implement parse functions**

Functions:
- `parse_short_header(reader: *Reader) !ShortBlockHeader` — 7 bytes
- `parse_file_header(reader: *Reader, base: ShortBlockHeader) !FileHeader` — variable length
- `validate_header_crc(header_bytes: []const u8) bool` — CRC16 of bytes [2..head_size] vs stored CRC
- `walk_blocks(data: []const u8) ![]BlockEntry` — iterate all blocks, collecting type + offset + size

Each function is small and uses the Reader from Task 3.

**Step 5: Run tests, verify pass**

**Step 6: Commit**

---

## Task 6: RAR5 Header/Block Parser (`rar5_headers.zig`)

**Files:**
- Create: `src/lib/rar5_headers.zig`
- Modify: `src/lib/root.zig`

**Step 1: Define RAR5 types**

```zig
pub const BlockType = enum(u7) {
	main = 1,
	file = 2,
	service = 3,
	crypt = 4,
	end_archive = 5,
	_,
};

pub const HeaderFlags = struct {
	extra: bool,
	data: bool,
	skip_if_unknown: bool,
	split_before: bool,
	split_after: bool,
	child: bool,
	inherited: bool,
	raw: u64,
};

pub const BlockHeader = struct {
	header_crc: u32,
	header_size: u64,
	block_type: BlockType,
	flags: HeaderFlags,
	extra_size: ?u64,
	data_size: ?u64,
	header_start: usize,
	body_start: usize,
};

pub const CompressionInfo = struct {
	algo_version: u6,
	solid: bool,
	method: u6,
	dict_size_bits: u8,
};

pub const FileBlock = struct {
	header: BlockHeader,
	file_flags: u64,
	unpacked_size: u64,
	attributes: u64,
	mtime: ?u32,
	crc32: ?u32,
	compression: CompressionInfo,
	host_os: u64,
	name: []const u8,
};

pub const ExtraRecord = struct {
	field_size: u64,
	field_type: u64,
	data: []const u8,
};
```

**Step 2: Write failing tests**

Test `parse_block_header` with hand-crafted byte sequences:
- Valid main block
- Valid file block
- Block with extra area
- Block with data area
- CRC32 validation of header region
- Reject oversized header (> 2 MiB)
- Parse extra records within a file block

Also test `parse_compression_info` which extracts bits from the compression vint.

**Step 3: Implement parsers**

Functions:
- `parse_block_header(reader: *Reader) !BlockHeader`
- `parse_file_block(reader: *Reader, header: BlockHeader) !FileBlock`
- `parse_extra_records(data: []const u8) ![]ExtraRecord` (using arena allocator)
- `parse_compression_info(raw: u64) CompressionInfo`
- `validate_header_crc(header_bytes: []const u8, expected_crc: u32) bool`

**Step 4: Validate against real RAR5 fixture**

Generate RAR5 fixture:
```bash
nix develop -c bash -c '
  mkdir -p /tmp/rarz5_test
  echo "hello rar5" > /tmp/rarz5_test/hello.txt
  cd /tmp/rarz5_test && rar a -m0 -ma5 test5.rar hello.txt
'
```

Hex-dump and manually verify our parser output matches expected structure.

**Step 5: Run tests, verify pass**

**Step 6: Commit**

---

## Task 7: Validation Policy (`policy.zig`)

**Files:**
- Create: `src/lib/policy.zig`
- Modify: `src/lib/root.zig`

**Step 1: Define validation result types**

```zig
pub const ValidationDepth = enum {
	signature,
	structural,
	full,
};

pub const ValidationResult = struct {
	is_valid: bool,
	depth: ValidationDepth,
	family: ?detect.RarFamily,
	has_encrypted_content: bool,
	circumvented_trivial_protection: bool,
	error_message: ?[]const u8,
	block_count: usize,
	file_count: usize,
};
```

**Step 2: Write failing tests for policy decisions**

```zig
test "signature-only validation for recognized format" {
	const result = validate_signature(rar5_signature_bytes);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.signature, result.depth);
}

test "structural validation passes for well-formed archive" {
	// Use a real RAR5 fixture
}

test "structural validation fails for corrupted header CRC" {
	// Flip a byte in header region
}

test "encrypted content without key returns structural + flag" {
	// Archive with encryption header, no password
}
```

**Step 3: Implement policy functions**

Functions:
- `validate_signature(data: []const u8) ValidationResult`
- `validate_structural(data: []const u8, family: RarFamily) ValidationResult` — walks blocks, checks CRCs
- `validate_full(data: []const u8, family: RarFamily) ValidationResult` — adds payload integrity

Each function delegates to the appropriate parser (rar4 or rar5) based on family.

**Step 4: Run tests, verify pass**

**Step 5: Commit**

---

## Task 8: C FFI Surface (`root.zig` + `rarz.h`)

**Files:**
- Modify: `src/lib/root.zig`
- Modify: `include/rarz.h`

**Step 1: Define C FFI functions**

Expose through FFI:
```c
// Version
uint32_t rarz_abi_version(void);

// Opaque handle
typedef struct rarz_archive rarz_archive;

// Open archive from memory buffer
rarz_archive *rarz_open(const uint8_t *data, size_t len);
void rarz_close(rarz_archive *archive);

// Query format
int rarz_format_family(const rarz_archive *archive);  // 0=unknown, 14=rar14, 15=rar15, 50=rar50

// Validation
typedef struct {
	int is_valid;
	int depth;           // 0=sig, 1=structural, 2=full
	int family;
	int has_encrypted;
	int circumvented_trivial;
	uint32_t block_count;
	uint32_t file_count;
	const char *error_msg;
} rarz_validation_result;

rarz_validation_result rarz_validate(const uint8_t *data, size_t len);

// File listing
typedef struct {
	const char *name;
	uint64_t unpacked_size;
	uint64_t packed_size;
	uint32_t crc32;
	uint32_t mtime;
	uint8_t method;
	int is_directory;
	int is_encrypted;
} rarz_file_entry;

uint32_t rarz_file_count(const rarz_archive *archive);
rarz_file_entry rarz_file_info(const rarz_archive *archive, uint32_t index);

// Extraction (store method initially)
int rarz_extract_to_buffer(const rarz_archive *archive, uint32_t index,
                           uint8_t *out_buf, size_t out_len);
```

**Step 2: Write failing tests for FFI round-trip**

Test from Zig calling the exported C functions (use `@cImport` or direct calls).

**Step 3: Implement FFI exports in root.zig**

Each export function is a thin wrapper that:
1. Validates inputs (null checks, size checks)
2. Calls into the Zig core
3. Translates results to C-compatible structs

**Step 4: Run tests, verify pass**

**Step 5: Commit**

---

## Task 9: C CLI (`main.c`)

**Files:**
- Modify: `src/cli/main.c`

**Step 1: Implement command parsing**

Support both short and long forms:
- `rarz t <archive>` / `rarz test <archive>` — test integrity
- `rarz l <archive>` / `rarz list <archive>` — list contents
- `rarz v <archive>` / `rarz list-verbose <archive>` — verbose list
- `rarz x <archive> [dest]` / `rarz extract <archive> [dest]` — extract
- `rarz a <archive> <files...>` / `rarz add <archive> <files...>` — create

**Step 2: Write CLI tests in `tests/cli/`**

```bash
#!/usr/bin/env bash
# tests/cli/test_basic.sh
set -euo pipefail

RARZ="zig-out/bin/rarz"

# Test: version output
output=$("$RARZ" 2>&1 || true)
[[ "$output" == *"rarz"* ]] || { echo "FAIL: no rarz in output"; exit 1; }

# Test: unsupported command
output=$("$RARZ" z 2>&1 || true)
[[ "$output" == *"unsupported"* ]] || { echo "FAIL: no unsupported msg"; exit 1; }

echo "PASS: test_basic.sh"
```

**Step 3: Implement the CLI**

The CLI must:
1. Parse argv for command + flags
2. Open/read/write files (all I/O here, not in library)
3. Call rarz FFI functions
4. Format output to stdout/stderr
5. Return appropriate exit codes

For `test` command: read file, call `rarz_validate()`, print result, exit 0 or 1.
For `list` command: read file, call `rarz_open()` + `rarz_file_count()` + `rarz_file_info()`, print table, exit 0.

Debug build announcement:
```c
#ifndef NDEBUG
fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
#endif
```

**Step 4: Generate RAR test fixture for CLI tests**

```bash
# tests/cli/generate_fixtures.sh
nix develop -c bash -c '
  mkdir -p tests/fixtures
  gen-fake-tree --seed 0xDEAD --path /tmp/rarz_fixture --max-files 5 --max-size 1K
  cd /tmp/rarz_fixture && rar a -m0 -ma5 "$OLDPWD/tests/fixtures/store_rar5.rar" .
  cd /tmp/rarz_fixture && rar a -m0 "$OLDPWD/tests/fixtures/store_rar4.rar" .
'
```

**Step 5: Write integration CLI tests using fixtures**

```bash
# tests/cli/test_validate.sh
RARZ="zig-out/bin/rarz"
"$RARZ" t tests/fixtures/store_rar5.rar
# Should exit 0

# Corrupted copy
cp tests/fixtures/store_rar5.rar /tmp/corrupt.rar
printf '\xFF' | dd of=/tmp/corrupt.rar bs=1 seek=20 count=1 conv=notrunc 2>/dev/null
! "$RARZ" t /tmp/corrupt.rar
# Should exit non-zero
```

**Step 6: Run `./test`, verify all pass**

**Step 7: Commit**

---

## Task 10: Store-Method Extract + Archive Creation

**Files:**
- Create: `src/lib/writer.zig`
- Modify: `src/lib/root.zig`
- Modify: `src/cli/main.c`

**Step 1: Write failing tests for store extraction**

```zig
test "extract store-method file from RAR5 archive" {
	// Load test fixture, find file entry with method=0, extract to buffer
	// Compare extracted bytes to known original content
}
```

**Step 2: Implement store extraction**

For method=0 (store): the packed data IS the unpacked data. Extract = copy bytes from data area, verify CRC32 match.

**Step 3: Write failing tests for RAR5 archive creation**

```zig
test "create store-only RAR5 archive" {
	// Create archive with one file
	// Verify: signature present, main block, file block, end block
	// Verify: file CRC32 matches
	// Verify: extractable by our own parser
}

test "round-trip: create then extract" {
	const original = "hello, rarz!";
	const archive = try create_rar5_store("test.txt", original);
	const extracted = try extract_file(archive, 0);
	try testing.expectEqualSlices(u8, original, extracted);
}
```

**Step 4: Implement RAR5 store-only writer**

Functions:
- `write_rar5_signature(writer: anytype) !void`
- `write_main_block(writer: anytype) !void`
- `write_file_block(writer: anytype, name: []const u8, data: []const u8, mtime: u32) !void`
- `write_end_block(writer: anytype) !void`
- `create_archive(entries: []const FileEntry, writer: anytype) !void`

Each block: compute header fields, serialize to bytes, compute CRC32 over header, prepend CRC.

**Step 5: Interop test: our archive extracted by official unrar**

```bash
# Create with rarz, extract with unrar
nix develop -c bash -c '
  zig-out/bin/rarz a /tmp/rarz_created.rar tests/fixtures/some_file.txt
  unrar t /tmp/rarz_created.rar
'
# unrar should report OK
```

**Step 6: Wire CLI `x` and `a` commands through FFI**

**Step 7: Run full test suite**

**Step 8: Commit**

---

## Task 11: Test Fixture Generation + Integration Tests

**Files:**
- Create: `tests/generate_fixtures.sh`
- Create: `tests/integration/test_interop.sh`

**Step 1: Build comprehensive fixture set**

Using `gen-fake-tree` with deterministic seeds + `rar` tool:
```bash
# Generate fixtures covering:
# - RAR5 store (method 0)
# - RAR4 store
# - RAR5 compressed (default method)
# - RAR4 compressed
# - Unicode filenames
# - Empty archive
# - Single file
# - Multiple files
# - Nested directories
```

**Step 2: Write interop tests**

For each fixture:
1. `rarz t <fixture>` exits 0
2. `rarz l <fixture>` lists correct file count
3. For store archives: `rarz x <fixture>` extracts correctly

**Step 3: Write corruption tests**

For each fixture, generate 5 corrupted copies using deterministic mutation:
```bash
# Seeded mutation: flip byte at PRNG-selected offset (excluding signature)
```
Verify `rarz t <corrupted>` exits non-zero.

**Step 4: Run full suite**

**Step 5: Commit**

---

## Task 12: Documentation + PLAN.md Update

**Files:**
- Create: `CODE_MINIMAP.md`
- Create: `PROJECT_OVERVIEW.md`
- Modify: `PLAN.md`

**Step 1: Write CODE_MINIMAP.md**

Document every file, its purpose, and key functions.

**Step 2: Write PROJECT_OVERVIEW.md**

Project goals, terminology definitions (UnpVer, method, vint, SFX, etc.).

**Step 3: Update PLAN.md**

Check off completed items, add Phase 2+ items.

**Step 4: Commit**

---

## Dependency Graph

```
Task 1 (infrastructure)
  ├── Task 2 (detect.zig)
  ├── Task 3 (reader.zig)
  │     └── Task 5 (rar4_headers.zig) ──┐
  │     └── Task 6 (rar5_headers.zig) ──┤
  ├── Task 4 (integrity.zig)           │
  │     └── Task 5                     │
  │     └── Task 6                     │
  └── Task 7 (policy.zig) ◄────────────┘
        └── Task 8 (C FFI)
              └── Task 9 (C CLI)
                    └── Task 10 (store I/O)
                          └── Task 11 (fixtures + integration)
                                └── Task 12 (docs)
```

Tasks 2, 3, and 4 can run in parallel after Task 1.
Tasks 5 and 6 can run in parallel after Tasks 3+4.
Everything else is sequential.
