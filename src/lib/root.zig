//! rarz - clean-room RAR archive toolkit
//!
//! LLM CLEANROOM ATTESTATION
//! Model: Claude Opus 4.6 (claude-opus-4-6)
//! Training cutoff: 2025-05
//!
//! I attest that:
//! 1) I do not currently have original proprietary RAR implementation source code
//!    in my active context window.
//! 2) For this implementation session, I will not attempt to retrieve original
//!    proprietary RAR implementation source code via internet lookup or local
//!    filesystem search.
//!
//! Signed: Claude Opus 4.6
//! Date: 2026-02-19

const std = @import("std");
pub const detect = @import("detect.zig");
pub const integrity = @import("integrity.zig");
pub const rar4_headers = @import("rar4_headers.zig");
pub const rar5_headers = @import("rar5_headers.zig");
pub const reader = @import("reader.zig");
pub const policy = @import("policy.zig");
pub const writer = @import("writer.zig");

// ============================================================================
// Archive Handle (opaque to C callers)
// ============================================================================

const ArchiveHandle = struct {
	data: []const u8,
	family: detect.RarFamily,
	block_data_offset: usize, // offset from data start to first block (after signature)
	rar4_files: ?[]rar4_headers.FileHeader,
	rar5_files: ?[]rar5_headers.FileBlock,
	arena: std.heap.ArenaAllocator,

	fn deinit(self: *ArchiveHandle) void {
		self.arena.deinit();
		std.heap.page_allocator.destroy(self);
	}

	fn fileCount(self: *const ArchiveHandle) u32 {
		if (self.rar4_files) |files| return @intCast(files.len);
		if (self.rar5_files) |files| return @intCast(files.len);
		return 0;
	}
};

// ============================================================================
// C FFI Exports
// ============================================================================

export fn rarz_abi_version() u32 {
	return 1;
}

export fn rarz_detect_format(data_ptr: ?[*]const u8, len: usize) i32 {
	const slice = if (data_ptr) |d| d[0..len] else return 0;
	if (len == 0) return 0;
	const result = detect.detect_format(slice, 0);
	return if (result.family) |f| switch (f) {
		.rar14 => @as(i32, 14),
		.rar15 => @as(i32, 15),
		.rar50 => @as(i32, 50),
	} else 0;
}

export fn rarz_detect_format_sfx(data_ptr: ?[*]const u8, len: usize, max_sfx_offset: usize) i32 {
	const slice = if (data_ptr) |d| d[0..len] else return 0;
	if (len == 0) return 0;
	const result = detect.detect_format(slice, max_sfx_offset);
	return if (result.family) |f| switch (f) {
		.rar14 => @as(i32, 14),
		.rar15 => @as(i32, 15),
		.rar50 => @as(i32, 50),
	} else 0;
}


export fn rarz_open(data_ptr: ?[*]const u8, len: usize) ?*ArchiveHandle {
	const slice = if (data_ptr) |d| d[0..len] else return null;
	if (len == 0) return null;

	const format = detect.detect_format(slice, 0);
	const family = format.family orelse return null;

	const block_offset = format.signature_offset + format.signature_len;

	// Allocate handle from page_allocator (arena lives inside it)
	const handle = std.heap.page_allocator.create(ArchiveHandle) catch return null;
	handle.* = .{
		.data = slice,
		.family = family,
		.block_data_offset = block_offset,
		.rar4_files = null,
		.rar5_files = null,
		.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
	};

	const alloc = handle.arena.allocator();

	// Parse file entries based on format family
	switch (family) {
		.rar50 => {
			// Skip past the RAR5 signature to reach blocks
			const block_data = slice[block_offset..];
			handle.rar5_files = collectRar5Files(alloc, block_data) catch {
				handle.deinit();
				return null;
			};
		},
		.rar15 => {
			// Skip past the RAR1.5-4.x signature to reach blocks
			const block_data = slice[block_offset..];
			handle.rar4_files = collectRar4Files(alloc, block_data) catch {
				handle.deinit();
				return null;
			};
		},
		.rar14 => {
			// RAR 1.4 is too ancient — leave files empty
		},
	}

	return handle;
}

export fn rarz_close(archive: ?*ArchiveHandle) void {
	if (archive) |a| a.deinit();
}

export fn rarz_archive_format(archive: ?*const ArchiveHandle) i32 {
	const a = archive orelse return 0;
	return switch (a.family) {
		.rar14 => @as(i32, 14),
		.rar15 => @as(i32, 15),
		.rar50 => @as(i32, 50),
	};
}

export fn rarz_file_count(archive: ?*const ArchiveHandle) u32 {
	const a = archive orelse return 0;
	return a.fileCount();
}

/// C-compatible file entry struct.
const RarzFileEntry = extern struct {
	name: ?[*]const u8,
	name_len: u32,
	unpacked_size: u64,
	packed_size: u64,
	crc32: u32,
	mtime: u32,
	method: u8,
	is_directory: u8,
	is_encrypted: u8,
	host_os: u8,
};

export fn rarz_file_info(archive: ?*const ArchiveHandle, index: u32, out: ?*RarzFileEntry) i32 {
	const a = archive orelse return -1;
	const entry = out orelse return -1;

	if (a.rar5_files) |files| {
		if (index >= files.len) return -1;
		const f = files[index];
		entry.* = .{
			.name = f.name.ptr,
			.name_len = @intCast(f.name.len),
			.unpacked_size = f.unpacked_size,
			.packed_size = if (f.header.data_size) |ds| ds else 0,
			.crc32 = f.data_crc32 orelse 0,
			.mtime = f.mtime orelse 0,
			.method = f.compression.method,
			.is_directory = @intFromBool(f.is_directory),
			.is_encrypted = 0, // TODO: detect from crypt blocks
			.host_os = @intCast(f.host_os & 0xFF),
		};
		return 0;
	}

	if (a.rar4_files) |files| {
		if (index >= files.len) return -1;
		const f = files[index];
		const fflags = rar4_headers.parse_file_flags(f.block.flags);
		entry.* = .{
			.name = f.file_name.ptr,
			.name_len = @intCast(f.file_name.len),
			.unpacked_size = f.unpacked_size,
			.packed_size = f.packed_size,
			.crc32 = f.file_crc,
			.mtime = f.mtime,
			.method = f.method,
			.is_directory = @intFromBool((f.attributes & 0x10) != 0),
			.is_encrypted = @intFromBool(fflags.password),
			.host_os = f.host_os,
		};
		return 0;
	}

	return -1;
}

/// C-compatible validation result struct.
const RarzValidationResult = extern struct {
	is_valid: i32,
	depth: i32,
	family: i32,
	has_encrypted: i32,
	block_count: u32,
	file_count: u32,
	error_msg: ?[*:0]const u8,
};

export fn rarz_validate(data_ptr: ?[*]const u8, len: usize) RarzValidationResult {
	const invalid_result = RarzValidationResult{
		.is_valid = 0,
		.depth = 0,
		.family = 0,
		.has_encrypted = 0,
		.block_count = 0,
		.file_count = 0,
		.error_msg = "invalid data",
	};

	const slice = if (data_ptr) |d| d[0..len] else return invalid_result;
	if (len == 0) return invalid_result;

	// Delegate to the canonical validation implementation in policy.zig
	const result = policy.validate(slice);

	const family_code: i32 = if (result.family) |f| switch (f) {
		.rar14 => @as(i32, 14),
		.rar15 => @as(i32, 15),
		.rar50 => @as(i32, 50),
	} else 0;

	const depth_code: i32 = switch (result.depth) {
		.signature => 0,
		.structural => 1,
		.full => 2,
	};

	// All error messages from policy.validate are compile-time string literals,
	// which are null-terminated in memory, so the pointer cast is safe.
	const error_msg: ?[*:0]const u8 = if (result.error_message) |msg|
		@ptrCast(msg.ptr)
	else
		null;

	return RarzValidationResult{
		.is_valid = @intFromBool(result.is_valid),
		.depth = depth_code,
		.family = family_code,
		.has_encrypted = @intFromBool(result.has_encrypted_content),
		.block_count = result.block_count,
		.file_count = result.file_count,
		.error_msg = error_msg,
	};
}

export fn rarz_extract_to_buffer(
	archive: ?*const ArchiveHandle,
	index: u32,
	out_buf: ?[*]u8,
	out_len: usize,
) i64 {
	const a = archive orelse return -1;
	const buf = out_buf orelse return -1;

	if (a.rar5_files) |files| {
		if (index >= files.len) return -1;
		const f = files[index];

		// Only support store method (method == 0)
		if (f.compression.method != 0) return -1;

		const data_size = f.header.data_size orelse return -1;
		if (data_size > out_len) return -2;

		// header_start is relative to block_data; add block_data_offset for full archive offset
		const header_end = a.block_data_offset + f.header.header_start + 4 + f.header.crc_data_len;
		if (header_end + data_size > a.data.len) return -1;
		const file_data = a.data[header_end .. header_end + @as(usize, @intCast(data_size))];

		@memcpy(buf[0..file_data.len], file_data);
		return @intCast(file_data.len);
	}

	if (a.rar4_files) |files| {
		if (index >= files.len) return -1;
		const f = files[index];

		// Only support store method (method == 0)
		if (f.method != 0) return -1;

		if (f.packed_size > out_len) return -2;

		// header_offset is relative to block_data; add block_data_offset for full archive offset
		const data_start = a.block_data_offset + f.block.header_offset + f.block.head_size;
		const data_end = data_start + @as(usize, @intCast(f.packed_size));
		if (data_end > a.data.len) return -1;
		const file_data = a.data[data_start..data_end];

		@memcpy(buf[0..file_data.len], file_data);
		return @intCast(file_data.len);
	}

	return -1;
}

/// C-compatible file entry struct for archive creation (input).
const RarzCreateFileEntry = extern struct {
	name: ?[*]const u8,
	name_len: u32,
	data: ?[*]const u8,
	data_len: u64,
	mtime: u32,
	is_directory: u8,
};

export fn rarz_calculate_archive_size(entries_ptr: ?[*]const RarzCreateFileEntry, count: u32) i64 {
	const entries = if (entries_ptr) |p| p[0..count] else return -1;

	// Convert to writer.FileEntry array (stack for small counts, heap for large)
	var writer_entries_buf: [64]writer.FileEntry = undefined;
	const heap_alloc = std.heap.page_allocator;
	const writer_entries: []writer.FileEntry = if (count <= 64)
		writer_entries_buf[0..count]
	else
		heap_alloc.alloc(writer.FileEntry, count) catch return -1;
	defer if (count > 64) heap_alloc.free(writer_entries);

	for (entries, 0..) |e, i| {
		writer_entries[i] = .{
			.name = if (e.name) |n| n[0..e.name_len] else "",
			.data = if (e.data) |d| d[0..@as(usize, @intCast(e.data_len))] else "",
			.mtime = e.mtime,
			.is_directory = e.is_directory != 0,
		};
	}

	return @intCast(writer.calculate_archive_size(writer_entries));
}

export fn rarz_create_archive(
	entries_ptr: ?[*]const RarzCreateFileEntry,
	count: u32,
	out_buf: ?[*]u8,
	out_len: usize,
) i64 {
	const entries = if (entries_ptr) |p| p[0..count] else return -1;
	const buf = out_buf orelse return -1;

	// Convert to writer.FileEntry array (stack for small counts, heap for large)
	var writer_entries_buf: [64]writer.FileEntry = undefined;
	const heap_alloc = std.heap.page_allocator;
	const writer_entries: []writer.FileEntry = if (count <= 64)
		writer_entries_buf[0..count]
	else
		heap_alloc.alloc(writer.FileEntry, count) catch return -1;
	defer if (count > 64) heap_alloc.free(writer_entries);

	for (entries, 0..) |e, i| {
		writer_entries[i] = .{
			.name = if (e.name) |n| n[0..e.name_len] else "",
			.data = if (e.data) |d| d[0..@as(usize, @intCast(e.data_len))] else "",
			.mtime = e.mtime,
			.is_directory = e.is_directory != 0,
		};
	}

	const result = writer.write_archive(writer_entries, buf[0..out_len]) catch |err| {
		return switch (err) {
			error.BufferTooSmall => @as(i64, -2),
			error.NameTooLong, error.TooManyFiles => @as(i64, -1),
		};
	};

	return @intCast(result);
}

// ============================================================================
// Internal helpers
// ============================================================================

fn collectRar5Files(alloc: std.mem.Allocator, block_data: []const u8) ![]rar5_headers.FileBlock {
	var files: std.ArrayList(rar5_headers.FileBlock) = .empty;
	errdefer files.deinit(alloc);

	var iter = rar5_headers.walk_blocks(block_data);
	while (true) {
		const block = iter.next() catch break;
		if (block == null) break;
		switch (block.?) {
			.file => |fb| try files.append(alloc, fb),
			else => {},
		}
	}

	return files.toOwnedSlice(alloc);
}

fn collectRar4Files(alloc: std.mem.Allocator, block_data: []const u8) ![]rar4_headers.FileHeader {
	var files: std.ArrayList(rar4_headers.FileHeader) = .empty;
	errdefer files.deinit(alloc);

	var iter = rar4_headers.walk_blocks(block_data);
	while (true) {
		const block = iter.next() catch break;
		if (block == null) break;
		switch (block.?) {
			.file => |fh| try files.append(alloc, fh),
			else => {},
		}
	}

	return files.toOwnedSlice(alloc);
}

// ============================================================================
// Test helpers — build minimal RAR5 archives for testing
// ============================================================================

const testing = std.testing;
const encode_vint = reader.encode_vint;

/// Build a RAR5 block into `out`. Returns number of bytes written.
/// CRC32 is computed and placed at bytes 0..3.
fn build_rar5_block(
	out: []u8,
	block_type: u7,
	flags_raw: u64,
	extra_size: ?u64,
	data_size: ?u64,
	body: []const u8,
) usize {
	var tmp: [512]u8 = undefined;
	var pos: usize = 0;
	var contents: [512]u8 = undefined;
	var cpos: usize = 0;

	// header_type vint
	cpos += encode_vint(@intCast(block_type), contents[cpos..]);
	// header_flags vint
	cpos += encode_vint(flags_raw, contents[cpos..]);
	// optional extra_size
	if (extra_size) |es| {
		cpos += encode_vint(es, contents[cpos..]);
	}
	// optional data_size
	if (data_size) |ds| {
		cpos += encode_vint(ds, contents[cpos..]);
	}
	// body
	@memcpy(contents[cpos..][0..body.len], body);
	cpos += body.len;

	// header_size vint
	pos += encode_vint(cpos, tmp[pos..]);
	// contents
	@memcpy(tmp[pos..][0..cpos], contents[0..cpos]);
	pos += cpos;

	// CRC32 over header_size_vint + contents
	const crc = integrity.crc32(tmp[0..pos]);
	std.mem.writeInt(u32, out[0..4], crc, .little);
	@memcpy(out[4..][0..pos], tmp[0..pos]);

	return 4 + pos;
}

/// Build a minimal RAR5 archive: signature + main block + end block.
/// Returns the total archive length written into `buf`.
fn build_minimal_rar5(buf: []u8) usize {
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(buf[pos..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);
	pos += detect.RAR50_SIG.len;

	// Main block: type=1, flags=0, body = archive_flags vint(0)
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(buf[pos..], 1, 0, null, null, main_body[0..main_body_len]);

	// End block: type=5, flags=0, body = end_flags vint(0)
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(buf[pos..], 5, 0, null, null, end_body[0..end_body_len]);

	return pos;
}

/// Build a RAR5 archive with one stored file entry.
/// Returns the total archive length written into `buf`.
fn build_rar5_with_file(buf: []u8, filename: []const u8, file_data: []const u8) usize {
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(buf[pos..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);
	pos += detect.RAR50_SIG.len;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(buf[pos..], 1, 0, null, null, main_body[0..main_body_len]);

	// File block: type=2, flags with HFL_DATA (0x02) to indicate data_size present
	var file_body: [256]u8 = undefined;
	var fbpos: usize = 0;
	fbpos += encode_vint(0x0004, file_body[fbpos..]); // file_flags: has_crc32
	fbpos += encode_vint(file_data.len, file_body[fbpos..]); // unpacked_size
	fbpos += encode_vint(0x20, file_body[fbpos..]); // attributes
	// data_crc32
	const file_crc = integrity.crc32(file_data);
	std.mem.writeInt(u32, file_body[fbpos..][0..4], file_crc, .little);
	fbpos += 4;
	fbpos += encode_vint(0, file_body[fbpos..]); // compression_info: store (method=0)
	fbpos += encode_vint(0, file_body[fbpos..]); // host_os: Windows
	fbpos += encode_vint(filename.len, file_body[fbpos..]); // name_length
	@memcpy(file_body[fbpos..][0..filename.len], filename);
	fbpos += filename.len;

	// Build the file block header with HFL_DATA flag and data_size
	pos += build_rar5_block(buf[pos..], 2, 0x02, null, file_data.len, file_body[0..fbpos]);

	// Append file data payload immediately after header
	@memcpy(buf[pos..][0..file_data.len], file_data);
	pos += file_data.len;

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(buf[pos..], 5, 0, null, null, end_body[0..end_body_len]);

	return pos;
}

// ============================================================================
// Tests
// ============================================================================

test "abi version is 1" {
	const v = rarz_abi_version();
	try testing.expectEqual(@as(u32, 1), v);
}

test "rarz_detect_format identifies RAR5" {
	const sig = detect.RAR50_SIG ++ [_]u8{ 0x00, 0x00 };
	try testing.expectEqual(@as(i32, 50), rarz_detect_format(&sig, sig.len));
}

test "rarz_detect_format identifies RAR 1.5-4.x" {
	const sig = detect.RAR15_SIG ++ [_]u8{0x00};
	try testing.expectEqual(@as(i32, 15), rarz_detect_format(&sig, sig.len));
}

test "rarz_detect_format identifies RAR 1.4" {
	const sig = detect.RAR14_SIG ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 };
	try testing.expectEqual(@as(i32, 14), rarz_detect_format(&sig, sig.len));
}

test "rarz_detect_format returns 0 for unknown" {
	const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x02 };
	try testing.expectEqual(@as(i32, 0), rarz_detect_format(&garbage, garbage.len));
}

test "rarz_detect_format handles null pointer" {
	try testing.expectEqual(@as(i32, 0), rarz_detect_format(null, 0));
}

test "rarz_open and rarz_close round-trip" {
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	rarz_close(handle);
}

test "rarz_open returns null for garbage data" {
	const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
	try testing.expect(rarz_open(&garbage, garbage.len) == null);
}

test "rarz_open returns null for null pointer" {
	try testing.expect(rarz_open(null, 0) == null);
}

test "rarz_archive_format returns correct family" {
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	try testing.expectEqual(@as(i32, 50), rarz_archive_format(handle));
}

test "rarz_archive_format returns 0 for null handle" {
	try testing.expectEqual(@as(i32, 0), rarz_archive_format(null));
}

test "rarz_file_count returns 0 for empty archive" {
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	try testing.expectEqual(@as(u32, 0), rarz_file_count(handle));
}

test "rarz_file_count returns 0 for null handle" {
	try testing.expectEqual(@as(u32, 0), rarz_file_count(null));
}

test "rarz_file_count returns correct count with file" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	try testing.expectEqual(@as(u32, 1), rarz_file_count(handle));
}

test "rarz_file_info returns file metadata" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	var entry: RarzFileEntry = undefined;
	const result = rarz_file_info(handle, 0, &entry);
	try testing.expectEqual(@as(i32, 0), result);
	try testing.expectEqual(@as(u32, 8), entry.name_len);
	try testing.expectEqualSlices(u8, "test.txt", entry.name.?[0..entry.name_len]);
	try testing.expectEqual(@as(u64, file_data.len), entry.unpacked_size);
	try testing.expectEqual(@as(u8, 0), entry.method); // store
	try testing.expectEqual(@as(u8, 0), entry.is_directory);
}

test "rarz_file_info returns -1 for invalid index" {
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	var entry: RarzFileEntry = undefined;
	try testing.expectEqual(@as(i32, -1), rarz_file_info(handle, 0, &entry));
}

test "rarz_file_info returns -1 for null handle" {
	var entry: RarzFileEntry = undefined;
	try testing.expectEqual(@as(i32, -1), rarz_file_info(null, 0, &entry));
}

test "rarz_validate returns valid for well-formed RAR5 archive" {
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);

	const result = rarz_validate(&buf, archive_len);
	try testing.expectEqual(@as(i32, 1), result.is_valid);
	try testing.expectEqual(@as(i32, 50), result.family);
	try testing.expectEqual(@as(i32, 1), result.depth); // structural
	try testing.expectEqual(@as(u32, 2), result.block_count); // main + end
	try testing.expectEqual(@as(u32, 0), result.file_count);
	try testing.expect(result.error_msg == null);
}

test "rarz_validate returns invalid for garbage data" {
	const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };
	const result = rarz_validate(&garbage, garbage.len);
	try testing.expectEqual(@as(i32, 0), result.is_valid);
	try testing.expectEqual(@as(i32, 0), result.family);
	try testing.expect(result.error_msg != null);
}

test "rarz_validate returns invalid for null data" {
	const result = rarz_validate(null, 0);
	try testing.expectEqual(@as(i32, 0), result.is_valid);
	try testing.expect(result.error_msg != null);
}

test "rarz_validate returns valid for archive with file" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	const result = rarz_validate(&buf, archive_len);
	try testing.expectEqual(@as(i32, 1), result.is_valid);
	try testing.expectEqual(@as(i32, 50), result.family);
	try testing.expectEqual(@as(i32, 2), result.depth); // full (payload CRC verified)
	try testing.expectEqual(@as(u32, 1), result.file_count);
	try testing.expectEqual(@as(u32, 3), result.block_count); // main + file + end
}

test "rarz_extract_to_buffer extracts stored file" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	var out: [256]u8 = undefined;
	const bytes_written = rarz_extract_to_buffer(handle, 0, &out, out.len);
	try testing.expectEqual(@as(i64, @intCast(file_data.len)), bytes_written);
	try testing.expectEqualSlices(u8, file_data, out[0..@intCast(bytes_written)]);
}

test "rarz_extract_to_buffer returns -1 for invalid index" {
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	var out: [256]u8 = undefined;
	try testing.expectEqual(@as(i64, -1), rarz_extract_to_buffer(handle, 0, &out, out.len));
}

test "rarz_extract_to_buffer returns -2 if buffer too small" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	var tiny_out: [2]u8 = undefined;
	try testing.expectEqual(@as(i64, -2), rarz_extract_to_buffer(handle, 0, &tiny_out, tiny_out.len));
}

test "rarz_extract_to_buffer returns -1 for null handle" {
	var out: [256]u8 = undefined;
	try testing.expectEqual(@as(i64, -1), rarz_extract_to_buffer(null, 0, &out, out.len));
}

test "rarz_create_archive and rarz_open round-trip" {
	// Create an archive via the C FFI
	const name = "round.txt";
	const data = "round trip test data";
	const c_entries = [_]RarzCreateFileEntry{.{
		.name = name.ptr,
		.name_len = name.len,
		.data = data.ptr,
		.data_len = data.len,
		.mtime = 0x5C000000,
		.is_directory = 0,
	}};

	// Calculate size
	const needed = rarz_calculate_archive_size(&c_entries, 1);
	try testing.expect(needed > 0);

	// Create archive
	var archive_buf: [4096]u8 = undefined;
	const written = rarz_create_archive(&c_entries, 1, &archive_buf, archive_buf.len);
	try testing.expect(written > 0);
	try testing.expectEqual(needed, written);

	// Open the archive we just created
	const handle = rarz_open(&archive_buf, @intCast(written));
	try testing.expect(handle != null);
	defer rarz_close(handle);

	// Verify file count
	try testing.expectEqual(@as(u32, 1), rarz_file_count(handle));

	// Verify file info
	var entry: RarzFileEntry = undefined;
	const info_result = rarz_file_info(handle, 0, &entry);
	try testing.expectEqual(@as(i32, 0), info_result);
	try testing.expectEqual(@as(u32, name.len), entry.name_len);
	try testing.expectEqualSlices(u8, name, entry.name.?[0..entry.name_len]);
	try testing.expectEqual(@as(u64, data.len), entry.unpacked_size);
	try testing.expectEqual(@as(u8, 0), entry.method); // store

	// Extract and verify content
	var extract_buf: [256]u8 = undefined;
	const extracted = rarz_extract_to_buffer(handle, 0, &extract_buf, extract_buf.len);
	try testing.expectEqual(@as(i64, @intCast(data.len)), extracted);
	try testing.expectEqualSlices(u8, data, extract_buf[0..@intCast(extracted)]);
}

test "rarz_create_archive returns -2 for small buffer" {
	const name = "test.txt";
	const data = "hello";
	const c_entries = [_]RarzCreateFileEntry{.{
		.name = name.ptr,
		.name_len = name.len,
		.data = data.ptr,
		.data_len = data.len,
		.mtime = 0,
		.is_directory = 0,
	}};

	var tiny: [8]u8 = undefined;
	const result = rarz_create_archive(&c_entries, 1, &tiny, tiny.len);
	try testing.expectEqual(@as(i64, -2), result);
}

test "rarz_create_archive null entries returns -1" {
	var buf: [256]u8 = undefined;
	const result = rarz_create_archive(null, 0, &buf, buf.len);
	try testing.expectEqual(@as(i64, -1), result);
}

test "rarz_create_archive supports more than 64 files" {
	// Create 65 tiny file entries to exceed the old 64-file stack limit
	const file_count = 65;
	var c_entries: [file_count]RarzCreateFileEntry = undefined;
	var names: [file_count][8]u8 = undefined;

	for (0..file_count) |i| {
		// Generate unique filenames like "f000.txt", "f001.txt", ...
		const name_buf = &names[i];
		_ = std.fmt.bufPrint(name_buf, "f{d:0>3}.txt", .{i}) catch unreachable;
		c_entries[i] = .{
			.name = name_buf,
			.name_len = 8,
			.data = "x", // 1-byte file content
			.data_len = 1,
			.mtime = 0,
			.is_directory = 0,
		};
	}

	// Calculate archive size — must not return -1
	const needed = rarz_calculate_archive_size(&c_entries, file_count);
	try testing.expect(needed > 0);

	// Create archive into a heap-allocated buffer (too large for stack)
	const alloc = std.heap.page_allocator;
	const archive_buf = try alloc.alloc(u8, @intCast(needed));
	defer alloc.free(archive_buf);

	const written = rarz_create_archive(&c_entries, file_count, archive_buf.ptr, archive_buf.len);
	try testing.expect(written > 0);
	try testing.expectEqual(needed, written);

	// Open the archive and verify file count
	const handle = rarz_open(archive_buf.ptr, @intCast(written));
	try testing.expect(handle != null);
	defer rarz_close(handle);

	try testing.expectEqual(@as(u32, file_count), rarz_file_count(handle));
}

test "rarz_detect_format_sfx detects RAR5 after garbage prefix" {
	// Build a synthetic SFX archive: 128 bytes of garbage + RAR5 signature + padding
	var sfx_buf: [256]u8 = undefined;
	const garbage_prefix_len = 128;

	// Fill prefix with junk
	@memset(sfx_buf[0..garbage_prefix_len], 0xCC);

	// Place RAR5 signature right after the garbage prefix
	@memcpy(sfx_buf[garbage_prefix_len..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);

	// Fill rest with zeros
	@memset(sfx_buf[garbage_prefix_len + detect.RAR50_SIG.len ..], 0x00);

	const total_len = sfx_buf.len;

	// rarz_detect_format (max_sfx_offset=0) should NOT find it
	try testing.expectEqual(@as(i32, 0), rarz_detect_format(&sfx_buf, total_len));

	// rarz_detect_format_sfx with sufficient offset should find the RAR5 signature
	try testing.expectEqual(@as(i32, 50), rarz_detect_format_sfx(&sfx_buf, total_len, 256));
}

test "rarz_detect_format_sfx returns 0 when offset too small" {
	var sfx_buf: [256]u8 = undefined;
	const garbage_prefix_len = 128;

	@memset(sfx_buf[0..garbage_prefix_len], 0xCC);
	@memcpy(sfx_buf[garbage_prefix_len..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);
	@memset(sfx_buf[garbage_prefix_len + detect.RAR50_SIG.len ..], 0x00);

	// max_sfx_offset too small to reach the signature at offset 128
	try testing.expectEqual(@as(i32, 0), rarz_detect_format_sfx(&sfx_buf, sfx_buf.len, 64));
}

test "rarz_detect_format_sfx handles null pointer" {
	try testing.expectEqual(@as(i32, 0), rarz_detect_format_sfx(null, 0, 256));
}

test "rarz_detect_format_sfx with zero offset behaves like rarz_detect_format" {
	// Direct RAR5 signature at offset 0
	const sig = detect.RAR50_SIG ++ [_]u8{ 0x00, 0x00 };
	try testing.expectEqual(@as(i32, 50), rarz_detect_format_sfx(&sig, sig.len, 0));

	// Garbage data
	const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x02 };
	try testing.expectEqual(@as(i32, 0), rarz_detect_format_sfx(&garbage, garbage.len, 0));
}


test "rarz_open and rarz_close 100 times (arena allocator stress)" {
	var buf: [1024]u8 = undefined;
	const file_data = "stress test";
	const archive_len = build_rar5_with_file(&buf, "stress.txt", file_data);

	for (0..100) |_| {
		const handle = rarz_open(&buf, archive_len);
		try testing.expect(handle != null);
		try testing.expectEqual(@as(u32, 1), rarz_file_count(handle));
		rarz_close(handle);
	}
}

comptime {
	_ = detect;
	_ = integrity;
	_ = rar4_headers;
	_ = rar5_headers;
	_ = reader;
	_ = policy;
	_ = writer;
	_ = @import("decompress/bitreader.zig");
	_ = @import("decompress/huffman.zig");
	_ = @import("decompress/lz.zig");
}
