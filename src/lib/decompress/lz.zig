const std = @import("std");

pub const Window = struct {
    buffer: []u8,
    mask: usize, // buffer.len - 1 (for fast modulo via bitwise AND)
    write_pos: usize, // current write position in circular buffer
    total_written: u64, // total bytes written (for tracking progress & distance validation)

    /// Initialize a window with the given dictionary size.
    /// dict_size must be a power of 2.
    pub fn init(allocator: std.mem.Allocator, dict_size: usize) !Window {
        // Ensure power of 2
        std.debug.assert(dict_size > 0 and (dict_size & (dict_size - 1)) == 0);
        const buffer = try allocator.alloc(u8, dict_size);
        @memset(buffer, 0);
        return .{
            .buffer = buffer,
            .mask = dict_size - 1,
            .write_pos = 0,
            .total_written = 0,
        };
    }

    /// Initialize from dict_bits (e.g., 20 means 1MB dictionary).
    pub fn initFromBits(allocator: std.mem.Allocator, dict_bits: u5) !Window {
        const dict_size: usize = @as(usize, 1) << dict_bits;
        return init(allocator, dict_size);
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.buffer = &.{};
    }

    /// Write a literal byte to the window.
    pub fn putByte(self: *Window, byte: u8) void {
        self.buffer[self.write_pos & self.mask] = byte;
        self.write_pos += 1;
        self.total_written += 1;
    }

    /// Copy `length` bytes from `distance` bytes back in the window.
    /// Optimized with bulk operations for common cases:
    /// - distance == 0 or invalid: @memset(0)
    /// - distance == 1 (RLE): @memset with repeated byte
    /// - distance >= length (non-overlapping): @memcpy
    /// - overlapping, distance >= 16, no wrap: SIMD stride copy
    /// - wrapping: split into pre-wrap + post-wrap @memcpy
    /// - small overlapping or complex wrapping: byte-by-byte fallback
    pub fn copyMatch(self: *Window, distance: usize, length: usize) void {
        if (length == 0) return;

        if (distance == 0 or distance > self.total_written) {
            // Invalid distance: zero-fill for corruption hardening
            self.bulkZeroFill(length);
            return;
        }

        const dst_phys = self.write_pos & self.mask;
        const src_phys = (self.write_pos -% distance) & self.mask;

        // Check if both src and dst regions fit without wrapping around the circular buffer
        const dst_no_wrap = dst_phys + length <= self.buffer.len;
        const src_no_wrap = src_phys + length <= self.buffer.len;

        if (distance == 1 and dst_no_wrap) {
            // RLE: fill with the single repeated byte
            const fill_byte = self.buffer[src_phys];
            @memset(self.buffer[dst_phys..][0..length], fill_byte);
            self.write_pos += length;
            self.total_written += length;
            return;
        }

        if (distance >= length and dst_no_wrap and src_no_wrap and
            (dst_phys + length <= src_phys or src_phys + length <= dst_phys))
        {
            // Non-overlapping: bulk copy
            @memcpy(self.buffer[dst_phys..][0..length], self.buffer[src_phys..][0..length]);
            self.write_pos += length;
            self.total_written += length;
            return;
        }

        // Overlapping with distance >= 16, no wrap: stride copy in distance-sized chunks
        // Safe because each chunk reads from already-written data
        if (distance >= 2 and distance < length and dst_no_wrap and src_no_wrap) {
            const dst = self.buffer[dst_phys..];
            const src = self.buffer[src_phys..];
            var copied: usize = 0;
            // Copy in chunks of `distance` size (the repeating unit)
            while (copied + distance <= length) {
                @memcpy(dst[copied..][0..distance], src[copied..][0..distance]);
                copied += distance;
            }
            // Tail
            if (copied < length) {
                const remain = length - copied;
                @memcpy(dst[copied..][0..remain], src[copied..][0..remain]);
            }
            self.write_pos += length;
            self.total_written += length;
            return;
        }

        // Wrapping case: split into segments that don't wrap
        if (!dst_no_wrap or !src_no_wrap) {
            if (distance >= length) {
                // Non-overlapping but wrapping: split copy
                self.splitCopy(dst_phys, src_phys, length);
                self.write_pos += length;
                self.total_written += length;
                return;
            }
        }

        // Fallback: byte-by-byte for complex overlapping + wrapping cases
        var src_pos = self.write_pos -% distance;
        for (0..length) |_| {
            const byte = self.buffer[src_pos & self.mask];
            self.putByte(byte);
            src_pos +%= 1;
        }
    }

    /// Split a non-overlapping copy across the circular buffer boundary.
    fn splitCopy(self: *Window, dst_phys: usize, src_phys: usize, length: usize) void {
        const buf_len = self.buffer.len;
        var dst = dst_phys;
        var src = src_phys;
        var remaining = length;

        while (remaining > 0) {
            const dst_avail = buf_len - dst;
            const src_avail = buf_len - src;
            const chunk = @min(remaining, @min(dst_avail, src_avail));

            @memcpy(self.buffer[dst..][0..chunk], self.buffer[src..][0..chunk]);

            dst = (dst + chunk) & self.mask;
            src = (src + chunk) & self.mask;
            remaining -= chunk;
        }
    }

    /// Bulk zero-fill: optimized for the invalid-distance case.
    fn bulkZeroFill(self: *Window, length: usize) void {
        const dst_phys = self.write_pos & self.mask;
        if (dst_phys + length <= self.buffer.len) {
            @memset(self.buffer[dst_phys..][0..length], 0);
            self.write_pos += length;
            self.total_written += length;
        } else {
            for (0..length) |_| {
                self.putByte(0);
            }
        }
    }

    /// Get a byte from `distance` bytes back from the current write position.
    pub fn getByte(self: *const Window, distance: usize) u8 {
        if (distance == 0 or distance > self.total_written) return 0;
        const pos = self.write_pos -% distance;
        return self.buffer[pos & self.mask];
    }

    /// Copy `count` bytes from the window to an output slice, starting from
    /// `start_offset` bytes back from write_pos.
    /// Returns the number of bytes actually copied.
    pub fn copyToOutput(self: *const Window, output: []u8, start_offset: usize, count: usize) usize {
        const actual_count = @min(count, output.len);
        var src = self.write_pos -% start_offset;
        for (0..actual_count) |i| {
            output[i] = self.buffer[src & self.mask];
            src +%= 1;
        }
        return actual_count;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "putByte writes and advances" {
    var win = try Window.init(testing.allocator, 16); // 16-byte window
    defer win.deinit(testing.allocator);

    win.putByte('A');
    try testing.expectEqual(@as(u64, 1), win.total_written);
    try testing.expectEqual(@as(u8, 'A'), win.buffer[0]);

    win.putByte('B');
    try testing.expectEqual(@as(u64, 2), win.total_written);
    try testing.expectEqual(@as(u8, 'B'), win.buffer[1]);
}

test "copyMatch no overlap" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    // Write "ABCD"
    for ("ABCD") |c| win.putByte(c);
    // Copy 3 bytes from distance 4 (copies "ABC")
    win.copyMatch(4, 3);

    try testing.expectEqual(@as(u64, 7), win.total_written);
    try testing.expectEqual(@as(u8, 'A'), win.buffer[4]);
    try testing.expectEqual(@as(u8, 'B'), win.buffer[5]);
    try testing.expectEqual(@as(u8, 'C'), win.buffer[6]);
}

test "copyMatch with overlap (RLE pattern)" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    // Write single byte 'X'
    win.putByte('X');
    // Copy from distance=1, length=9 -> replicates 'X' 9 more times
    win.copyMatch(1, 9);

    try testing.expectEqual(@as(u64, 10), win.total_written);
    for (0..10) |i| {
        try testing.expectEqual(@as(u8, 'X'), win.buffer[i]);
    }
}

test "copyMatch with distance=0 zero-fills" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    win.putByte('A');
    win.copyMatch(0, 3); // invalid distance

    try testing.expectEqual(@as(u64, 4), win.total_written);
    try testing.expectEqual(@as(u8, 0), win.buffer[1]);
    try testing.expectEqual(@as(u8, 0), win.buffer[2]);
    try testing.expectEqual(@as(u8, 0), win.buffer[3]);
}

test "copyMatch with distance > total_written zero-fills" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    win.putByte('A');
    win.copyMatch(5, 2); // only 1 byte written, distance=5 is invalid

    try testing.expectEqual(@as(u64, 3), win.total_written);
    try testing.expectEqual(@as(u8, 0), win.buffer[1]);
    try testing.expectEqual(@as(u8, 0), win.buffer[2]);
}

test "circular buffer wrapping" {
    var win = try Window.init(testing.allocator, 4); // tiny 4-byte window
    defer win.deinit(testing.allocator);

    // Write 6 bytes - wraps around
    for ("ABCDEF") |c| win.putByte(c);

    try testing.expectEqual(@as(u64, 6), win.total_written);
    // Buffer should contain: E, F, C, D (positions 0,1 overwritten)
    // 4-byte buffer, write_pos wraps: A@0, B@1, C@2, D@3, E@0, F@1
    try testing.expectEqual(@as(u8, 'E'), win.buffer[0]);
    try testing.expectEqual(@as(u8, 'F'), win.buffer[1]);
    try testing.expectEqual(@as(u8, 'C'), win.buffer[2]);
    try testing.expectEqual(@as(u8, 'D'), win.buffer[3]);
}

test "getByte retrieves from distance" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    for ("HELLO") |c| win.putByte(c);

    try testing.expectEqual(@as(u8, 'O'), win.getByte(1)); // most recent
    try testing.expectEqual(@as(u8, 'L'), win.getByte(2));
    try testing.expectEqual(@as(u8, 'H'), win.getByte(5));
    try testing.expectEqual(@as(u8, 0), win.getByte(0)); // invalid
    try testing.expectEqual(@as(u8, 0), win.getByte(10)); // beyond written
}

test "initFromBits creates correct size" {
    var win = try Window.initFromBits(testing.allocator, 10); // 1024 bytes
    defer win.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1024), win.buffer.len);
    try testing.expectEqual(@as(usize, 1023), win.mask);
}

test "copyToOutput reads from window" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    for ("HELLO") |c| win.putByte(c);

    var out: [5]u8 = undefined;
    const copied = win.copyToOutput(&out, 5, 5);
    try testing.expectEqual(@as(usize, 5), copied);
    try testing.expectEqualSlices(u8, "HELLO", &out);
}

test "copyToOutput with partial read" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    for ("ABCDE") |c| win.putByte(c);

    var out: [3]u8 = undefined;
    const copied = win.copyToOutput(&out, 5, 5); // output too small
    try testing.expectEqual(@as(usize, 3), copied);
    try testing.expectEqualSlices(u8, "ABC", &out);
}

test "copyMatch with wrap-around copy" {
    var win = try Window.init(testing.allocator, 4); // tiny 4-byte window
    defer win.deinit(testing.allocator);

    // Fill buffer: A@0, B@1, C@2, D@3
    for ("ABCD") |c| win.putByte(c);
    // Now write_pos=4, which maps to physical pos 0
    // Copy from distance=4, length=2 -> copies A, B from wrapped positions
    win.copyMatch(4, 2);

    try testing.expectEqual(@as(u64, 6), win.total_written);
    // After copy: A was at physical 0, now overwritten with A (from distance 4)
    // B was at physical 1, now overwritten with B (from distance 3 at that point)
    try testing.expectEqual(@as(u8, 'A'), win.buffer[0]);
    try testing.expectEqual(@as(u8, 'B'), win.buffer[1]);
}

test "copyMatch overlap pattern ABAB" {
    var win = try Window.init(testing.allocator, 16);
    defer win.deinit(testing.allocator);

    // Write "AB"
    win.putByte('A');
    win.putByte('B');
    // Copy from distance=2, length=4 -> should produce ABAB
    win.copyMatch(2, 4);

    try testing.expectEqual(@as(u64, 6), win.total_written);
    try testing.expectEqual(@as(u8, 'A'), win.buffer[2]);
    try testing.expectEqual(@as(u8, 'B'), win.buffer[3]);
    try testing.expectEqual(@as(u8, 'A'), win.buffer[4]);
    try testing.expectEqual(@as(u8, 'B'), win.buffer[5]);
}
