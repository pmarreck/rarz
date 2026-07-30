//! RAR3 (v29) filter subsystem — "RarVM".
//!
//! RAR3 encodes data filters as small programs for a bytecode VM. In practice
//! only six programs are ever emitted, and modern unrar no longer ships a
//! general interpreter at all: `RarVM::Execute` dispatches straight to
//! `ExecuteStandardFilter`, and anything unrecognised is simply not filtered.
//! We do the same — recognise the six by the CRC32 and length of their code,
//! then run a native implementation.
//!
//! Reference: unrar rarvm.cpp / rarvm.hpp, unpack30.cpp (ReadVMCode/AddVMCode).

const std = @import("std");
const BitReader = @import("bitreader.zig").BitReader;
const integrity = @import("../integrity.zig");

/// The only filter programs RAR3 actually emits.
pub const StandardFilter = enum {
    none,
    e8,
    e8e9,
    itanium,
    rgb,
    audio,
    delta,
};

/// Length + CRC32 of each standard filter's bytecode, from unrar rarvm.cpp.
/// Both must match: length alone is not distinguishing, and CRC alone would
/// accept a truncated program.
const StdFilterEntry = struct { length: u32, crc: u32, filter: StandardFilter };
const STD_FILTERS = [_]StdFilterEntry{
    .{ .length = 53, .crc = 0xad576887, .filter = .e8 },
    .{ .length = 57, .crc = 0x3cd7e57e, .filter = .e8e9 },
    .{ .length = 120, .crc = 0x3769893f, .filter = .itanium },
    .{ .length = 29, .crc = 0x0e06077d, .filter = .delta },
    .{ .length = 149, .crc = 0x1c2c5dc8, .filter = .rgb },
    .{ .length = 216, .crc = 0xbc85e701, .filter = .audio },
};

/// Identify a filter program, or `.none` if it is not one of the six.
///
/// Byte 0 of the program is an XOR checksum over bytes 1..n; a mismatch means
/// corrupt code and yields `.none` (the reference bails out of Prepare()).
pub fn identifyFilter(code: []const u8) StandardFilter {
    if (code.len == 0) return .none;

    var xor_sum: u8 = 0;
    for (code[1..]) |b| xor_sum ^= b;
    if (xor_sum != code[0]) return .none;

    const code_crc = integrity.crc32(code);
    for (STD_FILTERS) |entry| {
        if (entry.crc == code_crc and entry.length == code.len) return entry.filter;
    }
    return .none;
}

/// RarVM's variable-width integer encoding (`RarVM::ReadData`).
///
/// The top two bits select the width, and the 0x4000 case has a sub-case that
/// sign-extends a small negative value:
///   00 -> 4 bits  (6 consumed)
///   01 -> 8 bits  (10 consumed), or 0xFFFFFF00|value when the next 4 bits are 0
///   10 -> 16 bits (2 + 16 consumed)
///   11 -> 32 bits (2 + 16 + 16 consumed)
pub fn readData(br: *BitReader) error{EndOfData}!u32 {
    const data = try br.peekBits(16);
    switch (data & 0xc000) {
        0 => {
            br.skipBits(6);
            return (data >> 10) & 0x0f;
        },
        0x4000 => {
            if ((data & 0x3c00) == 0) {
                br.skipBits(14);
                return 0xffffff00 | ((data >> 2) & 0xff);
            }
            br.skipBits(10);
            return (data >> 6) & 0xff;
        },
        0x8000 => {
            br.skipBits(2);
            const v = try br.peekBits(16);
            br.skipBits(16);
            return v;
        },
        else => {
            br.skipBits(2);
            const hi = try br.peekBits(16);
            br.skipBits(16);
            const lo = try br.peekBits(16);
            br.skipBits(16);
            return (hi << 16) | lo;
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "identifyFilter: rejects code whose XOR checksum does not match" {
    // Byte 0 must equal XOR of the rest. 0xFF here is deliberately wrong.
    var code = [_]u8{ 0xFF, 0x01, 0x02 };
    try testing.expectEqual(StandardFilter.none, identifyFilter(&code));
    // With the correct checksum it is still not a standard filter (wrong CRC),
    // which proves the checksum is not the only gate.
    code[0] = 0x01 ^ 0x02;
    try testing.expectEqual(StandardFilter.none, identifyFilter(&code));
}

test "identifyFilter: length and CRC must BOTH match" {
    // Every table entry's length is distinct, so a program of the right length
    // but wrong content must not be accepted.
    var fake = [_]u8{0} ** 29; // DELTA's length
    fake[0] = 0; // XOR of all-zero tail is 0, so the checksum passes
    try testing.expectEqual(StandardFilter.none, identifyFilter(&fake));
}

test "identifyFilter: empty code is not a filter" {
    try testing.expectEqual(StandardFilter.none, identifyFilter(&[_]u8{}));
}

test "readData: 4-bit form yields the value and consumes exactly 6 bits" {
    // Prefix 00, then the 4-bit value 1011. Byte 0 = 00 1011 00.
    var buf = [_]u8{ 0b0010_1100, 0x00, 0x00, 0x00 };
    var br = BitReader.init(&buf);
    const before = br.remainingBits();
    try testing.expectEqual(@as(u32, 0b1011), try readData(&br));
    try testing.expectEqual(@as(usize, 6), before - br.remainingBits());
}

test "readData: 16-bit form yields the value and consumes exactly 18 bits" {
    // Prefix 10, then 16 bits of 0xABCD, laid out MSB-first:
    //   1 0 | 1010 1011 1100 1101
    // byte0 = 10 101010 = 0xAA, byte1 = 1111 0011 = 0xF3, byte2 = 01...
    var buf = [_]u8{ 0xAA, 0xF3, 0x40, 0x00 };
    var br = BitReader.init(&buf);
    const before = br.remainingBits();
    try testing.expectEqual(@as(u32, 0xABCD), try readData(&br));
    try testing.expectEqual(@as(usize, 18), before - br.remainingBits());
}

test "readData: 8-bit form and its sign-extended sub-case" {
    // Prefix 01 with a nonzero next-4-bits selects the plain 8-bit form:
    //   0 1 | 1111 | xxxxxxxx   -> value = (data >> 6) & 0xff
    // Using 0x4000-family bits: byte0 = 01 111100 = 0x7C, byte1 = 11 000000.
    {
        var buf = [_]u8{ 0x7C, 0xC0, 0x00, 0x00 };
        var br = BitReader.init(&buf);
        const before = br.remainingBits();
        const v = try readData(&br);
        try testing.expectEqual(@as(usize, 10), before - br.remainingBits());
        try testing.expectEqual(@as(u32, 0b11110011), v);
    }
    // Prefix 01 with the next 4 bits ZERO takes the sign-extended branch,
    // which returns 0xffffff00 | value — the one case that can come back
    // "negative" and which a naive 8-bit read would silently get wrong.
    {
        var buf = [_]u8{ 0x40, 0x3C, 0x00, 0x00 };
        var br = BitReader.init(&buf);
        const before = br.remainingBits();
        const v = try readData(&br);
        try testing.expectEqual(@as(usize, 14), before - br.remainingBits());
        try testing.expect(v >= 0xffffff00);
    }
}
