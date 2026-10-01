-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils, StatsService

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
	WINDOW_LOW = 0.400,
	WINDOW_REFERENCE_SPEED = 600,
	WINDOW_MAX = 0.840,
	WINDOW_REFERENCE = 0.840,
	WINDOW_FACTOR = 0.45,

	PING_WINDOW_FACTOR = 1,
	PING_WINDOW_CAP = 0.400,
	PING_SAMPLE_INTERVAL = 0.35,
	PING_EMA_ALPHA = 0.08,
	DEFAULT_PING_ONE_WAY = 0.030,

	TELEPORT_LOCK_BASE = 0.400,
	RESET_LOCK_BASE = 0.400,
}

local math_max = math.max
local math_min = math.min
local math_sqrt = math.sqrt
local math_clamp = math.clamp
local math_floor = math.floor
local tonumber = tonumber
local typeof = typeof
local type = type
local pcall = pcall

local WINDOW_SLOPE =
	(Tuning.WINDOW_REFERENCE - Tuning.WINDOW_LOW)
	/ (Tuning.WINDOW_REFERENCE_SPEED - Tuning.WINDOW_LOW_SPEED)

local MAX_RES_STACK = math_floor(
	Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY
)

local HITBOX_PROXIMITY_SQ =
	Tuning.HITBOX_PROXIMITY * Tuning.HITBOX_PROXIMITY

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

local namespace =
	type(_G.Exodus) == "table" and _G.Exodus or {}

local HitboxState =
	type(namespace.AutoParryHitbox) == "table"
		and namespace.AutoParryHitbox
	or {
		connection = nil,
		handler = nil,
	}

namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

local Resilience = {
	stack = 0,
	lastFireBall = nil,
	lastFireAt = 0,
	lastHitboxAt = 0,
	hitboxConfirmed = false,
	lifeGeneration = 0,
}

local ParryLock = {
	armed = true,
	lastTargeted = false,
}

local function resetParryLock()
	ParryLock.armed = true
	ParryLock.lastTargeted = false
end

local function updateParryLock(targeted)
	if not targeted then
		ParryLock.armed = true
	elseif not ParryLock.lastTargeted then
		ParryLock.armed = true
	end

	ParryLock.lastTargeted = targeted
end

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
	pingOneWay = Tuning.DEFAULT_PING_ONE_WAY,
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

	phase = PHASE_DETACHED,

	passivePhase = "idle",
	passiveCycleStart = 0,
	passiveBallAtValid = false,

	-- cached references
	getConfig = nil,
	isSpamActive = nil,
	getSnapshot = nil,
	isSnapshotValid = nil,
	isFiniteNumber = nil,
}

-- HELPERS

local function now()
	if Utils then
		local fn = Utils.now

		if type(fn) == "function" then
			return fn()
		end
	end

	return os.clock()
end

local function isFiniteNumber(value)
	if type(value) ~= "number" then
		return false
	end

	if Utils then
		local fn = Utils.isFiniteNumber

		if type(fn) == "function" then
			return fn(value) == true
		end
	end

	return value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function setPhase(phase, reason)
	if Runtime.phase == phase then
		return
	end

	local old = Runtime.phase

	Runtime.phase = phase
	phaseString = PHASE_STRINGS[phase] or "detached"

	if Utils then
		local fn = Utils.recordTransition

		if type(fn) == "function" then
			pcall(
				fn,
				"AutoParry",
				PHASE_STRINGS[old] or "detached",
				phaseString,
				reason
			)
		end
	end
end

local function isValidBall(ball)
	return ball ~= nil and ball.Parent ~= nil
end

local function disconnectConnections()
	for i = #Runtime.connections, 1, -1 do
		local connection = Runtime.connections[i]

		Runtime.connections[i] = nil

		if connection then
			if Utils then
				local untrack = Utils.untrackCharacter

				if type(untrack) == "function" then
					pcall(untrack, connection)
				end
			end

			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end

local function distanceSquared(a, b)
	if typeof(a) ~= "Vector3"
		or typeof(b) ~= "Vector3"
	then
		return math.huge
	end

	local x = a.X - b.X
	local y = a.Y - b.Y
	local z = a.Z - b.Z

	return x * x + y * y + z * z
end

-- RESILIENCE

local function resetResilience()
	Resilience.stack = 0
	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0
	Resilience.lastHitboxAt = 0
	Resilience.hitboxConfirmed = false
	Resilience.lifeGeneration = Runtime.lifeGeneration

	Runtime.resilienceBonus = 0
	Runtime.resilienceBonusAt = -1
end

local function invalidateLife()
	Runtime.lifeGeneration += 1
	Runtime.alive = false
	Runtime.bound = false

	resetParryLock()
	resetResilience()
end

local function isResilienceUsable()
	if
		not Runtime.alive
		or not Runtime.bound
		or Resilience.lifeGeneration ~= Runtime.lifeGeneration
	then
		Resilience.stack = 0
		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0
		Resilience.lastHitboxAt = 0
		Resilience.hitboxConfirmed = false

		Runtime.resilienceBonus = 0
		Runtime.resilienceBonusAt = Runtime.lifeGeneration

		return false
	end

	local stack = Resilience.stack

	if
		type(stack) ~= "number"
		or stack < 0
		or stack > MAX_RES_STACK
	then
		Resilience.stack = 0
		Runtime.resilienceBonus = 0
		Runtime.resilienceBonusAt = Runtime.lifeGeneration

		return false
	end

	return true
end

local function getResilienceBonus(time)
	if not isResilienceUsable() then
		return 0
	end

	if Runtime.resilienceBonusAt == time then
		return Runtime.resilienceBonus
	end

	local bonus =
		math_min(
			Resilience.stack * Tuning.RES_PER_PARRY,
			Tuning.RES_CAP_STUDS
		)

	Runtime.resilienceBonus = bonus
	Runtime.resilienceBonusAt = time

	return bonus
end

-- PING

local function samplePing()
	if not StatsService then
		return
	end

	local ok, item = pcall(function()
		return StatsService.Network.ServerStatsItem["Data Ping"]
	end)

	if not ok or not item then
		return
	end

	local valid, ping = pcall(item.GetValue, item)

	if
		not valid
		or not isFiniteNumber(ping)
	then
		return
	end

	ping *= 0.001

	if ping <= 0 or ping >= 0.5 then
		return
	end

	if not Runtime.minPing or ping < Runtime.minPing then
		Runtime.minPing = ping
	end

	local oneWay = ping * 0.5

	Runtime.pingOneWay +=
		(oneWay - Runtime.pingOneWay)
		* Tuning.PING_EMA_ALPHA
end

-- TIMING

local function computeDeflectWindow(speed)
	local raw = tonumber(speed) or 0

	if raw <= Tuning.WINDOW_LOW_SPEED then
		return Tuning.WINDOW_LOW
	end

	return math_min(
		math_max(
			Tuning.WINDOW_LOW
				+ (raw - Tuning.WINDOW_LOW_SPEED)
				* WINDOW_SLOPE,
			0
		),
		Tuning.WINDOW_MAX
	)
end

local function computePingRadius(speed)
	if speed <= 0 then
		return 0
	end

	local pingWindow =
		math_min(
			Runtime.pingOneWay
				* 2
				* Tuning.PING_WINDOW_FACTOR,
			Tuning.PING_WINDOW_CAP
		)

	return speed * pingWindow
end

local function computeNoWindowParryRadius(
	speed,
	resilience
)
	return Tuning.DEFLECT_RADIUS
		+ (resilience or 0)
		+ computePingRadius(speed)
end

local function computeTiming(
	rootPosition,
	position,
	speed,
	time,
	windowFactor
)
	if
		typeof(rootPosition) ~= "Vector3"
		or typeof(position) ~= "Vector3"
		or not isFiniteNumber(speed)
		or speed <= 0
	then
		return nil
	end

	local resilience =
		getResilienceBonus(time)

	local deflectWindow =
		computeDeflectWindow(speed)

	local factor =
		tonumber(windowFactor)

	if
		not factor
		or not isFiniteNumber(factor)
	then
		factor = Tuning.WINDOW_FACTOR
	end

	factor = math_clamp(factor, 0, 1.5)

	local effectiveWindow =
		deflectWindow * factor

	local pingRadius =
		computePingRadius(speed)

	local noWindowParryRadius =
		Tuning.DEFLECT_RADIUS
		+ resilience
		+ pingRadius

	local parryRadius =
		noWindowParryRadius
		+ speed * effectiveWindow

	local distSq =
		distanceSquared(
			rootPosition,
			position
		)

	if distSq == math.huge then
		return nil
	end

	local distance =
		math_sqrt(distSq)

	local delta =
		distance - parryRadius

	local tti =
		delta <= 0
			and 0
			or delta / speed

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
		windowFactor = factor,
		stationary = false,
	}
end

local function getSnapshot(time)
	local getSnapshotRef =
		GameInfo
		and GameInfo.getSnapshot

	local validate =
		GameInfo
		and GameInfo.isSnapshotValid

	if
		type(getSnapshotRef) ~= "function"
		or type(validate) ~= "function"
	then
		return nil
	end

	local snapshot =
		getSnapshotRef(nil, time)

	if type(snapshot) ~= "table" then
		return nil
	end

	if not validate(snapshot, time) then
		return nil
	end

	return snapshot
end

local function isBallInParryWindow(time)
	local snapshot =
		getSnapshot(time)

	if not snapshot then
		return false, false
	end

	local ball =
		snapshot.ball

	if not isValidBall(ball) then
		return false, false
	end

	local speed =
		tonumber(snapshot.speed)

	if
		not speed
		or speed < Tuning.MIN_BALL_SPEED
		or not isFiniteNumber(speed)
	then
		return false, false
	end

	local position =
		snapshot.position

	local root =
		Runtime.root

	if
		typeof(position) ~= "Vector3"
		or not root
		or not root.Parent
	then
		return false, false
	end

	local timing =
		computeTiming(
			root.Position,
			position,
			speed,
			time
		)

	if not timing then
		return false, false
	end

	return timing.distance <= timing.parryRadius, true
end

-- PARRY

local function requestParry(ball)
	if
		not Runtime.alive
		or not Runtime.bound
	then
		return false
	end

	if
		not Remote
		or type(Remote.fireParry) ~= "function"
	then
		if Utils then
			local recordError =
				Utils.recordError

			if type(recordError) == "function" then
				pcall(
					recordError,
					"AutoParry",
					"Remote.fireParry indisponivel"
				)
			end
		end

		setPhase(
			PHASE_WAITING,
			"remote_unavailable"
		)

		return false
	end

	local time =
		now()

	local ok, result =
		pcall(
			Remote.fireParry,
			1
		)

	if not ok or result == false then
		if Utils then
			local recordError =
				Utils.recordError

			if type(recordError) == "function" then
				pcall(
					recordError,
					"AutoParry",
					"Remote.fireParry falhou: " .. tostring(result)
				)
			end
		end

		setPhase(
			PHASE_WAITING,
			"remote_failed"
		)

		return false
	end

	Runtime.lastFireAt = time
	Resilience.hitboxConfirmed = false

	local firedBall = ball

	if not isValidBall(firedBall) then
		local okBall, currentBall =
			pcall(GameInfo.getBall)

		if okBall then
			firedBall = currentBall
		end
	end

	if
		isValidBall(firedBall)
		and Runtime.alive
		and Runtime.bound
		and Resilience.lifeGeneration
			== Runtime.lifeGeneration
	then
		Resilience.lastFireBall = firedBall
		Resilience.lastFireAt = time
	else
		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0
	end

	setPhase(
		PHASE_FIRED,
		"parry_requested"
	)

	return true
end

-- SYNC

local function onBallSync(data)
	if
		typeof(data) ~= "table"
		or not Runtime.alive
		or not Runtime.bound
	then
		return
	end

	local time =
		now()

	if
		data.Teleported == true
		or data.Grace == true
		or data.OldGrace == true
	then
		Runtime.teleportLockUntil =
			math_max(
				Runtime.teleportLockUntil,
				time
					+ Tuning.RESET_LOCK_BASE
					+ Runtime.pingOneWay
			)

		resetParryLock()

		Runtime.passivePhase = "idle"
		Runtime.passiveBallAtValid = false

		setPhase(
			PHASE_WAITING,
			"teleport_lock"
		)

		return
	end

	local targetId = -1

	if GameInfo then
		local getTargetId =
			GameInfo.getTargetId

		if type(getTargetId) == "function" then
			local ok, value =
				pcall(getTargetId)

			if ok then
				targetId =
					tonumber(value) or -1
			end
		end
	end

	if targetId == -1 then
		targetId =
			tonumber(data.TargetPlayerID)
			or -1
	end

	Runtime.targetId = targetId
	Runtime.targetKnown = true

	local previousTarget =
		Runtime.lastTarget

	local previousWasMe =
		Runtime.lastWasMe

	if
		targetId == previousTarget
		and previousWasMe ~= nil
	then
		if
			Utils
			and type(Utils.isSpamActive) == "function"
			and Utils.isSpamActive()
			and Runtime.passivePhase
				== "awaiting_leave"
		then
			local inside, valid =
				isBallInParryWindow(time)

			if valid and inside then
				Runtime.passiveBallAtValid = true
			end
		end

		return
	end

	Runtime.lastTarget = targetId

	local isMe =
		targetId == Runtime.localUserId

	Runtime.lastWasMe = isMe

	local spamActive =
		Utils
		and type(Utils.isSpamActive) == "function"
		and Utils.isSpamActive()

	if spamActive then
		if not isMe then
			if Runtime.passivePhase == "awaiting_leave" then
				if
					Runtime.passiveBallAtValid
					and isResilienceUsable()
				then
					Resilience.stack =
						math_min(
							Resilience.stack + 1,
							MAX_RES_STACK
						)

					Runtime.resilienceBonusAt = -1
				end

				Runtime.passivePhase = "idle"
				Runtime.passiveBallAtValid = false
			end
		else
			if previousWasMe ~= true then
				Runtime.passivePhase =
					"awaiting_leave"

				Runtime.passiveCycleStart =
					time

				local inside, valid =
					isBallInParryWindow(time)

				Runtime.passiveBallAtValid =
					valid and inside
			else
				local inside, valid =
					isBallInParryWindow(time)

				if valid and inside then
					Runtime.passiveBallAtValid = true
				end
			end
		end
	else
		Runtime.passivePhase = "idle"
		Runtime.passiveBallAtValid = false
	end
end

-- HEARTBEAT

local function onHeartbeat(
	character,
	root,
	dt
)
	if
		not character
		or not character.Parent
		or not root
		or not root.Parent
	then
		return
	end

	local timeNow =
		now()

	local getConfig =
		Runtime.getConfig

	local isSpamActive =
		Runtime.isSpamActive

	local getSnapshotRef =
		Runtime.getSnapshot

	local isSnapshotValid =
		Runtime.isSnapshotValid

	local finite =
		Runtime.isFiniteNumber

	if
		not getConfig
		or not isSpamActive
		or not getSnapshotRef
		or not isSnapshotValid
	then
		return
	end

	local config =
		getConfig()

	if
		type(config) ~= "table"
		or config.AutoParry ~= true
	then
		resetParryLock()
		return
	end

	if timeNow < Runtime.teleportLockUntil then
		resetParryLock()
		return
	end

	if isSpamActive() then
		resetParryLock()
		return
	end

	-- Ping is sampled independently from the actual
	-- parry calculation, so it never blocks the
	-- immediate decision.
	Runtime.pingTimer +=
		math_max(
			tonumber(dt) or 0,
			0
		)

	if Runtime.pingTimer >= Tuning.PING_SAMPLE_INTERVAL then
		Runtime.pingTimer = 0
		samplePing()
	end

	local snapshotCallOk, snapshot = pcall(getSnapshotRef, nil, timeNow)

	if
		not snapshotCallOk
		or type(snapshot) ~= "table"
	then
		resetParryLock()
		return
	end
	local validCallOk, snapshotValid = pcall(isSnapshotValid, snapshot, timeNow)
	if not validCallOk or snapshotValid ~= true then
		resetParryLock()
		return
	end

	if snapshot.resetting == true then
		resetParryLock()
		return
	end

	-- O GameInfo já contém a resolução de alvo do PhantomBallz.
	local targeted = snapshot.targeted == true
	local targetId = tonumber(snapshot.targetId) or -1

	Runtime.targetId = targetId
	Runtime.targetKnown = snapshot.targetId ~= nil
	Runtime.lastTarget = targetId

	-- Mesma trava do PhantomBallz: desarma apenas depois de um parry
	-- e rearma quando deixa de ser alvo ou quando volta a ser alvo.
	updateParryLock(targeted)

	if not targeted then
		setPhase(
			PHASE_WAITING,
			"not_targeted"
		)

		return
	end

	local ball =
		snapshot.ball

	if not isValidBall(ball) then
		resetParryLock()
		return
	end

	local speed =
		tonumber(snapshot.speed)
	local velocity =
		snapshot.velocity

	-- O PhantomBallz usa a velocidade instantânea da bola. O GameInfo
	-- normalmente fornece a velocidade sincronizada, mas ela pode ficar
	-- abaixo da velocidade física durante uma aceleração.
	if typeof(velocity) == "Vector3" then
		speed = math_max(
			speed or 0,
			velocity.Magnitude
		)
	end

	if
		not speed
		or speed < Tuning.MIN_BALL_SPEED
		or not finite(speed)
	then
		return
	end

	local position
	local positionCallOk =
		pcall(function()
			position = ball.Position
		end)

	if not positionCallOk or typeof(position) ~= "Vector3" then
		return
	end

	local rootPosition =
		root.Position

	if typeof(rootPosition) ~= "Vector3" then
		return
	end

	local timing =
		computeTiming(
			rootPosition,
			position,
			speed,
			timeNow
		)

	if not timing then
		return
	end

	Runtime.parryRadius =
		timing.parryRadius

	Runtime.baseParryRadius =
		timing.pureRadius

	Runtime.noWindowParryRadius =
		timing.noWindowParryRadius

	Runtime.pingRadius =
		timing.pingRadius

	Runtime.resilienceBonus =
		timing.resilienceBonus

	Runtime.deflectWindow =
		timing.deflectWindow

	Runtime.effectiveWindow =
		timing.effectiveWindow

	Runtime.lastTTI =
		timing.tti

	Runtime.lastDistance =
		timing.distance

	Runtime.lastDistanceToParryRadius =
		timing.distanceToParryRadius

	Runtime.lastSpeed =
		timing.speed

	if timing.distance > timing.parryRadius then
		setPhase(
			PHASE_WAITING,
			"outside_radius"
		)

		return
	end

	if not ParryLock.armed then
		return
	end

	if requestParry(ball) then
		ParryLock.armed = false
	end
end

-- HITBOX

local function handleHitbox(instance)
	if
		typeof(instance) ~= "Instance"
		or instance.Name ~= "HitboxGrow"
		or not Utils
		or type(Utils.isActive) ~= "function"
		or not Utils.isActive()
		or Resilience.hitboxConfirmed
	then
		return
	end

	if not isResilienceUsable() then
		return
	end

	local time =
		now()

	if
		time - Resilience.lastFireAt
			> Tuning.HITBOX_OWN_WINDOW
		or time - Resilience.lastHitboxAt
			< Tuning.HITBOX_GAP
	then
		return
	end

	local ball =
		Resilience.lastFireBall

	if not isValidBall(ball) then
		return
	end

	if not instance:IsA("BasePart") then
		return
	end

	local position =
		instance.Position

	local ballPosition =
		ball.Position

	if
		typeof(position) ~= "Vector3"
		or typeof(ballPosition) ~= "Vector3"
	then
		return
	end

	if
		distanceSquared(
			ballPosition,
			position
		) > HITBOX_PROXIMITY_SQ
	then
		return
	end

	if
		not Runtime.alive
		or not Runtime.bound
		or Resilience.lifeGeneration
			~= Runtime.lifeGeneration
	then
		return
	end

	Resilience.hitboxConfirmed = true
	Resilience.lastHitboxAt = time

	Resilience.stack =
		math_min(
			Resilience.stack + 1,
			MAX_RES_STACK
		)

	Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
	if HitboxState.connection then
		return true
	end

	local workspaceService =
		Runtime.workspace

	if not workspaceService then
		return false
	end

	local ok, connection =
		pcall(function()
			return workspaceService.DescendantAdded:Connect(
				function(instance)
					local handler =
						HitboxState.handler

					if handler then
						handler(instance)
					end
				end
			)
		end)

	if not ok or not connection then
		return false
	end

	HitboxState.connection =
		connection

	if Utils then
		local trackGlobal =
			Utils.trackGlobal

		if type(trackGlobal) == "function" then
			pcall(
				trackGlobal,
				connection
			)
		end
	end

	return true
end

-- CHARACTER

local function bindCharacter(character)
	if
		not Remote
		or not GameInfo
		or not Utils
	then
		return false, "dependencias nao inicializadas"
	end

	Runtime.generation += 1

	local generation =
		Runtime.generation

	disconnectConnections()
	invalidateLife()

	setPhase(
		PHASE_DETACHED,
		"rebind_start"
	)

	if
		not character
		or not character.Parent
	then
		return false
	end

	local root =
		character:FindFirstChild(
			"HumanoidRootPart"
		)

	if not root then
		local ok, result =
			pcall(
				character.WaitForChild,
				character,
				"HumanoidRootPart",
				1
			)

		if ok then
			root = result
		end
	end

	if
		generation ~= Runtime.generation
		or not root
		or not root.Parent
	then
		return false
	end

	local humanoid =
		character:FindFirstChildOfClass(
			"Humanoid"
		)

	if
		humanoid
		and humanoid.Health <= 0
	then
		return false
	end

	Runtime.character = character
	Runtime.root = root

	if humanoid then
		local diedConnection =
			humanoid.Died:Connect(
				function()
					if generation ~= Runtime.generation then
						return
					end

					Runtime.generation += 1

					invalidateLife()

					setPhase(
						PHASE_DETACHED,
						"character_died"
					)
				end
			)

		Runtime.connections[
			#Runtime.connections + 1
		] = diedConnection

		if type(Utils.trackCharacter) == "function" then
			Utils.trackCharacter(
				diedConnection
			)
		end
	end

	local runService =
		Utils.getRunService()

	if not runService then
		invalidateLife()
		return false, "RunService indisponivel"
	end

	-- Cache all functions used every frame.
	Runtime.getConfig =
		Utils.getConfig

	Runtime.isSpamActive =
		Utils.isSpamActive

	Runtime.getSnapshot =
		GameInfo.getSnapshot

	Runtime.isSnapshotValid =
		GameInfo.isSnapshotValid

	Runtime.isFiniteNumber =
		Utils.isFiniteNumber

	local frameSignal =
		runService.PostSimulation
		or runService.Heartbeat

	local heartbeatConnection =
		frameSignal:Connect(
			function(dt)
				if
					generation ~= Runtime.generation
					or not Runtime.alive
					or not Runtime.bound
				then
					return
				end

				onHeartbeat(
					character,
					root,
					dt
				)
			end
		)

	Runtime.connections[
		#Runtime.connections + 1
	] = heartbeatConnection

	Utils.trackCharacter(
		heartbeatConnection
	)

	local ancestryConnection =
		character.AncestryChanged:Connect(
			function(_, parent)
				if
					not parent
					and generation == Runtime.generation
				then
					Runtime.generation += 1

					invalidateLife()
					disconnectConnections()

					Runtime.character = nil
					Runtime.root = nil

					setPhase(
						PHASE_DETACHED,
						"character_removed"
					)
				end
			end
		)

	Runtime.connections[
		#Runtime.connections + 1
	] = ancestryConnection

	Utils.trackCharacter(
		ancestryConnection
	)

	Runtime.bound = true
	Runtime.alive = true

	Resilience.lifeGeneration =
		Runtime.lifeGeneration

	setPhase(
		PHASE_WAITING,
		"character_bound"
	)

	return true
end

-- RESET

local function resetState()
	invalidateLife()

	Runtime.teleportLockUntil = 0

	Runtime.lastTarget = -1
	Runtime.lastWasMe = nil

	Runtime.targetId = -1
	Runtime.targetKnown = false

	Runtime.pingTimer = 0
	Runtime.minPing = nil
	Runtime.pingOneWay =
		Tuning.DEFAULT_PING_ONE_WAY

	Runtime.parryRadius = 0

	Runtime.baseParryRadius =
		Tuning.DEFLECT_RADIUS

	Runtime.noWindowParryRadius =
		Tuning.DEFLECT_RADIUS

	Runtime.pingRadius = 0

	Runtime.resilienceBonus = 0
	Runtime.resilienceBonusAt = -1

	Runtime.deflectWindow = 0
	Runtime.effectiveWindow = 0

	Runtime.lastTTI = math.huge

	Runtime.lastDistance = 0
	Runtime.lastDistanceToParryRadius = 0

	Runtime.lastSpeed = 0
	Runtime.lastFireAt = 0

	Runtime.passivePhase = "idle"
	Runtime.passiveCycleStart = 0
	Runtime.passiveBallAtValid = false

	Runtime.getConfig = nil
	Runtime.isSpamActive = nil
	Runtime.getSnapshot = nil
	Runtime.isSnapshotValid = nil
	Runtime.isFiniteNumber = nil

	setPhase(
		PHASE_DETACHED,
		"reset"
	)
end

-- SETUP

function AutoParry.setup(deps)
	if type(deps) ~= "table" then
		return false, "dependencias invalidas"
	end

	local remote = deps.Remote
	local gameInfo = deps.GameInfo
	local utils = deps.Utils

	if
		type(remote) ~= "table"
		or type(remote.fireParry) ~= "function"
	then
		return false,
			"dependencia ausente: Remote.fireParry"
	end

	if
		type(gameInfo) ~= "table"
		or type(gameInfo.getBall) ~= "function"
		or type(gameInfo.getSnapshot) ~= "function"
		or type(gameInfo.isSnapshotValid) ~= "function"
	then
		return false,
			"dependencia ausente: GameInfo"
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
		return false,
			"dependencia ausente: Utils"
	end

	Remote = remote
	GameInfo = gameInfo
	Utils = utils

	local okStats, stats =
		pcall(
			game.GetService,
			game,
			"Stats"
		)

	StatsService =
		okStats and stats or nil

	Runtime.player =
		Utils.getLocalPlayer()

	Runtime.localUserId =
		Runtime.player
		and tonumber(Runtime.player.UserId)
		or -1

	Runtime.workspace =
		Utils.getWorkspace()

	HitboxState.handler =
		handleHitbox

	resetState()

	if
		not installHitboxHook()
		and type(Utils.warn) == "function"
	then
		Utils.warn(
			"hook de hitbox indisponivel"
		)
	end

	return true
end

-- PUBLIC

function AutoParry.fire()
	if
		not Remote
		or not GameInfo
		or not Utils
		or not Runtime.alive
		or not Runtime.bound
	then
		return false
	end

	local ball

	local ok, result =
		pcall(GameInfo.getBall)

	if ok then
		ball = result
	end

	local fired =
		requestParry(ball)

	if fired then
		ParryLock.armed = false
	end

	return fired
end

function AutoParry.bindCharacter(character)
	if
		not Remote
		or not GameInfo
		or not Utils
	then
		return false
	end

	return bindCharacter(character)
end

function AutoParry.resetState()
	if Utils then
		resetState()
	end
end

function AutoParry.detachCharacter()
	if not Utils then
		return
	end

	Runtime.generation += 1

	disconnectConnections()
	invalidateLife()

	Runtime.character = nil
	Runtime.root = nil

	setPhase(
		PHASE_DETACHED,
		"detach"
	)
end

function AutoParry.teardown()
	AutoParry.detachCharacter()

	if HitboxState.connection then
		if
			Utils
			and type(Utils.untrackGlobal) == "function"
		then
			pcall(
				Utils.untrackGlobal,
				HitboxState.connection
			)
		end

		pcall(
			HitboxState.connection.Disconnect,
			HitboxState.connection
		)

		HitboxState.connection = nil
	end

	Remote = nil
	GameInfo = nil
	Utils = nil
	StatsService = nil

	Runtime.player = nil
	Runtime.workspace = nil

	Runtime.getConfig = nil
	Runtime.isSpamActive = nil
	Runtime.getSnapshot = nil
	Runtime.isSnapshotValid = nil
	Runtime.isFiniteNumber = nil
end

function AutoParry.onBallSync(data)
	if Utils then
		onBallSync(data)
	end
end

function AutoParry.getTargetStatus()
	if not Utils then
		return nil
	end

	return {
		armed = ParryLock.armed == true,
		lastTargeted =
			ParryLock.lastTargeted == true,
	}
end

-- API

local function getResilienceStatus()
	local usable =
		isResilienceUsable()

	return {
		stack =
			usable and Resilience.stack or 0,

		size =
			usable
			and Runtime.resilienceBonus
			or 0,

		perParry =
			Tuning.RES_PER_PARRY,

		cap =
			Tuning.RES_CAP_STUDS,

		maxStack =
			MAX_RES_STACK,
	}
end

function AutoParry.getRadius(
	mode,
	windowFactor,
	speedOverride
)
	mode = mode or "geometry"

	if
		mode ~= "geometry"
		and mode ~= "tti"
		and mode ~= "speed_distance"
	then
		mode = "geometry"
	end

	local speed =
		tonumber(speedOverride)

	if
		not speed
		or not isFiniteNumber(speed)
		or speed < 0
	then
		speed = Runtime.lastSpeed
	end

	local distance =
		Runtime.lastDistance

	local tti =
		speed > 0
		and distance / speed
		or math.huge

	local requestedFactor =
		tonumber(windowFactor)

	if
		not requestedFactor
		or not isFiniteNumber(requestedFactor)
	then
		requestedFactor =
			Tuning.WINDOW_FACTOR
	end

	requestedFactor =
		math_clamp(
			requestedFactor,
			0,
			1.5
		)

	local deflectWindow =
		computeDeflectWindow(speed)

	local effectiveWindow =
		deflectWindow * requestedFactor

	local resilience =
		getResilienceBonus(now())

	local pingRadius =
		computePingRadius(speed)

	local noWindowParryRadius =
		Tuning.DEFLECT_RADIUS
		+ resilience
		+ pingRadius

	local fullRadius =
		noWindowParryRadius
		+ speed * effectiveWindow

	local value = fullRadius

	if mode == "tti" then
		value =
			math_max(
				distance - fullRadius,
				0
			)
			/ math_max(speed, 1)

	elseif mode == "speed_distance" then
		value = {
			speed = speed,
			distance = distance,
		}
	end

	return {
		mode = mode,

		value = value,

		pureRadius =
			Tuning.DEFLECT_RADIUS,

		noWindowParryRadius =
			noWindowParryRadius,

		pingRadius =
			pingRadius,

		resilience =
			getResilienceStatus(),

		fullRadius =
			fullRadius,

		deflectWindow =
			deflectWindow,

		windowFactor =
			requestedFactor,

		effectiveWindow =
			effectiveWindow,

		distance =
			distance,

		speed =
			speed,

		tti =
			tti,
	}
end

function AutoParry.getTiming(
	snapshot,
	time,
	rootPosition,
	windowFactor
)
	if
		not Utils
		or type(snapshot) ~= "table"
	then
		return nil
	end

	time =
		tonumber(time)
		or now()

	if typeof(rootPosition) ~= "Vector3" then
		local root =
			Runtime.root

		if root and root.Parent then
			rootPosition =
				root.Position
		else
			local player =
				Runtime.player

			local character =
				player
				and player.Character

			local newRoot =
				character
				and character:FindFirstChild(
					"HumanoidRootPart"
				)

			if newRoot then
				rootPosition =
					newRoot.Position
			end
		end
	end

	local speed =
		tonumber(snapshot.speed)

	local position =
		snapshot.position

	if
		not speed
		or not isFiniteNumber(speed)
		or speed <= 0
		or typeof(position) ~= "Vector3"
		or typeof(rootPosition) ~= "Vector3"
	then
		return nil
	end

	return computeTiming(
		rootPosition,
		position,
		speed,
		time,
		windowFactor
	)
end

function AutoParry.getStatus()
	local target =
		AutoParry.getTargetStatus()

	return {
		schema =
			Utils
			and Utils.apiVersion
			and Utils.apiVersion()
			or nil,

		api = {
			name = "AutoParry",
			version = 6,

			endpoints = {
				"getRadius",
				"getTiming",
				"getStatus",
				"getTargetStatus",
			},
		},

		lifecycle = {
			phase = phaseString,

			bound =
				Runtime.bound == true,

			alive =
				Runtime.alive == true,

			lifeGeneration =
				Runtime.lifeGeneration,
		},

		radius =
			AutoParry.getRadius(
				"geometry"
			),

		resilience =
			getResilienceStatus(),

		timing = {
			tti =
				Runtime.lastTTI,

			speed =
				Runtime.lastSpeed,

			distance =
				Runtime.lastDistance,

			distanceToRadius =
				Runtime.lastDistanceToParryRadius,

			deflectWindow =
				Runtime.deflectWindow,

			effectiveWindow =
				Runtime.effectiveWindow,

			noWindowParryRadius =
				Runtime.noWindowParryRadius,

			pingRadius =
				Runtime.pingRadius,
		},

		ping = {
			oneWay =
				Runtime.pingOneWay,

			minimum =
				Runtime.minPing,
		},

		target =
			target,

		cycle = {
			fired =
				target
				and target.armed == false
				or false,

			lastFireAt =
				Runtime.lastFireAt,

			lastTTI =
				Runtime.lastTTI,
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
