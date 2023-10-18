local gl = require 'gl'

-- [[
if not gl.extensions then
	gl.extensions = setmetatable({}, {
		__index = function(self, k)
			if type(k)=='string' then
				if (' '..gl.GetString('EXTENSIONS')..' '):match('%s'..k..'%s') then
					return true
				end
			end
		end,
	})
end
--]]

-- alternative implementation
--[[
require 'gl.CheckError'

if not gl.extensions then
	gl.extensions = setmetatable({}, {
		__index = function(self, k)
			if gl.GetString('VERSION'):match('^[1-2]%.') then
				if type(k)=='string' then
					if (' '..gl.GetString('EXTENSIONS')..' '):match('%s'..k..'%s') then
						return true
					end
				end
			else
				for i=0,gl.GetIntegerv('NUM_EXTENSIONS')[1] - 1 do
					if k == gl.GetStringi('EXTENSIONS', i) then
						return true
					end
				end
			end
		end,
	})
end
--]]

