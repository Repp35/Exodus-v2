-- [[ utils ]]

local Utils = {}
export type SpamRateMode = "CPS" | "CPF"
export type ConfigSnapshot = {
    AutoParry: boolean?,
    AutoParryWindowFactor: number?,
    AutoClash: boolean?,
    AutoDark: boolean?,
    ClashBallVisible: boolean?,
    CPS: number?,
    CPF: number?,
    SpamRateMode: SpamRateMode?,
    Keybind: Enum.KeyCode?,
    SpamKeybind: Enum.KeyCode?,
    [string]: any,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local VERSION, API_VERSION = "35.42", 1
local NAME, AUTHOR = "Exodus Hub", "delta"
local DATA_FOLDER, MAX_LOGS = "Exodus Hub", 32

local ConfigModule
local persistenceReady, saveQueued = false, false
local diagnosticsModules = {}
local spamObservers, configObservers = {}, {}
local namespaceUpdating, transitionRefreshPending = false, false

local state = {
    active = false,
    connections = {},
    characterConnections = {},
    config = {},
    moduleURLs = {},
    manualSpamActive = false,
    autoSpamActive = false,
    lifecycle = {phase = "stopped", generation = 0, startedAt = 0, stoppedAt = 0},
    diagnostics = {
        lastError = nil,
        lastTransition = nil,
        lastTransitionAt = 0,
        errors = {},
        transitions = {},
    },
}

task.defer(function()
    local ok, err = pcall(Workspace.SetAttribute, Workspace, "CPS_LIMIT", math.huge)
    if not ok then warn("[Utils] Não foi possível atualizar CPS_LIMIT: " .. tostring(err)) end
end)

local function copy(value, depth)
    if type(value) ~= "table" or (depth or 0) > 8 then return value end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key, (depth or 0) + 1)] = copy(item, (depth or 0) + 1)
    end
    return result
end

local function appendLog(list, entry)
    list[#list + 1] = entry
    if #list > MAX_LOGS then table.remove(list, 1) end
end

local function disconnect(connection)
    if not connection or type(connection.Disconnect) ~= "function" then return false end
    return pcall(connection.Disconnect, connection)
end

local function disconnectAll(list)
    for index = #list, 1, -1 do
        disconnect(list[index])
        list[index] = nil
    end
end

local function track(list, connection)
    if connection and type(connection.Disconnect) == "function" then
        list[#list + 1] = connection
    end
    return connection
end

local function untrack(list, connection)
    for index = #list, 1, -1 do
        if list[index] == connection then
            table.remove(list, index)
            return true
        end
    end
    return false
end

local function notify(observers, payload, label)
    for callback in pairs(observers) do
        local ok, err = pcall(callback, payload)
        if not ok then warn("[" .. label .. "] " .. tostring(err)) end
    end
end

local function observe(observers, callback)
    if type(callback) ~= "function" then return nil end
    observers[callback] = true
    return {Disconnect = function() observers[callback] = nil end}
end

function Utils.observeSpam(callback)
    return observe(spamObservers, callback)
end

function Utils.observeConfig(callback)
    return observe(configObservers, callback)
end

local function moduleStatuses()
    local statuses = {}
    for name, module in pairs(diagnosticsModules) do
        if type(module) == "table" and type(module.getStatus) == "function" then
            local ok, result = pcall(module.getStatus)
            statuses[name] = ok and type(result) == "table" and copy(result)
                or {ok = false, error = tostring(result)}
        end
    end
    return statuses
end

local function lifecycleSnapshot()
    local snapshot = copy(state.lifecycle)
    snapshot.schema = API_VERSION
    snapshot.generatedAt = os.clock()
    return snapshot
end

local function diagnosticsSnapshot()
    local data = state.diagnostics
    return {
        schema = API_VERSION,
        generatedAt = os.clock(),
        lastError = copy(data.lastError),
        lastTransition = copy(data.lastTransition),
        lastTransitionAt = data.lastTransitionAt,
        errors = copy(data.errors),
        transitions = copy(data.transitions),
        lifecycle = lifecycleSnapshot(),
        runtime = {
            active = state.active,
            manualSpamActive = state.manualSpamActive,
            autoSpamActive = state.autoSpamActive,
        },
        modules = moduleStatuses(),
    }
end

local function stateSnapshot()
    return {
        schema = API_VERSION,
        generatedAt = os.clock(),
        active = state.active,
        manualSpamActive = state.manualSpamActive,
        autoSpamActive = state.autoSpamActive,
        lifecycle = copy(state.lifecycle),
        config = copy(state.config),
        moduleURLs = copy(state.moduleURLs),
        connectionCounts = {
            global = #state.connections,
            character = #state.characterConnections,
        },
    }
end

local function publish()
    if namespaceUpdating then return end
    namespaceUpdating = true
    local ok, err = pcall(function()
        local exodus = type(_G.Exodus) == "table" and _G.Exodus or {}
        exodus.Name = NAME
        exodus.InternalName = "Exodus"
        exodus.Version = VERSION
        exodus.ApiVersion = API_VERSION
        exodus.Author = AUTHOR
        exodus.State = stateSnapshot()
        exodus.Config = copy(state.config)
        exodus.ModuleURLs = copy(state.moduleURLs)
        exodus.Diagnostics = diagnosticsSnapshot()
        _G.Exodus = exodus
    end)
    namespaceUpdating = false
    if not ok then warn("[Utils] " .. tostring(err)) end
end

local function transition(source, before, after, reason)
    local entry = {
        source = tostring(source or "Unknown"),
        from = tostring(before or ""),
        to = tostring(after or ""),
        reason = tostring(reason or ""),
        at = os.clock(),
    }
    local data = state.diagnostics
    data.lastTransition = entry
    data.lastTransitionAt = entry.at
    appendLog(data.transitions, entry)

    if not transitionRefreshPending then
        transitionRefreshPending = true
        task.delay(0.1, function()
            transitionRefreshPending = false
            publish()
        end)
    end
end

local function ensureFolder()
    if type(makefolder) ~= "function" or type(isfolder) ~= "function" then
        return false, "APIs de pasta do executor indisponíveis"
    end

    local ok, exists = pcall(isfolder, DATA_FOLDER)
    if not ok then return false, tostring(exists) end
    if exists then return true, DATA_FOLDER end

    local created, err = pcall(makefolder, DATA_FOLDER)
    if not created then return false, tostring(err or ("falha ao criar " .. DATA_FOLDER)) end
    return true, DATA_FOLDER
end

function Utils.ensureDataFolder()
    return ensureFolder()
end

function Utils.start()
    local previous = state.lifecycle.phase
    state.lifecycle.generation += 1
    state.lifecycle.startedAt = os.clock()
    state.lifecycle.stoppedAt = 0
    state.active = true
    state.lifecycle.phase = "starting"
    transition("Utils", previous, "starting", "start")
    if _G.ExodusOnBurst == nil then _G.ExodusOnBurst = function() end end
    publish()
    return stateSnapshot()
end

function Utils.stop()
    local previous = state.lifecycle.phase
    state.active = false
    state.manualSpamActive, state.autoSpamActive = false, false
    notify(spamObservers, nil, "Spam")
    state.lifecycle.stoppedAt = os.clock()
    _G.ExodusOnBurst = function() end

    local antitamper = diagnosticsModules.antitamper
    if type(antitamper) == "table" and type(antitamper.teardown) == "function" then
        local ok, err = pcall(antitamper.teardown)
        if not ok then warn("[AntiTamper] " .. tostring(err)) end
    end

    if type(_G.ExodusUICleanup) == "function" then pcall(_G.ExodusUICleanup) end
    disconnectAll(state.characterConnections)
    disconnectAll(state.connections)
    state.config, state.moduleURLs = {}, {}
    diagnosticsModules = {}

    if type(_G.Exodus) == "table" then
        local exodus = _G.Exodus
        exodus.Started, exodus.UIReady = false, false
        exodus.Runtime, exodus.UI = nil, nil
        if type(exodus.RemoteHooks) == "table" then exodus.RemoteHooks.register = nil end
        if type(exodus.AutoParryHitbox) == "table" then
            local hitbox = exodus.AutoParryHitbox
            disconnect(hitbox.connection)
            hitbox.connection, hitbox.handler = nil, nil
        end
    end

    state.lifecycle.phase = "stopped"
    transition("Utils", previous, "stopped", "stop")
    publish()
    return true
end

function Utils.isActive() return state.active == true end
function Utils.getStateSnapshot() return stateSnapshot() end
function Utils.getConfig(): ConfigSnapshot return copy(state.config) end
function Utils.getConfigValue(key: string): any return state.config[key] end
function Utils.getConfigSnapshot() return copy(state.config) end
function Utils.getModuleURLsSnapshot() return copy(state.moduleURLs) end
function Utils.getLifecycle() return lifecycleSnapshot() end
function Utils.getDiagnostics() return diagnosticsSnapshot() end

function Utils.setDiagnosticsModules(modules)
    if type(modules) ~= "table" then return false end
    diagnosticsModules = copy(modules)
    publish()
    return true
end

function Utils.setLifecyclePhase(phase)
    if type(phase) ~= "string" or phase == "" then return false end
    local before = state.lifecycle.phase
    if before == phase then return true end
    state.lifecycle.phase = phase
    transition("Lifecycle", before, phase, "phase_change")
    return true
end

function Utils.recordTransition(source, before, after, reason)
    transition(source, before, after, reason)
end

function Utils.recordError(source, message)
    local entry = {source = tostring(source or "Unknown"), message = tostring(message or ""), at = os.clock()}
    state.diagnostics.lastError = entry
    appendLog(state.diagnostics.errors, entry)
    warn(("[%s] %s"):format(entry.source, entry.message))
    publish()
    return true
end

function Utils.isManualSpamActive() return state.manualSpamActive == true end
function Utils.isAutoSpamActive() return state.autoSpamActive == true end
function Utils.isSpamActive() return state.manualSpamActive or state.autoSpamActive end

function Utils.setAutoSpamActive(value)
    local enabled = value == true
    if state.autoSpamActive == enabled then return false end
    local before = state.autoSpamActive
    state.autoSpamActive = enabled
    notify(spamObservers, nil, "Spam")
    transition("AutoClash", before and "active" or "inactive", enabled and "active" or "inactive", "automatic_toggle")
    return true
end

function Utils.setManualSpamActive(value)
    local enabled = value == true
    if state.manualSpamActive == enabled then return false end
    local before = state.manualSpamActive
    state.manualSpamActive = enabled
    notify(spamObservers, nil, "Spam")
    transition("Spam", before and "active" or "inactive", enabled and "active" or "inactive", "manual_toggle")
    return true
end

function Utils.stopAllSpam()
    local changed = state.manualSpamActive or state.autoSpamActive
    state.manualSpamActive, state.autoSpamActive = false, false
    if changed then notify(spamObservers, nil, "Spam") end
    return true
end

function Utils.isFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Utils.isNonNegativeFiniteNumber(value)
    return Utils.isFiniteNumber(value) and value >= 0
end

function Utils.normalizeSpamRate(value, fallback)
    local rate = tonumber(value)
    if not Utils.isFiniteNumber(rate) then rate = tonumber(fallback) end
    if not Utils.isFiniteNumber(rate) then rate = 0 end
    return math.max(rate, 0)
end

local function saveConfig()
    if not persistenceReady or saveQueued or type(writefile) ~= "function" then return end
    saveQueued = true
    task.delay(0.25, function()
        saveQueued = false
        local ok, folder = ensureFolder()
        if not ok then Utils.recordError("Config", folder); return end

        local data = {}
        for key, value in pairs(state.config) do
            if typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode then
                data[key] = {keyCode = value.Name}
            else
                data[key] = value
            end
        end

        local encoded, body = pcall(HttpService.JSONEncode, HttpService, data)
        if not encoded then Utils.recordError("Config", tostring(body)); return end
        local written, err = pcall(writefile, folder .. "/config.json", body)
        if not written then Utils.recordError("Config", tostring(err)) end
    end)
end

function Utils.setConfig(config)
    if type(config) ~= "table" then return false end
    local patch = copy(config)

    if ConfigModule and type(ConfigModule.normalizePatch) == "function" then
        local ok, normalized, err = pcall(ConfigModule.normalizePatch, config)
        if not ok then return false, normalized end
        if type(normalized) ~= "table" then return false, err end
        patch = normalized
    end

    for key, value in pairs(patch) do state.config[key] = value end
    notify(configObservers, patch, "Config")

    if patch.SpamRateMode ~= nil or patch.CPF ~= nil then
        notify(spamObservers, nil, "Spam")
    end
    publish()
    saveConfig()
    return true
end

function Utils.loadConfig()
    if type(isfile) == "function" and type(readfile) == "function" then
        local ok, folder = ensureFolder()
        if ok then
            local path = folder .. "/config.json"
            local checked, exists = pcall(isfile, path)
            if checked and exists then
                local readOk, body = pcall(readfile, path)
                local decoded, data = false, nil
                if readOk then decoded, data = pcall(HttpService.JSONDecode, HttpService, body) end

                if decoded and type(data) == "table" then
                    for key, value in pairs(data) do
                        if type(value) == "table" and type(value.keyCode) == "string" then
                            value = Enum.KeyCode[value.keyCode]
                        end
                        if (key == "AutoClashActivationMs" or key == "AutoClashDeactivationMs")
                            and type(value) == "number" and value == value then
                            value = math.clamp(value, 0, 400)
                        end
                        if value ~= nil then Utils.setConfig({[key] = value}) end
                    end
                else
                    Utils.recordError("Config", tostring(readOk and data or body))
                end
            end
        end
    end
    persistenceReady = true
    return true
end

function Utils.setConfigModule(module)
    if type(module) ~= "table" or type(module.normalizePatch) ~= "function"
        or type(module.validate) ~= "function" then return false end
    ConfigModule = module
    return true
end

function Utils.setModuleURLs(urls)
    if type(urls) ~= "table" then return false end
    for name, url in pairs(urls) do state.moduleURLs[name] = url end
    publish()
    return true
end

function Utils.trackGlobal(connection) return track(state.connections, connection) end
function Utils.untrackGlobal(connection) return untrack(state.connections, connection) end
function Utils.trackCharacter(connection) return track(state.characterConnections, connection) end
function Utils.untrackCharacter(connection) return untrack(state.characterConnections, connection) end
function Utils.disconnectCharacterConnections() disconnectAll(state.characterConnections) end

function Utils.getPlayers() return Players end
function Utils.getReplicatedStorage() return ReplicatedStorage end
function Utils.getRunService() return RunService end
function Utils.getWorkspace() return Workspace end
function Utils.getLocalPlayer() return Players.LocalPlayer end
function Utils.now() return os.clock() end
function Utils.name() return NAME end
function Utils.version() return VERSION end
function Utils.apiVersion() return API_VERSION end
function Utils.author() return AUTHOR end

_G.ExodusStop = Utils.stop

Utils.__contract = {
    provides = {
        "start", "stop", "isActive", "getConfig", "getConfigValue", "setConfig",
        "setConfigModule", "setModuleURLs", "setDiagnosticsModules",
        "setLifecyclePhase", "getStateSnapshot", "getConfigSnapshot",
        "getModuleURLsSnapshot", "getPlayers", "getLocalPlayer", "getRunService",
        "getReplicatedStorage", "getWorkspace", "now", "apiVersion", "version",
        "trackGlobal", "untrackGlobal", "trackCharacter", "untrackCharacter",
        "disconnectCharacterConnections", "recordError", "recordTransition",
        "isSpamActive", "isManualSpamActive", "isAutoSpamActive",
        "setManualSpamActive", "setAutoSpamActive", "stopAllSpam",
        "observeConfig", "normalizeSpamRate",
    },
    requires = {},
}

return Utils
