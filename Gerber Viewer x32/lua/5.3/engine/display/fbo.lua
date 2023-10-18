local _M = {}

local gl = require 'gl'
require 'gl.CheckError'

local methods = {}
local mt = {__index=methods}

local texfmt = {
	DEPTH_COMPONENT32F = {f='DEPTH_COMPONENT', t='FLOAT'},
	RGBA8 = {f='RGBA', t='UNSIGNED_BYTE'},
	R32F = {f='RED', t='FLOAT'},
	RGB32F = {f='RGB', t='FLOAT'},
	RGBA32F = {f='RGBA', t='FLOAT'},
}

function _M.new(buffers, samples, w, h)
	local self = {}
	
	self.buffers = buffers
	self.samples = samples or 1
	
	self.width,self.height = w or 1,h or 1
	self.viewport = {0, 0, self.width, self.height}
	
	-- setup attachment buffers
	for name,buffer in pairs(buffers) do
		if buffer.type=='texture' then
			self[name] = gl.GenTextures(1)[1]; gl.CheckError()
			if self.samples > 1 then
				gl.BindTexture('TEXTURE_2D_MULTISAMPLE', self[name]); gl.CheckError()
				gl.TexImage2DMultisample('TEXTURE_2D_MULTISAMPLE', self.samples, buffer.format, self.width, self.height, true); gl.CheckError()
			else
				gl.BindTexture('TEXTURE_2D', self[name]); gl.CheckError()
				local fmt = assert(texfmt[buffer.format], 'no texture format for '..buffer.format)
				gl.TexImage2D('TEXTURE_2D', 0, buffer.format, self.width, self.height, 0, fmt.f, fmt.t, nil); gl.CheckError()
				
				gl.TexParameterf('TEXTURE_2D', 'TEXTURE_MIN_FILTER', gl.LINEAR); gl.CheckError()
				if buffer.attachment=='DEPTH_ATTACHMENT' then
					gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_S', gl.CLAMP_TO_EDGE); gl.CheckError()
					gl.TexParameterf('TEXTURE_2D', 'TEXTURE_WRAP_T', gl.CLAMP_TO_EDGE); gl.CheckError()
					gl.TexParameterf('TEXTURE_2D', 'TEXTURE_COMPARE_MODE', gl.COMPARE_REF_TO_TEXTURE); gl.CheckError()
					gl.TexParameterf('TEXTURE_2D', 'TEXTURE_COMPARE_FUNC', gl.LESS); gl.CheckError()
				end
			end
		elseif buffer.type=='renderbuffer' then
			self[name] = gl.GenRenderbuffers(1)[1]; gl.CheckError()
			gl.BindRenderbuffer('RENDERBUFFER', self[name]); gl.CheckError()
			if self.samples > 1 then
				gl.RenderbufferStorageMultisample('RENDERBUFFER', self.samples, buffer.format, self.width, self.height); gl.CheckError()
			else
				gl.RenderbufferStorage('RENDERBUFFER', buffer.format, self.width, self.height); gl.CheckError()
			end
		end
	end
	
	--------------------------------------------------------------------------
	
	-- create the FBO
	self.fbo = gl.GenFramebuffers(1)[1]; gl.CheckError()
	gl.BindFramebuffer('FRAMEBUFFER', self.fbo); gl.CheckError()
	-- attach buffers
	for name,buffer in pairs(buffers) do
		if buffer.type=='texture' then
			if self.samples > 1 then
				gl.FramebufferTexture2D('FRAMEBUFFER', buffer.attachment, 'TEXTURE_2D_MULTISAMPLE', self[name], 0); gl.CheckError()
			else
				gl.FramebufferTexture2D('FRAMEBUFFER', buffer.attachment, 'TEXTURE_2D', self[name], 0); gl.CheckError()
			end
		elseif buffer.type=='renderbuffer' then
			gl.FramebufferRenderbuffer('FRAMEBUFFER', buffer.attachment, 'RENDERBUFFER', self[name]); gl.CheckError()
		end
	end
	
	--------------------------------------------------------------------------
	
	-- setup draw buffers
	local draw_buffers = {}
	local read_buffer = 'NONE'
	for _,buffer in pairs(buffers) do
		local attachment = buffer.attachment
		local i = attachment:match('^COLOR_ATTACHMENT(%d+)$')
		if i then
			draw_buffers[i+1] = attachment
			if buffer.read then
				read_buffer = attachment
			end
		end
	end
	gl.DrawBuffers(draw_buffers); gl.CheckError()
	gl.ReadBuffer(read_buffer); gl.CheckError()
	
	--------------------------------------------------------------------------
	
	-- check for completeness
	local status = gl.CheckFramebufferStatus('FRAMEBUFFER'); gl.CheckError()
	if status ~= gl.FRAMEBUFFER_COMPLETE then
		error("incomplete framebuffer ("..gl[status]..")")
	end
	
	--------------------------------------------------------------------------
	
	self.clear = {}
	for _,buffer in pairs(buffers) do
		local attachment = buffer.attachment
		local i = attachment:match('^COLOR_ATTACHMENT(%d+)$')
		if i then
			self.clear['color'..i] = {0,0,0,0}
		elseif attachment=='DEPTH_ATTACHMENT' then
			self.clear.depth = 1
		end
	end
	
	return setmetatable(self, mt)
end

function methods:updateFramebuffer(width, height)
	if width < 1 then width = 1 end
	if height < 1 then height = 1 end
	if width ~= self.width or height ~= self.height then
		self.width,self.height = width,height
		self.viewport[3] = self.width
		self.viewport[4] = self.height
		
		gl.BindFramebuffer('FRAMEBUFFER', self.fbo); gl.CheckError()
		for name,buffer in pairs(self.buffers) do
			if buffer.type=='texture' then
				if self.samples > 1 then
					gl.BindTexture('TEXTURE_2D_MULTISAMPLE', self[name]); gl.CheckError()
					gl.TexImage2DMultisample('TEXTURE_2D_MULTISAMPLE', self.samples, buffer.format, self.width, self.height, true); gl.CheckError()
					-- workaround for AMD bug
					if gl.GetTexLevelParameteriv('TEXTURE_2D_MULTISAMPLE', 0, 'TEXTURE_SAMPLES')[1] < self.samples then
						-- recreate the texture
						gl.DeleteTextures{self[name]}; gl.CheckError()
						self[name] = gl.GenTextures(1)[1]; gl.CheckError()
						gl.BindTexture('TEXTURE_2D_MULTISAMPLE', self[name]); gl.CheckError()
						gl.TexImage2DMultisample('TEXTURE_2D_MULTISAMPLE', self.samples, buffer.format, self.width, self.height, true); gl.CheckError()
						gl.FramebufferTexture2D('FRAMEBUFFER', buffer.attachment, 'TEXTURE_2D_MULTISAMPLE', self[name], 0); gl.CheckError()
					end
				else
					gl.BindTexture('TEXTURE_2D', self[name]); gl.CheckError()
					local fmt = assert(texfmt[buffer.format], 'no texture format for '..buffer.format)
					gl.TexImage2D('TEXTURE_2D', 0, buffer.format, self.width, self.height, 0, fmt.f, fmt.t, nil); gl.CheckError()
				end
			elseif buffer.type=='renderbuffer' then
				gl.BindRenderbuffer('RENDERBUFFER', self[name]); gl.CheckError()
				if self.samples > 1 then
					gl.RenderbufferStorageMultisample('RENDERBUFFER', self.samples, buffer.format, self.width, self.height); gl.CheckError()
				else
					gl.RenderbufferStorage('RENDERBUFFER', buffer.format, self.width, self.height); gl.CheckError()
				end
			end
		end
		local status = gl.CheckFramebufferStatus('FRAMEBUFFER'); gl.CheckError()
		if status ~= gl.FRAMEBUFFER_COMPLETE then
			error("incomplete framebuffer ("..gl[status]..")")
		end
		gl.BindFramebuffer('FRAMEBUFFER', 0); gl.CheckError()
	end
end

return _M
