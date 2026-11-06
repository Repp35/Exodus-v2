-- [[ gameinfo ]]

local GameInfo = {}

local utils, players, world
local ball, searchAt, watching = nil, 0, false
local abilityScript, abilities, replicatorScript, replicator, gameBallScript, gameBall
local lastSync, packet, packetAt = nil, nil, 0
local sampledBall, sampledPosition, sampledAt, measuredVelocity, movedAt
-- tuning
local T = {
	MIN_SPEED = 16,
	MAX_SPEED = 600,
	PACKET_AGE = 0.5,
	BALL_SEARCH_INTERVAL = 0.5,
	SYNC_CONNECTED_INTERVAL = 3,
	SYNC_RETRY_INTERVAL = 1,
	COOLDOWN_RETRY = 0.5,
	HELD_COOLDOWN_INTERVAL = 0.05,
	SPEED_REFRESH = 0.5,
	SAMPLE_INTERVAL = 1 / 240,
	SAMPLE_MAX_GAP = 0.25,
	WINDOW_BASE = 0.85,
	WINDOW_SPREAD = 0.65,
	RANGE_BASE = 8.5,
	RANGE_BONUS_SPAN = 7.5,
	RANGE_WINDOW_BONUS = 0.12,
}
local minimumSpeed, maximumSpeed, speedAt = T.MIN_SPEED, T.MAX_SPEED, 0
local errors, cooldownConnection, parriedConnection = {}, nil, nil
local syncConnection, syncRemote, maintenance = nil, nil, 0
local cooldown, signalAt, heldAt, missingAt, warningAt

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function child(parent, name) return parent and parent:FindFirstChild(name) end
local function report(name, message)
	local time = os.clock()
	if errors[name] and time - errors[name] < 2 then return end
	errors[name] = time; local detail = name .. ": " .. tostring(message)
	if utils and type(utils.recordError) == "function" then utils.recordError("GameInfo", detail) else warn("[GameInfo] " .. detail) end
end
local function load(module, name)
	if not module or not module:IsA("ModuleScript") then return nil end
	local ok, result = pcall(require, module)
	if not ok or type(result) ~= "table" then report(name, ok and "módulo não retornou tabela" or result); return nil end
	return result
end
local function storage() return utils and utils.getReplicatedStorage() end
local function ts() return child(storage(), "TS") end

-- abilities
local function getAbilities()
	local module = child(ts(), "ClientAbilities")
	if abilityScript ~= module then abilityScript, abilities = module, nil end
	if not abilities and module then
		local value = load(module, "ClientAbilities")
		if value and type(value.Abilities) == "table" then abilities = value.Abilities elseif value then report("ClientAbilities", "Abilities ausente ou inválido") end
	end
	return abilities
end
local function getAbility(index, method)
	local list = getAbilities(); local ability = list and list[index]
	if type(ability) == "table" and type(ability[method]) == "function" then return ability end
	return nil
end
local function getReplicator()
	local folder = child(ts(), "BallReplicator"); local module = folder and (folder:IsA("ModuleScript") and folder or child(folder, "BallReplicator"))
	if module ~= replicatorScript then replicatorScript, replicator = module, nil end
	if not replicator and module then
		local value = load(module, "BallReplicator")
		if value then
			if type(value.BallReplicator) == "table" then
				replicator = value.BallReplicator
			elseif value.syncData ~= nil then
				replicator = value
			end
		end
	end
	return replicator
end
local function syncData()
	local provider = getReplicator()
	if packet and os.clock() - packetAt > T.PACKET_AGE then packet = nil end
	if packet then
		local sequence = provider and provider.hasState == true and provider.lastSeq
		if type(sequence) ~= "number" or (packet.Sequence ~= sequence and (packet.Sequence - sequence) % 65536 < 32768) then return packet end
		packet = nil
	end
	local data = provider and provider.hasState == true and provider.syncData or lastSync
	if type(data) ~= "table" then data = provider and provider.syncData end
	return type(data) == "table" and data or nil
end

-- targeting
local function targetNumber(value)
	if typeof(value) == "Instance" and value:IsA("Player") then return value.UserId end
	if type(value) == "string" then value = tonumber(value) end
	return finite(value) and value > 0 and value or nil
end
local function targetId(data)
	local target = type(data) == "table" and (targetNumber(data.TargetPlayerID) or targetNumber(data.HighlightTargetPlayerID))
	if target then return target end
	if type(data) == "table" and data.Targeted == true and players.LocalPlayer then return players.LocalPlayer.UserId end
	local ok, value = pcall(world.GetAttribute, world, "GameBallTarget"); return ok and targetNumber(value) or -1
end
local function findBall()
	local candidate = world:FindFirstChild("GameBall") or world:FindFirstChild("GameBall", true)
	if candidate and candidate:IsA("BasePart") then return candidate end
	return nil
end
local function getBall()
	if ball and ball.Parent then return ball end
	if watching and os.clock() < searchAt then return nil end
	ball, searchAt = findBall(), os.clock() + T.BALL_SEARCH_INTERVAL; return ball
end
local function disconnect(connection)
	if connection then
		if utils and type(utils.untrackGlobal) == "function" then utils.untrackGlobal(connection) end
		connection:Disconnect()
	end
end

-- synchronization
local function validSyncRemote(instance) return typeof(instance) == "Instance" and instance:IsA("RemoteEvent") and instance.Parent ~= nil end
local function disconnectSync()
	if syncConnection then
		if utils then utils.untrackGlobal(syncConnection) end
		syncConnection:Disconnect()
	end
	syncConnection, syncRemote = nil, nil
end
local function findSyncRemote()
	local replicated = storage()
	if not replicated then return nil end
	local remotes = replicated:FindFirstChild("Remotes"); local candidate = remotes and remotes:FindFirstChild("BallSyncData")
	if validSyncRemote(candidate) then return candidate end
	candidate = replicated:FindFirstChild("BallSyncData")
	if validSyncRemote(candidate) then return candidate end
	candidate = replicated:FindFirstChild("BallSyncData", true)
	if validSyncRemote(candidate) then return candidate end
	return nil
end
function GameInfo.bindBallSync(handler)
	if type(handler) ~= "function" then return false end
	local candidate = findSyncRemote()
	if not candidate then
		if syncRemote and not validSyncRemote(syncRemote) then disconnectSync() end
		return syncConnection ~= nil and syncConnection.Connected == true
	end
	if syncConnection and syncConnection.Connected and syncRemote == candidate then return true end
	disconnectSync()
	local ok, connection = pcall(function() return candidate.OnClientEvent:Connect(handler) end)
	if not ok or not connection then return false end
	syncConnection, syncRemote = connection, candidate; utils.trackGlobal(connection); return true
end
function GameInfo.startMaintenance(options)
	if type(options) ~= "table" or type(options.isActive) ~= "function" then return false end
	maintenance += 1; local token = maintenance
	task.spawn(function()
		while token == maintenance do
			local activeOk, active = pcall(options.isActive)
			if not activeOk or active ~= true or token ~= maintenance then break end
			local linked = type(options.onBallSync) == "function" and GameInfo.bindBallSync(options.onBallSync)
			if token ~= maintenance then break end
			task.wait(linked and T.SYNC_CONNECTED_INTERVAL or T.SYNC_RETRY_INTERVAL)
		end
	end)
	return true
end
function GameInfo.stopMaintenance()
	maintenance += 1; disconnectSync()
end

-- setup
function GameInfo.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
	GameInfo.stopMaintenance(); disconnect(cooldownConnection); disconnect(parriedConnection); cooldownConnection, parriedConnection = nil, nil
	utils = deps.Utils; players, world = utils.getPlayers(), utils.getWorkspace()
	if not players or not world then return false, "dependência ausente: Players ou Workspace" end
	ball, searchAt, watching = nil, 0, false; abilityScript, abilities, replicatorScript, replicator, gameBallScript, gameBall = nil, nil, nil, nil, nil, nil; lastSync, packet, packetAt = nil, nil, 0
	sampledBall, sampledPosition, sampledAt, measuredVelocity, movedAt = nil, nil, nil, nil, nil; minimumSpeed, maximumSpeed, speedAt = T.MIN_SPEED, T.MAX_SPEED, 0; errors = {}
	cooldown = { known = false, active = false, rawActive = false, lastEventAt = -math.huge }; signalAt, heldAt, missingAt, warningAt = 0, 0, nil, 0; GameInfo.getDeflectCooldownState(); return true
end
function GameInfo.getBall() return getBall() end
function GameInfo.getBallPosition(value) return value.Position end
function GameInfo.getBallVelocity(value) return value.AssemblyLinearVelocity end
function GameInfo.getRootPosition(root) return root.Position end
function GameInfo.getLocalPing() return players.LocalPlayer and players.LocalPlayer:GetNetworkPing() or nil end
function GameInfo.getDeflectRange() return players.LocalPlayer and players.LocalPlayer:GetAttribute("DeflectRange") or nil end
function GameInfo.getDeflectAbility() return getAbility(1, "Deflect") end
function GameInfo.getDashAbility() return getAbility(2, "Dash") end
function GameInfo.getFierceDeflectAbility() return getAbility(19, "ActivateAndBlock") end
function GameInfo.getDarkSealAbility() return getAbility(20, "SendEvent") end
local function generatedRemote(id)
	local remotes = child(ts(), "GeneratedNetworkRemotes"); local remote = child(remotes, "RE_" .. tostring(id)); return remote and remote:IsA("RemoteEvent") and remote or nil
end
function GameInfo.getDeflectServerEvents()
	local first, second = generatedRemote(5.520474058077904e76), generatedRemote(9.611859444202098e76)
	if not first then return nil end
	return { cooldown = first.OnClientEvent, parried = second and second.OnClientEvent or nil }
end
function GameInfo.decodeDeflectServerEvent(abilityId, eventId, value)
	if abilityId ~= 1 then return nil end
	if eventId == 5.93848805167512e76 and finite(value) then return value > 0 and "started" or "reset", math.max(value, 0) end
	if eventId == 6.60750295352893e76 then return "stopped", 0 end
	return nil
end
function GameInfo.getHeldDeflectServerCooldown()
	local ability = GameInfo.getDeflectAbility()
	if not ability then return nil end
	local duration, received = ability.HeldServerCooldown, ability.HeldServerCooldownAt
	if finite(duration) and duration > 0 and finite(received) then return duration, received end
	return nil
end
function GameInfo.getDeflectCooldownState()
	local time = os.clock()
	if cooldownConnection and cooldownConnection.Connected == false then
		disconnect(cooldownConnection); cooldownConnection = nil
		cooldown.rawActive, cooldown.endsAt, signalAt = false, nil, 0
	end
	if parriedConnection and parriedConnection.Connected == false then disconnect(parriedConnection); parriedConnection = nil end
	if not cooldownConnection and time >= signalAt then
		signalAt = time + T.COOLDOWN_RETRY; local signals = GameInfo.getDeflectServerEvents()
		if signals and signals.cooldown then
			cooldownConnection = signals.cooldown:Connect(function(abilityId, eventId, value)
				local kind, duration = GameInfo.decodeDeflectServerEvent(abilityId, eventId, value)
				if not kind then return end
				cooldown.known, cooldown.lastEventAt = true, os.clock()
				cooldown.rawActive = kind == "started"; cooldown.endsAt = cooldown.rawActive and cooldown.lastEventAt + duration or nil
			end)
			utils.trackGlobal(cooldownConnection); missingAt = nil
		else
			missingAt = missingAt or time
			if time - missingAt >= 3 and time >= warningAt then warningAt = time + 10; report("DeflectCooldown", "evento de cooldown do servidor indisponível") end
		end
	end
	if cooldownConnection and not parriedConnection then
		local signals = GameInfo.getDeflectServerEvents()
		if signals and signals.parried then
			parriedConnection = signals.parried:Connect(function()
				cooldown.active, cooldown.rawActive, cooldown.endsAt, cooldown.lastEventAt = false, false, nil, os.clock()
			end)
			utils.trackGlobal(parriedConnection)
		end
	end
	if not cooldown.rawActive and time >= heldAt then
		heldAt = time + T.HELD_COOLDOWN_INTERVAL; local duration, received = GameInfo.getHeldDeflectServerCooldown()
		if duration and received and received <= time and time < received + duration and received > cooldown.lastEventAt + 0.01 then
			cooldown.known, cooldown.rawActive, cooldown.lastEventAt, cooldown.endsAt = true, true, received, received + duration
		end
	end
	if cooldown.rawActive and finite(cooldown.endsAt) and time >= cooldown.endsAt then
		cooldown.rawActive, cooldown.endsAt = false, nil
	end
	local ability = GameInfo.getDeflectAbility(); local localCooldown = ability and finite(ability.Cooldown) and ability.Cooldown > 0
	if localCooldown then cooldown.known = true end
	local remaining = localCooldown and ability.Cooldown or 0
	if cooldown.rawActive and finite(cooldown.endsAt) then remaining = math.max(remaining, cooldown.endsAt - time) end
	cooldown.remaining = math.max(0, remaining); cooldown.active = cooldown.rawActive or localCooldown == true; cooldown.blocking = cooldown.active; return cooldown
end
function GameInfo.getSyncData() return syncData() end
local function syncSequence(current, provider)
	if packet and current == packet then return packet.Sequence end
	return provider and provider.hasState == true and provider.lastSeq or nil
end
function GameInfo.getSyncSequence() return syncSequence(syncData(), getReplicator()) end
function GameInfo.applyPacket(value)
	if type(value) ~= "table" then return false end
	local sequence = value.Sequence
	if not finite(sequence) or sequence < 0 or sequence >= 65536 or sequence % 1 ~= 0 then return false end
	local previous = GameInfo.getSyncSequence()
	if type(previous) == "number" then
		local delta = (sequence - previous) % 65536
		if delta == 0 or delta >= 32768 then return false end
	end
	packet, packetAt = table.clone(value), os.clock(); return true
end
function GameInfo.decodeBallPacket(value)
	local provider = getReplicator()
	if not provider or type(provider.Decode) ~= "function" then return nil end
	local decoded = provider:Decode(value)
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
function GameInfo.getTargetId() return targetId(syncData()) end

-- snapshots
local function snapshot(time)
	local currentBall = getBall()
	if not currentBall then return nil end
	time = type(time) == "number" and time or utils.now(); local position, velocity, sync = currentBall.Position, currentBall.AssemblyLinearVelocity, syncData()
	if sampledBall ~= currentBall or (sync and sync.Teleported == true) then
		sampledBall, sampledPosition, sampledAt, measuredVelocity, movedAt = currentBall, position, time, Vector3.zero, nil
	elseif sampledPosition and sampledAt and time - sampledAt >= T.SAMPLE_INTERVAL then
		local elapsed = time - sampledAt; local displacement = position - sampledPosition
		if displacement.Magnitude > 0.001 then
			local measured, expected = displacement / elapsed, sync and tonumber(sync.Speed)
			if elapsed <= T.SAMPLE_MAX_GAP and (not expected or expected <= 0 or measured.Magnitude <= expected * 2.5 + 30) then measuredVelocity, movedAt = measured, time
			else measuredVelocity, movedAt = Vector3.zero, nil end
		elseif movedAt and time - movedAt > 0.1 then
			measuredVelocity = Vector3.zero
		end
		sampledPosition, sampledAt = position, time
	end
	if typeof(velocity) ~= "Vector3" or velocity.Magnitude < 0.1 then velocity = measuredVelocity or Vector3.zero end
	local target, provider = targetId(sync), getReplicator()
	return {
		schema = 2,
		generatedAt = time,
		valid = true,
		ball = currentBall,
		ballValid = true,
		position = position,
		velocity = velocity,
		speed = velocity.Magnitude,
		syncSpeed = sync and sync.Speed or nil,
		realPosition = sync and sync.RealPosition or nil,
		targetId = target,
		targeted = players.LocalPlayer ~= nil and target == players.LocalPlayer.UserId,
		teleported = sync and sync.Teleported == true or false,
		grace = sync and sync.Grace == true or false,
		oldGrace = sync and sync.OldGrace == true or false,
		syncAt = time,
		syncSequence = syncSequence(sync, provider),
	}
end
function GameInfo.getSnapshot(_, time) return snapshot(time) end
function GameInfo.getSnapshotAt(time) return snapshot(time) end
function GameInfo.isSnapshotValid(value)
	return type(value) == "table"
		and typeof(value.ball) == "Instance"
		and value.ball:IsA("BasePart")
		and typeof(value.position) == "Vector3"
		and typeof(value.velocity) == "Vector3"
		and finite(value.speed)
		and value.speed >= 0
		and type(value.targetId) == "number"
		and type(value.targeted) == "boolean"
end
function GameInfo.applySync(value)
	if type(value) == "table" and type(value.syncData) == "table" then value = value.syncData end
	if type(value) ~= "table" then local provider = getReplicator(); value = provider and provider.syncData end
	if type(value) ~= "table" then return nil end
	lastSync = value; return value
end
function GameInfo.installBallWatcher(track)
	if type(track) ~= "function" then return false, "trackConnection invalido" end
	track((world.DescendantAdded or world.ChildAdded):Connect(function(item)
		if item.Name == "GameBall" and item:IsA("BasePart") then ball = item end
	end))
	track((world.DescendantRemoving or world.ChildRemoved):Connect(function(item)
		if ball == item then ball, searchAt = nil, 0 end
	end))
	ball, watching, searchAt = findBall(), true, os.clock() + T.BALL_SEARCH_INTERVAL; return true
end
function GameInfo.getBallSpeedLimits()
	local time = os.clock()
	if time < speedAt then return minimumSpeed, maximumSpeed end
	speedAt = time + T.SPEED_REFRESH; local module = child(child(ts(), "Gameplay"), "GameBall")
	if module ~= gameBallScript then gameBallScript, gameBall = module, nil end
	if not gameBall then local value = load(module, "GameBall"); gameBall = value and value.GameBall end
	if type(gameBall) ~= "table" or type(gameBall.GetBaseSpeed) ~= "function" or type(gameBall.GetMaxSpeed) ~= "function" then
		report("GameBall", "API de velocidade indisponível; usando últimos limites conhecidos"); return minimumSpeed, maximumSpeed
	end
	local ok, low, high = pcall(function() return gameBall:GetBaseSpeed(), gameBall:GetMaxSpeed() end)
	if ok and finite(low) and finite(high) and low > 0 and high > low then minimumSpeed, maximumSpeed = low, high else report("GameBall", ok and "limites de velocidade inválidos" or low) end
	return minimumSpeed, maximumSpeed
end
function GameInfo.getDeflectWindow(speed)
	local low, high = GameInfo.getBallSpeedLimits(); local sync = syncData()
	if not finite(speed) and sync and finite(sync.Speed) then speed = sync.Speed end
	if not finite(speed) or high <= low then return nil end
	local window = T.WINDOW_BASE - T.WINDOW_SPREAD * math.clamp((speed - low) / (high - low), 0, 1); local player = players.LocalPlayer; local inClash = false
	if gameBall and player and type(gameBall.IsInClash) == "function" then local ok, active = pcall(gameBall.IsInClash, gameBall, player); inClash = ok and active == true end
	if inClash and type(gameBall.GetClashMinWindow) == "function" then
		local ok, minimum = pcall(gameBall.GetClashMinWindow, gameBall, speed)
		if ok and finite(minimum) then window = math.max(window, minimum) end
	end
	local range = GameInfo.getDeflectRange()
	if finite(range) then window += math.clamp((range - T.RANGE_BASE) / T.RANGE_BONUS_SPAN, 0, 1) * T.RANGE_WINDOW_BONUS end
	if inClash and type(gameBall.GetClashWindowScale) == "function" then
		local ok, scale = pcall(gameBall.GetClashWindowScale, gameBall)
		if ok and finite(scale) and scale > 0 then window *= scale end
	end
	return window
end
function GameInfo.getManifestRemote() return generatedRemote(9.318024238496386e76) end
function GameInfo.getClashContext()
	local player = players.LocalPlayer
	if not player then return nil end
	local lastAt, by, target = world:GetAttribute("LastParryAt"), world:GetAttribute("LastParryBy"), world:GetAttribute("LastParryTarget")
	if type(lastAt) ~= "number" or type(by) ~= "number" or type(target) ~= "number" then return nil end
	local partnerId = by == player.UserId and target or (target == player.UserId and by or nil)
	if not partnerId or partnerId <= 0 or partnerId == player.UserId then return nil end
	local age, currentTarget = world:GetServerTimeNow() - lastAt, world:GetAttribute("GameBallTarget")
	if age < 0 or (age > 1 and (age > 2.5 or currentTarget ~= target)) then return nil end
	local partner = players:GetPlayerByUserId(partnerId); local ownRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local partnerRoot = partner and partner.Character and partner.Character:FindFirstChild("HumanoidRootPart")
	if not ownRoot or not partnerRoot or (ownRoot.Position - partnerRoot.Position).Magnitude > 35 then return nil end
	return { partnerId = partnerId, lastParryAt = lastAt, age = age }
end

-- status
function GameInfo.getStatus()
	local now = utils.now(); local value = snapshot(now)
	return {
		schema = utils.apiVersion(),
		generatedAt = now,
		available = value ~= nil,
		targetId = value and value.targetId or -1,
		targeted = value and value.targeted or false,
		speed = value and value.speed or 0,
	}
end

-- contract
GameInfo.__contract = {
	requires = { Utils = "utils" },
	requiresMethods = { Utils = { "now", "apiVersion", "getPlayers", "getReplicatedStorage", "getWorkspace" } },
	provides = {
		"setup",
		"getBall",
		"getBallPosition",
		"getBallVelocity",
		"getRootPosition",
		"getLocalPing",
		"getDeflectRange",
		"getDeflectWindow",
		"getDeflectAbility",
		"getDeflectServerEvents",
		"decodeDeflectServerEvent",
		"getHeldDeflectServerCooldown",
		"getDeflectCooldownState",
		"getDashAbility",
		"getFierceDeflectAbility",
		"getDarkSealAbility",
		"getBallSpeedLimits",
		"getSnapshot",
		"getSnapshotAt",
		"isSnapshotValid",
		"getSyncData",
		"getSyncSequence",
		"decodeBallPacket",
		"getTargetId",
		"applySync",
		"installBallWatcher",
		"bindBallSync",
		"startMaintenance",
		"stopMaintenance",
	},

}

return GameInfo
