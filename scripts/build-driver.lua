package.path = 'scripts/?.lua;' .. package.path
local core, json, ffi = require('build-core'), require('cjson'), require('ffi')
ffi.cdef[[int symlink(const char *, const char *); int rename(const char *, const char *);
int unlink(const char *); int rmdir(const char *); int getpid(void);]]
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function run(command)
	local status = os.execute(command)
	return status == 0
end
local function capture(command)
	local file = assert(io.popen(command))
	local result = file:read('*a')
	file:close()
	return result:gsub('%s+$', '')
end
local function read(path)
	local file = assert(io.open(path, 'rb'), 'cannot open ' .. path)
	local data = file:read('*a'); file:close(); return data
end
local function write(path, data)
	local file = assert(io.open(path, 'wb'), 'cannot write ' .. path)
	assert(file:write(data)); assert(file:close())
end
local function exists(path) return run('test -e ' .. quote(path) .. ' -o -L ' .. quote(path)) end
local function link(path) return run('test -L ' .. quote(path)) end
local function real(path) return capture('command realpath ' .. quote(path) .. ' 2>/dev/null') end
local function hash(path)
	local value = capture('command sha256sum ' .. quote(path))
	return assert(value:match('^([a-f0-9]+)%s'), 'cannot hash ' .. path)
end
local function directories(path)
	local prefix = ''
	for part in path:gmatch('[^/]+') do
		prefix = prefix == '' and part or prefix .. '/' .. part
		assert(not link(prefix), 'directory is a symlink: ' .. prefix)
		assert(run('mkdir -p ' .. quote(prefix)), 'cannot create ' .. prefix)
	end
end
local function replace_link(path, target, identity)
	local temporary = path .. '.' .. identity
	assert(ffi.C.symlink(target, temporary) == 0, 'cannot prepare link ' .. path)
	if ffi.C.rename(temporary, path) ~= 0 then
		ffi.C.unlink(temporary); error('cannot publish ' .. path)
	end
end
local function managed(entry, marker, pf)
	if not exists(entry) then return end
	if pf:match('^mswin%-') then
		assert(not link(entry) and not link(marker) and exists(marker), 'unmanaged Windows entrypoint')
		local record = json.decode(read(marker))
		local actual = hash(entry)
		assert(record.pf == pf and (actual == record.previous_sha or actual == record.next_sha), 'modified Windows entrypoint')
	else
		assert(link(entry), 'unmanaged entrypoint: ' .. entry)
		local target = capture('command readlink ' .. quote(entry))
		assert(target:sub(1, #('../../.nix-out/' .. pf .. '/')) == '../../.nix-out/' .. pf .. '/', 'unmanaged entrypoint link')
	end
end

local registry = json.decode(read('scripts/targets.json'))
local host = core.platform(capture('command uname -s'), capture('command uname -m'))
if arg[1] == '--help' or arg[1] == '-h' then
	print('Usage: ./build [debug|test] [--platform PF|--all-plats] [--all-impls|--all]')
	print('Builds the single Zig/C implementation through Nix; prints complete product paths.')
	os.exit(0)
end
local selection, problem = core.select(arg, host, registry)
if not selection then io.stderr:write('build: ', problem, '\n'); os.exit(64) end

local failures = 0
for _, target in ipairs(selection.targets) do
	local lock
	local ok, problem = pcall(function()
		local pf, profile = target.pf, selection.profile
		local suffix = pf .. (target.variant and '/' .. target.variant or '')
		local windows = pf:match('^mswin%-')
		local command = windows and 'rarz.exe' or 'rarz'
		directories('.build-work')
		lock = '.build-work/publish-' .. pf .. '.lock'
		if not run('mkdir ' .. quote(lock) .. ' 2>/dev/null') then lock = nil; error('another publisher holds ' .. pf) end
		write(lock .. '/owner', tostring(ffi.C.getpid()) .. '\n')
		directories('bin/' .. pf)
		directories('.nix-out/' .. suffix)
		directories('zig-out/' .. suffix)
		local entry, marker = 'bin/' .. pf .. '/' .. command, 'bin/' .. pf .. '/.rarz-build.json'
		managed(entry, marker, pf)
		assert(not link(marker), 'selection record is a symlink')
		local view = 'zig-out/' .. suffix .. '/' .. profile
		if exists(view) then
			assert(link(view), 'unmanaged product tree: ' .. view)
			local destination = capture('command readlink ' .. quote(view))
			assert(destination:match('^%.%./') and destination:find('.nix-out/' .. suffix .. '/', 1, true), 'unmanaged product link')
		end
		local generation = capture('command mktemp -d ' .. quote('.nix-out/' .. suffix .. '/' .. profile .. '.XXXXXXXX'))
		assert(generation ~= '', 'cannot create product generation')
		local identity = generation:match('([^/]+)$')
		io.stderr:write('Building ', pf, ' ', profile, '\n')
		assert(run('command nix build --out-link ' .. quote(generation .. '/result') .. ' ' .. quote('.#' .. core.package(target, profile))), 'Nix build failed; prior command preserved')
		local product = real(generation .. '/result')
		assert(product ~= '', 'Nix returned no product')
		local executable = product .. '/bin/' .. command
		local flags = windows and '--coff-imports' or (pf:match('^macos%-') and '--macho-version-min' or '--program-headers --dynamic-table --needed-libs')
		assert(run('command llvm-readobj --file-header ' .. flags .. ' ' .. quote(executable) .. ' > ' .. quote(generation .. '/inspection.txt')), 'executable inspection failed')
		local dylibs
		if pf:match('^macos%-') then
			assert(run('command llvm-objdump --macho --dylibs-used ' .. quote(executable) .. ' > ' .. quote(generation .. '/dylibs.txt')), 'dependency inspection failed')
			local values = {}
			for line in read(generation .. '/dylibs.txt'):gmatch('[^\n]+') do
				local path = line:match('^%s+([^%s]+)%s+%(')
				if path then values[#values+1] = path end
			end
			dylibs = table.concat(values, '\n')
		end
		local valid, reason = core.verify(target, read(generation .. '/inspection.txt'), dylibs)
		assert(valid, reason)
		if pf == host then
			assert(run('MUTE_DEBUG_STATUS=1 ' .. quote(executable) .. ' --about > ' .. quote(generation .. '/about.txt')), 'native product cannot execute')
			local about = read(generation .. '/about.txt'):gsub('\n$', '')
			assert(not about:find('\n') and (' ' .. about .. ' '):find(' PF=' .. pf .. ' ', 1, true), 'compiled PF differs from product target')
			assert(about:find(', ' .. profile .. ')', 1, true), 'compiled profile differs from requested profile')
			if target.variant then assert(about:find(' VARIANT=' .. target.variant, 1, true), 'compiled ABI differs from product variant') end
		end
		managed(entry, marker, pf)
		local same_entry = windows and exists(entry) and hash(entry) == hash(executable)
			or not windows and real(entry) == executable
		local already = same_entry and real(view) == product
		if already then
			-- Keep the original GC root and selection on an identical rebuild.
			for _, name in ipairs({'result', 'inspection.txt', 'about.txt', 'dylibs.txt'}) do ffi.C.unlink(generation .. '/' .. name) end
			ffi.C.rmdir(generation)
			print(real(view)); return
		end
		local relative_view = capture('command realpath -s --relative-to=' .. quote('zig-out/' .. suffix) .. ' ' .. quote(generation .. '/result'))
		replace_link(view, relative_view, identity)
		if windows then
			local next_sha = hash(executable)
			local previous_sha = exists(entry) and hash(entry) or nil
			local temporary = entry .. '.' .. identity
			assert(run('command cp ' .. quote(executable) .. ' ' .. quote(temporary)), 'cannot stage Windows executable')
			assert(run('command chmod 755 ' .. quote(temporary)), 'cannot set executable permissions')
			-- A prepared record recognizes both sides of an interrupted rename.
			write(marker .. '.' .. identity, json.encode({pf=pf, profile=profile, product=product, previous_sha=previous_sha, next_sha=next_sha}) .. '\n')
			assert(ffi.C.rename(marker .. '.' .. identity, marker) == 0, 'cannot prepare Windows selection record')
			assert(ffi.C.rename(temporary, entry) == 0, 'cannot publish Windows executable')
		else
			replace_link(entry, '../../' .. generation .. '/result/bin/' .. command, identity)
		end
		io.stderr:write('Published ', entry, pf == host and ' (native execution checked)\n' or ' (cross-built; native runtime unverified)\n')
		print(product)
	end)
	if lock then ffi.C.unlink(lock .. '/owner'); ffi.C.rmdir(lock) end
	if not ok then failures = failures + 1; io.stderr:write('build: ', target.pf, ': ', tostring(problem), '\n') end
end
os.exit(failures == 0 and 0 or 1)
