-- [[ AutoParry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

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
	WINDOW_FACTOR = 0.47,
	PING_WINDOW_FACTOR = 1.0,
	PING_WINDOW_CAP = 0.250,
	CLIENT_CD_PROPAGATION = 0.30,
}

local PING_SAMPLE_INTERVAL = 1.5
local DEFAULT_PING_ONE_WAY = 0.030
local TELEPORT_LOCK = 0.20

local WINDOW_CURVE_B = (Tuning.WINDOW_LOW - Tuning.WINDOW_REFERENCE) / ((1 / Tuning.WINDOW_LOW_SPEED) - (1 / Tuning.WINDOW_REFERENCE_SPEED))
local WINDOW_CURVE_A = Tuning.WINDOW_REFERENCE - (WINDOW_CURVE_B / Tuning.WINDOW_REFERENCE_SPEED)
local MAX_RES_STACK = math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY)
local HITBOX_PROXIMITY_SQ = Tuning.HITBOX_PROXIMITY * Tuning.HITBOX_PROXIMITY

local PHASE_DETACHED   = 1
local PHASE_WAITING    = 2
local PHASE_COOLDOWN   = 3
local PHASE_ARMED      = 4
local PHASE_FIRED      = 5
local PHASE_PASSIVE    = 6

local PHASE_STRINGS = {
	[PHASE_DETACHED] = "detached",
	[PHASE_WAITING]  = "waiting",
	[PHASE_COOLDOWN] = "cooldown",
	[PHASE_ARMED]    = "armed",
	[PHASE_FIRED]    = "fired",
	[PHASE_PASSIVE]  = "passive",
}

local phaseString = PHASE_STRINGS[PHASE_DETACHED]

local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table" and namespace.AutoParryHitbox or {
	connection = nil,
	handler    = nil,
}
namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- state
local ParryState = {
	armed     = false,
	armedBall = nil,
	fired     = false,
	firedBall = nil,
	firedAt   = 0,
}

local Resilience = {
	stack         = 0,
	lastFireBall  = nil,
	lastFireAt    = 0,
	lastHitboxAt  = 0,
}

local Runtime = {
	generation            = 0,
	localUserId           = -1,
	lastTarget            = -1,
	lastWasMe             = nil,
	teleportLockUntil     = 0,
	connections           = {},
	minPing               = nil,
	pingTimer             = 0,
	pingOneWay            = DEFAULT_PING_ONE_WAY,
	resilienceBonusAt     = -1,
	parryRadius           = 0,
	baseParryRadius       = Tuning.DEFLECT_RADIUS,
	resilienceBonus       = 0,
	deflectWindow         = 0,
	effectiveWindow       = 0,
	lastTTI               = math.huge,
	lastDistance          = 0,
	lastDistanceToParryRadius = 0,
	lastSpeed             = 0,
	lastFireAt            = 0,
	cooldownObservedAt    = 0,
	phase                 = PHASE_DETACHED,
	bound                 = false,
	passivePhase          = "idle",
	passiveCycleStart     = 0,
	passiveBallAtValid    = false,
}

local StatsService

-- helpers
local function now()
	if Utils and type(Utils.now) == "function" then
		return Utils.now()
	end
	return os.clock()
end

local function setPhase(phase, reason)
	if Runtime.phase == phase then return end
	local previous = Runtime.phase
	Runtime.phase = phase
	phaseString = PHASE_STRINGS[phase] or "detached"
	if Utils and type(Utils.recordTransition) == "function" then
		Utils.recordTransition(
			"AutoParry",
			PHASE_STRINGS[previous] or "detached",
			phaseString,
			reason
		)
	end
end

local function clearArmed()
	ParryState.armed = false
	ParryState.armedBall = nil
end

local function clearFired()
	ParryState.fired = false
	ParryState.firedBall = nil
	ParryState.firedAt = 0
end

local function clearCycle()
	clearArmed()
	clearFired()
	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0
end

local function disconnectConnections()
	local connections = Runtime.connections
	for i = #connections, 1, -1 do
		local connection = connections[i]
		connections[i] = nil
		if connection then
			if Utils and type(Utils.untrackCharacter) == "function" then
				pcall(Utils.untrackCharacter, connection)
			end
			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end

local function isValidBall(ball)
	return ball ~= nil and ball.Parent ~= nil
end

local function getDistanceSquared(a, b)
	local dx = a.X - b.X
	local dy = a.Y - b.Y
	local dz = a.Z - b.Z
	return dx * dx + dy * dy + dz * dz
end

-- ping
local function samplePing()
	if not StatsService then return end
	local okItem, pingItem = pcall(function()
		return StatsService.Network.ServerStatsItem["Data Ping"]
	end)
	if not okItem or not pingItem then return end
	local ok, ping = pcall(pingItem.GetValue, pingItem)
	if not ok or type(ping) ~= "number" then return end
	ping *= 0.001
	if not Utils or not Utils.isFiniteNumber or not Utils.isFiniteNumber(ping) or ping <= 0 or ping >= 0.5 then
		return
	end
	if not Runtime.minPing or ping < Runtime.minPing then
		Runtime.minPing = ping
		Runtime.pingOneWay = ping * 0.5
	end
end

-- resilience
local function getResilienceBonus(time)
	if Runtime.resilienceBonusAt == time then
		return Runtime.resilienceBonus
	end
	Runtime.resilienceBonus = math.min(
		Resilience.stack * Tuning.RES_PER_PARRY,
		Tuning.RES_CAP_STUDS
	)
	Runtime.resilienceBonusAt = time
	return Runtime.resilienceBonus
end

local function resetResilience()
	Resilience.stack = 0
	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0
	Resilience.lastHitboxAt = 0
	Runtime.resilienceBonus = 0
	Runtime.resilienceBonusAt = -1
end

local function computeBaseParryRadius(time)
	return Tuning.DEFLECT_RADIUS + getResilienceBonus(time)
end

local function computeBaseDeflectWindow(speed)
	local rawSpeed = tonumber(speed) or 0
	speed = math.max(rawSpeed, Tuning.WINDOW_LOW_SPEED)
	local window = WINDOW_CURVE_A + WINDOW_CURVE_B / speed
	if rawSpeed < 40 then
		window *= 0.7
	end
	return math.max(window, 0)
end

local function computeDeflectWindow(speed, pingOneWay)
	local window = computeBaseDeflectWindow(speed)
	local ping = tonumber(pingOneWay) or Runtime.pingOneWay or DEFAULT_PING_ONE_WAY
	if ping and ping > 0 then
		local buffer = ping * 2 * Tuning.PING_WINDOW_FACTOR
		window += math.min(buffer, Tuning.PING_WINDOW_CAP)
	end
	return window
end

local function computeEffectiveWindow(speed, pingOneWay)
	return computeDeflectWindow(speed, pingOneWay) * Tuning.WINDOW_FACTOR
end

local function computeParryRadius(time, speed)
	local baseRadius = computeBaseParryRadius(time)
	local effectiveWindow = computeEffectiveWindow(speed, Runtime.pingOneWay)
	return baseRadius + speed * effectiveWindow
end

-- timing
local function computeTiming(rootPosition, position, speed, time)
	if typeof(rootPosition) ~= "Vector3"
		or typeof(position) ~= "Vector3"
		or type(speed) ~= "number"
		or speed <= 0 then
		return nil
	end
	local parryRadius = computeParryRadius(time, speed)
	local deflectWindow = computeDeflectWindow(speed, Runtime.pingOneWay)
	local effectiveWindow = deflectWindow * Tuning.WINDOW_FACTOR
	local distanceSquared = getDistanceSquared(rootPosition, position)
	local distance = math.sqrt(distanceSquared)
	local distanceToParryRadius = distance - parryRadius
	local tti
	if distanceToParryRadius <= 0 then
		tti = 0
	else
		tti = distanceToParryRadius / speed
	end
		return {
			parryRadius           = parryRadius,
			pureRadius            = Tuning.DEFLECT_RADIUS,
			resilienceBonus       = getResilienceBonus(time),
			deflectWindow         = deflectWindow,
		effectiveWindow       = effectiveWindow,
		tti                   = tti,
		speed                 = speed,
		distance              = distance,
		distanceToParryRadius = distanceToParryRadius,
		pingOneWay            = Runtime.pingOneWay,
		stationary            = false,
	}
end

local function isBallInParryWindow(time)
	if not GameInfo
		or type(GameInfo.getSnapshot) ~= "function"
		or type(GameInfo.isSnapshotValid) ~= "function" then
		return false, false
	end
	local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, time)
	if type(snapshot) ~= "table" or not GameInfo.isSnapshotValid(snapshot, time) then
		return false, false
	end
	local ball = snapshot.ball
	if not isValidBall(ball) then return false, false end
	local speed = tonumber(snapshot.speed)
	if not speed
		or not Utils
		or not Utils.isFiniteNumber
		or not Utils.isFiniteNumber(speed)
		or speed < Tuning.MIN_BALL_SPEED then
		return false, false
	end
	local position = snapshot.position
	if typeof(position) ~= "Vector3" then return false, false end
	if not Utils or type(Utils.getLocalPlayer) ~= "function" then
		return false, false
	end
	local localPlayer = Utils.getLocalPlayer()
	local character = localPlayer and localPlayer.Character
	if not character then return false, false end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false, false end
	local timing = computeTiming(root.Position, position, speed, time)
	if not timing then return false, false end
	local insideRadius = timing.distance <= timing.parryRadius
	return insideRadius, true
end

-- targeting
local function onBallSync(data)
	if typeof(data) ~= "table" then return end
	if not Utils then return end -- FIX: guard contra deps nulas

	local time = now()

	if data.Teleported == true then
		Runtime.teleportLockUntil = time + TELEPORT_LOCK
		clearCycle()
		Runtime.passivePhase = "idle"
		Runtime.passiveBallAtValid = false
		return
	end

	local targetId = tonumber(data.TargetPlayerID) or -1
	local previousTarget = Runtime.lastTarget
	local previousWasMe = Runtime.lastWasMe

	if targetId == Runtime.lastTarget and previousWasMe ~= nil then
		if Utils.isSpamActive and Utils.isSpamActive()
			and Runtime.passivePhase == "awaiting_leave" then
			local inside, valid = isBallInParryWindow(time)
			if valid and inside then
				Runtime.passiveBallAtValid = true
			end
		end
		return
	end

	Runtime.lastTarget = targetId
	local isMe = targetId == Runtime.localUserId
	Runtime.lastWasMe = isMe

	if Utils.isSpamActive and Utils.isSpamActive() then
		if not isMe then
			if Runtime.passivePhase == "awaiting_leave" then
				if Runtime.passiveBallAtValid then
					Resilience.stack = math.min(Resilience.stack + 1, MAX_RES_STACK)
					Runtime.resilienceBonusAt = -1
				end
				Runtime.passivePhase = "idle"
				Runtime.passiveBallAtValid = false
			end
		else
			if previousWasMe ~= true then
				Runtime.passivePhase = "awaiting_leave"
				Runtime.passiveCycleStart = time
				local inside, valid = isBallInParryWindow(time)
				Runtime.passiveBallAtValid = valid and inside
			else
				local inside, valid = isBallInParryWindow(time)
				if valid and inside then
					Runtime.passiveBallAtValid = true
				end
			end
		end
	else
		Runtime.passivePhase = "idle"
		Runtime.passiveBallAtValid = false
	end

	if targetId == Runtime.localUserId and previousTarget ~= Runtime.localUserId then
		clearFired()
	end
end

-- parry
local function requestParry()
	if not Remote or type(Remote.fireParry) ~= "function" then
		if Utils and type(Utils.recordError) == "function" then
			Utils.recordError("AutoParry", "Remote.fireParry indisponivel")
		end
		setPhase(PHASE_WAITING, "remote_unavailable")
		return false
	end
	local time = now()
	local ok, result = pcall(Remote.fireParry, 1)
	if not ok or result == false then
		if Utils and type(Utils.recordError) == "function" then
			Utils.recordError("AutoParry", "Remote.fireParry falhou")
		end
		setPhase(PHASE_WAITING, "remote_failed")
		return false
	end
	Runtime.lastFireAt = time
	Runtime.cooldownObservedAt = 0
	local ball = GameInfo and GameInfo.getBall and GameInfo.getBall() or nil
	if isValidBall(ball) then
		Resilience.lastFireBall = ball
		Resilience.lastFireAt = time
	else
		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0
	end
	setPhase(PHASE_FIRED, "parry_requested")
	return true
end

-- hitbox
local function handleHitbox(instance)
	if typeof(instance) ~= "Instance"
		or instance.Name ~= "HitboxGrow"
		or not Utils
		or type(Utils.isActive) ~= "function"
		or not Utils.isActive() then
		return
	end
	local time = now()
	if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW
		or time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP then
		return
	end
	local ball = Resilience.lastFireBall
	if not isValidBall(ball) then return end
	local position, ballPosition
	local ok = pcall(function()
		position = instance.Position
		ballPosition = ball.Position
	end)
	if not ok or typeof(position) ~= "Vector3" or typeof(ballPosition) ~= "Vector3" then
		return
	end
	if getDistanceSquared(ballPosition, position) > HITBOX_PROXIMITY_SQ then
		return
	end
	Resilience.lastHitboxAt = time
	Resilience.stack = math.min(Resilience.stack + 1, MAX_RES_STACK)
	Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
	if HitboxState.connection then return true end
	if not Utils or type(Utils.getWorkspace) ~= "function" then return false end
	local workspaceService = Utils.getWorkspace()
	if not workspaceService then return false end
	local ok, connection = pcall(function()
		return workspaceService.DescendantAdded:Connect(function(instance)
			local handler = HitboxState.handler
			if type(handler) == "function" then
				handler(instance)
			end
		end)
	end)
	if not ok or not connection then return false end
	HitboxState.connection = connection
	if Utils and type(Utils.trackGlobal) == "function" then
		Utils.trackGlobal(connection)
	end
	return true
end

-- character
local function bindCharacter(character)
	if not Utils or not GameInfo or not Remote then
		return false, "dependencias nao inicializadas"
	end
	Runtime.generation += 1
	local generation = Runtime.generation
	Runtime.bound = false
	disconnectConnections()
	clearCycle()
	setPhase(PHASE_DETACHED, "rebind_start")
	if not character or not character.Parent then return false end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		root = character:WaitForChild("HumanoidRootPart", 1)
	end
	if generation ~= Runtime.generation or not root or not root.Parent then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local diedConnection = humanoid.Died:Connect(function()
			resetResilience()
			clearCycle()
		end)
		Runtime.connections[#Runtime.connections + 1] = diedConnection
		if Utils.trackCharacter then
			Utils.trackCharacter(diedConnection)
		end
	end

	local heartbeat = Utils.getRunService().Heartbeat
	local getConfig    = Utils.getConfig
	local isSpamActive = Utils.isSpamActive
	local getLocalPlayer = Utils.getLocalPlayer

	local heartbeatConnection = heartbeat:Connect(function(dt)
		if generation ~= Runtime.generation then return end
		if not character.Parent or not root.Parent then return end
		local config = getConfig()
		if type(config) ~= "table" or config.AutoParry ~= true then
			clearCycle()
			setPhase(PHASE_WAITING, "disabled_or_locked")
			return
		end
		local timeNow = now()
		if timeNow < Runtime.teleportLockUntil then
			clearCycle()
			setPhase(PHASE_WAITING, "teleport_lock")
			return
		end
		if isSpamActive and isSpamActive() then
			clearCycle()
			setPhase(PHASE_WAITING, "spam_active")
			return
		end

		Runtime.pingTimer += math.max(dt, 0)
		if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then
			Runtime.pingTimer = 0
			samplePing()
		end

		local rootPos = root.Position
		local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, timeNow)
		if type(snapshot) ~= "table" or not GameInfo.isSnapshotValid(snapshot, timeNow) then
			setPhase(PHASE_WAITING, "snapshot_invalid")
			return
		end
		local ball = snapshot.ball
		local targeted = snapshot.targeted == true
		if not (isValidBall(ball) and targeted) then
			setPhase(PHASE_WAITING, "ball_or_target_invalid")
			return
		end
		local speed = tonumber(snapshot.speed)
		if not speed or not Utils.isFiniteNumber(speed) or speed < Tuning.MIN_BALL_SPEED then
			setPhase(PHASE_WAITING, "ball_too_slow")
			return
		end
		local position = snapshot.position
		if typeof(position) ~= "Vector3" then
			setPhase(PHASE_WAITING, "position_unavailable")
			return
		end
		local deflectCooldown = tonumber(GameInfo.getDeflectCD()) or 0
		if not Utils.isFiniteNumber(deflectCooldown) then
			deflectCooldown = 0
		end
		local timing = computeTiming(rootPos, position, speed, timeNow)
		if not timing then
			setPhase(PHASE_WAITING, "timing_unavailable")
			return
		end
			Runtime.parryRadius = timing.parryRadius
			Runtime.baseParryRadius = timing.pureRadius
			Runtime.resilienceBonus = timing.resilienceBonus
			Runtime.deflectWindow = timing.deflectWindow
			Runtime.effectiveWindow = timing.effectiveWindow
			Runtime.lastTTI = timing.tti
			Runtime.lastDistance = timing.distance
			Runtime.lastDistanceToParryRadius = timing.distanceToParryRadius
			Runtime.lastSpeed = timing.speed

		local insideEffectiveRadius = timing.distance <= timing.parryRadius
		if not insideEffectiveRadius then
			setPhase(PHASE_WAITING, "outside_effective_radius")
			return
		end

		if deflectCooldown > 0 then
			if not ParryState.armed then
				ParryState.armed = true
				ParryState.armedBall = ball
			end
			if Runtime.cooldownObservedAt <= 0 then
				Runtime.cooldownObservedAt = timeNow
				setPhase(PHASE_COOLDOWN, "cooldown_observed")
			elseif timeNow - Runtime.cooldownObservedAt >= Tuning.CLIENT_CD_PROPAGATION then
				setPhase(PHASE_COOLDOWN, "cooldown_propagation")
			else
				setPhase(PHASE_ARMED, "awaiting_deflect_cooldown")
			end
			return
		end

		Runtime.cooldownObservedAt = 0
		if ParryState.armed then
			if not (isValidBall(ball) and ball == ParryState.armedBall and targeted) then
				clearArmed()
				setPhase(PHASE_WAITING, "armed_context_invalid")
				return
			end
			if requestParry() then
				ParryState.fired = true
				ParryState.firedBall = ball
				ParryState.firedAt = timeNow
			end
			clearArmed()
			return
		end

		if ParryState.fired then
			if ParryState.firedBall == ball then
				setPhase(PHASE_FIRED, "ball_already_fired")
				return
			end
			if not isValidBall(ParryState.firedBall) or ParryState.firedBall ~= ball then
				clearFired()
			end
		end
		if requestParry() then
			ParryState.fired = true
			ParryState.firedBall = ball
			ParryState.firedAt = timeNow
		end
	end)
	Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
	if Utils.trackCharacter then
		Utils.trackCharacter(heartbeatConnection)
	end

	local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
		if not parent and generation == Runtime.generation then
			Runtime.generation += 1
			Runtime.bound = false
			disconnectConnections()
			clearCycle()
			setPhase(PHASE_DETACHED, "character_removed")
		end
	end)
	Runtime.connections[#Runtime.connections + 1] = ancestryConnection
	if Utils.trackCharacter then
		Utils.trackCharacter(ancestryConnection)
	end

	Runtime.bound = true
	setPhase(PHASE_WAITING, "character_bound")
	return true
end

-- lifecycle
local function resetState()
	clearCycle()
	Runtime.teleportLockUntil = 0
	Runtime.lastTarget = -1
	Runtime.pingTimer = 0
	Runtime.minPing = nil
	Runtime.pingOneWay = DEFAULT_PING_ONE_WAY
	Runtime.parryRadius = 0
	Runtime.baseParryRadius = Tuning.DEFLECT_RADIUS
	Runtime.resilienceBonus = 0
	Runtime.deflectWindow = 0
	Runtime.effectiveWindow = 0
	Runtime.lastTTI = math.huge
	Runtime.lastDistance = 0
	Runtime.lastDistanceToParryRadius = 0
	Runtime.lastSpeed = 0
	Runtime.lastFireAt = 0
	Runtime.cooldownObservedAt = 0
	Runtime.bound = false
	Runtime.passivePhase = "idle"
	Runtime.passiveCycleStart = 0
	Runtime.passiveBallAtValid = false
	setPhase(PHASE_DETACHED, "reset")
end

-- setup
function AutoParry.setup(deps)
	if type(deps) ~= "table" then return false, "dependencias invalidas" end
	local remote   = deps.Remote
	local gameInfo = deps.GameInfo
	local utils    = deps.Utils
	if type(remote) ~= "table" or type(remote.fireParry) ~= "function" then
		return false, "dependencia ausente: Remote.fireParry"
	end
	if type(gameInfo) ~= "table"
		or type(gameInfo.getDeflectCD) ~= "function"
		or type(gameInfo.getBall) ~= "function"
		or type(gameInfo.getSnapshot) ~= "function"
		or type(gameInfo.isSnapshotValid) ~= "function" then
		return false, "dependencia ausente: GameInfo"
	end
	if type(utils) ~= "table"
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
		or type(utils.isSpamActive) ~= "function" then
		return false, "dependencia ausente: Utils"
	end
	Remote   = remote
	GameInfo = gameInfo
	Utils    = utils
	StatsService = game:GetService("Stats")
	local localPlayer = Utils.getLocalPlayer()
	Runtime.localUserId = localPlayer and tonumber(localPlayer.UserId) or -1
	HitboxState.handler = handleHitbox
	resetResilience()
	resetState()
	if not installHitboxHook() and type(Utils.warn) == "function" then
		Utils.warn("hook de hitbox indisponivel")
	end
	return true
end

function AutoParry.fire()
	if not Remote or not GameInfo or not Utils then return false end
	return requestParry()
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
	Runtime.generation += 1
	Runtime.bound = false
	disconnectConnections()
	resetState()
end

function AutoParry.onBallSync(data)
	if not Utils then return end -- FIX: sem Utils, ignora silenciosamente
	onBallSync(data)
end

-- api
local function getResilienceStatus()
	return {
		stack = Resilience.stack,
		size = Runtime.resilienceBonus,
		perParry = Tuning.RES_PER_PARRY,
		cap = Tuning.RES_CAP_STUDS,
		maxStack = MAX_RES_STACK,
	}
end

function AutoParry.getRadius(mode)
	mode = mode or "geometry"
	if mode ~= "geometry"
		and mode ~= "tti"
		and mode ~= "speed_distance"
	then
		mode = "geometry"
	end

	local speed = Runtime.lastSpeed
	local distance = Runtime.lastDistance
	local tti = speed > 0 and distance / speed or math.huge
	local fullRadius = Runtime.parryRadius
	local value = fullRadius
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
		resilience = getResilienceStatus(),
		fullRadius = fullRadius,
		deflectWindow = Runtime.deflectWindow,
		effectiveWindow = Runtime.effectiveWindow,
		distance = distance,
		speed = speed,
		tti = tti,
	}
end

function AutoParry.getTiming(snapshot, time, rootPosition)
	if not Utils then return nil end
	if type(snapshot) ~= "table" then return nil end
	time = tonumber(time) or now()
	if typeof(rootPosition) ~= "Vector3" then
		local localPlayer = Utils.getLocalPlayer()
		local character = localPlayer and localPlayer.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root then
				rootPosition = root.Position
			end
		end
	end
	local speed = tonumber(snapshot.speed)
	local position = snapshot.position
	if not speed
		or not Utils.isFiniteNumber(speed)
		or speed <= 0
		or typeof(position) ~= "Vector3"
		or typeof(rootPosition) ~= "Vector3" then
		return nil
	end
	return computeTiming(rootPosition, position, speed, time)
end

function AutoParry.getStatus()
	return {
		schema          = Utils and Utils.apiVersion and Utils.apiVersion() or nil,
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
		},
		ping = {
			oneWay = Runtime.pingOneWay,
			minimum = Runtime.minPing,
		},
		cycle = {
			armed = ParryState.armed == true,
			fired = ParryState.fired == true,
			lastFireAt = Runtime.lastFireAt,
			lastTTI = Runtime.lastTTI,
		},
	}
end

AutoParry.__contract = {
	requires = {
		Remote   = "remote",
		GameInfo = "gameinfo",
		Utils    = "utils",
	},
	onBallSync    = true,
	bindCharacter = true,
}

return AutoParry
