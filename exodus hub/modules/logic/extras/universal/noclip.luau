-- [[ noclip ]]

local Noclip = {}

local Utils
local configObserver

-- configuration
local CONFIG = {
  schema = { UniversalNoclip = "boolean" },
  defaults = { UniversalNoclip = false },
}

local RunService = game:GetService("RunService")
local savedCollision = setmetatable({}, { __mode = "k" })
local noclipCharacter
local characterParts = {}
local partIndexes = {}
local enabledState = false
local connections = {}
local function disconnect(name)
  local connection = connections[name]; connections[name] = nil
  if connection then
    if Utils then pcall(Utils.untrackGlobal, connection) end
    pcall(connection.Disconnect, connection)
  end
end
local function connect(name, signal, callback)
  disconnect(name); local connection = signal:Connect(callback)
  connections[name] = connection
  if Utils then Utils.trackGlobal(connection) end
  return connection
end
local function restoreCollision()
  disconnect("NoclipAdded"); disconnect("NoclipRemoving")
  table.clear(characterParts); table.clear(partIndexes)
  for part, value in pairs(savedCollision) do
    if part.Parent then
      pcall(function() part.CanCollide = value end)
    end
    savedCollision[part] = nil
  end
  noclipCharacter = nil
end
local function applyNoclip()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  if character ~= noclipCharacter then
    restoreCollision(); noclipCharacter = character
    if character then
      local function addPart(part)
        if not part:IsA("BasePart") or partIndexes[part] then return end
        characterParts[#characterParts + 1] = part; partIndexes[part] = #characterParts
      end
      local function removePart(part)
        local index = partIndexes[part]
        if not index then return end
        local last = characterParts[#characterParts]; characterParts[index] = last
        characterParts[#characterParts] = nil; partIndexes[part] = nil
        if last and last ~= part then partIndexes[last] = index end
        local original = savedCollision[part]; savedCollision[part] = nil
        if original ~= nil then
          pcall(function() part.CanCollide = original end)
        end
      end
      connect("NoclipAdded", character.DescendantAdded, addPart); connect("NoclipRemoving", character.DescendantRemoving, removePart)
      for _, part in ipairs(character:GetDescendants()) do
        addPart(part)
      end
    end
  end
  if not character or not character.Parent then return end
  for _, part in ipairs(characterParts) do
    if savedCollision[part] == nil then savedCollision[part] = part.CanCollide end
    if part.CanCollide then part.CanCollide = false end
  end
end
local function startNoclip()
  connect("Noclip", RunService.Stepped, applyNoclip); applyNoclip()
  return true
end
local function stopNoclip()
  disconnect("Noclip"); restoreCollision()
  return true
end
function Noclip.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalNoclip = value }) then return false, "configuração rejeitada" end
  if enabledState == value then return true end
  enabledState = value; local ok, result, detail = pcall(value and startNoclip or stopNoclip)
  if not ok or result == false then
    pcall(stopNoclip); enabledState = false
    Utils.setConfig({ UniversalNoclip = false }); return false, tostring(ok and (detail or "falha ao alterar recurso") or result)
  end
  return true
end
function Noclip.teardown()
  if configObserver then configObserver:Disconnect(); configObserver = nil end
  stopNoclip(); enabledState = false
  Utils = nil; return true
end
function Noclip.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Noclip.teardown(); Utils = deps.Utils
  configObserver = Utils.observeConfig(function(changes)
    if changes.UniversalNoclip ~= nil then Noclip.setEnabled(changes.UniversalNoclip == true) end
  end)
  if Utils.getConfigValue("UniversalNoclip") == true then return Noclip.setEnabled(true) end
  return true
end
Noclip.__config = CONFIG

-- contract
Noclip.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "observeConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled" },
}

return Noclip
