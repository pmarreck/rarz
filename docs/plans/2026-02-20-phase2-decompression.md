# Phase 2: Decompression Engine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add full RAR decompression support (all algorithm generations: v15/v20/v29/v50/v70) so rarz can extract and validate compressed archives, plus fix Phase 1 cleanup items.

**Architecture:** Decompression modules live in `src/lib/decompress/`. Each generation has its own file. Shared primitives (BitReader, Huffman, LZ window) are factored out. The decompression entry point is a `decompress(packed_data, unpacked_size, algo_version, method, dict_bits, ...) -> []u8` function that dispatches by algorithm version. This hooks into `rarz_extract_to_buffer` (replacing the method!=0 rejection) and `policy.validate` (enabling full-depth validation for compressed files).

**Tech Stack:** Zig 0.15.x, no external dependencies. All decompression is pure computation on byte slices — no I/O.

**Spec references:**
- `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` — behavioral spec derived from unRAR 7.2.4
- `RAR_SPECIFICATION.md` — format-level header/block spec

**Test strategy:** Each module gets inline Zig tests with known input/output vectors. Integration tests use official `rar`-compressed fixtures validated against `unrar` output. TDD: write failing test first, implement, verify.

---

## Phase 2A: Cleanup & Foundation

### Task 1: Fix RAR4 block iterator for >4GB files

**Problem:** `BlockHeader.data_size` is `?u32` (line 57 of `src/lib/rar4_headers.zig`). The `BlockIterator.next()` (line 245) uses this 32-bit value to advance past blocks. For files with the `large` flag (`LHD_LARGE`, 0x0100), the actual packed size is 64-bit (low 32 from data_size + high 32 from an extra field). The iterator only skips the low 32 bits, causing misalignment for files >4GB.

**Files:**
- Modify: `src/lib/rar4_headers.zig` — Change `BlockHeader.data_size` from `?u32` to `?u64`. Update `parse_block_header` to read the high 32 bits when `LHD_LARGE` is set. Alternatively, compute the full 64-bit data advancement from the file header's `packed_size` field.

**Approach:** The cleanest fix is to make `BlockHeader.data_size` a `?u64` and have `parse_block_header` combine the low and high words when the LONG_BLOCK flag is present AND the header type is FILE (0x74) with the `large` flag set. For non-file blocks with LONG_BLOCK, the existing u32 read is correct (just widen it).

**Tests:**
- Construct a synthetic RAR4 archive with a file header claiming >4GB packed_size (using LHD_LARGE flag)
- Verify the block iterator correctly skips past the full 64-bit data region
- Verify subsequent blocks are still parseable after the large file

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Fix RAR4 block iterator advancement for >4GB files"`

---

### Task 2: Remove 64-file stack allocation limit in FFI archive creation

**Problem:** `rarz_calculate_archive_size` and `rarz_create_archive` in `src/lib/root.zig` (lines ~315-360) use `var writer_entries_buf: [64]writer.FileEntry = undefined` and return -1 if count > 64. The writer module supports up to 65535 files.

**Files:**
- Modify: `src/lib/root.zig` — Use the handle's allocator (or page_allocator) to heap-allocate the conversion buffer when count > 64. Free it before returning.

**Tests:**
- Test creating an archive with >64 files through the FFI (use 65 tiny entries)
- Verify the archive is valid by opening it with `rarz_open`

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Remove 64-file stack limit in FFI archive creation"`

---

### Task 3: Expose SFX detection through FFI

**Problem:** `rarz_detect_format` always passes `max_sfx_offset=0`, meaning SFX archives are never detected through the FFI. The underlying `detect.detect_format` supports SFX scanning.

**Files:**
- Modify: `src/lib/root.zig` — Add `rarz_detect_format_sfx(data, len, max_sfx_offset)` export
- Modify: `include/rarz.h` — Add the new function declaration

**Tests:**
- Build a synthetic SFX archive (garbage prefix + RAR5 signature)
- Verify `rarz_detect_format` returns 0 (no SFX scan)
- Verify `rarz_detect_format_sfx` with appropriate max_offset returns 50

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add rarz_detect_format_sfx for SFX archive detection"`

---

### Task 4: Migrate from page_allocator to arena allocator

**Problem:** `rarz_open` uses `std.heap.page_allocator` which wastes memory (minimum 4KB per allocation). The design spec calls for "arena allocator per parse operation."

**Files:**
- Modify: `src/lib/root.zig` — Replace `page_allocator` with an `ArenaAllocator` backed by `page_allocator`. Store the arena in the handle. On `rarz_close`, deinit the arena (frees everything at once).

**Approach:**
```zig
const ArchiveHandle = struct {
    data: []const u8,
    family: detect.RarFamily,
    block_data_offset: usize,
    rar4_files: ?[]rar4_headers.FileHeader,
    rar5_files: ?[]rar5_headers.FileBlock,
    arena: std.heap.ArenaAllocator,
    // remove allocator field — use arena.allocator() instead
};
```

In `rarz_open`: create `ArenaAllocator.init(std.heap.page_allocator)`, use `arena.allocator()` for all allocations. In `deinit`: call `arena.deinit()` instead of individual frees.

**Note:** The handle itself must be allocated from `page_allocator` (not the arena, since the arena is inside the handle). Use `page_allocator.create(ArchiveHandle)` for the handle, then `arena.allocator()` for file lists.

**Tests:**
- Existing tests should all pass unchanged (allocation strategy is an implementation detail)
- Add a test that opens and closes an archive 1000 times to verify no memory leaks

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Migrate ArchiveHandle to arena allocator"`

---

### Task 5: Add BLAKE2sp payload verification for RAR5 files

**Problem:** RAR5 files can have BLAKE2sp hashes in extra record type 0x02. Currently `policy.validate` only checks CRC32 for store-method files. The `integrity.blake2sp` function exists but isn't wired into validation.

**Files:**
- Modify: `src/lib/rar5_headers.zig` — Add constants for extra record types (`EXTRA_FILE_HASH = 0x02`). Add a helper to extract BLAKE2sp hash from extra records.
- Modify: `src/lib/policy.zig` — In `validate_rar5_payload`, after CRC32 check, also check BLAKE2sp hash if available in extra records.

**Approach:**
1. In `rar5_headers.zig`, add:
   ```zig
   pub const EXTRA_FILE_HASH: u64 = 0x02;
   pub const HASH_TYPE_BLAKE2SP: u64 = 0x00;
   ```
2. Add a function `extract_blake2sp_hash(extra_data: []const u8) -> ?[32]u8` that parses the extra area looking for type 0x02, then reads the hash type vint (must be 0x00 for BLAKE2sp) and the 32-byte hash value.
3. In `policy.zig`'s `validate_rar5_payload`, after successful CRC32 check, also call `extract_blake2sp_hash` on the file's extra_data and verify with `integrity.blake2sp`.

**Tests:**
- Create a RAR5 archive with `rar -htb` (BLAKE2sp hash type) and verify `rarz` validates it at full depth
- Construct a synthetic file block with BLAKE2sp extra record and verify the hash extraction
- Corrupt the payload and verify BLAKE2sp mismatch is detected

**Run:** `nix develop -c zig build test` then `nix develop -c bash tests/cli/test_integration.sh`

**Commit:** `git commit -m "Add BLAKE2sp payload verification for RAR5 files"`

---

## Phase 2B: Decompression Infrastructure

### Task 6: BitReader for compressed streams

**Files:**
- Create: `src/lib/decompress/bitreader.zig`

**Purpose:** Compressed RAR data is a bitstream. All decompression algorithms need to read individual bits and multi-bit fields from a byte stream. This is distinct from `reader.zig` which reads bytes/vints from headers.

**Interface:**
```zig
pub const BitReader = struct {
    data: []const u8,
    bit_pos: usize,  // current bit position in the stream

    pub fn init(data: []const u8) BitReader;

    /// Read `n` bits (1-32) as a u32, MSB first.
    pub fn read_bits(self: *BitReader, n: u5) error{EndOfData}!u32;

    /// Peek at the next `n` bits without advancing.
    pub fn peek_bits(self: *BitReader, n: u5) error{EndOfData}!u32;

    /// Advance past `n` bits.
    pub fn skip_bits(self: *BitReader, n: u5) void;

    /// Read a single bit.
    pub fn read_bit(self: *BitReader) error{EndOfData}!u1;

    /// Current byte-aligned position (for block boundary checks).
    pub fn byte_position(self: *BitReader) usize;

    /// Remaining bits available.
    pub fn remaining_bits(self: *BitReader) usize;

    /// Align to next byte boundary (skip padding bits).
    pub fn align_byte(self: *BitReader) void;
};
```

**Tests:**
- Read individual bits from known bytes: `0xA5` = `10100101` → bits are 1,0,1,0,0,1,0,1
- Read multi-bit fields: 5 bits from `0xFF` = `11111` = 31
- Read across byte boundaries: 12 bits spanning 2 bytes
- Peek doesn't advance position
- EndOfData at end of stream
- Round-trip: write bits manually, read them back

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add BitReader for compressed stream decoding"`

---

### Task 7: Canonical Huffman decoder

**Files:**
- Create: `src/lib/decompress/huffman.zig`

**Purpose:** All RAR generations (v20/v29/v50) use canonical Huffman coding. `MakeDecodeTables` builds a decode table from code-length arrays. `DecodeNumber` resolves symbols using quick-lookup and fallback paths. This is shared infrastructure.

**Interface:**
```zig
pub const MAX_CODE_LENGTH = 15;
pub const QUICK_BITS = 10;  // quick-path lookup table bits

pub const DecodeTable = struct {
    /// Quick-path decode: table[peek_bits(QUICK_BITS)] -> symbol + length
    quick_table: [1 << QUICK_BITS]QuickEntry,
    /// Full decode data for codes longer than QUICK_BITS
    decode_len: [MAX_CODE_LENGTH + 1]u32,   // cumulative counts per length
    decode_pos: [MAX_CODE_LENGTH + 1]u32,   // starting position per length
    decode_num: []u16,                       // symbol numbers sorted by code
    max_num: u16,                            // number of symbols

    pub const QuickEntry = packed struct {
        symbol: u16,
        length: u4,  // 0 means need full decode
    };
};

/// Build decode tables from an array of code lengths.
/// code_lengths[i] = number of bits for symbol i. 0 means not present.
pub fn make_decode_tables(
    code_lengths: []const u8,
    max_num: u16,
    allocator: std.mem.Allocator,
) !DecodeTable;

/// Decode one symbol from the bitstream using the given table.
pub fn decode_number(
    br: *BitReader,
    table: *const DecodeTable,
) !u16;
```

**Algorithmic reference:** `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` section 8.1.

**Tests:**
- Build table from known code lengths (e.g., 3 symbols with lengths [1, 2, 2])
- Decode a known bitstream and verify correct symbol sequence
- Quick-path decode for short codes (< QUICK_BITS)
- Full-path decode for long codes (> QUICK_BITS)
- Empty table (all zero code lengths) → error
- Single-symbol table → always returns that symbol

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add canonical Huffman decoder with quick-path lookup"`

---

### Task 8: LZ window buffer and match-copy primitive

**Files:**
- Create: `src/lib/decompress/lz.zig`

**Purpose:** All RAR decoders output into a circular LZ window buffer. The `CopyString` operation copies `length` bytes from `distance` bytes back in the window. Must handle overlap (distance < length), wrap-around, and invalid distances (zero-fill for corruption hardening).

**Interface:**
```zig
pub const Window = struct {
    buffer: []u8,          // circular buffer (power-of-2 size)
    mask: usize,           // buffer.len - 1 (for fast modulo)
    write_pos: usize,      // current write position
    total_written: u64,    // total bytes written (for tracking progress)

    pub fn init(allocator: std.mem.Allocator, dict_bits: u5) !Window;
    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void;

    /// Write a literal byte to the window.
    pub fn put_byte(self: *Window, byte: u8) void;

    /// Copy `length` bytes from `distance` bytes back.
    /// Handles overlap (distance < length) correctly via byte-by-byte copy.
    /// If distance > total_written (invalid), zero-fills for corruption hardening.
    pub fn copy_match(self: *Window, distance: usize, length: usize) void;

    /// Get a slice of the last `n` bytes written (for filter application).
    /// Returns up to 2 slices (for wrap-around).
    pub fn last_bytes(self: *Window, n: usize) struct { first: []const u8, second: []const u8 };

    /// Flush `n` bytes from the window to an output buffer.
    /// Returns bytes written to output.
    pub fn flush(self: *Window, output: []u8, n: usize) usize;
};
```

**Algorithmic reference:** `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` section 8.2.

**Tests:**
- put_byte writes to correct position and advances
- copy_match with distance > length (no overlap) — verify correct bytes copied
- copy_match with distance < length (overlap/RLE pattern) — e.g., distance=1, length=10 replicates a single byte
- copy_match with distance=0 (invalid) → zero-fill
- copy_match wrapping around the circular buffer
- flush extracts correct bytes in order

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add LZ window buffer with match-copy and corruption hardening"`

---

## Phase 2C: RAR5/7 Decoder (most common modern archives)

### Task 9: RAR5 compressed block reader and table loading

**Files:**
- Create: `src/lib/decompress/unpack50.zig`

**Purpose:** RAR5 compressed streams are chunked into blocks. Each block has a header with flags, optional new Huffman tables, and a last-block marker. This task implements the block-level framing and Huffman table loading for v50/v70.

**Key data structures:**
```zig
pub const Unpack50State = struct {
    br: BitReader,
    window: Window,
    // Huffman tables
    ld: DecodeTable,    // literals + main slots (306 symbols for RAR5, 326 for RAR7)
    dd: DecodeTable,    // distances (DCB=64 for RAR5, DCX=80 for RAR7)
    ldd: DecodeTable,   // low distance bits (16 symbols)
    rd: DecodeTable,    // repeat lengths (44 symbols)
    // State
    prev_distances: [4]u32,  // last 4 distances for repeat matches
    last_length: u32,
    is_rar7: bool,
    allocator: std.mem.Allocator,
};

/// Read block header: flags (1 bit table-present, 1 bit last-block),
/// optional checksum, block size, then optional Huffman tables.
pub fn read_block_header(state: *Unpack50State) !BlockInfo;

/// Load Huffman tables from the bitstream.
/// Reads code-length Huffman first (20 symbols), then uses it to decode
/// the code lengths for LD, DD, LDD, RD tables.
pub fn read_tables(state: *Unpack50State) !void;
```

**Algorithmic reference:** `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` sections 7.1 and 7.2.

**RAR5 vs RAR7:** The only difference is distance alphabet size. RAR5: `DCB=64`, RAR7: `DCX=80`. Set by `is_rar7` flag (UnpVer==70 → true). Main alphabet: RAR5=256+6+DCB=326 isn't right... let me recalculate. Actually the main alphabet size is `306` for RAR5 (256 literals + 6 control + 44 length slots) — the distance is a separate table.

**Tests:**
- Construct a minimal RAR5 compressed block with known Huffman tables
- Verify table loading produces correct decode tables
- Verify block header parsing (table-present flag, last-block flag)
- Test with RAR7 extended distance alphabet

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add RAR5/7 compressed block reader and Huffman table loading"`

---

### Task 10: RAR5/7 main decoder loop

**Files:**
- Modify: `src/lib/decompress/unpack50.zig`

**Purpose:** Implement the main decoding loop that reads Huffman-coded symbols and dispatches to literal, match, filter, or repeat operations.

**Symbol classes (from spec section 7.3):**
- `<256`: literal byte → `window.put_byte(symbol)`
- `256`: filter descriptor (Task 11)
- `257`: repeat last length at most recent distance
- `258..261`: prior-distance repeat with new length from RD table
- `>=262`: new match — length slot → extra bits → length; distance slot → extra bits → distance; optional low dist bits from LDD table

**Interface:**
```zig
/// Decompress a RAR5/7 compressed stream.
/// packed_data: raw compressed payload bytes
/// unpacked_size: expected output size
/// algo_version: 50 or 70
/// method: 1-5 (compression level, affects nothing in decode — only table encoding differs)
/// dict_bits/dict_frac_bits: dictionary size parameters from CompressionInfo
/// solid: if true, window state carries over from previous file (not supported initially — return error)
/// Returns decompressed data (caller-owned, allocated from allocator).
pub fn decompress(
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    algo_version: u6,
    dict_bits: u4,
    dict_frac_bits: u4,
    solid: bool,
) ![]u8;
```

**Tests:**
- Create a RAR5 archive with `rar -m1` (fast compression), extract with `unrar`, save the expected output
- Feed the compressed payload to `decompress()` and verify output matches
- Test with multiple blocks (large file that exceeds one block)
- Test with each distance-repeat type (257-261)

**CRITICAL INTEROP TEST:** Create real compressed archives with the official `rar` tool, decompress with our engine, and verify byte-for-byte match against `unrar` output.

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Implement RAR5/7 main decoder loop with LZ matches"`

---

### Task 11: RAR5 filter subsystem

**Files:**
- Create: `src/lib/decompress/filters.zig`
- Modify: `src/lib/decompress/unpack50.zig` — Wire filter application into the decode loop

**Purpose:** RAR5 uses 4 post-processing filter types applied to decoded output regions:
- `FILTER_DELTA` (0): Delta encoding (multi-channel byte differences)
- `FILTER_E8` (1): x86 CALL instruction address translation
- `FILTER_E8E9` (2): x86 CALL+JMP address translation
- `FILTER_ARM` (3): ARM branch instruction address translation

**Algorithmic reference:** `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` section 7.4.

**Interface:**
```zig
pub const FilterType = enum(u3) {
    delta = 0,
    e8 = 1,
    e8e9 = 2,
    arm = 3,
};

pub const Filter = struct {
    filter_type: FilterType,
    block_start: usize,
    block_length: usize,
    channels: u8,  // for delta filter
};

/// Apply a filter to a data region in-place.
pub fn apply_filter(data: []u8, filter: Filter, file_offset: u64) void;
```

**Tests:**
- Delta filter round-trip: encode then decode
- E8 filter: known x86 binary with CALL instructions
- ARM filter: known ARM binary with branch instructions
- Create RAR5 archives with `rar` from binary files (which trigger E8/E8E9 filters) and verify decompression

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add RAR5 filter subsystem (Delta, E8, E8E9, ARM)"`

---

## Phase 2D: Wire Decompression Into Extraction + Validation

### Task 12: Integrate decompression into FFI and validation

**Files:**
- Create: `src/lib/decompress/dispatch.zig` — Top-level dispatch by UnpVer/algo_version
- Modify: `src/lib/root.zig` — Replace method!=0 rejection with decompression call
- Modify: `src/lib/policy.zig` — Enable full-depth validation for compressed files
- Modify: `include/rarz.h` — Update comments, add error codes
- Modify: `src/cli/main.c` — No changes needed (extraction already calls `rarz_extract_to_buffer`)

**Dispatch interface:**
```zig
// src/lib/decompress/dispatch.zig
pub fn decompress(
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    family: detect.RarFamily,
    // RAR5 params
    algo_version: ?u6,
    dict_bits: ?u4,
    dict_frac_bits: ?u4,
    solid: ?bool,
    // RAR4 params
    unpack_version: ?u8,
    method: u8,
) ![]u8 {
    if (method == 0) unreachable; // store is handled by caller
    return switch (family) {
        .rar50 => unpack50.decompress(allocator, packed_data, unpacked_size, algo_version.?, dict_bits.?, dict_frac_bits.?, solid.?),
        .rar15 => switch (unpack_version.?) {
            15 => unpack15.decompress(...),
            20, 26 => unpack20.decompress(...),
            29 => unpack29.decompress(...),
            else => error.UnsupportedVersion,
        },
        .rar14 => unpack15.decompress(...), // RAR 1.4 uses v15 decoder
    };
}
```

**Changes to `rarz_extract_to_buffer`:**
```zig
// Instead of: if (f.compression.method != 0) return -1;
if (f.compression.method != 0) {
    // Decompress
    const packed_data = a.data[header_end .. header_end + data_size];
    const decompressed = decompress.decompress(
        a.arena.allocator(), packed_data, f.unpacked_size,
        .rar50, f.compression.algo_version, ...
    ) catch return -3; // new error code: decompression failed
    if (decompressed.len > out_len) return -2;
    @memcpy(buf[0..decompressed.len], decompressed);
    return @intCast(decompressed.len);
}
```

**Changes to `policy.validate`:**
- Remove the `method == 0` guard in payload validation
- For compressed files, decompress then verify CRC32/BLAKE2sp of the decompressed output
- On decompression failure, return `is_valid=false, depth=.full, error_message="decompression failed"`

**New FFI error codes:**
- `-3`: decompression failed (corrupt data or unsupported algorithm)
- `-4`: unsupported compression version

**Tests:**
- Create RAR5 compressed archive with `rar`, extract via `rarz_extract_to_buffer`, verify matches `unrar` output
- Validate a compressed archive reaches `depth=full`
- Extract a compressed archive via CLI `rarz x` and diff against `unrar x` output
- Test error codes for unsupported versions

**Run:** `nix develop -c zig build test` then all CLI tests

**Commit:** `git commit -m "Wire RAR5 decompression into extraction and validation"`

---

## Phase 2E: RAR3 Decoder

### Task 13: RAR3 LZ branch (v29)

**Files:**
- Create: `src/lib/decompress/unpack29.zig`

**Purpose:** RAR3 is dual-mode per block (LZ or PPM). This task implements the LZ branch only. PPM comes in Task 14.

**Token classes (from spec section 6.2):**
- `<256`: literal byte
- `256`: end-of-block control (switch tables or end file)
- `257`: VM filter command (Task 16)
- `258`: repeat last match
- `259..262`: old-distance repeat with new length
- `263..271`: short-distance 2-byte matches
- `>=272`: full length/distance matches

**Huffman tables:** Same structure as v50 but different alphabet sizes:
- Main/literal (MC): 299 symbols (256 + 13 control + 28 length + 2 special)
- Distance (DC): 60 symbols
- Low-distance (LDC): 17 symbols
- Repeat-length (RC): 28 symbols

**Key difference from v50:** RAR3 uses `ReadTables30` which reads a block mode bit first. If bit==0, load LZ Huffman tables. If bit==1, switch to PPM mode.

**Tests:**
- Create RAR3-era compressed archive (need older `rar` version or construct synthetically)
- Since our nix flake has `rar 7.20` which only creates RAR5, we'll need to create test vectors by:
  1. Constructing synthetic compressed blocks manually
  2. Using known RAR3 archives from test corpora
- Verify LZ-only decompression for simple patterns

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add RAR3 LZ branch decoder (v29)"`

---

### Task 14: PPMd model and range coder

**Files:**
- Create: `src/lib/decompress/ppm.zig`

**Purpose:** RAR3's PPM branch uses PPMd (public-domain variant) for statistical compression. This requires a range coder (arithmetic decoder) and the PPMd context model.

**Key components:**
1. **Range coder**: Arithmetic decoder reading from bitstream. Core operations: `decode(scale)`, `get_current_count(scale)`, `remove_sub_range(low, high, scale)`.
2. **PPMd context model**: Hierarchical character prediction with order-N contexts. Context structs, state arrays, frequency tables.
3. **SubAllocator**: Unit-list memory allocator for PPMd nodes (can use arena allocator).

**Algorithmic reference:** `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` section 6.6. PPMd is based on Dmitry Shkarin's public-domain algorithm.

**Interface:**
```zig
pub const PpmModel = struct {
    range_coder: RangeCoder,
    // ... context model state
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_order: u8, mem_size: u32) !PpmModel;
    pub fn deinit(self: *PpmModel) void;

    /// Decode one symbol from the PPM model.
    pub fn decode_symbol(self: *PpmModel) !PpmSymbol;
};

pub const PpmSymbol = union(enum) {
    literal: u8,         // regular byte
    end_of_block: void,  // switch back to table reading
    end_of_file: void,   // done
    vm_code: void,       // VM filter follows
    lz_match: struct { distance: u32, length: u32 },
    rle_byte: struct { byte: u8, distance: u8 },
    escaped_escape: u8,  // literal escape byte
};
```

**Tests:**
- Range coder decode with known probability tables
- PPMd model init/deinit without leaks
- Decode a known PPMd-compressed sequence
- Full round-trip against known RAR3 PPMd-compressed data

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add PPMd model and range coder for RAR3 PPM branch"`

---

### Task 15: RAR3 PPM integration and block switching

**Files:**
- Modify: `src/lib/decompress/unpack29.zig` — Add PPM mode support, block mode switching

**Purpose:** Connect the PPMd model to the v29 decoder. RAR3 can switch between LZ and PPM modes at block boundaries. The decoder reads a mode bit at each table-load point and dispatches accordingly.

**PPM symbol handling (from spec section 6.3):**
- `PPM symbol → escape(0)`: end of PPM block → read new tables (might switch to LZ)
- `PPM symbol → escape(1)`: literal escape byte
- `PPM symbol → escape(2)`: end-of-file
- `PPM symbol → escape(3)`: VM code block follows
- `PPM symbol → escape(4)`: embedded LZ match in PPM stream
- `PPM symbol → escape(5)`: one-byte-distance RLE

**Tests:**
- Decode data that switches between LZ and PPM modes
- Handle PPM escape sequences correctly
- Test corruption fallback (PPM error → clean state, switch to LZ)

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Integrate PPM mode into RAR3 decoder with block switching"`

---

### Task 16: RAR3 VM filter subsystem (standard filters only)

**Files:**
- Modify: `src/lib/decompress/filters.zig` — Add RAR3 standard filter recognition
- Modify: `src/lib/decompress/unpack29.zig` — Wire filter application

**Purpose:** RAR3 has a VM-based filter system, but in practice only 6 standard filters are used. Instead of implementing the full RARVM, recognize standard filters by their `(code_length, CRC32)` signatures and implement them natively.

**Standard filters (from spec section 6.5):**
- E8 (x86 CALL)
- E8E9 (x86 CALL+JMP)
- Itanium (IA-64 branch)
- RGB (color channel delta)
- Audio (audio sample delta prediction)
- Delta (generic multi-channel delta)

**Approach:** When a VM filter block is read (`ReadVMCode`), compute the CRC32 of the bytecode and match against known standard filter CRCs. If matched, apply the native implementation. If not matched, return an error (we don't implement the full RARVM — it's a security risk and extremely rare in practice).

**Tests:**
- Recognize each standard filter by CRC
- Apply RGB filter to known pixel data
- Apply Audio filter to known sample data
- Real RAR3 archive with filters → decompress and verify

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add RAR3 standard VM filter recognition (E8, E8E9, Itanium, RGB, Audio, Delta)"`

---

## Phase 2F: Legacy Decoders

### Task 17: RAR 2.x decoder (v20) with audio mode

**Files:**
- Create: `src/lib/decompress/unpack20.zig`
- Modify: `src/lib/decompress/dispatch.zig` — Add v20/v26 dispatch

**Purpose:** RAR 2.x uses multi-table Huffman + LZ with an optional audio predictor mode.

**Key components (from spec section 5):**
- 4 Huffman tables: LD (main), DD (distance), RD (repeat length), MD[] (audio per-channel)
- Main symbol classes: `<256` literal, `>269` new match, `269` table refresh, `256` repeat, `257..260` old-distance, `261..269` short 2-byte match
- Audio mode: When `UnpAudioBlock` set, symbols are audio residuals decoded via adaptive linear predictor with K1..K5 coefficients

**v26 variant:** Same as v20 but with 64-bit file size support (>2GB). No algorithmic change.

**Tests:**
- Synthetic v20 compressed data
- Audio mode predictor verification
- If available, real RAR 2.x archives from test corpora

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add RAR 2.x decoder (v20/v26) with audio mode"`

---

### Task 18: RAR 1.5 decoder (v15)

**Files:**
- Create: `src/lib/decompress/unpack15.zig`
- Modify: `src/lib/decompress/dispatch.zig` — Add v15 dispatch

**Purpose:** RAR 1.5 uses adaptive Huffman coding with flag buffers and moving averages. This is the oldest algorithm and uses a fundamentally different approach from later versions.

**Key components (from spec section 4):**
- Three token modes: `HuffDecode` (literals), `LongLZ` (long matches), `ShortLZ` (short/repeat matches)
- Flag buffer (`FlagBuf`, `FlagsCnt`) drives branch preference
- Moving averages (`Nhfb`, `Nlzb`, `Avr*`) for model adaptation
- Four adaptive symbol sets (`ChSet`, `ChSetA`, `ChSetB`, `ChSetC`) with placement arrays and periodic correction (`CorrHuff`)

**Tests:**
- Synthetic v15 compressed data with known flag sequences
- If available, real RAR 1.5 archives
- Verify the "ACHIEVEMENT UNLOCKED: Ancient Data Format" path works end-to-end

**Run:** `nix develop -c zig build test`

**Commit:** `git commit -m "Add RAR 1.5 decoder (v15) — ACHIEVEMENT UNLOCKED: Ancient Data Format"`

---

## Phase 2G: Final Integration

### Task 19: Full interop gates + PLAN.md update

**Files:**
- Modify: `tests/generate_fixtures.sh` — Add compressed fixture variants
- Create: `tests/cli/test_decompress.sh` — Comprehensive decompression integration tests
- Modify: `PLAN.md` — Check off Phase 2 and Phase 3 items
- Modify: `CODE_MINIMAP.md` — Add decompress/ module descriptions

**Tests:**
1. **Interop Gate A (compressed):** Create RAR5 archives at compression levels 1-5 with `rar`, extract with `rarz x`, diff against `unrar x` output → must match byte-for-byte
2. **Interop Gate B (round-trip):** Create store archive with `rarz a`, verify `unrar t` passes (already exists, re-verify)
3. **Validation depth for compressed:** `rarz t` on compressed archives should report success (full-depth validation with CRC32 + BLAKE2sp after decompression)
4. **Corruption detection (compressed):** Mutate compressed payload bytes, verify `rarz t` rejects (decompression failure or CRC mismatch)
5. **Multi-file compressed archives:** Verify correct extraction of all files from multi-file compressed archives
6. **Large file handling:** Test with files >1MB to exercise multi-block decompression

**Run:** All test suites

**Commit:** `git commit -m "Add compressed archive interop tests and update documentation"`

---

## Dependency Graph

```
Task 1 (RAR4 iterator fix)  ──────┐
Task 2 (64-file limit)      ──────┤
Task 3 (SFX FFI)            ──────┤── Independent cleanup (can parallelize)
Task 4 (Arena allocator)     ──────┤
Task 5 (BLAKE2sp)            ──────┘

Task 6 (BitReader)           ──┐
Task 7 (Huffman)             ──┼── Decompression infrastructure (sequential)
Task 8 (LZ Window)           ──┘
                                │
Task 9 (v50 block reader)   ───┤── Depends on Tasks 6-8
Task 10 (v50 decoder loop)  ───┤── Depends on Task 9
Task 11 (RAR5 filters)      ───┘── Depends on Task 10

Task 12 (Wire into FFI)     ───── Depends on Tasks 4, 10, 11

Task 13 (v29 LZ branch)     ───┐── Depends on Tasks 6-8
Task 14 (PPMd + range coder) ──┤── Independent of v50
Task 15 (v29 PPM integration)──┤── Depends on Tasks 13, 14
Task 16 (v29 VM filters)    ───┘── Depends on Task 15

Task 17 (v20 decoder)       ───── Depends on Tasks 6-8
Task 18 (v15 decoder)       ───── Depends on Tasks 6-8

Task 19 (Final integration)  ──── Depends on ALL above
```

## Parallelization Opportunities

- Tasks 1-5 are independent and can all run in parallel
- Tasks 6, 7, 8 are infrastructure and should be sequential (each builds on prior)
- Tasks 9-11 (v50) are sequential
- Tasks 13-16 (v29) are sequential but independent of v50 (can start after Task 8)
- Tasks 17, 18 (legacy) are independent of each other and of v50/v29 (only need Task 8)
- Task 12 (wiring) should happen after v50 is done, then updated again as v29/v20/v15 land
- Task 19 waits for everything
