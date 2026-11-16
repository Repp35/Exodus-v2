-- [[ speed ]]

local Speed = {}

local Utils
local configObserver

-- configuration
local CONFIG = {
  schema = { UniversalSpeedEnabled = "boolean", UniversalSpeed = "rate" },
  defaults = { UniversalSpeedEnabled = false, UniversalSpeed = 40 },
}

local RunService = game:GetService("RunService")
local states = { Speed = false }
local speedValue
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
local speedHumanoid, speedRestore, speedApplied
local applyingSpeed = false
local function writeSpeed(humanoid, value)
  if humanoid.WalkSpeed == value then return end
  applyingSpeed = true; humanoid.WalkSpeed = value
  applyingSpeed = false
end
local function currentHumanoid()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  return character and character:FindFirstChildOfClass("Humanoid")
end
local function applySpeed()
  local humanoid = currentHumanoid()
  if humanoid ~= speedHumanoid then
    disconnect("SpeedChanged")
    if speedHumanoid and speedHumanoid.Parent and speedApplied ~= nil and speedHumanoid.WalkSpeed == speedApplied and speedRestore ~= nil then writeSpeed(speedHumanoid, speedRestore) end
    speedHumanoid, speedApplied = humanoid, nil; speedRestore = humanoid and humanoid.WalkSpeed or nil
    if humanoid then
      connect("SpeedChanged", humanoid:GetPropertyChangedSignal("WalkSpeed"), function()
        if not applyingSpeed and states.Speed and speedHumanoid == humanoid and humanoid.WalkSpeed ~= speedApplied then
          speedRestore, speedApplied = humanoid.WalkSpeed, nil
          if humanoid.WalkSpeed < speedValue then speedApplied = speedValue; writeSpeed(humanoid, speedValue) end
        end
      end)
    end
  end
  local configured = tonumber(Utils.getConfigValue("UniversalSpeed"))
  if configured and configured == configured and configured > -math.huge and configured < math.huge then speedValue = math.clamp(configured, 0, 200) end
  if humanoid and humanoid.Health > 0 then
    if speedApplied ~= nil and humanoid.WalkSpeed == speedApplied then
      local desired = math.max(speedRestore or 0, speedValue)
      if desired ~= speedApplied then speedApplied = desired; writeSpeed(humanoid, desired) end
    elseif humanoid.WalkSpeed < speedValue then
      speedRestore, speedApplied = humanoid.WalkSpeed, speedValue; writeSpeed(humanoid, speedValue)
    end
  end
  return true
end
local function startSpeed()
  local frameSignal = RunService.PreSimulation or RunService.Stepped or RunService.Heartbeat
  if not frameSignal then return false end
  connect("SpeedFrame", frameSignal, applySpeed)
  if RunService.RenderStepped and RunService.RenderStepped ~= frameSignal then connect("SpeedRender", RunService.RenderStepped, applySpeed) end
  return applySpeed()
end
local function stopSpeed()
  disconnect("SpeedStep"); disconnect("SpeedFrame")
  disconnect("SpeedRender"); disconnect("SpeedChanged")
  if speedHumanoid and speedHumanoid.Parent and speedApplied ~= nil and speedHumanoid.WalkSpeed == speedApplied and speedRestore ~= nil then writeSpeed(speedHumanoid, speedRestore) end
  speedHumanoid, speedRestore, speedApplied = nil, nil, nil; return true
end
function Speed.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalSpeedEnabled = value }) then return false, "configuração rejeitada" end
  if states.Speed == value then
    if value then applySpeed() end
    return true
  end
  states.Speed = value; local ok, result, detail = pcall(value and startSpeed or stopSpeed)
  if not ok or result == false then
    pcall(stopSpeed); states.Speed = false
    Utils.setConfig({ UniversalSpeedEnabled = false }); return false, tostring(ok and (detail or "falha ao alterar recurso") or result)
  end
  return true
end
function Speed.setValue(value)
  if not Utils then return false, "controle inválido" end
  local number = tonumber(value)
  if not number or number ~= number or math.abs(number) == math.huge then return false, "valor inválido" end
  number = math.clamp(number, 0, 200)
  if not Utils.setConfig({ UniversalSpeed = number, UniversalSpeedEnabled = true }) then return false end
  speedValue = number
  if not states.Speed then return Speed.setEnabled(true) end
  return applySpeed()
end
function Speed.teardown()
  if configObserver then configObserver:Disconnect(); configObserver = nil end
  stopSpeed(); states.Speed = false
  Utils = nil; return true
end
function Speed.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Speed.teardown(); Utils = deps.Utils
  configObserver = Utils.observeConfig(function(changes)
    if changes.UniversalSpeedEnabled ~= nil then Speed.setEnabled(changes.UniversalSpeedEnabled == true) end
  end)
  speedValue = tonumber(Utils.getConfigValue("UniversalSpeed")) or CONFIG.defaults.UniversalSpeed
  if Utils.getConfigValue("UniversalSpeedEnabled") == true then return Speed.setEnabled(true) end
  return true
end
Speed.__config = CONFIG

-- contract
Speed.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "observeConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled", "setValue" },
}

return Speed
