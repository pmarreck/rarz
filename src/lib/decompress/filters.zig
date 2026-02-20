const std = @import("std");

/// RAR5 post-processing filter types.
/// These filters are applied to decompressed data regions to reverse
/// transformations the compressor applied for better entropy coding.
pub const FilterType = enum(u3) {
    delta = 0,
    e8 = 1,
    e8e9 = 2,
    arm = 3,
};

/// A filter descriptor parsed from the compressed stream.
/// Describes a region of the decompressed output that needs post-processing.
pub const Filter = struct {
    filter_type: FilterType,
    block_start: usize, // start offset within the window
    block_length: usize, // number of bytes the filter covers
    channels: u8, // for delta filter only (1-256, stored as 0-255 meaning 1-256)
};

/// Apply a filter to a data region in-place.
/// `file_offset` is the cumulative file position (for E8/ARM address calculations).
pub fn applyFilter(data: []u8, filter: Filter, file_offset: u64) void {
    switch (filter.filter_type) {
        .delta => applyDelta(data, filter.channels),
        .e8 => applyE8E9(data, @intCast(@min(file_offset, std.math.maxInt(u32))), false),
        .e8e9 => applyE8E9(data, @intCast(@min(file_offset, std.math.maxInt(u32))), true),
        .arm => applyArm(data),
    }
}

/// Delta filter: multi-channel byte differencing.
/// Reverses the compressor's delta encoding by accumulating:
///   data[i] += data[i - channels]
/// for each position from `channels` onward.
pub fn applyDelta(data: []u8, channels: u8) void {
    if (channels == 0) return;
    const ch: usize = channels;
    if (ch >= data.len) return;
    for (ch..data.len) |i| {
        data[i] +%= data[i - ch];
    }
}

/// E8/E8E9 filter: x86 CALL/JMP address translation reversal.
///
/// The RAR compressor converts relative x86 CALL (0xE8) and optionally JMP (0xE9)
/// addresses to absolute addresses so that nearby calls to the same function
/// produce identical byte sequences (better for LZ compression).
///
/// During decompression we reverse this: absolute -> relative.
///
/// Algorithm for each byte position i:
///   if data[i] == 0xE8 or (e9_mode and data[i] == 0xE9):
///     addr = signed LE32 from data[i+1..i+5]
///     offset = i + 1
///     if addr < 0:
///       if addr + offset >= 0: write addr + file_size
///     else:
///       if addr < file_size: write addr - offset
///     advance i by 5 (skip opcode + 4 address bytes)
///   else:
///     advance i by 1
pub fn applyE8E9(data: []u8, file_size: u32, e9: bool) void {
    if (data.len < 5) return;
    var i: usize = 0;
    const limit = data.len - 4;
    while (i < limit) {
        if (data[i] == 0xE8 or (e9 and data[i] == 0xE9)) {
            const offset: i64 = @intCast(i + 1);
            const addr = readSignedLE32(data[i + 1 ..][0..4]);

            if (addr < 0) {
                if (addr + offset >= 0) {
                    writeSignedLE32(data[i + 1 ..][0..4], addr +% @as(i32, @intCast(file_size)));
                }
            } else {
                if (addr < @as(i32, @intCast(file_size))) {
                    writeSignedLE32(data[i + 1 ..][0..4], addr -% @as(i32, @truncate(offset)));
                }
            }
            i += 5;
        } else {
            i += 1;
        }
    }
}

/// ARM filter: ARM BL (branch-and-link) instruction address translation reversal.
///
/// ARM BL instructions have 0xEB as byte 3 (the opcode byte in little-endian).
/// The lower 3 bytes encode a 24-bit signed offset (in instruction units, i.e., *4).
/// The compressor converts relative branch targets to absolute; we reverse this.
pub fn applyArm(data: []u8) void {
    if (data.len < 4) return;
    var i: usize = 0;
    const limit = data.len - 3;
    while (i < limit) : (i += 4) {
        if (data[i + 3] == 0xEB) {
            // Read 24-bit little-endian offset from bytes [i..i+3]
            const b0: u32 = data[i];
            const b1: u32 = data[i + 1];
            const b2: u32 = data[i + 2];
            var offset: i32 = @bitCast((b2 << 16) | (b1 << 8) | b0);

            // Sign-extend from 24 bits to 32 bits
            if (offset & 0x800000 != 0) {
                offset |= @as(i32, @bitCast(@as(u32, 0xFF000000)));
            }

            // Subtract current instruction position (in instruction units)
            offset -%= @as(i32, @intCast(i / 4));

            // Write back the low 24 bits
            const u_offset: u32 = @bitCast(offset);
            data[i] = @truncate(u_offset & 0xFF);
            data[i + 1] = @truncate((u_offset >> 8) & 0xFF);
            data[i + 2] = @truncate((u_offset >> 16) & 0xFF);
            // data[i+3] stays 0xEB
        }
    }
}

// ============================================================================
// Helper functions
// ============================================================================

fn readSignedLE32(bytes: *const [4]u8) i32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}

fn writeSignedLE32(bytes: *[4]u8, value: i32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "delta filter channels=1: differences become cumulative" {
    // Input:  [0, 1, 1, 1, 1]
    // After:  [0, 0+1=1, 1+1=2, 2+1=3, 3+1=4]
    var data = [_]u8{ 0, 1, 1, 1, 1 };
    applyDelta(&data, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4 }, &data);
}

test "delta filter channels=1: wrapping arithmetic" {
    // 250 + 10 = 260 -> wraps to 4 (mod 256)
    var data = [_]u8{ 250, 10 };
    applyDelta(&data, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 250, 4 }, &data);
}

test "delta filter channels=3 (RGB interleaved)" {
    // 3 channels: R, G, B
    // Input:  [10, 20, 30, 5, 5, 5, 3, 3, 3]
    // After channel 0 (R): data[3] += data[0] -> 5+10=15, data[6] += data[3] -> 3+15=18
    // After channel 1 (G): data[4] += data[1] -> 5+20=25, data[7] += data[4] -> 3+25=28
    // After channel 2 (B): data[5] += data[2] -> 5+30=35, data[8] += data[5] -> 3+35=38
    // But delta filter processes left-to-right, not channel-by-channel
    // So: for i in 3..9: data[i] += data[i-3]
    //   data[3] = 5+10 = 15
    //   data[4] = 5+20 = 25
    //   data[5] = 5+30 = 35
    //   data[6] = 3+15 = 18
    //   data[7] = 3+25 = 28
    //   data[8] = 3+35 = 38
    var data = [_]u8{ 10, 20, 30, 5, 5, 5, 3, 3, 3 };
    applyDelta(&data, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 15, 25, 35, 18, 28, 38 }, &data);
}

test "delta filter channels=0: no-op" {
    var data = [_]u8{ 1, 2, 3 };
    const original = data;
    applyDelta(&data, 0);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "delta filter: data shorter than channels is no-op" {
    var data = [_]u8{ 1, 2 };
    const original = data;
    applyDelta(&data, 5);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "E8 filter: forward absolute address becomes relative" {
    // Simulate: at position 0, we have E8 followed by absolute address 0x00001000
    // file_size = 0x10000
    // offset = 0 + 1 = 1
    // addr = 0x00001000 (positive, < file_size)
    // new addr = 0x00001000 - 1 = 0x00000FFF
    var data = [_]u8{ 0xE8, 0x00, 0x10, 0x00, 0x00, 0x90 };
    applyE8E9(&data, 0x10000, false);
    // Read back the modified address
    const addr = readSignedLE32(data[1..5]);
    try testing.expectEqual(@as(i32, 0x00000FFF), addr);
    // The E8 opcode and trailing byte should be unchanged
    try testing.expectEqual(@as(u8, 0xE8), data[0]);
    try testing.expectEqual(@as(u8, 0x90), data[5]);
}

test "E8 filter: negative address that crosses zero gets file_size added" {
    // At position 10, we have E8 followed by address -5
    // offset = 10 + 1 = 11
    // addr = -5, addr + offset = -5 + 11 = 6 >= 0 -> modify
    // new addr = -5 + file_size
    var data = [_]u8{ 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0xE8, 0xFB, 0xFF, 0xFF, 0xFF, 0x90 };
    applyE8E9(&data, 0x10000, false);
    const addr = readSignedLE32(data[11..15]);
    // -5 + 0x10000 = 0xFFFB
    try testing.expectEqual(@as(i32, 0x0000FFFB), addr);
}

test "E8 filter: address >= file_size is not modified" {
    // addr = 0x20000, file_size = 0x10000 -> addr >= file_size, skip
    var data = [_]u8{ 0xE8, 0x00, 0x00, 0x02, 0x00, 0x90 };
    const original = [_]u8{ 0xE8, 0x00, 0x00, 0x02, 0x00, 0x90 };
    applyE8E9(&data, 0x10000, false);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "E8 filter: negative address not crossing zero is not modified" {
    // At position 0, addr = -100, offset = 1
    // addr + offset = -100 + 1 = -99 < 0 -> do not modify
    var data = [_]u8{ 0xE8, 0x9C, 0xFF, 0xFF, 0xFF, 0x90 };
    const original = [_]u8{ 0xE8, 0x9C, 0xFF, 0xFF, 0xFF, 0x90 };
    applyE8E9(&data, 0x10000, false);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "E8E9 filter: handles both E8 and E9" {
    // Two instructions: E8 at offset 0, E9 at offset 5
    var data = [_]u8{
        0xE8, 0x00, 0x10, 0x00, 0x00, // CALL +0x1000
        0xE9, 0x00, 0x20, 0x00, 0x00, // JMP +0x2000
        0x90,
    };
    applyE8E9(&data, 0x10000, true);

    // E8 at offset 0: addr=0x1000, offset=1, new=0x1000-1=0xFFF
    const addr1 = readSignedLE32(data[1..5]);
    try testing.expectEqual(@as(i32, 0xFFF), addr1);

    // E9 at offset 5: addr=0x2000, offset=6, new=0x2000-6=0x1FFA
    const addr2 = readSignedLE32(data[6..10]);
    try testing.expectEqual(@as(i32, 0x1FFA), addr2);
}

test "E8E9 filter: E9 ignored when e9=false" {
    var data = [_]u8{ 0xE9, 0x00, 0x10, 0x00, 0x00, 0x90 };
    const original = [_]u8{ 0xE9, 0x00, 0x10, 0x00, 0x00, 0x90 };
    applyE8E9(&data, 0x10000, false);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "E8 filter: data too short (< 5 bytes) is no-op" {
    var data = [_]u8{ 0xE8, 0x00, 0x10 };
    const original = [_]u8{ 0xE8, 0x00, 0x10 };
    applyE8E9(&data, 0x10000, false);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "ARM filter: BL instruction address reversal" {
    // ARM BL instruction at position 0: bytes [offset_low, offset_mid, offset_high, 0xEB]
    // Suppose the compressor stored absolute address 0x100 (in instruction units)
    // At position 0, instruction position = 0/4 = 0
    // Reverse: 0x100 - 0 = 0x100 (no change at position 0)
    var data = [_]u8{ 0x00, 0x01, 0x00, 0xEB };
    applyArm(&data);
    // offset = 0x000100, sign-extended = 0x000100 (positive, bit 23=0)
    // offset -= 0/4 = 0 -> stays 0x000100
    try testing.expectEqual(@as(u8, 0x00), data[0]);
    try testing.expectEqual(@as(u8, 0x01), data[1]);
    try testing.expectEqual(@as(u8, 0x00), data[2]);
    try testing.expectEqual(@as(u8, 0xEB), data[3]);
}

test "ARM filter: BL at non-zero position subtracts instruction offset" {
    // BL instruction at byte position 8 (instruction position 2)
    // Absolute offset encoded as 0x000010 = 16 (instruction units)
    // After reversal: 16 - 2 = 14 = 0x0E
    var data = [_]u8{
        0x00, 0x00, 0x00, 0x00, // non-BL at pos 0
        0x00, 0x00, 0x00, 0x00, // non-BL at pos 4
        0x10, 0x00, 0x00, 0xEB, // BL at pos 8
    };
    applyArm(&data);
    // Only the instruction at offset 8 should be modified
    // New offset = 0x10 - 2 = 0x0E
    try testing.expectEqual(@as(u8, 0x0E), data[8]);
    try testing.expectEqual(@as(u8, 0x00), data[9]);
    try testing.expectEqual(@as(u8, 0x00), data[10]);
    try testing.expectEqual(@as(u8, 0xEB), data[11]);
}

test "ARM filter: non-BL instructions are not modified" {
    var data = [_]u8{ 0x10, 0x20, 0x30, 0xEA }; // not 0xEB -> no modification
    const original = [_]u8{ 0x10, 0x20, 0x30, 0xEA };
    applyArm(&data);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "ARM filter: data shorter than 4 bytes is no-op" {
    var data = [_]u8{ 0xEB, 0x00, 0x00 };
    const original = [_]u8{ 0xEB, 0x00, 0x00 };
    applyArm(&data);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "ARM filter: negative offset wrapping" {
    // BL at position 0 with a negative 24-bit offset
    // offset = 0xFFFFFE = -2 (sign-extended from 24 bits)
    // Actually 0xFFFFFE in 24 bits: bit 23 = 1, so it's negative
    // Value: 0xFFFFFE as 24-bit = -(0x1000000 - 0xFFFFFE) = -2
    // After reversal at pos 0: -2 - 0 = -2 (unchanged)
    var data = [_]u8{ 0xFE, 0xFF, 0xFF, 0xEB };
    applyArm(&data);
    // offset in = 0xFFFFFE, sign-extended = 0xFFFFFFFE = -2
    // offset out = -2 - 0 = -2 = 0xFFFFFFFE, low 24 bits = 0xFFFFFE
    try testing.expectEqual(@as(u8, 0xFE), data[0]);
    try testing.expectEqual(@as(u8, 0xFF), data[1]);
    try testing.expectEqual(@as(u8, 0xFF), data[2]);
    try testing.expectEqual(@as(u8, 0xEB), data[3]);
}

test "applyFilter dispatches to correct filter type" {
    // Test delta via applyFilter
    var data1 = [_]u8{ 0, 1, 1, 1 };
    const f1 = Filter{
        .filter_type = .delta,
        .block_start = 0,
        .block_length = 4,
        .channels = 1,
    };
    applyFilter(&data1, f1, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3 }, &data1);

    // Test E8 via applyFilter
    var data2 = [_]u8{ 0xE8, 0x00, 0x10, 0x00, 0x00, 0x90 };
    const f2 = Filter{
        .filter_type = .e8,
        .block_start = 0,
        .block_length = 6,
        .channels = 0,
    };
    applyFilter(&data2, f2, 0x10000);
    const addr = readSignedLE32(data2[1..5]);
    try testing.expectEqual(@as(i32, 0xFFF), addr);
}
