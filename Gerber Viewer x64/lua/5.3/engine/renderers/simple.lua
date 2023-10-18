local os = require 'os'
local math = require 'math'
local table = require 'table'
local gl = require 'gl'
require 'gl.CheckError'
require 'gl.version'
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

local loadstring = loadstring or load

local config = {
	display_entities = true,
	display_uiobjects = true,
	multisample = 4,
	autoreload = false,
	wireframe = false,
	assets_use_doubles = false,
	stats_width = 400,
	stats_height = 50,
	capture_format = 'png',
	gl = {
		version = nil,
		profile = nil,
	},
}
configlib.load(config.gl, 'gl.conf')
configlib.load(config, 'display.conf')

local glsl_version = gl.glsl_version() or 0
if glsl_version < 1.5 then
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
}

shaders.entity = shader.new(assets.find('shaders/entity_textured_simple.glsl'), {
	in_Position = 0,
	in_Normal = 1,
	in_Color = 2,
}, world_output)

shaders.uiobject = shader.new(assets.find('shaders/uiobject.glsl'), {
	in_Position = 0,
	in_TexCoord = 1,
}, {
	out_Color = 0,
}, defines)

local visual_shaders = {
	entity = shaders.entity,
}

--............................................................................
-- main camera framebuffer object

local scene_fbo = fbo.new({
	color = {type='texture', format='RGBA8', attachment='COLOR_ATTACHMENT0'},
	depth = {type='renderbuffer', format='DEPTH_COMPONENT', attachment='DEPTH_ATTACHMENT'},
}, 1)

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
-- performance graph mesh

local graph
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
local glBlendFunci = gl.BlendFunci
local glBlendFuncSeparate = gl.BlendFuncSeparate
local glBlendFuncSeparatei = gl.BlendFuncSeparatei
local glBlitFramebuffer = gl.BlitFramebuffer
local glBufferSubData = gl.BufferSubData
local glCheckError = gl.CheckError
local glClear = gl.Clear
local glClearBufferfv = gl.ClearBufferfv
local glClearColor = gl.ClearColor
local glCullFace = gl.CullFace
local glDepthFunc = gl.DepthFunc
local glDisable = gl.Disable
local glDisableVertexAttribArray = gl.DisableVertexAttribArray
local glDrawArrays = gl.DrawArrays
local glEnable = gl.Enable
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

local function draw_entity(i, entity, t, view_matrix, projection_matrix, shaders)
	local primcount = entity.arrays.primcount
	if primcount >= 1 then
		local shader = shaders.entity
		
		local model_matrix = assert(absolute_entity_matrices[i])
		
		local mesh = entity.mesh
		
		glUniformMatrix4fv(shader.uniforms.ModelMatrix, false, model_matrix.glmatrix); glCheckError()
		
		glBindBuffer('ARRAY_BUFFER', mesh.vbo); glCheckError()
		if mesh.albedo == 0 then
			glUniform1i(shader.uniforms.HasColorTexture, GL_FALSE); glCheckError()
		else
			glBindTexture('TEXTURE_2D', mesh.albedo); glCheckError()
			glUniform1i(shader.uniforms.HasColorTexture, GL_TRUE); glCheckError()
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

local function draw_entities(scene, t, view_matrix, projection_matrix, shaders)
	local shader = shaders.entity

	glUseProgram(shader.program); glCheckError()
	
	glUniform1i(shader.uniforms.ColorTexture, 0); glCheckError()
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
			-- ignore
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
end

local function read_scene_matrix(matrix, scene_matrix)
	for r=1,4 do for c=1,4 do
		local k = r*10+c
		matrix[k] = scene_matrix['m'..k]
	end end
end

local function compute_camera_matrices(scene, camera)
	local view_matrix
	local projection_matrix
	
	if camera.type == 'third_person' then
		local orientation = quaternion(camera.orientation)
		local aspect_ratio = scene.view.width / scene.view.height
		
		local target = camera.target
		local campos
		local entity_model_matrix = absolute_entity_matrices[target]
		if target > 0 and entity_model_matrix then
			local target_position = entity_model_matrix:transform(vectorh(0,0,0,1)).vector
			campos = vector(camera.offset) + target_position
		elseif scene.debug_position then
			local target_location = vector(scene.debug_position.location)
			campos = target_location
		end
		
		local near = camera.distance / 10 -- 10 cm when target is at 1m
		local far = near * 2^24 -- 1600 km when target is at 1m
		projection_matrix = matrixh.glperspective(math.deg(camera.fovy), aspect_ratio, near, far)
		
		view_matrix = matrixh()
		
		view_matrix = matrixh(vector(-campos.x, -campos.y, -campos.z)) * view_matrix
		view_matrix = matrixh(orientation) * view_matrix
		view_matrix = matrixh(vector(0, 0, -camera.distance)) * view_matrix
	
	elseif camera.type=='free' then
		local position = vector(camera.position)
		local orientation = quaternion(camera.orientation)
		local frustum = camera.frustum
		if frustum.ortho then
			projection_matrix = matrixh.glortho(frustum.left, frustum.right, frustum.bottom, frustum.top, frustum.near, frustum.far+10)
		else
			projection_matrix = matrixh.glfrustum(frustum.left, frustum.right, frustum.bottom, frustum.top, frustum.near, frustum.far+10)
		end
		
		view_matrix = matrixh(orientation) * matrixh(-position)
	
	else
		error("unsupported camera type "..tostring(camera.type))
	end
	
	return view_matrix,projection_matrix
end

local function draw_scene(scene, t, lights, view_matrix, projection_matrix, shaders)
	local sun = lights and lights[1]
	
	-- configure uniforms common to all models
	for name,shader in pairs(shaders) do
		glUseProgram(shader.program); glCheckError()
		glUniformMatrix4fv(shader.uniforms.ViewMatrix, false, view_matrix.glmatrix); glCheckError()
		glUniformMatrix4fv(shader.uniforms.ProjectionMatrix, false, projection_matrix.glmatrix); glCheckError()
		if sun then
			glUniform3f(shader.uniforms.SunDirection, sun.direction:get_components()); glCheckError()
		end
	end
	
	-- display the entities
	if config.display_entities then
		draw_entities(scene, t, view_matrix, projection_matrix, shaders)
	end
end

local function render_scene(scene, t, lights, fbo, view_matrix, projection_matrix, shaders)
	glBindFramebuffer('DRAW_FRAMEBUFFER', fbo.fbo); glCheckError()
	
	-- setup rendering
	
	glEnable('CULL_FACE'); glCheckError()
	glCullFace('BACK'); glCheckError()
	
	glEnable('DEPTH_TEST'); glCheckError()
	glDepthFunc('LESS'); glCheckError()
	
	glEnable('BLEND'); glCheckError()
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
	draw_scene(scene, t, lights, view_matrix, projection_matrix, shaders)
end

------------------------------------------------------------------------------
-- other code

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
		glUniformMatrix4fv(shader.uniforms.ModelMatrix, false, model_matrix.glmatrix); glCheckError()
		
		local mesh = uiobject.mesh
		glBindBuffer('ARRAY_BUFFER', mesh.vbo); glCheckError()
		if mesh.texture == -1 then
			glBindTexture('TEXTURE_2D', scene_fbo.color); glCheckError()
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
			local sun_direction = sun_orientation:rotate(vector(0, 0, -1))
			table.insert(lights, {
				direction = sun_direction,
			})
		end
		
		-- compute the regular camera matrices
		local view_matrix,projection_matrix = compute_camera_matrices(scene, scene.cameras[scene.current_camera])
		
		-- render the 3D scene
		render_scene(scene, t, lights, scene_fbo, view_matrix, projection_matrix, visual_shaders)
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

