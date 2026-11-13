-- [[ invisicam ]]

local Invisicam = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalInvisicam = "boolean" },
  defaults = { UniversalInvisicam = false },
}

local savedOcclusion, savedOcclusionMode = nil, false
local enabledState = false
local function startInvisicam()
  local player = Utils.getLocalPlayer()
  if not player then return false, "LocalPlayer indisponível" end
  if not savedOcclusionMode then
    local ok, value = pcall(function() return player.DevCameraOcclusionMode end)
    if ok then savedOcclusion, savedOcclusionMode = value, true end
  end
  local ok, errorMessage = pcall(function() player.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Invisicam end)
  return ok, ok and nil or tostring(errorMessage)
end
local function stopInvisicam()
  local player = Utils.getLocalPlayer()
  if player and savedOcclusionMode then
    pcall(function() player.DevCameraOcclusionMode = savedOcclusion end)
  end
  savedOcclusion, savedOcclusionMode = nil, false; return true
end
function Invisicam.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalInvisicam = value }) then return false, "configuração rejeitada" end
  if enabledState == value then return true end
  enabledState = value; local ok, result = pcall(value and startInvisicam or stopInvisicam)
  if not ok or result == false then
    enabledState = not value; Utils.setConfig({ UniversalInvisicam = not value })
    return false, tostring(result)
  end
  return true
end
function Invisicam.teardown()
  if enabledState then stopInvisicam() end
  enabledState = false; Utils = nil
  return true
end
function Invisicam.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Invisicam.teardown(); Utils = deps.Utils
  if Utils.getConfigValue("UniversalInvisicam") == true then return Invisicam.setEnabled(true) end
  return true
end
Invisicam.__config = CONFIG

-- contract
Invisicam.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "getLocalPlayer" } },
  provides = { "setup", "teardown", "setEnabled" },
}

return Invisicam
