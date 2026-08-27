//! Validation policy — validates RAR archives and reports facts.
//!
//! Reports: valid/invalid, error type, whether encrypted content was present.

const std = @import("std");
const detect_mod = @import("detect.zig");
const dispatch = @import("decompress/dispatch.zig");
const sink = @import("decompress/sink.zig");
const integrity = @import("integrity.zig");
const rar4_headers = @import("rar4_headers.zig");
const rar5_headers = @import("rar5_headers.zig");
const reader_mod = @import("reader.zig");

// ============================================================================
// Types
// ============================================================================

pub const ValidationResult = struct {
	is_valid: bool,
	family: ?detect_mod.RarFamily,
	has_encrypted_content: bool,

	error_message: ?[]const u8,
	block_count: u32,
	file_count: u32,

	/// Entries whose payload could NOT be checked, and were therefore skipped.
	/// Today that means encrypted entries; no password support exists.
	///
	/// Exists because `is_valid` plus `has_encrypted_content` cannot distinguish
	/// "2 of 2 entries encrypted, nothing checked" from "1 of 2 encrypted, the
	/// other verified" — both looked identical. This does not claim a verdict;
	/// it states what was skipped, which is the minimum the project's no-silent-
	/// skip invariant requires.
	///
	/// INTERIM. The full fix is the could-not-verify outcome in
	/// RAR_SPECIFICATION.md §5.1; see PLAN.md §4h. Defaults to 0 because a path
	/// that skips nothing correctly reports nothing skipped — but any NEW skip
	/// path must increment this, or it reintroduces the silent skip.
	unverified_entry_count: u32 = 0,
};

// ============================================================================
// Helpers
// ============================================================================

const encode_vint = reader_mod.encode_vint;

/// How far to scan for a RAR signature behind a self-extracting stub.
///
/// Matches the reference's `MAXSFXSIZE` (unrar `rardefs.hpp`), which allocates a
/// buffer of exactly this size and scans it byte-by-byte for the signature.
///
/// `validate()` previously passed 0 here, disabling a scan that `detect_format`
/// already implements and that §5 of RAR_SPECIFICATION.md requires. A stub
/// prepended to a good archive produced "no recognized RAR signature" — a damage
/// claim about an archive unrar tests clean.
const MAX_SFX_SCAN: usize = 0x400000;

/// Write a u16 in little-endian into a buffer at the given offset.
fn write_u16_le(buf: []u8, offset: usize, val: u16) void {
	std.mem.writeInt(u16, buf[offset..][0..2], val, .little);
}

/// Write a u32 in little-endian into a buffer at the given offset.
fn write_u32_le(buf: []u8, offset: usize, val: u32) void {
	std.mem.writeInt(u32, buf[offset..][0..4], val, .little);
}

fn invalid_result(family: ?detect_mod.RarFamily, msg: []const u8) ValidationResult {
	return .{
		.is_valid = false,
		.family = family,
		.has_encrypted_content = false,

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
				.family = .rar15,
				.has_encrypted_content = has_encrypted,
		
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
					.family = .rar15,
					.has_encrypted_content = has_encrypted,
			
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
			.end_archive => {},
			else => {},
		}
	}

	if (block_count == 0) {
		return invalid_result(.rar15, "no blocks found");
	}

	// NOTE: unlike RAR5, a missing end-of-archive block is NOT an error here.
	//
	// RAR5 mandates the terminator, so its absence there means truncation. RAR
	// 2.x does not: archives produced by the original RAR 2.90 frequently just
	// end after the last file, and `unrar t` reports them "All OK" (see the
	// rar2_v20_* fixtures and tests/generate_rar2_fixtures.sh). Requiring it
	// rejected perfectly good old archives — a false positive, and on precisely
	// the vintage files a file-integrity tool most needs to be believed about.
	//
	// Truncation of RAR4 is still detected, by the checks that actually observe
	// missing bytes rather than a missing terminator: a payload declared past
	// end-of-archive, and a block header that fails to parse. Verified against
	// the oracle — cutting a v20 fixture short still reports INVALID while
	// unrar reports an error, and the intact archive stays VALID.

	return .{
		.is_valid = true,
		.family = .rar15,
		.has_encrypted_content = has_encrypted,

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
	// NOTE: deliberately no archive-wide bail-out on encryption. Encryption is a
	// PER-ENTRY property; skipping the whole archive because one entry is
	// encrypted abandoned checks we could run on every other entry. See the
	// matching note in validate_rar5_payload.

	// Now walk again to check payload CRCs for store-method files
	var iter = rar4_headers.walk_blocks(data[sig_offset..]);

	// One decoder for the whole walk. In a solid archive the entries share a
	// single continuous stream, so this must outlive any one of them.
	var solid_session: ?dispatch.SolidSession = null;
	defer if (solid_session) |*s| s.deinit();

	while (true) {
		// FAIL, don't stop. This is the payload walk; the structural walk above
		// already parsed the same blocks, so an error here means the two
		// disagree — and the only safe reading of that is "we cannot verify the
		// rest", not "the rest is fine". Breaking silently left every remaining
		// entry unchecked and still returned the structural VALID.
		//
		// Currently unreachable: both walks run the same iterator over the same
		// bytes, so the structural pass would have failed first. Measured — 0
		// hits across the whole fixture corpus, 8 byte-mutations and 8
		// truncations of each, and the unit suite's exhaustive single-byte and
		// every-position-truncation sweeps. It is hardened anyway because the
		// failure direction of a stale assumption here is a silent PASS.
		const maybe_block = iter.next() catch {
			structural.is_valid = false;
			structural.error_message = "block parse error during payload verification";
			return structural;
		};
		const block = maybe_block orelse break;

		switch (block) {
			.file => |f| {
				const fflags = rar4_headers.parse_file_flags(f.block.flags);
				// Split files: the CRC covers the whole file, not this chunk.
				if (fflags.split_before or fflags.split_after) continue;
				// Encrypted ENTRY: its payload cannot be checked without the
				// password. Skip this entry only — every other entry in the
				// archive is still verified — and COUNT it, so the result can
				// say what went unchecked instead of quietly omitting it.
				if (fflags.password) {
					structural.unverified_entry_count += 1;
					continue;
				}
				if (f.packed_size == 0) continue; // directory / empty entry

				const header_end = f.block.header_offset + f.block.head_size;
				const payload_start = sig_offset + header_end;
				const payload_end = payload_start + f.packed_size;

				// PRECISION: a payload declared past the end of the archive
				// means the file is truncated. Skipping it reported VALID.
				if (payload_end > data.len) {
					structural.is_valid = false;
					structural.error_message = "declared payload extends beyond end of archive (truncated)";
					return structural;
				}
				const payload = data[payload_start..payload_end];

				if (f.method == 0) {
					// Store — CRC the raw bytes.
					if (integrity.crc32(payload) != f.file_crc) {
						structural.is_valid = false;
						structural.error_message = "payload CRC32 mismatch";
						return structural;
					}
				} else {
					// Compressed — decompress, then CRC. This branch did not
					// exist: validation only handled method == 0, so compressed
					// RAR4 archives received NO payload verification at all and
					// were reported VALID however damaged they were (0/6 against
					// the unrar oracle, versus 6/6 for store-method).
					const alloc = std.heap.page_allocator;
					var verify = decodeEntryRar4(
						&solid_session,
						alloc,
						payload,
						f.unpacked_size,
						f.unpack_version,
						f.block.flags,
						fflags.solid,
					) catch {
						structural.is_valid = false;
						structural.error_message = "decompression failed during validation";
						return structural;
					};

					if (verify.crc32() != f.file_crc) {
						structural.is_valid = false;
						structural.error_message = "payload CRC32 mismatch";
						return structural;
					}
				}
			},
			else => {},
		}
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
		return invalid_result(.rar50, "no data after signature");
	}

	var iter = rar5_headers.walk_blocks(data[block_start..]);
	var block_count: u32 = 0;
	var file_count: u32 = 0;
	var has_encrypted: bool = false;
	var saw_end_of_archive: bool = false;

	while (true) {
		const maybe_block = iter.next() catch {
			return .{
				.is_valid = false,
				.family = .rar50,
				.has_encrypted_content = has_encrypted,
		
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
				.family = .rar50,
				.has_encrypted_content = has_encrypted,
		
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
				if (rar5_headers.extra_has_encryption(f.extra_data)) has_encrypted = true;
			},
			.service => {
				// services are also counted in block_count but not file_count
			},
			.end_archive => {
				saw_end_of_archive = true;
				break; // stop after END block (volumes may have trailing padding)
			},
			else => {},
		}
	}

	if (block_count == 0) {
		return invalid_result(.rar50, "no blocks found");
	}

	// PRECISION: a RAR5 archive terminates with an end-of-archive block. Running
	// out of data without one means the archive was cut short. The block walk
	// alone cannot see this: a truncation that removes whole trailing blocks
	// leaves every surviving block individually well-formed, so the iterator
	// reports a clean end and validation used to return VALID. unrar reports
	// "Unexpected end of archive" for exactly this input.
	if (!saw_end_of_archive) {
		return .{
			.is_valid = false,
			.family = .rar50,
			.has_encrypted_content = has_encrypted,
			.error_message = "archive ends without an end-of-archive block (truncated)",
			.block_count = block_count,
			.file_count = file_count,
		};
	}

	return .{
		.is_valid = true,
		.family = .rar50,
		.has_encrypted_content = has_encrypted,

		.error_message = null,
		.block_count = block_count,
		.file_count = file_count,
	};
}

// ============================================================================
// Sequential decode across entries (solid-archive support)
// ============================================================================

/// Decode one compressed entry through a decoder that PERSISTS across entries.
///
/// Every compressed entry goes through here, solid or not. Routing only solid
/// entries through the session would not work: the first entry of a solid group
/// carries solid=false, and if that one were decoded by a throwaway decoder the
/// shared window would never be built and every later entry would decode against
/// an empty history — the original bug, just moved.
///
/// Passing non-solid entries through costs nothing (a solid=false entry resets
/// the decoder to exactly the state a fresh one would have) and saves a window
/// allocation per entry.
///
/// The session is rebuilt when an entry needs a different unpack version or a
/// larger dictionary than the one it was sized for.
/// Returns the running hashes rather than the bytes: validation wants the
/// verdict, never the payload. Nothing the size of a decoded entry is allocated
/// on this path — peak memory is the LZ window plus ~600 bytes of hash state.
fn decodeEntryRar5(
    session: *?dispatch.SolidSession,
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    compression: rar5_headers.CompressionInfo,
    want_blake: bool,
) !sink.VerifySink {
    if (session.*) |*s| {
        if (!s.acceptsRar5(compression)) {
            s.deinit();
            session.* = null;
        }
    }
    if (session.* == null) {
        session.* = try dispatch.SolidSession.initRar5(allocator, compression);
    }

    var vs = sink.VerifySink.init(want_blake);
    if (unpacked_size == 0) return vs;

    try session.*.?.decodeFile(packed_data, unpacked_size, compression.solid, vs.sink());
    return vs;
}

/// RAR4 counterpart of `decodeEntryRar5`; see that function for why non-solid
/// entries go through the session too.
fn decodeEntryRar4(
    session: *?dispatch.SolidSession,
    allocator: std.mem.Allocator,
    packed_data: []const u8,
    unpacked_size: u64,
    unpack_version: u8,
    file_flags_raw: u16,
    solid: bool,
) !sink.VerifySink {
    if (session.*) |*s| {
        if (!s.acceptsRar4(unpack_version, file_flags_raw)) {
            s.deinit();
            session.* = null;
        }
    }
    if (session.* == null) {
        session.* = try dispatch.SolidSession.initRar4(allocator, unpack_version, file_flags_raw);
    }

    // RAR4 has no BLAKE2sp — CRC32 is the only checksum the format carries.
    var vs = sink.VerifySink.init(false);
    if (unpacked_size == 0) return vs;

    try session.*.?.decodeFile(packed_data, unpacked_size, solid, vs.sink());
    return vs;
}

// ============================================================================
// RAR5 payload validation (store-method files)
// ============================================================================

fn validate_rar5_payload(data: []const u8, sig_offset: usize, sig_len: u8) ValidationResult {
	// First do structural validation
	var structural = validate_rar5_structural(data, sig_offset, sig_len);
	if (!structural.is_valid) return structural;
	// NO archive-wide bail-out on encryption.
	//
	// This used to be `if (structural.has_encrypted_content) return structural;`
	// — returning a result whose is_valid was already true. Encryption is a
	// PER-ENTRY property, so one encrypted entry silenced payload verification
	// for every other entry in the archive, including unencrypted ones whose
	// CRC32 we could check perfectly well:
	//
	//     unrar t -pSECRET  ->  plain.txt - checksum error, Total errors: 1
	//     rarz t            ->  VALID
	//
	// A false pass on PROVEN damage in READABLE data. Encrypted entries are now
	// skipped individually, below, and everything else is still verified.
	if (!structural.is_valid) return structural;

	// Walk again to verify payload CRCs for store-method files
	const block_start = sig_offset + sig_len;
	var iter = rar5_headers.walk_blocks(data[block_start..]);

	// One decoder for the whole walk. In a solid archive the entries share a
	// single continuous stream, so this must outlive any one of them.
	var solid_session: ?dispatch.SolidSession = null;
	defer if (solid_session) |*s| s.deinit();

	while (true) {
		// FAIL, don't stop — see the matching note in validate_rar4_payload.
		// Stopping here left every remaining entry unverified while still
		// returning the structural VALID.
		const maybe_block = iter.next() catch {
			structural.is_valid = false;
			structural.error_message = "block parse error during payload verification";
			return structural;
		};
		const block = maybe_block orelse break;

		switch (block) {
			.file => |f| {
				// Skip split files — payload CRC covers the full file, not chunks
				if (f.header.flags.split_before or f.header.flags.split_after) continue;
				// Encrypted ENTRY: its payload cannot be checked without the
				// password. Skip this entry only — every other entry in the
				// archive is still verified — and COUNT it, so the result can
				// say what went unchecked instead of quietly omitting it.
				if (rar5_headers.extra_has_encryption(f.extra_data)) {
					structural.unverified_entry_count += 1;
					continue;
				}

				// PRECISION OVER FORGIVENESS: an entry claiming N > 0 unpacked
				// bytes must declare packed bytes we can actually read, or its
				// stored checksum is unverifiable. Previously a missing/zero
				// data size meant every check below was skipped and the archive
				// was still reported VALID — "nothing to check" silently became
				// "nothing wrong". That is how rarz blessed its own corrupt
				// output (headers with packed_size == 0) while unrar reported
				// "checksum error" on the same file. Being unable to verify is
				// a FAILURE, not a pass.
				//
				// unpacked_size == 0 is the legitimate empty-file/directory
				// case and is intentionally still allowed through.
				if (f.unpacked_size > 0) {
					const declared = f.header.data_size orelse 0;
					if (declared == 0) {
						structural.is_valid = false;
						structural.error_message = "file header declares unpacked data but no packed data size; payload cannot be verified";
						return structural;
					}
				}

				if (f.compression.method == 0) {
					// Store-method file — verify raw payload directly
					if (f.header.data_size) |ds| {
						const total_header = 4 + f.header.crc_data_len;
						const payload_start = block_start + f.header.header_start + total_header;
						const payload_end = payload_start + @as(usize, @intCast(ds));
						// PRECISION: a payload declared past the end of the
						// archive means the file is truncated. Skipping it (the
						// old behaviour) reported a truncated archive as VALID.
						if (payload_end > data.len) {
							structural.is_valid = false;
							structural.error_message = "declared payload extends beyond end of archive (truncated)";
							return structural;
						}
						if (payload_end <= data.len) {
							const payload = data[payload_start..payload_end];

							// Check CRC32 if present
							if (f.has_crc32) {
								const computed_crc = integrity.crc32(payload);
								if (computed_crc != f.data_crc32.?) {
									structural.is_valid = false;
									structural.error_message = "payload CRC32 mismatch";
									return structural;
								}
							}

							// Check BLAKE2sp hash if present (non-allocating raw extraction)
							if (rar5_headers.extract_blake2sp_hash_raw(f.extra_data)) |expected_hash| {
								var computed_hash: [32]u8 = undefined;
								integrity.blake2sp(payload, &computed_hash);
								if (!std.mem.eql(u8, &computed_hash, &expected_hash)) {
									structural.is_valid = false;
									structural.error_message = "payload BLAKE2sp mismatch";
									return structural;
								}
							}
						}
					}
				} else {
					// Compressed file — decompress then verify CRC
					if (f.header.data_size) |ds| {
						const total_header = 4 + f.header.crc_data_len;
						const payload_start = block_start + f.header.header_start + total_header;
						const payload_end = payload_start + @as(usize, @intCast(ds));
						// PRECISION: a payload declared past the end of the
						// archive means the file is truncated. Skipping it (the
						// old behaviour) reported a truncated archive as VALID.
						if (payload_end > data.len) {
							structural.is_valid = false;
							structural.error_message = "declared payload extends beyond end of archive (truncated)";
							return structural;
						}
						if (payload_end <= data.len) {
							const packed_data = data[payload_start..payload_end];
							const alloc = std.heap.page_allocator;

							// Resolve the expected BLAKE2sp BEFORE decoding: the
							// hash has to be computed as the bytes stream past,
							// so we cannot wait until afterwards to decide
							// whether we wanted it.
							//
							// The non-allocating `_raw` form also retires a
							// silent-skip path — the old code called
							// `parse_extra_records(...) catch { continue; }`,
							// so a malformed extra record skipped BLAKE2sp
							// verification entirely and the entry still passed.
							// "Could not check" must never read as "nothing
							// wrong".
							const expected_blake = rar5_headers.extract_blake2sp_hash_raw(f.extra_data);

							var verify = decodeEntryRar5(
								&solid_session,
								alloc,
								packed_data,
								f.unpacked_size,
								f.compression,
								expected_blake != null,
							) catch {
								structural.is_valid = false;
								structural.error_message = "decompression failed during validation";
								return structural;
							};

							// CRC32 check
							if (f.has_crc32) {
								if (verify.crc32() != f.data_crc32.?) {
									structural.is_valid = false;
									structural.error_message = "payload CRC32 mismatch";
									return structural;
								}
							}

							if (expected_blake) |expected_hash| {
								var computed_hash: [32]u8 = undefined;
								verify.blake2sp(&computed_hash);
								if (!std.mem.eql(u8, &computed_hash, &expected_hash)) {
									structural.is_valid = false;
									structural.error_message = "payload BLAKE2sp mismatch";
									return structural;
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

	return structural;
}

// ============================================================================
// Multi-volume validation
// ============================================================================

/// Internal type for tracking file chunks across volumes.
const VolumeFileChunk = struct {
	volume_idx: usize,
	data_ptr: [*]const u8,
	data_len: usize,
	name: []const u8,
	unpacked_size: u64,
	compression: rar5_headers.CompressionInfo,
	data_crc32: ?u32,
	has_crc32: bool,
	split_before: bool,
	split_after: bool,
};

/// One RAR4 file chunk within a volume. RAR4 carries no BLAKE2sp and its
/// compression is described by (unpack_version, method, raw flags) rather than
/// RAR5's CompressionInfo, so it needs its own chunk type.
const Rar4VolumeChunk = struct {
	data_ptr: [*]const u8,
	data_len: usize,
	name: []const u8,
	unpacked_size: u64,
	unpack_version: u8,
	method: u8,
	flags_raw: u16,
	file_crc: u32,
	split_before: bool,
	split_after: bool,
};

/// Validate a multi-volume RAR4 (1.5-4.x) archive.
///
/// Mirrors the RAR5 path: structurally validate every volume, then concatenate
/// each split file's packed chunks across volumes and check the reassembled
/// content against its stored CRC32.
///
/// Like RAR5, the authoritative whole-file CRC lives in the part where the file
/// COMPLETES (split_after == false); earlier parts carry a per-segment value.
/// Verified against the producer: `unrar lt` reports `Pack-CRC32` for the
/// leading parts and a plain `CRC32` only on the completing one.
fn validate_volumes_rar4(volumes: []const []const u8) ValidationResult {
	const alloc = std.heap.page_allocator;

	var total_block_count: u32 = 0;
	var unverified: u32 = 0;
	for (volumes) |vol_data| {
		const fmt = detect_mod.detect_format(vol_data, MAX_SFX_SCAN);
		const family = fmt.family orelse {
			return invalid_result(null, "no recognized RAR signature in volume");
		};
		if (family != .rar15) {
			return invalid_result(family, "volume set mixes RAR families");
		}
		const structural = validate_rar4_structural(vol_data, fmt.signature_offset);
		if (!structural.is_valid) return structural;
		total_block_count += structural.block_count;
	}

	var chunks: std.ArrayList(Rar4VolumeChunk) = .empty;
	defer chunks.deinit(alloc);

	for (volumes) |vol_data| {
		const fmt = detect_mod.detect_format(vol_data, MAX_SFX_SCAN);
		const sig_offset = fmt.signature_offset;
		var iter = rar4_headers.walk_blocks(vol_data[sig_offset..]);

		while (true) {
			// FAIL, don't stop — see the RAR5 path. Abandoning the walk
			// mid-volume drops the remaining files from `chunks` entirely, and
			// the merge below would then verify only what it happened to
			// collect and report VALID.
			const maybe_block = iter.next() catch {
				return invalid_result(.rar15, "block parse error while collecting volume file chunks");
			};
			const block = maybe_block orelse break;

			switch (block) {
				.file => |f| {
					const fflags = rar4_headers.parse_file_flags(f.block.flags);
					if (rar4_headers.is_directory_entry(f)) continue;
					// Encrypted entry: counted, not silently dropped.
					if (fflags.password) {
						unverified += 1;
						continue;
					}
					if (f.packed_size == 0) continue;

					const payload_start = sig_offset + f.block.header_offset + f.block.head_size;
					const payload_end = payload_start + f.packed_size;
					// A chunk declaring more payload than its volume holds means
					// that volume is truncated. Dropping it would remove the file
					// from the verification set and report VALID.
					if (payload_end > vol_data.len) {
						return invalid_result(.rar15, "declared payload extends beyond end of volume (truncated)");
					}
					chunks.append(alloc, .{
						.data_ptr = vol_data[payload_start..payload_end].ptr,
						.data_len = @intCast(f.packed_size),
						.name = f.file_name,
						.unpacked_size = f.unpacked_size,
						.unpack_version = f.unpack_version,
						.method = f.method,
						.flags_raw = f.block.flags,
						.file_crc = f.file_crc,
						.split_before = fflags.split_before,
						.split_after = fflags.split_after,
					}) catch {
						return invalid_result(.rar15, "out of memory collecting file chunks");
					};
				},
				.end_archive => break,
				else => {},
			}
		}
	}

	var file_count: u32 = 0;
	var i: usize = 0;
	while (i < chunks.items.len) {
		const first = chunks.items[i];
		if (first.split_before) {
			i += 1; // consumed by the merge below
			continue;
		}
		file_count += 1;

		// Find where this file completes.
		var total_packed: usize = first.data_len;
		var j: usize = i + 1;
		if (first.split_after) {
			while (j < chunks.items.len) {
				const cont = chunks.items[j];
				if (!cont.split_before) break;
				if (!std.mem.eql(u8, first.name, cont.name)) break;
				total_packed += cont.data_len;
				j += 1;
				if (!cont.split_after) break;
			}
		}
		const last = chunks.items[j - 1];

		if (total_packed == 0) {
			i = j;
			continue;
		}

		// Contiguous packed bytes: the decoder and the CRC both need the file's
		// stream whole, and it physically spans volumes.
		const concat = alloc.alloc(u8, total_packed) catch {
			return invalid_result(.rar15, "out of memory merging split file");
		};
		defer alloc.free(concat);
		var offset: usize = 0;
		var k: usize = i;
		while (k < j) : (k += 1) {
			const c = chunks.items[k];
			@memcpy(concat[offset..][0..c.data_len], c.data_ptr[0..c.data_len]);
			offset += c.data_len;
		}

		if (first.method == 0) {
			if (integrity.crc32(concat) != last.file_crc) {
				return rar4_volume_failure(total_block_count, file_count, unverified, "payload CRC32 mismatch");
			}
		} else {
			// A split file cannot share a solid session with its neighbours here
			// (its stream is reassembled), so decode it standalone — into the
			// hashing sink, so memory stays the window + packed reassembly and
			// never the decoded size.
			var vs = sink.VerifySink.init(false);
			dispatch.decompressRar4ToSink(
				alloc,
				concat,
				first.unpacked_size,
				first.unpack_version,
				first.method,
				first.flags_raw,
				vs.sink(),
			) catch {
				return rar4_volume_failure(total_block_count, file_count, unverified, "decompression failed during validation");
			};
			if (vs.len != first.unpacked_size or vs.crc32() != last.file_crc) {
				return rar4_volume_failure(total_block_count, file_count, unverified, "payload CRC32 mismatch");
			}
		}

		i = j;
	}

	return .{
		.is_valid = true,
		.family = .rar15,
		.has_encrypted_content = unverified > 0,
		.error_message = null,
		.block_count = total_block_count,
		.file_count = file_count,
		.unverified_entry_count = unverified,
	};
}

fn rar4_volume_failure(blocks: u32, files: u32, unverified: u32, msg: []const u8) ValidationResult {
	return .{
		.is_valid = false,
		.family = .rar15,
		.has_encrypted_content = unverified > 0,
		.error_message = msg,
		.block_count = blocks,
		.file_count = files,
		.unverified_entry_count = unverified,
	};
}

/// Validate a multi-volume RAR5 archive.
///
/// Validates structural integrity of each volume, then concatenates split file
/// data across volumes and verifies CRC32 of the reassembled content.
pub fn validate_volumes(volumes: []const []const u8) ValidationResult {
	if (volumes.len == 0) {
		return invalid_result(null, "empty volumes list");
	}

	// Single volume: delegate to standard validate
	if (volumes.len == 1) {
		return validate(volumes[0]);
	}

	const alloc = std.heap.page_allocator;

	// Step 1: Structural validation of each volume, all must be RAR5
	var total_block_count: u32 = 0;
	for (volumes) |vol_data| {
		const fmt = detect_mod.detect_format(vol_data, MAX_SFX_SCAN);
		const family = fmt.family orelse {
			return invalid_result(null, "no recognized RAR signature in volume");
		};
		// RAR4 volume sets (.part01.rar / .r00 …) are among the most common
		// archives in the wild. Returning INVALID for them claimed positive
		// evidence of corruption that did not exist, on archives unrar tests
		// clean — a missing capability reported as the user's data being bad.
		if (family == .rar15) {
			return validate_volumes_rar4(volumes);
		}
		if (family != .rar50) {
			return invalid_result(family, "multi-volume validation only supported for RAR4 and RAR5");
		}

		// Structural validation
		const structural = validate_rar5_structural(vol_data, fmt.signature_offset, fmt.signature_len);
		if (!structural.is_valid) return structural;
		if (structural.has_encrypted_content) return structural;
		total_block_count += structural.block_count;
	}

	// Step 2: Collect file chunks from all volumes
	var chunks: std.ArrayList(VolumeFileChunk) = .empty;
	defer chunks.deinit(alloc);

	for (volumes, 0..) |vol_data, vi| {
		const fmt = detect_mod.detect_format(vol_data, MAX_SFX_SCAN);
		const block_start = fmt.signature_offset + fmt.signature_len;
		var iter = rar5_headers.walk_blocks(vol_data[block_start..]);

		while (true) {
			// FAIL, don't stop. Abandoning the walk mid-volume leaves the
			// remaining files out of `chunks` entirely, and step 3 then verifies
			// only what it happens to have collected and reports VALID. A file
			// that vanished from consideration must not read as a file that
			// passed.
			const maybe_block = iter.next() catch {
				return invalid_result(.rar50, "block parse error while collecting volume file chunks");
			};
			const block = maybe_block orelse break;

			switch (block) {
				.file => |f| {
					// Compute absolute offset of packed data in this volume
					const total_header = 4 + f.header.crc_data_len;
					const payload_start = block_start + f.header.header_start + total_header;
					const data_size = f.header.data_size orelse 0;
					const payload_end = payload_start + @as(usize, @intCast(data_size));

					// PRECISION: a chunk declaring more payload than its volume
					// physically holds means that volume is truncated. The old
					// code simply did not append it — so the file silently left
					// the verification set, the surviving chunks checked out,
					// and the archive was reported VALID. Absence of evidence
					// became evidence of correctness, on the exact input a
					// file-integrity product exists to catch.
					//
					// The single-volume path has always failed this case; the
					// multi-volume path did not.
					if (payload_end > vol_data.len) {
						return invalid_result(.rar50, "declared payload extends beyond end of volume (truncated)");
					}
					{
						chunks.append(alloc, .{
							.volume_idx = vi,
							.data_ptr = vol_data[payload_start..payload_end].ptr,
							.data_len = @intCast(data_size),
							.name = f.name,
							.unpacked_size = f.unpacked_size,
							.compression = f.compression,
							.data_crc32 = f.data_crc32,
							.has_crc32 = f.has_crc32,
							.split_before = f.header.flags.split_before,
							.split_after = f.header.flags.split_after,
						}) catch {
							return invalid_result(.rar50, "out of memory collecting file chunks");
						};
					}
				},
				.end_archive => break,
				else => {},
			}
		}
	}

	// Step 3: Walk chunks, merge split files, verify CRCs
	var file_count: u32 = 0;
	var i: usize = 0;
	while (i < chunks.items.len) {
		const first = chunks.items[i];

		// Skip split_before chunks (consumed by merge loop below)
		if (first.split_before) {
			i += 1;
			continue;
		}

		file_count += 1;

		if (!first.split_after) {
			// Complete file in single volume — validate inline
			if (first.data_len > 0 and first.has_crc32) {
				const payload = first.data_ptr[0..first.data_len];

				if (first.compression.method == 0) {
					// Store method — CRC the raw data
					const computed_crc = integrity.crc32(payload);
					if (computed_crc != first.data_crc32.?) {
						return .{
							.is_valid = false,
							.family = .rar50,
							.has_encrypted_content = false,
							.error_message = "payload CRC32 mismatch",
							.block_count = total_block_count,
							.file_count = file_count,
						};
					}
				} else {
					// Compressed — decode into the hashing sink; see the
					// split-file branch below for why nothing is materialised.
					var whole_vs = sink.VerifySink.init(false);
					dispatch.decompressRar5ToSink(
						alloc,
						payload,
						first.unpacked_size,
						first.compression,
						whole_vs.sink(),
					) catch {
						return .{
							.is_valid = false,
							.family = .rar50,
							.has_encrypted_content = false,
							.error_message = "decompression failed during validation",
							.block_count = total_block_count,
							.file_count = file_count,
						};
					};

					const computed_crc = whole_vs.crc32();
					if (whole_vs.len != first.unpacked_size or computed_crc != first.data_crc32.?) {
						return .{
							.is_valid = false,
							.family = .rar50,
							.has_encrypted_content = false,
							.error_message = "payload CRC32 mismatch",
							.block_count = total_block_count,
							.file_count = file_count,
						};
					}
				}
			}
			i += 1;
			continue;
		}

		// Split file — collect all continuation chunks
		var total_packed: usize = first.data_len;
		var j: usize = i + 1;
		while (j < chunks.items.len) {
			const cont = chunks.items[j];
			if (!cont.split_before) break;
			if (!std.mem.eql(u8, first.name, cont.name)) break;

			total_packed += cont.data_len;
			j += 1;
			if (!cont.split_after) break;
		}

		// RAR5 stores the authoritative full-file hash in the LAST volume part —
		// the one where the file completes (split_after == false). Earlier parts
		// carry a different (per-segment) CRC, so validating against the first
		// part's CRC produces a false "payload CRC32 mismatch". unRAR does the
		// same: extract.cpp gates the check on `!Arc.FileHead.SplitAfter` and
		// compares against the current (last) FileHead.FileHash. chunks.items[j-1]
		// is that last part.
		const last = chunks.items[j - 1];

		// Verify CRC if present (use the last part's hash — see above)
		if (last.has_crc32 and total_packed > 0) {
			// Concatenate packed data from all chunks
			const concat = alloc.alloc(u8, total_packed) catch {
				return invalid_result(.rar50, "out of memory merging split file");
			};
			defer alloc.free(concat);

			var offset: usize = 0;
			// First chunk
			@memcpy(concat[offset..][0..first.data_len], first.data_ptr[0..first.data_len]);
			offset += first.data_len;
			// Continuation chunks
			var k: usize = i + 1;
			while (k < j) : (k += 1) {
				const cont = chunks.items[k];
				@memcpy(concat[offset..][0..cont.data_len], cont.data_ptr[0..cont.data_len]);
				offset += cont.data_len;
			}

			if (first.compression.method == 0) {
				// Store method — CRC the concatenated raw data
				const computed_crc = integrity.crc32(concat);
				if (computed_crc != last.data_crc32.?) {
					return .{
						.is_valid = false,
						.family = .rar50,
						.has_encrypted_content = false,
						.error_message = "payload CRC32 mismatch",
						.block_count = total_block_count,
						.file_count = file_count,
					};
				}
			} else {
				// Compressed — decode the concatenated packed data INTO the
				// hashing sink, so memory stays the window + packed reassembly
				// and never the decoded size.
				var split_vs = sink.VerifySink.init(false);
				dispatch.decompressRar5ToSink(
					alloc,
					concat,
					first.unpacked_size,
					first.compression,
					split_vs.sink(),
				) catch {
					return .{
						.is_valid = false,
						.family = .rar50,
						.has_encrypted_content = false,
						.error_message = "decompression failed during validation",
						.block_count = total_block_count,
						.file_count = file_count,
					};
				};

				const computed_crc = split_vs.crc32();
				if (split_vs.len != first.unpacked_size or computed_crc != last.data_crc32.?) {
					return .{
						.is_valid = false,
						.family = .rar50,
						.has_encrypted_content = false,
						.error_message = "payload CRC32 mismatch",
						.block_count = total_block_count,
						.file_count = file_count,
					};
				}
			}
		}

		i = j;
		continue;
	}

	return .{
		.is_valid = true,
		.family = .rar50,
		.has_encrypted_content = false,
		.error_message = null,
		.block_count = total_block_count,
		.file_count = file_count,
	};
}

// ============================================================================
// Main entry point
// ============================================================================

/// Validate a RAR archive.
///
/// 1. Signature detection — identifies format family
/// 2. Structural validation — walks blocks, validates header CRCs
/// 3. Payload validation — verifies CRC32/BLAKE2sp of file content
pub fn validate(data: []const u8) ValidationResult {
	// Step 1: Detect format
	const fmt = detect_mod.detect_format(data, MAX_SFX_SCAN);

	const family = fmt.family orelse {
		return invalid_result(null, "no recognized RAR signature");
	};

	// Header encryption (-hp) makes the BLOCKS themselves ciphertext. Walking
	// them as if they were headers produced "header CRC mismatch" — a damage
	// claim about an intact archive we merely cannot read. Detect it first and
	// say what it is.
	if (headers_encrypted(data, fmt, family)) {
		return .{
			.is_valid = false,
			.family = family,
			.has_encrypted_content = true,
			.error_message = "archive headers are encrypted (-hp); contents cannot be verified without a password",
			.block_count = 0,
			.file_count = 0,
		};
	}

	// Step 2+3: Validate based on family
	return switch (family) {
		// RAR 1.4 has no parser here, so nothing about the file has been
		// examined. That must REFUSE, not pass.
		//
		// This branch used to return `.is_valid = true` with the note "No
		// structural parser for RAR 1.4 yet" — so a RAR 1.4 signature followed
		// by pure noise was reported VALID while unrar reported it damaged. Of
		// every silent-skip path in this file that was the worst, because it
		// blessed the entire format sight-unseen.
		//
		// RAR 1.4 is genuinely different, not merely old: its file header has
		// its own layout (SIZEOF_FILEHEAD14) and its checksum is a 16-bit
		// HASH_RAR14, not a CRC32 — a distinct algorithm with no final XOR
		// (unrar hash.cpp: `if (Type==HASH_RAR14) CurCRC32=0;` and Result
		// without the `^0xffffffff`). Parsing it as RAR4 would read the wrong
		// fields, so refusing is also the only currently-correct answer.
		//
		// INVALID overstates the case for an intact RAR 1.4 archive, and the
		// could-not-verify outcome in PLAN 4c is where this belongs once it
		// exists. Until then, refusing to bless beats a false pass: the
		// dangerous direction is blessing something bad.
		.rar14 => .{
			.is_valid = false,
			.family = .rar14,
			.has_encrypted_content = false,

			.error_message = "RAR 1.4 archives are not supported; contents cannot be verified",
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

	try testing.expectEqual(@as(?detect_mod.RarFamily, null), result.family);
	try testing.expect(result.error_message != null);
}

// --- Test 2: RAR 1.4 is DETECTED but not blessed ---

test "validate detects the RAR 1.4 family without claiming the archive is valid" {
	// This test previously asserted `result.is_valid` and was named "returns
	// valid signature for RAR 1.4 data" — conflating "the signature is
	// recognised" with "the archive is intact". That conflation is what let
	// validate() bless every RAR 1.4 file without reading a byte of it, and the
	// test would have blocked the fix.
	//
	// Recognising the family is genuinely useful and is still asserted. The
	// verdict is the part that was wrong.
	const data = detect_mod.RAR14_SIG ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 };
	const result = validate(&data);

	try testing.expectEqual(detect_mod.RarFamily.rar14, result.family.?);
	try testing.expectEqual(@as(u32, 0), result.block_count);

	// Nothing was parsed, so nothing may be claimed.
	try testing.expect(!result.is_valid);
	try testing.expect(result.error_message != null);
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
		// unpacked_size = 0 (legitimately empty file). This fixture exists to
		// test BLOCK/FILE COUNTING, not payload verification. It previously
		// claimed 100 unpacked bytes while building the block with header flags
		// = 0, i.e. no data area and no payload at all — a contradictory
		// archive that real RAR5 cannot represent and that unrar rejects.
		// Validation now (correctly) refuses to call that VALID, so the fixture
		// states what it actually contains. Do not "restore" a nonzero size
		// here without also emitting a data area and payload bytes.
		bpos += encode_vint(0, body[bpos..]); // unpacked_size
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
		bpos += encode_vint(0, body[bpos..]); // unpacked_size (see note on file 1)
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
	// MHD_PASSWORD on the MAIN header IS -hp for RAR4: every following block
	// is ciphertext. The old expectation here (is_valid = true) blessed an
	// archive whose contents cannot even be enumerated. The truthful verdict
	// is not-valid + encrypted + a message naming the reason — and never a
	// CRC complaint, which would claim damage we cannot know about.
	try testing.expect(!result.is_valid);
	try testing.expect(result.has_encrypted_content);
	const msg = result.error_message orelse return error.TestUnexpectedResult;
	try testing.expect(std.mem.indexOf(u8, msg, "encrypted") != null);
	try testing.expect(std.mem.indexOf(u8, msg, "CRC") == null);
}

test "validate detects RAR5 per-file encryption record (type 0x01)" {
	// RAR5 archive with a FILE block carrying a file-encryption extra record
	// (type 0x01) — the `-p` data-encryption case, which has NO CRYPT block.
	var archive: [256]u8 = undefined;
	var pos: usize = 0;

	// RAR5 signature
	@memcpy(archive[pos..][0..8], &detect_mod.RAR50_SIG);
	pos += 8;

	// Main block
	var main_body: [16]u8 = undefined;
	const main_body_len = encode_vint(0, &main_body);
	pos += build_rar5_block(archive[pos..], 1, 0, main_body[0..main_body_len]);

	// Build the FILE block body. Header flag 0x0001 (extra) is set, so the
	// body begins with extra_size, then the file fields, then the extra area.
	const name = "x";

	// Extra area: one encryption record (type 0x01) with 2 data bytes.
	// field_size = 1 (type vint) + 2 (data) = 3
	var extra_area: [8]u8 = undefined;
	var ea: usize = 0;
	ea += encode_vint(3, extra_area[ea..]); // field_size
	ea += encode_vint(0x01, extra_area[ea..]); // field_type = ENCRYPTION
	extra_area[ea] = 0xAA;
	ea += 1;
	extra_area[ea] = 0xBB;
	ea += 1;

	var file_body: [64]u8 = undefined;
	var fb: usize = 0;
	fb += encode_vint(ea, file_body[fb..]); // extra_size (header-level)
	fb += encode_vint(0, file_body[fb..]); // file_flags (no dir/mtime/crc)
	fb += encode_vint(0, file_body[fb..]); // unpacked_size
	fb += encode_vint(0, file_body[fb..]); // attributes
	fb += encode_vint(0, file_body[fb..]); // compression_info
	fb += encode_vint(0, file_body[fb..]); // host_os
	fb += encode_vint(name.len, file_body[fb..]); // name_length
	@memcpy(file_body[fb..][0..name.len], name);
	fb += name.len;
	@memcpy(file_body[fb..][0..ea], extra_area[0..ea]); // extra area
	fb += ea;

	// FILE block (type=2) with extra flag 0x0001.
	pos += build_rar5_block(archive[pos..], 2, 0x0001, file_body[0..fb]);

	// End block
	var end_body: [16]u8 = undefined;
	const end_body_len = encode_vint(0, &end_body);
	pos += build_rar5_block(archive[pos..], 5, 0, end_body[0..end_body_len]);

	const result = validate(archive[0..pos]);
	try testing.expect(result.is_valid);
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

	try testing.expect(std.mem.eql(u8, result.error_message.?, "payload BLAKE2sp mismatch"));
}

// --- Test: RAR4 encrypted archive detection ---

test "validate detects RAR4 encrypted content via main password flag" {
	var archive: [128]u8 = undefined;
	var pos: usize = 0;

	// RAR 1.5 signature (also the mark block)
	@memcpy(archive[pos..][0..7], &detect_mod.RAR15_SIG);
	pos += 7;

	// Main block with MHD_PASSWORD (0x0080). This said 0x0040, which is
	// MHD_PROTECT (recovery record) — the test passed only because
	// parse_main_flags had the same off-by-one-bit mapping.
	const main_len = build_rar4_block(archive[pos..], 0x73, 0x0080, &.{});
	pos += main_len;

	// End archive block
	const end_len = build_rar4_block(archive[pos..], 0x7B, 0x0000, &.{});
	pos += end_len;

	const result = validate(archive[0..pos]);
	// MHD_PASSWORD on MAIN is RAR4's -hp: the blocks that follow are
	// ciphertext. Truthful verdict: not-valid + encrypted + a message naming
	// the reason, never a CRC damage claim.
	try testing.expect(!result.is_valid);
	try testing.expect(result.has_encrypted_content);
	const msg = result.error_message orelse return error.TestUnexpectedResult;
	try testing.expect(std.mem.indexOf(u8, msg, "encrypted") != null);
	try testing.expect(std.mem.indexOf(u8, msg, "CRC") == null);
}

// --- Test: validate returns full depth for compressed file with valid CRC ---

test "validate returns full depth for compressed file with valid CRC" {
	const writer = @import("writer.zig");
	const alloc = testing.allocator;

	const file_data = "The quick brown fox jumps over the lazy dog. The quick brown fox!";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	var buf: [16384]u8 = undefined;
	const archive_len = try writer.write_archive_compressed(alloc, &entries, &buf, 3);

	const result = validate(buf[0..archive_len]);
	try testing.expect(result.is_valid);

	try testing.expectEqual(detect_mod.RarFamily.rar50, result.family.?);
	try testing.expectEqual(@as(u32, 1), result.file_count);
}

// --- Test: validate returns invalid at full depth for compressed payload CRC mismatch ---

test "validate returns invalid at full depth for compressed payload CRC mismatch" {
	const writer = @import("writer.zig");
	const alloc = testing.allocator;

	const file_data = "The quick brown fox jumps over the lazy dog. The quick brown fox!";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	var buf: [16384]u8 = undefined;
	const archive_len = try writer.write_archive_compressed(alloc, &entries, &buf, 3);

	// Corrupt a byte in the compressed data area (last byte before end block)
	// The end block is at the very end; corrupt a byte a few bytes before it
	buf[archive_len - 20] ^= 0xFF;

	const result = validate(buf[0..archive_len]);
	try testing.expect(!result.is_valid);

	try testing.expect(result.error_message != null);
}

// --- Test: corrupted archives must return clean errors, never abort/crash ---

test "validate handles truncated RAR5 (signature only, no blocks)" {
	// Just the 8-byte signature with nothing after it
	const data = detect_mod.RAR50_SIG;
	const result = validate(&data);
	try testing.expect(!result.is_valid);
}

test "validate handles RAR5 signature followed by garbage" {
	var data: [64]u8 = undefined;
	@memcpy(data[0..8], &detect_mod.RAR50_SIG);
	// Fill rest with garbage that looks like invalid vint/header data
	@memset(data[8..], 0xFF);
	const result = validate(&data);
	// Must return without crashing — valid or invalid doesn't matter, no abort
	_ = result;
}

test "validate handles RAR5 signature followed by zeros" {
	var data: [64]u8 = undefined;
	@memcpy(data[0..8], &detect_mod.RAR50_SIG);
	@memset(data[8..], 0x00);
	const result = validate(&data);
	_ = result;
}

test "validate handles RAR4 signature followed by garbage" {
	var data: [64]u8 = undefined;
	@memcpy(data[0..7], &detect_mod.RAR15_SIG);
	@memset(data[7..], 0xFF);
	const result = validate(&data);
	_ = result;
}

test "validate handles RAR5 with header claiming enormous data_size" {
	// Build a valid RAR5 archive then corrupt the header to claim huge sizes
	const writer = @import("writer.zig");
	const file_data = "hello";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0,
		.is_directory = false,
	}};

	var buf: [4096]u8 = undefined;
	const archive_len = try writer.write_archive(&entries, &buf);

	// Corrupt bytes in the middle of the archive (header area)
	// to create nonsensical vint values
	var corrupted = buf;
	for (12..@min(archive_len, 24)) |i| {
		corrupted[i] = 0xFF;
	}
	const result = validate(corrupted[0..archive_len]);
	_ = result; // must not crash
}

test "validate handles every single-byte corruption of a valid RAR5 archive" {
	// Build a valid archive, then try corrupting every single byte position
	// and verify validate() never crashes (returns is_valid true or false)
	const writer = @import("writer.zig");
	const file_data = "The quick brown fox";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	var original: [4096]u8 = undefined;
	const archive_len = try writer.write_archive(&entries, &original);

	// Corrupt each byte position one at a time
	for (0..archive_len) |i| {
		var corrupted = original;
		corrupted[i] ^= 0xFF;
		const result = validate(corrupted[0..archive_len]);
		// Must not crash. Either valid or invalid is fine.
		_ = result;
	}
}

test "validate handles every single-byte corruption of a compressed RAR5 archive" {
	const writer = @import("writer.zig");
	const alloc = testing.allocator;
	const file_data = "The quick brown fox jumps over the lazy dog. The quick brown fox!";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	var original: [16384]u8 = undefined;
	const archive_len = try writer.write_archive_compressed(alloc, &entries, &original, 3);

	// Corrupt each byte position one at a time
	for (0..archive_len) |i| {
		var corrupted = original;
		corrupted[i] ^= 0xFF;
		const result = validate(corrupted[0..archive_len]);
		_ = result; // must not crash
	}
}

test "mixed encryption: the result says HOW MANY entries went unverified" {
	// Detecting the situation is not the same as reporting it. Before this,
	// `policy.validate` returned the identical result for
	//   "2 of 2 entries encrypted, nothing checked"  and
	//   "1 of 2 entries encrypted, the other verified"
	// — both `is_valid=true, has_encrypted_content=true`. A consumer could not
	// tell a fully-opaque archive from a mostly-checked one.
	//
	// Full compliance (the could-not-verify outcome of RAR_SPECIFICATION §5.1)
	// is deferred; see PLAN.md. This count is the honest interim: it does not
	// claim a verdict, it states what was skipped.
	const mixed: []const u8 = @embedFile("rar5_encrypted_mixed");

	const r = validate(mixed);
	try testing.expect(r.is_valid);
	try testing.expect(r.has_encrypted_content);
	// Exactly one of the two entries is encrypted.
	try testing.expectEqual(@as(u32, 1), r.unverified_entry_count);
	try testing.expectEqual(@as(u32, 2), r.file_count);
}

test "no encryption: nothing is reported as unverified" {
	// The count must not be noise: an ordinary archive verifies every entry.
	const plain: []const u8 = @embedFile("rar5_store");
	const r = validate(plain);
	try testing.expect(r.is_valid);
	try testing.expectEqual(@as(u32, 0), r.unverified_entry_count);
}

test "mixed encryption: damage in an UNENCRYPTED entry must be caught" {
	// One encrypted entry used to disable payload verification for the WHOLE
	// archive:
	//
	//     if (structural.has_encrypted_content) return structural;  // is_valid=true
	//
	// So an unencrypted entry with a smashed payload — a CRC32 we can check
	// perfectly well — sailed through because a DIFFERENT entry happened to be
	// encrypted. Measured against the oracle:
	//
	//     unrar t -pSECRET  ->  plain.txt - checksum error, Total errors: 1
	//     rarz t            ->  VALID
	//
	// That is a false pass on PROVEN damage in READABLE data, strictly worse
	// than the wholly-encrypted case where nothing was checkable at all.
	//
	// A wholly-encrypted fixture cannot catch this; the archive needs both kinds
	// of entry, which is why an audit over single-mode archives missed it.
	const pristine: []const u8 = @embedFile("rar5_encrypted_mixed");

	// Intact: the encrypted entry is unverifiable, but nothing is DAMAGED.
	try testing.expect(validate(pristine).is_valid);

	// Smash bytes across the archive; wherever the unencrypted entry's payload
	// is hit, that must be detected. Sweeping avoids hard-coding an offset that
	// a regenerated fixture would invalidate.
	var buf: [4096]u8 = undefined;
	try testing.expect(pristine.len <= buf.len);

	var caught: usize = 0;
	var attempts: usize = 0;
	var off: usize = 100;
	while (off + 16 < pristine.len) : (off += 16) {
		@memcpy(buf[0..pristine.len], pristine);
		for (buf[off..][0..16]) |*b| b.* ^= 0xFF;
		attempts += 1;
		if (!validate(buf[0..pristine.len]).is_valid) caught += 1;
	}

	// The archive is ~1.2 KB and mostly payload, so a bail-out-on-encryption
	// implementation catches almost nothing here. Requiring a clear majority
	// keeps this from passing on header-CRC hits alone.
	try testing.expect(attempts > 8);
	try testing.expect(caught * 2 > attempts);
}

test "SFX prefix: a self-extracting archive must be recognised, not rejected" {
	// `validate()` called `detect_format(data, 0)`, disabling the SFX prefix
	// scan that the same function already implements and that §5 of the spec
	// requires. A stub prepended to a perfectly good archive produced:
	//
	//     unrar t  ->  All OK
	//     rarz t   ->  INVALID: no recognized RAR signature
	//
	// i.e. a damage claim about an archive that is not damaged. Self-extracting
	// RARs are common in the wild.
	const inner: []const u8 = @embedFile("rar5_store");

	var buf: [65536]u8 = undefined;
	const prefix_len = 46;
	try testing.expect(inner.len + prefix_len <= buf.len);

	// A plausible stub: bytes that are not a RAR signature.
	for (buf[0..prefix_len]) |*b| b.* = 'M';
	@memcpy(buf[prefix_len..][0..inner.len], inner);

	const result = validate(buf[0 .. prefix_len + inner.len]);
	try testing.expect(result.is_valid);
	try testing.expectEqual(detect_mod.RarFamily.rar50, result.family.?);
}

test "SFX prefix: damage inside the embedded archive is still caught" {
	// The prefix scan must not become a way to skip past corruption. Same
	// construction as above, with the archive's payload smashed.
	const inner: []const u8 = @embedFile("rar5_store");

	var buf: [65536]u8 = undefined;
	const prefix_len = 46;
	for (buf[0..prefix_len]) |*b| b.* = 'M';
	@memcpy(buf[prefix_len..][0..inner.len], inner);

	const total = prefix_len + inner.len;
	var caught: usize = 0;
	var attempts: usize = 0;
	var off: usize = prefix_len + 40;
	while (off + 16 < total) : (off += 32) {
		var probe: [65536]u8 = undefined;
		@memcpy(probe[0..total], buf[0..total]);
		for (probe[off..][0..16]) |*b| b.* ^= 0xFF;
		attempts += 1;
		if (!validate(probe[0..total]).is_valid) caught += 1;
	}
	try testing.expect(attempts > 4);
	try testing.expect(caught * 2 > attempts);
}

test "RAR 1.4: a signature followed by garbage must NOT be VALID" {
	// The worst failure this project can produce, and it was live: the family
	// switch in validate() returned `.is_valid = true` for .rar14 with the
	// comment "No structural parser for RAR 1.4 yet". So every RAR 1.4 archive
	// was blessed without a single byte being examined, and 200 bytes of random
	// noise behind a valid signature passed while unrar reported it damaged.
	//
	// "No parser yet" is a reason to REFUSE, never a reason to pass.
	var buf: [204]u8 = undefined;
	@memcpy(buf[0..4], "RE~^"); // RAR 1.4 signature
	// Deterministic non-archive filler.
	for (buf[4..], 0..) |*b, i| b.* = @truncate(i *% 197 +% 31);

	const result = validate(&buf);
	try testing.expect(!result.is_valid);
	try testing.expect(result.error_message != null);
}

test "RAR 1.4: bare signature with no data must NOT be VALID" {
	const result = validate("RE~^");
	try testing.expect(!result.is_valid);
}

test "RAR 1.4: even a plausible-looking body must NOT be VALID while unparsed" {
	// Zeros are the shape a naive "is it all readable?" check would accept.
	var buf: [64]u8 = [_]u8{0} ** 64;
	@memcpy(buf[0..4], "RE~^");
	const result = validate(&buf);
	try testing.expect(!result.is_valid);
}

test "validate handles truncation at every position of a valid RAR5 archive" {
	const writer = @import("writer.zig");
	const file_data = "hello world";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0,
		.is_directory = false,
	}};

	var buf: [4096]u8 = undefined;
	const archive_len = try writer.write_archive(&entries, &buf);

	// Try every truncation point from 1 byte to full length
	for (1..archive_len) |len| {
		const result = validate(buf[0..len]);
		_ = result; // must not crash
	}
}

// ============================================================================
// Multi-volume validation tests
// ============================================================================

test "validate_volumes: valid store file split across 2 volumes" {
	const writer = @import("writer.zig");
	const alloc = testing.allocator;

	// Create a file large enough to split across 2 volumes
	const file_data = "Hello, multi-volume world! This is a test of split file validation across volumes.";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	// Use small volume size to force splitting
	var result = try writer.write_archive_volumes(alloc, &entries, .{ .volume_size = 128 });
	defer result.deinit();

	try testing.expect(result.count >= 2);

	// Build slices array
	const vol_slices = try alloc.alloc([]const u8, result.count);
	defer alloc.free(vol_slices);
	for (0..result.count) |i| {
		vol_slices[i] = result.volumes[i];
	}

	const vr = validate_volumes(vol_slices);
	try testing.expect(vr.is_valid);
	try testing.expectEqual(@as(u32, 1), vr.file_count);
}

test "validate_volumes: CRC mismatch in split file" {
	const writer = @import("writer.zig");
	const alloc = testing.allocator;

	const file_data = "Hello, multi-volume world! This is a test of split file validation across volumes.";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	var result = try writer.write_archive_volumes(alloc, &entries, .{ .volume_size = 128 });
	defer result.deinit();

	try testing.expect(result.count >= 2);

	// Corrupt a byte in the data area of the second volume
	const vol2 = result.volumes[1];
	// Find a byte in the data area (after headers, near middle of volume)
	const corrupt_pos = vol2.len / 2;
	vol2[corrupt_pos] ^= 0xFF;

	const vol_slices = try alloc.alloc([]const u8, result.count);
	defer alloc.free(vol_slices);
	for (0..result.count) |i| {
		vol_slices[i] = result.volumes[i];
	}

	const vr = validate_volumes(vol_slices);
	try testing.expect(!vr.is_valid);
}

test "validate_volumes: mixed split and non-split files" {
	const writer = @import("writer.zig");
	const alloc = testing.allocator;

	// Two small files that fit in one volume + one large file that splits
	const entries = [_]writer.FileEntry{
		.{ .name = "small1.txt", .data = "Hi!", .mtime = 0, .is_directory = false },
		.{ .name = "small2.txt", .data = "Hey!", .mtime = 0, .is_directory = false },
		.{
			.name = "big.txt",
			.data = "This is a much larger file that should definitely be split across multiple volumes in the archive.",
			.mtime = 0,
			.is_directory = false,
		},
	};

	// Volume size chosen so small files fit but big file splits
	var result = try writer.write_archive_volumes(alloc, &entries, .{ .volume_size = 180 });
	defer result.deinit();

	try testing.expect(result.count >= 2);

	const vol_slices = try alloc.alloc([]const u8, result.count);
	defer alloc.free(vol_slices);
	for (0..result.count) |i| {
		vol_slices[i] = result.volumes[i];
	}

	const vr = validate_volumes(vol_slices);
	try testing.expect(vr.is_valid);
	try testing.expectEqual(@as(u32, 3), vr.file_count);
}

test "validate_volumes: single volume passthrough" {
	const writer = @import("writer.zig");

	const file_data = "Hello, single volume!";
	const entries = [_]writer.FileEntry{.{
		.name = "test.txt",
		.data = file_data,
		.mtime = 0x5C000000,
		.is_directory = false,
	}};

	var buf: [4096]u8 = undefined;
	const archive_len = try writer.write_archive(&entries, &buf);

	const vol_slices = [_][]const u8{buf[0..archive_len]};
	const vr = validate_volumes(&vol_slices);
	try testing.expect(vr.is_valid);
	try testing.expectEqual(@as(u32, 1), vr.file_count);
}

test "validate_volumes: empty volumes slice" {
	const vol_slices = [_][]const u8{};
	const vr = validate_volumes(&vol_slices);
	try testing.expect(!vr.is_valid);
}

// Regression (fuzz-found via validate Tier-1 sweep, 2026-07-01): a corrupt RAR5
// filter descriptor carries a 3-bit filter type; FilterType is enum(u3) with only
// 4 of 8 values defined, so @enumFromInt on a 4..7 value panicked ("invalid enum
// value") in parseFilterDescriptor. validate fuzzing surfaced it (bolter bit-flip
// of a valid RAR). Fixed with a checked std.meta.intToEnum. Fixture:
// tests/fixtures/invalid/fuzz_filter_type_invalid.rar (766 bytes) inlined for a self-
// contained regression that runs in `zig build test`.
test "validate does not panic on invalid RAR5 filter type (fuzz regression)" {
    const crasher = [_]u8{
        0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00, 0xf3, 0xe1, 0x82, 0xeb, 0x0b, 0x01, 0x05, 0x07, 
        0x00, 0x06, 0x01, 0x01, 0x80, 0x80, 0x80, 0x00, 0x2d, 0x78, 0x1b, 0x53, 0x2b, 0x02, 0x03, 0x0b, 
        0xae, 0x85, 0x00, 0x04, 0xb0, 0x93, 0x01, 0xa4, 0x83, 0x02, 0xfb, 0x0b, 0x0c, 0x0d, 0x80, 0x05, 
        0x01, 0x0b, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64, 0x2e, 0x74, 0x78, 0x74, 0x0a, 0x03, 0x13, 
        0x57, 0x85, 0x9a, 0x69, 0xa8, 0xcf, 0x23, 0x21, 0xce, 0x3c, 0xaa, 0x02, 0x26, 0x46, 0x53, 0x45, 
        0x53, 0x4f, 0x34, 0x04, 0x4c, 0xef, 0x45, 0x4e, 0x81, 0x9e, 0xd5, 0x30, 0xed, 0x9a, 0xc7, 0x5a, 
        0x15, 0xe8, 0x3f, 0x0d, 0xf5, 0xd3, 0xe8, 0x78, 0x6e, 0x8e, 0xd7, 0xa9, 0xd8, 0xdf, 0x9f, 0xaf, 
        0xe0, 0x96, 0xc7, 0x6c, 0x76, 0x56, 0x95, 0x49, 0x72, 0x17, 0x30, 0xc6, 0x38, 0xd3, 0xc9, 0x10, 
        0x24, 0x10, 0xb9, 0x0a, 0x09, 0xc3, 0x24, 0x92, 0xac, 0x73, 0xed, 0x1f, 0xeb, 0xee, 0xef, 0xeb, 
        0xe6, 0xee, 0xf0, 0xe9, 0xb7, 0x93, 0xfb, 0xf2, 0x6d, 0xea, 0xed, 0xdd, 0xe5, 0xef, 0xe9, 0xb7, 
        0x9f, 0xaf, 0xb7, 0xc3, 0xff, 0xed, 0xd3, 0xc5, 0xfe, 0x74, 0xf4, 0xf4, 0xed, 0xef, 0xc7, 0xe6, 
        0xdb, 0xd9, 0xd7, 0xc3, 0xd1, 0xce, 0x5f, 0x3f, 0x38, 0x3c, 0xbd, 0x79, 0x3f, 0xb7, 0x3e, 0x7d, 
        0xb6, 0xf5, 0xf3, 0xc3, 0x6f, 0x4f, 0x27, 0x3c, 0x5c, 0xff, 0x39, 0x37, 0xe3, 0xdf, 0x79, 0x7f, 
        0x5b, 0x72, 0x7b, 0xc3, 0xb7, 0xab, 0xfd, 0xf7, 0x78, 0xff, 0xef, 0x47, 0x5e, 0x9d, 0xfc, 0xff, 
        0x5f, 0x4d, 0xf7, 0xe5, 0xac, 0xdb, 0xdf, 0xd3, 0xbb, 0xe6, 0x53, 0xca, 0x51, 0x55, 0x59, 0x42, 
        0xba, 0xc2, 0xe3, 0x27, 0x2d, 0xf2, 0x92, 0x5a, 0x6d, 0x24, 0xa4, 0xa4, 0xa4, 0xa4, 0xa4, 0xa4, 
        0xa6, 0xa6, 0xa6, 0xa6, 0xa7, 0x9e, 0x3f, 0x88, 0xad, 0x94, 0xd3, 0x69, 0x35, 0x35, 0x35, 0x45, 
        0x45, 0x45, 0x45, 0x45, 0x45, 0x45, 0x45, 0x45, 0x45, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 
        0x55, 0x55, 0x5c, 0xf5, 0xfb, 0xca, 0xdb, 0xe5, 0x34, 0xda, 0x59, 0x59, 0x59, 0x59, 0x59, 0x59, 
        0x59, 0x59, 0x42, 0x85, 0x0a, 0x14, 0x28, 0x50, 0xa1, 0x42, 0x85, 0x75, 0x75, 0x75, 0x75, 0x7c, 
        0xe1, 0xfb, 0x0a, 0xd9, 0x4d, 0x36, 0x97, 0x57, 0x57, 0x58, 0x58, 0x58, 0x58, 0x58, 0x58, 0x58, 
        0x58, 0x58, 0x58, 0x5c, 0x2e, 0x17, 0x0b, 0x85, 0xc2, 0xe1, 0x70, 0xb8, 0x5c, 0x2e, 0x33, 0x97, 
        0xe2, 0x52, 0xdf, 0x7c, 0xa4, 0x94, 0xd5, 0x15, 0x55, 0x94, 0x2b, 0xac, 0x2d, 0x36, 0x92, 0x5a, 
        0x72, 0x56, 0x48, 0x84, 0x10, 0x84, 0x10, 0x84, 0x10, 0x84, 0x10, 0x84, 0x10, 0x84, 0x0b, 0xe0, 
        0x56, 0xca, 0x69, 0xb4, 0x9a, 0x9e, 0x1a, 0x34, 0xa6, 0xed, 0x1a, 0x52, 0x6d, 0x1a, 0x52, 0xad, 
        0x1a, 0x52, 0x1a, 0x34, 0xa6, 0x1a, 0x34, 0xae, 0xed, 0x1a, 0x56, 0x6d, 0x1a, 0x56, 0xad, 0x1a, 
        0x56, 0x1a, 0x34, 0xae, 0x1a, 0x34, 0xb6, 0xfa, 0x85, 0xa6, 0xd2, 0xca, 0xd4, 0x68, 0xd2, 0xd6, 
        0x68, 0xd2, 0xd7, 0x68, 0xd3, 0x4e, 0x4a, 0xc9, 0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 
        0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 0x13, 0xf3, 0x44, 0xa3, 0x29, 0xa6, 0xd2, 0xeb, 0x4e, 0x4a, 
        0xc9, 0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 0x10, 0x82, 0x10, 
        0x82, 0x10, 0x82, 0x13, 0x39, 0xe7, 0xdf, 0xe5, 0x29, 0x65, 0x26, 0xa8, 0xaa, 0xac, 0xa1, 0x5d, 
        0x61, 0x69, 0xb4, 0x92, 0x94, 0x9a, 0x34, 0x95, 0x1a, 0x34, 0x95, 0x9a, 0x34, 0x95, 0xda, 0x34, 
        0xd3, 0x92, 0xb3, 0x44, 0x20, 0x93, 0x44, 0x21, 0xf7, 0xf8, 0x4a, 0x32, 0x9a, 0x6d, 0x26, 0xb4, 
        0xe4, 0xac, 0xd1, 0x08, 0x21, 0x08, 0x21, 0x08, 0x21, 0x08, 0x21, 0x08, 0x21, 0x08, 0x21, 0x08, 
        0x21, 0x08, 0x21, 0x08, 0x21, 0x08, 0x7f, 0xfd, 0xa5, 0x2c, 0xa6, 0x9b, 0x4b, 0x2b, 0x55, 0xa3, 
        0x4b, 0x43, 0x46, 0x96, 0xc3, 0x46, 0x91, 0xbb, 0x46, 0x91, 0x36, 0x8d, 0x22, 0xad, 0x1a, 0x44, 
        0x34, 0x69, 0x18, 0x68, 0xd2, 0xfb, 0xb4, 0x69, 0x79, 0xb4, 0x69, 0xa7, 0x25, 0x49, 0xea, 0xfd, 
        0x25, 0x19, 0x4d, 0x36, 0x97, 0x5a, 0x72, 0x56, 0x68, 0x84, 0x10, 0x84, 0x10, 0x84, 0x10, 0x84, 
        0x10, 0x84, 0x10, 0x84, 0x10, 0x84, 0x10, 0x84, 0x10, 0x84, 0x10, 0x99, 0xd3, 0x3b, 0xff, 0x29, 
        0x4b, 0x29, 0x35, 0x45, 0x55, 0x65, 0x0a, 0xeb, 0x0b, 0x4d, 0xa4, 0x94, 0xa4, 0xd1, 0xa4, 0xa8, 
        0xd1, 0xa4, 0xac, 0xd1, 0xa4, 0xae, 0xd1, 0xa6, 0x9c, 0x95, 0xa2, 0x21, 0x04, 0x21, 0x04, 0x27, 
        0xcb, 0xf0, 0x94, 0x65, 0x34, 0xda, 0x4d, 0x69, 0xc9, 0x5a, 0x22, 0x10, 0x42, 0x10, 0x42, 0x10, 
        0x42, 0x10, 0x42, 0x10, 0x42, 0x10, 0x42, 0x10, 0x42, 0x10, 0x42, 0x10, 0x42, 0x10, 0xef, 0xf7, 
        0x94, 0xb2, 0x9a, 0x6d, 0x2c, 0xad, 0x56, 0x8d, 0x2d, 0x0d, 0x1a, 0x5b, 0x0d, 0x1a, 0x46, 0xed, 
        0x1a, 0x44, 0xda, 0x34, 0x8a, 0xb4, 0x69, 0x10, 0xd1, 0xa4, 0x61, 0xa3, 0x4b, 0xee, 0xd1, 0xa5, 
        0xe6, 0xd1, 0xa6, 0x9c, 0x95, 0x27, 0x8b, 0xeb, 0x28, 0xca, 0x69, 0xb4, 0xba, 0xd3, 0x92, 0xb4, 
        0x44, 0x20, 0x84, 0x20, 0x84, 0x20, 0x84, 0x20, 0x84, 0x20, 0x84, 0x20, 0x84, 0x20, 0x84, 0x20, 
        0x84, 0x20, 0x84, 0xce, 0xb9, 0xce, 0x1d, 0x77, 0x56, 0x51, 0x03, 0x05, 0x04, 0x00, 
        
    };
    // Pre-fix: "invalid enum value" panic. Post-fix: a clean (invalid) verdict.
    const result = validate(&crasher);
    try testing.expect(!result.is_valid);
}
test "validate_volumes: official rar m3 multi-volume fixture validates (spanning-payload CRC regression)" {
	// MFIC independence: these volumes were produced by the OFFICIAL `rar` CLI,
	// NOT rarz's own writer (the other validate_volumes tests round-trip through
	// writer.zig, so they cannot catch a systematic divergence from real RAR5).
	// External oracle `unrar t` reports "All OK" and rarz extraction is
	// byte-identical to unrar. Therefore the verify path MUST report VALID.
	//
	// Regression for the false "payload CRC32 mismatch" on volume-spanning
	// payloads: large.txt is m3-compressed and split across both volumes. RAR5
	// stores the authoritative full-file CRC in the LAST part; rarz previously
	// compared against the FIRST part's (per-segment) CRC and rejected valid data.
	const part1: []const u8 = @embedFile("rar5_vol_m3_part01");
	const part2: []const u8 = @embedFile("rar5_vol_m3_part02");
	const vols = [_][]const u8{ part1, part2 };
	const vr = validate_volumes(&vols);
	try testing.expect(vr.is_valid);
}

test "validate: truncated RAR4 archive must NOT be VALID" {
	// Truncation must be detected by observing MISSING BYTES, not by a
	// missing end-of-archive block.
	//
	// This test used to build a synthetic RAR4, drop its end block, and
	// require INVALID. That premise was wrong: RAR 2.x archives routinely
	// have no end block at all and unrar reports them fine, so the rule
	// rejected valid vintage archives. Now it truncates a REAL RAR 2.90
	// archive part-way through its payload, which is genuine damage —
	// `unrar t` errors on this input too.
	const full: []const u8 = @embedFile("rar2_v20_store");

	// Intact: valid (no end-of-archive block in this vintage archive).
	try testing.expect(validate(full).is_valid);

	// Cut into the payload: the declared data now runs past end-of-file.
	try testing.expect(!validate(full[0 .. full.len - 500]).is_valid);
}

test "validate: corrupted COMPRESSED RAR4 payload must be detected" {
	// validate_rar4_payload only verified `f.method == 0` (store), so compressed
	// RAR4 archives got ZERO payload verification and were reported VALID no
	// matter how damaged they were: 0/6 against the unrar oracle, versus 6/6 for
	// store-method. The v29 decoder had to be corrected first (976d34b) — wiring
	// this up beforehand flagged the pristine fixture INVALID.
	const pristine: []const u8 = @embedFile("rar4_m3");

	// Intact archive stays VALID (unrar: All OK). Guards against "fixing" the
	// false-green by making every compressed RAR4 fail instead.
	try testing.expect(validate(pristine).is_valid);

	const buf = try testing.allocator.alloc(u8, pristine.len);
	defer testing.allocator.free(buf);
	@memcpy(buf, pristine);
	buf[pristine.len / 2] ^= 0xFF; // corrupt inside the compressed payload
	try testing.expect(!validate(buf).is_valid);
}

test "validate: a genuine RAR 2.x archive with no end-of-archive block is VALID" {
	// REGRESSION against over-strictness. e781e58/00be71e made a missing
	// end-of-archive block mean "truncated". That is correct for RAR5, where the
	// terminator is mandatory, but RAR 2.x archives frequently do not carry one
	// at all — this fixture, produced by the original RAR 2.90 and reported
	// "All OK" by unrar, simply ends after its last file.
	//
	// The rule therefore rejected perfectly good old archives: exactly the
	// false-positive direction that matters most for a tool whose job is to be
	// believed about old files. Truncation of RAR4 is still caught by the
	// payload-past-end-of-archive and block-parse checks (verified: cutting this
	// same fixture short still reports INVALID, matching unrar).
	const data: []const u8 = @embedFile("rar2_v20_store");
	const result = validate(data);
	try testing.expect(result.is_valid);
}

/// Detect RAR "-hp" header encryption pre-walk: RAR5 opens with a HEAD_CRYPT
/// block (type 4); RAR4 sets MHD_PASSWORD (0x0080) on the MAIN header. Both
/// mean every subsequent block is ciphertext — unreadable, not damaged.
pub fn headers_encrypted(data: []const u8, fmt: detect_mod.FormatResult, family: detect_mod.RarFamily) bool {
	switch (family) {
		.rar50 => {
			const block_start = fmt.signature_offset + fmt.signature_len;
			if (block_start >= data.len) return false;
			// HEAD_CRYPT exists ONLY for header encryption; everything after it
			// is ciphertext. Real -hp archives place it first, but any position
			// means the same thing, so scan rather than peek.
			var iter = rar5_headers.walk_blocks(data[block_start..]);
			while (iter.next() catch return false) |block| {
				if (block == .crypt) return true;
				if (block == .end_archive) break;
			}
			return false;
		},
		.rar15 => {
			var r = reader_mod.Reader.init(data[fmt.signature_offset + fmt.signature_len ..]);
			const block = rar4_headers.parse_block_header(&r) catch return false;
			if (block.header_type != .main) return false;
			return rar4_headers.parse_main_flags(block.flags).password;
		},
		.rar14 => return false,
	}
}
