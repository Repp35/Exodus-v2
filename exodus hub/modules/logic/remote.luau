--[[ Remote ]]

-- state
local Remote = {}
local Utils
local ballSyncConnection
local ballSyncRemote
local parryRemote
local parryInitialized = false
local maintenanceGeneration = 0
local parryRemoteSource
local remoteState = "uninitialized"

local HttpService = game:GetService("HttpService")
local STORAGE_SCHEMA = 1
local STORAGE_FILE = "deflect_remotes.json"
local MAX_CAPTURED_REMOTES = 128

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

local CapturedRemotes = setmetatable({}, { __mode = "k" })

local function reportStorageError(message)
    Storage.lastError = tostring(message)
    if not Storage.errorReported and Utils and type(Utils.recordError) == "function" then
        Storage.errorReported = true
        Utils.recordError("RemoteStorage", Storage.lastError)
    end
end

local function safeInstanceInfo(instance)
    if typeof(instance) ~= "Instance" then return nil end
    local info = {}
    local okName, name = pcall(function() return instance.Name end)
    local okClass, className = pcall(function() return instance.ClassName end)
    local okFullName, fullName = pcall(function() return instance:GetFullName() end)
    if okName then info.name = name end
    if okClass then info.className = className end
    if okFullName then info.fullName = fullName end
    return info
end

local function safeValue(value, depth)
    depth = depth or 0
    if value == nil then return nil end
    if type(value) == "boolean" or type(value) == "string" then return value end
    if type(value) == "number" then
        if value == value and value < math.huge and value > -math.huge then
            return value
        end
        return tostring(value)
    end
    if depth >= 3 then return tostring(value) end

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
        return { type = valueType, enumType = tostring(value.EnumType), name = value.Name, value = value.Value }
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
    local ok, attributes = pcall(function() return remote:GetAttributes() end)
    if not ok or type(attributes) ~= "table" then return {} end
    return safeValue(attributes) or {}
end

local function safeAncestry(remote)
    local ancestry = {}
    local current = remote
    for _ = 1, 64 do
        local info = safeInstanceInfo(current)
        if not info then break end
        table.insert(ancestry, 1, info)
        local ok, parent = pcall(function() return current.Parent end)
        if not ok then break end
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
    if not Storage.available or Storage.writeBlocked then return false end
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
    if Storage.initialized then return Storage.available end
    Storage.initialized = true

    local folderOk, folderPath = Utils.ensureDataFolder()
    if not folderOk then
        reportStorageError(folderPath)
        return false
    end

    Storage.path = folderPath .. "/" .. STORAGE_FILE
    if type(isfile) ~= "function" or type(readfile) ~= "function" or type(writefile) ~= "function" then
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
            if not decodeOk or type(document) ~= "table" or document.schema ~= STORAGE_SCHEMA or type(document.captures) ~= "table" then
                reportStorageError(Storage.path .. " possui JSON inválido ou schema incompatível")
                return false
            end
            local firstCapture = math.max(1, #document.captures - MAX_CAPTURED_REMOTES + 1)
            for index = firstCapture, #document.captures do
                local capture = document.captures[index]
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
    if not initializeStorage() or Storage.writeBlocked or Storage.flushQueued then return end
    Storage.flushQueued = true
    task.spawn(function()
        Storage.flushQueued = false
        writeStorage()
    end)
end

local function captureRemote(remote)
    if CapturedRemotes[remote] then return end
    CapturedRemotes[remote] = true

    task.spawn(function()
        local ok, errorMessage = pcall(function()
            if not initializeStorage() then return end
            local parent
            local parentOk = pcall(function() parent = remote.Parent end)
            local remoteInfo = safeInstanceInfo(remote)
            if not remoteInfo then return end

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
            if #Storage.captures >= MAX_CAPTURED_REMOTES then
                table.remove(Storage.captures, 1)
            end
            Storage.captures[#Storage.captures + 1] = capture
            queueStorageWrite()
        end)
        if not ok then reportStorageError(errorMessage) end
    end)
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

function Remote.setParryRemote(remote)
    if not isAlive(remote) then
        return false
    end
    parryRemote = remote
    parryRemoteSource = "external"
    parryInitialized = false
    remoteState = "captured"
    captureRemote(remote)
    return true
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
    remoteState = "hooked"
    initializeStorage()
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

function Remote.getStatus()
    return {
        schema = Utils.apiVersion(),
        state = remoteState,
        initialized = parryInitialized == true,
        source = parryRemoteSource,
        hasBallSync = ballSyncConnection ~= nil and ballSyncConnection.Connected == true and ballSyncRemote ~= nil,
        storage = getStorageStatus(),
    }
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

function Remote.stopMaintenance()
    maintenanceGeneration = maintenanceGeneration + 1
    disconnectBallSync()
end

Remote.__contract = {
    requires = { Utils = "utils" },
    ballSync = true,
}

return Remote
