local _M = {}

local math = require 'math'
local table = require 'table'
local string = require 'string'

local debug = false

local optim
do
	local success,err = pcall(function() optim = require 'serial.optim' end)
	if not success and not err:match("module 'serial%.optim' not found") then
		error(err)
	end
end

local tinsert = table.insert
local tconcat = table.concat
local sformat = string.format
local schar = string.char
local mfloor = math.floor
local tonumber = tonumber
local unpack = unpack or table.unpack

_M.enum_names = {}

function _M.enum(name2value, name)
	local self = {}
	for k,v in pairs(name2value) do
		self[k] = v
		self[v] = k
	end
	if name then
		_M.enum_names[name] = self
	end
	return self
end

if optim and optim.bin2hex then
	_M.bin2hex = optim.bin2hex
else
	function _M.bin2hex(bin)
		local hex = {}
		bin = {bin:byte(1,#bin)}
		for i=1,#bin do
			tinsert(hex, sformat("%X%X", mfloor(bin[i]/16), bin[i]%16))
		end
		return tconcat(hex)
	end
end

if optim and optim.hex2bin then
	_M.hex2bin = optim.hex2bin
else
	function _M.hex2bin(hex)
		local bin = {}
		for i=1,#hex/2 do
			tinsert(bin, schar(tonumber("0X"..hex:sub(2*i-1, 2*i))))
		end
		return tconcat(bin)
	end
end

local conversion = {}
conversion.b16b2 = {
	["0"] = "0000",
	["1"] = "0001",
	["2"] = "0010",
	["3"] = "0011",
	["4"] = "0100",
	["5"] = "0101",
	["6"] = "0110",
	["7"] = "0111",
	["8"] = "1000",
	["9"] = "1001",
	["a"] = "1010", ["A"] = "1010",
	["b"] = "1011", ["B"] = "1011",
	["c"] = "1100", ["C"] = "1100",
	["d"] = "1101", ["D"] = "1101",
	["e"] = "1110", ["E"] = "1110",
	["f"] = "1111", ["F"] = "1111",
}
conversion.b2b16 = {
	["0000"] = "0",
	["0001"] = "1",
	["0010"] = "2",
	["0011"] = "3",
	["0100"] = "4",
	["0101"] = "5",
	["0110"] = "6",
	["0111"] = "7",
	["1000"] = "8",
	["1001"] = "9",
	["1010"] = "A",
	["1011"] = "B",
	["1100"] = "C",
	["1101"] = "D",
	["1110"] = "E",
	["1111"] = "f",
}
conversion.b32b2 = {
	["a"] = "00000", ["A"] = "00000",
	["b"] = "00001", ["B"] = "00001",
	["c"] = "00010", ["C"] = "00010",
	["d"] = "00011", ["D"] = "00011",
	["e"] = "00100", ["E"] = "00100",
	["f"] = "00101", ["F"] = "00101",
	["g"] = "00110", ["G"] = "00110",
	["h"] = "00111", ["H"] = "00111",
	["i"] = "01000", ["I"] = "01000",
	["j"] = "01001", ["J"] = "01001",
	["k"] = "01010", ["K"] = "01010",
	["l"] = "01011", ["L"] = "01011",
	["m"] = "01100", ["M"] = "01100",
	["n"] = "01101", ["N"] = "01101",
	["o"] = "01110", ["O"] = "01110",
	["p"] = "01111", ["P"] = "01111",
	["q"] = "10000", ["Q"] = "10000",
	["r"] = "10001", ["R"] = "10001",
	["s"] = "10010", ["S"] = "10010",
	["t"] = "10011", ["T"] = "10011",
	["u"] = "10100", ["U"] = "10100",
	["v"] = "10101", ["V"] = "10101",
	["w"] = "10110", ["W"] = "10110",
	["x"] = "10111", ["X"] = "10111",
	["y"] = "11000", ["Y"] = "11000",
	["z"] = "11001", ["Z"] = "11001",
	["2"] = "11010",
	["3"] = "11011",
	["4"] = "11100",
	["5"] = "11101",
	["6"] = "11110",
	["7"] = "11111",
}
conversion.b2b32 = {
	["00000"] = "A",
	["00001"] = "B",
	["00010"] = "C",
	["00011"] = "D",
	["00100"] = "E",
	["00101"] = "F",
	["00110"] = "G",
	["00111"] = "H",
	["01000"] = "I",
	["01001"] = "J",
	["01010"] = "K",
	["01011"] = "L",
	["01100"] = "M",
	["01101"] = "N",
	["01110"] = "O",
	["01111"] = "P",
	["10000"] = "Q",
	["10001"] = "R",
	["10010"] = "S",
	["10011"] = "T",
	["10100"] = "U",
	["10101"] = "V",
	["10110"] = "W",
	["10111"] = "X",
	["11000"] = "Y",
	["11001"] = "Z",
	["11010"] = "2",
	["11011"] = "3",
	["11100"] = "4",
	["11101"] = "5",
	["11110"] = "6",
	["11111"] = "7",
}

local function hex2base32(str)
	assert(#str % 5 == 0, "hex string must have a size multiple of 5")
	str = str:gsub(".", conversion.b16b2)
	str = str:gsub(".....", conversion.b2b32)
	return str
end

local function base322hex(str)
	assert(#str % 4 == 0, "hex string must have a size multiple of 4")
	str = str:gsub(".", conversion.b32b2)
	str = str:gsub("....", conversion.b2b16)
	return str
end

if optim and optim.base322bin then
	_M.base322bin = optim.base322bin
else
	function _M.base322bin(value)
		return _M.hex2bin(base322hex(value))
	end
end

if optim and optim.bin2base32 then
	_M.bin2base32 = optim.bin2base32
else
	function _M.bin2base32(value)
		return hex2base32(_M.bin2hex(value))
	end
end

if optim and optim.B2b then
	_M.B2b = optim.B2b
else
	function _M.B2b(bytes, endianness)
		assert(endianness=='le' or endianness=='be', "invalid endianness "..tostring(endianness))
		bytes = {string.byte(bytes, 1, #bytes)}
		local bits = {}
		for _,byte in ipairs(bytes) do
			if endianness=='le' then
				for i=0,7 do
					bits[#bits+1] = byte & 2^i > 0 and 1 or 0
				end
			elseif endianness=='be' then
				for i=7,0,-1 do
					bits[#bits+1] = byte & 2^i > 0 and 1 or 0
				end
			end
		end
		return string.char(unpack(bits))
	end
end

if optim and optim.b2B then
	_M.b2B = optim.b2B
else
	function _M.b2B(bits, endianness)
		assert(endianness=='le' or endianness=='be', "invalid endianness "..tostring(endianness))
		bits = {string.byte(bits, 1, #bits)}
		local bytes = {}
		local nbytes = #bits / 8
		assert(nbytes==math.floor(nbytes))
		for B=0,nbytes-1 do
			local byte = 0
			if endianness=='le' then
				for b=0,7 do
					byte = byte + bits[B*8+b+1] * 2^b
				end
			elseif endianness=='be' then
				for b=0,7 do
					byte = byte + bits[B*8+b+1] * 2^(7-b)
				end
			end
			bytes[B+1] = byte
		end
		return string.char(unpack(bytes))
	end
end

--[=[
function wrap(name)
	local ename = name:gsub("[^%w]", "_")
	local chunk = assert(loadstring([[
		local ]]..ename..[[ = ...
		return select(1, ]]..ename..[[(select(2, ...)))
	]], name.." wrapper"))
	if name ~= ename then
		return loadstring(string.dump(chunk):gsub(ename, name))
	else
		return chunk
	end
end
--]=]
if debug then
	function _M.wrap(name, f)
		local ename = name:gsub("[^%w]", "_")
		local chunk = assert(loadstring([[
			local ]]..ename..[[ = ...
			return function(...)
				return select(1, ]]..ename..[[(...))
			end
		]], name.." wrapper"))
		if name ~= ename then
			chunk = loadstring(string.dump(chunk):gsub(ename, name))
		end
		return chunk(f)
	end
else
	function _M.wrap(name, f)
		return f
	end
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
