local _M = {}

local math = require 'math'
local geometry = require 'geometry'
local vector = geometry.vector
local vectorh = geometry.vectorh
local quaternion = geometry.quaternion
local matrixh = geometry.matrixh

function _M.compute_matrices(camera, scene, target_matrices)
	local view_matrix
	local projection_matrix
	
	if camera.type == 'shadow_perspective' then
		local camera2 = camera.target
		
		view_matrix,projection_matrix = _M.compute_matrices(camera2, scene, target_matrices)
		
		if camera2.type=='third_person' then
			-- replace the camera frustum with a bigger, skewed one
			
			local light_direction = view_matrix:transform(camera.light_direction)
			local pitch = math.acos(-light_direction.z) - math.pi/2
			local roll = math.atan(light_direction.y, light_direction.x) - math.pi/2
			
			local aspect_ratio = scene.view.width / scene.view.height
			local y = math.tan(math.rad(45/2))
			local x = y * aspect_ratio
			local h = math.sqrt(x*x+y*y)
			local a = math.deg(math.atan(h))*2
			local near,far = 10,100
			
			local left = - h * near
			local right = h * near
			local bottom = - h * near
			local top = h * near
			local bottom = (math.tan(math.atan(-h) - pitch)) * near
			local top = (math.tan(math.atan(h) - pitch)) * near
			
			projection_matrix = matrixh.glfrustum(left, right, bottom, top, near, far)
			
			projection_matrix = projection_matrix * matrixh(quaternion.glrotation(math.deg(pitch), -1, 0, 0))
			projection_matrix = projection_matrix * matrixh(quaternion.glrotation(math.deg(roll), 0, 0, -1))
			
			projection_matrix = matrixh(quaternion.glrotation(-90, 1, 0, 0)) * projection_matrix
		end
	
	elseif camera.type == 'shadow_ortho' then
		local camera2 = camera.target
		
		view_matrix,projection_matrix = _M.compute_matrices(camera2, scene, target_matrices)

		if camera2.type=='third_person' then
			-- replace the camera frustum with a bigger, orthographic one
			
			local light_direction = view_matrix:transform(camera.light_direction)
			local pitch = math.acos(-light_direction.z) - math.pi/2
			local roll = math.atan(light_direction.y, light_direction.x) - math.pi/2
			
			local aspect_ratio = scene.view.width / scene.view.height
			local y = math.tan(math.rad(45/2))
			local x = y * aspect_ratio
			local h = math.sqrt(x*x+y*y)
			local a = math.deg(math.atan(h))*2
			local near,far = 10,100
			
			local left = - h * near
			local right = h * near
			local bottom = - h * near
			local top = h * near
			local bottom = (math.tan(math.atan(-h) - pitch)) * near
			local top = (math.tan(math.atan(h) - pitch)) * near
			
			projection_matrix = matrixh.glortho(-50, 50, -100, 100, 1, 101)
			projection_matrix = projection_matrix * matrixh(vector(0, 0, -50))
			
			projection_matrix = projection_matrix * matrixh(quaternion.glrotation(math.deg(pitch), -1, 0, 0))
			projection_matrix = projection_matrix * matrixh(quaternion.glrotation(math.deg(roll), 0, 0, -1))
			
			projection_matrix = projection_matrix * matrixh(vector(0, 0, 50))
			
			projection_matrix = matrixh(quaternion.glrotation(-90, 1, 0, 0)) * projection_matrix
			
		end
	
	elseif camera.type == 'third_person' then
		local orientation = quaternion(camera.orientation)
		local aspect_ratio = scene.view.width / scene.view.height
		
		local target = camera.target
		local campos
		local target_matrix = target_matrices[target]
		if target > 0 and target_matrix then
			local target_position = target_matrix:transform(vectorh(0,0,0,1)).vector
			campos = vector(camera.offset) + target_position
		elseif scene.debug_position then
			local target_location = vector(scene.debug_position.location)
			campos = target_location
		end
		
		local near = camera.distance / 10 -- 10 cm when target is at 1m
		local far = near * 2^24 -- 1600 km when target is at 1m
		projection_matrix = matrixh.glperspective(math.deg(camera.fovy), aspect_ratio, near, far)
		
		view_matrix = matrixh()
		
		view_matrix = matrixh(vector(-campos.x, -campos.y, -campos.z)) * view_matrix
		view_matrix = matrixh(orientation) * view_matrix
		view_matrix = matrixh(vector(0, 0, -camera.distance)) * view_matrix
	
	elseif camera.type=='free' then
		local position = vector(camera.position)
		local orientation = quaternion(camera.orientation)
		local frustum = camera.frustum
		if frustum.ortho then
			projection_matrix = matrixh.glortho(frustum.left, frustum.right, frustum.bottom, frustum.top, frustum.near, frustum.far+10)
		else
			projection_matrix = matrixh.glfrustum(frustum.left, frustum.right, frustum.bottom, frustum.top, frustum.near, frustum.far+10)
		end
		
		view_matrix = matrixh(orientation) * matrixh(-position)
	
	else
		error("unsupported camera type "..tostring(camera.type))
	end
	
	return view_matrix,projection_matrix
end

return _M
