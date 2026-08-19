-- [[ Remote ]]
-- Stub vazio — sem hooks, sem captura
-- Só mantém a API pra não quebrar o resto do código

local Remote = {}
local Utils

-- state
local parryRemote = nil
local parryMode = "buffer"
local parryInitialized = false
local ballSyncConnection = nil
local ballSyncRemote = nil

-- helpers
local function noop() end

-- setup
function Remote.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" then
        return false
    end
    Utils = deps.Utils
    return true
end

-- parry api
function Remote.fireParry(flag)
    return false
end

function Remote.initParry()
    parryInitialized = false
    return false
end

function Remote.getRemote()
    return nil
end

function Remote.getMode()
    return parryMode
end

function Remote.invalidateRemote()
    parryRemote = nil
    parryInitialized = false
end

function Remote.setRemote(remote, mode)
    if not remote or typeof(remote) ~= "Instance" or not remote:IsA("RemoteEvent") then
        return false
    end
    parryRemote = remote
    parryMode = mode or "buffer"
    parryInitialized = false
    return true
end

function Remote.getStatus()
    return {
        schema = Utils and type(Utils.apiVersion) == "function" and Utils.apiVersion() or 1,
        state = "disabled",
        initialized = false,
        mode = parryMode,
        hasBallSync = false,
    }
end

-- sync api
function Remote.bindBallSync(handler)
    return false
end

function Remote.stopMaintenance()
    ballSyncConnection = nil
    ballSyncRemote = nil
end

function Remote.startMaintenance(options)
    return false
end

return Remote
