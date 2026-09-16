-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

-- tuning
local Tuning = {
	-- radius
	DEFLECT_RADIUS = 7,
	PARRY_WINDOW = 0.15,
	MIN_BALL_SPEED = 8,
	RES_PER_PARRY = 0.19,
	RES_CAP_STUDS = 32,
	HITBOX_OWN_WINDOW = 0.5,
	HITBOX_PROXIMITY = 12,
	HITBOX_GAP = 0.4,

	-- movement
	STATIONARY_MULT = 1.30,
	STATIONARY_SPEED = 1.5,
	STATIONARY_DWELL = 0.20,

	-- cooldown propagation
	CLIENT_CD_PROPAGATION = 0.30,
}

-- cor da bola que indica "alvo = eu" (igual o Phantom Lupa faz)
local TARGET_BRICK_COLOR = BrickColor.new("Bright red")
local BRICK_LOOKUP = {}

local function _isTargetColor(ball)
	if not ball or ball.Parent == nil then
		return false
	end

	local bc = ball.BrickColor
	if bc == TARGET_BRICK_COLOR then
		return true
	end

	-- fallback: aceita qualquer cor com a mesma numeração
	local number = bc.Number
	if number == TARGET_BRICK_COLOR.Number then
		return true
	end

	-- qualquer BrickColor "vermelha" (faixa do Bright red)
	if number >= 21 and number <= 23 then
		return true
	end

	return false
end

local PING_SAMPLE_INTERVAL = 1.5
local DEFAULT_PING_ONE_WAY = 0.030
local TELEPORT_LOCK = 0.20
local MAX_RES_STACK = math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY)
local HITBOX_PROXIMITY_SQ = Tuning.HITBOX_PROXIMITY ^ 2
local STATIONARY_SPEED_SQ = Tuning.STATIONARY_SPEED ^ 2

local PHASE_DETACHED = 1
local PHASE_WAITING = 2
local PHASE_COOLDOWN = 3
local PHASE_ARMED = 4
local PHASE_FIRED = 5

local PHASE_STRINGS = {
	[PHASE_DETACHED] = "detached",
	[PHASE_WAITING] = "waiting",
	[PHASE_COOLDOWN] = "cooldown",
	[PHASE_ARMED] = "armed",
	[PHASE_FIRED] = "fired",
}

local phaseString = PHASE_STRINGS[PHASE_DETACHED]

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
	armedWasTargeted = false,
	fired = false,
	firedBall = nil,
	firedAt = 0,
}

local Resilience = {
	stack = 0,
	lastFireBall = nil,
	lastFireAt = 0,
	lastHitboxAt = 0,
}

local Runtime = {
	generation = 0,
	lastBallRef = nil,
	lastBallWasTargeted = false,
	teleportLockUntil = 0,
	connections = {},
	minPing = nil,
	pingTimer = 0,
	pingOneWay = DEFAULT_PING_ONE_WAY,
	resilienceBonus = 0,
	resilienceBonusAt = -1,
	parryRadius = 0,
	stationary = false,
	stationarySince = 0,
	lastRootPos = nil,
	lastRootPosAt = 0,
	lastFireAt = 0,
	cooldownObservedAt = 0,
	phase = PHASE_DETACHED,
	bound = false,
}

local StatsService

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
	ParryState.armedWasTargeted = false
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
	if not StatsService then
		return
	end

	local okItem, pingItem = pcall(function()
		return StatsService.Network.ServerStatsItem["Data Ping"]
	end)

	if not okItem or not pingItem then
		return
	end

	local ok, ping = pcall(pingItem.GetValue, pingItem)

	if not ok or type(ping) ~= "number" then
		return
	end

	ping *= 0.001

	if not Utils.isFiniteNumber(ping) or ping <= 0 or ping >= 0.5 then
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

local function computeParryRadius(time)
	return Tuning.DEFLECT_RADIUS + getResilienceBonus(time)
end

-- request
local function requestParry()
	if type(Remote.fireParry) ~= "function" then
		if type(Utils.recordError) == "function" then
			Utils.recordError("AutoParry", "Remote.fireParry indisponível")
		end

		setPhase(PHASE_WAITING, "remote_unavailable")
		return false
	end

	local time = now()
	local ok, result = pcall(Remote.fireParry, 1)

	if not ok or result == false then
		if type(Utils.recordError) == "function" then
			Utils.recordError("AutoParry", "Remote.fireParry falhou")
		end

		setPhase(PHASE_WAITING, "remote_failed")
		return false
	end

	Runtime.lastFireAt = time
	Runtime.cooldownObservedAt = 0

	local ball = GameInfo.getBall()

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
		or not Utils.isActive()
	then
		return
	end

	local time = now()

	if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW
		or time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP
	then
		return
	end

	local ball = Resilience.lastFireBall

	if not isValidBall(ball) then
		return
	end

	local position, ballPosition

	local ok = pcall(function()
		position = instance.Position
		ballPosition = ball.Position
	end)

	if not ok
		or typeof(position) ~= "Vector3"
		or typeof(ballPosition) ~= "Vector3"
	then
		return
	end

	if getDistanceSquared(ballPosition, position) > HITBOX_PROXIMITY_SQ then
		return
	end

	Resilience.lastHitboxAt = time
	Resilience.stack = math.min(
		Resilience.stack + 1,
		MAX_RES_STACK
	)

	Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
	if HitboxState.connection then
		return true
	end

	local workspaceService = Utils.getWorkspace()

	if not workspaceService then
		return false
	end

	local ok, connection = pcall(function()
		return workspaceService.DescendantAdded:Connect(function(instance)
			local handler = HitboxState.handler

			if type(handler) == "function" then
				handler(instance)
			end
		end)
	end)

	if not ok or not connection then
		return false
	end

	HitboxState.connection = connection

	if type(Utils.trackGlobal) == "function" then
		Utils.trackGlobal(connection)
	end

	return true
end

-- character
local function bindCharacter(character)
	Runtime.generation += 1

	local generation = Runtime.generation

	Runtime.bound = false
	disconnectConnections()
	clearCycle()
	setPhase(PHASE_DETACHED, "rebind_start")

	if not character or not character.Parent then
		return false
	end

	local root = character:FindFirstChild("HumanoidRootPart")

	if not root then
		root = character:WaitForChild("HumanoidRootPart", 1)
	end

	if generation ~= Runtime.generation
		or not root
		or not root.Parent
	then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		local diedConnection = humanoid.Died:Connect(function()
			resetResilience()
			clearCycle()
		end)

		Runtime.connections[#Runtime.connections + 1] = diedConnection
		Utils.trackCharacter(diedConnection)
	end

	local heartbeat = Utils.getRunService().Heartbeat
	local getConfig = Utils.getConfig
	local isSpamActive = Utils.isSpamActive

	local heartbeatConnection = heartbeat:Connect(function(dt)
		if generation ~= Runtime.generation then
			return
		end

		if not character.Parent or not root.Parent then
			return
		end

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

		if isSpamActive() then
			clearCycle()
			setPhase(PHASE_WAITING, "spam_active")
			return
		end

		Runtime.pingTimer += math.max(dt, 0)

		if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then
			Runtime.pingTimer = 0
			samplePing()
		end

		local ball = GameInfo.getBall()

		-- alvo = eu agora é decidido pela BrickColor da bola (igual Phantom Lupa)
		local targeted = isValidBall(ball) and _isTargetColor(ball) == true

		if Runtime.lastBallRef ~= ball then
			Runtime.lastBallRef = ball
			Runtime.lastBallWasTargeted = targeted
		elseif targeted ~= Runtime.lastBallWasTargeted then
			Runtime.lastBallWasTargeted = targeted
		end

		local ballValid = isValidBall(ball)
		local snapshot

		if ballValid then
			snapshot = {
				valid = true,
				ballValid = true,
				ball = ball,
				position = ball.Position,
				speed = ball.AssemblyLinearVelocity.Magnitude,
			}
		else
			snapshot = {
				valid = false,
				ballValid = false,
			}
		end

		if not (ballValid and targeted) then
			if ParryState.armed then
				clearArmed()
			end
			setPhase(PHASE_WAITING, "ball_or_color_invalid")
			return
		end

		if not GameInfo.isSnapshotValid(snapshot, timeNow) then
			setPhase(PHASE_WAITING, "snapshot_invalid")
			return
		end

		local deflectCooldown = tonumber(GameInfo.getDeflectCD()) or 0

		if not Utils.isFiniteNumber(deflectCooldown) then
			deflectCooldown = 0
		end

		if ParryState.armed then
			if not (
				isValidBall(ball)
				and ball == ParryState.armedBall
				and targeted
			) then
				clearArmed()
				setPhase(PHASE_WAITING, "armed_context_invalid")
			elseif deflectCooldown <= 0 then
				if requestParry() then
					ParryState.fired = true
					ParryState.firedBall = ball
					ParryState.firedAt = timeNow
				end

				clearArmed()
				return
			else
				setPhase(PHASE_ARMED, "awaiting_deflect_cooldown")
				return
			end
		end

		if deflectCooldown > 0 then
			if Runtime.cooldownObservedAt <= 0 then
				Runtime.cooldownObservedAt = timeNow
			elseif timeNow - Runtime.cooldownObservedAt >= Tuning.CLIENT_CD_PROPAGATION then
				setPhase(PHASE_COOLDOWN, "cooldown_observed")
			else
				setPhase(PHASE_COOLDOWN, "cooldown_propagation")
			end
		else
			Runtime.cooldownObservedAt = 0
		end

		if not (isValidBall(ball) and targeted) then
			setPhase(PHASE_WAITING, "ball_or_color_invalid")
			return
		end

		local speed = tonumber(snapshot.speed)

		if not speed
			or not Utils.isFiniteNumber(speed)
			or speed < Tuning.MIN_BALL_SPEED
		then
			setPhase(PHASE_WAITING, "ball_too_slow")
			return
		end

		local position = snapshot.position

		if typeof(position) ~= "Vector3" then
			setPhase(PHASE_WAITING, "position_unavailable")
			return
		end

		local rootPos = root.Position
		local parryRadius = computeParryRadius(timeNow)
		local parryWindow = Tuning.PARRY_WINDOW

		local previousPos = Runtime.lastRootPos
		local previousTime = Runtime.lastRootPosAt

		Runtime.lastRootPos = rootPos
		Runtime.lastRootPosAt = timeNow

		if previousPos and timeNow > previousTime then
			local invDt = 1 / (timeNow - previousTime)
			local vx = (rootPos.X - previousPos.X) * invDt
			local vz = (rootPos.Z - previousPos.Z) * invDt
			local horizontalSpeedSq = vx * vx + vz * vz

			if horizontalSpeedSq < STATIONARY_SPEED_SQ then
				if Runtime.stationarySince == 0 then
					Runtime.stationarySince = timeNow
				end
			else
				Runtime.stationarySince = 0
			end
		elseif Runtime.stationarySince == 0 then
			Runtime.stationarySince = timeNow
		end

		Runtime.stationary =
			Runtime.stationarySince > 0
			and timeNow - Runtime.stationarySince >= Tuning.STATIONARY_DWELL

		if Runtime.stationary then
			parryWindow *= Tuning.STATIONARY_MULT
		end

		Runtime.parryRadius = parryRadius + speed * parryWindow

		local distanceSquared = getDistanceSquared(rootPos, position)
		local distance = math.sqrt(distanceSquared)

		local tti = (distance - parryRadius) / speed

		if tti > parryWindow then
			setPhase(PHASE_WAITING, "outside_ping_window")
			return
		end

		if deflectCooldown > 0 then
			if not ParryState.armed then
				ParryState.armed = true
				ParryState.armedBall = ball
				ParryState.armedWasTargeted = targeted
			end

			setPhase(PHASE_ARMED, "awaiting_deflect_cooldown")
			return
		end

		if ParryState.fired then
			if ParryState.firedBall == ball then
				setPhase(PHASE_FIRED, "ball_already_fired")
				return
			end

			if not isValidBall(ParryState.firedBall)
				or ParryState.firedBall ~= ball
			then
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
	Utils.trackCharacter(heartbeatConnection)

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
	Utils.trackCharacter(ancestryConnection)

	Runtime.bound = true
	setPhase(PHASE_WAITING, "character_bound")

	return true
end

-- lifecycle
local function resetState()
	clearCycle()

	Runtime.teleportLockUntil = 0
	Runtime.lastBallRef = nil
	Runtime.lastBallWasTargeted = false
	Runtime.pingTimer = 0
	Runtime.minPing = nil
	Runtime.pingOneWay = DEFAULT_PING_ONE_WAY
	Runtime.parryRadius = 0
	Runtime.stationary = false
	Runtime.stationarySince = 0
	Runtime.lastRootPos = nil
	Runtime.lastRootPosAt = 0
	Runtime.lastFireAt = 0
	Runtime.cooldownObservedAt = 0
	Runtime.bound = false

	setPhase(PHASE_DETACHED, "reset")
end

-- setup
function AutoParry.setup(deps)
	if type(deps) ~= "table" then
		return false, "dependências inválidas"
	end

	local remote = deps.Remote
	local gameInfo = deps.GameInfo
	local utils = deps.Utils

	if type(remote) ~= "table"
		or type(remote.fireParry) ~= "function"
	then
		return false, "dependência ausente: Remote.fireParry"
	end

	if type(gameInfo) ~= "table"
		or type(gameInfo.getDeflectCD) ~= "function"
		or type(gameInfo.getBall) ~= "function"
		or type(gameInfo.isSnapshotValid) ~= "function"
	then
		return false, "dependência ausente: GameInfo"
	end

	if type(utils) ~= "table"
		or type(utils.now) ~= "function"
		or type(utils.apiVersion) ~= "function"
		or type(utils.isFiniteNumber) ~= "function"
		or type(utils.getConfig) ~= "function"
		or type(utils.getWorkspace) ~= "function"
		or type(utils.getRunService) ~= "function"
		or type(utils.trackCharacter) ~= "function"
		or type(utils.untrackCharacter) ~= "function"
		or type(utils.trackGlobal) ~= "function"
		or type(utils.isActive) ~= "function"
		or type(utils.isSpamActive) ~= "function"
	then
		return false, "dependência ausente: Utils"
	end

	Remote = remote
	GameInfo = gameInfo
	Utils = utils

	StatsService = game:GetService("Stats")

	HitboxState.handler = handleHitbox

	resetResilience()
	resetState()

	if not installHitboxHook()
		and type(Utils.warn) == "function"
	then
		Utils.warn("hook de hitbox indisponível")
	end

	return true
end

function AutoParry.fire()
	if not Remote or not GameInfo or not Utils then
		return false
	end

	return requestParry()
end

function AutoParry.bindCharacter(character)
	if not Remote or not GameInfo or not Utils then
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
	Runtime.generation += 1
	Runtime.bound = false

	disconnectConnections()
	resetState()
end

-- mantido como no-op pra não quebrar quem chama; alvo agora é por BrickColor
function AutoParry.onBallSync(data)
	return
end

function AutoParry.getParryRadius()
	return Runtime.parryRadius
end

function AutoParry.getPingOneWay()
	return Runtime.pingOneWay
end

function AutoParry.getStatus()
	return {
		schema = Utils and Utils.apiVersion() or nil,
		phase = phaseString,
		bound = Runtime.bound == true,
		armed = ParryState.armed == true,
		fired = ParryState.fired == true,
		resilienceStack = Resilience.stack,
		parryRadius = Runtime.parryRadius,
		stationary = Runtime.stationary == true,
	}
end

function AutoParry.isTargetingMe(ball)
	return _isTargetColor(ball)
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
