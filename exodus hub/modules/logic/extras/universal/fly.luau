-- [[ fly ]]

local Fly = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalFly = "boolean", UniversalFlySpeed = "rate" },
  defaults = { UniversalFly = false, UniversalFlySpeed = 1 },
}

local Workspace = game:GetService("Workspace")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local states = { Fly = false }
local flyCharacter, flyHumanoid, flyRoot, flyVelocity, flyGyro
local flyPlatformStand, flyAutoRotate
local controls = { Forward = 0, Backward = 0, Left = 0, Right = 0, Up = 0, Down = 0 }
local bindings = {
  [Enum.KeyCode.W] = { "Forward", 1 }, [Enum.KeyCode.S] = { "Backward", -1 },
  [Enum.KeyCode.A] = { "Left", -1 }, [Enum.KeyCode.D] = { "Right", 1 },
  [Enum.KeyCode.E] = { "Up", 1 }, [Enum.KeyCode.Q] = { "Down", -1 },
  [Enum.KeyCode.Space] = { "Up", 1 }, [Enum.KeyCode.LeftControl] = { "Down", -1 },
}

local connections = {}
local function disconnect(name)
  local connection = connections[name]; connections[name] = nil
  if connection then if Utils then pcall(Utils.untrackGlobal, connection) end; pcall(connection.Disconnect, connection) end
end
local function connect(name, signal, callback)
  disconnect(name); local connection = signal:Connect(callback); connections[name] = connection
  if Utils then Utils.trackGlobal(connection) end; return connection
end
local function disconnectPrefix(prefix)
  for name in pairs(connections) do if name:sub(1, #prefix) == prefix then disconnect(name) end end
end
local function destroy(object) if object then pcall(object.Destroy, object) end end
local function clearControls() for key in pairs(controls) do controls[key] = 0 end end


local function detachFly()
  if flyRoot and flyRoot.Parent then pcall(function() flyRoot.AssemblyLinearVelocity = Vector3.zero end) end
  destroy(flyVelocity); destroy(flyGyro)
  if flyHumanoid and flyHumanoid.Parent then pcall(function()
    if flyPlatformStand ~= nil then flyHumanoid.PlatformStand = flyPlatformStand end
    if flyAutoRotate ~= nil then flyHumanoid.AutoRotate = flyAutoRotate end
  end) end
  flyCharacter, flyHumanoid, flyRoot, flyVelocity, flyGyro = nil, nil, nil, nil, nil
  flyPlatformStand, flyAutoRotate = nil, nil
end
local function flyCharacterReady()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid"); local root = character and character:FindFirstChild("HumanoidRootPart")
  if not character or not humanoid or humanoid.Health <= 0 or not root then detachFly(); return nil end
  if flyCharacter ~= character then detachFly(); flyCharacter, flyHumanoid, flyRoot = character, humanoid, root; flyPlatformStand, flyAutoRotate = humanoid.PlatformStand, humanoid.AutoRotate end
  if not flyVelocity or not flyVelocity.Parent then
    flyVelocity = Instance.new("BodyVelocity"); flyVelocity.Name = "ExodusFlyVelocity"; flyVelocity.MaxForce = Vector3.new(9e9, 9e9, 9e9); flyVelocity.P = 9e4; flyVelocity.Parent = root
  end
  if not flyGyro or not flyGyro.Parent then
    flyGyro = Instance.new("BodyGyro"); flyGyro.Name = "ExodusFlyGyro"; flyGyro.MaxTorque = Vector3.new(9e9, 9e9, 9e9); flyGyro.P = 9e4; flyGyro.D = 1000; flyGyro.Parent = root
  end
  return humanoid
end
local function updateFly()
  if not states.Fly then return end
  local humanoid = flyCharacterReady(); local camera = Workspace.CurrentCamera
  if not humanoid or not camera then return end
  local direction = UIS.TouchEnabled and camera.CFrame.LookVector
    or camera.CFrame.LookVector * (controls.Forward + controls.Backward)
      + camera.CFrame.RightVector * (controls.Left + controls.Right)
      + Vector3.new(0, controls.Up + controls.Down, 0)
  if direction.Magnitude > 1 then direction = direction.Unit end
  flyVelocity.Velocity = direction * (tonumber(Utils.getConfigValue("UniversalFlySpeed")) or 1) * 50
  flyGyro.CFrame = camera.CFrame; humanoid.PlatformStand = true; humanoid.AutoRotate = false
end
local function startFly()
  connect("FlyBegan", UIS.InputBegan, function(input, processed)
    if processed then return end; local binding = bindings[input.KeyCode]; if binding then controls[binding[1]] = binding[2] end
  end)
  connect("FlyEnded", UIS.InputEnded, function(input)
    local binding = bindings[input.KeyCode]; if binding then controls[binding[1]] = 0 end
  end)
  connect("FlyFocus", UIS.WindowFocusReleased, clearControls)
  connect("FlyStep", RunService.RenderStepped, updateFly); return true
end
local function stopFly()
  disconnectPrefix("Fly"); clearControls(); detachFly(); return true
end


function Fly.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalFly = value }) then return false, "configuração rejeitada" end
  if states.Fly == value then
    return true
  end
  states.Fly = value
  local ok, result = pcall(value and startFly or stopFly)
  if not ok or result == false then states.Fly = not value; Utils.setConfig({ UniversalFly = not value }); return false, tostring(result) end
  return true
end
function Fly.teardown()
  if states.Fly then stopFly() end
  states.Fly = false; Utils = nil; return true
end
function Fly.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Fly.teardown(); Utils = deps.Utils
  if Utils.getConfigValue("UniversalFly") == true then return Fly.setEnabled(true) end
  return true
end

Fly.__config = CONFIG
Fly.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled" },
}
return Fly
