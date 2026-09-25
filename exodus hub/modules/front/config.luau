-- [[ config ]]

local Config = {}

-- defaults
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value < math.huge and value > -math.huge
end
local DEFAULTS = {
	AutoParry = true,
	AutoClash = true,
	DynamicParry = false,
	DynamicParryReleaseDelay = 0.2,
	CPS = 500,
	CPF = 8,
	SpamRateMode = "CPF",
	Keybind = Enum.KeyCode.F9,
	SpamKeybind = Enum.KeyCode.F,
	SpamMode = "Toggle",
	ClashBallVisible = false,
}

local function cloneDefaults()
	local result = {}
	for key, value in pairs(DEFAULTS) do
		result[key] = value
	end
	return result
end
function Config.defaults() return cloneDefaults() end
function Config.validate(config)
	if type(config) ~= "table" then return false, "configuração não é uma tabela" end
	if
		type(config.AutoParry) ~= "boolean"
		or type(config.AutoClash) ~= "boolean"
		or type(config.DynamicParry) ~= "boolean"
		or type(config.ClashBallVisible) ~= "boolean"
	then
		return false, "flags booleanas inválidas"
	end
	if not isFiniteNumber(config.CPS) or not isFiniteNumber(config.CPF) or config.CPS < 0 or config.CPF < 0 then return false, "taxas de spam inválidas" end
	if
		not isFiniteNumber(config.DynamicParryReleaseDelay)
		or config.DynamicParryReleaseDelay < 0
		or config.DynamicParryReleaseDelay > 5
	then
		return false, "atraso de saída do Dynamic Parry inválido"
	end
	if config.SpamRateMode ~= "CPS" and config.SpamRateMode ~= "CPF" then return false, "SpamRateMode inválido" end
	if config.SpamMode ~= "Toggle" and config.SpamMode ~= "Hold" then return false, "SpamMode inválido" end
	if config.Keybind == nil or config.SpamKeybind == nil then return false, "keybind ausente" end
	return true
end
Config.__contract = { requires = {} }

return Config
