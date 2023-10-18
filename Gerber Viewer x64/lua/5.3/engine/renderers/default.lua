local os = require 'os'
local math = require 'math'
local table = require 'table'
local gl = require 'gl'
require 'gl.CheckError'
require 'gl.version'
require 'gl.extensions'
local lfs = require 'lfs'
local geometry = require 'geometry'
local vector = geometry.vector
local vectorh = geometry.vectorh
local quaternion = geometry.quaternion
local matrixh = geometry.matrixh
local serial = require 'serial'
local png = require 'png'
local imagelib = require 'image'
local configlib = require 'config'

local time = require 'engine.time'
local traj = require 'engine.trajectories'
local assets = require 'engine.assets'
local shader = require 'engine.display.shader'
local fbo = require 'engine.display.fbo'
local camera_utils = require 'engine.scene.camera'

local loadstring = loadstring or load

local config = {
	display_debug_shapes = false,
	display_debug_position = false,
	display_entities = true,
	display_stats = false,
	display_camera_boxes = false,
	display_uiobjects = true,
	display_antialiasing_debug_lines = false,
	geometry_wireframe = false,
	multisample = 4,
	autoreload = false,
	wireframe = false,
	atmosphere = false, -- :TODO: find a way to enable per app
	assets_use_doubles = false,
	stats_width = 400,
	stats_height = 50,
	capture_format = 'png',
	cast_shadows = true,
	draw_sky = true,
	use_distance_buffer = true,
	use_dithering = true,
	gl = {
		version = nil,
		profile = nil,
	},
}
configlib.load(config.gl, 'gl.conf')
configlib.load(config, 'display.conf')

local glsl_version = gl.glsl_version() or 0
if glsl_version < 1.5 then
	config.cast_shadows = false
	config.draw_sky = false
	config.multisample = false
	shader.version = 130
end

-- restrict gl profile if required
if config.gl.version or config.gl.profile then
	gl = require('gl.profiles').load(config.gl.version, config.gl.profile)
end

if gl.PushMatrix then
	for _,k in ipairs{
		'PushMatrix',
		'PopMatrix',
		'MatrixMode',
		'LoadIdentity',
		'LoadMatrixf',
		'MultMatrixf',
		'Translatef',
		'Rotatef',
		'Ortho',
		'Begin',
		'End',
	} do
		gl[k] = nil
	end
end

------------------------------------------------------------------------------
-- data

--............................................................................
-- common structures for serialization

serial.struct.vec2 = {
	{'x',	'float', 'le'},
	{'y',	'float', 'le'},
}

serial.struct.vec3 = {
	{'x',	'float', 'le'},
	{'y',	'float', 'le'},
	{'z',	'float', 'le'},
}

serial.struct.rgb = {
	{'r',	'float', 'le'},
	{'g',	'float', 'le'},
	{'b',	'float', 'le'},
}

serial.struct.rgba = {
	{'r',	'float', 'le'},
	{'g',	'float', 'le'},
	{'b',	'float', 'le'},
	{'a',	'float', 'le'},
}

serial.struct.element_v3c3 = {
	{'vertex', 'vec3'},
	{'color', 'rgb'},
}

serial.struct.element_v3 = {
	{'vertex', 'vec3'},
}

serial.struct.element_v3t2 = {
	{'vertex', 'vec3'},
	{'texcoord', 'vec2'},
}

serial.struct.element_v3n3t2 = {
	{'vertex', 'vec3'},
	{'normal', 'vec3'},
	{'texcoord', 'vec2'},
}

serial.struct.element_v2 = {
	{'vertex', 'vec2'},
}

serial.struct.element_v2c4 = {
	{'vertex', 'vec2'},
	{'color', 'rgba'},
}

local function gen_mesh(mode, format, elements)
	assert(serial.struct['element_'..format], "unsupported format '"..format.."'")
	local data = serial.serialize.array(elements, '*', 'element_'..format)
	local mesh = {}
	
	mesh.mode = mode
	mesh.size = #elements
	
	mesh.vao = gl.GenVertexArrays(1)[1]; gl.CheckError()
	gl.BindVertexArray(mesh.vao); gl.CheckError()
	
	mesh.vbo = gl.GenBuffers(1)[1]; gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', mesh.vbo); gl.CheckError()
	gl.BufferData('ARRAY_BUFFER', data, 'STATIC_DRAW'); gl.CheckError()
	
	local stride = 0
	for size in format:gmatch('%a(%d)') do
		stride = stride + 4 * tonumber(size)
	end
	mesh.stride = stride
	
	local i = 0
	local offset = 0
	for type,size in format:gmatch('(%a)(%d)') do
		size = tonumber(size)
		gl.EnableVertexAttribArray(i); gl.CheckError()
		gl.VertexAttribPointer(i, size, 'FLOAT', false, stride, offset); gl.CheckError()
		i = i + 1
		offset = offset + 4 * size
	end
	
	return mesh
end

--............................................................................
-- dithering texture

local dithering
if config.use_dithering then
	local path = assets.find('textures/dithering.png')
	local image = png.read(path)
	assert((#image).channels==4)
	dithering = gl.GenTextures(1)[1]; gl.CheckError()
	gl.BindTexture('TEXTURE_2D', dithering); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'NEAREST'); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'NEAREST'); gl.CheckError()
	gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', (#image).width, (#image).height, 0, 'RGBA', 'UNSIGNED_SHORT', image); gl.CheckError()
end

--............................................................................
-- sky scattering texture

local scattering
do
	-- x is angle to sun: 0 when facing the sun, pi when sun is behind viewer
	-- y is log(depth)
	local path = assets.find('textures/scattering.png')
	local image = png.read(path)
	assert((#image).channels==4)
	scattering = gl.GenTextures(1)[1]; gl.CheckError()
	gl.BindTexture('TEXTURE_2D', scattering); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'LINEAR'); gl.CheckError()
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'LINEAR'); gl.CheckError()
	gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_S', gl.CLAMP_TO_EDGE); gl.CheckError()
	gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_T', gl.CLAMP_TO_EDGE); gl.CheckError()
	gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', (#image).width, (#image).height, 0, 'RGBA', 'UNSIGNED_BYTE', image); gl.CheckError()
end

--............................................................................
-- shaders

local shaders = {}
local defines = {}
for k,v in pairs(config) do
	local tv = type(v)
	if tv=='boolean' or tv=='number' or tv=='string' then
		table.insert(defines, {k:upper(), v})
	end
end

local world_output = {
	out_Color = 0,
	out_Distance = 1,
}
if not config.use_distance_buffer then
	world_output.out_Distance = nil
end

shaders.entity = shader.new(assets.find('shaders/entity_textured.glsl'), {
	in_Position = 0,
	in_Normal = 1,
	in_Color = 2,
}, world_output, defines)

shaders.flat = shader.new(assets.find('shaders/flat.glsl'), {
	in_Position = 0,
	in_Color = 1,
}, world_output, defines)

if config.geometry_wireframe then
	shaders.wireframe = shader.new(assets.find('shaders/wireframe.glsl'), {
		in_Position = 0,
	}, world_output, defines)
end

shaders.post_process = shader.new(assets.find('shaders/post_process.glsl'), {
	in_Position = 0,
	in_TexCoord = 1,
}, {
	out_Color = 0,
}, defines)

shaders.shadow = shader.new(assets.find('shaders/shadow.glsl'), {
	in_Position = 0,
}, { }, defines)

if config.draw_sky then
	shaders.sky = shader.new(assets.find('shaders/sky.glsl'), {
		in_Position = 0,
	}, world_output, defines)
end

shaders.ui_v2c4 = shader.new(assets.find('shaders/ui_v2c4.glsl'), {
	in_Position = 0,
	in_Color = 1,
}, {
	out_Color = 0,
}, defines)

shaders.ui_v2 = shader.new(assets.find('shaders/ui_v2.glsl'), {
	in_Position = 0,
}, {
	out_Color = 0,
}, defines)

shaders.uiobject = shader.new(assets.find('shaders/uiobject.glsl'), {
	in_Position = 0,
	in_TexCoord = 1,
}, {
	out_Color = 0,
}, defines)

local visual_shaders = {
	entity = shaders.entity,
	flat = shaders.flat,
	wireframe = shaders.wireframe,
	sky = shaders.sky,
}

local shadow_shaders = {
	entity = shaders.shadow,
	flat = shaders.shadow,
	wireframe = shaders.shadow,
	sky = shaders.shadow,
}

--............................................................................
-- main camera framebuffer object

local buffers = {
	color = {type='texture', format='RGBA8', attachment='COLOR_ATTACHMENT0'},
	distance = {type='texture', format='R32F', attachment='COLOR_ATTACHMENT1'},
	depth = {type='renderbuffer', format='DEPTH_COMPONENT32F', attachment='DEPTH_ATTACHMENT'},
}
if not config.use_distance_buffer then
	buffers.distance = nil
end
local scene_fbo = fbo.new(buffers, config.multisample or 1)

--............................................................................
-- post-process framebuffer object

local post_process_fbo = fbo.new({
	color = {type='texture', format='RGBA8', attachment='COLOR_ATTACHMENT0'},
	depth = {type='renderbuffer', format='DEPTH_COMPONENT32F', attachment='DEPTH_ATTACHMENT'},
}, 1)

--............................................................................
-- sun shadow framebuffer object

local shadow = fbo.new({
	depth = {type='texture', format='DEPTH_COMPONENT32F', attachment='DEPTH_ATTACHMENT'},
}, 1, 4096, 4096)

--............................................................................
-- config variables

local atmosphere_altitude = 10*1000

local ground_radius = 50
local ground_max_k = 10
local ground_base = 10

local tscale = 0.2 -- 0.2 textures width per meter

--............................................................................
-- origin axis mesh

local origin
do

local data = {
	{vertex=vector(0,0,0), color={r=1,g=0,b=0}},
	{vertex=vector(1,0,0), color={r=1,g=0,b=0}},
	{vertex=vector(0,0,0), color={r=0,g=1,b=0}},
	{vertex=vector(0,1,0), color={r=0,g=1,b=0}},
	{vertex=vector(0,0,0), color={r=0,g=0,b=1}},
	{vertex=vector(0,0,1), color={r=0,g=0,b=1}},
}

--[[
local gray = {r=0.5,g=0.5,b=0.5}
local gridsize = 10
for i=-gridsize,gridsize do
	table.insert(data, {vertex=vector(-gridsize, 0, i), color=gray})
	table.insert(data, {vertex=vector(gridsize, 0, i), color=gray})
	table.insert(data, {vertex=vector(i, 0, -gridsize), color=gray})
	table.insert(data, {vertex=vector(i, 0, gridsize), color=gray})
end
--]]

origin = gen_mesh('LINES', 'v3c3', data)

end

--............................................................................
-- sun direction mesh

local sun_mesh
do

local data = {
	{vertex=vector(0,0,0)},
	{vertex=vector(0,0,-1)},
}

sun_mesh = gen_mesh('LINES', 'v3', data)

end

--............................................................................
-- antialiasing debug lines

local antialiasing_debug_lines
do

local data = {}

for i=0,90,5 do
	local x = math.cos(math.rad(i))
	local y = math.sin(math.rad(i))
	table.insert(data, {vertex=vector(-1, -1, -4)})
	table.insert(data, {vertex=vector(-1+2*x, -1+2*y, -4)})
end

antialiasing_debug_lines = gen_mesh('LINES', 'v3', data)

end

--............................................................................
-- frustum mesh

local frustum_data
do

local a = vector(-1,-1,-1)
local b = vector( 1,-1,-1)
local c = vector( 1, 1,-1)
local d = vector(-1, 1,-1)
local e = vector(-1,-1, 1)
local f = vector( 1,-1, 1)
local g = vector( 1, 1, 1)
local h = vector(-1, 1, 1)

local x1 = vector(-0.1,0,0)
local x2 = vector( 0.1,0,0)
local y1 = vector(0,-0.1,0)
local y2 = vector(0, 0.1,0)
local z1 = vector(0,0,-0.1)
local z2 = vector(0,0, 0.1)

local data = {
	a, b,
	b, c,
	c, d,
	d, a,
	
	e, f,
	f, g,
	g, h,
	h, e,
	
	a, e,
	b, f,
	c, g,
	d, h,
	
	x1, x2,
	y1, y2,
	z1, z2,
}
local red = {r=1,g=0,b=0}
local green = {r=0,g=1,b=0}
local white = {r=1,g=1,b=1}
for i=1,#data do
	local color
	if i <= 8 then
		color = red
	elseif i <= 16 then
		color = green
	else
		color = white
	end
	data[i] = {vertex=data[i], color=color}
end

frustum_data = gen_mesh('LINES', 'v3c3', data)

frustum_data.frustum = {
	mode = 'LINES',
	first = 0,
	size = 24,
}

frustum_data.origin = {
	mode = 'LINES',
	first = 24,
	size = 6,
}

end

--............................................................................
-- fbo rendering mesh

local fullscreen_mesh
do

local data = {
	{vertex=vector(-1,-1), texcoord=vector(0, 0)},
	{vertex=vector( 1,-1), texcoord=vector(1, 0)},
	{vertex=vector( 1, 1), texcoord=vector(1, 1)},
	{vertex=vector(-1, 1), texcoord=vector(0, 1)},
}

fullscreen_mesh = gen_mesh('QUADS', 'v3t2', data)

end

--............................................................................
-- debug arrow mesh

local arrow_data
do

--[[

X=^ Y=O Z=>

   G
  /|
 / F---E
A      |
 \ C---D
  \|
   B

--]]

local a = vector(0, 0, -1)
local b = vector(-.8, 0, -.2)
local c = vector(-.3, 0, -.2)
local d = vector(-.3, 0, 1)
local e = vector(.3, 0, 1)
local f = vector(.3, 0, -.2)
local g = vector(.8, 0, -.2)

local offu = vector(0, .3, 0)
local offd = vector(0, -.3, 0)
local up = vector(0, 1, 0)
local down = vector(0, -1, 0)
local left = vector(-1, 0, 0)
local right = vector(1, 0, 0)
local back = vector(0, 0, 1)
local sqrt2_2 = math.sqrt(2)/2
local ab = vector(-sqrt2_2, 0, -sqrt2_2)
local ag = vector(sqrt2_2, 0, -sqrt2_2)
local gray = {r=0.25, g=0.25, b=0.25}

local data = {
	-- top polygon
	{vertex=a+offu, normal=up},
	{vertex=b+offu, normal=up},
	{vertex=c+offu, normal=up},
	{vertex=d+offu, normal=up},
	{vertex=e+offu, normal=up},
	{vertex=f+offu, normal=up},
	{vertex=g+offu, normal=up},
	-- bottom polygon
	{vertex=a+offd, normal=down},
	{vertex=g+offd, normal=down},
	{vertex=f+offd, normal=down},
	{vertex=e+offd, normal=down},
	{vertex=d+offd, normal=down},
	{vertex=c+offd, normal=down},
	{vertex=b+offd, normal=down},
	-- side quads
	{vertex=a+offu, normal=ab},
	{vertex=a+offd, normal=ab},
	{vertex=b+offd, normal=ab},
	{vertex=b+offu, normal=ab},
	{vertex=b+offu, normal=back},
	{vertex=b+offd, normal=back},
	{vertex=c+offd, normal=back},
	{vertex=c+offu, normal=back},
	{vertex=c+offu, normal=left},
	{vertex=c+offd, normal=left},
	{vertex=d+offd, normal=left},
	{vertex=d+offu, normal=left},
	{vertex=d+offu, normal=back},
	{vertex=d+offd, normal=back},
	{vertex=e+offd, normal=back},
	{vertex=e+offu, normal=back},
	{vertex=e+offu, normal=right},
	{vertex=e+offd, normal=right},
	{vertex=f+offd, normal=right},
	{vertex=f+offu, normal=right},
	{vertex=f+offu, normal=back},
	{vertex=f+offd, normal=back},
	{vertex=g+offd, normal=back},
	{vertex=g+offu, normal=back},
	{vertex=g+offu, normal=ag},
	{vertex=g+offd, normal=ag},
	{vertex=a+offd, normal=ag},
	{vertex=a+offu, normal=ag},
}
arrow_data = gen_mesh(nil, 'v3', data)

arrow_data.top = {
	mode = 'POLYGON',
	first = 0,
	size = 7,
}

arrow_data.bottom = {
	mode = 'POLYGON',
	first = 7,
	size = 7,
}

arrow_data.side = {
	mode = 'QUADS',
	first = 14,
	size = 28,
}

end

--............................................................................
-- performance graph mesh

local graph
local update_graph
do

local data = {}
for i=1,512 do
	local t = i / 60
--	local v = 1/60 + 0.005*math.sin(t*math.pi*2/0.2)
	local v = 0
	table.insert(data, {vertex=vector(t, v)})
end

graph = gen_mesh(nil, 'v2', data)

graph.last = 0

end

local graphbg
do
	local border = 10
	local xsize = config.stats_width
	local ysize = config.stats_height
	
	local xrange = 512/60
	local yrange = 1/30
	
	local bgcolor = {r=0, g=0, b=0, a=0.5}
	local axiscolor = {r=1, g=1, b=1, a=1}
	
	local data = {}
	
	table.insert(data, {vertex=vector(-border, -border), color=bgcolor})
	table.insert(data, {vertex=vector(xsize+border, -border), color=bgcolor})
	table.insert(data, {vertex=vector(xsize+border, ysize+border), color=bgcolor})
	table.insert(data, {vertex=vector(-border, ysize+border), color=bgcolor})
	
	table.insert(data, {vertex=vector(0, 0), color=axiscolor})
	table.insert(data, {vertex=vector(xsize, 0), color=axiscolor})
	table.insert(data, {vertex=vector(0, 0), color=axiscolor})
	table.insert(data, {vertex=vector(0, ysize), color=axiscolor})
	local kx = xsize / xrange
	local ky = ysize / yrange
	for x=0,xrange,0.1 do
		table.insert(data, {vertex=vector(x*kx, 0), color=axiscolor})
		table.insert(data, {vertex=vector(x*kx, -border/2), color=axiscolor})
	end
	for y=0,yrange,0.01 do
		table.insert(data, {vertex=vector(0, y*ky), color=axiscolor})
		table.insert(data, {vertex=vector(-border/2, y*ky), color=axiscolor})
	end
	
	graphbg = gen_mesh(nil, 'v2c4', data)
	
	graphbg.bg = {
		mode = 'QUADS',
		first = 0,
		size = 4,
	}
	
	graphbg.axis = {
		mode = 'LINES',
		first = 4,
		size = #data-4,
	}
end

------------------------------------------------------------------------------

local glActiveTexture = gl.ActiveTexture
local glBindBuffer = gl.BindBuffer
local glBindFramebuffer = gl.BindFramebuffer
local glBindTexture = gl.BindTexture
local glBindVertexArray = gl.BindVertexArray
local glBlendFuncSeparate = gl.BlendFuncSeparate
local glBlitFramebuffer = gl.BlitFramebuffer
local glBufferSubData = gl.BufferSubData
local glCheckError = gl.CheckError
local glClear = gl.Clear
local glClearBufferfv = gl.ClearBufferfv
local glClearColor = gl.ClearColor
local glCullFace = gl.CullFace
local glDepthFunc = gl.DepthFunc
local glDisable = gl.Disable
local glDisablei = gl.Disablei
local glDisableVertexAttribArray = gl.DisableVertexAttribArray
local glDrawArrays = gl.DrawArrays
local glEnable = gl.Enable
local glEnablei = gl.Enablei
local glEnableVertexAttribArray = gl.EnableVertexAttribArray
local glFinish = gl.Finish
local glGetError = gl.GetError
local glHint = gl.Hint
local glLineStipple = gl.LineStipple
local glLineWidth = gl.LineWidth
local glMultiDrawArrays = gl.MultiDrawArrays
local glPointSize = gl.PointSize
local glPolygonMode = gl.PolygonMode
local glPolygonOffset = gl.PolygonOffset
local glReadBuffer = gl.ReadBuffer
local glReadPixels = gl.ReadPixels
local glScissor = gl.Scissor
local glUniform1f = gl.Uniform1f
local glUniform1i = gl.Uniform1i
local glUniform3f = gl.Uniform3f
local glUniform4f = gl.Uniform4f
local glUniformMatrix4fv = gl.UniformMatrix4fv
local glUseProgram = gl.UseProgram
local glVertexAttrib3f = gl.VertexAttrib3f
local glVertexAttribPointer = gl.VertexAttribPointer
local glViewport = gl.Viewport
local glFlush = gl.Flush

local GL_FALSE = gl.FALSE
local GL_TRUE = gl.TRUE

local gl

------------------------------------------------------------------------------
-- scene rendering code

local relative_entity_matrices = {}
local absolute_entity_matrices = {}

local function compute_absolute_matrix(scene, i)
	if absolute_entity_matrices[i] then return end
	
	local entities = scene.entities
	local entity = entities[i]
	local trajectory = entity.trajectory
	if trajectory then
		local parent = trajectory.parent
		if parent and parent~=0 then
			compute_absolute_matrix(scene, parent)
			absolute_entity_matrices[i] = absolute_entity_matrices[parent] * relative_entity_matrices[i]
		else
			absolute_entity_matrices[i] = relative_entity_matrices[i]
		end
	end
end

local function set_parent_absolute_matrix_reversed(scene, i, m)
	local entities = scene.entities
	local entity = entities[i]
	local trajectory = entity.trajectory
	if trajectory then
		local parent = trajectory.parent
		if parent and parent~=0 then
			assert(absolute_entity_matrices[parent]==nil)
			absolute_entity_matrices[parent] = m
			m = m * relative_entity_matrices[parent].inverse
			set_parent_absolute_matrix_reversed(scene, parent, m)
		end
	end
end

local function compute_entity_positions(scene, t)
	local entities = scene.entities
	for i=1,#entities do
		local entity = entities[i]
		local trajectory = entity.trajectory
		if trajectory then
			local translation,orientation = traj.compute_relative_transform(trajectory, t, scene.entities)
			assert(geometry.type(translation)=='vector')
			assert(geometry.type(orientation)=='quaternion')
			relative_entity_matrices[i] = matrixh(vector(translation)) * matrixh(quaternion(orientation))
		end
	end
	absolute_entity_matrices = {}
	local root = scene.root_entity
	if root > 0 then
		absolute_entity_matrices[root] = matrixh()
		local m = relative_entity_matrices[root].inverse
		set_parent_absolute_matrix_reversed(scene, root, m)
	end
	for i=1,#entities do
		compute_absolute_matrix(scene, i)
	end
end

local function config_shaders_view_matrices(shaders, view_matrix, projection_matrix, viewport)
	local inverse_projection_matrix
	for name,shader in pairs(shaders) do
		glUseProgram(shader.program); glCheckError()
		local Viewport = shader.uniforms.Viewport
		if Viewport >= 0 then
			glUniform4f(Viewport, table.unpack(viewport)); glCheckError()
		end
		local ViewMatrix = shader.uniforms.ViewMatrix
		if ViewMatrix >= 0 then
			glUniformMatrix4fv(ViewMatrix, false, view_matrix.glmatrix); glCheckError()
		end
		local ProjectionMatrix = shader.uniforms.ProjectionMatrix
		if ProjectionMatrix >= 0 then
			glUniformMatrix4fv(ProjectionMatrix, false, projection_matrix.glmatrix); glCheckError()
		end
		local ProjectionMatrixInverse = shader.uniforms.ProjectionMatrixInverse
		if ProjectionMatrixInverse >= 0 then
			if not inverse_projection_matrix then inverse_projection_matrix = projection_matrix.inverse end
			glUniformMatrix4fv(ProjectionMatrixInverse, false, inverse_projection_matrix.glmatrix); glCheckError()
		end
	end
end

local function config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
	local ModelMatrix = shader.uniforms.ModelMatrix
	if ModelMatrix >= 0 then
		glUniformMatrix4fv(ModelMatrix, false, model_matrix.glmatrix); glCheckError()
	end
	local ModelViewMatrix = shader.uniforms.ModelViewMatrix
	if ModelViewMatrix >= 0 then
		local model_view_matrix = view_matrix * model_matrix
		glUniformMatrix4fv(ModelViewMatrix, false, model_view_matrix.glmatrix); glCheckError()
	end
	local ModelViewProjectionMatrix = shader.uniforms.ModelViewProjectionMatrix
	if ModelViewProjectionMatrix >= 0 then
		local model_view_projection_matrix = projection_matrix * view_matrix * model_matrix
		glUniformMatrix4fv(ModelViewProjectionMatrix, false, model_view_projection_matrix.glmatrix); glCheckError()
	end
end

local function draw_entity(i, entity, t, view_matrix, projection_matrix, shaders)
	local primcount = entity.arrays.primcount
	if primcount >= 1 then
		local shader = shaders.entity
		
		local model_matrix = assert(absolute_entity_matrices[i])
		
		local mesh = entity.mesh
		
		config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
		
		glBindBuffer('ARRAY_BUFFER', mesh.vbo); glCheckError()
		if mesh.albedo == 0 then
			glUniform1i(shader.uniforms.HasAlbedoTexture, GL_FALSE); glCheckError()
		else
			glBindTexture('TEXTURE_2D', mesh.albedo); glCheckError()
			glUniform1i(shader.uniforms.HasAlbedoTexture, GL_TRUE); glCheckError()
		end
		
		if config.assets_use_doubles then
			glVertexAttribPointer(0, 3, 'DOUBLE', false, 104, 0); glCheckError()
			glVertexAttribPointer(1, 3, 'DOUBLE', false, 104, 24); glCheckError()
			glVertexAttribPointer(2, 3, 'DOUBLE', false, 104, 48); glCheckError()
		else
			glVertexAttribPointer(0, 3, 'FLOAT', false, 52, 0); glCheckError()
			glVertexAttribPointer(1, 3, 'FLOAT', false, 52, 12); glCheckError()
			glVertexAttribPointer(2, 3, 'FLOAT', false, 52, 24); glCheckError()
		end
		
		glMultiDrawArrays('TRIANGLES', entity.arrays.first, entity.arrays.count, primcount); glCheckError()
	end
end

local function draw_sky2(entity, t, view_matrix, projection_matrix, shaders)
	local shader = shaders.sky
	
	glUseProgram(shader.program); glCheckError()
	config_shader_model_matrices(shader, matrixh(), view_matrix, projection_matrix)
	
	glBindVertexArray(fullscreen_mesh.vao); glCheckError()
	glDepthFunc('LEQUAL'); glCheckError()
	glDrawArrays(fullscreen_mesh.mode, 0, fullscreen_mesh.size); glCheckError()
	glDepthFunc('LESS'); glCheckError()
end

local function draw_entities(scene, t, view_matrix, projection_matrix, shaders)
	local shader = shaders.entity

	local sky
	
	glUseProgram(shader.program); glCheckError()
	
	glUniform1i(shader.uniforms.AlbedoTexture, 0); glCheckError()
	glActiveTexture('TEXTURE0'); glCheckError()
	
	glBindVertexArray(0); glCheckError()
	glEnableVertexAttribArray(0); glCheckError()
	glEnableVertexAttribArray(1); glCheckError()
	glEnableVertexAttribArray(2); glCheckError()
	
	if config.wireframe or scene.view.wireframe then
		glPolygonMode('FRONT', 'LINE'); glCheckError()
	end
	
	local entities = scene.entities
	for i=1,#entities do
		local entity = entities[i]
		if entity.type=='sky' then
			sky = entity
		elseif entity.type=='null' then
			-- nothing to display
		elseif entity.type then
			draw_entity(i, entity, t, view_matrix, projection_matrix, shaders)
		end
	end
	
	if config.wireframe or scene.view.wireframe then
		glPolygonMode('FRONT', 'FILL'); glCheckError()
	end
	
	glDisableVertexAttribArray(0); glCheckError()
	glDisableVertexAttribArray(1); glCheckError()
	glDisableVertexAttribArray(2); glCheckError()
	
	if sky and shaders~=shadow_shaders and config.draw_sky then
		draw_sky2(sky, t, view_matrix, projection_matrix, shaders)
	end
end

local function draw_null_entity(i, entity, t, view_matrix, projection_matrix, shaders)
	local shader = shaders.flat
	
	local model_matrix = assert(absolute_entity_matrices[i])
	
	config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
	
	glDrawArrays(origin.mode, 0, origin.size); glCheckError()
end

local function draw_null_entities(scene, t, view_matrix, projection_matrix, shaders)
	local shader = shaders.flat
	
	glUseProgram(shader.program); glCheckError()
	glBindVertexArray(origin.vao); glCheckError()
	
	local entities = scene.entities
	for i=1,#entities do
		local entity = entities[i]
		if entity.type=='null' then
			draw_null_entity(i, entity, t, view_matrix, projection_matrix, shaders)
		end
	end
end

local function draw_arrow_data(color, shaders)
	local shader = shaders.flat
	
	if shader.attributes.in_Color >= 0 then
		glVertexAttrib3f(shader.attributes.in_Color, color.r, color.g, color.b); glCheckError()
	end
	
	glDrawArrays(arrow_data.top.mode, arrow_data.top.first, arrow_data.top.size); glCheckError()
	glDrawArrays(arrow_data.bottom.mode, arrow_data.bottom.first, arrow_data.bottom.size); glCheckError()
	glDrawArrays(arrow_data.side.mode, arrow_data.side.first, arrow_data.side.size); glCheckError()
end

local gray = {r=0.25,g=0.25,b=0.25}
local white = {r=0.75,g=0.75,b=0.75}
local function draw_arrow(model_matrix, view_matrix, projection_matrix, shaders)
	local shader
	if config.geometry_wireframe then
		shader = shaders.wireframe
	else
		shader = shaders.flat
	end
	glUseProgram(shader.program); glCheckError()
	config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
	
	glBindVertexArray(arrow_data.vao); glCheckError()
	
	-- draw solid arrow
	draw_arrow_data(gray, shaders)
	
	if not config.geometry_wireframe then
		-- draw edges, with an offset to avoid z-fight
		glPolygonMode('FRONT', 'LINE'); glCheckError()
		glEnable('POLYGON_OFFSET_LINE'); glCheckError()
		glPolygonOffset(-1, 0); glCheckError()
		glDepthFunc('LEQUAL'); glCheckError()
		
		draw_arrow_data(white, shaders)
		
		glDepthFunc('LESS'); glCheckError()
		glDisable('POLYGON_OFFSET_LINE'); glCheckError()
		glPolygonOffset(0, 0); glCheckError()
		glPolygonMode('FRONT', 'FILL'); glCheckError()
	end
end

local function draw_origin(model_matrix, view_matrix, projection_matrix, shaders)
	local shader = shaders.flat
	
	glUseProgram(shader.program); glCheckError()
	config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
	
	glBindVertexArray(origin.vao); glCheckError()
	glDrawArrays(origin.mode, 0, origin.size); glCheckError()
end

local function draw_sun_direction(model_matrix, view_matrix, projection_matrix, shaders)
	local shader = shaders.flat
	
	glUseProgram(shader.program); glCheckError()
	config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
	
	if shader.attributes.in_Color >= 0 then
		glVertexAttrib3f(shader.attributes.in_Color, 1, 1, 1); glCheckError()
	end
	
	glBindVertexArray(sun_mesh.vao); glCheckError()
	glDrawArrays(sun_mesh.mode, 0, sun_mesh.size); glCheckError()
end

local function read_scene_matrix(matrix, scene_matrix)
	for r=1,4 do for c=1,4 do
		local k = r*10+c
		matrix[k] = scene_matrix['m'..k]
	end end
end

local function draw_camera(scene, camera, view_matrix, projection_matrix, shaders)
	local shader = shaders.flat
	
	if camera.type=='matrix' then
		local camera_matrix = matrixh()
		read_scene_matrix(camera_matrix, camera)
		
		local model_matrix = camera_matrix.inverse
		
		glUseProgram(shader.program); glCheckError()
		config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
		
		glBindVertexArray(frustum_data.vao); glCheckError()
		glDrawArrays(frustum_data.origin.mode, frustum_data.origin.first, frustum_data.origin.size); glCheckError()
		glDrawArrays(frustum_data.frustum.mode, frustum_data.frustum.first, frustum_data.frustum.size); glCheckError()
	else
		local view,projection = camera_utils.compute_matrices(camera, scene, absolute_entity_matrices)
		
		glUseProgram(shader.program); glCheckError()
		glBindVertexArray(frustum_data.vao); glCheckError()
		
		local model_matrix = view.inverse
		config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
		glDrawArrays(frustum_data.origin.mode, frustum_data.origin.first, frustum_data.origin.size); glCheckError()
		
		local model_matrix = view.inverse * projection.inverse
		config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
		glDrawArrays(frustum_data.frustum.mode, frustum_data.frustum.first, frustum_data.frustum.size); glCheckError()
	end
end

local function draw_antialiasing_debug_lines(projection_matrix, shaders)
	local shader = shaders.flat
	
	glUseProgram(shader.program); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ViewMatrix, false, matrixh().glmatrix); glCheckError()
	config_shader_model_matrices(shader, matrixh(), matrixh(), projection_matrix)
	if shader.attributes.in_Color >= 0 then
		glVertexAttrib3f(shader.attributes.in_Color, 1, 1, 1); glCheckError()
	end
	
	glLineWidth(2); glCheckError()
	glBindVertexArray(antialiasing_debug_lines.vao); glCheckError()
	glDrawArrays(antialiasing_debug_lines.mode, 0, antialiasing_debug_lines.size); glCheckError()
end

local function draw_scene(scene, t, lights, view_matrix, projection_matrix, shaders, mode)
	if lights then
		for i,light in ipairs(lights) do
			glActiveTexture('TEXTURE'..(4+i-1)); glCheckError()
			glBindTexture('TEXTURE_2D', light.shadow); glCheckError()
		end
	end
	
	local sun = lights and lights[1]
	
	-- configure uniforms common to all models
	config_shaders_view_matrices(shaders, view_matrix, projection_matrix, viewport)
	for name,shader in pairs(shaders) do
		glUseProgram(shader.program); glCheckError()
		if sun then
			glUniform3f(shader.uniforms.SunDirection, sun.direction:get_components()); glCheckError()
			glUniformMatrix4fv(shader.uniforms.ShadowMatrix, false, sun.matrix.glmatrix); glCheckError()
		end
		glUniform1i(shader.uniforms.ShadowTexture, 4); glCheckError()
	end
	
	-- draw the origin tri-axis, and the debug grid
	if config.display_debug_shapes then
		draw_origin(matrixh(), view_matrix, projection_matrix, shaders)
	end
	
	-- draw a small vector indicating the sun direction
	if config.display_debug_shapes and lights then
		for i,light in ipairs(lights) do
			draw_sun_direction(matrixh(light.orientation), view_matrix, projection_matrix, shaders)
		end
	end
	
	-- display the entities
	if config.display_entities then
		draw_entities(scene, t, view_matrix, projection_matrix, shaders)
		if config.display_debug_shapes then
			draw_null_entities(scene, t, view_matrix, projection_matrix, shaders)
		end
	end
	
	-- display the viewer debug position (the big arrow)
	if config.display_debug_position and scene.debug_position and scene.cameras[1].distance > 0 then
		local model_matrix =
			matrixh(vector(scene.debug_position.location)) *
			matrixh(quaternion(scene.debug_position.orientation))
		
		model_matrix = model_matrix * matrixh.scale(scene.cameras[scene.current_camera].distance / 10)
		
		draw_arrow(model_matrix, view_matrix, projection_matrix, shaders)
	end
	
	-- display the second camera frustum
	if config.display_camera_boxes and mode~='shadow' then
		for i=1,4 do
			if i ~= scene.current_camera and scene.cameras[i].type then
				draw_camera(scene, scene.cameras[i], view_matrix, projection_matrix, shaders)
			end
		end
	--	draw_camera(scene, 'shadow_perspective', view_matrix, projection_matrix, shaders)
	--	draw_camera(scene, 'shadow_ortho', view_matrix, projection_matrix, shaders)
	end
	
	if config.display_antialiasing_debug_lines and mode~='shadow' then
		draw_antialiasing_debug_lines(projection_matrix, shaders)
	end
end

local function render_scene(scene, t, lights, fbo, view_matrix, projection_matrix, shaders, mode)
	glBindFramebuffer('DRAW_FRAMEBUFFER', fbo.fbo); glCheckError()
	
	-- setup rendering
	
	glEnable('CULL_FACE'); glCheckError()
	if mode=='shadow' then
		glCullFace('FRONT'); glCheckError()
	elseif mode=='visual' then
		glCullFace('BACK'); glCheckError()
	end
	
	if mode=='shadow' then
		glEnable('DEPTH_CLAMP'); glCheckError()
	end
	
	glEnable('DEPTH_TEST'); glCheckError()
	glDepthFunc('LESS'); glCheckError()
	
	glEnablei('BLEND', 0); glCheckError()
	glDisablei('BLEND', 1); glCheckError()
	glBlendFuncSeparate('SRC_ALPHA', 'ONE_MINUS_SRC_ALPHA', 'ONE', 'ONE_MINUS_SRC_ALPHA'); glCheckError()
	
	glViewport(0, 0, fbo.width, fbo.height); glCheckError()
	
	-- clear the framebuffer
	for type,color in pairs(fbo.clear) do
		if type=='depth' then
			glClearBufferfv('DEPTH', 0, {color}); glCheckError()
		else
			local n = tonumber((type:match('color(%d+)')))
			glClearBufferfv('COLOR', n, color); glCheckError()
		end
	end
	
	-- draw the models
	draw_scene(scene, t, lights, view_matrix, projection_matrix, shaders, mode)
	
	if mode=='shadow' then
		glDisable('DEPTH_CLAMP'); glCheckError()
	end
end

------------------------------------------------------------------------------
-- other code

local function update_graph(v)
	graph.last = graph.last + 1
	if graph.last > graph.size then graph.last = 1 end
	
	local t = graph.last / 60
	local elements = {{vertex=vector(t, v)}}
	local data = serial.serialize.array(elements, '*', 'element_v2')
	glBindVertexArray(0); glCheckError()
	glBindBuffer('ARRAY_BUFFER', graph.vbo); glCheckError()
	glBufferSubData('ARRAY_BUFFER', (graph.last - 1) * graph.stride, data); glCheckError()
end

local function post_process(scene, fbo, sun_orientation, view_matrix, projection_matrix)
	-- red:		605nm
	-- green:	540nm
	-- blue:	445nm
	
	local shader = shaders.post_process
	
	glActiveTexture('TEXTURE0'); glCheckError()
	if fbo.samples > 1 then
		glBindTexture('TEXTURE_2D_MULTISAMPLE', fbo.color); glCheckError()
	else
		glBindTexture('TEXTURE_2D', fbo.color); glCheckError()
	end
	glActiveTexture('TEXTURE1'); glCheckError()
	if config.use_distance_buffer then
		if fbo.samples > 1 then
			glBindTexture('TEXTURE_2D_MULTISAMPLE', fbo.distance); glCheckError()
		else
			glBindTexture('TEXTURE_2D', fbo.distance); glCheckError()
		end
	end
	glActiveTexture('TEXTURE2'); glCheckError()
	glBindTexture('TEXTURE_2D', scattering); glCheckError()
	if config.use_dithering then
		glActiveTexture('TEXTURE3'); glCheckError()
		glBindTexture('TEXTURE_2D', dithering); glCheckError()
	end
	
	glUseProgram(shader.program); glCheckError()
	glUniform1i(shader.uniforms.ColorTexture, 0); glCheckError()
	if config.use_distance_buffer then
		glUniform1i(shader.uniforms.DistanceTexture, 1); glCheckError()
	end
	glUniform1i(shader.uniforms.ScatteringTexture, 2); glCheckError()
	glUniform1i(shader.uniforms.DitheringTexture, 3); glCheckError()
	glUniform1i(shader.uniforms.DebugNumber, scene.debug_number); glCheckError()
	
	glUniformMatrix4fv(shader.uniforms.ViewMatrix, false, view_matrix.glmatrix); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ProjectionMatrixInverse, false, projection_matrix.inverse.glmatrix); glCheckError()
	local sun_direction = sun_orientation:rotate(vector(0, 0, -1))
	glUniform3f(shader.uniforms.SunDirection, view_matrix:transform(sun_direction):get_components()); glCheckError()
	
	glBindVertexArray(fullscreen_mesh.vao); glCheckError()
	glDrawArrays(fullscreen_mesh.mode, 0, fullscreen_mesh.size); glCheckError()
end

local function prepare_render_target(target)
	glBindFramebuffer('DRAW_FRAMEBUFFER', target.fbo); glCheckError()
	
	-- setup rendering
	
	glDisable('DEPTH_TEST'); glCheckError()
	glDisable('BLEND'); glCheckError()
	
	glViewport(0, 0, target.width, target.height); glCheckError()
	
	-- clear the framebuffer
	for type,color in pairs(target.clear) do
		if type=='depth' then
			glClearBufferfv('DEPTH', 0, {color}); glCheckError()
		else
			local n = tonumber((type:match('color(%d+)')))
			glClearBufferfv('COLOR', n, color); glCheckError()
		end
	end
end

local function render_stats(scene)
	update_graph(_G.dt)
	
	glDisable('DEPTH_TEST'); glCheckError()
	glEnable('BLEND'); glCheckError()
	glBlendFuncSeparate('SRC_ALPHA', 'ONE_MINUS_SRC_ALPHA', 'ONE', 'ONE_MINUS_SRC_ALPHA'); glCheckError()
	
	local projection_matrix = matrixh.glortho(0, scene.view.width, 0, scene.view.height, -1, 11)
	
	local view_matrix = matrixh()
	
	local border = 10
	local xsize = config.stats_width
	local ysize = config.stats_height
	
	local xrange = 512/60
	local yrange = 1/30
	
	local shader = shaders.ui_v2c4
	glUseProgram(shader.program); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ViewMatrix, false, view_matrix.glmatrix); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ProjectionMatrix, false, projection_matrix.glmatrix); glCheckError()
	
	-- 0.5 offset is to align axis on pixels centers
	local model_matrix = matrixh(vector(scene.view.width-(xsize+2*border)-0.5, 2*border+0.5, 0))
	
	config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
	
	glLineWidth(1); glCheckError()
	
	glBindVertexArray(graphbg.vao); glCheckError()
	glDrawArrays(graphbg.bg.mode, graphbg.bg.first, graphbg.bg.size); glCheckError()
	glDrawArrays(graphbg.axis.mode, graphbg.axis.first, graphbg.axis.size); glCheckError()
	
	model_matrix = model_matrix * matrixh.glscale(xsize / xrange, ysize / yrange, 1)
	
	local shader = shaders.ui_v2c4
	glUseProgram(shader.program); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ProjectionMatrix, false, projection_matrix.glmatrix); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ViewMatrix, false, view_matrix.glmatrix); glCheckError()
	config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
	if shader.attributes.in_Color >= 0 then
		glVertexAttrib3f(shader.attributes.in_Color, 1, 0, 0); glCheckError()
	end
	
	glLineWidth(0.2); glCheckError()
	
	glBindVertexArray(graph.vao); glCheckError()
	glDrawArrays('POINTS', 0, graph.last); glCheckError()
	glDrawArrays('POINTS', graph.last, graph.size-graph.last); glCheckError()
end

local function render_ui(scene)
	glDisable('DEPTH_TEST'); glCheckError()
	glEnable('BLEND'); glCheckError()
	glBlendFuncSeparate('SRC_ALPHA', 'ONE_MINUS_SRC_ALPHA', 'ONE', 'ONE_MINUS_SRC_ALPHA'); glCheckError()
	
	local projection_matrix = matrixh.glortho(0, scene.view.width, 0, scene.view.height, -1, 11)
	
	local view_matrix = matrixh()
	
	local visible = {}
	local uiobjects = scene.uiobjects
	for i=1,#uiobjects do
		local uiobject = uiobjects[i]
		if uiobject.used then
			table.insert(visible, uiobject)
		end
	end
	table.sort(visible, function(a, b) return a.layer < b.layer end)
	
	local shader = shaders.uiobject
	glUseProgram(shader.program); glCheckError()
	glUniform1i(shader.uniforms.Texture, 0); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ProjectionMatrix, false, projection_matrix.glmatrix); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ViewMatrix, false, view_matrix.glmatrix); glCheckError()
	
	glBindVertexArray(0); glCheckError()
	glEnableVertexAttribArray(0); glCheckError()
	glEnableVertexAttribArray(1); glCheckError()
	glActiveTexture('TEXTURE0'); glCheckError()
	
	for _,uiobject in ipairs(visible) do
		local position,color = uiobject.position,uiobject.color
		local model_matrix = matrixh(vector(position.x, position.y, position.z))
		
		glUniform3f(shader.uniforms.Color, color.r, color.g, color.b); glCheckError()
		config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
		
		local mesh = uiobject.mesh
		glBindBuffer('ARRAY_BUFFER', mesh.vbo); glCheckError()
		if mesh.texture == -1 then
			glBindTexture('TEXTURE_2D', post_process_fbo.color); glCheckError()
		else
			glBindTexture('TEXTURE_2D', mesh.texture); glCheckError()
		end
		
		glVertexAttribPointer(0, 2, 'FLOAT', false, 16, 0); glCheckError()
		glVertexAttribPointer(1, 2, 'FLOAT', false, 16, 8); glCheckError()
		
		glDrawArrays('QUADS', 0, mesh.size); glCheckError()
	end
	
	glDisableVertexAttribArray(0); glCheckError()
	glDisableVertexAttribArray(1); glCheckError()
end

local function render_curves(scene)
	glDisable('DEPTH_TEST'); glCheckError()
	glEnable('BLEND'); glCheckError()
	glBlendFuncSeparate('SRC_ALPHA', 'ONE_MINUS_SRC_ALPHA', 'ONE', 'ONE_MINUS_SRC_ALPHA'); glCheckError()
	
	local projection_matrix = matrixh.glortho(0, scene.view.width, 0, scene.view.height, -1, 11)
	
	local view_matrix = matrixh()
	
	local visible = {}
	local curves = scene.curves
	for i=1,#curves do
		local uiobject = curves[i]
		if uiobject.used then
			table.insert(visible, uiobject)
		end
	end
	table.sort(visible, function(a, b) return a.layer < b.layer end)
	
	local shader_texture = shaders.uiobject
	glUseProgram(shader_texture.program); glCheckError()
	glUniform1i(shader_texture.uniforms.Texture, 0); glCheckError()
	glUniformMatrix4fv(shader_texture.uniforms.ProjectionMatrix, false, projection_matrix.glmatrix); glCheckError()
	glUniformMatrix4fv(shader_texture.uniforms.ViewMatrix, false, view_matrix.glmatrix); glCheckError()
	
	local shader = shaders.ui_v2
	glUseProgram(shader.program); glCheckError()
	glUniform1i(shader.uniforms.Texture, 0); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ProjectionMatrix, false, projection_matrix.glmatrix); glCheckError()
	glUniformMatrix4fv(shader.uniforms.ViewMatrix, false, view_matrix.glmatrix); glCheckError()
	
	glBindVertexArray(0); glCheckError()
	glEnableVertexAttribArray(0); glCheckError()
	
	for _,uiobject in ipairs(visible) do
		local color = uiobject.color
		local model_matrix = matrixh()
		read_scene_matrix(model_matrix, uiobject.transform)
		
		glUniform4f(shader.uniforms.Color, color.r, color.g, color.b, color.a); glCheckError()
		config_shader_model_matrices(shader, model_matrix, view_matrix, projection_matrix)
		
		local mesh = uiobject.mesh
		glBindBuffer('ARRAY_BUFFER', mesh.vbo); glCheckError()
		
		local stride = uiobject.stride
		if stride ~= 0 then
			glVertexAttribPointer(0, 2, 'FLOAT', false, 8*stride, 0); glCheckError()
		else
			glVertexAttribPointer(0, 2, 'FLOAT', false, 8, 0); glCheckError()
		end
		
		local stipple = uiobject.stipple
		local stipple_factor = stipple.factor
		if stipple_factor ~= 0 then
			glEnable('LINE_STIPPLE'); glCheckError()
			glLineStipple(stipple_factor, stipple.pattern); glCheckError()
		else
			glDisable('LINE_STIPPLE'); glCheckError()
		end
		
		local scissor = uiobject.scissor
		local scissor_width = scissor.width
		if scissor_width ~= 0 then
			glEnable('SCISSOR_TEST'); glCheckError()
			glScissor(scissor.x, scissor.y, scissor_width, scissor.height); glCheckError()
		else
			glDisable('SCISSOR_TEST'); glCheckError()
		end
		
		local line_width = uiobject.line_width
		if line_width ~= 0 then
			glLineWidth(line_width); glCheckError()
			if stride ~= 0 then
				glDrawArrays('LINE_STRIP', 0, math.floor(mesh.size / stride)); glCheckError()
			else
				glDrawArrays('LINES', 0, mesh.size); glCheckError()
			end
		end
		
		local point_size = uiobject.point_size
		if point_size ~= 0 and stride ~= 0 then
			glPointSize(point_size); glCheckError()
			glDrawArrays('POINTS', 0, math.floor(mesh.size / stride)); glCheckError()
		end
	end
	
	glDisable('SCISSOR_TEST'); glCheckError()
	glDisable('LINE_STIPPLE'); glCheckError()
	glDisableVertexAttribArray(0); glCheckError()
end

------------------------------------------------------------------------------
-- display

glEnable('LINE_SMOOTH'); glCheckError()

return function(scene)
	
	--........................................................................
	-- update global data
	
	local t = time.time() + scene.time_offset
	
	local sun_orientation = quaternion(scene.sun.direction)
	
	--........................................................................
	-- reload the shaders if necessary
	
	if config.autoreload then
		for name,shader in pairs(shaders) do
			local success,err = pcall(function() shader:load() end)
			if not success then
				print(err)
			end
		end
	end
	
	--........................................................................
	-- update the FBO size
	
	scene_fbo:updateFramebuffer(scene.view.width, scene.view.height)
	post_process_fbo:updateFramebuffer(scene.view.width, scene.view.height)
	
	--........................................................................
	-- make computations for this frame
	
	compute_entity_positions(scene, t)
	
	--........................................................................
	-- render the world frame
	
	if scene.current_camera ~= 0 then
		-- render the scene shadow maps
		local lights = {}
		
		-- eventually loop
		do
			-- compute the shadow camera matrices
		--	local view_matrix,projection_matrix = camera_utils.compute_matrices(scene.cameras[2], scene, absolute_entity_matrices)
			local sun_direction = sun_orientation:rotate(vector(0, 0, -1))
			local view_matrix,projection_matrix = camera_utils.compute_matrices({
			--	type = 'shadow_perspective',
				type = 'shadow_ortho',
				light_direction = sun_direction,
				target = scene.cameras[scene.current_camera]
			}, scene, absolute_entity_matrices)
			
			-- render the shadow map
			render_scene(scene, t, nil, shadow, view_matrix, projection_matrix, shadow_shaders, 'shadow')
			
			table.insert(lights, {
				orientation = sun_orientation,
				direction = sun_direction,
				matrix = matrixh(vector(0.5,0.5,0.5)) * matrixh.scale(0.5) * projection_matrix * view_matrix,
				shadow = shadow.depth,
			})
		end
		
		-- compute the regular camera matrices
		local view_matrix,projection_matrix = camera_utils.compute_matrices(scene.cameras[scene.current_camera], scene, absolute_entity_matrices)
		
		-- render the 3D scene
		render_scene(scene, t, lights, scene_fbo, view_matrix, projection_matrix, visual_shaders, 'visual')
		
		-- post-process the scene
		prepare_render_target(post_process_fbo)
		post_process(scene, scene_fbo, sun_orientation, view_matrix, projection_matrix)
	end
	
	--........................................................................
	-- prepare final 2D rendering
	
	glBindFramebuffer('DRAW_FRAMEBUFFER', 0); glCheckError()
	glViewport(0, 0, scene.view.width, scene.view.height); glCheckError()
	
	glDisable('DEPTH_TEST'); glCheckError()
	glDisable('BLEND'); glCheckError()
	
	-- :NOTE: clear is not necessary when the UI is opaque and covers the whole window
	local clear_color = scene.clear_color
	glClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a); glCheckError()
	glClear('COLOR_BUFFER_BIT'); glCheckError()
	
	--........................................................................
	-- display uiobjects
	
	if config.display_uiobjects then
		render_ui(scene)
		render_curves(scene) -- :TODO: render curves in the world frame to properly blend with UI
	end
	
	--........................................................................
	-- display statistics
	
	if config.display_stats then
		render_stats(scene)
	end
	
	--........................................................................
	-- capture
	
	if capture then
		-- wait for rendering completion
		glFinish(); glCheckError()
		
		-- generate the image
		local width,height = scene.view.width,scene.view.height
		local image = imagelib.new(height, width, 4, 8)
		glBindFramebuffer('READ_FRAMEBUFFER', 0); glCheckError()
		glReadPixels(0, 0, width, height, 'RGBA', 'UNSIGNED_BYTE', image); glCheckError()
		-- the framebuffer is alpha-pre-multiplied (because that's how hardware accelerated alpha-composition needs it to be)
		image:demultiply_alpha()
		-- the framebuffer starts at the bottom-left
		image:flip()
		
		-- list existing files
		local files = {}
		for file in lfs.dir(".") do files[file] = true end
		
		-- format specific code
		if config.capture_format=='png' then
			local format = "screenshot%03d.png"
			local n = 0
			local filename = format:format(n)
			while files[filename] do
				n = n+1
				filename = format:format(n)
			end
			png.write(filename, image)
			print("saved screenshot to "..filename)
		elseif config.capture_format=='jpeg' then
			local format = "screenshot%03d.jpg"
			local n = 0
			local filename = format:format(n)
			while files[filename] do
				n = n+1
				filename = format:format(n)
			end
			local pngfilename = "screenshot_tmp.png"
			png.write(pngfilename, image)
			local jpegfilename = pngfilename:gsub('%.png$', '.jpg')
			os.execute("convert "..pngfilename.." "..filename)
			os.remove(pngfilename)
			print("saved screenshot to "..filename)
		else
			print("unsupported capture format "..(type(config.capture_format)=='string' and "'"..config.capture_format.."'" or tostring(config.capture_format)))
		end
		capture = nil
	end
	
end

------------------------------------------------------------------------------

