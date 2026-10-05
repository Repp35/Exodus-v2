-- [[ gameinfo ]]

local GameInfo = {}

-- tuning
local T = {
	SNAPSHOT_SCHEMA = 2,
	DEFAULT_FRAME_TIME = 1 / 60,
}

-- state
local Utils
local Players
local Workspace
local cachedBall
local ballReplicatorModule
local deflectAbility

-- helpers
local function now() return Utils.now() end
local function findGameBall()
	local ball = Workspace:FindFirstChild("GameBall", true)
	if typeof(ball) == "Instance" and ball:IsA("BasePart") then return ball end
	return nil
end
local function getBall()
	if cachedBall and cachedBall.Parent then return cachedBall end
	cachedBall = findGameBall(); return cachedBall
end
local function getBallReplicator()
	if ballReplicatorModule and ballReplicatorModule.Parent ~= nil then return ballReplicatorModule end
	ballReplicatorModule = nil; local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then return nil end
	local ts = replicatedStorage:FindFirstChild("TS")
	if not ts then return nil end
	local folder = ts:FindFirstChild("BallReplicator")
	if not folder then return nil end
	local candidate = folder:IsA("ModuleScript") and folder or folder:FindFirstChild("BallReplicator")
	if not candidate or not candidate:IsA("ModuleScript") then return nil end
	local ok, result = pcall(require, candidate)
	if not ok or type(result) ~= "table" then return nil end
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
	local provider = getBallReplicator()
	if not provider then return nil end
	local data = provider.syncData
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
	if type(data) ~= "table" then return -1 end
	local attributeOk, attributeValue = pcall(function() return Workspace:GetAttribute("GameBallTarget") end)
	if attributeOk and attributeValue ~= nil then return normalizeTargetId(attributeValue) or -1 end
	return normalizeTargetId(data.TargetPlayerID) or normalizeTargetId(data.HighlightTargetPlayerID) or -1
end
local function isLocalTargeted(data)
	if type(data) ~= "table" then return false end
	local localPlayer = Players and Players.LocalPlayer
	if not localPlayer then return false end
	local localUserId = tonumber(localPlayer.UserId)
	local attributeOk, attributeValue = pcall(function() return Workspace:GetAttribute("GameBallTarget") end)
	if attributeOk and attributeValue ~= nil then return normalizeTargetId(attributeValue) == localUserId end
	return normalizeTargetId(data.TargetPlayerID) == localUserId
		or normalizeTargetId(data.HighlightTargetPlayerID) == localUserId
end
local function locateDeflectAbility()
	if deflectAbility and deflectAbility.Parent ~= nil then return deflectAbility end
	deflectAbility = nil; local replicatedStorage = Utils.getReplicatedStorage()
	if not replicatedStorage then return nil end
	local ts = replicatedStorage:FindFirstChild("TS")
	if not ts then return nil end
	local bindableManager = ts:FindFirstChild("BindableManager")
	if not bindableManager or not bindableManager:IsA("ModuleScript") then return nil end
	local ok, manager = pcall(require, bindableManager)
	if not ok or type(manager) ~= "table" or type(manager.GetFunction) ~= "function" then return nil end
	local okFunction, getAbility = pcall(manager.GetFunction, manager, "AbilityManager::GetAbility")
	if not okFunction or not getAbility or type(getAbility.Invoke) ~= "function" then return nil end
	for _, name in ipairs({ "Deflect", "Block" }) do
		local okAbility, ability = pcall(getAbility.Invoke, getAbility, name)
		if
			okAbility
			and type(ability) == "table"
			and type(ability.Cooldown) == "number"
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
	if type(cooldown) == "number" and cooldown == cooldown and cooldown < math.huge then return cooldown end
	return 0
end
local function getSnapshot(_, time, frameTime)
	time = type(time) == "number" and time or now(); frameTime = type(frameTime) == "number" and frameTime > 0 and frameTime or T.DEFAULT_FRAME_TIME; local ball = getBall()
	if not ball then return nil end
	local position = ball.Position; local velocity = ball.AssemblyLinearVelocity
	if typeof(velocity) == "Vector3" then position = position + velocity * frameTime end
	local speed = 0
	if typeof(velocity) == "Vector3" then speed = velocity.Magnitude end
	local syncData = getDecodedSyncData(); local teleported, grace, oldGrace = false, false, false
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
		targetId = resolveTargetId(syncData),
		targeted = isLocalTargeted(syncData),
		teleported = teleported,
		grace = grace,
		oldGrace = oldGrace,
		syncAt = time,
	}
end
local function installBallWatcher(trackConnection)
	if type(trackConnection) ~= "function" then return false, "trackConnection invalido" end
	local gameFolder = Workspace:FindFirstChild("Game"); local ballFolder = gameFolder and gameFolder:FindFirstChild("Ball")
	if ballFolder then
		trackConnection(ballFolder.ChildAdded:Connect(function(child)
			if child.Name == "GameBall" and child:IsA("BasePart") then cachedBall = child end
		end))
		trackConnection(ballFolder.ChildRemoved:Connect(function(child)
			if cachedBall == child then cachedBall = nil end
		end))
		local existingBall = ballFolder:FindFirstChild("GameBall")
		if typeof(existingBall) == "Instance" and existingBall:IsA("BasePart") then cachedBall = existingBall end
		return true
	end
	trackConnection(Workspace.DescendantAdded:Connect(function(child)
		if not cachedBall and child.Name == "GameBall" and child:IsA("BasePart") then cachedBall = child end
	end))
	trackConnection(Workspace.DescendantRemoving:Connect(function(child)
		if cachedBall == child then cachedBall = nil end
	end))
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
	cachedBall = nil; ballReplicatorModule = nil; deflectAbility = nil; return true
end
function GameInfo.getBall() return getBall() end
function GameInfo.getSnapshot(lastTarget, time, frameTime) return getSnapshot(lastTarget, time, frameTime) end
function GameInfo.getSyncData() return getDecodedSyncData() end
function GameInfo.getTargetId() return resolveTargetId(getDecodedSyncData()) end
function GameInfo.isSnapshotValid(snapshot) return type(snapshot) == "table" end
function GameInfo.applySync(data) return type(data) == "table" and data or nil end
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
	requires = {
		Utils = "utils",
	},

	ballSync = true,
}

return GameInfo
