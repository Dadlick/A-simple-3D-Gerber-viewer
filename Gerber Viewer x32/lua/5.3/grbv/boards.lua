local _M = {}

local io = require 'io'
local math = require 'math'
local table = require 'table'
local gl = require 'gl'
require 'gl.CheckError'
require 'gl.extensions'
local glu = require 'glu'
local lfs = require 'lfs'
local pathlib = require 'path'
local gerber = require 'gerber'
local excellon = require 'excellon'
local matrixh = require 'geometry.matrixh'
local optim = require 'assets.grbv'
local gpc = require 'gpc'
local dump = require 'dump'
local crypto = require 'crypto'
local imagelib = require 'image'
local png = require 'png'
local configlib = require 'config'
local tesselation = require 'grbv.tesselation'

local fbo = require 'engine.display.fbo'

local boards = require 'boards'
local boards_path = require 'boards.path'
local extents = require 'boards.extents'
local templates = require 'grbv.templates'
local interpolation = require 'boards.interpolation'

pathlib.install()

local unpack = unpack or table.unpack
local exterior = boards_path.exterior

------------------------------------------------------------------------------

local config = {
	cache_directory = 'cache',
	silkscreen_extends_board = false,
	keep_outlines_in_images = false,
	max_texture_size = 4096,
	mill = true,
	drill = true,
	circle_steps = 64,
	template = nil,
	gl = {
		version = nil,
		profile = nil,
	},
}
configlib.load(config.gl, 'gl.conf')
configlib.load(config, 'boards.conf')

boards.circle_steps = config.circle_steps

------------------------------------------------------------------------------

-- this needs to be called when the main GL context is current
function _M.init_gl()
	if config.gl.version or config.gl.profile then
		gl = require('gl.profiles').load(config.gl.version, config.gl.profile)
	else
		gl = require 'gl'
	end
end

------------------------------------------------------------------------------

local cache = {}

function cache.gen_mesh_path(name)
	if not config.cache_directory then return nil end
	return pathlib.split(config.cache_directory) / (name..'.bin')
end

function cache.load_mesh(mesh_path)
	local file = assert(io.open(mesh_path, 'rb'))
	local data = assert(file:read('*all'))
	assert(file:close())
	return data
end

function cache.save_mesh(data, mesh_path)
	local dir = mesh_path.dir
	if lfs.attributes(dir, 'mode')~='directory' then
		local success,err = lfs.mkdir(dir)
		if not success then
			print("warning: cache directory could not be created: "..err)
			return
		end
	end
	local file = assert(io.open(mesh_path, 'wb'))
	assert(file:write(data))
	assert(file:close())
end

function cache.gen_outline_path(outline_name)
	if not config.cache_directory then return nil end
	return pathlib.split(config.cache_directory) / (outline_name..'.lua')
end

function cache.load_outline(outline_path)
	return assert(dofile(outline_path))
end

function cache.save_outline(outline, outline_path)
	local dir = outline_path.dir
	if lfs.attributes(dir, 'mode')~='directory' then
		local success,err = lfs.mkdir(dir)
		if not success then
			print("warning: cache directory could not be created: "..err)
			return
		end
	end
	assert(dump.tofile(outline, tostring(outline_path)))
end

function cache.gen_texture_path(name)
	if not config.cache_directory then return nil end
	return pathlib.split(config.cache_directory) / (name..'.png')
end

function cache.load_texture(texture_path, height, width, channels, bit_depth)
	if not lfs.attributes(texture_path.dir, 'mode') then
		lfs.mkdir(texture_path.dir)
	end
	local pixels = png.read(tostring(texture_path))
	local size = #pixels
	assert(size.height==height)
	assert(size.width==width)
	assert(size.channels==channels)
	assert(size.bit_depth==bit_depth)
	return pixels
end

function cache.save_texture(pixels, texture_path)
	local dir = texture_path.dir
	if lfs.attributes(dir, 'mode')~='directory' then
		local success,err = lfs.mkdir(dir)
		if not success then
			print("warning: cache directory could not be created: "..err)
			return
		end
	end
	png.write(tostring(texture_path), pixels)
end

------------------------------------------------------------------------------

local face_layers = {
	'substrate',
	'copper',
	'soldermask',
	'finish',
	'silkscreen',
	'paste',
}

local dont_rasterize = {
	outline = true,
	milling = true,
	milling_plated = true,
	milling_non_plated = true,
	drill = true,
	drill_plated = true,
	drill_non_plated = true,
}

local flash_shader_source = [[
in vec2 in_Vertex;

uniform mat4 ProjectionMatrix;
uniform vec2 Position;

void main()
{
	gl_Position = ProjectionMatrix * vec4(in_Vertex + Position, 0, 1);
}
]]

local stroke_shader_source = [[
in vec3 in_Vertex;

uniform mat4 ProjectionMatrix;
uniform vec2 From;
uniform vec2 To;

void main()
{
	vec2 offset = From * (1.0 - in_Vertex.z) + To * in_Vertex.z;
	gl_Position = ProjectionMatrix * vec4(in_Vertex.xy + offset, 0, 1);
}
]]

local color_shader_source = [[
uniform float Polarity;

out float out_Alpha;

void main()
{
	out_Alpha = Polarity;
}
]]

local fullscreen_shader_source = [[
in vec4 in_Position;

void main()
{
	gl_Position = in_Position;
}
]]

local blend_shader_source = [[
out vec4 out_Color;

uniform vec4 DarkColor;
uniform vec4 ClearColor;
uniform sampler2D Blend;

void main()
{
	float factor = texelFetch(Blend, ivec2(floor(gl_FragCoord.xy)), 0).r;
	out_Color = DarkColor * factor + ClearColor * (1 - factor);
}
]]

local blend2_shader_source = [[
out vec4 out_Color;

uniform vec4 DarkColor;
uniform vec4 ClearColor;
uniform sampler2D Blend1;
uniform sampler2D Blend2;

void main()
{
	float factor1 = texelFetch(Blend1, ivec2(floor(gl_FragCoord.xy)), 0).r;
	float factor2 = texelFetch(Blend2, ivec2(floor(gl_FragCoord.xy)), 0).r;
	float factor = factor1 * factor2;
	out_Color = DarkColor * factor + ClearColor * (1 - factor);
}
]]

local blend3_shader_source = [[
out vec4 out_Color;

uniform vec4 DarkColor;
uniform vec4 ClearColor;
uniform sampler2D Blend1;
uniform sampler2D Blend2;

void main()
{
	float factor1 = texelFetch(Blend1, ivec2(floor(gl_FragCoord.xy)), 0).r;
	float factor2 = texelFetch(Blend2, ivec2(floor(gl_FragCoord.xy)), 0).r;
	float factor = factor1 * (1 - factor2);
	out_Color = DarkColor * factor + ClearColor * (1 - factor);
}
]]

local mask_shader_source = [[
out vec4 out_Color;

uniform sampler2D Color;
uniform sampler2D Mask;

void main()
{
	vec4 color = texelFetch(Color, ivec2(floor(gl_FragCoord.xy)), 0);
	float mask = texelFetch(Mask, ivec2(floor(gl_FragCoord.xy)), 0).r;
	out_Color = vec4(color.rgb, color.a * mask);
}
]]

local function compile_shader(type, name, source)
	local shader = gl.CreateShader(type:upper()..'_SHADER'); gl.CheckError()
	local header = "#version 130\n"
	gl.ShaderSource(shader, {header, source}); gl.CheckError()
	gl.CompileShader(shader); gl.CheckError()
	local result = gl.GetShaderiv(shader, 'COMPILE_STATUS'); gl.CheckError()
	if result[1] ~= gl.TRUE then
		local rawreport = gl.GetShaderInfoLog(shader); gl.CheckError()
		local report = rawreport:gsub('(%d+)%((%d+)%) :', function(string, line)
			string = tonumber(string)
			line = tonumber(line) - 2
			return name..':'..line..':'
		end):gsub('\n$', '')
		error("GLSL compilation error:\n\t"..report:gsub('\n', '\n\t'))
	end
	return shader
end

local function link_shader(vertex, fragment)
	local program = gl.CreateProgram(); gl.CheckError()
	gl.AttachShader(program, vertex); gl.CheckError()
	gl.AttachShader(program, fragment); gl.CheckError()
	gl.BindAttribLocation(program, 0, 'in_Vertex'); gl.CheckError()
	gl.BindFragDataLocation(program, 0, 'out_Alpha'); gl.CheckError()
	gl.LinkProgram(program); gl.CheckError()
	local result = gl.GetProgramiv(program, 'LINK_STATUS'); gl.CheckError()
	if result[1] ~= gl.TRUE then
		local rawreport = gl.GetProgramInfoLog(program); gl.CheckError()
		local report = rawreport:gsub('\n$', '')
		error("GLSL compilation error:\n\t"..report:gsub('\n', '\n\t'))
	end
	return program
end

-- convert a path to a buffer of 2D triangles
local function tesselate(paths, z, nz, dr, dg, db, sr, sg, sb, sa)
	local elements = assert(tesselation.triangulate(paths))
	return assert(optim.serialize(elements, z, nz, dr, dg, db, sr, sg, sb, sa))
end

-- convert a path to a buffer of 3D triangles extruded along Z
local function extrude(paths, z0, z1, dR, dG, dB, sR, sG, sB, sA)
	return assert(optim.extrude(paths, z0, z1, dR, dG, dB, sR, sG, sB, sA))
end

local function render_image(image, flash, stroke)
	local apertures = {}
	for _,layer in ipairs(image.layers) do
		for _,path in ipairs(layer) do
			local aperture = path.aperture
			if aperture and not apertures[aperture] then
				apertures[aperture] = true
			end
		end
	end
	
	-- gen meshes for apertures
	for aperture in pairs(apertures) do
		local paths = aperture.paths
		if not paths then
			paths = { aperture.path }
		end
		
		-- flash
		local flash_data,flash_size = tesselate(paths, 0, 1, 1, 1, 1, 0, 0, 0, 0)
		aperture.flash_size = flash_size
		
		aperture.flash_vao = gl.GenVertexArrays(1)[1]; gl.CheckError()
		gl.BindVertexArray(aperture.flash_vao); gl.CheckError()
		
		aperture.flash_vbo = gl.GenBuffers(1)[1]; gl.CheckError()
		gl.BindBuffer('ARRAY_BUFFER', aperture.flash_vbo); gl.CheckError()
		gl.BufferData('ARRAY_BUFFER', flash_data, 'STATIC_DRAW'); gl.CheckError()
		gl.EnableVertexAttribArray(0); gl.CheckError()
		gl.VertexAttribPointer(0, 2, 'FLOAT', false, 52, 0); gl.CheckError()
		
		-- stroke
		local stroke_data,stroke_size = extrude(paths, 0, 1, 1, 1, 1, 0, 0, 0, 0)
		aperture.stroke_size = stroke_size
		
		aperture.stroke_vao = gl.GenVertexArrays(1)[1]; gl.CheckError()
		gl.BindVertexArray(aperture.stroke_vao); gl.CheckError()
		
		aperture.stroke_vbo = gl.GenBuffers(1)[1]; gl.CheckError()
		gl.BindBuffer('ARRAY_BUFFER', aperture.stroke_vbo); gl.CheckError()
		gl.BufferData('ARRAY_BUFFER', stroke_data, 'STATIC_DRAW'); gl.CheckError()
		gl.EnableVertexAttribArray(0); gl.CheckError()
		gl.VertexAttribPointer(0, 3, 'FLOAT', false, 52, 0); gl.CheckError()
	end
	
	-- create vbo for regions
	local region_vao = gl.GenVertexArrays(1)[1]; gl.CheckError()
	gl.BindVertexArray(region_vao); gl.CheckError()
		
	local region_vbo = gl.GenBuffers(1)[1]; gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', region_vbo); gl.CheckError()
	gl.EnableVertexAttribArray(0); gl.CheckError()
	gl.VertexAttribPointer(0, 2, 'FLOAT', false, 52, 0); gl.CheckError()
	
	-- draw each path
	for _,layer in ipairs(image.layers) do
		local polarity = layer.polarity == 'clear' and 0 or 1
		gl.UseProgram(flash.program); gl.CheckError()
		gl.Uniform1f(flash.Polarity, polarity); gl.CheckError()
		gl.UseProgram(stroke.program); gl.CheckError()
		gl.Uniform1f(stroke.Polarity, polarity); gl.CheckError()
		for _,path in ipairs(layer) do
			assert(not path.outline) -- this replaces an if that never triggered, feel free to remove once you forget about the reasons
			local aperture = path.aperture
			if aperture then
				gl.UseProgram(flash.program); gl.CheckError()
				gl.BindVertexArray(aperture.flash_vao); gl.CheckError()
				
				gl.Uniform2f(flash.Position, path[1].x, path[1].y); gl.CheckError()
				gl.DrawArrays('TRIANGLES', 0, aperture.flash_size); gl.CheckError()
				
				if #path > 1 then
					gl.UseProgram(stroke.program); gl.CheckError()
					gl.BindVertexArray(aperture.stroke_vao); gl.CheckError()
					
					for i=2,#path do
						gl.Uniform2f(stroke.From, path[i-1].x, path[i-1].y); gl.CheckError()
						gl.Uniform2f(stroke.To, path[i].x, path[i].y); gl.CheckError()
						gl.DrawArrays('TRIANGLES', 0, aperture.stroke_size); gl.CheckError()
					end
				end
			else
				gl.UseProgram(flash.program); gl.CheckError()
				gl.BindVertexArray(region_vao); gl.CheckError()
				
				-- gen data
				local region_data,region_size = tesselate({path}, 0, 1, 1, 1, 1, 0, 0, 0, 0)
				gl.BufferData('ARRAY_BUFFER', region_data, 'STREAM_DRAW'); gl.CheckError()
				
				gl.Uniform2f(flash.Position, 0, 0); gl.CheckError()
				gl.DrawArrays('TRIANGLES', 0, region_size); gl.CheckError()
			end
		end
	end
	gl.UseProgram(0); gl.CheckError()
	gl.BindVertexArray(0); gl.CheckError()
	
	-- delete region mesh
	gl.DeleteVertexArrays({region_vao}); gl.CheckError()
	gl.DeleteBuffers({region_vbo}); gl.CheckError()
	
	-- delete aperture meshes
	for aperture in pairs(apertures) do
		gl.DeleteVertexArrays({aperture.flash_vao, aperture.stroke_vao}); gl.CheckError()
		gl.DeleteBuffers({aperture.flash_vbo, aperture.stroke_vbo}); gl.CheckError()
		aperture.flash_vao, aperture.stroke_vao, aperture.flash_vbo, aperture.stroke_vbo, aperture.flash_size, aperture.stroke_size = nil
	end
end

local function init_shaders()
	local programs = {}
	
	local flash_shader = compile_shader('vertex', 'flash', flash_shader_source)
	local stroke_shader = compile_shader('vertex', 'stroke', stroke_shader_source)
	local color_shader = compile_shader('fragment', 'color', color_shader_source)
	local fullscreen_shader = compile_shader('vertex', 'fullscreen', fullscreen_shader_source)
	local blend_shader = compile_shader('fragment', 'blend', blend_shader_source)
	local blend2_shader = compile_shader('fragment', 'blend2', blend2_shader_source)
	local blend3_shader = compile_shader('fragment', 'blend3', blend3_shader_source)
	local mask_shader = compile_shader('fragment', 'mask', mask_shader_source)
	
	local flash = {}
	flash.program = link_shader(flash_shader, color_shader)
	flash.ProjectionMatrix = gl.GetUniformLocation(flash.program, 'ProjectionMatrix'); gl.CheckError()
	flash.Position = gl.GetUniformLocation(flash.program, 'Position'); gl.CheckError()
	flash.Polarity = gl.GetUniformLocation(flash.program, 'Polarity'); gl.CheckError()
	programs.flash = flash
	
	local stroke = {}
	stroke.program = link_shader(stroke_shader, color_shader)
	stroke.ProjectionMatrix = gl.GetUniformLocation(stroke.program, 'ProjectionMatrix'); gl.CheckError()
	stroke.From = gl.GetUniformLocation(stroke.program, 'From'); gl.CheckError()
	stroke.To = gl.GetUniformLocation(stroke.program, 'To'); gl.CheckError()
	stroke.Polarity = gl.GetUniformLocation(stroke.program, 'Polarity'); gl.CheckError()
	programs.stroke = stroke
	
	local blend = {}
	blend.program = link_shader(fullscreen_shader, blend_shader)
	blend.DarkColor = gl.GetUniformLocation(blend.program, 'DarkColor'); gl.CheckError()
	blend.ClearColor = gl.GetUniformLocation(blend.program, 'ClearColor'); gl.CheckError()
	blend.Blend = gl.GetUniformLocation(blend.program, 'Blend'); gl.CheckError()
	gl.UseProgram(blend.program); gl.CheckError()
	gl.Uniform1i(blend.Blend, 0); gl.CheckError()
	programs.blend = blend
	
	local blend2 = {}
	blend2.program = link_shader(fullscreen_shader, blend2_shader)
	blend2.DarkColor = gl.GetUniformLocation(blend2.program, 'DarkColor'); gl.CheckError()
	blend2.ClearColor = gl.GetUniformLocation(blend2.program, 'ClearColor'); gl.CheckError()
	blend2.Blend1 = gl.GetUniformLocation(blend2.program, 'Blend1'); gl.CheckError()
	blend2.Blend2 = gl.GetUniformLocation(blend2.program, 'Blend2'); gl.CheckError()
	gl.UseProgram(blend2.program); gl.CheckError()
	gl.Uniform1i(blend2.Blend1, 0); gl.CheckError()
	gl.Uniform1i(blend2.Blend2, 1); gl.CheckError()
	programs.blend2 = blend2
	
	local blend3 = {}
	blend3.program = link_shader(fullscreen_shader, blend3_shader)
	blend3.DarkColor = gl.GetUniformLocation(blend3.program, 'DarkColor'); gl.CheckError()
	blend3.ClearColor = gl.GetUniformLocation(blend3.program, 'ClearColor'); gl.CheckError()
	blend3.Blend1 = gl.GetUniformLocation(blend3.program, 'Blend1'); gl.CheckError()
	blend3.Blend2 = gl.GetUniformLocation(blend3.program, 'Blend2'); gl.CheckError()
	gl.UseProgram(blend3.program); gl.CheckError()
	gl.Uniform1i(blend3.Blend1, 0); gl.CheckError()
	gl.Uniform1i(blend3.Blend2, 1); gl.CheckError()
	programs.blend3 = blend3
	
	local mask = {}
	mask.program = link_shader(fullscreen_shader, mask_shader)
	mask.Color = gl.GetUniformLocation(mask.program, 'Color'); gl.CheckError()
	mask.Mask = gl.GetUniformLocation(mask.program, 'Mask'); gl.CheckError()
	gl.UseProgram(mask.program); gl.CheckError()
	gl.Uniform1i(mask.Color, 0); gl.CheckError()
	gl.Uniform1i(mask.Mask, 1); gl.CheckError()
	programs.mask = mask
	
	gl.UseProgram(0); gl.CheckError()
	
	-- mark the shaders for deletion
	gl.DeleteShader(flash_shader); gl.CheckError()
	gl.DeleteShader(stroke_shader); gl.CheckError()
	gl.DeleteShader(color_shader); gl.CheckError()
	gl.DeleteShader(fullscreen_shader); gl.CheckError()
	gl.DeleteShader(blend_shader); gl.CheckError()
	gl.DeleteShader(blend2_shader); gl.CheckError()
	gl.DeleteShader(blend3_shader); gl.CheckError()
	gl.DeleteShader(mask_shader); gl.CheckError()
	
	return programs
end

function _M.load(path, style_name)
	-- load style
	assert(style_name, "no style name provided")
	local style,msg = templates.load(style_name)
	if not style then return nil,"error while loading style: "..msg end
	
	local board,msg
	if type(path)=='string' and path:match('%.lua$') and lfs.attributes(mesh_path.dir, 'mode')=='file' then
		-- load script (that's supposed to return a board)
		board,msg = dofile(path)
	else
		-- load Gerber/Excellon data
		board,msg = boards.load(path, {
			silkscreen_extends_board = config.silkscreen_extends_board,
			keep_outlines_in_images = config.keep_outlines_in_images,
			unit = 'mm',
			template = config.template,
		})
	end
	if not board then return nil,msg end
	
	board.extents = extents.compute_board_extents(board)
	if board.extents.empty then
		return nil,"board is empty"
	end
	if board.template.margin then
		board.extents = board.extents * region{
			left = -board.template.margin,
			right = board.template.margin,
			bottom = -board.template.margin,
			top = board.template.margin,
		}
	end
	
	-- we need only linear segments
	interpolation.interpolate_board_paths(board, 0.001)
	
	-- we need aperture paths
	boards.generate_aperture_paths(board)
	
	-- determine file hashes
	local hashes = {}
	for type,image in pairs(board.images) do
		if image.file_path then
			local file = assert(io.open(image.file_path, "rb"))
			local content = assert(file:read('*all'))
			assert(file:close())
			local hash = crypto.digest('md5', content):lower()
			hashes[type] = hash
		end
	end
	board.hashes = hashes
	
	-- compute special outline hash
	local outline_name = {}
	for type,image in pairs(board.images) do
		if not boards.ignore_outline[type] then
			table.insert(outline_name, board.hashes[type])
		end
	end
	table.sort(outline_name)
	outline_name = table.concat(outline_name, ":")
	if outline_name == "" then
		local l = board.extents.left
		local r = board.extents.right
		local t = board.extents.top
		local b = board.extents.bottom
		outline_name = "l="..l..":r="..r..":t="..t..":b="..b
	end
	if board.hashes.milling then
		outline_name = outline_name..":m="..board.hashes.milling
	end
	if board.hashes.milling_plated then
		outline_name = outline_name..":mp="..board.hashes.milling_plated
	end
	if board.hashes.milling_non_plated then
		outline_name = outline_name..":mnp="..board.hashes.milling_non_plated
	end
	if board.hashes.drill then
		outline_name = outline_name..":d="..board.hashes.drill
	end
	if board.hashes.drill_plated then
		outline_name = outline_name..":dp="..board.hashes.drill_plated
	end
	if board.hashes.drill_non_plated then
		outline_name = outline_name..":dnp="..board.hashes.drill_non_plated
	end
	local outline_hash = crypto.digest('md5', outline_name):lower()
	board.outline_hash = outline_hash
	
	-- build shaders
	board.programs = init_shaders()
	
	-- determine texture size
	local w = board.extents.right - board.extents.left
	local h = board.extents.top - board.extents.bottom
	local tw = w / 0.1 * 4 -- 4 pixels per 0.1 mm
	local th = h / 0.1 * 4 -- 4 pixels per 0.1 mm
	tw = math.min(2 ^ math.ceil(math.log(tw) / math.log(2)), config.max_texture_size)
	th = math.min(2 ^ math.ceil(math.log(th) / math.log(2)), config.max_texture_size)
	board.texture_width = tw
	board.texture_height = th
	
	-- multisample FBO for anti-aliased rendering
	local samples = math.min(16, gl.GetIntegerv('MAX_SAMPLES')[1]); gl.GetError() -- :NOTE: blindly clear the error, since some 3.x implementations incorrectly generate INVALID_ENUM
	local ms_rbo = gl.GenRenderbuffers(1)[1]; gl.CheckError()
	gl.BindRenderbuffer('RENDERBUFFER', ms_rbo); gl.CheckError()
	if samples > 1 then
		gl.RenderbufferStorageMultisample('RENDERBUFFER', samples, 'R8', tw, th); gl.CheckError()
	else
		-- we might as well directly render on fbo, but that would change code too much
		gl.RenderbufferStorage('RENDERBUFFER', 'R8', tw, th); gl.CheckError()
	end
	gl.BindRenderbuffer('RENDERBUFFER', 0); gl.CheckError()
	local ms_fbo = gl.GenFramebuffers(1)[1]; gl.CheckError()
	gl.BindFramebuffer('DRAW_FRAMEBUFFER', ms_fbo); gl.CheckError()
	gl.FramebufferRenderbuffer('DRAW_FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'RENDERBUFFER', ms_rbo); gl.CheckError()
	local status = gl.CheckFramebufferStatus('DRAW_FRAMEBUFFER'); gl.CheckError()
	if status ~= gl.FRAMEBUFFER_COMPLETE then
		error("incomplete framebuffer ("..gl[status]..")")
	end
	gl.Viewport(0, 0, tw, th); gl.CheckError()
	board.ms_fbo = ms_fbo
	
	-- regular FBO for bliting to texture, and for compositing
	local fbo = gl.GenFramebuffers(1)[1]; gl.CheckError()
	gl.BindFramebuffer('DRAW_FRAMEBUFFER', fbo); gl.CheckError()
	board.fbo = fbo
	
	-- cache shaders
	local flash = board.programs.flash
	local stroke = board.programs.stroke
	
	-- projection matrix
	local projection_matrix = matrixh.glortho(board.extents.left, board.extents.right, board.extents.bottom, board.extents.top, -1, 1).glmatrix
	gl.UseProgram(flash.program); gl.CheckError()
	gl.UniformMatrix4fv(flash.ProjectionMatrix, false, projection_matrix); gl.CheckError()
	gl.UseProgram(stroke.program); gl.CheckError()
	gl.UniformMatrix4fv(stroke.ProjectionMatrix, false, projection_matrix); gl.CheckError()
	
	-- allocate a pixel buffers
	board.pixels_r = imagelib.new(th, tw, 1, 8)
	board.pixels_rgba = imagelib.new(th, tw, 4, 8)
	
	-- save style
	board.style = style
	
	return board
end

local function generate_outline(board)
	local outline_path = cache.gen_outline_path(board.outline_hash)
	
	if outline_path and lfs.attributes(outline_path, 'mode') then
		print("loading outline from cache")
		board.outline_mesh = cache.load_outline(outline_path)
	else
		print("generating outline")
		
		-- generate outline paths
		local surface = tesselation.surface()
		if board.outline then
			print("using extracted outline")
			surface:extend(board.outline.path)
		else
			print("using board extents")
			local l = board.extents.left
			local r = board.extents.right
			local t = board.extents.top
			local b = board.extents.bottom
			surface:extend({
				{x=l,y=b},
				{x=r,y=b},
				{x=r,y=t},
				{x=l,y=t},
				{x=l,y=b},
			})
		end
		local function mill(image)
			for _,layer in ipairs(image.layers) do
				for _,path in ipairs(layer) do
					local aperture = path.aperture
					-- treat zero-width lines and regions as areas to cut out
					if not aperture or extents.compute_aperture_extents(aperture).empty then
						if #path >= 4 and path[1].x==path[#path].x and path[1].y==path[#path].y then
							surface:drill(path, {x=0, y=0})
						end
					elseif aperture.paths and #aperture.paths > 1 then
						error("cannot drill or mill apertures with complex contours")
					else
						local aperture_path = aperture.paths[1]
						surface:drill(aperture_path, path[1])
						if #path > 1 then
							surface:mill(aperture_path, path)
						end
					end
				end
			end
		end
		for _,operation in ipairs{
			{config.mill, 'milling', "milling"},
			{config.mill, 'milling_plated', "milling plated slots"},
			{config.mill, 'milling_non_plated', "milling non-plated slots"},
			{config.drill, 'drill', "drilling"},
			{config.drill, 'drill_plated', "drilling plated holes"},
			{config.drill, 'drill_non_plated', "drilling non-plated holes"},
		} do
			local enabled,type,message = table.unpack(operation)
			local image = board.images[type]
			if enabled and image then
				print(message)
				mill(image)
			end
		end
		board.outline_mesh = surface.contour
		
		if outline_path then
			cache.save_outline(board.outline_mesh, outline_path)
		end
	end
end

local function generate_image(board, type, image)
	local tw = board.texture_width
	local th = board.texture_height
	
	local texture_path
	local hash = board.hashes[type]
	if hash then
		local texture_name = hash..':tw='..tw..':th='..th..':l='..board.extents.left..':r='..board.extents.right..':b='..board.extents.bottom..':t='..board.extents.top
		if not boards.ignore_outline[type] then
			texture_name = texture_name..':o='..board.outline_hash
		end
		local texture_hash = crypto.digest('md5', texture_name):lower()
		texture_path = cache.gen_texture_path(texture_hash) -- :NOTE: we could use texture_name instead
	end
	
	if texture_path and lfs.attributes(texture_path, 'mode') then
		print("loading "..type.." texture from cache")
		
		-- load pixels from file
		local pixels_r = cache.load_texture(texture_path, th, tw, 1, 8)
		
		-- create texture
		local texture = gl.GenTextures(1)[1]; gl.CheckError()
		gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
		gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'NEAREST'); gl.CheckError()
		gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'NEAREST'); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_R', gl.RED); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_G', gl.RED); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_B', gl.RED); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_A', gl.ONE); gl.CheckError()
		gl.TexImage2D('TEXTURE_2D', 0, 'R8', tw, th, 0, 'RED', 'UNSIGNED_BYTE', pixels_r); gl.CheckError()
		gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
		image.texture = texture
	else
		print("rasterizing "..type)
		
		-- cache shaders
		local flash = board.programs.flash
		local stroke = board.programs.stroke
		
		-- setup drawing
		gl.BindFramebuffer('DRAW_FRAMEBUFFER', board.ms_fbo); gl.CheckError()
		gl.ClearBufferfv('COLOR', 0, {0, 0, 0, 0}); gl.CheckError()
		gl.Enable('MULTISAMPLE'); gl.CheckError()
		
		-- :KLUDGE: check ms_fbo status again (just before rendering)
		local status = gl.CheckFramebufferStatus('DRAW_FRAMEBUFFER'); gl.CheckError()
		if status ~= gl.FRAMEBUFFER_COMPLETE then
			error("incomplete framebuffer ("..gl[status]..")")
		end
		
		-- draw layer to fbo
		render_image(image, flash, stroke)
		
		-- teardown drawing
		gl.Disable('MULTISAMPLE'); gl.CheckError()
		
		-- create texture
		local texture = gl.GenTextures(1)[1]; gl.CheckError()
		gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
		gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'NEAREST'); gl.CheckError()
		gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'NEAREST'); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_R', gl.RED); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_G', gl.RED); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_B', gl.RED); gl.CheckError()
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_SWIZZLE_A', gl.ONE); gl.CheckError()
		gl.TexImage2D('TEXTURE_2D', 0, 'R8', tw, th, 0, 'RED', 'UNSIGNED_BYTE', nil); gl.CheckError()
		gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
		image.texture = texture
		
		-- attach texture to an fbo
		gl.BindFramebuffer('DRAW_FRAMEBUFFER', board.fbo); gl.CheckError()
		gl.FramebufferTexture2D('DRAW_FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', texture, 0); gl.CheckError()
		local status = gl.CheckFramebufferStatus('DRAW_FRAMEBUFFER'); gl.CheckError()
		if status ~= gl.FRAMEBUFFER_COMPLETE then
			error("incomplete framebuffer ("..gl[status]..")")
		end
		
		-- blit pixels from the multisample render buffer to the single-sample texture
		gl.BindFramebuffer('READ_FRAMEBUFFER', board.ms_fbo); gl.CheckError()
		gl.BlitFramebuffer(0, 0, tw, th, 0, 0, tw, th, 'COLOR_BUFFER_BIT', 'NEAREST'); gl.CheckError()
		
		-- save picture
		if texture_path then
			gl.BindFramebuffer('READ_FRAMEBUFFER', board.fbo); gl.CheckError()
			gl.ReadPixels(0, 0, tw, th, 'RED', 'UNSIGNED_BYTE', board.pixels_r); gl.CheckError()
			cache.save_texture(board.pixels_r, texture_path)
		end
		
		-- detach texture
		gl.FramebufferTexture2D('DRAW_FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', 0, 0); gl.CheckError()
		
		-- unbind FBOs
		gl.BindFramebuffer('DRAW_FRAMEBUFFER', 0); gl.CheckError()
		gl.BindFramebuffer('READ_FRAMEBUFFER', 0); gl.CheckError()
	end
end

local function generate_images(board)
	-- gen/load image textures
	for type,image in pairs(board.images) do if not dont_rasterize[type] then
		if not image.texture then
			generate_image(board, type, image)
		end
	end end
end

function _M.unload(board)
	for _,program in pairs(board.programs) do
		gl.DeleteProgram(program.program); gl.CheckError()
	end
	board.programs = nil
	
	local textures = {}
	for _,image in pairs(board.images) do
		if image.texture then
			table.insert(textures, image.texture)
			image.texture = nil
		end
	end
	if #textures >= 1 then
		gl.DeleteTextures(textures); gl.CheckError()
	end
end

------------------------------------------------------------------------------

local element_size = optim.element_size

function _M.gen_top_mesh(entity, board)
	local h = board.style.thickness / 2
	local z = h
	local data,size
	
	local mesh_name = board.outline_hash..":face"..":z="..z..":tw="..board.texture_width..":th="..board.texture_height..":es="..element_size
	local mesh_hash = crypto.digest('md5', mesh_name):lower()
	local mesh_path = cache.gen_mesh_path(mesh_hash)
	
	if mesh_path and lfs.attributes(mesh_path, 'mode') then
		print("loading top mesh from cache")
		data = cache.load_mesh(mesh_path)
		size = #data / element_size
	else
		if not board.outline_mesh then
			generate_outline(board)
		end
		
		print("tesselating top")
		
		data,size = tesselate(board.outline_mesh, z, 1, 1, 1, 1, 0, 0, 0, 0)
		data = optim.adjust_albedo_texcoords(data, board.extents)
		assert(size == #data / element_size)
		
		if mesh_path then
			cache.save_mesh(data, mesh_path)
		end
	end
	
	local mesh = entity.mesh
	gl.BindBuffer('ARRAY_BUFFER', mesh.vbo); gl.CheckError()
	gl.BufferData('ARRAY_BUFFER', data, 'STATIC_DRAW'); gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
	mesh.size = size
	
	local arrays = entity.arrays
	arrays.primcount = 1
	arrays.first[1] = 0
	arrays.count[1] = mesh.size
end

function _M.gen_bottom_mesh(entity, board)
	local h = board.style.thickness / 2
	local z = -h
	local data,size
	
	local mesh_name = board.outline_hash..":face"..":z="..z..":tw="..board.texture_width..":th="..board.texture_height..":es="..element_size
	local mesh_hash = crypto.digest('md5', mesh_name):lower()
	local mesh_path = cache.gen_mesh_path(mesh_hash)
	
	if mesh_path and lfs.attributes(mesh_path, 'mode') then
		print("loading bottom mesh from cache")
		data = cache.load_mesh(mesh_path)
		size = #data / element_size
	else
		if not board.outline_mesh then
			generate_outline(board)
		end
		
		print("tesselating bottom")
		
		data,size = tesselate(board.outline_mesh, z, -1, 1, 1, 1, 0, 0, 0, 0)
		data = optim.adjust_albedo_texcoords(data, board.extents)
		assert(size == #data / element_size)
		
		if mesh_path then
			cache.save_mesh(data, mesh_path)
		end
	end
	
	local mesh = entity.mesh
	gl.BindBuffer('ARRAY_BUFFER', mesh.vbo); gl.CheckError()
	gl.BufferData('ARRAY_BUFFER', data, 'STATIC_DRAW'); gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
	mesh.size = size
	
	local arrays = entity.arrays
	arrays.primcount = 1
	arrays.first[1] = 0
	arrays.count[1] = mesh.size
end

function _M.gen_side_mesh(entity, board)
	local h = board.style.thickness / 2
	local data,size
	
	local mesh_name = board.outline_hash..":side"..":h="..h..":tw="..board.texture_width..":th="..board.texture_height..":es="..element_size
	local mesh_hash = crypto.digest('md5', mesh_name):lower()
	local mesh_path = cache.gen_mesh_path(mesh_hash)
	
	if mesh_path and lfs.attributes(mesh_path, 'mode') then
		print("loading side mesh from cache")
		data = cache.load_mesh(mesh_path)
		size = #data / element_size
	else
		if not board.outline_mesh then
			generate_outline(board)
		end
		
		print("extruding side")
		
		data,size = extrude(board.outline_mesh, -h, h, 1, 1, 1, 0, 0, 0, 0)
		data = optim.adjust_albedo_texcoords(data, board.extents)
		assert(size == #data / element_size)
		
		if mesh_path then
			cache.save_mesh(data, mesh_path)
		end
	end
	
	local mesh = entity.mesh
	gl.BindBuffer('ARRAY_BUFFER', mesh.vbo); gl.CheckError()
	gl.BufferData('ARRAY_BUFFER', data, 'STATIC_DRAW'); gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
	mesh.size = size
	
	local arrays = entity.arrays
	arrays.primcount = 1
	arrays.first[1] = 0
	arrays.count[1] = mesh.size
end

local function fullscreen()
	gl.Begin('TRIANGLES')
		gl.Vertex4f(-1, -1, 0, 1)
		gl.Vertex4f( 1, -1, 0, 1)
		gl.Vertex4f( 1,  1, 0, 1)
		gl.Vertex4f( 1,  1, 0, 1)
		gl.Vertex4f(-1,  1, 0, 1)
		gl.Vertex4f(-1, -1, 0, 1)
	gl.End(); gl.CheckError()
end

local function gen_texture(texture, board, hidden, side)
	local tw = board.texture_width
	local th = board.texture_height
	
	-- prepare destination texture
	gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'GENERATE_MIPMAP', 'TRUE'); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'LINEAR'); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'LINEAR_MIPMAP_LINEAR'); gl.CheckError()
--	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'NEAREST'); gl.CheckError()
--	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'NEAREST'); gl.CheckError()
	gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_S', gl.CLAMP_TO_EDGE); gl.CheckError()
	gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_T', gl.CLAMP_TO_EDGE); gl.CheckError()
	if gl.extensions.GL_EXT_texture_filter_anisotropic then
		local anisotropy = gl.GetFloatv('MAX_TEXTURE_MAX_ANISOTROPY_EXT')[1]
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_MAX_ANISOTROPY_EXT', anisotropy); gl.CheckError()
	end
	gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', tw, th, 0, 'RGBA', 'UNSIGNED_BYTE', nil); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	
	local texture_name = side.."tmpl:"..board.style.hash..":tw="..tw..":th="..th..':l='..board.extents.left..':r='..board.extents.right..':b='..board.extents.bottom..':t='..board.extents.top
	for _,layer_name in ipairs(face_layers) do
		local material = board.style.materials[layer_name]
		local type = side..'_'..layer_name
		local image = board.images[type]
		if material and (image or layer_name=='finish') and not hidden[layer_name] then
			texture_name = texture_name..':'..layer_name..'='..(board.hashes[type] or '')
		end
	end
	local texture_hash = crypto.digest('md5', texture_name):lower()
	local texture_path = cache.gen_texture_path(texture_hash)
	
	if texture_path and lfs.attributes(texture_path, 'mode') then
		print("loading "..side.." texture from cache")
		
		-- load pixels from file
		local pixels_rgba = cache.load_texture(texture_path, th, tw, 4, 8)
		
		-- create texture
		gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
		gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', tw, th, 0, 'RGBA', 'UNSIGNED_BYTE', pixels_rgba); gl.CheckError()
		gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	else
		generate_images(board)
		
		print("compositing "..side)
		
		-- cache shaders
		local blend = board.programs.blend
		local blend2 = board.programs.blend2
		local blend3 = board.programs.blend3
		
		-- bind it to a fbo, prepare drawing
		gl.BindFramebuffer('FRAMEBUFFER', board.fbo); gl.CheckError()
		gl.FramebufferTexture2D('FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', texture, 0); gl.CheckError()
		gl.Enable('BLEND'); gl.CheckError()
		gl.UseProgram(blend.program); gl.CheckError()
		gl.ActiveTexture('TEXTURE0'); gl.CheckError()
		
		-- fill it with background
		local color = board.style.materials.substrate.color
		gl.ClearBufferfv('COLOR', 0, {color.r, color.g, color.b, 1}); gl.CheckError()
		
		-- draw color layers
		gl.BlendFuncSeparate('SRC_ALPHA', 'ONE_MINUS_SRC_ALPHA', 'ONE', 'ONE_MINUS_SRC_ALPHA'); gl.CheckError()
		for _,layer_name in ipairs(face_layers) do
			local material = board.style.materials[layer_name]
			local type = side..'_'..layer_name
			local image = board.images[type]
			if material and (image or layer_name=='finish') and not hidden[layer_name] then
				print("", layer_name)
				local R,G,B = material.color.r,material.color.g,material.color.b
				local D,C = material.opacity or 1, 0
				if layer_name=='soldermask' then
					C,D = D,C
					gl.Uniform4f(blend.DarkColor, R, G, B, D); gl.CheckError()
					gl.Uniform4f(blend.ClearColor, R, G, B, C); gl.CheckError()
					gl.BindTexture('TEXTURE_2D', image.texture); gl.CheckError()
				elseif layer_name=='finish' then
					local copper = board.images[side..'_copper']
					if copper then -- finish only adheres to (exposed) copper
						local soldermask = board.images[side..'_soldermask']
						if soldermask then
							gl.UseProgram(blend2.program); gl.CheckError()
							gl.Uniform4f(blend2.DarkColor, R, G, B, D); gl.CheckError()
							gl.Uniform4f(blend2.ClearColor, R, G, B, C); gl.CheckError()
							gl.ActiveTexture('TEXTURE1'); gl.CheckError()
							gl.BindTexture('TEXTURE_2D', soldermask.texture); gl.CheckError()
							gl.ActiveTexture('TEXTURE0'); gl.CheckError()
							gl.BindTexture('TEXTURE_2D', copper.texture); gl.CheckError()
						else
							gl.Uniform4f(blend.DarkColor, R, G, B, D); gl.CheckError()
							gl.Uniform4f(blend.ClearColor, R, G, B, C); gl.CheckError()
							gl.BindTexture('TEXTURE_2D', copper.texture); gl.CheckError()
						end
					end
				elseif layer_name=='silkscreen' and board.style.mask_silkscreen then
					local soldermask = board.images[side..'_soldermask']
					if soldermask then
						gl.UseProgram(blend3.program); gl.CheckError()
						gl.Uniform4f(blend3.DarkColor, R, G, B, D); gl.CheckError()
						gl.Uniform4f(blend3.ClearColor, R, G, B, C); gl.CheckError()
						gl.ActiveTexture('TEXTURE1'); gl.CheckError()
						gl.BindTexture('TEXTURE_2D', soldermask.texture); gl.CheckError()
						gl.ActiveTexture('TEXTURE0'); gl.CheckError()
						gl.BindTexture('TEXTURE_2D', image.texture); gl.CheckError()
					else
						gl.Uniform4f(blend.DarkColor, R, G, B, D); gl.CheckError()
						gl.Uniform4f(blend.ClearColor, R, G, B, C); gl.CheckError()
						gl.BindTexture('TEXTURE_2D', image.texture); gl.CheckError()
					end
				else
					gl.Uniform4f(blend.DarkColor, R, G, B, D); gl.CheckError()
					gl.Uniform4f(blend.ClearColor, R, G, B, C); gl.CheckError()
					gl.BindTexture('TEXTURE_2D', image.texture); gl.CheckError()
				end
				
				fullscreen()
				
				if layer_name=='finish' and board.images[side..'_copper'] then
					gl.UseProgram(blend.program); gl.CheckError()
				end
			end
		end
		
		gl.Finish(); gl.CheckError()
		
		if texture_path then
			gl.ReadPixels(0, 0, tw, th, 'RGBA', 'UNSIGNED_BYTE', board.pixels_rgba); gl.CheckError()
			cache.save_texture(board.pixels_rgba, texture_path)
		end
		
		gl.BlendFuncSeparate('ONE', 'ZERO', 'ONE', 'ZERO'); gl.CheckError()
		gl.UseProgram(0); gl.CheckError()
		gl.FramebufferTexture2D('FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', 0, 0); gl.CheckError()
		gl.BindFramebuffer('FRAMEBUFFER', 0); gl.CheckError()
	end
	
	gl.ActiveTexture('TEXTURE1'); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	gl.ActiveTexture('TEXTURE0'); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
	gl.GenerateMipmap('TEXTURE_2D'); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
end

function _M.gen_top_texture(texture, board, hidden)
	gen_texture(texture, board, hidden, 'top')
end

function _M.gen_bottom_texture(texture, board, hidden)
	gen_texture(texture, board, hidden, 'bottom')
end

function _M.gen_side_texture(texture, board, hidden, top_texture)
	--[[
	
	Side color depends on face color (assumed identical top/bottom):
	- if copper, use face color (copper, soldermask?, silkscreen?), the drilling/milling/routing occured before plating, masking and silking
	- otherwise, use substrate color, the drilling/milling/routing occured after plating, masking and silking
	
	--]]
	
	local tw = board.texture_width
	local th = board.texture_height
	
	-- prepare destination texture
	gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'GENERATE_MIPMAP', 'TRUE'); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'LINEAR'); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'LINEAR_MIPMAP_LINEAR'); gl.CheckError()
--	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'NEAREST'); gl.CheckError()
--	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'NEAREST'); gl.CheckError()
	gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_S', gl.CLAMP_TO_EDGE); gl.CheckError()
	gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_T', gl.CLAMP_TO_EDGE); gl.CheckError()
	if gl.extensions.GL_EXT_texture_filter_anisotropic then
		local anisotropy = gl.GetFloatv('MAX_TEXTURE_MAX_ANISOTROPY_EXT')[1]
		gl.TexParameterf('TEXTURE_2D', 'TEXTURE_MAX_ANISOTROPY_EXT', anisotropy); gl.CheckError()
	end
	gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', tw, th, 0, 'RGBA', 'UNSIGNED_BYTE', nil); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	
	local texture_name = "side".."tmpl:"..board.style.hash..":tw="..tw..":th="..th..':l='..board.extents.left..':r='..board.extents.right..':b='..board.extents.bottom..':t='..board.extents.top
	for _,layer_name in ipairs(face_layers) do
		local material = board.style.materials[layer_name]
		local type = 'top_'..layer_name
		local image = board.images[type]
		if material and (image or layer_name=='finish') and not hidden[layer_name] then
			texture_name = texture_name..':'..layer_name..'='..(board.hashes[type] or '')
		end
	end
	local texture_hash = crypto.digest('md5', texture_name):lower()
	local texture_path = cache.gen_texture_path(texture_hash)
	
	if texture_path and lfs.attributes(texture_path, 'mode') then
		print("loading side texture from cache")
		
		-- load pixels from file
		local pixels_rgba = cache.load_texture(texture_path, th, tw, 4, 8)
		
		-- create texture
		gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
		gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', tw, th, 0, 'RGBA', 'UNSIGNED_BYTE', pixels_rgba); gl.CheckError()
		gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	else
		generate_images(board)
		
		print("compositing side")
		
		-- bind it to a fbo, prepare drawing
		gl.BindFramebuffer('FRAMEBUFFER', board.fbo); gl.CheckError()
		gl.FramebufferTexture2D('FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', texture, 0); gl.CheckError()
		gl.Enable('BLEND'); gl.CheckError()
		gl.UseProgram(board.programs.mask.program); gl.CheckError()
		gl.ActiveTexture('TEXTURE0'); gl.CheckError()
		
		-- fill it with background
		local color = board.style.materials.substrate.color
		gl.ClearBufferfv('COLOR', 0, {color.r, color.g, color.b, 1}); gl.CheckError()
		
		-- use the stacked top color where there is copper (it was drilled/milled/routed before deposition for plating)
		local copper = board.images['top_copper']
		if copper then
			gl.BlendFuncSeparate('SRC_ALPHA', 'ONE_MINUS_SRC_ALPHA', 'ZERO', 'ONE'); gl.CheckError()
			gl.ActiveTexture('TEXTURE1'); gl.CheckError()
			gl.BindTexture('TEXTURE_2D', copper.texture); gl.CheckError()
			gl.ActiveTexture('TEXTURE0'); gl.CheckError()
			gl.BindTexture('TEXTURE_2D', top_texture); gl.CheckError()
			fullscreen()
		end
		
		gl.Finish(); gl.CheckError()
		
		if texture_path then
			gl.ReadPixels(0, 0, tw, th, 'RGBA', 'UNSIGNED_BYTE', board.pixels_rgba); gl.CheckError()
			cache.save_texture(board.pixels_rgba, texture_path)
		end
		
		gl.BlendFuncSeparate('ONE', 'ZERO', 'ONE', 'ZERO'); gl.CheckError()
		gl.UseProgram(0); gl.CheckError()
		gl.FramebufferTexture2D('FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', 0, 0); gl.CheckError()
		gl.BindFramebuffer('FRAMEBUFFER', 0); gl.CheckError()
	end
	
	gl.ActiveTexture('TEXTURE1'); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	gl.ActiveTexture('TEXTURE0'); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
	gl.GenerateMipmap('TEXTURE_2D'); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
end

------------------------------------------------------------------------------

return _M
