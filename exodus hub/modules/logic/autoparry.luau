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
	DEFLECT_RETRY_DELAY = 1.45,
}

local PING_SAMPLE_INTERVAL = 0.35
local PING_EMA_ALPHA = 0.08
local DEFAULT_PING_ONE_WAY = 0.030

local TELEPORT_LOCK_BASE = 0.400

local WINDOW_CURVE_B =
(Tuning.WINDOW_LOW - Tuning.WINDOW_REFERENCE)
/ ((1 / Tuning.WINDOW_LOW_SPEED) - (1 / Tuning.WINDOW_REFERENCE_SPEED))

local WINDOW_CURVE_A =
Tuning.WINDOW_REFERENCE
- WINDOW_CURVE_B / Tuning.WINDOW_REFERENCE_SPEED

local MAX_RES_STACK =
math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY)

local HITBOX_PROXIMITY_SQ =
	Tuning.HITBOX_PROXIMITY * Tuning.HITBOX_PROXIMITY

local PHASE_DETACHED = 1
local PHASE_WAITING = 2
local PHASE_COOLDOWN = 3
local PHASE_ARMED = 4
local PHASE_FIRED = 5
local PHASE_PASSIVE = 6

local PHASE_STRINGS = {
	[PHASE_DETACHED] = "detached",
	[PHASE_WAITING] = "waiting",
	[PHASE_COOLDOWN] = "cooldown",
	[PHASE_ARMED] = "armed",
	[PHASE_FIRED] = "fired",
	[PHASE_PASSIVE] = "passive",
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

local ParryState = {
	armed = false,
	armedBall = nil,

	fired = false,
	firedBall = nil,
	firedAt = 0,
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

	-- cache do target real
	targetId = -1,
	targetKnown = false,

	teleportLockUntil = 0,

	connections = {},

	pingTimer = 0,
	pingOneWay = DEFAULT_PING_ONE_WAY,
	minPing = nil,

	resilienceBonus = 0,
	resilienceBonusAt = -1,

	parryRadius = 0,
	baseParryRadius = Tuning.DEFLECT_RADIUS,

	deflectWindow = 0,
	effectiveWindow = 0,

	lastTTI = math.huge,
	lastDistance = 0,
	lastDistanceToParryRadius = 0,
	lastSpeed = 0,

	lastFireAt = 0,
	cooldownObservedAt = 0,

	phase = PHASE_DETACHED,

	passivePhase = "idle",
	passiveCycleStart = 0,
	passiveBallAtValid = false,
}

-- =========================================================
-- HELPERS
-- =========================================================

local function now()
	return Utils and Utils.now and Utils.now() or os.clock()
end

local function setPhase(phase, reason)
	if Runtime.phase == phase then
		return
	end

	local old = Runtime.phase

	Runtime.phase = phase
	phaseString = PHASE_STRINGS[phase] or "detached"

	if Utils and Utils.recordTransition then
		Utils.recordTransition(
			"AutoParry",
			PHASE_STRINGS[old] or "detached",
			phaseString,
			reason
		)
	end
end

local function isValidBall(ball)
	return ball ~= nil and ball.Parent ~= nil
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
	for i = #Runtime.connections, 1, -1 do
		local connection = Runtime.connections[i]
		Runtime.connections[i] = nil

		if connection then
			if Utils and Utils.untrackCharacter then
				pcall(Utils.untrackCharacter, connection)
			end

			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end

local function distanceSquared(a, b)
	local x = a.X - b.X
	local y = a.Y - b.Y
	local z = a.Z - b.Z

	return x * x + y * y + z * z
end

-- =========================================================
-- RESILIENCE
-- =========================================================

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

	clearCycle()
	resetResilience()
end

local function isResilienceUsable()
	if not Runtime.alive
		or not Runtime.bound
		or Resilience.lifeGeneration ~= Runtime.lifeGeneration
	then
		Resilience.stack = 0
		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0
		Resilience.lastHitboxAt = 0

		Runtime.resilienceBonus = 0
		Runtime.resilienceBonusAt = Runtime.lifeGeneration

		return false
	end

	local stack = Resilience.stack

	if type(stack) ~= "number"
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

	Runtime.resilienceBonus =
		math.min(
			Resilience.stack * Tuning.RES_PER_PARRY,
			Tuning.RES_CAP_STUDS
		)

	Runtime.resilienceBonusAt = time

	return Runtime.resilienceBonus
end

-- =========================================================
-- PING
-- =========================================================

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

	if not valid or type(ping) ~= "number" then
		return
	end

	ping *= 0.001

	if ping <= 0
		or ping >= 0.5
		or not Utils.isFiniteNumber(ping)
	then
		return
	end

	if not Runtime.minPing or ping < Runtime.minPing then
		Runtime.minPing = ping
	end

	local oneWay = ping * 0.5

	Runtime.pingOneWay +=
		(oneWay - Runtime.pingOneWay)
		* PING_EMA_ALPHA
end

-- =========================================================
-- TIMING
-- =========================================================

local function computeBaseDeflectWindow(speed)
local raw = tonumber(speed) or 0
local s = math.max(raw, Tuning.WINDOW_LOW_SPEED)

local window =
WINDOW_CURVE_A
+ WINDOW_CURVE_B / s

if raw < 40 then
window *= 0.7
end

return math.max(window, 0)
end

local function computeDeflectWindow(speed)
local window = computeBaseDeflectWindow(speed)
local ping = Runtime.pingOneWay

if ping > 0 then
window += math.min(
ping * 2 * Tuning.PING_WINDOW_FACTOR,
Tuning.PING_WINDOW_CAP
)
end

return window
end

local function computeEffectiveWindow(speed)
return computeDeflectWindow(speed) * Tuning.WINDOW_FACTOR
end

local function computeTiming(rootPosition, position, speed, time)
	if typeof(rootPosition) ~= "Vector3"
		or typeof(position) ~= "Vector3"
		or type(speed) ~= "number"
		or speed <= 0
	then
		return nil
	end

	local resilience =
		getResilienceBonus(time)

	local deflectWindow =
		computeDeflectWindow(speed)

	local effectiveWindow =
		computeEffectiveWindow(speed)

	local parryRadius =
		Tuning.DEFLECT_RADIUS
		+ resilience
		+ speed * effectiveWindow

	local distSq =
		distanceSquared(
			rootPosition,
			position
		)

	local distance =
		math.sqrt(distSq)

	local delta =
		distance - parryRadius

	local tti =
		delta <= 0
		and 0
		or delta / speed

	return {
		parryRadius = parryRadius,
		pureRadius = Tuning.DEFLECT_RADIUS,

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

-- =========================================================
-- TARGET
-- =========================================================

local function refreshTargetCache()
	local syncData =
		BallReplicator
		and BallReplicator.syncData

	local target =
		tonumber(
			syncData
			and syncData.TargetPlayerID
		)

	if target ~= nil then
		Runtime.targetId = target
		Runtime.targetKnown = true
		return target
	end

	Runtime.targetKnown = false
	return nil
end

local function isLocallyTargeted()
	if Runtime.localUserId <= 0 then
		return false
	end

	local target = Runtime.targetId

	if Runtime.targetKnown then
		return target == Runtime.localUserId
	end

	-- Fallback somente quando o TargetPlayerID ainda não existe.
	-- Mantido leve para não executar toda a árvore visual por frame.
	local syncData =
		BallReplicator
		and BallReplicator.syncData

	local highlight =
		tonumber(
			syncData
			and syncData.HighlightTargetPlayerID
		)

	if highlight ~= nil then
		return highlight == Runtime.localUserId
	end

	local workspaceService = Runtime.workspace

	if workspaceService then
		local targetAttribute =
			tonumber(
				workspaceService:GetAttribute(
					"GameBallTarget"
				)
			)

		if targetAttribute ~= nil then
			return targetAttribute ==
				Runtime.localUserId
		end
	end

	return false
end

-- =========================================================
-- PARry WINDOW
-- =========================================================

local function getSnapshot(time)
	local snapshot =
		GameInfo.getSnapshot(
			Runtime.lastTarget,
			time
		)

	if type(snapshot) ~= "table"
		or not GameInfo.isSnapshotValid(
			snapshot,
			time
		)
	then
		return nil
	end

	return snapshot
end

local function isBallInParryWindow(time)
	local snapshot = getSnapshot(time)

	if not snapshot then
		return false, false
	end

	local ball = snapshot.ball

	if not isValidBall(ball) then
		return false, false
	end

	local speed = tonumber(snapshot.speed)

	if not speed
		or speed < Tuning.MIN_BALL_SPEED
		or not Utils.isFiniteNumber(speed)
	then
		return false, false
	end

	local position = snapshot.position

	if typeof(position) ~= "Vector3"
		or not Runtime.root
		or not Runtime.root.Parent
	then
		return false, false
	end

	local timing =
		computeTiming(
			Runtime.root.Position,
			position,
			speed,
			time
		)

	if not timing then
		return false, false
	end

	return (
		timing.distance
		<= timing.parryRadius
	), true
end

-- =========================================================
-- BALL SYNC
-- =========================================================

local function onBallSync(data)
	if typeof(data) ~= "table"
		or not Runtime.alive
		or not Runtime.bound
	then
		return
	end

	local time = now()

	if data.Teleported == true then
		Runtime.teleportLockUntil =
			math.max(
				Runtime.teleportLockUntil,
				time
					+ TELEPORT_LOCK_BASE
					+ Runtime.pingOneWay
			)

		clearCycle()

		Runtime.passivePhase = "idle"
		Runtime.passiveBallAtValid = false

		setPhase(
			PHASE_WAITING,
			"teleport_lock"
		)

		return
	end

	-- Atualiza imediatamente o target.
	local targetId =
		tonumber(data.TargetPlayerID) or -1

	Runtime.targetId = targetId
	Runtime.targetKnown = true

	local previousTarget = Runtime.lastTarget
	local previousWasMe = Runtime.lastWasMe

	if targetId == previousTarget
		and previousWasMe ~= nil
	then
		-- Não executa cálculo pesado se não houve mudança.
		if Utils.isSpamActive()
			and Runtime.passivePhase == "awaiting_leave"
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

	if Utils.isSpamActive() then
		if not isMe then
			if Runtime.passivePhase == "awaiting_leave" then
				if Runtime.passiveBallAtValid
					and isResilienceUsable()
				then
					Resilience.stack =
						math.min(
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

				Runtime.passiveCycleStart = time

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

	if isMe
		and previousTarget ~= Runtime.localUserId
	then
		clearFired()
	end
end

-- =========================================================
-- PARRY
-- =========================================================

local function requestParry(ball)
	if not Runtime.alive
		or not Runtime.bound
	then
		return false
	end

	if not Remote
		or type(Remote.fireParry) ~= "function"
	then
		if Utils.recordError then
			Utils.recordError(
				"AutoParry",
				"Remote.fireParry indisponivel"
			)
		end

		setPhase(
			PHASE_WAITING,
			"remote_unavailable"
		)

		return false
	end

	local time = now()

	-- Bloqueio de double-fire.
	if ParryState.fired then
		if ball == nil
			or ParryState.firedBall == ball
		then
			return false
		end

		clearFired()
	end

	-- Marca ANTES do Remote.
	ParryState.fired = true
	ParryState.firedBall = ball
	ParryState.firedAt = time

	local ok, result =
		pcall(
			Remote.fireParry,
			1
		)

	if not ok or result == false then
		clearFired()

		if Utils.recordError then
			Utils.recordError(
				"AutoParry",
				"Remote.fireParry falhou"
			)
		end

		setPhase(
			PHASE_WAITING,
			"remote_failed"
		)

		return false
	end

	Runtime.lastFireAt = time
	Runtime.cooldownObservedAt = 0

	-- Depois da confirmação inicial por HitboxGrow, cada parry
	-- enviado com sucesso concede exatamente um stack.
	if Resilience.hitboxConfirmed
		and isResilienceUsable()
	then
		Resilience.stack =
			math.min(
				Resilience.stack + 1,
				MAX_RES_STACK
			)

		Runtime.resilienceBonusAt = -1
	end
	local firedBall = ball

	if not isValidBall(firedBall) then
		local okBall, currentBall =
			pcall(GameInfo.getBall)

		if okBall then
			firedBall = currentBall
		end
	end

	if isValidBall(firedBall)
		and Runtime.alive
		and Runtime.bound
		and Resilience.lifeGeneration ==
			Runtime.lifeGeneration
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

-- =========================================================
-- HITBOX
-- =========================================================

local function handleHitbox(instance)
	if typeof(instance) ~= "Instance"
		or instance.Name ~= "HitboxGrow"
		or not Utils.isActive()
		or Resilience.hitboxConfirmed
	then
		return
	end

	if not isResilienceUsable() then
		return
	end

	local time = now()

	if time - Resilience.lastFireAt
			> Tuning.HITBOX_OWN_WINDOW
		or time - Resilience.lastHitboxAt
			< Tuning.HITBOX_GAP
	then
		return
	end

	local ball = Resilience.lastFireBall

	if not isValidBall(ball) then
		return
	end

	local position = instance.Position
	local ballPosition = ball.Position

	if typeof(position) ~= "Vector3"
		or typeof(ballPosition) ~= "Vector3"
	then
		return
	end

	if distanceSquared(
		ballPosition,
		position
	) > HITBOX_PROXIMITY_SQ
	then
		return
	end

	if not Runtime.alive
		or not Runtime.bound
		or Resilience.lifeGeneration
			~= Runtime.lifeGeneration
	then
		return
	end

	-- O primeiro HitboxGrow válido confirma a resiliência nesta vida.
	-- O stack inicial é contado aqui; os próximos vêm de cada fired.
	Resilience.hitboxConfirmed = true
	Resilience.lastHitboxAt = time

	Resilience.stack =
		math.min(
			Resilience.stack + 1,
			MAX_RES_STACK
		)

	Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
	if HitboxState.connection then
		return true
	end

	local workspaceService = Runtime.workspace

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

	HitboxState.connection = connection

	Utils.trackGlobal(connection)

	return true
end

-- =========================================================
-- CHARACTER
-- =========================================================

local function bindCharacter(character)
	if not Remote
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

	if not character or not character.Parent then
		return false
	end

	local root =
		character:FindFirstChild(
			"HumanoidRootPart"
		)

	if not root then
		root =
			character:WaitForChild(
				"HumanoidRootPart",
				1
			)
	end

	if generation ~= Runtime.generation
		or not root
		or not root.Parent
	then
		return false
	end

	local humanoid =
		character:FindFirstChildOfClass(
			"Humanoid"
		)

	if humanoid
		and humanoid.Health <= 0
	then
		return false
	end

	-- Cacheia tudo que era procurado por frame.
	Runtime.character = character
	Runtime.root = root

	local player = Runtime.player

	if humanoid then
		local diedConnection =
			humanoid.Died:Connect(function()
				if generation ~= Runtime.generation then
					return
				end

				Runtime.generation += 1
				invalidateLife()

				setPhase(
					PHASE_DETACHED,
					"character_died"
				)
			end)

		Runtime.connections[
			#Runtime.connections + 1
		] = diedConnection

		Utils.trackCharacter(diedConnection)
	end

	local runService =
		Utils.getRunService()

	local heartbeat =
		runService.Heartbeat

	-- Cacheia funções locais.
	local getConfig = Utils.getConfig
	local isSpamActive = Utils.isSpamActive
	local getSnapshot = GameInfo.getSnapshot
	local isSnapshotValid =
		GameInfo.isSnapshotValid
	local getDeflectCD =
		GameInfo.getDeflectCD
	local finite = Utils.isFiniteNumber

	local heartbeatConnection =
		heartbeat:Connect(function(dt)
			if generation ~= Runtime.generation
				or not Runtime.alive
				or not Runtime.bound
			then
				return
			end

			if not character.Parent
				or not root.Parent
			then
				return
			end

			local config = getConfig()

			if type(config) ~= "table"
				or config.AutoParry ~= true
			then
				clearCycle()
				setPhase(
					PHASE_WAITING,
					"disabled_or_locked"
				)
				return
			end

			local timeNow = now()

			if timeNow < Runtime.teleportLockUntil then
				clearCycle()
				setPhase(
					PHASE_WAITING,
					"teleport_lock"
				)
				return
			end

			if isSpamActive() then
				clearCycle()
				setPhase(
					PHASE_WAITING,
					"spam_active"
				)
				return
			end

			-- Ping é barato e só atualiza a cada 350ms.
			Runtime.pingTimer += math.max(dt, 0)

			if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then
				Runtime.pingTimer = 0
				samplePing()
			end

			-- Target autoritativo primeiro.
			refreshTargetCache()

			if not isLocallyTargeted() then
				setPhase(
					PHASE_WAITING,
					"ball_or_target_invalid"
				)
				return
			end

			local snapshot =
				getSnapshot(
					Runtime.lastTarget,
					timeNow
				)

			if type(snapshot) ~= "table"
				or not isSnapshotValid(
					snapshot,
					timeNow
				)
			then
				setPhase(
					PHASE_WAITING,
					"snapshot_invalid"
				)
				return
			end

			local ball = snapshot.ball

			if not isValidBall(ball) then
				setPhase(
					PHASE_WAITING,
					"ball_invalid"
				)
				return
			end

			local speed =
				tonumber(snapshot.speed)

			if not speed
				or speed < Tuning.MIN_BALL_SPEED
				or not finite(speed)
			then
				setPhase(
					PHASE_WAITING,
					"ball_too_slow"
				)
				return
			end

			local position =
				snapshot.position

			if typeof(position) ~= "Vector3" then
				setPhase(
					PHASE_WAITING,
					"position_unavailable"
				)
				return
			end

			-- Uma única leitura do root por frame.
			local rootPosition = root.Position

			local deflectCooldown =
				tonumber(getDeflectCD()) or 0

			if not finite(deflectCooldown) then
				deflectCooldown = 0
			end

			local timing =
				computeTiming(
					rootPosition,
					position,
					speed,
					timeNow
				)

			if not timing then
				setPhase(
					PHASE_WAITING,
					"timing_unavailable"
				)
				return
			end

			Runtime.parryRadius =
				timing.parryRadius

			Runtime.baseParryRadius =
				timing.pureRadius

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

			-- Comparação normal.
			if timing.distance > timing.parryRadius then
				setPhase(
					PHASE_WAITING,
					"outside_effective_radius"
				)
				return
			end

			-- Cooldown observado.
			if deflectCooldown > 0 then
				if not ParryState.armed then
					ParryState.armed = true
					ParryState.armedBall = ball
				end

				if Runtime.cooldownObservedAt <= 0 then
					Runtime.cooldownObservedAt =
						timeNow

					setPhase(
						PHASE_COOLDOWN,
						"cooldown_observed"
					)

				elseif timeNow
					- Runtime.cooldownObservedAt
					>= Tuning.CLIENT_CD_PROPAGATION
				then
					setPhase(
						PHASE_COOLDOWN,
						"cooldown_propagation"
					)
				else
					setPhase(
						PHASE_ARMED,
						"awaiting_deflect_cooldown"
					)
				end

				return
				end

				Runtime.cooldownObservedAt = 0

				-- A local send is not proof of a server parry. If the same
				-- ball is still eligible after the game's 1.45s cooldown,
				-- release the stale fired lock so the normal trigger can retry.
				if ParryState.fired
					and ParryState.firedBall == ball
					and timeNow - ParryState.firedAt
						>= Tuning.DEFLECT_RETRY_DELAY
				then
					clearFired()
				end

				-- Se estava armado durante cooldown,
				-- dispara imediatamente no primeiro frame livre.
				if ParryState.armed then
				if not isValidBall(ball)
					or ball ~= ParryState.armedBall
					or not isLocallyTargeted()
				then
					clearArmed()

					setPhase(
						PHASE_WAITING,
						"armed_context_invalid"
					)

					return
				end

				requestParry(ball)
				clearArmed()
				return
			end

			-- Double-fire protection.
			if ParryState.fired then
				if ParryState.firedBall == ball then
					return
				end

				if not isValidBall(
					ParryState.firedBall
				) then
					clearFired()
				elseif ParryState.firedBall ~= ball then
					clearFired()
				end
			end

			-- Instantâneo.
			requestParry(ball)
		end)

	Runtime.connections[
		#Runtime.connections + 1
	] = heartbeatConnection

	Utils.trackCharacter(heartbeatConnection)

	local ancestryConnection =
		character.AncestryChanged:Connect(
			function(_, parent)
				if not parent
					and generation ==
						Runtime.generation
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

	Utils.trackCharacter(ancestryConnection)

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

-- =========================================================
-- RESET
-- =========================================================

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
		DEFAULT_PING_ONE_WAY

	Runtime.parryRadius = 0
	Runtime.baseParryRadius =
		Tuning.DEFLECT_RADIUS

	Runtime.resilienceBonus = 0
	Runtime.resilienceBonusAt = -1

	Runtime.deflectWindow = 0
	Runtime.effectiveWindow = 0

	Runtime.lastTTI = math.huge
	Runtime.lastDistance = 0
	Runtime.lastDistanceToParryRadius = 0
	Runtime.lastSpeed = 0

	Runtime.lastFireAt = 0
	Runtime.cooldownObservedAt = 0

	Runtime.passivePhase = "idle"
	Runtime.passiveCycleStart = 0
	Runtime.passiveBallAtValid = false

	setPhase(
		PHASE_DETACHED,
		"reset"
	)
end

-- =========================================================
-- SETUP
-- =========================================================

function AutoParry.setup(deps)
	if type(deps) ~= "table" then
		return false, "dependencias invalidas"
	end

	local remote = deps.Remote
	local gameInfo = deps.GameInfo
	local utils = deps.Utils

	if type(remote) ~= "table"
		or type(remote.fireParry) ~= "function"
	then
		return false,
			"dependencia ausente: Remote.fireParry"
	end

	if type(gameInfo) ~= "table"
		or type(gameInfo.getDeflectCD) ~= "function"
		or type(gameInfo.getBall) ~= "function"
		or type(gameInfo.getSnapshot) ~= "function"
		or type(gameInfo.isSnapshotValid) ~= "function"
	then
		return false,
			"dependencia ausente: GameInfo"
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
		or type(utils.isSpamActive) ~= "function"
	then
		return false,
			"dependencia ausente: Utils"
	end

	Remote = remote
	GameInfo = gameInfo
	Utils = utils

	StatsService =
		game:GetService("Stats")

	Runtime.player =
		Utils.getLocalPlayer()

	Runtime.localUserId =
		Runtime.player
		and tonumber(Runtime.player.UserId)
		or -1

	Runtime.workspace =
		Utils.getWorkspace()

	BallReplicator = nil

	pcall(function()
		local ReplicatedStorage =
			game:GetService("ReplicatedStorage")

		local module =
			require(
				ReplicatedStorage
					:WaitForChild("TS")
					:WaitForChild("BallReplicator")
					:WaitForChild("BallReplicator")
			)

		if module
			and module.BallReplicator
		then
			BallReplicator =
				module.BallReplicator
		end
	end)

	HitboxState.handler =
		handleHitbox

	resetState()

	if not installHitboxHook()
		and Utils.warn
	then
		Utils.warn(
			"hook de hitbox indisponivel"
		)
	end

	return true
end

-- =========================================================
-- PUBLIC
-- =========================================================

function AutoParry.fire()
	if not Remote
		or not GameInfo
		or not Utils
		or not Runtime.alive
		or not Runtime.bound
	then
		return false
	end

	local ball =
		GameInfo.getBall()

	return requestParry(ball)
end

function AutoParry.bindCharacter(character)
	if not Remote
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

function AutoParry.onBallSync(data)
	if Utils then
		onBallSync(data)
	end
end

-- =========================================================
-- API
-- =========================================================

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

	if mode ~= "geometry"
		and mode ~= "tti"
		and mode ~= "speed_distance"
	then
		mode = "geometry"
	end

	local speed =
		tonumber(speedOverride)

	if not speed
		or not Utils.isFiniteNumber(speed)
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

	windowFactor =
		tonumber(windowFactor)

	if not windowFactor
		or not Utils.isFiniteNumber(windowFactor)
	then
		windowFactor =
			Tuning.WINDOW_FACTOR
	end

	windowFactor =
		math.clamp(
			windowFactor,
			0,
			1.5
		)

	local deflectWindow =
		computeDeflectWindow(speed)

	local effectiveWindow =
		deflectWindow * windowFactor

	local resilience =
		getResilienceBonus(now())

	local fullRadius =
		Tuning.DEFLECT_RADIUS
		+ resilience
		+ speed * effectiveWindow

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

		pureRadius =
			Tuning.DEFLECT_RADIUS,

		resilience =
			getResilienceStatus(),

		fullRadius =
			fullRadius,

		deflectWindow =
			deflectWindow,

		windowFactor =
			windowFactor,

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
	rootPosition
)
	if not Utils
		or type(snapshot) ~= "table"
	then
		return nil
	end

	time =
		tonumber(time)
		or now()

	if typeof(rootPosition) ~= "Vector3" then
		local root = Runtime.root

		if root and root.Parent then
			rootPosition = root.Position
		else
			local player = Runtime.player

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

	if not speed
		or not Utils.isFiniteNumber(speed)
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
		time
	)
end

function AutoParry.getStatus()
	return {
		schema =
			Utils
			and Utils.apiVersion
			and Utils.apiVersion()
			or nil,

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
			tti = Runtime.lastTTI,
			speed = Runtime.lastSpeed,
			distance = Runtime.lastDistance,

			distanceToRadius =
				Runtime.lastDistanceToParryRadius,

			deflectWindow =
				Runtime.deflectWindow,

			effectiveWindow =
				Runtime.effectiveWindow,
		},

		ping = {
			oneWay =
				Runtime.pingOneWay,

			minimum =
				Runtime.minPing,
		},

		cycle = {
			armed =
				ParryState.armed == true,

			fired =
				ParryState.fired == true,

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
