//! RAR 1.5-4.x (legacy) archive header parser.
//!
//! Parses the block-based header format used in RAR versions 1.5 through 4.x.
//! Headers consist of a 7-byte base block followed by type-specific fields.
//! CRC16 validation uses the ARC variant from integrity.zig.

const std = @import("std");
const reader_mod = @import("reader.zig");
const integrity = @import("integrity.zig");

const Reader = reader_mod.Reader;

// ============================================================================
// Types
// ============================================================================

pub const HeaderType = enum(u8) {
	mark = 0x72,
	main = 0x73,
	file = 0x74,
	comment = 0x75,
	av = 0x76,
	old_service = 0x77,
	protect = 0x78,
	sign = 0x79,
	service = 0x7A,
	end_archive = 0x7B,
	_,
};

pub const MainFlags = struct {
	volume: bool,
	comment: bool,
	lock: bool,
	solid: bool,
	protect: bool,
	password: bool,
	first_volume: bool,
	raw: u16,
};

pub const FileFlags = struct {
	split_before: bool,
	split_after: bool,
	password: bool,
	solid: bool,
	large: bool,
	unicode: bool,
	long_block: bool,
	raw: u16,
};

pub const BlockHeader = struct {
	head_crc: u16,
	header_type: HeaderType,
	flags: u16,
	head_size: u16,
	data_size: ?u64,
	header_offset: usize,
};

pub const FileHeader = struct {
	block: BlockHeader,
	packed_size: u64,
	unpacked_size: u64,
	host_os: u8,
	file_crc: u32,
	mtime: u32,
	unpack_version: u8,
	method: u8,
	attributes: u32,
	file_name: []const u8,
};

pub const ArchiveBlock = union(enum) {
	mark: BlockHeader,
	main: struct { block: BlockHeader, flags: MainFlags },
	file: FileHeader,
	end_archive: BlockHeader,
	other: BlockHeader,
};

// ============================================================================
// Constants
// ============================================================================

const LONG_BLOCK: u16 = 0x8000;
const LHD_LARGE: u16 = 0x0100;

// ============================================================================
// Parsing functions
// ============================================================================

pub const ParseError = error{
	EndOfData,
	HeaderTooSmall,
};

/// Parse a 7-byte base block header from the reader.
/// If the LONG_BLOCK flag (bit 15) is set, also reads the 4-byte data_size.
pub fn parse_block_header(r: *Reader) ParseError!BlockHeader {
	const header_offset = r.position();
	const head_crc = r.read_u16_le() catch return error.EndOfData;
	const type_byte = r.read_u8() catch return error.EndOfData;
	const flags = r.read_u16_le() catch return error.EndOfData;
	const head_size = r.read_u16_le() catch return error.EndOfData;

	if (head_size < 7) return error.HeaderTooSmall;

	const data_size: ?u64 = if (flags & LONG_BLOCK != 0)
		@as(u64, r.read_u32_le() catch return error.EndOfData)
	else
		null;

	return BlockHeader{
		.head_crc = head_crc,
		.header_type = @enumFromInt(type_byte),
		.flags = flags,
		.head_size = head_size,
		.data_size = data_size,
		.header_offset = header_offset,
	};
}

/// Extract main archive flags from a raw u16 flags field.
pub fn parse_main_flags(raw: u16) MainFlags {
	return MainFlags{
		.volume = (raw & 0x0001) != 0,
		.comment = (raw & 0x0002) != 0,
		.lock = (raw & 0x0004) != 0,
		.solid = (raw & 0x0008) != 0,
		// Reference (unrar headers.hpp): MHD_AV 0x0020, MHD_PROTECT 0x0040,
		// MHD_PASSWORD 0x0080. These were each one bit-position low, so a
		// recovery record (PROTECT) read as PASSWORD and AV read as PROTECT.
		.protect = (raw & 0x0040) != 0,
		.password = (raw & 0x0080) != 0,
		.first_volume = (raw & 0x0100) != 0,
		.raw = raw,
	};
}

/// Extract file flags from a raw u16 flags field.
pub fn parse_file_flags(raw: u16) FileFlags {
	return FileFlags{
		.split_before = (raw & 0x0001) != 0,
		.split_after = (raw & 0x0002) != 0,
		.password = (raw & 0x0004) != 0,
		.solid = (raw & 0x0010) != 0,
		.large = (raw & 0x0100) != 0,
		.unicode = (raw & 0x0200) != 0,
		.long_block = (raw & 0x8000) != 0,
		.raw = raw,
	};
}

/// Parse file-specific fields following the base block header.
/// The reader should be positioned right after the base header (and data_size
/// if LONG_BLOCK was set). The block parameter is the already-parsed base header.
pub fn parse_file_header(r: *Reader, block: BlockHeader) ParseError!FileHeader {
	// In RAR4 a file block's ADD_SIZE field IS PACK_SIZE — it is not a separate
	// field that follows it. parse_block_header already consumed ADD_SIZE when
	// LONG_BLOCK was set (which file blocks always set), so reading another u32
	// here shifted EVERY subsequent field by 4 bytes: unpacked_size picked up
	// host_os+CRC bytes (~2^32 garbage), the CRC came from the mtime slot (so
	// every entry reported the same value), name_size was wrong (empty names)
	// and mtime decoded to month 00. Take the packed size from the base header
	// when it is there, and only read a field when it is not.
	const packed_size_low: u32 = if (block.data_size) |ds|
		@truncate(ds)
	else
		r.read_u32_le() catch return error.EndOfData;
	const unpacked_size_low: u32 = r.read_u32_le() catch return error.EndOfData;
	const host_os = r.read_u8() catch return error.EndOfData;
	const file_crc = r.read_u32_le() catch return error.EndOfData;
	const mtime = r.read_u32_le() catch return error.EndOfData;
	const unpack_version = r.read_u8() catch return error.EndOfData;
	const method_raw = r.read_u8() catch return error.EndOfData;
	const name_size = r.read_u16_le() catch return error.EndOfData;
	const attributes = r.read_u32_le() catch return error.EndOfData;

	const flags = parse_file_flags(block.flags);

	var packed_size: u64 = packed_size_low;
	var unpacked_size: u64 = unpacked_size_low;

	if (flags.large) {
		const packed_high: u32 = r.read_u32_le() catch return error.EndOfData;
		const unpacked_high: u32 = r.read_u32_le() catch return error.EndOfData;
		packed_size |= @as(u64, packed_high) << 32;
		unpacked_size |= @as(u64, unpacked_high) << 32;
	}

	const file_name = r.read_bytes(name_size) catch return error.EndOfData;

	// Normalize method: subtract 0x30
	const method = method_raw -% 0x30;

	// Update the block's data_size to the full 64-bit packed_size when
	// the large flag is set. The base block header only stores the low
	// 32 bits; without this, the block iterator would misalign for >4GB files.
	var updated_block = block;
	if (flags.large and block.data_size != null) {
		updated_block.data_size = packed_size;
	}

	return FileHeader{
		.block = updated_block,
		.packed_size = packed_size,
		.unpacked_size = unpacked_size,
		.host_os = host_os,
		.file_crc = file_crc,
		.mtime = mtime,
		.unpack_version = unpack_version,
		.method = method,
		.attributes = attributes,
		.file_name = file_name,
	};
}

/// Validate the CRC16 stored in a block header against the actual header bytes.
/// `data` must be the full archive data; the header's offset and size are used
/// to locate the bytes. CRC16 covers bytes [2..head_size] relative to header_offset.
pub fn validate_header_crc(data: []const u8, header: BlockHeader) bool {
	const start = header.header_offset;
	const end = start + header.head_size;
	if (end > data.len) return false;
	// CRC covers bytes from offset+2 (after the 2-byte CRC field) through end of header
	const crc_data = data[start + 2 .. end];
	const computed = integrity.crc16(crc_data);
	return computed == header.head_crc;
}

// ============================================================================
// Block iterator
// ============================================================================

pub const BlockIterator = struct {
	data: []const u8,
	pos: usize,

	/// Return the next ArchiveBlock, or null when no more data remains.
	pub fn next(self: *BlockIterator) ParseError!?ArchiveBlock {
		if (self.pos >= self.data.len) return null;
		// Need at least 7 bytes for a base header
		if (self.data.len - self.pos < 7) return null;

		var r = Reader.init(self.data[self.pos..]);
		var block = try parse_block_header(&r);
		// parse_block_header records r.position(), and this Reader starts AT the
		// block, so that offset is always 0 — it is relative to the block, not to
		// the archive. Every consumer treats header_offset as an archive offset:
		// payload_start = header_offset + head_size located payloads as though
		// every block began at 0 (extraction returned right-sized, wrong-content
		// files), and validate_header_crc checksummed the first block's bytes for
		// every block. Rebase it onto the archive here.
		block.header_offset += self.pos;

		const result: ArchiveBlock = switch (block.header_type) {
			.mark => .{ .mark = block },
			.main => .{ .main = .{
				.block = block,
				.flags = parse_main_flags(block.flags),
			} },
			.file => blk: {
				const fh = try parse_file_header(&r, block);
				break :blk .{ .file = fh };
			},
			.end_archive => .{ .end_archive = block },
			.comment, .av, .old_service, .protect, .sign, .service => .{ .other = block },
			_ => .{ .other = block },
		};

		// Advance past the entire header + data payload.
		// For file blocks with the large flag, the data_size in the file header's
		// block has been updated to the full 64-bit packed_size.
		const effective_block = switch (result) {
			.file => |fh| fh.block,
			.mark => |b| b,
			.main => |m| m.block,
			.end_archive => |b| b,
			.other => |b| b,
		};
		const header_size: usize = effective_block.head_size;
		const data_size: u64 = effective_block.data_size orelse 0;
		self.pos += header_size + @as(usize, @intCast(data_size));

		return result;
	}
};

/// Create a block iterator over the given archive data.
pub fn walk_blocks(data: []const u8) BlockIterator {
	return .{ .data = data, .pos = 0 };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Helper to write a u16 in little-endian into a buffer at the given offset.
fn write_u16_le(buf: []u8, offset: usize, val: u16) void {
	std.mem.writeInt(u16, buf[offset..][0..2], val, .little);
}

/// Helper to write a u32 in little-endian into a buffer at the given offset.
fn write_u32_le(buf: []u8, offset: usize, val: u32) void {
	std.mem.writeInt(u32, buf[offset..][0..4], val, .little);
}

test "parse_block_header reads 7-byte header" {
	// Construct a 7-byte header:
	// head_crc: 0x1234, type: 0x73 (main), flags: 0x0001, head_size: 7
	var data: [7]u8 = undefined;
	write_u16_le(&data, 0, 0x1234); // head_crc
	data[2] = 0x73; // header_type = main
	write_u16_le(&data, 3, 0x0001); // flags
	write_u16_le(&data, 5, 7); // head_size

	var r = Reader.init(&data);
	const block = try parse_block_header(&r);

	try testing.expectEqual(@as(u16, 0x1234), block.head_crc);
	try testing.expectEqual(HeaderType.main, block.header_type);
	try testing.expectEqual(@as(u16, 0x0001), block.flags);
	try testing.expectEqual(@as(u16, 7), block.head_size);
	try testing.expectEqual(@as(?u64, null), block.data_size);
	try testing.expectEqual(@as(usize, 0), block.header_offset);
	try testing.expectEqual(@as(usize, 7), r.position());
}

test "parse_block_header with LONG_BLOCK reads data_size" {
	// 7-byte header + 4-byte data_size = 11 bytes
	var data: [11]u8 = undefined;
	write_u16_le(&data, 0, 0xABCD); // head_crc
	data[2] = 0x74; // header_type = file
	write_u16_le(&data, 3, 0x8000); // flags: LONG_BLOCK
	write_u16_le(&data, 5, 11); // head_size
	write_u32_le(&data, 7, 0x00010000); // data_size

	var r = Reader.init(&data);
	const block = try parse_block_header(&r);

	try testing.expectEqual(@as(u16, 0xABCD), block.head_crc);
	try testing.expectEqual(HeaderType.file, block.header_type);
	try testing.expectEqual(@as(u16, 0x8000), block.flags);
	try testing.expectEqual(@as(u16, 11), block.head_size);
	try testing.expectEqual(@as(?u64, 0x00010000), block.data_size);
	try testing.expectEqual(@as(usize, 11), r.position());
}

test "parse_main_flags extracts bits correctly" {
	// All flags set: volume(0x0001) | comment(0x0002) | lock(0x0004) | solid(0x0008)
	//               | protect(0x0040) | password(0x0080) | first_volume(0x0100)
	// (reference unrar headers.hpp; 0x0020 is MHD_AV, not PROTECT)
	const all_set: u16 = 0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0040 | 0x0080 | 0x0100;
	const flags = parse_main_flags(all_set);
	try testing.expect(flags.volume);
	try testing.expect(flags.comment);
	try testing.expect(flags.lock);
	try testing.expect(flags.solid);
	try testing.expect(flags.protect);
	try testing.expect(flags.password);
	try testing.expect(flags.first_volume);
	try testing.expectEqual(all_set, flags.raw);

	// No flags set
	const none = parse_main_flags(0x0000);
	try testing.expect(!none.volume);
	try testing.expect(!none.comment);
	try testing.expect(!none.lock);
	try testing.expect(!none.solid);
	try testing.expect(!none.protect);
	try testing.expect(!none.password);
	try testing.expect(!none.first_volume);

	// Only solid + password (MHD_PASSWORD is 0x0080, not 0x0040)
	const partial = parse_main_flags(0x0008 | 0x0080);
	try testing.expect(!partial.volume);
	try testing.expect(partial.solid);
	try testing.expect(partial.password);
	try testing.expect(!partial.protect);
	try testing.expect(!partial.first_volume);
}

test "parse_file_flags extracts bits correctly" {
	const all_set: u16 = 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0100 | 0x0200 | 0x8000;
	const flags = parse_file_flags(all_set);
	try testing.expect(flags.split_before);
	try testing.expect(flags.split_after);
	try testing.expect(flags.password);
	try testing.expect(flags.solid);
	try testing.expect(flags.large);
	try testing.expect(flags.unicode);
	try testing.expect(flags.long_block);
	try testing.expectEqual(all_set, flags.raw);

	// No flags
	const none = parse_file_flags(0x0000);
	try testing.expect(!none.split_before);
	try testing.expect(!none.split_after);
	try testing.expect(!none.password);
	try testing.expect(!none.solid);
	try testing.expect(!none.large);
	try testing.expect(!none.unicode);
	try testing.expect(!none.long_block);
}

test "parse_file_header reads all fields" {
	// Build a complete file header (without LHD_LARGE) after the base block.
	// NOTE: the packed size is NOT one of these fields. For a RAR4 file block
	// the base header's ADD_SIZE field IS PACK_SIZE, and parse_block_header
	// consumes it (LONG_BLOCK is set below), so it arrives via block.data_size.
	// This fixture used to write a packed_size here as well, double-counting it
	// — which is precisely the layout error the parser had, so the fixture
	// agreed with the bug and could never catch it. The official-tool fixture
	// in `parse_file_header: real RAR4 fixture matches unrar ground truth` is
	// the arbiter for this layout.
	// File-specific fields: unpacked_size_low(4) + host_os(1) + file_crc(4)
	//   + mtime(4) + unpack_version(1) + method(1) + name_size(2)
	//   + attributes(4) + filename
	// Total file-specific = 21 + name_size bytes
	const filename = "test.txt";
	const file_fields_len = 21 + filename.len;
	var data: [file_fields_len]u8 = undefined;

	var off: usize = 0;
	write_u32_le(&data, off, 2048); off += 4; // unpacked_size_low
	data[off] = 0x03; off += 1; // host_os (Unix)
	write_u32_le(&data, off, 0xDEADBEEF); off += 4; // file_crc
	write_u32_le(&data, off, 0x12345678); off += 4; // mtime
	data[off] = 29; off += 1; // unpack_version
	data[off] = 0x33; off += 1; // method raw (0x33 - 0x30 = 3)
	write_u16_le(&data, off, @as(u16, filename.len)); off += 2; // name_size
	write_u32_le(&data, off, 0x00000020); off += 4; // attributes

	// Copy filename
	@memcpy(data[off..][0..filename.len], filename);

	const block = BlockHeader{
		.head_crc = 0,
		.header_type = .file,
		.flags = 0x8000, // LONG_BLOCK but no LHD_LARGE
		.head_size = 7,
		.data_size = 1024,
		.header_offset = 0,
	};

	var r = Reader.init(&data);
	const fh = try parse_file_header(&r, block);

	try testing.expectEqual(@as(u64, 1024), fh.packed_size);
	try testing.expectEqual(@as(u64, 2048), fh.unpacked_size);
	try testing.expectEqual(@as(u8, 0x03), fh.host_os);
	try testing.expectEqual(@as(u32, 0xDEADBEEF), fh.file_crc);
	try testing.expectEqual(@as(u32, 0x12345678), fh.mtime);
	try testing.expectEqual(@as(u8, 29), fh.unpack_version);
	try testing.expectEqual(@as(u8, 3), fh.method); // normalized
	try testing.expectEqual(@as(u32, 0x00000020), fh.attributes);
	try testing.expectEqualSlices(u8, filename, fh.file_name);
}

test "parse_file_header with LHD_LARGE reads 64-bit sizes" {
	const filename = "big.bin";
	// With LHD_LARGE: +8 bytes (packed_high + unpacked_high)
	const file_fields_len = 25 + 8 + filename.len;
	var data: [file_fields_len]u8 = undefined;

	var off: usize = 0;
	write_u32_le(&data, off, 0x00001000); off += 4; // packed_size_low
	write_u32_le(&data, off, 0x00002000); off += 4; // unpacked_size_low
	data[off] = 0x00; off += 1; // host_os (DOS)
	write_u32_le(&data, off, 0xCAFEBABE); off += 4; // file_crc
	write_u32_le(&data, off, 0xAAAABBBB); off += 4; // mtime
	data[off] = 36; off += 1; // unpack_version
	data[off] = 0x30; off += 1; // method raw (0x30 - 0x30 = 0 = store)
	write_u16_le(&data, off, @as(u16, filename.len)); off += 2; // name_size
	write_u32_le(&data, off, 0x00000010); off += 4; // attributes
	// LHD_LARGE high words
	write_u32_le(&data, off, 0x00000005); off += 4; // packed_size_high
	write_u32_le(&data, off, 0x0000000A); off += 4; // unpacked_size_high
	@memcpy(data[off..][0..filename.len], filename);

	const block = BlockHeader{
		.head_crc = 0,
		.header_type = .file,
		.flags = 0x8100, // LONG_BLOCK | LHD_LARGE
		.head_size = 7,
		.data_size = null,
		.header_offset = 0,
	};

	var r = Reader.init(&data);
	const fh = try parse_file_header(&r, block);

	// packed = 0x00000005_00001000
	try testing.expectEqual(@as(u64, 0x0000000500001000), fh.packed_size);
	// unpacked = 0x0000000A_00002000
	try testing.expectEqual(@as(u64, 0x0000000A00002000), fh.unpacked_size);
	try testing.expectEqualSlices(u8, filename, fh.file_name);
	try testing.expectEqual(@as(u8, 0), fh.method); // store
}

test "validate_header_crc accepts correct CRC" {
	// Build a 7-byte header with a valid CRC16 over bytes [2..7]
	var data: [7]u8 = undefined;
	data[2] = 0x73; // header_type = main
	write_u16_le(&data, 3, 0x0001); // flags
	write_u16_le(&data, 5, 7); // head_size

	// Compute CRC16 over bytes [2..7]
	const crc = integrity.crc16(data[2..7]);
	write_u16_le(&data, 0, crc);

	const header = BlockHeader{
		.head_crc = crc,
		.header_type = .main,
		.flags = 0x0001,
		.head_size = 7,
		.data_size = null,
		.header_offset = 0,
	};

	try testing.expect(validate_header_crc(&data, header));
}

test "validate_header_crc matches real-world RAR4 file headers (CRC32-low16)" {
	// REGRESSION: prior `validate_header_crc accepts correct CRC` test above
	// is circular — it computes the CRC with rarz's own poly and asserts it
	// matches itself, so it always passes regardless of which polynomial
	// integrity.crc16 implements.
	//
	// This test bakes in the EXACT bytes from real RAR4 archives in the wild
	// (`Corduroy.cbr` and `KITT's Voice Lines.rar` both share these bytes
	// as their first 20 bytes). The stored HEAD_CRC (0x90CF) was emitted by
	// whatever RAR encoder produced those files, so our verifier MUST agree.
	//
	// CRC-32 (ISO-HDLC, same poly as zlib/PNG/Ethernet) of the 11 header
	// bytes that follow HEAD_CRC = 0x974290CF → low-16 = 0x90CF ✓
	// CRC-16/ARC of the same bytes = 0x1C64 ✗
	//
	// A second data point — the FIRST FILE block of `Corduroy.cbr` (offset
	// 20..62, 43 bytes total, stored HEAD_CRC=0x3CDC):
	//   CRC-32-low16 of bytes [2..43] = 0x3CDC ✓
	//   CRC-16/ARC = 0x2025 ✗
	//
	// So real-world RAR4 producers and the unrar reference store CRC-32-low16
	// for HEAD_CRC, NOT CRC-16/ARC. integrity.crc16 (which this function
	// delegates to) needs to compute the lower 16 bits of CRC-32, despite
	// the historical naming.

	// Synthesize the main-archive header alone (skip the marker; that's a
	// separate block with its own CRC handled elsewhere).
	const main_hdr = [_]u8{
		0xCF, 0x90, // HEAD_CRC = 0x90CF
		0x73,       // HEAD_TYPE = main
		0x00, 0x00, // FLAGS
		0x0D, 0x00, // HEAD_SIZE = 13
		0x00, 0x00, // RESERVED1
		0x00, 0x00, 0x00, 0x00, // RESERVED2
	};
	const header = BlockHeader{
		.head_crc = 0x90CF,
		.header_type = .main,
		.flags = 0x0000,
		.head_size = 13,
		.data_size = null,
		.header_offset = 0,
	};
	try testing.expect(validate_header_crc(&main_hdr, header));
}

test "validate_header_crc rejects corrupted CRC" {
	// Build a 7-byte header with valid CRC, then corrupt a byte
	var data: [7]u8 = undefined;
	data[2] = 0x73; // header_type = main
	write_u16_le(&data, 3, 0x0001); // flags
	write_u16_le(&data, 5, 7); // head_size

	const crc = integrity.crc16(data[2..7]);
	write_u16_le(&data, 0, crc);

	// Corrupt the type byte
	data[2] = 0x74;

	const header = BlockHeader{
		.head_crc = crc,
		.header_type = .main,
		.flags = 0x0001,
		.head_size = 7,
		.data_size = null,
		.header_offset = 0,
	};

	try testing.expect(!validate_header_crc(&data, header));
}

test "walk_blocks iterates through multiple blocks" {
	// Build a mini archive: MARK (7 bytes) + MAIN (7 bytes) + END_ARCHIVE (7 bytes) = 21 bytes
	var data: [21]u8 = undefined;

	// MARK block: type=0x72, flags=0, head_size=7
	data[2] = 0x72;
	write_u16_le(&data, 3, 0x0000);
	write_u16_le(&data, 5, 7);
	const crc0 = integrity.crc16(data[2..7]);
	write_u16_le(&data, 0, crc0);

	// MAIN block at offset 7: type=0x73, flags=0x0001, head_size=7
	data[9] = 0x73;
	write_u16_le(&data, 10, 0x0001);
	write_u16_le(&data, 12, 7);
	const crc1 = integrity.crc16(data[9..14]);
	write_u16_le(&data, 7, crc1);

	// END_ARCHIVE block at offset 14: type=0x7B, flags=0, head_size=7
	data[16] = 0x7B;
	write_u16_le(&data, 17, 0x0000);
	write_u16_le(&data, 19, 7);
	const crc2 = integrity.crc16(data[16..21]);
	write_u16_le(&data, 14, crc2);

	var iter = walk_blocks(&data);

	// First block: MARK
	const block0 = (try iter.next()).?;
	try testing.expectEqual(HeaderType.mark, block0.mark.header_type);

	// Second block: MAIN
	const block1 = (try iter.next()).?;
	try testing.expectEqual(HeaderType.main, block1.main.block.header_type);
	try testing.expect(block1.main.flags.volume);

	// Third block: END_ARCHIVE
	const block2 = (try iter.next()).?;
	try testing.expectEqual(HeaderType.end_archive, block2.end_archive.header_type);

	// No more blocks
	const block3 = try iter.next();
	try testing.expectEqual(@as(?ArchiveBlock, null), block3);
}

test "walk_blocks handles empty remaining data" {
	const data: []const u8 = &.{};
	var iter = walk_blocks(data);
	const result = try iter.next();
	try testing.expectEqual(@as(?ArchiveBlock, null), result);
}

test "block iterator advances correctly for >4GB file (large flag)" {
	// Construct a synthetic RAR4 archive with a file block that has the large flag set,
	// claiming a packed_size > 4GB. After the file block + its data, there's an end_archive
	// block. The iterator must use the full 64-bit data_size to skip correctly.
	//
	// We can't allocate 4GB of data in a test, so we construct the scenario differently:
	// We build a file block header with packed_size = 0x1_0000_0100 (just over 4GB).
	// The data_size in the base block header (LONG_BLOCK) will be the low 32 bits: 0x0000_0100.
	// If the iterator only uses the 32-bit data_size, it would skip only 0x100 bytes of data.
	// If it uses the full 64-bit value, it would skip 0x1_0000_0100 bytes.
	//
	// Since we can't have that much data, we instead verify the parsed BlockHeader.data_size
	// is the full 64-bit value by checking what the iterator computes for the file block.
	//
	// Strategy: build a file block with large flag, parse it, and verify data_size is 64-bit.

	const filename = "huge.bin";
	// File block header layout for a large file:
	// Base header (7 bytes): crc(2) + type(1) + flags(2) + head_size(2)
	// data_size (4 bytes): LONG_BLOCK -> low 32 bits of packed_size
	// File-specific (25 bytes): packed_size_low(4) + unpacked_size_low(4) + host_os(1) +
	//   file_crc(4) + mtime(4) + version(1) + method(1) + name_size(2) + attrs(4)
	// Large extension (8 bytes): packed_size_high(4) + unpacked_size_high(4)
	// Filename

	const flags: u16 = LONG_BLOCK | LHD_LARGE; // 0x8100
	const base_header_size: u16 = 7;
	const data_size_field: usize = 4; // LONG_BLOCK adds 4 bytes to base
	const file_fields: usize = 21; // standard file-specific fields (packed size arrives via ADD_SIZE)
	const large_ext: usize = 8; // packed_high + unpacked_high
	const head_size: u16 = base_header_size + @as(u16, @intCast(data_size_field)) + @as(u16, @intCast(file_fields)) + @as(u16, @intCast(large_ext)) + @as(u16, @intCast(filename.len));

	var data: [128]u8 = undefined;
	var off: usize = 0;

	// Base header
	write_u16_le(&data, off, 0x0000); off += 2; // head_crc (we don't validate in iterator)
	data[off] = 0x74; off += 1; // header_type = file
	write_u16_le(&data, off, flags); off += 2; // flags: LONG_BLOCK | LHD_LARGE
	write_u16_le(&data, off, head_size); off += 2; // head_size

	// data_size (low 32 bits of packed_size) - LONG_BLOCK field
	const packed_size_low: u32 = 0x0000_0100;
	write_u32_le(&data, off, packed_size_low); off += 4;

	// File-specific fields.
	// NOTE: no packed_size_low here — as the comment above says, ADD_SIZE (the
	// LONG_BLOCK field just written) IS the low 32 bits of the packed size.
	// This fixture used to write it a second time, double-counting it and
	// encoding the very field-offset bug the parser had.
	write_u32_le(&data, off, 0x0000_0200); off += 4; // unpacked_size_low
	data[off] = 0x00; off += 1; // host_os
	write_u32_le(&data, off, 0x12345678); off += 4; // file_crc
	write_u32_le(&data, off, 0x00000000); off += 4; // mtime
	data[off] = 29; off += 1; // unpack_version
	data[off] = 0x30; off += 1; // method (store)
	write_u16_le(&data, off, @as(u16, filename.len)); off += 2; // name_size
	write_u32_le(&data, off, 0x00000000); off += 4; // attributes

	// Large extension: high 32 bits
	const packed_size_high: u32 = 0x0000_0001; // packed = 0x1_0000_0100
	const unpacked_size_high: u32 = 0x0000_0002; // unpacked = 0x2_0000_0200
	write_u32_le(&data, off, packed_size_high); off += 4;
	write_u32_le(&data, off, unpacked_size_high); off += 4;

	// Filename
	@memcpy(data[off..][0..filename.len], filename);
	off += filename.len;

	// Parse through the block iterator
	var iter = walk_blocks(data[0..off]);
	const result = try iter.next();
	try testing.expect(result != null);

	const file_block = result.?.file;

	// Verify the file header has full 64-bit packed_size
	try testing.expectEqual(@as(u64, 0x1_0000_0100), file_block.packed_size);
	try testing.expectEqual(@as(u64, 0x2_0000_0200), file_block.unpacked_size);

	// Critical check: the block's data_size must be the full 64-bit packed_size,
	// not just the low 32 bits. This is what the iterator uses to advance.
	try testing.expect(file_block.block.data_size != null);
	try testing.expectEqual(@as(u64, 0x1_0000_0100), file_block.block.data_size.?);
}

test "method normalization subtracts 0x30" {
	// Method 0x30 = store (0), 0x33 = level 3 (3), 0x35 = level 5 (5)
	const filename = "a";
	const file_fields_len = 25 + filename.len;
	var data: [file_fields_len]u8 = undefined;

	// Test with method = 0x30 (store)
	var off: usize = 0;
	write_u32_le(&data, off, 100); off += 4; // packed_size_low
	write_u32_le(&data, off, 100); off += 4; // unpacked_size_low
	data[off] = 0; off += 1; // host_os
	write_u32_le(&data, off, 0); off += 4; // file_crc
	write_u32_le(&data, off, 0); off += 4; // mtime
	data[off] = 29; off += 1; // unpack_version
	data[off] = 0x30; off += 1; // method raw = store
	write_u16_le(&data, off, @as(u16, filename.len)); off += 2; // name_size
	write_u32_le(&data, off, 0); off += 4; // attributes
	data[off] = 'a';

	const block = BlockHeader{
		.head_crc = 0,
		.header_type = .file,
		.flags = 0,
		.head_size = 7,
		.data_size = null,
		.header_offset = 0,
	};

	var r = Reader.init(&data);
	const fh = try parse_file_header(&r, block);
	try testing.expectEqual(@as(u8, 0), fh.method); // 0x30 - 0x30 = 0

	// Now test with method = 0x33 (level 3)
	data[18] = 0x33; // method byte offset within file-specific fields
	var r2 = Reader.init(&data);
	const fh2 = try parse_file_header(&r2, block);
	try testing.expectEqual(@as(u8, 3), fh2.method); // 0x33 - 0x30 = 3
}

test "parse_file_header: real RAR4 fixture matches unrar ground truth" {
	// Differential against an INDEPENDENT producer (official rar 6.21) and an
	// independent reader (unrar 7.20). `unrar l tests/fixtures/rar4_store.rar`
	// reports exactly:
	//     text.txt   6972
	//     noise.bin  4096
	//     mixed.bin  6144
	// rarz reported garbage for all three (empty names, ~2^32 unpacked sizes,
	// month-00 dates, and the SAME CRC for every entry) while still calling the
	// archive VALID. Root cause: in RAR4 a file block's ADD_SIZE field IS
	// PACK_SIZE. parse_block_header already consumes it for LONG_BLOCK, and
	// parse_file_header then read a packed size again, shifting every following
	// field by 4 bytes.
	const data: []const u8 = @embedFile("rar4_store");
	const Expected = struct { name: []const u8, size: u64 };
	const expected = [_]Expected{
		.{ .name = "text.txt", .size = 6972 },
		.{ .name = "noise.bin", .size = 4096 },
		.{ .name = "mixed.bin", .size = 6144 },
	};

	// RAR4 blocks start at the 7-byte signature.
	var iter = BlockIterator{ .data = data, .pos = 0 };
	var seen: usize = 0;
	var crcs: [3]u32 = .{ 0, 0, 0 };
	while (try iter.next()) |block| {
		switch (block) {
			.file => |f| {
				if (seen >= expected.len) break;
				try testing.expectEqualStrings(expected[seen].name, f.file_name);
				try testing.expectEqual(expected[seen].size, f.unpacked_size);
				crcs[seen] = f.file_crc;
				seen += 1;
			},
			else => {},
		}
	}
	try testing.expectEqual(@as(usize, 3), seen);
	// Three different payloads cannot share one CRC32; identical values were the
	// tell that the CRC field was being read from the wrong offset.
	try testing.expect(crcs[0] != crcs[1]);
	try testing.expect(crcs[1] != crcs[2]);
}


test "parse_main_flags: PROTECT (recovery record) is not PASSWORD" {
	// Reference (unrar headers.hpp):
	//   MHD_AV       0x0020
	//   MHD_PROTECT  0x0040   (recovery record)
	//   MHD_PASSWORD 0x0080
	// rarz had protect=0x0020 (actually AV) and password=0x0040 (actually
	// PROTECT), so ANY archive carrying a recovery record was reported as
	// password-protected. Validation then took the has_encrypted_content early
	// exit, skipped every payload check, and still returned VALID — a
	// false-green on a very common archive shape. Observed on a real 29 MB RAR4
	// that unrar reads with no password at all.
	const protect_only = parse_main_flags(0x0040);
	try testing.expect(protect_only.protect);
	try testing.expect(!protect_only.password);

	const password_only = parse_main_flags(0x0080);
	try testing.expect(password_only.password);
	try testing.expect(!password_only.protect);

	// 0x0020 is AV, and must not be mistaken for PROTECT.
	const av_only = parse_main_flags(0x0020);
	try testing.expect(!av_only.protect);
	try testing.expect(!av_only.password);

	// Unaffected neighbours stay correct.
	try testing.expect(parse_main_flags(0x0001).volume);
	try testing.expect(parse_main_flags(0x0008).solid);
	try testing.expect(parse_main_flags(0x0100).first_volume);
}
