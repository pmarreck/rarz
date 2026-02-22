//! Validation policy — maps parser outcomes to validation depth levels.
//!
//! Three validation depths:
//! - **signature**: magic bytes recognized, format family identified
//! - **structural**: header/block walk succeeds, all header CRCs valid, sizes coherent
//! - **full**: payload integrity verified (CRC32/BLAKE2sp of decoded content)

const std = @import("std");
const detect_mod = @import("detect.zig");
const integrity = @import("integrity.zig");
const rar4_headers = @import("rar4_headers.zig");
const rar5_headers = @import("rar5_headers.zig");
const reader_mod = @import("reader.zig");

// ============================================================================
// Types
// ============================================================================

pub const ValidationDepth = enum {
	signature,
	structural,
	full,
};

pub const ValidationResult = struct {
	is_valid: bool,
	depth: ValidationDepth,
	family: ?detect_mod.RarFamily,
	has_encrypted_content: bool,
	circumvented_trivial_protection: bool,
	error_message: ?[]const u8,
	block_count: u32,
	file_count: u32,
};

// ============================================================================
// Helpers
// ============================================================================

const encode_vint = reader_mod.encode_vint;

/// Write a u16 in little-endian into a buffer at the given offset.
fn write_u16_le(buf: []u8, offset: usize, val: u16) void {
	std.mem.writeInt(u16, buf[offset..][0..2], val, .little);
}

/// Write a u32 in little-endian into a buffer at the given offset.
fn write_u32_le(buf: []u8, offset: usize, val: u32) void {
	std.mem.writeInt(u32, buf[offset..][0..4], val, .little);
}

fn invalid_result(depth: ValidationDepth, family: ?detect_mod.RarFamily, msg: []const u8) ValidationResult {
	return .{
		.is_valid = false,
		.depth = depth,
		.family = family,
		.has_encrypted_content = false,
		.circumvented_trivial_protection = false,
		.error_message = msg,
		.block_count = 0,
		.file_count = 0,
	};
}

// ============================================================================
// RAR4 structural validation
// ============================================================================

fn validate_rar4_structural(data: []const u8, sig_offset: usize) ValidationResult {
	// RAR4 blocks start at the signature offset (the mark block is the first block)
	const archive_data = data[sig_offset..];
	var iter = rar4_headers.walk_blocks(archive_data);
	var block_count: u32 = 0;
	var file_count: u32 = 0;
	var has_encrypted: bool = false;

	while (true) {
		// Record position before parsing so we know where this block starts
		const block_pos = iter.pos;

		const maybe_block = iter.next() catch {
			return .{
				.is_valid = false,
				.depth = .structural,
				.family = .rar15,
				.has_encrypted_content = has_encrypted,
				.circumvented_trivial_protection = false,
				.error_message = "block parse error",
				.block_count = block_count,
				.file_count = file_count,
			};
		};
		const block = maybe_block orelse break;

		block_count += 1;

		// Validate header CRC for each block.
		// Skip the mark block — its CRC is a magic signature pattern,
		// not a computed CRC-16/ARC value.
		const is_mark = switch (block) {
			.mark => true,
			else => false,
		};
		if (!is_mark) {
			// The RAR4 BlockIterator creates a fresh Reader for each block,
			// so header_offset is always 0 (relative to sub-slice). We need
			// to create a corrected header with the absolute offset within
			// archive_data for CRC validation to work.
			var block_header = switch (block) {
				.mark => unreachable,
				.main => |m| m.block,
				.file => |f| f.block,
				.end_archive => |b| b,
				.other => |b| b,
			};
			block_header.header_offset = block_pos;

			if (!rar4_headers.validate_header_crc(archive_data, block_header)) {
				return .{
					.is_valid = false,
					.depth = .structural,
					.family = .rar15,
					.has_encrypted_content = has_encrypted,
					.circumvented_trivial_protection = false,
					.error_message = "header CRC mismatch",
					.block_count = block_count,
					.file_count = file_count,
				};
			}
		}

		// Check for encrypted content
		switch (block) {
			.main => |m| {
				if (m.flags.password) has_encrypted = true;
			},
			.file => |f| {
				file_count += 1;
				const fflags = rar4_headers.parse_file_flags(f.block.flags);
				if (fflags.password) has_encrypted = true;
			},
			else => {},
		}
	}

	if (block_count == 0) {
		return invalid_result(.structural, .rar15, "no blocks found");
	}

	// If encrypted, cap at structural
	if (has_encrypted) {
		return .{
			.is_valid = true,
			.depth = .structural,
			.family = .rar15,
			.has_encrypted_content = true,
			.circumvented_trivial_protection = false,
			.error_message = null,
			.block_count = block_count,
			.file_count = file_count,
		};
	}

	return .{
		.is_valid = true,
		.depth = .structural,
		.family = .rar15,
		.has_encrypted_content = false,
		.circumvented_trivial_protection = false,
		.error_message = null,
		.block_count = block_count,
		.file_count = file_count,
	};
}

// ============================================================================
// RAR4 payload validation (store-method files)
// ============================================================================

fn validate_rar4_payload(data: []const u8, sig_offset: usize) ValidationResult {
	// First do structural validation
	var structural = validate_rar4_structural(data, sig_offset);
	if (!structural.is_valid) return structural;
	if (structural.has_encrypted_content) return structural;

	// Now walk again to check payload CRCs for store-method files
	var iter = rar4_headers.walk_blocks(data[sig_offset..]);
	var checked_payload = false;

	while (true) {
		const maybe_block = iter.next() catch break;
		const block = maybe_block orelse break;

		switch (block) {
			.file => |f| {
				// Only verify store-method files (method == 0)
				if (f.method == 0 and f.packed_size > 0) {
					// The packed data follows the header
					const header_end = f.block.header_offset + f.block.head_size;
					const payload_start = sig_offset + header_end;
					const payload_end = payload_start + f.packed_size;
					if (payload_end <= data.len) {
						const payload = data[payload_start..payload_end];
						const computed_crc = integrity.crc32(payload);
						if (computed_crc != f.file_crc) {
							structural.is_valid = false;
							structural.depth = .full;
							structural.error_message = "payload CRC32 mismatch";
							return structural;
						}
						checked_payload = true;
					}
				}
			},
			else => {},
		}
	}

	if (checked_payload) {
		structural.depth = .full;
	}

	return structural;
}

// ============================================================================
// RAR5 structural validation
// ============================================================================

fn validate_rar5_structural(data: []const u8, sig_offset: usize, sig_len: u8) ValidationResult {
	// RAR5 blocks start after the 8-byte signature
	const block_start = sig_offset + sig_len;
	if (block_start >= data.len) {
		return invalid_result(.structural, .rar50, "no data after signature");
	}

	var iter = rar5_headers.walk_blocks(data[block_start..]);
	var block_count: u32 = 0;
	var file_count: u32 = 0;
	var has_encrypted: bool = false;

	while (true) {
		const maybe_block = iter.next() catch {
			return .{
				.is_valid = false,
				.depth = .structural,
				.family = .rar50,
				.has_encrypted_content = has_encrypted,
				.circumvented_trivial_protection = false,
				.error_message = "block parse error",
				.block_count = block_count,
				.file_count = file_count,
			};
		};
		const block = maybe_block orelse break;

		block_count += 1;

		// Validate header CRC for each block
		const block_header = switch (block) {
			.main => |m| m.header,
			.file => |f| f.header,
			.service => |s| s.header,
			.crypt => |h| h,
			.end_archive => |e| e.header,
			.unknown => |h| h,
		};

		if (!rar5_headers.validate_header_crc(data[block_start..], block_header)) {
			return .{
				.is_valid = false,
				.depth = .structural,
				.family = .rar50,
				.has_encrypted_content = has_encrypted,
				.circumvented_trivial_protection = false,
				.error_message = "header CRC mismatch",
				.block_count = block_count,
				.file_count = file_count,
			};
		}

		// Check for encrypted content and end of archive
		switch (block) {
			.crypt => has_encrypted = true,
			.file => |f| {
				file_count += 1;
				_ = f;
			},
			.service => {
				// services are also counted in block_count but not file_count
			},
			.end_archive => break, // stop after END block (volumes may have trailing padding)
			else => {},
		}
	}

	if (block_count == 0) {
		return invalid_result(.structural, .rar50, "no blocks found");
	}

	if (has_encrypted) {
		return .{
			.is_valid = true,
			.depth = .structural,
			.family = .rar50,
			.has_encrypted_content = true,
			.circumvented_trivial_protection = false,
			.error_message = null,
			.block_count = block_count,
			.file_count = file_count,
		};
	}

	return .{
		.is_valid = true,
		.depth = .structural,
		.family = .rar50,
		.has_encrypted_content = false,
		.circumvented_trivial_protection = false,
		.error_message = null,
		.block_count = block_count,
		.file_count = file_count,
	};
}

// ============================================================================
// RAR5 payload validation (store-method files)
// ============================================================================

fn validate_rar5_payload(data: []const u8, sig_offset: usize, sig_len: u8) ValidationResult {
	// First do structural validation
	var structural = validate_rar5_structural(data, sig_offset, sig_len);
	if (!structural.is_valid) return structural;
	if (structural.has_encrypted_content) return structural;

	// Walk again to verify payload CRCs for store-method files
	const block_start = sig_offset + sig_len;
	var iter = rar5_headers.walk_blocks(data[block_start..]);
	var checked_payload = false;

	while (true) {
		const maybe_block = iter.next() catch break;
		const block = maybe_block orelse break;

		switch (block) {
			.file => |f| {
				// Skip split files — payload CRC covers the full file, not chunks
				if (f.header.flags.split_before or f.header.flags.split_after) continue;

				// Only verify store-method files
				if (f.compression.method == 0) {
					if (f.header.data_size) |ds| {
						// data_size bytes follow the header
						const total_header = 4 + f.header.crc_data_len;
						const payload_start = block_start + f.header.header_start + total_header;
						const payload_end = payload_start + @as(usize, @intCast(ds));
						if (payload_end <= data.len) {
							const payload = data[payload_start..payload_end];

							// Check CRC32 if present
							if (f.has_crc32) {
								const computed_crc = integrity.crc32(payload);
								if (computed_crc != f.data_crc32.?) {
									structural.is_valid = false;
									structural.depth = .full;
									structural.error_message = "payload CRC32 mismatch";
									return structural;
								}
								checked_payload = true;
							}

							// Check BLAKE2sp hash if present in extra records
							if (f.extra_data) |extra_bytes| {
								const alloc = std.heap.page_allocator;
								const extra_records = rar5_headers.parse_extra_records(extra_bytes, alloc) catch {
									// If we can't parse extra records, skip BLAKE2sp check
									continue;
								};
								defer alloc.free(extra_records);

								if (rar5_headers.extract_blake2sp_hash(extra_records)) |expected_hash| {
									var computed_hash: [32]u8 = undefined;
									integrity.blake2sp(payload, &computed_hash);
									if (!std.mem.eql(u8, &computed_hash, &expected_hash)) {
										structural.is_valid = false;
										structural.depth = .full;
										structural.error_message = "payload BLAKE2sp mismatch";
										return structural;
									}
									checked_payload = true;
								}
							}
						}
					}
				}
			},
			.end_archive => break, // stop after END block (volumes may have trailing padding)
			else => {},
		}
	}

	if (checked_payload) {
		structural.depth = .full;
	}

	return structural;
}

// ============================================================================
// Main entry point
// ============================================================================

/// Validate a RAR archive at all applicable depth levels.
///
/// 1. Signature detection — identifies format family
/// 2. Structural validation — walks blocks, validates header CRCs
/// 3. Full validation — verifies payload CRC32 for store-method files
pub fn validate(data: []const u8) ValidationResult {
	// Step 1: Detect format
	const fmt = detect_mod.detect_format(data, 0);

	const family = fmt.family orelse {
		return invalid_result(.signature, null, "no recognized RAR signature");
	};

	// Step 2+3: Validate based on family
	return switch (family) {
		.rar14 => .{
			// No structural parser for RAR 1.4 yet
			.is_valid = true,
			.depth = .signature,
			.family = .rar14,
			.has_encrypted_content = false,
			.circumvented_trivial_protection = false,
			.error_message = null,
			.block_count = 0,
			.file_count = 0,
		},
		.rar15 => validate_rar4_payload(data, fmt.signature_offset),
		.rar50 => validate_rar5_payload(data, fmt.signature_offset, fmt.signature_len),
	};
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// --- Test helpers for constructing RAR4 archives ---

/// Build a RAR4 block with correct CRC16. Returns number of bytes written.
fn build_rar4_block(out: []u8, header_type: u8, flags: u16, extra_data: []const u8) usize {
	const head_size: u16 = @intCast(7 + extra_data.len);
	// Fill in type, flags, head_size (bytes 2-6)
	out[2] = header_type;
	write_u16_le(out, 3, flags);
	write_u16_le(out, 5, head_size);
	// Copy extra data
	if (extra_data.len > 0) {
		@memcpy(out[7..][0..extra_data.len], extra_data);
	}
	// Compute CRC16 over bytes [2..head_size]
	const crc = integrity.crc16(out[2..head_size]);
	write_u16_le(out, 0, crc);
	return head_size;
}

/// Build a RAR5 block with correct CRC32. Returns number of bytes written.
/// body is the type-specific content to embed in the header.
fn build_rar5_block(out: []u8, block_type: u7, flags_raw: u64, body: []const u8) usize {
	return build_rar5_block_with_data(out, block_type, flags_raw, body, null);
}

/// Build a RAR5 block with correct CRC32 and optional data area.
/// Returns total bytes written (header + data).
fn build_rar5_block_with_data(out: []u8, block_type: u7, flags_raw: u64, body: []const u8, data_area: ?[]const u8) usize {
	// Build the "after CRC" portion: header_size_vint + contents
	var tmp: [512]u8 = undefined;
	var pos: usize = 0;

	// Build contents (everything after header_size vint)
	var contents: [512]u8 = undefined;
	var cpos: usize = 0;

	// header_type vint
	cpos += encode_vint(@intCast(block_type), contents[cpos..]);
	// header_flags vint
	cpos += encode_vint(flags_raw, contents[cpos..]);
	// body
	@memcpy(contents[cpos..][0..body.len], body);
	cpos += body.len;

	// Encode header_size vint (covers type through end of header area)
	pos += encode_vint(cpos, tmp[pos..]);
	// Append contents
	@memcpy(tmp[pos..][0..cpos], contents[0..cpos]);
	pos += cpos;

	// Compute CRC32 over tmp[0..pos]
	const crc = integrity.crc32(tmp[0..pos]);

	// Write CRC32 as LE u32
	std.mem.writeInt(u32, out[0..4], crc, .little);
	// Write the rest of the header
	@memcpy(out[4..][0..pos], tmp[0..pos]);
	const header_total = 4 + pos;

	// Write optional data area
	if (data_area) |da| {
		@memcpy(out[header_total..][0..da.len], da);
		return header_total + da.len;
	}

	return header_total;
}

// --- Test 1: validate returns invalid for unrecognized data ---

test "validate returns invalid for unrecognized data" {
	const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };
	const result = validate(&data);
	try testing.expect(!result.is_valid);
	try testing.expectEqual(ValidationDepth.signature, result.depth);
	try testing.expectEqual(@as(?detect_mod.RarFamily, null), result.family);
	try testing.expect(result.error_message != null);
}

// --- Test 2: validate returns valid signature for RAR 1.4 data ---

test "validate returns valid signature for RAR 1.4 data" {
	const data = detect_mod.RAR14_SIG ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 };
	const result = validate(&data);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.signature, result.depth);
	try testing.expectEqual(detect_mod.RarFamily.rar14, result.family.?);
	try testing.expectEqual(@as(u32, 0), result.block_count);
}

// --- Test 3: validate returns valid structural for well-formed RAR4 archive ---

test "validate returns valid structural for well-formed RAR4 archive" {
	// Construct: RAR15 signature + mark block + main block + end_archive block
	var archive: [128]u8 = undefined;
	var pos: usize = 0;

	// RAR 1.5 signature (7 bytes) — this is also the mark block
	@memcpy(archive[pos..][0..7], &detect_mod.RAR15_SIG);
	pos += 7;

	// The mark block is the signature itself. For RAR4, the "mark" block header
	// is: CRC=0x6152, type=0x72, flags=0x1A21, size=0x0007
	// These are the actual bytes in the 7-byte signature.
	// So the walk_blocks starting at offset 0 of archive data (the signature offset)
	// will parse the mark block from those 7 bytes.

	// Main block: type=0x73, flags=0x0000, head_size=7
	const main_len = build_rar4_block(archive[pos..], 0x73, 0x0000, &.{});
	pos += main_len;

	// End archive block: type=0x7B, flags=0x0000, head_size=7
	const end_len = build_rar4_block(archive[pos..], 0x7B, 0x0000, &.{});
	pos += end_len;

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.depth);
	try testing.expectEqual(detect_mod.RarFamily.rar15, result.family.?);
	try testing.expectEqual(@as(u32, 3), result.block_count); // mark + main + end
	try testing.expectEqual(@as(u32, 0), result.file_count);
	try testing.expect(!result.has_encrypted_content);
}

// --- Test 4: validate returns invalid structural for corrupted RAR4 header CRC ---

test "validate returns invalid structural for corrupted RAR4 header CRC" {
	var archive: [128]u8 = undefined;
	var pos: usize = 0;

	// RAR 1.5 signature
	@memcpy(archive[pos..][0..7], &detect_mod.RAR15_SIG);
	pos += 7;

	// Main block with correct CRC
	const main_len = build_rar4_block(archive[pos..], 0x73, 0x0000, &.{});
	pos += main_len;

	// End archive block with correct CRC
	const end_len = build_rar4_block(archive[pos..], 0x7B, 0x0000, &.{});

	// Corrupt the end block's type byte (at offset pos+2)
	archive[pos + 2] = 0xFF;

	pos += end_len;

	const result = validate(archive[0..pos]);
	try testing.expect(!result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.depth);
	try testing.expectEqual(detect_mod.RarFamily.rar15, result.family.?);
	try testing.expect(std.mem.eql(u8, result.error_message.?, "header CRC mismatch"));
}

// --- Test 5: validate returns valid structural for well-formed RAR5 archive ---

test "validate returns valid structural for well-formed RAR5 archive" {
	var archive: [256]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature (8 bytes)
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block: type=1, flags=0, body=archive_flags(0)
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body); // archive_flags = 0
	const main_len = build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);
	pos += main_len;

	// End block: type=5, flags=0, body=end_flags(0)
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body); // end_flags = 0
	const end_len = build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);
	pos += end_len;

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.depth);
	try testing.expectEqual(detect_mod.RarFamily.rar50, result.family.?);
	try testing.expectEqual(@as(u32, 2), result.block_count); // main + end
	try testing.expectEqual(@as(u32, 0), result.file_count);
	try testing.expect(!result.has_encrypted_content);
}

// --- Test 6: validate returns invalid structural for corrupted RAR5 header CRC ---

test "validate returns invalid structural for corrupted RAR5 header CRC" {
	var archive: [256]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	const main_len = build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);
	pos += main_len;

	// End block — will corrupt after building
	const end_start = pos;
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	const end_len = build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	// Corrupt a byte inside the end header (after CRC32 field)
	archive[end_start + 5] ^= 0xFF;

	pos += end_len;

	const result = validate(archive[0..pos]);
	try testing.expect(!result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.depth);
	try testing.expectEqual(detect_mod.RarFamily.rar50, result.family.?);
	try testing.expect(std.mem.eql(u8, result.error_message.?, "header CRC mismatch"));
}

// --- Test 7: validate counts blocks and files correctly ---

test "validate counts blocks and files correctly" {
	var archive: [512]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);

	// File block 1: minimal file with no optional fields
	{
		var body: [128]u8 = undefined;
		var bpos: usize = 0;
		bpos += encode_vint(0, body[bpos..]); // file_flags = 0
		bpos += encode_vint(100, body[bpos..]); // unpacked_size
		bpos += encode_vint(0x20, body[bpos..]); // attributes
		bpos += encode_vint(0, body[bpos..]); // compression_info (store)
		bpos += encode_vint(0, body[bpos..]); // host_os
		bpos += encode_vint(5, body[bpos..]); // name_length
		@memcpy(body[bpos..][0..5], "a.txt");
		bpos += 5;
		pos += build_rar5_block(archive[pos..], 2, 0, body[0..bpos]);
	}

	// File block 2
	{
		var body: [128]u8 = undefined;
		var bpos: usize = 0;
		bpos += encode_vint(0, body[bpos..]); // file_flags = 0
		bpos += encode_vint(200, body[bpos..]); // unpacked_size
		bpos += encode_vint(0x20, body[bpos..]); // attributes
		bpos += encode_vint(0, body[bpos..]); // compression_info (store)
		bpos += encode_vint(0, body[bpos..]); // host_os
		bpos += encode_vint(5, body[bpos..]); // name_length
		@memcpy(body[bpos..][0..5], "b.txt");
		bpos += 5;
		pos += build_rar5_block(archive[pos..], 2, 0, body[0..bpos]);
	}

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(@as(u32, 4), result.block_count); // main + 2 files + end
	try testing.expectEqual(@as(u32, 2), result.file_count);
}

// --- Test 8: validate detects encrypted content ---

test "validate detects encrypted content" {
	// RAR5 archive with a CRYPT block (type=4)
	var archive: [256]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);

	// Crypt block (type=4) — minimal body, just needs to be parseable
	// The crypt block only has a header parsed (no body parsing beyond header)
	pos += build_rar5_block(archive[pos..], 4, 0, &.{});

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.depth);
	try testing.expect(result.has_encrypted_content);
}

// --- Test 9: validate returns full depth for store-method file with valid CRC ---

test "validate returns full depth for store-method file with valid CRC" {
	var archive: [512]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);

	// File block with store method, CRC32, and data area
	const payload = "Hello, RAR5!";
	const payload_crc = integrity.crc32(payload);
	{
		var body: [128]u8 = undefined;
		var bpos: usize = 0;
		// file_flags: has_crc32 (0x04)
		bpos += encode_vint(0x04, body[bpos..]);
		// unpacked_size
		bpos += encode_vint(payload.len, body[bpos..]);
		// attributes
		bpos += encode_vint(0x20, body[bpos..]);
		// data_crc32 (u32 LE)
		std.mem.writeInt(u32, body[bpos..][0..4], payload_crc, .little);
		bpos += 4;
		// compression_info = 0 (store)
		bpos += encode_vint(0, body[bpos..]);
		// host_os = 0
		bpos += encode_vint(0, body[bpos..]);
		// name_length + name
		bpos += encode_vint(8, body[bpos..]);
		@memcpy(body[bpos..][0..8], "test.txt");
		bpos += 8;

		// flags_raw=0x02 means HFL_DATA is set, which triggers data_size reading
		// We need to build a header with both HFL_DATA flag and data_size in the header
		// Use build_rar5_block_with_data which handles the data area
		// But the header itself needs the data flag set.
		// Let me construct this more carefully.

		// Actually, the header flags need HFL_DATA (0x02) set, and data_size vint
		// is part of the header. Let me build this manually.

		// Build the "after CRC" portion
		var tmp: [512]u8 = undefined;
		var tpos: usize = 0;

		// Build contents (everything after header_size vint)
		var contents: [512]u8 = undefined;
		var cpos: usize = 0;

		// header_type = 2 (file)
		cpos += encode_vint(2, contents[cpos..]);
		// header_flags = 0x02 (HFL_DATA)
		cpos += encode_vint(0x02, contents[cpos..]);
		// data_size (because HFL_DATA is set)
		cpos += encode_vint(payload.len, contents[cpos..]);
		// body (file-specific fields)
		@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
		cpos += bpos;

		// header_size vint (size from header_type onward)
		tpos += encode_vint(cpos, tmp[tpos..]);
		@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
		tpos += cpos;

		// CRC32 over header_size_vint + contents
		const crc = integrity.crc32(tmp[0..tpos]);

		// Write CRC32
		std.mem.writeInt(u32, archive[pos..][0..4], crc, .little);
		@memcpy(archive[pos + 4 ..][0..tpos], tmp[0..tpos]);
		pos += 4 + tpos;

		// Write data area (the payload)
		@memcpy(archive[pos..][0..payload.len], payload);
		pos += payload.len;
	}

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.full, result.depth);
	try testing.expectEqual(detect_mod.RarFamily.rar50, result.family.?);
	try testing.expectEqual(@as(u32, 3), result.block_count); // main + file + end
	try testing.expectEqual(@as(u32, 1), result.file_count);
	try testing.expect(!result.has_encrypted_content);
}

// --- Test: validate returns invalid at full depth for payload CRC mismatch ---

test "validate returns invalid at full depth for payload CRC mismatch" {
	var archive: [512]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);

	// File block with store method, CRC32, and WRONG data
	const payload = "Hello, RAR5!";
	const wrong_crc: u32 = 0xDEADBEEF; // intentionally wrong
	{
		var body: [128]u8 = undefined;
		var bpos: usize = 0;
		bpos += encode_vint(0x04, body[bpos..]); // file_flags: has_crc32
		bpos += encode_vint(payload.len, body[bpos..]); // unpacked_size
		bpos += encode_vint(0x20, body[bpos..]); // attributes
		std.mem.writeInt(u32, body[bpos..][0..4], wrong_crc, .little); // wrong CRC
		bpos += 4;
		bpos += encode_vint(0, body[bpos..]); // compression_info (store)
		bpos += encode_vint(0, body[bpos..]); // host_os
		bpos += encode_vint(8, body[bpos..]); // name_length
		@memcpy(body[bpos..][0..8], "test.txt");
		bpos += 8;

		var tmp: [512]u8 = undefined;
		var tpos: usize = 0;
		var contents: [512]u8 = undefined;
		var cpos: usize = 0;

		cpos += encode_vint(2, contents[cpos..]); // type = file
		cpos += encode_vint(0x02, contents[cpos..]); // flags = HFL_DATA
		cpos += encode_vint(payload.len, contents[cpos..]); // data_size
		@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
		cpos += bpos;

		tpos += encode_vint(cpos, tmp[tpos..]);
		@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
		tpos += cpos;

		const crc = integrity.crc32(tmp[0..tpos]);
		std.mem.writeInt(u32, archive[pos..][0..4], crc, .little);
		@memcpy(archive[pos + 4 ..][0..tpos], tmp[0..tpos]);
		pos += 4 + tpos;

		@memcpy(archive[pos..][0..payload.len], payload);
		pos += payload.len;
	}

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	const result = validate(archive[0..pos]);
	try testing.expect(!result.is_valid);
	try testing.expectEqual(ValidationDepth.full, result.depth);
	try testing.expect(std.mem.eql(u8, result.error_message.?, "payload CRC32 mismatch"));
}

// --- Test: BLAKE2sp payload verification passes with correct hash ---

test "validate checks BLAKE2sp hash from extra record" {
	var archive: [1024]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);

	// File block with store method, CRC32, BLAKE2sp extra record, and data area
	const payload = "Hello, BLAKE2sp!";
	const payload_crc = integrity.crc32(payload);
	var blake2sp_hash: [32]u8 = undefined;
	integrity.blake2sp(payload, &blake2sp_hash);
	{
		var body: [256]u8 = undefined;
		var bpos: usize = 0;
		// file_flags: has_crc32 (0x04)
		bpos += encode_vint(0x04, body[bpos..]);
		// unpacked_size
		bpos += encode_vint(payload.len, body[bpos..]);
		// attributes
		bpos += encode_vint(0x20, body[bpos..]);
		// data_crc32 (u32 LE)
		std.mem.writeInt(u32, body[bpos..][0..4], payload_crc, .little);
		bpos += 4;
		// compression_info = 0 (store)
		bpos += encode_vint(0, body[bpos..]);
		// host_os = 0
		bpos += encode_vint(0, body[bpos..]);
		// name_length + name
		bpos += encode_vint(8, body[bpos..]);
		@memcpy(body[bpos..][0..8], "test.txt");
		bpos += 8;

		// Build extra area: HASH record (type=0x02) with BLAKE2sp hash
		var extra_area: [64]u8 = undefined;
		var epos: usize = 0;
		// Extra record: field_size = 1 (type vint) + 1 (hash_type vint) + 32 (hash) = 34
		epos += encode_vint(34, extra_area[epos..]); // field_size
		epos += encode_vint(0x02, extra_area[epos..]); // field_type = HASH
		epos += encode_vint(0x00, extra_area[epos..]); // hash_type = BLAKE2sp
		@memcpy(extra_area[epos..][0..32], &blake2sp_hash);
		epos += 32;

		// Build header manually with HFL_EXTRA (0x01) + HFL_DATA (0x02) = 0x03
		var tmp: [512]u8 = undefined;
		var tpos: usize = 0;
		var contents: [512]u8 = undefined;
		var cpos: usize = 0;

		// header_type = 2 (file)
		cpos += encode_vint(2, contents[cpos..]);
		// header_flags = 0x03 (HFL_EXTRA | HFL_DATA)
		cpos += encode_vint(0x03, contents[cpos..]);
		// extra_size (because HFL_EXTRA is set)
		cpos += encode_vint(epos, contents[cpos..]);
		// data_size (because HFL_DATA is set)
		cpos += encode_vint(payload.len, contents[cpos..]);
		// body (file-specific fields)
		@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
		cpos += bpos;
		// extra area
		@memcpy(contents[cpos..][0..epos], extra_area[0..epos]);
		cpos += epos;

		// header_size vint
		tpos += encode_vint(cpos, tmp[tpos..]);
		@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
		tpos += cpos;

		// CRC32 over header_size_vint + contents
		const crc = integrity.crc32(tmp[0..tpos]);

		// Write CRC32
		std.mem.writeInt(u32, archive[pos..][0..4], crc, .little);
		@memcpy(archive[pos + 4 ..][0..tpos], tmp[0..tpos]);
		pos += 4 + tpos;

		// Write data area (the payload)
		@memcpy(archive[pos..][0..payload.len], payload);
		pos += payload.len;
	}

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.full, result.depth);
	try testing.expectEqual(detect_mod.RarFamily.rar50, result.family.?);
}

// --- Test: BLAKE2sp payload verification fails with wrong hash ---

test "validate returns invalid for BLAKE2sp hash mismatch" {
	var archive: [1024]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);

	// File block with store method, correct CRC32, but WRONG BLAKE2sp hash
	const payload = "Hello, BLAKE2sp!";
	const payload_crc = integrity.crc32(payload);
	var wrong_hash: [32]u8 = undefined;
	@memset(&wrong_hash, 0xAA); // intentionally wrong hash
	{
		var body: [256]u8 = undefined;
		var bpos: usize = 0;
		// file_flags: has_crc32 (0x04)
		bpos += encode_vint(0x04, body[bpos..]);
		// unpacked_size
		bpos += encode_vint(payload.len, body[bpos..]);
		// attributes
		bpos += encode_vint(0x20, body[bpos..]);
		// data_crc32 (u32 LE) — correct CRC so we get past CRC32 check
		std.mem.writeInt(u32, body[bpos..][0..4], payload_crc, .little);
		bpos += 4;
		// compression_info = 0 (store)
		bpos += encode_vint(0, body[bpos..]);
		// host_os = 0
		bpos += encode_vint(0, body[bpos..]);
		// name_length + name
		bpos += encode_vint(8, body[bpos..]);
		@memcpy(body[bpos..][0..8], "test.txt");
		bpos += 8;

		// Build extra area: HASH record with wrong BLAKE2sp hash
		var extra_area: [64]u8 = undefined;
		var epos: usize = 0;
		epos += encode_vint(34, extra_area[epos..]); // field_size
		epos += encode_vint(0x02, extra_area[epos..]); // field_type = HASH
		epos += encode_vint(0x00, extra_area[epos..]); // hash_type = BLAKE2sp
		@memcpy(extra_area[epos..][0..32], &wrong_hash);
		epos += 32;

		// Build header manually with HFL_EXTRA (0x01) + HFL_DATA (0x02) = 0x03
		var tmp: [512]u8 = undefined;
		var tpos: usize = 0;
		var contents: [512]u8 = undefined;
		var cpos: usize = 0;

		cpos += encode_vint(2, contents[cpos..]); // type = file
		cpos += encode_vint(0x03, contents[cpos..]); // flags = HFL_EXTRA | HFL_DATA
		cpos += encode_vint(epos, contents[cpos..]); // extra_size
		cpos += encode_vint(payload.len, contents[cpos..]); // data_size
		@memcpy(contents[cpos..][0..bpos], body[0..bpos]);
		cpos += bpos;
		@memcpy(contents[cpos..][0..epos], extra_area[0..epos]);
		cpos += epos;

		tpos += encode_vint(cpos, tmp[tpos..]);
		@memcpy(tmp[tpos..][0..cpos], contents[0..cpos]);
		tpos += cpos;

		const crc = integrity.crc32(tmp[0..tpos]);
		std.mem.writeInt(u32, archive[pos..][0..4], crc, .little);
		@memcpy(archive[pos + 4 ..][0..tpos], tmp[0..tpos]);
		pos += 4 + tpos;

		@memcpy(archive[pos..][0..payload.len], payload);
		pos += payload.len;
	}

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	const result = validate(archive[0..pos]);
	try testing.expect(!result.is_valid);
	try testing.expectEqual(ValidationDepth.full, result.depth);
	try testing.expect(std.mem.eql(u8, result.error_message.?, "payload BLAKE2sp mismatch"));
}

// --- Test: RAR4 encrypted archive detection ---

test "validate detects RAR4 encrypted content via main password flag" {
	var archive: [128]u8 = undefined;
	var pos: usize = 0;

	// RAR 1.5 signature (also the mark block)
	@memcpy(archive[pos..][0..7], &detect_mod.RAR15_SIG);
	pos += 7;

	// Main block with password flag (0x0040)
	const main_len = build_rar4_block(archive[pos..], 0x73, 0x0040, &.{});
	pos += main_len;

	// End archive block
	const end_len = build_rar4_block(archive[pos..], 0x7B, 0x0000, &.{});
	pos += end_len;

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.depth);
	try testing.expect(result.has_encrypted_content);
}
