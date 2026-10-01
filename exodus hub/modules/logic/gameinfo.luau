-- [[ gameinfo ]]

local GameInfo = {}
local Utils
local Players
local Workspace

-- tuning
local T = {
	BALL_CACHE_TTL = 0.05,
	SYNC_FRESH_TIME = 0.05,
	PREDICTION_HORIZON = 0.6,
	TELEPORT_EVENT_TIME = 0.5,
	SNAPSHOT_LIFETIME = 0.05,
	ACQUIRE_RETRY_TIME = 0.02,
	PROVIDER_RECHECK_TIME = 0.05,
	ABILITY_RETRY_TIME = 0.05,
	SNAPSHOT_CACHE_WINDOW = 0.002,
	SNAPSHOT_SCHEMA = 2,
}

local ZERO_VECTOR = Vector3.zero
local State = {
	ball = nil,
	ballAt = 0,
	speed = 0,
	speedAt = 0,
	maxSpeed = 0,
	acceleration = 0,
	realPosition = ZERO_VECTOR,
	hasRealPosition = false,
	positionAt = 0,
	target = nil,
	lastSyncAt = 0,
	lastSyncData = nil,
	syncPayloadType = "none",
	syncEventAt = 0,
	deflectDirection = ZERO_VECTOR,
	teleported = false,
	teleportedAt = 0,
	grace = false,
	oldGrace = false,
	resetAt = 0,
	snapshotCache = nil,
	snapshotCacheAt = 0,
}

local gameInfoModule
local gameInfoProvider
local gameInfoCheckedAt = 0
local gameInfoProviderStatus = "not_checked"
local gameInfoProviderError
local ballReplicatorModule
local ballReplicatorProvider
local ballReplicatorCheckedAt = 0
local ballReplicatorAttempted = false
local ballReplicatorStatus = "not_checked"
local ballReplicatorError
local deflectAbility
local abilityAttempted = false
local abilityCheckedAt = 0
local refreshDecodedSync
local ballSource = "none"
local lastReportedIssue
local cachedCharacter
local cachedRoot
local function now() return Utils.now() end
local function isFiniteNumber(value) return Utils.isFiniteNumber(value) end
local function isNonNegativeFiniteNumber(value) return Utils.isNonNegativeFiniteNumber(value) end
local function resolveTime(time)
	if isFiniteNumber(time) then return time end
	return now()
end
local function isBall(instance)
	return typeof(instance) == "Instance" and instance.Parent ~= nil and instance:IsA("BasePart")
end
local function clearSyncState()
	State.speed = 0; State.speedAt = 0; State.maxSpeed = 0; State.acceleration = 0
	State.realPosition = ZERO_VECTOR; State.hasRealPosition = false; State.positionAt = 0; State.target = nil
	State.lastSyncAt = 0; State.lastSyncData = nil; State.syncPayloadType = "none"; State.syncEventAt = 0
	State.deflectDirection = ZERO_VECTOR; State.teleported = false; State.teleportedAt = 0; State.grace = false
	State.oldGrace = false; State.resetAt = 0; State.snapshotCache = nil; State.snapshotCacheAt = 0
end
local function resetState()
	State.ball = nil; State.ballAt = 0; clearSyncState(); cachedCharacter = nil
	cachedRoot = nil; gameInfoModule = nil; gameInfoProvider = nil; gameInfoCheckedAt = 0
	gameInfoProviderStatus = "not_checked"; gameInfoProviderError = nil; ballReplicatorModule = nil; ballReplicatorProvider = nil
	ballReplicatorCheckedAt = 0; ballReplicatorAttempted = false; ballReplicatorStatus = "not_checked"; ballReplicatorError = nil
	deflectAbility = nil; abilityAttempted = false; abilityCheckedAt = 0; ballSource = "none"
	lastReportedIssue = nil
end
local function resolveGameInfoProvider(time)
	time = resolveTime(time)
	if gameInfoProvider and gameInfoModule and gameInfoModule.Parent ~= nil then
		if time - gameInfoCheckedAt < T.PROVIDER_RECHECK_TIME then return gameInfoProvider end
		gameInfoCheckedAt = time; return gameInfoProvider
	end
	if gameInfoCheckedAt > 0 and time - gameInfoCheckedAt < T.ACQUIRE_RETRY_TIME then return nil end
	gameInfoCheckedAt = time; gameInfoModule = nil; gameInfoProvider = nil; gameInfoProviderError = nil
	local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then gameInfoProviderStatus = "replicated_storage_missing"; return nil end
	local ts = replicatedStorage:FindFirstChild("TS")
	if not ts then gameInfoProviderStatus = "ts_folder_missing"; return nil end
	local candidate = ts:FindFirstChild("GameInfo")
	if candidate and not candidate:IsA("ModuleScript") then candidate = candidate:FindFirstChild("GameInfo") end
	if not candidate then gameInfoProviderStatus = "gameinfo_module_missing"; return nil end
	if not candidate:IsA("ModuleScript") then gameInfoProviderStatus = "gameinfo_instance_not_module"; return nil end
	local ok, result = pcall(require, candidate)
	if not ok then gameInfoProviderStatus = "require_failed"; gameInfoProviderError = tostring(result); return nil end
	if type(result) ~= "table" then gameInfoProviderStatus = "require_returned_non_table"; return nil end
	gameInfoModule = candidate
	if type(result.GameInfo) == "table" then gameInfoProvider = result.GameInfo
	elseif result.BallModel ~= nil then gameInfoProvider = result end
	if gameInfoProvider then gameInfoProviderStatus = "provider_ready"
	else gameInfoProviderStatus = "provider_table_missing" end
	return gameInfoProvider
end
local function getProviderBall(time)
	local provider = resolveGameInfoProvider(time)
	if not provider then return nil end
	local ball = provider.BallModel
	if isBall(ball) then gameInfoProviderStatus = "ballmodel_found"; return ball end
	if ball == nil then gameInfoProviderStatus = "ballmodel_missing"
	else gameInfoProviderStatus = "ballmodel_not_basepart" end
	return nil
end
local function resolveBallReplicator(time)
	time = resolveTime(time)
	if ballReplicatorProvider and ballReplicatorModule and ballReplicatorModule.Parent ~= nil then
		if time - ballReplicatorCheckedAt < T.PROVIDER_RECHECK_TIME then return ballReplicatorProvider end
		ballReplicatorCheckedAt = time; return ballReplicatorProvider
	end
	if ballReplicatorAttempted and time - ballReplicatorCheckedAt < T.ACQUIRE_RETRY_TIME then return nil end
	ballReplicatorAttempted = true; ballReplicatorCheckedAt = time; ballReplicatorModule = nil; ballReplicatorProvider = nil
	ballReplicatorError = nil; local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then ballReplicatorStatus = "replicated_storage_missing"; return nil end
	local ts = replicatedStorage:FindFirstChild("TS")
	if not ts then ballReplicatorStatus = "ts_folder_missing"; return nil end
	local folder = ts:FindFirstChild("BallReplicator")
	if not folder then ballReplicatorStatus = "ballreplicator_folder_missing"; return nil end
	local candidate = folder:IsA("ModuleScript") and folder or folder:FindFirstChild("BallReplicator")
	if not candidate then ballReplicatorStatus = "ballreplicator_module_missing"; return nil end
	if not candidate:IsA("ModuleScript") then ballReplicatorStatus = "ballreplicator_instance_not_module"; return nil end
	local ok, result = pcall(require, candidate)
	if not ok then ballReplicatorStatus = "require_failed"; ballReplicatorError = tostring(result); return nil end
	if type(result) ~= "table" then ballReplicatorStatus = "require_returned_non_table"; return nil end
	ballReplicatorModule = candidate
	if type(result.BallReplicator) == "table" then
		ballReplicatorProvider = result.BallReplicator
	elseif result.syncData ~= nil then
		ballReplicatorProvider = result
	end
	if ballReplicatorProvider then ballReplicatorStatus = "provider_ready"
	else ballReplicatorStatus = "provider_table_missing" end
	return ballReplicatorProvider
end
local function getDecodedSyncData(time)
	local provider = resolveBallReplicator(time)
	if not provider then return nil end
	local data = provider.syncData
	if type(data) ~= "table" then ballReplicatorStatus = "syncdata_not_table"; return nil end
	ballReplicatorStatus = "syncdata_ready"; return data
end
local function setBall(ball, source)
	if not isBall(ball) then return false end
	if State.ball ~= ball then clearSyncState() end
	State.ball = ball; State.ballAt = now()
	if source then ballSource = source end
	return true
end
local function clearBall(ball)
	if ball == nil or State.ball == ball then State.ball = nil; State.ballAt = now(); ballSource = "none"; clearSyncState() end
end
local function getBall()
	local time = now(); local cached = State.ball
	if not cached and State.ballAt > 0 and time - State.ballAt < T.BALL_CACHE_TTL then return nil end
	local providerBall = getProviderBall(time)
	if providerBall and providerBall ~= cached then setBall(providerBall, "TS.GameInfo.GameInfo.BallModel"); return providerBall end
	if cached and cached.Parent ~= nil then return cached end
	local ball = providerBall
	local source
	if ball then source = "TS.GameInfo.GameInfo.BallModel" end
	if not ball then
		local direct = Workspace:FindFirstChild("GameBall")
		if isBall(direct) then ball = direct; source = "Workspace.GameBall" end
	end
	if not ball then
		local descendant = Workspace:FindFirstChild("GameBall", true)
		if isBall(descendant) then ball = descendant; source = "Workspace descendant named GameBall" end
	end
	if isBall(ball) then setBall(ball, source); return ball end
	State.ball = nil; State.ballAt = time; ballSource = "none"; return nil
end
local function getAssemblyVelocity(ball)
	if not isBall(ball) then return ZERO_VECTOR end
	local velocity = ball.AssemblyLinearVelocity
	if typeof(velocity) == "Vector3" then return velocity end
	return ZERO_VECTOR
end
local function ballSpeed(ball, time, velocity)
	if not isBall(ball) then return 0 end
	if State.speedAt > 0 and time >= State.speedAt and time - State.speedAt < T.PREDICTION_HORIZON then return State.speed end
	return (velocity or getAssemblyVelocity(ball)).Magnitude
end
local function ballPosition(ball, time, velocity)
	if not isBall(ball) then return nil end
	local positionAge = time - State.positionAt
	if State.hasRealPosition and positionAge >= 0 and positionAge < T.PREDICTION_HORIZON then
		local direction = State.deflectDirection
		if direction.Magnitude <= 0.1 then
			velocity = velocity or getAssemblyVelocity(ball)
			if velocity.Magnitude > 1 then direction = velocity end
		end
		local predicted
		if direction.Magnitude > 0.1 and State.speed > 0 then predicted = State.realPosition + direction.Unit * State.speed * positionAge
		else predicted = State.realPosition end
		local trust = 1 - positionAge / T.PREDICTION_HORIZON
		if trust >= 1 then return predicted end
		if trust <= 0 then return ball.Position end
		return predicted:Lerp(ball.Position, 1 - trust)
	end
	return ball.Position
end
local function normalizeTargetId(value)
	if typeof(value) == "Instance" and value:IsA("Player") then return tonumber(value.UserId) end
	if isFiniteNumber(value) then return value > 0 and value or nil end
	if type(value) == "string" then
		local number = tonumber(value)
		if isFiniteNumber(number) and number > 0 then return number end
	end
	return nil
end
local function resolveTargetId(data)
	if type(data) ~= "table" then data = State.lastSyncData or {} end
	local attribute
	local ok, value = pcall(function() return Workspace:GetAttribute("GameBallTarget") end)
	if ok then attribute = value end
	if attribute ~= nil then local normalizedAttribute = normalizeTargetId(attribute); return normalizedAttribute or -1 end
	local highlighted = normalizeTargetId(data.HighlightTargetPlayerID)
	if highlighted then return highlighted end
	return normalizeTargetId(data.TargetPlayerID) or -1
end
local function isLocalTarget(data)
	local localPlayer = Players and Players.LocalPlayer; local localUserId = localPlayer and tonumber(localPlayer.UserId)
	if not localUserId then return false end
	local attribute
	local attributeOk, attributeValue = pcall(function() return Workspace:GetAttribute("GameBallTarget") end)
	if attributeOk and attributeValue ~= nil then return normalizeTargetId(attributeValue) == localUserId end
	data = type(data) == "table" and data or {}
	if data.HighlightTargetPlayerID ~= nil then return normalizeTargetId(data.HighlightTargetPlayerID) == localUserId end
	return normalizeTargetId(data.TargetPlayerID) == localUserId
end
local function updateSyncState(data, time, force)
	if type(data) ~= "table" then return false end
	local speed = isNonNegativeFiniteNumber(data.Speed) and data.Speed or 0; local maxSpeed = isNonNegativeFiniteNumber(data.MaxSpeed) and data.MaxSpeed or 0
	local acceleration = isNonNegativeFiniteNumber(data.Accel) and data.Accel or 0; local hasRealPosition = typeof(data.RealPosition) == "Vector3"
	local realPosition = hasRealPosition and data.RealPosition or ZERO_VECTOR; local deflectDirection = typeof(data.DeflectDirection) == "Vector3" and data.DeflectDirection or ZERO_VECTOR
	local target = resolveTargetId(data); local teleported = data.Teleported == true; local grace = data.Grace == true; local oldGrace = data.OldGrace == true
	local changed = force
		or State.lastSyncData == nil
		or State.speed ~= speed
		or State.maxSpeed ~= maxSpeed
		or State.acceleration ~= acceleration
		or State.hasRealPosition ~= hasRealPosition
		or State.realPosition ~= realPosition
		or State.deflectDirection ~= deflectDirection
		or State.target ~= target
		or State.teleported ~= teleported
		or State.grace ~= grace
		or State.oldGrace ~= oldGrace
	if not changed then return false end
	State.speed = speed; State.maxSpeed = maxSpeed; State.acceleration = acceleration; State.speedAt = time
	State.hasRealPosition = hasRealPosition; State.realPosition = realPosition; State.positionAt = time; State.deflectDirection = deflectDirection
	State.target = target; State.teleported = teleported
	if teleported then State.teleportedAt = time end
	State.grace = grace; State.oldGrace = oldGrace; State.snapshotCache = nil; State.snapshotCacheAt = 0
	if grace or oldGrace or teleported then State.resetAt = time end
	State.lastSyncAt = time; State.lastSyncData = data; return true
end
local function consumerSyncData(data)
	if type(data) ~= "table" then return nil end
	local copy = {}
	for key, value in pairs(data) do
		copy[key] = value
	end
	copy.TargetPlayerID = resolveTargetId(data); copy.Targeted = isLocalTarget(data); return copy
end
refreshDecodedSync = function(time, force)
	time = resolveTime(time); local data = getDecodedSyncData(time)
	if not data then
		return false,
			("BallReplicator.syncData indisponivel: %s%s"):format(
				tostring(ballReplicatorStatus),
				ballReplicatorError and ("; " .. tostring(ballReplicatorError)) or ""
			)
	end
	local changed = updateSyncState(data, time, force)
	if not changed then State.target = resolveTargetId(data) end
	return true, consumerSyncData(data)
end
local function applySync(rawPayload)
	local time = now(); State.syncPayloadType = rawPayload == nil and "nil" or typeof(rawPayload); State.syncEventAt = time
	if type(rawPayload) == "table" then
		local hasSyncFields = rawPayload.Speed ~= nil
			or rawPayload.MaxSpeed ~= nil
			or rawPayload.RealPosition ~= nil
			or rawPayload.DeflectDirection ~= nil
			or rawPayload.TargetPlayerID ~= nil
		if hasSyncFields and updateSyncState(rawPayload, time, true) then return true, consumerSyncData(rawPayload) end
	end
	return refreshDecodedSync(time, true)
end
local function getLocalRoot()
	local player = Players and Players.LocalPlayer
	if not player then return nil end
	local character = player.Character
	if character ~= cachedCharacter then cachedCharacter = character; cachedRoot = nil end
	if cachedRoot and cachedRoot.Parent ~= nil then return cachedRoot end
	if character then cachedRoot = character:FindFirstChild("HumanoidRootPart") end
	return cachedRoot
end
local function getSnapshot(_, time)
	time = resolveTime(time); local syncOk = refreshDecodedSync(time, false)
	if syncOk ~= true then return nil end
	local syncData = State.lastSyncData
	if type(syncData) ~= "table" then return nil end
	local ball = State.ball
	if not isBall(ball) then return nil end
	local position = ball.Position; local velocity = ball.AssemblyLinearVelocity; local speed = State.speed
	if speed <= 0 then speed = velocity.Magnitude end
	return {
		schema = T.SNAPSHOT_SCHEMA,
		generatedAt = time,
		valid = true,
		ball = ball,
		ballValid = true,
		position = position,
		velocity = velocity,
		speed = speed,
		maxSpeed = State.maxSpeed,
		acceleration = State.acceleration,
		approachingSpeed = nil,
		targetId = resolveTargetId(syncData),
		targeted = isLocalTarget(syncData),
		lastTarget = State.target,
		teleported = syncData.Teleported == true,
		grace = syncData.Grace == true,
		oldGrace = syncData.OldGrace == true,
		resetting = false,
		syncAt = State.lastSyncAt,
		syncAge = nil,
		syncFresh = true,
	}

end
local function locateDeflectAbility()
	if deflectAbility and deflectAbility.Parent ~= nil then return deflectAbility end
	local time = now()
	if abilityAttempted and time - abilityCheckedAt < T.ABILITY_RETRY_TIME then return nil end
	abilityAttempted = true; abilityCheckedAt = time; local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then return nil end
	local ts = replicatedStorage:FindFirstChild("TS"); local bindableManager = ts and ts:FindFirstChild("BindableManager")
	if not bindableManager or not bindableManager:IsA("ModuleScript") then return nil end
	local ok, manager = pcall(require, bindableManager)
	if not ok or type(manager) ~= "table" or type(manager.GetFunction) ~= "function" then return nil end
	local okFunction, getAbility = pcall(manager.GetFunction, manager, "AbilityManager::GetAbility")
	if not okFunction or not getAbility or type(getAbility.Invoke) ~= "function" then return nil end
	for _, name in ipairs({
		"Deflect",
		"Block",
	}) do
		local okAbility, ability = pcall(getAbility.Invoke, getAbility, name)
		if
			okAbility
			and type(ability) == "table"
			and isNonNegativeFiniteNumber(ability.Cooldown)
			and type(ability.SetCooldown) == "function"
		then
			deflectAbility = ability; return ability
		end
	end
	return nil
end
local function getDeflectCooldown()
	local ability = locateDeflectAbility()
	if not ability then return 0 end
	local cooldown = ability.Cooldown
	if isNonNegativeFiniteNumber(cooldown) then return cooldown end
	return 0
end
local function installBallWatcher(trackConnection)
	if type(trackConnection) ~= "function" then return false, "trackConnection invalido" end
	local gameFolder = Workspace:FindFirstChild("Game"); local ballFolder = gameFolder and gameFolder:FindFirstChild("Ball")
	if ballFolder then
		trackConnection(ballFolder.ChildAdded:Connect(function(child)
			if child.Name == "GameBall" and isBall(child) then setBall(child, "Workspace.Game.Ball.GameBall") end
		end))
		trackConnection(ballFolder.ChildRemoved:Connect(function(child) clearBall(child) end))
		local existingBall = ballFolder:FindFirstChild("GameBall")
		if isBall(existingBall) then
			setBall(existingBall, "Workspace.Game.Ball.GameBall")
		else
			local providerBall = getProviderBall(now())
			if providerBall then setBall(providerBall, "TS.GameInfo.GameInfo.BallModel") end
		end
		return true
	end
	trackConnection(Workspace.DescendantAdded:Connect(function(child)
		if child.Name == "GameBall" and isBall(child) then setBall(child, "Workspace descendant named GameBall") end
	end))
	trackConnection(Workspace.DescendantRemoving:Connect(function(child) clearBall(child) end))
	local ball = getBall()
	if ball then setBall(ball, ballSource) end
	return true
end
function GameInfo.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.Utils.now) ~= "function"
		or type(deps.Utils.apiVersion) ~= "function"
		or type(deps.Utils.isFiniteNumber) ~= "function"
		or type(deps.Utils.isNonNegativeFiniteNumber) ~= "function"
		or type(deps.Utils.getPlayers) ~= "function"
		or type(deps.Utils.getReplicatedStorage) ~= "function"
		or type(deps.Utils.getWorkspace) ~= "function"
	then
		return false, "dependência ausente: Utils"
	end
	Utils = deps.Utils; Players = Utils.getPlayers(); Workspace = Utils.getWorkspace()
	if not Players then return false, "dependência ausente: Players" end
	if not Workspace then return false, "dependência ausente: Workspace" end
	resetState(); return true
end
function GameInfo.getBall() return getBall() end
function GameInfo.getSnapshot(lastTarget, time) return getSnapshot(lastTarget, time) end
function GameInfo.getSyncData()
	if refreshDecodedSync then
		local syncOk = refreshDecodedSync(now(), false)
		if syncOk ~= true then return nil end
	end
	if not State.lastSyncData then return nil end
	return consumerSyncData(State.lastSyncData)
end
function GameInfo.getTargetId()
	if refreshDecodedSync then
		local syncOk = refreshDecodedSync(now(), false)
		if syncOk ~= true then return -1 end
	end
	return resolveTargetId(State.lastSyncData)
end
function GameInfo.getStatus()
	local snapshot = getSnapshot(nil, now())
	return {
		schema = Utils.apiVersion(),
		generatedAt = now(),
		available = type(snapshot) == "table",
		targetId = snapshot and snapshot.targetId or -1,
		targeted = snapshot and snapshot.targeted == true or false,
		speed = snapshot and snapshot.speed or 0,
	}
end
function GameInfo.isSnapshotValid(snapshot, time) return type(snapshot) == "table" end
function GameInfo.applySync(data) return applySync(data) end
function GameInfo.installBallWatcher(trackConnection) return installBallWatcher(trackConnection) end
function GameInfo.getDeflectCD() return getDeflectCooldown() end
GameInfo.__contract = {
	requires = {
		Utils = "utils",
	},

	ballSync = true,
}

return GameInfo
