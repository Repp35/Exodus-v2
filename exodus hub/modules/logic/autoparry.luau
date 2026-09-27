-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils, BallReplicator, StatsService

-- tuning
local Tuning = {
	DEFLECT_RADIUS = 8.5,
	MIN_BALL_SPEED = 16,
	RES_PER_PARRY = 0.225,
	RES_CAP_STUDS = 32,
	HITBOX_OWN_WINDOW = 0.5,
	HITBOX_PROXIMITY = 12,
	HITBOX_GAP = 0.4,
	WINDOW_LOW_SPEED = 16,
	WINDOW_LOW = 0.820,
	WINDOW_REFERENCE_SPEED = 600,
	WINDOW_REFERENCE = 0.200,
	WINDOW_FACTOR = 0.45,
	PING_WINDOW_FACTOR = 1,
	PING_WINDOW_CAP = 0.400,
	CLIENT_CD_PROPAGATION = 0.30,
	MIN_LOCAL_PARRY_LOCK = 0.080,
}

local PING_SAMPLE_INTERVAL = 0.10
local PING_EMA_ALPHA_UP = 0.50
local PING_EMA_ALPHA_DOWN = 0.20
local DEFAULT_PING_ONE_WAY = 0.030
local TELEPORT_LOCK_BASE = 0.400
local WINDOW_CURVE_B = (Tuning.WINDOW_LOW - Tuning.WINDOW_REFERENCE)
	/ ((1 / Tuning.WINDOW_LOW_SPEED) - (1 / Tuning.WINDOW_REFERENCE_SPEED))
local WINDOW_CURVE_A = Tuning.WINDOW_REFERENCE - WINDOW_CURVE_B / Tuning.WINDOW_REFERENCE_SPEED
local MAX_RES_STACK = math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY)
local HITBOX_PROXIMITY_SQ = Tuning.HITBOX_PROXIMITY * Tuning.HITBOX_PROXIMITY
local PHASE_DETACHED = 1
local PHASE_WAITING = 2
local PHASE_COOLDOWN = 3
local PHASE_FIRED = 4
local PHASE_STRINGS = {
	[PHASE_DETACHED] = "detached",
	[PHASE_WAITING] = "waiting",
	[PHASE_COOLDOWN] = "cooldown",
	[PHASE_FIRED] = "fired",
}

local phaseString = "detached"
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table" and namespace.AutoParryHitbox
	or {
		connection = nil,
		handler = nil,
	}
namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace
local ParryState = {
	fired = false,
	firedBall = nil,
}

local Resilience = {
	stack = 0,
	lastFireBall = nil,
	lastFireAt = 0,
	lastHitboxAt = 0,
	hitboxConfirmed = false,
	lifeGeneration = 0,
}

local Runtime = {
	generation = 0,
	lifeGeneration = 0,
	alive = false,
	bound = false,
	localUserId = -1,
	player = nil,
	character = nil,
	root = nil,
	workspace = nil,
	lastTarget = -1,
	lastWasMe = nil,
	targetId = -1,
	targetKnown = false,
	teleportLockUntil = 0,
	connections = {},
	pingTimer = 0,
	pingOneWay = DEFAULT_PING_ONE_WAY,
	pingSource = "default",
	minPing = nil,
	resilienceBonus = 0,
	resilienceBonusAt = -1,
	parryRadius = 0,
	baseParryRadius = Tuning.DEFLECT_RADIUS,
	noWindowParryRadius = Tuning.DEFLECT_RADIUS,
	pingRadius = 0,
	deflectWindow = 0,
	effectiveWindow = 0,
	lastTTI = math.huge,
	lastDistance = 0,
	lastDistanceToParryRadius = 0,
	lastSpeed = 0,
	lastFireAt = 0,
	localParryLockUntil = 0,
	cooldownObservedAt = 0,
	phase = PHASE_DETACHED,
	passivePhase = "idle",
	passiveCycleStart = 0,
	passiveBallAtValid = false,
}

-- HELPERS
local function now() return Utils and Utils.now and Utils.now() or os.clock() end
local function setPhase(phase, reason)
	if Runtime.phase == phase then return end
	local old = Runtime.phase; Runtime.phase = phase; phaseString = PHASE_STRINGS[phase] or "detached"
	if Utils and Utils.recordTransition then Utils.recordTransition("AutoParry", PHASE_STRINGS[old] or "detached", phaseString, reason) end
end
local function isValidBall(ball) return ball ~= nil and ball.Parent ~= nil end
local function clearFired()
	ParryState.fired = false; ParryState.firedBall = nil
end
local function clearCycle()
	clearFired(); Resilience.lastFireBall = nil; Resilience.lastFireAt = 0
end
local function disconnectConnections()
	for i = #Runtime.connections, 1, -1 do
		local connection = Runtime.connections[i]; Runtime.connections[i] = nil
		if connection then
			if Utils and Utils.untrackCharacter then pcall(Utils.untrackCharacter, connection) end
			pcall(function() connection:Disconnect() end)
		end
	end
end
local function distanceSquared(a, b)
	local x = a.X - b.X; local y = a.Y - b.Y; local z = a.Z - b.Z; return x * x + y * y + z * z
end

-- RESILIENCE
local function resetResilience()
	Resilience.stack = 0; Resilience.lastFireBall = nil; Resilience.lastFireAt = 0; Resilience.lastHitboxAt = 0
	Resilience.hitboxConfirmed = false; Resilience.lifeGeneration = Runtime.lifeGeneration; Runtime.resilienceBonus = 0; Runtime.resilienceBonusAt = -1
end
local function invalidateLife()
	Runtime.lifeGeneration += 1; Runtime.alive = false; Runtime.bound = false; clearCycle()
	resetResilience()
end
local function isResilienceUsable()
	if not Runtime.alive or not Runtime.bound or Resilience.lifeGeneration ~= Runtime.lifeGeneration then
		Resilience.stack = 0; Resilience.lastFireBall = nil; Resilience.lastFireAt = 0; Resilience.lastHitboxAt = 0
		Runtime.resilienceBonus = 0; Runtime.resilienceBonusAt = Runtime.lifeGeneration; return false
	end
	local stack = Resilience.stack
	if type(stack) ~= "number" or stack < 0 or stack > MAX_RES_STACK then Resilience.stack = 0; Runtime.resilienceBonus = 0; Runtime.resilienceBonusAt = Runtime.lifeGeneration; return false end
	return true
end
local function getResilienceBonus(time)
	if not isResilienceUsable() then return 0 end
	if Runtime.resilienceBonusAt == time then return Runtime.resilienceBonus end
	Runtime.resilienceBonus = math.min(Resilience.stack * Tuning.RES_PER_PARRY, Tuning.RES_CAP_STUDS); Runtime.resilienceBonusAt = time; return Runtime.resilienceBonus
end

-- PING
local function samplePing()
	local ping, source
	if StatsService then
		local ok, item = pcall(function() return StatsService.Network.ServerStatsItem["Data Ping"] end)
		if ok and item then
			local valid, value = pcall(item.GetValue, item)
			if valid and type(value) == "number" and Utils.isFiniteNumber(value) then
				ping = value > 1 and value * 0.001 or value; source = "Stats.Data Ping"
			end
		end
	end
	if not ping or ping <= 0 or ping >= 1 then
		local player = Runtime.player
		local ok, value = pcall(function() return player and player:GetNetworkPing() end)
		if ok and type(value) == "number" and Utils.isFiniteNumber(value) and value > 0 and value < 1 then
			ping = value; source = "Player:GetNetworkPing"
		end
	end
	if not ping or ping <= 0 or ping >= 1 or not Utils.isFiniteNumber(ping) then return end
	if not Runtime.minPing or ping < Runtime.minPing then Runtime.minPing = ping end
	local oneWay = ping * 0.5
	local alpha = oneWay > Runtime.pingOneWay and PING_EMA_ALPHA_UP or PING_EMA_ALPHA_DOWN
	Runtime.pingOneWay += (oneWay - Runtime.pingOneWay) * alpha
	Runtime.pingSource = source or "unknown"
end

-- TIMING
local function computeBaseDeflectWindow(speed)
	local raw = tonumber(speed) or 0; local s = math.max(raw, Tuning.WINDOW_LOW_SPEED); local window = WINDOW_CURVE_A + WINDOW_CURVE_B / s
	if raw < 40 then window *= 0.7 end
	return math.max(window, 0)
end
local function computePingWindow()
	return math.min(Runtime.pingOneWay * 2 * Tuning.PING_WINDOW_FACTOR, Tuning.PING_WINDOW_CAP)
end
local function computeDeflectWindow(speed)
	return computeBaseDeflectWindow(speed) + computePingWindow()
end
local function computeEffectiveWindow(speed, factor)
	return computeBaseDeflectWindow(speed) * (factor or Tuning.WINDOW_FACTOR) + computePingWindow()
end
local function computePingRadius(speed)
	local rawSpeed = tonumber(speed) or 0
	if rawSpeed <= 0 then return 0 end
	return rawSpeed * computePingWindow()
end
local function computeNoWindowParryRadius(speed, resilience)
	return Tuning.DEFLECT_RADIUS + (resilience or 0) + computePingRadius(speed)
end
local function computeTiming(rootPosition, position, speed, time)
	if typeof(rootPosition) ~= "Vector3" or typeof(position) ~= "Vector3" or type(speed) ~= "number" or speed <= 0 then return nil end
	local resilience = getResilienceBonus(time); local deflectWindow = computeDeflectWindow(speed); local effectiveWindow = computeEffectiveWindow(speed)
	local pingRadius = computePingRadius(speed); local noWindowParryRadius = Tuning.DEFLECT_RADIUS + resilience + pingRadius
	local parryRadius = Tuning.DEFLECT_RADIUS + resilience + speed * effectiveWindow; local distSq = distanceSquared(rootPosition, position); local distance = math.sqrt(distSq)
	local delta = distance - parryRadius; local tti = delta <= 0 and 0 or delta / speed
	return {
		parryRadius = parryRadius,
		pureRadius = Tuning.DEFLECT_RADIUS,
		noWindowParryRadius = noWindowParryRadius,
		pingRadius = pingRadius,
		resilienceBonus = resilience,
		deflectWindow = deflectWindow,
		effectiveWindow = effectiveWindow,
		tti = tti,
		speed = speed,
		distance = distance,
		distanceSquared = distSq,
		distanceToParryRadius = delta,
		pingOneWay = Runtime.pingOneWay,
		stationary = false,
	}
end

-- TARGET
local function refreshTargetCache()
	local syncData = BallReplicator and BallReplicator.syncData; local target = tonumber(syncData and syncData.TargetPlayerID)
	if target ~= nil then Runtime.targetId = target; Runtime.targetKnown = true; return target end
	Runtime.targetKnown = false; return nil
end
local function isLocallyTargeted()
	if Runtime.localUserId <= 0 then return false end
	local target = Runtime.targetId
	if Runtime.targetKnown then return target == Runtime.localUserId end
	local syncData = BallReplicator and BallReplicator.syncData; local highlight = tonumber(syncData and syncData.HighlightTargetPlayerID)
	if highlight ~= nil then return highlight == Runtime.localUserId end
	local workspaceService = Runtime.workspace
	if workspaceService then
		local targetAttribute = tonumber(workspaceService:GetAttribute("GameBallTarget"))
		if targetAttribute ~= nil then return targetAttribute == Runtime.localUserId end
	end
	return false
end
local function getSnapshot(time)
	local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, time)
	if type(snapshot) ~= "table" or not GameInfo.isSnapshotValid(snapshot, time) then return nil end
	return snapshot
end
local function getBallSpeed(ball, snapshot)
	local ok, velocity = pcall(function() return ball.AssemblyLinearVelocity end)
	if ok and typeof(velocity) == "Vector3" and velocity.Magnitude > 0.1 then return velocity.Magnitude end
	local syncData = BallReplicator and BallReplicator.syncData
	local syncSpeed = tonumber(syncData and syncData.Speed)
	if syncSpeed and Utils.isFiniteNumber(syncSpeed) and syncSpeed >= 0 then return syncSpeed end
	return tonumber(snapshot and snapshot.speed)
end
local function isBallInParryWindow(time)
	local snapshot = getSnapshot(time)
	if not snapshot then return false, false end
	local ball = snapshot.ball
	if not isValidBall(ball) then return false, false end
	local speed = getBallSpeed(ball, snapshot)
	if not speed or speed < Tuning.MIN_BALL_SPEED or not Utils.isFiniteNumber(speed) then return false, false end
	local position = snapshot.position
	local root = Runtime.root
	if typeof(position) ~= "Vector3" or not root or not root.Parent then return false, false end
	local timing = computeTiming(root.Position, position, speed, time)
	if not timing then return false, false end
	return (timing.distance <= timing.parryRadius), true
end
local function onBallSync(data)
	if typeof(data) ~= "table" or not Runtime.alive or not Runtime.bound then return end
	local time = now()
	if data.Teleported == true then
		Runtime.teleportLockUntil = math.max(Runtime.teleportLockUntil, time + TELEPORT_LOCK_BASE + Runtime.pingOneWay); clearCycle(); Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false
		setPhase(PHASE_WAITING, "teleport_lock"); return
	end
	local targetId = tonumber(data.TargetPlayerID) or -1; Runtime.targetId = targetId; Runtime.targetKnown = true; local previousTarget = Runtime.lastTarget
	local previousWasMe = Runtime.lastWasMe
	if targetId == previousTarget and previousWasMe ~= nil then
		if Utils.isSpamActive() and Runtime.passivePhase == "awaiting_leave" then
			local inside, valid = isBallInParryWindow(time)
			if valid and inside then Runtime.passiveBallAtValid = true end
		end
		return
	end
	Runtime.lastTarget = targetId; local isMe = targetId == Runtime.localUserId; Runtime.lastWasMe = isMe
	if Utils.isSpamActive() then
		if not isMe then
			if Runtime.passivePhase == "awaiting_leave" then
				if Runtime.passiveBallAtValid and isResilienceUsable() then Resilience.stack = math.min(Resilience.stack + 1, MAX_RES_STACK); Runtime.resilienceBonusAt = -1 end
				Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false
			end
		else
			if previousWasMe ~= true then
				Runtime.passivePhase = "awaiting_leave"; Runtime.passiveCycleStart = time; local inside, valid = isBallInParryWindow(time); Runtime.passiveBallAtValid = valid and inside
			else
				local inside, valid = isBallInParryWindow(time)
				if valid and inside then Runtime.passiveBallAtValid = true end
			end
		end
	else
		Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false
	end
	if isMe then
		clearFired()
	elseif targetId ~= -1 then
		if previousWasMe == true then clearFired() end
	else
		clearFired()
	end
end

-- PARRY
local function requestParry(ball)
	if not Runtime.alive or not Runtime.bound then return false end
	local time = now()
	if ParryState.fired or time < Runtime.localParryLockUntil then
		setPhase(PHASE_COOLDOWN, "local_parry_lock")
		return false
	end
	if GameInfo and type(GameInfo.getDeflectCD) == "function" then
		local okCooldown, cooldown = pcall(GameInfo.getDeflectCD)
		cooldown = okCooldown and tonumber(cooldown) or 0
		if cooldown and Utils.isFiniteNumber(cooldown) and cooldown > 0 then
			Runtime.localParryLockUntil = math.max(Runtime.localParryLockUntil, time + cooldown + 0.05)
			setPhase(PHASE_COOLDOWN, "game_cooldown")
			return false
		end
	end
	if not Remote or type(Remote.fireParry) ~= "function" then
		if Utils.recordError then Utils.recordError("AutoParry", "Remote.fireParry indisponivel") end
		setPhase(PHASE_WAITING, "remote_unavailable"); return false
	end
	Runtime.localParryLockUntil = time + Tuning.MIN_LOCAL_PARRY_LOCK
	ParryState.fired = true; ParryState.firedBall = ball; local ok = pcall(Remote.fireParry, 1)
	if not ok then
		clearFired()
		if Utils.recordError then Utils.recordError("AutoParry", "Remote.fireParry falhou") end
		setPhase(PHASE_WAITING, "remote_failed"); return false
	end
	Runtime.lastFireAt = time; Runtime.cooldownObservedAt = 0
	if Resilience.hitboxConfirmed then Resilience.hitboxConfirmed = false end
	local firedBall = ball
	if not isValidBall(firedBall) then
		local okBall, currentBall = pcall(GameInfo.getBall)
		if okBall then firedBall = currentBall end
	end
	if
		isValidBall(firedBall)
		and Runtime.alive
		and Runtime.bound
		and Resilience.lifeGeneration == Runtime.lifeGeneration
	then
		Resilience.lastFireBall = firedBall; Resilience.lastFireAt = time
	else
		Resilience.lastFireBall = nil; Resilience.lastFireAt = 0
	end
	setPhase(PHASE_FIRED, "parry_requested"); return true
end

-- HITBOX
local function handleHitbox(instance)
	if
		typeof(instance) ~= "Instance"
		or instance.Name ~= "HitboxGrow"
		or not Utils.isActive()
		or Resilience.hitboxConfirmed
	then
		return
	end
	if not isResilienceUsable() then return end
	local time = now()
	if
		time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW
		or time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP
	then
		return
	end
	local ball = Resilience.lastFireBall
	if not isValidBall(ball) then return end
	local position = instance.Position; local ballPosition = ball.Position
	if typeof(position) ~= "Vector3" or typeof(ballPosition) ~= "Vector3" then return end
	if distanceSquared(ballPosition, position) > HITBOX_PROXIMITY_SQ then return end
	if not Runtime.alive or not Runtime.bound or Resilience.lifeGeneration ~= Runtime.lifeGeneration then return end
	Resilience.hitboxConfirmed = true; Resilience.lastHitboxAt = time; Resilience.stack = math.min(Resilience.stack + 1, MAX_RES_STACK); Runtime.resilienceBonusAt = -1
end
local function installHitboxHook()
	if HitboxState.connection then return true end
	local workspaceService = Runtime.workspace
	if not workspaceService then return false end
	local ok, connection = pcall(function()
		return workspaceService.DescendantAdded:Connect(function(instance)
			local handler = HitboxState.handler
			if handler then handler(instance) end
		end)
	end)
	if not ok or not connection then return false end
	HitboxState.connection = connection; Utils.trackGlobal(connection); return true
end

-- CHARACTER
local function bindCharacter(character)
	if not Remote or not GameInfo or not Utils then return false, "dependencias nao inicializadas" end
	Runtime.generation += 1; local generation = Runtime.generation; disconnectConnections(); invalidateLife()
	setPhase(PHASE_DETACHED, "rebind_start")
	if not character or not character.Parent then return false end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then root = character:WaitForChild("HumanoidRootPart", 1) end
	if generation ~= Runtime.generation or not root or not root.Parent then return false end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then return false end
	Runtime.character = character; Runtime.root = root
	if humanoid then
		local diedConnection = humanoid.Died:Connect(function()
			if generation ~= Runtime.generation then return end
			Runtime.generation += 1; invalidateLife(); setPhase(PHASE_DETACHED, "character_died")
		end)
		Runtime.connections[#Runtime.connections + 1] = diedConnection; Utils.trackCharacter(diedConnection)
	end
	local runService = Utils.getRunService(); local heartbeat = runService.Heartbeat; local getConfig = Utils.getConfig; local isSpamActive = Utils.isSpamActive
	local getSnapshot = GameInfo.getSnapshot; local isSnapshotValid = GameInfo.isSnapshotValid; local getDeflectCD = GameInfo.getDeflectCD; local finite = Utils.isFiniteNumber
	local heartbeatConnection = heartbeat:Connect(function(dt)
		if generation ~= Runtime.generation or not Runtime.alive or not Runtime.bound then return end
		if not character.Parent or not root.Parent then return end
		local config = getConfig()
		if type(config) ~= "table" or config.AutoParry ~= true then clearCycle(); return end
		local timeNow = now()
		if timeNow < Runtime.teleportLockUntil then clearCycle(); return end
		if isSpamActive() then clearCycle(); return end
		Runtime.pingTimer += math.max(dt, 0)
		if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then Runtime.pingTimer = 0; samplePing() end
		refreshTargetCache()
		if not isLocallyTargeted() then setPhase(PHASE_WAITING, "not_targeted"); return end
		if ParryState.fired then return end
		local snapshot = getSnapshot(Runtime.lastTarget, timeNow)
		if type(snapshot) ~= "table" or not isSnapshotValid(snapshot, timeNow) then return end
		local ball = snapshot.ball
		if not isValidBall(ball) then return end
		local speed = getBallSpeed(ball, snapshot)
		if not speed or speed < Tuning.MIN_BALL_SPEED or not finite(speed) then return end
		local position = snapshot.position
		if typeof(position) ~= "Vector3" then return end
		local deflectCooldown = tonumber(getDeflectCD()) or 0
		if deflectCooldown > 0 then
			if Runtime.cooldownObservedAt <= 0 then Runtime.cooldownObservedAt = timeNow end
			if timeNow - Runtime.cooldownObservedAt >= Tuning.CLIENT_CD_PROPAGATION then setPhase(PHASE_COOLDOWN, "cooldown_propagation")
			else setPhase(PHASE_COOLDOWN, "cooldown_observed") end
			return
		end
		Runtime.cooldownObservedAt = 0
		local timing = computeTiming(root.Position, position, speed, timeNow)
		if not timing then return end
		Runtime.parryRadius = timing.parryRadius; Runtime.baseParryRadius = timing.pureRadius; Runtime.noWindowParryRadius = timing.noWindowParryRadius
		Runtime.pingRadius = timing.pingRadius; Runtime.resilienceBonus = timing.resilienceBonus
		Runtime.deflectWindow = timing.deflectWindow; Runtime.effectiveWindow = timing.effectiveWindow
		Runtime.lastTTI = timing.tti; Runtime.lastDistance = timing.distance; Runtime.lastDistanceToParryRadius = timing.distanceToParryRadius; Runtime.lastSpeed = timing.speed
		if timing.distance > timing.parryRadius then setPhase(PHASE_WAITING, "outside_radius"); return end
		requestParry(ball)
	end)
	Runtime.connections[#Runtime.connections + 1] = heartbeatConnection; Utils.trackCharacter(heartbeatConnection)
	local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
		if not parent and generation == Runtime.generation then
			Runtime.generation += 1; invalidateLife(); disconnectConnections(); Runtime.character = nil
			Runtime.root = nil; setPhase(PHASE_DETACHED, "character_removed")
		end
	end)
	Runtime.connections[#Runtime.connections + 1] = ancestryConnection; Utils.trackCharacter(ancestryConnection); Runtime.bound = true; Runtime.alive = true
	Resilience.lifeGeneration = Runtime.lifeGeneration; setPhase(PHASE_WAITING, "character_bound"); return true
end

-- RESET
local function resetState()
	invalidateLife(); Runtime.teleportLockUntil = 0; Runtime.lastTarget = -1; Runtime.lastWasMe = nil
	Runtime.targetId = -1; Runtime.targetKnown = false; Runtime.pingTimer = 0; Runtime.minPing = nil
	Runtime.pingOneWay = DEFAULT_PING_ONE_WAY; Runtime.pingSource = "default"; Runtime.parryRadius = 0; Runtime.baseParryRadius = Tuning.DEFLECT_RADIUS
	Runtime.noWindowParryRadius = Tuning.DEFLECT_RADIUS; Runtime.pingRadius = 0; Runtime.resilienceBonus = 0
	Runtime.resilienceBonusAt = -1; Runtime.deflectWindow = 0; Runtime.effectiveWindow = 0; Runtime.lastTTI = math.huge
	Runtime.lastDistance = 0; Runtime.lastDistanceToParryRadius = 0; Runtime.lastSpeed = 0; Runtime.lastFireAt = 0
	Runtime.cooldownObservedAt = 0; Runtime.localParryLockUntil = 0
	setPhase(PHASE_DETACHED, "reset")
end

-- SETUP
function AutoParry.setup(deps)
	if type(deps) ~= "table" then return false, "dependencias invalidas" end
	local remote = deps.Remote; local gameInfo = deps.GameInfo; local utils = deps.Utils
	if type(remote) ~= "table" or type(remote.fireParry) ~= "function" then return false, "dependencia ausente: Remote.fireParry" end
	if
		type(gameInfo) ~= "table"
		or type(gameInfo.getDeflectCD) ~= "function"
		or type(gameInfo.getBall) ~= "function"
		or type(gameInfo.getSnapshot) ~= "function"
		or type(gameInfo.isSnapshotValid) ~= "function"
	then
		return false, "dependencia ausente: GameInfo"
	end
	if
		type(utils) ~= "table"
		or type(utils.now) ~= "function"
		or type(utils.apiVersion) ~= "function"
		or type(utils.isFiniteNumber) ~= "function"
		or type(utils.getConfig) ~= "function"
		or type(utils.getLocalPlayer) ~= "function"
		or type(utils.getWorkspace) ~= "function"
		or type(utils.getRunService) ~= "function"
		or type(utils.trackCharacter) ~= "function"
		or type(utils.untrackCharacter) ~= "function"
		or type(utils.trackGlobal) ~= "function"
		or type(utils.isActive) ~= "function"
		or type(utils.isSpamActive) ~= "function"
	then
		return false, "dependencia ausente: Utils"
	end
	Remote = remote; GameInfo = gameInfo; Utils = utils; StatsService = game:GetService("Stats")
	Runtime.player = Utils.getLocalPlayer(); Runtime.localUserId = Runtime.player and tonumber(Runtime.player.UserId) or -1; Runtime.workspace = Utils.getWorkspace(); BallReplicator = nil
	pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local module =
			require(ReplicatedStorage:WaitForChild("TS"):WaitForChild("BallReplicator"):WaitForChild("BallReplicator"))
		if module and module.BallReplicator then BallReplicator = module.BallReplicator end
	end)
	HitboxState.handler = handleHitbox; resetState()
	if not installHitboxHook() and Utils.warn then Utils.warn("hook de hitbox indisponivel") end
	return true
end

-- PUBLIC
function AutoParry.fire()
	if not Remote or not GameInfo or not Utils or not Runtime.alive or not Runtime.bound then return false end
	local ball = GameInfo.getBall(); return requestParry(ball)
end
function AutoParry.bindCharacter(character)
	if not Remote or not GameInfo or not Utils then return false end
	return bindCharacter(character)
end
function AutoParry.resetState()
	if Utils then resetState() end
end
function AutoParry.detachCharacter()
	if not Utils then return end
	Runtime.generation += 1; disconnectConnections(); invalidateLife(); Runtime.character = nil
	Runtime.root = nil; setPhase(PHASE_DETACHED, "detach")
end
function AutoParry.onBallSync(data)
	if Utils then onBallSync(data) end
end

-- API
local function getResilienceStatus()
	local usable = isResilienceUsable()
	return {
		stack = usable and Resilience.stack or 0,
		size = usable and Runtime.resilienceBonus or 0,
		perParry = Tuning.RES_PER_PARRY,
		cap = Tuning.RES_CAP_STUDS,
		maxStack = MAX_RES_STACK,
	}
end
function AutoParry.getRadius(mode, windowFactor, speedOverride)
	mode = mode or "geometry"
	if mode ~= "geometry" and mode ~= "tti" and mode ~= "speed_distance" then mode = "geometry" end
	local speed = tonumber(speedOverride)
	if not speed or not Utils.isFiniteNumber(speed) or speed < 0 then speed = Runtime.lastSpeed end
	local distance = Runtime.lastDistance; local tti = speed > 0 and distance / speed or math.huge; windowFactor = tonumber(windowFactor)
	if not windowFactor or not Utils.isFiniteNumber(windowFactor) then windowFactor = Tuning.WINDOW_FACTOR end
	windowFactor = math.clamp(windowFactor, 0, 1.5); local deflectWindow = computeDeflectWindow(speed)
	local effectiveWindow = deflectWindow * windowFactor
	local resilience = getResilienceBonus(now()); local pingRadius = computePingRadius(speed)
	local noWindowParryRadius = Tuning.DEFLECT_RADIUS + resilience + pingRadius
	local fullRadius = Tuning.DEFLECT_RADIUS + resilience + speed * effectiveWindow; local value = fullRadius
	if mode == "tti" then
		value = tti
	elseif mode == "speed_distance" then
		value = {
			speed = speed,
			distance = distance,
		}

	end
	return {
		mode = mode,
		value = value,
		pureRadius = Tuning.DEFLECT_RADIUS,
		noWindowParryRadius = noWindowParryRadius,
		pingRadius = pingRadius,
		resilience = getResilienceStatus(),
		fullRadius = fullRadius,
		deflectWindow = deflectWindow,
		windowFactor = windowFactor,
		effectiveWindow = effectiveWindow,
		distance = distance,
		speed = speed,
		tti = tti,
	}
end
function AutoParry.getTiming(snapshot, time, rootPosition)
	if not Utils or type(snapshot) ~= "table" then return nil end
	time = tonumber(time) or now()
	if typeof(rootPosition) ~= "Vector3" then
		local root = Runtime.root
		if root and root.Parent then
			rootPosition = root.Position
		else
			local player = Runtime.player; local character = player and player.Character; local newRoot = character and character:FindFirstChild("HumanoidRootPart")
			if newRoot then rootPosition = newRoot.Position end
		end
	end
	local speed = tonumber(snapshot.speed); local position = snapshot.position
	if
		not speed
		or not Utils.isFiniteNumber(speed)
		or speed <= 0
		or typeof(position) ~= "Vector3"
		or typeof(rootPosition) ~= "Vector3"
	then
		return nil
	end
	return computeTiming(rootPosition, position, speed, time)
end
function AutoParry.getStatus()
	return {
		schema = Utils and Utils.apiVersion and Utils.apiVersion() or nil,
		api = {
			name = "AutoParry",
			version = 3,
			endpoints = {
				"getRadius",
				"getTiming",
				"getStatus",
			},
		},

		lifecycle = {
			phase = phaseString,
			bound = Runtime.bound == true,
			alive = Runtime.alive == true,
			lifeGeneration = Runtime.lifeGeneration,
		},

		radius = AutoParry.getRadius("geometry"),
		resilience = getResilienceStatus(),
		timing = {
			tti = Runtime.lastTTI,
			speed = Runtime.lastSpeed,
			distance = Runtime.lastDistance,
			distanceToRadius = Runtime.lastDistanceToParryRadius,
			deflectWindow = Runtime.deflectWindow,
			effectiveWindow = Runtime.effectiveWindow,
			noWindowParryRadius = Runtime.noWindowParryRadius,
			pingRadius = Runtime.pingRadius,
		},

		ping = {
			oneWay = Runtime.pingOneWay,
			roundTrip = Runtime.pingOneWay * 2,
			compensationWindow = computePingWindow(),
			source = Runtime.pingSource,
			minimum = Runtime.minPing,
		},

		cycle = {
			fired = ParryState.fired == true,
			lastFireAt = Runtime.lastFireAt,
			lastTTI = Runtime.lastTTI,
			localLockRemaining = math.max(0, Runtime.localParryLockUntil - now()),
		},

	}
end
AutoParry.__contract = {
	requires = {
		Remote = "remote",
		GameInfo = "gameinfo",
		Utils = "utils",
	},

	onBallSync = true,
	bindCharacter = true,
}

return AutoParry
