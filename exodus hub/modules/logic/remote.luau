-- [[ Remote ]]

local Remote = {}
local Utils

-- state
local parryRemote
local parryMode = "buffer"
local parryInitialized = false
local ballSyncConnection
local ballSyncRemote

-- helpers
local function isAlive(remote)
    return remote
        and typeof(remote) == "Instance"
        and remote:IsA("RemoteEvent")
        and remote.Parent ~= nil
end

local function payloadFor(flag)
    local value = flag == 2 and "\x02" or "\x01"
    if type(buffer) == "table" and type(buffer.fromstring) == "function" then
        return buffer.fromstring(value)
    end
    return value
end

-- register (igual ao certo: não auto-detecta, só registra o que for passado)
local function RegisterRemote(remote)
    if not isAlive(remote) then
        return
    end
    if not parryRemote then
        parryRemote = remote
    end
end

-- hooks (idêntico ao certo)
local _hooked = false
local _oldNamecall
local _oldIndex

local function installHooks()
    if _hooked then return true end
    if type(hookmetamethod) ~= "function"
        or type(getnamecallmethod) ~= "function"
        or type(checkcaller) ~= "function"
    then
        return false
    end
    local ok = pcall(function()
        _oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
            local method = getnamecallmethod()
            local args = { ... }

            if not checkcaller() and (method == "FireServer" or method == "fireServer") then
                local isPayload = false

                if args[1] then
                    if typeof(args[1]) == "buffer"
                        or (typeof(args[1]) == "string" and (string.find(args[1], "\x01") or string.find(args[1], "\x02"))) then
                        isPayload = true
                    end
                end

                if isPayload or self.Name == "RemoteEvent" then
                    RegisterRemote(self)
                end
            end

            return _oldNamecall(self, ...)
        end)

        _oldIndex = hookmetamethod(game, "__index", function(self, key)
            if not checkcaller()
                and (key == "FireServer" or key == "fireServer")
                and typeof(self) == "Instance"
                and self:IsA("RemoteEvent") then

                if self.Name == "RemoteEvent"
                    or (self.Parent and string.find(self.Parent.Name, "Remote")) then
                    task.spawn(function()
                        RegisterRemote(self)
                    end)
                end
            end

            return _oldIndex(self, key)
        end)
    end)
    if ok then
        _hooked = true
    end
    return _hooked == true
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

-- setup (API do errado)
function Remote.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.getReplicatedStorage) ~= "function"
        or type(deps.Utils.apiVersion) ~= "function"
        or type(deps.Utils.trackGlobal) ~= "function"
        or type(deps.Utils.untrackGlobal) ~= "function"
        or type(deps.Utils.warn) ~= "function"
    then
        return false
    end
    Utils = deps.Utils
    if not installHooks() then
        Utils.warn("hooks do Remote indisponíveis; captura automática desativada")
        return true
    end
    return true
end

-- parry api
function Remote.fireParry(flag)
    if not isAlive(parryRemote) then
        parryRemote = nil
        parryInitialized = false
        if Utils and type(Utils.recordError) == "function" then
            Utils.recordError("Remote", "parry Remote indisponível")
        end
        return false
    end
    local ok, errorMessage = pcall(function()
        parryRemote:FireServer(payloadFor(flag))
    end)
    if not ok then
        if Utils and type(Utils.recordError) == "function" then
            Utils.recordError("Remote", errorMessage)
        end
        return false
    end
    return true
end

function Remote.initParry()
    if not isAlive(parryRemote) then
        parryRemote = nil
        parryInitialized = false
        return false
    end
    if parryInitialized then
        return true
    end
    local ok, errorMessage = pcall(function()
        parryRemote:FireServer(payloadFor(2))
    end)
    if not ok and Utils and type(Utils.recordError) == "function" then
        Utils.recordError("Remote", errorMessage)
    end
    parryInitialized = ok
    return ok
end

function Remote.getRemote()
    if not isAlive(parryRemote) then
        parryRemote = nil
    end
    return parryRemote
end

function Remote.getMode()
    return parryMode
end

function Remote.invalidateRemote()
    parryRemote = nil
    parryInitialized = false
end

function Remote.setRemote(remote, mode)
    if not isAlive(remote) then
        return false
    end
    parryRemote = remote
    parryMode = mode or "buffer"
    parryInitialized = false
    return true
end

function Remote.getStatus()
    local remote = Remote.getRemote()
    return {
        schema = Utils.apiVersion(),
        state = remote and (parryInitialized and "ready" or "captured") or (_hooked and "hooked" or "uninitialized"),
        initialized = parryInitialized == true,
        mode = parryMode,
        hasBallSync = ballSyncConnection ~= nil
            and ballSyncConnection.Connected == true
            and ballSyncRemote ~= nil,
    }
end

-- sync api
function Remote.bindBallSync(handler)
    if type(handler) ~= "function" then
        return false
    end
    local candidate = locateBallSync()
    if not candidate then
        disconnectBallSync()
        if Utils and type(Utils.recordError) == "function" then
            Utils.recordError("Remote", "BallSyncData indisponível")
        end
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
        if Utils and type(Utils.recordError) == "function" then
            Utils.recordError("Remote", "falha ao conectar BallSyncData")
        end
        return false
    end
    ballSyncConnection = connection
    ballSyncRemote = candidate
    Utils.trackGlobal(connection)
    return true
end

function Remote.stopMaintenance()
    disconnectBallSync()
end

function Remote.startMaintenance(options)
    options = type(options) == "table" and options or {}
    local isActive = options.isActive
    local onBallSync = options.onBallSync
    if type(isActive) ~= "function" then
        if Utils and type(Utils.recordError) == "function" then
            Utils.recordError("Remote", "manutenção sem isActive")
        end
        return false
    end
    task.spawn(function()
        while true do
            local activeOk, active = pcall(isActive)
            if not activeOk or not active then
                break
            end
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
