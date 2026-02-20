//! RAR format family detection from raw bytes with SFX prefix scanning.

const std = @import("std");

pub const RarFamily = enum {
	rar14, // RAR 1.4 (ancient, signature: 52 45 7E 5E)
	rar15, // RAR 1.5-4.x (signature: 52 61 72 21 1A 07 00)
	rar50, // RAR5+ (signature: 52 61 72 21 1A 07 01 00)
};

pub const FormatResult = struct {
	family: ?RarFamily,
	signature_offset: usize,
	signature_len: u8,
};

// Signature constants
pub const RAR14_SIG = [4]u8{ 0x52, 0x45, 0x7E, 0x5E };
pub const RAR15_SIG = [7]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 };
pub const RAR50_SIG = [8]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 };

/// Attempt to match a RAR signature at the given offset within data.
/// Returns a FormatResult with the matched family, or null if no match.
/// Checks most specific first (RAR5 before RAR 1.5-4.x).
fn try_match_at(data: []const u8, offset: usize) FormatResult {
	const no_match = FormatResult{ .family = null, .signature_offset = 0, .signature_len = 0 };

	// Check RAR5 (8 bytes) — must check before RAR 1.5-4.x since RAR5 is a superset
	if (offset + RAR50_SIG.len <= data.len) {
		const candidate = data[offset..][0..RAR50_SIG.len];
		if (std.mem.eql(u8, candidate, &RAR50_SIG)) {
			return .{ .family = .rar50, .signature_offset = offset, .signature_len = RAR50_SIG.len };
		}
	}

	// Future format detection: first 6 bytes match RAR 1.5+ prefix, but byte 6 is > 1 and < 5
	// This means it's a future unsupported format — return null
	if (offset + 7 <= data.len) {
		const first6 = data[offset..][0..6];
		if (std.mem.eql(u8, first6, RAR15_SIG[0..6])) {
			const byte6 = data[offset + 6];
			if (byte6 > 1 and byte6 < 5) {
				return no_match;
			}
		}
	}

	// Check RAR 1.5-4.x (7 bytes)
	if (offset + RAR15_SIG.len <= data.len) {
		const candidate = data[offset..][0..RAR15_SIG.len];
		if (std.mem.eql(u8, candidate, &RAR15_SIG)) {
			return .{ .family = .rar15, .signature_offset = offset, .signature_len = RAR15_SIG.len };
		}
	}

	// Check RAR 1.4 (4 bytes)
	if (offset + RAR14_SIG.len <= data.len) {
		const candidate = data[offset..][0..RAR14_SIG.len];
		if (std.mem.eql(u8, candidate, &RAR14_SIG)) {
			return .{ .family = .rar14, .signature_offset = offset, .signature_len = RAR14_SIG.len };
		}
	}

	return no_match;
}

/// Detect RAR format family from raw bytes.
///
/// First checks offset 0 for all three signatures (most specific first).
/// If not found at offset 0 and max_sfx_offset > 0, scans byte-by-byte
/// up to max_sfx_offset looking for any signature (SFX prefix scanning).
///
/// Returns a FormatResult with family set to null if no signature is found.
pub fn detect_format(data: []const u8, max_sfx_offset: usize) FormatResult {
	const no_match = FormatResult{ .family = null, .signature_offset = 0, .signature_len = 0 };

	// Data too short for any signature (shortest is RAR14 at 4 bytes)
	if (data.len < RAR14_SIG.len) {
		return no_match;
	}

	// First check at offset 0
	const result_at_0 = try_match_at(data, 0);
	if (result_at_0.family != null) {
		return result_at_0;
	}

	// If max_sfx_offset > 0, scan byte-by-byte for SFX prefix
	if (max_sfx_offset > 0) {
		const scan_limit = @min(max_sfx_offset, data.len);
		var offset: usize = 1;
		while (offset < scan_limit) : (offset += 1) {
			const result = try_match_at(data, offset);
			if (result.family != null) {
				return result;
			}
		}
	}

	return no_match;
}

// --- Tests ---

const testing = std.testing;

test "detect RAR 1.4 signature" {
	const data = RAR14_SIG ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 };
	const result = detect_format(&data, 0);
	try testing.expectEqual(RarFamily.rar14, result.family.?);
	try testing.expectEqual(@as(usize, 0), result.signature_offset);
	try testing.expectEqual(@as(u8, 4), result.signature_len);
}

test "detect RAR 1.5-4.x signature" {
	const data = RAR15_SIG ++ [_]u8{0x00};
	const result = detect_format(&data, 0);
	try testing.expectEqual(RarFamily.rar15, result.family.?);
	try testing.expectEqual(@as(usize, 0), result.signature_offset);
	try testing.expectEqual(@as(u8, 7), result.signature_len);
}

test "detect RAR5 signature" {
	const data = RAR50_SIG ++ [_]u8{ 0x00, 0x00 };
	const result = detect_format(&data, 0);
	try testing.expectEqual(RarFamily.rar50, result.family.?);
	try testing.expectEqual(@as(usize, 0), result.signature_offset);
	try testing.expectEqual(@as(u8, 8), result.signature_len);
}

test "detect no signature returns null family" {
	const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x02 };
	const result = detect_format(&data, 0);
	try testing.expectEqual(@as(?RarFamily, null), result.family);
}

test "detect SFX prefix - RAR5 after junk" {
	var data = [_]u8{0xAA} ** 256;
	// Place RAR5 signature at offset 100
	const sig = RAR50_SIG;
	for (sig, 0..) |b, i| {
		data[100 + i] = b;
	}
	const result = detect_format(&data, 256);
	try testing.expectEqual(RarFamily.rar50, result.family.?);
	try testing.expectEqual(@as(usize, 100), result.signature_offset);
	try testing.expectEqual(@as(u8, 8), result.signature_len);
}

test "SFX scan respects max offset" {
	var data = [_]u8{0xAA} ** 256;
	// Place RAR5 signature at offset 200
	const sig = RAR50_SIG;
	for (sig, 0..) |b, i| {
		data[200 + i] = b;
	}
	// max_sfx_offset=100, so signature at 200 should NOT be found
	const result = detect_format(&data, 100);
	try testing.expectEqual(@as(?RarFamily, null), result.family);
}

test "data too short for any signature" {
	const data = [_]u8{0x52};
	const result = detect_format(&data, 0);
	try testing.expectEqual(@as(?RarFamily, null), result.family);
}

test "future marker byte 6 > 1 and < 5" {
	// Like RAR5 but byte 6 = 0x03 (future unsupported format)
	const data = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x03, 0x00, 0x00, 0x00 };
	const result = detect_format(&data, 0);
	try testing.expectEqual(@as(?RarFamily, null), result.family);
}

test "empty input" {
	const data: []const u8 = &.{};
	const result = detect_format(data, 0);
	try testing.expectEqual(@as(?RarFamily, null), result.family);
}
