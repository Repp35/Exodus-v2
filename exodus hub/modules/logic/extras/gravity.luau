-- [[ gravity ]]

local Gravity = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalGravityEnabled = "boolean", UniversalGravity = "rate" },
  defaults = { UniversalGravityEnabled = false, UniversalGravity = 196.2 },
}

local Workspace = game:GetService("Workspace")
local gravityDefault, gravityValue
local enabledState = false


local function startGravity() Workspace.Gravity = gravityValue; return true end
local function stopGravity() Workspace.Gravity = gravityDefault; return true end

function Gravity.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalGravityEnabled = value }) then return false, "configuração rejeitada" end
  if enabledState == value then
    if value then Workspace.Gravity = gravityValue end
    return true
  end
  enabledState = value
  local ok, result = pcall(value and startGravity or stopGravity)
  if not ok or result == false then enabledState = not value; Utils.setConfig({ UniversalGravityEnabled = not value }); return false, tostring(result) end
  return true
end
function Gravity.setValue(value)
  if not Utils then return false, "controle inválido" end
  local number = tonumber(value); if not number or number ~= number then return false, "valor inválido" end
  gravityValue = math.clamp(number, 0, 400)
  local saved = Utils.setConfig({ UniversalGravity = gravityValue })
  if enabledState then Workspace.Gravity = gravityValue end
  return saved
end
function Gravity.teardown()
  if enabledState then stopGravity() end
  enabledState = false; Utils = nil; return true
end
function Gravity.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Gravity.teardown(); Utils = deps.Utils
  gravityDefault = Workspace.Gravity; gravityValue = tonumber(Utils.getConfigValue("UniversalGravity")) or gravityDefault
  if Utils.getConfigValue("UniversalGravityEnabled") == true then return Gravity.setEnabled(true) end
  return true
end

Gravity.__config = CONFIG
Gravity.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig" } },
  provides = { "setup", "teardown", "setEnabled", "setValue" },
}
return Gravity
