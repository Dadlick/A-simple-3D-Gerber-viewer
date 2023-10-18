local math = require 'math'
local table = require 'table'
local debug = require 'debug'
local string = require 'string'
local coroutine = require 'coroutine'
local win32 = require 'win32'
local kernel32 = require 'win32.kernel32'
local user32 = require 'win32.user32'
local ws2_32 = require 'win32.ws2_32'
local ntdll = require 'win32.ntdll'
local WinUsb = require 'win32.winusb'
local function pack(...) return {n=_G.select('#', ...), ...} end
local unpack = unpack or table.unpack

assert(ws2_32.WSAStartup(0x202))

local _M = {}

_M.engine = 'lwin32'

local token = {}

------------------------------------------------------------------------------
-- time management

local frequency = kernel32.QueryPerformanceFrequency()
local function getcurrenttime()
	return kernel32.QueryPerformanceCounter() / frequency
end

local function sleep(delay)
	kernel32.Sleep(delay * 1000)
end

------------------------------------------------------------------------------
-- message only window

local async_class = assert(user32.RegisterClassEx(win32.new 'WNDCLASSEX' {
	lpszClassName = 'nb message-only window',
	lpfnWndProc = function(window, message, wparam, lparam)
		return user32.DefWindowProc(window, message, wparam, lparam)
	end,
}))
local async_window = assert(user32.CreateWindowEx(
	nil,
	async_class,
	nil,
	nil,
	nil, nil, nil, nil,
	win32.HWND_MESSAGE, nil, nil
))
local async_message = win32.WM_USER

local async_events = {
	accept = assert(win32.FD_ACCEPT),
	connect = assert(win32.FD_CONNECT),
	read = assert(win32.FD_READ),
	write = assert(win32.FD_WRITE),
	close = assert(win32.FD_CLOSE),
}
local async_events_reverse = {}
for k,v in pairs(async_events) do async_events_reverse[v] = k end
local all_events = win32.FD_ACCEPT + win32.FD_CONNECT + win32.FD_READ + win32.FD_WRITE + win32.FD_CLOSE

------------------------------------------------------------------------------
-- event loop

local timeouts = {} -- array: index -> { when = when, thread = thread }
local sequences = {} -- map: thread -> thread
local resumables = {} -- map: thread -> {resume_args}
local queue_pop = {} -- map: queue -> thread
local queue_flush = {} -- map: queue -> thread
local pipes = {} -- map: pipe -> thread
local handles = {} -- map: handle -> map: thread -> true
local handle_by_overlapped = {} -- map: overlapped -> handle
local overlapped_by_thread = {} -- map: thread -> overlapped
local finished_threads = setmetatable({}, {__mode='k'}) -- set
local async_select = {} -- map: socket -> map: event -> set: thread
local message_thread = nil -- thread

local function unregister_thread(thread)
	for socket,sthreads in pairs(async_select) do
		for event,ethreads in pairs(sthreads) do
			ethreads[thread] = nil
			if next(ethreads)==nil then
				sthreads[event] = nil
			end
			if next(sthreads)==nil then
				async_select[socket] = nil
			end
		end
	end
	for handle,hthreads in pairs(handles) do
		hthreads[thread] = nil
		if not next(hthreads) then
			handles[handle] = nil
		end
	end
	for i = #timeouts,1,-1 do
		if timeouts[i].thread==thread then
			table.remove(timeouts, i)
		end
	end
	for first,second in pairs(sequences) do
		if thread==second then
			sequences[first] = nil
		end
	end
	resumables[thread] = nil
	for queue,qthread in pairs(queue_pop) do
		if thread==qthread then
			queue_pop[queue] = nil
		end
	end
	for queue,qthread in pairs(queue_flush) do
		if thread==qthread then
			queue_flush[queue] = nil
		end
	end
	for pipe,pthread in pairs(pipes) do
		if thread==pthread then
			pipes[pipe] = nil
		end
	end
	if message_thread==thread then
		message_thread = nil
	end
end

local function time_comp(a, b)
	return a.when < b.when
end

local function resume_later(thread, ...)
	resumables[thread] = pack(...)
end

local function finish_thread(thread)
	-- mark the thread as finished for future waits
	finished_threads[thread] = true
	-- resume pending wait if any
	local first = thread
	local second = sequences[first]
	if second then
		sequences[first] = nil
		resume_later(second)
	end
end

local function resume(thread, ...)
	-- unregister the thread: it's about to be resumed, so it's no longer waiting on anything
	unregister_thread(thread)
	
	-- resume the thread
	local result = pack(coroutine.resume(thread, ...))
	
	-- forward yields not targeted at us
	while result[1] and coroutine.status(thread)=='suspended' and result[2]~=token do
		result = pack(coroutine.resume(thread, coroutine.yield(unpack(result, 2, result.n))))
	end
	
	-- handle error
	if not result[1] then
		error(debug.traceback(thread, result[2]))
	end
	
	-- if the thread is suspended, save it
	local finished = false
	if coroutine.status(thread)=='suspended' then
		local reason = result[3]
		if reason=='exit' then
			finished = true
		elseif reason=='wait' then
			local condition = unpack(result, 4, 4)
			local t = type(condition)
			if t=='number' then
				local timeout = condition
				local when = getcurrenttime() + timeout
				timeouts[#timeouts+1] = { when = when, thread = thread }
				table.sort(timeouts, time_comp)
			elseif t=='thread' then
				local first = condition
				local second = thread
				sequences[first] = second
			else
				error(debug.traceback(thread, "unsupported condition type "..t.." for wait"))
			end
		elseif reason=='queue_pop' then
			local queue = result[4]
			if queue_pop[queue] then
				error(debug.traceback(thread, "another thread is already waiting to pop on that queue"))
			end
			queue_pop[queue] = thread
		elseif reason=='queue_flush' then
			local queue = result[4]
			if queue_flush[queue] then
				error(debug.traceback(thread, "another thread is already waiting to flush that queue"))
			end
			queue_flush[queue] = thread
		elseif reason=='pipe' then
			local pipe = result[4]
			if pipes[pipe] then
				error(debug.traceback(thread, "another thread is already waiting on that pipe"))
			end
			pipes[pipe] = thread
		elseif reason=='handle' then
			local handle = result[4]
			if not handles[handle] then
				handles[handle] = {}
			end
			handles[handle][thread] = true
		elseif reason=='async_select' then
			local socket = result[4]
			local events = result[5]
			if type(events)=='string' then events = {events} end
			local sthreads = async_select[socket]
			if not sthreads then
				sthreads = {}
				async_select[socket] = sthreads
			end
			for _,event in ipairs(events) do
				local ethreads = sthreads[event]
				if not ethreads then
					ethreads = {}
					sthreads[event] = ethreads
				end
				ethreads[thread] = true
			end
		elseif reason=='message' then
			message_thread = thread
		else
			_G.print("thread yielded with unknown reason:", unpack(result, 3, result.n))
		end
	else
		finished = true
	end
	if finished then
		finish_thread(thread)
	end
end

function _M.run(f, ...)
	if type(f)=='function' then
		_M.add_thread_later(f, ...)
	end
	local did_something = false
	while next(resumables) or next(timeouts) or next(handles) or next(async_select) or message_thread do
		did_something = true
		-- if a thread is already resumable, resume it
		-- pick one randomly (:TODO: implement some fair scheduling)
		local thread,args = next(resumables)
		if thread then
			unregister_thread(thread)
			resume(thread, unpack(args, 1, args.n))
		else
			-- compute the timeout value
			local timeout
			if #timeouts >= 1 then
				local now = getcurrenttime()
				local then_ = timeouts[1].when
				timeout = then_ - now
				if timeout < 0 then
					-- negative timeout mean we're late, so don't wait at all
					timeout = 0
				end
			end
			
			-- build handle array
			local ahandles = {}
			for handle in pairs(handles) do table.insert(ahandles, handle) end
			
			-- call blocking core
			local reason
			if next(async_select) or message_thread then
				reason = assert(user32.MsgWaitForMultipleObjects(ahandles, false, timeout and math.floor(timeout * 1000 + 0.5) or win32.INFINITE, win32.QS_ALLINPUT))
			else
				if #ahandles > 0 then
					reason = assert(kernel32.WaitForMultipleObjects(ahandles, false, timeout and timeout * 1000 or win32.INFINITE))
				else
					sleep(timeout)
					reason = win32.WAIT_TIMEOUT
				end
			end
			
			if win32.WAIT_OBJECT_0 <= reason and reason < (win32.WAIT_OBJECT_0 + #ahandles) then
				-- find selected thread
				local ihandle = reason - win32.WAIT_OBJECT_0 + 1
				local handle = ahandles[ihandle]
				local threads = handles[handle]
				
				-- resume the threads
				for thread in pairs(threads) do
					resume_later(thread, handle)
				end
				
			elseif reason == (win32.WAIT_OBJECT_0 + #ahandles) then
				-- this case can happen even if no user message is available
				-- PeekMessage will process internal events
				local msg
				if message_thread then
					msg = user32.PeekMessage(nil, nil, nil, win32.PM_REMOVE)
				else
					msg = user32.PeekMessage(async_window, nil, nil, win32.PM_REMOVE)
				end
				-- loop since the first Peek will mark all messages as read
				-- and subsequent MsgWaitForMultipleObjects would block
				while msg do
					if msg.hwnd==async_window and msg.message==async_message then
						local socket = msg.wParam
						local event = async_events_reverse[win32.WSAGETSELECTEVENT(msg.lParam)]
						local errno = win32.WSAGETSELECTERROR(msg.lParam)
						if errno==0 then errno = nil end
						local msg
						if errno then
							msg = assert(kernel32.FormatMessage('FORMAT_MESSAGE_FROM_SYSTEM', errno, 0))
						end
						
						-- find selected thread
						local sthreads = async_select[socket]
						if sthreads then
							local ethreads = sthreads[event]
							if ethreads then
								for thread in pairs(ethreads) do
									unregister_thread(thread)
									resume_later(thread, event, msg, errno)
								end
							end
						end
					elseif message_thread then
						-- resume immediately, so that a loop on get_message would get all messages
						resume(message_thread, msg)
					else
						-- no-op, discard message
					end
					if message_thread then
						msg = user32.PeekMessage(nil, nil, nil, win32.PM_REMOVE)
					else
						msg = user32.PeekMessage(async_window, nil, nil, win32.PM_REMOVE)
					end
				end
				
			elseif reason == win32.WAIT_TIMEOUT then
				-- do nothing, timeouts are treated unconditionnally below
				
			else
				error("unsupported result from WaitForMultipleObjects: "..tostring(reason))
			end
			
			-- process timeouts
			if #timeouts >= 1 then
				local now = getcurrenttime()
				while timeouts[1] and timeouts[1].when <= now do
					-- find selected thread
					local thread = timeouts[1].thread
					
					-- resume the thread
					resume_later(thread, {})
					table.remove(timeouts, 1)
				end
			end
		end
	end
	return did_something
end

------------------------------------------------------------------------------
-- threading

local thread_names = setmetatable({}, {__mode='k'})

function _M.add_thread(f, ...)
	_G.assert(_G.type(f)=='function', debug.traceback("f has type '".._G.type(f).."'"))
	local thread = coroutine.create(f)
	resume(thread, ...)
	return thread
end

function _M.add_thread_later(f, ...)
	_G.assert(_G.type(f)=='function', debug.traceback("f has type '".._G.type(f).."'"))
	local thread = coroutine.create(f)
	resume_later(thread, ...)
	return thread
end

function _M.set_thread_name(name)
	local thread = assert(coroutine.running(), "cannot set main thread name")
	thread_names[thread] = name
end

function _M.exit_thread()
	coroutine.yield(token, 'exit')
end

local killing = {}

function _M.kill_thread(thread)
	local overlapped = overlapped_by_thread[thread]
	if overlapped then
		-- find the associated file/socket handle
		local handle = assert(handle_by_overlapped[overlapped])
		-- cancel the pending I/O
		local success,msg,errno = kernel32.CancelIoEx(handle, overlapped)
		-- :NOTE: the operation may have already finished by the time we get here
		if not success and errno~=win32.ERROR_NOT_FOUND then
			error(msg)
		end
		-- the thread is not really killed, but as soon as the core loop runs
		-- it should be resumed and die by itself without running any user code
		killing[thread] = true
		return
	end
	unregister_thread(thread)
	finish_thread(thread)
end

function _M.thread_name(thread)
	return (thread_names[thread] or "<unnamed>").." ("..tostring(thread)..")"
end

local function all_threads()
	local threads = {}
	for _,timeout in ipairs(timeouts) do
		assert(not threads[timeout.thread])
		threads[timeout.thread] = 'timeout'
	end
	for _,thread in pairs(sequences) do
		assert(not threads[thread])
		threads[thread] = 'sequence'
	end
	for thread in pairs(resumables) do
		assert(not threads[thread])
		threads[thread] = 'resumable'
	end
	for _,thread in pairs(queue_pop) do
		assert(not threads[thread])
		threads[thread] = 'queue pop'
	end
	for _,thread in pairs(queue_flush) do
		assert(not threads[thread])
		threads[thread] = 'queue flush'
	end
	for _,thread in pairs(pipes) do
		assert(not threads[thread])
		threads[thread] = 'pipe'
	end
	for _,threads2 in pairs(handles) do
		for thread in pairs(threads2) do
			assert(not threads[thread])
			threads[thread] = 'handle'
		end
	end
	local events = {} -- map: thread -> array: event
	for socket,sthreads in pairs(async_select) do
		for event,ethreads in pairs(sthreads) do
			for thread in pairs(ethreads) do
				local t = events[thread]
				if not t then
					t = {}
					events[thread] = t
				end
				table.insert(t, event)
			end
		end
	end
	for thread,events in pairs(events) do
		assert(not threads[thread])
		threads[thread] = 'async_select '..table.concat(events, ' ')
	end
	if message_thread then
		threads[message_thread] = 'message'
	end
	return threads
end

function _M.kill_all_threads()
	local threads = all_threads()
	for thread in pairs(threads) do
		_M.kill_thread(thread)
	end
end

function _M.status()
	local reasons = all_threads()
	
	local threads = {}
	for thread,reason in pairs(reasons) do
		table.insert(threads, _M.thread_name(thread)..": "..reason)
	end
	table.sort(threads)
	
	local result = {}
	table.insert(result, string.format("Threads: (%d)", #threads))
	for _,line in ipairs(threads) do
		table.insert(result, "\t"..line)
	end
	return table.concat(result, "\n")
end

------------------------------------------------------------------------------
-- win32 overlapped I/O helpers

local function overlapped_read(handle, event, length, where)
	local thread = coroutine.running()
	local overlapped = win32.new 'OVERLAPPED' {
		hEvent = event,
		Offset = where and where % 2^32,
		OffsetHigh = where and math.floor(where / 2^32),
	}
	local result,msg,errno = kernel32.ReadFile(handle, length, overlapped)
	if not result then
		if errno==win32.ERROR_HANDLE_EOF or errno==win32.ERROR_BROKEN_PIPE then
			result,msg,errno = ""
		else
			return nil,msg,errno
		end
	end
	if msg=='ERROR_IO_PENDING' then
		local bytes
		repeat
			overlapped_by_thread[thread] = overlapped
			handle_by_overlapped[overlapped] = handle
			coroutine.yield(token, 'handle', overlapped.hEvent)
			handle_by_overlapped[overlapped] = nil
			overlapped_by_thread[thread] = nil
			bytes,msg,errno = kernel32.GetOverlappedResult(handle, overlapped, false)
		until bytes or errno~=win32.ERROR_IO_INCOMPLETE
		if killing[thread] then
			killing[thread] = nil
			_M.exit_thread()
		elseif bytes then
			result = tostring(result):sub(1, bytes)
		elseif errno==win32.ERROR_HANDLE_EOF or errno==win32.ERROR_BROKEN_PIPE then
			result = ""
	--	elseif errno==win32.ERROR_OPERATION_ABORTED then
	--		_M.exit_thread()
		elseif errno==win32.ERROR_NETNAME_DELETED then
			return nil,'aborted'
		else
			return nil,msg,errno
		end
	end
	return result
end

local function overlapped_write(handle, event, data, where)
	local thread = coroutine.running()
	local overlapped = win32.new 'OVERLAPPED' {
		hEvent = event,
		Offset = where and where % 2^32,
		OffsetHigh = where and math.floor(where / 2^32),
	}
	local result,msg,errno = kernel32.WriteFile(handle, data, overlapped)
	if not result then
		if errno==win32.ERROR_BROKEN_PIPE or errno==win32.ERROR_NO_DATA then
			result,msg,errno = 0
		else
			return nil,msg,errno
		end
	end
	if msg=='ERROR_IO_PENDING' then -- 'result' holds a buffer
		local bytes
		repeat
			overlapped_by_thread[thread] = overlapped
			handle_by_overlapped[overlapped] = handle
			coroutine.yield(token, 'handle', overlapped.hEvent)
			handle_by_overlapped[overlapped] = nil
			overlapped_by_thread[thread] = nil
			bytes,msg,errno = kernel32.GetOverlappedResult(handle, overlapped, false)
		until bytes or errno~=win32.ERROR_IO_INCOMPLETE
		if killing[thread] then
			killing[thread] = nil
			_M.exit_thread()
		elseif bytes then
			result = bytes
		elseif errno==win32.ERROR_BROKEN_PIPE or errno==win32.ERROR_NO_DATA then
			result = 0
	--	elseif errno==win32.ERROR_OPERATION_ABORTED then
	--		_M.exit_thread()
		else
			return nil,msg,errno
		end
	end
	return result
end

local function overlapped_ioctl(handle, event, code, input, output)
	local thread = coroutine.running()
	local overlapped = win32.new 'OVERLAPPED' {
		hEvent = event,
	}
	local result,msg,errno = kernel32.DeviceIoControl(handle, code, input, output, overlapped)
	if not result then
		return nil,msg,errno
	end
	if msg=='ERROR_IO_PENDING' then -- 'result' is a table with input and output buffers
		local bytes
		repeat
			overlapped_by_thread[thread] = overlapped
			handle_by_overlapped[overlapped] = handle
			coroutine.yield(token, 'handle', overlapped.hEvent)
			handle_by_overlapped[overlapped] = nil
			overlapped_by_thread[thread] = nil
			bytes,msg,errno = kernel32.GetOverlappedResult(handle, overlapped, false)
		until bytes or errno~=win32.ERROR_IO_INCOMPLETE
		if killing[thread] then
			killing[thread] = nil
			_M.exit_thread()
		elseif bytes then
			if type(output)=='number' then
				result = tostring(result.output):sub(1, bytes)
			else
				result = result.output
			end
	--	elseif errno==win32.ERROR_OPERATION_ABORTED then
	--		_M.exit_thread()
		else
			return nil,msg,errno
		end
	end
	return result
end

------------------------------------------------------------------------------
-- time

function _M.wait(condition)
	if type(condition)=='thread' then
		if finished_threads[condition] then
			return
		end
	end
	return coroutine.yield(token, 'wait', condition)
end

-- separate function since the object could be a number (fd, handle) which conflicts with timed wait
function _M.wait_for_system_object(object)
	return coroutine.yield(token, 'handle', object)
end

------------------------------------------------------------------------------
-- messaging

function _M.get_message()
	return coroutine.yield(token, 'message')
end

------------------------------------------------------------------------------
-- queues

local queue_methods = {}
local queue_getters = {}
local queue_mt = {}
local queue_data = setmetatable({}, {__mode='k'})

function queue_mt:__index(k)
	local getter = queue_getters[k]
	if getter ~= nil then
		return getter(self)
	end
	return queue_methods[k]
end

function _M.queue()
	local self = {}
	local data = {self=self}
	queue_data[self] = data
	data.head = 1
	data.tail = 0
	setmetatable(self, queue_mt)
	return self
end

function queue_getters:empty()
	local data = queue_data[self]
	return data.head > data.tail
end

function queue_getters:length()
	local data = queue_data[self]
	return math.max(0, data.tail - data.head + 1)
end

function queue_methods:pop()
	local data = queue_data[self]
	if self.empty then
		coroutine.yield(token, 'queue_pop', self)
	end
	local head = data.head
	local value = data[head]
	data[head] = nil
	data.head = head + 1
	if self.empty then
		local thread = queue_flush[self]
		if thread then
			resume_later(thread)
		end
	end
	return value
end

function queue_methods:push(value)
	local data = queue_data[self]
	local tail = data.tail + 1
	data[tail] = value
	data.tail = tail
	local thread = queue_pop[self]
	if thread then
		queue_pop[self] = nil
		resume_later(thread)
	end
	return true
end

function queue_methods:flush()
	local data = queue_data[self]
	if not self.empty then
		coroutine.yield(token, 'queue_flush', self)
	end
	return true
end

------------------------------------------------------------------------------
-- pipes

local pipe_methods = {}
local pipe_mt = {__index=pipe_methods}
local pipe_data = setmetatable({}, {__mode='k'})

function _M.pipe()
	local self = {}
	local data = {self=self}
	pipe_data[self] = data
	data.buffer = ""
	setmetatable(self, pipe_mt)
	return self
end

function pipe_methods:read(size)
	local data = pipe_data[self]
	while #data.buffer < size do
		coroutine.yield(token, 'pipe', self)
	end
	local result = data.buffer:sub(1, size)
	data.buffer = data.buffer:sub(size+1)
	return result
end

function pipe_methods:write(bytes)
	local data = pipe_data[self]
	data.buffer = data.buffer..bytes
	local thread = pipes[self]
	if thread then
		resume_later(thread)
	end
	return true
end

------------------------------------------------------------------------------
-- Windows named pipes

local named_pipe_methods = {}
local named_pipe_getters = {}
local named_pipe_setters = {}
local named_pipe_mt = {}
local named_pipe_data = setmetatable({}, {__mode='k'})

function named_pipe_mt:__index(k)
	local getter = named_pipe_getters[k]
	if getter ~= nil then
		return getter(self)
	end
	return named_pipe_methods[k]
end

function named_pipe_mt:__newindex(k, v)
	local setter = named_pipe_setters[k]
	if setter ~= nil then
		return setter(self, v)
	end
	error("no setter for "..tostring(k))
end

function _M.named_pipe(name)
	local self = {}
	local data = {self=self}
	named_pipe_data[self] = data
	
	-- create the pipe
	data.name = [[\\.\pipe\]]..name
	local handle,msg,errno = kernel32.CreateNamedPipe(
		data.name,
		{'PIPE_ACCESS_DUPLEX', 'FILE_FLAG_OVERLAPPED'},
		{'PIPE_TYPE_MESSAGE', 'PIPE_READMODE_MESSAGE', 'PIPE_WAIT', 'PIPE_ACCEPT_REMOTE_CLIENTS'},
		win32.PIPE_UNLIMITED_INSTANCES,
		0, 0, 0, nil)
	if not handle then return nil,msg,errno end
	data.handle = handle
	
	-- create an event for overlapped I/O
	local event,msg,errno = kernel32.CreateEvent()
	if not event then
		kernel32.CloseHandle(handle)
		return nil,msg,errno
	end
	data.event = event
	
	setmetatable(self, named_pipe_mt)
	return self
end

function named_pipe_getters:handle()
	local data = named_pipe_data[self]
	return data.handle
end

function named_pipe_methods:connect()
	local data = named_pipe_data[self]
	
	-- wait for a client connection
	local thread = coroutine.running()
	local overlapped = win32.new 'OVERLAPPED' {
		hEvent = data.event,
	}
	local success,msg,errno = kernel32.ConnectNamedPipe(data.handle, overlapped)
	if errno==win32.ERROR_IO_PENDING then
		repeat
			overlapped_by_thread[thread] = overlapped
			handle_by_overlapped[overlapped] = data.handle
			coroutine.yield(token, 'handle', overlapped.hEvent)
			handle_by_overlapped[overlapped] = nil
			overlapped_by_thread[thread] = nil
			success,msg,errno = kernel32.HasOverlappedIoCompleted(overlapped)
		until success or errno~=win32.ERROR_IO_PENDING
		if killing[thread] then
			killing[thread] = nil
			_M.exit_thread()
		end
	end
	if not success then return nil,msg end
	
	return true
end

function named_pipe_methods:disconnect()
	local data = named_pipe_data[self]
	
	local success,msg = kernel32.DisconnectNamedPipe(data.handle)
	if not success then return nil,msg end
	
	return true
end

local function named_pipe_overlapped_read(handle, event, length, where)
	local thread = coroutine.running()
	local overlapped = win32.new 'OVERLAPPED' {
		hEvent = event,
		Offset = where and where % 2^32,
		OffsetHigh = where and math.floor(where / 2^32),
	}
	local results = {}
	repeat
		local result,msg,errno = kernel32.ReadFile(handle, length, overlapped)
		if not result then
			if errno==win32.ERROR_HANDLE_EOF or errno==win32.ERROR_BROKEN_PIPE then
				result,msg,errno = ""
			else
				return nil,msg,errno
			end
		end
		if msg=='ERROR_IO_PENDING' then
			local bytes
			repeat
				overlapped_by_thread[thread] = overlapped
				handle_by_overlapped[overlapped] = handle
				coroutine.yield(token, 'handle', overlapped.hEvent)
				handle_by_overlapped[overlapped] = nil
				overlapped_by_thread[thread] = nil
				bytes,msg,errno = kernel32.GetOverlappedResult(handle, overlapped, false)
			until bytes or errno~=win32.ERROR_IO_INCOMPLETE
			if killing[thread] then
				killing[thread] = nil
				_M.exit_thread()
			elseif bytes then
				result = tostring(result):sub(1, bytes)
			elseif errno==win32.ERROR_HANDLE_EOF or errno==win32.ERROR_BROKEN_PIPE then
				result = ""
		--	elseif errno==win32.ERROR_OPERATION_ABORTED then
		--		_M.exit_thread()
			elseif errno==win32.ERROR_NETNAME_DELETED then
				return nil,'aborted'
			else
				return nil,msg,errno
			end
		end
		table.insert(results, result)
	until msg ~= 'ERROR_MORE_DATA'
	return table.concat(results)
end

function named_pipe_methods:read(size)
	local data = named_pipe_data[self]
	local result,msg = named_pipe_overlapped_read(data.handle, data.event, size)
	if result=="" then
		return nil,'closed'
	elseif result then
		return result
	else
		return nil,msg
	end
end

function named_pipe_methods:write(bytes)
	local data = named_pipe_data[self]
	local result,msg = overlapped_write(data.handle, data.event, bytes)
	if result then
		return result
	else
		return nil,msg
	end
end

function named_pipe_methods:close()
	local data = named_pipe_data[self]
	for overlapped,handle in pairs(handle_by_overlapped) do
		if handle == data.socket then error("trying to close a named pipe with pending I/O", 2) end
	end
	kernel32.CloseHandle(data.event)
	return kernel32.CloseHandle(data.handle)
end

------------------------------------------------------------------------------
-- TCP-like sockets

local tcp_methods = {}
local tcp_getters = {}
local tcp_mt = {}
local tcp_data = setmetatable({}, {__mode='k'})

function tcp_mt:__index(k)
	local getter = tcp_getters[k]
	if getter ~= nil then
		return getter(self)
	end
	return tcp_methods[k]
end

function _M.tcp()
	local self = {}
	local data = {self=self}
	tcp_data[self] = data
	
	-- create the socket
	local socket,msg,errno = ws2_32.socket(win32.AF_INET, win32.SOCK_STREAM, win32.IPPROTO_TCP)
	if not socket then return nil,msg,errno end
	
	-- set the socket as non blocking
	local success,msg,errno = ws2_32.WSAAsyncSelect(socket, async_window, async_message, all_events)
	if not success then
		ws2_32.closesocket(socket)
		return nil,msg,errno
	end
	
	data.socket = socket
	setmetatable(self, tcp_mt)
	return self
end

function tcp_methods:bind(address, port)
	local data = tcp_data[self]
	if address=='*' then address = '0.0.0.0' end
	local addr = win32.new.SOCKADDR_STORAGE()
	addr.ss_family = win32.AF_INET
	addr.sin_addr = select(2, assert(ntdll.RtlIpv4StringToAddress(address)))
	addr.sin_port = port or 0
	local result,msg,errno = ws2_32.bind(data.socket, addr)
	if not result then return nil,msg,errno end
	return true
end

function tcp_getters:socket()
	local data = tcp_data[self]
	return data.socket
end

function tcp_getters:port()
	local data = tcp_data[self]
	local addr,msg,errno = ws2_32.getsockname(data.socket)
	if not addr then return nil,msg,errno end
	return addr.sin_port
end

function tcp_getters:peer_address()
	local data = tcp_data[self]
	local addr,msg,errno = ws2_32.getpeername(data.socket)
	if not addr then return nil,msg,errno end
	return string.format('%d.%d.%d.%d',
		addr.sin_addr.s_b1,
		addr.sin_addr.s_b2,
		addr.sin_addr.s_b3,
		addr.sin_addr.s_b4)
end

function tcp_getters:peer_port()
	local data = tcp_data[self]
	local addr,msg,errno = ws2_32.getpeername(data.socket)
	if not addr then return nil,msg,errno end
	return addr.sin_port
end

function tcp_methods:listen()
	local data = tcp_data[self]
	
	-- listen for incoming connections
	local result,msg,errno = ws2_32.listen(data.socket, assert(win32.SOMAXCONN))
	if not result then return nil,msg,errno end
	
	return true
end

function tcp_methods:accept()
	local data = tcp_data[self]
	
	-- accept the first connection
	local socket,msg,errno = ws2_32.accept(data.socket)
	while not socket and errno == win32.WSAEWOULDBLOCK do
		local event
		event,msg,errno = coroutine.yield(token, 'async_select', data.socket, 'accept')
		assert(event=='accept', "unexpected event "..tostring(event))
		if msg then return nil,msg,errno end
		socket,msg,errno = ws2_32.accept(data.socket)
	end
	if not socket then return nil,msg,errno end
	
	-- set the server socket as non-blocking
	local success,msg,errno = ws2_32.WSAAsyncSelect(socket, async_window, async_message, all_events)
	if not success then
		ws2_32.closesocket(socket)
		return nil,msg,errno
	end
	
	-- return the client TCP socket
	local client = {}
	local data = {self=client}
	tcp_data[client] = data
	data.socket = socket
	setmetatable(client, tcp_mt)
	return client
end

function tcp_methods:connect(address, port)
	local data = tcp_data[self]
	
	local addr = win32.new.SOCKADDR_STORAGE()
	addr.ss_family = win32.AF_INET
	addr.sin_addr = select(2, assert(ntdll.RtlIpv4StringToAddress(address)))
	addr.sin_port = port
	
	-- connect
	local success,msg,errno = ws2_32.connect(data.socket, addr)
	while not success and errno == win32.WSAEWOULDBLOCK do
		local event
		event,msg,errno = coroutine.yield(token, 'async_select', data.socket, 'connect')
		assert(event=='connect', "unexpected event "..tostring(event))
		if msg then
			break
		end
		success,msg,errno = ws2_32.connect(data.socket, addr)
		if errno == win32.WSAEINVAL or errno == win32.WSAEALREADY then
			errno = win32.WSAEWOULDBLOCK
		end
		if errno == win32.WSAEISCONN then
			success,msg,errno = true
		end
	end
	if not success then
		if errno==win32.WSAECONNREFUSED then
			msg = 'refused'
		elseif errno==win32.WSAETIMEDOUT then
			msg = 'timeout'
		end
		return nil,msg,errno
	end
	
	return true
end

function tcp_methods:read(size)
	local data = tcp_data[self]
	
	-- try reading data
	local bytes,msg,errno = ws2_32.recv(data.socket, size)
	while not bytes and errno == win32.WSAEWOULDBLOCK do
		local event
		event,msg,errno = coroutine.yield(token, 'async_select', data.socket, {'read', 'close'})
		if event=='read' then
			if msg then return nil,msg,errno end
			bytes,msg,errno = ws2_32.recv(data.socket, size)
		elseif event=='close' then
			if errno==win32.WSAECONNABORTED then
				return nil,'aborted'
			elseif msg then
				return nil,msg,errno
			else
				bytes,msg,errno = ""
			end
		else
			error("unexpected event "..tostring(event))
		end
	end
	if bytes=="" then
		return nil,'closed'
	elseif bytes then
		return bytes
	elseif errno==win32.WSAECONNABORTED then
		return nil,'aborted'
	else
		return nil,msg,errno
	end
end

function tcp_methods:write(bytes)
	local data = tcp_data[self]
	
	-- try writing data
	local written,msg,errno = ws2_32.send(data.socket, bytes)
	while not written and errno == win32.WSAEWOULDBLOCK do
		local event
		event,msg,errno = coroutine.yield(token, 'async_select', data.socket, {'write', 'close'})
		if event=='write' then
			if msg then return nil,msg,errno end
			written,msg,errno = ws2_32.send(data.socket, bytes)
		elseif event=='close' then
			if errno==win32.WSAECONNABORTED then
				return nil,'aborted'
			elseif msg then
				return nil,msg,errno
			else
				written,msg,errno = 0
			end
		else
			error("unexpected event "..tostring(event))
		end
	end
	if not written then return nil,msg,errno end
	
	return written
end

function tcp_methods:close()
	local data = tcp_data[self]
	-- a non-lingering closesocket will return immediately, closure happening in the background
	-- if we want to know it's finished, we need to linger, but that cannot be done asynchronously
	-- :TODO: find an asynchronous sequence to close the socket
	-- :FIXME: the ioctlsocket call below fails with EINVAL, so the blocking close has been disabled
--	assert(ws2_32.ioctlsocket(data.socket, 'FIONBIO', false))
--	assert(ws2_32.setsockopt(data.socket, 'SOL_SOCKET', 'SO_LINGER', win32.new 'LINGER' { l_onoff = true, l_linger = 0 }))
--	assert(ws2_32.shutdown(data.socket, 'SD_BOTH'))
	return ws2_32.closesocket(data.socket)
end

------------------------------------------------------------------------------
-- UDP-like sockets

local udp_methods = {}
local udp_getters = {}
local udp_mt = {}
local udp_data = setmetatable({}, {__mode='k'})

function udp_mt:__index(k)
	local getter = udp_getters[k]
	if getter ~= nil then
		return getter(self)
	end
	return udp_methods[k]
end

function _M.udp(address, port)
	local self = {}
	local data = {self=self}
	udp_data[self] = data
	
	-- create the socket
	local socket,msg,errno = ws2_32.socket(win32.AF_INET, win32.SOCK_DGRAM, win32.IPPROTO_UDP)
	if not socket then return nil,msg,errno end
	
	-- set the socket as non blocking
	local success,msg,errno = ws2_32.WSAAsyncSelect(socket, async_window, async_message, all_events)
	if not success then
		ws2_32.closesocket(socket)
		return nil,msg,errno
	end
	
	data.socket = socket
	setmetatable(self, udp_mt)
	return self
end

function udp_methods:bind(address, port)
	local data = udp_data[self]
	if address=='*' then address = '0.0.0.0' end
	local addr = win32.new.SOCKADDR_STORAGE()
	addr.ss_family = win32.AF_INET
	addr.sin_addr = select(2, assert(ntdll.RtlIpv4StringToAddress(address)))
	addr.sin_port = port or 0
	local result,msg,errno = ws2_32.bind(data.socket, addr)
	if not result then return nil,msg,errno end
	return true
end

function udp_getters:socket()
	local data = udp_data[self]
	return data.socket
end

function udp_getters:port()
	local data = udp_data[self]
	local addr,msg,errno = ws2_32.getsockname(data.socket)
	if not addr then return nil,msg,errno end
	return addr.sin_port
end

function udp_getters:peer_address()
	local data = udp_data[self]
	local addr,msg,errno = ws2_32.getpeername(data.socket)
	if not addr then return nil,msg,errno end
	return string.format('%d.%d.%d.%d',
		addr.sin_addr.s_b1,
		addr.sin_addr.s_b2,
		addr.sin_addr.s_b3,
		addr.sin_addr.s_b4)
end

function udp_getters:peer_port()
	local data = udp_data[self]
	local addr,msg,errno = ws2_32.getpeername(data.socket)
	if not addr then return nil,msg,errno end
	return addr.sin_port
end

function udp_methods:connect(address, port)
	local data = udp_data[self]
	
	local addr = win32.new.SOCKADDR_STORAGE()
	addr.ss_family = win32.AF_INET
	addr.sin_addr = select(2, assert(ntdll.RtlIpv4StringToAddress(address)))
	addr.sin_port = port
	
	-- connect
	local success,msg,errno = ws2_32.connect(data.socket, addr)
	while not success and errno == win32.WSAEWOULDBLOCK do
		local event
		event,msg,errno = coroutine.yield(token, 'async_select', data.socket, 'connect')
		assert(event=='connect', "unexpected event "..tostring(event))
		if msg then return nil,msg,errno end
		success,msg,errno = ws2_32.connect(data.socket, addr)
		if errno == win32.WSAEINVAL or errno == win32.WSAEALREADY then
			errno = win32.WSAEWOULDBLOCK
		end
		if errno == win32.WSAEISCONN then
			success,msg,errno = true
		end
	end
	if not success then return nil,msg,errno end
	
	return true
end

function udp_methods:read(size)
	local data = udp_data[self]
	
	-- try reading data
	local bytes,msg,errno = ws2_32.recv(data.socket, size)
	while not bytes and errno == win32.WSAEWOULDBLOCK do
		local event
		event,msg,errno = coroutine.yield(token, 'async_select', data.socket, {'read', 'close'})
		if event=='read' then
			if msg then return nil,msg,errno end
			bytes,msg,errno = ws2_32.recv(data.socket, size)
		elseif event=='close' then
			if errno==win32.WSAECONNABORTED then
				return nil,'aborted'
			elseif msg then
				return nil,msg,errno
			else
				bytes,msg,errno = ""
			end
		else
			error("unexpected event "..tostring(event))
		end
	end
	if errno==win32.WSAECONNABORTED then
		return nil,'aborted'
	elseif not bytes then
		return nil,msg,errno
	end
	
	return bytes
end

function udp_methods:write(bytes)
	local data = udp_data[self]
	
	-- try writing data
	local written,msg,errno = ws2_32.send(data.socket, bytes)
	while not written and errno == win32.WSAEWOULDBLOCK do
		local event
		event,msg,errno = coroutine.yield(token, 'async_select', data.socket, {'write', 'close'})
		if event=='write' then
			if msg then return nil,msg,errno end
			written,msg,errno = ws2_32.send(data.socket, bytes)
		elseif event=='close' then
			if errno==win32.WSAECONNABORTED then
				return nil,'aborted'
			elseif msg then
				return nil,msg,errno
			else
				written,msg,errno = 0
			end
		else
			error("unexpected event "..tostring(event))
		end
	end
	if not written then return nil,msg,errno end
	
	return written
end

function udp_methods:close()
	local data = udp_data[self]
	-- a non-lingering closesocket will return immediately, closure happening in the background
	-- if we want to know it's finished, we need to linger, but that cannot be done asynchronously
	-- :TODO: find an asynchronous sequence to close the socket
	-- :FIXME: the ioctlsocket call below fails with EINVAL, so the blocking close has been disabled
--	assert(ws2_32.ioctlsocket(data.socket, 'FIONBIO', false))
--	assert(ws2_32.setsockopt(data.socket, 'SOL_SOCKET', 'SO_LINGER', win32.new 'LINGER' { l_onoff = true, l_linger = 0 }))
--	assert(ws2_32.shutdown(data.socket, 'SD_BOTH'))
	return ws2_32.closesocket(data.socket)
end

------------------------------------------------------------------------------

function _M.resolve(hostname)
	-- windows 7 and earlier doesn't have an API to do asynchronous DNS resolution, so spawn a thread
	-- :KLUDGE: a new OS thread is spawned for each request, don't throw too many concurrently
	-- :TODO: use a long running thread or a thread pool to serialize requests and use less resources
	local handle = assert(kernel32.CreateThread(nil, nil, nil, [[
		local string = require 'string'
		local win32 = require 'win32'
		local ws2_32 = require 'win32.ws2_32'
		local hostname = ...
		local addr,msg = ws2_32.getaddrinfo(hostname)
		if not addr then return nil,msg end
		local p = addr
		while p and p.ai_family~=win32.AF_INET do
			p = p.ai_next
		end
		local ip
		if p then
			ip = string.format('%d.%d.%d.%d',
				p.ai_addr.sin_addr.s_b1,
				p.ai_addr.sin_addr.s_b2,
				p.ai_addr.sin_addr.s_b3,
				p.ai_addr.sin_addr.s_b4)
		end
		ws2_32.freeaddrinfo(addr)
		return ip
	]], hostname))
	coroutine.yield(token, 'handle', handle)
	local ip = kernel32.GetExitCodeThread(handle)
	assert(kernel32.CloseHandle(handle))
	if ip==0 then return nil end
	return ip
end

------------------------------------------------------------------------------
-- winusb wrappers

local function winusb_overlapped_read(device, interface, event, pipe, length, where)
	local thread = coroutine.running()
	local overlapped = win32.new 'OVERLAPPED' {
		hEvent = event,
		Offset = where and where % 2^32,
		OffsetHigh = where and math.floor(where / 2^32),
	}
	local result,msg,errno = WinUsb.ReadPipe(interface, pipe, length, overlapped)
	if not result then
		if errno==win32.ERROR_HANDLE_EOF then
			result,msg,errno = ""
		else
			return nil,msg,errno
		end
	end
	if msg=='ERROR_IO_PENDING' then
		local bytes
		repeat
			overlapped_by_thread[thread] = overlapped
			handle_by_overlapped[overlapped] = device -- :NOTE: CancelIoEx expects the device handle, not the winusb handle
			coroutine.yield(token, 'handle', overlapped.hEvent)
			handle_by_overlapped[overlapped] = nil
			overlapped_by_thread[thread] = nil
			bytes,msg,errno = WinUsb.GetOverlappedResult(interface, overlapped, false)
		until bytes or errno~=win32.ERROR_IO_INCOMPLETE
		if killing[thread] then
			killing[thread] = nil
			_M.exit_thread()
		elseif bytes then
			result = tostring(result):sub(1, bytes)
		elseif errno==win32.ERROR_HANDLE_EOF then
			result = ""
	--	elseif errno==win32.ERROR_OPERATION_ABORTED then
	--		_M.exit_thread()
		elseif errno==win32.ERROR_NETNAME_DELETED then
			return nil,'aborted'
		else
			return nil,msg,errno
		end
	end
	return result
end

local function winusb_overlapped_write(device, interface, event, pipe, data, where)
	local thread = coroutine.running()
	local overlapped = win32.new 'OVERLAPPED' {
		hEvent = event,
		Offset = where and where % 2^32,
		OffsetHigh = where and math.floor(where / 2^32),
	}
	local result,msg,errno = WinUsb.WritePipe(interface, pipe, data, overlapped)
	if not result then
		return nil,msg,errno
	end
	if msg=='ERROR_IO_PENDING' then -- 'result' holds a buffer
		local bytes
		repeat
			overlapped_by_thread[thread] = overlapped
			handle_by_overlapped[overlapped] = device -- :NOTE: CancelIoEx expects the device handle, not the winusb handle
			coroutine.yield(token, 'handle', overlapped.hEvent)
			handle_by_overlapped[overlapped] = nil
			overlapped_by_thread[thread] = nil
			bytes,msg,errno = WinUsb.GetOverlappedResult(interface, overlapped, false)
		until bytes or errno~=win32.ERROR_IO_INCOMPLETE
		if killing[thread] then
			killing[thread] = nil
			_M.exit_thread()
		elseif bytes then
			result = bytes
	--	elseif errno==win32.ERROR_OPERATION_ABORTED then
	--		_M.exit_thread()
		else
			return nil,msg,errno
		end
	end
	return result
end

local winusb_methods = {}
local winusb_getters = {}
local winusb_mt = {}
local winusb_data = setmetatable({}, {__mode='k'})

function winusb_mt:__index(k)
	local getter = winusb_getters[k]
	if getter ~= nil then
		return getter(self)
	end
	return winusb_methods[k]
end

function _M.winusb_wrapper(device, interface)
	local self = {}
	local data = {self=self}
	winusb_data[self] = data
	
	-- :TODO: open the device here
	
	-- create an event for overlapped I/O
	local event,msg,errno = kernel32.CreateEvent()
	if not event then
	--	kernel32.CloseHandle(handle)
		return nil,msg,errno
	end
	
	data.device = device
	data.interface = interface
	data.event = event
	setmetatable(self, winusb_mt)
	return self
end

function winusb_methods:read(pipe, size)
	local data = winusb_data[self]
	local result,msg = winusb_overlapped_read(data.device, data.interface, data.event, pipe, size)
	if result=="" then
		return nil,'closed'
	elseif result then
		return result
	else
		return nil,msg
	end
end

function winusb_methods:write(pipe, bytes)
	local data = winusb_data[self]
	local result,msg = winusb_overlapped_write(data.device, data.interface, data.event, pipe, bytes)
	if result then
		return result
	else
		return nil,msg
	end
end

function winusb_methods:close()
	local data = winusb_data[self]
	for overlapped,handle in pairs(handle_by_overlapped) do
		if handle == data.device then error("trying to close a winusb device with pending I/O", 2) end
	end
	kernel32.CloseHandle(data.event)
--	return kernel32.CloseHandle(data.handle)
	-- :TODO: close the device here
	return true
end

------------------------------------------------------------------------------
-- device files

local device_methods = {}
local device_getters = {}
local device_mt = {}
local device_data = setmetatable({}, {__mode='k'})

function device_mt:__index(k)
	local getter = device_getters[k]
	if getter ~= nil then
		return getter(self)
	end
	return device_methods[k]
end

function _M.device(file, mode)
	local self = {}
	local data = {self=self}
	device_data[self] = data
	
	local handle,msg
	if type(file)=='string' then
		local access = {}
		if mode:match('r') and mode:match('w') then
			table.insert(access, 'GENERIC_READ')
			table.insert(access, 'GENERIC_WRITE')
		elseif mode:match('r') then
			table.insert(access, 'GENERIC_READ')
		elseif mode:match('w') then
			table.insert(access, 'GENERIC_WRITE')
		else
			error("unsupported mode '"..mode.."'")
		end
		local share = {'FILE_SHARE_READ', 'FILE_SHARE_WRITE'}
		local security = nil
		local creation = win32.OPEN_EXISTING -- we open device files
		local flags = {'FILE_ATTRIBUTE_NORMAL', 'FILE_FLAG_OVERLAPPED'}
		local template = nil
		
		-- open the device (in non-blocking mode)
		handle,msg = kernel32.CreateFile(file, access, share, security, creation, flags, template)
		if not handle then return nil,"error while opening device: "..msg end
	elseif type(file)=='number' or type(file)=='userdata' then
		handle = assert(file)
	else
		error("unsupported file type")
	end
	
	-- create an event for overlapped I/O
	local event,msg,errno = kernel32.CreateEvent()
	if not event then
		kernel32.CloseHandle(handle)
		return nil,msg,errno
	end
	
	data.handle = handle
	data.event = event
	setmetatable(self, device_mt)
	return self
end

function device_getters:handle()
	local data = device_data[self]
	return data.handle
end

function device_methods:read(size)
	local data = device_data[self]
	local result,msg = overlapped_read(data.handle, data.event, size)
	if result=="" then
		return nil,'closed'
	elseif result then
		return result
	else
		return nil,msg
	end
end

function device_methods:write(bytes)
	local data = device_data[self]
	local result,msg = overlapped_write(data.handle, data.event, bytes)
	if result then
		return result
	else
		return nil,msg
	end
end

function device_methods:ioctl(code, input, output)
	local data = device_data[self]
	local event,msg,errno = kernel32.CreateEvent()
	if not event then
		return nil,msg,errno
	end
	local result,msg = overlapped_ioctl(data.handle, event, code, input, output)
	local success,msg2 = kernel32.CloseHandle(event)
	if not result then
		return nil,msg
	elseif not success then
		return nil,msg2
	else
		return result
	end
end

function device_methods:close()
	local data = device_data[self]
	for overlapped,handle in pairs(handle_by_overlapped) do
		if handle == data.socket then error("trying to close a device with pending I/O", 2) end
	end
	kernel32.CloseHandle(data.event)
	return kernel32.CloseHandle(data.handle)
end

------------------------------------------------------------------------------

return _M
