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
    DOT_AWAY_WINDOW_MULT = 1.4,
    DOT_AWAY_EMA_ALPHA = 0.15,
    DOT_AWAY_THRESHOLD = 0,
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
    localUserId = nil,
    boundRoot = nil,
    wasMyTarget = false,
    lastNotMyTargetAt = 0,
    dotEma = 0,
    dotAwaySince = 0,
    lastSpeed = 0,
}

-- helpers
local function setPhase(phase, reason)
    if Runtime.phase == phase then
        return
    end
    local previous = Runtime.phase
    Runtime.phase = phase
    if Utils then
        pcall(Utils.recordTransition, "AutoClash", previous, phase, reason or "phase_change")
    end
end

local function disconnectConnections()
    for index = #Runtime.connections, 1, -1 do
        local connection = Runtime.connections[index]
        Runtime.connections[index] = nil
        if Utils then
            pcall(Utils.untrackCharacter, connection)
        end
        if connection and type(connection.Disconnect) == "function" then
            pcall(connection.Disconnect, connection)
        end
    end
end

local function getParryRadius(speed, time)
    if not AutoParry or type(AutoParry.getParryRadius) ~= "function" then
        return 0
    end
    local ok, radius = pcall(AutoParry.getParryRadius, speed, time)
    if not ok or type(radius) ~= "number" or radius < 0 then
        return 0
    end
    return radius
end

local function getReturnWindow(speed)
    local speedRatio = math.clamp(
        (speed - Tuning.SPD_LOW) / (Tuning.SPD_HIGH - Tuning.SPD_LOW),
        0,
        1
    )
    return Tuning.TARGET_RETURN_MAX_LO
        - (Tuning.TARGET_RETURN_MAX_LO - Tuning.TARGET_RETURN_MIN_HI) * speedRatio
end

local function updateDotEma(velocity, ballPosition, rootPosition)
    if typeof(velocity) ~= "Vector3" then
        return
    end
    local toMe = rootPosition - ballPosition
    if toMe.Magnitude <= 0.001 then
        return
    end
    local dot = velocity:Dot(toMe.Unit)
    local alpha = Tuning.DOT_AWAY_EMA_ALPHA
    Runtime.dotEma = Runtime.dotEma * (1 - alpha) + dot * alpha
end

local function checkDotAwayDeactivation(time, distance)
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
    local window = getReturnWindow(Runtime.lastSpeed) * Tuning.DOT_AWAY_WINDOW_MULT
    return time - Runtime.dotAwaySince >= window
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
        local ok, err = pcall(Spam.setActive, true)
        if not ok then
            pcall(Utils.recordError, "AutoClash", "Spam.setActive(true): " .. tostring(err))
        end
        setPhase("active", reason)
    else
        Runtime.lastDeactivatedAt = time
        local ok, err = pcall(Spam.setActive, false)
        if not ok then
            pcall(Utils.recordError, "AutoClash", "Spam.setActive(false): " .. tostring(err))
        end
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
    if typeof(ballPosition) ~= "Vector3" then
        setPhase("waiting", "position_unavailable")
        return
    end

    local speed = tonumber(snapshot.speed) or 0
    local parryRadius = getParryRadius(speed, time)
    Runtime.parryRadius = parryRadius
    Runtime.activationRadius = parryRadius * Tuning.ACTIVATION_RADIUS_MULT
    Runtime.deactivationRadius = parryRadius * Tuning.DEACTIVATION_RADIUS_MULT

    local rootPosition = root.Position
    local distance = (rootPosition - ballPosition).Magnitude

    Runtime.lastSpeed = speed
    updateDotEma(snapshot.velocity, ballPosition, rootPosition)

    if Runtime.active then
        if checkDotAwayDeactivation(time, distance) then
            setActive(false, "dot_away")
        end
        return
    end

    if distance > Runtime.activationRadius then
        Runtime.wasMyTarget = false
        Runtime.lastNotMyTargetAt = time
        setPhase("waiting", "outside_activation_radius")
        return
    end

    local currentTarget = snapshot.targetId
    if type(currentTarget) ~= "number" then
        setPhase("waiting", "no_target")
        return
    end

    local targetIsMe = currentTarget == Runtime.localUserId

    if targetIsMe then
        local returned = Runtime.wasMyTarget == false
            and Runtime.lastNotMyTargetAt > 0
            and time - Runtime.lastNotMyTargetAt <= getReturnWindow(speed)

        Runtime.wasMyTarget = true

        if returned or Runtime.lastNotMyTargetAt == 0 then
            setActive(true, returned and "target_returned" or "should_activate")
            return
        end

        if Runtime.wasMyTarget then
            setActive(true, "should_activate")
            return
        end
    else
        Runtime.wasMyTarget = false
        Runtime.lastNotMyTargetAt = time
    end

    setPhase("waiting", "should_not_activate")
end

-- character runtime
local function bindCharacter(character)
    Runtime.generation = Runtime.generation + 1
    local generation = Runtime.generation

    setActive(false, "rebind_start")
    setPhase("detached", "rebind_start")
    disconnectConnections()

    Runtime.parryRadius = 0
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0
    Runtime.boundRoot = nil
    Runtime.dotEma = 0
    Runtime.dotAwaySince = 0
    Runtime.lastSpeed = 0
    Runtime.wasMyTarget = false
    Runtime.lastNotMyTargetAt = 0

    if not (character and character.Parent) then
        return false
    end

    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)

    if generation ~= Runtime.generation or not (root and root.Parent) then
        return false
    end

    Runtime.boundRoot = root

    local heartbeatConnection
    heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function()
        if generation ~= Runtime.generation then
            return
        end

        local ok, err = xpcall(function()
            if not (character.Parent and root.Parent) then
                setActive(false, "character_dead")
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
        end, debug.traceback)

        if not ok then
            pcall(Utils.recordError, "AutoClash", tostring(err))
        end
    end)

    Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
    Utils.trackCharacter(heartbeatConnection)

    local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            Runtime.generation = Runtime.generation + 1
            setActive(false, "character_removed")
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

    local player = Utils.getLocalPlayer()
    Runtime.localUserId = player and player.UserId or nil

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
    Runtime.generation = Runtime.generation + 1
    Runtime.bound = false
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

    local target = data.TargetPlayerID

    if type(target) == "number" then
        Runtime.lastTarget = target
    elseif type(target) == "string" then
        local parsed = tonumber(target)
        Runtime.lastTarget = parsed or -1
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
    }
end

return AutoClash