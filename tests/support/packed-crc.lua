-- Independent fixture adapter: verify a packed-part CRC or alter only that field.
local bit = require('bit')
local function crc32(bytes)
	local crc = -1
	for i = 1, #bytes do
		crc = bit.bxor(crc, bytes:byte(i))
		for _ = 1, 8 do
			crc = bit.bxor(bit.rshift(crc, 1), bit.band(crc, 1) == 1 and 0xedb88320 or 0)
		end
	end
	return bit.bnot(crc) % 2^32
end
assert(crc32('123456789') == 0xcbf43926)
local function le(bytes, pos, count)
	local value = 0
	for i = 0, count - 1 do value = value + assert(bytes:byte(pos + i)) * 256^i end
	return value
end
local function encoded(value, count)
	local bytes = {}
	for i = 1, count do bytes[i] = string.char(value % 256); value = math.floor(value / 256) end
	return table.concat(bytes)
end
local function vint(bytes, pos)
	local value, factor = 0, 1
	for _ = 1, 10 do
		local byte = assert(bytes:byte(pos)); pos = pos + 1
		value = value + bit.band(byte, 127) * factor
		if byte < 128 then return value, pos end
		factor = factor * 128
	end
	error('fixture VINT overflow')
end
local mode, input, output = arg[1], arg[2], arg[3]
assert(mode == 'check' or mode == 'mutate')
local handle = assert(io.open(input, 'rb'))
local bytes = assert(handle:read('*a')); handle:close()
local rar5 = bytes:sub(1, 8) == 'Rar!\26\7\1\0'
assert(rar5 or bytes:sub(1, 7) == 'Rar!\26\7\0', 'fixture format')
local pos = rar5 and 9 or 8
while pos < #bytes do
	local header_end, payload_size, split, checksum, crc_bytes
	if rar5 then
		local size, cursor = vint(bytes, pos + 4)
		header_end = cursor + size
		local kind, flags
		kind, cursor = vint(bytes, cursor)
		flags, cursor = vint(bytes, cursor)
		if bit.band(flags, 1) ~= 0 then local extra; extra, cursor = vint(bytes, cursor) end
		payload_size = 0
		if bit.band(flags, 2) ~= 0 then payload_size, cursor = vint(bytes, cursor) end
		if kind == 2 and bit.band(flags, 16) ~= 0 then
			local file_flags, ignored
			file_flags, cursor = vint(bytes, cursor)
			ignored, cursor = vint(bytes, cursor)
			ignored, cursor = vint(bytes, cursor)
			if bit.band(file_flags, 2) ~= 0 then cursor = cursor + 4 end
			assert(bit.band(file_flags, 4) ~= 0, 'fixture needs CRC32')
			checksum, split = cursor, true
		end
		crc_bytes = 4
	else
		local flags = le(bytes, pos + 3, 2)
		header_end = pos + le(bytes, pos + 5, 2)
		payload_size = bit.band(flags, 0x8000) ~= 0 and le(bytes, pos + 7, 4) or 0
		if bytes:byte(pos + 2) == 0x74 and bit.band(flags, 2) ~= 0 then
			checksum, split = pos + 16, true
		end
		crc_bytes = 2
	end
	assert(header_end > pos and header_end + payload_size - 1 <= #bytes, 'fixture bounds')
	if split then
		assert(le(bytes, pos, crc_bytes) == crc32(bytes:sub(pos + crc_bytes, header_end - 1)) % 256^crc_bytes, 'fixture header CRC')
		assert(le(bytes, checksum, 4) == crc32(bytes:sub(header_end, header_end + payload_size - 1)), 'packed-part CRC mismatch')
		if mode == 'mutate' then
			bytes = bytes:sub(1, checksum - 1) .. string.char(bit.bxor(bytes:byte(checksum), 1)) .. bytes:sub(checksum + 1)
			local header_crc = crc32(bytes:sub(pos + crc_bytes, header_end - 1)) % 256^crc_bytes
			bytes = bytes:sub(1, pos - 1) .. encoded(header_crc, crc_bytes) .. bytes:sub(pos + crc_bytes)
			handle = assert(io.open(assert(output), 'wb')); assert(handle:write(bytes)); assert(handle:close())
		end
		return
	end
	pos = header_end + payload_size
end
error('fixture contains no split part')
