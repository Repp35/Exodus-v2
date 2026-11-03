-- [[ autoparry ]]

local AutoParry = {}
export type RadiusMode = "geometry" | "tti" | "speed_distance"
export type RadiusResult = {
	mode: string,
	value: number | { speed: number, distance: number },
	pureRadius: number,
	noWindowParryRadius: number,
	pingRadius: number,
	resilience: { [string]: any },
	fullRadius: number,
	deflectWindow: number,
	windowFactor: number,
	effectiveWindow: number,
	leadTime: number,
	distance: number,
	speed: number,
	tti: number,
}

local Remote
local GameInfo
local Utils

-- tuning
local T = {
	VELOCITY_SMOOTHING_TAU = 0.05,
	PING_SAMPLE_INTERVAL = 1,
	BASE_RADIUS = 8.5,
	BASE_WINDOW = 0.50,
	MIN_DEFLECT_WINDOW = 0.20,
	DEFAULT_WINDOW_FACTOR = 0.50,
	MIN_WINDOW_FACTOR = 0.0,
	MAX_WINDOW_FACTOR = 1.0,
	MIN_LEAD_TIME = 0.20,
	SPEED_TOLERANCE_FACTOR = 2.5,
	SPEED_TOLERANCE_EXTRA = 30,
	RES_PER_PARRY = 0.225,
	RES_CAP_STUDS = 7.5,
	STATIONARY_TIMEOUT = 0.10,
	MAX_RES_STACK = math.ceil(7.5 / 0.225),
}

-- state
local R = {
	phase = "detached",
	reason = "initial",
	lastErrorAt = -math.huge,
	generation = 0,
	lifeGeneration = 0,
	alive = false,
	bound = false,
	player = nil,
	root = nil,
	connections = {},
	armed = true,
	firedForTarget = false,
	targetAwaySeen = false,
	targetCycle = 0,
	lastTargeted = false,
	targeted = false,
	lastBall = nil,
	lastPosition = nil,
	lastPositionAt = nil,
	velocity = Vector3.zero,
	ping = 0,
	pingAt = 0,
	lastDistance = 0,
	lastSpeed = 0,
	lastLeadTime = T.MIN_LEAD_TIME,
	lastFireAt = 0,
	lastApproaching = false,
	lastTarget = -1,
	lastSyncSequence = nil,
	targetId = -1,
	targetKnown = false,
	teleported = false,
	teleportSequence = nil,
	lastMovingAt = nil,
	resilienceBonus = 0,
	resilienceBonusAt = -1,
}

local function clock() return os.clock() end
local function isFiniteNumber(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end
local function isValidVector3(value) return typeof(value) == "Vector3" end
local function isPlausibleVelocity(velocity, syncData)
	if not isValidVector3(velocity) or not isFiniteNumber(velocity.Magnitude) then return false end
	local expected = type(syncData) == "table" and syncData.Speed or nil
	if isFiniteNumber(expected) and expected > 0 then return velocity.Magnitude <= expected * T.SPEED_TOLERANCE_FACTOR + T.SPEED_TOLERANCE_EXTRA end
	local _, maximum
	if GameInfo and type(GameInfo.getBallSpeedLimits) == "function" then _, maximum = GameInfo.getBallSpeedLimits() end
	if isFiniteNumber(maximum) then return velocity.Magnitude <= maximum * T.SPEED_TOLERANCE_FACTOR + T.SPEED_TOLERANCE_EXTRA end
	return true
end
local function minimumBallSpeed()
	local minimum
	if GameInfo and type(GameInfo.getBallSpeedLimits) == "function" then minimum = GameInfo.getBallSpeedLimits() end
	if not isFiniteNumber(minimum) and GameInfo and type(GameInfo.getSyncData) == "function" then local data = GameInfo.getSyncData(); minimum = type(data) == "table" and tonumber(data.Speed) or nil end
	return isFiniteNumber(minimum) and minimum * 0.375 or math.huge
end
local function isValidBall(ball) return typeof(ball) == "Instance" and ball.Parent ~= nil and ball:IsA("BasePart") end
local function getRootPart(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then return root end
	return nil
end
local function setPhase(nextPhase, reason)
	if R.phase == nextPhase and R.reason == reason then return end
	local previous = R.phase; R.phase = nextPhase; R.reason = reason
	if Utils and type(Utils.recordTransition) == "function" then pcall(Utils.recordTransition, "AutoParry", previous, nextPhase, reason) end
end
local function trackConnection(connection)
	if not connection then return end
	R.connections[#R.connections + 1] = connection
	if Utils and type(Utils.trackCharacter) == "function" then pcall(Utils.trackCharacter, connection) end
end
local function disconnectConnections()
	for i = #R.connections, 1, -1 do
		local connection = R.connections[i]; R.connections[i] = nil
		if connection then
			if Utils and type(Utils.untrackCharacter) == "function" then pcall(Utils.untrackCharacter, connection) end
			pcall(function() connection:Disconnect() end)
		end
	end
end
local function resetParryLock()
	R.armed = true; R.lastTargeted = false
end
local function clearBallState()
	R.targeted = false; R.lastBall = nil; R.lastPosition = nil; R.lastPositionAt = nil
	R.lastMovingAt = nil; R.velocity = Vector3.zero; R.lastDistance = 0; R.lastSpeed = 0
	R.lastLeadTime = T.MIN_LEAD_TIME; R.lastApproaching = false; R.targetId = -1; R.targetKnown = false
end
local function resetTracking()
	R.armed = true; R.firedForTarget = false; R.targetAwaySeen = false; R.targetCycle = 0
	R.lastTargeted = false; R.targeted = false; R.lastBall = nil; R.lastPosition = nil
	R.lastPositionAt = nil; R.lastMovingAt = nil; R.velocity = Vector3.zero; R.ping = 0
	R.pingAt = 0; R.lastDistance = 0; R.lastSpeed = 0; R.lastLeadTime = T.MIN_LEAD_TIME
	R.lastFireAt = 0; R.lastApproaching = false; R.lastTarget = -1; R.lastSyncSequence = nil
	R.targetId = -1; R.targetKnown = false; R.teleported = false; R.teleportSequence = nil
	R.resilienceBonus = 0; R.resilienceBonusAt = -1
end
local function invalidateLife()
	R.lifeGeneration += 1; R.alive = false; R.bound = false; resetParryLock()
end
local function observeTarget(targetId)
	if not R.player or not isFiniteNumber(targetId) or targetId <= 0 then return end
	if targetId ~= R.player.UserId then R.targetAwaySeen = true elseif R.targetAwaySeen then R.targetAwaySeen = false; R.firedForTarget = false; R.targetCycle += 1 end
end
local function getResilienceBonus(time)
	if not R.alive or not R.bound or not R.player then return 0 end
	if R.resilienceBonusAt == time then return R.resilienceBonus end
	local ok, range = pcall(GameInfo.getDeflectRange)
	if not ok or not isFiniteNumber(range) then range = T.BASE_RADIUS end
	R.resilienceBonus = math.clamp(range - T.BASE_RADIUS, 0, T.RES_CAP_STUDS); R.resilienceBonusAt = time; return R.resilienceBonus
end
local function getResilienceStatus()
	local bonus = getResilienceBonus(clock())
	return {
		stack = math.floor(bonus / T.RES_PER_PARRY + 0.5),
		size = bonus,
		perParry = T.RES_PER_PARRY,
		cap = T.RES_CAP_STUDS,
		maxStack = T.MAX_RES_STACK,
		source = "DeflectRange",
	}
end
local function getConfig()
	if not Utils or type(Utils.getConfig) ~= "function" then return nil end
	local ok, config = pcall(Utils.getConfig)
	if ok and type(config) == "table" then return config end
	return nil
end
local function isAutoParryEnabled()
	if Utils and type(Utils.getConfigValue) == "function" then return Utils.getConfigValue("AutoParry") ~= false end
	local config = getConfig()
	if not config then return true end
	return config.AutoParry ~= false
end
local function getWindowFactor()
	local factor
	if Utils and type(Utils.getConfigValue) == "function" then factor = tonumber(Utils.getConfigValue("AutoParryWindowFactor"))
	else local config = getConfig(); factor = config and tonumber(config.AutoParryWindowFactor) end
	if not isFiniteNumber(factor) then return T.DEFAULT_WINDOW_FACTOR end
	return math.clamp(factor, T.MIN_WINDOW_FACTOR, T.MAX_WINDOW_FACTOR)
end
local function isSystemActive()
	if not Utils or type(Utils.isActive) ~= "function" then return true end
	local ok, active = pcall(Utils.isActive); return ok and active == true
end
local function isSpamActive()
	if not Utils or type(Utils.isSpamActive) ~= "function" then return false end
	local ok, active = pcall(Utils.isSpamActive); return ok and active == true
end
local function computeDeflectWindow(speed)
	local minimum, maximum
	if GameInfo and type(GameInfo.getBallSpeedLimits) == "function" then minimum, maximum = GameInfo.getBallSpeedLimits() end
	if not isFiniteNumber(minimum) or not isFiniteNumber(maximum) or maximum <= minimum then minimum, maximum = 16, 600 end
	local fraction = math.clamp((speed - minimum) / (maximum - minimum), 0, 1); return T.BASE_WINDOW + (T.MIN_DEFLECT_WINDOW - T.BASE_WINDOW) * fraction
end
local function computeParryRadius(speed, ping, resilienceBonus, windowFactor)
	local validSpeed = isFiniteNumber(speed) and math.max(speed, 0) or 0; local deflectWindow = computeDeflectWindow(validSpeed); local validPing = isFiniteNumber(ping) and math.max(ping, 0) or 0
	local leadTime = deflectWindow + validPing; local factor = tonumber(windowFactor)
	if not isFiniteNumber(factor) then factor = getWindowFactor() end
	factor = math.clamp(factor, T.MIN_WINDOW_FACTOR, T.MAX_WINDOW_FACTOR); local validResilience = isFiniteNumber(resilienceBonus) and math.max(resilienceBonus, 0) or 0
	local baseRadius = T.BASE_RADIUS + validResilience
	local anticipation = validSpeed * leadTime * factor
	local noWindowRadius = baseRadius
	local pingRadius = validSpeed * validPing * factor
	local fullRadius = baseRadius + anticipation
	local effectiveWindow = leadTime * factor
	return fullRadius, leadTime, noWindowRadius, pingRadius, deflectWindow, effectiveWindow, factor
end
local function readTargeted(snapshot)
	if type(snapshot) == "table" then
		local targetId = tonumber(snapshot.targetId)
		if targetId and targetId > 0 and R.player then return targetId == tonumber(R.player.UserId) end
		if snapshot.targeted == true then return true end
	end
	if GameInfo and type(GameInfo.getTargetId) == "function" and R.player then
		local ok, targetId = pcall(GameInfo.getTargetId)
		if ok then return tonumber(targetId) == tonumber(R.player.UserId) end
	end
	return false
end
local function readFrameState(time)
	local snapshot
	if GameInfo and type(GameInfo.getSnapshot) == "function" then
		local ok, result
		if type(GameInfo.getSnapshotAt) == "function" then ok, result = pcall(GameInfo.getSnapshotAt, time) else ok, result = pcall(GameInfo.getSnapshot, nil, time) end
		if ok and type(result) == "table" then
			local valid = true
			if type(GameInfo.isSnapshotValid) == "function" then local validOk, snapshotValid = pcall(GameInfo.isSnapshotValid, result, time); valid = validOk and snapshotValid == true end
			if valid then snapshot = result end
		end
	end
	local ball = snapshot and snapshot.ball or nil
	if not isValidBall(ball) and GameInfo and type(GameInfo.getBall) == "function" then
		local ok, result = pcall(GameInfo.getBall)
		if ok then ball = result end
	end
	if not isValidBall(ball) then return nil, false, snapshot end
	return ball, readTargeted(snapshot), snapshot
end
local function getCurrentVelocity(ball)
	local ok, value = pcall(function() return GameInfo.getBallVelocity(ball) end)
	if ok and isValidVector3(value) then
		if value.Magnitude > 0.1 or not isValidVector3(R.velocity) or R.velocity.Magnitude <= 0.1 then return value end
	end
	if isValidVector3(R.velocity) then return R.velocity end
	return ok and value or nil
end
local function samplePing(time)
	if time - R.pingAt < T.PING_SAMPLE_INTERVAL then return end
	R.pingAt = time; local ok, value = pcall(GameInfo.getLocalPing)
	if ok and isFiniteNumber(value) and value >= 0 then R.ping = value end
end
local function isTeleportLocked() return R.teleported end
local function enterTeleportLock(_, sequence)
	if type(sequence) == "number" then R.teleportSequence = sequence end
	if R.teleported then return end
	R.teleported = true; R.firedForTarget = false; R.targetAwaySeen = false; R.targetCycle += 1
	R.lastTarget = -1; resetParryLock(); clearBallState(); R.lastFireAt = 0
	setPhase("waiting", "teleport_lock")
end
local function leaveTeleportLock(time)
	if R.teleported and R.teleportSequence ~= nil then
		local current = GameInfo and GameInfo.getSyncSequence and GameInfo.getSyncSequence()
		if type(current) ~= "number" or (current - R.teleportSequence) % 65536 >= 32768 then return false end
	end
	local wasTeleported = R.teleported; R.teleported = false; R.teleportSequence = nil
	if wasTeleported then resetParryLock(); clearBallState(); R.lastFireAt = 0; setPhase("waiting", "teleport_finished") end
	return true
end
local function getRemoteParry(ball)
	local time = clock()
	if isTeleportLocked() then return false end
	if not isValidBall(ball) then return false end
	if R.lastBall ~= ball then return false end
	if not R.lastApproaching then return false end
	if not isFiniteNumber(R.lastSpeed) or R.lastSpeed < minimumBallSpeed() then return false end
	local liveVelocity = getCurrentVelocity(ball); local syncData = GameInfo and GameInfo.getSyncData and GameInfo.getSyncData()
	if type(syncData) == "table" and syncData.Teleported == true then return false end
	if not isPlausibleVelocity(liveVelocity, syncData) or liveVelocity.Magnitude < minimumBallSpeed() then return false end
	if not Remote or type(Remote.fireParry) ~= "function" then return false end
	local fireOk, result, detail = pcall(Remote.fireParry, 1)
	if not fireOk or result == false then
		local message = fireOk and (detail or "envio de defesa indisponível") or result
		if Utils and type(Utils.recordError) == "function" and time - R.lastErrorAt >= 1 then R.lastErrorAt = time; Utils.recordError("AutoParry", tostring(message)) end
		return false
	end
	return true
end
local function updateVelocity(ball, position, time, dt, syncData, requireMovement)
	if R.lastBall ~= ball then
		R.lastBall = ball; R.lastPosition = nil; R.lastPositionAt = nil; R.lastMovingAt = nil
		R.velocity = Vector3.zero; R.lastSpeed = 0; R.lastApproaching = false; R.armed = true
		R.lastTargeted = false
	end
	local assemblyVelocity
	local ok = pcall(function() assemblyVelocity = GameInfo.getBallVelocity(ball) end)
	if ok and isValidVector3(assemblyVelocity) and assemblyVelocity.Magnitude > 0.1 then
		if not isPlausibleVelocity(assemblyVelocity, syncData) then
			R.velocity = Vector3.zero; R.lastMovingAt = nil
			R.lastPosition, R.lastPositionAt = position, time
			return false
		end
		R.velocity = assemblyVelocity; R.lastMovingAt = time
	else
		local previousPosition = R.lastPosition; local previousTime = R.lastPositionAt
		if previousPosition and previousTime then
			local elapsed = time - previousTime
			if elapsed > 0 then
				local rawVelocity = (position - previousPosition) / elapsed
				if not isPlausibleVelocity(rawVelocity, syncData) then
					R.velocity = Vector3.zero; R.lastMovingAt = nil
					R.lastPosition, R.lastPositionAt = position, time
					return false
				end
				if rawVelocity.Magnitude < 0.1 then
					if requireMovement or (R.lastMovingAt and time - R.lastMovingAt >= T.STATIONARY_TIMEOUT) then R.velocity = Vector3.zero end
				else
					R.lastMovingAt = time
					if R.velocity.Magnitude < 0.1 or R.velocity:Dot(rawVelocity) <= 0 then
						R.velocity = rawVelocity
					else
						local frameDt = isFiniteNumber(dt) and math.max(dt, 1 / 240) or 1 / 60; local alpha = frameDt / (T.VELOCITY_SMOOTHING_TAU + frameDt)
						R.velocity += (rawVelocity - R.velocity) * alpha
					end
				end
			end
		end
	end
	R.lastPosition = position; R.lastPositionAt = time; return true
end
local function onHeartbeat(character, root, dt, generation)
	if generation ~= R.generation or not R.alive or not R.bound then return end
	if not character.Parent or not root.Parent then return end
	local time = clock(); samplePing(time); local syncData = GameInfo and GameInfo.getSyncData and GameInfo.getSyncData()
	if type(syncData) == "table" and syncData.Teleported == true then
		if not R.teleported then enterTeleportLock(time) end
	elseif R.teleported and type(syncData) == "table" then
		leaveTeleportLock(time)
	end
	if R.teleported then clearBallState(); resetParryLock(); setPhase("waiting", "teleport_lock"); return end
	if not isAutoParryEnabled() then resetParryLock(); setPhase("waiting", "auto_parry_disabled"); return end
	if isSpamActive() then resetParryLock(); clearBallState(); setPhase("waiting", "spam_active"); return end
	if not isSystemActive() then resetParryLock(); setPhase("waiting", "system_inactive"); return end
	local ball, targeted, snapshot = readFrameState(time)
	if snapshot and R.lastSyncSequence ~= nil then
		local sequence = snapshot.syncSequence; local targetId = tonumber(snapshot.targetId)
		if type(sequence) == "number" then
			local delta = (sequence - R.lastSyncSequence) % 65536
			if delta > 32768 or (delta == 0 and R.lastTarget > 0 and targetId and targetId ~= R.lastTarget) then setPhase("waiting", "snapshot_older_than_target"); return end
		elseif R.lastTarget > 0 and targetId and targetId ~= R.lastTarget then
			setPhase("waiting", "snapshot_older_than_target"); return
		end
	end
	if snapshot and type(snapshot.syncSequence) == "number" then
		if R.lastSyncSequence == nil or snapshot.syncSequence ~= R.lastSyncSequence then R.lastTarget = tonumber(snapshot.targetId) or -1 end
		R.lastSyncSequence = snapshot.syncSequence
	end
	if not isValidBall(ball) then resetParryLock(); clearBallState(); setPhase("waiting", "ball_or_target_invalid"); return end
	if snapshot then observeTarget(tonumber(snapshot.targetId)) end
	if not targeted then
		resetParryLock(); R.targeted = false; R.lastApproaching = false; local positionOk, position = pcall(GameInfo.getBallPosition, ball)
		if not positionOk or not isValidVector3(position) or not updateVelocity(ball, position, time, dt, syncData) then clearBallState() end
		setPhase("waiting", "ball_or_target_invalid"); return
	end
	local positionOk, position = pcall(function() return GameInfo.getBallPosition(ball) end)
	if not positionOk or not isValidVector3(position) then resetParryLock(); return end
	if not updateVelocity(ball, position, time, dt, syncData, not R.lastTargeted) then resetParryLock(); setPhase("waiting", "ball_speed_outlier"); return end
	local rootPositionOk, rootPosition = pcall(function() return GameInfo.getRootPosition(root) end)
	if not rootPositionOk or not isValidVector3(rootPosition) then resetParryLock(); return end
	local delta = rootPosition - position; local distance = delta.Magnitude; local speed = R.velocity.Magnitude
	local approaching = speed >= minimumBallSpeed() and distance > 0 and R.velocity:Dot(delta) > 0
	if not R.lastTargeted then R.armed = true end
	R.lastTargeted = targeted; R.targeted = targeted; local resilienceBonus = getResilienceBonus(time)
	local parryRadius, leadTime = computeParryRadius(speed, R.ping, resilienceBonus, getWindowFactor()); R.lastDistance = distance; R.lastSpeed = speed; R.lastLeadTime = leadTime
	R.lastApproaching = approaching; R.targetId = tonumber(snapshot and snapshot.targetId) or -1; R.targetKnown = snapshot ~= nil and snapshot.targetId ~= nil
	if speed < minimumBallSpeed() then R.armed = true; setPhase("waiting", "ball_speed_invalid"); return end
	if not approaching then R.armed = true; setPhase("waiting", "ball_not_approaching"); return end
	if distance > parryRadius then setPhase("waiting", "outside_radius"); return end
	if R.firedForTarget then setPhase("waiting", "target_already_parried"); return end
	if isSpamActive() or not isSystemActive() or not isAutoParryEnabled() then resetParryLock(); clearBallState(); setPhase("waiting", "parry_gate_changed"); return end
	if R.lastSyncSequence ~= nil and R.lastTarget > 0 and R.player and R.lastTarget ~= R.player.UserId then setPhase("waiting", "target_changed"); return end
	if R.armed then
		local cycle = R.targetCycle; R.armed = false; R.firedForTarget = true
		if getRemoteParry(ball) then R.lastFireAt = clock(); setPhase("fired", "parry_requested") elseif R.targetCycle == cycle then R.firedForTarget = false; R.armed = true end
	end
end
local function detachCharacterInternal(reason)
	R.generation += 1; disconnectConnections(); invalidateLife(); R.root = nil
	resetTracking(); setPhase("detached", reason or "detach")
end
function AutoParry.setup(deps)
	if type(deps) ~= "table" then return false, "dependencias invalidas" end
	local remote = deps.Remote; local gameInfo = deps.GameInfo; local utils = deps.Utils
	if type(remote) ~= "table" or type(remote.fireParry) ~= "function" then return false, "dependencia ausente: Remote.fireParry" end
	if
		type(gameInfo) ~= "table"
		or type(gameInfo.getSnapshot) ~= "function"
		or type(gameInfo.isSnapshotValid) ~= "function"
		or type(gameInfo.getBall) ~= "function"
		or type(gameInfo.getSyncData) ~= "function"
		or type(gameInfo.getTargetId) ~= "function"
		or type(gameInfo.getDeflectRange) ~= "function"
		or type(gameInfo.getLocalPing) ~= "function"
		or type(gameInfo.getBallPosition) ~= "function"
		or type(gameInfo.getBallVelocity) ~= "function"
		or type(gameInfo.getRootPosition) ~= "function"
	then
		return false, "dependencia ausente: GameInfo"
	end
	if
		type(utils) ~= "table"
		or type(utils.getLocalPlayer) ~= "function"
		or type(utils.getRunService) ~= "function"
		or type(utils.getConfig) ~= "function"
		or type(utils.isActive) ~= "function"
		or type(utils.isSpamActive) ~= "function"
		or type(utils.trackCharacter) ~= "function"
		or type(utils.untrackCharacter) ~= "function"
		or type(utils.trackGlobal) ~= "function"
		or type(utils.untrackGlobal) ~= "function"
	then
		return false, "dependencia ausente: Utils"
	end
	detachCharacterInternal("setup"); Remote = remote; GameInfo = gameInfo; Utils = utils
	local playerOk, player = pcall(Utils.getLocalPlayer)
	if not playerOk or not player then return false, "Players.LocalPlayer indisponivel" end
	R.player = player; resetTracking(); setPhase("detached", "setup_complete"); return true
end
function AutoParry.bindCharacter(character)
	if not Remote or not GameInfo or not Utils then return false, "dependencias nao inicializadas" end
	detachCharacterInternal("rebind_start")
	if not character or not character.Parent then return false, "personagem indisponivel" end
	local generation = R.generation; local root = getRootPart(character)
	if not root then
		local ok, result = pcall(character.WaitForChild, character, "HumanoidRootPart", 10)
		if ok and typeof(result) == "Instance" and result:IsA("BasePart") then root = result end
	end
	if generation ~= R.generation or not root or not root.Parent then return false, "HumanoidRootPart indisponivel" end
	local runOk, runService = pcall(Utils.getRunService)
	if not runOk or not runService then return false, "RunService indisponivel" end
	local signal = runService.PostSimulation or runService.Heartbeat
	if not signal then return false, "RunService indisponivel" end
	local playerOk, player = pcall(Utils.getLocalPlayer)
	if not playerOk or not player then return false, "Players.LocalPlayer indisponivel" end
	R.root = root; R.player = player; R.alive = true; R.bound = true
	resetTracking(); setPhase("waiting", "character_bound")
	local heartbeatOk, heartbeatConnection = pcall(function()
		return signal:Connect(function(dt) onHeartbeat(character, root, dt, generation) end)
	end)
	if not heartbeatOk or not heartbeatConnection then detachCharacterInternal("heartbeat_bind_failed"); return false, "falha ao conectar RunService" end
	trackConnection(heartbeatConnection)
	local ancestryOk, ancestryConnection = pcall(function()
		return character.AncestryChanged:Connect(function(_, parent)
			if not parent and generation == R.generation then detachCharacterInternal("character_removed") end
		end)
	end)
	if not ancestryOk or not ancestryConnection then detachCharacterInternal("ancestry_bind_failed"); return false, "falha ao conectar AncestryChanged" end
	trackConnection(ancestryConnection); return true
end
function AutoParry.fire()
	if not R.alive or not R.bound then return false end
	if R.firedForTarget then return false end
	if isTeleportLocked() then return false end
	if not R.lastApproaching or R.lastSpeed < minimumBallSpeed() then return false end
	local cycle = R.targetCycle; R.armed = false; R.firedForTarget = true; local fired = getRemoteParry(R.lastBall)
	if not fired then
		if R.targetCycle == cycle then R.firedForTarget = false; R.armed = true end
		return false
	end
	R.lastFireAt = clock(); setPhase("fired", "manual_parry"); return true
end
function AutoParry.resetState() detachCharacterInternal("reset") end
function AutoParry.detachCharacter() detachCharacterInternal("detach") end
function AutoParry.teardown()
	detachCharacterInternal("teardown"); Remote = nil; GameInfo = nil; Utils = nil
	R.player = nil
end
function AutoParry.onBallSync(data)
	if type(data) ~= "table" or not R.alive or not R.bound then return end
	local sequence = data.Sequence or data.TeleportSequence
	if
		sequence == nil
		and GameInfo
		and type(GameInfo.getSyncSequence) == "function"
		and type(GameInfo.getSyncData) == "function"
		and data == GameInfo.getSyncData()
	then
		sequence = GameInfo.getSyncSequence()
	end
	if type(sequence) == "number" and sequence == sequence and sequence >= 0 and sequence < 65536 and sequence % 1 == 0 then
		if R.lastSyncSequence ~= nil then
			local delta = (sequence - R.lastSyncSequence) % 65536
			if delta == 0 or delta > 32768 then return true end
		end
		R.lastSyncSequence = sequence
	end
	local time = clock()
	if data.Teleported == true then enterTeleportLock(time, data.TeleportSequence); return true end
	if not leaveTeleportLock(time) then return true end
	local targetId = data.TargetPlayerID ~= nil and (tonumber(data.TargetPlayerID) or -1) or -1
	if data.TargetPlayerID == nil and GameInfo and type(GameInfo.getTargetId) == "function" then
		local ok, value = pcall(GameInfo.getTargetId)
		if ok then targetId = tonumber(value) or -1 end
	end
	observeTarget(targetId)
	if targetId > 0 and R.player and targetId ~= R.player.UserId then resetParryLock() end
	if targetId == -1 and R.lastTarget ~= -1 then clearBallState() end
	R.targetId = targetId; R.targetKnown = true; R.lastTarget = targetId; return true
end
function AutoParry.getTargetStatus()
	return {
		armed = R.armed == true and not R.firedForTarget,
		firedForTarget = R.firedForTarget == true,
		lastTargeted = R.lastTargeted == true,
		targeted = R.targeted == true,
		approaching = R.lastApproaching == true,
		targetId = R.targetId,
		targetKnown = R.targetKnown == true,
	}
end
local function getRootPosition()
	local root = R.root
	if root and root.Parent then return GameInfo.getRootPosition(root) end
	local player = R.player; local character = player and player.Character
	if not character then return nil end
	local candidate = getRootPart(character)
	if candidate and candidate.Parent then return GameInfo.getRootPosition(candidate) end
	return nil
end
function AutoParry.getTiming(snapshot, time, rootPosition, windowFactor)
	if type(snapshot) ~= "table" then return nil end
	time = tonumber(time) or clock(); local position = snapshot.position; local ball = snapshot.ball
	if not isValidVector3(position) and isValidBall(ball) then
		local ok, value = pcall(function() return GameInfo.getBallPosition(ball) end)
		if ok then position = value end
	end
	if not isValidVector3(rootPosition) then rootPosition = getRootPosition() end
	if not isValidVector3(position) or not isValidVector3(rootPosition) then return nil end
	local velocity
	local speed
	if isValidBall(ball) and R.lastBall == ball then
		local currentVelocity = getCurrentVelocity(ball)
		if isValidVector3(currentVelocity) and currentVelocity.Magnitude > 0.1 then velocity = currentVelocity; speed = currentVelocity.Magnitude end
	end
	if not isValidVector3(velocity) then velocity = snapshot.velocity end
	if not isValidVector3(velocity) and isValidBall(ball) then
		local ok, value = pcall(function() return GameInfo.getBallVelocity(ball) end)
		if ok and isValidVector3(value) then velocity = value end
	end
	if isValidVector3(velocity) then speed = velocity.Magnitude else speed = tonumber(snapshot.speed) or 0 end
	if not isFiniteNumber(speed) or speed < 0 then return nil end
	local delta = rootPosition - position; local distance = delta.Magnitude; local resilienceBonus = getResilienceBonus(time)
	local parryRadius, leadTime, noWindowRadius, pingRadius, deflectWindow, effectiveWindow, requestedFactor =
		computeParryRadius(speed, R.ping, resilienceBonus, windowFactor)
	local distanceToRadius = distance - parryRadius; local tti = speed > 0 and math.max(distanceToRadius, 0) / speed or math.huge
	local approaching = isValidVector3(velocity) and speed >= minimumBallSpeed() and distance > 0 and velocity:Dot(delta) > 0 or false
	return {
		distance = distance,
		speed = speed,
		parryRadius = parryRadius,
		fullRadius = parryRadius,
		pureRadius = T.BASE_RADIUS,
		noWindowParryRadius = noWindowRadius,
		pingRadius = pingRadius,
		resilienceBonus = resilienceBonus,
		leadTime = leadTime,
		deflectWindow = deflectWindow,
		effectiveWindow = effectiveWindow,
		windowFactor = requestedFactor,
		distanceToParryRadius = distanceToRadius,
		tti = tti,
		approaching = approaching,
		targeted = snapshot.targeted == true,
	}
end
function AutoParry.getRadius(mode, windowFactor, speedOverride): RadiusResult
	mode = mode or "geometry"
	if mode ~= "geometry" and mode ~= "tti" and mode ~= "speed_distance" then mode = "geometry" end
	local speed = tonumber(speedOverride)
	if not isFiniteNumber(speed) or speed < 0 then speed = R.lastSpeed end
	if not isFiniteNumber(speed) or speed < 0 then speed = 0 end
	local time = clock(); local resilienceBonus = getResilienceBonus(time)
	local fullRadius, leadTime, noWindowRadius, pingRadius, deflectWindow, effectiveWindow, requestedFactor =
		computeParryRadius(speed, R.ping, resilienceBonus, windowFactor)
	local value = fullRadius
	if mode == "tti" then
		value = speed > 0 and math.max(R.lastDistance - fullRadius, 0) / speed or math.huge
	elseif mode == "speed_distance" then
		value = {
			speed = speed,
			distance = R.lastDistance,
		}
	end
	local distanceToRadius = R.lastDistance - fullRadius; local tti = speed > 0 and math.max(distanceToRadius, 0) / speed or math.huge
	return {
		mode = mode,
		value = value,
		pureRadius = T.BASE_RADIUS,
		noWindowParryRadius = noWindowRadius,
		pingRadius = pingRadius,
		resilience = getResilienceStatus(),
		fullRadius = fullRadius,
		deflectWindow = deflectWindow,
		windowFactor = requestedFactor,
		effectiveWindow = effectiveWindow,
		leadTime = leadTime,
		distance = R.lastDistance,
		speed = speed,
		tti = tti,
	}
end
function AutoParry.getStatus()
	local time = clock(); local target = AutoParry.getTargetStatus(); local radius = AutoParry.getRadius("geometry", getWindowFactor()); local resilience = getResilienceStatus()
	local apiVersion
	if Utils and type(Utils.apiVersion) == "function" then
		local ok, value = pcall(Utils.apiVersion)
		if ok then apiVersion = value end
	end
	return {
		schema = apiVersion,
		api = {
			name = "AutoParry",
			version = 10,
			endpoints = {
				"getRadius",
				"getTiming",
				"getStatus",
				"getTargetStatus",
			},
			radiusModes = {
				"geometry",
				"tti",
				"speed_distance",
			},
			defaultWindowFactor = T.DEFAULT_WINDOW_FACTOR,
			windowFactorRange = {
				min = T.MIN_WINDOW_FACTOR,
				max = T.MAX_WINDOW_FACTOR,
			},
		},

		lifecycle = {
			phase = R.phase,
			reason = R.reason,
			bound = R.bound == true,
			alive = R.alive == true,
			generation = R.generation,
			lifeGeneration = R.lifeGeneration,
		},

		radius = radius,
		resilience = resilience,
		timing = {
			tti = radius.tti,
			ti = radius.tti,
			speed = R.lastSpeed,
			distance = R.lastDistance,
			distanceToRadius = R.lastDistance - radius.fullRadius,
			deflectWindow = radius.deflectWindow,
			effectiveWindow = radius.effectiveWindow,
			leadTime = R.lastLeadTime,
			noWindowParryRadius = radius.noWindowParryRadius,
			pingRadius = radius.pingRadius,
			approaching = R.lastApproaching == true,
		},

		ping = {
			oneWay = R.ping,
			raw = R.ping,
			minimum = nil,
		},

		target = target,
		cycle = {
			fired = R.armed == false,
			armed = R.armed == true,
			lastFireAt = R.lastFireAt,
			lastTTI = radius.tti,
		},

		config = {
			baseRadius = T.BASE_RADIUS,
			baseWindow = T.BASE_WINDOW,
			defaultWindowFactor = T.DEFAULT_WINDOW_FACTOR,
			windowFactorRange = {
				min = T.MIN_WINDOW_FACTOR,
				max = T.MAX_WINDOW_FACTOR,
			},
			minBallSpeed = minimumBallSpeed(),
		},

		timestamp = time,
	}
end
AutoParry.__contract = {
	requiresMethods = {
		Remote = { "fireParry" },
		GameInfo = {
			"getSnapshot",
			"isSnapshotValid",
			"getBall",
			"getSyncData",
			"getTargetId",
			"getDeflectRange",
			"getLocalPing",
			"getBallPosition",
			"getBallVelocity",
			"getRootPosition",
		},
		Utils = {
			"getLocalPlayer",
			"getRunService",
			"getConfig",
			"isActive",
			"isSpamActive",
			"trackCharacter",
			"untrackCharacter",
			"trackGlobal",
			"untrackGlobal",
		},
	},
	provides = {
		"setup",
		"bindCharacter",
		"detachCharacter",
		"onBallSync",
		"fire",
		"resetState",
		"getRadius",
		"getTiming",
		"getStatus",
	},
	requires = {
		Remote = "remote",
		GameInfo = "gameinfo",
		Utils = "utils",
	},

	onBallSync = true,
	bindCharacter = true,
	version = 10,
}

return AutoParry
