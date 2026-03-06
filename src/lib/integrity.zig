//! Integrity primitives for RAR archive validation.
//!
//! Provides CRC32, CRC16 (ARC variant used by RAR legacy headers),
//! and BLAKE2sp (8-way parallel tree hash used by RAR5).

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;

// ============================================================================
// CRC32 — standard CRC-32/ISO-HDLC (used by RAR for file data checksums)
// ============================================================================

/// Compute CRC-32/ISO-HDLC over the given data.
/// This is the standard CRC32 used in Ethernet, zlib, PNG, etc.
///
/// Uses hardware CRC instructions on aarch64 (ARMv8 CRC extension),
/// slicing-by-8 on other architectures. Both paths produce identical results.
pub fn crc32(data: []const u8) u32 {
	const arch = comptime builtin.cpu.arch;
	if (comptime arch == .aarch64) {
		if (comptime std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc)) {
			return crc32_arm(data);
		}
	}
	return crc32_slice8(data);
}

/// ARM hardware CRC32 (implemented in C via arm_acle.h intrinsics).
/// Zig inline asm on aarch64 doesn't support w-register modifiers,
/// so we use a C helper that calls __crc32d/__crc32w/__crc32b.
extern fn crc32_arm_hw(data: [*]const u8, len: usize) u32;
fn crc32_arm(data: []const u8) u32 {
	return crc32_arm_hw(data.ptr, data.len);
}

/// Slicing-by-8: processes 8 bytes per iteration using 8 lookup tables.
/// ~2-4x faster than the stdlib single-table byte-at-a-time approach.
fn crc32_slice8(data: []const u8) u32 {
	const tables = comptime blk: {
		@setEvalBranchQuota(20000);
		// Reflected polynomial for CRC32/ISO-HDLC
		const poly: u32 = 0xEDB88320;

		// Table 0: standard single-byte lookup table
		var t: [8][256]u32 = undefined;
		for (&t[0], 0..) |*entry, i| {
			var crc: u32 = @intCast(i);
			for (0..8) |_| {
				crc = if (crc & 1 != 0) (crc >> 1) ^ poly else crc >> 1;
			}
			entry.* = crc;
		}

		// Tables 1-7: extended tables for slicing-by-8
		for (1..8) |s| {
			for (&t[s], 0..) |*entry, i| {
				entry.* = (t[s - 1][i] >> 8) ^ t[0][@as(u8, @truncate(t[s - 1][i]))];
			}
		}

		break :blk t;
	};

	var crc: u32 = 0xFFFFFFFF;
	var pos: usize = 0;

	// Process 8 bytes at a time
	while (pos + 8 <= data.len) {
		const d0 = crc ^ mem.readInt(u32, data[pos..][0..4], .little);
		const d1 = mem.readInt(u32, data[pos + 4 ..][0..4], .little);
		crc = tables[7][@as(u8, @truncate(d0))] ^
			tables[6][@as(u8, @truncate(d0 >> 8))] ^
			tables[5][@as(u8, @truncate(d0 >> 16))] ^
			tables[4][@as(u8, @truncate(d0 >> 24))] ^
			tables[3][@as(u8, @truncate(d1))] ^
			tables[2][@as(u8, @truncate(d1 >> 8))] ^
			tables[1][@as(u8, @truncate(d1 >> 16))] ^
			tables[0][@as(u8, @truncate(d1 >> 24))];
		pos += 8;
	}

	// Process remaining bytes one at a time
	while (pos < data.len) {
		crc = (crc >> 8) ^ tables[0][@as(u8, @truncate(crc ^ data[pos]))];
		pos += 1;
	}

	return crc ^ 0xFFFFFFFF;
}

// ============================================================================
// CRC16 — CRC-16/ARC (IBM) variant used by RAR legacy headers
// ============================================================================

/// Compute CRC-16/ARC over the given data.
/// Polynomial 0x8005, init 0x0000, reflect in/out, no xor output.
/// RAR legacy (v1.5-4.x) headers use this over header bytes after the CRC field.
pub fn crc16(data: []const u8) u16 {
	return std.hash.crc.Crc16Arc.hash(data);
}

// ============================================================================
// BLAKE2sp — 8-way parallel tree hash (used by RAR5 for file checksums)
// ============================================================================

/// BLAKE2s compression constants
const blake2s_iv = [8]u32{
	0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
	0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
};

const blake2s_sigma = [10][16]u8{
	.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
	.{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
	.{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
	.{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
	.{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
	.{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
	.{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
	.{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
	.{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
	.{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
};

/// Low-level BLAKE2s state for tree mode support.
/// The stdlib Blake2s does not expose tree parameters (fanout, depth,
/// node_offset, node_depth, inner_length), so we implement from scratch.
const Blake2sState = struct {
	h: [8]u32,
	t: u64,
	buf: [64]u8,
	buf_len: u8,
	last_node: bool,

	/// Initialize with a raw parameter block (32 bytes, little-endian).
	fn initFromParams(param_block: [32]u8) Blake2sState {
		var state: Blake2sState = undefined;
		state.h = blake2s_iv;
		// XOR parameter block words into IV
		for (&state.h, 0..) |*hword, i| {
			hword.* ^= mem.readInt(u32, param_block[i * 4 ..][0..4], .little);
		}
		state.t = 0;
		state.buf_len = 0;
		state.buf = [_]u8{0} ** 64;
		state.last_node = false;
		return state;
	}

	/// Build a BLAKE2s parameter block for tree mode.
	fn makeParamBlock(
		digest_length: u8,
		key_length: u8,
		fanout: u8,
		depth: u8,
		leaf_length: u32,
		node_offset: u32,
		xof_length: u16,
		node_depth: u8,
		inner_length: u8,
	) [32]u8 {
		var p: [32]u8 = [_]u8{0} ** 32;
		p[0] = digest_length;
		p[1] = key_length;
		p[2] = fanout;
		p[3] = depth;
		mem.writeInt(u32, p[4..8], leaf_length, .little);
		mem.writeInt(u32, p[8..12], node_offset, .little);
		mem.writeInt(u16, p[12..14], xof_length, .little);
		p[14] = node_depth;
		p[15] = inner_length;
		// bytes 16-23: salt (zeros)
		// bytes 24-31: personal (zeros)
		return p;
	}

	fn update(self: *Blake2sState, data: []const u8) void {
		var off: usize = 0;

		// Partial buffer from previous update
		if (self.buf_len != 0 and @as(usize, self.buf_len) + data.len > 64) {
			off = 64 - @as(usize, self.buf_len);
			@memcpy(self.buf[self.buf_len..][0..off], data[0..off]);
			self.t += 64;
			self.compress(&self.buf, false);
			self.buf_len = 0;
		}

		// Full middle blocks
		while (off + 64 < data.len) : (off += 64) {
			self.t += 64;
			self.compress(data[off..][0..64], false);
		}

		// Copy remainder
		const remainder = data[off..];
		@memcpy(self.buf[self.buf_len..][0..remainder.len], remainder);
		self.buf_len += @as(u8, @intCast(remainder.len));
	}

	fn final(self: *Blake2sState, out: []u8) void {
		@memset(self.buf[self.buf_len..], 0);
		self.t += self.buf_len;
		self.compress(&self.buf, true);
		// Convert h to little-endian bytes
		var hash_bytes: [32]u8 = undefined;
		for (self.h, 0..) |hword, i| {
			mem.writeInt(u32, hash_bytes[i * 4 ..][0..4], hword, .little);
		}
		@memcpy(out[0..out.len], hash_bytes[0..out.len]);
	}

	fn compress(self: *Blake2sState, block: *const [64]u8, last: bool) void {
		var m: [16]u32 = undefined;
		var v: [16]u32 = undefined;

		for (&m, 0..) |*r, i| {
			r.* = mem.readInt(u32, block[4 * i ..][0..4], .little);
		}

		var k: usize = 0;
		while (k < 8) : (k += 1) {
			v[k] = self.h[k];
			v[k + 8] = blake2s_iv[k];
		}

		v[12] ^= @as(u32, @truncate(self.t));
		v[13] ^= @as(u32, @intCast(self.t >> 32));
		if (last) {
			v[14] = ~v[14]; // f[0] = 0xFFFFFFFF
			if (self.last_node) {
				v[15] = ~v[15]; // f[1] = 0xFFFFFFFF
			}
		}

		// 10 rounds of mixing
		comptime var j: usize = 0;
		inline while (j < 10) : (j += 1) {
			// Column step
			g(&v, &m, blake2s_sigma[j], 0, 4, 8, 12, 0, 1);
			g(&v, &m, blake2s_sigma[j], 1, 5, 9, 13, 2, 3);
			g(&v, &m, blake2s_sigma[j], 2, 6, 10, 14, 4, 5);
			g(&v, &m, blake2s_sigma[j], 3, 7, 11, 15, 6, 7);
			// Diagonal step
			g(&v, &m, blake2s_sigma[j], 0, 5, 10, 15, 8, 9);
			g(&v, &m, blake2s_sigma[j], 1, 6, 11, 12, 10, 11);
			g(&v, &m, blake2s_sigma[j], 2, 7, 8, 13, 12, 13);
			g(&v, &m, blake2s_sigma[j], 3, 4, 9, 14, 14, 15);
		}

		for (&self.h, 0..) |*r, i| {
			r.* ^= v[i] ^ v[i + 8];
		}
	}
};

/// BLAKE2s G mixing function
fn g(v: *[16]u32, m: *const [16]u32, sigma_row: [16]u8, a: usize, b: usize, c: usize, d: usize, x: usize, y: usize) void {
	v[a] = v[a] +% v[b] +% m[sigma_row[x]];
	v[d] = math.rotr(u32, v[d] ^ v[a], 16);
	v[c] = v[c] +% v[d];
	v[b] = math.rotr(u32, v[b] ^ v[c], 12);
	v[a] = v[a] +% v[b] +% m[sigma_row[y]];
	v[d] = math.rotr(u32, v[d] ^ v[a], 8);
	v[c] = v[c] +% v[d];
	v[b] = math.rotr(u32, v[b] ^ v[c], 7);
}

const PARALLELISM: usize = 8;
const BLOCK_SIZE: usize = 64;
const BUF_SIZE: usize = PARALLELISM * BLOCK_SIZE; // 512

/// Initialize a BLAKE2s leaf state for BLAKE2sp tree mode.
fn initLeaf(leaf_index: u32) Blake2sState {
	const param_block = Blake2sState.makeParamBlock(
		32, // digest_length (inner output is 32 bytes)
		0, // key_length
		PARALLELISM, // fanout = 8
		2, // depth = 2
		0, // leaf_length
		leaf_index, // node_offset
		0, // xof_length
		0, // node_depth = 0 (leaf level)
		32, // inner_length = 32
	);
	var state = Blake2sState.initFromParams(param_block);
	if (leaf_index == PARALLELISM - 1) {
		state.last_node = true;
	}
	return state;
}

/// Initialize a BLAKE2s root state for BLAKE2sp tree mode.
fn initRoot() Blake2sState {
	const param_block = Blake2sState.makeParamBlock(
		32, // digest_length
		0, // key_length
		PARALLELISM, // fanout = 8
		2, // depth = 2
		0, // leaf_length
		0, // node_offset = 0
		0, // xof_length
		1, // node_depth = 1 (root level)
		32, // inner_length = 32
	);
	var state = Blake2sState.initFromParams(param_block);
	state.last_node = true;
	return state;
}

/// Compute the BLAKE2sp tree hash (unkeyed) over the given data.
/// Output is always 32 bytes.
///
/// BLAKE2sp distributes 64-byte input blocks round-robin across 8 parallel
/// BLAKE2s leaf instances, then hashes the concatenation of leaf outputs
/// through a root BLAKE2s instance. All instances use tree mode parameters.
pub fn blake2sp(data: []const u8, out: *[32]u8) void {
	var leaves: [PARALLELISM]Blake2sState = undefined;
	for (&leaves, 0..) |*leaf, i| {
		leaf.* = initLeaf(@intCast(i));
	}

	// Process full 512-byte (8 * 64) chunks
	var offset: usize = 0;
	while (offset + BUF_SIZE <= data.len) : (offset += BUF_SIZE) {
		for (&leaves, 0..) |*leaf, i| {
			const block_start = offset + i * BLOCK_SIZE;
			leaf.update(data[block_start..][0..BLOCK_SIZE]);
		}
	}

	// Process remaining partial chunk: distribute to leaves by 64-byte blocks
	const remaining = data[offset..];
	for (&leaves, 0..) |*leaf, i| {
		const block_start = i * BLOCK_SIZE;
		if (block_start < remaining.len) {
			const end = @min(block_start + BLOCK_SIZE, remaining.len);
			leaf.update(remaining[block_start..end]);
		}
	}

	// Finalize leaves and feed into root
	var root = initRoot();
	var leaf_hash: [32]u8 = undefined;
	for (&leaves) |*leaf| {
		leaf.final(&leaf_hash);
		root.update(&leaf_hash);
	}

	root.final(out);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// --- CRC32 tests ---

test "crc32 of empty data" {
	const result = crc32(&[_]u8{});
	try testing.expectEqual(@as(u32, 0x00000000), result);
}

test "crc32 of '123456789' — standard check value" {
	const result = crc32("123456789");
	try testing.expectEqual(@as(u32, 0xCBF43926), result);
}

test "crc32 of 'hello world'" {
	// Known CRC32 value for "hello world"
	const result = crc32("hello world");
	try testing.expectEqual(@as(u32, 0x0D4A1185), result);
}

test "crc32 of single byte 0x00" {
	const result = crc32(&[_]u8{0x00});
	try testing.expectEqual(@as(u32, 0xD202EF8D), result);
}

test "crc32 known-value: 256-byte incrementing pattern" {
	// Verify hardware and software paths produce identical results
	var data: [256]u8 = undefined;
	for (&data, 0..) |*b, i| b.* = @intCast(i);
	const result = crc32(&data);
	try testing.expectEqual(@as(u32, 0x29058C73), result);
}

test "crc32 slicing-by-8 matches stdlib" {
	// Cross-verify our implementation against the stdlib
	const test_vectors = [_][]const u8{
		"",
		"a",
		"abc",
		"123456789",
		"hello world",
		"The quick brown fox jumps over the lazy dog",
	};
	for (test_vectors) |data| {
		const our_result = crc32(data);
		const std_result = std.hash.crc.Crc32IsoHdlc.hash(data);
		try testing.expectEqual(std_result, our_result);
	}
}

test "crc32 large buffer matches stdlib" {
	// Test with a buffer that exercises the 8-byte fast path extensively
	var buf: [1024]u8 = undefined;
	for (&buf, 0..) |*b, i| b.* = @truncate(i *% 0x9E3779B1);
	const our_result = crc32(&buf);
	const std_result = std.hash.crc.Crc32IsoHdlc.hash(&buf);
	try testing.expectEqual(std_result, our_result);
}

// --- CRC16 tests ---

test "crc16 of empty data" {
	const result = crc16(&[_]u8{});
	try testing.expectEqual(@as(u16, 0x0000), result);
}

test "crc16 of '123456789' — CRC-16/ARC check value" {
	const result = crc16("123456789");
	try testing.expectEqual(@as(u16, 0xBB3D), result);
}

test "crc16 of single byte 0x00" {
	const result = crc16(&[_]u8{0x00});
	// CRC-16/ARC of single zero byte
	try testing.expectEqual(@as(u16, 0x0000), result);
}

// --- BLAKE2sp tests ---

test "blake2sp of empty data" {
	var out: [32]u8 = undefined;
	blake2sp(&[_]u8{}, &out);
	// Reference value computed via Python hashlib.blake2s with tree parameters
	const expected = "dd0e891776933f43c7d032b08a917e25741f8aa9a12c12e1cac8801500f2ca4f";
	var expected_bytes: [32]u8 = undefined;
	_ = std.fmt.hexToBytes(&expected_bytes, expected) catch unreachable;
	try testing.expectEqualSlices(u8, &expected_bytes, &out);
}

test "blake2sp of 'abc'" {
	var out: [32]u8 = undefined;
	blake2sp("abc", &out);
	// Reference value computed via Python hashlib.blake2s with tree parameters
	const expected = "70f75b58f1fecab821db43c88ad84edde5a52600616cd22517b7bb14d440a7d5";
	var expected_bytes: [32]u8 = undefined;
	_ = std.fmt.hexToBytes(&expected_bytes, expected) catch unreachable;
	try testing.expectEqualSlices(u8, &expected_bytes, &out);
}

test "blake2sp of 512 zero bytes" {
	// Tests the case where input exactly fills one full 512-byte buffer (8 * 64)
	var data: [512]u8 = [_]u8{0} ** 512;
	var out: [32]u8 = undefined;
	blake2sp(&data, &out);
	const expected = "6f34b48fa62a0392995a9ed4eda02ddcae556962430626574b32ead3557cdc12";
	var expected_bytes: [32]u8 = undefined;
	_ = std.fmt.hexToBytes(&expected_bytes, expected) catch unreachable;
	try testing.expectEqualSlices(u8, &expected_bytes, &out);
}

test "blake2sp of 1000 bytes 0xFF — multi-chunk" {
	// 1000 bytes = 512 (one full chunk) + 488 (partial chunk across 8 leaves)
	var data: [1000]u8 = [_]u8{0xFF} ** 1000;
	var out: [32]u8 = undefined;
	blake2sp(&data, &out);
	const expected = "a5b68918c45fe06a047294662c9f040cfe48c1f20acd22ada651574db8b51679";
	var expected_bytes: [32]u8 = undefined;
	_ = std.fmt.hexToBytes(&expected_bytes, expected) catch unreachable;
	try testing.expectEqualSlices(u8, &expected_bytes, &out);
}

test "blake2sp of 100-byte incrementing pattern" {
	// 100 bytes distributed to first 2 leaves (leaf0: 64 bytes, leaf1: 36 bytes)
	var data: [100]u8 = undefined;
	for (&data, 0..) |*b, i| b.* = @intCast(i);
	var out: [32]u8 = undefined;
	blake2sp(&data, &out);
	const expected = "67d22b8edf2001d86422136ac6516cf39f7fc6a7029892fd75c98790964a720b";
	var expected_bytes: [32]u8 = undefined;
	_ = std.fmt.hexToBytes(&expected_bytes, expected) catch unreachable;
	try testing.expectEqualSlices(u8, &expected_bytes, &out);
}
