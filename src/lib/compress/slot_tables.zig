const std = @import("std");

/// Result of encoding a match length into a RAR5 slot.
pub const LengthSlotResult = struct {
    slot: u32, // slot number (0..43, maps to LD symbol 262+slot)
    extra: u32, // extra bits value
    extra_bits: u5, // number of extra bits to emit
};

/// Result of encoding a match distance into RAR5 slots.
pub const DistanceSlotResult = struct {
    dd_slot: u32, // distance slot number for the DD table
    dd_extra: u32, // extra bits value for DD
    dd_extra_bits: u5, // number of DD extra bits
    use_ldd: bool, // true if low-distance bits go through LDD table
    ldd_value: u32, // low 4 bits decoded via LDD (only if use_ldd)
};

/// Encode a match length (2..4097+) into a RAR5 length slot.
/// This is the inverse of decodeLengthSlot in unpack50.zig.
///
/// **CRITICAL**: The caller must SUBTRACT the distance-dependent length bonus
/// before calling this function. The decoder adds:
///   +1 if distance > 0x100
///   +1 if distance > 0x2000
///   +1 if distance > 0x40000
/// So the encoder must subtract these before encoding.
pub fn encodeLengthSlot(length: u32) LengthSlotResult {
    std.debug.assert(length >= 2);

    // Slots 0-7: direct mapping (length 2-9, no extra bits)
    if (length <= 9) {
        return .{
            .slot = length - 2,
            .extra = 0,
            .extra_bits = 0,
        };
    }

    // Slots 8+: groups of 4 with increasing extra bits
    // For slot s (s >= 8): LBits = s/4 - 1
    //   base = 2 + (4 | (s & 3)) << LBits
    //   length = base + extra_value
    // Invert: find LBits, then compute slot and extra
    //
    // adjusted = length - 2
    // Find highest set bit position to determine LBits
    // Find the slot by scanning using the LENGTH_TABLE formula
    // LBits = floor(log2(adjusted)) - 2 (since the mantissa is 3 bits: 1xx pattern)
    // But we need to handle the groups-of-4 structure
    //
    // Simpler: iterate from slot 8 upward using the LENGTH_TABLE formula
    var slot: u32 = 8;
    while (slot < 44) : (slot += 1) {
        const lbits: u5 = @intCast(slot / 4 - 1);
        const base: u32 = 2 + (@as(u32, 4 | @as(u32, slot & 3)) << lbits);
        const range: u32 = @as(u32, 1) << lbits;
        if (length >= base and length < base + range) {
            return .{
                .slot = slot,
                .extra = length - base,
                .extra_bits = lbits,
            };
        }
    }

    // Fallback: use the last slot (shouldn't happen for valid lengths)
    return .{
        .slot = 43,
        .extra = 0,
        .extra_bits = 0,
    };
}

/// Subtract the distance-dependent length bonus that the decoder adds.
/// Call this before encodeLengthSlot to get the "raw" length for encoding.
pub fn adjustLengthForDistance(length: u32, distance: u32) u32 {
    var adj = length;
    if (distance > 0x100) {
        adj -= 1;
        if (distance > 0x2000) {
            adj -= 1;
            if (distance > 0x40000) {
                adj -= 1;
            }
        }
    }
    return adj;
}

/// Encode a match distance (1-based) into RAR5 distance slots.
/// This is the inverse of decodeDistance in unpack50.zig.
pub fn encodeDistanceSlot(distance: u32) DistanceSlotResult {
    std.debug.assert(distance >= 1);

    // Slots 0-3: direct (distance 1-4)
    if (distance <= 4) {
        return .{
            .dd_slot = distance - 1,
            .dd_extra = 0,
            .dd_extra_bits = 0,
            .use_ldd = false,
            .ldd_value = 0,
        };
    }

    // Slots 4+: distance = (2 | (slot & 1)) << extra_bits + extra_value + 1
    // extra_bits = slot / 2 - 1
    //
    // Invert: dist_base = distance - 1
    const dist_base = distance - 1;

    // Find the slot by scanning (guaranteed small range, max 64/80 slots)
    var slot: u32 = 4;
    while (slot < 64) : (slot += 1) {
        const extra_bits: u5 = @intCast(slot / 2 - 1);
        const base: u32 = (2 | (slot & 1)) << extra_bits;
        const range: u32 = @as(u32, 1) << extra_bits;
        if (dist_base >= base and dist_base < base + range) {
            const extra_value = dist_base - base;

            if (extra_bits < 4) {
                // All extra bits go directly
                return .{
                    .dd_slot = slot,
                    .dd_extra = extra_value,
                    .dd_extra_bits = extra_bits,
                    .use_ldd = false,
                    .ldd_value = 0,
                };
            } else {
                // Split: high bits go to bitstream, low 4 bits to LDD table
                const ldd_value = extra_value & 0xF;
                const high_extra = extra_value >> 4;
                const high_bits: u5 = extra_bits - 4;
                return .{
                    .dd_slot = slot,
                    .dd_extra = high_extra,
                    .dd_extra_bits = high_bits,
                    .use_ldd = true,
                    .ldd_value = ldd_value,
                };
            }
        }
    }

    // Shouldn't reach here for valid distances within RAR5 range
    return .{
        .dd_slot = 63,
        .dd_extra = 0,
        .dd_extra_bits = 0,
        .use_ldd = false,
        .ldd_value = 0,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Import the decoder for round-trip verification
const unpack50 = @import("../decompress/unpack50.zig");
const BitReader = @import("../decompress/bitreader.zig").BitReader;
const BitWriter = @import("bitwriter.zig").BitWriter;
const dec_huffman = @import("../decompress/huffman.zig");

test "encodeLengthSlot: round-trip all direct slots (length 2-9)" {
    for (0..8) |slot| {
        const length: u32 = @intCast(slot + 2);
        const result = encodeLengthSlot(length);
        try testing.expectEqual(@as(u32, @intCast(slot)), result.slot);
        try testing.expectEqual(@as(u32, 0), result.extra);
        try testing.expectEqual(@as(u5, 0), result.extra_bits);
    }
}

test "encodeLengthSlot: round-trip slots 8-11 (1 extra bit)" {
    // Slot 8: base=10, extra_bits=1 -> lengths 10, 11
    const r10 = encodeLengthSlot(10);
    try testing.expectEqual(@as(u32, 8), r10.slot);
    try testing.expectEqual(@as(u32, 0), r10.extra);
    try testing.expectEqual(@as(u5, 1), r10.extra_bits);

    const r11 = encodeLengthSlot(11);
    try testing.expectEqual(@as(u32, 8), r11.slot);
    try testing.expectEqual(@as(u32, 1), r11.extra);

    // Slot 9: base=12
    const r12 = encodeLengthSlot(12);
    try testing.expectEqual(@as(u32, 9), r12.slot);
    try testing.expectEqual(@as(u32, 0), r12.extra);
}

test "encodeLengthSlot: decode round-trip for all encodable lengths" {
    // Test all lengths from 2 to ~4000 by encoding and then decoding
    var length: u32 = 2;
    while (length < 4000) : (length += 1) {
        const enc = encodeLengthSlot(length);
        // Verify by decoding: create a bitstream with the extra bits
        if (enc.extra_bits == 0) {
            // Direct decode
            var data = [_]u8{0};
            var br = BitReader.init(&data);
            const decoded = try unpack50.decodeLengthSlot(&br, enc.slot);
            try testing.expectEqual(length, decoded);
        } else {
            // Encode extra bits into a bitstream
            var buf: [4]u8 = undefined;
            var bw = BitWriter.init(&buf);
            try bw.writeBits(enc.extra, enc.extra_bits);
            _ = try bw.flush();

            var br = BitReader.init(&buf);
            const decoded = try unpack50.decodeLengthSlot(&br, enc.slot);
            try testing.expectEqual(length, decoded);
        }
    }
}

test "encodeDistanceSlot: direct distances 1-4" {
    for (1..5) |dist| {
        const result = encodeDistanceSlot(@intCast(dist));
        try testing.expectEqual(@as(u32, @intCast(dist - 1)), result.dd_slot);
        try testing.expectEqual(@as(u32, 0), result.dd_extra);
        try testing.expectEqual(@as(u5, 0), result.dd_extra_bits);
        try testing.expect(!result.use_ldd);
    }
}

test "encodeDistanceSlot: slot 4 (distance 5-6)" {
    // Slot 4: extra_bits=1, base=(2|0)<<1=4, distance=base+extra+1
    const r5 = encodeDistanceSlot(5);
    try testing.expectEqual(@as(u32, 4), r5.dd_slot);
    try testing.expectEqual(@as(u32, 0), r5.dd_extra);
    try testing.expectEqual(@as(u5, 1), r5.dd_extra_bits);
    try testing.expect(!r5.use_ldd);

    const r6 = encodeDistanceSlot(6);
    try testing.expectEqual(@as(u32, 4), r6.dd_slot);
    try testing.expectEqual(@as(u32, 1), r6.dd_extra);
}

test "encodeDistanceSlot: decode round-trip for key distances" {
    // Test specific distances that exercise different code paths
    const test_distances = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 16, 32, 64, 128, 256, 512, 1024, 4096, 65536 };
    for (test_distances) |dist| {
        const enc = encodeDistanceSlot(dist);

        // Build DD and LDD tables that will decode this slot
        var dd_lengths: [64]u8 = [_]u8{0} ** 64;
        dd_lengths[enc.dd_slot] = 1;
        var dd = try dec_huffman.makeDecodeTables(&dd_lengths, testing.allocator);
        defer dec_huffman.freeDecodeTable(&dd, testing.allocator);

        var ldd_lengths: [16]u8 = [_]u8{0} ** 16;
        if (enc.use_ldd) {
            ldd_lengths[enc.ldd_value] = 1;
        } else {
            ldd_lengths[0] = 1;
        }
        var ldd = try dec_huffman.makeDecodeTables(&ldd_lengths, testing.allocator);
        defer dec_huffman.freeDecodeTable(&ldd, testing.allocator);

        // Build bitstream: DD code (1 bit "0") + DD extra bits + LDD code (1 bit "0")
        var buf: [8]u8 = undefined;
        var bw = BitWriter.init(&buf);
        try bw.writeBit(0); // DD table code for our slot
        if (enc.dd_extra_bits > 0) {
            try bw.writeBits(enc.dd_extra, enc.dd_extra_bits);
        }
        if (enc.use_ldd) {
            try bw.writeBit(0); // LDD table code for ldd_value
        }
        const bytes = try bw.flush();

        var br = BitReader.init(buf[0..bytes]);
        const decoded = try unpack50.decodeDistance(&br, &dd, &ldd);
        try testing.expectEqual(dist, decoded);
    }
}

test "adjustLengthForDistance: removes distance bonuses" {
    try testing.expectEqual(@as(u32, 5), adjustLengthForDistance(5, 1)); // no bonus
    try testing.expectEqual(@as(u32, 5), adjustLengthForDistance(5, 0x100)); // no bonus (not >)
    try testing.expectEqual(@as(u32, 4), adjustLengthForDistance(5, 0x101)); // -1
    try testing.expectEqual(@as(u32, 3), adjustLengthForDistance(5, 0x2001)); // -2
    try testing.expectEqual(@as(u32, 2), adjustLengthForDistance(5, 0x40001)); // -3
}
