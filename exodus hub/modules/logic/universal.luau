-- [[ universal controls ]]

local Universal = {}
local Utils
local Workspace = game:GetService("Workspace")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local connections = {}
local states = { InfiniteJump = false, Fly = false, Invisicam = false, Noclip = false, Gravity = false }
local keys = {
  InfiniteJump = "UniversalInfiniteJump", Fly = "UniversalFly",
  Invisicam = "UniversalInvisicam", Noclip = "UniversalNoclip",
  Gravity = "UniversalGravityEnabled",
}
local gravityDefault, gravityValue
local savedOcclusion, savedOcclusionMode = nil, false
local savedCollision = setmetatable({}, { __mode = "k" })
local noclipCharacter
local flyCharacter, flyHumanoid, flyRoot, flyVelocity, flyGyro
local flyPlatformStand, flyAutoRotate
local controls = { Forward = 0, Backward = 0, Left = 0, Right = 0, Up = 0, Down = 0 }
local bindings = {
  [Enum.KeyCode.W] = { "Forward", 1 }, [Enum.KeyCode.S] = { "Backward", -1 },
  [Enum.KeyCode.A] = { "Left", -1 }, [Enum.KeyCode.D] = { "Right", 1 },
  [Enum.KeyCode.E] = { "Up", 1 }, [Enum.KeyCode.Q] = { "Down", -1 },
}

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

local function startInfiniteJump()
  connect("InfiniteJump", UIS.JumpRequest, function()
    if not states.InfiniteJump then return end
    local player = Utils.getLocalPlayer(); local character = player and player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 and not humanoid.Sit then pcall(humanoid.ChangeState, humanoid, Enum.HumanoidStateType.Jumping) end
  end)
  return true
end
local function stopInfiniteJump() disconnect("InfiniteJump"); return true end

local function restoreCollision()
  for part, value in pairs(savedCollision) do
    if part.Parent then pcall(function() part.CanCollide = value end) end
    savedCollision[part] = nil
  end
  noclipCharacter = nil
end
local function applyNoclip()
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  if character ~= noclipCharacter then restoreCollision(); noclipCharacter = character end
  if not character or not character.Parent then return end
  for _, part in ipairs(character:GetDescendants()) do
    if part:IsA("BasePart") then
      if savedCollision[part] == nil then savedCollision[part] = part.CanCollide end
      part.CanCollide = false
    end
  end
end
local function startNoclip() connect("Noclip", RunService.Stepped, applyNoclip); applyNoclip(); return true end
local function stopNoclip() disconnect("Noclip"); restoreCollision(); return true end

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
  local direction = UIS.TouchEnabled and humanoid.MoveDirection
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
  connect("FlyFocus", UIS.WindowFocusReleased, clearControls); connect("FlyStep", RunService.RenderStepped, updateFly); return true
end
local function stopFly() disconnectPrefix("Fly"); clearControls(); detachFly(); return true end

local function startInvisicam()
  local player = Utils.getLocalPlayer(); if not player then return false, "LocalPlayer indisponível" end
  if not savedOcclusionMode then local ok, value = pcall(function() return player.DevCameraOcclusionMode end); if ok then savedOcclusion, savedOcclusionMode = value, true end end
  local ok, errorMessage = pcall(function() player.DevCameraOcclusionMode = Enum.DevCameraOcclusionMode.Invisicam end)
  return ok, ok and nil or tostring(errorMessage)
end
local function stopInvisicam()
  local player = Utils.getLocalPlayer(); if player and savedOcclusionMode then pcall(function() player.DevCameraOcclusionMode = savedOcclusion end) end
  savedOcclusion, savedOcclusionMode = nil, false; return true
end
local function startGravity() Workspace.Gravity = gravityValue; return true end
local function stopGravity() Workspace.Gravity = gravityDefault; return true end
local function lay()
  local player = Utils.getLocalPlayer(); local character = player and player.Character; local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  if not humanoid then return false, "Humanoid indisponível" end
  humanoid.Sit = true
  task.delay(0.1, function()
    if not character.Parent or not humanoid.Parent then return end
    local root = humanoid.RootPart or character:FindFirstChild("HumanoidRootPart"); if root then pcall(function() root.CFrame = root.CFrame * CFrame.Angles(math.pi * 0.5, 0, 0) end) end
    for _, track in ipairs(humanoid:GetPlayingAnimationTracks()) do pcall(track.Stop, track) end
  end)
  return true
end

local starters = { InfiniteJump = startInfiniteJump, Fly = startFly, Invisicam = startInvisicam, Noclip = startNoclip, Gravity = startGravity }
local stoppers = { InfiniteJump = stopInfiniteJump, Fly = stopFly, Invisicam = stopInvisicam, Noclip = stopNoclip, Gravity = stopGravity }

function Universal.setEnabled(feature, enabled)
  if not Utils or not starters[feature] then return false, "recurso inválido" end
  local value = enabled == true; if not Utils.setConfig({ [keys[feature]] = value }) then return false, "configuração rejeitada" end
  if states[feature] == value then if value and feature == "Gravity" then Workspace.Gravity = gravityValue end; return true end
  states[feature] = value
  local ok, result = pcall((value and starters or stoppers)[feature])
  if not ok or result == false then states[feature] = not value; Utils.setConfig({ [keys[feature]] = not value }); return false, tostring(result) end
  return true
end
function Universal.setValue(feature, value)
  if feature ~= "Gravity" or not Utils then return false, "controle inválido" end
  local number = tonumber(value); if not number or number ~= number then return false, "valor inválido" end
  gravityValue = math.clamp(number, 0, 400); local saved = Utils.setConfig({ UniversalGravity = gravityValue }); if states.Gravity then Workspace.Gravity = gravityValue end; return saved
end
function Universal.activate(feature) if feature == "Lay" then return lay() end; return false, "ação inválida" end
function Universal.teardown()
  for feature, enabled in pairs(states) do if enabled and stoppers[feature] then pcall(stoppers[feature]) end; states[feature] = false end
  restoreCollision(); Utils = nil; return true
end
function Universal.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  Universal.teardown(); Utils = deps.Utils; gravityDefault = Workspace.Gravity; gravityValue = tonumber(Utils.getConfigValue("UniversalGravity")) or gravityDefault
  for feature, key in pairs(keys) do states[feature] = Utils.getConfigValue(key) == true end
  for feature, enabled in pairs(states) do if enabled then local ok, errorMessage = Universal.setEnabled(feature, true); if not ok then states[feature] = false; warn("[Exodus Universal] " .. feature .. ": " .. tostring(errorMessage)) end end end
  return true
end

Universal.__config = {
  schema = { UniversalInfiniteJump = "boolean", UniversalFly = "boolean", UniversalFlySpeed = "rate", UniversalInvisicam = "boolean", UniversalNoclip = "boolean", UniversalGravityEnabled = "boolean", UniversalGravity = "rate" },
  defaults = { UniversalInfiniteJump = false, UniversalFly = false, UniversalFlySpeed = 1, UniversalInvisicam = false, UniversalNoclip = false, UniversalGravityEnabled = false, UniversalGravity = 196.2 },
}
Universal.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled", "setValue", "activate" },
}
return Universal
