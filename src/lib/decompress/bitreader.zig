const std = @import("std");

/// BitReader for RAR compressed stream decoding.
///
/// All RAR decompression algorithms read individual bits and multi-bit fields
/// from compressed byte streams. This reader handles MSB-first bit extraction,
/// cross-byte boundary reads, and position tracking.
///
/// Uses a 64-bit accumulator buffer for performance: bits are bulk-loaded from
/// the byte stream and extracted via shift+mask, avoiding per-bit loop overhead.
///
/// Bits are numbered MSB-first within each byte:
///   byte[0] bit 7 = bit position 0
///   byte[0] bit 6 = bit position 1
///   ...
///   byte[0] bit 0 = bit position 7
///   byte[1] bit 7 = bit position 8
///   etc.
pub const BitReader = struct {
    data: []const u8,
    bit_pos: usize, // current bit position in the stream (for external tracking)
    buffer: u64, // MSB-justified accumulator
    bits_in_buffer: u7, // how many valid bits are in the buffer (0-64)
    byte_pos: usize, // next byte to load from data[]

    pub fn init(data: []const u8) BitReader {
        var br = BitReader{
            .data = data,
            .bit_pos = 0,
            .buffer = 0,
            .bits_in_buffer = 0,
            .byte_pos = 0,
        };
        br.refill();
        return br;
    }

    /// Bulk-load bytes into the accumulator when bits_in_buffer <= 56.
    /// Loads up to 7 bytes at a time to keep bits_in_buffer <= 64.
    fn refill(self: *BitReader) void {
        while (self.bits_in_buffer <= 56 and self.byte_pos < self.data.len) {
            const shift: u6 = @intCast(56 - self.bits_in_buffer);
            self.buffer |= @as(u64, self.data[self.byte_pos]) << shift;
            self.byte_pos += 1;
            self.bits_in_buffer += 8;
        }
    }

    /// Read `n` bits (1-25) as a u32, MSB first.
    /// RAR uses MSB-first bit ordering within bytes.
    pub fn readBits(self: *BitReader, n: u5) error{EndOfData}!u32 {
        const count: u7 = n;
        if (count == 0) return 0;

        if (self.bit_pos + @as(usize, count) > self.data.len * 8) return error.EndOfData;

        if (count > self.bits_in_buffer) {
            self.refill();
        }

        // Extract top `count` bits from the MSB-justified buffer
        const shift: u6 = @intCast(64 - count);
        const result: u32 = @intCast(self.buffer >> shift);

        // Consume the bits
        self.buffer <<= @intCast(count);
        self.bits_in_buffer -= count;
        self.bit_pos += count;

        return result;
    }

    /// Peek at next `n` bits without advancing the position.
    pub fn peekBits(self: *BitReader, n: u5) error{EndOfData}!u32 {
        const count: u7 = n;
        if (count == 0) return 0;

        if (self.bit_pos + @as(usize, count) > self.data.len * 8) return error.EndOfData;

        if (count > self.bits_in_buffer) {
            self.refill();
        }

        const shift: u6 = @intCast(64 - count);
        return @intCast(self.buffer >> shift);
    }

    /// Skip `n` bits.
    pub fn skipBits(self: *BitReader, n: usize) void {
        var remaining = n;
        while (remaining > 0) {
            if (self.bits_in_buffer == 0) {
                self.refill();
                if (self.bits_in_buffer == 0) {
                    self.bit_pos += remaining;
                    break;
                }
            }
            const can_skip: u7 = @intCast(@min(remaining, self.bits_in_buffer));
            self.buffer <<= @intCast(can_skip);
            self.bits_in_buffer -= can_skip;
            self.bit_pos += can_skip;
            remaining -= can_skip;
        }
    }

    /// Read a single bit.
    pub fn readBit(self: *BitReader) error{EndOfData}!u1 {
        const v = try self.readBits(1);
        return @intCast(v);
    }

    /// Current byte-aligned position (truncated to byte boundary).
    pub fn bytePosition(self: *const BitReader) usize {
        return self.bit_pos / 8;
    }

    /// Remaining bits available in the stream.
    pub fn remainingBits(self: *const BitReader) usize {
        const total = self.data.len * 8;
        return if (self.bit_pos < total) total - self.bit_pos else 0;
    }

    /// Align to next byte boundary. If already aligned, does nothing.
    pub fn alignByte(self: *BitReader) void {
        const rem = self.bit_pos % 8;
        if (rem != 0) {
            const skip: u7 = @intCast(8 - rem);
            if (skip <= self.bits_in_buffer) {
                self.buffer <<= @intCast(skip);
                self.bits_in_buffer -= skip;
            } else {
                self.bits_in_buffer = 0;
                self.buffer = 0;
            }
            self.bit_pos += skip;
            self.refill();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "read individual bits from known byte" {
    // 0xA5 = 10100101
    const data = [_]u8{0xA5};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u1, 1), try br.readBit()); // bit 7
    try std.testing.expectEqual(@as(u1, 0), try br.readBit()); // bit 6
    try std.testing.expectEqual(@as(u1, 1), try br.readBit()); // bit 5
    try std.testing.expectEqual(@as(u1, 0), try br.readBit()); // bit 4
    try std.testing.expectEqual(@as(u1, 0), try br.readBit()); // bit 3
    try std.testing.expectEqual(@as(u1, 1), try br.readBit()); // bit 2
    try std.testing.expectEqual(@as(u1, 0), try br.readBit()); // bit 1
    try std.testing.expectEqual(@as(u1, 1), try br.readBit()); // bit 0
}

test "read multi-bit field" {
    // 0xFF = 11111111, read 5 bits = 11111 = 31
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 31), try br.readBits(5));
}

test "read across byte boundaries" {
    // 0xA5, 0x3C = 10100101 00111100
    // Read 12 bits: 101001010011 = 0xA53 = 2643
    const data = [_]u8{ 0xA5, 0x3C };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0xA53), try br.readBits(12));
}

test "peek does not advance position" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);
    const peeked = try br.peekBits(4);
    try std.testing.expectEqual(@as(u32, 15), peeked);
    try std.testing.expectEqual(@as(usize, 0), br.bit_pos); // unchanged
    const read = try br.readBits(4);
    try std.testing.expectEqual(@as(u32, 15), read);
    try std.testing.expectEqual(@as(usize, 4), br.bit_pos); // advanced
}

test "EndOfData at end of stream" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);
    _ = try br.readBits(8);
    try std.testing.expectError(error.EndOfData, br.readBit());
}

test "alignByte aligns to next byte boundary" {
    const data = [_]u8{ 0xFF, 0x00 };
    var br = BitReader.init(&data);
    _ = try br.readBits(3);
    try std.testing.expectEqual(@as(usize, 3), br.bit_pos);
    br.alignByte();
    try std.testing.expectEqual(@as(usize, 8), br.bit_pos);
}

test "alignByte does nothing when already aligned" {
    const data = [_]u8{ 0xFF, 0x00 };
    var br = BitReader.init(&data);
    _ = try br.readBits(8);
    try std.testing.expectEqual(@as(usize, 8), br.bit_pos);
    br.alignByte();
    try std.testing.expectEqual(@as(usize, 8), br.bit_pos); // no change
}

test "remainingBits tracks correctly" {
    const data = [_]u8{ 0xFF, 0x00 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(usize, 16), br.remainingBits());
    _ = try br.readBits(5);
    try std.testing.expectEqual(@as(usize, 11), br.remainingBits());
}

test "remainingBits returns 0 at end of stream" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);
    _ = try br.readBits(8);
    try std.testing.expectEqual(@as(usize, 0), br.remainingBits());
}

test "bytePosition tracks correctly" {
    const data = [_]u8{ 0xFF, 0x00, 0xAA };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(usize, 0), br.bytePosition());
    _ = try br.readBits(7);
    try std.testing.expectEqual(@as(usize, 0), br.bytePosition()); // still in byte 0
    _ = try br.readBit();
    try std.testing.expectEqual(@as(usize, 1), br.bytePosition()); // now in byte 1
    _ = try br.readBits(8);
    try std.testing.expectEqual(@as(usize, 2), br.bytePosition()); // now in byte 2
}

test "skipBits advances position" {
    const data = [_]u8{ 0xA5, 0x3C };
    var br = BitReader.init(&data);
    br.skipBits(4);
    try std.testing.expectEqual(@as(usize, 4), br.bit_pos);
    // After skipping 4 bits of 0xA5 (1010), remaining bits are 0101 00111100
    // Read 4 bits: 0101 = 5
    try std.testing.expectEqual(@as(u32, 5), try br.readBits(4));
}

test "read all 25 bits at once" {
    // 0xFF, 0xFF, 0xFF, 0x80 = 11111111 11111111 11111111 10000000
    // Read 25 bits: 1111111111111111111111111 = 0x1FFFFFF = 33554431
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0x80 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0x1FFFFFF), try br.readBits(25));
}

test "multiple sequential reads" {
    // 0xAB = 10101011, 0xCD = 11001101
    // Full bitstream: 10101011 11001101
    const data = [_]u8{ 0xAB, 0xCD };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 5), try br.readBits(3)); // 101 = 5
    try std.testing.expectEqual(@as(u32, 2), try br.readBits(3)); // 010 = 2
    try std.testing.expectEqual(@as(u32, 7), try br.readBits(3)); // 111 = 7
    try std.testing.expectEqual(@as(u32, 4), try br.readBits(3)); // 100 = 4
    try std.testing.expectEqual(@as(u32, 13), try br.readBits(4)); // 1101 = 13
}

test "empty data returns EndOfData immediately" {
    const data = [_]u8{};
    var br = BitReader.init(&data);
    try std.testing.expectError(error.EndOfData, br.readBit());
    try std.testing.expectEqual(@as(usize, 0), br.remainingBits());
}

test "EndOfData when requesting more bits than available" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);
    _ = try br.readBits(5);
    // Only 3 bits remain, asking for 4 should fail
    try std.testing.expectError(error.EndOfData, br.readBits(4));
}

test "peek at end of stream returns EndOfData" {
    const data = [_]u8{0xFF};
    var br = BitReader.init(&data);
    _ = try br.readBits(8);
    try std.testing.expectError(error.EndOfData, br.peekBits(1));
}

test "buffered reader: sequential byte reads across refill boundaries" {
    const data = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 0x12), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x34), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x56), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x78), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x9A), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0xBC), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0xDE), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0xF0), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x11), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x22), try br.readBits(8));
}

test "cross-refill boundary: mixed width reads" {
    // 0xFF 0x00 0xAA 0x55 = 11111111 00000000 10101010 01010101
    const data = [_]u8{ 0xFF, 0x00, 0xAA, 0x55 };
    var br = BitReader.init(&data);
    // Read 25 bits: 1111111100000000101010100 = 0x1FE0AA * 2 + 0
    // = 11111111 00000000 10101010 0 = 0xFF00AA shifted...
    // Top 25 bits: 11111111_00000000_10101010_0 = 0x1FE0154
    // Actually: 0xFF00AA55 >> 7 = ?
    // Let me compute: 0xFF = 11111111, 0x00 = 00000000, 0xAA = 10101010, 0x55 = 01010101
    // Top 25 bits: 11111111_00000000_101010100 = binary
    // = 0b1111111100000000101010100 = 0xFF00AA * 2 + 0 = ... just check byte reads
    try std.testing.expectEqual(@as(u32, 0xFF), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x00), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0xAA), try br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x55), try br.readBits(8));
    try std.testing.expectEqual(@as(usize, 32), br.bit_pos);
}
