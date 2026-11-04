-- [[ gameinfo ]]

local GameInfo = {}

export type BallSnapshot = {
	schema: number,
	generatedAt: number,
	valid: boolean,
	ball: BasePart,
	ballValid: boolean,
	position: Vector3,
	velocity: Vector3,
	speed: number,
	syncSpeed: number?,
	realPosition: Vector3?,
	targetId: number,
	targeted: boolean,
	teleported: boolean,
	grace: boolean,
	oldGrace: boolean,
	syncAt: number,
	syncSequence: number?,
}

export type BallSync = {
	Sequence: number?,
	ServerTime: number?,
	TeleportSequence: number?,
	Teleported: boolean?,
	Grace: boolean?,
	OldGrace: boolean?,
	TargetPlayerID: number?,
	HighlightTargetPlayerID: number?,
	PossessorId: number?,
	RealPosition: Vector3?,
	Speed: number?,
}

-- tuning
local T = {
	SNAPSHOT_SCHEMA = 2,
}

-- state
local Utils
local Players
local Workspace
local cachedBall
local ballWatcherReady = false
local ballSearchComplete = false
local nextBallSearch = 0
local ballReplicatorModule
local gameBallModule
local speedLimitMin, speedLimitMax = 16, 600
local nextSpeedRead = 0
local lastSyncData
local clientAbilitiesModule
local clientAbilities
local sampledBall, sampledPosition, sampledAt, sampledVelocity, movedAt
local lastModuleError = {}

local function reportModuleError(name, message)
	local time = os.clock()
	if lastModuleError[name] and time - lastModuleError[name] < 2 then return end
	lastModuleError[name] = time; local detail = name .. ": " .. tostring(message)
	if Utils and type(Utils.recordError) == "function" then Utils.recordError("GameInfo", detail) else warn("[GameInfo] " .. detail) end
end

-- helpers
local function now() return Utils.now() end
local function findGameBall()
	local ball = Workspace:FindFirstChild("GameBall") or Workspace:FindFirstChild("GameBall", true)
	if typeof(ball) == "Instance" and ball:IsA("BasePart") then return ball end
	return nil
end
local function getBall()
	if cachedBall and cachedBall.Parent then return cachedBall end
	if ballWatcherReady and ballSearchComplete and os.clock() < nextBallSearch then return nil end
	cachedBall = findGameBall(); ballSearchComplete = true; nextBallSearch = os.clock() + 0.5; return cachedBall
end
local function getBallReplicator()
	-- BallReplicator retorna uma tabela; não use Parent para validar o cache.
	if ballReplicatorModule then return ballReplicatorModule end
	ballReplicatorModule = nil; local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then return nil end
	local ts = replicatedStorage:FindFirstChild("TS")
	if not ts then return nil end
	local folder = ts:FindFirstChild("BallReplicator")
	if not folder then return nil end
	local candidate = folder:IsA("ModuleScript") and folder or folder:FindFirstChild("BallReplicator")
	if not candidate or not candidate:IsA("ModuleScript") then return nil end
	local ok, result = pcall(require, candidate)
	if not ok or type(result) ~= "table" then reportModuleError("BallReplicator", ok and "módulo não retornou tabela" or result); return nil end
	if type(result.BallReplicator) == "table" then
		ballReplicatorModule = result.BallReplicator
	elseif result.syncData ~= nil then
		ballReplicatorModule = result
	else
		return nil
	end
	return ballReplicatorModule
end
local function getDecodedSyncData()
	local provider = getBallReplicator(); local data = provider and provider.hasState == true and provider.syncData or lastSyncData
	if type(data) ~= "table" then data = provider and provider.syncData or nil end
	if type(data) ~= "table" then return nil end
	return data
end
local function normalizeTargetId(value)
	if typeof(value) == "Instance" and value:IsA("Player") then return tonumber(value.UserId) end
	if type(value) == "number" and value > 0 then return value end
	if type(value) == "string" then
		local n = tonumber(value)
		if n and n > 0 then return n end
	end
	return nil
end
local function resolveTargetId(data)
	local syncTarget = type(data) == "table" and (normalizeTargetId(data.TargetPlayerID) or normalizeTargetId(data.HighlightTargetPlayerID))
	if syncTarget then return syncTarget end
	if type(data) == "table" and data.Targeted == true and Players and Players.LocalPlayer then return Players.LocalPlayer.UserId end
	local attributeOk, attributeValue = pcall(function() return Workspace:GetAttribute("GameBallTarget") end)
	if attributeOk and attributeValue ~= nil then
		local attributeTarget = normalizeTargetId(attributeValue)
		if attributeTarget then return attributeTarget end
	end
	return -1
end
local function locateDeflectAbility()
	if clientAbilitiesModule and clientAbilitiesModule.Parent and clientAbilities then
		local ability = clientAbilities.Abilities[1]
		if type(ability) == "table" and type(ability.Deflect) == "function" then return ability end
		return nil
	end
	local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then return nil end
	local ts = replicatedStorage:FindFirstChild("TS")
	if not ts then return nil end
	local clientModule = ts:FindFirstChild("ClientAbilities")
	if not clientModule or not clientModule:IsA("ModuleScript") then return nil end
	if clientAbilitiesModule ~= clientModule then
		local ok, client = pcall(require, clientModule)
		if not ok or type(client) ~= "table" or type(client.Abilities) ~= "table" then
			reportModuleError("ClientAbilities", ok and "Abilities ausente ou inválido" or client); clientAbilitiesModule, clientAbilities = nil, nil; return nil
		end
		clientAbilitiesModule, clientAbilities = clientModule, client
	end
	local ability = clientAbilities.Abilities[1]
	if type(ability) == "table" and type(ability.Deflect) == "function" then return ability end
	return nil
end
local function getDeflectCooldown()
	local ability = locateDeflectAbility()
	if not ability then return nil end
	local cooldown = ability.Cooldown
	if type(cooldown) == "number" and cooldown == cooldown and cooldown < math.huge then return cooldown end
	return nil
end
local function getSnapshot(_, time, frameTime): BallSnapshot?
	time = type(time) == "number" and time or now(); local ball = getBall()
	if not ball then return nil end
	local position = ball.Position; local velocity = ball.AssemblyLinearVelocity; local syncData = getDecodedSyncData()
	if sampledBall ~= ball or (syncData and syncData.Teleported == true) then
		sampledBall, sampledPosition, sampledAt = ball, position, time; sampledVelocity, movedAt = Vector3.zero, nil
	elseif sampledPosition and sampledAt and time - sampledAt >= 1 / 240 then
		local elapsed = time - sampledAt; local displacement = position - sampledPosition
		if displacement.Magnitude > 0.001 then
			local measured = displacement / elapsed; local expected = syncData and tonumber(syncData.Speed)
			if elapsed <= 0.25 and (not expected or expected <= 0 or measured.Magnitude <= expected * 2.5 + 30) then sampledVelocity, movedAt = measured, time
			else sampledVelocity, movedAt = Vector3.zero, nil end
		elseif movedAt and time - movedAt > 0.10 then
			sampledVelocity = Vector3.zero
		end
		sampledPosition, sampledAt = position, time
	end
	if typeof(velocity) ~= "Vector3" or velocity.Magnitude < 0.1 then velocity = sampledVelocity or Vector3.zero end
	local speed = 0
	if typeof(velocity) == "Vector3" then speed = velocity.Magnitude end
	local targetId = resolveTargetId(syncData); local localPlayer = Players and Players.LocalPlayer; local teleported, grace, oldGrace = false, false, false; local provider = getBallReplicator()
	if syncData then teleported = syncData.Teleported == true; grace = syncData.Grace == true; oldGrace = syncData.OldGrace == true end
	return {
		schema = T.SNAPSHOT_SCHEMA,
		generatedAt = time,
		valid = true,
		ball = ball,
		ballValid = true,
		position = position,
		velocity = velocity,
		speed = speed,
		syncSpeed = syncData and syncData.Speed or nil,
		realPosition = syncData and syncData.RealPosition or nil,
		targetId = targetId,
		targeted = localPlayer ~= nil and targetId == localPlayer.UserId,
		teleported = teleported,
		grace = grace,
		oldGrace = oldGrace,
		syncAt = time,
		syncSequence = provider and provider.hasState == true and provider.lastSeq or nil,
	}
end
local function installBallWatcher(trackConnection)
	if type(trackConnection) ~= "function" then return false, "trackConnection invalido" end
	trackConnection((Workspace.DescendantAdded or Workspace.ChildAdded):Connect(function(child)
		if child.Name == "GameBall" and child:IsA("BasePart") then cachedBall = child end
	end))
	trackConnection((Workspace.DescendantRemoving or Workspace.ChildRemoved):Connect(function(child)
		if cachedBall == child then cachedBall = nil; ballSearchComplete = false end
	end))
	cachedBall = findGameBall(); ballSearchComplete = true; ballWatcherReady = true; nextBallSearch = os.clock() + 0.5
	return true
end
function GameInfo.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.Utils.now) ~= "function"
		or type(deps.Utils.apiVersion) ~= "function"
		or type(deps.Utils.getPlayers) ~= "function"
		or type(deps.Utils.getReplicatedStorage) ~= "function"
		or type(deps.Utils.getWorkspace) ~= "function"
	then
		return false, "dependência ausente: Utils"
	end
	Utils = deps.Utils; Players = Utils.getPlayers(); Workspace = Utils.getWorkspace()
	if not Players then return false, "dependência ausente: Players" end
	if not Workspace then return false, "dependência ausente: Workspace" end
	cachedBall = nil; ballWatcherReady = false; ballSearchComplete = false; nextBallSearch = 0
	nextSpeedRead = 0; ballReplicatorModule = nil; gameBallModule = nil; lastSyncData = nil
	clientAbilitiesModule = nil; clientAbilities = nil; sampledBall, sampledPosition, sampledAt, sampledVelocity, movedAt = nil, nil, nil, nil, nil; return true
end
function GameInfo.getBall() return getBall() end
function GameInfo.getBallPosition(ball) return ball.Position end
function GameInfo.getBallVelocity(ball) return ball.AssemblyLinearVelocity end
function GameInfo.getRootPosition(root) return root.Position end
function GameInfo.getLocalPing()
	local player = Players and Players.LocalPlayer; return player and player:GetNetworkPing() or nil
end
function GameInfo.getDeflectRange()
	local player = Players and Players.LocalPlayer; return player and player:GetAttribute("DeflectRange") or nil
end
function GameInfo.getDeflectAbility() return locateDeflectAbility() end
function GameInfo.getDashAbility()
	locateDeflectAbility()
	local ability = clientAbilities and clientAbilities.Abilities[2]
	if type(ability) == "table" and type(ability.Dash) == "function" then return ability end
	return nil
end
function GameInfo.getDarkSealAbility()
	locateDeflectAbility()
	local ability = clientAbilities and clientAbilities.Abilities[20]
	if type(ability) == "table" and type(ability.SendEvent) == "function" then return ability end
	return nil
end
function GameInfo.getSnapshot(lastTarget, time, frameTime): BallSnapshot? return getSnapshot(lastTarget, time, frameTime) end
function GameInfo.getSnapshotAt(time: number?): BallSnapshot? return getSnapshot(nil, time) end
function GameInfo.getSyncData() return getDecodedSyncData() end
function GameInfo.getSyncSequence()
	local provider = getBallReplicator(); return provider and provider.hasState == true and provider.lastSeq or nil
end
function GameInfo.decodeBallPacket(packet): BallSync?
	local provider = getBallReplicator()
	if not provider or type(provider.Decode) ~= "function" then return nil end
	local decoded = provider:Decode(packet)
	if type(decoded) ~= "table" then return nil end
	return {
		Sequence = decoded.seq,
		ServerTime = decoded.serverTime,
		TeleportSequence = decoded.seq,
		Teleported = decoded.teleported,
		Grace = decoded.grace,
		OldGrace = decoded.oldGrace,
		TargetPlayerID = decoded.targetId,
		HighlightTargetPlayerID = decoded.highlightId,
		PossessorId = decoded.possessed and decoded.possessorId or 0,
		RealPosition = decoded.position,
		Speed = decoded.speed,
	}
end
function GameInfo.getTargetId() return resolveTargetId(getDecodedSyncData()) end
function GameInfo.getBallSpeedLimits()
	local time = os.clock()
	if time < nextSpeedRead then return speedLimitMin, speedLimitMax end
	nextSpeedRead = time + 0.5
	if not gameBallModule then
		local storage = Utils and Utils.getReplicatedStorage(); local ts = storage and storage:FindFirstChild("TS"); local gameplay = ts and ts:FindFirstChild("Gameplay")
		local module = gameplay and gameplay:FindFirstChild("GameBall")
		if not module or not module:IsA("ModuleScript") then reportModuleError("GameBall", "módulo de velocidade indisponível; usando últimos limites conhecidos"); return speedLimitMin, speedLimitMax end
		local ok, result = pcall(require, module)
		if not ok then reportModuleError("GameBall", result); return speedLimitMin, speedLimitMax end
		gameBallModule = type(result) == "table" and result.GameBall or nil
	end
	local ball = gameBallModule
	if type(ball) ~= "table" or type(ball.GetBaseSpeed) ~= "function" or type(ball.GetMaxSpeed) ~= "function" then
		reportModuleError("GameBall", "API de velocidade indisponível"); gameBallModule = nil; return speedLimitMin, speedLimitMax
	end
	local ok, minimum, maximum = pcall(function() return ball:GetBaseSpeed(), ball:GetMaxSpeed() end)
	if
		not ok
		or type(minimum) ~= "number"
		or type(maximum) ~= "number"
		or minimum ~= minimum
		or maximum ~= maximum
		or minimum <= 0
		or maximum <= minimum
		or maximum == math.huge
	then
		reportModuleError("GameBall", ok and "limites de velocidade inválidos" or minimum); return speedLimitMin, speedLimitMax
	end
	speedLimitMin, speedLimitMax = minimum, maximum; return minimum, maximum
end
function GameInfo.getHaunterRemote()
	local storage = Utils and Utils.getReplicatedStorage(); local ts = storage and storage:FindFirstChild("TS"); local remotes = ts and ts:FindFirstChild("GeneratedNetworkRemotes")
	local remote = remotes and remotes:FindFirstChild("RE_" .. tostring(9.150098456648103e76))
	if remote and remote:IsA("RemoteEvent") then return remote end
	return nil
end
function GameInfo.getManifestRemote()
	local storage = Utils and Utils.getReplicatedStorage(); local ts = storage and storage:FindFirstChild("TS"); local remotes = ts and ts:FindFirstChild("GeneratedNetworkRemotes")
	local remote = remotes and remotes:FindFirstChild("RE_" .. tostring(9.318024238496386e76))
	if remote and remote:IsA("RemoteEvent") then return remote end
	return nil
end
function GameInfo.getClashContext()
	local player = Players and Players.LocalPlayer
	if not player or not Workspace then return nil end
	local lastAt = Workspace:GetAttribute("LastParryAt"); local by = Workspace:GetAttribute("LastParryBy"); local target = Workspace:GetAttribute("LastParryTarget")
	if type(lastAt) ~= "number" or type(by) ~= "number" or type(target) ~= "number" then return nil end
	local partnerId = by == player.UserId and target or (target == player.UserId and by or nil)
	if not partnerId or partnerId <= 0 or partnerId == player.UserId then return nil end
	local age = Workspace:GetServerTimeNow() - lastAt; local currentTarget = Workspace:GetAttribute("GameBallTarget")
	if age < 0 or (age > 1 and (age > 2.5 or currentTarget ~= target)) then return nil end
	local partner = Players:GetPlayerByUserId(partnerId); local ownRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local partnerRoot = partner and partner.Character and partner.Character:FindFirstChild("HumanoidRootPart")
	if not ownRoot or not partnerRoot or (ownRoot.Position - partnerRoot.Position).Magnitude > 35 then return nil end
	return { partnerId = partnerId, lastParryAt = lastAt, age = age }
end
function GameInfo.isSnapshotValid(snapshot)
	return type(snapshot) == "table"
		and typeof(snapshot.ball) == "Instance"
		and snapshot.ball:IsA("BasePart")
		and typeof(snapshot.position) == "Vector3"
		and typeof(snapshot.velocity) == "Vector3"
		and type(snapshot.speed) == "number"
		and snapshot.speed == snapshot.speed
		and snapshot.speed >= 0
		and snapshot.speed < math.huge
		and type(snapshot.targetId) == "number"
		and type(snapshot.targeted) == "boolean"
end
function GameInfo.applySync(data)
	if type(data) == "table" and type(data.syncData) == "table" then data = data.syncData end
	if type(data) ~= "table" then local provider = getBallReplicator(); data = provider and provider.syncData or nil end
	if type(data) ~= "table" then return nil end
	lastSyncData = data; return data
end
function GameInfo.installBallWatcher(trackConnection) return installBallWatcher(trackConnection) end
function GameInfo.getDeflectCD() return getDeflectCooldown() end
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
GameInfo.__contract = {
	requiresMethods = { Utils = { "now", "apiVersion", "getPlayers", "getReplicatedStorage", "getWorkspace" } },
	provides = {
		"setup",
		"getBall",
		"getBallPosition",
		"getBallVelocity",
		"getRootPosition",
		"getLocalPing",
		"getDeflectRange",
		"getDeflectAbility",
		"getDashAbility",
		"getDarkSealAbility",
		"getBallSpeedLimits",
		"getDeflectCD",
		"getSnapshot",
		"getSnapshotAt",
		"isSnapshotValid",
		"getSyncData",
		"getSyncSequence",
		"decodeBallPacket",
		"getTargetId",
		"applySync",
		"installBallWatcher",
	},
	requires = {
		Utils = "utils",
	},
}

return GameInfo
