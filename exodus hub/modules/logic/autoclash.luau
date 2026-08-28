-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local Tuning = {
    RED_HOLD = 0.210,
    SPAM_INTERVAL = 0.05,
    TARGET_RETURN_MAX_LO = 0.230,
    TARGET_RETURN_MIN_HI = 0.140,
    TARGET_RETURN_SPD_LO = 60,
    TARGET_RETURN_SPD_HI = 200,
    PHYS_SPD_REF = 120,
    PHYS_DOT_EMA = 0.25,
    PHYS_THRESH = 0.14,
    PHYS_RAD_SLACK = 1.22,
    ACT_RADIUS_MULT = 1.33,
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
    activationRadius = 0,
    deactivationRadius = 0,
    connections = {},
    lastTarget = -1,
    localUserId = nil,
    boundRoot = nil,
    -- Variáveis de estado do script 2
    lastValidAt = 0,
    lastTargetAt = 0,
    lastTargetId = nil,
    wasMeTarget = false,
    lostMeAt = 0,
    physDotEma = 0,
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
        Runtime.lastValidAt = time
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

local function snapshotVelocity(snapshot, ball)
    if type(snapshot) == "table" and typeof(snapshot.velocity) == "Vector3"
        and snapshot.velocity.Magnitude > 1
    then
        return snapshot.velocity
    end
    local ok, velocity = pcall(function()
        return ball and ball.AssemblyLinearVelocity
    end)
    if ok and typeof(velocity) == "Vector3" and velocity.Magnitude > 1 then
        return velocity
    end
    return nil
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

local function tickPhysical(snapshot, hr, ball, speed, activationRadius)
    if not (hr and hr.Parent and ball and ball.Parent) then
        Runtime.physDotEma = 0
        Runtime.lastGate = "physical_context_invalid"
        return false
    end

    local position = snapshotPosition(snapshot, ball)
    if not position then
        Runtime.physDotEma = 0
        Runtime.lastGate = "position_unavailable"
        return false
    end

    local offset = hr.Position - position
    local distance = offset.Magnitude
    if distance < 0.001 then
        Runtime.physDotEma = 0
        Runtime.lastGate = "distance_zero"
        return false
    end

    local velocity = snapshotVelocity(snapshot, ball)
    local dot
    if velocity then
        dot = velocity:Dot(offset.Unit)
    else
        dot = tonumber(snapshot and snapshot.approachingSpeed) or 0
        if dot <= 0 and snapshot and snapshot.targeted == true then
            -- BallSync pode fornecer velocidade/posição confiáveis enquanto a
            -- AssemblyLinearVelocity local ainda está zerada. Nesse caso o
            -- alvo confirmado é a única direção segura disponível.
            dot = math.max(tonumber(speed) or 0, 1)
        end
    end

    local effectiveSpeed = math.max(tonumber(speed) or 0, velocity and velocity.Magnitude or 0)
    if effectiveSpeed <= 1 or dot <= Tuning.PHYS_THRESH then
        Runtime.physDotEma = 0
        Runtime.lastGate = "not_approaching"
        return false
    end

    if distance <= activationRadius * Tuning.PHYS_RAD_SLACK then
        Runtime.physDotEma = Runtime.physDotEma * (1 - Tuning.PHYS_DOT_EMA) + dot * Tuning.PHYS_DOT_EMA
    else
        Runtime.physDotEma = 0
    end
    local activated = distance <= activationRadius and Runtime.physDotEma > Tuning.PHYS_THRESH
    Runtime.lastGate = activated and "physical_or_sync_inbound" or "outside_activation_radius"
    return activated
end

local function shouldDeactivate(t, hr, position, deactivationRadius, isTargeted)
    if not (hr and position) then
        return true
    end
    if not isTargeted then
        return true
    end
    if not ballInRange(hr, position, deactivationRadius) then
        return true
    end
    if not nearestInRange(hr, deactivationRadius) then
        return true
    end
    local lastValid = Runtime.lastValidAt or Runtime.lastActivatedAt or 0
    return (t - lastValid) >= Tuning.RED_HOLD
end

-- main evaluation (com os gates do script 2)
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

    local speed = tonumber(snapshot.speed) or 0
    local parryRadius = getParryRadius(speed, time)
    Runtime.parryRadius = parryRadius
    Runtime.activationRadius = parryRadius * Tuning.ACT_RADIUS_MULT
    Runtime.deactivationRadius = parryRadius * Tuning.DEACT_RADIUS_MULT
    Runtime.lastSpeed = speed

    local position = snapshotPosition(snapshot, ball)
    local isTargeted = snapshot.targetId == Runtime.localUserId

    if Runtime.active then
        if ballInRange(root, position, Runtime.deactivationRadius)
            and nearestInRange(root, Runtime.deactivationRadius)
            and isTargeted
        then
            Runtime.lastValidAt = time
        end

        if shouldDeactivate(time, root, position, Runtime.deactivationRadius, isTargeted) then
            Runtime.lastGate = "should_deactivate"
            setActive(false, "should_deactivate")
        end
    else
        if tickPhysical(snapshot, root, ball, speed, Runtime.activationRadius) then
            setActive(true, "tick_physical")
        end
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
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0
    Runtime.boundRoot = nil
    Runtime.lastValidAt = 0
    Runtime.lastTargetAt = 0
    Runtime.lastTargetId = nil
    Runtime.wasMeTarget = false
    Runtime.lostMeAt = 0
    Runtime.physDotEma = 0
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
                setActive(false, "character_dead")
                return
            end

            if Utils.isManualSpamActive() then
                Runtime.lastGate = "manual_spam_active"
                return
            end

            if not Utils.isActive() then
                Runtime.lastGate = "hub_inactive"
                setActive(false, "hub_inactive")
                return
            end

            if Utils.getConfig().AutoClash ~= true then
                Runtime.lastGate = "config_disabled"
                setActive(false, "config_disabled")
                return
            end

            local time = Utils.now()
            local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, time)

            if not GameInfo.isSnapshotValid(snapshot, time) then
                Runtime.lastGate = "snapshot_invalid"
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
    Runtime.activationRadius = 0
    Runtime.deactivationRadius = 0
    Runtime.connections = {}
    Runtime.lastTarget = -1
    Runtime.boundRoot = nil
    Runtime.lastValidAt = 0
    Runtime.lastTargetAt = 0
    Runtime.lastTargetId = nil
    Runtime.wasMeTarget = false
    Runtime.lostMeAt = 0
    Runtime.physDotEma = 0
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
    end

    local t = Utils.now()
    Runtime.lastTargetAt = t

    if type(Runtime.lastTargetId) == "number" and Runtime.localUserId then
        local isMe = Runtime.lastTargetId == Runtime.localUserId
        if isMe then
            if Runtime.lostMeAt > 0 and (t - Runtime.lostMeAt) <= getTargetReturnWindow(Runtime.lastSpeed) then
                -- Lógica de retorno de alvo caso precise interagir via callback de rede
            end
            Runtime.wasMeTarget = true
            Runtime.lostMeAt = 0
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
