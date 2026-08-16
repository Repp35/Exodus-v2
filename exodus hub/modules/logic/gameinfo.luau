-- [[ GameInfo ]]

local GameInfo = {}
local Utils
local Players
local Workspace

-- tuning
local BALL_CACHE_TTL = 0.5
local SYNC_FRESH_TIME = 1.0
local ABILITY_RETRY_TIME = 2.0

-- state
local State = {
    ball = nil,
    ballAt = 0,
    speed = 0,
    realPosition = Vector3.new(0, 0, 0),
    hasRealPosition = false,
    target = -1,
    lastSyncAt = 0,
    positionAt = 0,
    deflectDirection = Vector3.new(0, 0, 0),
}

local deflectAbility
local abilityAttempted = false
local abilityCheckedAt = 0

-- reset
local function resetState()
    State.ball = nil
    State.ballAt = 0
    State.speed = 0
    State.realPosition = Vector3.new(0, 0, 0)
    State.hasRealPosition = false
    State.target = -1
    State.lastSyncAt = 0
    State.positionAt = 0
    State.deflectDirection = Vector3.new(0, 0, 0)

    deflectAbility = nil
    abilityAttempted = false
    abilityCheckedAt = 0
end

-- ball
local function isBall(instance)
    return instance
        and instance.Parent
        and instance:IsA("BasePart")
        and instance.Name == "GameBall"
end

local function setBall(ball)
    if isBall(ball) then
        State.ball = ball
        State.ballAt = Utils.now()
    end
end

local function clearBall(ball)
    if State.ball == ball then
        State.ball = nil
        State.ballAt = Utils.now()
    end
end

local function getBall()
    local time = Utils.now()

    if isBall(State.ball) and time - State.ballAt < BALL_CACHE_TTL then
        return State.ball
    end

    local ball = Workspace:FindFirstChild("GameBall", true)

    if isBall(ball) then
        setBall(ball)
        return ball
    end

    State.ball = nil
    State.ballAt = time
    return nil
end

-- motion
local function getAssemblyVelocity(ball)
    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if ok and typeof(velocity) == "Vector3" then
        return velocity
    end

    return Vector3.new(0, 0, 0)
end

local function ballSpeed(ball, time)
    if not isBall(ball) then
        return 0
    end

    time = type(time) == "number" and time or Utils.now()

    if State.speed > 0
        and time >= State.lastSyncAt
        and time - State.lastSyncAt < SYNC_FRESH_TIME
    then
        return State.speed
    end

    return getAssemblyVelocity(ball).Magnitude
end

local function ballPosition(ball, time)
    if not isBall(ball) then
        return nil
    end

    time = type(time) == "number" and time or Utils.now()
    local positionAge = time - State.positionAt

    if State.hasRealPosition
        and positionAge >= 0
        and positionAge < SYNC_FRESH_TIME
    then
        local velocity = getAssemblyVelocity(ball)
        local direction = State.deflectDirection

        if direction.Magnitude <= 0.1 and velocity.Magnitude > 1 then
            direction = velocity
        end

        if direction.Magnitude > 0.1 and State.speed > 0 then
            return State.realPosition + direction.Unit * State.speed * positionAge
        end

        return State.realPosition
    end

    local ok, position = pcall(function()
        return ball.Position
    end)

    if ok and typeof(position) == "Vector3" then
        return position
    end

    return nil
end

-- target
local function normalizeTargetId(value)
    if type(value) == "number" then
        return value
    end

    if type(value) == "string" then
        return tonumber(value)
    end

    return nil
end

local function getTargetAttribute()
    return normalizeTargetId(Workspace:GetAttribute("GameBallTarget"))
end

local function isTargeted(lastTarget)
    local player = Players.LocalPlayer

    if not player then
        return false
    end

    local userId = player.UserId

    return State.target == userId
        or normalizeTargetId(lastTarget) == userId
        or getTargetAttribute() == userId
end

-- sync
local function applySync(data)
    if typeof(data) ~= "table" then
        return false
    end

    local time = Utils.now()

    if type(data.Speed) == "number" and data.Speed >= 0 then
        State.speed = data.Speed
    end

    if typeof(data.RealPosition) == "Vector3" then
        State.realPosition = data.RealPosition
        State.hasRealPosition = true
        State.positionAt = time
    end

    if typeof(data.DeflectDirection) == "Vector3" then
        State.deflectDirection = data.DeflectDirection
    end

    if data.TargetPlayerID ~= nil then
        State.target = normalizeTargetId(data.TargetPlayerID) or -1
    end

    State.lastSyncAt = time
    return true
end

-- ability
local function locateDeflectAbility()
    if deflectAbility and deflectAbility.Parent ~= nil then
        return deflectAbility
    end

    local time = Utils.now()

    if abilityAttempted and time - abilityCheckedAt < ABILITY_RETRY_TIME then
        return nil
    end

    abilityAttempted = true
    abilityCheckedAt = time

    pcall(function()
        local ts = Utils.getReplicatedStorage():FindFirstChild("TS")
        local bindableManager = ts and ts:FindFirstChild("BindableManager")

        if not bindableManager then
            return
        end

        local ok, manager = pcall(require, bindableManager)

        if not ok or type(manager) ~= "table" or type(manager.GetFunction) ~= "function" then
            return
        end

        local getAbility = manager:GetFunction("AbilityManager::GetAbility")

        if not getAbility or type(getAbility.Invoke) ~= "function" then
            return
        end

        for _, name in ipairs({ "Deflect", "Block" }) do
            local okAbility, ability = pcall(getAbility.Invoke, getAbility, name)

            if okAbility
                and ability
                and type(ability.Cooldown) == "number"
                and type(ability.SetCooldown) == "function"
            then
                deflectAbility = ability
                return
            end
        end
    end)

    return deflectAbility
end

local function getDeflectCooldown()
    local ability = locateDeflectAbility()

    if not ability then
        return 0
    end

    local ok, cooldown = pcall(function()
        return ability.Cooldown
    end)

    if ok and type(cooldown) == "number" then
        return cooldown
    end

    return 0
end

-- watcher
local function installBallWatcher(trackConnection)
    if type(trackConnection) ~= "function" then
        return false
    end

    local gameFolder = Workspace:WaitForChild("Game", 30)
    local ballFolder = gameFolder and gameFolder:FindFirstChild("Ball")

    if not ballFolder then
        return false
    end

    trackConnection(ballFolder.ChildAdded:Connect(function(child)
        if child.Name == "GameBall" and child:IsA("BasePart") then
            setBall(child)
        end
    end))

    trackConnection(ballFolder.ChildRemoved:Connect(clearBall))
    setBall(ballFolder:FindFirstChild("GameBall"))

    return true
end

-- setup
function GameInfo.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.now) ~= "function"
        or type(deps.Utils.getPlayers) ~= "function"
        or type(deps.Utils.getReplicatedStorage) ~= "function"
    then
        return false
    end

    Utils = deps.Utils
    Players = Utils.getPlayers()
    Workspace = game:GetService("Workspace")
    resetState()

    return true
end

-- public api
function GameInfo.getBall()
    return getBall()
end

function GameInfo.ballSpeed(ball, time)
    return ballSpeed(ball, time)
end

function GameInfo.ballPos(ball, time)
    return ballPosition(ball, time)
end

function GameInfo.isTargeted(lastTarget)
    return isTargeted(lastTarget)
end

function GameInfo.applySync(data)
    return applySync(data)
end

function GameInfo.installBallWatcher(trackConnection)
    return installBallWatcher(trackConnection)
end

function GameInfo.getDeflectCD()
    return getDeflectCooldown()
end

return GameInfo