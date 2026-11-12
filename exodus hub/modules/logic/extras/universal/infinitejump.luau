-- [[ infinitejump ]]

local InfiniteJump = {}
local Utils

-- configuration
local CONFIG = {
  schema = { UniversalInfiniteJump = "boolean" },
  defaults = { UniversalInfiniteJump = false },
}

local UIS = game:GetService("UserInputService")
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
