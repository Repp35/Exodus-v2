-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
	RETURN_WIN_LO = 0.090,
	RETURN_WIN_MIN_FACTOR = 0.50,
	RETURN_SPD_LO = 60,
	RETURN_SPD_HI = 600,
	PING_FACTOR = 0.3,
	DEACT_OUT_HI = 0.100,
	DEACT_MIN_FACTOR = 0.50,
	FASTPATH_RADIUS_FACTOR = 0.35,
	RALLY_TIMEOUT = 0.200,
	DEACT_RADIUS_EXTRA_WINDOW = 0.100,
	ACT_RADIUS_EXTRA_WINDOW = 0.200,
	MIN_EVAL_INTERVAL = 1 / 120,
}

-- runtime
local R = {
	generation = 0,
	bound = false,
	active = false,
	phase = "detached",
	boundRoot = nil,
	localUserId = nil,
	lastTarget = -1,
	clashPartnerId = -1,
	lastSpeed = 0,
	parryRadius = 0,
	lostMeAt = 0,
	returnPending = false,
	fastpathPending = false,
	outSinceAt = 0,
	wasMeTarget = nil,
	lastEvalAt = 0,
	connections = {},
	lastGate = "none",
}

-- helpers
local function normalizeTarget(target)
	if type(target) == "string" then
		target = tonumber(target)
	end
	if type(target) ~= "number" then
		return nil
	end
	return target
end
local function getNow()
	if not Utils or type(Utils.now) ~= "function" then
		return 0
	end
	local ok, now = pcall(Utils.now)
	if not ok then
		return 0
	end
	return tonumber(now) or 0
end
local function getPingOneWay()
	if not AutoParry or type(AutoParry.getPingOneWay) ~= "function" then
		return 0
	end
	local ok, ping = pcall(AutoParry.getPingOneWay)
	if not ok then
		return 0
	end
	ping = tonumber(ping) or 0
	return math.max(ping, 0)
end
local function getRootPosition()
	local root = R.boundRoot
	if not (root and root.Parent) then
		return nil
	end
	local ok, position = pcall(function()
		return root.Position
	end)
	if not (ok and typeof(position) == "Vector3") then
		return nil
	end
	return position
end
local function getSnapshotPosition(snapshot)
	if type(snapshot) ~= "table" then
		return nil
	end
	local position = snapshot.position
	if typeof(position) ~= "Vector3" then
		return nil
	end
	return position
end
local function lerp(speed, lo, hi, spdLo, spdHi)
	speed = tonumber(speed) or 0
	if spdHi <= spdLo then
		return lo
	end
	local alpha = math.clamp((speed - spdLo) / (spdHi - spdLo), 0, 1)
	return lo + (hi - lo) * alpha
end
local function returnWindow(speed)
	local base = lerp(speed, T.RETURN_WIN_LO, T.RETURN_WIN_LO * T.RETURN_WIN_MIN_FACTOR, T.RETURN_SPD_LO, T.RETURN_SPD_HI)
	local window = base + getPingOneWay() * T.PING_FACTOR
	return math.max(window, 0)
end
local function deactOutWindow(speed)
	return lerp(speed, T.DEACT_OUT_HI, T.DEACT_OUT_HI * T.DEACT_MIN_FACTOR, T.RETURN_SPD_LO, T.RETURN_SPD_HI)
end
local function clearReturnState()
	R.lostMeAt = 0
	R.returnPending = false
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
	R.outSinceAt = 0
	if active then
		R.clashPartnerId = R.lastTarget
	else
		R.clashPartnerId = -1
	end
	if Utils and type(Utils.setAutoSpamActive) == "function" then
		pcall(Utils.setAutoSpamActive, active)
	end
	setPhase(active and "active" or "idle", reason)
end
local function resetTargetState()
	R.lastTarget = -1
	R.clashPartnerId = -1
	R.lostMeAt = 0
	R.returnPending = false
	R.fastpathPending = false
	R.outSinceAt = 0
	R.wasMeTarget = nil
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
local function resetRuntime(reason)
	R.generation = R.generation + 1
	if R.active then
		setActive(false, reason or "reset")
	end
	disconnectConnections()
	R.bound = false
	R.boundRoot = nil
	R.lastSpeed = 0
	R.parryRadius = 0
	R.lastEvalAt = 0
	R.lastGate = "detached"
	resetTargetState()
	setPhase("detached", reason or "reset")
end

-- rally
local function rallyCheck(data)
	if not R.active then
		return true
	end
	if type(data) ~= "table" then
		return true
	end
	local novoTarget = normalizeTarget(data.TargetPlayerID)
	if not novoTarget then
		return true
	end
	if novoTarget == R.localUserId then
		return true
	end
	local realPosition = data.RealPosition
	if typeof(realPosition) ~= "Vector3" then
		return true
	end
	local speed = tonumber(data.Speed) or 0
	if speed <= 0 then
		setActive(false, "rally_invalid_speed")
		clearReturnState()
		return false
	end
	if not Utils or type(Utils.getPlayers) ~= "function" then
		return true
	end
	local okPlayers, Players = pcall(Utils.getPlayers)
	if not okPlayers or not Players then
		return true
	end
	local okPlayer, player = pcall(Players.GetPlayerByUserId, Players, novoTarget)
	if not okPlayer or not player then
		return true
	end
	local character = player.Character
	if not (character and character.Parent) then
		return true
	end
	local targetRoot = character:FindFirstChild("HumanoidRootPart")
	if not (targetRoot and targetRoot.Parent) then
		return true
	end
	local okTargetPos, novoTargetPos = pcall(function()
		return targetRoot.Position
	end)
	if not (okTargetPos and typeof(novoTargetPos) == "Vector3") then
		return true
	end
	local rootPos = getRootPosition()
	if not rootPos then
		return true
	end
	local tempoIda = (realPosition - novoTargetPos).Magnitude / speed
	local tempoVolta = (novoTargetPos - rootPos).Magnitude / speed
	local tempoTotal = tempoIda + tempoVolta
	if tempoTotal > T.RALLY_TIMEOUT then
		setActive(false, "rally_too_far")
		clearReturnState()
		return false
	end
	R.clashPartnerId = novoTarget
	return true
end

-- activation
local function shouldActivate(snapshot)
	if not (snapshot and snapshot.ball and snapshot.ball.Parent) then
		R.lastGate = "no_ball"
		return false
	end
	local rootPos = getRootPosition()
	if not rootPos then
		R.lastGate = "no_root"
		return false
	end
	if snapshot.targeted ~= true then
		R.lastGate = "target_not_me"
		return false
	end
	local position = getSnapshotPosition(snapshot)
	if not position then
		R.lastGate = "no_position"
		return false
	end
	local parryRadius = math.max(tonumber(R.parryRadius) or 0, 0)
	if parryRadius <= 0 then
		R.lastGate = "no_effective_radius"
		return false
	end
	local effectiveRadius = parryRadius
		+ R.lastSpeed * T.ACT_RADIUS_EXTRA_WINDOW
	local distance = (rootPos - position).Magnitude
	if distance > effectiveRadius then
		R.lastGate = "outside_effective_radius"
		return false
	end
	R.lastGate = "activation_ready"
	return true
end
local function tryReturnActivate(snapshot)
	if not R.returnPending then
		return false
	end
	if not shouldActivate(snapshot) then
		return false
	end
	R.returnPending = false
	R.lostMeAt = 0
	return true
end
local function tryFastpathActivate(snapshot)
	if not R.fastpathPending then
		return false
	end
	R.fastpathPending = false
	if not shouldActivate(snapshot) then
		return false
	end
	return true
end

-- deactivation
local function shouldDeactivate(t, snapshot)
	if snapshot and snapshot.targeted == true then
		R.outSinceAt = 0
		return false
	end
	local rootPos = getRootPosition()
	local position = getSnapshotPosition(snapshot)
	if not (rootPos and position) then
		R.outSinceAt = 0
		return false
	end
	local parryRadius = math.max(tonumber(R.parryRadius) or 0, 0)
	if parryRadius <= 0 then
		R.outSinceAt = 0
		return false
	end
	local speed = math.max(tonumber(R.lastSpeed) or 0, 0)
	local distance = (rootPos - position).Magnitude
	local deactRadius = parryRadius + speed * T.DEACT_RADIUS_EXTRA_WINDOW
	if distance <= deactRadius then
		R.outSinceAt = 0
		return false
	end
	if R.outSinceAt <= 0 then
		R.outSinceAt = t
		return false
	end
	local elapsed = t - R.outSinceAt
	if elapsed < 0 then
		R.outSinceAt = t
		return false
	end
	return elapsed >= deactOutWindow(speed)
end

-- main evaluation
local function evaluateClash(t, snapshot)
	if not (R.boundRoot and R.boundRoot.Parent) then
		return
	end
	if not (snapshot and snapshot.ball and snapshot.ball.Parent) then
		return
	end
	R.lastSpeed = math.max(tonumber(snapshot.speed) or 0, 0)
	if AutoParry and type(AutoParry.getParryRadius) == "function" then
		local ok, radius = pcall(AutoParry.getParryRadius, R.lastSpeed, t)
		if ok then
			radius = tonumber(radius)
			if radius and radius >= 0 then
				R.parryRadius = radius
			end
		end
	end
	if R.active then
		if shouldDeactivate(t, snapshot) then
			setActive(false, "target_deactivated")
			clearReturnState()
			R.fastpathPending = false
		end
		return
	end
	if tryFastpathActivate(snapshot) then
		setActive(true, "sync_target_instant")
		clearReturnState()
		return
	end
	if tryReturnActivate(snapshot) then
		setActive(true, "activated")
		clearReturnState()
		return
	end
end

-- character
local function bindCharacter(character)
	resetRuntime("rebind")
	local generation = R.generation
	if not (character and character.Parent) then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
	if not (generation == R.generation and root and root.Parent) then
		return false
	end
	R.boundRoot = root
	R.lastGate = "waiting_for_character"
	local heartbeat = Utils.getRunService().Heartbeat:Connect(function()
		if generation ~= R.generation then
			return
		end
		if not (character.Parent and root.Parent) then
			return
		end
		if Utils.isManualSpamActive() then
			if R.active then
				setActive(false, "manual_spam")
			end
			resetTargetState()
			R.lastGate = "manual_spam"
			return
		end
		if not Utils.isActive() then
			if R.active then
				setActive(false, "hub_inactive")
			end
			resetTargetState()
			R.lastGate = "hub_inactive"
			return
		end
		local config = Utils.getConfig()
		if not (config and config.AutoClash) then
			if R.active then
				setActive(false, "hub_disabled")
			end
			resetTargetState()
			R.lastGate = "hub_disabled"
			return
		end
		local t = getNow()
		if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
			return
		end
		R.lastEvalAt = t
		local snapshot = GameInfo.getSnapshot(R.lastTarget, t)
		if not GameInfo.isSnapshotValid(snapshot, t) then
			return
		end
		local target = normalizeTarget(snapshot.targetId)
		if target then
			R.lastTarget = target
		end
		evaluateClash(t, snapshot)
	end)
	R.connections[#R.connections + 1] = heartbeat
	Utils.trackCharacter(heartbeat)
	local ancestry = character.AncestryChanged:Connect(function(_, parent)
		if parent then
			return
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
	if not (deps and deps.AutoParry and type(deps.AutoParry.getParryRadius) == "function" and type(deps.AutoParry.getPingOneWay) == "function" and deps.GameInfo and type(deps.GameInfo.getSnapshot) == "function" and type(deps.GameInfo.isSnapshotValid) == "function" and deps.Utils and type(deps.Utils.now) == "function" and type(deps.Utils.getConfig) == "function" and type(deps.Utils.getRunService) == "function" and type(deps.Utils.recordTransition) == "function" and type(deps.Utils.setAutoSpamActive) == "function" and type(deps.Utils.trackCharacter) == "function" and type(deps.Utils.untrackCharacter) == "function" and type(deps.Utils.isActive) == "function" and type(deps.Utils.isManualSpamActive) == "function" and type(deps.Utils.getLocalPlayer) == "function" and type(deps.Utils.apiVersion) == "function") then
		return false
	end
	if Utils then
		resetRuntime("setup")
	end
	AutoParry = deps.AutoParry
	GameInfo = deps.GameInfo
	Utils = deps.Utils
	local player = Utils.getLocalPlayer()
	R.localUserId = player and player.UserId or nil
	R.generation = 0
	R.bound = false
	R.active = false
	R.phase = "detached"
	R.boundRoot = nil
	R.lastTarget = -1
	R.clashPartnerId = -1
	R.lastSpeed = 0
	R.parryRadius = 0
	R.lostMeAt = 0
	R.returnPending = false
	R.fastpathPending = false
	R.outSinceAt = 0
	R.wasMeTarget = nil
	R.lastEvalAt = 0
	R.connections = {}
	R.lastGate = "none"
	return true
end
function AutoClash.bindCharacter(character)
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
	if type(data) ~= "table" or not Utils or not R.localUserId then
		return
	end
	if data.Teleported == true then
		if R.active then
			setActive(false, "teleported")
		end
		resetTargetState()
		R.lastGate = "teleported"
		return
	end
	local target = normalizeTarget(data.TargetPlayerID)
	if not target then
		if R.active then
			setActive(false, "invalid_target")
		end
		resetTargetState()
		R.lastGate = "invalid_target"
		return
	end
	R.lastTarget = target
	local isMe = target == R.localUserId
	if R.wasMeTarget == nil then
		R.wasMeTarget = isMe
		R.lastGate = isMe and "initial_me" or "initial_not_me"
		return
	end
	local previousTarget = R.wasMeTarget
	if previousTarget and not isMe then
		if R.active then
			local rallyAccepted = rallyCheck(data)
			if not rallyAccepted then
				R.wasMeTarget = isMe
				return
			end
		end
		R.lostMeAt = getNow()
		R.returnPending = false
		R.fastpathPending = false
		R.lastGate = "target_lost"
	elseif not previousTarget and isMe then
		local rootPos = getRootPosition()
		local realPosition = data.RealPosition
		local speed = math.max(tonumber(data.Speed) or 0, 0)
		if rootPos and typeof(realPosition) == "Vector3" and speed > 0 and R.parryRadius > 0 then
			local dist = (rootPos - realPosition).Magnitude
			if dist <= R.parryRadius * T.FASTPATH_RADIUS_FACTOR then
				R.fastpathPending = true
				R.lastGate = "fastpath_pending"
			end
		end
		local lostAt = R.lostMeAt
		if lostAt > 0 then
			local now = getNow()
			local elapsed = now - lostAt
			local window = returnWindow(R.lastSpeed)
			if elapsed >= 0 and elapsed <= window then
				R.returnPending = true
				R.lastGate = "target_return"
			else
				R.lostMeAt = 0
				R.returnPending = false
				if not R.fastpathPending then
					R.lastGate = "return_too_late"
				end
			end
		else
			R.returnPending = false
			if not R.fastpathPending then
				R.lastGate = "return_without_loss"
			end
		end
	end
	R.wasMeTarget = isMe
end
function AutoClash.isActive()
	return R.active == true
end
function AutoClash.getStatus()
	local schema
	if Utils and type(Utils.apiVersion) == "function" then
		local ok, value = pcall(Utils.apiVersion)
		if ok then
			schema = value
		end
	end
	return {
		schema = schema,
		phase = R.phase,
		bound = R.bound == true,
		active = R.active == true,
		parryRadius = R.parryRadius,
		lastTarget = R.lastTarget,
		clashPartnerId = R.clashPartnerId,
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
