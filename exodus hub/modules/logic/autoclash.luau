-- [[ Auto Clash ]]

local AutoClash = {}

local AutoParry
local GameInfo
local Spam
local Utils

-- tuning
local Tuning = {
    -- activation / deactivation
    ACTIVATION_RADIUS_MULT = 1.30,
    DEACTIVATION_RADIUS_MULT = 1.05,

    -- minimum ball speed
    MIN_BALL_SPEED = 5,

    -- approaching speed
    MIN_APPROACHING_SPEED = 1,
    STRONG_APPROACHING_SPEED = 8,

    -- target return
    SPD_LOW = 60,
    SPD_HIGH = 200,
    TARGET_RETURN_MAX_LO = 0.230,
    TARGET_RETURN_MIN_HI = 0.140,

    -- away detection
    DOT_AWAY_WINDOW_MULT = 1.4,
    DOT_AWAY_EMA_ALPHA = 0.15,
    DOT_AWAY_THRESHOLD = 0,

    -- safety
    MAX_SNAPSHOT_AGE = 0.25,
}

-- state
local Runtime = {
    generation = 0,

    bound = false,
    active = false,
    phase = "detached",

    lastActivatedAt = 0,
    lastDeactivatedAt = 0,

    parryRadius = 0,
    activationRadius = 0,
    deactivationRadius = 0,

    connections = {},

    lastTarget = -1,

    boundCharacter = nil,
    boundRoot = nil,

    localUserId = 0,

    -- target history
    wasMyTarget = false,
    lastMyTargetAt = 0,
    lastNotMyTargetAt = 0,

    -- motion
    dotEma = 0,
    dotAwaySince = 0,
    lastSpeed = 0,
    lastApproachingSpeed = 0,

    -- diagnostics
    lastReason = nil,
}

-- compatibility only.
-- AutoClash does NOT require external gates anymore.
local ActivationGates = {}
local DeactivationGates = {}

-- helpers
local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value < math.huge
        and value > -math.huge
end

local function setPhase(phase, reason)
    reason = tostring(reason or "")

    if Runtime.phase == phase then
        Runtime.lastReason = reason
        return
    end

    local previous = Runtime.phase
    Runtime.phase = phase
    Runtime.lastReason = reason

    if Utils and type(Utils.recordTransition) == "function" then
        Utils.recordTransition(
            "AutoClash",
            previous,
            phase,
            reason
        )
    end
end

local function disconnectConnections()
    for index = #Runtime.connections, 1, -1 do
        local connection = Runtime.connections[index]
        Runtime.connections[index] = nil

        if connection then
            if Utils and type(Utils.untrackCharacter) == "function" then
                pcall(Utils.untrackCharacter, connection)
            end

            if type(connection.Disconnect) == "function" then
                pcall(connection.Disconnect, connection)
            end
        end
    end
end

local function resetMotionState()
    Runtime.dotEma = 0
    Runtime.dotAwaySince = 0
    Runtime.lastSpeed = 0
    Runtime.lastApproachingSpeed = 0
end

local function resetTargetState()
    Runtime.wasMyTarget = false
    Runtime.lastMyTargetAt = 0
    Runtime.lastNotMyTargetAt = 0
end

local function getParryRadius(speed, time)
    if not AutoParry
        or type(AutoParry.getParryRadius) ~= "function"
    then
        return 0
    end

    local ok, radius = pcall(
        AutoParry.getParryRadius,
        speed,
        time
    )

    if not ok or not finiteNumber(radius) then
        return 0
    end

    return math.max(0, radius)
end

local function getTargetReturnWindow(speed)
    local speedRatio = math.clamp(
        (speed - Tuning.SPD_LOW)
            / (Tuning.SPD_HIGH - Tuning.SPD_LOW),
        0,
        1
    )

    return Tuning.TARGET_RETURN_MAX_LO
        - (
            Tuning.TARGET_RETURN_MAX_LO
            - Tuning.TARGET_RETURN_MIN_HI
        ) * speedRatio
end

local function getApproachingSpeed(snapshot, ballPosition, rootPosition)
    local approachingSpeed = snapshot.approachingSpeed

    if finiteNumber(approachingSpeed) then
        return approachingSpeed
    end

    local velocity = snapshot.velocity

    if typeof(velocity) ~= "Vector3" then
        return 0
    end

    local direction = rootPosition - ballPosition
    local magnitude = direction.Magnitude

    if magnitude <= 0.001 then
        return 0
    end

    return velocity:Dot(direction.Unit)
end

local function updateDotEma(velocity, ballPosition, rootPosition)
    if typeof(velocity) ~= "Vector3" then
        return
    end

    local toMe = rootPosition - ballPosition
    local distance = toMe.Magnitude

    if distance <= 0.001 then
        return
    end

    local direction = toMe.Unit
    local dot = velocity:Dot(direction)

    if not finiteNumber(dot) then
        return
    end

    local alpha = math.clamp(
        Tuning.DOT_AWAY_EMA_ALPHA,
        0,
        1
    )

    Runtime.dotEma =
        Runtime.dotEma * (1 - alpha)
        + dot * alpha
end

local function checkDotAway(time, distance)
    if not finiteNumber(time)
        or not finiteNumber(distance)
    then
        Runtime.dotAwaySince = 0
        return false
    end

    if distance <= Runtime.deactivationRadius then
        Runtime.dotAwaySince = 0
        return false
    end

    if Runtime.dotEma > Tuning.DOT_AWAY_THRESHOLD then
        Runtime.dotAwaySince = 0
        return false
    end

    if Runtime.dotAwaySince == 0 then
        Runtime.dotAwaySince = time
        return false
    end

    local window = getTargetReturnWindow(
        Runtime.lastSpeed
    ) * Tuning.DOT_AWAY_WINDOW_MULT

    window = math.max(0.01, window)

    return time - Runtime.dotAwaySince >= window
end

local function targetIsMe(snapshot)
    if type(snapshot) ~= "table" then
        return false
    end

    -- GameInfo already resolves the local player target.
    if snapshot.targeted == true then
        return true
    end

    local targetId = tonumber(snapshot.targetId)

    if not targetId then
        return false
    end

    local localUserId = Runtime.localUserId

    return localUserId > 0
        and targetId == localUserId
end

local function updateTargetState(isMyTarget, time)
    if isMyTarget then
        if not Runtime.wasMyTarget then
            Runtime.lastMyTargetAt = time
        end

        Runtime.wasMyTarget = true
    else
        if Runtime.wasMyTarget then
            Runtime.lastNotMyTargetAt = time
        else
            Runtime.lastNotMyTargetAt = time
        end

        Runtime.wasMyTarget = false
    end
end

local function targetRecentlyReturned(time, speed)
    if Runtime.wasMyTarget then
        return false
    end

    if Runtime.lastNotMyTargetAt <= 0 then
        return false
    end

    local window = getTargetReturnWindow(speed)

    return time - Runtime.lastNotMyTargetAt <= window
end

-- control
local function setActive(nextActive, reason)
    nextActive = nextActive == true
    reason = tostring(reason or "")

    if Runtime.active == nextActive then
        Runtime.lastReason = reason
        return
    end

    Runtime.active = nextActive
    Runtime.lastReason = reason

    local time = Utils.now()

    if nextActive then
        Runtime.lastActivatedAt = time

        if Spam
            and type(Spam.setActive) == "function"
        then
            pcall(Spam.setActive, true)
        end

        if Utils
            and type(Utils.setAutoSpamActive) == "function"
        then
            Utils.setAutoSpamActive(true)
        end

        setPhase("active", reason)
    else
        Runtime.lastDeactivatedAt = time

        if Spam
            and type(Spam.setActive) == "function"
        then
            pcall(Spam.setActive, false)
        end

        if Utils
            and type(Utils.setAutoSpamActive) == "function"
        then
            Utils.setAutoSpamActive(false)
        end

        Runtime.dotAwaySince = 0

        setPhase("idle", reason)
    end
end

-- activation logic
local function shouldActivate(
    time,
    snapshot,
    distance,
    speed,
    approachingSpeed,
    isMyTarget
)
    -- The ball must actually be moving.
    if speed < Tuning.MIN_BALL_SPEED then
        return false, "ball_too_slow"
    end

    -- Must be inside the enlarged activation radius.
    if distance > Runtime.activationRadius then
        return false, "outside_activation_radius"
    end

    -- If it is moving clearly away, do not start spamming.
    if approachingSpeed < -Tuning.MIN_APPROACHING_SPEED then
        return false, "moving_away"
    end

    -- Strongly approaching balls are sufficient by themselves.
    if approachingSpeed >= Tuning.STRONG_APPROACHING_SPEED then
        return true, "approaching"
    end

    -- Being explicitly targeted is the primary Clash condition.
    if isMyTarget then
        return true, "targeted"
    end

    -- Target transition can briefly disappear during sync changes.
    if targetRecentlyReturned(time, speed) then
        return true, "target_returned"
    end

    -- Very close balls are allowed even when approachingSpeed is
    -- temporarily unavailable/weak due to network or sync jitter.
    if distance <= Runtime.deactivationRadius
        and approachingSpeed >= Tuning.MIN_APPROACHING_SPEED
    then
        return true, "close_approach"
    end

    return false, "not_dangerous"
end

-- deactivation logic
local function shouldDeactivate(
    time,
    snapshot,
    distance,
    speed,
    approachingSpeed,
    isMyTarget
)
    if distance <= Runtime.deactivationRadius then
        return false, "inside_deactivation_radius"
    end

    -- Once the ball is outside the hysteresis radius and is
    -- demonstrably travelling away, stop immediately after the
    -- small EMA confirmation window.
    if approachingSpeed <= Tuning.DOT_AWAY_THRESHOLD then
        if checkDotAway(time, distance) then
            return true, "dot_away"
        end
    else
        Runtime.dotAwaySince = 0
    end

    -- If it is far outside and is no longer approaching,
    -- there is no reason to keep the spam active.
    if distance > Runtime.activationRadius
        and approachingSpeed <= Tuning.MIN_APPROACHING_SPEED
        and not isMyTarget
    then
        return true, "no_longer_dangerous"
    end

    -- A very old snapshot should not keep an automatic spam state alive.
    if finiteNumber(snapshot.generatedAt) then
        local age = time - snapshot.generatedAt

        if age > Tuning.MAX_SNAPSHOT_AGE then
            return true, "snapshot_stale"
        end
    end

    return false, "still_active"
end

-- main
local function evaluateClash(time, snapshot)
    local root = Runtime.boundRoot

    if not (root and root.Parent) then
        setActive(false, "character_dead")
        setPhase("detached", "character_missing")
        return
    end

    if type(snapshot) ~= "table" then
        setActive(false, "snapshot_missing")
        setPhase("waiting", "snapshot_missing")
        return
    end

    local ball = snapshot.ball

    if not (ball and ball.Parent) then
        setActive(false, "ball_gone")
        setPhase("waiting", "ball_gone")
        return
    end

    local ballPosition = snapshot.position

    if typeof(ballPosition) ~= "Vector3" then
        setActive(false, "position_unavailable")
        setPhase("waiting", "position_unavailable")
        return
    end

    local speed = tonumber(snapshot.speed) or 0

    if speed < Tuning.MIN_BALL_SPEED then
        Runtime.lastSpeed = speed
        setActive(false, "ball_too_slow")
        setPhase("waiting", "ball_too_slow")
        return
    end

    local rootPosition

    local ok, result = pcall(function()
        return root.Position
    end)

    if not ok or typeof(result) ~= "Vector3" then
        setActive(false, "root_position_unavailable")
        setPhase("waiting", "root_position_unavailable")
        return
    end

    rootPosition = result

    local parryRadius = getParryRadius(speed, time)

    Runtime.parryRadius = parryRadius

    if parryRadius <= 0 then
        Runtime.activationRadius = 0
        Runtime.deactivationRadius = 0

        setActive(false, "parry_radius_zero")
        setPhase("waiting", "parry_radius_zero")
        return
    end

    Runtime.activationRadius =
        parryRadius * Tuning.ACTIVATION_RADIUS_MULT

    Runtime.deactivationRadius =
        parryRadius * Tuning.DEACTIVATION_RADIUS_MULT

    local distance =
        (rootPosition - ballPosition).Magnitude

    local approachingSpeed =
        getApproachingSpeed(
            snapshot,
            ballPosition,
            rootPosition
        )

    Runtime.lastSpeed = speed
    Runtime.lastApproachingSpeed = approachingSpeed

    updateDotEma(
        snapshot.velocity,
        ballPosition,
        rootPosition
    )

    local isMyTarget = targetIsMe(snapshot)

    updateTargetState(isMyTarget, time)

    if Runtime.active then
        local deactivate, reason = shouldDeactivate(
            time,
            snapshot,
            distance,
            speed,
            approachingSpeed,
            isMyTarget
        )

        if deactivate then
            setActive(false, reason)
        else
            setPhase("active", reason)
        end

        return
    end

    local activate, reason = shouldActivate(
        time,
        snapshot,
        distance,
        speed,
        approachingSpeed,
        isMyTarget
    )

    if activate then
        setActive(true, reason)
        return
    end

    setPhase("waiting", reason)
end

-- character runtime
local function bindCharacter(character)
    Runtime.generation =
        Runtime.generation + 1

    local generation = Runtime.generation

    setActive(false, "rebind_start")
    setPhase("detached", "rebind_start")

    disconnectConnections()

    Runtime.bound = false
    Runtime.boundCharacter = nil
    Runtime.boundRoot = nil

    Runtime.parryRadius = 0
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0

    resetMotionState()
    resetTargetState()

    if not (character and character.Parent) then
        return false
    end

    local root =
        character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild(
            "HumanoidRootPart",
            1
        )

    if generation ~= Runtime.generation
        or not (root and root.Parent)
    then
        return false
    end

    Runtime.boundCharacter = character
    Runtime.boundRoot = root

    local heartbeatConnection =
        Utils.getRunService().Heartbeat:Connect(function()
            if generation ~= Runtime.generation then
                return
            end

            if not (character.Parent and root.Parent) then
                setActive(false, "character_missing")
                return
            end

            -- Manual spam has priority over AutoClash.
            if Utils.isManualSpamActive() then
                if Runtime.active then
                    setActive(false, "manual_spam")
                end

                return
            end

            if not Utils.isActive() then
                setActive(false, "hub_inactive")
                return
            end

            local config = Utils.getConfig()

            if type(config) ~= "table"
                or config.AutoClash ~= true
            then
                setActive(false, "config_disabled")
                return
            end

            local time = Utils.now()

            local snapshot =
                GameInfo.getSnapshot(
                    Runtime.lastTarget,
                    time
                )

            if not GameInfo.isSnapshotValid(
                snapshot,
                time
            )
            then
                setActive(false, "snapshot_invalid")
                setPhase("waiting", "snapshot_invalid")
                return
            end

            if type(snapshot.targetId) == "number" then
                Runtime.lastTarget = snapshot.targetId
            elseif type(snapshot.targetId) == "string" then
                local parsed =
                    tonumber(snapshot.targetId)

                if parsed then
                    Runtime.lastTarget = parsed
                end
            elseif type(snapshot.lastTarget) == "number" then
                Runtime.lastTarget = snapshot.lastTarget
            end

            evaluateClash(
                time,
                snapshot
            )
        end)

    Runtime.connections[
        #Runtime.connections + 1
    ] = heartbeatConnection

    Utils.trackCharacter(
        heartbeatConnection
    )

    local ancestryConnection =
        character.AncestryChanged:Connect(
            function(_, parent)
                if not parent
                    and generation == Runtime.generation
                then
                    Runtime.generation =
                        Runtime.generation + 1

                    setActive(
                        false,
                        "character_removed"
                    )

                    Runtime.bound = false
                    Runtime.boundCharacter = nil
                    Runtime.boundRoot = nil
                end
            end
        )

    Runtime.connections[
        #Runtime.connections + 1
    ] = ancestryConnection

    Utils.trackCharacter(
        ancestryConnection
    )

    Runtime.bound = true

    setPhase(
        "waiting",
        "character_bound"
    )

    return true
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table"
        or type(deps.AutoParry) ~= "table"
        or type(deps.AutoParry.getParryRadius) ~= "function"
        or type(deps.GameInfo) ~= "table"
        or type(deps.GameInfo.getSnapshot) ~= "function"
        or type(deps.GameInfo.isSnapshotValid) ~= "function"
        or type(deps.Spam) ~= "table"
        or type(deps.Spam.setActive) ~= "function"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.now) ~= "function"
        or type(deps.Utils.apiVersion) ~= "function"
        or type(deps.Utils.getConfig) ~= "function"
        or type(deps.Utils.getRunService) ~= "function"
        or type(deps.Utils.trackCharacter) ~= "function"
        or type(deps.Utils.untrackCharacter) ~= "function"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.isManualSpamActive) ~= "function"
        or type(deps.Utils.recordTransition) ~= "function"
    then
        return false
    end

    AutoParry = deps.AutoParry
    GameInfo = deps.GameInfo
    Spam = deps.Spam
    Utils = deps.Utils

    Runtime.generation = 0
    Runtime.bound = false
    Runtime.active = false
    Runtime.phase = "detached"

    Runtime.lastActivatedAt = 0
    Runtime.lastDeactivatedAt = 0

    Runtime.parryRadius = 0
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0

    Runtime.connections = {}

    Runtime.lastTarget = -1

    Runtime.boundCharacter = nil
    Runtime.boundRoot = nil

    Runtime.localUserId = 0

    Runtime.wasMyTarget = false
    Runtime.lastMyTargetAt = 0
    Runtime.lastNotMyTargetAt = 0

    resetMotionState()

    Runtime.lastReason = nil

    local player =
        type(Utils.getLocalPlayer) == "function"
        and Utils.getLocalPlayer()
        or nil

    if player then
        Runtime.localUserId =
            tonumber(player.UserId) or 0
    end

    return true
end

function AutoClash.bindCharacter(character)
    return bindCharacter(character)
end

function AutoClash.detachCharacter()
    Runtime.generation =
        Runtime.generation + 1

    setActive(false, "detach")

    disconnectConnections()

    Runtime.bound = false
    Runtime.boundCharacter = nil
    Runtime.boundRoot = nil

    Runtime.parryRadius = 0
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0

    resetMotionState()
    resetTargetState()

    setPhase("detached", "detach")
end

function AutoClash.teardown()
    Runtime.generation =
        Runtime.generation + 1

    setActive(false, "teardown")

    disconnectConnections()

    Runtime.bound = false
    Runtime.boundCharacter = nil
    Runtime.boundRoot = nil

    Runtime.parryRadius = 0
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0

    resetMotionState()
    resetTargetState()

    AutoParry = nil
    GameInfo = nil
    Spam = nil
    Utils = nil

    Runtime.phase = "detached"
end

function AutoClash.onBallSync(data)
    if type(data) ~= "table" then
        return
    end

    local target =
        data.TargetPlayerID

    if target ~= nil then
        local parsed = tonumber(target)

        if parsed then
            Runtime.lastTarget = parsed
        end
    end
end

-- Kept for API compatibility.
-- The AutoClash itself no longer depends on external gates.
function AutoClash.addActivationGate(fn)
    if type(fn) ~= "function" then
        return false
    end

    ActivationGates[
        #ActivationGates + 1
    ] = fn

    return true
end

function AutoClash.addDeactivationGate(fn)
    if type(fn) ~= "function" then
        return false
    end

    DeactivationGates[
        #DeactivationGates + 1
    ] = fn

    return true
end

function AutoClash.clearGates()
    ActivationGates = {}
    DeactivationGates = {}
end

function AutoClash.isActive()
    return Runtime.active == true
end

function AutoClash.getStatus()
    local schema =
        Utils
        and type(Utils.apiVersion) == "function"
        and Utils.apiVersion()
        or 1

    return {
        schema = schema,

        phase = Runtime.phase,
        reason = Runtime.lastReason,

        bound = Runtime.bound == true,
        active = Runtime.active == true,

        parryRadius = Runtime.parryRadius,
        activationRadius = Runtime.activationRadius,
        deactivationRadius = Runtime.deactivationRadius,

        lastActivatedAt =
            Runtime.lastActivatedAt,

        lastDeactivatedAt =
            Runtime.lastDeactivatedAt,

        localUserId =
            Runtime.localUserId,

        lastTarget =
            Runtime.lastTarget,

        wasMyTarget =
            Runtime.wasMyTarget,

        lastSpeed =
            Runtime.lastSpeed,

        lastApproachingSpeed =
            Runtime.lastApproachingSpeed,

        dotEma =
            Runtime.dotEma,

        activationGateCount =
            #ActivationGates,

        deactivationGateCount =
            #DeactivationGates,
    }
end

return AutoClash