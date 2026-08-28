-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local Tuning = {
    ACT_RAD_FACTOR = 1.40,
    TARGET_RETURN_MAX_LO = 0.149,
    TARGET_RETURN_MIN_HI = 0.081,
    PING_COMPENSATION_FACTOR = 0.3,
    DET_RETURN_FACTOR = 2.0,
    RETURN_SPD_LO = 60,
    RETURN_SPD_HI = 200,
    DET_RAD_MIN = 10,
    DET_RAD_MAX = 25,
    DET_DIST_DELTA = 0.5,
    DET_DOT_EMA = 0.35,
    DET_DOT_THRESHOLD = 0.14,
    DET_TIMEOUT = 0.8,
    DEACT_WINDOW_FACTOR = 2.2,
    DEACT_GUARD_TIME = 0.080,
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
    connections = {},
    lastTarget = -1,
    localUserId = nil,
    boundRoot = nil,
    lastTargetAt = 0,
    lastTargetId = nil,
    wasMeTarget = false,
    lostMeAt = 0,
    lastSpeed = 0,
    lastGate = "none",
    activationReturnWindow = 0,
    lastReturnAt = 0,
    detPhase = "IDLE",
    detEnterAt = 0,
    detExitAt = 0,
    detMinDist = 0,
    detDotEma = 0,
    detWasComing = false,
}

-- helpers
local function setPhase(phase, reason)
    if Runtime.phase == phase then
        return
    end
    local previous = Runtime.phase
    Runtime.phase = phase
    if Utils then
        pcall(
            Utils.recordTransition,
            "AutoClash",
            previous,
            phase,
            reason or "phase_change"
        )
    end
end

local function disconnectConnections()
    for index = #Runtime.connections, 1, -1 do
        local connection = Runtime.connections[index]
        Runtime.connections[index] = nil
        if Utils then
            pcall(Utils.untrackCharacter, connection)
        end
        if connection
            and type(connection.Disconnect) == "function"
        then
            pcall(connection.Disconnect, connection)
        end
    end
end

local function getParryRadius(speed, time)
    if not AutoParry
        or type(AutoParry.getParryRadius) ~= "function"
    then
        return 8
    end
    local ok, radius = pcall(
        AutoParry.getParryRadius,
        speed,
        time
    )
    if not ok
        or type(radius) ~= "number"
        or radius < 0
    then
        return 8
    end
    return radius
end

local function setActive(nextActive, reason)
    nextActive = nextActive == true
    if Runtime.active == nextActive then
        return
    end
    Runtime.active = nextActive
    local time = Utils.now()
    if nextActive then
        Runtime.lastActivatedAt = time
        local ok, err = pcall(
            Utils.setAutoSpamActive,
            true
        )
        if not ok then
            pcall(
                Utils.recordError,
                "AutoClash",
                "Utils.setAutoSpamActive(true): "
                    .. tostring(err)
            )
        end
        setPhase("active", reason)
    else
        Runtime.lastDeactivatedAt = time
        local ok, err = pcall(
            Utils.setAutoSpamActive,
            false
        )
        if not ok then
            pcall(
                Utils.recordError,
                "AutoClash",
                "Utils.setAutoSpamActive(false): "
                    .. tostring(err)
            )
        end
        setPhase("idle", reason)
    end
end

-- helpers lógicos do script 2 adaptados
local function lerpBySpeed(
    speed,
    valueLow,
    valueHigh
)
    if Tuning.RETURN_SPD_HI
        <= Tuning.RETURN_SPD_LO
    then
        return valueLow
    end
    local alpha = math.clamp(
        (speed - Tuning.RETURN_SPD_LO)
            / (
                Tuning.RETURN_SPD_HI
                    - Tuning.RETURN_SPD_LO
            ),
        0,
        1
    )
    return valueLow
        + (valueHigh - valueLow) * alpha
end

local function getTargetReturnWindow(speed)
    return lerpBySpeed(
        speed,
        Tuning.TARGET_RETURN_MAX_LO,
        Tuning.TARGET_RETURN_MIN_HI
    ) + AutoParry.getPingOneWay()
        * Tuning.PING_COMPENSATION_FACTOR
end

local function getDetectorReturnWindow(speed)
    return getTargetReturnWindow(speed)
        * Tuning.DET_RETURN_FACTOR
end

local function getDeactivationWindow(speed)
    return getTargetReturnWindow(speed)
        * Tuning.DEACT_WINDOW_FACTOR
end

local function getDetectorRadius(speed)
    local alpha = math.clamp(
        (speed - Tuning.RETURN_SPD_LO)
            / (
                Tuning.RETURN_SPD_HI
                    - Tuning.RETURN_SPD_LO
            ),
        0,
        1
    )
    return Tuning.DET_RAD_MIN
        + (
            Tuning.DET_RAD_MAX
                - Tuning.DET_RAD_MIN
        ) * alpha
end

local function resetDetector()
    Runtime.detPhase = "IDLE"
    Runtime.detEnterAt = 0
    Runtime.detExitAt = 0
    Runtime.detMinDist = 0
    Runtime.detDotEma = 0
    Runtime.detWasComing = false
end

-- return detector
local function tickReturnDetector(
    t,
    hr,
    ball,
    activationRadius,
    speed
)
    if not (
        hr
        and hr.Parent
        and ball
        and ball.Parent
    ) then
        resetDetector()
        return false
    end
    local velocity
    local ok = pcall(function()
        velocity = ball.AssemblyLinearVelocity
    end)
    if not ok
        or typeof(velocity) ~= "Vector3"
    then
        resetDetector()
        return false
    end
    local velocitySpeed = velocity.Magnitude
    if velocitySpeed <= 1 then
        resetDetector()
        return false
    end
    local offset = hr.Position - ball.Position
    local distance = offset.Magnitude
    if distance <= 0.001 then
        resetDetector()
        return false
    end
    local detectorRadius =
        getDetectorRadius(speed)
    local rawDot =
        velocity:Dot(offset.Unit)
    Runtime.detDotEma =
        Runtime.detDotEma
            * (1 - Tuning.DET_DOT_EMA)
            + rawDot
                * Tuning.DET_DOT_EMA
    local coming =
        Runtime.detDotEma
            > Tuning.DET_DOT_THRESHOLD
    if distance > detectorRadius * 1.2 then
        resetDetector()
        return false
    end
    if Runtime.detPhase == "EXITED"
        and t - Runtime.detExitAt
            > Tuning.DET_TIMEOUT
    then
        resetDetector()
    end
    if Runtime.detPhase == "IDLE" then
        if distance <= detectorRadius
            and coming
        then
            Runtime.detPhase = "INSIDE"
            Runtime.detEnterAt = t
            Runtime.detMinDist = distance
        end
        Runtime.detWasComing = coming
        return false
    end
    if Runtime.detPhase == "INSIDE" then
        Runtime.detMinDist =
            math.min(
                Runtime.detMinDist,
                distance
            )
        if Runtime.detWasComing
            and not coming
        then
            Runtime.detPhase = "EXITED"
            Runtime.detExitAt = t
        end
        Runtime.detWasComing = coming
        return false
    end
    if Runtime.detPhase == "EXITED" then
        local elapsed =
            t - Runtime.detExitAt
        local window =
            getDetectorReturnWindow(speed)
        local returned =
            coming
            and distance
                <= Runtime.detMinDist
                    + Tuning.DET_DIST_DELTA
        if returned then
            Runtime.detPhase = "INSIDE"
            Runtime.detEnterAt = t
            Runtime.detMinDist = distance
            if elapsed <= window
                and distance <= activationRadius
            then
                Runtime.lastReturnAt = t
                Runtime.detWasComing = coming
                return true
            end
        end
        Runtime.detWasComing = coming
    end
    return false
end

-- activation
local function shouldActivate(t, snapshot)
    if type(snapshot) ~= "table" then
        Runtime.lastGate = "snapshot_invalid"
        return false
    end
    local ball = snapshot.ball
    if not (ball and ball.Parent) then
        Runtime.lastGate = "ball_invalid"
        return false
    end
    local root = Runtime.boundRoot
    if not (root and root.Parent) then
        Runtime.lastGate = "character_invalid"
        return false
    end
    local speed =
        tonumber(snapshot.speed) or 0
    Runtime.lastSpeed = speed
    local parryRadius =
        getParryRadius(speed, t)
    Runtime.parryRadius = parryRadius
    Runtime.activationRadius =
        parryRadius
            * Tuning.ACT_RAD_FACTOR
    local isTargeted =
        snapshot.targeted == true
    if isTargeted
        and Runtime.lostMeAt > 0
    then
        local elapsed =
            t - Runtime.lostMeAt
        local window =
            getTargetReturnWindow(speed)
        if elapsed >= 0
            and elapsed <= window
        then
            Runtime.lastGate =
                "target_return"
            Runtime.activationReturnWindow =
                window
            return true
        end
    end
    if tickReturnDetector(
        t,
        root,
        ball,
        Runtime.activationRadius,
        speed
    ) then
        Runtime.lastGate =
            "detector_return"
        Runtime.activationReturnWindow =
            getDetectorReturnWindow(speed)
        return true
    end
    Runtime.lastGate =
        isTargeted
        and "awaiting_activation_gate"
        or "target_not_me"
    return false
end

-- deactivation
local function shouldDeactivate(t)
    if Runtime.lostMeAt <= 0 then
        return false
    end
    if Runtime.lostMeAt
        <= Runtime.lastActivatedAt
    then
        return false
    end
    local sinceActivation =
        t - Runtime.lastActivatedAt
    if sinceActivation
        < Tuning.DEACT_GUARD_TIME
    then
        return false
    end
    local pingCompensation =
        AutoParry.getPingOneWay()
            * Tuning.PING_COMPENSATION_FACTOR
    local sinceLeft =
        t - Runtime.lostMeAt
            + pingCompensation
    return sinceLeft
        > getDeactivationWindow(
            Runtime.lastSpeed
        )
end

-- main evaluation (com os gates do script 2 adaptados)
local function evaluateClash(time, snapshot)
    local root = Runtime.boundRoot
    if not (root and root.Parent) then
        return
    end
    local ball = snapshot.ball
    if not (ball and ball.Parent) then
        return
    end
    local speed =
        tonumber(snapshot.speed) or 0
    Runtime.lastSpeed = speed
    local parryRadius =
        getParryRadius(speed, time)
    Runtime.parryRadius =
        parryRadius
    Runtime.activationRadius =
        parryRadius
            * Tuning.ACT_RAD_FACTOR
    if Runtime.active then
        if shouldDeactivate(time) then
            setActive(
                false,
                "target_lost_timeout"
            )
        end
        return
    end
    if shouldActivate(
        time,
        snapshot
    ) then
        Runtime.lastReturnAt = time
        setActive(
            true,
            "should_activate"
        )
        Runtime.lostMeAt = 0
    end
end

-- character runtime
local function bindCharacter(character)
    Runtime.generation =
        Runtime.generation + 1
    local generation =
        Runtime.generation
    setActive(
        false,
        "rebind_start"
    )
    setPhase(
        "detached",
        "rebind_start"
    )
    disconnectConnections()
    Runtime.parryRadius = 0
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0
    Runtime.boundRoot = nil
    Runtime.lastTargetAt = 0
    Runtime.lastTargetId = nil
    Runtime.wasMeTarget = false
    Runtime.lostMeAt = 0
    Runtime.lastSpeed = 0
    Runtime.lastGate =
        "waiting_for_character"
    Runtime.activationReturnWindow = 0
    Runtime.lastReturnAt = 0
    resetDetector()
    if not (
        character
        and character.Parent
    ) then
        return false
    end
    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )
        or character:WaitForChild(
            "HumanoidRootPart",
            1
        )
    if generation ~= Runtime.generation
        or not (root and root.Parent)
    then
        return false
    end
    Runtime.boundRoot = root
    local heartbeatConnection
    heartbeatConnection =
        Utils.getRunService()
            .Heartbeat
            :Connect(function()
                if generation
                    ~= Runtime.generation
                then
                    return
                end
                local ok, err =
                    xpcall(
                        function()
                            if not (
                                character.Parent
                                and root.Parent
                            ) then
                                return
                            end
                            if Utils.isManualSpamActive() then
                                return
                            end
                            if not Utils.isActive() then
                                if Runtime.active then
                                    setActive(
                                        false,
                                        "hub_inactive"
                                    )
                                end
                                return
                            end
                            if Utils.getConfig()
                                .AutoClash
                                ~= true
                            then
                                if Runtime.active then
                                    setActive(
                                        false,
                                        "hub_disabled"
                                    )
                                end
                                return
                            end
                            local time =
                                Utils.now()
                            local snapshot =
                                GameInfo.getSnapshot(
                                    Runtime.lastTarget,
                                    time
                                )
                            if not GameInfo.isSnapshotValid(
                                snapshot,
                                time
                            ) then
                                return
                            end
                            if type(
                                snapshot.targetId
                            ) == "number"
                            then
                                Runtime.lastTarget =
                                    snapshot.targetId
                            end
                            evaluateClash(
                                time,
                                snapshot
                            )
                        end,
                        debug.traceback
                    )
                if not ok then
                    pcall(
                        Utils.recordError,
                        "AutoClash",
                        tostring(err)
                    )
                end
            end)
    Runtime.connections[
        #Runtime.connections + 1
    ] = heartbeatConnection
    Utils.trackCharacter(
        heartbeatConnection
    )
    local ancestryConnection =
        character.AncestryChanged
            :Connect(function(_, parent)
                if not parent then
                    Runtime.generation =
                        Runtime.generation + 1
                    Runtime.bound = false
                    Runtime.boundRoot = nil
                    disconnectConnections()
                    if Runtime.active then
                        setActive(
                            false,
                            "character_removed"
                        )
                    end
                end
            end)
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
        or type(deps.AutoParry.getParryRadius)
            ~= "function"
        or type(deps.AutoParry.getPingOneWay)
            ~= "function"
        or type(deps.GameInfo) ~= "table"
        or type(deps.GameInfo.getSnapshot)
            ~= "function"
        or type(deps.GameInfo.isSnapshotValid)
            ~= "function"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.now)
            ~= "function"
        or type(deps.Utils.apiVersion)
            ~= "function"
        or type(deps.Utils.getConfig)
            ~= "function"
        or type(deps.Utils.getRunService)
            ~= "function"
        or type(deps.Utils.trackCharacter)
            ~= "function"
        or type(deps.Utils.untrackCharacter)
            ~= "function"
        or type(deps.Utils.isActive)
            ~= "function"
        or type(deps.Utils.isManualSpamActive)
            ~= "function"
        or type(deps.Utils.setAutoSpamActive)
            ~= "function"
        or type(deps.Utils.recordTransition)
            ~= "function"
    then
        return false
    end
    AutoParry = deps.AutoParry
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    local player =
        Utils.getLocalPlayer()
    Runtime.localUserId =
        player
        and player.UserId
        or nil
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
    Runtime.boundRoot = nil
    Runtime.lastTargetAt = 0
    Runtime.lastTargetId = nil
    Runtime.wasMeTarget = false
    Runtime.lostMeAt = 0
    Runtime.lastSpeed = 0
    Runtime.lastGate = "none"
    Runtime.activationReturnWindow = 0
    Runtime.lastReturnAt = 0
    resetDetector()
    return true
end

function AutoClash.bindCharacter(character)
    return bindCharacter(character)
end

function AutoClash.detachCharacter()
    Runtime.generation =
        Runtime.generation + 1
    Runtime.bound = false
    Runtime.boundRoot = nil
    disconnectConnections()
    if Runtime.active then
        setActive(
            false,
            "detach"
        )
    end
end

function AutoClash.teardown()
    Runtime.generation =
        Runtime.generation + 1
    Runtime.bound = false
    Runtime.boundRoot = nil
    disconnectConnections()
    if Runtime.active then
        setActive(
            false,
            "teardown"
        )
    end
    AutoParry = nil
    GameInfo = nil
    Utils = nil
end

function AutoClash.onBallSync(data)
    if type(data) ~= "table" then
        return
    end
    local target =
        data.TargetPlayerID
    if type(target) == "number" then
        Runtime.lastTarget = target
        Runtime.lastTargetId = target
    elseif type(target) == "string" then
        local parsed =
            tonumber(target)
        Runtime.lastTarget =
            parsed or -1
        Runtime.lastTargetId =
            Runtime.lastTarget
    else
        return
    end
    local t =
        Utils.now()
    Runtime.lastTargetAt = t
    if type(Runtime.lastTargetId)
            == "number"
        and Runtime.localUserId
    then
        local isMe =
            Runtime.lastTargetId
            == Runtime.localUserId
        if isMe then
            local returned =
                Runtime.wasMeTarget == false
                and Runtime.lostMeAt > 0
            if returned then
                local speed =
                    Runtime.lastSpeed
                local window =
                    getTargetReturnWindow(
                        speed
                    )
                local elapsed =
                    t - Runtime.lostMeAt
                if elapsed >= 0
                    and elapsed <= window
                then
                    Runtime.lastReturnAt = t
                    if Runtime.active then
                        Runtime.lastGate =
                            "target_return_refresh"
                    end
                end
            end
            Runtime.wasMeTarget = true
        else
            if Runtime.wasMeTarget then
                Runtime.lostMeAt = t
            end
            Runtime.wasMeTarget = false
        end
    end
end

function AutoClash.isActive()
    return Runtime.active == true
end

function AutoClash.getStatus()
    return {
        schema = Utils.apiVersion(),
        phase = Runtime.phase,
        bound = Runtime.bound == true,
        active = Runtime.active == true,
        parryRadius = Runtime.parryRadius,
        activationRadius = Runtime.activationRadius,
        deactivationRadius = Runtime.deactivationRadius,
        lastActivatedAt = Runtime.lastActivatedAt,
        lastDeactivatedAt = Runtime.lastDeactivatedAt,
        localUserId = Runtime.localUserId,
        lastTarget = Runtime.lastTarget,
        lastGate = Runtime.lastGate,
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