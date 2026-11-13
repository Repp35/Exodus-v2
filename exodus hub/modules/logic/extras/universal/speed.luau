-- [[ speed ]]

local Speed = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalSpeedEnabled = "boolean", UniversalSpeed = "rate" },
  defaults = { UniversalSpeedEnabled = false, UniversalSpeed = 16 },
}

local RunService = game:GetService("RunService")
local states = { Speed = false }
local speedDefault, speedValue
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
local speedHumanoid, speedRestore
local function currentHumanoid()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  return character and character:FindFirstChildOfClass("Humanoid")
end
local function applySpeed()
  local humanoid = currentHumanoid()
  if humanoid ~= speedHumanoid then speedHumanoid = humanoid; speedRestore = humanoid and humanoid.WalkSpeed or nil end
  local configured = tonumber(Utils.getConfigValue("UniversalSpeed"))
  if configured and configured == configured and configured > -math.huge and configured < math.huge then speedValue = math.clamp(configured, 0, 200) end
  if humanoid and humanoid.Health > 0 then humanoid.WalkSpeed = speedValue end
  return true
end
local function startSpeed()
  local frameSignal = RunService.PreSimulation or RunService.Stepped or RunService.Heartbeat
  if not frameSignal then return false end
  connect("SpeedFrame", frameSignal, applySpeed); return applySpeed()
end
local function stopSpeed()
  disconnect("SpeedStep"); disconnect("SpeedFrame")
  if speedHumanoid and speedHumanoid.Parent and speedHumanoid.WalkSpeed == speedValue and speedRestore ~= nil then speedHumanoid.WalkSpeed = speedRestore end
  speedHumanoid, speedRestore = nil, nil; return true
end
function Speed.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalSpeedEnabled = value }) then return false, "configuração rejeitada" end
  if states.Speed == value then
    if value then applySpeed() end
    return true
  end
  states.Speed = value; local ok, result = pcall(value and startSpeed or stopSpeed)
  if not ok or result == false then
    states.Speed = not value; Utils.setConfig({ UniversalSpeedEnabled = not value })
    return false, tostring(result)
  end
  return true
end
function Speed.setValue(value)
  if not Utils then return false, "controle inválido" end
  local number = tonumber(value)
  if not number or number ~= number then return false, "valor inválido" end
  local previous = speedValue; speedValue = math.clamp(number, 0, 200)
  if states.Speed and speedHumanoid and speedHumanoid.WalkSpeed == previous then speedHumanoid.WalkSpeed = speedValue end
  if not Utils.setConfig({ UniversalSpeed = speedValue, UniversalSpeedEnabled = true }) then return false end
  if not states.Speed then return Speed.setEnabled(true) end
  return applySpeed()
end
function Speed.teardown()
  if states.Speed then stopSpeed() end
  states.Speed = false; Utils = nil
  return true
end
function Speed.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Speed.teardown(); Utils = deps.Utils
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid"); speedDefault = humanoid and humanoid.WalkSpeed or 16
  speedValue = tonumber(Utils.getConfigValue("UniversalSpeed")) or speedDefault
  if Utils.getConfigValue("UniversalSpeedEnabled") == true then return Speed.setEnabled(true) end
  return true
end
Speed.__config = CONFIG

-- contract
Speed.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled", "setValue" },
}

return Speed
