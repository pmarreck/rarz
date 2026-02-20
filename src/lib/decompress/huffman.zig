const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;

pub const MAX_CODE_LENGTH: u5 = 15;
pub const MAX_QUICK_BITS: u5 = 9; // matches unRAR's MAX_QUICK_DECODE_BITS
pub const QUICK_TABLE_SIZE: usize = 1 << MAX_QUICK_BITS; // 512

pub const DecodeTable = struct {
    /// Quick-path: table[peek_bits(quick_bits)] -> symbol + length
    /// If length == 0, need full decode path
    quick_table: [QUICK_TABLE_SIZE]QuickEntry = [_]QuickEntry{.{}} ** QUICK_TABLE_SIZE,

    /// First canonical code of each bit length (1-indexed, [0] unused).
    /// decode_len[n] = left-aligned upper limit for codes of length <= n.
    /// decode_len[MAX_CODE_LENGTH + 1] is a sentinel used for bounds checking.
    decode_len: [MAX_CODE_LENGTH + 2]u32 = [_]u32{0} ** (MAX_CODE_LENGTH + 2),

    /// Starting positions in decode_num for codes of each length.
    /// decode_pos[n] = index into decode_num where symbols of length n begin.
    decode_pos: [MAX_CODE_LENGTH + 2]u32 = [_]u32{0} ** (MAX_CODE_LENGTH + 2),

    /// Symbol numbers sorted by canonical code order.
    decode_num: []u16 = &.{},

    /// Number of symbols in the alphabet.
    max_num: u16 = 0,

    /// Number of bits used for quick decode (matches unRAR's QuickBits).
    /// 9 for large alphabets (NC=306, NC20=298, NC30=299), 6 for smaller ones.
    quick_bits: u5 = MAX_QUICK_BITS,

    /// Was this table successfully built?
    valid: bool = false,

    pub const QuickEntry = struct {
        symbol: u16 = 0,
        length: u5 = 0, // 0 means need full decode
    };
};

/// Build Huffman decode tables from code-length array using range-based boundaries.
/// This matches unRAR's MakeDecodeTables approach: instead of computing canonical codes
/// and matching them exactly, it builds left-aligned 16-bit range boundaries. This
/// correctly handles over-committed Huffman tables (Kraft sum > 1.0) that appear in
/// real RAR archives.
///
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

    // Step 2: Build range boundaries (left-aligned to 16-bit space) and positions.
    //
    // decode_len[L] = upper boundary for all codes of length <= L, left-aligned to 16 bits.
    // Formula: decode_len[L] = sum_{k=1}^{L} len_count[k] << (16 - k)
    //
    // This is equivalent to unRAR's: M = 2*(M + LenCount[I]); DecodeLen[I] = M << (15-I)
    // For well-formed trees, decode_len[max_used] = 0x10000 (exactly fills the code space).
    // For over-committed trees (Kraft > 1.0), it may exceed 0x10000, which is fine in u32.
    table.decode_len[0] = 0;
    table.decode_pos[0] = 0;
    var total_symbols: u32 = 0;

    for (1..MAX_CODE_LENGTH + 1) |len| {
        table.decode_len[len] = table.decode_len[len - 1] +
            (len_count[len] << @intCast(16 - len));
        table.decode_pos[len] = total_symbols;
        total_symbols += len_count[len];
    }
    table.decode_len[MAX_CODE_LENGTH + 1] = 0x10000; // Sentinel
    table.decode_pos[MAX_CODE_LENGTH + 1] = total_symbols;

    if (total_symbols == 0) {
        table.valid = false;
        return table;
    }

    // Step 3: Allocate and fill decode_num (symbols sorted by code length, then symbol order).
    table.decode_num = try allocator.alloc(u16, total_symbols);
    var tmp_pos: [MAX_CODE_LENGTH + 2]u32 = undefined;
    for (0..MAX_CODE_LENGTH + 2) |i| {
        tmp_pos[i] = table.decode_pos[i];
    }
    for (code_lengths, 0..) |cl, i| {
        if (cl > 0 and cl <= MAX_CODE_LENGTH) {
            const pos = tmp_pos[cl];
            if (pos < total_symbols) {
                table.decode_num[pos] = @intCast(i);
            }
            tmp_pos[cl] += 1;
        }
    }

    // Set quick_bits based on alphabet size (matches unRAR):
    // NC (306), NC20 (298), NC30 (299) -> MAX_QUICK_BITS (9)
    // All others -> MAX_QUICK_BITS - 3 (6)
    const size = code_lengths.len;
    table.quick_bits = if (size == 306 or size == 298 or size == 299)
        MAX_QUICK_BITS
    else if (MAX_QUICK_BITS > 3)
        MAX_QUICK_BITS - 3
    else
        0;

    // Step 4: Build quick-path lookup table.
    // For each possible quick_bits-wide value, left-align to 16 bits and find
    // which length bucket it falls into using the range boundaries.
    // Uses monotonic CurBitLength optimization matching unRAR.
    const quick_data_size: usize = @as(usize, 1) << table.quick_bits;
    var cur_bit_length: usize = 1;
    for (0..quick_data_size) |quick_val| {
        const bit_field: u32 = @as(u32, @intCast(quick_val)) << @intCast(16 - table.quick_bits);

        // Find the bit length (monotonically increasing since bit_field increases)
        while (cur_bit_length < MAX_CODE_LENGTH + 1 and bit_field >= table.decode_len[cur_bit_length]) {
            cur_bit_length += 1;
        }

        table.quick_table[quick_val].length = @intCast(cur_bit_length);

        // Calculate symbol position
        const prev_boundary = if (cur_bit_length > 0) table.decode_len[cur_bit_length - 1] else 0;
        const dist = (bit_field -| prev_boundary) >> @intCast(16 - cur_bit_length);
        const pos = table.decode_pos[cur_bit_length] + dist;

        if (cur_bit_length < MAX_CODE_LENGTH + 1 and pos < size) {
            table.quick_table[quick_val].symbol = table.decode_num[pos];
        } else {
            table.quick_table[quick_val].symbol = 0;
        }
    }

    table.valid = true;
    return table;
}

/// Decode one symbol from the bitstream using the given table.
/// Uses range-comparison decoding matching unRAR's DecodeNumber approach:
/// peek 16 bits, left-align to 16-bit field, compare against decode_len boundaries
/// to find the code length, then compute the symbol index.
pub fn decodeNumber(br: *BitReader, table: *const DecodeTable) !u16 {
    if (!table.valid) return error.InvalidTable;

    const bits_available = br.remainingBits();
    if (bits_available == 0) return error.EndOfData;

    // Peek up to 16 bits and left-align to 16-bit field for range comparison
    const peek_count: u5 = if (bits_available >= 16) 16 else @intCast(bits_available);
    const peeked = try br.peekBits(peek_count);
    const bit_field: u32 = if (peek_count < 16)
        peeked << @intCast(16 - peek_count)
    else
        peeked;

    // Quick table check: if the value falls within the quick_bits boundary
    // (matching unRAR: BitField < DecodeLen[QuickBits])
    const qb = table.quick_bits;
    if (bit_field < table.decode_len[qb]) {
        const quick_idx: u32 = bit_field >> @intCast(16 - qb);
        const quick = table.quick_table[@intCast(quick_idx)];
        if (quick.length > 0 and quick.length <= peek_count) {
            br.skipBits(quick.length);
            return quick.symbol;
        }
    }

    // Slow path: find the correct code length by scanning range boundaries.
    // Matches unRAR: scan from QuickBits+1 to 14, default to 15.
    var bits: u5 = MAX_CODE_LENGTH;
    {
        var len: usize = @as(usize, qb) + 1;
        while (len < MAX_CODE_LENGTH) : (len += 1) {
            if (bit_field < table.decode_len[len]) {
                bits = @intCast(len);
                break;
            }
        }
    }

    // Skip the consumed bits
    if (bits <= peek_count) {
        br.skipBits(bits);
    } else {
        br.skipBits(peek_count);
    }

    // Calculate symbol position in decode_num using range arithmetic
    const prev_boundary = if (bits > 0) table.decode_len[bits - 1] else 0;
    var n: u32 = table.decode_pos[bits] +
        ((bit_field -| prev_boundary) >> @intCast(16 - bits));

    // Overflow protection (matches unRAR's N >= MaxNum check)
    if (n >= table.max_num or n >= table.decode_num.len) {
        n = 0;
    }

    return table.decode_num[@intCast(n)];
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

    // Verify range boundaries (left-aligned to 16 bits):
    // length 1: 1 code -> boundary = 1 << 15 = 0x8000
    // length 2: 2 codes -> boundary = 0x8000 + 2 << 14 = 0x10000
    try testing.expectEqual(@as(u32, 0x8000), table.decode_len[1]);
    try testing.expectEqual(@as(u32, 0x10000), table.decode_len[2]);
}

test "build table from [2, 2, 2, 2] gives codes 00, 01, 10, 11" {
    const code_lengths = [_]u8{ 2, 2, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    try testing.expect(table.valid);
    try testing.expectEqual(@as(usize, 4), table.decode_num.len);

    // All codes are length 2. Range boundary = 4 << 14 = 0x10000
    try testing.expectEqual(@as(u32, 0x10000), table.decode_len[2]);

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

    // Range boundaries (left-aligned to 16 bits):
    // Each length has 1 symbol (except 15 which has 2).
    // decode_len[L] = sum_{k=1}^{L} count[k] << (16-k)
    //   L=1: 1<<15 = 32768
    //   L=2: 32768 + 1<<14 = 49152
    //   ... geometric series converging to 65536
    //   L=15: 65536 (the tree is complete)
    try testing.expectEqual(@as(u32, 65536), table.decode_len[15]);

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
    // For 4-symbol alphabet, quick_bits = MAX_QUICK_BITS - 3 = 6, so 64 entries.
    // Quick table indices use 6-bit values: entry = code_prefix << (6 - code_len)
    //   00xxxx (0-15)  -> sym 0, len 2
    //   01xxxx (16-31) -> sym 1, len 2
    //   10xxxx (32-47) -> sym 2, len 2
    //   11xxxx (48-63) -> sym 3, len 2
    const code_lengths = [_]u8{ 2, 2, 2, 2 };
    var table = try makeDecodeTables(&code_lengths, testing.allocator);
    defer freeDecodeTable(&table, testing.allocator);

    // Verify quick_bits is 6 for small alphabet
    try testing.expectEqual(@as(u5, 6), table.quick_bits);

    // Entry 0 (00_0000) -> sym 0, len 2
    try testing.expectEqual(@as(u16, 0), table.quick_table[0].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[0].length);

    // Entry 16 (01_0000) -> sym 1, len 2
    try testing.expectEqual(@as(u16, 1), table.quick_table[16].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[16].length);

    // Entry 32 (10_0000) -> sym 2, len 2
    try testing.expectEqual(@as(u16, 2), table.quick_table[32].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[32].length);

    // Entry 48 (11_0000) -> sym 3, len 2
    try testing.expectEqual(@as(u16, 3), table.quick_table[48].symbol);
    try testing.expectEqual(@as(u5, 2), table.quick_table[48].length);

    // Entries between should map to the same symbol (suffix bits vary)
    // E.g. entry 1 (00_0001) should also map to sym 0, len 2
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
