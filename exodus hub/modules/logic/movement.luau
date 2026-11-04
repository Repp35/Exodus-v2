-- [[ movement ]]

local Movement = {}

local Utils, GameInfo
local jumpConnection
local generation = 0
local function disconnectJump()
	if not jumpConnection then return end
	if Utils then Utils.untrackGlobal(jumpConnection) end
	jumpConnection:Disconnect(); jumpConnection = nil
end
function Movement.syncJump()
	generation += 1; disconnectJump()
	if not Utils or Utils.getConfigValue("AutoJump") ~= true or not Utils.isActive() then return true end
	local player = Utils.getLocalPlayer(); local runService = Utils.getRunService()
	if not player or not runService or not runService.Heartbeat then return false, "Jogador ou Heartbeat indisponível" end
	local current = generation
	local character, humanoid
	jumpConnection = runService.Heartbeat:Connect(function()
		if current ~= generation or not Utils or not Utils.isActive() or Utils.getConfigValue("AutoJump") ~= true then return end
		if player.Character ~= character or (humanoid and humanoid.Parent ~= character) then character = player.Character; humanoid = nil end
		if not character or not character.Parent then return end
		if not humanoid then humanoid = character:FindFirstChildOfClass("Humanoid") end
		if humanoid and humanoid.Health > 0 and humanoid.FloorMaterial ~= Enum.Material.Air and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end)
	Utils.trackGlobal(jumpConnection); return true
end
function Movement.upDash()
	if not Utils or not GameInfo or not Utils.isActive() then return false, "Hub inativo" end
	local ability = GameInfo.getDashAbility()
	if not ability then return false, "Dash não está equipada ou ainda não carregou" end
	if ability.Dashing then return false, "Dash já está em andamento" end
	local ok, err = pcall(ability.Dash, ability)
	if not ok then return false, tostring(err) end
	if not ability.Dashing then return false, "Dash indisponível ou em cooldown" end
	ability.MoveDir = Vector3.new(0, 1, 0); return true
end
function Movement.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes: Utils ou GameInfo" end
	Utils, GameInfo = deps.Utils, deps.GameInfo; return Movement.syncJump()
end
function Movement.teardown()
	generation += 1; disconnectJump(); Utils, GameInfo = nil, nil
end
Movement.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = {
		Utils = { "getConfigValue", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive" },
		GameInfo = { "getDashAbility" },
	},

	provides = { "setup", "syncJump", "upDash", "teardown" },
}

return Movement
