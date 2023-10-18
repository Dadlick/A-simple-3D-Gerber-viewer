local _M = {}

local math = require 'math'
local vector = require 'geometry.vector'
local quaternion = require 'geometry.quaternion'

local function rand(a, b)
	if not a then a = 0 end
	if not b then b = 1 end
	return a + (b - a) * math.random()
end


--[[

Convention:
- forward: -z
- left: -x
- upward: y

On a plane:
- location: vector2 (x, -z)
- orientation: number (theta)
- position (location + orientation): vector2 + number
- forward3 = glrotation(theta, 0, 1, 0) * vector3(0, 0, -1)
- left3 = glrotation(theta, 0, 1, 0) * vector3(-1, 0, 0)
- up3 = vector3(0, 1, 0)
- move forward: location = location + forward3 * speed * dt

On a sphere (radius r)
- location: unit vector3
- orientation: <no meaning>
- position (location + orientation): unit quaternion
- forward3 = position:rotate(vector3(0, 0, -1))
- left3 = position:rotate(vector3(-1, 0, 0))
- up3 = position:rotate(vector3(0, 1, 0)) = location
- move forward: position = glrotation(speed * dt / r, left3) * position

]]





function _M.randompos(size)
	if not size then size = 40 end
	return {x=rand(-size,size), y=0, z=rand(-size,size)}
end

function _M.stay(position, orientation, parent)
	-- angle 0 is toward -z, pi/2 is -x
	local trajectory = {
		type = 'static_stand',
		parent = parent,
		position = {
			x = position.x,
			y = position.y,
			z = position.z,
		},
		orientation = orientation,
	}
	return trajectory
end

function _M.stay_3d(position, orientation, parent)
	-- angle 0 is toward -z, pi/2 is -x
	local trajectory = {
		type = 'static_3d',
		parent = parent,
		position = {
			x = position.x,
			y = position.y,
			z = position.z,
		},
		orientation = {
			a = orientation.a,
			b = orientation.b,
			c = orientation.c,
			d = orientation.d,
		},
	}
	return trajectory
end

function _M.go_to(from, to, t, speed, parent)
	local diff = {
		x = to.x - from.x,
		y = to.y - from.y,
		z = to.z - from.z,
	}
	local dist = math.sqrt(diff.x^2, diff.y^2, diff.z^2)
	local delay = dist / speed
	-- angle 0 is toward -z, pi/2 is -x
	local orientation = math.atan2(-diff.x, -diff.z)
	local trajectory = {
		type = 'linear',
		parent = parent,
		p0 = {
			x = from.x,
			y = from.y,
			z = from.z,
		},
		t0 = t,
		orientation = orientation,
		speed = speed,
	}
	return trajectory,delay
end

function _M.compute_position(trajectory, t)
	local position,orientation
	if trajectory.type=='static_stand' then
		position = vector(trajectory.position)
		orientation = quaternion.glrotation(math.deg(trajectory.orientation), 0, 1, 0)
	elseif trajectory.type=='static_3d' then
		position = vector(trajectory.position)
		orientation = quaternion(trajectory.orientation)
	elseif trajectory.type=='linear' then
		-- angle 0 is toward -z, pi/2 is -x
		orientation = quaternion.glrotation(math.deg(trajectory.orientation), 0, 1, 0)
		local speed = trajectory.speed
		local dt = t - trajectory.t0
		local dist = speed * dt
		local p0 = vector(trajectory.p0)
		position = p0 + orientation:rotate(vector(0, 0, -1)) * dist
	elseif trajectory.type=='inertial' then
		local dt = t - trajectory.t0
		local rotation = quaternion(trajectory.rotation)
		local angle,axis = rotation:get_rotation()
		rotation:set_rotation(angle * dt, axis)
		orientation = rotation * quaternion(trajectory.orientation)
		local dist = vector(trajectory.velocity) * dt
		position = vector(trajectory.position) + dist
	else
		error("unsupported trajectory type")
	end
	return position,orientation
end

function _M.compute_relative_transform(trajectory, t)
	return _M.compute_position(trajectory, t)
end

return _M
