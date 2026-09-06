-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
	-- activation
	RETURN_WIN_LO = 0.10,
	RETURN_WIN_MIN_FACTOR = 0.10,
	RETURN_SPD_LO = 60,
	RETURN_SPD_HI = 600,
	PING_FACTOR = 0.3,
	ACT_RADIUS_EXTRA_WINDOW = 0.150,
	ACT_INSTANT_RADIUS_FACTOR = 0.20,
	REACTIVATE_COOLDOWN = 0.25,

	-- activation deactivation lock
	ACT_DEACT_LOCK_RADIUS_FACTOR = 0.60,
	ACT_DEACT_LOCK_TIME = 0.050,

	-- deactivation
	DEACT_TRAVEL_MAX_LO = 0.090,
	DEACT_TRAVEL_MAX_MIN_FACTOR = 0.10,
	DEACT_TRAVEL_SPD_LO = 60,
	DEACT_TRAVEL_SPD_HI = 600,
	DEACT_TRAVEL_RADIUS_FACTOR = 1.10,
	DEACT_TRAVEL_HOLD = 0.015,
	DEACT_TRAVEL_HYSTERESIS = 1.20,
	DEACT_RADIUS_FACTOR = 1.65,
	DEACT_RADIUS_EXTRA_WINDOW = 0.090,
	DEACT_OUT_WINDOW = 0.100,

	-- system
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
	outSince = 0,
	travelSince = 0,
	wasMeTarget = nil,

	lastEvalAt = 0,
	reactivateBlockedUntil = 0,
	activationDeactLockedUntil = 0,

	connections = {},
	lastGate = "none",
}

-- helpers
local function normalizeTarget(target)
	if type(target) == "string" then
		target = tonumber(target)
	end

	return type(target) == "number" and target or nil
end

local function now()
	if not Utils or type(Utils.now) ~= "function" then
		return 0
	end

	local ok, value = pcall(Utils.now)
	return ok and tonumber(value) or 0
end

local function pingOneWay()
	if not AutoParry or type(AutoParry.getPingOneWay) ~= "function" then
		return 0
	end

	local ok, value = pcall(AutoParry.getPingOneWay)

	return ok and math.max(tonumber(value) or 0, 0) or 0
end

local function rootPosition()
	local root = R.boundRoot

	if not (root and root.Parent) then
		return nil
	end

	local ok, position = pcall(function()
		return root.Position
	end)

	return ok and typeof(position) == "Vector3" and position or nil
end

local function snapshotPosition(snapshot)
	local position = snapshot and snapshot.position
	return typeof(position) == "Vector3" and position or nil
end

local function lerp(speed, lo, hi, speedLo, speedHi)
	if speedHi <= speedLo then
		return lo
	end

	local alpha = math.clamp(
		(tonumber(speed) or 0 - speedLo) / (speedHi - speedLo),
		0,
		1
	)

	return lo + (hi - lo) * alpha
end

local function returnWindow(speed)
	local base = lerp(
		speed,
		T.RETURN_WIN_LO,
		T.RETURN_WIN_LO * T.RETURN_WIN_MIN_FACTOR,
		T.RETURN_SPD_LO,
		T.RETURN_SPD_HI
	)

	return math.max(base + pingOneWay() * T.PING_FACTOR, 0)
end

local function resetTargetState()
	R.lastTarget = -1
	R.clashPartnerId = -1
	R.wasMeTarget = nil

	R.lostMeAt = 0
	R.returnPending = false

	R.outSince = 0
	R.travelSince = 0
end

local function resetDeactivationState()
	R.outSince = 0
	R.travelSince = 0
end

local function setPhase(phase, reason)
	if R.phase == phase then
		return
	end

	local previous = R.phase
	R.phase = phase

	if Utils and type(Utils.recordTransition) == "function" then
		pcall(
			Utils.recordTransition,
			"AutoClash",
			previous,
			phase,
			reason
		)
	end
end

local function setActive(active, reason, snapshot)
	active = active == true

	if R.active == active then
		return
	end

	R.active = active
	resetDeactivationState()

	local t = now()

	if active then
		if R.clashPartnerId == -1
			and R.lastTarget ~= R.localUserId
		then
			R.clashPartnerId = R.lastTarget
		end

		local root = rootPosition()
		local position = snapshotPosition(snapshot)
		local radius = R.parryRadius

		if root and position and radius > 0 then
			if (root - position).Magnitude
				<= radius * T.ACT_DEACT_LOCK_RADIUS_FACTOR
			then
				R.activationDeactLockedUntil =
					t + T.ACT_DEACT_LOCK_TIME
			else
				R.activationDeactLockedUntil = 0
			end
		else
			R.activationDeactLockedUntil = 0
		end
	else
		R.clashPartnerId = -1
		R.reactivateBlockedUntil =
			t + T.REACTIVATE_COOLDOWN

		R.activationDeactLockedUntil = 0

		if reason == "target_deactivated" then
			R.lostMeAt = 0
			R.returnPending = false
		end
	end

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
	R.reactivateBlockedUntil = 0
	R.activationDeactLockedUntil = 0

	resetTargetState()

	R.lastGate = "detached"
	setPhase("detached", reason or "reset")
end

-- target / rally
local function rallyCheck(data)
	if not R.active or type(data) ~= "table" then
		return true
	end

	local target = normalizeTarget(data.TargetPlayerID)

	if not target
		or target == R.localUserId
		or target == R.clashPartnerId
	then
		return true
	end

	local root = rootPosition()
	local position = data.RealPosition

	if not root or typeof(position) ~= "Vector3" then
		return true
	end

	local speed = math.max(
		R.lastSpeed,
		tonumber(data.Speed) or 0,
		0
	)

	local radius = R.parryRadius

	if radius <= 0 then
		return true
	end

	local effectiveRadius =
		radius + speed * T.ACT_RADIUS_EXTRA_WINDOW

	if (root - position).Magnitude > effectiveRadius then
		setActive(false, "rally_outside_effective_radius")

		R.lostMeAt = 0
		R.returnPending = false

		return false
	end

	R.clashPartnerId = target
	return true
end

-- activation
local function shouldActivate(snapshot)
	if not snapshot
		or not snapshot.ball
		or not snapshot.ball.Parent
	then
		R.lastGate = "no_ball"
		return false
	end

	local root = rootPosition()

	if not root then
		R.lastGate = "no_root"
		return false
	end

	if snapshot.targeted ~= true then
		R.lastGate = "target_not_me"
		return false
	end

	local position = snapshotPosition(snapshot)

	if not position then
		R.lastGate = "no_position"
		return false
	end

	local radius = R.parryRadius

	if radius <= 0 then
		R.lastGate = "no_effective_radius"
		return false
	end

	local effectiveRadius =
		radius + R.lastSpeed * T.ACT_RADIUS_EXTRA_WINDOW

	if (root - position).Magnitude > effectiveRadius then
		R.lastGate = "outside_effective_radius"
		return false
	end

	R.lastGate = "activation_ready"
	return true
end

local function canReactivate()
	if now() < R.reactivateBlockedUntil then
		R.lastGate = "reactivate_cooldown"
		return false
	end

	return true
end

local function tryReturnActivate(snapshot)
	if not R.returnPending or not canReactivate() then
		return false
	end

	local lostAt = R.lostMeAt

	if lostAt <= 0 then
		R.lostMeAt = 0
		R.returnPending = false
		R.lastGate = "return_without_loss"
		return false
	end

	local elapsed = now() - lostAt
	local window = returnWindow(R.lastSpeed)

	if elapsed < 0 or elapsed > window then
		R.lostMeAt = 0
		R.returnPending = false
		R.lastGate = "return_too_late"
		return false
	end

	return shouldActivate(snapshot)
end

-- deactivation
local function shouldDeactivate(t, snapshot)
	if t < R.activationDeactLockedUntil then
		R.lastGate = "deact_activation_lock"
		return false
	end

	local root = rootPosition()
	local position = snapshotPosition(snapshot)

	if not root or not position then
		return false
	end

	local radius = R.parryRadius

	if radius <= 0 then
		return false
	end

	local speed = R.lastSpeed
	local distance = (root - position).Magnitude

	-- travel-based deactivation
	if distance > radius and speed > 0 then
		local baseMax = lerp(
			speed,
			T.DEACT_TRAVEL_MAX_LO,
			T.DEACT_TRAVEL_MAX_LO
				* T.DEACT_TRAVEL_MAX_MIN_FACTOR,
			T.DEACT_TRAVEL_SPD_LO,
			T.DEACT_TRAVEL_SPD_HI
		)

		local radiusTime =
			(radius * T.DEACT_TRAVEL_RADIUS_FACTOR) / speed

		local radiusMax = lerp(
			speed,
			radiusTime,
			radiusTime * T.DEACT_TRAVEL_MAX_MIN_FACTOR,
			T.DEACT_TRAVEL_SPD_LO,
			T.DEACT_TRAVEL_SPD_HI
		)

		local travelMax = math.max(baseMax, radiusMax)

		if distance / speed
			> travelMax * T.DEACT_TRAVEL_HYSTERESIS
		then
			if R.travelSince <= 0 then
				R.travelSince = t
			end

			if t - R.travelSince >= T.DEACT_TRAVEL_HOLD then
				R.lastGate = "deact_travel"
				R.travelSince = 0
				return true
			end
		end
	end

	if distance <= radius * 0.85 then
		R.travelSince = 0
	end

	-- hard radius
	if distance > radius * T.DEACT_RADIUS_FACTOR then
		R.lastGate = "deact_radius_factor"
		return true
	end

	-- extra radius + hold window
	local deactOutRadius =
		radius + speed * T.DEACT_RADIUS_EXTRA_WINDOW

	if distance > deactOutRadius then
		if R.outSince <= 0 then
			R.outSince = t
		end

		if t - R.outSince >= T.DEACT_OUT_WINDOW then
			R.lastGate = "deact_out_window"
			return true
		end
	else
		R.outSince = 0
	end

	R.lastGate = "deact_none"
	return false
end

-- state update
local function updateParryState(t, snapshot)
	R.lastSpeed = math.max(
		tonumber(snapshot.speed) or 0,
		0
	)

	if AutoParry
		and type(AutoParry.getParryRadius) == "function"
	then
		local ok, radius = pcall(
			AutoParry.getParryRadius,
			R.lastSpeed,
			t
		)

		radius = ok and tonumber(radius)

		if radius and radius >= 0 then
			R.parryRadius = radius
		end
	end
end

-- main evaluation
local function evaluateClash(t, snapshot)
	if not R.boundRoot
		or not R.boundRoot.Parent
		or not snapshot
		or not snapshot.ball
		or not snapshot.ball.Parent
	then
		return
	end

	updateParryState(t, snapshot)

	if R.active then
		if shouldDeactivate(t, snapshot) then
			setActive(false, "target_deactivated")
		end
	elseif tryReturnActivate(snapshot) then
		R.lostMeAt = 0
		R.returnPending = false

		setActive(true, "activated", snapshot)
	end
end

-- heartbeat
local function heartbeatStep(generation, character, root)
	if generation ~= R.generation
		or not character.Parent
		or not root.Parent
	then
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

	local t = now()

	if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
		return
	end

	R.lastEvalAt = t

	local snapshot = GameInfo.getSnapshot(
		R.lastTarget,
		t
	)

	if not GameInfo.isSnapshotValid(snapshot, t) then
		return
	end

	local target = normalizeTarget(snapshot.targetId)

	if target then
		R.lastTarget = target
	end

	evaluateClash(t, snapshot)
end

-- character
local function bindCharacter(character)
	resetRuntime("rebind")

	local generation = R.generation

	if not (character and character.Parent) then
		return false
	end

	local root =
		character:FindFirstChild("HumanoidRootPart")
		or character:WaitForChild("HumanoidRootPart", 1)

	if not (
		generation == R.generation
		and root
		and root.Parent
	) then
		return false
	end

	R.boundRoot = root
	R.lastGate = "waiting_for_character"

	local heartbeat =
		Utils.getRunService().Heartbeat:Connect(function()
			heartbeatStep(
				generation,
				character,
				root
			)
		end)

	R.connections[#R.connections + 1] = heartbeat
	Utils.trackCharacter(heartbeat)

	local ancestry =
		character.AncestryChanged:Connect(function(_, parent)
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
	local required = {
		{ "AutoParry", "getParryRadius" },
		{ "AutoParry", "getPingOneWay" },
		{ "GameInfo", "getSnapshot" },
		{ "GameInfo", "isSnapshotValid" },
		{ "Utils", "now" },
		{ "Utils", "getConfig" },
		{ "Utils", "getRunService" },
		{ "Utils", "recordTransition" },
		{ "Utils", "setAutoSpamActive" },
		{ "Utils", "trackCharacter" },
		{ "Utils", "untrackCharacter" },
		{ "Utils", "isActive" },
		{ "Utils", "isManualSpamActive" },
		{ "Utils", "getLocalPlayer" },
		{ "Utils", "apiVersion" },
	}

	if not deps then
		return false
	end

	for _, requirement in ipairs(required) do
		local object = deps[requirement[1]]

		if not object
			or type(object[requirement[2]]) ~= "function"
		then
			return false
		end
	end

	if Utils then
		resetRuntime("setup")
	end

	AutoParry = deps.AutoParry
	GameInfo = deps.GameInfo
	Utils = deps.Utils

	local player = Utils.getLocalPlayer()

	R.localUserId =
		player and player.UserId or nil

	R.generation = 0
	R.bound = false
	R.active = false
	R.phase = "detached"
	R.boundRoot = nil
	R.lastSpeed = 0
	R.parryRadius = 0
	R.lastEvalAt = 0
	R.reactivateBlockedUntil = 0
	R.activationDeactLockedUntil = 0
	R.connections = {}

	resetTargetState()

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
	if type(data) ~= "table"
		or not Utils
		or not R.localUserId
	then
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

	local previousTargetId = R.lastTarget
	R.lastTarget = target

	local wasMe = R.wasMeTarget
	local isMe = target == R.localUserId

	if wasMe == nil then
		R.wasMeTarget = isMe
		R.lastGate = isMe and "initial_me" or "initial_not_me"
		return
	end

	-- lost target
	if wasMe and not isMe then
		if R.active then
			if not rallyCheck(data) then
				R.wasMeTarget = isMe
				return
			end
		else
			R.clashPartnerId = target
		end

		R.lostMeAt = now()
		R.returnPending = false
		R.lastGate = "target_lost"

	-- target returned
	elseif not wasMe and isMe then
		if previousTargetId ~= -1
			and previousTargetId ~= R.localUserId
		then
			R.clashPartnerId = previousTargetId
		end

		local root = rootPosition()
		local position = data.RealPosition
		local radius = R.parryRadius

		if root
			and typeof(position) == "Vector3"
			and radius > 0
		then
			if (root - position).Magnitude
				<= radius * T.ACT_INSTANT_RADIUS_FACTOR
			then
				R.clashPartnerId =
					previousTargetId ~= -1
					and previousTargetId
					or R.clashPartnerId

				setActive(true, "instant_activate")

				R.wasMeTarget = isMe
				return
			end
		end

		local lostAt = R.lostMeAt

		if lostAt > 0 then
			local elapsed = now() - lostAt
			local window = returnWindow(R.lastSpeed)

			if elapsed >= 0 and elapsed <= window then
				R.returnPending = true
				R.lastGate = "target_return"
			else
				R.lostMeAt = 0
				R.returnPending = false
				R.lastGate = "return_too_late"
			end
		else
			R.returnPending = false
			R.lastGate = "return_without_loss"
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