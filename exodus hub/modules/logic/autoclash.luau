-- [[ Auto Clash ]]

local AutoClash = {}

-- dependencies
local GameInfo
local Utils
local AutoParry

-- tuning
local RED_HOLD = 0.25
local FIRE_INTERVAL = 0.05

local TARGET_RETURN_MAX = 0.280
local TARGET_RETURN_MIN = 0.170
local TARGET_RETURN_SPEED_LO = 60
local TARGET_RETURN_SPEED_HI = 200

local PHYS_DOT_EMA = 0.25
local PHYS_DOT_THRESHOLD = 0.14
local PHYS_RADIUS_SLACK = 1.22
local ACTIVATION_RADIUS_MULT = 1.32
local SYNC_RADIUS_MULT = 1.05
local DEACTIVATION_RADIUS_MULT = 1.15
local MIN_PARRY_RADIUS = 8.5

-- state
local State = {
    enabled = false,
    active = false,
    activeAt = 0,
    lastValidAt = 0,
    lastTargetId = nil,
    wasMeTarget = false,
    lostMeAt = 0,
    physicalDotEma = 0,
    bound = false,
    boundCharacter = nil,
    lastFireAt = -math.huge,
}

local heartbeatConnection

-- helpers
local function now()
    if Utils and type(Utils.now) == "function" then
        return Utils.now()
    end

    return os.clock()
end

local function getLocalPlayer()
    if Utils and type(Utils.getLocalPlayer) == "function" then
        return Utils.getLocalPlayer()
    end

    return game:GetService("Players").LocalPlayer
end

local function getPlayers()
    if Utils and type(Utils.getPlayers) == "function" then
        return Utils.getPlayers()
    end

    return game:GetService("Players")
end

local function getBall()
    if GameInfo and type(GameInfo.getBall) == "function" then
        return GameInfo.getBall()
    end

    return nil
end

local function getConfig()
    if Utils and type(Utils.getConfig) == "function" then
        local config = Utils.getConfig()
        return type(config) == "table" and config or {}
    end

    return {}
end

local function uiEnabled()
    return getConfig().AutoClash == true
end

local function isBallTargeted()
    return AutoParry
        and type(AutoParry.isTargeted) == "function"
        and AutoParry.isTargeted() == true
end

local function isManualSpamActive()
    return Utils
        and type(Utils.isManualSpamActive) == "function"
        and Utils.isManualSpamActive() == true
end

local function getBallPosition(ball, t)
    if not (ball and ball.Parent) then
        return nil
    end

    if GameInfo and type(GameInfo.ballPos) == "function" then
        local ok, position = pcall(GameInfo.ballPos, ball, t)

        if ok and typeof(position) == "Vector3" then
            return position
        end
    end

    local ok, position = pcall(function()
        return ball.Position
    end)

    return ok and typeof(position) == "Vector3" and position or nil
end

local function getBallSpeed(ball, t)
    if not (ball and ball.Parent) then
        return 0
    end

    if GameInfo and type(GameInfo.ballSpeed) == "function" then
        local ok, speed = pcall(GameInfo.ballSpeed, ball, t)

        if ok and type(speed) == "number" and speed >= 0 then
            return speed
        end
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if ok and typeof(velocity) == "Vector3" then
        return velocity.Magnitude
    end

    return 0
end

local function getDistance(positionA, positionB)
    if typeof(positionA) ~= "Vector3" or typeof(positionB) ~= "Vector3" then
        return nil
    end

    local ok, distance = pcall(function()
        return (positionA - positionB).Magnitude
    end)

    return ok and type(distance) == "number" and distance or nil
end

local function getParryRadius(speed, t)
    if AutoParry and type(AutoParry.getParryRadius) == "function" then
        local ok, parryRadius = pcall(AutoParry.getParryRadius, speed, t)

        if ok and type(parryRadius) == "number" and parryRadius > 0 then
            return parryRadius
        end
    end

    return MIN_PARRY_RADIUS
end

local function getContext(t, hr, ball)
    local speed = getBallSpeed(ball, t)
    local parryRadius = getParryRadius(speed, t)

    return {
        time = t,
        hr = hr,
        ball = ball,
        position = getBallPosition(ball, t),
        speed = speed,
        parryRadius = parryRadius,
        activationRadius = parryRadius * ACTIVATION_RADIUS_MULT,
        deactivationRadius = parryRadius * DEACTIVATION_RADIUS_MULT,
    }
end

local function ballInRange(ctx, radius)
    if not (ctx and ctx.hr and ctx.ball and ctx.position) then
        return false
    end

    local distance = getDistance(ctx.hr.Position, ctx.position)
    return type(distance) == "number" and distance <= radius
end

local function hasOpponentInRange(position, radius)
    if typeof(position) ~= "Vector3" or type(radius) ~= "number" or radius <= 0 then
        return false
    end

    local localPlayer = getLocalPlayer()
    local players = getPlayers()

    if not (localPlayer and players) then
        return false
    end

    for _, player in ipairs(players:GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local hr = character and character:FindFirstChild("HumanoidRootPart")

            if hr and hr.Parent then
                local distance = getDistance(position, hr.Position)

                if type(distance) == "number" and distance <= radius then
                    return true
                end
            end
        end
    end

    return false
end

local function getTargetReturnWindow(speed)
    if speed >= TARGET_RETURN_SPEED_HI then
        return TARGET_RETURN_MIN
    end

    if speed <= TARGET_RETURN_SPEED_LO then
        return TARGET_RETURN_MAX
    end

    local alpha = (speed - TARGET_RETURN_SPEED_LO)
        / (TARGET_RETURN_SPEED_HI - TARGET_RETURN_SPEED_LO)

    return TARGET_RETURN_MAX + (TARGET_RETURN_MIN - TARGET_RETURN_MAX) * alpha
end

local function tickPhysical(ctx)
    if not (ctx and ctx.hr and ctx.ball and ctx.position) then
        State.physicalDotEma = 0
        return false
    end

    local ok, velocity = pcall(function()
        return ctx.ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        State.physicalDotEma = 0
        return false
    end

    local speed = velocity.Magnitude

    if speed <= 1 then
        State.physicalDotEma = 0
        return false
    end

    local offset = ctx.hr.Position - ctx.position
    local distance = offset.Magnitude

    if distance < 0.001 then
        State.physicalDotEma = 0
        return false
    end

    if distance <= ctx.activationRadius * PHYS_RADIUS_SLACK then
        local approachingSpeed = velocity:Dot(offset.Unit)
        State.physicalDotEma = State.physicalDotEma * (1 - PHYS_DOT_EMA)
            + approachingSpeed * PHYS_DOT_EMA
    else
        State.physicalDotEma = 0
    end

    return distance <= ctx.activationRadius
        and State.physicalDotEma > PHYS_DOT_THRESHOLD
end

-- lifecycle
local function activate(t)
    State.active = true
    State.activeAt = t
    State.lastValidAt = t
    State.lastFireAt = -math.huge
end

local function deactivate()
    State.active = false
    State.activeAt = 0
    State.lastValidAt = 0
    State.physicalDotEma = 0
end

local function shouldDeactivate(t, ctx)
    if not (ctx and ctx.hr and ctx.ball and ctx.position) then
        return true
    end

    if not isBallTargeted() then
        return true
    end

    if not ballInRange(ctx, ctx.deactivationRadius) then
        return true
    end

    if not hasOpponentInRange(ctx.hr.Position, ctx.deactivationRadius) then
        return true
    end

    return t - (State.lastValidAt or State.activeAt or 0) >= RED_HOLD
end

-- target sync
local function activateFromTargetSync(t, targetId, previousTarget)
    local localPlayer = getLocalPlayer()

    if not localPlayer
        or type(targetId) ~= "number"
        or targetId ~= localPlayer.UserId
        or previousTarget == targetId
    then
        return false
    end

    local character = localPlayer.Character
    local hr = character and character:FindFirstChild("HumanoidRootPart")
    local ball = getBall()

    if not (hr and hr.Parent and ball and ball.Parent) then
        return false
    end

    local ctx = getContext(t, hr, ball)

    if not ctx.position or not ballInRange(ctx, ctx.parryRadius * SYNC_RADIUS_MULT) then
        return false
    end

    activate(t)
    return true
end

function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end

    local t = now()

    if not uiEnabled() or isManualSpamActive() then
        State.enabled = false
        deactivate()
        return
    end

    if data.Teleported == true then
        deactivate()
        return
    end

    local newTarget = data.TargetPlayerID

    if type(newTarget) ~= "number" then
        if State.wasMeTarget and State.lostMeAt == 0 then
            State.lostMeAt = t
        end

        return
    end

    local previousTarget = State.lastTargetId

    State.lastTargetId = newTarget
    activateFromTargetSync(t, newTarget, previousTarget)

    local localPlayer = getLocalPlayer()

    if not localPlayer then
        return
    end

    local isMe = newTarget == localPlayer.UserId

    if isMe then
        local lostAt = State.lostMeAt or 0

        if lostAt > 0 then
            local character = localPlayer.Character
            local hr = character and character:FindFirstChild("HumanoidRootPart")
            local ball = getBall()

            if hr and hr.Parent and ball and ball.Parent then
                local speed = getBallSpeed(ball, t)
                local window = getTargetReturnWindow(speed)
                local elapsed = t - lostAt
                local ctx = getContext(t, hr, ball)

                if elapsed <= window
                    and ctx.position
                    and ballInRange(ctx, ctx.activationRadius)
                then
                    activate(t)
                end
            end
        end

        State.wasMeTarget = true
        State.lostMeAt = 0
    elseif State.wasMeTarget then
        State.lostMeAt = t
    end
end

-- firing
local function fireParry(t)
    if t - State.lastFireAt < FIRE_INTERVAL then
        return
    end

    State.lastFireAt = t

    if not AutoParry or type(AutoParry.fire) ~= "function" then
        return
    end

    pcall(AutoParry.fire)
end

local function tickCharacter(character)
    if not uiEnabled() then
        if State.enabled or State.active then
            State.enabled = false
            deactivate()
        end

        return
    end

    State.enabled = true

    if isManualSpamActive() then
        deactivate()
        return
    end

    if not (character and character.Parent) then
        return
    end

    local hr = character:FindFirstChild("HumanoidRootPart")

    if not (hr and hr.Parent) then
        return
    end

    local ball = getBall()

    if not (ball and ball.Parent) then
        deactivate()
        return
    end

    local t = now()
    local ctx = getContext(t, hr, ball)

    if not ctx.position then
        deactivate()
        return
    end

    if State.active then
        if isBallTargeted()
            and ballInRange(ctx, ctx.deactivationRadius)
            and hasOpponentInRange(hr.Position, ctx.deactivationRadius)
        then
            State.lastValidAt = t
        end

        if shouldDeactivate(t, ctx) then
            deactivate()
        end
    elseif tickPhysical(ctx) then
        activate(t)
    end

    if State.active then
        fireParry(t)
    end
end

-- binding
function AutoClash.bindCharacter(character)
    if not (character and character.Parent) then
        return false
    end

    if not (Utils and type(Utils.getRunService) == "function") then
        return false
    end

    AutoClash.detachCharacter()

    State.bound = true
    State.boundCharacter = character
    State.lastFireAt = -math.huge

    heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function()
        tickCharacter(character)
    end)

    Utils.trackCharacter(heartbeatConnection)
    Utils.setOnClashOn(function()
        return State.active == true
    end)

    return true
end

function AutoClash.detachCharacter()
    if heartbeatConnection then
        pcall(function()
            heartbeatConnection:Disconnect()
        end)

        if Utils and type(Utils.untrackCharacter) == "function" then
            Utils.untrackCharacter(heartbeatConnection)
        end

        heartbeatConnection = nil
    end

    State.bound = false
    State.boundCharacter = nil
    deactivate()

    if Utils and type(Utils.setOnClashOn) == "function" then
        Utils.setOnClashOn(nil)
    end
end

function AutoClash.resetState()
    State.enabled = false
    State.active = false
    State.activeAt = 0
    State.lastValidAt = 0
    State.lastTargetId = nil
    State.wasMeTarget = false
    State.lostMeAt = 0
    State.physicalDotEma = 0
    State.lastFireAt = -math.huge
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table"
        or not deps.GameInfo
        or not deps.Utils
        or not deps.AutoParry
        or type(deps.AutoParry.fire) ~= "function"
        or type(deps.AutoParry.isTargeted) ~= "function"
        or type(deps.AutoParry.getParryRadius) ~= "function"
    then
        return false
    end

    GameInfo = deps.GameInfo
    Utils = deps.Utils
    AutoParry = deps.AutoParry
    AutoClash.resetState()

    return true
end

return AutoClash
