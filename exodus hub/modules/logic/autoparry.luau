-- [[ Auto Parry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

-- tuning
local Tuning = {
	-- radius
	DEFLECT_RADIUS = 8.5,
	DETECTION_RADIUS_FACTOR = 1.50,
	MIN_BALL_SPEED = 6,
	RES_PER_PARRY = 0.225,
	RES_CAP_STUDS = 32,
	HITBOX_OWN_WINDOW = 0.5,
	HITBOX_PROXIMITY = 12,
	HITBOX_GAP = 0.4,
}
local PING_SAMPLE_INTERVAL = 1.5
local DEFAULT_PING_ONE_WAY = 0.030
local TELEPORT_LOCK = 0.20

-- phase constants
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

-- shared hitbox hook
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table" and namespace.AutoParryHitbox or { connection = nil, handler = nil }
namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- state
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
}
local Runtime = {
	generation = 0,
	localUserId = -1,
	lastTarget = -1,
	teleportLockUntil = 0,
	connections = {},
	minPing = nil,
	pingTimer = 0,
	pingOneWay = DEFAULT_PING_ONE_WAY,
	resilienceBonus = 0,
	resilienceBonusAt = -1,
	parryRadius = 0,
	stationary = false,
	phase = PHASE_DETACHED,
	bound = false,
}
local Stats = game:GetService("Stats")
local PingItem = Stats.Network.ServerStatsItem["Data Ping"]

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
		Utils.recordTransition("AutoParry", PHASE_STRINGS[previous] or "detached", phaseString, reason)
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
		Utils.untrackCharacter(connection)
		pcall(connection.Disconnect, connection)
	end
end

-- ping
local function samplePing()
	local ok, ping = pcall(PingItem.GetValue, PingItem)
	ping = ok and ping / 1000 or nil
	if type(ping) ~= "number" or not Utils.isFiniteNumber(ping) or ping <= 0 or ping >= 0.5 then
		return
	end
	if not Runtime.minPing or ping < Runtime.minPing then
		Runtime.minPing = ping
		Runtime.pingOneWay = ping * 0.5
	end
end
local function getPingOneWay()
	return Runtime.pingOneWay
end

-- resilience
local function getResilienceBonus(time)
	if Runtime.resilienceBonusAt == time then
		return Runtime.resilienceBonus
	end
	Runtime.resilienceBonus = math.min(Resilience.stack * Tuning.RES_PER_PARRY, Tuning.RES_CAP_STUDS)
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

-- radius
local function computeParryRadius(_, time)
	time = Utils.isFiniteNumber(time) and time or now()
	local radius = Tuning.DEFLECT_RADIUS + getResilienceBonus(time)
	return radius, radius * Tuning.DETECTION_RADIUS_FACTOR
end

-- targeting
local function onBallSync(data)
	if typeof(data) ~= "table" then
		return
	end
	local time = now()
	if data.Teleported == true then
		Runtime.teleportLockUntil = time + TELEPORT_LOCK
		clearArmed()
		clearFired()
		Resilience.lastFireBall = nil
		Resilience.lastFireAt = 0
		return
	end
	local targetId = data.TargetPlayerID
	if not Utils.isFiniteNumber(targetId) then
		targetId = tonumber(targetId) or -1
	end
	if targetId == Runtime.lastTarget then
		return
	end
	local previousTarget = Runtime.lastTarget
	Runtime.lastTarget = targetId
	if targetId == Runtime.localUserId and previousTarget ~= Runtime.localUserId then
		clearFired()
	end
end

-- parry request
local function requestParry()
	local time = now()
	if not Remote.fireParry(1) then
		if Utils and type(Utils.recordError) == "function" then
			Utils.recordError("AutoParry", "Remote.fireParry falhou")
		end
		setPhase(PHASE_WAITING, "remote_failed")
		return false
	end
	setPhase(PHASE_FIRED, "parry_requested")
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
	if typeof(instance) ~= "Instance" or not Utils.isActive() or instance.Name ~= "HitboxGrow" then
		return
	end
	local time = now()
	if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW or time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP then
		return
	end
	local ball = Resilience.lastFireBall
	if not (ball and ball.Parent) then
		return
	end
	local ok, position, ballPosition = pcall(function()
		return instance.Position, ball.Position
	end)
	if not ok or typeof(position) ~= "Vector3" or typeof(ballPosition) ~= "Vector3" then
		return
	end
	local delta = ballPosition - position
	if delta:Dot(delta) > Tuning.HITBOX_PROXIMITY ^ 2 then
		return
	end
	Resilience.lastHitboxAt = time
	Resilience.stack = math.min(Resilience.stack + 1, math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY))
	Runtime.resilienceBonusAt = -1
end
local function installHitboxHook()
	if HitboxState.connection then
		return true
	end
	local workspaceService = Utils.getWorkspace()
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
	Utils.trackGlobal(connection)
	return true
end

-- character runtime
local function bindCharacter(character)
	Runtime.generation += 1
	local generation = Runtime.generation
	Runtime.bound = false
	setPhase(PHASE_DETACHED, "rebind_start")
	disconnectConnections()
	clearCycle()
	if not (character and character.Parent) then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
	if generation ~= Runtime.generation or not (root and root.Parent) then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local connection = humanoid.Died:Connect(resetResilience)
		Runtime.connections[#Runtime.connections + 1] = connection
		Utils.trackCharacter(connection)
	end
	local getConfig = Utils.getConfig
	local isSpamActive = Utils.isSpamActive
	local heartbeat = Utils.getRunService().Heartbeat
	local heartbeatConnection = heartbeat:Connect(function(dt)
		if generation ~= Runtime.generation or not (character.Parent and root.Parent) then
			return
		end
		local config = getConfig()
		if config.AutoParry ~= true then
			clearCycle()
			setPhase(PHASE_WAITING, "disabled_or_locked")
			return
		end
		local timeNow = now()
		if timeNow < Runtime.teleportLockUntil then
			clearCycle()
			setPhase(PHASE_WAITING, "disabled_or_locked")
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
		local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, timeNow)
		if not GameInfo.isSnapshotValid(snapshot, timeNow) then
			setPhase(PHASE_WAITING, "snapshot_invalid")
			return
		end
		local ball = snapshot.ball
		local targeted = snapshot.targeted == true
		local deflectCooldown = GameInfo.getDeflectCD()
		-- armed state
		if ParryState.armed then
			if not (ball and ball.Parent and ball == ParryState.armedBall and targeted) then
				clearArmed()
				setPhase(PHASE_WAITING, "armed_context_invalid")
			elseif deflectCooldown > 0 then
				setPhase(PHASE_COOLDOWN, "deflect_cooldown")
				return
			else
				if requestParry() then
					ParryState.fired = true
					ParryState.firedBall = ball
					ParryState.firedAt = timeNow
				end
				clearArmed()
				return
			end
		end
		-- basic validation
		if not (ball and ball.Parent and targeted) then
			setPhase(PHASE_WAITING, "ball_or_target_invalid")
			return
		end
		local speed = snapshot.speed
		if speed < Tuning.MIN_BALL_SPEED then
			setPhase(PHASE_WAITING, "ball_too_slow")
			return
		end
		local position = snapshot.position
		if not position then
			setPhase(PHASE_WAITING, "position_unavailable")
			return
		end
		local parryRadius, detectionRadius = computeParryRadius(speed, timeNow)
		Runtime.parryRadius = parryRadius
		local delta = root.Position - position
		local distanceSquared = delta:Dot(delta)
		local detectionSquared = detectionRadius * detectionRadius
		if distanceSquared > detectionSquared then
			setPhase(PHASE_WAITING, "outside_detection_radius")
			return
		end
		local distance = math.sqrt(distanceSquared)
		local impactTime = math.max(0, (distance - parryRadius) / speed)
		if impactTime > Runtime.pingOneWay then
			setPhase(PHASE_WAITING, "outside_ping_window")
			return
		end
		if deflectCooldown > 0 then
			ParryState.armed = true
			ParryState.armedBall = ball
			setPhase(PHASE_ARMED, "awaiting_deflect_cooldown")
			return
		end
		if ParryState.fired and ParryState.firedBall == ball then
			setPhase(PHASE_WAITING, "ball_already_fired")
			return
		end
		if requestParry() then
			ParryState.fired = true
			ParryState.firedBall = ball
			ParryState.firedAt = timeNow
		else
			clearFired()
		end
	end)
	Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
	Utils.trackCharacter(heartbeatConnection)
	local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			Runtime.generation += 1
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
	Runtime.lastTarget = -1
	Runtime.pingTimer = 0
	Runtime.minPing = nil
	Runtime.pingOneWay = DEFAULT_PING_ONE_WAY
	Runtime.parryRadius = 0
	Runtime.stationary = false
	Runtime.bound = false
	setPhase(PHASE_DETACHED, "reset")
end

-- setup
function AutoParry.setup(deps)
	if type(deps) ~= "table" or type(deps.Remote) ~= "table" or type(deps.Remote.fireParry) ~= "function" or type(deps.GameInfo) ~= "table" or type(deps.GameInfo.getDeflectCD) ~= "function" or type(deps.GameInfo.getBall) ~= "function" or type(deps.GameInfo.getSnapshot) ~= "function" or type(deps.GameInfo.isSnapshotValid) ~= "function" or type(deps.Utils) ~= "table" or type(deps.Utils.now) ~= "function" or type(deps.Utils.apiVersion) ~= "function" or type(deps.Utils.isFiniteNumber) ~= "function" or type(deps.Utils.getConfig) ~= "function" or type(deps.Utils.getLocalPlayer) ~= "function" or type(deps.Utils.getWorkspace) ~= "function" or type(deps.Utils.getRunService) ~= "function" or type(deps.Utils.trackCharacter) ~= "function" or type(deps.Utils.untrackCharacter) ~= "function" or type(deps.Utils.trackGlobal) ~= "function" or type(deps.Utils.isActive) ~= "function" or type(deps.Utils.isSpamActive) ~= "function" then
		return false, "dependência ausente: Remote.fireParry, GameInfo, Utils ou uma API obrigatória"
	end
	Remote = deps.Remote
	GameInfo = deps.GameInfo
	Utils = deps.Utils
	local localPlayer = Utils.getLocalPlayer()
	Runtime.localUserId = localPlayer and localPlayer.UserId or -1
	HitboxState.handler = handleHitbox
	resetResilience()
	resetState()
	if not installHitboxHook() then
		Utils.warn("hook de hitbox indisponível")
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
	Runtime.generation += 1
	Runtime.bound = false
	disconnectConnections()
	resetState()
end
function AutoParry.onBallSync(data)
	onBallSync(data)
end
function AutoParry.getParryRadius(speed, time)
	return computeParryRadius(speed, time)
end
function AutoParry.getPingOneWay()
	return Runtime.pingOneWay
end
function AutoParry.getStatus()
	return {
		schema = Utils.apiVersion(),
		phase = phaseString,
		bound = Runtime.bound == true,
		armed = ParryState.armed == true,
		fired = ParryState.fired == true,
		resilienceStack = Resilience.stack,
		parryRadius = Runtime.parryRadius,
		stationary = Runtime.stationary == true,
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
