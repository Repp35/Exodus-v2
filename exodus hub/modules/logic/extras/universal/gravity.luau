-- [[ gravity ]]

local Gravity = {}

local Utils
local configObserver

-- configuration
local CONFIG = {
  schema = { UniversalGravityEnabled = "boolean", UniversalGravity = "rate" },
  defaults = { UniversalGravityEnabled = false, UniversalGravity = 196.2 },
}

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local gravityValue
local enabledState = false
local connection, gravityRoot, attachment, force
local function clearGravity()
  if force then force:Destroy(); force = nil end
  if attachment then attachment:Destroy(); attachment = nil end
  gravityRoot = nil
end
local function updateGravity()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid"); local root = character and character:FindFirstChild("HumanoidRootPart")
  if not humanoid or humanoid.Health <= 0 or not root or not root.Parent then clearGravity(); return end
  if gravityRoot ~= root or not force or not force.Parent or not attachment or not attachment.Parent then
    clearGravity(); gravityRoot = root
    attachment = Instance.new("Attachment"); attachment.Name = "ExodusGravityAttachment"
    attachment.Parent = root; force = Instance.new("VectorForce")
    force.Name = "ExodusGravityForce"; force.Attachment0 = attachment
    force.RelativeTo = Enum.ActuatorRelativeTo.World; force.ApplyAtCenterOfMass = true
    force.Parent = root
  end
  local mass = root.AssemblyMass; local compensation = (not root.Anchored and mass == mass and mass < math.huge) and mass * (Workspace.Gravity - gravityValue) or 0
  local desired = Vector3.new(0, compensation, 0)
  if force.Force ~= desired then force.Force = desired end
end
local function startGravity()
  local signal = RunService.PreSimulation or RunService.Stepped or RunService.Heartbeat
  if not signal then return false end
  connection = signal:Connect(updateGravity); Utils.trackGlobal(connection)
  updateGravity(); return true
end
local function stopGravity()
  if connection then
    Utils.untrackGlobal(connection); connection:Disconnect()
    connection = nil
  end
  clearGravity(); return true
end
function Gravity.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalGravityEnabled = value }) then return false, "configuração rejeitada" end
  if enabledState == value then
    if value then updateGravity() end
    return true
  end
  enabledState = value; local ok, result, detail = pcall(value and startGravity or stopGravity)
  if not ok or result == false then
    pcall(stopGravity); enabledState = false
    Utils.setConfig({ UniversalGravityEnabled = false }); return false, tostring(ok and (detail or "falha ao alterar recurso") or result)
  end
  return true
end
function Gravity.setValue(value)
  if not Utils then return false, "controle inválido" end
  local number = tonumber(value)
  if not number or number ~= number or math.abs(number) == math.huge then return false, "valor inválido" end
  number = math.clamp(number, 0, 400)
  if not Utils.setConfig({ UniversalGravity = number }) then return false end
  gravityValue = number
  if not enabledState then return Gravity.setEnabled(true) end
  updateGravity(); return true
end
function Gravity.teardown()
  if configObserver then configObserver:Disconnect(); configObserver = nil end
  stopGravity(); enabledState = false
  Utils = nil; return true
end
function Gravity.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Gravity.teardown(); Utils = deps.Utils
  configObserver = Utils.observeConfig(function(changes)
    if changes.UniversalGravityEnabled ~= nil then Gravity.setEnabled(changes.UniversalGravityEnabled == true) end
  end)
  gravityValue = tonumber(Utils.getConfigValue("UniversalGravity")) or Workspace.Gravity
  if Utils.getConfigValue("UniversalGravityEnabled") == true then return Gravity.setEnabled(true) end
  return true
end
Gravity.__config = CONFIG

-- contract
Gravity.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "observeConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled", "setValue" },
}

return Gravity
