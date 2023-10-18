
if not newproxy then
	local function argcheck(value, index, message)
		if not value then
			local name = debug.getinfo(2, 'n').name or '?'
			error("bad argument #1 to '"..name.."' ("..message..")", 3)
		end
	end
	
	local weaktable = {}
	function newproxy(...)
		local proxy,m = {}
		if not ... then
			return proxy
		elseif type(...)=='boolean' then
			m = {}
			rawset(weaktable, m, true)
		else
			local validproxy = false
			m = getmetatable(...)
			if m then
				validproxy = rawget(weaktable, m)
			end
			argcheck(validproxy, 1, "boolean or proxy expected")
		end
		setmetatable(proxy, m)
		return proxy
	end
end

