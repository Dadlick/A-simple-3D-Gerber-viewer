local _M = {}

local table = require 'table'
local nb = require 'nb'

local connections = setmetatable({}, {__mode='k'})
-- connections[emitter][receiver][signal][slot] = async
-- where 'emitter' and 'receiver' are weak keys
-- async may be true or false

local function _connect(emitter, signal, receiver, slot, async)
	if receiver==nil then
		receiver = 'global'
	end
	local per_emitter = connections
	local per_receiver = per_emitter[emitter]
	if not per_receiver then
		per_receiver = setmetatable({}, {__mode='k'})
		per_emitter[emitter] = per_receiver
	end
	local per_signal = per_receiver[receiver]
	if not per_signal then
		per_signal = {}
		per_receiver[receiver] = per_signal
	end
	local slots = per_signal[signal]
	if not slots then
		slots = {}
		per_signal[signal] = slots
	end
	slots[slot] = async
end

function _M.connect(emitter, signal, receiver, slot)
	return _connect(emitter, signal, receiver, slot, false)
end

function _M.connect_async(emitter, signal, receiver, slot)
	return _connect(emitter, signal, receiver, slot, true)
end

local function _disconnect(emitter, signal, receiver, slot)
	if receiver==nil then
		receiver = 'global'
	end
	local per_emitter = connections
	local per_receiver = per_emitter[emitter]
	if not per_receiver then
		return
	end
	local per_signal = per_receiver[receiver]
	if not per_signal then
		return
	end
	local slots = per_signal[signal]
	if not slots then
		return
	end
	slots[slot] = nil
	if next(slots)==nil then
		per_signal[signal] = nil
		if next(per_signal)==nil then
			per_receiver[receiver] = nil
			if next(per_receiver)==nil then
				per_emitter[emitter] = nil
			end
		end
	end
end

function _M.disconnect(emitter, signal, receiver, slot)
	if signal==nil and receiver==nil and slot==nil then
		connections[emitter] = nil
	elseif emitter==nil and signal==nil and slot==nil then
		for emitter,per_receiver in pairs(connections) do
			per_receiver[receiver] = nil
		end
	elseif emitter and signal and slot then
		_disconnect(emitter, signal, receiver, slot)
	else
		error("disconnect mode not supported")
	end
end

-- non-blocking, slots are called in separate threads
function _M.emit(emitter, signal, ...)
	local per_emitter = connections
	local per_receiver = per_emitter[emitter]
	if not per_receiver then
		return
	end
	for receiver,per_signal in pairs(per_receiver) do
		local slots = per_signal[signal]
		if slots then
			if receiver=='global' then
				for slot,async in pairs(slots) do
					if async then
						nb.add_thread_later(slot, ...)
					else
						nb.add_thread(slot, ...)
					end
				end
			else
				for slot,async in pairs(slots) do
					if async then
						nb.add_thread_later(slot, receiver, ...)
					else
						nb.add_thread(slot, receiver, ...)
					end
				end
			end
		end
	end
end

--[[
nb.add_thread(function()
	local os = require 'nb.os'
	while true do
		nb.wait(1)
		local total = 0
		local per_emitter = connections
		local receivers = {}
		for emitter,per_receiver in pairs(per_emitter) do
			for receiver,per_signal in pairs(per_receiver) do
				receivers[receiver] = true
				for signal,slots in pairs(per_signal) do
					for slot in pairs(slots) do
					end
				end
			end
		end
		local areceivers = {}
		for receiver in pairs(receivers) do
			table.insert(areceivers, receiver)
		end
		print(">", #areceivers, unpack(areceivers))
	end
end)
--]]

function _M.wait(emitter, signal)
	local queue = nb.queue()
	local function slot(...)
		_M.disconnect(emitter, signal, nil, slot)
		queue:push(table.pack(...))
	end
	_M.connect(emitter, signal, nil, slot)
	return table.unpack(queue:pop())
end

return _M
