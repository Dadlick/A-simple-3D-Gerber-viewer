local _M = {}

local table = require 'table'
local dump = require 'dump'
local nb = require 'nb'

_M.host = nil
_M.path = nil
_M.agent = 'mechanicus'
_M.user = nil

_M.host_ip = nil

-- :NOTE: please don't abuse this feature
function _M.send(report)
	assert(_M.host or _M.host_ip, "no report host specified")
	assert(_M.path, "no report path specified")
	
	-- resolve report host
	if not _M.host_ip then
		_M.host_ip = nb.resolve(_M.host)
	end
	if not _M.host_ip then
		return nil,"could not resolve report host"
	end
	
	-- send the report through HTTP POST
	-- :TODO: use system HTTP proxy
	local s = nb.tcp()
	local success,msg = s:connect(_M.host_ip, 80)
	if not success then
		return nil,"connection to report host failed"
	end
	local content_type,content
	if type(report)=='string' then
		content_type = 'text/plain'
		content = report
	else
		content_type = 'application/lua'
		content = 'return '..assert(dump.tostring(report))
	end
	s:write('POST '.._M.path..' HTTP/1.1'..'\r\n')
	s:write('Host: '..(_M.host or _M.host_ip)..'\r\n')
	if _M.user then
		s:write('From: '.._M.user..'\r\n')
	end
	s:write('User-agent: '.._M.agent..'\r\n')
	s:write('Content-type: '..content_type..'\r\n')
	s:write('Content-length: '..#content..'\r\n')
	s:write('\r\n')
	s:write(content)
	
	-- get the status line, ignore the rest
	local response = {}
	local c = s:read(1)
	while c and c~='\n' and c~='\r' do
		table.insert(response, c)
		c = s:read(1)
	end
	response = table.concat(response)
	local code,msg = response:match('^HTTP/%S*%s+(%d%d%d)%s+(%S.*)$')
	if not code then
		return nil,"invalid HTTP response '"..tostring(response).."'"
	elseif tonumber(code)~=200 then
		return nil,"unexpected HTTP response '"..tostring(response).."'"
	end
	assert(s:close())
	return true
end

return _M
