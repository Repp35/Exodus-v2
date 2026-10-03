--!strict
--!optimize 2
-- [[ autoparry ]]

-- Dependencies
local AutoParry = {}
local Remote: any = nil
local GameInfo: any = nil
local Utils: any = nil
local RemoteFireParry: any = nil
local GameInfoGetSnapshot: any = nil
local GameInfoIsSnapshotValid: any = nil
local GameInfoGetBall: any = nil
local GameInfoGetSyncData: any = nil
local GameInfoGetTargetId: any = nil
local UtilsGetLocalPlayer: any = nil
local UtilsGetRunService: any = nil
local UtilsGetConfig: any = nil
local UtilsIsActive: any = nil
local UtilsIsSpamActive: any = nil
local UtilsTrackCharacter: any = nil
local UtilsUntrackCharacter: any = nil
local UtilsGetWorkspace: any = nil
local UtilsTrackGlobal: any = nil
local UtilsUntrackGlobal: any = nil
local UtilsRecordTransition: any = nil

-- Constants
local CONSTANTS = {
	VELOCITY_SMOOTHING_TAU = 0.05,
	PING_SAMPLE_INTERVAL = 1,
	BASE_RADIUS = 8.5,
	BASE_WINDOW = 0.40,
	DEFAULT_WINDOW_FACTOR = 0.50,
	MIN_WINDOW_FACTOR = 0.0,
	MAX_WINDOW_FACTOR = 1.5,
	MIN_LEAD_TIME = 0.48,
	MAX_LEAD_TIME = 0.84,
	MIN_BALL_SPEED = 16,
	RES_PER_PARRY = 0.225,
	RES_CAP_STUDS = 32,
	HITBOX_OWN_WINDOW = 0.50,
	HITBOX_PROXIMITY = 12,
	HITBOX_GAP = 0.40,
	RESET_LOCK_BASE = 0.40,
	MAX_RES_STACK = math.floor(32 / 0.225),
}

local HITBOX_PROXIMITY_SQ = CONSTANTS.HITBOX_PROXIMITY * CONSTANTS.HITBOX_PROXIMITY
local Runtime = {
	phase = "detached",
	generation = 0,
	lifeGeneration = 0,
	alive = false,
	bound = false,
	player = nil,
	character = nil,
	root = nil,
	workspace = nil,
	connections = {},
	armed = true,
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
	lastRadius = 0,
	lastLeadTime = CONSTANTS.MIN_LEAD_TIME,
	lastFireAt = 0,
	lastApproaching = false,
	lastTarget = -1,
	lastWasMe = nil,
	targetId = -1,
	targetKnown = false,
	teleportLockUntil = 0,
	passivePhase = "idle",
	passiveBallAtValid = false,
	resilienceBonus = 0,
	resilienceBonusAt = -1,
}

-- Resilience
local Resilience = {
	stack = 0,
	lastFireBall = nil,
	lastFireAt = 0,
	lastHitboxAt = 0,
	hitboxConfirmed = false,
	lifeGeneration = 0,
}

local namespace: any = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState: any = type(namespace.AutoParryHitbox) == "table" and namespace.AutoParryHitbox
	or {
		connection = nil,
		workspace = nil,
		handler = nil,
	}
namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- Utility
local function clock(): number return os.clock() end
local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
local function isValidVector3(value: any): boolean return typeof(value) == "Vector3" end
local function isValidBall(ball: any): boolean
	return typeof(ball) == "Instance" and ball.Parent ~= nil and ball:IsA("BasePart")
end
local function distanceSquared(a: Vector3, b: Vector3): number
	local delta = a - b; return delta:Dot(delta)
end
local function getRootPart(character: Instance): BasePart?
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then return root end
	return nil
end

-- Phase
local function setPhase(nextPhase: string, reason: string)
	if Runtime.phase == nextPhase then return end
	local previousPhase = Runtime.phase; Runtime.phase = nextPhase
	if type(UtilsRecordTransition) == "function" then pcall(UtilsRecordTransition, "AutoParry", previousPhase, nextPhase, reason) end
end

-- Connections
local function trackConnection(connection: RBXScriptConnection?)
	if not connection then return end
	Runtime.connections[#Runtime.connections + 1] = connection
	if type(UtilsTrackCharacter) == "function" then pcall(UtilsTrackCharacter, connection) end
end
local function disconnectConnections()
	for index = #Runtime.connections, 1, -1 do
		local connection = Runtime.connections[index]; Runtime.connections[index] = nil
		if connection then
			if type(UtilsUntrackCharacter) == "function" then pcall(UtilsUntrackCharacter, connection) end
			pcall(function() connection:Disconnect() end)
		end
	end
end
local function resetParryLock()
	Runtime.armed = true; Runtime.lastTargeted = false
end
local function resetTracking()
	Runtime.armed = true; Runtime.lastTargeted = false; Runtime.targeted = false; Runtime.lastBall = nil
	Runtime.lastPosition = nil; Runtime.lastPositionAt = nil; Runtime.velocity = Vector3.zero; Runtime.ping = 0
	Runtime.pingAt = 0; Runtime.lastDistance = 0; Runtime.lastSpeed = 0; Runtime.lastRadius = 0
	Runtime.lastLeadTime = CONSTANTS.MIN_LEAD_TIME; Runtime.lastFireAt = 0; Runtime.lastApproaching = false; Runtime.lastTarget = -1
	Runtime.lastWasMe = nil; Runtime.targetId = -1; Runtime.targetKnown = false; Runtime.teleportLockUntil = 0
	Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false; Runtime.resilienceBonus = 0; Runtime.resilienceBonusAt = -1
end
local function resetResilience()
	Resilience.stack = 0; Resilience.lastFireBall = nil; Resilience.lastFireAt = 0; Resilience.lastHitboxAt = 0
	Resilience.hitboxConfirmed = false; Resilience.lifeGeneration = Runtime.lifeGeneration; Runtime.resilienceBonus = 0; Runtime.resilienceBonusAt = -1
end
local function invalidateLife()
	Runtime.lifeGeneration += 1; Runtime.alive = false; Runtime.bound = false; resetParryLock()
	resetResilience()
end
local function clearResilienceState()
	Resilience.stack = 0; Resilience.lastFireBall = nil; Resilience.lastFireAt = 0; Resilience.lastHitboxAt = 0
	Resilience.hitboxConfirmed = false; Runtime.resilienceBonus = 0; Runtime.resilienceBonusAt = -1
end
local function isResilienceUsable(): boolean
	if not Runtime.alive or not Runtime.bound or Resilience.lifeGeneration ~= Runtime.lifeGeneration then clearResilienceState(); return false end
	if not isFiniteNumber(Resilience.stack) or Resilience.stack < 0 or Resilience.stack > CONSTANTS.MAX_RES_STACK then clearResilienceState(); return false end
	return true
end
local function getResilienceBonus(time: number): number
	if not isResilienceUsable() then return 0 end
	if Runtime.resilienceBonusAt == time then return Runtime.resilienceBonus end
	Runtime.resilienceBonus = math.min(Resilience.stack * CONSTANTS.RES_PER_PARRY, CONSTANTS.RES_CAP_STUDS); Runtime.resilienceBonusAt = time; return Runtime.resilienceBonus
end
local function getResilienceStatus()
	local usable = isResilienceUsable()
	return {
		stack = usable and Resilience.stack or 0,
		size = usable and Runtime.resilienceBonus or 0,
		perParry = CONSTANTS.RES_PER_PARRY,
		cap = CONSTANTS.RES_CAP_STUDS,
		maxStack = CONSTANTS.MAX_RES_STACK,
	}
end
local function addResilienceStack(): boolean
	if not isResilienceUsable() then return false end
	if Resilience.stack >= CONSTANTS.MAX_RES_STACK then return false end
	Resilience.stack += 1; Runtime.resilienceBonusAt = -1; return true
end
local function getConfig()
	if type(UtilsGetConfig) ~= "function" then return nil end
	local ok, config = pcall(UtilsGetConfig)
	if ok and type(config) == "table" then return config end
	return nil
end

-- Configuration
local function isAutoParryEnabled(): boolean
	local config = getConfig()
	if not config then return true end
	return config.AutoParry ~= false
end
local function isSystemActive(): boolean
	if type(UtilsIsActive) ~= "function" then return true end
	local ok, active = pcall(UtilsIsActive); return ok and active == true
end
local function isSpamActive(): boolean
	if type(UtilsIsSpamActive) ~= "function" then return false end
	local ok, active = pcall(UtilsIsSpamActive); return ok and active == true
end

-- Timing
local function computeLeadTime(ping: number): number
	local validPing = isFiniteNumber(ping) and math.max(ping, 0) or 0; local leadTime = CONSTANTS.BASE_WINDOW + validPing
	leadTime = math.clamp(leadTime, CONSTANTS.MIN_LEAD_TIME, CONSTANTS.MAX_LEAD_TIME); leadTime = math.floor(leadTime * 100 + 0.5) / 100; return leadTime
end
local function computeParryRadius(speed: number, ping: number, resilienceBonus: number, windowFactor: number?)
	local validSpeed = isFiniteNumber(speed) and math.max(speed, 0) or 0; local leadTime = computeLeadTime(ping); local factor = tonumber(windowFactor)
	if not isFiniteNumber(factor) then factor = CONSTANTS.DEFAULT_WINDOW_FACTOR end
	factor = math.clamp(factor, 0, CONSTANTS.MAX_WINDOW_FACTOR); local validResilience = isFiniteNumber(resilienceBonus) and math.max(resilienceBonus, 0) or 0
	local baseRadius = CONSTANTS.BASE_RADIUS + validResilience
	local anticipation = validSpeed * leadTime * factor
	local noWindowRadius = baseRadius; local pingRadius = validSpeed * math.max(leadTime - CONSTANTS.BASE_WINDOW, 0); local fullRadius = baseRadius + anticipation
	local effectiveWindow = CONSTANTS.BASE_WINDOW * factor
	return fullRadius, leadTime, noWindowRadius, pingRadius, CONSTANTS.BASE_WINDOW, effectiveWindow, factor
end
local function readTargeted(snapshot: any): boolean
	if type(snapshot) == "table" and type(snapshot.targeted) == "boolean" then return snapshot.targeted end
	if type(GameInfoGetSyncData) == "function" then
		local ok, syncData = pcall(GameInfoGetSyncData)
		if ok and type(syncData) == "table" and type(syncData.Targeted) == "boolean" then return syncData.Targeted end
	end
	if type(GameInfoGetTargetId) == "function" and Runtime.player then
		local ok, targetId = pcall(GameInfoGetTargetId)
		if ok then return tonumber(targetId) == tonumber(Runtime.player.UserId) end
	end
	return false
end
local function readFrameState(time: number)
	local snapshot = nil
	if type(GameInfoGetSnapshot) == "function" then
		local ok, result = pcall(GameInfoGetSnapshot, nil, time)
		if ok and type(result) == "table" then
			local valid = true
			if type(GameInfoIsSnapshotValid) == "function" then local validOk, snapshotValid = pcall(GameInfoIsSnapshotValid, result, time); valid = validOk and snapshotValid == true end
			if valid then snapshot = result end
		end
	end
	local ball = snapshot and snapshot.ball or nil
	if not isValidBall(ball) and type(GameInfoGetBall) == "function" then
		local ok, result = pcall(GameInfoGetBall)
		if ok then ball = result end
	end
	if not isValidBall(ball) then return nil, false, snapshot end
	return ball, readTargeted(snapshot), snapshot
end

-- Ping
local function samplePing(time: number)
	if time - Runtime.pingAt < CONSTANTS.PING_SAMPLE_INTERVAL then return end
	Runtime.pingAt = time; local player = Runtime.player
	if not player then return end
	local ok, value = pcall(function() return player:GetNetworkPing() end)
	if ok and isFiniteNumber(value) and value >= 0 then Runtime.ping = value end
end
local function getRemoteParry(ball: any): boolean
	if type(RemoteFireParry) ~= "function" then return false end
	local ok, result = pcall(RemoteFireParry, 1)
	if not ok or result == false then return false end
	local time = clock(); Resilience.hitboxConfirmed = false; local firedBall = ball
	if not isValidBall(firedBall) and type(GameInfoGetBall) == "function" then
		local ballOk, currentBall = pcall(GameInfoGetBall)
		if ballOk then firedBall = currentBall end
	end
	if
		isValidBall(firedBall)
		and Runtime.alive
		and Runtime.bound
		and Resilience.lifeGeneration == Runtime.lifeGeneration
	then
		Resilience.lastFireBall = firedBall; Resilience.lastFireAt = time
	else
		Resilience.lastFireBall = nil; Resilience.lastFireAt = 0
	end
	return true
end
local function fireAfterDetection(ball: any): boolean
	if not Runtime.alive or not Runtime.bound then return false end
	local fired = getRemoteParry(ball)
	if not fired then Runtime.armed = true; return false end
	Runtime.armed = false; Runtime.lastFireAt = clock(); setPhase("fired", "parry_requested"); return true
end

-- Hitbox
local function handleHitbox(instance: Instance)
	if instance.Name ~= "HitboxGrow" then return end
	if not instance:IsA("BasePart") then return end
	if Resilience.hitboxConfirmed then return end
	if not isResilienceUsable() then return end
	if type(UtilsIsActive) == "function" then
		local ok, active = pcall(UtilsIsActive)
		if not ok or active ~= true then return end
	end
	local time = clock()
	if time - Resilience.lastFireAt > CONSTANTS.HITBOX_OWN_WINDOW then return end
	if time - Resilience.lastHitboxAt < CONSTANTS.HITBOX_GAP then return end
	local ball = Resilience.lastFireBall
	if not isValidBall(ball) then return end
	local hitboxPosition = instance.Position; local ballPosition = ball.Position
	if not isValidVector3(hitboxPosition) or not isValidVector3(ballPosition) then return end
	if distanceSquared(ballPosition, hitboxPosition) > HITBOX_PROXIMITY_SQ then return end
	if not Runtime.alive or not Runtime.bound or Resilience.lifeGeneration ~= Runtime.lifeGeneration then return end
	Resilience.hitboxConfirmed = true; Resilience.lastHitboxAt = time; addResilienceStack()
end
local function uninstallHitboxHook()
	local connection = HitboxState.connection
	if not connection then return end
	if type(UtilsUntrackGlobal) == "function" then pcall(UtilsUntrackGlobal, connection) end
	pcall(function() connection:Disconnect() end)
	HitboxState.connection = nil; HitboxState.workspace = nil
end
local function installHitboxHook(): boolean
	local workspaceService = Runtime.workspace
	if not workspaceService then return false end
	if HitboxState.connection and HitboxState.workspace == workspaceService then return true end
	uninstallHitboxHook()
	local ok, connection = pcall(function()
		return workspaceService.DescendantAdded:Connect(function(instance)
			local handler = HitboxState.handler
			if handler then handler(instance) end
		end)
	end)
	if not ok or not connection then return false end
	HitboxState.connection = connection; HitboxState.workspace = workspaceService
	if type(UtilsTrackGlobal) == "function" then pcall(UtilsTrackGlobal, connection) end
	return true
end
local function isBallInParryWindow(time: number)
	local ball, _, snapshot = readFrameState(time)
	if not isValidBall(ball) then return false, false end
	local root = Runtime.root
	if not root or not root.Parent then return false, false end
	local position = snapshot and snapshot.position or nil
	if not isValidVector3(position) then
		local ok, value = pcall(function() return ball.Position end)
		if not ok then return false, false end
		position = value
	end
	local speed = snapshot and tonumber(snapshot.speed) or nil
	if not isFiniteNumber(speed) then
		local ok, velocity = pcall(function() return ball.AssemblyLinearVelocity end)
		if ok and isValidVector3(velocity) then speed = velocity.Magnitude end
	end
	if not isFiniteNumber(speed) or speed < CONSTANTS.MIN_BALL_SPEED then return false, false end
	local bonus = getResilienceBonus(time); local radius = computeParryRadius(speed, Runtime.ping, bonus, 1); local distance = (root.Position - position).Magnitude; return distance <= radius, true
end
local function clearBallState()
	Runtime.targeted = false; Runtime.lastBall = nil; Runtime.lastPosition = nil; Runtime.lastPositionAt = nil
	Runtime.velocity = Vector3.zero; Runtime.lastDistance = 0; Runtime.lastSpeed = 0; Runtime.lastRadius = 0
	Runtime.lastApproaching = false
end
local function updateVelocity(ball: BasePart, position: Vector3, time: number, dt: number)
	if Runtime.lastBall ~= ball then Runtime.lastBall = ball; Runtime.lastPosition = nil; Runtime.lastPositionAt = nil; Runtime.velocity = Vector3.zero end
	local assemblyVelocity: Vector3?
	local ok = pcall(function() assemblyVelocity = ball.AssemblyLinearVelocity end)
	if ok and isValidVector3(assemblyVelocity) and assemblyVelocity.Magnitude > 0.1 then
		Runtime.velocity = assemblyVelocity
	else
		local previousPosition = Runtime.lastPosition; local previousTime = Runtime.lastPositionAt
		if previousPosition and previousTime then
			local elapsed = time - previousTime
			if elapsed > 0 then
				local rawVelocity = (position - previousPosition) / elapsed; local frameDt = isFiniteNumber(dt) and math.max(dt, 1 / 240) or 1 / 60
				local alpha = frameDt / (CONSTANTS.VELOCITY_SMOOTHING_TAU + frameDt); Runtime.velocity = Runtime.velocity + (rawVelocity - Runtime.velocity) * alpha
			end
		end
	end
	Runtime.lastPosition = position; Runtime.lastPositionAt = time
end

-- Heartbeat
local function onHeartbeat(character: Model, root: BasePart, dt: number, generation: number)
	if generation ~= Runtime.generation or not Runtime.alive or not Runtime.bound then return end
	if not character.Parent or not root.Parent then return end
	local time = clock(); samplePing(time)
	if not isAutoParryEnabled() then resetParryLock(); setPhase("waiting", "auto_parry_disabled"); return end
	if not isSystemActive() then resetParryLock(); return end
	if time < Runtime.teleportLockUntil then resetParryLock(); setPhase("waiting", "teleport_lock"); return end
	local ball, targeted, snapshot = readFrameState(time)
	if not isValidBall(ball) then resetParryLock(); clearBallState(); setPhase("waiting", "ball_unavailable"); return end
	local position = ball.Position
	if not isValidVector3(position) then return end
	updateVelocity(ball, position, time, dt); local rootPosition = root.Position
	if not isValidVector3(rootPosition) then return end
	local delta = rootPosition - position; local distance = delta.Magnitude; local speed = Runtime.velocity.Magnitude
	if not targeted then Runtime.armed = true
	elseif not Runtime.lastTargeted then Runtime.armed = true end
	Runtime.lastTargeted = targeted; Runtime.targeted = targeted; local resilienceBonus = getResilienceBonus(time)
	local parryRadius, leadTime =
		computeParryRadius(speed, Runtime.ping, resilienceBonus, CONSTANTS.DEFAULT_WINDOW_FACTOR)
	Runtime.lastDistance = distance; Runtime.lastSpeed = speed; Runtime.lastRadius = parryRadius; Runtime.lastLeadTime = leadTime
	Runtime.lastApproaching = false; Runtime.resilienceBonus = resilienceBonus; Runtime.targetId = tonumber(snapshot and snapshot.targetId) or -1
	Runtime.targetKnown = snapshot ~= nil and snapshot.targetId ~= nil
	if not targeted then setPhase("waiting", "not_targeted"); return end
	if distance > parryRadius then setPhase("waiting", "outside_radius"); return end
	if Runtime.armed then Runtime.armed = false; setPhase("detecting", "parry_detected"); task.defer(fireAfterDetection, ball) end
end

-- Lifecycle
local function detachCharacterInternal(reason: string?)
	Runtime.generation += 1; disconnectConnections(); invalidateLife(); Runtime.character = nil
	Runtime.root = nil; resetTracking(); setPhase("detached", reason or "detach")
end

-- Setup
function AutoParry.setup(deps: any)
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
		or type(utils.getWorkspace) ~= "function"
		or type(utils.trackGlobal) ~= "function"
		or type(utils.untrackGlobal) ~= "function"
	then
		return false, "dependencia ausente: Utils"
	end
	uninstallHitboxHook(); detachCharacterInternal("setup"); Remote = remote; GameInfo = gameInfo
	Utils = utils; RemoteFireParry = remote.fireParry; GameInfoGetSnapshot = gameInfo.getSnapshot; GameInfoIsSnapshotValid = gameInfo.isSnapshotValid
	GameInfoGetBall = gameInfo.getBall; GameInfoGetSyncData = gameInfo.getSyncData; GameInfoGetTargetId = gameInfo.getTargetId; UtilsGetLocalPlayer = utils.getLocalPlayer
	UtilsGetRunService = utils.getRunService; UtilsGetConfig = utils.getConfig; UtilsIsActive = utils.isActive; UtilsIsSpamActive = utils.isSpamActive
	UtilsTrackCharacter = utils.trackCharacter; UtilsUntrackCharacter = utils.untrackCharacter; UtilsGetWorkspace = utils.getWorkspace; UtilsTrackGlobal = utils.trackGlobal
	UtilsUntrackGlobal = utils.untrackGlobal; UtilsRecordTransition = utils.recordTransition; local playerOk, player = pcall(UtilsGetLocalPlayer)
	if not playerOk or not player then return false, "Players.LocalPlayer indisponivel" end
	Runtime.player = player; local workspaceOk, workspaceService = pcall(UtilsGetWorkspace); Runtime.workspace = workspaceOk and workspaceService or nil; HitboxState.handler = handleHitbox
	resetTracking(); resetResilience(); installHitboxHook(); setPhase("detached", "setup_complete")
	return true
end
function AutoParry.bindCharacter(character: Model)
	if not Remote or not GameInfo or not Utils then return false, "dependencias nao inicializadas" end
	detachCharacterInternal("rebind_start")
	if not character or not character.Parent then return false, "personagem indisponivel" end
	local generation = Runtime.generation; local root = getRootPart(character)
	if not root then
		local ok, result = pcall(character.WaitForChild, character, "HumanoidRootPart", 10)
		if ok and typeof(result) == "Instance" and result:IsA("BasePart") then root = result end
	end
	if generation ~= Runtime.generation or not root or not root.Parent then return false, "HumanoidRootPart indisponivel" end
	local runOk, runService = pcall(UtilsGetRunService)
	if not runOk or not runService then return false, "RunService indisponivel" end
	local signal = runService.PostSimulation or runService.Heartbeat
	if not signal then return false, "RunService indisponivel" end
	local playerOk, player = pcall(UtilsGetLocalPlayer)
	if not playerOk or not player then return false, "Players.LocalPlayer indisponivel" end
	Runtime.character = character; Runtime.root = root; Runtime.player = player; Runtime.alive = true
	Runtime.bound = true; resetTracking(); Resilience.lifeGeneration = Runtime.lifeGeneration; installHitboxHook()
	setPhase("waiting", "character_bound")
	local heartbeatOk, heartbeatConnection = pcall(function()
		return signal:Connect(function(dt) onHeartbeat(character, root, dt, generation) end)
	end)
	if not heartbeatOk or not heartbeatConnection then detachCharacterInternal("heartbeat_bind_failed"); return false, "falha ao conectar RunService" end
	trackConnection(heartbeatConnection)
	local ancestryOk, ancestryConnection = pcall(function()
		return character.AncestryChanged:Connect(function(_, parent)
			if not parent and generation == Runtime.generation then detachCharacterInternal("character_removed") end
		end)
	end)
	if not ancestryOk or not ancestryConnection then detachCharacterInternal("ancestry_bind_failed"); return false, "falha ao conectar AncestryChanged" end
	trackConnection(ancestryConnection); return true
end
function AutoParry.fire(): boolean
	if not Runtime.alive or not Runtime.bound then return false end
	local fired = getRemoteParry(Runtime.lastBall)
	if not fired then return false end
	Runtime.armed = false; Runtime.lastFireAt = clock(); setPhase("fired", "manual_parry"); return true
end
function AutoParry.resetState() detachCharacterInternal("reset") end
function AutoParry.detachCharacter() detachCharacterInternal("detach") end
function AutoParry.teardown()
	uninstallHitboxHook(); detachCharacterInternal("teardown"); HitboxState.handler = nil; Remote = nil
	GameInfo = nil; Utils = nil; RemoteFireParry = nil; GameInfoGetSnapshot = nil
	GameInfoIsSnapshotValid = nil; GameInfoGetBall = nil; GameInfoGetSyncData = nil; GameInfoGetTargetId = nil
	UtilsGetLocalPlayer = nil; UtilsGetRunService = nil; UtilsGetConfig = nil; UtilsIsActive = nil
	UtilsIsSpamActive = nil; UtilsTrackCharacter = nil; UtilsUntrackCharacter = nil; UtilsGetWorkspace = nil
	UtilsTrackGlobal = nil; UtilsUntrackGlobal = nil; UtilsRecordTransition = nil; Runtime.player = nil
	Runtime.workspace = nil
end
function AutoParry.onBallSync(data: any)
	if type(data) ~= "table" or not Runtime.alive or not Runtime.bound then return end
	local time = clock()
	if data.Teleported == true or data.Grace == true or data.OldGrace == true then
		Runtime.teleportLockUntil =
			math.max(Runtime.teleportLockUntil, time + CONSTANTS.RESET_LOCK_BASE + Runtime.ping * 0.5)
		resetParryLock(); Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false; setPhase("waiting", "teleport_lock")
		return
	end
	local targetId = -1
	if type(GameInfoGetTargetId) == "function" then
		local ok, value = pcall(GameInfoGetTargetId)
		if ok then targetId = tonumber(value) or -1 end
	end
	if targetId == -1 then targetId = tonumber(data.TargetPlayerID) or -1 end
	Runtime.targetId = targetId; Runtime.targetKnown = true; local previousWasMe = Runtime.lastWasMe; local isMe = Runtime.player ~= nil and targetId == tonumber(Runtime.player.UserId)
	local spamActive = isSpamActive()
	if targetId == Runtime.lastTarget and previousWasMe ~= nil then
		if spamActive and isMe then
			if Runtime.passivePhase ~= "awaiting_leave" then Runtime.passivePhase = "awaiting_leave"; Runtime.passiveBallAtValid = false end
			local inside, valid = isBallInParryWindow(time)
			if valid and inside then Runtime.passiveBallAtValid = true end
		else
			Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false
		end
		return true
	end
	Runtime.lastTarget = targetId; Runtime.lastWasMe = isMe
	if not spamActive then Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false; return true end
	if isMe then Runtime.passivePhase = "awaiting_leave"; local inside, valid = isBallInParryWindow(time); Runtime.passiveBallAtValid = valid and inside; return true end
	if Runtime.passivePhase == "awaiting_leave" then
		if Runtime.passiveBallAtValid and isResilienceUsable() then addResilienceStack() end
	end
	Runtime.passivePhase = "idle"; Runtime.passiveBallAtValid = false; return true
end
function AutoParry.getTargetStatus()
	return {
		armed = Runtime.armed == true,
		lastTargeted = Runtime.lastTargeted == true,
		targeted = Runtime.targeted == true,
		approaching = Runtime.lastApproaching == true,
		targetId = Runtime.targetId,
		targetKnown = Runtime.targetKnown == true,
	}
end
local function getRootPosition(): Vector3?
	local root = Runtime.root
	if root and root.Parent then return root.Position end
	local player = Runtime.player; local character = player and player.Character
	if not character then return nil end
	local candidate = getRootPart(character)
	if candidate and candidate.Parent then return candidate.Position end
	return nil
end
function AutoParry.getTiming(snapshot: any, time: number?, rootPosition: Vector3?, windowFactor: number?)
	if type(snapshot) ~= "table" then return nil end
	time = tonumber(time) or clock(); local position = snapshot.position; local ball = snapshot.ball
	if not isValidVector3(position) and isValidBall(ball) then
		local ok, value = pcall(function() return ball.Position end)
		if ok then position = value end
	end
	if not isValidVector3(rootPosition) then rootPosition = getRootPosition() end
	if not isValidVector3(position) or not isValidVector3(rootPosition) then return nil end
	local velocity: Vector3?
	local speed: number?
	if isValidBall(ball) and Runtime.lastBall == ball then
		velocity = Runtime.velocity; speed = Runtime.lastSpeed
	else
		velocity = snapshot.velocity
		if not isValidVector3(velocity) and isValidBall(ball) then
			local ok, value = pcall(function() return ball.AssemblyLinearVelocity end)
			if ok and isValidVector3(value) then velocity = value end
		end
		if isValidVector3(velocity) then speed = velocity.Magnitude
		else speed = tonumber(snapshot.speed) or 0 end
	end
	if not isFiniteNumber(speed) or speed < 0 then return nil end
	local delta = rootPosition - position; local distance = delta.Magnitude; local resilienceBonus = getResilienceBonus(time)
	local parryRadius, leadTime, noWindowRadius, pingRadius, deflectWindow, effectiveWindow, requestedFactor =
		computeParryRadius(speed, Runtime.ping, resilienceBonus, windowFactor)
	local distanceToRadius = distance - parryRadius; local tti = speed > 0 and math.max(distanceToRadius, 0) / speed or math.huge
	local approaching = isValidVector3(velocity) and distance > 0 and velocity:Dot(delta) > 0 or false
	return {
		distance = distance,
		speed = speed,
		parryRadius = parryRadius,
		fullRadius = parryRadius,
		pureRadius = CONSTANTS.BASE_RADIUS,
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
function AutoParry.getRadius(mode: string?, windowFactor: number?, speedOverride: number?)
	mode = mode or "geometry"
	if mode ~= "geometry" and mode ~= "tti" and mode ~= "speed_distance" then mode = "geometry" end
	local speed = tonumber(speedOverride)
	if not isFiniteNumber(speed) or speed < 0 then speed = Runtime.lastSpeed end
	if not isFiniteNumber(speed) or speed < 0 then speed = 0 end
	local time = clock(); local resilienceBonus = getResilienceBonus(time)
	local fullRadius, leadTime, noWindowRadius, pingRadius, deflectWindow, effectiveWindow, requestedFactor =
		computeParryRadius(speed, Runtime.ping, resilienceBonus, windowFactor)
	local value: any = fullRadius
	if mode == "tti" then
		value = speed > 0 and math.max(Runtime.lastDistance - fullRadius, 0) / speed or math.huge
	elseif mode == "speed_distance" then
		value = {
			speed = speed,
			distance = Runtime.lastDistance,
		}

	end
	local distanceToRadius = Runtime.lastDistance - fullRadius; local tti = speed > 0 and math.max(distanceToRadius, 0) / speed or math.huge
	return {
		mode = mode,
		value = value,
		pureRadius = CONSTANTS.BASE_RADIUS,
		noWindowParryRadius = noWindowRadius,
		pingRadius = pingRadius,
		resilience = getResilienceStatus(),
		fullRadius = fullRadius,
		deflectWindow = deflectWindow,
		windowFactor = requestedFactor,
		effectiveWindow = effectiveWindow,
		leadTime = leadTime,
		distance = Runtime.lastDistance,
		speed = speed,
		tti = tti,
	}
end
function AutoParry.getStatus()
	local time = clock(); local target = AutoParry.getTargetStatus(); local radius = AutoParry.getRadius("geometry", CONSTANTS.DEFAULT_WINDOW_FACTOR); local resilience = getResilienceStatus()
	local apiVersion
	local apiVersionFunction = Utils and Utils.apiVersion
	if type(apiVersionFunction) == "function" then
		local ok, value = pcall(apiVersionFunction)
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
			defaultWindowFactor = CONSTANTS.DEFAULT_WINDOW_FACTOR,
			windowFactorRange = {
				min = CONSTANTS.MIN_WINDOW_FACTOR,
				max = CONSTANTS.MAX_WINDOW_FACTOR,
			},
		},

		lifecycle = {
			phase = Runtime.phase,
			bound = Runtime.bound == true,
			alive = Runtime.alive == true,
			generation = Runtime.generation,
			lifeGeneration = Runtime.lifeGeneration,
		},

		radius = radius,
		resilience = resilience,
		timing = {
			tti = radius.tti,
			ti = radius.tti,
			speed = Runtime.lastSpeed,
			distance = Runtime.lastDistance,
			distanceToRadius = Runtime.lastDistance - radius.fullRadius,
			deflectWindow = CONSTANTS.BASE_WINDOW,
			effectiveWindow = CONSTANTS.BASE_WINDOW * CONSTANTS.DEFAULT_WINDOW_FACTOR,
			leadTime = Runtime.lastLeadTime,
			noWindowParryRadius = radius.noWindowParryRadius,
			pingRadius = radius.pingRadius,
			approaching = Runtime.lastApproaching == true,
		},

		ping = {
			oneWay = Runtime.ping * 0.5,
			raw = Runtime.ping,
			minimum = nil,
		},

		target = target,
		cycle = {
			fired = Runtime.armed == false,
			armed = Runtime.armed == true,
			lastFireAt = Runtime.lastFireAt,
			lastTTI = radius.tti,
		},

		config = {
			baseRadius = CONSTANTS.BASE_RADIUS,
			baseWindow = CONSTANTS.BASE_WINDOW,
			defaultWindowFactor = CONSTANTS.DEFAULT_WINDOW_FACTOR,
			windowFactorRange = {
				min = CONSTANTS.MIN_WINDOW_FACTOR,
				max = CONSTANTS.MAX_WINDOW_FACTOR,
			},
			minBallSpeed = CONSTANTS.MIN_BALL_SPEED,
		},

		timestamp = time,
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
	version = 10,
}

return AutoParry
