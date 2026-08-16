--[[ autoclah ]]

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

local function nearestInRange(myHRP, distance)
    if not (myHRP and type(distance) == "number" and distance > 0) then
        return false
    end

    local localPlayer = getLP()

    for _, player in ipairs(Utils.getPlayers():GetPlayers()) do
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

local function getParryContext(t, hr, ball)
    local speed = getSyncSpeed(ball, t)
    local parryRadius = AutoParry.computeParryRadius(speed, t)

    return {
        time = t,
        hr = hr,
        ball = ball,
        targeted = GameInfo.isTargeted(S.lastTargetId),
        parryRadius = parryRadius,
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

    local radius = getActivationRadius(ctx)
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
    local wasMe = previousTarget == localPlayer.UserId

    if wasMe and not isMe then
        S.wasMeTarget = true
        S.lostMeAt = t
        return
    end

    if not isMe or wasMe or not S.wasMeTarget then
        return
    end

    local ball = getBall()
    local speed = getBallSpeed(ball)
    local window = getTargetReturnWindow(speed)
    local elapsed = t - S.lostMeAt

    if elapsed <= window then
        local character = localPlayer.Character
        local hrp = character and character:FindFirstChild("HumanoidRootPart")
        local ctx = hrp and ball and getParryContext(t, hrp, ball)

        if ctx and ballInRange(hrp, ball, getActivationRadius(ctx)) then
            activate(t)
        end
    end

    S.wasMeTarget = false
    S.lostMeAt = 0
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
        or type(AutoParry.computeParryRadius) ~= "function"
    then
        return false
    end

    Utils.setOnClashOn(function()
        return S.active
    end)

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
end

return AutoClash
