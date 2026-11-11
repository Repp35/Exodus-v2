-- [[ config ]]

-- module
local Config = {}
local Registry = {}
local Keys = {}

-- configuration
local CONFIG = {
  RATE_MIN = 0,
  DELAY_MIN = 0,
  DELAY_MAX = 5,
  DELAY_MS_MAX = 400,
  WINDOW_FACTOR_MAX = 0.35,
  POSITION_MIN = -10000,
  POSITION_MAX = 10000,
  ERRORS = {
    boolean = "flag inválida: %s",
    rate = "taxa inválida: %s",
    delay = "atraso inválido: %s",
    delayMs = "tempo inválido: %s",
    windowFactor = "fator de janela inválido: %s",
    position = "posição inválida: %s",
    keyCode = "keybind inválido: %s",
    rateMode = "SpamRateMode inválido",
  },
}

-- validation
local function isFiniteNumber(value) return type(value) == "number" and value == value and value < math.huge and value > -math.huge end
local function validKeyCode(value)
  return typeof(value) == "EnumItem"
    and (
      value.EnumType == Enum.KeyCode
      or value == Enum.UserInputType.MouseButton1
      or value == Enum.UserInputType.MouseButton2
      or value == Enum.UserInputType.MouseButton3
    )
end
local validationErrors = CONFIG.ERRORS
local validators = {
  boolean = function(value) return type(value) == "boolean" end,
  rate = function(value) return isFiniteNumber(value) and value >= CONFIG.RATE_MIN end,
  delay = function(value) return isFiniteNumber(value) and value >= CONFIG.DELAY_MIN and value <= CONFIG.DELAY_MAX end,
  delayMs = function(value) return isFiniteNumber(value) and value >= CONFIG.DELAY_MIN and value <= CONFIG.DELAY_MS_MAX end,
  windowFactor = function(value) return isFiniteNumber(value) and value >= 0 and value <= CONFIG.WINDOW_FACTOR_MAX end,
  position = function(value) return isFiniteNumber(value) and value >= CONFIG.POSITION_MIN and value <= CONFIG.POSITION_MAX end,
  keyCode = validKeyCode,
  rateMode = function(value) return value == "CPS" or value == "CPF" or value == "Auto" end,
}

local function validateValue(key, kind, value)
  local validator = validators[kind]
  if validator and validator(value) then return true end
  local message = validationErrors[kind] or "valor inválido: %s"; return false, message:find("%s", 1, true) and message:format(key) or message
end
local function copy(source)
  local result = {}
  for key, value in pairs(source or {}) do
    result[key] = value
  end
  return result
end

-- registration
function Config.register(name, definition)
  if type(name) ~= "string" or type(definition) ~= "table" or Registry[name] then return false end
  local schema = type(definition.schema) == "table" and definition.schema or {}; local defaults = type(definition.defaults) == "table" and definition.defaults or {}
  for key, kind in pairs(schema) do
    if type(key) ~= "string" or not validators[kind] or Keys[key] then return false end
  end
  for key, value in pairs(defaults) do
    local kind = schema[key]
    if not kind or not validateValue(key, kind, value) then return false end
  end
  for key, kind in pairs(schema) do
    Keys[key] = kind
  end
  Registry[name] = { schema = copy(schema), defaults = copy(defaults) }; return true
end

-- defaults
function Config.defaults()
  local result = {}
  for _, definition in pairs(Registry) do
    for key, value in pairs(definition.defaults) do
      result[key] = value
    end
  end
  return result
end

-- validation-api
function Config.validatePatch(patch)
  if type(patch) ~= "table" then return false, "configuração não é uma tabela" end
  for key, value in pairs(patch) do
    local kind = Keys[key]
    if not kind then return false, "chave de configuração desconhecida: " .. tostring(key) end
    local ok, reason = validateValue(key, kind, value)
    if not ok then return false, reason end
  end
  return true
end
function Config.normalizePatch(patch)
  local ok, reason = Config.validatePatch(patch)
  if not ok then return nil, reason end
  return copy(patch)
end
function Config.validate(config)
  if type(config) ~= "table" then return false, "configuração não é uma tabela" end
  local ok, reason = Config.validatePatch(config)
  if not ok then return false, reason end
  return true
end

-- public-api
function Config.getRegistry()
  local result = {}
  for name, definition in pairs(Registry) do
    result[name] = { schema = copy(definition.schema), defaults = copy(definition.defaults) }
  end
  return result
end

-- contract
Config.__contract = {
  provides = { "register", "defaults", "validate", "validatePatch", "normalizePatch", "getRegistry" },
  requires = {},
}

return Config
