-- [[ auto spam ]]

-- module
local AutoSpam = {}
local utils, gameInfo, clashStatsModule, players, runService, localPlayer, cooldownInfo, dashInfo
local current, generation = nil, 0
local clashStats
local lastActivationReason, lastActivationAt, lastStopReason, lastStopAt

-- configuration
local CONFIG = {
  ACTIVATION = {
    RETURN = 0.30,
    KILL_RADIUS_INTERVAL = 0.30,
    EXCHANGE_MAX_INTERVAL = 0.5,
    EXCHANGE_MIN_INTERVAL = 0.1,
    EXCHANGE_READY_TIME = 0.2,
    CLOSE_TARGET_DISTANCE = 5,
    CLOSE_TARGET_TIMEOUT = 0.15,
    REACTIVATION_COOLDOWN = 0.04,
    RADIUS_FACTOR = 1,
    RETURN_RADIUS_FACTOR = 1,
    MIN_OPPONENT_DISTANCE = 20,
    MAX_DISTANCE_REFERENCE = 51,
    HAUNTER_RANGE = 11,
    HAUNTER_MATCH_RADIUS = 5,
    DASH_WINDOW_FACTOR = 0.4,
    DASH_MAX_SNAPSHOT_AGE = 0.15,
    DASH_MIN_CPS = 4,
    DASH_MIN_SCORE = 75,
    DASH_MIN_ALIGNMENT = 0.6,
    DASH_DETECTION_RANGE = 70,
  },
  DEACTIVATION = {
    STATIONARY_TIMEOUT = 0.3,
    STATIONARY_EPSILON = 0.05,
    HAUNTER_CONFIRM_TIMEOUT = 0.1,
    MANUAL_COOLDOWN_FACTOR = 1.3,
    DASH_ESCAPE_COOLDOWN = 0.05,
    DASH_ESCAPE_MIN_OUTWARD_SPEED = 15,
    DASH_ESCAPE_MIN_HORIZONTAL_RATIO = 0.35,
    DASH_ESCAPE_MIN_SEPARATION_GAIN = 2,
    RETURN_TIMEOUT_MIN_SPEED = 0.4,
    RETURN_TIMEOUT_MAX_SPEED = 0.2,
    DEFLECT_COOLDOWN_TIMEOUT = 0.09,
    CLASH_GRACE_PERIOD = 0.15,
    TARGET_RETURN_TIMEOUT_MIN_SPEED = 0.15,
    TARGET_RETURN_TIMEOUT_MAX_SPEED = 0.22,
    COOLDOWN_PROTECTION_RADIUS = 16,
    RETURN_PROTECTION_RADIUS = 10,
    COOLDOWN_PROTECTION_MAX_SPEED_RADIUS = 40,
    RETURN_PROTECTION_MAX_SPEED_RADIUS = 25,
  },
  SHARED = {
    MIN_RETURN = 1 / 25,
    SNAPSHOT_MAX_AGE = 0.5,
    SEQUENCE_MODULUS = 65536,
    SEQUENCE_HALF = 32768,
    RUNTIME_TICK_INTERVAL = 1 / 120,
  },
}

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function userId(value)
  if type(value) == "string" then value = tonumber(value) end
  return finite(value) and value > 0 and value % 1 == 0 and value or nil
end
local function now() return utils.now() end
local function networkLatency()
  local ping = gameInfo.getAveragePing(); return finite(ping) and math.max(0, ping) * 0.5 or 0
end
local function compensatedRadius(id, speed)
  local radius = gameInfo.getPlayerRawRadius(id, speed, false)
  if not finite(radius) then return nil end
  return radius + (id == localPlayer.UserId and finite(speed) and math.max(0, speed) * networkLatency() or 0)
end
local function elapsed(localStart, serverStart, time, serverTime)
  if finite(serverStart) and finite(serverTime) then return serverTime >= serverStart and serverTime - serverStart or nil end
  return finite(localStart) and time >= localStart and time - localStart or nil
end
local function snapshotSpeed(snapshot)
  if not snapshot then return nil end
  local speed = tonumber(snapshot.syncSpeed); return finite(speed) and speed > 0 and speed or snapshot.speed
end
local function freshSnapshot(snapshot, time)
  return snapshot
    and gameInfo.isSnapshotValid(snapshot)
    and snapshot.targetUncertain ~= true
    and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE))
end
local function speedInterval(snapshot, slow, fast)
  local speed = snapshotSpeed(snapshot); local minimum, maximum = gameInfo.getBallSpeedLimits()
  local progress = finite(speed) and finite(minimum) and finite(maximum) and maximum > minimum and math.clamp((speed - minimum) / (maximum - minimum), 0, 1)
    or 0
  return slow + (fast - slow) * progress
end
local function returnTimeout(snapshot, state, time)
  local fresh = snapshot
    and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE))
  local speed = fresh and snapshotSpeed(snapshot) or nil
  if finite(speed) and speed > 0 then state.returnTimeoutSpeed = speed else speed = state.returnTimeoutSpeed end
  local slow, fast = CONFIG.DEACTIVATION.RETURN_TIMEOUT_MIN_SPEED, CONFIG.DEACTIVATION.RETURN_TIMEOUT_MAX_SPEED; local minimum, maximum = gameInfo.getBallSpeedLimits()
  local progress = 0
  if finite(speed) and finite(minimum) and finite(maximum) and maximum > minimum then progress = math.clamp((speed - minimum) / (maximum - minimum), 0, 1) end
  local ping = gameInfo.getAveragePing(); return slow + (fast - slow) * progress + (finite(ping) and math.max(0, ping) or 0)
end
local function targetReturnTimeout(snapshot, state, time)
  local fresh = snapshot
    and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE))
  local speed = fresh and snapshotSpeed(snapshot) or nil
  if finite(speed) and speed > 0 then state.targetReturnSpeed = speed else speed = state.targetReturnSpeed end
  local minimum, maximum = gameInfo.getBallSpeedLimits(); local progress = 0
  if finite(speed) and finite(minimum) and finite(maximum) and maximum > minimum then progress = math.clamp((speed - minimum) / (maximum - minimum), 0, 1) end
  local slow, fast = CONFIG.DEACTIVATION.TARGET_RETURN_TIMEOUT_MIN_SPEED, CONFIG.DEACTIVATION.TARGET_RETURN_TIMEOUT_MAX_SPEED; return slow + (fast - slow) * progress
end
local function listen(state, signal, callback)
  local connection = signal:Connect(callback); state.connections[#state.connections + 1] = connection
  utils.trackCharacter(connection); return connection
end
local function forget(state, connection)
  if not connection then return end
  if utils then utils.untrackCharacter(connection) end
  connection:Disconnect(); local index = table.find(state.connections, connection)
  if index then table.remove(state.connections, index) end
end
local function disconnectAll(state)
  for index = #state.connections, 1, -1 do
    local connection = state.connections[index]; state.connections[index] = nil
    if utils then utils.untrackCharacter(connection) end
    connection:Disconnect()
  end
end
local function resetExchange(state)
  state.exchangeFrom, state.exchangeTo, state.exchangeAt = nil, nil, nil; state.exchangePartner, state.exchangeReadyAt = nil, nil
  state.pending, state.departedAt, state.departedServerAt, state.departedTo = nil, nil, nil, nil; state.closeTargetAt, state.closeTargetPartner = nil, nil
end
local function newState(character, root)
  return {
    character = character,
    root = root,
    connections = {},
    active = false,
    reason = "waiting",
    generation = generation,
    lastRootPosition = root.Position,
    pendingReset = false,
    lastTickAt = -math.huge,
  }
end
local function distanceLimit(snapshot, partner)
  local speed = snapshotSpeed(snapshot)
  if not finite(speed) or speed <= 0 then return nil end
  local minimum, maximum = gameInfo.getBallSpeedLimits(); local baseRange, resilienceMax = gameInfo.getDeflectRangeParameters()
  local ownRange, otherRange = gameInfo.getPlayerDeflectRange(localPlayer.UserId), gameInfo.getPlayerDeflectRange(partner)
  local ownRaw, otherRaw = compensatedRadius(localPlayer.UserId, speed), gameInfo.getPlayerRawRadius(partner, speed, false)
  if
    not finite(minimum)
    or not finite(maximum)
    or maximum <= minimum
    or not finite(baseRange)
    or not finite(resilienceMax)
    or not finite(ownRange)
    or not finite(otherRange)
    or not finite(ownRaw)
    or not finite(otherRaw)
  then
    return nil
  end
  local factor = math.clamp((speed - minimum) / (maximum - minimum), 0, 1); local base = CONFIG.ACTIVATION.MIN_OPPONENT_DISTANCE
    + (CONFIG.ACTIVATION.MAX_DISTANCE_REFERENCE - resilienceMax * 2 - CONFIG.ACTIVATION.MIN_OPPONENT_DISTANCE) * factor
  local resilience = math.clamp(ownRange - baseRange, 0, resilienceMax) + math.clamp(otherRange - baseRange, 0, resilienceMax)
  return base + resilience * factor + math.max(0, ownRaw - ownRange) + math.max(0, otherRaw - otherRange)
end
local function geometry(snapshot, factor)
  local speed = snapshotSpeed(snapshot)
  if not finite(speed) or speed <= 0 then return nil end
  local value = gameInfo.getDeflectGeometry(speed, "game", factor, false, networkLatency()); return value, speed, value and value.deflectWindow
end
local function distanceGate(state, snapshot, partner)
  if not state.root.Parent or not snapshot or typeof(snapshot.position) ~= "Vector3" then return "distance_unavailable" end
  local speed = snapshotSpeed(snapshot); local value = finite(speed) and speed > 0 and gameInfo.getDeflectGeometry(speed, "game", CONFIG.ACTIVATION.RADIUS_FACTOR, false, networkLatency())
  local opponent, limit = partner and gameInfo.getPlayerMotion(partner), distanceLimit(snapshot, partner)
  if not value or typeof(opponent) ~= "Vector3" or not limit then return "distance_unavailable" end
  local own = state.root.Position
  if (opponent - own).Magnitude > limit then return "opponent_distance" end
  return math.max(0, (snapshot.position - own).Magnitude - value.noWindowParryRadius) / speed > value.effectiveWindow and "ball_distance" or nil
end
local function playerIsAlive(id)
  local player = id and players:GetPlayerByUserId(id); local character = player and player.Character
  local humanoid = character and character.Parent and character:FindFirstChildOfClass("Humanoid"); return humanoid ~= nil and humanoid.Health > 0
end
local function returnWindow(window, speed, base, uncertainty)
  local minimum, maximum = gameInfo.getBallSpeedLimits(); local factor = maximum > minimum and math.clamp((speed - minimum) / (maximum - minimum), 0, 1) or 0
  return math.max(CONFIG.SHARED.MIN_RETURN, math.min(base * (1 - 0.9 * factor) + (finite(uncertainty) and math.max(0, uncertainty) or 0), window))
end
local function sampleOwnDash(state, time)
  if not gameInfo.isPlayerDashing(localPlayer) then state.dashStart, state.dashAt = nil, nil; return end
  if not state.dashStart or time - state.dashAt > 0.85 then state.dashStart, state.dashAt = state.root.Position, time end
end
local function activationGeometry(state, snapshot, partner, time) return geometry(snapshot, CONFIG.ACTIVATION.RETURN_RADIUS_FACTOR) end

-- protection
local watchOpponent
local function opponentOutside(state, radius, maxRadius, snapshot, time)
  local fresh = snapshot
    and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE))
  local speed = fresh and snapshotSpeed(snapshot) or nil
  if finite(speed) and speed > 0 then state.protectionSpeed = speed else speed = state.protectionSpeed end
  local minimum, maximum = gameInfo.getBallSpeedLimits()
  if not finite(speed) or not finite(minimum) or not finite(maximum) or maximum <= minimum then return false end
  local progress = math.clamp((speed - minimum) / (maximum - minimum), 0, 1); radius = radius + (maxRadius - radius) * progress
  if not state.partner or not state.root or not state.root.Parent then return false end
  local position = gameInfo.getPlayerMotion(state.partner)
  if typeof(position) ~= "Vector3" then
    local player = players:GetPlayerByUserId(state.partner); local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") and root.Parent then position = root.Position end
  end
  if typeof(position) ~= "Vector3" then return false end
  return (position - state.root.Position).Magnitude > radius
end
local function resetMotion(state)
  state.motionBall, state.motionPosition, state.motionAt = nil, nil, nil; state.stationary = false
end
local function observeMotion(state, snapshot, time)
  if not freshSnapshot(snapshot, time) then resetMotion(state); return end
  if snapshot.teleported then
    resetMotion(state); state.teleporting = true
    resetExchange(state); return
  end
  if state.teleporting then
    state.teleporting = false; resetMotion(state)
    state.activatedAt = state.active and time or state.activatedAt; state.deflectCooldownSince = nil
    state.haunterWindowConfirmed = false
    if state.active and state.target == state.partner then state.departedAt = time end
  end
  if state.motionBall ~= snapshot.ball then
    resetMotion(state); resetExchange(state)
    state.target, state.previousOpponent = nil, nil; state.motionBall, state.motionPosition, state.motionAt = snapshot.ball, snapshot.position, time
  elseif not state.motionPosition or (snapshot.position - state.motionPosition).Magnitude > CONFIG.DEACTIVATION.STATIONARY_EPSILON then
    state.motionPosition, state.motionAt, state.stationary = snapshot.position, time, false
  elseif state.motionAt and time - state.motionAt > CONFIG.DEACTIVATION.STATIONARY_TIMEOUT then
    state.stationary = true
  end
end
local function cooldownExpired(state, snapshot, time, multiplier)
  local cooldown = cooldownInfo.getDeflectCooldownState()
  if cooldown and cooldown.blocking == true then
    local start = finite(cooldown.blockingSince) and cooldown.blockingSince <= time and cooldown.blockingSince or state.deflectCooldownSince or time
    state.deflectCooldownSince = state.deflectCooldownSince or math.max(state.activatedAt or time, start); state.deflectCooldownSince = math.max(state.deflectCooldownSince, start)
  else
    state.deflectCooldownSince = nil
  end
  local limit = CONFIG.DEACTIVATION.DEFLECT_COOLDOWN_TIMEOUT * (multiplier or 1); return state.activatedAt
    and state.deflectCooldownSince
    and time - state.activatedAt >= limit
    and time - state.deflectCooldownSince >= limit
    and opponentOutside(state, CONFIG.DEACTIVATION.COOLDOWN_PROTECTION_RADIUS, CONFIG.DEACTIVATION.COOLDOWN_PROTECTION_MAX_SPEED_RADIUS, snapshot, time)
end
local function dashEscapeRisk(state, tracker, snapshot, time)
  if not state.root or not state.root.Parent or state.teleporting or not tracker or not tracker.partner then return nil end
  if not freshSnapshot(snapshot, time) or snapshot.teleported or snapshot.locked or snapshot.targetId ~= tracker.partner then return nil end
  if not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or time < snapshot.syncAt or time - snapshot.syncAt > CONFIG.ACTIVATION.DASH_MAX_SNAPSHOT_AGE then return nil end
  if not playerIsAlive(tracker.partner) then return nil end
  local own = state.root.Position; local other, otherVelocity = gameInfo.getPlayerMotion(tracker.partner)
  if typeof(own) ~= "Vector3" or typeof(other) ~= "Vector3" or typeof(snapshot.velocity) ~= "Vector3" then return nil end
  local delta = other - own; local horizontal = Vector3.new(delta.X, 0, delta.Z)
  local distance = delta.Magnitude; local flatDistance = horizontal.Magnitude
  if not finite(distance) or not finite(flatDistance) or flatDistance < 1 then return nil end
  local speed = snapshotSpeed(snapshot); local g = geometry(snapshot, CONFIG.ACTIVATION.RADIUS_FACTOR)
  local ownRadius, otherRadius = compensatedRadius(localPlayer.UserId, speed), gameInfo.getPlayerRawRadius(tracker.partner, speed, false)
  if not g or not finite(speed) or speed <= 0 or not finite(ownRadius) or not finite(otherRadius) or not finite(g.deflectWindow) then return nil end
  local towardOther = other - snapshot.position
  if snapshot.velocity:Dot(towardOther) <= 0 then return nil end
  local ownWindow = ownRadius + speed * (g.deflectWindow * CONFIG.ACTIVATION.DASH_WINDOW_FACTOR + networkLatency())
  if (snapshot.position - own).Magnitude <= ownWindow then return nil end
  local localVelocity = state.root.AssemblyLinearVelocity
  if typeof(localVelocity) ~= "Vector3" then localVelocity = Vector3.zero end
  if typeof(otherVelocity) ~= "Vector3" then otherVelocity = Vector3.zero end
  local function candidate(sample, selfDash)
    if not sample or not sample.signalActive or not sample.normalModel or typeof(sample.velocity) ~= "Vector3" then return nil end
    local velocity, remaining = sample.velocity, sample.normalModel.estimatedRemaining; local magnitude = velocity.Magnitude
    local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
    if not finite(magnitude) or magnitude < 70 or magnitude > 140 or not finite(remaining) or remaining <= 0 then return nil end
    if horizontalSpeed < magnitude * CONFIG.DEACTIVATION.DASH_ESCAPE_MIN_HORIZONTAL_RATIO then return nil end
    local away = velocity:Dot(horizontal) / flatDistance * (selfDash and -1 or 1)
    if not finite(away) or away < CONFIG.DEACTIVATION.DASH_ESCAPE_MIN_OUTWARD_SPEED then return nil end
    local drift = selfDash and otherVelocity or localVelocity
    if not finite(drift.Magnitude) or drift.Magnitude > 40 then drift = Vector3.zero end
    local relativeVelocity = selfDash and (drift - velocity) or (velocity - drift); local projectedDistance = (delta + relativeVelocity * remaining).Magnitude
    local threshold = ownRadius + otherRadius + speed * g.deflectWindow * CONFIG.ACTIVATION.DASH_WINDOW_FACTOR
    if
      not finite(projectedDistance)
      or projectedDistance <= threshold
      or projectedDistance - distance < CONFIG.DEACTIVATION.DASH_ESCAPE_MIN_SEPARATION_GAIN
    then
      return nil
    end
    return {
      reason = selfDash and "self_dash_escape" or "opponent_dash_escape",
      distance = distance,
      projectedDistance = projectedDistance,
      threshold = threshold,
    }
  end
  local result = candidate(dashInfo.getEstimate(tracker.partner), false) or candidate(dashInfo.getEstimate(localPlayer.UserId), true)
  if not result then tracker.dashEscapeSince = nil; return nil end
  local cooldown = cooldownInfo.getDeflectCooldownState()
  if not cooldown or cooldown.blocking ~= true or cooldown.source == "unknown" then tracker.dashEscapeSince = nil; return nil end
  local start = finite(cooldown.blockingSince) and cooldown.blockingSince <= time and cooldown.blockingSince or tracker.dashEscapeSince or time
  tracker.dashEscapeSince = math.max(tracker.activatedAt or time, start)
  if time - tracker.dashEscapeSince < CONFIG.DEACTIVATION.DASH_ESCAPE_COOLDOWN then return nil end
  return result
end
local function activate(state, reason, partner, time, serverTime, snapshot)
  if
    reason ~= "return_target"
    and reason ~= "kill_radius"
    and reason ~= "haunter"
    and reason ~= "haunter_self"
    and reason ~= "close_target"
    and reason ~= "dash_incoming"
    and reason ~= "dash_self"
  then
    return false
  end
  if
    current ~= state
    or state.active
    or not utils.isActive()
    or utils.getConfigValue("AutoSpam") ~= true
    or (reason ~= "kill_radius" and not partner)
    or (partner ~= nil and (partner == localPlayer.UserId or not playerIsAlive(partner)))
    or state.stationary == true
    or state.teleporting == true
    or state.timeoutBlocked == true
    or (state.lastDeactivatedAt and time - state.lastDeactivatedAt < CONFIG.ACTIVATION.REACTIVATION_COOLDOWN)
  then
    return false
  end
  local dashPrediction = reason == "dash_incoming" or reason == "dash_self"
  local bypassExchange = dashPrediction or reason == "haunter" or reason == "haunter_self" or reason == "kill_radius" or reason == "close_target"
  if
    not bypassExchange
    and (
      not state.exchangeReadyAt
      or state.exchangePartner ~= partner
      or time < state.exchangeReadyAt
      or time - state.exchangeReadyAt > CONFIG.ACTIVATION.EXCHANGE_READY_TIME
    )
  then
    return false
  end
  snapshot = snapshot or gameInfo.getSnapshotAt(time)
  if
    not gameInfo.isSnapshotValid(snapshot)
    or snapshot.targetUncertain == true
    or (snapshot.targetId ~= localPlayer.UserId and (not dashPrediction or snapshot.targetId ~= partner))
    or snapshot.teleported == true
    or snapshot.locked == true
    or not state.root
    or not state.root.Parent
    or typeof(snapshot.position) ~= "Vector3"
    or typeof(snapshot.velocity) ~= "Vector3"
  then
    return false
  end
  if finite(snapshot.syncAt) and snapshot.syncAt > 0 and (time < snapshot.syncAt or time - snapshot.syncAt > CONFIG.SHARED.SNAPSHOT_MAX_AGE) then return false end
  local targetPosition = dashPrediction and snapshot.targetId == partner and gameInfo.getPlayerMotion(partner) or state.root.Position
  if typeof(targetPosition) ~= "Vector3" then return false end
  local toward = targetPosition - snapshot.position
  if reason ~= "close_target" and (toward.Magnitude <= 0.05 or snapshot.velocity:Dot(toward) <= 0) then return false end
  if reason == "close_target" and toward.Magnitude > CONFIG.ACTIVATION.CLOSE_TARGET_DISTANCE then return false end
  if not bypassExchange then
    local blockedBy = distanceGate(state, snapshot, partner)
    if blockedBy ~= nil and not (reason == "return_target" and blockedBy == "ball_distance") then return false end
  end
  if partner and clashStats and clashStats.frozen then clashStatsModule.begin(partner, time); clashStats = clashStatsModule.get() end
  state.active, state.partner, state.pending = true, partner, nil; state.stoppedPartner, state.stoppedAt = nil, nil
  state.killRadiusInside, state.killRadiusFirstAt, state.killRadiusBall = nil, nil, nil; state.dashSwitchPartner, state.dashSwitchAt = nil, nil
  state.closeTargetAt, state.closeTargetPartner = nil, nil; state.haunterWindowConfirmed = false
  state.deflectCooldownSince, state.cooldownSpeed = nil, snapshotSpeed(snapshot); state.activatedAt = time
  state.targetReturnSpeed = snapshotSpeed(snapshot); state.protectionSpeed = snapshotSpeed(snapshot)
  state.lastSwitchAt, state.lastSwitchServerAt = time, serverTime; state.reason = reason
  lastActivationReason, lastActivationAt = reason, time
  if watchOpponent then watchOpponent(state, partner) end
  utils.setAutoSpamActive(true); utils.recordTransition("AutoSpam", "idle", "active", reason)
  return true
end
local function deactivate(state, reason, time)
  if current ~= state then return false end
  time = time or now()
  if state.active then
    state.stoppedPartner, state.stoppedAt = state.partner, time; state.active, state.lastDeactivatedAt = false, time
    if reason == "deflect_cooldown_timeout" or reason == "opponent_dash_escape" or reason == "self_dash_escape" then state.timeoutBlocked, state.timeoutBlockedTarget = true, state.target end
    lastStopReason, lastStopAt = reason, time; utils.setAutoSpamActive(false)
    utils.recordTransition("AutoSpam", "active", "idle", reason)
  end
  state.reason, state.pending, state.partner = reason, nil, nil; state.haunterPartner, state.haunterUntil = nil, nil
  if watchOpponent then watchOpponent(state, nil) end
  state.activatedAt, state.deflectCooldownSince = nil, nil; resetExchange(state)
  return true
end
local function deactivationReason(state, snapshot, time)
  if not utils.isActive() then return "hub_inactive" end
  if utils.getConfigValue("AutoSpam") ~= true then return "disabled" end
  if state.teleporting or (snapshot and snapshot.teleported) then return nil end
  if gameInfo.getBallFrozen() == true then return "ball_frozen" end
  if state.stationary then return "ball_stationary" end
  local escape = dashEscapeRisk(state, state, snapshot, time); state.dashEscape = escape
  if escape then return escape.reason end
  if cooldownExpired(state, snapshot, time) then return "deflect_cooldown_timeout" end
  if
    state.reason == "haunter"
    or state.reason == "haunter_self"
    or state.reason == "close_target"
    or state.reason == "dash_incoming"
    or state.reason == "dash_self"
  then
    local age = time - (state.activatedAt or time); local fresh = freshSnapshot(snapshot, time) and not snapshot.locked
    local value = fresh and geometry(snapshot, CONFIG.ACTIVATION.RADIUS_FACTOR); local ballTarget = fresh and userId(snapshot.targetId)
    local targetPosition = ballTarget == state.partner and gameInfo.getPlayerMotion(state.partner) or state.root.Position
    local targetRange = ballTarget == state.partner and gameInfo.getPlayerRawRadius(state.partner, snapshotSpeed(snapshot), false)
      or (value and value.noWindowParryRadius)
    local inWindow = value
      and typeof(targetPosition) == "Vector3"
      and finite(targetRange)
      and (snapshot.position - targetPosition).Magnitude <= targetRange + snapshotSpeed(snapshot) * value.effectiveWindow
    if inWindow then state.haunterWindowConfirmed = true end
    if age >= CONFIG.DEACTIVATION.HAUNTER_CONFIRM_TIMEOUT then
      if not state.haunterWindowConfirmed or not fresh then return "haunter_window_unconfirmed" end
      local opponent = state.partner and gameInfo.getPlayerMotion(state.partner); local limit = distanceLimit(snapshot, state.partner)
      if typeof(opponent) ~= "Vector3" or not limit or (opponent - state.root.Position).Magnitude > limit then return "opponent_distance" end
      local target = userId(snapshot.targetId)
      if target ~= localPlayer.UserId and target ~= state.partner then return "haunter_target_changed" end
      if target == localPlayer.UserId and not inWindow then return "haunter_ball_outside_window" end
      local wait = speedInterval(snapshot, 0.15, 0.04) + networkLatency()
      if target == state.partner and state.departedAt and time - state.departedAt >= wait then return "haunter_return_timeout" end
    end
  end
  if
    state.activatedAt
    and time - state.activatedAt >= CONFIG.DEACTIVATION.CLASH_GRACE_PERIOD
    and state.target == state.partner
    and state.departedAt
    and time - state.departedAt >= targetReturnTimeout(snapshot, state, time)
    and opponentOutside(state, CONFIG.DEACTIVATION.RETURN_PROTECTION_RADIUS, CONFIG.DEACTIVATION.RETURN_PROTECTION_MAX_SPEED_RADIUS, snapshot, time)
  then
    return "target_return_timeout"
  end
  if
    snapshot
    and gameInfo.isSnapshotValid(snapshot)
    and snapshot.targetUncertain ~= true
    and not snapshot.teleported
    and not snapshot.locked
    and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE))
  then
    local target = userId(snapshot.targetId)
    if target and target ~= localPlayer.UserId and target ~= state.partner then
      local position = gameInfo.getPlayerMotion(target); local value = geometry(snapshot, CONFIG.ACTIVATION.RADIUS_FACTOR)
      if typeof(position) == "Vector3" and value and (position - state.root.Position).Magnitude > value.fullRadius then return "target_outside_window" end
    end
  end
end
local function checkDeactivation(state, snapshot, time)
  if not state.active then return false end
  local reason = deactivationReason(state, snapshot, time); return reason ~= nil and deactivate(state, reason, time)
end

-- target-tracking
local function canActivateReturn(state, snapshot, time)
  if
    not utils.isActive()
    or utils.getConfigValue("AutoSpam") ~= true
    or not state.pending
    or state.target ~= localPlayer.UserId
    or not snapshot
    or snapshot.targetUncertain
    or snapshot.targetId ~= localPlayer.UserId
    or gameInfo.getBallFrozen() == true
    or typeof(snapshot.position) ~= "Vector3"
  then
    return false
  end
  local toward = state.root.Position - snapshot.position; local distance = toward.Magnitude
  local value = activationGeometry(state, snapshot, state.pending.partner, time)
  if not value or distance <= 0 or typeof(snapshot.velocity) ~= "Vector3" then return false end
  local closingSpeed = snapshot.velocity:Dot(toward) / distance; return finite(closingSpeed) and closingSpeed > 0 and distance <= value.fullRadius + closingSpeed * value.effectiveWindow * 0.8
end
local function armReturn(state, previous, time, snapshot, serverTime)
  if
    state.active
    or not previous
    or previous == localPlayer.UserId
    or previous ~= state.departedTo
    or state.pending
    or previous == state.stoppedPartner
    or not state.departedAt
  then
    return
  end
  local value, speed, window = activationGeometry(state, snapshot, previous, time); local duration = elapsed(state.departedAt, state.departedServerAt, time, serverTime)
  if not value or not window or not duration then return end
  local uncertainty = finite(state.departedServerAt) and finite(serverTime) and 0 or networkLatency(); local startedNear = (snapshot.position - state.root.Position).Magnitude <= value.fullRadius
  local fastReturn = duration <= returnWindow(window, speed, CONFIG.ACTIVATION.RETURN, uncertainty)
  if startedNear and not fastReturn then return end
  state.pending = { partner = previous, startedNear = startedNear, fastReturn = fastReturn }
end
local function targetChanged(state, target, time, snapshot, serverTime)
  if not target or target == state.target then return end
  local previous, ownId = state.target, localPlayer.UserId; local switchedToMe = target == ownId and previous and previous ~= ownId
  state.closeTargetAt, state.closeTargetPartner = nil, nil
  if previous and (previous == ownId or target == ownId) then state.dashExchangeAt, state.dashExchangePartner = time, previous == ownId and target or previous end
  if previous and previous ~= ownId then state.previousOpponent = previous end
  if target ~= ownId then state.previousOpponent = target end
  if switchedToMe and not state.active and freshSnapshot(snapshot, time) and not snapshot.teleported and not snapshot.locked then
    local context = gameInfo.getGameContext()
    if context.inMatch == true and (snapshot.position - state.root.Position).Magnitude <= CONFIG.ACTIVATION.CLOSE_TARGET_DISTANCE then
      state.closeTargetAt, state.closeTargetPartner = time, previous
    end
  end
  if state.active and not state.partner and previous == ownId and target ~= ownId and playerIsAlive(target) then
    state.partner = target
    if watchOpponent then watchOpponent(state, target) end
  end
  local exchangeReady
  if
    previous
    and state.exchangeFrom == target
    and state.exchangeTo == previous
    and (target == ownId or previous == ownId)
    and state.exchangeAt
    and time >= state.exchangeAt
    and time - state.exchangeAt
      <= speedInterval(snapshot, CONFIG.ACTIVATION.EXCHANGE_MAX_INTERVAL, CONFIG.ACTIVATION.EXCHANGE_MIN_INTERVAL) + networkLatency()
  then
    exchangeReady = target == ownId and previous or target
  end
  state.exchangePartner, state.exchangeReadyAt = exchangeReady, exchangeReady and time or nil
  if previous and (previous == ownId or target == ownId) then state.exchangeFrom, state.exchangeTo, state.exchangeAt = previous, target, time
  else state.exchangeFrom, state.exchangeTo, state.exchangeAt = nil, nil, nil end
  if previous and previous ~= target and (previous == ownId or target == ownId) then
    if state.dashStart then state.dashSwitchPartner, state.dashSwitchAt = previous == ownId and target or previous, time else state.dashSwitchPartner, state.dashSwitchAt = nil, nil end
  else
    state.dashSwitchPartner, state.dashSwitchAt = nil, nil
  end
  if previous == ownId and target ~= ownId then
    state.departedAt, state.departedServerAt, state.departedTo = time, serverTime, target
  elseif switchedToMe then
    local matchingReturn = previous == state.departedTo and state.departedAt
    if not state.active and matchingReturn then armReturn(state, previous, time, snapshot, serverTime) end
    state.departedAt, state.departedServerAt, state.departedTo = nil, nil, nil
  end
  if
    state.stoppedPartner
    and previous
    and previous ~= target
    and state.stoppedAt
    and ((previous == ownId and target == state.stoppedPartner) or (target == ownId and previous == state.stoppedPartner))
  then
    state.stoppedPartner, state.stoppedAt = nil, nil
  end
  if not state.active and state.pending and target ~= ownId then state.pending = nil end
  local switchElapsed = elapsed(state.lastSwitchAt, state.lastSwitchServerAt, time, serverTime)
  if switchElapsed then state.intervalMs = switchElapsed * 1000 end
  state.target, state.lastSwitchAt, state.lastSwitchServerAt = target, time, serverTime
end
local function safeToReset(state, time)
  if not state.pendingReset or (state.resetCheckAt and time - state.resetCheckAt < 0.15) then return end
  state.resetCheckAt = time; local snapshot = gameInfo.getSnapshotAt(time)
  local speed = snapshot and (snapshot.syncSpeed or snapshot.speed) or 16; local radius = compensatedRadius(localPlayer.UserId, speed) or select(1, gameInfo.getDeflectRangeParameters()) or 16
  for _, player in ipairs(players:GetPlayers()) do
    if player ~= localPlayer and playerIsAlive(player.UserId) then
      local position = gameInfo.getPlayerMotion(player.UserId)
      if typeof(position) ~= "Vector3" or (position - state.root.Position).Magnitude <= radius then return end
    end
  end
  if snapshot and gameInfo.isSnapshotValid(snapshot) and snapshot.targetId == localPlayer.UserId then return end
  state.pendingReset, state.stoppedPartner, state.pending, state.dashSwitchPartner = false, nil, nil, nil
end
local function observeKillRadius(state, snapshot, time)
  if
    not snapshot
    or not gameInfo.isSnapshotValid(snapshot)
    or snapshot.targetUncertain == true
    or snapshot.teleported
    or snapshot.locked
    or not state.root.Parent
  then
    state.killRadiusInside, state.killRadiusFirstAt, state.killRadiusBall = nil, nil, nil; return nil
  end
  if state.killRadiusBall ~= snapshot.ball then state.killRadiusInside, state.killRadiusFirstAt, state.killRadiusBall = nil, nil, snapshot.ball end
  local physics = gameInfo.getDefensePhysics(); local radius = physics and physics.killRadius
  if not finite(radius) or radius <= 0 then state.killRadiusInside, state.killRadiusFirstAt = nil, nil; return nil end
  local inside = (snapshot.position - state.root.Position).Magnitude <= radius; local entered = inside and not state.killRadiusInside
  state.killRadiusInside = inside
  if not entered or snapshot.targetId ~= localPlayer.UserId then return nil end
  local first = state.killRadiusFirstAt; state.killRadiusFirstAt = time
  local speed = snapshotSpeed(snapshot); local window = finite(speed) and speed > 0 and gameInfo.getDeflectWindow(speed) or nil
  if not finite(window) then return nil end
  if not first or time < first or time - first > returnWindow(window, speed, CONFIG.ACTIVATION.KILL_RADIUS_INTERVAL, networkLatency()) then return nil end
  state.killRadiusFirstAt = nil; return true
end
local function dashPrediction(state, snapshot, time)
  local partner, switchedAt = state.dashExchangePartner, state.dashExchangeAt
  if not partner or not switchedAt or time < switchedAt or time - switchedAt > 0.25 or not playerIsAlive(partner) then return nil end
  if not freshSnapshot(snapshot, time) or snapshot.teleported or snapshot.locked then return nil end
  if not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or time < snapshot.syncAt or time - snapshot.syncAt > CONFIG.ACTIVATION.DASH_MAX_SNAPSHOT_AGE then return nil end
  if snapshot.targetId ~= localPlayer.UserId and snapshot.targetId ~= partner then return nil end
  local other = gameInfo.getPlayerMotion(partner); local own = state.root.Position
  if typeof(other) ~= "Vector3" or typeof(own) ~= "Vector3" then return nil end
  local speed = snapshotSpeed(snapshot); local g = geometry(snapshot, CONFIG.ACTIVATION.RADIUS_FACTOR)
  local ownRadius = compensatedRadius(localPlayer.UserId, speed); local otherRadius = gameInfo.getPlayerRawRadius(partner, speed, false)
  if not g or not finite(speed) or speed <= 0 or not finite(ownRadius) or not finite(otherRadius) then return nil end
  local targetPos, targetRadius = snapshot.targetId == partner and other or own, snapshot.targetId == partner and otherRadius or ownRadius; local ballToTarget = targetPos - snapshot.position
  if typeof(snapshot.velocity) ~= "Vector3" or ballToTarget.Magnitude <= 0.05 or snapshot.velocity:Dot(ballToTarget) <= 0 then return nil end
  if ballToTarget.Magnitude > targetRadius + speed * g.effectiveWindow then return nil end
  local ownDash, otherDash = dashInfo.getEstimate(localPlayer.UserId), dashInfo.getEstimate(partner)
  local function model(sample, relative, reason)
    if not sample or not sample.signalActive or not sample.normalModel or not sample.velocity or not sample.observedAt then return nil end
    local age = time - sample.observedAt
    if age < 0 or age > 0.2 or switchedAt < sample.observedAt - 0.05 or switchedAt > time then return nil end
    local velocity, distance = sample.velocity, relative.Magnitude
    if not finite(distance) or not finite(velocity.Magnitude) or distance <= 0.05 or velocity.Magnitude < 70 or velocity.Magnitude > 140 then return nil end
    local closing = velocity:Dot(relative) / distance; local alignment = closing / velocity.Magnitude
    if not finite(alignment) or alignment < CONFIG.ACTIVATION.DASH_MIN_ALIGNMENT then return nil end
    local remaining = sample.normalModel.estimatedRemaining
    if not finite(remaining) or remaining <= 0 then return nil end
    local closestAt = math.clamp(relative:Dot(velocity) / velocity:Dot(velocity), 0, remaining); local projected = relative - velocity * closestAt
    local predictedDistance = projected.Magnitude
    local ok, obstruction = pcall(function()
      local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude
      local otherPlayer = players:GetPlayerByUserId(partner); params.FilterDescendantsInstances = { state.character, otherPlayer.Character, snapshot.ball }
      params.RespectCanCollide = true; return utils.getWorkspace():Raycast(sample.position, velocity * closestAt, params)
    end)
    if not ok or obstruction then return nil end
    local travelGap = math.max(0, predictedDistance - ownRadius - otherRadius); local cycle = math.max(2 * travelGap / speed, 1 / 50)
    local cps = 1 / cycle; local predictedRange = ownRadius + otherRadius + speed * g.deflectWindow * CONFIG.ACTIVATION.DASH_WINDOW_FACTOR
    if predictedDistance > predictedRange or cps < CONFIG.ACTIVATION.DASH_MIN_CPS then return nil end
    local score = 50
      + 25 * math.clamp((alignment - CONFIG.ACTIVATION.DASH_MIN_ALIGNMENT) / (1 - CONFIG.ACTIVATION.DASH_MIN_ALIGNMENT), 0, 1)
      + 25 * math.clamp((predictedRange - predictedDistance) / math.max(predictedRange, 1), 0, 1)
    if score < CONFIG.ACTIVATION.DASH_MIN_SCORE then return nil end
    return { reason = reason, partner = partner, score = score, projectedDistance = predictedDistance, estimatedCps = cps, remaining = remaining }
  end
  return model(otherDash, own - other, "dash_incoming") or model(ownDash, other - own, "dash_self")
end
local function evaluate(state, time, fresh, serverTime, snapshot, blocked, autoEnabled)
  if current ~= state or not state.root.Parent then return end
  if not utils.isActive() then
    deactivate(state, "hub_inactive", time); state.stoppedPartner, state.pendingReset = nil, false
    return
  end
  if autoEnabled == nil then autoEnabled = utils.getConfigValue("AutoSpam") == true end
  if state.timeoutBlocked and not state.active then
    local cooldown = cooldownInfo.getDeflectCooldownState()
    if cooldown and cooldown.blocking == false then state.timeoutBlocked, state.timeoutBlockedTarget = false, nil end
  end
  if not autoEnabled then
    if state.active then deactivate(state, "disabled", time) end
    state.timeoutBlocked, state.timeoutBlockedTarget = false, nil; resetExchange(state)
    state.killRadiusInside, state.killRadiusFirstAt, state.killRadiusBall = nil, nil, nil
  end
  snapshot = snapshot or gameInfo.getSnapshotAt(time); observeMotion(state, snapshot, time)
  if snapshot and snapshot.teleported then return end
  if state.teleporting then return end
  if gameInfo.getBallFrozen() == true then
    if state.active then deactivate(state, "ball_frozen", time) end
    resetExchange(state); state.target = nil
    state.killRadiusInside, state.killRadiusFirstAt, state.killRadiusBall = nil, nil, nil; return
  end
  snapshot = snapshot or gameInfo.getSnapshotAt(time); local snapshotFresh = snapshot
    and gameInfo.isSnapshotValid(snapshot)
    and snapshot.targetUncertain ~= true
    and not snapshot.teleported
    and not snapshot.locked
    and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE))
  if snapshotFresh then
    local target = userId(snapshot.targetId)
    if target then
      targetChanged(state, target, time, snapshot, fresh and serverTime or nil)
      if state.active and target == state.partner and not state.departedAt then state.departedAt = time end
    end
  end
  if autoEnabled or state.active or utils.isManualSpamActive() then dashInfo.tick(time, false, state.root.Position, CONFIG.ACTIVATION.DASH_DETECTION_RANGE) end
  if state.active and not blocked and checkDeactivation(state, snapshot, time) then blocked = true end
  sampleOwnDash(state, time)
  if not snapshot or not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return end
  if finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt > CONFIG.SHARED.SNAPSHOT_MAX_AGE then return end
  if fresh then clashStatsModule.observe(state, snapshot, time, true); clashStats = clashStatsModule.get() end
  if not autoEnabled or blocked or state.active or state.stationary then return end
  local prediction = dashPrediction(state, snapshot, time); state.dashPrediction = prediction
  if prediction and activate(state, prediction.reason, prediction.partner, time, serverTime or snapshot.serverTime, snapshot) then return end
  if state.closeTargetAt then
    if time < state.closeTargetAt or time - state.closeTargetAt > CONFIG.ACTIVATION.CLOSE_TARGET_TIMEOUT then state.closeTargetAt, state.closeTargetPartner = nil, nil
    elseif activate(state, "close_target", state.closeTargetPartner, time, serverTime or snapshot.serverTime, snapshot) then return end
  end
  local killReady = snapshotFresh and observeKillRadius(state, snapshot, time)
  if killReady and activate(state, "kill_radius", nil, time, serverTime or snapshot.serverTime, snapshot) then return end
  if not state.active and not blocked and canActivateReturn(state, snapshot, time) then activate(state, "return_target", state.pending.partner, time, serverTime or snapshot.serverTime, snapshot) end
end
local function watchCharacter(state, player, character)
  if state.watchedDeath then forget(state, state.watchedDeath); state.watchedDeath = nil end
  if state.watchedChild then forget(state, state.watchedChild); state.watchedChild = nil end
  state.watchedCharacter = character
  local function watchHumanoid(child)
    if not child:IsA("Humanoid") or state.watchedDeath then return end
    state.watchedDeath = listen(state, child.Died, function()
      if current ~= state or player.Character ~= character then return end
      local id = player.UserId
      if id ~= localPlayer.UserId and id ~= state.partner and not (clashStats and not clashStats.frozen and id == clashStats.partnerId) then return end
      clashStatsModule.freeze(id, state); clashStats = clashStatsModule.get()
      deactivate(state, "player_died", now()); state.pendingReset = true
    end)
  end
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  if humanoid then watchHumanoid(humanoid) end
  if character and character.Parent then state.watchedChild = listen(state, character.ChildAdded, watchHumanoid) end
end
watchOpponent = function(state, id)
  if state.watchedId == id and (not id or state.watchedPlayer) then return end
  if state.watchedAdded then forget(state, state.watchedAdded); state.watchedAdded = nil end
  if state.watchedDeath then forget(state, state.watchedDeath); state.watchedDeath = nil end
  if state.watchedChild then forget(state, state.watchedChild); state.watchedChild = nil end
  state.watchedId, state.watchedPlayer = id, nil
  if not id then return end
  local player = players:GetPlayerByUserId(id)
  if not player then return end
  state.watchedPlayer = player
  state.watchedAdded = listen(state, player.CharacterAdded, function(character)
    if current == state and state.watchedPlayer == player then watchCharacter(state, player, character) end
  end)
  if player.Character then watchCharacter(state, player, player.Character) end
end
local function nearestPlayer(position, limit, excluded)
  local best, bestDistance
  for _, player in ipairs(players:GetPlayers()) do
    if player ~= excluded and playerIsAlive(player.UserId) then
      local value = gameInfo.getPlayerMotion(player.UserId)
      if typeof(value) == "Vector3" then
        local distance = (value - position).Magnitude
        if distance <= limit and (not bestDistance or distance < bestDistance) then best, bestDistance = player, distance end
      end
    end
  end
  return best
end
local function connectHaunter(state)
  local event = gameInfo.getHaunterEvent()
  if event == state.haunterRemote and state.haunterConnection and state.haunterConnection.Connected ~= false then return end
  if state.haunterConnection then forget(state, state.haunterConnection); state.haunterConnection, state.haunterRemote = nil, nil end
  if not event then return end
  state.haunterRemote = event
  state.haunterConnection = listen(state, event.OnClientEvent, function(from, destination)
    if
      current ~= state
      or state.active
      or not state.root.Parent
      or not utils.isActive()
      or utils.getConfigValue("AutoSpam") ~= true
      or not gameInfo.areAbilitiesEnabled()
      or gameInfo.getBallFrozen() == true
      or typeof(from) ~= "CFrame"
      or typeof(destination) ~= "CFrame"
    then
      return
    end
    local time, ownId = now(), localPlayer.UserId; local target = userId(gameInfo.getTargetId())
    local ownWasAtSource = typeof(state.lastRootPosition) == "Vector3"
      and (state.lastRootPosition - from.Position).Magnitude <= CONFIG.ACTIVATION.HAUNTER_MATCH_RADIUS
    if not ownWasAtSource and state.recentRootPosition and time - state.recentRootAt <= 0.75 then
      ownWasAtSource = (state.recentRootPosition - from.Position).Magnitude <= CONFIG.ACTIVATION.HAUNTER_MATCH_RADIUS
    end
    local other = target ~= ownId and target or (state.target ~= ownId and state.target or nil)
    if ownWasAtSource and target == ownId and not other then local player = nearestPlayer(destination.Position, CONFIG.ACTIVATION.HAUNTER_RANGE, localPlayer); other = player and player.UserId end
    if other and ownWasAtSource and (target == ownId or target == other) then
      local position = gameInfo.getPlayerMotion(other)
      if typeof(position) == "Vector3" and playerIsAlive(other) and (position - destination.Position).Magnitude <= CONFIG.ACTIVATION.HAUNTER_RANGE then
        state.haunterPartner, state.haunterUntil = other, time + 0.75; activate(state, "haunter_self", other, time, nil)
        return
      end
    end
    if (destination.Position - state.root.Position).Magnitude > CONFIG.ACTIVATION.HAUNTER_RANGE then return end
    local caster, bestDistance
    for _, player in ipairs(players:GetPlayers()) do
      local position = gameInfo.getPlayerMotion(player.UserId)
      if typeof(position) == "Vector3" and playerIsAlive(player.UserId) then
        local distance = math.min((position - from.Position).Magnitude, (position - destination.Position).Magnitude)
        if distance <= CONFIG.ACTIVATION.HAUNTER_MATCH_RADIUS and (not bestDistance or distance < bestDistance) then caster, bestDistance = player, distance end
      end
    end
    if caster and caster ~= localPlayer then activate(state, "haunter", caster.UserId, time, nil) end
  end)
end
local function detach(reason)
  local state = current
  if state then
    if clashStats and not clashStats.frozen then
      local humanoid = state.character and state.character:FindFirstChildOfClass("Humanoid")
      if humanoid and humanoid.Health <= 0 then clashStatsModule.freeze(localPlayer.UserId, state) else clashStatsModule.finish(reason, now()) end
    end
    deactivate(state, reason, now()); current = nil
    disconnectAll(state)
  end
  generation += 1
end

-- lifecycle
function AutoSpam.setup(deps)
  if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.ClashStats or not deps.Cooldown or not deps.Dash then return false, "dependências ausentes" end
  if current then detach("setup") end
  utils, gameInfo, clashStatsModule, cooldownInfo, dashInfo = deps.Utils, deps.GameInfo, deps.ClashStats, deps.Cooldown, deps.Dash
  players, runService, localPlayer = utils.getPlayers(), utils.getRunService(), utils.getLocalPlayer()
  if not players or not runService or not localPlayer then
    utils, gameInfo, clashStatsModule, players, runService, localPlayer, cooldownInfo = nil, nil, nil, nil, nil, nil, nil; return false, "serviços indisponíveis"
  end
  clashStats = clashStatsModule.get(); return true
end
function AutoSpam.bindCharacter(character)
  detach("rebind"); local root = character and character:FindFirstChild("HumanoidRootPart")
  if not root or not root:IsA("BasePart") then return false, "HumanoidRootPart indisponível" end
  local state = newState(character, root); current = state
  connectHaunter(state)
  listen(state, players.PlayerRemoving, function(player)
    if current ~= state then return end
    if player.UserId == state.partner or player.UserId == state.watchedId then
      if clashStats and not clashStats.frozen then clashStatsModule.finish("oponente saiu", now()) end
      deactivate(state, "opponent_left", now()); state.watchedPlayer = nil
      watchOpponent(state, nil)
    end
  end)
  listen(state, runService.Heartbeat, function()
    if current ~= state then return end
    local time = now()
    if time - state.lastTickAt < CONFIG.SHARED.RUNTIME_TICK_INTERVAL then return end
    state.lastTickAt = time; local autoEnabled = utils.getConfigValue("AutoSpam") == true
    local upDashEnabled = utils.getConfigValue("AutoClashUpDash") == true; local manualEnabled = utils.isManualSpamActive()
    clashStats = clashStatsModule.get()
    if
      (not state.haunterConnection or state.haunterConnection.Connected == false or not state.haunterRemote or not state.haunterRemote.Parent)
      and time >= (state.nextHaunterCheck or 0)
    then
      state.nextHaunterCheck = time + 0.25; connectHaunter(state)
    end
    local context = (autoEnabled or upDashEnabled or manualEnabled or state.active or state.pendingReset or (clashStats and not clashStats.frozen))
      and gameInfo.getClashContext()
    if clashStats and not clashStats.frozen and not state.active and not context and time - clashStats.lastObserved > 1.5 then
      clashStatsModule.finish("clash encerrado", clashStats.lastObserved); clashStats = clashStatsModule.get()
    end
    if
      not autoEnabled
      and not upDashEnabled
      and not manualEnabled
      and not state.active
      and not context
      and (not clashStats or clashStats.frozen)
      and not state.pendingReset
    then
      clashStatsModule.waitForNextClash(); state.lobbyCheckAt, state.lobbySnapshotValid = nil, false
      state.pending, state.departedAt, state.departedServerAt, state.departedTo = nil, nil, nil, nil; return
    end
    watchOpponent(
      state,
      state.active and state.partner or (state.pending and state.pending.partner) or (clashStats and not clashStats.frozen and clashStats.partnerId)
    )
    safeToReset(state, time)
    if state.haunterPartner then
      local target = userId(gameInfo.getTargetId())
      if state.active or time > state.haunterUntil or not autoEnabled or not utils.isActive() then state.haunterPartner, state.haunterUntil = nil, nil
      elseif target == localPlayer.UserId or target == state.haunterPartner then activate(state, "haunter_self", state.haunterPartner, time, nil) end
    end
    local snapshot
    if not state.lobbyCheckAt or time - state.lobbyCheckAt >= 0.25 then
      state.lobbyCheckAt, snapshot = time, gameInfo.getSnapshotAt(time); state.lobbySnapshotValid = gameInfo.isSnapshotValid(snapshot)
    end
    if not state.lobbySnapshotValid then
      state.lobbySince = state.lobbySince or time
      if time - state.lobbySince >= 1 and not state.active then
        state.stoppedPartner, state.pending, state.dashSwitchPartner, state.pendingReset, state.target = nil, nil, nil, false, nil; resetMotion(state)
        resetExchange(state)
      end
    else
      state.lobbySince = nil
    end
    evaluate(state, time, false, nil, snapshot, nil, autoEnabled); AutoSpam.canSendManual()
    if typeof(state.lastRootPosition) == "Vector3" and (state.root.Position - state.lastRootPosition).Magnitude > CONFIG.ACTIVATION.HAUNTER_RANGE then
      state.recentRootPosition, state.recentRootAt = state.lastRootPosition, time
    end
    state.lastRootPosition = state.root.Position
  end)
  listen(state, character.AncestryChanged, function(_, parent)
    if not parent and current == state then detach("character_removed") end
  end)
  return true
end
function AutoSpam.detachCharacter() detach("detach") end
function AutoSpam.teardown()
  detach("teardown"); clashStatsModule = nil
  clashStats = nil; utils, gameInfo, players, runService, localPlayer, clashStatsModule, cooldownInfo, dashInfo = nil, nil, nil, nil, nil, nil, nil, nil
end
function AutoSpam.onBallSync(data)
  local state = current
  if not state or type(data) ~= "table" or (data.Source ~= "packet" and data.Teleported ~= true) then return end
  local time = now(); local sequence = data.Sequence or data.TeleportSequence
  if finite(sequence) and finite(state.sequence) then
    local delta = (sequence - state.sequence) % CONFIG.SHARED.SEQUENCE_MODULUS
    if delta == 0 or delta >= CONFIG.SHARED.SEQUENCE_HALF then return end
  end
  if finite(sequence) then state.sequence = sequence end
  if data.Teleported == true then
    state.teleporting = true; resetMotion(state)
    resetExchange(state); state.deflectCooldownSince = nil
    state.killRadiusInside, state.killRadiusFirstAt, state.killRadiusBall = nil, nil, nil; return
  end
  local autoEnabled = utils.getConfigValue("AutoSpam") == true; local manualEnabled = utils.isManualSpamActive()
  local context = gameInfo.getClashContext()
  if not autoEnabled and not manualEnabled and not state.active and (not clashStats or clashStats.frozen) and not context then
    state.target = userId(data.TargetPlayerID) or userId(gameInfo.getTargetId()) or state.target; resetExchange(state)
    return
  end
  local serverTime = tonumber(data.ServerTime)
  if not finite(serverTime) then serverTime = nil end
  local speed = tonumber(data.Speed); local snapshot = gameInfo.getSnapshotAt(time)
  if snapshot and data.Source == "packet" then
    snapshot = table.clone(snapshot); snapshot.syncAt, snapshot.serverTime, snapshot.syncSequence, snapshot.teleported = time, serverTime, sequence, false
    if data.TargetPlayerID ~= nil then snapshot.targetId = userId(data.TargetPlayerID) or -1 end
    if type(data.Locked) == "boolean" then snapshot.locked = data.Locked end
    if finite(speed) and speed > 0 then snapshot.syncSpeed = speed end
  end
  evaluate(state, time, true, serverTime, snapshot, nil, autoEnabled); AutoSpam.canSendManual()
end

-- public-api
function AutoSpam.isActive() return current ~= nil and current.active end
function AutoSpam.canSendManual()
  local state = current
  if not state or not utils or not utils.isManualSpamActive() then
    if state then state.manual = nil end
    return false
  end
  if not utils.isActive() or not state.root.Parent or not state.character.Parent then return false end
  local time = now(); local snapshot = gameInfo.getSnapshotAt(time)
  if state.teleporting or (snapshot and snapshot.teleported) then
    if state.manual then state.manual.activatedAt, state.manual.deflectCooldownSince = time, nil end
    return false
  end
  local manual = state.manual
  if not manual then manual = { activatedAt = time }; state.manual = manual end
  local target = freshSnapshot(snapshot, time) and userId(snapshot.targetId)
  if target and target ~= localPlayer.UserId then manual.partner = target end
  if not manual.partner then manual.partner = state.partner or state.previousOpponent end
  if not manual.partner then
    local nearest, nearestDistance
    for _, player in ipairs(players:GetPlayers()) do
      local position = player ~= localPlayer and playerIsAlive(player.UserId) and gameInfo.getPlayerMotion(player.UserId)
      if typeof(position) == "Vector3" then
        local distance = (position - state.root.Position).Magnitude
        if not nearestDistance or distance < nearestDistance then nearest, nearestDistance = player.UserId, distance end
      end
    end
    manual.partner = nearest
  end
  manual.root = state.root
  local reason
  if state.stationary then
    reason = "ball_stationary"
  elseif dashEscapeRisk(state, manual, snapshot, time) then
    reason = "dash_escape"
  elseif cooldownExpired(manual, snapshot, time, CONFIG.DEACTIVATION.MANUAL_COOLDOWN_FACTOR) then
    reason = "deflect_cooldown_timeout"
  elseif manual.partner and freshSnapshot(snapshot, time) then
    local opponent, limit = gameInfo.getPlayerMotion(manual.partner), distanceLimit(snapshot, manual.partner)
    if not playerIsAlive(manual.partner) or (typeof(opponent) == "Vector3" and limit and (opponent - state.root.Position).Magnitude > limit) then reason = "opponent_distance" end
  end
  if reason then
    state.manual = nil; utils.setManualSpamActive(false)
    utils.recordTransition("ManualSpam", "active", "inactive", reason); return false
  end
  return true
end
function AutoSpam.canSend()
  if current and current.active and utils then checkDeactivation(current, gameInfo.getSnapshotAt(now()), now()) end
  if current and (current.teleporting or current.stationary) then return false end
  return current ~= nil
    and current.active
    and current.root.Parent ~= nil
    and current.character.Parent ~= nil
    and utils ~= nil
    and utils.isActive()
    and utils.getConfigValue("AutoSpam") == true
end
function AutoSpam.stopSpam()
  if current then deactivate(current, "stop_spam", now()) end
end
function AutoSpam.getDashData()
  local state = current
  local dashing, speed, duration
  if gameInfo then dashing, speed, duration = gameInfo.getLocalDashState() end
  speed, duration = speed or 120, duration or 0.2
  return {
    dashing = dashing == true,
    speed = speed,
    duration = duration,
    idealTravel = speed * duration,
    actualTravel = state and state.dashStart and (state.root.Position - state.dashStart).Magnitude or 0,
    switchPartner = state and state.dashSwitchPartner or nil,
    windowFactor = CONFIG.ACTIVATION.DASH_WINDOW_FACTOR,
  }
end
function AutoSpam.getTargetSwitch()
  local state = current
  return {
    timestampMs = state and (state.lastSwitchAt or 0) * 1000 or 0,
    partnerId = state and state.partner or -1,
    intervalMs = state and (state.intervalMs or 0) or 0,
    resetToken = generation,
  }
end
function AutoSpam.getActivationContext()
  local state = current
  return {
    active = state ~= nil and state.active,
    reason = state and state.reason or "detached",
    partner = state and state.partner or -1,
  }
end
local function clashStatus()
  if not clashStats then return nil end
  local currentCps = clashStats.currentCps
  if currentCps and not clashStats.frozen then
    currentCps = math.min(currentCps, 1 / math.max(clashStats.cycleInterval or 0, clashStats.lastCycleAt and now() - clashStats.lastCycleAt or math.huge))
  end
  local duration = clashStats.duration or (clashStats.startedAt and math.max(0, now() - clashStats.startedAt))
  return {
    partnerId = clashStats.partnerId,
    distance = clashStats.distance,
    cps = clashStats.cps,
    currentCps = currentCps,
    startSample = clashStats.startSample and table.clone(clashStats.startSample) or nil,
    endSample = clashStats.endSample and table.clone(clashStats.endSample) or nil,
    endReason = clashStats.endReason,
    speed = clashStats.speed,
    frozen = clashStats.frozen,
    duration = duration,
    travelTarget = clashStats.travelTarget,
    travelStartedAt = not clashStats.frozen and clashStats.travelStartedAt or nil,
    lastTravelTime = clashStats.lastTravelTime,
    lastTravelTarget = clashStats.lastTravelTarget,
    fatalTravelTime = clashStats.fatalTravelTime,
    penultimateTravelTime = clashStats.penultimateTravelTime,
    penultimateTarget = clashStats.penultimateTarget,
    deceasedId = clashStats.deceasedId,
  }
end
function AutoSpam.getStatus()
  local state = current; local time = utils and now() or 0
  local snapshot = gameInfo and gameInfo.getSnapshotAt(time)
  local distance, closing
  if state and state.root and state.root.Parent and snapshot and typeof(snapshot.position) == "Vector3" then
    local delta = state.root.Position - snapshot.position; distance = delta.Magnitude
    if distance > 0 and typeof(snapshot.velocity) == "Vector3" then closing = snapshot.velocity:Dot(delta) / distance end
  end
  return {
    schema = utils and utils.apiVersion() or 1,
    phase = state and (state.active and "active" or "idle") or "detached",
    active = state ~= nil and state.active,
    lastGate = state and state.reason or "detached",
    dashPrediction = state and state.dashPrediction or nil,
    dashEscape = state and state.dashEscape or nil,
    lastActivationReason = lastActivationReason,
    lastActivationAt = lastActivationAt,
    lastStopReason = lastStopReason,
    lastStopAt = lastStopAt,
    targetId = snapshot and snapshot.targetId or -1,
    targetUncertain = snapshot and snapshot.targetUncertain == true or false,
    ballDistance = distance,
    closingSpeed = closing,
    snapshotAge = snapshot and finite(snapshot.syncAt) and snapshot.syncAt > 0 and math.max(0, time - snapshot.syncAt) or nil,
    clashPartnerId = state and state.partner or -1,
    clashStats = clashStatus(),
  }
end

-- contract
AutoSpam.__contract = {
  requires = {
    Utils = "utils",
    GameInfo = "gameinfo",
    ClashStats = "clashstats",
    Cooldown = "cooldown",
    Dash = "dash",
  },
  requiresMethods = {
    Utils = {
      "now",
      "getLocalPlayer",
      "getPlayers",
      "getWorkspace",
      "getRunService",
      "isActive",
      "getConfigValue",
      "isManualSpamActive",
      "setAutoSpamActive",
      "setManualSpamActive",
      "trackCharacter",
      "untrackCharacter",
      "recordTransition",
      "apiVersion",
    },
    GameInfo = {
      "areAbilitiesEnabled",
      "getSnapshotAt",
      "isSnapshotValid",
      "getPlayerMotion",
      "getHaunterEvent",
      "getDeflectGeometry",
      "getDefensePhysics",
      "getDeflectRangeParameters",
      "isPlayerDashing",
      "getLocalDashState",
      "getPlayerDeflectRange",
      "getPlayerRawRadius",
      "getBallFrozen",
      "getAveragePing",
      "getTargetId",
      "getBallSpeedLimits",
      "getClashContext",
      "getGameContext",
      "getDeflectWindow",
    },
    Cooldown = { "getDeflectCooldownState" },
    Dash = { "tick", "getEstimate" },
    ClashStats = { "begin", "finish", "observe", "freeze", "get", "waitForNextClash" },
  },
  provides = {
    "setup",
    "bindCharacter",
    "detachCharacter",
    "teardown",
    "onBallSync",
    "isActive",
    "canSend",
    "canSendManual",
    "getActivationContext",
    "getStatus",
    "getTargetSwitch",
    "getDashData",
    "stopSpam",
  },
  onBallSync = true,
  bindCharacter = true,
}

return AutoSpam
