local M = {}
-- Documentation: Ensure we load after core_camera to access its exported functions
M.dependencies = { "core_camera" }
local socket = require("socket")
local ffi = require("ffi")

ffi.cdef([[
    typedef struct {
        double x, y, z;          
        double yaw, pitch, roll; 
    } OpenTrackData;
]])

local udpSocket = nil
local otData = ffi.new("OpenTrackData")

local qYaw = nil
local qPitch = nil
local currentHook = nil

local function onInit()
	udpSocket = socket.udp()
	if udpSocket then
		udpSocket:setsockname("127.0.0.1", 4242)
		udpSocket:settimeout(0)
		log("I", "opentrack", "Native OpenTrack UDP listener initialized on port 4242")
	else
		log("E", "opentrack", "Failed to create UDP socket")
	end
end

local function onPreRender(dt)
	-- log("D", "opentrack", "Native OpenTrack: onPreRender")
	if not udpSocket then
		log("E", "opentrack", "udpSocket socket null! Exiting...")
		return
	end

	local latestData = nil

	-- Drain buffer for the absolute latest frame
	while true do
		local data, err = udpSocket:receive()
		if data and #data == 48 then
			latestData = data
		elseif err == "timeout" or err == nil then
			break
		end
	end

	if latestData then
		-- log("D", "opentrack", "Native OpenTrack: got latestData")
		ffi.copy(otData, latestData, 48)

		-- Convert degrees to radians
		local yaw = math.rad(otData.yaw)
		local pitch = math.rad(otData.pitch)
		local roll = math.rad(otData.roll)
		-- log(
		-- 	"D",
		-- 	"opentrack",
		-- 	string.format(
		-- 		"Y: %.2f (%.2frad) | P: %.2f (%.2frad) | R: %.2f (%.2frad)",
		-- 		otData.yaw,
		-- 		yaw,
		-- 		otData.pitch,
		-- 		pitch,
		-- 		otData.roll,
		-- 		roll
		-- 	)
		-- )

		-- Convert cm to meters
		local x = otData.x / 100
		local y = otData.y / 100
		local z = otData.z / 100
		-- log("D", "opentrack", string.format("Translation (m) -> X: %.4f | Y: %.4f | Z: %.4f", x, y, z))

		-- Create absolute rotation quaternion
		-- 1. Create independent quaternions for each axis
		-- Adjust the negative signs here if an axis is backwards
		qYaw = quatFromEuler(0, 0, yaw)
		qPitch = quatFromEuler(pitch, 0, 0)

		-- 2. Force the evaluation order: Apply Yaw first, then apply Pitch on top of it.
		-- This absolutely prevents Pitch from bleeding into Roll when you look over your shoulder.
		-- headRot = qYaw * qPitch
		-- headPos = vec3(0, 0, 0) -- Mapping: Side(X), Forward(Z), Up(Y)
		-- log(
		-- 	"D",
		-- 	"opentrack",
		-- 	string.format(
		-- 		"Local Head -> Rot: (w:%.2f x:%.2f y:%.2f z:%.2f) | Pos: %s",
		-- 		headRot.w,
		-- 		headRot.x,
		-- 		headRot.y,
		-- 		headRot.z,
		-- 		tostring(headPos)
		-- 	)
		-- )
	end

	local vid = be:getPlayerVehicleID(0)
	if vid >= 0 then
		local allCams = core_camera.getCameraDataById(vid)
		local cam = allCams and allCams["driver"]

		-- 2. Hook logic that survives car resets
		if cam and type(cam.update) == "function" then
			-- If the camera's update function isn't our current script's closure, we must hook it
			-- (This triggers on first load, car resets, AND script reloads)
			if cam.update ~= currentHook then
				-- Backup the original function ONLY if it hasn't been backed up yet
				if not cam._origUpdate then
					cam._origUpdate = cam.update
				end

				-- Create the new closure that reads from THIS script's live qYaw and qPitch
				currentHook = function(self, camData)
					self._origUpdate(self, camData)

					if camData.res and camData.res.rot and qYaw and qPitch then
						-- Correct math order: Car * Yaw * Pitch (Local Space)
						camData.res.rot = camData.res.rot * qYaw * qPitch
					end
				end

				-- Apply the hook
				cam.update = currentHook
				log("I", "opentrack", "Driver camera hooked/updated successfully")
			end
		end
	end
end

local function onExtensionUnloaded()
	if udpSocket then
		udpSocket:close()
		udpSocket = nil
	end

	local vid = be:getPlayerVehicleID(0)
	if vid >= 0 then
		local allCams = core_camera.getCameraDataById(vid)
		local cam = allCams and allCams["driver"]

		if cam and cam._origUpdate then
			cam.update = cam._origUpdate
			cam._origUpdate = nil -- Clear the backup
			log("I", "opentrack", "Cleanly unhooked driver camera")
		end
	end
end

M.onInit = onInit
M.onPreRender = onPreRender
M.onExtensionUnloaded = onExtensionUnloaded

return M
