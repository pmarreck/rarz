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
const sink = @import("decompress/sink.zig");

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
	/// RAR4 compression descriptor. Null for RAR5 entries, where `compression`
	/// is authoritative instead. RAR4 describes an entry by
	/// (unpack_version, method, raw flags) and has no CompressionInfo, so the
	/// two families cannot share one field.
	rar4: ?Rar4Compression = null,
};

const Rar4Compression = struct {
	unpack_version: u8,
	method: u8,
	flags_raw: u16,
};

/// RAR4 stores the method as the ASCII digits '0'..'5', but `parse_file_header`
/// already normalises it (`method_raw -% 0x30`), so store is 0 by the time it
/// reaches here — the same value RAR5 uses.
const RAR4_METHOD_STORE: u8 = 0;

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

	/// Decoder carried across entries, for solid archives.
	///
	/// `rarz_extract_to_buffer` is index-based random access, which is the wrong
	/// shape for a solid archive: every entry is one slice of a single
	/// continuous stream, so entry N needs the window and tables entry N-1 left
	/// behind. Caching the decoder here — together with the index it is
	/// positioned at — turns the CLI's front-to-back extraction into ONE pass,
	/// while an out-of-order request still gets a correct answer by replaying
	/// the predecessors it missed.
	///
	/// This keeps the FFI signature unchanged, which matters: the C CLI is the
	/// dogfooding consumer, and a solid archive should not need a different API.
	solid_session: ?dispatch.SolidSession,
	/// Entry index `solid_session` is ready to decode next. A request for any
	/// other index means the session must be rewound and replayed.
	solid_next_index: u32,

	fn deinit(self: *ArchiveHandle) void {
		if (self.solid_session) |*s| s.deinit();
		self.arena.deinit();
		std.heap.page_allocator.destroy(self);
	}

	fn resetSolidSession(self: *ArchiveHandle) void {
		if (self.solid_session) |*s| s.deinit();
		self.solid_session = null;
		self.solid_next_index = 0;
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
		.solid_session = null,
		.solid_next_index = 0,
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
			.is_directory = @intFromBool(rar4_headers.is_directory_entry(f)),
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

		// See the RAR4 path for why this cast is sound: the cache is a memo on a
		// heap-allocated handle that is only *declared* const across the FFI.
		const mut5: *ArchiveHandle = @constCast(a);
		var bs5 = sink.BufferSink.init(buf[0..@intCast(f.unpacked_size)]);
		decodeRar5Entry(mut5, files, index, bs5.sink()) catch |err| {
			setLastError(switch (err) {
				error.OutOfMemory => "out of memory",
				else => "decompression failed",
			});
			return -3;
		};
		clearLastError();
		return @intCast(bs5.len);
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

		// The solid decoder cache is a MEMO: it changes how fast the next
		// extraction runs, never what any call returns. The handle is
		// heap-allocated by rarz_archive_open and only *declared* const across
		// the FFI, so this is not a write to genuinely-const storage. Casting
		// here keeps `const rarz_archive *` in the published header intact —
		// solid support should not force every C caller to change.
		const mut: *ArchiveHandle = @constCast(a);
		var bs = sink.BufferSink.init(buf[0..@intCast(f.unpacked_size)]);
		decodeRar4Entry(mut, files, index, bs.sink()) catch |err| {
			setLastError(switch (err) {
				error.OutOfMemory => "out of memory",
				error.UnsupportedFilter => "entry uses an unsupported filter; contents cannot be verified",
				else => "decompression failed",
			});
			return -3;
		};
		clearLastError();
		return @intCast(bs.len);
	}

	setLastError("file index out of range");
	return -1;
}

/// Byte range of a RAR5 entry's packed payload within the archive buffer.
fn rar5PayloadRange(a: *ArchiveHandle, f: rar5_headers.FileBlock) ?struct { start: usize, end: usize } {
	const data_size = f.header.data_size orelse return null;
	const start = a.block_data_offset + f.header.header_start + 4 + f.header.crc_data_len;
	const end = start + @as(usize, @intCast(data_size));
	if (end > a.data.len) return null;
	return .{ .start = start, .end = end };
}

/// RAR5 counterpart of `decodeRar4Entry`; see that function for the caching and
/// replay rationale.
///
/// Takes a `Sink` rather than a buffer so extraction and verify-only share one
/// path: extraction passes a `BufferSink`, verification a `VerifySink` that
/// hashes and discards. Two copies of the solid replay logic would be two places
/// for it to drift.
fn decodeRar5Entry(
	a: *ArchiveHandle,
	files: []rar5_headers.FileBlock,
	index: u32,
	out: sink.Sink,
) !void {
	const alloc = std.heap.page_allocator;
	const target = files[index];

	var usable = a.solid_next_index == index;
	if (usable) {
		if (a.solid_session) |*s| {
			usable = s.acceptsRar5(target.compression);
		} else {
			usable = false;
		}
	}
	if (!usable) {
		a.resetSolidSession();
		a.solid_session = try dispatch.SolidSession.initRar5(alloc, target.compression);

		var run_start: u32 = index;
		while (run_start > 0 and files[run_start].compression.solid) {
			run_start -= 1;
		}

		var i = run_start;
		while (i < index) : (i += 1) {
			const pred = files[i];
			// Store-method entries bypass the unpacker and contribute nothing to
			// the window, so they are not replayed.
			if (pred.compression.method == 0) continue;
			const range = rar5PayloadRange(a, pred) orelse return error.CorruptData;
			var discard = sink.DiscardSink{};
			try a.solid_session.?.decodeFile(
				a.data[range.start..range.end],
				pred.unpacked_size,
				pred.compression.solid,
				discard.sink(),
			);
		}
		a.solid_next_index = index;
	}

	const range = rar5PayloadRange(a, target) orelse return error.CorruptData;
	a.solid_session.?.decodeFile(
		a.data[range.start..range.end],
		target.unpacked_size,
		target.compression.solid,
		out,
	) catch |err| {
		// The session's position is now unknown, so it must not be reused.
		a.resetSolidSession();
		return err;
	};
	a.solid_next_index = index + 1;
}

/// Byte range of a RAR4 entry's packed payload within the archive buffer.
fn rar4PayloadRange(a: *ArchiveHandle, f: rar4_headers.FileHeader) ?struct { start: usize, end: usize } {
	const start = a.block_data_offset + f.block.header_offset + f.block.head_size;
	const end = start + @as(usize, @intCast(f.packed_size));
	if (end > a.data.len) return null;
	return .{ .start = start, .end = end };
}

/// Extract one compressed RAR4 entry, replaying solid predecessors when needed.
///
/// The cached session makes the common case — the CLI walking entries 0,1,2,… —
/// a single pass over the stream. An out-of-order request rewinds to the start
/// of the solid run and replays the entries in between into a DiscardSink: their
/// bytes are wanted only for the window they leave behind.
///
/// Replaying from index 0 on every call would also be correct but O(n^2); on an
/// archive of thousands of entries that is the difference between usable and not.
fn decodeRar4Entry(
	a: *ArchiveHandle,
	files: []rar4_headers.FileHeader,
	index: u32,
	out: sink.Sink,
) !void {
	const alloc = std.heap.page_allocator;
	const target = files[index];

	// Rewind when the cached decoder is not positioned here, or cannot serve
	// this entry's format/dictionary.
	var usable = a.solid_next_index == index;
	if (usable) {
		if (a.solid_session) |*s| {
			usable = s.acceptsRar4(target.unpack_version, target.block.flags);
		} else {
			usable = false;
		}
	}
	if (!usable) {
		a.resetSolidSession();
		a.solid_session = try dispatch.SolidSession.initRar4(
			alloc,
			target.unpack_version,
			target.block.flags,
		);

		// Replay from the start of this entry's solid run. Walking back to the
		// nearest non-solid entry — rather than to index 0 — keeps a
		// multi-group archive from re-decoding groups it does not need.
		var run_start: u32 = index;
		while (run_start > 0 and rar4_headers.parse_file_flags(files[run_start].block.flags).solid) {
			run_start -= 1;
		}

		var i = run_start;
		while (i < index) : (i += 1) {
			const pred = files[i];
			// Store-method entries bypass the unpacker entirely and contribute
			// nothing to the window, exactly as the reference does
			// (`if (Method==0) UnstoreFile(...)`), so they are not replayed.
			if (pred.method == 0 or pred.packed_size == 0) continue;
			const range = rar4PayloadRange(a, pred) orelse return error.CorruptData;
			var discard = sink.DiscardSink{};
			try a.solid_session.?.decodeFile(
				a.data[range.start..range.end],
				pred.unpacked_size,
				rar4_headers.parse_file_flags(pred.block.flags).solid,
				discard.sink(),
			);
		}
		a.solid_next_index = index;
	}

	const range = rar4PayloadRange(a, target) orelse return error.CorruptData;
	a.solid_session.?.decodeFile(
		a.data[range.start..range.end],
		target.unpacked_size,
		rar4_headers.parse_file_flags(target.block.flags).solid,
		out,
	) catch |err| {
		// The session's position is now unknown, so it must not be reused.
		a.resetSolidSession();
		return err;
	};
	a.solid_next_index = index + 1;
}

// ============================================================================
// Verify-only: decode an entry and check its checksums, without materialising it
// ============================================================================

/// Outcome codes for `rarz_verify_file`, mirrored in include/rarz.h.
const VERIFY_OK: i32 = 0;
const VERIFY_CHECKSUM_MISMATCH: i32 = 1;
const VERIFY_NO_CHECKSUM: i32 = 2;
const VERIFY_UNSUPPORTED: i32 = 3;
const VERIFY_ERROR: i32 = 4;

/// Archive-level outcomes for `rarz_verify_archive`, mirrored in include/rarz.h.
const ARCHIVE_VERIFY_VERIFIED: i32 = 0;
const ARCHIVE_VERIFY_DAMAGED: i32 = 1;
const ARCHIVE_VERIFY_INCOMPLETE: i32 = 2;
const ARCHIVE_VERIFY_ERROR: i32 = 3;

/// Result of verifying one entry. Extern layout — part of the C ABI.
const RarzVerifyResult = extern struct {
	status: i32,
	/// Decoded bytes actually hashed. Compared against the header's declared
	/// unpacked size by the caller; a short count on a status-OK entry would
	/// mean the decoder stopped early.
	bytes_verified: u64,
	crc32_expected: u32,
	crc32_actual: u32,
	has_crc32: u8,
	/// 1 when a BLAKE2sp was present AND matched. RAR4 never carries one.
	checked_blake2sp: u8,
	is_directory: u8,
	/// 1 when this entry's content is encrypted. Reported alongside the status
	/// rather than folded into it, so a caller can distinguish "unsupported
	/// because we have no password" from "unsupported because the decode
	/// failed" — both of which return VERIFY_UNSUPPORTED.
	is_encrypted: u8 = 0,
};

/// Lossless archive rollup of the per-entry verify evidence.
///
/// Counts are kept separate so mixed archives remain expressible: one damaged
/// entry and one unsupported entry is damaged overall while still reporting
/// the unsupported evidence. The accounting invariant prevents a new entry
/// path from disappearing from the consumer's view.
const RarzVerifyArchiveSummary = extern struct {
	status: i32,
	entry_count: u32,
	verified_entry_count: u32,
	damaged_entry_count: u32,
	unsupported_entry_count: u32,
	no_checksum_entry_count: u32,
	error_entry_count: u32,
	directory_count: u32,
	format_supported: u8,
	_pad: [3]u8 = .{ 0, 0, 0 },
	/// Entries whose CONTENT is encrypted. Deliberately NOT part of the
	/// accounting invariant: encryption is a property of an entry, not an
	/// outcome, so an encrypted entry is always also counted in exactly one
	/// outcome bucket. Today that bucket is `unsupported`; if a password API
	/// lands, the same entry becomes `verified` and this count stays true.
	///
	/// It exists because `unsupported_entry_count` alone cannot say WHY an
	/// entry went unverified — encryption and a failed decode both land there,
	/// and a consumer reporting "unsupported due to encrypted content" would
	/// be guessing. With this field the reason is a fact, not an inference.
	encrypted_entry_count: u32,

	/// True when the archive holds BOTH encrypted and unencrypted content.
	/// Such an archive cannot be fully verified without a password, yet its
	/// readable entries can be and are — so it is neither wholly opaque nor
	/// fully checked, and a consumer needs to say so precisely.
	fn hasMixedEncryption(self: RarzVerifyArchiveSummary) bool {
		const content_entries = self.entry_count - self.directory_count;
		return self.encrypted_entry_count > 0 and
			self.encrypted_entry_count < content_entries;
	}

	fn accountedEntryCount(self: RarzVerifyArchiveSummary) u32 {
		return self.verified_entry_count +
			self.damaged_entry_count +
			self.unsupported_entry_count +
			self.no_checksum_entry_count +
			self.error_entry_count +
			self.directory_count;
	}
};

/// Verify one entry by decoding it into a hashing sink and comparing against the
/// checksums stored in its header. Nothing the size of the decoded entry is
/// allocated.
///
/// This is the verify-only path a C consumer previously could not reach: to
/// check entry N it had to allocate `unpacked_size` bytes and call
/// `rarz_extract_to_buffer`, paying for bytes it meant to discard. Peak memory
/// here is the LZ window plus the hash state, whatever the entry's size.
///
/// On a solid archive, verifying entries in order costs ONE pass — the decoder
/// cache on the handle is keyed by next-expected-index, so each entry continues
/// the shared stream instead of replaying its predecessors.
export fn rarz_verify_file(
	archive: ?*const ArchiveHandle,
	index: u32,
	out_result: ?*RarzVerifyResult,
) i32 {
	const a = archive orelse {
		setLastError("null archive handle");
		return VERIFY_ERROR;
	};
	const res = out_result orelse {
		setLastError("null result pointer");
		return VERIFY_ERROR;
	};

	res.* = .{
		.status = VERIFY_ERROR,
		.bytes_verified = 0,
		.crc32_expected = 0,
		.crc32_actual = 0,
		.has_crc32 = 0,
		.checked_blake2sp = 0,
		.is_directory = 0,
	};

	// The cache is a memo on a heap-allocated handle that is only *declared*
	// const across the FFI; see rarz_extract_to_buffer for the full rationale.
	const mut: *ArchiveHandle = @constCast(a);

	// Multi-volume: entries are reassembled from chunks spread across volumes.
	// This branch must come FIRST — a handle opened over a volume set also has
	// rar5_files populated for its own volume, and using that would decode only
	// the leading chunk of a split file and report "decompression failed" on a
	// perfectly intact set.
	if (a.unified_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return VERIFY_ERROR;
		}
		const uf = files[index];
		const volumes = a.volumes orelse {
			setLastError("corrupt archive handle");
			return VERIFY_ERROR;
		};

		if (uf.is_directory) {
			res.is_directory = 1;
			res.status = VERIFY_OK;
			clearLastError();
			return VERIFY_OK;
		}
		if (uf.packed_chunks.len == 0) {
			setLastError("file has no packed data");
			return VERIFY_ERROR;
		}

		var vs = sink.VerifySink.init(false);
		const alloc = std.heap.page_allocator;

		if (uf.compression.method == 0) {
			// Store: hash each chunk in order, no decoder and no reassembly.
			for (uf.packed_chunks) |chunk| {
				const vol = volumes[chunk.volume_index];
				vs.sink().write(vol.data[chunk.offset..][0..chunk.length]);
			}
		} else {
			// Compressed: the packed stream itself spans volumes, so it has to
			// be contiguous before the decoder can read it. This is the one
			// place verification still allocates, and it allocates the PACKED
			// size, not the decoded size.
			var total_packed: usize = 0;
			for (uf.packed_chunks) |chunk| total_packed += chunk.length;

			const combined = alloc.alloc(u8, total_packed) catch {
				setLastError("out of memory");
				return VERIFY_ERROR;
			};
			defer alloc.free(combined);

			var wpos: usize = 0;
			for (uf.packed_chunks) |chunk| {
				const vol = volumes[chunk.volume_index];
				@memcpy(combined[wpos..][0..chunk.length], vol.data[chunk.offset..][0..chunk.length]);
				wpos += chunk.length;
			}

			const decompressed = (if (uf.rar4) |r4| dispatch.decompressRar4(
				alloc,
				combined,
				uf.unpacked_size,
				r4.unpack_version,
				r4.method,
				r4.flags_raw,
			) else dispatch.decompressRar5(
				alloc,
				combined,
				uf.unpacked_size,
				uf.compression,
			)) catch {
				setLastError("decompression failed");
				res.status = VERIFY_UNSUPPORTED;
				return VERIFY_UNSUPPORTED;
			};
			defer alloc.free(decompressed);
			vs.sink().write(decompressed);
		}

		res.bytes_verified = vs.len;
		// PRECISION: fewer bytes than the header declares means the decoder
		// stopped early. With a checksum the CRC would catch it; without one
		// this is the ONLY signal, so it is checked before anything else.
		if (vs.len != uf.unpacked_size) {
			setLastError("decoded size does not match the size declared in the header");
			res.status = VERIFY_CHECKSUM_MISMATCH;
			return VERIFY_CHECKSUM_MISMATCH;
		}
		res.has_crc32 = @intFromBool(uf.has_crc32);
		if (uf.has_crc32) {
			res.crc32_expected = uf.data_crc32.?;
			res.crc32_actual = vs.crc32();
			if (res.crc32_expected != res.crc32_actual) {
				setLastError("payload CRC32 mismatch");
				res.status = VERIFY_CHECKSUM_MISMATCH;
				return VERIFY_CHECKSUM_MISMATCH;
			}
		} else {
			res.status = VERIFY_NO_CHECKSUM;
			clearLastError();
			return VERIFY_NO_CHECKSUM;
		}
		res.status = VERIFY_OK;
		clearLastError();
		return VERIFY_OK;
	}

	if (a.rar5_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return VERIFY_ERROR;
		}
		const f = files[index];

		if (f.is_directory) {
			res.is_directory = 1;
			res.status = VERIFY_OK;
			clearLastError();
			return VERIFY_OK;
		}
		if (rar5_headers.extra_has_encryption(f.extra_data)) {
			setLastError("entry is encrypted; contents cannot be verified without a password");
			res.is_encrypted = 1;
			res.status = VERIFY_UNSUPPORTED;
			return VERIFY_UNSUPPORTED;
		}

		const expected_blake = rar5_headers.extract_blake2sp_hash_raw(f.extra_data);
		var vs = sink.VerifySink.init(expected_blake != null);

		if (f.compression.method == 0) {
			// Store: no decoder involved, hash the raw payload.
			const range = rar5PayloadRange(mut, f) orelse {
				setLastError("declared payload extends beyond end of archive (truncated)");
				return VERIFY_ERROR;
			};
			vs.sink().write(a.data[range.start..range.end]);
		} else {
			decodeRar5Entry(mut, files, index, vs.sink()) catch |err| {
				setLastError(switch (err) {
					error.OutOfMemory => "out of memory",
					else => "decompression failed",
				});
				res.status = VERIFY_UNSUPPORTED;
				return VERIFY_UNSUPPORTED;
			};
		}

		res.bytes_verified = vs.len;
		// PRECISION: fewer bytes than the header declares means the decoder
		// stopped early. With a checksum the CRC would catch it; without one
		// this is the ONLY signal, so it is checked before anything else.
		if (vs.len != f.unpacked_size) {
			setLastError("decoded size does not match the size declared in the header");
			res.status = VERIFY_CHECKSUM_MISMATCH;
			return VERIFY_CHECKSUM_MISMATCH;
		}
		res.has_crc32 = @intFromBool(f.has_crc32);
		if (f.has_crc32) {
			res.crc32_expected = f.data_crc32.?;
			res.crc32_actual = vs.crc32();
		}
		if (expected_blake) |expected| {
			var got: [32]u8 = undefined;
			vs.blake2sp(&got);
			if (!std.mem.eql(u8, &got, &expected)) {
				setLastError("payload BLAKE2sp mismatch");
				res.status = VERIFY_CHECKSUM_MISMATCH;
				return VERIFY_CHECKSUM_MISMATCH;
			}
			res.checked_blake2sp = 1;
		}
		if (f.has_crc32 and res.crc32_expected != res.crc32_actual) {
			setLastError("payload CRC32 mismatch");
			res.status = VERIFY_CHECKSUM_MISMATCH;
			return VERIFY_CHECKSUM_MISMATCH;
		}
		// PRECISION: an entry with nothing to check must not read as verified.
		if (!f.has_crc32 and expected_blake == null) {
			res.status = VERIFY_NO_CHECKSUM;
			clearLastError();
			return VERIFY_NO_CHECKSUM;
		}
		res.status = VERIFY_OK;
		clearLastError();
		return VERIFY_OK;
	}

	if (a.rar4_files) |files| {
		if (index >= files.len) {
			setLastError("file index out of range");
			return VERIFY_ERROR;
		}
		const f = files[index];

		if (rar4_headers.is_directory_entry(f)) {
			res.is_directory = 1;
			res.status = VERIFY_OK;
			clearLastError();
			return VERIFY_OK;
		}
		// PRECISION: without this the STORE path hashes ciphertext against the
		// plaintext CRC32 in the header and calls an intact archive damaged —
		// a false positive on good data. The RAR5 branch above always had this
		// check; RAR4 did not, so `rarz t` (which consults policy.zig) and
		// `rarz verify` disagreed on the very same archive.
		if (rar4_headers.parse_file_flags(f.block.flags).password) {
			setLastError("entry is encrypted; contents cannot be verified without a password");
			res.is_encrypted = 1;
			res.status = VERIFY_UNSUPPORTED;
			return VERIFY_UNSUPPORTED;
		}

		var vs = sink.VerifySink.init(false); // RAR4 carries no BLAKE2sp

		if (f.method == 0) {
			const range = rar4PayloadRange(mut, f) orelse {
				setLastError("declared payload extends beyond end of archive (truncated)");
				return VERIFY_ERROR;
			};
			vs.sink().write(a.data[range.start..range.end]);
		} else {
			decodeRar4Entry(mut, files, index, vs.sink()) catch |err| {
				setLastError(switch (err) {
					error.OutOfMemory => "out of memory",
					error.UnsupportedFilter => "entry uses an unsupported filter; contents cannot be verified",
					else => "decompression failed",
				});
				res.status = VERIFY_UNSUPPORTED;
				return VERIFY_UNSUPPORTED;
			};
		}

		res.bytes_verified = vs.len;
		// See the RAR5 path: a short decode is the only signal when no checksum
		// exists, and a cheap cross-check when one does.
		if (vs.len != f.unpacked_size) {
			setLastError("decoded size does not match the size declared in the header");
			res.status = VERIFY_CHECKSUM_MISMATCH;
			return VERIFY_CHECKSUM_MISMATCH;
		}
		res.has_crc32 = 1;
		res.crc32_expected = f.file_crc;
		res.crc32_actual = vs.crc32();
		if (res.crc32_expected != res.crc32_actual) {
			setLastError("payload CRC32 mismatch");
			res.status = VERIFY_CHECKSUM_MISMATCH;
			return VERIFY_CHECKSUM_MISMATCH;
		}
		res.status = VERIFY_OK;
		clearLastError();
		return VERIFY_OK;
	}

	setLastError("archive has no verifiable entries");
	return VERIFY_ERROR;
}

/// Verify every entry and publish a complete, additive archive summary.
///
/// Return value equals `out_summary.status`. A damaged result takes precedence
/// over incomplete evidence, while every incomplete count remains visible.
/// This function does not invoke an external decoder or oracle.
export fn rarz_verify_archive(
	archive: ?*const ArchiveHandle,
	out_summary: ?*RarzVerifyArchiveSummary,
) i32 {
	const a = archive orelse {
		setLastError("null archive handle");
		return ARCHIVE_VERIFY_ERROR;
	};
	const summary = out_summary orelse {
		setLastError("null archive summary pointer");
		return ARCHIVE_VERIFY_ERROR;
	};

	summary.* = .{
		.status = ARCHIVE_VERIFY_VERIFIED,
		.entry_count = rarz_file_count(a),
		.verified_entry_count = 0,
		.damaged_entry_count = 0,
		.unsupported_entry_count = 0,
		.no_checksum_entry_count = 0,
		.error_entry_count = 0,
		.directory_count = 0,
		.format_supported = @intFromBool(a.family != .rar14),
		.encrypted_entry_count = 0,
	};

	// RAR 1.4 is recognised but has no parser. Zero enumerated entries is an
	// incomplete result for that family, not a vacuous success.
	if (summary.format_supported == 0) {
		summary.status = ARCHIVE_VERIFY_INCOMPLETE;
		clearLastError();
		return summary.status;
	}

	for (0..summary.entry_count) |index| {
		var entry_result: RarzVerifyResult = undefined;
		const entry_status = rarz_verify_file(a, @intCast(index), &entry_result);
		if (entry_result.is_directory != 0) {
			summary.directory_count += 1;
			continue;
		}
		// Orthogonal to the outcome buckets below — see the field's comment.
		if (entry_result.is_encrypted != 0) summary.encrypted_entry_count += 1;
		switch (entry_status) {
			VERIFY_OK => summary.verified_entry_count += 1,
			VERIFY_CHECKSUM_MISMATCH => summary.damaged_entry_count += 1,
			VERIFY_NO_CHECKSUM => summary.no_checksum_entry_count += 1,
			VERIFY_UNSUPPORTED => summary.unsupported_entry_count += 1,
			else => summary.error_entry_count += 1,
		}
	}

	std.debug.assert(summary.accountedEntryCount() == summary.entry_count);
	if (summary.damaged_entry_count > 0 or summary.error_entry_count > 0) {
		summary.status = ARCHIVE_VERIFY_DAMAGED;
	} else if (summary.unsupported_entry_count > 0 or summary.no_checksum_entry_count > 0) {
		summary.status = ARCHIVE_VERIFY_INCOMPLETE;
	}
	clearLastError();
	return summary.status;
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
/// Merge RAR4 file blocks across volumes into whole-file entries.
///
/// Mirrors `collectRar5FilesUnified`. Like RAR5, the authoritative whole-file
/// CRC lives in the part where the file COMPLETES (split_after == false);
/// earlier parts carry a per-segment value. Confirmed against the producer:
/// `unrar lt` prints `Pack-CRC32` for the leading parts of a split RAR4 file
/// and a plain `CRC32` only on the completing one.
fn collectRar4FilesUnified(alloc: std.mem.Allocator, volumes: []const VolumeData) ![]UnifiedFile {
	const FileWithVolume = struct {
		fh: rar4_headers.FileHeader,
		volume_index: u32,
		packed_data_offset: usize,
	};

	var all: std.ArrayList(FileWithVolume) = .empty;
	defer all.deinit(alloc);

	for (volumes, 0..) |vol, vi| {
		var iter = rar4_headers.walk_blocks(vol.data[vol.block_data_offset..]);
		while (true) {
			const block = iter.next() catch break;
			if (block == null) break;
			switch (block.?) {
				.file => |fh| {
					const header_end = vol.block_data_offset + fh.block.header_offset + fh.block.head_size;
					try all.append(alloc, .{
						.fh = fh,
						.volume_index = @intCast(vi),
						.packed_data_offset = header_end,
					});
				},
				else => {},
			}
		}
	}

	var unified: std.ArrayList(UnifiedFile) = .empty;
	errdefer unified.deinit(alloc);

	var i: usize = 0;
	while (i < all.items.len) {
		const first = all.items[i];
		const first_flags = rar4_headers.parse_file_flags(first.fh.block.flags);
		if (first_flags.split_before) {
			i += 1; // continuation, consumed by a previous merge
			continue;
		}

		var chunks: std.ArrayList(PackedChunk) = .empty;
		errdefer chunks.deinit(alloc);
		try chunks.append(alloc, .{
			.volume_index = first.volume_index,
			.offset = first.packed_data_offset,
			.length = @intCast(first.fh.packed_size),
		});
		var total_packed: u64 = first.fh.packed_size;
		var last_fh = first.fh;

		var j: usize = i + 1;
		if (first_flags.split_after) {
			while (j < all.items.len) {
				const cont = all.items[j];
				const cf = rar4_headers.parse_file_flags(cont.fh.block.flags);
				if (!cf.split_before) break;
				if (!std.mem.eql(u8, first.fh.file_name, cont.fh.file_name)) break;
				try chunks.append(alloc, .{
					.volume_index = cont.volume_index,
					.offset = cont.packed_data_offset,
					.length = @intCast(cont.fh.packed_size),
				});
				total_packed += cont.fh.packed_size;
				last_fh = cont.fh;
				j += 1;
				if (!cf.split_after) break;
			}
		}

		try unified.append(alloc, .{
			.name = first.fh.file_name,
			.unpacked_size = first.fh.unpacked_size,
			// CompressionInfo is RAR5-shaped and cannot hold a RAR4 method
			// (0x30-0x35 in a u3). Only the store-vs-compressed distinction is
			// consulted on the shared path, so carry exactly that; the real
			// RAR4 descriptor lives in `.rar4` below.
			.compression = .{
				.algo_version = 0,
				.solid = first_flags.solid,
				.method = if (first.fh.method == RAR4_METHOD_STORE) 0 else 1,
				.dict_bits = 0,
				.dict_frac_bits = 0,
			},
			.data_crc32 = last_fh.file_crc,
			.mtime = first.fh.mtime,
			.is_directory = rar4_headers.is_directory_entry(first.fh),
			.host_os = first.fh.host_os,
			.has_crc32 = true, // RAR4 always stores one
			.is_encrypted = first_flags.password,
			.total_packed_size = total_packed,
			.packed_chunks = try chunks.toOwnedSlice(alloc),
			.rar4 = .{
				.unpack_version = first.fh.unpack_version,
				.method = first.fh.method,
				.flags_raw = first.fh.block.flags,
			},
		});

		i = if (j > i) j else i + 1;
	}

	return unified.toOwnedSlice(alloc);
}

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

		// RAR5 stores the authoritative full-file hash in the LAST part (where the
		// file completes, split_after == false). Track it so the merged file reports
		// the true full-file CRC, not the first part's per-segment value.
		var last_fb = first.fb;

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
				last_fb = cont.fb;

				j += 1;
				if (!cont.fb.header.flags.split_after) break;
			}
		}

		try unified.append(alloc, .{
			.name = first.fb.name,
			.unpacked_size = first.fb.unpacked_size,
			.compression = first.fb.compression,
			.data_crc32 = last_fb.data_crc32,
			.mtime = first.fb.mtime,
			.is_directory = first.fb.is_directory,
			.host_os = first.fb.host_os,
			.has_crc32 = last_fb.has_crc32,
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
		.solid_session = null,
		.solid_next_index = 0,
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

	if (family != .rar50 and family != .rar15) {
		handle.deinit();
		setLastError("multi-volume only supported for RAR4 and RAR5");
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
	handle.unified_files = (if (family == .rar15)
		collectRar4FilesUnified(alloc, vol_data)
	else
		collectRar5FilesUnified(alloc, vol_data)) catch {
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

test "rarz_verify_archive accounts for every pristine and payload-mutated entry" {
	const pristine: []const u8 = @embedFile("rar5_store");
	const pristine_archive = rarz_open(pristine.ptr, pristine.len) orelse return error.TestUnexpectedResult;
	defer rarz_close(pristine_archive);

	var pristine_summary: RarzVerifyArchiveSummary = undefined;
	try testing.expectEqual(ARCHIVE_VERIFY_VERIFIED, rarz_verify_archive(pristine_archive, &pristine_summary));
	try testing.expectEqual(pristine_summary.entry_count, pristine_summary.accountedEntryCount());
	try testing.expectEqual(
		pristine_summary.entry_count,
		pristine_summary.verified_entry_count + pristine_summary.directory_count,
	);
	try testing.expectEqual(@as(u32, 0), pristine_summary.damaged_entry_count);
	try testing.expectEqual(@as(u32, 0), pristine_summary.unsupported_entry_count);

	// The fixture is store-method, so every packed payload byte is covered by
	// that entry's CRC32. Classify a SET spanning each payload rather than
	// pinning one lucky offset. Five positions model sparse sniper shots while
	// keeping this unit test fast; larger guns belong in the CLI mutation gate.
	const files = pristine_archive.rar5_files orelse return error.TestUnexpectedResult;
	const mutated = try testing.allocator.alloc(u8, pristine.len);
	defer testing.allocator.free(mutated);
	var mutation_count: usize = 0;
	for (files) |f| {
		if (f.is_directory or f.unpacked_size == 0) continue;
		const range = rar5PayloadRange(pristine_archive, f) orelse return error.TestUnexpectedResult;
		const payload_len = range.end - range.start;
		const offsets = [_]usize{
			range.start,
			range.start + payload_len / 4,
			range.start + payload_len / 2,
			range.start + (payload_len * 3) / 4,
			range.end - 1,
		};
		for (offsets) |offset| {
			@memcpy(mutated, pristine);
			mutated[offset] ^= 0x01;
			const archive = rarz_open(mutated.ptr, mutated.len) orelse return error.TestUnexpectedResult;
			defer rarz_close(archive);

			var summary: RarzVerifyArchiveSummary = undefined;
			try testing.expectEqual(ARCHIVE_VERIFY_DAMAGED, rarz_verify_archive(archive, &summary));
			try testing.expectEqual(summary.entry_count, summary.accountedEntryCount());
			try testing.expectEqual(@as(u32, 1), summary.damaged_entry_count);
			mutation_count += 1;
		}
	}
	try testing.expect(mutation_count >= 15);
}

/// Archives that unrar 7.20 tests CLEAN. Every one of these was a false
/// positive — rarz reported damage on good data — found by differential sweep
/// on 2026-08-05. See tests/generate_filter_fixtures.sh for how each was
/// isolated and why the content is shaped the way it is.
const unrar_clean_corpus = [_]struct { name: []const u8, bytes: []const u8 }{
	// x86 E8/E8E9 filter. Proven causally: the same content archived with
	// `-mc-` (filters off) validated, with filters on it did not.
	.{ .name = "rar5_x86_filter", .bytes = @embedFile("rar5_x86_filter") },
	.{ .name = "rar4_x86_filter", .bytes = @embedFile("rar4_x86_filter") },
	// A file larger than RAR4's 4 MB dictionary. Boundary measured exactly:
	// 4096 KB validated, 4608 KB did not.
	.{ .name = "rar4_large_window", .bytes = @embedFile("rar4_large_window") },
	.{ .name = "rar5_large_window", .bytes = @embedFile("rar5_large_window") },
	// RAR 2.90, entry ~750 KB against a 64 KB and a 1 MB dictionary. v20 windows
	// are 64 KB-1 MB, so an ORDINARY file exceeds them — the RAR4 equivalent
	// needed 4 MB before it showed. Two defects sit behind these:
	// the same emit-once-at-the-end window overflow fixed in unpack29, and a
	// 256 KB cap rarz applied to the v20 dictionary that the reference does not
	// (arcread.cpp:268 uses one uncapped formula for every RAR4 version).
	.{ .name = "rar2_v20_md64_large", .bytes = @embedFile("rar2_v20_md64_large") },
	.{ .name = "rar2_v20_md1024_large", .bytes = @embedFile("rar2_v20_md1024_large") },
	// RAR5 with -md128k: entries ~28x (text) and ~16x (x86, exercising the
	// filter-during-streaming interaction) their dictionary window. unpack50
	// was the last decoder still holding whole entries in the window.
	.{ .name = "rar5_stream_text", .bytes = @embedFile("rar5_stream_text") },
	.{ .name = "rar5_stream_filter", .bytes = @embedFile("rar5_stream_filter") },
};

test "archives unrar tests clean are not reported damaged" {
	for (unrar_clean_corpus) |fx| {
		const archive = rarz_open(fx.bytes.ptr, fx.bytes.len) orelse {
			std.debug.print("{s}: failed to open\n", .{fx.name});
			return error.TestUnexpectedResult;
		};
		defer rarz_close(archive);

		var summary: RarzVerifyArchiveSummary = undefined;
		const status = rarz_verify_archive(archive, &summary);
		if (status != ARCHIVE_VERIFY_VERIFIED) {
			std.debug.print(
				"{s}: status={d} (damaged={d} unsupported={d} error={d}) — unrar says this archive is intact\n",
				.{ fx.name, status, summary.damaged_entry_count, summary.unsupported_entry_count, summary.error_entry_count },
			);
			return error.TestUnexpectedResult;
		}
	}
}

/// One member of the encryption classifier corpus. `encrypted` and `plain` are
/// the counts unrar itself reported when the fixture was generated, so the
/// expectations here trace back to an oracle we did not write.
const EncryptionFixture = struct {
	name: []const u8,
	bytes: []const u8,
	encrypted: u32,
	plain: u32,
};

/// The full none/mixed/all cross-product in both families. A classifier must be
/// judged over a SET: any single fixture can be passed by a stuck answer.
const encryption_corpus = [_]EncryptionFixture{
	.{ .name = "rar4 none", .bytes = @embedFile("rar4_encrypted_none"), .encrypted = 0, .plain = 2 },
	.{ .name = "rar4 mixed", .bytes = @embedFile("rar4_encrypted_mixed"), .encrypted = 2, .plain = 1 },
	.{ .name = "rar4 all", .bytes = @embedFile("rar4_encrypted_all"), .encrypted = 2, .plain = 0 },
	.{ .name = "rar5 none", .bytes = @embedFile("rar5_encrypted_none"), .encrypted = 0, .plain = 2 },
	.{ .name = "rar5 mixed", .bytes = @embedFile("rar5_encrypted_mixed"), .encrypted = 1, .plain = 1 },
	.{ .name = "rar5 all", .bytes = @embedFile("rar5_encrypted_all"), .encrypted = 2, .plain = 0 },
};

test "an intact encrypted archive is never reported damaged" {
	// unrar tests every one of these clean with the fixture password. Claiming
	// damage on data we simply cannot read condemns good archives — the worst
	// error an integrity tool can make, and strictly worse than admitting we
	// could not check. The RAR4 path had no encryption check at all, so its
	// stored ciphertext was hashed against the plaintext CRC32 in the header.
	for (encryption_corpus) |fx| {
		if (fx.encrypted == 0) continue;
		const archive = rarz_open(fx.bytes.ptr, fx.bytes.len) orelse {
			std.debug.print("{s}: failed to open\n", .{fx.name});
			return error.TestUnexpectedResult;
		};
		defer rarz_close(archive);

		var summary: RarzVerifyArchiveSummary = undefined;
		const status = rarz_verify_archive(archive, &summary);
		if (status == ARCHIVE_VERIFY_DAMAGED or summary.damaged_entry_count != 0) {
			std.debug.print(
				"{s}: intact archive reported damaged (status={d}, damaged={d})\n",
				.{ fx.name, status, summary.damaged_entry_count },
			);
			return error.TestUnexpectedResult;
		}
		try testing.expectEqual(ARCHIVE_VERIFY_INCOMPLETE, status);
	}
}

test "rarz_verify_archive separates no / mixed / wholly encrypted archives" {
	// The consumer-visible question is "why could this not be fully verified?"
	// `unsupported_entry_count` cannot answer it — a failed decode lands in the
	// same bucket as an encrypted entry. These counts make the reason a fact.
	for (encryption_corpus) |fx| {
		const archive = rarz_open(fx.bytes.ptr, fx.bytes.len) orelse {
			std.debug.print("{s}: failed to open\n", .{fx.name});
			return error.TestUnexpectedResult;
		};
		defer rarz_close(archive);

		var summary: RarzVerifyArchiveSummary = undefined;
		_ = rarz_verify_archive(archive, &summary);

		if (summary.encrypted_entry_count != fx.encrypted) {
			std.debug.print(
				"{s}: encrypted_entry_count={d}, unrar counted {d}\n",
				.{ fx.name, summary.encrypted_entry_count, fx.encrypted },
			);
			return error.TestUnexpectedResult;
		}
		// The archive-level classification the CLI and validate report on.
		const expect_mixed = fx.encrypted > 0 and fx.plain > 0;
		if (summary.hasMixedEncryption() != expect_mixed) {
			std.debug.print(
				"{s}: hasMixedEncryption={} expected {}\n",
				.{ fx.name, summary.hasMixedEncryption(), expect_mixed },
			);
			return error.TestUnexpectedResult;
		}
		// Encryption is a property, not an outcome: it must never disturb the
		// accounting invariant that proves no entry was silently skipped.
		try testing.expectEqual(summary.entry_count, summary.accountedEntryCount());
	}
}

test "rarz_verify_archive keeps mixed encryption incomplete rather than valid or damaged" {
	const mixed: []const u8 = @embedFile("rar5_encrypted_mixed");
	const archive = rarz_open(mixed.ptr, mixed.len) orelse return error.TestUnexpectedResult;
	defer rarz_close(archive);

	var summary: RarzVerifyArchiveSummary = undefined;
	try testing.expectEqual(ARCHIVE_VERIFY_INCOMPLETE, rarz_verify_archive(archive, &summary));
	try testing.expectEqual(@as(u32, 2), summary.entry_count);
	try testing.expectEqual(summary.entry_count, summary.accountedEntryCount());
	try testing.expectEqual(@as(u32, 1), summary.verified_entry_count);
	try testing.expectEqual(@as(u32, 0), summary.damaged_entry_count);
	try testing.expectEqual(@as(u32, 1), summary.unsupported_entry_count);
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
	_ = @import("decompress/sink.zig");
	_ = @import("decompress/filters.zig");
	_ = @import("decompress/unpack50.zig");
	_ = @import("decompress/ppm.zig");
	_ = @import("decompress/unpack29.zig");
	_ = @import("decompress/rarvm.zig");
	_ = @import("decompress/unpack20.zig");
	_ = @import("decompress/unpack15.zig");
	_ = @import("decompress/dispatch.zig");
	_ = @import("compress/bitwriter.zig");
	_ = @import("compress/huffman_encoder.zig");
	_ = @import("compress/slot_tables.zig");
	_ = @import("compress/match_finder.zig");
	_ = @import("compress/pack50.zig");
}
