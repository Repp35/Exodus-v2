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
		DASH_AWAY_COSINE = 0.98,
		DASH_TOWARD_COSINE = 0.5,
	},
	DEACTIVATION = {
		RETURN = 0.1,
		RETURN_MARGIN = 0.01,
		SWITCH_WINDOW_MARGIN = 0.04,
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
local function returnLimit(s, speed, window)
	local limit = returnWindow(window, speed, T.DEACTIVATION.RETURN); local distance = distanceToPlayer(s, s.partner)
	if not distance then return limit + T.DEACTIVATION.RETURN_MARGIN, false end
	local ownRange = tonumber(gameInfo.getDeflectRange())
	if not finite(ownRange) or ownRange <= 0 then ownRange = 8.5 end
	local ping = gameInfo.getLocalPing()
	if not finite(ping) or ping < 0 then ping = 0 end
	local close = distance <= ownRange + 8.5 + speed * ping; local travel = math.max(0, distance - ownRange - 8.5) / speed; return math.max(limit, travel + T.SHARED.MIN_RETURN + ping) + T.DEACTIVATION.RETURN_MARGIN, close
end
local function reportClashLogError(stats, message)
	stats.logFailed = true; utils.recordError("ClashLog", tostring(message))
end
local function flushClashLog(stats)
	if stats.logFailed or not stats.log or #stats.logBuffer == 0 then return end
	local chunk = table.concat(stats.logBuffer); local ok, err = pcall(utils.appendClashLog, stats.log, chunk)
	if not ok then reportClashLogError(stats, err); return end
	table.clear(stats.logBuffer)
end
local function appendClashLog(stats, line)
	if not stats.logFailed and stats.log then stats.logBuffer[#stats.logBuffer + 1] = line .. "\n" end
end
local function finishClashStats(reason, time)
	local stats = clashStats
	if not stats or stats.frozen then return end
	stats.frozen, stats.waitingForClash = true, false
	stats.duration = math.max(0, time - stats.startedAt); stats.cps = stats.duration > 0 and stats.totalSwitches / stats.duration or 0; stats.endReason = reason
	local function summary(label, sample)
		if not sample then return label .. ": indisponível" end
		return string.format(
			"%s: tempo=%.3fs | distância=%s studs | velocidade=%s | CPS médio=%.2f | ping=%s ms | alvo=%s",
			label,
			sample.time,
			sample.distance and string.format("%.2f", sample.distance) or "?",
			sample.speed and string.format("%.2f", sample.speed) or "?",
			sample.cps,
			sample.ping and string.format("%.1f", sample.ping * 1000) or "?",
			tostring(sample.target or "?")
		)
	end
	appendClashLog(stats, "\n" .. summary("INÍCIO", stats.startSample)); appendClashLog(stats, summary("ÚLTIMA AMOSTRA ANTES DO FIM", stats.endSample))
	appendClashLog(
		stats,
		string.format(
			"\nFIM: %s\nDuração: %.3f s\nTrocas de alvo: %d\nCPS médio: %.2f\nMaior CPS em 1 segundo: %d\nMaior velocidade observada: %.2f\nMenor distância observada: %s\n",
			reason,
			stats.duration,
			stats.totalSwitches,
			stats.cps,
			stats.maxCps,
			stats.maxSpeed,
			stats.minDistance and string.format("%.2f studs", stats.minDistance) or "indisponível"
		)
	)
	flushClashLog(stats)
end
local function beginClashStats(partner, time)
	if clashStats and not clashStats.frozen then finishClashStats("novo clash", clashStats.lastObserved) end
	local stats = {
		partnerId = partner,
		switches = {},
		cps = 0,
		lastObserved = time,
		startedAt = time,
		totalSwitches = 0,
		maxCps = 0,
		maxSpeed = 0,
		frozen = false,
		logBuffer = {},
		lastLogFlush = time,
		lastSample = -math.huge,
	}

	clashStats = stats; local ok, result = pcall(utils.createClashLog, partner)
	if ok then
		stats.log = result; local opponent = players:GetPlayerByUserId(partner); appendClashLog(stats, "Oponente: " .. (opponent and opponent.Name or tostring(partner)))
		appendClashLog(
			stats,
			"AMOSTRA;tempo_s;velocidade;distância_studs;cps;alvo_id;ping_ms;grace;bola_x;bola_y;bola_z;meu_x;meu_y;meu_z;oponente_x;oponente_y;oponente_z"
		)
	else
		reportClashLogError(stats, result)
	end
end
local function observeClashStats(s, snapshot, time)
	local context = gameInfo.getClashContext(); local partner = s.active and s.partner or (context and context.partnerId); local target = userId(snapshot.targetId)
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
	local stats = clashStats
	if stats.lastTarget and target and stats.lastTarget ~= target then
		local me = localPlayer.UserId
		if (stats.lastTarget == me and target == partner) or (stats.lastTarget == partner and target == me) then stats.switches[#stats.switches + 1] = time; stats.totalSwitches += 1; stats.lastSwitchAt = time; appendClashLog(stats, string.format("TROCA;%.3f;%d;%d", math.max(0, time - stats.startedAt), stats.lastTarget, target)) end
	end
	if target then stats.lastTarget = target end
	while #stats.switches > 0 and (time < stats.switches[1] or time - stats.switches[1] > 1) do
		table.remove(stats.switches, 1)
	end
	stats.maxCps = math.max(stats.maxCps, #stats.switches); local duration = time - stats.startedAt; stats.cps = duration > 0 and stats.totalSwitches / duration or 0; local speed = tonumber(snapshot.syncSpeed)
	if not finite(speed) or speed <= 0 then speed = snapshot.speed end
	if finite(speed) and speed >= 0 then stats.speed = speed; stats.maxSpeed = math.max(stats.maxSpeed, speed) end
	local distance = distanceToPlayer(s, partner)
	if finite(distance) then stats.distance = distance; stats.minDistance = stats.minDistance and math.min(stats.minDistance, distance) or distance end
	stats.lastObserved = time; local ping = gameInfo.getLocalPing()
	local sample = {
		time = math.max(0, time - stats.startedAt),
		distance = stats.distance,
		speed = stats.speed,
		cps = stats.cps,
		ping = finite(ping) and ping or nil,
		target = target,
	}

	stats.startSample = stats.startSample or sample; stats.endSample = sample
	if time - stats.lastSample >= 0.1 then
		local ping = gameInfo.getLocalPing(); local ball, own = snapshot.position, s.root.Position; local other = gameInfo.getPlayerMotion(partner)
		local function coordinate(point, axis) return typeof(point) == "Vector3" and string.format("%.2f", point[axis]) or "?" end
		appendClashLog(
			stats,
			string.format(
				"AMOSTRA;%.3f;%s;%s;%.2f;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s",
				math.max(0, time - stats.startedAt),
				stats.speed and string.format("%.2f", stats.speed) or "?",
				stats.distance and string.format("%.2f", stats.distance) or "?",
				stats.cps,
				target and tostring(target) or "?",
				finite(ping) and string.format("%.1f", ping * 1000) or "?",
				tostring(snapshot.grace == true),
				coordinate(ball, "X"),
				coordinate(ball, "Y"),
				coordinate(ball, "Z"),
				coordinate(own, "X"),
				coordinate(own, "Y"),
				coordinate(own, "Z"),
				coordinate(other, "X"),
				coordinate(other, "Y"),
				coordinate(other, "Z")
			)
		)
		stats.lastSample = time
	end
	if time - stats.lastLogFlush >= 0.5 then flushClashLog(stats); stats.lastLogFlush = time end
end
local function freezeClashStats(playerId)
	if not clashStats or clashStats.frozen then return end
	if playerId ~= localPlayer.UserId and playerId ~= clashStats.partnerId then return end
	finishClashStats(playerId == localPlayer.UserId and "jogador morreu" or "oponente morreu", now())
end

-- activation
local function start(s, reason, partner, time, serverTime)
	if s.active then return end
	if clashStats and clashStats.frozen then beginClashStats(partner, time) end
	s.active, s.partner, s.pending, s.recoveryPartner = true, partner, nil, nil
	s.awayAt = s.target == partner and time or nil; s.awayServerAt = s.awayAt and serverTime or nil
	s.lastSwitchAt, s.lastSwitchServerAt, s.reason = time, serverTime, reason
	s.dashEntry = reason == "return_target" and dashActive(s, time); utils.setAutoSpamActive(true); utils.recordTransition("AutoSpam", "idle", "active", reason)
end
local function shouldActivate(s, snapshot, time)
	if not utils.isActive() or utils.getConfigValue("AutoSpam") ~= true then return false end
	if gameInfo.getBallFrozen() == true or not s.pending then return false end
	local pending = s.pending; local factor = dashActive(s, time) and T.ACTIVATION.DASH_RADIUS_FACTOR or T.ACTIVATION.RADIUS_FACTOR; local g = geometry(s, snapshot, factor)
	if not g then return false end
	if pending.recovery then local partnerDistance = distanceToPlayer(s, pending.partner); local normal = geometry(s, snapshot, T.ACTIVATION.RADIUS_FACTOR); return normal ~= nil and partnerDistance ~= nil and partnerDistance <= normal.fullRadius end
	return s.target == localPlayer.UserId and snapshot.targetId == localPlayer.UserId and (snapshot.position - s.root.Position).Magnitude <= g.fullRadius
end

-- deactivation
local function stop(s, reason, distant)
	if current ~= s then return end
	if distant and s.partner then s.recoveryPartner = s.partner end
	if s.active then s.active = false; utils.setAutoSpamActive(false); utils.recordTransition("AutoSpam", "active", "idle", reason) end
	s.reason, s.pending, s.awayAt, s.partner = reason, nil, nil, nil
	s.departedAt, s.departedServerAt, s.departedTo, s.awayServerAt = nil, nil, nil, nil
end
local function stopBoth(s, reason)
	stop(s, reason, false)
	s.recoveryPartner, s.manualPartner, s.manualWasActive = nil, nil, false
	utils.setManualSpamActive(false)
end
local function shouldDeactivate(s, snapshot, time, fresh, serverTime)
	if not utils.isActive() then return "hub_inactive" end
	if utils.getConfigValue("AutoSpam") ~= true then return "disabled" end
	if gameInfo.getBallFrozen() == true then return "frozen" end
	local g, speed, window = geometry(s, snapshot, 1)
	if not g then return nil end
	local outside = (snapshot.position - s.root.Position).Magnitude > g.fullRadius
	if not outside then s.dashEntry = false end
	if outside and not (s.dashEntry and dashActive(s, time)) then return "outside_window" end
	local awayElapsed = elapsed(s.awayAt, s.awayServerAt, time, serverTime); local limit, close = returnLimit(s, speed, window)
	if fresh and awayElapsed and s.target == s.partner and not close and awayElapsed > limit then return "return_timeout" end
	local switchElapsed = elapsed(s.lastSwitchAt, s.lastSwitchServerAt, time, serverTime)
	if fresh and switchElapsed and switchElapsed > math.max(T.DEACTIVATION.SWITCH_WINDOW_MARGIN, window - T.DEACTIVATION.SWITCH_WINDOW_MARGIN) then return "no_target_switch" end
	return nil
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
	if snapshot then g, speed, window = geometry(s, snapshot, 1) end
	local partner = s.active and s.partner or s.manualPartner
	if (s.active or utils.isManualSpamActive()) and target ~= me and target ~= partner and partner and g then
		local distance = distanceToPlayer(s, target)
		if distance and distance > g.fullRadius then stop(s, "distant_target", true); utils.setManualSpamActive(false) end
	end
	local awayElapsed = elapsed(s.awayAt, s.awayServerAt, time, serverTime)
	if s.active and awayElapsed and previous == s.partner and target == me and window then
		local limit, close = returnLimit(s, speed, window)
		if not close and awayElapsed > limit then stop(s, "return_timeout", false) end
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
local function evaluate(s, time, fresh, serverTime, snapshot)
	if current ~= s or not s.root.Parent then return end
	if not utils.isActive() then stopBoth(s, "hub_inactive"); return end
	if utils.getConfigValue("AutoSpam") ~= true then
		if s.active then stop(s, "disabled", false) end
		s.pending, s.recoveryPartner, s.departedAt, s.departedTo = nil, nil, nil, nil
	end
	syncManualPartner(s)
	if gameInfo.getBallFrozen() == true then stopBoth(s, "frozen"); return end
	snapshot = snapshot or gameInfo.getSnapshotAt(time)
	if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return end
	if finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt > T.SHARED.SNAPSHOT_MAX_AGE then return end
	local target = userId(snapshot.targetId)
	if not fresh then
		local sequence = snapshot.syncSequence
		if finite(sequence) and finite(s.sequence) then
			local delta = (sequence - s.sequence) % T.SHARED.SEQUENCE_MODULUS
			if delta >= T.SHARED.SEQUENCE_HALF or (delta == 0 and target and s.target and target ~= s.target) then return end
		end
		inspectTarget(s, target, time, snapshot, snapshot.serverTime)
	end
	observeClashStats(s, snapshot, time)
	if utils.getConfigValue("AutoClashUpDash") == true and gameInfo.areAbilitiesEnabled() then
		local context = gameInfo.getClashContext(); local partner = s.active and s.partner or (context and context.partnerId); local g = partner and geometry(s, snapshot, 1); local position = g and gameInfo.getPlayerMotion(partner)
		if typeof(position) == "Vector3" then
			local direction = position - s.root.Position
			if direction.Magnitude > g.fullRadius then movement.dashToward(direction) end
		end
	end
	if fresh and utils.isManualSpamActive() then
		local switchElapsed = elapsed(s.manualSwitchAt, s.manualSwitchServerAt, time, serverTime); local _, _, window = geometry(s, snapshot, 1)
		if window and switchElapsed and switchElapsed > math.max(T.DEACTIVATION.SWITCH_WINDOW_MARGIN, window - T.DEACTIVATION.SWITCH_WINDOW_MARGIN) then utils.setManualSpamActive(false) end
	end
	if s.active then
		local reason = shouldDeactivate(s, snapshot, time, fresh, serverTime)
		if reason then stop(s, reason, false) end
	elseif shouldActivate(s, snapshot, time) then
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
		if clashStats and not clashStats.frozen then finishClashStats(reason, now()) end
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
	local function watchCharacter(player, model)
		local function watchHumanoid(humanoid)
			if humanoid:IsA("Humanoid") then
				track(s, humanoid.Died, function()
					if current == s then freezeClashStats(player.UserId); stopBoth(s, "player_died") end
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
	syncManualPartner(s)
	if gameInfo.getBallFrozen() == true then stopBoth(s, "frozen"); return end
	local sequence = data.Sequence or data.TeleportSequence
	if finite(sequence) and finite(s.sequence) then
		local delta = (sequence - s.sequence) % T.SHARED.SEQUENCE_MODULUS
		if delta >= T.SHARED.SEQUENCE_HALF or (delta == 0 and data.Teleported ~= true) then return end
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
	local speed = tonumber(data.Speed); local partner = s.active and s.partner or s.manualPartner
	if
		(s.active or utils.isManualSpamActive())
		and partner
		and target
		and target ~= localPlayer.UserId
		and target ~= partner
		and finite(speed)
		and speed > 0
	then
		local g = gameInfo.getDeflectGeometry(speed, nil, 1, true); local distance = distanceToPlayer(s, target)
		if g and distance and distance > g.fullRadius then stop(s, "distant_target", true); utils.setManualSpamActive(false) end
	end
	local snapshot = gameInfo.getSnapshotAt(time)
	if snapshot and data.Source == "packet" and userId(target) then
		snapshot = table.clone(snapshot)
		snapshot.targetId, snapshot.targeted = target, target == localPlayer.UserId
		snapshot.syncAt, snapshot.serverTime, snapshot.syncSequence = time, serverTime, sequence
		snapshot.teleported = false
		if finite(speed) and speed > 0 then snapshot.syncSpeed = speed end
	end
	if snapshot and userId(target) then inspectTarget(s, target, time, snapshot, serverTime) end
	evaluate(s, time, true, serverTime, snapshot)
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
