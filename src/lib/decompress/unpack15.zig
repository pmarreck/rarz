const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;
const Window = @import("lz.zig").Window;

// RAR 1.5 uses adaptive Huffman coding, not the canonical Huffman from huffman.zig.
// We import it for API consistency but the actual decoding uses adaptive character sets.
const huffman = @import("huffman.zig");

/// RAR 1.5 decompression errors.
pub const Error = error{
    DecompressionError,
    EndOfData,
    OutOfMemory,
    InvalidData,
};

/// Number of entries in each character set (256 symbols, 2 words each: value + count).
const CHAR_SET_SIZE = 256;

/// Threshold for CorrHuff — when cumulative frequency exceeds this, halve all.
const CORR_HUFF_THRESHOLD: u16 = 0x6000;

/// Initial placement table for ChSet (NToPl).
/// These define how many symbols get each bit-length initially.
/// The table encodes: nto_pl[i] = number of bits needed to encode symbol at position i.
/// Standard RAR 1.5 initialization.
const INIT_NTO_PL = [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0-15: 0 bits (special)
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 16-31
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 32-47
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 48-63
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 64-79
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 80-95
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // 96-111
    3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 7, // 112-127
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 128-143
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 144-159
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 160-175
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 176-191
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 192-207
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 208-223
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // 224-239
    3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 7, // 240-255
};

/// Initial placement table for ChSetB (NToPlB) — used for match lengths.
const INIT_NTO_PL_B = [256]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
};

/// Initial placement table for ChSetC (NToPlC) — used for match distances.
const INIT_NTO_PL_C = [256]u8{
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
};

/// Decode a symbol from an adaptive character set.
/// The character set is organized as pairs: [value, count] stored in a flat array.
/// Uses the placement table to determine bit lengths for each position range.
///
/// Returns the decoded symbol value (high byte of the character set entry) and
/// updates the character set by promoting the found entry (move-to-front variant).
fn decodeChar(
    br: *BitReader,
    ch_set: *[CHAR_SET_SIZE]u16,
    nto_pl: *const [256]u8,
) Error!u8 {
    // Peek enough bits to find the placement
    const peek_val = br.peekBits(8) catch return Error.EndOfData;

    // The placement table tells us how many additional bits define position within that group
    const byte_val: u8 = @intCast(peek_val);
    const place_bits = nto_pl[byte_val];

    // Calculate the position in the character set
    // The placement table groups symbols by frequency: lower positions = more frequent
    var pos: usize = 0;

    // Count how many symbols precede this group
    // Each bit-length group occupies a range in the table
    if (place_bits > 0) {
        // Skip past groups with fewer bits
        var group_start: usize = 0;

        // The groups in NToPl are arranged: group 0 takes positions where nto_pl[i]==0, etc.
        // To find position, read `place_bits + 1` bits from the stream
        const total_bits: u5 = @intCast(@min(@as(u32, place_bits) + 1, 8));
        const code = br.readBits(total_bits) catch return Error.EndOfData;

        // Count entries in lower-numbered groups to find the starting position
        for (0..256) |i| {
            if (nto_pl[i] < place_bits) {
                group_start += 1;
            }
        }

        // Within this group, the remaining bits give the offset
        const group_size = countGroup(nto_pl, place_bits);

        // The code's lower bits index within the group
        const group_offset = code & ((@as(u32, 1) << @intCast(place_bits)) - 1);
        pos = group_start + @min(@as(usize, group_offset), if (group_size > 0) group_size - 1 else 0);
    } else {
        // Group 0: the most frequent symbols. Only 1 bit was peeked effectively.
        // Position is directly the byte value mapped through group-0 ordering
        const code = br.readBits(1) catch return Error.EndOfData;
        _ = code;

        // For group 0, count how many entries have nto_pl == 0 before this byte_val
        var count: usize = 0;
        for (0..@as(usize, byte_val)) |i| {
            if (nto_pl[i] == 0) count += 1;
        }
        pos = count;
    }

    // Clamp position to valid range
    if (pos >= CHAR_SET_SIZE) pos = CHAR_SET_SIZE - 1;

    // Get the symbol value (high byte of character set entry)
    const symbol: u8 = @intCast(ch_set[pos] >> 8);

    // Update frequency: increment the low byte (count)
    const old_count = ch_set[pos] & 0xFF;
    if (old_count < 0xFF) {
        ch_set[pos] = (@as(u16, symbol) << 8) | @as(u16, @intCast(old_count + 1));
    }

    // Promote: swap toward the front if the entry behind has a lower count
    if (pos > 0) {
        const prev_count = ch_set[pos - 1] & 0xFF;
        const cur_count = ch_set[pos] & 0xFF;
        if (cur_count > prev_count) {
            const tmp = ch_set[pos];
            ch_set[pos] = ch_set[pos - 1];
            ch_set[pos - 1] = tmp;
        }
    }

    return symbol;
}

/// Count how many entries in a placement table have a given bit-length value.
fn countGroup(nto_pl: *const [256]u8, group: u8) usize {
    var count: usize = 0;
    for (nto_pl) |v| {
        if (v == group) count += 1;
    }
    return count;
}

/// Correct (normalize) an adaptive Huffman table by halving all counts.
/// This prevents frequency overflow and helps the table adapt to changing data.
fn corrHuff(ch_set: *[CHAR_SET_SIZE]u16) void {
    for (0..CHAR_SET_SIZE) |i| {
        const value = ch_set[i] >> 8;
        var count = ch_set[i] & 0xFF;
        // Halve the count, minimum 0
        count >>= 1;
        ch_set[i] = @as(u16, @intCast(value)) << 8 | count;
    }
}

/// Check if cumulative frequency exceeds threshold, and if so, correct the table.
fn checkAndCorrect(ch_set: *[CHAR_SET_SIZE]u16) void {
    var total: u32 = 0;
    for (0..CHAR_SET_SIZE) |i| {
        total += ch_set[i] & 0xFF;
    }
    if (total > CORR_HUFF_THRESHOLD) {
        corrHuff(ch_set);
    }
}

/// RAR 1.5 decompression state.
pub const Unpack15State = struct {
    br: *BitReader,
    window: Window,

    // Flag buffer — drives mode selection
    flag_buf: u32, // current flag byte being consumed
    flag_bits_left: u4, // bits remaining in current flag byte
    flags_pos: usize, // position in the flag buffer data

    // Adaptive Huffman character sets
    // Each entry: high byte = symbol value, low byte = frequency count
    ch_set: [CHAR_SET_SIZE]u16,
    ch_set_a: [CHAR_SET_SIZE]u16,
    ch_set_b: [CHAR_SET_SIZE]u16,
    ch_set_c: [CHAR_SET_SIZE]u16,

    // Placement tables — map peek values to bit-length groups
    nto_pl: [256]u8,
    nto_pl_b: [256]u8,
    nto_pl_c: [256]u8,

    // Moving averages for adaptive decisions
    num_huf: u32, // Nhfb: ratio of huffman vs LZ tokens
    num_lz: u32, // Nlzb: LZ frequency
    avr1: u32, // average for LongLZ distance decisions
    avr2: u32, // average for ShortLZ distance decisions
    avr3: u32, // average for match length

    // Match state
    prev_distance: u32,
    last_distance: u32,
    last_length: u32,

    // Output tracking
    written_size: u64,
    unp_size: u64,

    allocator: std.mem.Allocator,

    /// Initialize the RAR 1.5 decompression state.
    pub fn init(
        allocator: std.mem.Allocator,
        br: *BitReader,
        dict_bits: u5,
        unp_size: u64,
    ) Error!Unpack15State {
        var state = Unpack15State{
            .br = br,
            .window = Window.initFromBits(allocator, dict_bits) catch return Error.OutOfMemory,
            .flag_buf = 0,
            .flag_bits_left = 0,
            .flags_pos = 0,
            .ch_set = undefined,
            .ch_set_a = undefined,
            .ch_set_b = undefined,
            .ch_set_c = undefined,
            .nto_pl = INIT_NTO_PL,
            .nto_pl_b = INIT_NTO_PL_B,
            .nto_pl_c = INIT_NTO_PL_C,
            .num_huf = 0x800,
            .num_lz = 0x800,
            .avr1 = 0,
            .avr2 = 0,
            .avr3 = 0,
            .prev_distance = 0,
            .last_distance = 0,
            .last_length = 0,
            .written_size = 0,
            .unp_size = unp_size,
            .allocator = allocator,
        };

        state.initTables();
        return state;
    }

    /// Initialize the adaptive character set tables to their starting state.
    pub fn initTables(self: *Unpack15State) void {
        // ChSet: symbol i at position i, count 0
        for (0..CHAR_SET_SIZE) |i| {
            self.ch_set[i] = @as(u16, @intCast(i)) << 8;
        }

        // ChSetA: same structure
        for (0..CHAR_SET_SIZE) |i| {
            self.ch_set_a[i] = @as(u16, @intCast(i)) << 8;
        }

        // ChSetB: initialized for length decoding
        for (0..CHAR_SET_SIZE) |i| {
            self.ch_set_b[i] = @as(u16, @intCast(i)) << 8;
        }

        // ChSetC: initialized for distance decoding
        for (0..CHAR_SET_SIZE) |i| {
            self.ch_set_c[i] = @as(u16, @intCast(i)) << 8;
        }

        // Reset placement tables
        self.nto_pl = INIT_NTO_PL;
        self.nto_pl_b = INIT_NTO_PL_B;
        self.nto_pl_c = INIT_NTO_PL_C;

        // Reset moving averages
        self.num_huf = 0x800;
        self.num_lz = 0x800;
        self.avr1 = 0;
        self.avr2 = 0;
        self.avr3 = 0;

        // Reset match state
        self.prev_distance = 0;
        self.last_distance = 0;
        self.last_length = 0;
    }

    /// Get the next flag bit. If the current flag byte is exhausted, read a new one.
    fn getFlag(self: *Unpack15State) Error!u1 {
        if (self.flag_bits_left == 0) {
            // Read a new flag byte from the bitstream
            const byte = self.br.readBits(8) catch return Error.EndOfData;
            self.flag_buf = byte;
            self.flag_bits_left = 8;
        }

        // Extract the MSB of the flag byte
        const bit: u1 = @intCast((self.flag_buf >> 7) & 1);
        self.flag_buf = (self.flag_buf << 1) & 0xFF;
        self.flag_bits_left -= 1;

        return bit;
    }

    /// HuffDecode: Decode a literal byte from the adaptive Huffman table.
    fn huffDecode(self: *Unpack15State) Error!void {
        // Update moving average: more huffman tokens
        self.num_huf +%= 1;

        // Decode a literal from ChSet
        const byte = try decodeChar(self.br, &self.ch_set, &self.nto_pl);

        // Output the literal
        self.window.putByte(byte);
        self.written_size += 1;

        // Periodically correct the Huffman table
        checkAndCorrect(&self.ch_set);
    }

    /// LongLZ: Decode a long LZ match (distance + length from bitstream).
    fn longLZ(self: *Unpack15State) Error!void {
        // Update moving average
        self.num_lz +%= 1;

        // Decode distance from ChSetC
        const dist_sym = try decodeChar(self.br, &self.ch_set_c, &self.nto_pl_c);

        // Distance = dist_sym * 256 + extra 8 bits (for distances > 255)
        var distance: u32 = undefined;
        if (dist_sym == 0) {
            // Short distance: just read 6 extra bits
            const extra = self.br.readBits(6) catch return Error.EndOfData;
            distance = extra + 1;
        } else {
            const extra = self.br.readBits(8) catch return Error.EndOfData;
            distance = (@as(u32, dist_sym) << 8) | extra;
        }

        // Decode length from the bitstream
        var length: u32 = undefined;

        // Read length indicator bits
        const len_bits = self.br.peekBits(2) catch return Error.EndOfData;

        if (len_bits == 0) {
            // 2 bits: 00 → length = 2
            self.br.skipBits(2);
            length = 2;
        } else if (len_bits == 1) {
            // 2 bits: 01 → length = 3
            self.br.skipBits(2);
            length = 3;
        } else if (len_bits == 2) {
            // 2 bits: 10 → read 1 more bit for length 4 or 5
            self.br.skipBits(2);
            const extra_len = self.br.readBits(1) catch return Error.EndOfData;
            length = 4 + extra_len;
        } else {
            // 2 bits: 11 → decode from ChSetB for longer lengths
            self.br.skipBits(2);
            const len_sym = try decodeChar(self.br, &self.ch_set_b, &self.nto_pl_b);
            length = @as(u32, len_sym) + 6;
            checkAndCorrect(&self.ch_set_b);
        }

        // Store match state
        self.prev_distance = self.last_distance;
        self.last_distance = distance;
        self.last_length = length;

        // Execute the match copy
        self.window.copyMatch(@intCast(distance), @intCast(length));
        self.written_size += length;

        // Update averages
        self.avr1 = (self.avr1 *% 3 +% distance) / 4;
        self.avr3 = (self.avr3 *% 3 +% length) / 4;

        checkAndCorrect(&self.ch_set_c);
    }

    /// ShortLZ: Decode a short/repeat match.
    fn shortLZ(self: *Unpack15State) Error!void {
        // Read 2 bits to determine the short match type
        const type_bits = self.br.readBits(2) catch return Error.EndOfData;

        if (type_bits == 0) {
            // Repeat: use last distance with new length
            var length: u32 = undefined;

            // Decode repeat length
            const len_bit = self.br.readBits(1) catch return Error.EndOfData;
            if (len_bit == 0) {
                length = 2;
            } else {
                const len_bits2 = self.br.readBits(1) catch return Error.EndOfData;
                if (len_bits2 == 0) {
                    length = 3;
                } else {
                    length = 4;
                }
            }

            // Use last distance for repeat
            const distance = self.last_distance;
            if (distance == 0) return Error.DecompressionError;

            self.last_length = length;

            self.window.copyMatch(@intCast(distance), @intCast(length));
            self.written_size += length;

            self.avr2 = (self.avr2 *% 3 +% distance) / 4;
        } else {
            // Short distance match
            // type_bits 1-3 encode small distances with short lengths
            var distance: u32 = type_bits; // 1, 2, or 3
            const extra = self.br.readBits(2) catch return Error.EndOfData;
            distance = (distance << 2) | extra;

            // Distance is 1-based
            if (distance == 0) distance = 1;

            const length: u32 = 2; // Short matches are always length 2

            self.prev_distance = self.last_distance;
            self.last_distance = distance;
            self.last_length = length;

            self.window.copyMatch(@intCast(distance), @intCast(length));
            self.written_size += length;

            self.avr2 = (self.avr2 *% 3 +% distance) / 4;
        }
    }

    /// Run the main decompression loop.
    fn unpack(self: *Unpack15State) Error!void {
        while (self.written_size < self.unp_size) {
            // Check if we have enough bits remaining
            if (self.br.remainingBits() < 16) return Error.EndOfData;

            // Get flag bit to determine mode
            const flag = try self.getFlag();

            if (flag == 0) {
                // Literal / Huffman decode
                try self.huffDecode();
            } else {
                // LZ match
                const lz_flag = try self.getFlag();

                if (lz_flag == 0) {
                    // Long LZ match
                    try self.longLZ();
                } else {
                    // Short LZ match / repeat
                    try self.shortLZ();
                }
            }
        }
    }

    /// Clean up resources.
    pub fn deinit(self: *Unpack15State) void {
        self.window.deinit(self.allocator);
    }
};

/// Public decompression interface for RAR 1.5 data.
///
/// Takes packed data and produces unpacked output.
/// dict_bits is typically 15-16 for RAR 1.5 archives.
///
/// Note: RAR 1.5 is the oldest and most obscure RAR format.
/// This implementation handles the basic framework (flag buffer, adaptive Huffman
/// literals, LZ matches) but may not handle all edge cases of the adaptive coding.
/// Real RAR 1.5 files are extremely rare in practice.
pub fn decompress(
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    dict_bits: u5,
) Error![]u8 {
    if (unpacked_size == 0) {
        return allocator.alloc(u8, 0) catch return Error.OutOfMemory;
    }

    var br = BitReader.init(packed_data);
    var state = try Unpack15State.init(allocator, &br, dict_bits, unpacked_size);
    defer state.deinit();

    // Run the decompression loop
    state.unpack() catch |err| {
        // If we hit end-of-data but have written enough, that's OK
        if (err == Error.EndOfData and state.written_size >= unpacked_size) {
            // Success — we have all the data
        } else {
            return err;
        }
    };

    // Copy output from the window
    const out_size: usize = @intCast(@min(state.written_size, unpacked_size));
    const output = allocator.alloc(u8, out_size) catch return Error.OutOfMemory;
    _ = state.window.copyToOutput(output, out_size, out_size);

    return output;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Unpack15State initialization — tables are correctly set up" {
    var dummy_data = [_]u8{0xFF} ** 32;
    var br = BitReader.init(&dummy_data);
    var state = try Unpack15State.init(testing.allocator, &br, 15, 0);
    defer state.deinit();

    // Verify ChSet: each entry should be (i << 8) | 0
    for (0..CHAR_SET_SIZE) |i| {
        const expected: u16 = @as(u16, @intCast(i)) << 8;
        try testing.expectEqual(expected, state.ch_set[i]);
    }

    // Verify ChSetB
    for (0..CHAR_SET_SIZE) |i| {
        const expected: u16 = @as(u16, @intCast(i)) << 8;
        try testing.expectEqual(expected, state.ch_set_b[i]);
    }

    // Verify ChSetC
    for (0..CHAR_SET_SIZE) |i| {
        const expected: u16 = @as(u16, @intCast(i)) << 8;
        try testing.expectEqual(expected, state.ch_set_c[i]);
    }

    // Verify moving averages
    try testing.expectEqual(@as(u32, 0x800), state.num_huf);
    try testing.expectEqual(@as(u32, 0x800), state.num_lz);
    try testing.expectEqual(@as(u32, 0), state.avr1);
    try testing.expectEqual(@as(u32, 0), state.avr2);
    try testing.expectEqual(@as(u32, 0), state.avr3);

    // Verify match state
    try testing.expectEqual(@as(u32, 0), state.last_distance);
    try testing.expectEqual(@as(u32, 0), state.last_length);
    try testing.expectEqual(@as(u32, 0), state.prev_distance);
}

test "Unpack15State initialization — placement tables match expected values" {
    var dummy_data = [_]u8{0xFF} ** 32;
    var br = BitReader.init(&dummy_data);
    var state = try Unpack15State.init(testing.allocator, &br, 15, 0);
    defer state.deinit();

    // NToPl: first 64 entries should be 0 (group 0)
    for (0..64) |i| {
        try testing.expectEqual(@as(u8, 0), state.nto_pl[i]);
    }
    // Entry 64 should be 1 (group 1)
    try testing.expectEqual(@as(u8, 1), state.nto_pl[64]);
    // Entry 96 should be 2 (group 2)
    try testing.expectEqual(@as(u8, 2), state.nto_pl[96]);
    // Entry 127 should be 7
    try testing.expectEqual(@as(u8, 7), state.nto_pl[127]);

    // NToPlB: entry 0 should be 0
    try testing.expectEqual(@as(u8, 0), state.nto_pl_b[0]);
    // Entry 8 should be 1
    try testing.expectEqual(@as(u8, 1), state.nto_pl_b[8]);

    // NToPlC: entry 0 should be 0
    try testing.expectEqual(@as(u8, 0), state.nto_pl_c[0]);
    // Entry 4 should be 1
    try testing.expectEqual(@as(u8, 1), state.nto_pl_c[4]);
}

test "flag bit reading — consumes flag byte correctly" {
    // Flag byte 0xA5 = 10100101
    // Expected bits: 1, 0, 1, 0, 0, 1, 0, 1
    var data = [_]u8{0xA5} ++ [_]u8{0xFF} ** 64;
    var br = BitReader.init(&data);
    var state = try Unpack15State.init(testing.allocator, &br, 15, 0);
    defer state.deinit();

    // First call reads a flag byte from the stream
    try testing.expectEqual(@as(u1, 1), try state.getFlag());
    try testing.expectEqual(@as(u1, 0), try state.getFlag());
    try testing.expectEqual(@as(u1, 1), try state.getFlag());
    try testing.expectEqual(@as(u1, 0), try state.getFlag());
    try testing.expectEqual(@as(u1, 0), try state.getFlag());
    try testing.expectEqual(@as(u1, 1), try state.getFlag());
    try testing.expectEqual(@as(u1, 0), try state.getFlag());
    try testing.expectEqual(@as(u1, 1), try state.getFlag());

    // Next call should trigger reading the next byte (0xFF)
    try testing.expectEqual(@as(u1, 1), try state.getFlag());
    try testing.expectEqual(@as(u4, 7), state.flag_bits_left);
}

test "corrHuff — halves all frequency counts" {
    var ch_set: [CHAR_SET_SIZE]u16 = undefined;

    // Set up: symbol i with count i (mod 256)
    for (0..CHAR_SET_SIZE) |i| {
        ch_set[i] = @as(u16, @intCast(i)) << 8 | @as(u16, @intCast(i));
    }

    corrHuff(&ch_set);

    // After correction, counts should be halved
    for (0..CHAR_SET_SIZE) |i| {
        const value: u8 = @intCast(ch_set[i] >> 8);
        const count: u8 = @intCast(ch_set[i] & 0xFF);
        try testing.expectEqual(@as(u8, @intCast(i)), value); // value unchanged
        try testing.expectEqual(@as(u8, @intCast(i >> 1)), count); // count halved
    }
}

test "corrHuff — preserves symbol values" {
    var ch_set: [CHAR_SET_SIZE]u16 = undefined;

    // All entries have max frequency
    for (0..CHAR_SET_SIZE) |i| {
        ch_set[i] = @as(u16, @intCast(i)) << 8 | 0xFF;
    }

    corrHuff(&ch_set);

    // Symbols should be preserved, counts halved from 255 to 127
    for (0..CHAR_SET_SIZE) |i| {
        const value: u8 = @intCast(ch_set[i] >> 8);
        const count: u8 = @intCast(ch_set[i] & 0xFF);
        try testing.expectEqual(@as(u8, @intCast(i)), value);
        try testing.expectEqual(@as(u8, 127), count); // 255 >> 1 = 127
    }
}

test "checkAndCorrect — triggers correction above threshold" {
    var ch_set: [CHAR_SET_SIZE]u16 = undefined;

    // Set all counts to 100 -> total = 25600 > 0x6000 (24576)
    for (0..CHAR_SET_SIZE) |i| {
        ch_set[i] = @as(u16, @intCast(i)) << 8 | 100;
    }

    checkAndCorrect(&ch_set);

    // Counts should be halved to 50
    for (0..CHAR_SET_SIZE) |i| {
        const count: u8 = @intCast(ch_set[i] & 0xFF);
        try testing.expectEqual(@as(u8, 50), count);
    }
}

test "checkAndCorrect — does not trigger below threshold" {
    var ch_set: [CHAR_SET_SIZE]u16 = undefined;

    // Set all counts to 10 -> total = 2560 < 0x6000 (24576)
    for (0..CHAR_SET_SIZE) |i| {
        ch_set[i] = @as(u16, @intCast(i)) << 8 | 10;
    }

    checkAndCorrect(&ch_set);

    // Counts should remain 10
    for (0..CHAR_SET_SIZE) |i| {
        const count: u8 = @intCast(ch_set[i] & 0xFF);
        try testing.expectEqual(@as(u8, 10), count);
    }
}

test "initTables can be called multiple times (reset)" {
    var dummy_data = [_]u8{0xFF} ** 32;
    var br = BitReader.init(&dummy_data);
    var state = try Unpack15State.init(testing.allocator, &br, 15, 0);
    defer state.deinit();

    // Modify some state
    state.ch_set[0] = 0xBEEF;
    state.num_huf = 42;
    state.last_distance = 100;

    // Re-init tables
    state.initTables();

    // Should be back to initial values
    try testing.expectEqual(@as(u16, 0), state.ch_set[0]); // symbol 0, count 0
    try testing.expectEqual(@as(u32, 0x800), state.num_huf);
    try testing.expectEqual(@as(u32, 0), state.last_distance);
}

test "decompress — empty output" {
    const input = [_]u8{0x00} ** 16;
    const result = try decompress(testing.allocator, &input, 0, 15);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "countGroup — counts entries correctly" {
    const nto_pl = INIT_NTO_PL;

    // Group 0 should have the most entries (128 entries: 0-63 + 128-191)
    const g0 = countGroup(&nto_pl, 0);
    try testing.expectEqual(@as(usize, 128), g0);

    // Group 1 should have 64 entries (64-95 + 192-223)
    const g1 = countGroup(&nto_pl, 1);
    try testing.expectEqual(@as(usize, 64), g1);

    // Group 2 should have 32 entries (96-111 + 224-239)
    const g2 = countGroup(&nto_pl, 2);
    try testing.expectEqual(@as(usize, 32), g2);

    // Group 7 should have 2 entries (127 + 255)
    const g7 = countGroup(&nto_pl, 7);
    try testing.expectEqual(@as(usize, 2), g7);
}

test "window is properly sized from dict_bits" {
    var dummy_data = [_]u8{0xFF} ** 32;
    var br = BitReader.init(&dummy_data);

    // dict_bits = 15 → 32768 byte window
    var state15 = try Unpack15State.init(testing.allocator, &br, 15, 0);
    defer state15.deinit();
    try testing.expectEqual(@as(usize, 32768), state15.window.buffer.len);

    // dict_bits = 16 → 65536 byte window
    br.bit_pos = 0;
    var state16 = try Unpack15State.init(testing.allocator, &br, 16, 0);
    defer state16.deinit();
    try testing.expectEqual(@as(usize, 65536), state16.window.buffer.len);
}

test "adaptive table structure — entries encode value in high byte" {
    var ch_set: [CHAR_SET_SIZE]u16 = undefined;

    // Initialize like the real code does
    for (0..CHAR_SET_SIZE) |i| {
        ch_set[i] = @as(u16, @intCast(i)) << 8;
    }

    // Verify we can extract values correctly
    for (0..CHAR_SET_SIZE) |i| {
        const value: u8 = @intCast(ch_set[i] >> 8);
        const count: u8 = @intCast(ch_set[i] & 0xFF);
        try testing.expectEqual(@as(u8, @intCast(i)), value);
        try testing.expectEqual(@as(u8, 0), count);
    }
}

test "NToPlB placement table — groups are sized correctly" {
    const nto_pl_b = INIT_NTO_PL_B;

    // Group 0: first 8 entries
    const g0 = countGroup(&nto_pl_b, 0);
    try testing.expectEqual(@as(usize, 8), g0);

    // Group 1: next 4
    const g1 = countGroup(&nto_pl_b, 1);
    try testing.expectEqual(@as(usize, 4), g1);

    // Group 8: last large group (entries 96-255 = 160)
    const g8 = countGroup(&nto_pl_b, 8);
    try testing.expectEqual(@as(usize, 160), g8);
}

test "NToPlC placement table — groups are sized correctly" {
    const nto_pl_c = INIT_NTO_PL_C;

    // Group 0: 4 entries
    const g0 = countGroup(&nto_pl_c, 0);
    try testing.expectEqual(@as(usize, 4), g0);

    // Group 1: 4 entries
    const g1 = countGroup(&nto_pl_c, 1);
    try testing.expectEqual(@as(usize, 4), g1);

    // Group 7: 64 entries
    const g7 = countGroup(&nto_pl_c, 7);
    try testing.expectEqual(@as(usize, 64), g7);
}
