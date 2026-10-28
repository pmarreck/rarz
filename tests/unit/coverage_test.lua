local c = dofile('tests/support/coverage.lua')
local function near(a,b,e) assert(math.abs(a-b)<(e or 1e-6), tostring(a)..' != '..tostring(b)) end
assert(c.sample_size(0.95,0.05)==385)
assert(c.sample_size(0.99,0.01)==16588)
-- NIST/SEMATECH handbook prc241: 26/200, one-sided z=1.645 -> 0.09577.
local low = c.wilson(26,200,1.645)
near(low,0.09577,0.00001)
for n=1,400 do
	for k=0,n do
		local lo,hi=c.wilson(k,n,1.959963984540054)
		assert(lo>=0 and hi<=1 and lo<=k/n and hi>=k/n)
		local rlo,rhi=c.wilson(n-k,n,1.959963984540054)
		near(lo,1-rhi); near(hi,1-rlo)
		if n>=385 then assert((hi-lo)/2<=0.05) end
	end
end
assert(c.wilson(0,0,1.96)==nil)
for _,version in ipairs({'0.7.0','0.10.0','1.0.0','10.2.3'}) do
	assert(c.consumer_version('corruption-reader '..version..' (linux/x86_64)'))
	assert(c.consumer_version('corruption-reader '..version..': deterministic replayable corruption'))
end
for _,version in ipairs({'0.3.0','0.6.9','unknown','0.7','0.7.0garbage'}) do
	assert(not c.consumer_version('corruption-reader '..version))
end
for status=0,255 do
	for _,verdict in ipairs({'VALID','INVALID','UNVERIFIABLE','unknown'}) do
		local expected='tool-error'
		if status==0 and verdict=='VALID' then expected='valid' end
		if status==1 and verdict=='INVALID' then expected='damaged' end
		if status==69 and verdict=='UNVERIFIABLE' then expected='unverifiable' end
		assert(c.rarz(status,'Validation: '..verdict..'\n')==expected)
	end
	assert(c.rarz(status,'')=='tool-error')
	assert(c.rarz(status,'Validation: VALID\nValidation: VALID\n')=='tool-error')
end
assert(c.reference(0,'')=='valid')
assert(c.reference(3,'')=='damaged')
assert(c.reference(1,'Unexpected end of archive\n')=='damaged')
assert(c.reference(1,'warning\n')=='tool-error')
assert(c.reference(124,'Unexpected end of archive\n')=='tool-error')
assert(c.reference(13,'ERROR: Bad archive /tmp/case.rar\n')=='damaged')
assert(c.reference(13,'other fatal error\n')=='tool-error')
local diagnostics={
	{text='',truncated=false,bad=false},
	{text='warning\n',truncated=false,bad=false},
	{text='Unexpected end of archive\n',truncated=true,bad=false},
	{text='Unexpected end of archive\r\n',truncated=true,bad=false},
	{text='prefix Unexpected end of archive\n',truncated=false,bad=false},
	{text='ERROR: Bad archive case.rar\n',truncated=false,bad=true},
	{text='prefix ERROR: Bad archive case.rar\n',truncated=false,bad=false},
}
for status=0,255 do for _,d in ipairs(diagnostics) do
	local expected='tool-error'
	if status==0 and not d.truncated then expected='valid' end
	if status==3 or (status==1 and d.truncated) or (status==13 and d.bad) then expected='damaged' end
	assert(c.reference(status,d.text)==expected)
end end
assert(c.pair('damaged','damaged')=='detected')
assert(c.pair('damaged','valid')=='missed')
assert(c.pair('valid','damaged')=='disagreement')
assert(c.pair('valid','valid')=='survived')
assert(c.pair('damaged','unverifiable')=='unverifiable')
local outcomes={valid={valid='survived',damaged='disagreement'},
	damaged={valid='missed',damaged='detected',unverifiable='unverifiable'},['tool-error']={}}
for reference,expected in pairs(outcomes) do
	for _,rarz in ipairs({'valid','damaged','unverifiable','tool-error'}) do
		assert(c.pair(reference,rarz)==(expected[rarz] or 'inconclusive'))
	end
end
print('PASS: coverage statistics and process classification')
