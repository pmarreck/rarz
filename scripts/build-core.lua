local M = {}

function M.platform(os, arch)
	os, arch = os:lower(), arch:lower()
	if os == 'darwin' then os = 'macos' end
	if os:match('^windows') or os:match('^mingw') or os:match('^msys') or os:match('^cygwin') then os = 'mswin' end
	if arch == 'x86_64' then arch = 'amd64' end
	if arch == 'aarch64' then arch = 'arm64' end
	if arch ~= 'amd64' and arch ~= 'arm64' then return nil end
	if os == 'linux' or os == 'mswin' or (os == 'macos' and arch == 'arm64') then return os .. '-' .. arch end
end

function M.package(target, profile)
	return target.pf .. (target.variant and '-' .. target.variant or '') .. '-' .. profile
end

function M.select(args, host, registry)
	local all, platform, profile = false, nil, 'ReleaseFast'
	local i = 1
	while i <= #args do
		local value = args[i]
		if value == '--all' or value == '--all-plats' or value == '--all-platforms' then all = true
		elseif value == '--all-impls' or value == '--all-implementations' then -- One executable implementation.
		elseif value == 'debug' then profile = 'Debug'
		elseif value == 'test' then profile = 'ReleaseSafe'
		elseif value == '--platform' then
			i = i + 1
			platform = args[i]
			if not platform then return nil, '--platform requires a canonical PF' end
		else return nil, 'unknown build argument: ' .. value end
		i = i + 1
	end
	if all and platform then return nil, '--platform conflicts with --all-platforms' end
	if not all and not platform and not host then return nil, 'unsupported host platform' end
	local targets = {}
	for _, target in ipairs(registry) do
		if all or target.pf == (platform or host) then targets[#targets+1] = target end
	end
	if #targets == 0 then return nil, 'unsupported target platform' end
	return {targets=targets, profile=profile}
end

-- Consume independent LLVM inspection, never producer-written target metadata.
function M.verify(target, report, dylibs)
	local text = '\n' .. report
	local format = text:match('\nFormat: ([^\n]+)') or ''
	local arch = text:match('\nArch: ([^\n]+)')
	local expected = target.pf:match('amd64$') and 'x86_64' or 'aarch64'
	if arch ~= expected then return nil, 'executable architecture mismatch' end
	if target.pf:match('^linux%-') then
		if not format:match('^elf64') or not text:find('Type: Executable', 1, true) then return nil, 'expected an ELF executable' end
		local needed = text:match('NeededLibraries %[(.-)%]')
		if needed == nil or needed:match('%S') or text:find('PT_INTERP', 1, true) then return nil, 'musl product must be static with no external loader' end
	elseif target.pf:match('^macos%-') then
		if not format:match('^Mach%-O') or not text:find('FileType: Executable', 1, true) then return nil, 'expected a Mach-O executable' end
		local count = 0
		for path in (dylibs or ''):gmatch('[^\n]+') do
			if not path:match('^/usr/lib/') and not path:match('^/System/Library/Frameworks/') then return nil, 'non-system macOS library: ' .. path end
			count = count + 1
		end
		if count == 0 then return nil, 'missing macOS dependency inspection' end
	elseif target.pf:match('^mswin%-') then
		if not format:match('^COFF') or not text:find('IMAGE_FILE_EXECUTABLE_IMAGE', 1, true) or text:find('IMAGE_FILE_DLL', 1, true) then return nil, 'expected a PE executable' end
		local system = {['kernel32.dll']=true, ['ntdll.dll']=true, ['msvcrt.dll']=true,
			['ucrtbase.dll']=true, ['advapi32.dll']=true, ['user32.dll']=true, ['shell32.dll']=true,
			['ws2_32.dll']=true, ['bcrypt.dll']=true, ['crypt32.dll']=true, ['ole32.dll']=true,
			['gdi32.dll']=true, ['secur32.dll']=true}
		local count = 0
		for name in text:gmatch('\n%s+Name: ([^\n]+)') do
			name = name:lower()
			if not system[name] and not name:match('^api%-ms%-win%-[%w%-]+%.dll$') then return nil, 'unbundled Windows DLL: ' .. name end
			count = count + 1
		end
		if count == 0 then return nil, 'missing Windows import inspection' end
	else return nil, 'unsupported executable platform' end
	return true
end

return M
