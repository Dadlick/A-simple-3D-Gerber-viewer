local _M = {}

local table = require 'table'
local user32 = require 'win32.user32'

local gui = require 'engine.gui'
local signal = require 'engine.signal'
local emit = signal.emit

local left,right = false,false
local mousex,mousey,lastx,lasty
local drag_modes = {}
local drag_mode

function _M.add_mode(drag_mode)
	table.insert(drag_modes, drag_mode)
end

local function start_drag(mode)
	assert(drag_mode==nil)
--	print("starting drag "..mode.name)
	
	drag_mode = mode
	
	if drag_mode.infinite then
		user32.ShowCursor(false)
	end
	gui.capture_cursor()
	lastx,lasty = mousex,mousey
end

local function end_drag()
--	print("ending drag "..drag_mode.name)
	
	lastx,lasty = nil
	gui.release_cursor()
	if drag_mode.infinite then
		user32.ShowCursor(true)
	end
	
	drag_mode = nil
end

signal.connect(gui, 'left_button_down', nil, function()
	left = true
	if drag_mode then return end
	for _,drag_mode in ipairs(drag_modes) do
		if drag_mode.condition('left') then
			start_drag(drag_mode)
			break
		end
	end
end)

signal.connect(gui, 'left_button_up', nil, function()
	left = false
	if drag_mode then
		end_drag()
	end
end)

signal.connect(gui, 'right_button_down', nil, function()
	right = true
	if drag_mode then return end
	for _,drag_mode in ipairs(drag_modes) do
		if drag_mode.condition('right') then
			start_drag(drag_mode)
			break
		end
	end
end)

signal.connect(gui, 'right_button_up', nil, function()
	right = false
	if drag_mode then
		end_drag()
	end
end)

signal.connect(gui, 'mouse_move', nil, function(x, y)
	mousex,mousey = x,y
	if drag_mode then
		if not lastx or not lasty or x==lastx and y==lasty then
			return
		end
		local dx = x - lastx
		local dy = y - lasty
		local pos = user32.GetCursorPos()
		if drag_mode.infinite then
			user32.SetCursorPos(pos.x - dx, pos.y - dy)
		else
			lastx = x
			lasty = y
		end
		emit(drag_mode, 'drag', dx, dy)
	end
end)

return _M
