local _M = {}

local table = require 'table'
local gpc = require 'gpc'

local boards_path = require 'boards.path'

local exterior = boards_path.exterior

------------------------------------------------------------------------------

local surface = {}
local surface_getters = {}
local surface_mt = {}

function _M.surface()
	local self = {
		p = gpc.new(),
	}
	return setmetatable(self, surface_mt)
end

function surface_mt:__index(k)
	local getter = surface_getters[k]
	if getter then
		return getter(self)
	else
		return surface[k]
	end
end

function surface:extend(path)
	local c = {}
	for i=1,#path-1 do
		table.insert(c, path[i].x)
		table.insert(c, path[i].y)
	end
	self.p = self.p + gpc.new():add(c)
end

function surface:drill(aperture, position)
	local c = {}
	for i=1,#aperture-1 do
		table.insert(c, aperture[i].x + position.x)
		table.insert(c, aperture[i].y + position.y)
	end
	self.p = self.p - gpc.new():add(c)
end

function surface:mill(aperture, path)
	for i=1,#aperture-1 do
		local c = {}
		for j=1,#path do
			table.insert(c, aperture[i].x + path[j].x)
			table.insert(c, aperture[i].y + path[j].y)
		end
		for j=#path,1,-1 do
			table.insert(c, aperture[i+1].x + path[j].x)
			table.insert(c, aperture[i+1].y + path[j].y)
		end
		self.p = self.p - gpc.new():add(c)
	end
end

function surface_getters:contour()
	local paths = {}
	for c=1,self.p:get() do
		local path = {}
		local n,h = self.p:get(c)
		for i=1,n do
			local x,y = self.p:get(c, i)
			path[i] = {x=x, y=y, z=0, nx=0, ny=0, nz=0, r=0, g=0, b=0}
		end
		path[n+1] = {x=path[1].x, y=path[1].y, z=0, nx=0, ny=0, nz=0, r=0, g=0, b=0}
		if h == exterior(path) then
			local t = {}
			for i=1,#path do
				t[i] = path[#path+1-i]
			end
			path = t
		end
		table.insert(paths, path)
	end
	return paths
end

function _M.triangulate(paths)
	local buffer = gpc.new()
	for _,path in ipairs(paths) do
		local t = {}
		for i=1,#path-1 do
			table.insert(t, path[i].x)
			table.insert(t, path[i].y)
		end
		buffer:add(t, not exterior(path))
	end
	local strip = buffer:strip()
	local output = {}
	for c=1,strip:get() do
		local n = strip:get(c)
		local x1,y1 = strip:get(c, 1)
		local x2,y2 = strip:get(c, 2)
		for i=3,n do
			local x,y = strip:get(c,i)
			if i % 2 == 1 then
				table.insert(output, {x=x1, y=y1})
				table.insert(output, {x=x2, y=y2})
				table.insert(output, {x=x, y=y})
			else
				table.insert(output, {x=x2, y=y2})
				table.insert(output, {x=x1, y=y1})
				table.insert(output, {x=x, y=y})
			end
			x1,y1,x2,y2 = x2,y2,x,y
		end
	end
	return output
end

------------------------------------------------------------------------------

return _M
