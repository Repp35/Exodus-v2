-- [[ config ]]

local Config = {}
local registry = {}
local keys = {}
local kinds = {
    boolean = true,
    rate = true,
    delay = true,
    delayMs = true,
    position = true,
    keyCode = true,
    rateMode = true,
}

local function copy(source)
    local result = {}
    for key, value in pairs(source) do
        result[key] = value
    end
    return result
end

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function valid(key, kind, value)
    if kind == "boolean" then
        return type(value) == "boolean", "flag inválida: " .. key
    elseif kind == "rate" then
        return finite(value) and value >= 0, "taxa inválida: " .. key
    elseif kind == "delay" then
        return finite(value) and value >= 0 and value <= 5, "atraso inválido: " .. key
    elseif kind == "delayMs" then
        return finite(value) and value >= 0 and value <= 400, "tempo inválido: " .. key
    elseif kind == "position" then
        return finite(value) and value >= -10000 and value <= 10000, "posição inválida: " .. key
    elseif kind == "keyCode" then
        return typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode, "keybind inválido: " .. key
    elseif kind == "rateMode" then
        return value == "CPS" or value == "CPF", "SpamRateMode inválido"
    end
    return false, "tipo inválido: " .. tostring(kind)
end

function Config.register(name, definition)
    if type(name) ~= "string" or type(definition) ~= "table" or registry[name] then return false end

    local schema = type(definition.schema) == "table" and definition.schema or {}
    local defaults = type(definition.defaults) == "table" and definition.defaults or {}

    for key, kind in pairs(schema) do
        if type(key) ~= "string" or not kinds[kind] or keys[key] then return false end
    end
    for key, value in pairs(defaults) do
        local kind = schema[key]
        if not kind then return false end
        local ok = valid(key, kind, value)
        if not ok then return false end
    end

    for key, kind in pairs(schema) do keys[key] = kind end
    registry[name] = {schema = copy(schema), defaults = copy(defaults)}
    return true
end

function Config.defaults()
    local result = {}
    for _, definition in pairs(registry) do
        for key, value in pairs(definition.defaults) do result[key] = value end
    end
    return result
end

function Config.validatePatch(patch)
    if type(patch) ~= "table" then return false, "configuração não é uma tabela" end
    for key, value in pairs(patch) do
        local kind = keys[key]
        if not kind then return false, "chave de configuração desconhecida: " .. tostring(key) end
        local ok, err = valid(key, kind, value)
        if not ok then return false, err end
    end
    return true
end

function Config.normalizePatch(patch)
    local ok, err = Config.validatePatch(patch)
    if not ok then return nil, err end
    return copy(patch)
end

Config.validate = Config.validatePatch

function Config.getRegistry()
    local result = {}
    for name, definition in pairs(registry) do
        result[name] = {schema = copy(definition.schema), defaults = copy(definition.defaults)}
    end
    return result
end

Config.__contract = {
    provides = {"register", "defaults", "validate", "normalizePatch"},
    requires = {},
}

return Config
