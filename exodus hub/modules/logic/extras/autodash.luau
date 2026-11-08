-- [[ auto dash ]]
local AutoDash = {}
local utils, gameInfo, dash, movement, autoSpam, players, localPlayer, runService
local root, heartbeat

local function playerIsAlive(id)
	local player = id and players:GetPlayerByUserId(id)
	local character = player and player.Character
	local humanoid = character and character.Parent and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function onDash(event)
	if not root or not root.Parent or not gameInfo.areAbilitiesEnabled() or not event or event.userId == localPlayer.UserId or not event.position or not event.velocity then return end
	local active = autoSpam.getActivationContext()
	local context = gameInfo.getClashContext()
	local partner = active.active and active.partner or (context and context.partnerId)
	local velocity = event.velocity
	if utils.isActive() and utils.getConfigValue("AutoClashUpDash") == true then
		local horizontalSpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
		if partner == event.userId and velocity.Y >= 72 and horizontalSpeed <= velocity.Y * 0.5 then movement.upDash() end
	end
	local offset = root.Position - event.position
	local distance, speed = offset.Magnitude, velocity.Magnitude
	if not utils.isActive() then return end
	if partner == event.userId and playerIsAlive(partner) and distance > 0 and speed > 0
		and -velocity:Dot(offset) / (speed * distance) >= 0.98 and velocity.Y / speed < 0.5 then
		movement.dashToward(-offset)
	end
end

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
		local autoEnabled = utils.getConfigValue("AutoSpam") == true
		local upDashEnabled = utils.getConfigValue("AutoClashUpDash") == true
		local context = gameInfo.getClashContext()
		if gameInfo.areAbilitiesEnabled() and (autoEnabled or upDashEnabled or context) then dash.tick(utils.now(), true) end
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
AutoDash.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Dash = "dash", Movement = "movement", AutoSpam = "autospam" },
	requiresMethods = {
		Utils = { "getPlayers", "getLocalPlayer", "getRunService", "getConfigValue", "isActive", "now", "trackCharacter", "untrackCharacter" },
		GameInfo = { "areAbilitiesEnabled", "getClashContext" },
		Dash = { "setHandler", "tick" }, Movement = { "upDash", "dashToward" },
		AutoSpam = { "getActivationContext" },
	},
	provides = { "setup", "bindCharacter", "detachCharacter", "teardown" },
	bindCharacter = true,
}
return AutoDash
