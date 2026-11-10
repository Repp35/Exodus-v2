-- [[ autoparry ]]

-- dependencies
local AutoParry = {}
local utils, gameInfo, remote

-- state
local state = {
	phase = "detached",
	reason = "initial",
	generation = 0,
	lifeGeneration = 0,
	alive = false,
	bound = false,
	player = nil,
	character = nil,
	root = nil,
	connections = {},
	fired = false,
	graceHandled = false,
	localGraceActive = false,
	localGraceUntil = 0,
	awaySeen = false,
	cycle = 0,
	target = -1,
	targetKnown = false,
	lastTargeted = false,
	teleported = false,
	teleportSequence = nil,
	sequence = nil,
	mode = nil,
	lastBall = nil,
	speed = 0,
	distance = 0,
	approaching = false,
	closingSpeed = 0,
	frameAllowance = 0,
	triggerDistance = 0,
	ping = 0,
	pingRaw = nil,
	pingCount = 0,
	lastFireAt = 0,
	lastErrorAt = -math.huge,
	clicks = {},
	returns = {},
	awayAt = nil,
	awayTarget = nil,
}

-- tuning
local T = {
	DEFAULT_WINDOW_FACTOR = 0.40,
	GRACE_COOLDOWN = 0.03,
	GRACE_KILL_DISTANCE = 4,
	PRESSURE_SAMPLE_LIMIT = 100,
	PRESSURE_WINDOW = 3,
	TARGET_SEQUENCE_MODULUS = 65536,
	TARGET_SEQUENCE_HALF = 32768,
	MIN_PARRY_SPEED = 16,
	FRAME_BASE = 1 / 60,
	MAX_FRAME_ALLOWANCE = 0.12,
}

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function vector(value) return typeof(value) == "Vector3" end
local function clock() return os.clock() end
local function phase(value, reason)
	if state.phase == value and state.reason == reason then return end
	local previous = state.phase
	state.phase, state.reason = value, reason
	if previous ~= value and utils and type(utils.recordTransition) == "function" then utils.recordTransition("AutoParry", previous, value, reason) end
end
local function track(connection)
	state.connections[#state.connections + 1] = connection; utils.trackCharacter(connection)
end
local function disconnect()
	for i = #state.connections, 1, -1 do
		local connection = state.connections[i]
		if utils then utils.untrackCharacter(connection) end
		connection:Disconnect(); state.connections[i] = nil
	end
end

-- lifecycle
local function resetTracking()
	state.fired, state.graceHandled, state.localGraceActive, state.awaySeen, state.cycle = false, false, false, false, 0
	state.localGraceUntil = 0
	state.target, state.targetKnown, state.lastTargeted = -1, false, false
	state.teleported, state.teleportSequence, state.sequence = false, nil, nil
	state.mode = nil
	state.lastBall, state.speed, state.distance, state.approaching = nil, 0, 0, false
	state.closingSpeed, state.triggerDistance, state.frameAllowance = 0, 0, 0
	state.ping, state.pingRaw, state.pingCount, state.lastFireAt = 0, nil, 0, 0
	state.awayAt, state.awayTarget = nil, nil
	table.clear(state.clicks); table.clear(state.returns)
end
local function detach(reason)
	state.generation += 1; disconnect(); state.lifeGeneration += 1
	state.alive, state.bound, state.character, state.root = false, false, nil, nil
	resetTracking(); phase("detached", reason)
end

-- geometry
local function rangeBonus()
	if not state.alive or not state.bound then return 0 end
	local _, cap = gameInfo.getDeflectRangeParameters(); local g = gameInfo.getDeflectGeometry(0, 0, 0, false, 0); return g and math.clamp(g.resilienceBonus, 0, cap) or 0
end
local function resilience()
	local bonus = rangeBonus(); local _, cap, step = gameInfo.getDeflectRangeParameters()
	return {
		stack = math.floor(bonus / step + 0.5),
		size = bonus,
		perParry = step,
		cap = cap,
		maxStack = math.ceil(cap / step),
		source = "DeflectRange",
	}
end
local function configuredFactor()
	local factor = utils and tonumber(utils.getConfigValue("AutoParryWindowFactor")); return finite(factor) and math.clamp(factor, 0, 1) or T.DEFAULT_WINDOW_FACTOR
end
local function minimumBallSpeed() return T.MIN_PARRY_SPEED end
local function radius(speed, factor, baseWindow)
	speed = finite(speed) and math.max(speed, 0) or 0; factor = tonumber(factor)
	if not finite(factor) then factor = configuredFactor() end
	factor = math.clamp(factor, 0, 1); return gameInfo.getDeflectGeometry(speed, baseWindow or "ap", factor, false, state.ping)
end

-- telemetry
local function samplePing()
	state.ping, state.pingRaw, state.pingCount = gameInfo.getAveragePing()
end
local function appendRecent(list, item)
	list[#list + 1] = item
	if #list > T.PRESSURE_SAMPLE_LIMIT then table.remove(list, 1) end
end
local function trajectory(position, velocity, rootPosition, nominalSpeed, geometry)
	local delta = rootPosition - position; local distance = delta.Magnitude; local magnitude = velocity.Magnitude; local closing = 0
	if distance > 0 and magnitude > 0 then
		closing = velocity:Dot(delta) / distance
		if finite(nominalSpeed) and nominalSpeed > 0 then closing = math.min(closing, nominalSpeed * 1.1) end
	end
	if not finite(closing) then closing = 0 end
	local threshold = gameInfo.getProjectedDeflectRadius(geometry, closing) or geometry.noWindowParryRadius; return distance, closing, threshold
end

-- target-sync
local function sequenceOrder(incoming)
	if not finite(incoming) or incoming < 0 or incoming >= T.TARGET_SEQUENCE_MODULUS or incoming % 1 ~= 0 then return nil end
	if state.sequence == nil then return "new" end
	local delta = (incoming - state.sequence) % T.TARGET_SEQUENCE_MODULUS
	if delta == 0 then return "same" end
	return delta < T.TARGET_SEQUENCE_HALF and "new" or "old"
end
local function observeTarget(target, time)
	if not state.player or not finite(target) then return end
	if target == state.target and state.targetKnown then return end
	local me, previous = state.player.UserId, state.target; state.lastTargeted = previous == me
	if previous == me and target ~= me then
		state.awaySeen = true; state.awayAt = time; state.awayTarget = target > 0 and target or nil
	elseif target == me and previous ~= me and state.awaySeen then
		if state.awayAt and state.awayTarget == previous and time >= state.awayAt then appendRecent(state.returns, { at = time, interval = time - state.awayAt }) end
		state.fired = false; state.awaySeen = false; state.cycle += 1
		state.awayAt, state.awayTarget = nil, nil
	end
	state.target, state.targetKnown = target, true
end
local function observeSnapshot(snapshot, time)
	local mode = snapshot.mode == "training" and "training" or "match"
	if state.mode ~= mode then
		state.mode, state.sequence, state.target, state.targetKnown = mode, nil, -1, false
		state.fired, state.graceHandled, state.localGraceActive, state.awaySeen, state.teleported, state.teleportSequence =
			false, false, false, false, false, nil
		state.localGraceUntil = 0
		state.awayAt, state.awayTarget = nil, nil
	end
	local order = sequenceOrder(snapshot.syncSequence)
	if order == "old" then return false end
	if order ~= "new" and state.sequence ~= nil and state.targetKnown and snapshot.targetId ~= state.target then return false end
	if order == "new" then state.sequence = snapshot.syncSequence end
	observeTarget(snapshot.targetId, time); return true
end

-- parry
local function request(reason)
	local redirectReturn = reason == "redirect_return"
	if state.fired or not state.player or (not redirectReturn and state.target ~= state.player.UserId) then return false end
	local generation, cycle = state.generation, state.cycle; local boundUtils, boundRemote = utils, remote; local firedAt, speed, distance = clock(), state.speed, state.distance
	state.fired, state.lastFireAt = true, firedAt
	local function sameCycle()
		return state.generation == generation
			and state.cycle == cycle
			and utils == boundUtils
			and remote == boundRemote
			and state.alive
			and state.bound
			and state.fired
			and state.player ~= nil
			and (redirectReturn or state.target == state.player.UserId)
	end
	local function allowed()
		return sameCycle()
			and not state.teleported
			and boundUtils.isActive()
			and not boundUtils.isSpamActive()
			and (reason == "manual_parry" or boundUtils.getConfigValue("AutoParry") ~= false)
	end
	local ok, sent, detail = pcall(boundRemote.fireParry, 1, allowed)
	if not ok then detail, sent = sent, false end
	if not sameCycle() then return false end
	if sent ~= true then
		state.fired = false; phase("waiting", "parry_attempt_failed"); local now = clock()
		if now - state.lastErrorAt >= 1 then state.lastErrorAt = now; boundUtils.recordError("AutoParry", tostring(detail or "Deflect indisponível")) end
		return false
	end
	local configured = configuredFactor()
	if configured > 0 then
		local geometry = radius(speed, configured)
		if geometry then local denominator = speed * geometry.leadTime; local used = denominator > 0 and math.clamp((distance - geometry.noWindowParryRadius) / denominator, 0, configured) or configured; appendRecent(state.clicks, { at = firedAt, factor = used, configured = configured, speed = speed }) end
	end
	phase("fired", reason); return true
end
local function tick(character, root, generation)
	if generation ~= state.generation or not state.alive or not state.bound or not character.Parent or not root.Parent then return end
	if not utils.isActive() or utils.getConfigValue("AutoParry") == false then return end
	local time = clock(); local value = gameInfo.getSnapshotAt(time)
	if generation ~= state.generation or not state.bound or not state.alive then return end
	if not gameInfo.isSnapshotValid(value) then phase("waiting", "snapshot_indisponível"); return end
	if not observeSnapshot(value, time) then phase("waiting", "stale_snapshot"); return end
	if utils.isSpamActive() then phase("waiting", "spam_active"); return end
	if state.teleported or value.teleported then phase("waiting", "teleport_lock"); return end
	if state.fired then phase("waiting", "target_already_parried"); return end
	if value.locked == true then
		state.approaching, state.closingSpeed, state.triggerDistance = false, 0, 0
		phase("waiting", "ball_locked"); return
	end
	local position, velocity, rootPosition = value.position, value.velocity, gameInfo.getRootPosition(root)
	if not vector(position) or not vector(velocity) or not vector(rootPosition) then return end
	if not value.ball.Parent then return end
	local syncSpeed = tonumber(value.syncSpeed); local speed = finite(syncSpeed) and syncSpeed > 0 and syncSpeed or velocity.Magnitude; samplePing(); local fullWindow = radius(speed, 1); local delta = rootPosition - position; local distance = delta.Magnitude; local closing = distance > 0 and velocity:Dot(delta) / distance or 0
	local targeted = value.targetUncertain ~= true and state.player ~= nil and value.targetId == state.player.UserId; local inKillDistance = distance <= T.GRACE_KILL_DISTANCE
	if not targeted or not inKillDistance then
		state.localGraceActive, state.graceHandled, state.localGraceUntil = false, false, 0
	elseif not state.localGraceActive then
		state.localGraceActive, state.graceHandled = true, false
		state.localGraceUntil = time + math.clamp(state.ping + 0.075, 0.075, 0.350)
	end
	local localGrace = state.localGraceActive and time <= state.localGraceUntil and fullWindow ~= nil and distance <= fullWindow.fullRadius
	if localGrace then
		state.lastBall, state.speed, state.distance, state.approaching = value.ball, speed, distance, true
		state.closingSpeed, state.triggerDistance = closing, fullWindow.fullRadius
		if not state.graceHandled and time - state.lastFireAt >= T.GRACE_COOLDOWN then
			if request("local_grace_parry_requested") then state.graceHandled = true end
		end
		return
	end
	if value.targetUncertain == true then phase("waiting", "target_uncertain"); return end
	if not state.player or value.targetId ~= state.player.UserId then phase("waiting", "not_target"); return end
	samplePing(); local geometry = radius(speed, configuredFactor())
	if not geometry then return end
	local distance, closing, threshold = trajectory(position, velocity, rootPosition, speed, geometry); threshold += math.max(closing, 0) * state.frameAllowance
	state.lastBall, state.speed, state.distance, state.approaching = value.ball, speed, distance, closing > 0
	state.closingSpeed, state.triggerDistance = closing, threshold
	if closing > 0 and distance <= threshold then request("parry_requested") end
end

-- setup
function AutoParry.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.Remote) ~= "table" then return false, "dependências inválidas" end
	for name, methods in pairs(AutoParry.__contract.requiresMethods) do
		for _, method in ipairs(methods) do
			if type(deps[name][method]) ~= "function" then return false, "dependência ausente: " .. name .. "." .. method end
		end
	end
	detach("setup"); utils, gameInfo, remote = deps.Utils, deps.GameInfo, deps.Remote; state.player = utils.getLocalPlayer()
	if not state.player then return false, "Players.LocalPlayer indisponível" end
	resetTracking(); phase("detached", "setup_complete"); return true
end
function AutoParry.bindCharacter(character)
	if not utils or not gameInfo or not remote then return false, "dependências não inicializadas" end
	detach("rebind_start")
	if not character or not character.Parent then return false, "personagem indisponível" end
	local generation = state.generation; local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
	if generation ~= state.generation or not root or not root.Parent or not root:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
	local service, player = utils.getRunService(), utils.getLocalPlayer(); local signal = service and (service.PostSimulation or service.Heartbeat)
	if not signal or not player then return false, "RunService ou jogador indisponível" end
	state.root, state.character, state.player, state.alive, state.bound = root, character, player, true, true
	resetTracking(); phase("waiting", "character_bound"); gameInfo.getDeflectCooldownState()
	track(signal:Connect(function(deltaTime)
		if generation ~= state.generation then return end
		if finite(deltaTime) and deltaTime >= 0 then state.frameAllowance = math.clamp(deltaTime - T.FRAME_BASE, 0, T.MAX_FRAME_ALLOWANCE) end
		tick(character, root, generation)
	end))
	track(character.AncestryChanged:Connect(function(_, parent)
		if not parent and generation == state.generation then detach("character_removed") end
	end))
	return true
end
function AutoParry.beginFierce()
	if not state.alive or not state.bound then return nil end
	local target = gameInfo.getTargetId()
	if finite(target) then observeTarget(target, clock()) end
	local token = { generation = state.generation, cycle = state.cycle, previouslyFired = state.fired }; state.fired = true; return token
end
function AutoParry.cancelFierce(token)
	if token and state.generation == token.generation and state.cycle == token.cycle and not token.previouslyFired then state.fired = false end
end
function AutoParry.fire()
	if not state.alive or not state.bound or state.fired or state.teleported then return false end
	if not state.player or state.target ~= state.player.UserId then return false end
	local g = radius(state.speed, configuredFactor())
	if not g or state.distance > g.fullRadius then return false end
	return request("manual_parry")
end
function AutoParry.tryRedirectReturn(value, redirectAt)
	if not state.alive or not state.bound or not state.player or state.teleported then return false end
	if not state.root or not state.root.Parent then return false end
	if not utils.isActive() or utils.isSpamActive() or utils.getConfigValue("AutoParry") == false then return false end
	if not gameInfo.isSnapshotValid(value) or value.teleported or value.locked then return false end
	local time = clock()
	if not observeSnapshot(value, time) then return false end
	if state.fired and finite(redirectAt) and state.lastFireAt >= redirectAt then return true end
	local position, velocity = value.position, value.velocity; local own = gameInfo.getRootPosition(state.root)
	if not vector(position) or not vector(velocity) or not vector(own) then return false end
	samplePing(); local speed = tonumber(value.syncSpeed)
	if not finite(speed) or speed <= 0 then speed = velocity.Magnitude end
	local g = radius(speed, configuredFactor())
	if not g then return false end
	local distance, closing, threshold = trajectory(position, velocity, own, speed, g)
	state.lastBall, state.speed, state.distance, state.approaching = value.ball, speed, distance, closing > 0
	state.closingSpeed, state.triggerDistance = closing, threshold
	if closing <= 0 or distance > threshold then return false end
	local alreadyFired, previousFireAt = state.fired, state.lastFireAt; local generation, cycle = state.generation, state.cycle; state.fired = false; local sent = request("redirect_return")
	if not sent and state.generation == generation and state.cycle == cycle then
		state.fired, state.lastFireAt = alreadyFired, previousFireAt
	end
	return sent
end
function AutoParry.resetState() detach("reset") end
function AutoParry.detachCharacter() detach("detach") end
function AutoParry.teardown()
	detach("teardown")
	utils, gameInfo, remote, state.player = nil, nil, nil, nil
end

-- ball-sync
function AutoParry.onBallSync(data)
	if type(data) ~= "table" or not state.alive or not state.bound then return end
	local currentSnapshot = gameInfo.getSnapshotAt(clock())
	if currentSnapshot and currentSnapshot.mode == "training" then return true end
	local sequence = data.Sequence or data.TeleportSequence
	if sequence == nil and gameInfo.getSyncSequence and data == gameInfo.getSyncData() then sequence = gameInfo.getSyncSequence() end
	local order = sequenceOrder(sequence)
	if order == "old" then return true end
	if order == "same" and (data.Teleported ~= true or state.teleported) then return true end
	if order == "new" then state.sequence = sequence end
	if data.Teleported == true then
		state.teleported, state.teleportSequence = true, sequence
		state.lastBall = nil
		state.speed, state.distance, state.approaching = 0, 0, false
		state.awayAt, state.awayTarget = nil, nil
		table.clear(state.clicks); table.clear(state.returns); phase("waiting", "teleport_lock"); return true
	end
	if state.teleported and state.teleportSequence then
		local current = gameInfo.getSyncSequence()
		if type(current) ~= "number" or (current - state.teleportSequence) % 65536 >= 32768 then return true end
	end
	state.teleported, state.teleportSequence = false, nil
	local rawTarget = tonumber(data.TargetPlayerID); local target = finite(rawTarget) and rawTarget > 0 and rawTarget or gameInfo.getTargetId()
	if order == nil and state.sequence ~= nil and state.targetKnown and target ~= state.target then return true end
	if not finite(target) then return true end
	observeTarget(target, clock())
	if target <= 0 then
		state.target, state.targetKnown = target, true
		if target == -1 then state.lastBall = nil end
	end
	if state.player and (target == state.player.UserId or data.Grace == true) and state.character and state.root and not state.fired then tick(state.character, state.root, state.generation) end
	return true
end

-- public-api
function AutoParry.getTargetStatus()
	return {
		armed = not state.fired,
		firedForTarget = state.fired,
		lastTargeted = state.lastTargeted,
		targeted = state.targetKnown and state.player ~= nil and state.target == state.player.UserId,
		approaching = state.approaching,
		targetId = state.target,
		targetKnown = state.targetKnown,
		cooldown = gameInfo and gameInfo.getDeflectCooldownState() or nil,
	}
end
local function rootPosition()
	if state.root and state.root.Parent then return gameInfo.getRootPosition(state.root) end
	local character = state.player and state.player.Character; local root = character and character:FindFirstChild("HumanoidRootPart"); return root and root.Parent and gameInfo.getRootPosition(root) or nil
end
function AutoParry.getTiming(value, time, root, factor, baseWindow)
	if type(value) ~= "table" then return nil end
	root = vector(root) and root or rootPosition(); local position, velocity = value.position, value.velocity
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
	if not geometry then return nil end
	local delta = root - position; local distance = delta.Magnitude; local distanceToRadius = distance - geometry.fullRadius
	return {
		distance = distance,
		speed = speed,
		velocity = velocity,
		parryRadius = geometry.fullRadius,
		fullRadius = geometry.fullRadius,
		pureRadius = geometry.pureRadius,
		noWindowParryRadius = geometry.noWindowParryRadius,
		pingRadius = geometry.pingRadius,
		resilienceBonus = geometry.resilienceBonus,
		leadTime = geometry.leadTime,
		deflectWindow = geometry.deflectWindow,
		effectiveWindow = geometry.effectiveWindow,
		windowFactor = geometry.windowFactor,
		distanceToParryRadius = distanceToRadius,
		tti = speed > 0 and math.max(distanceToRadius, 0) / speed or math.huge,
		approaching = vector(velocity) and speed >= minimumBallSpeed() and distance > 0 and velocity:Dot(delta) > 0 or false,
		targeted = value.targeted == true,
	}
end
function AutoParry.getRadius(mode, factor, speedOverride, baseWindow)
	if mode ~= "tti" and mode ~= "speed_distance" then mode = "geometry" end
	local speed = tonumber(speedOverride)
	if not finite(speed) or speed < 0 then speed = state.speed end
	local result = radius(speed, factor, baseWindow); local tti = speed > 0 and math.max(state.distance - result.fullRadius, 0) / speed or math.huge
	result.mode, result.speed, result.distance, result.tti, result.resilience = mode, speed, state.distance, tti, resilience()
	result.value = mode == "tti" and tti or (mode == "speed_distance" and { speed = speed, distance = state.distance } or result.fullRadius); return result
end
function AutoParry.getPressure()
	local time, count, factors, configured, speeds, ratios = clock(), 0, 0, 0, 0, 0
	for i = #state.clicks, 1, -1 do
		local item = state.clicks[i]
		if time < item.at or time - item.at > T.PRESSURE_WINDOW then
			table.remove(state.clicks, i)
		else
			count += 1
			factors += item.factor
			configured += item.configured; speeds += item.speed; ratios += math.clamp(item.factor / item.configured, 0, 1)
		end
	end
	local returns, intervals = 0, 0
	for i = #state.returns, 1, -1 do
		local item = state.returns[i]
		if time < item.at or time - item.at > T.PRESSURE_WINDOW then table.remove(state.returns, i) else returns += 1; intervals += item.interval end
	end
	local latest, lastReturn = state.clicks[#state.clicks], state.returns[#state.returns]
	local currentLevel, factorDrop
	if latest and time >= latest.at and time - latest.at <= 1 and finite(latest.configured) and latest.configured > 0 then
		local ratio = math.clamp(latest.factor / latest.configured, 0, 1); currentLevel = 1 - ratio
		if count >= 3 then local previous, older = state.clicks[#state.clicks - 1], state.clicks[#state.clicks - 2]; local earlier = (math.clamp(previous.factor / previous.configured, 0, 1) + math.clamp(older.factor / older.configured, 0, 1)) / 2; factorDrop = math.max(0, earlier - ratio) end
	end
	return {
		samples = count,
		cps = count / T.PRESSURE_WINDOW,
		averageFactor = count > 0 and factors / count or nil,
		configuredFactor = count > 0 and configured / count or nil,
		averageSpeed = count > 0 and speeds / count or nil,
		returnSamples = returns,
		averageReturnTime = returns > 0 and intervals / returns or nil,
		level = count >= 3 and returns >= 2 and math.clamp(1 - ratios / count, 0, 1) or nil,
		currentFactor = latest and latest.factor or nil,
		currentLevel = currentLevel,
		factorDrop = factorDrop,
		latestReturnTime = lastReturn and lastReturn.interval or nil,
	}
end
function AutoParry.getStatus()
	local geometry = AutoParry.getRadius("geometry", utils and configuredFactor() or 0.5); local target = AutoParry.getTargetStatus()
	return {
		schema = utils and utils.apiVersion() or nil,
		api = {
			name = "AutoParry",
			version = 10,
			endpoints = { "getRadius", "getTiming", "getStatus", "getTargetStatus" },
			radiusModes = { "geometry", "tti", "speed_distance" },
			defaultWindowFactor = T.DEFAULT_WINDOW_FACTOR,
			windowFactorRange = { min = 0, max = 1 },
		},

		lifecycle = {
			phase = state.phase,
			reason = state.reason,
			bound = state.bound,
			alive = state.alive,
			generation = state.generation,
			lifeGeneration = state.lifeGeneration,
		},

		radius = geometry,
		resilience = geometry.resilience,
		timing = {
			tti = geometry.tti,
			ti = geometry.tti,
			speed = state.speed,
			distance = state.distance,
			distanceToRadius = state.distance - state.triggerDistance,
			triggerDistance = state.triggerDistance,
			closingSpeed = state.closingSpeed,
			frameAllowance = state.frameAllowance,
			deflectWindow = geometry.deflectWindow,
			effectiveWindow = geometry.effectiveWindow,
			leadTime = geometry.leadTime,
			noWindowParryRadius = geometry.noWindowParryRadius,
			pingRadius = geometry.pingRadius,
			approaching = state.approaching,
		},

		ping = { oneWay = state.ping, raw = state.pingRaw, samples = state.pingCount },
		target = target,
		pressure = AutoParry.getPressure(),
		cycle = { fired = state.fired, armed = not state.fired, lastFireAt = state.lastFireAt, lastTTI = geometry.tti },
		config = {
			baseRadius = geometry.pureRadius,
			baseWindow = geometry.deflectWindow,
			defaultWindowFactor = T.DEFAULT_WINDOW_FACTOR,
			windowFactorRange = { min = 0, max = 1 },
			minBallSpeed = minimumBallSpeed(),
		},

		timestamp = clock(),
	}
end

-- contract
AutoParry.__contract = {
	requires = { Remote = "remote", GameInfo = "gameinfo", Utils = "utils" },
	requiresMethods = {
		Remote = { "fireParry" },
		GameInfo = {
			"getSnapshotAt",
			"isSnapshotValid",
			"getSyncData",
			"getTargetId",
			"getSyncSequence",
			"getDeflectCooldownState",
			"getAveragePing",
			"getBallPosition",
			"getBallVelocity",
			"getRootPosition",
			"getDeflectGeometry",
			"getDeflectRangeParameters",
			"getProjectedDeflectRadius",
		},
		Utils = {
			"getLocalPlayer",
			"getRunService",
			"getConfigValue",
			"isActive",
			"isSpamActive",
			"trackCharacter",
			"untrackCharacter",
			"recordError",
		},
	},

	provides = {
		"setup",
		"bindCharacter",
		"detachCharacter",
		"teardown",
		"onBallSync",
		"fire",
		"tryRedirectReturn",
		"beginFierce",
		"cancelFierce",
		"resetState",
		"getRadius",
		"getTiming",
		"getTargetStatus",
		"getPressure",
		"getStatus",
	},

	onBallSync = true,
	bindCharacter = true,
	version = 10,
}

return AutoParry
