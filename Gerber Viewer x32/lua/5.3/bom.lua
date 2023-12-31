local _M = {}

local io = require 'io'
local math = require 'math'
local table = require 'table'

local function rotate(v, angle)
	local a = math.rad(angle)
	local c = math.cos(a)
	local s = math.sin(a)
	return {
		x = v.x * c - v.y * s,
		y = v.x * s + v.y * c,
	}
end

function _M.load(file_path, template)
	local name = file_path.file
	local unit = nil
	local top = { polarity = 'top' }
	local bottom = { polarity = 'bottom' }
	local layers = { top, bottom }
	
	local file = assert(io.open(file_path, 'rb'))
	local data = {}
	for line in file:lines() do
		line = line:gsub('\r', '')
		local fields = {}
		for field in (line..'\t'):gmatch('([^\t]*)\t') do
			table.insert(fields, field)
		end
		table.insert(data, fields)
	end
	assert(file:close())
	
	local field_names = data[1]
	for i=2,#data do
		local array = data[i]
		local set = {}
		for i,field_name in ipairs(field_names) do
			set[field_name] = array[i]
		end
		local package = set[template.fields.package]
		local part = {}
		part.name = set[template.fields.name]
		local angle = set[template.fields.angle]
		if set[template.fields.angle_offset] and set[template.fields.angle_offset]~="" and set[template.fields.angle_offset]~="*" then
			angle = angle + set[template.fields.angle_offset]
		end
		part.angle = angle * template.scale.angle
		local offset = {x=0, y=0}
		if set[template.fields.x_offset] and set[template.fields.x_offset]~="" and set[template.fields.x_offset]~="*" then
			offset.x = tonumber(set[template.fields.x_offset])
		end
		if set[template.fields.y_offset] and set[template.fields.y_offset]~="" and set[template.fields.y_offset]~="*" then
			offset.y = tonumber(set[template.fields.y_offset])
		end
		offset = rotate(offset, angle)
		local x = set[template.fields.x] + offset.x
		local y = set[template.fields.y] + offset.y
		part.x = x * template.scale.length
		part.y = y * template.scale.length
		local side = set[template.fields.side]
		for _,field in pairs(template.fields) do
			set[field] = nil
		end
		local device = set
		device.package = package
		local layer
		if side=='top' then
			layer = top
		elseif side=='bottom' then
			layer = bottom
		else
			error("unexpected Side in BOM: "..tostring(side))
		end
		table.insert(layer, {
			aperture = {
				device = true,
				parameters = device,
			},
			part,
		})
	end
	
	local image = {
		file_path = file_path,
	--	name = image_name,
		format = field_names,
		unit = unit,
		layers = layers,
	}
	
	return image
end

function _M.save(image, file_path, template)
	local file = assert(io.open(file_path, 'wb'))
	local field_names = image.format
	assert(#image.layers==2)
	
	assert(file:write(table.concat(field_names, '\t')..'\r\n'))
	for _,layer in ipairs(image.layers) do
		for _,path in ipairs(layer) do
			assert(path.aperture and path.aperture.device)
			local device = path.aperture.parameters
			local part = path[1]
			local set = {}
			for k,v in pairs(device) do
				set[k] = v
			end
			set[template.fields.package] = device.package
			set[template.fields.name] = part.name
			set[template.fields.x] = part.x / template.scale.length
			set[template.fields.y] = part.y / template.scale.length
			set[template.fields.angle] = part.angle / template.scale.angle
			set[template.fields.side] = layer.polarity
			local array = {}
			for i,field_name in ipairs(field_names) do
				array[i] = set[field_name]
			end
			assert(file:write(table.concat(array, '\t')..'\r\n'))
		end
	end
	assert(file:close())
	return true
end

return _M
