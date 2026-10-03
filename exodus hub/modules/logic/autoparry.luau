-- [[ autoparry ]]

local AutoParry = {}
local Remote
local GameInfo
local Utils

-- tuning
local T = {
	VELOCITY_SMOOTHING_TAU = 0.05,
	PING_SAMPLE_INTERVAL = 1,

	BASE_RADIUS = 8.5,
	BASE_WINDOW = 0.40,
	DEFAULT_WINDOW_FACTOR = 0.50,
	MIN_WINDOW_FACTOR = 0.0,
	MAX_WINDOW_FACTOR = 1.5,

	MIN_LEAD_TIME = 0.48,
	MAX_LEAD_TIME = 0.84,

	MIN_BALL_SPEED = 16,

	RES_PER_PARRY = 0.225,
	RES_CAP_STUDS = 32,

	HITBOX_OWN_WINDOW = 0.50,
	HITBOX_PROXIMITY = 12,
	HITBOX_GAP = 0.40,

	-- antigo sistema de trava
	TELEPORT_LOCK_BASE = 0.40,

	MAX_RES_STACK = math.floor(32 / 0.225),
}

local HITBOX_PROXIMITY_SQ =
	T.HITBOX_PROXIMITY ^ 2

-- state
local R = {
	phase = "detached",

	generation = 0,
	lifeGeneration = 0,

	alive = false,
	bound = false,

	player = nil,
	character = nil,
	root = nil,
	workspace = nil,

	connections = {},

	armed = true,
	lastTargeted = false,
	targeted = false,

	lastBall = nil,
	lastPosition = nil,
	lastPositionAt = nil,
	velocity = Vector3.zero,

	ping = 0,
	pingAt = 0,

	lastDistance = 0,
	lastSpeed = 0,
	lastRadius = 0,
	lastLeadTime = T.MIN_LEAD_TIME,

	lastFireAt = 0,
	lastApproaching = false,

	lastTarget = -1,
	lastWasMe = nil,

	targetId = -1,
	targetKnown = false,

	-- antigo: somente Teleported controla a trava
	teleported = false,
	teleportLockUntil = 0,

	passivePhase = "idle",
	passiveBallAtValid = false,

	resilienceBonus = 0,
	resilienceBonusAt = -1,
}

local Resilience = {
	stack = 0,
	lastFireBall = nil,
	lastFireAt = 0,
	lastHitboxAt = 0,
	hitboxConfirmed = false,
	lifeGeneration = 0,
}

local namespace =
	type(_G.Exodus) == "table"
	and _G.Exodus
	or {}

local HitboxState =
	namespace.AutoParryHitbox

if type(HitboxState) ~= "table" then
	HitboxState = {
		connection = nil,
		workspace = nil,
		handler = nil,
	}

	namespace.AutoParryHitbox =
		HitboxState
end

_G.Exodus = namespace

local function clock()
	return os.clock()
end

local function isFiniteNumber(value)
	return type(value) == "number"
		and value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function isValidVector3(value)
	return typeof(value) == "Vector3"
end

local function isValidBall(ball)
	return typeof(ball) == "Instance"
		and ball.Parent ~= nil
		and ball:IsA("BasePart")
end

local function distanceSquared(a, b)
	local delta = a - b
	return delta:Dot(delta)
end

local function getRootPart(character)
	local root =
		character:FindFirstChild(
			"HumanoidRootPart"
		)

	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

local function setPhase(nextPhase, reason)
	if R.phase == nextPhase then
		return
	end

	local previous = R.phase
	R.phase = nextPhase

	if Utils
		and type(Utils.recordTransition)
			== "function"
	then
		pcall(
			Utils.recordTransition,
			"AutoParry",
			previous,
			nextPhase,
			reason
		)
	end
end

local function trackConnection(connection)
	if not connection then
		return
	end

	R.connections[#R.connections + 1] =
		connection

	if Utils
		and type(Utils.trackCharacter)
			== "function"
	then
		pcall(
			Utils.trackCharacter,
			connection
		)
	end
end

local function disconnectConnections()
	for i = #R.connections, 1, -1 do
		local connection =
			R.connections[i]

		R.connections[i] = nil

		if connection then
			if Utils
				and type(Utils.untrackCharacter)
					== "function"
			then
				pcall(
					Utils.untrackCharacter,
					connection
				)
			end

			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end

local function resetParryLock()
	R.armed = true
	R.lastTargeted = false
end

local function clearBallState()
	R.targeted = false

	R.lastBall = nil
	R.lastPosition = nil
	R.lastPositionAt = nil
	R.velocity = Vector3.zero

	R.lastDistance = 0
	R.lastSpeed = 0
	R.lastRadius = 0
	R.lastLeadTime = T.MIN_LEAD_TIME
	R.lastApproaching = false

	R.targetId = -1
	R.targetKnown = false
end

local function resetTracking()
	R.armed = true
	R.lastTargeted = false
	R.targeted = false

	R.lastBall = nil
	R.lastPosition = nil
	R.lastPositionAt = nil
	R.velocity = Vector3.zero

	R.ping = 0
	R.pingAt = 0

	R.lastDistance = 0
	R.lastSpeed = 0
	R.lastRadius = 0
	R.lastLeadTime = T.MIN_LEAD_TIME

	R.lastFireAt = 0
	R.lastApproaching = false

	R.lastTarget = -1
	R.lastWasMe = nil

	R.targetId = -1
	R.targetKnown = false

	R.teleported = false
	R.teleportLockUntil = 0

	R.passivePhase = "idle"
	R.passiveBallAtValid = false

	R.resilienceBonus = 0
	R.resilienceBonusAt = -1
end

local function resetResilience()
	Resilience.stack = 0
	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0
	Resilience.lastHitboxAt = 0
	Resilience.hitboxConfirmed = false
	Resilience.lifeGeneration =
		R.lifeGeneration

	R.resilienceBonus = 0
	R.resilienceBonusAt = -1
end

local function clearResilienceState()
	Resilience.stack = 0
	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0
	Resilience.lastHitboxAt = 0
	Resilience.hitboxConfirmed = false

	R.resilienceBonus = 0
	R.resilienceBonusAt = -1
end

local function invalidateLife()
	R.lifeGeneration += 1
	R.alive = false
	R.bound = false

	resetParryLock()
	resetResilience()
end

local function isResilienceUsable()
	if not R.alive
		or not R.bound
		or Resilience.lifeGeneration
			~= R.lifeGeneration
	then
		clearResilienceState()
		return false
	end

	if not isFiniteNumber(Resilience.stack)
		or Resilience.stack < 0
		or Resilience.stack > T.MAX_RES_STACK
	then
		clearResilienceState()
		return false
	end

	return true
end

local function getResilienceBonus(time)
	if not isResilienceUsable() then
		return 0
	end

	if R.resilienceBonusAt == time then
		return R.resilienceBonus
	end

	R.resilienceBonus = math.min(
		Resilience.stack
			* T.RES_PER_PARRY,
		T.RES_CAP_STUDS
	)

	R.resilienceBonusAt = time

	return R.resilienceBonus
end

local function getResilienceStatus()
	local usable =
		isResilienceUsable()

	return {
		stack =
			usable
			and Resilience.stack
			or 0,

		size =
			usable
			and getResilienceBonus(clock())
			or 0,

		perParry =
			T.RES_PER_PARRY,

		cap =
			T.RES_CAP_STUDS,

		maxStack =
			T.MAX_RES_STACK,
	}
end

local function addResilienceStack()
	if not isResilienceUsable() then
		return false
	end

	if Resilience.stack
		>= T.MAX_RES_STACK
	then
		return false
	end

	Resilience.stack += 1
	R.resilienceBonusAt = -1

	return true
end

local function getConfig()
	if not Utils
		or type(Utils.getConfig)
			~= "function"
	then
		return nil
	end

	local ok, config =
		pcall(Utils.getConfig)

	if ok and type(config) == "table" then
		return config
	end

	return nil
end

local function isAutoParryEnabled()
	local config =
		getConfig()

	if not config then
		return true
	end

	return config.AutoParry ~= false
end

local function isSystemActive()
	if not Utils
		or type(Utils.isActive)
			~= "function"
	then
		return true
	end

	local ok, active =
		pcall(Utils.isActive)

	return ok and active == true
end

local function isSpamActive()
	if not Utils
		or type(Utils.isSpamActive)
			~= "function"
	then
		return false
	end

	local ok, active =
		pcall(Utils.isSpamActive)

	return ok and active == true
end

local function computeLeadTime(ping)
	local validPing =
		isFiniteNumber(ping)
		and math.max(ping, 0)
		or 0

	local leadTime =
		T.BASE_WINDOW + validPing

	leadTime = math.clamp(
		leadTime,
		T.MIN_LEAD_TIME,
		T.MAX_LEAD_TIME
	)

	return math.floor(
		leadTime * 100 + 0.5
	) / 100
end

local function computeParryRadius(
	speed,
	ping,
	resilienceBonus,
	windowFactor
)
	local validSpeed =
		isFiniteNumber(speed)
		and math.max(speed, 0)
		or 0

	local leadTime =
		computeLeadTime(ping)

	local factor =
		tonumber(windowFactor)

	if not isFiniteNumber(factor) then
		factor =
			T.DEFAULT_WINDOW_FACTOR
	end

	factor = math.clamp(
		factor,
		T.MIN_WINDOW_FACTOR,
		T.MAX_WINDOW_FACTOR
	)

	local validResilience =
		isFiniteNumber(resilienceBonus)
		and math.max(resilienceBonus, 0)
		or 0

	local baseRadius =
		T.BASE_RADIUS
		+ validResilience

	local anticipation =
		validSpeed
		* leadTime
		* factor

	local noWindowRadius =
		baseRadius

	local pingRadius =
		validSpeed
		* math.max(
			leadTime - T.BASE_WINDOW,
			0
		)

	local fullRadius =
		baseRadius + anticipation

	local effectiveWindow =
		T.BASE_WINDOW * factor

	return
		fullRadius,
		leadTime,
		noWindowRadius,
		pingRadius,
		T.BASE_WINDOW,
		effectiveWindow,
		factor
end

local function readTargeted(snapshot)
	if type(snapshot) == "table"
		and type(snapshot.targeted)
			== "boolean"
	then
		return snapshot.targeted
	end

	if GameInfo
		and type(GameInfo.getSyncData)
			== "function"
	then
		local ok, syncData =
			pcall(
				GameInfo.getSyncData
			)

		if ok
			and type(syncData) == "table"
			and type(syncData.Targeted)
				== "boolean"
		then
			return syncData.Targeted
		end
	end

	if GameInfo
		and type(GameInfo.getTargetId)
			== "function"
		and R.player
	then
		local ok, targetId =
			pcall(
				GameInfo.getTargetId
			)

		if ok then
			return tonumber(targetId)
				== tonumber(
					R.player.UserId
				)
		end
	end

	return false
end

local function readFrameState(time)
	local snapshot

	if GameInfo
		and type(GameInfo.getSnapshot)
			== "function"
	then
		local ok, result =
			pcall(
				GameInfo.getSnapshot,
				nil,
				time
			)

		if ok and type(result) == "table" then
			local valid = true

			if type(
				GameInfo.isSnapshotValid
			) == "function" then
				local validOk,
					snapshotValid =
					pcall(
						GameInfo.isSnapshotValid,
						result,
						time
					)

				valid =
					validOk
					and snapshotValid == true
			end

			if valid then
				snapshot = result
			end
		end
	end

	local ball =
		snapshot
		and snapshot.ball
		or nil

	if not isValidBall(ball)
		and GameInfo
		and type(GameInfo.getBall)
			== "function"
	then
		local ok, result =
			pcall(
				GameInfo.getBall
			)

		if ok then
			ball = result
		end
	end

	if not isValidBall(ball) then
		return nil, false, snapshot
	end

	return
		ball,
		readTargeted(snapshot),
		snapshot
end

local function samplePing(time)
	if time - R.pingAt
		< T.PING_SAMPLE_INTERVAL
	then
		return
	end

	R.pingAt = time

	local player = R.player

	if not player then
		return
	end

	local ok, value =
		pcall(function()
			return player:GetNetworkPing()
		end)

	if ok
		and isFiniteNumber(value)
		and value >= 0
	then
		R.ping = value
	end
end

-- =========================================================
-- ANTIGO SISTEMA DE TELEPORT LOCK
-- =========================================================

local function isTeleportLocked(time)
	return R.teleported
		or time < R.teleportLockUntil
end

local function getTeleportLockDuration()
	local ping =
		isFiniteNumber(R.ping)
		and math.max(R.ping, 0)
		or 0

	return T.TELEPORT_LOCK_BASE
		+ (ping * 0.5)
end

local function enterTeleportLock(time)
	R.teleported = true

	R.teleportLockUntil =
		math.max(
			R.teleportLockUntil,
			time + getTeleportLockDuration()
		)

	resetParryLock()
	clearBallState()

	R.lastFireAt = 0

	R.passivePhase = "idle"
	R.passiveBallAtValid = false

	setPhase(
		"waiting",
		"teleport_lock"
	)
end

local function leaveTeleportLock(time)
	local wasTeleported =
		R.teleported

	R.teleported = false

	if wasTeleported then
		-- Igual ao antigo:
		-- o ciclo anterior não pode ser reutilizado.
		resetParryLock()
		clearBallState()

		R.lastFireAt = 0

		R.passivePhase = "idle"
		R.passiveBallAtValid = false

		setPhase(
			"waiting",
			"teleport_finished"
		)
	end

	if time < R.teleportLockUntil then
		resetParryLock()
		clearBallState()

		R.passivePhase = "idle"
		R.passiveBallAtValid = false

		setPhase(
			"waiting",
			"teleport_lock"
		)

		return false
	end

	return true
end

local function getRemoteParry(ball)
	local time = clock()

	-- trava exatamente pelo estado Teleported
	-- e pelo lock mínimo do antigo.
	if isTeleportLocked(time) then
		return false
	end

	if not isFiniteNumber(R.lastSpeed)
		or R.lastSpeed
			< T.MIN_BALL_SPEED
	then
		return false
	end

	if not R.lastApproaching then
		return false
	end

	if not Remote
		or type(Remote.fireParry)
			~= "function"
	then
		return false
	end

	local ok, result =
		pcall(
			Remote.fireParry,
			1
		)

	if not ok or result == false then
		return false
	end

	time = clock()

	Resilience.hitboxConfirmed =
		false

	local firedBall = ball

	if not isValidBall(firedBall)
		and GameInfo
		and type(GameInfo.getBall)
			== "function"
	then
		local ballOk,
			currentBall =
			pcall(
				GameInfo.getBall
			)

		if ballOk then
			firedBall =
				currentBall
		end
	end

	if isValidBall(firedBall)
		and R.alive
		and R.bound
		and Resilience.lifeGeneration
			== R.lifeGeneration
	then
		Resilience.lastFireBall =
			firedBall

		Resilience.lastFireAt =
			time
	else
		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0
	end

	return true
end

local function fireAfterDetection(
	ball,
	generation
)
	if generation ~= R.generation then
		return false
	end

	if not R.alive
		or not R.bound
	then
		return false
	end

	if R.teleported then
		return false
	end

	if isTeleportLocked(clock()) then
		return false
	end

	if R.lastBall ~= ball then
		return false
	end

	if not R.targeted then
		return false
	end

	if not R.lastApproaching then
		R.armed = true
		return false
	end

	if isTeleportLocked(clock()) then
		R.armed = true
		return false
	end

	local fired =
		getRemoteParry(ball)

	if not fired then
		R.armed = true
		return false
	end

	R.armed = false
	R.lastFireAt = clock()

	setPhase(
		"fired",
		"parry_requested"
	)

	return true
end

local function handleHitbox(instance)
	if instance.Name
		~= "HitboxGrow"
	then
		return
	end

	if not instance:IsA("BasePart") then
		return
	end

	if Resilience.hitboxConfirmed then
		return
	end

	if not isResilienceUsable() then
		return
	end

	if Utils
		and type(Utils.isActive)
			== "function"
	then
		local ok, active =
			pcall(Utils.isActive)

		if not ok or active ~= true then
			return
		end
	end

	local time = clock()

	if time - Resilience.lastFireAt
		> T.HITBOX_OWN_WINDOW
	then
		return
	end

	if time - Resilience.lastHitboxAt
		< T.HITBOX_GAP
	then
		return
	end

	local ball =
		Resilience.lastFireBall

	if not isValidBall(ball) then
		return
	end

	local hitboxPosition =
		instance.Position

	local ballPosition =
		ball.Position

	if not isValidVector3(
		hitboxPosition
	)
		or not isValidVector3(
			ballPosition
		)
	then
		return
	end

	if distanceSquared(
		ballPosition,
		hitboxPosition
	) > HITBOX_PROXIMITY_SQ
	then
		return
	end

	if not R.alive
		or not R.bound
		or Resilience.lifeGeneration
			~= R.lifeGeneration
	then
		return
	end

	Resilience.hitboxConfirmed =
		true

	Resilience.lastHitboxAt =
		time

	addResilienceStack()
end

local function uninstallHitboxHook()
	local connection =
		HitboxState.connection

	if not connection then
		return
	end

	if Utils
		and type(Utils.untrackGlobal)
			== "function"
	then
		pcall(
			Utils.untrackGlobal,
			connection
		)
	end

	pcall(function()
		connection:Disconnect()
	end)

	HitboxState.connection = nil
	HitboxState.workspace = nil
end

local function installHitboxHook()
	local workspaceService =
		R.workspace

	if not workspaceService then
		return false
	end

	if HitboxState.connection
		and HitboxState.workspace
			== workspaceService
	then
		return true
	end

	uninstallHitboxHook()

	local ok, connection =
		pcall(function()
			return workspaceService
				.DescendantAdded
				:Connect(function(instance)
					if HitboxState.handler then
						HitboxState.handler(
							instance
						)
					end
				end)
		end)

	if not ok or not connection then
		return false
	end

	HitboxState.connection =
		connection

	HitboxState.workspace =
		workspaceService

	if Utils
		and type(Utils.trackGlobal)
			== "function"
	then
		pcall(
			Utils.trackGlobal,
			connection
		)
	end

	return true
end

local function updateVelocity(
	ball,
	position,
	time,
	dt
)
	if R.lastBall ~= ball then
		R.lastBall = ball
		R.lastPosition = nil
		R.lastPositionAt = nil
		R.velocity = Vector3.zero
	end

	local assemblyVelocity

	local ok = pcall(function()
		assemblyVelocity =
			ball.AssemblyLinearVelocity
	end)

	if ok
		and isValidVector3(
			assemblyVelocity
		)
		and assemblyVelocity.Magnitude
			> 0.1
	then
		R.velocity =
			assemblyVelocity
	else
		local previousPosition =
			R.lastPosition

		local previousTime =
			R.lastPositionAt

		if previousPosition
			and previousTime
		then
			local elapsed =
				time - previousTime

			if elapsed > 0 then
				local rawVelocity =
					(position
						- previousPosition)
					/ elapsed

				local frameDt =
					isFiniteNumber(dt)
					and math.max(
						dt,
						1 / 240
					)
					or 1 / 60

				local alpha =
					frameDt
					/ (
						T.VELOCITY_SMOOTHING_TAU
						+ frameDt
					)

				R.velocity +=
					(rawVelocity
						- R.velocity)
					* alpha
			end
		end
	end

	R.lastPosition = position
	R.lastPositionAt = time
end

local function isBallInParryWindow(time)
	if isTeleportLocked(time) then
		return false, false
	end

	local ball, _, snapshot =
		readFrameState(time)

	if not isValidBall(ball) then
		return false, false
	end

	local root = R.root

	if not root or not root.Parent then
		return false, false
	end

	local position =
		snapshot
		and snapshot.position
		or nil

	if not isValidVector3(position) then
		local ok, value =
			pcall(function()
				return ball.Position
			end)

		if not ok then
			return false, false
		end

		position = value
	end

	local speed =
		snapshot
		and tonumber(snapshot.speed)
		or nil

	if not isFiniteNumber(speed) then
		local ok, velocity =
			pcall(function()
				return ball.AssemblyLinearVelocity
			end)

		if ok
			and isValidVector3(velocity)
		then
			speed = velocity.Magnitude
		end
	end

	if not isFiniteNumber(speed)
		or speed < T.MIN_BALL_SPEED
	then
		return false, false
	end

	local velocity

	local ok, value =
		pcall(function()
			return ball.AssemblyLinearVelocity
		end)

	if ok and isValidVector3(value) then
		velocity = value
	else
		velocity = R.velocity
	end

	local delta =
		root.Position - position

	local approaching =
		isValidVector3(velocity)
		and velocity.Magnitude
			>= T.MIN_BALL_SPEED
		and delta.Magnitude > 0
		and velocity:Dot(delta) > 0

	if not approaching then
		return false, false
	end

	local bonus =
		getResilienceBonus(time)

	local radius =
		computeParryRadius(
			speed,
			R.ping,
			bonus,
			1
		)

	local distance =
		(root.Position - position).Magnitude

	return distance <= radius, true
end

local function onHeartbeat(
	character,
	root,
	dt,
	generation
)
	if generation ~= R.generation
		or not R.alive
		or not R.bound
	then
		return
	end

	if not character.Parent
		or not root.Parent
	then
		return
	end

	local time = clock()

	samplePing(time)

	-- =========================================================
	-- TELEPORTED = TRAVA EXATAMENTE COMO NO ANTIGO
	-- =========================================================

	if R.teleported then
		clearBallState()
		resetParryLock()

		setPhase(
			"waiting",
			"teleport_lock"
		)

		return
	end

	if time < R.teleportLockUntil then
		clearBallState()
		resetParryLock()

		setPhase(
			"waiting",
			"teleport_lock"
		)

		return
	end

	-- =========================================================
	-- CONFIG / SPAM / ACTIVE
	-- =========================================================

	if not isAutoParryEnabled() then
		resetParryLock()

		setPhase(
			"waiting",
			"auto_parry_disabled"
		)

		return
	end

	-- antigo bloqueava completamente o AP enquanto Spam
	if isSpamActive() then
		resetParryLock()

		setPhase(
			"waiting",
			"spam_active"
		)

		return
	end

	if not isSystemActive() then
		resetParryLock()

		setPhase(
			"waiting",
			"system_inactive"
		)

		return
	end

	local ball, targeted, snapshot =
		readFrameState(time)

	if not isValidBall(ball) then
		resetParryLock()
		clearBallState()

		setPhase(
			"waiting",
			"ball_unavailable"
		)

		return
	end

	local position = ball.Position

	if not isValidVector3(position) then
		return
	end

	updateVelocity(
		ball,
		position,
		time,
		dt
	)

	local rootPosition =
		root.Position

	if not isValidVector3(rootPosition) then
		return
	end

	local delta =
		rootPosition - position

	local distance =
		delta.Magnitude

	local speed =
		R.velocity.Magnitude

	local approaching =
		speed >= T.MIN_BALL_SPEED
		and distance > 0
		and R.velocity:Dot(delta) > 0

	if not targeted then
		R.armed = true
	elseif not R.lastTargeted then
		R.armed = true
	end

	R.lastTargeted = targeted
	R.targeted = targeted

	local resilienceBonus =
		getResilienceBonus(time)

	local parryRadius, leadTime =
		computeParryRadius(
			speed,
			R.ping,
			resilienceBonus,
			T.DEFAULT_WINDOW_FACTOR
		)

	R.lastDistance = distance
	R.lastSpeed = speed
	R.lastRadius = parryRadius
	R.lastLeadTime = leadTime
	R.lastApproaching = approaching

	R.targetId =
		tonumber(
			snapshot
			and snapshot.targetId
		)
		or -1

	R.targetKnown =
		snapshot ~= nil
		and snapshot.targetId ~= nil

	if not targeted then
		setPhase(
			"waiting",
			"not_targeted"
		)

		return
	end

	if speed < T.MIN_BALL_SPEED then
		R.armed = true

		setPhase(
			"waiting",
			"ball_speed_invalid"
		)

		return
	end

	if not approaching then
		R.armed = true

		setPhase(
			"waiting",
			"ball_not_approaching"
		)

		return
	end

	if distance > parryRadius then
		setPhase(
			"waiting",
			"outside_radius"
		)

		return
	end

	if R.armed then
		R.armed = false

		local currentGeneration =
			R.generation

		task.defer(
			fireAfterDetection,
			ball,
			currentGeneration
		)
	end
end

local function detachCharacterInternal(reason)
	R.generation += 1

	disconnectConnections()
	invalidateLife()

	R.character = nil
	R.root = nil

	resetTracking()

	setPhase(
		"detached",
		reason or "detach"
	)
end

function AutoParry.setup(deps)
	if type(deps) ~= "table" then
		return false,
			"dependencias invalidas"
	end

	local remote = deps.Remote
	local gameInfo = deps.GameInfo
	local utils = deps.Utils

	if type(remote) ~= "table"
		or type(remote.fireParry)
			~= "function"
	then
		return false,
			"dependencia ausente: Remote.fireParry"
	end

	if type(gameInfo) ~= "table"
		or type(gameInfo.getSnapshot)
			~= "function"
		or type(gameInfo.isSnapshotValid)
			~= "function"
		or type(gameInfo.getBall)
			~= "function"
		or type(gameInfo.getSyncData)
			~= "function"
		or type(gameInfo.getTargetId)
			~= "function"
	then
		return false,
			"dependencia ausente: GameInfo"
	end

	if type(utils) ~= "table"
		or type(utils.getLocalPlayer)
			~= "function"
		or type(utils.getRunService)
			~= "function"
		or type(utils.getConfig)
			~= "function"
		or type(utils.isActive)
			~= "function"
		or type(utils.isSpamActive)
			~= "function"
		or type(utils.trackCharacter)
			~= "function"
		or type(utils.untrackCharacter)
			~= "function"
		or type(utils.getWorkspace)
			~= "function"
		or type(utils.trackGlobal)
			~= "function"
		or type(utils.untrackGlobal)
			~= "function"
	then
		return false,
			"dependencia ausente: Utils"
	end

	uninstallHitboxHook()
	detachCharacterInternal("setup")

	Remote = remote
	GameInfo = gameInfo
	Utils = utils

	local playerOk, player =
		pcall(Utils.getLocalPlayer)

	if not playerOk or not player then
		return false,
			"Players.LocalPlayer indisponivel"
	end

	R.player = player

	local workspaceOk,
		workspaceService =
		pcall(Utils.getWorkspace)

	R.workspace =
		workspaceOk
		and workspaceService
		or nil

	HitboxState.handler =
		handleHitbox

	resetTracking()
	resetResilience()
	installHitboxHook()

	setPhase(
		"detached",
		"setup_complete"
	)

	return true
end

function AutoParry.bindCharacter(character)
	if not Remote
		or not GameInfo
		or not Utils
	then
		return false,
			"dependencias nao inicializadas"
	end

	detachCharacterInternal(
		"rebind_start"
	)

	if not character
		or not character.Parent
	then
		return false,
			"personagem indisponivel"
	end

	local generation =
		R.generation

	local root =
		getRootPart(character)

	if not root then
		local ok, result =
			pcall(
				character.WaitForChild,
				character,
				"HumanoidRootPart",
				10
			)

		if ok
			and typeof(result)
				== "Instance"
			and result:IsA("BasePart")
		then
			root = result
		end
	end

	if generation ~= R.generation
		or not root
		or not root.Parent
	then
		return false,
			"HumanoidRootPart indisponivel"
	end

	local runOk, runService =
		pcall(Utils.getRunService)

	if not runOk or not runService then
		return false,
			"RunService indisponivel"
	end

	local signal =
		runService.PostSimulation
		or runService.Heartbeat

	if not signal then
		return false,
			"RunService indisponivel"
	end

	local playerOk, player =
		pcall(Utils.getLocalPlayer)

	if not playerOk or not player then
		return false,
			"Players.LocalPlayer indisponivel"
	end

	R.character = character
	R.root = root
	R.player = player

	R.alive = true
	R.bound = true

	resetTracking()

	Resilience.lifeGeneration =
		R.lifeGeneration

	installHitboxHook()

	setPhase(
		"waiting",
		"character_bound"
	)

	local heartbeatOk,
		heartbeatConnection =
		pcall(function()
			return signal:Connect(
				function(dt)
					onHeartbeat(
						character,
						root,
						dt,
						generation
					)
				end
			)
		end)

	if not heartbeatOk
		or not heartbeatConnection
	then
		detachCharacterInternal(
			"heartbeat_bind_failed"
		)

		return false,
			"falha ao conectar RunService"
	end

	trackConnection(
		heartbeatConnection
	)

	local ancestryOk,
		ancestryConnection =
		pcall(function()
			return character.AncestryChanged:Connect(
				function(_, parent)
					if not parent
						and generation
							== R.generation
					then
						detachCharacterInternal(
							"character_removed"
						)
					end
				end
			)
		end)

	if not ancestryOk
		or not ancestryConnection
	then
		detachCharacterInternal(
			"ancestry_bind_failed"
		)

		return false,
			"falha ao conectar AncestryChanged"
	end

	trackConnection(
		ancestryConnection
	)

	return true
end

function AutoParry.fire()
	if not R.alive
		or not R.bound
	then
		return false
	end

	if isTeleportLocked(clock()) then
		return false
	end

	if not R.lastApproaching
		or R.lastSpeed
			< T.MIN_BALL_SPEED
	then
		return false
	end

	local fired =
		getRemoteParry(R.lastBall)

	if not fired then
		return false
	end

	R.armed = false
	R.lastFireAt = clock()

	setPhase(
		"fired",
		"manual_parry"
	)

	return true
end

function AutoParry.resetState()
	detachCharacterInternal("reset")
end

function AutoParry.detachCharacter()
	detachCharacterInternal("detach")
end

function AutoParry.teardown()
	uninstallHitboxHook()

	detachCharacterInternal(
		"teardown"
	)

	HitboxState.handler = nil

	Remote = nil
	GameInfo = nil
	Utils = nil

	R.player = nil
	R.workspace = nil
end

function AutoParry.onBallSync(data)
	if type(data) ~= "table"
		or not R.alive
		or not R.bound
	then
		return
	end

	local time = clock()

	-- =========================================================
	-- TELEPORTED = MESMA TRAVA DO ANTIGO
	-- Grace não participa.
	-- =========================================================

	if data.Teleported == true then
		enterTeleportLock(time)
		return true
	end

	-- =========================================================
	-- SAÍDA DO TELEPORT LOCK
	-- =========================================================

	if not leaveTeleportLock(time) then
		return true
	end

	local targetId = -1

	if GameInfo
		and type(GameInfo.getTargetId)
			== "function"
	then
		local ok, value =
			pcall(
				GameInfo.getTargetId
			)

		if ok then
			targetId =
				tonumber(value) or -1
		end
	end

	if targetId == -1 then
		targetId =
			tonumber(
				data.TargetPlayerID
			)
			or -1
	end

	R.targetId = targetId
	R.targetKnown = true

	local previousWasMe =
		R.lastWasMe

	local isMe =
		R.player ~= nil
		and targetId
			== tonumber(
				R.player.UserId
			)

	local spamActive =
		isSpamActive()

	if targetId == R.lastTarget
		and previousWasMe ~= nil
	then
		if spamActive and isMe then
			if R.passivePhase
				~= "awaiting_leave"
			then
				R.passivePhase =
					"awaiting_leave"

				R.passiveBallAtValid =
					false
			end

			local inside, valid =
				isBallInParryWindow(
					time
				)

			if valid and inside then
				R.passiveBallAtValid =
					true
			end
		else
			R.passivePhase = "idle"
			R.passiveBallAtValid =
				false
		end

		return true
	end

	R.lastTarget = targetId
	R.lastWasMe = isMe

	if not spamActive then
		R.passivePhase = "idle"
		R.passiveBallAtValid =
			false

		return true
	end

	if isMe then
		R.passivePhase =
			"awaiting_leave"

		local inside, valid =
			isBallInParryWindow(
				time
			)

		R.passiveBallAtValid =
			valid and inside

		return true
	end

	if R.passivePhase
		== "awaiting_leave"
		and R.passiveBallAtValid
		and isResilienceUsable()
	then
		addResilienceStack()
	end

	R.passivePhase = "idle"
	R.passiveBallAtValid =
		false

	return true
end

function AutoParry.getTargetStatus()
	return {
		armed =
			R.armed == true,

		lastTargeted =
			R.lastTargeted == true,

		targeted =
			R.targeted == true,

		approaching =
			R.lastApproaching == true,

		targetId =
			R.targetId,

		targetKnown =
			R.targetKnown == true,
	}
end

local function getRootPosition()
	local root = R.root

	if root and root.Parent then
		return root.Position
	end

	local player = R.player

	local character =
		player
		and player.Character

	if not character then
		return nil
	end

	local candidate =
		getRootPart(character)

	if candidate
		and candidate.Parent
	then
		return candidate.Position
	end

	return nil
end

function AutoParry.getTiming(
	snapshot,
	time,
	rootPosition,
	windowFactor
)
	if type(snapshot) ~= "table" then
		return nil
	end

	time =
		tonumber(time)
		or clock()

	local position =
		snapshot.position

	local ball =
		snapshot.ball

	if not isValidVector3(position)
		and isValidBall(ball)
	then
		local ok, value =
			pcall(function()
				return ball.Position
			end)

		if ok then
			position = value
		end
	end

	if not isValidVector3(rootPosition) then
		rootPosition =
			getRootPosition()
	end

	if not isValidVector3(position)
		or not isValidVector3(rootPosition)
	then
		return nil
	end

	local velocity
	local speed

	if isValidBall(ball)
		and R.lastBall == ball
	then
		velocity = R.velocity
		speed = R.lastSpeed
	end

	if not isValidVector3(velocity) then
		velocity =
			snapshot.velocity
	end

	if not isValidVector3(velocity)
		and isValidBall(ball)
	then
		local ok, value =
			pcall(function()
				return ball.AssemblyLinearVelocity
			end)

		if ok
			and isValidVector3(value)
		then
			velocity = value
		end
	end

	if isValidVector3(velocity) then
		speed = velocity.Magnitude
	else
		speed =
			tonumber(
				snapshot.speed
			) or 0
	end

	if not isFiniteNumber(speed)
		or speed < 0
	then
		return nil
	end

	local delta =
		rootPosition - position

	local distance =
		delta.Magnitude

	local resilienceBonus =
		getResilienceBonus(time)

	local parryRadius,
		leadTime,
		noWindowRadius,
		pingRadius,
		deflectWindow,
		effectiveWindow,
		requestedFactor =
		computeParryRadius(
			speed,
			R.ping,
			resilienceBonus,
			windowFactor
		)

	local distanceToRadius =
		distance - parryRadius

	local tti =
		speed > 0
		and math.max(
			distanceToRadius,
			0
		) / speed
		or math.huge

	local approaching =
		isValidVector3(velocity)
		and speed >= T.MIN_BALL_SPEED
		and distance > 0
		and velocity:Dot(delta) > 0
		or false

	return {
		distance = distance,
		speed = speed,

		parryRadius =
			parryRadius,

		fullRadius =
			parryRadius,

		pureRadius =
			T.BASE_RADIUS,

		noWindowParryRadius =
			noWindowRadius,

		pingRadius =
			pingRadius,

		resilienceBonus =
			resilienceBonus,

		leadTime =
			leadTime,

		deflectWindow =
			deflectWindow,

		effectiveWindow =
			effectiveWindow,

		windowFactor =
			requestedFactor,

		distanceToParryRadius =
			distanceToRadius,

		tti = tti,

		approaching =
			approaching,

		targeted =
			snapshot.targeted == true,
	}
end

function AutoParry.getRadius(
	mode,
	windowFactor,
	speedOverride
)
	mode = mode or "geometry"

	if mode ~= "geometry"
		and mode ~= "tti"
		and mode ~= "speed_distance"
	then
		mode = "geometry"
	end

	local speed =
		tonumber(speedOverride)

	if not isFiniteNumber(speed)
		or speed < 0
	then
		speed = R.lastSpeed
	end

	if not isFiniteNumber(speed)
		or speed < 0
	then
		speed = 0
	end

	local time = clock()

	local resilienceBonus =
		getResilienceBonus(time)

	local fullRadius,
		leadTime,
		noWindowRadius,
		pingRadius,
		deflectWindow,
		effectiveWindow,
		requestedFactor =
		computeParryRadius(
			speed,
			R.ping,
			resilienceBonus,
			windowFactor
		)

	local value = fullRadius

	if mode == "tti" then
		value =
			speed > 0
			and math.max(
				R.lastDistance
					- fullRadius,
				0
			) / speed
			or math.huge

	elseif mode == "speed_distance" then
		value = {
			speed = speed,
			distance = R.lastDistance,
		}
	end

	local distanceToRadius =
		R.lastDistance
			- fullRadius

	local tti =
		speed > 0
		and math.max(
			distanceToRadius,
			0
		) / speed
		or math.huge

	return {
		mode = mode,

		value = value,

		pureRadius =
			T.BASE_RADIUS,

		noWindowParryRadius =
			noWindowRadius,

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

		leadTime =
			leadTime,

		distance =
			R.lastDistance,

		speed =
			speed,

		tti =
			tti,
	}
end

function AutoParry.getStatus()
	local time = clock()

	local target =
		AutoParry.getTargetStatus()

	local radius =
		AutoParry.getRadius(
			"geometry",
			T.DEFAULT_WINDOW_FACTOR
		)

	local resilience =
		getResilienceStatus()

	local apiVersion

	if Utils
		and type(Utils.apiVersion)
			== "function"
	then
		local ok, value =
			pcall(Utils.apiVersion)

		if ok then
			apiVersion = value
		end
	end

	return {
		schema = apiVersion,

		api = {
			name = "AutoParry",
			version = 10,

			endpoints = {
				"getRadius",
				"getTiming",
				"getStatus",
				"getTargetStatus",
			},

			radiusModes = {
				"geometry",
				"tti",
				"speed_distance",
			},

			defaultWindowFactor =
				T.DEFAULT_WINDOW_FACTOR,

			windowFactorRange = {
				min =
					T.MIN_WINDOW_FACTOR,

				max =
					T.MAX_WINDOW_FACTOR,
			},
		},

		lifecycle = {
			phase =
				R.phase,

			bound =
				R.bound == true,

			alive =
				R.alive == true,

			generation =
				R.generation,

			lifeGeneration =
				R.lifeGeneration,
		},

		radius =
			radius,

		resilience =
			resilience,

		timing = {
			tti =
				radius.tti,

			ti =
				radius.tti,

			speed =
				R.lastSpeed,

			distance =
				R.lastDistance,

			distanceToRadius =
				R.lastDistance
				- radius.fullRadius,

			deflectWindow =
				T.BASE_WINDOW,

			effectiveWindow =
				T.BASE_WINDOW
				* T.DEFAULT_WINDOW_FACTOR,

			leadTime =
				R.lastLeadTime,

			noWindowParryRadius =
				radius.noWindowParryRadius,

			pingRadius =
				radius.pingRadius,

			approaching =
				R.lastApproaching == true,
		},

		ping = {
			oneWay =
				R.ping * 0.5,

			raw =
				R.ping,

			minimum = nil,
		},

		target =
			target,

		cycle = {
			fired =
				R.armed == false,

			armed =
				R.armed == true,

			lastFireAt =
				R.lastFireAt,

			lastTTI =
				radius.tti,
		},

		config = {
			baseRadius =
				T.BASE_RADIUS,

			baseWindow =
				T.BASE_WINDOW,

			defaultWindowFactor =
				T.DEFAULT_WINDOW_FACTOR,

			windowFactorRange = {
				min =
					T.MIN_WINDOW_FACTOR,

				max =
					T.MAX_WINDOW_FACTOR,
			},

			minBallSpeed =
				T.MIN_BALL_SPEED,
		},

		timestamp =
			time,
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
	version = 10,
}

return AutoParry