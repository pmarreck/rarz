// Diagnostic harness for the payload CRC32 false positive.
// Walks an archive's RAR5 file blocks, prints stored vs computed CRC for each,
// and identifies which entry fails. Build with `zig build` after wiring this
// in build.zig — but we'll just `zig run` it directly.

const std = @import("std");
const rarz = @import("rarz");
const detect = rarz.detect;
const integrity = rarz.integrity;
const rar5_headers = rarz.rar5_headers;
const dispatch = rarz.dispatch;

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const alloc = gpa.allocator();

	var args = try std.process.argsWithAllocator(alloc);
	defer args.deinit();
	_ = args.next(); // exe name
	const path = args.next() orelse {
		std.debug.print("usage: diagnose_crc <archive.rar> [--extract <idx> <out.rar>]\n", .{});
		return error.MissingArg;
	};

	// Optional --extract <idx> <out.rar> mode: write a minimal RAR5 archive
	// containing only the file block at the given 1-based index, plus a fresh
	// main + end block. This is used to capture a small in-repo regression
	// fixture from the original failing archive without committing the full file.
	var extract_idx: ?usize = null;
	var extract_out: ?[]const u8 = null;
	while (args.next()) |a| {
		if (std.mem.eql(u8, a, "--extract")) {
			const idx_s = args.next() orelse return error.MissingArg;
			extract_idx = try std.fmt.parseInt(usize, idx_s, 10);
			extract_out = args.next() orelse return error.MissingArg;
		}
	}

	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();
	const stat = try file.stat();
	const data = try alloc.alloc(u8, stat.size);
	defer alloc.free(data);
	_ = try file.readAll(data);

	const fmt = detect.detect_format(data, 0);
	std.debug.print("family={?} sig_offset={} sig_len={}\n", .{ fmt.family, fmt.signature_offset, fmt.signature_len });
	if (fmt.family != .rar50) {
		std.debug.print("not RAR5\n", .{});
		return;
	}

	const block_start = fmt.signature_offset + fmt.signature_len;
	var iter = rar5_headers.walk_blocks(data[block_start..]);

	var idx: usize = 0;
	var first_file_offset: ?usize = null;
	var extract_block_offset: ?usize = null;
	var extract_payload_end: ?usize = null;

	while (true) {
		const maybe = iter.next() catch |e| {
			std.debug.print("walk error: {}\n", .{e});
			return;
		};
		const block = maybe orelse break;

		switch (block) {
			.main => |m| {
				std.debug.print("\nMAIN block: solid={} volume={} volume_number={?}\n", .{ m.solid, m.volume, m.volume_number });
			},
			.file => |f| {
				idx += 1;
				const total_header = 4 + f.header.crc_data_len;
				const block_offset_in_data = block_start + f.header.header_start;
				const payload_start = block_offset_in_data + total_header;
				const data_size = f.header.data_size orelse 0;
				const payload_end = payload_start + @as(usize, @intCast(data_size));

				if (first_file_offset == null) first_file_offset = block_offset_in_data;
				if (extract_idx) |eidx| {
					if (idx == eidx) {
						extract_block_offset = block_offset_in_data;
						extract_payload_end = payload_end;
					}
				}

				std.debug.print("\n#{d} name={s}\n", .{ idx, f.name });
				std.debug.print("  method={} unpacked_size={} packed_size={}\n", .{ f.compression.method, f.unpacked_size, data_size });
				std.debug.print("  algo_version={} compression.solid={} dict_bits={} dict_frac_bits={}\n", .{ f.compression.algo_version, f.compression.solid, f.compression.dict_bits, f.compression.dict_frac_bits });
				std.debug.print("  header_start={} crc_data_len={} payload[{}..{}]\n", .{ f.header.header_start, f.header.crc_data_len, payload_start, payload_end });
				std.debug.print("  flags split_before={} split_after={}\n", .{ f.header.flags.split_before, f.header.flags.split_after });
				std.debug.print("  has_crc32={} stored_crc=0x{X:0>8}\n", .{ f.has_crc32, f.data_crc32 orelse 0 });

				if (extract_idx != null) {
					// In extract mode, skip the verify computation to keep it fast
					continue;
				}

				if (f.header.flags.split_before or f.header.flags.split_after) {
					std.debug.print("  -> split, skipping\n", .{});
					continue;
				}
				if (!f.has_crc32) {
					std.debug.print("  -> no crc32 stored\n", .{});
					continue;
				}
				if (payload_end > data.len) {
					std.debug.print("  -> payload OOB\n", .{});
					continue;
				}
				const payload = data[payload_start..payload_end];

				if (f.compression.method == 0) {
					const computed = integrity.crc32(payload);
					const stored = f.data_crc32.?;
					const ok = computed == stored;
					std.debug.print("  store-method computed=0x{X:0>8} {s}\n", .{ computed, if (ok) "OK" else "MISMATCH" });
					if (!ok) {
						std.debug.print("  ! XOR=0x{X:0>8}\n", .{ computed ^ stored });
					}
				} else {
					const decompressed = dispatch.decompressRar5(alloc, payload, f.unpacked_size, f.compression) catch |e| {
						std.debug.print("  decompress failed: {}\n", .{e});
						continue;
					};
					defer alloc.free(decompressed);
					const computed = integrity.crc32(decompressed);
					const stored = f.data_crc32.?;
					const ok = computed == stored;
					std.debug.print("  compressed decompressed_len={} computed=0x{X:0>8} {s}\n", .{ decompressed.len, computed, if (ok) "OK" else "MISMATCH" });
					if (!ok) {
						std.debug.print("  ! XOR=0x{X:0>8}\n", .{ computed ^ stored });
					}
				}
			},
			.end_archive => break,
			else => {},
		}
	}

	if (extract_idx) |eidx| {
		const off = extract_block_offset orelse {
			std.debug.print("entry {d} not found\n", .{eidx});
			return error.NotFound;
		};
		const pend = extract_payload_end.?;
		_ = first_file_offset.?;

		// Build minimal archive: fresh sig + fresh minimal main + copied file block + fresh end.
		// We deliberately don't copy the source archive's main block because it contains a
		// Locator extra record (0x01) pointing to a QuickOpen offset that won't exist in the
		// truncated fixture, which makes unrar emit "Unexpected end of archive".
		var out: std.ArrayList(u8) = .empty;
		defer out.deinit(alloc);

		// Signature (8 bytes)
		try out.appendSlice(alloc, &[_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 });

		// Minimal main block: header_type=1, header_flags=0, archive_flags=0 (3 bytes contents)
		{
			var contents: [3]u8 = .{ 1, 0, 0 };
			var tmp: [4]u8 = undefined;
			tmp[0] = @intCast(contents.len);
			@memcpy(tmp[1..4], &contents);
			const crc = integrity.crc32(tmp[0..4]);
			var crc_bytes: [4]u8 = undefined;
			std.mem.writeInt(u32, &crc_bytes, crc, .little);
			try out.appendSlice(alloc, &crc_bytes);
			try out.appendSlice(alloc, tmp[0..4]);
		}

		// Copy the chosen file block (header + payload) byte-for-byte from the source
		try out.appendSlice(alloc, data[off..pend]);

		// End-of-archive block: header_type=5, header_flags=4 (skip_if_unknown), end_flags=0
		{
			var contents: [3]u8 = .{ 5, 4, 0 };
			var tmp: [4]u8 = undefined;
			tmp[0] = @intCast(contents.len);
			@memcpy(tmp[1..4], &contents);
			const crc = integrity.crc32(tmp[0..4]);
			var crc_bytes: [4]u8 = undefined;
			std.mem.writeInt(u32, &crc_bytes, crc, .little);
			try out.appendSlice(alloc, &crc_bytes);
			try out.appendSlice(alloc, tmp[0..4]);
		}

		const out_path = extract_out.?;
		const out_file = try std.fs.cwd().createFile(out_path, .{});
		defer out_file.close();
		try out_file.writeAll(out.items);
		std.debug.print("\nWrote {} bytes to {s}\n", .{ out.items.len, out_path });
	}
}
