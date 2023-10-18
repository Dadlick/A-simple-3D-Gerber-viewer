local _M = {}

local io = require 'io'
local math = require 'math'
local table = require 'table'
local string = require 'string'
local serial = require 'serial'
local image = require 'image'
local FT = require 'freetype'
local unicode = require 'unicode'
local gl = require 'gl'
local glo = require 'glo'

local scene = require('engine.scene').write
local scene_utils = require 'engine.scene.utils'

local image_get_value = image.get_value
local image_set_pixel = image.set_pixel
local image_get_pixel = image.get_pixel

local root = [[E:\Developpement\WoW\WoW_Interface_art]]
local nl = string.byte('\n')

--[[

A font is a texture, where characters are allocated. A 'glyph' object contains the coords of the glyph within the texture.

A text is an VBO, with a quad per glyph.

]]

serial.struct.vertex2 = {
	{'x',	'float', 'le'},
	{'y',	'float', 'le'},
}
serial.struct.glyph_element = {
	{'vertex', 'vertex2'},
	{'texcoord', 'vertex2'},
}

------------------------------------------------------------------------------

local ftfont_methods = {}
local ftfont_mt = {__index=ftfont_methods}

local function ftfont(name, height, stroke_radius)
	local self = setmetatable({
		name=name,
		height=height,
	}, ftfont_mt)
	self.library = assert(FT.Init_FreeType())
	self.face = assert(FT.Open_Face(self.library, {stream=assert(io.open(name, "rb"))}, 0))
--	self.face = assert(FT.New_Memory_Face(self.library, assert(assert(io.open(name, "rb")):read"*a"), 0))
	FT.Set_Char_Size(self.face, self.height, self.height, 96, 96)
	if stroke_radius then
		local stroker = assert(FT.Stroker_New(self.library))
		self.stroker = stroker
		-- BUTT, ROUND, SQUARE
		-- ROUND, BEVEL, MITER
		FT.Stroker_Set(stroker, stroke_radius, 'SQUARE', 'MITER', 1)
	end
	return self
end

local function glyph_to_bitmap(glyph_slot, glyph, newimage)
	local bitmap_glyph = assert(FT.Glyph_To_Bitmap(glyph, 'NORMAL', nil))
	local bitmap = bitmap_glyph.bitmap
	
	local glyphsize = {height=bitmap.rows, width=bitmap.width}
	local texturesize = {
		height = 2 ^ math.ceil(math.log(glyphsize.height) / math.log(2)),
		width = 2 ^ math.ceil(math.log(glyphsize.width) / math.log(2)),
	}

--	log.Begin("get_image")
	local image = assert(bitmap:get_image(newimage, {texturesize.height, texturesize.width}))
--	log.End()
	
	return image, {
		glyphsize = glyphsize,
		texturesize = texturesize,
		advance = glyph_slot.advance,
		left = bitmap_glyph.left,
		top = bitmap_glyph.top,
	}
end

function ftfont_methods:getglyph(char, newimage)
	local charcode = FT.Get_Char_Index(self.face, char)
	if not charcode then
		return nil,"character code "..char.." is not present in font "..self.name
	end
	
	assert(FT.Load_Glyph(self.face, charcode, {'DEFAULT', 'NO_HINTING', 'NO_AUTOHINT'}))
	
	local glyph_slot = self.face.glyph
	local glyph = assert(FT.Get_Glyph(glyph_slot))
	local stroker = self.stroker
	local outside,inside
	if stroker then
		outside = assert(FT.Glyph_StrokeBorder(glyph, stroker, false))
	--	inside = assert(FT.Glyph_StrokeBorder(glyph, stroker, true))
		inside = glyph
	else
		outside = glyph
		inside = nil
	end
	local oimage,oparams = glyph_to_bitmap(glyph_slot, outside, newimage)
	local iimage,iparams
	if inside then
		iimage,iparams = glyph_to_bitmap(glyph_slot, inside, newimage)
	end
	return oimage,oparams,iimage,iparams
end

function ftfont_methods:getkerning(leftchar, rightchar)
	local leftcharcode = FT.Get_Char_Index(self.face, leftchar)
	if not leftcharcode then
		return nil,"character code "..leftchar.." is not present in font "..self.name
	end
	local rightcharcode = FT.Get_Char_Index(self.face, rightchar)
	if not rightcharcode then
		return nil,"character code "..rightchar.." is not present in font "..self.name
	end
	return FT.Get_Kerning(self.face, leftcharcode, rightcharcode, 'DEFAULT')
end

------------------------------------------------------------------------------

local font = {}
local font_mt = {__index=font}

function _M.font(path, height, stroke_radius, shadow, absolute)
	local filename
	if absolute then
		filename = path
	else
		filename = root..'\\'..path
	end
	local self = {
		filename = filename,
		texture = glo.texture(),
		font = ftfont(filename, height, stroke_radius),
		tw = 512,
		th = 512,
		glyphs = {},
		row = 0,
		col = 0,
		row_height = 0,
		height = height,
	}
	if shadow and shadow.offset then
		self.shadow = {
			x = shadow.offset.x,
			y = -shadow.offset.y,
		}
		if shadow.color then
			self.shadow.r = shadow.color.r
			self.shadow.g = shadow.color.g
			self.shadow.b = shadow.color.b
			self.shadow.a = shadow.color.a or 1
		else
			self.shadow.r = 0
			self.shadow.g = 0
			self.shadow.b = 0
			self.shadow.a = 1
		end
	end
	gl.BindTexture('TEXTURE_2D', self.texture.name)
--	gl.TexParameteri('TEXTURE_2D', 'GENERATE_MIPMAP', true)
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MAG_FILTER', 'LINEAR')
	gl.TexParameteri('TEXTURE_2D', 'TEXTURE_MIN_FILTER', 'NEAREST')
	if stroke_radius then
		gl.TexParameterfv('TEXTURE_2D', 'TEXTURE_BORDER_COLOR', {0,0,0,0})
	else
		gl.TexParameterfv('TEXTURE_2D', 'TEXTURE_BORDER_COLOR', {1,1,1,0})
	end
--	local image = image.new(self.th, self.tw, 4, 8)
--	gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', (#image).width, (#image).height, 0, 'RGBA', 'UNSIGNED_BYTE', nil)
	gl.TexImage2D('TEXTURE_2D', 0, 'RGBA', self.tw, self.th, 0, 'RGBA', 'UNSIGNED_BYTE', nil)
	gl.BindTexture('TEXTURE_2D', 0)
	return setmetatable(self, font_mt)
end

function font:text(chars)
	return _M.text(self, chars)
end

function font:allocate_chars(chars)
	for char in pairs(chars) do
		self:allocate_char(char)
	end
end

function font:allocate_char(char)
	local oimg,oparm,iimg,iparm = self.font:getglyph(char, image.new)
	if not oimg then
		oimg,oparm,iimg,iparm = assert(self.font:getglyph(string.byte('?'), image.new))
	end
	
	-- make a copy of the outline, with the shadow color
	local simg
	if self.shadow then
		-- allocate a bigger image
		local olen = #oimg
		local oh,ow,oc = olen.height,olen.width,olen.channels
		simg = image.new(oh, ow, oc, olen.bit_depth)
		
		-- copy the shadow
		for y=1,oh do for x=1,ow do
			simg[{y, x, 1}] = self.shadow.r
			simg[{y, x, 2}] = self.shadow.g
			simg[{y, x, 3}] = self.shadow.b
			simg[{y, x, 4}] = self.shadow.a * oimg[{y, x, 4}]
		end end
	end
	
	-- copy the inline inside the outline, and make the outline black
	if iimg then
		local olen = #oimg
		local oh,ow,oc = olen.height,olen.width,olen.channels
		local ilen = #iimg
		local ih,iw,ic = ilen.height,ilen.width,ilen.channels
		-- write iimg over oimg
		for oy=1,oh do for ox=1,ow do
			local iy = oy - oparm.top + iparm.top
			local ix = ox + oparm.left - iparm.left
			local val
			if iy>=1 and iy<=ih and ix>=1 and ix<=iw then
				val = iimg[{iy, ix, 4}]
			--	val = image_get_value(iimg, iw, ic, iy, ix, 4)
			else
				val = 0
			end
			oimg[{oy, ox, 1}] = val
			oimg[{oy, ox, 2}] = val
			oimg[{oy, ox, 3}] = val
		--	image_set_pixel(oimg, ow, oc, oy, ox, val, val, val, image_get_value(oimg, ow, oc, oy, ox, 4))
		end end
	end
	
	-- finally blend the shadow and the font
	if self.shadow then
		local shadow = self.shadow
		-- allocate
		local olen = #oimg
		local oh,ow,oc = olen.height,olen.width,olen.channels
		local img = image.new(oh + math.abs(shadow.y), ow + math.abs(shadow.x), oc, olen.bit_depth)
		
		-- copy shadow
		local soffx = math.max(0, shadow.x)
		local soffy = math.max(0, shadow.y)
		for sy=1,oh do for sx=1,ow do
			local y = sy + soffy
			local x = sx + soffx
			for c=1,oc do
				img[{y, x, c}] = simg[{sy, sx, c}]
			end
		end end
		
		-- blend regular outlined glyph
		local ooffx = math.max(0, -shadow.x)
		local ooffy = math.max(0, -shadow.y)
		for oy=1,oh do for ox=1,ow do
			local y = oy + ooffy
			local x = ox + ooffx
			local a = oimg[{oy, ox, 4}] / 255
			local _a = 1 - a
			img[{y, x, 1}] = img[{y, x, 1}] * _a + oimg[{oy, ox, 1}] * a
			img[{y, x, 2}] = img[{y, x, 2}] * _a + oimg[{oy, ox, 2}] * a
			img[{y, x, 3}] = img[{y, x, 3}] * _a + oimg[{oy, ox, 3}] * a
			img[{y, x, 4}] = img[{y, x, 4}] * _a + 255 * a
		end end

		-- adjust params
		oimg = img
		oparm.glyphsize.width = oparm.glyphsize.width + math.abs(shadow.x)
		oparm.glyphsize.height = oparm.glyphsize.height + math.abs(shadow.y)
		oparm.top = oparm.top + math.max(0, shadow.y)
		oparm.left = oparm.left + math.min(0, -shadow.x)
	end
	
	local glyph = {}
	glyph.advance = { x = oparm.advance.x }
	local size = #oimg
	local w,h = oparm.glyphsize.width,oparm.glyphsize.height
	local ix,iy
	
	if self.col + w > self.tw then
		self.row = self.row + self.row_height + 1
		self.col = 0
		self.row_height = 0
	end
	self.row_height = math.max(h, self.row_height)
	
	local ix,iy = self.col,self.row
	local iw,ih = size.width,size.height
	scene_utils.tex_sub_image_2d(self.texture.name, 0, ix, iy, iw, ih, 'RGBA', 'UNSIGNED_BYTE', tostring(oimg))
	
	self.col = self.col + w + 1
	
	local x,y = oparm.left,oparm.top
	glyph.vertices = {
		{x=0+x, y=y-h},
		{x=w+x, y=y-h},
		{x=w+x, y=y-0},
		{x=0+x, y=y-0},
	}
	local tw,th = self.tw,self.th
	glyph.texcoords = {
		{x=(0+ix)/tw, y=(h+iy)/th},
		{x=(w+ix)/tw, y=(h+iy)/th},
		{x=(w+ix)/tw, y=(0+iy)/th},
		{x=(0+ix)/tw, y=(0+iy)/th},
	}
	self.glyphs[char] = glyph
end

------------------------------------------------------------------------------

local text = {}
local text_mt = {__index=text}

function _M.text(font, chars)
	-- allocate a text if possible
	local uiobject
	for i=1,#scene.uiobjects do
		if not scene.uiobjects[i].used then
			uiobject = scene.uiobjects[i]
			break
		end
	end
	if not uiobject then
		return nil,"too many uiobjects"
	end
	
	uiobject.used = true
	local mesh = uiobject.mesh
	mesh.texture = font.texture.name
	mesh.vbo = 0
	mesh.size = 0
	if not scene.refs then scene.refs = {} end
	scene.refs[font.texture] = true
	
	local text = {
		font = font,
		uiobject = uiobject,
		chars = {},
		buffer_size = 0,
		width = 0,
		bottom = 0,
		top = font.height,
	}
	return setmetatable(text, text_mt)
end

function text:destroy()
	self.uiobject.used = false
	self.uiobject = nil
	for k in pairs(self) do
		self[k] = nil
	end
end

function text:append(chars)
	if type(chars)=='string' then
		chars = unicode.convert(chars, 'utf-8', 'ucs-4', 'table')
	else
		assert(type(chars)=='table')
	end
	if not chars or #chars==0 then
		return
	end
	
	scene:lock()
	
	-- alloc chars if necessary
	local missing = {}
	for _,char in pairs(chars) do
		if not self.font.glyphs[char] then
			missing[char] = true
		end
	end
	if next(missing) then
		self.font:allocate_chars(missing)
	end
	
	if #self.chars + #chars > self.buffer_size then
		-- rebuild whole buffer
		for _,char in ipairs(chars) do
			table.insert(self.chars, char)
		end
		local data,width,bottom = self:build_elements(self.chars)
		local strdata = serial.serialize.array(data, '*', 'glyph_element')
		
		if not scene.refs then scene.refs = {} end
		if self.buffer then
			scene.refs[self.buffer] = nil
		end
		self.buffer = glo.buffer()
		scene.refs[self.buffer] = true
		
		self.buffer_size = #data / 4
		scene_utils.buffer_data(self.buffer.name, strdata)
		
		self.width,self.bottom = width,bottom
	else
		-- only serialize new characters
		local data,width,bottom = self:build_elements(chars, self.width, self.bottom)
		local strdata = serial.serialize.array(data, '*', 'glyph_element')
		
		scene_utils.buffer_sub_data(self.buffer.name, #self.chars * 4 * 16, strdata)
		
		self.width,self.bottom = width,bottom
		
		for _,char in ipairs(chars) do
			table.insert(self.chars, char)
		end
	end
	
	local mesh = self.uiobject.mesh
	mesh.vbo = self.buffer.name
	mesh.size = #self.chars * 4
	
	scene:unlock()
end

function text:chop(n)
	local chars = self.chars
	if n > #chars then
		n = #chars
	end
	if n >= 1 then
		scene:lock()
		for i=1,n do
			local char = chars[#chars]
			if char==nl then
				error("cannot chop newline")
			else
				local glyph = self.font.glyphs[char]
				chars[#chars] = nil
				self.width = self.width - math.ceil(glyph.advance.x)
			end
		end
		self.uiobject.mesh.size = #chars * 4
		scene:unlock()
	end
end

function text:settext(str)
	-- :NOTE: calling chop cause flicker
--	self:chop(#self.chars)
	-- :FIXME: not calling chop may cause visual bugs (if mesh buffer is read while written in append)
	-- :TODO: solution is to have double "vertex buffer"-ing
	self.width = 0
	self.uiobject.mesh.size = 0
	for i=#self.chars,1,-1 do
		self.chars[i] = nil
	end
	self:append(str)
end

function text:build_elements(chars, left, bottom)
	if not left then left = 0 end
	if not bottom then bottom = 0 end
	local data = {}
	for ichar,char in ipairs(chars) do
		if char==nl then
			bottom = bottom - self.font.height * 4 / 3
			left = 0
		else
			--[[
			if ichar > 1 and left > 0 then
				local kerning = self.font.font:getkerning(chars[ichar-1], char)
				if kerning.x~=0 or kerning.y~=0 then
					print(">", kerning.x, kerning.y, chars[ichar-1], char)
				end
			end
			--]]
			local glyph = self.font.glyphs[char]
			for i=1,4 do
				local vertex = glyph.vertices[i]
				local texcoord = glyph.texcoords[i]
				table.insert(data, {
					vertex = {
						x = vertex.x + left,
						y = vertex.y + bottom,
					},
					texcoord = texcoord,
				})
			end
			left = left + math.ceil(glyph.advance.x)
		end
	end
	if self.vertical then
		for _,element in ipairs(data) do
			element.vertex.x,element.vertex.y = -element.vertex.y,element.vertex.x
		end
	end
	return data,left,bottom
end

------------------------------------------------------------------------------

return _M
