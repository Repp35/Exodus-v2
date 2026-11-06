local AutoParry = {}
local utils, gameInfo, remote
local state = {
    phase = "detached", reason = "initial", generation = 0, lifeGeneration = 0, alive = false, bound = false,
    player = nil, character = nil, root = nil, connections = {},
    fired = false, awaySeen = false, cycle = 0, target = -1, targetKnown = false,
    lastTargeted = false,
    teleported = false, teleportSequence = nil, sequence = nil,
    lastBall = nil, speed = 0, distance = 0, approaching = false, ping = 0, pingAt = 0,
    lastFireAt = 0, lastErrorAt = -math.huge, clicks = {}, returns = {}, awayAt = nil, awayTarget = nil,
}
local BASE_RADIUS, BASE_WINDOW, MIN_WINDOW, BONUS_CAP = 8.5, 0.50, 0.23, 7.5
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function vector(value) return typeof(value) == "Vector3" end
local function clock() return os.clock() end
local function phase(value, reason)
    if state.phase == value and state.reason == reason then return end
    local previous = state.phase
    state.phase, state.reason = value, reason
    if utils and type(utils.recordTransition) == "function" then utils.recordTransition("AutoParry", previous, value, reason) end
end
local function track(connection)
    state.connections[#state.connections + 1] = connection
    utils.trackCharacter(connection)
end
local function disconnect()
    for i = #state.connections, 1, -1 do
        local connection = state.connections[i]
        if utils then utils.untrackCharacter(connection) end
        connection:Disconnect()
        state.connections[i] = nil
    end
end
local function resetTracking()
    state.fired, state.awaySeen, state.cycle = false, false, 0
    state.target, state.targetKnown, state.lastTargeted = -1, false, false
    state.teleported, state.teleportSequence, state.sequence = false, nil, nil
    state.lastBall, state.speed, state.distance, state.approaching = nil, 0, 0, false
    state.ping, state.pingAt, state.lastFireAt = 0, 0, 0
    state.awayAt, state.awayTarget = nil, nil
    table.clear(state.clicks); table.clear(state.returns)
end
local function detach(reason)
    state.generation += 1
    disconnect()
    state.lifeGeneration += 1
    state.alive, state.bound, state.character, state.root = false, false, nil, nil
    resetTracking()
    phase("detached", reason)
end
local function rangeBonus()
    if not state.alive or not state.bound then return 0 end
    local ok, range = pcall(gameInfo.getDeflectRange)
    return ok and finite(range) and math.clamp(range - BASE_RADIUS, 0, BONUS_CAP) or 0
end
local function resilience()
    local bonus = rangeBonus()
    return { stack = math.floor(bonus / 0.225 + 0.5), size = bonus, perParry = 0.225, cap = BONUS_CAP,
        maxStack = math.ceil(BONUS_CAP / 0.225), source = "DeflectRange" }
end
local function configuredFactor()
    local factor = utils and tonumber(utils.getConfigValue("AutoParryWindowFactor"))
    return finite(factor) and math.clamp(factor, 0, 1) or 0.5
end
local function minimumBallSpeed()
    local low = gameInfo and gameInfo.getBallSpeedLimits()
    return finite(low) and math.max(low * 0.375, 1) or 1
end
local function radius(speed, factor, baseWindow)
    speed = finite(speed) and math.max(speed, 0) or 0
    local low, high
    if gameInfo then low, high = gameInfo.getBallSpeedLimits() end
    if not finite(low) or not finite(high) or high <= low then low, high = 16, 600 end
    local fraction = math.clamp((speed - low) / (high - low), 0, 1)
    local window = BASE_WINDOW + (MIN_WINDOW - BASE_WINDOW) * fraction
    if baseWindow == "game" and gameInfo then
        local actual = gameInfo.getDeflectWindow(speed)
        if finite(actual) and actual > 0 then window = actual end
    elseif finite(baseWindow) and baseWindow > 0 then window = baseWindow end
    factor = tonumber(factor)
    if not finite(factor) then factor = configuredFactor() end
    factor = math.clamp(factor, 0, 1)
    local ping = finite(state.ping) and math.max(state.ping, 0) or 0
    local base = BASE_RADIUS + rangeBonus()
    return {
        fullRadius = base + speed * (window + ping) * factor,
        pureRadius = BASE_RADIUS, noWindowParryRadius = base, pingRadius = speed * ping * factor,
        deflectWindow = window, effectiveWindow = (window + ping) * factor,
        leadTime = window + ping, windowFactor = factor,
    }
end
local function samplePing(time)
    if time >= state.pingAt and time - state.pingAt < 0.25 then return end
    state.pingAt = time
    local ok, value = pcall(gameInfo.getLocalPing)
    if ok and finite(value) and value >= 0 then state.ping = value end
end
local function appendRecent(list, item)
    list[#list + 1] = item
    while #list > 100 do table.remove(list, 1) end
end
-- Sequence numbers are 16-bit and may wrap; older packets cannot undo a newer target.
local function sequenceOrder(incoming)
    if not finite(incoming) or incoming < 0 or incoming >= 65536 or incoming % 1 ~= 0 then
        return nil
    end
    if state.sequence == nil then return "new" end
    local delta = (incoming - state.sequence) % 65536
    if delta == 0 then return "same" end
    return delta < 32768 and "new" or "old"
end

local function observeTarget(target, time)
    if not state.player or not finite(target) then return end
    if target == state.target and state.targetKnown then return end

    local me, previous = state.player.UserId, state.target
    state.lastTargeted = previous == me

    if previous == me and target ~= me then
        state.awaySeen = true
        state.awayAt = time
        state.awayTarget = target > 0 and target or nil
    elseif target == me and previous ~= me and state.awaySeen then
        if state.awayAt and state.awayTarget == previous and time >= state.awayAt then
            appendRecent(state.returns, { at = time, interval = time - state.awayAt })
        end
        state.fired = false
        state.awaySeen = false
        state.cycle += 1
        state.awayAt, state.awayTarget = nil, nil
    end

    state.target, state.targetKnown = target, true
end

local function observeSnapshot(snapshot, time)
    local order = sequenceOrder(snapshot.syncSequence)
    if order == "old" then return false end
    -- Same-sequence or unsequenced snapshots must not contradict a newer BallSync.
    if order ~= "new" and state.sequence ~= nil and state.targetKnown and snapshot.targetId ~= state.target then
        return false
    end
    if order == "new" then state.sequence = snapshot.syncSequence end
    observeTarget(snapshot.targetId, time)
    return true
end
local function request(reason)
    if state.fired or not state.player or state.target ~= state.player.UserId then return false end

    local generation, cycle = state.generation, state.cycle
    local boundUtils, boundRemote = utils, remote
    local firedAt, speed, distance = clock(), state.speed, state.distance

    -- Lock before invoking Remote: Deflect() may cause reentrant BallSync events.
    state.fired, state.lastFireAt = true, firedAt
    local function sameCycle()
        return state.generation == generation and state.cycle == cycle
            and utils == boundUtils and remote == boundRemote
            and state.alive and state.bound and state.fired
            and state.player ~= nil and state.target == state.player.UserId
    end
    local function allowed()
        return sameCycle() and not state.teleported
            and boundUtils.isActive() and not boundUtils.isSpamActive()
            and (reason == "manual_parry" or boundUtils.getConfigValue("AutoParry") ~= false)
    end

    local ok, sent, detail = pcall(boundRemote.fireParry, 1, allowed)
    if not sameCycle() then return false end

    if not ok or sent ~= true then
        -- Unlock only when Remote did not dispatch. Never unlock a successful click
        -- just because the spam/config state changed while Deflect() executed.
        state.fired = false
        local now = clock()
        if now - state.lastErrorAt >= 1 then
            state.lastErrorAt = now
            boundUtils.recordError("AutoParry", tostring(ok and (detail or "Deflect indisponível") or sent))
        end
        return false
    end

    local configured = configuredFactor()
    if configured > 0 then
        local geometry = radius(speed, configured)
        local denominator = speed * geometry.leadTime
        local used = denominator > 0
            and math.clamp((distance - geometry.noWindowParryRadius) / denominator, 0, configured)
            or configured
        appendRecent(state.clicks, { at = firedAt, factor = used, configured = configured, speed = speed })
    end
    phase("fired", reason)
    return true
end
local function tick(character, root, generation)
    if generation ~= state.generation or not state.alive or not state.bound or not character.Parent or not root.Parent then return end
    if not utils.isActive() or utils.getConfigValue("AutoParry") == false then return end
    local time = clock()
    samplePing(time)
    local value = gameInfo.getSnapshotAt(time)
    if generation ~= state.generation or not state.bound or not state.alive then return end
    if not gameInfo.isSnapshotValid(value) then phase("waiting", "snapshot_indisponível"); return end
    if not observeSnapshot(value, time) then
        phase("waiting", "stale_snapshot")
        return
    end
    if utils.isSpamActive() then phase("waiting", "spam_active"); return end
    if state.teleported or value.teleported then phase("waiting", "teleport_lock"); return end
    if not state.player or value.targetId ~= state.player.UserId then phase("waiting", "not_target"); return end
    if state.fired then phase("waiting", "target_already_parried"); return end
    local position, velocity, rootPosition = value.position, value.velocity, gameInfo.getRootPosition(root)
    if not vector(position) or not vector(velocity) or not vector(rootPosition) then return end
    if typeof(value.ball) ~= "Instance" or not value.ball.Parent or not value.ball:IsA("BasePart") then return end
    state.lastBall, state.speed = value.ball, velocity.Magnitude
    state.distance = (rootPosition - position).Magnitude
    state.approaching = velocity:Dot(rootPosition - position) > 0
    if state.distance <= radius(state.speed, configuredFactor()).fullRadius then request("parry_requested") end
end
function AutoParry.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.Remote) ~= "table" then
        return false, "dependências inválidas"
    end
    for name, methods in pairs(AutoParry.__contract.requiresMethods) do
        for _, method in ipairs(methods) do
            if type(deps[name][method]) ~= "function" then
                return false, "dependência ausente: " .. name .. "." .. method
            end
        end
    end
    detach("setup")
    utils, gameInfo, remote = deps.Utils, deps.GameInfo, deps.Remote
    state.player = utils.getLocalPlayer()
    if not state.player then return false, "Players.LocalPlayer indisponível" end
    resetTracking()
    phase("detached", "setup_complete")
    return true
end
function AutoParry.bindCharacter(character)
    if not utils or not gameInfo or not remote then return false, "dependências não inicializadas" end
    detach("rebind_start")
    if not character or not character.Parent then return false, "personagem indisponível" end
    local generation = state.generation
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
    if generation ~= state.generation or not root or not root.Parent or not root:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
    local service, player = utils.getRunService(), utils.getLocalPlayer()
    local signal = service and (service.PostSimulation or service.Heartbeat)
    if not signal or not player then return false, "RunService ou jogador indisponível" end
    state.root, state.character, state.player, state.alive, state.bound = root, character, player, true, true
    resetTracking()
    phase("waiting", "character_bound")
    gameInfo.getDeflectCooldownState()
    local ok, err = pcall(function()
        track(signal:Connect(function() tick(character, root, generation) end))
        track(character.AncestryChanged:Connect(function(_, parent)
            if not parent and generation == state.generation then detach("character_removed") end
        end))
    end)
    if not ok then
        detach("bind_failed")
        return false, tostring(err)
    end
    return true
end
function AutoParry.fire()
    if not state.alive or not state.bound or state.fired or state.teleported then return false end
    if not state.approaching or state.speed < minimumBallSpeed() then return false end
    return request("manual_parry")
end
function AutoParry.resetState() detach("reset") end
function AutoParry.detachCharacter() detach("detach") end
function AutoParry.teardown() detach("teardown"); utils, gameInfo, remote, state.player = nil, nil, nil, nil end
function AutoParry.onBallSync(data)
    if type(data) ~= "table" or not state.alive or not state.bound then return end
    local sequence = data.Sequence or data.TeleportSequence
    if sequence == nil and gameInfo.getSyncSequence and data == gameInfo.getSyncData() then
        sequence = gameInfo.getSyncSequence()
    end
    local order = sequenceOrder(sequence)
    if order == "same" or order == "old" then return true end
    if order == "new" then state.sequence = sequence end
    if data.Teleported == true then
        state.teleported, state.teleportSequence, state.fired, state.awaySeen = true, sequence, false, false
        state.cycle += 1
        state.lastFireAt = 0
        state.target, state.targetKnown, state.lastBall = -1, false, nil
        state.speed, state.distance, state.approaching = 0, 0, false
        state.awayAt, state.awayTarget = nil, nil
        table.clear(state.clicks); table.clear(state.returns)
        phase("waiting", "teleport_lock")
        return true
    end
    if state.teleported and state.teleportSequence then
        local current = gameInfo.getSyncSequence()
        if type(current) ~= "number" or (current - state.teleportSequence) % 65536 >= 32768 then return true end
    end
    state.teleported, state.teleportSequence = false, nil
    local target = data.TargetPlayerID ~= nil and (tonumber(data.TargetPlayerID) or -1) or gameInfo.getTargetId()
    -- An unsequenced fallback cannot overturn a newer sequenced observation.
    if order == nil and state.sequence ~= nil and state.targetKnown and target ~= state.target then
        return true
    end
    observeTarget(target, clock())
    if target <= 0 then
        state.target, state.targetKnown = target, true
        if target == -1 then state.lastBall = nil end
    end
    if state.player and target == state.player.UserId and state.character and state.root and not state.fired then
        tick(state.character, state.root, state.generation)
    end
    return true
end
function AutoParry.getTargetStatus()
    return { armed = not state.fired, firedForTarget = state.fired, lastTargeted = state.lastTargeted,
        targeted = state.targetKnown and state.player ~= nil and state.target == state.player.UserId,
        approaching = state.approaching,
        targetId = state.target, targetKnown = state.targetKnown, cooldown = gameInfo and gameInfo.getDeflectCooldownState() or nil }
end
local function rootPosition()
    if state.root and state.root.Parent then return gameInfo.getRootPosition(state.root) end
    local character = state.player and state.player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return root and root.Parent and gameInfo.getRootPosition(root) or nil
end
function AutoParry.getTiming(value, time, root, factor, baseWindow)
    if type(value) ~= "table" then return nil end
    root = vector(root) and root or rootPosition()
    local position, velocity = value.position, value.velocity
    if gameInfo and typeof(value.ball) == "Instance" and value.ball.Parent and value.ball:IsA("BasePart") then
        if not vector(position) then position = gameInfo.getBallPosition(value.ball) end
        if value.ball == state.lastBall then
            local current = gameInfo.getBallVelocity(value.ball)
            if vector(current) and current.Magnitude > 0.1 then velocity = current end
        end
        if not vector(velocity) then velocity = gameInfo.getBallVelocity(value.ball) end
    end
    if not vector(position) or not vector(root) then return nil end
    local speed = vector(velocity) and velocity.Magnitude or tonumber(value.speed) or 0
    if not finite(speed) or speed < 0 then return nil end
    local geometry = radius(speed, factor, baseWindow)
    local delta, distance = root - position, (root - position).Magnitude
    local distanceToRadius = distance - geometry.fullRadius
    return {
        distance = distance, speed = speed, velocity = velocity, parryRadius = geometry.fullRadius, fullRadius = geometry.fullRadius,
        pureRadius = geometry.pureRadius, noWindowParryRadius = geometry.noWindowParryRadius, pingRadius = geometry.pingRadius,
        resilienceBonus = geometry.noWindowParryRadius - BASE_RADIUS, leadTime = geometry.leadTime, deflectWindow = geometry.deflectWindow,
        effectiveWindow = geometry.effectiveWindow, windowFactor = geometry.windowFactor, distanceToParryRadius = distanceToRadius,
        tti = speed > 0 and math.max(distanceToRadius, 0) / speed or math.huge,
        approaching = vector(velocity) and speed >= minimumBallSpeed() and distance > 0 and velocity:Dot(delta) > 0 or false,
        targeted = value.targeted == true,
    }
end
function AutoParry.getRadius(mode, factor, speedOverride, baseWindow)
    if mode ~= "tti" and mode ~= "speed_distance" then mode = "geometry" end
    local speed = tonumber(speedOverride)
    if not finite(speed) or speed < 0 then speed = state.speed end
    local result = radius(speed, factor, baseWindow)
    local tti = speed > 0 and math.max(state.distance - result.fullRadius, 0) / speed or math.huge
    result.mode, result.speed, result.distance, result.tti, result.resilience = mode, speed, state.distance, tti, resilience()
    result.value = mode == "tti" and tti or (mode == "speed_distance" and { speed = speed, distance = state.distance } or result.fullRadius)
    return result
end
function AutoParry.getPressure()
    local time, count, factors, configured, speeds, ratios = clock(), 0, 0, 0, 0, 0
    for i = #state.clicks, 1, -1 do
        local item = state.clicks[i]
        if time < item.at or time - item.at > 3 then table.remove(state.clicks, i)
        else count += 1; factors += item.factor; configured += item.configured; speeds += item.speed; ratios += math.clamp(item.factor / item.configured, 0, 1) end
    end
    local returns, intervals = 0, 0
    for i = #state.returns, 1, -1 do
        local item = state.returns[i]
        if time < item.at or time - item.at > 3 then table.remove(state.returns, i) else returns += 1; intervals += item.interval end
    end
    local latest, lastReturn = state.clicks[#state.clicks], state.returns[#state.returns]
    local currentLevel, factorDrop
    if latest and time >= latest.at and time - latest.at <= 1 and finite(latest.configured) and latest.configured > 0 then
        local ratio = math.clamp(latest.factor / latest.configured, 0, 1)
        currentLevel = 1 - ratio
        if count >= 3 then
            local previous, older = state.clicks[#state.clicks - 1], state.clicks[#state.clicks - 2]
            local earlier = (math.clamp(previous.factor / previous.configured, 0, 1) + math.clamp(older.factor / older.configured, 0, 1)) / 2
            factorDrop = math.max(0, earlier - ratio)
        end
    end
    return { samples = count, cps = count / 3, averageFactor = count > 0 and factors / count or nil,
        configuredFactor = count > 0 and configured / count or nil, averageSpeed = count > 0 and speeds / count or nil,
        returnSamples = returns, averageReturnTime = returns > 0 and intervals / returns or nil,
        level = count >= 3 and returns >= 2 and math.clamp(1 - ratios / count, 0, 1) or nil,
        currentFactor = latest and latest.factor or nil, currentLevel = currentLevel, factorDrop = factorDrop,
        latestReturnTime = lastReturn and lastReturn.interval or nil }
end
function AutoParry.getStatus()
    local geometry = AutoParry.getRadius("geometry", utils and configuredFactor() or 0.5)
    local target = AutoParry.getTargetStatus()
    return {
        schema = utils and utils.apiVersion() or nil,
        api = { name = "AutoParry", version = 10, endpoints = { "getRadius", "getTiming", "getStatus", "getTargetStatus" },
            radiusModes = { "geometry", "tti", "speed_distance" }, defaultWindowFactor = 0.5, windowFactorRange = { min = 0, max = 1 } },
        lifecycle = { phase = state.phase, reason = state.reason, bound = state.bound, alive = state.alive, generation = state.generation, lifeGeneration = state.lifeGeneration },
        radius = geometry, resilience = geometry.resilience,
        timing = { tti = geometry.tti, ti = geometry.tti, speed = state.speed, distance = state.distance,
            distanceToRadius = state.distance - geometry.fullRadius, deflectWindow = geometry.deflectWindow, effectiveWindow = geometry.effectiveWindow,
            leadTime = geometry.leadTime, noWindowParryRadius = geometry.noWindowParryRadius, pingRadius = geometry.pingRadius, approaching = state.approaching },
        ping = { oneWay = state.ping, raw = state.ping, minimum = nil }, target = target, pressure = AutoParry.getPressure(),
        cycle = { fired = state.fired, armed = not state.fired, lastFireAt = state.lastFireAt, lastTTI = geometry.tti },
        config = { baseRadius = BASE_RADIUS, baseWindow = BASE_WINDOW, defaultWindowFactor = 0.5, windowFactorRange = { min = 0, max = 1 }, minBallSpeed = gameInfo and minimumBallSpeed() or 1 },
        timestamp = clock(),
    }
end
AutoParry.__contract = {
    requires = { Remote = "remote", GameInfo = "gameinfo", Utils = "utils" },
    requiresMethods = {
        Remote = { "fireParry" },
        GameInfo = { "getSnapshotAt", "isSnapshotValid", "getSyncData", "getTargetId",
            "getSyncSequence", "getDeflectRange", "getDeflectCooldownState", "getLocalPing",
            "getBallPosition", "getBallVelocity", "getRootPosition", "getBallSpeedLimits",
            "getDeflectWindow" },
        Utils = { "getLocalPlayer", "getRunService", "getConfigValue", "isActive",
            "isSpamActive", "trackCharacter", "untrackCharacter", "recordError" },
    },
    provides = { "setup", "bindCharacter", "detachCharacter", "teardown", "onBallSync", "fire", "resetState", "getRadius", "getTiming", "getTargetStatus", "getPressure", "getStatus" },
    onBallSync = true, bindCharacter = true, version = 10,
}
return AutoParry
