-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local Tuning = {
    RED_HOLD = 0.210,
    TARGET_RETURN_MAX_LO = 0.230,
    TARGET_RETURN_MIN_HI = 0.140,
    TARGET_RETURN_SPD_LO = 60,
    TARGET_RETURN_SPD_HI = 200,
    DEACT_RADIUS_MULT = 1.08,
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
    deactivationRadius = 0,
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
        return 8
    end
    local ok, radius = pcall(AutoParry.getParryRadius, speed, time)
    if not ok or type(radius) ~= "number" or radius < 0 then
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
        local ok, err = pcall(Utils.setAutoSpamActive, true)
        if not ok then
            pcall(Utils.recordError, "AutoClash", "Utils.setAutoSpamActive(true): " .. tostring(err))
        end
        setPhase("active", reason)
    else
        Runtime.lastDeactivatedAt = time
        local ok, err = pcall(Utils.setAutoSpamActive, false)
        if not ok then
            pcall(Utils.recordError, "AutoClash", "Utils.setAutoSpamActive(false): " .. tostring(err))
        end
        setPhase("idle", reason)
    end
end

-- helpers lógicos do script 2 adaptados
local function getTargetReturnWindow(speed)
    if speed >= Tuning.TARGET_RETURN_SPD_HI then
        return Tuning.TARGET_RETURN_MIN_HI
    end
    if speed <= Tuning.TARGET_RETURN_SPD_LO then
        return Tuning.TARGET_RETURN_MAX_LO
    end
    local alpha = (speed - Tuning.TARGET_RETURN_SPD_LO)
        / (Tuning.TARGET_RETURN_SPD_HI - Tuning.TARGET_RETURN_SPD_LO)
    return Tuning.TARGET_RETURN_MAX_LO
        + (Tuning.TARGET_RETURN_MIN_HI - Tuning.TARGET_RETURN_MAX_LO) * alpha
end

local function ballInRange(hr, position, distance)
    if not (hr and position) then
        return false
    end
    if typeof(position) ~= "Vector3"
        or type(distance) ~= "number"
        or distance <= 0
    then
        return false
    end
    local ok, currentDistance = pcall(function()
        return (hr.Position - position).Magnitude
    end)
    return ok and typeof(currentDistance) == "number" and currentDistance <= distance
end

local function snapshotPosition(snapshot, ball)
    if type(snapshot) == "table" and typeof(snapshot.position) == "Vector3" then
        return snapshot.position
    end
    local ok, position = pcall(function()
        return ball and ball.Position
    end)
    return ok and typeof(position) == "Vector3" and position or nil
end

local function nearestInRange(myHRP, distance)
    if not (myHRP and type(distance) == "number" and distance > 0) then
        return false
    end
    local localPlayer = Utils.getLocalPlayer()
    for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            if hrp then
                local ok, currentDistance = pcall(function()
                    return (myHRP.Position - hrp.Position).Magnitude
                end)
                if ok and typeof(currentDistance) == "number" and currentDistance <= distance then
                    return true
                end
            end
        end
    end
    return false
end

local function shouldActivate(t, snapshot)
    if type(snapshot) ~= "table" then
        Runtime.lastGate = "snapshot_invalid"
        return false
    end

    local targetId = snapshot.targetId

    if type(targetId) ~= "number" or not Runtime.localUserId then
        Runtime.lastGate = "target_unavailable"
        return false
    end

    if targetId ~= Runtime.localUserId then
        Runtime.lastGate = "target_not_me"
        return false
    end

    if Runtime.lostMeAt <= 0 then
        Runtime.lastGate = "target_return_not_detected"
        return false
    end

    local elapsed = t - Runtime.lostMeAt
    local window = getTargetReturnWindow(Runtime.lastSpeed)

    if elapsed < 0 or elapsed > window then
        Runtime.lastGate = "target_return_expired"
        return false
    end

    Runtime.lastGate = "target_return"
    return true
end

local function shouldDeactivate(t, hr, position, deactivationRadius, isTargeted)
    if not (hr and position) then
        Runtime.lastGate = "deactivation_context_invalid"
        return true
    end
    if not isTargeted then
        Runtime.lastGate = "target_lost"
        return true
    end
    if not ballInRange(hr, position, deactivationRadius) then
        Runtime.lastGate = "outside_deactivation_radius"
        return true
    end
    if not nearestInRange(hr, deactivationRadius) then
        Runtime.lastGate = "no_nearby_target"
        return true
    end
    local lastValid = Runtime.lastActivatedAt or 0
    if (t - lastValid) >= Tuning.RED_HOLD then
        Runtime.lastGate = "red_hold_expired"
        return true
    end
    Runtime.lastGate = "deactivation_hold"
    return false
end

-- main evaluation (com os gates do script 2)
local function evaluateClash(time, snapshot)
    local root = Runtime.boundRoot
    if not (root and root.Parent) then
        Runtime.lastGate = "character_dead"
        return
    end

    local ball = snapshot.ball
    local position = snapshotPosition(snapshot, ball)
    local speed = tonumber(snapshot.speed) or 0

    Runtime.lastSpeed = speed

    local parryRadius = getParryRadius(speed, time)
    Runtime.parryRadius = parryRadius
    Runtime.deactivationRadius = parryRadius * Tuning.DEACT_RADIUS_MULT

    local isTargeted = snapshot.targeted == true

    if Runtime.active then
        if shouldDeactivate(
            time,
            root,
            position,
            Runtime.deactivationRadius,
            isTargeted
        ) then
            setActive(false, "should_deactivate")
        end
        return
    end

    if shouldActivate(time, snapshot) then
        setActive(true, "should_activate")
        Runtime.lostMeAt = 0
    end
end

-- character runtime
local function bindCharacter(character)
    Runtime.generation = Runtime.generation + 1
    local generation = Runtime.generation

    setActive(false, "rebind_start")
    setPhase("detached", "rebind_start")
    disconnectConnections()

    Runtime.parryRadius = 0
    Runtime.deactivationRadius = 0
    Runtime.boundRoot = nil
    Runtime.lastTargetAt = 0
    Runtime.lastTargetId = nil
    Runtime.wasMeTarget = false
    Runtime.lostMeAt = 0
    Runtime.lastSpeed = 0
    Runtime.lastGate = "waiting_for_character"

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
                Runtime.lastGate = "character_dead"
                return
            end

            if Utils.isManualSpamActive() then
                Runtime.lastGate = "manual_spam_active"
                return
            end

            if not Utils.isActive() then
                Runtime.lastGate = "hub_inactive"
                if Runtime.active then
                    setActive(false, "hub_inactive")
                end
                return
            end

            if Utils.getConfig().AutoClash ~= true then
                Runtime.lastGate = "config_disabled"
                if Runtime.active then
                    setActive(false, "hub_disabled")
                end
                return
            end

            local time = Utils.now()
            local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, time)

            if not GameInfo.isSnapshotValid(snapshot, time) then
                Runtime.lastGate = "snapshot_invalid"
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
            Runtime.bound = false
            Runtime.boundRoot = nil
            disconnectConnections()
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
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.now) ~= "function"
        or type(deps.Utils.apiVersion) ~= "function"
        or type(deps.Utils.getConfig) ~= "function"
        or type(deps.Utils.getRunService) ~= "function"
        or type(deps.Utils.trackCharacter) ~= "function"
        or type(deps.Utils.untrackCharacter) ~= "function"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.isManualSpamActive) ~= "function"
        or type(deps.Utils.setAutoSpamActive) ~= "function"
        or type(deps.Utils.recordTransition) ~= "function"
    then
        return false
    end

    AutoParry = deps.AutoParry
    GameInfo = deps.GameInfo
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

    if Runtime.active then
        setActive(false, "detach")
    end
end

function AutoClash.teardown()
    Runtime.generation = Runtime.generation + 1
    Runtime.bound = false
    Runtime.boundRoot = nil
    disconnectConnections()

    if Runtime.active then
        setActive(false, "teardown")
    end

    AutoParry = nil
    GameInfo = nil
    Utils = nil
end

function AutoClash.onBallSync(data)
    if type(data) ~= "table" then
        return
    end

    local target = data.TargetPlayerID

    if type(target) == "number" then
        Runtime.lastTarget = target
        Runtime.lastTargetId = target
    elseif type(target) == "string" then
        local parsed = tonumber(target)
        Runtime.lastTarget = parsed or -1
        Runtime.lastTargetId = Runtime.lastTarget
    else
        return
    end

    local t = Utils.now()
    Runtime.lastTargetAt = t

    if type(Runtime.lastTargetId) == "number" and Runtime.localUserId then
        local isMe = Runtime.lastTargetId == Runtime.localUserId

        if isMe then
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