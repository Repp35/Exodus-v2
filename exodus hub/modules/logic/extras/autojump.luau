-- [[ auto jump ]]

-- state
local AutoJump = {}
local utils
local jumpConnection, jumpCharacter, jumpHumanoid
local epoch = 0
local CONFIG = {
	AIR_MATERIAL = Enum.Material.Air,
	JUMPING_STATE = Enum.HumanoidStateType.Jumping,
}

-- helpers
local function stopJump()
	epoch += 1; local connection = jumpConnection; jumpConnection, jumpCharacter, jumpHumanoid = nil, nil, nil
	if not connection then return end
	if utils then utils.untrackGlobal(connection) end
	connection:Disconnect()
end
local function jumpStep(player)
	local character = player.Character
	if character ~= jumpCharacter then jumpCharacter, jumpHumanoid = character, nil end
	if not character or not character.Parent then return end
	local humanoid = jumpHumanoid
	if not humanoid or humanoid.Parent ~= character then humanoid = character:FindFirstChildOfClass("Humanoid"); jumpHumanoid = humanoid end
	if not humanoid or humanoid.Health <= 0 or humanoid.FloorMaterial == CONFIG.AIR_MATERIAL then return end
	if humanoid:GetState() ~= CONFIG.JUMPING_STATE then humanoid:ChangeState(CONFIG.JUMPING_STATE) end
end

-- lifecycle
function AutoJump.sync()
	stopJump()
	if not utils or not utils.isActive() or utils.getConfigValue("AutoJump") ~= true then return true end
	local player, runService = utils.getLocalPlayer(), utils.getRunService()
	if not player or not runService or not runService.Heartbeat then return false, "Jogador ou Heartbeat indisponível" end
	local token = epoch
	jumpConnection = runService.Heartbeat:Connect(function()
		if token ~= epoch then return end
		if not utils.isActive() or utils.getConfigValue("AutoJump") ~= true then stopJump(); return end
		jumpStep(player)
	end)
	utils.trackGlobal(jumpConnection); return true
end
function AutoJump.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "Utils ausente" end
	AutoJump.teardown(); utils = deps.Utils; return AutoJump.sync()
end
function AutoJump.teardown()
	stopJump(); utils = nil
end

-- contract
AutoJump.__contract = {
	requires = { Utils = "utils" },
	requiresMethods = { Utils = { "getConfigValue", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive" } },
	provides = { "setup", "sync", "teardown" },
}

return AutoJump
