-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
    RETURN_WIN_START = 0.100,
    RETURN_WIN_END = 0.060,
    RETURN_SPD_START = 60,
    RETURN_SPD_END = 600,
    PING_FACTOR = 0.3,
    ACTIVATION_ADDITIONAL_TIME = 0.250,
    LOST_TARGET_DEACT_FACTOR = 1.8,
    MIN_EVAL_INTERVAL = 1 / 120,
    TELEPORT_GRACE_TIME = 0.20,
}

-- runtime
local R = {
    generation = 0,
    bound = false,
    active = false,
    phase = "detached",
    boundRoot = nil,
    localUserId = nil,
    lastTarget = -1,
    lastSpeed = 0,
    parryRadius = 0,
    actRadius = 0,
    lostMeAt = 0,
    returnPending = false,
    wasMeTarget = false,
    lastEvalAt = 0,
    teleportLockUntil = 0,
    connections = {},
    lastGate = "none",
}

-- helpers
local function lerp(a, b, alpha)
    return a + (b - a) * alpha
end
local function getNow()
    return Utils and Utils.now() or os.clock()
end
local function getPing()
    if not AutoParry then
        return 0
    end
    local ok, ping = pcall(AutoParry.getPingOneWay)
    return ok and (tonumber(ping) or 0) or 0
end
local function getActivationTime()
    return T.ACTIVATION_ADDITIONAL_TIME + getPing() * T.PING_FACTOR
end
local function returnWindow(speed)
    speed = tonumber(speed) or 0
    local span = T.RETURN_SPD_END - T.RETURN_SPD_START
    local alpha = 0
    if span > 0 then
        alpha = math.clamp((speed - T.RETURN_SPD_START) / span, 0, 1)
    end
    return lerp(T.RETURN_WIN_START, T.RETURN_WIN_END, alpha) + getPing() * T.PING_FACTOR
end
local function setPhase(phase, reason)
    if R.phase == phase then
        return
    end
    local previous = R.phase
    R.phase = phase
    if Utils and type(Utils.recordTransition) == "function" then
        pcall(Utils.recordTransition, "AutoClash", previous, phase, reason)
    end
end
local function setActive(active, reason)
    active = active == true
    if R.active == active then
        return
    end
    R.active = active
    if Utils and type(Utils.setAutoSpamActive) == "function" then
        pcall(Utils.setAutoSpamActive, active)
    end
    setPhase(active and "active" or "idle", reason)
end
local function disconnectConnections()
    for i = #R.connections, 1, -1 do
        local connection = R.connections[i]
        R.connections[i] = nil
        if Utils and type(Utils.untrackCharacter) == "function" then
            pcall(Utils.untrackCharacter, connection)
        end
        pcall(function()
            connection:Disconnect()
        end)
    end
end
local function clearTargetHistory()
    R.lostMeAt = 0
    R.returnPending = false
    R.wasMeTarget = false
end
local function resetRuntime(reason)
    R.generation += 1
    if R.active then
        setActive(false, reason or "reset")
    end
    disconnectConnections()
    R.bound = false
    R.boundRoot = nil
    R.lastTarget = -1
    R.lastSpeed = 0
    R.parryRadius = 0
    R.actRadius = 0
    clearTargetHistory()
    R.lastEvalAt = 0
    R.teleportLockUntil = 0
    R.lastGate = "detached"
    setPhase("detached", reason or "reset")
end
local function isCharacterValid(character, root)
    return character and character.Parent and root and root.Parent
end
local function isBallValid(snapshot)
    return snapshot and snapshot.ball and snapshot.ball.Parent
end
local function getConfigEnabled()
    if not Utils or type(Utils.getConfig) ~= "function" then
        return false
    end
    local config = Utils.getConfig()
    return type(config) == "table" and config.AutoClash == true
end
local function isBallInsideParryRadius(snapshot)
    if not R.boundRoot or not R.boundRoot.Parent or not isBallValid(snapshot) then
        return false
    end
    local ballPosition = snapshot.ball.Position
    local rootPosition = R.boundRoot.Position
    if typeof(ballPosition) ~= "Vector3" or typeof(rootPosition) ~= "Vector3" then
        return false
    end
    return (ballPosition - rootPosition).Magnitude <= R.parryRadius
end

-- deactivation gates
local function checkDeactivationGates(t, snapshot)
    if Utils.isActive() ~= true then
        return "hub_inactive"
    end
    if not getConfigEnabled() then
        return "hub_disabled"
    end
    if Utils.isManualSpamActive() then
        return "manual_spam"
    end
    if t < R.teleportLockUntil then
        return "teleport_grace"
    end
    if R.active and R.lostMeAt > 0 and not R.wasMeTarget then
        if isBallInsideParryRadius(snapshot) then
            R.lostMeAt = 0
            R.lastGate = "target_timeout_reset"
        elseif t - R.lostMeAt >= getActivationTime() * T.LOST_TARGET_DEACT_FACTOR then
            return "target_timeout"
        end
    end
    return nil
end

-- activation gates
local function checkActivationGates(snapshot)
    if not isBallValid(snapshot) then
        R.lastGate = "invalid_ball"
        return false
    end
    if not R.boundRoot or not R.boundRoot.Parent then
        R.lastGate = "invalid_character"
        return false
    end
    if snapshot.targeted ~= true then
        R.lastGate = "target_not_me"
        return false
    end
    if not R.returnPending then
        R.lastGate = "awaiting_return"
        return false
    end
    R.returnPending = false
    R.lostMeAt = 0
    R.lastGate = "target_return"
    return true
end

-- evaluation
local function evaluateClash(t, snapshot)
    if not R.boundRoot or not R.boundRoot.Parent then
        return
    end
    if not isBallValid(snapshot) then
        return
    end
    R.lastSpeed = tonumber(snapshot.speed) or 0
    local radius = 8
    local ok, result = pcall(AutoParry.getParryRadius, R.lastSpeed, t)
    if ok and tonumber(result) then
        radius = result
    end
    R.parryRadius = radius
    R.actRadius = radius + R.lastSpeed * getActivationTime()
    if R.active then
        return
    end
    if checkActivationGates(snapshot) then
        setActive(true, "activated")
    end
end

-- character
local function bindCharacter(character)
    resetRuntime("rebind")
    if not character or not character.Parent then
        return false
    end
    local generation = R.generation
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
    if generation ~= R.generation or not root or not root.Parent then
        return false
    end
    R.boundRoot = root
    R.lastGate = "waiting_for_character"
    local heartbeat
    heartbeat = Utils.getRunService().Heartbeat:Connect(function()
        if generation ~= R.generation then
            return
        end
        if not isCharacterValid(character, root) then
            if R.active then
                setActive(false, "death")
            end
            return
        end
        local t = getNow()
        local snapshot = GameInfo.getSnapshot(R.lastTarget, t)
        if snapshot and GameInfo.isSnapshotValid(snapshot, t) then
            local targetId = snapshot.targetId
            if type(targetId) == "number" then
                R.lastTarget = targetId
            elseif type(targetId) == "string" then
                R.lastTarget = tonumber(targetId) or R.lastTarget
            end
        end
        local deactivationGate = checkDeactivationGates(t, snapshot)
        if deactivationGate then
            if R.active then
                setActive(false, deactivationGate)
            end
            if deactivationGate ~= "target_timeout_reset" then
                clearTargetHistory()
            end
            R.lastGate = deactivationGate
            return
        end
        if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
            return
        end
        R.lastEvalAt = t
        if not snapshot or not GameInfo.isSnapshotValid(snapshot, t) then
            R.lastGate = "invalid_snapshot"
            return
        end
        evaluateClash(t, snapshot)
    end)
    R.connections[#R.connections + 1] = heartbeat
    Utils.trackCharacter(heartbeat)
    local ancestry = character.AncestryChanged:Connect(function(_, parent)
        if parent or generation ~= R.generation then
            return
        end
        if R.active then
            setActive(false, "death")
        end
        resetRuntime("character_removed")
        R.lastGate = "character_removed"
    end)
    R.connections[#R.connections + 1] = ancestry
    Utils.trackCharacter(ancestry)
    R.bound = true
    setPhase("waiting", "character_bound")
    return true
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table" or not deps.AutoParry or not deps.GameInfo or not deps.Utils then
        return false
    end
    local ap = deps.AutoParry
    local gi = deps.GameInfo
    local u = deps.Utils
    local required = {
        { ap, "getParryRadius" },
        { ap, "getPingOneWay" },
        { gi, "getSnapshot" },
        { gi, "isSnapshotValid" },
        { u, "now" },
        { u, "getConfig" },
        { u, "getRunService" },
        { u, "recordTransition" },
        { u, "setAutoSpamActive" },
        { u, "trackCharacter" },
        { u, "untrackCharacter" },
        { u, "isActive" },
        { u, "isManualSpamActive" },
        { u, "getLocalPlayer" },
        { u, "apiVersion" },
    }
    for i = 1, #required do
        local object = required[i][1]
        local name = required[i][2]
        if type(object[name]) ~= "function" then
            return false
        end
    end
    if Utils then
        resetRuntime("setup")
    end
    AutoParry = ap
    GameInfo = gi
    Utils = u
    local player = Utils.getLocalPlayer()
    R.localUserId = player and player.UserId or nil
    R.generation = 0
    R.bound = false
    R.active = false
    R.phase = "detached"
    R.boundRoot = nil
    R.lastTarget = -1
    R.lastSpeed = 0
    R.parryRadius = 0
    R.actRadius = 0
    R.lostMeAt = 0
    R.returnPending = false
    R.wasMeTarget = false
    R.lastEvalAt = 0
    R.teleportLockUntil = 0
    R.connections = {}
    R.lastGate = "none"
    return true
end

-- api
function AutoClash.bindCharacter(character)
    if not Utils then
        return false
    end
    return bindCharacter(character)
end
function AutoClash.detachCharacter()
    resetRuntime("detach")
end
function AutoClash.teardown()
    resetRuntime("teardown")
    AutoParry = nil
    GameInfo = nil
    Utils = nil
end
function AutoClash.onBallSync(data)
    if type(data) ~= "table" or not Utils then
        return
    end
    local nowTime = getNow()
    if data.Teleported == true then
        R.teleportLockUntil = nowTime + T.TELEPORT_GRACE_TIME
        clearTargetHistory()
        R.lastGate = "teleport"
        if R.active then
            setActive(false, "teleport_grace")
        end
        return
    end
    local target = data.TargetPlayerID
    local targetId
    if type(target) == "number" then
        targetId = target
    elseif type(target) == "string" then
        targetId = tonumber(target)
    end
    if not targetId then
        R.lastTarget = -1
        clearTargetHistory()
        R.lastGate = "invalid_target"
        return
    end
    R.lastTarget = targetId
    if not R.localUserId then
        return
    end
    local isMe = targetId == R.localUserId
    if R.wasMeTarget and not isMe then
        R.lostMeAt = 0
        R.returnPending = false
    elseif not R.wasMeTarget and isMe then
        if R.lostMeAt > 0 then
            local elapsed = nowTime - R.lostMeAt
            if elapsed >= 0 and elapsed <= returnWindow(R.lastSpeed) then
                R.returnPending = true
            else
                R.lostMeAt = 0
                R.returnPending = false
            end
        end
    end
    R.wasMeTarget = isMe
end
function AutoClash.isActive()
    return R.active == true
end
function AutoClash.getStatus()
    return {
        schema = Utils and Utils.apiVersion() or nil,
        phase = R.phase,
        bound = R.bound == true,
        active = R.active == true,
        parryRadius = R.parryRadius,
        actRadius = R.actRadius,
        lastTarget = R.lastTarget,
        lastGate = R.lastGate,
    }
end
AutoClash.__contract = {
    requires = {
        AutoParry = "autoparry",
        GameInfo = "gameinfo",
        Utils = "utils",
    },
    onBallSync = true,
    bindCharacter = true,
}

return AutoClash