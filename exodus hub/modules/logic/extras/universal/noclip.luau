-- [[ noclip ]]

local Noclip = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalNoclip = "boolean" },
  defaults = { UniversalNoclip = false },
}

local RunService = game:GetService("RunService")
local savedCollision = setmetatable({}, { __mode = "k" })
local noclipCharacter
local characterParts = {}
local partsDirty = true
local enabledState = false

local connections = {}
local function disconnect(name)
  local connection = connections[name]; connections[name] = nil
  if connection then if Utils then pcall(Utils.untrackGlobal, connection) end; pcall(connection.Disconnect, connection) end
end
local function connect(name, signal, callback)
  disconnect(name); local connection = signal:Connect(callback); connections[name] = connection
  if Utils then Utils.trackGlobal(connection) end; return connection
end

local function restoreCollision()
  disconnect("NoclipAdded"); disconnect("NoclipRemoving")
  table.clear(characterParts); partsDirty = true
  for part, value in pairs(savedCollision) do
    if part.Parent then pcall(function() part.CanCollide = value end) end
    savedCollision[part] = nil
  end
  noclipCharacter = nil
end
local function applyNoclip()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  if character ~= noclipCharacter then
    restoreCollision(); noclipCharacter = character
    if character then
      local function markPartsDirty() partsDirty = true end
      connect("NoclipAdded", character.DescendantAdded, markPartsDirty)
      connect("NoclipRemoving", character.DescendantRemoving, markPartsDirty)
    end
  end
  if not character or not character.Parent then return end
  if partsDirty then
    table.clear(characterParts)
    for _, part in ipairs(character:GetDescendants()) do
      if part:IsA("BasePart") then characterParts[#characterParts + 1] = part end
    end
    partsDirty = false
  end
  for _, part in ipairs(characterParts) do
    if savedCollision[part] == nil then savedCollision[part] = part.CanCollide end
    if part.CanCollide then part.CanCollide = false end
  end
end
local function startNoclip() connect("Noclip", RunService.Stepped, applyNoclip); applyNoclip(); return true end
local function stopNoclip() disconnect("Noclip"); restoreCollision(); return true end


function Noclip.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalNoclip = value }) then return false, "configuração rejeitada" end
  if enabledState == value then
    return true
  end
  enabledState = value
  local ok, result = pcall(value and startNoclip or stopNoclip)
  if not ok or result == false then enabledState = not value; Utils.setConfig({ UniversalNoclip = not value }); return false, tostring(result) end
  return true
end
function Noclip.teardown()
  if enabledState then stopNoclip() end
  enabledState = false; Utils = nil; return true
end
function Noclip.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Noclip.teardown(); Utils = deps.Utils
  if Utils.getConfigValue("UniversalNoclip") == true then return Noclip.setEnabled(true) end
  return true
end

Noclip.__config = CONFIG
-- contract
Noclip.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled" },
}
return Noclip
