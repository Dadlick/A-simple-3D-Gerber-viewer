local _M = {}
local _NAME = ... or 'test'

local math = require 'math'
local table = require 'table'
local string = require 'string'
local core
if not pcall(function()
	core = require 'unicode.core'
end) then core = nil end

if _NAME == 'test' then
	require 'test'
end

local unpack = table.unpack or unpack

local function string_to_numbers(str, size, endianness)
	assert(size==1 or endianness=='be' or endianness=='le', "unsupported endianness '"..tostring(endianness).."'")
	assert(#str%size==0, "string length is not a multiple of "..tostring(size))
	local bytes
	local n = 65536
	if #str <= n then
		bytes = {str:byte(1, #str)}
	else
		bytes = {}
		for i=1,#str,n do
			local t = {str:byte((i-1)*n + 1, i*n)}
			for j=1,#t do
				bytes[(i-1)*n + j] = t[j]
			end
		end
	end
	local numbers = {}
	local i = 1
	while i<=#bytes do
		local number = 0
		for j=1,size do
			if size==1 then
				number = bytes[i]
			elseif endianness=='be' then
				number = number*2^8 + bytes[i]
			elseif endianness=='le' then
				number = number + bytes[i]*2^(8*(j-1))
			end
			i = i+1
		end
		table.insert(numbers, number)
	end
	return numbers
end

if _NAME=='test' then
	local A,_0 = string.byte('A\0', 1, 2)
	expect({A}, string_to_numbers("A", 1))
	expect({A}, string_to_numbers("A", 1, 'be'))
	expect({_0, A}, string_to_numbers("\0A", 1))
	expect({A, _0}, string_to_numbers("A\0", 1))
	expect({A}, string_to_numbers("A", 1, 'le'))
	expect({A}, string_to_numbers("\0A", 2, 'be'))
	expect({A}, string_to_numbers("A\0", 2, 'le'))
	expect({A*0x100}, string_to_numbers("A\0", 2, 'be'))
	expect({A*0x100}, string_to_numbers("\0A", 2, 'le'))
	expect({_0, A}, string_to_numbers("\0\0\0A", 2, 'be'))
	expect({_0, A}, string_to_numbers("\0\0A\0", 2, 'le'))
	expect({A, _0}, string_to_numbers("\0A\0\0", 2, 'be'))
	expect({A, _0}, string_to_numbers("A\0\0\0", 2, 'le'))
end

local function numbers_to_string(numbers, size, endianness)
	assert(size==1 or endianness=='be' or endianness=='le', "unsupported endianness '"..tostring(endianness).."'")
	local bytes = {}
	for _,number in ipairs(numbers) do
		if size==1 then
			table.insert(bytes, number%2^8)
		elseif endianness=='be' then
			for j=size-1,0,-1 do
				local byte = math.floor(number/2^(8*j))%2^8
				table.insert(bytes, byte)
				number = number - byte*2^(8*j)
			end
		elseif endianness=='le' then
			for j=size-1,0,-1 do
				local byte = number%2^8
				table.insert(bytes, byte)
				number = math.floor(number/2^8)
			end
		end
	end
	return string.char(unpack(bytes))
end

if _NAME=='test' then
	local A = string.byte('A')
	expect("A", numbers_to_string({A}, 1))
	expect("A", numbers_to_string({A}, 1, 'be'))
	expect("A", numbers_to_string({A}, 1, 'le'))
	expect("\0A", numbers_to_string({A}, 2, 'be'))
	expect("A\0", numbers_to_string({A}, 2, 'le'))
	expect("A\0", numbers_to_string({A*0x100}, 2, 'be'))
	expect("\0A", numbers_to_string({A*0x100}, 2, 'le'))
end

local function utf8_to_ucs4(utf8)
	local ucs4 = {}
	local i = 1
	local c,csize
	while i<=#utf8 do
		local u = utf8[i]
		if u<=0x7F then -- 0xxxxxxx
			assert(not c, "ascii character in the middle of a multi-byte character")
			table.insert(ucs4, u)
		elseif u<=0xBF then -- 10xxxxxx
			assert(c, "trailing byte not in the middle of a multi-byte character")
			c = c * 2^6 + u-0x80
			csize = csize-1
			if csize==0 then
				table.insert(ucs4, c)
				c,csize = nil,nil
			end
		else
			assert(not c, "starting byte in the middle of a multi-byte character")
			-- Count bits at 1
			csize = 0
			assert(u~=0xff, "multi-byte characters of 8 bytes or more are not supported")
			for _,bit in ipairs{0x80,0x40,0x20,0x10,0x08,0x04,0x02,0x01} do
				if u>=bit then
					csize = csize+1
					u = u-bit
				else
					break
				end
			end
			c = u
			csize = csize-1
		end
		i = i+1
	end
	return ucs4
end

local function ucs4_to_utf8(ucs4)
	local utf8 = {}
	for _,number in ipairs(ucs4) do
		if number <= 0x7f then
			table.insert(utf8, number)
		else
			-- chop in groups of 6 bits (in little endian order)
			local sextets = {}
			while number > 0 do
				local sextet = number % 2^6
				table.insert(sextets, sextet)
				number = (number - sextet) / 2^6
			end
			assert(#sextets <= 7)
			-- determine the number of significant bits in the higher order sextet
			local first = sextets[#sextets]
			local bits = 0
			while first >= 2^bits do
				bits = bits + 1
			end
			assert(bits >= 1 and bits <= 6)
			-- prefix is one 1 per octet, a 0, some 0 for padding, and the first sextet
			-- we can fit (8-1-bits) 1s in the first sextet octet
			local maxpackedones = 8 - 1 - bits
			local packedones
			if #sextets <= maxpackedones then
				-- all ones fit in the first sextet octet
				-- insert an octet with the 1s of the prefix on the high side,
				-- 0 padding (at least one bit), and the first sextet on the
				-- low side
				local ones = #sextets
				local zeros = 8 - ones - bits
				assert(zeros >= 1 and zeros <= 8)
				local prefix = (2^ones - 1) * 2^(zeros + bits) + first
				table.insert(utf8, prefix)
				table.remove(sextets) -- the first sextet won't have to be processed
			else
				-- insert a dedicated prefix octet with the number of sextets
				-- plus one (to account for the additionnal octet)
				local ones = #sextets + 1
				local zeros = 8 - ones
				local prefix = (2^ones - 1) * 2^zeros
				table.insert(utf8, prefix)
			end
			-- then add all remaining sextets in big endian order, with a
			-- binary 10xxxxxx prefix
			for i=#sextets,1,-1 do
				local sextet = sextets[i]
				local octet = 0x80 + sextet
				table.insert(utf8, octet)
			end
		end
	end
	return utf8
end

if _NAME=='test' then
	local utf8samples = {
		[0] = {0x00},
		[31] = {0x1F},
		[32] = {0x20},
		[65] = {0x41},
		[126] = {0x7E},
		[127] = {0x7F},
		[128] = {0xC2, 0x80},
		[159] = {0xC2, 0x9F},
		[160] = {0xC2, 0xA0},
		[233] = {0xC3, 0xA9},
		[2047] = {0xDF, 0xBF},
		[2048] = {0xE0, 0xA0, 0x80},
		[8364] = {0xE2, 0x82, 0xAC},
		[55295] = {0xED, 0x9F, 0xBF},
		[57344] = {0xEE, 0x80, 0x80},
		[63743] = {0xEF, 0xA3, 0xBF},
		[63744] = {0xEF, 0xA4, 0x80},
		[64975] = {0xEF, 0xB7, 0x8F},
		[64976] = {0xEF, 0xB7, 0x90},
		[65007] = {0xEF, 0xB7, 0xAF},
		[65008] = {0xEF, 0xB7, 0xB0},
		[65533] = {0xEF, 0xBF, 0xBD},
		[65534] = {0xEF, 0xBF, 0xBE},
		[65535] = {0xEF, 0xBF, 0xBF},
		[65536] = {0xF0, 0x90, 0x80, 0x80},
		[119070] = {0xF0, 0x9D, 0x84, 0x9E},
		[131069] = {0xF0, 0x9F, 0xBF, 0xBD},
		[131070] = {0xF0, 0x9F, 0xBF, 0xBE},
		[131071] = {0xF0, 0x9F, 0xBF, 0xBF},
		[131072] = {0xF0, 0xA0, 0x80, 0x80},
		[196605] = {0xF0, 0xAF, 0xBF, 0xBD},
		[196606] = {0xF0, 0xAF, 0xBF, 0xBE},
		[196607] = {0xF0, 0xAF, 0xBF, 0xBF},
		[917504] = {0xF3, 0xA0, 0x80, 0x80},
		[983037] = {0xF3, 0xAF, 0xBF, 0xBD},
		[983038] = {0xF3, 0xAF, 0xBF, 0xBE},
		[983039] = {0xF3, 0xAF, 0xBF, 0xBF},
		[983040] = {0xF3, 0xB0, 0x80, 0x80},
		[1048573] = {0xF3, 0xBF, 0xBF, 0xBD},
		[1048574] = {0xF3, 0xBF, 0xBF, 0xBE},
		[1048575] = {0xF3, 0xBF, 0xBF, 0xBF},
		[1048576] = {0xF4, 0x80, 0x80, 0x80},
		[1114109] = {0xF4, 0x8F, 0xBF, 0xBD},
		[1114110] = {0xF4, 0x8F, 0xBF, 0xBE},
		[1114111] = {0xF4, 0x8F, 0xBF, 0xBF},
	}
	local A = string.byte("A")
	
	expect({A}, utf8_to_ucs4({string.byte("A")}))
	expect({0xE9}, utf8_to_ucs4({0xC3, 0xA9}))
	for ucs4ref,utf8ref in pairs(utf8samples) do
		expect({ucs4ref}, utf8_to_ucs4(utf8ref))
	end
	
	expect({A}, ucs4_to_utf8({string.byte("A")}))
	expect({0xC3, 0xA9}, ucs4_to_utf8({0xE9}))
	for ucs4ref,utf8ref in pairs(utf8samples) do
		expect(utf8ref, ucs4_to_utf8({ucs4ref}))
	end
	
	expect({0xC3, 0x98}, ucs4_to_utf8({0xD8}))
end

local function utf16_to_ucs4(utf16)
	local ucs4 = {}
	local i = 1
	while i<=#utf16 do
		local u = utf16[i]
		if u >= 0xD800 and u<=0xDBFF -- surrogate lead
			and (i+1 <= #utf16) and utf16[i+1] >= 0xDC00 and utf16[i+1] <= 0xDFFF -- trail
			then
			local upperbits = u - 0xD800
			local lowerbits = utf16[i+1] - 0xDC00
			table.insert(ucs4, upperbits * 2^10 + lowerbits)
			i = i + 1
		else
			table.insert(ucs4, u)
		end
		i = i + 1
	end
	return ucs4
end

local function ucs4_to_utf16(ucs4)
	local utf16 = {}
	for _,number in ipairs(ucs4) do
		assert(number <= 0x10FFFF, "number outside range representable in utf16")
		if number >= 0x10000 and number <= 0x10FFFF then
			-- Use surrogates
			local upperbits = math.floor(number/2^10)
			local lowerbits = number - upperbits*2^10
			table.insert(utf16, 0xD800 + upperbits)
			table.insert(utf16, 0xDC00 + lowerbits)
		else
			assert(number<0xD800 or number>0xDFFF, "number is not representable in utf16 (codepoint is used for surrogates)")
			table.insert(utf16, number)
		end
	end
	return utf16
end

if _NAME=='test' then
	local A = string.byte("A")
	expect({A}, ucs4_to_utf16({A}))
	expect({A}, utf16_to_ucs4({A}))
	expect({0xD880, 0xDC00}, ucs4_to_utf16({0x20000}))
	expect({0x20000}, utf16_to_ucs4({0xD880, 0xDC00}))
end

local function ucs2_to_ucs4(ucs2)
	local ucs4 = {}
	local i = 1
	while i<=#ucs2 do
		local u = ucs2[i]
		table.insert(ucs4, u)
		i = i + 1
	end
	return ucs4
end

local function ucs4_to_ucs2(ucs4)
	local ucs2 = {}
	for _,number in ipairs(ucs4) do
		assert(number <= 0xFFFF, "number outside range representable in ucs2")
		table.insert(ucs2, number)
	end
	return ucs2
end

if _NAME=='test' then
	local A = string.byte("A")
	expect({A}, ucs4_to_ucs2({A}))
	expect({A}, ucs2_to_ucs4({A}))
end

local identity = function(...) return ... end

local function ucs4_to_iso8859_1(ucs4)
	local iso8859 = {}
	for _,number in ipairs(ucs4) do
		assert(number <= 0xFF, "number outside range representable in iso8859-1")
		table.insert(iso8859, number)
	end
	return iso8859
end

local baseformat = 'ucs-4'
local converters = {
	['utf-8'] = {
		['ucs-4'] = utf8_to_ucs4;
	};
	['iso8859-1'] = {
		['ucs-4'] = identity;
	};
	['utf-16le'] = {
		['ucs-4'] = utf16_to_ucs4;
	};
	['utf-16be'] = {
		['ucs-4'] = utf16_to_ucs4;
	};
	['ucs-2le'] = {
		['ucs-4'] = ucs2_to_ucs4;
	};
	['ucs-2be'] = {
		['ucs-4'] = ucs2_to_ucs4;
	};
	['ucs-4'] = {
		['utf-8'] = ucs4_to_utf8;
		['iso8859-1'] = ucs4_to_iso8859_1;
		['utf-16le'] = ucs4_to_utf16;
		['utf-16be'] = ucs4_to_utf16;
		['ucs-2le'] = ucs4_to_ucs2;
		['ucs-2be'] = ucs4_to_ucs2;
	};
}
local s2t = {
	['utf-8'] = function(str) return string_to_numbers(str, 1) end,
	['iso8859-1'] = function(str) return string_to_numbers(str, 1) end,
	['utf-16le'] = function(str) return string_to_numbers(str, 2, 'le') end,
	['utf-16be'] = function(str) return string_to_numbers(str, 2, 'be') end,
	['ucs-2le'] = function(str) return string_to_numbers(str, 2, 'le') end,
	['ucs-2be'] = function(str) return string_to_numbers(str, 2, 'be') end,
}
local t2s = {
	['utf-8'] = function(str) return numbers_to_string(str, 1) end,
	['iso8859-1'] = function(str) return numbers_to_string(str, 1) end,
	['utf-16le'] = function(str) return numbers_to_string(str, 2, 'le') end,
	['utf-16be'] = function(str) return numbers_to_string(str, 2, 'be') end,
	['ucs-2le'] = function(str) return numbers_to_string(str, 2, 'le') end,
	['ucs-2be'] = function(str) return numbers_to_string(str, 2, 'be') end,
}

function _M.convert(str, from, to, outputtype)
	outputtype = outputtype or 'string'
	assert(type(str)=='string' or type(str)=='table', "input data is not a string or a table")
	assert(outputtype=='string' or outputtype=='table', "output type is not 'string' or 'table'")
	if to~=from then
		assert(converters[from] and converters[from][baseformat] or from==baseformat, "input format '"..tostring(from).."' not yet supported")
		assert(converters[baseformat] and converters[baseformat][to] or to==baseformat, "output format '"..tostring(to).."' not yet supported")
	end
	local input,output
	if type(str)=='string' then
		local s2t = assert(s2t[from], "input format '"..tostring(from).."' not yet supported")
		input = s2t(str)
	else
		input = str
	end
	if to==from then
		output = input
	else
		local base
		if from==baseformat then
			base = input
		elseif converters[from] and converters[from][baseformat] then
			base = converters[from][baseformat](input)
		end
		assert(base)
		if to==baseformat then
			output = base
		elseif converters[baseformat] and converters[baseformat][to] then
			output = converters[baseformat][to](base)
		end
		assert(output)
	end
	if outputtype=='string' then
		local t2s = assert(t2s[to], "output format '"..tostring(to).."' not yet supported")
		return t2s(output)
	else
		return output
	end
end

if _NAME=='test' then
	expect("A\0", _M.convert("A", 'utf-8', 'utf-16le'))
	expect({0xF0, 0xA0, 0x80, 0x80}, _M.convert({0xD880, 0xDC00}, 'utf-16le', 'utf-8', 'table'))
	expect(string.char(0xF0, 0xA0, 0x80, 0x80), _M.convert(string.char(0xD8, 0x80, 0xDC, 0x00), 'utf-16be', 'utf-8'))
	expect(string.char(0xF0, 0xA0, 0x80, 0x80), _M.convert(string.char(0x80, 0xD8, 0x00, 0xDC), 'utf-16le', 'utf-8'))
end

if core then
	_M.collate_utf8 = core.collate_utf8
	if _NAME=='test' then
		local loc = 'en_US.UTF-8'
		expect(0, _M.collate_utf8(loc, "A", "A"))
		expect(1, _M.collate_utf8(loc, "A", "a"))
		expect(-1, _M.collate_utf8(loc, "a", "A"))
		expect(1, _M.collate_utf8(loc, "à", "a"))
		expect(1, _M.collate_utf8(loc, "é", "e"))
		expect(1, _M.collate_utf8(loc, "Neon Genesis Evangelion", "Monster"))
		expect(-1, _M.collate_utf8(loc, "Neon Genesis Evangelion", "Rurouni Kenshin"))
	end
end

if _NAME=='test' then
	print "All tests succeeded."
end

return _M
