local AutoFierce = {}
local utils, gameInfo, autoClash, spam, connection
local trackedAbility, used = nil, false

local function reset()
    trackedAbility, used = nil, false
end

local function step()
    if not utils.isActive() or utils.getConfigValue("AutoFierceDeflect") ~= true then reset(); return end
    local player = utils.getLocalPlayer()
    if not player then reset(); return end
    local ability = gameInfo.getDeflectAbility()
    if not ability then reset(); return end
    if ability ~= trackedAbility then trackedAbility, used = ability, false end

    local target = gameInfo.getTargetId()
    if target ~= player.UserId then return end
    local cooldown = gameInfo.getDeflectCooldownState()
    if not cooldown or not cooldown.active then
        used = false
        return
    end
    if used then return end

    local fierce = gameInfo.getFierceDeflectAbility()
    if not fierce or type(fierce.IsAvailable) ~= "function" or type(fierce.IsOwnerAlive) ~= "function"
        or not fierce:IsOwnerAlive() or not fierce:IsAvailable(false) then return end

    -- Validate the current target and cooldown before touching spam controllers.
    if gameInfo.getTargetId() ~= player.UserId or gameInfo.getDeflectAbility() ~= ability then return end
    used = true
    fierce:ActivateAndBlock()
    utils.stopAllSpam()
    spam.resetState()
    autoClash.stopSpam()
end
function AutoFierce.setup(deps)
    AutoFierce.teardown()
    utils, gameInfo, autoClash, spam = deps.Utils, deps.GameInfo, deps.AutoClash, deps.Spam
    local service = utils.getRunService()
    if not service or not service.Heartbeat then return false, "Heartbeat indisponível" end
    connection = service.Heartbeat:Connect(function()
        local ok, err = pcall(step)
        if not ok then utils.recordError("AutoFierce", tostring(err)) end
    end)
    utils.trackGlobal(connection)
    return true
end
function AutoFierce.teardown()
    if connection then
        if utils then utils.untrackGlobal(connection) end
        connection:Disconnect()
        connection = nil
    end
    reset()
    utils, gameInfo, autoClash, spam = nil, nil, nil, nil
end
AutoFierce.__contract = {
    requires = { Utils = "utils", GameInfo = "gameinfo", AutoClash = "autoclash", Spam = "spam" },
    requiresMethods = {
        Utils = { "isActive", "getConfigValue", "getLocalPlayer", "getRunService", "stopAllSpam", "trackGlobal", "untrackGlobal", "recordError" },
        GameInfo = { "getDeflectAbility", "getFierceDeflectAbility", "getDeflectCooldownState", "getTargetId" },
        AutoClash = { "stopSpam" }, Spam = { "resetState" },
    },
    provides = { "setup", "teardown" },
}
return AutoFierce
