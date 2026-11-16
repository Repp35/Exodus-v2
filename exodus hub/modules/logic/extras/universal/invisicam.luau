-- [[ invisicam ]]

local Invisicam = {}

local Utils
local configObserver

-- configuration
local CONFIG = {
  schema = { UniversalInvisicam = "boolean" },
  defaults = { UniversalInvisicam = true },
}

local savedOcclusion, savedOcclusionMode = nil, false
local enabledState = false
local function stopInvisicam()
  local player = Utils and Utils.getLocalPlayer()
  if savedOcclusionMode and player then
    local ok, reason = pcall(function() player.DevCameraOcclusionMode = savedOcclusion end)
    if not ok then warn("[Invisicam] Camera restore unavailable: " .. tostring(reason)) end
  end
  savedOcclusion, savedOcclusionMode = nil, false; enabledState = false
  return true
end
local function startInvisicam()
  local player = Utils.getLocalPlayer()
  if not player then return false, "LocalPlayer unavailable" end
  local readOk, previous = pcall(function() return player.DevCameraOcclusionMode end)
  if not readOk then return false, "Camera occlusion property unavailable" end
  if previous == Enum.DevCameraOcclusionMode.Invisicam then savedOcclusion, savedOcclusionMode = Enum.DevCameraOcclusionMode.Zoom, true; return true end
  local ok, reason = pcall(function() player.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Invisicam end)
  if not ok then return false, tostring(reason) end
  savedOcclusion, savedOcclusionMode = previous, true; return true
end
function Invisicam.setEnabled(enabled)
  if not Utils then return false, "feature unavailable" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalInvisicam = value }) then return false, "configuration rejected" end
  if enabledState == value then return true end
  if not value then return stopInvisicam() end
  local ok, reason = startInvisicam()
  if not ok then
    stopInvisicam(); Utils.setConfig({ UniversalInvisicam = false })
    warn("[Invisicam] Disabled: " .. tostring(reason)); return true
  end
  enabledState = true; return true
end
function Invisicam.teardown()
  if configObserver then configObserver:Disconnect(); configObserver = nil end
  stopInvisicam(); Utils = nil
  return true
end
function Invisicam.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "missing dependency: Utils" end
  Invisicam.teardown(); Utils = deps.Utils
  configObserver = Utils.observeConfig(function(changes)
    if changes.UniversalInvisicam ~= nil then Invisicam.setEnabled(changes.UniversalInvisicam == true) end
  end)
  if Utils.getConfigValue("UniversalInvisicam") == true then return Invisicam.setEnabled(true) end
  return true
end
Invisicam.__config = CONFIG

-- contract
Invisicam.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "observeConfig", "getLocalPlayer" } },
  provides = { "setup", "teardown", "setEnabled" },
}

return Invisicam
