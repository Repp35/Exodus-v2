-- [[ Remote ]]

local Remote = {}
local Utils

-- state
local parryRemote
local parryInitialized = false
local ballSyncConnection
local ballSyncRemote
local maintenanceGeneration = 0

local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HookState = type(namespace.RemoteHooks) == "table" and namespace.RemoteHooks or {
    installed = false,
    register = nil,
}

namespace.RemoteHooks = HookState
_G.Exodus = namespace

-- helpers
local function isAlive(remote)
    return remote
        and typeof(remote) == "Instance"
        and remote:IsA("RemoteEvent")
        and remote.Parent ~= nil
end

local function clearParryRemote(remote)
    if parryRemote == remote and not isAlive(remote) then
        parryRemote = nil
        parryInitialized = false
    end
end

local function registerRemote(remote)
    if isAlive(remote) and (not parryRemote or not isAlive(parryRemote)) then
        parryRemote = remote
        parryInitialized = false
    end
end

local function payloadFor(flag)
    local value = flag == 2 and "\x02" or "\x01"

    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        return buffer.fromstring(value)
    end

    return value
end

local function isParryPayload(value)
    local valueType = typeof(value)

    if valueType == "buffer" then
        return true
    end

    if valueType == "string" then
        return string.find(value, "\x01", 1, true) ~= nil
            or string.find(value, "\x02", 1, true) ~= nil
    end

    return false
end

-- hooks
local function installHooks()
    if HookState.installed then
        return true
    end

    if type(hookmetamethod) ~= "function"
        or type(getnamecallmethod) ~= "function"
        or type(checkcaller) ~= "function"
    then
        return false
    end

    local ok = pcall(function()
        local oldNamecall

        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local firstArgument = ...

            if not checkcaller()
                and (method == "FireServer" or method == "fireServer")
                and typeof(self) == "Instance"
                and self:IsA("RemoteEvent")
                and (isParryPayload(firstArgument) or self.Name == "RemoteEvent")
            then
                if type(HookState.register) == "function" then
                    HookState.register(self)
                end
            end

            return oldNamecall(self, ...)
        end)

        local oldIndex

        oldIndex = hookmetamethod(game, "__index", function(self, key)
            if not checkcaller()
                and (key == "FireServer" or key == "fireServer")
                and typeof(self) == "Instance"
                and self:IsA("RemoteEvent")
                and (
                    self.Name == "RemoteEvent"
                    or (self.Parent and string.find(self.Parent.Name, "Remote", 1, true))
                )
            then
                if type(HookState.register) == "function" then
                    task.spawn(HookState.register, self)
                end
            end

            return oldIndex(self, key)
        end)
    end)

    if ok then
        HookState.installed = true
    end

    return HookState.installed == true
end

-- sync
local function locateBallSync()
    local remotes = Utils.getReplicatedStorage():FindFirstChild("Remotes")
    local candidate = remotes and remotes:FindFirstChild("BallSyncData")

    if candidate and candidate:IsA("RemoteEvent") then
        return candidate
    end

    return nil
end

local function disconnectBallSync()
    if ballSyncConnection then
        pcall(ballSyncConnection.Disconnect, ballSyncConnection)
        Utils.untrackGlobal(ballSyncConnection)
    end

    ballSyncConnection = nil
    ballSyncRemote = nil
end

-- setup
function Remote.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.getReplicatedStorage) ~= "function"
        or type(deps.Utils.trackGlobal) ~= "function"
        or type(deps.Utils.untrackGlobal) ~= "function"
        or type(deps.Utils.warn) ~= "function"
    then
        return false
    end

    Utils = deps.Utils
    parryRemote = nil
    parryInitialized = false
    HookState.register = registerRemote

    if not installHooks() then
        HookState.register = nil
        Utils.warn("hooks do Remote indisponíveis")
        return false
    end

    return true
end

-- parry api
function Remote.fireParry(flag)
    if flag ~= 2 then
        flag = 1
    end

    if not isAlive(parryRemote) then
        clearParryRemote(parryRemote)
        return false
    end

    local ok = pcall(function()
        parryRemote:FireServer(payloadFor(flag))
    end)

    return ok
end

function Remote.initParry()
    if parryInitialized then
        return true
    end

    if not Remote.fireParry(2) then
        return false
    end

    parryInitialized = true
    return true
end

function Remote.getRemote()
    if not isAlive(parryRemote) then
        clearParryRemote(parryRemote)
    end

    return parryRemote
end

-- sync api
function Remote.bindBallSync(handler)
    if type(handler) ~= "function" then
        return false
    end

    local candidate = locateBallSync()

    if not candidate then
        disconnectBallSync()
        return false
    end

    if ballSyncConnection
        and ballSyncConnection.Connected
        and ballSyncRemote == candidate
    then
        return true
    end

    disconnectBallSync()

    local ok, connection = pcall(function()
        return candidate.OnClientEvent:Connect(handler)
    end)

    if not ok or not connection then
        return false
    end

    ballSyncConnection = connection
    ballSyncRemote = candidate
    Utils.trackGlobal(connection)

    return true
end

function Remote.stopMaintenance()
    maintenanceGeneration = maintenanceGeneration + 1
    disconnectBallSync()
end

function Remote.startMaintenance(options)
    options = type(options) == "table" and options or {}

    local isActive = options.isActive
    local onBallSync = options.onBallSync

    if type(isActive) ~= "function" then
        return false
    end

    maintenanceGeneration = maintenanceGeneration + 1
    local generation = maintenanceGeneration

    task.spawn(function()
        while generation == maintenanceGeneration and isActive() do
            local remote = Remote.getRemote()

            if remote then
                Remote.initParry()
            end

            if type(onBallSync) == "function" then
                Remote.bindBallSync(onBallSync)
            end

            task.wait(remote and 3 or 1)
        end
    end)

    return true
end

return Remote
