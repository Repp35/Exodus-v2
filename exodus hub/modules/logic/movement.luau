-- [[ movement: dash actions ]]

local Movement = {}
local utils, gameInfo, remote

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


function Movement.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.Remote) ~= "table" then return false, "dependências ausentes: Utils, GameInfo ou Remote" end
	Movement.teardown(); utils, gameInfo, remote = deps.Utils, deps.GameInfo, deps.Remote; return true
end
function Movement.teardown() utils, gameInfo, remote = nil, nil, nil end

Movement.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Remote = "remote" },
	requiresMethods = {
		Utils = { "isActive" },
		GameInfo = { "getDashAbility", "areAbilitiesEnabled" },
		Remote = { "fireDash" },
	},
	provides = { "setup", "upDash", "dashToward", "teardown" },
}
return Movement
