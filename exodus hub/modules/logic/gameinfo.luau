-- [[ gameinfo ]]

-- module
local GameInfo = {}
local utils, players, world
local ball, searchAt, watching = nil, 0, false
local abilityScript, abilities, replicatorScript, replicator, gameBallScript, gameBall
local lastSync, packet, packetAt, syncReceivedAt = nil, nil, 0, 0
local sampledBall, sampledPosition, sampledAt, measuredVelocity, movedAt
local ballData, dashAnimation
local minimumSpeed, maximumSpeed, speedAt
local errors, cooldownConnection, parriedConnection = {}, nil, nil
local syncConnection, syncRemote, snapshotConnection, snapshotRemote, maintenance = nil, nil, nil, nil, 0
local cooldown, signalAt, heldAt, missingAt, warningAt
local pingSamples, pingIndex, pingSum, pingSampleAt, pingRaw = {}, 0, 0, nil, nil
local targetEvidence = { stable = nil, pending = nil, pendingAt = nil, observedAt = nil }
local targetFrame, targetFrameConnection = 0, nil
local trainingConnection, trainingRemote, trainingState, trainingSequence = nil, nil, nil, 0
local trainingEventConnection, trainingEventRemote
local trainingRound, trainingDespawned, trainingServerTime = 0, false, nil
local trainingDataModule, trainingData

-- configuration
local CONFIG = {
  MIN_SPEED = 16,
  MAX_SPEED = 600,
  PACKET_AGE = 0.5,
  BALL_SEARCH_INTERVAL = 0.5,
  SYNC_CONNECTED_INTERVAL = 3,
  SYNC_RETRY_INTERVAL = 1,
  COOLDOWN_RETRY = 0.5,
  SPAM_MIN_INTERVAL = 0.0301,
  HELD_COOLDOWN_INTERVAL = 0.05,
  CLIENT_DEFLECT_RESET_MIN = 0.08,
  CLIENT_DEFLECT_RESET_FAST = 0.09,
  CLIENT_DEFLECT_RESET_SLOW = 0.15,
  CLIENT_DEFLECT_RESET_MAX_PING_MARGIN = 0.06,
  CLIENT_DEFLECT_RESET_FRAME_MARGIN = 1 / 60,
  SPEED_REFRESH = 0.5,
  SAMPLE_INTERVAL = 1 / 240,
  SAMPLE_MAX_GAP = 0.5,
  WINDOW_BASE = 0.85,
  WINDOW_SPREAD = 0.65,
  RANGE_BASE = 8.5,
  RANGE_BONUS_SPAN = 7.5,
  RANGE_BONUS_STEP = 0.225,
  RANGE_WINDOW_BONUS = 0.12,
  AUTO_PARRY_TRIGGER_PADDING = 1,
  AUTO_PARRY_NETWORK_MARGIN = 0.015,
  AP_WINDOW_LOW_SPEED = 0.45,
  AP_WINDOW_HIGH_SPEED = 0.25,
  PING_SAMPLE_INTERVAL = 0.25,
  PING_SAMPLE_COUNT = 8,
  TARGET_CONFIRM_INTERVAL = 1 / 60,
  TARGET_HOLD_TIME = 0.1,
  GAME_IDS = {
    DEFLECT = 1,
    DASH = 2,
    FIERCE = 19,
    DARK = 20,
    HAUNTER_REMOTE = 9.150098456648103e76,
    COOLDOWN_REMOTE = 5.520474058077904e76,
    PARRIED_REMOTE = 9.611859444202098e76,
    COOLDOWN_EVENT = 5.93848805167512e76,
    COOLDOWN_STOP = 6.60750295352893e76,
    DARK_EVENT = 2.4141700243704228e76,
    MANIFEST_REMOTE = 9.318024238496386e76,
    CRATE_CHECK = 4.702176977990345e76,
    CRATE_OWNED = 1.796923298985336e75,
    CRATE_NEW = 1.0038569313364564e77,
  },
}

minimumSpeed, maximumSpeed, speedAt = CONFIG.MIN_SPEED, CONFIG.MAX_SPEED, 0

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local EMPTY_OPTIONS = {}
local function child(parent, name) return parent and parent:FindFirstChild(name) end
local function report(name, message)
  local time = os.clock()
  if errors[name] and time - errors[name] < 2 then return end
  errors[name] = time; local detail = name .. ": " .. tostring(message)
  if utils and type(utils.recordError) == "function" then utils.recordError("GameInfo", detail) else warn("[GameInfo] " .. detail) end
end
local function load(module, name)
  if not module or not module:IsA("ModuleScript") then error("API externa ausente: TS." .. tostring(name), 2) end
  local result = require(module)
  if type(result) ~= "table" then error("API externa inválida: TS." .. tostring(name) .. " não retornou tabela", 2) end
  return result
end
local function storage() return utils and utils.getReplicatedStorage() end
local function ts() return child(storage(), "Shared") or child(storage(), "TS") end
local function sharedLayout() return child(storage(), "Shared") ~= nil end
local function inTrainingArea()
  local player = players and players.LocalPlayer; local character = player and player.Character
  local root = character and character:FindFirstChild("HumanoidRootPart")
  if not root or not root.Parent then return false end
  local area = child(child(child(world, "Training"), "Areas"), "Zone")
  if not area or not area:IsA("BasePart") then return false end
  local localPos = area.CFrame:PointToObjectSpace(root.Position); local half = area.Size / 2
  if math.abs(localPos.X) > half.X or math.abs(localPos.Y) > half.Y or math.abs(localPos.Z) > half.Z then return false end
  local module = child(child(ts(), "Core"), "GameData")
  if module ~= trainingDataModule then trainingDataModule, trainingData = module, nil end
  if module and not trainingData then
    local ok, result = pcall(load, module, "GameData")
    if ok then trainingData = result.GameData end
  end
  local lives = player:GetAttribute("Lives")
  if trainingData and type(trainingData.GetFallback) == "function" then
    local ok, result = pcall(trainingData.GetFallback, trainingData, player, "Lives", 0)
    if ok then lives = result end
  end
  return not finite(lives) or lives <= 0
end
function GameInfo.isTrainingArea() return inTrainingArea() end
function GameInfo.fireTrainingParry()
  if not inTrainingArea() then return false, "fora da arena de treino" end
  local endpoint = child(child(child(storage(), "Training"), "Remotes"), "Block"); local camera = world.CurrentCamera
  if not endpoint or not endpoint:IsA("RemoteEvent") or not camera then return false, "bloqueio de treino indisponível" end
  endpoint:FireServer(camera.CFrame.Position, camera.CFrame.LookVector); return true
end

-- abilities
local function getAbilities()
  local root = ts(); local module = child(child(root, "Abilities"), "ClientAbilities") or child(root, "ClientAbilities")
  if abilityScript ~= module then abilityScript, abilities = module, nil end
  if not module then return nil end
  if not abilities then
    local value = load(module, "ClientAbilities")
    if type(value.Abilities) ~= "table" then error("API externa ausente: TS.ClientAbilities.Abilities", 2) end
    abilities = value.Abilities
  end
  return abilities
end
local function getAbility(index, method)
  local list = getAbilities(); local ability = list and list[index]
  if ability == nil then return nil end
  if type(ability) ~= "table" or type(ability[method]) ~= "function" then error(("API externa ausente: ClientAbilities[%d].%s"):format(index, method), 2) end
  return ability
end
local function getReplicator()
  local root = ts(); local folder = child(child(root, "Gameplay"), "BallReplicator") or child(root, "BallReplicator")
  local module = folder and (folder:IsA("ModuleScript") and folder or child(folder, "BallReplicator"))
  if module ~= replicatorScript then replicatorScript, replicator = module, nil end
  if not replicator and module then
    local ok, value = pcall(load, module, "BallReplicator")
    if ok then
      if type(value.BallReplicator) == "table" then
        replicator = value.BallReplicator
      elseif value.syncData ~= nil then
        replicator = value
      end
    end
  end
  return replicator
end
local function syncData(provider)
  if provider == nil then provider = getReplicator() end
  if packet and os.clock() - packetAt > CONFIG.PACKET_AGE then packet = nil end
  if packet then
    local sequence = provider and provider.hasState == true and provider.lastSeq
    if type(sequence) ~= "number" or (packet.Sequence ~= sequence and (packet.Sequence - sequence) % 65536 < 32768) then return packet end
    packet = nil
  end
  local data = provider and provider.hasState == true and provider.syncData or lastSync
  if type(data) ~= "table" then data = provider and provider.syncData end
  return type(data) == "table" and data or nil
end

-- targeting
local function targetNumber(value)
  if typeof(value) == "Instance" and value:IsA("Player") then return value.UserId end
  if type(value) == "string" then value = tonumber(value) end
  return finite(value) and value > 0 and value or nil
end
function GameInfo.getBallTargetAttribute() return world:GetAttribute("GameBallTarget") end
local function targetId(data, currentBall)
  local time = os.clock(); local player = players and players.LocalPlayer
  local primary = type(data) == "table" and targetNumber(data.TargetPlayerID) or nil; local attribute = targetNumber(GameInfo.getBallTargetAttribute())
  local highlight = type(data) == "table" and targetNumber(data.HighlightTargetPlayerID) or nil; local character = player and player.Character
  local visual = character and character:FindFirstChild("PlayerBallHighlight"); local visualTargeted = visual ~= nil and visual.Enabled == true
  local color = currentBall and currentBall.Color
  local redBall = typeof(color) == "Color3" and color.R >= 0.65 and color.R > color.G * 1.5 and color.R > color.B * 1.5 or false
  targetEvidence.primary, targetEvidence.attribute, targetEvidence.highlight = primary, attribute, highlight; targetEvidence.visualTargeted, targetEvidence.redBall = visualTargeted, redBall
  if type(data) == "table" and data.Teleported == true then
    targetEvidence.stable, targetEvidence.pending, targetEvidence.pendingAt, targetEvidence.pendingFrame, targetEvidence.observedAt = nil, nil, nil, nil, nil
  end
  local strong = primary
  if strong then
    targetEvidence.stable, targetEvidence.pending, targetEvidence.pendingAt, targetEvidence.pendingFrame, targetEvidence.observedAt =
      strong, nil, nil, nil, time
    targetEvidence.source, targetEvidence.uncertain = "target", false; return strong
  end
  local candidate = highlight or attribute; local source = highlight and "highlight" or (attribute and "attribute" or nil)
  if not candidate and player and (visualTargeted or (type(data) == "table" and data.Targeted == true)) then
    candidate, source = player.UserId, visualTargeted and (redBall and "visual_color" or "visual") or "targeted"
  end
  if candidate then
    if candidate == targetEvidence.stable then
      targetEvidence.observedAt, targetEvidence.pending, targetEvidence.pendingAt, targetEvidence.pendingFrame = time, nil, nil, nil; targetEvidence.source, targetEvidence.uncertain = source, false
    elseif candidate ~= targetEvidence.pending then
      targetEvidence.pending, targetEvidence.pendingAt, targetEvidence.pendingFrame = candidate, time, targetFrame; targetEvidence.uncertain = true
    elseif
      (targetFrameConnection and targetEvidence.pendingFrame ~= targetFrame)
      or (not targetFrameConnection and targetEvidence.pendingAt and time - targetEvidence.pendingAt >= CONFIG.TARGET_CONFIRM_INTERVAL)
    then
      targetEvidence.stable, targetEvidence.observedAt = candidate, time; targetEvidence.pending, targetEvidence.pendingAt, targetEvidence.pendingFrame, targetEvidence.source = nil, nil, nil, source
      targetEvidence.uncertain = false
    end
  else
    targetEvidence.pending, targetEvidence.pendingAt, targetEvidence.pendingFrame = nil, nil, nil; targetEvidence.uncertain = true
  end
  if targetEvidence.stable and targetEvidence.observedAt and time - targetEvidence.observedAt <= CONFIG.TARGET_HOLD_TIME then return targetEvidence.stable end
  targetEvidence.stable, targetEvidence.source, targetEvidence.uncertain = nil, nil, true; return -1
end
local function findBall()
  local candidate = world:FindFirstChild("GameBall") or world:FindFirstChild("GameBall", true)
  if candidate and candidate:IsA("BasePart") then return candidate end
  return nil
end
local function getBall()
  if ball and ball.Parent then return ball end
  if watching and os.clock() < searchAt then return nil end
  ball, searchAt = findBall(), os.clock() + CONFIG.BALL_SEARCH_INTERVAL; return ball
end
local function disconnect(connection)
  if connection then
    if utils and type(utils.untrackGlobal) == "function" then utils.untrackGlobal(connection) end
    connection:Disconnect()
  end
end

-- synchronization
local function validSyncRemote(instance)
  return typeof(instance) == "Instance" and (instance:IsA("RemoteEvent") or instance:IsA("UnreliableRemoteEvent")) and instance.Parent ~= nil
end
local function disconnectSync()
  if syncConnection then
    if utils then utils.untrackGlobal(syncConnection) end
    syncConnection:Disconnect()
  end
  if snapshotConnection then
    if utils then utils.untrackGlobal(snapshotConnection) end
    snapshotConnection:Disconnect()
  end
  syncConnection, syncRemote, snapshotConnection, snapshotRemote = nil, nil, nil, nil
end
local function findSyncRemote()
  local replicated = storage()
  if not replicated then return nil end
  local remotes = replicated:FindFirstChild("Remotes"); local candidate = remotes and remotes:FindFirstChild("BallSyncData")
  if validSyncRemote(candidate) then return candidate end
  candidate = replicated:FindFirstChild("BallSyncData")
  if validSyncRemote(candidate) then return candidate end
  candidate = replicated:FindFirstChild("BallSyncData", true)
  if validSyncRemote(candidate) then return candidate end
  return nil
end
local function resetTrainingBall(despawned)
  trainingRound += 1; trainingState, trainingDespawned = nil, despawned
end
local function bindTrainingSync()
  local remotes = child(child(storage(), "Training"), "Remotes"); local event = child(remotes, "Event")
  if not validSyncRemote(event) then event = nil end
  if trainingEventRemote ~= event or (trainingEventConnection and not trainingEventConnection.Connected) then
    disconnect(trainingEventConnection); trainingEventConnection, trainingEventRemote = nil, event
    resetTrainingBall(false)
  end
  if event and not trainingEventConnection then
    trainingEventConnection = event.OnClientEvent:Connect(function(kind)
      if kind == "BallSpawn" then resetTrainingBall(false) elseif kind == "BallDespawn" or kind == "Kill" then resetTrainingBall(true) end
    end)
    utils.trackGlobal(trainingEventConnection)
  end
  local training = child(remotes, "BallState")
  if not validSyncRemote(training) then training = nil end
  if trainingRemote ~= training or (trainingConnection and not trainingConnection.Connected) then
    disconnect(trainingConnection); trainingConnection, trainingRemote, trainingServerTime = nil, nil, nil
    resetTrainingBall(trainingDespawned)
  end
  if training and not trainingConnection then
    trainingRemote = training
    trainingConnection = training.OnClientEvent:Connect(function(position, velocity, serverTime, goal, target, speed)
      if typeof(position) ~= "Vector3" or typeof(velocity) ~= "Vector3" or not finite(serverTime) then return end
      local receivedAt = os.clock()
      if trainingDespawned or (trainingServerTime and serverTime <= trainingServerTime) then return end
      trainingServerTime = serverTime; trainingSequence = (trainingSequence + 1) % 65536
      trainingState = {
        position = position,
        velocity = velocity,
        serverTime = serverTime,
        goal = goal,
        target = target,
        speed = speed,
        receivedAt = receivedAt,
        sequence = trainingSequence,
        round = trainingRound,
      }

    end)
    utils.trackGlobal(trainingConnection)
  end
end
function GameInfo.bindBallSync(handler)
  if type(handler) ~= "function" then return false end
  bindTrainingSync(); local candidate = findSyncRemote()
  if not candidate then
    if syncRemote and not validSyncRemote(syncRemote) then disconnectSync() end
    return syncConnection ~= nil and syncConnection.Connected == true
  end
  local replicated = storage(); local remotes = replicated and replicated:FindFirstChild("Remotes")
  local snapshotCandidate = remotes and remotes:FindFirstChild("BallSnapshot")
  if not validSyncRemote(snapshotCandidate) then snapshotCandidate = nil end
  if not (syncConnection and syncConnection.Connected and syncRemote == candidate) then
    disconnectSync(); syncConnection, syncRemote = candidate.OnClientEvent:Connect(handler), candidate
    utils.trackGlobal(syncConnection)
  end
  if snapshotRemote ~= snapshotCandidate or (snapshotConnection and not snapshotConnection.Connected) then
    if snapshotConnection then utils.untrackGlobal(snapshotConnection); snapshotConnection:Disconnect() end
    snapshotConnection, snapshotRemote = nil, nil
  end
  if snapshotCandidate and not snapshotConnection then
    snapshotConnection, snapshotRemote = snapshotCandidate.OnClientEvent:Connect(handler), snapshotCandidate; utils.trackGlobal(snapshotConnection)
  end
  return true
end

-- lifecycle
function GameInfo.startMaintenance(options)
  if type(options) ~= "table" or type(options.isActive) ~= "function" then return false end
  maintenance += 1; local token = maintenance
  task.spawn(function()
    while token == maintenance do
      if not options.isActive() or token ~= maintenance then break end
      local linked = type(options.onBallSync) == "function" and GameInfo.bindBallSync(options.onBallSync)
      if token ~= maintenance then break end
      task.wait(linked and CONFIG.SYNC_CONNECTED_INTERVAL or CONFIG.SYNC_RETRY_INTERVAL)
    end
  end)
  return true
end
function GameInfo.stopMaintenance()
  maintenance += 1; disconnectSync()
  disconnect(trainingConnection); disconnect(trainingEventConnection)
  trainingConnection, trainingRemote, trainingServerTime = nil, nil, nil; trainingEventConnection, trainingEventRemote = nil, nil
  resetTrainingBall(false)
  if targetFrameConnection then
    if utils then utils.untrackGlobal(targetFrameConnection) end
    targetFrameConnection:Disconnect(); targetFrameConnection = nil
  end
end
function GameInfo.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
  GameInfo.stopMaintenance(); disconnect(cooldownConnection)
  disconnect(parriedConnection); cooldownConnection, parriedConnection = nil, nil
  utils = deps.Utils; players, world = utils.getPlayers(), utils.getWorkspace()
  if not players or not world then return false, "dependência ausente: Players ou Workspace" end
  ball, searchAt, watching = nil, 0, false; ballData, dashAnimation = nil, nil
  abilityScript, abilities, replicatorScript, replicator, gameBallScript, gameBall = nil, nil, nil, nil, nil, nil; lastSync, packet, packetAt, syncReceivedAt = nil, nil, 0, 0
  sampledBall, sampledPosition, sampledAt, measuredVelocity, movedAt = nil, nil, nil, nil, nil; trainingState, trainingSequence, trainingDataModule, trainingData = nil, 0, nil, nil
  minimumSpeed, maximumSpeed, speedAt = CONFIG.MIN_SPEED, CONFIG.MAX_SPEED, 0; errors = {}
  pingSamples, pingIndex, pingSum, pingSampleAt, pingRaw = {}, 0, 0, nil, nil; targetEvidence = { stable = nil, pending = nil, pendingAt = nil, observedAt = nil }
  targetFrame = 0; local service = utils.getRunService()
  if service and service.Heartbeat then
    targetFrameConnection = service.Heartbeat:Connect(function()
      targetFrame += 1
    end)
    utils.trackGlobal(targetFrameConnection)
  end
  cooldown = {
    known = false,
    active = false,
    rawActive = false,
    lastEventAt = -math.huge,
    lastParriedAt = -math.huge,
  }

  signalAt, heldAt, missingAt, warningAt = 0, 0, nil, 0; GameInfo.getDeflectCooldownState()
  return true
end
function GameInfo.getBall() return getBall() end
function GameInfo.getBallPosition(value) return value.Position end
function GameInfo.getBallVelocity(value) return value.AssemblyLinearVelocity end
function GameInfo.getRootPosition(root) return root.Position end
function GameInfo.getLocalPing() return players.LocalPlayer and players.LocalPlayer:GetNetworkPing() or nil end
function GameInfo.getAveragePing()
  local time = os.clock()
  if pingSampleAt == nil or time < pingSampleAt or time - pingSampleAt >= CONFIG.PING_SAMPLE_INTERVAL then
    pingSampleAt = time; local value = GameInfo.getLocalPing()
    if finite(value) and value >= 0 then
      pingRaw = value
      if #pingSamples < CONFIG.PING_SAMPLE_COUNT then
        pingSamples[#pingSamples + 1] = value
      else
        pingIndex = pingIndex % CONFIG.PING_SAMPLE_COUNT + 1; pingSum -= pingSamples[pingIndex]
        pingSamples[pingIndex] = value
      end
      pingSum += value
    end
  end
  return #pingSamples > 0 and pingSum / #pingSamples or 0, pingRaw, #pingSamples
end
function GameInfo.areAbilitiesEnabled() return world:GetAttribute("CurGamemode") ~= 3 end
function GameInfo.observeAbilityMode(callback)
  return world:GetAttributeChangedSignal("CurGamemode"):Connect(function() callback(GameInfo.areAbilitiesEnabled()) end)
end
local function generatedRemote(id)
  local root = ts(); local remotes = child(child(root, "Network"), "GeneratedNetworkRemotes") or child(root, "GeneratedNetworkRemotes")
  local remote = child(remotes, "RE_" .. tostring(id)); return remote and remote:IsA("RemoteEvent") and remote or nil
end
function GameInfo.getHaunterEvent() return generatedRemote(CONFIG.GAME_IDS.HAUNTER_REMOTE) end
local function playerRoot(id)
  local player = type(id) == "number" and players:GetPlayerByUserId(id); local character = player and player.Character
  local root = character and character:FindFirstChild("HumanoidRootPart")
  if root and root.Parent then return root, character end
  return nil
end
function GameInfo.getPlayerMotion(id)
  local root, character = playerRoot(id)
  if not root then return nil end
  return root.Position, root.AssemblyLinearVelocity, character
end
function GameInfo.getPlayerDistance(id)
  local own = players.LocalPlayer; local ownRoot = own and own.Character and own.Character:FindFirstChild("HumanoidRootPart")
  local otherRoot = playerRoot(id)
  if not ownRoot or not ownRoot.Parent or not otherRoot then return nil end
  return (ownRoot.Position - otherRoot.Position).Magnitude
end
function GameInfo.getDeflectRangeParameters() return CONFIG.RANGE_BASE, CONFIG.RANGE_BONUS_SPAN, sharedLayout() and 0.1125 or CONFIG.RANGE_BONUS_STEP end
function GameInfo.getDeflectRange()
  local player = players.LocalPlayer; local range = player and player:GetAttribute("DeflectRange") or nil
  if sharedLayout() and player and type(GameInfo.getPlayerDeflectRange) == "function" then return GameInfo.getPlayerDeflectRange(player.UserId) end
  return range
end
function GameInfo.getPlayerDeflectRange(id)
  local player = type(id) == "number" and players:GetPlayerByUserId(id)
  if not player then return nil end
  local range = player:GetAttribute("DeflectRange")
  if not finite(range) then return CONFIG.RANGE_BASE end
  range = math.clamp(range, CONFIG.RANGE_BASE, CONFIG.RANGE_BASE + CONFIG.RANGE_BONUS_SPAN)
  if sharedLayout() and range > CONFIG.RANGE_BASE and type(GameInfo.getClashContext) == "function" then
    local context = GameInfo.getClashContext(); local own = players.LocalPlayer
    if context and own and (id == own.UserId or id == context.partnerId) then
      local distance = GameInfo.getPlayerDistance(context.partnerId)
      if finite(distance) and distance <= math.max(20, range + 8) then return CONFIG.RANGE_BASE end
    end
  end
  return range
end
function GameInfo.getPlayerRawRadius(id, speed, includePing)
  local range = GameInfo.getPlayerDeflectRange(id)
  if not range then return nil end
  local latency = includePing and GameInfo.getAveragePing() or 0
  if not finite(latency) or latency < 0 then latency = 0 end
  return range + (finite(speed) and math.max(0, speed) * latency or 0)
end
function GameInfo.getDeflectAbility() return getAbility(CONFIG.GAME_IDS.DEFLECT, "Deflect") end
function GameInfo.getLastDeflectPressAt()
  local ability = GameInfo.getDeflectAbility()
  if not ability then return nil end
  local pressedAt = ability.LastPressClock
  if finite(pressedAt) and pressedAt > 0 then return pressedAt end
  local latest
  if type(ability.ClickInstances) == "table" then
    for _, click in ipairs(ability.ClickInstances) do
      local remaining = type(click) == "table" and click.Time
      if finite(remaining) and remaining > 0 and remaining <= 1 then latest = latest and math.max(latest, remaining) or remaining end
    end
  end
  return latest and (os.clock() - (1 - latest)) or 0
end
function GameInfo.getMinimumSpamInterval() return CONFIG.SPAM_MIN_INTERVAL end
function GameInfo.getAutoSpamDelay()
  local ability = GameInfo.getDeflectAbility()
  if not ability then return nil end
  local time = os.clock(); local last = ability.LastPressClock
  local delay = finite(last) and math.max(0, CONFIG.SPAM_MIN_INTERVAL - (time - last)) or 0; local limit = world:GetAttribute("CPS_LIMIT")
  if not finite(limit) then limit = 50 end
  limit = math.floor(limit)
  if limit <= 0 then return nil end
  local clicks = ability.ClickInstances
  if type(clicks) ~= "table" then return nil end
  if #clicks >= limit then
    local remaining
    for _, click in ipairs(clicks) do
      if type(click) == "table" and finite(click.Time) then remaining = remaining and math.min(remaining, click.Time) or click.Time end
    end
    if not remaining then return nil end
    delay = math.max(delay, remaining > 0 and remaining or 1 / 240)
  end
  return delay
end
function GameInfo.getDashAbility() return getAbility(CONFIG.GAME_IDS.DASH, "Dash") end
function GameInfo.getLocalDashState()
  local ability = GameInfo.getDashAbility()
  if not ability then return false end
  return ability.Dashing == true, tonumber(ability.DashSpeed), tonumber(ability.DashTime)
end
function GameInfo.isPlayerDashing(player)
  if not player then return false end
  if player == players.LocalPlayer then local ability = GameInfo.getDashAbility(); return ability ~= nil and ability.Dashing == true end
  local character = player.Character
  if not character or not character.Parent then return false end
  if character:GetAttribute("IsDashing") == true then return true end
  local humanoid = character:FindFirstChildOfClass("Humanoid"); local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
  if not dashAnimation or not dashAnimation.Parent then
    local replicated = storage(); local animations = replicated and replicated:FindFirstChild("Animations")
    local movement = animations and animations:FindFirstChild("Movement"); dashAnimation = movement and movement:FindFirstChild("Dash")
  end
  if not animator or not dashAnimation or not dashAnimation:IsA("Animation") or dashAnimation.AnimationId == "" then return false end
  for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
    local animation = track.Animation
    if track.IsPlaying and animation and animation.AnimationId == dashAnimation.AnimationId then return true end
  end
  return false
end
function GameInfo.getFierceDeflectAbility() return getAbility(CONFIG.GAME_IDS.FIERCE, "ActivateAndBlock") end
function GameInfo.getDarkSealAbility() return getAbility(CONFIG.GAME_IDS.DARK, "SendEvent") end
function GameInfo.getDeflectServerEvents()
  local first, second = generatedRemote(CONFIG.GAME_IDS.COOLDOWN_REMOTE), generatedRemote(CONFIG.GAME_IDS.PARRIED_REMOTE)
  if not first then return nil end
  return { cooldown = first.OnClientEvent, parried = second and second.OnClientEvent or nil }
end
function GameInfo.decodeDeflectServerEvent(abilityId, eventId, value)
  if abilityId ~= CONFIG.GAME_IDS.DEFLECT then return nil end
  if eventId == CONFIG.GAME_IDS.COOLDOWN_EVENT and finite(value) then return value > 0 and "started" or "reset", math.max(value, 0) end
  if eventId == CONFIG.GAME_IDS.COOLDOWN_STOP then return "stopped", 0 end
  return nil
end
function GameInfo.getHeldDeflectServerCooldown()
  local ability = GameInfo.getDeflectAbility()
  if not ability then return nil end
  local duration, received = ability.HeldServerCooldown, ability.HeldServerCooldownAt
  if finite(duration) and duration > 0 and finite(received) then return duration, received end
  return nil
end
function GameInfo.getDeflectCooldownState()
  local time = os.clock()
  if cooldownConnection and cooldownConnection.Connected == false then
    disconnect(cooldownConnection); cooldownConnection = nil
    cooldown.rawActive, cooldown.endsAt, signalAt = false, nil, 0
  end
  if parriedConnection and parriedConnection.Connected == false then disconnect(parriedConnection); parriedConnection = nil end
  if not cooldownConnection and time >= signalAt then
    signalAt = time + CONFIG.COOLDOWN_RETRY; local signals = GameInfo.getDeflectServerEvents()
    if signals and signals.cooldown then
      cooldownConnection = signals.cooldown:Connect(function(abilityId, eventId, value)
        local kind, duration = GameInfo.decodeDeflectServerEvent(abilityId, eventId, value)
        if not kind then return end
        cooldown.known, cooldown.lastEventAt = true, os.clock(); cooldown.rawActive = kind == "started"
        cooldown.endsAt = cooldown.rawActive and cooldown.lastEventAt + duration or nil
      end)
      utils.trackGlobal(cooldownConnection); missingAt = nil
    else
      missingAt = missingAt or time
      if time - missingAt >= 3 and time >= warningAt then warningAt = time + 10; report("DeflectCooldown", "evento de cooldown do servidor indisponível") end
    end
  end
  if cooldownConnection and not parriedConnection then
    local signals = GameInfo.getDeflectServerEvents()
    if signals and signals.parried then
      parriedConnection = signals.parried:Connect(function()
        cooldown.active, cooldown.rawActive, cooldown.endsAt, cooldown.lastEventAt, cooldown.lastParriedAt = false, false, nil, os.clock(), os.clock()
      end)
      utils.trackGlobal(parriedConnection)
    end
  end
  if not cooldown.rawActive and time >= heldAt then
    heldAt = time + CONFIG.HELD_COOLDOWN_INTERVAL; local duration, received = GameInfo.getHeldDeflectServerCooldown()
    if duration and received and received <= time and time < received + duration and received > cooldown.lastEventAt + 0.01 then
      cooldown.known, cooldown.rawActive, cooldown.lastEventAt, cooldown.endsAt = true, true, received, received + duration
    end
  end
  if cooldown.rawActive and finite(cooldown.endsAt) and time >= cooldown.endsAt then cooldown.rawActive, cooldown.endsAt = false, nil end
  local ability = GameInfo.getDeflectAbility(); local localCooldown = ability and finite(ability.Cooldown) and ability.Cooldown > 0
  if localCooldown then cooldown.known = true end
  local remaining = localCooldown and ability.Cooldown or 0
  if cooldown.rawActive and finite(cooldown.endsAt) then remaining = math.max(remaining, cooldown.endsAt - time) end
  cooldown.remaining = math.max(0, remaining); cooldown.active = cooldown.rawActive or localCooldown == true
  cooldown.blocking = cooldown.active; return cooldown
end
function GameInfo.isClientDeflectResetLate(activatedAt, speed, multiplier)
  if not finite(activatedAt) or not finite(speed) or speed <= 0 then return false end
  local ability = GameInfo.getDeflectAbility()
  if not ability or not finite(ability.Cooldown) or ability.Cooldown <= 0 then return false end
  local time = os.clock(); local pressedAt, predictUntil = ability.PendingPressAt, ability.PendingPredictUntil
  if not finite(pressedAt) or pressedAt < activatedAt or pressedAt > time then return false end
  if not finite(predictUntil) or time >= predictUntil then return false end
  local low, high = GameInfo.getBallSpeedLimits(); local progress = math.clamp((speed - low) / (high - low), 0, 1)
  local budget = CONFIG.CLIENT_DEFLECT_RESET_SLOW + (CONFIG.CLIENT_DEFLECT_RESET_FAST - CONFIG.CLIENT_DEFLECT_RESET_SLOW) * progress; local ping = GameInfo.getAveragePing()
  budget = budget + math.clamp(ping, 0, CONFIG.CLIENT_DEFLECT_RESET_MAX_PING_MARGIN); local lastSafeDelay = predictUntil - pressedAt - CONFIG.CLIENT_DEFLECT_RESET_FRAME_MARGIN
  if lastSafeDelay < CONFIG.CLIENT_DEFLECT_RESET_MIN then return false end
  local extra = finite(multiplier) and math.max(1, multiplier) or 1
  budget *= extra
  return time - pressedAt >= math.min(budget, lastSafeDelay)
end
function GameInfo.getSyncData() return syncData() end
local function syncSequence(current, provider)
  if packet and current == packet then return packet.Sequence end
  return provider and provider.hasState == true and provider.lastSeq or nil
end
function GameInfo.getSyncSequence() return syncSequence(syncData(), getReplicator()) end
function GameInfo.applyPacket(value)
  if type(value) ~= "table" then return false end
  local sequence = value.Sequence
  if not finite(sequence) or sequence < 0 or sequence >= 65536 or sequence % 1 ~= 0 then return false end
  local previous = GameInfo.getSyncSequence()
  if type(previous) == "number" then
    local delta = (sequence - previous) % 65536
    if delta == 0 or delta >= 32768 then return false end
  end
  packet, packetAt = table.clone(value), os.clock(); syncReceivedAt = packetAt
  return true
end
local function decodeBallPacketFallback(value)
  if typeof(value) ~= "buffer" or buffer.len(value) < 92 then return nil end
  local flags = buffer.readu8(value, 0); local serverTime = buffer.readf64(value, 3)
  local x, y, z = buffer.readf32(value, 11), buffer.readf32(value, 15), buffer.readf32(value, 19); local dx, dy, dz = buffer.readf32(value, 23), buffer.readf32(value, 27), buffer.readf32(value, 31)
  local speed, accel, maximum = buffer.readf32(value, 35), buffer.readf32(value, 39), buffer.readf32(value, 43); local curve, curveMax = buffer.readf32(value, 47), buffer.readf32(value, 51)
  local target, highlight, possessor = buffer.readf64(value, 55), buffer.readf64(value, 63), buffer.readf64(value, 83)
  if
    not finite(serverTime)
    or not finite(x)
    or not finite(y)
    or not finite(z)
    or not finite(dx)
    or not finite(dy)
    or not finite(dz)
    or not finite(speed)
    or speed < 0
    or not finite(accel)
    or not finite(maximum)
    or maximum < 0
    or not finite(curve)
    or curve < 0
    or not finite(curveMax)
    or curveMax < 0
    or not finite(target)
    or not finite(highlight)
    or not finite(possessor)
  then
    return nil
  end
  return {
    seq = buffer.readu16(value, 1),
    serverTime = serverTime,
    position = Vector3.new(x, y, z),
    speed = speed,
    targetId = target,
    highlightId = highlight,
    possessorId = possessor,
    teleported = bit32.btest(flags, 1),
    locked = bit32.btest(flags, 2),
    grace = bit32.btest(flags, 4),
    oldGrace = bit32.btest(flags, 8),
    possessed = bit32.btest(flags, 32),
  }
end
function GameInfo.decodeBallPacket(value)
  local ok, provider = pcall(getReplicator)
  local decoded
  if ok and provider and type(provider.Decode) == "function" then
    local success, result = pcall(provider.Decode, provider, value)
    if success then decoded = result else decoded = decodeBallPacketFallback(value) end
  else
    decoded = decodeBallPacketFallback(value)
  end
  if type(decoded) ~= "table" then return nil end
  return {
    Sequence = decoded.seq,
    ServerTime = decoded.serverTime,
    TeleportSequence = decoded.seq,
    Teleported = decoded.teleported,
    Locked = decoded.locked,
    Grace = decoded.grace,
    OldGrace = decoded.oldGrace,
    TargetPlayerID = decoded.targetId,
    HighlightTargetPlayerID = decoded.highlightId,
    PossessorId = decoded.possessed and decoded.possessorId or 0,
    RealPosition = decoded.position,
    Speed = decoded.speed,
  }
end
function GameInfo.getTargetId() return targetId(syncData(), getBall()) end

-- snapshots
local function snapshot(time)
  if inTrainingArea() then
    time = type(time) == "number" and time or utils.now(); local sample = trainingState
    local model = child(child(child(world, "Training"), "TrainingClient"), "TrainingBall")
    if not sample or time < sample.receivedAt or time - sample.receivedAt > 0.6 or not model or not model:IsA("BasePart") or not model.Parent then return nil end
    local age = math.clamp(world:GetServerTimeNow() - sample.serverTime, 0, 0.25); local target = finite(sample.goal) and sample.goal > 0 and sample.goal or -1
    return {
      schema = 2,
      mode = "training",
      ball = model,
      position = sample.position + sample.velocity * age,
      velocity = sample.velocity,
      speed = sample.velocity.Magnitude,
      syncSpeed = sample.speed,
      targetId = target,
      targeted = target == players.LocalPlayer.UserId,
      targetUncertain = false,
      teleported = false,
      locked = false,
      grace = false,
      syncAt = sample.receivedAt,
      serverTime = sample.serverTime,
      syncSequence = sample.sequence,
      trainingRound = sample.round,
    }
  end
  local currentBall = getBall()
  if not currentBall then return nil end
  time = type(time) == "number" and time or utils.now(); local provider = getReplicator()
  local position, velocity, sync = currentBall.Position, currentBall.AssemblyLinearVelocity, syncData(provider or false)
  if sampledBall ~= currentBall or (sync and sync.Teleported == true) then
    sampledBall, sampledPosition, sampledAt, measuredVelocity, movedAt = currentBall, position, time, Vector3.zero, nil
  elseif sampledPosition and sampledAt and time - sampledAt >= CONFIG.SAMPLE_INTERVAL then
    local elapsed = time - sampledAt; local displacement = position - sampledPosition
    if displacement.Magnitude > 0.001 then
      local measured, expected = displacement / elapsed, sync and tonumber(sync.Speed)
      if elapsed <= CONFIG.SAMPLE_MAX_GAP and (not expected or expected <= 0 or measured.Magnitude <= expected * 2.5 + 30) then measuredVelocity, movedAt = measured, time
      else measuredVelocity, movedAt = Vector3.zero, nil end
    elseif movedAt and time - movedAt > 0.1 then
      measuredVelocity = Vector3.zero
    end
    sampledPosition, sampledAt = position, time
  end
  if typeof(velocity) ~= "Vector3" or velocity.Magnitude < 0.1 then velocity = measuredVelocity or Vector3.zero end
  local target = targetId(sync, currentBall)
  return {
    schema = 2,
    generatedAt = time,
    valid = true,
    ball = currentBall,
    ballValid = true,
    position = position,
    velocity = velocity,
    speed = velocity.Magnitude,
    syncSpeed = sync and sync.Speed or nil,
    realPosition = sync and sync.RealPosition or nil,
    syncDirection = sync and sync.ForcedDirection or nil,
    targetId = target,
    targeted = players.LocalPlayer ~= nil and target == players.LocalPlayer.UserId,
    targetSource = targetEvidence.source,
    targetUncertain = targetEvidence.uncertain == true,
    targetSignals = {
      primary = targetEvidence.primary,
      attribute = targetEvidence.attribute,
      highlight = targetEvidence.highlight,
      visualTargeted = targetEvidence.visualTargeted,
      redBall = targetEvidence.redBall,
    },
    teleported = sync and sync.Teleported == true or false,
    locked = sync and sync.Locked == true or false,
    ballCanMove = not (sync and sync.Locked == true),
    grace = sync and sync.Grace == true or false,
    oldGrace = sync and sync.OldGrace == true or false,
    syncAt = syncReceivedAt,
    serverTime = sync and sync.ServerTime or nil,
    syncSequence = syncSequence(sync, provider),
  }
end

-- public-api
function GameInfo.getSnapshot(_, time) return snapshot(time) end
function GameInfo.getSnapshotAt(time) return snapshot(time) end
function GameInfo.isSnapshotValid(value)
  return type(value) == "table"
    and typeof(value.ball) == "Instance"
    and value.ball:IsA("BasePart")
    and typeof(value.position) == "Vector3"
    and typeof(value.velocity) == "Vector3"
    and finite(value.speed)
    and value.speed >= 0
    and type(value.targetId) == "number"
    and type(value.targeted) == "boolean"
end
function GameInfo.applySync(value)
  if type(value) == "table" and type(value.syncData) == "table" then value = value.syncData end
  if type(value) ~= "table" then local provider = getReplicator(); value = provider and provider.syncData end
  if type(value) ~= "table" then return nil end
  lastSync, syncReceivedAt = value, os.clock(); return value
end
function GameInfo.installBallWatcher(track)
  if type(track) ~= "function" then return false, "trackConnection invalido" end
  track((world.DescendantAdded or world.ChildAdded):Connect(function(item)
    if item.Name == "GameBall" and item:IsA("BasePart") then ball = item end
  end))
  track((world.DescendantRemoving or world.ChildRemoved):Connect(function(item)
    if ball == item then ball, searchAt = nil, 0 end
  end))
  ball, watching, searchAt = findBall(), true, os.clock() + CONFIG.BALL_SEARCH_INTERVAL; return true
end
function GameInfo.getBallSpeedLimits()
  local time = os.clock()
  if time < speedAt then return minimumSpeed, maximumSpeed end
  speedAt = time + CONFIG.SPEED_REFRESH; local module = child(child(ts(), "Gameplay"), "GameBall")
  if module ~= gameBallScript then gameBallScript, gameBall = module, nil end
  if not module then return minimumSpeed, maximumSpeed end
  if not gameBall then gameBall = load(module, "GameBall").GameBall end
  if type(gameBall) ~= "table" or type(gameBall.GetBaseSpeed) ~= "function" or type(gameBall.GetMaxSpeed) ~= "function" then
    error("API externa ausente: TS.Gameplay.GameBall.GetBaseSpeed/GetMaxSpeed", 2)
  end
  local low, high = gameBall:GetBaseSpeed(), gameBall:GetMaxSpeed()
  if not finite(low) or not finite(high) or low <= 0 or high <= low then error("API externa inválida: GameBall retornou limites de velocidade inválidos", 2) end
  minimumSpeed, maximumSpeed = low, high; return minimumSpeed, maximumSpeed
end
function GameInfo.getDeflectWindow(speed, includeResilience)
  local low, high = GameInfo.getBallSpeedLimits()
  if not finite(speed) then
    local sync = syncData()
    if sync and finite(sync.Speed) then speed = sync.Speed end
  end
  if not finite(speed) or high <= low then return nil end
  local window = CONFIG.WINDOW_BASE - CONFIG.WINDOW_SPREAD * math.clamp((speed - low) / (high - low), 0, 1); local player = players.LocalPlayer
  local inClash = false
  if gameBall and player and type(gameBall.IsInClash) == "function" then inClash = gameBall:IsInClash(player) == true end
  if inClash and type(gameBall.GetClashMinWindow) == "function" then
    local minimum = gameBall:GetClashMinWindow(speed)
    if finite(minimum) then window = math.max(window, minimum) end
  end
  if includeResilience ~= false and not sharedLayout() then
    local range = GameInfo.getDeflectRange()
    if finite(range) then window += math.clamp((range - CONFIG.RANGE_BASE) / CONFIG.RANGE_BONUS_SPAN, 0, 1) * CONFIG.RANGE_WINDOW_BONUS end
  end
  if inClash and type(gameBall.GetClashWindowScale) == "function" then
    local scale = gameBall:GetClashWindowScale()
    if finite(scale) and scale > 0 then window *= scale end
  end
  return window
end
function GameInfo.getBallFrozen()
  if not ballData or not ballData.Parent then ballData = child(world, "BallData") end
  if not ballData then return nil end
  return ballData:GetAttribute("Frozen") == true
end
function GameInfo.getDeflectGeometry(speed, window, factor, _scaleBase, latencyOverride, options)
  if not finite(speed) or speed < 0 then return nil end
  options = type(options) == "table" and options or EMPTY_OPTIONS; local includeResilience = options.resilience ~= false
  local range = includeResilience and GameInfo.getDeflectRange() or CONFIG.RANGE_BASE
  if not finite(range) or range <= 0 then range = CONFIG.RANGE_BASE end
  if window == "ap" then
    local low, high = GameInfo.getBallSpeedLimits()
    if not finite(low) or not finite(high) or high <= low then return nil end
    local fraction = math.clamp((speed - low) / (high - low), 0, 1); local actual = GameInfo.getDeflectWindow(speed, includeResilience)
    if not finite(actual) then return nil end
    window = math.max(
      0,
      actual
        + (CONFIG.AP_WINDOW_LOW_SPEED - CONFIG.WINDOW_BASE) * (1 - fraction)
        + (CONFIG.AP_WINDOW_HIGH_SPEED - (CONFIG.WINDOW_BASE - CONFIG.WINDOW_SPREAD)) * fraction
    )
  elseif not finite(window) then
    window = GameInfo.getDeflectWindow(speed, includeResilience)
    if finite(window) then local minimum = finite(options.minimumWindow) and math.max(0, options.minimumWindow) or CONFIG.AP_WINDOW_HIGH_SPEED; window = math.max(window, minimum) end
  end
  if not finite(window) or window < 0 then return nil end
  local latency = options.ping == false and 0 or (finite(latencyOverride) and latencyOverride or GameInfo.getAveragePing())
  if not finite(latency) or latency < 0 then latency = 0 end
  factor = finite(factor) and math.max(0, factor) or 1; local base = range
  return {
    fullRadius = base + speed * (window + latency) * factor,
    pureRadius = CONFIG.RANGE_BASE,
    noWindowParryRadius = range,
    resilienceBonus = range - CONFIG.RANGE_BASE,
    pingRadius = speed * latency * factor,
    deflectWindow = window,
    effectiveWindow = (window + latency) * factor,
    leadTime = window + latency,
    windowFactor = factor,
  }
end
function GameInfo.getAutoParryGeometry(speed, factor, frameLead, latencyOverride)
  if not finite(speed) or speed < 0 then return nil end
  local window = GameInfo.getDeflectWindow(speed, true); local range = GameInfo.getDeflectRange()
  if not finite(range) or range <= 0 then range = CONFIG.RANGE_BASE end
  if not finite(window) or window < 0 then return nil end
  local latency = finite(latencyOverride) and math.max(0, latencyOverride) or GameInfo.getAveragePing()
  if not finite(latency) then latency = 0 end
  local factorValue = finite(factor) and math.clamp(factor, 0, 1) or 0.3; local frame = finite(frameLead) and math.clamp(frameLead, 0, 0.15) or 1 / 60
  local networkLead = latency + frame + CONFIG.AUTO_PARRY_NETWORK_MARGIN; local lead = math.min(window + latency, math.max(window * factorValue, networkLead))
  return {
    fullRadius = range + CONFIG.AUTO_PARRY_TRIGGER_PADDING + speed * lead,
    pureRadius = CONFIG.RANGE_BASE,
    noWindowParryRadius = range,
    resilienceBonus = range - CONFIG.RANGE_BASE,
    pingRadius = speed * latency,
    deflectWindow = window,
    effectiveWindow = lead,
    leadTime = lead,
    serverLeadTime = window + latency,
    windowFactor = factorValue,
    triggerPadding = CONFIG.AUTO_PARRY_TRIGGER_PADDING,
    networkLead = networkLead,
    autoParry = true,
  }
end
function GameInfo.getProjectedDeflectRadius(geometry, closingSpeed)
  if type(geometry) ~= "table" or not finite(geometry.noWindowParryRadius) or not finite(geometry.effectiveWindow) or not finite(closingSpeed) then return nil end
  return geometry.noWindowParryRadius + math.max(0, closingSpeed) * geometry.effectiveWindow
end
function GameInfo.isBallWithinDeflectRadius(factor)
  local snapshot = GameInfo.getSnapshotAt()
  if not GameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return false end
  local player = players.LocalPlayer; local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
  if not root or not root.Parent then return false end
  local speed = tonumber(snapshot.syncSpeed)
  if not finite(speed) or speed <= 0 then speed = snapshot.speed end
  if not finite(speed) or speed <= 0 then return false end
  local geometry = GameInfo.getDeflectGeometry(speed, nil, factor, false); return geometry ~= nil and (snapshot.position - root.Position).Magnitude <= geometry.fullRadius
end
function GameInfo.getDarkSealEventId() return CONFIG.GAME_IDS.DARK_EVENT end
function GameInfo.createCrateNetwork()
  local root = ts()
  if not root then error("API externa ausente: Shared ou TS", 2) end
  local network = root:WaitForChild("Network"):WaitForChild("Network"); return require(network).Network.new()
end
function GameInfo.spinCrate(network, crate, guard)
  local owned = network:CSendFunction(CONFIG.GAME_IDS.CRATE_CHECK, crate)
  if type(guard) == "function" and not guard() then return false end
  network:CSendEvent(owned == true and CONFIG.GAME_IDS.CRATE_OWNED or CONFIG.GAME_IDS.CRATE_NEW, crate); return true
end
function GameInfo.getManifestRemote() return generatedRemote(CONFIG.GAME_IDS.MANIFEST_REMOTE) end
function GameInfo.getClashContext()
  local player = players.LocalPlayer
  if not player then return nil end
  local lastAt, by, target = world:GetAttribute("LastParryAt"), world:GetAttribute("LastParryBy"), world:GetAttribute("LastParryTarget")
  if type(lastAt) ~= "number" or type(by) ~= "number" or type(target) ~= "number" then return nil end
  local partnerId = by == player.UserId and target or (target == player.UserId and by or nil)
  if not partnerId or partnerId <= 0 or partnerId == player.UserId then return nil end
  local age, currentTarget = world:GetServerTimeNow() - lastAt, GameInfo.getBallTargetAttribute()
  if age < 0 or (age > 1 and (age > 2.5 or currentTarget ~= target)) then return nil end
  local partner = players:GetPlayerByUserId(partnerId); local ownRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
  local partnerRoot = partner and partner.Character and partner.Character:FindFirstChild("HumanoidRootPart")
  if not ownRoot or not partnerRoot or (ownRoot.Position - partnerRoot.Position).Magnitude > 35 then return nil end
  return { partnerId = partnerId, lastParryAt = lastAt, age = age }
end
function GameInfo.getStatus()
  local now = utils.now(); local value = snapshot(now)
  return {
    schema = utils.apiVersion(),
    generatedAt = now,
    available = value ~= nil,
    targetId = value and value.targetId or -1,
    targeted = value and value.targeted or false,
    speed = value and value.speed or 0,
  }
end

-- contract
GameInfo.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = {
    Utils = {
      "now",
      "apiVersion",
      "getPlayers",
      "getReplicatedStorage",
      "getWorkspace",
      "getRunService",
      "trackGlobal",
      "untrackGlobal",
    },
  },
  provides = {
    "setup",
    "applyPacket",
    "isTrainingArea",
    "fireTrainingParry",
    "getBall",
    "getBallPosition",
    "getBallVelocity",
    "getRootPosition",
    "getLocalPing",
    "getAveragePing",
    "areAbilitiesEnabled",
    "observeAbilityMode",
    "getDeflectRange",
    "getDeflectRangeParameters",
    "getPlayerDeflectRange",
    "getPlayerRawRadius",
    "getPlayerDistance",
    "getPlayerMotion",
    "getHaunterEvent",
    "getDeflectWindow",
    "getDeflectGeometry",
    "getAutoParryGeometry",
    "getProjectedDeflectRadius",
    "isBallWithinDeflectRadius",
    "getBallFrozen",
    "getDeflectAbility",
    "getLastDeflectPressAt",
    "getAutoSpamDelay",
    "getMinimumSpamInterval",
    "getDeflectServerEvents",
    "decodeDeflectServerEvent",
    "getHeldDeflectServerCooldown",
    "getDeflectCooldownState",
    "isClientDeflectResetLate",
    "getDashAbility",
    "getLocalDashState",
    "isPlayerDashing",
    "getFierceDeflectAbility",
    "getDarkSealAbility",
    "getDarkSealEventId",
    "createCrateNetwork",
    "spinCrate",
    "getBallSpeedLimits",
    "getManifestRemote",
    "getClashContext",
    "getStatus",
    "getSnapshot",
    "getSnapshotAt",
    "isSnapshotValid",
    "getSyncData",
    "getSyncSequence",
    "decodeBallPacket",
    "getTargetId",
    "getBallTargetAttribute",
    "applySync",
    "installBallWatcher",
    "bindBallSync",
    "startMaintenance",
    "stopMaintenance",
  },
}

return GameInfo
