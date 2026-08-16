-- [[ Auto Parry ]]

local AutoParry = {}
local Remote
local GameInfo
local Utils

-- tuning
local Tuning = {
    FIRE_LOCK_TIME = 0.080,
    FIRE_TIMEOUT = 2.0,
    MIN_BALL_SPEED = 5,

    DEFLECT_RADIUS = 8.5,
    RADIUS_SPEED_FLOOR = 14,
    RADIUS_CAP = 1000,
    RADIUS_SPEED_REFERENCE = 200,

    PING_FLOOR = 0.030,
    PING_CAP = 0.150,
    EARLY_PARRY_TIME = 0.130,
    PING_PARRY_MIN = 0.030,
    PING_PARRY_MAX = 0.500,

    RES_PER_PARRY = 0.225,
    RES_CAP = 6.0,
    RES_HOLD_TIME = 1.2,
    RES_DECAY_TIME = 4.0,

    HITBOX_OWN_WINDOW = 0.5,
    HITBOX_PROXIMITY = 12,
    HITBOX_GAP = 0.4,
}

local PING_SAMPLE_INTERVAL = 1.5
local PING_EMA_ALPHA = 0.3
local PING_CACHE_INTERVAL = 0.25

-- shared hitbox hook
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table"
    and namespace.AutoParryHitbox
    or {
        connection = nil,
        handler = nil,
    }

namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- state
local ParryState = {
    armed = false,
    armedBall = nil,
    armedAt = 0,
    fired = false,
    firedAt = 0,
}

local Resilience = {
    stack = 0,
    lastFireBall = nil,
    lastFireAt = 0,
    lastHitboxAt = 0,
    lastStackAt = 0,
}

local Runtime = {
    generation = 0,
    localUserId = -1,
    lastTarget = -1,
    teleportLockUntil = 0,
    connections = {},
    smoothPing = 0.060,
    pingTimer = 0,
    pingOneWay = 0.030,
    pingOneWayAt = 0,
    resilienceBonus = 0,
    resilienceBonusAt = -1,
}

local Stats = game:GetService("Stats")

-- helpers
local function now()
    return Utils.now()
end

local function clearArmedState()
    ParryState.armed = false
    ParryState.armedBall = nil
    ParryState.armedAt = 0
end

local function disconnectConnections()
    for index = #Runtime.connections, 1, -1 do
        local connection = Runtime.connections[index]
        Runtime.connections[index] = nil
        Utils.untrackCharacter(connection)
        pcall(connection.Disconnect, connection)
    end
end

local function clearRuntimeCycle()
    clearArmedState()
    ParryState.fired = false
    ParryState.firedAt = 0
end

local function samplePing()
    local ok, ping = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)

    if ok and type(ping) == "number" and ping > 0 and ping < 0.5 then
        Runtime.smoothPing = Runtime.smoothPing * (1 - PING_EMA_ALPHA)
            + ping * PING_EMA_ALPHA
    end
end

local function getPingWindow()
    return math.clamp(
        Runtime.smoothPing,
        Tuning.PING_PARRY_MIN,
        Tuning.PING_PARRY_MAX
    )
end

local function getPingOneWay(time)
    if time - Runtime.pingOneWayAt > PING_CACHE_INTERVAL then
        Runtime.pingOneWay = math.clamp(
            Runtime.smoothPing * 0.5,
            Tuning.PING_FLOOR,
            Tuning.PING_CAP
        )
        Runtime.pingOneWayAt = time
    end

    return Runtime.pingOneWay
end

-- resilience
local function getResilienceBonus(time)
    if time == Runtime.resilienceBonusAt then
        return Runtime.resilienceBonus
    end

    Runtime.resilienceBonus = math.min(
        Resilience.stack * Tuning.RES_PER_PARRY,
        Tuning.RES_CAP
    )
    Runtime.resilienceBonusAt = time

    return Runtime.resilienceBonus
end

local function tickResilience(time)
    if Resilience.stack <= 0 then
        return
    end

    local elapsed = time - Resilience.lastStackAt

    if elapsed > Tuning.RES_HOLD_TIME + Tuning.RES_DECAY_TIME then
        Resilience.stack = 0
        Runtime.resilienceBonusAt = -1
        return
    end

    if elapsed > Tuning.RES_HOLD_TIME then
        local fraction = 1 - (elapsed - Tuning.RES_HOLD_TIME) / Tuning.RES_DECAY_TIME
        local decayed = math.max(0, math.floor(Resilience.stack * fraction + 0.5))

        if decayed ~= Resilience.stack then
            Resilience.stack = decayed
            Runtime.resilienceBonusAt = -1
        end
    end
end

-- radius
local function computeParryRadius(speed, time)
    speed = math.max(0, tonumber(speed) or 0)
    time = tonumber(time) or now()

    local speedFactor = math.clamp(
        speed / Tuning.RADIUS_SPEED_REFERENCE,
        0,
        1
    )

    local parryRadius = Tuning.DEFLECT_RADIUS
        + (Tuning.RADIUS_SPEED_FLOOR - Tuning.DEFLECT_RADIUS) * speedFactor
        + getResilienceBonus(time)

    parryRadius = math.clamp(
        parryRadius,
        Tuning.DEFLECT_RADIUS,
        Tuning.RADIUS_CAP
    )

    local detectionRadius = parryRadius
        + speed * (
            getPingOneWay(time)
            + Tuning.EARLY_PARRY_TIME
            + 0.016
        )

    return parryRadius, detectionRadius
end

-- targeting
local function isTargeted()
    return GameInfo.isTargeted(Runtime.lastTarget) == true
end

local function onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end

    local time = now()

    if data.Teleported == true then
        Runtime.teleportLockUntil = time + 0.20
        ParryState.fired = false
        clearArmedState()
        return
    end

    local targetId = tonumber(data.TargetPlayerID) or -1

    if targetId == Runtime.lastTarget then
        return
    end

    local previousTarget = Runtime.lastTarget
    Runtime.lastTarget = targetId

    if targetId == Runtime.localUserId and previousTarget ~= Runtime.localUserId then
        ParryState.fired = false
    end
end

-- parry request
local function requestParry()
    local time = now()

    if not Remote.fireParry(1) then
        return false
    end

    local ball = GameInfo.getBall()

    if ball and ball.Parent then
        Resilience.lastFireBall = ball
        Resilience.lastFireAt = time
    end

    return true
end

-- hitbox
local function handleHitbox(instance)
    if not Utils.isActive() or instance.Name ~= "HitboxGrow" then
        return
    end

    local ok, position = pcall(function()
        return instance.Position
    end)

    if not ok or typeof(position) ~= "Vector3" then
        return
    end

    local time = now()

    if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW then
        return
    end

    if not (Resilience.lastFireBall and Resilience.lastFireBall.Parent) then
        return
    end

    if time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP then
        return
    end

    if (Resilience.lastFireBall.Position - position).Magnitude > Tuning.HITBOX_PROXIMITY then
        return
    end

    Resilience.lastHitboxAt = time
    Resilience.lastStackAt = time
    Resilience.stack = math.min(
        Resilience.stack + 1,
        math.floor(Tuning.RES_CAP / Tuning.RES_PER_PARRY)
    )
    Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
    if HitboxState.connection then
        return true
    end

    local workspaceService = game:GetService("Workspace")
    local ok, connection = pcall(function()
        return workspaceService.DescendantAdded:Connect(function(instance)
            local handler = HitboxState.handler

            if type(handler) == "function" then
                handler(instance)
            end
        end)
    end)

    if not ok or not connection then
        return false
    end

    HitboxState.connection = connection
    Utils.trackGlobal(connection)
    return true
end

-- character runtime
local function bindCharacter(character)
    Runtime.generation = Runtime.generation + 1
    local generation = Runtime.generation

    disconnectConnections()
    clearRuntimeCycle()

    if not (character and character.Parent) then
        return false
    end

    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)

    if generation ~= Runtime.generation or not (root and root.Parent) then
        return false
    end

    local heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function(dt)
        if generation ~= Runtime.generation then
            return
        end

        if not (character.Parent and root.Parent) then
            return
        end

        local config = Utils.getConfig()

        if config.AutoParry ~= true
            or now() < Runtime.teleportLockUntil
        then
            clearRuntimeCycle()
            return
        end

        if Utils.isSpamActive() then
            clearRuntimeCycle()
            return
        end

        local timeNow = now()
        tickResilience(timeNow)

        Runtime.pingTimer = Runtime.pingTimer + dt

        if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then
            Runtime.pingTimer = 0
            samplePing()
        end

        local ball = GameInfo.getBall()

        if ParryState.armed then
            local sameBall = ball == ParryState.armedBall
            local validBall = ball and ball.Parent and sameBall

            if not (validBall and isTargeted()) then
                clearArmedState()
            elseif GameInfo.getDeflectCD() > 0 then
                return
            else
                local canRetry = not ParryState.fired
                    or timeNow - ParryState.firedAt >= Tuning.FIRE_TIMEOUT

                if canRetry then
                    if requestParry() then
                        ParryState.fired = true
                        ParryState.firedAt = timeNow
                    else
                        ParryState.fired = false
                    end
                end

                clearArmedState()
                return
            end
        end

        if not (ball and ball.Parent) or not isTargeted() then
            return
        end

        local speed = GameInfo.ballSpeed(ball, timeNow)

        if speed < Tuning.MIN_BALL_SPEED then
            return
        end

        local position = GameInfo.ballPos(ball, timeNow)

        if not position then
            return
        end

        local parryRadius, detectionRadius = computeParryRadius(speed, timeNow)
        local offset = root.Position - position
        local distanceSquared = offset:Dot(offset)

        if distanceSquared > detectionRadius * detectionRadius then
            return
        end

        local distance = math.sqrt(distanceSquared)
        local impactTime = math.max(0, (distance - parryRadius) / speed)
        local earlyWindow = Tuning.EARLY_PARRY_TIME + getPingWindow()

        if impactTime > earlyWindow then
            return
        end

        if GameInfo.getDeflectCD() > 0 then
            ParryState.armed = true
            ParryState.armedBall = ball
            ParryState.armedAt = timeNow
            return
        end

        if ParryState.fired then
            local elapsed = timeNow - ParryState.firedAt

            if elapsed < Tuning.FIRE_LOCK_TIME then
                return
            end

            if elapsed < Tuning.FIRE_TIMEOUT then
                return
            end

            ParryState.fired = false
        end

        if requestParry() then
            ParryState.fired = true
            ParryState.firedAt = timeNow
        else
            ParryState.fired = false
        end
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

    return true
end

-- lifecycle
local function resetState()
    clearRuntimeCycle()

    Resilience.stack = 0
    Resilience.lastFireBall = nil
    Resilience.lastFireAt = 0
    Resilience.lastHitboxAt = 0
    Resilience.lastStackAt = 0

    Runtime.teleportLockUntil = 0
    Runtime.lastTarget = -1
    Runtime.pingTimer = 0
    Runtime.pingOneWayAt = 0
    Runtime.resilienceBonus = 0
    Runtime.resilienceBonusAt = -1
end

-- setup
function AutoParry.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Remote) ~= "table"
        or type(deps.Remote.fireParry) ~= "function"
        or type(deps.GameInfo) ~= "table"
        or type(deps.GameInfo.getDeflectCD) ~= "function"
        or type(deps.GameInfo.getBall) ~= "function"
        or type(deps.GameInfo.ballSpeed) ~= "function"
        or type(deps.GameInfo.ballPos) ~= "function"
        or type(deps.GameInfo.isTargeted) ~= "function"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.now) ~= "function"
        or type(deps.Utils.getConfig) ~= "function"
        or type(deps.Utils.getLocalPlayer) ~= "function"
        or type(deps.Utils.getRunService) ~= "function"
        or type(deps.Utils.trackCharacter) ~= "function"
        or type(deps.Utils.untrackCharacter) ~= "function"
        or type(deps.Utils.trackGlobal) ~= "function"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.isSpamActive) ~= "function"
    then
        return false
    end

    Remote = deps.Remote
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    local localPlayer = Utils.getLocalPlayer()
    Runtime.localUserId = localPlayer and localPlayer.UserId or -1

    HitboxState.handler = handleHitbox
    resetState()

    if not installHitboxHook() then
        Utils.warn("hook de hitbox indisponível")
    end

    return true
end

function AutoParry.fire()
    return requestParry()
end

function AutoParry.bindParry(character)
    return bindCharacter(character)
end

function AutoParry.resetState()
    resetState()
end

function AutoParry.detachCharacter()
    Runtime.generation = Runtime.generation + 1
    disconnectConnections()
    resetState()
end

function AutoParry.onBallSync(data)
    onBallSync(data)
end

function AutoParry.isTargeted()
    return isTargeted()
end

function AutoParry.getParryRadius(speed, time)
    local parryRadius = computeParryRadius(speed, time)
    return parryRadius
end

return AutoParry
