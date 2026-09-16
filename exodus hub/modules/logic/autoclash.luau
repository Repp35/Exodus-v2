-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

-- tuning

local Tuning = {
	DEFLECT_RADIUS = 7,
	PARRY_WINDOW = 0.15,
	MIN_BALL_SPEED = 8,
	RES_PER_PARRY = 0.19,
	RES_CAP_STUDS = 32,
	HITBOX_OWN_WINDOW = 0.5,
	HITBOX_PROXIMITY = 12,
	HITBOX_GAP = 0.4,

	STATIONARY_MULT = 1.30,
	STATIONARY_SPEED = 1.5,
	STATIONARY_DWELL = 0.20,

	CLIENT_CD_PROPAGATION = 0.30,

	RED_COLOR_TOLERANCE = 0.08,
	BRICKCOLOR_RED_NAME = "Bright red",
	CHAR_HIGHLIGHT_RADIUS = 20,
}

local PING_SAMPLE_INTERVAL = 1.5
local DEFAULT_PING_ONE_WAY = 0.030
local TELEPORT_LOCK = 0.20

local MAX_RES_STACK = math.floor(
	Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY
)

local HITBOX_PROXIMITY_SQ = Tuning.HITBOX_PROXIMITY ^ 2
local STATIONARY_SPEED_SQ = Tuning.STATIONARY_SPEED ^ 2
local CHAR_HIGHLIGHT_RADIUS_SQ = Tuning.CHAR_HIGHLIGHT_RADIUS ^ 2

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

-- ownership reasons

local REASON_SERVER_TARGET = "server_target"
local REASON_GAMEINFO_TARGET = "gameinfo_target"
local REASON_BALL_BRICKCOLOR = "ball_brickcolor_red"
local REASON_BALL_HIGHLIGHT = "ball_highlight_red"
local REASON_CHAR_HIGHLIGHT_NEAREST = "char_highlight_red_nearest"
local REASON_BALL_BRICKCOLOR_ANY = "ball_brickcolor_any"
local REASON_BALL_HIGHLIGHT_ANY = "ball_highlight_any"
local REASON_CHAR_HIGHLIGHT_ANY = "char_highlight_any"

local REASON_SERVER_TARGET_OTHER = "server_target_other"
local REASON_GAMEINFO_TARGET_OTHER = "gameinfo_target_other"
local REASON_CHAR_HIGHLIGHT_OTHER = "char_highlight_other"

local TARGET_ATTR_NAMES = {
	"target",
	"Target",
	"TargetPlayer",
	"TargetPlayerName",
}

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
	fired = false,
	firedBall = nil,
	firedAt = 0,
}

local Ownership = {
	ball = nil,
	state = nil,
	stateReason = nil,
	stateAt = 0,
	wasMine = false,
	parriedThisCycle = false,
	cycle = 0,
	lastLostAt = 0,
	lastMineAt = 0,
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
	stationarySince = 0,
	lastRootPos = nil,
	lastRootPosAt = 0,

	lastFireAt = 0,
	cooldownObservedAt = 0,

	phase = PHASE_DETACHED,
	bound = false,

	detectedAsTarget = false,
	detectionReason = nil,
	detectionTickAt = 0,

	detectionCounts = {
		[REASON_SERVER_TARGET] = 0,
		[REASON_GAMEINFO_TARGET] = 0,
		[REASON_BALL_BRICKCOLOR] = 0,
		[REASON_BALL_HIGHLIGHT] = 0,
		[REASON_CHAR_HIGHLIGHT_NEAREST] = 0,
		[REASON_BALL_BRICKCOLOR_ANY] = 0,
		[REASON_BALL_HIGHLIGHT_ANY] = 0,
		[REASON_CHAR_HIGHLIGHT_ANY] = 0,

		[REASON_SERVER_TARGET_OTHER] = 0,
		[REASON_GAMEINFO_TARGET_OTHER] = 0,
		[REASON_CHAR_HIGHLIGHT_OTHER] = 0,
	},
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

local function getPlayerRoot(player)
	local character = player and player.Character

	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")

	if root then
		return root
	end

	return character:FindFirstChildOfClass("BasePart")
end

local function getLocalPlayerRoot()
	local localPlayer = Utils.getLocalPlayer()
	return getPlayerRoot(localPlayer)
end

local function getPlayerByTargetName(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local players = game:GetService("Players")

	local direct = players:FindFirstChild(name)
	if direct and direct:IsA("Player") then
		return direct
	end

	for _, player in ipairs(players:GetPlayers()) do
		if player.Name == name or player.DisplayName == name then
			return player
		end
	end

	return nil
end

-- ownership

local function resetOwnership(ball)
	Ownership.ball = ball
	Ownership.state = nil
	Ownership.stateReason = nil
	Ownership.stateAt = 0
	Ownership.wasMine = false
	Ownership.parriedThisCycle = false
	Ownership.lastLostAt = 0
	Ownership.lastMineAt = 0
	Ownership.cycle += 1

	clearArmed()
	clearFired()
end

local function commitOwnership(ball, state, reason, time)
	if state ~= true and state ~= false then
		return false
	end

	if Ownership.ball ~= ball then
		resetOwnership(ball)
	end

	if Ownership.state == state then
		return true
	end

	Ownership.state = state
	Ownership.stateReason = reason
	Ownership.stateAt = time

	if state then
		Ownership.wasMine = true
		Ownership.parriedThisCycle = false
		Ownership.lastMineAt = time
		Ownership.cycle += 1

		clearArmed()
		clearFired()
	else
		Ownership.wasMine = false
		Ownership.lastLostAt = time
		Ownership.parriedThisCycle = true

		clearArmed()
		clearFired()
	end

	Runtime.detectedAsTarget = state
	Runtime.detectionReason = reason
	Runtime.detectionTickAt = time
	Runtime.detectionCounts[reason] =
		(Runtime.detectionCounts[reason] or 0) + 1

	return true
end

local function ownershipCanParry(ball)
	return Ownership.ball == ball
		and Ownership.state == true
		and Ownership.parriedThisCycle == false
end

-- target detection

local function resetTargetDetection(time)
	Runtime.detectedAsTarget = false
	Runtime.detectionReason = nil
	Runtime.detectionTickAt = time
end

local function isRedColor(color)
	if typeof(color) ~= "Color3" then
		return false
	end

	local r, g, b = color.R, color.G, color.B

	if r < 1 - Tuning.RED_COLOR_TOLERANCE then
		return false
	end

	if g > Tuning.RED_COLOR_TOLERANCE then
		return false
	end

	if b > Tuning.RED_COLOR_TOLERANCE then
		return false
	end

	return true
end

local function getBallBrickColor(ball)
	local ok, brickColor = pcall(function()
		return ball.BrickColor
	end)

	if not ok or typeof(brickColor) ~= "BrickColor" then
		return nil
	end

	return brickColor
end

local function getBallHighlight(ball)
	local direct = ball:FindFirstChildOfClass("Highlight")

	if direct then
		return direct
	end

	for _, descendant in ipairs(ball:GetDescendants()) do
		if descendant:IsA("Highlight") then
			return descendant
		end
	end

	return nil
end

local function getTargetAttribute(ball)
	for _, attributeName in ipairs(TARGET_ATTR_NAMES) do
		local ok, value = pcall(function()
			return ball:GetAttribute(attributeName)
		end)

		if ok and value ~= nil then
			if typeof(value) == "string" and value ~= "" then
				return value
			end

			if typeof(value) == "number" then
				return value
			end
		end
	end

	return nil
end

local function targetValueIsLocal(value)
	local localPlayer = Utils.getLocalPlayer()

	if not localPlayer then
		return nil
	end

	if type(value) == "number" then
		return tonumber(value) == tonumber(localPlayer.UserId)
	end

	if type(value) == "string" then
		if value == localPlayer.Name then
			return true
		end

		if value == localPlayer.DisplayName then
			return true
		end

		local targetPlayer = getPlayerByTargetName(value)

		if targetPlayer then
			return targetPlayer == localPlayer
		end
	end

	return nil
end

local function detectServerTarget(ball, time)
	local targetValue = getTargetAttribute(ball)

	if targetValue == nil then
		return nil
	end

	local localResult = targetValueIsLocal(targetValue)

	if localResult == true then
		commitOwnership(
			ball,
			true,
			REASON_SERVER_TARGET,
			time
		)

		return true
	end

	if localResult == false then
		commitOwnership(
			ball,
			false,
			REASON_SERVER_TARGET_OTHER,
			time
		)

		return false
	end

	return nil
end

local function detectGameInfoTarget(ball, targetedFromGameInfo, targetId, time)
	if targetedFromGameInfo ~= true then
		return nil
	end

	local localUserId = Runtime.localUserId
	local numericTarget = tonumber(targetId)

	if numericTarget == nil or numericTarget < 0 then
		return nil
	end

	if numericTarget == localUserId then
		commitOwnership(
			ball,
			true,
			REASON_GAMEINFO_TARGET,
			time
		)

		return true
	end

	commitOwnership(
		ball,
		false,
		REASON_GAMEINFO_TARGET_OTHER,
		time
	)

	return false
end

local function detectBallBrickColor(ball, time)
	local brickColor = getBallBrickColor(ball)

	if not brickColor then
		return nil
	end

	if brickColor == BrickColor.new(Tuning.BRICKCOLOR_RED_NAME) then
		commitOwnership(
			ball,
			true,
			REASON_BALL_BRICKCOLOR,
			time
		)

		return true
	end

	return nil
end

local function detectBallHighlight(ball, time)
	local highlight = getBallHighlight(ball)

	if not highlight then
		return nil
	end

	if highlight.FillTransparency >= 1 then
		return nil
	end

	if not isRedColor(highlight.FillColor) then
		return nil
	end

	commitOwnership(
		ball,
		true,
		REASON_BALL_HIGHLIGHT,
		time
	)

	return true
end

local function detectCharHighlightNearest(ball, time)
	local localPlayer = Utils.getLocalPlayer()

	if not localPlayer then
		return nil
	end

	local localCharacter = localPlayer.Character

	if not localCharacter then
		return nil
	end

	local localHighlight = localCharacter:FindFirstChildOfClass("Highlight")

	if localHighlight
		and localHighlight.FillTransparency < 1
		and isRedColor(localHighlight.FillColor)
	then
		local root = getPlayerRoot(localPlayer)

		if root and isValidBall(ball) then
			local ok, ballPosition = pcall(function()
				return ball.Position
			end)

			if ok and typeof(ballPosition) == "Vector3" then
				if getDistanceSquared(
					root.Position,
					ballPosition
				) <= CHAR_HIGHLIGHT_RADIUS_SQ then
					commitOwnership(
						ball,
						true,
						REASON_CHAR_HIGHLIGHT_NEAREST,
						time
					)

					return true
				end
			end
		end
	end

	local players = game:GetService("Players")

	for _, player in ipairs(players:GetPlayers()) do
		if player ~= localPlayer then
			local character = player.Character

			if character then
				local highlight = character:FindFirstChildOfClass("Highlight")

				if highlight
					and highlight.FillTransparency < 1
					and isRedColor(highlight.FillColor)
				then
					commitOwnership(
						ball,
						false,
						REASON_CHAR_HIGHLIGHT_OTHER,
						time
					)

					return false
				end
			end
		end
	end

	return nil
end

local function detectBallBrickColorAny(ball, time)
	local brickColor = getBallBrickColor(ball)

	if not brickColor then
		return nil
	end

	if brickColor == BrickColor.new("Bright red") then
		return nil
	end

	if brickColor == BrickColor.new("Medium stone grey") then
		return nil
	end

	if brickColor == BrickColor.new("White") then
		return nil
	end

	if brickColor == BrickColor.new("Really black") then
		return nil
	end

	commitOwnership(
		ball,
		true,
		REASON_BALL_BRICKCOLOR_ANY,
		time
	)

	return true
end

local function detectBallHighlightAny(ball, time)
	local highlight = getBallHighlight(ball)

	if not highlight then
		return nil
	end

	if highlight.FillTransparency >= 1 then
		return nil
	end

	commitOwnership(
		ball,
		true,
		REASON_BALL_HIGHLIGHT_ANY,
		time
	)

	return true
end

local function detectCharHighlightAny(ball, time)
	local localPlayer = Utils.getLocalPlayer()

	if not localPlayer then
		return nil
	end

	local localCharacter = localPlayer.Character

	if not localCharacter then
		return nil
	end

	local highlight = localCharacter:FindFirstChildOfClass("Highlight")

	if highlight
		and highlight.FillTransparency < 1
	then
		commitOwnership(
			ball,
			true,
			REASON_CHAR_HIGHLIGHT_ANY,
			time
		)

		return true
	end

	return nil
end

local function runOwnershipDetection(
	ball,
	targetedFromGameInfo,
	targetId,
	time
)
	resetTargetDetection(time)

	if not isValidBall(ball) then
		return nil
	end

	if Ownership.ball ~= ball then
		resetOwnership(ball)
	end

	if Ownership.state ~= nil then
		Runtime.detectedAsTarget = Ownership.state
		Runtime.detectionReason = Ownership.stateReason

		return Ownership.state
	end

	local result

	result = detectGameInfoTarget(
		ball,
		targetedFromGameInfo,
		targetId,
		time
	)

	if result ~= nil then
		return result
	end

	result = detectServerTarget(ball, time)

	if result ~= nil then
		return result
	end

	result = detectBallBrickColor(ball, time)

	if result ~= nil then
		return result
	end

	result = detectBallHighlight(ball, time)

	if result ~= nil then
		return result
	end

	result = detectCharHighlightNearest(ball, time)

	if result ~= nil then
		return result
	end

	result = detectBallBrickColorAny(ball, time)

	if result ~= nil then
		return result
	end

	result = detectBallHighlightAny(ball, time)

	if result ~= nil then
		return result
	end

	result = detectCharHighlightAny(ball, time)

	if result ~= nil then
		return result
	end

	return nil
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

	if not Utils.isFiniteNumber(ping)
		or ping <= 0
		or ping >= 0.5
	then
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

-- sync

local function onBallSync(data)
	if typeof(data) ~= "table" then
		return
	end

	local time = now()

	if data.Teleported == true then
		Runtime.teleportLockUntil = time + TELEPORT_LOCK

		clearCycle()

		return
	end

	local targetId = tonumber(data.TargetPlayerID)

	if targetId == nil then
		targetId = -1
	end

	if targetId == Runtime.lastTarget then
		return
	end

	local previousTarget = Runtime.lastTarget

	Runtime.lastTarget = targetId

	if targetId == Runtime.localUserId
		and previousTarget ~= Runtime.localUserId
	then
		clearFired()
	end
end

-- parry

local function requestParry(lockOwnership)
	if not Remote
		or type(Remote.fireParry) ~= "function"
	then
		if Utils and type(Utils.recordError) == "function" then
			Utils.recordError(
				"AutoParry",
				"Remote.fireParry indisponível"
			)
		end

		setPhase(PHASE_WAITING, "remote_unavailable")

		return false
	end

	local time = now()

	local ok, result = pcall(
		Remote.fireParry,
		1
	)

	if not ok or result == false then
		if type(Utils.recordError) == "function" then
			Utils.recordError(
				"AutoParry",
				"Remote.fireParry falhou"
			)
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

	if lockOwnership and isValidBall(ball) then
		if Ownership.ball ~= ball then
			resetOwnership(ball)
		end

		Ownership.state = true
		Ownership.stateReason = Ownership.stateReason
		Ownership.stateAt = time
		Ownership.wasMine = true
		Ownership.parriedThisCycle = true
		Ownership.lastMineAt = time

		Runtime.detectedAsTarget = true
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

	local position
	local ballPosition

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

	if getDistanceSquared(
		ballPosition,
		position
	) > HITBOX_PROXIMITY_SQ
	then
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
		return workspaceService.DescendantAdded:Connect(
			function(instance)
				local handler = HitboxState.handler

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

	resetOwnership(nil)

	resetResilience()

	setPhase(
		PHASE_DETACHED,
		"rebind_start"
	)

	if not character or not character.Parent then
		return false
	end

	local root = character:FindFirstChild(
		"HumanoidRootPart"
	)

	if not root then
		root = character:WaitForChild(
			"HumanoidRootPart",
			1
		)
	end

	if generation ~= Runtime.generation
		or not root
		or not root.Parent
	then
		return false
	end

	local humanoid = character:FindFirstChildOfClass(
		"Humanoid"
	)

	if humanoid then
		local diedConnection = humanoid.Died:Connect(
			function()
				resetResilience()
				clearCycle()
				resetOwnership(nil)

				setPhase(
					PHASE_DETACHED,
					"character_died"
				)
			end
		)

		Runtime.connections[
			#Runtime.connections + 1
		] = diedConnection

		Utils.trackCharacter(
			diedConnection
		)
	end

	local heartbeat = Utils.getRunService().Heartbeat
	local getConfig = Utils.getConfig
	local isSpamActive = Utils.isSpamActive

	local heartbeatConnection = heartbeat:Connect(
		function(dt)
			if generation ~= Runtime.generation then
				return
			end

			if not character.Parent
				or not root.Parent
			then
				return
			end

			local config = getConfig()

			if type(config) ~= "table"
				or config.AutoParry ~= true
			then
				clearCycle()

				setPhase(
					PHASE_WAITING,
					"disabled_or_locked"
				)

				return
			end

			local timeNow = now()

			if timeNow < Runtime.teleportLockUntil then
				clearCycle()

				setPhase(
					PHASE_WAITING,
					"teleport_lock"
				)

				return
			end

			if isSpamActive() then
				clearCycle()

				setPhase(
					PHASE_WAITING,
					"spam_active"
				)

				return
			end

			Runtime.pingTimer += math.max(
				dt,
				0
			)

			if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then
				Runtime.pingTimer = 0
				samplePing()
			end

			local snapshot = GameInfo.getSnapshot(
				Runtime.lastTarget,
				timeNow
			)

			if type(snapshot) ~= "table"
				or not GameInfo.isSnapshotValid(
					snapshot,
					timeNow
				)
			then
				setPhase(
					PHASE_WAITING,
					"snapshot_invalid"
				)

				return
			end

			local ball = snapshot.ball
			local ballVel = snapshot.velocity
			local targetedFromGameInfo =
				snapshot.targeted == true

			local snapshotTargetId =
				tonumber(snapshot.targetPlayerId)

			if snapshotTargetId == nil then
				snapshotTargetId =
					tonumber(snapshot.TargetPlayerID)
			end

			if snapshotTargetId == nil then
				snapshotTargetId =
					tonumber(Runtime.lastTarget)
			end

			local deflectCooldown =
				tonumber(GameInfo.getDeflectCD())
				or 0

			if not Utils.isFiniteNumber(
				deflectCooldown
			) then
				deflectCooldown = 0
			end

			if not isValidBall(ball) then
				resetOwnership(nil)
				resetTargetDetection(timeNow)

				setPhase(
					PHASE_WAITING,
					"ball_invalid"
				)

				return
			end

			if Ownership.ball ~= ball then
				resetOwnership(ball)
			end

			local ownershipResult =
				runOwnershipDetection(
					ball,
					targetedFromGameInfo,
					snapshotTargetId,
					timeNow
				)

			if ownershipResult == false then
				ParryState.armed = false
				ParryState.armedBall = nil

				setPhase(
					PHASE_WAITING,
					"ball_not_mine"
				)

				return
			end

			if ownershipResult == nil
				and Ownership.state == nil
			then
				setPhase(
					PHASE_WAITING,
					"ownership_unknown"
				)

				return
			end

			if Ownership.state ~= true then
				setPhase(
					PHASE_WAITING,
					"ball_not_mine"
				)

				return
			end

			if Ownership.parriedThisCycle then
				setPhase(
					PHASE_FIRED,
					"already_parried_this_cycle"
				)

				return
			end

			local speed = tonumber(
				snapshot.speed
			)

			if not speed
				or not Utils.isFiniteNumber(speed)
				or speed < Tuning.MIN_BALL_SPEED
			then
				setPhase(
					PHASE_WAITING,
					"ball_too_slow"
				)

				return
			end

			local position = snapshot.position

			if typeof(position) ~= "Vector3" then
				setPhase(
					PHASE_WAITING,
					"position_unavailable"
				)

				return
			end

			local rootPos = root.Position
			local parryRadius =
				computeParryRadius(timeNow)

			local parryWindow =
				Tuning.PARRY_WINDOW

			local previousPos =
				Runtime.lastRootPos

			local previousTime =
				Runtime.lastRootPosAt

			Runtime.lastRootPos = rootPos
			Runtime.lastRootPosAt = timeNow

			if previousPos
				and timeNow > previousTime
			then
				local invDt =
					1 / (timeNow - previousTime)

				local vx =
					(rootPos.X - previousPos.X)
					* invDt

				local vz =
					(rootPos.Z - previousPos.Z)
					* invDt

				local horizontalSpeedSq =
					vx * vx + vz * vz

				if horizontalSpeedSq
					< STATIONARY_SPEED_SQ
				then
					if Runtime.stationarySince == 0 then
						Runtime.stationarySince =
							timeNow
					end
				else
					Runtime.stationarySince = 0
				end
			elseif Runtime.stationarySince == 0 then
				Runtime.stationarySince = timeNow
			end

			Runtime.stationary =
				Runtime.stationarySince > 0
				and timeNow
					- Runtime.stationarySince
					>= Tuning.STATIONARY_DWELL

			if Runtime.stationary then
				parryWindow *=
					Tuning.STATIONARY_MULT
			end

			Runtime.parryRadius =
				parryRadius
				+ speed * parryWindow

			local distanceSquared =
				getDistanceSquared(
					rootPos,
					position
				)

			local distance =
				math.sqrt(distanceSquared)

			local tti =
				(distance - parryRadius)
				/ speed

			if tti > parryWindow then
				if deflectCooldown > 0 then
					setPhase(
						PHASE_COOLDOWN,
						"cooldown_outside_window"
					)
				else
					setPhase(
						PHASE_WAITING,
						"outside_ping_window"
					)
				end

				return
			end

			if deflectCooldown > 0 then
				if Runtime.cooldownObservedAt <= 0 then
					Runtime.cooldownObservedAt =
						timeNow
				elseif timeNow
					- Runtime.cooldownObservedAt
					>= Tuning.CLIENT_CD_PROPAGATION
				then
					setPhase(
						PHASE_COOLDOWN,
						"cooldown_observed"
					)
				else
					setPhase(
						PHASE_COOLDOWN,
						"cooldown_propagation"
					)
				end

				if not ParryState.armed then
					ParryState.armed = true
					ParryState.armedBall = ball
				end

				setPhase(
					PHASE_ARMED,
					"awaiting_deflect_cooldown"
				)

				return
			end

			Runtime.cooldownObservedAt = 0

			if ParryState.armed then
				if ParryState.armedBall ~= ball then
					clearArmed()

					setPhase(
						PHASE_WAITING,
						"armed_ball_changed"
					)

					return
				end

				if not ownershipCanParry(ball) then
					clearArmed()

					setPhase(
						PHASE_WAITING,
						"armed_ownership_invalid"
					)

					return
				end

				if requestParry(true) then
					ParryState.fired = true
					ParryState.firedBall = ball
					ParryState.firedAt = timeNow
				end

				clearArmed()

				return
			end

			if not ownershipCanParry(ball) then
				setPhase(
					PHASE_WAITING,
					"parry_blocked"
				)

				return
			end

			if requestParry(true) then
				ParryState.fired = true
				ParryState.firedBall = ball
				ParryState.firedAt = timeNow
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
				if not parent
					and generation
						== Runtime.generation
				then
					Runtime.generation += 1
					Runtime.bound = false

					disconnectConnections()
					clearCycle()
					resetOwnership(nil)
					resetResilience()

					setPhase(
						PHASE_DETACHED,
						"character_removed"
					)
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
		PHASE_WAITING,
		"character_bound"
	)

	return true
end

-- lifecycle

local function resetState()
	clearCycle()
	resetOwnership(nil)

	Runtime.teleportLockUntil = 0
	Runtime.lastTarget = -1

	Runtime.pingTimer = 0
	Runtime.minPing = nil
	Runtime.pingOneWay =
		DEFAULT_PING_ONE_WAY

	Runtime.parryRadius = 0

	Runtime.stationary = false
	Runtime.stationarySince = 0
	Runtime.lastRootPos = nil
	Runtime.lastRootPosAt = 0

	Runtime.lastFireAt = 0
	Runtime.cooldownObservedAt = 0

	Runtime.bound = false

	Runtime.detectedAsTarget = false
	Runtime.detectionReason = nil
	Runtime.detectionTickAt = 0

	Runtime.detectionCounts =
		Runtime.detectionCounts or {}

	for reason in pairs(Runtime.detectionCounts) do
		Runtime.detectionCounts[reason] = 0
	end

	setPhase(
		PHASE_DETACHED,
		"reset"
	)
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
		return false,
			"dependência ausente: Remote.fireParry"
	end

	if type(gameInfo) ~= "table"
		or type(gameInfo.getDeflectCD)
			~= "function"
		or type(gameInfo.getBall)
			~= "function"
		or type(gameInfo.getSnapshot)
			~= "function"
		or type(gameInfo.isSnapshotValid)
			~= "function"
	then
		return false,
			"dependência ausente: GameInfo"
	end

	if type(utils) ~= "table"
		or type(utils.now) ~= "function"
		or type(utils.apiVersion) ~= "function"
		or type(utils.isFiniteNumber)
			~= "function"
		or type(utils.getConfig)
			~= "function"
		or type(utils.getLocalPlayer)
			~= "function"
		or type(utils.getWorkspace)
			~= "function"
		or type(utils.getRunService)
			~= "function"
		or type(utils.trackCharacter)
			~= "function"
		or type(utils.untrackCharacter)
			~= "function"
		or type(utils.trackGlobal)
			~= "function"
		or type(utils.isActive)
			~= "function"
		or type(utils.isSpamActive)
			~= "function"
	then
		return false,
			"dependência ausente: Utils"
	end

	Remote = remote
	GameInfo = gameInfo
	Utils = utils

	StatsService =
		game:GetService("Stats")

	local localPlayer =
		Utils.getLocalPlayer()

	Runtime.localUserId =
		localPlayer
		and tonumber(localPlayer.UserId)
		or -1

	HitboxState.handler =
		handleHitbox

	resetResilience()
	resetState()

	if not installHitboxHook()
		and type(Utils.warn) == "function"
	then
		Utils.warn(
			"hook de hitbox indisponível"
		)
	end

	return true
end

function AutoParry.fire()
	if not Remote
		or not GameInfo
		or not Utils
	then
		return false
	end

	local ball = GameInfo.getBall()

	if isValidBall(ball) then
		if Ownership.ball ~= ball then
			resetOwnership(ball)
		end

		if Ownership.state ~= true then
			return false
		end

		if Ownership.parriedThisCycle then
			return false
		end
	end

	return requestParry(true)
end

function AutoParry.bindCharacter(character)
	if not Remote
		or not GameInfo
		or not Utils
	then
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
	resetResilience()
end

function AutoParry.onBallSync(data)
	if Utils then
		onBallSync(data)
	end
end

function AutoParry.getParryRadius()
	return Runtime.parryRadius
end

function AutoParry.getPingOneWay()
	return Runtime.pingOneWay
end

function AutoParry.getDetectedReason()
	return Runtime.detectionReason
end

function AutoParry.getDetectionCounts()
	local copy = {}

	for reason, count in pairs(
		Runtime.detectionCounts
	) do
		copy[reason] = count
	end

	return copy
end

function AutoParry.getStatus()
	return {
		schema =
			Utils
			and Utils.apiVersion()
			or nil,

		phase = phaseString,
		bound = Runtime.bound == true,

		armed =
			ParryState.armed == true,

		fired =
			ParryState.fired == true,

		resilienceStack =
			Resilience.stack,

		parryRadius =
			Runtime.parryRadius,

		stationary =
			Runtime.stationary == true,

		detectedAsTarget =
			Runtime.detectedAsTarget,

		detectionReason =
			Runtime.detectionReason,

		detectionCounts =
			AutoParry.getDetectionCounts(),

		ownership = {
			ball = Ownership.ball,
			state = Ownership.state,
			stateReason = Ownership.stateReason,
			stateAt = Ownership.stateAt,
			wasMine = Ownership.wasMine,
			parriedThisCycle =
				Ownership.parriedThisCycle,
			cycle = Ownership.cycle,
			lastMineAt =
				Ownership.lastMineAt,
			lastLostAt =
				Ownership.lastLostAt,
		},
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