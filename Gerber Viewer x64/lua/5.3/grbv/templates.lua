local _M = {}

local dump = require 'dump'
local crypto = require 'crypto'
local assets = require 'engine.assets'

local function parse_color(color)
	local R,G,B = color:match('^#(%x%x)(%x%x)(%x%x)$')
	return {r=tonumber(R,16)/255, g=tonumber(G,16)/255, b=tonumber(B,16)/255}
end

function _M.load(name)
	local path,msg = assets.find('colors/'..name..'.lua')
	if not path then
		path,msg = assets.find(name)
	end
	if not path then return nil,msg end
	
	local template = { materials = {} }
	local chunk,msg = loadfile(path, 't', template)
	if not chunk then return nil,msg end
	
	local success,msg = pcall(chunk)
	if not success then return nil,msg end
	
	-- materials can be defined as a simple color
	for name,material in pairs(template.materials) do
		if type(material)=='string' then
			template.materials[name] = { color = material }
		end
	end
	
	-- colors are strings that need to be parsed
	for _,material in pairs(template.materials) do
		if type(material.color)=='string' then
			material.color = parse_color(material.color)
		end
	end
	
	template.hash = crypto.digest('md5', dump.tostring(template)):lower()
	
	return template
end

return _M
