const std = @import("std");
const rarz = @import("rarz");
const integrity = rarz.integrity;

const ITERATIONS = 100;
const BUFFER_SIZE = 1024 * 1024; // 1MB

fn printLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Generate 1MB test buffer with pseudo-random data
    const buffer = try allocator.alloc(u8, BUFFER_SIZE);
    defer allocator.free(buffer);
    for (buffer, 0..) |*b, i| {
        b.* = @truncate(i *% 0x9E3779B1 +% 0xDEADBEEF);
    }

    // === CRC32 Benchmark ===
    {
        var timer = try std.time.Timer.start();
        var crc: u32 = 0;
        for (0..ITERATIONS) |_| {
            crc = integrity.crc32(buffer);
            std.mem.doNotOptimizeAway(&crc);
        }
        const elapsed_ns = timer.read();
        const total_bytes = BUFFER_SIZE * ITERATIONS;
        const mbps = @as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0) / (1024.0 * 1024.0);
        printLine("CRC32 1MB x {d}: {d:.1} ms total, {d:.0} MB/s (last={x:08})\n", .{
            ITERATIONS,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            mbps,
            crc,
        });
    }

    // === BLAKE2sp Benchmark ===
    {
        var timer = try std.time.Timer.start();
        var hash: [32]u8 = undefined;
        for (0..ITERATIONS) |_| {
            integrity.blake2sp(buffer, &hash);
            std.mem.doNotOptimizeAway(&hash);
        }
        const elapsed_ns = timer.read();
        const total_bytes = BUFFER_SIZE * ITERATIONS;
        const mbps = @as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0) / (1024.0 * 1024.0);
        printLine("BLAKE2sp 1MB x {d}: {d:.1} ms total, {d:.0} MB/s\n", .{
            ITERATIONS,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            mbps,
        });
    }
}
