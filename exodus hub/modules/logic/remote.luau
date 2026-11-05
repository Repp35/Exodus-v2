local Remote = {}
local utils, gameInfo, syncConnection, syncRemote
local maintenance = 0
local initialized, source, state, logged, parryBusy = false, nil, "uninitialized", false, false
local captureEnabled, captured = false, setmetatable({}, { __mode = "k" })
local http = game:GetService("HttpService")
local storage = { initialized = false, available = false, blocked = false, queued = false, path = "deflect_remotes.json", captures = {}, lastWriteAt = 0, lastError = nil }

local function info(instance)
    if typeof(instance) ~= "Instance" then return nil end
    local ok, result = pcall(function() return { name = instance.Name, className = instance.ClassName, fullName = instance:GetFullName() } end)
    return ok and result or nil
end
local function jsonValue(value, depth)
    local kind = typeof(value)
    if value == nil or kind == "string" or kind == "boolean" then return value end
    if kind == "number" then
        if value == value and value > -math.huge and value < math.huge then return value end
        return tostring(value)
    end
    if depth >= 3 then return tostring(value) end
    if kind == "Instance" then return info(value) end
    if kind == "Vector3" then return { type = kind, x = value.X, y = value.Y, z = value.Z } end
    if kind == "Color3" then return { type = kind, r = value.R, g = value.G, b = value.B } end
    if kind == "CFrame" then return { type = kind, components = { value:GetComponents() } } end
    if kind == "EnumItem" then return { type = kind, enumType = tostring(value.EnumType), name = value.Name, value = value.Value } end
    if type(value) == "table" then
        local result = {}
        for key, item in pairs(value) do result[type(key) == "string" and key or tostring(key)] = jsonValue(item, depth + 1) end
        return result
    end
    return tostring(value)
end
local function save()
    if not storage.available or storage.blocked then return end
    local ok, body = pcall(http.JSONEncode, http, { schema = 1, hub = "Exodus Hub", file = "deflect_remotes.json", captures = storage.captures })
    if not ok then storage.blocked = true; storage.lastError = tostring(body); return end
    local written, result = pcall(writefile, storage.path, body)
    if not written or result == false then storage.blocked = true; storage.lastError = tostring(result); return end
    storage.lastWriteAt, storage.lastError = os.time(), nil
end
local function initializeStorage()
    if storage.initialized then return storage.available end
    storage.initialized = true
    local folderOk, folder = utils.ensureDataFolder()
    if not folderOk then storage.initialized = false; storage.lastError = tostring(folder); return false end
    storage.path = folder .. "/deflect_remotes.json"
    if type(isfile) ~= "function" or type(readfile) ~= "function" or type(writefile) ~= "function" then
        storage.initialized = false; storage.lastError = "APIs de arquivo do executor indisponíveis"; return false
    end
    local ok, exists = pcall(isfile, storage.path)
    if not ok then storage.initialized = false; storage.lastError = tostring(exists); return false end
    local body = ""
    if exists then
        local readOk
        readOk, body = pcall(readfile, storage.path)
        if not readOk then storage.initialized = false; storage.lastError = tostring(body); return false end
        if body ~= "" then
            local decoded, document = pcall(http.JSONDecode, http, body)
            if not decoded or type(document) ~= "table" or document.schema ~= 1 or type(document.captures) ~= "table" then
                storage.lastError = storage.path .. " possui JSON inválido ou schema incompatível"; return false
            end
            for index = math.max(1, #document.captures - 127), #document.captures do
                if type(document.captures[index]) == "table" then table.insert(storage.captures, document.captures[index]) end
            end
        end
    end
    storage.available = true
    if not exists or body == "" then save() end
    return true
end
local function queueSave()
    if storage.queued or storage.blocked then return end
    storage.queued = true
    task.defer(function() storage.queued = false; save() end)
end
function Remote.capture(instance)
    if not captureEnabled or typeof(instance) ~= "Instance" or captured[instance] or not utils then return false end
    captured[instance] = true
    local ok, err = pcall(function()
        if not initializeStorage() then return end
        local description = info(instance)
        if not description then return end
        local ancestry, current = {}, instance
        for _ = 1, 64 do
            local item = info(current)
            if not item then break end
            table.insert(ancestry, 1, item)
            current = current.Parent
        end
        local attributesOk, attributes = pcall(instance.GetAttributes, instance)
        local capture = {
            id = #storage.captures + 1, capturedAt = os.time(), source = "phantomballz",
            name = description.name, className = description.className, fullName = description.fullName,
            parent = info(instance.Parent), ancestry = ancestry, attributes = attributesOk and jsonValue(attributes, 0) or {},
            requirements = { className = "RemoteEvent", methods = { "FireServer" }, source = "ReplicatedStorage.TouchTap",
                resolution = { "getconnections", "getfenv", "debug.getupvalues" }, globalKey = "did2", upvalueKey = "did",
                owner = "LocalPlayer", baseDistance = 8.5, payloadFlags = { 1, 2 } },
        }
        if #storage.captures >= 128 then table.remove(storage.captures, 1) end
        table.insert(storage.captures, capture)
        queueSave()
    end)
    if not ok then storage.lastError = tostring(err); return false end
    return true
end
local function alive(instance)
    return typeof(instance) == "Instance" and instance:IsA("RemoteEvent") and instance.Parent ~= nil
end
local function disconnectSync()
    if syncConnection then
        if utils then utils.untrackGlobal(syncConnection) end
        syncConnection:Disconnect()
    end
    syncConnection, syncRemote = nil, nil
end
local function findSync()
    local replicated = utils.getReplicatedStorage()
    if not replicated then return nil end
    local remotes = replicated:FindFirstChild("Remotes")
    local candidate = remotes and remotes:FindFirstChild("BallSyncData")
    if alive(candidate) then return candidate end
    candidate = replicated:FindFirstChild("BallSyncData")
    if alive(candidate) then return candidate end
    candidate = replicated:FindFirstChild("BallSyncData", true)
    if alive(candidate) then return candidate end
    return nil
end
function Remote.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table"
        or type(deps.GameInfo.getDeflectAbility) ~= "function" then return false, "dependência ausente: Utils ou API de Deflect do GameInfo" end
    Remote.stopMaintenance()
    utils, gameInfo = deps.Utils, deps.GameInfo
    captureEnabled, state, logged, initialized, source = deps.captureDiagnostics == true, "deflect_only", false, false, nil
    return true
end
function Remote.fireParry(_flag, guard)
    if parryBusy then return false, "Deflect em andamento" end
    parryBusy = true
    local resolved, ability = pcall(function() return gameInfo and gameInfo.getDeflectAbility() end)
    if not resolved then parryBusy = false; state = "deflect_error"; return false, tostring(ability) end
    if not ability then parryBusy = false; state, initialized, source = "unavailable", false, nil; return false, "Deflect indisponível" end
    local guardOk, allowed = pcall(function()
        return (not utils or utils.isActive()) and (type(guard) ~= "function" or guard())
    end)
    if not guardOk or not allowed then
        parryBusy = false
        return false, "Deflect cancelado"
    end
    local ok, result = xpcall(ability.Deflect, function(err)
        if type(debug) == "table" and type(debug.traceback) == "function" then return debug.traceback(tostring(err), 2) end
        return tostring(err)
    end, ability)
    parryBusy = false
    if not ok then state = "deflect_error"; return false, result end
    if result == false then state = "deflect_ignored"; return false, "Deflect recusou a chamada" end
    state, source = "deflect", "ClientAbilities.Abilities[1]:Deflect"
    if not logged then logged = true; print("[Exodus Remote] Deflect() chamado") end
    return true
end
function Remote.initParry() initialized = gameInfo and gameInfo.getDeflectAbility() ~= nil or false; return initialized end
function Remote.usesGameDeflect() return gameInfo ~= nil and gameInfo.getDeflectAbility() ~= nil end
function Remote.getRemote() return gameInfo and gameInfo.getDeflectAbility() or nil end
function Remote.getStatus()
    return {
        schema = utils.apiVersion(), state = state, method = Remote.getRemote() and "Deflect" or "unavailable",
        initialized = initialized, source = source,
        hasBallSync = syncConnection ~= nil and syncConnection.Connected == true and syncRemote ~= nil,
        storage = { schema = 1, enabled = captureEnabled, available = captureEnabled and storage.available or false,
            path = captureEnabled and storage.path or nil, captures = captureEnabled and #storage.captures or 0,
            lastWriteAt = captureEnabled and storage.lastWriteAt or 0, lastError = captureEnabled and storage.lastError or nil },
    }
end
function Remote.bindBallSync(handler)
    if type(handler) ~= "function" then return false end
    local candidate = findSync()
    if not candidate then
        if syncRemote and not alive(syncRemote) then disconnectSync() end
        return syncConnection ~= nil and syncConnection.Connected
    end
    if syncConnection and syncConnection.Connected and syncRemote == candidate then return true end
    disconnectSync()
    local ok, connection = pcall(function() return candidate.OnClientEvent:Connect(handler) end)
    if not ok or not connection then return false end
    syncConnection, syncRemote = connection, candidate
    utils.trackGlobal(connection)
    return true
end
function Remote.startMaintenance(options)
    if type(options) ~= "table" or type(options.isActive) ~= "function" then return false end
    maintenance += 1
    local current = maintenance
    task.spawn(function()
        while current == maintenance do
            local activeOk, active = pcall(options.isActive)
            if current ~= maintenance or not activeOk or active ~= true then break end
            local ok, ability = pcall(Remote.getRemote)
            if not ok then ability = nil end
            if current ~= maintenance then break end
            local stillOk, stillActive = pcall(options.isActive)
            if current ~= maintenance or not stillOk or stillActive ~= true then break end
            if ability then pcall(Remote.initParry) else initialized = false end
            if current ~= maintenance then break end
            stillOk, stillActive = pcall(options.isActive)
            if current ~= maintenance or not stillOk or stillActive ~= true then break end
            if type(options.onBallSync) == "function" then pcall(Remote.bindBallSync, options.onBallSync) end
            task.wait(ability and 3 or 1)
        end
    end)
    return true
end
function Remote.stopMaintenance()
    maintenance += 1
    disconnectSync()
end
Remote.__contract = {
    requires = { Utils = "utils", GameInfo = "gameinfo" },
    requiresMethods = { Utils = { "getReplicatedStorage", "trackGlobal", "untrackGlobal", "apiVersion" }, GameInfo = { "getDeflectAbility" } },
    provides = { "setup", "getRemote", "initParry", "fireParry", "bindBallSync", "startMaintenance", "stopMaintenance" },
    ballSync = true, remoteResolution = "Deflect",
}
return Remote
