-- [[ auto dash ]]

-- configuration
local CONFIG = {
  DETECTION_RANGE = 70,
  FALLBACK_RANGE = 35,
  MAX_EVENT_AGE = 0.2,
  MIN_UP_SPEED = 68,
  MAX_HORIZONTAL_RATIO = 0.65,
}

-- module
local AutoDash = {}
local utils, gameInfo, dash, movement, autoSpam, players, localPlayer, runService
local root, heartbeat
local inFlight, handledSignals = nil, {}

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function validVector(value) return typeof(value) == "Vector3" and finite(value.X) and finite(value.Y) and finite(value.Z) end

-- event-filtering
local function relevantOpponent(event, localRoot)
  local active = autoSpam.getActivationContext()
  if active.active then return active.partner == event.userId end
  local context = gameInfo.getClashContext()
  if context and context.partnerId then return context.partnerId == event.userId end
  if (event.position - localRoot.Position).Magnitude > CONFIG.FALLBACK_RANGE then return false end
  local snapshot = gameInfo.getSnapshotAt(utils.now())
  if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported or snapshot.locked or snapshot.targetUncertain or snapshot.targetId ~= event.userId then return false end
  local time = utils.now()
  if finite(snapshot.syncAt) and snapshot.syncAt > 0 and (time < snapshot.syncAt or time - snapshot.syncAt > 0.5) then return false end
  local speed = tonumber(snapshot.syncSpeed)
  if not finite(speed) or speed <= 0 then speed = snapshot.speed end
  if not finite(speed) or speed <= 0 then return false end
  local geometry = gameInfo.getDeflectGeometry(speed, "game", 0.8, false); return geometry ~= nil and (snapshot.position - localRoot.Position).Magnitude <= geometry.fullRadius
end

-- event-handling
local function onDash(event)
  local localRoot = root
  if
    not localRoot
    or not localRoot.Parent
    or inFlight
    or not utils.isActive()
    or utils.getConfigValue("AutoClashUpDash") ~= true
    or not gameInfo.areAbilitiesEnabled()
  then
    return
  end
  if
    type(event) ~= "table"
    or event.confirmed ~= true
    or not finite(event.signalAt)
    or not finite(event.detectedAt)
    or not validVector(event.position)
    or not validVector(event.velocity)
  then
    return
  end
  local time = utils.now()
  if not finite(event.userId) or event.userId <= 0 then return end
  if
    time < event.detectedAt
    or time - event.detectedAt > CONFIG.MAX_EVENT_AGE
    or event.userId == localPlayer.UserId
    or handledSignals[event.userId] == event.signalAt
  then
    return
  end
  local player = event.player
  if not player or player.UserId ~= event.userId then return end
  local character = player.Character; local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  local localHumanoid = localRoot.Parent:FindFirstChildOfClass("Humanoid")
  if not humanoid or humanoid.Health <= 0 or not localHumanoid or localHumanoid.Health <= 0 then return end
  if (event.position - localRoot.Position).Magnitude > CONFIG.DETECTION_RANGE then return end
  local velocity = event.velocity; local horizontalSpeed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
  if velocity.Y < CONFIG.MIN_UP_SPEED or horizontalSpeed > velocity.Y * CONFIG.MAX_HORIZONTAL_RATIO then return end
  if not relevantOpponent(event, localRoot) then return end
  local token = {}; inFlight = token
  local ok, result = pcall(movement.upDash)
  if inFlight == token then
    inFlight = nil
    if ok and result == true and root == localRoot then handledSignals[event.userId] = event.signalAt end
  end
  if not ok then warn("[AutoDash] " .. tostring(result)) end
end

-- setup
function AutoDash.setup(deps)
  if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.Dash or not deps.Movement or not deps.AutoSpam then return false, "dependências ausentes" end
  AutoDash.teardown(); utils, gameInfo, dash, movement, autoSpam = deps.Utils, deps.GameInfo, deps.Dash, deps.Movement, deps.AutoSpam
  players, localPlayer, runService = utils.getPlayers(), utils.getLocalPlayer(), utils.getRunService()
  if not players or not localPlayer or not runService then return false, "serviços indisponíveis" end
  dash.setHandler(onDash); return true
end

-- character-binding
function AutoDash.bindCharacter(character)
  AutoDash.detachCharacter(); local newRoot = character and character:FindFirstChild("HumanoidRootPart")
  if not newRoot or not newRoot:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
  root = newRoot
  heartbeat = runService.Heartbeat:Connect(function()
    if not root or not root.Parent then return end
    if not utils.isActive() or utils.getConfigValue("AutoClashUpDash") ~= true or not gameInfo.areAbilitiesEnabled() then return end
    dash.tick(utils.now(), true, root.Position, CONFIG.DETECTION_RANGE)
  end)
  utils.trackCharacter(heartbeat); return true
end
function AutoDash.detachCharacter()
  root, inFlight = nil, nil; table.clear(handledSignals)
  if heartbeat then
    utils.untrackCharacter(heartbeat); heartbeat:Disconnect()
    heartbeat = nil
  end
end
function AutoDash.teardown()
  AutoDash.detachCharacter()
  if dash then dash.setHandler(nil) end
  utils, gameInfo, dash, movement, autoSpam, players, localPlayer, runService = nil, nil, nil, nil, nil, nil, nil, nil
end

-- contract
AutoDash.__contract = {
  requires = {
    Utils = "utils",
    GameInfo = "gameinfo",
    Dash = "dash",
    Movement = "movement",
    AutoSpam = "autospam",
  },
  requiresMethods = {
    Utils = {
      "getPlayers",
      "getLocalPlayer",
      "getRunService",
      "getConfigValue",
      "isActive",
      "now",
      "trackCharacter",
      "untrackCharacter",
    },
    GameInfo = {
      "areAbilitiesEnabled",
      "getClashContext",
      "getSnapshotAt",
      "isSnapshotValid",
      "getDeflectGeometry",
    },
    Dash = { "setHandler", "tick" },
    Movement = { "upDash" },
    AutoSpam = { "getActivationContext" },
  },
  provides = { "setup", "bindCharacter", "detachCharacter", "teardown" },
  bindCharacter = true,
}

return AutoDash
