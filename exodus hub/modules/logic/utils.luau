--[[ Utils ]]

-- services
local Utils = {}
local PlayersService       = game:GetService("Players")
local ReplicatedStorageSvc = game:GetService("ReplicatedStorage")
local RunServiceSvc        = game:GetService("RunService")

-- metadata
local SCRIPT_VERSION = "24.3"
local SCRIPT_NAME = "Exodus Hub"
local INTERNAL_NAME = "Exodus"
local SCRIPT_AUTHOR = "ppzudo"

-- spam limits
local SPAM_RATE_MIN = 0
local SPAM_RATE_MAX = 5000000000

-- state
local State = {
    active               = false,
    connections           = {},
    characterConnections  = {},
    config                = {},
    moduleURLs            = {},
    manualSpamActive      = false,
}

-- callbacks
local _onClashOn

-- helpers
local function disconnectAll(list)
    for i = #list, 1, -1 do
        local c = list[i]
        list[i] = nil
        if c then pcall(function() c:Disconnect() end) end
    end
end
local function track(list, connection)
    if connection and type(connection.Disconnect) == "function" then
        list[#list + 1] = connection
    end
    return connection
end
local function untrack(list, connection)
    for i = #list, 1, -1 do
        if list[i] == connection then
            table.remove(list, i)
        end
    end
end

-- lifecycle
function Utils.start()
    State.active = true
    local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
    namespace.Name = SCRIPT_NAME
    namespace.InternalName = INTERNAL_NAME
    namespace.Version = SCRIPT_VERSION
    namespace.Author = SCRIPT_AUTHOR
    namespace.State = State
    namespace.Config = State.config
    namespace.ModuleURLs = State.moduleURLs
    namespace.Started = true
    _G.Exodus = namespace
    if _G.ExodusOnBurst == nil then _G.ExodusOnBurst = function() end end
    return State
end
function Utils.stop()
    State.active = false
    if type(_G.ExodusUICleanup) == "function" then
        pcall(_G.ExodusUICleanup)
    end
    disconnectAll(State.characterConnections)
    Utils.disconnectGlobalConnections()
    State.manualSpamActive = false
    _onClashOn = nil
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
            local hitboxConnection = _G.Exodus.AutoParryHitbox.connection
            if hitboxConnection then
                pcall(function()
                    hitboxConnection:Disconnect()
                end)
            end
            _G.Exodus.AutoParryHitbox.connection = nil
            _G.Exodus.AutoParryHitbox.handler = nil
        end
    end
end

-- state api
function Utils.isActive()             return State.active end
function Utils.getState()             return State end
function Utils.getConfig()            return State.config end
function Utils.getModuleURLs()        return State.moduleURLs end
function Utils.isManualSpamActive()   return State.manualSpamActive end
function Utils.normalizeSpamRate(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        n = tonumber(fallback) or SPAM_RATE_MIN
    end
    if not n or n ~= n or n == math.huge or n == -math.huge then
        n = SPAM_RATE_MIN
    end
    return math.clamp(n, SPAM_RATE_MIN, SPAM_RATE_MAX)
end

-- config api
function Utils.setConfig(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if k == "CPS" or k == "CPF" then
            State.config[k] = Utils.normalizeSpamRate(v, State.config[k])
        else
            State.config[k] = v
        end
    end
    local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
    namespace.Config = State.config
    _G.Exodus = namespace
end
function Utils.setModuleURLs(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do State.moduleURLs[k] = v end
    local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
    namespace.ModuleURLs = State.moduleURLs
    _G.Exodus = namespace
end
function Utils.setManualSpamActive(v)
    State.manualSpamActive = v == true
end

-- connection api
function Utils.trackGlobal(c)     return track(State.connections, c) end
function Utils.untrackGlobal(c)   return untrack(State.connections, c) end
function Utils.trackCharacter(c)  return track(State.characterConnections, c) end
function Utils.untrackCharacter(c) return untrack(State.characterConnections, c) end
function Utils.disconnectGlobalConnections() disconnectAll(State.connections) end
function Utils.disconnectCharacterConnections() disconnectAll(State.characterConnections) end

-- services api
function Utils.getPlayers()           return PlayersService end
function Utils.getReplicatedStorage() return ReplicatedStorageSvc end
function Utils.getRunService()        return RunServiceSvc end
function Utils.getLocalPlayer()       return PlayersService.LocalPlayer end
function Utils.now()                  return os.clock() end

-- metadata
function Utils.name()         return SCRIPT_NAME end
function Utils.version()      return SCRIPT_VERSION end
function Utils.author()       return SCRIPT_AUTHOR end

-- logs
function Utils.log(level, message)
    local text = ("[%s] %s"):format(INTERNAL_NAME, tostring(message))
    if level == "warn" then
        warn(text)
    else
        print(text)
    end
end
function Utils.info(message) Utils.log("info", message) end
function Utils.warn(message) Utils.log("warn", message) end

-- callbacks api
function Utils.isClashActive()
    if not _onClashOn then return false end
    local ok, v = pcall(_onClashOn)
    return ok and v == true
end
function Utils.setOnClashOn(fn)
    _onClashOn = type(fn) == "function" and fn or nil
end
_G.ExodusStop = Utils.stop
return Utils
