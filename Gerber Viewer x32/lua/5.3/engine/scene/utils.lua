local _M = {}

local string = require 'string'
local scenelib = require 'engine.scene'
local scene = scenelib.write

local function bin2str(bin)
	return string.format("%q", bin)--:gsub('\\\n', '\n'):gsub('[\1-\31\127-\255]', function(c) return string.format("\\%03d", c:byte()) end)
end

function _M.buffer_data(buffer, data)
	scene.stream:write([[
		gl.BindBuffer('ARRAY_BUFFER', ]]..tostring(buffer)..[[)
		gl.BufferData('ARRAY_BUFFER', ]]..bin2str(data)..[[, 'STATIC_DRAW')
	]])
end

function _M.buffer_sub_data(buffer, offset, data)
	scene.stream:write([[
		gl.BindBuffer('ARRAY_BUFFER', ]]..tostring(buffer)..[[)
		gl.BufferSubData('ARRAY_BUFFER', ]]..tostring(offset)..[[, ]]..bin2str(data)..[[, 'STATIC_DRAW')
	]])
end

function _M.tex_sub_image_2d(texture, level, x, y, w, h, format, type, data)
	scene.stream:write([[
		gl.BindTexture('TEXTURE_2D', ]]..tostring(texture)..[[)
		gl.TexSubImage2D('TEXTURE_2D', ]]..tostring(level)..[[, ]]..tostring(x)..[[, ]]..tostring(y)..[[, ]]..tostring(w)..[[, ]]..tostring(h)..[[, ']]..format..[[', ']]..type..[[', ]]..bin2str(data)..[[)
	]])
end

function _M.tex_image_2d(texture, target, level, internalformat, w, h, border, format, type, data)
	scene.stream:write([[
		gl.BindTexture(']]..target..[[', ]]..tostring(texture)..[[)
		gl.TexImage2D(']]..target..[[', ]]..tostring(level)..[[, ']]..internalformat..[[', ]]..tostring(w)..[[, ]]..tostring(h)..[[, ]]..tostring(border)..[[, ']]..format..[[', ']]..type..[[', ]]..bin2str(data)..[[)
		gl.BindTexture(']]..target..[[', 0)
	]])
end

function _M.dump(scene, types_file)
	local dump = {}
	local types = {}
	
	local mt = {}
	local env = setmetatable({}, mt)
	function mt:__index(metatype)
		return function(data)
			return setmetatable(data, {__index=function(_, k)
				if k=='dump' then
					return dump[metatype]
				elseif k=='metatype' then
					return metatype
				end
			end})
		end
	end
	function mt:__newindex(k, v)
		types[k] = v
	end
	local chunk
	if _VERSION == 'Lua 5.2' then
		chunk = assert(loadfile(types_file, 't', env))
	elseif _VERSION == 'Lua 5.1' then
		chunk = assert(loadfile(types_file))
		setfenv(chunk, env)
	end
	chunk()
	
	function dump:ref(value)
		return 'ref'
	end
	
	function dump:stream(value)
		return 'stream'
	end
	
	function dump:typedef(value)
		local t = type(value)
		assert(t=='number' or t=='boolean', "typedef value "..tostring(value).." is not a number or a boolean")
		return value
	end
	
	function dump:struct(value)
		local t = {}
		for i,field in ipairs(self.fields) do
			local type = types[field.type]
			local dump = assert(type.dump, type.metatype.." "..field.type.." has no dump method")
			if field.size then
				local a = {}
				for i=1,field.size do
					a[i] = dump(type, value[field.name][i])
				end
				t[field.name] = a
			else
				local fvalue = dump(type, value[field.name])
				if i==1 and field.type=='boolean' and field.name=='used' and not fvalue then
					break
				end
				t[field.name] = fvalue
			end
		end
		if next(t)==nil then
			return nil
		end
		return t
	end
	
	function dump:union(value)
		local selector = value[self.selector]
		local subtype
		for _,case in ipairs(self.cases) do
			if case.selector == selector then
				subtype = types[case.type]
				break
			end
		end
		local subvalue
		if subtype then
			subvalue = subtype:dump(value)
		end
		if type(subvalue)=='table' then
			subvalue[self.selector] = selector
		else
			subvalue = {
				[self.selector] = selector,
				subvalue,
			}
		end
		if next(subvalue)==nil then
			return nil
		end
		return subvalue
	end
	
	local root = types.scene
	return root:dump(scene)
end

return _M
