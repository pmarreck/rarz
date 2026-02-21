const std = @import("std");
const huffman = @import("../decompress/huffman.zig");

/// Maximum number of symbols supported in a single alphabet.
const MAX_SYMBOLS: usize = 512;

/// Compute depth-limited Huffman code lengths from symbol frequencies.
///
/// Uses a two-queue Huffman tree construction (optimal) with parent-pointer
/// depth tracking, followed by depth limiting via Kraft redistribution.
///
/// `freq[i]` = frequency of symbol i
/// `out[i]` = code length for symbol i (0 if frequency is 0)
pub fn computeCodeLengths(freq: []const u32, max_bits: u5, out: []u8) void {
    std.debug.assert(freq.len == out.len);
    std.debug.assert(freq.len <= MAX_SYMBOLS);

    @memset(out, 0);

    // Collect symbols with non-zero frequency, sorted by ascending frequency
    var sorted: [MAX_SYMBOLS]u16 = undefined;
    var n: usize = 0;
    for (freq, 0..) |f, i| {
        if (f > 0) {
            sorted[n] = @intCast(i);
            n += 1;
        }
    }

    if (n == 0) return;
    if (n == 1) {
        out[sorted[0]] = 1;
        return;
    }

    // Insertion sort by frequency (ascending), stable
    for (1..n) |i| {
        const key = sorted[i];
        const key_freq = freq[key];
        var j: usize = i;
        while (j > 0 and freq[sorted[j - 1]] > key_freq) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = key;
    }

    // Two-queue Huffman tree construction with parent pointers.
    // Nodes 0..n-1 are leaves, nodes n..2*n-2 are internal.
    var node_freq: [MAX_SYMBOLS * 2]u64 = undefined;
    var parent_of: [MAX_SYMBOLS * 2]u16 = [_]u16{0} ** (MAX_SYMBOLS * 2);

    // Initialize leaf frequencies
    for (0..n) |i| {
        node_freq[i] = freq[sorted[i]];
    }

    // Two queues: leaf_head scans leaves[0..n), int_head scans internal nodes[n..int_tail)
    var leaf_head: usize = 0;
    var int_head: usize = n;
    var int_tail: usize = n; // next slot for new internal node

    // Helper: pick the minimum-frequency node from either queue
    const pickMin = struct {
        fn pick(nf: *[MAX_SYMBOLS * 2]u64, lh: *usize, le: usize, ih: *usize, it: usize) usize {
            const have_leaf = lh.* < le;
            const have_int = ih.* < it;

            if (have_leaf and have_int) {
                if (nf[lh.*] <= nf[ih.*]) {
                    const result = lh.*;
                    lh.* += 1;
                    return result;
                } else {
                    const result = ih.*;
                    ih.* += 1;
                    return result;
                }
            } else if (have_leaf) {
                const result = lh.*;
                lh.* += 1;
                return result;
            } else {
                const result = ih.*;
                ih.* += 1;
                return result;
            }
        }
    }.pick;

    // Merge n-1 times to build the tree
    for (0..n - 1) |_| {
        const a = pickMin(&node_freq, &leaf_head, n, &int_head, int_tail);
        const b = pickMin(&node_freq, &leaf_head, n, &int_head, int_tail);

        // Create internal node at int_tail
        node_freq[int_tail] = node_freq[a] + node_freq[b];
        parent_of[a] = @intCast(int_tail);
        parent_of[b] = @intCast(int_tail);
        int_tail += 1;
    }

    // Root is at int_tail - 1
    const root = int_tail - 1;

    // Compute depths by walking from each leaf to the root
    for (0..n) |i| {
        var depth: u8 = 0;
        var node: usize = i;
        while (node != root) {
            node = parent_of[node];
            depth += 1;
        }
        out[sorted[i]] = depth;
    }

    // Depth-limit to max_bits
    limitDepths(out, max_bits);
}

/// Limit code lengths to max_bits using Kraft redistribution.
fn limitDepths(lengths: []u8, max_bits: u5) void {
    var needs_limit = false;
    for (lengths) |l| {
        if (l > max_bits) {
            needs_limit = true;
            break;
        }
    }
    if (!needs_limit) return;

    // Clamp all lengths to max_bits
    for (lengths) |*l| {
        if (l.* > max_bits) l.* = max_bits;
    }

    // Verify Kraft inequality: sum(2^(max_bits - len_i)) <= 2^max_bits
    var kraft: u32 = 0;
    const capacity: u32 = @as(u32, 1) << max_bits;
    for (lengths) |l| {
        if (l > 0) {
            kraft += @as(u32, 1) << @intCast(max_bits - @as(u5, @intCast(l)));
        }
    }

    if (kraft <= capacity) return;

    // Over-committed: lengthen shorter codes to reduce Kraft sum
    while (kraft > capacity) {
        // Find the shortest non-zero code that's < max_bits
        var min_len: u8 = max_bits;
        var min_idx: ?usize = null;
        for (lengths, 0..) |l, i| {
            if (l > 0 and l < max_bits and (min_idx == null or l < min_len)) {
                min_len = l;
                min_idx = i;
            }
        }
        const idx = min_idx orelse break;

        const old_contribution = @as(u32, 1) << @intCast(max_bits - @as(u5, @intCast(lengths[idx])));
        lengths[idx] += 1;
        const new_contribution = @as(u32, 1) << @intCast(max_bits - @as(u5, @intCast(lengths[idx])));
        kraft = kraft - old_contribution + new_contribution;
    }
}

/// Assign canonical Huffman codes from code lengths.
///
/// Given lengths[i] = code length for symbol i (0 = not present),
/// compute codes[i] = canonical code for symbol i.
pub fn computeCanonicalCodes(lengths: []const u8, codes: []u32) void {
    std.debug.assert(lengths.len == codes.len);

    var len_count: [16]u32 = [_]u32{0} ** 16;
    var max_len: u8 = 0;
    for (lengths) |cl| {
        if (cl > 0) {
            len_count[cl] += 1;
            max_len = @max(max_len, cl);
        }
    }

    var next_code: [16]u32 = [_]u32{0} ** 16;
    {
        var code: u32 = 0;
        for (1..@as(usize, max_len) + 1) |bits| {
            code = (code + len_count[bits - 1]) << 1;
            next_code[bits] = code;
        }
    }

    for (lengths, 0..) |cl, i| {
        if (cl > 0) {
            codes[i] = next_code[cl];
            next_code[cl] += 1;
        } else {
            codes[i] = 0;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "computeCodeLengths: empty frequencies" {
    const freq = [_]u32{ 0, 0, 0, 0 };
    var lengths: [4]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);
    for (lengths) |l| try testing.expectEqual(@as(u8, 0), l);
}

test "computeCodeLengths: single symbol" {
    const freq = [_]u32{ 0, 5, 0, 0 };
    var lengths: [4]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);
    try testing.expectEqual(@as(u8, 0), lengths[0]);
    try testing.expectEqual(@as(u8, 1), lengths[1]);
    try testing.expectEqual(@as(u8, 0), lengths[2]);
    try testing.expectEqual(@as(u8, 0), lengths[3]);
}

test "computeCodeLengths: two equal symbols get length 1" {
    const freq = [_]u32{ 5, 5 };
    var lengths: [2]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);
    try testing.expectEqual(@as(u8, 1), lengths[0]);
    try testing.expectEqual(@as(u8, 1), lengths[1]);
}

test "computeCodeLengths: three symbols" {
    const freq = [_]u32{ 10, 5, 5 };
    var lengths: [3]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);
    try testing.expectEqual(@as(u8, 1), lengths[0]);
    try testing.expectEqual(@as(u8, 2), lengths[1]);
    try testing.expectEqual(@as(u8, 2), lengths[2]);
}

test "computeCodeLengths: four equal symbols all get length 2" {
    const freq = [_]u32{ 10, 10, 10, 10 };
    var lengths: [4]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);
    for (lengths) |l| try testing.expectEqual(@as(u8, 2), l);
}

test "computeCodeLengths: respects max_bits limit" {
    const freq = [_]u32{ 128, 64, 32, 16, 8, 4, 2, 1 };
    var lengths: [8]u8 = undefined;
    computeCodeLengths(&freq, 4, &lengths);
    for (lengths) |l| {
        if (l > 0) try testing.expect(l <= 4);
    }
}

test "computeCodeLengths: Kraft inequality satisfied" {
    const freq = [_]u32{ 100, 50, 25, 12, 6, 3, 2, 1 };
    var lengths: [8]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);

    var kraft: f64 = 0;
    for (lengths) |l| {
        if (l > 0) {
            kraft += std.math.pow(f64, 2.0, -@as(f64, @floatFromInt(l)));
        }
    }
    try testing.expect(kraft <= 1.0 + 1e-9);
    try testing.expect(kraft > 0);
}

test "computeCodeLengths: decoder round-trip" {
    // Build code lengths from frequencies, then verify decoder works
    const freq = [_]u32{ 100, 50, 25, 12, 6, 3, 2, 1 };
    var lengths: [8]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);

    // All active symbols should have non-zero lengths
    for (lengths) |l| try testing.expect(l > 0);

    // Build decode table and verify it's valid
    var table = try huffman.makeDecodeTables(&lengths, testing.allocator);
    defer huffman.freeDecodeTable(&table, testing.allocator);
    try testing.expect(table.valid);
}

test "computeCanonicalCodes: [1, 2, 2] gives 0, 10, 11" {
    const lengths = [_]u8{ 1, 2, 2 };
    var codes: [3]u32 = undefined;
    computeCanonicalCodes(&lengths, &codes);
    try testing.expectEqual(@as(u32, 0), codes[0]);
    try testing.expectEqual(@as(u32, 2), codes[1]);
    try testing.expectEqual(@as(u32, 3), codes[2]);
}

test "computeCanonicalCodes: [2, 2, 2, 2] gives 00, 01, 10, 11" {
    const lengths = [_]u8{ 2, 2, 2, 2 };
    var codes: [4]u32 = undefined;
    computeCanonicalCodes(&lengths, &codes);
    try testing.expectEqual(@as(u32, 0), codes[0]);
    try testing.expectEqual(@as(u32, 1), codes[1]);
    try testing.expectEqual(@as(u32, 2), codes[2]);
    try testing.expectEqual(@as(u32, 3), codes[3]);
}

test "computeCanonicalCodes: round-trip through decoder" {
    const lengths = [_]u8{ 2, 2, 3, 3, 3, 3 };
    var codes: [6]u32 = undefined;
    computeCanonicalCodes(&lengths, &codes);

    var table = try huffman.makeDecodeTables(&lengths, testing.allocator);
    defer huffman.freeDecodeTable(&table, testing.allocator);
    try testing.expect(table.valid);

    const BitWriter = @import("bitwriter.zig").BitWriter;
    const BitReader = @import("../decompress/bitreader.zig").BitReader;

    var buf: [4]u8 = undefined;
    var bw = BitWriter.init(&buf);
    try bw.writeBits(codes[0], @intCast(lengths[0]));
    try bw.writeBits(codes[3], @intCast(lengths[3]));
    try bw.writeBits(codes[5], @intCast(lengths[5]));
    const bytes = try bw.flush();

    var br = BitReader.init(buf[0..bytes]);
    try testing.expectEqual(@as(u16, 0), try huffman.decodeNumber(&br, &table));
    try testing.expectEqual(@as(u16, 3), try huffman.decodeNumber(&br, &table));
    try testing.expectEqual(@as(u16, 5), try huffman.decodeNumber(&br, &table));
}

test "computeCanonicalCodes: zero-length symbols skipped" {
    const lengths = [_]u8{ 0, 1, 0, 2, 2, 0 };
    var codes: [6]u32 = undefined;
    computeCanonicalCodes(&lengths, &codes);
    try testing.expectEqual(@as(u32, 0), codes[1]);
    try testing.expectEqual(@as(u32, 2), codes[3]);
    try testing.expectEqual(@as(u32, 3), codes[4]);
}

test "computeCodeLengths + computeCanonicalCodes: full encode-decode round-trip" {
    const freq = [_]u32{ 100, 50, 25, 12 };
    var lengths: [4]u8 = undefined;
    computeCodeLengths(&freq, 15, &lengths);

    var codes: [4]u32 = undefined;
    computeCanonicalCodes(&lengths, &codes);

    var table = try huffman.makeDecodeTables(&lengths, testing.allocator);
    defer huffman.freeDecodeTable(&table, testing.allocator);

    const BitWriter = @import("bitwriter.zig").BitWriter;
    const BitReader = @import("../decompress/bitreader.zig").BitReader;

    // Encode sequence: 0, 1, 2, 3, 0, 0, 1
    var buf: [8]u8 = undefined;
    var bw = BitWriter.init(&buf);
    const sequence = [_]u16{ 0, 1, 2, 3, 0, 0, 1 };
    for (sequence) |sym| {
        try bw.writeBits(codes[sym], @intCast(lengths[sym]));
    }
    const bytes = try bw.flush();

    // Decode and verify
    var br = BitReader.init(buf[0..bytes]);
    for (sequence) |expected| {
        try testing.expectEqual(expected, try huffman.decodeNumber(&br, &table));
    }
}
