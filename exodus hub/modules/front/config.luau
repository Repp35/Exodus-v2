-- [[ config registry ]]

local Config = {}
local Registry = {}
local Keys = {}

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value < math.huge and value > -math.huge
end

local function validKeyCode(value)
	return typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode
end

local function validateValue(key, kind, value)
	if kind == "boolean" and type(value) ~= "boolean" then return false, "flag inválida: " .. key end
	if kind == "rate" and (not isFiniteNumber(value) or value < 0) then return false, "taxa inválida: " .. key end
	if kind == "delay" and (not isFiniteNumber(value) or value < 0 or value > 5) then return false, "atraso inválido: " .. key end
	if kind == "position" and (not isFiniteNumber(value) or value < -10000 or value > 10000) then return false, "posição inválida: " .. key end
	if kind == "keyCode" and not validKeyCode(value) then return false, "keybind inválido: " .. key end
	if kind == "rateMode" and value ~= "CPS" and value ~= "CPF" then return false, "SpamRateMode inválido" end
	if kind == "spamMode" and value ~= "Toggle" and value ~= "Hold" then return false, "SpamMode inválido" end
	return true
end

local function copy(source)
	local result = {}
	for key, value in pairs(source or {}) do result[key] = value end
	return result
end

function Config.register(name, definition)
	if type(name) ~= "string" or type(definition) ~= "table" or Registry[name] then return false end
	local schema = type(definition.schema) == "table" and definition.schema or {}
	local defaults = type(definition.defaults) == "table" and definition.defaults or {}
	for key, kind in pairs(schema) do
		if type(key) ~= "string" or type(kind) ~= "string" or Keys[key] then return false end
		Keys[key] = kind
	end
	Registry[name] = { schema = copy(schema), defaults = copy(defaults) }
	return true
end

function Config.defaults()
	local result = {}
	for _, definition in pairs(Registry) do
		for key, value in pairs(definition.defaults) do result[key] = value end
	end
	return result
end

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

function Config.getRegistry()
	local result = {}
	for name, definition in pairs(Registry) do result[name] = { schema = copy(definition.schema), defaults = copy(definition.defaults) } end
	return result
end

Config.__contract = { requires = {} }

return Config
