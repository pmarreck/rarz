const std = @import("std");

/// BitWriter for RAR compressed stream encoding.
///
/// The inverse of BitReader: writes individual bits and multi-bit fields
/// to a byte buffer, MSB-first (matching RAR5 convention).
///
/// Uses a 64-bit accumulator, MSB-justified. Complete bytes are flushed
/// to the output buffer when >= 8 bits are accumulated.
pub const BitWriter = struct {
    output: []u8,
    buffer: u64, // MSB-justified accumulator
    bits_in_buffer: u7, // valid bits in buffer (0-64)
    byte_pos: usize, // next write position in output[]
    total_bits: usize, // total bits written (including flushed)

    pub fn init(output: []u8) BitWriter {
        return .{
            .output = output,
            .buffer = 0,
            .bits_in_buffer = 0,
            .byte_pos = 0,
            .total_bits = 0,
        };
    }

    /// Write `n` bits (1-25) from `value`, MSB-first.
    /// Only the bottom `n` bits of `value` are used.
    pub fn writeBits(self: *BitWriter, value: u32, n: u5) !void {
        const count: u7 = n;
        if (count == 0) return;

        // Mask off only the bottom `n` bits
        const mask: u32 = (@as(u32, 1) << n) - 1;
        const masked_value: u64 = value & mask;

        // Place bits at the correct position in the MSB-justified buffer
        const shift: u6 = @intCast(64 - self.bits_in_buffer - count);
        self.buffer |= masked_value << shift;
        self.bits_in_buffer += count;
        self.total_bits += count;

        // Flush complete bytes
        try self.flushBytes();
    }

    /// Write a single bit.
    pub fn writeBit(self: *BitWriter, bit: u1) !void {
        try self.writeBits(bit, 1);
    }

    /// Flush complete bytes from the buffer to the output.
    fn flushBytes(self: *BitWriter) !void {
        while (self.bits_in_buffer >= 8) {
            if (self.byte_pos >= self.output.len) return error.BufferTooSmall;
            // Extract top byte
            self.output[self.byte_pos] = @intCast(self.buffer >> 56);
            self.byte_pos += 1;
            self.buffer <<= 8;
            self.bits_in_buffer -= 8;
        }
    }

    /// Flush any remaining partial byte (pads with zeros on the right).
    /// Returns the total number of bytes written to the output.
    pub fn flush(self: *BitWriter) !usize {
        if (self.bits_in_buffer > 0) {
            if (self.byte_pos >= self.output.len) return error.BufferTooSmall;
            self.output[self.byte_pos] = @intCast(self.buffer >> 56);
            self.byte_pos += 1;
            self.buffer = 0;
            self.bits_in_buffer = 0;
        }
        return self.byte_pos;
    }

    /// Pad to byte boundary by writing zero bits.
    pub fn alignByte(self: *BitWriter) !void {
        const rem = self.total_bits % 8;
        if (rem != 0) {
            const pad: u5 = @intCast(8 - rem);
            try self.writeBits(0, pad);
        }
    }

    /// Total bits written so far (including any partial byte in buffer).
    pub fn totalBits(self: *const BitWriter) usize {
        return self.total_bits;
    }

    /// Total complete bytes written to output so far (not including buffered partial byte).
    pub fn bytesWritten(self: *const BitWriter) usize {
        return self.byte_pos;
    }

    /// Write a raw byte directly (must be byte-aligned).
    pub fn writeByte(self: *BitWriter, byte: u8) !void {
        try self.writeBits(byte, 8);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const BitReader = @import("../decompress/bitreader.zig").BitReader;

test "write single bits" {
    var buf: [2]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBit(1);
    try bw.writeBit(0);
    try bw.writeBit(1);
    try bw.writeBit(0);
    try bw.writeBit(0);
    try bw.writeBit(1);
    try bw.writeBit(0);
    try bw.writeBit(1);
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 1), bytes);
    try testing.expectEqual(@as(u8, 0xA5), buf[0]);
}

test "write multi-bit value" {
    var buf: [2]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(0x1F, 5); // 11111
    try bw.writeBits(0x00, 3); // 000
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 1), bytes);
    try testing.expectEqual(@as(u8, 0xF8), buf[0]); // 11111000
}

test "write across byte boundaries" {
    var buf: [4]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(0xA53, 12); // 101001010011
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 2), bytes);
    try testing.expectEqual(@as(u8, 0xA5), buf[0]);
    try testing.expectEqual(@as(u8, 0x30), buf[1]); // 0011_0000 (padded)
}

test "write-then-read round-trip" {
    var buf: [8]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(0xA5, 8);
    try bw.writeBits(0x3C, 8);
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 2), bytes);

    var br = BitReader.init(buf[0..bytes]);
    try testing.expectEqual(@as(u32, 0xA5), try br.readBits(8));
    try testing.expectEqual(@as(u32, 0x3C), try br.readBits(8));
}

test "write-then-read round-trip with mixed widths" {
    var buf: [8]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(5, 3); // 101
    try bw.writeBits(2, 3); // 010
    try bw.writeBits(7, 3); // 111
    try bw.writeBits(4, 3); // 100
    try bw.writeBits(13, 4); // 1101
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 2), bytes);

    var br = BitReader.init(buf[0..bytes]);
    try testing.expectEqual(@as(u32, 5), try br.readBits(3));
    try testing.expectEqual(@as(u32, 2), try br.readBits(3));
    try testing.expectEqual(@as(u32, 7), try br.readBits(3));
    try testing.expectEqual(@as(u32, 4), try br.readBits(3));
    try testing.expectEqual(@as(u32, 13), try br.readBits(4));
}

test "write 25 bits at once" {
    var buf: [8]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(0x1FFFFFF, 25);
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 4), bytes);

    var br = BitReader.init(buf[0..bytes]);
    try testing.expectEqual(@as(u32, 0x1FFFFFF), try br.readBits(25));
}

test "alignByte pads to byte boundary" {
    var buf: [4]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(0x7, 3); // 111
    try bw.alignByte(); // pad with 5 zero bits -> 11100000
    try bw.writeBits(0xAB, 8);
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 2), bytes);
    try testing.expectEqual(@as(u8, 0xE0), buf[0]); // 11100000
    try testing.expectEqual(@as(u8, 0xAB), buf[1]);
}

test "alignByte does nothing when already aligned" {
    var buf: [4]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(0xFF, 8);
    try bw.alignByte(); // no-op
    try testing.expectEqual(@as(usize, 8), bw.totalBits());
}

test "totalBits tracks correctly" {
    var buf: [4]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try testing.expectEqual(@as(usize, 0), bw.totalBits());
    try bw.writeBits(0, 5);
    try testing.expectEqual(@as(usize, 5), bw.totalBits());
    try bw.writeBits(0, 8);
    try testing.expectEqual(@as(usize, 13), bw.totalBits());
}

test "BufferTooSmall when output is full" {
    var buf: [1]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(0xFF, 8); // fills the 1-byte buffer
    try bw.writeBits(1, 1); // goes into accumulator (no flush yet)
    // Error occurs when we try to flush the partial byte (byte_pos=1, output.len=1)
    try testing.expectError(error.BufferTooSmall, bw.flush());
}

test "writeByte convenience" {
    var buf: [4]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeByte(0x42);
    try bw.writeByte(0xFF);
    const bytes = try bw.flush();
    try testing.expectEqual(@as(usize, 2), bytes);
    try testing.expectEqual(@as(u8, 0x42), buf[0]);
    try testing.expectEqual(@as(u8, 0xFF), buf[1]);
}

test "round-trip with large number of writes" {
    var buf: [128]u8 = undefined;
    var bw = BitWriter.init(&buf);

    // Write 256 values of varying widths
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        try bw.writeBits(i & 0xF, 4);
    }
    const bytes = try bw.flush();

    // Read them back
    var br = BitReader.init(buf[0..bytes]);
    i = 0;
    while (i < 64) : (i += 1) {
        try testing.expectEqual(i & 0xF, try br.readBits(4));
    }
}
