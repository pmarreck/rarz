//! RAR5+ header/block parser.
//!
//! Parses the block-level structure of RAR5 archives: MAIN, FILE, SERVICE,
//! CRYPT, and END_ARCHIVE blocks. Validates header CRC32 and provides an
//! iterator for walking all blocks in an archive.

const std = @import("std");
const reader_mod = @import("reader.zig");
const integrity = @import("integrity.zig");
const testing = std.testing;

// ============================================================================
// Types
// ============================================================================

pub const BlockType = enum(u7) {
	main = 1,
	file = 2,
	service = 3,
	crypt = 4,
	end_archive = 5,
	_,
};

pub const HeaderFlags = struct {
	extra: bool,
	data: bool,
	skip_if_unknown: bool,
	split_before: bool,
	split_after: bool,
	child: bool,
	inherited: bool,
	raw: u64,
};

pub const BlockHeader = struct {
	header_crc: u32,
	header_size: u64,
	header_start: usize, // offset where CRC32 begins in archive
	body_start: usize, // offset where type-specific body begins
	crc_data_len: usize, // bytes covered by CRC (header_size_vint + header_size)
	block_type: BlockType,
	flags: HeaderFlags,
	extra_size: ?u64,
	data_size: ?u64,
};

pub const MainBlock = struct {
	header: BlockHeader,
	volume: bool,
	volume_number: ?u64,
	solid: bool,
};

pub const CompressionInfo = struct {
	algo_version: u6,
	solid: bool,
	method: u3, // 0=store, 1-5=compression
	dict_bits: u4,
	dict_frac_bits: u4,
};

pub const FileBlock = struct {
	header: BlockHeader,
	is_directory: bool,
	has_mtime: bool,
	has_crc32: bool,
	unpacked_unknown: bool,
	unpacked_size: u64,
	attributes: u64,
	mtime: ?u32,
	data_crc32: ?u32,
	compression: CompressionInfo,
	host_os: u64,
	name: []const u8,
	extra_data: ?[]const u8, // raw extra area bytes for later parsing
};

pub const ExtraRecord = struct {
	field_type: u64,
	data: []const u8,
};

pub const EndBlock = struct {
	header: BlockHeader,
	next_volume: bool,
};

pub const ArchiveBlock = union(enum) {
	main: MainBlock,
	file: FileBlock,
	service: FileBlock, // same structure as file
	crypt: BlockHeader, // just header for now
	end_archive: EndBlock,
	unknown: BlockHeader,
};

pub const ParseError = error{
	EndOfData,
	HeaderTooLarge,
};

// Extra record type constants
pub const EXTRA_FILE_HASH: u64 = 0x02;
pub const HASH_TYPE_BLAKE2SP: u64 = 0x00;
pub const EXTRA_FILE_ENCRYPTION: u64 = 0x01;

/// Maximum allowed header size: 2 MiB.
const MAX_HEADER_SIZE: u64 = 2 * 1024 * 1024;

// ============================================================================
// Parsing functions
// ============================================================================

/// Extract flag bits from a raw header flags value.
pub fn parse_header_flags(raw: u64) HeaderFlags {
	return .{
		.extra = (raw & 0x0001) != 0,
		.data = (raw & 0x0002) != 0,
		.skip_if_unknown = (raw & 0x0004) != 0,
		.split_before = (raw & 0x0008) != 0,
		.split_after = (raw & 0x0010) != 0,
		.child = (raw & 0x0020) != 0,
		.inherited = (raw & 0x0040) != 0,
		.raw = raw,
	};
}

/// Extract compression info bit fields from a raw vint value.
pub fn parse_compression_info(raw: u64) CompressionInfo {
	return .{
		.algo_version = @intCast(raw & 0x3F), // bits 0-5
		.solid = ((raw >> 6) & 1) != 0, // bit 6
		.method = @intCast((raw >> 7) & 0x7), // bits 7-9
		.dict_bits = @intCast((raw >> 10) & 0xF), // bits 10-13
		.dict_frac_bits = @intCast((raw >> 14) & 0xF), // bits 14-17
	};
}

/// Read a block header from the reader. The reader must be positioned at
/// the start of the header (the 4-byte CRC32 field).
pub fn parse_block_header(r: *reader_mod.Reader) ParseError!BlockHeader {
	const header_start = r.position();

	// Read the 4-byte CRC32
	const header_crc = r.read_u32_le() catch return error.EndOfData;

	// Read header_size vint and track its encoded length
	const before_hsize = r.position();
	const header_size = r.read_vint() catch return error.EndOfData;
	const hsize_vint_len = r.position() - before_hsize;

	// Reject oversized headers
	if (header_size > MAX_HEADER_SIZE) {
		return error.HeaderTooLarge;
	}

	// Read header_type vint
	const type_raw = r.read_vint() catch return error.EndOfData;
	const block_type: BlockType = @enumFromInt(@as(u7, @intCast(type_raw & 0x7F)));

	// Read header_flags vint
	const flags_raw = r.read_vint() catch return error.EndOfData;
	const flags = parse_header_flags(flags_raw);

	// Read optional extra_size
	var extra_size: ?u64 = null;
	if (flags.extra) {
		extra_size = r.read_vint() catch return error.EndOfData;
	}

	// Read optional data_size
	var data_size: ?u64 = null;
	if (flags.data) {
		data_size = r.read_vint() catch return error.EndOfData;
	}

	const body_start = r.position();

	return .{
		.header_crc = header_crc,
		.header_size = header_size,
		.block_type = block_type,
		.flags = flags,
		.extra_size = extra_size,
		.data_size = data_size,
		.header_start = header_start,
		.body_start = body_start,
		.crc_data_len = hsize_vint_len + @as(usize, @intCast(header_size)),
	};
}

/// Parse the body of a MAIN block.
pub fn parse_main_block(r: *reader_mod.Reader, header: BlockHeader) ParseError!MainBlock {
	const archive_flags = r.read_vint() catch return error.EndOfData;

	const volume = (archive_flags & 0x0001) != 0;
	const has_volnumber = (archive_flags & 0x0002) != 0;
	const solid = (archive_flags & 0x0004) != 0;

	var volume_number: ?u64 = null;
	if (has_volnumber) {
		volume_number = r.read_vint() catch return error.EndOfData;
	}

	return .{
		.header = header,
		.volume = volume,
		.volume_number = volume_number,
		.solid = solid,
	};
}

/// Parse the body of a FILE or SERVICE block.
pub fn parse_file_block(r: *reader_mod.Reader, header: BlockHeader) ParseError!FileBlock {
	const file_flags = r.read_vint() catch return error.EndOfData;

	const is_directory = (file_flags & 0x0001) != 0;
	const has_mtime = (file_flags & 0x0002) != 0;
	const has_crc32 = (file_flags & 0x0004) != 0;
	const unpacked_unknown = (file_flags & 0x0008) != 0;

	const unpacked_size = r.read_vint() catch return error.EndOfData;
	const attributes = r.read_vint() catch return error.EndOfData;

	var mtime: ?u32 = null;
	if (has_mtime) {
		mtime = r.read_u32_le() catch return error.EndOfData;
	}

	var data_crc32: ?u32 = null;
	if (has_crc32) {
		data_crc32 = r.read_u32_le() catch return error.EndOfData;
	}

	const compression_raw = r.read_vint() catch return error.EndOfData;
	const compression = parse_compression_info(compression_raw);

	const host_os = r.read_vint() catch return error.EndOfData;

	const name_length = r.read_vint() catch return error.EndOfData;
	const name = r.read_bytes(@intCast(name_length)) catch return error.EndOfData;

	// Read extra area if present
	var extra_data: ?[]const u8 = null;
	if (header.flags.extra) {
		if (header.extra_size) |es| {
			extra_data = r.read_bytes(@intCast(es)) catch return error.EndOfData;
		}
	}

	return .{
		.header = header,
		.is_directory = is_directory,
		.has_mtime = has_mtime,
		.has_crc32 = has_crc32,
		.unpacked_unknown = unpacked_unknown,
		.unpacked_size = unpacked_size,
		.attributes = attributes,
		.mtime = mtime,
		.data_crc32 = data_crc32,
		.compression = compression,
		.host_os = host_os,
		.name = name,
		.extra_data = extra_data,
	};
}

/// Parse the body of an END_ARCHIVE block.
pub fn parse_end_block(r: *reader_mod.Reader, header: BlockHeader) ParseError!EndBlock {
	const end_flags = r.read_vint() catch return error.EndOfData;

	return .{
		.header = header,
		.next_volume = (end_flags & 0x0001) != 0,
	};
}

/// Parse extra area bytes into individual ExtraRecord entries.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn parse_extra_records(data: []const u8, allocator: std.mem.Allocator) ![]ExtraRecord {
	var records: std.ArrayList(ExtraRecord) = .empty;
	errdefer records.deinit(allocator);

	var r = reader_mod.Reader.init(data);

	while (r.remaining() > 0) {
		const field_size = r.read_vint() catch break;
		if (field_size == 0) break;

		// Remember position before reading field_type to compute how many
		// bytes the field_type vint consumed.
		const before_type = r.position();
		const field_type = r.read_vint() catch break;
		const type_vint_len = r.position() - before_type;

		// field_data is the remaining bytes within this record
		const data_len = field_size - type_vint_len;
		const field_data = r.read_bytes(@intCast(data_len)) catch break;

		try records.append(allocator, .{
			.field_type = field_type,
			.data = field_data,
		});
	}

	return records.toOwnedSlice(allocator);
}

/// Extract BLAKE2sp hash from extra records, if present.
/// Returns the 32-byte hash if a HASH extra record with BLAKE2sp type is found.
pub fn extract_blake2sp_hash(extra_records: []const ExtraRecord) ?[32]u8 {
	for (extra_records) |rec| {
		if (rec.field_type == EXTRA_FILE_HASH) {
			// Parse: hash_type vint + 32-byte hash
			var r = reader_mod.Reader.init(rec.data);
			const hash_type = r.read_vint() catch continue;
			if (hash_type != HASH_TYPE_BLAKE2SP) continue;
			const hash_bytes = r.read_bytes(32) catch continue;
			var result: [32]u8 = undefined;
			@memcpy(&result, hash_bytes);
			return result;
		}
	}
	return null;
}

/// Returns true if the file's extra area contains a file-encryption record
/// (RAR5 extra record type 0x01), indicating the file's data is encrypted.
/// Non-allocating: walks the raw extra bytes directly.
pub fn extra_has_encryption(extra_data: ?[]const u8) bool {
	const data = extra_data orelse return false;
	var r = reader_mod.Reader.init(data);
	while (r.remaining() > 0) {
		const field_size = r.read_vint() catch break;
		if (field_size == 0) break;
		const before_type = r.position();
		const field_type = r.read_vint() catch break;
		const type_vint_len = r.position() - before_type;
		if (field_type == EXTRA_FILE_ENCRYPTION) return true;
		const data_len = field_size - type_vint_len;
		_ = r.read_bytes(@intCast(data_len)) catch break;
	}
	return false;
}

/// Extract a BLAKE2sp file hash directly from raw extra-area bytes, without
/// allocating an intermediate ExtraRecord list. Returns the 32-byte hash if a
/// HASH extra record (type 0x02) with BLAKE2sp hash_type (0x00) is present.
pub fn extract_blake2sp_hash_raw(extra_data: ?[]const u8) ?[32]u8 {
	const data = extra_data orelse return null;
	var r = reader_mod.Reader.init(data);
	while (r.remaining() > 0) {
		const field_size = r.read_vint() catch break;
		if (field_size == 0) break;
		const before_type = r.position();
		const field_type = r.read_vint() catch break;
		const type_vint_len = r.position() - before_type;
		const data_len = field_size - type_vint_len;
		if (field_type == EXTRA_FILE_HASH) {
			// HASH record body: hash_type vint + 32-byte hash
			const rec_start = r.position();
			const hash_type = r.read_vint() catch break;
			if (hash_type == HASH_TYPE_BLAKE2SP) {
				const hash_bytes = r.read_bytes(32) catch break;
				var result: [32]u8 = undefined;
				@memcpy(&result, hash_bytes);
				return result;
			}
			// Not BLAKE2sp — skip the rest of this record's data.
			const consumed = r.position() - rec_start;
			if (data_len > consumed) {
				_ = r.read_bytes(@intCast(data_len - consumed)) catch break;
			}
		} else {
			_ = r.read_bytes(@intCast(data_len)) catch break;
		}
	}
	return null;
}

/// Validate the header CRC32 against the stored value.
/// The CRC is computed over header_size bytes starting from the header_size
/// vint field (i.e., the 4 bytes after header_start).
pub fn validate_header_crc(archive_data: []const u8, header: BlockHeader) bool {
	const crc_data_start = header.header_start + 4; // skip the CRC32 field itself
	const crc_data_end = crc_data_start + header.crc_data_len;

	if (crc_data_end > archive_data.len) return false;

	const computed = integrity.crc32(archive_data[crc_data_start..crc_data_end]);
	return computed == header.header_crc;
}

// ============================================================================
// Block iterator
// ============================================================================

/// Iterator that walks all blocks in a RAR5 archive byte stream.
pub const BlockIterator = struct {
	data: []const u8,
	pos: usize,

	/// Parse and return the next block, or null if at end of data.
	pub fn next(self: *BlockIterator) ParseError!?ArchiveBlock {
		if (self.pos >= self.data.len) return null;

		var r = reader_mod.Reader.init(self.data[self.pos..]);
		const header = try parse_block_header(&r);

		// Compute total block size: 4 (CRC32) + crc_data_len + data_size
		const total_header = 4 + header.crc_data_len;
		const total_data = if (header.data_size) |ds| @as(usize, @intCast(ds)) else 0;
		const total_block = total_header + total_data;

		// Adjust header offsets to be relative to archive start
		var adjusted_header = header;
		adjusted_header.header_start = self.pos + header.header_start;
		adjusted_header.body_start = self.pos + header.body_start;

		const block: ArchiveBlock = switch (header.block_type) {
			.main => blk: {
				var main_block = try parse_main_block(&r, adjusted_header);
				main_block.header = adjusted_header;
				break :blk .{ .main = main_block };
			},
			.file => blk: {
				var file_block = try parse_file_block(&r, adjusted_header);
				file_block.header = adjusted_header;
				break :blk .{ .file = file_block };
			},
			.service => blk: {
				var svc_block = try parse_file_block(&r, adjusted_header);
				svc_block.header = adjusted_header;
				break :blk .{ .service = svc_block };
			},
			.crypt => .{ .crypt = adjusted_header },
			.end_archive => blk: {
				var end_block = try parse_end_block(&r, adjusted_header);
				end_block.header = adjusted_header;
				break :blk .{ .end_archive = end_block };
			},
			_ => .{ .unknown = adjusted_header },
		};

		// Advance past entire block
		self.pos += total_block;
		return block;
	}
};

/// Create a BlockIterator over the given archive data.
pub fn walk_blocks(data: []const u8) BlockIterator {
	return .{ .data = data, .pos = 0 };
}

// ============================================================================
// Tests
// ============================================================================

const encode_vint = reader_mod.encode_vint;

/// Build a complete header byte slice for testing. Returns the number of
/// bytes written into `out`. The CRC32 is computed and placed at bytes 0..3.
fn build_test_header(
	out: []u8,
	block_type: u7,
	flags_raw: u64,
	extra_size: ?u64,
	data_size: ?u64,
	body: []const u8,
) usize {
	// Build the "after CRC" portion into a temp buffer
	var tmp: [512]u8 = undefined;
	var pos: usize = 0;

	// We'll fill in the header_size vint after we know how big everything is.
	// First, compute the contents (everything after header_size vint).
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

	// Now encode header_size as vint. header_size = size of header_type through end of header area.
	// But RAR5 says header_size is the size from header_type onward.
	// Actually: header_size includes header_size's own vint bytes? No.
	// From spec: "header_size : vint (size of header data beginning at header_type)"
	// So header_size = contents length (cpos).
	// But wait, header_size is the number of bytes from header_type to end of header.
	// header_size vint itself is not counted in header_size.
	// However, for CRC: CRC is over header_size vint + contents.

	// Encode header_size vint
	pos += encode_vint(cpos, tmp[pos..]);
	// Append contents
	@memcpy(tmp[pos..][0..cpos], contents[0..cpos]);
	pos += cpos;

	// Compute CRC32 over tmp[0..pos] (header_size vint + contents)
	const crc = integrity.crc32(tmp[0..pos]);

	// Write CRC32 as little-endian u32
	std.mem.writeInt(u32, out[0..4], crc, .little);
	// Write the rest
	@memcpy(out[4..][0..pos], tmp[0..pos]);

	return 4 + pos;
}

test "parse_header_flags extracts all bits" {
	// All flags set: bits 0-6 = 0x7F
	const flags = parse_header_flags(0x7F);
	try testing.expect(flags.extra);
	try testing.expect(flags.data);
	try testing.expect(flags.skip_if_unknown);
	try testing.expect(flags.split_before);
	try testing.expect(flags.split_after);
	try testing.expect(flags.child);
	try testing.expect(flags.inherited);
	try testing.expectEqual(@as(u64, 0x7F), flags.raw);

	// No flags set
	const flags2 = parse_header_flags(0);
	try testing.expect(!flags2.extra);
	try testing.expect(!flags2.data);
	try testing.expect(!flags2.skip_if_unknown);
	try testing.expect(!flags2.split_before);
	try testing.expect(!flags2.split_after);
	try testing.expect(!flags2.child);
	try testing.expect(!flags2.inherited);

	// Individual bit test: only HFL_DATA
	const flags3 = parse_header_flags(0x0002);
	try testing.expect(!flags3.extra);
	try testing.expect(flags3.data);
	try testing.expect(!flags3.skip_if_unknown);
}

test "parse_compression_info extracts bit fields" {
	// Test store: method=0, algo_version=0, no solid, dict_bits=0
	const store = parse_compression_info(0);
	try testing.expectEqual(@as(u6, 0), store.algo_version);
	try testing.expect(!store.solid);
	try testing.expectEqual(@as(u3, 0), store.method);
	try testing.expectEqual(@as(u4, 0), store.dict_bits);
	try testing.expectEqual(@as(u4, 0), store.dict_frac_bits);

	// Test compressed: algo_version=0, solid=true, method=3, dict_bits=10, dict_frac_bits=2
	// bits: 000000 = algo(0), 1 = solid, 011 = method(3), 1010 = dict(10), 0010 = frac(2)
	// binary: 0010_1010_0110_1_000000
	// = 0b00_0010_1010_0110_1_000000
	// bits 0-5: 0b000000 = 0
	// bit 6: 1 = solid
	// bits 7-9: 0b011 = 3
	// bits 10-13: 0b1010 = 10
	// bits 14-17: 0b0010 = 2
	const raw: u64 = (0 << 0) | (1 << 6) | (3 << 7) | (10 << 10) | (2 << 14);
	const comp = parse_compression_info(raw);
	try testing.expectEqual(@as(u6, 0), comp.algo_version);
	try testing.expect(comp.solid);
	try testing.expectEqual(@as(u3, 3), comp.method);
	try testing.expectEqual(@as(u4, 10), comp.dict_bits);
	try testing.expectEqual(@as(u4, 2), comp.dict_frac_bits);
}

test "parse_block_header reads CRC + vint fields" {
	var buf: [256]u8 = undefined;
	const len = build_test_header(&buf, 1, 0, null, null, &.{});
	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);

	try testing.expectEqual(BlockType.main, hdr.block_type);
	try testing.expect(!hdr.flags.extra);
	try testing.expect(!hdr.flags.data);
	try testing.expectEqual(@as(?u64, null), hdr.extra_size);
	try testing.expectEqual(@as(?u64, null), hdr.data_size);
	try testing.expectEqual(@as(usize, 0), hdr.header_start);
}

test "parse_block_header rejects oversized header" {
	// Manually construct a header with an enormous header_size
	var buf: [64]u8 = undefined;
	// CRC32 (dummy, doesn't matter for this test)
	std.mem.writeInt(u32, buf[0..4], 0, .little);
	// header_size = 3 MiB (larger than 2 MiB limit)
	const big_size: u64 = 3 * 1024 * 1024;
	const vlen = encode_vint(big_size, buf[4..]);

	var r = reader_mod.Reader.init(buf[0 .. 4 + vlen]);
	const result = parse_block_header(&r);
	try testing.expectError(error.HeaderTooLarge, result);
}

test "parse_main_block reads archive flags" {
	var buf: [256]u8 = undefined;
	// Main block body: archive_flags = 0 (no volume, no solid)
	var body: [16]u8 = undefined;
	const body_len = encode_vint(0, &body); // archive_flags = 0
	const len = build_test_header(&buf, 1, 0, null, null, body[0..body_len]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);
	const main = try parse_main_block(&r, hdr);

	try testing.expect(!main.volume);
	try testing.expect(!main.solid);
	try testing.expectEqual(@as(?u64, null), main.volume_number);
}

test "parse_main_block with volume number" {
	var buf: [256]u8 = undefined;
	// Main block body: archive_flags = 0x0003 (VOLUME + VOLNUMBER), volume_number = 42
	var body: [32]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(0x0003, body[bpos..]); // archive_flags: volume + volnumber
	bpos += encode_vint(42, body[bpos..]); // volume_number = 42
	const len = build_test_header(&buf, 1, 0, null, null, body[0..bpos]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);
	const main = try parse_main_block(&r, hdr);

	try testing.expect(main.volume);
	try testing.expect(!main.solid);
	try testing.expectEqual(@as(?u64, 42), main.volume_number);
}

test "parse_file_block reads all fields" {
	var buf: [512]u8 = undefined;
	// FILE block body:
	//   file_flags = 0 (no optional fields)
	//   unpacked_size = 1024
	//   attributes = 0x20
	//   compression_info = 0 (store)
	//   host_os = 0 (Windows)
	//   name_length = 8
	//   name = "test.txt"
	var body: [128]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(0, body[bpos..]); // file_flags = 0
	bpos += encode_vint(1024, body[bpos..]); // unpacked_size
	bpos += encode_vint(0x20, body[bpos..]); // attributes
	bpos += encode_vint(0, body[bpos..]); // compression_info (store)
	bpos += encode_vint(0, body[bpos..]); // host_os
	bpos += encode_vint(8, body[bpos..]); // name_length
	@memcpy(body[bpos..][0..8], "test.txt");
	bpos += 8;

	const len = build_test_header(&buf, 2, 0, null, null, body[0..bpos]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);
	const fb = try parse_file_block(&r, hdr);

	try testing.expect(!fb.is_directory);
	try testing.expect(!fb.has_mtime);
	try testing.expect(!fb.has_crc32);
	try testing.expectEqual(@as(u64, 1024), fb.unpacked_size);
	try testing.expectEqual(@as(u64, 0x20), fb.attributes);
	try testing.expectEqual(@as(u3, 0), fb.compression.method);
	try testing.expectEqual(@as(u64, 0), fb.host_os);
	try testing.expectEqualSlices(u8, "test.txt", fb.name);
	try testing.expectEqual(@as(?u32, null), fb.mtime);
	try testing.expectEqual(@as(?u32, null), fb.data_crc32);
}

test "parse_file_block with mtime and CRC32" {
	var buf: [512]u8 = undefined;
	// FILE block body with mtime and CRC32 present
	var body: [128]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(0x0006, body[bpos..]); // file_flags: UTIME + CRC32
	bpos += encode_vint(2048, body[bpos..]); // unpacked_size
	bpos += encode_vint(0x10, body[bpos..]); // attributes
	// mtime: u32 little-endian = 0x12345678
	std.mem.writeInt(u32, body[bpos..][0..4], 0x12345678, .little);
	bpos += 4;
	// data_crc32: u32 little-endian = 0xDEADBEEF
	std.mem.writeInt(u32, body[bpos..][0..4], 0xDEADBEEF, .little);
	bpos += 4;
	bpos += encode_vint(0, body[bpos..]); // compression_info (store)
	bpos += encode_vint(1, body[bpos..]); // host_os (Unix)
	bpos += encode_vint(5, body[bpos..]); // name_length
	@memcpy(body[bpos..][0..5], "a.bin");
	bpos += 5;

	const len = build_test_header(&buf, 2, 0, null, null, body[0..bpos]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);
	const fb = try parse_file_block(&r, hdr);

	try testing.expect(fb.has_mtime);
	try testing.expect(fb.has_crc32);
	try testing.expectEqual(@as(u32, 0x12345678), fb.mtime.?);
	try testing.expectEqual(@as(u32, 0xDEADBEEF), fb.data_crc32.?);
	try testing.expectEqual(@as(u64, 2048), fb.unpacked_size);
	try testing.expectEqual(@as(u64, 1), fb.host_os);
	try testing.expectEqualSlices(u8, "a.bin", fb.name);
}

test "parse_file_block without optional fields" {
	var buf: [512]u8 = undefined;
	// Minimal file block: no mtime, no crc32, no extra
	var body: [128]u8 = undefined;
	var bpos: usize = 0;
	bpos += encode_vint(0, body[bpos..]); // file_flags = 0
	bpos += encode_vint(0, body[bpos..]); // unpacked_size = 0
	bpos += encode_vint(0, body[bpos..]); // attributes = 0
	bpos += encode_vint(0, body[bpos..]); // compression_info
	bpos += encode_vint(0, body[bpos..]); // host_os
	bpos += encode_vint(0, body[bpos..]); // name_length = 0

	const len = build_test_header(&buf, 2, 0, null, null, body[0..bpos]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);
	const fb = try parse_file_block(&r, hdr);

	try testing.expect(!fb.is_directory);
	try testing.expect(!fb.has_mtime);
	try testing.expect(!fb.has_crc32);
	try testing.expectEqual(@as(?u32, null), fb.mtime);
	try testing.expectEqual(@as(?u32, null), fb.data_crc32);
	try testing.expectEqual(@as(u64, 0), fb.unpacked_size);
	try testing.expectEqualSlices(u8, "", fb.name);
	try testing.expectEqual(@as(?[]const u8, null), fb.extra_data);
}

test "parse_end_block reads next_volume flag" {
	var buf: [256]u8 = undefined;
	// End block body: end_flags = 1 (next volume exists)
	var body: [16]u8 = undefined;
	const body_len = encode_vint(1, &body);
	const len = build_test_header(&buf, 5, 0, null, null, body[0..body_len]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);
	const end = try parse_end_block(&r, hdr);

	try testing.expect(end.next_volume);

	// Also test with next_volume = false
	var buf2: [256]u8 = undefined;
	var body2: [16]u8 = undefined;
	const body2_len = encode_vint(0, &body2);
	const len2 = build_test_header(&buf2, 5, 0, null, null, body2[0..body2_len]);

	var r2 = reader_mod.Reader.init(buf2[0..len2]);
	const hdr2 = try parse_block_header(&r2);
	const end2 = try parse_end_block(&r2, hdr2);

	try testing.expect(!end2.next_volume);
}

test "validate_header_crc accepts correct CRC" {
	var buf: [256]u8 = undefined;
	var body: [16]u8 = undefined;
	const body_len = encode_vint(0, &body); // archive_flags = 0
	const len = build_test_header(&buf, 1, 0, null, null, body[0..body_len]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);

	try testing.expect(validate_header_crc(buf[0..len], hdr));
}

test "validate_header_crc rejects corrupted header" {
	var buf: [256]u8 = undefined;
	var body: [16]u8 = undefined;
	const body_len = encode_vint(0, &body);
	const len = build_test_header(&buf, 1, 0, null, null, body[0..body_len]);

	var r = reader_mod.Reader.init(buf[0..len]);
	const hdr = try parse_block_header(&r);

	// Corrupt a byte in the header data area (after the CRC32 field)
	buf[5] ^= 0xFF;

	try testing.expect(!validate_header_crc(buf[0..len], hdr));
}

test "parse_extra_records parses multiple records" {
	// Build an extra area with two records:
	// Record 1: field_type=0x02 (HASH), data = [0xAA, 0xBB]
	// Record 2: field_type=0x03 (HTIME), data = [0xCC]

	var extra: [64]u8 = undefined;
	var epos: usize = 0;

	// Record 1: field_size = 1 (type vint) + 2 (data) = 3
	epos += encode_vint(3, extra[epos..]); // field_size
	epos += encode_vint(0x02, extra[epos..]); // field_type
	extra[epos] = 0xAA;
	epos += 1;
	extra[epos] = 0xBB;
	epos += 1;

	// Record 2: field_size = 1 (type vint) + 1 (data) = 2
	epos += encode_vint(2, extra[epos..]); // field_size
	epos += encode_vint(0x03, extra[epos..]); // field_type
	extra[epos] = 0xCC;
	epos += 1;

	const records = try parse_extra_records(extra[0..epos], testing.allocator);
	defer testing.allocator.free(records);

	try testing.expectEqual(@as(usize, 2), records.len);

	try testing.expectEqual(@as(u64, 0x02), records[0].field_type);
	try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, records[0].data);

	try testing.expectEqual(@as(u64, 0x03), records[1].field_type);
	try testing.expectEqualSlices(u8, &[_]u8{0xCC}, records[1].data);
}

test "extract_blake2sp_hash returns hash from HASH extra record" {
	// Build an extra area with a HASH record: type=0x02, hash_type=0x00 (BLAKE2sp), 32-byte hash
	var extra: [64]u8 = undefined;
	var epos: usize = 0;

	var expected_hash: [32]u8 = undefined;
	for (&expected_hash, 0..) |*b, i| b.* = @intCast(i);

	// Record: field_size = 1 (type vint) + 1 (hash_type vint) + 32 (hash) = 34
	epos += encode_vint(34, extra[epos..]); // field_size
	epos += encode_vint(0x02, extra[epos..]); // field_type = HASH
	epos += encode_vint(0x00, extra[epos..]); // hash_type = BLAKE2sp
	@memcpy(extra[epos..][0..32], &expected_hash);
	epos += 32;

	const records = try parse_extra_records(extra[0..epos], testing.allocator);
	defer testing.allocator.free(records);

	const result = extract_blake2sp_hash(records);
	try testing.expect(result != null);
	try testing.expectEqualSlices(u8, &expected_hash, &result.?);
}

test "extract_blake2sp_hash returns null when no HASH record" {
	// Build an extra area with a non-HASH record
	var extra: [64]u8 = undefined;
	var epos: usize = 0;

	// Record: field_type=0x03 (HTIME), data = [0xCC]
	epos += encode_vint(2, extra[epos..]); // field_size
	epos += encode_vint(0x03, extra[epos..]); // field_type = HTIME
	extra[epos] = 0xCC;
	epos += 1;

	const records = try parse_extra_records(extra[0..epos], testing.allocator);
	defer testing.allocator.free(records);

	const result = extract_blake2sp_hash(records);
	try testing.expect(result == null);
}

test "extract_blake2sp_hash skips non-BLAKE2sp hash types" {
	// Build a HASH record with an unknown hash type (not 0x00)
	var extra: [64]u8 = undefined;
	var epos: usize = 0;

	var dummy_hash: [32]u8 = undefined;
	@memset(&dummy_hash, 0xFF);

	epos += encode_vint(34, extra[epos..]); // field_size
	epos += encode_vint(0x02, extra[epos..]); // field_type = HASH
	epos += encode_vint(0x01, extra[epos..]); // hash_type = unknown (not BLAKE2sp)
	@memcpy(extra[epos..][0..32], &dummy_hash);
	epos += 32;

	const records = try parse_extra_records(extra[0..epos], testing.allocator);
	defer testing.allocator.free(records);

	const result = extract_blake2sp_hash(records);
	try testing.expect(result == null);
}

test "extra_has_encryption detects type 0x01 record" {
	// Build an extra area with an encryption record: type=0x01, some data bytes.
	var extra: [64]u8 = undefined;
	var epos: usize = 0;

	// Record: field_size = 1 (type vint) + 3 (data) = 4
	epos += encode_vint(4, extra[epos..]); // field_size
	epos += encode_vint(0x01, extra[epos..]); // field_type = ENCRYPTION
	extra[epos] = 0xAA;
	epos += 1;
	extra[epos] = 0xBB;
	epos += 1;
	extra[epos] = 0xCC;
	epos += 1;

	try testing.expect(extra_has_encryption(extra[0..epos]));
}

test "extra_has_encryption is false without encryption record" {
	// Build an extra area with only a HASH record (type 0x02).
	var extra: [64]u8 = undefined;
	var epos: usize = 0;

	epos += encode_vint(2, extra[epos..]); // field_size
	epos += encode_vint(0x02, extra[epos..]); // field_type = HASH
	extra[epos] = 0xCC;
	epos += 1;

	try testing.expect(!extra_has_encryption(extra[0..epos]));
}

test "extra_has_encryption is false for null/empty extra" {
	try testing.expect(!extra_has_encryption(null));
	try testing.expect(!extra_has_encryption(&[_]u8{}));
}

test "extract_blake2sp_hash_raw returns hash from raw extra bytes" {
	var extra: [64]u8 = undefined;
	var epos: usize = 0;

	var expected_hash: [32]u8 = undefined;
	for (&expected_hash, 0..) |*b, i| b.* = @intCast(i);

	// Record: field_size = 1 (type) + 1 (hash_type) + 32 (hash) = 34
	epos += encode_vint(34, extra[epos..]); // field_size
	epos += encode_vint(0x02, extra[epos..]); // field_type = HASH
	epos += encode_vint(0x00, extra[epos..]); // hash_type = BLAKE2sp
	@memcpy(extra[epos..][0..32], &expected_hash);
	epos += 32;

	const result = extract_blake2sp_hash_raw(extra[0..epos]);
	try testing.expect(result != null);
	try testing.expectEqualSlices(u8, &expected_hash, &result.?);
}

test "extract_blake2sp_hash_raw returns null without HASH record" {
	var extra: [64]u8 = undefined;
	var epos: usize = 0;
	// Only an encryption record (type 0x01).
	epos += encode_vint(2, extra[epos..]); // field_size
	epos += encode_vint(0x01, extra[epos..]); // field_type = ENCRYPTION
	extra[epos] = 0xCC;
	epos += 1;

	try testing.expect(extract_blake2sp_hash_raw(extra[0..epos]) == null);
	try testing.expect(extract_blake2sp_hash_raw(null) == null);
}

test "extract_blake2sp_hash_raw matches allocating extract_blake2sp_hash" {
	var extra: [64]u8 = undefined;
	var epos: usize = 0;
	var expected_hash: [32]u8 = undefined;
	@memset(&expected_hash, 0x5A);
	epos += encode_vint(34, extra[epos..]);
	epos += encode_vint(0x02, extra[epos..]);
	epos += encode_vint(0x00, extra[epos..]);
	@memcpy(extra[epos..][0..32], &expected_hash);
	epos += 32;

	const records = try parse_extra_records(extra[0..epos], testing.allocator);
	defer testing.allocator.free(records);
	const ref = extract_blake2sp_hash(records);
	const raw = extract_blake2sp_hash_raw(extra[0..epos]);
	try testing.expect(ref != null and raw != null);
	try testing.expectEqualSlices(u8, &ref.?, &raw.?);
}

test "walk_blocks iterates through blocks" {
	// Build a sequence of blocks: MAIN, END_ARCHIVE
	var archive: [512]u8 = undefined;
	var apos: usize = 0;

	// MAIN block: archive_flags = 0
	{
		var body: [16]u8 = undefined;
		const body_len = encode_vint(0, &body);
		const len = build_test_header(archive[apos..], 1, 0, null, null, body[0..body_len]);
		apos += len;
	}

	// END_ARCHIVE block: end_flags = 0 (no next volume)
	{
		var body: [16]u8 = undefined;
		const body_len = encode_vint(0, &body);
		const len = build_test_header(archive[apos..], 5, 0, null, null, body[0..body_len]);
		apos += len;
	}

	var iter = walk_blocks(archive[0..apos]);

	// First block: MAIN
	const block1 = (try iter.next()) orelse return error.EndOfData;
	switch (block1) {
		.main => |main| {
			try testing.expect(!main.volume);
			try testing.expect(!main.solid);
		},
		else => return error.EndOfData,
	}

	// Second block: END_ARCHIVE
	const block2 = (try iter.next()) orelse return error.EndOfData;
	switch (block2) {
		.end_archive => |end| {
			try testing.expect(!end.next_volume);
		},
		else => return error.EndOfData,
	}

	// No more blocks
	const block3 = try iter.next();
	try testing.expectEqual(@as(?ArchiveBlock, null), block3);
}
