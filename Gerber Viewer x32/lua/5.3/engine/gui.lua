local _M = {}

local math = require 'math'
local table = require 'table'
local debug = require 'debug'
local string = require 'string'
local win32 = require 'win32'
local kernel32 = require 'win32.kernel32'
local gdi32 = require 'win32.gdi32'
local nb = require 'nb'
local user32 = require 'win32.user32'
local shell32 = require 'win32.shell32'
local opengl32 = require 'win32.opengl32'
local gl = require 'gl'
require 'gl.version'

local assets = require 'engine.assets'
local signal = require 'engine.signal'
local emit = signal.emit

local force_core_profile = false -- { 3, 3 }
local default_title = "Homo Mechanicus"

local msgname = setmetatable({}, {__index=function(self, message)
	local t = {tostring(message)}
	for k,v in pairs(win32) do
		if type(k)=='string' and v==message and k:match('^WM_') then
			table.insert(t, k)
		end
	end
	local s = table.concat(t, ', ')
	self[message] = s
	return s
end})

------------------------------------------------------------------------------
-- the interaction

local A,Z,_0,_9 = string.byte('AZ09', 1, 4)
local VKs = {}
for k,v in pairs(win32) do
	if type(k)=='string' and k:match('^VK_') then
		k = k:match('^VK_(.*)$')
		VKs[v] = k -- :TODO: handle multiple VK with the same value
	end
end

local gui_windows = {}
local gui_class = win32.new 'WNDCLASSEX' {
	lpszClassName = 'mechanicus_gui',
	hCursor = user32.LoadImage(nil, win32.MAKEINTRESOURCE('OCR_NORMAL'), 'IMAGE_CURSOR', 32, 32, {'LR_DEFAULTCOLOR', 'LR_SHARED'}),
	lpfnWndProc = function(window, message, wparam, lparam)
--		print('>>', msgname[message])
		local self = gui_windows[window]
		if not self and (message==win32.WM_NCCREATE or message==win32.WM_CREATE) then
			local createstruct = win32.new.CREATESTRUCT(lparam)
			self = debug.getregistry()[createstruct.lpCreateParams] or {}
			gui_windows[window] = self
		end
		if not self then
			return user32.DefWindowProc(window, message, wparam, lparam)
		end
		
		if message==win32.WM_CLOSE then
			user32.PostQuitMessage(0)
			return 0
			
		elseif message==win32.WM_DESTROY then
			gui_windows[window] = nil
			return 0
			
		elseif message==win32.WM_LBUTTONDOWN then
			local x = win32.GET_X_LPARAM(lparam)
			local y = win32.GET_Y_LPARAM(lparam)
			emit(_M, 'left_button_down', x, y)
			return 0
			
		elseif message==win32.WM_LBUTTONUP then
			local x = win32.GET_X_LPARAM(lparam)
			local y = win32.GET_Y_LPARAM(lparam)
			emit(_M, 'left_button_up', x, y)
			return 0
			
		elseif message==win32.WM_RBUTTONDOWN then
			local x = win32.GET_X_LPARAM(lparam)
			local y = win32.GET_Y_LPARAM(lparam)
			emit(_M, 'right_button_down', x, y)
			return 0
			
		elseif message==win32.WM_RBUTTONUP then
			local x = win32.GET_X_LPARAM(lparam)
			local y = win32.GET_Y_LPARAM(lparam)
			emit(_M, 'right_button_up', x, y)
			return 0
			
		elseif message==win32.WM_MOUSEMOVE then
			local x = win32.GET_X_LPARAM(lparam)
			local y = win32.GET_Y_LPARAM(lparam)
			emit(_M, 'mouse_move', x, y)
			return 0
			
		elseif message==win32.WM_MOUSEWHEEL then
			local flags = win32.LOWORD(wparam)
			local dwheel = win32.HIWORD(wparam)
			if dwheel >= 2^15 then
				dwheel = dwheel - 2^16
			end
			emit(_M, 'mouse_wheel', dwheel)
			return 0
			
		elseif message==win32.WM_KEYDOWN or message==win32.WM_KEYUP then
			local signal = message==win32.WM_KEYDOWN and 'key_down' or 'key_up'
			local n = wparam
			if A <= n and n <= Z then
				emit(_M, signal, string.char(n))
			end
			if _0 <= n and n <= _9 then
				emit(_M, signal, string.char(n))
			end
			local name = VKs[n]
			if name then
				emit(_M, signal, name)
			end
			return 0
			
		-- disable F10 special behaviour (ie. generating SC_KEYMENU to give focus to the menu)
		elseif (message==win32.WM_SYSKEYDOWN or message==win32.WM_SYSKEYUP) and wparam==win32.VK_F10 then
			local signal = message==win32.WM_SYSKEYDOWN and 'key_down' or 'key_up'
			emit(_M, signal, 'F10')
			return 0
			
		elseif message==win32.WM_SIZE then
			local w,h = win32.LOWORD(lparam),win32.HIWORD(lparam)
			self.w,self.h = w,h
			if self.child then
				user32.MoveWindow(self.child, 0, 0, w, h)
			end
			emit(_M, 'size', w, h)
			
		elseif message==win32.WM_PARENTNOTIFY then
			local notification = win32.LOWORD(wparam)
			if notification==win32.WM_CREATE then
				self.child = lparam -- hwnd
				if self.w and self.h then
					user32.MoveWindow(self.child, 0, 0, self.w, self.h)
				end
				return 0
			elseif notification==win32.WM_DESTROY then
				self.child = nil -- hwnd
				return 0
			end
			
		elseif message==win32.WM_DROPFILES then
			local hDrop = wparam
			local filecount = assert(shell32.DragQueryFile(hDrop, nil))
			local files = {}
			for i=0,filecount-1 do
				local file = assert(shell32.DragQueryFile(hDrop, i))
				table.insert(files, file)
			end
			emit(_M, 'dropped_files', files)
			shell32.DragFinish(hDrop)
			return 0
			
		elseif message==win32.WM_CHAR then
			emit(_M, 'char', wparam, 'utf-16')
			
		elseif message==win32.WM_USER then
			-- ignore
			
		else
		--	print('>>', msgname[message], wparam, lparam)
		end
		return user32.DefWindowProc(window, message, wparam, lparam)
	end,
}

function _M.init(w, h, title, flags, icon)
	if icon then
		gui_class.hIcon = assert(user32.LoadImage(nil, icon, 'IMAGE_ICON', 32, 32, {'LR_DEFAULTCOLOR', 'LR_SHARED', 'LR_LOADFROMFILE'}))
		gui_class.hIconSm = assert(user32.LoadImage(nil, icon, 'IMAGE_ICON', 16, 16, {'LR_DEFAULTCOLOR', 'LR_SHARED', 'LR_LOADFROMFILE'}))
	end
	assert(user32.RegisterClassEx(gui_class))
	
	local cursor = user32.GetCursorPos()
	local monitor
	user32.EnumDisplayMonitors(nil, win32.new.RECT{
		left = cursor.x,
		right = cursor.x + 1,
		top = cursor.y,
		bottom = cursor.y + 1,
	}, function(hMonitor, hdcMonitor, lprcMonitor)
		monitor = hMonitor
	end)
	
	local _w,_h = w,h
	local style,styleex,x,y
	
	if flags.multiscreen then
		local left,right,top,bottom = math.huge,-math.huge,math.huge,-math.huge
		user32.EnumDisplayMonitors(nil, nil, function(hMonitor, hdcMonitor, lprcMonitor)
			left = math.min(left, lprcMonitor.left)
			right = math.max(right, lprcMonitor.right)
			top = math.min(top, lprcMonitor.top)
			bottom = math.max(bottom, lprcMonitor.bottom)
			return true
		end)
		x = left
		y = top
		w = right - left
		h = bottom - top
		style = {'WS_POPUP', 'WS_CLIPCHILDREN'}
		styleex = {'WS_EX_APPWINDOW', 'WS_EX_TOPMOST'}
	elseif flags.fullscreen and monitor then
		local info = user32.GetMonitorInfo(monitor)
		local mode = user32.EnumDisplaySettings(info.szDevice, 'ENUM_CURRENT_SETTINGS')
		if mode then
			print('current', 'mode', mode.dmPelsWidth..' x '..mode.dmPelsHeight, mode.dmBitsPerPel..' bits', mode.dmDisplayFrequency..' Hz')
			local rect = info.rcMonitor
			x = rect.left
			y = rect.top
			w = rect.right-rect.left
			h = rect.bottom-rect.top
			assert(w == mode.dmPelsWidth)
			assert(h == mode.dmPelsHeight)
			
			style = {'WS_POPUP', 'WS_CLIPCHILDREN'}
			styleex = {'WS_EX_APPWINDOW', 'WS_EX_TOPMOST'}
			
		--	user32.ChangeDisplaySettingsEx(info.szDevice, mode, nil, 'CDS_FULLSCREEN', nil)
		end
	end
	
	if not style then
		if monitor then
			local info = user32.GetMonitorInfo(monitor)
			x = info.rcWork.left + 100
			y = info.rcWork.top + 100
		else
			-- use default pos
			x = nil
			y = nil
		end
		
		style = {'WS_OVERLAPPEDWINDOW', 'WS_CLIPCHILDREN'}
		styleex = {'WS_EX_APPWINDOW'}
		
		local rect = win32.new 'RECT' {left=0, top=0, right=w, bottom=h}
		assert(user32.AdjustWindowRectEx(rect, style, false, styleex))
		w = rect.right-rect.left
		h = rect.bottom-rect.top
	end
	
	_M.window = assert(user32.CreateWindowEx(
		styleex,
		'mechanicus_gui',
		title or default_title,
		style,
		x, y, w, h
	))
	
	local dwmapi
	if flags.translucent and pcall(function() dwmapi = require 'win32.dwmapi' end) then
		if flags.translucent=='blurbehind' then
			local success,msg = dwmapi.DwmEnableBlurBehindWindow(_M.window, win32.new 'DWM_BLURBEHIND' {
				dwFlags = 'DWM_BB_ENABLE',
				fEnable = true,
			})
			if success then
				_M.translucent = flags.translucent
			end
		elseif flags.translucent then
			local success,msg = dwmapi.DwmExtendFrameIntoClientArea(_M.window, win32.new 'MARGINS' {
				cxLeftWidth = -1,
			})
			if success then
				_M.translucent = true
			end
		end
		--[[
		for i=1,20 do
			local attr,success,msg,errno
			for n=1,64 do
				attr = win32.new 'WINCOMPATTRDATA' {
					attribute = i,
					pData = string.rep('\0', n),
				}
				success,msg,errno = user32.GetWindowCompositionAttribute(_M.window, attr)
				if success or errno~=win32.ERROR_INSUFFICIENT_BUFFER then
					break
				end
			end
			print(">", i, success, success and require('dump').tostring(attr.pData) or msg:gsub('\n*$', ''))
		end
		for i=1,20 do
			local attr,msg,errno
			for n=4,1024 do
				attr,msg,errno = dwmapi.DwmGetWindowAttribute(_M.window, i, n)
				if attr or errno~=win32.ERROR_INSUFFICIENT_BUFFER then
					break
				end
			end
			print(">", i, attr and true, attr and require('dump').tostring(attr) or msg:gsub('\n*$', ''))
		end
		--]]
		if user32.SetWindowCompositionAttribute then
			local accent = win32.new 'ACCENTPOLICY' {
				Accent = 'ACCENT_ENABLE_BLURBEHIND',
				Flags = {
					'ACCENT_BLURBEHIND_LEFT_BORDER',
					'ACCENT_BLURBEHIND_TOP_BORDER',
					'ACCENT_BLURBEHIND_RIGHT_BORDER',
					'ACCENT_BLURBEHIND_BOTTOM_BORDER',
				},
			}
			local attribute = win32.new 'WINCOMPATTRDATA' {
				attribute = 'WCA_ACCENT_POLICY',
				pData = win32.tostring(accent),
			}
			user32.SetWindowCompositionAttribute(_M.window, attribute)
		end
	end
	
	if flags.drop_target then
		shell32.DragAcceptFiles(_M.window, true)
	end
	
	_M.gui_thread = nb.add_thread(function()
		while true do
			local msg = nb.get_message()
--			print('>', msgname[msg.message])
			user32.TranslateMessage(msg)
			assert(user32.DispatchMessage(msg))
			if msg.message==win32.WM_QUIT then
				emit(_M, 'quit')
			end
		end
	end)
end

function _M.show(maximized)
	if maximized then
		user32.ShowWindow(_M.window, 'SW_SHOWMAXIMIZED')
	else
		user32.ShowWindow(_M.window, 'SW_SHOW')
	end
end

function _M.hide()
	user32.ShowWindow(_M.window, 'SW_HIDE')
end

function _M.cleanup()
	nb.kill_thread(_M.gui_thread)
	user32.DestroyWindow(_M.window)
	assert(_M.gui_thread)
end

function _M.capture_cursor()
	user32.SetCapture(_M.window)
end

function _M.release_cursor()
	user32.SetCapture(nil)
end

------------------------------------------------------------------------------

function _M.message_box(message)
	local title
	if _M.window then
		local len = assert(user32.GetWindowTextLength(_M.window))
		title = assert(user32.GetWindowText(_M.window, len + 1))
	else
		title = default_title
	end
	user32.MessageBox(_M.window, message, title, nil)
end

------------------------------------------------------------------------------

local focus_items = {}
local ifocus = 1
_M.focus = focus_items[ifocus] or '(none)'

local function focuschange(offset)
	local id
	for i,item in ipairs(focus_items) do
		if item==_M.focus then
			id = i
			break
		end
	end
	id = id + offset
	if id > #focus_items then id = 1 end
	if id < 1 then id = #focus_items end
	_M.focus = focus_items[id] or '(none)'
	emit(_M, 'focus_changed')
end

function _M.addfocus(item)
	if #focus_items == 0 then
		focus_items[1] = item
		emit(_M, 'focus_changed')
	else
		table.insert(focus_items, item)
	end
end

function _M.remfocus(item)
	local id
	for i,item2 in ipairs(focus_items) do
		if item2==item then
			id = i
			break
		end
	end
	if id==ifocus and #focus_items>1 then
		focuschange(1)
	end
	table.remove(focus_items, id)
	if #focus_items == 0 then
		emit(_M, 'focus_changed')
	end
end

function _M.focusnext()
	focuschange(1)
end

function _M.focusprev()
	focuschange(-1)
end

function _M.setfocus(item)
	_M.focus = item
	emit(_M, 'focus_changed')
end

------------------------------------------------------------------------------

function _M.os_report()
	local version = assert(kernel32.GetVersionEx())
	local report = {
		type = 'windows',
		version = {
			major = version.dwMajorVersion,
			minor = version.dwMinorVersion,
			build = version.dwBuildNumber,
		},
	}
	local x = version.wServicePackMajor
	local y = version.wServicePackMinor
	local s = version.szCSDVersion:gsub('%z*$', '')
	if x~=0 or y~=0 or s~="" then
		report.service_pack = {
			major = x,
			minor = y,
			name = s,
		}
	end
	local platforms = {
		VER_PLATFORM_WIN32s = 'win32s',
		VER_PLATFORM_WIN32_WINDOWS = 'windows',
		VER_PLATFORM_WIN32_NT = 'nt',
	}
	for flag,text in pairs(platforms) do
		local value = assert(win32[flag])
		if version.dwPlatformId==value then
			report.platform = text
		end
	end
	local products = {
		VER_NT_WORKSTATION = "workstation",
		VER_NT_SERVER = "server",
		VER_NT_DOMAIN_CONTROLLER = "domain_controller",
	}
	for flag,text in pairs(products) do
		local value = assert(win32[flag])
		if version.wProductType==value then
			report.product = text
		end
	end
	local suites = {
		VER_SUITE_BACKOFFICE = "backoffice",
		VER_SUITE_BLADE = "blade",
		VER_SUITE_COMPUTE_SERVER = "compute_server",
		VER_SUITE_DATACENTER = "datacenter",
		VER_SUITE_ENTERPRISE = "enterprise",
		VER_SUITE_EMBEDDEDNT = "embeddednt",
		VER_SUITE_PERSONAL = "personal",
		VER_SUITE_SINGLEUSERTS = "singleuserts",
		VER_SUITE_SMALLBUSINESS = "smallbusiness",
		VER_SUITE_SMALLBUSINESS_RESTRICTED = "smallbusiness_restricted",
		VER_SUITE_STORAGE_SERVER = "storage_server",
		VER_SUITE_TERMINAL = "terminal",
		VER_SUITE_WH_SERVER = "wh_server",
	}
	report.suite = {}
	for flag,text in pairs(suites) do
		local bit = assert(win32[flag])
		if (version.wSuiteMask & bit)~=0 then
			table.insert(report.suite, text)
		end
	end
	table.sort(report.suite)
	return report
end

------------------------------------------------------------------------------

local function gl_clear_errors(limit)
	-- clear errors (that may have stacked)
	-- limit because on some implementations and in some situations GetError doesn't clear some errors
	for i=1,limit or 10 do
		if gl.GetError() == gl.NO_ERROR then
			break
		end
	end
end

local report_strings = {
	'vendor',
	'renderer',
	'version',
	'shading_language_version',
}
local report_integers = {
	'max_texture_size',
	'max_vertex_texture_image_units',
	'max_texture_image_units',
	'max_geometry_texture_image_units',
	'max_texture_max_anisotropy_ext',
	'max_clip_distances',
--	'max_framebuffer_samples',
	'max_samples',
}
local report_dimensions = {
	'max_viewport_dims',
}

function _M.gl_report()
	local report = {}
	for _,string in ipairs(report_strings) do
		report[string] = gl.GetString(string:upper())
	end
	for _,integer in ipairs(report_integers) do
		report[integer] = gl.GetIntegerv(integer:upper())[1]
	end
	for _,dimensions in ipairs(report_dimensions) do
		local t = gl.GetIntegerv(dimensions:upper())
		report[dimensions] = { width = t[1], height = t[2] }
	end
	gl_clear_errors()
	local extensions = {}
	if not report.version:match('^[1-2]%.') then
		local t = gl.GetIntegerv('NUM_EXTENSIONS')
		if t and t[1] then
			for i=1,t[1] do
				local extension = gl.GetStringi('EXTENSIONS', i-1)
				table.insert(extensions, extension)
			end
		end
	end
	if #extensions == 0 then
		local str = gl.GetString('EXTENSIONS')
		if str then
			for extension in str:gmatch('%S+') do
				table.insert(extensions, extension)
			end
		end
	end
	table.sort(extensions)
	report.extensions = extensions
	gl_clear_errors()
	return report
end

function _M.setup_gl_context(parent)
	assert(parent==_M.window)
	
	_M.dc = assert(user32.GetDC(_M.window))
	
	local format = assert(gdi32.ChoosePixelFormat(_M.dc, win32.new 'PIXELFORMATDESCRIPTOR' {
		dwFlags = {'PFD_DRAW_TO_WINDOW', 'PFD_SUPPORT_OPENGL', 'PFD_DOUBLEBUFFER', 'PFD_STEREO_DONTCARE'},
		iPixelType = 'PFD_TYPE_RGBA',
		cColorBits = 24,
		cAlphaBits = 8,
		iLayerType = 'PFD_MAIN_PLANE',
	}))
	assert(gdi32.SetPixelFormat(_M.dc, format))
	
	if force_core_profile then
		local tempRC = assert(opengl32.wglCreateContext(_M.dc))
		assert(opengl32.wglMakeCurrent(_M.dc, tempRC))
		local attribs = {
			WGL_CONTEXT_MAJOR_VERSION_ARB = force_core_profile[1],
			WGL_CONTEXT_MINOR_VERSION_ARB = force_core_profile[2],
		--	WGL_CONTEXT_FLAGS_ARB = assert(gl.WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB),
			WGL_CONTEXT_PROFILE_MASK_ARB = assert(gl.WGL_CONTEXT_CORE_PROFILE_BIT_ARB)
		}
		_M.rc1 = assert(gl.CreateContextAttribsARB(_M.dc, nil, attribs))
		_M.rc2 = assert(gl.CreateContextAttribsARB(_M.dc, _M.rc1, attribs))
		assert(opengl32.wglMakeCurrent(nil, nil))
		assert(opengl32.wglDeleteContext(tempRC))
	else
		_M.rc1 = assert(opengl32.wglCreateContext(_M.dc))
		_M.rc2 = assert(opengl32.wglCreateContext(_M.dc))
		assert(opengl32.wglShareLists(_M.rc1, _M.rc2))
	end
	assert(opengl32.wglMakeCurrent(_M.dc, _M.rc1))
	
	_M.vsync_event = assert(kernel32.CreateEvent(nil, false, false, nil))
end

function _M.start_gl_thread(...)
	local handle,id = assert(kernel32.CreateThread(nil, nil, nil, [[
		local render = require 'engine.render'
		return render.ThreadProc(...)
	]], _M.window, _M.dc, _M.rc2, _M.vsync_event, ...))
--	assert(kernel32.SetThreadAffinityMask(kernel32.GetCurrentThread(), 1))
--	assert(kernel32.SetThreadAffinityMask(handle, 2))
	_M.gl_thread = handle
	_M.gl_thread_id = id
	_M.gl_metathread = nb.add_thread(function()
		nb.wait_for_system_object(handle)
		kernel32.GetExitCodeThread(handle) -- if the thread had an error, GetExitCodeThread will rethrow it
		error("GL thread terminated unexpectedly")
	end)
	_M.vsync_thread = nb.add_thread(function()
		while true do
			nb.wait_for_system_object(_M.vsync_event)
			emit(_M, 'vsync')
		end
	end)
end

function _M.init_gl(parent, ...)
	_M.setup_gl_context(parent)
	_M.start_gl_thread(...)
end

function _M.stop_gl_thread()
	if _M.vsync_thread then
		nb.kill_thread(_M.vsync_thread)
		_M.vsync_thread = nil
	end
	if _M.gl_metathread then
		nb.kill_thread(_M.gl_metathread)
		_M.gl_metathread = nil
	end
	if _M.gl_thread_id or _M.gl_thread then
		assert(_M.gl_thread_id and _M.gl_thread)
		user32.PostThreadMessage(_M.gl_thread_id, win32.WM_QUIT, 0, 0) -- :NOTE: this fails if the thread crashed before creating a message queue
		assert(kernel32.WaitForSingleObject(_M.gl_thread, win32.INFINITE)==win32.WAIT_OBJECT_0)
		assert(kernel32.CloseHandle(_M.gl_thread))
		_M.gl_thread_id = nil
		_M.gl_thread = nil
	end
end

function _M.cleanup_gl_context()
	if _M.vsync_event then
		kernel32.CloseHandle(_M.vsync_event)
		_M.vsync_event = nil
	end
	assert(opengl32.wglMakeCurrent(nil, nil))
	if _M.rc2 then
		assert(opengl32.wglDeleteContext(_M.rc2))
		_M.rc2 = nil
	end
	if _M.rc1 then
		assert(opengl32.wglDeleteContext(_M.rc1))
		_M.rc1 = nil
	end
	if _M.dc then
		assert(user32.ReleaseDC(_M.window, _M.dc))
		_M.dc = nil
	end
end

function _M.cleanup_gl()
	_M.stop_gl_thread()
	_M.cleanup_gl_context()
end

------------------------------------------------------------------------------

return _M
