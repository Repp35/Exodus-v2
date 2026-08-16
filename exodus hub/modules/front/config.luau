-- [[ Config ]]

local Config = {}

-- defaults
local DEFAULTS = {
    AutoParry = true,
    AutoClash = true,
    CPS = 4,
    CPF = 16,
    SpamRateMode = "CPF",
    Keybind = Enum.KeyCode.F9,
    SpamKeybind = Enum.KeyCode.F,
    SpamMode = "Toggle",
    ClashBallVisible = false,
}

function Config.defaults()
    local result = {}

    for key, value in pairs(DEFAULTS) do
        result[key] = value
    end

    return result
end

return Config
