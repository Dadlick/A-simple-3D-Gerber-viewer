local _M = {}
local _NAME = ...

local io = require 'io'
local image = require 'image'
local core = require(_NAME..".core")

function _M.read(filename, format)
	local file
	local png = assert(core.png_create_read_struct())
	local info = assert(core.png_create_info_struct(png))
	local endinfo,err = core.png_create_info_struct(png)
	if not endinfo then
		core.png_destroy_read_struct(png, info)
		assert(endinfo,err)
	end
	if type(filename)=='string' then
		file = assert(io.open(filename, "rb"))
	else
		file = filename
	end
	core.png_set_read_fn(png, function(...) return file:read(...) end)
	local transform = {
		'PNG_TRANSFORM_EXPAND',
	--	'PNG_TRANSFORM_STRIP_16',
	--	'PNG_TRANSFORM_PACKING',
	--	'PNG_TRANSFORM_SHIFT',
	}
	if format == 'bgr' then
		table.insert(transform, 'PNG_TRANSFORM_BGR')
	elseif format ~= nil then
		error("unsupported format "..tostring(format))
	end
	core.png_read_png(png, info, transform)
	
--	local width = core.png_get_image_width(png, info)
--	local height = core.png_get_image_height(png, info)
--	local channels = core.png_get_channels(png, info)
--	local bit_depth = png_get_bit_depth(png, info)
--	local color_type = png_get_color_type(png, info)
	
	local image = core.get_image(png, info, image.new)
--	core.png_read_end(png, endinfo)
	
	core.png_set_read_fn(png, nil)
	core.png_destroy_read_struct(png, info, endinfo)
	if type(filename)=='string' then
		file:close()
	end

	return image
end

function _M.write(filename, image)
	local file
	local png = assert(core.png_create_write_struct())
	local info,err = assert(core.png_create_info_struct(png))
	if not info then
		core.png_destroy_read_struct(png, nil)
		error(err)
	end
	if type(filename)=='string' then
		file = assert(io.open(filename, "wb"))
	else
		file = filename
	end
	core.png_set_write_fn(png, function(...) return file:write(...) end, function(...) return file:flush(...) end)
	
	local size = #image
	local width, height, bit_depth = size.width, size.height, size.bit_depth
	local color_type
	if size.channels==1 then
		color_type = 'PNG_COLOR_TYPE_GRAY'
	elseif size.channels==2 then
		color_type = 'PNG_COLOR_TYPE_GRAY_ALPHA'
	elseif size.channels==3 then
		color_type = 'PNG_COLOR_TYPE_RGB'
	elseif size.channels==4 then
		color_type = 'PNG_COLOR_TYPE_RGB_ALPHA'
	else
		error("only images with 1 to 4 components per pixel are supported")
	end
	local interlace_type, compression_type, filter_method = 'PNG_INTERLACE_NONE', 'PNG_COMPRESSION_TYPE_DEFAULT', 'PNG_FILTER_TYPE_DEFAULT'
	core.png_set_IHDR(png, info, width, height, bit_depth, color_type, interlace_type, compression_type, filter_method)
	
	core.png_set_compression_level(png, 6) -- in the range 0-9
	
	local rows = core.alloc_rows(image)
	core.png_set_rows(png, info, rows)
	
	core.png_write_png(png, info, {
		'PNG_TRANSFORM_IDENTITY',
	})
	
	core.png_set_write_fn(png, nil, nil)
	core.png_destroy_write_struct(png, info)
	if type(filename)=='string' then
		file:close()
	end

	return image
end

return _M
