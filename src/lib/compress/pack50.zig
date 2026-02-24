const std = @import("std");
const BitWriter = @import("bitwriter.zig").BitWriter;
const huff_enc = @import("huffman_encoder.zig");
const slot_tables = @import("slot_tables.zig");
const match_finder = @import("match_finder.zig");
const LzToken = match_finder.LzToken;

// Import decoder constants for alphabet sizes
const unpack50 = @import("../decompress/unpack50.zig");
const NC: u16 = unpack50.NC; // 306
const DC: u16 = unpack50.DC_RAR5; // 64
const LDC: u16 = unpack50.LDC; // 16
const RC: u16 = unpack50.RC; // 44

const CODE_LENGTH_SYMBOLS: u16 = 20;

/// Compress input data into a RAR5 compressed block.
/// Returns the compressed block data (caller must free).
///
/// The output contains: block_header + Huffman_tables + compressed_symbols
/// This can be directly placed in a RAR5 file block's data area.
pub fn compressBlock(
    allocator: std.mem.Allocator,
    data: []const u8,
    level: u3,
    is_last_block: bool,
) ![]u8 {
    // Step 1: Run match finder to produce LZ token stream
    const window_size: u32 = 1 << 20; // 1MB dictionary
    var mf = try match_finder.MatchFinder.init(allocator, window_size, level);
    defer mf.deinit();

    const raw_tokens = try mf.compress(data, allocator);
    defer allocator.free(raw_tokens);

    // Step 1b: Replace matches whose adjusted length < 2 with literals.
    // RAR5 subtracts a distance-dependent bonus on decode (up to +3 for large distances),
    // so the encoder must subtract it before encoding. If that makes the length < 2,
    // the match is unencodable — emit the original bytes as literals instead.
    var filtered = std.ArrayList(LzToken).empty;
    defer filtered.deinit(allocator);
    {
        var data_pos: usize = 0;
        for (raw_tokens) |tok| {
            switch (tok) {
                .literal => {
                    try filtered.append(allocator, tok);
                    data_pos += 1;
                },
                .match => |m| {
                    const adj_len = slot_tables.adjustLengthForDistance(m.length, m.distance);
                    if (adj_len < 2) {
                        // Unencodable after distance bonus adjustment — emit as literals
                        for (0..m.length) |i| {
                            try filtered.append(allocator, .{ .literal = data[data_pos + i] });
                        }
                    } else {
                        try filtered.append(allocator, tok);
                    }
                    data_pos += m.length;
                },
            }
        }
    }
    const tokens = filtered.items;

    // Step 2: Count frequencies for all alphabets
    var ld_freq: [NC]u32 = [_]u32{0} ** NC;
    var dd_freq: [DC]u32 = [_]u32{0} ** DC;
    var ldd_freq: [LDC]u32 = [_]u32{0} ** LDC;
    var rd_freq: [RC]u32 = [_]u32{0} ** RC;

    // Track previous distances for repeat-distance optimization
    var prev_distances: [4]u32 = .{ 0, 0, 0, 0 };

    // Pre-scan tokens to collect frequencies
    for (tokens) |tok| {
        switch (tok) {
            .literal => |byte| {
                ld_freq[byte] += 1;
            },
            .match => |m| {
                // Check for repeat distances
                const repeat_idx = findRepeatDistance(prev_distances, m.distance);
                if (repeat_idx) |idx| {
                    if (idx == 0) {
                        // Symbol 257: repeat last match (same distance, same length)
                        // We'd need to know if length matches too - use prior distance instead
                        ld_freq[258 + idx] += 1;
                    } else {
                        ld_freq[258 + idx] += 1;
                    }
                    // Rotate distances
                    rotatePrevDistances(&prev_distances, idx);
                    // Length goes to RD table
                    const adj_len = slot_tables.adjustLengthForDistance(m.length, m.distance);
                    const len_enc = slot_tables.encodeLengthSlot(adj_len);
                    rd_freq[len_enc.slot] += 1;
                } else {
                    // New match: symbol 262+slot
                    const adj_len = slot_tables.adjustLengthForDistance(m.length, m.distance);
                    const len_enc = slot_tables.encodeLengthSlot(adj_len);
                    ld_freq[262 + len_enc.slot] += 1;

                    // Distance
                    const dist_enc = slot_tables.encodeDistanceSlot(m.distance);
                    dd_freq[dist_enc.dd_slot] += 1;
                    if (dist_enc.use_ldd) {
                        ldd_freq[dist_enc.ldd_value] += 1;
                    }

                    // Update prev distances
                    prev_distances[3] = prev_distances[2];
                    prev_distances[2] = prev_distances[1];
                    prev_distances[1] = prev_distances[0];
                    prev_distances[0] = m.distance;
                }
            },
        }
    }

    // Ensure at least one symbol has a non-zero frequency in each table
    // (a table with all zeros is invalid for the decoder)
    ensureMinFreq(&ld_freq);
    ensureMinFreqSlice(&dd_freq);
    ensureMinFreqSlice(&ldd_freq);
    ensureMinFreqSlice(&rd_freq);

    // Step 3: Compute Huffman code lengths and canonical codes
    var ld_lengths: [NC]u8 = undefined;
    var dd_lengths: [DC]u8 = undefined;
    var ldd_lengths: [LDC]u8 = undefined;
    var rd_lengths: [RC]u8 = undefined;

    huff_enc.computeCodeLengths(&ld_freq, 15, &ld_lengths);
    huff_enc.computeCodeLengths(&dd_freq, 15, &dd_lengths);
    huff_enc.computeCodeLengths(&ldd_freq, 15, &ldd_lengths);
    huff_enc.computeCodeLengths(&rd_freq, 15, &rd_lengths);

    var ld_codes: [NC]u32 = undefined;
    var dd_codes: [DC]u32 = undefined;
    var ldd_codes: [LDC]u32 = undefined;
    var rd_codes: [RC]u32 = undefined;

    huff_enc.computeCanonicalCodes(&ld_lengths, &ld_codes);
    huff_enc.computeCanonicalCodes(&dd_lengths, &dd_codes);
    huff_enc.computeCanonicalCodes(&ldd_lengths, &ldd_codes);
    huff_enc.computeCanonicalCodes(&rd_lengths, &rd_codes);

    // Step 4: Build the block data (tables + compressed symbols)
    // Allocate generous output buffer
    const max_output = data.len * 2 + 8192; // worst-case: incompressible data expands under Huffman
    const output = try allocator.alloc(u8, max_output);
    errdefer allocator.free(output);

    var bw = BitWriter.init(output);

    // Step 4a: Write CL code lengths (20 x 4-bit values with value-15 zero-run encoding)
    try writeCLLengths(&bw, &ld_lengths, &dd_lengths, &ldd_lengths, &rd_lengths);

    // Step 4b: Write main code lengths encoded with CL Huffman
    try writeMainCodeLengths(&bw, &ld_lengths, &dd_lengths, &ldd_lengths, &rd_lengths);

    // Step 4c: Write compressed data symbols
    prev_distances = .{ 0, 0, 0, 0 };
    for (tokens) |tok| {
        switch (tok) {
            .literal => |byte| {
                try bw.writeBits(ld_codes[byte], @intCast(ld_lengths[byte]));
            },
            .match => |m| {
                const repeat_idx = findRepeatDistance(prev_distances, m.distance);
                if (repeat_idx) |idx| {
                    // Emit repeat-distance symbol (258-261)
                    const sym: usize = 258 + idx;
                    try bw.writeBits(ld_codes[sym], @intCast(ld_lengths[sym]));
                    rotatePrevDistances(&prev_distances, idx);

                    // Emit length via RD table
                    const adj_len = slot_tables.adjustLengthForDistance(m.length, m.distance);
                    const len_enc = slot_tables.encodeLengthSlot(adj_len);
                    try bw.writeBits(rd_codes[len_enc.slot], @intCast(rd_lengths[len_enc.slot]));
                    if (len_enc.extra_bits > 0) {
                        try bw.writeBits(len_enc.extra, len_enc.extra_bits);
                    }
                } else {
                    // New match: emit LD symbol 262+slot
                    const adj_len = slot_tables.adjustLengthForDistance(m.length, m.distance);
                    const len_enc = slot_tables.encodeLengthSlot(adj_len);
                    const ld_sym: usize = 262 + len_enc.slot;
                    try bw.writeBits(ld_codes[ld_sym], @intCast(ld_lengths[ld_sym]));
                    if (len_enc.extra_bits > 0) {
                        try bw.writeBits(len_enc.extra, len_enc.extra_bits);
                    }

                    // Emit distance
                    const dist_enc = slot_tables.encodeDistanceSlot(m.distance);
                    try bw.writeBits(dd_codes[dist_enc.dd_slot], @intCast(dd_lengths[dist_enc.dd_slot]));
                    if (dist_enc.dd_extra_bits > 0) {
                        try bw.writeBits(dist_enc.dd_extra, dist_enc.dd_extra_bits);
                    }
                    if (dist_enc.use_ldd) {
                        try bw.writeBits(ldd_codes[dist_enc.ldd_value], @intCast(ldd_lengths[dist_enc.ldd_value]));
                    }

                    // Update prev distances
                    prev_distances[3] = prev_distances[2];
                    prev_distances[2] = prev_distances[1];
                    prev_distances[1] = prev_distances[0];
                    prev_distances[0] = m.distance;
                }
            },
        }
    }

    const data_total_bits = bw.totalBits();
    const data_bytes = try bw.flush();

    // Step 5: Wrap in a RAR5 block header
    return try wrapBlockHeader(allocator, output[0..data_bytes], data_total_bits, is_last_block);
}

/// Write the 20 code-length code lengths (CL table).
/// Each is 4 bits; value 15 uses special run-length encoding.
fn writeCLLengths(
    bw: *BitWriter,
    ld_lengths: *const [NC]u8,
    dd_lengths: *const [DC]u8,
    ldd_lengths: *const [LDC]u8,
    rd_lengths: *const [RC]u8,
) !void {
    // First, compute the CL code lengths by collecting frequency of
    // all code-length values in the combined alphabet
    const total_symbols = NC + DC + LDC + RC;
    var combined: [total_symbols]u8 = undefined;
    @memcpy(combined[0..NC], ld_lengths);
    @memcpy(combined[NC .. NC + DC], dd_lengths);
    @memcpy(combined[NC + DC .. NC + DC + LDC], ldd_lengths);
    @memcpy(combined[NC + DC + LDC .. NC + DC + LDC + RC], rd_lengths);

    // Encode the combined lengths into CL symbols (0-15 direct, 16-19 repeat/zero runs)
    var cl_symbols: [total_symbols * 2]CLSymbol = undefined;
    var cl_count: usize = 0;
    encodeCLSymbols(&combined, &cl_symbols, &cl_count);

    // Count CL symbol frequencies
    var cl_freq: [CODE_LENGTH_SYMBOLS]u32 = [_]u32{0} ** CODE_LENGTH_SYMBOLS;
    for (0..cl_count) |i| {
        cl_freq[cl_symbols[i].symbol] += 1;
    }
    // Ensure at least one symbol has frequency
    if (allZero(&cl_freq)) cl_freq[0] = 1;

    // Compute CL code lengths
    var cl_lengths: [CODE_LENGTH_SYMBOLS]u8 = undefined;
    huff_enc.computeCodeLengths(&cl_freq, 15, &cl_lengths);

    // Write 20 x 4-bit CL code lengths with value-15 zero-run encoding
    var i: usize = 0;
    while (i < CODE_LENGTH_SYMBOLS) {
        const len = cl_lengths[i];
        if (len == 15) {
            try bw.writeBits(15, 4); // value 15
            try bw.writeBits(0, 4); // second nibble 0 means "actual value is 15"
            i += 1;
        } else if (len == 0) {
            // Check for a run of zeros
            var run: usize = 0;
            while (i + run < CODE_LENGTH_SYMBOLS and cl_lengths[i + run] == 0) : (run += 1) {}
            if (run >= 3) {
                // Use value-15 zero-run encoding: 15 + (count-2) where count >= 3
                try bw.writeBits(15, 4);
                const count_raw: u8 = @intCast(@min(run, 18) - 2); // max 16+2=18 per encoding
                try bw.writeBits(count_raw, 4);
                i += @min(run, 18);
            } else {
                try bw.writeBits(0, 4);
                i += 1;
            }
        } else {
            try bw.writeBits(len, 4);
            i += 1;
        }
    }
}

/// A code-length symbol (used in the CL stage of encoding).
const CLSymbol = struct {
    symbol: u8, // 0-15 = direct length, 16-19 = repeat/zero
    extra: u32, // extra bits value
    extra_bits: u5, // number of extra bits
};

/// Encode combined code lengths into CL symbols with run-length encoding.
fn encodeCLSymbols(combined: []const u8, out: []CLSymbol, count: *usize) void {
    count.* = 0;
    var i: usize = 0;

    while (i < combined.len) {
        const val = combined[i];

        if (val == 0) {
            // Count zero run
            var run: usize = 0;
            while (i + run < combined.len and combined[i + run] == 0) : (run += 1) {}

            while (run > 0) {
                if (run >= 11) {
                    // Symbol 19: 11 + readBits(7) zeros = 11..138
                    const emit = @min(run, 138);
                    out[count.*] = .{ .symbol = 19, .extra = @intCast(emit - 11), .extra_bits = 7 };
                    count.* += 1;
                    run -= emit;
                    i += emit;
                } else if (run >= 3) {
                    // Symbol 18: 3 + readBits(3) zeros = 3..10
                    const emit = @min(run, 10);
                    out[count.*] = .{ .symbol = 18, .extra = @intCast(emit - 3), .extra_bits = 3 };
                    count.* += 1;
                    run -= emit;
                    i += emit;
                } else {
                    // Single zeros
                    out[count.*] = .{ .symbol = 0, .extra = 0, .extra_bits = 0 };
                    count.* += 1;
                    run -= 1;
                    i += 1;
                }
            }
        } else {
            // Non-zero: emit direct
            out[count.*] = .{ .symbol = val, .extra = 0, .extra_bits = 0 };
            count.* += 1;
            i += 1;

            // Check for repeat run of same value
            var run: usize = 0;
            while (i + run < combined.len and combined[i + run] == val) : (run += 1) {}

            while (run > 0) {
                if (run >= 11) {
                    // Symbol 17: repeat prev 11 + readBits(7) times = 11..138
                    const emit = @min(run, 138);
                    out[count.*] = .{ .symbol = 17, .extra = @intCast(emit - 11), .extra_bits = 7 };
                    count.* += 1;
                    run -= emit;
                    i += emit;
                } else if (run >= 3) {
                    // Symbol 16: repeat prev 3 + readBits(3) times = 3..10
                    const emit = @min(run, 10);
                    out[count.*] = .{ .symbol = 16, .extra = @intCast(emit - 3), .extra_bits = 3 };
                    count.* += 1;
                    run -= emit;
                    i += emit;
                } else {
                    // Individual repeats: emit as direct values
                    out[count.*] = .{ .symbol = val, .extra = 0, .extra_bits = 0 };
                    count.* += 1;
                    run -= 1;
                    i += 1;
                }
            }
        }
    }
}

/// Write the main code lengths (NC+DC+LDC+RC symbols) encoded using the CL Huffman table.
fn writeMainCodeLengths(
    bw: *BitWriter,
    ld_lengths: *const [NC]u8,
    dd_lengths: *const [DC]u8,
    ldd_lengths: *const [LDC]u8,
    rd_lengths: *const [RC]u8,
) !void {
    const total_symbols = NC + DC + LDC + RC;
    var combined: [total_symbols]u8 = undefined;
    @memcpy(combined[0..NC], ld_lengths);
    @memcpy(combined[NC .. NC + DC], dd_lengths);
    @memcpy(combined[NC + DC .. NC + DC + LDC], ldd_lengths);
    @memcpy(combined[NC + DC + LDC .. NC + DC + LDC + RC], rd_lengths);

    // Encode into CL symbols
    var cl_symbols: [total_symbols * 2]CLSymbol = undefined;
    var cl_count: usize = 0;
    encodeCLSymbols(&combined, &cl_symbols, &cl_count);

    // Recompute CL frequencies and codes (must match what we wrote in writeCLLengths)
    var cl_freq: [CODE_LENGTH_SYMBOLS]u32 = [_]u32{0} ** CODE_LENGTH_SYMBOLS;
    for (0..cl_count) |i| {
        cl_freq[cl_symbols[i].symbol] += 1;
    }
    if (allZero(&cl_freq)) cl_freq[0] = 1;

    var cl_lengths: [CODE_LENGTH_SYMBOLS]u8 = undefined;
    huff_enc.computeCodeLengths(&cl_freq, 15, &cl_lengths);

    var cl_codes: [CODE_LENGTH_SYMBOLS]u32 = undefined;
    huff_enc.computeCanonicalCodes(&cl_lengths, &cl_codes);

    // Write CL-encoded symbols
    for (0..cl_count) |i| {
        const sym = cl_symbols[i];
        try bw.writeBits(cl_codes[sym.symbol], @intCast(cl_lengths[sym.symbol]));
        if (sym.extra_bits > 0) {
            try bw.writeBits(sym.extra, sym.extra_bits);
        }
    }
}

/// Wrap block data in a RAR5 block header.
/// Returns a new allocation containing: header + block_data.
fn wrapBlockHeader(
    allocator: std.mem.Allocator,
    block_data: []const u8,
    total_bits: usize,
    is_last_block: bool,
) ![]u8 {
    const block_size: u32 = @intCast(block_data.len);
    const last_byte_bits: u8 = @intCast(if (total_bits % 8 == 0) 8 else total_bits % 8);

    // Block header:
    //   byte 0: flags
    //     bits 0-2: block_bit_size - 1
    //     bits 3-4: byte_count - 1 (number of bytes for size field)
    //     bit 6: is_last_block
    //     bit 7: table_present (always 1 for first block)
    //   byte 1: checksum = 0x5a ^ flags ^ size_bytes...
    //   bytes 2..2+byte_count: block_size (little-endian)

    // Determine byte_count needed for block_size
    const byte_count: u8 = if (block_size <= 0xFF) 1 else if (block_size <= 0xFFFF) 2 else 3;

    var flags: u8 = (last_byte_bits - 1) & 0x07;
    flags |= @as(u8, byte_count - 1) << 3;
    if (is_last_block) flags |= 0x40;
    flags |= 0x80; // table_present = always true

    // Compute checksum
    var checksum: u8 = 0x5a ^ flags;
    checksum ^= @as(u8, @truncate(block_size));
    if (byte_count >= 2) checksum ^= @as(u8, @truncate(block_size >> 8));
    if (byte_count >= 3) checksum ^= @as(u8, @truncate(block_size >> 16));

    const header_size: usize = 2 + byte_count;
    const total_size = header_size + block_data.len;
    const result = try allocator.alloc(u8, total_size);

    result[0] = flags;
    result[1] = checksum;
    result[2] = @truncate(block_size);
    if (byte_count >= 2) result[3] = @truncate(block_size >> 8);
    if (byte_count >= 3) result[4] = @truncate(block_size >> 16);

    @memcpy(result[header_size..], block_data);

    return result;
}

/// Find if a distance matches one of the 4 previous distances.
fn findRepeatDistance(prev: [4]u32, distance: u32) ?usize {
    if (distance == 0) return null;
    for (prev, 0..) |d, i| {
        if (d == distance) return i;
    }
    return null;
}

/// Rotate previous distances when using repeat index.
fn rotatePrevDistances(prev: *[4]u32, idx: usize) void {
    const d = prev[idx];
    var j: usize = idx;
    while (j > 0) : (j -= 1) {
        prev[j] = prev[j - 1];
    }
    prev[0] = d;
}

fn ensureMinFreq(freq: *[NC]u32) void {
    for (freq) |f| {
        if (f > 0) return;
    }
    freq[0] = 1; // ensure at least literal 0 exists
}

fn ensureMinFreqSlice(freq: anytype) void {
    for (freq) |f| {
        if (f > 0) return;
    }
    freq[0] = 1;
}

fn allZero(arr: []const u32) bool {
    for (arr) |v| {
        if (v > 0) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const BitReader = @import("../decompress/bitreader.zig").BitReader;

test "compressBlock: trivial data" {
    const data = "AAAA";
    const compressed = try compressBlock(testing.allocator, data, 1, true);
    defer testing.allocator.free(compressed);

    // Should produce a valid block header + compressed data
    try testing.expect(compressed.len > 0);
    try testing.expect(compressed.len <= data.len + 256); // shouldn't expand much
}

test "compressBlock: compress-then-decompress round-trip" {
    const data = "Hello World! Hello World! Hello World!";
    const compressed = try compressBlock(testing.allocator, data, 3, true);
    defer testing.allocator.free(compressed);

    // Decompress using the decoder
    const decompressed = try unpack50.decompress(
        testing.allocator,
        compressed,
        data.len,
        50,
        20, // dict_bits for 1MB
    );
    defer testing.allocator.free(decompressed);

    try testing.expectEqualSlices(u8, data, decompressed);
}

test "compressBlock: all-literal data round-trip" {
    // Data with no repeats should still compress correctly (all literals)
    const data = "abcdefghijklmnop";
    const compressed = try compressBlock(testing.allocator, data, 1, true);
    defer testing.allocator.free(compressed);

    const decompressed = try unpack50.decompress(
        testing.allocator,
        compressed,
        data.len,
        50,
        20,
    );
    defer testing.allocator.free(decompressed);

    try testing.expectEqualSlices(u8, data, decompressed);
}

test "compressBlock: RLE data round-trip" {
    const data = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"; // 32 X's
    const compressed = try compressBlock(testing.allocator, data, 3, true);
    defer testing.allocator.free(compressed);

    const decompressed = try unpack50.decompress(
        testing.allocator,
        compressed,
        data.len,
        50,
        20,
    );
    defer testing.allocator.free(decompressed);

    try testing.expectEqualSlices(u8, data, decompressed);
}

test "compressBlock: block header checksum" {
    const data = "test";
    const compressed = try compressBlock(testing.allocator, data, 1, true);
    defer testing.allocator.free(compressed);

    // Verify block header checksum
    const flags = compressed[0];
    const saved_checksum = compressed[1];
    const byte_count: u8 = ((flags >> 3) & 3) + 1;

    var computed: u8 = 0x5a ^ flags;
    for (0..byte_count) |i| {
        computed ^= compressed[2 + i];
    }
    try testing.expectEqual(saved_checksum, computed);
}

test "wrapBlockHeader: checksum verification" {
    // Create some fake block data and verify the header checksum
    const block_data = [_]u8{ 0x12, 0x34, 0x56 };
    const result = try wrapBlockHeader(testing.allocator, &block_data, 24, true);
    defer testing.allocator.free(result);

    const flags = result[0];
    const checksum = result[1];
    const byte_count: u8 = ((flags >> 3) & 3) + 1;

    var computed: u8 = 0x5a ^ flags;
    for (0..byte_count) |i| {
        computed ^= result[2 + i];
    }
    try testing.expectEqual(checksum, computed);

    // Verify last_block flag
    try testing.expect((flags & 0x40) != 0);
    // Verify table_present flag
    try testing.expect((flags & 0x80) != 0);
}

test "encodeCLSymbols: direct values" {
    const combined = [_]u8{ 3, 5, 7, 2 };
    var out: [16]CLSymbol = undefined;
    var count: usize = 0;
    encodeCLSymbols(&combined, &out, &count);
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqual(@as(u8, 3), out[0].symbol);
    try testing.expectEqual(@as(u8, 5), out[1].symbol);
    try testing.expectEqual(@as(u8, 7), out[2].symbol);
    try testing.expectEqual(@as(u8, 2), out[3].symbol);
}

test "encodeCLSymbols: zero run encoding" {
    var combined: [20]u8 = [_]u8{0} ** 20;
    var out: [40]CLSymbol = undefined;
    var count: usize = 0;
    encodeCLSymbols(&combined, &out, &count);
    // 20 zeros should be encoded as sym19 (11..138 zeros)
    try testing.expect(count >= 1);
    try testing.expectEqual(@as(u8, 19), out[0].symbol);
}

test "findRepeatDistance: finds matching distance" {
    const prev = [4]u32{ 5, 10, 15, 20 };
    try testing.expectEqual(@as(?usize, 0), findRepeatDistance(prev, 5));
    try testing.expectEqual(@as(?usize, 1), findRepeatDistance(prev, 10));
    try testing.expectEqual(@as(?usize, 2), findRepeatDistance(prev, 15));
    try testing.expectEqual(@as(?usize, 3), findRepeatDistance(prev, 20));
    try testing.expectEqual(@as(?usize, null), findRepeatDistance(prev, 25));
}

test "rotatePrevDistances: moves to front" {
    var prev = [4]u32{ 1, 2, 3, 4 };
    rotatePrevDistances(&prev, 2); // move index 2 (value 3) to front
    try testing.expectEqual(@as(u32, 3), prev[0]);
    try testing.expectEqual(@as(u32, 1), prev[1]);
    try testing.expectEqual(@as(u32, 2), prev[2]);
    try testing.expectEqual(@as(u32, 4), prev[3]);
}
