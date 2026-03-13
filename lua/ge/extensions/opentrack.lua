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

local headRot = quat()
local headPos = vec3()

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
		-- Swap pitch/roll/yaw here if your axes are inverted in-game
		headRot = quatFromEuler(pitch, roll, yaw)
		headPos = vec3(x, y, z)
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

	-- Table to track which cameras we have already intercepted
	if not M.hookedCameras then
		M.hookedCameras = {}
	end

	local vid = be:getPlayerVehicleID(0)
	if vid >= 0 then
		-- Clear our tracked hooks if the player switches vehicles
		if M.lastVid ~= vid then
			M.hookedCameras = {}
			M.lastVid = vid
		end

		local allCams = core_camera.getCameraDataById(vid)

		if allCams then
			for camName, cam in pairs(allCams) do
				-- Check our external table to see if we already hooked this specific camera
				if type(cam.update) == "function" and not M.hookedCameras[camName] then
					local originalUpdate = cam.update

					cam.update = function(self, camData)
						-- 1. Run the game's default math first
						originalUpdate(self, camData)

						-- 2. Inject our absolute tracking into the finalized camData.res table
						if camData.res and camData.res.rot and camData.res.pos then
							camData.res.rot = camData.res.rot * headRot
							camData.res.pos = camData.res.pos + (camData.res.rot * headPos)
						end
					end

					-- Mark as hooked in our external table
					M.hookedCameras[camName] = true
					log("I", "opentrack", "Hooked absolute tracking into: " .. tostring(camName))
				end
			end
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
