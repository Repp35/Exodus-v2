-- [[ autoclash ]]

local AutoClash = {}
export type TargetSwitch = {
	timestampMs: number,
	intervalMs: number,
	partnerId: number,
	resetToken: number,
}

local AutoParry
local GameInfo
local Dash
local Utils

-- tuning
local T = {

	-- activation
	RETURN_WIN_LO = 0.18,
	RETURN_WIN_MIN_FACTOR = 0.10,
	PING_FACTOR = 0.3,
	ACTIVATION_WINDOW_FACTOR = 0.8,
	ACTIVATION_MIN_DOT = 0.3,
	ACTIVATION_TTI_MAX = 0.35,
	ACTIVATION_TTI_EMA_ALPHA = 0.4,
	DASH_WINDOW_FACTOR = 1.0,
	ACT_DEACT_LOCK_RADIUS_FACTOR = 0.70,
	ACT_DEACT_LOCK_TIME = 0.05,
	PROXIMITY_RADIUS = 6,
	PARTNER_PROXIMITY_FACTOR = 0.3,
	DASH_DETECT_WINDOW = 0.25,
	OWN_DASH_ESCAPE_CONFIRM_FRAMES = 2,
	DASH_RETURN_DOT = 0.3,
	DASH_ACCEPT_FACTOR = 1.15,
	DASH_DETECT_FACTOR = 1.5,
	DASH_DEACT_LOCK_TIME = 0.070,
	DASH_RADIUS_BONUS_TIME = 0.700,
	DASH_BONUS_RETURN_MULT = 10.0,
	OWN_DASH_ESCAPE_HOLD = 0.060,
	OWN_DASH_ESCAPE_MIN_SEPARATION_SPEED = 18,
	OWN_DASH_ESCAPE_SPEED_FACTOR = 0.08,

	-- deactivation
	DEACT_DIRECTION_MAX_LO = 0.13,
	DEACT_DIRECTION_MAX_MIN_FACTOR = 0.10,
	DIRECTION_DEACT_MARGIN_FACTOR = 1.10,
	DEACT_CONFIRM_HOLD = 0.050,
	OUTSIDE_RADIUS_HOLD = 0.050,
	DEACT_CONFIRM_FRAMES = 2,
	DEACT_CONFIRM_MAX_GAP = 0.10,
	CLASH_INTERVAL_EMA_ALPHA = 0.4,
	CLASH_INTERVAL_EMA_MIN_SAMPLES = 4.5,
	CLASH_INTERVAL_DIRECTION_FACTOR = 3.0,
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
	players = nil,
	runService = nil,
	lastTarget = -1,
	clashPartnerId = -1,
	proximityPartnerId = -1,
	proximitySwitchAt = 0,
	lastSpeed = 0,
	ttiEma = nil,
	ttiEmaAt = 0,
	parryRadius = 0,
	radiusCacheAt = 0,
	radiusCacheSpeed = -1,
	radiusActivation = 0,
	radiusSafety = 0,
	dashBonusUntil = 0,
	dashDeactLockedUntil = 0,
	wasMeTarget = nil,
	lostMeAt = nil,
	returnExpiresAt = 0,
	returnWindow = 0,
	returnPending = false,
	returnFromTarget = -1,
	returnServerAt = nil,
	returnToken = 0,
	lastSyncAt = 0,
	lastSequence = nil,
	lastTargetSource = nil,
	teleported = false,

	-- activation
	activationDeactLockedUntil = 0,

	-- clash
	lastDirectionSwitchAt = 0,
	lastClashSwitchAt = 0,
	lastClashSwitchServerAt = nil,
	clashIntervalMs = 0,
	clashIntervalEma = nil,
	clashIntervalEmaSamples = 0,
	targetResetToken = 0,

	-- deactivation
	deactivationCandidate = nil,
	deactivationCandidateAt = 0,
	deactivationConfirmFrames = 0,
	deactivationLastConfirmAt = 0,
	outsideRadiusSince = nil,

	-- evaluation

	-- debug/status
	lastGate = "none",
	ownDashEscapePending = false,
	ownDashEscapeDetectedAt = 0,
	ownDashEscapeConfirmFrames = 0,
	ownDashEscapeLastDist = nil,
	ownDashEscapeLastAt = 0,
	ownDashEscapeFartherStreak = 0,
	lastActivationAt = 0,
	lastActivationSource = "none",
	lastActivationReason = "none",
	lastActivationTrigger = "none",
	lastActivationTarget = -1,
	lastActivationPartner = -1,
	lastActivationDistance = 0,
	lastActivationRadius = 0,
	lastActivationSpeed = 0,
	lastDashEvent = nil,
	lastDashData = nil,
	connections = {},
	darkConnections = {},
	pullSuspension = nil,
	pullEvent = nil,
}

local FN = {
	now = nil,
	getConfig = nil,
	getRunService = nil,
	getPlayers = nil,
	getLocalPlayer = nil,
	getSnapshot = nil,
	isSnapshotValid = nil,
	getRadius = nil,
	getStatus = nil,
}

local lastApiErrors = {}

-- helpers
local function finiteNumber(v, fallback)
	v = tonumber(v)
	if not v or v ~= v or v == math.huge or v == -math.huge then return fallback or 0 end
	return v
end
local function now()
	local f = FN.now
	if f then
		local v = f()
		if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
	end
	return 0
end
local function reportApiError(source, message, t)
	message = tostring(message); local previous = lastApiErrors[source]
	if previous and previous.message == message and t >= previous.at and t - previous.at < 1 then return end
	lastApiErrors[source] = { message = message, at = t }
	if Utils and type(Utils.recordError) == "function" then Utils.recordError(source, message) else warn(("[%s] %s"):format(source, message)) end
end
local function readValidatedSnapshot(t)
	if not FN.getSnapshot or not FN.isSnapshotValid then return nil, "no_gameinfo" end
	local ok, snapshot = pcall(FN.getSnapshot, t)
	if not ok then reportApiError("GameInfo.getSnapshot", snapshot, t); return nil, "snapshot_error" end
	if type(snapshot) ~= "table" then return nil, "snapshot_error" end
	local validOk, valid = pcall(FN.isSnapshotValid, snapshot, t)
	if not validOk then reportApiError("GameInfo.isSnapshotValid", valid, t); return nil, "snapshot_invalid" end
	if valid ~= true then return nil, "snapshot_invalid" end
	return snapshot
end
local function normalizeTarget(target)
	if type(target) == "string" then target = tonumber(target) end
	if type(target) ~= "number" or target ~= target or target < 1 or target == math.huge or target == -math.huge or target % 1 ~= 0 then return nil end
	return target
end
local function lerpBySpeed(speed, low, high, speedLow, speedHigh)
	if speedHigh <= speedLow then return low end
	local alpha = (speed - speedLow) / (speedHigh - speedLow)
	if alpha < 0 then alpha = 0 elseif alpha > 1 then alpha = 1 end
	return low + (high - low) * alpha
end
local function horizontalSpeed(v)
	if typeof(v) ~= "Vector3" then return 0 end
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end
local function distanceSquared(a, b)
	local x = a.X - b.X; local y = a.Y - b.Y; local z = a.Z - b.Z; return x * x + y * y + z * z
end
local function horizontalDistanceSquared(a, b)
	local x = a.X - b.X; local z = a.Z - b.Z; return x * x + z * z
end
local function getRootPosition()
	local root = R.boundRoot
	if not root or not root.Parent then return nil end
	local position = root.Position; return typeof(position) == "Vector3" and position or nil
end
local function getSnapshotPosition(snapshot)
	local position = snapshot and snapshot.position; return typeof(position) == "Vector3" and position or nil
end
local function isSnapshotTargeted(snapshot)
	if not snapshot then return false end
	local target = normalizeTarget(snapshot.targetId)
	if target then return target == R.localUserId end
	return snapshot.targeted == true
end
local function getPingOneWay()
	if GameInfo and type(GameInfo.getLocalPing) == "function" then
		local ok, value = pcall(GameInfo.getLocalPing)
		if ok and type(value) == "number" and value == value and value >= 0 and value < math.huge then return value end
		if not ok then reportApiError("GameInfo.getLocalPing", value, now()) end
	end
	local f = FN.getStatus
	if not f then return 0 end
	local status = f()
	if type(status) ~= "table" then return 0 end
	local ping = status.ping
	if type(ping) ~= "table" then return 0 end
	local value = tonumber(ping.oneWay)
	if not value or value <= 0 or value == math.huge or value == -math.huge then return 0 end
	return value
end
local function pingCompensation() return getPingOneWay() * T.PING_FACTOR end
local function getReturnWindow(speed)
	local configured = Utils and type(Utils.getConfigValue) == "function" and tonumber(Utils.getConfigValue("AutoClashActivationMs"))
	local minimum, maximum
	if GameInfo and type(GameInfo.getBallSpeedLimits) == "function" then minimum, maximum = GameInfo.getBallSpeedLimits() end
	local low = configured and math.clamp(configured, 0, 400) / 1000 or T.RETURN_WIN_LO; local base = lerpBySpeed(speed, low, low * T.RETURN_WIN_MIN_FACTOR, minimum or speed, maximum or speed)
	return math.max(base + pingCompensation(), 2 / 60)
end
local function beginReturnWindow(t, fromTarget, serverTime)
	local window = getReturnWindow(R.lastSpeed)
	if t < R.dashBonusUntil then window *= T.DASH_BONUS_RETURN_MULT end
	R.lostMeAt = t; R.returnWindow = window; R.returnExpiresAt = t + window + 2 * getPingOneWay() + 1 / 30; R.returnFromTarget = fromTarget or -1
	R.returnServerAt = serverTime; R.returnPending = false; R.returnToken += 1
end
local function setPhase(phase, reason)
	if R.phase == phase then return end
	local previous = R.phase; R.phase = phase
	if Utils and Utils.recordTransition then Utils.recordTransition("AutoClash", previous, phase, reason) end
end
local function addConnection(list, connection)
	if connection then list[#list + 1] = connection end
	return connection
end
local function disconnectList(list, trackCharacter)
	for i = #list, 1, -1 do
		local connection = list[i]; list[i] = nil
		if connection then
			if trackCharacter and Utils and Utils.untrackCharacter then Utils.untrackCharacter(connection) end
			pcall(function() connection:Disconnect() end)
		end
	end
end
local function clearReturnState()
	R.lostMeAt = nil; R.returnExpiresAt = 0; R.returnWindow = 0; R.returnPending = false
	R.returnFromTarget = -1; R.returnServerAt = nil; R.returnToken += 1
end
local function resetTargetState()
	R.targetResetToken += 1; R.lastTarget = -1; R.clashPartnerId = -1; R.proximityPartnerId = -1; R.proximitySwitchAt = 0; R.dashBonusUntil = 0
	R.wasMeTarget = nil; clearReturnState(); R.lastClashSwitchAt = 0; R.lastClashSwitchServerAt = nil
	R.clashIntervalMs = 0; R.lastDirectionSwitchAt = 0; R.clashIntervalEma = nil; R.clashIntervalEmaSamples = 0
	R.ttiEma = nil; R.ttiEmaAt = 0; R.lastDashEvent = nil; R.lastDashData = nil
	R.lastActivationAt = 0; R.lastActivationSource = "none"; R.lastActivationReason = "none"; R.lastActivationTrigger = "none"
	R.lastActivationTarget = -1; R.lastActivationPartner = -1; R.lastActivationDistance = 0; R.lastActivationRadius = 0
	R.lastActivationSpeed = 0
end
local function resetOwnDashState()
	R.ownDashEscapePending = false; R.ownDashEscapeDetectedAt = 0; R.ownDashEscapeConfirmFrames = 0; R.ownDashEscapeLastDist = nil
	R.ownDashEscapeLastAt = 0; R.ownDashEscapeFartherStreak = 0
end
local function resetDeactivationState()
	resetOwnDashState(); R.dashDeactLockedUntil = 0; R.deactivationCandidate = nil; R.deactivationCandidateAt = 0
	R.deactivationConfirmFrames = 0; R.deactivationLastConfirmAt = 0; R.outsideRadiusSince = nil
end
local function queryRadius(factor)
	local f = FN.getRadius
	if not f then return R.parryRadius end
	local status = f("geometry", factor, R.lastSpeed, "game")
	if type(status) ~= "table" then return R.parryRadius end
	local radius = tonumber(status.fullRadius)
	if radius and radius == radius and radius >= 0 and radius < math.huge then return radius end
	return R.parryRadius
end
local function refreshRadiusCache(t)
	t = t or now()
	if R.radiusCacheAt > 0 and t - R.radiusCacheAt < 1 / 60 and math.abs(R.lastSpeed - R.radiusCacheSpeed) < 2 then return end
	local base = queryRadius(1.0)
	if base > 0 then R.parryRadius = base; R.radiusSafety = base end
	if not R.active then R.radiusActivation = queryRadius(T.ACTIVATION_WINDOW_FACTOR) end
	R.radiusCacheAt = t; R.radiusCacheSpeed = R.lastSpeed
end
local function getActivationRadius(t)
	if t < R.dashBonusUntil then
		local dashRadius = queryRadius(T.DASH_DETECT_FACTOR)
		if dashRadius > 0 then return dashRadius end
		return queryRadius(T.DASH_WINDOW_FACTOR)
	end
	if R.radiusActivation > 0 then return R.radiusActivation end
	return queryRadius(T.ACTIVATION_WINDOW_FACTOR)
end

-- activation
local function setActivationLock(t, snapshot)
	R.activationDeactLockedUntil = 0; local root = getRootPosition(); local position = getSnapshotPosition(snapshot)
	if not root or not position or R.parryRadius <= 0 then return end
	if distanceSquared(root, position) <= (R.parryRadius * T.ACT_DEACT_LOCK_RADIUS_FACTOR) ^ 2 then R.activationDeactLockedUntil = t + T.ACT_DEACT_LOCK_TIME end
end
local function setActive(active, reason, snapshot, activationReason)
	active = active == true
	if R.active == active then return end
	R.active = active; resetDeactivationState(); local t = now()
	if active then
		R.lastActivationAt = t; R.lastActivationSource = t < R.dashBonusUntil and "anti_dash" or "normal"; R.lastActivationReason = activationReason or "unknown"
		R.lastActivationTrigger = reason or "unknown"; R.lastActivationTarget = R.lastTarget; R.lastActivationSpeed = R.lastSpeed; R.lastActivationRadius = getActivationRadius(t)
		if snapshot and snapshot.ball and R.boundRoot then
			local position = getSnapshotPosition(snapshot)
			if position then R.lastActivationDistance = math.sqrt(distanceSquared(R.boundRoot.Position, position)) end
		end
		if R.clashPartnerId == -1 and R.lastTarget ~= R.localUserId and R.lastTarget ~= -1 then R.clashPartnerId = R.lastTarget end
		R.lastActivationPartner = R.clashPartnerId; setActivationLock(t, snapshot)
		if t < R.dashBonusUntil then R.dashDeactLockedUntil = t + T.DASH_DEACT_LOCK_TIME + pingCompensation() end
	else
		R.clashPartnerId = -1; R.activationDeactLockedUntil = 0; R.dashDeactLockedUntil = 0
	end
	if Utils.setAutoSpamActive then Utils.setAutoSpamActive(active) end
	setPhase(active and "active" or "idle", reason)
end
local function stopForOutsidePull(position, reason)
	if typeof(position) ~= "Vector3" or R.parryRadius <= 0 then return false end
	local root = getRootPosition()
	if not root or distanceSquared(root, position) <= R.parryRadius * R.parryRadius then return false end
	local partner = R.clashPartnerId ~= -1 and R.clashPartnerId or (R.lastTarget ~= R.localUserId and R.lastTarget or -1)
	if R.active then
		R.pullSuspension = { partner = partner, stoppedAt = now(), lastTarget = R.lastTarget, switched = false }; setActive(false, reason); clearReturnState()
		if Utils.stopAllSpam then Utils.stopAllSpam() end
	elseif Utils and Utils.isManualSpamActive and Utils.isManualSpamActive() then
		if Utils.stopAllSpam then Utils.stopAllSpam() end
	end
	R.pullEvent = { reason = reason, at = now(), position = position }; R.lastGate = reason; return true
end
local function resetRuntime(reason)
	R.generation += 1
	if R.active then setActive(false, reason or "reset") end
	disconnectList(R.connections, true)
	for player, connection in pairs(R.darkConnections) do
		if Utils and Utils.untrackCharacter then Utils.untrackCharacter(connection) end
		connection:Disconnect(); R.darkConnections[player] = nil
	end
	R.bound = false; R.boundRoot = nil; R.lastSpeed = 0; R.parryRadius = 0
	R.radiusCacheAt = 0; R.radiusCacheSpeed = -1; R.radiusActivation = 0; R.radiusSafety = 0
	R.lastSyncAt = 0; R.lastSequence = nil; R.lastTargetSource = nil; R.teleported = false
	R.activationDeactLockedUntil = 0; R.pullSuspension = nil; R.pullEvent = nil; resetTargetState()
	resetDeactivationState(); R.lastGate = "detached"; setPhase("detached", reason or "reset")
end
local function updateTtiEma(t, root, snapshot)
	local position = getSnapshotPosition(snapshot); local ball = snapshot and snapshot.ball; local velocity = snapshot and snapshot.velocity
	if typeof(velocity) ~= "Vector3" then velocity = ball and ball.AssemblyLinearVelocity end
	if not position or typeof(velocity) ~= "Vector3" then R.ttiEma = nil; return end
	local dx = root.X - position.X; local dy = root.Y - position.Y; local dz = root.Z - position.Z; local distSq = dx * dx + dy * dy + dz * dz
	if distSq <= 0.000001 then R.ttiEma = nil; return end
	local dist = math.sqrt(distSq); local speed = velocity.Magnitude
	if speed <= 0 then R.ttiEma = nil; return end
	local closingSpeed = (velocity.X * dx + velocity.Y * dy + velocity.Z * dz) / dist
	if closingSpeed <= 0 then R.ttiEma = nil; return end
	local rawTti = dist / closingSpeed
	if not R.ttiEma then R.ttiEma = rawTti else R.ttiEma = T.ACTIVATION_TTI_EMA_ALPHA * rawTti + (1 - T.ACTIVATION_TTI_EMA_ALPHA) * R.ttiEma end
	R.ttiEmaAt = t
end
local function updateParryState(t, snapshot)
	R.lastSpeed = math.max(finiteNumber(snapshot and snapshot.speed, 0), 0); refreshRadiusCache(t); local root = getRootPosition()
	if root then updateTtiEma(t, root, snapshot) end
end
local function shouldActivate(snapshot, t)
	if not snapshot or not snapshot.ball or not snapshot.ball.Parent then R.lastGate = "no_ball"; return false end
	if R.lastTarget ~= R.localUserId then R.lastGate = "target_not_me"; return false end
	if not isSnapshotTargeted(snapshot) then R.lastGate = "target_not_me"; return false end
	local root = getRootPosition(); local position = getSnapshotPosition(snapshot)
	if not root then R.lastGate = "no_root"; return false end
	if not position or R.parryRadius <= 0 then R.lastGate = "no_effective_radius"; return false end
	local dx = root.X - position.X; local dy = root.Y - position.Y; local dz = root.Z - position.Z; local distanceSq = dx * dx + dy * dy + dz * dz
	local effectiveRadius = getActivationRadius(t)
	if distanceSq > effectiveRadius * effectiveRadius then R.lastGate = "outside_effective_radius"; return false end
	local velocity = snapshot.velocity
	if typeof(velocity) ~= "Vector3" then velocity = snapshot.ball.AssemblyLinearVelocity end
	if typeof(velocity) ~= "Vector3" or velocity.Magnitude < 6 then R.lastGate = "ball_speed_invalid"; return false end
	if distanceSq > 0.000001 then
		local dot = (velocity.X * dx + velocity.Y * dy + velocity.Z * dz) / (velocity.Magnitude * math.sqrt(distanceSq))
		if dot < T.ACTIVATION_MIN_DOT then R.lastGate = "ball_not_approaching"; return false end
	end
	R.lastGate = "activation_ready"; return true
end
local function tryPartnerProximityActivate(snapshot, t)
	local partnerId = R.proximityPartnerId
	if partnerId == -1 or partnerId == R.localUserId then return false end
	if R.lastTarget ~= R.localUserId and R.lastTarget ~= partnerId then return false end
	local player = R.players and R.players:GetPlayerByUserId(partnerId)
	local partnerRoot = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local root = getRootPosition()
	local ballPosition = getSnapshotPosition(snapshot)
	if not root or not partnerRoot or not partnerRoot.Parent or not ballPosition or R.parryRadius <= 0 then return false end
	local proximityRadius = R.parryRadius * T.PARTNER_PROXIMITY_FACTOR
	if distanceSquared(root, partnerRoot.Position) > proximityRadius * proximityRadius then return false end
	if distanceSquared(root, ballPosition) > R.parryRadius * R.parryRadius then return false end
	R.lastGate = "partner_proximity_ready"
	return true
end
local function tryReturnActivate(snapshot, t)
	if not isSnapshotTargeted(snapshot) then R.lastGate = "act_not_targeted"; return false end
	if not R.returnPending then R.lastGate = "act_no_return_pending"; return false end
	return shouldActivate(snapshot, t)
end
local function getActivationReason(snapshot, t)
	if t < R.dashBonusUntil then return "anti_dash" end
	local root = getRootPosition(); local position = getSnapshotPosition(snapshot)
	if root and position and distanceSquared(root, position) <= T.PROXIMITY_RADIUS * T.PROXIMITY_RADIUS then return "proximity" end
	return "effective_radius"
end

-- deactivation
local Deactivation = {}
function Deactivation.clearConfirmation()
	R.deactivationCandidate = nil; R.deactivationCandidateAt = 0; R.deactivationConfirmFrames = 0; R.deactivationLastConfirmAt = 0
end
function Deactivation.confirm(t, reason)
	if R.deactivationCandidate ~= reason then
		R.deactivationCandidate = reason; R.deactivationCandidateAt = t; R.deactivationConfirmFrames = 1; R.deactivationLastConfirmAt = t
		R.lastGate = reason .. "_confirming_1"; return false
	end
	local elapsed = t - R.deactivationCandidateAt; local gap = t - R.deactivationLastConfirmAt
	if elapsed < 0 or gap > T.DEACT_CONFIRM_MAX_GAP then
		Deactivation.clearConfirmation(); R.deactivationCandidate = reason; R.deactivationCandidateAt = t; R.deactivationConfirmFrames = 1
		R.deactivationLastConfirmAt = t; R.lastGate = reason .. "_confirming_1"; return false
	end
	R.deactivationConfirmFrames += 1; R.deactivationLastConfirmAt = t
	if elapsed < T.DEACT_CONFIRM_HOLD or R.deactivationConfirmFrames < T.DEACT_CONFIRM_FRAMES then R.lastGate = reason .. "_confirming_" .. R.deactivationConfirmFrames; return false end
	Deactivation.clearConfirmation(); R.lastGate = reason; return true
end
function Deactivation.direction(t, snapshot, speed)
	if isSnapshotTargeted(snapshot) then R.lastGate = "deact_direction_targeted"; return false end
	local radius = AutoParry.getRadius("geometry", 0, speed, "game"); local pureRadius = type(radius) == "table" and tonumber(radius.noWindowParryRadius) or nil; local root = getRootPosition()
	local position = getSnapshotPosition(snapshot)
	if not pureRadius or pureRadius ~= pureRadius or pureRadius < 0 or pureRadius == math.huge or not root or not position then
		Deactivation.clearConfirmation(); R.lastGate = "deact_direction_radius_unavailable"; return false
	end
	local directionDeactRadius = pureRadius * T.DIRECTION_DEACT_MARGIN_FACTOR
	if distanceSquared(root, position) <= directionDeactRadius * directionDeactRadius then Deactivation.clearConfirmation(); R.lastGate = "deact_direction_radius_protected"; return false end
	if R.lastDirectionSwitchAt <= 0 then return false end
	if R.lastSyncAt < R.lastDirectionSwitchAt then return false end
	local configured = Utils and type(Utils.getConfigValue) == "function" and tonumber(Utils.getConfigValue("AutoClashDeactivationMs")); local ping = pingCompensation()
	local minimum, maximum
	if GameInfo and type(GameInfo.getBallSpeedLimits) == "function" then minimum, maximum = GameInfo.getBallSpeedLimits() end
	local base = (configured and math.clamp(configured, 0, 400) / 1000 or T.DEACT_DIRECTION_MAX_LO) + ping
	local baseMax = math.max(lerpBySpeed(speed, base, base * T.DEACT_DIRECTION_MAX_MIN_FACTOR, minimum or speed, maximum or speed), T.MIN_EVAL_INTERVAL * 1.5); local directionMax = baseMax
	if R.clashIntervalEma and R.clashIntervalEmaSamples >= T.CLASH_INTERVAL_EMA_MIN_SAMPLES then directionMax = math.max(R.clashIntervalEma * T.CLASH_INTERVAL_DIRECTION_FACTOR, baseMax) end
	if t - R.lastDirectionSwitchAt <= directionMax then return false end
	local ball = snapshot.ball; local velocity = snapshot.velocity
	if typeof(velocity) ~= "Vector3" then velocity = ball and ball.AssemblyLinearVelocity end
	if typeof(velocity) == "Vector3" then
		local dx = root.X - position.X; local dz = root.Z - position.Z; local distSq = dx * dx + dz * dz
		if distSq > 0.000001 then
			local dist = math.sqrt(distSq); local spd = velocity.Magnitude
			if spd > 0 then
				local dot = (velocity.X * dx + velocity.Z * dz) / (spd * dist); local ttiOk = R.ttiEma and t - R.ttiEmaAt <= T.MIN_EVAL_INTERVAL * 4 and R.ttiEma <= T.ACTIVATION_TTI_MAX
				if dot >= T.ACTIVATION_MIN_DOT and ttiOk then R.lastGate = "deact_direction_still_converging"; return false end
			end
		end
	end
	return true
end

-- dash
local OwnDash = {}
local function extendReturnForDash(t)
	if R.lostMeAt == nil or R.returnPending or t > R.returnExpiresAt then return end
	local window = getReturnWindow(R.lastSpeed) * T.DASH_BONUS_RETURN_MULT
	if window > R.returnWindow then R.returnWindow = window; R.returnExpiresAt = R.lostMeAt + window + 2 * getPingOneWay() + 1 / 30 end
end
local function getHorizontalDistance(a, b)
	if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then return math.huge end
	return math.sqrt(horizontalDistanceSquared(a, b))
end
local function onDashDetected(event)
	if type(event) == "table" and event.userId == R.clashPartnerId then R.lastDashEvent = event; R.lastDashData = nil end
	if
		type(event) ~= "table"
		or not event.player
		or R.clashPartnerId == -1
		or event.userId ~= R.clashPartnerId
		or R.parryRadius <= 0
		or typeof(event.position) ~= "Vector3"
		or typeof(event.velocity) ~= "Vector3"
	then
		return
	end
	local localRoot = getRootPosition()
	if not localRoot then return end
	local distanceSq = horizontalDistanceSquared(localRoot, event.position)
	if distanceSq <= 0 then return end
	local distance = math.sqrt(distanceSq); local speed = horizontalSpeed(event.velocity)
	if speed <= 0 then return end
	local acceptRadius = queryRadius(T.DASH_ACCEPT_FACTOR); local detectRadius = queryRadius(T.DASH_DETECT_FACTOR); local fullRadius = R.radiusSafety
	if acceptRadius <= 0 or detectRadius <= 0 or fullRadius <= 0 then return end
	local dx = localRoot.X - event.position.X; local dz = localRoot.Z - event.position.Z; local dot = (event.velocity.X * dx + event.velocity.Z * dz) / (speed * distance)
	if dot < T.DASH_RETURN_DOT then return end
	local closingSpeed = speed * dot
	if distance > detectRadius and distance - closingSpeed * (T.DASH_DETECT_WINDOW + getPingOneWay()) > acceptRadius then return end
	local targetAtDetection = normalizeTarget(R.lastTarget)
	if targetAtDetection ~= R.localUserId and targetAtDetection ~= event.userId then return end
	local t = finiteNumber(event.detectedAt, now())
	local dashData = {
		player = event.player,
		userId = event.userId,
		detectedAt = t,
		expiresAt = t + T.DASH_DETECT_WINDOW + pingCompensation(),
		position = event.position,
		velocity = event.velocity,
		previousPosition = event.previousPosition,
		distanceAtDetection = distance,
		confirmRadius = acceptRadius,
		targetAtDetection = targetAtDetection,
		dangerous = false,
	}

	R.lastDashData = dashData
	if distance <= acceptRadius then dashData.dangerous = true; R.dashBonusUntil = t + T.DASH_RADIUS_BONUS_TIME + pingCompensation(); extendReturnForDash(t) end
end
function OwnDash.getOpponent()
	local id = R.clashPartnerId
	if id == -1 or id == R.localUserId or not R.players then return nil end
	local opponent = R.players:GetPlayerByUserId(id)
	if not opponent or not opponent.Parent then return nil end
	local character = opponent.Character
	if not character then return nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root.Parent then return nil end
	return opponent, root
end
local function processPendingDash(t)
	local pending = R.lastDashData
	if not pending or pending.dangerous == true then return end
	if pending.userId ~= R.clashPartnerId or t < pending.detectedAt or t > pending.expiresAt then R.lastDashData = nil; return end
	local localRoot = getRootPosition(); local opponent, opponentRoot = OwnDash.getOpponent()
	if not localRoot or not opponentRoot or opponent ~= pending.player then return end
	local distanceSq = horizontalDistanceSquared(localRoot, opponentRoot.Position)
	if distanceSq <= pending.confirmRadius * pending.confirmRadius then
		pending.dangerous = true; pending.confirmedAt = t; R.dashBonusUntil = pending.detectedAt + T.DASH_RADIUS_BONUS_TIME + pingCompensation(); extendReturnForDash(t)
	end
end
function OwnDash.getRecentThreat(t)
	local event = R.lastDashEvent
	if not event or not event.player or event.userId ~= R.clashPartnerId or not event.player.Parent then return nil end
	local detectedAt = finiteNumber(event.detectedAt, 0); local age = t - detectedAt
	if age < 0 or age > T.DASH_DETECT_WINDOW + pingCompensation() then return nil end
	return event
end
function OwnDash.shouldDeactivate(t)
	if not R.active then resetOwnDashState(); return false end
	local ownRoot = getRootPosition()
	if not ownRoot then resetOwnDashState(); R.lastGate = "own_dash_escape_no_root"; return false end
	local event = OwnDash.getRecentThreat(t)
	if not event then
		if R.ownDashEscapePending then
			if t - R.ownDashEscapeDetectedAt > T.DASH_DETECT_WINDOW + pingCompensation() then resetOwnDashState() else R.lastGate = "own_dash_escape_waiting" end
		else
			R.lastGate = "own_dash_escape_no_dash"
		end
		return false
	end
	local _, opponentRoot = OwnDash.getOpponent()
	if not opponentRoot then resetOwnDashState(); R.lastGate = "own_dash_escape_no_opponent"; return false end
	local detectedAt = finiteNumber(event.detectedAt, 0)
	if not R.ownDashEscapePending or R.ownDashEscapeDetectedAt ~= detectedAt then
		R.ownDashEscapePending = true; R.ownDashEscapeDetectedAt = detectedAt; R.ownDashEscapeConfirmFrames = 0; R.ownDashEscapeFartherStreak = 0
		R.ownDashEscapeLastDist = getHorizontalDistance(ownRoot, opponentRoot.Position); R.ownDashEscapeLastAt = t; R.lastGate = "own_dash_escape_detected"; return false
	end
	local currentDistance = getHorizontalDistance(ownRoot, opponentRoot.Position); local previousDistance = R.ownDashEscapeLastDist
	if not previousDistance then R.ownDashEscapeLastDist = currentDistance; R.ownDashEscapeLastAt = t; R.lastGate = "own_dash_escape_first"; return false end
	local sampleDt = t - R.ownDashEscapeLastAt
	if sampleDt <= 0 or sampleDt > T.DEACT_CONFIRM_MAX_GAP then
		R.ownDashEscapeFartherStreak = 0; R.ownDashEscapeConfirmFrames = 0; R.ownDashEscapeLastDist = currentDistance; R.ownDashEscapeLastAt = t
		R.lastGate = "own_dash_escape_sample_gap"; return false
	end
	local deltaDistance = currentDistance - previousDistance; local dx = ownRoot.X - opponentRoot.Position.X; local dz = ownRoot.Z - opponentRoot.Position.Z
	local distance = math.max(currentDistance, 0.001); local awayX = dx / distance; local awayZ = dz / distance; local opponentVelocity = opponentRoot.AssemblyLinearVelocity
	local separationSpeed = opponentVelocity.X * -awayX + opponentVelocity.Z * -awayZ; local opponentHorizontalSpeed = horizontalSpeed(opponentVelocity)
	local requiredSeparationSpeed = math.max(T.OWN_DASH_ESCAPE_MIN_SEPARATION_SPEED, opponentHorizontalSpeed * T.OWN_DASH_ESCAPE_SPEED_FACTOR); local measuredSeparationSpeed = deltaDistance / sampleDt
	local effectiveSeparationSpeed = math.max(separationSpeed, measuredSeparationSpeed); local isMeaningfulEscape = deltaDistance > 0 and effectiveSeparationSpeed >= requiredSeparationSpeed
	R.ownDashEscapeLastDist = currentDistance; R.ownDashEscapeLastAt = t
	if isMeaningfulEscape then
		R.ownDashEscapeFartherStreak += 1; R.ownDashEscapeConfirmFrames += 1; R.lastGate = "own_dash_escape_farther_" .. R.ownDashEscapeFartherStreak
		return t - R.ownDashEscapeDetectedAt >= T.OWN_DASH_ESCAPE_HOLD and R.ownDashEscapeFartherStreak >= T.OWN_DASH_ESCAPE_CONFIRM_FRAMES
	end
	R.ownDashEscapeFartherStreak = 0; R.ownDashEscapeConfirmFrames = 0; R.ownDashEscapeLastDist = currentDistance; R.ownDashEscapeLastAt = t
	R.lastGate = "own_dash_escape_not_farther"; return false
end
function Deactivation.shouldDeactivate(t, snapshot)
	local rootPosition = getRootPosition()
	local ballPosition = getSnapshotPosition(snapshot)
	if rootPosition and ballPosition and R.parryRadius > 0 and distanceSquared(rootPosition, ballPosition) > R.parryRadius * R.parryRadius then
		if not R.outsideRadiusSince or t < R.outsideRadiusSince then R.outsideRadiusSince = t end
		if t - R.outsideRadiusSince >= T.OUTSIDE_RADIUS_HOLD then
			R.lastGate = "deact_outside_radius"
			return true
		end
	else
		R.outsideRadiusSince = nil
	end
	local dashEscape = OwnDash.shouldDeactivate(t)
	if dashEscape and not isSnapshotTargeted(snapshot) then R.lastGate = "own_dash_escape"; return true end
	local root = getRootPosition(); local position = getSnapshotPosition(snapshot)
	if not root or not position or R.parryRadius <= 0 then Deactivation.clearConfirmation(); R.lastGate = "deact_no_position"; return false end
	if t < R.activationDeactLockedUntil then Deactivation.clearConfirmation(); R.lastGate = "deact_activation_lock"; return false end
	if t < R.dashDeactLockedUntil then Deactivation.clearConfirmation(); R.lastGate = "deact_dash_lock"; return false end
	local speed = R.lastSpeed
	if speed <= 0 then R.lastGate = "deact_ball_stopped"; return not isSnapshotTargeted(snapshot) end
	if Deactivation.direction(t, snapshot, speed) then return Deactivation.confirm(t, "deact_direction") end
	Deactivation.clearConfirmation(); R.lastGate = "deact_none"; return false
end

-- evaluation
local function evaluateClash(t, snapshot)
	local root = R.boundRoot
	if not root or not root.Parent then return end
	local ball = snapshot and snapshot.ball; local snapshotUsable = ball and ball.Parent
	if R.active and not snapshotUsable then
		if t >= R.activationDeactLockedUntil then R.lastGate = "ball_lost"; setActive(false, "ball_lost") else R.lastGate = "ball_lost_pending" end
		return
	end
	if not snapshotUsable then R.lastGate = "no_ball"; return end
	updateParryState(t, snapshot)
	if R.pullSuspension then
		local suspension = R.pullSuspension
		if t - suspension.stoppedAt > 2 or not Utils.isActive() or Utils.getConfigValue("AutoClash") ~= true then
			R.pullSuspension = nil
		else
			local position = getSnapshotPosition(snapshot); local target = normalizeTarget(snapshot.targetId); local opponent = R.players and R.players:GetPlayerByUserId(suspension.partner)
			local opponentRoot = opponent and opponent.Character and opponent.Character:FindFirstChild("HumanoidRootPart"); local inRange = position
				and R.parryRadius > 0
				and distanceSquared(root.Position, position) <= R.parryRadius ^ 2
				and opponentRoot
				and opponentRoot.Parent
				and distanceSquared(root.Position, opponentRoot.Position) <= R.parryRadius ^ 2
			if inRange and suspension.switched and (target == R.localUserId or target == suspension.partner) then
				R.pullSuspension = nil; R.lastTarget = target; R.clashPartnerId = suspension.partner; setActive(true, "pull_return", snapshot, "pull_return")
				return
			end
			return
		end
	end
	if R.active then
		if Deactivation.shouldDeactivate(t, snapshot) then setActive(false, "target_deactivated") end
		return
	end
	if tryPartnerProximityActivate(snapshot, t) then
		R.clashPartnerId = R.proximityPartnerId
		clearReturnState()
		setActive(true, "activated", snapshot, "partner_proximity")
	elseif tryReturnActivate(snapshot, t) then
		local activationReason = getActivationReason(snapshot, t)
		clearReturnState()
		setActive(true, "activated", snapshot, activationReason)
	end
end

-- hub
local function stopForGate(reason)
	local wasActive = R.active
	if wasActive then setActive(false, reason) end
	if wasActive or R.lastGate ~= reason or R.lastTarget ~= -1 or R.returnPending then resetTargetState() end
	R.lastGate = reason; return false
end
local function checkHubState()
	if not Utils then R.lastGate = "no_utils"; return false end
	if Utils.isManualSpamActive() then return stopForGate("manual_spam") end
	if not Utils.isActive() then return stopForGate("hub_inactive") end
	local enabled
	if type(Utils.getConfigValue) == "function" then enabled = Utils.getConfigValue("AutoClash") else local config = Utils.getConfig(); enabled = type(config) == "table" and config.AutoClash end
	if enabled ~= true then return stopForGate("hub_disabled") end
	return true
end

-- heartbeat
local function heartbeatStep(generation, character, root)
	if generation ~= R.generation or not character.Parent or not root.Parent then return end
	local t = now()
	if not checkHubState() then return end
	if not R.returnPending and R.returnExpiresAt > 0 and t >= R.returnExpiresAt then clearReturnState(); R.lastGate = "return_expired" end
	local snapshot, snapshotError = readValidatedSnapshot(t)
	if not snapshot then
		if R.active then setActive(false, snapshotError == "snapshot_invalid" and "snapshot_invalid" or "ball_lost"); resetTargetState() end
		R.lastGate = snapshotError
		return
	end
	if Dash and type(Dash.tick) == "function" then Dash.tick(t) end
	processPendingDash(t)
	if snapshot.teleported == true then
		if not R.teleported then AutoClash.onBallSync({ Sequence = snapshot.syncSequence, Teleported = true, Source = "snapshot" }) end
		R.lastGate = "teleported"; return
	end
	R.teleported = false; local snapshotTarget = normalizeTarget(snapshot.targetId); local targetChanged = snapshotTarget and (R.wasMeTarget == nil or snapshotTarget ~= R.lastTarget)
	local targetCleared = snapshot.targetId ~= nil and not snapshotTarget and (R.lastTarget ~= -1 or R.active)
	if targetChanged or targetCleared then
		local sequence = snapshot.syncSequence
		if type(sequence) == "number" or (R.lastSequence == nil and (R.lastTargetSource ~= "event" or t - R.lastSyncAt >= 0.10)) then
			AutoClash.onBallSync({ Sequence = sequence, TargetPlayerID = snapshot.targetId, Speed = snapshot.syncSpeed, Source = "snapshot" })
		end
	end
	evaluateClash(t, snapshot)
end

-- character
local function bindCharacter(character)
	resetRuntime("rebind"); local generation = R.generation
	if not character or not character.Parent then return false end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
	if generation ~= R.generation or not root or not root.Parent then return false end
	R.boundRoot = root
	if not R.runService or not R.runService.Heartbeat then R.boundRoot = nil; R.lastGate = "no_run_service"; return false end
	local heartbeat = R.runService.Heartbeat:Connect(function() heartbeatStep(generation, character, root) end)
	addConnection(R.connections, heartbeat)
	if Utils.trackCharacter then Utils.trackCharacter(heartbeat) end
	local function watchDarkSeal(player)
		if player.UserId == R.localUserId or R.darkConnections[player] then return end
		local connection = player:GetAttributeChangedSignal("DarkSealed"):Connect(function()
			if generation ~= R.generation or not R.bound or player:GetAttribute("DarkSealed") ~= true then return end
			local targetRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if targetRoot and targetRoot.Parent then stopForOutsidePull(targetRoot.Position, "dark_seal_pull") end
		end)
		R.darkConnections[player] = connection
		if Utils.trackCharacter then Utils.trackCharacter(connection) end
	end
	if R.players and type(R.players.GetPlayers) == "function" then
		for _, player in ipairs(R.players:GetPlayers()) do
			watchDarkSeal(player)
		end
		local added = R.players.PlayerAdded:Connect(watchDarkSeal)
		local removing = R.players.PlayerRemoving:Connect(function(player)
			local connection = R.darkConnections[player]
			if connection then
				if Utils.untrackCharacter then Utils.untrackCharacter(connection) end
				connection:Disconnect(); R.darkConnections[player] = nil
			end
		end)
		addConnection(R.connections, added); addConnection(R.connections, removing)
		if Utils.trackCharacter then Utils.trackCharacter(added); Utils.trackCharacter(removing) end
	end
	local manifest = type(GameInfo.getManifestRemote) == "function" and GameInfo.getManifestRemote()
	if manifest then
		local connection = manifest.OnClientEvent:Connect(function(caster)
			if generation ~= R.generation or not R.bound or typeof(caster) ~= "CFrame" then return end
			stopForOutsidePull(caster.Position, "manifest_pull")
		end)
		addConnection(R.connections, connection)
		if Utils.trackCharacter then Utils.trackCharacter(connection) end
	end
	local haunter = type(GameInfo.getHaunterRemote) == "function" and GameInfo.getHaunterRemote()
	if haunter then
		local connection = haunter.OnClientEvent:Connect(function(_, destination)
			if generation ~= R.generation or not R.bound or R.active or not checkHubState() or typeof(destination) ~= "CFrame" then return end
			local ownPosition = getRootPosition()
			if not ownPosition or distanceSquared(ownPosition, destination.Position) > 10 * 10 then return end
			local snapshot = readValidatedSnapshot(now())
			if not snapshot or snapshot.teleported or not isSnapshotTargeted(snapshot) then return end
			updateParryState(now(), snapshot); R.lastTarget = R.localUserId; R.wasMeTarget = true; clearReturnState()
			setActive(true, "haunter", snapshot, "haunter")
		end)
		addConnection(R.connections, connection)
		if Utils.trackCharacter then Utils.trackCharacter(connection) end
	end
	local ancestry = character.AncestryChanged:Connect(function(_, parent)
		if parent then return end
		resetRuntime("character_removed"); R.lastGate = "character_removed"
	end)
	addConnection(R.connections, ancestry)
	if Utils.trackCharacter then Utils.trackCharacter(ancestry) end
	R.bound = true; setPhase("waiting", "character_bound"); return true
end
function AutoClash.onBallSync(data)
	if type(data) ~= "table" or not Utils or not R.localUserId or not R.bound then return end
	if not checkHubState() then return end
	local sequence = data.Sequence or data.TeleportSequence
	if sequence == nil and type(GameInfo.getSyncSequence) == "function" and type(GameInfo.getSyncData) == "function" then
		local sync = GameInfo.getSyncData()
		if data == sync then sequence = GameInfo.getSyncSequence() end
	end
	if type(sequence) == "number" and sequence == sequence and sequence >= 0 and sequence < 65536 and sequence % 1 == 0 then
		if R.lastSequence ~= nil then
			local delta = (sequence - R.lastSequence) % 65536
			if delta == 0 or delta > 32768 then return true end
		end
		R.lastSequence = sequence
	end
	local t = now(); R.lastSyncAt = t; R.lastTargetSource = data.Source == "snapshot" and "snapshot" or "event"
	if data.Teleported == true then
		R.teleported = true
		if R.active then setActive(false, "teleported") end
		resetTargetState(); R.lastGate = "teleported"; return true
	end
	R.teleported = false; local possessorId = normalizeTarget(data.PossessorId)
	if possessorId and possessorId ~= R.localUserId and R.players then
		local possessor = R.players:GetPlayerByUserId(possessorId); local targetRoot = possessor and possessor.Character and possessor.Character:FindFirstChild("HumanoidRootPart")
		if targetRoot and targetRoot.Parent and stopForOutsidePull(targetRoot.Position, "possession_pull") then return true end
	end
	local target = normalizeTarget(data.TargetPlayerID) or normalizeTarget(data.HighlightTargetPlayerID); local hasExplicitTarget = data.TargetPlayerID ~= nil or data.HighlightTargetPlayerID ~= nil
	if not target and not hasExplicitTarget and type(GameInfo.getTargetId) == "function" then target = normalizeTarget(GameInfo.getTargetId()) end
	if not target then
		if hasExplicitTarget then
			if R.active then setActive(false, "invalid_target") end
			resetTargetState(); R.lastGate = "invalid_target"; return true
		end
		if R.active and Deactivation.confirm(t, "invalid_target") then setActive(false, "invalid_target") end
		R.lastGate = "invalid_target"; return true
	end
	local speed = tonumber(data.Speed)
	if speed and speed == speed and speed > 0 and speed < math.huge then R.lastSpeed = speed end
	local serverTime = tonumber(data.ServerTime)
	if not serverTime or serverTime ~= serverTime or serverTime == math.huge or serverTime == -math.huge then serverTime = nil end
	local previousTarget = R.lastTarget; local wasMe = R.wasMeTarget; local isMe = target == R.localUserId
	if target == previousTarget and wasMe ~= nil then return true end
	R.lastTarget = target
	if wasMe == nil then R.wasMeTarget = isMe; clearReturnState(); R.lastGate = isMe and "initial_me" or "initial_not_me"; return true end
	if R.pullSuspension then
		local suspension = R.pullSuspension
		if (target == R.localUserId or target == suspension.partner) and target ~= suspension.lastTarget then suspension.switched = true end
		suspension.lastTarget = target; R.lastTarget = target; R.wasMeTarget = isMe; return true
	end
	if R.active and R.clashPartnerId ~= -1 and R.clashPartnerId ~= R.localUserId then
		local previousWasPartner = previousTarget == R.clashPartnerId; local currentIsPartner = target == R.clashPartnerId
		if previousWasPartner ~= currentIsPartner and wasMe ~= isMe and (previousWasPartner or currentIsPartner) then
			if R.lastClashSwitchAt > 0 and t >= R.lastClashSwitchAt then
				local interval = t - R.lastClashSwitchAt
				if serverTime and R.lastClashSwitchServerAt and serverTime >= R.lastClashSwitchServerAt then interval = serverTime - R.lastClashSwitchServerAt end
				R.clashIntervalMs = interval * 1000
				if not R.clashIntervalEma then R.clashIntervalEma = interval else R.clashIntervalEma = T.CLASH_INTERVAL_EMA_ALPHA * interval + (1 - T.CLASH_INTERVAL_EMA_ALPHA) * R.clashIntervalEma end
				R.clashIntervalEmaSamples += 1
			end
			R.lastClashSwitchAt = t; R.lastClashSwitchServerAt = serverTime
		end
	end
	if wasMe ~= isMe then
		R.lastDirectionSwitchAt = t
		local partnerId = isMe and previousTarget or target
		if partnerId ~= -1 and partnerId ~= R.localUserId then
			R.proximityPartnerId = partnerId
			R.proximitySwitchAt = t
		end
	end
	if wasMe and not isMe then
		if R.active and R.clashPartnerId ~= -1 and target ~= R.clashPartnerId then setActive(false, "target_redirected") end
		beginReturnWindow(t, target, serverTime); R.clashPartnerId = target; Deactivation.clearConfirmation(); R.lastGate = "target_lost"
	elseif not wasMe and isMe then
		local elapsed = R.lostMeAt and (t - R.lostMeAt) or nil
		if serverTime and R.returnServerAt then elapsed = serverTime - R.returnServerAt end
		if elapsed == nil or R.returnFromTarget ~= previousTarget then clearReturnState(); R.lastGate = "return_without_matching_loss"
		elseif elapsed < 0 or elapsed > R.returnWindow or t > R.returnExpiresAt then clearReturnState(); R.lastGate = "return_too_late"
		else R.clashPartnerId = previousTarget; R.returnPending = true; R.lastGate = "target_return" end
	elseif not wasMe and not isMe and target ~= previousTarget then
		clearReturnState()
		if R.active then setActive(false, "target_redirected") end
		R.clashPartnerId = -1; R.proximityPartnerId = -1; R.proximitySwitchAt = 0; R.lastGate = "target_redirected"
	end
	R.wasMeTarget = isMe
	if R.returnPending and data.Source ~= "snapshot" then
		local snapshot = readValidatedSnapshot(t)
		if snapshot and snapshot.teleported ~= true then evaluateClash(t, snapshot) end
	end
	return true
end

-- setup
function AutoClash.setup(deps)
	if type(deps) ~= "table" then return false, "dependências inválidas" end
	local required = {
		{ "AutoParry", "getRadius" },
		{ "AutoParry", "getStatus" },
		{ "Dash", "setHandler" },
		{ "Dash", "tick" },
		{ "GameInfo", "getSnapshot" },
		{ "GameInfo", "isSnapshotValid" },
		{ "Utils", "now" },
		{ "Utils", "getConfig" },
		{ "Utils", "getRunService" },
		{ "Utils", "getPlayers" },
		{ "Utils", "recordTransition" },
		{ "Utils", "setAutoSpamActive" },
		{ "Utils", "trackCharacter" },
		{ "Utils", "untrackCharacter" },
		{ "Utils", "isActive" },
		{ "Utils", "isManualSpamActive" },
		{ "Utils", "getLocalPlayer" },
		{ "Utils", "apiVersion" },
	}

	for i = 1, #required do
		local requirement = required[i]; local object = deps[requirement[1]]
		if not object or type(object[requirement[2]]) ~= "function" then return false, requirement[1] .. "." .. requirement[2] .. " ausente" end
	end
	if Utils then resetRuntime("setup") else disconnectList(R.connections, true) end
	table.clear(lastApiErrors); AutoParry = deps.AutoParry; Dash = deps.Dash; GameInfo = deps.GameInfo
	Utils = deps.Utils; FN.now = Utils.now; FN.getConfig = Utils.getConfig; FN.getRunService = Utils.getRunService
	FN.getPlayers = Utils.getPlayers; FN.getLocalPlayer = Utils.getLocalPlayer
	FN.getSnapshot = type(GameInfo.getSnapshotAt) == "function" and GameInfo.getSnapshotAt or function(time) return GameInfo.getSnapshot(nil, time) end
	FN.isSnapshotValid = GameInfo.isSnapshotValid; FN.getRadius = AutoParry.getRadius; FN.getStatus = AutoParry.getStatus; Dash.setHandler(onDashDetected)
	local player = Utils.getLocalPlayer()
	if not player then
		Dash.setHandler(nil); AutoParry = nil; GameInfo = nil; Dash = nil
		Utils = nil
		for key in pairs(FN) do
			FN[key] = nil
		end
		return false
	end
	R.localUserId = player.UserId; R.generation = 0; R.bound = false; R.active = false
	R.phase = "detached"; R.boundRoot = nil; R.players = nil; R.runService = nil
	R.pullSuspension = nil; R.pullEvent = nil; R.lastSpeed = 0; R.parryRadius = 0
	R.radiusActivation = 0; R.radiusSafety = 0; R.lastSyncAt = 0; R.lastSequence = nil
	R.lastTargetSource = nil; R.teleported = false; R.activationDeactLockedUntil = 0; R.connections = {}
	resetTargetState(); resetDeactivationState(); R.runService = Utils.getRunService(); R.players = Utils.getPlayers()
	R.lastGate = "none"; return true
end
function AutoClash.bindCharacter(character) return bindCharacter(character) end
function AutoClash.detachCharacter() resetRuntime("detach") end
function AutoClash.teardown()
	resetRuntime("teardown")
	if Dash and Dash.setHandler then Dash.setHandler(nil) end
	AutoParry = nil; GameInfo = nil; Dash = nil; Utils = nil
	R.players = nil; R.runService = nil; R.localUserId = nil
	for key in pairs(FN) do
		FN[key] = nil
	end
end
function AutoClash.isActive() return R.active == true end
function AutoClash.getPullEvent() return R.pullEvent end
function AutoClash.stopSpam()
	setActive(false, "fierce_deflect"); clearReturnState(); R.lastGate = "fierce_deflect"
	if Utils and Utils.setAutoSpamActive then Utils.setAutoSpamActive(false) end
end
function AutoClash.getTargetSwitch(): TargetSwitch
	return {
		timestampMs = R.lastClashSwitchAt * 1000,
		intervalMs = R.clashIntervalMs,
		partnerId = R.clashPartnerId,
		resetToken = R.targetResetToken,
	}
end
function AutoClash.getActivationContext()
	return {
		active = R.active == true,
		source = R.lastActivationSource,
		reason = R.lastActivationReason,
		trigger = R.lastActivationTrigger,
		timestamp = R.lastActivationAt,
		target = R.lastActivationTarget,
		partner = R.lastActivationPartner,
		distance = R.lastActivationDistance,
		parryRadius = R.lastActivationRadius,
		speed = R.lastActivationSpeed,
	}
end
function AutoClash.getDashData()
	local data = R.lastDashData
	if type(data) ~= "table" or not data.player or not data.player.Parent or data.userId ~= R.clashPartnerId then return nil end
	local t = now()
	if t < data.detectedAt or t > data.expiresAt then return nil end
	local target = normalizeTarget(R.lastTarget)
	if (target ~= R.localUserId and target ~= data.userId) or (data.targetAtDetection ~= R.localUserId and data.targetAtDetection ~= data.userId) then return nil end
	return data
end
function AutoClash.getStatus()
	local schema
	if Utils and Utils.apiVersion then schema = Utils.apiVersion() end
	local gameClash
	if GameInfo and type(GameInfo.getClashContext) == "function" then
		local ok, context = pcall(GameInfo.getClashContext)
		if ok then gameClash = context else reportApiError("GameInfo.getClashContext", context, now()) end
	end
	return {
		schema = schema,
		phase = R.phase,
		bound = R.bound == true,
		active = R.active == true,
		gameClash = gameClash,
		activationSource = R.lastActivationSource,
		activationReason = R.lastActivationReason,
		activationTrigger = R.lastActivationTrigger,
		activationAt = R.lastActivationAt,
		activationTarget = R.lastActivationTarget,
		activationPartner = R.lastActivationPartner,
		activationDistance = R.lastActivationDistance,
		activationRadius = R.lastActivationRadius,
		activationSpeed = R.lastActivationSpeed,
		parryRadius = R.parryRadius,
		lastTarget = R.lastTarget,
		clashPartnerId = R.clashPartnerId,
		clashIntervalEma = R.clashIntervalEma,
		clashIntervalEmaSamples = R.clashIntervalEmaSamples,
		lastGate = R.lastGate,
		ownDashEscapePending = R.ownDashEscapePending == true,
		ownDashEscapeConfirmFrames = R.ownDashEscapeConfirmFrames,
		ownDashEscapeLastDistance = R.ownDashEscapeLastDist,
		ownDashEscapeLastAt = R.ownDashEscapeLastAt,
		returnPending = R.returnPending == true,
		returnWindow = R.returnWindow,
		returnExpiresAt = R.returnExpiresAt,
		returnFromTarget = R.returnFromTarget,
		returnToken = R.returnToken,
		dashBonusUntil = R.dashBonusUntil,
		dashDeactLockedUntil = R.dashDeactLockedUntil,
		deactivationCandidate = R.deactivationCandidate,
		deactivationConfirmFrames = R.deactivationConfirmFrames,
		deactivationCandidateAt = R.deactivationCandidateAt,
	}
end

-- contract
AutoClash.__contract = {
	requiresMethods = {
		AutoParry = { "getRadius", "getStatus" },
		Dash = { "setHandler", "tick" },
		GameInfo = { "getSnapshot", "isSnapshotValid" },
		Utils = {
			"now",
			"getConfig",
			"getRunService",
			"getPlayers",
			"recordTransition",
			"setAutoSpamActive",
			"trackCharacter",
			"untrackCharacter",
			"isActive",
			"isManualSpamActive",
			"getLocalPlayer",
			"apiVersion",
		},
	},

	provides = {
		"setup",
		"bindCharacter",
		"detachCharacter",
		"onBallSync",
		"getStatus",
		"getTargetSwitch",
		"getDashData",
		"getPullEvent",
		"stopSpam",
	},

	requires = {
		AutoParry = "autoparry",
		Dash = "dash",
		GameInfo = "gameinfo",
		Utils = "utils",
	},

	onBallSync = true,
	bindCharacter = true,
	minAutoParryVersion = 10,
	requiresVersions = { AutoParry = 10 },
}

return AutoClash
