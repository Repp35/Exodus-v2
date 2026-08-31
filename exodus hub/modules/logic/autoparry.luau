-- [[ Auto Parry ]]

local AutoParry = {}
local Remote
local GameInfo
local Utils

-- tuning
local Tuning = {
	MIN_BALL_SPEED = 5,
	BALL_BASE_SPEED = 16,
	BALL_MAX_SPEED = 600,
	REARM_DISTANCE = 2,
	COOLDOWN_CONFIRM_TIME = 0.20,
	DEFLECT_RADIUS = 8.5,
	RES_PER_PARRY = 0.225,
	RES_CAP_STUDS = 32,
	DEFLECT_WINDOW_MAX = 0.85,
	DEFLECT_WINDOW_MIN = 0.20,
	PING_SAMPLE_INTERVAL = 1.5,
	PING_EMA_ALPHA = 0.3,
	PING_FLOOR = 0.030,
	PING_CAP = 0.300,
	PING_WINDOW_FLOOR = 0.10,
	HITBOX_OWN_WINDOW = 0.5,
	HITBOX_PROXIMITY = 3,
	HITBOX_GAP = 0.4,
}

-- shared hitbox hook
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table" and namespace.AutoParryHitbox or {
	connection = nil,
	handler = nil,
}
namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- state
local ParryState = {
	firedThisBall = false,
	ball = nil,
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
	resilienceBonus = 0,
	resilienceBonusAt = -1,
	parryRadius = 0,
	deflectionWindow = Tuning.DEFLECT_WINDOW_MAX,
	smoothPing = 0.060,
	pingTimer = 0,
	cooldownSeenAt = 0,
	cooldownConfirmed = false,
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
		Utils.recordTransition("AutoParry", previous, phase, reason)
	end
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
	ParryState.firedThisBall = false
	ParryState.ball = nil
	Runtime.parryRadius = 0
end

-- cooldown
local function updateCooldownState(time)
	local cooldown = GameInfo.getDeflectCD()
	if not Utils.isFiniteNumber(cooldown) or cooldown <= 0 then
		Runtime.cooldownSeenAt = 0
		Runtime.cooldownConfirmed = false
		return false
	end
	if Runtime.cooldownSeenAt <= 0 then
		Runtime.cooldownSeenAt = time
	end
	if time - Runtime.cooldownSeenAt >= Tuning.COOLDOWN_CONFIRM_TIME then
		Runtime.cooldownConfirmed = true
	end
	return true
end

-- resilience
local function getResilienceBonus(time)
	if time == Runtime.resilienceBonusAt then
		return Runtime.resilienceBonus
	end
	Runtime.resilienceBonus = math.min(Resilience.stack * Tuning.RES_PER_PARRY, Tuning.RES_CAP_STUDS)
	Runtime.resilienceBonusAt = time
	return Runtime.resilienceBonus
end

-- ping compensation
local function samplePing()
	local ok, ping = pcall(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
	end)
	if ok and type(ping) == "number" and ping > 0 and ping < 0.5 then
		Runtime.smoothPing = Runtime.smoothPing * (1 - Tuning.PING_EMA_ALPHA) + ping * Tuning.PING_EMA_ALPHA
	end
end
local function getPingCompensation()
	return math.clamp(Runtime.smoothPing * 0.5, Tuning.PING_FLOOR, Tuning.PING_CAP)
end

-- deflection window
local function computeDeflectionWindow(speed)
	local base
	if not Utils.isFiniteNumber(speed) or speed <= Tuning.BALL_BASE_SPEED then
		base = Tuning.DEFLECT_WINDOW_MAX
	elseif speed >= Tuning.BALL_MAX_SPEED then
		base = Tuning.DEFLECT_WINDOW_MIN
	else
		local t = (speed - Tuning.BALL_BASE_SPEED) / (Tuning.BALL_MAX_SPEED - Tuning.BALL_BASE_SPEED)
		base = Tuning.DEFLECT_WINDOW_MAX + (Tuning.DEFLECT_WINDOW_MIN - Tuning.DEFLECT_WINDOW_MAX) * t
	end
	local window = base - getPingCompensation()
	return math.max(window, Tuning.PING_WINDOW_FLOOR)
end

-- radius
local function computeParryRadius(time)
	time = Utils.isFiniteNumber(time) and time or now()
	local radius = Tuning.DEFLECT_RADIUS + getResilienceBonus(time)
	return math.max(radius, 0)
end

-- targeting
local function onBallSync(data)
	if typeof(data) ~= "table" then
		return
	end
	local time = now()
	if data.Teleported == true then
		Runtime.teleportLockUntil = time + 0.20
		ParryState.firedThisBall = false
		return
	end
	if data.Grace == true then
		Runtime.teleportLockUntil = time + 0.20
		ParryState.firedThisBall = false
		return
	end
	local targetId
	if Utils.isFiniteNumber(data.TargetPlayerID) then
		targetId = data.TargetPlayerID
	elseif type(data.TargetPlayerID) == "string" then
		local parsedTarget = tonumber(data.TargetPlayerID)
		targetId = Utils.isFiniteNumber(parsedTarget) and parsedTarget or -1
	else
		targetId = -1
	end
	if targetId == Runtime.lastTarget then
		return
	end
	Runtime.lastTarget = targetId
	ParryState.firedThisBall = false
end

-- parry request
local function requestParry()
	local time = now()
	if not Remote.fireParry(1) then
		if Utils and type(Utils.recordError) == "function" then
			Utils.recordError("AutoParry", "Remote.fireParry falhou")
		end
		return false
	end
	setPhase("fired", "parry_requested")
	ParryState.firedThisBall = true
	local ball = GameInfo.getBall()
	if ball and ball.Parent then
		Resilience.lastFireBall = ball
		Resilience.lastFireAt = time
	end
	return true
end

-- hitbox
local function handleHitbox(instance)
	if typeof(instance) ~= "Instance" or not Utils.isActive() or instance.Name ~= "HitboxGrow" then
		return
	end
	local ok, position = pcall(function()
		return instance.Position
	end)
	if not ok or typeof(position) ~= "Vector3" then
		return
	end
	local time = now()
	if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW then
		return
	end
	if not (Resilience.lastFireBall and Resilience.lastFireBall.Parent) then
		return
	end
	if time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP then
		return
	end
	local okBall, ballPosition = pcall(function()
		return Resilience.lastFireBall.Position
	end)
	if not okBall or typeof(ballPosition) ~= "Vector3" then
		return
	end
	if (ballPosition - position).Magnitude > Tuning.HITBOX_PROXIMITY then
		return
	end
	Resilience.lastHitboxAt = time
	local maxStack = math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY)
	Resilience.stack = math.min(Resilience.stack + 1, maxStack)
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
	Utils.trackGlobal(connection)
	return true
end

-- character runtime
local function bindCharacter(character)
	Runtime.generation = Runtime.generation + 1
	local generation = Runtime.generation
	Runtime.bound = false
	setPhase("detached", "rebind_start")
	disconnectConnections()
	clearRuntimeCycle()
	if not (character and character.Parent) then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
	if generation ~= Runtime.generation or not (root and root.Parent) then
		return false
	end
	local getConfig = Utils.getConfig
	local isSpamActive = Utils.isSpamActive
	local heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function(dt)
		if generation ~= Runtime.generation then
			return
		end
		if not (character.Parent and root.Parent) then
			Runtime.bound = false
			return
		end
		local config = getConfig()
		if type(config) ~= "table" or config.AutoParry ~= true then
			setPhase("waiting", "disabled")
			return
		end
		local timeNow = now()
		Runtime.pingTimer = Runtime.pingTimer + (Utils.isFiniteNumber(dt) and math.max(0, dt) or 0)
		if Runtime.pingTimer >= Tuning.PING_SAMPLE_INTERVAL then
			Runtime.pingTimer = 0
			samplePing()
		end
		if timeNow < Runtime.teleportLockUntil then
			setPhase("waiting", "grace_or_teleport_lock")
			return
		end
		if isSpamActive() then
			clearRuntimeCycle()
			setPhase("waiting", "spam_active")
			return
		end
		local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, timeNow)
		if not GameInfo.isSnapshotValid(snapshot, timeNow) then
			setPhase("waiting", "snapshot_invalid")
			return
		end
		local ball = snapshot.ball
		if updateCooldownState(timeNow) then
			setPhase("waiting", Runtime.cooldownConfirmed and "server_on_cooldown" or "cooldown_confirming")
			return
		end
		if not (ball and ball.Parent) or snapshot.targeted ~= true then
			setPhase("waiting", "ball_or_target_invalid")
			return
		end
		if ParryState.ball ~= ball then
			ParryState.ball = ball
			ParryState.firedThisBall = false
		end
		local speed = snapshot.speed
		if not Utils.isFiniteNumber(speed) or speed < Tuning.MIN_BALL_SPEED then
			setPhase("waiting", "ball_too_slow")
			return
		end
		local position = snapshot.position
		if typeof(position) ~= "Vector3" then
			setPhase("waiting", "position_unavailable")
			return
		end
		local deflectionWindow = computeDeflectionWindow(speed)
		Runtime.deflectionWindow = deflectionWindow
		local parryRadius = computeParryRadius(timeNow)
		Runtime.parryRadius = parryRadius
		local offset = root.Position - position
		local distanceSquared = offset:Dot(offset)
		if ParryState.firedThisBall and distanceSquared > (parryRadius + Tuning.REARM_DISTANCE) ^ 2 then
			ParryState.firedThisBall = false
		end
		if ParryState.firedThisBall then
			setPhase("waiting", "already_fired")
			return
		end
		if distanceSquared > parryRadius * parryRadius then
			setPhase("waiting", "outside_parry_radius")
			return
		end
		if requestParry() then
			ParryState.firedThisBall = true
		end
	end)
	Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
	Utils.trackCharacter(heartbeatConnection)
	local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			Runtime.generation = Runtime.generation + 1
			Runtime.bound = false
			setPhase("detached", "character_removed")
		end
	end)
	Runtime.connections[#Runtime.connections + 1] = ancestryConnection
	Utils.trackCharacter(ancestryConnection)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local diedConnection = humanoid.Died:Connect(function()
			if generation ~= Runtime.generation then
				return
			end
			Resilience.stack = 0
			Runtime.resilienceBonusAt = -1
		end)
		Runtime.connections[#Runtime.connections + 1] = diedConnection
		Utils.trackCharacter(diedConnection)
	end
	Runtime.bound = true
	setPhase("waiting", "character_bound")
	return true
end

-- lifecycle
local function resetState()
	clearRuntimeCycle()
	Resilience.stack = 0
	Resilience.lastFireBall = nil
	Resilience.lastFireAt = 0
	Resilience.lastHitboxAt = 0
	Runtime.teleportLockUntil = 0
	Runtime.lastTarget = -1
	Runtime.resilienceBonus = 0
	Runtime.resilienceBonusAt = -1
	Runtime.parryRadius = 0
	Runtime.deflectionWindow = Tuning.DEFLECT_WINDOW_MAX
	Runtime.pingTimer = 0
	Runtime.cooldownSeenAt = 0
	Runtime.cooldownConfirmed = false
	Runtime.bound = false
	setPhase("detached", "reset")
end

-- setup
function AutoParry.setup(deps)
	if type(deps) ~= "table" or type(deps.Remote) ~= "table" or type(deps.Remote.fireParry) ~= "function" or type(deps.GameInfo) ~= "table" or type(deps.GameInfo.getDeflectCD) ~= "function" or type(deps.GameInfo.getBall) ~= "function" or type(deps.GameInfo.getSnapshot) ~= "function" or type(deps.GameInfo.isSnapshotValid) ~= "function" or type(deps.Utils) ~= "table" or type(deps.Utils.now) ~= "function" or type(deps.Utils.apiVersion) ~= "function" or type(deps.Utils.isFiniteNumber) ~= "function" or type(deps.Utils.getConfig) ~= "function" or type(deps.Utils.getLocalPlayer) ~= "function" or type(deps.Utils.getWorkspace) ~= "function" or type(deps.Utils.getRunService) ~= "function" or type(deps.Utils.trackCharacter) ~= "function" or type(deps.Utils.untrackCharacter) ~= "function" or type(deps.Utils.trackGlobal) ~= "function" or type(deps.Utils.isActive) ~= "function" or type(deps.Utils.isSpamActive) ~= "function" or type(deps.Utils.warn) ~= "function" then
		return false, "dependência ausente: Remote.fireParry, GameInfo, Utils ou uma API obrigatória"
	end
	Remote = deps.Remote
	GameInfo = deps.GameInfo
	Utils = deps.Utils
	local localPlayer = Utils.getLocalPlayer()
	Runtime.localUserId = localPlayer and localPlayer.UserId or -1
	HitboxState.handler = handleHitbox
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
	Runtime.generation = Runtime.generation + 1
	Runtime.bound = false
	disconnectConnections()
	resetState()
end
function AutoParry.onBallSync(data)
	onBallSync(data)
end
function AutoParry.getParryRadius(time)
	local radius = computeParryRadius(time)
	Runtime.parryRadius = radius
	return radius
end
function AutoParry.getDeflectionWindow(speed)
	return computeDeflectionWindow(speed)
end
function AutoParry.getPingOneWay()
	return math.clamp(Runtime.smoothPing * 0.5, Tuning.PING_FLOOR, Tuning.PING_CAP)
end
function AutoParry.getStatus()
	return {
		schema = Utils.apiVersion(),
		phase = Runtime.phase,
		bound = Runtime.bound == true,
		resilienceStack = Resilience.stack,
		parryRadius = computeParryRadius(now()),
		deflectionWindow = Runtime.deflectionWindow,
		ping = Runtime.smoothPing,
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
