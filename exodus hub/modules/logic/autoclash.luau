-- [[ Auto Clash ]]

local AutoClash = {}

-- dependencies
local AutoParry
local GameInfo
local Utils

-- configuration
local T = {
	-- activation
	RETURN_WIN_LO = 0.10,
	RETURN_WIN_MIN_FACTOR = 0.10,
	RETURN_SPD_LO = 60,
	RETURN_SPD_HI = 600,
	PING_FACTOR = 0.3,
	ACT_RADIUS_EXTRA_WINDOW = 0.150,
	REACTIVATE_COOLDOWN = 0.25,
	ACT_DEACT_LOCK_RADIUS_FACTOR = 0.70,
	ACT_DEACT_LOCK_TIME = 0.050,
	DASH_DETECT_WINDOW = 0.250,
	OWN_DASH_ESCAPE_CONFIRM_FRAMES = 2,
	OWN_DASH_ESCAPE_DOT = -0.30,
	-- deactivation / direction
	DEACT_DIRECTION_MAX_LO = 0.10,
	DEACT_DIRECTION_MAX_MIN_FACTOR = 0.10,
	DEACT_DIRECTION_SPD_LO = 60,
	DEACT_DIRECTION_SPD_HI = 600,
	DEACT_DIRECTION_MIN_RADIUS_FACTOR = 0.40,
	-- system
	MIN_EVAL_INTERVAL = 1 / 120,
}

-- constants
local DASH_PARTS = {
	DashEffect = true,
	WindDash = true,
	Dash = true,
}

-- runtime state
local R = {
	-- lifecycle
	generation = 0,
	bound = false,
	active = false,
	phase = "detached",
	boundRoot = nil,
	localUserId = nil,
	-- ball / clash
	lastTarget = -1,
	clashPartnerId = -1,
	lastSpeed = 0,
	parryRadius = 0,
	-- target return
	wasMeTarget = nil,
	lostMeAt = 0,
	returnPending = false,
	-- deactivation
	activationDeactLockedUntil = 0,
	reactivateBlockedUntil = 0,
	lastDirectionSwitchAt = 0,
	-- escape detector
	-- evaluation
	lastEvalAt = 0,
	lastDashScanAt = 0,
	lastGate = "none",
	-- own dash escape
	ownDashEscapePending = false,
	ownDashEscapeSince = 0,
	ownDashEscapeDetectedAt = 0,
	ownDashEscapeConfirmFrames = 0,
	ownDashEscapeLastDist = nil,
	ownDashEscapeFartherStreak = 0,
	-- connections
	connections = {},
	dashConnections = {},
	dashGeneration = 0,
	-- dash cache
	dashEvents = {},
	dashCooldown = {},
	dashTrackSnap = {},
	dashVelAnterior = {},
	dashVelFrames = {},
}

-- basic helpers
local function now()
	if not Utils or type(Utils.now) ~= "function" then
		return 0
	end
	local ok, value = pcall(Utils.now)
	return ok and tonumber(value) or 0
end
local function normalizeTarget(target)
	if type(target) == "string" then
		target = tonumber(target)
	end
	return type(target) == "number" and target or nil
end
local function lerpBySpeed(speed, low, high, speedLow, speedHigh)
	speed = tonumber(speed) or 0
	if speedHigh <= speedLow then
		return low
	end
	local alpha = math.clamp((speed - speedLow) / (speedHigh - speedLow), 0, 1)
	return low + (high - low) * alpha
end
local function horizontalSpeed(velocity)
	if typeof(velocity) ~= "Vector3" then
		return 0
	end
	return math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
end

-- position helpers
local function getRootPosition()
	local root = R.boundRoot
	if not root or not root.Parent then
		return nil
	end
	local ok, position = pcall(function()
		return root.Position
	end)
	return ok and typeof(position) == "Vector3" and position or nil
end
local function getSnapshotPosition(snapshot)
	local position = snapshot and snapshot.position
	return typeof(position) == "Vector3" and position or nil
end
local function getDataPosition(data)
	local position = data and data.RealPosition
	return typeof(position) == "Vector3" and position or nil
end
local function getDistance(position)
	local root = getRootPosition()
	if not root or typeof(position) ~= "Vector3" then
		return nil
	end
	return (root - position).Magnitude
end

-- timing
local function getPingOneWay()
	if not AutoParry or type(AutoParry.getPingOneWay) ~= "function" then
		return 0
	end
	local ok, value = pcall(AutoParry.getPingOneWay)
	return ok and math.max(tonumber(value) or 0, 0) or 0
end
local function getReturnWindow(speed)
	local base = lerpBySpeed(speed, T.RETURN_WIN_LO, T.RETURN_WIN_LO * T.RETURN_WIN_MIN_FACTOR, T.RETURN_SPD_LO, T.RETURN_SPD_HI)
	return math.max(base + getPingOneWay() * T.PING_FACTOR, T.MIN_EVAL_INTERVAL * 1.5)
end

-- phase
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

-- connection management
local function addConnection(list, connection)
	if connection then
		list[#list + 1] = connection
	end
	return connection
end
local function disconnectList(list, trackCharacter)
	for i = #list, 1, -1 do
		local connection = list[i]
		list[i] = nil
		if connection then
			if trackCharacter and Utils and type(Utils.untrackCharacter) == "function" then
				pcall(Utils.untrackCharacter, connection)
			end
			pcall(function()
				connection:Disconnect()
			end)
		end
	end
end
local function disconnectCharacterConnections()
	disconnectList(R.connections, true)
end
local function disconnectDashConnections()
	disconnectList(R.dashConnections, false)
	R.dashGeneration += 1
end

-- state reset
local function resetTargetState()
	R.lastTarget = -1
	R.clashPartnerId = -1
	R.wasMeTarget = nil
	R.lostMeAt = 0
	R.returnPending = false
	R.lastDirectionSwitchAt = 0
end
local function resetOwnDashState()
	R.ownDashEscapePending = false
	R.ownDashEscapeSince = 0
	R.ownDashEscapeDetectedAt = 0
	R.ownDashEscapeConfirmFrames = 0
	R.ownDashEscapeLastDist = nil
	R.ownDashEscapeFartherStreak = 0
end
local function resetDeactivationState()
	resetOwnDashState()
end
local function clearDashState()
	R.dashEvents = {}
	R.dashCooldown = {}
	R.dashTrackSnap = {}
	R.dashVelAnterior = {}
	R.dashVelFrames = {}
end

-- active state
local function setActivationLock(t, snapshot)
	R.activationDeactLockedUntil = 0
	local root = getRootPosition()
	local position = getSnapshotPosition(snapshot)
	if not root or not position or R.parryRadius <= 0 then
		return
	end
	if (root - position).Magnitude <= R.parryRadius * T.ACT_DEACT_LOCK_RADIUS_FACTOR then
		R.activationDeactLockedUntil = t + T.ACT_DEACT_LOCK_TIME
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
		R.lastDirectionSwitchAt = 0
		if R.clashPartnerId == -1 and R.lastTarget ~= R.localUserId and R.lastTarget ~= -1 then
			R.clashPartnerId = R.lastTarget
		end
		setActivationLock(t, snapshot)
	else
		R.clashPartnerId = -1
		R.reactivateBlockedUntil = t + T.REACTIVATE_COOLDOWN
		R.activationDeactLockedUntil = 0
	end
	if Utils and type(Utils.setAutoSpamActive) == "function" then
		pcall(Utils.setAutoSpamActive, active)
	end
	setPhase(active and "active" or "idle", reason)
end

-- full runtime reset
local function resetRuntime(reason, keepDashDetection)
	R.generation += 1
	if R.active then
		setActive(false, reason or "reset")
	end
	disconnectCharacterConnections()
	if not keepDashDetection then
		disconnectDashConnections()
	end
	R.bound = false
	R.boundRoot = nil
	R.lastSpeed = 0
	R.parryRadius = 0
	R.lastEvalAt = 0
	R.lastDashScanAt = 0
	R.reactivateBlockedUntil = 0
	R.activationDeactLockedUntil = 0
	resetTargetState()
	resetDeactivationState()
	clearDashState()
	R.lastGate = "detached"
	setPhase("detached", reason or "reset")
end

-- parry state
local function refreshParryRadius(t)
	if not AutoParry or type(AutoParry.getParryRadius) ~= "function" then
		return
	end
	local ok, radius = pcall(AutoParry.getParryRadius, t)
	radius = ok and tonumber(radius) or nil
	if radius and radius >= 0 then
		R.parryRadius = radius
	end
end
local function updateParryState(t, snapshot)
	R.lastSpeed = math.max(tonumber(snapshot and snapshot.speed) or 0, 0)
	refreshParryRadius(t)
end

-- activation
local function canReactivate()
	if now() < R.reactivateBlockedUntil then
		R.lastGate = "reactivate_cooldown"
		return false
	end
	return true
end
local function activationRadius()
	return R.parryRadius + R.lastSpeed * T.ACT_RADIUS_EXTRA_WINDOW
end
local function shouldActivate(snapshot)
	if not snapshot or not snapshot.ball or not snapshot.ball.Parent then
		R.lastGate = "no_ball"
		return false
	end
	local root = getRootPosition()
	if not root then
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
	if R.parryRadius <= 0 then
		R.lastGate = "no_effective_radius"
		return false
	end
	if (root - position).Magnitude > activationRadius() then
		R.lastGate = "outside_effective_radius"
		return false
	end
	R.lastGate = "activation_ready"
	return true
end

-- target return
local function tryReturnActivate(snapshot)
	if not R.returnPending or not canReactivate() then
		return false
	end
	if R.lostMeAt <= 0 then
		R.returnPending = false
		R.lostMeAt = 0
		R.lastGate = "return_without_loss"
		return false
	end
	local elapsed = now() - R.lostMeAt
	local window = getReturnWindow(R.lastSpeed)
	if elapsed < 0 or elapsed > window then
		R.returnPending = false
		R.lostMeAt = 0
		R.lastGate = "return_too_late"
		return false
	end
	return shouldActivate(snapshot)
end

-- rally check
local function rallyCheck(data)
	if not R.active or type(data) ~= "table" then
		return true
	end
	local target = normalizeTarget(data.TargetPlayerID)
	if not target or target == R.localUserId or target == R.clashPartnerId then
		return true
	end
	local position = getDataPosition(data)
	if not position then
		return true
	end
	local root = getRootPosition()
	if not root then
		return true
	end
	local speed = math.max(R.lastSpeed, tonumber(data.Speed) or 0, 0)
	if R.parryRadius <= 0 then
		return true
	end
	local effectiveRadius = R.parryRadius + speed * T.ACT_RADIUS_EXTRA_WINDOW
	if (root - position).Magnitude > effectiveRadius then
		setActive(false, "rally_outside_effective_radius")
		R.lostMeAt = 0
		R.returnPending = false
		return false
	end
	R.clashPartnerId = target
	return true
end

-- dash detection
local Dash = {}
function Dash.cleanExpired(t)
	for i = #R.dashEvents, 1, -1 do
		local event = R.dashEvents[i]
		if not event or not event.player or not event.player.Parent or t - event.detectedAt > T.DASH_DETECT_WINDOW then
			table.remove(R.dashEvents, i)
		end
	end
end
function Dash.register(player, position, velocity)
	if not player or not player.Parent then
		return
	end
	local t = now()
	local last = R.dashCooldown[player]
	if last and t - last < T.DASH_DETECT_WINDOW then
		return
	end
	R.dashCooldown[player] = t
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if typeof(position) ~= "Vector3" and root then
		position = root.Position
	end
	if typeof(velocity) ~= "Vector3" and root then
		velocity = root.AssemblyLinearVelocity
	end
	Dash.cleanExpired(t)
	R.dashEvents[#R.dashEvents + 1] = {
		player = player,
		userId = player.UserId,
		detectedAt = t,
		position = position,
		velocity = velocity,
	}
end
function Dash.isTrack(track)
	if not track or not track:IsA("AnimationTrack") then
		return false
	end
	local animation = track.Animation
	if not animation then
		return false
	end
	local name = string.lower(animation.Name or "")
	local id = string.lower(animation.AnimationId or "")
	return name:find("dash", 1, true) ~= nil or id:find("dash", 1, true) ~= nil
end
function Dash.hookAnimator(animator, player, character, generation)
	if not animator or not player then
		return
	end
	local connection = animator.AnimationPlayed:Connect(function(track)
		if generation ~= R.dashGeneration or not player.Parent or player.Character ~= character then
			return
		end
		if Dash.isTrack(track) then
			Dash.register(player)
		end
	end)
	addConnection(R.dashConnections, connection)
	local snapshot = R.dashTrackSnap[player]
	if not snapshot then
		snapshot = {}
		R.dashTrackSnap[player] = snapshot
	end
	table.clear(snapshot)
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		snapshot[track] = true
	end
end
function Dash.scanTracks(players)
	if not players then
		return
	end
	for _, player in ipairs(players:GetPlayers()) do
		if not player.Parent then
			continue
		end
		local character = player.Character
		if not character then
			continue
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			continue
		end
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			continue
		end
		local current = animator:GetPlayingAnimationTracks()
		local snapshot = R.dashTrackSnap[player]
		if not snapshot then
			snapshot = {}
			R.dashTrackSnap[player] = snapshot
		end
		for _, track in ipairs(current) do
			if not snapshot[track] and Dash.isTrack(track) then
				Dash.register(player)
			end
		end
		table.clear(snapshot)
		for _, track in ipairs(current) do
			snapshot[track] = true
		end
	end
end
function Dash.hookRoot(root, player, character, generation)
	if not root or not player then
		return
	end
	local connection = root.ChildAdded:Connect(function(child)
		if generation ~= R.dashGeneration or not player.Parent or player.Character ~= character then
			return
		end
		if DASH_PARTS[child.Name] then
			Dash.register(player)
		end
	end)
	addConnection(R.dashConnections, connection)
end
function Dash.scanVelocity(players)
	if not players then
		return
	end
	for _, player in ipairs(players:GetPlayers()) do
		if not player.Parent then
			continue
		end
		local character = player.Character
		if not character then
			continue
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root then
			continue
		end
		local velocity = root.AssemblyLinearVelocity
		local speed = horizontalSpeed(velocity)
		local previous = R.dashVelAnterior[player] or 0
		local delta = speed - previous
		if speed >= 80 and delta >= 15 then
			R.dashVelFrames[player] = (R.dashVelFrames[player] or 0) + 1
			Dash.register(player, root.Position, velocity)
			R.dashVelFrames[player] = 0
		else
			R.dashVelFrames[player] = 0
		end
		R.dashVelAnterior[player] = speed
	end
end
function Dash.attachCharacter(character, player, generation)
	if generation ~= R.dashGeneration or not character or not player or not player.Parent or player.Character ~= character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if generation ~= R.dashGeneration or player.Character ~= character or not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 5)
	if generation ~= R.dashGeneration or player.Character ~= character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
	if generation ~= R.dashGeneration or player.Character ~= character then
		return
	end
	if animator then
		Dash.hookAnimator(animator, player, character, generation)
	end
	if root then
		Dash.hookRoot(root, player, character, generation)
	end
	R.dashVelAnterior[player] = nil
	R.dashVelFrames[player] = 0
end
function Dash.hookPlayer(player, generation)
	if generation ~= R.dashGeneration or not player or not player.Parent then
		return
	end
	R.dashTrackSnap[player] = {}
	R.dashVelAnterior[player] = nil
	R.dashVelFrames[player] = 0
	if player.Character then
		task.spawn(Dash.attachCharacter, player.Character, player, generation)
	end
	local connection = player.CharacterAdded:Connect(function(character)
		if generation == R.dashGeneration then
			task.spawn(Dash.attachCharacter, character, player, generation)
		end
	end)
	addConnection(R.dashConnections, connection)
end
function Dash.init(players)
	if not players then
		return
	end
	R.dashGeneration += 1
	local generation = R.dashGeneration
	for _, player in ipairs(players:GetPlayers()) do
		Dash.hookPlayer(player, generation)
	end
	addConnection(
		R.dashConnections,
		players.PlayerAdded:Connect(function(player)
			if generation == R.dashGeneration then
				Dash.hookPlayer(player, generation)
			end
		end)
	)
	addConnection(
		R.dashConnections,
		players.PlayerRemoving:Connect(function(player)
			R.dashCooldown[player] = nil
			R.dashTrackSnap[player] = nil
			R.dashVelAnterior[player] = nil
			R.dashVelFrames[player] = nil
			for i = #R.dashEvents, 1, -1 do
				local event = R.dashEvents[i]
				if event and event.player == player then
					table.remove(R.dashEvents, i)
				end
			end
		end)
	)
end
function Dash.tick(players, t)
	if not players or t - R.lastDashScanAt < T.MIN_EVAL_INTERVAL then
		return
	end
	R.lastDashScanAt = t
	Dash.cleanExpired(t)
	Dash.scanTracks(players)
	Dash.scanVelocity(players)
end

-- own dash escape
local OwnDash = {}
function OwnDash.getOpponent()
	if R.clashPartnerId == -1 or R.clashPartnerId == R.localUserId then
		return nil
	end
	if not Utils or type(Utils.getPlayers) ~= "function" then
		return nil
	end
	local ok, players = pcall(Utils.getPlayers)
	if not ok or not players then
		return nil
	end
	local opponent = players:GetPlayerByUserId(R.clashPartnerId)
	if not opponent or not opponent.Parent then
		return nil
	end
	local character = opponent.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root.Parent then
		return nil
	end
	return opponent, root
end
function OwnDash.directionDot(velocity, fromPosition, toPosition)
	if typeof(velocity) ~= "Vector3" or typeof(fromPosition) ~= "Vector3" or typeof(toPosition) ~= "Vector3" then
		return nil
	end
	local velocityMagnitude = horizontalSpeed(velocity)
	if velocityMagnitude <= 0 then
		return nil
	end
	local delta = toPosition - fromPosition
	local distance = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)
	if distance <= 0 then
		return nil
	end
	return (velocity.X / velocityMagnitude) * (delta.X / distance) + (velocity.Z / velocityMagnitude) * (delta.Z / distance)
end
function OwnDash.getRecentThreat(t)
	if not R.active or R.clashPartnerId == -1 or R.clashPartnerId == R.localUserId then
		return nil
	end
	local _, opponentRoot = OwnDash.getOpponent()
	if not opponentRoot then
		return nil
	end
	local latest
	for i = #R.dashEvents, 1, -1 do
		local event = R.dashEvents[i]
		if event and event.userId == R.localUserId then
			local age = t - event.detectedAt
			if age >= 0 and age <= T.DASH_DETECT_WINDOW then
				latest = event
				break
			end
		end
	end
	if not latest then
		return nil
	end
	if typeof(latest.velocity) == "Vector3" and typeof(latest.position) == "Vector3" then
		local dot = OwnDash.directionDot(latest.velocity, latest.position, opponentRoot.Position)
		if dot ~= nil and dot > T.OWN_DASH_ESCAPE_DOT then
			return nil
		end
	end
	return latest
end
function OwnDash.shouldDeactivate(t)
	if not R.active then
		resetOwnDashState()
		return false
	end
	if R.wasMeTarget then
		resetOwnDashState()
		R.lastGate = "own_dash_escape_targeted_skip"
		return false
	end
	local ownRoot = getRootPosition()
	if not ownRoot then
		resetOwnDashState()
		R.lastGate = "own_dash_escape_no_root"
		return false
	end
	local opponent, opponentRoot = OwnDash.getOpponent()
	if not opponent or not opponentRoot then
		resetOwnDashState()
		R.lastGate = "own_dash_escape_no_opponent"
		return false
	end
	local event = OwnDash.getRecentThreat(t)
	-- no recent dash
	if not event then
		if R.ownDashEscapePending then
			if t - R.ownDashEscapeDetectedAt > T.DASH_DETECT_WINDOW then
				resetOwnDashState()
			else
				R.lastGate = "own_dash_escape_waiting"
			end
		else
			R.lastGate = "own_dash_escape_no_dash"
		end
		return false
	end
	-- new dash
	if not R.ownDashEscapePending or R.ownDashEscapeDetectedAt ~= event.detectedAt then
		R.ownDashEscapePending = true
		R.ownDashEscapeSince = t
		R.ownDashEscapeDetectedAt = event.detectedAt
		R.ownDashEscapeConfirmFrames = 0
		R.ownDashEscapeFartherStreak = 0
		R.ownDashEscapeLastDist = (ownRoot - opponentRoot.Position).Magnitude
		R.lastGate = "own_dash_escape_detected"
		return false
	end
	-- confirm distance increase
	local currentDistance = (ownRoot - opponentRoot.Position).Magnitude
	local previousDistance = R.ownDashEscapeLastDist
	if not previousDistance then
		R.ownDashEscapeLastDist = currentDistance
		R.ownDashEscapeFartherStreak = 0
		R.lastGate = "own_dash_escape_first"
		return false
	end
	if currentDistance > previousDistance then
		R.ownDashEscapeFartherStreak += 1
		R.ownDashEscapeConfirmFrames = R.ownDashEscapeFartherStreak
		R.ownDashEscapeLastDist = currentDistance
		R.lastGate = "own_dash_escape_farther_" .. R.ownDashEscapeFartherStreak
		return R.ownDashEscapeFartherStreak >= T.OWN_DASH_ESCAPE_CONFIRM_FRAMES
	end
	-- distance stopped / decreased
	R.ownDashEscapeFartherStreak = 0
	R.ownDashEscapeConfirmFrames = 0
	R.ownDashEscapeLastDist = currentDistance
	R.lastGate = "own_dash_escape_not_farther"
	return false
end

-- deactivation
local Deactivation = {}
function Deactivation.ballStopped(speed)
	return speed == 0
end
function Deactivation.direction(t, snapshot, distance, radius, speed)
	if snapshot.targeted == true then
		R.lastGate = "deact_direction_targeted"
		return false
	end
	local minimumRadius = radius * T.DEACT_DIRECTION_MIN_RADIUS_FACTOR
	if distance <= minimumRadius then
		R.lastGate = "deact_direction_inside_radius"
		return false
	end
	local directionMax = math.max(lerpBySpeed(speed, T.DEACT_DIRECTION_MAX_LO, T.DEACT_DIRECTION_MAX_LO * T.DEACT_DIRECTION_MAX_MIN_FACTOR, T.DEACT_DIRECTION_SPD_LO, T.DEACT_DIRECTION_SPD_HI), T.MIN_EVAL_INTERVAL * 1.5)
	if R.lastDirectionSwitchAt <= 0 then
		return false
	end
	if t - R.lastDirectionSwitchAt > directionMax then
		R.lastGate = "deact_direction"
		return true
	end
	return false
end
function Deactivation.shouldDeactivate(t, snapshot)
	if OwnDash.shouldDeactivate(t) then
		R.lastGate = "own_dash_escape"
		return true
	end
	if t < R.activationDeactLockedUntil then
		R.lastGate = "deact_activation_lock"
		return false
	end
	local root = getRootPosition()
	local position = getSnapshotPosition(snapshot)
	if not root or not position then
		R.lastGate = "deact_no_position"
		return false
	end
	local radius = R.parryRadius
	if radius <= 0 then
		R.lastGate = "deact_no_radius"
		return false
	end
	local speed = math.max(R.lastSpeed, 0)
	local distance = (root - position).Magnitude
	if Deactivation.ballStopped(speed) then
		R.lastGate = "deact_ball_stopped"
		return true
	end
	if Deactivation.direction(t, snapshot, distance, radius, speed) then
		return true
	end
	R.lastGate = "deact_none"
	return false
end

-- main clash evaluation
local function evaluateClash(t, snapshot)
	if not R.boundRoot or not R.boundRoot.Parent or not snapshot or not snapshot.ball or not snapshot.ball.Parent then
		return
	end
	updateParryState(t, snapshot)
	-- active
	if R.active then
		if Deactivation.shouldDeactivate(t, snapshot) then
			setActive(false, "target_deactivated")
		end
		return
	end
	-- return activation
	if tryReturnActivate(snapshot) then
		R.lostMeAt = 0
		R.returnPending = false
		setActive(true, "activated", snapshot)
	end
end

-- player service
local function getPlayersService()
	if not Utils or type(Utils.getPlayers) ~= "function" then
		return nil
	end
	local ok, players = pcall(Utils.getPlayers)
	return ok and players or nil
end

-- hub state
local function checkHubState()
	if not Utils then
		R.lastGate = "no_utils"
		return false
	end
	local ok, manual = pcall(Utils.isManualSpamActive)
	if not ok or manual then
		if R.active then
			setActive(false, "manual_spam")
		end
		resetTargetState()
		R.lastGate = "manual_spam"
		return false
	end
	ok, manual = pcall(Utils.isActive)
	if not ok or not manual then
		if R.active then
			setActive(false, "hub_inactive")
		end
		resetTargetState()
		R.lastGate = "hub_inactive"
		return false
	end
	local config
	ok, config = pcall(Utils.getConfig)
	if not ok or type(config) ~= "table" or not config.AutoClash then
		if R.active then
			setActive(false, "hub_disabled")
		end
		resetTargetState()
		R.lastGate = "hub_disabled"
		return false
	end
	return true
end

-- heartbeat
local function heartbeatStep(generation, character, root, _dt)
	if generation ~= R.generation or not character.Parent or not root.Parent then
		return
	end
	local t = now()
	if not checkHubState() then
		return
	end
	local players = getPlayersService()
	if players then
		Dash.tick(players, t)
	end
	if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
		return
	end
	R.lastEvalAt = t
	if not GameInfo or type(GameInfo.getSnapshot) ~= "function" or type(GameInfo.isSnapshotValid) ~= "function" then
		R.lastGate = "no_gameinfo"
		return
	end
	local ok, snapshot = pcall(GameInfo.getSnapshot, R.lastTarget, t)
	if not ok or type(snapshot) ~= "table" then
		R.lastGate = "snapshot_error"
		return
	end
	ok = pcall(GameInfo.isSnapshotValid, snapshot, t)
	if not ok then
		return
	end
	local valid
	local validOk, validResult = pcall(GameInfo.isSnapshotValid, snapshot, t)
	if not validOk or validResult ~= true then
		return
	end
	valid = true
	if not valid then
		return
	end
	local target = normalizeTarget(snapshot.targetId)
	if target then
		R.lastTarget = target
	end
	evaluateClash(t, snapshot)
end

-- character binding
local function bindCharacter(character)
	resetRuntime("rebind", true)
	local generation = R.generation
	if not character or not character.Parent then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
	if generation ~= R.generation or not root or not root.Parent then
		return false
	end
	R.boundRoot = root
	R.lastGate = "waiting_for_character"
	if not Utils or type(Utils.getRunService) ~= "function" then
		R.boundRoot = nil
		R.lastGate = "no_run_service"
		return false
	end
	local ok, runService = pcall(Utils.getRunService)
	if not ok or not runService or not runService.Heartbeat then
		R.boundRoot = nil
		R.lastGate = "no_run_service"
		return false
	end
	-- heartbeat
	local heartbeat = runService.Heartbeat:Connect(function(dt)
		heartbeatStep(generation, character, root, dt)
	end)
	addConnection(R.connections, heartbeat)
	if type(Utils.trackCharacter) == "function" then
		pcall(Utils.trackCharacter, heartbeat)
	end
	-- character lifetime
	local ancestry = character.AncestryChanged:Connect(function(_, parent)
		if parent then
			return
		end
		resetRuntime("character_removed", false)
		R.lastGate = "character_removed"
	end)
	addConnection(R.connections, ancestry)
	if type(Utils.trackCharacter) == "function" then
		pcall(Utils.trackCharacter, ancestry)
	end
	R.bound = true
	setPhase("waiting", "character_bound")
	-- dash system
	if #R.dashConnections == 0 then
		local players = getPlayersService()
		if players then
			Dash.init(players)
		end
	end
	return true
end

-- ball sync
function AutoClash.onBallSync(data)
	if type(data) ~= "table" or not Utils or not R.localUserId then
		return
	end
	-- teleport
	if data.Teleported == true then
		if R.active then
			setActive(false, "teleported")
		end
		resetTargetState()
		R.lastGate = "teleported"
		return
	end
	-- target
	local target = normalizeTarget(data.TargetPlayerID)
	if not target then
		if R.active then
			setActive(false, "invalid_target")
		end
		resetTargetState()
		R.lastGate = "invalid_target"
		return
	end
	local previousTarget = R.lastTarget
	R.lastTarget = target
	local wasMe = R.wasMeTarget
	local isMe = target == R.localUserId
	-- first sync
	if wasMe == nil then
		R.wasMeTarget = isMe
		R.lastGate = isMe and "initial_me" or "initial_not_me"
		return
	end
	local t = now()
	-- target switch
	if wasMe ~= isMe then
		R.lastDirectionSwitchAt = t
	end
	-- we lost the ball
	if wasMe and not isMe then
		if R.active then
			if not rallyCheck(data) then
				R.wasMeTarget = isMe
				return
			end
		else
			R.clashPartnerId = target
		end
		R.lostMeAt = t
		R.returnPending = false
		R.lastGate = "target_lost"
	-- ball returned to us
	elseif not wasMe and isMe then
		if previousTarget ~= -1 and previousTarget ~= R.localUserId then
			R.clashPartnerId = previousTarget
		end
		if R.lostMeAt <= 0 then
			R.returnPending = false
			R.lastGate = "return_without_loss"
		else
			local elapsed = t - R.lostMeAt
			local window = getReturnWindow(R.lastSpeed)
			if elapsed >= 0 and elapsed <= window then
				R.returnPending = true
				R.lastGate = "target_return"
			else
				R.lostMeAt = 0
				R.returnPending = false
				R.lastGate = "return_too_late"
			end
		end
	end
	R.wasMeTarget = isMe
end

-- setup
function AutoClash.setup(deps)
	if type(deps) ~= "table" then
		return false
	end
	local required = {
		{ "AutoParry", "getParryRadius" },
		{ "AutoParry", "getPingOneWay" },
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
	for _, requirement in ipairs(required) do
		local object = deps[requirement[1]]
		if not object or type(object[requirement[2]]) ~= "function" then
			return false
		end
	end
	-- clean old instance
	if Utils then
		resetRuntime("setup", false)
	else
		disconnectDashConnections()
		disconnectCharacterConnections()
	end
	-- dependencies
	AutoParry = deps.AutoParry
	GameInfo = deps.GameInfo
	Utils = deps.Utils
	-- local player
	local player
	local ok = pcall(function()
		player = Utils.getLocalPlayer()
	end)
	if not ok or not player then
		AutoParry = nil
		GameInfo = nil
		Utils = nil
		return false
	end
	R.localUserId = player.UserId
	-- state
	R.generation = 0
	R.bound = false
	R.active = false
	R.phase = "detached"
	R.boundRoot = nil
	R.lastSpeed = 0
	R.parryRadius = 0
	R.lastEvalAt = 0
	R.lastDashScanAt = 0
	R.reactivateBlockedUntil = 0
	R.activationDeactLockedUntil = 0
	R.connections = {}
	R.dashConnections = {}
	R.dashGeneration = 0
	resetTargetState()
	resetDeactivationState()
	clearDashState()
	R.lastGate = "none"
	-- dash init
	local players = getPlayersService()
	if players then
		Dash.init(players)
	end
	return true
end

-- public character api
function AutoClash.bindCharacter(character)
	return bindCharacter(character)
end
function AutoClash.detachCharacter()
	resetRuntime("detach", false)
end
function AutoClash.teardown()
	resetRuntime("teardown", false)
	AutoParry = nil
	GameInfo = nil
	Utils = nil
end

-- public state api
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
		ownDashEscapePending = R.ownDashEscapePending == true,
		ownDashEscapeConfirmFrames = R.ownDashEscapeConfirmFrames,
	}
end

-- contract
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
