-- [[ remote ]]

-- dependencies
local Remote = {}
local utils, gameInfo

-- lifecycle
function Remote.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências inválidas: Utils ou GameInfo" end
	utils, gameInfo = deps.Utils, deps.GameInfo; return true
end

-- dispatch
local function send(ability, method, ...)
	if ability == nil then return false, method .. " não equipado ou indisponível" end
	if type(ability[method]) ~= "function" then error("API externa ausente: habilidade." .. method, 2) end
	local result = ability[method](ability, ...)
	if result == false then return false, method .. " recusado" end
	return true
end
function Remote.fireParry(_flag, guard)
	if not gameInfo then return false, "Remote não inicializado" end
	local ability = gameInfo.getDeflectAbility()
	if not ability then return false, "Deflect indisponível" end
	if type(guard) == "function" then
		if not guard() then return false, "Deflect cancelado" end
	end
	return send(ability, "Deflect")
end
function Remote.fireDark(eventId, cameraFrame) return send(gameInfo and gameInfo.getDarkSealAbility(), "SendEvent", eventId, cameraFrame) end
function Remote.fireFierce(guard)
	local ability = gameInfo and gameInfo.getFierceDeflectAbility()
	if type(guard) == "function" and not guard() then return false, "Fierce cancelado" end
	return send(ability, "ActivateAndBlock")
end
function Remote.fireDash() return send(gameInfo and gameInfo.getDashAbility(), "Dash") end

-- contract
Remote.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = {
		GameInfo = { "getDeflectAbility", "getDarkSealAbility", "getFierceDeflectAbility", "getDashAbility" },
	},

	provides = { "setup", "fireParry", "fireDark", "fireFierce", "fireDash" },
}

return Remote
