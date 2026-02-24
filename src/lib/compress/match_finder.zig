const std = @import("std");

/// An LZ77 token: either a literal byte or a length/distance match.
pub const LzToken = union(enum) {
    literal: u8,
    match: struct {
        length: u32,
        distance: u32,
    },
};

/// BT4 (Binary Tree, 4-byte hash) LZ77 match finder for RAR5 compression.
///
/// Uses multi-level hashing (2-byte perfect, 3-byte, 4-byte) with a binary
/// search tree for finding longest matches. The tree structure avoids
/// re-comparing bytes already known to match via known-prefix skipping.
///
/// Positions inside matches get lightweight `skip()` updates (hash2/hash3 only),
/// avoiding expensive tree insertions where they provide little benefit.
pub const MatchFinder = struct {
    /// 4-byte hash table: hash -> most recent pos+1 (0 = empty)
    hash: []u32,
    /// 2-byte perfect hash table (65536 entries)
    hash2: []u32,
    /// 3-byte hash table (262144 entries)
    hash3: []u32,
    /// Window/dictionary size
    window_size: u32,
    /// Minimum match length
    min_match: u32,
    /// Maximum match length
    max_match: u32,
    /// "Nice" match length: stop tree walk if match >= this
    nice_len: u32,
    /// Maximum BT4 tree depth for match searching
    bt_depth: u32,
    /// Tree depth for maintenance inserts (positions inside matches)
    insert_depth: u32,
    /// Enable lazy matching (better compression, slower)
    lazy: bool,
    /// Allocator used for internal buffers
    allocator: std.mem.Allocator,

    const HASH_BITS: comptime_int = 20;
    const HASH_SIZE: usize = 1 << HASH_BITS;
    const HASH_SHIFT: u5 = 32 - HASH_BITS; // 12

    const HASH2_SIZE: usize = 1 << 16; // 65536 — perfect hash for 2-byte keys

    const HASH3_BITS: comptime_int = 18;
    const HASH3_SIZE: usize = 1 << HASH3_BITS; // 262144
    const HASH3_SHIFT: u5 = 32 - HASH3_BITS; // 14

    pub fn init(allocator: std.mem.Allocator, window_size: u32, level: u3) !MatchFinder {
        const hash = try allocator.alloc(u32, HASH_SIZE);
        @memset(hash, 0);

        const hash2 = try allocator.alloc(u32, HASH2_SIZE);
        @memset(hash2, 0);

        const hash3 = try allocator.alloc(u32, HASH3_SIZE);
        @memset(hash3, 0);

        return .{
            .hash = hash,
            .hash2 = hash2,
            .hash3 = hash3,
            .window_size = window_size,
            .min_match = 2,
            .max_match = 4097,
            .nice_len = switch (level) {
                1 => 8,
                2 => 16,
                3 => 32,
                4 => 64,
                5 => 128,
                else => 32,
            },
            .bt_depth = switch (level) {
                1 => 4,
                2 => 8,
                3 => 16,
                4 => 24,
                5 => 32,
                else => 16,
            },
            // Shallow depth for tree maintenance (positions inside matches).
            // Full bt_depth is only used when actively searching for matches.
            .insert_depth = switch (level) {
                1 => 2,
                2 => 4,
                3 => 4,
                4 => 6,
                5 => 8,
                else => 4,
            },
            .lazy = level >= 3,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MatchFinder) void {
        self.allocator.free(self.hash);
        self.allocator.free(self.hash2);
        self.allocator.free(self.hash3);
    }

    /// 2-byte perfect hash (no collisions for 16-bit keys).
    fn hash2val(data: []const u8, pos: usize) u32 {
        return @as(u32, data[pos]) | (@as(u32, data[pos + 1]) << 8);
    }

    /// 3-byte multiplicative hash.
    fn hash3val(data: []const u8, pos: usize) u32 {
        const v: u32 = @as(u32, data[pos]) |
            (@as(u32, data[pos + 1]) << 8) |
            (@as(u32, data[pos + 2]) << 16);
        return (v *% 0x56A3B17D) >> HASH3_SHIFT;
    }

    /// 4-byte multiplicative hash (golden ratio constant).
    fn hash4(data: []const u8, pos: usize) u32 {
        if (pos + 3 >= data.len) return 0;
        const v: u32 = @as(u32, data[pos]) |
            (@as(u32, data[pos + 1]) << 8) |
            (@as(u32, data[pos + 2]) << 16) |
            (@as(u32, data[pos + 3]) << 24);
        return (v *% 0x9E3779B1) >> HASH_SHIFT;
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

    /// Insert position into the tree without searching for matches.
    /// Maintains all hash tables and the BT4 tree structure so future
    /// positions can find this one. Used for positions inside matches.
    fn treeInsert(
        self: *MatchFinder,
        data: []const u8,
        pos: u32,
        bt_left: []u32,
        bt_right: []u32,
    ) void {
        if (pos + 3 >= data.len) {
            // Too close to end: update hash2/hash3 only
            if (pos + 1 < data.len) self.hash2[hash2val(data, pos)] = pos + 1;
            if (pos + 2 < data.len) self.hash3[hash3val(data, pos)] = pos + 1;
            return;
        }

        self.hash2[hash2val(data, pos)] = pos + 1;
        self.hash3[hash3val(data, pos)] = pos + 1;

        const h = hash4(data, pos);
        var cur = self.hash[h];
        self.hash[h] = pos + 1;

        var left_ptr = &bt_left[pos];
        var right_ptr = &bt_right[pos];
        var best_left_len: u32 = 0;
        var best_right_len: u32 = 0;
        var depth: u32 = 0;

        while (cur > 0 and depth < self.insert_depth) : (depth += 1) {
            const match_pos = cur - 1;
            if (pos <= match_pos) break;
            if (pos - match_pos > self.window_size) break;

            const max_len = @min(self.max_match, @as(u32, @intCast(data.len - pos)));
            const max_src = @min(max_len, @as(u32, @intCast(data.len - match_pos)));
            const limit = @min(max_len, max_src);
            const common = extendMatch(data, pos, match_pos, @min(best_left_len, best_right_len), limit);

            if (common >= limit or common >= self.nice_len) {
                left_ptr.* = bt_left[match_pos];
                right_ptr.* = bt_right[match_pos];
                return;
            }

            if (common < limit and data[pos + common] < data[match_pos + common]) {
                right_ptr.* = cur;
                right_ptr = &bt_left[match_pos];
                cur = bt_left[match_pos];
                best_right_len = common;
            } else {
                left_ptr.* = cur;
                left_ptr = &bt_right[match_pos];
                cur = bt_right[match_pos];
                best_left_len = common;
            }
        }

        left_ptr.* = 0;
        right_ptr.* = 0;
    }

    /// Insert position into the binary tree and find the best match.
    /// Simultaneously maintains the BT4 tree and searches for matches.
    /// Returns null if no match of at least min_match length is found.
    fn findBT4Match(
        self: *MatchFinder,
        data: []const u8,
        pos: u32,
        bt_left: []u32,
        bt_right: []u32,
    ) ?struct { length: u32, distance: u32 } {
        if (pos + 3 >= data.len) return null;

        // --- HC2: 2-byte hash lookup ---
        const h2 = hash2val(data, pos);
        const h2_prev = self.hash2[h2];
        self.hash2[h2] = pos + 1;

        // --- HC3: 3-byte hash lookup ---
        const h3 = hash3val(data, pos);
        const h3_prev = self.hash3[h3];
        self.hash3[h3] = pos + 1;

        var best_len: u32 = self.min_match - 1;
        var best_dist: u32 = 0;

        // Check 2-byte match from hash2
        if (h2_prev > 0) {
            const mp: u32 = h2_prev - 1;
            if (pos > mp) {
                const dist = pos - mp;
                if (dist <= self.window_size and data[mp] == data[pos] and data[mp + 1] == data[pos + 1]) {
                    best_len = 2;
                    best_dist = dist;
                }
            }
        }

        // Check 3-byte match from hash3 (extend to find actual length)
        if (h3_prev > 0) {
            const mp: u32 = h3_prev - 1;
            if (pos > mp) {
                const dist = pos - mp;
                if (dist <= self.window_size and
                    data[mp] == data[pos] and
                    data[mp + 1] == data[pos + 1] and
                    data[mp + 2] == data[pos + 2])
                {
                    const max_len = @min(self.max_match, @as(u32, @intCast(data.len - pos)));
                    const max_src = @min(max_len, @as(u32, @intCast(data.len - mp)));
                    const limit = @min(max_len, max_src);
                    const actual_len = extendMatch(data, pos, mp, 3, limit);
                    if (actual_len > best_len) {
                        best_len = actual_len;
                        best_dist = dist;
                    }
                }
            }
        }

        // Adaptive depth: if neither HC2 nor HC3 found a 3+ byte match,
        // use a shallow tree walk. On incompressible data, this saves
        // enormous time since deep BT4 walks find nothing useful.
        const effective_depth: u32 = if (best_len < 3) @min(self.bt_depth, 2) else self.bt_depth;

        // --- BT4: binary tree match finding + insertion ---
        const h = hash4(data, pos);
        var cur = self.hash[h];
        self.hash[h] = pos + 1;

        var left_ptr = &bt_left[pos];
        var right_ptr = &bt_right[pos];
        var best_left_len: u32 = 0;
        var best_right_len: u32 = 0;
        var depth: u32 = 0;

        while (cur > 0 and depth < effective_depth) : (depth += 1) {
            const match_pos = cur - 1;
            if (pos <= match_pos) break;
            const dist = pos - match_pos;
            if (dist > self.window_size) break;

            const max_len = @min(self.max_match, @as(u32, @intCast(data.len - pos)));
            const max_src = @min(max_len, @as(u32, @intCast(data.len - match_pos)));
            const limit = @min(max_len, max_src);
            // Known-prefix skipping: start comparison from min of left/right known lengths
            const common = extendMatch(data, pos, match_pos, @min(best_left_len, best_right_len), limit);

            if (common > best_len) {
                best_len = common;
                best_dist = dist;
                // Nice-length early exit: graft subtrees and return
                if (common >= max_len or common >= self.nice_len) {
                    left_ptr.* = bt_left[match_pos];
                    right_ptr.* = bt_right[match_pos];
                    if (best_len >= self.min_match) {
                        return .{ .length = best_len, .distance = best_dist };
                    }
                    return null;
                }
            }

            // Binary tree insertion: lexicographic ordering by suffix
            if (common < limit and data[pos + common] < data[match_pos + common]) {
                right_ptr.* = cur;
                right_ptr = &bt_left[match_pos];
                cur = bt_left[match_pos];
                best_right_len = common;
            } else {
                left_ptr.* = cur;
                left_ptr = &bt_right[match_pos];
                cur = bt_right[match_pos];
                best_left_len = common;
            }
        }

        // Terminate tree branches (no graft)
        left_ptr.* = 0;
        right_ptr.* = 0;

        if (best_len >= self.min_match) {
            return .{ .length = best_len, .distance = best_dist };
        }
        return null;
    }

    /// Compress input data into an LZ77 token stream.
    /// Returns allocated slice of tokens (caller must free).
    pub fn compress(self: *MatchFinder, data: []const u8, allocator: std.mem.Allocator) ![]LzToken {
        if (data.len == 0) return try allocator.alloc(LzToken, 0);

        // Allocate BT4 tree arrays for this compression run
        const bt_left = try allocator.alloc(u32, data.len);
        defer allocator.free(bt_left);
        @memset(bt_left, 0);

        const bt_right = try allocator.alloc(u32, data.len);
        defer allocator.free(bt_right);
        @memset(bt_right, 0);

        var tokens: std.ArrayList(LzToken) = .empty;
        errdefer tokens.deinit(allocator);

        var pos: u32 = 0;
        while (pos < data.len) {
            const match_result = self.findBT4Match(data, pos, bt_left, bt_right);

            if (match_result) |m| {
                // Lazy matching: check if next position has a better match
                if (self.lazy and pos + 1 < data.len) {
                    const next_match = self.findBT4Match(data, pos + 1, bt_left, bt_right);
                    if (next_match) |nm| {
                        if (nm.length > m.length + 1) {
                            // Next position is better: emit current pos as literal
                            try tokens.append(allocator, .{ .literal = data[pos] });
                            pos += 1;

                            // Emit the better match from pos+1
                            try tokens.append(allocator, .{ .match = .{ .length = nm.length, .distance = nm.distance } });
                            // Insert positions inside the match into tree (no match search)
                            var i: u32 = 1;
                            while (i < nm.length) : (i += 1) {
                                if (pos + i < data.len) self.treeInsert(data, pos + i, bt_left, bt_right);
                            }
                            pos += nm.length;
                            continue;
                        }
                    }
                    // Original match was better or equal — emit it.
                    // pos was already inserted by findBT4Match, pos+1 was inserted by the
                    // lazy check above. Insert remaining positions into tree.
                    try tokens.append(allocator, .{ .match = .{ .length = m.length, .distance = m.distance } });
                    var i: u32 = 2; // pos and pos+1 already in tree
                    while (i < m.length) : (i += 1) {
                        if (pos + i < data.len) self.treeInsert(data, pos + i, bt_left, bt_right);
                    }
                    pos += m.length;
                } else {
                    // No lazy matching: emit the match directly
                    try tokens.append(allocator, .{ .match = .{ .length = m.length, .distance = m.distance } });
                    // Insert positions inside the match into tree
                    var i: u32 = 1; // pos already in tree via findBT4Match
                    while (i < m.length) : (i += 1) {
                        if (pos + i < data.len) self.treeInsert(data, pos + i, bt_left, bt_right);
                    }
                    pos += m.length;
                }
            } else {
                // No match: literal (pos already inserted into tree by findBT4Match)
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

test "compression levels affect output quality" {
    // All levels should produce valid output that replays correctly
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

test "BT4 replay: repeated lines pattern (regression)" {
    // This pattern failed at 20 lines (591 bytes) with 1 byte missing.
    // Generates "Line N: The quick brown fox.\n" repeated 20 times.
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    for (1..21) |i| {
        const line = std.fmt.bufPrint(buf[pos..], "Line {d}: The quick brown fox.\n", .{i}) catch unreachable;
        pos += line.len;
    }
    const data = buf[0..pos];

    for ([_]u3{ 1, 2, 3, 4, 5 }) |level| {
        var mf = try MatchFinder.init(testing.allocator, 1 << 20, level);
        defer mf.deinit();

        const tokens = try mf.compress(data, testing.allocator);
        defer testing.allocator.free(tokens);

        // Verify total decompressed size matches
        var total: usize = 0;
        for (tokens) |tok| {
            switch (tok) {
                .literal => total += 1,
                .match => |m| total += m.length,
            }
        }
        try testing.expectEqual(data.len, total);

        // Replay through LZ window and verify byte-for-byte
        var win = try lz.Window.init(testing.allocator, 1 << 20);
        defer win.deinit(testing.allocator);

        for (tokens) |tok| {
            switch (tok) {
                .literal => |byte| win.putByte(byte),
                .match => |m| win.copyMatch(m.distance, m.length),
            }
        }

        var output: [1024]u8 = undefined;
        _ = win.copyToOutput(&output, win.write_pos, data.len);
        try testing.expectEqualSlices(u8, data, output[0..data.len]);
    }
}

test "BT4 finds longer matches than needed with short data" {
    // Verify BT4 can find matches in small repeated patterns
    var mf = try MatchFinder.init(testing.allocator, 4096, 5);
    defer mf.deinit();

    const data = "ABCABCABCABCABC"; // 5 repetitions of "ABC"
    const tokens = try mf.compress(data, testing.allocator);
    defer testing.allocator.free(tokens);

    // Should compress significantly
    try testing.expect(tokens.len < data.len);

    // Verify correctness
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
