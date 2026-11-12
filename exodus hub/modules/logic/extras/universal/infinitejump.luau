-- [[ infinitejump ]]

local InfiniteJump = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalInfiniteJump = "boolean" },
  defaults = { UniversalInfiniteJump = false },
}

local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local states = { InfiniteJump = false }

local connections = {}
local function disconnect(name)
  local connection = connections[name]; connections[name] = nil
  if connection then if Utils then pcall(Utils.untrackGlobal, connection) end; pcall(connection.Disconnect, connection) end
end
local function connect(name, signal, callback)
  disconnect(name); local connection = signal:Connect(callback); connections[name] = connection
  if Utils then Utils.trackGlobal(connection) end; return connection
end

local jumpButton
local lastJump = 0
local function jumpInAir()
  if not states.InfiniteJump then return end
  local player = Utils.getLocalPlayer(); local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  local root = character and character:FindFirstChild("HumanoidRootPart")
  if not humanoid or humanoid.Health <= 0 or humanoid.Sit or not root or humanoid.FloorMaterial ~= Enum.Material.Air then return end
  local now = os.clock(); if now - lastJump < 0.08 then return end; lastJump = now
  local power = humanoid.UseJumpPower and humanoid.JumpPower or math.sqrt(math.max(0, 2 * Workspace.Gravity * humanoid.JumpHeight))
  local velocity = root.AssemblyLinearVelocity
  root.AssemblyLinearVelocity = Vector3.new(velocity.X, power, velocity.Z)
  humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
end
local function attachJumpButton()
  local player = Utils.getLocalPlayer(); local gui = player and player:FindFirstChildOfClass("PlayerGui")
  local interface = gui and gui:FindFirstChild("Interface")
  local mobile = interface and interface:FindFirstChild("MobileUI")
  local buttons = mobile and mobile:FindFirstChild("Buttons")
  local jump = buttons and buttons:FindFirstChild("Jump")
  local button = jump and jump:FindFirstChild("Button")
  if button == jumpButton then return end
  disconnect("GameJump"); jumpButton = button
  if button and button:IsA("GuiButton") then connect("GameJump", button.MouseButton1Down, jumpInAir) end
end
local function startInfiniteJump()
  lastJump = 0; connect("InfiniteJump", UIS.JumpRequest, jumpInAir)
  local player = Utils.getLocalPlayer(); local gui = player and player:FindFirstChildOfClass("PlayerGui")
  if gui then
    connect("JumpGuiAdded", gui.DescendantAdded, function(object)
      if object.Name == "Button" or object.Name == "Jump" or object.Name == "Buttons" or object.Name == "MobileUI" or object.Name == "Interface" then attachJumpButton() end
    end)
    connect("JumpGuiRemoving", gui.DescendantRemoving, function(object) if object == jumpButton then disconnect("GameJump"); jumpButton = nil end end)
  end
  attachJumpButton(); return true
end
local function stopInfiniteJump()
  disconnect("InfiniteJump"); disconnect("GameJump"); disconnect("JumpGuiAdded"); disconnect("JumpGuiRemoving"); jumpButton = nil; return true
end


function InfiniteJump.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  local value = enabled == true
  if not Utils.setConfig({ UniversalInfiniteJump = value }) then return false, "configuração rejeitada" end
  if states.InfiniteJump == value then
    return true
  end
  states.InfiniteJump = value
  local ok, result = pcall(value and startInfiniteJump or stopInfiniteJump)
  if not ok or result == false then states.InfiniteJump = not value; Utils.setConfig({ UniversalInfiniteJump = not value }); return false, tostring(result) end
  return true
end
function InfiniteJump.teardown()
  if states.InfiniteJump then stopInfiniteJump() end
  states.InfiniteJump = false; Utils = nil; return true
end
function InfiniteJump.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  InfiniteJump.teardown(); Utils = deps.Utils
  if Utils.getConfigValue("UniversalInfiniteJump") == true then return InfiniteJump.setEnabled(true) end
  return true
end

InfiniteJump.__config = CONFIG
InfiniteJump.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "trackGlobal", "untrackGlobal" } },
  provides = { "setup", "teardown", "setEnabled" },
}
return InfiniteJump
