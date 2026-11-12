-- [[ speed ]]

local Speed = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalSpeedEnabled = "boolean", UniversalSpeed = "rate" },
  defaults = { UniversalSpeedEnabled = false, UniversalSpeed = 16 },
}

local states = { Speed = false }
local speedDefault, speedValue

local connections = {}
local function disconnect(name)
  local connection = connections[name]; connections[name] = nil
  if connection then if Utils then pcall(Utils.untrackGlobal, connection) end; pcall(connection.Disconnect, connection) end
end
local function connect(name, signal, callback)
  disconnect(name); local connection = signal:Connect(callback); connections[name] = connection
  if Utils then Utils.trackGlobal(connection) end; return connection
end

local function applySpeed()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  if humanoid then humanoid.WalkSpeed = speedValue end
  return true
end
local function startSpeed()
  local player = Utils.getLocalPlayer()
  if player then
    connect("SpeedCharacter", player.CharacterAdded, function(character)
      task.defer(function()
        local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
        if states.Speed and humanoid then humanoid.WalkSpeed = speedValue end
      end)
    end)
  end
  return applySpeed()
end
local function stopSpeed()
  disconnect("SpeedCharacter"); local player = Utils.getLocalPlayer(); local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  if humanoid then humanoid.WalkSpeed = speedDefault end
  return true
end

function Speed.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalSpeedEnabled = value }) then return false, "configuração rejeitada" end
  if states.Speed == value then
    if value then applySpeed() end
    return true
  end
  states.Speed = value
  local ok, result = pcall(value and startSpeed or stopSpeed)
  if not ok or result == false then states.Speed = not value; Utils.setConfig({ UniversalSpeedEnabled = not value }); return false, tostring(result) end
  return true
end
function Speed.setValue(value)
  if not Utils then return false, "controle inválido" end
  local number = tonumber(value); if not number or number ~= number then return false, "valor inválido" end
  speedValue = math.clamp(number, 0, 200)
  if not Utils.setConfig({ UniversalSpeed = speedValue, UniversalSpeedEnabled = true }) then return false end
  if not states.Speed then return Speed.setEnabled(true) end
  return applySpeed()
end
function Speed.teardown()
  if states.Speed then stopSpeed() end
  states.Speed = false; Utils = nil; return true
end
function Speed.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Speed.teardown(); Utils = deps.Utils
  local player = Utils.getLocalPlayer(); local character = player and player.Character; local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  speedDefault = humanoid and humanoid.WalkSpeed or 16; speedValue = tonumber(Utils.getConfigValue("UniversalSpeed")) or speedDefault
  if Utils.getConfigValue("UniversalSpeedEnabled") == true then return Speed.setEnabled(true) end
  return true
end

Speed.__config = CONFIG
Speed.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled", "setValue" },
}
return Speed
