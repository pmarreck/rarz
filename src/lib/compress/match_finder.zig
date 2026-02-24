const std = @import("std");

/// An LZ77 token: either a literal byte or a length/distance match.
pub const LzToken = union(enum) {
    literal: u8,
    match: struct {
        length: u32,
        distance: u32,
    },
};

/// Hash-chain LZ77 match finder for RAR5 compression.
///
/// Finds repeated byte sequences using a hash table with chaining.
/// 3-byte windows are hashed to chain positions where the same hash occurs.
///
/// Compression quality is controlled by `max_chain_length`:
///   m1=4, m2=16, m3=64, m4=256, m5=1024
pub const MatchFinder = struct {
    /// Hash table: hash -> most recent position with this hash
    hash_table: []u32,
    /// Chain: prev[pos & mask] -> previous position with same hash
    chain: []u32,
    /// Window mask for chain indexing (window_size - 1)
    chain_mask: u32,
    /// Maximum chain search depth
    max_chain_length: u32,
    /// Minimum match length
    min_match: u32,
    /// Maximum match length
    max_match: u32,
    /// Enable lazy matching (better compression, slower)
    lazy: bool,
    /// Allocator used for internal buffers
    allocator: std.mem.Allocator,

    const HASH_BITS: u5 = 16;
    const HASH_SIZE: usize = 1 << HASH_BITS;
    const HASH_MASK: u32 = HASH_SIZE - 1;
    const NO_MATCH: u32 = 0xFFFFFFFF;

    pub fn init(allocator: std.mem.Allocator, window_size: u32, level: u3) !MatchFinder {
        const hash_table = try allocator.alloc(u32, HASH_SIZE);
        @memset(hash_table, NO_MATCH);

        const chain = try allocator.alloc(u32, window_size);
        @memset(chain, NO_MATCH);

        return .{
            .hash_table = hash_table,
            .chain = chain,
            .chain_mask = window_size - 1,
            .max_chain_length = switch (level) {
                1 => 4,
                2 => 16,
                3 => 64,
                4 => 256,
                5 => 1024,
                else => 64, // default to m3
            },
            .min_match = 2,
            .max_match = 4097,
            .lazy = level >= 3,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MatchFinder) void {
        self.allocator.free(self.hash_table);
        self.allocator.free(self.chain);
    }

    /// Compute 3-byte multiplicative hash at position `pos` in `data`.
    /// Uses FNV-style constant for good bit dispersion across the hash table.
    fn hash3(data: []const u8, pos: usize) u32 {
        if (pos + 2 >= data.len) return 0;
        const v: u32 = @as(u32, data[pos]) |
            (@as(u32, data[pos + 1]) << 8) |
            (@as(u32, data[pos + 2]) << 16);
        return (v *% 0x56A3B17D) >> @as(u5, 32 - @as(u6, HASH_BITS));
    }

    /// Insert position into the hash chain.
    fn insertHash(self: *MatchFinder, data: []const u8, pos: u32) void {
        const h = hash3(data, pos);
        self.chain[pos & self.chain_mask] = self.hash_table[h];
        self.hash_table[h] = pos;
    }

    /// Compare bytes at positions `a` and `b` in `data`, starting from `start`.
    /// Uses u64 fast path (8 bytes at a time via XOR + CTZ) with byte-by-byte tail.
    /// Returns total matching length.
    fn extendMatch(data: []const u8, a: usize, b: usize, start: u32, max_len: u32) u32 {
        var common = start;
        // u64 fast path: compare 8 bytes at a time
        while (common + 8 <= max_len) {
            const va = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(data.ptr + a + common)), .little);
            const vb = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(data.ptr + b + common)), .little);
            const diff = va ^ vb;
            if (diff != 0) {
                return common + @as(u32, @intCast(@ctz(diff) >> 3));
            }
            common += 8;
        }
        // Byte-by-byte tail
        while (common < max_len and data[a + common] == data[b + common]) {
            common += 1;
        }
        return common;
    }

    /// Find the longest match at `pos` in `data`.
    /// Returns null if no match of at least min_match length is found.
    fn findMatch(self: *MatchFinder, data: []const u8, pos: u32) ?struct { length: u32, distance: u32 } {
        if (pos + self.min_match > data.len) return null;

        const h = hash3(data, pos);
        var chain_pos = self.hash_table[h];
        var best_len: u32 = self.min_match - 1;
        var best_dist: u32 = 0;
        var chain_count: u32 = 0;

        while (chain_pos != NO_MATCH and chain_count < self.max_chain_length) : (chain_count += 1) {
            if (chain_pos >= pos) break; // safety: only look backward

            const dist = pos - chain_pos;
            if (dist > self.chain_mask + 1) break; // beyond window

            // Quick check: compare last+1 byte of current best to skip obvious non-matches
            if (best_len > 0 and best_len < data.len - pos) {
                if (data[chain_pos + best_len] != data[pos + best_len]) {
                    chain_pos = self.chain[chain_pos & self.chain_mask];
                    continue;
                }
            }

            // Compare bytes using u64 fast path
            const max_len = @min(self.max_match, @as(u32, @intCast(data.len - pos)));
            const max_src = @min(max_len, @as(u32, @intCast(data.len - chain_pos)));
            const limit = @min(max_len, max_src);
            const len = extendMatch(data, chain_pos, pos, 0, limit);

            if (len > best_len) {
                best_len = len;
                best_dist = dist;
                if (len >= self.max_match) break; // can't do better
            }

            chain_pos = self.chain[chain_pos & self.chain_mask];
        }

        if (best_len >= self.min_match) {
            return .{ .length = best_len, .distance = best_dist };
        }
        return null;
    }

    /// Compress input data into an LZ77 token stream.
    /// Returns allocated slice of tokens (caller must free).
    pub fn compress(self: *MatchFinder, data: []const u8, allocator: std.mem.Allocator) ![]LzToken {
        var tokens: std.ArrayList(LzToken) = .empty;
        errdefer tokens.deinit(allocator);

        var pos: u32 = 0;
        while (pos < data.len) {
            const match_result = self.findMatch(data, pos);

            if (match_result) |m| {
                // Lazy matching: check if next position has a better match
                if (self.lazy and pos + 1 < data.len) {
                    self.insertHash(data, pos);
                    const next_match = self.findMatch(data, pos + 1);
                    if (next_match) |nm| {
                        if (nm.length > m.length + 1) {
                            // Next position is better: emit current pos as literal, advance to next
                            try tokens.append(allocator, .{ .literal = data[pos] });
                            pos += 1;

                            // Emit the better match from pos+1
                            try tokens.append(allocator, .{ .match = .{ .length = nm.length, .distance = nm.distance } });
                            // Insert all positions covered by this match into the hash
                            var i: u32 = 0;
                            while (i < nm.length) : (i += 1) {
                                if (pos + i < data.len) self.insertHash(data, pos + i);
                            }
                            pos += nm.length;
                            continue;
                        }
                    }
                    // Original match was better or equal — undo the insert (already done, that's fine)
                    // and emit the original match. But we already inserted at pos, so the hash chain
                    // is slightly different. That's acceptable — it doesn't affect correctness.
                    try tokens.append(allocator, .{ .match = .{ .length = m.length, .distance = m.distance } });
                    var i: u32 = 1; // pos already inserted
                    while (i < m.length) : (i += 1) {
                        if (pos + i < data.len) self.insertHash(data, pos + i);
                    }
                    pos += m.length;
                } else {
                    // No lazy matching: emit the match directly
                    try tokens.append(allocator, .{ .match = .{ .length = m.length, .distance = m.distance } });
                    var i: u32 = 0;
                    while (i < m.length) : (i += 1) {
                        if (pos + i < data.len) self.insertHash(data, pos + i);
                    }
                    pos += m.length;
                }
            } else {
                // No match: emit literal
                self.insertHash(data, pos);
                try tokens.append(allocator, .{ .literal = data[pos] });
                pos += 1;
            }
        }

        return tokens.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const lz = @import("../decompress/lz.zig");

test "extendMatch: u64 fast-path correctness" {
    // Identical slices: full match
    const data = "ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP";
    try testing.expectEqual(@as(u32, 16), MatchFinder.extendMatch(data, 0, 16, 0, 16));

    // Differ at byte 5
    const data2 = "ABCDEfghijABCDExghij";
    try testing.expectEqual(@as(u32, 5), MatchFinder.extendMatch(data2, 0, 10, 0, 10));

    // Differ at byte 0
    try testing.expectEqual(@as(u32, 0), MatchFinder.extendMatch("AB", 0, 1, 0, 1));

    // Long match crossing u64 boundary (>8 bytes)
    const long = "0123456789ABCDEF0123456789ABCDEFxx";
    try testing.expectEqual(@as(u32, 16), MatchFinder.extendMatch(long, 0, 16, 0, 18));

    // Start from nonzero offset (positions 0 and 7 share "HELLO" starting at offset 2)
    const data3 = "xxHELLOyyHELLO";
    try testing.expectEqual(@as(u32, 7), MatchFinder.extendMatch(data3, 0, 7, 2, 7));
}

test "compress all-literal data (random)" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 3);
    defer mf.deinit();

    // Data with no repeats
    const data = "abcdefghijklmnop";
    const tokens = try mf.compress(data, testing.allocator);
    defer testing.allocator.free(tokens);

    // All should be literals
    for (tokens) |tok| {
        try testing.expect(tok == .literal);
    }
    try testing.expectEqual(data.len, tokens.len);
}

test "compress finds RLE pattern" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 3);
    defer mf.deinit();

    // "AAAAAAAAAAAA" - should compress to literal + match(distance=1)
    const data = "AAAAAAAAAAAA";
    const tokens = try mf.compress(data, testing.allocator);
    defer testing.allocator.free(tokens);

    // Should have fewer tokens than bytes (at least one match)
    try testing.expect(tokens.len < data.len);

    // First token should be literal (no history yet for distance=1)
    // Actually with min_match=2, after 2 literals we could have a match
    // Verify some match exists
    var has_match = false;
    for (tokens) |tok| {
        if (tok == .match) {
            has_match = true;
            try testing.expectEqual(@as(u32, 1), tok.match.distance);
        }
    }
    try testing.expect(has_match);
}

test "compress finds repeated substring" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 3);
    defer mf.deinit();

    const data = "Hello World! Hello World!";
    const tokens = try mf.compress(data, testing.allocator);
    defer testing.allocator.free(tokens);

    // Should compress: fewer tokens than bytes
    try testing.expect(tokens.len < data.len);
}

test "token stream replays correctly through Window" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 1);
    defer mf.deinit();

    const data = "ABCABCABCXYZ";
    const tokens = try mf.compress(data, testing.allocator);
    defer testing.allocator.free(tokens);

    // Replay tokens through the LZ window
    var win = try lz.Window.init(testing.allocator, 4096);
    defer win.deinit(testing.allocator);

    for (tokens) |tok| {
        switch (tok) {
            .literal => |byte| win.putByte(byte),
            .match => |m| win.copyMatch(m.distance, m.length),
        }
    }

    // Extract output and compare
    var output: [64]u8 = undefined;
    _ = win.copyToOutput(&output, win.write_pos, data.len);
    try testing.expectEqualSlices(u8, data, output[0..data.len]);
}

test "token stream replays for RLE data" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 1);
    defer mf.deinit();

    const data = "XXXXXXXXXXXXXXXX"; // 16 X's
    const tokens = try mf.compress(data, testing.allocator);
    defer testing.allocator.free(tokens);

    var win = try lz.Window.init(testing.allocator, 4096);
    defer win.deinit(testing.allocator);

    for (tokens) |tok| {
        switch (tok) {
            .literal => |byte| win.putByte(byte),
            .match => |m| win.copyMatch(m.distance, m.length),
        }
    }

    var output: [64]u8 = undefined;
    _ = win.copyToOutput(&output, win.write_pos, data.len);
    try testing.expectEqualSlices(u8, data, output[0..data.len]);
}

test "token stream replays for mixed data" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 3);
    defer mf.deinit();

    const data = "The quick brown fox jumps over the lazy dog. The quick brown fox!";
    const tokens = try mf.compress(data, testing.allocator);
    defer testing.allocator.free(tokens);

    var win = try lz.Window.init(testing.allocator, 4096);
    defer win.deinit(testing.allocator);

    for (tokens) |tok| {
        switch (tok) {
            .literal => |byte| win.putByte(byte),
            .match => |m| win.copyMatch(m.distance, m.length),
        }
    }

    var output: [128]u8 = undefined;
    _ = win.copyToOutput(&output, win.write_pos, data.len);
    try testing.expectEqualSlices(u8, data, output[0..data.len]);
}

test "empty input produces no tokens" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 3);
    defer mf.deinit();

    const tokens = try mf.compress("", testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 0), tokens.len);
}

test "single byte produces one literal" {
    var mf = try MatchFinder.init(testing.allocator, 4096, 3);
    defer mf.deinit();

    const tokens = try mf.compress("X", testing.allocator);
    defer testing.allocator.free(tokens);
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectEqual(@as(u8, 'X'), tokens[0].literal);
}

test "compression levels affect chain search depth" {
    // Level 1 (fast) should produce fewer/worse matches than level 5 (best)
    // We can't easily verify chain depth, but we can verify both produce valid output
    for ([_]u3{ 1, 3, 5 }) |level| {
        var mf = try MatchFinder.init(testing.allocator, 4096, level);
        defer mf.deinit();

        const data = "ABCDEFABCDEFABCDEFABCDEF";
        const tokens = try mf.compress(data, testing.allocator);
        defer testing.allocator.free(tokens);

        // Replay and verify
        var win = try lz.Window.init(testing.allocator, 4096);
        defer win.deinit(testing.allocator);

        for (tokens) |tok| {
            switch (tok) {
                .literal => |byte| win.putByte(byte),
                .match => |m| win.copyMatch(m.distance, m.length),
            }
        }

        var output: [64]u8 = undefined;
        _ = win.copyToOutput(&output, win.write_pos, data.len);
        try testing.expectEqualSlices(u8, data, output[0..data.len]);
    }
}
