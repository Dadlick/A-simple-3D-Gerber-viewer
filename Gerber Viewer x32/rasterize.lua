local math = require 'math'
local pathlib = require 'path'
local launcher = require 'launcher'
local boards = require 'boards'
local region = require 'boards.region'
local extents = require 'boards.extents'
local interpolation = require 'boards.interpolation'
local configlib = require 'config'

local gui = require 'engine.gui'

local renderer = require 'rasterize.boards'

pathlib.install()

------------------------------------------------------------------------------
-- config

local config = {
	board = nil,
	image = nil,
	output = nil,
	dpi = 96,
	template = nil,
	margin = 10,
}
configlib.load(config, 'rasterize.conf')
configlib.args(config, ...)
assert(#config == 0, "unexpected argument '"..tostring(config[1]).."'")

configlib.check(launcher.title, {
	{config.board, "no input board specified"},
	{config.image, "no image specified"},
	{config.output, "no output filename provided"},
	{type(config.dpi)=='number', "invalid dpi value"},
}, [[
Usage: ]]..launcher.title..[[ [-<arg> <value>]...

Mandatory arguments:
  board     path of input board file(s)
  image     name of image to rasterize (top_copper, milling, etc.)
  output    path of output raster image file

Optional arguments:
  dpi       resolution of output raster (default: 96)
  template  board template (see gerber-ltools)]])

------------------------------------------------------------------------------
-- window for opengl context

gui.init(320, 240, "Gerber viewer", {})
gui.init_gl(gui.window)
renderer.init_gl()

------------------------------------------------------------------------------

local board = assert(boards.load(config.board, {
	keep_outlines_in_images = true,
	unit = 'mm',
	template = config.template,
}))
board.extents = extents.compute_board_extents(board)
assert(not board.extents.empty, "board is empty")
interpolation.interpolate_board_paths(board, 0.01)
boards.generate_aperture_paths(board)
local image = assert(board.images[config.image])

local w = board.extents.right - board.extents.left + config.margin
local h = board.extents.top - board.extents.bottom + config.margin
local cx = (board.extents.left + board.extents.right) / 2
local cy = (board.extents.bottom + board.extents.top) / 2

local tw = math.ceil(w * config.dpi / 25.4 / 16) * 16
local th = math.ceil(h * config.dpi / 25.4 / 16) * 16

local w = tw * 25.4 / config.dpi
local h = th * 25.4 / config.dpi
local extents = region{left=cx-w/2, bottom=cy-h/2, right=cx+w/2, top=cy+h/2}

assert(renderer.init(tw, th, extents))

renderer.generate_image(image, config.output)

assert(renderer.cleanup())

gui.cleanup_gl()
gui.cleanup()

------------------------------------------------------------------------------

print("exiting cleanly")

-- vi: ft=lua
