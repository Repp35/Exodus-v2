-- [[ autoclash ]]

local AutoClash = {}
local Utils, GameInfo, AutoParry, Dash
local state = {
	active = false, bound = false, generation = 0, root = nil, connection = nil,
	target = -1, previous = -1, partner = -1, switchAt = 0,
	intervalMs = 0, resetToken = 0, lostAt = 0, releaseAt = nil,
	lastGate = "detached", activationAt = 0, activationReason = "none",
	lastSpeed = 0, lastRadius = 0, dashData = nil,
}

local ACTIVATE_TTI = 0.18
local RETURN_WINDOW = 0.35
local RELEASE_HOLD = 0.10

local function now() return Utils.now() end
local function targetId(value)
	local id = tonumber(value)
	if id and id > 0 and id % 1 == 0 then return id end
	return -1
end
local function myId()
	local player = Utils.getLocalPlayer()
	return player and player.UserId or -1
end
local function enabled()
	return Utils.isActive() and Utils.getConfigValue("AutoClash") == true
end
local function setActive(value, reason)
	if state.active == value then return end
	local old = state.active
	state.active = value
	state.releaseAt = nil
	state.lastGate = reason
	if value then
		state.activationAt = now()
		state.activationReason = reason
	end
	Utils.setAutoSpamActive(value)
	Utils.recordTransition("AutoClash", old and "active" or "idle", value and "active" or "idle", reason)
end
local function reset(reason)
	state.generation += 1
	if state.connection then
		if Utils and Utils.untrackCharacter then Utils.untrackCharacter(state.connection) end
		state.connection:Disconnect()
		state.connection = nil
	end
	if Utils then setActive(false, reason) end
	state.bound, state.root = false, nil
	state.target, state.previous, state.partner = -1, -1, -1
	state.switchAt, state.intervalMs, state.lostAt = 0, 0, 0
	state.releaseAt, state.dashData = nil, nil
	state.resetToken += 1
	state.lastGate = reason
end
local function snapshot(t)
	local s = GameInfo.getSnapshotAt and GameInfo.getSnapshotAt(t) or GameInfo.getSnapshot(nil, t)
	if not s or not GameInfo.isSnapshotValid(s, t) or not s.ball or not s.ball.Parent then return nil end
	return s
end
local function recordTarget(id, t)
	if id == -1 or id == state.target then return end
	local old = state.target
	state.previous = old
	state.target = id
	if old > 0 then
		if state.switchAt > 0 then state.intervalMs = (t - state.switchAt) * 1000 end
		state.switchAt = t
		if old == myId() then
			state.lostAt = t
			state.partner = id
		elseif id == myId() then
			state.partner = old
		end
	end
end
local function approaching(s)
	local root = state.root
	if not root or not root.Parent or typeof(s.position) ~= "Vector3" or typeof(s.velocity) ~= "Vector3" then return false, math.huge end
	local offset = root.Position - s.position
	local distance = offset.Magnitude
	local speed = s.velocity.Magnitude
	if distance < 0.001 or speed < 1 then return false, math.huge end
	local closing = s.velocity:Dot(offset) / distance
	if closing <= 0 then return false, math.huge end
	local radiusData = AutoParry.getRadius("geometry", 0, s.speed, "game")
	local hitRadius = type(radiusData) == "table" and tonumber(radiusData.noWindowParryRadius) or 0
	local window = type(radiusData) == "table" and tonumber(radiusData.deflectWindow) or 0
	if not hitRadius or hitRadius < 0 or not window or window <= 0 then return false, math.huge end
	state.lastRadius = hitRadius
	return true, math.max(0, distance - hitRadius) / closing, window
end
local function evaluate(t, s)
	if not enabled() then
		setActive(false, "disabled")
		return
	end
	if Utils.isManualSpamActive() then
		setActive(false, "manual_spam")
		return
	end
	if not s or s.teleported then
		if state.active then
			state.releaseAt = state.releaseAt or t
			if t - state.releaseAt >= RELEASE_HOLD then setActive(false, "ball_unavailable") end
		end
		return
	end
	state.lastSpeed = s.speed or 0
	local id = targetId(s.targetId)
	if id > 0 then recordTarget(id, t) end
	local mine = myId()
	local isMine = id == mine or (id == -1 and s.targeted == true)
	local converging, tti, window = approaching(s)
	local imminent = converging and tti <= math.min(ACTIVATE_TTI, window + 0.03)
	local returning = state.partner > 0 and state.previous == state.partner and t - state.lostAt <= RETURN_WINDOW
	if not state.active then
		if isMine and imminent and (returning or state.previous == -1 or t - state.switchAt <= RETURN_WINDOW) then
			setActive(true, "target_impact")
		else
			state.lastGate = not isMine and "not_target" or not converging and "not_approaching" or "outside_window"
		end
		return
	end
	-- Keep spam running through fast target exchanges. Release only after a stable exit.
	local shouldRelease = not isMine and (not converging or tti > window + RELEASE_HOLD)
	if shouldRelease then
		state.releaseAt = state.releaseAt or t
		if t - state.releaseAt >= RELEASE_HOLD then setActive(false, "clash_ended") end
	else
		state.releaseAt = nil
	end
end

function AutoClash.onBallSync(data)
	if type(data) ~= "table" or not Utils or not state.bound then return end
	if data.Teleported == true then
		setActive(false, "teleported")
		state.target, state.previous, state.partner = -1, -1, -1
		state.resetToken += 1
		return true
	end
	local id = targetId(data.TargetPlayerID or data.HighlightTargetPlayerID)
	if id > 0 then recordTarget(id, now()) end
	if data.Source == "packet" then evaluate(now(), snapshot(now())) end
	return true
end
function AutoClash.setup(deps)
	if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.AutoParry then return false, "dependencias ausentes" end
	if Utils then reset("setup") end
	Utils, GameInfo, AutoParry, Dash = deps.Utils, deps.GameInfo, deps.AutoParry, deps.Dash
	if not Utils.getLocalPlayer() or not Utils.getRunService() then return false, "jogador ou RunService ausente" end
	state.lastGate = "ready"
	return true
end
function AutoClash.bindCharacter(character)
	reset("rebind")
	if not character or not character.Parent then return false end
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
	if not root then return false end
	state.root, state.bound = root, true
	local generation = state.generation
	state.connection = Utils.getRunService().Heartbeat:Connect(function()
		if generation ~= state.generation or not root.Parent then return end
		local t = now()
		evaluate(t, snapshot(t))
	end)
	if Utils.trackCharacter then Utils.trackCharacter(state.connection) end
	return true
end
function AutoClash.detachCharacter() if Utils then reset("detach") end end
function AutoClash.teardown()
	if Utils then reset("teardown") end
	Utils, GameInfo, AutoParry, Dash = nil, nil, nil, nil
end
function AutoClash.isActive() return state.active end
function AutoClash.stopSpam() if Utils then setActive(false, "stop_spam") end end
function AutoClash.getPullEvent() return nil end
function AutoClash.getDashData() return state.dashData end
function AutoClash.getTargetSwitch()
	return { timestampMs = state.switchAt * 1000, intervalMs = state.intervalMs, partnerId = state.partner, resetToken = state.resetToken }
end
function AutoClash.getActivationContext()
	return { active = state.active, source = "prediction", reason = state.activationReason, trigger = state.activationReason,
		timestamp = state.activationAt, target = state.target, partner = state.partner,
		distance = 0, parryRadius = state.lastRadius, speed = state.lastSpeed }
end
function AutoClash.getStatus()
	return { schema = Utils and Utils.apiVersion() or 1, phase = not state.bound and "detached" or state.active and "active" or "idle",
		bound = state.bound, active = state.active, lastGate = state.lastGate,
		lastTarget = state.target, clashPartnerId = state.partner, parryRadius = state.lastRadius,
		activationAt = state.activationAt, activationReason = state.activationReason,
		activationTarget = state.target, activationPartner = state.partner,
		deactivationCandidateAt = state.releaseAt or 0 }
end
AutoClash.__contract = {
	requiresMethods = {
		AutoParry = { "getRadius", "getStatus" },
		Dash = { "setHandler", "tick" },
		GameInfo = { "getSnapshot", "isSnapshotValid" },
		Utils = { "now", "getConfig", "getRunService", "getPlayers", "recordTransition",
			"setAutoSpamActive", "trackCharacter", "untrackCharacter", "isActive",
			"isManualSpamActive", "getLocalPlayer", "apiVersion" },
	},
	provides = { "setup", "bindCharacter", "detachCharacter", "onBallSync", "getStatus",
		"getTargetSwitch", "getDashData", "getPullEvent", "stopSpam" },
	requires = { AutoParry = "autoparry", Dash = "dash", GameInfo = "gameinfo", Utils = "utils" },
	onBallSync = true, bindCharacter = true, minAutoParryVersion = 10,
	requiresVersions = { AutoParry = 10 },
}
return AutoClash
