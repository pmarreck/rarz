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
	host_os: u8 = 0, // 0=Windows, 3=Unix
	attributes: u32 = 0, // OS-specific (0 = use defaults: 0x10 dir / 0x20 file)
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

/// Write a main block with configurable archive_flags and volume_number. Returns new position.
/// archive_flags: bit 0 (0x01)=VOLUME, bit 1 (0x02)=VOLNUMBER (include volume_number vint)
/// volume_number: only encoded if VOLNUMBER bit is set in archive_flags
fn write_main_block_ex(out: []u8, pos: usize, archive_flags: u64, volume_number: u64) usize {
	var contents: [64]u8 = undefined;
	var cpos: usize = 0;

	// header_type = 1 (main)
	cpos += encode_vint(1, contents[cpos..]);
	// header_flags = 0
	cpos += encode_vint(0, contents[cpos..]);
	// archive_flags
	cpos += encode_vint(archive_flags, contents[cpos..]);
	// volume_number (only if VOLNUMBER flag is set)
	if (archive_flags & 0x02 != 0) {
		cpos += encode_vint(volume_number, contents[cpos..]);
	}

	var tmp: [128]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]);
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	const crc = integrity.crc32(tmp[0..tpos]);

	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);

	return pos + 4 + tpos;
}

/// Write a minimal main block (no volume, not solid). Returns new position.
fn write_main_block(out: []u8, pos: usize) usize {
	return write_main_block_ex(out, pos, 0, 0);
}

/// Calculate the size of the main block in bytes.
fn main_block_size() usize {
	return main_block_size_ex(0);
}

/// Calculate the size of a main block with given archive_flags.
fn main_block_size_ex(archive_flags: u64) usize {
	var contents_size: usize = vint_size(1) + vint_size(0) + vint_size(archive_flags);
	if (archive_flags & 0x02 != 0) {
		contents_size += vint_size(0); // volume_number (varies, use 0 as min)
	}
	return 4 + vint_size(contents_size) + contents_size;
}

/// Calculate exact main block size with specific volume_number.
fn main_block_size_exact(archive_flags: u64, volume_number: u64) usize {
	var contents_size: usize = vint_size(1) + vint_size(0) + vint_size(archive_flags);
	if (archive_flags & 0x02 != 0) {
		contents_size += vint_size(volume_number);
	}
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

	// Attributes: use caller-provided if non-zero, otherwise defaults
	const attributes: u64 = if (entry.attributes != 0)
		entry.attributes
	else if (entry.is_directory)
		0x10
	else
		0x20;

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
	// host_os
	bpos += encode_vint(entry.host_os, body[bpos..]);
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

	const attributes: u64 = if (entry.attributes != 0)
		entry.attributes
	else if (entry.is_directory)
		0x10
	else
		0x20;

	// Body size calculation
	var body_size: usize = 0;
	body_size += vint_size(file_flags);
	body_size += vint_size(if (entry.is_directory) 0 else entry.data.len); // unpacked_size
	body_size += vint_size(attributes);
	body_size += 4; // mtime (u32)
	if (!entry.is_directory) body_size += 4; // data_crc32 (u32)
	body_size += vint_size(0); // compression_info
	body_size += vint_size(entry.host_os); // host_os
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

/// Write a file block for volume splitting. Like write_file_block but with:
/// - split_before/split_after header flags
/// - custom data chunk (may be a subset of the file data)
/// - unpacked_size and data_crc always reflect the FULL file, not the chunk
/// compression_info=0 (store mode).
fn write_file_block_split(
	out: []u8,
	pos: usize,
	entry: FileEntry,
	data_chunk: []const u8,
	split_before: bool,
	split_after: bool,
) usize {
	const full_data_crc = integrity.crc32(entry.data);

	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01;
	file_flags |= 0x02; // FHFL_UTIME
	if (!entry.is_directory) file_flags |= 0x04; // FHFL_CRC32

	const attributes: u64 = if (entry.attributes != 0)
		entry.attributes
	else if (entry.is_directory)
		0x10
	else
		0x20;

	var body: [4096]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(file_flags, body[bpos..]);
	bpos += encode_vint(if (entry.is_directory) 0 else entry.data.len, body[bpos..]); // full unpacked_size
	bpos += encode_vint(attributes, body[bpos..]);
	std.mem.writeInt(u32, body[bpos..][0..4], entry.mtime, .little);
	bpos += 4;
	if (!entry.is_directory) {
		std.mem.writeInt(u32, body[bpos..][0..4], full_data_crc, .little);
		bpos += 4;
	}
	bpos += encode_vint(0, body[bpos..]); // compression_info = store
	bpos += encode_vint(entry.host_os, body[bpos..]);
	bpos += encode_vint(entry.name.len, body[bpos..]);
	@memcpy(body[bpos..][0..entry.name.len], entry.name);
	bpos += entry.name.len;

	const chunk_size: u64 = data_chunk.len;
	// Header flags: HFL_DATA(0x02), HFL_SPLIT_BEFORE(0x08), HFL_SPLIT_AFTER(0x10)
	var header_flags: u64 = 0;
	if (chunk_size > 0) header_flags |= 0x02;
	if (split_before) header_flags |= 0x08;
	if (split_after) header_flags |= 0x10;

	var contents: [4096]u8 = undefined;
	var cpos: usize = 0;
	cpos += encode_vint(2, contents[cpos..]); // type = file
	cpos += encode_vint(header_flags, contents[cpos..]);
	if (chunk_size > 0) {
		cpos += encode_vint(chunk_size, contents[cpos..]);
	}
	@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
	cpos += bpos;

	var tmp: [8192]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]);
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	const crc = integrity.crc32(tmp[0..tpos]);

	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);
	var new_pos = pos + 4 + tpos;

	if (chunk_size > 0) {
		@memcpy(out[new_pos..][0..data_chunk.len], data_chunk);
		new_pos += data_chunk.len;
	}

	return new_pos;
}

/// Calculate the header-only size for a split file block (without data).
fn file_block_header_size(entry: FileEntry, chunk_size: u64, split_before: bool, split_after: bool) usize {
	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01;
	file_flags |= 0x02;
	if (!entry.is_directory) file_flags |= 0x04;

	const attributes: u64 = if (entry.attributes != 0)
		entry.attributes
	else if (entry.is_directory)
		0x10
	else
		0x20;

	var body_size: usize = 0;
	body_size += vint_size(file_flags);
	body_size += vint_size(if (entry.is_directory) 0 else entry.data.len);
	body_size += vint_size(attributes);
	body_size += 4; // mtime
	if (!entry.is_directory) body_size += 4; // data_crc32
	body_size += vint_size(0); // compression_info
	body_size += vint_size(entry.host_os);
	body_size += vint_size(entry.name.len);
	body_size += entry.name.len;

	var header_flags: u64 = 0;
	if (chunk_size > 0) header_flags |= 0x02;
	if (split_before) header_flags |= 0x08;
	if (split_after) header_flags |= 0x10;

	var contents_size: usize = 0;
	contents_size += vint_size(2); // type
	contents_size += vint_size(header_flags);
	if (chunk_size > 0) {
		contents_size += vint_size(chunk_size);
	}
	contents_size += body_size;

	return 4 + vint_size(contents_size) + contents_size;
}

/// Write a compressed file block for volume splitting.
fn write_file_block_precompressed_split(
	out: []u8,
	pos: usize,
	entry: FileEntry,
	compressed_chunk: []const u8,
	full_compressed_size: u64,
	method: u3,
	split_before: bool,
	split_after: bool,
) usize {
	const data_crc = integrity.crc32(entry.data);

	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01;
	file_flags |= 0x02;
	if (!entry.is_directory) file_flags |= 0x04;

	const attributes: u64 = if (entry.attributes != 0)
		entry.attributes
	else if (entry.is_directory)
		0x10
	else
		0x20;
	const dict_bits: u4 = 3;

	var body: [4096]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(file_flags, body[bpos..]);
	bpos += encode_vint(entry.data.len, body[bpos..]);
	bpos += encode_vint(attributes, body[bpos..]);
	std.mem.writeInt(u32, body[bpos..][0..4], entry.mtime, .little);
	bpos += 4;
	if (!entry.is_directory) {
		std.mem.writeInt(u32, body[bpos..][0..4], data_crc, .little);
		bpos += 4;
	}
	bpos += encode_vint(encode_compression_info(method, dict_bits), body[bpos..]);
	bpos += encode_vint(entry.host_os, body[bpos..]);
	bpos += encode_vint(entry.name.len, body[bpos..]);
	@memcpy(body[bpos..][0..entry.name.len], entry.name);
	bpos += entry.name.len;

	const chunk_size: u64 = compressed_chunk.len;
	var header_flags: u64 = 0;
	if (chunk_size > 0) header_flags |= 0x02;
	if (split_before) header_flags |= 0x08;
	if (split_after) header_flags |= 0x10;

	var contents: [4096]u8 = undefined;
	var cpos: usize = 0;
	cpos += encode_vint(2, contents[cpos..]);
	cpos += encode_vint(header_flags, contents[cpos..]);
	if (chunk_size > 0) {
		cpos += encode_vint(chunk_size, contents[cpos..]);
	}
	@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
	cpos += bpos;

	var tmp: [8192]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]);
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	const crc = integrity.crc32(tmp[0..tpos]);

	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);
	var new_pos = pos + 4 + tpos;

	if (chunk_size > 0) {
		@memcpy(out[new_pos..][0..compressed_chunk.len], compressed_chunk);
		new_pos += compressed_chunk.len;
	}

	_ = full_compressed_size;
	return new_pos;
}

/// Calculate header-only size for a compressed split file block.
fn file_block_header_size_compressed(entry: FileEntry, chunk_size: u64, method: u3, split_before: bool, split_after: bool) usize {
	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01;
	file_flags |= 0x02;
	if (!entry.is_directory) file_flags |= 0x04;

	const attributes: u64 = if (entry.attributes != 0)
		entry.attributes
	else if (entry.is_directory)
		0x10
	else
		0x20;
	const dict_bits: u4 = 3;

	var body_size: usize = 0;
	body_size += vint_size(file_flags);
	body_size += vint_size(entry.data.len);
	body_size += vint_size(attributes);
	body_size += 4;
	if (!entry.is_directory) body_size += 4;
	body_size += vint_size(encode_compression_info(method, dict_bits));
	body_size += vint_size(entry.host_os);
	body_size += vint_size(entry.name.len);
	body_size += entry.name.len;

	var header_flags: u64 = 0;
	if (chunk_size > 0) header_flags |= 0x02;
	if (split_before) header_flags |= 0x08;
	if (split_after) header_flags |= 0x10;

	var contents_size: usize = 0;
	contents_size += vint_size(2);
	contents_size += vint_size(header_flags);
	if (chunk_size > 0) {
		contents_size += vint_size(chunk_size);
	}
	contents_size += body_size;

	return 4 + vint_size(contents_size) + contents_size;
}

/// Write end-of-archive block with configurable end_flags. Returns new position.
/// end_flags: bit 0 (0x01) = next_volume (more volumes follow)
fn write_end_block_ex(out: []u8, pos: usize, end_flags: u64) usize {
	var contents: [32]u8 = undefined;
	var cpos: usize = 0;

	// header_type = 5 (end_archive)
	cpos += encode_vint(5, contents[cpos..]);
	// header_flags = 0
	cpos += encode_vint(0, contents[cpos..]);
	// end_flags
	cpos += encode_vint(end_flags, contents[cpos..]);

	var tmp: [64]u8 = undefined;
	var tpos: usize = 0;
	tpos += encode_vint(cpos, tmp[tpos..]);
	@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
	tpos += cpos;

	const crc = integrity.crc32(tmp[0..tpos]);

	std.mem.writeInt(u32, out[pos..][0..4], crc, .little);
	@memcpy(out[pos + 4 ..][0..tpos], tmp[0..tpos]);

	return pos + 4 + tpos;
}

/// Write end-of-archive block (no next volume). Returns new position.
fn write_end_block(out: []u8, pos: usize) usize {
	return write_end_block_ex(out, pos, 0);
}

/// Calculate the size of the end block.
fn end_block_size() usize {
	return end_block_size_ex(0);
}

/// Calculate the size of an end block with given end_flags.
fn end_block_size_ex(end_flags: u64) usize {
	const contents_size: usize = vint_size(5) + vint_size(0) + vint_size(end_flags);
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

/// Write a compressed file block using pre-compressed data. Returns new position.
fn write_file_block_precompressed(
	out: []u8,
	pos: usize,
	entry: FileEntry,
	compressed_data: []const u8,
	method: u3,
) usize {
	const data_crc = integrity.crc32(entry.data);

	// File flags: FHFL_UTIME | FHFL_CRC32
	var file_flags: u64 = 0;
	if (entry.is_directory) file_flags |= 0x01;
	file_flags |= 0x02; // FHFL_UTIME
	if (!entry.is_directory) file_flags |= 0x04; // FHFL_CRC32

	const attributes: u64 = if (entry.attributes != 0)
		entry.attributes
	else if (entry.is_directory)
		0x10
	else
		0x20;
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
	// host_os
	bpos += encode_vint(entry.host_os, body[bpos..]);
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

/// Result of a parallel compression worker thread.
const CompressResult = struct {
	data: ?[]u8 = null,
	failed: bool = false,
};

/// Worker function for parallel compression. Each thread compresses one file
/// using page_allocator (thread-safe, no shared state).
fn compressWorker(file_data: []const u8, method: u3, result: *CompressResult) void {
	const alloc = std.heap.page_allocator;
	result.data = pack50.compressBlock(alloc, file_data, method, true) catch {
		result.failed = true;
		return;
	};
}

/// Write a complete RAR5 archive with compression to the output buffer.
/// method: 0=store, 1-5=compression levels.
/// For method 0, delegates to write_archive.
/// Returns the number of bytes written.
///
/// Files are compressed in parallel using OS threads. Each file gets its own
/// thread, and results are assembled sequentially. For a single compressible
/// file, compression happens inline (no thread overhead).
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

	// Count compressible entries (non-directory, non-empty)
	var compressible_count: usize = 0;
	for (entries) |entry| {
		if (!entry.is_directory and entry.data.len > 0) compressible_count += 1;
	}

	// Allocate per-entry compression results and thread handles
	const results = try allocator.alloc(CompressResult, entries.len);
	defer allocator.free(results);
	@memset(results, CompressResult{});

	// Compress all files in parallel (if 2+ compressible entries)
	if (compressible_count >= 2) {
		const threads = try allocator.alloc(?std.Thread, entries.len);
		defer allocator.free(threads);

		// Spawn compression threads
		for (entries, 0..) |entry, i| {
			if (!entry.is_directory and entry.data.len > 0) {
				threads[i] = std.Thread.spawn(.{}, compressWorker, .{
					entry.data,
					method,
					&results[i],
				}) catch blk: {
					// Thread spawn failed — fall back to inline compression
					results[i].data = pack50.compressBlock(
						std.heap.page_allocator,
						entry.data,
						method,
						true,
					) catch {
						results[i].failed = true;
						break :blk null;
					};
					break :blk null;
				};
			} else {
				threads[i] = null;
			}
		}

		// Join all threads
		for (threads) |t| {
			if (t) |thread| thread.join();
		}
	} else {
		// Single file or no compressible files: compress inline (no thread overhead)
		for (entries, 0..) |entry, i| {
			if (!entry.is_directory and entry.data.len > 0) {
				results[i].data = pack50.compressBlock(
					allocator,
					entry.data,
					method,
					true,
				) catch {
					results[i].failed = true;
					continue;
				};
			}
		}
	}

	// Check for compression failures
	defer {
		// Free all compressed data
		for (results, 0..) |r, i| {
			if (r.data) |d| {
				if (compressible_count >= 2) {
					std.heap.page_allocator.free(d);
				} else {
					_ = i;
					allocator.free(d);
				}
			}
		}
	}
	for (results) |r| {
		if (r.failed) return error.CompressionFailed;
	}

	// Write archive sequentially using pre-compressed data
	var pos: usize = 0;

	// Signature
	pos = write_signature(output, pos);

	// Main block
	pos = write_main_block(output, pos);

	// File blocks
	for (entries, 0..) |entry, i| {
		if (entry.is_directory or entry.data.len == 0) {
			pos = write_file_block(output, pos, entry);
		} else {
			pos = write_file_block_precompressed(
				output,
				pos,
				entry,
				results[i].data.?,
				method,
			);
		}
	}

	// End block
	pos = write_end_block(output, pos);

	return pos;
}

// ============================================================================
// Volume creation API
// ============================================================================

pub const VolumeConfig = struct {
	volume_size: u64, // max bytes per volume
};

pub const VolumeResult = struct {
	volumes: [][]u8,
	count: usize,
	allocator: std.mem.Allocator,

	pub fn deinit(self: *VolumeResult) void {
		for (self.volumes[0..self.count]) |vol| {
			self.allocator.free(vol);
		}
		self.allocator.free(self.volumes);
	}
};

/// Per-file data to distribute across volumes (after optional compression).
const FilePayload = struct {
	entry: FileEntry,
	data: []const u8, // actual data to write (raw or compressed)
	method: u3,
	is_compressed: bool,
};

/// Write volume archives from pre-prepared file payloads.
/// Each volume gets: signature + main block (VOLUME+VOLNUMBER) + file blocks + end block.
/// Files that don't fit in the current volume are split across volumes.
fn write_volumes_from_payloads(
	allocator: std.mem.Allocator,
	payloads: []const FilePayload,
	config: VolumeConfig,
) !VolumeResult {
	// Volume flags for multi-volume archives
	const VOLUME_FLAG: u64 = 0x01;
	const VOLNUMBER_FLAG: u64 = 0x02;
	const archive_flags = VOLUME_FLAG | VOLNUMBER_FLAG;
	const END_NEXT_VOLUME: u64 = 0x01;

	// Estimate max volumes (generous upper bound)
	var total_data_size: usize = 0;
	for (payloads) |p| {
		total_data_size += p.data.len + 256; // data + header overhead
	}
	const estimated_volumes = (total_data_size / @as(usize, @intCast(config.volume_size))) + 2;
	const max_volumes = @max(estimated_volumes, 4);

	// Allocate volume buffer pointers
	var vol_list = try allocator.alloc([]u8, max_volumes);
	var vol_count: usize = 0;
	errdefer {
		for (vol_list[0..vol_count]) |vol| allocator.free(vol);
		allocator.free(vol_list);
	}

	// Track progress through files
	var file_idx: usize = 0;
	var data_offset: usize = 0; // how far into current file's data we've written

	while (file_idx < payloads.len or vol_count == 0) {
		// Start a new volume
		const vol_num = vol_count;
		const vol_buf_size = @as(usize, @intCast(config.volume_size)) + 65536; // extra for header overhead
		var vol_buf = try allocator.alloc(u8, vol_buf_size);
		// Per-iteration ownership: this errdefer is scoped to the loop body, so it
		// fires only if THIS iteration errors out (e.g. the vol_list growth or
		// final_buf allocation below fails). On the success path vol_buf is freed
		// explicitly before the iteration ends, discharging the errdefer.
		errdefer allocator.free(vol_buf);

		var pos: usize = 0;
		pos = write_signature(vol_buf, pos);
		pos = write_main_block_ex(vol_buf, pos, archive_flags, vol_num);

		const overhead = detect.RAR50_SIG.len + main_block_size_exact(archive_flags, vol_num) + end_block_size_ex(END_NEXT_VOLUME);
		const usable = if (config.volume_size > overhead) config.volume_size - overhead else 256;

		var written_in_vol: u64 = 0;
		while (file_idx < payloads.len) {
			const p = payloads[file_idx];
			const remaining_data = p.data[data_offset..];
			const is_continuation = data_offset > 0;

			// Calculate header size for this chunk
			const trial_header_size = if (p.is_compressed)
				file_block_header_size_compressed(p.entry, remaining_data.len, p.method, is_continuation, false)
			else
				file_block_header_size(p.entry, remaining_data.len, is_continuation, false);

			const full_block_size = trial_header_size + remaining_data.len;

			if (written_in_vol + full_block_size <= usable) {
				// Whole file (or remainder) fits in this volume
				if (p.is_compressed) {
					pos = write_file_block_precompressed_split(
						vol_buf, pos, p.entry, remaining_data,
						p.data.len, p.method, is_continuation, false,
					);
				} else {
					pos = write_file_block_split(
						vol_buf, pos, p.entry, remaining_data,
						is_continuation, false,
					);
				}
				written_in_vol += full_block_size;
				file_idx += 1;
				data_offset = 0;
			} else {
				// Need to split the file
				// Calculate how much data we can fit
				const header_for_split = if (p.is_compressed)
					file_block_header_size_compressed(p.entry, 1, p.method, is_continuation, true)
				else
					file_block_header_size(p.entry, 1, is_continuation, true);

				if (written_in_vol + header_for_split >= usable) {
					// Can't fit even a header — end this volume
					break;
				}

				// Chunk size = remaining usable space - header overhead
				// We need to iterate because vint_size changes with chunk_size
				var chunk_size = usable - written_in_vol - header_for_split;
				if (chunk_size > remaining_data.len) chunk_size = remaining_data.len;

				// Refine: recalculate header with actual chunk_size
				const actual_header = if (p.is_compressed)
					file_block_header_size_compressed(p.entry, chunk_size, p.method, is_continuation, true)
				else
					file_block_header_size(p.entry, chunk_size, is_continuation, true);

				if (actual_header + chunk_size > usable - written_in_vol) {
					if (chunk_size > 1) {
						chunk_size -= 1; // vint size grew, trim a byte
					}
				}

				if (chunk_size == 0) break;

				const chunk_data = remaining_data[0..@as(usize, @intCast(chunk_size))];
				if (p.is_compressed) {
					pos = write_file_block_precompressed_split(
						vol_buf, pos, p.entry, chunk_data,
						p.data.len, p.method, is_continuation, true,
					);
				} else {
					pos = write_file_block_split(
						vol_buf, pos, p.entry, chunk_data,
						is_continuation, true,
					);
				}
				data_offset += @as(usize, @intCast(chunk_size));
				break; // End this volume, continue file in next
			}
		}

		// Write end block
		const is_last = (file_idx >= payloads.len);
		const end_flags: u64 = if (is_last) 0 else END_NEXT_VOLUME;
		pos = write_end_block_ex(vol_buf, pos, end_flags);

		// Shrink volume to actual size
		if (vol_count >= vol_list.len) {
			// Grow vol_list
			const new_list = try allocator.alloc([]u8, vol_list.len * 2);
			@memcpy(new_list[0..vol_count], vol_list[0..vol_count]);
			allocator.free(vol_list);
			vol_list = new_list;
		}

		const final_buf = try allocator.alloc(u8, pos);
		@memcpy(final_buf, vol_buf[0..pos]);
		allocator.free(vol_buf);

		vol_list[vol_count] = final_buf;
		vol_count += 1;

		if (is_last) break;
	}

	return VolumeResult{
		.volumes = vol_list,
		.count = vol_count,
		.allocator = allocator,
	};
}

/// Write store-mode volume archives.
pub fn write_archive_volumes(
	allocator: std.mem.Allocator,
	entries: []const FileEntry,
	config: VolumeConfig,
) !VolumeResult {
	// Build payloads (no compression)
	const payloads = try allocator.alloc(FilePayload, entries.len);
	defer allocator.free(payloads);

	for (entries, 0..) |entry, i| {
		payloads[i] = .{
			.entry = entry,
			.data = if (entry.is_directory) "" else entry.data,
			.method = 0,
			.is_compressed = false,
		};
	}

	return write_volumes_from_payloads(allocator, payloads, config);
}

/// Write compressed volume archives. Files are compressed first (in parallel),
/// then distributed across volumes.
pub fn write_archive_volumes_compressed(
	allocator: std.mem.Allocator,
	entries: []const FileEntry,
	config: VolumeConfig,
	method: u3,
) !VolumeResult {
	if (method == 0) {
		return write_archive_volumes(allocator, entries, config);
	}

	// Compress all files first (reuse parallel compression logic)
	var compressible_count: usize = 0;
	for (entries) |entry| {
		if (!entry.is_directory and entry.data.len > 0) compressible_count += 1;
	}

	const results = try allocator.alloc(CompressResult, entries.len);
	defer allocator.free(results);
	@memset(results, CompressResult{});

	if (compressible_count >= 2) {
		const threads = try allocator.alloc(?std.Thread, entries.len);
		defer allocator.free(threads);

		for (entries, 0..) |entry, i| {
			if (!entry.is_directory and entry.data.len > 0) {
				threads[i] = std.Thread.spawn(.{}, compressWorker, .{
					entry.data, method, &results[i],
				}) catch blk: {
					results[i].data = pack50.compressBlock(
						std.heap.page_allocator, entry.data, method, true,
					) catch {
						results[i].failed = true;
						break :blk null;
					};
					break :blk null;
				};
			} else {
				threads[i] = null;
			}
		}

		for (threads) |t| {
			if (t) |thread| thread.join();
		}
	} else {
		for (entries, 0..) |entry, i| {
			if (!entry.is_directory and entry.data.len > 0) {
				results[i].data = pack50.compressBlock(
					allocator, entry.data, method, true,
				) catch {
					results[i].failed = true;
					continue;
				};
			}
		}
	}

	defer {
		for (results) |r| {
			if (r.data) |d| {
				if (compressible_count >= 2) {
					std.heap.page_allocator.free(d);
				} else {
					allocator.free(d);
				}
			}
		}
	}

	for (results) |r| {
		if (r.failed) return error.CompressionFailed;
	}

	// Build payloads with compressed data
	const payloads = try allocator.alloc(FilePayload, entries.len);
	defer allocator.free(payloads);

	for (entries, 0..) |entry, i| {
		if (entry.is_directory or entry.data.len == 0) {
			payloads[i] = .{
				.entry = entry,
				.data = if (entry.is_directory) "" else entry.data,
				.method = 0,
				.is_compressed = false,
			};
		} else {
			payloads[i] = .{
				.entry = entry,
				.data = results[i].data.?,
				.method = method,
				.is_compressed = true,
			};
		}
	}

	return write_volumes_from_payloads(allocator, payloads, config);
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
	try testing.expectEqual(@as(u8, 50), parsed.algo_version);
	try testing.expectEqual(@as(u3, 3), parsed.method);
	try testing.expectEqual(@as(u5, 3), parsed.dict_bits);
	try testing.expect(!parsed.solid);
}

// ============================================================================
// Volume creation tests
// ============================================================================

test "write_archive_volumes: single volume when data fits" {
	const entries = [_]FileEntry{.{
		.name = "small.txt",
		.data = "hello",
		.mtime = 0,
		.is_directory = false,
	}};

	var result = try write_archive_volumes(testing.allocator, &entries, .{ .volume_size = 4096 });
	defer result.deinit();

	// Should produce exactly 1 volume
	try testing.expectEqual(@as(usize, 1), result.count);

	// The single volume should be a valid RAR5 archive
	const vol = result.volumes[0];
	try testing.expectEqualSlices(u8, &detect.RAR50_SIG, vol[0..8]);

	// Parse and verify
	const block_data = vol[detect.RAR50_SIG.len..];
	var iter = rar5_headers.walk_blocks(block_data);

	// Main block should have VOLUME flag
	const b1 = (try iter.next()) orelse return error.EndOfData;
	switch (b1) {
		.main => |m| {
			try testing.expect(m.volume);
		},
		else => return error.EndOfData,
	}

	// File block
	const b2 = (try iter.next()) orelse return error.EndOfData;
	switch (b2) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "small.txt", f.name);
			try testing.expectEqual(@as(u64, 5), f.unpacked_size);
		},
		else => return error.EndOfData,
	}

	// End block (no next volume)
	const b3 = (try iter.next()) orelse return error.EndOfData;
	switch (b3) {
		.end_archive => |e| {
			try testing.expect(!e.next_volume);
		},
		else => return error.EndOfData,
	}
}

test "write_archive_volumes: two volumes split between files" {
	// Create two files. Set volume_size small enough that both can't fit in one volume.
	// File block: ~35 bytes header + data. Volume overhead: sig(8) + main(~12) + end(~8) = ~28
	const data_a = "alpha alpha alpha alpha alpha alpha"; // 35 bytes
	const data_b = "bravo bravo bravo bravo bravo bravo"; // 35 bytes
	const entries = [_]FileEntry{
		.{ .name = "a.txt", .data = data_a, .mtime = 0, .is_directory = false },
		.{ .name = "b.txt", .data = data_b, .mtime = 0, .is_directory = false },
	};

	// One file block = ~35 header + 35 data = ~70 bytes.
	// Volume overhead = ~28. So volume_size=100 fits one file but not two.
	var result = try write_archive_volumes(testing.allocator, &entries, .{ .volume_size = 105 });
	defer result.deinit();

	// Should produce 2 or more volumes
	try testing.expect(result.count >= 2);

	// First volume should have end block with next_volume flag
	const vol1 = result.volumes[0];
	const bd1 = vol1[detect.RAR50_SIG.len..];
	var iter1 = rar5_headers.walk_blocks(bd1);
	_ = try iter1.next(); // main
	_ = try iter1.next(); // file

	// Walk to end block
	var found_end = false;
	while (try iter1.next()) |block| {
		switch (block) {
			.end_archive => |e| {
				try testing.expect(e.next_volume);
				found_end = true;
			},
			else => {},
		}
	}
	try testing.expect(found_end);

	// Last volume should have end block without next_volume flag
	const last_vol = result.volumes[result.count - 1];
	const bdl = last_vol[detect.RAR50_SIG.len..];
	var iter_l = rar5_headers.walk_blocks(bdl);

	var last_end_found = false;
	while (try iter_l.next()) |block| {
		switch (block) {
			.end_archive => |e| {
				try testing.expect(!e.next_volume);
				last_end_found = true;
			},
			else => {},
		}
	}
	try testing.expect(last_end_found);
}

test "write_archive_volumes: file split across volumes" {
	// One large file that must be split
	const big_data = "x" ** 200;
	const entries = [_]FileEntry{.{
		.name = "big.txt",
		.data = big_data,
		.mtime = 0,
		.is_directory = false,
	}};

	// Volume size small enough to force a split (overhead ~50 bytes, so ~100 for data)
	var result = try write_archive_volumes(testing.allocator, &entries, .{ .volume_size = 160 });
	defer result.deinit();

	try testing.expect(result.count >= 2);

	// Check first volume: file should have split_after
	const vol1 = result.volumes[0];
	const bd1 = vol1[detect.RAR50_SIG.len..];
	var iter1 = rar5_headers.walk_blocks(bd1);
	_ = try iter1.next(); // main
	const fb1 = (try iter1.next()) orelse return error.EndOfData;
	switch (fb1) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "big.txt", f.name);
			try testing.expect(!f.header.flags.split_before);
			try testing.expect(f.header.flags.split_after);
		},
		else => return error.EndOfData,
	}

	// Check second volume: file should have split_before
	const vol2 = result.volumes[1];
	const bd2 = vol2[detect.RAR50_SIG.len..];
	var iter2 = rar5_headers.walk_blocks(bd2);
	_ = try iter2.next(); // main
	const fb2 = (try iter2.next()) orelse return error.EndOfData;
	switch (fb2) {
		.file => |f| {
			try testing.expectEqualSlices(u8, "big.txt", f.name);
			try testing.expect(f.header.flags.split_before);
		},
		else => return error.EndOfData,
	}
}

test "write_archive_volumes: volume numbers increment" {
	const entries = [_]FileEntry{
		.{ .name = "a.txt", .data = "aaaa aaaa aaaa", .mtime = 0, .is_directory = false },
		.{ .name = "b.txt", .data = "bbbb bbbb bbbb", .mtime = 0, .is_directory = false },
		.{ .name = "c.txt", .data = "cccc cccc cccc", .mtime = 0, .is_directory = false },
	};

	var result = try write_archive_volumes(testing.allocator, &entries, .{ .volume_size = 110 });
	defer result.deinit();

	try testing.expect(result.count >= 2);

	// Check volume numbers
	for (result.volumes[0..result.count], 0..) |vol, expected_num| {
		const bd = vol[detect.RAR50_SIG.len..];
		var iter = rar5_headers.walk_blocks(bd);
		const mb = (try iter.next()) orelse return error.EndOfData;
		switch (mb) {
			.main => |m| {
				try testing.expect(m.volume);
				if (m.volume_number) |vn| {
					try testing.expectEqual(@as(u64, expected_num), vn);
				}
			},
			else => return error.EndOfData,
		}
	}
}

test "write_archive_volumes: round-trip reassemble data from chunks" {
	const file_data = "The quick brown fox jumps over the lazy dog. " ** 3;
	const entries = [_]FileEntry{.{
		.name = "fox.txt",
		.data = file_data,
		.mtime = 0x5A000000,
		.is_directory = false,
	}};

	// Force splitting into multiple volumes
	var result = try write_archive_volumes(testing.allocator, &entries, .{ .volume_size = 130 });
	defer result.deinit();

	try testing.expect(result.count >= 2);

	// Reassemble the file data from all volume chunks
	var reassembled: [file_data.len]u8 = undefined;
	var reassembled_len: usize = 0;

	for (result.volumes[0..result.count]) |vol| {
		const bd = vol[detect.RAR50_SIG.len..];
		var iter = rar5_headers.walk_blocks(bd);

		while (try iter.next()) |block| {
			switch (block) {
				.file => |f| {
					try testing.expectEqualSlices(u8, "fox.txt", f.name);
					try testing.expectEqual(@as(u64, file_data.len), f.unpacked_size);

					// Extract the data chunk from this volume
					const total_header = 4 + f.header.crc_data_len;
					const payload_start = f.header.header_start + total_header;
					if (f.header.data_size) |ds| {
						const chunk_len = @as(usize, @intCast(ds));
						const chunk = bd[payload_start .. payload_start + chunk_len];
						@memcpy(reassembled[reassembled_len..][0..chunk_len], chunk);
						reassembled_len += chunk_len;
					}
				},
				else => {},
			}
		}
	}

	// Reassembled data should match original
	try testing.expectEqual(file_data.len, reassembled_len);
	try testing.expectEqualSlices(u8, file_data, reassembled[0..reassembled_len]);
}

test "write_volumes_from_payloads: no leak when allocation fails mid-iteration" {
	// Two files, small volume size => multivolume loop runs several iterations,
	// each allocating a per-iteration `vol_buf` plus a shrink-to-fit `final_buf`.
	// checkAllAllocationFailures injects an OOM at every allocation index; if the
	// error path forgets to free `vol_buf`, it is reported as a leak.
	const data_a = "alpha alpha alpha alpha alpha alpha";
	const data_b = "bravo bravo bravo bravo bravo bravo";
	const payloads = [_]FilePayload{
		.{ .entry = .{ .name = "a.txt", .data = data_a, .mtime = 0, .is_directory = false }, .data = data_a, .method = 0, .is_compressed = false },
		.{ .entry = .{ .name = "b.txt", .data = data_b, .mtime = 0, .is_directory = false }, .data = data_b, .method = 0, .is_compressed = false },
	};
	const config = VolumeConfig{ .volume_size = 105 };

	const Helper = struct {
		fn run(alloc: std.mem.Allocator, p: []const FilePayload, cfg: VolumeConfig) !void {
			var result = try write_volumes_from_payloads(alloc, p, cfg);
			result.deinit();
		}
	};

	try testing.checkAllAllocationFailures(testing.allocator, Helper.run, .{ &payloads, config });
}

test "write_archive_compressed: MULTI-file round-trip (parallel compression path)" {
	// Regression: every other compressed-writer test uses a SINGLE entry, which
	// takes the inline-compression branch. With 2+ compressible entries
	// write_archive_compressed switches to the threaded path
	// (`compressible_count >= 2`), and that path was emitting files with
	// packed_size == 0 — producing archives that unrar rejects with "checksum
	// error" and that rarz itself cannot extract ("file has no data size").
	const f1 = "The quick brown fox jumps over the lazy dog. The quick brown fox!";
	const f2 = "Pack my box with five dozen liquor jugs. Pack my box with jugs!";
	const entries = [_]FileEntry{
		.{ .name = "one.txt", .data = f1, .mtime = 0x5C000000, .is_directory = false },
		.{ .name = "two.txt", .data = f2, .mtime = 0x5C000000, .is_directory = false },
	};

	var buf: [16384]u8 = undefined;
	const archive_len = try write_archive_compressed(testing.allocator, &entries, &buf, 3);

	const format = detect.detect_format(buf[0..archive_len], 0);
	const block_data = buf[format.signature_offset + format.signature_len .. archive_len];
	var iter = rar5_headers.walk_blocks(block_data);
	_ = try iter.next(); // main

	const expected = [_][]const u8{ f1, f2 };
	for (expected) |want| {
		const block = (try iter.next()) orelse return error.EndOfData;
		switch (block) {
			.file => |f| {
				const total_header = 4 + f.header.crc_data_len;
				const payload_start = f.header.header_start + total_header;
				const ds = f.header.data_size orelse return error.EndOfData;
				// The actual defect: a compressed entry must carry real packed bytes.
				try testing.expect(ds > 0);
				const packed_data = block_data[payload_start .. payload_start + @as(usize, @intCast(ds))];

				const dispatch = @import("decompress/dispatch.zig");
				const decompressed = try dispatch.decompressRar5(
					testing.allocator,
					packed_data,
					f.unpacked_size,
					f.compression,
				);
				defer testing.allocator.free(decompressed);
				try testing.expectEqualSlices(u8, want, decompressed);
			},
			else => return error.EndOfData,
		}
	}
}


test "policy.validate: a compressed entry with packed_size==0 must NOT be VALID" {
	// PRECISION OVER FORGIVENESS (Mecha Validate trust signal).
	//
	// A file header can claim unpacked_size > 0 AND carry a stored CRC32 while
	// declaring packed_size == 0. That archive is malformed: there are no bytes
	// to decompress, so the stored checksum can never be corroborated. rarz used
	// to report such an archive as VALID, because a zero-length payload made the
	// verifier skip the CRC check entirely — "nothing to check" was treated as
	// "nothing wrong".
	//
	// This is the exact shape the C-hosted Thread.spawn UB emitted (every file
	// written with packed_size == 0), and rarz blessed its own corrupt output
	// while unrar reported "checksum error". Being unable to verify must be a
	// FAILURE, never a pass.
	const payload = "x" ** 100;
	const entry = FileEntry{
		.name = "claims-data.txt",
		.data = payload, // unpacked_size = 100, and a CRC32 is stored
		.mtime = 0x5C000000,
		.is_directory = false,
	};

	var buf: [4096]u8 = undefined;
	var pos: usize = 0;
	pos = write_signature(&buf, pos);
	pos = write_main_block(&buf, pos);
	// Deliberately write ZERO compressed bytes for a 100-byte file.
	pos = write_file_block_precompressed(&buf, pos, entry, &[_]u8{}, 3);
	pos = write_end_block(&buf, pos);

	const result = policy.validate(buf[0..pos]);
	try testing.expect(!result.is_valid);
}

test "policy.validate: truncated archive must NOT be VALID" {
	// PRECISION: unrar reports "Unexpected end of archive" on a truncated RAR5;
	// rarz reported VALID because the block walk swallowed the parse error
	// (`iter.next() catch break`), so losing the tail of an archive silently
	// ended validation early and everything seen so far was blessed.
	const entry = FileEntry{
		.name = "payload.txt",
		.data = "the quick brown fox jumps over the lazy dog" ** 4,
		.mtime = 0x5C000000,
		.is_directory = false,
	};
	var buf: [4096]u8 = undefined;
	const full_len = try write_archive(&[_]FileEntry{entry}, &buf);

	// Sanity: the intact archive is valid.
	try testing.expect(policy.validate(buf[0..full_len]).is_valid);

	// Cut into the trailing blocks. Every proper truncation must be rejected.
	var cut: usize = 1;
	while (cut <= 12) : (cut += 1) {
		const r = policy.validate(buf[0 .. full_len - cut]);
		if (r.is_valid) {
			std.debug.print("truncating {d} byte(s) still reported VALID\n", .{cut});
			return error.TruncatedArchiveReportedValid;
		}
	}
}
