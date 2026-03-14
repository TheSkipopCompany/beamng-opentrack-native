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

local otYaw = 0
local otPitch = 0
local hasData = false
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
		otYaw = math.rad(otData.yaw)
		otPitch = math.rad(-otData.pitch)
		hasData = true
		-- log("D", "opentrack", string.format("OT RAW -> Y: %.2f | P: %.2f | R: %.2f", yaw, pitch, roll))

		-- Convert cm to meters
		local x = otData.x / 100
		local y = otData.y / 100
		local z = otData.z / 100
		-- log("D", "opentrack", string.format("Translation (m) -> X: %.4f | Y: %.4f | Z: %.4f", x, y, z))

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
			if cam.update ~= currentHook then
				if not cam._origUpdate then
					cam._origUpdate = cam.update
				end

				currentHook = function(self, camData)
					-- Feed OpenTrack directly into the engine's native variables
					if hasData then
						-- You may need to add a '-' to these if they are inverted
						self.relativeYaw = otYaw
						self.relativePitch = otPitch
					end

					-- Now let the engine calculate its own flawless quaternions
					self._origUpdate(self, camData)
				end

				cam.update = currentHook
				log("I", "opentrack", "Hooked driver camera using native relativeYaw/Pitch")
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
