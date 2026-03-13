local M = {}
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
	if not udpSocket then
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
		ffi.copy(otData, latestData, 48)

		-- Convert degrees to radians
		local yaw = math.rad(otData.yaw)
		local pitch = math.rad(otData.pitch)
		local roll = math.rad(otData.roll)

		-- Convert cm to meters
		local x = otData.x / 100
		local y = otData.y / 100
		local z = otData.z / 100

		-- Create absolute rotation quaternion
		-- Swap pitch/roll/yaw here if your axes are inverted in-game
		local headRot = quatFromEuler(pitch, roll, yaw)
		local headPos = vec3(x, y, z)

		local camData = core_camera.getCameraDataById(0)

		if camData and camData.res and camData.res.rot then
			local finalRot = camData.res.rot * headRot
			local finalPos = camData.res.pos + (camData.res.rot * headPos)

			-- Force the absolute position and rotation
			core_camera.setPosRot(0, finalPos, finalRot)
		end
	end
end

local function onExtensionUnloaded()
	if udpSocket then
		udpSocket:close()
		udpSocket = nil
	end
end

M.onInit = onInit
M.onPreRender = onPreRender
M.onExtensionUnloaded = onExtensionUnloaded

return M
