local _M = {}
local _NAME = ... or 'test'

local table = require 'table'
local string = require 'string'

local function parseargs(s)
	local arg = {}
	string.gsub(s, "([-%w_]+)=([\"'])(.-)%2", function (w, _, a)
		arg[w] = a
	end)
	return arg
end

local function line(s, i)
	return select(2, s:sub(1,i):gsub('\n', '\n')) + 1
end
if _NAME=='test' then
	assert(line("foo\nbar\nbaz")==3)
	assert(line("foo\nbar\nbaz", 6)==2)
end

------------------------------------------------------------------------------

local label_token = setmetatable({}, {__tostring=function() return "<xml label token>" end})
local line_token = setmetatable({}, {__tostring=function() return "<xml line token>" end})
local parent_token = setmetatable({}, {__tostring=function() return "<xml parent token>" end})
local file_token = setmetatable({}, {__tostring=function() return "<xml file token>" end})

local function get_label(node)
	return node[label_token]
end
local function set_label(node, value)
	node[label_token] = value
end

local function get_line(node)
	return node[line_token]
end
local function set_line(node, value)
	node[line_token] = value
end

local function get_parent(node)
	return node[parent_token]
end
local function set_parent(node, value)
	node[parent_token] = value
end

local function get_file(node)
	return node[file_token]
end
local function set_file(node, value)
	node[file_token] = value
end

------------------------------------------------------------------------------

function _M.collect(s, file)
	-- strip XML comments
	s = s:gsub('<!%-%-.-%-%->', function(str) return str:gsub('[^\n]', '') end) -- preserve newlines for line numbers
	
	local stack = {}
	local top = {}
	table.insert(stack, top)
	local ni,c,label,xarg, empty
	local i, j = 1, 1
	while true do
		ni,j,c,label,xarg,empty = string.find(s, "<(%/?)([-%w_:]+)(.-)(%/?)>", i)
		if not ni then break end
		local text = string.sub(s, i, ni-1)
		if not string.find(text, "^%s*$") then
			table.insert(top, text)
		end
		if empty == "/" then  -- empty element tag
			local node = parseargs(xarg)
			set_label(node, label)
			set_line(node, {s=s, a=ni, b=nil, c=nil, d=j})
			set_file(node, file)
			set_parent(node, top)
			table.insert(top, node)
		elseif c == "" then   -- start tag
			local parent = top
			top = parseargs(xarg)
			set_label(top, label)
			set_line(top, {s=s, a=ni, b=j})
			set_file(top, file)
			set_parent(top, parent)
			table.insert(stack, top)   -- new level
		else  -- end tag
			local toclose = table.remove(stack)  -- remove top
			top = stack[#stack]
			if #stack < 1 then
				error("nothing to close with "..label)
			end
			if get_label(toclose) ~= label then
				if get_label(toclose):lower() ~= label:lower() then
					error("trying to close "..get_label(toclose).." with "..label)
				end
			end
			get_line(toclose).c = ni
			get_line(toclose).d = j
			table.insert(top, toclose)
		end
		i = j+1
	end
	local text = string.sub(s, i)
	if not string.find(text, "^%s*$") then
		table.insert(stack[#stack], text)
	end
	if #stack > 1 then
		error("unclosed "..get_label(stack[#stack]))
	end
	return stack[1]
end

function _M.label(node)
	return get_label(node)
end

function _M.setlabel(node, label)
	set_label(node, label)
end

function _M.nodeline(node)
	local lineinfo = get_line(node)
	return line(lineinfo.s, lineinfo.a)
end

function _M.contentline(node)
	local lineinfo = get_line(node)
	return line(lineinfo.s, lineinfo.b)
end

function _M.path(node)
	local parent = get_parent(node)
	local parentpath,index
	if parent then
		parentpath = _M.path(parent)
		for k,v in pairs(parent) do
			if node==v then
				index = k
				break
			end
		end
	end
	if parentpath and index then
		return parentpath..'.'..get_label(node)..'('..tostring(index)..')'
	else
		return get_label(node)
	end
end

function _M.file(node)
	return get_file(node)
end

local function write_node(file, node, indent)
	local label = get_label(node)
	file:write(indent..'<'..label)
	local args = {}
	for k,v in pairs(node) do
		if type(k)=='string' then
			table.insert(args, k)
		end
	end
	if next(args) then
	--	file:write('\n')
		table.sort(args)
		for _,k in ipairs(args) do
	--		file:write(indent..'\t'..k..'="'..tostring(node[k])..'"\n')
			file:write(' '..k..'="'..tostring(node[k])..'"')
		end
	--	file:write(indent)
	end
	if #node == 0 then
		file:write('/>\n')
	elseif #node == 1 and type(node[1])=='string' and not node[1]:match('\n') then
		file:write('>'..node[1]..'</'..label..'>\n')
	else
		file:write('>\n')
		local cindent = indent..'\t'
		for _,child in ipairs(node) do
			if type(child)=='string' then
				file:write(cindent..child:gsub('\n', '\n'..cindent)..'\n')
			else
				write_node(file, child, cindent)
			end
		end
		file:write(indent)
		file:write('</'..label..'>\n')
	end
end

function _M.write(file, doc)
	file:write('<?xml')
	if doc.version then file:write(' version="'..doc.version..'"') end
	if doc.encoding then file:write(' encoding="'..doc.encoding..'"') end
	file:write('?>\n')
	write_node(file, doc.root, "")
end

if _NAME=='test' then
	function expect(expectation, value, ...)
		if value~=expectation then
			error("expectation failed! "..tostring(expectation).." expected, got "..tostring(value), 2)
		end
	end
	
	local root = _M.collect('<foo/>')
	expect('table', type(root))
	assert(next(root)==1 and next(root, 1)==nil)
	local foo = root[1]
	expect('foo', _M.label(foo))
	expect('foo_bar', _M.label(_M.collect('<foo_bar/>')[1]))
	local root = _M.collect('<foo BUILD_ID="1"/>')
	expect('string', type(root[1].BUILD_ID))
	local root = _M.collect([[
<foo>
	<bar/>
	<baz>
		Hello World!
	</baz>
</foo>]])
	expect('table', type(root))
	assert(next(root)==1 and next(root, 1)==nil)
	local foo = root[1]
	expect('foo', _M.label(foo))
	expect(2, #foo)
	local bar = foo[1]
	expect(2, _M.nodeline(bar))
	local baz = foo[2]
	expect("\n\t\tHello World!\n\t", baz[1])
	expect(3, _M.contentline(baz))
--	expect('foo.baz', _M.path(baz))
	
	print("all tests passed successfully")
end

return _M
