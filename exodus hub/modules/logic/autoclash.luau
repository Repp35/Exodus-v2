-- [[ Auto Clash ]]

local AutoClash = {}
local GameInfo
local Utils
local AutoParry

-- tuning
local RELEASE_HOLD_TIME = 0.25
local TARGET_RETURN_MAX_WINDOW = 0.280
local TARGET_RETURN_MIN_WINDOW = 0.170
local TARGET_RETURN_SPEED_LOW = 60
local TARGET_RETURN_SPEED_HIGH = 200

local PHYSICAL_DOT_EMA = 0.25
local PHYSICAL_DOT_THRESHOLD = 0.14
local PHYSICAL_RADIUS_SLACK = 1.22
local ACTIVATION_RADIUS_MULTIPLIER = 1.32
local SYNC_TARGET_RADIUS_MULTIPLIER = 1.05
local DEACTIVATION_RADIUS_MULTIPLIER = 1.15

-- state
local State = {
    enabled = false,
    activeAt = 0,
    lastValidAt = 0,
    lastTargetAt = 0,
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

local function localPlayer()
    return Utils.getLocalPlayer()
end

local function getConfig()
    return Utils.getConfig()
end

local function isEnabled()
    local config = getConfig()
    return type(config) == "table" and config.AutoClash == true
end

local function isManualSpamActive()
    return Utils.isManualSpamActive() == true
end

local function isAutoSpamActive()
    return Utils.isAutoSpamActive() == true
end

local function setAutoSpamActive(value)
    Utils.setAutoSpamActive(value)
end

local function isBallTargeted(context)
    return context and context.targeted == true
end

local function normalizeTargetId(value)
    if type(value) == "number" then
        return value
    end

    if type(value) == "string" then
        return tonumber(value)
    end

    return nil
end

local function getBall()
    return GameInfo.getBall()
end

local function getBallSpeed(ball)
    if not (ball and ball.Parent) then
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

local function distanceBetween(partA, partB)
    if not (partA and partB) then
        return nil
    end

    local ok, distance = pcall(function()
        return (partA.Position - partB.Position).Magnitude
    end)

    return ok and type(distance) == "number" and distance or nil
end

local function ballInRange(humanoidRootPart, ball, distance)
    if not (humanoidRootPart and ball)
        or type(distance) ~= "number"
        or distance <= 0
    then
        return false
    end

    local currentDistance = distanceBetween(humanoidRootPart, ball)
    return type(currentDistance) == "number" and currentDistance <= distance
end

local function opponentInRange(humanoidRootPart, distance)
    if not humanoidRootPart
        or type(distance) ~= "number"
        or distance <= 0
    then
        return false
    end

    local player = localPlayer()

    for _, otherPlayer in ipairs(Utils.getPlayers():GetPlayers()) do
        if otherPlayer ~= player then
            local character = otherPlayer.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local currentDistance = distanceBetween(humanoidRootPart, root)

            if type(currentDistance) == "number" and currentDistance <= distance then
                return true
            end
        end
    end

    return false
end

local function getContext(time, humanoidRootPart, ball)
    if not (humanoidRootPart and humanoidRootPart.Parent and ball and ball.Parent) then
        return nil
    end

    local serverSpeed = GameInfo.ballSpeed(ball, time)
    local parryRadius = AutoParry.getParryRadius(serverSpeed, time)

    if type(parryRadius) ~= "number" or parryRadius <= 0 then
        return nil
    end

    return {
        time = time,
        humanoidRootPart = humanoidRootPart,
        ball = ball,
        targeted = GameInfo.isTargeted(State.lastTargetId) == true,
        parryRadius = parryRadius,
        serverSpeed = serverSpeed,
    }
end

local function activationRadius(context)
    if not context or type(context.parryRadius) ~= "number" then
        return nil
    end

    return context.parryRadius * ACTIVATION_RADIUS_MULTIPLIER
end

local function deactivationRadius(context)
    if not context or type(context.parryRadius) ~= "number" then
        return nil
    end

    return context.parryRadius * DEACTIVATION_RADIUS_MULTIPLIER
end

local function targetReturnWindow(speed)
    if speed >= TARGET_RETURN_SPEED_HIGH then
        return TARGET_RETURN_MIN_WINDOW
    end

    if speed <= TARGET_RETURN_SPEED_LOW then
        return TARGET_RETURN_MAX_WINDOW
    end

    local alpha = (speed - TARGET_RETURN_SPEED_LOW)
        / (TARGET_RETURN_SPEED_HIGH - TARGET_RETURN_SPEED_LOW)

    return TARGET_RETURN_MAX_WINDOW
        + (TARGET_RETURN_MIN_WINDOW - TARGET_RETURN_MAX_WINDOW) * alpha
end

-- physical gate
local function physicalApproach(context)
    local humanoidRootPart = context and context.humanoidRootPart
    local ball = context and context.ball

    if not (humanoidRootPart and humanoidRootPart.Parent and ball and ball.Parent) then
        State.physicalDotEma = 0
        return false
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
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

    local offset = humanoidRootPart.Position - ball.Position
    local currentDistance = offset.Magnitude

    if currentDistance < 0.001 then
        State.physicalDotEma = 0
        return false
    end

    local radius = activationRadius(context)

    if not radius then
        State.physicalDotEma = 0
        return false
    end

    local approachingSpeed = velocity:Dot(offset.Unit)

    if currentDistance <= radius * PHYSICAL_RADIUS_SLACK then
        State.physicalDotEma = State.physicalDotEma * (1 - PHYSICAL_DOT_EMA)
            + approachingSpeed * PHYSICAL_DOT_EMA
    else
        State.physicalDotEma = 0
    end

    return currentDistance <= radius
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

local function shouldDeactivate(time, context)
    if not context or not context.humanoidRootPart or not context.ball then
        return true
    end

    if not isBallTargeted(context) then
        return true
    end

    local radius = deactivationRadius(context)

    if not radius then
        return true
    end

    if not ballInRange(context.humanoidRootPart, context.ball, radius) then
        return true
    end

    if not opponentInRange(context.humanoidRootPart, radius) then
        return true
    end

    return time - (State.lastValidAt or State.activeAt or 0) >= RELEASE_HOLD_TIME
end

-- sync gate
local function activateOnCloseTarget(time, targetId, previousTarget)
    local player = localPlayer()

    if not player
        or type(targetId) ~= "number"
        or targetId ~= player.UserId
        or previousTarget == targetId
    then
        return false
    end

    local character = player.Character
    local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
    local ball = getBall()
    local context = getContext(time, humanoidRootPart, ball)
    local radius = context and context.parryRadius

    if not context or type(radius) ~= "number" or radius <= 0 then
        return false
    end

    if not ballInRange(humanoidRootPart, ball, radius * SYNC_TARGET_RADIUS_MULTIPLIER) then
        return false
    end

    activate(time)
    return true
end

local function onTargetChanged(targetId)
    local time = now()
    local previousTarget = State.lastTargetId

    State.lastTargetAt = time
    State.lastTargetId = targetId
    activateOnCloseTarget(time, targetId, previousTarget)

    local player = localPlayer()

    if not player or type(targetId) ~= "number" then
        if State.wasLocalTarget and State.lostLocalTargetAt == 0 then
            State.lostLocalTargetAt = time
        end

        return
    end

    if targetId == player.UserId then
        local lostAt = State.lostLocalTargetAt or 0

        if lostAt > 0 then
            local character = player.Character
            local humanoidRootPart = character and character:FindFirstChild("HumanoidRootPart")
            local ball = getBall()
            local speed = getBallSpeed(ball)
            local elapsed = time - lostAt

            if humanoidRootPart
                and ball
                and ball.Parent
                and elapsed <= targetReturnWindow(speed)
            then
                local context = getContext(time, humanoidRootPart, ball)
                local radius = activationRadius(context)

                if radius and ballInRange(humanoidRootPart, ball, radius) then
                    activate(time)
                end
            end
        end

        State.wasLocalTarget = true
        State.lostLocalTargetAt = 0
        return
    end

    if State.wasLocalTarget then
        State.lostLocalTargetAt = time
    end
end

-- sync
function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end

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

    onTargetChanged(normalizeTargetId(data.TargetPlayerID))
end

-- runtime
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

    local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")

    if not (humanoidRootPart and humanoidRootPart.Parent) then
        deactivate()
        return
    end

    local ball = getBall()
    local time = now()
    local context = getContext(time, humanoidRootPart, ball)

    if not context then
        deactivate()
        return
    end

    if isAutoSpamActive() then
        local radius = deactivationRadius(context)

        if isBallTargeted(context)
            and radius
            and ballInRange(humanoidRootPart, ball, radius)
            and opponentInRange(humanoidRootPart, radius)
        then
            State.lastValidAt = time
        end

        if shouldDeactivate(time, context) then
            deactivate()
        end
    elseif isBallTargeted(context) and physicalApproach(context) then
        activate(time)
    else
        State.physicalDotEma = 0
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
    State.lastTargetAt = 0
    State.lastTargetId = nil
    State.wasLocalTarget = false
    State.lostLocalTargetAt = 0
    State.physicalDotEma = 0
    setAutoSpamActive(false)
end

function AutoClash.getState()
    return {
        enabled = State.enabled,
        active = isAutoSpamActive(),
        activeAt = State.activeAt,
        lastValidAt = State.lastValidAt,
        lastTargetAt = State.lastTargetAt,
        lastTargetId = State.lastTargetId,
    }
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table"
        or type(deps.GameInfo) ~= "table"
        or type(deps.GameInfo.getBall) ~= "function"
        or type(deps.GameInfo.ballSpeed) ~= "function"
        or type(deps.GameInfo.isTargeted) ~= "function"
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
