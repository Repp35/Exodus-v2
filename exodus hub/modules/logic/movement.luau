-- [[ movement ]]

local Movement = {}

-- dependencies
local utils, gameInfo, remote

-- state
local jumpConnection, jumpCharacter, jumpHumanoid
local epoch = 0

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
	if not humanoid or humanoid.Health <= 0 or humanoid.FloorMaterial == Enum.Material.Air then return end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Jumping then humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end
end

-- actions
function Movement.syncJump()
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
function Movement.upDash()
	if not utils or not gameInfo or not remote or not utils.isActive() then return false, "Hub inativo" end
	local ability = gameInfo.getDashAbility()
	if not ability then return false, "Dash não está equipada ou ainda não carregou" end
	if ability.Dashing then return false, "Dash já está em andamento" end
	local ok, err = remote.fireDash()
	if not ok then return false, tostring(err) end
	if not ability.Dashing then return false, "Dash indisponível ou em cooldown" end
	ability.MoveDir = Vector3.new(0, 1, 0); return true
end

-- lifecycle
function Movement.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.Remote) ~= "table" then return false, "dependências ausentes: Utils, GameInfo ou Remote" end
	Movement.teardown(); utils, gameInfo, remote = deps.Utils, deps.GameInfo, deps.Remote; return Movement.syncJump()
end
function Movement.teardown()
	stopJump(); utils, gameInfo, remote = nil, nil, nil
end

-- contract
Movement.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Remote = "remote" },
	requiresMethods = {
		Utils = { "getConfigValue", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive" },
		GameInfo = { "getDashAbility" },
		Remote = { "fireDash" },
	},

	provides = { "setup", "syncJump", "upDash", "teardown" },
}

return Movement
