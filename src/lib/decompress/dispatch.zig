const std = @import("std");
const rar5_headers = @import("../rar5_headers.zig");
const unpack50 = @import("unpack50.zig");
const unpack29 = @import("unpack29.zig");
const unpack20 = @import("unpack20.zig");
const unpack15 = @import("unpack15.zig");
const Sink = @import("sink.zig").Sink;

pub const DecompressError = error{
    UnsupportedVersion,
    UnsupportedMethod,
    CorruptData,
    OutOfMemory,
    EndOfData,
    InvalidTable,
    UnsupportedFilter,
    CorruptPpmData,
};

/// A decoder carried across the entries of a solid archive, hiding which
/// unpack version is underneath.
///
/// WHY THIS TYPE EXISTS
///   `rarz_extract_to_buffer(handle, index, ...)` is random access with a fresh
///   decoder per call. That is the wrong shape for a solid archive, where every
///   file is one slice of a single continuous stream and file N inherits the LZ
///   window and Huffman tables from file N-1. The result was a FALSE POSITIVE —
///   rarz reporting a perfectly valid archive INVALID, and in one RAR5 case
///   returning an entry at exactly the right size with the wrong bytes.
///
///   Rejected alternative: decode entries `0..N` on every extraction. Correct,
///   but O(n^2) — unusable on an archive of thousands of entries.
pub const SolidSession = struct {
    inner: Inner,
    /// Window exponent this session was built with. A later entry needing a
    /// larger dictionary cannot reuse the session's window.
    dict_bits: u5,

    const Inner = union(enum) {
        v20: unpack20.Session,
        v29: unpack29.Session,
        v50: unpack50.Session,
    };

    pub fn initRar4(
        allocator: std.mem.Allocator,
        unpack_version: u8,
        file_flags_raw: u16,
    ) DecompressError!SolidSession {
        const dict_bits = getDictBitsRar4(unpack_version, file_flags_raw);
        return switch (unpack_version) {
            29, 36 => .{
                .inner = .{ .v29 = unpack29.Session.init(allocator, dict_bits) catch return error.OutOfMemory },
                .dict_bits = dict_bits,
            },
            20, 26 => .{
                .inner = .{ .v20 = unpack20.Session.init(allocator, dict_bits) catch return error.OutOfMemory },
                .dict_bits = dict_bits,
            },
            else => error.UnsupportedVersion,
        };
    }

    pub fn initRar5(
        allocator: std.mem.Allocator,
        compression: rar5_headers.CompressionInfo,
    ) DecompressError!SolidSession {
        const dict_bits = getDictBitsRar5(compression);
        return .{
            .inner = .{
                .v50 = unpack50.Session.init(
                    allocator,
                    compression.algo_version == 70,
                    dict_bits,
                ) catch return error.OutOfMemory,
            },
            .dict_bits = dict_bits,
        };
    }

    pub fn deinit(self: *SolidSession) void {
        switch (self.inner) {
            inline else => |*s| s.deinit(),
        }
    }

    /// True when this session can serve an entry with the given format and
    /// dictionary requirement. A mismatch means the caller must rebuild.
    pub fn acceptsRar4(self: *const SolidSession, unpack_version: u8, file_flags_raw: u16) bool {
        const want = getDictBitsRar4(unpack_version, file_flags_raw);
        const version_ok = switch (self.inner) {
            .v29 => unpack_version == 29 or unpack_version == 36,
            .v20 => unpack_version == 20 or unpack_version == 26,
            .v50 => false,
        };
        return version_ok and want == self.dict_bits;
    }

    pub fn acceptsRar5(self: *const SolidSession, compression: rar5_headers.CompressionInfo) bool {
        return self.inner == .v50 and getDictBitsRar5(compression) == self.dict_bits;
    }

    /// Decode one entry, emitting its bytes to `out`.
    ///
    /// `solid` is the ENTRY's own flag, not the archive's: the first entry of a
    /// solid group carries solid=false and starts the stream.
    pub fn decodeFile(
        self: *SolidSession,
        packed_data: []const u8,
        unpacked_size: u64,
        solid: bool,
        out: Sink,
    ) DecompressError!void {
        switch (self.inner) {
            .v20 => |*s| s.decodeFile(packed_data, unpacked_size, solid, out) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.EndOfData => error.EndOfData,
                    error.InvalidTable => error.InvalidTable,
                    error.InvalidData => error.CorruptData,
                };
            },
            .v29 => |*s| s.decodeFile(packed_data, unpacked_size, solid, out) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.EndOfData => error.EndOfData,
                    error.InvalidTable => error.InvalidTable,
                    error.UnsupportedFilter => error.UnsupportedFilter,
                    error.CorruptPpmData => error.CorruptPpmData,
                    else => error.CorruptData,
                };
            },
            .v50 => |*s| s.decodeFile(packed_data, unpacked_size, solid, out) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.EndOfData => error.EndOfData,
                    error.InvalidTable => error.InvalidTable,
                    else => error.CorruptData,
                };
            },
        }
    }
};

/// RAR5 encodes the window exponent as an offset from 17.
fn getDictBitsRar5(compression: rar5_headers.CompressionInfo) u5 {
    const raw_bits: u8 = @as(u8, compression.dict_bits) + 17;
    return if (raw_bits > 31) 31 else @intCast(raw_bits);
}

/// Decompress a RAR5/7 compressed file entry.
///
/// `packed_data`: the raw compressed payload bytes from the archive
/// `unpacked_size`: expected decompressed size
/// `compression`: the CompressionInfo parsed from the file header
///
/// Returns a newly allocated slice containing the decompressed data.
/// Caller owns the returned memory.
pub fn decompressRar5(
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    compression: rar5_headers.CompressionInfo,
) DecompressError![]u8 {
    if (compression.method == 0) return error.UnsupportedMethod; // store is handled directly

    const dict_bits = getDictBitsRar5(compression);

    return unpack50.decompress(allocator, packed_data, unpacked_size, compression.algo_version, dict_bits) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EndOfData => error.EndOfData,
            error.InvalidTable => error.InvalidTable,
            else => error.CorruptData,
        };
    };
}

/// Decompress a RAR4 (v15/v20/v26/v29) compressed file entry.
///
/// `packed_data`: the raw compressed payload bytes from the archive
/// `unpacked_size`: expected decompressed size
/// `unpack_version`: the unpack version from the file header (15, 20, 26, or 29)
/// `method`: compression method (1-5; 0=store is handled elsewhere)
/// `file_flags_raw`: the raw u16 file flags from the block header
///
/// Returns a newly allocated slice containing the decompressed data.
/// Caller owns the returned memory.
pub fn decompressRar4(
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    unpack_version: u8,
    method: u8,
    file_flags_raw: u16,
) DecompressError![]u8 {
    if (method == 0) return error.UnsupportedMethod; // store

    const dict_bits = getDictBitsRar4(unpack_version, file_flags_raw);

    return switch (unpack_version) {
        29, 36 => unpack29.decompress(allocator, packed_data, unpacked_size, dict_bits) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.EndOfData => error.EndOfData,
                error.InvalidTable => error.InvalidTable,
                error.UnsupportedFilter => error.UnsupportedFilter,
                error.CorruptPpmData => error.CorruptPpmData,
                else => error.CorruptData,
            };
        },
        20, 26 => unpack20.decompress(allocator, packed_data, unpacked_size, dict_bits) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.EndOfData => error.EndOfData,
                error.InvalidTable => error.InvalidTable,
                else => error.CorruptData,
            };
        },
        15 => unpack15.decompress(allocator, packed_data, unpacked_size, dict_bits) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.EndOfData => error.EndOfData,
                else => error.CorruptData,
            };
        },
        else => error.UnsupportedVersion,
    };
}

/// Derive the dictionary size exponent from RAR4 file header fields.
///
/// In RAR4, the dictionary size is encoded in bits 5-7 of the file flags:
///   dict_size_code = (file_flags >> 5) & 7
///
/// ONE formula for every RAR4-family version, matching unrar 7.20
/// arcread.cpp:268:
///
///     hd->WinSize = hd->Dir ? 0 : 0x10000 << ((hd->Flags & LHD_WINDOWMASK) >> 5)
///
/// The reference applies no version-dependent cap, and neither does this. rarz
/// previously capped v20 at 256 KB and pinned v15 to 64 KB, which handed the
/// decoder a window smaller than the encoder had used and produced DAMAGE
/// verdicts on intact archives — RAR 2.90 accepts -md512 and -md1024 and writes
/// dict codes 3 and 4.
///
/// Code 7 is LHD_DIRECTORY, which the reference resolves to WinSize 0 rather
/// than a window; a directory has no payload to decode, so clamping to 6 (4 MB)
/// here is equivalent and keeps the allocation bounded.
///
/// v15 follows the same formula because the reference does. That path has no
/// producer corpus, so it is reference-derived rather than measured.
fn getDictBitsRar4(unpack_version: u8, file_flags_raw: u16) u5 {
    _ = unpack_version;
    const dict_code: u3 = @intCast((file_flags_raw >> 5) & 7);
    const capped: u5 = if (dict_code > 6) 6 else dict_code;
    return 16 + capped;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "getDictBitsRar4 reads the window from the flags for v15 too" {
    // This test previously asserted a fixed 16 for v15, which is what rarz did
    // and not what the reference does — arcread.cpp:268 applies one formula to
    // every RAR4-family version. UNVERIFIED against a real v15 archive: no
    // obtainable producer writes v15 (rarlab's oldest is RAR 2.50), so this is
    // reference-derived, not measured.
    try testing.expectEqual(@as(u5, 16), getDictBitsRar4(15, 0x0000)); // code 0
    try testing.expectEqual(@as(u5, 17), getDictBitsRar4(15, 0x0020)); // code 1
    try testing.expectEqual(@as(u5, 22), getDictBitsRar4(15, 0x00E0)); // code 7 -> clamped
}

test "getDictBitsRar4 v20 honours the full dictionary range, like the reference" {
    // The reference applies ONE uncapped formula to every RAR4-family version
    // (arcread.cpp:268): WinSize = 0x10000 << ((Flags & LHD_WINDOWMASK) >> 5).
    //
    // rarz capped v20 at 18 (256 KB) on the belief that RAR 2.x could not go
    // higher. It can: RAR 2.90 accepts -md512 and -md1024 and writes dict codes
    // 3 and 4. The cap handed the decoder a window smaller than the encoder
    // used, so any v20 entry over 256 KB decoded wrongly and was reported as
    // DAMAGED on archives unrar tests clean. Measured: a 356 KB entry written
    // with -md1024 failed, a 177 KB one passed.
    try testing.expectEqual(@as(u5, 16), getDictBitsRar4(20, 0x0000)); // 64KB
    try testing.expectEqual(@as(u5, 17), getDictBitsRar4(20, 0x0020)); // 128KB
    try testing.expectEqual(@as(u5, 18), getDictBitsRar4(20, 0x0040)); // 256KB
    try testing.expectEqual(@as(u5, 19), getDictBitsRar4(20, 0x0060)); // 512KB  (-md512)
    try testing.expectEqual(@as(u5, 20), getDictBitsRar4(20, 0x0080)); // 1MB    (-md1024)
    try testing.expectEqual(@as(u5, 21), getDictBitsRar4(20, 0x00A0)); // 2MB
    // Code 7 is LHD_DIRECTORY, never a file window, so 6 is the real ceiling.
    try testing.expectEqual(@as(u5, 22), getDictBitsRar4(20, 0x00C0)); // 4MB
    try testing.expectEqual(@as(u5, 22), getDictBitsRar4(20, 0x00E0));
}

test "getDictBitsRar4 v29 full range" {
    // code 0: 16 (64KB)
    try testing.expectEqual(@as(u5, 16), getDictBitsRar4(29, 0x0000));
    // code 1: 17 (128KB)
    try testing.expectEqual(@as(u5, 17), getDictBitsRar4(29, 0x0020));
    // code 2: 18 (256KB)
    try testing.expectEqual(@as(u5, 18), getDictBitsRar4(29, 0x0040));
    // code 3: 19 (512KB)
    try testing.expectEqual(@as(u5, 19), getDictBitsRar4(29, 0x0060));
    // code 4: 20 (1MB)
    try testing.expectEqual(@as(u5, 20), getDictBitsRar4(29, 0x0080));
    // code 5: 21 (2MB)
    try testing.expectEqual(@as(u5, 21), getDictBitsRar4(29, 0x00A0));
    // code 6: 22 (4MB)
    try testing.expectEqual(@as(u5, 22), getDictBitsRar4(29, 0x00C0));
    // code 7: capped to 22
    try testing.expectEqual(@as(u5, 22), getDictBitsRar4(29, 0x00E0));
}

test "getDictBitsRar4 v26 same as v29" {
    try testing.expectEqual(@as(u5, 20), getDictBitsRar4(26, 0x0080));
    try testing.expectEqual(@as(u5, 22), getDictBitsRar4(26, 0x00C0));
}

test "getDictBitsRar4 v36 same as v29" {
    try testing.expectEqual(@as(u5, 20), getDictBitsRar4(36, 0x0080));
}

test "decompressRar5 rejects store method" {
    const comp = rar5_headers.CompressionInfo{
        .algo_version = 50,
        .solid = false,
        .method = 0,
        .dict_bits = 0,
        .dict_frac_bits = 0,
    };
    try testing.expectError(error.UnsupportedMethod, decompressRar5(testing.allocator, &[_]u8{}, 0, comp));
}

test "decompressRar4 rejects store method" {
    try testing.expectError(error.UnsupportedMethod, decompressRar4(testing.allocator, &[_]u8{}, 0, 29, 0, 0));
}

test "decompressRar4 rejects unknown version" {
    try testing.expectError(error.UnsupportedVersion, decompressRar4(testing.allocator, &[_]u8{}, 0, 99, 3, 0));
}
