-- [[ camera sensitivity ]]

-- tuning
local CONFIG = {
    DEFAULT_SENSITIVITY = 1,
    MODULE_SEARCH_RETRY = 0.5,
}

-- state
local Camera = {}
local utils, runService
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
            local player = utils.getLocalPlayer(); local scripts = player and player:FindFirstChild("PlayerScripts")
            local module = scripts and scripts:FindFirstChild("PlayerModule"); local camera = module and module:FindFirstChild("CameraModule")
            local input = camera and camera:FindFirstChild("CameraInput")
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
                cameraWrapped = wrapped; cameraInput.getRotation = cameraWrapped
                return
            end
            task.wait(CONFIG.MODULE_SEARCH_RETRY)
        end
    end)
end

-- lifecycle
function Camera.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
    Camera.teardown(); utils = deps.Utils
    runService = utils.getRunService()
    if not runService then return false, "RunService indisponível" end
    sensitivity = tonumber(utils.getConfigValue("CameraSensitivity")) or CONFIG.DEFAULT_SENSITIVITY; startCamera()
    configConnection = utils.observeConfig(function(changes)
        if changes.CameraSensitivity ~= nil then sensitivity = tonumber(changes.CameraSensitivity) or CONFIG.DEFAULT_SENSITIVITY end
    end)
    utils.trackGlobal(configConnection); return true
end
function Camera.teardown()
    stopCamera(); utils, runService = nil, nil
end

-- contract
Camera.__contract = {
    requires = { Utils = "utils" },
    requiresMethods = {
        Utils = {
            "getLocalPlayer",
            "getRunService",
            "getConfigValue",
            "isActive",
            "observeConfig",
            "trackGlobal",
            "untrackGlobal",
        },
    },
    provides = { "setup", "teardown" },
}

return Camera
