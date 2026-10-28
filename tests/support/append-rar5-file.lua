-- Append an unchanged producer file block before another archive's ENDARC.
-- Reference checks disable quick-open so a cached listing cannot hide it.
local bit = require('bit')
local function read(path)
	local f = assert(io.open(path, 'rb'))
	local bytes = assert(f:read('*a')); assert(f:close())
	assert(bytes:sub(1, 8) == 'Rar!\26\7\1\0')
	return bytes
end
local function vint(bytes, pos)
	local value, factor = 0, 1
	for _ = 1, 8 do
		local byte = assert(bytes:byte(pos)); pos = pos + 1
		value = value + bit.band(byte, 127) * factor
		assert(value < 2^53, 'fixture integer too large')
		if byte < 128 then return value, pos end
		factor = factor * 128
	end
	error('fixture VINT overflow')
end
local function blocks(bytes)
	local pos, files = 9, {}
	while pos <= #bytes do
		local size, cursor = vint(bytes, pos + 4)
		local header_end = cursor + size
		local kind, flags, ignored, payload
		kind, cursor = vint(bytes, cursor)
		flags, cursor = vint(bytes, cursor)
		if bit.band(flags, 1) ~= 0 then ignored, cursor = vint(bytes, cursor) end
		payload = 0
		if bit.band(flags, 2) ~= 0 then payload, cursor = vint(bytes, cursor) end
		local next_pos = header_end + payload
		assert(header_end >= cursor and next_pos - 1 <= #bytes)
		if kind == 5 then return files, pos end
		if kind == 2 then files[#files + 1] = bytes:sub(pos, next_pos - 1) end
		pos = next_pos
	end
	error('fixture missing ENDARC')
end
local history, literal = read(arg[1]), read(arg[2])
local _, end_pos = blocks(history)
local files = blocks(literal)
assert(#files == 1, 'literal fixture must contain exactly one file')
local output = assert(io.open(arg[3], 'wb'))
assert(output:write(history:sub(1, end_pos - 1), files[1], history:sub(end_pos)))
assert(output:close())
