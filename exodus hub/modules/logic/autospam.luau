-- [[ auto spam ]]

local AutoSpam = {}

-- dependencies
local utils, gameInfo, dash, players, runService, localPlayer

-- state
local current, generation = nil, 0

-- helpers
local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end
local function userId(value)
	if type(value) == "string" then value = tonumber(value) end
	return finite(value) and value > 0 and value % 1 == 0 and value or nil
end
local function now() return utils.now() end
local function ping()
	local value = gameInfo.getLocalPing(); return finite(value) and math.max(value, 0) or 0
end
local function track(s, signal, callback)
	local connection = signal:Connect(callback); s.connections[#s.connections + 1] = connection; utils.trackCharacter(connection); return connection
end
local function stop(s, reason, distant)
	if current ~= s then return end
	if distant and s.partner then s.recoveryPartner = s.partner end
	if s.active then s.active = false; utils.setAutoSpamActive(false); utils.recordTransition("AutoSpam", "active", "idle", reason) end
	s.reason, s.pending, s.awayAt, s.partner = reason, nil, nil, nil
	s.departedAt, s.departedTo = nil, nil
end
local function stopBoth(s, reason)
	stop(s, reason, false); s.recoveryPartner = nil; utils.setManualSpamActive(false)
end
local function rootOf(id)
	local player = id and players:GetPlayerByUserId(id); local character = player and player.Character; return character and character:FindFirstChild("HumanoidRootPart")
end
local function distanceToPlayer(s, id)
	local root = rootOf(id)
	if not root or not root.Parent or not s.root.Parent then return nil end
	return (root.Position - s.root.Position).Magnitude
end

-- geometry
local function geometry(s, snapshot, factor)
	local speed = tonumber(snapshot.syncSpeed)
	if not finite(speed) or speed <= 0 then speed = snapshot.speed end
	if not finite(speed) or speed <= 0 then return nil end
	local window = gameInfo.getDeflectWindow(speed); local g = gameInfo.getDeflectGeometry(speed, window, factor, true)
	if not g then return nil end
	return g, speed, window
end
local function returnWindow(s, window, speed, partner)
	local distance = distanceToPlayer(s, partner); local travel = distance and speed > 0 and distance * 2 / speed or window; return math.min(window, math.max(1 / 25, travel + 1 / 25)) + ping() * 0.3
end
local function activationReturnWindow(window, speed)
	local minimum, maximum = gameInfo.getBallSpeedLimits(); local fraction = math.clamp((speed - minimum) / (maximum - minimum), 0, 1); local base = 0.18 + (1 / 25 - 0.18) * fraction; return math.min(base, window) + ping() * 0.3
end

-- activation
local function start(s, reason, partner, time)
	if s.active then return end
	s.active, s.partner, s.pending, s.recoveryPartner = true, partner, nil, nil
	s.awayAt = s.target == partner and time or nil
	s.lastSwitchAt, s.reason = time, reason
	s.dashEntry = reason == "return_target" and time <= s.dashUntil; utils.setAutoSpamActive(true); utils.recordTransition("AutoSpam", "idle", "active", reason)
end
local function shouldActivate(s, snapshot, time)
	if not utils.isActive() or utils.getConfigValue("AutoSpam") ~= true then return false end
	if gameInfo.getBallFrozen() == true or not s.pending then return false end
	local pending = s.pending; local factor = time <= s.dashUntil and 1.5 or 0.8; local g = geometry(s, snapshot, factor)
	if not g then return false end
	if pending.recovery then local partnerDistance = distanceToPlayer(s, pending.partner); local normal = geometry(s, snapshot, 0.8); return normal ~= nil and partnerDistance ~= nil and partnerDistance <= normal.fullRadius end
	return s.target == localPlayer.UserId and snapshot.targetId == localPlayer.UserId and (snapshot.position - s.root.Position).Magnitude <= g.fullRadius
end

-- deactivation
local function shouldDeactivate(s, snapshot, time, fresh)
	if not utils.isActive() then return "hub_inactive" end
	if utils.getConfigValue("AutoSpam") ~= true then return "disabled" end
	if gameInfo.getBallFrozen() == true then return "frozen" end
	local g, speed, window = geometry(s, snapshot, 1)
	if not g then return nil end
	local outside = (snapshot.position - s.root.Position).Magnitude > g.fullRadius
	if not outside then s.dashEntry = false end
	if outside and not (s.dashEntry and time <= s.dashUntil) then return "outside_window" end
	if fresh and s.awayAt and s.target == s.partner and time - s.awayAt > returnWindow(s, window, speed, s.partner) then return "return_timeout" end
	if fresh and s.lastSwitchAt and time - s.lastSwitchAt > math.max(0.04, window - 0.04) + ping() * 0.3 then return "no_target_switch" end
	return nil
end

-- target-tracking
local function inspectTarget(s, target, time, snapshot)
	if not target or target == s.target then return end
	local previous, me = s.target, localPlayer.UserId
	if not s.active and s.pending then s.pending = nil end
	if utils.isManualSpamActive() and not s.partner and previous == me and target ~= me then s.partner = target end
	local g, speed, window
	if snapshot then g, speed, window = geometry(s, snapshot, 1) end
	if (s.active or utils.isManualSpamActive()) and target ~= me and target ~= s.partner and s.partner and g then
		local distance = distanceToPlayer(s, target)
		if distance and distance > g.fullRadius then stop(s, "distant_target", true); utils.setManualSpamActive(false) end
	end
	if s.active and s.awayAt and previous == s.partner and target == me and window and time - s.awayAt > returnWindow(s, window, speed, s.partner) then stop(s, "return_timeout", false) end
	if s.lastSwitchAt and time >= s.lastSwitchAt then s.intervalMs = (time - s.lastSwitchAt) * 1000 end
	s.target, s.lastSwitchAt = target, time
	if previous == me and target ~= me then
		s.departedAt, s.departedTo = time, target
		if s.active and target == s.partner then s.awayAt = time end
		if not s.active and s.recoveryPartner == target then s.pending = { partner = target, recovery = true } end
	elseif previous and previous ~= me and target == me then
		if s.active and previous == s.partner then s.awayAt = nil end
		if not s.active and s.recoveryPartner == previous then
			s.pending = { partner = previous, recovery = true }
		elseif not s.active and not s.recoveryPartner and previous == s.departedTo and s.departedAt and window then
			local limit = activationReturnWindow(window, speed) * (time <= s.dashUntil and 2.5 or 1)
			if time - s.departedAt <= limit then s.pending = { partner = previous } end
		end
	end
end

-- evaluation
local function evaluate(s, time, fresh)
	if current ~= s or not s.root.Parent then return end
	if not utils.isActive() then stopBoth(s, "hub_inactive"); return end
	if utils.getConfigValue("AutoSpam") ~= true then
		if s.active then stop(s, "disabled", false) end
		s.pending, s.recoveryPartner, s.departedAt, s.departedTo = nil, nil, nil, nil
	end
	if s.active and gameInfo.getBallFrozen() == true then stop(s, "frozen", false) end
	local snapshot = gameInfo.getSnapshotAt(time)
	if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return end
	if finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt > 0.5 then return end
	local target = userId(snapshot.targetId)
	if not fresh then
		local sequence = snapshot.syncSequence
		if finite(sequence) and finite(s.sequence) then
			local delta = (sequence - s.sequence) % 65536
			if delta >= 32768 or (delta == 0 and target and s.target and target ~= s.target) then return end
		end
		inspectTarget(s, target, time, snapshot)
	end
	if s.active then
		local reason = shouldDeactivate(s, snapshot, time, fresh)
		if reason then stop(s, reason, false) end
	elseif shouldActivate(s, snapshot, time) then
		start(s, s.pending.recovery and "recovery" or "return_target", s.pending.partner, time)
	end
end

-- lifecycle
local function disconnect(s)
	for _, connection in ipairs(s.connections) do
		utils.untrackCharacter(connection); connection:Disconnect()
	end
end
local function detach(reason)
	local s = current
	if s then stop(s, reason, false); current = nil; disconnect(s) end
	generation += 1
end
function AutoSpam.setup(deps)
	if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.Dash then return false, "dependências ausentes" end
	if current then detach("setup") end
	utils, gameInfo, dash = deps.Utils, deps.GameInfo, deps.Dash; players, runService, localPlayer = utils.getPlayers(), utils.getRunService(), utils.getLocalPlayer()
	if not players or not runService or not localPlayer then return false, "serviços indisponíveis" end
	dash.setHandler(function(event)
		local s = current
		if not s or not event or event.userId == localPlayer.UserId or not event.position or not event.velocity then return end
		local offset = s.root.Position - event.position
		if offset.X * event.velocity.X + offset.Z * event.velocity.Z > 0 then s.dashUntil = now() + 0.3; s.dashData = event end
	end)
	return true
end
function AutoSpam.bindCharacter(character)
	detach("rebind"); local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
	local s = {
		root = root,
		character = character,
		connections = {},
		active = false,
		target = nil,
		partner = nil,
		pending = nil,
		recoveryPartner = nil,
		dashUntil = 0,
		reason = "waiting",
		generation = generation,
	}

	current = s
	local function watchCharacter(model)
		local function watchHumanoid(humanoid)
			if humanoid:IsA("Humanoid") then track(s, humanoid.Died, function()
				if current == s then stopBoth(s, "player_died") end
			end) end
		end
		for _, child in ipairs(model:GetChildren()) do
			watchHumanoid(child)
		end
		track(s, model.ChildAdded, watchHumanoid)
	end
	local function watchPlayer(player)
		if player.Character then watchCharacter(player.Character) end
		track(s, player.CharacterAdded, watchCharacter)
	end
	for _, player in ipairs(players:GetPlayers()) do
		watchPlayer(player)
	end
	track(s, players.PlayerAdded, watchPlayer)
	track(s, runService.Heartbeat, function()
		if current ~= s then return end
		local time = now(); dash.tick(time); evaluate(s, time, false)
	end)
	track(s, character.AncestryChanged, function(_, parent)
		if not parent and current == s then detach("character_removed") end
	end)
	return true
end
function AutoSpam.detachCharacter() detach("detach") end
function AutoSpam.teardown()
	detach("teardown")
	if dash then dash.setHandler(nil) end
	utils, gameInfo, dash, players, runService, localPlayer = nil, nil, nil, nil, nil, nil
end
function AutoSpam.onBallSync(data)
	local s = current
	if not s or type(data) ~= "table" then return end
	local sequence = data.Sequence or data.TeleportSequence
	if finite(sequence) and finite(s.sequence) then
		local delta = (sequence - s.sequence) % 65536
		if delta >= 32768 or (delta == 0 and data.Teleported ~= true) then return end
	end
	if finite(sequence) then s.sequence = sequence end
	if data.Teleported == true then
		stop(s, "teleported", false)
		s.target, s.recoveryPartner = nil, nil
		return
	end
	local time = now(); local snapshot = gameInfo.getSnapshotAt(time); local target = userId(data.TargetPlayerID) or userId(data.HighlightTargetPlayerID) or gameInfo.getTargetId()
	if snapshot and userId(target) then inspectTarget(s, target, time, snapshot) end
	evaluate(s, time, true)
end

-- api
function AutoSpam.isActive() return current ~= nil and current.active end
function AutoSpam.stopSpam()
	if current then stop(current, "stop_spam", false) end
end
function AutoSpam.getPullEvent() return nil end
function AutoSpam.getDashData() return current and now() <= current.dashUntil and current.dashData or nil end
function AutoSpam.getTargetSwitch()
	local s = current
	return {
		timestampMs = s and (s.lastSwitchAt or 0) * 1000 or 0,
		partnerId = s and s.partner or -1,
		intervalMs = s and (s.intervalMs or 0) or 0,
		resetToken = generation,
	}
end
function AutoSpam.getActivationContext()
	local s = current; return { active = s ~= nil and s.active, reason = s and s.reason or "detached", partner = s and s.partner or -1 }
end
function AutoSpam.getStatus()
	local s = current
	return {
		schema = utils and utils.apiVersion() or 1,
		phase = s and (s.active and "active" or "idle") or "detached",
		active = s ~= nil and s.active,
		lastGate = s and s.reason or "detached",
		clashPartnerId = s and s.partner or -1,
	}
end

-- contract
AutoSpam.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Dash = "dash" },
	requiresMethods = {
		Utils = {
			"now",
			"getLocalPlayer",
			"getPlayers",
			"getRunService",
			"isActive",
			"getConfigValue",
			"isManualSpamActive",
			"setManualSpamActive",
			"setAutoSpamActive",
			"trackCharacter",
			"untrackCharacter",
			"recordTransition",
			"apiVersion",
		},
		GameInfo = {
			"getSnapshotAt",
			"isSnapshotValid",
			"getDeflectWindow",
			"getDeflectGeometry",
			"getBallFrozen",
			"getLocalPing",
			"getTargetId",
			"getBallSpeedLimits",
		},
		Dash = { "setHandler", "tick" },
	},

	provides = {
		"setup",
		"bindCharacter",
		"detachCharacter",
		"teardown",
		"onBallSync",
		"getStatus",
		"getTargetSwitch",
		"getDashData",
		"getPullEvent",
		"stopSpam",
	},

	onBallSync = true,
	bindCharacter = true,
}

return AutoSpam
