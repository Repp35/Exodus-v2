-- [[ autodark ]]

local AutoDark = {}
local Utils, GameInfo
local connections = {}
local generation = 0
local DARK_SEAL_EVENT = 2.4141700243704228e76

local function disconnectAll()
    for index = #connections, 1, -1 do
        local connection = connections[index]
        connections[index] = nil
        if Utils then Utils.untrackGlobal(connection) end
        connection:Disconnect()
    end
end

local function track(connection)
    connections[#connections + 1] = connection
    Utils.trackGlobal(connection)
end

function AutoDark.sync()
    generation += 1
    disconnectAll()

    if not Utils or not GameInfo or not Utils.isActive() or Utils.getConfigValue("AutoDark") ~= true then
        return true
    end

    local players = Utils.getPlayers()
    local player = Utils.getLocalPlayer()
    local runService = Utils.getRunService()
    if not players or not player or not runService or not runService.Heartbeat then
        return false, "Players ou Heartbeat indisponível"
    end

    local current = generation
    local known = {}
    for _, member in ipairs(players:GetPlayers()) do known[member] = true end

    track(players.PlayerAdded:Connect(function(member) known[member] = true end))
    track(players.PlayerRemoving:Connect(function(member) known[member] = nil end))

    local function blocked()
        for member in pairs(known) do
            if member ~= player and member:GetAttribute("DarkSealed") == true then return true end
        end
        return false
    end

    local busy, missing, lastError, errorAt = false, false, nil, 0

    track(runService.Heartbeat:Connect(function()
        if busy or current ~= generation or not Utils.isActive() or Utils.getConfigValue("AutoDark") ~= true then
            return
        end

        if blocked() then return end
        busy = true

        local ok, err = pcall(function()
            local ability = GameInfo.getDarkSealAbility()
            if current ~= generation or not Utils.isActive() or Utils.getConfigValue("AutoDark") ~= true then return end

            if not ability then
                if not missing then
                    Utils.recordError("AutoDark", "Dark Seal não está equipada ou ainda não carregou")
                end
                missing = true
                return
            end
            missing = false

            local workspace = Utils.getWorkspace()
            local camera = workspace and workspace.CurrentCamera
            if camera and not blocked() then
                ability:SendEvent(DARK_SEAL_EVENT, camera.CFrame)
            end
        end)

        busy = false
        if not ok then
            local message, time = tostring(err), os.clock()
            if message ~= lastError or time - errorAt >= 5 then
                Utils.recordError("AutoDark", message)
                lastError, errorAt = message, time
            end
        else
            lastError = nil
        end
    end))

    return true
end

function AutoDark.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then
        return false, "dependências ausentes: Utils ou GameInfo"
    end
    Utils, GameInfo = deps.Utils, deps.GameInfo
    return AutoDark.sync()
end

function AutoDark.teardown()
    generation += 1
    disconnectAll()
    Utils, GameInfo = nil, nil
end

AutoDark.__contract = {
    requires = {Utils = "utils", GameInfo = "gameinfo"},
    requiresMethods = {
        Utils = {"getConfigValue", "getWorkspace", "getPlayers", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive", "recordError"},
        GameInfo = {"getDarkSealAbility"},
    },
    provides = {"setup", "sync", "teardown"},
}

return AutoDark
