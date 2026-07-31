//! Output sinks for the decoders.
//!
//! WHY THIS EXISTS
//!   A decoder used to have exactly one way to deliver its result: allocate a
//!   buffer the size of the decoded file and return it. That forced two costs
//!   nobody wanted:
//!
//!   1. Validation allocated whole decompressed files purely to checksum them
//!      and throw them away. `validate` never needs the bytes, only the verdict.
//!   2. Solid archives need PREDECESSOR files decoded to reconstruct the shared
//!      window, and those bytes are pure waste — they exist only to warm up the
//!      LZ history for the file actually being asked for.
//!
//!   A sink lets the same decode path serve all three cases: write to a caller
//!   buffer (extraction), feed a running hash (validation), or drop the bytes on
//!   the floor (warming a solid window).
//!
//! Deliberately a hand-rolled vtable rather than `std.io.Writer`: sinks here
//! cannot fail. The window is already in memory and the destination is either a
//! pre-sized buffer, a hash register, or nothing, so there is no I/O error to
//! propagate. Giving `write` an error union would make every decoder call site
//! handle an error that can never occur.

const std = @import("std");
const integrity = @import("../integrity.zig");

/// A destination for decoded bytes. `write` may be called several times per
/// file: the window is circular, so a logically-contiguous run of output can
/// arrive as two spans.
pub const Sink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, bytes: []const u8) void,

    pub inline fn write(self: Sink, bytes: []const u8) void {
        self.write_fn(self.ctx, bytes);
    }
};

/// Writes into a caller-owned buffer. Used by extraction.
///
/// Records an overflow rather than truncating silently: a short write would
/// hand back a partial file that still looks like a success, which is the
/// failure mode this project exists to avoid.
pub const BufferSink = struct {
    buf: []u8,
    len: usize = 0,
    overflowed: bool = false,

    pub fn init(buf: []u8) BufferSink {
        return .{ .buf = buf };
    }

    pub fn sink(self: *BufferSink) Sink {
        return .{ .ctx = self, .write_fn = writeImpl };
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) void {
        const self: *BufferSink = @ptrCast(@alignCast(ctx));
        const room = self.buf.len - self.len;
        if (bytes.len > room) {
            self.overflowed = true;
            if (room == 0) return;
            @memcpy(self.buf[self.len..][0..room], bytes[0..room]);
            self.len += room;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

/// Hashes decoded bytes and throws them away.
///
/// This is the one Peter asked for: validation never needs the bytes, only the
/// verdict, so it can "stream into the void while watching for errors". Before
/// this, `policy.zig` allocated a buffer the size of every decoded entry purely
/// to checksum it and free it again. Peak memory for validation drops from
/// "whole archive + whole decoded file" to "window + hash state".
///
/// BLAKE2sp is optional because only RAR5 carries one, and its state is ~600
/// bytes — worth not paying for on RAR4.
pub const VerifySink = struct {
    crc: integrity.Crc32 = .{},
    blake: ?integrity.Blake2sp = null,
    len: u64 = 0,

    /// `want_blake` should be true only when the entry actually declares a
    /// BLAKE2sp hash; otherwise the work is pure waste.
    pub fn init(want_blake: bool) VerifySink {
        return .{ .blake = if (want_blake) integrity.Blake2sp.init() else null };
    }

    pub fn sink(self: *VerifySink) Sink {
        return .{ .ctx = self, .write_fn = writeImpl };
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) void {
        const self: *VerifySink = @ptrCast(@alignCast(ctx));
        self.crc.update(bytes);
        if (self.blake) |*b| b.update(bytes);
        self.len += bytes.len;
    }

    pub fn crc32(self: *const VerifySink) u32 {
        return self.crc.final();
    }

    pub fn blake2sp(self: *VerifySink, out: *[32]u8) void {
        self.blake.?.final(out);
    }
};

/// Discards everything, counting bytes. Used to warm a solid window with
/// predecessor files whose contents nobody asked for.
pub const DiscardSink = struct {
    len: u64 = 0,

    pub fn sink(self: *DiscardSink) Sink {
        return .{ .ctx = self, .write_fn = writeImpl };
    }

    fn writeImpl(ctx: *anyopaque, bytes: []const u8) void {
        const self: *DiscardSink = @ptrCast(@alignCast(ctx));
        self.len += bytes.len;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "BufferSink accumulates across several writes" {
    var buf: [8]u8 = undefined;
    var bs = BufferSink.init(&buf);
    const s = bs.sink();

    s.write("abc");
    s.write("de");

    try testing.expectEqual(@as(usize, 5), bs.len);
    try testing.expect(!bs.overflowed);
    try testing.expectEqualSlices(u8, "abcde", buf[0..5]);
}

test "BufferSink flags overflow instead of truncating silently" {
    var buf: [4]u8 = undefined;
    var bs = BufferSink.init(&buf);
    const s = bs.sink();

    s.write("abcdef");

    // It fills what it can — but the flag is the point: a caller that ignores
    // it would otherwise ship a truncated file as a success.
    try testing.expect(bs.overflowed);
    try testing.expectEqual(@as(usize, 4), bs.len);
    try testing.expectEqualSlices(u8, "abcd", &buf);
}

test "BufferSink overflow flag survives a later fitting write" {
    var buf: [4]u8 = undefined;
    var bs = BufferSink.init(&buf);
    const s = bs.sink();

    s.write("abcdef"); // overflows
    s.write(""); // fits trivially

    try testing.expect(bs.overflowed);
}

test "BufferSink into a zero-length buffer overflows without writing" {
    var buf: [0]u8 = undefined;
    var bs = BufferSink.init(&buf);
    const s = bs.sink();

    s.write("a");

    try testing.expect(bs.overflowed);
    try testing.expectEqual(@as(usize, 0), bs.len);
}

test "VerifySink reproduces the one-shot hashes over split writes" {
    // The window is circular, so a contiguous run of decoded output can reach a
    // sink as two spans. If the sink's hashes did not survive that, validation
    // would report a mismatch on a perfectly good archive.
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 41 +% 13);

    const want_crc = integrity.crc32(&data);
    var want_blake: [32]u8 = undefined;
    integrity.blake2sp(&data, &want_blake);

    var split: usize = 0;
    while (split <= data.len) : (split += 97) {
        var vs = VerifySink.init(true);
        const s = vs.sink();
        s.write(data[0..split]);
        s.write(data[split..]);

        try testing.expectEqual(want_crc, vs.crc32());
        var got_blake: [32]u8 = undefined;
        vs.blake2sp(&got_blake);
        try testing.expectEqualSlices(u8, &want_blake, &got_blake);
        try testing.expectEqual(@as(u64, data.len), vs.len);
    }
}

test "VerifySink without BLAKE2sp still checksums" {
    // RAR4 entries carry no BLAKE2sp, and its state is ~600 bytes of pure waste
    // there. Skipping it must not disturb the CRC.
    var vs = VerifySink.init(false);
    const s = vs.sink();
    s.write("hello ");
    s.write("world");

    try testing.expectEqual(integrity.crc32("hello world"), vs.crc32());
    try testing.expectEqual(@as(u64, 11), vs.len);
}

test "VerifySink over no data equals the empty-input hashes" {
    var vs = VerifySink.init(true);
    try testing.expectEqual(integrity.crc32(""), vs.crc32());

    var want: [32]u8 = undefined;
    integrity.blake2sp("", &want);
    var got: [32]u8 = undefined;
    vs.blake2sp(&got);
    try testing.expectEqualSlices(u8, &want, &got);
}

test "VerifySink detects a single flipped bit" {
    // Non-vacuity: the sink must DISAGREE when the bytes differ, or every
    // assertion above is satisfiable by a constant.
    var a: [300]u8 = undefined;
    for (&a, 0..) |*b, i| b.* = @truncate(i);
    var b_data = a;
    b_data[150] ^= 0x01;

    var va = VerifySink.init(true);
    va.sink().write(&a);
    var vb = VerifySink.init(true);
    vb.sink().write(&b_data);

    try testing.expect(va.crc32() != vb.crc32());
    var ha: [32]u8 = undefined;
    var hb: [32]u8 = undefined;
    va.blake2sp(&ha);
    vb.blake2sp(&hb);
    try testing.expect(!std.mem.eql(u8, &ha, &hb));
}

test "DiscardSink counts without storing" {
    var ds = DiscardSink{};
    const s = ds.sink();

    s.write("hello");
    s.write(" world");

    try testing.expectEqual(@as(u64, 11), ds.len);
}
