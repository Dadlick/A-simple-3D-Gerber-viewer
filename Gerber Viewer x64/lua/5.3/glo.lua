-- GL objects
local _M = {}

local gl = require 'gl'
require 'newproxy'

local texture_proto = newproxy(true)
local texture_mt = getmetatable(texture_proto)
local textures = setmetatable({}, {__mode='k'})

function _M.texture()
	local self = newproxy(texture_proto)
	textures[self] = gl.GenTextures(1)[1]
	return self
end

function texture_mt:__gc()
	local texture = textures[self]
	if texture then
		gl.DeleteTextures{texture}
	end
end

function texture_mt:__index(k)
	if k=='name' then
		return textures[self]
	end
end

local buffer_proto = newproxy(true)
local buffer_mt = getmetatable(buffer_proto)
local buffers = setmetatable({}, {__mode='k'})

function _M.buffer()
	local self = newproxy(buffer_proto)
	buffers[self] = gl.GenBuffers(1)[1]
	return self
end

function buffer_mt:__gc()
	local buffer = buffers[self]
	if buffer then
		gl.DeleteBuffers{buffer}
	end
end

function buffer_mt:__index(k)
	if k=='name' then
		return buffers[self]
	end
end

return _M
