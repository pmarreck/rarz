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
pub const dispatch = @import("decompress/dispatch.zig");

// ============================================================================
// Multi-volume types
// ============================================================================

const VolumeData = struct {
	data: []const u8,
	block_data_offset: usize,
};

const PackedChunk = struct {
	volume_index: u32,
	offset: usize, // absolute offset within the volume's data buffer
	length: usize,
};

const UnifiedFile = struct {
	name: []const u8,
	unpacked_size: u64,
	compression: rar5_headers.CompressionInfo,
	data_crc32: ?u32,
	mtime: ?u32,
	is_directory: bool,
	host_os: u64,
	has_crc32: bool,
	is_encrypted: bool,
	total_packed_size: u64,
	packed_chunks: []PackedChunk,
};

// ============================================================================
// Archive Handle (opaque to C callers)
// ============================================================================

const ArchiveHandle = struct {
	data: []const u8,
	family: detect.RarFamily,
	block_data_offset: usize, // offset from data start to first block (after signature)
	rar4_files: ?[]rar4_headers.FileHeader,
	rar5_files: ?[]rar5_headers.FileBlock,
	// Multi-volume fields
	volumes: ?[]VolumeData,
	unified_files: ?[]UnifiedFile,
	arena: std.heap.ArenaAllocator,

	fn deinit(self: *ArchiveHandle) void {
		self.arena.deinit();
		std.heap.page_allocator.destroy(self);
	}

	fn fileCount(self: *const ArchiveHandle) u32 {
		if (self.unified_files) |files| return @intCast(files.len);
		if (self.rar4_files) |files| return @intCast(files.len);
		if (self.rar5_files) |files| return @intCast(files.len);
		return 0;
	}
};

// ============================================================================
// Thread-local last-error for FFI diagnostics
// ============================================================================

threadlocal var last_error_msg: ?[*:0]const u8 = null;

fn setLastError(msg: [*:0]const u8) void {
	last_error_msg = msg;
}

fn clearLastError() void {
	last_error_msg = null;
}

export fn rarz_last_error() ?[*:0]const u8 {
	return last_error_msg;
}

export fn rarz_clear_error() void {
	clearLastError();
}

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
	const slice = if (data_ptr) |d| d[0..len] else {
		setLastError("null or empty data");
		return null;
	};
	if (len == 0) {
		setLastError("null or empty data");
		return null;
	}

	const format = detect.detect_format(slice, 0);
	const family = format.family orelse {
		setLastError("unrecognized archive format");
		return null;
	};

	const block_offset = format.signature_offset + format.signature_len;

	// Allocate handle from page_allocator (arena lives inside it)
	const handle = std.heap.page_allocator.create(ArchiveHandle) catch {
		setLastError("out of memory");
		return null;
	};
	handle.* = .{
		.data = slice,
		.family = family,
		.block_data_offset = block_offset,
		.rar4_files = null,
		.rar5_files = null,
		.volumes = null,
		.unified_files = null,
		.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
	};

	const alloc = handle.arena.allocator();

	// Parse file entries based on format family
	switch (family) {
		.rar50 => {
			const block_data = slice[block_offset..];
			handle.rar5_files = collectRar5Files(alloc, block_data) catch {
				handle.deinit();
				setLastError("failed to parse RAR5 headers");
				return null;
			};
		},
		.rar15 => {
			const block_data = slice[block_offset..];
			handle.rar4_files = collectRar4Files(alloc, block_data) catch {
				handle.deinit();
				setLastError("failed to parse RAR4 headers");
				return null;
			};
		},
		.rar14 => {
			// RAR 1.4 is too ancient — leave files empty
		},
	}

	clearLastError();
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
	split_before: u8,
	split_after: u8,
};

export fn rarz_file_info(archive: ?*const ArchiveHandle, index: u32, out: ?*RarzFileEntry) i32 {
	const a = archive orelse {
		setLastError("null archive handle");
		return -1;
	};
	const entry = out orelse {
		setLastError("null output pointer");
		return -1;
	};

	// Multi-volume unified files take priority
	if (a.unified_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return -1;
		}
		const uf = files[index];
		entry.* = .{
			.name = uf.name.ptr,
			.name_len = @intCast(uf.name.len),
			.unpacked_size = uf.unpacked_size,
			.packed_size = uf.total_packed_size,
			.crc32 = uf.data_crc32 orelse 0,
			.mtime = uf.mtime orelse 0,
			.method = uf.compression.method,
			.is_directory = @intFromBool(uf.is_directory),
			.is_encrypted = @intFromBool(uf.is_encrypted),
			.host_os = @intCast(uf.host_os & 0xFF),
			.split_before = 0,
			.split_after = 0,
		};
		clearLastError();
		return 0;
	}

	if (a.rar5_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return -1;
		}
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
			.is_encrypted = @intFromBool(rar5_headers.extra_has_encryption(f.extra_data)),
			.host_os = @intCast(f.host_os & 0xFF),
			.split_before = @intFromBool(f.header.flags.split_before),
			.split_after = @intFromBool(f.header.flags.split_after),
		};
		clearLastError();
		return 0;
	}

	if (a.rar4_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return -1;
		}
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
			.split_before = @intFromBool(fflags.split_before),
			.split_after = @intFromBool(fflags.split_after),
		};
		clearLastError();
		return 0;
	}

	setLastError("file index out of range");
	return -1;
}

/// C-compatible validation result struct.
const RarzValidationResult = extern struct {
	is_valid: i32,
	family: i32,
	has_encrypted: i32,
	block_count: u32,
	file_count: u32,
	error_msg: ?[*:0]const u8,
};

export fn rarz_validate(data_ptr: ?[*]const u8, len: usize) RarzValidationResult {
	const invalid_result = RarzValidationResult{
		.is_valid = 0,
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

	// All error messages from policy.validate are compile-time string literals,
	// which are null-terminated in memory, so the pointer cast is safe.
	const error_msg: ?[*:0]const u8 = if (result.error_message) |msg|
		@ptrCast(msg.ptr)
	else
		null;

	return RarzValidationResult{
		.is_valid = @intFromBool(result.is_valid),
		.family = family_code,
		.has_encrypted = @intFromBool(result.has_encrypted_content),
		.block_count = result.block_count,
		.file_count = result.file_count,
		.error_msg = error_msg,
	};
}

export fn rarz_validate_volumes(
	volumes_ptr: ?[*]const [*]const u8,
	lengths_ptr: ?[*]const usize,
	volume_count: u32,
) RarzValidationResult {
	const invalid_result = RarzValidationResult{
		.is_valid = 0,
		.family = 0,
		.has_encrypted = 0,
		.block_count = 0,
		.file_count = 0,
		.error_msg = "invalid data",
	};

	if (volume_count == 0) return invalid_result;
	const vols = if (volumes_ptr) |v| v[0..volume_count] else return invalid_result;
	const lens = if (lengths_ptr) |l| l[0..volume_count] else return invalid_result;

	// Build slice of slices
	const alloc = std.heap.page_allocator;
	const vol_slices = alloc.alloc([]const u8, volume_count) catch {
		setLastError("out of memory");
		return invalid_result;
	};
	defer alloc.free(vol_slices);

	for (0..volume_count) |i| {
		vol_slices[i] = vols[i][0..lens[i]];
	}

	const result = policy.validate_volumes(vol_slices);

	const family_code: i32 = if (result.family) |f| switch (f) {
		.rar14 => @as(i32, 14),
		.rar15 => @as(i32, 15),
		.rar50 => @as(i32, 50),
	} else 0;

	const error_msg: ?[*:0]const u8 = if (result.error_message) |msg|
		@ptrCast(msg.ptr)
	else
		null;

	clearLastError();
	return RarzValidationResult{
		.is_valid = @intFromBool(result.is_valid),
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
	const a = archive orelse {
		setLastError("null archive handle");
		return -1;
	};
	const buf = out_buf orelse {
		setLastError("null output buffer");
		return -1;
	};

	// Multi-volume unified extraction path
	if (a.unified_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return -1;
		}
		const uf = files[index];
		const volumes = a.volumes orelse {
			setLastError("corrupt archive handle");
			return -1;
		};

		if (uf.is_directory) {
			clearLastError();
			return 0; // directories have no data
		}

		if (uf.packed_chunks.len == 0) {
			setLastError("file has no packed data");
			return -1;
		}

		if (uf.packed_chunks.len == 1) {
			const chunk = uf.packed_chunks[0];
			const vol = volumes[chunk.volume_index];
			const packed_data = vol.data[chunk.offset..][0..chunk.length];

			if (uf.compression.method == 0) {
				if (packed_data.len > out_len) {
					setLastError("output buffer too small");
					return -2;
				}
				@memcpy(buf[0..packed_data.len], packed_data);
				clearLastError();
				return @intCast(packed_data.len);
			}

			if (uf.unpacked_size > out_len) {
				setLastError("output buffer too small");
				return -2;
			}
			const decompressed = dispatch.decompressRar5(
				std.heap.page_allocator,
				packed_data,
				uf.unpacked_size,
				uf.compression,
			) catch {
				setLastError("decompression failed");
				return -3;
			};
			defer std.heap.page_allocator.free(decompressed);
			@memcpy(buf[0..decompressed.len], decompressed);
			clearLastError();
			return @intCast(decompressed.len);
		}

		// Multiple chunks — concatenate all packed data, then decompress
		var total_packed: usize = 0;
		for (uf.packed_chunks) |chunk| {
			total_packed += chunk.length;
		}

		const combined = std.heap.page_allocator.alloc(u8, total_packed) catch {
			setLastError("out of memory");
			return -1;
		};
		defer std.heap.page_allocator.free(combined);

		var write_pos: usize = 0;
		for (uf.packed_chunks) |chunk| {
			const vol = volumes[chunk.volume_index];
			const src = vol.data[chunk.offset..][0..chunk.length];
			@memcpy(combined[write_pos..][0..chunk.length], src);
			write_pos += chunk.length;
		}

		if (uf.compression.method == 0) {
			if (combined.len > out_len) {
				setLastError("output buffer too small");
				return -2;
			}
			@memcpy(buf[0..combined.len], combined);
			clearLastError();
			return @intCast(combined.len);
		}

		if (uf.unpacked_size > out_len) {
			setLastError("output buffer too small");
			return -2;
		}
		const decompressed = dispatch.decompressRar5(
			std.heap.page_allocator,
			combined,
			uf.unpacked_size,
			uf.compression,
		) catch {
			setLastError("decompression failed");
			return -3;
		};
		defer std.heap.page_allocator.free(decompressed);
		@memcpy(buf[0..decompressed.len], decompressed);
		clearLastError();
		return @intCast(decompressed.len);
	}

	if (a.rar5_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return -1;
		}
		const f = files[index];

		const data_size = f.header.data_size orelse {
			setLastError("file has no data size");
			return -1;
		};

		// header_start is relative to block_data; add block_data_offset for full archive offset
		const header_end = a.block_data_offset + f.header.header_start + 4 + f.header.crc_data_len;
		if (header_end + data_size > a.data.len) {
			setLastError("data extends beyond archive");
			return -1;
		}
		const packed_data = a.data[header_end .. header_end + @as(usize, @intCast(data_size))];

		if (f.compression.method == 0) {
			if (data_size > out_len) {
				setLastError("output buffer too small");
				return -2;
			}
			@memcpy(buf[0..packed_data.len], packed_data);
			clearLastError();
			return @intCast(packed_data.len);
		}

		// Compressed: decompress via dispatch
		if (f.unpacked_size > out_len) {
			setLastError("output buffer too small");
			return -2;
		}
		const decompressed = dispatch.decompressRar5(
			std.heap.page_allocator,
			packed_data,
			f.unpacked_size,
			f.compression,
		) catch {
			setLastError("decompression failed");
			return -3;
		};
		defer std.heap.page_allocator.free(decompressed);
		@memcpy(buf[0..decompressed.len], decompressed);
		clearLastError();
		return @intCast(decompressed.len);
	}

	if (a.rar4_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return -1;
		}
		const f = files[index];

		// header_offset is relative to block_data; add block_data_offset for full archive offset
		const data_start = a.block_data_offset + f.block.header_offset + f.block.head_size;
		const data_end = data_start + @as(usize, @intCast(f.packed_size));
		if (data_end > a.data.len) {
			setLastError("data extends beyond archive");
			return -1;
		}
		const packed_data = a.data[data_start..data_end];

		if (f.method == 0) {
			if (f.packed_size > out_len) {
				setLastError("output buffer too small");
				return -2;
			}
			@memcpy(buf[0..packed_data.len], packed_data);
			clearLastError();
			return @intCast(packed_data.len);
		}

		// Compressed: decompress via dispatch
		if (f.unpacked_size > out_len) {
			setLastError("output buffer too small");
			return -2;
		}
		const decompressed = dispatch.decompressRar4(
			std.heap.page_allocator,
			packed_data,
			f.unpacked_size,
			f.unpack_version,
			f.method,
			f.block.flags,
		) catch {
			setLastError("decompression failed");
			return -3;
		};
		defer std.heap.page_allocator.free(decompressed);
		@memcpy(buf[0..decompressed.len], decompressed);
		clearLastError();
		return @intCast(decompressed.len);
	}

	setLastError("file index out of range");
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
	host_os: u8,
	_pad: [2]u8 = .{ 0, 0 },
	attributes: u32,
};

export fn rarz_calculate_archive_size(entries_ptr: ?[*]const RarzCreateFileEntry, count: u32) i64 {
	const entries = if (entries_ptr) |p| p[0..count] else {
		setLastError("null entries pointer");
		return -1;
	};

	// Convert to writer.FileEntry array (stack for small counts, heap for large)
	var writer_entries_buf: [64]writer.FileEntry = undefined;
	const heap_alloc = std.heap.page_allocator;
	const writer_entries: []writer.FileEntry = if (count <= 64)
		writer_entries_buf[0..count]
	else
		heap_alloc.alloc(writer.FileEntry, count) catch {
			setLastError("out of memory");
			return -1;
		};
	defer if (count > 64) heap_alloc.free(writer_entries);

	for (entries, 0..) |e, i| {
		writer_entries[i] = .{
			.name = if (e.name) |n| n[0..e.name_len] else "",
			.data = if (e.data) |d| d[0..@as(usize, @intCast(e.data_len))] else "",
			.mtime = e.mtime,
			.is_directory = e.is_directory != 0,
			.host_os = e.host_os,
			.attributes = e.attributes,
		};
	}

	clearLastError();
	return @intCast(writer.calculate_archive_size(writer_entries));
}

export fn rarz_create_archive(
	entries_ptr: ?[*]const RarzCreateFileEntry,
	count: u32,
	out_buf: ?[*]u8,
	out_len: usize,
) i64 {
	const entries = if (entries_ptr) |p| p[0..count] else {
		setLastError("null entries pointer");
		return -1;
	};
	const buf = out_buf orelse {
		setLastError("null output buffer");
		return -1;
	};

	// Convert to writer.FileEntry array (stack for small counts, heap for large)
	var writer_entries_buf: [64]writer.FileEntry = undefined;
	const heap_alloc = std.heap.page_allocator;
	const writer_entries: []writer.FileEntry = if (count <= 64)
		writer_entries_buf[0..count]
	else
		heap_alloc.alloc(writer.FileEntry, count) catch {
			setLastError("out of memory");
			return -1;
		};
	defer if (count > 64) heap_alloc.free(writer_entries);

	for (entries, 0..) |e, i| {
		writer_entries[i] = .{
			.name = if (e.name) |n| n[0..e.name_len] else "",
			.data = if (e.data) |d| d[0..@as(usize, @intCast(e.data_len))] else "",
			.mtime = e.mtime,
			.is_directory = e.is_directory != 0,
			.host_os = e.host_os,
			.attributes = e.attributes,
		};
	}

	const result = writer.write_archive(writer_entries, buf[0..out_len]) catch |err| {
		return switch (err) {
			error.BufferTooSmall => {
				setLastError("output buffer too small");
				return @as(i64, -2);
			},
			error.NameTooLong => {
				setLastError("filename exceeds maximum length");
				return @as(i64, -1);
			},
			error.TooManyFiles => {
				setLastError("too many files for archive");
				return @as(i64, -1);
			},
		};
	};

	clearLastError();
	return @intCast(result);
}

export fn rarz_create_archive_compressed(
	entries_ptr: ?[*]const RarzCreateFileEntry,
	count: u32,
	out_buf: ?[*]u8,
	out_len: usize,
	method: u8,
) i64 {
	const entries = if (entries_ptr) |p| p[0..count] else {
		setLastError("null entries pointer");
		return -1;
	};
	const buf = out_buf orelse {
		setLastError("null output buffer");
		return -1;
	};
	if (method > 5) {
		setLastError("invalid compression method");
		return -1;
	}
	const compression_method: u3 = @intCast(method);

	var writer_entries_buf: [64]writer.FileEntry = undefined;
	const heap_alloc = std.heap.page_allocator;
	const writer_entries: []writer.FileEntry = if (count <= 64)
		writer_entries_buf[0..count]
	else
		heap_alloc.alloc(writer.FileEntry, count) catch {
			setLastError("out of memory");
			return -1;
		};
	defer if (count > 64) heap_alloc.free(writer_entries);

	for (entries, 0..) |e, i| {
		writer_entries[i] = .{
			.name = if (e.name) |n| n[0..e.name_len] else "",
			.data = if (e.data) |d| d[0..@as(usize, @intCast(e.data_len))] else "",
			.mtime = e.mtime,
			.is_directory = e.is_directory != 0,
			.host_os = e.host_os,
			.attributes = e.attributes,
		};
	}

	const result = writer.write_archive_compressed(heap_alloc, writer_entries, buf[0..out_len], compression_method) catch |err| {
		return switch (err) {
			error.BufferTooSmall => {
				setLastError("output buffer too small");
				return @as(i64, -2);
			},
			error.NameTooLong => {
				setLastError("filename exceeds maximum length");
				return @as(i64, -1);
			},
			error.TooManyFiles => {
				setLastError("too many files for archive");
				return @as(i64, -1);
			},
			else => {
				setLastError("compression failed");
				return @as(i64, -3);
			},
		};
	};

	clearLastError();
	return @intCast(result);
}

// ============================================================================
// Volume creation FFI
// ============================================================================

/// Opaque handle for volume creation result.
const VolumeHandle = struct {
	result: writer.VolumeResult,
};

export fn rarz_create_volumes(
	entries_ptr: ?[*]const RarzCreateFileEntry,
	count: u32,
	volume_size: u64,
	method: u8,
) ?*VolumeHandle {
	const entries = if (entries_ptr) |p| p[0..count] else {
		setLastError("null entries pointer");
		return null;
	};
	if (method > 5) {
		setLastError("invalid compression method");
		return null;
	}
	if (volume_size < 1024) {
		setLastError("volume size must be at least 1024 bytes");
		return null;
	}

	const heap_alloc = std.heap.page_allocator;

	// Convert to writer.FileEntry array
	const writer_entries = heap_alloc.alloc(writer.FileEntry, count) catch {
		setLastError("out of memory");
		return null;
	};
	defer heap_alloc.free(writer_entries);

	for (entries, 0..) |e, i| {
		writer_entries[i] = .{
			.name = if (e.name) |n| n[0..e.name_len] else "",
			.data = if (e.data) |d| d[0..@as(usize, @intCast(e.data_len))] else "",
			.mtime = e.mtime,
			.is_directory = e.is_directory != 0,
			.host_os = e.host_os,
			.attributes = e.attributes,
		};
	}

	const config = writer.VolumeConfig{ .volume_size = volume_size };
	const compression_method: u3 = @intCast(method);

	const vol_result = if (method == 0)
		writer.write_archive_volumes(heap_alloc, writer_entries, config) catch {
			setLastError("volume creation failed");
			return null;
		}
	else
		writer.write_archive_volumes_compressed(heap_alloc, writer_entries, config, compression_method) catch {
			setLastError("volume creation failed");
			return null;
		};

	const handle = heap_alloc.create(VolumeHandle) catch {
		var mutable_result = vol_result;
		mutable_result.deinit();
		setLastError("out of memory");
		return null;
	};
	handle.* = .{ .result = vol_result };

	clearLastError();
	return handle;
}

export fn rarz_volume_count(handle: ?*const VolumeHandle) u32 {
	const h = handle orelse return 0;
	return @intCast(h.result.count);
}

export fn rarz_volume_data(
	handle: ?*const VolumeHandle,
	index: u32,
	out_buf: ?*[*]const u8,
	out_len: ?*usize,
) i32 {
	const h = handle orelse {
		setLastError("null volume handle");
		return -1;
	};
	if (index >= h.result.count) {
		setLastError("volume index out of range");
		return -1;
	}

	const vol = h.result.volumes[index];
	if (out_buf) |ob| ob.* = vol.ptr;
	if (out_len) |ol| ol.* = vol.len;

	clearLastError();
	return 0;
}

export fn rarz_volumes_free(handle: ?*VolumeHandle) void {
	const h = handle orelse return;
	h.result.deinit();
	std.heap.page_allocator.destroy(h);
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

/// Collect files from multiple RAR5 volumes into a unified file list.
/// Split files (same name across volumes with split_before/split_after) are merged
/// into a single UnifiedFile with multiple packed chunks.
fn collectRar5FilesUnified(alloc: std.mem.Allocator, volumes: []const VolumeData) ![]UnifiedFile {
	// First pass: collect all file blocks from all volumes with their volume index
	const FileWithVolume = struct {
		fb: rar5_headers.FileBlock,
		volume_index: u32,
		packed_data_offset: usize, // absolute offset of packed data in volume
	};

	var all_file_blocks: std.ArrayList(FileWithVolume) = .empty;
	defer all_file_blocks.deinit(alloc);

	for (volumes, 0..) |vol, vi| {
		const block_data = vol.data[vol.block_data_offset..];
		var iter = rar5_headers.walk_blocks(block_data);
		while (true) {
			const block = iter.next() catch break;
			if (block == null) break;
			switch (block.?) {
				.file => |fb| {
					// Compute the absolute offset of packed data in this volume
					const header_end = vol.block_data_offset + fb.header.header_start + 4 + fb.header.crc_data_len;
					try all_file_blocks.append(alloc, .{
						.fb = fb,
						.volume_index = @intCast(vi),
						.packed_data_offset = header_end,
					});
				},
				else => {},
			}
		}
	}

	// Second pass: merge file blocks by name
	// Files appear in volume order. A file with split_after in volume N
	// continues with split_before in volume N+1.
	var unified: std.ArrayList(UnifiedFile) = .empty;
	errdefer unified.deinit(alloc);

	var i: usize = 0;
	while (i < all_file_blocks.items.len) {
		const first = all_file_blocks.items[i];

		// If this block has split_before, it's a continuation — skip it
		// (it should have been consumed by the previous file's merge loop)
		if (first.fb.header.flags.split_before) {
			i += 1;
			continue;
		}

		// Collect packed chunks for this file
		var chunks: std.ArrayList(PackedChunk) = .empty;
		errdefer chunks.deinit(alloc);

		const data_size = first.fb.header.data_size orelse 0;
		try chunks.append(alloc, .{
			.volume_index = first.volume_index,
			.offset = first.packed_data_offset,
			.length = @intCast(data_size),
		});

		var total_packed: u64 = data_size;

		// If this file continues to next volume(s), find continuations
		if (first.fb.header.flags.split_after) {
			var j: usize = i + 1;
			while (j < all_file_blocks.items.len) {
				const cont = all_file_blocks.items[j];
				if (!cont.fb.header.flags.split_before) break;

				// Verify name matches
				if (!std.mem.eql(u8, first.fb.name, cont.fb.name)) break;

				const cont_data_size = cont.fb.header.data_size orelse 0;
				try chunks.append(alloc, .{
					.volume_index = cont.volume_index,
					.offset = cont.packed_data_offset,
					.length = @intCast(cont_data_size),
				});
				total_packed += cont_data_size;

				j += 1;
				if (!cont.fb.header.flags.split_after) break;
			}
		}

		try unified.append(alloc, .{
			.name = first.fb.name,
			.unpacked_size = first.fb.unpacked_size,
			.compression = first.fb.compression,
			.data_crc32 = first.fb.data_crc32,
			.mtime = first.fb.mtime,
			.is_directory = first.fb.is_directory,
			.host_os = first.fb.host_os,
			.has_crc32 = first.fb.has_crc32,
			.is_encrypted = rar5_headers.extra_has_encryption(first.fb.extra_data),
			.total_packed_size = total_packed,
			.packed_chunks = try chunks.toOwnedSlice(alloc),
		});

		i += 1;
	}

	return unified.toOwnedSlice(alloc);
}

// ============================================================================
// Multi-volume FFI export
// ============================================================================

export fn rarz_open_volumes(
	volumes_ptr: ?[*]const [*]const u8,
	lengths_ptr: ?[*]const usize,
	volume_count: u32,
) ?*ArchiveHandle {
	const vols = if (volumes_ptr) |v| v[0..volume_count] else {
		setLastError("null or empty volume data");
		return null;
	};
	const lens = if (lengths_ptr) |l| l[0..volume_count] else {
		setLastError("null or empty volume data");
		return null;
	};
	if (volume_count == 0) {
		setLastError("null or empty volume data");
		return null;
	}

	const handle = std.heap.page_allocator.create(ArchiveHandle) catch {
		setLastError("out of memory");
		return null;
	};
	handle.* = .{
		.data = vols[0][0..lens[0]],
		.family = .rar50,
		.block_data_offset = 0,
		.rar4_files = null,
		.rar5_files = null,
		.volumes = null,
		.unified_files = null,
		.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
	};

	const alloc = handle.arena.allocator();

	// Detect format from first volume
	const first_slice = vols[0][0..lens[0]];
	const format = detect.detect_format(first_slice, 0);
	const family = format.family orelse {
		handle.deinit();
		setLastError("unrecognized format in first volume");
		return null;
	};
	handle.family = family;

	if (family != .rar50) {
		handle.deinit();
		setLastError("multi-volume only supported for RAR5");
		return null;
	}

	// Build VolumeData array
	const vol_data = alloc.alloc(VolumeData, volume_count) catch {
		handle.deinit();
		setLastError("out of memory");
		return null;
	};

	for (0..volume_count) |vi| {
		const slice = vols[vi][0..lens[vi]];
		const vol_format = detect.detect_format(slice, 0);
		const vol_offset = (vol_format.signature_offset) + (vol_format.signature_len);
		vol_data[vi] = .{
			.data = slice,
			.block_data_offset = vol_offset,
		};
	}

	handle.volumes = vol_data;

	// Build unified file list
	handle.unified_files = collectRar5FilesUnified(alloc, vol_data) catch {
		handle.deinit();
		setLastError("failed to collect multi-volume files");
		return null;
	};

	clearLastError();
	return handle;
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
		.host_os = 0,
		.attributes = 0,
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
		.host_os = 0,
		.attributes = 0,
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
			.host_os = 0,
			.attributes = 0,
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

// ============================================================================
// Multi-volume tests
// ============================================================================

/// Build a RAR5 volume: signature + main block (with volume flag) + optional file block + end block.
/// If split_before/split_after flags are set on the file, the header flags reflect that.
fn build_rar5_volume(
	buf: []u8,
	volume_number: ?u64,
	file_name: ?[]const u8,
	file_data: ?[]const u8,
	split_before: bool,
	split_after: bool,
	has_next_volume: bool,
	unpacked_size_override: ?u64,
) usize {
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(buf[pos..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);
	pos += detect.RAR50_SIG.len;

	// Main block: type=1, flags=0, body = archive_flags vint
	var main_body: [32]u8 = undefined;
	var mbpos: usize = 0;
	// archive_flags: 0x01 = volume, 0x02 = volume_number present
	var archive_flags: u64 = 0x01; // VOLUME
	if (volume_number != null) archive_flags |= 0x02; // VOLNUMBER
	mbpos += encode_vint(archive_flags, main_body[mbpos..]);
	if (volume_number) |vn| {
		mbpos += encode_vint(vn, main_body[mbpos..]);
	}
	pos += build_rar5_block(buf[pos..], 1, 0, null, null, main_body[0..mbpos]);

	// File block (if present)
	if (file_name) |fname| {
		const fdata = file_data orelse "";
		var file_body: [256]u8 = undefined;
		var fbpos: usize = 0;
		fbpos += encode_vint(0x0004, file_body[fbpos..]); // file_flags: has_crc32
		const unp_size = unpacked_size_override orelse fdata.len;
		fbpos += encode_vint(unp_size, file_body[fbpos..]); // unpacked_size
		fbpos += encode_vint(0x20, file_body[fbpos..]); // attributes
		// data_crc32 (only meaningful on last chunk, but we always write it)
		const file_crc = integrity.crc32(fdata);
		std.mem.writeInt(u32, file_body[fbpos..][0..4], file_crc, .little);
		fbpos += 4;
		fbpos += encode_vint(0, file_body[fbpos..]); // compression_info: store
		fbpos += encode_vint(0, file_body[fbpos..]); // host_os: Windows
		fbpos += encode_vint(fname.len, file_body[fbpos..]); // name_length
		@memcpy(file_body[fbpos..][0..fname.len], fname);
		fbpos += fname.len;

		// Header flags: HFL_DATA (0x02) + split_before (0x08) + split_after (0x10)
		var hflags: u64 = 0x02; // HFL_DATA
		if (split_before) hflags |= 0x08;
		if (split_after) hflags |= 0x10;

		pos += build_rar5_block(buf[pos..], 2, hflags, null, fdata.len, file_body[0..fbpos]);

		// Append file data payload
		@memcpy(buf[pos..][0..fdata.len], fdata);
		pos += fdata.len;
	}

	// End block: type=5, flags=0, body = end_flags vint
	var end_body: [16]u8 = undefined;
	var end_flags: u64 = 0;
	if (has_next_volume) end_flags |= 0x01;
	const end_body_len = encode_vint(end_flags, &end_body);
	pos += build_rar5_block(buf[pos..], 5, 0, null, null, end_body[0..end_body_len]);

	return pos;
}

test "rarz_open_volumes with 2-volume store split file" {
	// Build two synthetic volumes:
	// Volume 1: file "big.txt" with split_after, first 6 bytes
	// Volume 2: file "big.txt" with split_before, last 5 bytes
	const full_data = "hello world"; // 11 bytes total
	const chunk1 = full_data[0..6]; // "hello "
	const chunk2 = full_data[6..]; // "world"

	var vol1_buf: [2048]u8 = undefined;
	const vol1_len = build_rar5_volume(
		&vol1_buf,
		0,
		"big.txt",
		chunk1,
		false,
		true,
		true,
		full_data.len,
	);

	var vol2_buf: [2048]u8 = undefined;
	const vol2_len = build_rar5_volume(
		&vol2_buf,
		1,
		"big.txt",
		chunk2,
		true,
		false,
		false,
		full_data.len,
	);

	const volumes = [_][*]const u8{ &vol1_buf, &vol2_buf };
	const lengths = [_]usize{ vol1_len, vol2_len };

	const handle = rarz_open_volumes(&volumes, &lengths, 2);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	// Should have exactly 1 unified file
	try testing.expectEqual(@as(u32, 1), rarz_file_count(handle));

	// Verify file info
	var entry: RarzFileEntry = undefined;
	try testing.expectEqual(@as(i32, 0), rarz_file_info(handle, 0, &entry));
	try testing.expectEqual(@as(u32, 7), entry.name_len);
	try testing.expectEqualSlices(u8, "big.txt", entry.name.?[0..entry.name_len]);
	try testing.expectEqual(@as(u64, full_data.len), entry.unpacked_size);

	// Extract and verify the concatenated data
	var out: [256]u8 = undefined;
	const extracted = rarz_extract_to_buffer(handle, 0, &out, out.len);
	try testing.expectEqual(@as(i64, @intCast(full_data.len)), extracted);
	try testing.expectEqualSlices(u8, full_data, out[0..@intCast(extracted)]);
}

test "rarz_open_volumes with 3-volume split file" {
	const full_data = "ABCDEFGHIJKLMNO"; // 15 bytes
	const chunk1 = full_data[0..5]; // "ABCDE"
	const chunk2 = full_data[5..10]; // "FGHIJ"
	const chunk3 = full_data[10..]; // "KLMNO"

	var vol1_buf: [2048]u8 = undefined;
	const vol1_len = build_rar5_volume(&vol1_buf, 0, "split.dat", chunk1, false, true, true, full_data.len);

	var vol2_buf: [2048]u8 = undefined;
	const vol2_len = build_rar5_volume(&vol2_buf, 1, "split.dat", chunk2, true, true, true, full_data.len);

	var vol3_buf: [2048]u8 = undefined;
	const vol3_len = build_rar5_volume(&vol3_buf, 2, "split.dat", chunk3, true, false, false, full_data.len);

	const volumes = [_][*]const u8{ &vol1_buf, &vol2_buf, &vol3_buf };
	const lengths = [_]usize{ vol1_len, vol2_len, vol3_len };

	const handle = rarz_open_volumes(&volumes, &lengths, 3);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	try testing.expectEqual(@as(u32, 1), rarz_file_count(handle));

	var out: [256]u8 = undefined;
	const extracted = rarz_extract_to_buffer(handle, 0, &out, out.len);
	try testing.expectEqual(@as(i64, @intCast(full_data.len)), extracted);
	try testing.expectEqualSlices(u8, full_data, out[0..@intCast(extracted)]);
}

test "rarz_open_volumes with mix of complete and split files" {
	// Volume 1: complete file "small.txt" + start of split "big.txt"
	// Volume 2: end of split "big.txt" + complete file "other.txt"
	const small_data = "tiny";
	const big_data = "this is a bigger file content";
	const big_chunk1 = big_data[0..15];
	const big_chunk2 = big_data[15..];
	const other_data = "other stuff";

	// We need to build volumes with multiple file blocks each.
	// The build_rar5_volume helper only supports one file, so let's build manually.
	var vol1_buf: [4096]u8 = undefined;
	var v1pos: usize = 0;

	// Signature
	@memcpy(vol1_buf[v1pos..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);
	v1pos += detect.RAR50_SIG.len;

	// Main block (volume)
	var main_body: [32]u8 = undefined;
	var mbpos: usize = 0;
	mbpos += encode_vint(0x03, main_body[mbpos..]); // VOLUME + VOLNUMBER
	mbpos += encode_vint(0, main_body[mbpos..]); // volume_number = 0
	v1pos += build_rar5_block(vol1_buf[v1pos..], 1, 0, null, null, main_body[0..mbpos]);

	// File: small.txt (complete, no split)
	{
		var fb: [256]u8 = undefined;
		var fbp: usize = 0;
		fbp += encode_vint(0x0004, fb[fbp..]); // has_crc32
		fbp += encode_vint(small_data.len, fb[fbp..]);
		fbp += encode_vint(0x20, fb[fbp..]);
		std.mem.writeInt(u32, fb[fbp..][0..4], integrity.crc32(small_data), .little);
		fbp += 4;
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(9, fb[fbp..]); // "small.txt" = 9 chars
		@memcpy(fb[fbp..][0..9], "small.txt");
		fbp += 9;
		v1pos += build_rar5_block(vol1_buf[v1pos..], 2, 0x02, null, small_data.len, fb[0..fbp]);
		@memcpy(vol1_buf[v1pos..][0..small_data.len], small_data);
		v1pos += small_data.len;
	}

	// File: big.txt chunk1 (split_after)
	{
		var fb: [256]u8 = undefined;
		var fbp: usize = 0;
		fbp += encode_vint(0x0004, fb[fbp..]); // has_crc32
		fbp += encode_vint(big_data.len, fb[fbp..]);
		fbp += encode_vint(0x20, fb[fbp..]);
		std.mem.writeInt(u32, fb[fbp..][0..4], integrity.crc32(big_data), .little);
		fbp += 4;
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(7, fb[fbp..]);
		@memcpy(fb[fbp..][0..7], "big.txt");
		fbp += 7;
		v1pos += build_rar5_block(vol1_buf[v1pos..], 2, 0x02 | 0x10, null, big_chunk1.len, fb[0..fbp]); // HFL_DATA | split_after
		@memcpy(vol1_buf[v1pos..][0..big_chunk1.len], big_chunk1);
		v1pos += big_chunk1.len;
	}

	// End block (next_volume)
	{
		var eb: [16]u8 = undefined;
		const ebl = encode_vint(1, &eb); // next_volume flag
		v1pos += build_rar5_block(vol1_buf[v1pos..], 5, 0, null, null, eb[0..ebl]);
	}

	// Build volume 2
	var vol2_buf: [4096]u8 = undefined;
	var v2pos: usize = 0;

	@memcpy(vol2_buf[v2pos..][0..detect.RAR50_SIG.len], &detect.RAR50_SIG);
	v2pos += detect.RAR50_SIG.len;

	// Main block (volume)
	mbpos = 0;
	mbpos += encode_vint(0x03, main_body[mbpos..]);
	mbpos += encode_vint(1, main_body[mbpos..]); // volume_number = 1
	v2pos += build_rar5_block(vol2_buf[v2pos..], 1, 0, null, null, main_body[0..mbpos]);

	// File: big.txt chunk2 (split_before)
	{
		var fb: [256]u8 = undefined;
		var fbp: usize = 0;
		fbp += encode_vint(0x0004, fb[fbp..]); // has_crc32
		fbp += encode_vint(big_data.len, fb[fbp..]);
		fbp += encode_vint(0x20, fb[fbp..]);
		std.mem.writeInt(u32, fb[fbp..][0..4], integrity.crc32(big_data), .little);
		fbp += 4;
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(7, fb[fbp..]);
		@memcpy(fb[fbp..][0..7], "big.txt");
		fbp += 7;
		v2pos += build_rar5_block(vol2_buf[v2pos..], 2, 0x02 | 0x08, null, big_chunk2.len, fb[0..fbp]); // HFL_DATA | split_before
		@memcpy(vol2_buf[v2pos..][0..big_chunk2.len], big_chunk2);
		v2pos += big_chunk2.len;
	}

	// File: other.txt (complete)
	{
		var fb: [256]u8 = undefined;
		var fbp: usize = 0;
		fbp += encode_vint(0x0004, fb[fbp..]);
		fbp += encode_vint(other_data.len, fb[fbp..]);
		fbp += encode_vint(0x20, fb[fbp..]);
		std.mem.writeInt(u32, fb[fbp..][0..4], integrity.crc32(other_data), .little);
		fbp += 4;
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(0, fb[fbp..]);
		fbp += encode_vint(9, fb[fbp..]);
		@memcpy(fb[fbp..][0..9], "other.txt");
		fbp += 9;
		v2pos += build_rar5_block(vol2_buf[v2pos..], 2, 0x02, null, other_data.len, fb[0..fbp]);
		@memcpy(vol2_buf[v2pos..][0..other_data.len], other_data);
		v2pos += other_data.len;
	}

	// End block (no next volume)
	{
		var eb: [16]u8 = undefined;
		const ebl = encode_vint(0, &eb);
		v2pos += build_rar5_block(vol2_buf[v2pos..], 5, 0, null, null, eb[0..ebl]);
	}

	const volumes_arr = [_][*]const u8{ &vol1_buf, &vol2_buf };
	const lengths_arr = [_]usize{ v1pos, v2pos };

	const handle = rarz_open_volumes(&volumes_arr, &lengths_arr, 2);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	// Should have 3 unified files: small.txt, big.txt, other.txt
	try testing.expectEqual(@as(u32, 3), rarz_file_count(handle));

	// Extract small.txt
	var out: [256]u8 = undefined;
	var extracted = rarz_extract_to_buffer(handle, 0, &out, out.len);
	try testing.expectEqual(@as(i64, @intCast(small_data.len)), extracted);
	try testing.expectEqualSlices(u8, small_data, out[0..@intCast(extracted)]);

	// Extract big.txt (split across volumes)
	extracted = rarz_extract_to_buffer(handle, 1, &out, out.len);
	try testing.expectEqual(@as(i64, @intCast(big_data.len)), extracted);
	try testing.expectEqualSlices(u8, big_data, out[0..@intCast(extracted)]);

	// Extract other.txt
	extracted = rarz_extract_to_buffer(handle, 2, &out, out.len);
	try testing.expectEqual(@as(i64, @intCast(other_data.len)), extracted);
	try testing.expectEqualSlices(u8, other_data, out[0..@intCast(extracted)]);
}

test "rarz_file_info reports split flags on single-volume archive" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	var entry: RarzFileEntry = undefined;
	try testing.expectEqual(@as(i32, 0), rarz_file_info(handle, 0, &entry));
	// Non-split file should have split flags = 0
	try testing.expectEqual(@as(u8, 0), entry.split_before);
	try testing.expectEqual(@as(u8, 0), entry.split_after);
}

test "rarz_open_volumes returns null for empty input" {
	try testing.expect(rarz_open_volumes(null, null, 0) == null);
}

// ============================================================================
// FFI error propagation tests
// ============================================================================

test "rarz_last_error returns null initially" {
	rarz_clear_error();
	try testing.expect(rarz_last_error() == null);
}

test "rarz_open sets error on garbage data" {
	rarz_clear_error();
	const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
	const handle = rarz_open(&garbage, garbage.len);
	try testing.expect(handle == null);
	try testing.expect(rarz_last_error() != null);
}

test "rarz_extract_to_buffer sets error on bad index" {
	rarz_clear_error();
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);
	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);

	var out: [256]u8 = undefined;
	const result = rarz_extract_to_buffer(handle, 99, &out, out.len);
	try testing.expectEqual(@as(i64, -1), result);
	try testing.expect(rarz_last_error() != null);
}

test "rarz_open clears error on success" {
	// First cause an error
	const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
	_ = rarz_open(&garbage, garbage.len);
	try testing.expect(rarz_last_error() != null);

	// Now open a valid archive — should clear
	var buf: [512]u8 = undefined;
	const archive_len = build_minimal_rar5(&buf);
	const handle = rarz_open(&buf, archive_len);
	try testing.expect(handle != null);
	defer rarz_close(handle);
	try testing.expect(rarz_last_error() == null);
}

test "rarz_create_archive sets error on null entries" {
	rarz_clear_error();
	var buf: [256]u8 = undefined;
	const result = rarz_create_archive(null, 0, &buf, buf.len);
	try testing.expectEqual(@as(i64, -1), result);
	try testing.expect(rarz_last_error() != null);
}

test "rarz_file_info sets error on null handle" {
	rarz_clear_error();
	var entry: RarzFileEntry = undefined;
	const result = rarz_file_info(null, 0, &entry);
	try testing.expectEqual(@as(i32, -1), result);
	try testing.expect(rarz_last_error() != null);
}

// ============================================================================
// Compression of large/incompressible data (regression: segfault > ~10KB)
// ============================================================================

test "rarz_create_archive_compressed handles 50KB random data without crashing" {
	// Reproduces segfault: compressing incompressible data > ~10KB
	const alloc = std.heap.page_allocator;
	const data_size: usize = 50 * 1024;
	const data = try alloc.alloc(u8, data_size);
	defer alloc.free(data);

	// Fill with pseudo-random data (incompressible)
	var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
	const random = prng.random();
	for (data) |*b| b.* = random.int(u8);

	const c_entries = [_]RarzCreateFileEntry{.{
		.name = "random.bin",
		.name_len = 10,
		.data = data.ptr,
		.data_len = data_size,
		.mtime = 0,
		.is_directory = 0,
		.host_os = 0,
		.attributes = 0,
	}};

	// Generous output buffer: 2x input + overhead
	const out_size = data_size * 2 + 65536;
	const out_buf = try alloc.alloc(u8, out_size);
	defer alloc.free(out_buf);

	const result = rarz_create_archive_compressed(&c_entries, 1, out_buf.ptr, out_size, 3);
	// Must not crash. Should succeed or return a clean error code.
	try testing.expect(result > 0 or result == -2 or result == -3);
}

// ============================================================================
// Corruption robustness tests (must never crash/abort)
// ============================================================================

test "rarz_validate handles every single-byte corruption without crashing" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	for (0..archive_len) |i| {
		var corrupted = buf;
		corrupted[i] ^= 0xFF;
		const result = rarz_validate(&corrupted, archive_len);
		_ = result; // must not abort
	}
}

test "rarz_validate handles truncation at every position without crashing" {
	var buf: [1024]u8 = undefined;
	const file_data = "hello world";
	const archive_len = build_rar5_with_file(&buf, "test.txt", file_data);

	for (1..archive_len) |len| {
		const result = rarz_validate(&buf, len);
		_ = result; // must not abort
	}
}

test "rarz_validate handles RAR5 signature followed by garbage" {
	var data: [64]u8 = undefined;
	@memcpy(data[0..8], &detect.RAR50_SIG);
	@memset(data[8..], 0xFF);
	const result = rarz_validate(&data, data.len);
	_ = result;
}

test "rarz_validate handles single-byte input" {
	const data = [_]u8{0x52}; // just 'R'
	const result = rarz_validate(&data, 1);
	try testing.expectEqual(@as(i32, 0), result.is_valid);
}

test "rarz_validate handles zero-length input" {
	const result = rarz_validate(null, 0);
	try testing.expectEqual(@as(i32, 0), result.is_valid);
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
	_ = @import("decompress/filters.zig");
	_ = @import("decompress/unpack50.zig");
	_ = @import("decompress/ppm.zig");
	_ = @import("decompress/unpack29.zig");
	_ = @import("decompress/unpack20.zig");
	_ = @import("decompress/unpack15.zig");
	_ = @import("decompress/dispatch.zig");
	_ = @import("compress/bitwriter.zig");
	_ = @import("compress/huffman_encoder.zig");
	_ = @import("compress/slot_tables.zig");
	_ = @import("compress/match_finder.zig");
	_ = @import("compress/pack50.zig");
}
