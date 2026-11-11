-- [[ remote ]]

-- module
local Remote = {}
local gameInfo

-- configuration
local CONFIG = {
  PARRY_METHOD = "Deflect",
  DARK_METHOD = "SendEvent",
  FIERCE_METHOD = "ActivateAndBlock",
  DASH_METHOD = "Dash",
}

-- lifecycle
function Remote.setup(deps)
  if type(deps) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependência inválida: GameInfo" end
  gameInfo = deps.GameInfo; return true
end

-- dispatch
local function send(ability, method, ...)
  if ability == nil then return false, method .. " não equipado ou indisponível" end
  local callback = ability[method]
  if type(callback) ~= "function" then error("API externa ausente: habilidade." .. method, 2) end
  local ok, result = pcall(callback, ability, ...)
  if not ok then return false, tostring(result) end
  if result == false then return false, method .. " recusado" end
  return true
end
local function allowed(guard)
  if type(guard) ~= "function" then return true end
  local ok, result = pcall(guard); return ok and result ~= nil and result ~= false
end
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function fireDeflect(ability)
  local before = gameInfo.getLastDeflectPressAt(); local sent, detail = send(ability, CONFIG.PARRY_METHOD)
  if not sent then return false, detail end
  local after = gameInfo.getLastDeflectPressAt()
  if not finite(after) or (finite(before) and after <= before + 0.001) or (not finite(before) and after <= 0) then return false, "Deflect não aceito pelo cliente" end
  return true, detail
end

-- public-api
function Remote.fireParry(_flag, guard)
  if not gameInfo then return false, "Remote não inicializado" end
  if gameInfo.isTrainingArea() then
    if not allowed(guard) then return false, "Deflect cancelado" end
    local sent, detail = gameInfo.fireTrainingParry(); return sent, detail
  end
  local ability = gameInfo.getDeflectAbility()
  if not ability then return false, "Deflect indisponível" end
  if not allowed(guard) then return false, "Deflect cancelado" end
  local sent, detail = fireDeflect(ability); return sent, detail
end
function Remote.fireDark(eventId, cameraFrame)
  if not gameInfo then return false, "Remote não inicializado" end
  return send(gameInfo.getDarkSealAbility(), CONFIG.DARK_METHOD, eventId, cameraFrame)
end
function Remote.fireFierce(guard)
  if not gameInfo then return false, "Remote não inicializado" end
  local ability = gameInfo and gameInfo.getFierceDeflectAbility()
  if not allowed(guard) then return false, "Fierce cancelado" end
  return send(ability, CONFIG.FIERCE_METHOD)
end
function Remote.fireDash()
  if not gameInfo then return false, "Remote não inicializado" end
  return send(gameInfo.getDashAbility(), CONFIG.DASH_METHOD)
end

-- contract
Remote.__contract = {
  requires = { GameInfo = "gameinfo" },
  requiresMethods = {
    GameInfo = {
      "isTrainingArea",
      "fireTrainingParry",
      "getDeflectAbility",
      "getLastDeflectPressAt",
      "getDarkSealAbility",
      "getFierceDeflectAbility",
      "getDashAbility",
    },
  },
  provides = {
    "setup",
    "fireParry",
    "fireDark",
    "fireFierce",
    "fireDash",
  },
}

return Remote
