local _M = {}

local io = require 'io'
local table = require 'table'
local lfs = require 'lfs'
local pathlib = require 'path'
local gl = require 'gl'
require 'gl.CheckError'

local assets = require 'engine.assets'

local methods = {}
local mt = {__index=methods}

local types = {
	vertex = true,
	geometry = true,
	fragment = true,
}

_M.version = 150
_M.extensions = {}

------------------------------------------------------------------------------

local function report_prefix(program, shader, string, line)
	if string==0 then
		return "GLSL version definition:"
	elseif string==1 then
		return "GLSL extensions definition:"
	elseif string==2 then
		return "define "..program.defines[line][1]..":"
	end
	local filename = shader.filenames[string - 2]
	if not filename then
		error("unexpected string number "..string)
	end
	if #filename > 59 then
		filename = "..."..filename:sub(-56)
	end
	return filename..':'..line..':'
end

local function process_compilation_report(program, shader, rawreport)
	local vendor = gl.GetString('VENDOR'); gl.CheckError()
	local function convert_string_line(string, line)
		return report_prefix(program, shader, tonumber(string), tonumber(line))
	end
	local report
	if vendor == 'NVIDIA Corporation' then
		report = rawreport:gsub('(%d+)%((%d+)%) :', convert_string_line)
	elseif vendor == 'ATI Technologies Inc.' or vendor == 'Intel' then
		report = rawreport:gsub('(%d+):(%d+):', convert_string_line)
	else
		report = "while compiling "..shader.filename..":\n"..rawreport:gsub('^\n*', '')
	end
	return report:gsub('^\n*', ''):gsub('\n*$', '')
end

local function process_link_report(program, rawreport)
	return rawreport:gsub('^\n*', ''):gsub('\n*$', '')
end

------------------------------------------------------------------------------

local function compile(program, shader)
	gl.ShaderSource(shader.shader, shader.text); gl.CheckError()
	gl.CompileShader(shader.shader); gl.CheckError()
	local result = gl.GetShaderiv(shader.shader, 'COMPILE_STATUS'); gl.CheckError()
	if result[1] ~= gl.TRUE then
		local rawreport = gl.GetShaderInfoLog(shader.shader); gl.CheckError()
		local report = process_compilation_report(program, shader, rawreport)
		error("GLSL compilation error:\n\t"..report:gsub('\n', '\n\t'))
	end
end

local function link(program)
	for name,slot in pairs(program.inputs) do
		gl.BindAttribLocation(program.program, slot, name); gl.CheckError()
	end
	for name,slot in pairs(program.outputs) do
		gl.BindFragDataLocation(program.program, slot, name); gl.CheckError()
	end
	gl.LinkProgram(program.program); gl.CheckError()
	local result = gl.GetProgramiv(program.program, 'LINK_STATUS'); gl.CheckError()
	if result[1] ~= gl.TRUE then
		local rawreport = gl.GetProgramInfoLog(program.program); gl.CheckError()
		local report = process_link_report(program, rawreport)
		error("GLSL compilation error:\n\t"..report:gsub('\n', '\n\t'))
	end
	for name,slot in pairs(program.outputs) do
		local loc = gl.GetFragDataLocation(program.program, name); gl.CheckError()
		assert(loc==slot, "invalid location for fragment data '"..name.."' in shader '"..program.filename.."'! ("..slot.." expected, got "..loc..")")
	end
	
	program.uniforms = setmetatable({}, {__index=function() return -1 end})
	do
		local count = gl.GetProgramiv(program.program, 'ACTIVE_UNIFORMS')[1]; gl.CheckError()
		local max_length = gl.GetProgramiv(program.program, 'ACTIVE_UNIFORM_MAX_LENGTH')[1]; gl.CheckError()
		for i=0,count-1 do
			local size,type,name = gl.GetActiveUniform(program.program, i, max_length); gl.CheckError()
			program.uniforms[name] = gl.GetUniformLocation(program.program, name); gl.CheckError()
		end
	end
	
	program.attributes = setmetatable({}, {__index=function() return -1 end})
	do
		local count = gl.GetProgramiv(program.program, 'ACTIVE_ATTRIBUTES')[1]; gl.CheckError()
		local max_length = gl.GetProgramiv(program.program, 'ACTIVE_ATTRIBUTE_MAX_LENGTH')[1]; gl.CheckError()
		for i=0,count-1 do
			local size,type,name = gl.GetActiveAttrib(program.program, i, max_length); gl.CheckError()
			program.attributes[name] = gl.GetAttribLocation(program.program, name); gl.CheckError()
		end
	end
end

function methods:load()
	local dirty = false
	
	local date = assert(lfs.attributes(self.filename, 'modification'))
	if not self.date or self.date < date then
		self.date = date
		local file = io.open(self.filename, "rb")
		local sections = {}
		local iline = 0
		local section = { filenames = { self.filename } }
		sections.common = section
		for line in file:lines() do
			iline = iline + 1
			if line:match('^%s*///') then
				local raw = line:match('^%s*///%s*(.-)%s*$')
				local type = raw:gsub('%s+', '_'):lower()
				assert(types[type], "unexpected section '"..raw.."' in shader '"..self.filename.."'")
				section = { filenames = { self.filename }, '#line '..iline..' 3\n' }
				sections[type] = section
			else
				if section==sections.common then
					assert(line:match('^%s*$'), "non-empty line before first section")
				elseif line:match('^%s*#%s*include%s*%b""') or line:match('^%s*#%s*include%s*%b<>') then
					local path,tail = line:match('^%s*#%s*include%s*(%b"")(.*)$')
					if not path then
						path,tail = line:match('^%s*#%s*include%s*(%b<>)(.*)$')
					end
					path = assert(path):sub(2,-2)
					path = tostring(pathlib.split(self.filename).dir / pathlib.split(path))
					local file = assert(io.open(path, 'rb'))
					local include = assert(file:read('*all'))
					assert(file:close())
					table.insert(section.filenames, path)
					table.insert(section, tail..'\n')
					table.insert(section, '#line 0 '..(#section.filenames + 2)..'\n')
					table.insert(section, include..'\n')
					table.insert(section, '#line '..iline..' 3\n')
				else
					table.insert(section, line..'\n')
				end
			end
		end
		sections.common = nil
		
		assert(sections.vertex, "no vertex shader in "..self.filename)
		assert(sections.fragment, "no fragment shader in "..self.filename)
		
		-- removed shaders
		for type,shader in pairs(self.shaders) do
			if not sections[type] then
				gl.DetachShader(self.program, shader.shader); gl.CheckError()
				gl.DeleteShader(shader.shader); gl.CheckError()
				self.shaders[type] = nil
			end
		end
	
		-- added shaders
		for type,section in pairs(sections) do
			if not self.shaders[type] then
				local shader = {}
				shader.filename = self.filename
				shader.shader = gl.CreateShader(type:upper()..'_SHADER'); gl.CheckError()
				gl.AttachShader(self.program, shader.shader); gl.CheckError()
				self.shaders[type] = shader
			end
		end
		
		-- generate text and compile
		local extensions = {'#line 0 1\n'}
		for _,extension in ipairs(_M.extensions) do
			table.insert(extensions, "#extension "..extension.." : enable\n")
		end
		extensions = table.concat(extensions)
		for type,section in pairs(sections) do
			local shader = self.shaders[type]
			local text = {
				"#version ".._M.version.."\n",
				extensions,
				self.defines.text,
				table.concat(section),
			}
			if not shader.text or table.concat(text)~=table.concat(shader.text) then
				shader.text = text
				shader.filenames = section.filenames
				compile(self, shader)
				dirty = true
			end
		end
	end
	
	-- link if possible and necessary
	if dirty then
		link(self)
	end
end

function _M.new(filename, inputs, outputs, defines)
	local self = {
		filename = filename,
		inputs = inputs,
		outputs = outputs,
		shaders = {},
	}
	
	self.program = gl.CreateProgram(); gl.CheckError()
	
	self.defines = defines or {}
	do
		local text = { '#line 0 2\n' }
		for _,define in ipairs(self.defines) do
			local name = define[1]
			local value = define[2]
			assert(type(name)=='string', "invalid define name (string expected, got "..type(name)..")")
			local tv = type(value)
			if tv=='boolean' then
				value = value and '1' or '0'
			elseif tv=='number' then
				value = tostring(value)
			elseif tv=='string' then
				-- keep as-is
			else
				error("unsupported define value type '"..tv.."' (for define '"..name.."')")
			end
			local line = '#define '..name..' '..value..'\n'
			table.insert(text, line)
		end
		self.defines.text = table.concat(text)
	end
	
	setmetatable(self, mt)
	
	self:load()
	
	return self
end

return _M
