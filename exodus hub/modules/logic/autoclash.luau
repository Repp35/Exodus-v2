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

local DEFLECT_R = 8.5
local RAD_FLOOR = 14
local RAD_CAP = 30
local RAD_SPD_REF = 200
local RES_BASE = 0
local RES_PER_PARRY = 0.225
local RES_CAP = 6.0
local RES_HOLD_T = 1.2
local RES_DECAY_T = 4.0
local RES_HITBOX_PROX = 12
local RES_HITBOX_GAP = 0.4

-- state
local S = {
    enabled = false,
    active = false,
    activeAt = 0,
    lastValidAt = 0,
    lastTargetAt = 0,
    lastTargetId = nil,
    wasMeTarget = false,
    lostMeAt = 0,
    physDotEma = 0,
}

local RES = {
    stack = 0,
    lastHitboxAt = 0,
    lastStackAt = 0,
}

local resConnection

local heartbeatConnection
local bindGeneration = 0

-- helpers
local function now()
    return Utils.now()
end

local function getLP()
    return Utils.getLocalPlayer()
end

local function getBall()
    return GameInfo.getBall()
end

local function getConfig()
    return Utils.getConfig() or {}
end

local function uiEnabled()
    local config = getConfig()
    return type(config) == "table"
        and config.AutoClash ~= false
        and not Utils.isManualSpamActive()
end

local function isBallTargeted(ctx)
    return ctx and ctx.targeted == true
end

local function ballInRange(hr, ball, distance)
    if not (hr and ball) then
        return false
    end

    if type(distance) ~= "number" or distance <= 0 then
        return false
    end

    local ok, currentDistance = pcall(function()
        return (hr.Position - ball.Position).Magnitude
    end)

    return ok
        and typeof(currentDistance) == "number"
        and currentDistance <= distance
end

local function getDeactivationRadius(ctx)
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return 8
    end

    return radius * DEACT_RADIUS_MULT
end

local function getActivationRadius(ctx)
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return 8
    end

    return radius * ACT_RADIUS_MULT
end

local function getDetectorRadius(ctx)
    local radius = ctx and (ctx.detectRadius or ctx.parryRadius)

    if type(radius) ~= "number" or radius <= 0 then
        return 8
    end

    return radius * ACT_RADIUS_MULT
end

local function nearestInRange(myHRP, distance)
    if not (myHRP and type(distance) == "number" and distance > 0) then
        return false
    end

    local localPlayer = getLP()
    local players = Utils.getPlayers()

    if not players then
        return false
    end

    for _, player in ipairs(players:GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")

            if hrp then
                local ok, currentDistance = pcall(function()
                    return (myHRP.Position - hrp.Position).Magnitude
                end)

                if ok
                    and typeof(currentDistance) == "number"
                    and currentDistance <= distance
                then
                    return true
                end
            end
        end
    end

    return false
end

-- context
local function getBallSpeed(ball)
    if not ball or not ball.Parent then
        return 0
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        return 0
    end

    return velocity.Magnitude
end

local function getSyncSpeed(ball, t)
    if GameInfo and type(GameInfo.ballSpeed) == "function" then
        local ok, speed = pcall(GameInfo.ballSpeed, ball, t)

        if ok and type(speed) == "number" and speed >= 0 then
            return speed
        end
    end

    return getBallSpeed(ball)
end

local function resRadiusBonus()
    return math.min(RES.stack * RES_PER_PARRY, RES_CAP)
end

local function tickResilience(t)
    if RES.stack <= 0 then
        return
    end

    local since = t - RES.lastStackAt

    if since > RES_HOLD_T + RES_DECAY_T then
        RES.stack = 0
        return
    end

    if since > RES_HOLD_T then
        local frac = 1 - (since - RES_HOLD_T) / RES_DECAY_T

        if frac <= 0 then
            RES.stack = 0
        else
            RES.stack = math.floor(RES.stack * frac + 0.5)
        end
    end
end

local function handleHitbox(d)
    if not d or d.Name ~= "HitboxGrow" then
        return
    end

    if not S.active then
        return
    end

    local t = now()

    local ok, hitboxPosition = pcall(function()
        return d.Position
    end)

    if not ok or typeof(hitboxPosition) ~= "Vector3" then
        return
    end

    if t - RES.lastHitboxAt < RES_HITBOX_GAP then
        return
    end

    local ball = getBall()

    if not (ball and ball.Parent) then
        return
    end

    local okDistance, distance = pcall(function()
        return (ball.Position - hitboxPosition).Magnitude
    end)

    if not okDistance
        or typeof(distance) ~= "number"
        or distance > RES_HITBOX_PROX
    then
        return
    end

    RES.lastHitboxAt = t
    RES.lastStackAt = t
    RES.stack = math.min(
        RES.stack + 1,
        math.floor((RES_CAP - RES_BASE) / RES_PER_PARRY)
    )
end

local function installResilienceHook()
    if resConnection then
        pcall(function()
            resConnection:Disconnect()
        end)
        resConnection = nil
    end

    local ok, connection = pcall(function()
        return game:GetService("Workspace").DescendantAdded:Connect(handleHitbox)
    end)

    if ok and connection then
        resConnection = connection
        Utils.trackGlobal(connection)
    end
end

local function computeParryRadius(speed, t)
    tickResilience(t)

    local factor = math.clamp(
        (tonumber(speed) or 0) / RAD_SPD_REF,
        0,
        1
    )

    local parryRadius = math.clamp(
        DEFLECT_R
            + (RAD_FLOOR - DEFLECT_R) * factor
            + resRadiusBonus(),
        DEFLECT_R,
        RAD_CAP
    )

    return parryRadius, parryRadius
end

local function getParryContext(t, hr, ball)
    local speed = getSyncSpeed(ball, t)
    local parryRadius, detectRadius = computeParryRadius(speed, t)

    return {
        time = t,
        hr = hr,
        ball = ball,
        targeted = AutoParry.isTargeted(),
        parryRadius = parryRadius,
        detectRadius = detectRadius,
        sync = {Speed = speed},
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

-- detector
local function tickPhysical(ctx)
    local hr = ctx and ctx.hr
    local ball = ctx and ctx.ball

    if not (hr and hr.Parent and ball and ball.Parent) then
        S.physDotEma = 0
        return false
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        S.physDotEma = 0
        return false
    end

    local speed = velocity.Magnitude

    if speed <= 1 then
        S.physDotEma = 0
        return false
    end

    local offset = hr.Position - ball.Position
    local distance = offset.Magnitude

    if distance < 0.001 then
        S.physDotEma = 0
        return false
    end

    local radius = getDetectorRadius(ctx)
    local dot = velocity:Dot(offset.Unit)

    if distance <= radius * PHYS_RAD_SLACK then
        S.physDotEma =
            S.physDotEma * (1 - PHYS_DOT_EMA)
            + dot * PHYS_DOT_EMA
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

local function shouldDeactivate(t, ctx)
    if not (ctx.hr and ctx.ball) then
        return true
    end

    if not isBallTargeted(ctx) then
        return true
    end

    local radius = getDeactivationRadius(ctx)

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

    local localPlayer = getLP()

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
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return false
    end

    radius = radius * SYNC_TARGET_RADIUS_MULT

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
    S.lastTargetId = targetId
    syncCloseActivationGate(t, targetId, previousTarget)

    if type(targetId) ~= "number" then
        return
    end

    local localPlayer = getLP()

    if not localPlayer then
        return
    end

    local isMe = targetId == localPlayer.UserId

    if isMe then
        local lostAt = S.lostMeAt or 0

        if lostAt > 0 then
            local character = localPlayer.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local ball = getBall()

            if hrp and hrp.Parent and ball and ball.Parent then
                local speed = getBallSpeed(ball)
                local window = getTargetReturnWindow(speed)
                local elapsed = t - lostAt

                if elapsed <= window then
                    local ctx = getParryContext(t, hrp, ball)
                    local activationRadius = getActivationRadius(ctx)

                    if ballInRange(hrp, ball, activationRadius) then
                        activate(t)
                    end
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
    deactivate()
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
            deactivate()
            return
        end

        AutoClash.evaluate(now(), root, getBall(), getConfig())
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
        or type(AutoParry.isTargeted) ~= "function"
    then
        return false
    end

    Utils.setOnClashOn(function()
        return S.active
    end)

    installResilienceHook()

    return true
end

-- public
function AutoClash.evaluate(t, hr, ball, config)
    if not config or not uiEnabled() then
        S.enabled = false
        deactivate()
        return
    end

    S.enabled = true

    if GameInfo.isGrace and GameInfo.isGrace() then
        deactivate()
        return
    end

    local ctx = getParryContext(t, hr, ball)

    if S.active then
        local radius = getDeactivationRadius(ctx)

        if isBallTargeted(ctx)
            and ballInRange(ctx.hr, ctx.ball, radius)
            and nearestInRange(ctx.hr, radius)
        then
            S.lastValidAt = t
        end

        if shouldDeactivate(t, ctx) then
            deactivate()
        end
    elseif tickPhysical(ctx) then
        activate(t)
    end
end

function AutoClash.bindCharacter(character)
    return bindCharacter(character)
end

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

    onTarget(data.TargetPlayerID)
end

function AutoClash.resetState()
    bindGeneration = bindGeneration + 1
    disconnectHeartbeat()

    S.enabled = false
    S.active = false
    S.activeAt = 0
    S.lastValidAt = 0
    S.lastTargetAt = 0
    S.lastTargetId = nil
    S.wasMeTarget = false
    S.lostMeAt = 0
    S.physDotEma = 0
    RES.stack = 0
    RES.lastHitboxAt = 0
    RES.lastStackAt = 0
end

return AutoClash
