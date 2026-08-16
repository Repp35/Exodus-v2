-- [[ Utils ]]

local Utils = {}

-- services
local PlayersService = game:GetService("Players")
local ReplicatedStorageService = game:GetService("ReplicatedStorage")
local RunServiceService = game:GetService("RunService")

-- metadata
local SCRIPT_VERSION = "25.0"
local SCRIPT_NAME = "Exodus Hub"
local INTERNAL_NAME = "Exodus"
local SCRIPT_AUTHOR = "ppzudo"

-- limits
local SPAM_RATE_MIN = 0
local SPAM_RATE_MAX = 5000000000

-- state
local State = {
    active = false,
    connections = {},
    characterConnections = {},
    config = {},
    moduleURLs = {},
    manualSpamActive = false,
    autoSpamActive = false,
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

local function updateNamespace()
    local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}

    namespace.Name = SCRIPT_NAME
    namespace.InternalName = INTERNAL_NAME
    namespace.Version = SCRIPT_VERSION
    namespace.Author = SCRIPT_AUTHOR
    namespace.State = State
    namespace.Config = State.config
    namespace.ModuleURLs = State.moduleURLs

    _G.Exodus = namespace
end

-- lifecycle
function Utils.start()
    State.active = true
    updateNamespace()

    if _G.ExodusOnBurst == nil then
        _G.ExodusOnBurst = function() end
    end

    return State
end

function Utils.stop()
    State.active = false
    State.manualSpamActive = false
    State.autoSpamActive = false

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
end

-- state api
function Utils.isActive()
    return State.active == true
end

function Utils.getState()
    return State
end

function Utils.getConfig()
    return State.config
end

function Utils.getModuleURLs()
    return State.moduleURLs
end

function Utils.isManualSpamActive()
    return State.manualSpamActive == true
end

function Utils.isAutoSpamActive()
    return State.autoSpamActive == true
end

function Utils.isSpamActive()
    return State.manualSpamActive or State.autoSpamActive
end

function Utils.setManualSpamActive(value)
    State.manualSpamActive = value == true

    if State.manualSpamActive then
        State.autoSpamActive = false
    end
end

function Utils.setAutoSpamActive(value)
    State.autoSpamActive = value == true

    if State.autoSpamActive then
        State.manualSpamActive = false
    end
end

function Utils.normalizeSpamRate(value, fallback)
    local rate = tonumber(value)

    if not rate or rate ~= rate or rate == math.huge or rate == -math.huge then
        rate = tonumber(fallback) or SPAM_RATE_MIN
    end

    if not rate or rate ~= rate or rate == math.huge or rate == -math.huge then
        rate = SPAM_RATE_MIN
    end

    return math.clamp(rate, SPAM_RATE_MIN, SPAM_RATE_MAX)
end

-- config api
function Utils.setConfig(config)
    if type(config) ~= "table" then
        return false
    end

    for key, value in pairs(config) do
        if key == "CPS" or key == "CPF" then
            State.config[key] = Utils.normalizeSpamRate(value, State.config[key])
        else
            State.config[key] = value
        end
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

function Utils.disconnectGlobalConnections()
    disconnectAll(State.connections)
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
