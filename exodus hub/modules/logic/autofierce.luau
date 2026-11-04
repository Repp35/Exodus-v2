-- [[ autofierce ]]

local AutoFierce = {}
local Utils, GameInfo, AutoParry, AutoClash, Spam
local generation = 0
local connection
local lastActivationAt = -math.huge

-- Upper bound in the dump: 850 ms, plus up to 150 ms and 120 ms bonuses.
local FIERCE_DURATION = 5
local RADIUS_MULTIPLIER = 3
local CRITICAL_RATIO = 0.30
local ARM_RATIO = 0.70
local WINDOW_MARGIN = 0.055
local tracking = { ball = nil, target = nil, cooldownAt = nil, outside = false }

local function disconnect()
	if not connection then return end
	if Utils and type(Utils.untrackCharacter) == "function" then Utils.untrackCharacter(connection) end
	connection:Disconnect()
	connection = nil
end

local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end

local function resetTracking()
	tracking.ball = nil; tracking.target = nil
	tracking.cooldownAt = nil; tracking.outside = false
end

local function evaluate(root, time)
	if not Utils.isActive() or Utils.getConfigValue("AutoFierceDeflect") ~= true then return nil end
	local cooldown = GameInfo.getDeflectCooldownState()
	if not cooldown or not cooldown.known or cooldown.rawActive ~= true or cooldown.normalizing == true or not finite(cooldown.endsAt) or not finite(cooldown.lastEventAt) then
		resetTracking(); return nil
	end
	local sync = GameInfo.getSyncData()
	if type(sync) == "table" and sync.Teleported == true then resetTracking(); return nil end
	local snapshot = GameInfo.getSnapshot(nil, time)
	if not GameInfo.isSnapshotValid(snapshot) or snapshot.teleported == true then resetTracking(); return nil end
	local player = Utils.getLocalPlayer()
	if not player or snapshot.targetId ~= player.UserId or snapshot.targeted ~= true then resetTracking(); return nil end
	local latestSequence = GameInfo.getSyncSequence()
	if type(latestSequence) == "number" and snapshot.syncSequence ~= latestSequence then resetTracking(); return nil end
	local rootPosition = GameInfo.getRootPosition(root)
	if typeof(rootPosition) ~= "Vector3" then return nil end
	local timing = AutoParry.getTiming(snapshot, time, rootPosition, 1)
	if not timing or not timing.approaching or not finite(timing.distance) or not finite(timing.speed) then resetTracking(); return nil end
	local minimum = GameInfo.getBallSpeedLimits()
	if not finite(minimum) or timing.speed < minimum * 0.375 then return nil end
	if timing.distance > timing.parryRadius * RADIUS_MULTIPLIER or timing.distance <= 0 then return nil end
	local radius = AutoParry.getTiming(snapshot, time, rootPosition, Utils.getConfigValue("AutoParryWindowFactor") or 0.5)
	if not radius or not finite(radius.parryRadius) or radius.parryRadius <= 0 then return nil end
	if tracking.ball ~= snapshot.ball or tracking.target ~= snapshot.targetId or tracking.cooldownAt ~= cooldown.lastEventAt then
		resetTracking()
		tracking.ball = snapshot.ball; tracking.target = snapshot.targetId; tracking.cooldownAt = cooldown.lastEventAt
	end
	if timing.distance > radius.parryRadius * ARM_RATIO then tracking.outside = true end
	local critical = tracking.outside and timing.distance <= radius.parryRadius * CRITICAL_RATIO
	local velocity = snapshot.velocity
	if typeof(velocity) ~= "Vector3" then return nil end
	local closing = velocity:Dot(rootPosition - snapshot.position) / timing.distance
	if not finite(closing) or closing <= 0 then return nil end
	local impact = math.max(0, timing.distance - timing.noWindowParryRadius) / closing
	local ping = GameInfo.getLocalPing()
	if not finite(ping) or ping < 0 then return nil end
	local impactAt = time + impact
	-- The duration is received after the server starts it; account for transit.
	local earliestCooldownEnd = cooldown.endsAt - ping - 0.05
	if time >= cooldown.endsAt or earliestCooldownEnd <= time then return nil end
	if impactAt + 0.03 >= earliestCooldownEnd or impact + 2 * ping + 0.1 >= FIERCE_DURATION then return nil end
	local window = GameInfo.getDeflectWindow(timing.speed)
	if not finite(window) or window <= 0 then return nil end
	local elapsed = time - cooldown.lastEventAt
	local nearWindowEnd = elapsed >= math.max(0, window - WINDOW_MARGIN - ping)
	if not critical and not nearWindowEnd then return nil end
	local ability = GameInfo.getFierceDeflectAbility()
	if not ability or type(ability.IsAvailable) ~= "function" or not ability:IsAvailable(false) then return nil end
	if type(ability.IsOwnerAlive) ~= "function" or not ability:IsOwnerAlive() then return nil end
	return ability, ping
end

local function step(root, current)
	if current ~= generation or not root.Parent then return end
	local time = Utils.now()
	if time - lastActivationAt < 1 then return end
	local ability = evaluate(root, time)
	if not ability then return end
	-- Disarm both sources and invalidate any scheduled spam before activating.
	Utils.stopAllSpam()
	Spam.resetState()
	if not Utils.setConfig({ AutoClash = false }) then
		AutoClash.stopSpam()
		return
	end
	AutoClash.stopSpam()
	if Utils.isSpamActive() then return end
	local checked = evaluate(root, Utils.now())
	if checked ~= ability then return end
	lastActivationAt = Utils.now()
	resetTracking()
	local ok, sent, detail = pcall(GameInfo.activateFierceDeflect, ability)
	if not ok or not sent then Utils.recordError("AutoFierce", tostring(ok and detail or sent)) end
end

function AutoFierce.setup(deps)
	Utils, GameInfo, AutoParry, AutoClash, Spam = deps.Utils, deps.GameInfo, deps.AutoParry, deps.AutoClash, deps.Spam
	return true
end
function AutoFierce.bindCharacter(character)
	generation += 1
	disconnect()
	local current = generation
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root.Parent then return false, "HumanoidRootPart indisponível" end
	local runService = Utils.getRunService()
	local signal = runService and (runService.PostSimulation or runService.Heartbeat)
	if not signal then return false, "RunService indisponível" end
	connection = signal:Connect(function()
		if character.Parent then step(root, current) end
	end)
	Utils.trackCharacter(connection)
	lastActivationAt = -math.huge
	resetTracking()
	return true
end
function AutoFierce.detachCharacter()
	generation += 1
	disconnect()
	resetTracking()
end
function AutoFierce.teardown()
	AutoFierce.detachCharacter()
	Utils, GameInfo, AutoParry, AutoClash, Spam = nil, nil, nil, nil, nil
end
AutoFierce.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", AutoParry = "autoparry", AutoClash = "autoclash", Spam = "spam" },
	requiresMethods = {
		Utils = {
			"isActive",
			"getConfigValue",
			"getLocalPlayer",
			"getRunService",
			"now",
			"setConfig",
			"stopAllSpam",
			"isSpamActive",
			"recordError",
			"trackCharacter",
			"untrackCharacter",
		},
		GameInfo = {
			"getDeflectCooldownState",
			"getSyncData",
			"getSnapshot",
			"isSnapshotValid",
			"getSyncSequence",
			"getRootPosition",
			"getBallSpeedLimits",
			"getDeflectWindow",
			"getLocalPing",
			"getFierceDeflectAbility",
			"activateFierceDeflect",
		},
		AutoParry = { "getTiming" },
		AutoClash = { "stopSpam" },
		Spam = { "resetState" },
	},
	provides = { "setup", "bindCharacter", "detachCharacter", "teardown" },
	bindCharacter = true,
}
return AutoFierce
