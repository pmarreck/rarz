//! RAR5 archive writer.
//!
//! Produces valid RAR5 archives with store (method=0) or compressed (method=1-5) modes.
//! Archives contain: signature, main block, file blocks with data, end block.

const std = @import("std");
const integrity = @import("integrity.zig");
const detect = @import("detect.zig");
const rar5_headers = @import("rar5_headers.zig");
const policy = @import("policy.zig");
const reader_mod = @import("reader.zig");
const pack50 = @import("compress/pack50.zig");

pub const encode_vint = reader_mod.encode_vint;
pub const vint_size = reader_mod.vint_size;

// ============================================================================
// Types
// ============================================================================

pub const FileEntry = struct {
	name: []const u8, // UTF-8 filename
	data: []const u8, // file content
	mtime: u32, // Unix timestamp (DOS format)
	is_directory: bool,
};

pub const WriteError = error{
	BufferTooSmall,
	NameTooLong,
	TooManyFiles,
};

// ============================================================================
// Block writers
// ============================================================================

/// Write the 8-byte RAR5 signature. Returns new position.
fn write_signature(out: []u8, pos: usize) usize {
	@memcpy(out[pos..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);
	return pos + detect.RAR50_SIG.len;
}

/// Write a minimal main block (no volume, not solid). Returns new position.
fn write_main_block(out: []u8, pos: usize) usize {
	// Main block body: archive_flags vint = 0 (no volume, no solid)
	// Block structure:
	//   [4 bytes CRC32] [header_size vint] [type vint=1] [flags vint=0] [archive_flags vint=0]

	// Compute body contents first (type + flags + body)
	var contents: [32]u8 = undefined;
	var cpos: usize = 0;

	// header_type = 1 (main)
	cpos += encode_vint(1, contents[cpos..]);
	// header_flags = 0
	cpos += encode_vint(0, contents[cpos..]);
	// archive_flags = 0
	cpos += encode_vint(0, contents[cpos..]);

	// Build header_size_vint + contents into temp buffer
	var tmp: [64]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]); // header_size = length of contents
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	// CRC32 over header_size_vint + contents
	const crc = integrity.crc32(tmp[0..tpos]);

	// Write CRC32 (little-endian)
	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	// Write header_size_vint + contents
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);

	return pos + 4 + tpos;
}

/// Calculate the size of the main block in bytes.
fn main_block_size() usize {
	// CRC32(4) + header_size_vint(1) + type_vint(1) + flags_vint(1) + archive_flags_vint(1)
	// All vints here are single-byte since values are 0, 0, and 1
	const contents_size: usize = vint_size(1) + vint_size(0) + vint_size(0); // type=1, flags=0, archive_flags=0
	return 4 + vint_size(contents_size) + contents_size;
}

/// Write a file block header + store data for one entry. Returns new position.
fn write_file_block(out: []u8, pos: usize, entry: FileEntry) usize {
	// File block body fields:
	//   file_flags: FHFL_UTIME (0x02) | FHFL_CRC32 (0x04) = 0x06
	//   unpacked_size
	//   attributes
	//   mtime (u32 LE, because FHFL_UTIME is set)
	//   data_crc32 (u32 LE, because FHFL_CRC32 is set)
	//   compression_info = 0 (store: method=0, algo_version=0, dict_bits=0)
	//   host_os = 0 (Windows)
	//   name_length
	//   name bytes

	const data_crc = integrity.crc32(entry.data);
	const data_size: u64 = if (entry.is_directory) 0 else entry.data.len;

	// File flags
	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01; // FHFL_DIRECTORY
	file_flags |= 0x02; // FHFL_UTIME
	if (!entry.is_directory) file_flags |= 0x04; // FHFL_CRC32

	// Attributes: 0x10 for directories, 0x20 for files
	const attributes: u64 = if (entry.is_directory) 0x10 else 0x20;

	// Build the file-specific body
	var body: [4096]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(file_flags, body[bpos..]);
	bpos += encode_vint(if (entry.is_directory) 0 else entry.data.len, body[bpos..]); // unpacked_size
	bpos += encode_vint(attributes, body[bpos..]);
	// mtime (u32 LE)
	std.mem.writeInt(u32, body[bpos..][0..4], entry.mtime, .little);
	bpos += 4;
	// data_crc32 (u32 LE) - only if not directory
	if (!entry.is_directory) {
		std.mem.writeInt(u32, body[bpos..][0..4], data_crc, .little);
		bpos += 4;
	}
	// compression_info = 0 (store)
	bpos += encode_vint(0, body[bpos..]);
	// host_os = 0 (Windows)
	bpos += encode_vint(0, body[bpos..]);
	// name_length
	bpos += encode_vint(entry.name.len, body[bpos..]);
	// name
	@memcpy(body[bpos..][0..entry.name.len], entry.name);
	bpos += entry.name.len;

	// Header flags: HFL_DATA (0x02) if we have data
	const header_flags: u64 = if (data_size > 0) 0x02 else 0;

	// Build the full contents (type + flags + [data_size] + body)
	var contents: [4096]u8 = undefined;
	var cpos: usize = 0;
	// header_type = 2 (file)
	cpos += encode_vint(2, contents[cpos..]);
	// header_flags
	cpos += encode_vint(header_flags, contents[cpos..]);
	// data_size (only if HFL_DATA is set)
	if (data_size > 0) {
		cpos += encode_vint(data_size, contents[cpos..]);
	}
	// file body
	@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
	cpos += bpos;

	// Build header_size_vint + contents
	var tmp: [8192]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]); // header_size
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	// CRC32 over header_size_vint + contents
	const crc = integrity.crc32(tmp[0..tpos]);

	// Write CRC32
	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	// Write header
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);
	var new_pos = pos + 4 + tpos;

	// Write data area (file content) after header
	if (data_size > 0) {
		@memcpy(out[new_pos..][0..entry.data.len], entry.data);
		new_pos += entry.data.len;
	}

	return new_pos;
}

/// Calculate the size of a file block (header + data) for one entry.
fn file_block_size(entry: FileEntry) usize {
	const data_size: u64 = if (entry.is_directory) 0 else entry.data.len;

	// File flags
	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01;
	file_flags |= 0x02; // FHFL_UTIME
	if (!entry.is_directory) file_flags |= 0x04; // FHFL_CRC32

	const attributes: u64 = if (entry.is_directory) 0x10 else 0x20;

	// Body size calculation
	var body_size: usize = 0;
	body_size += vint_size(file_flags);
	body_size += vint_size(if (entry.is_directory) 0 else entry.data.len); // unpacked_size
	body_size += vint_size(attributes);
	body_size += 4; // mtime (u32)
	if (!entry.is_directory) body_size += 4; // data_crc32 (u32)
	body_size += vint_size(0); // compression_info
	body_size += vint_size(0); // host_os
	body_size += vint_size(entry.name.len); // name_length
	body_size += entry.name.len; // name

	// Header flags
	const header_flags: u64 = if (data_size > 0) 0x02 else 0;

	// Contents size (type + flags + [data_size] + body)
	var contents_size: usize = 0;
	contents_size += vint_size(2); // type
	contents_size += vint_size(header_flags); // flags
	if (data_size > 0) {
		contents_size += vint_size(data_size); // data_size
	}
	contents_size += body_size;

	// Total: CRC32(4) + header_size_vint + contents + data_area
	return 4 + vint_size(contents_size) + contents_size + @as(usize, @intCast(data_size));
}

/// Write end-of-archive block. Returns new position.
fn write_end_block(out: []u8, pos: usize) usize {
	// End block: type=5, flags=0, body=end_flags(0)
	var contents: [32]u8 = undefined;
	var cpos: usize = 0;

	// header_type = 5 (end_archive)
	cpos += encode_vint(5, contents[cpos..]);
	// header_flags = 0
	cpos += encode_vint(0, contents[cpos..]);
	// end_flags = 0 (no next volume)
	cpos += encode_vint(0, contents[cpos..]);

	var tmp: [64]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]); // header_size
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	const crc = integrity.crc32(tmp[0..tpos]);

	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);

	return pos + 4 + tpos;
}

/// Calculate the size of the end block.
fn end_block_size() usize {
	const contents_size: usize = vint_size(5) + vint_size(0) + vint_size(0); // type=5, flags=0, end_flags=0
	return 4 + vint_size(contents_size) + contents_size;
}

// ============================================================================
// Public API
// ============================================================================

/// Calculate the total size needed for the archive.
/// This lets callers pre-allocate.
pub fn calculate_archive_size(entries: []const FileEntry) usize {
	var size: usize = 0;

	// RAR5 signature
	size += detect.RAR50_SIG.len;

	// Main block
	size += main_block_size();

	// File blocks
	for (entries) |entry| {
		size += file_block_size(entry);
	}

	// End block
	size += end_block_size();

	return size;
}

/// Write a complete RAR5 store-only archive to the output buffer.
/// Returns the number of bytes written.
pub fn write_archive(entries: []const FileEntry, output: []u8) WriteError!usize {
	const needed = calculate_archive_size(entries);
	if (output.len < needed) return error.BufferTooSmall;

	// Validate entries
	for (entries) |entry| {
		if (entry.name.len > 4096) return error.NameTooLong;
	}
	if (entries.len > 65535) return error.TooManyFiles;

	var pos: usize = 0;

	// Signature
	pos = write_signature(output, pos);

	// Main block
	pos = write_main_block(output, pos);

	// File blocks
	for (entries) |entry| {
		pos = write_file_block(output, pos, entry);
	}

	// End block
	pos = write_end_block(output, pos);

	return pos;
}

/// Encode compression_info for a RAR5 file block.
/// Format: (algo_version & 0x3F) | (solid << 6) | (method << 7) | (dict_bits << 10)
/// dict_bits: offset from 17, so actual window = 2^(dict_bits + 17).
///   0 = 128KB, 3 = 1MB, 6 = 8MB, 10 = 128MB
fn encode_compression_info(method: u3, dict_bits: u4) u64 {
	const algo_version: u64 = 0; // standard RAR5 algorithm
	return (algo_version & 0x3F) | (@as(u64, method) << 7) | (@as(u64, dict_bits) << 10);
}

/// Write a compressed file block (header + compressed data). Returns new position.
/// Uses a two-pass approach: compress first, then write header with known sizes.
fn write_file_block_compressed(
	allocator: std.mem.Allocator,
	out: []u8,
	pos: usize,
	entry: FileEntry,
	method: u3,
) !usize {
	// Compress the data
	const compressed_data = try pack50.compressBlock(allocator, entry.data, method, true);
	defer allocator.free(compressed_data);

	const data_crc = integrity.crc32(entry.data);

	// File flags: FHFL_UTIME | FHFL_CRC32
	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01;
	file_flags |= 0x02; // FHFL_UTIME
	if (!entry.is_directory) file_flags |= 0x04; // FHFL_CRC32

	const attributes: u64 = if (entry.is_directory) 0x10 else 0x20;
	const dict_bits: u4 = 3; // 2^(3+17) = 1MB dictionary

	// Build file body
	var body: [4096]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(file_flags, body[bpos..]);
	bpos += encode_vint(entry.data.len, body[bpos..]); // unpacked_size
	bpos += encode_vint(attributes, body[bpos..]);
	// mtime (u32 LE)
	std.mem.writeInt(u32, body[bpos..][0..4], entry.mtime, .little);
	bpos += 4;
	// data_crc32
	if (!entry.is_directory) {
		std.mem.writeInt(u32, body[bpos..][0..4], data_crc, .little);
		bpos += 4;
	}
	// compression_info
	bpos += encode_vint(encode_compression_info(method, dict_bits), body[bpos..]);
	// host_os = 0
	bpos += encode_vint(0, body[bpos..]);
	// name
	bpos += encode_vint(entry.name.len, body[bpos..]);
	@memcpy(body[bpos..][0..entry.name.len], entry.name);
	bpos += entry.name.len;

	const data_size: u64 = compressed_data.len;
	const header_flags: u64 = if (data_size > 0) 0x02 else 0;

	// Build contents
	var contents: [4096]u8 = undefined;
	var cpos: usize = 0;
	cpos += encode_vint(2, contents[cpos..]); // type = file
	cpos += encode_vint(header_flags, contents[cpos..]);
	if (data_size > 0) {
		cpos += encode_vint(data_size, contents[cpos..]);
	}
	@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
	cpos += bpos;

	// header_size + contents
	var tmp: [8192]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]);
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	const crc = integrity.crc32(tmp[0..tpos]);

	// Write CRC32
	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);
	var new_pos = pos + 4 + tpos;

	// Write compressed data
	if (data_size > 0) {
		@memcpy(out[new_pos..][0..compressed_data.len], compressed_data);
		new_pos += compressed_data.len;
	}

	return new_pos;
}

/// Write a complete RAR5 archive with compression to the output buffer.
/// method: 0=store, 1-5=compression levels.
/// For method 0, delegates to write_archive.
/// Returns the number of bytes written.
pub fn write_archive_compressed(
	allocator: std.mem.Allocator,
	entries: []const FileEntry,
	output: []u8,
	method: u3,
) !usize {
	if (method == 0) {
		return write_archive(entries, output) catch |err| switch (err) {
			error.BufferTooSmall => return error.BufferTooSmall,
			error.NameTooLong => return error.NameTooLong,
			error.TooManyFiles => return error.TooManyFiles,
		};
	}

	// Validate entries
	for (entries) |entry| {
		if (entry.name.len > 4096) return error.NameTooLong;
	}
	if (entries.len > 65535) return error.TooManyFiles;

	var pos: usize = 0;

	// Signature
	pos = write_signature(output, pos);

	// Main block
	pos = write_main_block(output, pos);

	// File blocks (compressed)
	for (entries) |entry| {
		if (entry.is_directory or entry.data.len == 0) {
			// Directories and empty files: store mode
			pos = write_file_block(output, pos, entry);
		} else {
			pos = try write_file_block_compressed(allocator, output, pos, entry, method);
		}
	}

	// End block
	pos = write_end_block(output, pos);

	return pos;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "encode_vint encodes single byte" {
	var buf: [16]u8 = undefined;
	const len = encode_vint(0x42, &buf);
	try testing.expectEqual(@as(usize, 1), len);
	try testing.expectEqual(@as(u8, 0x42), buf[0]);
}

test "encode_vint encodes two bytes" {
	var buf: [16]u8 = undefined;
	// 0x2101 = 0x01 | (0x42 << 7)
	// byte0: 0x01 | 0x80 (continue) = 0x81
	// byte1: 0x42 (no continue)
	const len = encode_vint(0x2101, &buf);
	try testing.expectEqual(@as(usize, 2), len);
	try testing.expectEqual(@as(u8, 0x81), buf[0]);
	try testing.expectEqual(@as(u8, 0x42), buf[1]);
}

test "encode_vint encodes zero" {
	var buf: [16]u8 = undefined;
	const len = encode_vint(0, &buf);
	try testing.expectEqual(@as(usize, 1), len);
	try testing.expectEqual(@as(u8, 0x00), buf[0]);
}

test "encode_vint encodes 0x7F (max single byte)" {
	var buf: [16]u8 = undefined;
	const len = encode_vint(0x7F, &buf);
	try testing.expectEqual(@as(usize, 1), len);
	try testing.expectEqual(@as(u8, 0x7F), buf[0]);
}

test "encode_vint encodes 0x80 (first two-byte value)" {
	var buf: [16]u8 = undefined;
	const len = encode_vint(0x80, &buf);
	try testing.expectEqual(@as(usize, 2), len);
	try testing.expectEqual(@as(u8, 0x80), buf[0]); // continue bit + 0x00
	try testing.expectEqual(@as(u8, 0x01), buf[1]); // 1
}

test "vint_size returns correct sizes" {
	try testing.expectEqual(@as(usize, 1), vint_size(0));
	try testing.expectEqual(@as(usize, 1), vint_size(0x7F));
	try testing.expectEqual(@as(usize, 2), vint_size(0x80));
	try testing.expectEqual(@as(usize, 2), vint_size(0x3FFF));
	try testing.expectEqual(@as(usize, 3), vint_size(0x4000));
	try testing.expectEqual(@as(usize, 10), vint_size(std.math.maxInt(u64)));
}

test "vint_size matches encode_vint output" {
	const test_values = [_]u64{ 0, 1, 0x7F, 0x80, 0x2101, 0x3FFF, 0x4000, 12345, 0xFFFFFFFF, std.math.maxInt(u64) };
	var buf: [16]u8 = undefined;
	for (test_values) |v| {
		const encoded_len = encode_vint(v, &buf);
		try testing.expectEqual(encoded_len, vint_size(v));
	}
}

test "write_archive produces valid signature" {
	const entries = [_]FileEntry{};
	var buf: [256]u8 = undefined;
	const len = try write_archive(&entries, &buf);
	try testing.expect(len >= 8);
	try testing.expectEqualSlices(u8, &detect.RAR50_SIG, buf[0..8]);
}

test "write_archive round-trip with single file" {
	const file_data = "hello world";
	const entries = [_]FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0,
		.is_directory = false,
	}};

	var buf: [4096]u8 = undefined;
	const archive_len = try write_archive(&entries, &buf);

	// Parse back with rar5_headers
	const block_data = buf[detect.RAR50_SIG.len..archive_len];
	var iter = rar5_headers.walk_blocks(block_data);

	// Main block
	const block1 = (try iter.next()) orelse return error.EndOfData;
	switch (block1) {
		.main => {},
		else => return error.EndOfData,
	}

	// File block
	const block2 = (try iter.next()) orelse return error.EndOfData;
	switch (block2) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "test.txt", f.name);
			try testing.expectEqual(@as(u64, file_data.len), f.unpacked_size);
			try testing.expectEqual(@as(u3, 0), f.compression.method); // store
			try testing.expect(f.has_crc32);
			try testing.expectEqual(integrity.crc32(file_data), f.data_crc32.?);
			try testing.expect(f.has_mtime);
		},
		else => return error.EndOfData,
	}

	// End block
	const block3 = (try iter.next()) orelse return error.EndOfData;
	switch (block3) {
		.end_archive => {},
		else => return error.EndOfData,
	}

	// No more blocks
	const block4 = try iter.next();
	try testing.expectEqual(@as(?rar5_headers.ArchiveBlock, null), block4);
}

test "write_archive round-trip with multiple files" {
	const entries = [_]FileEntry{
		.{ .name = "a.txt", .data = "alpha", .mtime = 0x5A000000, .is_directory = false },
		.{ .name = "b.bin", .data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, .mtime = 0, .is_directory = false },
		.{ .name = "subdir", .data = "", .mtime = 0, .is_directory = true },
	};

	var buf: [8192]u8 = undefined;
	const archive_len = try write_archive(&entries, &buf);

	const block_data = buf[detect.RAR50_SIG.len..archive_len];
	var iter = rar5_headers.walk_blocks(block_data);

	// Skip main block
	_ = try iter.next();

	// File 1
	const b1 = (try iter.next()) orelse return error.EndOfData;
	switch (b1) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "a.txt", f.name);
			try testing.expectEqual(@as(u64, 5), f.unpacked_size);
			try testing.expectEqual(@as(u32, 0x5A000000), f.mtime.?);
		},
		else => return error.EndOfData,
	}

	// File 2
	const b2 = (try iter.next()) orelse return error.EndOfData;
	switch (b2) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "b.bin", f.name);
			try testing.expectEqual(@as(u64, 4), f.unpacked_size);
		},
		else => return error.EndOfData,
	}

	// File 3 (directory)
	const b3 = (try iter.next()) orelse return error.EndOfData;
	switch (b3) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "subdir", f.name);
			try testing.expect(f.is_directory);
			try testing.expectEqual(@as(u64, 0), f.unpacked_size);
		},
		else => return error.EndOfData,
	}

	// End block
	const b4 = (try iter.next()) orelse return error.EndOfData;
	switch (b4) {
		.end_archive => {},
		else => return error.EndOfData,
	}
}

test "write_archive CRC32 validates via policy" {
	const file_data = "Hello, RAR5 writer!";
	const entries = [_]FileEntry{.{
		.name = "greet.txt",
		.data = file_data,
		.mtime = 0x5B123456,
		.is_directory = false,
	}};

	var buf: [4096]u8 = undefined;
	const archive_len = try write_archive(&entries, &buf);

	const result = policy.validate(buf[0..archive_len]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(policy.ValidationDepth.full, result.depth);
	try testing.expectEqual(@as(u32, 1), result.file_count);
}

test "calculate_archive_size matches actual output" {
	const entries = [_]FileEntry{
		.{ .name = "test.txt", .data = "hello world", .mtime = 0, .is_directory = false },
		.{ .name = "dir", .data = "", .mtime = 0, .is_directory = true },
	};

	const predicted = calculate_archive_size(&entries);

	var buf: [8192]u8 = undefined;
	const actual = try write_archive(&entries, &buf);

	try testing.expectEqual(predicted, actual);
}

test "write_archive returns BufferTooSmall for insufficient buffer" {
	const entries = [_]FileEntry{.{
		.name = "test.txt",
		.data = "hello",
		.mtime = 0,
		.is_directory = false,
	}};

	var tiny: [8]u8 = undefined;
	const result = write_archive(&entries, &tiny);
	try testing.expectError(error.BufferTooSmall, result);
}

test "write_archive returns NameTooLong for oversized filename" {
	const long_name = "x" ** 4097;
	const entries = [_]FileEntry{.{
		.name = long_name,
		.data = "data",
		.mtime = 0,
		.is_directory = false,
	}};

	var buf: [65536]u8 = undefined;
	const result = write_archive(&entries, &buf);
	try testing.expectError(error.NameTooLong, result);
}

test "write_archive empty archive (no files)" {
	const entries = [_]FileEntry{};

	var buf: [256]u8 = undefined;
	const archive_len = try write_archive(&entries, &buf);

	const result = policy.validate(buf[0..archive_len]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(@as(u32, 0), result.file_count);
}

test "write_archive and extract round-trip through FFI" {
	// This tests the full cycle: write archive, open it, extract contents
	const file_data = "The quick brown fox jumps over the lazy dog";
	const entries = [_]FileEntry{.{
		.name = "fox.txt",
		.data = file_data,
		.mtime = 0,
		.is_directory = false,
	}};

	var archive_buf: [4096]u8 = undefined;
	const archive_len = try write_archive(&entries, &archive_buf);

	// Verify we can detect the format
	const format = detect.detect_format(archive_buf[0..archive_len], 0);
	try testing.expectEqual(detect.RarFamily.rar50, format.family.?);

	// Verify we can parse file blocks
	const block_data = archive_buf[format.signature_offset + format.signature_len .. archive_len];
	var iter = rar5_headers.walk_blocks(block_data);

	// Skip main
	_ = try iter.next();

	// Get file block
	const block = (try iter.next()) orelse return error.EndOfData;
	switch (block) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "fox.txt", f.name);
			try testing.expectEqual(@as(u64, file_data.len), f.unpacked_size);

			// Extract the data
			const total_header = 4 + f.header.crc_data_len;
			const payload_start = f.header.header_start + total_header;
			const ds = f.header.data_size orelse return error.EndOfData;
			const payload = block_data[payload_start .. payload_start + @as(usize, @intCast(ds))];
			try testing.expectEqualSlices(u8, file_data, payload);
		},
		else => return error.EndOfData,
	}
}

test "write_archive_compressed: method 0 delegates to store" {
	const file_data = "hello world";
	const entries = [_]FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0,
		.is_directory = false,
	}};

	var buf: [4096]u8 = undefined;
	const archive_len = try write_archive_compressed(testing.allocator, &entries, &buf, 0);

	// Should produce identical output to write_archive
	var buf2: [4096]u8 = undefined;
	const store_len = try write_archive(&entries, &buf2);
	try testing.expectEqual(store_len, archive_len);
	try testing.expectEqualSlices(u8, buf2[0..store_len], buf[0..archive_len]);
}

test "write_archive_compressed: method 3 produces valid archive" {
	const file_data = "Hello World! Hello World! Hello World!";
	const entries = [_]FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0,
		.is_directory = false,
	}};

	var buf: [8192]u8 = undefined;
	const archive_len = try write_archive_compressed(testing.allocator, &entries, &buf, 3);

	// Should be a valid RAR5 archive
	const format = detect.detect_format(buf[0..archive_len], 0);
	try testing.expectEqual(detect.RarFamily.rar50, format.family.?);

	// Parse blocks
	const block_data = buf[format.signature_offset + format.signature_len .. archive_len];
	var iter = rar5_headers.walk_blocks(block_data);

	// Main block
	const b1 = (try iter.next()) orelse return error.EndOfData;
	switch (b1) {
		.main => {},
		else => return error.EndOfData,
	}

	// File block
	const b2 = (try iter.next()) orelse return error.EndOfData;
	switch (b2) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "test.txt", f.name);
			try testing.expectEqual(@as(u64, file_data.len), f.unpacked_size);
			try testing.expect(f.compression.method > 0); // compressed, not store
		},
		else => return error.EndOfData,
	}

	// End block
	const b3 = (try iter.next()) orelse return error.EndOfData;
	switch (b3) {
		.end_archive => {},
		else => return error.EndOfData,
	}
}

test "write_archive_compressed: compress-then-extract round-trip" {
	const file_data = "The quick brown fox jumps over the lazy dog. The quick brown fox!";
	const entries = [_]FileEntry{.{
		.name = "fox.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	var buf: [8192]u8 = undefined;
	const archive_len = try write_archive_compressed(testing.allocator, &entries, &buf, 3);

	// Parse and extract via the decompression path
	const format = detect.detect_format(buf[0..archive_len], 0);
	const block_data = buf[format.signature_offset + format.signature_len .. archive_len];
	var iter = rar5_headers.walk_blocks(block_data);

	// Skip main
	_ = try iter.next();

	const block = (try iter.next()) orelse return error.EndOfData;
	switch (block) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "fox.txt", f.name);
			try testing.expectEqual(@as(u64, file_data.len), f.unpacked_size);

			// Extract compressed data
			const total_header = 4 + f.header.crc_data_len;
			const payload_start = f.header.header_start + total_header;
			const ds = f.header.data_size orelse return error.EndOfData;
			const packed_data = block_data[payload_start .. payload_start + @as(usize, @intCast(ds))];

			// Decompress
			const dispatch = @import("decompress/dispatch.zig");
			const decompressed = try dispatch.decompressRar5(
				testing.allocator,
				packed_data,
				f.unpacked_size,
				f.compression,
			);
			defer testing.allocator.free(decompressed);

			try testing.expectEqualSlices(u8, file_data, decompressed);
		},
		else => return error.EndOfData,
	}
}

test "encode_compression_info: store mode" {
	const info = encode_compression_info(0, 0);
	try testing.expectEqual(@as(u64, 0), info); // algo_version=0, method=0, dict=0
}

test "encode_compression_info: method 3 with dict_bits=3 (1MB)" {
	const info = encode_compression_info(3, 3);
	// Round-trip through the parser
	const parsed = rar5_headers.parse_compression_info(info);
	try testing.expectEqual(@as(u6, 0), parsed.algo_version);
	try testing.expectEqual(@as(u3, 3), parsed.method);
	try testing.expectEqual(@as(u4, 3), parsed.dict_bits);
	try testing.expect(!parsed.solid);
}
