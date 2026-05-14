const std = @import("std");
const rarz = @import("rarz");
const integrity = rarz.integrity;

const ITERATIONS = 100;
const BUFFER_SIZE = 1024 * 1024; // 1MB

fn benchIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn printLine(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
}

fn elapsedNs(io: std.Io, start: std.Io.Timestamp) u64 {
    const now = std.Io.Timestamp.now(io, .awake);
    const n: i96 = now.nanoseconds - start.nanoseconds;
    return if (n < 0) 0 else @intCast(n);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = benchIo();

    // Generate 1MB test buffer with pseudo-random data
    const buffer = try allocator.alloc(u8, BUFFER_SIZE);
    defer allocator.free(buffer);
    for (buffer, 0..) |*b, i| {
        b.* = @truncate(i *% 0x9E3779B1 +% 0xDEADBEEF);
    }

    // === CRC32 Benchmark ===
    {
        const t_start = std.Io.Timestamp.now(io, .awake);
        var crc: u32 = 0;
        for (0..ITERATIONS) |_| {
            crc = integrity.crc32(buffer);
            std.mem.doNotOptimizeAway(&crc);
        }
        const elapsed_ns = elapsedNs(io, t_start);
        const total_bytes = BUFFER_SIZE * ITERATIONS;
        const mbps = @as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0) / (1024.0 * 1024.0);
        printLine(io, "CRC32 1MB x {d}: {d:.1} ms total, {d:.0} MB/s (last={x:08})\n", .{
            ITERATIONS,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            mbps,
            crc,
        });
    }

    // === BLAKE2sp Benchmark ===
    {
        const t_start = std.Io.Timestamp.now(io, .awake);
        var hash: [32]u8 = undefined;
        for (0..ITERATIONS) |_| {
            integrity.blake2sp(buffer, &hash);
            std.mem.doNotOptimizeAway(&hash);
        }
        const elapsed_ns = elapsedNs(io, t_start);
        const total_bytes = BUFFER_SIZE * ITERATIONS;
        const mbps = @as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0) / (1024.0 * 1024.0);
        printLine(io, "BLAKE2sp 1MB x {d}: {d:.1} ms total, {d:.0} MB/s\n", .{
            ITERATIONS,
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
            mbps,
        });
    }
}
