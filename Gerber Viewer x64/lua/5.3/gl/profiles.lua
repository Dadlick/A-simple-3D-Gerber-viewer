local _M = {}

local io = require 'io'
local math = require 'math'
local xml = require 'xml'
local gl = require 'gl'
require 'gl.version'
require 'gl.extensions'
require 'gl.CheckError'

local assets = require 'engine.assets'

function _M.load(version, profile)
	version = version or math.huge
	local data = assert(assert(io.open(assert(assets.find('gl.xml')), "r")):read('*all'))
	local root = assert(xml.collect(data))
	local registry
	for _,child in ipairs(root) do
		if xml.label(child)=='registry' then
			registry = child
			break
		end
	end
	assert(registry)
	local gl_subset = {}
	for _,child in ipairs(registry) do
		if xml.label(child)=='feature' and child.api=='gl' then
			local feature = child
			local number = tonumber(feature.number)
			if number <= version then
				for _,requirement in ipairs(feature) do
					if not profile or not requirement.profile or requirement.profile == profile then
						if xml.label(requirement)=='require' then
							for _,child in ipairs(requirement) do
								if xml.label(child)=='enum' then
									local name = child.name:match('^GL_(.*)$')
									assert(name)
									gl_subset[name] = gl[name]
								elseif xml.label(child)=='command' then
									local name = child.name:match('^gl(.*)$')
									assert(name)
									gl_subset[name] = gl[name]
								end
							end
						elseif xml.label(requirement)=='remove' then
							for _,child in ipairs(requirement) do
								if xml.label(child)=='enum' then
									local name = child.name:match('^GL_(.*)$')
									assert(name)
									gl_subset[name] = nil
								elseif xml.label(child)=='command' then
									local name = child.name:match('^gl(.*)$')
									assert(name)
									gl_subset[name] = nil
								end
							end
						end
					end
				end
			end
		end
	end
	gl_subset.version = gl.version
	gl_subset.extensions = gl.extensions
	gl_subset.CheckError = gl.CheckError
	return gl_subset
end

return _M
