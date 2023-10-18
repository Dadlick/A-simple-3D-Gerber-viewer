local _M = {}

local function desire(name)
	local ok,mod = pcall(require, name)
	if ok then return mod end
end

local math = require 'math'
local linux = desire 'linux'
local kernel32 = desire 'win32.kernel32'

if linux then
	local timespec = linux.new.timespec()
	function _M.time()
		linux.clock_gettime(linux.CLOCK_MONOTONIC, timespec)
		local msec = math.floor(timespec.tv_nsec / 1000000)
		return timespec.tv_sec + msec / 1000
	end
elseif kernel32 then
	local frequency = kernel32.QueryPerformanceFrequency() / (1000*1000)
	function _M.time()
		local ticktime = kernel32.QueryPerformanceCounter()
		local mstime = math.floor(ticktime / frequency) -- for some reason that floor crashes on the render thread
		return mstime / (1000*1000)
	end
else
	error("cannot get precise time from system, one of the following modules is required: linux, win32.kernel32")
end

return _M
