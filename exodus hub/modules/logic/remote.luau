-- [[ remote ]]

-- dependencies
local Remote = {}
local utils, gameInfo

-- lifecycle
function Remote.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then
		return false, "dependências inválidas: Utils ou GameInfo"
	end
	utils, gameInfo = deps.Utils, deps.GameInfo
	return true
end

-- dispatch
local function send(ability, method, ...)
	if not ability or type(ability[method]) ~= "function" then return false, method .. " indisponível" end
	local ok, result = pcall(ability[method], ability, ...)
	if not ok then return false, tostring(result) end
	if result == false then return false, method .. " recusado" end
	return true
end

function Remote.fireParry(_flag, guard)
	if not gameInfo then return false, "Remote não inicializado" end
	local ability = gameInfo.getDeflectAbility()
	if not ability then return false, "Deflect indisponível" end
	if type(guard) == "function" then
		local ok, allowed = pcall(guard)
		if not ok or not allowed then return false, "Deflect cancelado" end
	end
	return send(ability, "Deflect")
end

function Remote.fireDark(eventId, cameraFrame)
	return send(gameInfo and gameInfo.getDarkSealAbility(), "SendEvent", eventId, cameraFrame)
end

function Remote.fireFierce()
	return send(gameInfo and gameInfo.getFierceDeflectAbility(), "ActivateAndBlock")
end

function Remote.fireDash()
	return send(gameInfo and gameInfo.getDashAbility(), "Dash")
end

-- contract
Remote.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = {
		GameInfo = { "getDeflectAbility", "getDarkSealAbility", "getFierceDeflectAbility", "getDashAbility" },
	},
	provides = { "setup", "fireParry", "fireDark", "fireFierce", "fireDash" },
}

return Remote
