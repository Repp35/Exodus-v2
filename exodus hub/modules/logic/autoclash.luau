-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
    ACT_RAD_FACTOR = 1.15,
    PROX_FACTOR = 0.50,
    RETURN_WIN_LO = 0.150,
    RETURN_WIN_HI = 0.068,
    RETURN_SPD_LO = 60,
    RETURN_SPD_HI = 200,
    DET_FACTOR = 2.0,
    DEACT_FALLBACK = 1.85,
    PING_FACTOR = 0.3,
    DET_DOT_EMA = 0.35,
    DET_DOT_THRESHOLD = 0.14,
    DET_TIMEOUT = 0.8,
    MIN_EVAL_INTERVAL = 1 / 120,
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
    wasMeTarget = false,
    detPhase = "IDLE",
    detExitAt = 0,
    detMinDist = 0,
    detDotEma = 0,
    lastEvalAt = 0,
    connections = {},
    lastGate = "none",
}

-- helpers
local function lerp(speed, lo, hi, spdLo, spdHi)
    if spdHi <= spdLo then
        return lo
    end

    local alpha = math.clamp(
        (speed - spdLo) / (spdHi - spdLo),
        0,
        1
    )

    return lo + (hi - lo) * alpha
end

local function returnWindow(speed)
    local base = lerp(
        speed,
        T.RETURN_WIN_LO,
        T.RETURN_WIN_HI,
        T.RETURN_SPD_LO,
        T.RETURN_SPD_HI
    )

    return base + AutoParry.getPingOneWay() * T.PING_FACTOR
end

local function detectorWindow(speed)
    return returnWindow(speed) * T.DET_FACTOR
end

local function deactWindow(speed)
    return returnWindow(speed) * T.DEACT_FALLBACK
end

local function setPhase(phase, reason)
    if R.phase == phase then
        return
    end

    local previous = R.phase
    R.phase = phase
    pcall(Utils.recordTransition, "AutoClash", previous, phase, reason)
end

local function setActive(active, reason)
    active = active == true

    if R.active == active then
        return
    end

    R.active = active
    pcall(Utils.setAutoSpamActive, active)
    setPhase(active and "active" or "idle", reason)
end

local function disconnectConnections()
    for i = #R.connections, 1, -1 do
        local connection = R.connections[i]
        R.connections[i] = nil

        if Utils then
            pcall(Utils.untrackCharacter, connection)
        end

        pcall(function()
            connection:Disconnect()
        end)
    end
end

local function resetDetector()
    R.detPhase = "IDLE"
    R.detExitAt = 0
    R.detMinDist = 0
    R.detDotEma = 0
end

local function resetRuntime(reason)
    R.generation = R.generation + 1

    if R.active and Utils then
        setActive(false, reason or "reset")
    end

    disconnectConnections()

    R.bound = false
    R.boundRoot = nil
    R.lastTarget = -1
    R.lastSpeed = 0
    R.parryRadius = 0
    R.actRadius = 0
    R.lostMeAt = 0
    R.wasMeTarget = false
    R.lastEvalAt = 0
    R.lastGate = "detached"

    resetDetector()
    setPhase("detached", reason or "reset")
end

-- activation
local function proximityGate(snapshot)
    if not (snapshot and snapshot.targeted == true) then
        return false
    end

    if not (
        type(snapshot.approachingSpeed) == "number"
        and snapshot.approachingSpeed > 0
    ) then
        return false
    end

    local position = snapshot.position
    local root = R.boundRoot

    if not (position and root and root.Parent) then
        return false
    end

    local ok, rootPosition = pcall(function()
        return root.Position
    end)

    if not (ok and typeof(rootPosition) == "Vector3") then
        return false
    end

    return (rootPosition - position).Magnitude <= R.parryRadius * T.PROX_FACTOR
end

local function targetReturnGate(t)
    if not R.wasMeTarget or R.lostMeAt <= 0 then
        return false
    end

    local elapsed = t - R.lostMeAt
    return elapsed >= 0 and elapsed <= returnWindow(R.lastSpeed)
end

local function detectorGate(t, snapshot)
    local ball = snapshot and snapshot.ball
    local root = R.boundRoot

    if not (ball and ball.Parent and root and root.Parent) then
        resetDetector()
        return false
    end

    local ok, velocity, rootPosition, ballPosition = pcall(function()
        return ball.AssemblyLinearVelocity, root.Position, ball.Position
    end)

    if not (
        ok
        and typeof(velocity) == "Vector3"
        and typeof(rootPosition) == "Vector3"
        and typeof(ballPosition) == "Vector3"
    ) then
        resetDetector()
        return false
    end

    if velocity.Magnitude <= 1 then
        resetDetector()
        return false
    end

    local offset = rootPosition - ballPosition
    local distance = offset.Magnitude

    if distance <= 0.001 then
        resetDetector()
        return false
    end

    local rawDot = velocity:Dot(offset.Unit)

    R.detDotEma =
        R.detDotEma * (1 - T.DET_DOT_EMA)
        + rawDot * T.DET_DOT_EMA

    local approaching = R.detDotEma > T.DET_DOT_THRESHOLD

    if R.detPhase == "IDLE" then
        if approaching and distance <= R.actRadius then
            R.detPhase = "INSIDE"
            R.detMinDist = distance
        end

        return false
    end

    if R.detPhase == "INSIDE" then
        R.detMinDist = math.min(R.detMinDist, distance)

        if not approaching then
            R.detPhase = "EXITED"
            R.detExitAt = t
        end

        return false
    end

    if R.detPhase == "EXITED" then
        if t - R.detExitAt > T.DET_TIMEOUT then
            resetDetector()
            return false
        end

        local elapsed = t - R.detExitAt
        local returned =
            approaching
            and distance <= R.detMinDist + 0.5
            and distance <= R.actRadius

        if returned and elapsed <= detectorWindow(R.lastSpeed) then
            R.detPhase = "INSIDE"
            R.detMinDist = distance
            return true
        end
    end

    return false
end

local function shouldActivate(t, snapshot)
    if not (snapshot and snapshot.ball and snapshot.ball.Parent) then
        return false
    end

    if not (R.boundRoot and R.boundRoot.Parent) then
        return false
    end

    R.lastSpeed = tonumber(snapshot.speed) or 0
    R.parryRadius = AutoParry.getParryRadius(R.lastSpeed, t) or 8
    R.actRadius = R.parryRadius * T.ACT_RAD_FACTOR

    if proximityGate(snapshot) then
        R.lastGate = "proximity"
        return true
    end

    if targetReturnGate(t) then
        R.lastGate = "target_return"
        return true
    end

    if detectorGate(t, snapshot) then
        R.lastGate = "detector_return"
        return true
    end

    R.lastGate = snapshot.targeted == true
        and "awaiting_gate"
        or "target_not_me"

    return false
end

-- deactivation
local function targetDeactivationGate(t, snapshot)
    local position = snapshot and snapshot.position
    local root = R.boundRoot

    if position and root and root.Parent then
        local ok, rootPosition = pcall(function()
            return root.Position
        end)

        if ok and typeof(rootPosition) == "Vector3" then
            if (rootPosition - position).Magnitude <= R.parryRadius then
                return false
            end
        end
    end

    if R.lostMeAt <= 0 then
        return false
    end

    return t - R.lostMeAt > deactWindow(R.lastSpeed)
end

-- main evaluation
local function evaluateClash(t, snapshot)
    if not (R.boundRoot and R.boundRoot.Parent) then
        return
    end

    if not (snapshot and snapshot.ball and snapshot.ball.Parent) then
        return
    end

    if R.active then
        if targetDeactivationGate(t, snapshot) then
            setActive(false, "target_deactivated")
        end

        return
    end

    if shouldActivate(t, snapshot) then
        setActive(true, "activated")
        R.lostMeAt = 0
    end
end

-- character
local function bindCharacter(character)
    resetRuntime("rebind")

    local generation = R.generation

    if not (character and character.Parent) then
        return false
    end

    local root =
        character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)

    if not (generation == R.generation and root and root.Parent) then
        return false
    end

    R.boundRoot = root
    R.lastGate = "waiting_for_character"

    local heartbeat = Utils.getRunService().Heartbeat:Connect(function()
        if generation ~= R.generation then
            return
        end

        if not (character.Parent and root.Parent) then
            return
        end

        if Utils.isManualSpamActive() then
            if R.active then
                setActive(false, "manual_spam")
            end

            R.lostMeAt = 0
            resetDetector()
            return
        end

        if not Utils.isActive() then
            if R.active then
                setActive(false, "hub_inactive")
            end

            R.lostMeAt = 0
            resetDetector()
            return
        end

        if not Utils.getConfig().AutoClash then
            if R.active then
                setActive(false, "hub_disabled")
            end

            R.lostMeAt = 0
            resetDetector()
            return
        end

        local t = Utils.now()

        if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
            return
        end

        R.lastEvalAt = t

        local snapshot = GameInfo.getSnapshot(R.lastTarget, t)

        if not GameInfo.isSnapshotValid(snapshot, t) then
            return
        end

        if type(snapshot.targetId) == "number" then
            R.lastTarget = snapshot.targetId
        end

        evaluateClash(t, snapshot)
    end)

    R.connections[#R.connections + 1] = heartbeat
    Utils.trackCharacter(heartbeat)

    local ancestry = character.AncestryChanged:Connect(function(_, parent)
        if parent then
            return
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
    if not (
        deps
        and deps.AutoParry
        and type(deps.AutoParry.getParryRadius) == "function"
        and type(deps.AutoParry.getPingOneWay) == "function"
        and deps.GameInfo
        and type(deps.GameInfo.getSnapshot) == "function"
        and type(deps.GameInfo.isSnapshotValid) == "function"
        and deps.Utils
        and type(deps.Utils.now) == "function"
        and type(deps.Utils.getConfig) == "function"
        and type(deps.Utils.getRunService) == "function"
        and type(deps.Utils.recordTransition) == "function"
        and type(deps.Utils.setAutoSpamActive) == "function"
        and type(deps.Utils.trackCharacter) == "function"
        and type(deps.Utils.untrackCharacter) == "function"
        and type(deps.Utils.isActive) == "function"
        and type(deps.Utils.isManualSpamActive) == "function"
        and type(deps.Utils.getLocalPlayer) == "function"
        and type(deps.Utils.apiVersion) == "function"
    ) then
        return false
    end

    if Utils then
        resetRuntime("setup")
    end

    AutoParry = deps.AutoParry
    GameInfo = deps.GameInfo
    Utils = deps.Utils

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
    R.wasMeTarget = false
    R.lastEvalAt = 0
    R.connections = {}
    R.lastGate = "none"

    resetDetector()

    return true
end

function AutoClash.bindCharacter(character)
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

    if data.Teleported == true then
        R.lostMeAt = 0
        R.wasMeTarget = false
        resetDetector()

        if R.active then
            setActive(false, "teleported")
        end

        return
    end

    local target = data.TargetPlayerID

    if type(target) == "number" then
        R.lastTarget = target
    elseif type(target) == "string" then
        R.lastTarget = tonumber(target) or -1
    else
        R.lastTarget = -1
    end

    if not R.localUserId then
        return
    end

    local isMe = R.lastTarget == R.localUserId

    if not isMe and R.wasMeTarget then
        R.lostMeAt = Utils.now()
    end

    R.wasMeTarget = isMe
end

function AutoClash.isActive()
    return R.active == true
end

function AutoClash.getStatus()
    return {
        schema = Utils.apiVersion(),
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