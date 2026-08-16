--[[ Config ]]
local Config = {}

-- defaults
local DEFAULTS = {
    AutoParry = true, AutoClash = true, CPS = 4, CPF = 16,
    SpamRateMode = "CPF", Keybind = Enum.KeyCode.F9,
    SpamKeybind = Enum.KeyCode.F, SpamMode = "Toggle",
}
function Config.defaults()
    local config = {}
    for key, value in pairs(DEFAULTS) do config[key] = value end
    return config
end
return Config
