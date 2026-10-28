local M = {}
function M.consumer_version(about)
	local major,minor= (about..' '):match('^corruption%-reader (%d+)%.(%d+)%.%d+[%s:]')
	return major~=nil and (tonumber(major)>0 or tonumber(minor)>=7)
end
M.z = {[0.90]=1.6448536269514722,[0.95]=1.959963984540054,[0.99]=2.5758293035489004}
function M.sample_size(confidence, margin)
	assert(M.z[confidence] and margin>0 and margin<0.5, 'invalid confidence or margin')
	return math.ceil(M.z[confidence]^2/(4*margin^2))
end
function M.wilson(k,n,z)
	if n==0 then return nil end
	assert(k>=0 and k<=n)
	local p=k/n
	local center=(p+z*z/(2*n))/(1+z*z/n)
	local half=z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))/(1+z*z/n)
	return k==0 and 0 or math.max(0,center-half),k==n and 1 or math.min(1,center+half)
end
function M.rarz(status,output)
	local verdict,count=nil,0
	for line in (output..'\n'):gmatch('(.-)\n') do
		line=line:gsub('\r$','')
		if line:match('^Validation:') then
			verdict=line:match('^Validation: (.*)$'); count=count+1
		end
	end
	if count~=1 then return 'tool-error' end
	if status==0 and verdict=='VALID' then return 'valid' end
	if status==1 and verdict=='INVALID' then return 'damaged' end
	if status==69 and verdict=='UNVERIFIABLE' then return 'unverifiable' end
	return 'tool-error'
end
function M.reference(status,diagnostic)
	local truncated=('\n'..diagnostic:gsub('\r\n','\n')..'\n'):find('\nUnexpected end of archive\n',1,true)
	if status==0 and not truncated then return 'valid' end
	if status==3 or (status==1 and truncated) then return 'damaged' end
	if status==13 and ('\n'..diagnostic):match('\nERROR: Bad archive [^\n]+') then return 'damaged' end
	return 'tool-error'
end
function M.pair(reference,rarz)
	if reference=='damaged' then
		if rarz=='damaged' then return 'detected' end
		if rarz=='valid' then return 'missed' end
		if rarz=='unverifiable' then return 'unverifiable' end
	elseif reference=='valid' then
		if rarz=='valid' then return 'survived' end
		if rarz=='damaged' then return 'disagreement' end
	end
	return 'inconclusive'
end
return M
