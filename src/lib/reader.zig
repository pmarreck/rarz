const std = @import("std");
const testing = std.testing;

pub const Reader = struct {
	data: []const u8,
	pos: usize,

	pub const Error = error{EndOfData};

	pub fn init(data: []const u8) Reader {
		return .{ .data = data, .pos = 0 };
	}

	pub fn read_u8(self: *Reader) Error!u8 {
		if (self.pos >= self.data.len) return error.EndOfData;
		const val = self.data[self.pos];
		self.pos += 1;
		return val;
	}

	pub fn read_u16_le(self: *Reader) Error!u16 {
		if (self.pos + 2 > self.data.len) return error.EndOfData;
		const val = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
		self.pos += 2;
		return val;
	}

	pub fn read_u32_le(self: *Reader) Error!u32 {
		if (self.pos + 4 > self.data.len) return error.EndOfData;
		const val = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
		self.pos += 4;
		return val;
	}

	pub fn read_vint(self: *Reader) Error!u64 {
		var result: u64 = 0;
		var shift: u7 = 0;
		var count: usize = 0;
		while (true) {
			if (self.pos >= self.data.len) return error.EndOfData;
			if (count >= 10) return error.EndOfData;
			const byte = self.data[self.pos];
			self.pos += 1;
			const value_bits: u64 = @intCast(byte & 0x7F);
			result |= value_bits << @as(u6, @intCast(shift));
			count += 1;
			if (byte & 0x80 == 0) break;
			shift += 7;
		}
		return result;
	}

	pub fn read_bytes(self: *Reader, len: usize) Error![]const u8 {
		if (self.pos + len > self.data.len) return error.EndOfData;
		const slice = self.data[self.pos .. self.pos + len];
		self.pos += len;
		return slice;
	}

	pub fn skip(self: *Reader, len: usize) Error!void {
		if (self.pos + len > self.data.len) return error.EndOfData;
		self.pos += len;
	}

	pub fn remaining(self: Reader) usize {
		return self.data.len - self.pos;
	}

	pub fn position(self: Reader) usize {
		return self.pos;
	}
};

// === TESTS ===

test "read_u8 returns byte and advances" {
	var r = Reader.init(&[_]u8{ 0xAB, 0xCD });
	const val = try r.read_u8();
	try testing.expectEqual(@as(u8, 0xAB), val);
	try testing.expectEqual(@as(usize, 1), r.pos);
}

test "read_u8 at end returns EndOfData" {
	var r = Reader.init(&[_]u8{});
	const result = r.read_u8();
	try testing.expectError(error.EndOfData, result);
}

test "read_u16_le decodes little-endian" {
	var r = Reader.init(&[_]u8{ 0x34, 0x12 });
	const val = try r.read_u16_le();
	try testing.expectEqual(@as(u16, 0x1234), val);
	try testing.expectEqual(@as(usize, 2), r.pos);
}

test "read_u16_le at end returns EndOfData" {
	var r = Reader.init(&[_]u8{0x34});
	const result = r.read_u16_le();
	try testing.expectError(error.EndOfData, result);
}

test "read_u32_le decodes little-endian" {
	var r = Reader.init(&[_]u8{ 0x78, 0x56, 0x34, 0x12 });
	const val = try r.read_u32_le();
	try testing.expectEqual(@as(u32, 0x12345678), val);
	try testing.expectEqual(@as(usize, 4), r.pos);
}

test "read_u32_le at end returns EndOfData" {
	var r = Reader.init(&[_]u8{ 0x78, 0x56 });
	const result = r.read_u32_le();
	try testing.expectError(error.EndOfData, result);
}

test "read_vint single byte" {
	var r = Reader.init(&[_]u8{0x42});
	const val = try r.read_vint();
	try testing.expectEqual(@as(u64, 0x42), val);
	try testing.expectEqual(@as(usize, 1), r.pos);
}

test "read_vint two bytes" {
	// byte0: 0x81 = continue bit set, value bits = 0x01
	// byte1: 0x42 = no continue, value bits = 0x42
	// result = 0x01 | (0x42 << 7) = 0x01 | 0x2100 = 0x2101
	var r = Reader.init(&[_]u8{ 0x81, 0x42 });
	const val = try r.read_vint();
	try testing.expectEqual(@as(u64, 0x2101), val);
	try testing.expectEqual(@as(usize, 2), r.pos);
}

test "read_vint max single byte value" {
	// 0x7F = all 7 value bits set, no continue bit
	var r = Reader.init(&[_]u8{0x7F});
	const val = try r.read_vint();
	try testing.expectEqual(@as(u64, 0x7F), val);
}

test "read_vint rejects overlong" {
	// 11 bytes all with continue bit set
	var r = Reader.init(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80 });
	const result = r.read_vint();
	try testing.expectError(error.EndOfData, result);
}

test "read_vint at end of data" {
	var r = Reader.init(&[_]u8{});
	const result = r.read_vint();
	try testing.expectError(error.EndOfData, result);
}

test "read_bytes returns correct slice" {
	const data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
	var r = Reader.init(&data);
	const slice = try r.read_bytes(3);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, slice);
	try testing.expectEqual(@as(usize, 3), r.pos);
}

test "read_bytes past end returns EndOfData" {
	var r = Reader.init(&[_]u8{ 0x01, 0x02 });
	const result = r.read_bytes(5);
	try testing.expectError(error.EndOfData, result);
}

test "skip advances position" {
	var r = Reader.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 });
	try r.skip(3);
	try testing.expectEqual(@as(usize, 3), r.pos);
}

test "skip past end returns EndOfData" {
	var r = Reader.init(&[_]u8{ 0x01, 0x02 });
	const result = r.skip(5);
	try testing.expectError(error.EndOfData, result);
}

test "remaining decreases after reads" {
	var r = Reader.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });
	try testing.expectEqual(@as(usize, 4), r.remaining());
	_ = try r.read_u8();
	try testing.expectEqual(@as(usize, 3), r.remaining());
	_ = try r.read_u16_le();
	try testing.expectEqual(@as(usize, 1), r.remaining());
}

test "position increases after reads" {
	var r = Reader.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });
	try testing.expectEqual(@as(usize, 0), r.position());
	_ = try r.read_u8();
	try testing.expectEqual(@as(usize, 1), r.position());
	_ = try r.read_u16_le();
	try testing.expectEqual(@as(usize, 3), r.position());
}

test "sequential reads work correctly" {
	var r = Reader.init(&[_]u8{ 0xAA, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x42 });
	// read_u8
	const byte = try r.read_u8();
	try testing.expectEqual(@as(u8, 0xAA), byte);
	// read_u16_le
	const word = try r.read_u16_le();
	try testing.expectEqual(@as(u16, 0x1234), word);
	// read_u32_le
	const dword = try r.read_u32_le();
	try testing.expectEqual(@as(u32, 0x12345678), dword);
	// read_vint (single byte, no continue)
	const vint = try r.read_vint();
	try testing.expectEqual(@as(u64, 0x42), vint);
	// should be at end
	try testing.expectEqual(@as(usize, 0), r.remaining());
}
