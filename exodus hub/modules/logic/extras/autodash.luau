-- [[ auto dash ]]

-- dependencies
local AutoDash = {}
local utils, gameInfo, dash, movement, autoSpam, players, localPlayer, runService
local root, heartbeat
local DASH_DETECTION_RANGE = 70

-- helpers
local function onDash(event)
	if not root or not root.Parent or not utils.isActive() or utils.getConfigValue("AutoClashUpDash") ~= true
		or not gameInfo.areAbilitiesEnabled() or not event or event.userId == localPlayer.UserId or not event.velocity then return end
	if typeof(event.position) ~= "Vector3" or (event.position - root.Position).Magnitude > DASH_DETECTION_RANGE then return end
	local active = autoSpam.getActivationContext()
	local partner = active.active and active.partner or (gameInfo.getClashContext() or {}).partnerId
	-- A nearby player holding the ball may become the clash partner on the next return.
	if partner ~= event.userId and gameInfo.getTargetId() ~= event.userId then return end
	local character = event.player and event.player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end
	local velocity = event.velocity
	local horizontalSpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
	if velocity.Y >= 72 and horizontalSpeed <= velocity.Y * 0.5 then movement.upDash() end
end

-- lifecycle
function AutoDash.setup(deps)
	if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.Dash or not deps.Movement or not deps.AutoSpam then return false, "dependências ausentes" end
	AutoDash.teardown()
	utils, gameInfo, dash, movement, autoSpam = deps.Utils, deps.GameInfo, deps.Dash, deps.Movement, deps.AutoSpam
	players, localPlayer, runService = utils.getPlayers(), utils.getLocalPlayer(), utils.getRunService()
	if not players or not localPlayer or not runService then return false, "serviços indisponíveis" end
	dash.setHandler(onDash)
	return true
end

function AutoDash.bindCharacter(character)
	AutoDash.detachCharacter()
	local newRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not newRoot or not newRoot:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
	root = newRoot
	heartbeat = runService.Heartbeat:Connect(function()
		if not root or not root.Parent then return end
		if not utils.isActive() or utils.getConfigValue("AutoClashUpDash") ~= true or not gameInfo.areAbilitiesEnabled() then return end
		-- Track nearby players even before the first exchange; distant animations are expensive.
		dash.tick(utils.now(), true, root.Position, DASH_DETECTION_RANGE)
	end)
	utils.trackCharacter(heartbeat)
	return true
end
function AutoDash.detachCharacter()
	root = nil
	if heartbeat then utils.untrackCharacter(heartbeat); heartbeat:Disconnect(); heartbeat = nil end
end
function AutoDash.teardown()
	AutoDash.detachCharacter()
	if dash then dash.setHandler(nil) end
	utils, gameInfo, dash, movement, autoSpam, players, localPlayer, runService = nil, nil, nil, nil, nil, nil, nil, nil
end
-- contract
AutoDash.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Dash = "dash", Movement = "movement", AutoSpam = "autospam" },
	requiresMethods = {
		Utils = { "getPlayers", "getLocalPlayer", "getRunService", "getConfigValue", "isActive", "now", "trackCharacter", "untrackCharacter" },
		GameInfo = { "areAbilitiesEnabled", "getClashContext", "getTargetId" },
		Dash = { "setHandler", "tick" }, Movement = { "upDash", "dashToward" },
		AutoSpam = { "getActivationContext" },
	},
	provides = { "setup", "bindCharacter", "detachCharacter", "teardown" },
	bindCharacter = true,
}
return AutoDash
