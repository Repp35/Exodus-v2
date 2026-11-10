-- [[ remote ]]

-- dependencies
local Remote = {}
local gameInfo
local lastParryAt, lastParryInterval
local parryTimes = {}

-- lifecycle
function Remote.setup(deps)
	if type(deps) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependência inválida: GameInfo" end
	gameInfo = deps.GameInfo; lastParryAt, lastParryInterval = nil, nil; table.clear(parryTimes); return true
end

-- dispatch
local function pruneParryTimes(now)
	for i = #parryTimes, 1, -1 do
		if now - parryTimes[i] >= 1 or now < parryTimes[i] then table.remove(parryTimes, i) end
	end
end
local function recordParrySent()
	local now = os.clock(); lastParryInterval = lastParryAt and (now - lastParryAt) or nil; lastParryAt = now; pruneParryTimes(now); parryTimes[#parryTimes + 1] = now
end
function Remote.getParrySendTiming() return lastParryInterval, lastParryAt end
function Remote.getParryCps()
	pruneParryTimes(os.clock()); return #parryTimes
end
local function send(ability, method, ...)
	if ability == nil then return false, method .. " não equipado ou indisponível" end
	local callback = ability[method]
	if type(callback) ~= "function" then error("API externa ausente: habilidade." .. method, 2) end
	local result = callback(ability, ...)
	if result == false then return false, method .. " recusado" end
	return true
end
function Remote.fireParry(_flag, guard)
	if not gameInfo then return false, "Remote não inicializado" end
	if gameInfo.isTrainingArea() then
		if type(guard) == "function" and not guard() then return false, "Deflect cancelado" end
		local sent, detail = gameInfo.fireTrainingParry()
		if sent == true then recordParrySent() end
		return sent, detail
	end
	local ability = gameInfo.getDeflectAbility()
	if not ability then return false, "Deflect indisponível" end
	if type(guard) == "function" then
		if not guard() then return false, "Deflect cancelado" end
	end
	local sent, detail = send(ability, "Deflect")
	if sent == true then recordParrySent() end
	return sent, detail
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
	requires = { GameInfo = "gameinfo" },
	requiresMethods = {
		GameInfo = { "isTrainingArea", "fireTrainingParry", "getDeflectAbility", "getDarkSealAbility", "getFierceDeflectAbility", "getDashAbility" },
	},

	provides = { "setup", "fireParry", "getParrySendTiming", "getParryCps", "fireDark", "fireFierce", "fireDash" },
}

return Remote
