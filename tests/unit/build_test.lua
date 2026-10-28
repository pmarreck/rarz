package.path = 'scripts/?.lua;' .. package.path
local build = require('build-core')
local file = assert(io.open('scripts/targets.json'))
local registry = require('cjson').decode(file:read('*a'))
file:close()
local select = build.select
build.select = function(args, host) return select(args, host, registry) end
local function equal(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local cases = {
	{'Linux', 'x86_64', 'linux-amd64'}, {'Linux', 'aarch64', 'linux-arm64'},
	{'Darwin', 'arm64', 'macos-arm64'}, {'Windows_NT', 'AMD64', 'mswin-amd64'},
	{'MINGW64_NT-10.0', 'x86_64', 'mswin-amd64'}, {'MSYS_NT', 'ARM64', 'mswin-arm64'},
	{'CYGWIN_NT', 'amd64', 'mswin-amd64'}, {'FreeBSD', 'amd64', nil},
	{'Darwin', 'x86_64', nil}, {'Linux', 'riscv64', nil}, {'unknown', 'arm64', nil},
}
for _, row in ipairs(cases) do equal(build.platform(row[1], row[2]), row[3]) end
local function selected(args)
	local result = assert(build.select(args, 'linux-amd64'))
	local names = {}
	for _, target in ipairs(result.targets) do names[#names+1] = target.pf end
	return table.concat(names, ','), result
end
equal(selected({}), 'linux-amd64')
equal(selected({'--all-impls'}), 'linux-amd64')
local all = 'linux-amd64,linux-arm64,macos-arm64,mswin-amd64,mswin-arm64'
for _, args in ipairs({{'--all'}, {'--all-plats'}, {'--all-platforms'},
	{'--all-impls', '--all-platforms'}, {'--all-platforms', '--all-implementations'},
	{'--all', '--all-plats', '--all-impls'}}) do equal(selected(args), all) end
local _, debug = selected({'debug'})
equal(debug.profile, 'Debug')
local _, safe = selected({'test'})
equal(safe.profile, 'ReleaseSafe')
equal(safe.targets[1].variant, 'musl')
equal(safe.targets[1].triple, 'x86_64-linux-musl')
local _, windows = selected({'--platform', 'mswin-arm64'})
equal(windows.targets[1].variant, nil)
equal(windows.targets[1].triple, 'aarch64-windows-gnu')
for _, args in ipairs({{'--backend=direct'}, {'canonize', 'rust'}, {'--platform'},
	{'--platform', 'linux-mips'}, {'--all', '--platform', 'linux-amd64'}, {'surprise'}}) do
	assert(not build.select(args, 'linux-amd64'))
end
assert(not build.select({}, nil))
equal(build.package(safe.targets[1], safe.profile), 'linux-amd64-musl-ReleaseSafe')
equal(build.package(windows.targets[1], 'ReleaseFast'), 'mswin-arm64-ReleaseFast')
local reports = {
	'Format: elf64-x86-64\nArch: x86_64\nType: Executable\nNeededLibraries [\n]\n',
	'Format: elf64-littleaarch64\nArch: aarch64\nType: Executable\nNeededLibraries [\n]\n',
	'Format: Mach-O arm64\nArch: aarch64\nFileType: Executable\n',
	'Format: COFF-x86-64\nArch: x86_64\nIMAGE_FILE_EXECUTABLE_IMAGE\nImport {\n  Name: KERNEL32.dll\n}\n',
	'Format: COFF-ARM64\nArch: aarch64\nIMAGE_FILE_EXECUTABLE_IMAGE\nImport {\n  Name: KERNEL32.dll\n}\n',
}
for i, target in ipairs(registry) do
	for j, report in ipairs(reports) do
		equal(not not build.verify(target, report, '/usr/lib/libSystem.B.dylib'), i == j)
	end
	assert(not build.verify(target, ''))
end
assert(not build.verify(registry[1], reports[1] .. 'Type: PT_INTERP\n'))
assert(not build.verify(registry[1], reports[1]:gsub('NeededLibraries %[\n%]', 'NeededLibraries [\nlibc.so.6\n]')))
assert(not build.verify(registry[3], reports[3], '/nix/store/private/lib.dylib'))
assert(not build.verify(registry[4], reports[4]:gsub('KERNEL32.dll', 'missing.dll')))
print('PASS: platform/scope sets, profiles, executable headers, and runtime dependencies')
