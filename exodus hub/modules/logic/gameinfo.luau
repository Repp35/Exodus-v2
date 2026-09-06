-- [[ GameInfo ]]

local GameInfo = {}
local Utils
local Players
local Workspace

-- tuning
local BALL_CACHE_TTL = 0.5
local SYNC_FRESH_TIME = 1.0
local ABILITY_RETRY_TIME = 2.0
local SNAPSHOT_SCHEMA = 1

-- state
local State = {
    ball = nil,
    ballAt = 0,
    speed = 0,
    speedAt = 0,
    realPosition = Vector3.new(0, 0, 0),
    hasRealPosition = false,
    target = nil,
    targetAt = 0,
    lastSyncAt = 0,
    positionAt = 0,
    deflectDirection = Vector3.new(0, 0, 0),
}
-- cache de character/root (evita lookup toda hora, atualiza por ancestry)
local cachedCharacter = nil
local cachedRoot = nil
local function clearSyncState()
    State.speed = 0
    State.speedAt = 0
    State.realPosition = Vector3.new(0, 0, 0)
    State.hasRealPosition = false
    State.target = nil
    State.targetAt = 0
    State.lastSyncAt = 0
    State.positionAt = 0
    State.deflectDirection = Vector3.new(0, 0, 0)
end

-- reset
local function resetState()
    State.ball = nil
    State.ballAt = 0
    clearSyncState()
    cachedCharacter = nil
    cachedRoot = nil
end

-- ball
local function isBall(instance)
    return typeof(instance) == "Instance"
        and instance.Parent ~= nil
        and instance:IsA("BasePart")
        and instance.Name == "GameBall"
end
local function setBall(ball)
    if isBall(ball) then
        if State.ball ~= ball then
            clearSyncState()
        end
        State.ball = ball
        State.ballAt = Utils.now()
    end
end
local function clearBall(ball)
    if State.ball == ball then
        State.ball = nil
        State.ballAt = Utils.now()
        clearSyncState()
    end
end
local function getBall()
    local time = Utils.now()
    local cached = State.ball
    if cached and cached.Parent ~= nil and time - State.ballAt < BALL_CACHE_TTL then
        return cached
    end
    -- checa rápido (não recursivo) antes de pagar o preço do recursivo
    local ball = Workspace:FindFirstChild("GameBall")
    if not ball then
        -- fallback recursivo só se não achou direto (1x por spawn)
        ball = Workspace:FindFirstChild("GameBall", true)
    end
    if isBall(ball) then
        setBall(ball)
        return ball
    end
    State.ball = nil
    State.ballAt = time
    return nil
end

-- motion
local ZERO_VELOCITY = Vector3.new(0, 0, 0)
local function getAssemblyVelocity(ball)
    -- sem pcall: BasePart garante AssemblyLinearVelocity
    local velocity = ball.AssemblyLinearVelocity
    return typeof(velocity) == "Vector3" and velocity or ZERO_VELOCITY
end
local function resolveTime(time)
    return Utils.isFiniteNumber(time) and time or Utils.now()
end
local function ballSpeed(ball, time, velocity)
    if not isBall(ball) then
        return 0
    end
    time = resolveTime(time)
    if State.speedAt > 0
        and time >= State.speedAt
        and time - State.speedAt < SYNC_FRESH_TIME
    then
        return State.speed
    end
    return (velocity or getAssemblyVelocity(ball)).Magnitude
end
local function ballPosition(ball, time, velocity)
    if not isBall(ball) then
        return nil
    end
    time = resolveTime(time)
    local positionAge = time - State.positionAt
    if State.hasRealPosition
        and positionAge >= 0
        and positionAge < SYNC_FRESH_TIME
    then
        if not velocity then
            velocity = getAssemblyVelocity(ball)
        end
        local direction = State.deflectDirection
        if direction.Magnitude <= 0.1 and velocity.Magnitude > 1 then
            direction = velocity
        end
        if direction.Magnitude > 0.1 and State.speed > 0 then
            return State.realPosition + direction.Unit * State.speed * positionAge
        end
        return State.realPosition
    end
    return ball.Position
end

-- target
local function normalizeTargetId(value)
    if Utils.isFiniteNumber(value) then
        return value
    end
    if type(value) == "string" then
        local number = tonumber(value)
        return Utils.isFiniteNumber(number) and number or nil
    end
    return nil
end
local function getTargetAttribute()
    return normalizeTargetId(Workspace:GetAttribute("GameBallTarget"))
end
local function isTargeted(lastTarget, userId)
    -- short-circuit se State.target já bate (caso comum)
    if State.target == userId then
        return true
    end
    if normalizeTargetId(lastTarget) == userId then
        return true
    end
    return getTargetAttribute() == userId
end
local function getSnapshot(lastTarget, time)
    time = resolveTime(time)
    local ball = getBall()
    local ballValid = ball ~= nil and ball.Parent ~= nil
    local rawVelocity
    local rawSpeed = 0
    local rawPosition
    if ballValid then
        rawVelocity = getAssemblyVelocity(ball)
        rawSpeed = ballSpeed(ball, time, rawVelocity)
        rawPosition = ballPosition(ball, time, rawVelocity)
    end
    local validPosition = rawPosition ~= nil
    local rawSyncAge = State.lastSyncAt > 0
        and math.max(0, time - State.lastSyncAt)
        or nil
    local syncFresh = rawSyncAge ~= nil and rawSyncAge <= SYNC_FRESH_TIME
    local syncValid = syncFresh and ballValid
    local normalizedLastTarget = normalizeTargetId(lastTarget)
    local targetId
    if syncValid and State.targetAt == State.lastSyncAt then
        targetId = State.target
    end
    local player = Players.LocalPlayer
    local userId = player and player.UserId or -1
    local targeted = syncValid and targetId ~= nil and isTargeted(lastTarget, userId) or false

    -- approachingSpeed só calcula se tem player e root (cacheados)
    local approachingSpeed
    if rawPosition and rawVelocity and player then
        local root = cachedRoot
        if not root or not root.Parent then
            local character = player.Character
            if character then
                cachedCharacter = character
                root = character:FindFirstChild("HumanoidRootPart")
                cachedRoot = root
            end
        end
        if root and root.Parent then
            local playerPosition = root.Position
            local direction = playerPosition - rawPosition
            local dirMag = direction.Magnitude
            if dirMag > 0 then
                approachingSpeed = rawVelocity:Dot(direction / dirMag)
            end
        end
    end

    return {
        schema = SNAPSHOT_SCHEMA,
        generatedAt = time,
        valid = ballValid and validPosition,
        ball = ballValid and ball or nil,
        ballValid = ballValid,
        position = ballValid and rawPosition or nil,
        velocity = ballValid and rawVelocity or nil,
        speed = ballValid and rawSpeed or nil,
        approachingSpeed = approachingSpeed,
        targetId = targetId,
        lastTarget = normalizedLastTarget,
        targeted = targeted,
        syncAt = syncFresh and State.lastSyncAt or nil,
        syncAge = syncFresh and rawSyncAge or nil,
        syncFresh = syncFresh,
        syncValid = syncValid,
    }
end

-- sync
local function applySync(data)
    if typeof(data) ~= "table" then
        return false
    end
    local time = Utils.now()
    State.speed = 0
    State.speedAt = 0
    if Utils.isFiniteNumber(data.Speed) and data.Speed >= 0 then
        State.speed = data.Speed
        State.speedAt = time
    end
    State.hasRealPosition = false
    State.positionAt = 0
    if typeof(data.RealPosition) == "Vector3" then
        State.realPosition = data.RealPosition
        State.hasRealPosition = true
        State.positionAt = time
    end
    State.deflectDirection = Vector3.new(0, 0, 0)
    if typeof(data.DeflectDirection) == "Vector3" then
        State.deflectDirection = data.DeflectDirection
    end
    State.target = nil
    State.targetAt = 0
    if data.TargetPlayerID ~= nil then
        State.target = normalizeTargetId(data.TargetPlayerID)
        State.targetAt = time
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
    local cooldown = ability.Cooldown
    if Utils.isFiniteNumber(cooldown) then
        return math.max(0, cooldown)
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
        or type(deps.Utils.apiVersion) ~= "function"
        or type(deps.Utils.isFiniteNumber) ~= "function"
        or type(deps.Utils.getPlayers) ~= "function"
        or type(deps.Utils.getReplicatedStorage) ~= "function"
        or type(deps.Utils.getWorkspace) ~= "function"
    then
        return false
    end
    Utils = deps.Utils
    Players = Utils.getPlayers()
    Workspace = Utils.getWorkspace()
    resetState()
    return true
end

-- public api
function GameInfo.getBall()
    return getBall()
end
function GameInfo.getSnapshot(lastTarget, time)
    return getSnapshot(lastTarget, time)
end
function GameInfo.getStatus()
    local snapshot = getSnapshot(nil, Utils.now())
    return {
        schema = Utils.apiVersion(),
        snapshotSchema = SNAPSHOT_SCHEMA,
        generatedAt = snapshot.generatedAt,
        valid = snapshot.valid == true,
        ballValid = snapshot.ballValid == true,
        syncFresh = snapshot.syncFresh == true,
        syncValid = snapshot.syncValid == true,
        targeted = snapshot.targeted == true,
    }
end
function GameInfo.isSnapshotValid(snapshot, time)
    if type(snapshot) ~= "table"
        or snapshot.schema ~= SNAPSHOT_SCHEMA
        or snapshot.valid ~= true
        or snapshot.ballValid ~= true
        or not isBall(snapshot.ball)
        or typeof(snapshot.position) ~= "Vector3"
        or not Utils.isFiniteNumber(snapshot.speed)
        or snapshot.speed < 0
    then
        return false
    end
    time = resolveTime(time)
    if not Utils.isFiniteNumber(snapshot.generatedAt) then
        return false
    end
    local age = time - snapshot.generatedAt
    return age >= 0
        and age <= SYNC_FRESH_TIME
        and snapshot.ball ~= nil
        and snapshot.ball.Parent ~= nil
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
GameInfo.__contract = {
    requires = { Utils = "utils" },
    ballSync = true,
}
return GameInfo
