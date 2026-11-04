-- [[ autofierce ]]

local AutoFierce = {}

local Utils, GameInfo, AutoParry, AutoClash, Spam
local generation = 0
local connection
local boundRoot
local lastActivationAt = -math.huge
local function disconnect()
	if not connection then return end
	if Utils and type(Utils.untrackCharacter) == "function" then Utils.untrackCharacter(connection) end
	connection:Disconnect(); connection = nil
end
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function evaluate(root, time)
	if not Utils.isActive() or Utils.getConfigValue("AutoFierceDeflect") ~= true then return nil end
	local cooldown = GameInfo.getDeflectCooldownState()
	if not cooldown or (not cooldown.active and not cooldown.blocking) then return nil end
	local uiRemaining = GameInfo.getDeflectUICooldown()
	if not finite(uiRemaining) or uiRemaining <= 0 then return nil end
	local sync = GameInfo.getSyncData()
	if type(sync) == "table" and sync.Teleported == true then return nil end
	local snapshot = GameInfo.getSnapshot(nil, time)
	if not GameInfo.isSnapshotValid(snapshot) or snapshot.teleported == true then return nil end
	local player = Utils.getLocalPlayer()
	if not player or not snapshot.targeted or snapshot.targetId ~= player.UserId then return nil end
	local sequence = GameInfo.getSyncSequence()
	if type(sequence) == "number" and snapshot.syncSequence ~= sequence then return nil end
	local rootPosition = GameInfo.getRootPosition(root)
	if typeof(rootPosition) ~= "Vector3" then return nil end
	local timing = AutoParry.getTiming(snapshot, time, rootPosition)
	if not timing or not timing.approaching or not finite(timing.distance) or not finite(timing.speed) then return nil end
	if not finite(timing.parryRadius) or timing.parryRadius <= 0 or timing.distance <= 0 then return nil end
	if timing.distance > timing.parryRadius then return nil end
	local minimum = GameInfo.getBallSpeedLimits()
	if not finite(minimum) or timing.speed < minimum * 0.375 then return nil end
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
	Utils.stopAllSpam(); Spam.resetState()
	AutoClash.stopSpam()
	if Utils.isSpamActive() then return end
	local checked = evaluate(root, Utils.now())
	if checked ~= ability then return end
	lastActivationAt = Utils.now(); local ok, sent, detail = pcall(GameInfo.activateFierceDeflect, ability)
	if ok and sent then GameInfo.noteFierceDeflectActivation() else Utils.recordError("AutoFierce", tostring(ok and detail or sent)) end
end
function AutoFierce.setup(deps)
	Utils, GameInfo, AutoParry, AutoClash, Spam = deps.Utils, deps.GameInfo, deps.AutoParry, deps.AutoClash, deps.Spam; return true
end
function AutoFierce.bindCharacter(character)
	generation += 1; disconnect(); boundRoot = nil; local current = generation; local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root.Parent then return false, "HumanoidRootPart indisponível" end
	local runService = Utils.getRunService(); local signal = runService and (runService.PostSimulation or runService.Heartbeat)
	if not signal then return false, "RunService indisponível" end
	boundRoot = root; connection = signal:Connect(function()
		if character.Parent then step(root, current) end
	end)
	Utils.trackCharacter(connection); lastActivationAt = -math.huge; return true
end
function AutoFierce.detachCharacter()
	generation += 1; disconnect(); boundRoot = nil
end
function AutoFierce.onBallSync(data)
	if type(data) ~= "table" or data.Source ~= "packet" or data.Teleported == true or not boundRoot or not Utils then return end
	local player = Utils.getLocalPlayer()
	if player and tonumber(data.TargetPlayerID) == player.UserId then step(boundRoot, generation) end
end
function AutoFierce.teardown()
	AutoFierce.detachCharacter(); Utils, GameInfo, AutoParry, AutoClash, Spam = nil, nil, nil, nil, nil
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
			"stopAllSpam",
			"isSpamActive",
			"recordError",
			"trackCharacter",
			"untrackCharacter",
		},
		GameInfo = {
			"getDeflectCooldownState",
			"getDeflectUICooldown",
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
		AutoClash = { "stopSpam" },
		Spam = { "resetState" },
	},

	provides = { "setup", "bindCharacter", "detachCharacter", "teardown", "onBallSync" },
	bindCharacter = true,
	onBallSync = true,
}

return AutoFierce
