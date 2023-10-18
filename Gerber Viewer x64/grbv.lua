local os = require 'os'
local io = require 'io'
local math = require 'math'
local table = require 'table'
local debug = require 'debug'
local string = require 'string'
local nb = require 'nb'
local lfs = require 'lfs'
local xml = require 'xml'
local pathlib = require 'path'
local imagelib = require 'image'
local win32 = require 'win32'
local kernel32 = require 'win32.kernel32'
local user32 = require 'win32.user32'
local comdlg32 = require 'win32.comdlg32'
local serial = require 'serial'
local unicode = require 'unicode'
local geometry = require 'geometry'
local vector = geometry.vector
local vectorh = geometry.vectorh
local quaternion = geometry.quaternion
local matrixh = geometry.matrixh
local gl = require 'gl'
require 'gl.CheckError'
local png = require 'png'
local glo = require 'glo'
local dump = require 'dump'
local launcher = require 'launcher'
local configlib = require 'config'

local assets = require 'engine.assets'

local gui = require 'engine.gui'
local drag = require 'engine.drag'
local time = require 'engine.time'
local fonts = require 'engine.fonts'
local reports = require 'engine.report'
local signal = require 'engine.signal'
local emit = signal.emit
local scene_utils = require 'engine.scene.utils'

local boards = require 'grbv.boards'

pathlib.install()

------------------------------------------------------------------------------
-- identify ourselves

local version,release,cpu
if kernel32.GetConsoleWindow() then
	pcall(function()
		local id = io.popen("hg id -i 2>NUL", "r"):read("*all")
		if not id:match('^%s*$') and not id:match('^abort') then
			version = id:gsub('%s*$', '')
		end
	end)
end
if not version then
	local path = pathlib.split(kernel32.GetModuleFileName()).dir / '.hg_id'
	local file = io.open(path, "r")
	if file then
		version = assert(file:read('*line'))
		assert(file:close())
	end
end
if not release then
	local path = pathlib.split(kernel32.GetModuleFileName()).dir / '.release_name'
	local file = io.open(path, "r")
	if file then
		release = assert(file:read('*line'))
		assert(file:close())
	end
end
do
	local system_info = assert(kernel32.GetSystemInfo())
	cpu = ({
		[win32.PROCESSOR_ARCHITECTURE_INTEL] = 'x86',
		[win32.PROCESSOR_ARCHITECTURE_AMD64] = 'x64',
		[win32.PROCESSOR_ARCHITECTURE_IA64] = 'Itanium',
		[win32.PROCESSOR_ARCHITECTURE_ARM] = 'ARM',
	})[system_info.wProcessorArchitecture]
end
print("Gerber Viewer version "..(version or "unknown").." release "..(release or "unknown").." for "..(cpu or "unknown cpu"))

local title = launcher.title
if release then title = title.." "..release
elseif version then title = title.." "..version end
if cpu then title = title.." "..cpu end
launcher.title = title
local agent = 'grbv/'..(release or version or 'unknown')
if release and version or cpu then
	agent = agent..' ('
	if release and version then
		agent = agent..version
	end
	if release and version and cpu then
		agent = agent..'; '
	end
	if cpu then
		agent = agent..cpu
	end
	agent = agent..')'
end

------------------------------------------------------------------------------
-- config

local config = {
	width = 800,
	height = 600,
	wireframe = false,
	fullscreen = false,
	translucent = true,
	time_font_size = 12,
	board = nil,
	colors = nil, -- same as 'default'
	loading_gear = true,
	quick_colors = {
		'default',
		'seeed',
		'osh',
		'altium',
		'flex',
	},
	report_errors = true,
	bindings = "bindings.conf",
	display_parts = false,
	show_debug_spheres = false,
	rotation_mode = 'free',
--	rotation_mode = 'polar',
--	translation_mode = 'screen',
--	translation_mode = 'plane',
	translation_mode = 'projected',
	hidden_layers = {},
	hide_version = true,
}

-- config file
configlib.load(config, 'grbv.conf')

-- command line processing
configlib.args(config, ...)
assert(#config == 0, "unexpected argument '"..tostring(config[1]).."'")

-- validate some config options
if type(config.quick_colors)~='table' then
	error("configuration option 'quick_colors' must be a table")
end
if type(config.hidden_layers)~='table' then
	error("configuration option 'hidden_layers' must be a table")
end

------------------------------------------------------------------------------
-- everything else should be error-free, so run it in a pcall and report errors online

-- configure reporting (may also be used for statistics)
reports.agent = agent
reports.host = 'piratery.net'
reports.path = '/grbv/report'
reports.user = config.user
local os_report,gl_report

local traceback
do
	local base = kernel32.GetModuleFileName(nil)
	local dir = base:match('^(.*\\)[^\\]*$')
	local dirpattern = dir:gsub('[]^$()%%.[*+?-]', '%%%1')
	local tail = dir:match('(\\[^\\]*\\)$')
	local tailpattern = tail:gsub('[]^$()%%.[*+?-]', '%%%1')
	function traceback(...)
		msg = debug.traceback(...)
		-- remove paths in full
		msg = msg:gsub(dirpattern, '')
		-- remove short_src
		-- :TODO: write a custom traceback that doesn't use short_src
		msg = msg:gsub('%.%.%.(.-'..tailpattern..')', function(tail)
			if tail==dir:sub(-#tail) then
				return ""
			end
		end)
		return msg
	end
end

-- wrap the rest of the main script in a function
local arg = {...}
local main = function()

------------------------------------------------------------------------------
-- get info regarding current OS

os_report = gui.os_report()

------------------------------------------------------------------------------
-- scene camera init

local scene = require('engine.scene').write
local scene_read = require('engine.scene').read

scene:lock()

local function calcdistance(index)
	return math.exp(-index / 10) * 100
end

local camera_distance_index = 0
do
	local camera = scene.cameras[1]
	camera.type = 'third_person'
	local offset = camera.offset
	offset.x = 0
	offset.y = 0
	offset.z = 0
	local theta = 0 -- -15
	local phi = 0 -- 30
	camera.orientation = quaternion.glrotation(phi, 1, 0, 0) * quaternion.glrotation(theta, 0, 1, 0)
	camera.distance = calcdistance(camera_distance_index)
	camera.fovy = math.rad(40)
	scene.sun.direction = quaternion.glrotation(180 - theta, 0, 1, 0) * quaternion.glrotation(phi, 1, 0, 0)
end

local commands = {}

function commands.zoom(delta)
	scene:lock()
	camera_distance_index = camera_distance_index + delta
	scene.cameras[1].distance = calcdistance(camera_distance_index)
	scene:unlock()
end

scene.current_camera = 1

------------------------------------------------------------------------------
-- view dimensions init

scene.view.width = config.width
scene.view.height = config.height
scene.view.wireframe = config.wireframe

------------------------------------------------------------------------------
-- keyboard modifiers

local ctrl = false

signal.connect(gui, 'key_down', nil, function(key)
	if key=='CONTROL' then
		ctrl = true
	end
end)

signal.connect(gui, 'key_up', nil, function(key)
	if key=='CONTROL' then
		ctrl = false
	end
end)

------------------------------------------------------------------------------
-- camera distance

signal.connect(gui, 'mouse_wheel', nil, function(dwheel)
	commands.zoom(dwheel / 120)
end)

------------------------------------------------------------------------------
-- window creation and control

signal.connect(gui, 'size', nil, function(w, h)
	scene:lock()
	scene.view.width = w
	scene.view.height = h
	scene:unlock()
end)

signal.connect(gui, 'vsync', nil, function()
	scene:lock()
	scene:unlock()
end)

gui.init(scene.view.width, scene.view.height, "Gerber3DViewer F2-Top, F3-Bottom, F4-F8 (Color)", {
	fullscreen = config.fullscreen,
	translucent = config.translucent,
	drop_target = true,
}, assets.find('gerber.ico'))
gui.setup_gl_context(gui.window)
gl_report = gui.gl_report()

-- check OpenGL version
local version = gl.GetString('VERSION'); gl.CheckError()
if version:match('^[12]%.') then
	error("OpenGL 3 or later is required")
end

boards.init_gl()
gui.start_gl_thread(table.unpack(arg))

if not gui.translucent then
	scene.clear_color = {r=1, g=1, b=1, a=1}
end

local function cleanup()
	local path = 'cache'
	for file in lfs.dir(path) do
		if 	file~='.' and file~='..' then
			local theFile =  path .. '/' .. file ;
			os.remove(theFile);
		end		
	end
	-- make sure we're not called from the gui thread, since we need to kill it
	gui.hide()
	emit(_G, 'shutdown')
	gui.cleanup_gl()
	gui.cleanup()
end

signal.connect_async(gui, 'quit', nil, cleanup)

signal.connect(gui, 'key_down', nil, function(key)
	if key=='ESCAPE' then
		nb.add_thread_later(cleanup)
	end
end)

------------------------------------------------------------------------------
-- scene entities

local orientation_node = scene.entities[1]
do
	orientation_node.type = 'null'
	local trajectory = orientation_node.trajectory
	trajectory.type = 'static_3d'
	trajectory.position = {x=0, y=0, z=0}
	trajectory.orientation = {a=1, b=0, c=0, d=0}
end

local position_node = scene.entities[2]
do
	position_node.type = 'null'
	local trajectory = position_node.trajectory
	trajectory.type = 'static_3d'
	trajectory.parent = 1
	trajectory.position = {x=0, y=0, z=0}
	trajectory.orientation = {a=1, b=0, c=0, d=0}
end

function commands.front()
	scene:lock()
	orientation_node.trajectory.orientation = {a=1, b=0, c=0, d=0}
	position_node.trajectory.position = {x=0, y=0, z=0}
	scene:unlock()
end

function commands.back()
	scene:lock()
	orientation_node.trajectory.orientation = quaternion.glrotation(180, 0, 1, 0)
	position_node.trajectory.position = {x=0, y=0, z=0}
	scene:unlock()
end

local top,bottom,side
do
	for i=3,5 do
		local entity = scene.entities[i]
		entity.type = 'simple'
		local trajectory = entity.trajectory
		trajectory.type = 'static_3d'
		trajectory.position = {x=0, y=0, z=0}
		trajectory.orientation = {a=1, b=0, c=0, d=0}
		trajectory.parent = 2
		entity.mesh.vbo = gl.GenBuffers(1)[1]; gl.CheckError()
		entity.mesh.albedo = gl.GenTextures(1)[1]; gl.CheckError()
	end
	
	top = scene.entities[3]
	bottom = scene.entities[4]
	side = scene.entities[5]
end

-- create a rotating gear
local loading_gear
if config.loading_gear then
	local entity = scene.entities[6]
	entity.type = 'simple'
	local trajectory = entity.trajectory
	trajectory.type = 'inertial'
	trajectory.position = {x=1000, y=0, z=0}
	trajectory.orientation = {a=1, b=0, c=0, d=0}
	trajectory.t0 = 0
	trajectory.velocity = {x=0, y=0, z=0}
	trajectory.rotation = quaternion.glrotation(100, 0, 0, 1)
	entity.mesh.vbo = gl.GenBuffers(1)[1]; gl.CheckError()
	local data = assert(assert(io.open(assets.find("meshes/gear.bin"), "rb")):read('*all'))
	gl.BindBuffer('ARRAY_BUFFER', entity.mesh.vbo); gl.CheckError()
	gl.BufferData('ARRAY_BUFFER', data, 'STATIC_DRAW'); gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
	entity.mesh.size = #data / (4*9)
	entity.arrays.primcount = 1
	entity.arrays.first[1] = 0
	entity.arrays.count[1] = entity.mesh.size
	loading_gear = entity
	
	loading_gear.type = nil
	
	local camera = scene.cameras[2]
	camera.type = 'third_person'
	camera.target = 6
	camera.offset = {x=0, y=0, z=0}
	camera.orientation = {a=1, b=0, c=0, d=0}
	camera.distance = calcdistance(0)
	camera.fovy = math.rad(40)
end

if config.show_debug_spheres then
	local data = assert(assert(io.open(assets.find("meshes/spheres.bin"), "rb")):read('a'))
	
	local entity = scene.entities[7]
	entity.type = 'simple'
	local trajectory = entity.trajectory
	trajectory.type = 'static_3d'
	trajectory.position = {x=0, y=0, z=0}
	trajectory.orientation = {a=1, b=0, c=0, d=0}
	trajectory.parent = 2
	entity.mesh.vbo = gl.GenBuffers(1)[1]; gl.CheckError()
	
	local mesh = entity.mesh
	gl.BindBuffer('ARRAY_BUFFER', mesh.vbo); gl.CheckError()
	gl.BufferData('ARRAY_BUFFER', data, 'STATIC_DRAW'); gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
	mesh.size = #data / (13 * 4) -- 13 floats per vertex, 4 bytes per float
	
	local arrays = entity.arrays
	arrays.primcount = 1
	arrays.first[1] = 0
	arrays.count[1] = mesh.size
end

local function unload_board()
	local version = scene.version
	local removed_textures = {}
	
	scene:lock()
	
	for i=3,5 do
		local entity = scene.entities[i]
		entity.arrays.primcount = 0
		entity.mesh.size = 0
	end
	
	if config.display_parts then
		for i=7,1024 do
			local entity = scene.entities[i]
			if entity.type=='simple' then
				if entity.mesh.albedo ~= 0 then
					table.insert(removed_textures, entity.mesh.albedo)
					entity.mesh.albedo = 0
				end
				entity.arrays.primcount = 0
				entity.mesh.size = 0
				entity.type = nil
			end
		end
	end
	
	scene:unlock()
	
	-- wait for a few of vsync to make sure the display thread is no longer using the textures and buffers
	local sync = scene_read.version
	while sync < version do
		signal.wait(gui, 'vsync')
		sync = scene_read.version
	end
	
	-- free up as much video memory as possible
	for i=3,5 do
		local entity = scene.entities[i]
		gl.BindBuffer('ARRAY_BUFFER', entity.mesh.vbo); gl.CheckError()
		gl.BufferData('ARRAY_BUFFER', "", 'STATIC_DRAW'); gl.CheckError()
		gl.BindTexture('TEXTURE_2D', entity.mesh.albedo); gl.CheckError()
		gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', 0, 0, 0, 'RGBA', 'UNSIGNED_BYTE', nil); gl.CheckError()
	end
	gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	
	-- delete old textures
	if #removed_textures >= 1 then
		gl.DeleteTextures(removed_textures); gl.CheckError()
	end
end

local board_thickness = 0

local function load_board(boardname, colors)
	-- load new board
	local board,msg = boards.load(boardname, colors)
	if not board then
		return nil,msg
	end
	
	local cx = (board.extents.left + board.extents.right) / 2
	local cy = (board.extents.bottom + board.extents.top) / 2
	
	board_thickness = board.style.thickness
	
	scene:lock()
	
	-- build entities
	top.trajectory.position = {x=-cx, y=-cy, z=0}
	boards.gen_top_mesh(top, board)
	boards.gen_top_texture(top.mesh.albedo, board, config.hidden_layers)
	
	bottom.trajectory.position = {x=-cx, y=-cy, z=0}
	boards.gen_bottom_mesh(bottom, board)
	boards.gen_bottom_texture(bottom.mesh.albedo, board, config.hidden_layers)
	
	side.trajectory.position = {x=-cx, y=-cy, z=0}
	boards.gen_side_mesh(side, board)
	boards.gen_side_texture(side.mesh.albedo, board, config.hidden_layers, top.mesh.albedo)
	
	if config.display_parts then
		local lastindex = 6
		if board.images.bom and board.images.bom.layers then -- :FIXME: caching is broken for the BOM images so layers can be empty
			for _,layer in ipairs(board.images.bom.layers) do
				for _,path in ipairs(layer) do
					if path.aperture and path.aperture.device then
						local device = path.aperture.parameters
						local part = path[1]
						lastindex = lastindex + 1
						local index = lastindex
						local entity = scene.entities[6+index]
						entity.type = 'simple'
						local trajectory = entity.trajectory
						trajectory.type = 'static_3d'
						if layer.polarity=='top' then
							trajectory.position = {x=part.x, y=part.y, z=board.style.thickness/2}
							trajectory.orientation = quaternion.glrotation(part.angle, 0, 0, 1)
							trajectory.parent = 3
						elseif layer.polarity=='bottom' then
							trajectory.position = {x=part.x, y=part.y, z=-board.style.thickness/2}
							trajectory.orientation = quaternion.glrotation(180, 0, 1, 0) * quaternion.glrotation(part.angle, 0, 0, 1)
							trajectory.parent = 4
						else
							error("unsupported part side "..tostring(layer.polarity))
						end
						if entity.mesh.vbo == 0 then
							entity.mesh.vbo = gl.GenBuffers(1)[1]; gl.CheckError()
						end
						local package = device.package
						if package and package ~= "" and package ~= "*" then
							local found,path = pcall(function() return assets.find("meshes/parts/"..package..".bin") end)
							if found then
								local data = assert(assert(io.open(path, "rb")):read('*all'))
								gl.BindBuffer('ARRAY_BUFFER', entity.mesh.vbo); gl.CheckError()
								gl.BufferData('ARRAY_BUFFER', data, 'STATIC_DRAW'); gl.CheckError()
								gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
								entity.mesh.size = #data / (4*9)
								entity.arrays.primcount = 1
								entity.arrays.first[1] = 0
								entity.arrays.count[1] = entity.mesh.size
							end
							local found,path = pcall(function() return assets.find("meshes/parts/"..package..".png") end)
							if found then
								local image = png.read(path)
								if image then
									local size = #image
									if size.bit_depth==8 and size.channels==3 then
										entity.mesh.albedo = gl.GenTextures(1)[1]; gl.CheckError()
										gl.BindTexture('TEXTURE_2D', entity.mesh.albedo); gl.CheckError()
										gl.TexParameteri('TEXTURE_2D', 'GENERATE_MIPMAP', 'TRUE'); gl.CheckError()
										gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'LINEAR'); gl.CheckError()
										gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'LINEAR_MIPMAP_LINEAR'); gl.CheckError()
										gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_S', gl.CLAMP_TO_EDGE); gl.CheckError()
										gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_T', gl.CLAMP_TO_EDGE); gl.CheckError()
										if gl.extensions.GL_EXT_texture_filter_anisotropic then
											local anisotropy = gl.GetFloatv('MAX_TEXTURE_MAX_ANISOTROPY_EXT')[1]
											gl.TexParameterf('TEXTURE_2D', 'TEXTURE_MAX_ANISOTROPY_EXT', anisotropy); gl.CheckError()
										end
										gl.TexImage2D('TEXTURE_2D', 0, 'RGB', size.width, size.height, 0, 'RGB', 'UNSIGNED_BYTE', image); gl.CheckError()
										gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
									end
								end
							end
						end
					end
				end
			end
		end
	end
	
	scene:unlock()
	
	gl.Flush()
	
	boards.unload(board)
	
	print("board loaded")
	return true
end

local function get_texture(texture)
	gl.BindTexture('TEXTURE_2D', texture); gl.CheckError()
	local tw = gl.GetTexLevelParameteriv('TEXTURE_2D', 0, 'TEXTURE_WIDTH')[1]; gl.CheckError()
	local th = gl.GetTexLevelParameteriv('TEXTURE_2D', 0, 'TEXTURE_HEIGHT')[1]; gl.CheckError()
	local texture = gl.GetTexImage('TEXTURE_2D', 0, 'RGBA', 'UNSIGNED_BYTE'); gl.CheckError()
	gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
	assert(#texture == tw * th * 4)
	
	local image = imagelib.new(th, tw, 4, 8)
	image[{}] = texture
	
	return image
end

local function get_mesh(mesh, vertex_offset)
	local optim = require 'assets.grbv'
	
	local len = mesh.size * optim.element_size
	gl.BindBuffer('ARRAY_BUFFER', mesh.vbo); gl.CheckError()
	local data = gl.GetBufferSubData('ARRAY_BUFFER', 0, len); gl.CheckError()
	gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
	
	local nf = math.tointeger(#data / 4)
	local nv = math.tointeger(nf / 9)
	local floats = {}
	for i=1,nf do
		floats[i] = string.unpack("f", data, i * 4 - 3)
	end
	local positions = {}
	local normals = {}
	local texcoords = {}
	for v=1,nv do
		for k=1,3 do
			table.insert(positions, floats[(v - 1) * 9 + k])
			table.insert(normals, floats[(v - 1) * 9 + 3 + k])
			table.insert(texcoords, floats[(v - 1) * 9 + 6 + k])
		end
	end
	local triangles = {}
	if not vertex_offset then vertex_offset = 0 end
	for v=1,nv do
		for a=1,3 do
			table.insert(triangles, v + vertex_offset)
		end
	end
	
	return {
		positions = positions,
		normals = normals,
		texcoords = texcoords,
		triangles = triangles,
	}
end

local function multi_concat(t, sep, ...)
	local groups = {...}
	for i=1,#groups,2 do
		local stride,sep = groups[i],groups[i+1]
		local t2 = {}
		for i=1,#t,stride do
			table.insert(t2, table.concat(t, sep, i, i+stride-1))
		end
		t = t2
	end
	return table.concat(t, sep)
end

local function e(label)
	return function(t)
		xml.setlabel(t, label)
		return t
	end
end

function save_board()
	local ofn = win32.new 'OPENFILENAME' {
		hwndOwner = gui.window,
		nFilterIndex = 1,
		lpstrFilter = {"Wavefront .obj file (*.obj)", "*.obj"},
		Flags = { 'OFN_OVERWRITEPROMPT' },
		lpstrFile = win32.MAX_PATH,
		lpstrDefExt = "obj",
	}
	local success = comdlg32.GetSaveFileName(ofn)
	if not success then return end
	
	local base_path = ofn.lpstrFile:gsub('\0*$', '')
	if not base_path:lower():match('%.obj$') then
		base_path = base_path..'.obj'
	end
	
	local obj_path = pathlib.split(base_path)
	local mtl_path = obj_path.dir / obj_path.file:gsub('%.obj$', '.mtl')
	local top_path = obj_path.dir / obj_path.file:gsub('%.obj$', '-top.png')
	local bottom_path = obj_path.dir / obj_path.file:gsub('%.obj$', '-bottom.png')
	
	local image = get_texture(top.mesh.albedo)
	image:flip()
	png.write(tostring(top_path), image)
	local image = get_texture(bottom.mesh.albedo)
	image:flip()
	png.write(tostring(bottom_path), image)
	
	local file = assert(io.open(mtl_path, 'wb'))
	assert(file:write([[
# Gerber Viewer board export
# Material Count: 2

newmtl Top
Ka 1.000000 1.000000 1.000000
Kd 1.000000 1.000000 1.000000
Ks 0.000000 0.000000 0.000000
Ns 1
Ni 1.000000
d 1.000000
illum 2
map_Kd ]]..top_path.file..[[


newmtl Bottom
Ka 1.000000 1.000000 1.000000
Kd 1.000000 1.000000 1.000000
Ks 0.000000 0.000000 0.000000
Ns 1
Ni 1.000000
d 1.000000
illum 2
map_Kd ]]..bottom_path.file..[[

]]))
	assert(file:close())
	
	local file = assert(io.open(obj_path, 'wb'))
	assert(file:write([[
# Gerber Viewer board export
# http://piratery.net/grbv/
mtllib ]]..mtl_path.file..[[

]]))
	local vertices = 0
	for _,object in pairs{
		{top, 'Top', 'Top'},
		{side, 'Side', 'Top'},
		{bottom, 'Bottom', 'Bottom'},
	} do
		local entity,name,material = table.unpack(object)
		local mesh = get_mesh(entity.mesh, vertices)
		assert(#mesh.positions == #mesh.normals and #mesh.positions == #mesh.texcoords)
		vertices = vertices + #mesh.positions / 3
		assert(file:write("o "..name.."\n"))
		assert(file:write("v "..multi_concat(mesh.positions, "\nv ", 3, " ").."\n"))
		assert(file:write("vn "..multi_concat(mesh.normals, "\nvn ", 3, " ").."\n"))
		assert(file:write("vt "..multi_concat(mesh.texcoords, "\nvt ", 3, " ").."\n"))
		assert(file:write("usemtl "..material.."\n"))
		assert(file:write("s off\n"))
		assert(file:write("f "..multi_concat(mesh.triangles, "\nf ", 3, "/", 3, " ").."\n"))
	end
	assert(file:close())
	
	print("board saved")
end

------------------------------------------------------------------------------
-- mouse drag

local drag_mode_orientation = {
	name='orientation', infinite=true,
	condition = function(button) return button=='left' end,
}

signal.connect(drag_mode_orientation, 'drag', nil, function(dx, dy)
	if config.rotation_mode=='free' then
		scene:lock()
		orientation_node.trajectory.orientation = quaternion.glrotation(dy, 1, 0, 0) * quaternion.glrotation(dx, 0, 1, 0) * quaternion(orientation_node.trajectory.orientation)
		scene:unlock()
	elseif config.rotation_mode=='polar' then
		scene:lock()
		local board_to_world = quaternion(orientation_node.trajectory.orientation)
		local world_to_board = board_to_world.conjugate
		local world_up = vector(0, 1, 0)
		local board_up = world_to_board:rotate(world_up)
		local board_normal = vector(0, 0, 1)
		-- if the board is pointing downward, and we want the yaw rotation to be inverted
		if board_up * board_normal < 0 then
			dx = -dx
		end
		orientation_node.trajectory.orientation = quaternion.glrotation(dy, 1, 0, 0) * quaternion(orientation_node.trajectory.orientation) * quaternion.glrotation(dx, 0, 0, 1)
		scene:unlock()
	elseif config.rotation_mode=='free_camera' then
		scene:lock()
		local camera = scene.cameras[1]
		camera.orientation = quaternion.glrotation(dy, 1, 0, 0) * quaternion.glrotation(dx, 0, 1, 0) * quaternion(camera.orientation)
		scene:unlock()
	end
end)

drag.add_mode(drag_mode_orientation)

if config.translation_mode=='camera' then
	local drag_mode_position = {
		name='position', infinite=false,
		condition = function(button) return button=='right' end,
	}
	
	signal.connect(drag_mode_position, 'drag', nil, function(dx, dy)
		scene:lock()
		local position = orientation_node.trajectory.position
		local k = calcdistance(camera_distance_index) / 1000
		position.x = position.x + dx * k
		position.y = position.y - dy * k
		scene:unlock()
	end)
	
	drag.add_mode(drag_mode_position)
	
elseif config.translation_mode=='plane' then
	local drag_mode_position = {
		name='position', infinite=true,
		condition = function(button) return button=='right' end,
	}
	
	signal.connect(drag_mode_position, 'drag', nil, function(dx, dy)
		scene:lock()
		local orientation = quaternion(orientation_node.trajectory.orientation)
		local front = orientation.conjugate:rotate(vector(0, 0, 1))
		local up = orientation.conjugate:rotate(vector(0, 1, 0))
		local right = orientation.conjugate:rotate(vector(1, 0, 0))
		local z = vector(0, 0, 1)
		if front * z < 0 then
			dx = -dx
			dy = -dy
		end
		local board_up = (z ^ right).normalized
		local board_right = (up ^ z).normalized
		local k = calcdistance(camera_distance_index) / 1000
		position_node.trajectory.position = vector(position_node.trajectory.position) + board_right * dx * k + board_up * -dy * k
		scene:unlock()
	end)
	
	drag.add_mode(drag_mode_position)

elseif config.translation_mode=='projected' then
	local camera_utils = require 'engine.scene.camera'
	
	local function screen_to_plane(x, y)
		local proj_x = (x + 0.5) / scene.view.width * 2 - 1
		local proj_y = (y + 0.5) / scene.view.height * -2 + 1
		local proj_near = vectorh(proj_x, proj_y, -1, 1)
		local world_to_view,view_to_projection = camera_utils.compute_matrices(scene.cameras[1], scene, {})
		local projection_to_view = view_to_projection.inverse
		local view_to_world = world_to_view.inverse
		local view_near = projection_to_view:transform(proj_near)
		local view_camera = vectorh(0, 0, 0, 1)
		local world_near = view_to_world:transform(view_near)
		local world_camera = view_to_world:transform(view_camera)
		-- project the line [camera;near) onto the PCB plane
		local board_to_world = quaternion(orientation_node.trajectory.orientation)
		local world_to_board = board_to_world.conjugate
		local board_near = world_to_board:rotate(world_near.vector)
		local board_camera = world_to_board:rotate(world_camera.vector)
		local cursor_dir = (board_near - board_camera)
		-- drag the top of the board from the camera point of view
		local cursor_z
		if board_camera.z > board_thickness / 2 then
			cursor_z = board_thickness / 2
		elseif board_camera.z < -board_thickness / 2 then
			cursor_z = -board_thickness / 2
		else
			-- if the camera is within the board thickness, drag the z=0 plane to avoid behind-the-camera projection problems
			cursor_z = 0
		end
		local position = board_camera - cursor_dir * ((board_camera.z - cursor_z) / cursor_dir.z)
		return position
	end
	
	local translation_origin
	
	signal.connect(gui, 'right_button_down', nil, function(x, y)
		if config.translation_mode=='projected' then
			translation_origin = {
				cursor_pos = screen_to_plane(x, y),
				board_pos = vector(position_node.trajectory.position),
			}
		end
	end)
	
	signal.connect(gui, 'right_button_up', nil, function()
		translation_origin = nil
	end)
	
	signal.connect(gui, 'mouse_move', nil, function(x, y)
		if translation_origin then
			local cursor_pos = screen_to_plane(x, y)
			scene:lock()
			position_node.trajectory.position = translation_origin.board_pos + cursor_pos - translation_origin.cursor_pos
			scene:unlock()
		end
	end)
end

------------------------------------------------------------------------------
-- world frame

local world_frame
for i=1,#scene.uiobjects do
	if not scene.uiobjects[i].used then
		world_frame = scene.uiobjects[i]
		break
	end
end

local buffer = glo.buffer()
world_frame.used = true
world_frame.color = {r=1, g=1, b=1, a=1}
world_frame.mesh.texture = -1
world_frame.mesh.size = 0
world_frame.mesh.vbo = buffer.name
world_frame.layer = -1

local function update_world_frame(w, h)
	scene:lock()
	
	local data = {
		{vertex={x=0, y=0}, texcoord={x=0, y=0}},
		{vertex={x=w, y=0}, texcoord={x=1, y=0}},
		{vertex={x=w, y=h}, texcoord={x=1, y=1}},
		{vertex={x=0, y=h}, texcoord={x=0, y=1}},
	}
	
	local strdata = serial.serialize.array(data, '*', 'glyph_element')
	
	scene_utils.buffer_data(buffer.name, strdata)
	
	world_frame.mesh.size = #data
	
	scene:unlock()
end

update_world_frame(scene.view.width, scene.view.height)

signal.connect(gui, 'size', nil, update_world_frame)

------------------------------------------------------------------------------
-- debug font

local debug_font = fonts.font(assets.find('fonts/FixedsysExcelsior.ttf'), 12, 0, nil, true)

------------------------------------------------------------------------------
-- debug text

if not config.hide_version then
	local text = assert(debug_font:text())
	text:append(unicode.convert(title, 'utf-8', 'ucs-4', 'table'))
	text.uiobject.layer = -1
	if gui.translucent then
		text.uiobject.color.r = 0.5
		text.uiobject.color.g = 0.5
		text.uiobject.color.b = 0.5
	else
		text.uiobject.color.r = 0.8
		text.uiobject.color.g = 0.8
		text.uiobject.color.b = 0.8
	end
	
	local function on_size(w, h)
		text.uiobject.position.x = w - text.width - 10
		text.uiobject.position.y = 10
	end
	on_size(scene.view.width, scene.view.height)
	signal.connect(gui, 'size', nil, on_size)
end

------------------------------------------------------------------------------
--[=[
-- time

local border,lightness
if gui.translucent then
	border,lightness = 1,1
else
	border,lightness = 0,0
end

local time_font = fonts.font(assets.find('fonts/Bandy.ttf'), config.time_font_size, border, nil, true)

local text = assert(time_font:text())
text.uiobject.position.x = 10
text.uiobject.position.y = 10
text.uiobject.color.g = lightness
text.uiobject.color.b = lightness
text.uiobject.color.r = lightness

local last
local function update_time()
	local time = kernel32.GetLocalTime()
	local h,m,s,ms = time.wHour, time.wMinute, time.wSecond, time.wMilliseconds
--	local n = (((h * 60) + m) * 60 + s) * 1000 + ms
	local k = ((h * 60) + m) * 60 + s
	if k ~= last then
		scene:lock()
		local str = string.format("%02d:%02d:%02d", h, m, s)
		text:settext(str)
		scene:unlock()
		last = k
	end
end
update_time()
signal.connect(gui, 'vsync', nil, update_time)
--]=]

------------------------------------------------------------------------------
-- [=[
-- message

local border,lightness,shadow
if gui.translucent then
	border,lightness,shadow = 0.5,1,{offset={x=2, y=-2}, color={r=0,g=0,b=0,a=0.5}}
else
	border,lightness = 0,0
end

--local message_font_name = assets.find('fonts/narcissusopensg.ttf')
assets.path = assets.path..';'..os.getenv('windir')..[[\fonts\?]]
local message_font_name = assets.find('segoeui.ttf')
local message_font = fonts.font(message_font_name, 36, border, shadow, true)

local text = assert(message_font:text())
text.uiobject.position.x = 0
text.uiobject.position.y = 0
text.uiobject.color.g = lightness
text.uiobject.color.b = lightness
text.uiobject.color.r = lightness

local message_y = 0.5
local function on_size(w, h)
	scene:lock()
	text.uiobject.position.x = math.floor(w / 2 - text.width / 2)
	text.uiobject.position.y = math.floor(h * message_y - message_font.height / 2)
	scene:unlock()
end
local default_message = "Перетащите файлы Gerber сюда"
function _G.set_message(str, y)
	scene:lock()
	text:settext(str or default_message)
	message_y = y or 0.5
	on_size(scene.view.width, scene.view.height)
	scene:unlock()
end
on_size(scene.view.width, scene.view.height)
signal.connect(gui, 'size', nil, on_size)
--]=]

------------------------------------------------------------------------------
-- screen capture

signal.connect(gui, 'key_up', nil, function(key)
	if key=='SNAPSHOT' then
		scene.stream:write([[
			capture = true
		]])
	end
end)

------------------------------------------------------------------------------

--[=[
signal.connect(gui, 'key_up', nil, function(key)
	if key=='F2' then
		scene.stream:write([[
			do
				local filename = os.date("scene-%Y-%m-%dT%H.%M.%S.lua")
				local dump = require 'dump'
				dump.tofile(require('engine.scene.utils').dump(require('engine.scene').read, "../scene-types.lua"), filename)
				print("dump saved to "..filename)
			end
		]])
	end
end)
--]=]

------------------------------------------------------------------------------
-- main loop

local function enable_loading()
	scene:lock()
	if loading_gear then
		loading_gear.type = 'simple'
		scene.current_camera = 2
	end
	_G.set_message("Обработка...", 0.25)
	scene:unlock()
end

local function disable_loading()
	scene:lock()
	if loading_gear then
		scene.current_camera = 1
		loading_gear.type = nil
	end
	_G.set_message("")
	scene:unlock()
end

local function reload()
	if config.board then
		enable_loading()
		unload_board()
		local success,msg = load_board(config.board, config.colors or config.quick_colors[1] or 'default')
		disable_loading()
		if not success then
			gui.message_box(msg)
			_G.set_message()
		end
	else
		unload_board()
		_G.set_message()
	end
end

function commands.load(board)
	config.board = board
	reload()
end

function commands.colors(colors)
	config.colors = colors
	reload()
end

function commands.save()
	save_board()
end

local bindings = {}
if config.bindings and lfs.attributes(config.bindings, 'mode') then
	local env = setmetatable({}, {
		__index = function(_, k)
			if k=='config' then			
				return config
			else
				return commands[k]
			end
		end,
		__newindex = function(_, k, v)
			bindings[k] = v
		end,
	})
	-- throw errors in the bindings definition
	local chunk = assert(loadfile(config.bindings, "t", env))
	chunk()
end


signal.connect_async(gui, 'key_up', nil, function(key)
	if bindings[key] then
		-- catch errors in the bindings execution
		local success,msg = pcall(bindings[key])
		if not success then
			gui.message_box("Error while executing '"..tostring(key).."' key binding: "..msg)
		end
	elseif key=='PAUSE' then
		error("this is not an error")
	end
end)

signal.connect(gui, 'dropped_files', nil, function(files)
	config.board = files
	reload()
end)

if config.board then
	nb.add_thread(reload)
else
	_G.set_message()
end

scene:unlock()
gui.show()
nb.run()

------------------------------------------------------------------------------
-- run the main script (eventually catching and reporting errors)

end

local success,msg = xpcall(main, traceback)
if not success then
	gui.cleanup_gl()
	
	local report = {
		type = 'error',
	--	error = msg:match('[^\n]*:%d+: ([^\n]*)\n'),
		error = msg,
		os = os_report,
		gl = gl_report,
	}
	local reported = false
	if config.report_errors then
		-- ignore reporting errors
		pcall(function()
			nb.kill_all_threads()
			local threads = {}
			threads.report = nb.add_thread_later(function()
				assert(reports.send(report))
				reported = true
				nb.kill_thread(threads.timeout)
			end)
			threads.timeout = nb.add_thread(function()
				nb.wait(5)
				nb.kill_thread(threads.report)
			end)
			nb.run()
		end)
	end
	if not reported then
		dump.tofile(report, "error-report.txt")
	end
	if config.report_errors and not config.user then
		msg = msg.."\n\nPlease consider setting the 'user' option in grbv.conf (see the manual for details) so that the devs can contact you when this error is fixed."
	end
	error(msg, 0) -- re-throw
end

------------------------------------------------------------------------------

print("exiting cleanly")

-- vi: ft=lua
