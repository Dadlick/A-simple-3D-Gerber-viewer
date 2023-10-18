local gl = require 'gl'

local glGetError = gl.GetError

function gl.CheckError()
	local err = glGetError()
	if err~=gl.NO_ERROR then
		local msg = gl[err]
		if not msg then msg = "error code "..err end
		error(msg, 2)
	end
end

