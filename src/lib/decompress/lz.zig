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
    /// Uses byte-by-byte copy to handle overlap (distance < length) correctly.
    /// If distance > total_written (invalid reference), zero-fills.
    pub fn copyMatch(self: *Window, distance: usize, length: usize) void {
        if (distance == 0 or distance > self.total_written) {
            // Invalid distance: zero-fill for corruption hardening
            for (0..length) |_| {
                self.putByte(0);
            }
            return;
        }

        var src_pos = self.write_pos -% distance; // wrapping subtract
        for (0..length) |_| {
            const byte = self.buffer[src_pos & self.mask];
            self.putByte(byte);
            src_pos +%= 1;
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
