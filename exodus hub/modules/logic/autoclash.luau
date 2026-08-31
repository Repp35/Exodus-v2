-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
	RETURN_TIME_START = 0.100,
	RETURN_TIME_END = 0.040,
	RETURN_SPEED_START = 60,
	RETURN_SPEED_END = 600,
	PING_FACTOR = 0.3,
	RADIUS_LEAD_TIME = 0.250,
	DEACT_RETURN_FACTOR = 1.3,
	MIN_EVAL_INTERVAL = 1 / 120,
	TELEPORT_GRACE_TIME = 0.20,
}

-- runtime
local R = {
	generation = 0,
	bound = false,
	active = false,
	phase = "detached",
	root = nil,
	localUserId = nil,
	targetId = -1,
	speed = 0,
	parryRadius = 0,
	activationRadius = 0,
	wasTarget = false,
	targetLostAt = 0,
	targetLostSpeed = 0,
	returnPending = false,
	outsideParryAt = 0,
	lastEvalAt = 0,
	teleportLockUntil = 0,
	connections = {},
	lastGate = "none",
}

-- helpers
local function lerp(a, b, alpha)
	return a + (b - a) * alpha
end
local function now()
	return Utils and Utils.now() or os.clock()
end
local function getPing()
	if not AutoParry then
		return 0
	end
	local ok, value = pcall(AutoParry.getPingOneWay)
	return ok and (tonumber(value) or 0) or 0
end
local function getReturnTime(speed)
	speed = tonumber(speed) or 0
	local span = T.RETURN_SPEED_END - T.RETURN_SPEED_START
	local alpha = 0
	if span > 0 then
		alpha = math.clamp((speed - T.RETURN_SPEED_START) / span, 0, 1)
	end
	return lerp(T.RETURN_TIME_START, T.RETURN_TIME_END, alpha) + getPing() * T.PING_FACTOR
end
local function getDeactivationTime(speed)
	return getReturnTime(speed) * T.DEACT_RETURN_FACTOR
end
local function setPhase(phase, reason)
	if R.phase == phase then
		return
	end
	local previous = R.phase
	R.phase = phase
	if Utils and type(Utils.recordTransition) == "function" then
		pcall(Utils.recordTransition, "AutoClash", previous, phase, reason)
	end
end
local function setActive(active, reason)
	active = active == true
	if R.active == active then
		return
	end
	R.active = active
	if Utils and type(Utils.setAutoSpamActive) == "function" then
		pcall(Utils.setAutoSpamActive, active)
	end
	setPhase(active and "active" or "idle", reason)
end
local function disconnectConnections()
	for i = #R.connections, 1, -1 do
		local connection = R.connections[i]
		R.connections[i] = nil
		if Utils and type(Utils.untrackCharacter) == "function" then
			pcall(Utils.untrackCharacter, connection)
		end
		pcall(function()
			connection:Disconnect()
		end)
	end
end
local function clearTargetHistory()
	R.wasTarget = false
	R.targetLostAt = 0
	R.targetLostSpeed = 0
	R.returnPending = false
end
local function clearOutsideTimer()
	R.outsideParryAt = 0
end
local function resetRuntime(reason)
	R.generation += 1
	if R.active then
		setActive(false, reason or "reset")
	end
	disconnectConnections()
	R.bound = false
	R.root = nil
	R.targetId = -1
	R.speed = 0
	R.parryRadius = 0
	R.activationRadius = 0
	clearTargetHistory()
	clearOutsideTimer()
	R.lastEvalAt = 0
	R.teleportLockUntil = 0
	R.lastGate = "detached"
	setPhase("detached", reason or "reset")
end
local function isCharacterValid(character, root)
	return character and character.Parent and root and root.Parent
end
local function isBallValid(snapshot)
	return snapshot and snapshot.ball and snapshot.ball.Parent
end
local function isConfigEnabled()
	if not Utils or type(Utils.getConfig) ~= "function" then
		return false
	end
	local config = Utils.getConfig()
	return type(config) == "table" and config.AutoClash == true
end
local function getBallDistance(snapshot)
	if not isBallValid(snapshot) then
		return nil
	end
	if not R.root or not R.root.Parent then
		return nil
	end
	local ballPosition = snapshot.position
	local rootPosition = R.root.Position
	if not ballPosition or not rootPosition then
		return nil
	end
	return (ballPosition - rootPosition).Magnitude
end
local function updateBallState(snapshot)
	R.speed = tonumber(snapshot.speed) or 0
	local radius = 8
	local ok, result = pcall(AutoParry.getParryRadius, now(), R.speed)
	if ok and tonumber(result) then
		radius = result
	end
	R.parryRadius = radius
	R.activationRadius = radius + R.speed * T.RADIUS_LEAD_TIME
end
local function gateBallValid(_, snapshot)
	if not isBallValid(snapshot) then
		return false, "invalid_ball"
	end
	local distance = getBallDistance(snapshot)
	if not distance then
		return false, "invalid_distance"
	end
	return true
end
local function gateIsTargeted(_, snapshot)
	if snapshot.targeted ~= true then
		return false, "not_targeted"
	end
	return true
end
local function gateInsideActivationRadius(_, snapshot)
	local distance = getBallDistance(snapshot)
	if not distance then
		return false, "invalid_distance"
	end
	if distance <= R.activationRadius then
		return true
	end
	return false, "outside_activation_radius"
end
local function gateReturnPending(_, _)
	if not R.returnPending then
		return false, "no_return_pending"
	end
	return true
end
local ACTIVATION_GATES = {
	gateBallValid,
	gateIsTargeted,
	gateReturnPending,
	gateInsideActivationRadius,
}
local DEACTIVATION_GATES = {
	{
		name = "inside_parry",
		run = function(_, snapshot)
			local distance = getBallDistance(snapshot)
			if distance and distance <= R.parryRadius then
				clearOutsideTimer()
				return false, "inside_parry_radius"
			end
			return true
		end,
	},
	{
		name = "outside_started",
		run = function(t, _)
			if R.outsideParryAt <= 0 then
				R.outsideParryAt = t
			end
			return true
		end,
	},
	{
		name = "outside_timeout",
		run = function(t, _)
			local outsideTime = t - R.outsideParryAt
			if outsideTime < getDeactivationTime(R.speed) then
				return false, "outside_waiting"
			end
			return true
		end,
	},
}
local function checkDeactivation(t, snapshot)
	if not R.active then
		return false, "inactive"
	end
	if not isBallValid(snapshot) then
		clearOutsideTimer()
		R.lastGate = "deact_invalid_ball"
		return false
	end
	for _, gate in ipairs(DEACTIVATION_GATES) do
		local passed, gateName = gate.run(t, snapshot)
		if not passed then
			R.lastGate = "deact_" .. gateName
			return false
		end
	end
	R.lastGate = "deact_outside_timeout"
	return true
end
local function checkActivation(t, snapshot)
	if not isBallValid(snapshot) then
		R.lastGate = "act_invalid_ball"
		return false
	end
	for _, gate in ipairs(ACTIVATION_GATES) do
		local passed, gateName = gate(t, snapshot)
		if not passed then
			R.lastGate = "act_" .. gateName
			return false
		end
	end
	R.lastGate = "act_target_return"
	return true
end
local function evaluate(t, snapshot)
	if not R.root or not R.root.Parent then
		return
	end
	if not isBallValid(snapshot) then
		return
	end
	updateBallState(snapshot)
	if R.active then
		if checkDeactivation(t, snapshot) then
			setActive(false, "outside_parry_timeout")
			clearOutsideTimer()
			clearTargetHistory()
		end
		return
	end
	if checkActivation(t, snapshot) then
		clearTargetHistory()
		setActive(true, "activated")
	end
end

-- character
local function bindCharacter(character)
	resetRuntime("rebind")
	if not character or not character.Parent then
		return false
	end
	local generation = R.generation
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
	if generation ~= R.generation or not root or not root.Parent then
		return false
	end
	R.root = root
	R.lastGate = "waiting_for_character"
	local heartbeat
	heartbeat = Utils.getRunService().Heartbeat:Connect(function()
		if generation ~= R.generation then
			return
		end
		if not isCharacterValid(character, root) then
			if R.active then
				setActive(false, "death")
			end
			resetRuntime("character_invalid")
			return
		end
		local t = now()
		local snapshot = GameInfo.getSnapshot(R.targetId, t)
		if snapshot and GameInfo.isSnapshotValid(snapshot, t) then
			local snapshotTarget = snapshot.targetId
			if type(snapshotTarget) == "number" then
				R.targetId = snapshotTarget
			elseif type(snapshotTarget) == "string" then
				R.targetId = tonumber(snapshotTarget) or R.targetId
			end
		end
		if Utils.isActive() ~= true then
			if R.active then
				setActive(false, "hub_inactive")
			end
			clearTargetHistory()
			clearOutsideTimer()
			R.lastGate = "hub_inactive"
			return
		end
		if not isConfigEnabled() then
			if R.active then
				setActive(false, "hub_disabled")
			end
			clearTargetHistory()
			clearOutsideTimer()
			R.lastGate = "hub_disabled"
			return
		end
		if Utils.isManualSpamActive() then
			if R.active then
				setActive(false, "manual_spam")
			end
			clearTargetHistory()
			clearOutsideTimer()
			R.lastGate = "manual_spam"
			return
		end
		if t < R.teleportLockUntil then
			if R.active then
				setActive(false, "teleport_grace")
			end
			clearTargetHistory()
			clearOutsideTimer()
			R.lastGate = "teleport_grace"
			return
		end
		if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
			return
		end
		R.lastEvalAt = t
		if not snapshot or not GameInfo.isSnapshotValid(snapshot, t) then
			R.lastGate = "invalid_snapshot"
			return
		end
		evaluate(t, snapshot)
	end)
	R.connections[#R.connections + 1] = heartbeat
	Utils.trackCharacter(heartbeat)
	local ancestry = character.AncestryChanged:Connect(function(_, parent)
		if parent or generation ~= R.generation then
			return
		end
		if R.active then
			setActive(false, "death")
		end
		resetRuntime("character_removed")
		R.lastGate = "character_removed"
	end)
	R.connections[#R.connections + 1] = ancestry
	Utils.trackCharacter(ancestry)
	R.bound = true
	setPhase("waiting", "character_bound")
	return true
end

-- setup
function AutoClash.setup(deps)
	if type(deps) ~= "table" or not deps.AutoParry or not deps.GameInfo or not deps.Utils then
		return false
	end
	local ap, gi, u = deps.AutoParry, deps.GameInfo, deps.Utils
	local required = {
		{ ap, "getParryRadius" },
		{ ap, "getPingOneWay" },
		{ gi, "getSnapshot" },
		{ gi, "isSnapshotValid" },
		{ u, "now" },
		{ u, "getConfig" },
		{ u, "getRunService" },
		{ u, "recordTransition" },
		{ u, "setAutoSpamActive" },
		{ u, "trackCharacter" },
		{ u, "untrackCharacter" },
		{ u, "isActive" },
		{ u, "isManualSpamActive" },
		{ u, "getLocalPlayer" },
		{ u, "apiVersion" },
	}
	for i = 1, #required do
		if type(required[i][1][required[i][2]]) ~= "function" then
			return false
		end
	end
	if Utils then
		resetRuntime("setup")
	end
	AutoParry = ap
	GameInfo = gi
	Utils = u
	local player = Utils.getLocalPlayer()
	R.localUserId = player and player.UserId or nil
	R.generation = 0
	R.bound = false
	R.active = false
	R.phase = "detached"
	R.root = nil
	R.targetId = -1
	R.speed = 0
	R.parryRadius = 0
	R.activationRadius = 0
	R.wasTarget = false
	R.targetLostAt = 0
	R.targetLostSpeed = 0
	R.returnPending = false
	R.outsideParryAt = 0
	R.lastEvalAt = 0
	R.teleportLockUntil = 0
	R.connections = {}
	R.lastGate = "none"
	return true
end

-- api
function AutoClash.bindCharacter(character)
	if not Utils then
		return false
	end
	return bindCharacter(character)
end
function AutoClash.detachCharacter()
	resetRuntime("detach")
end
function AutoClash.teardown()
	resetRuntime("teardown")
	AutoParry = nil
	GameInfo = nil
	Utils = nil
end
function AutoClash.onBallSync(data)
	if type(data) ~= "table" or not Utils then
		return
	end
	local t = now()
	if data.Teleported == true then
		R.teleportLockUntil = t + T.TELEPORT_GRACE_TIME
		clearTargetHistory()
		clearOutsideTimer()
		R.lastGate = "teleport"
		if R.active then
			setActive(false, "teleport_grace")
		end
		return
	end
	local newTargetId
	local target = data.TargetPlayerID
	if type(target) == "number" then
		newTargetId = target
	elseif type(target) == "string" then
		newTargetId = tonumber(target)
	end
	if not newTargetId then
		R.targetId = -1
		clearTargetHistory()
		clearOutsideTimer()
		R.lastGate = "invalid_target"
		return
	end
	if not R.localUserId then
		R.targetId = newTargetId
		return
	end
	local isTarget = newTargetId == R.localUserId
	local wasTarget = R.wasTarget
	R.targetId = newTargetId
	if wasTarget and not isTarget then
		R.targetLostAt = t
		R.targetLostSpeed = R.speed
		R.returnPending = false
	elseif not wasTarget and isTarget then
		if R.targetLostAt > 0 then
			local elapsed = t - R.targetLostAt
			local returnTime = getReturnTime(R.targetLostSpeed > 0 and R.targetLostSpeed or R.speed)
			if elapsed >= 0 and elapsed <= returnTime then
				R.returnPending = true
			else
				R.targetLostAt = 0
				R.targetLostSpeed = 0
				R.returnPending = false
			end
		end
	end
	R.wasTarget = isTarget
end
function AutoClash.isActive()
	return R.active == true
end
function AutoClash.getStatus()
	return {
		schema = Utils and Utils.apiVersion() or nil,
		phase = R.phase,
		bound = R.bound == true,
		active = R.active == true,
		parryRadius = R.parryRadius,
		activationRadius = R.activationRadius,
		targetId = R.targetId,
		returnPending = R.returnPending,
		lastGate = R.lastGate,
	}
end
AutoClash.__contract = {
	requires = {
		AutoParry = "autoparry",
		GameInfo = "gameinfo",
		Utils = "utils",
	},
	onBallSync = true,
	bindCharacter = true,
}

return AutoClash
