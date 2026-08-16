-- [[ auto clash ]]

-- parameters
local AutoClash = {}
local GameInfo, Utils, AutoParry

-- tuning
local RED_HOLD = 0.25
local TARGET_RETURN_MAX_LO = 0.280
local TARGET_RETURN_MIN_HI = 0.170
local TARGET_RETURN_SPD_LO = 60
local TARGET_RETURN_SPD_HI = 200
local PHYS_DOT_EMA = 0.25
local PHYS_THRESH = 0.14
local PHYS_RAD_SLACK = 1.22
local ACT_RADIUS_MULT = 1.32
local SYNC_TARGET_RADIUS_MULT = 1.05
local DEACT_RADIUS_MULT = 1.15
local TELEPORT_LOCK = 0.20

local S = {
    enabled = false,
    active = false,
    activeAt = 0,
    lastValidAt = 0,
    lastTargetAt = 0,
    lastTargetId = -999,
    wasMeTarget = false,
    lostMeAt = 0,
    physDotEma = 0,
    teleportLockUntil = 0,
}

local heartbeatConnection
local bindGeneration = 0

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
    if not (ball and ball.Parent) then
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

local function getBallSpeed(ball, t)
    if GameInfo and type(GameInfo.ballSpeed) == "function" then
        local ok, speed = pcall(GameInfo.ballSpeed, ball, t)
        if ok and type(speed) == "number" and speed >= 0 then
            return speed
        end
    end

    local velocity = getBallVelocity(ball)
    return velocity and velocity.Magnitude or 0
end

local function getParryRadius(speed, t)
    return AutoParry.computeParryRadius(speed, t)
end

local function ballDistance(hr, ball)
    if not (hr and hr.Parent and ball and ball.Parent) then
        return nil
    end

    local ok, distance = pcall(function()
        return (hr.Position - ball.Position).Magnitude
    end)

    return ok and type(distance) == "number" and distance or nil
end

local function ballInRange(hr, ball, distance)
    local currentDistance = ballDistance(hr, ball)
    return currentDistance ~= nil
        and type(distance) == "number"
        and distance > 0
        and currentDistance <= distance
end

local function isBallTargeted()
    if not GameInfo or type(GameInfo.isTargeted) ~= "function" then
        return false
    end

    local ok, targeted = pcall(GameInfo.isTargeted, S.lastTargetId)
    return ok and targeted == true
end

local function getParryContext(t, hr, ball)
    local speed = getBallSpeed(ball, t)

    return {
        time = t,
        hr = hr,
        ball = ball,
        targeted = isBallTargeted(),
        parryRadius = getParryRadius(speed, t),
        spd = speed,
    }
end

local function getTargetReturnWindow(speed)
    if speed >= TARGET_RETURN_SPD_HI then
        return TARGET_RETURN_MIN_HI
    end

    if speed <= TARGET_RETURN_SPD_LO then
        return TARGET_RETURN_MAX_LO
    end

    local alpha = (speed - TARGET_RETURN_SPD_LO)
        / (TARGET_RETURN_SPD_HI - TARGET_RETURN_SPD_LO)

    return TARGET_RETURN_MAX_LO
        + (TARGET_RETURN_MIN_HI - TARGET_RETURN_MAX_LO) * alpha
end

local function nearestInRange(myHRP, distance)
    if not (myHRP and myHRP.Parent and type(distance) == "number" and distance > 0) then
        return false
    end

    local players = Utils.getPlayers()
    local localPlayer = getLocalPlayer()
    if not players then
        return false
    end

    for _, player in ipairs(players:GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local currentDistance = ballDistance(myHRP, hrp)

            if currentDistance and currentDistance <= distance then
                return true
            end
        end
    end

    return false
end

-- detector
local function tickPhysical(ctx)
    local hr = ctx and ctx.hr
    local ball = ctx and ctx.ball

    if not (hr and hr.Parent and ball and ball.Parent) then
        S.physDotEma = 0
        return false
    end

    local velocity = getBallVelocity(ball)
    if not velocity or velocity.Magnitude <= 1 then
        S.physDotEma = 0
        return false
    end

    local offset = hr.Position - ball.Position
    local distance = offset.Magnitude
    if distance < 0.001 then
        S.physDotEma = 0
        return false
    end

    local radius = getParryRadius(ctx.spd, ctx.time) * ACT_RADIUS_MULT
    local dot = velocity:Dot(offset.Unit)

    if distance <= radius * PHYS_RAD_SLACK then
        S.physDotEma = S.physDotEma * (1 - PHYS_DOT_EMA) + dot * PHYS_DOT_EMA
    else
        S.physDotEma = 0
    end

    return distance <= radius and S.physDotEma > PHYS_THRESH
end

-- lifecycle
local function activate(t)
    S.active = true
    S.activeAt = t
    S.lastValidAt = t
end

local function deactivate()
    S.active = false
    S.activeAt = 0
    S.lastValidAt = 0
end

local function forceDeactivate(t)
    deactivate()
    S.lastValidAt = t or 0
end

local function shouldDeactivate(t, ctx)
    if not (ctx and ctx.hr and ctx.ball) then
        return true
    end

    if not ctx.targeted then
        return true
    end

    local radius = ctx.parryRadius * DEACT_RADIUS_MULT
    if not ballInRange(ctx.hr, ctx.ball, radius) then
        return true
    end

    if not nearestInRange(ctx.hr, radius) then
        return true
    end

    local lastValid = S.lastValidAt or S.activeAt or 0
    return (t - lastValid) >= RED_HOLD
end

-- target
local function syncCloseActivationGate(t, targetId, previousTarget)
    if type(targetId) ~= "number" then
        return false
    end

    local localPlayer = getLocalPlayer()
    if not localPlayer
        or targetId ~= localPlayer.UserId
        or previousTarget == targetId
    then
        return false
    end

    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    local ball = getBall()
    if not (hrp and hrp.Parent and ball and ball.Parent) then
        return false
    end

    local ctx = getParryContext(t, hrp, ball)
    local radius = ctx.parryRadius * SYNC_TARGET_RADIUS_MULT

    if not ballInRange(hrp, ball, radius) then
        return false
    end

    activate(t)
    return true
end

local function onTarget(targetId)
    local t = now()
    local previousTarget = S.lastTargetId

    S.lastTargetAt = t
    S.lastTargetId = type(targetId) == "number" and targetId or -999
    syncCloseActivationGate(t, S.lastTargetId, previousTarget)

    local localPlayer = getLocalPlayer()
    if not localPlayer then
        return
    end

    local isMe = S.lastTargetId == localPlayer.UserId
    if isMe then
        local lostAt = S.lostMeAt or 0

        if lostAt > 0 then
            local character = localPlayer.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local ball = getBall()

            if hrp and hrp.Parent and ball and ball.Parent then
                local speed = getBallSpeed(ball, t)
                local window = getTargetReturnWindow(speed)
                local elapsed = t - lostAt
                local activationRadius = getParryRadius(speed, t) * ACT_RADIUS_MULT

                if elapsed <= window and ballInRange(hrp, ball, activationRadius) then
                    activate(t)
                end
            end
        end

        S.wasMeTarget = true
        S.lostMeAt = 0
        return
    end

    if S.wasMeTarget then
        S.lostMeAt = t
    end
end

-- teleport
local function onTeleport()
    local t = now()
    S.teleportLockUntil = t + TELEPORT_LOCK
    forceDeactivate(t)
end

-- character
local function disconnectHeartbeat()
    if heartbeatConnection then
        pcall(function()
            heartbeatConnection:Disconnect()
        end)
        heartbeatConnection = nil
    end
end

local function bindCharacter(character)
    bindGeneration = bindGeneration + 1
    local currentGeneration = bindGeneration

    disconnectHeartbeat()
    forceDeactivate(now())

    if not (character and character.Parent) then
        return false
    end

    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)
    if not (root and root.Parent) then
        return false
    end

    heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function()
        if currentGeneration ~= bindGeneration or not Utils.isActive() then
            return
        end

        if not (character.Parent and root.Parent) then
            forceDeactivate(now())
            return
        end

        local t = now()
        local config = Utils.getConfig()
        local ctx = getParryContext(t, root, getBall())

        if not config or config.AutoClash == false or Utils.isManualSpamActive() then
            S.enabled = false
            forceDeactivate(t)
            return
        end

        if GameInfo.isGrace and GameInfo.isGrace() then
            S.enabled = true
            forceDeactivate(t)
            return
        end

        if t < S.teleportLockUntil then
            S.enabled = true
            forceDeactivate(t)
            return
        end

        S.enabled = true

        if S.active then
            if ctx.targeted
                and ballInRange(ctx.hr, ctx.ball, ctx.parryRadius * DEACT_RADIUS_MULT)
                and nearestInRange(ctx.hr, ctx.parryRadius * DEACT_RADIUS_MULT)
            then
                S.lastValidAt = t
            end

            if shouldDeactivate(t, ctx) then
                deactivate()
            end
        elseif tickPhysical(ctx) then
            activate(t)
        end
    end)

    Utils.trackCharacter(heartbeatConnection)
    return true
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table" then
        return false
    end

    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoParry = deps.AutoParry

    if not GameInfo
        or not Utils
        or not AutoParry
        or type(AutoParry.computeParryRadius) ~= "function"
    then
        return false
    end

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
    if typeof(data) ~= "table" then
        return
    end

    if data.Teleported == true then
        onTeleport()
        return
    end

    if type(data.TargetPlayerID) == "number" then
        onTarget(data.TargetPlayerID)
    end
end

function AutoClash.resetState()
    bindGeneration = bindGeneration + 1
    disconnectHeartbeat()

    S.enabled = false
    S.active = false
    S.activeAt = 0
    S.lastValidAt = 0
    S.lastTargetAt = 0
    S.lastTargetId = -999
    S.wasMeTarget = false
    S.lostMeAt = 0
    S.physDotEma = 0
    S.teleportLockUntil = 0
end

return AutoClash
