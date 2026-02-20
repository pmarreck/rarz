const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;

pub const MAX_CODE_LENGTH: u5 = 15;
pub const QUICK_BITS: u5 = 10;
pub const QUICK_TABLE_SIZE: usize = 1 << QUICK_BITS; // 1024

pub const DecodeTable = struct {
    /// Quick-path: table[peek_bits(QUICK_BITS)] -> symbol + length
    /// If length == 0, need full decode path
    quick_table: [QUICK_TABLE_SIZE]QuickEntry = [_]QuickEntry{.{}} ** QUICK_TABLE_SIZE,

    /// First canonical code of each bit length (1-indexed, [0] unused).
    /// decode_len[n] = first code of length n.
    /// decode_len[MAX_CODE_LENGTH + 1] is a sentinel used for bounds checking.
    decode_len: [MAX_CODE_LENGTH + 2]u32 = [_]u32{0} ** (MAX_CODE_LENGTH + 2),

    /// Starting positions in decode_num for codes of each length.
    /// decode_pos[n] = index into decode_num where symbols of length n begin.
    decode_pos: [MAX_CODE_LENGTH + 2]u32 = [_]u32{0} ** (MAX_CODE_LENGTH + 2),

    /// Symbol numbers sorted by canonical code order.
    decode_num: []u16 = &.{},

    /// Number of symbols in the alphabet.
    max_num: u16 = 0,

    /// Was this table successfully built?
    valid: bool = false,

    pub const QuickEntry = struct {
        symbol: u16 = 0,
        length: u5 = 0, // 0 means need full decode
    };
};

/// Build canonical Huffman decode tables from code-length array.
/// code_lengths[i] = number of bits for symbol i (0 means not present).
/// Allocates decode_num from the provided allocator.
pub fn makeDecodeTables(
    code_lengths: []const u8,
    allocator: std.mem.Allocator,
) !DecodeTable {
    var table = DecodeTable{};
    table.max_num = @intCast(code_lengths.len);

    // Step 1: Count codes of each length
    var len_count = [_]u32{0} ** (MAX_CODE_LENGTH + 2);
    for (code_lengths) |cl| {
        if (cl > 0 and cl <= MAX_CODE_LENGTH) {
            len_count[cl] += 1;
        }
    }

    // Step 2: Compute starting canonical code for each length.
    // The canonical Huffman assignment: code[L] = (code[L-1] + count[L-1]) << 1
    // Also build decode_pos as cumulative symbol positions.
    var code: u32 = 0;
    var total_symbols: u32 = 0;
    for (1..MAX_CODE_LENGTH + 1) |len| {
        code = (code + len_count[len - 1]) << 1;
        table.decode_len[len] = code;
        table.decode_pos[len] = total_symbols;
        total_symbols += len_count[len];
    }
    // Sentinel: one past the last valid code at max length
    table.decode_len[MAX_CODE_LENGTH + 1] = code + len_count[MAX_CODE_LENGTH];
    table.decode_pos[MAX_CODE_LENGTH + 1] = total_symbols;

    if (total_symbols == 0) {
        table.valid = false;
        return table;
    }

    // Step 3: Allocate and fill decode_num (symbols sorted by canonical code order).
    // Within each code length, symbols appear in order of their symbol number.
    table.decode_num = try allocator.alloc(u16, total_symbols);
    var pos_tracker = [_]u32{0} ** (MAX_CODE_LENGTH + 2);
    for (1..MAX_CODE_LENGTH + 1) |len| {
        pos_tracker[len] = table.decode_pos[len];
    }
    for (code_lengths, 0..) |cl, i| {
        if (cl > 0 and cl <= MAX_CODE_LENGTH) {
            table.decode_num[pos_tracker[cl]] = @intCast(i);
            pos_tracker[cl] += 1;
        }
    }

    // Step 4: Build quick-path lookup table for codes <= QUICK_BITS long.
    // For each possible QUICK_BITS-wide value, find the shortest code that matches.
    for (0..QUICK_TABLE_SIZE) |quick_val| {
        for (1..QUICK_BITS + 1) |len| {
            const shift: u5 = @intCast(QUICK_BITS - len);
            const test_code: u32 = @intCast(quick_val >> shift);
            const first_code = table.decode_len[len];
            const count = len_count[len];
            if (count > 0 and test_code >= first_code and test_code < first_code + count) {
                const sym_idx = table.decode_pos[len] + (test_code - first_code);
                if (sym_idx < total_symbols) {
                    table.quick_table[quick_val] = .{
                        .symbol = table.decode_num[sym_idx],
                        .length = @intCast(len),
                    };
                    break;
                }
            }
        }
    }

    table.valid = true;
    return table;
}

/// Decode one symbol from the bitstream using the given table.
/// Uses a quick-path lookup for short codes (up to QUICK_BITS),
/// falling back to a bit-by-bit full-path decode for longer codes.
pub fn decodeNumber(br: *BitReader, table: *const DecodeTable) !u16 {
    if (!table.valid) return error.InvalidTable;

    const bits_available = br.remainingBits();
    if (bits_available == 0) return error.EndOfData;

    // Quick path: peek QUICK_BITS and look up in quick table
    const peek_count: u5 = if (bits_available >= QUICK_BITS) QUICK_BITS else @intCast(bits_available);
    const peeked = try br.peekBits(peek_count);

    // Pad to QUICK_BITS width if we could not peek the full amount
    const quick_val: u32 = if (peek_count < QUICK_BITS)
        peeked << @intCast(QUICK_BITS - peek_count)
    else
        peeked;

    const quick = table.quick_table[@intCast(quick_val)];
    if (quick.length > 0 and quick.length <= peek_count) {
        br.skipBits(quick.length);
        return quick.symbol;
    }

    // Full path: read bits one at a time from the start of the current code.
    // Save position so we read from the beginning of this symbol's code.
    const saved_pos = br.bit_pos;
    var accumulated_code: u32 = 0;

    for (1..MAX_CODE_LENGTH + 1) |len| {
        if (br.remainingBits() == 0) break;
        const bit = try br.readBits(1);
        accumulated_code = (accumulated_code << 1) | bit;

        const first_code = table.decode_len[len];
        // Number of symbols with this code length
        const num_symbols_at_len = table.decode_pos[len + 1] - table.decode_pos[len];

        if (num_symbols_at_len > 0 and accumulated_code >= first_code and
            accumulated_code < first_code + num_symbols_at_len)
        {
            const sym_idx = table.decode_pos[len] + (accumulated_code - first_code);
            return table.decode_num[sym_idx];
        }
    }

    // No valid code found -- restore position and report error
    br.bit_pos = saved_pos;
    return error.InvalidCode;
}

/// Free the decode table's allocated memory.
pub fn freeDecodeTable(table: *DecodeTable, allocator: std.mem.Allocator) void {
    if (table.decode_num.len > 0) {
        allocator.free(table.decode_num);
        table.decode_num = &.{};
    }
    table.valid = false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "empty table (all zero lengths) returns valid=false" {
    const code_lengths = [_]u8{ 0, 0, 0, 0 };
    const table = try makeDecodeTables(&code_lengths, testing.allocator);
    // No allocation to free since total_symbols == 0
    try testing.expect(!table.valid);
}

test "build table from [1, 2, 2] gives codes A=0, B=10, C=11" {
    // Symbol 0: length 1 -> code 0
    // Symbol 1: length 2 -> code 10
    // Symbol 2: length 2 -> code 11
    const code_lengths = [_]u8{ 1, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    try testing.expect(table.valid);
    try testing.expectEqual(@as(u16, 3), table.max_num);

    // Verify decode_num ordering: symbol 0 (len 1), then symbols 1,2 (len 2)
    try testing.expectEqual(@as(usize, 3), table.decode_num.len);
    try testing.expectEqual(@as(u16, 0), table.decode_num[0]); // len=1: symbol 0
    try testing.expectEqual(@as(u16, 1), table.decode_num[1]); // len=2: symbol 1
    try testing.expectEqual(@as(u16, 2), table.decode_num[2]); // len=2: symbol 2

    // Verify first codes: length 1 -> code 0, length 2 -> code 2 (= (0+1)<<1 = 2)
    try testing.expectEqual(@as(u32, 0), table.decode_len[1]);
    try testing.expectEqual(@as(u32, 2), table.decode_len[2]);
}

test "build table from [2, 2, 2, 2] gives codes 00, 01, 10, 11" {
    const code_lengths = [_]u8{ 2, 2, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    try testing.expect(table.valid);
    try testing.expectEqual(@as(usize, 4), table.decode_num.len);

    // All codes are length 2. First code of length 2 = (0+0)<<1 = 0
    try testing.expectEqual(@as(u32, 0), table.decode_len[2]);

    // Symbols in order: 0, 1, 2, 3
    try testing.expectEqual(@as(u16, 0), table.decode_num[0]);
    try testing.expectEqual(@as(u16, 1), table.decode_num[1]);
    try testing.expectEqual(@as(u16, 2), table.decode_num[2]);
    try testing.expectEqual(@as(u16, 3), table.decode_num[3]);
}

test "single-symbol table" {
    // Only symbol 0 has code length 1 -> code is just "0" (or "1"?)
    // With canonical Huffman: first code of length 1 = (0+0)<<1 = 0
    // So code is 0b0
    const code_lengths = [_]u8{1};
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    try testing.expect(table.valid);
    try testing.expectEqual(@as(usize, 1), table.decode_num.len);
    try testing.expectEqual(@as(u16, 0), table.decode_num[0]);
}

test "quick-path decode for short codes: [1, 2, 2]" {
    // Codes: A=0, B=10, C=11
    // Bitstream: 0 10 11 0 = A B C A
    // Binary: 0 10 11 0 = 01011_0 -> pad to full byte: 01011000 = 0x58
    const code_lengths = [_]u8{ 1, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    const data = [_]u8{0x58};
    var br = BitReader.init(&data);

    // All these codes are <= QUICK_BITS, so quick path should handle them
    try testing.expectEqual(@as(u16, 0), try decodeNumber(&br, &table)); // A (code 0, 1 bit)
    try testing.expectEqual(@as(u16, 1), try decodeNumber(&br, &table)); // B (code 10, 2 bits)
    try testing.expectEqual(@as(u16, 2), try decodeNumber(&br, &table)); // C (code 11, 2 bits)
    try testing.expectEqual(@as(u16, 0), try decodeNumber(&br, &table)); // A (code 0, 1 bit)
}

test "quick-path decode for [2, 2, 2, 2]" {
    // Codes: 0=00, 1=01, 2=10, 3=11
    // Bitstream: 00 01 10 11 = 0x1B
    const code_lengths = [_]u8{ 2, 2, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    const data = [_]u8{0x1B};
    var br = BitReader.init(&data);

    try testing.expectEqual(@as(u16, 0), try decodeNumber(&br, &table)); // 00
    try testing.expectEqual(@as(u16, 1), try decodeNumber(&br, &table)); // 01
    try testing.expectEqual(@as(u16, 2), try decodeNumber(&br, &table)); // 10
    try testing.expectEqual(@as(u16, 3), try decodeNumber(&br, &table)); // 11
}

test "full-path decode for long codes (>10 bits)" {
    // Build a table with a mix of short and long codes.
    // Use lengths that create a code longer than QUICK_BITS (10).
    // With 5 symbols: lengths [1, 2, 3, 11, 11]
    // Canonical codes:
    //   len 1: first_code = 0 -> sym 0 = 0b0
    //   len 2: first_code = (0+1)<<1 = 2 -> sym 1 = 0b10
    //   len 3: first_code = (2+1)<<1 = 6 -> sym 2 = 0b110
    //   len 4-10: no codes, but code keeps shifting
    //   len 4: (6+1)<<1 = 14
    //   len 5: 14<<1 = 28
    //   len 6: 28<<1 = 56
    //   len 7: 56<<1 = 112
    //   len 8: 112<<1 = 224
    //   len 9: 224<<1 = 448
    //   len 10: 448<<1 = 896
    //   len 11: 896<<1 = 1792 -> sym 3 = 1792, sym 4 = 1793
    //
    // 1792 in 11 bits = 0b11100000000
    // 1793 in 11 bits = 0b11100000001

    const code_lengths = [_]u8{ 1, 2, 3, 11, 11 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    try testing.expect(table.valid);

    // Encode symbol 3 (code 1792 = 0b11100000000, 11 bits)
    // then symbol 4 (code 1793 = 0b11100000001, 11 bits)
    // Total: 22 bits -> 3 bytes needed
    // 11100000000 11100000001 00
    // 1110 0000 | 0001 1100 | 0000 0100
    // = 0xE0, 0x1C, 0x04
    const data = [_]u8{ 0xE0, 0x1C, 0x04 };
    var br = BitReader.init(&data);

    // These codes are 11 bits, which exceeds QUICK_BITS (10), so the full path is used
    try testing.expectEqual(@as(u16, 3), try decodeNumber(&br, &table));
    try testing.expectEqual(@as(u16, 4), try decodeNumber(&br, &table));
}

test "mixed quick-path and full-path decodes" {
    // Same table as above: lengths [1, 2, 3, 11, 11]
    // Sequence: sym 0, sym 3, sym 2, sym 4
    // Codes: 0 (1 bit), 11100000000 (11 bits), 110 (3 bits), 11100000001 (11 bits)
    // Total: 26 bits -> 4 bytes needed (padded with zeros)
    //
    // Bitstream: 0 11100000000 110 11100000001 000000
    // = 0_1110000 | 0000_110_1 | 11000000 | 01_000000
    // = 0111 0000 | 0000 1101 | 1100 0000 | 0100 0000
    // = 0x70, 0x0D, 0xC0, 0x40
    const code_lengths = [_]u8{ 1, 2, 3, 11, 11 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    const data = [_]u8{ 0x70, 0x0D, 0xC0, 0x40 };
    var br = BitReader.init(&data);

    try testing.expectEqual(@as(u16, 0), try decodeNumber(&br, &table)); // quick path
    try testing.expectEqual(@as(u16, 3), try decodeNumber(&br, &table)); // full path
    try testing.expectEqual(@as(u16, 2), try decodeNumber(&br, &table)); // quick path
    try testing.expectEqual(@as(u16, 4), try decodeNumber(&br, &table)); // full path
}

test "single-symbol decode always returns that symbol" {
    // Only symbol 0 with code length 1, code = 0
    const code_lengths = [_]u8{1};
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    // Data: 0x00 = 00000000 -> eight 0-bits, each should decode as symbol 0
    const data = [_]u8{0x00};
    var br = BitReader.init(&data);

    for (0..8) |_| {
        try testing.expectEqual(@as(u16, 0), try decodeNumber(&br, &table));
    }
}

test "round-trip: manually encode, then decode to verify correct symbols" {
    // Table: [3, 3, 3, 3, 3, 2, 2, 2]
    // len 2: count=3 (symbols 5,6,7). first_code = (0+0)<<1 = 0
    //   sym 5 = 00, sym 6 = 01, sym 7 = 10
    // len 3: count=5 (symbols 0,1,2,3,4). first_code = (0+3)<<1 = 6
    //   sym 0 = 110, sym 1 = 111, sym 2 = 1000... wait, that's 4 bits
    //
    // Let me recalculate carefully:
    // len 1: count=0, first_code = 0
    // len 2: count=3 (syms 5,6,7), first_code = (0+0)<<1 = 0
    //   sym 5 = 00, sym 6 = 01, sym 7 = 10
    // len 3: count=5 (syms 0,1,2,3,4), first_code = (0+3)<<1 = 6
    //   sym 0 = 110 (6), sym 1 = 111 (7), sym 2 = 1000... that's > 3 bits!
    //
    // Hmm, 5 symbols at length 3 starting from code 6: 6,7,8,9,10
    // But 3-bit codes max at 7 (0b111). So codes 8,9,10 don't fit in 3 bits.
    // This is an invalid Huffman tree. Let me pick valid lengths.
    //
    // Valid: [2, 2, 3, 3, 3, 3] (6 symbols)
    // len 2: count=2 (syms 0,1), first_code = 0
    //   sym 0 = 00, sym 1 = 01
    // len 3: count=4 (syms 2,3,4,5), first_code = (0+2)<<1 = 4
    //   sym 2 = 100, sym 3 = 101, sym 4 = 110, sym 5 = 111

    const code_lengths = [_]u8{ 2, 2, 3, 3, 3, 3 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    // Encode sequence: 0, 1, 2, 3, 4, 5, 0
    // Codes: 00, 01, 100, 101, 110, 111, 00
    // Bitstream: 00 01 100 101 110 111 00
    // = 00011001 01110111 00______
    // = 0x19, 0x77, 0x00 (padded)
    const data = [_]u8{ 0x19, 0x77, 0x00 };
    var br = BitReader.init(&data);

    const expected = [_]u16{ 0, 1, 2, 3, 4, 5, 0 };
    for (expected) |sym| {
        try testing.expectEqual(sym, try decodeNumber(&br, &table));
    }
}

test "decodeNumber on invalid table returns InvalidTable" {
    var table = DecodeTable{}; // valid = false
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);
    try testing.expectError(error.InvalidTable, decodeNumber(&br, &table));
}

test "decodeNumber on empty stream returns EndOfData" {
    const code_lengths = [_]u8{ 1, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    const data = [_]u8{};
    var br = BitReader.init(&data);
    try testing.expectError(error.EndOfData, decodeNumber(&br, &table));
}

test "freeDecodeTable resets state" {
    const code_lengths = [_]u8{ 1, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    try testing.expect(table.valid);
    try testing.expect(table.decode_num.len > 0);

    freeDecodeTable(&table, testing.allocator);
    try testing.expect(!table.valid);
    try testing.expectEqual(@as(usize, 0), table.decode_num.len);
}

test "15-bit maximum code length" {
    // Create a skewed tree that forces some 15-bit codes.
    // Lengths: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15]
    // This is a valid complete Huffman tree where each interior node
    // has exactly one leaf and one child, except at the very bottom.
    const code_lengths = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 15 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    try testing.expect(table.valid);
    try testing.expectEqual(@as(usize, 16), table.decode_num.len);

    // Verify the two 15-bit symbols exist
    // Symbol 14 and 15 should be at the end of decode_num
    // decode_pos[15] should point to where the 15-bit symbols start
    const pos15 = table.decode_pos[15];
    try testing.expectEqual(@as(u16, 14), table.decode_num[pos15]);
    try testing.expectEqual(@as(u16, 15), table.decode_num[pos15 + 1]);

    // Now encode symbol 14 and symbol 15 and decode them.
    // The first code at length 15:
    // We need to compute it. Let's trace through:
    //   len 1: code=0, count=1(sym 0)
    //   len 2: code=(0+1)<<1=2, count=1(sym 1)
    //   len 3: code=(2+1)<<1=6, count=1(sym 2)
    //   len 4: code=(6+1)<<1=14
    //   len 5: code=(14+1)<<1=30
    //   len 6: code=(30+1)<<1=62
    //   len 7: code=(62+1)<<1=126
    //   len 8: code=(126+1)<<1=254
    //   len 9: code=(254+1)<<1=510
    //   len 10: code=(510+1)<<1=1022
    //   len 11: code=(1022+1)<<1=2046
    //   len 12: code=(2046+1)<<1=4094
    //   len 13: code=(4094+1)<<1=8190
    //   len 14: code=(8190+1)<<1=16382
    //   len 15: code=(16382+1)<<1=32766
    // sym 14 = 32766 (15 bits), sym 15 = 32767 (15 bits)
    try testing.expectEqual(@as(u32, 32766), table.decode_len[15]);

    // 32766 in 15 bits = 0b111111111111110
    // 32767 in 15 bits = 0b111111111111111
    // Concatenated: 111111111111110 111111111111111 00 (padded to 32 bits)
    // = 11111111 11111101 11111111 11111100
    // = 0xFF, 0xFD, 0xFF, 0xFC
    const data = [_]u8{ 0xFF, 0xFD, 0xFF, 0xFC };
    var br = BitReader.init(&data);

    try testing.expectEqual(@as(u16, 14), try decodeNumber(&br, &table));
    try testing.expectEqual(@as(u16, 15), try decodeNumber(&br, &table));
}

test "quick table correctly handles all entries for 2-bit codes" {
    // With codes [2,2,2,2]: first_code[2] = 0
    // Code 00 = sym 0, 01 = sym 1, 10 = sym 2, 11 = sym 3
    // Quick table should map:
    //   0b0000000000 (00 << 8) -> sym 0, len 2
    //   0b0100000000 (01 << 8) -> sym 1, len 2
    //   etc.
    const code_lengths = [_]u8{ 2, 2, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    // Check a sampling of quick table entries
    // Entry 0b0000000000 (0) -> sym 0, len 2
    try testing.expectEqual(@as(u16, 0), table.quick_table[0].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[0].length);

    // Entry 0b0100000000 (256) -> sym 1, len 2
    try testing.expectEqual(@as(u16, 1), table.quick_table[256].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[256].length);

    // Entry 0b1000000000 (512) -> sym 2, len 2
    try testing.expectEqual(@as(u16, 2), table.quick_table[512].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[512].length);

    // Entry 0b1100000000 (768) -> sym 3, len 2
    try testing.expectEqual(@as(u16, 3), table.quick_table[768].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[768].length);

    // Entries between should map to the same symbol (suffix bits vary)
    // E.g. 0b0000000001 (1) should also map to sym 0, len 2
    try testing.expectEqual(@as(u16, 0), table.quick_table[1].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[1].length);
}

test "symbols with length 0 are skipped" {
    // Lengths: [0, 1, 0, 2, 2, 0]
    // Active symbols: sym 1 (len 1), sym 3 (len 2), sym 4 (len 2)
    // Same structure as [1, 2, 2] but with different symbol indices
    const code_lengths = [_]u8{ 0, 1, 0, 2, 2, 0 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    try testing.expect(table.valid);
    try testing.expectEqual(@as(usize, 3), table.decode_num.len);
    try testing.expectEqual(@as(u16, 1), table.decode_num[0]); // len 1
    try testing.expectEqual(@as(u16, 3), table.decode_num[1]); // len 2
    try testing.expectEqual(@as(u16, 4), table.decode_num[2]); // len 2

    // Decode: sym 1 (code 0, 1 bit), sym 3 (code 10, 2 bits), sym 4 (code 11, 2 bits)
    // Bitstream: 0 10 11 0 = 01011000 = 0x58
    const data = [_]u8{0x58};
    var br = BitReader.init(&data);

    try testing.expectEqual(@as(u16, 1), try decodeNumber(&br, &table));
    try testing.expectEqual(@as(u16, 3), try decodeNumber(&br, &table));
    try testing.expectEqual(@as(u16, 4), try decodeNumber(&br, &table));
    try testing.expectEqual(@as(u16, 1), try decodeNumber(&br, &table));
}
