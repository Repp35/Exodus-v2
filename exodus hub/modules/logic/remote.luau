-- [[ remote ]]

-- dependencies
local Remote = {}
local utils, gameInfo

-- deflect
function Remote.setup(deps)
	if type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.GameInfo) ~= "table"
		or type(deps.GameInfo.getDeflectAbility) ~= "function" then
		return false, "dependência ausente: Utils ou GameInfo.getDeflectAbility"
	end
	utils, gameInfo = deps.Utils, deps.GameInfo
	return true
end

function Remote.fireParry(_flag, guard)
	local ability = gameInfo and gameInfo.getDeflectAbility()
	if not ability then return false, "Deflect indisponível" end
	if utils and not utils.isActive() then return false, "Hub inativo" end
	if type(guard) == "function" and not guard() then return false, "Deflect cancelado" end
	local result = ability:Deflect()
	return result ~= false
end

-- contract
Remote.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = {
		Utils = { "isActive" },
		GameInfo = { "getDeflectAbility" },
	},
	provides = { "setup", "fireParry" },
}

return Remote
