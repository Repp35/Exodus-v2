-- [[ auto spam ]]

-- module
local AutoSpam = {}
local utils, gameInfo, autoParry, clashStatsModule, players, runService, localPlayer
local current, generation = nil, 0
local clashStats

-- configuration
local CONFIG = {
  ACTIVATION = {
    RETURN = 0.15,
    EXCHANGE_MAX_INTERVAL = 2,
    EXCHANGE_READY_TIME = 0.5,
    REACTIVATION_COOLDOWN = 0.04,
    RADIUS_FACTOR = 0.8,
    HAUNTER_RANGE = 11,
    HAUNTER_MATCH_RADIUS = 5,
    DASH_WINDOW_FACTOR = 0.4,
    DASH_RADIUS_MULTIPLIER = 22 / 15,
    DASH_MAX_AGE = 0.35,
    DASH_MIN_APPROACH = 3,
    DASH_FAST_APPROACH = 1.25,
    DASH_FAST_SPEED = 60,
    DASH_MAX_SPEED = 400,
    DASH_ALIGNMENT = 0.7,
  },
  DEACTIVATION = {
    MIN_DISTANCE = 20,
    MAX_DISTANCE_REFERENCE = 51,
    MIN_ACTIVE_TIME = 0.1,
    NEAR_PARTNER_COOLDOWN_MULTIPLIER = 1.3,
    TARGET_RETURN_TIMEOUT = 0.05,
    PARTNER_RETURN_FALLBACK = 0.1,
    PARTNER_RETURN_MAX = 0.25,
  },
  SHARED = {
    MIN_RETURN = 1 / 25,
    SNAPSHOT_MAX_AGE = 0.5,
    SEQUENCE_MODULUS = 65536,
    SEQUENCE_HALF = 32768,
  },
}

-- helpers
local function finite(n) return type(n) == "number" and n == n and n > -math.huge and n < math.huge end
local function userId(value)
  if type(value) == "string" then value = tonumber(value) end
  return finite(value) and value > 0 and value % 1 == 0 and value or nil
end
local function now() return utils.now() end
local function elapsed(localStart, serverStart, localNow, serverNow)
  if finite(serverStart) and finite(serverNow) then
    if serverNow < serverStart then return nil end
    return serverNow - serverStart
  end
  if finite(localStart) and localNow >= localStart then return localNow - localStart end
  return nil
end
local function track(s, signal, callback)
  local connection = signal:Connect(callback); s.connections[#s.connections + 1] = connection
  utils.trackCharacter(connection); return connection
end
local function untrack(s, connection)
  if not connection then return end
  utils.untrackCharacter(connection); connection:Disconnect()
  local index = table.find(s.connections, connection)
  if index then table.remove(s.connections, index) end
end
local function snapshotSpeed(snapshot)
  if not snapshot then return nil end
  local speed = tonumber(snapshot.syncSpeed); return finite(speed) and speed > 0 and speed or snapshot.speed
end
local function resetExchange(s)
  s.opponentWindow = nil; s.exchangeFrom, s.exchangeTo, s.exchangeAt, s.exchangePartner, s.exchangeReadyAt = nil, nil, nil, nil, nil
  s.pending, s.departedAt, s.departedServerAt, s.departedTo = nil, nil, nil, nil
end
local function distanceToPlayer(id) return id and gameInfo.getPlayerDistance(id) or nil end
local function distanceLimit(snapshot, partner)
  local speed = snapshotSpeed(snapshot)
  if not finite(speed) or speed <= 0 then return nil end
  local minimum, maximum = gameInfo.getBallSpeedLimits(); local baseRange, maximumResilience = gameInfo.getDeflectRangeParameters()
  local ownRange = gameInfo.getPlayerDeflectRange(localPlayer.UserId); local otherRange = partner and gameInfo.getPlayerDeflectRange(partner)
  local ownRaw = gameInfo.getPlayerRawRadius(localPlayer.UserId, speed, true); local otherRaw = partner and gameInfo.getPlayerRawRadius(partner, speed, true)
  if
    not finite(minimum)
    or not finite(maximum)
    or maximum <= minimum
    or not finite(baseRange)
    or not finite(maximumResilience)
    or not finite(ownRange)
    or not finite(otherRange)
    or not finite(ownRaw)
    or not finite(otherRaw)
  then
    return nil
  end
  local speedFactor = math.clamp((speed - minimum) / (maximum - minimum), 0, 1); local baseAtMaxSpeed = CONFIG.DEACTIVATION.MAX_DISTANCE_REFERENCE - maximumResilience * 2
  local baseDistance = CONFIG.DEACTIVATION.MIN_DISTANCE + (baseAtMaxSpeed - CONFIG.DEACTIVATION.MIN_DISTANCE) * speedFactor
  local ownResilience = math.clamp(ownRange - baseRange, 0, maximumResilience); local otherResilience = math.clamp(otherRange - baseRange, 0, maximumResilience)
  local ownPing = math.max(0, ownRaw - ownRange); local otherPing = math.max(0, otherRaw - otherRange)
  return baseDistance + (ownResilience + otherResilience) * speedFactor + ownPing + otherPing
end
local function distanceGate(s, snapshot, partner, radiusOnly)
  if not s.root or not s.root.Parent or not snapshot or typeof(snapshot.position) ~= "Vector3" then return "distance_unavailable" end
  local speed = snapshotSpeed(snapshot); local g = finite(speed) and speed > 0 and gameInfo.getDeflectGeometry(speed, "game", CONFIG.ACTIVATION.RADIUS_FACTOR, false)
  local other = partner and gameInfo.getPlayerMotion(partner); local opponentLimit = distanceLimit(snapshot, partner)
  if not g or typeof(other) ~= "Vector3" or not opponentLimit then return "distance_unavailable" end
  local own = s.root.Position; local opponentDistance = (other - own).Magnitude
  local ballDistance = (snapshot.position - own).Magnitude
  if opponentDistance > opponentLimit then return "opponent_distance" end
  if radiusOnly then
    local raw = gameInfo.getPlayerRawRadius(localPlayer.UserId, speed, true)
    if not finite(raw) then return "distance_unavailable" end
    if ballDistance > raw then return "ball_distance" end
  elseif math.max(0, ballDistance - g.noWindowParryRadius) / speed > g.effectiveWindow then
    return "ball_distance"
  end
  return nil
end
local function playerIsAlive(id)
  local player = id and players:GetPlayerByUserId(id); local character = player and player.Character
  local humanoid = character and character.Parent and character:FindFirstChildOfClass("Humanoid"); return humanoid ~= nil and humanoid.Health > 0
end

-- geometry
local function geometry(snapshot, factor)
  local speed = snapshotSpeed(snapshot)
  if not finite(speed) or speed <= 0 then return nil end
  local g = gameInfo.getDeflectGeometry(speed, "game", factor, false)
  if not g then return nil end
  return g, speed, g.deflectWindow
end
local function returnWindow(window, speed, base)
  local minimum, maximum = gameInfo.getBallSpeedLimits(); local factor = maximum > minimum and math.clamp((speed - minimum) / (maximum - minimum), 0, 1) or 0
  local pressure = autoParry.getPressure(); local multiplier = pressure and pressure.returnMultiplier == 1.4 and 1.4 or 1
  return math.max(CONFIG.SHARED.MIN_RETURN, math.min(base * (1 - 0.9 * factor), window)) * multiplier
end

-- dash-assist
local function sampleOwnDash(s, time)
  if not gameInfo.isPlayerDashing(localPlayer) then s.dashStart, s.dashAt = nil, nil; return end
  if not s.dashStart then s.dashStart, s.dashAt = s.root.Position, time end
  if time - s.dashAt > 0.85 then s.dashStart, s.dashAt = s.root.Position, time end
end
local function dashAssistPartner(s, snapshot, time)
  if not s.dashStart or not s.dashAt or time - s.dashAt > 0.85 or not s.dashSwitchPartner then return nil end
  if time - s.dashSwitchAt > CONFIG.ACTIVATION.DASH_MAX_AGE then return nil end
  local partner = s.dashSwitchPartner
  if not playerIsAlive(partner) then return nil end
  local opponent = gameInfo.getPlayerMotion(partner)
  if typeof(opponent) ~= "Vector3" then return nil end
  local own = s.root.Position; local movement = own - s.dashStart
  local toward = opponent - s.dashStart; local startDistance = toward.Magnitude
  local elapsedTime = time - s.dashAt
  if startDistance < 0.1 or elapsedTime <= 0 then return nil end
  local measuredSpeed = movement.Magnitude / elapsedTime
  if not finite(measuredSpeed) or measuredSpeed > CONFIG.ACTIVATION.DASH_MAX_SPEED then return nil end
  local minimum = measuredSpeed >= CONFIG.ACTIVATION.DASH_FAST_SPEED and CONFIG.ACTIVATION.DASH_FAST_APPROACH or CONFIG.ACTIVATION.DASH_MIN_APPROACH
  if movement.Magnitude < minimum or startDistance - (opponent - own).Magnitude < minimum then return nil end
  if movement:Dot(toward) / (movement.Magnitude * startDistance) < CONFIG.ACTIVATION.DASH_ALIGNMENT then return nil end
  if snapshot.targetId == localPlayer.UserId and typeof(snapshot.position) == "Vector3" and typeof(snapshot.velocity) == "Vector3" then
    local ballToward = own - snapshot.position; local velocity = snapshot.velocity
    if ballToward.Magnitude > 1 and velocity.Magnitude > 8 and velocity:Dot(ballToward) / (velocity.Magnitude * ballToward.Magnitude) < -0.35 then return nil end
  end
  local speed = snapshotSpeed(snapshot); local raw = gameInfo.getPlayerRawRadius(localPlayer.UserId, speed, true)
  if not raw or (opponent - own).Magnitude > raw then return nil end
  return partner
end

-- activation
local function start(s, reason, partner, time, serverTime, snapshot)
  if s.active or (s.lastDeactivatedAt and time - s.lastDeactivatedAt < CONFIG.ACTIVATION.REACTIVATION_COOLDOWN) then return end
  local haunter = reason == "haunter" or reason == "haunter_self"
  if
    not haunter
    and (not s.exchangeReadyAt or s.exchangePartner ~= partner or time < s.exchangeReadyAt or time - s.exchangeReadyAt > CONFIG.ACTIVATION.EXCHANGE_READY_TIME)
  then
    return
  end
  snapshot = snapshot or gameInfo.getSnapshotAt(time); local distanceReason = distanceGate(s, snapshot, partner, reason == "started_near")
  if distanceReason then return end
  if clashStats and clashStats.frozen then clashStatsModule.begin(partner, time); clashStats = clashStatsModule.get() end
  s.active, s.partner, s.pending, s.stoppedPartner, s.stoppedAt = true, partner, nil, nil, nil; s.dashSwitchPartner, s.dashSwitchAt = nil, nil
  s.activatedAt = time; gameInfo.isClientDeflectResetLate(time, snapshot and snapshotSpeed(snapshot))
  local initialTarget = snapshot and snapshot.targetUncertain ~= true and userId(snapshot.targetId) or nil; s.targetAwaySince = initialTarget and initialTarget ~= localPlayer.UserId and time or nil
  s.diversionSince, s.diversionSyncAt = nil, nil; s.lastSwitchAt, s.lastSwitchServerAt, s.reason = time, serverTime, reason
  utils.setAutoSpamActive(true); utils.recordTransition("AutoSpam", "idle", "active", reason)
end
local function activationGeometry(s, snapshot, partner, time)
  local factor = CONFIG.ACTIVATION.RADIUS_FACTOR
  if dashAssistPartner(s, snapshot, time) == partner then factor *= CONFIG.ACTIVATION.DASH_RADIUS_MULTIPLIER end
  return geometry(snapshot, factor)
end
local function observeOpponentWindow(s, snapshot, time)
  local target = userId(snapshot.targetId)
  if not target or target == localPlayer.UserId then return end
  s.opponentWindow = nil
  if snapshot.targetUncertain == true or snapshot.locked == true then return end
  local g = geometry(snapshot, 1); local position = gameInfo.getPlayerMotion(target)
  if g and typeof(position) == "Vector3" and (position - s.root.Position).Magnitude <= g.fullRadius then s.opponentWindow = { partner = target, at = time } end
end
local function shouldActivate(s, snapshot, time)
  if not utils.isActive() or utils.getConfigValue("AutoSpam") ~= true then return false end
  if not snapshot or snapshot.targetUncertain == true or gameInfo.getBallFrozen() == true or not s.pending then return false end
  if s.target ~= localPlayer.UserId or snapshot.targetId ~= localPlayer.UserId then return false end
  if typeof(snapshot.position) ~= "Vector3" then return false end
  local towardPlayer = s.root.Position - snapshot.position; local distance = towardPlayer.Magnitude
  if s.pending.nearSwitch then
    local raw = gameInfo.getPlayerRawRadius(localPlayer.UserId, snapshotSpeed(snapshot), true); return time == s.pending.switchAt and snapshot.locked ~= true and finite(raw) and distance <= raw
  end
  local g = activationGeometry(s, snapshot, s.pending.partner, time)
  if not g or distance > g.fullRadius then return false end
  if s.pending.fastReturn then return true end
  if distance <= 0 or typeof(snapshot.velocity) ~= "Vector3" then return false end
  local closingSpeed = snapshot.velocity:Dot(towardPlayer) / distance
  if not finite(closingSpeed) or closingSpeed <= 0 then return false end
  if s.pending.startedNear then
    local timeToRange = math.max(0, distance - g.noWindowParryRadius) / closingSpeed
    if timeToRange > g.effectiveWindow then return false end
  end
  return true
end

-- deactivation
local function stop(s, reason)
  if current ~= s then return end
  if s.active then
    local stoppedAt = now(); s.stoppedPartner, s.stoppedAt = s.partner, stoppedAt
    s.active = false; s.lastDeactivatedAt = stoppedAt
    s.lastStopReason, s.lastStopAt = reason, s.lastDeactivatedAt; utils.setAutoSpamActive(false)
    utils.recordTransition("AutoSpam", "active", "idle", reason)
  end
  s.reason, s.pending, s.partner, s.activatedAt, s.diversionSince, s.diversionSyncAt = reason, nil, nil, nil, nil, nil; s.targetAwaySince = nil
  resetExchange(s)
end
local function shouldDeactivate(s, snapshot, time)
  if not utils.isActive() then return "hub_inactive" end
  if utils.getConfigValue("AutoSpam") ~= true then return "disabled" end
  if gameInfo.getBallFrozen() == true then return "frozen" end
  local age = snapshot and finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt
  if
    not snapshot
    or not gameInfo.isSnapshotValid(snapshot)
    or snapshot.teleported
    or snapshot.locked == true
    or snapshot.targetUncertain == true
    or not age
    or age < 0
    or age > CONFIG.SHARED.SNAPSHOT_MAX_AGE
  then
    return nil
  end
  local target = userId(snapshot.targetId)
  if not target then return nil end
  if target ~= localPlayer.UserId and target ~= s.partner then
    local position = gameInfo.getPlayerMotion(target); local limit = distanceLimit(snapshot, target)
    if limit and s.root and s.root.Parent and typeof(position) == "Vector3" and (position - s.root.Position).Magnitude > limit then return "distant_target" end
  end
  local reason = distanceGate(s, snapshot, s.partner)
  if reason ~= "distance_unavailable" then return reason end
  return nil
end
local function applyDeactivation(s, snapshot, time)
  if not s.active then return false end
  local reason = shouldDeactivate(s, snapshot, time)
  if not reason and s.activatedAt then
    local speed = snapshot and snapshotSpeed(snapshot); local multiplier = 1
    if
      s.partner
      and snapshot
      and gameInfo.isSnapshotValid(snapshot)
      and snapshot.targetUncertain ~= true
      and not snapshot.teleported
      and finite(snapshot.syncAt)
      and time >= snapshot.syncAt
      and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE
    then
      local radius = gameInfo.getPlayerRawRadius(localPlayer.UserId, speed, true); local distance = distanceToPlayer(s.partner)
      if finite(radius) and finite(distance) and distance <= radius then multiplier = CONFIG.DEACTIVATION.NEAR_PARTNER_COOLDOWN_MULTIPLIER end
    end
    local resetLate = gameInfo.isClientDeflectResetLate(s.activatedAt, speed, multiplier)
    if resetLate and time - s.activatedAt >= CONFIG.DEACTIVATION.MIN_ACTIVE_TIME then reason = "client_deflect_reset_late" end
  end
  if not reason then return false end
  stop(s, reason); return true
end
local function observeTargetReturn(s, target, time)
  if not s.active or not target then return end
  if target == localPlayer.UserId then s.targetAwaySince = nil else s.targetAwaySince = s.targetAwaySince or time end
end
local function enforceTargetReturnTimeout(s, snapshot, time)
  if not s.active or not s.activatedAt or not s.targetAwaySince then return false end
  if time - s.activatedAt < CONFIG.DEACTIVATION.MIN_ACTIVE_TIME then return false end
  local timeout = CONFIG.DEACTIVATION.TARGET_RETURN_TIMEOUT
  if
    s.partner
    and snapshot
    and snapshot.targetId == s.partner
    and snapshot.targetUncertain ~= true
    and not snapshot.teleported
    and finite(snapshot.syncAt)
    and time >= snapshot.syncAt
    and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE
  then
    local radius = gameInfo.getPlayerRawRadius(localPlayer.UserId, snapshotSpeed(snapshot), true); local distance = distanceToPlayer(s.partner)
    if finite(radius) and finite(distance) and distance <= radius then
      local interval = clashStats and not clashStats.frozen and clashStats.partnerId == s.partner and clashStats.cycleInterval
      timeout = finite(interval) and math.clamp(interval, timeout, CONFIG.DEACTIVATION.PARTNER_RETURN_MAX) or CONFIG.DEACTIVATION.PARTNER_RETURN_FALLBACK
    end
  end
  if time - s.targetAwaySince < timeout then return false end
  stop(s, "target_return_timeout"); return true
end

-- target-tracking
local function inspectTarget(s, target, time, snapshot, serverTime)
  if not target or target == s.target then return end
  local previous, me = s.target, localPlayer.UserId
  local completedPartner
  if
    previous
    and s.exchangeFrom == target
    and s.exchangeTo == previous
    and (target == me or previous == me)
    and s.exchangeAt
    and time >= s.exchangeAt
    and time - s.exchangeAt <= CONFIG.ACTIVATION.EXCHANGE_MAX_INTERVAL
  then
    completedPartner = target == me and previous or target
  end
  if previous and (previous == me or target == me) then s.exchangeFrom, s.exchangeTo, s.exchangeAt = previous, target, time else s.exchangeFrom, s.exchangeTo, s.exchangeAt = nil, nil, nil end
  s.exchangePartner, s.exchangeReadyAt = completedPartner, completedPartner and time or nil
  if
    s.stoppedPartner
    and previous
    and previous ~= target
    and ((previous == me and target == s.stoppedPartner) or (target == me and previous == s.stoppedPartner))
    and s.stoppedAt
    and time - s.stoppedAt >= CONFIG.ACTIVATION.REACTIVATION_COOLDOWN
  then
    s.stoppedPartner, s.stoppedAt = nil, nil
  end
  if previous and previous ~= target and (previous == me or target == me) and s.dashStart then s.dashSwitchPartner, s.dashSwitchAt = previous == me and target or previous, time
  elseif previous and previous ~= target then s.dashSwitchPartner, s.dashSwitchAt = nil, nil end
  if not s.active and s.pending and target ~= me then s.pending = nil end
  local switchElapsed = elapsed(s.lastSwitchAt, s.lastSwitchServerAt, time, serverTime)
  if switchElapsed then s.intervalMs = switchElapsed * 1000 end
  s.target, s.lastSwitchAt, s.lastSwitchServerAt = target, time, serverTime
  if previous == me and target ~= me then
    s.departedAt, s.departedServerAt, s.departedTo = time, serverTime, target
  elseif target == me and previous ~= me then
    if not s.pending and not s.active and previous ~= s.stoppedPartner and previous == s.departedTo and s.departedAt then
      local g, speed, window = activationGeometry(s, snapshot, previous, time)
      if not g or not window or typeof(snapshot.position) ~= "Vector3" then return end
      local returnElapsed = elapsed(s.departedAt, s.departedServerAt, time, serverTime)
      if not returnElapsed then return end
      local raw = gameInfo.getPlayerRawRadius(me, speed, true); local startedNear = finite(raw) and (snapshot.position - s.root.Position).Magnitude <= raw
      local observed = s.opponentWindow; local nearSwitch = startedNear
        and snapshot.locked ~= true
        and snapshot.targetUncertain ~= true
        and completedPartner == previous
        and observed
        and observed.partner == previous
        and time >= observed.at
        and time - observed.at <= CONFIG.SHARED.SNAPSHOT_MAX_AGE
      s.opponentWindow = nil; local fastReturn = returnElapsed <= returnWindow(window, speed, CONFIG.ACTIVATION.RETURN)
      if startedNear and not fastReturn and not nearSwitch then return end
      s.pending = { partner = previous, startedNear = startedNear, fastReturn = fastReturn, nearSwitch = nearSwitch == true, switchAt = time }
    end
  end
end

-- evaluation
local function evaluate(s, time, fresh, serverTime, snapshot, blockedActivation, autoEnabled)
  if current ~= s or not s.root.Parent then return end
  if not utils.isActive() then
    stop(s, "hub_inactive"); s.stoppedPartner, s.haunterPartner, s.haunterUntil = nil, nil, nil
    return
  end
  if autoEnabled == nil then autoEnabled = utils.getConfigValue("AutoSpam") == true end
  if not autoEnabled then
    if s.active then stop(s, "disabled") end
    resetExchange(s)
  end
  if gameInfo.getBallFrozen() == true then
    applyDeactivation(s, nil, time); resetExchange(s)
    s.target = nil; return
  end
  snapshot = snapshot or gameInfo.getSnapshotAt(time)
  if not fresh and applyDeactivation(s, snapshot, time) then blockedActivation = true end
  if enforceTargetReturnTimeout(s, snapshot, time) then return end
  sampleOwnDash(s, time)
  if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return end
  if finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt > CONFIG.SHARED.SNAPSHOT_MAX_AGE then return end
  observeOpponentWindow(s, snapshot, time)
  if s.pending and s.pending.nearSwitch and time ~= s.pending.switchAt then s.pending = nil end
  if fresh then clashStatsModule.observe(s, snapshot, time, true); clashStats = clashStatsModule.get() end
  if
    not s.active
    and not blockedActivation
    and (not s.lastDeactivatedAt or time - s.lastDeactivatedAt >= CONFIG.ACTIVATION.REACTIVATION_COOLDOWN)
    and shouldActivate(s, snapshot, time)
  then
    local activationServerTime = serverTime
    if not fresh then activationServerTime = snapshot.serverTime end
    start(s, s.pending.nearSwitch and "started_near" or "return_target", s.pending.partner, time, activationServerTime, snapshot)
  end
end

-- lifecycle
local function disconnect(s)
  for _, connection in ipairs(s.connections) do
    utils.untrackCharacter(connection); connection:Disconnect()
  end
end
local function detach(reason)
  local s = current
  if s then
    if clashStats and not clashStats.frozen then
      local humanoid = s.character and s.character:FindFirstChildOfClass("Humanoid")
      if humanoid and humanoid.Health <= 0 then clashStatsModule.freeze(localPlayer.UserId, s) else clashStatsModule.finish(reason, now()) end
    end
    stop(s, reason); current = nil
    disconnect(s)
  end
  generation += 1
end
function AutoSpam.setup(deps)
  if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.ClashStats or not deps.AutoParry then return false, "dependências ausentes" end
  if current then detach("setup") end
  utils, gameInfo, autoParry, clashStatsModule = deps.Utils, deps.GameInfo, deps.AutoParry, deps.ClashStats; clashStats = clashStatsModule.get()
  players, runService, localPlayer = utils.getPlayers(), utils.getRunService(), utils.getLocalPlayer()
  if not players or not runService or not localPlayer then return false, "serviços indisponíveis" end
  return true
end
function AutoSpam.bindCharacter(character)
  detach("rebind"); local root = character and character:FindFirstChild("HumanoidRootPart")
  if not root or not root:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
  local s = {
    root = root,
    character = character,
    connections = {},
    active = false,
    target = nil,
    partner = nil,
    pending = nil,
    targetAwaySince = nil,
    stoppedPartner = nil,
    stoppedAt = nil,
    reason = "waiting",
    generation = generation,
    lastRootPosition = root.Position,
    dashStart = nil,
    dashSwitchPartner = nil,
    pendingReset = false,
  }

  current = s; local haunterConnection, haunterRemote, nextHaunterCheck = nil, nil, 0
  local function connectHaunter()
    local event = gameInfo.getHaunterEvent()
    if event == haunterRemote and haunterConnection and haunterConnection.Connected then return end
    if haunterConnection then untrack(s, haunterConnection); haunterConnection, haunterRemote = nil, nil end
    if not event then return end
    haunterRemote = event
    haunterConnection = track(s, event.OnClientEvent, function(from, destination)
      if current ~= s or s.active or not s.root.Parent or not utils.isActive() or utils.getConfigValue("AutoSpam") ~= true then return end
      if not gameInfo.areAbilitiesEnabled() or gameInfo.getBallFrozen() == true then return end
      if typeof(from) ~= "CFrame" or typeof(destination) ~= "CFrame" then return end
      local targetId = userId(gameInfo.getTargetId()); local ownId = localPlayer.UserId
      local ownWasAtSource = typeof(s.lastRootPosition) == "Vector3"
        and (s.lastRootPosition - from.Position).Magnitude <= CONFIG.ACTIVATION.HAUNTER_MATCH_RADIUS
      local eventTime = now()
      if not ownWasAtSource and s.recentRootPosition and eventTime - s.recentRootAt <= 0.75 then
        ownWasAtSource = (s.recentRootPosition - from.Position).Magnitude <= CONFIG.ACTIVATION.HAUNTER_MATCH_RADIUS
      end
      local otherTarget = targetId ~= ownId and targetId or (s.target ~= ownId and s.target or nil)
      if ownWasAtSource and targetId == ownId and not otherTarget then
        local bestDistance
        for _, player in ipairs(players:GetPlayers()) do
          if player ~= localPlayer and playerIsAlive(player.UserId) then
            local position = gameInfo.getPlayerMotion(player.UserId)
            if typeof(position) == "Vector3" then
              local distance = (position - destination.Position).Magnitude
              if distance <= CONFIG.ACTIVATION.HAUNTER_RANGE and (not bestDistance or distance < bestDistance) then otherTarget, bestDistance = player.UserId, distance end
            end
          end
        end
      end
      if otherTarget and ownWasAtSource and (targetId == ownId or targetId == otherTarget) then
        local targetPosition = gameInfo.getPlayerMotion(otherTarget)
        if
          typeof(targetPosition) == "Vector3"
          and playerIsAlive(otherTarget)
          and (targetPosition - destination.Position).Magnitude <= CONFIG.ACTIVATION.HAUNTER_RANGE
        then
          s.haunterPartner, s.haunterUntil = otherTarget, eventTime + 0.75; start(s, "haunter_self", otherTarget, eventTime, nil)
          return
        end
      end
      if (destination.Position - s.root.Position).Magnitude > CONFIG.ACTIVATION.HAUNTER_RANGE then return end
      local caster, best
      for _, player in ipairs(players:GetPlayers()) do
        local position = gameInfo.getPlayerMotion(player.UserId)
        if typeof(position) == "Vector3" and playerIsAlive(player.UserId) then
          local distance = math.min((position - from.Position).Magnitude, (position - destination.Position).Magnitude)
          if distance <= CONFIG.ACTIVATION.HAUNTER_MATCH_RADIUS and (not best or distance < best) then caster, best = player, distance end
        end
      end
      if not caster or caster == localPlayer then return end
      start(s, "haunter", caster.UserId, now(), nil)
    end)
  end
  connectHaunter(); local playerWatches = {}
  local function clearConnections(connections)
    for _, connection in ipairs(connections) do
      untrack(s, connection)
    end
    table.clear(connections)
  end
  local function watchCharacter(player, model, entry)
    clearConnections(entry.character)
    local function watchHumanoid(humanoid)
      if humanoid:IsA("Humanoid") then
        entry.character[#entry.character + 1] = track(s, humanoid.Died, function()
          if current ~= s or player.Character ~= model then return end
          local id = player.UserId
          if id ~= localPlayer.UserId and id ~= s.partner and not (clashStats and not clashStats.frozen and id == clashStats.partnerId) then return end
          clashStatsModule.freeze(id, s); clashStats = clashStatsModule.get()
          stop(s, "player_died"); s.pendingReset = true
        end)
      end
    end
    for _, child in ipairs(model:GetChildren()) do
      watchHumanoid(child)
    end
    entry.character[#entry.character + 1] = track(s, model.ChildAdded, watchHumanoid)
  end
  local function watchPlayer(player)
    if playerWatches[player] then return end
    local entry = { character = {} }; playerWatches[player] = entry
    entry.added = track(s, player.CharacterAdded, function(character) watchCharacter(player, character, entry) end)
    if player.Character then watchCharacter(player, player.Character, entry) end
  end
  local function removePlayer(player)
    local entry = playerWatches[player]
    if entry then
      clearConnections(entry.character); untrack(s, entry.added)
      playerWatches[player] = nil
    end
    if current == s and s.active and player.UserId == s.partner then stop(s, "opponent_left") end
  end
  track(s, players.PlayerAdded, watchPlayer); track(s, players.PlayerRemoving, removePlayer)
  for _, player in ipairs(players:GetPlayers()) do
    watchPlayer(player)
  end
  track(s, runService.Heartbeat, function()
    if current ~= s then return end
    local time = now()
    if (not haunterConnection or not haunterConnection.Connected or not haunterRemote.Parent) and time >= nextHaunterCheck then nextHaunterCheck = time + 0.25; connectHaunter() end
    local autoEnabled = utils.getConfigValue("AutoSpam") == true; local upDashEnabled = utils.getConfigValue("AutoClashUpDash") == true
    local manualEnabled = utils.isManualSpamActive(); local clashContext = gameInfo.getClashContext()
    clashStats = clashStatsModule.get()
    if
      not autoEnabled
      and not upDashEnabled
      and not manualEnabled
      and not s.active
      and not clashContext
      and (not clashStats or clashStats.frozen)
      and not s.pendingReset
      and not s.haunterPartner
    then
      clashStatsModule.waitForNextClash(); s.lobbyCheckAt, s.lobbySnapshotValid = nil, false
      s.pending, s.departedAt, s.departedServerAt, s.departedTo = nil, nil, nil, nil; return
    end
    local liveSnapshot
    if not s.lobbyCheckAt or time - s.lobbyCheckAt >= 0.25 then s.lobbyCheckAt, liveSnapshot = time, gameInfo.getSnapshotAt(time); s.lobbySnapshotValid = gameInfo.isSnapshotValid(liveSnapshot) end
    if not s.lobbySnapshotValid then
      s.lobbySince = s.lobbySince or time
      if time - s.lobbySince >= 1 and not s.active then s.stoppedPartner, s.pending, s.dashSwitchPartner, s.pendingReset = nil, nil, nil, false end
    else
      s.lobbySince = nil
    end
    if s.pendingReset and (not s.resetCheckAt or time - s.resetCheckAt >= 0.15) then
      s.resetCheckAt = time; local safe = true
      local snapshot = gameInfo.getSnapshotAt(time); local speed = snapshot and (snapshot.syncSpeed or snapshot.speed) or 16
      local radius = gameInfo.getPlayerRawRadius(localPlayer.UserId, speed, true) or gameInfo.getDeflectRangeParameters()
      for _, player in ipairs(players:GetPlayers()) do
        if player ~= localPlayer and playerIsAlive(player.UserId) then
          local position = gameInfo.getPlayerMotion(player.UserId)
          if typeof(position) ~= "Vector3" or (position - s.root.Position).Magnitude <= radius then safe = false; break end
        end
      end
      if snapshot and gameInfo.isSnapshotValid(snapshot) and snapshot.targetId == localPlayer.UserId then safe = false end
      if safe then s.pendingReset = false; s.stoppedPartner, s.pending, s.dashSwitchPartner = nil, nil, nil end
    end
    if s.haunterPartner then
      local target = userId(gameInfo.getTargetId())
      if s.active or time > s.haunterUntil or not autoEnabled or not utils.isActive() then s.haunterPartner, s.haunterUntil = nil, nil
      elseif target == localPlayer.UserId or target == s.haunterPartner then start(s, "haunter_self", s.haunterPartner, time, nil) end
    end
    if clashStats and not clashStats.frozen and not s.active and not clashContext and time - clashStats.lastObserved > 1.5 then clashStatsModule.finish("clash encerrado", clashStats.lastObserved) end
    if not autoEnabled and not upDashEnabled and not manualEnabled and not s.active and not clashContext and (not clashStats or clashStats.frozen) then
      clashStatsModule.waitForNextClash(); s.pending, s.departedAt, s.departedServerAt, s.departedTo = nil, nil, nil, nil
      return
    end
    evaluate(s, time, false, nil, nil, nil, autoEnabled)
    if typeof(s.lastRootPosition) == "Vector3" and (s.root.Position - s.lastRootPosition).Magnitude > CONFIG.ACTIVATION.HAUNTER_RANGE then
      s.recentRootPosition, s.recentRootAt = s.lastRootPosition, time
    end
    s.lastRootPosition = s.root.Position
  end)
  track(s, character.AncestryChanged, function(_, parent)
    if not parent and current == s then detach("character_removed") end
  end)
  return true
end
function AutoSpam.detachCharacter() detach("detach") end
function AutoSpam.teardown()
  detach("teardown"); clashStatsModule, autoParry = nil, nil
  clashStats = nil; utils, gameInfo, players, runService, localPlayer = nil, nil, nil, nil, nil, nil
end

-- ball-sync
function AutoSpam.onBallSync(data)
  local s = current
  if not s or type(data) ~= "table" then return end
  if data.Source ~= "packet" and data.Teleported ~= true then return end
  if gameInfo.getBallFrozen() == true then
    applyDeactivation(s, nil, now(), false); resetExchange(s)
    s.target = nil; return
  end
  local sequence = data.Sequence or data.TeleportSequence
  if finite(sequence) and finite(s.sequence) then
    local delta = (sequence - s.sequence) % CONFIG.SHARED.SEQUENCE_MODULUS
    if delta == 0 or delta >= CONFIG.SHARED.SEQUENCE_HALF then return end
  end
  if finite(sequence) then s.sequence = sequence end
  if data.Teleported == true then
    s.target, s.stoppedPartner = nil, nil; resetExchange(s)
    s.haunterPartner, s.haunterUntil = nil, nil; return
  end
  if
    utils.getConfigValue("AutoSpam") ~= true
    and not utils.isManualSpamActive()
    and not s.active
    and (not clashStats or clashStats.frozen)
    and not gameInfo.getClashContext()
  then
    s.target = userId(data.TargetPlayerID) or userId(gameInfo.getTargetId()) or s.target; resetExchange(s)
    return
  end
  local time = now(); local target = userId(data.TargetPlayerID)
  local serverTime = tonumber(data.ServerTime); observeTargetReturn(s, target, time)
  if not finite(serverTime) then serverTime = nil end
  local speed = tonumber(data.Speed); local snapshot = gameInfo.getSnapshotAt(time)
  if snapshot and data.Source == "packet" then
    snapshot = table.clone(snapshot)
    if userId(target) then
      snapshot.targetId, snapshot.targeted = target, target == localPlayer.UserId
      if userId(data.TargetPlayerID) then snapshot.targetUncertain = false end
    end
    snapshot.syncAt, snapshot.serverTime, snapshot.syncSequence = time, serverTime, sequence; snapshot.teleported = false
    if type(data.Locked) == "boolean" then snapshot.locked = data.Locked end
    if finite(speed) and speed > 0 then snapshot.syncSpeed = speed end
  end
  local stopped = false
  if gameInfo.isSnapshotValid(snapshot) and not snapshot.teleported and target then
    if not stopped then stopped = applyDeactivation(s, snapshot, time) end
    inspectTarget(s, target, time, snapshot, serverTime)
  end
  evaluate(s, time, true, serverTime, snapshot, stopped)
end

-- public-api
function AutoSpam.isActive() return current ~= nil and current.active end
function AutoSpam.stopSpam()
  if current then stop(current, "stop_spam") end
end
function AutoSpam.getPullEvent() return nil end
function AutoSpam.getDashData()
  local s = current
  local dashing, speed, duration
  if gameInfo then dashing, speed, duration = gameInfo.getLocalDashState() end
  speed, duration = speed or 120, duration or 0.2
  return {
    dashing = dashing == true,
    speed = speed,
    duration = duration,
    idealTravel = speed * duration,
    actualTravel = s and s.dashStart and (s.root.Position - s.dashStart).Magnitude or 0,
    switchPartner = s and s.dashSwitchPartner or nil,
    windowFactor = CONFIG.ACTIVATION.DASH_WINDOW_FACTOR,
  }
end
function AutoSpam.getTargetSwitch()
  local s = current
  return {
    timestampMs = s and (s.lastSwitchAt or 0) * 1000 or 0,
    partnerId = s and s.partner or -1,
    intervalMs = s and (s.intervalMs or 0) or 0,
    resetToken = generation,
  }
end
function AutoSpam.getActivationContext()
  local s = current; return { active = s ~= nil and s.active, reason = s and s.reason or "detached", partner = s and s.partner or -1 }
end

-- status
function AutoSpam.getStatus()
  local s = current
  return {
    schema = utils and utils.apiVersion() or 1,
    phase = s and (s.active and "active" or "idle") or "detached",
    active = s ~= nil and s.active,
    lastGate = s and s.reason or "detached",
    lastStopReason = s and s.lastStopReason or nil,
    lastStopAt = s and s.lastStopAt or nil,
    clashPartnerId = s and s.partner or -1,
    clashStats = clashStats and {
      partnerId = clashStats.partnerId,
      distance = clashStats.distance,
      cps = clashStats.cps,
      currentCps = clashStats.currentCps and (clashStats.frozen and clashStats.currentCps or math.min(
        clashStats.currentCps,
        1 / math.max(clashStats.cycleInterval, now() - clashStats.lastCycleAt)
      )) or nil,
      startSample = clashStats.startSample and table.clone(clashStats.startSample) or nil,
      endSample = clashStats.endSample and table.clone(clashStats.endSample) or nil,
      endReason = clashStats.endReason,
      speed = clashStats.speed,
      frozen = clashStats.frozen,
      duration = clashStats.duration or math.max(0, now() - clashStats.startedAt),
      travelTarget = clashStats.travelTarget,
      travelStartedAt = not clashStats.frozen and clashStats.travelStartedAt or nil,
      lastTravelTime = clashStats.lastTravelTime,
      lastTravelTarget = clashStats.lastTravelTarget,
      fatalTravelTime = clashStats.fatalTravelTime,
      penultimateTravelTime = clashStats.penultimateTravelTime,
      penultimateTarget = clashStats.penultimateTarget,
      deceasedId = clashStats.deceasedId,
    } or nil,
  }
end

-- contract
AutoSpam.__contract = {
  requires = {
    Utils = "utils",
    GameInfo = "gameinfo",
    ClashStats = "clashstats",
    AutoParry = "autoparry",
  },
  requiresMethods = {
    Utils = {
      "now",
      "getLocalPlayer",
      "getPlayers",
      "getRunService",
      "isActive",
      "getConfigValue",
      "isManualSpamActive",
      "setAutoSpamActive",
      "trackCharacter",
      "untrackCharacter",
      "recordTransition",
      "apiVersion",
    },
    GameInfo = {
      "areAbilitiesEnabled",
      "getSnapshotAt",
      "isSnapshotValid",
      "getPlayerDistance",
      "getPlayerMotion",
      "getHaunterEvent",
      "getDeflectGeometry",
      "getDeflectRangeParameters",
      "isPlayerDashing",
      "getLocalDashState",
      "isClientDeflectResetLate",
      "getPlayerDeflectRange",
      "getPlayerRawRadius",
      "getBallFrozen",
      "getTargetId",
      "getBallSpeedLimits",
      "getClashContext",
    },
    AutoParry = { "getPressure" },
    ClashStats = { "begin", "finish", "observe", "freeze", "get", "waitForNextClash" },
  },
  provides = {
    "setup",
    "bindCharacter",
    "detachCharacter",
    "teardown",
    "onBallSync",
    "isActive",
    "getActivationContext",
    "getStatus",
    "getTargetSwitch",
    "getDashData",
    "getPullEvent",
    "stopSpam",
  },
  onBallSync = true,
  bindCharacter = true,
}

return AutoSpam
