-- [[ camera sensitivity ]]

-- state
local Camera = {}
local utils, gameInfo, autoSpam, runService
local cameraEpoch = 0
local cameraInput, cameraOriginal, cameraWrapped, configConnection
local sensitivity = 1

-- helpers
local function stopCamera()
	cameraEpoch += 1
	if cameraInput and cameraInput.getRotation == cameraWrapped then cameraInput.getRotation = cameraOriginal end
	if configConnection then
		if utils then utils.untrackGlobal(configConnection) end
		configConnection:Disconnect(); configConnection = nil
	end
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
					return rotation * sensitivity
				end
				cameraWrapped = wrapped; cameraInput.getRotation = cameraWrapped; return
			end
			task.wait(0.5)
		end
	end)
end

-- lifecycle
function Camera.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.AutoSpam) ~= "table" then return false, "dependências ausentes" end
	Camera.teardown(); utils, gameInfo, autoSpam = deps.Utils, deps.GameInfo, deps.AutoSpam; runService = utils.getRunService()
	if not runService then return false, "RunService indisponível" end
	sensitivity = tonumber(utils.getConfigValue("CameraSensitivity")) or 1; startCamera()
	configConnection = utils.observeConfig(function(changes)
		if changes.CameraSensitivity ~= nil then sensitivity = tonumber(changes.CameraSensitivity) or 1 end
	end)
	utils.trackGlobal(configConnection); return true
end
function Camera.teardown()
	stopCamera(); utils, gameInfo, autoSpam, runService = nil, nil, nil, nil
end

-- contract
Camera.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", AutoSpam = "autospam" },
	requiresMethods = {
		Utils = { "getLocalPlayer", "getRunService", "getWorkspace", "getConfigValue", "isActive", "observeConfig", "trackGlobal", "untrackGlobal" },
		GameInfo = { "getPlayerMotion", "getClashContext" },
		AutoSpam = { "getActivationContext" },
	},

	provides = { "setup", "teardown" },
}

return Camera
