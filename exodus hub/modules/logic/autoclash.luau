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

	-- activation -> deactivation lock
	ACT_DEACT_LOCK_RADIUS_FACTOR = 0.60,
	ACT_DEACT_LOCK_TIME = 0.050,

	-- dash-threat gate
	DASH_DETECT_WINDOW = 0.450,
	DEACT_COOLDOWN = 0.100,

	-- own dash escape deactivation
	OWN_DASH_ESCAPE_DELAY = 0.030,
	OWN_DASH_TTI_MIN_GAIN = 30,

	-- deactivation: travel
	DEACT_TRAVEL_RADIUS_SCALE = 1.2,
	DEACT_TRAVEL_MAX_LO = 0.090,
	DEACT_TRAVEL_MAX_MIN_FACTOR = 0.10,
	DEACT_TRAVEL_SPD_LO = 60,
	DEACT_TRAVEL_SPD_HI = 600,
	DEACT_TRAVEL_RADIUS_FACTOR = 1.10,

	-- deactivation: direction
	DEACT_DIRECTION_MAX_LO = 0.035,
	DEACT_DIRECTION_MAX_MIN_FACTOR = 0.10,
	DEACT_DIRECTION_MIN_RADIUS_FACTOR = 0.55,

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

	-- target return state
	lostMeAt = 0,
	returnPending = false,
	wasMeTarget = nil,

	-- direction state
	lastDirectionSwitchAt = 0,

	-- deactivation state
	outSince = 0,
	travelSince = 0,

	-- evaluation
	lastEvalAt = 0,
	reactivateBlockedUntil = 0,
	activationDeactLockedUntil = 0,

	-- character/runtime connections
	connections = {},

	-- dash detector connections
	dashConnections = {},
	dashGeneration = 0,

	lastGate = "none",

	-- dash-threat gate
	dashGateActive = false,
	dashGateTriggerUserId = nil,
	deactivateCooldownUntil = 0,

	-- own dash escape gate
	ownDashEscapePending = false,
	ownDashEscapeSince = 0,
	ownDashEscapeDetectedAt = 0,
	ownDashEscapeInitialTti = nil,

	-- internal dash detection state
	dashEvents = {},
	dashCooldown = {},
	dashTrackSnap = {},
	dashVelAnterior = {},
	dashVelFrames = {},
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

local function now()
	if not Utils or type(Utils.now) ~= "function" then
		return 0
	end

	local ok, value = pcall(Utils.now)

	if not ok then
		return 0
	end

	return tonumber(value) or 0
end

local function pingOneWay()
	if not AutoParry or type(AutoParry.getPingOneWay) ~= "function" then
		return 0
	end

	local ok, value = pcall(AutoParry.getPingOneWay)

	if not ok then
		return 0
	end

	return math.max(tonumber(value) or 0, 0)
end

local function rootPosition()
	local root = R.boundRoot

	if not (root and root.Parent) then
		return nil
	end

	local ok, position = pcall(function()
		return root.Position
	end)

	if not ok or typeof(position) ~= "Vector3" then
		return nil
	end

	return position
end

local function snapshotPosition(snapshot)
	local position = snapshot and snapshot.position

	if typeof(position) ~= "Vector3" then
		return nil
	end

	return position
end

local function dataPosition(data)
	local position = data and data.RealPosition

	if typeof(position) ~= "Vector3" then
		return nil
	end

	return position
end

local function lerp(speed, lo, hi, speedLo, speedHi)
	speed = tonumber(speed) or 0

	if speedHi <= speedLo then
		return lo
	end

	local alpha = math.clamp(
		(speed - speedLo) / (speedHi - speedLo),
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

	local raw = base + pingOneWay() * T.PING_FACTOR

	return math.max(
		raw,
		T.MIN_EVAL_INTERVAL * 1.5
	)
end

local function resetTargetState()
	R.lastTarget = -1
	R.clashPartnerId = -1
	R.wasMeTarget = nil
	R.lostMeAt = 0
	R.returnPending = false
	R.lastDirectionSwitchAt = 0
end

local function resetDeactivationState()
	R.outSince = 0
	R.travelSince = 0

	R.ownDashEscapePending = false
	R.ownDashEscapeSince = 0
	R.ownDashEscapeDetectedAt = 0
	R.ownDashEscapeInitialTti = nil
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

-- connection helpers
local function addConnection(list, connection)
	if connection then
		list[#list + 1] = connection
	end

	return connection
end

local function disconnectList(list, useUtilsTracking)
	for i = #list, 1, -1 do
		local connection = list[i]
		list[i] = nil

		if connection then
			if useUtilsTracking
				and Utils
				and type(Utils.untrackCharacter) == "function"
			then
				pcall(
					Utils.untrackCharacter,
					connection
				)
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

	R.dashGeneration = R.dashGeneration + 1
end

-- activation state
local function setActivationLock(t, snapshot)
	R.activationDeactLockedUntil = 0

	local root = rootPosition()
	local position = snapshotPosition(snapshot)
	local radius = R.parryRadius

	if not root or not position or radius <= 0 then
		return
	end

	local distance = (root - position).Magnitude

	if distance <= radius * T.ACT_DEACT_LOCK_RADIUS_FACTOR then
		R.activationDeactLockedUntil =
			t + T.ACT_DEACT_LOCK_TIME
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

		R.deactivateCooldownUntil =
			t + T.DEACT_COOLDOWN

		if R.clashPartnerId == -1
			and R.lastTarget ~= R.localUserId
		then
			R.clashPartnerId = R.lastTarget
		end

		setActivationLock(t, snapshot)
	else
		R.clashPartnerId = -1

		R.reactivateBlockedUntil =
			t + T.REACTIVATE_COOLDOWN

		R.activationDeactLockedUntil = 0

		R.dashGateActive = false
		R.dashGateTriggerUserId = nil

		R.deactivateCooldownUntil = 0
	end

	if Utils and type(Utils.setAutoSpamActive) == "function" then
		pcall(
			Utils.setAutoSpamActive,
			active
		)
	end

	setPhase(
		active and "active" or "idle",
		reason
	)
end

-- runtime
local function resetRuntime(reason, keepDashDetection)
	R.generation = R.generation + 1

	if R.active then
		setActive(
			false,
			reason or "reset"
		)
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

	R.reactivateBlockedUntil = 0
	R.activationDeactLockedUntil = 0

	resetTargetState()
	resetDeactivationState()

	R.dashGateActive = false
	R.dashGateTriggerUserId = nil
	R.deactivateCooldownUntil = 0

	R.dashEvents = {}
	R.dashCooldown = {}
	R.dashTrackSnap = {}
	R.dashVelAnterior = {}
	R.dashVelFrames = {}

	R.lastGate = "detached"

	setPhase(
		"detached",
		reason or "reset"
	)
end

-- rally
local function rallyCheck(data)
	if not R.active or type(data) ~= "table" then
		return true
	end

	local target = normalizeTarget(
		data.TargetPlayerID
	)

	if not target
		or target == R.localUserId
		or target == R.clashPartnerId
	then
		return true
	end

	local position = dataPosition(data)

	if not position then
		return true
	end

	local root = rootPosition()

	if not root then
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
		setActive(
			false,
			"rally_outside_effective_radius"
		)

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
	local t = now()

	if t < R.reactivateBlockedUntil then
		R.lastGate = "reactivate_cooldown"
		return false
	end

	return true
end

-- [[ Dash detection ]]

local DASH_DETECT_PARTS = {
	DashEffect = true,
	WindDash = true,
	Dash = true,
}

local function dashCleanExpired(atTs)
	for i = #R.dashEvents, 1, -1 do
		local ev = R.dashEvents[i]

		if not ev
			or not ev.player
			or not ev.player.Parent
			or (atTs - ev.detectedAt)
				> T.DASH_DETECT_WINDOW
		then
			table.remove(
				R.dashEvents,
				i
			)
		end
	end
end

-- IMPORTANT:
-- This function DOES NOT ignore the local player.
-- Filtering local/enemy player is done by the individual gate
-- that consumes the dash event.
local function dashRegister(player, position, velocity)
	if not player or not player.Parent then
		return
	end

	local ts = now()

	local ultimo = R.dashCooldown[player]

	if ultimo
		and (ts - ultimo) < T.DASH_DETECT_WINDOW
	then
		return
	end

	R.dashCooldown[player] = ts

	local character = player.Character
	local hrp = character
		and character:FindFirstChild(
			"HumanoidRootPart"
		)

	if typeof(position) ~= "Vector3" then
		if hrp then
			position = hrp.Position
		else
			position = nil
		end
	end

	if typeof(velocity) ~= "Vector3"
		and hrp
	then
		velocity = hrp.AssemblyLinearVelocity
	end

	dashCleanExpired(ts)

	R.dashEvents[#R.dashEvents + 1] = {
		player = player,
		userId = player.UserId,
		detectedAt = ts,
		position = position,
		velocity = velocity,
	}
end

local function dashIsDashTrack(track)
	if not track
		or not track:IsA("AnimationTrack")
	then
		return false
	end

	local anim = track.Animation

	if not anim then
		return false
	end

	local nome = string.lower(
		anim.Name or ""
	)

	local id = string.lower(
		anim.AnimationId or ""
	)

	return nome:find("dash", 1, true) ~= nil
		or id:find("dash", 1, true) ~= nil
end

local function dashHookAnimator(animator, player)
	if not animator or not player then
		return
	end

	local connection =
		animator.AnimationPlayed:Connect(function(track)
			if not player.Parent then
				return
			end

			if dashIsDashTrack(track) then
				dashRegister(
					player,
					nil
				)
			end
		end)

	addConnection(
		R.dashConnections,
		connection
	)

	local snap =
		R.dashTrackSnap[player]

	if not snap then
		snap = {}
		R.dashTrackSnap[player] = snap
	end

	table.clear(snap)

	for _, track in ipairs(
		animator:GetPlayingAnimationTracks()
	) do
		snap[track] = true
	end
end

local function dashScanTracks(playersService)
	if not playersService then
		return
	end

	for _, player in ipairs(
		playersService:GetPlayers()
	) do
		if not player.Parent then
			continue
		end

		local character = player.Character

		if not character then
			continue
		end

		local humanoid =
			character:FindFirstChildOfClass(
				"Humanoid"
			)

		if not humanoid then
			continue
		end

		local animator =
			humanoid:FindFirstChildOfClass(
				"Animator"
			)

		if not animator then
			continue
		end

		local current =
			animator:GetPlayingAnimationTracks()

		local snap =
			R.dashTrackSnap[player]

		if not snap then
			snap = {}
			R.dashTrackSnap[player] = snap
		end

		for _, track in ipairs(current) do
			if not snap[track]
				and dashIsDashTrack(track)
			then
				dashRegister(
					player,
					nil
				)
			end
		end

		table.clear(snap)

		for _, track in ipairs(current) do
			snap[track] = true
		end
	end
end

local function dashHookHRP(hrp, player)
	if not hrp or not player then
		return
	end

	local connection =
		hrp.ChildAdded:Connect(function(child)
			if not player.Parent then
				return
			end

			if DASH_DETECT_PARTS[child.Name] then
				dashRegister(
					player,
					nil
				)
			end
		end)

	addConnection(
		R.dashConnections,
		connection
	)
end

local function dashScanVelocity(playersService)
	if not playersService then
		return
	end

	for _, player in ipairs(
		playersService:GetPlayers()
	) do
		if not player.Parent then
			continue
		end

		local character = player.Character

		if not character then
			continue
		end

		local hrp =
			character:FindFirstChild(
				"HumanoidRootPart"
			)

		if not hrp then
			continue
		end

		local velocity =
			hrp.AssemblyLinearVelocity

		local speed = math.sqrt(
			velocity.X * velocity.X
				+ velocity.Z * velocity.Z
		)

		local anterior =
			R.dashVelAnterior[player] or 0

		local delta = speed - anterior

		if speed >= 80 and delta >= 15 then
			R.dashVelFrames[player] =
				(R.dashVelFrames[player] or 0) + 1

			if R.dashVelFrames[player] >= 1 then
				dashRegister(
					player,
					hrp.Position,
					velocity
				)

				R.dashVelFrames[player] = 0
			end
		else
			R.dashVelFrames[player] = 0
		end

		R.dashVelAnterior[player] = speed
	end
end

local function dashAttachCharacter(
	character,
	player,
	playersService,
	dashGeneration
)
	if dashGeneration ~= R.dashGeneration then
		return
	end

	if not character
		or not player
		or not player.Parent
	then
		return
	end

	local humanoid =
		character:FindFirstChildOfClass(
			"Humanoid"
		)

	if not humanoid then
		humanoid =
			character:WaitForChild(
				"Humanoid",
				5
			)
	end

	if dashGeneration ~= R.dashGeneration then
		return
	end

	if not humanoid then
		return
	end

	local animator =
		humanoid:FindFirstChildOfClass(
			"Animator"
		)

	if not animator then
		animator =
			humanoid:WaitForChild(
				"Animator",
				5
			)
	end

	if dashGeneration ~= R.dashGeneration then
		return
	end

	local hrp =
		character:FindFirstChild(
			"HumanoidRootPart"
		)

	if not hrp then
		hrp =
			character:WaitForChild(
				"HumanoidRootPart",
				5
			)
	end

	if dashGeneration ~= R.dashGeneration then
		return
	end

	if animator then
		dashHookAnimator(
			animator,
			player
		)
	end

	if hrp then
		dashHookHRP(
			hrp,
			player
		)
	end

	R.dashVelAnterior[player] = nil
	R.dashVelFrames[player] = 0
end

local function dashHookPlayer(
	player,
	playersService,
	dashGeneration
)
	if dashGeneration ~= R.dashGeneration then
		return
	end

	if not player or not player.Parent then
		return
	end

	R.dashTrackSnap[player] = {}
	R.dashVelAnterior[player] = nil
	R.dashVelFrames[player] = 0

	if player.Character then
		task.spawn(
			dashAttachCharacter,
			player.Character,
			player,
			playersService,
			dashGeneration
		)
	end

	local connection =
		player.CharacterAdded:Connect(
			function(character)
				if dashGeneration
					~= R.dashGeneration
				then
					return
				end

				task.spawn(
					dashAttachCharacter,
					character,
					player,
					playersService,
					dashGeneration
				)
			end
		)

	addConnection(
		R.dashConnections,
		connection
	)
end

local function dashDetectionInit(playersService)
	if not playersService then
		return
	end

	R.dashGeneration =
		R.dashGeneration + 1

	local dashGeneration =
		R.dashGeneration

	for _, player in ipairs(
		playersService:GetPlayers()
	) do
		dashHookPlayer(
			player,
			playersService,
			dashGeneration
		)
	end

	local playerAddedConnection =
		playersService.PlayerAdded:Connect(
			function(player)
				if dashGeneration
					~= R.dashGeneration
				then
					return
				end

				dashHookPlayer(
					player,
					playersService,
					dashGeneration
				)
			end
		)

	addConnection(
		R.dashConnections,
		playerAddedConnection
	)

	local playerRemovingConnection =
		playersService.PlayerRemoving:Connect(
			function(player)
				R.dashCooldown[player] = nil
				R.dashTrackSnap[player] = nil
				R.dashVelAnterior[player] = nil
				R.dashVelFrames[player] = nil

				for i = #R.dashEvents, 1, -1 do
					local ev = R.dashEvents[i]

					if ev
						and ev.player == player
					then
						table.remove(
							R.dashEvents,
							i
						)
					end
				end
			end
		)

	addConnection(
		R.dashConnections,
		playerRemovingConnection
	)
end

local function dashDetectionTick(playersService)
	dashScanTracks(playersService)
	dashScanVelocity(playersService)
end

-- [[ Own dash escape detection ]]

local function getOpponentForOwnDash()
	if R.clashPartnerId == -1
		or R.clashPartnerId == R.localUserId
	then
		return nil
	end

	local playersService =
		game:GetService("Players")

	local opponent =
		playersService:GetPlayerByUserId(
			R.clashPartnerId
		)

	if not opponent
		or not opponent.Parent
	then
		return nil
	end

	local character = opponent.Character

	local root =
		character
		and character:FindFirstChild(
			"HumanoidRootPart"
		)

	if not root
		or not root.Parent
	then
		return nil
	end

	return opponent, root
end

local function getBallPositionForTti()
	if not GameInfo
		or type(GameInfo.getSnapshot)
			~= "function"
	then
		return nil
	end

	local t = now()

	local ok, snapshot =
		pcall(
			GameInfo.getSnapshot,
			R.lastTarget,
			t
		)

	if not ok
		or type(snapshot) ~= "table"
	then
		return nil
	end

	if not snapshot.ball
		or not snapshot.ball.Parent
	then
		return nil
	end

	local position =
		snapshotPosition(snapshot)

	if not position then
		return nil
	end

	local speed =
		math.max(
			tonumber(snapshot.speed)
				or R.lastSpeed
				or 0,
			0
		)

	if speed <= 0 then
		return nil
	end

	return position, speed
end

local function getOwnDashTti()
	local ballPosition, ballSpeed =
		getBallPositionForTti()

	local ownPosition =
		rootPosition()

	if not ballPosition
		or not ownPosition
		or ballSpeed <= 0
	then
		return nil
	end

	local distance =
		(ballPosition - ownPosition).Magnitude

	return (distance / ballSpeed) * 1000
end

local function getOwnDashThreat(t)
	if not R.active then
		return nil
	end

	if not R.clashPartnerId
		or R.clashPartnerId == -1
		or R.clashPartnerId == R.localUserId
	then
		return nil
	end

	local _, opponentRoot =
		getOpponentForOwnDash()

	if not opponentRoot then
		return nil
	end

	local bestEvent = nil
	local bestScore = -math.huge

	for i = 1, #R.dashEvents do
		local ev = R.dashEvents[i]

		if not ev then
			continue
		end

		if ev.userId ~= R.localUserId then
			continue
		end

		local age = t - ev.detectedAt

		if age < 0
			or age > T.DASH_DETECT_WINDOW
		then
			continue
		end

		local score =
			-age

		if score > bestScore then
			bestScore = score
			bestEvent = ev
		end
	end

	return bestEvent
end

local function tryOwnDashEscapeDeactivate(t)
	if not R.active then
		R.ownDashEscapePending = false
		R.ownDashEscapeSince = 0
		R.ownDashEscapeDetectedAt = 0
		R.ownDashEscapeInitialTti = nil
		return false
	end

	local event =
		getOwnDashThreat(t)

	if not event then
		return false
	end

	if not R.ownDashEscapePending
		or R.ownDashEscapeDetectedAt
			~= event.detectedAt
	then
		local initialTti =
			getOwnDashTti()

		if not initialTti then
			return false
		end

		R.ownDashEscapePending = true
		R.ownDashEscapeSince = t
		R.ownDashEscapeDetectedAt =
			event.detectedAt
		R.ownDashEscapeInitialTti =
			initialTti

		R.lastGate =
			"own_dash_escape_pending"
	end

	local elapsed =
		t - R.ownDashEscapeSince

	if elapsed < T.OWN_DASH_ESCAPE_DELAY then
		R.lastGate =
			"own_dash_escape_delay"

		return false
	end

	local currentTti =
		getOwnDashTti()

	if not currentTti then
		R.lastGate =
			"own_dash_escape_no_tti"

		return false
	end

	if currentTti
		>= R.ownDashEscapeInitialTti
			+ T.OWN_DASH_TTI_MIN_GAIN
	then
		R.lastGate =
			"own_dash_escape"

		return true
	end

	R.ownDashEscapePending = false
	R.ownDashEscapeSince = 0
	R.ownDashEscapeDetectedAt = 0
	R.ownDashEscapeInitialTti = nil

	R.lastGate =
		"own_dash_escape_no_gain"

	return false
end

-- dash-threat gate
local function tryDashActivate(snapshot)
	local root = rootPosition()
	local position = snapshotPosition(snapshot)

	if not root or not position then
		R.lastGate =
			"dash_no_root_or_pos"

		return false
	end

	local radius = R.parryRadius

	if radius <= 0 then
		R.lastGate = "dash_no_radius"
		return false
	end

	local t = now()

	dashCleanExpired(t)

	if #R.dashEvents == 0 then
		return false
	end

	local ballSpeed =
		math.max(
			tonumber(snapshot.speed)
				or R.lastSpeed
				or 0,
			1
		)

	local ballDistance =
		(root - position).Magnitude

	local ballArrival =
		ballDistance / ballSpeed

	if ballArrival > T.DASH_DETECT_WINDOW then
		R.lastGate =
			"dash_ball_too_far"

		return false
	end

	local bestUserId = nil
	local bestEvent = nil
	local bestDirDot = 0
	local bestArrival = 0
	local bestScore = -math.huge

	for i = 1, #R.dashEvents do
		local ev = R.dashEvents[i]

		if not ev then
			continue
		end

		local userId = ev.userId

		-- IMPORTANT:
		-- Local player is ignored ONLY here,
		-- because this gate detects enemy dash threats.
		if not userId
			or userId == R.localUserId
		then
			continue
		end

		local player = ev.player

		if not player
			or not player.Parent
		then
			continue
		end

		local dasherPos = ev.position

		if typeof(dasherPos)
			~= "Vector3"
		then
			local char = player.Character

			local hrp =
				char
				and char:FindFirstChild(
					"HumanoidRootPart"
				)

			if hrp then
				dasherPos = hrp.Position
			end
		end

		if typeof(dasherPos)
			~= "Vector3"
		then
			continue
		end

		local toRoot =
			root - dasherPos

		local distToRoot =
			toRoot.Magnitude

		if distToRoot <= 0 then
			continue
		end

		local char = player.Character

		local hrp =
			char
			and char:FindFirstChild(
				"HumanoidRootPart"
			)

		if not hrp then
			continue
		end

		local velocity =
			hrp.AssemblyLinearVelocity

		local dasherSpeed =
			math.sqrt(
				velocity.X * velocity.X
					+ velocity.Z * velocity.Z
			)

		if dasherSpeed < 1 then
			dasherSpeed = 1
		end

		local arrival =
			distToRoot / dasherSpeed

		if arrival > T.DASH_DETECT_WINDOW then
			continue
		end

		local dirDot = 1.0

		local vMag =
			math.sqrt(
				velocity.X * velocity.X
					+ velocity.Z * velocity.Z
			)

		if vMag > 0 then
			local nx =
				velocity.X / vMag

			local nz =
				velocity.Z / vMag

			local rx =
				toRoot.X / distToRoot

			local rz =
				toRoot.Z / distToRoot

			dirDot =
				nx * rx + nz * rz
		end

		if dirDot < 0.5 then
			continue
		end

		local age =
			t - ev.detectedAt

		local score =
			(1 + dirDot * 0.3)
			- arrival * 0.5
			- age * 0.5

		if score > bestScore then
			bestScore = score
			bestUserId = userId
			bestEvent = ev
			bestDirDot = dirDot
			bestArrival = arrival
		end
	end

	if not bestEvent then
		R.lastGate =
			"dash_no_match"

		return false
	end

	R.dashGateActive = true
	R.dashGateTriggerUserId =
		bestUserId

	R.lastGate =
		"dash_gate_activate"

	local _ = bestDirDot
	local _arrival = bestArrival

	return true
end

local function tryReturnActivate(snapshot)
	if not R.returnPending then
		return false
	end

	if not canReactivate() then
		return false
	end

	local lostAt = R.lostMeAt

	if lostAt <= 0 then
		R.lostMeAt = 0
		R.returnPending = false

		R.lastGate =
			"return_without_loss"

		return false
	end

	local t = now()

	local elapsed =
		t - lostAt

	local window =
		returnWindow(R.lastSpeed)

	if elapsed < 0
		or elapsed > window
	then
		R.lostMeAt = 0
		R.returnPending = false

		R.lastGate =
			"return_too_late"

		return false
	end

	return shouldActivate(snapshot)
end

local function shouldDeactivate(t, snapshot)
	-- Own dash escape by real TTI has priority over
	-- cooldown and activation deactivation lock.
	if tryOwnDashEscapeDeactivate(t) then
		return true
	end

	if t < R.deactivateCooldownUntil then
		R.lastGate = "deact_cooldown"
		return false
	end

	if t < R.activationDeactLockedUntil then
		R.lastGate =
			"deact_activation_lock"

		return false
	end

	local root = rootPosition()
	local position = snapshotPosition(snapshot)

	if not root or not position then
		R.lastGate =
			"deact_no_position"

		return false
	end

	local radius = R.parryRadius

	if radius <= 0 then
		R.lastGate =
			"deact_no_radius"

		return false
	end

	local speed =
		math.max(
			tonumber(R.lastSpeed) or 0,
			0
		)

	local distance =
		(root - position).Magnitude

	local directionMinRadius =
		radius * T.DEACT_DIRECTION_MIN_RADIUS_FACTOR

	local insideDirectionRadius =
		distance <= directionMinRadius

	-- Travel remains unchanged.
	if distance > radius
		and speed > 0
	then
		local travelRadius =
			radius * T.DEACT_TRAVEL_RADIUS_SCALE

		local baseMax =
			lerp(
				speed,
				T.DEACT_TRAVEL_MAX_LO,
				T.DEACT_TRAVEL_MAX_LO
					* T.DEACT_TRAVEL_MAX_MIN_FACTOR,
				T.DEACT_TRAVEL_SPD_LO,
				T.DEACT_TRAVEL_SPD_HI
			)

		local radiusTime =
			(
				travelRadius
				* T.DEACT_TRAVEL_RADIUS_FACTOR
			) / speed

		local radiusMax =
			lerp(
				speed,
				radiusTime,
				radiusTime
					* T.DEACT_TRAVEL_MAX_MIN_FACTOR,
				T.DEACT_TRAVEL_SPD_LO,
				T.DEACT_TRAVEL_SPD_HI
			)

		local travelMax =
			math.max(
				baseMax,
				radiusMax
			)

		if distance / speed > travelMax then
			R.lastGate =
				"deact_travel"

			return true
		end
	end

	-- Direction gate is still allowed.
	if snapshot.targeted == true then
		R.lastGate =
			"deact_direction_targeted"

		return false
	end

	if insideDirectionRadius then
		R.lastGate =
			"deact_direction_inside_radius"

		return false
	end

	local directionMax =
		math.max(
			lerp(
				speed,
				T.DEACT_DIRECTION_MAX_LO,
				T.DEACT_DIRECTION_MAX_LO
					* T.DEACT_DIRECTION_MAX_MIN_FACTOR,
				T.DEACT_TRAVEL_SPD_LO,
				T.DEACT_TRAVEL_SPD_HI
			),
			T.MIN_EVAL_INTERVAL * 1.5
		)

	if R.lastDirectionSwitchAt > 0
		and (t - R.lastDirectionSwitchAt)
			> directionMax
	then
		R.lastGate =
			"deact_direction"

		return true
	end

	R.lastGate =
		"deact_none"

	return false
end

local function updateParryState(t, snapshot)
	R.lastSpeed =
		math.max(
			tonumber(snapshot.speed) or 0,
			0
		)

	if not AutoParry
		or type(AutoParry.getParryRadius)
			~= "function"
	then
		return
	end

	local ok, radius =
		pcall(
			AutoParry.getParryRadius,
			t
		)

	if not ok then
		R.lastGate =
			"parry_radius_error"

		return
	end

	radius = tonumber(radius)

	if radius and radius >= 0 then
		R.parryRadius = radius
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

	updateParryState(
		t,
		snapshot
	)

	if R.active then
		if shouldDeactivate(
			t,
			snapshot
		) then
			setActive(
				false,
				"target_deactivated"
			)
		end

		return
	end

	if tryReturnActivate(snapshot) then
		R.lostMeAt = 0
		R.returnPending = false

		setActive(
			true,
			"activated",
			snapshot
		)

		return
	end

	if tryDashActivate(snapshot) then
		R.lostMeAt = 0
		R.returnPending = false

		setActive(
			true,
			"dash_threat",
			snapshot
		)
	end
end

-- heartbeat
local function heartbeatStep(
	generation,
	character,
	root,
	_dt
)
	if generation ~= R.generation
		or not character.Parent
		or not root.Parent
	then
		return
	end

	if type(Utils.getPlayers)
		== "function"
	then
		local ok, playersService =
			pcall(
				Utils.getPlayers
			)

		if ok and playersService then
			dashDetectionTick(
				playersService
			)
		end
	end

	if Utils.isManualSpamActive() then
		if R.active then
			setActive(
				false,
				"manual_spam"
			)
		end

		resetTargetState()

		R.lastGate =
			"manual_spam"

		return
	end

	if not Utils.isActive() then
		if R.active then
			setActive(
				false,
				"hub_inactive"
			)
		end

		resetTargetState()

		R.lastGate =
			"hub_inactive"

		return
	end

	local config =
		Utils.getConfig()

	if not (
		config
		and config.AutoClash
	) then
		if R.active then
			setActive(
				false,
				"hub_disabled"
			)
		end

		resetTargetState()

		R.lastGate =
			"hub_disabled"

		return
	end

	local t = now()

	if t - R.lastEvalAt
		< T.MIN_EVAL_INTERVAL
	then
		return
	end

	R.lastEvalAt = t

	local snapshot =
		GameInfo.getSnapshot(
			R.lastTarget,
			t
		)

	if not GameInfo.isSnapshotValid(
		snapshot,
		t
	) then
		return
	end

	local target =
		normalizeTarget(
			snapshot.targetId
		)

	if target then
		R.lastTarget = target
	end

	evaluateClash(
		t,
		snapshot
	)
end

-- character
local function bindCharacter(character)
	resetRuntime(
		"rebind",
		true
	)

	local generation =
		R.generation

	if not (
		character
		and character.Parent
	) then
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

	if not (
		generation == R.generation
		and root
		and root.Parent
	) then
		return false
	end

	R.boundRoot = root
	R.lastGate =
		"waiting_for_character"

	local heartbeat =
		Utils.getRunService().Heartbeat:Connect(
			function(dt)
				heartbeatStep(
					generation,
					character,
					root,
					dt
				)
			end
		)

	addConnection(
		R.connections,
		heartbeat
	)

	Utils.trackCharacter(
		heartbeat
	)

	local ancestry =
		character.AncestryChanged:Connect(
			function(_, parent)
				if parent then
					return
				end

				resetRuntime(
					"character_removed",
					false
				)

				R.lastGate =
					"character_removed"
			end
		)

	addConnection(
		R.connections,
		ancestry
	)

	Utils.trackCharacter(
		ancestry
	)

	R.bound = true

	setPhase(
		"waiting",
		"character_bound"
	)

	if #R.dashConnections == 0 then
		local okPS, playersService =
			pcall(
				Utils.getPlayers
			)

		if okPS and playersService then
			dashDetectionInit(
				playersService
			)
		end
	end

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

	if type(deps) ~= "table" then
		return false
	end

	for _, requirement in ipairs(required) do
		local object =
			deps[requirement[1]]

		if not object
			or type(
				object[requirement[2]]
			) ~= "function"
		then
			return false
		end
	end

	if Utils then
		resetRuntime(
			"setup",
			false
		)
	else
		disconnectDashConnections()
		disconnectCharacterConnections()
	end

	AutoParry = deps.AutoParry
	GameInfo = deps.GameInfo
	Utils = deps.Utils

	local player =
		Utils.getLocalPlayer()

	R.localUserId =
		player and player.UserId
		or nil

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
	R.lastDirectionSwitchAt = 0

	R.connections = {}
	R.dashConnections = {}
	R.dashGeneration = 0

	R.dashGateActive = false
	R.dashGateTriggerUserId = nil
	R.deactivateCooldownUntil = 0

	R.ownDashEscapePending = false
	R.ownDashEscapeSince = 0
	R.ownDashEscapeDetectedAt = 0
	R.ownDashEscapeInitialTti = nil

	R.dashEvents = {}
	R.dashCooldown = {}
	R.dashTrackSnap = {}
	R.dashVelAnterior = {}
	R.dashVelFrames = {}

	resetTargetState()
	resetDeactivationState()

	R.lastGate = "none"

	local okPS, playersService =
		pcall(
			Utils.getPlayers
		)

	if okPS and playersService then
		dashDetectionInit(
			playersService
		)
	end

	return true
end

function AutoClash.bindCharacter(character)
	return bindCharacter(character)
end

function AutoClash.detachCharacter()
	resetRuntime(
		"detach",
		false
	)
end

function AutoClash.teardown()
	resetRuntime(
		"teardown",
		false
	)

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
			setActive(
				false,
				"teleported"
			)
		end

		resetTargetState()

		R.lastGate =
			"teleported"

		return
	end

	local target =
		normalizeTarget(
			data.TargetPlayerID
		)

	if not target then
		if R.active then
			setActive(
				false,
				"invalid_target"
			)
		end

		resetTargetState()

		R.lastGate =
			"invalid_target"

		return
	end

	local previousTargetId =
		R.lastTarget

	R.lastTarget = target

	local wasMe =
		R.wasMeTarget

	local isMe =
		target == R.localUserId

	if wasMe == nil then
		R.wasMeTarget = isMe

		R.lastGate =
			isMe
				and "initial_me"
				or "initial_not_me"

		return
	end

	local t = now()

	if wasMe ~= isMe then
		R.lastDirectionSwitchAt = t
	end

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

		R.lastGate =
			"target_lost"

	elseif not wasMe and isMe then
		if previousTargetId ~= -1
			and previousTargetId
				~= R.localUserId
		then
			R.clashPartnerId =
				previousTargetId
		end

		local position =
			dataPosition(data)

		local root =
			rootPosition()

		local radius =
			R.parryRadius

		if root
			and position
			and radius > 0
		then
			local distance =
				(root - position).Magnitude

			if distance
				<= radius
					* T.ACT_INSTANT_RADIUS_FACTOR
			then
				if previousTargetId ~= -1
					and previousTargetId
						~= R.localUserId
				then
					R.clashPartnerId =
						previousTargetId
				end

				setActive(
					true,
					"instant_activate",
					{
						position = position,
					}
				)

				R.lostMeAt = 0
				R.returnPending = false
				R.wasMeTarget = isMe

				return
			end
		end

		local lostAt =
			R.lostMeAt

		if lostAt > 0 then
			local elapsed =
				t - lostAt

			local window =
				returnWindow(
					R.lastSpeed
				)

			if elapsed >= 0
				and elapsed <= window
			then
				R.returnPending = true

				R.lastGate =
					"target_return"
			else
				R.lostMeAt = 0
				R.returnPending = false

				R.lastGate =
					"return_too_late"
			end
		else
			R.returnPending = false

			R.lastGate =
				"return_without_loss"
		end
	end

	R.wasMeTarget = isMe
end

function AutoClash.isActive()
	return R.active == true
end

function AutoClash.getStatus()
	local schema

	if Utils
		and type(Utils.apiVersion)
			== "function"
	then
		local ok, value =
			pcall(
				Utils.apiVersion
			)

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
		clashPartnerId =
			R.clashPartnerId,

		lastGate = R.lastGate,

		dashGateActive =
			R.dashGateActive == true,

		dashGateTriggerUserId =
			R.dashGateTriggerUserId,

		ownDashEscapePending =
			R.ownDashEscapePending == true,

		deactivateCooldownUntil =
			R.deactivateCooldownUntil,
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