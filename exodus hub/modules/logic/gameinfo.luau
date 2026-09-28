-- [[ gameinfo ]]

local GameInfo = {}
local Utils
local Players
local Workspace

-- tuning
local T = {
	BALL_CACHE_TTL = 0.1,
	SYNC_FRESH_TIME = 1.0,
	PREDICTION_HORIZON = 0.6,
	TELEPORT_EVENT_TIME = 0.5,
	SNAPSHOT_LIFETIME = 0.25,
	ACQUIRE_RETRY_TIME = 0.1,
	PROVIDER_RECHECK_TIME = 0.5,
	ABILITY_RETRY_TIME = 2.0,
	SNAPSHOT_SCHEMA = 2,
}

-- state
local State = {
	ball = nil,
	ballAt = 0,
	speed = 0,
	speedAt = 0,
	maxSpeed = 0,
	acceleration = 0,
	realPosition = Vector3.new(0, 0, 0),
	hasRealPosition = false,
	target = nil,
	highlightTarget = nil,
	lastSyncAt = 0,
	lastSyncData = nil,
	syncPayloadType = "none",
	syncEventAt = 0,
	positionAt = 0,
	deflectDirection = Vector3.new(0, 0, 0),
	teleported = false,
	teleportedAt = 0,
}

local deflectAbility = nil
local abilityAttempted = false
local abilityCheckedAt = 0
local gameInfoModule = nil
local gameInfoProvider = nil
local gameInfoCheckedAt = 0
local gameInfoProviderStatus = "not_checked"
local gameInfoProviderError = nil
local ballReplicatorModule = nil
local ballReplicatorProvider = nil
local ballReplicatorCheckedAt = 0
local ballReplicatorAttempted = false
local ballReplicatorStatus = "not_checked"
local ballReplicatorError = nil
local refreshDecodedSync = nil
local ballSource = "none"
local lastReportedIssue = nil
local cachedCharacter = nil
local cachedRoot = nil
local function clearSyncState()
	State.speed = 0; State.speedAt = 0; State.maxSpeed = 0; State.acceleration = 0
	State.realPosition = Vector3.new(0, 0, 0); State.hasRealPosition = false
	State.target = nil; State.highlightTarget = nil; State.lastSyncAt = 0; State.lastSyncData = nil; State.syncPayloadType = "none"; State.syncEventAt = 0; State.positionAt = 0
	State.deflectDirection = Vector3.new(0, 0, 0); State.teleported = false; State.teleportedAt = 0
end

-- reset
local function resetState()
	State.ball = nil; State.ballAt = 0; clearSyncState(); cachedCharacter = nil
	cachedRoot = nil; gameInfoModule = nil; gameInfoProvider = nil; gameInfoCheckedAt = 0
	gameInfoProviderStatus = "not_checked"; gameInfoProviderError = nil; ballSource = "none"; lastReportedIssue = nil
	ballReplicatorModule = nil; ballReplicatorProvider = nil; ballReplicatorCheckedAt = 0; ballReplicatorAttempted = false
	ballReplicatorStatus = "not_checked"; ballReplicatorError = nil
end

-- ball
local function isBall(instance)
	return typeof(instance) == "Instance"
		and instance.Parent ~= nil
		and instance:IsA("BasePart")
end
local function resolveGameInfoProvider(time)
	time = time or Utils.now()
	if gameInfoProvider and gameInfoModule and gameInfoModule.Parent ~= nil
		and time - gameInfoCheckedAt < T.PROVIDER_RECHECK_TIME
	then
		return gameInfoProvider
	end
	if gameInfoCheckedAt > 0 and time - gameInfoCheckedAt < T.ACQUIRE_RETRY_TIME then
		return nil
	end
	gameInfoCheckedAt = time
	gameInfoModule = nil; gameInfoProvider = nil; gameInfoProviderError = nil
	local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then gameInfoProviderStatus = "replicated_storage_missing"; return nil end
	local ts = replicatedStorage and replicatedStorage:FindFirstChild("TS")
	if not ts then gameInfoProviderStatus = "ts_folder_missing"; return nil end
	local candidate = ts and ts:FindFirstChild("GameInfo")
	if not candidate then gameInfoProviderStatus = "gameinfo_module_missing"; return nil end
	if not candidate:IsA("ModuleScript") then gameInfoProviderStatus = "gameinfo_instance_not_module"; return nil end
	gameInfoModule = candidate
	local ok, result = pcall(require, candidate)
	if not ok then
		gameInfoProviderStatus = "require_failed"
		gameInfoProviderError = tostring(result)
		return nil
	end
	if type(result) ~= "table" then gameInfoProviderStatus = "require_returned_non_table"; return nil end
	if type(result.GameInfo) == "table" then
		gameInfoProvider = result.GameInfo
	elseif result.BallModel ~= nil then
		-- Também aceita versões que exponham BallModel diretamente.
		gameInfoProvider = result
	end
	gameInfoProviderStatus = gameInfoProvider and "provider_ready" or "provider_table_missing"
	return gameInfoProvider
end
local function getProviderBall(time)
	local provider = resolveGameInfoProvider(time)
	local ball = provider and provider.BallModel
	if isBall(ball) then gameInfoProviderStatus = "ballmodel_found"; return ball end
	if provider and ball == nil then gameInfoProviderStatus = "ballmodel_missing"
	elseif provider then gameInfoProviderStatus = "ballmodel_not_basepart" end
	return nil
end
local function resolveBallReplicator(time)
	time = time or Utils.now()
	if ballReplicatorProvider and ballReplicatorModule and ballReplicatorModule.Parent ~= nil
		and time - ballReplicatorCheckedAt < T.PROVIDER_RECHECK_TIME
	then
		return ballReplicatorProvider
	end
	if ballReplicatorAttempted and time - ballReplicatorCheckedAt < T.ACQUIRE_RETRY_TIME then return nil end
	ballReplicatorAttempted = true; ballReplicatorCheckedAt = time
	ballReplicatorModule = nil; ballReplicatorProvider = nil; ballReplicatorError = nil
	local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then ballReplicatorStatus = "replicated_storage_missing"; return nil end
	local ts = replicatedStorage:FindFirstChild("TS")
	if not ts then ballReplicatorStatus = "ts_folder_missing"; return nil end
	local folder = ts:FindFirstChild("BallReplicator")
	if not folder then ballReplicatorStatus = "ballreplicator_folder_missing"; return nil end
	local candidate = folder:FindFirstChild("BallReplicator")
	if not candidate then ballReplicatorStatus = "ballreplicator_module_missing"; return nil end
	if not candidate:IsA("ModuleScript") then ballReplicatorStatus = "ballreplicator_instance_not_module"; return nil end
	ballReplicatorModule = candidate
	local ok, result = pcall(require, candidate)
	if not ok then
		ballReplicatorStatus = "require_failed"
		ballReplicatorError = tostring(result)
		return nil
	end
	if type(result) ~= "table" then ballReplicatorStatus = "require_returned_non_table"; return nil end
	if type(result.BallReplicator) == "table" then
		ballReplicatorProvider = result.BallReplicator
	elseif result.syncData ~= nil then
		ballReplicatorProvider = result
	end
	ballReplicatorStatus = ballReplicatorProvider and "provider_ready" or "provider_table_missing"
	return ballReplicatorProvider
end
local function getDecodedSyncData(time)
	local provider = resolveBallReplicator(time)
	if not provider then return nil end
	local ok, data = pcall(function() return provider.syncData end)
	if not ok then
		ballReplicatorStatus = "syncdata_read_failed"
		ballReplicatorError = tostring(data)
		return nil
	end
	if type(data) ~= "table" then
		ballReplicatorStatus = "syncdata_not_table"
		return nil
	end
	ballReplicatorStatus = "syncdata_ready"
	return data
end
local function setBall(ball, source)
	if isBall(ball) then
		if State.ball ~= ball then clearSyncState() end
		State.ball = ball; State.ballAt = Utils.now(); ballSource = source or ballSource
	end
end
local function clearBall(ball)
	if State.ball == ball then State.ball = nil; State.ballAt = Utils.now(); ballSource = "none"; clearSyncState() end
end
local function getBall()
	local time = Utils.now(); local cached = State.ball
	if cached and cached.Parent ~= nil and time - State.ballAt < T.BALL_CACHE_TTL then return cached end
	local ball = getProviderBall(time)
	local source = ball and "TS.GameInfo.GameInfo.BallModel" or nil
	if not ball then
		ball = Workspace:FindFirstChild("GameBall")
		if ball then source = "Workspace.GameBall" end
		if not ball then
			ball = Workspace:FindFirstChild("GameBall", true)
			if ball then source = "Workspace descendant named GameBall" end
		end
	end
	if isBall(ball) then setBall(ball, source); return ball end
	if ball ~= nil then gameInfoProviderStatus = "workspace_gameball_not_basepart" end
	State.ball = nil; State.ballAt = time; ballSource = "none"; return nil
end

-- motion
local ZERO_VELOCITY = Vector3.new(0, 0, 0)
local function getAssemblyVelocity(ball)
	local velocity = ball.AssemblyLinearVelocity; return typeof(velocity) == "Vector3" and velocity or ZERO_VELOCITY
end
local function resolveTime(time) return Utils.isFiniteNumber(time) and time or Utils.now() end
local function ballSpeed(ball, time, velocity)
	if not isBall(ball) then return 0 end
	time = resolveTime(time)
	if State.speedAt > 0 and time >= State.speedAt and time - State.speedAt < T.PREDICTION_HORIZON then return State.speed end
	return (velocity or getAssemblyVelocity(ball)).Magnitude
end
local function ballPosition(ball, time, velocity)
	if not isBall(ball) then return nil end
	time = resolveTime(time); local positionAge = time - State.positionAt
	if State.hasRealPosition and positionAge >= 0 and positionAge < T.PREDICTION_HORIZON then
		if not velocity then velocity = getAssemblyVelocity(ball) end
		local direction = State.deflectDirection
		if direction.Magnitude <= 0.1 and velocity.Magnitude > 1 then direction = velocity end
		local predicted
		if direction.Magnitude > 0.1 and State.speed > 0 then predicted = State.realPosition + direction.Unit * State.speed * positionAge
		else predicted = State.realPosition end
		local trust = 1 - positionAge / T.PREDICTION_HORIZON
		if trust >= 1 then return predicted end
		return predicted:Lerp(ball.Position, 1 - trust)
	end
	return ball.Position
end

-- target
local function normalizeTargetId(value)
	if Utils.isFiniteNumber(value) then return value > 0 and value or nil end
	if type(value) == "string" then
		local number = tonumber(value)
		return Utils.isFiniteNumber(number) and number > 0 and number or nil
	end
	return nil
end
local function isTargeted(userId)
	if State.target == userId then return true end
	if State.highlightTarget == userId then return true end
	return normalizeTargetId(Workspace:GetAttribute("GameBallTarget")) == userId
end
local function getSnapshot(_, time)
	time = resolveTime(time)
	if refreshDecodedSync then refreshDecodedSync(time, false) end
	local ball = getBall(); local ballValid = ball ~= nil and ball.Parent ~= nil
	local rawVelocity
	local rawSpeed = 0
	local rawPosition
	if ballValid then rawVelocity = getAssemblyVelocity(ball); rawSpeed = ballSpeed(ball, time, rawVelocity); rawPosition = ballPosition(ball, time, rawVelocity) end
	local validPosition = rawPosition ~= nil; local rawSyncAge = State.lastSyncAt > 0 and math.max(0, time - State.lastSyncAt) or nil
	local syncFresh = rawSyncAge ~= nil and rawSyncAge <= T.SYNC_FRESH_TIME
	local targetId = State.target or State.highlightTarget
	local player = Players.LocalPlayer; local userId = player and player.UserId or -1; local targeted = ballValid and isTargeted(userId)
	local approachingSpeed
	if rawPosition and rawVelocity and player then
		local root = cachedRoot
		if not root or not root.Parent then
			local character = player.Character
			if character then cachedCharacter = character; root = character:FindFirstChild("HumanoidRootPart"); cachedRoot = root end
		end
		if root and root.Parent then
			local playerPosition = root.Position; local direction = playerPosition - rawPosition; local dirMag = direction.Magnitude
			if dirMag > 0 then approachingSpeed = rawVelocity:Dot(direction / dirMag) end
		end
	end
	return {
		schema = T.SNAPSHOT_SCHEMA,
		generatedAt = time,
		valid = ballValid and validPosition,
		ball = ballValid and ball or nil,
		ballValid = ballValid,
		position = ballValid and rawPosition or nil,
		velocity = ballValid and rawVelocity or nil,
		speed = ballValid and rawSpeed or nil,
		maxSpeed = State.maxSpeed,
		acceleration = State.acceleration,
		approachingSpeed = approachingSpeed,
		targetId = targetId,
		highlightTargetId = State.highlightTarget,
		lastTarget = targetId,
		targeted = targeted,
		teleported = State.teleported and (time - State.teleportedAt) < T.TELEPORT_EVENT_TIME,
		syncAt = State.lastSyncAt > 0 and State.lastSyncAt or nil,
		syncAge = rawSyncAge,
		syncFresh = syncFresh,
	}
end

-- sync
local function cloneSyncData(data)
	local copy = {}
	for key, value in pairs(data) do copy[key] = value end
	return copy
end
local function consumerSyncData(data)
	local copy = cloneSyncData(data)
	local target = normalizeTargetId(data.TargetPlayerID)
	local highlightTarget = normalizeTargetId(data.HighlightTargetPlayerID)
	copy.TargetPlayerID = target or highlightTarget or -1
	copy.HighlightTargetPlayerID = highlightTarget or -1
	return copy
end
refreshDecodedSync = function(time, force)
	time = resolveTime(time)
	local data = getDecodedSyncData(time)
	if not data then
		return false, ("BallReplicator.syncData indisponivel: %s%s"):format(
			tostring(ballReplicatorStatus),
			ballReplicatorError and ("; " .. tostring(ballReplicatorError)) or ""
		)
	end
	local changed = State.lastSyncData == nil
	if not changed then
		for key, value in pairs(data) do
			if State.lastSyncData[key] ~= value then changed = true; break end
		end
		if not changed then
			for key, value in pairs(State.lastSyncData) do
				if data[key] ~= value then changed = true; break end
			end
		end
	end
	if not force and not changed then return true, consumerSyncData(data) end

	State.speed = Utils.isFiniteNumber(data.Speed) and math.max(0, data.Speed) or 0
	State.maxSpeed = Utils.isFiniteNumber(data.MaxSpeed) and math.max(0, data.MaxSpeed) or 0
	State.acceleration = Utils.isFiniteNumber(data.Accel) and data.Accel or 0
	State.speedAt = Utils.isFiniteNumber(data.Speed) and data.Speed >= 0 and time or 0
	State.hasRealPosition = typeof(data.RealPosition) == "Vector3"
	State.positionAt = State.hasRealPosition and time or 0
	if State.hasRealPosition then State.realPosition = data.RealPosition end
	State.deflectDirection = typeof(data.DeflectDirection) == "Vector3" and data.DeflectDirection or ZERO_VELOCITY
	State.target = normalizeTargetId(data.TargetPlayerID)
	State.highlightTarget = normalizeTargetId(data.HighlightTargetPlayerID)
	State.teleported = data.Teleported == true
	State.teleportedAt = State.teleported and time or 0
	State.lastSyncAt = time
	State.lastSyncData = cloneSyncData(data)
	return true, consumerSyncData(data)
end
local function applySync(rawPayload)
	local time = Utils.now(); State.syncPayloadType = rawPayload == nil and "nil" or typeof(rawPayload); State.syncEventAt = time
	return refreshDecodedSync(time, true)
end

-- ability
local function locateDeflectAbility()
	if deflectAbility and deflectAbility.Parent ~= nil then return deflectAbility end
	local time = Utils.now()
	if abilityAttempted and time - abilityCheckedAt < T.ABILITY_RETRY_TIME then return nil end
	abilityAttempted = true; abilityCheckedAt = time
	pcall(function()
		local ts = Utils.getReplicatedStorage():FindFirstChild("TS"); local bindableManager = ts and ts:FindFirstChild("BindableManager")
		if not bindableManager then return end
		local ok, manager = pcall(require, bindableManager)
		if not ok or type(manager) ~= "table" or type(manager.GetFunction) ~= "function" then return end
		local getAbility = manager:GetFunction("AbilityManager::GetAbility")
		if not getAbility or type(getAbility.Invoke) ~= "function" then return end
		for _, name in ipairs({ "Deflect", "Block" }) do
			local okAbility, ability = pcall(getAbility.Invoke, getAbility, name)
			if
				okAbility
				and ability
				and type(ability.Cooldown) == "number"
				and type(ability.SetCooldown) == "function"
			then
				deflectAbility = ability; return
			end
		end
	end)
	return deflectAbility
end
local function getDeflectCooldown()
	local ability = locateDeflectAbility()
	if not ability then return 0 end
	local cooldown = ability.Cooldown
	if Utils.isFiniteNumber(cooldown) then return math.max(0, cooldown) end
	return 0
end

-- watcher
local function installBallWatcher(trackConnection)
	if type(trackConnection) ~= "function" then return false end
	local gameFolder = Workspace:FindFirstChild("Game")
	local ballFolder = gameFolder and gameFolder:FindFirstChild("Ball")
	if ballFolder then
		trackConnection(ballFolder.ChildAdded:Connect(function(child)
			if child.Name == "GameBall" and child:IsA("BasePart") then setBall(child, "Workspace.Game.Ball.GameBall") end
		end))
		trackConnection(ballFolder.ChildRemoved:Connect(clearBall))
		local existingBall = ballFolder:FindFirstChild("GameBall")
		if existingBall then setBall(existingBall, "Workspace.Game.Ball.GameBall")
		else setBall(getProviderBall(Utils.now()), "TS.GameInfo.GameInfo.BallModel") end
		return true
	end

	-- Algumas versões expõem a bola apenas por TS.GameInfo.BallModel ou em outra
	-- hierarquia do Workspace. Observe alterações gerais e resolva a fonte atual.
	trackConnection(Workspace.DescendantAdded:Connect(function(child)
		if child.Name == "GameBall" and child:IsA("BasePart") then
			setBall(child, "Workspace descendant named GameBall")
			return
		end
		if getProviderBall(Utils.now()) == child then setBall(child, "TS.GameInfo.GameInfo.BallModel") end
	end))
	trackConnection(Workspace.DescendantRemoving:Connect(clearBall))
	setBall(getBall())
	return true
end

-- setup
function GameInfo.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.Utils.now) ~= "function"
		or type(deps.Utils.apiVersion) ~= "function"
		or type(deps.Utils.isFiniteNumber) ~= "function"
		or type(deps.Utils.getPlayers) ~= "function"
		or type(deps.Utils.getReplicatedStorage) ~= "function"
		or type(deps.Utils.getWorkspace) ~= "function"
	then
		return false, "dependência ausente: Utils"
	end
	Utils = deps.Utils; Players = Utils.getPlayers(); Workspace = Utils.getWorkspace(); resetState()
	return true
end

-- api
function GameInfo.getBall() return getBall() end
function GameInfo.getSnapshot(lastTarget, time) return getSnapshot(lastTarget, time) end
function GameInfo.getSyncData()
	if refreshDecodedSync then refreshDecodedSync(Utils.now(), false) end
	return State.lastSyncData and consumerSyncData(State.lastSyncData) or nil
end
function GameInfo.getStatus()
	local snapshot = getSnapshot(nil, Utils.now())
	local validReason
	if not snapshot.valid then
		validReason = snapshot.ballValid and "ball_position_unavailable" or "ball_not_found_or_not_a_basepart"
	end
	if validReason and validReason ~= lastReportedIssue then
		lastReportedIssue = validReason
		if type(Utils.recordError) == "function" then pcall(Utils.recordError, "GameInfo", validReason .. "; provider=" .. tostring(gameInfoProviderStatus)) end
	elseif not validReason then
		lastReportedIssue = nil
	end
	local ballName, ballClass, ballPath
	local syncReason
	if not snapshot.syncFresh then syncReason = "BallReplicator.syncData ausente ou sem atualização recente" end
	if snapshot.ball then
		pcall(function()
			ballName = snapshot.ball.Name
			ballClass = snapshot.ball.ClassName
			ballPath = snapshot.ball:GetFullName()
		end)
	end
	return {
		schema = Utils.apiVersion(),
		snapshotSchema = T.SNAPSHOT_SCHEMA,
		generatedAt = snapshot.generatedAt,
		valid = snapshot.valid == true,
		validReason = validReason,
		ballValid = snapshot.ballValid == true,
		ballSource = ballSource,
		ballName = ballName,
		ballClass = ballClass,
		ballPath = ballPath,
		providerStatus = gameInfoProviderStatus,
		providerError = gameInfoProviderError,
		syncFresh = snapshot.syncFresh == true,
		syncAge = snapshot.syncAge,
		syncReason = syncReason,
		syncPayloadType = State.syncPayloadType,
		syncEventAt = State.syncEventAt,
		syncProviderStatus = ballReplicatorStatus,
		syncProviderError = ballReplicatorError,
		speed = snapshot.speed,
		maxSpeed = snapshot.maxSpeed,
		acceleration = snapshot.acceleration,
		targetId = snapshot.targetId,
		highlightTargetId = snapshot.highlightTargetId,
		teleported = snapshot.teleported,
		targeted = snapshot.targeted == true,
	}
end
function GameInfo.isSnapshotValid(snapshot, time)
	if
		type(snapshot) ~= "table"
		or snapshot.schema ~= T.SNAPSHOT_SCHEMA
		or snapshot.valid ~= true
		or snapshot.ballValid ~= true
		or not isBall(snapshot.ball)
		or typeof(snapshot.position) ~= "Vector3"
		or not Utils.isFiniteNumber(snapshot.speed)
		or snapshot.speed < 0
	then
		return false
	end
	time = resolveTime(time)
	if not Utils.isFiniteNumber(snapshot.generatedAt) then return false end
	local age = time - snapshot.generatedAt
	return age >= 0 and age <= T.SNAPSHOT_LIFETIME and snapshot.ball ~= nil and snapshot.ball.Parent ~= nil
end
function GameInfo.applySync(data) return applySync(data) end
function GameInfo.installBallWatcher(trackConnection) return installBallWatcher(trackConnection) end
function GameInfo.getDeflectCD() return getDeflectCooldown() end
GameInfo.__contract = {
	requires = { Utils = "utils" },
	ballSync = true,
}

return GameInfo
