--[[ Auto Clash ]]

local AutoClash = {}
local GameInfo, Utils, AutoParry

local heartbeatConnection
local bindGeneration = 0

-- constants
local C = {
    DET_RAD_MIN = 14,
    DET_RAD_MAX = 32,
    DET_RAD_SPD_REF = 120,
    DET_DOT_EMA = 0.25,
    DET_DOT_THRESH = 0.15,
    DET_RADIUS_SLACK = 1.20,

    TARGET_RETURN_MAX_LO = 0.280,
    TARGET_RETURN_MIN_HI = 0.170,
    TARGET_RETURN_SPD_LO = 60,
    TARGET_RETURN_SPD_HI = 200,

    SYNC_PANIC_RADIUS = 22,
    SYNC_PANIC_TIMP = 0.085,
    SYNC_PANIC_MAX_AGE = 0.20,

    ACTIVE_LOCK = 0.080,
    INACTIVE_LOCK = 0.080,

    DEACTIVATE_SLACK = 1.08,
    DEACT_HOLD = 0.170,
    DEACTIVATE_OUT_TIME = 0.350,
}

-- state
local S = {
    active = false,
    activeAt = 0,
    inactiveAt = 0,

    detDotEma = 0,
    lastValidAt = 0,
    lastTarget = -999,
    wasMeTarget = false,
    lostMeAt = 0,

    syncPanicPending = false,
    syncPanicAt = 0,

    targetReturnPending = false,
    teleportLockUntil = 0,

    outOfRangeSince = 0,
}

-- helpers
local function now()
    return Utils.now()
end

local function getLocalPlayer()
    return Utils.getLocalPlayer()
end

local function getBall()
    return GameInfo.getBall()
end

local function getBallVelocity(ball)
    if not ball or not ball.Parent then
        return nil
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        return nil
    end

    return velocity
end

local function getBallSpeed(ball)
    local velocity = getBallVelocity(ball)
    return velocity and velocity.Magnitude or 0
end

local function lerpBySpeed(speed, speedLow, speedHigh, valueLow, valueHigh)
    if speedHigh <= speedLow then
        return valueLow
    end

    local alpha = math.clamp(
        (speed - speedLow) / (speedHigh - speedLow),
        0,
        1
    )

    return valueLow + (valueHigh - valueLow) * alpha
end

local function resetDetector()
    S.detDotEma = 0
end

local function activate(t)
    if S.active or t - S.inactiveAt < C.INACTIVE_LOCK then
        return false
    end

    S.active = true
    S.activeAt = t
    S.inactiveAt = 0
    S.lastValidAt = t

    S.syncPanicPending = false
    S.syncPanicAt = 0
    S.targetReturnPending = false
    S.wasMeTarget = false
    S.lostMeAt = 0
    S.outOfRangeSince = 0

    resetDetector()

    return true
end

local function deactivate(t)
    if not S.active or t - S.activeAt < C.ACTIVE_LOCK then
        return false
    end

    S.active = false
    S.activeAt = 0
    S.inactiveAt = t

    S.syncPanicPending = false
    S.syncPanicAt = 0
    S.targetReturnPending = false
    S.outOfRangeSince = 0

    resetDetector()

    return true
end

local function forceDeactivate(t)
    S.syncPanicPending = false
    S.syncPanicAt = 0
    S.targetReturnPending = false
    S.outOfRangeSince = 0

    if not S.active then
        return false
    end

    S.active = false
    S.activeAt = 0
    S.inactiveAt = t

    resetDetector()

    return true
end

local function getDetectorRadius(speed)
    local alpha = math.clamp(speed / C.DET_RAD_SPD_REF, 0, 1)

    return C.DET_RAD_MIN
        + (C.DET_RAD_MAX - C.DET_RAD_MIN) * alpha
end

local function getActivationRadius(speed, t)
    if not AutoParry
        or type(AutoParry.getActivationRadius) ~= "function"
    then
        return 0
    end

    local ok, radius = pcall(
        AutoParry.getActivationRadius,
        speed,
        t
    )

    if ok and type(radius) == "number" and radius >= 0 then
        return radius
    end

    return 0
end

local function activationMetrics(hr, ball, t)
    local velocity = getBallVelocity(ball)

    if not velocity or velocity.Magnitude <= 1 then
        return nil
    end

    local distance = (hr.Position - ball.Position).Magnitude
    local speed = velocity.Magnitude
    local parryRadius = getActivationRadius(speed, t)
    local tImp = math.max((distance - parryRadius) / speed, 0)

    return {
        distance = distance,
        speed = speed,
        parryRadius = parryRadius,
        tImp = tImp,
    }
end

local function getTargetReturnWindow(speed)
    return lerpBySpeed(
        speed,
        C.TARGET_RETURN_SPD_LO,
        C.TARGET_RETURN_SPD_HI,
        C.TARGET_RETURN_MAX_LO,
        C.TARGET_RETURN_MIN_HI
    )
end

-- physical return
local function physicalReturn(hr, ball)
    if not hr
        or not hr.Parent
        or not ball
        or not ball.Parent
    then
        resetDetector()
        return false
    end

    local velocity = getBallVelocity(ball)

    if not velocity or velocity.Magnitude <= 1 then
        resetDetector()
        return false
    end

    local offset = hr.Position - ball.Position
    local distance = offset.Magnitude

    if distance < 0.001 then
        resetDetector()
        return false
    end

    local radius = getDetectorRadius(velocity.Magnitude)

    if distance > radius * C.DET_RADIUS_SLACK then
        resetDetector()
        return false
    end

    local dot = velocity:Dot(offset.Unit)

    S.detDotEma =
        S.detDotEma * (1 - C.DET_DOT_EMA)
        + dot * C.DET_DOT_EMA

    return distance <= radius
        and S.detDotEma > C.DET_DOT_THRESH
end

-- activation
local function syncPanic(t, metrics)
    if not S.syncPanicPending or not metrics then
        return false
    end

    if t - S.syncPanicAt > C.SYNC_PANIC_MAX_AGE then
        S.syncPanicPending = false
        S.syncPanicAt = 0
        return false
    end

    if metrics.distance > C.SYNC_PANIC_RADIUS
        or metrics.distance > metrics.parryRadius
        or metrics.tImp > C.SYNC_PANIC_TIMP
    then
        return false
    end

    return "syncPanic"
end

local function targetReturn(t, metrics)
    if not S.targetReturnPending then
        return false
    end

    local elapsed = t - S.lostMeAt

    if elapsed > getTargetReturnWindow(metrics and metrics.speed or 0) then
        S.targetReturnPending = false
        S.wasMeTarget = false
        S.lostMeAt = 0
        return false
    end

    if not metrics or metrics.distance > metrics.parryRadius then
        return false
    end

    return "targetReturn"
end

local function shouldActivate(t, hr, ball)
    if not hr
        or not hr.Parent
        or not ball
        or not ball.Parent
    then
        return false
    end

    if not AutoParry.isTargeted() then
        return false
    end

    local metrics = activationMetrics(hr, ball, t)
    local physicalReturnReady = physicalReturn(hr, ball)

    if not metrics or metrics.distance > metrics.parryRadius then
        resetDetector()
        return false
    end

    return syncPanic(t, metrics)
        or targetReturn(t, metrics)
        or (physicalReturnReady and "physicalReturn" or false)
end

-- deactivation (astru-style: hold-based)
local function shouldDeactivate(t, hr, ball)
    if not hr
        or not hr.Parent
        or not ball
        or not ball.Parent
    then
        return true
    end

    if not AutoParry.isTargeted() then
        return true
    end

    local velocity = getBallVelocity(ball)

    if not velocity or velocity.Magnitude <= 1 then
        return true
    end

    local distance = (hr.Position - ball.Position).Magnitude
    local speed = velocity.Magnitude
    local parryRadius = getActivationRadius(speed, t)
    local deactRadius = parryRadius * C.DEACTIVATE_SLACK

    if distance <= deactRadius then
        return false
    end

    -- saiu do range: só desativa se passou DEACT_HOLD desde a última vez válido
    local lastValid = S.lastValidAt > 0 and S.lastValidAt or S.activeAt
    return (t - lastValid) >= C.DEACT_HOLD
end

local function evaluate(t, hr, ball, config)
    if not config
        or config.AutoClash == false
        or Utils.isManualSpamActive()
    then
        forceDeactivate(t)
        return
    end

    if GameInfo.isGrace()
        or not hr
        or not hr.Parent
        or not ball
        or not ball.Parent
    then
        forceDeactivate(t)
        return
    end

    if t < S.teleportLockUntil then
        forceDeactivate(t)
        return
    end

    if S.active then
        -- renova lastValidAt enquanto tudo OK (astru-style)
        if AutoParry.isTargeted() then
            local velocity = getBallVelocity(ball)

            if velocity and velocity.Magnitude > 1 then
                local distance = (hr.Position - ball.Position).Magnitude
                local parryRadius = getActivationRadius(velocity.Magnitude, t)
                local deactRadius = parryRadius * C.DEACTIVATE_SLACK

                if distance <= deactRadius then
                    S.lastValidAt = t
                end
            end
        end

        if shouldDeactivate(t, hr, ball) then
            deactivate(t)
        end

        return
    end

    if shouldActivate(t, hr, ball) then
        activate(t)
    end
end

-- target
local function onTarget(newTarget, t)
    if type(newTarget) ~= "number" then
        return
    end

    local player = getLocalPlayer()
    local previousTarget = S.lastTarget
    local userId = player and player.UserId

    if not userId then
        return
    end

    S.lastTarget = newTarget

    local getState = AutoParry.getState

    if type(getState) == "function" then
        local state = getState()

        if type(state) == "table" then
            state.armed = newTarget == userId
        end
    end

    local isMe = newTarget == userId
    local wasMe = previousTarget == userId

    if wasMe and not isMe then
        S.wasMeTarget = true
        S.lostMeAt = t
        S.syncPanicPending = false
        S.syncPanicAt = 0
        S.targetReturnPending = false
        return
    end

    if not isMe or wasMe then
        return
    end

    if S.wasMeTarget then
        S.targetReturnPending = true
        S.syncPanicPending = false
        S.syncPanicAt = 0
    else
        S.syncPanicPending = true
        S.syncPanicAt = t
        S.targetReturnPending = false
    end
end

-- teleport
local function onTeleport()
    local t = now()

    S.syncPanicPending = false
    S.syncPanicAt = 0
    S.targetReturnPending = false
    S.outOfRangeSince = 0
    S.teleportLockUntil = t + 0.5

    forceDeactivate(t)
end

-- lifecycle
local function disconnectHeartbeat()
    local connection = heartbeatConnection

    if not connection then
        return
    end

    heartbeatConnection = nil

    if Utils then
        Utils.untrackCharacter(connection)
    end

    pcall(function()
        connection:Disconnect()
    end)
end

local function bindCharacter(character)
    bindGeneration = bindGeneration + 1

    local currentGeneration = bindGeneration

    disconnectHeartbeat()

    if not character or not character.Parent then
        return false
    end

    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)

    if not root or not root.Parent then
        return false
    end

    heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function()
        if currentGeneration ~= bindGeneration
            or not Utils.isActive()
        then
            return
        end

        if not character.Parent or not root.Parent then
            forceDeactivate(now())
            return
        end

        local t = now()

        evaluate(
            t,
            root,
            GameInfo.getBall(),
            Utils.getConfig()
        )
    end)

    Utils.trackCharacter(heartbeatConnection)

    return true
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table"
        or not deps.GameInfo
        or not deps.Utils
        or not deps.AutoParry
    then
        return false
    end

    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoParry = deps.AutoParry

    AutoClash.resetState()

    Utils.setOnClashOn(function()
        return S.active
    end)

    return true
end

function AutoClash.bindCharacter(character)
    return bindCharacter(character)
end

-- public
function AutoClash.clashOn()
    return S.active
end

function AutoClash.onBallSync(data)
    if type(data) ~= "table" then
        return
    end

    if data.Teleported == true then
        onTeleport()
        return
    end

    onTarget(
        data.TargetPlayerID or -999,
        now()
    )
end

function AutoClash.resetState()
    bindGeneration = bindGeneration + 1

    disconnectHeartbeat()

    S.active = false
    S.activeAt = 0
    S.inactiveAt = 0

    S.detDotEma = 0
    S.lastTarget = -999
    S.wasMeTarget = false

    S.lostMeAt = 0
    S.syncPanicPending = false
    S.syncPanicAt = 0

    S.targetReturnPending = false
    S.teleportLockUntil = 0
    S.outOfRangeSince = 0
end

return AutoClash