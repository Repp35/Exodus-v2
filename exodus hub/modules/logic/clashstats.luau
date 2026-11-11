-- [[ clash stats ]]

local ClashStats = {}

-- dependencies
local utils, gameInfo, players, localPlayer
local CONFIG = {
	CLASH_RETENTION_SECONDS = 1.5,
	PACKET_FALLBACK_SECONDS = 0.5,
	CPS_SAMPLE_CAP = 35,
	CPS_SMOOTHING_FACTOR = 0.2,
}

-- state
local stats

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function userId(value)
	if type(value) == "string" then value = tonumber(value) end
	return finite(value) and value > 0 and value % 1 == 0 and value or nil
end
local function snapshotSpeed(snapshot)
	if not snapshot then return nil end
	local speed = tonumber(snapshot.syncSpeed); return finite(speed) and speed > 0 and speed or snapshot.speed
end
local function formatPoint(point)
	if typeof(point) ~= "Vector3" then return "unavailable" end
	return string.format("%.2f, %.2f, %.2f", point.X, point.Y, point.Z)
end
local function formatSample(title, sample)
	if not sample then return title .. ": unavailable\n" end
	return string.format(
		"%s\nMy position: %s\nOpponent position: %s\nBall position: %s\nDistance: %s studs\nSpeed: %s\n",
		title,
		formatPoint(sample.own),
		formatPoint(sample.opponent),
		formatPoint(sample.ball),
		sample.distance and string.format("%.2f", sample.distance) or "?",
		sample.speed and string.format("%.2f", sample.speed) or "?"
	)
end

-- lifecycle
function ClashStats.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes" end
	ClashStats.teardown(); utils, gameInfo = deps.Utils, deps.GameInfo; players, localPlayer = utils.getPlayers(), utils.getLocalPlayer()
	if not players or not localPlayer then return false, "serviços indisponíveis" end
	stats = nil; return true
end
function ClashStats.teardown()
	stats = nil; utils, gameInfo, players, localPlayer = nil, nil, nil, nil
end

-- recording
function ClashStats.finish(reason, time)
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
				"Opponent: %s\nWinner: %s\nDuration: %.3f s\nAverage CPS: %.2f\nTarget time until death: %s\nPrevious target: %s\n\n%s\n%s",
				opponent and opponent.Name or tostring(stats.partnerId),
				reason == "jogador morreu" and (opponent and opponent.Name or tostring(stats.partnerId)) or localPlayer.Name,
				stats.duration,
				stats.cps,
				stats.fatalTravelTime and string.format("%.3f s (%.0f ms)", stats.fatalTravelTime, stats.fatalTravelTime * 1000) or "unavailable",
				stats.penultimateTravelTime
						and string.format(
							"%s — %.3f s (%.0f ms)",
							stats.penultimateTarget == localPlayer.UserId and localPlayer.Name or (opponent and opponent.Name or tostring(stats.partnerId)),
							stats.penultimateTravelTime,
							stats.penultimateTravelTime * 1000
						)
					or "unavailable",
				formatSample("START", stats.startSample),
				formatSample("FIM", stats.endSample)
			)
		)
	end)
	if not ok then utils.recordError("ClashLog", tostring(result)) end
end
function ClashStats.begin(partner, time)
	if stats and not stats.frozen then ClashStats.finish("novo clash", stats.lastObserved) end
	stats = stats or {}; table.clear(stats)
	stats.partnerId, stats.cps, stats.lastObserved = partner, 0, time
	stats.startedAt, stats.startedDate = time, os.date("!%Y-%m-%d %H:%M:%S")
	stats.totalSwitches, stats.frozen = 0, false
end
function ClashStats.observe(session, snapshot, time, fresh)
	local partner = session.active and session.partner
	if not partner then local context = gameInfo.getClashContext(); partner = context and context.partnerId end
	local target = userId(snapshot.targetId)
	if
		not partner
		and stats
		and not stats.frozen
		and time - (stats.lastSwitchAt or stats.startedAt) <= CONFIG.CLASH_RETENTION_SECONDS
		and (target == localPlayer.UserId or target == stats.partnerId)
	then
		partner = stats.partnerId
	end
	if not partner then
		if stats and stats.frozen then stats.waitingForClash = true end
		return
	end
	if stats and stats.frozen then
		if not stats.waitingForClash then return end
		ClashStats.begin(partner, time)
	elseif not stats or stats.partnerId ~= partner or time - stats.lastObserved > CONFIG.CLASH_RETENTION_SECONDS then
		ClashStats.begin(partner, time)
	end
	local observeTarget = fresh or not stats.lastPacketAt or time - stats.lastPacketAt > CONFIG.PACKET_FALLBACK_SECONDS
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
			if stats.cycleArmed then
				stats.totalSwitches += 1
				if stats.lastCycleAt and time > stats.lastCycleAt then stats.cycleInterval = time - stats.lastCycleAt; local sample = math.min(CONFIG.CPS_SAMPLE_CAP, 1 / stats.cycleInterval); stats.currentCps = stats.currentCps and (stats.currentCps + CONFIG.CPS_SMOOTHING_FACTOR * (sample - stats.currentCps)) or sample end
				stats.lastCycleAt = time
			end
			stats.cycleArmed = false; stats.lastSwitchAt = time
		elseif target ~= me and target ~= partner then
			stats.cycleArmed, stats.lastCycleAt, stats.cycleInterval, stats.currentCps = false, nil, nil, nil
		end
		stats.lastTarget = target
	end
	local duration = time - stats.startedAt; stats.cps = duration > 0 and stats.totalSwitches / duration or 0; local speed = snapshotSpeed(snapshot)
	if finite(speed) and speed >= 0 then stats.speed = speed end
	local other = gameInfo.getPlayerMotion(partner); local own = session.root.Position; local distance = typeof(other) == "Vector3" and (other - own).Magnitude or nil
	if finite(distance) then stats.distance = distance end
	stats.lastObserved = time; local sample = stats.endSample or {}
	sample.time, sample.distance, sample.speed, sample.cps = math.max(0, time - stats.startedAt), distance, stats.speed, stats.cps
	sample.own, sample.opponent, sample.ball = own, other, snapshot.position
	if not stats.startSample then stats.startSample = table.clone(sample) end
	stats.endSample = sample
end
function ClashStats.freeze(playerId, session)
	if not stats or stats.frozen or (playerId ~= localPlayer.UserId and playerId ~= stats.partnerId) then return end
	local time = utils.now()
	if stats.travelTarget == playerId and stats.travelStartedAt then
		stats.fatalTravelTime = math.max(0, time - stats.travelStartedAt)
		stats.penultimateTravelTime, stats.penultimateTarget = stats.lastTravelTime, stats.lastTravelTarget
	end
	stats.deceasedId = playerId; local sample = stats.endSample
	if sample and session and session.root and session.root.Parent then
		local other = gameInfo.getPlayerMotion(stats.partnerId)
		sample.own, sample.opponent = session.root.Position, other
		if typeof(other) == "Vector3" then sample.distance = (other - sample.own).Magnitude end
	end
	ClashStats.finish(playerId == localPlayer.UserId and "jogador morreu" or "oponente morreu", time)
end
function ClashStats.get() return stats end

-- contract
ClashStats.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = {
		Utils = { "getLocalPlayer", "getPlayers", "createClashLog", "appendClashLog", "recordError", "now" },
		GameInfo = { "getClashContext", "getPlayerMotion" },
	},

	provides = { "setup", "teardown", "begin", "finish", "observe", "freeze", "get" },
}

return ClashStats
