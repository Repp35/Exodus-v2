local AutoFierce = {}
local utils, gameInfo, autoClash, spam, connection
local trackedAbility, startedAt, deadline, lastCooldown, used

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function reset()
    trackedAbility, startedAt, deadline, lastCooldown, used = nil, nil, nil, nil, false
end

local function getWindow(ability, player)
    if type(ability.GetDeflectionWindow) == "function" then
        local ok, value = pcall(ability.GetDeflectionWindow, ability, player)
        if ok and finite(value) and value > 0 then return value end
    end
    local sync = gameInfo.getSyncData()
    return gameInfo.getDeflectWindow(sync and sync.Speed)
end

local function imminent(ability, player, now)
    local snapshot = gameInfo.getSnapshotAt(now)
    if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported or snapshot.targetId ~= player.UserId then return false end
    local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local delta = root.Position - snapshot.position
    local distance = delta.Magnitude
    local range = player:GetAttribute("DeflectRange") or ability.DeflectDistance
    if not finite(range) or range <= 0 then return false end
    if distance <= range then return true end
    local closing = snapshot.velocity:Dot(delta) / math.max(distance, 0.001)
    if closing <= 0 then return false end
    local window = getWindow(ability, player)
    return finite(window) and window > 0 and (distance - range) / closing <= window
end

local function step()
    if not utils.isActive() or utils.getConfigValue("AutoFierceDeflect") ~= true then reset(); return end
    local ability = gameInfo.getDeflectAbility()
    local cd = ability and ability.Cooldown
    if not finite(cd) or cd <= 0 then reset(); return end
    local now = os.clock()
    local player = utils.getLocalPlayer()
    if not player then reset(); return end

    -- Deflect() starts a local cooldown; OnParried() clears it.
    -- The same deflection window used by the game decides when an unreset
    -- local cooldown can be treated as a missed parry.
    if ability ~= trackedAbility or not startedAt or (lastCooldown and cd > lastCooldown + 0.03) then
        local window = getWindow(ability, player)
        if not finite(window) or window <= 0 then reset(); return end
        trackedAbility, startedAt, deadline, used = ability, now, now + window, false
    end
    lastCooldown = cd
    if used then return end
    if finite(ability.PredictedResetUntil) and now < ability.PredictedResetUntil then return end
    if now < deadline then return end

    -- A successful parry cancels the local cooldown; a pending predicted
    -- reset or a new cooldown cycle must not trigger Fierce.
    if gameInfo.getDeflectAbility() ~= ability or not finite(ability.Cooldown)
        or ability.Cooldown <= 0 or not imminent(ability, player, now) then return end
    local fierce = gameInfo.getFierceDeflectAbility()
    if not fierce or type(fierce.IsAvailable) ~= "function"
        or type(fierce.IsOwnerAlive) ~= "function"
        or not fierce:IsOwnerAlive() or not fierce:IsAvailable(false) then return end

    utils.stopAllSpam()
    spam.resetState()
    autoClash.stopSpam()
    if gameInfo.getTargetId() ~= player.UserId or gameInfo.getDeflectAbility() ~= ability
        or not finite(ability.Cooldown) or ability.Cooldown <= 0
        or (finite(ability.PredictedResetUntil) and os.clock() < ability.PredictedResetUntil)
        or not fierce:IsOwnerAlive() or not fierce:IsAvailable(false) then return end
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
        GameInfo = { "getDeflectAbility", "getFierceDeflectAbility", "getDeflectWindow", "getSyncData", "getTargetId", "getSnapshotAt", "isSnapshotValid" },
        AutoClash = { "stopSpam" }, Spam = { "resetState" },
    },
    provides = { "setup", "teardown" },
}
return AutoFierce
