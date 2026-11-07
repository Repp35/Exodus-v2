-- [[ auto spam ]]

local AutoSpam = {}

-- dependencies
local utils, gameInfo, dash, movement, players, runService, localPlayer

-- state
local current, generation = nil, 0
local clashStats

-- tuning
local T = {
	ACTIVATION = {
		RETURN = 0.13,
		RADIUS_FACTOR = 0.8,
		DASH_RADIUS_FACTOR = 1.5,
		DASH_RETURN_MULTIPLIER = 2.5,
		DASH_BONUS_DURATION = 0.3,
		HAUNTER_RANGE = 11,
		HAUNTER_MATCH_RADIUS = 5,
		DASH_AWAY_COSINE = 0.98,
		DASH_TOWARD_COSINE = 0.5,
	},
	DEACTIVATION = {
		MIN_SPEED_DISTANCE = 20,
		MAX_SPEED_DISTANCE = 60,
		MIN_SPEED_TIMEOUT = 0.2975,
		MAX_SPEED_TIMEOUT = 0.06,
		START_DELAY = 0.12,
	},
	SHARED = {
		MIN_RETURN = 1 / 25,
		SNAPSHOT_MAX_AGE = 0.5,
		SEQUENCE_MODULUS = 65536,
		SEQUENCE_HALF = 32768,
	},
}

-- helpers
local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end
local function userId(value)
	if type(value) == "string" then value = tonumber(value) end
	return finite(value) and value > 0 and value % 1 == 0 and value or nil
end
local function now() return utils.now() end
local function dashActive(s, time) return gameInfo.areAbilitiesEnabled() and time <= s.dashUntil end
local function elapsed(localStart, serverStart, localNow, serverNow)
	if finite(serverStart) and finite(serverNow) then
		if serverNow < serverStart then return nil end
		return serverNow - serverStart
	end
	if finite(localStart) and localNow >= localStart then return localNow - localStart end
	return nil
end
local function track(s, signal, callback)
	local connection = signal:Connect(callback); s.connections[#s.connections + 1] = connection; utils.trackCharacter(connection); return connection
end
local function distanceToPlayer(s, id) return id and gameInfo.getPlayerDistance(id) or nil end
local function opponentTooFar(s, partner)
	local distance = distanceToPlayer(s, partner)
	return finite(distance) and distance > 70
end
local function playerIsAlive(id)
	local player = id and players:GetPlayerByUserId(id); local character = player and player.Character; local humanoid = character and character.Parent and character:FindFirstChildOfClass("Humanoid"); return humanoid ~= nil and humanoid.Health > 0
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
local function returnWindow(window, speed, base)
	local minimum, maximum = gameInfo.getBallSpeedLimits(); local factor = maximum > minimum and math.clamp((speed - minimum) / (maximum - minimum), 0, 1) or 0; return math.max(T.SHARED.MIN_RETURN, math.min(base * (1 - 0.9 * factor), window))
end
local function formatPoint(point)
	if typeof(point) ~= "Vector3" then return "indisponível" end
	return string.format("%.2f, %.2f, %.2f", point.X, point.Y, point.Z)
end
local function formatSample(title, sample)
	if not sample then return title .. ": indisponível\n" end
	return string.format(
		"%s\nMinha posição: %s\nPosição do oponente: %s\nPosição da bola: %s\nDistância: %s studs\nVelocidade: %s\n",
		title,
		formatPoint(sample.own),
		formatPoint(sample.opponent),
		formatPoint(sample.ball),
		sample.distance and string.format("%.2f", sample.distance) or "?",
		sample.speed and string.format("%.2f", sample.speed) or "?"
	)
end
local function finishClashStats(reason, time)
	local stats = clashStats
	if not stats or stats.frozen then return end
	stats.frozen, stats.waitingForClash = true, false
	stats.duration = math.max(0, time - stats.startedAt); stats.cps = stats.duration > 0 and stats.totalSwitches / stats.duration or 0; stats.endReason = reason
	if reason ~= "jogador morreu" and reason ~= "oponente morreu" then return end
	local opponent = players:GetPlayerByUserId(stats.partnerId)
	local ok, result = pcall(function()
		local log = utils.createClashLog(stats.partnerId, stats.startedDate)
		utils.appendClashLog(
			log,
			string.format(
				"Oponente: %s\nVencedor: %s\nDuração: %.3f s\nCPS médio: %.2f\nTempo do target até a morte observada: %s\nPenúltimo target: %s\n\n%s\n%s",
				opponent and opponent.Name or tostring(stats.partnerId),
				reason == "jogador morreu" and (opponent and opponent.Name or tostring(stats.partnerId)) or localPlayer.Name,
				stats.duration,
				stats.cps,
				stats.fatalTravelTime and string.format("%.3f s (%.0f ms)", stats.fatalTravelTime, stats.fatalTravelTime * 1000) or "indisponível",
				stats.penultimateTravelTime
						and string.format(
							"%s — %.3f s (%.0f ms)",
							stats.penultimateTarget == localPlayer.UserId and localPlayer.Name or (opponent and opponent.Name or tostring(stats.partnerId)),
							stats.penultimateTravelTime,
							stats.penultimateTravelTime * 1000
						)
					or "indisponível",
				formatSample("INÍCIO", stats.startSample),
				formatSample("FIM", stats.endSample)
			)
		)
	end)
	if not ok then utils.recordError("ClashLog", tostring(result)) end
end
local function beginClashStats(partner, time)
	if clashStats and not clashStats.frozen then finishClashStats("novo clash", clashStats.lastObserved) end
	clashStats = {
		partnerId = partner,
		cps = 0,
		lastObserved = time,
		startedAt = time,
		startedDate = os.date("!%Y-%m-%d %H:%M:%S"),
		totalSwitches = 0,
		frozen = false,
	}

end
local function observeClashStats(s, snapshot, time, fresh)
	local partner = s.active and s.partner
	if not partner then local context = gameInfo.getClashContext(); partner = context and context.partnerId end
	local target = userId(snapshot.targetId)
	if
		not partner
		and clashStats
		and not clashStats.frozen
		and time - (clashStats.lastSwitchAt or clashStats.startedAt) <= 1.5
		and (target == localPlayer.UserId or target == clashStats.partnerId)
	then
		partner = clashStats.partnerId
	end
	if not partner then
		if clashStats and clashStats.frozen then clashStats.waitingForClash = true end
		return
	end
	if clashStats and clashStats.frozen then
		if not clashStats.waitingForClash then return end
		beginClashStats(partner, time)
	elseif not clashStats or clashStats.partnerId ~= partner or time - clashStats.lastObserved > 1.5 then
		beginClashStats(partner, time)
	end
	local stats = clashStats; local observeTarget = fresh or not stats.lastPacketAt or time - stats.lastPacketAt > 0.5
	if fresh then stats.lastPacketAt = time end
	if observeTarget and target then
		local me = localPlayer.UserId
		if fresh then
			local previousTarget = stats.travelObservedTarget
			if previousTarget and previousTarget ~= target then
				if stats.travelTarget == previousTarget and stats.travelStartedAt then
					stats.lastTravelTime, stats.lastTravelTarget = math.max(0, time - stats.travelStartedAt), previousTarget
				else
					stats.lastTravelTime, stats.lastTravelTarget = nil, nil
				end
				if (previousTarget == me or previousTarget == partner) and (target == me or target == partner) then
					stats.travelTarget, stats.travelStartedAt = target, time
				else
					stats.travelTarget, stats.travelStartedAt = nil, nil
				end
			end
			stats.travelObservedTarget = target
		end
		if stats.lastTarget == me and target == partner then
			stats.cycleArmed = true; stats.lastSwitchAt = time
		elseif stats.lastTarget == partner and target == me then
			if stats.cycleArmed then stats.totalSwitches += 1 end
			stats.cycleArmed = false; stats.lastSwitchAt = time
		elseif target ~= me and target ~= partner then
			stats.cycleArmed = false
		end
		stats.lastTarget = target
	end
	local duration = time - stats.startedAt; stats.cps = duration > 0 and stats.totalSwitches / duration or 0; local speed = tonumber(snapshot.syncSpeed)
	if not finite(speed) or speed <= 0 then speed = snapshot.speed end
	if finite(speed) and speed >= 0 then stats.speed = speed end
	local other = gameInfo.getPlayerMotion(partner); local own = s.root.Position; local distance = typeof(other) == "Vector3" and (other - own).Magnitude or nil
	if finite(distance) then stats.distance = distance end
	stats.lastObserved = time; local sample = stats.endSample or {}
	sample.time, sample.distance, sample.speed, sample.cps = math.max(0, time - stats.startedAt), distance, stats.speed, stats.cps
	sample.own, sample.opponent, sample.ball = own, other, snapshot.position
	if not stats.startSample then stats.startSample = table.clone(sample) end
	stats.endSample = sample
end
local function freezeClashStats(playerId)
	if not clashStats or clashStats.frozen then return end
	if playerId ~= localPlayer.UserId and playerId ~= clashStats.partnerId then return end
	local time = now()
	if clashStats.travelTarget == playerId and clashStats.travelStartedAt then
		clashStats.fatalTravelTime = math.max(0, time - clashStats.travelStartedAt)
		clashStats.penultimateTravelTime, clashStats.penultimateTarget = clashStats.lastTravelTime, clashStats.lastTravelTarget
	end
	clashStats.deceasedId = playerId; local sample, s = clashStats.endSample, current
	if sample and s and s.root and s.root.Parent then
		local other = gameInfo.getPlayerMotion(clashStats.partnerId)
		sample.own, sample.opponent = s.root.Position, other
		if typeof(other) == "Vector3" then sample.distance = (other - sample.own).Magnitude end
	end
	finishClashStats(playerId == localPlayer.UserId and "jogador morreu" or "oponente morreu", time)
end

-- activation
local function start(s, reason, partner, time, serverTime)
	if s.active or opponentTooFar(s, partner) then return end
	if clashStats and clashStats.frozen then beginClashStats(partner, time) end
	s.active, s.partner, s.pending, s.recoveryPartner = true, partner, nil, nil
	s.activatedAt, s.switchTimeout = time, nil
	s.awayAt = s.target == partner and time or nil; s.awayServerAt = s.awayAt and serverTime or nil
	s.lastSwitchAt, s.lastSwitchServerAt, s.reason = time, serverTime, reason
	utils.setAutoSpamActive(true); utils.recordTransition("AutoSpam", "idle", "active", reason)
end
local function shouldActivate(s, snapshot, time)
	if not utils.isActive() or utils.getConfigValue("AutoSpam") ~= true then return false end
	if gameInfo.getBallFrozen() == true or not s.pending then return false end
	local pending = s.pending; local factor = dashActive(s, time) and T.ACTIVATION.DASH_RADIUS_FACTOR or T.ACTIVATION.RADIUS_FACTOR; local g = geometry(s, snapshot, factor)
	if not g then return false end
	if pending.recovery then
		local partnerDistance = distanceToPlayer(s, pending.partner); local normal = geometry(s, snapshot, T.ACTIVATION.RADIUS_FACTOR); return normal ~= nil
			and partnerDistance ~= nil
			and partnerDistance <= normal.fullRadius
			and (s.target == localPlayer.UserId or s.target == pending.partner)
			and snapshot.targetId == s.target
			and (snapshot.position - s.root.Position).Magnitude <= normal.fullRadius
	end
	return s.target == localPlayer.UserId and snapshot.targetId == localPlayer.UserId and (snapshot.position - s.root.Position).Magnitude <= g.fullRadius
end

-- deactivation
local function stop(s, reason, distant)
	if current ~= s then return end
	if distant and s.partner then s.recoveryPartner = s.partner end
	if s.active then s.active = false; utils.setAutoSpamActive(false); utils.recordTransition("AutoSpam", "active", "idle", reason) end
	s.reason, s.pending, s.awayAt, s.partner, s.activatedAt = reason, nil, nil, nil, nil
	s.departedAt, s.departedServerAt, s.departedTo, s.awayServerAt = nil, nil, nil, nil
end
local function stopBoth(s, reason)
	stop(s, reason, false)
	s.recoveryPartner, s.manualPartner, s.manualWasActive = nil, nil, false
	utils.setManualSpamActive(false)
end
local function shouldDeactivate(s, snapshot, time, serverTime, targetChanged)
	if not utils.isActive() then return "hub_inactive" end
	if utils.getConfigValue("AutoSpam") ~= true then return "disabled" end
	if gameInfo.getBallFrozen() == true then return "frozen" end
	local speed = snapshot and tonumber(snapshot.syncSpeed)
	if not finite(speed) or speed <= 0 then speed = snapshot and snapshot.speed end
	if finite(speed) and speed > 0 then
		local minimum, maximum = gameInfo.getBallSpeedLimits()
		if finite(minimum) and finite(maximum) and maximum > minimum then
			local factor = math.clamp((speed - minimum) / (maximum - minimum), 0, 1)
			local limit = T.DEACTIVATION.MIN_SPEED_DISTANCE + (T.DEACTIVATION.MAX_SPEED_DISTANCE - T.DEACTIVATION.MIN_SPEED_DISTANCE) * factor
			local distance = distanceToPlayer(s, s.partner)
			if finite(distance) and distance > limit then return "opponent_distance" end
			s.switchTimeout = T.DEACTIVATION.MIN_SPEED_TIMEOUT + (T.DEACTIVATION.MAX_SPEED_TIMEOUT - T.DEACTIVATION.MIN_SPEED_TIMEOUT) * factor
		end
	end
	if s.activatedAt and time - s.activatedAt >= T.DEACTIVATION.START_DELAY
		and s.lastSwitchAt and s.switchTimeout and time - s.lastSwitchAt > s.switchTimeout then
		return "switch_timeout"
	end
	local target = snapshot and userId(snapshot.targetId) or s.target
	if targetChanged and target and target ~= localPlayer.UserId and target ~= s.partner and snapshot then
		local g = geometry(s, snapshot, 1)
		local distance = distanceToPlayer(s, target)
		if g and distance and distance > g.fullRadius then return "distant_target" end
	end
	return nil
end

local function applyDeactivation(s, snapshot, time, serverTime, targetChanged)
	if not s.active then return false end
	local reason = shouldDeactivate(s, snapshot, time, serverTime, targetChanged)
	if not reason then return false end
	stop(s, reason, reason == "distant_target")
	if reason == "distant_target" then utils.setManualSpamActive(false) end
	return true
end

-- target-tracking
local function syncManualPartner(s)
	local manual = utils.isManualSpamActive()
	if manual and not s.manualWasActive then
		s.manualPartner = s.active and s.partner or nil
		s.manualSwitchAt, s.manualSwitchServerAt = now(), nil
	elseif not manual then
		s.manualPartner, s.manualSwitchAt, s.manualSwitchServerAt = nil, nil, nil
	end
	s.manualWasActive = manual
end
local function inspectTarget(s, target, time, snapshot, serverTime)
	syncManualPartner(s)
	if not target or target == s.target then return end
	local previous, me = s.target, localPlayer.UserId
	if not s.active and s.pending then s.pending = nil end
	if utils.isManualSpamActive() and not s.manualPartner then
		if previous == me and target ~= me then s.manualPartner = target elseif previous and previous ~= me and target == me then s.manualPartner = previous end
	end
	local g, speed, window
	local partner = s.active and s.partner or s.manualPartner
	if snapshot and (not s.active or (partner and target ~= me and target ~= partner)) then g, speed, window = geometry(s, snapshot, 1) end
	if utils.isManualSpamActive() and target ~= me and target ~= partner and partner and g then
		local distance = distanceToPlayer(s, target)
		if distance and distance > g.fullRadius then utils.setManualSpamActive(false) end
	end
	local switchElapsed = elapsed(s.lastSwitchAt, s.lastSwitchServerAt, time, serverTime)
	if switchElapsed then s.intervalMs = switchElapsed * 1000 end
	s.target, s.lastSwitchAt, s.lastSwitchServerAt = target, time, serverTime
	if utils.isManualSpamActive() then
		s.manualSwitchAt, s.manualSwitchServerAt = time, serverTime
	end
	if previous == me and target ~= me then
		if not s.active and s.recoveryPartner and target ~= s.recoveryPartner then s.recoveryPartner = nil end
		s.departedAt, s.departedServerAt, s.departedTo = time, serverTime, target
		if s.active and target == s.partner then
			s.awayAt, s.awayServerAt = time, serverTime
		end
		if not s.active and s.recoveryPartner == target then s.pending = { partner = target, recovery = true } end
	elseif previous and previous ~= me and target == me then
		if s.active and previous == s.partner then
			s.awayAt, s.awayServerAt = nil, nil
		end
		if not s.active and s.recoveryPartner == previous then
			s.pending = { partner = previous, recovery = true }
		elseif not s.active and not s.recoveryPartner and previous == s.departedTo and s.departedAt and window then
			local limit = returnWindow(window, speed, T.ACTIVATION.RETURN) * (dashActive(s, time) and T.ACTIVATION.DASH_RETURN_MULTIPLIER or 1); local returnElapsed = elapsed(s.departedAt, s.departedServerAt, time, serverTime)
			if returnElapsed and returnElapsed <= limit then s.pending = { partner = previous } end
		end
	end
end

-- evaluation
local function evaluate(s, time, fresh, serverTime, snapshot, blockedActivation)
	if current ~= s or not s.root.Parent then return end
	if not utils.isActive() then stopBoth(s, "hub_inactive"); return end
	if utils.getConfigValue("AutoSpam") ~= true then
		if s.active then stop(s, "disabled", false) end
		s.pending, s.recoveryPartner, s.departedAt, s.departedTo = nil, nil, nil, nil
	end
	syncManualPartner(s)
	if gameInfo.getBallFrozen() == true then stopBoth(s, "frozen"); return end
	snapshot = snapshot or gameInfo.getSnapshotAt(time)
	-- Deactivation runs on every Heartbeat, regardless of sync packets.
	if not fresh and applyDeactivation(s, snapshot, time, nil, false) then blockedActivation = true end
	if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return end
	if finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt > T.SHARED.SNAPSHOT_MAX_AGE then return end
	local target = userId(snapshot.targetId); observeClashStats(s, snapshot, time, fresh)
	if utils.getConfigValue("AutoClashUpDash") == true and gameInfo.areAbilitiesEnabled() then
		local context = gameInfo.getClashContext(); local partner = s.active and s.partner or (context and context.partnerId); local g = partner and geometry(s, snapshot, 1); local position = g and gameInfo.getPlayerMotion(partner)
		if typeof(position) == "Vector3" then
			local direction = position - s.root.Position
			if direction.Magnitude > g.fullRadius and playerIsAlive(partner) then movement.dashToward(direction) end
		end
	end
	if fresh and utils.isManualSpamActive() then
		local switchElapsed = elapsed(s.manualSwitchAt, s.manualSwitchServerAt, time, serverTime); local _, _, window = geometry(s, snapshot, 1)
		if window and switchElapsed and switchElapsed > window then utils.setManualSpamActive(false) end
	end
	if not s.active and not blockedActivation and shouldActivate(s, snapshot, time) then
		local activationServerTime = serverTime
		if not fresh then activationServerTime = snapshot.serverTime end
		start(s, s.pending.recovery and "recovery" or "return_target", s.pending.partner, time, activationServerTime)
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
	if s then
		if clashStats and not clashStats.frozen then
			local humanoid = s.character and s.character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health <= 0 then freezeClashStats(localPlayer.UserId) else finishClashStats(reason, now()) end
		end
		stop(s, reason, false); current = nil; disconnect(s)
	end
	generation += 1
end
function AutoSpam.setup(deps)
	if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.Dash or not deps.Movement then return false, "dependências ausentes" end
	if current then detach("setup") end
	utils, gameInfo, dash, movement = deps.Utils, deps.GameInfo, deps.Dash, deps.Movement; players, runService, localPlayer = utils.getPlayers(), utils.getRunService(), utils.getLocalPlayer()
	if not players or not runService or not localPlayer then return false, "serviços indisponíveis" end
	dash.setHandler(function(event)
		local s = current
		if not s or not gameInfo.areAbilitiesEnabled() or not event or event.userId == localPlayer.UserId or not event.position or not event.velocity then return end
		if utils.isActive() and utils.getConfigValue("AutoClashUpDash") == true then
			local context = gameInfo.getClashContext(); local partner = s.active and s.partner or (context and context.partnerId); local velocity = event.velocity; local horizontalSpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
			if partner == event.userId and velocity.Y >= 72 and horizontalSpeed <= velocity.Y * 0.5 then movement.upDash() end
		end
		local offset = s.root.Position - event.position; local velocity = event.velocity; local distance, speed = offset.Magnitude, velocity.Magnitude
		if distance > 0 and speed > 0 and velocity:Dot(offset) / (speed * distance) >= T.ACTIVATION.DASH_TOWARD_COSINE then s.dashUntil = now() + T.ACTIVATION.DASH_BONUS_DURATION; s.dashData = event end
		if not utils.isActive() then return end
		local context = gameInfo.getClashContext(); local partner = s.active and s.partner or (context and context.partnerId)
		if
			partner == event.userId
			and playerIsAlive(partner)
			and distance > 0
			and speed > 0
			and -velocity:Dot(offset) / (speed * distance) >= T.ACTIVATION.DASH_AWAY_COSINE
			and velocity.Y / speed < 0.5
		then
			movement.dashToward(-offset)
		end
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
	local haunterConnection, haunterRemote
	local function connectHaunter()
		local event = gameInfo.getHaunterEvent()
		if event == haunterRemote and haunterConnection and haunterConnection.Connected then return end
		if haunterConnection then utils.untrackCharacter(haunterConnection); haunterConnection:Disconnect(); haunterConnection, haunterRemote = nil, nil end
		if not event then return end
		haunterRemote = event
		haunterConnection = track(s, event.OnClientEvent, function(from, destination)
			if current ~= s or s.active or not s.root.Parent or not utils.isActive() or utils.getConfigValue("AutoSpam") ~= true then return end
			if not gameInfo.areAbilitiesEnabled() or gameInfo.getBallFrozen() == true then return end
			if typeof(from) ~= "CFrame" or typeof(destination) ~= "CFrame" then return end
			if (destination.Position - s.root.Position).Magnitude > T.ACTIVATION.HAUNTER_RANGE then return end
			local caster, best
			for _, player in ipairs(players:GetPlayers()) do
				local position = gameInfo.getPlayerMotion(player.UserId)
				if typeof(position) == "Vector3" and playerIsAlive(player.UserId) then
					local distance = math.min((position - from.Position).Magnitude, (position - destination.Position).Magnitude)
					if distance <= T.ACTIVATION.HAUNTER_MATCH_RADIUS and (not best or distance < best) then caster, best = player, distance end
				end
			end
			if not caster or caster == localPlayer then return end
			start(s, "haunter", caster.UserId, now(), nil)
		end)
	end
	connectHaunter()
	local function watchCharacter(player, model)
		local function watchHumanoid(humanoid)
			if humanoid:IsA("Humanoid") then
				track(s, humanoid.Died, function()
					if current == s and player.Character == model then freezeClashStats(player.UserId); stopBoth(s, "player_died") end
				end)
			end
		end
		for _, child in ipairs(model:GetChildren()) do
			watchHumanoid(child)
		end
		track(s, model.ChildAdded, watchHumanoid)
	end
	local function watchPlayer(player)
		if player.Character then watchCharacter(player, player.Character) end
		track(s, player.CharacterAdded, function(character) watchCharacter(player, character) end)
	end
	for _, player in ipairs(players:GetPlayers()) do
		watchPlayer(player)
	end
	track(s, players.PlayerAdded, watchPlayer)
	track(s, runService.Heartbeat, function()
		if current ~= s then return end
		if not haunterConnection or not haunterConnection.Connected or not haunterRemote.Parent then connectHaunter() end
		local autoEnabled = utils.getConfigValue("AutoSpam") == true; local upDashEnabled = utils.getConfigValue("AutoClashUpDash") == true; local clashContext = gameInfo.getClashContext(); local time = now()
		if clashStats and not clashStats.frozen and not s.active and not clashContext and time - clashStats.lastObserved > 1.5 then finishClashStats("clash encerrado", clashStats.lastObserved) end
		if
			not autoEnabled
			and not upDashEnabled
			and not utils.isManualSpamActive()
			and not s.active
			and not clashContext
			and (not clashStats or clashStats.frozen)
		then
			if clashStats and clashStats.frozen then clashStats.waitingForClash = true end
			s.pending, s.recoveryPartner, s.departedAt, s.departedServerAt, s.departedTo = nil, nil, nil, nil, nil
			return
		end
		if not gameInfo.areAbilitiesEnabled() then
			s.dashUntil, s.dashData = 0, nil
		elseif autoEnabled or upDashEnabled or clashContext then
			dash.tick(time, true)
		end
		evaluate(s, time, false)
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
	utils, gameInfo, dash, movement, players, runService, localPlayer = nil, nil, nil, nil, nil, nil, nil
end
function AutoSpam.onBallSync(data)
	local s = current
	if not s or type(data) ~= "table" then return end
	if data.Source ~= "packet" and data.Teleported ~= true then return end
	syncManualPartner(s)
	if gameInfo.getBallFrozen() == true then stopBoth(s, "frozen"); return end
	local sequence = data.Sequence or data.TeleportSequence
	if finite(sequence) and finite(s.sequence) then
		local delta = (sequence - s.sequence) % T.SHARED.SEQUENCE_MODULUS
		if delta >= T.SHARED.SEQUENCE_HALF then return end
	end
	if finite(sequence) then s.sequence = sequence end
	if data.Teleported == true then
		stop(s, "teleported", false)
		s.target, s.recoveryPartner = nil, nil
		return
	end
	if
		utils.getConfigValue("AutoSpam") ~= true
		and not utils.isManualSpamActive()
		and not s.active
		and (not clashStats or clashStats.frozen)
		and not gameInfo.getClashContext()
	then
		s.target = userId(data.TargetPlayerID) or userId(data.HighlightTargetPlayerID) or s.target
		s.pending, s.recoveryPartner, s.departedAt, s.departedServerAt, s.departedTo = nil, nil, nil, nil, nil
		return
	end
	local time = now(); local target = userId(data.TargetPlayerID) or userId(data.HighlightTargetPlayerID) or gameInfo.getTargetId(); local serverTime = tonumber(data.ServerTime)
	if not finite(serverTime) then serverTime = nil end
	local speed = tonumber(data.Speed)
	local snapshot = gameInfo.getSnapshotAt(time)
	if snapshot and data.Source == "packet" and userId(target) then
		snapshot = table.clone(snapshot)
		snapshot.targetId, snapshot.targeted = target, target == localPlayer.UserId
		snapshot.syncAt, snapshot.serverTime, snapshot.syncSequence = time, serverTime, sequence
		snapshot.teleported = false
		if finite(speed) and speed > 0 then snapshot.syncSpeed = speed end
	end
	local stopped = false
	if gameInfo.isSnapshotValid(snapshot) and not snapshot.teleported and userId(target) then
		if target ~= s.target then
			stopped = applyDeactivation(s, snapshot, time, serverTime, true)
		end
		inspectTarget(s, target, time, snapshot, serverTime)
	end
	evaluate(s, time, true, serverTime, snapshot, stopped)
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
		clashStats = clashStats and {
			partnerId = clashStats.partnerId,
			distance = clashStats.distance,
			cps = clashStats.cps,
			startSample = clashStats.startSample,
			endSample = clashStats.endSample,
			endReason = clashStats.endReason,
			speed = clashStats.speed,
			frozen = clashStats.frozen,
			duration = clashStats.duration or math.max(0, now() - clashStats.startedAt),
			travelTarget = clashStats.travelTarget,
			travelStartedAt = not clashStats.frozen and clashStats.travelStartedAt or nil,
			lastTravelTime = clashStats.lastTravelTime,
			lastTravelTarget = clashStats.lastTravelTarget,
			fatalTravelTime = clashStats.fatalTravelTime,
			penultimateTravelTime = clashStats.penultimateTravelTime,
			penultimateTarget = clashStats.penultimateTarget,
			deceasedId = clashStats.deceasedId,
		} or nil,
	}
end

-- contract
AutoSpam.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Dash = "dash", Movement = "movement" },
	requiresMethods = {
		Utils = {
			"now",
			"createClashLog",
			"appendClashLog",
			"recordError",
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
			"areAbilitiesEnabled",
			"getSnapshotAt",
			"isSnapshotValid",
			"getDeflectWindow",
			"getDeflectRange",
			"getPlayerDistance",
			"getPlayerMotion",
			"getHaunterEvent",
			"getLocalPing",
			"getDeflectGeometry",
			"getBallFrozen",
			"getTargetId",
			"getBallSpeedLimits",
			"getClashContext",
		},
		Dash = { "setHandler", "tick" },
		Movement = { "upDash", "dashToward" },
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
