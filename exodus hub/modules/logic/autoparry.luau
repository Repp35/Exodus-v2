-- [[ autoparry ]]

-- module
local AutoParry = {}
local utils, gameInfo, remote
local state = {
  phase = "detached",
  reason = "initial",
  generation = 0,
  lifeGeneration = 0,
  alive = false,
  bound = false,
  player = nil,
  character = nil,
  root = nil,
  connections = {},
  fired = false,
  awaySeen = false,
  cycle = 0,
  target = -1,
  targetKnown = false,
  lastTargeted = false,
  teleported = false,
  teleportSequence = nil,
  sequence = nil,
  mode = nil,
  lastBall = nil,
  speed = 0,
  distance = 0,
  approaching = false,
  closingSpeed = 0,
  frameAllowance = 0,
  triggerDistance = 0,
  ping = 0,
  pingRaw = nil,
  pingCount = 0,
  lastFireAt = 0,
  lastErrorAt = -math.huge,
  clicks = {},
  returns = {},
  autoParryCps = 0,
  lastAutoParryClickAt = nil,
  windowFactor = 0.3,
  awayAt = nil,
  awayTarget = nil,
  trainingRound = nil,
  trainingBall = nil,
  trainingLastValidAt = 0,
  trainingLastServerTime = nil,
  trainingConfirmedAt = nil,
  nextAttemptAt = 0,
  lastPosition = nil,
  lastSampleAt = 0,
  resetPending = false,
  retryPending = false,
  retryCooldownSeen = false,
  retryReady = false,
}

-- configuration
local CONFIG = {
  DEFAULT_WINDOW_FACTOR = 0.3,
  MAX_WINDOW_FACTOR = 0.35,
  MATCH_RETRY_DELAY_MAX = 0.5,
  RETRY_WINDOW_FACTOR = 0.12,
  PRESSURE_SAMPLE_LIMIT = 100,
  PRESSURE_WINDOW = 3,
  TARGET_SEQUENCE_MODULUS = 65536,
  TARGET_SEQUENCE_HALF = 32768,
  MIN_PARRY_SPEED = 16,
  FRAME_BASE = 1 / 60,
  MAX_FRAME_ALLOWANCE = 0.12,
  TRAINING_BASE_SPEED = 16,
  TRAINING_MAX_SPEED = 600,
  TRAINING_DEFLECT_DISTANCE = 8.5,
  TRAINING_TRIGGER_PADDING = 2,
  TRAINING_MAX_PING = 0.25,
  TRAINING_WINDOW_FACTOR = 0.3,
  TRAINING_MAX_LEAD_FACTOR = 0.8,
  TRAINING_MIN_SPEED = 1,
  TRAINING_MIN_CLOSING_SPEED = 1,
  TRAINING_WINDOW_SLOW = 0.85,
  TRAINING_WINDOW_FAST = 0.2,
}

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function vector(value) return typeof(value) == "Vector3" end
local function clock() return os.clock() end
local function phase(value, reason)
  if state.phase == value and state.reason == reason then return end
  local previous = state.phase; state.phase, state.reason = value, reason
  if previous ~= value and utils and type(utils.recordTransition) == "function" then utils.recordTransition("AutoParry", previous, value, reason) end
end
local function track(connection)
  state.connections[#state.connections + 1] = connection; utils.trackCharacter(connection)
end
local function disconnect()
  for i = #state.connections, 1, -1 do
    local connection = state.connections[i]
    if utils then utils.untrackCharacter(connection) end
    connection:Disconnect(); state.connections[i] = nil
  end
end

-- lifecycle
local function resetTracking()
  state.fired, state.awaySeen, state.cycle = false, false, 0; state.target, state.targetKnown, state.lastTargeted = -1, false, false
  state.teleported, state.teleportSequence, state.sequence = false, nil, nil; state.mode = nil
  state.lastBall, state.speed, state.distance, state.approaching = nil, 0, 0, false; state.closingSpeed, state.triggerDistance, state.frameAllowance = 0, 0, 0
  state.ping, state.pingRaw, state.pingCount, state.lastFireAt = 0, nil, 0, 0; state.autoParryCps, state.lastAutoParryClickAt, state.windowFactor = 0, nil, CONFIG.DEFAULT_WINDOW_FACTOR
  state.awayAt, state.awayTarget = nil, nil; state.trainingLastValidAt, state.trainingLastServerTime = 0, nil
  state.trainingRound, state.trainingBall, state.trainingConfirmedAt = nil, nil, nil; state.nextAttemptAt = 0
  state.lastPosition, state.lastSampleAt = nil, 0; state.resetPending = false
  state.retryPending, state.retryCooldownSeen, state.retryReady = false, false, false; table.clear(state.clicks)
  table.clear(state.returns)
end
local function detach(reason)
  state.generation += 1; disconnect()
  state.lifeGeneration += 1; state.alive, state.bound, state.character, state.root = false, false, nil, nil
  resetTracking(); phase("detached", reason)
end

-- geometry
local function rangeBonus()
  if not state.alive or not state.bound then return 0 end
  local _, cap = gameInfo.getDeflectRangeParameters(); local g = gameInfo.getDeflectGeometry(0, 0, 0, false, 0)
  return g and math.clamp(g.resilienceBonus, 0, cap) or 0
end
local function resilience()
  local bonus = rangeBonus(); local _, cap, step = gameInfo.getDeflectRangeParameters()
  return {
    stack = math.floor(bonus / step + 0.5),
    size = bonus,
    perParry = step,
    cap = cap,
    maxStack = math.ceil(cap / step),
    source = "DeflectRange",
  }
end
local function configuredFactor()
  local factor = utils and tonumber(utils.getConfigValue("AutoParryWindowFactor")); return finite(factor) and math.clamp(factor, 0, CONFIG.MAX_WINDOW_FACTOR) or CONFIG.DEFAULT_WINDOW_FACTOR
end
local function activeWindowFactor()
  state.windowFactor = math.clamp(configuredFactor(), 0, CONFIG.MAX_WINDOW_FACTOR); return state.windowFactor
end
local function recordAutoParryRequest()
  local now, previous = clock(), state.lastAutoParryClickAt; local interval = previous and now - previous or nil
  state.autoParryCps = finite(interval) and interval > 0 and 1 / interval or 0; state.lastAutoParryClickAt, state.windowFactor = now, math.clamp(configuredFactor(), 0, CONFIG.MAX_WINDOW_FACTOR)
end
local function trainingGeometry(speed, factor)
  speed = finite(speed) and math.max(speed, CONFIG.TRAINING_BASE_SPEED) or CONFIG.TRAINING_BASE_SPEED; local span = CONFIG.TRAINING_MAX_SPEED - CONFIG.TRAINING_BASE_SPEED
  local progress = span > 0 and math.clamp((speed - CONFIG.TRAINING_BASE_SPEED) / span, 0, 1) or 1
  local blockWindow = CONFIG.TRAINING_WINDOW_SLOW + (CONFIG.TRAINING_WINDOW_FAST - CONFIG.TRAINING_WINDOW_SLOW) * progress; local deflectDistance = CONFIG.TRAINING_DEFLECT_DISTANCE
  factor = finite(factor) and math.clamp(factor, 0, CONFIG.TRAINING_MAX_LEAD_FACTOR) or activeWindowFactor(clock())
  local effectiveWindow = blockWindow * factor
  return {
    fullRadius = deflectDistance + speed * effectiveWindow + CONFIG.TRAINING_TRIGGER_PADDING,
    pureRadius = deflectDistance,
    noWindowParryRadius = deflectDistance,
    resilienceBonus = 0,
    pingRadius = 0,
    deflectWindow = blockWindow,
    effectiveWindow = effectiveWindow,
    leadTime = blockWindow,
    windowFactor = factor,
    triggerPadding = CONFIG.TRAINING_TRIGGER_PADDING,
    training = true,
  }
end
local function radius(speed, factor, baseWindow)
  speed = finite(speed) and math.max(speed, 0) or 0
  if state.mode == "training" then return trainingGeometry(speed, factor) end
  factor = tonumber(factor)
  if not finite(factor) then factor = activeWindowFactor(clock()) end
  factor = math.clamp(factor, 0, CONFIG.MAX_WINDOW_FACTOR)
  if type(gameInfo.getAutoParryGeometry) == "function" then return gameInfo.getAutoParryGeometry(speed, factor, CONFIG.FRAME_BASE + state.frameAllowance, state.ping) end
  return gameInfo.getDeflectGeometry(speed, baseWindow or "ap", factor, false, state.ping)
end

-- telemetry
local function samplePing()
  state.ping, state.pingRaw, state.pingCount = gameInfo.getAveragePing()
end
local function appendRecent(list, item)
  list[#list + 1] = item
  if #list > CONFIG.PRESSURE_SAMPLE_LIMIT then table.remove(list, 1) end
end
local function trajectory(position, velocity, rootPosition, nominalSpeed, geometry)
  local delta = rootPosition - position; local distance = delta.Magnitude
  local magnitude = velocity.Magnitude; local closing = 0
  if distance > 0 and magnitude > 0 then
    closing = velocity:Dot(delta) / distance
    if finite(nominalSpeed) and nominalSpeed > 0 then closing = math.min(closing, nominalSpeed * 1.1) end
  end
  if not finite(closing) then closing = 0 end
  local threshold = gameInfo.getProjectedDeflectRadius(geometry, closing) or geometry.noWindowParryRadius; threshold += finite(geometry.triggerPadding) and math.max(0, geometry.triggerPadding) or 0
  return distance, closing, threshold
end

-- target-sync
local function sequenceOrder(incoming)
  if not finite(incoming) or incoming < 0 or incoming >= CONFIG.TARGET_SEQUENCE_MODULUS or incoming % 1 ~= 0 then return nil end
  if state.sequence == nil then return "new" end
  local delta = (incoming - state.sequence) % CONFIG.TARGET_SEQUENCE_MODULUS
  if delta == 0 then return "same" end
  return delta < CONFIG.TARGET_SEQUENCE_HALF and "new" or "old"
end
local function observeTarget(target, time)
  if not state.player or not finite(target) then return end
  if target <= 0 then
    if state.targetKnown and state.target == state.player.UserId then state.awaySeen, state.awayAt, state.awayTarget = true, time, nil end
    state.target, state.targetKnown = -1, false; return
  end
  if target == state.target and state.targetKnown then return end
  local me, previous = state.player.UserId, state.target; state.lastTargeted = previous == me
  if previous == me and target > 0 and target ~= me then
    state.awaySeen = true; state.awayAt = time
    state.awayTarget = target > 0 and target or nil; state.nextAttemptAt = 0
  elseif target == me and previous ~= me and state.awaySeen then
    if state.awayAt and state.awayTarget == previous and time >= state.awayAt then appendRecent(state.returns, { at = time, interval = time - state.awayAt }) end
    state.fired, state.awaySeen = false, false; state.nextAttemptAt = 0
    state.retryPending, state.retryCooldownSeen, state.retryReady = false, false, false; state.cycle += 1
    state.awayAt, state.awayTarget = nil, nil
  end
  state.target, state.targetKnown = target, true
end
local function observeSnapshot(snapshot, time)
  if snapshot.targetUncertain == true then return false end
  local mode = snapshot.mode == "training" and "training" or "match"
  local newTrainingBall = mode == "training" and (snapshot.trainingRound ~= state.trainingRound or snapshot.ball ~= state.trainingBall)
  local newMatchBall = mode == "match" and state.lastBall ~= nil and state.lastBall ~= snapshot.ball
  if state.mode ~= mode or newTrainingBall or newMatchBall then
    state.cycle += 1; state.trainingRound, state.trainingBall = nil, nil
    if mode == "training" then
      state.trainingRound, state.trainingBall = snapshot.trainingRound, snapshot.ball; state.lastBall = nil
      state.speed, state.distance, state.approaching = 0, 0, false; state.closingSpeed, state.triggerDistance = 0, 0
    end
    state.mode, state.sequence, state.target, state.targetKnown = mode, nil, -1, false; state.fired, state.awaySeen, state.teleported, state.teleportSequence = false, false, false, nil
    state.awayAt, state.awayTarget = nil, nil; state.trainingLastValidAt, state.trainingLastServerTime, state.trainingConfirmedAt = 0, nil, nil
    state.nextAttemptAt = 0; state.lastPosition, state.lastSampleAt = nil, 0
    state.resetPending = newMatchBall; state.retryPending, state.retryCooldownSeen, state.retryReady = false, false, false
  end
  local order = sequenceOrder(snapshot.syncSequence)
  if order == "old" then return false end
  if order == "new" then state.sequence = snapshot.syncSequence end
  observeTarget(snapshot.targetId, time); return true
end

-- parry
local function safeCooldown()
  local ok, value = pcall(gameInfo.getDeflectCooldownState); return ok and type(value) == "table" and value or nil
end
local function request(reason)
  local now = clock(); local redirectReturn = reason == "redirect_return"
  if
    now < state.nextAttemptAt
    or state.fired
    or not state.player
    or (not redirectReturn and (not state.targetKnown or state.target ~= state.player.UserId))
  then
    return false
  end
  local generation, cycle = state.generation, state.cycle; local boundUtils, boundRemote = utils, remote
  local firedAt, speed, distance = now, state.speed, state.distance; state.fired, state.lastFireAt = true, firedAt
  local wasRetry = state.retryReady; state.retryPending, state.retryCooldownSeen, state.retryReady = false, false, false
  local function sameCycle()
    return state.generation == generation
      and state.cycle == cycle
      and utils == boundUtils
      and remote == boundRemote
      and state.alive
      and state.bound
      and state.fired
      and state.player ~= nil
      and (redirectReturn or (state.targetKnown and state.target == state.player.UserId))
  end
  local function allowed()
    return sameCycle()
      and not state.teleported
      and boundUtils.isActive()
      and (state.mode == "training" or not boundUtils.isSpamActive())
      and (reason == "manual_parry" or boundUtils.getConfigValue("AutoParry") ~= false)
  end
  local ok, sent, detail = pcall(boundRemote.fireParry, 1, allowed)
  if not ok then detail, sent = sent, false end
  if not sameCycle() then return false end
  if sent ~= true then
    if state.mode == "training" then
      state.fired = false; state.nextAttemptAt = clock() + CONFIG.FRAME_BASE
      phase("waiting", "training_attempt_failed"); local errorAt = clock()
      if errorAt - state.lastErrorAt >= 1 then state.lastErrorAt = errorAt; boundUtils.recordError("TrainingParry", tostring(detail or "Treino indisponível")) end
      return false
    end
    state.fired = false; state.retryReady = wasRetry
    local delay = 0.05
    if type(gameInfo.getAutoSpamDelay) == "function" then
      local delayOk, value = pcall(gameInfo.getAutoSpamDelay)
      if delayOk and finite(value) then delay = math.max(delay, value) end
    end
    local cooldown = safeCooldown()
    if cooldown and finite(cooldown.remaining) then delay = math.max(delay, cooldown.remaining) end
    state.nextAttemptAt = clock() + math.clamp(delay, 0.03, CONFIG.MATCH_RETRY_DELAY_MAX); phase("waiting", "parry_attempt_failed")
    local errorAt = clock()
    if errorAt - state.lastErrorAt >= 1 then state.lastErrorAt = errorAt; boundUtils.recordError("AutoParry", tostring(detail or "Deflect indisponível")) end
    return false
  end
  state.nextAttemptAt = 0; recordAutoParryRequest()
  if state.mode == "training" then gameInfo.recordTrainingDeflectAttempt(firedAt) else state.retryPending = true; gameInfo.recordDeflectAttempt(firedAt, speed) end
  local factor = activeWindowFactor(firedAt)
  if factor > 0 then
    local geometry = radius(speed, factor)
    if geometry then
      local denominator = speed * math.max(geometry.leadTime or geometry.effectiveWindow or 0, 0)
      local used = denominator > 0 and math.clamp((distance - geometry.noWindowParryRadius) / denominator, 0, factor) or factor
      appendRecent(state.clicks, { at = firedAt, factor = used, configured = factor, speed = speed })
    end
  end
  phase("fired", reason); return true
end
local function tickTraining(value, root, time)
  local position, velocity, rootPosition = value.position, value.velocity, gameInfo.getRootPosition(root)
  if not vector(position) or not vector(velocity) or not vector(rootPosition) then return end
  local syncSpeed = tonumber(value.syncSpeed); local speed = finite(syncSpeed) and syncSpeed > 0 and syncSpeed or velocity.Magnitude
  if not finite(speed) or speed < CONFIG.TRAINING_MIN_SPEED then
    state.approaching, state.closingSpeed, state.triggerDistance = false, 0, 0; phase("waiting", "training_speed_unavailable")
    return
  end
  samplePing(); local geometry = trainingGeometry(speed, CONFIG.TRAINING_WINDOW_FACTOR)
  local delta = rootPosition - position; local distance = delta.Magnitude
  local closing = distance > 0 and velocity:Dot(delta) / distance or 0
  if not finite(closing) then closing = 0 end
  local ping = finite(state.ping) and math.clamp(state.ping, 0, CONFIG.TRAINING_MAX_PING) or 0
  local lead = math.min(geometry.deflectWindow * CONFIG.TRAINING_MAX_LEAD_FACTOR, geometry.effectiveWindow + ping + CONFIG.FRAME_BASE + state.frameAllowance)
  local threshold = geometry.noWindowParryRadius + CONFIG.TRAINING_TRIGGER_PADDING + math.max(0, closing) * lead
  state.lastBall, state.speed, state.distance, state.approaching = value.ball, speed, distance, closing > 0; state.closingSpeed, state.triggerDistance = closing, threshold
  state.trainingLastValidAt, state.trainingLastServerTime = time, value.serverTime; local confirmed = value.trainingParryAt
  if
    state.fired
    and finite(confirmed)
    and confirmed ~= state.trainingConfirmedAt
    and finite(value.serverTime)
    and value.serverTime > confirmed
    and value.targetId == state.player.UserId
    and closing >= CONFIG.TRAINING_MIN_CLOSING_SPEED
  then
    state.fired, state.awaySeen, state.trainingConfirmedAt, state.retryReady = false, false, confirmed, false; state.cycle += 1
    state.nextAttemptAt = 0
  end
  if
    state.fired
    and gameInfo.getTrainingCooldownState().blocking ~= true
    and (not finite(confirmed) or confirmed == state.trainingConfirmedAt)
    and value.targetId == state.player.UserId
    and closing >= CONFIG.TRAINING_MIN_CLOSING_SPEED
  then
    state.fired, state.nextAttemptAt, state.retryReady = false, 0, true
  end
  if state.retryReady then threshold = geometry.noWindowParryRadius + math.max(0, closing) * geometry.deflectWindow * CONFIG.RETRY_WINDOW_FACTOR; state.triggerDistance = threshold end
  if state.fired then phase("waiting", "training_awaiting_return"); return end
  if finite(confirmed) then state.trainingConfirmedAt = confirmed end
  if gameInfo.getTrainingCooldownState().blocking then phase("waiting", "training_lockout"); return end
  if not state.player or value.targetId ~= state.player.UserId then phase("waiting", "training_not_target"); return end
  if closing < CONFIG.TRAINING_MIN_CLOSING_SPEED then phase("waiting", "training_not_approaching"); return end
  if distance > threshold then phase("waiting", "training_outside_window"); return end
  request("training_parry")
end
local function resolveVelocity(value, position, speed, time)
  local velocity = vector(value.velocity) and value.velocity or Vector3.zero
  if velocity.Magnitude > 0.1 then return velocity end
  if state.lastBall == value.ball and vector(state.lastPosition) and state.lastSampleAt > 0 then
    local elapsed = time - state.lastSampleAt
    if elapsed > 0 and elapsed <= 0.25 then
      local measured = (position - state.lastPosition) / elapsed
      if measured.Magnitude > 0.1 then return measured end
    end
  end
  if finite(speed) and speed > 0 and vector(value.syncDirection) and value.syncDirection.Magnitude > 0.01 then return value.syncDirection.Unit * speed end
  return velocity
end
local function tick(character, root, generation)
  if generation ~= state.generation or not state.alive or not state.bound or not character.Parent or not root.Parent then return end
  if not utils.isActive() or utils.getConfigValue("AutoParry") == false then return end
  local time = clock(); local value = gameInfo.getSnapshotAt(time)
  if generation ~= state.generation or not state.bound or not state.alive then return end
  if not gameInfo.isSnapshotValid(value) then phase("waiting", "snapshot_indisponível"); return end
  if not observeSnapshot(value, time) then phase("waiting", "stale_snapshot"); return end
  if value.mode ~= "training" and utils.isSpamActive() then phase("waiting", "spam_active"); return end
  if state.teleported or value.teleported then
    state.lastPosition, state.lastSampleAt = nil, 0; phase("waiting", "teleport_lock")
    return
  end
  if value.mode == "training" then tickTraining(value, root, time); return end
  local cooldown = safeCooldown()
  if state.fired and state.retryPending and cooldown then
    if finite(cooldown.lastParriedAt) and cooldown.lastParriedAt >= state.lastFireAt then
      state.retryPending = false
    elseif
      cooldown.missConfirmed == true
      and finite(cooldown.pressAt)
      and cooldown.pressAt >= state.lastFireAt - 0.05
      and cooldown.blocking ~= true
      and cooldown.predictedReset ~= true
    then
      state.fired, state.retryPending, state.retryCooldownSeen, state.retryReady, state.nextAttemptAt = false, false, false, true, 0
    end
  end
  if state.fired then phase("waiting", "target_already_parried"); return end
  if cooldown and cooldown.blocking == true then phase("waiting", "deflect_cooldown"); return end
  if value.locked == true then
    state.approaching, state.closingSpeed, state.triggerDistance = false, 0, 0; phase("waiting", "ball_locked")
    return
  end
  local position, rootPosition = value.position, gameInfo.getRootPosition(root)
  if not vector(position) or not vector(rootPosition) then return end
  if not value.ball.Parent then return end
  local syncSpeed = tonumber(value.syncSpeed); local speed = finite(syncSpeed) and syncSpeed > 0 and syncSpeed or tonumber(value.speed) or 0
  if state.resetPending then
    local real = value.realPosition; local tolerance = math.max(6, math.max(speed, 0) * 0.15)
    if not vector(real) or (position - real).Magnitude > tolerance then
      state.lastPosition, state.lastSampleAt = nil, 0; phase("waiting", "reset_position_pending")
      return
    end
    state.resetPending = false
  end
  local velocity = resolveVelocity(value, position, speed, time); state.lastBall, state.lastPosition, state.lastSampleAt = value.ball, position, time
  if value.targetUncertain == true then phase("waiting", "target_uncertain"); return end
  if not state.player or value.targetId ~= state.player.UserId then phase("waiting", "not_target"); return end
  samplePing(); local geometry = radius(speed, activeWindowFactor(time))
  if not geometry then return end
  if state.retryReady then geometry.effectiveWindow = math.min(geometry.effectiveWindow, geometry.deflectWindow * CONFIG.RETRY_WINDOW_FACTOR); geometry.triggerPadding = 0 end
  local distance, closing, threshold = trajectory(position, velocity, rootPosition, speed, geometry); state.speed, state.distance, state.approaching = speed, distance, closing > 0
  state.closingSpeed, state.triggerDistance = closing, threshold
  if closing > 0 and distance <= threshold then request("parry_requested") end
end

-- public-api
function AutoParry.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.Remote) ~= "table" then return false, "dependências inválidas" end
  detach("setup"); utils, gameInfo, remote = deps.Utils, deps.GameInfo, deps.Remote
  state.player = utils.getLocalPlayer()
  if not state.player then return false, "Players.LocalPlayer indisponível" end
  resetTracking(); phase("detached", "setup_complete")
  return true
end
function AutoParry.bindCharacter(character)
  if not utils or not gameInfo or not remote then return false, "dependências não inicializadas" end
  detach("rebind_start")
  if not character or not character.Parent then return false, "personagem indisponível" end
  local generation = state.generation; local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
  if generation ~= state.generation or not root or not root.Parent or not root:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
  local service, player = utils.getRunService(), utils.getLocalPlayer(); local signal = service and (service.PostSimulation or service.Heartbeat)
  if not signal or not player then return false, "RunService ou jogador indisponível" end
  state.root, state.character, state.player, state.alive, state.bound = root, character, player, true, true; resetTracking()
  phase("waiting", "character_bound"); gameInfo.getDeflectCooldownState()
  track(signal:Connect(function(deltaTime)
    if generation ~= state.generation then return end
    if finite(deltaTime) and deltaTime >= 0 then state.frameAllowance = math.clamp(deltaTime - CONFIG.FRAME_BASE, 0, CONFIG.MAX_FRAME_ALLOWANCE) end
    tick(character, root, generation)
  end))
  track(gameInfo.observeTraining(function()
    if generation == state.generation and gameInfo.isTrainingArea() then tick(character, root, generation) end
  end))
  track(character.AncestryChanged:Connect(function(_, parent)
    if not parent and generation == state.generation then detach("character_removed") end
  end))
  return true
end

-- actions
function AutoParry.beginFierce()
  if not state.alive or not state.bound then return nil end
  local target = gameInfo.getTargetId()
  if finite(target) then observeTarget(target, clock()) end
  local token = { generation = state.generation, cycle = state.cycle, previouslyFired = state.fired }; state.fired = true
  return token
end
function AutoParry.cancelFierce(token)
  if token and state.generation == token.generation and state.cycle == token.cycle and not token.previouslyFired then state.fired = false end
end
function AutoParry.fire()
  if not state.alive or not state.bound or state.fired or state.teleported then return false end
  if not state.player or state.target ~= state.player.UserId or clock() < state.nextAttemptAt then return false end
  local g = radius(state.speed, activeWindowFactor(clock()))
  if not g or state.distance > g.fullRadius then return false end
  return request("manual_parry")
end
function AutoParry.tryRedirectReturn(value, redirectAt)
  if not state.alive or not state.bound or not state.player or state.teleported then return false end
  if not state.root or not state.root.Parent then return false end
  if not utils.isActive() or utils.isSpamActive() or utils.getConfigValue("AutoParry") == false then return false end
  if not gameInfo.isSnapshotValid(value) or value.teleported or value.locked then return false end
  local time = clock()
  if not observeSnapshot(value, time) then return false end
  if state.fired and finite(redirectAt) and state.lastFireAt >= redirectAt then return true end
  local position, velocity = value.position, value.velocity; local own = gameInfo.getRootPosition(state.root)
  if not vector(position) or not vector(own) then return false end
  samplePing(); local speed = tonumber(value.syncSpeed)
  if not finite(speed) or speed <= 0 then speed = vector(velocity) and velocity.Magnitude or 0 end
  velocity = resolveVelocity(value, position, speed, time); local g = radius(speed, activeWindowFactor(time))
  if not g then return false end
  local distance, closing, threshold = trajectory(position, velocity, own, speed, g); state.lastBall, state.speed, state.distance, state.approaching = value.ball, speed, distance, closing > 0
  state.closingSpeed, state.triggerDistance = closing, threshold; state.lastBall, state.lastPosition, state.lastSampleAt = value.ball, position, time
  if closing <= 0 or distance > threshold then return false end
  if state.fired then return false end
  return request("redirect_return")
end
function AutoParry.resetState() detach("reset") end
function AutoParry.detachCharacter() detach("detach") end
function AutoParry.teardown()
  detach("teardown"); utils, gameInfo, remote, state.player = nil, nil, nil, nil
end

-- ball-sync
function AutoParry.onBallSync(data)
  if type(data) ~= "table" or not state.alive or not state.bound then return end
  if gameInfo.isTrainingArea() then return true end
  local sequence = data.Sequence or data.TeleportSequence
  if sequence == nil and gameInfo.getSyncSequence and data == gameInfo.getSyncData() then sequence = gameInfo.getSyncSequence() end
  local order = sequenceOrder(sequence)
  if order == "old" then return true end
  if order == "same" and (data.Teleported ~= true or state.teleported) then return true end
  if order == "new" then state.sequence = sequence end
  if data.Teleported == true then
    state.teleported, state.teleportSequence = true, sequence; state.lastBall = nil
    state.cycle += 1; state.fired, state.awaySeen, state.targetKnown, state.target = false, false, false, -1
    state.retryPending, state.retryCooldownSeen, state.retryReady = false, false, false; state.resetPending = true
    state.speed, state.distance, state.approaching = 0, 0, false; state.autoParryCps, state.lastAutoParryClickAt, state.windowFactor = 0, nil, CONFIG.DEFAULT_WINDOW_FACTOR
    state.nextAttemptAt = 0; state.lastPosition, state.lastSampleAt = nil, 0
    state.awayAt, state.awayTarget = nil, nil; table.clear(state.clicks)
    table.clear(state.returns); phase("waiting", "teleport_lock")
    return true
  end
  if state.teleported and state.teleportSequence then
    local current = gameInfo.getSyncSequence()
    if type(current) ~= "number" or (current - state.teleportSequence) % 65536 >= 32768 then return true end
  end
  state.teleported, state.teleportSequence = false, nil
  if state.character and state.root then tick(state.character, state.root, state.generation) end
  return true
end

-- status
function AutoParry.getTargetStatus()
  return {
    armed = not state.fired,
    firedForTarget = state.fired,
    lastTargeted = state.lastTargeted,
    targeted = state.targetKnown and state.player ~= nil and state.target == state.player.UserId,
    approaching = state.approaching,
    targetId = state.target,
    targetKnown = state.targetKnown,
    cooldown = gameInfo and gameInfo.getDeflectCooldownState() or nil,
  }
end
function AutoParry.getDefenseState(value)
  samplePing(); local cooldown = safeCooldown()
  local time = clock(); local speed = value and (tonumber(value.syncSpeed) or tonumber(value.speed))
  local geometry = finite(speed) and radius(speed, activeWindowFactor(time)) or nil
  local distance, closing, trigger
  if geometry and value and vector(value.position) and vector(value.velocity) and state.root and state.root.Parent then
    distance, closing, trigger = trajectory(value.position, value.velocity, gameInfo.getRootPosition(state.root), speed, geometry)
  end
  return {
    enabled = state.alive and state.bound and utils.getConfigValue("AutoParry") ~= false,
    armed = not state.fired,
    fired = state.fired,
    cycle = state.cycle,
    lastRequestAt = state.lastFireAt,
    retryAt = state.nextAttemptAt,
    lastParriedAt = cooldown and cooldown.lastParriedAt or 0,
    blocking = cooldown and cooldown.blocking == true or false,
    reason = state.reason,
    triggerDistance = trigger,
    distance = distance,
    closingSpeed = closing,
  }
end
local function rootPosition()
  if state.root and state.root.Parent then return gameInfo.getRootPosition(state.root) end
  local character = state.player and state.player.Character; local root = character and character:FindFirstChild("HumanoidRootPart")
  return root and root.Parent and gameInfo.getRootPosition(root) or nil
end
function AutoParry.getTiming(value, time, root, factor, baseWindow)
  if type(value) ~= "table" then return nil end
  root = vector(root) and root or rootPosition(); local position, velocity = value.position, value.velocity
  if gameInfo and typeof(value.ball) == "Instance" and value.ball.Parent and value.ball:IsA("BasePart") then
    if value.mode == "training" or not vector(position) then position = gameInfo.getBallPosition(value.ball) end
    if value.ball == state.lastBall then
      local current = gameInfo.getBallVelocity(value.ball)
      if vector(current) and current.Magnitude > 0.1 then velocity = current end
    end
    if not vector(velocity) then velocity = gameInfo.getBallVelocity(value.ball) end
  end
  if not vector(position) or not vector(root) then return nil end
  velocity = vector(velocity) and velocity or Vector3.zero; local speed = velocity.Magnitude > 0.1 and velocity.Magnitude or tonumber(value.speed) or 0
  if not finite(speed) or speed < 0 then return nil end
  local geometry = value.mode == "training" and trainingGeometry(speed, factor) or radius(speed, factor, baseWindow)
  if not geometry then return nil end
  local distance, closing, triggerDistance = trajectory(position, velocity, root, speed, geometry); local delta = root - position
  local distanceToRadius = distance - geometry.fullRadius; local timeToRange = closing > 0 and math.max(distance - geometry.noWindowParryRadius, 0) / closing or math.huge
  local timeToTrigger = closing > 0 and math.max(distance - triggerDistance, 0) / closing or math.huge
  return {
    distance = distance,
    speed = speed,
    velocity = velocity,
    parryRadius = geometry.fullRadius,
    fullRadius = geometry.fullRadius,
    pureRadius = geometry.pureRadius,
    noWindowParryRadius = geometry.noWindowParryRadius,
    pingRadius = geometry.pingRadius,
    resilienceBonus = geometry.resilienceBonus,
    leadTime = geometry.leadTime,
    deflectWindow = geometry.deflectWindow,
    effectiveWindow = geometry.effectiveWindow,
    windowFactor = geometry.windowFactor,
    triggerPadding = geometry.triggerPadding,
    distanceToParryRadius = distanceToRadius,
    timeToRange = timeToRange,
    triggerDistance = triggerDistance,
    timeToTrigger = timeToTrigger,
    tti = timeToTrigger,
    approaching = closing > 0 and speed >= CONFIG.MIN_PARRY_SPEED,
    targeted = value.targeted == true,
  }
end
function AutoParry.getRadius(mode, factor, speedOverride, baseWindow)
  if mode ~= "tti" and mode ~= "speed_distance" then mode = "geometry" end
  local speed = tonumber(speedOverride)
  if not finite(speed) or speed < 0 then speed = state.speed end
  local result = radius(speed, factor, baseWindow); local tti = speed > 0 and math.max(state.distance - result.fullRadius, 0) / speed or math.huge
  result.mode, result.speed, result.distance, result.tti, result.resilience = mode, speed, state.distance, tti, resilience()
  result.value = mode == "tti" and tti or (mode == "speed_distance" and { speed = speed, distance = state.distance } or result.fullRadius); return result
end
function AutoParry.getPressure()
  local time, count, factors, configured, speeds, ratios = clock(), 0, 0, 0, 0, 0
  for i = #state.clicks, 1, -1 do
    local item = state.clicks[i]
    if time < item.at or time - item.at > CONFIG.PRESSURE_WINDOW then
      table.remove(state.clicks, i)
    else
      count += 1
      factors += item.factor
      configured += item.configured; speeds += item.speed
      ratios += math.clamp(item.factor / item.configured, 0, 1)
    end
  end
  local returns, intervals = 0, 0
  for i = #state.returns, 1, -1 do
    local item = state.returns[i]
    if time < item.at or time - item.at > CONFIG.PRESSURE_WINDOW then table.remove(state.returns, i) else returns += 1; intervals += item.interval end
  end
  local latest, lastReturn = state.clicks[#state.clicks], state.returns[#state.returns]
  local currentLevel, factorDrop
  if latest and time >= latest.at and time - latest.at <= 1 and finite(latest.configured) and latest.configured > 0 then
    local ratio = math.clamp(latest.factor / latest.configured, 0, 1); currentLevel = 1 - ratio
    if count >= 3 then
      local previous, older = state.clicks[#state.clicks - 1], state.clicks[#state.clicks - 2]
      local earlier = (math.clamp(previous.factor / previous.configured, 0, 1) + math.clamp(older.factor / older.configured, 0, 1)) / 2; factorDrop = math.max(0, earlier - ratio)
    end
  end
  return {
    samples = count,
    cps = count / CONFIG.PRESSURE_WINDOW,
    averageFactor = count > 0 and factors / count or nil,
    configuredFactor = count > 0 and configured / count or nil,
    averageSpeed = count > 0 and speeds / count or nil,
    returnSamples = returns,
    averageReturnTime = returns > 0 and intervals / returns or nil,
    level = count >= 3 and returns >= 2 and math.clamp(1 - ratios / count, 0, 1) or nil,
    currentFactor = latest and latest.factor or nil,
    currentLevel = currentLevel,
    factorDrop = factorDrop,
    latestReturnTime = lastReturn and lastReturn.interval or nil,
  }
end
function AutoParry.getStatus()
  local geometry = AutoParry.getRadius("geometry", utils and activeWindowFactor(clock()) or CONFIG.DEFAULT_WINDOW_FACTOR); local target = AutoParry.getTargetStatus()
  return {
    schema = utils and utils.apiVersion() or nil,
    api = {
      name = "AutoParry",
      version = 13,
      endpoints = { "getRadius", "getTiming", "getStatus", "getTargetStatus" },
      radiusModes = { "geometry", "tti", "speed_distance" },
      defaultWindowFactor = CONFIG.DEFAULT_WINDOW_FACTOR,
      windowFactorRange = { min = 0, max = CONFIG.MAX_WINDOW_FACTOR },
    },
    lifecycle = {
      phase = state.phase,
      reason = state.reason,
      bound = state.bound,
      alive = state.alive,
      generation = state.generation,
      lifeGeneration = state.lifeGeneration,
    },
    radius = geometry,
    resilience = geometry.resilience,
    timing = {
      tti = geometry.tti,
      ti = geometry.tti,
      speed = state.speed,
      distance = state.distance,
      distanceToRadius = state.distance - state.triggerDistance,
      triggerDistance = state.triggerDistance,
      closingSpeed = state.closingSpeed,
      frameAllowance = state.frameAllowance,
      deflectWindow = geometry.deflectWindow,
      effectiveWindow = geometry.effectiveWindow,
      leadTime = geometry.leadTime,
      noWindowParryRadius = geometry.noWindowParryRadius,
      pingRadius = geometry.pingRadius,
      approaching = state.approaching,
    },
    ping = {
      oneWay = state.ping,
      raw = state.pingRaw,
      samples = state.pingCount,
    },
    cps = state.autoParryCps,
    windowFactor = state.windowFactor,
    cpsGate = {
      adaptive = false,
    },
    target = target,
    mode = state.mode,
    training = {
      active = state.mode == "training",
      triggerDistance = state.mode == "training" and state.triggerDistance or nil,
      nextAttemptIn = 0,
      stateAge = state.mode == "training" and (state.trainingLastValidAt > 0 and clock() - state.trainingLastValidAt or nil) or nil,
    },
    pressure = AutoParry.getPressure(),
    cycle = {
      fired = state.fired,
      armed = not state.fired,
      lastFireAt = state.lastFireAt,
      lastTTI = geometry.tti,
    },
    config = {
      baseRadius = geometry.pureRadius,
      baseWindow = geometry.deflectWindow,
      defaultWindowFactor = CONFIG.DEFAULT_WINDOW_FACTOR,
      windowFactorRange = { min = 0, max = CONFIG.MAX_WINDOW_FACTOR },
      minBallSpeed = CONFIG.MIN_PARRY_SPEED,
    },
    timestamp = clock(),
  }
end

-- contract
AutoParry.__contract = {
  requires = { Remote = "remote", GameInfo = "gameinfo", Utils = "utils" },
  requiresMethods = {
    Remote = { "fireParry" },
    GameInfo = {
      "isTrainingArea",
      "recordTrainingDeflectAttempt",
      "getTrainingCooldownState",
      "recordDeflectAttempt",
      "observeTraining",
      "getSnapshotAt",
      "isSnapshotValid",
      "getSyncData",
      "getTargetId",
      "getSyncSequence",
      "getDeflectCooldownState",
      "getAveragePing",
      "getBallPosition",
      "getBallVelocity",
      "getRootPosition",
      "getDeflectGeometry",
      "getAutoParryGeometry",
      "getDeflectRangeParameters",
      "getProjectedDeflectRadius",
      "getAutoSpamDelay",
    },
    Utils = {
      "apiVersion",
      "getLocalPlayer",
      "getRunService",
      "getConfigValue",
      "isActive",
      "isSpamActive",
      "trackCharacter",
      "untrackCharacter",
      "recordError",
      "recordTransition",
    },
  },
  provides = {
    "getDefenseState",
    "setup",
    "bindCharacter",
    "detachCharacter",
    "teardown",
    "onBallSync",
    "fire",
    "tryRedirectReturn",
    "beginFierce",
    "cancelFierce",
    "resetState",
    "getRadius",
    "getTiming",
    "getTargetStatus",
    "getPressure",
    "getStatus",
  },
  onBallSync = true,
  bindCharacter = true,
  version = 13,
}

return AutoParry
