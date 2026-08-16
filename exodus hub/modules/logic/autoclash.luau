-- [[ Auto Clash ]]

local AutoClash = {}
local GameInfo
local Utils
local AutoParry

-- tuning
local RELEASE_HOLD_TIME = 0.25
local TARGET_RETURN_WINDOW_MIN = 0.170
local TARGET_RETURN_WINDOW_MAX = 0.280
local TARGET_RETURN_SPEED_MIN = 60
local TARGET_RETURN_SPEED_MAX = 200

local PHYSICAL_DOT_EMA = 0.25
local PHYSICAL_DOT_THRESHOLD = 0.14
local PHYSICAL_RADIUS_SLACK = 1.22
local ACTIVATION_RADIUS_MULTIPLIER = 1.32
local SYNC_RADIUS_MULTIPLIER = 1.05
local RELEASE_RADIUS_MULTIPLIER = 1.15

-- state
local State = {
    enabled = false,
    activeAt = 0,
    lastValidAt = 0,
    lastTargetId = nil,
    wasLocalTarget = false,
    lostLocalTargetAt = 0,
    physicalDotEma = 0,
}

local heartbeatConnection

-- helpers
local function now()
    return Utils.now()
end

local function getConfig()
    return Utils.getConfig()
end

local function isEnabled()
    return getConfig().AutoClash == true
end

local function isManualSpamActive()
    return Utils.isManualSpamActive() == true
end

local function isAutoSpamActive()
    return Utils.isAutoSpamActive() == true
end

local function isBallTargeted()
    return type(AutoParry) == "table"
        and type(AutoParry.isTargeted) == "function"
        and AutoParry.isTargeted() == true
end

local function setAutoSpamActive(value)
    Utils.setAutoSpamActive(value)
end

local function getLocalPlayer()
    return Utils.getLocalPlayer()
end

local function getBall()
    return GameInfo.getBall()
end

local function getBallSpeed(ball, time)
    return GameInfo.ballSpeed(ball, time)
end

local function getBallPosition(ball, time)
    return GameInfo.ballPos(ball, time)
end

local function getParryRadius(speed, time)
    local radius = AutoParry.getParryRadius(speed, time)

    if type(radius) == "number" and radius > 0 then
        return radius
    end

    return nil
end

local function distance(positionA, positionB)
    if typeof(positionA) ~= "Vector3" or typeof(positionB) ~= "Vector3" then
        return nil
    end

    local ok, value = pcall(function()
        return (positionA - positionB).Magnitude
    end)

    return ok and type(value) == "number" and value or nil
end

local function getContext(time, humanoidRootPart, ball)
    if not (humanoidRootPart and humanoidRootPart.Parent and ball and ball.Parent) then
        return nil
    end

    local speed = getBallSpeed(ball, time)
    local position = getBallPosition(ball, time)
    local radius = getParryRadius(speed, time)

    if not position or not radius then
        return nil
    end

    return {
        time = time,
        humanoidRootPart = humanoidRootPart,
        ball = ball,
        position = position,
        speed = speed,
        parryRadius = radius,
        activationRadius = radius * ACTIVATION_RADIUS_MULTIPLIER,
        releaseRadius = radius * RELEASE_RADIUS_MULTIPLIER,
    }
end

local function ballInRange(context, radius)
    if not context or type(radius) ~= "number" or radius <= 0 then
        return false
    end

    local currentPosition = context.humanoidRootPart.Position
    local currentDistance = distance(currentPosition, context.position)

    return type(currentDistance) == "number" and currentDistance <= radius
end

local function hasOpponentInRange(position, radius)
    if typeof(position) ~= "Vector3" or type(radius) ~= "number" or radius <= 0 then
        return false
    end

    local localPlayer = getLocalPlayer()

    for _, player in ipairs(Utils.getPlayers():GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")

            local currentDistance = root
                and root.Parent
                and distance(position, root.Position)

            if type(currentDistance) == "number" and currentDistance <= radius then
                return true
            end
        end
    end

    return false
end

local function targetReturnWindow(speed)
    if speed <= TARGET_RETURN_SPEED_MIN then
        return TARGET_RETURN_WINDOW_MAX
    end

    if speed >= TARGET_RETURN_SPEED_MAX then
        return TARGET_RETURN_WINDOW_MIN
    end

    local alpha = (speed - TARGET_RETURN_SPEED_MIN)
        / (TARGET_RETURN_SPEED_MAX - TARGET_RETURN_SPEED_MIN)

    return TARGET_RETURN_WINDOW_MAX
        + (TARGET_RETURN_WINDOW_MIN - TARGET_RETURN_WINDOW_MAX) * alpha
end

local function physicalApproach(context)
    if not context or not isBallTargeted() then
        State.physicalDotEma = 0
        return false
    end

    local ok, velocity = pcall(function()
        return context.ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" or velocity.Magnitude <= 1 then
        State.physicalDotEma = 0
        return false
    end

    local offset = context.humanoidRootPart.Position - context.position
    local currentDistance = offset.Magnitude

    if currentDistance < 0.001 then
        State.physicalDotEma = 0
        return false
    end

    if currentDistance <= context.activationRadius * PHYSICAL_RADIUS_SLACK then
        local approachingSpeed = velocity:Dot(offset.Unit)

        State.physicalDotEma = State.physicalDotEma * (1 - PHYSICAL_DOT_EMA)
            + approachingSpeed * PHYSICAL_DOT_EMA
    else
        State.physicalDotEma = 0
    end

    return currentDistance <= context.activationRadius
        and State.physicalDotEma > PHYSICAL_DOT_THRESHOLD
end

-- state transitions
local function activate(time)
    State.activeAt = time
    State.lastValidAt = time
    setAutoSpamActive(true)
end

local function deactivate()
    State.activeAt = 0
    State.lastValidAt = 0
    State.physicalDotEma = 0
    setAutoSpamActive(false)
end

local function shouldRelease(time, context)
    if not context then
        return true
    end

    if not isBallTargeted() then
        return true
    end

    if not ballInRange(context, context.releaseRadius) then
        return true
    end

    if not hasOpponentInRange(
        context.humanoidRootPart.Position,
        context.releaseRadius
    ) then
        return true
    end

    return time - math.max(State.lastValidAt, State.activeAt) >= RELEASE_HOLD_TIME
end

local function tryActivateFromSync(time, targetId, previousTarget)
    local localPlayer = getLocalPlayer()

    if not localPlayer
        or type(targetId) ~= "number"
        or targetId ~= localPlayer.UserId
        or previousTarget == targetId
    then
        return false
    end

    local character = localPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local ball = getBall()
    local context = getContext(time, root, ball)

    if context and ballInRange(context, context.parryRadius * SYNC_RADIUS_MULTIPLIER) then
        activate(time)
        return true
    end

    return false
end

-- events
function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end

    local time = now()

    if not isEnabled() or isManualSpamActive() then
        State.enabled = false
        deactivate()
        return
    end

    State.enabled = true

    if data.Teleported == true then
        deactivate()
        return
    end

    local targetId = data.TargetPlayerID

    if type(targetId) ~= "number" then
        if State.wasLocalTarget and State.lostLocalTargetAt == 0 then
            State.lostLocalTargetAt = time
        end

        return
    end

    local previousTarget = State.lastTargetId
    State.lastTargetId = targetId
    tryActivateFromSync(time, targetId, previousTarget)

    local localPlayer = getLocalPlayer()

    if not localPlayer then
        return
    end

    if targetId == localPlayer.UserId then
        if State.lostLocalTargetAt > 0 then
            local character = localPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local ball = getBall()
            local context = getContext(time, root, ball)
            local elapsed = time - State.lostLocalTargetAt

            if elapsed <= targetReturnWindow(context and context.speed or 0)
                and context
                and ballInRange(context, context.activationRadius)
            then
                activate(time)
            end
        end

        State.wasLocalTarget = true
        State.lostLocalTargetAt = 0
    elseif State.wasLocalTarget then
        State.lostLocalTargetAt = time
    end
end

-- character runtime
local function tickCharacter(character)
    if not isEnabled() or isManualSpamActive() then
        State.enabled = false
        deactivate()
        return
    end

    State.enabled = true

    if not (character and character.Parent) then
        deactivate()
        return
    end

    local root = character:FindFirstChild("HumanoidRootPart")

    if not (root and root.Parent) then
        deactivate()
        return
    end

    local ball = getBall()
    local time = now()
    local context = getContext(time, root, ball)

    if not context then
        deactivate()
        return
    end

    if isAutoSpamActive() then
        if isBallTargeted()
            and ballInRange(context, context.releaseRadius)
            and hasOpponentInRange(root.Position, context.releaseRadius)
        then
            State.lastValidAt = time
        end

        if shouldRelease(time, context) then
            deactivate()
        end
    elseif physicalApproach(context) then
        activate(time)
    end
end

-- lifecycle
function AutoClash.bindCharacter(character)
    if not (character and character.Parent) then
        return false
    end

    AutoClash.detachCharacter()

    heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function()
        tickCharacter(character)
    end)

    Utils.trackCharacter(heartbeatConnection)
    return true
end

function AutoClash.detachCharacter()
    if heartbeatConnection then
        pcall(heartbeatConnection.Disconnect, heartbeatConnection)
        Utils.untrackCharacter(heartbeatConnection)
        heartbeatConnection = nil
    end

    AutoClash.resetState()
end

function AutoClash.resetState()
    State.enabled = false
    State.activeAt = 0
    State.lastValidAt = 0
    State.lastTargetId = nil
    State.wasLocalTarget = false
    State.lostLocalTargetAt = 0
    State.physicalDotEma = 0
    setAutoSpamActive(false)
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table"
        or type(deps.GameInfo) ~= "table"
        or type(deps.GameInfo.getBall) ~= "function"
        or type(deps.GameInfo.ballPos) ~= "function"
        or type(deps.GameInfo.ballSpeed) ~= "function"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.now) ~= "function"
        or type(deps.Utils.getConfig) ~= "function"
        or type(deps.Utils.getLocalPlayer) ~= "function"
        or type(deps.Utils.getPlayers) ~= "function"
        or type(deps.Utils.isManualSpamActive) ~= "function"
        or type(deps.Utils.isAutoSpamActive) ~= "function"
        or type(deps.Utils.setAutoSpamActive) ~= "function"
        or type(deps.Utils.getRunService) ~= "function"
        or type(deps.Utils.trackCharacter) ~= "function"
        or type(deps.Utils.untrackCharacter) ~= "function"
        or type(deps.AutoParry) ~= "table"
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
