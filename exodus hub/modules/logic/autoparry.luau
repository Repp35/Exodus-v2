-- [[ Auto Parry ]]

local AutoParry = {}
local Remote
local GameInfo
local Utils

-- tuning
local Tuning = {
	FIRE_LOCK_TIME = 0.080,
	FIRE_TIMEOUT = 2.0,
	MIN_BALL_SPEED = 7,
	DEFLECT_RADIUS = 8.5,
	ADDITIONAL_WINDOW = 0.110,

	RES_PER_PARRY = 0.225,

	-- hitbox detection
	HITBOX_PROXIMITY = 12,
}

local PING_SAMPLE_INTERVAL = 1.5

-- shared hitbox hook
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}

local HitboxState = type(namespace.AutoParryHitbox) == "table"
	and namespace.AutoParryHitbox
	or {
		connection = nil,
		handler = nil,
	}

namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- state
local ParryState = {
	armed = false,
	armedBall = nil,
	armedAt = 0,

	fired = false,
	firedAt = 0,
}

local Resilience = {
	stack = 0,

	-- fica true depois que um HitboxGrow válido
	-- for detectado durante a vida atual
	detected = false,

	lastFireBall = nil,
	lastFireAt = 0,
}

local Runtime = {
	generation = 0,
	localUserId = -1,
	lastTarget = -1,

	teleportLockUntil = 0,

	connections = {},

	minPing = nil,
	pingTimer = 0,
	pingOneWay = 0.030,

	resilienceBonus = 0,
	resilienceBonusAt = -1,

	parryRadius = 0,
	additionalWindow = Tuning.ADDITIONAL_WINDOW,

	stationary = false,
	phase = "detached",
	bound = false,
}

local Stats = game:GetService("Stats")

-- helpers
local function now()
	return Utils.now()
end

local function setPhase(phase, reason)
	if Runtime.phase == phase then
		return
	end

	local previous = Runtime.phase
	Runtime.phase = phase

	if Utils and type(Utils.recordTransition) == "function" then
		Utils.recordTransition(
			"AutoParry",
			previous,
			phase,
			reason
		)
	end
end

local function clearArmedState()
	ParryState.armed = false
	ParryState.armedBall = nil
	ParryState.armedAt = 0
end

local function disconnectConnections()
	for index = #Runtime.connections, 1, -1 do
		local connection = Runtime.connections[index]
		Runtime.connections[index] = nil

		Utils.untrackCharacter(connection)
		pcall(connection.Disconnect, connection)
	end
end

local function clearRuntimeCycle()
	clearArmedState()

	ParryState.fired = false
	ParryState.firedAt = 0

	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0

	Runtime.parryRadius = 0
end

local function samplePing()
	local ok, ping = pcall(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
	end)

	if not ok
		or type(ping) ~= "number"
		or not Utils.isFiniteNumber(ping)
		or ping <= 0
		or ping >= 0.5
	then
		return
	end

	if Runtime.minPing == nil or ping < Runtime.minPing then
		Runtime.minPing = ping
		Runtime.pingOneWay = ping * 0.5
	end
end

local function getPingOneWay()
	if Runtime.minPing ~= nil then
		Runtime.pingOneWay = Runtime.minPing * 0.5
	end

	return Runtime.pingOneWay
end

-- resilience
local function getResilienceBonus()
	if Runtime.resilienceBonusAt == Resilience.stack then
		return Runtime.resilienceBonus
	end

	-- SEM LIMITE
	Runtime.resilienceBonus =
		Resilience.stack * Tuning.RES_PER_PARRY

	Runtime.resilienceBonusAt = Resilience.stack

	return Runtime.resilienceBonus
end

-- registra UM fired bem-sucedido
local function registerSuccessfulFire()
	if not Resilience.detected then
		return
	end

	-- cada fired válido = +1 stack
	Resilience.stack =
		Resilience.stack + 1

	Runtime.resilienceBonusAt = -1
end

-- radius
local function computeParryRadius(speed, time, frameDelta)
	speed = tonumber(speed)
	time = tonumber(time)
	frameDelta = tonumber(frameDelta)

	speed = Utils.isFiniteNumber(speed)
		and math.max(0, speed)
		or 0

	time = Utils.isFiniteNumber(time)
		and time
		or now()

	frameDelta = Utils.isFiniteNumber(frameDelta)
		and math.max(0, frameDelta)
		or 0

	local parryRadius =
		Tuning.DEFLECT_RADIUS
		+ getResilienceBonus()

	local detectionRadius =
		parryRadius
		+ speed * (
			getPingOneWay()
			+ Tuning.ADDITIONAL_WINDOW
			+ frameDelta
		)

	return parryRadius, detectionRadius
end

-- targeting
local function onBallSync(data)
	if typeof(data) ~= "table" then
		return
	end

	local time = now()

	if data.Teleported == true then
		Runtime.teleportLockUntil =
			time + 0.20

		ParryState.fired = false
		clearArmedState()

		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0

		return
	end

	local targetId

	if Utils.isFiniteNumber(data.TargetPlayerID) then
		targetId = data.TargetPlayerID

	elseif type(data.TargetPlayerID) == "string" then
		local parsedTarget =
			tonumber(data.TargetPlayerID)

		targetId =
			Utils.isFiniteNumber(parsedTarget)
			and parsedTarget
			or -1
	else
		targetId = -1
	end

	if targetId == Runtime.lastTarget then
		return
	end

	local previousTarget =
		Runtime.lastTarget

	Runtime.lastTarget = targetId

	if targetId == Runtime.localUserId
		and previousTarget ~= Runtime.localUserId
	then
		ParryState.fired = false
	end
end

-- parry request
local function requestParry()
	local time = now()

	if not Remote.fireParry(1) then
		if Utils
			and type(Utils.recordError) == "function"
		then
			Utils.recordError(
				"AutoParry",
				"Remote.fireParry falhou"
			)
		end

		setPhase(
			"waiting",
			"remote_failed"
		)

		return false
	end

	setPhase(
		"fired",
		"parry_requested"
	)

	local ball = GameInfo.getBall()

	if ball and ball.Parent then
		Resilience.lastFireBall = ball
		Resilience.lastFireAt = time
	else
		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0
	end

	return true
end

-- hitbox
local function handleHitbox(instance)
	if typeof(instance) ~= "Instance"
		or not Utils.isActive()
		or instance.Name ~= "HitboxGrow"
	then
		return
	end

	-- Depois que já detectou uma vez,
	-- não precisa detectar novamente.
	if Resilience.detected then
		return
	end

	local ok, position = pcall(function()
		return instance.Position
	end)

	if not ok
		or typeof(position) ~= "Vector3"
	then
		return
	end

	local ball = GameInfo.getBall()

	if not (ball and ball.Parent) then
		return
	end

	local okBallPosition, ballPosition =
		pcall(function()
			return ball.Position
		end)

	if not okBallPosition
		or typeof(ballPosition) ~= "Vector3"
	then
		return
	end

	-- confirma que esse HitboxGrow pertence
	-- à bola que está sendo processada
	if (ballPosition - position).Magnitude
		> Tuning.HITBOX_PROXIMITY
	then
		return
	end

	-- A partir daqui a resiliência foi detectada.
	Resilience.detected = true

	-- força atualização do raio
	Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
	if HitboxState.connection then
		return true
	end

	local workspaceService =
		Utils.getWorkspace()

	local ok, connection = pcall(function()
		return workspaceService.DescendantAdded:Connect(
			function(instance)
				local handler =
					HitboxState.handler

				if type(handler) == "function" then
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

-- character runtime
local function bindCharacter(character)
	Runtime.generation =
		Runtime.generation + 1

	local generation =
		Runtime.generation

	Runtime.bound = false

	setPhase(
		"detached",
		"rebind_start"
	)

	disconnectConnections()
	clearRuntimeCycle()

	if not (character and character.Parent) then
		return false
	end

	local root =
		character:FindFirstChild(
			"HumanoidRootPart"
		)
		or character:WaitForChild(
			"HumanoidRootPart",
			1
		)

	if generation ~= Runtime.generation
		or not (root and root.Parent)
	then
		return false
	end

	local getConfig = Utils.getConfig
	local isSpamActive = Utils.isSpamActive
	local isFiniteNumber = Utils.isFiniteNumber

	local heartbeatConnection =
		Utils.getRunService().Heartbeat:Connect(
			function(dt)
				if generation ~= Runtime.generation then
					return
				end

				if not (
					character.Parent
					and root.Parent
				) then
					return
				end

				local config = getConfig()

				if config.AutoParry ~= true then
					clearRuntimeCycle()

					setPhase(
						"waiting",
						"disabled_or_locked"
					)

					return
				end

				local timeNow = now()

				if timeNow <
					Runtime.teleportLockUntil
				then
					clearRuntimeCycle()

					setPhase(
						"waiting",
						"disabled_or_locked"
					)

					return
				end

				if isSpamActive() then
					clearRuntimeCycle()

					setPhase(
						"waiting",
						"spam_active"
					)

					return
				end

				local frameDelta =
					isFiniteNumber(dt)
					and math.max(0, dt)
					or 0

				Runtime.pingTimer =
					Runtime.pingTimer
					+ frameDelta

				if Runtime.pingTimer
					>= PING_SAMPLE_INTERVAL
				then
					Runtime.pingTimer = 0
					samplePing()
				end

				local snapshot =
					GameInfo.getSnapshot(
						Runtime.lastTarget,
						timeNow
					)

				if not GameInfo.isSnapshotValid(
					snapshot,
					timeNow
				) then
					setPhase(
						"waiting",
						"snapshot_invalid"
					)

					return
				end

				local ball = snapshot.ball

				local deflectCooldown =
					GameInfo.getDeflectCD()

				-- armed
				if ParryState.armed then
					local sameBall =
						ball == ParryState.armedBall

					local validBall =
						ball
						and ball.Parent
						and sameBall

					if not (
						validBall
						and snapshot.targeted == true
					) then
						clearArmedState()

						setPhase(
							"waiting",
							"armed_context_invalid"
						)

					elseif deflectCooldown > 0 then
						setPhase(
							"cooldown",
							"deflect_cooldown"
						)

						return
					else
						local canRetry =
							not ParryState.fired
							or timeNow
								- ParryState.firedAt
								>= Tuning.FIRE_TIMEOUT

						if canRetry then
							if requestParry() then
								ParryState.fired = true
								ParryState.firedAt = timeNow

								-- +0.225
								registerSuccessfulFire()
							else
								ParryState.fired = false
							end
						end

						clearArmedState()
						return
					end
				end

				-- ball / target
				if not (
					ball
					and ball.Parent
				)
					or snapshot.targeted ~= true
				then
					setPhase(
						"waiting",
						"ball_or_target_invalid"
					)

					return
				end

				local speed = snapshot.speed

				if speed < Tuning.MIN_BALL_SPEED then
					setPhase(
						"waiting",
						"ball_too_slow"
					)

					return
				end

				local position =
					snapshot.position

				if not position then
					setPhase(
						"waiting",
						"position_unavailable"
					)

					return
				end

				local parryRadius, detectionRadius =
					computeParryRadius(
						speed,
						timeNow,
						frameDelta
					)

				Runtime.parryRadius =
					detectionRadius

				local offset =
					root.Position - position

				local distanceSquared =
					offset:Dot(offset)

				if distanceSquared
					> detectionRadius
						* detectionRadius
				then
					setPhase(
						"waiting",
						"outside_detection_radius"
					)

					return
				end

				local distance =
					math.sqrt(distanceSquared)

				local impactTime =
					math.max(
						0,
						(distance - parryRadius)
							/ speed
					)

				local earlyWindow =
					Tuning.ADDITIONAL_WINDOW
					+ getPingOneWay()

				if impactTime > earlyWindow then
					setPhase(
						"waiting",
						"outside_early_window"
					)

					return
				end

				-- deflect cooldown
				if deflectCooldown > 0 then
					ParryState.armed = true
					ParryState.armedBall = ball
					ParryState.armedAt = timeNow

					setPhase(
						"armed",
						"awaiting_deflect_cooldown"
					)

					return
				end

				-- fired lock
				if ParryState.fired then
					local elapsed =
						timeNow
						- ParryState.firedAt

					if elapsed
						< Tuning.FIRE_LOCK_TIME
					then
						setPhase(
							"cooldown",
							"fire_lock"
						)

						return
					end

					if elapsed
						< Tuning.FIRE_TIMEOUT
					then
						setPhase(
							"cooldown",
							"fire_timeout"
						)

						return
					end

					ParryState.fired = false

					setPhase(
						"waiting",
						"fire_retry_window"
					)
				end

				-- FIRE
				if requestParry() then
					-- IMPORTANTE:
					-- atualiza firedAt ANTES de registrar
					-- o fired na resiliência.
					ParryState.fired = true
					ParryState.firedAt = timeNow

					-- cada fired bem-sucedido
					-- após a detecção = +0.225
					registerSuccessfulFire()
				else
					ParryState.fired = false
				end
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
				if not parent then
					Runtime.generation =
						Runtime.generation + 1
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

	setPhase(
		"waiting",
		"character_bound"
	)

	return true
end

-- lifecycle
local function resetState()
	clearRuntimeCycle()

	-- MORTE / RESET:
	-- aqui sim a resiliência volta para zero.
	Resilience.stack = 0
	Resilience.detected = false
	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0

	Runtime.teleportLockUntil = 0
	Runtime.lastTarget = -1

	Runtime.pingTimer = 0
	Runtime.minPing = nil
	Runtime.pingOneWay = 0.030

	Runtime.resilienceBonus = 0
	Runtime.resilienceBonusAt = -1

	Runtime.parryRadius = 0
	Runtime.additionalWindow =
		Tuning.ADDITIONAL_WINDOW

	Runtime.stationary = false
	Runtime.bound = false

	setPhase(
		"detached",
		"reset"
	)
end

-- setup
function AutoParry.setup(deps)
	if type(deps) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.GameInfo) ~= "table"
		or type(deps.GameInfo.getDeflectCD) ~= "function"
		or type(deps.GameInfo.getBall) ~= "function"
		or type(deps.GameInfo.getSnapshot) ~= "function"
		or type(deps.GameInfo.isSnapshotValid) ~= "function"
		or type(deps.Utils) ~= "table"
		or type(deps.Utils.now) ~= "function"
		or type(deps.Utils.apiVersion) ~= "function"
		or type(deps.Utils.isFiniteNumber) ~= "function"
		or type(deps.Utils.getConfig) ~= "function"
		or type(deps.Utils.getLocalPlayer) ~= "function"
		or type(deps.Utils.getWorkspace) ~= "function"
		or type(deps.Utils.getRunService) ~= "function"
		or type(deps.Utils.trackCharacter) ~= "function"
		or type(deps.Utils.untrackCharacter) ~= "function"
		or type(deps.Utils.trackGlobal) ~= "function"
		or type(deps.Utils.isActive) ~= "function"
		or type(deps.Utils.isSpamActive) ~= "function"
	then
		return false,
			"dependência ausente: Remote.fireParry, GameInfo, Utils ou uma API obrigatória"
	end

	Remote = deps.Remote
	GameInfo = deps.GameInfo
	Utils = deps.Utils

	local localPlayer =
		Utils.getLocalPlayer()

	Runtime.localUserId =
		localPlayer
		and localPlayer.UserId
		or -1

	HitboxState.handler =
		handleHitbox

	resetState()

	if not installHitboxHook() then
		Utils.warn(
			"hook de hitbox indisponível"
		)
	end

	return true
end

function AutoParry.fire()
	return requestParry()
end

function AutoParry.bindCharacter(character)
	return bindCharacter(character)
end

function AutoParry.resetState()
	resetState()
end

function AutoParry.detachCharacter()
	Runtime.generation =
		Runtime.generation + 1

	Runtime.bound = false

	disconnectConnections()
	resetState()
end

function AutoParry.onBallSync(data)
	onBallSync(data)
end

function AutoParry.getParryRadius(speed, time)
	local _, detectionRadius =
		computeParryRadius(
			speed,
			time,
			0
		)

	return detectionRadius
end

function AutoParry.getPingOneWay()
	return getPingOneWay()
end

function AutoParry.getStatus()
	return {
		schema = Utils.apiVersion(),

		phase = Runtime.phase,
		bound = Runtime.bound == true,

		armed = ParryState.armed == true,
		fired = ParryState.fired == true,

		resilienceStack = Resilience.stack,
		resilienceDetected =
			Resilience.detected == true,

		parryRadius = Runtime.parryRadius,
		additionalWindow =
			Runtime.additionalWindow,

		stationary =
			Runtime.stationary == true,
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