--[[ Remote ]]

-- state
local Remote = {}
local Utils
local ballSyncConnection
local ballSyncRemote
local parryRemote
local parryInitialized = false
local maintenanceGeneration = 0
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HookState = type(namespace.RemoteHooks) == "table" and namespace.RemoteHooks or {
    installed = false,
    register = nil,
}
namespace.RemoteHooks = HookState
_G.Exodus = namespace

-- discovery
local function registerRemote(remote)
    if not parryRemote then
        parryRemote = remote
    end
end

-- payload
local function payloadFor(flag)
    local value = flag == 2 and "\x02" or "\x01"
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        return buffer.fromstring(value)
    end
    return value
end

-- hooks
local function installHooks()
    if HookState.installed then return true end
    if type(hookmetamethod) ~= "function" then return false end
    local ok = pcall(function()
        local oldNamecall
        oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local args = { ... }
            if not checkcaller() and (method == "FireServer" or method == "fireServer") then
                local isPayload = false
                if args[1] then
                    if typeof(args[1]) == "buffer"
                        or (typeof(args[1]) == "string" and (string.find(args[1], "\x01") or string.find(args[1], "\x02")))
                    then
                        isPayload = true
                    end
                end
                if isPayload or self.Name == "RemoteEvent" then
                    if type(HookState.register) == "function" then
                        HookState.register(self)
                    end
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
            then
                if self.Name == "RemoteEvent"
                    or (self.Parent and string.find(self.Parent.Name, "Remote"))
                then
                    if type(HookState.register) == "function" then
                        task.spawn(HookState.register, self)
                    end
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

-- ball sync
local function locateBallSync()
    local remotes = Utils.getReplicatedStorage():FindFirstChild("Remotes")
    local candidate = remotes and remotes:FindFirstChild("BallSyncData")
    return candidate and candidate:IsA("RemoteEvent") and candidate or nil
end
local function isAlive(remote)
    return remote
        and typeof(remote) == "Instance"
        and remote:IsA("RemoteEvent")
        and remote.Parent ~= nil
end
local function clearRemovedRemote(remote)
    if parryRemote == remote and not isAlive(remote) then
        parryRemote = nil
        parryInitialized = false
    end
end

-- setup
function Remote.setup(deps)
    if type(deps) ~= "table" or not deps.Utils then
        return false
    end
    Utils = deps.Utils
    HookState.register = registerRemote
    if not installHooks() then
        HookState.register = nil
        Utils.warn("hooks do Remote indisponíveis")
        return false
    end
    return true
end

-- parry
function Remote.fireParry(flag)
    if not isAlive(parryRemote) then
        clearRemovedRemote(parryRemote)
        return false
    end
    local ok = pcall(function()
        parryRemote:FireServer(payloadFor(flag))
    end)
    return ok
end
function Remote.initParry()
    if not isAlive(parryRemote) then
        clearRemovedRemote(parryRemote)
        return false
    end
    if parryInitialized then
        return true
    end
    local ok = pcall(function()
        parryRemote:FireServer(payloadFor(2))
    end)
    parryInitialized = ok
    return ok
end
function Remote.getRemote()
    if not isAlive(parryRemote) then
        clearRemovedRemote(parryRemote)
    end
    return parryRemote
end

-- ball sync connection
local function disconnectBallSync()
    if ballSyncConnection then
        pcall(function()
            ballSyncConnection:Disconnect()
        end)
        if Utils and Utils.untrackGlobal then
            Utils.untrackGlobal(ballSyncConnection)
        end
    end
    ballSyncConnection = nil
    ballSyncRemote = nil
end
function Remote.bindBallSync(handler)
    if type(handler) ~= "function" then
        return false
    end
    local candidate = locateBallSync()
    if not candidate then
        if ballSyncRemote and not isAlive(ballSyncRemote) then
            disconnectBallSync()
        end
        return ballSyncConnection ~= nil and ballSyncConnection.Connected
    end
    if ballSyncConnection and ballSyncConnection.Connected and ballSyncRemote == candidate then
        return true
    end
    disconnectBallSync()
    local ok, connection = pcall(function()
        return candidate.OnClientEvent:Connect(handler)
    end)
    if not ok or not connection then
        ballSyncConnection = nil
        ballSyncRemote = nil
        return false
    end
    ballSyncConnection = connection
    ballSyncRemote = candidate
    if Utils then
        Utils.trackGlobal(ballSyncConnection)
    end
    return true
end

-- maintenance
function Remote.startMaintenance(options)
    options = type(options) == "table" and options or {}
    local onBallSync = options.onBallSync
    local isActive = options.isActive
    if type(isActive) ~= "function" then
        return false
    end
    maintenanceGeneration = maintenanceGeneration + 1
    local currentGeneration = maintenanceGeneration
    task.spawn(function()
        while currentGeneration == maintenanceGeneration and isActive() do
            local remote = Remote.getRemote()
            if remote and not isAlive(remote) then
                clearRemovedRemote(remote)
                remote = nil
            end
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
