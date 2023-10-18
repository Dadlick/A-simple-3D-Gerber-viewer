--- This module is the main entry point for Aperture Scripting. It contains several high level functions to load and save boards.
local _M = {}

local os = require 'os'
local io = require 'io'
local math = require 'math'
local table = require 'table'
local lfs = require 'lfs'
local pathlib = require 'path'

local paths = require 'boards.path'
local macros = require 'boards.macro'
local region = require 'boards.region'
local drawing = require 'boards.drawing'
local extents = require 'boards.extents'
local aperture = require 'boards.aperture'
local templates = require 'boards.templates'
local pathmerge = require 'boards.pathmerge'
local manipulation = require 'boards.manipulation'
local panelization = require 'boards.panelization'
local interpolation = require 'boards.interpolation'

local gui = require 'engine.gui'
local string = require 'string'

pathlib.install()

local unpack = unpack or table.unpack

------------------------------------------------------------------------------

_M.circle_steps = 64

------------------------------------------------------------------------------

local path_load_scales = {
	pm = 1,
	mm = 1e-9,
}

local path_merge_scales = {
	pm = 1e9,
	mm = 1,
}

local function load_image(filepath, format, unit, template)
--	print("loading "..tostring(filepath))
	local image
	if format=='excellon' then
		local excellon = require 'excellon'
		image = excellon.load(filepath, template.excellon)
	elseif format=='bom' then
		local bom = require 'bom'
		image = bom.load(filepath, template.bom)
	elseif format=='gerber' then
		local gerber = require 'gerber'
		image = gerber.load(filepath)
	elseif format=='svg' then
		local svg = require 'svg'
		image = svg.load(filepath)
	elseif format=='dxf' then
		local dxf = require 'dxf'
		image = dxf.load(filepath)
	else
		error("unsupported image format "..tostring(format))
	end
	
	-- scale the path data (sub-modules output picometers)
	local scale = assert(path_load_scales[unit], "unsupported board output unit "..tostring(unit))
	if scale ~= 1 then
		for _,layer in ipairs(image.layers) do
			for _,path in ipairs(layer) do
				for _,point in ipairs(path) do
					point.x = point.x * scale
					point.y = point.y * scale
					if point.cx then point.cx = point.cx * scale end
					if point.cy then point.cy = point.cy * scale end
				end
			end
		end
	end
	
	-- merge quasi-continuous paths (like rounded outlines as generated by EAGLE)
	local path_merge_epsilon = (template.path_merge_radius or 0) * path_merge_scales[unit]
	pathmerge.merge_image_paths(image, path_merge_epsilon)
	
	return image
end

--- Load the image in file *filepath*. *format* is one of the supported image formats as a string, or `nil` to trigger auto-detection. *options* is an optional table.
--- 
--- The *options* table can contain a field named `unit` that specifies the output length unit. Its value must be one of the supported length units as a string. The default is `'pm'`.
function _M.load_image(filepath, format, options)
	if not options then options = {} end
	
	local unit = options.unit or 'pm'
	
	-- look for a template
	local template
	-- - 1. try option as data
	if not template and options.template and type(options.template)=='table' then
		template = options.template
	end
	-- - 2. try option as a filename
	if not template and options.template and lfs.attributes(options.template, 'mode') then
		template = dofile(options.template)
	end
	-- - 3. try option as standard template name
	if not template and options.template and templates[options.template] then
		template = templates[options.template]
	end
	-- - 4. use default template
	if not template then
		template = templates.default -- :TODO: make that configurable
	end
	
	if not template then
		return nil,"no template found"
	end
	
	if not format then
		local msg
		format,msg = _M.detect_format(filepath)
		if not format then
			return nil,msg
		end
	end
	
	return load_image(filepath, format, unit, template)
end

local function save_image(image, filepath, format, unit, template)
--	print("saving "..tostring(filepath))
	assert(unit == 'pm', "saving scaled images is not yet supported")
	if format=='excellon' then
		local excellon = require 'excellon'
		return excellon.save(image, filepath)
	elseif format=='bom' then
		local bom = require 'bom'
		return bom.save(image, filepath, template.bom)
	elseif format=='gerber' then
		local gerber = require 'gerber'
		return gerber.save(image, filepath)
	elseif format=='svg' then
		local svg = require 'svg'
		return svg.save_image(image, filepath)
	elseif format=='dxf' then
		local dxf = require 'dxf'
		return dxf.save(image, filepath)
	else
		error("unsupported image format "..tostring(format))
	end
end

--- Save the *image* in the file *filepath*. *format* must be one of the supported image formats as a string. *options* is an optional table.
--- 
--- The *options* table can contain a field named `unit` that specifies the length unit of the input data. Its value must be one of the supported length units as a string, the default is `'pm'`. Note that at the moment only images in `'pm'` can be saved.
--- 
--- The unit used within the file is specified in the `unit` field of the *image* itself. Some formats also expect some more such fields, for example to specify the number of significant digits or whether to remove trailing zeroes (see the source, examples and individual format documentation for more details).
function _M.save_image(image, filepath, format, options)
	if not options then options = {} end
	
	local unit = options.unit or 'pm'
	local template = templates.default -- :TODO: make that configurable
	
	return save_image(image, filepath, format, unit, template)
end

------------------------------------------------------------------------------

local function path_to_region(path)
	assert(path[#path].x==path[1].x and path[#path].y==path[1].y, "path is not closed")
	-- fix orientation
	if not paths.exterior(path) then
		path = paths.reverse_path(path)
	end
	-- find bottom-left corner
	local corner = 1
	for i=2,#path-1 do
		if path[i].y < path[corner].y or path[i].y == path[corner].y and path[i].x < path[corner].x then
			corner = i
		end
	end
	-- rotate the path
	local region = paths.shift_path(path, corner)
	-- make it a region
	region.aperture = nil
	return region
end

--- Detect the format of the file *path*. Possible return values are `'gerber'`, `'excellon'`, `'dxf'`, `'svg'`, `'bom'` or `nil`.
function _M.detect_format(path)
	local file,msg = io.open(path, 'rb')
	if not file then return nil,msg end
	local k,msg = file:read(1024)
	if not k then file:close(); return nil,msg end
	local success,msg = file:close()
	if not success then return nil,msg end
	if k:match('FS[LT][AI]X%d%dY%d%d%*') or k:match('%%ADD10') then
		return 'gerber'
	elseif k:match('T0*1') or k:match('M48') then
		return 'excellon'
	elseif k:match('%s+0%s+SECTION%s') then
		return 'dxf'
	elseif k:match('^[^\n]*\t[^\n]*\n') then
		return 'bom'
	else
		return nil,"unknown file format"
	end
end

function isDir(name)
    if type(name)~="string" then return false end
    local cd = lfs.currentdir()
    local is = lfs.chdir(name) and true or false
    lfs.chdir(cd)
    return is
end

--- Load the board specified by *path*, which can be either a string specifying a base path, or an array listing individual image file paths. *options* is an optional table.
--- 
--- The correspondance between the base path or paths table and individual images is based on a template, which can be specified in several ways:
--- 
---   - If *path* is a string and ends with `'.conf'`, it is used as the template.
---   - If *path* is a string and a file named *<path>.conf* exists, it is used as the template.
---   - If *path* is an array and contains a string ending with `'.conf'`, this file is used as a template.
---   - If the *options* table contain a field named `template` which string value corresponds to an existing file path, this file is used as a template.
---   - If the *options* table contain a field named `template` which string value corresponds to a known template (see the `boards.templates` module), this template is used.
---   - Otherwise the `default` template is used.
--- 
--- The template `patterns` field specifies a correspondance between filename patterns and image roles. If *path* is a string corresponding to an existing file, or an array of strings, these paths are matched against the template patterns and matching files are loaded as the corresponding images. If *path* is a string not corresponding to an existing file, it is used as a base path and matched against the template patterns to find files, which are loaded as the corresponding images if they exist.
--- 
--- All files format are automatically detected depending on content. The *options* table can contain a field named `unit` that specifies the output length unit. Its value must be one of the supported length units as a string. The default is `'pm'`.
--- 
--- Finally once all the files have been loaded a board outline is extracted from the various images. To avoid that last step and leave the outline paths in the images themselves (if you want to render them for example), you can set the *options* field `keep_outlines_in_images` to a true value.
function _M.load(path, options)
	if not options then options = {} end
	local board = {}	
	board.unit = options.unit or 'pm'
	-- look for a template
	local template
	-- - 1. look for a .conf file in the input
	if type(path)=='string' and lfs.attributes(path, 'mode') and path:match('%.conf$') then
		template = dofile(path)
	elseif type(path)=='string' and lfs.attributes(path..".conf", 'mode') then
		template = dofile(path..".conf")
	elseif type(path)=='table' then
		for _,path in ipairs(path) do
			if lfs.attributes(path, 'mode') and path:match('%.conf$') then
				template = dofile(path)
				break
			end
		end
	end
	
	
	
	-- - 2. try option as data
	if not template and options.template and type(options.template)=='table' then
		template = options.template
	end
	-- - 3. try option as a filename
	if not template and options.template and lfs.attributes(options.template, 'mode') then
		template = dofile(options.template)
	end
	-- - 4. try option as standard template name
	if not template and options.template and templates[options.template] then
		template = templates[options.template]
	end
	-- - 5. use default template
	if not template then
		template = templates.default -- :TODO: make that configurable
	end
	
	if not template then
		return nil,"no template found"
	end
	board.template = template
	
	-- locate files
	local paths = {}
	local extensions = {}
	local formats = {}
	
	if isDir(path) then	
		-- files in folder
		local files = {}
		for file in lfs.dir(path) do
			for image,patterns in pairs(template.patterns) do
				if type(patterns)=='string' then patterns = { patterns } end
				for _,pattern in ipairs(patterns) do
					if file:match(pattern) then
						local fpath = path .. '/' .. file
						local format = _M.detect_format(fpath)
						if format then
							paths[image] = fpath
							extensions[image] = pattern
							formats[image] = format
							break
						else
							print("cannot detect format of file "..tostring(path))
						end
					end
				end
			end
		end
	else	
		-- single file special case
		if type(path)=='string' and lfs.attributes(path, 'mode') then
			path = { path }
		end	
	end
		
	if type(path)~='table' and lfs.attributes(path, 'mode') then
		path = { path }
	end
	
	if type(path)=='table' then
		for _,path in ipairs(path) do
			path = pathlib.split(path)
			local format = _M.detect_format(path)
			if format then
				local found = false
				for image,patterns in pairs(template.patterns) do
					if type(patterns)=='string' then patterns = { patterns } end
					for _,pattern in ipairs(patterns) do
						local lpattern = '^'..pattern:gsub('[-%.()%%]', {
							['-'] = '%-',
							['.'] = '%.',
							['('] = '%(',
							[')'] = '%)',
							['%'] = '(.*)',
						})..'$'
						local basename = path.file:match(lpattern) or path.file:lower():match(lpattern:lower())
						if basename then
							paths[image] = path
							extensions[image] = pattern
							formats[image] = format
							found = true
							break
						end
					end
					if found then
						break
					end
				end
				if not found then
					print("cannot guess type of file "..tostring(path))
				end
			else
				print("cannot detect format of file "..tostring(path))
			end
		end
	else	
		path = pathlib.split(path)
		local files = {}
		local Fi = 0
		for file in lfs.dir(path.dir) do
			if string.match(file, path.file) then
				files[Fi] = file
				Fi = Fi + 1
			end		
		end
		
		for i = 0, Fi - 1 do
			local file = files[i]
			for image,patterns in pairs(template.patterns) do
				if type(patterns)=='string' then patterns = { patterns } end
				for _,pattern in ipairs(patterns) do
					if file:match(pattern) then
						local fpath = path.dir / file
						local format = _M.detect_format(fpath)
						if format then
							paths[image] = fpath
							extensions[image] = pattern
							formats[image] = format
							break
						else
							print("cannot detect format of file "..tostring(path.dir))
						end
					end
				end
			end
		end

		
	end
	if next(paths)==nil then
		return nil,"no image found"
	end
	board.extensions = extensions
	board.formats = formats
	
	-- load images
	local images = {}
	for type,path in pairs(paths) do
		local format = formats[type]
		local image = load_image(path, format, board.unit, template)
		images[type] = image
	end
	board.images = images
	
	-- crop
	if template.crop then
		local scale = path_merge_scales[board.unit]
		local crop = region{
			left = (template.crop.left or 0) * scale,
			right = (template.crop.right or 0) * scale,
			bottom = (template.crop.bottom or 0) * scale,
			top = (template.crop.top or 0) * scale,
		}
		for _,image in pairs(board.images) do
			for _,layer in ipairs(image.layers) do
				for i=#layer,1,-1 do
					local path = layer[i]
					for _,point in ipairs(path) do
						if not crop:contains(point) then
							table.remove(layer, i)
							break
						end
					end
				end
			end
		end
	end
	
	-- extract outline
	local outlines = _M.find_board_outlines(board)
	if next(outlines) and not options.keep_outlines_in_images then
		local data = select(2, next(outlines))
		local outline = {}
		outline.path = path_to_region(data.path)
		outline.apertures = {}
		-- convert the outline data
		for type,data in pairs(outlines) do
			-- store the aperture used on this image
			outline.apertures[type] = data.path.aperture
			-- remove the path from the image
			table.remove(board.images[type].layers[data.ilayer], data.ipath)
			if #board.images[type].layers[data.ilayer] == 0 then
				table.remove(board.images[type].layers, data.ilayer)
			end
		end
		board.outline = outline
	end
	
	return board
end

local function save_board(board, filepath, format, unit, template)
--	print("saving "..tostring(filepath))
	assert(unit == 'pm', "saving scaled images is not yet supported")
	--[[if format=='gerber' then
		-- :TODO: add support for multi-image gerber files
		local gerber = require 'gerber'
		return gerber.save_board(image, filepath)
	else]]if format=='svg' then
		local svg = require 'svg'
		return svg.save_board(board, filepath)
	elseif format=='dxf' then
		local dxf = require 'dxf'
		return dxf.save_board(board, filepath)
	else
		error("unsupported board format "..tostring(format))
	end
end

--- Save the board *board* with the base name *filepath*. The board should contain fields `extensions` and `formats` that specify the individual file name pattern and file format (resp.) to use for each individual image. The input data unit should be specified in the board `unit` field (at the moment it must be `'pm'`).
--- 
--- Further format details and options on how to save each individual file should be specified in the images (as documented in [boards.save\_image](#boards.save_image)).
function _M.save(board, filepath)
	if pathlib.type(filepath) ~= 'path' then
		filepath = pathlib.split(filepath)
	end
	assert(board.format or board.formats and next(board.formats), "board image formats is not specified")
	assert(not (board.format and board.formats and next(board.formats)), "board has both a board format and individual image formats")
	if board.format then
		local success,msg = save_board(board, filepath, board.format, board.unit, board.template)
		if not success then return nil,msg end
	else
		for type,image in pairs(board.images) do
			-- re-inject outline before saving
			if board.outline and board.outline.apertures[type] then
				image = manipulation.copy_image(image)
				local path = manipulation.copy_path(board.outline.path)
				path.aperture = board.outline.apertures[type]
				if #image.layers==0 or image.layers[#image.layers].polarity=='clear' then
					table.insert(image.layers, {polarity='dark'})
				end
				table.insert(image.layers[#image.layers], path)
			end
			local pattern = assert(board.extensions[type], "no extension pattern for file of type "..type)
			local filepath = filepath.dir / pattern:gsub('%%', filepath.file)
			local format = assert(board.formats[type], "no format for file of type "..type)
			local success,msg = save_image(image, filepath, format, board.unit, board.template)
			if not success then return nil,msg end
		end
	end
	return true
end

------------------------------------------------------------------------------

local function find_image_outline(image)
	-- find path with largest area
	local amax,lmax,pmax = -math.huge
	for l,layer in ipairs(image.layers) do
		for p,path in ipairs(layer) do
			local path_extents = extents.compute_path_extents(path)
			local a = path_extents.area
			if a > amax then
				amax,lmax,pmax = a,l,p
			end
		end
	end
	-- check that we have a path
	if not lmax or not pmax then
		return nil
	end
	local path = image.layers[lmax][pmax]
	-- check that the path is long enough to enclose a region
	if #path < 3 then
		return nil
	end
	-- check that the path is closed
	if path[1].x ~= path[#path].x or path[1].y ~= path[#path].y then
		return nil
	end
	-- check that path is a line, not a region
	if not path.aperture then
		return nil
	end
	-- :TODO: check that all other paths are within the outline
	
	return path,amax,lmax,pmax
end

local ignore_outline = {
	top_soldermask = true,
	bottom_soldermask = true,
}
_M.ignore_outline = ignore_outline

function _M.find_board_outlines(board)
	local outlines = {}
	-- gen raw list
	local max_area = -math.huge
	for type,image in pairs(board.images) do
		if not ignore_outline[type] then
			local path,area,ilayer,ipath = find_image_outline(image)
			if path then
				max_area = math.max(max_area, area)
				outlines[type] = {path=path, ilayer=ilayer, ipath=ipath, area=area}
			end
		end
	end
	-- filter the list
	for type,data in pairs(outlines) do
		-- igore all but the the largest ones
		if data.area < max_area then
			outlines[type] = nil
		end
	end
	return outlines
end

------------------------------------------------------------------------------

local function macro_hash(macro)
	local t = {}
	for _,instruction in ipairs(macro.script) do
		local type = instruction.type
		table.insert(t, type)
		if type=='comment' then
			-- ignore
		elseif type=='variable' then
			table.insert(t, instruction.name)
			table.insert(t, macros.compile_expression(instruction.value))
		elseif type=='primitive' then
			table.insert(t, instruction.shape)
			for _,expression in ipairs(instruction.parameters) do
				table.insert(t, macros.compile_expression(expression))
			end
		else
			error("unsupported aperture macro instruction type "..tostring(type))
		end
	end
	for i,n in ipairs(t) do
		if type(n) == 'number' then
			t[i] = math.tointeger(n) or n
		end
	end
	return table.concat(t, '\0')
end

local function aperture_hash(aperture)
	local t
	if aperture.macro then
		t = { 'macro', macro_hash(aperture.macro), unpack(aperture.parameters or {}) }
	elseif aperture.shape then
		local shape = aperture.shape
		t = { shape }
		if shape=='circle' then
			table.insert(t, aperture.diameter)
			table.insert(t, aperture.hole_width)
			table.insert(t, aperture.hole_height)
			if aperture.line_type then
				-- :FIXME: we need to handle line stipples more robustly
				table.insert(t, 'line_type='..aperture.line_type)
			end
		elseif shape=='rectangle' or shape=='obround' then
			table.insert(t, aperture.width)
			table.insert(t, aperture.height)
			table.insert(t, aperture.hole_width)
			table.insert(t, aperture.hole_height)
		elseif shape=='polygon' then
			table.insert(t, aperture.diameter)
			table.insert(t, aperture.steps)
			table.insert(t, aperture.angle)
			table.insert(t, aperture.hole_width)
			table.insert(t, aperture.hole_height)
		else
			error("unsupported aperture shape "..tostring(shape))
		end
	elseif aperture.device then
		local keys = {}
		for k in pairs(aperture.parameters) do
			table.insert(keys, k)
		end
		table.sort(keys)
		t = { 'device' }
		for _,k in ipairs(keys) do
			table.insert(t, k)
			table.insert(t, aperture.parameters[k])
		end
	else
		error("unsupported aperture")
	end
	for i,n in ipairs(t) do
		if type(n) == 'number' then
			t[i] = math.tointeger(n) or n
		end
	end
	return table.concat(t, '\0')
end

local function merge_image_apertures(image)
	-- list apertures
	local apertures = {}
	local aperture_order = {}
	for _,layer in ipairs(image.layers) do
		for _,path in ipairs(layer) do
			local aperture = path.aperture
			if aperture then
				local s = aperture_hash(aperture)
				if apertures[s] then
					aperture = apertures[s]
					path.aperture = aperture
				else
					apertures[s] = aperture
					table.insert(aperture_order, aperture)
				end
			end
		end
	end
	
	-- list macros
	local macros = {}
	local macro_order = {}
	for _,aperture in ipairs(aperture_order) do
		local macro = aperture.macro
		if macro then
			local s = macro_hash(macro)
			if macros[s] then
				aperture.macro = macros[s]
			else
				macros[s] = macro
				table.insert(macro_order, macro)
			end
		end
	end
end
_M.merge_image_apertures = merge_image_apertures

local function merge_board_apertures(board)
	for _,image in pairs(board.images) do
		merge_image_apertures(image)
	end
end

--- Merge the identical apertures within each image of the board. This can save significant duplication when panelizing several identical or similar boards.
function _M.merge_apertures(board)
	merge_board_apertures(board)
end

------------------------------------------------------------------------------

--- Generate a `paths` field in each aperture used in the *board*.
--- 
--- Most apertures are defined as ideal shapes (for example circles or rectangles). This function will generate a series of contours for each of these ideal shapes. These contours can be used for rasterization and rendering of the apertures. See the source code of [Gerber Viewer](http://piratery.net/grbv/) for more details on how to use these generated paths.
--- 
--- Note that to generate paths for apertures using macros, you will need the [lgpc module from lhf](http://www.tecgraf.puc-rio.br/~lhf/ftp/lua/#lgpc).
function _M.generate_aperture_paths(board)
	-- collect apertures
	local apertures = {}
	for _,image in pairs(board.images) do
		for _,layer in ipairs(image.layers) do
			for _,path in ipairs(layer) do
				local aperture = path.aperture
				if aperture and not apertures[aperture] then
					apertures[aperture] = true
				end
			end
		end
	end
	
	-- generate aperture paths
	for a in pairs(apertures) do
		a.paths = aperture.generate_aperture_paths(a, board.unit, _M.circle_steps)
	end
end

------------------------------------------------------------------------------

return _M