-- [[ remote ]]

local Remote = {}
local Utils, GameInfo
local HttpService = game:GetService("HttpService")
local ballSyncRemote, ballSyncConnection
local parryRemote, parryRemoteSource
local parryInitialized = false
local remoteState = "uninitialized"
local maintenanceGeneration = 0
local captureEnabled = false
local loggedMethods = {}
local capturedRemotes = setmetatable({}, {__mode = "k"})

local STORAGE_SCHEMA = 1
local STORAGE_FILE = "deflect_remotes.json"
local MAX_CAPTURES = 128
local storage = {
    initialized = false,
    available = false,
    writeBlocked = false,
    flushQueued = false,
    path = STORAGE_FILE,
    captures = {},
    lastWriteAt = 0,
    lastError = nil,
}

local function instanceInfo(object)
    if typeof(object) ~= "Instance" then return nil end
    local info = {}
    local ok, name = pcall(function() return object.Name end)
    if ok then info.name = name end
    ok, name = pcall(function() return object.ClassName end)
    if ok then info.className = name end
    ok, name = pcall(function() return object:GetFullName() end)
    if ok then info.fullName = name end
    return info
end

local function serializable(value, depth)
    depth = depth or 0
    if value == nil or type(value) == "boolean" or type(value) == "string" then return value end
    if type(value) == "number" then
        return value == value and math.abs(value) < math.huge and value or tostring(value)
    end
    if depth >= 3 then return tostring(value) end

    local kind = typeof(value)
    if kind == "Vector3" then return {type = kind, x = value.X, y = value.Y, z = value.Z} end
    if kind == "Color3" then return {type = kind, r = value.R, g = value.G, b = value.B} end
    if kind == "CFrame" then return {type = kind, components = {value:GetComponents()}} end
    if kind == "EnumItem" then
        return {type = kind, enumType = tostring(value.EnumType), name = value.Name, value = value.Value}
    end
    if kind == "Instance" then return instanceInfo(value) end

    if type(value) == "table" then
        local result = {}
        for key, item in pairs(value) do
            result[type(key) == "string" and key or tostring(key)] = serializable(item, depth + 1)
        end
        return result
    end
    return tostring(value)
end

local function ancestry(object)
    local result = {}
    for _ = 1, 64 do
        local info = instanceInfo(object)
        if not info then break end
        table.insert(result, 1, info)
        local ok, parent = pcall(function() return object.Parent end)
        if not ok then break end
        object = parent
    end
    return result
end

local function writeStorage()
    if not storage.available or storage.writeBlocked then return false end
    local document = {
        schema = STORAGE_SCHEMA,
        hub = "Exodus Hub",
        file = STORAGE_FILE,
        captures = storage.captures,
    }
    local ok, data = pcall(HttpService.JSONEncode, HttpService, document)
    if not ok or type(data) ~= "string" then
        storage.writeBlocked = true
        storage.lastError = "falha ao codificar " .. storage.path
        return false
    end

    local saved, err = pcall(writefile, storage.path, data)
    if not saved or err == false then
        storage.writeBlocked = true
        storage.lastError = tostring(err or ("falha ao gravar " .. storage.path))
        return false
    end
    storage.lastWriteAt = os.time()
    storage.lastError = nil
    return true
end

local function initStorage()
    if storage.initialized then return storage.available end
    storage.initialized = true
    local ok, folder = Utils.ensureDataFolder()
    if not ok then
        storage.initialized = false
        storage.lastError = tostring(folder)
        return false
    end

    storage.path = folder .. "/" .. STORAGE_FILE
    if type(isfile) ~= "function" or type(readfile) ~= "function"
        or type(writefile) ~= "function" then
        storage.initialized = false
        storage.lastError = "APIs de arquivo do executor indisponíveis"
        return false
    end

    local checked, exists = pcall(isfile, storage.path)
    if not checked then
        storage.initialized = false
        storage.lastError = tostring(exists)
        return false
    end

    local body = ""
    if exists then
        local readOk
        readOk, body = pcall(readfile, storage.path)
        if not readOk then
            storage.initialized = false
            storage.lastError = tostring(body)
            return false
        end

        if body ~= "" then
            local decoded, document = pcall(HttpService.JSONDecode, HttpService, body)
            if not decoded or type(document) ~= "table"
                or document.schema ~= STORAGE_SCHEMA or type(document.captures) ~= "table" then
                storage.lastError = storage.path .. " possui JSON inválido ou schema incompatível"
                return false
            end

            for i = math.max(1, #document.captures - MAX_CAPTURES + 1), #document.captures do
                if type(document.captures[i]) == "table" then
                    storage.captures[#storage.captures + 1] = document.captures[i]
                end
            end
        end
    end

    storage.available = true
    if not exists or body == "" then writeStorage() end
    return true
end

local function capture(remote)
    if not captureEnabled or capturedRemotes[remote] then return end
    capturedRemotes[remote] = true

    task.spawn(function()
        local ok, err = pcall(function()
            if not initStorage() then return end
            local info = instanceInfo(remote)
            if not info then return end

            local parent = remote.Parent
            local attributesOk, attributes = pcall(function() return remote:GetAttributes() end)
            local entry = {
                id = #storage.captures + 1,
                capturedAt = os.time(),
                source = "phantomballz",
                name = info.name,
                className = info.className,
                fullName = info.fullName,
                parent = instanceInfo(parent),
                ancestry = ancestry(remote),
                attributes = attributesOk and serializable(attributes) or {},
                requirements = {
                    className = "RemoteEvent",
                    methods = {"FireServer"},
                    source = "ReplicatedStorage.TouchTap",
                    resolution = {"getconnections", "getfenv", "debug.getupvalues"},
                    globalKey = "did2",
                    upvalueKey = "did",
                    owner = "LocalPlayer",
                    baseDistance = 8.5,
                    payloadFlags = {1, 2},
                },
            }

            if #storage.captures >= MAX_CAPTURES then table.remove(storage.captures, 1) end
            storage.captures[#storage.captures + 1] = entry

            if not storage.flushQueued and not storage.writeBlocked then
                storage.flushQueued = true
                task.spawn(function()
                    writeStorage()
                    storage.flushQueued = false
                end)
            end
        end)
        if not ok then storage.lastError = tostring(err) end
    end)
end

local function isRemote(object)
    return object and typeof(object) == "Instance" and object:IsA("RemoteEvent") and object.Parent ~= nil
end

local function getAbility()
    return GameInfo and GameInfo.getDeflectAbility() or nil
end

local function trace(errorMessage)
    if type(debug) == "table" and type(debug.traceback) == "function" then
        return debug.traceback(tostring(errorMessage), 2)
    end
    return tostring(errorMessage)
end

function Remote.setParryRemote(remote)
    if not isRemote(remote) then return false end
    parryRemote = remote
    parryRemoteSource = "external"
    parryInitialized = false
    remoteState = "captured"
    capture(remote)
    return true
end

function Remote.setup(deps)
    if type(deps) ~= "table" or not deps.Utils or type(deps.GameInfo) ~= "table"
        or type(deps.GameInfo.getDeflectAbility) ~= "function"
        or type(deps.GameInfo.noteDeflectPress) ~= "function" then
        return false, "dependência ausente: Utils ou API de Deflect do GameInfo"
    end

    Utils, GameInfo = deps.Utils, deps.GameInfo
    captureEnabled = deps.captureDiagnostics == true
    remoteState = "deflect_only"
    table.clear(loggedMethods)
    return true
end

function Remote.fireParry(_flag)
    local ability = getAbility()
    if not ability then
        remoteState = "unavailable"
        parryInitialized = false
        parryRemoteSource = nil
        return false, "Deflect indisponível"
    end

    local ok, sent = xpcall(ability.Deflect, trace, ability)
    if not ok then
        remoteState = "deflect_error"
        return false, sent
    end
    if sent == false then
        remoteState = "deflect_ignored"
        return false, "Deflect recusou a chamada"
    end

    GameInfo.noteDeflectPress()
    remoteState = "deflect"
    parryRemoteSource = "ClientAbilities.Abilities[1]:Deflect"
    if not loggedMethods.deflect then
        loggedMethods.deflect = true
        print("[Exodus Remote] Deflect() chamado")
    end
    return true
end

function Remote.initParry()
    parryInitialized = getAbility() ~= nil
    return parryInitialized
end

function Remote.usesGameDeflect()
    return getAbility() ~= nil
end

function Remote.getRemote()
    return getAbility()
end

local function findBallSync()
    local replicated = Utils.getReplicatedStorage()
    if not replicated then return nil end
    local remotes = replicated:FindFirstChild("Remotes")
    for _, candidate in pairs({
        remotes and remotes:FindFirstChild("BallSyncData"),
        replicated:FindFirstChild("BallSyncData"),
        replicated:FindFirstChild("BallSyncData", true),
    }) do
        if candidate and candidate:IsA("RemoteEvent") then return candidate end
    end
    return nil
end

local function disconnectBallSync()
    if ballSyncConnection then
        pcall(ballSyncConnection.Disconnect, ballSyncConnection)
        if Utils and Utils.untrackGlobal then Utils.untrackGlobal(ballSyncConnection) end
    end
    ballSyncConnection, ballSyncRemote = nil, nil
end

function Remote.bindBallSync(handler)
    if type(handler) ~= "function" then return false end
    local remote = findBallSync()
    if not remote then
        if ballSyncRemote and not isRemote(ballSyncRemote) then disconnectBallSync() end
        return ballSyncConnection ~= nil and ballSyncConnection.Connected
    end

    if ballSyncConnection and ballSyncConnection.Connected and ballSyncRemote == remote then
        return true
    end

    disconnectBallSync()
    local ok, connection = pcall(function() return remote.OnClientEvent:Connect(handler) end)
    if not ok or not connection then return false end

    ballSyncRemote, ballSyncConnection = remote, connection
    Utils.trackGlobal(connection)
    return true
end

function Remote.startMaintenance(options)
    options = type(options) == "table" and options or {}
    if type(options.isActive) ~= "function" then return false end

    maintenanceGeneration += 1
    local token = maintenanceGeneration

    task.spawn(function()
        while token == maintenanceGeneration do
            local ok, active = pcall(options.isActive)
            if not ok or active ~= true then break end

            local remoteOk, remote = pcall(Remote.getRemote)
            if not remoteOk then remote = nil end
            if remote then pcall(Remote.initParry) else parryInitialized = false end

            if type(options.onBallSync) == "function" then
                pcall(Remote.bindBallSync, options.onBallSync)
            end
            task.wait(remote and 3 or 1)
        end
    end)
    return true
end

function Remote.stopMaintenance()
    maintenanceGeneration += 1
    disconnectBallSync()
end

function Remote.getStatus()
    return {
        schema = Utils.apiVersion(),
        state = remoteState,
        method = getAbility() and "Deflect" or "unavailable",
        initialized = parryInitialized,
        source = parryRemoteSource,
        hasBallSync = ballSyncConnection ~= nil and ballSyncConnection.Connected == true and ballSyncRemote ~= nil,
        storage = {
            schema = STORAGE_SCHEMA,
            enabled = captureEnabled,
            available = captureEnabled and storage.available or false,
            path = captureEnabled and storage.path or nil,
            captures = captureEnabled and #storage.captures or 0,
            lastWriteAt = captureEnabled and storage.lastWriteAt or 0,
            lastError = captureEnabled and storage.lastError or nil,
        },
    }
end

Remote.__contract = {
    requires = {Utils = "utils", GameInfo = "gameinfo"},
    requiresMethods = {
        Utils = {"getReplicatedStorage", "trackGlobal", "untrackGlobal", "apiVersion"},
        GameInfo = {"getDeflectAbility", "noteDeflectPress"},
    },
    provides = {"setup", "getRemote", "initParry", "fireParry", "bindBallSync", "startMaintenance", "stopMaintenance"},
    ballSync = true,
    remoteResolution = "Deflect",
}

return Remote
