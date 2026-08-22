-- [[ Remote ]]

local Remote = {}
local Utils

-- state
local parryRemote
local parryRemoteSource
local parryInitialized = false
local ballSyncConnection
local ballSyncRemote
local maintenanceGeneration = 0
local remoteState = "uninitialized"
local HttpService = game:GetService("HttpService")
local STORAGE_SCHEMA = 1
local STORAGE_FILE = "deflect_remotes.json"
local Storage = {
    initialized = false,
    available = false,
    writeBlocked = false,
    flushQueued = false,
    path = STORAGE_FILE,
    captures = {},
    lastWriteAt = 0,
    lastError = nil,
    errorReported = false,
}

-- storage
local function reportStorageError(message)
    Storage.lastError = tostring(message)
    if not Storage.errorReported
        and Utils
        and type(Utils.recordError) == "function"
    then
        Storage.errorReported = true
        Utils.recordError("RemoteStorage", Storage.lastError)
    end
end
local function safeInstanceInfo(instance)
    if typeof(instance) ~= "Instance" then
        return nil
    end
    local info = {}
    local okName, name = pcall(function()
        return instance.Name
    end)
    local okClass, className = pcall(function()
        return instance.ClassName
    end)
    local okFullName, fullName = pcall(function()
        return instance:GetFullName()
    end)
    if okName then info.name = name end
    if okClass then info.className = className end
    if okFullName then info.fullName = fullName end
    return info
end
local function safeValue(value, depth)
    depth = depth or 0
    if value == nil then
        return nil
    end
    if type(value) == "boolean" or type(value) == "string" then
        return value
    end
    if type(value) == "number" then
        if value == value and value < math.huge and value > -math.huge then
            return value
        end
        return tostring(value)
    end
    if depth >= 3 then
        return tostring(value)
    end
    local valueType = typeof(value)
    if valueType == "Vector3" then
        return { type = valueType, x = value.X, y = value.Y, z = value.Z }
    end
    if valueType == "Color3" then
        return { type = valueType, r = value.R, g = value.G, b = value.B }
    end
    if valueType == "CFrame" then
        return { type = valueType, components = { value:GetComponents() } }
    end
    if valueType == "EnumItem" then
        return {
            type = valueType,
            enumType = tostring(value.EnumType),
            name = value.Name,
            value = value.Value,
        }
    end
    if valueType == "Instance" then
        return safeInstanceInfo(value)
    end
    if type(value) == "table" then
        local result = {}
        for key, item in pairs(value) do
            local safeKey = type(key) == "string" and key or tostring(key)
            result[safeKey] = safeValue(item, depth + 1)
        end
        return result
    end
    return tostring(value)
end
local function safeAttributes(remote)
    local ok, attributes = pcall(function()
        return remote:GetAttributes()
    end)
    if not ok or type(attributes) ~= "table" then
        return {}
    end
    return safeValue(attributes) or {}
end
local function safeAncestry(remote)
    local ancestry = {}
    local current = remote
    for _ = 1, 64 do
        local info = safeInstanceInfo(current)
        if not info then
            break
        end
        table.insert(ancestry, 1, info)
        local ok, parent = pcall(function()
            return current.Parent
        end)
        if not ok then
            break
        end
        current = parent
    end
    return ancestry
end
local function emptyStorageDocument()
    return {
        schema = STORAGE_SCHEMA,
        hub = "Exodus Hub",
        file = STORAGE_FILE,
        captures = {},
    }
end
local function writeStorage()
    if not Storage.available or Storage.writeBlocked then
        return false
    end
    local document = emptyStorageDocument()
    document.captures = Storage.captures
    local encodeOk, body = pcall(HttpService.JSONEncode, HttpService, document)
    if not encodeOk or type(body) ~= "string" then
        Storage.writeBlocked = true
        reportStorageError("falha ao codificar " .. Storage.path)
        return false
    end
    local writeOk, writeResult = pcall(writefile, Storage.path, body)
    if not writeOk or writeResult == false then
        Storage.writeBlocked = true
        reportStorageError(writeResult or ("falha ao gravar " .. Storage.path))
        return false
    end
    Storage.lastWriteAt = os.time()
    Storage.lastError = nil
    return true
end
local function initializeStorage()
    if Storage.initialized then
        return Storage.available
    end
    Storage.initialized = true
    local folderOk, folderPath = Utils.ensureDataFolder()
    if not folderOk then
        reportStorageError(folderPath)
        return false
    end
    Storage.path = folderPath .. "/" .. STORAGE_FILE
    if type(isfile) ~= "function"
        or type(readfile) ~= "function"
        or type(writefile) ~= "function"
    then
        reportStorageError("APIs de arquivo do executor indisponíveis")
        return false
    end
    local fileOk, fileExists = pcall(isfile, Storage.path)
    if not fileOk then
        reportStorageError(fileExists)
        return false
    end
    local body = ""
    if fileExists then
        local readOk
        readOk, body = pcall(readfile, Storage.path)
        if not readOk then
            reportStorageError(body)
            return false
        end
        if body ~= "" then
            local decodeOk, document = pcall(HttpService.JSONDecode, HttpService, body)
            if not decodeOk
                or type(document) ~= "table"
                or document.schema ~= STORAGE_SCHEMA
                or type(document.captures) ~= "table"
            then
                reportStorageError(Storage.path .. " possui JSON inválido ou schema incompatível")
                return false
            end
            for _, capture in ipairs(document.captures) do
                if type(capture) == "table" then
                    Storage.captures[#Storage.captures + 1] = capture
                end
            end
        end
    end
    Storage.available = true
    if not fileExists or body == "" then
        writeStorage()
    end
    return true
end
local function queueStorageWrite()
    if not initializeStorage() or Storage.writeBlocked or Storage.flushQueued then
        return
    end
    Storage.flushQueued = true
    task.spawn(function()
        Storage.flushQueued = false
        writeStorage()
    end)
end
local function captureRemote(remote)
    local ok, errorMessage = pcall(function()
        if not initializeStorage() then
            return
        end
        local parent
        local parentOk = pcall(function()
            parent = remote.Parent
        end)
        local remoteInfo = safeInstanceInfo(remote)
        if not remoteInfo then
            return
        end
        local capture = {
            id = #Storage.captures + 1,
            capturedAt = os.time(),
            source = "remote_hook",
            name = remoteInfo.name,
            className = remoteInfo.className,
            fullName = remoteInfo.fullName,
            parent = parentOk and safeInstanceInfo(parent) or nil,
            ancestry = safeAncestry(remote),
            attributes = safeAttributes(remote),
            requirements = {
                className = "RemoteEvent",
                methods = { "FireServer" },
                events = { "OnClientEvent" },
                payloadFlags = { 1, 2 },
            },
        }
        Storage.captures[#Storage.captures + 1] = capture
        queueStorageWrite()
    end)
    if not ok then
        reportStorageError(errorMessage)
    end
end
local function getStorageStatus()
    return {
        schema = STORAGE_SCHEMA,
        available = Storage.available == true,
        path = Storage.path,
        captures = #Storage.captures,
        lastWriteAt = Storage.lastWriteAt,
        lastError = Storage.lastError,
    }
end
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
        local hadRemote = parryRemote ~= nil
        parryRemote = nil
        parryRemoteSource = nil
        parryInitialized = false
        if hadRemote then
            remoteState = "lost"
        end
    end
end
local function registerRemote(remote)
    if not isAlive(remote) then
        return
    end
    captureRemote(remote)
    if not isAlive(parryRemote) then
        clearParryRemote(parryRemote)
    end
    local shouldAssign = false
    if not parryRemote then
        shouldAssign = true
    elseif parryRemoteSource == "feio4" then
        shouldAssign = true
    end
    if shouldAssign then
        parryRemote = remote
        parryRemoteSource = "hook"
        remoteState = "captured"
        if Utils and type(Utils.recordTransition) == "function" then
            Utils.recordTransition("Remote", "hooked", "captured", "remote_captured")
        end
    end
end

-- feio-4 fallback
local function isParryCandidate(value)
    return typeof(value) == "Instance"
        and value:IsA("RemoteEvent")
        and value.Parent ~= nil
end
function Remote.resolveParryRemote()
    if isAlive(parryRemote) then
        return parryRemote
    end

    parryRemote = nil
    parryRemoteSource = nil

    local Players = Utils and Utils.getPlayers and Utils.getPlayers() or nil
    local lp = Players and Players.LocalPlayer or nil
    local RSrv = Utils and Utils.getReplicatedStorage and Utils.getReplicatedStorage() or nil
    if not (lp and RSrv) then
        return nil
    end

    local touchTap = RSrv:FindFirstChild("TouchTap")
    if not touchTap
        or not touchTap:IsA("BindableEvent")
        or type(getconnections) ~= "function"
    then
        return nil
    end

    local okConnections, connections = pcall(getconnections, touchTap.Event)
    if not okConnections or type(connections) ~= "table" then
        return nil
    end

    for _, connection in ipairs(connections) do
        local fn = connection.Function
        if type(fn) == "function" then
            if type(getfenv) == "function" then
                local okEnv, env = pcall(getfenv, fn)
                if okEnv and type(env) == "table" then
                    local globalEnv = rawget(env, "_G")
                    local did = type(globalEnv) == "table" and rawget(globalEnv, "did2") or nil
                    if isParryCandidate(did) then
                        parryRemote = did
                        parryRemoteSource = "feio4"
                        remoteState = "captured"
                        captureRemote(did)
                        return parryRemote
                    end
                end
            end

            if debug and type(debug.getupvalues) == "function" then
                local okUps, upvalues = pcall(debug.getupvalues, fn)
                if okUps and type(upvalues) == "table" then
                    for _, value in pairs(upvalues) do
                        if type(value) == "table"
                            and rawget(value, "Owner") == lp
                            and rawget(value, "BaseDistance") == 8.5
                        then
                            local did = rawget(value, "did")
                            if isParryCandidate(did) then
                                parryRemote = did
                                parryRemoteSource = "feio4"
                                remoteState = "captured"
                                captureRemote(did)
                                return parryRemote
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end
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
        or type(deps.Utils.apiVersion) ~= "function"
        or type(deps.Utils.trackGlobal) ~= "function"
        or type(deps.Utils.untrackGlobal) ~= "function"
        or type(deps.Utils.ensureDataFolder) ~= "function"
        or type(deps.Utils.warn) ~= "function"
    then
        return false
    end
    Utils = deps.Utils
    initializeStorage()
    remoteState = "hooked"
    HookState.register = registerRemote
    if not installHooks() then
        HookState.register = nil
        Utils.warn("hooks do Remote indisponíveis, usando fallback feio-4")
        local fallback = Remote.resolveParryRemote()
        if not isAlive(fallback) then
            Utils.warn("fallback feio-4 também falhou em capturar parry Remote")
            return false
        end
    end
    return true
end

-- parry api
function Remote.fireParry(flag)
    if not isAlive(parryRemote) then
        clearParryRemote(parryRemote)
        local fallback = Remote.resolveParryRemote()
        if not isAlive(fallback) then
            remoteState = "lost"
            if Utils and type(Utils.recordError) == "function" then
                Utils.recordError("Remote", "parry Remote indisponível")
            end
            return false
        end
    end
    local ok, errorMessage = pcall(function()
        parryRemote:FireServer(payloadFor(flag))
    end)
    if not ok then
        remoteState = isAlive(parryRemote) and "captured" or "lost"
        if Utils and type(Utils.recordError) == "function" then
            Utils.recordError("Remote", errorMessage)
        end
        return false
    end
    remoteState = "ready"
    return true
end
function Remote.initParry()
    if not isAlive(parryRemote) then
        clearParryRemote(parryRemote)
        local fallback = Remote.resolveParryRemote()
        if not isAlive(fallback) then
            remoteState = "lost"
            return false
        end
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
    remoteState = ok and "ready" or "hooked"
    return ok
end
function Remote.getRemote()
    if isAlive(parryRemote) then
        return parryRemote
    end
    if parryRemote ~= nil then
        clearParryRemote(parryRemote)
    end
    return Remote.resolveParryRemote()
end
function Remote.getStatus()
    local remote = Remote.getRemote()
    local state = remoteState
    if state == "sync_missing" or state == "sync_error" then
        if not remote then
            state = HookState.installed and "hooked" or "uninitialized"
        elseif parryInitialized then
            state = "ready"
        else
            state = "captured"
        end
    elseif state == "lost" and remote then
        state = parryInitialized and "ready" or "captured"
    elseif state == "uninitialized" and HookState.installed then
        state = remote and "captured" or "hooked"
    elseif not remote and state == "ready" then
        state = "lost"
    end
    return {
        schema = Utils.apiVersion(),
        state = state,
        initialized = parryInitialized == true,
        source = parryRemoteSource,
        hasBallSync = ballSyncConnection ~= nil
            and ballSyncConnection.Connected == true
            and ballSyncRemote ~= nil,
        storage = getStorageStatus(),
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
        remoteState = "sync_missing"
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
        remoteState = "sync_error"
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
    maintenanceGeneration = maintenanceGeneration + 1
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
    maintenanceGeneration = maintenanceGeneration + 1
    local generation = maintenanceGeneration
    task.spawn(function()
        while generation == maintenanceGeneration do
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
