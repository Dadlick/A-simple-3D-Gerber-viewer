local _M = {}

local math = require 'math'
local table = require 'table'
local gl = require 'gl'
require 'gl.CheckError'
require 'gl.extensions'
local pathlib = require 'path'
local matrixh = require 'geometry.matrixh'
local optim = require 'assets.grbv'
local tesselation = require 'tesselation'
local imagelib = require 'image'
local png = require 'png'
local configlib = require 'config'

local boards = require 'boards'
local extents = require 'boards.extents'

pathlib.install()

local unpack = unpack or table.unpack

------------------------------------------------------------------------------

local config = {
	max_texture_size = 4096,
	circle_steps = 64,
	gl = {
		version = nil,
		profile = nil,
	},
	draw_zero_width_lines = true,
}
configlib.load(config.gl, 'gl.conf')
configlib.load(config, 'rasterize.conf')

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

LAYOUT in vec4 gl_FragCoord;

void main()
{
	float factor = texelFetch(Blend, ivec2(gl_FragCoord.xy), 0).r;
	out_Color = DarkColor * factor + ClearColor * (1 - factor);
}
]]

local blend2_shader_source = [[
out vec4 out_Color;

uniform vec4 DarkColor;
uniform vec4 ClearColor;
uniform sampler2D Blend1;
uniform sampler2D Blend2;

LAYOUT in vec4 gl_FragCoord;

void main()
{
	float factor1 = texelFetch(Blend1, ivec2(gl_FragCoord.xy), 0).r;
	float factor2 = texelFetch(Blend2, ivec2(gl_FragCoord.xy), 0).r;
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

LAYOUT in vec4 gl_FragCoord;

void main()
{
	float factor1 = texelFetch(Blend1, ivec2(gl_FragCoord.xy), 0).r;
	float factor2 = texelFetch(Blend2, ivec2(gl_FragCoord.xy), 0).r;
	float factor = factor1 * (1 - factor2);
	out_Color = DarkColor * factor + ClearColor * (1 - factor);
}
]]

local mask_shader_source = [[
out vec4 out_Color;

uniform sampler2D Color;
uniform sampler2D Mask;

LAYOUT in vec4 gl_FragCoord;

void main()
{
	vec4 color = texelFetch(Color, ivec2(gl_FragCoord.xy), 0);
	float mask = texelFetch(Mask, ivec2(gl_FragCoord.xy), 0).r;
	out_Color = vec4(color.rgb, color.a * mask);
}
]]

local function compile_shader(type, name, source)
	local shader = gl.CreateShader(type:upper()..'_SHADER'); gl.CheckError()
	local header = ""
	if gl.glsl_version() >= 1.5 then
		header = "#version 150\n#define LAYOUT layout(pixel_center_integer)\n"
	else
		header = "#version 130\n#define LAYOUT\n"
	end
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
local function tesselate(paths, z, nz, r, g, b)
	local elements = assert(tesselation.triangulate(paths))
	return assert(optim.serialize(elements, z, nz, r, g, b))
end

-- convert a path to a buffer of 3D triangles extruded along Z
local function extrude(paths, z0, z1, R, G, B)
	return assert(optim.extrude(paths, z0, z1, R, G, B))
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
		local flash_data,flash_size = tesselate(paths, 0, 1, 1, 1, 1)
		aperture.flash_size = flash_size
		
		aperture.flash_vao = gl.GenVertexArrays(1)[1]; gl.CheckError()
		gl.BindVertexArray(aperture.flash_vao); gl.CheckError()
		
		aperture.flash_vbo = gl.GenBuffers(1)[1]; gl.CheckError()
		gl.BindBuffer('ARRAY_BUFFER', aperture.flash_vbo); gl.CheckError()
		gl.BufferData('ARRAY_BUFFER', flash_data, 'STATIC_DRAW'); gl.CheckError()
		gl.EnableVertexAttribArray(0); gl.CheckError()
		gl.VertexAttribPointer(0, 2, 'FLOAT', false, 36, 0); gl.CheckError()
		
		-- stroke
		local stroke_data,stroke_size
		if #paths >= 2 or #paths[1] >= 3 then
			stroke_data,stroke_size = extrude(paths, 0, 1, 1, 1, 1)
		else
			assert(extents.compute_aperture_extents(aperture).empty)
			stroke_data,stroke_size = require('serial').serialize({0,0,0,0,0,1,1,1,1, 0,0,1,0,0,1,1,1,1}, 'array', '*', 'float', 'le'),2
		end
		aperture.stroke_size = stroke_size
		
		aperture.stroke_vao = gl.GenVertexArrays(1)[1]; gl.CheckError()
		gl.BindVertexArray(aperture.stroke_vao); gl.CheckError()
		
		aperture.stroke_vbo = gl.GenBuffers(1)[1]; gl.CheckError()
		gl.BindBuffer('ARRAY_BUFFER', aperture.stroke_vbo); gl.CheckError()
		gl.BufferData('ARRAY_BUFFER', stroke_data, 'STATIC_DRAW'); gl.CheckError()
		gl.EnableVertexAttribArray(0); gl.CheckError()
		gl.VertexAttribPointer(0, 3, 'FLOAT', false, 36, 0); gl.CheckError()
	end
	
	-- create vbo for regions
	local region_vao = gl.GenVertexArrays(1)[1]; gl.CheckError()
	gl.BindVertexArray(region_vao); gl.CheckError()
		
	local region_vbo = gl.GenBuffers(1)[1]; gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', region_vbo); gl.CheckError()
	gl.EnableVertexAttribArray(0); gl.CheckError()
	gl.VertexAttribPointer(0, 2, 'FLOAT', false, 36, 0); gl.CheckError()
	
	-- draw each path
	for _,layer in ipairs(image.layers) do
		local polarity = layer.polarity == 'clear' and 0 or 1
		gl.UseProgram(flash.program); gl.CheckError()
		gl.Uniform1f(flash.Polarity, polarity); gl.CheckError()
		gl.UseProgram(stroke.program); gl.CheckError()
		gl.Uniform1f(stroke.Polarity, polarity); gl.CheckError()
		for _,path in ipairs(layer) do
			if not path.outline then
				local aperture = path.aperture
				if aperture then
					if aperture.flash_size >= 1 then
						gl.UseProgram(flash.program); gl.CheckError()
						gl.BindVertexArray(aperture.flash_vao); gl.CheckError()
						
						gl.Uniform2f(flash.Position, path[1].x, path[1].y); gl.CheckError()
						gl.DrawArrays('TRIANGLES', 0, aperture.flash_size); gl.CheckError()
					end
					
					if #path > 1 then
						gl.UseProgram(stroke.program); gl.CheckError()
						gl.BindVertexArray(aperture.stroke_vao); gl.CheckError()
						
						if aperture.stroke_size >= 3 then
							for i=2,#path do
								gl.Uniform2f(stroke.From, path[i-1].x, path[i-1].y); gl.CheckError()
								gl.Uniform2f(stroke.To, path[i].x, path[i].y); gl.CheckError()
								gl.DrawArrays('TRIANGLES', 0, aperture.stroke_size); gl.CheckError()
							end
						elseif config.draw_zero_width_lines then
							for i=2,#path do
								gl.Uniform2f(stroke.From, path[i-1].x, path[i-1].y); gl.CheckError()
								gl.Uniform2f(stroke.To, path[i].x, path[i].y); gl.CheckError()
								gl.DrawArrays('LINES', 0, aperture.stroke_size); gl.CheckError()
							end
						end
					end
				else
					gl.UseProgram(flash.program); gl.CheckError()
					gl.BindVertexArray(region_vao); gl.CheckError()
					
					-- gen data
					local region_data,region_size = tesselate({path}, 0, 1, 1, 1, 1)
					gl.BufferData('ARRAY_BUFFER', region_data, 'STREAM_DRAW'); gl.CheckError()
					
					gl.Uniform2f(flash.Position, 0, 0); gl.CheckError()
					gl.DrawArrays('TRIANGLES', 0, region_size); gl.CheckError()
				end
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

local renderer = {}

function _M.init(tw, th, extents)
	renderer = {}
	
	-- build shaders
	renderer.programs = init_shaders()
	
	-- determine texture size
	renderer.texture_width = tw
	renderer.texture_height = th
	
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
	renderer.ms_fbo = ms_fbo
	
	-- regular FBO for bliting to texture, and for compositing
	local fbo = gl.GenFramebuffers(1)[1]; gl.CheckError()
	gl.BindFramebuffer('DRAW_FRAMEBUFFER', fbo); gl.CheckError()
	renderer.fbo = fbo
	
	-- cache shaders
	local flash = renderer.programs.flash
	local stroke = renderer.programs.stroke
	
	-- projection matrix
	local projection_matrix = matrixh.glortho(extents.left, extents.right, extents.bottom, extents.top, -1, 1).glmatrix
	gl.UseProgram(flash.program); gl.CheckError()
	gl.UniformMatrix4fv(flash.ProjectionMatrix, false, projection_matrix); gl.CheckError()
	gl.UseProgram(stroke.program); gl.CheckError()
	gl.UniformMatrix4fv(stroke.ProjectionMatrix, false, projection_matrix); gl.CheckError()
	
	-- allocate a pixel buffers
	renderer.pixels_r = imagelib.new(th, tw, 1, 8)
	
	return true
end

function _M.generate_image(image, texture_path)
	local tw = renderer.texture_width
	local th = renderer.texture_height
	
	-- cache shaders
	local flash = renderer.programs.flash
	local stroke = renderer.programs.stroke
	
	-- setup drawing
	gl.BindFramebuffer('DRAW_FRAMEBUFFER', renderer.ms_fbo); gl.CheckError()
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
	
	-- attach texture to an fbo
	gl.BindFramebuffer('DRAW_FRAMEBUFFER', renderer.fbo); gl.CheckError()
	gl.FramebufferTexture2D('DRAW_FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', texture, 0); gl.CheckError()
	local status = gl.CheckFramebufferStatus('DRAW_FRAMEBUFFER'); gl.CheckError()
	if status ~= gl.FRAMEBUFFER_COMPLETE then
		error("incomplete framebuffer ("..gl[status]..")")
	end
	
	-- blit pixels from the multisample render buffer to the single-sample texture
	gl.BindFramebuffer('READ_FRAMEBUFFER', renderer.ms_fbo); gl.CheckError()
	gl.BlitFramebuffer(0, 0, tw, th, 0, 0, tw, th, 'COLOR_BUFFER_BIT', 'NEAREST'); gl.CheckError()
	
	-- save picture
	gl.BindFramebuffer('READ_FRAMEBUFFER', renderer.fbo); gl.CheckError()
	gl.ReadPixels(0, 0, tw, th, 'RED', 'UNSIGNED_BYTE', renderer.pixels_r); gl.CheckError()
	renderer.pixels_r:flip()
	print("saving "..texture_path)
	png.write(texture_path, renderer.pixels_r)
	
	-- detach texture
	gl.FramebufferTexture2D('DRAW_FRAMEBUFFER', 'COLOR_ATTACHMENT0', 'TEXTURE_2D', 0, 0); gl.CheckError()
	
	-- unbind FBOs
	gl.BindFramebuffer('DRAW_FRAMEBUFFER', 0); gl.CheckError()
	gl.BindFramebuffer('READ_FRAMEBUFFER', 0); gl.CheckError()
	
	-- delete texture
	gl.DeleteTextures({texture}); gl.CheckError()
end

function _M.cleanup()
	for _,program in pairs(renderer.programs) do
		gl.DeleteProgram(program.program); gl.CheckError()
	end
	renderer.programs = nil
	renderer = nil
	return true
end

------------------------------------------------------------------------------

return _M
