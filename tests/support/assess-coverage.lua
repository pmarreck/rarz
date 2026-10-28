local json=require('cjson.safe')
local root=arg[0]:match('^(.*)/tests/support/assess%-coverage%.lua$')
local stats=dofile(root..'/tests/support/coverage.lua')
local function quote(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
local function read(path)
	local f=io.open(path,'rb'); if not f then return nil end
	local data=f:read('*a'); f:close(); return data
end
local function write(path,data)
	local f=assert(io.open(path,'wb')); assert(f:write(data)); assert(f:close())
end
local function encode(value) return assert(json.encode(value)) end
local function output(command)
	local f=assert(io.popen(command)); local s=f:read('*a'); f:close(); return s
end
local function platform()
	local build=dofile(root..'/scripts/build-core.lua')
	return assert(build.platform(output('uname -s'):gsub('%s+$',''),output('uname -m'):gsub('%s+$','')),'unsupported execution platform')
end
local function absolute(path) return output('realpath -z -- '..quote(path)):gsub('%z$','') end
local function hash(path)
	local s=output('sha256sum -- '..quote(path)):match('([a-f0-9]+)')
	assert(s and #s==64,'cannot hash input or executable'); return s
end
local function resolve(exe)
	local path=output('command -v '..quote(exe)):gsub('\n$','')
	assert(path~='','missing executable: '..exe); return absolute(path)
end
local function status(raw)
	if raw%128~=0 then return 128+raw%128 end
	return math.floor(raw/256)
end
local help=[[Usage: ./assess-coverage [options] [RAR ...]
Estimate detection of reference-confirmed damage, per input/profile pair.
Defaults: three producer fixtures (RAR2, RAR4, RAR5), six mutation profiles,
95% pointwise Wilson intervals, at most 5 percentage points half-width.

  --output DIR        New report directory (default: private temporary dir)
  --profile NAME      Repeat to select profiles; JSON profile paths accepted
  --master SEED       Replay seed (default: 42)
  --confidence N      0.90, 0.95 or 0.99 (default: 0.95)
  --margin N          Interval half-width, 0 < N < 0.5 (default: 0.05)
  --max-attempts N    Per-pair cap (default: 4 times fixed sample target)
  --timeout SECONDS   Per-process wall limit (default: 10)
  --memory-mib N      Per-process virtual-memory limit (default: 1024)
  --rarz PATH         Validator (default: project bin/PF/rarz)
  --mutator PATH      corruption-reader 0.7.0 or newer
  --reference PATH    Official unrar executable
  -h, --help          Show this help
  --about             One-line tool/version/platform description

JSON summary goes to stdout; progress and report location go to stderr.
Reports preserve every case record and observation for replay. Inputs must
be independently valid, unencrypted, standalone archives. No volume-set
mutation or v70 run is implied by the defaults. Exit: 0 complete/no findings,
1 complete with misses or disagreements, 2 incomplete or execution error.
Use - or @stdin once to retain a private input snapshot for repeated trials.
]]
local options={confidence=0.95,margin=0.05,master='42',timeout=10,memory_mib=1024,
	rarz=os.getenv('RARZ'),mutator=os.getenv('CORRUPTION_READER') or 'corruption-reader',
	reference=os.getenv('UNRAR') or 'unrar'}
local inputs,profiles={},{}
local keys={['--output']='output',['--master']='master',['--confidence']='confidence',
	['--margin']='margin',['--max-attempts']='max_attempts',['--timeout']='timeout',
	['--memory-mib']='memory_mib',['--rarz']='rarz',['--mutator']='mutator',['--reference']='reference'}
local numeric={confidence=true,margin=true,max_attempts=true,timeout=true,memory_mib=true}
local function main()
	local i=1
	while i<=#arg do
		local a=arg[i]
		if a=='--help' or a=='-h' then io.write(help); return 0 end
		if a=='--about' then print('rarz assess-coverage 1: reproducible RAR corruption assessment; PF='..platform()); return 0 end
		if a=='--' then for j=i+1,#arg do inputs[#inputs+1]=arg[j] end; break end
		if a=='--profile' or keys[a] then
			i=i+1; assert(arg[i],'missing value for '..a)
			if a=='--profile' then profiles[#profiles+1]=arg[i]
			else options[keys[a]]=numeric[keys[a]] and assert(tonumber(arg[i]),'invalid number') or arg[i] end
		elseif a:sub(1,1)=='-' and a~='-' then error('unknown option '..a)
		else inputs[#inputs+1]=a end
		i=i+1
	end
	local target=stats.sample_size(options.confidence,options.margin)
	options.max_attempts=options.max_attempts or 4*target
	for _,key in ipairs({'max_attempts','timeout','memory_mib'}) do
		assert(options[key]>0 and options[key]%1==0 and options[key]<=1000000,'invalid '..key)
	end
	if #profiles==0 then profiles={'sniper','bolter','shotgun_variable','nuke','robespierre','badonkachomp'} end
	if #inputs==0 then
		for _,name in ipairs({'rar2_v20_m3','rar4_m3','rar5_m3'}) do inputs[#inputs+1]=root..'/tests/fixtures/'..name..'.rar' end
	end
	local seen={}
	for i,path in ipairs(inputs) do
		inputs[i]=(path=='-' or path=='@stdin') and '@stdin' or absolute(path)
		assert(inputs[i]~='' and not seen[inputs[i]],'missing or duplicate input')
		seen[inputs[i]]=true
	end
	seen={}
	for _,profile in ipairs(profiles) do assert(not seen[profile],'duplicate profile'); seen[profile]=true end
	options.rarz=options.rarz or root..'/bin/'..platform()..'/rarz'
	for _,key in ipairs({'rarz','mutator','reference'}) do options[key]=resolve(options[key]) end
	local dir
	if options.output then
		assert(os.execute('mkdir -- '..quote(options.output))==0,'report directory must be new')
		dir=absolute(options.output)
	else dir=output('mktemp -d '..quote((os.getenv('TMPDIR') or '/tmp')..'/rarz-coverage.XXXXXXXX')):gsub('\n$','') end
	assert(dir and dir~='','cannot create report directory')
	assert(os.execute('chmod 700 '..quote(dir)..'; mkdir '..quote(dir..'/cases'))==0)
	io.stderr:write('Assessment reports: '..dir..'\n')
	for i,path in ipairs(inputs) do if path=='@stdin' then
		inputs[i]=dir..'/stdin.rar'
		local f=assert(io.open(inputs[i],'wb'))
		while true do
			local chunk,err=io.stdin:read(65536)
			assert(not err,err); if not chunk then break end
			assert(f:write(chunk))
		end
		assert(f:close())
	end end
	local report={schema='rarz-coverage/v1',status='running',options=options,cells={},inputs={},tools={},
		reference_args={'t','-p-','-idq','-qo-'},
		confidence_scope='pointwise per input/profile; no pooled or simultaneous confidence claim',
		method='fixed reference-damaged sample; Wilson score interval; PRNG draws with replacement',target=target}
	local function checkpoint() write(dir..'/summary.json',encode(report)..'\n') end
	checkpoint()
	local function run(argv)
		local words={}; for _,v in ipairs(argv) do words[#words+1]=quote(v) end
		local command='(ulimit -c 0; ulimit -v '..(options.memory_mib*1024)..' || exit 125; exec timeout -k 2 '..options.timeout..' '..table.concat(words,' ')..' </dev/null)'
		local rc=status(os.execute(command..' >'..quote(dir..'/stdout.tmp')..' 2>'..quote(dir..'/stderr.tmp')))
		local function limited(path)
			local f=assert(io.open(path,'rb')); local s=f:read(65536) or ''; local extra=f:read(1); f:close(); return s,extra~=nil
		end
		local out,ot=limited(dir..'/stdout.tmp'); local err,et=limited(dir..'/stderr.tmp')
		return {exit=rc,stdout=out,stderr=err,truncated=ot or et,
			kind=rc==124 and 'timeout' or rc>=128 and 'signal' or 'exit'}
	end
	local function observe(path)
		local r=run({options.rarz,'t',path})
		r.class=r.truncated and 'tool-error' or stats.rarz(r.exit,r.stdout)
		local args={options.reference}
		for _,value in ipairs(report.reference_args) do args[#args+1]=value end
		args[#args+1]=path
		local u=run(args)
		u.class=u.truncated and 'tool-error' or stats.reference(u.exit,u.stderr)
		return r,u
	end
	for _,key in ipairs({'rarz','mutator','reference'}) do
		local about=run(key=='reference' and {options[key]} or {options[key],'--about'})
		report.tools[key]={path=options[key],sha256=hash(options[key]),about=about.stdout..about.stderr}
	end
	assert(stats.consumer_version(report.tools.mutator.about),'consumer CLI v1 requires corruption-reader >=0.7.0')
	local records=assert(io.open(dir..'/trials.jsonl','wb'))
	local serial=0
	local function log(value) assert(records:write(encode(value)..'\n')); assert(records:flush()) end
	local ok,problem=pcall(function()
		for _,path in ipairs(inputs) do
			local item={path=path,sha256=hash(path)}; report.inputs[#report.inputs+1]=item
			local r,u=observe(path); item.rarz=r; item.reference=u
			assert(r.class=='valid' and u.class=='valid','pristine input is not accepted by both tools: '..path)
			assert(not r.stdout:find('Encrypted: yes',1,true),'encrypted inputs are not fully verified')
			assert(not r.stdout:match('%(%d+ volumes%)'),'volume sets require a separate mutation adapter')
		end
		for _,input in ipairs(report.inputs) do for _,profile in ipairs(profiles) do
			local cell={input=input.path,input_sha256=input.sha256,profile=profile,attempts=0,eligible=0,detected=0,
				counts={detected=0,missed=0,disagreement=0,survived=0,inconclusive=0,unverifiable=0,noop=0,unchanged=0},retained=0}
			report.cells[#report.cells+1]=cell
			for round=0,options.max_attempts-1 do
				serial=serial+1; cell.attempts=cell.attempts+1
				local mutant=dir..'/mutant.rar'
				local raw_report=dir..'/mutation.jsonl'
				os.remove(raw_report); os.remove(mutant)
				local m=run({options.mutator,'corrupt',profile,'--master',options.master,'--round',round,'--emit','stream','--report',raw_report,'-o',mutant,input.path})
				local mutation,decode_error=json.decode(read(raw_report) or '')
				assert((m.exit==0 or m.exit==3) and mutation and mutation.report==1 and mutation.item==0 and mutation.round==round and mutation.emitted==true and type(mutation.record)=='table',
					'mutator contract failure: '..(decode_error or m.stderr))
				assert((m.exit==0 and mutation.status=='applied' and mutation.noop==json.null) or
					(m.exit==3 and mutation.status=='noop' and (mutation.noop=='too_small' or mutation.noop=='no_events' or mutation.noop=='non_candidate')),'inconsistent no-op report')
				local comparison=status(os.execute('cmp -s -- '..quote(input.path)..' '..quote(mutant)))
				assert(comparison==0 or comparison==1,'cannot compare emitted bytes')
				local trial={id=serial,input=input.path,profile=profile,round=round,mutation=mutation,mutant_sha256=hash(mutant)}
				local outcome
				if mutation.status=='noop' then assert(comparison==0,'no-op changed bytes'); outcome='noop'
				elseif comparison==0 then outcome='unchanged'
				else
					trial.rarz,trial.reference=observe(mutant)
					outcome=stats.pair(trial.reference.class,trial.rarz.class)
					if trial.reference.class=='damaged' then cell.eligible=cell.eligible+1 end
					if outcome=='detected' then cell.detected=cell.detected+1 end
				end
				trial.outcome=outcome; cell.counts[outcome]=cell.counts[outcome]+1
				if outcome~='detected' and outcome~='survived' and outcome~='noop' and outcome~='unchanged' and cell.retained<50 then
					cell.retained=cell.retained+1
					local prefix=dir..'/cases/'..serial
					assert(os.execute('cp -- '..quote(mutant)..' '..quote(prefix..'.rar'))==0)
					write(prefix..'.json',encode(mutation.record)..'\n'); trial.retained=prefix
				end
				log(trial)
				if cell.eligible==target or mutation.noop=='too_small' or mutation.noop=='non_candidate' then break end
			end
			local lo,hi=stats.wilson(cell.detected,cell.eligible,stats.z[options.confidence])
			cell.interval=lo and {lower=lo,upper=hi} or json.null
			cell.rate=cell.eligible>0 and cell.detected/cell.eligible or json.null
			cell.precision_met=cell.eligible==target and (hi-lo)/2<=options.margin
			io.stderr:write(string.format('%s / %s: %d/%d detected; %d attempts; precision %s\n',input.path,profile,cell.detected,cell.eligible,cell.attempts,tostring(cell.precision_met)))
			checkpoint()
		end end
	end)
	assert(records:close())
	report.inputs_unchanged=true
	for _,input in ipairs(report.inputs) do if hash(input.path)~=input.sha256 then report.inputs_unchanged=false end end
	local incomplete=not ok or not report.inputs_unchanged
	local findings=false
	for _,cell in ipairs(report.cells) do
		if not cell.precision_met or cell.counts.inconclusive>0 or cell.counts.unverifiable>0 then incomplete=true end
		if cell.counts.missed>0 or cell.counts.disagreement>0 then findings=true end
	end
	report.status=incomplete and 'incomplete' or findings and 'complete-with-findings' or 'complete'
	report.error=not ok and tostring(problem) or json.null
	checkpoint(); io.write(encode(report)..'\n')
	if ok then
		os.remove(dir..'/mutant.rar'); os.remove(dir..'/stdout.tmp'); os.remove(dir..'/stderr.tmp'); os.remove(dir..'/mutation.jsonl')
	end
	return incomplete and 2 or findings and 1 or 0
end
local ok,result=pcall(main)
if not ok then io.stderr:write('assess-coverage: '..tostring(result)..'\n'); os.exit(2) end
os.exit(result)
