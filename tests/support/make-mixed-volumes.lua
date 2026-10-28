-- Put two unchanged producer FILE records in numbered, independently tested volumes.
-- The source fixture contains plain.txt followed by encrypted secret.txt.
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
local function crc(s)
	local c=0xffffffff
	for i=1,#s do
		c=bit.bxor(c,s:byte(i))
		for _=1,8 do c=bit.bxor(bit.rshift(c,1),bit.band(c,1)==1 and 0xedb88320 or 0) end
	end
	return bit.bnot(c)
end
local function block(kind, body)
	local s=string.char(2+#body, kind, 0)..body
	local c=crc(s)
	return string.char(bit.band(c,255),bit.band(bit.rshift(c,8),255),bit.band(bit.rshift(c,16),255),bit.band(bit.rshift(c,24),255))..s
end
local source=read(arg[1]);local files=blocks(source)
assert(#files==2)
assert(arg[3]=='plain-first' or arg[3]=='encrypted-first', 'unknown fixture order')
local groups=arg[3]=='plain-first' and {files[1],files[2]} or {files[2],files[1]}
for i=1,2 do
	local output=assert(io.open(arg[2]..'.part'..i..'.rar','wb'))
	output:write(source:sub(1,8),block(1,string.char(3,i-1)),groups[i],block(5,string.char(i==1 and 1 or 0)))
	assert(output:close())
end
