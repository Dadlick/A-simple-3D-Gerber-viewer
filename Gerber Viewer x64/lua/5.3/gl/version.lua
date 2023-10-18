local gl = require 'gl'

if not gl.version then
	function gl.version()
		local str = assert(gl.GetString('VERSION'))
		local n = tonumber((str:match('^%d+%.%d+')))
		return n,str
	end
	function gl.glsl_version()
		local str = gl.GetString('SHADING_LANGUAGE_VERSION')
		if not str then return 0 end
		local n = tonumber((str:match('^%d+%.%d+')))
		return n,str
	end
end

