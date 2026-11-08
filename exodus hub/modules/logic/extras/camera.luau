-- [[ camera sensitivity ]]
local Camera = {}
local utils
local cameraEpoch = 0
local cameraInput, cameraOriginal, cameraWrapped

local function stopCamera()
	cameraEpoch += 1
	if cameraInput and cameraInput.getRotation == cameraWrapped then cameraInput.getRotation = cameraOriginal end
	cameraInput, cameraOriginal, cameraWrapped = nil, nil, nil
end
local function startCamera()
	stopCamera(); local token = cameraEpoch
	task.spawn(function()
		while token == cameraEpoch and utils and utils.isActive() do
			local player = utils.getLocalPlayer(); local scripts = player and player:FindFirstChild("PlayerScripts"); local module = scripts and scripts:FindFirstChild("PlayerModule"); local camera = module and module:FindFirstChild("CameraModule"); local input = camera and camera:FindFirstChild("CameraInput")
			if input and input:IsA("ModuleScript") then
				local api = require(input)
				if token ~= cameraEpoch or not utils then return end
				if type(api) ~= "table" or type(api.getRotation) ~= "function" then error("CameraInput.getRotation indisponível") end
				cameraInput, cameraOriginal = api, api.getRotation; local original, boundUtils = cameraOriginal, utils
				local wrapped
				wrapped = function(...)
					local rotation = original(...)
					if not boundUtils.isActive() then
						if api.getRotation == wrapped then api.getRotation = original end
						return rotation
					end
					local factor = tonumber(boundUtils.getConfigValue("CameraSensitivity")); return rotation * (factor or 1)
				end
				cameraWrapped = wrapped; cameraInput.getRotation = cameraWrapped; return
			end
			task.wait(0.5)
		end
	end)
end


function Camera.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "Utils ausente" end
	Camera.teardown(); utils = deps.Utils; startCamera(); return true
end
function Camera.teardown() stopCamera(); utils = nil end

Camera.__contract = {
	requires = { Utils = "utils" },
	requiresMethods = { Utils = { "getLocalPlayer", "getConfigValue", "isActive" } },
	provides = { "setup", "teardown" },
}
return Camera
