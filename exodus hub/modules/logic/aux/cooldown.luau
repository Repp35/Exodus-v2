-- [[ cooldown ]]

-- module
local Cooldown = {}
local utils, gameInfo
local cooldownConnection, parriedConnection, heartbeatConnection, trainingConnection, trainingRemote
local cooldown, signalAt, heldAt, missingAt, warningAt
local deflectAttempt, observedAbility, blockingSince, previousBlocking, cooldownEpisode
local trainingSharedModule, trainingShared, trainingLockoutUntil, trainingAttemptUntil

-- configuration
local CONFIG = {
  COOLDOWN_RETRY = 0.5,
  HELD_COOLDOWN_INTERVAL = 0.05,
  TRAINING_RETRY = 0.5,
  GAME_IDS = {
    DEFLECT = 1,
    COOLDOWN_REMOTE = 5.520474058077904e76,
    PARRIED_REMOTE = 9.611859444202098e76,
    COOLDOWN_EVENT = 5.93848805167512e76,
    COOLDOWN_STOP = 6.60750295352893e76,
  },
}

-- helpers
local nextTrainingAt = 0
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function child(parent, name) return parent and parent:FindFirstChild(name) end
local function disconnect(connection)
  if not connection then return end
  if utils then utils.untrackGlobal(connection) end
  connection:Disconnect()
end
local function report(name, message)
  if utils then utils.recordError("Cooldown", name .. ": " .. tostring(message)) end
end
local function generatedRemote(id)
  local storage = utils and utils.getReplicatedStorage()
  local root = child(storage, "Shared") or child(storage, "TS")
  local remotes = child(child(root, "Network"), "GeneratedNetworkRemotes") or child(root, "GeneratedNetworkRemotes")
  local remote = child(remotes, "RE_" .. tostring(id))
  return remote and remote:IsA("RemoteEvent") and remote or nil
end

-- training cooldown
function Cooldown.getTrainingMissCooldown()
  local storage = utils and utils.getReplicatedStorage(); local module = child(child(storage, "Training"), "TrainingShared")
  if module ~= trainingSharedModule then trainingSharedModule, trainingShared = module, nil end
  if module and not trainingShared and module:IsA("ModuleScript") then
    local ok, value = pcall(require, module)
    if ok and type(value) == "table" then trainingShared = value end
  end
  local duration = trainingShared and trainingShared.MissCooldown
  return finite(duration) and duration > 0 and duration or 1.45
end
function Cooldown.recordTrainingDeflectAttempt(time)
  if finite(time) then trainingAttemptUntil = time + Cooldown.getTrainingMissCooldown() end
end
function Cooldown.getTrainingCooldownState()
  local now = os.clock(); local endsAt = math.max(trainingAttemptUntil or 0, trainingLockoutUntil or 0)
  return { known = trainingAttemptUntil ~= nil or trainingLockoutUntil ~= nil, blocking = now < endsAt,
    remaining = math.max(0, endsAt - now), endsAt = endsAt > 0 and endsAt or nil }
end
local function bindTraining(now)
  local storage = utils.getReplicatedStorage(); local event = child(child(child(storage, "Training"), "Remotes"), "Event")
  if not event or not event:IsA("RemoteEvent") then event = nil end
  if trainingConnection and (trainingConnection.Connected == false or trainingRemote ~= event) then
    disconnect(trainingConnection); trainingConnection, trainingRemote = nil, nil
  end
  if trainingConnection or now < nextTrainingAt then return end
  nextTrainingAt = now + CONFIG.TRAINING_RETRY
  if not event then return end
  trainingRemote = event
  trainingConnection = event.OnClientEvent:Connect(function(kind, value)
    local player = utils.getLocalPlayer()
    if kind == "Parry" and player and value == player.UserId then
      trainingLockoutUntil, trainingAttemptUntil = nil, nil
    elseif kind == "Lockout" then
      local duration = finite(value) and value >= 0 and value or Cooldown.getTrainingMissCooldown()
      trainingLockoutUntil = os.clock() + duration
    end
  end)
  utils.trackGlobal(trainingConnection)
end

-- deflect cooldown
function Cooldown.getDeflectServerEvents()
  local first, second = generatedRemote(CONFIG.GAME_IDS.COOLDOWN_REMOTE), generatedRemote(CONFIG.GAME_IDS.PARRIED_REMOTE)
  if not first and not second then return nil end
  return { cooldown = first and first.OnClientEvent or nil, parried = second and second.OnClientEvent or nil }
end
function Cooldown.decodeDeflectServerEvent(abilityId, eventId, value)
  if abilityId ~= CONFIG.GAME_IDS.DEFLECT then return nil end
  if eventId == CONFIG.GAME_IDS.COOLDOWN_EVENT and finite(value) then return value > 0 and "started" or "reset", math.max(value, 0) end
  if eventId == CONFIG.GAME_IDS.COOLDOWN_STOP then return "stopped", 0 end
  return nil
end
function Cooldown.getHeldDeflectServerCooldown()
  local ability = gameInfo.getDeflectAbility()
  if not ability then return nil end
  local duration, received = ability.HeldServerCooldown, ability.HeldServerCooldownAt
  if finite(duration) and duration > 0 and finite(received) then return duration, received end
  return nil
end
-- The actual prediction deadline is kept by the game's Deflect ability.
function Cooldown.recordDeflectAttempt(pressedAt)
  if not finite(pressedAt) or pressedAt <= 0 then return end
  if deflectAttempt and pressedAt <= deflectAttempt.pressedAt then return end
  deflectAttempt = { pressedAt = pressedAt, missed = false }
end
function Cooldown.getDeflectCooldownState()
  local time = os.clock()
  if cooldownConnection and cooldownConnection.Connected == false then
    disconnect(cooldownConnection); cooldownConnection = nil
    cooldown.rawActive, cooldown.endsAt, cooldown.serverKnown, signalAt = false, nil, false, 0
  end
  if parriedConnection and parriedConnection.Connected == false then
    disconnect(parriedConnection); parriedConnection = nil
  end
  if not cooldownConnection and time >= signalAt then
    signalAt = time + CONFIG.COOLDOWN_RETRY; local signals = Cooldown.getDeflectServerEvents()
    if signals and signals.cooldown then
      cooldownConnection = signals.cooldown:Connect(function(abilityId, eventId, value)
        local kind, duration = Cooldown.decodeDeflectServerEvent(abilityId, eventId, value)
        if not kind then return end
        cooldown.known, cooldown.serverKnown, cooldown.lastEventAt = true, true, os.clock(); cooldown.rawActive = kind == "started"
        if kind == "started" then cooldown.lastStartedAt = cooldown.lastEventAt end
        cooldown.endsAt = cooldown.rawActive and cooldown.lastEventAt + duration or nil
      end)
      utils.trackGlobal(cooldownConnection); missingAt = nil
    else
      missingAt = missingAt or time
      if time - missingAt >= 3 and time >= warningAt then warningAt = time + 10; report("DeflectCooldown", "evento de cooldown do servidor indisponível") end
    end
  end
  if not parriedConnection then
    local signals = Cooldown.getDeflectServerEvents()
    if signals and signals.parried then
      parriedConnection = signals.parried:Connect(function()
        cooldown.active, cooldown.rawActive, cooldown.endsAt, cooldown.lastEventAt, cooldown.lastParriedAt = false, false, nil, os.clock(), os.clock()
      end)
      utils.trackGlobal(parriedConnection)
    end
  end
  if not cooldown.rawActive and time >= heldAt then
    heldAt = time + CONFIG.HELD_COOLDOWN_INTERVAL; local duration, received = Cooldown.getHeldDeflectServerCooldown()
    if duration and received and received <= time and time < received + duration and received > cooldown.lastEventAt + 0.01 then
      cooldown.known, cooldown.serverKnown, cooldown.rawActive, cooldown.lastEventAt, cooldown.endsAt = true, true, true, received, received + duration; cooldown.lastStartedAt = received
    end
  end
  if cooldown.rawActive and finite(cooldown.endsAt) and time >= cooldown.endsAt then cooldown.rawActive, cooldown.endsAt = false, nil end
  local ability = gameInfo.getDeflectAbility()
  if ability ~= observedAbility then
    observedAbility, deflectAttempt, blockingSince, previousBlocking = ability, nil, nil, nil
  end
  local localKnown = ability ~= nil and finite(ability.Cooldown)
  local localRemaining = localKnown and math.max(0, ability.Cooldown) or nil
  local serverRemaining = cooldown.rawActive and finite(cooldown.endsAt) and math.max(0, cooldown.endsAt - time) or 0
  if localKnown then cooldown.known = true end
  -- The client may hold a server cooldown while a predicted parry resets its local value.
  -- Follow the ability's actual local value when available; keep server timing separate.
  local serverKnown = cooldown.serverKnown and cooldownConnection ~= nil and cooldownConnection.Connected ~= false
  if localKnown then
    cooldown.remaining, cooldown.source = localRemaining, "local"
  elseif serverKnown then
    cooldown.remaining, cooldown.source = serverRemaining, "server"
  else
    cooldown.remaining, cooldown.source = nil, "unknown"
  end
  cooldown.active = nil
  if cooldown.remaining ~= nil then cooldown.active = cooldown.remaining > 0 end
  cooldown.blocking = cooldown.active
  cooldown.predictedReset = ability and finite(ability.PredictedResetUntil) and time < ability.PredictedResetUntil or false
  -- ClickInstances also contains rejected clicks made while cooling down. Only
  -- PendingPressAt identifies an accepted local press; other clicks must not
  -- restart the window (especially while AutoSpam is active).
  local pendingAt = ability and ability.PendingPressAt
  local pendingUntil = ability and ability.PendingPredictUntil
  if finite(pendingAt) and pendingAt > 0 and pendingAt <= time then
    Cooldown.recordDeflectAttempt(pendingAt)
  end
  if cooldown.blocking then
    if previousBlocking ~= true then blockingSince = time; cooldownEpisode = (cooldownEpisode or 0) + 1 end
  elseif cooldown.blocking == false then
    if previousBlocking == true then cooldown.lastClearedAt = time end
    blockingSince = nil
  else
    blockingSince = nil
  end
  previousBlocking = cooldown.blocking
  cooldown.blockingSince, cooldown.episode = blockingSince, cooldownEpisode
  local attempt = deflectAttempt
  local pendingOpen = finite(pendingUntil) and pendingUntil > time
  local parried = attempt and finite(cooldown.lastParriedAt) and cooldown.lastParriedAt >= attempt.pressedAt or false
  -- PendingPredictUntil is set and cleared by Deflect itself. A positive local
  -- cooldown after that window closes is the game's miss, regardless of ping.
  local missActive = localKnown and cooldown.blocking == true and not pendingOpen
  if attempt then
    if parried then attempt.missed = false elseif missActive then attempt.missed = true end
  end
  cooldown.pressAt = attempt and attempt.pressedAt or nil
  cooldown.missDeadline = pendingOpen and pendingUntil or nil
  cooldown.miss = not parried and (missActive or (attempt and attempt.missed == true)) or false
  cooldown.outcome = parried and "parried" or (cooldown.miss and "miss" or "pending")
  if parried then cooldown.phase = "reverted"
  elseif cooldown.blocking == true and pendingOpen then cooldown.phase = "reversible"
  elseif cooldown.blocking == true and missActive then cooldown.phase = "miss_cooldown"
  elseif cooldown.predictedReset then cooldown.phase = "predicted_reset"
  elseif cooldown.miss then cooldown.phase = "miss_finished"
  elseif cooldown.blocking == false then cooldown.phase = "ready"
  else cooldown.phase = "unknown" end
  cooldown.localRemaining = localRemaining
  cooldown.serverRemaining = serverRemaining
  return cooldown
end

-- lifecycle
function Cooldown.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes: Utils ou GameInfo" end
  Cooldown.teardown(); utils, gameInfo = deps.Utils, deps.GameInfo
  cooldown = { known = false, active = false, rawActive = false, lastEventAt = -math.huge, lastParriedAt = -math.huge }
  signalAt, heldAt, missingAt, warningAt, nextTrainingAt = 0, 0, nil, 0, 0
  deflectAttempt, observedAbility, blockingSince, previousBlocking, cooldownEpisode = nil, nil, nil, nil, 0
  trainingSharedModule, trainingShared, trainingLockoutUntil, trainingAttemptUntil = nil, nil, nil, nil
  local service = utils.getRunService()
  if not service or not service.Heartbeat then return false, "Heartbeat indisponível" end
  heartbeatConnection = service.Heartbeat:Connect(function()
    local ok, err = pcall(function() bindTraining(os.clock()); Cooldown.getDeflectCooldownState() end)
    if not ok then report("update", err) end
  end)
  utils.trackGlobal(heartbeatConnection)
  bindTraining(os.clock()); Cooldown.getDeflectCooldownState(); return true
end
function Cooldown.teardown()
  disconnect(heartbeatConnection); disconnect(cooldownConnection); disconnect(parriedConnection); disconnect(trainingConnection)
  heartbeatConnection, cooldownConnection, parriedConnection, trainingConnection, trainingRemote = nil, nil, nil, nil, nil
  cooldown, deflectAttempt, observedAbility, blockingSince, previousBlocking, cooldownEpisode = nil, nil, nil, nil, nil, nil
  trainingSharedModule, trainingShared, trainingLockoutUntil, trainingAttemptUntil = nil, nil, nil, nil
  utils, gameInfo = nil, nil
end

-- contract
Cooldown.__contract = {
  requires = { Utils = "utils", GameInfo = "gameinfo" },
  requiresMethods = {
    Utils = { "getRunService", "getReplicatedStorage", "getLocalPlayer", "trackGlobal", "untrackGlobal", "recordError" },
    GameInfo = { "getDeflectAbility" },
  },
  provides = { "setup", "teardown", "getTrainingMissCooldown", "recordTrainingDeflectAttempt", "getTrainingCooldownState", "getDeflectServerEvents", "decodeDeflectServerEvent", "getHeldDeflectServerCooldown", "recordDeflectAttempt", "getDeflectCooldownState" },
}
return Cooldown
