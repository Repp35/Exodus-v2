-- [[ movement: dash actions ]]

local Movement = {}
local utils, gameInfo, remote

local UP = Vector3.new(0, 1, 0)
local function performDash(direction, upward)
	if not utils or not gameInfo or not remote or not utils.isActive() then return false, "Hub inativo" end
	if not gameInfo.areAbilitiesEnabled() then
		return false, upward and "Habilidades indisponíveis nesta partida" or "Habilidades indisponíveis"
	end
	if not upward and (typeof(direction) ~= "Vector3" or direction.Magnitude <= 0.001) then return false, "Direção indisponível" end
	local ability = gameInfo.getDashAbility()
	if not ability then return false, upward and "Dash não está equipada ou ainda não carregou" or "Dash indisponível" end
	if ability.Dashing then return false, upward and "Dash já está em andamento" or "Dash indisponível" end
	local moveDir = ability.MoveDir
	local vectorValue = typeof(moveDir) == "Instance" and moveDir:IsA("Vector3Value")
	if not upward and not vectorValue and typeof(moveDir) ~= "Vector3" then return false, "Direção do dash indisponível" end
	local ok, err = remote.fireDash()
	if not ok then return false, tostring(err) end
	if not ability.Dashing then return false, "Dash indisponível ou em cooldown" end
	local targetDirection = upward and UP or direction.Unit
	if vectorValue then moveDir.Value = targetDirection else ability.MoveDir = targetDirection end
	return true
end
function Movement.upDash() return performDash(UP, true) end
function Movement.dashToward(direction) return performDash(direction, false) end

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
