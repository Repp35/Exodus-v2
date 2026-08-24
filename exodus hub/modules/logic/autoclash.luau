-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Spam
local Utils

-- tuning
local Tuning = {
    ACTIVATION_RADIUS_MULT = 1.30,
    DEACTIVATION_RADIUS_MULT = 1.05,
    MIN_BALL_SPEED = 5,
    SPD_LOW = 60,
    SPD_HIGH = 200,
    TARGET_RETURN_MAX_LO = 0.230,
    TARGET_RETURN_MIN_HI = 0.140,
    -- dot-away (deactivation by velocity direction)
    DOT_AWAY_WINDOW_MULT = 1.4,
    DOT_AWAY_EMA_ALPHA = 0.15,
    DOT_AWAY_THRESHOLD = 0, -- dot <= threshold counts as "away"
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
    boundRoot = nil,
    wasMyTarget = false,
    lastNotMyTargetAt = 0,
    -- dot-away state
    dotEma = 0,
    dotAwaySince = 0,
}

-- gates
local ActivationGates = {}
local DeactivationGates = {}

-- helpers
local function setPhase(phase, reason)
    if Runtime.phase == phase then
        return
    end
    local previous = Runtime.phase
    Runtime.phase = phase
    Utils.recordTransition("AutoClash", previous, phase, reason or "phase_change")
end

local function disconnectConnections()
    for index = #Runtime.connections, 1, -1 do
        local connection = Runtime.connections[index]
        Runtime.connections[index] = nil
        Utils.untrackCharacter(connection)
        connection:Disconnect()
    end
end

local function getParryRadius(speed, time)
    return AutoParry.getParryRadius(speed, time) or 0
end

local function getDotAwayWindow(speed)
    local speedRatio = math.clamp(
        (speed - Tuning.SPD_LOW) / (Tuning.SPD_HIGH - Tuning.SPD_LOW),
        0,
        1
    )
    local returnWindow = Tuning.TARGET_RETURN_MAX_LO
        - (Tuning.TARGET_RETURN_MAX_LO - Tuning.TARGET_RETURN_MIN_HI) * speedRatio
    return returnWindow * Tuning.DOT_AWAY_WINDOW_MULT
end

local function updateDotEma(velocity, ballPosition, rootPosition)
    if not velocity then
        return
    end
    local toMe = rootPosition - ballPosition
    local dist = toMe.Magnitude
    if dist <= 0 then
        return
    end
    local direction = toMe.Unit
    local dot = velocity:Dot(direction)
    local alpha = Tuning.DOT_AWAY_EMA_ALPHA
    Runtime.dotEma = Runtime.dotEma * (1 - alpha) + dot * alpha
end

local function checkDotAwayDeactivation(time, distance)
    if Runtime.dotEma <= Tuning.DOT_AWAY_THRESHOLD and distance > Runtime.deactivationRadius then
        if Runtime.dotAwaySince == 0 then
            Runtime.dotAwaySince = time
            return false
        end
        local window = getDotAwayWindow(Runtime.lastSpeed or 0)
        if time - Runtime.dotAwaySince >= window then
            return true
        end
    else
        Runtime.dotAwaySince = 0
    end
    return false
end

local function runGates(gateList, time, snapshot, ctx)
    for index = 1, #gateList do
        local gate = gateList[index]
        if type(gate) == "function" then
            local ok, result = pcall(gate, time, snapshot, ctx)
            if ok and result == true then
                return index
            end
        end
    end
end

-- control
local function setActive(nextActive, reason)
    if Runtime.active == nextActive then
        return
    end
    Runtime.active = nextActive
    local time = Utils.now()
    if nextActive then
        Runtime.lastActivatedAt = time
        Spam.setActive(true)
        setPhase("active", reason)
    else
        Runtime.lastDeactivatedAt = time
        Spam.setActive(false)
        setPhase("idle", reason)
    end
end

-- main
local function evaluateClash(time, snapshot)
    local root = Runtime.boundRoot
    if not (root and root.Parent) then
        setActive(false, "character_dead")
        return
    end
    local ball = snapshot.ball
    if not (ball and ball.Parent) then
        setActive(false, "ball_gone")
        return
    end
    local ballPosition = snapshot.position
    if not ballPosition then
        setPhase("waiting", "position_unavailable")
        return
    end

    local speed = snapshot.speed or 0
    if speed < Tuning.MIN_BALL_SPEED then
        setPhase("waiting", "ball_too_slow")
        return
    end

    local parryRadius = getParryRadius(speed, time)
    Runtime.parryRadius = parryRadius
    Runtime.activationRadius = parryRadius * Tuning.ACTIVATION_RADIUS_MULT
    Runtime.deactivationRadius = parryRadius * Tuning.DEACTIVATION_RADIUS_MULT

    local rootPosition = root.Position
    local distance = (rootPosition - ballPosition).Magnitude

    if Runtime.active then
        if distance <= Runtime.deactivationRadius then
            Runtime.dotAwaySince = 0
            return
        end
        Runtime.lastSpeed = speed
        updateDotEma(snapshot.velocity, ballPosition, rootPosition)
        if checkDotAwayDeactivation(time, distance) then
            setActive(false, "dot_away")
            return
        end
        local gateIndex = runGates(DeactivationGates, time, snapshot, {
            speed = speed,
            ball = ball,
            ballPosition = ballPosition,
            rootPosition = rootPosition,
            velocity = snapshot.velocity,
            approachingSpeed = snapshot.approachingSpeed,
            targeted = snapshot.targeted,
            targetId = snapshot.targetId,
            parryRadius = parryRadius,
            activationRadius = Runtime.activationRadius,
            deactivationRadius = Runtime.deactivationRadius,
            distance = distance,
        })
        if gateIndex then
            setActive(false, "deactivate_gate_" .. gateIndex)
        end
        return
    end

    if distance > Runtime.activationRadius then
        setPhase("waiting", "outside_activation_radius")
        return
    end

    local currentTarget = snapshot.targetId
    if type(currentTarget) ~= "number" then
        setPhase("waiting", "no_target")
        return
    end

    local targetIsMe = (currentTarget == Runtime.localUserId)
    if targetIsMe then
        if Runtime.wasMyTarget and Runtime.lastNotMyTargetAt > 0 then
            local speedRatio = math.clamp(
                (speed - Tuning.SPD_LOW) / (Tuning.SPD_HIGH - Tuning.SPD_LOW),
                0,
                1
            )
            local returnWindow = Tuning.TARGET_RETURN_MAX_LO
                - (Tuning.TARGET_RETURN_MAX_LO - Tuning.TARGET_RETURN_MIN_HI) * speedRatio
            if time - Runtime.lastNotMyTargetAt <= returnWindow then
                setActive(true, "target_returned")
                return
            end
        end
        Runtime.wasMyTarget = true
    else
        Runtime.lastNotMyTargetAt = time
    end

    local gateIndex = runGates(ActivationGates, time, snapshot, {
        speed = speed,
        ball = ball,
        ballPosition = ballPosition,
        rootPosition = rootPosition,
        velocity = snapshot.velocity,
        approachingSpeed = snapshot.approachingSpeed,
        targeted = snapshot.targeted,
        targetId = snapshot.targetId,
        parryRadius = parryRadius,
        activationRadius = Runtime.activationRadius,
        deactivationRadius = Runtime.deactivationRadius,
        distance = distance,
    })
    if gateIndex then
        setActive(true, "activate_gate_" .. gateIndex)
    else
        setPhase("waiting", "no_activation")
    end
end

-- character runtime
local function bindCharacter(character)
    Runtime.generation = Runtime.generation + 1
    local generation = Runtime.generation
    setPhase("detached", "rebind_start")
    setActive(false, "rebind_start")
    disconnectConnections()
    Runtime.parryRadius = 0
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0
    Runtime.boundRoot = nil
    Runtime.dotEma = 0
    Runtime.dotAwaySince = 0
    Runtime.lastSpeed = 0
    if not (character and character.Parent) then
        return false
    end
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)
    if generation ~= Runtime.generation or not (root and root.Parent) then
        return false
    end
    Runtime.boundRoot = root
    local heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function()
        if generation ~= Runtime.generation then
            return
        end
        if not (character.Parent and root.Parent) then
            return
        end
        if Utils.isManualSpamActive() then
            return
        end
        if not Utils.isActive() then
            setActive(false, "hub_inactive")
            return
        end
        if Utils.getConfig().AutoClash ~= true then
            setActive(false, "config_disabled")
            return
        end
        local time = Utils.now()
        local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, time)
        if not GameInfo.isSnapshotValid(snapshot, time) then
            setActive(false, "snapshot_invalid")
            return
        end
        if type(snapshot.targetId) == "number" then
            Runtime.lastTarget = snapshot.targetId
        end
        evaluateClash(time, snapshot)
    end)
    Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
    Utils.trackCharacter(heartbeatConnection)
    local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            Runtime.generation = Runtime.generation + 1
        end
    end)
    Runtime.connections[#Runtime.connections + 1] = ancestryConnection
    Utils.trackCharacter(ancestryConnection)
    Runtime.bound = true
    setPhase("waiting", "character_bound")
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
    Runtime.boundRoot = nil
    Runtime.wasMyTarget = false
    Runtime.lastNotMyTargetAt = 0
    Runtime.dotEma = 0
    Runtime.dotAwaySince = 0
    Runtime.lastSpeed = 0
    return true
end

function AutoClash.bindCharacter(character)
    return bindCharacter(character)
end

function AutoClash.detachCharacter()
    Runtime.generation = Runtime.generation + 1
    Runtime.bound = false
    Runtime.boundRoot = nil
    disconnectConnections()
    setActive(false, "detach")
end

function AutoClash.teardown()
    Runtime.boundRoot = nil
    disconnectConnections()
    setActive(false, "teardown")
    AutoParry = nil
    GameInfo = nil
    Spam = nil
    Utils = nil
end

function AutoClash.onBallSync(data)
    if type(data) ~= "table" then
        return
    end
    if type(data.TargetPlayerID) == "number" then
        Runtime.lastTarget = data.TargetPlayerID
    elseif type(data.TargetPlayerID) == "string" then
        local parsed = tonumber(data.TargetPlayerID)
        Runtime.lastTarget = (parsed ~= nil) and parsed or -1
    end
end

function AutoClash.addActivationGate(fn)
    if type(fn) ~= "function" then
        return false
    end
    ActivationGates[#ActivationGates + 1] = fn
    return true
end

function AutoClash.addDeactivationGate(fn)
    if type(fn) ~= "function" then
        return false
    end
    DeactivationGates[#DeactivationGates + 1] = fn
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
        activationGateCount = #ActivationGates,
        deactivationGateCount = #DeactivationGates,
    }
end

return AutoClash
