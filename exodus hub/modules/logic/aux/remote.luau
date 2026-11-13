-- [[ remote ]]

-- module
local Remote = {}
local gameInfo, utils

-- configuration
local CONFIG = {
  PARRY_METHOD = "Deflect",
  DARK_METHOD = "SendEvent",
  FIERCE_METHOD = "ActivateAndBlock",
  DASH_METHOD = "Dash",
}

-- lifecycle
function Remote.setup(deps)
  if type(deps) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependência inválida: GameInfo" end
  if type(deps.Utils) ~= "table" then return false, "dependência inválida: Utils" end
  gameInfo, utils = deps.GameInfo, deps.Utils; return true
end

-- dispatch
local function send(ability, method, ...)
  if ability == nil then return false, method .. " não equipado ou indisponível" end
  local callback = ability[method]
  if type(callback) ~= "function" then error("API externa ausente: habilidade." .. method, 2) end
  local result = callback(ability, ...)
  if result == false then return false, method .. " recusado" end
  return true
end
local function allowed(guard)
  if type(guard) ~= "function" then return true end
  local result = guard(); return result ~= nil and result ~= false
end
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function fireDeflect(ability)
  local clicks = ability.ClickInstances; local beforeClick = type(clicks) == "table" and clicks[#clicks] or nil
  local before = type(clicks) ~= "table" and gameInfo.getLastDeflectPressAt() or nil; local sent, detail = send(ability, CONFIG.PARRY_METHOD)
  if not sent then return false, detail end
  clicks = ability.ClickInstances
  if type(clicks) == "table" then
    if clicks[#clicks] ~= nil and clicks[#clicks] ~= beforeClick then
      if ability.did == nil and _G.did2 == nil then return false, "Remote de Deflect indisponível" end
      return true, detail
    end
    return false, "Deflect não aceito pelo cliente"
  end
  local after = gameInfo.getLastDeflectPressAt()
  if not finite(after) or (finite(before) and after <= before + 0.001) or (not finite(before) and after <= 0) then return false, "Deflect não aceito pelo cliente" end
  return true, detail
end
local function directRemote()
  local env = type(getrenv) == "function" and getrenv() or nil; local globals = type(env) == "table" and rawget(env, "_G")
  local remote = type(globals) == "table" and rawget(globals, "did2") or nil
  if typeof(remote) == "Instance" and remote:IsA("RemoteEvent") then return remote end
  local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes"); local player = game:GetService("Players").LocalPlayer
  remote = remotes and player and (remotes:FindFirstChild("pu_" .. player.UserId) or remotes:FindFirstChild(""))
  if remote and remote:IsA("RemoteEvent") then return remote end
end
local function fireDirect()
  local remote = directRemote()
  if not remote then return false, "Remote de Deflect indisponível" end
  local camera = workspace.CurrentCamera
  if not camera then return false, "Câmera indisponível" end
  local cf = camera.CFrame
  local pos, look = cf.Position, cf.LookVector
  local packet = buffer.create(25); buffer.writeu8(packet, 0, 1)
  buffer.writef32(packet, 1, pos.X); buffer.writef32(packet, 5, pos.Y)
  buffer.writef32(packet, 9, pos.Z); buffer.writef32(packet, 13, look.X)
  buffer.writef32(packet, 17, look.Y); buffer.writef32(packet, 21, look.Z)
  remote:FireServer(packet); return true
end
local keybindObject
local function configuredInput()
  if not keybindObject then
    local storage = game:GetService("ReplicatedStorage"); local shared = storage:FindFirstChild("Shared") or storage:FindFirstChild("TS")
    local core = shared and shared:FindFirstChild("Core"); local module = core and core:FindFirstChild("KeybindObject")
    if module then
      local ok, value = pcall(require, module)
      if ok and type(value) == "table" and type(value.KeybindObject) == "table" then keybindObject = value.KeybindObject end
    end
  end
  if keybindObject then
    local binding = keybindObject:Get("Blocking")
    if binding then
      for _, value in ipairs({ binding.Key, binding.AlternateKey }) do
        if typeof(value) == "EnumItem" and value ~= Enum.KeyCode.Unknown then
          if value.EnumType == Enum.KeyCode then return value end
          if value == Enum.UserInputType.MouseButton2 or value == Enum.UserInputType.MouseButton3 then return value end
        end
      end
    end
  end
  return Enum.UserInputType.MouseButton1
end
local function fireInput()
  local input = configuredInput(); local vim = game:GetService("VirtualInputManager")
  if input.EnumType == Enum.KeyCode then
    vim:SendKeyEvent(true, input, false, game); vim:SendKeyEvent(false, input, false, game)
  else
    local mouse = game:GetService("UserInputService"):GetMouseLocation(); local button = input == Enum.UserInputType.MouseButton2 and 1 or (input == Enum.UserInputType.MouseButton3 and 2 or 0)
    vim:SendMouseButtonEvent(mouse.X, mouse.Y, button, true, game, 0); vim:SendMouseButtonEvent(mouse.X, mouse.Y, button, false, game, 0)
  end
  return true
end

-- public-api
function Remote.fireParry(_flag, guard)
  if not gameInfo then return false, "Remote não inicializado" end
  local method = utils.getConfigValue("ClickMethod")
  if method == "Input" then
    if not allowed(guard) then return false, "Deflect cancelado" end
    return fireInput()
  end
  if gameInfo.isTrainingArea() then
    if not allowed(guard) then return false, "Deflect cancelado" end
    local sent, detail = gameInfo.fireTrainingParry(); return sent, detail
  end
  if not allowed(guard) then return false, "Deflect cancelado" end
  if method == "Direct" then return fireDirect() end
  local ability = gameInfo.getDeflectAbility()
  if not ability then return false, "Deflect indisponível" end
  return fireDeflect(ability)
end
function Remote.fireDark(eventId, cameraFrame) return send(gameInfo and gameInfo.getDarkSealAbility(), CONFIG.DARK_METHOD, eventId, cameraFrame) end
function Remote.fireFierce(guard)
  local ability = gameInfo and gameInfo.getFierceDeflectAbility()
  if not allowed(guard) then return false, "Fierce cancelado" end
  return send(ability, CONFIG.FIERCE_METHOD)
end
function Remote.fireDash() return send(gameInfo and gameInfo.getDashAbility(), CONFIG.DASH_METHOD) end

-- contract
Remote.__contract = {
  requires = { GameInfo = "gameinfo", Utils = "utils" },
  requiresMethods = {
    Utils = { "getConfigValue" },
    GameInfo = {
      "isTrainingArea",
      "fireTrainingParry",
      "getDeflectAbility",
      "getLastDeflectPressAt",
      "getDarkSealAbility",
      "getFierceDeflectAbility",
      "getDashAbility",
    },
  },
  provides = {
    "setup",
    "fireParry",
    "fireDark",
    "fireFierce",
    "fireDash",
  },
}

return Remote
