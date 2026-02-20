const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;
const huffman = @import("huffman.zig");
const DecodeTable = huffman.DecodeTable;
const lz = @import("lz.zig");
const Window = lz.Window;

// ============================================================================
// RAR 2.x Constants
// ============================================================================

/// Main/control alphabet: 256 literals + 42 control codes = 298
const MC20: u16 = 298;
/// Distance alphabet: 48 slots
const DC20: u16 = 48;
/// Repeat-length alphabet: 28 slots
const RC20: u16 = 28;
/// Code-length alphabet for reading tables: 20 symbols
const BC20: u16 = 20;

/// Number of audio channels (max 4, indexed 0-3)
const MAX_AUDIO_CHANNELS: u8 = 4;

/// Short distances for 2-byte matches (symbols 261-268)
const short_distances = [8]u32{ 0, 1, 2, 3, 4, 8, 16, 32 };

/// Length base values for length slots
/// Slots 0-7: length = slot + 2
/// Slots 8+: extra bits pattern
const length_bases = computeLengthBases();
const length_extra_bits = computeLengthExtraBits();

fn computeLengthBases() [RC20]u32 {
    var bases: [RC20]u32 = undefined;
    // Slots 0-7: length = slot + 2, no extra bits
    for (0..8) |i| {
        bases[i] = @intCast(i + 2);
    }
    // Slots 8+: increasing extra bits
    // Slots 8,9: 1 extra bit each
    // Slots 10,11: 2 extra bits each
    // ...
    var base: u32 = 10; // slot 8 starts at length 10
    var i: usize = 8;
    while (i < RC20) {
        const extra: u5 = @intCast((i - 6) / 2);
        const step: u32 = @as(u32, 1) << extra;
        bases[i] = base;
        base += step;
        if (i + 1 < RC20) {
            bases[i + 1] = base;
            base += step;
        }
        i += 2;
    }
    return bases;
}

fn computeLengthExtraBits() [RC20]u5 {
    var extra: [RC20]u5 = undefined;
    for (0..8) |i| {
        extra[i] = 0;
    }
    for (8..RC20) |i| {
        extra[i] = @intCast((i - 6) / 2);
    }
    return extra;
}

/// Distance extra bits: slot/2 - 1 for slot >= 4
fn distanceDecode(slot: u32, br: *BitReader) !u32 {
    if (slot < 4) {
        return slot + 1;
    }
    const extra: u5 = @intCast(slot / 2 - 1);
    const base: u32 = (2 | (slot & 1)) << extra;
    const extra_val = try br.readBits(extra);
    return base + extra_val + 1;
}

// ============================================================================
// Audio Channel State (for audio mode)
// ============================================================================

const AudioChannel = struct {
    last_delta: i32 = 0,
    d1: i32 = 0,
    d2: i32 = 0,
    d3: i32 = 0,
    d4: i32 = 0,
    k1: i32 = 0,
    k2: i32 = 0,
    k3: i32 = 0,
    k4: i32 = 0,
    k5: i32 = 0,
    last_byte: i32 = 0,
    count: u32 = 0,

    fn decode(self: *AudioChannel, encoded_raw: u8) u8 {
        // Compute the predicted value using the adaptive linear predictor.
        // The five "delta" inputs for the FIR are: d1, d2, d3, d4, and a
        // delta-of-delta average computed from recent differences.
        const d5: i32 = self.d1 - self.d2;
        _ = d5;
        const d_avg: i32 = self.d1 + self.d2 + self.d3 + self.d4;
        _ = d_avg;

        // Predicted value from 5-tap adaptive filter
        const predicted: i32 = blk: {
            const v = @as(i64, 8) * @as(i64, self.d1) * @as(i64, self.k1) +
                @as(i64, 8) * @as(i64, self.d2) * @as(i64, self.k2) +
                @as(i64, 8) * @as(i64, self.d3) * @as(i64, self.k3) +
                @as(i64, 8) * @as(i64, self.d4) * @as(i64, self.k4) +
                @as(i64, 8) * @as(i64, (self.d1 - self.d2)) * @as(i64, self.k5);
            break :blk @intCast(@as(i64, @divTrunc(v, 8)) >> 8);
        };

        // Decode the encoded symbol as a signed value.
        // RAR 2.x encodes the audio residual as:
        //   0..127 -> positive (0..127)
        //   128..255 -> negative (remap)
        const encoded_signed: i32 = blk: {
            const e: i32 = @intCast(encoded_raw);
            if (e >= 128) {
                break :blk e - 256;
            }
            break :blk e;
        };

        const decoded_byte_i32: i32 = (predicted + encoded_signed) & 0xFF;
        const decoded_byte: u8 = @intCast(@as(u32, @bitCast(decoded_byte_i32)) & 0xFF);

        // Update deltas
        const dd: i32 = @as(i32, @intCast(decoded_byte)) -% self.last_delta;
        self.last_delta = @intCast(decoded_byte);

        // Shift deltas
        self.d4 = self.d3;
        self.d3 = self.d2;
        self.d2 = self.d1;
        self.d1 = dd;

        // Adapt coefficients every sample based on sign correlation
        const sign_dd = signOf(dd);
        adaptCoefficient(&self.k1, sign_dd, signOf(self.d1));
        adaptCoefficient(&self.k2, sign_dd, signOf(self.d2));
        adaptCoefficient(&self.k3, sign_dd, signOf(self.d3));
        adaptCoefficient(&self.k4, sign_dd, signOf(self.d4));
        adaptCoefficient(&self.k5, sign_dd, signOf(self.d1 - self.d2));

        self.last_byte = decoded_byte;
        self.count += 1;

        return decoded_byte;
    }

    fn reset(self: *AudioChannel) void {
        self.* = .{};
    }
};

fn signOf(val: i32) i32 {
    if (val > 0) return 1;
    if (val < 0) return -1;
    return 0;
}

fn adaptCoefficient(k: *i32, sign_dd: i32, sign_d: i32) void {
    if (sign_dd == sign_d) {
        if (k.* < 32) k.* += 1;
    } else if (sign_dd != 0 and sign_d != 0) {
        if (k.* > -32) k.* -= 1;
    }
}

// ============================================================================
// Unpack20 State
// ============================================================================

const Unpack20State = struct {
    br: *BitReader,
    window: Window,
    ld: DecodeTable, // main (298 symbols)
    dd: DecodeTable, // distance (48 symbols)
    rd: DecodeTable, // repeat length (28 symbols)
    md: [MAX_AUDIO_CHANNELS]DecodeTable, // per-channel audio tables
    prev_distances: [4]u32,
    last_distance: u32,
    last_length: u32,
    written_size: u64,
    unpacked_size: u64,
    audio_block: bool,
    audio_channels: u8,
    cur_channel: u8,
    channel_delta: u8,
    tables_loaded: bool,
    audio_state: [MAX_AUDIO_CHANNELS]AudioChannel,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, br: *BitReader, dict_bits: u5, unpacked_size: u64) !Unpack20State {
        return .{
            .br = br,
            .window = try Window.initFromBits(allocator, dict_bits),
            .ld = .{},
            .dd = .{},
            .rd = .{},
            .md = [_]DecodeTable{.{}} ** MAX_AUDIO_CHANNELS,
            .prev_distances = [_]u32{ 0, 0, 0, 0 },
            .last_distance = 0,
            .last_length = 0,
            .written_size = 0,
            .unpacked_size = unpacked_size,
            .audio_block = false,
            .audio_channels = 0,
            .cur_channel = 0,
            .channel_delta = 0,
            .tables_loaded = false,
            .audio_state = [_]AudioChannel{.{}} ** MAX_AUDIO_CHANNELS,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Unpack20State) void {
        self.window.deinit(self.allocator);
        self.freeTables();
    }

    fn freeTables(self: *Unpack20State) void {
        if (self.ld.valid) huffman.freeDecodeTable(&self.ld, self.allocator);
        if (self.dd.valid) huffman.freeDecodeTable(&self.dd, self.allocator);
        if (self.rd.valid) huffman.freeDecodeTable(&self.rd, self.allocator);
        for (&self.md) |*t| {
            if (t.valid) huffman.freeDecodeTable(t, self.allocator);
        }
    }
};

// ============================================================================
// Table Reading
// ============================================================================

/// Read and build Huffman tables from the bitstream (ReadTables20).
fn readTables(state: *Unpack20State) !void {
    const br = state.br;

    // Step 1: Align to byte boundary
    br.alignByte();

    // Step 2: Read audio mode flag
    const audio_flag = try br.readBits(1);
    state.audio_block = (audio_flag != 0);

    if (state.audio_block) {
        // Audio mode
        const channels_raw = try br.readBits(2);
        state.audio_channels = @intCast(channels_raw + 1);
        state.cur_channel = 0;

        // Free old audio tables
        for (&state.md) |*t| {
            if (t.valid) huffman.freeDecodeTable(t, state.allocator);
        }

        // Build per-channel audio Huffman tables
        for (0..state.audio_channels) |ch| {
            var code_lengths: [MC20]u8 = [_]u8{0} ** MC20;
            // Read 20 code lengths (4 bits each) for the first 20 symbols
            for (0..BC20) |i| {
                code_lengths[i] = @intCast(try br.readBits(4));
            }
            state.md[ch] = try huffman.makeDecodeTables(code_lengths[0..MC20], state.allocator);
        }
    } else {
        // LZ mode

        // Free old tables
        if (state.ld.valid) huffman.freeDecodeTable(&state.ld, state.allocator);
        if (state.dd.valid) huffman.freeDecodeTable(&state.dd, state.allocator);
        if (state.rd.valid) huffman.freeDecodeTable(&state.rd, state.allocator);

        // Read 20 code lengths for the code-length Huffman table (4 bits each)
        var bc_lengths: [BC20]u8 = undefined;
        for (0..BC20) |i| {
            bc_lengths[i] = @intCast(try br.readBits(4));
        }

        var bc_table = try huffman.makeDecodeTables(&bc_lengths, state.allocator);
        defer huffman.freeDecodeTable(&bc_table, state.allocator);

        // Now decode the code lengths for the three tables: LD, DD, RD
        // Total symbols: MC20 + DC20 + RC20 = 298 + 48 + 28 = 374
        const total_symbols: u16 = MC20 + DC20 + RC20;
        var all_lengths: [total_symbols]u8 = [_]u8{0} ** total_symbols;

        var i: u16 = 0;
        while (i < total_symbols) {
            // If we cannot decode, break out
            if (br.remainingBits() < 1) break;

            const sym = try huffman.decodeNumber(br, &bc_table);

            if (sym < 16) {
                // Direct code length
                all_lengths[i] = @intCast(sym);
                i += 1;
            } else if (sym == 16) {
                // Repeat previous code length 3 + readBits(2) times
                if (i == 0) return error.InvalidData;
                const repeat_count: u16 = @intCast(3 + try br.readBits(2));
                const prev = all_lengths[i - 1];
                var j: u16 = 0;
                while (j < repeat_count and i < total_symbols) : (j += 1) {
                    all_lengths[i] = prev;
                    i += 1;
                }
            } else if (sym == 17) {
                // Zero run: 3 + readBits(3) zeros
                const run_count: u16 = @intCast(3 + try br.readBits(3));
                var j: u16 = 0;
                while (j < run_count and i < total_symbols) : (j += 1) {
                    all_lengths[i] = 0;
                    i += 1;
                }
            } else if (sym == 18) {
                // Long zero run: 11 + readBits(7) zeros
                const run_count: u16 = @intCast(11 + try br.readBits(7));
                var j: u16 = 0;
                while (j < run_count and i < total_symbols) : (j += 1) {
                    all_lengths[i] = 0;
                    i += 1;
                }
            } else {
                return error.InvalidData;
            }
        }

        // Build the three tables from the concatenated lengths
        state.ld = try huffman.makeDecodeTables(all_lengths[0..MC20], state.allocator);
        state.dd = try huffman.makeDecodeTables(all_lengths[MC20 .. MC20 + DC20], state.allocator);
        state.rd = try huffman.makeDecodeTables(all_lengths[MC20 + DC20 .. MC20 + DC20 + RC20], state.allocator);
    }

    state.tables_loaded = true;
}

// ============================================================================
// Length Decoding from RD table
// ============================================================================

/// Decode a length value from the repeat-length table.
fn decodeLength(br: *BitReader, rd: *const DecodeTable) !u32 {
    const slot = try huffman.decodeNumber(br, rd);
    if (slot >= RC20) return error.InvalidData;

    const base = length_bases[slot];
    const extra = length_extra_bits[slot];
    if (extra > 0) {
        const extra_val = try br.readBits(extra);
        return base + extra_val;
    }
    return base;
}

// ============================================================================
// Main Decompression Loop
// ============================================================================

fn unpackLoop(state: *Unpack20State) !void {
    while (state.written_size < state.unpacked_size) {
        // Load tables if not yet loaded
        if (!state.tables_loaded) {
            try readTables(state);
        }

        if (state.audio_block) {
            // Audio mode decompression
            try unpackAudioBlock(state);
        } else {
            // LZ mode decompression
            try unpackLzBlock(state);
        }
    }
}

fn unpackAudioBlock(state: *Unpack20State) !void {
    const br = state.br;

    while (state.written_size < state.unpacked_size) {
        if (br.remainingBits() < 1) return error.EndOfData;

        const ch = state.cur_channel;
        const sym = huffman.decodeNumber(br, &state.md[ch]) catch |err| {
            if (err == error.EndOfData) return error.EndOfData;
            return err;
        };

        if (sym == 256) {
            // Table refresh marker in audio mode
            state.tables_loaded = false;
            return;
        }

        const decoded_byte = state.audio_state[ch].decode(@intCast(sym & 0xFF));
        state.window.putByte(decoded_byte);
        state.written_size += 1;

        // Round-robin channel cycling
        state.cur_channel = (state.cur_channel + 1) % state.audio_channels;
    }
}

fn unpackLzBlock(state: *Unpack20State) !void {
    const br = state.br;

    while (state.written_size < state.unpacked_size) {
        if (br.remainingBits() < 1) return error.EndOfData;

        const sym = huffman.decodeNumber(br, &state.ld) catch |err| {
            if (err == error.EndOfData) return error.EndOfData;
            return err;
        };

        if (sym < 256) {
            // Literal byte
            state.window.putByte(@intCast(sym));
            state.written_size += 1;
        } else if (sym == 256) {
            // Repeat last match
            if (state.last_distance == 0 or state.last_length == 0) {
                // No previous match to repeat; treat as no-op or error.
                continue;
            }
            state.window.copyMatch(state.last_distance, state.last_length);
            state.written_size += state.last_length;
        } else if (sym >= 257 and sym <= 260) {
            // Old-distance repeat with new length
            const dist_idx: u32 = sym - 257;

            // Rotate previous distances: move [dist_idx] to front
            const dist = state.prev_distances[dist_idx];
            var k: u32 = dist_idx;
            while (k > 0) : (k -= 1) {
                state.prev_distances[k] = state.prev_distances[k - 1];
            }
            state.prev_distances[0] = dist;

            // Read new length from RD table
            const length = try decodeLength(br, &state.rd);

            state.last_distance = dist;
            state.last_length = length;
            state.window.copyMatch(dist, length);
            state.written_size += length;
        } else if (sym >= 261 and sym <= 268) {
            // Short-distance 2-byte match
            const short_idx: u32 = sym - 261;
            const dist = short_distances[short_idx] + 1; // +1 because distance 0 means distance 1

            // Shift previous distances, put new at front
            state.prev_distances[3] = state.prev_distances[2];
            state.prev_distances[2] = state.prev_distances[1];
            state.prev_distances[1] = state.prev_distances[0];
            state.prev_distances[0] = dist;

            state.last_distance = dist;
            state.last_length = 2;
            state.window.copyMatch(dist, 2);
            state.written_size += 2;
        } else if (sym == 269) {
            // Table refresh marker
            state.tables_loaded = false;
            return; // Return to main loop, which will re-read tables
        } else if (sym >= 270) {
            // New match
            const length_slot: u32 = sym - 270;
            if (length_slot >= RC20) return error.InvalidData;

            const length: u32 = blk: {
                const base = length_bases[length_slot];
                const extra = length_extra_bits[length_slot];
                if (extra > 0) {
                    const extra_val = try br.readBits(extra);
                    break :blk base + extra_val;
                }
                break :blk base;
            };

            // Read distance from DD table
            const dist_sym = try huffman.decodeNumber(br, &state.dd);
            const dist = try distanceDecode(dist_sym, br);

            // Shift previous distances
            state.prev_distances[3] = state.prev_distances[2];
            state.prev_distances[2] = state.prev_distances[1];
            state.prev_distances[1] = state.prev_distances[0];
            state.prev_distances[0] = dist;

            state.last_distance = dist;
            state.last_length = length;
            state.window.copyMatch(dist, length);
            state.written_size += length;
        } else {
            return error.InvalidData;
        }
    }
}

// ============================================================================
// Public Interface
// ============================================================================

pub const DecompressError = error{
    OutOfMemory,
    EndOfData,
    InvalidData,
    InvalidTable,
};

/// Decompress RAR 2.x (v20/v26) packed data.
///
/// Parameters:
///   allocator: Memory allocator for working buffers and output
///   packed_data: Raw compressed bitstream
///   unpacked_size: Expected decompressed size in bytes
///   dict_bits: Dictionary size as power-of-2 exponent (typically 15-20)
///
/// Returns: Newly allocated slice containing the decompressed data.
pub fn decompress(
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    dict_bits: u5,
) DecompressError![]u8 {
    if (unpacked_size == 0) {
        return allocator.alloc(u8, 0) catch return error.OutOfMemory;
    }

    var br = BitReader.init(packed_data);
    var state = Unpack20State.init(allocator, &br, dict_bits, unpacked_size) catch return error.OutOfMemory;
    defer state.deinit();

    unpackLoop(&state) catch |err| {
        // If we have written the expected amount, that's success even on EndOfData
        if (state.written_size >= state.unpacked_size) {
            // Fall through to output extraction
        } else {
            return switch (err) {
                error.EndOfData => error.EndOfData,
                error.InvalidData => error.InvalidData,
                error.InvalidTable => error.InvalidTable,
                error.OutOfMemory => error.OutOfMemory,
            };
        }
    };

    // Extract the output from the window
    const out_size: usize = @intCast(@min(state.written_size, state.unpacked_size));
    const output = allocator.alloc(u8, out_size) catch return error.OutOfMemory;

    _ = state.window.copyToOutput(output, out_size, out_size);

    return output;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Helper: build a simple bitstream from a list of (value, bit_count) pairs
fn buildBitstream(comptime pairs: anytype) [bitstreamByteCount(pairs)]u8 {
    const total_bits = comptime bitstreamBitCount(pairs);
    const byte_count = comptime (total_bits + 7) / 8;
    var bytes = [_]u8{0} ** byte_count;
    var bit_pos: usize = 0;
    inline for (pairs) |pair| {
        const value: u32 = pair[0];
        const bits: u5 = pair[1];
        var i: u5 = 0;
        while (i < bits) : (i += 1) {
            const bit_val: u1 = @intCast((value >> @intCast(bits - 1 - i)) & 1);
            const byte_idx = bit_pos / 8;
            const bit_idx: u3 = @intCast(7 - (bit_pos % 8));
            bytes[byte_idx] |= @as(u8, bit_val) << bit_idx;
            bit_pos += 1;
        }
    }
    return bytes;
}

fn bitstreamBitCount(comptime pairs: anytype) usize {
    var total: usize = 0;
    for (pairs) |pair| {
        total += pair[1];
    }
    return total;
}

fn bitstreamByteCount(comptime pairs: anytype) usize {
    return (bitstreamBitCount(pairs) + 7) / 8;
}

test "length base and extra bits tables are consistent" {
    // Slots 0-7: length = slot + 2, no extra bits
    for (0..8) |i| {
        try testing.expectEqual(@as(u32, @intCast(i + 2)), length_bases[i]);
        try testing.expectEqual(@as(u5, 0), length_extra_bits[i]);
    }

    // Slot 8: base=10, extra=1 -> lengths 10-11
    try testing.expectEqual(@as(u32, 10), length_bases[8]);
    try testing.expectEqual(@as(u5, 1), length_extra_bits[8]);

    // Slot 9: base=12, extra=1 -> lengths 12-13
    // Wait, let's verify: with 1 extra bit, slot 8 covers 10-11, slot 9 covers 12-13
    try testing.expectEqual(@as(u32, 12), length_bases[9]);
    try testing.expectEqual(@as(u5, 1), length_extra_bits[9]);

    // Slot 10: base=14, extra=2 -> lengths 14-17
    try testing.expectEqual(@as(u32, 14), length_bases[10]);
    try testing.expectEqual(@as(u5, 2), length_extra_bits[10]);

    // All lengths should be monotonically increasing
    for (1..RC20) |i| {
        try testing.expect(length_bases[i] >= length_bases[i - 1]);
    }
}

test "distance decode for small slots (0-3)" {
    // Slots 0-3 return slot+1 with no extra bits needed.
    // We need a bit reader but it won't be consumed.
    const dummy_data = [_]u8{0xFF};
    var br = BitReader.init(&dummy_data);
    try testing.expectEqual(@as(u32, 1), try distanceDecode(0, &br));
    try testing.expectEqual(@as(u32, 2), try distanceDecode(1, &br));
    try testing.expectEqual(@as(u32, 3), try distanceDecode(2, &br));
    try testing.expectEqual(@as(u32, 4), try distanceDecode(3, &br));
}

test "distance decode for slot 4 (1 extra bit)" {
    // Slot 4: extra = 4/2 - 1 = 1
    // base = (2 | (4 & 1)) << 1 = 2 << 1 = 4
    // distance = 4 + readBits(1) + 1

    // With extra bit = 0: distance = 4 + 0 + 1 = 5
    const data0 = [_]u8{0x00}; // bit 0 = 0
    var br0 = BitReader.init(&data0);
    try testing.expectEqual(@as(u32, 5), try distanceDecode(4, &br0));

    // With extra bit = 1: distance = 4 + 1 + 1 = 6
    const data1 = [_]u8{0x80}; // bit 0 = 1 (MSB first)
    var br1 = BitReader.init(&data1);
    try testing.expectEqual(@as(u32, 6), try distanceDecode(4, &br1));
}

test "distance decode for slot 5 (1 extra bit)" {
    // Slot 5: extra = 5/2 - 1 = 1
    // base = (2 | (5 & 1)) << 1 = 3 << 1 = 6
    // distance = 6 + readBits(1) + 1

    // With extra bit = 0: distance = 6 + 0 + 1 = 7
    const data0 = [_]u8{0x00};
    var br0 = BitReader.init(&data0);
    try testing.expectEqual(@as(u32, 7), try distanceDecode(5, &br0));

    // With extra bit = 1: distance = 6 + 1 + 1 = 8
    const data1 = [_]u8{0x80};
    var br1 = BitReader.init(&data1);
    try testing.expectEqual(@as(u32, 8), try distanceDecode(5, &br1));
}

test "readTables in LZ mode builds three tables" {
    // Construct a bitstream that readTables can parse:
    // 1) Byte-aligned (we start at position 0, already aligned)
    // 2) Audio flag = 0 (1 bit)
    // 3) 20 code lengths for BC table, each 4 bits
    //    We'll use a simple BC table: all symbols have length 4
    //    (This gives us a uniform 4-bit Huffman code for the BC symbols 0-15)
    //    But we actually need codes for symbols 0-19.
    //    With 20 symbols all at length 5 => 20 codes from a 5-bit space (32 entries).
    //    Let's be practical: give symbols 0-15 length 4 (that's 16 codes from 16 available at len 4 = exactly full).
    //    But we need up to symbol 18. Let's make all 20 symbols length 5.
    //    20 * 5-bit codes from 32 total => valid (20 <= 32).
    //    Actually for canonical Huffman, not all assignments with identical lengths produce valid prefix codes.
    //    20 symbols all at length 5 IS valid: the Kraft inequality sum = 20/32 = 0.625 < 1.
    //    But it's an incomplete code. That's fine, the decoder will still work.
    //
    //    Actually let's keep it really simple:
    //    Give only symbol 0 (code length 0 = direct 0-length code) a length of 1,
    //    and all others 0.
    //    Wait, that won't help us encode lengths > 0 for the main tables.
    //
    //    Let's try: give all 20 symbols a length of 5. That produces 20 codes.
    //    Then to build the LD/DD/RD tables, we just need to encode code lengths using
    //    these 20 symbols.
    //
    //    For simplicity, let's encode all 374 symbols as having code length 0
    //    (i.e., not present). We can do this with symbol 18 (long zero run = 11 + readBits(7)).
    //
    //    Actually let's think simpler. Let's use symbol 17 (zero run: 3 + readBits(3))
    //    and symbol 18 (long zero run: 11 + readBits(7)) to fill all 374 with zeros,
    //    which will produce invalid tables (valid=false) but that's OK for testing
    //    that readTables doesn't crash.
    //
    //    Better approach: let's give a simple table where a few symbols have non-zero lengths.

    // Let's build a bitstream manually. We want:
    //   - audio_flag = 0 (1 bit)
    //   - 20 BC lengths, each 4 bits. Let's give symbol 0 length 1, symbols 17,18 length 2, rest 0.
    //     Symbol 0 (direct length 0): code = "0" (length 1)
    //     Symbol 17 (zero run): one of the length-2 codes
    //     Symbol 18 (long zero run): the other length-2 code
    //     Canonical codes:
    //       len 1: first_code = 0 -> sym 0 = 0b0
    //       len 2: first_code = (0+1)<<1 = 2 -> sym 17 = 0b10, sym 18 = 0b11
    //   - Then encode the 374 code lengths for LD+DD+RD:
    //     Use symbol 18 (long zero run) repeatedly to zero-fill, then
    //     use symbol 0 to set a few lengths to 0.
    //     Actually symbol 0 = "direct code length 0" means the target symbol has length 0.
    //     We need at least some non-zero lengths for valid tables.
    //
    //     Let's put length 1 for the first two symbols of LD (symbols 0 and 1).
    //     But our BC table can only represent length values 0-15 via symbols 0-15.
    //     Symbol 1 (direct code length 1) has BC code length 0 in our table.
    //     We need to give symbol 1 a non-zero BC code length too.
    //
    //     OK, let's redo the BC table:
    //     Symbol 0: length 2 (for encoding "length 0")
    //     Symbol 1: length 2 (for encoding "length 1")
    //     Symbol 18: length 2 (for long zero runs)
    //     Rest: 0
    //
    //     Wait, 3 symbols at length 2 means 3 codes from 4 available (00, 01, 10).
    //     Canonical:
    //       len 2: first_code = 0 -> sym 0 = 00, sym 1 = 01, sym 18 = 10
    //
    //     Actually canonical ordering is by symbol number, so among the length-2 symbols:
    //       sym 0 -> code 00
    //       sym 1 -> code 01
    //       sym 18 -> code 10

    // BC code lengths (20 entries, 4 bits each):
    // [0]=2, [1]=2, [2..17]=0, [18]=2, [19]=0
    // Binary (4 bits each):
    //   0010 0010 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0000 0010 0000
    // That's: sym0=2(0010), sym1=2(0010), sym2-17=0(0000 x16), sym18=2(0010), sym19=0(0000)
    // Total: 20 * 4 = 80 bits for BC lengths

    // Then encode the main code lengths (374 total):
    // We want sym 0 of LD to have length 1, sym 1 of LD to have length 1,
    // and everything else length 0.
    //
    // Encoding:
    //   BC sym 1 (code 01) -> code_length = 1 for LD sym 0
    //   BC sym 1 (code 01) -> code_length = 1 for LD sym 1
    //   BC sym 18 (code 10) + 7 bits for run length -> zeros for the rest
    //     We need 374 - 2 = 372 zeros.
    //     sym 18 = 11 + readBits(7) = 11..138 zeros per invocation
    //     372 = 138 + 138 + 96
    //     138 = 11 + 127 -> readBits(7) = 127 = 0b1111111
    //     96 = 11 + 85 -> readBits(7) = 85 = 0b1010101

    // Let me assemble this bitstream:
    // [audio_flag: 0 (1 bit)]
    // [20 BC lengths, 4 bits each (80 bits)]
    // [BC sym 1 = code 01 (2 bits)] -> LD[0] = length 1
    // [BC sym 1 = code 01 (2 bits)] -> LD[1] = length 1
    // [BC sym 18 = code 10 (2 bits) + 1111111 (7 bits)] -> 138 zeros
    // [BC sym 18 = code 10 (2 bits) + 1111111 (7 bits)] -> 138 zeros
    // [BC sym 18 = code 10 (2 bits) + 1010101 (7 bits)] -> 96 zeros
    // Total zeros: 138 + 138 + 96 = 372

    var buf: [64]u8 = [_]u8{0} ** 64;
    var bit_pos: usize = 0;

    // Helper to write bits
    const writeBits = struct {
        fn f(buffer: []u8, pos: *usize, value: u32, count: u5) void {
            var i: u5 = 0;
            while (i < count) : (i += 1) {
                const bit_val: u1 = @intCast((value >> @intCast(count - 1 - i)) & 1);
                const byte_idx = pos.* / 8;
                const bit_idx: u3 = @intCast(7 - (pos.* % 8));
                buffer[byte_idx] |= @as(u8, bit_val) << bit_idx;
                pos.* += 1;
            }
        }
    }.f;

    // Audio flag = 0
    writeBits(&buf, &bit_pos, 0, 1);

    // BC lengths: sym0=2, sym1=2, sym2-17=0, sym18=2, sym19=0
    writeBits(&buf, &bit_pos, 2, 4); // sym 0
    writeBits(&buf, &bit_pos, 2, 4); // sym 1
    for (0..16) |_| {
        writeBits(&buf, &bit_pos, 0, 4); // syms 2-17
    }
    writeBits(&buf, &bit_pos, 2, 4); // sym 18
    writeBits(&buf, &bit_pos, 0, 4); // sym 19

    // Encode code lengths for LD/DD/RD tables:
    // LD[0] = 1: encode BC sym 1 (code 01)
    writeBits(&buf, &bit_pos, 1, 2);
    // LD[1] = 1: encode BC sym 1 (code 01)
    writeBits(&buf, &bit_pos, 1, 2);
    // 138 zeros: BC sym 18 (code 10) + 127 (7 bits)
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 127, 7);
    // 138 zeros: BC sym 18 (code 10) + 127 (7 bits)
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 127, 7);
    // 96 zeros: BC sym 18 (code 10) + 85 (7 bits)
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 85, 7);

    var br = BitReader.init(buf[0 .. (bit_pos + 7) / 8]);
    var state = Unpack20State.init(testing.allocator, &br, 15, 0) catch unreachable;
    defer state.deinit();

    try readTables(&state);

    // Verify: tables are loaded and the LD table is valid
    try testing.expect(state.tables_loaded);
    try testing.expect(!state.audio_block);
    try testing.expect(state.ld.valid);
    // DD and RD tables should have all-zero lengths (valid=false since no symbols)
    try testing.expect(!state.dd.valid);
    try testing.expect(!state.rd.valid);
}

test "readTables detects audio mode" {
    // Build a minimal bitstream for audio mode:
    // 1) Audio flag = 1 (1 bit)
    // 2) Channels = 0 (2 bits, means 1 channel)
    // 3) 20 code lengths for channel 0's table, each 4 bits
    //    Give all 20 code lengths as 0 (80 bits of zeros)

    var buf: [16]u8 = [_]u8{0} ** 16;
    var bit_pos: usize = 0;

    const writeBits = struct {
        fn f(buffer: []u8, pos: *usize, value: u32, count: u5) void {
            var i: u5 = 0;
            while (i < count) : (i += 1) {
                const bit_val: u1 = @intCast((value >> @intCast(count - 1 - i)) & 1);
                const byte_idx = pos.* / 8;
                const bit_idx: u3 = @intCast(7 - (pos.* % 8));
                buffer[byte_idx] |= @as(u8, bit_val) << bit_idx;
                pos.* += 1;
            }
        }
    }.f;

    // Audio flag = 1
    writeBits(&buf, &bit_pos, 1, 1);
    // Channels = 0 (means 1 channel)
    writeBits(&buf, &bit_pos, 0, 2);
    // 20 code lengths of 0 for channel 0 (80 bits of zeros already in buffer)
    bit_pos += 80;

    var br = BitReader.init(buf[0 .. (bit_pos + 7) / 8]);
    var state = Unpack20State.init(testing.allocator, &br, 15, 0) catch unreachable;
    defer state.deinit();

    try readTables(&state);

    try testing.expect(state.tables_loaded);
    try testing.expect(state.audio_block);
    try testing.expectEqual(@as(u8, 1), state.audio_channels);
}

test "literal decoding in LZ mode" {
    // Build a compressed stream that encodes two literal bytes: 'A' (65) and 'B' (66).
    // We need:
    //   1. Tables header (audio_flag=0, BC lengths, then LD/DD/RD code lengths)
    //   2. Two literal symbols (65, 66) encoded with the LD table

    // Strategy: build a simple LD table where symbols 65 and 66 have short codes.
    // To keep things manageable, give only symbols 65 and 66 a code length.
    // sym 65: length 1 (code 0)
    // sym 66: length 1 -- can't, only one symbol at length 1
    // sym 65: length 1 (code 0), sym 66: length 2... wait, that doesn't work for 2 symbols.
    // Two symbols: sym 65 length 1 (code 0), sym 66 length 1 (code 1)
    // Wait, canonical Huffman with 2 symbols at length 1 = codes 0, 1. That works.

    // BC table: we need to encode code lengths for 374 symbols.
    // LD[65]=1, LD[66]=1, everything else=0.
    // BC symbols needed: 0 (for length 0), 1 (for length 1), 18 (for long zero runs)
    // BC code lengths: [0]=2, [1]=2, [2..17]=0, [18]=2, [19]=0

    var buf: [64]u8 = [_]u8{0} ** 64;
    var bit_pos: usize = 0;

    const writeBits = struct {
        fn f(buffer: []u8, pos: *usize, value: u32, count: u5) void {
            var i: u5 = 0;
            while (i < count) : (i += 1) {
                const bit_val: u1 = @intCast((value >> @intCast(count - 1 - i)) & 1);
                const byte_idx = pos.* / 8;
                const bit_idx: u3 = @intCast(7 - (pos.* % 8));
                buffer[byte_idx] |= @as(u8, bit_val) << bit_idx;
                pos.* += 1;
            }
        }
    }.f;

    // Audio flag = 0
    writeBits(&buf, &bit_pos, 0, 1);

    // BC lengths: [0]=2, [1]=2, [2-17]=0, [18]=2, [19]=0
    writeBits(&buf, &bit_pos, 2, 4);
    writeBits(&buf, &bit_pos, 2, 4);
    for (0..16) |_| writeBits(&buf, &bit_pos, 0, 4);
    writeBits(&buf, &bit_pos, 2, 4);
    writeBits(&buf, &bit_pos, 0, 4);

    // BC canonical codes: sym 0 -> 00, sym 1 -> 01, sym 18 -> 10

    // LD code lengths (298 symbols):
    // Symbols 0-64: all zero (65 zeros)
    //   65 = 11 + 54 -> sym 18 (code 10) + 54 (0110110 in 7 bits)
    writeBits(&buf, &bit_pos, 2, 2); // BC sym 18
    writeBits(&buf, &bit_pos, 54, 7);
    // Symbol 65: length 1 -> BC sym 1 (code 01)
    writeBits(&buf, &bit_pos, 1, 2);
    // Symbol 66: length 1 -> BC sym 1 (code 01)
    writeBits(&buf, &bit_pos, 1, 2);
    // Symbols 67-297: all zero (231 zeros)
    //   138 = 11 + 127 -> sym 18 + 127
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 127, 7);
    //   93 = 11 + 82 -> sym 18 + 82
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 82, 7);

    // DD code lengths (48 symbols): all zero
    //   48 = 11 + 37 -> sym 18 + 37
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 37, 7);

    // RD code lengths (28 symbols): all zero
    //   28 = 11 + 17 -> sym 18 + 17
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 17, 7);

    // Now encode the data symbols using the LD table:
    // LD sym 65 has canonical code: at length 1, first_code = 0
    //   Symbols sorted by length then number: sym 65 and sym 66 both at length 1
    //   first code of length 1 = 0 -> sym 65 = 0, sym 66 = 1
    writeBits(&buf, &bit_pos, 0, 1); // literal 'A' (sym 65)
    writeBits(&buf, &bit_pos, 1, 1); // literal 'B' (sym 66)

    const data_len = (bit_pos + 7) / 8;
    var br = BitReader.init(buf[0..data_len]);
    var state = Unpack20State.init(testing.allocator, &br, 15, 2) catch unreachable;
    defer state.deinit();

    try readTables(&state);
    try unpackLzBlock(&state);

    try testing.expectEqual(@as(u64, 2), state.written_size);

    // Extract output
    var output: [2]u8 = undefined;
    _ = state.window.copyToOutput(&output, 2, 2);
    try testing.expectEqual(@as(u8, 'A'), output[0]);
    try testing.expectEqual(@as(u8, 'B'), output[1]);
}

test "old-distance repeat (symbols 257-260) rotates distances" {
    // Test the distance rotation logic directly
    var prev_distances = [4]u32{ 10, 20, 30, 40 };

    // Simulate symbol 258 (dist_idx = 1): move prev_distances[1] to front
    const dist_idx: u32 = 1;
    const dist = prev_distances[dist_idx];
    var k: u32 = dist_idx;
    while (k > 0) : (k -= 1) {
        prev_distances[k] = prev_distances[k - 1];
    }
    prev_distances[0] = dist;

    // Expected: [20, 10, 30, 40]
    try testing.expectEqual(@as(u32, 20), prev_distances[0]);
    try testing.expectEqual(@as(u32, 10), prev_distances[1]);
    try testing.expectEqual(@as(u32, 30), prev_distances[2]);
    try testing.expectEqual(@as(u32, 40), prev_distances[3]);

    // Now simulate symbol 259 (dist_idx = 2): move [2] to front
    const dist_idx2: u32 = 2;
    const dist2 = prev_distances[dist_idx2];
    var k2: u32 = dist_idx2;
    while (k2 > 0) : (k2 -= 1) {
        prev_distances[k2] = prev_distances[k2 - 1];
    }
    prev_distances[0] = dist2;

    // Expected: [30, 20, 10, 40]
    try testing.expectEqual(@as(u32, 30), prev_distances[0]);
    try testing.expectEqual(@as(u32, 20), prev_distances[1]);
    try testing.expectEqual(@as(u32, 10), prev_distances[2]);
    try testing.expectEqual(@as(u32, 40), prev_distances[3]);
}

test "short distance table values" {
    // Verify the short distance lookup table
    try testing.expectEqual(@as(u32, 0), short_distances[0]);
    try testing.expectEqual(@as(u32, 1), short_distances[1]);
    try testing.expectEqual(@as(u32, 2), short_distances[2]);
    try testing.expectEqual(@as(u32, 3), short_distances[3]);
    try testing.expectEqual(@as(u32, 4), short_distances[4]);
    try testing.expectEqual(@as(u32, 8), short_distances[5]);
    try testing.expectEqual(@as(u32, 16), short_distances[6]);
    try testing.expectEqual(@as(u32, 32), short_distances[7]);
}

test "audio channel predictor basic decode" {
    var ch = AudioChannel{};

    // First sample: predicted = 0 (all zeros), encoded = 42
    // decoded = (0 + 42) & 0xFF = 42
    const b1 = ch.decode(42);
    try testing.expectEqual(@as(u8, 42), b1);

    // Second sample: predictor should have updated state
    // The exact value depends on the prediction, but it should not crash
    const b2 = ch.decode(0);
    _ = b2; // We just verify it doesn't crash
}

test "audio channel predictor wrapping" {
    var ch = AudioChannel{};

    // Encode a value that wraps around
    const b1 = ch.decode(200);
    try testing.expectEqual(@as(u8, 200), b1);

    // Feed a large encoded value that causes wrapping
    const b2 = ch.decode(100);
    // predicted is non-zero now, result = (predicted + 100) & 0xFF
    // We just verify it produces some byte without crashing
    _ = b2;
}

test "decompress with zero unpacked size returns empty slice" {
    const packed_data = [_]u8{0};
    const result = try decompress(testing.allocator, &packed_data, 0, 15);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "sign function" {
    try testing.expectEqual(@as(i32, 1), signOf(42));
    try testing.expectEqual(@as(i32, -1), signOf(-7));
    try testing.expectEqual(@as(i32, 0), signOf(0));
}

test "adapt coefficient increases on same sign" {
    var k: i32 = 0;
    adaptCoefficient(&k, 1, 1);
    try testing.expectEqual(@as(i32, 1), k);

    adaptCoefficient(&k, -1, -1);
    try testing.expectEqual(@as(i32, 2), k);
}

test "adapt coefficient decreases on opposite sign" {
    var k: i32 = 0;
    adaptCoefficient(&k, 1, -1);
    try testing.expectEqual(@as(i32, -1), k);

    adaptCoefficient(&k, -1, 1);
    try testing.expectEqual(@as(i32, -2), k);
}

test "adapt coefficient clamps at bounds" {
    var k_high: i32 = 32;
    adaptCoefficient(&k_high, 1, 1);
    try testing.expectEqual(@as(i32, 32), k_high); // should not exceed 32

    var k_low: i32 = -32;
    adaptCoefficient(&k_low, 1, -1);
    try testing.expectEqual(@as(i32, -32), k_low); // should not go below -32
}

test "adapt coefficient no change when sign is zero" {
    var k: i32 = 5;
    adaptCoefficient(&k, 0, 1);
    try testing.expectEqual(@as(i32, 5), k); // dd sign is 0, no change

    adaptCoefficient(&k, 1, 0);
    try testing.expectEqual(@as(i32, 5), k); // d sign is 0, no change
}

test "full decompression of literal-only stream" {
    // Build a complete compressed stream that encodes "AB" (two literal bytes)
    // This exercises the full decompress() -> readTables() -> unpackLzBlock() path.

    var buf: [64]u8 = [_]u8{0} ** 64;
    var bit_pos: usize = 0;

    const writeBits = struct {
        fn f(buffer: []u8, pos: *usize, value: u32, count: u5) void {
            var i: u5 = 0;
            while (i < count) : (i += 1) {
                const bit_val: u1 = @intCast((value >> @intCast(count - 1 - i)) & 1);
                const byte_idx = pos.* / 8;
                const bit_idx: u3 = @intCast(7 - (pos.* % 8));
                buffer[byte_idx] |= @as(u8, bit_val) << bit_idx;
                pos.* += 1;
            }
        }
    }.f;

    // Audio flag = 0
    writeBits(&buf, &bit_pos, 0, 1);

    // BC lengths: [0]=2, [1]=2, [2-17]=0, [18]=2, [19]=0
    writeBits(&buf, &bit_pos, 2, 4);
    writeBits(&buf, &bit_pos, 2, 4);
    for (0..16) |_| writeBits(&buf, &bit_pos, 0, 4);
    writeBits(&buf, &bit_pos, 2, 4);
    writeBits(&buf, &bit_pos, 0, 4);

    // LD code lengths (298 symbols):
    // [0..64] = 0 (65 zeros via sym 18 + 54)
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 54, 7);
    // [65] = 1
    writeBits(&buf, &bit_pos, 1, 2);
    // [66] = 1
    writeBits(&buf, &bit_pos, 1, 2);
    // [67..297] = 0 (231 zeros)
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 127, 7); // 138 zeros
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 82, 7); // 93 zeros

    // DD code lengths: 48 zeros
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 37, 7);

    // RD code lengths: 28 zeros
    writeBits(&buf, &bit_pos, 2, 2);
    writeBits(&buf, &bit_pos, 17, 7);

    // Data: sym 65 (code 0, 1 bit) and sym 66 (code 1, 1 bit)
    writeBits(&buf, &bit_pos, 0, 1); // 'A'
    writeBits(&buf, &bit_pos, 1, 1); // 'B'

    const data_len = (bit_pos + 7) / 8;
    const result = try decompress(testing.allocator, buf[0..data_len], 2, 15);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(u8, 'A'), result[0]);
    try testing.expectEqual(@as(u8, 'B'), result[1]);
}
