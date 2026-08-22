-- [[ Utils ]]

local Utils = {}

-- services
local PlayersService = game:GetService("Players")
local ReplicatedStorageService = game:GetService("ReplicatedStorage")
local RunServiceService = game:GetService("RunService")
local WorkspaceService = game:GetService("Workspace")

-- metadata
local SCRIPT_VERSION = "26.12"
local API_VERSION = 1
local SCRIPT_NAME = "Exodus Hub"
local INTERNAL_NAME = "Exodus"
local SCRIPT_AUTHOR = "ppzudo"

-- limits
local SPAM_RATE_MIN = 0
local SPAM_RATE_MAX = 5000000000
local MAX_DIAGNOSTIC_ENTRIES = 32
local DATA_FOLDER = "Exodus Hub"
local function isValidConfigValue(key, value)
    if key == "AutoParry"
        or key == "AutoClash"
        or key == "ClashBallVisible"
    then
        return type(value) == "boolean"
    end
    if key == "CPS" or key == "CPF" then
        return tonumber(value) ~= nil
    end
    if key == "SpamRateMode" then
        return value == "CPS" or value == "CPF"
    end
    if key == "SpamMode" then
        return value == "Toggle" or value == "Hold"
    end
    if key == "Keybind" or key == "SpamKeybind" then
        return value ~= nil
    end
    return true
end

-- state
local DiagnosticsModules = {}
local State = {
    active = false,
    connections = {},
    characterConnections = {},
    config = {},
    moduleURLs = {},
    manualSpamActive = false,
    autoSpamActive = false,
    lifecycle = {
        phase = "stopped",
        generation = 0,
        startedAt = 0,
        stoppedAt = 0,
    },
    diagnostics = {
        lastError = nil,
        lastTransition = nil,
        lastTransitionAt = 0,
        errors = {},
        transitions = {},
    },
}
-- helpers
local function disconnectAll(list)
    for index = #list, 1, -1 do
        local connection = list[index]
        list[index] = nil
        if connection and type(connection.Disconnect) == "function" then
            pcall(connection.Disconnect, connection)
        end
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
local function copyMap(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end
    for key, value in pairs(source) do
        result[key] = value
    end
    return result
end
local function copyList(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end
    for index, value in ipairs(source) do
        if type(value) == "table" then
            result[index] = copyMap(value)
        else
            result[index] = value
        end
    end
    return result
end
local function getModuleStatuses()
    local result = {}
    for name, module in pairs(DiagnosticsModules) do
        if type(module) == "table" and type(module.getStatus) == "function" then
            local ok, status = pcall(module.getStatus)
            if ok and type(status) == "table" then
                result[name] = status
            end
        end
    end
    return result
end
local function updateNamespace()
    local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
    namespace.Name = SCRIPT_NAME
    namespace.InternalName = INTERNAL_NAME
    namespace.Version = SCRIPT_VERSION
    namespace.ApiVersion = API_VERSION
    namespace.Author = SCRIPT_AUTHOR
    namespace.State = Utils.getStateSnapshot()
    namespace.Config = Utils.getConfigSnapshot()
    namespace.ModuleURLs = Utils.getModuleURLsSnapshot()
    namespace.Diagnostics = Utils.getDiagnostics()
    _G.Exodus = namespace
end
local function setLifecyclePhase(phase)
    if type(phase) ~= "string" or phase == "" then
        return false
    end
    State.lifecycle.phase = phase
    return true
end
local function recordTransition(source, fromState, toState, reason)
    State.diagnostics.lastTransition = {
        source = tostring(source),
        from = tostring(fromState),
        to = tostring(toState),
        reason = tostring(reason or ""),
    }
    State.diagnostics.lastTransitionAt = os.clock()
    table.insert(State.diagnostics.transitions, State.diagnostics.lastTransition)
    if #State.diagnostics.transitions > MAX_DIAGNOSTIC_ENTRIES then
        table.remove(State.diagnostics.transitions, 1)
    end
    updateNamespace()
end
local function recordError(source, message)
    State.diagnostics.lastError = {
        source = tostring(source),
        message = tostring(message),
        at = os.clock(),
    }
    table.insert(State.diagnostics.errors, State.diagnostics.lastError)
    if #State.diagnostics.errors > MAX_DIAGNOSTIC_ENTRIES then
        table.remove(State.diagnostics.errors, 1)
    end
    updateNamespace()
end

-- filesystem
local function ensureDataFolder()
    if type(makefolder) ~= "function" or type(isfolder) ~= "function" then
        return false, "APIs de pasta do executor indisponíveis"
    end
    local folderOk, folderExists = pcall(isfolder, DATA_FOLDER)
    if not folderOk then
        return false, tostring(folderExists)
    end
    if not folderExists then
        local makeOk, makeError = pcall(makefolder, DATA_FOLDER)
        if not makeOk then
            return false, tostring(makeError or ("falha ao criar " .. DATA_FOLDER))
        end
    end
    return true, DATA_FOLDER
end
function Utils.ensureDataFolder()
    return ensureDataFolder()
end

-- lifecycle
function Utils.start()
    local previousPhase = State.lifecycle.phase
    State.lifecycle.generation = State.lifecycle.generation + 1
    State.lifecycle.startedAt = os.clock()
    State.lifecycle.stoppedAt = 0
    State.active = true
    setLifecyclePhase("starting")
    recordTransition("Utils", previousPhase, "starting", "start")
    if _G.ExodusOnBurst == nil then
        _G.ExodusOnBurst = function() end
    end
    return Utils.getStateSnapshot()
end
function Utils.stop()
    local previousPhase = State.lifecycle.phase
    State.active = false
    State.manualSpamActive = false
    State.autoSpamActive = false
    DiagnosticsModules = {}
    State.lifecycle.stoppedAt = os.clock()
    setLifecyclePhase("stopped")
    recordTransition("Utils", previousPhase, "stopped", "stop")
    if type(_G.ExodusUICleanup) == "function" then
        pcall(_G.ExodusUICleanup)
    end
    disconnectAll(State.characterConnections)
    disconnectAll(State.connections)
    _G.ExodusOnBurst = function() end
    if type(_G.Exodus) == "table" then
        _G.Exodus.Started = false
        _G.Exodus.UIReady = false
        _G.Exodus.Runtime = nil
        _G.Exodus.UI = nil
        if type(_G.Exodus.RemoteHooks) == "table" then
            _G.Exodus.RemoteHooks.register = nil
        end
        if type(_G.Exodus.AutoParryHitbox) == "table" then
            local connection = _G.Exodus.AutoParryHitbox.connection
            if connection then
                pcall(connection.Disconnect, connection)
            end
            _G.Exodus.AutoParryHitbox.connection = nil
            _G.Exodus.AutoParryHitbox.handler = nil
        end
    end
    updateNamespace()
end

-- state api
function Utils.isActive()
    return State.active == true
end
function Utils.getConfig()
    return State.config
end
function Utils.getConfigSnapshot()
    return copyMap(State.config)
end
function Utils.getModuleURLsSnapshot()
    return copyMap(State.moduleURLs)
end
function Utils.setDiagnosticsModules(modules)
    if type(modules) ~= "table" then
        return false
    end
    DiagnosticsModules = copyMap(modules)
    updateNamespace()
    return true
end
function Utils.getDiagnostics()
    return {
        schema = API_VERSION,
        generatedAt = os.clock(),
        lastError = State.diagnostics.lastError and copyMap(State.diagnostics.lastError) or nil,
        lastTransition = State.diagnostics.lastTransition
            and copyMap(State.diagnostics.lastTransition)
            or nil,
        lastTransitionAt = State.diagnostics.lastTransitionAt,
        errors = copyList(State.diagnostics.errors),
        transitions = copyList(State.diagnostics.transitions),
        lifecycle = Utils.getLifecycle(),
        runtime = {
            active = State.active,
            manualSpamActive = State.manualSpamActive,
            autoSpamActive = State.autoSpamActive,
        },
        modules = getModuleStatuses(),
    }
end
function Utils.getLifecycle()
    local snapshot = copyMap(State.lifecycle)
    snapshot.schema = API_VERSION
    snapshot.generatedAt = os.clock()
    return snapshot
end
function Utils.getStateSnapshot()
    return {
        schema = API_VERSION,
        generatedAt = os.clock(),
        active = State.active,
        manualSpamActive = State.manualSpamActive,
        autoSpamActive = State.autoSpamActive,
        lifecycle = copyMap(State.lifecycle),
        config = copyMap(State.config),
        moduleURLs = copyMap(State.moduleURLs),
        connectionCounts = {
            global = #State.connections,
            character = #State.characterConnections,
        },
    }
end
function Utils.setLifecyclePhase(phase)
    local previous = State.lifecycle.phase
    local changed = setLifecyclePhase(phase)
    if changed and previous ~= phase then
        recordTransition("Lifecycle", previous, phase, "phase_change")
    end
    return changed
end
function Utils.recordTransition(source, fromState, toState, reason)
    recordTransition(source, fromState, toState, reason)
end
function Utils.recordError(source, message)
    recordError(source, message)
end
function Utils.isManualSpamActive()
    return State.manualSpamActive == true
end
function Utils.isSpamActive()
    return State.manualSpamActive == true or State.autoSpamActive == true
end
function Utils.setAutoSpamActive(value)
    local nextValue = value == true
    if State.autoSpamActive == nextValue then
        return
    end
    local previous = State.autoSpamActive
    State.autoSpamActive = nextValue
    recordTransition(
        "AutoClash",
        previous and "active" or "inactive",
        nextValue and "active" or "inactive",
        "automatic_toggle"
    )
end
function Utils.setManualSpamActive(value)
    local nextValue = value == true
    if State.manualSpamActive == nextValue then
        return
    end
    local previous = State.manualSpamActive
    State.manualSpamActive = nextValue
    recordTransition(
        "Spam",
        previous and "active" or "inactive",
        nextValue and "active" or "inactive",
        "manual_toggle"
    )
end
function Utils.isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value < math.huge
        and value > -math.huge
end
function Utils.normalizeSpamRate(value, fallback)
    local rate = tonumber(value)
    if not Utils.isFiniteNumber(rate) then
        rate = tonumber(fallback)
    end
    if not Utils.isFiniteNumber(rate) then
        rate = SPAM_RATE_MIN
    end
    return math.clamp(rate, SPAM_RATE_MIN, SPAM_RATE_MAX)
end

-- config api
function Utils.setConfig(config)
    if type(config) ~= "table" then
        return false
    end
    local normalized = {}
    for key, value in pairs(config) do
        if not isValidConfigValue(key, value) then
            if type(Utils.recordError) == "function" then
                Utils.recordError("Config", "valor inválido para " .. tostring(key))
            end
            return false
        end
        if key == "CPS" or key == "CPF" then
            normalized[key] = Utils.normalizeSpamRate(value, State.config[key])
        else
            normalized[key] = value
        end
    end
    for key, value in pairs(normalized) do
        State.config[key] = value
    end
    updateNamespace()
    return true
end
function Utils.setModuleURLs(urls)
    if type(urls) ~= "table" then
        return false
    end
    for key, value in pairs(urls) do
        State.moduleURLs[key] = value
    end
    updateNamespace()
    return true
end

-- connection api
function Utils.trackGlobal(connection)
    return track(State.connections, connection)
end
function Utils.untrackGlobal(connection)
    return untrack(State.connections, connection)
end
function Utils.trackCharacter(connection)
    return track(State.characterConnections, connection)
end
function Utils.untrackCharacter(connection)
    return untrack(State.characterConnections, connection)
end
function Utils.disconnectCharacterConnections()
    disconnectAll(State.characterConnections)
end

-- services api
function Utils.getPlayers()
    return PlayersService
end
function Utils.getReplicatedStorage()
    return ReplicatedStorageService
end
function Utils.getRunService()
    return RunServiceService
end
function Utils.getWorkspace()
    return WorkspaceService
end
function Utils.getLocalPlayer()
    return PlayersService.LocalPlayer
end
function Utils.now()
    return os.clock()
end

-- metadata api
function Utils.name()
    return SCRIPT_NAME
end
function Utils.version()
    return SCRIPT_VERSION
end
function Utils.apiVersion()
    return API_VERSION
end
function Utils.author()
    return SCRIPT_AUTHOR
end

-- logging api
function Utils.log(level, message)
    local text = ("[%s] %s"):format(INTERNAL_NAME, tostring(message))
    if level == "warn" then
        warn(text)
    else
        print(text)
    end
end
function Utils.info(message)
    Utils.log("info", message)
end
function Utils.warn(message)
    Utils.log("warn", message)
end
_G.ExodusStop = Utils.stop

return Utils
