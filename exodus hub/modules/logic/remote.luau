-- [[ remote ]]

-- tuning
local CONFIG = {
  PARRY_METHOD = "Deflect",
  DARK_METHOD = "SendEvent",
  FIERCE_METHOD = "ActivateAndBlock",
  DASH_METHOD = "Dash",
}

-- dependencies
local Remote = {}
local gameInfo, parryObserver
local autoParrySignature = {}

-- lifecycle
function Remote.setup(deps)
  if type(deps) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependência inválida: GameInfo" end
  gameInfo, parryObserver = deps.GameInfo, nil; return true
end

-- dispatch
local function send(ability, method, ...)
  if ability == nil then return false, method .. " não equipado ou indisponível" end
  local callback = ability[method]
  if type(callback) ~= "function" then error("API externa ausente: habilidade." .. method, 2) end
  local result = callback(ability, ...)
  if result == false then return false, method .. " recusado" end
  return true
end
local function allowed(guard)
  if type(guard) ~= "function" then return true end
  local result = guard(); return result ~= nil and result ~= false
end
local function notifyParry(signature)
  if type(parryObserver) ~= "function" then return end
  local ok, detail = pcall(parryObserver, signature)
  if not ok and type(warn) == "function" then warn("[Remote] Observador de parry falhou: " .. tostring(detail)) end
end
function Remote.getAutoParrySignature() return autoParrySignature end
function Remote.setParryObserver(observer)
  if observer ~= nil and type(observer) ~= "function" then return false, "observador inválido" end
  parryObserver = observer; return true
end
function Remote.fireParry(_flag, guard, signature)
  if not gameInfo then return false, "Remote não inicializado" end
  if gameInfo.isTrainingArea() then
    if not allowed(guard) then return false, "Deflect cancelado" end
    local sent, detail = gameInfo.fireTrainingParry()
    if sent == true then notifyParry(signature) end
    return sent, detail
  end
  local ability = gameInfo.getDeflectAbility()
  if not ability then return false, "Deflect indisponível" end
  if not allowed(guard) then return false, "Deflect cancelado" end
  local sent, detail = send(ability, CONFIG.PARRY_METHOD)
  if sent == true then notifyParry(signature) end
  return sent, detail
end
function Remote.fireDark(eventId, cameraFrame) return send(gameInfo and gameInfo.getDarkSealAbility(), CONFIG.DARK_METHOD, eventId, cameraFrame) end
function Remote.fireFierce(guard)
  local ability = gameInfo and gameInfo.getFierceDeflectAbility()
  if not allowed(guard) then return false, "Fierce cancelado" end
  return send(ability, CONFIG.FIERCE_METHOD)
end
function Remote.fireDash() return send(gameInfo and gameInfo.getDashAbility(), CONFIG.DASH_METHOD) end

-- contract
Remote.__contract = {
  requires = { GameInfo = "gameinfo" },
  requiresMethods = {
    GameInfo = {
      "isTrainingArea",
      "fireTrainingParry",
      "getDeflectAbility",
      "getDarkSealAbility",
      "getFierceDeflectAbility",
      "getDashAbility",
    },
  },
  provides = {
    "setup",
    "getAutoParrySignature",
    "setParryObserver",
    "fireParry",
    "fireDark",
    "fireFierce",
    "fireDash",
  },
}

return Remote
