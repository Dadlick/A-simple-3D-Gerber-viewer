local _M = {}
local _NAME = ... or 'test'

local _G = require '_G'
local math = require 'math'
local table = require 'table'
local string = require 'string'
local coroutine = require 'coroutine'

if _NAME=='test' then
	_M.util = require("serial.util")
else
	_M.util = require(_NAME..".util")
end

--============================================================================

-- local cache

local pack = table.pack
local unpack = table.unpack
local cyield = coroutine.yield
local ccreate = coroutine.create
local cresume = coroutine.resume
local crunning = coroutine.running

-- log facilities

_M.verbose = false

local function warning(message, level)
	if not level then
		level = 1
	end
	if _M.verbose then
		local debug = require 'debug'
		print(debug.traceback("warning: "..message, level+1))
	end
end

-- debug facilities

local err_stacks = setmetatable({}, {
	__mode = 'k',
	__index = function(t, k)
		local v = {}
		t[k] = v
		return v
	end,
})
local function push(...)
	local err_stack = err_stacks[crunning()]
	local t = {...}
	for i=1,select('#', ...) do t[i] = tostring(t[i]) end
	err_stack[#err_stack+1] = table.concat(t, " ")
end
local function pop()
	local err_stack = err_stacks[crunning()]
	err_stack[#err_stack] = nil
end
local function stackstr()
	local err_stack = err_stacks[crunning()]
	local t = {}
	for i=#err_stack,1,-1 do
		t[#t+1] = err_stack[i]
	end
	return "in "..table.concat(t, "\nin ")
end
local _error = error
local function error(msg, level)
	local err_stack = err_stacks[crunning()]
	local t = {}
	for i=#err_stack,1,-1 do
		t[#t+1] = err_stack[i]
	end
	err_stacks[crunning()] = nil
	return _error(msg.."\nlunary traceback:\n\tin "..table.concat(t, "\n\tin "), level and level + 1 or 2)
end
local function assert(...)
	local argc = select('#', ...)
	if argc==0 then
		error("bad argument #1 to 'assert' (value expected)", 2)
	elseif not ... then
		if argc==1 then
			error("assertion failed!", 2)
		else
			local msg = select(2, ...)
			local t = type(msg)
			if t=='string' or t=='number' then
				error(msg, 2)
			else
				error("bad argument #2 to 'assert' (string expected, got "..t..")", 2)
			end
		end
	else
		return ...
	end
end
local function ioerror(msg)
	local err_stack = err_stacks[crunning()]
	local str = "io error"
	str = str..":\n\t"..stackstr():gsub("\n", "\n\t").."\nwith message: "..msg
	err_stacks[crunning()] = nil
	return str
end
local function eoferror()
	local err_stack = err_stacks[crunning()]
	local str = "end of stream"
	str = str..":\n\t"..stackstr():gsub("\n", "\n\t")
	err_stacks[crunning()] = nil
	return str
end

-- stream reading helpers

local function getbytes(stream, nbytes)
	local data,err = stream:getbytes(nbytes)
	if data==nil then return nil,ioerror(err) end
	if #data < nbytes then return nil,eoferror() end
	return data
end

local function putbytes(stream, data)
	local success,err = stream:putbytes(data)
	if not success then return nil,ioerror(err) end
	return true
end

local function getbits(stream, nbits)
	local data,err = stream:getbits(nbits)
	if data==nil then return nil,ioerror(err) end
	if #data < nbits then return nil,eoferror() end
	return data
end

local function putbits(stream, data)
	local success,err = stream:putbits(data)
	if not success then return nil,ioerror(err) end
	return true
end

--============================================================================

-- function read.typename(stream, typeparams...) return value end
-- function write.typename(stream, value, typeparams...) return true end
-- function serialize.typename(value, typeparams...) return string end

local read_mt = {}
local write_mt = {}
local serialize_mt = {}

_M.read = setmetatable({}, read_mt)
_M.write = setmetatable({}, write_mt)
_M.serialize = setmetatable({}, serialize_mt)

_M.struct = {}
_M.fstruct = {}
_M.alias = {}

------------------------------------------------------------------------------

function read_mt:__call(stream, typename, ...)
	local read = assert(_M.read[typename], "no type named "..tostring(typename))
	return read(stream, ...)
end

function read_mt:__index(k)
	local struct = _M.struct[k]
	if struct then
		local read = function(stream)
			push('read', 'struct', k)
			local value,err = _M.read._struct(stream, struct)
			if value==nil then return nil,err end
			pop()
			return value
		end
		self[k] = read
		return read
	end
	local fstruct = _M.fstruct[k]
	if fstruct then
		local read = function(stream, ...)
			return _M.read.fstruct(stream, fstruct, ...)
		end
		self[k] = read
		return read
	end
	local alias = _M.alias[k]
	if alias then
		local read
		local t = type(alias)
		if t=='function' then
			read = function(stream, ...)
				push('read', 'alias', k)
				local value,err = _M.read(stream, alias(...))
				if value==nil and err~=nil then return nil,err end
				pop()
				return value
			end
		elseif t=='string' then
			read = function(stream, ...)
				push('read', 'alias', k)
				local value,err = _M.read(stream, alias)
				if value==nil and err~=nil then return nil,err end
				pop()
				return value
			end
		elseif t=='table' then
			read = function(stream, ...)
				push('read', 'alias', k)
				local value,err = _M.read(stream, unpack(alias))
				if value==nil and err~=nil then return nil,err end
				pop()
				return value
			end
		end
		if read then
			self[k] = read
			return read
		end
	end
end

------------------------------------------------------------------------------

function write_mt:__call(stream, value, typename, ...)
	local write = assert(_M.write[typename], "no type named "..tostring(typename))
	return write(stream, value, ...)
end

function write_mt:__index(k)
	local struct = _M.struct[k]
	if struct then
		local write = function(stream, object)
			push('write', 'struct', k)
			local success,err = _M.write.struct(stream, object, struct)
			if not success then return nil,err end
			pop()
			return stream
		end
		local wrapper = _M.util.wrap("write."..k, write)
		self[k] = wrapper
		return wrapper
	end
	local fstruct = _M.fstruct[k]
	if fstruct then
		local write = function(stream, object, ...)
			return select(1, _M.write.fstruct(stream, object, fstruct, ...))
		end
		local wrapper = _M.util.wrap("write."..k, write)
		self[k] = wrapper
		return wrapper
	end
	local alias = _M.alias[k]
	if alias then
		local write
		local t = type(alias)
		if t=='function' then
			write = function(stream, value, ...)
				push('write', 'alias', k)
				local success,err = _M.write(stream, value, alias(...))
				if not success then return nil,err end
				pop()
				return stream
			end
		elseif t=='string' then
			write = function(stream, value, ...)
				push('write', 'alias', k)
				local success,err = _M.write(stream, value, alias)
				if not success then return nil,err end
				pop()
				return stream
			end
		elseif t=='table' then
			write = function(stream, value, ...)
				push('write', 'alias', k)
				local success,err = _M.write(stream, value, unpack(alias))
				if not success then return nil,err end
				pop()
				return stream
			end
		end
		if write then
			local wrapper = _M.util.wrap("write."..k, write)
			self[k] = wrapper
			return wrapper
		end
	end
	local serialize = rawget(_M.serialize, k)
	if serialize then
		local write = function(stream, ...)
			local data,err = serialize(...)
			if data==nil then return nil,err end
			local success,err = putbytes(stream, data)
			if not success then return nil,err end
			return true
		end
		self[k] = write
		return write
	end
end

------------------------------------------------------------------------------

function serialize_mt:__call(value, typename, ...)
	local serialize = assert(_M.serialize[typename], "no type named "..tostring(typename))
	return serialize(value, ...)
end

function serialize_mt:__index(k)
	local write = _M.write[k]
	if write then
		local serialize = function(...)
			local stream = _M.buffer()
			local success,err = write(stream, ...)
			if not success then
				return nil,err
			end
			return stream:getbytes('*')
		end
		self[k] = serialize
		return serialize
	end
end

--============================================================================

function _M.read.uint(stream, nbits, endianness)
	push('read', 'uint')
	assert(nbits==1 or endianness=='le' or endianness=='be', "invalid endianness "..tostring(endianness))
	if nbits=='*' then
		assert(stream.bitlength, "infinite precision integers can only be read from streams with a length")
		nbits = stream:bitlength()
	end
	local data,err = getbits(stream, nbits)
	if data==nil then return nil,err end
	if #data < nbits then return nil,eoferror() end
	local bits = {string.byte(data, 1, #data)}
	local value = 0
	if nbits==1 then
		value = bits[1]
	elseif endianness=='le' then
		for i,bit in ipairs(bits) do
			value = value + bit * 2^(i-1)
		end
	elseif endianness=='be' then
		for i,bit in ipairs(bits) do
			value = value + bit * 2^(nbits-i)
		end
	end
	local ivalue = math.tointeger(value)
	if ivalue==value then
		value = ivalue
	end
	pop()
	return value
end

function _M.write.uint(stream, value, nbits, endianness)
	push('write', 'uint')
	assert(nbits==1 or endianness=='le' or endianness=='be', "invalid endianness "..tostring(endianness))
	assert(type(value)=='number', "value is not a number")
	assert(value==math.floor(value), "value is not an integer")
	assert(value < 2^nbits, "integer out of range")
	local bits = {}
	for i=nbits-1,0,-1 do
		local bit = 2^i
		if value >= bit then
			table.insert(bits, '\1')
			value = value - bit
		else
			table.insert(bits, '\0')
		end
	end
	bits = table.concat(bits)
	if endianness=='le' then
		bits = bits:reverse()
	end
	local success,err = putbits(stream, bits)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.sint(stream, nbits, endianness)
	push('read', 'sint')
	local value,err = _M.read(stream, 'uint', nbits, endianness)
	if value==nil then return nil,err end
	if value >= 1 << (nbits-1) then
		value = value - (1 << nbits)
	end
	pop()
	return value
end

function _M.write.sint(stream, value, nbits, endianness)
	push('write', 'sint')
	assert(value, math.floor(value), "value is not an integer")
	assert(-(1 << (nbits-1)) <= value and value < 1 << (nbits-1), "integer out of range")
	if value < 0 then
		value = value + (1 << nbits)
	end
	local success,err = _M.write(stream, value, 'uint', nbits, endianness)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.uint8(stream)
	push('read', 'uint8')
	local data,err = getbytes(stream, 1)
	if data==nil then return nil,err end
	pop()
	return string.byte(data)
end

function _M.write.uint8(stream, value)
	push('write', 'uint8')
	assert(type(value)=='number', "value is not a number")
	assert(value==math.floor(value), "value is not an integer")
	assert(value < 2^8, "integer out of range")
	local a = value
	if value < 0 or value >= 2^8 or math.floor(value)~=value then
		error("invalid value")
	end
	local data = string.char(a)
	local success,err = putbytes(stream, data)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

local function read_sint(nbits, sint, uint)
	return function(stream, ...)
		push('read', sint)
		local value,err = _M.read(stream, uint, ...)
		if value==nil then return nil,err end
		if value >= 1 << (nbits-1) then
			value = value - (1 << nbits)
		end
		pop()
		return value
	end
end

local function write_sint(nbits, sint, uint)
	return function(stream, value, ...)
		push('write', sint)
		assert(type(value)=='number', "value is not a number")
		assert(value, math.floor(value), "value is not an integer")
		assert(-(1 << (nbits-1)) <= value and value < 1 << (nbits-1), "integer out of range")
		if value < 0 then
			value = value + (1 << nbits)
		end
		local success,err = _M.write(stream, value, uint, ...)
		if not success then return nil,err end
		pop()
		return stream
	end
end

------------------------------------------------------------------------------

_M.read.sint8 = read_sint(8, 'sint8', 'uint8')
_M.write.sint8 = write_sint(8, 'sint8', 'uint8')

------------------------------------------------------------------------------

function _M.read.uint16(stream, endianness)
	push('read', 'uint16')
	local data,err = getbytes(stream, 2)
	if data==nil then return nil,err end
	local a,b
	if endianness=='le' then
		b,a = string.byte(data, 1, 2)
	elseif endianness=='be' then
		a,b = string.byte(data, 1, 2)
	else
		error("unknown endianness")
	end
	pop()
	return a * 256 + b
end

function _M.write.uint16(stream, value, endianness)
	push('write', 'uint16')
	assert(type(value)=='number', "value is not a number")
	assert(value==math.floor(value), "value is not an integer")
	assert(value < 2^16, "integer out of range")
	local b = value % 256
	value = (value - b) / 256
	local a = value % 256
	local data
	if endianness=='le' then
		data = string.char(b, a)
	elseif endianness=='be' then
		data = string.char(a, b)
	else
		error("unknown endianness")
	end
	local success,err = putbytes(stream, data)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

_M.read.sint16 = read_sint(16, 'sint16', 'uint16')
_M.write.sint16 = write_sint(16, 'sint16', 'uint16')

------------------------------------------------------------------------------

function _M.read.uint32(stream, endianness)
	push('read', 'uint32')
	local data,err = getbytes(stream, 4)
	if data==nil then return nil,err end
	local a,b,c,d
	if endianness=='le' then
		d,c,b,a = string.byte(data, 1, 4)
	elseif endianness=='be' then
		a,b,c,d = string.byte(data, 1, 4)
	else
		error("unknown endianness")
	end
	pop()
	return ((a * 256 + b) * 256 + c) * 256 + d
end

function _M.write.uint32(stream, value, endianness)
	push('write', 'uint32')
	assert(type(value)=='number', "value is not a number")
	assert(value==math.floor(value), "value is not an integer")
	assert(value < 2^32, "integer out of range")
	local d = value % 256
	value = (value - d) / 256
	local c = value % 256
	value = (value - c) / 256
	local b = value % 256
	value = (value - b) / 256
	local a = value % 256
	local data
	if endianness=='le' then
		data = string.char(d, c, b, a)
	elseif endianness=='be' then
		data = string.char(a, b, c, d)
	else
		error("unknown endianness")
	end
	local success,err = putbytes(stream, data)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

_M.read.sint32 = read_sint(32, 'sint32', 'uint32')
_M.write.sint32 = write_sint(32, 'sint32', 'uint32')

------------------------------------------------------------------------------

function _M.read.uint64(stream, endianness)
	push('read', 'uint64')
	-- read bytes
	local data,err = getbytes(stream, 8)
	if data==nil then return nil,err end
	-- convert to number
	local buffer = _M.buffer(data, stream.byte_endianness)
	local h,l
	if endianness=='le' then
		l,err = _M.read(buffer, 'uint32', 'le')
		if not l then return nil,err end
		h,err = _M.read(buffer, 'uint32', 'le')
		if not h then return nil,err end
	elseif endianness=='be' then
		h,err = _M.read(buffer, 'uint32', 'be')
		if not h then return nil,err end
		l,err = _M.read(buffer, 'uint32', 'be')
		if not l then return nil,err end
	else
		error("unknown endianness")
	end
	local value
	if h < (1 << 31) then
		value = (h << 32) + l
	else
		value = h * 2^32 + l
	end
	-- check that we didn't lose precision
	local l2 = value % 2^32
	local h2 = (value - l2) / 2^32
	if h2~=h or l2~=l then
		-- int64 as string is little-endian
		if endianness=='le' then
			value = data
		else
			value = data:reverse()
		end
	end
	pop()
	return value
end

function _M.write.uint64(stream, value, endianness)
	push('write', 'uint64')
	local tvalue = type(value)
	if tvalue=='number' then
		assert(value==math.floor(value), "value is not an integer")
		assert(value < 2^64, "integer out of range")
		local l = value % 2^32
		local h = (value - l) / 2^32
		local success,err
		if endianness=='le' then
			success,err = _M.write(stream, l, 'uint32', 'le')
			if not success then return nil,err end
			success,err = _M.write(stream, h, 'uint32', 'le')
			if not success then return nil,err end
		elseif endianness=='be' then
			success,err = _M.write(stream, h, 'uint32', 'be')
			if not success then return nil,err end
			success,err = _M.write(stream, l, 'uint32', 'be')
			if not success then return nil,err end
		else
			error("unknown endianness")
		end
	elseif tvalue=='string' then
		assert(#value==8)
		local data
		-- int64 as string is little-endian
		if endianness=='le' then
			data = value
		elseif endianness=='be' then
			data = value:reverse()
		else
			error("unknown endianness")
		end
		local success,err = putbytes(stream, data)
		if not success then return nil,err end
	else
		error("uint64 value must be a number or a string")
	end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.sint64(stream, endianness)
	push('read', 'sint64')
	-- read bytes
	local data,err = getbytes(stream, 8)
	if data==nil then return nil,err end
	-- convert to number
	local buffer = _M.buffer(data, stream.byte_endianness)
	local h,l
	if endianness=='le' then
		l,err = _M.read(buffer, 'uint32', 'le')
		if not l then return nil,err end
		h,err = _M.read(buffer, 'uint32', 'le')
		if not h then return nil,err end
	elseif endianness=='be' then
		h,err = _M.read(buffer, 'uint32', 'be')
		if not h then return nil,err end
		l,err = _M.read(buffer, 'uint32', 'be')
		if not l then return nil,err end
	else
		error("unknown endianness")
	end
	if h >= 1 << 31 then
		h = h - (1 << 32) + 1
		l = l - (1 << 32)
	end
	local value = (h << 32) + l
	-- check that we didn't lose precision
	local l2,h2
	if value < 0 then
		h2 = math.ceil(value / 2^32)
		l2 = value - h2 * 2^32
	else
		h2 = math.floor(value / 2^32)
		l2 = value - h2 * 2^32
	end
	if h2~=h or l2~=l then
		-- int64 as string is little-endian
		if endianness=='le' then
			value = data
		else
			value = data:reverse()
		end
	end
	pop()
	return value
end

function _M.write.sint64(stream, value, endianness)
	push('write', 'uint64')
	local tvalue = type(value)
	if tvalue=='number' then
		assert(value==math.floor(value), "value is not an integer")
		assert(-2^63 <= value and value < 2^63, "integer out of range")
		local l,h
		if value < 0 then
			h = math.ceil(value / 2^32)
			l = value - h * 2^32
			h = h + 2^32 - 1
			l = l + 2^32
		else
			h = math.floor(value / 2^32)
			l = value - h * 2^32
		end
		local success,err
		if endianness=='le' then
			success,err = _M.write(stream, l, 'uint32', 'le')
			if not success then return nil,err end
			success,err = _M.write(stream, h, 'uint32', 'le')
			if not success then return nil,err end
		elseif endianness=='be' then
			success,err = _M.write(stream, h, 'uint32', 'be')
			if not success then return nil,err end
			success,err = _M.write(stream, l, 'uint32', 'be')
			if not success then return nil,err end
		else
			error("unknown endianness")
		end
	elseif tvalue=='string' then
		assert(#value==8)
		local data
		-- int64 as string is little-endian
		if endianness=='le' then
			data = value
		elseif endianness=='be' then
			data = value:reverse()
		else
			error("unknown endianness")
		end
		local success,err = putbytes(stream, data)
		if not success then return nil,err end
	else
		error("uint64 value must be a number or a string")
	end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.enum(stream, enum, int_t, ...)
	push('read', 'enum')
	if type(enum)~='table' then
		error("invalid enum")
	end
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local value,err = _M.read(stream, unpack(int_t))
	if value==nil then
		return nil,assert(err, "type '"..int_t[1].."' returned nil but no error")
	end
	local svalue = enum[value]
	if svalue==nil then
		warning("unknown enum number "..tostring(value)..(_M.util.enum_names[enum] and (" for enum "..tostring(enum)) or "")..", keeping numerical value")
		svalue = value
	end
	pop()
	return svalue
end

function _M.write.enum(stream, value, enum, int_t, ...)
	push('write', 'enum')
	if type(enum)~='table' then
		error("invalid enum")
	end
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local ivalue
	if type(value)=='number' then
		ivalue = value
	else
		ivalue = enum[value]
	end
	assert(ivalue, "unknown enum string '"..tostring(value).."'")
	local success,err = _M.write(stream, ivalue, unpack(int_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.mapping(stream, mapping, value_t, ...)
	push('read', 'mapping')
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	local valuel,err = _M.read(stream, unpack(value_t))
	if valuel==nil and err==nil then return nil,err end
	local valueh = mapping[valuel]
	pop()
	return valueh
end

function _M.write.mapping(stream, valueh, mapping, value_t, ...)
	push('write', 'mapping')
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	local valuel = mapping[valueh]
	local success,err = _M.write(stream, valuel, unpack(value_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.flags(stream, flagset, int_t, ...)
	push('read', 'flags')
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local int,err = _M.read(stream, unpack(int_t))
	if int==nil then return nil,err end
	local value = {}
	for k,v in pairs(flagset) do
		-- ignore reverse or invalid mappings (allows use of same dict in enums)
		if type(v)=='number' and int & v ~= 0 then
			value[k] = true
		end
	end
	pop()
	return value
end

function _M.write.flags(stream, value, flagset, int_t, ...)
	push('write', 'flags')
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local ints = {}
	assert(type(value)=='table', "flags value is not a table")
	for flag,k in pairs(value) do
		assert(k==true, "flag has value other than true ("..tostring(k)..")")
		ints[#ints+1] = flagset[flag]
	end
	value = 0
	for _,int in ipairs(ints) do
		value = value | int
	end
	local success,err = _M.write(stream, value, unpack(int_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.array(stream, size_t, value_t, ...)
	push('read', 'array')
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	
	-- determine size
	local size
	if size_t=='*' then
		size = '*'
	elseif type(size_t)=='number' then
		size = size_t
	elseif type(size_t)=='table' then
		-- read size
		local err
		push('read', 'size')
		size,err = _M.read(stream, unpack(size_t))
		if size==nil then return nil,err end
		pop()
	else
		error("invalid size definition")
	end
	
	-- read value array
	local value = {}
	if size_t=='*' then
		assert(stream.bytelength, "infinite arrays can only be read from streams with a length")
		while stream:bytelength() > 0 do
			push('read', 'element '..(#value+1))
			local elem,err = _M.read(stream, unpack(value_t))
			if elem==nil then return nil,err end
			pop()
			value[#value+1] = elem
		end
	else
		for i=1,size do
			push('read', 'element '..i)
			local elem,err = _M.read(stream, unpack(value_t))
			if elem==nil then return nil,err end
			pop()
			value[i] = elem
		end
	end
	pop()
	return value
end

function _M.write.array(stream, value, size_t, value_t, ...)
	push('write', 'array')
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	
	assert(type(value)=='table', "array value is not a table")
	
	-- determine size
	local size
	if size_t=='*' then
		size = #value
	elseif type(size_t)=='number' then
		size = size_t
	elseif type(size_t)=='table' then
		size = #value
	else
		error("invalid size definition")
	end
	assert(size == #value, "provided array size doesn't match")
	
	-- write size if necessary
	if type(size_t)=='table' then
		push('write', 'size')
		success,err = _M.write(stream, size, unpack(size_t))
		if not success then return nil,err end
		pop()
	end
	
	-- write value array
	for i=1,size do
		push('write', 'element '..i)
		local success,err = _M.write(stream, value[i], unpack(value_t))
		if not success then return nil,err end
		pop()
	end
	pop()
	return stream
end

------------------------------------------------------------------------------

_M.alias.sizedarray = function(...) return 'array', ... end

------------------------------------------------------------------------------

function _M.read.paddedvalue(stream, size_t, padding, value_t, ...)
	push('read', 'paddedvalue')
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	assert(type(size_t)=='number' or type(size_t)=='table', "size definition should be a number or a type definition array")
	assert(padding==nil or type(padding)=='string' and #padding==1, "padding should be nil or a single character")
	assert(type(value_t)=='table', "value type definition should be an array")
	assert(value_t[1], "value type definition array is empty")
	
	-- read size
	local size,err
	if type(size_t)=='number' then
		size = size_t
	elseif size_t.included then
		push('read', 'size+#size')
		size,err = _M.read(stream, unpack(size_t))
		if size==nil then return nil,err end
		push('size', 'size+#size')
		local sbuffer = _M.buffer('', stream.byte_endianness)
		local success,err = _M.write(sbuffer, size, unpack(size_t))
		if not success then return nil,err end
		local sdata,err = sbuffer:getbytes('*')
		if not sdata then return nil,err end
		pop()
		if #sdata > size then
			return nil,ioerror("included size is too small to include itself")
		else
			size = size - #sdata
		end
	else
		push('read', 'size')
		size,err = _M.read(stream, unpack(size_t))
		if size==nil then return nil,err end
		pop()
	end
	
	-- read serialized value
	local vdata,err
	if size > 0 then
		push('read', 'value bytes')
		vdata,err = getbytes(stream, size)
		if vdata==nil then return nil,err end
		pop()
	else
		vdata = ""
	end
	
	-- build a buffer stream
	local vbuffer = _M.buffer(vdata, stream.byte_endianness)
	
	-- read the value from the buffer
	push('read', 'value')
	local value,err = _M.read(vbuffer, unpack(value_t))
	if value==nil and err~=nil then return nil,err end
	pop()
	
	-- if the buffer is not empty save trailing bytes or generate an error
	if vbuffer:bytelength() > 0 then
		local trailing_bytes,msg = vbuffer:getbytes(vbuffer:bytelength())
		if not trailing_bytes then return nil,msg end
		if padding then
			-- remove padding
			if padding=='\0' then
				trailing_bytes = assert(trailing_bytes:match("^(.-)%z*$"))
			else
				trailing_bytes = assert(trailing_bytes:match("^(.-)%"..padding.."*$"))
			end
		end
		if #trailing_bytes > 0 then
			local msg = "trailing bytes in sized value not read by value serializer "..tostring(value_t[1])..""
			if type(value)=='table' then
				warning(msg)
				value.__trailing_bytes = trailing_bytes
			else
				error(msg)
			end
		end
	end
	pop()
	return value
end

function _M.write.paddedvalue(stream, value, size_t, padding, value_t, ...)
	push('write', 'paddedvalue')
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	-- get serialization functions
	local size_write
	if type(size_t)=='table' then
		assert(size_t[1], "size type definition array is empty")
		size_write = assert(_M.write[size_t[1]], "unknown size type "..tostring(size_t[1]).."")
	elseif type(size_t)=='number' then
		size_write = size_t
	else
		error("size_t should be a type definition array or a number")
	end
	assert(padding==nil or type(padding)=='string' and #padding==1, "padding should be nil or a single character")
	assert(type(value_t)=='table', "value type definition should be an array")
	assert(value_t[1], "value type definition array is empty")
	local value_write = assert(_M.write[value_t[1]], "unknown value type "..tostring(value_t[1]).."")
	-- size value
	push('size', 'value')
	local vbuffer = _M.buffer('', stream.byte_endianness)
	local success,err = value_write(vbuffer, value, unpack(value_t, 2))
	if not success then return nil,err end
	local vdata,err = vbuffer:getbytes('*')
	if not vdata then return nil,err end
	pop()
	-- if value has trailing bytes append them
	if type(value)=='table' and value.__trailing_bytes then
		vdata = vdata .. value.__trailing_bytes
	end
	local size = #vdata
	local sdata
	if type(size_write)=='number' then
		if padding then
			-- check we don't exceed the padded size
			assert(size<=size_write, "value size exceeds padded size")
			vdata = vdata .. string.rep(padding, size_write-size)
		else
			assert(size==size_write, "value size doesn't match sizedvalue size")
		end
	elseif size_t.included then
		push('size', 'size')
		local sbuffer1 = _M.buffer('', stream.byte_endianness)
		local success,err = size_write(sbuffer1, size, unpack(size_t, 2))
		if not success then return nil,err end
		local sdata1,err = sbuffer1:getbytes('*')
		if not sdata1 then return nil,err end
		pop()
		push('write', 'size+#size')
		local sbuffer2 = _M.buffer('', stream.byte_endianness)
		local success,err = size_write(sbuffer2, size + #sdata1, unpack(size_t, 2))
		if not success then return nil,err end
		local sdata2,err = sbuffer2:getbytes('*')
		if not sdata2 then return nil,err end
		pop()
		if #sdata2 ~= #sdata1 then return nil,ioerror("included size has variable length") end
		sdata = sdata2
	else
		push('write', 'size')
		local sbuffer = _M.buffer('', stream.byte_endianness)
		local success,err = size_write(sbuffer, size, unpack(size_t, 2))
		if not success then return nil,err end
		sdata,err = sbuffer:getbytes('*')
		if not sdata then return nil,err end
		pop()
	end
	if sdata then
		push('write', 'size')
		local success,err = putbytes(stream, sdata)
		if not success then return nil,err end
		pop()
	end
	push('write', 'value')
	local success,err = putbytes(stream, vdata)
	if not success then return nil,err end
	pop()
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.sizedvalue(stream, size_t, value_t, ...)
	push('read', 'sizedvalue')
	local results = pack(_M.read.paddedvalue(stream, size_t, nil, value_t, ...))
	pop()
	return unpack(results, 1, results.n)
end

function _M.write.sizedvalue(stream, value, size_t, value_t, ...)
	push('write', 'sizedvalue')
	local success,err = _M.write.paddedvalue(stream, value, size_t, nil, value_t, ...)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.cstring(stream)
	push('read', 'cstring')
	local bytes = {}
	repeat
		local byte,err = _M.read.uint8(stream)
		if not byte then return nil,err end
		bytes[#bytes+1] = byte
	until byte==0
	pop()
	return string.char(unpack(bytes, 1, #bytes-1)) -- remove trailing 0
end

function _M.write.cstring(stream, value)
	push('write', 'cstring')
	assert(type(value)=='string', "value is not a string")
	assert(not value:find('\0'), "a C string cannot contain embedded zeros")
	local data = value..'\0'
	local success,err = putbytes(stream, data)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.float(stream, endianness)
	push('read', 'float')
	local format
	if endianness=='le' then
		format = "<f"
	elseif endianness=='be' then
		format = ">f"
	else
		error("unknown endianness")
	end
	local data,err = getbytes(stream, 4)
	if data==nil then return nil,err end
	pop()
	return string.unpack(format, data)
end

function _M.write.float(stream, value, endianness)
	push('write', 'float')
	local format
	if endianness=='le' then
		format = "<f"
	elseif endianness=='be' then
		format = ">f"
	else
		error("unknown endianness")
	end
	local data = string.pack(format, value)
	if #data ~= 4 then
		error("string.pack \"f\" format doesn't correspond to a 32 bits float")
	end
	local success,err = putbytes(stream, data)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.double(stream, endianness)
	push('read', 'double')
	local format
	if endianness=='le' then
		format = "<d"
	elseif endianness=='be' then
		format = ">d"
	else
		error("unknown endianness")
	end
	local data,err = getbytes(stream, 8)
	if data==nil then return nil,err end
	local value,err = string.unpack(format, data)
	if not value then return nil,err end
	pop()
	return value
end

function _M.write.double(stream, value, endianness)
	push('write', 'double')
	local format
	if endianness=='le' then
		format = "<d"
	elseif endianness=='be' then
		format = ">d"
	else
		error("unknown endianness")
	end
	local data = string.pack(format, value)
	if #data ~= 8 then
		error("string.pack \"d\" format doesn't correspond to a 64 bits float")
	end
	local success,err = putbytes(stream, data)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.bytes(stream, size_t, ...)
	push('read', 'bytes')
	if size_t~='*' and type(size_t)~='number' and (type(size_t)~='table' or select('#', ...)>=1) then
		size_t = {size_t, ...}
	end
	
	-- determine size
	local size
	if size_t=='*' then
		size = '*'
	elseif type(size_t)=='number' then
		size = size_t
	elseif type(size_t)=='table' then
		-- read size
		local err
		size,err = _M.read(stream, unpack(size_t))
		if size==nil then return nil,err end
	else
		error("invalid size definition")
	end
	
	-- read value bytes
	if size=='*' then
		assert(stream.bytelength, "infinite byte sequences can only be read from streams with a length")
		size = stream:bytelength()
	end
	local data,err = getbytes(stream, size)
	if data==nil then return nil,err end
	pop()
	return data
end

function _M.write.bytes(stream, value, size_t, ...)
	push('write', 'bytes')
	if size_t~='*' and type(size_t)~='number' and (type(size_t)~='table' or select('#', ...)>=1) then
		size_t = {size_t, ...}
	end
	assert(type(value)=='string', "bytes value is not a string")
	
	-- determine size
	local size
	if size_t=='*' then
		size = #value
	elseif type(size_t)=='number' then
		size = size_t
	elseif type(size_t)=='table' then
		size = #value
	else
		error("invalid size definition")
	end
	assert(size == #value, "byte string has not the correct length ("..size.." expected, got "..#value..")")
	
	-- write size if necessary
	if type(size_t)=='table' then
		success,err = _M.write(stream, size, unpack(size_t))
		if not success then return nil,err end
	end
	
	-- write value array
	local success,err = putbytes(stream, value)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

_M.alias.char = {'bytes', 1}

------------------------------------------------------------------------------

_M.alias.sizedbuffer = function(...) return 'bytes', ... end

------------------------------------------------------------------------------

local bin2hex = _M.util.bin2hex
local hex2bin = _M.util.hex2bin

function _M.read.hex(stream, bytes_t, ...)
	push('read', 'hex')
	if type(bytes_t)~='table' then
		bytes_t = {bytes_t, ...}
	end
	local bytes,err = _M.read(stream, unpack(bytes_t))
	if bytes==nil then return nil,err end
	local value = bin2hex(bytes)
	pop()
	return value
end

function _M.write.hex(stream, value, bytes_t, ...)
	push('write', 'hex')
	if type(bytes_t)~='table' then
		bytes_t = {bytes_t, ...}
	end
	assert(type(value)=='string', "hex value is not a string")
	local bytes = hex2bin(value)
	local success,err = _M.write(stream, bytes, unpack(bytes_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

_M.alias.bytes2hex = function(count)
	return 'hex', 'bytes', count
end

------------------------------------------------------------------------------

local bin2base32 = _M.util.bin2base32
local base322bin = _M.util.base322bin

function _M.read.base32(stream, bytes_t, ...)
	push('read', 'base32')
	if type(bytes_t)~='table' then
		bytes_t = {bytes_t, ...}
	end
	local bytes,err = _M.read(stream, unpack(bytes_t))
	if bytes==nil then return nil,err end
	local value = bin2base32(bytes)
	pop()
	return value
end

function _M.write.base32(stream, value, bytes_t, ...)
	push('write', 'base32')
	if type(bytes_t)~='table' then
		bytes_t = {bytes_t, ...}
	end
	assert(type(value)=='string', "base32 value is not a string")
	local bytes = base322bin(value)
	local success,err = _M.write(stream, bytes, unpack(bytes_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

_M.alias.bytes2base32 = function(count)
	return 'base32', 'bytes', count
end

------------------------------------------------------------------------------

function _M.read.boolean(stream, int_t, ...)
	push('read', 'boolean')
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local int,err = _M.read(stream, unpack(int_t))
	if int==nil then return nil,err end
	local value
	if int==0 then
		value = false
	elseif int==1 then
		value = true
	else
		warning("boolean value is not 0 or 1, it's "..tostring(int))
		value = int
	end
	pop()
	return value
end

function _M.write.boolean(stream, value, int_t, ...)
	push('write', 'boolean')
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local int
	if type(value)=='boolean' then
		int = value and 1 or 0
	else
		int = value
	end
	local success,err = _M.write(stream, int, unpack(int_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

_M.alias.boolean8 = {'boolean', 'uint8'}

------------------------------------------------------------------------------

function _M.read.truenil(stream, int_t, ...)
	push('read', 'truenil')
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local int,err = _M.read(stream, unpack(int_t))
	if int==nil then return nil,err end
	local value
	if int==0 then
		value = nil
	elseif int==1 then
		value = true
	else
		warning("truenil value is not 0 or 1, it's "..tostring(int))
		value = int
	end
	pop()
	return value
end

function _M.write.truenil(stream, value, int_t, ...)
	push('write', 'truenil')
	if type(int_t)~='table' or select('#', ...)>=1 then
		int_t = {int_t, ...}
	end
	local int
	if type(value)=='boolean' or value==nil then
		int = value and 1 or 0
	else
		int = value
	end
	local success,err = _M.write(stream, int, unpack(int_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.default(stream, default, ...)
	push('read', 'default')
	local value,err = _M.read(stream, ...)
	if value==nil and err then return nil,err end
	if value==default then
		value = nil
	end
	pop()
	return value
end

function _M.write.default(stream, value, default, ...)
	push('write', 'default')
	if value==nil then
		value = default
	end
	local success,err = _M.write(stream, value, ...)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read._struct(stream, fields)
	local object = {}
	for _,field in ipairs(fields) do
		assert(type(field)=='table', "struct field ".._.." is not a table")
		local key = field[1]
		push('read', 'field', key)
		local tk = type(key)
		assert(tk=='nil' or tk=='boolean' or tk=='number' or tk=='string', "only interned value types can be used as struct key")
		local value,err = _M.read(stream, select(2, unpack(field)))
		if value==nil and err~=nil then return nil,err end
		object[key] = value
		pop()
	end
	return object
end

function _M.read.struct(stream, fields)
	push('read', 'struct')
	local value,err = _M.read._struct(stream, fields)
	if value==nil then return nil,err end
	pop()
	return value
end

function _M.write._struct(stream, value, fields)
	local tv = type(value)
	assert(tv=='table' or tv=='userdata', "struct value is not a table")
	for _,field in ipairs(fields) do
		local key = field[1]
		push('write', 'field', key)
		local tk = type(key)
		assert(tk=='nil' or tk=='boolean' or tk=='number' or tk=='string', "only interned value types can be used as struct key")
		local success,err = _M.write(stream, value[key], select(2, unpack(field)))
		if not success then return nil,err end
		pop()
	end
	return true
end

function _M.write.struct(stream, value, fields)
	push('write', 'struct')
	local success,err = _M.write._struct(stream, value, fields)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

local token = {}

local function cwrap(f)
	local c = ccreate(f)
	err_stacks[c] = err_stacks[crunning()]
	return function(...)
		local result = pack(cresume(c, ...))
		if result[1] then
			return unpack(result, 2, result.n)
		else
			_error(result[2])
		end
	end
end

function _M.read.fstruct(stream, f, ...)
	push('read', 'fstruct')
	local params = {n=select('#', ...), ...}
	local object = {}
	local wrapper = setmetatable({}, {
		__index = object,
		__newindex = object,
		__call = function(self, field, ...)
			if select('#', ...)>0 then
				push('read', 'field', field)
				local type = ...
				local read = _M.read[type]
				if not read then error("no function to read field of type "..tostring(type)) end
				local value,err = read(stream, select(2, ...))
				if value==nil and err~=nil then
					cyield(token, nil, err)
				end
				object[field] = value
				pop()
			else
				return --[[_M.util.wrap("field "..field, ]]function(type, ...)
					push('read', 'field', field)
					local read = _M.read[type]
					if not read then error("no function to read field of type "..tostring(type)) end
					local value,err = read(stream, ...)
					if value==nil and err~=nil then
						cyield(token, nil, assert(err, "type '"..type.."' returned nil, but no error"))
					end
					object[field] = value
					pop()
				end--[[)]]
			end
		end,
	})
	local coro = cwrap(function()
		f(wrapper, wrapper, unpack(params, 1, params.n))
		return token, true
	end)
	local results = pack(coro())
	while results[1]~=token do
		results = pack(coro(cyield(unpack(results, 1, results.n))))
	end
	local success,err = unpack(results, 2)
	if not success then return nil,err end
	pop()
	return object
end

function _M.write.fstruct(stream, object, f, ...)
	push('write', 'fstruct')
	local params = {n=select('#', ...), ...}
	local wrapper = setmetatable({}, {
		__index = object,
		__newindex = object,
		__call = function(self, field, ...)
			if select('#', ...)>0 then
				push('write', 'field', field)
				local type = ...
				local write = _M.write[type]
				if not write then error("no function to write field of type "..tostring(type)) end
				local success,err = write(stream, object[field], select(2, ...))
				if not success then
					cyield(token, nil, err)
				end
				pop()
			else
				return function(type, ...)
					push('write', 'field', field)
					local write = _M.write[type]
					if not write then error("no function to write field of type "..tostring(type)) end
					local success,err = write(stream, object[field], ...)
					if not success then
						cyield(token, nil, err)
					end
					pop()
				end
			end
		end,
	})
	local coro = cwrap(function()
		f(wrapper, wrapper, unpack(params, 1, params.n))
		return token, true
	end)
	local results = pack(coro())
	while results[1]~=token do
		results = pack(coro(cyield(unpack(results, 1, results.n))))
	end
	local success,err = unpack(results, 2)
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.constant(stream, constant, value_t, ...)
	push('read', 'constant')
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	local value,err = _M.read(stream, unpack(value_t))
	if value==nil and err~=nil then return nil,err end
	if value~=constant then
		error("invalid constant value in stream ("..tostring(constant).." expected, got "..tostring(value)..")")
	end
	pop()
	return nil
end

function _M.write.constant(stream, value, constant, value_t, ...)
	push('write', 'constant')
	assert(value==nil, "constant should have a nil value")
	if type(value_t)~='table' or select('#', ...)>=1 then
		value_t = {value_t, ...}
	end
	local success,err = _M.write(stream, constant, unpack(value_t))
	if not success then return nil,err end
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.taggedvalue(stream, tag_t, mapping, selector, ...)
	push('read', 'taggedvalue')
	assert(type(tag_t)=='table', "tag type definition should be an array")
	assert(tag_t[1], "tag type definition array is empty")
	
	-- read tag
	push('tag')
	local tag,err = _M.read(stream, unpack(tag_t))
	if tag==nil and err~=nil then return nil,err end
	pop()
	
	-- get value serialization function
	assert(type(mapping)=='table', "mapping should be a table")
	local value_t = assert(mapping[tag], "no mapping for tag "..tostring(tag))
	assert(type(value_t)=='table' or type(value_t)=='function', "value type definition should be an array or a function")
	if type(value_t)=='function' then
		value_t = {value_t(...)}
	end
	assert(value_t[1], "value type definition array is empty")
	
	-- read serialized value
	push('value with tag '..tostring(tag))
	local value,err = _M.read(stream, unpack(value_t))
	if value==nil and err~=nil then return nil,err end
	if type(selector)=='function' then
		assert(selector(value)==tag, "taggedvalue selector misbehaved when applied to a read value")
	elseif selector~=nil then
		assert(type(value)=='table', "taggedvalue non-function selector can only be used for table values")
		value[selector] = tag
	else
		value = {
			tag = tag,
			value = value,
		}
	end
	pop()
	pop()
	return value
end

function _M.write.taggedvalue(stream, value, tag_t, mapping, selector, ...)
	push('write', 'taggedvalue')
	-- get tag
	local tag
	if type(selector)=='function' then
		tag = selector(value)
	elseif selector~=nil then
		assert(type(value)=='table', "taggedvalue non-function selector can only be used for table values")
		tag = value[selector]
	else
		tag = value.tag
		value = value.value
	end
	-- get serialization functions
	assert(type(tag_t)=='table', "tag type definition should be an array")
	assert(tag_t[1], "tag type definition array is empty")
	assert(type(mapping)=='table', "mapping should be a table")
	local value_t = assert(mapping[tag], "no mapping for tag "..tostring(tag))
	assert(type(value_t)=='table' or type(value_t)=='function', "value type definition should be an array or a function")
	if type(value_t)=='function' then
		value_t = {value_t(...)}
	end
	assert(value_t[1], "value type definition array is empty")
	-- write tag and value
	push('write', 'tag')
	local success,err = _M.write(stream, tag, unpack(tag_t))
	if not success then return nil,err end
	pop()
	push('write', 'value with tag '..tostring(tag))
	local success,err = _M.write(stream, value, unpack(value_t))
	if not success then return nil,err end
	pop()
	pop()
	return stream
end

------------------------------------------------------------------------------

function _M.read.empty(stream, value2)
	push('read', 'empty')
	-- simply return the predefined value
	pop()
	return value2
end

function _M.write.empty(stream, value, value2)
	push('write', 'empty')
	local t = type(value2)
	-- for non-referenced types, check that the value match
	if t=='nil' or t=='boolean' or t=='number' or t=='string' then
		assert(value==value2, "empty value doesn't match the type definition")
	end
	-- don't write anything in the stream
	pop()
	return stream
end

--============================================================================

-- force function instantiation for all known types
for type in pairs(_M.serialize) do
	local _ = _M.write[type]
end
for type in pairs(_M.write) do
	local _ = _M.serialize[type]
end
for type in pairs(_M.struct) do
	local _ = _M.write[type] -- this forces write and serialize creation
	local _ = _M.read[type]
end

--============================================================================

local B2b = assert(_M.util.B2b)
local b2B = assert(_M.util.b2B)

local stream_methods = {}

function stream_methods:getbits(nbits)
	assert(type(nbits)=='number')
	local data = ""
	-- use remaining bits
	if #self.rbits > 0 then
		local a,b = self.rbits:sub(1, nbits),self.rbits:sub(nbits+1)
		data = data..a
		self.rbits = b
	end
	if #data < nbits then
		assert(#self.rbits==0)
		local nbytes = math.ceil((nbits - #data) / 8)
		local bytes,msg = self:getbytes(nbytes)
		if not bytes then return nil,msg end
		local bits = B2b(bytes, self.byte_endianness or 'le')
		local a,b = bits:sub(1, nbits-#data),bits:sub(nbits-#data+1)
		data = data..a
		self.rbits = b
	end
	-- use partially written byte
	if #data < nbits and #self.wbits > 0 then
		local a,b = self.wbits:sub(1, nbits),self.wbits:sub(nbits+1)
		data = data..a
		self.wbits = b
	end
	return data
end

function stream_methods:putbits(data)
	-- append bits
	self.wbits = self.wbits..data
	-- send full bytes
	if #self.wbits >= 8 then
		local bits = self.wbits
		local nbytes = math.floor(#bits / 8)
		bits,self.wbits = bits:sub(1, nbytes * 8),bits:sub(nbytes * 8 + 1)
		local bytes = b2B(bits, self.byte_endianness or 'le')
		return self:putbytes(bytes)
	else
		return true
	end
end

function stream_methods:bitlength()
	return #self.rbits + self:bytelength() * 8
end

------------------------------------------------------------------------------

local buffer_methods = {}
local buffer_mt = {__index=buffer_methods}

function _M.buffer(data, byte_endianness)
	return setmetatable({data or "", read_offset=0, rbits="", wbits="", byte_endianness=byte_endianness}, buffer_mt)
end

function buffer_methods:peekbytes(nbytes)
	assert(type(nbytes)=='number' and math.tointeger(nbytes) and nbytes >= 0)
	local len = rawlen(self)
	if len ~= 1 then
		self[1] = table.concat(self)
		for i=len,2,-1 do self[i] = nil end
	end
	return self[1]:sub(self.read_offset + 1, self.read_offset + nbytes)
end

function buffer_methods:getbytes(nbytes)
	assert(type(nbytes)=='number' and math.tointeger(nbytes) and nbytes >= 0 or nbytes=='*')
	local len = rawlen(self)
	if len ~= 1 then
		self[1] = table.concat(self)
		for i=len,2,-1 do self[i] = nil end
	end
	if nbytes == '*' then
		if self.rbits ~= "" or self.wbits ~= "" then
			return nil,"stream is not aligned on bytes"
		end
		nbytes = #self[1]
	end
	local data = self[1]:sub(self.read_offset + 1, self.read_offset + nbytes)
	self.read_offset = self.read_offset + #data
	return data
end

function buffer_methods:putbytes(data)
	table.insert(self, data)
	return true
end

function buffer_methods:bytelength()
	local len = rawlen(self)
	if len ~= 1 then
		self[1] = table.concat(self)
		for i=len,2,-1 do self[i] = nil end
	end
	return #self[1] - self.read_offset
end

buffer_methods.getbits = stream_methods.getbits
buffer_methods.putbits = stream_methods.putbits
buffer_methods.bitlength = stream_methods.bitlength

------------------------------------------------------------------------------

local filestream_methods = {}
local filestream_mt = {__index=filestream_methods}

function _M.filestream(file, byte_endianness)
	-- assume the passed object behaves like a file, it doesn't have to be one
	return setmetatable({file=file, data="", read_offset=0, rbits="", wbits="", byte_endianness=byte_endianness}, filestream_mt)
end

function filestream_methods:peekbytes(nbytes)
	assert(type(nbytes)=='number' and math.tointeger(nbytes) and nbytes >= 0)
	local data
	if self.read_offset + nbytes < #self.data then
		data = self.data:sub(self.read_offset + 1, self.read_offset + nbytes)
	else
		data = self.data:sub(self.read_offset + 1)
		while #data < nbytes do
			local bytes,err = self.file:read(nbytes - #data)
			-- eof
			if bytes==nil and err==nil then break end
			-- error
			if not bytes then return nil,err end
			-- accumulate bytes
			data = data..bytes
			self.data = self.data..bytes
		end
	end
	return data
end

function filestream_methods:getbytes(nbytes)
	assert(type(nbytes)=='number' and math.tointeger(nbytes) and nbytes >= 0)
	local data
	if self.read_offset + nbytes < #self.data then
		data = self.data:sub(self.read_offset + 1, self.read_offset + nbytes)
		self.read_offset = self.read_offset + nbytes
	else
		data = self.data:sub(self.read_offset + 1)
		self.data = ""
		self.read_offset = 0
		while #data < nbytes do
			local bytes,err = self.file:read(nbytes - #data)
			-- eof
			if bytes==nil and err==nil then break end
			-- error
			if not bytes then return nil,err end
			-- accumulate bytes
			data = data..bytes
		end
	end
	return data
end

function filestream_methods:putbytes(data)
	local written,err = self.file:write(data)
	if not written then return nil,err end
	return true
end

function filestream_methods:bytelength()
	local cur = self.file:seek()
	local len = self.file:seek('end')
	self.file:seek('set', cur)
	return len - cur
end

filestream_methods.getbits = stream_methods.getbits
filestream_methods.putbits = stream_methods.putbits
filestream_methods.bitlength = stream_methods.bitlength

------------------------------------------------------------------------------

local tcpstream_methods = {}
local tcpstream_mt = {__index=tcpstream_methods}

function _M.tcpstream(socket, byte_endianness)
	-- assumes the passed object behaves like a luasocket TCP socket
	return setmetatable({socket=socket, data="", read_offset=0, rbits="", wbits="", byte_endianness=byte_endianness}, tcpstream_mt)
end

function tcpstream_methods:peekbytes(nbytes)
	assert(type(nbytes)=='number' and math.tointeger(nbytes) and nbytes >= 0)
	local data
	if self.read_offset + nbytes < #self.data then
		data = self.data:sub(self.read_offset + 1, self.read_offset + nbytes)
	else
		data = self.data:sub(self.read_offset + 1)
		while #data < nbytes do
			local bytes,err = self.socket:receive(nbytes - #data)
			-- error
			if not bytes then return nil,err end
			-- eof
			if #bytes==0 then break end
			-- accumulate bytes
			data = data..bytes
			self.data = self.data..bytes
		end
	end
	return data
end

function tcpstream_methods:getbytes(nbytes)
	assert(type(nbytes)=='number' and math.tointeger(nbytes) and nbytes >= 0)
	local data
	if self.read_offset + nbytes < #self.data then
		data = self.data:sub(self.read_offset + 1, self.read_offset + nbytes)
		self.read_offset = self.read_offset + nbytes
	else
		data = self.data:sub(self.read_offset + 1)
		self.data = ""
		self.read_offset = 0
		while #data < nbytes do
			local bytes,err = self.socket:receive(nbytes - #data)
			-- error
			if not bytes then return nil,err end
			-- eof
			if #bytes==0 then break end
			-- accumulate bytes
			data = data..bytes
		end
	end
	return data
end

function tcpstream_methods:putbytes(data)
	assert(type(data)=='string')
	local total = 0
	local written,err = self.socket:send(data)
	while written and written < #data do
		total = total + written
		data = data:sub(#written + 1)
		written,err = self.socket:send(data)
	end
	if not written then return nil,err end
	return true
end

tcpstream_methods.getbits = stream_methods.getbits
tcpstream_methods.putbits = stream_methods.putbits

------------------------------------------------------------------------------

local nbstream_methods = {}
local nbstream_mt = {__index=nbstream_methods}

function _M.nbstream(socket, byte_endianness)
	-- assumes the passed object behaves like a nb TCP socket
	return setmetatable({socket=socket, rbits="", wbits="", byte_endianness=byte_endianness}, nbstream_mt)
end

function nbstream_methods:getbytes(nbytes)
	assert(type(nbytes)=='number')
	local data = ""
	while #data < nbytes do
		local bytes,err = self.socket:read(nbytes - #data)
		-- error
		if not bytes and err=='aborted' then break end
		if not bytes then return nil,err end
		-- eof
		if #bytes==0 then break end
		-- accumulate bytes
		data = data..bytes
	end
	return data
end

function nbstream_methods:putbytes(data)
	assert(type(data)=='string')
	local total = 0
	local written,err = self.socket:write(data)
	while written and written < #data do
		total = total + written
		data = data:sub(written + 1)
		written,err = self.socket:write(data)
	end
	if not written then return nil,err end
	return true
end

nbstream_methods.getbits = stream_methods.getbits
nbstream_methods.putbits = stream_methods.putbits

--============================================================================

if _NAME=='test' then

require 'test'

-- use random numbers to improve coverage without trying all values, but make
-- sure tests are repeatable
math.randomseed(0)

local function randombuffer(size)
	local t = {}
	for i=1,size do
		t[i] = math.random(0, 255)
	end
	return string.char(unpack(t))
end

local buffer = _M.buffer
local read = _M.read
local write = _M.write
local serialize = _M.serialize

local funcs = {}
local tested = {}
if arg and arg[0] then
	local io = require 'io'
	local file = assert(io.open(arg[0], "rb"))
	content = assert(file:read('*all'))
	assert(file:close())
	
	content = content:gsub('(--%[(=*)%[.-]%2])', function(str) return str:gsub('%S', ' ') end)
	content = content:gsub('%-%-.-\n', function(str) return str:gsub('%S', ' ') end)
	
	for push in content:gmatch('push%b()') do
		local args = {}
		local allstrings = true
		for arg in (push:sub(6, -2)..','):gmatch('%s*(.-)%s*,') do
			if not arg:match('^([\'"]).*%1$') then
				allstrings = false
				break
			end
			table.insert(args, arg:sub(2, -2))
		end
		if allstrings then
			table.insert(funcs, table.concat(args, " "))
		end
	end
	
	local _push = push
--	local _pop = pop
	
	function push(...)
		local t = {...}
		for i=1,select('#', ...) do t[i] = tostring(t[i]) end
		local str = table.concat(t, " ")
		tested[str] = true
		return _push(...)
	end
--	function pop(...)
--		return _pop(...)
--	end
end

-- uint8

expect(42, read(buffer("\042"), 'uint8'))
expect(242, read(buffer("\242"), 'uint8'))

expect("\042", serialize(42, 'uint8'))
expect("\242", serialize(242, 'uint8'))

-- sint8

expect(42, read(buffer("\042"), 'sint8'))
expect(-14, read(buffer("\242"), 'sint8'))

expect("\042", serialize(42, 'sint8'))
expect("\242", serialize(-14, 'sint8'))

-- uint16

expect(10789, read(buffer("\037\042"), 'uint16', 'le'))
expect(10989, read(buffer("\237\042"), 'uint16', 'le'))
expect(61989, read(buffer("\037\242"), 'uint16', 'le'))
expect(62189, read(buffer("\237\242"), 'uint16', 'le'))

expect(9514, read(buffer("\037\042"), 'uint16', 'be'))
expect(60714, read(buffer("\237\042"), 'uint16', 'be'))
expect(9714, read(buffer("\037\242"), 'uint16', 'be'))
expect(60914, read(buffer("\237\242"), 'uint16', 'be'))

expect("\037\042", serialize(10789, 'uint16', 'le'))
expect("\237\042", serialize(10989, 'uint16', 'le'))
expect("\037\242", serialize(61989, 'uint16', 'le'))
expect("\237\242", serialize(62189, 'uint16', 'le'))

expect("\037\042", serialize(9514, 'uint16', 'be'))
expect("\237\042", serialize(60714, 'uint16', 'be'))
expect("\037\242", serialize(9714, 'uint16', 'be'))
expect("\237\242", serialize(60914, 'uint16', 'be'))

-- sint16

expect(10789, read(buffer("\037\042"), 'sint16', 'le'))
expect(10989, read(buffer("\237\042"), 'sint16', 'le'))
expect(-3547, read(buffer("\037\242"), 'sint16', 'le'))
expect(-3347, read(buffer("\237\242"), 'sint16', 'le'))

expect(9514, read(buffer("\037\042"), 'sint16', 'be'))
expect(-4822, read(buffer("\237\042"), 'sint16', 'be'))
expect(9714, read(buffer("\037\242"), 'sint16', 'be'))
expect(-4622, read(buffer("\237\242"), 'sint16', 'be'))

expect("\037\042", serialize(10789, 'sint16', 'le'))
expect("\237\042", serialize(10989, 'sint16', 'le'))
expect("\037\242", serialize(-3547, 'sint16', 'le'))
expect("\237\242", serialize(-3347, 'sint16', 'le'))

expect("\037\042", serialize(9514, 'sint16', 'be'))
expect("\237\042", serialize(-4822, 'sint16', 'be'))
expect("\037\242", serialize(9714, 'sint16', 'be'))
expect("\237\242", serialize(-4622, 'sint16', 'be'))

-- uint32

expect(704643109, read(buffer("\037\000\000\042"), 'uint32', 'le'))
expect(4060086309, read(buffer("\037\000\000\242"), 'uint32', 'le'))
expect(704643309, read(buffer("\237\000\000\042"), 'uint32', 'le'))
expect(4060086509, read(buffer("\237\000\000\242"), 'uint32', 'le'))

expect(620757034, read(buffer("\037\000\000\042"), 'uint32', 'be'))
expect(620757234, read(buffer("\037\000\000\242"), 'uint32', 'be'))
expect(3976200234, read(buffer("\237\000\000\042"), 'uint32', 'be'))
expect(3976200434, read(buffer("\237\000\000\242"), 'uint32', 'be'))

expect("\037\000\000\042", serialize(704643109, 'uint32', 'le'))
expect("\037\000\000\242", serialize(4060086309, 'uint32', 'le'))
expect("\237\000\000\042", serialize(704643309, 'uint32', 'le'))
expect("\237\000\000\242", serialize(4060086509, 'uint32', 'le'))

expect("\037\000\000\042", serialize(620757034, 'uint32', 'be'))
expect("\037\000\000\242", serialize(620757234, 'uint32', 'be'))
expect("\237\000\000\042", serialize(3976200234, 'uint32', 'be'))
expect("\237\000\000\242", serialize(3976200434, 'uint32', 'be'))

-- sint32

expect(704643109, read(buffer("\037\000\000\042"), 'sint32', 'le'))
expect(-234880987, read(buffer("\037\000\000\242"), 'sint32', 'le'))
expect(704643309, read(buffer("\237\000\000\042"), 'sint32', 'le'))
expect(-234880787, read(buffer("\237\000\000\242"), 'sint32', 'le'))

expect(620757034, read(buffer("\037\000\000\042"), 'sint32', 'be'))
expect(620757234, read(buffer("\037\000\000\242"), 'sint32', 'be'))
expect(-318767062, read(buffer("\237\000\000\042"), 'sint32', 'be'))
expect(-318766862, read(buffer("\237\000\000\242"), 'sint32', 'be'))

expect("\037\000\000\042", serialize(704643109, 'sint32', 'le'))
expect("\037\000\000\242", serialize(-234880987, 'sint32', 'le'))
expect("\237\000\000\042", serialize(704643309, 'sint32', 'le'))
expect("\237\000\000\242", serialize(-234880787, 'sint32', 'le'))

expect("\037\000\000\042", serialize(620757034, 'sint32', 'be'))
expect("\037\000\000\242", serialize(620757234, 'sint32', 'be'))
expect("\237\000\000\042", serialize(-318767062, 'sint32', 'be'))
expect("\237\000\000\242", serialize(-318766862, 'sint32', 'be'))

-- uint64

expect(704643109 << 32, read(buffer("\000\000\000\000\037\000\000\042"), 'uint64', 'le'))
expect(4060086309 * 2^32, read(buffer("\000\000\000\000\037\000\000\242"), 'uint64', 'le'))
expect(704643309 << 32, read(buffer("\000\000\000\000\237\000\000\042"), 'uint64', 'le'))
expect(4060086509 * 2^32, read(buffer("\000\000\000\000\237\000\000\242"), 'uint64', 'le'))

expect(620757034, read(buffer("\000\000\000\000\037\000\000\042"), 'uint64', 'be'))
expect(620757234, read(buffer("\000\000\000\000\037\000\000\242"), 'uint64', 'be'))
expect(3976200234, read(buffer("\000\000\000\000\237\000\000\042"), 'uint64', 'be'))
expect(3976200434, read(buffer("\000\000\000\000\237\000\000\242"), 'uint64', 'be'))

expect(704643109, read(buffer("\037\000\000\042\000\000\000\000"), 'uint64', 'le'))
expect(4060086309, read(buffer("\037\000\000\242\000\000\000\000"), 'uint64', 'le'))
expect(704643309, read(buffer("\237\000\000\042\000\000\000\000"), 'uint64', 'le'))
expect(4060086509, read(buffer("\237\000\000\242\000\000\000\000"), 'uint64', 'le'))

expect(620757034 << 32, read(buffer("\037\000\000\042\000\000\000\000"), 'uint64', 'be'))
expect(620757234 << 32, read(buffer("\037\000\000\242\000\000\000\000"), 'uint64', 'be'))
expect(3976200234 * 2^32, read(buffer("\237\000\000\042\000\000\000\000"), 'uint64', 'be'))
expect(3976200434 * 2^32, read(buffer("\237\000\000\242\000\000\000\000"), 'uint64', 'be'))

expect(181009383424, read(buffer("\000\000\000\037\042\000\000\000"), 'uint64', 'le'))
expect(1040002842624, read(buffer("\000\000\000\037\242\000\000\000"), 'uint64', 'le'))
expect(184364826624, read(buffer("\000\000\000\237\042\000\000\000"), 'uint64', 'le'))
expect(1043358285824, read(buffer("\000\000\000\237\242\000\000\000"), 'uint64', 'le'))

expect(159618433024, read(buffer("\000\000\000\037\042\000\000\000"), 'uint64', 'be'))
expect(162973876224, read(buffer("\000\000\000\037\242\000\000\000"), 'uint64', 'be'))
expect(1018611892224, read(buffer("\000\000\000\237\042\000\000\000"), 'uint64', 'be'))
expect(1021967335424, read(buffer("\000\000\000\237\242\000\000\000"), 'uint64', 'be'))

expect('integer', math.type(read(buffer("\000\000\000\000\037\000\000\042"), 'uint64', 'le')))
expect('float', math.type(read(buffer("\000\000\000\000\037\000\000\242"), 'uint64', 'le')))
expect('integer', math.type(read(buffer("\000\000\000\000\237\000\000\042"), 'uint64', 'le')))
expect('float', math.type(read(buffer("\000\000\000\000\237\000\000\242"), 'uint64', 'le')))

expect("\037\000\000\000\000\000\000\042", read(buffer("\037\000\000\000\000\000\000\042"), 'uint64', 'le'))
expect("\037\000\000\000\000\000\000\242", read(buffer("\037\000\000\000\000\000\000\242"), 'uint64', 'le'))
expect("\237\000\000\000\000\000\000\042", read(buffer("\237\000\000\000\000\000\000\042"), 'uint64', 'le'))
expect("\237\000\000\000\000\000\000\242", read(buffer("\237\000\000\000\000\000\000\242"), 'uint64', 'le'))

expect("\042\000\000\000\000\000\000\037", read(buffer("\037\000\000\000\000\000\000\042"), 'uint64', 'be'))
expect("\242\000\000\000\000\000\000\037", read(buffer("\037\000\000\000\000\000\000\242"), 'uint64', 'be'))
expect("\042\000\000\000\000\000\000\237", read(buffer("\237\000\000\000\000\000\000\042"), 'uint64', 'be'))
expect("\242\000\000\000\000\000\000\237", read(buffer("\237\000\000\000\000\000\000\242"), 'uint64', 'be'))

expect("\000\000\000\000\037\000\000\042", serialize(2^32*704643109, 'uint64', 'le'))
expect("\000\000\000\000\037\000\000\242", serialize(2^32*4060086309, 'uint64', 'le'))
expect("\000\000\000\000\237\000\000\042", serialize(2^32*704643309, 'uint64', 'le'))
expect("\000\000\000\000\237\000\000\242", serialize(2^32*4060086509, 'uint64', 'le'))

expect("\000\000\000\000\037\000\000\042", serialize(620757034, 'uint64', 'be'))
expect("\000\000\000\000\037\000\000\242", serialize(620757234, 'uint64', 'be'))
expect("\000\000\000\000\237\000\000\042", serialize(3976200234, 'uint64', 'be'))
expect("\000\000\000\000\237\000\000\242", serialize(3976200434, 'uint64', 'be'))

expect("\037\000\000\042\000\000\000\000", serialize(704643109, 'uint64', 'le'))
expect("\037\000\000\242\000\000\000\000", serialize(4060086309, 'uint64', 'le'))
expect("\237\000\000\042\000\000\000\000", serialize(704643309, 'uint64', 'le'))
expect("\237\000\000\242\000\000\000\000", serialize(4060086509, 'uint64', 'le'))

expect("\037\000\000\042\000\000\000\000", serialize(2^32*620757034, 'uint64', 'be'))
expect("\037\000\000\242\000\000\000\000", serialize(2^32*620757234, 'uint64', 'be'))
expect("\237\000\000\042\000\000\000\000", serialize(2^32*3976200234, 'uint64', 'be'))
expect("\237\000\000\242\000\000\000\000", serialize(2^32*3976200434, 'uint64', 'be'))

expect("\000\000\000\037\042\000\000\000", serialize(181009383424, 'uint64', 'le'))
expect("\000\000\000\037\242\000\000\000", serialize(1040002842624, 'uint64', 'le'))
expect("\000\000\000\237\042\000\000\000", serialize(184364826624, 'uint64', 'le'))
expect("\000\000\000\237\242\000\000\000", serialize(1043358285824, 'uint64', 'le'))

expect("\000\000\000\037\042\000\000\000", serialize(159618433024, 'uint64', 'be'))
expect("\000\000\000\037\242\000\000\000", serialize(162973876224, 'uint64', 'be'))
expect("\000\000\000\237\042\000\000\000", serialize(1018611892224, 'uint64', 'be'))
expect("\000\000\000\237\242\000\000\000", serialize(1021967335424, 'uint64', 'be'))

expect("\037\000\000\000\000\000\000\042", serialize("\037\000\000\000\000\000\000\042", 'uint64', 'le'))
expect("\037\000\000\000\000\000\000\242", serialize("\037\000\000\000\000\000\000\242", 'uint64', 'le'))
expect("\237\000\000\000\000\000\000\042", serialize("\237\000\000\000\000\000\000\042", 'uint64', 'le'))
expect("\237\000\000\000\000\000\000\242", serialize("\237\000\000\000\000\000\000\242", 'uint64', 'le'))

expect("\037\000\000\000\000\000\000\042", serialize("\042\000\000\000\000\000\000\037", 'uint64', 'be'))
expect("\037\000\000\000\000\000\000\242", serialize("\242\000\000\000\000\000\000\037", 'uint64', 'be'))
expect("\237\000\000\000\000\000\000\042", serialize("\042\000\000\000\000\000\000\237", 'uint64', 'be'))
expect("\237\000\000\000\000\000\000\242", serialize("\242\000\000\000\000\000\000\237", 'uint64', 'be'))

-- sint64

expect(0, read(buffer("\000\000\000\000\000\000\000\000"), 'sint64', 'le'))

expect(1, read(buffer("\001\000\000\000\000\000\000\000"), 'sint64', 'le'))
expect(255, read(buffer("\255\000\000\000\000\000\000\000"), 'sint64', 'le'))
expect(256, read(buffer("\000\001\000\000\000\000\000\000"), 'sint64', 'le'))
expect(256^2, read(buffer("\000\000\001\000\000\000\000\000"), 'sint64', 'le'))
expect(256^3, read(buffer("\000\000\000\001\000\000\000\000"), 'sint64', 'le'))
expect(256^4, read(buffer("\000\000\000\000\001\000\000\000"), 'sint64', 'le'))

expect(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4, read(buffer("\001\002\003\004\005\000\000\000"), 'sint64', 'le'))
expect(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4 + 6*256^5, read(buffer("\001\002\003\004\005\006\000\000"), 'sint64', 'le'))
expect(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4 + 6*256^5 + 7*256^6, read(buffer("\001\002\003\004\005\006\007\000"), 'sint64', 'le'))
expect(2*256^1 + 3*256^2 + 4*256^3 + 5*256^4 + 6*256^5 + 7*256^6 + 8*256^7, read(buffer("\000\002\003\004\005\006\007\008"), 'sint64', 'le'))
expect("\001\002\003\004\005\006\007\008", read(buffer("\001\002\003\004\005\006\007\008"), 'sint64', 'le'))

expect(-1, read(buffer("\255\255\255\255\255\255\255\255"), 'sint64', 'le'))
expect(-256, read(buffer("\000\255\255\255\255\255\255\255"), 'sint64', 'le'))
expect(-1-256, read(buffer("\255\254\255\255\255\255\255\255"), 'sint64', 'le'))
expect(-1-256^2, read(buffer("\255\255\254\255\255\255\255\255"), 'sint64', 'le'))
expect(-1-256^3, read(buffer("\255\255\255\254\255\255\255\255"), 'sint64', 'le'))
expect(-1-256^4, read(buffer("\255\255\255\255\254\255\255\255"), 'sint64', 'le'))

expect(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4, read(buffer("\254\253\252\251\250\255\255\255"), 'sint64', 'le'))
expect(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4 - 6*256^5, read(buffer("\254\253\252\251\250\249\255\255"), 'sint64', 'le'))
expect(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4 - 6*256^5 - 7*256^6, read(buffer("\254\253\252\251\250\249\248\255"), 'sint64', 'le'))
expect(- 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4 - 6*256^5 - 7*256^6 - 8*256^7, read(buffer("\000\254\252\251\250\249\248\247"), 'sint64', 'le'))

expect(0, read(buffer("\000\000\000\000\000\000\000\000"), 'sint64', 'be'))

expect(1, read(buffer("\000\000\000\000\000\000\000\001"), 'sint64', 'be'))
expect(255, read(buffer("\000\000\000\000\000\000\000\255"), 'sint64', 'be'))
expect(256, read(buffer("\000\000\000\000\000\000\001\000"), 'sint64', 'be'))
expect(256^2, read(buffer("\000\000\000\000\000\001\000\000"), 'sint64', 'be'))
expect(256^3, read(buffer("\000\000\000\000\001\000\000\000"), 'sint64', 'be'))
expect(256^4, read(buffer("\000\000\000\001\000\000\000\000"), 'sint64', 'be'))

expect(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4, read(buffer("\000\000\000\005\004\003\002\001"), 'sint64', 'be'))
expect(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4 + 6*256^5, read(buffer("\000\000\006\005\004\003\002\001"), 'sint64', 'be'))
expect(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4 + 6*256^5 + 7*256^6, read(buffer("\000\007\006\005\004\003\002\001"), 'sint64', 'be'))
expect(2*256^1 + 3*256^2 + 4*256^3 + 5*256^4 + 6*256^5 + 7*256^6 + 8*256^7, read(buffer("\008\007\006\005\004\003\002\000"), 'sint64', 'be'))
expect("\001\002\003\004\005\006\007\008", read(buffer("\008\007\006\005\004\003\002\001"), 'sint64', 'be'))

expect(-1, read(buffer("\255\255\255\255\255\255\255\255"), 'sint64', 'be'))
expect(-256, read(buffer("\255\255\255\255\255\255\255\000"), 'sint64', 'be'))
expect(-1-256, read(buffer("\255\255\255\255\255\255\254\255"), 'sint64', 'be'))
expect(-1-256^2, read(buffer("\255\255\255\255\255\254\255\255"), 'sint64', 'be'))
expect(-1-256^3, read(buffer("\255\255\255\255\254\255\255\255"), 'sint64', 'be'))
expect(-1-256^4, read(buffer("\255\255\255\254\255\255\255\255"), 'sint64', 'be'))

expect(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4, read(buffer("\255\255\255\250\251\252\253\254"), 'sint64', 'be'))
expect(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4 - 6*256^5, read(buffer("\255\255\249\250\251\252\253\254"), 'sint64', 'be'))
expect(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4 - 6*256^5 - 7*256^6, read(buffer("\255\248\249\250\251\252\253\254"), 'sint64', 'be'))
expect(- 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4 - 6*256^5 - 7*256^6 - 8*256^7, read(buffer("\247\248\249\250\251\252\254\000"), 'sint64', 'be'))

expect('integer', math.type(read(buffer("\001\002\003\004\005\000\000\000"), 'sint64', 'le')))
expect('integer', math.type(read(buffer("\001\002\003\004\005\006\000\000"), 'sint64', 'le')))
expect('integer', math.type(read(buffer("\001\002\003\004\005\006\007\000"), 'sint64', 'le')))
expect('integer', math.type(read(buffer("\000\002\003\004\005\006\007\008"), 'sint64', 'le')))
expect('integer', math.type(read(buffer("\254\253\252\251\250\255\255\255"), 'sint64', 'le')))
expect('integer', math.type(read(buffer("\254\253\252\251\250\249\255\255"), 'sint64', 'le')))
expect('integer', math.type(read(buffer("\254\253\252\251\250\249\248\255"), 'sint64', 'le')))
expect('integer', math.type(read(buffer("\000\254\252\251\250\249\248\247"), 'sint64', 'le')))

expect("\000\000\000\000\000\000\000\000", serialize(0, 'sint64', 'le'))

expect("\001\000\000\000\000\000\000\000", serialize(1, 'sint64', 'le'))
expect("\255\000\000\000\000\000\000\000", serialize(255, 'sint64', 'le'))
expect("\000\001\000\000\000\000\000\000", serialize(256, 'sint64', 'le'))
expect("\000\000\001\000\000\000\000\000", serialize(256^2, 'sint64', 'le'))
expect("\000\000\000\001\000\000\000\000", serialize(256^3, 'sint64', 'le'))
expect("\000\000\000\000\001\000\000\000", serialize(256^4, 'sint64', 'le'))

expect("\001\002\003\004\005\000\000\000", serialize(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4, 'sint64', 'le'))

expect("\255\255\255\255\255\255\255\255", serialize(-1, 'sint64', 'le'))
expect("\000\255\255\255\255\255\255\255", serialize(-256, 'sint64', 'le'))
expect("\255\254\255\255\255\255\255\255", serialize(-1-256, 'sint64', 'le'))
expect("\255\255\254\255\255\255\255\255", serialize(-1-256^2, 'sint64', 'le'))
expect("\255\255\255\254\255\255\255\255", serialize(-1-256^3, 'sint64', 'le'))
expect("\255\255\255\255\254\255\255\255", serialize(-1-256^4, 'sint64', 'le'))

expect("\254\253\252\251\250\255\255\255", serialize(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4, 'sint64', 'le'))

expect("\000\000\000\000\000\000\000\000", serialize(0, 'sint64', 'be'))

expect("\000\000\000\000\000\000\000\001", serialize(1, 'sint64', 'be'))
expect("\000\000\000\000\000\000\000\255", serialize(255, 'sint64', 'be'))
expect("\000\000\000\000\000\000\001\000", serialize(256, 'sint64', 'be'))
expect("\000\000\000\000\000\001\000\000", serialize(256^2, 'sint64', 'be'))
expect("\000\000\000\000\001\000\000\000", serialize(256^3, 'sint64', 'be'))
expect("\000\000\000\001\000\000\000\000", serialize(256^4, 'sint64', 'be'))

expect("\000\000\000\005\004\003\002\001", serialize(1*256^0 + 2*256^1 + 3*256^2 + 4*256^3 + 5*256^4, 'sint64', 'be'))

expect("\255\255\255\255\255\255\255\255", serialize(-1, 'sint64', 'be'))
expect("\255\255\255\255\255\255\255\000", serialize(-256, 'sint64', 'be'))
expect("\255\255\255\255\255\255\254\255", serialize(-1-256, 'sint64', 'be'))
expect("\255\255\255\255\255\254\255\255", serialize(-1-256^2, 'sint64', 'be'))
expect("\255\255\255\255\254\255\255\255", serialize(-1-256^3, 'sint64', 'be'))
expect("\255\255\255\254\255\255\255\255", serialize(-1-256^4, 'sint64', 'be'))

expect("\255\255\255\250\251\252\253\254", serialize(-1 -1*256^0 - 2*256^1 - 3*256^2 - 4*256^3 - 5*256^4, 'sint64', 'be'))

-- enum

local foo_e = _M.util.enum{
	bar = 1,
	baz = 2,
}

expect('bar', read(buffer("\001"), 'enum', foo_e, 'uint8'))
expect('baz', read(buffer("\002\000"), 'enum', foo_e, 'uint16', 'le'))

expect("\001", serialize('bar', 'enum', foo_e, 'uint8'))
expect("\002\000", serialize('baz', 'enum', foo_e, 'uint16', 'le'))

-- mapping

local foo_m = _M.util.enum{
	bar = 'A',
	baz = 'B',
}

expect('bar', read(buffer("A\000"), 'mapping', foo_m, 'cstring'))
expect('baz', read(buffer("\001B"), 'mapping', foo_m, 'bytes', 'uint8'))

expect("A\000", serialize('bar', 'mapping', foo_m, 'cstring'))
expect("\001B", serialize('baz', 'mapping', foo_m, 'bytes', 'uint8'))

-- flags

local foo_f = {
	bar = 1,
	baz = 2,
}

local value = read(buffer("\001"), 'flags', foo_f, 'uint8')
assert(value.bar==true and next(value, next(value))==nil)
local value = read(buffer("\003\000"), 'flags', foo_f, 'uint16', 'le')
assert(value.bar==true and value.baz==true and next(value, next(value, next(value)))==nil)

expect("\001", serialize({bar=true}, 'flags', foo_f, 'uint8'))
expect("\003\000", serialize({bar=true, baz=true}, 'flags', foo_f, 'uint16', 'le'))

-- bytes

expect('fo', read(buffer("fo"), 'bytes', 2))
expect('fo', read(buffer("foo"), 'bytes', 2))

expect("fo", serialize('fo', 'bytes', 2))

expect('fo', read(buffer("\002fo"), 'bytes', 'uint8'))
expect('fo', read(buffer("\002\000foo"), 'bytes', 'uint16', 'le'))

expect("\002fo", serialize('fo', 'bytes', 'uint8'))
expect("\002\000fo", serialize('fo', 'bytes', 'uint16', 'le'))

-- array

local value = read(buffer("\037\042"), 'array', 2, 'uint8')
assert(value[1]==37 and value[2]==42 and next(value, next(value, next(value)))==nil)
local value = read(buffer("\000\042\000\037"), 'array', '*', 'uint16', 'be')
assert(value[1]==42 and value[2]==37 and next(value, next(value, next(value)))==nil)

local value = read(buffer("\002\037\042\000"), 'array', {'uint8'}, 'uint8')
assert(value[1]==37 and value[2]==42 and next(value, next(value, next(value)))==nil)
local value = read(buffer("\002\000\000\037\000\042\038"), 'array', {'uint16', 'le'}, 'uint16', 'be')
assert(value[1]==37 and value[2]==42 and next(value, next(value, next(value)))==nil)
local value = read(buffer("\002\000\000\037\000\042\038"), 'array', {'uint16', 'le'}, {'uint16', 'be'})
assert(value[1]==37 and value[2]==42 and next(value, next(value, next(value)))==nil)

expect("\002\037\042", serialize({37, 42}, 'array', {'uint8'}, 'uint8'))
expect("\002\000\000\037\000\042", serialize({37, 42}, 'array', {'uint16', 'le'}, 'uint16', 'be'))
expect("\002\000\000\037\000\042", serialize({37, 42}, 'array', {'uint16', 'le'}, {'uint16', 'be'}))

-- paddedvalue

expect(37, read(buffer("\037\000\000"), 'paddedvalue', 3, '\000', 'uint8'))
expect(42, read(buffer("\004\042\000\000\000"), 'paddedvalue', {'uint8'}, '\000', 'uint8'))
expect(42, read(buffer("\004\042\000\000"), 'paddedvalue', {'uint8', included=true}, '\000', 'uint8'))
local value = read(buffer("\002\042"), 'paddedvalue', {'uint8', included=true}, '\000', {'array', 1, 'uint8'})
assert(type(value)=='table' and #value==1 and value[1]==42 and value.__trailing_bytes==nil)
local value = read(buffer("\005\042\000\000\000"), 'paddedvalue', {'uint8', included=true}, '\000', {'array', 1, 'uint8'})
assert(type(value)=='table' and #value==1 and value[1]==42 and value.__trailing_bytes==nil) -- :FIXME: we lost the information of how many padding bytes we had
local value = read(buffer("\005\042\000\000\001"), 'paddedvalue', {'uint8', included=true}, '\000', {'array', 1, 'uint8'})
assert(type(value)=='table' and #value==1 and value[1]==42 and value.__trailing_bytes=="\000\000\001")
local value = read(buffer("\005\042\001\000\00"), 'paddedvalue', {'uint8', included=true}, '\000', {'array', 1, 'uint8'})
assert(type(value)=='table' and #value==1 and value[1]==42 and value.__trailing_bytes=="\001") -- :FIXME: we lost the information of how many clean padding bytes we had

expect("\037\000\000", serialize(37, 'paddedvalue', 3, '\000', 'uint8'))
expect("\001\042", serialize(42, 'paddedvalue', {'uint8'}, '\000', 'uint8'))
expect("\002\042", serialize(42, 'paddedvalue', {'uint8', included=true}, '\000', 'uint8'))
expect("\002\042", serialize({42}, 'paddedvalue', {'uint8', included=true}, '\000', {'array', 1, 'uint8'}))
expect("\005\042\000\000\000", serialize({42, __trailing_bytes="\000\000\000"}, 'paddedvalue', {'uint8', included=true}, '\000', {'array', 1, 'uint8'}))
expect("\005\042\000\000\001", serialize({42, __trailing_bytes="\000\000\001"}, 'paddedvalue', {'uint8', included=true}, '\000', {'array', 1, 'uint8'}))

-- sizedvalue

local value = read(buffer("\037\000\000"), 'sizedvalue', 2, 'array', '*', 'uint8')
expect(nil, value[1]==37 and value[2]==0 and next(value, next(value, next(value))))
expect("foob", read(buffer("\000\004foobar"), 'sizedvalue', {'uint16', 'be'}, 'bytes', '*'))
expect("foob", read(buffer("\000\006foobar"), 'sizedvalue', {'uint16', 'be', included=true}, 'bytes', '*'))

expect("\037\000", serialize({37, 0}, 'sizedvalue', 2, 'array', '*', 'uint8'))
expect("\000\004foob", serialize("foob", 'sizedvalue', {'uint16', 'be'}, 'bytes', '*'))
expect("\000\006foob", serialize("foob", 'sizedvalue', {'uint16', 'be', included=true}, 'bytes', '*'))

-- cstring

expect("foo", read(buffer("foo\000bar"), 'cstring'))

-- float

--print(string.byte(serialize(-37e-12, 'float', 'le'), 1, 4))

expect('\239\154\006\086', serialize(37e12, 'float', 'le'))
expect('\157\094\212\135', serialize(-3.1953823392725e-34, 'float', 'le'))
expect(0, read(buffer("\000\000\000\000"), 'float', 'le'))
expect("0.0", tostring(read(buffer("\000\000\000\000"), 'float', 'le')))
expect(0, read(buffer("\000\000\000\128"), 'float', 'le'))
expect("-0.0", tostring(read(buffer("\000\000\000\128"), 'float', 'le')))
expect(1, read(buffer("\000\000\128\063"), 'float', 'le'))
expect(2, read(buffer("\000\000\000\064"), 'float', 'le'))
expect(42, read(buffer("\000\000\040\066"), 'float', 'le'))
expect(36999998210048, read(buffer("\239\154\006\086"), 'float', 'le')) -- best approx for 37e12 as float
expect(0.5, read(buffer("\000\000\000\063"), 'float', 'le'))
assert(math.abs(read(buffer("\010\215\163\060"), 'float', 'le') / 0.02 - 1) < 1e-7)
assert(math.abs(read(buffer("\076\186\034\046"), 'float', 'le') / 37e-12 - 1) < 1e-8)
expect(-1, read(buffer("\000\000\128\191"), 'float', 'le'))
expect(-2, read(buffer("\000\000\000\192"), 'float', 'le'))
expect(-42, read(buffer("\000\000\040\194"), 'float', 'le'))
assert(math.abs(read(buffer("\239\154\006\214"), 'float', 'le') / -37e12 - 1) < 1e-7)
assert(math.abs(read(buffer("\076\186\034\174"), 'float', 'le') / -37e-12 - 1) < 1e-8)
-- smallest normalized
expect("\000\000\128\000", serialize(2^-126, 'float', 'le'))
expect(2^-126, read(buffer("\000\000\128\000"), 'float', 'le'))
-- +inf
expect('\000\000\128\127', serialize(1/0, 'float', 'le'))
expect(1/0, read(buffer('\000\000\128\127'), 'float', 'le'))
-- -inf
expect('\000\000\128\255', serialize(-1/0, 'float', 'le'))
expect(-1/0, read(buffer('\000\000\128\255'), 'float', 'le'))
-- nan
expect('\000\000\192\255', serialize(0/0, 'float', 'le'))
local n = read(buffer('\000\000\192\255'), 'float', 'le')
assert(n~=n)
-- denormalized numbers
expect("\000\000\064\000", serialize(2^-127, 'float', 'le'))
expect(2^-127, read(buffer("\000\000\064\000"), 'float', 'le'))
expect("\001\000\000\000", serialize(2^-149, 'float', 'le'))
expect(2^-149, read(buffer("\001\000\000\000"), 'float', 'le'))

-- double

expect('\000\000\168\237\093\211\192\066', serialize(37e12, 'double', 'le'))
expect('\079\000\000\160\211\139\250\184', serialize(-3.1953823392725e-34, 'double', 'le'))
expect(0, read(buffer("\000\000\000\000\000\000\000\000"), 'double', 'le'))
expect("0.0", tostring(read(buffer("\000\000\000\000\000\000\000\000"), 'double', 'le')))
expect(0, read(buffer("\000\000\000\000\000\000\000\128"), 'double', 'le'))
expect("-0.0", tostring(read(buffer("\000\000\000\000\000\000\000\128"), 'double', 'le')))
expect(1, read(buffer("\000\000\000\000\000\000\240\063"), 'double', 'le'))
expect(2, read(buffer("\000\000\000\000\000\000\000\064"), 'double', 'le'))
expect(42, read(buffer("\000\000\000\000\000\000\069\064"), 'double', 'le'))
expect(37e12, read(buffer("\000\000\168\237\093\211\192\066"), 'double', 'le'))
expect(36999998210048, read(buffer("\000\000\000\224\093\211\192\066"), 'double', 'le')) -- best float approx for 37e12
expect(0.5, read(buffer("\000\000\000\000\000\000\224\063"), 'double', 'le'))
assert(math.abs(read(buffer("\123\020\174\071\225\122\148\063"), 'double', 'le') / 0.02 - 1) < 1e-7)
assert(math.abs(read(buffer("\164\022\093\125\073\087\196\061"), 'double', 'le') / 37e-12 - 1) < 1e-8)
expect(-1, read(buffer("\000\000\000\000\000\000\240\191"), 'double', 'le'))
expect(-2, read(buffer("\000\000\000\000\000\000\000\192"), 'double', 'le'))
expect(-42, read(buffer("\000\000\000\000\000\000\069\192"), 'double', 'le'))
assert(math.abs(read(buffer("\000\000\168\237\093\211\192\194"), 'double', 'le') / -37e12 - 1) < 1e-7)
assert(math.abs(read(buffer("\164\022\093\125\073\087\196\189"), 'double', 'le') / -37e-12 - 1) < 1e-8)
-- smallest normalized
expect("\000\000\000\000\000\000\016\000", serialize(2^-1022, 'double', 'le'))
expect(2^-1022, read(buffer("\000\000\000\000\000\000\016\000"), 'double', 'le'))
-- +inf
expect('\000\000\000\000\000\000\240\127', serialize(1/0, 'double', 'le'))
expect(1/0, read(buffer('\000\000\000\000\000\000\240\127'), 'double', 'le'))
-- -inf
expect('\000\000\000\000\000\000\240\255', serialize(-1/0, 'double', 'le'))
expect(-1/0, read(buffer('\000\000\000\000\000\000\240\255'), 'double', 'le'))
-- nan
expect('\000\000\000\000\000\000\248\255', serialize(0/0, 'double', 'le'))
local n = read(buffer('\000\000\000\000\000\000\248\255'), 'double', 'le')
assert(n~=n)
-- denormalized numbers
expect("\000\000\000\000\000\000\008\000", serialize(2^-1023, 'double', 'le'))
expect("\001\000\000\000\000\000\000\000", serialize(2^-1074, 'double', 'le'))
expect(2^-1023, read(buffer("\000\000\000\000\000\000\008\000"), 'double', 'le'))
expect(2^-1074, read(buffer("\001\000\000\000\000\000\000\000"), 'double', 'le'))

-- bytes2hex

expect('666F', read(buffer("fo"), 'bytes2hex', 2))
expect('666F', read(buffer("foo"), 'bytes2hex', 2))

expect("fo", serialize('666F', 'bytes2hex', 2))

-- bytes2base32

expect('MZXW6YTB', read(buffer("fooba"), 'bytes2base32', 5))
expect('MZXW6YTB', read(buffer("foobar"), 'bytes2base32', 5))

expect("fooba", serialize('MZXW6YTB', 'bytes2base32', 5))

-- boolean

expect(false, read(buffer("\000"), 'boolean', 'uint8'))
expect(true, read(buffer("\000\001"), 'boolean', 'uint16', 'be'))
expect(2, read(buffer("\002\000"), 'boolean', 'sint16', 'le'))

expect("\000", serialize(false, 'boolean', 'uint8'))
expect("\000\001", serialize(true, 'boolean', 'uint16', 'be'))
expect("\002\000", serialize(2, 'boolean', 'sint16', 'le'))

-- boolean8

expect(false, read(buffer("\000"), 'boolean8'))
expect(true, read(buffer("\001"), 'boolean8'))
expect(2, read(buffer("\002\000"), 'boolean8'))

expect("\000", serialize(false, 'boolean8'))
expect("\001", serialize(true, 'boolean8'))
expect("\002", serialize(2, 'boolean8'))

-- truenil

expect(nil, read(buffer("\000"), 'truenil', 'uint8'))
expect(true, read(buffer("\000\001"), 'truenil', 'uint16', 'be'))
expect(2, read(buffer("\002\000"), 'truenil', 'sint16', 'le'))

expect("\000", serialize(nil, 'truenil', 'uint8'))
expect("\000\001", serialize(true, 'truenil', 'uint16', 'be'))
expect("\002\000", serialize(2, 'truenil', 'sint16', 'le'))

-- default

expect(nil, read(buffer("\000"), 'default', 0, 'uint8'))
expect(1, read(buffer("\001"), 'default', 0, 'uint8'))

expect("\000", serialize(nil, 'default', 0, 'uint8'))
expect("\000", serialize(0, 'default', 0, 'uint8'))
expect("\001", serialize(1, 'default', 0, 'uint8'))

-- struct

local foo_s = {
	{'foo', 'uint8'},
	{'bar', 'uint16', 'be'},
}
_M.struct.foo_s = foo_s

local value = read(buffer("\001\002\003\004"), 'struct', foo_s)
assert(value.foo==1 and value.bar==515 and next(value, next(value, next(value)))==nil)
local value = read(buffer("\001\002\003\004"), 'foo_s')
assert(value.foo==1 and value.bar==515 and next(value, next(value, next(value)))==nil)
expect("\001\002\003", serialize({foo=1, bar=515}, 'foo_s'))
expect(false, pcall(serialize, {foo=1, bar=nil}, 'foo_s'))
assert(select(2, pcall(serialize, {foo=1, bar=nil}, 'foo_s')):match("value is not a number"))

-- fstruct

function _M.fstruct.foo_fs(self)
	self 'foo' ('uint8')
	self 'bar' ('uint16', 'be')
end

local value = read(buffer("\001\002\003\004"), 'foo_fs')
assert(value.foo==1 and value.bar==515 and next(value, next(value, next(value)))==nil)
expect("\001\002\003", serialize(value, 'foo_fs'))

-- buffers

local b = buffer("\042\037")
-- 0010010100101010
expect('\0\1\0', b:getbits(3))
expect('\1\0\1\0\0\1\0\1', b:getbits(8))

local b = buffer("\042\037")
b.byte_endianness = 'be'
-- 0010101000100101
expect('\0\0\1', b:getbits(3))
expect('\0\1\0\1\0\0\0\1', b:getbits(8))

local b = buffer("")
assert(b:putbytes("\042"))
expect("\042", b:peekbytes(1))
expect("\042", b:getbytes(1))
expect("", b:getbytes(1))
assert(b:putbits('\0\1\0'))
assert(b:putbits('\1\0\1\0\0'))
local bytes = b:getbytes(1)
expect("\042", bytes)

-- filestream

do
	local io = require 'io'
	local file = io.tmpfile()
	local out = _M.filestream(file)
	write(out, "foo", 'bytes', 3)
	write(out, "bar", 'cstring')
	file:seek('set', 0)
	local in_ = _M.filestream(file)
	expect("foob", in_:peekbytes(4))
	expect("foobar", read(in_, 'cstring'))
	file:close()
end

-- tcp stream

local socket
if pcall(function() socket = require 'socket' end) then
	local server,port
	for i=1,10 do
		port = 50000+i
		server = socket.bind('*', port)
		if server then break end
	end
	if server then
		local a = socket.connect('127.0.0.1', port)
		local b = server:accept()
		local out = _M.tcpstream(a)
		write(out, "foo", 'bytes', 3)
		write(out, "bar", 'cstring')
		local in_ = _M.tcpstream(b)
		a:send("foo")
		expect("foob", in_:peekbytes(4))
		expect("foobar", read(in_, 'cstring'))
	else
		print("cannot test tcp streams (could not bind a server socket)")
	end
else
	print("cannot test tcp streams (optional dependency 'socket' missing)")
end

-- uint

-- \042\037 -> 0101010010100100
expect(2+8, read(buffer("\042\037"), 'uint', 4, 'le'))
expect(1+4, read(buffer("\042\037"), 'uint', 4, 'be'))

local b = buffer("\042\037\000")
b.byte_endianness = 'be'
-- \042\037 'be' -> 0010101000100101
expect(4, read(b, 'uint', 4, 'le'))
expect(81, read(b, 'uint', 7, 'be'))
expect(5+8, b:bitlength())

expect(2+8+32+256+1024, read(buffer("\042\037"), 'uint', 13, 'le')) -- 0101010010100 100
expect(4+16+64+1024, read(buffer("\042\037", 'be'), 'uint', 13, 'le')) -- 0010101000100 101
expect(4+16+64+1024+8192+32768, read(buffer("\042\037", 'be'), 'uint', '*', 'le')) -- 0010101000100101

local t = read(buffer("\042\037"), 'array', 13, 'uint', 1) -- 0101010010100 100
expect('table', type(t))
expect(13, #t)
expect(0, t[1])
expect(1, t[4])
expect(0, t[7])
expect(1, t[11])
expect(0, t[13])

local b = buffer("")
write(b, {0,1,0,1,0,1,0,0,1,0,1,0,0}, 'array', 13, 'uint', 1) -- 0101010010100
expect("\042", b:getbytes(2)) -- only full bytes are commited to the buffer
write(b, {1,0,0}, 'array', 3, 'uint', 1) -- 100
expect("\037", b:getbytes('*'))

assert(not serialize(0, 'uint', 1))
expect("\0", serialize(0, 'uint', 8, 'le'))

-- sint

-- \170\037 -> 1101010010100100
expect(-6, read(buffer("\170\037"), 'sint', 4, 'le'))
expect(5, read(buffer("\170\037"), 'sint', 4, 'be'))

expect("\000", serialize(0, 'sint', 8, 'le'))
expect("\255\255\063", serialize(4194303, 'sint', 24, 'le'))

-- constant

local value,err = read(buffer("\237\042"), 'constant', 10989, 'uint16', 'le')
assert(value==nil and err==nil)

expect('\239\154\006\086', serialize(nil, 'constant', 37e12, 'float', 'le'))

_M.struct.s_const = {
	{'const', 'constant', 42, 'uint8'},
	{'var', 'uint8'},
}

local value,err = read(buffer("\042\086"), 's_const')
expect('table', type(value))
expect('var', next(value))
expect(nil, next(value, 'var'))
expect(86, value.var)

assert(serialize({
	var = 87,
}, 's_const')=='\042\087')

-- taggedvalue

_M.alias.tv_plain = {'taggedvalue', {'uint8'}, {
	{'uint8'},
	{'uint16', 'le'},
}}

local value = assert(read(buffer("\001\042"), 'tv_plain'))
expect('table', type(value))
assert(next(value)=='tag' or next(value)=='value')
assert(next(value, 'tag')==nil or next(value, 'tag')=='value')
assert(next(value, 'value')==nil or next(value, 'value')=='tag')
expect(1, value.tag)
expect(42, value.value)
local value = assert(read(buffer("\002\237\037"), 'tv_plain'))
expect('table', type(value))
assert(next(value)=='tag' or next(value)=='value')
assert(next(value, 'tag')==nil or next(value, 'tag')=='value')
assert(next(value, 'value')==nil or next(value, 'value')=='tag')
expect(2, value.tag)
expect(9709, value.value)

expect("\001\042", serialize({tag=1, value=42}, 'tv_plain'))
expect("\002\237\037", serialize({tag=2, value=9709}, 'tv_plain'))


_M.alias.tv_selector = {'taggedvalue', {'cstring'}, {
	number = {'uint8'},
	string = {'cstring'},
}, type} -- use standard Lua 'type' function as selector

expect(42, read(buffer("number\000\042"), 'tv_selector'))
expect("foo", read(buffer("string\000foo\000"), 'tv_selector'))

expect("number\000\042", serialize(42, 'tv_selector'))
expect("string\000foo\000", serialize("foo", 'tv_selector'))


_M.alias.tv_selector2 = {'taggedvalue', {'cstring'}, {
	u8 = {'struct', {{'content', 'uint8'}}},
	u16 = {'struct', {{'content', 'uint16', 'le'}}},
}, 'type'} -- use 'type' field as selector

local value = assert(read(buffer("u8\000\042"), 'tv_selector2'))
expect('table', type(value))
assert(next(value)=='type' or next(value)=='content')
assert(next(value, 'type')==nil or next(value, 'type')=='content')
assert(next(value, 'content')==nil or next(value, 'content')=='type')
expect('u8', value.type)
expect(42, value.content)
local value = assert(read(buffer("u16\000\237\037"), 'tv_selector2'))
expect('table', type(value))
assert(next(value)=='type' or next(value)=='content')
assert(next(value, 'type')==nil or next(value, 'type')=='content')
assert(next(value, 'content')==nil or next(value, 'content')=='type')
expect('u16', value.type)
expect(9709, value.content)

expect("u8\000\042", serialize({type='u8', content=42}, 'tv_selector2'))
expect("u16\000\237\037", serialize({type='u16', content=9709}, 'tv_selector2'))

-- empty

expect("", serialize("foo", 'empty', "foo"))
expect(42, read("", 'empty', 42))

-- alias

_M.alias.alias1_t = {'uint32', 'le'}

expect(704643109, read(buffer("\037\000\000\042"), 'alias1_t'))
expect("\037\000\000\042", serialize(704643109, 'alias1_t'))

_M.alias.alias2_t = 'uint8'

expect(37, read(buffer("\037\000\000\042"), 'alias2_t'))
expect("\037", serialize(37, 'alias2_t'))

_M.alias.alias3_t = function(foo, endianness) return 'uint32',endianness end

expect(704643109, read(buffer("\037\000\000\042"), 'alias3_t', 'foo', 'le'))
expect("\037\000\000\042", serialize(704643109, 'alias3_t', 'foo', 'le'))

_M.alias.alias4_t = function(endianness, size_t, ...) return 'array', {size_t, ...}, 'uint32', endianness end

local value = read(buffer("\000\002\042\000\000\000\037\000\000\000"), 'alias4_t', 'le', 'uint16', 'be')
assert(type(value)=='table' and value[1]==42 and value[2]==37 and next(value, next(value, next(value)))==nil)
expect("\000\002\042\000\000\000\037\000\000\000", serialize({42, 37}, 'alias4_t', 'le', 'uint16', 'be'))

_M.alias.alias5_t = {'constant', '%1', 'cstring'} -- %n were only briefly supported

expect("%1\000", serialize(nil, 'alias5_t', 'foo'))
local value,err = read(buffer("%1\000"), 'alias5_t', 'foo')
expect(nil, value)
expect(nil, err)
local value,err = read(buffer("%1"), 'alias5_t', 'foo')
assert(value==nil and type(err)=='string' and err:match('^end of stream:'))

_M.alias.alias6_t = function(str) return 'constant', str, 'cstring' end

expect("foo\000", serialize(nil, 'alias6_t', 'foo'))
local value,err = read(buffer("foo\000"), 'alias6_t', 'foo')
assert(value==nil and err==nil)
local value,err = read(buffer("foo"), 'alias6_t', 'foo')
assert(value==nil and type(err)=='string' and err:match('^end of stream:'))

--

for _,func in ipairs(funcs) do
	if not tested[func] then
		print("serialization function '"..func.."' has not been tested")
	end
end

--

print("all tests passed successfully")

end

return _M

--[[
Copyright (c) Jérôme Vuarand

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
]]

-- vi: ts=4 sts=4 sw=4 noet
