local _M = {}

local os = require 'os'
local kernel32 = require 'win32.kernel32'

do
	local default_path = kernel32.GetModuleFileName():match('^(.*\\)[^\\]*$')..'?'
	local ASSETS_PATH = os.getenv('ASSETS_PATH')
	if ASSETS_PATH then
		_M.path = ASSETS_PATH:gsub(';;', ';'..default_path..';')
	else
		_M.path = default_path
	end
end

if not package.searchpath then
	local slash
	if package.config then
		slash = package.config:match('^([^\n]*)\n')
	else
		slash = os.getenv('OS')=='Windows_NT' and '\\' or '/'
	end
	function package.searchpath(name, path, sep, rep)
		local fragment = name:gsub('%'..(sep or '.'), rep or slash)
		local err = ""
		for pattern in (path..';'):gmatch('([^;]+);') do
			local path = pattern:gsub('%?', fragment)
			local file = io.open(path, 'r')
			if file then
				file:close()
				return path
			else
				err = err.."\n\tno file '"..path.."'"
			end
		end
		return nil,err
	end
end

function _M.find(name)
	local path,err = package.searchpath(name, _M.path, '/')
	if not path then
		error("asset '"..name.."' not found:"..err)
	end
	return path
end

return _M
