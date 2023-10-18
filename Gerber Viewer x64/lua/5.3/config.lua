local _M = {}

local io = require 'io'
local os = require 'os'
local table = require 'table'
local string = require 'string'
local package = require 'package'

_M.path = nil

local function load_config(config, filename)
	if _M.path and package.searchpath then
		filename = package.searchpath(filename, _M.path, '/', '\\')
	end
	if not filename then return end
	local file = io.open(filename, 'r')
	if not file then return end
	file:close()
	local chunk,msg = loadfile(filename, 't', config)
	if not chunk then
		error("error while loading config file: "..msg)
	end
	chunk()
end

function _M.load(config, filename)
	load_config(config, filename)
	return config
end

local keywords = {
	['and'] = true,
	['break'] = true,
	['do'] = true,
	['else'] = true,
	['elseif'] = true,
	['end'] = true,
	['false'] = true,
	['for'] = true,
	['function'] = true,
	['goto'] = true,
	['if'] = true,
	['in'] = true,
	['local'] = true,
	['nil'] = true,
	['not'] = true,
	['or'] = true,
	['repeat'] = true,
	['return'] = true,
	['then'] = true,
	['true'] = true,
	['until'] = true,
	['while'] = true,
}

function _M.args(config, ...)
	local args = {...}
	local i = 1
	local npos = 0
	while i <= #args do
		local arg = args[i]
		local key,value
		if arg:match('^%-%D') then
			if arg:match('^%-%-no%-') then
				key = arg:sub(6)
				value = 'false'
			elseif arg:match('^%-%-') then
				key = arg:sub(3)
				value = 'true'
			else
				key = arg:sub(2)
				i = i + 1
				value = assert(args[i], "argument '"..arg.."' has no value")
			end
		else
			-- append positional arguments to the array part of config
			npos = npos + 1
			key = npos
			value = arg
		end
		if key == 'config' then
			load_config(config, value)
		else
			local n = tonumber(value)
			if n and (value == tostring(n) or value:lower():match('^0x0*'..string.format("%x", n)..'$')) then
				-- keep as-is
			elseif value=='true' then
				value = true
			elseif value=='false' then
				value = false
			elseif value=='nil' then
				value = nil
			elseif value:match('^[[\'"{]') then
				-- keep as-is
			else
				value = string.format('%q', value)
			end
			if type(key)=='number' then
				key = '_ENV['..key..']'
			else
				key = '.'..key:gsub('%-', '_')
				key = key:gsub('%.([^.]+)', function(word)
					if keywords[word] then
						return string.format("[%q]", word)
					else
						return '.'..word
					end
				end)
				if key:sub(1,1)=='[' then
					key = '_ENV'..key
				else
					assert(key:sub(1,1)=='.')
					key = key:sub(2)
				end
			end
			local script = key.." = "..tostring(value)
			local chunk,err = load(script, "@argument", 't', config)
			if not chunk then
				error("invalid arguments '-"..key.." "..tostring(value).."': "..err:sub(13))
			end
			local success,err = pcall(chunk)
			if not success then
				error("invalid arguments '"..arg.." "..tostring(value).."': "..err:sub(13))
			end
		end
		i = i + 1
	end
	if npos ~= 0 then
		config['#'] = npos
	end
	return config
end

function _M.check(title, tests, usage)
	local msg
	for _,test in ipairs(tests) do
		if not test[1] then
			msg = test[2]
			break
		end
	end
	if msg then
		print(title..": "..msg)
		print(usage)
		os.exit(1)
	end
end

return _M
