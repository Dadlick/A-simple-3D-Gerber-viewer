local _M = {}

local io = require 'io'
local math = require 'math'
local table = require 'table'
local manipulation = require 'boards.manipulation'

local tinsert = table.insert
local tremove = table.remove
local atan2 = math.atan2 or math.atan

------------------------------------------------------------------------------

local function parse(group)
	local code,data = group.code,group.data
	if false then
	elseif 0 <= code and code <= 9 then
		-- String (with the introduction of extended symbol names in AutoCAD 2000, the 255-character limit has been increased to 2049 single-byte characters not including the newline at the end of the line)
		return data
	elseif 10 <= code and code <= 39 then
		-- Double precision 3D point value
		return tonumber(data)
	elseif 40 <= code and code <= 59 then
		-- Double-precision floating-point value
		return tonumber(data)
	elseif 60 <= code and code <= 79 then
		-- 16-bit integer value
		return tonumber(data)
	elseif 90 <= code and code <= 99 then
		-- 32-bit integer value
		return tonumber(data)
	elseif code == 100 then
		-- String (255-character maximum; less for Unicode strings)
		return data
	elseif code == 102 then
		-- String (255-character maximum; less for Unicode strings)
		error("group code "..code.." parsing not implemented")
	elseif code == 105 then
		-- String representing hexadecimal (hex) handle value
		return data
	elseif 110 <= code and code <= 119 then
		-- Double precision floating-point value
		error("group code "..code.." parsing not implemented")
	elseif 120 <= code and code <= 129 then
		-- Double precision floating-point value
		error("group code "..code.." parsing not implemented")
	elseif 130 <= code and code <= 139 then
		-- Double precision floating-point value
		error("group code "..code.." parsing not implemented")
	elseif 140 <= code and code <= 149 then
		-- Double precision scalar floating-point value
		return tonumber(data)
	elseif 160 <= code and code <= 169 then
		-- 64-bit integer value
		error("group code "..code.." parsing not implemented")
	elseif 170 <= code and code <= 179 then
		-- 16-bit integer value
		return tonumber(data)
	elseif 210 <= code and code <= 239 then
		-- Double-precision floating-point value
		error("group code "..code.." parsing not implemented")
	elseif 270 <= code and code <= 279 then
		-- 16-bit integer value
		return tonumber(data)
	elseif 280 <= code and code <= 289 then
		-- 16-bit integer value
		return tonumber(data)
	elseif 290 <= code and code <= 299 then
		-- Boolean flag value
		error("group code "..code.." parsing not implemented")
	elseif 300 <= code and code <= 309 then
		-- Arbitrary text string
		error("group code "..code.." parsing not implemented")
	elseif 310 <= code and code <= 319 then
		-- String representing hex value of binary chunk
		error("group code "..code.." parsing not implemented")
	elseif 320 <= code and code <= 329 then
		-- String representing hex handle value
		error("group code "..code.." parsing not implemented")
	elseif 330 <= code and code <= 369 then
		-- String representing hex object IDs
		return data
	elseif 370 <= code and code <= 379 then
		-- 16-bit integer value
		error("group code "..code.." parsing not implemented")
	elseif 380 <= code and code <= 389 then
		-- 16-bit integer value
		error("group code "..code.." parsing not implemented")
	elseif 390 <= code and code <= 399 then
		-- String representing hex handle value
		error("group code "..code.." parsing not implemented")
	elseif 400 <= code and code <= 409 then
		-- 16-bit integer value
		error("group code "..code.." parsing not implemented")
	elseif 410 <= code and code <= 419 then
		-- String
		error("group code "..code.." parsing not implemented")
	elseif 420 <= code and code <= 429 then
		-- 32-bit integer value
		error("group code "..code.." parsing not implemented")
	elseif 430 <= code and code <= 439 then
		-- String
		error("group code "..code.." parsing not implemented")
	elseif 440 <= code and code <= 449 then
		-- 32-bit integer value
		error("group code "..code.." parsing not implemented")
	elseif 450 <= code and code <= 459 then
		-- Long
		error("group code "..code.." parsing not implemented")
	elseif 460 <= code and code <= 469 then
		-- Double-precision floating-point value
		error("group code "..code.." parsing not implemented")
	elseif 470 <= code and code <= 479 then
		-- String
		error("group code "..code.." parsing not implemented")
	elseif 480 <= code and code <= 481 then
		-- String representing hex handle value
		error("group code "..code.." parsing not implemented")
	elseif code == 999 then
		-- Comment (string)
		error("group code "..code.." parsing not implemented")
	elseif 1000 <= code and code <= 1009 then
		-- String (same limits as indicated with 0-9 code range)
		error("group code "..code.." parsing not implemented")
	elseif 1010 <= code and code <= 1059 then
		-- Double-precision floating-point value
		error("group code "..code.." parsing not implemented")
	elseif 1060 <= code and code <= 1070 then
		-- 16-bit integer value
		error("group code "..code.." parsing not implemented")
	elseif code == 1071 then
		-- 32-bit integer value
		error("group code "..code.." parsing not implemented")
	else
		error("unsupported group code "..tostring(code))
	end
end

-- numbers are scaled by a factor of 10^8 to keep as many digits as possible in the integer part of lua numbers
-- also 1e-8 inches and 1e-8 millimeters are both an integer number of picometers
local decimal_shift = 0
_M.decimal_shift = decimal_shift

local function save_number(n, format)
	local sign
	if n < 0 then
		sign = '-'
		n = -n
	else
		sign = ''
	end
	n = n / 10 ^ (decimal_shift - format.decimal)
	local ni = math.floor(n + 0.5)
--	assert(math.abs(n - ni) < 1e-8, "rounding error")
	local d = ni % 10 ^ format.decimal
	local i = (ni - d) / 10 ^ format.decimal
	assert(i < 10 ^ format.integer, "number is too big for format")
	n = string.format('%0'..format.integer..'d.%0'..format.decimal..'d', i, d)
	assert(#n == format.integer + 1 + format.decimal)
	n = n:gsub('^0*', '') -- remove leading zeroes
	n = n:gsub('^%.', '0.') -- :FIXME: find out if we need a leading zero for decimal-only numbers
	n = n:gsub('0*$', '') -- remove trailing zeroes
	n = n:gsub('%.$', '.0') -- :FIXME: find out if we need a trailing zero for integer-only numbers
	return sign..n
end

local function groupcode_default(code, value)
	local data
	if false then
	elseif 0 <= code and code <= 9 then
		-- String (with the introduction of extended symbol names in AutoCAD 2000, the 255-character limit has been increased to 2049 single-byte characters not including the newline at the end of the line)
		assert(#value <= 2049)
		data = value
	elseif 10 <= code and code <= 39 then
		-- Double precision 3D point value
		data = save_number(value, _M.format)
		assert((value == 0 or math.abs(tonumber(data) - value) < 10^-_M.format.decimal) and data:match('^[-%d.]+$'))
	elseif 40 <= code and code <= 59 then
		-- Double-precision floating-point value
		data = save_number(value, _M.format)
		assert((value == 0 or math.abs(tonumber(data) - value) < 10^-_M.format.decimal) and data:match('^[-%d.]+$'))
	elseif 60 <= code and code <= 79 then
		-- 16-bit integer value
		data = string.format("%d", value)
		assert(tonumber(data) == value and data:match('^%s*[%d]+$'))
	elseif 90 <= code and code <= 99 then
		-- 32-bit integer value
		data = string.format("%d", value)
		assert(tonumber(data) == value and data:match('^[%d]+$'))
	elseif code == 100 then
		-- String (255-character maximum; less for Unicode strings)
		assert(#value <= 255)
		data = value
	elseif code == 102 then
		-- String (255-character maximum; less for Unicode strings)
		error("group code "..code.." unparsing not implemented")
	elseif code == 105 then
		-- String representing hexadecimal (hex) handle value
		assert(value:match('^%x+$'))
		data = value
	elseif 110 <= code and code <= 119 then
		-- Double precision floating-point value
		error("group code "..code.." unparsing not implemented")
	elseif 120 <= code and code <= 129 then
		-- Double precision floating-point value
		error("group code "..code.." unparsing not implemented")
	elseif 130 <= code and code <= 139 then
		-- Double precision floating-point value
		error("group code "..code.." unparsing not implemented")
	elseif 140 <= code and code <= 149 then
		-- Double precision scalar floating-point value
		data = save_number(value, _M.format)
		assert((value == 0 or math.abs(tonumber(data) - value) < 10^-_M.format.decimal) and data:match('^[-%d.]+$'))
	elseif 160 <= code and code <= 169 then
		-- 64-bit integer value
		error("group code "..code.." unparsing not implemented")
	elseif 170 <= code and code <= 179 then
		-- 16-bit integer value
		data = string.format("%d", value)
		assert(tonumber(data) == value and data:match('^[%d]+$'))
	elseif 210 <= code and code <= 239 then
		-- Double-precision floating-point value
		error("group code "..code.." unparsing not implemented")
	elseif 270 <= code and code <= 279 then
		-- 16-bit integer value
		data = string.format("%d", value)
		assert(tonumber(data) == value and data:match('^[%d]+$'))
	elseif 280 <= code and code <= 289 then
		-- 16-bit integer value
		data = string.format("%d", value)
		assert(tonumber(data) == value and data:match('^[%d]+$'))
	elseif 290 <= code and code <= 299 then
		-- Boolean flag value
		error("group code "..code.." unparsing not implemented")
	elseif 300 <= code and code <= 309 then
		-- Arbitrary text string
		error("group code "..code.." unparsing not implemented")
	elseif 310 <= code and code <= 319 then
		-- String representing hex value of binary chunk
		error("group code "..code.." unparsing not implemented")
	elseif 320 <= code and code <= 329 then
		-- String representing hex handle value
		error("group code "..code.." unparsing not implemented")
	elseif 330 <= code and code <= 369 then
		-- String representing hex object IDs
		assert(value:match('^%x+$'))
		data = value
	elseif 370 <= code and code <= 379 then
		-- 16-bit integer value
		data = string.format("%d", value)
		assert(tonumber(data) == value and data:match('^[%d]+$'))
	elseif 380 <= code and code <= 389 then
		-- 16-bit integer value
		error("group code "..code.." unparsing not implemented")
	elseif 390 <= code and code <= 399 then
		-- String representing hex handle value
		error("group code "..code.." unparsing not implemented")
	elseif 400 <= code and code <= 409 then
		-- 16-bit integer value
		error("group code "..code.." unparsing not implemented")
	elseif 410 <= code and code <= 419 then
		-- String
		error("group code "..code.." unparsing not implemented")
	elseif 420 <= code and code <= 429 then
		-- 32-bit integer value
		error("group code "..code.." unparsing not implemented")
	elseif 430 <= code and code <= 439 then
		-- String
		error("group code "..code.." unparsing not implemented")
	elseif 440 <= code and code <= 449 then
		-- 32-bit integer value
		error("group code "..code.." unparsing not implemented")
	elseif 450 <= code and code <= 459 then
		-- Long
		error("group code "..code.." unparsing not implemented")
	elseif 460 <= code and code <= 469 then
		-- Double-precision floating-point value
		error("group code "..code.." unparsing not implemented")
	elseif 470 <= code and code <= 479 then
		-- String
		error("group code "..code.." unparsing not implemented")
	elseif 480 <= code and code <= 481 then
		-- String representing hex handle value
		error("group code "..code.." unparsing not implemented")
	elseif code == 999 then
		-- Comment (string)
		error("group code "..code.." unparsing not implemented")
	elseif 1000 <= code and code <= 1009 then
		-- String (same limits as indicated with 0-9 code range)
		error("group code "..code.." unparsing not implemented")
	elseif 1010 <= code and code <= 1059 then
		-- Double-precision floating-point value
		error("group code "..code.." unparsing not implemented")
	elseif 1060 <= code and code <= 1070 then
		-- 16-bit integer value
		error("group code "..code.." unparsing not implemented")
	elseif code == 1071 then
		-- 32-bit integer value
		error("group code "..code.." unparsing not implemented")
	else
		error("unsupported group code "..tostring(code))
	end
	return {code=code, data=data}
end

local function groupcode_inkscape(code, value)
	local data
	if false then
	elseif code == 30 and value == 0 then
		data = "0.0"
	elseif 0 <= code and code <= 9 then
		-- String (with the introduction of extended symbol names in AutoCAD 2000, the 255-character limit has been increased to 2049 single-byte characters not including the newline at the end of the line)
		assert(#value <= 2049)
		data = value
	elseif 10 <= code and code <= 39 then -- Double precision 3D point value
		data = string.format("%.6f", value)
		assert((value == 0 or math.abs(tonumber(data) / value - 1) < 1e-9) and data:match('^[-%d.]+$'))
	elseif 40 <= code and code <= 59 then -- Double-precision floating-point value
		data = string.format('%f', value)
		assert((value == 0 or math.abs(tonumber(data) / value - 1) < 1e-9) and data:match('^[-%d.]+$'))
	elseif 60 <= code and code <= 79 then -- 16-bit integer value
		data = string.format('%d', value)
		assert(tonumber(data) == value and data:match('^%s*[%d]+$'))
	elseif 90 <= code and code <= 99 then -- 32-bit integer value
		data = string.format("%d", value)
		assert(tonumber(data) == value and data:match('^[%d]+$'))
	elseif code == 100 then -- String (255-character maximum; less for Unicode strings)
		assert(#value <= 255)
		data = value
	elseif code == 105 then -- String representing hexadecimal (hex) handle value
		assert(value:match('^%x+$'))
		data = value
	elseif 140 <= code and code <= 149 then -- Double precision scalar floating-point value
		data = save_number(value, _M.format)
		assert((value == 0 or math.abs(tonumber(data) - value) < 10^-_M.format.decimal) and data:match('^[-%d.]+$'))
	elseif 170 <= code and code <= 179 then -- 16-bit integer value
		data = string.format('%6d', value)
		assert(tonumber(data) == value and data:match('^%s*[%d]+$'))
	elseif 270 <= code and code <= 279 then -- 16-bit integer value
		data = string.format('%6d', value)
		assert(tonumber(data) == value and data:match('^%s*[%d]+$'))
	elseif 280 <= code and code <= 289 then -- 16-bit integer value
		data = string.format('%6d', value)
		assert(tonumber(data) == value and data:match('^%s*[%d]+$'))
	elseif 330 <= code and code <= 369 then -- String representing hex object IDs
		assert(value:match('^%x+$'))
		data = value
	end
	return {code=code, data=data}
end

local function groupcode(...)
	if _M.format.dxf == 'inkscape' then
		return groupcode_inkscape(...)
	else
		return groupcode_default(...)
	end
end

------------------------------------------------------------------------------

local load_subclass = {}
local save_subclass = {}

local function load_subclass_generic(groupcodes)
	local subclass = {}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 5 then
			subclass.handle = group.value
		elseif code == 330 then
			subclass.owner = group.value
		else
			local value = group.value
			table.insert(subclass, {code=code, value=value})
		end
	end
	return subclass
end

local function save_subclass_generic(subclass)
	local groupcodes = {}
	if subclass.handle then
		table.insert(groupcodes, groupcode(5, subclass.handle))
	end
	if subclass.owner then
		table.insert(groupcodes, groupcode(330, subclass.owner))
	end
	for _,group in ipairs(subclass) do
		table.insert(groupcodes, groupcode(group.code, group.value))
	end
	return groupcodes
end

local function number_to_bitset(n)
	assert(n == math.floor(n) and n >= 0)
	local t = {}
	local i = 0
	while n ~= 0 do
		if n % 2 == 1 then
			n = n - 1
			t[i] = true
		end
		i = i + 1
		n = n / 2
	end
	return t
end

local function bitset_to_number(t)
	local n = 0
	for k,v in pairs(t) do
		assert(v==true)
		n = n + 2 ^ k
	end
	return n
end

function load_subclass.AcDbPolyline(groupcodes)
	local subclass = {}
	local vertex_count,flags
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 90 then
			vertex_count = group.value
		elseif code == 70 then
			flags = group.value
		elseif code == 10 or code == 20 or code == 30 then
			-- treated below
		else
			error("unsupported code "..tostring(code).." in AcDbPolyline")
		end
	end
	local vertices = {}
	for i=1,vertex_count do vertices[i] = {} end
	local lastx,lasty,lastz = 0,0,0
	for _,group in ipairs(groupcodes) do
		if group.code == 10 then
			lastx = lastx + 1
			vertices[lastx].x = group.value
		elseif group.code == 20 then
			lasty = lasty + 1
			vertices[lasty].y = group.value
		elseif group.code == 30 then
			lastz = lastz + 1
			vertices[lastz].z = group.value
		end
	end
	for i=1,vertex_count do
		local vertex = vertices[i]
		assert(vertex.x and vertex.y and vertex.z)
	end
	subclass.vertices = vertices
	flags = number_to_bitset(flags)
	for bit,v in pairs(flags) do
		assert(v==true)
		if bit == 0 then
			subclass.closed = true
		elseif bit == 7 then
			subclass.plinegen = true
		else
			error("unsupported flag bit "..tonumber(bit).." is set")
		end
	end
	return subclass
end

function save_subclass.AcDbPolyline(subclass)
	local vertex_count = #subclass.vertices
	local flags = {}
	if subclass.closed then
		flags[0] = true
	elseif subclass.plinegen then
		flags[7] = true
	end
	flags = bitset_to_number(flags)
	local groupcodes = {}
	table.insert(groupcodes, groupcode(90, vertex_count))
	table.insert(groupcodes, groupcode(70, flags))
	for i=1,vertex_count do
		local vertex = subclass.vertices[i]
		table.insert(groupcodes, groupcode(10, vertex.x))
		table.insert(groupcodes, groupcode(20, vertex.y))
		if vertex.z then
			table.insert(groupcodes, groupcode(30, vertex.z))
		end
	end
	return groupcodes
end

function load_subclass.AcDbLine(groupcodes)
	local subclass = {}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 39 then
			subclass.thickness = group.value
		elseif code == 10 then
			subclass.start_point = subclass.start_point or {}
			subclass.start_point.x = group.value
		elseif code == 20 then
			subclass.start_point = subclass.start_point or {}
			subclass.start_point.y = group.value
		elseif code == 30 then
			subclass.start_point = subclass.start_point or {}
			subclass.start_point.z = group.value
		elseif code == 11 then
			subclass.end_point = subclass.end_point or {}
			subclass.end_point.x = group.value
		elseif code == 21 then
			subclass.end_point = subclass.end_point or {}
			subclass.end_point.y = group.value
		elseif code == 31 then
			subclass.end_point = subclass.end_point or {}
			subclass.end_point.z = group.value
		elseif code == 210 then
			subclass.extrusion_direction = subclass.extrusion_direction or {}
			subclass.extrusion_direction.x = group.value
		elseif code == 220 then
			subclass.extrusion_direction = subclass.extrusion_direction or {}
			subclass.extrusion_direction.y = group.value
		elseif code == 230 then
			subclass.extrusion_direction = subclass.extrusion_direction or {}
			subclass.extrusion_direction.z = group.value
		elseif code == 8 then
			-- ignore
		else
			error("unsupported code "..tostring(code).." in AcDbLine")
		end
	end
	return subclass
end

function save_subclass.AcDbLine(subclass)
	local groupcodes = {}
	if subclass.thickness ~= nil then
		table.insert(groupcodes, groupcode(39, subclass.thickness))
	end
	if subclass.start_point ~= nil then
		if subclass.start_point.x ~= nil then
			table.insert(groupcodes, groupcode(10, subclass.start_point.x))
		end
		if subclass.start_point.y ~= nil then
			table.insert(groupcodes, groupcode(20, subclass.start_point.y))
		end
		if subclass.start_point.z ~= nil then
			table.insert(groupcodes, groupcode(30, subclass.start_point.z))
		end
	end
	if subclass.end_point ~= nil then
		if subclass.end_point.x ~= nil then
			table.insert(groupcodes, groupcode(11, subclass.end_point.x))
		end
		if subclass.end_point.y ~= nil then
			table.insert(groupcodes, groupcode(21, subclass.end_point.y))
		end
		if subclass.end_point.z ~= nil then
			table.insert(groupcodes, groupcode(31, subclass.end_point.z))
		end
	end
	if subclass.extrusion_direction ~= nil then
		if subclass.extrusion_direction.x ~= nil then
			table.insert(groupcodes, groupcode(210, subclass.extrusion_direction.x))
		end
		if subclass.extrusion_direction.y ~= nil then
			table.insert(groupcodes, groupcode(220, subclass.extrusion_direction.y))
		end
		if subclass.extrusion_direction.z ~= nil then
			table.insert(groupcodes, groupcode(230, subclass.extrusion_direction.z))
		end
	end
	return groupcodes
end

function load_subclass.AcDbCircle(groupcodes)
	local subclass = {}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 39 then
			subclass.thickness = group.value
		elseif code == 10 then
			subclass.center = subclass.center or {}
			subclass.center.x = group.value
		elseif code == 20 then
			subclass.center = subclass.center or {}
			subclass.center.y = group.value
		elseif code == 30 then
			subclass.center = subclass.center or {}
			subclass.center.z = group.value
		elseif code == 40 then
			subclass.radius = group.value
		else
			error("unsupported code "..tostring(code).." in AcDbCircle")
		end
	end
	return subclass
end

function save_subclass.AcDbCircle(subclass)
	local groupcodes = {}
	if subclass.thickness ~= nil then
		table.insert(groupcodes, groupcode(39, subclass.thickness))
	end
	if subclass.center ~= nil then
		if subclass.center.x ~= nil then
			table.insert(groupcodes, groupcode(10, subclass.center.x))
		end
		if subclass.center.y ~= nil then
			table.insert(groupcodes, groupcode(20, subclass.center.y))
		end
		if subclass.center.z ~= nil then
			table.insert(groupcodes, groupcode(30, subclass.center.z))
		end
	end
	if subclass.radius ~= nil then
		table.insert(groupcodes, groupcode(40, subclass.radius))
	end
	return groupcodes
end

function load_subclass.AcDbArc(groupcodes)
	local subclass = {}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 50 then
			subclass.start_angle = group.value
		elseif code == 51 then
			subclass.end_angle = group.value
		else
			error("unsupported code "..tostring(code).." in AcDbArc")
		end
	end
	return subclass
end

function save_subclass.AcDbArc(subclass)
	local groupcodes = {}
	if subclass.start_angle ~= nil then
		table.insert(groupcodes, groupcode(50, subclass.start_angle))
	end
	if subclass.end_angle ~= nil then
		table.insert(groupcodes, groupcode(51, subclass.end_angle))
	end
	return groupcodes
end

function load_subclass.AcDbSpline(groupcodes)
	local subclass = {}
	local flags,degree,knot_count,control_point_count,fit_point_count
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 70 then
			flags = group.value
		elseif code == 71 then
			degree = group.value
		elseif code == 72 then
			knot_count = group.value
		elseif code == 73 then
			control_point_count = group.value
		elseif code == 74 then
			fit_point_count = group.value
		elseif code == 10 or code == 20 or code == 30 or code == 40 then
			-- treated below
		else
			error("unsupported code "..tostring(code).." in AcDbSpline")
		end
	end
	flags = number_to_bitset(flags)
	for bit,v in pairs(flags) do
		assert(v==true)
		if bit == 0 then
			subclass.closed = true
		elseif bit == 1 then
			subclass.periodic = true
		elseif bit == 2 then
			subclass.rational = true
		elseif bit == 3 then
			subclass.planar = true
		elseif bit == 4 then
			subclass.linear = true
		else
			error("unsupported flag bit "..tonumber(bit).." is set")
		end
	end
	subclass.degree = degree
	local control_points = {}
	local knots = {}
	for i=1,control_point_count do control_points[i] = {} end
	local lastx,lasty,lastz,lastk = 0,0,0,0
	for _,group in ipairs(groupcodes) do
		if group.code == 10 then
			lastx = lastx + 1
			control_points[lastx].x = group.value
		elseif group.code == 20 then
			lasty = lasty + 1
			control_points[lasty].y = group.value
		elseif group.code == 30 then
			lastz = lastz + 1
			control_points[lastz].z = group.value
		elseif group.code == 40 then
			lastk = lastk + 1
			knots[lastk] = group.value
		end
	end
	for i=1,control_point_count do
		local control_point = control_points[i]
		assert(control_point.x and control_point.y and control_point.z)
	end
	subclass.control_points = control_points
	for i=1,knot_count do
		assert(knots[i])
	end
	subclass.knots = knots
	return subclass
end

function save_subclass.AcDbSpline(subclass)
	local knot_count = #subclass.knots
	local control_point_count = #subclass.control_points
	local fit_point_count = 0
	local flags = {}
	if subclass.closed then
		flags[0] = true
	elseif subclass.periodic then
		flags[1] = true
	elseif subclass.rational then
		flags[2] = true
	elseif subclass.planar then
		flags[3] = true
	elseif subclass.linear then
		flags[4] = true
	end
	flags = bitset_to_number(flags)
	local groupcodes = {}
	table.insert(groupcodes, groupcode(70, flags))
	table.insert(groupcodes, groupcode(71, subclass.degree))
	table.insert(groupcodes, groupcode(72, knot_count))
	table.insert(groupcodes, groupcode(73, control_point_count))
	table.insert(groupcodes, groupcode(74, fit_point_count))
	for i=1,knot_count do
		local knot = subclass.knots[i]
		table.insert(groupcodes, groupcode(40, knot))
	end
	for i=1,control_point_count do
		local control_point = subclass.control_points[i]
		table.insert(groupcodes, groupcode(10, control_point.x))
		table.insert(groupcodes, groupcode(20, control_point.y))
		table.insert(groupcodes, groupcode(30, control_point.z or 0))
	end
	return groupcodes
end

function load_subclass.AcDbDictionary(groupcodes)
	local keys = {}
	local values = {}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 3 then
			table.insert(keys, group.value)
		elseif code == 350 then
			table.insert(values, group.value)
		else
			error("unsupported code "..tostring(code).." in AcDbDictionary")
		end
	end
	assert(#keys == #values, "number of keys and values don't match in AcDbDictionary")
	local subclass = {type='AcDbDictionary'}
	for i=1,#keys do
		table.insert(subclass, {key=keys[i], value=values[i]})
	end
	return subclass
end

function save_subclass.AcDbDictionary(subclass)
	local groupcodes = {}
	for _,pair in ipairs(subclass) do
		table.insert(groupcodes, groupcode(3, pair.key))
		table.insert(groupcodes, groupcode(350, pair.value))
	end
	return groupcodes
end

function load_subclass.AcDbTextStyleTableRecord(groupcodes)
	local subclass = {type='AcDbTextStyleTableRecord'}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 2 then
			subclass.name = group.value
		elseif code == 70 then
			subclass.flags = group.value
		elseif code == 40 then
			subclass.text_height = group.value
		elseif code == 41 then
			subclass.width_factor = group.value
		elseif code == 50 then
			subclass.oblique_angle = group.value
		elseif code == 71 then
			subclass.generation_flags = group.value
		elseif code == 42 then
			subclass.last_height_used = group.value
		elseif code == 3 then
			subclass.primary_font_filename = group.value
		elseif code == 4 then
			subclass.big_font_filename = group.value
		else
			error("unsupported code "..tostring(code).." in AcDbTextStyleTableRecord")
		end
	end
	return subclass
end

function save_subclass.AcDbTextStyleTableRecord(subclass)
	local groupcodes = {}
	if subclass.name then
		table.insert(groupcodes, groupcode(2, subclass.name))
	end
	if subclass.flags then
		table.insert(groupcodes, groupcode(70, subclass.flags))
	end
	if subclass.text_height then
		table.insert(groupcodes, groupcode(40, subclass.text_height))
	end
	if subclass.width_factor then
		table.insert(groupcodes, groupcode(41, subclass.width_factor))
	end
	if subclass.oblique_angle then
		table.insert(groupcodes, groupcode(50, subclass.oblique_angle))
	end
	if subclass.generation_flags then
		table.insert(groupcodes, groupcode(71, subclass.generation_flags))
	end
	if subclass.last_height_used then
		table.insert(groupcodes, groupcode(42, subclass.last_height_used))
	end
	if subclass.primary_font_filename then
		table.insert(groupcodes, groupcode(3, subclass.primary_font_filename))
	end
	if subclass.big_font_filename then
		table.insert(groupcodes, groupcode(4, subclass.big_font_filename))
	end
	return groupcodes
end

function load_subclass.AcDbViewportTableRecord(groupcodes)
	local subclass = {type='AcDbViewportTableRecord'}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 2 then
			subclass.name = group.value
		elseif code == 70 then
			subclass.flags = group.value
		elseif code == 10 then
			subclass.extents = subclass.extents or {}
			subclass.extents.left = group.value
		elseif code == 20 then
			subclass.extents = subclass.extents or {}
			subclass.extents.bottom = group.value
		elseif code == 11 then
			subclass.extents = subclass.extents or {}
			subclass.extents.right = group.value
		elseif code == 21 then
			subclass.extents = subclass.extents or {}
			subclass.extents.top = group.value
		elseif code == 12 then
			subclass.center = subclass.center or {}
			subclass.center.x = group.value
		elseif code == 22 then
			subclass.center = subclass.center or {}
			subclass.center.y = group.value
		elseif code == 13 then
			subclass.snap_base_point = subclass.snap_base_point or {}
			subclass.snap_base_point.x = group.value
		elseif code == 23 then
			subclass.snap_base_point = subclass.snap_base_point or {}
			subclass.snap_base_point.y = group.value
		elseif code == 14 then
			subclass.snap_spacing = subclass.snap_spacing or {}
			subclass.snap_spacing.x = group.value
		elseif code == 24 then
			subclass.snap_spacing = subclass.snap_spacing or {}
			subclass.snap_spacing.y = group.value
		elseif code == 15 then
			subclass.grid_spacing = subclass.grid_spacing or {}
			subclass.grid_spacing.x = group.value
		elseif code == 25 then
			subclass.grid_spacing = subclass.grid_spacing or {}
			subclass.grid_spacing.y = group.value
		elseif code == 16 then
			subclass.view_direction = subclass.view_direction or {}
			subclass.view_direction.x = group.value
		elseif code == 26 then
			subclass.view_direction = subclass.view_direction or {}
			subclass.view_direction.y = group.value
		elseif code == 36 then
			subclass.view_direction = subclass.view_direction or {}
			subclass.view_direction.z = group.value
		elseif code == 17 then
			subclass.view_target_point = subclass.view_target_point or {}
			subclass.view_target_point.x = group.value
		elseif code == 27 then
			subclass.view_target_point = subclass.view_target_point or {}
			subclass.view_target_point.y = group.value
		elseif code == 37 then
			subclass.view_target_point = subclass.view_target_point or {}
			subclass.view_target_point.z = group.value
		elseif code == 40 then
			subclass.view_height = group.value
		elseif code == 41 then
			subclass.viewport_aspect_ratio = group.value
		elseif code == 42 then
			subclass.lens_length = group.value
		elseif code == 43 then
			subclass.front_clipping_plane = group.value
		elseif code == 44 then
			subclass.back_clipping_plane = group.value
		elseif code == 50 then
			subclass.snap_rotation_angle = group.value
		elseif code == 51 then
			subclass.view_twist_angle = group.value
		elseif code == 71 then
			subclass.view_mode = group.value
		elseif code == 72 then
			subclass.circle_zoom_percent = group.value
		elseif code == 73 then
			subclass.fast_zoom_setting = group.value
		elseif code == 74 then
			subclass.ucsicon_setting = group.value
		elseif code == 75 then
			subclass.snap_on = group.value ~= 0
		elseif code == 76 then
			subclass.grid_on = group.value ~= 0
		elseif code == 77 then
			subclass.snap_style = group.value
		elseif code == 78 then
			subclass.snap_isopair = group.value
		elseif code == 281 then
			subclass.render_mode = group.value
		elseif code == 65 then
			subclass.ucsvp = group.value
		elseif code == 110 then
			subclass.ucs_origin = subclass.ucs_origin or {}
			subclass.ucs_origin.x = group.value
		elseif code == 120 then
			subclass.ucs_origin = subclass.ucs_origin or {}
			subclass.ucs_origin.y = group.value
		elseif code == 130 then
			subclass.ucs_origin = subclass.ucs_origin or {}
			subclass.ucs_origin.z = group.value
		elseif code == 111 then
			subclass.ucs_x_axis = subclass.ucs_x_axis or {}
			subclass.ucs_x_axis.x = group.value
		elseif code == 121 then
			subclass.ucs_x_axis = subclass.ucs_x_axis or {}
			subclass.ucs_x_axis.y = group.value
		elseif code == 131 then
			subclass.ucs_x_axis = subclass.ucs_x_axis or {}
			subclass.ucs_x_axis.z = group.value
		elseif code == 112 then
			subclass.ucs_y_axis = subclass.ucs_y_axis or {}
			subclass.ucs_y_axis.x = group.value
		elseif code == 122 then
			subclass.ucs_y_axis = subclass.ucs_y_axis or {}
			subclass.ucs_y_axis.y = group.value
		elseif code == 132 then
			subclass.ucs_y_axis = subclass.ucs_y_axis or {}
			subclass.ucs_y_axis.z = group.value
		elseif code == 79 then
			subclass.orthographic_type_of_ucs = group.value
		elseif code == 146 then
			subclass.elevation = group.value
		elseif code == 345 then
			subclass.named_ucs_record = group.value
		elseif code == 346 then
			subclass.orthographic_ucs_record = group.value
		else
			error("unsupported code "..tostring(code).." in AcDbViewportTableRecord")
		end
	end
	return subclass
end

function save_subclass.AcDbViewportTableRecord(subclass)
	local groupcodes = {}
	if subclass.name then
		table.insert(groupcodes, groupcode(2, subclass.name))
	end
	if subclass.flags ~= nil then
		table.insert(groupcodes, groupcode(70, subclass.flags))
	end
	if subclass.extents ~= nil then
		if subclass.extents.left ~= nil then
			table.insert(groupcodes, groupcode(10, subclass.extents.left))
		end
		if subclass.extents.bottom ~= nil then
			table.insert(groupcodes, groupcode(20, subclass.extents.bottom))
		end
		if subclass.extents.right ~= nil then
			table.insert(groupcodes, groupcode(11, subclass.extents.right))
		end
		if subclass.extents.top ~= nil then
			table.insert(groupcodes, groupcode(21, subclass.extents.top))
		end
	end
	if subclass.center ~= nil then
		if subclass.center.x ~= nil then
			table.insert(groupcodes, groupcode(12, subclass.center.x))
		end
		if subclass.center.y ~= nil then
			table.insert(groupcodes, groupcode(22, subclass.center.y))
		end
	end
	if subclass.snap_base_point ~= nil then
		if subclass.snap_base_point.x ~= nil then
			table.insert(groupcodes, groupcode(13, subclass.snap_base_point.x))
		end
		if subclass.snap_base_point.y ~= nil then
			table.insert(groupcodes, groupcode(23, subclass.snap_base_point.y))
		end
	end
	if subclass.snap_spacing ~= nil then
		if subclass.snap_spacing.x ~= nil then
			table.insert(groupcodes, groupcode(14, subclass.snap_spacing.x))
		end
		if subclass.snap_spacing.y ~= nil then
			table.insert(groupcodes, groupcode(24, subclass.snap_spacing.y))
		end
	end
	if subclass.grid_spacing ~= nil then
		if subclass.grid_spacing.x ~= nil then
			table.insert(groupcodes, groupcode(15, subclass.grid_spacing.x))
		end
		if subclass.grid_spacing.y ~= nil then
			table.insert(groupcodes, groupcode(25, subclass.grid_spacing.y))
		end
	end
	if subclass.view_direction ~= nil then
		if subclass.view_direction.x ~= nil then
			table.insert(groupcodes, groupcode(16, subclass.view_direction.x))
		end
		if subclass.view_direction.y ~= nil then
			table.insert(groupcodes, groupcode(26, subclass.view_direction.y))
		end
		if subclass.view_direction.z ~= nil then
			table.insert(groupcodes, groupcode(36, subclass.view_direction.z))
		end
	end
	if subclass.view_target_point ~= nil then
		if subclass.view_target_point.x ~= nil then
			table.insert(groupcodes, groupcode(17, subclass.view_target_point.x))
		end
		if subclass.view_target_point.y ~= nil then
			table.insert(groupcodes, groupcode(27, subclass.view_target_point.y))
		end
		if subclass.view_target_point.z ~= nil then
			table.insert(groupcodes, groupcode(37, subclass.view_target_point.z))
		end
	end
	if subclass.view_height ~= nil then
		table.insert(groupcodes, groupcode(40, subclass.view_height))
	end
	if subclass.viewport_aspect_ratio ~= nil then
		table.insert(groupcodes, groupcode(41, subclass.viewport_aspect_ratio))
	end
	if subclass.lens_length ~= nil then
		table.insert(groupcodes, groupcode(42, subclass.lens_length))
	end
	if subclass.front_clipping_plane ~= nil then
		table.insert(groupcodes, groupcode(43, subclass.front_clipping_plane))
	end
	if subclass.back_clipping_plane ~= nil then
		table.insert(groupcodes, groupcode(44, subclass.back_clipping_plane))
	end
	if subclass.snap_rotation_angle ~= nil then
		table.insert(groupcodes, groupcode(50, subclass.snap_rotation_angle))
	end
	if subclass.view_twist_angle ~= nil then
		table.insert(groupcodes, groupcode(51, subclass.view_twist_angle))
	end
	if subclass.view_mode ~= nil then
		table.insert(groupcodes, groupcode(71, subclass.view_mode))
	end
	if subclass.circle_zoom_percent ~= nil then
		table.insert(groupcodes, groupcode(72, subclass.circle_zoom_percent))
	end
	if subclass.fast_zoom_setting ~= nil then
		table.insert(groupcodes, groupcode(73, subclass.fast_zoom_setting))
	end
	if subclass.ucsicon_setting ~= nil then
		table.insert(groupcodes, groupcode(74, subclass.ucsicon_setting))
	end
	if subclass.snap_on then
		table.insert(groupcodes, groupcode(75, 1))
	end
	if subclass.grid_on then
		table.insert(groupcodes, groupcode(76, 1))
	end
	if subclass.snap_style ~= nil then
		table.insert(groupcodes, groupcode(77, subclass.snap_style))
	end
	if subclass.snap_isopair ~= nil then
		table.insert(groupcodes, groupcode(78, subclass.snap_isopair))
	end
	if subclass.render_mode ~= nil then
		table.insert(groupcodes, groupcode(281, subclass.render_mode))
	end
	if subclass.ucsvp ~= nil then
		table.insert(groupcodes, groupcode(65, subclass.ucsvp))
	end
	if subclass.ucs_origin ~= nil then
		if subclass.ucs_origin.x ~= nil then
			table.insert(groupcodes, groupcode(110, subclass.ucs_origin.x))
		end
		if subclass.ucs_origin.y ~= nil then
			table.insert(groupcodes, groupcode(120, subclass.ucs_origin.y))
		end
		if subclass.ucs_origin.z ~= nil then
			table.insert(groupcodes, groupcode(130, subclass.ucs_origin.z))
		end
	end
	if subclass.ucs_x_axis ~= nil then
		if subclass.ucs_x_axis.x ~= nil then
			table.insert(groupcodes, groupcode(111, subclass.ucs_x_axis.x))
		end
		if subclass.ucs_x_axis.y ~= nil then
			table.insert(groupcodes, groupcode(121, subclass.ucs_x_axis.y))
		end
		if subclass.ucs_x_axis.z ~= nil then
			table.insert(groupcodes, groupcode(131, subclass.ucs_x_axis.z))
		end
	end
	if subclass.ucs_y_axis ~= nil then
		if subclass.ucs_y_axis.x ~= nil then
			table.insert(groupcodes, groupcode(112, subclass.ucs_y_axis.x))
		end
		if subclass.ucs_y_axis.y ~= nil then
			table.insert(groupcodes, groupcode(122, subclass.ucs_y_axis.y))
		end
		if subclass.ucs_y_axis.z ~= nil then
			table.insert(groupcodes, groupcode(132, subclass.ucs_y_axis.z))
		end
	end
	if subclass.orthographic_type_of_ucs ~= nil then
		table.insert(groupcodes, groupcode(79, subclass.orthographic_type_of_ucs))
	end
	if subclass.elevation ~= nil then
		table.insert(groupcodes, groupcode(146, subclass.elevation))
	end
	if subclass.named_ucs_record ~= nil then
		table.insert(groupcodes, groupcode(345, subclass.named_ucs_record))
	end
	if subclass.orthographic_ucs_record ~= nil then
		table.insert(groupcodes, groupcode(346, subclass.orthographic_ucs_record))
	end
	return groupcodes
end

function load_subclass.AcDbLayerTableRecord(groupcodes)
	local subclass = {type='AcDbLayerTableRecord'}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 2 then
			subclass.name = group.value
		elseif code == 70 then
			subclass.flags = group.value
		elseif code == 62 then
			subclass.color = group.value
		elseif code == 6 then
			subclass.line_type_name = group.value
		elseif code == 290 then
			subclass.plotting_flag = group.value
		elseif code == 370 then
			subclass.line_weight = group.value
		elseif code == 390 then
			subclass.plot_style = group.value
		elseif code == 347 then
			subclass.material = group.value
		else
			error("unsupported code "..tostring(code).." in AcDbLayerTableRecord")
		end
	end
	return subclass
end

function save_subclass.AcDbLayerTableRecord(subclass)
	local groupcodes = {}
	if subclass.name then
		table.insert(groupcodes, groupcode(2, subclass.name))
	end
	if subclass.flags then
		table.insert(groupcodes, groupcode(70, subclass.flags))
	end
	if subclass.color then
		table.insert(groupcodes, groupcode(62, subclass.color))
	end
	if subclass.line_type_name then
		table.insert(groupcodes, groupcode(6, subclass.line_type_name))
	end
	if subclass.plotting_flag then
		table.insert(groupcodes, groupcode(290, subclass.plotting_flag))
	end
	if subclass.line_weight then
		table.insert(groupcodes, groupcode(370, subclass.line_weight))
	end
	if subclass.plot_style then
		table.insert(groupcodes, groupcode(390, subclass.plot_style))
	end
	if subclass.material then
		table.insert(groupcodes, groupcode(347, subclass.material))
	end
	return groupcodes
end

function load_subclass.AcDbLinetypeTableRecord(groupcodes)
	local subclass = {type='AcDbLinetypeTableRecord'}
	local element_count
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 2 then
			subclass.name = group.value
		elseif code == 70 then
			subclass.flags = group.value
		elseif code == 3 then
			subclass.description = group.value
		elseif code == 72 then
			subclass.alignment_code = group.value
		elseif code == 40 then
			subclass.pattern_length = group.value
		elseif code == 73 then
			element_count = group.value
		elseif code == 49 or code == 74 then
			-- treated below
		else
			error("unsupported code "..tostring(code).." in AcDbLayerTableRecord")
		end
	end
	local elements = {}
	for _,group in ipairs(groupcodes) do
		if code == 49 then
			table.insert(elements, group.value)
		elseif code == 74 then
			assert(group.value == 0, "embedded shape/text in line types is not supported")
		end
	end
	assert(#elements <= element_count)
	subclass.elements = elements
	return subclass
end

function save_subclass.AcDbLinetypeTableRecord(subclass)
	local groupcodes = {}
	if subclass.name then
		table.insert(groupcodes, groupcode(2, subclass.name))
	end
	if subclass.flags then
		table.insert(groupcodes, groupcode(70, subclass.flags))
	end
	if subclass.description then
		table.insert(groupcodes, groupcode(3, subclass.description))
	end
	if subclass.alignment_code then
		table.insert(groupcodes, groupcode(72, subclass.alignment_code))
	end
	if subclass.elements then
		table.insert(groupcodes, groupcode(73, #subclass.elements))
	end
	if subclass.pattern_length then
		table.insert(groupcodes, groupcode(40, subclass.pattern_length))
	end
	if subclass.elements then
		for _,element in ipairs(subclass.elements) do
			table.insert(groupcodes, groupcode(49, element))
			table.insert(groupcodes, groupcode(74, 0))
		end
	end
	return groupcodes
end

function load_subclass.AcDbEntity(groupcodes)
	local subclass = {
		type = 'AcDbEntity',
		line_type_name = 'BYLAYER',
		color = 'BYLAYER',
		line_type_scale = 1.0,
	}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 67 then
			subclass.paper_space = group.value ~= 0
		elseif code == 8 then
			subclass.layer = group.value
		elseif code == 6 then
			subclass.line_type_name = group.value
		elseif code == 62 then
			local value = group.value
			if value == 0 then
				subclass.color = 'BYBLOCK'
			elseif value == 255 then
				assert(subclass.color == 'BYLAYER')
			else
				subclass.color = group.value
			end
		elseif code == 370 then
			subclass.line_weight = group.value
		elseif code == 48 then
			subclass.line_type_scale = group.value
		elseif code == 60 then
			subclass.hidden = group.value ~= 0
		else
			error("unsupported code "..tostring(code).." in AcDbEntity")
		end
	end
	return subclass
end

function save_subclass.AcDbEntity(subclass)
	local groupcodes = {}
	if subclass.paper_space then
		table.insert(groupcodes, groupcode(67, 1))
	end
	assert(subclass.layer, "entity has no layer defined")
	table.insert(groupcodes, groupcode(8, subclass.layer))
	if subclass.line_type_name and subclass.line_type_name ~= 'BYLAYER' then
		table.insert(groupcodes, groupcode(6, subclass.line_type_name))
	end
	if subclass.color and subclass.color ~= 'BYLAYER' then
		if subclass.color == 'BYBLOCK' then
			table.insert(groupcodes, groupcode(62, 0))
		else
			table.insert(groupcodes, groupcode(62, subclass.color))
		end
	end
	if subclass.line_weight then
		table.insert(groupcodes, groupcode(370, subclass.line_weight))
	end
	if subclass.line_type_scale and subclass.line_type_scale ~= 1.0 then
		table.insert(groupcodes, groupcode(48, subclass.line_type_scale))
	end
	if subclass.hidden then
		table.insert(groupcodes, groupcode(60, 1))
	end
	return groupcodes
end

function load_subclass.AcDbSymbolTable(groupcodes)
	local subclass = {type='AcDbSymbolTable'}
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 70 then
			subclass.length = group.value
		else
			error("unsupported code "..tostring(code).." in AcDbSymbolTable")
		end
	end
	return subclass
end

function save_subclass.AcDbSymbolTable(subclass)
	local groupcodes = {}
	if subclass.length then
		table.insert(groupcodes, groupcode(70, subclass.length))
	end
	return groupcodes
end

local function load_object(otype, groupcodes)
	local object = {
		type=otype,
	}
	local subclasses = {}
	local subclass
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code==100 then
			local classname = parse(group)
			subclass = { type = classname }
			table.insert(subclasses, subclass)
		else
			if not subclass then
				subclass = {}
				table.insert(subclasses, subclass)
			end
			table.insert(subclass, {code=code, value=parse(group)})
		end
	end
	for isubclass,groupcodes in ipairs(subclasses) do
		local classname = groupcodes.type
		local loader = load_subclass[classname] or load_subclass_generic
		local subclass = loader(groupcodes)
		if classname then
			subclass.type = classname
			table.insert(object, subclass)
		else
			assert(isubclass == 1)
			for k,v in pairs(subclass) do
				if type(k) == 'string' then
					assert(k ~= 'type' and k ~= 'attributes')
					assert(object[k] == nil)
					subclasses[k] = nil
					object[k] = v
				end
			end
			if next(subclasses) then
				assert(object.attributes == nil)
				object.attributes = subclass
			end
		end
	end
	return object
end

local function save_object(otype, object)
	local attributes = object.attributes or {}
	for k,v in pairs(object) do
		if type(k) == 'string' and k ~= 'type' and k ~= 'attributes' then
			attributes[k] = v
		end
	end
	local subclasses = { attributes }
	for _,subclass in ipairs(object) do
		assert(subclass.type)
		table.insert(subclasses, subclass)
	end
	local groupcodes = {}
	for _,subclass in ipairs(subclasses) do
		local classname = subclass.type
		if classname then
			table.insert(groupcodes, groupcode(100, classname))
		end
		local saver = save_subclass[classname] or save_subclass_generic
		for _,group in ipairs(saver(subclass)) do
			table.insert(groupcodes, group)
		end
	end
	return groupcodes
end

------------------------------------------------------------------------------

local load_section = {}
local save_section = {}

--............................................................................

local header_codes = {
	ACADVER = 1,
	HANDSEED = 5,
	MEASUREMENT = 70,
}

function load_section.HEADER(groupcodes)
	local chunks = {}
	local chunk
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code == 9 then
			chunk = {}
			table.insert(chunk, group)
			table.insert(chunks, chunk)
		else
			table.insert(chunk, group)
		end
	end
	local headers = {}
	for _,chunk in pairs(chunks) do
		assert(#chunk >= 1)
		local name = table.remove(chunk, 1)
		assert(name.code == 9)
		name = assert(parse(name):match('^$(.*)$'))
		if header_codes[name] then
			assert(#chunk == 1)
			assert(chunk[1].code == header_codes[name])
			headers[name] = parse(chunk[1])
		else
			headers[name] = chunk
		end
	end
	return headers
end

function save_section.HEADER(headers)
	local names = {}
	for name in pairs(headers) do
		table.insert(names, name)
	end
	table.sort(names)
	local chunks = {}
	for _,name in ipairs(names) do
		local chunk = {}
		table.insert(chunk, groupcode(9, '$'..name))
		if header_codes[name] then
			table.insert(chunk, groupcode(header_codes[name], headers[name]))
		else
			for _,group in ipairs(headers[name]) do
				table.insert(chunk, group)
			end
		end
		table.insert(chunks, chunk)
	end
	local groupcodes = {}
	for _,chunk in ipairs(chunks) do
		for _,group in ipairs(chunk) do
			table.insert(groupcodes, group)
		end
	end
	return groupcodes
end

--............................................................................

function load_section.CLASSES(groupcodes)
	error("section not supported")
	local classes = {}
	local class
	for _,group in ipairs(groupcodes) do
		local code = group.code
		if code==0 then
			class = {}
			table.insert(classes, class)
		elseif code==1 then
			assert(class).class_dxf_record = parse(group)
		elseif code==2 then
			assert(class).class_name = parse(group)
		elseif code==3 then
			assert(class).app_name = parse(group)
		elseif code==90 then
			assert(class).flag90 = parse(group)
		elseif code==280 then
			assert(class).flag280 = parse(group)
		elseif code==281 then
			assert(class).flag281 = parse(group)
		else
			-- :TODO: save group code without interpreting it
		end
	end
	return classes
end

--............................................................................

local function load_table_header(groupcodes)
	return load_object(nil, groupcodes)
end

local function save_table_header(header)
	return save_object(nil, header)
end

local function load_table_record(type, groupcodes)
	return load_object(type, groupcodes)
end

local function save_table_record(type, record)
	return save_object(type, record)
end

local function load_table(type, groupcodes)
	local header = {}
	local records = {}
	local record = header
	for _,group in ipairs(groupcodes) do
		local code = group.code
		local data = group.data
		if code==0 then
			assert(data == type, "record type "..tostring(data).." differ from table type "..tostring(type))
			record = {}
			table.insert(records, record)
		else
			table.insert(record, group)
		end
	end
	
	header = load_table_header(header)
	local table = {type=type}
	for _,group in ipairs(header.attributes) do
		local code = group.code
		error("unsupported code "..tostring(code).." in table header")
	end
	assert(#header == 1)
	for _,subclass in ipairs(header) do
		if subclass.type == 'AcDbSymbolTable' then
		--	assert(subclass.length == #records) -- this is not required
		end
	end
	for _,record in ipairs(records) do
		record = load_table_record(type, record)
		assert(record.type == type)
		record.type = nil
		tinsert(table, record)
	end
	return table
end

local function save_table(table)
	local groupcodes = {}
	local header = {
		handle = table.handle,
		owner = table.owner,
		{ type = 'AcDbSymbolTable', length = #table },
	}
	for _,group in ipairs(save_table_header(header)) do
		tinsert(groupcodes, group)
	end
	for _,record in ipairs(table) do
		tinsert(groupcodes, groupcode(0, table.type))
		for _,group in ipairs(save_table_record(table.type, record)) do
			tinsert(groupcodes, group)
		end
	end
	return groupcodes
end

function load_section.TABLES(groupcodes)
	local chunks = {}
	local chunk
	for _,group in ipairs(groupcodes) do
		local code = group.code
		local data = group.data
		if code==0 and data=='TABLE' then
			chunk = {}
			tinsert(chunks, chunk)
		elseif code==0 and data=='ENDTAB' then
			chunk = nil
		else
			tinsert(chunk, group)
		end
	end
	
	local tables = {}
	for _,groupcodes in ipairs(chunks) do
		local name = tremove(groupcodes, 1)
		assert(name.code==2)
		name = name.data
		local table = load_table(name, groupcodes)
		tinsert(tables, table)
	end
	
	return tables
end

function save_section.TABLES(tables)
	local chunks = {}
	for _,table in ipairs(tables) do
		local chunk = save_table(table)
		tinsert(chunk, 1, groupcode(2, table.type))
		tinsert(chunks, chunk)
	end
	
	local groupcodes = {}
	for _,chunk in ipairs(chunks) do
		table.insert(groupcodes, groupcode(0, 'TABLE'))
		for _,group in ipairs(chunk) do
			table.insert(groupcodes, group)
		end
		table.insert(groupcodes, groupcode(0, 'ENDTAB'))
	end
	
	return groupcodes
end

--............................................................................

local function load_entity(type, groupcodes)
	return load_object(type, groupcodes)
end

local function save_entity(type, entity)
	return save_object(type, entity)
end

function load_section.ENTITIES(groupcodes)
	local chunks = {}
	local chunk
	for _,group in ipairs(groupcodes) do
		local code = group.code
		local data = group.data
		if code==0 then
			chunk = {group}
			table.insert(chunks, chunk)
		else
			table.insert(chunk, group)
		end
	end
	
	local entities = {}
	for _,groupcodes in ipairs(chunks) do
		local type = tremove(groupcodes, 1)
		assert(type.code==0)
		local entity = load_entity(type.data, groupcodes)
		table.insert(entities, entity)
	end
	
	return entities
end

function save_section.ENTITIES(entities)
	local chunks = {}
	for _,entity in ipairs(entities) do
		local chunk = save_entity(entity.type, entity)
		table.insert(chunk, 1, groupcode(0, entity.type))
		table.insert(chunks, chunk)
	end
	
	local groupcodes = {}
	for _,chunk in ipairs(chunks) do
		assert(chunk[1].code==0)
		for _,group in ipairs(chunk) do
			table.insert(groupcodes, group)
		end
	end
	return groupcodes
end

--............................................................................

function load_section.BLOCKS(groupcodes)
	local chunks = {}
	local chunk
	for _,group in ipairs(groupcodes) do
		local code = group.code
		local data = group.data
		if code==0 then
			chunk = {group}
			table.insert(chunks, chunk)
		else
			table.insert(chunk, group)
		end
	end
	
	local entities = {}
	for _,groupcodes in ipairs(chunks) do
		local type = tremove(groupcodes, 1)
		assert(type.code==0)
		local entity = load_entity(type.data, groupcodes)
		table.insert(entities, entity)
	end
	
	return entities
end

function save_section.BLOCKS(entities)
	local chunks = {}
	for _,entity in ipairs(entities) do
		local chunk = save_entity(entity.type, entity)
		table.insert(chunk, 1, groupcode(0, entity.type))
		table.insert(chunks, chunk)
	end
	
	local groupcodes = {}
	for _,chunk in ipairs(chunks) do
		assert(chunk[1].code==0)
		for _,group in ipairs(chunk) do
			table.insert(groupcodes, group)
		end
	end
	return groupcodes
end

--............................................................................

function load_section.OBJECTS(groupcodes)
	local chunks = {}
	local chunk
	for _,group in ipairs(groupcodes) do
		local code = group.code
		local data = group.data
		if code==0 then
			chunk = {group}
			table.insert(chunks, chunk)
		else
			table.insert(chunk, group)
		end
	end
	
	local root_dictionary = table.remove(chunks, 1)
	local type = table.remove(root_dictionary, 1)
	assert(type.code==0)
	assert(type.data=='DICTIONARY')
	root_dictionary = load_object(type.data, root_dictionary)
	
	local objects = {root_dictionary=root_dictionary}
	for _,groupcodes in ipairs(chunks) do
		local type = table.remove(groupcodes, 1)
		assert(type.code==0)
		local object = load_object(type.data, groupcodes)
		table.insert(objects, object)
	end
	
	return objects
end

function save_section.OBJECTS(objects)
	local chunks = {}
	
	local chunk = save_object(nil, objects.root_dictionary)
	table.insert(chunk, 1, groupcode(0, 'DICTIONARY'))
	table.insert(chunks, chunk)
	
	for _,object in ipairs(objects) do
		local chunk = save_object(object.type, object)
		table.insert(chunk, 1, groupcode(0, object.type))
		table.insert(chunks, chunk)
	end
	
	local groupcodes = {}
	for _,chunk in ipairs(chunks) do
		assert(chunk[1].code==0)
		for _,group in ipairs(chunk) do
			table.insert(groupcodes, group)
		end
	end
	
	return groupcodes
end

------------------------------------------------------------------------------

local function load_DXF(groupcodes)
	-- parse top level
	local chunks = {}
	local section
	for _,group in ipairs(groupcodes) do
		if group.code==0 and group.data=='SECTION' then
			section = {}
			table.insert(chunks, section)
		elseif group.code==0 and group.data=='ENDSEC' then
			section = nil
		elseif not section and group.code==0 and group.data=='EOF' then
			break
		else
			assert(section, "group code outside of any section")
			table.insert(section, group)
		end
	end
	
	-- convert sections
	local sections = {}
	for _,groupcodes in ipairs(chunks) do
		local name = table.remove(groupcodes, 1)
		assert(name.code==2)
		name = name.data
		local section = assert(load_section[name], "no loader for section "..tostring(name))(groupcodes)
	--	section.name = name
		sections[name] = section
	end
	
	return sections
end

local section_order = {'HEADER', 'TABLES', 'BLOCKS', 'ENTITIES', 'OBJECTS'}

local function save_DXF(sections)
	-- some checks
	for name in pairs(sections) do
		local found = false
		for _,name2 in ipairs(section_order) do
			if name2 == name then found = true; break end
		end
		assert(found, "unsuppoted DXF section "..tostring(name))
	end
	
	-- convert sections
	local chunks = {}
	for _,name in ipairs(section_order) do
		local section = sections[name]
		if section then
			local groupcodes = {}
			local groupcodes = assert(save_section[name], "no saver for section "..tostring(name))(section)
			table.insert(groupcodes, 1, groupcode(2, name))
			table.insert(chunks, groupcodes)
		end
	end
	
	-- unparse top level
	local groupcodes = {}
	for _,chunk in ipairs(chunks) do
		table.insert(groupcodes, groupcode(0, 'SECTION'))
		for _,group in ipairs(chunk) do
			table.insert(groupcodes, group)
		end
		table.insert(groupcodes, groupcode(0, 'ENDSEC'))
	end
	table.insert(groupcodes, groupcode(0, 'EOF'))
	
	return groupcodes
end

------------------------------------------------------------------------------

function _M.load(file_path)
	-- load lines
	local lines = {}
	for line in io.lines(file_path) do
		table.insert(lines, line)
	end
	assert(#lines % 2 == 0)
	
	-- group code and data
	local groupcodes = {}
	for i=1,#lines,2 do
		local code = assert(tonumber(lines[i]))
		local data = lines[i+1]
		if code==0 and data=='EOF' then
			assert(i==#lines-1)
			break
		end
		table.insert(groupcodes, {code=code, data=data})
	end
	
	local sections = load_DXF(groupcodes)
	
	local scale = 1e9
	
	local layers = {{polarity='dark'}}
	local layer = layers[1]
	local aperture = {shape='circle', parameters={0}, unit='mm', name=10}
	for _,entity in ipairs(sections.ENTITIES) do
	--	assert(entity[1].type == 'AcDbEntity')
	--	assert(entity[1].layer == "0")
		local npoints = 0
		if entity.type == 'LWPOLYLINE' then
			local vertices
			for _,subclass in ipairs(entity) do
				if subclass.type=='AcDbPolyline' then
					vertices = subclass.vertices
					if subclass.closed then
						assert(#vertices >= 1)
						table.insert(vertices, {x=vertices[1].x, y=vertices[1].y, z=vertices[1].z})
					end
					break
				end
			end
			assert(vertices)
			local path = {aperture=aperture}
			for i,point in ipairs(vertices) do
				assert(point.z == 0, "3D entities are not yet supported")
				table.insert(path, {x=point.x*scale, y=point.y*scale, interpolation=i>1 and 'linear' or nil})
			end
			table.insert(layer, path)
		elseif entity.type == 'LINE' then
			local AcDbLine
			for _,subclass in ipairs(entity) do
				if subclass.type=='AcDbLine' then
					AcDbLine = subclass
					break
				end
			end
			if not AcDbLine then
				AcDbLine = load_subclass.AcDbLine(entity.attributes)
			end
			local start_point = AcDbLine.start_point
			local end_point = AcDbLine.end_point
			assert(start_point and end_point)
			assert((not start_point.z or start_point.z == 0) and (not end_point.z or end_point.z == 0), "3D entities are not yet supported")
			start_point.x = start_point.x * scale
			start_point.y = start_point.y * scale
			end_point.x = end_point.x * scale
			end_point.y = end_point.y * scale
			local path = {
				aperture = aperture,
				{ x = start_point.x, y = start_point.y },
				{ x = end_point.x, y = end_point.y, interpolation = 'linear' },
			}
			table.insert(layer, path)
		elseif entity.type == 'ARC' then
			local center,radius,angle0,angle1
			for _,subclass in ipairs(entity) do
				if subclass.type=='AcDbCircle' then
					center = subclass.center
					radius = subclass.radius
				elseif subclass.type=='AcDbArc' then
					angle0 = math.rad(subclass.start_angle)
					angle1 = math.rad(subclass.end_angle)
				end
			end
			assert(center)
			assert(center.z == 0, "3D entities are not yet supported")
			center.x = center.x * scale
			center.y = center.y * scale
			local dx0 = radius * math.cos(angle0)
			local dy0 = radius * math.sin(angle0)
			local dx1 = radius * math.cos(angle1)
			local dy1 = radius * math.sin(angle1)
			local quadrant
			if angle1 < angle0 then
				angle1 = angle1 + math.pi * 2
			end
			if angle1 - angle0 < math.pi / 2 then
				quadrant = 'single'
			else
				quadrant = 'multi'
			end
			local path = {
				aperture = aperture,
				{ x = center.x + dx0, y = center.y + dy0 },
				{
					x = center.x + dx1, y = center.y + dy1,
					cx = center.x, cy = center.y,
					interpolation = 'circular', direction = 'counterclockwise', quadrant = quadrant,
				},
			}
			table.insert(layer, path)
		elseif entity.type == 'SPLINE' then
			local p0,p1,p2,p3
			for _,subclass in ipairs(entity) do
				if subclass.type=='AcDbSpline' then
					assert(not subclass.closed)
					assert(not subclass.periodic)
					assert(not subclass.rational)
					assert(subclass.planar)
					assert(not subclass.linear)
					assert(subclass.degree == 3)
					assert(#subclass.control_points == 4)
					p0 = subclass.control_points[1]
					p1 = subclass.control_points[2]
					p2 = subclass.control_points[3]
					p3 = subclass.control_points[4]
					assert(#subclass.knots == 8)
					assert(subclass.knots[1] == 0)
					assert(subclass.knots[2] == 0)
					assert(subclass.knots[3] == 0)
					assert(subclass.knots[4] == 0)
					assert(subclass.knots[5] == 1)
					assert(subclass.knots[6] == 1)
					assert(subclass.knots[7] == 1)
					assert(subclass.knots[8] == 1)
				end
			end
			assert(p0 and p1 and p2 and p3)
			assert(p0.z == 0 and p1.z == 0 and p2.z == 0 and p3.z == 0, "3D entities are not yet supported")
			local path = {
				aperture = aperture,
				{ x = p0.x, y = p0.y },
				{
					x0 = p1.x, y0 = p1.y,
					x1 = p2.x, y1 = p2.x,
					x = p3.x, y = p3.y,
					interpolation = 'cubic',
				},
			}
			table.insert(layer, path)
		else
			error("unsupported entity type "..tostring(entity.type))
		end
	end
	
	local image = {
		file_path = file_path,
		name = nil,
		format = {},
		unit = 'mm',
		layers = layers,
	}
	
	return image
end

local function create_base_file(genhandle)
	-- assemble DXF sections
	local sections = {}
	local line_types = {
		type = "LTYPE",
		handle = genhandle(),
		{
			handle = genhandle(),
			{
				type = "AcDbSymbolTableRecord",
			},
			{
				type = "AcDbLinetypeTableRecord",
				name = "BYBLOCK",
				flags = 0,
				description = "",
				alignment_code = 65,
				pattern_length = 0,
				elements = {},
			},
		},
		{
			handle = genhandle(),
			{
				type = "AcDbSymbolTableRecord",
			},
			{
				type = "AcDbLinetypeTableRecord",
				name = "BYLAYER",
				flags = 0,
				description = "",
				alignment_code = 65,
				pattern_length = 0,
				elements = {},
			},
		},
	}
	local layers = {
		type = "LAYER",
		handle = genhandle(),
		{
			handle = genhandle(),
			{
				type = "AcDbSymbolTableRecord",
			},
			{
				type = "AcDbLayerTableRecord",
				name = "0",
				flags = 0,
				line_type_name = 'CONTINUOUS',
			},
		},
	}
	sections.HEADER = {
		ACADVER = 'AC1014',
	}
	sections.ENTITIES = {}
	sections.OBJECTS = {
		root_dictionary = {
			type = "DICTIONARY",
			handle = genhandle(),
			{
				type = "AcDbDictionary",
			},
		},
	}
	sections.BLOCKS = {
		{
			type = "BLOCK",
			handle = genhandle(),
			{
				type = "AcDbEntity",
				color = "BYLAYER",
				layer = "0",
				line_type_name = "BYLAYER",
				line_type_scale = 1,
			},
			{
				type = "AcDbBlockBegin",
				{
					code = 2,
					value = "*MODEL_SPACE",
				},
				{
					code = 70,
					value = 0,
				},
				{
					code = 10,
					value = 0,
				},
				{
					code = 20,
					value = 0,
				},
				{
					code = 30,
					value = 0,
				},
				{
					code = 3,
					value = "*MODEL_SPACE",
				},
				{
					code = 1,
					value = "",
				},
			},
		},
		{
			type = "ENDBLK",
			handle = genhandle(),
			{
				type = "AcDbEntity",
				color = "BYLAYER",
				layer = "0",
				line_type_name = "BYLAYER",
				line_type_scale = 1,
			},
			{
				type = "AcDbBlockEnd",
			},
		},
		{
			type = "BLOCK",
			handle = genhandle(),
			{
				type = "AcDbEntity",
				color = "BYLAYER",
				layer = "0",
				line_type_name = "BYLAYER",
				line_type_scale = 1,
				paper_space = true,
			},
			{
				type = "AcDbBlockBegin",
				{
					code = 2,
					value = "*PAPER_SPACE",
				},
				{
					code = 1,
					value = "",
				},
			},
		},
		{
			type = "ENDBLK",
			handle = genhandle(),
			{
				type = "AcDbEntity",
				color = "BYLAYER",
				layer = "0",
				line_type_name = "BYLAYER",
				line_type_scale = 1,
				paper_space = true,
			},
			{
				type = "AcDbBlockEnd",
			},
		},
	}
	sections.TABLES = {
		{
			type = "VPORT",
			handle = genhandle(),
			{
				handle = genhandle(),
				{
					type = "AcDbSymbolTableRecord",
				},
				{
					type = "AcDbViewportTableRecord",
					name = "*ACTIVE",
					view_height = 341,
					center = {
						x = 210,
						y = 148.5,
					},
					flags = 0,
					viewport_aspect_ratio = 1.24,
				},
			},
		},
		line_types,
		layers,
		{
			type = "STYLE",
			handle = genhandle(),
		},
		{
			type = "VIEW",
			handle = genhandle(),
		},
		{
			type = "UCS",
			handle = genhandle(),
		},
		{
			type = "APPID",
			handle = genhandle(),
			{
				handle = genhandle(),
				{
					type = "AcDbSymbolTableRecord",
				},
				{
					type = "AcDbRegAppTableRecord",
					{
						code = 2,
						value = "ACAD",
					},
					{
						code = 70,
						value = 0,
					},
				},
			},
		},
		{
			type = "DIMSTYLE",
			handle = genhandle(),
		},
		{
			type = "BLOCK_RECORD",
			handle = genhandle(),
			{
				handle = genhandle(),
				{
					type = "AcDbSymbolTableRecord",
				},
				{
					type = "AcDbBlockTableRecord",
					{
						code = 2,
						value = "*MODEL_SPACE",
					},
				},
			},
			{
				handle = genhandle(),
				{
					type = "AcDbSymbolTableRecord",
				},
				{
					type = "AcDbBlockTableRecord",
					{
						code = 2,
						value = "*PAPER_SPACE",
					},
				},
			},
		},
	}
	return sections,line_types,layers
end

local function save_image(image, scale, name, sections, genhandle)
	for _,layer in ipairs(image.layers) do
		-- :FIXME: handle layer polarity
		for ipath,path in ipairs(layer) do
			-- :TODO: create line types for circle apertures, with group code 370 line weight, value in 0.01mm (ie. 0.3mm line is 30)
			if #path == 1 then
				error("aperture flashes are not yet supported in DXF files")
			end
			local line_type,line_weight
			if path.aperture then
				assert(path.aperture.shape == 'circle')
				assert(path.aperture.unit == 'pm')
				line_type = path.aperture.line_type
				assert(line_type == nil or line_type == 'center' or line_type == 'hidden')
				if line_type then line_type = line_type:upper() end
				line_weight = math.floor(path.aperture.diameter * 1e-7 + 0.5) -- 1e-9 for pm to mm, and 1e+2 because DXF line weights are in 1/100th of millimeters (ie. 0.3mm line is 30)
			end
			local dxf_paths = {}
			local dxf_point0
			for i,point in ipairs(path) do
				local x,y = point.x/scale,point.y/scale
				if i == 1 then
					dxf_point0 = {x=x, y=y, z=0}
				else
					if point.interpolation == 'linear' then
						local dxf_point1 = {x=x, y=y, z=0}
						if #dxf_paths >= 1 and dxf_paths[#dxf_paths].type=='line' then
							table.insert(dxf_paths[#dxf_paths], dxf_point1)
						else
							table.insert(dxf_paths, {type='line', dxf_point0, dxf_point1})
						end
						dxf_point0 = dxf_point1
					elseif point.interpolation == 'circular' then
						local cx = point.cx / scale
						local cy = point.cy / scale
						local r,a0,a1
						local dx0,dy0 = dxf_point0.x - cx, dxf_point0.y - cy
						local r = math.sqrt(dx0 ^ 2 + dy0 ^ 2)
						local a0 = math.deg(atan2(dy0, dx0))
						local a1 = math.deg(atan2(y - cy, x - cx))
						if point.direction == 'clockwise' then
							a0,a1 = a1,a0
						end
						local dxf_point1 = {x=x, y=y, z=0}
						table.insert(dxf_paths, {type='arc', c={x=cx, y=cy, z=0}, r=r, a0=a0, a1=a1})
						dxf_point0 = dxf_point1
					elseif point.interpolation == 'quadratic' then
						local x1,y1 = point.x1/scale,point.y1/scale
						local dxf_point1 = {x=x1, y=y1, z=0}
						local dxf_point2 = {x=x, y=y, z=0}
						table.insert(dxf_paths, {type='spline', dxf_point0, dxf_point1, dxf_point2})
						dxf_point0 = dxf_point2
					elseif point.interpolation == 'cubic' then
						local x1,y1 = point.x1/scale,point.y1/scale
						local x2,y2 = point.x2/scale,point.y2/scale
						local dxf_point1 = {x=x1, y=y1, z=0}
						local dxf_point2 = {x=x2, y=y2, z=0}
						local dxf_point3 = {x=x, y=y, z=0}
						table.insert(dxf_paths, {type='spline', dxf_point0, dxf_point1, dxf_point2, dxf_point3})
						dxf_point0 = dxf_point3
					else
						error("unsupported interpolation "..tostring(point.interpolation))
					end
				end
			end
			for _,dxf_path in ipairs(dxf_paths) do
				if dxf_path.type == 'line' and #dxf_path == 2 then
					local entity = {
						type = 'LINE',
						handle = genhandle(),
						{
							type = 'AcDbEntity',
							layer = name,
							line_type_name = line_type,
							line_weight = line_weight,
						},
						{
							type = 'AcDbLine',
							start_point = dxf_path[1],
							end_point = dxf_path[2],
						},
					}
					table.insert(sections.ENTITIES, entity)
				elseif dxf_path.type == 'line' then
					local closed
					local vertices = {}
					for i,point in ipairs(dxf_path) do vertices[i] = point end
					if #vertices >= 2 and vertices[#vertices].x == vertices[1].x and vertices[#vertices].y == vertices[1].y and vertices[#vertices].z == vertices[1].z then
						vertices[#vertices] = nil
						closed = true
					end
					local entity = {
						type = 'LWPOLYLINE',
						handle = genhandle(),
						{
							type = 'AcDbEntity',
							layer = name,
							line_type_name = line_type,
							line_weight = line_weight,
						},
						{
							type = 'AcDbPolyline',
							vertices = vertices,
							closed = closed,
						},
					}
					table.insert(sections.ENTITIES, entity)
				elseif dxf_path.type == 'arc' then
					local entity = {
						type = 'ARC',
						handle = genhandle(),
						{
							type = 'AcDbEntity',
							layer = name,
							line_type_name = line_type,
							line_weight = line_weight,
						},
						{
							type = 'AcDbCircle',
							center = dxf_path.c,
							radius = dxf_path.r,
						},
						{
							type = 'AcDbArc',
							start_angle = dxf_path.a0,
							end_angle = dxf_path.a1,
						},
					}
					table.insert(sections.ENTITIES, entity)
				elseif dxf_path.type == 'spline' and #dxf_path == 3 then
					local entity = {
						type = 'SPLINE',
						handle = genhandle(),
						{
							type = 'AcDbEntity',
							layer = name,
							line_type_name = line_type,
							line_weight = line_weight,
						},
						{
							type = 'AcDbSpline',
							degree = 2,
							planar = true,
							knots = { 0, 0, 0, 1, 1, 1 },
							control_points = { dxf_path[1], dxf_path[2], dxf_path[3] },
						},
					}
					table.insert(sections.ENTITIES, entity)
				elseif dxf_path.type == 'spline' and #dxf_path == 4 then
					local entity = {
						type = 'SPLINE',
						handle = genhandle(),
						{
							type = 'AcDbEntity',
							layer = name,
							line_type_name = line_type,
							line_weight = line_weight,
						},
						{
							type = 'AcDbSpline',
							degree = 3,
							planar = true,
							knots = { 0, 0, 0, 0, 1, 1, 1, 1 },
							control_points = { dxf_path[1], dxf_path[2], dxf_path[3], dxf_path[4] },
						},
					}
					table.insert(sections.ENTITIES, entity)
				else
					error("unsupported DXF path type "..tostring(dxf_path.type))
				end
			end
		end
	end
end

function _M.save(image, file_path)
	local seed = 1
	local function genhandle()
		local handle = seed
		seed = seed + 1
		return string.format("%X", handle)
	end
	
	local layer_name = image.name or "0"
	
	local sections,_,layers = create_base_file(genhandle, layer_name)
	
	local scale
	if image.unit == 'mm' then
		sections.HEADER.MEASUREMENT = 1
		scale = 1e9
	elseif image.unit == 'in' then
		sections.HEADER.MEASUREMENT = 0
		scale = 254e8
	end
	
	if layer_name ~= "0" then
		table.insert(layers, {
			handle = genhandle(),
			{
				type = "AcDbSymbolTableRecord",
			},
			{
				type = "AcDbLayerTableRecord",
				name = layer_name,
				flags = 0,
				line_type_name = 'CONTINUOUS',
			},
		})
	end
	
	save_image(image, scale, layer_name, sections, genhandle)
	
	sections.HEADER.HANDSEED = genhandle()
	
	-- generate group codes
	_M.format = image.format
	local groupcodes = save_DXF(sections)
	_M.format = nil
	
	-- write lines
	local lines = {}
	for i,group in ipairs(groupcodes) do
		local code,data = group.code,group.data
		assert(code, "group has no code")
		assert(data, "group has no data")
		table.insert(lines, string.format("%d", code))
		table.insert(lines, group.data)
		if code==0 and data=='EOF' then
			assert(i==#groupcodes)
			break
		end
	end
	
	-- save lines
	local file = assert(io.open(file_path, 'wb'))
	for _,line in ipairs(lines) do
		assert(file:write(line..'\r\n'))
	end
	assert(file:close())
	
	return true
end

local dxf_colors = {
	['FF0000'] = 01,
	['FFFF00'] = 02,
	['00FF00'] = 03,
	['00FFFF'] = 04,
	['0000FF'] = 05,
	['FF00FF'] = 06,
	['000000'] = 07,
	['414141'] = 08,
	['808080'] = 09,
--	['FF0000'] = 10,
	['FFAAAA'] = 11,
	['BD0000'] = 12,
	['BD7E7E'] = 13,
	['810000'] = 14,
	['815656'] = 15,
	['680000'] = 16,
	['684545'] = 17,
	['4F0000'] = 18,
	['4F3535'] = 19,
	['FF3F00'] = 20,
	['FFBFAA'] = 21,
	['BD2E00'] = 22,
	['BD8D7E'] = 23,
	['811F00'] = 24,
	['816056'] = 25,
	['681900'] = 26,
	['684E45'] = 27,
	['4F1300'] = 28,
	['4F3B35'] = 29,
	['FF7F00'] = 30,
	['FFD4AA'] = 31,
	['BD5E00'] = 32,
	['BD9D7E'] = 33,
	['814000'] = 34,
	['816B56'] = 35,
	['683400'] = 36,
	['685645'] = 37,
	['4F2700'] = 38,
	['4F4235'] = 39,
	['FFBF00'] = 40,
	['FFEAAA'] = 41,
	['BD8D00'] = 42,
	['BDAD7E'] = 43,
	['816000'] = 44,
	['817656'] = 45,
	['684E00'] = 46,
	['685F45'] = 47,
	['4F3B00'] = 48,
	['4F4935'] = 49,
--	['FFFF00'] = 50,
	['FFFFAA'] = 51,
	['BDBD00'] = 52,
	['BDBD7E'] = 53,
	['818100'] = 54,
	['818156'] = 55,
	['686800'] = 56,
	['686845'] = 57,
	['4F4F00'] = 58,
	['4F4F35'] = 59,
	['BFFF00'] = 60,
	['EAFFAA'] = 61,
	['8DBD00'] = 62,
	['ADBD7E'] = 63,
	['608100'] = 64,
	['768156'] = 65,
	['4E6800'] = 66,
	['5F6845'] = 67,
	['3B4F00'] = 68,
	['494F35'] = 69,
	['7FFF00'] = 70,
	['D4FFAA'] = 71,
	['5EBD00'] = 72,
	['9DBD7E'] = 73,
	['408100'] = 74,
	['6B8156'] = 75,
	['346800'] = 76,
	['566845'] = 77,
	['274F00'] = 78,
	['424F35'] = 79,
	['3FFF00'] = 80,
	['BFFFAA'] = 81,
	['2EBD00'] = 82,
	['8DBD7E'] = 83,
	['1F8100'] = 84,
	['608156'] = 85,
	['196800'] = 86,
	['4E6845'] = 87,
	['134F00'] = 88,
	['3B4F35'] = 89,
--	['00FF00'] = 90,
	['AAFFAA'] = 91,
	['00BD00'] = 92,
	['7EBD7E'] = 93,
	['008100'] = 94,
	['568156'] = 95,
	['006800'] = 96,
	['456845'] = 97,
	['004F00'] = 98,
	['354F35'] = 99,
	['00FF3F'] = 100,
	['AAFFBF'] = 101,
	['00BD2E'] = 102,
	['7EBD8D'] = 103,
	['00811F'] = 104,
	['568160'] = 105,
	['006819'] = 106,
	['45684E'] = 107,
	['004F13'] = 108,
	['354F3B'] = 109,
	['00FF7F'] = 110,
	['AAFFD4'] = 111,
	['00BD5E'] = 112,
	['7EBD9D'] = 113,
	['008140'] = 114,
	['56816B'] = 115,
	['006834'] = 116,
	['456856'] = 117,
	['004F27'] = 118,
	['354F42'] = 119,
	['00FFBF'] = 120,
	['AAFFEA'] = 121,
	['00BD8D'] = 122,
	['7EBDAD'] = 123,
	['008160'] = 124,
	['568176'] = 125,
	['00684E'] = 126,
	['45685F'] = 127,
	['004F3B'] = 128,
	['354F49'] = 129,
--	['00FFFF'] = 130,
	['AAFFFF'] = 131,
	['00BDBD'] = 132,
	['7EBDBD'] = 133,
	['008181'] = 134,
	['568181'] = 135,
	['006868'] = 136,
	['456868'] = 137,
	['004F4F'] = 138,
	['354F4F'] = 139,
	['00BFFF'] = 140,
	['AAEAFF'] = 141,
	['008DBD'] = 142,
	['7EADBD'] = 143,
	['006081'] = 144,
	['567681'] = 145,
	['004E68'] = 146,
	['455F68'] = 147,
	['003B4F'] = 148,
	['35494F'] = 149,
	['007FFF'] = 150,
	['AAD4FF'] = 151,
	['005EBD'] = 152,
	['7E9DBD'] = 153,
	['004081'] = 154,
	['566B81'] = 155,
	['003468'] = 156,
	['455668'] = 157,
	['00274F'] = 158,
	['35424F'] = 159,
	['003FFF'] = 160,
	['AABFFF'] = 161,
	['002EBD'] = 162,
	['7E8DBD'] = 163,
	['001F81'] = 164,
	['566081'] = 165,
	['001968'] = 166,
	['454E68'] = 167,
	['00134F'] = 168,
	['353B4F'] = 169,
--	['0000FF'] = 170,
	['AAAAFF'] = 171,
	['0000BD'] = 172,
	['7E7EBD'] = 173,
	['000081'] = 174,
	['565681'] = 175,
	['000068'] = 176,
	['454568'] = 177,
	['00004F'] = 178,
	['35354F'] = 179,
	['3F00FF'] = 180,
	['BFAAFF'] = 181,
	['2E00BD'] = 182,
	['8D7EBD'] = 183,
	['1F0081'] = 184,
	['605681'] = 185,
	['190068'] = 186,
	['4E4568'] = 187,
	['13004F'] = 188,
	['3B354F'] = 189,
	['7F00FF'] = 190,
	['D4AAFF'] = 191,
	['5E00BD'] = 192,
	['9D7EBD'] = 193,
	['400081'] = 194,
	['6B5681'] = 195,
	['340068'] = 196,
	['564568'] = 197,
	['27004F'] = 198,
	['42354F'] = 199,
	['BF00FF'] = 200,
	['EAAAFF'] = 201,
	['8D00BD'] = 202,
	['AD7EBD'] = 203,
	['600081'] = 204,
	['765681'] = 205,
	['4E0068'] = 206,
	['5F4568'] = 207,
	['3B004F'] = 208,
	['49354F'] = 209,
--	['FF00FF'] = 210,
	['FFAAFF'] = 211,
	['BD00BD'] = 212,
	['BD7EBD'] = 213,
	['810081'] = 214,
	['815681'] = 215,
	['680068'] = 216,
	['684568'] = 217,
	['4F004F'] = 218,
	['4F354F'] = 219,
	['FF00BF'] = 220,
	['FFAAEA'] = 221,
	['BD008D'] = 222,
	['BD7EAD'] = 223,
	['810060'] = 224,
	['815676'] = 225,
	['68004E'] = 226,
	['68455F'] = 227,
	['4F003B'] = 228,
	['4F3549'] = 229,
	['FF007F'] = 230,
	['FFAAD4'] = 231,
	['BD005E'] = 232,
	['BD7E9D'] = 233,
	['810040'] = 234,
	['81566B'] = 235,
	['680034'] = 236,
	['684556'] = 237,
	['4F0027'] = 238,
	['4F3542'] = 239,
	['FF003F'] = 240,
	['FFAABF'] = 241,
	['BD002E'] = 242,
	['BD7E8D'] = 243,
	['81001F'] = 244,
	['815660'] = 245,
	['680019'] = 246,
	['68454E'] = 247,
	['4F0013'] = 248,
	['4F353B'] = 249,
	['333333'] = 250,
	['505050'] = 251,
	['696969'] = 252,
	['828282'] = 253,
	['BEBEBE'] = 254,
	['FFFFFF'] = 255,
}

function _M.save_board(board, file_path)
	local image_units = {}
	for _,image in pairs(board.images) do
		image_units[image.unit] = true
	end
	local unit = next(image_units)
	assert(unit and next(image_units, unit) == nil, "board is using multiple units")
	local image_formats = {}
	for _,image in pairs(board.images) do
		image_formats[image.format.integer..':'..image.format.decimal] = true
	end
	assert(next(image_formats) and next(image_formats, next(image_formats)) == nil, "board is using multiple formats")
	local format = select(2, next(board.images)).format
	
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
	
	local seed = 1
	local function genhandle()
		local handle = seed
		seed = seed + 1
		return string.format("%X", handle)
	end
	
	local sections,line_types,layers = create_base_file(genhandle)
	
	local scale
	if unit == 'mm' then
		sections.HEADER.MEASUREMENT = 1
		scale = 1e9
	elseif unit == 'in' then
		sections.HEADER.MEASUREMENT = 0
		scale = 254e8
	end
	
	local center = false
	local hidden = false
	for _,layer_name in pairs(image_types) do
		local image = board.images[layer_name]
		local layer = {
			handle = genhandle(),
			{
				type = "AcDbSymbolTableRecord",
			},
			{
				type = "AcDbLayerTableRecord",
				name = layer_name,
				flags = 0,
				line_type_name = 'CONTINUOUS',
			},
		}
		if image.color then
			local a,r,g,b = assert(image.color:match('^#(%x%x)(%x%x)(%x%x)(%x%x)$'))
			a,r,g,b = tonumber(a, 16), tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
			local rgb = assert(image.color:match('^#%x%x(%x%x%x%x%x%x)$')):upper()
			if a ~= 255 then
				layer[2].line_type_name = 'CENTER'
				center = true
			end
			layer[2].color = assert(dxf_colors[rgb], "unsupported DXF color")
		end
		for _,layer in ipairs(image.layers) do
			for _,path in ipairs(layer) do
				local line_type = path.aperture and path.aperture.line_type
				if line_type == 'center' then
					center = true
				elseif line_type == 'hidden' then
					hidden = true
				end
			end
		end
		table.insert(layers, layer)
	end
	if center then
		table.insert(line_types, {
			handle = genhandle(),
			{
				type = "AcDbSymbolTableRecord",
			},
			{
				type = "AcDbLinetypeTableRecord",
				name = 'CENTER',
				flags = 0,
				description = "",
				alignment_code = 65,
				pattern_length = 25 + 25/16 + 25/8 + 25/16,
				elements = { 25, -25/16, 25/8, -25/16 },
			},
		})
	end
	if hidden then
		table.insert(line_types, {
			handle = genhandle(),
			{
				type = "AcDbSymbolTableRecord",
			},
			{
				type = "AcDbLinetypeTableRecord",
				name = 'HIDDEN',
				flags = 0,
				description = "",
				alignment_code = 65,
				pattern_length = 25/4 + 25/16,
				elements = { 25/4, -25/16 },
			},
		})
	end
	for _,layer_name in pairs(image_types) do
		local image = board.images[layer_name]
		-- re-inject outline before saving
		if board.outline and board.outline.apertures[layer_name] then
			image = manipulation.copy_image(image)
			local path = manipulation.copy_path(board.outline.path)
			path.aperture = board.outline.apertures[layer_name]
			table.insert(image.layers[1], path)
		end
		save_image(image, scale, layer_name, sections, genhandle)
	end
	
	sections.HEADER.HANDSEED = genhandle()
	
	-- generate group codes
	_M.format = format
	local groupcodes = save_DXF(sections)
	_M.format = nil
	
	-- write lines
	local lines = {}
	for i,group in ipairs(groupcodes) do
		local code,data = group.code,group.data
		assert(code, "group has no code")
		assert(data, "group has no data")
		table.insert(lines, string.format("%d", code))
		table.insert(lines, group.data)
		if code==0 and data=='EOF' then
			assert(i==#groupcodes)
			break
		end
	end
	
	-- save lines
	local file = assert(io.open(file_path, 'wb'))
	for _,line in ipairs(lines) do
		assert(file:write(line..'\r\n'))
	end
	assert(file:close())
	
	return true
end

return _M
