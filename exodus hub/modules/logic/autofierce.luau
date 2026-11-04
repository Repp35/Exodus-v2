-- [[ autofierce ]]

local AutoFierce = {}
local Utils, GameInfo, AutoParry, AutoClash, Spam
local generation = 0
local connection
local lastActivationAt = -math.huge

local FIERCE_DURATION = 5
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
	local attempt = cooldown and cooldown.attempt
	if not attempt or not cooldown.known or not cooldown.blocking then
		resetTracking(); return nil
	end

	local sync = GameInfo.getSyncData()
	if type(sync) == "table" and sync.Teleported == true then resetTracking(); return nil end
	local snapshot = GameInfo.getSnapshot(nil, time)
	if not GameInfo.isSnapshotValid(snapshot) or snapshot.teleported == true then resetTracking(); return nil end
	local player = Utils.getLocalPlayer()
	if not player or not snapshot.targeted or snapshot.targetId ~= player.UserId then resetTracking(); return nil end
	local sequence = GameInfo.getSyncSequence()
	if type(sequence) == "number" and snapshot.syncSequence ~= sequence then return nil end
	local rootPosition = GameInfo.getRootPosition(root)
	if typeof(rootPosition) ~= "Vector3" then return nil end

	local timing = AutoParry.getTiming(snapshot, time, rootPosition, 1, "game")
	if not timing or not timing.approaching or not finite(timing.distance) or not finite(timing.speed) then return nil end
	if not finite(timing.parryRadius) or timing.parryRadius <= 0 or timing.distance <= 0 then return nil end
	local minimum = GameInfo.getBallSpeedLimits()
	if not finite(minimum) or timing.speed < minimum * 0.375 then return nil end
	local miss = cooldown.active and attempt.expired == true
	if not miss then return nil end

	local pull = AutoClash.getPullEvent()
	local pulledOutside = pull and finite(pull.at) and time - pull.at >= 0 and time - pull.at <= 0.65
		and typeof(pull.position) == "Vector3"
		and (pull.position - rootPosition).Magnitude > timing.parryRadius
	if not pulledOutside and timing.distance > timing.parryRadius * 3 then return nil end

	local velocity = snapshot.velocity
	if typeof(velocity) ~= "Vector3" then return nil end
	local displacement = rootPosition - snapshot.position
	local rootVelocity = root.AssemblyLinearVelocity
	if typeof(rootVelocity) ~= "Vector3" then rootVelocity = Vector3.zero end
	local closing = (velocity - rootVelocity):Dot(displacement) / timing.distance
	if not finite(closing) or closing <= 0 then return nil end
	local impact = math.max(0, timing.distance - timing.noWindowParryRadius) / closing
	local ping = GameInfo.getLocalPing()
	if not finite(ping) or ping < 0 then return nil end
	if impact + 2 * ping + 0.1 >= FIERCE_DURATION then return nil end

	local ability = GameInfo.getFierceDeflectAbility()
	if not ability or type(ability.IsAvailable) ~= "function" or not ability:IsAvailable(false) then return nil end
	if type(ability.IsOwnerAlive) ~= "function" or not ability:IsOwnerAlive() then return nil end
	return ability
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
	if ok and sent then
		GameInfo.noteFierceDeflectActivation()
	else
		Utils.recordError("AutoFierce", tostring(ok and detail or sent))
	end
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
			"getLocalPing",
			"getFierceDeflectAbility",
			"activateFierceDeflect",
			"noteFierceDeflectActivation",
		},
		AutoParry = { "getTiming" },
		AutoClash = { "stopSpam", "getPullEvent" },
		Spam = { "resetState" },
	},
	provides = { "setup", "bindCharacter", "detachCharacter", "teardown" },
	bindCharacter = true,
}
return AutoFierce
