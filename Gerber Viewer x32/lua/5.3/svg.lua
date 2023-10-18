local _M = {}

local xml = require 'xml'
local region = require 'boards.region'
local extents = require 'boards.extents'
local manipulation = require 'boards.manipulation'
local interpolationlib = require 'boards.interpolation'

local atan2 = math.atan2 or math.atan

local verbose_paths = false

------------------------------------------------------------------------------

-- all positions in picometers (1e-12 meters)
local scales = {
	['in'] = 25400000000,
	mm     =  1000000000,
}
for unit,scale in pairs(scales) do
	assert(math.floor(scale)==scale)
end

local margins = {
	['in'] = 12700000000,
	mm     = 10000000000,
}

------------------------------------------------------------------------------

local function load_style(str)
	local style = {}
	for pair in str:gmatch('[^;]+') do
		local name,value = pair:match('^([^:]*):(.*)$')
		assert(name and value, "malformed style '"..str.."'")
		style[name] = value
	end
	return style
end

local function style_polarity(style)
	if style.fill and style.fill ~= 'none' then
		if style.fill == '#000000' then
			return 'dark'
		elseif style.fill == '#ffffff' then
			return 'clear'
		else
			error("unsupported style fill color "..tostring(style.fill))
		end
	elseif style.stroke and style.stroke ~= 'none' then
		if style.stroke == '#000000' then
			return 'dark'
		elseif style.stroke == '#ffffff' then
			return 'clear'
		else
			error("unsupported style stroke color "..tostring(style.fill))
		end
	else
		error("cannot determine style polarity")
	end
end

local function load_path(str)
	local scale = 25.4e9 / 90 -- picometers per pixel
	local xscale = scale
	local yscale = -scale
	local path = {}
	for letter,params in str:gmatch('(%a)(%A*)') do
		if letter=='M' then
			assert(#path==0)
			local x,y = params:match('^([-0-9.]+)[^-0-9.]([-0-9.]+)$')
			assert(x and y)
			x,y = tonumber(x),tonumber(y)
			assert(x and y)
			x = x * xscale
			y = y * yscale
			table.insert(path, {x=x, y=y})
		elseif letter=='L' then
			local x,y = params:match('^([-0-9.]+)[^-0-9.]([-0-9.]+)$')
			assert(x and y)
			x,y = tonumber(x),tonumber(y)
			assert(x and y)
			x = x * xscale
			y = y * yscale
			table.insert(path, {x=x, y=y, interpolation='linear'})
		elseif letter=='A' then
			local rx,ry,angle,large,sweep,x,y = params:match('^([-0-9.]+)[^-0-9.]([-0-9.]+)[^-0-9.]([-0-9.]+)[^-0-9.]([-0-9.]+)[^-0-9.]([-0-9.]+)[^-0-9.]([-0-9.]+)[^-0-9.]([-0-9.]+)$')
			assert(rx and ry and angle and large and sweep and x and y)
			rx,ry,angle,large,sweep,x,y = tonumber(rx),tonumber(ry),tonumber(angle),tonumber(large),tonumber(sweep),tonumber(x),tonumber(y)
			rx = rx * scale
			ry = ry * scale
			x = x * xscale
			y = y * yscale
			assert(rx and ry and angle and large and sweep and x and y)
			large = large~=0
			sweep = sweep~=0
			-- :TODO: accept more cases
			assert(rx==ry and angle==0 and not sweep and not large)
			local x0,y0 = path[#path].x,path[#path].y
			local r = rx
			local dx = x - x0
			local dy = y - y0
			local dist = math.sqrt(dx ^ 2 + dy ^ 2)
			dx = dx / dist
			dy = dy / dist
			local sin = dist / r / 2
			assert(sin <= 1)
			local angle = math.asin(sin)
			assert(angle <= math.pi / 2)
			local cos = math.cos(angle)
			local cx = (x0+x)/2 - dy * r * cos
			local cy = (y0+y)/2 + dx * r * cos
			table.insert(path, {x=x, y=y, cx=cx, cy=cy, interpolation'circular', direction='counterclockwise', quadrant='single'})
		elseif letter=='Z' then
			local x0,y0 = path[1].x,path[1].y
			local x1,y1 = path[#path].x,path[#path].y
			if x1 ~= x0 or y1 ~= y0 then
				table.insert(path, {x=x0, y=y0, interpolation='linear'})
			end
		else
			error("unsupported path element "..letter)
		end
	end
	return path
end

local function style_aperture(style)
	if style.stroke == 'none' and style.fill and style.fill ~= 'none' then
		return nil -- no stroke, fill, is a region
	elseif style.fill == 'none' and style.stroke and style.stroke ~= 'none' then
		assert(style['stroke-linecap'] == 'round')
		assert(style['stroke-linejoin'] == 'round')
		assert(style['stroke-opacity'] == '1')
		local name
		if style['marker'] then
			name = style['marker']:match('^url%((.*)%)$')
			if name and name:match('^%d+$') then
				name = tonumber(name)
			end
		end
		local width = style['stroke-width']
		local d,unit
		if width=='0' then
			d = 0
			unit = 'mm'
		else
			d,unit = width:match('^([-0-9.e]+)(%a%a)$')
			assert(d and unit, tostring(width).." doesn't not contain a valid line width")
			d = assert(tonumber(d), d.." is not a number") * 1e9
			unit = unit:lower()
			assert(unit=='mm' or unit=='in')
		end
		return {name=name, shape='circle', parameters={d}, unit=unit}
	else
		error("unsupported style")
	end
end

function _M.load(file_path)
	local file = assert(io.open(file_path, 'rb'))
	local content = assert(file:read('*all'))
	assert(file:close())
	local layers = {}
	local data = assert(xml.collect(content))
	assert(data[1]=='<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n')
	local svg = data[2]
	assert(xml.label(svg)=='svg')
	for _,g in ipairs(svg) do
		assert(xml.label(g)=='g')
		local layer = {}
		if g.name then
			layer.name = g.name
		end
		for _,path in ipairs(g) do
			assert(xml.label(path)=='path')
			local style = load_style(path.style)
			if layer.polarity then
				assert(style_polarity(style)==layer.polarity)
			else
				layer.polarity = style_polarity(style)
			end
			local path2 = load_path(path.d)
			path2.aperture = style_aperture(style)
			table.insert(layer, path2)
		end
		table.insert(layers, layer)
	end
	return {
		file_path = file_path,
		name = svg.id,
		format = {},
		unit = 'PX',
		layers = layers,
	}
end

local function save_layers(layers, file, scale, xscale, yscale, color, indent)
	local epsilon = 1e7 -- default to 0.01mm for bezier to arcs
	for _,layer in ipairs(layers) do
		local color = color
		if layer.polarity=='clear' then
			color = '#ffffffff'
		end
		local opacity
		if color:match('^#%x%x%x%x%x%x%x%x$') then
			opacity = tonumber(color:sub(2, 3), 16) / 255
			if opacity == 1 then opacity = nil end
			color = '#'..color:sub(4)
		end
		assert(file:write(indent..'\t<g'))
		if layer.name then
			assert(file:write(' id="'..layer.name..'"'))
		end
		assert(file:write('>\n'))
		for _,path in ipairs(layer) do
			-- :FIXME: implement all interpolation types with native SVG primitives
			path = interpolationlib.interpolate_path(path, epsilon, {linear=true, circular=true})
			assert(file:write(indent..'\t\t<path\n'))
			if path.aperture then
				-- stroke
				assert(path.aperture.shape=='circle', "only circle apertures are supported")
				local d = assert(path.aperture.diameter, "circle apertures has no diameter")
				assert(not path.aperture.hole_width and not path.aperture.hole_height, "circle apertures with holes are not yet supported")
				local width
				if d ~= 0 then
					assert(path.aperture.unit == 'pm') -- :FIXME: find out if other units are allowed here
					width = (d / 1e9)..'mm'
				end
				assert(file:write(indent..'\t\t\tstyle="'))
				if path.aperture.name then
					assert(file:write('marker:url('..tostring(path.aperture.name)..');'))
				end
				-- :NOTE: as a special case we don't set the width of strokes with zero width, so the document style makes them visible
				assert(file:write('stroke:'..color..(opacity and ';opacity:'..opacity or '')..(width and ';stroke-width:'..width or '')..';stroke-linecap:round;stroke-linejoin:round"\n'))
			else
				-- fill
				assert(file:write(indent..'\t\t\tstyle="fill:'..color..(opacity and ';opacity:'..opacity or '')..'"\n'))
			end
			assert(file:write(indent..'\t\t\td="'))
			local prefix = ''
			if verbose_paths then
				prefix = '\n'..indent..'\t\t\t\t'
			end
			for i,point in ipairs(path) do
				if i==1 then
					assert(file:write(prefix..'M'..(point.x / xscale)..','..(point.y / yscale)..''))
				elseif point.interpolation=='linear' then
					if i==#path and point.x==path[1].x and point.y==path[1].y then
						assert(file:write(prefix..'Z'))
					else
						assert(file:write(prefix..'L'..(point.x / xscale)..','..(point.y / yscale)..''))
					end
				elseif point.interpolation=='circular' and point.quadrant=='single' then
					local x0,y0 = path[i-1].x,path[i-1].y
					local cx,cy = point.cx,point.cy
					local dx = x0 - cx
					local dy = y0 - cy
					local r = math.sqrt(dx ^ 2 + dy ^ 2)
					local large = false
					local sweep = point.direction=='clockwise'
					assert(file:write(prefix..'A'..(r / scale)..','..(r / scale)..' 0 '..(large and '1' or '0')..','..(sweep and '1' or '0')..' '..(point.x / xscale)..','..(point.y / yscale)..''))
					if i==#path and point.x==path[1].x and point.y==path[1].y then
						assert(file:write(prefix..'Z'))
					end
				elseif point.interpolation=='circular' and point.quadrant=='multi' then
					local x0,y0 = path[i-1].x,path[i-1].y
					local x1,y1 = point.x,point.y
					local cx,cy = point.cx,point.cy
					local dx0 = x0 - cx
					local dy0 = y0 - cy
					local dx1 = dx0 + x1 - x0
					local dy1 = dy0 + y1 - y0
					local a0 = atan2(dy0, dx0)
					local a1 = atan2(dy1, dx1)
					local da = a1 - a0
					local clockwise = point.direction=='clockwise'
					if clockwise then da = -da end
					if da <= 0 then da = da + 2 * math.pi end
					local r = math.sqrt(dx0 ^ 2 + dy0 ^ 2)
					local large = da >= math.pi
					local sweep = clockwise
					assert(file:write(prefix..'A'..(r / scale)..','..(r / scale)..' 0 '..(large and '1' or '0')..','..(sweep and '1' or '0')..' '..(x1 / xscale)..','..(y1 / yscale)..''))
					if i==#path and x1==path[1].x and y1==path[1].y then
						assert(file:write(prefix..'Z'))
					end
				else
					error("unsupported point interpolation "..tostring(point.interpolation)..(point.quadrant and " "..point.quadrant.." quadrant" or ""))
				end
			end
			prefix = prefix:sub(1, -2)
			assert(file:write(prefix..'"\n'))
			assert(file:write(indent..'\t\t/>\n'))
		end
		assert(file:write(indent..'\t</g>\n'))
	end
end

function _M.save(image, filepath)
	local unit = assert(image.unit, "image has no unit")
	local scale = assert(scales[unit], "unsupported image unit "..tostring(unit))
	
	local file = assert(io.open(filepath, 'wb'))
	
	local viewport = image.viewport
	if not viewport then
		local margin = margins[unit] or 0
		viewport = extents.compute_image_extents(image) * region{ left=-margin, right=margin, bottom=-margin, top=margin }
	end
	assert(file:write([[
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg
	xmlns="http://www.w3.org/2000/svg"
	version="1.1"
]]))
	assert(file:write('\twidth="'..(viewport.width / scale)..unit..'"\n'))
	assert(file:write('\theight="'..(viewport.height / scale)..unit..'"\n'))
	
	-- from now on use user units, which correspond to 1px, 1/96in, etc., for all values below that have a unit (values without a unit will be assumed to be in px)
	scale = 254e8 / 96
	local xscale = scale
	local yscale = -scale
	
	assert(file:write('\tviewBox="'..(viewport.left / xscale)..' '..(viewport.top / yscale)..' '..(viewport.width / scale)..' '..(viewport.height / scale)..'"\n'))
	if image.name then
		assert(file:write('\tid="'..image.name..'"\n'))
	end
	assert(file:write('\tstyle="fill:none;stroke:none;stroke-width=1px"\n'))
	assert(file:write([[
>
]]))
	
	save_layers(image.layers, file, scale, xscale, yscale, image.color or '#ff000000', '')
	
	assert(file:write([[
</svg>
]]))
	assert(file:close())
	return true
end

------------------------------------------------------------------------------

function _M.save_board(board, filepath)
	local image_units = {}
	for _,image in pairs(board.images) do
		image_units[image.unit] = true
	end
	local unit = next(image_units)
	assert(unit and next(image_units, unit) == nil, "board is using multiple units")
	
	local scale = assert(scales[unit], "unsupported image unit "..tostring(unit))
	
	local file = assert(io.open(filepath, 'wb'))
	
	local viewport = board.viewport
	if not viewport then
		local margin = margins[unit] or 0
		viewport = extents.compute_board_extents(board) * region{ left=-margin, right=margin, bottom=-margin, top=margin }
	end
	assert(file:write([[
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg
	xmlns="http://www.w3.org/2000/svg"
	version="1.1"
]]))
	assert(file:write('\twidth="'..(viewport.width / scale)..unit..'"\n'))
	assert(file:write('\theight="'..(viewport.height / scale)..unit..'"\n'))
	
	-- from now on use user units, which correspond to 1px, 1/96in, etc., for all values below that have a unit (values without a unit will be assumed to be in px)
	scale = 254e8 / 96
	local xscale = scale
	local yscale = -scale
	
	assert(file:write('\tviewBox="'..(viewport.left / xscale)..' '..(viewport.top / yscale)..' '..(viewport.width / scale)..' '..(viewport.height / scale)..'"\n'))
	if board.name then
		assert(file:write('\tid="'..board.name..'"\n'))
	end
	assert(file:write('\tstyle="fill:none;stroke:none;stroke-width=1px"\n'))
	assert(file:write([[
>
]]))
	
	local image_types = {}
	for type in pairs(board.images) do table.insert(image_types, type) end
	table.sort(image_types, function(a, b)
		local za,zb = board.images[a].z_order or 0,board.images[b].z_order or 0
		if za ~= zb then
			return za < zb
		else
			return a < b
		end
	end)
	
	for _,type in pairs(image_types) do
		local image = board.images[type]
		-- re-inject outline before saving
		if board.outline and board.outline.apertures[type] then
			image = manipulation.copy_image(image)
			local path = manipulation.copy_path(board.outline.path)
			path.aperture = board.outline.apertures[type]
			if #image.layers==0 or image.layers[#image.layers].polarity=='clear' then
				table.insert(image.layers, {polarity='dark'})
			end
			table.insert(image.layers[#image.layers], path)
		end
		assert(file:write('\t<g class="'..type..'"'))
		if image.name then
			assert(file:write(' id="'..image.name..'"'))
		end
		assert(file:write('>\n'))
		save_layers(image.layers, file, scale, xscale, yscale, image.color or '#ff000000', '\t')
		assert(file:write('\t</g>\n'))
	end
	
	assert(file:write([[
</svg>
]]))
	assert(file:close())
	return true
end

------------------------------------------------------------------------------

return _M

