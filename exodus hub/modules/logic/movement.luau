-- [[ movement ]]

local Movement = {}

-- dependencies
local utils, gameInfo, remote

-- state
local jumpConnection, jumpCharacter, jumpHumanoid
local epoch = 0
local cameraEpoch = 0
local cameraInput, cameraOriginal, cameraWrapped

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
local function stopCamera()
	cameraEpoch += 1
	if cameraInput and cameraInput.getRotation == cameraWrapped then cameraInput.getRotation = cameraOriginal end
	cameraInput, cameraOriginal, cameraWrapped = nil, nil, nil
end
local function startCamera()
	stopCamera(); local token = cameraEpoch
	task.spawn(function()
		while token == cameraEpoch and utils and utils.isActive() do
			local player = utils.getLocalPlayer(); local scripts = player and player:FindFirstChild("PlayerScripts"); local module = scripts and scripts:FindFirstChild("PlayerModule"); local camera = module and module:FindFirstChild("CameraModule"); local input = camera and camera:FindFirstChild("CameraInput")
			if input and input:IsA("ModuleScript") then
				local api = require(input)
				if token ~= cameraEpoch or not utils then return end
				if type(api) ~= "table" or type(api.getRotation) ~= "function" then error("CameraInput.getRotation indisponível") end
				cameraInput, cameraOriginal = api, api.getRotation; local original, boundUtils = cameraOriginal, utils
				local wrapped
				wrapped = function(...)
					local rotation = original(...)
					if not boundUtils.isActive() then
						if api.getRotation == wrapped then api.getRotation = original end
						return rotation
					end
					local factor = tonumber(boundUtils.getConfigValue("CameraSensitivity")); return rotation * (factor or 1)
				end
				cameraWrapped = wrapped; cameraInput.getRotation = cameraWrapped; return
			end
			task.wait(0.5)
		end
	end)
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
	if not gameInfo.areAbilitiesEnabled() then return false, "Habilidades indisponíveis nesta partida" end
	local ability = gameInfo.getDashAbility()
	if not ability then return false, "Dash não está equipada ou ainda não carregou" end
	if ability.Dashing then return false, "Dash já está em andamento" end
	local moveDir = ability.MoveDir; local vectorValue = typeof(moveDir) == "Instance" and moveDir:IsA("Vector3Value"); local ok, err = remote.fireDash()
	if not ok then return false, tostring(err) end
	if not ability.Dashing then return false, "Dash indisponível ou em cooldown" end
	if vectorValue then moveDir.Value = Vector3.new(0, 1, 0) else ability.MoveDir = Vector3.new(0, 1, 0) end
	return true
end
function Movement.dashToward(direction)
	if not utils or not gameInfo or not remote or not utils.isActive() then return false, "Hub inativo" end
	if not gameInfo.areAbilitiesEnabled() then return false, "Habilidades indisponíveis" end
	if typeof(direction) ~= "Vector3" or direction.Magnitude <= 0.001 then return false, "Direção indisponível" end
	local ability = gameInfo.getDashAbility()
	if not ability or ability.Dashing then return false, "Dash indisponível" end
	local moveDir = ability.MoveDir; local vectorValue = typeof(moveDir) == "Instance" and moveDir:IsA("Vector3Value")
	if not vectorValue and typeof(moveDir) ~= "Vector3" then return false, "Direção do dash indisponível" end
	local ok, err = remote.fireDash()
	if not ok then return false, tostring(err) end
	if not ability.Dashing then return false, "Dash indisponível ou em cooldown" end
	if vectorValue then moveDir.Value = direction.Unit else ability.MoveDir = direction.Unit end
	return true
end

-- lifecycle
function Movement.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.Remote) ~= "table" then return false, "dependências ausentes: Utils, GameInfo ou Remote" end
	Movement.teardown(); utils, gameInfo, remote = deps.Utils, deps.GameInfo, deps.Remote; startCamera(); return Movement.syncJump()
end
function Movement.teardown()
	stopJump(); stopCamera(); utils, gameInfo, remote = nil, nil, nil
end

-- contract
Movement.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Remote = "remote" },
	requiresMethods = {
		Utils = { "getConfigValue", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive" },
		GameInfo = { "getDashAbility", "areAbilitiesEnabled" },
		Remote = { "fireDash" },
	},

	provides = { "setup", "syncJump", "upDash", "dashToward", "teardown" },
}

return Movement
