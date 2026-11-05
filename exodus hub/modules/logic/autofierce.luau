local AutoFierce = {}
local utils, gameInfo, autoClash, spam, connection
local trackedAbility, startedAt, deadline, used, lastElapsed, lastDuration, confirmationWindow

local function reset()
    trackedAbility, startedAt, deadline, used, lastElapsed, lastDuration, confirmationWindow = nil, nil, nil, false, nil, nil, nil
end
local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
local function step()
    if not utils.isActive() or utils.getConfigValue("AutoFierceDeflect") ~= true then reset(); return end
    local ability = gameInfo.getDeflectAbility()
    if not ability or not finite(ability.Cooldown) or ability.Cooldown <= 0 then reset(); return end
    local duration = ability.LastCooldown
    if not finite(duration) or duration <= 0 or ability.Cooldown > duration then reset(); return end
    local elapsed = duration - ability.Cooldown
    local now = os.clock()
    if ability ~= trackedAbility or not startedAt or (lastDuration and duration ~= lastDuration)
        or (lastElapsed and elapsed + 0.0001 < lastElapsed) then
        trackedAbility, startedAt, deadline, used, confirmationWindow = ability, now, nil, false, nil
    end
    lastElapsed, lastDuration = elapsed, duration
    if used then return end
    if not deadline then
        local sync = gameInfo.getSyncData()
        local window = gameInfo.getDeflectWindow(sync and sync.Speed)
        if not finite(window) or window <= 0 then return end
        confirmationWindow, deadline = window, startedAt + window
    end
    if finite(ability.PredictedResetUntil) then deadline = math.max(deadline, ability.PredictedResetUntil) end
    if now < deadline or elapsed < confirmationWindow then return end
    local player = utils.getLocalPlayer()
    if not player or gameInfo.getTargetId() ~= player.UserId then return end
    local fierce = gameInfo.getFierceDeflectAbility()
    if not fierce or type(fierce.IsAvailable) ~= "function" or type(fierce.IsOwnerAlive) ~= "function"
        or not fierce:IsOwnerAlive() or not fierce:IsAvailable(false) then return end
    utils.stopAllSpam()
    spam.resetState()
    autoClash.stopSpam()
    -- Stopping other controllers can change the current target or cooldown.
    if not utils.isActive() or utils.getConfigValue("AutoFierceDeflect") ~= true
        or gameInfo.getTargetId() ~= player.UserId or gameInfo.getDeflectAbility() ~= ability
        or not finite(ability.Cooldown) or ability.Cooldown <= 0
        or not finite(ability.LastCooldown) or ability.LastCooldown ~= duration
        or ability.LastCooldown - ability.Cooldown < confirmationWindow
        or gameInfo.getFierceDeflectAbility() ~= fierce or not fierce:IsOwnerAlive() or not fierce:IsAvailable(false) then return end
    used = true
    fierce:ActivateAndBlock()
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
        GameInfo = { "getDeflectAbility", "getFierceDeflectAbility", "getDeflectWindow", "getSyncData", "getTargetId" },
        AutoClash = { "stopSpam" }, Spam = { "resetState" },
    },
    provides = { "setup", "teardown" },
}
return AutoFierce
