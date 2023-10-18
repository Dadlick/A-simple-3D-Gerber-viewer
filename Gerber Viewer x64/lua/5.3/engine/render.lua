local _M = {}

local io = require 'io'
local math = require 'math'
local debug = require 'debug'
local table = require 'table'
local string = require 'string'

local win32 = require 'win32'
local kernel32 = require 'win32.kernel32'
local user32 = require 'win32.user32'
local gdi32 = require 'win32.gdi32'
local opengl32 = require 'win32.opengl32'
local configlib = require 'config'
local gl = require 'gl'
require 'gl.CheckError'

local time = require 'engine.time'
local assets = require 'engine.assets'
local scene = require('engine.scene').read

local loadstring = loadstring or load
local unpack = unpack or table.unpack

local config = {
--	autoreload = false,
	vsync = false,
	debug = false,
	log_fps = false,
	renderer = 'default',
}
configlib.load(config, 'render.conf')

local function pack(...) return {n=select('#', ...), ...} end

--[=[
-- :NOTE: this code is for auto-reload, which has been temporarily disabled while we rework the renderer architecture
local source
local render
local function display(scene)
	if not render or config.autoreload then
		local path = assert(package.searchpath('engine.renderers.'..config.renderer, package.path))
		local file = io.open(path, 'rb')
		if file then
			local content = file:read('*all')
			file:close()
			if content and not config.debug then
				content = content:gsub('; glCheckError%(%)', '; glGetError()')
			end
			if content and content~=source then
				local chunk,msg = loadstring(content, '@'..tostring(path))
				if not chunk then
					if config.autoreload then
						print(msg)
					else
						error(msg)
					end
				else
					local result = pack(xpcall(chunk, debug.traceback))
					if not result[1] then
						if config.autoreload then
							print(result[2])
						else
							error(result[2])
						end
					else
						local func = result[2]
						if func then
							source = content
							render = func
						end
					end
				end
			end
		end
	end
	if render then
		local result = pack(xpcall(function() render(scene) end, debug.traceback))
		if not result[1] then
			if config.autoreload then
				print(result[2])
			else
				error(result[2])
			end
			render = nil
		else
			return unpack(result, 2, result.n)
		end
	end
end
--]=]

function _M.ThreadProc(window, dc, rc, vsync, ...)
	configlib.args(config, ...)
	
	--gl.MakeCurrent(dc, rc)
	assert(opengl32.wglMakeCurrent(dc, rc))
	
	do
		local SwapIntervalEXT = gl.SwapIntervalEXT
		if SwapIntervalEXT then
			SwapIntervalEXT(config.vsync and 1 or 0)
		end
	end
	
	-- load the configured renderer while the GL rendering context it active
	local render = require('engine.renderers.'..config.renderer)
	
	local continue = true
	local t0 = time.time()
	local log_t0 = math.floor(t0)
	local frames = 0
	_G.dt = 1/60
	while continue do
		do
			local t1 = time.time()
			_G.dt = t1-t0
			if config.log_fps then
				frames = frames + 1
				local log_t1 = math.floor(t1)
				if log_t1 ~= log_t0 then
					local s = string.format('%d fps     ', frames)
					io.write('\r'..s); io.flush()
					frames = 0
					log_t0 = log_t1
				end
			end
			t0 = t1
		end
		
		-- swap the scenegraph
		scene:swap()
		
		-- run the init code (scene-related changes that need to be applied after the swap)
		local init = scene.stream:read()
		if init then
			local prefix,suffix = "local gl = require 'gl'\n",""
			assert(loadstring(prefix..init..suffix))(); gl.CheckError()
			gl.BindBuffer('ARRAY_BUFFER', 0); gl.CheckError()
			gl.BindTexture('TEXTURE_2D', 0); gl.CheckError()
			gl.Flush(); gl.CheckError()
		end
		
		-- render the scene
		render(scene)
		
		-- tell the main thread we're done
		assert(kernel32.SetEvent(vsync))
		
		-- wait for vsync
		gdi32.SwapBuffers(dc)
		
		-- flush message queue
		local msg = user32.PeekMessage(nil, nil, nil, {'PM_REMOVE'})
		while msg do
			if msg.message==win32.WM_QUIT then
				continue = false
			end
			msg = user32.PeekMessage(nil, nil, nil, {'PM_REMOVE'})
		end
	end
	
	-- if we don't delete textures before cleanup, some platforms crash
	-- :TODO: find a better way to manage them
	if _G.grass then
		gl.DeleteTextures({_G.grass})
	end
	
	--gl.MakeCurrent(nil, nil)
	assert(opengl32.wglMakeCurrent(nil, nil))
end

return _M
