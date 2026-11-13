-- [[ auto spam ]]

-- module
local AutoSpam = {}
local utils, gameInfo, clashStatsModule, danger, players, runService, localPlayer
local current, generation = nil, 0
local clashStats
local lastActivationReason, lastActivationAt, lastStopReason, lastStopAt

-- configuration
local CONFIG = {
  ACTIVATION = {
    RETURN = 0.30,
    OWN_BALL_CLOSE_RADIUS = 6,
    INSTANT_TARGET_SWITCH_RADIUS = 10,
    OWN_BALL_CANDIDATE_MAX_AGE = 0.8,
    OWN_BALL_OPPONENT_RADIUS = 16,
    EXCHANGE_MAX_INTERVAL = 2,
    EXCHANGE_READY_TIME = 0.5,
    REACTIVATION_COOLDOWN = 0.04,
    RADIUS_FACTOR = 1,
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
    STATIONARY_TIMEOUT = 0.1,
    DEFLECT_COOLDOWN_TIMEOUT_BASE = 0.15,
    DEFLECT_COOLDOWN_TIMEOUT_MAX_SPEED = 0.10,
    CLOSE_OPPONENT_PROTECTION_RADIUS = 10,
    SYNC_PROTECTION_RADIUS = 16,
    CLOSE_OPPONENT_MEMORY_SECONDS = 0.1,
    STATIONARY_POSITION_EPSILON = 0.01,
  },
  SHARED = {
    MIN_RETURN = 1 / 25,
    SNAPSHOT_MAX_AGE = 0.5,
    SEQUENCE_MODULUS = 65536,
    SEQUENCE_HALF = 32768,
  },
}

local PROTECTED_REASONS = {
  frozen = CONFIG.DEACTIVATION.CLOSE_OPPONENT_PROTECTION_RADIUS,
  opponent_distance = CONFIG.DEACTIVATION.CLOSE_OPPONENT_PROTECTION_RADIUS,
  exchange_unconfirmed = CONFIG.DEACTIVATION.CLOSE_OPPONENT_PROTECTION_RADIUS,
  danger_defended = CONFIG.DEACTIVATION.CLOSE_OPPONENT_PROTECTION_RADIUS,
}

-- helpers
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function userId(value)
  if type(value) == "string" then value = tonumber(value) end
  return finite(value) and value > 0 and value % 1 == 0 and value or nil
end
local function now() return utils.now() end
local function elapsed(localStart, serverStart, time, serverTime)
  if finite(serverStart) and finite(serverTime) then return serverTime >= serverStart and serverTime - serverStart or nil end
  return finite(localStart) and time >= localStart and time - localStart or nil
end
local function snapshotSpeed(snapshot)
  if not snapshot then return nil end
  local speed = tonumber(snapshot.syncSpeed); return finite(speed) and speed > 0 and speed or snapshot.speed
end
local function cooldownTimeout(snapshot, state, time)
  local fresh = snapshot and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE))
  local speed = fresh and snapshotSpeed(snapshot) or nil
  if finite(speed) and speed > 0 then state.cooldownSpeed = speed else speed = state.cooldownSpeed end
  local slow, fast = CONFIG.DEACTIVATION.DEFLECT_COOLDOWN_TIMEOUT_BASE, CONFIG.DEACTIVATION.DEFLECT_COOLDOWN_TIMEOUT_MAX_SPEED
  if not finite(speed) or speed <= 0 then return slow end
  local minimum, maximum = gameInfo.getBallSpeedLimits()
  if not finite(minimum) or not finite(maximum) or maximum <= minimum then return slow end
  local progress = math.clamp((speed - minimum) / (maximum - minimum), 0, 1)
  return slow + (fast - slow) * progress
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
  state.proximityPartner, state.proximityAt, state.proximityLastDistance, state.proximitySequence = nil, nil, nil, nil; state.exchangeFrom, state.exchangeTo, state.exchangeAt = nil, nil, nil
  state.exchangePartner, state.exchangeReadyAt = nil, nil; state.pending, state.departedAt, state.departedServerAt, state.departedTo = nil, nil, nil, nil
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
  }
end
local function distanceLimit(snapshot, partner)
  local speed = snapshotSpeed(snapshot)
  if not finite(speed) or speed <= 0 then return nil end
  local minimum, maximum = gameInfo.getBallSpeedLimits(); local baseRange, resilienceMax = gameInfo.getDeflectRangeParameters()
  local ownRange, otherRange = gameInfo.getPlayerDeflectRange(localPlayer.UserId), gameInfo.getPlayerDeflectRange(partner)
  local ownRaw, otherRaw = gameInfo.getPlayerRawRadius(localPlayer.UserId, speed, true), gameInfo.getPlayerRawRadius(partner, speed, false)
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
  local factor = math.clamp((speed - minimum) / (maximum - minimum), 0, 1)
  local base = CONFIG.DEACTIVATION.MIN_DISTANCE + (CONFIG.DEACTIVATION.MAX_DISTANCE_REFERENCE - resilienceMax * 2 - CONFIG.DEACTIVATION.MIN_DISTANCE) * factor
  local resilience = math.clamp(ownRange - baseRange, 0, resilienceMax) + math.clamp(otherRange - baseRange, 0, resilienceMax)
  return base + resilience * factor + math.max(0, ownRaw - ownRange) + math.max(0, otherRaw - otherRange)
end
local function geometry(snapshot, factor)
  local speed = snapshotSpeed(snapshot)
  if not finite(speed) or speed <= 0 then return nil end
  local value = gameInfo.getDeflectGeometry(speed, "game", factor, false); return value, speed, value and value.deflectWindow
end
local function distanceGate(state, snapshot, partner)
  if not state.root.Parent or not snapshot or typeof(snapshot.position) ~= "Vector3" then return "distance_unavailable" end
  local speed = snapshotSpeed(snapshot); local value = finite(speed) and speed > 0 and gameInfo.getDeflectGeometry(speed, "game", CONFIG.ACTIVATION.RADIUS_FACTOR, false)
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
local function dashAssistPartner(state, snapshot, time)
  if
    not state.dashStart
    or not state.dashAt
    or not state.dashSwitchPartner
    or not state.dashSwitchAt
    or time - state.dashAt > 0.85
    or time - state.dashSwitchAt > CONFIG.ACTIVATION.DASH_MAX_AGE
    or not snapshot
  then
    return nil
  end
  local partner = state.dashSwitchPartner; local opponent = gameInfo.getPlayerMotion(partner)
  if not playerIsAlive(partner) or typeof(opponent) ~= "Vector3" then return nil end
  local own = state.root.Position; local movement = own - state.dashStart
  local toward, startDistance = opponent - state.dashStart, (opponent - state.dashStart).Magnitude; local dashTime = time - state.dashAt
  if startDistance < 0.1 or dashTime <= 0 then return nil end
  local measuredSpeed = movement.Magnitude / dashTime
  if not finite(measuredSpeed) or measuredSpeed > CONFIG.ACTIVATION.DASH_MAX_SPEED then return nil end
  local approach = measuredSpeed >= CONFIG.ACTIVATION.DASH_FAST_SPEED and CONFIG.ACTIVATION.DASH_FAST_APPROACH or CONFIG.ACTIVATION.DASH_MIN_APPROACH
  if
    movement.Magnitude < approach
    or startDistance - (opponent - own).Magnitude < approach
    or movement:Dot(toward) / (movement.Magnitude * startDistance) < CONFIG.ACTIVATION.DASH_ALIGNMENT
  then
    return nil
  end
  if snapshot.targetId == localPlayer.UserId and typeof(snapshot.position) == "Vector3" and typeof(snapshot.velocity) == "Vector3" then
    local direction = own - snapshot.position; local velocity = snapshot.velocity
    if direction.Magnitude > 1 and velocity.Magnitude > 8 and velocity:Dot(direction) / (velocity.Magnitude * direction.Magnitude) < -0.35 then return nil end
  end
  local raw = gameInfo.getPlayerRawRadius(localPlayer.UserId, snapshotSpeed(snapshot), true); return finite(raw) and (opponent - own).Magnitude <= raw and partner or nil
end
local function activationGeometry(state, snapshot, partner, time)
  local factor = CONFIG.ACTIVATION.RADIUS_FACTOR
  if dashAssistPartner(state, snapshot, time) == partner then factor = math.min(1, factor * CONFIG.ACTIVATION.DASH_RADIUS_MULTIPLIER) end
  return geometry(snapshot, factor)
end

-- protection
local ownBallClose, watchOpponent
local function closeClashProtected(state, time, radius)
  if not state.partner or not state.root.Parent then return false end
  local opponent = gameInfo.getPlayerMotion(state.partner)
  if typeof(opponent) ~= "Vector3" then
    local player = players:GetPlayerByUserId(state.partner); local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") and root.Parent then opponent = root.Position end
  end
  if typeof(opponent) == "Vector3" then
    local distance = (opponent - state.root.Position).Magnitude
    if distance <= radius then state.lastClosePartner, state.lastCloseAt, state.lastCloseDistance = state.partner, time, distance; return true end
    if state.lastClosePartner == state.partner then state.lastCloseAt = nil end
    return false
  end
  return state.lastClosePartner == state.partner
    and finite(state.lastCloseAt)
    and time - state.lastCloseAt <= CONFIG.DEACTIVATION.CLOSE_OPPONENT_MEMORY_SECONDS
    and finite(state.lastCloseDistance)
    and state.lastCloseDistance <= radius
end
local function cooldownOpponentOutside(state)
  if not state.partner or not state.root or not state.root.Parent then return false end
  local position = gameInfo.getPlayerMotion(state.partner)
  if typeof(position) ~= "Vector3" then
    local player = players:GetPlayerByUserId(state.partner)
    local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") and root.Parent then position = root.Position end
  end
  if typeof(position) ~= "Vector3" then return false end
  return (position - state.root.Position).Magnitude > CONFIG.DEACTIVATION.SYNC_PROTECTION_RADIUS
end
local function stationaryTooLong(state, time, ball, snapshot)
  if not state.active then state.stationaryBall, state.stationaryPosition, state.stationarySince = nil, nil, nil; return false end
  local position = ball.Position
  local speed = snapshotSpeed(snapshot)
  if not finite(speed) or speed > 1 or not finite(snapshot.syncSequence) then state.stationarySince, state.stationarySequence = nil, nil; return false end
  if state.stationaryBall ~= ball or typeof(state.stationaryPosition) ~= "Vector3" or not state.stationarySince
    or (position - state.stationaryPosition).Magnitude > CONFIG.DEACTIVATION.STATIONARY_POSITION_EPSILON then
    state.stationaryBall, state.stationaryPosition, state.stationarySince, state.stationarySequence, state.stationarySampleAt = ball, position, time, snapshot.syncSequence, time; return false
  end
  if snapshot.syncSequence == state.stationarySequence then return false end
  if time < state.stationarySampleAt or time - state.stationarySampleAt > CONFIG.DEACTIVATION.STATIONARY_TIMEOUT then
    state.stationarySince = time
  end
  state.stationarySequence, state.stationarySampleAt = snapshot.syncSequence, time
  return time - state.stationarySince >= CONFIG.DEACTIVATION.STATIONARY_TIMEOUT
end
local function activate(state, reason, partner, time, serverTime, snapshot)
  if
    current ~= state
    or state.active
    or not utils.isActive()
    or utils.getConfigValue("AutoSpam") ~= true
    or not partner
    or partner == localPlayer.UserId
    or not playerIsAlive(partner)
    or state.timeoutBlocked == true
    or (reason ~= "danger_deadline" and state.lastDeactivatedAt and time - state.lastDeactivatedAt < CONFIG.ACTIVATION.REACTIVATION_COOLDOWN)
  then
    return false
  end
  local bypassExchange = reason == "danger_deadline" or reason == "own_ball_proximity" or reason == "close_target_switch" or reason == "clash_intercept" or reason == "haunter" or reason == "haunter_self"
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
  if not gameInfo.isSnapshotValid(snapshot) or snapshot.targetUncertain == true or snapshot.targetId ~= localPlayer.UserId
    or snapshot.teleported == true or snapshot.locked == true or not state.root or not state.root.Parent
    or typeof(snapshot.position) ~= "Vector3" or typeof(snapshot.velocity) ~= "Vector3" then return false end
  if finite(snapshot.syncAt) and snapshot.syncAt > 0 and (time < snapshot.syncAt or time - snapshot.syncAt > CONFIG.SHARED.SNAPSHOT_MAX_AGE) then return false end
  local toward = state.root.Position - snapshot.position
  if toward.Magnitude <= 0.05 or snapshot.velocity:Dot(toward) <= 0 then return false end
  local risk = danger.sample(state, snapshot, time, localPlayer.UserId)
  if risk.pending then return false end
  local proximity = reason == "own_ball_proximity" or reason == "close_target_switch" or reason == "clash_intercept"
  if proximity and risk.protect and not risk.urgent then return false end
  if not bypassExchange and distanceGate(state, snapshot, partner) ~= nil then return false end
  if clashStats and clashStats.frozen then clashStatsModule.begin(partner, time); clashStats = clashStatsModule.get() end
  state.active, state.partner, state.pending = true, partner, nil; state.stoppedPartner, state.stoppedAt = nil, nil
  state.dashSwitchPartner, state.dashSwitchAt = nil, nil; state.deflectCooldownSince, state.cooldownSpeed = nil, snapshotSpeed(snapshot)
  state.activatedAt = time; state.lastClosePartner, state.lastCloseAt, state.lastCloseDistance = nil, nil, nil
  state.dangerActivation = reason == "danger_deadline"
  state.confirmTarget, state.confirmSwitches, state.confirmSince, state.confirmPacketAt = localPlayer.UserId, 0, nil, nil
  state.stationaryBall, state.stationaryPosition, state.stationarySince = nil, nil, nil; state.lastSwitchAt, state.lastSwitchServerAt = time, serverTime
  state.reason = reason
  lastActivationReason, lastActivationAt = reason, time
  if watchOpponent then watchOpponent(state, partner) end
  utils.setAutoSpamActive(true); utils.recordTransition("AutoSpam", "idle", "active", reason)
  return true
end
local function deactivate(state, reason, time)
  if current ~= state then return false end
  time = time or now()
  if state.active then
    local radius = PROTECTED_REASONS[reason]
    if radius and closeClashProtected(state, time, radius) then return false end
    state.stoppedPartner, state.stoppedAt = state.partner, time; state.active, state.lastDeactivatedAt = false, time
    if reason == "deflect_cooldown_timeout" or reason == "exchange_unconfirmed" then
      state.timeoutBlocked, state.timeoutBlockedTarget = true, state.target
    end
    lastStopReason, lastStopAt = reason, time; utils.setAutoSpamActive(false)
    utils.recordTransition("AutoSpam", "active", "idle", reason)
  end
  state.reason, state.pending, state.partner = reason, nil, nil; state.haunterPartner, state.haunterUntil = nil, nil
  if watchOpponent then watchOpponent(state, nil) end
  state.activatedAt, state.deflectCooldownSince = nil, nil
  state.stationaryBall, state.stationaryPosition, state.stationarySince = nil, nil, nil; resetExchange(state)
  return true
end
local function deactivationReason(state, snapshot, time)
  if not utils.isActive() then return "hub_inactive" end
  if utils.getConfigValue("AutoSpam") ~= true then return "disabled" end
  -- The cooldown gate scales with speed and requires the opponent to be
  -- outside the fixed 16-stud radius.
  local cooldown = gameInfo.getDeflectCooldownState()
  if cooldown and cooldown.blocking == true then
    state.deflectCooldownSince = state.deflectCooldownSince or time
  else
    state.deflectCooldownSince = nil
  end
  local cooldownLimit = state.deflectCooldownSince and cooldownTimeout(snapshot, state, time) or nil
  if state.activatedAt and state.deflectCooldownSince
    and time - state.activatedAt >= cooldownLimit
    and time - state.deflectCooldownSince >= cooldownLimit
    and cooldownOpponentOutside(state) then return "deflect_cooldown_timeout" end
  if gameInfo.getBallFrozen() == true then return "ball_frozen" end
  local ball = gameInfo.getBall()
  if not ball or not ball:IsA("BasePart") or not ball.Parent then return nil end
  if snapshot and (snapshot.teleported or snapshot.locked or snapshot.targetUncertain) then return nil end
  local age = snapshot and finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt
  -- A missing or delayed packet is not evidence that the exchange ended.
  if not snapshot or not gameInfo.isSnapshotValid(snapshot) or not age or age < 0 or age > CONFIG.SHARED.SNAPSHOT_MAX_AGE then return nil end
  local target = userId(snapshot.targetId)
  if not target then return nil end
  if target ~= localPlayer.UserId and target ~= state.partner then
    return "target_changed"
  end
  -- A ball travelling to the partner can legitimately be far from us.
  local opponent = state.partner and gameInfo.getPlayerMotion(state.partner)
  local limit = state.partner and distanceLimit(snapshot, state.partner)
  if limit and typeof(opponent) == "Vector3" and (opponent - state.root.Position).Magnitude > limit then return "opponent_distance" end
end
local function checkExchangeConfirmation(state, snapshot, time)
  if not state.active or state.confirmSwitches == nil or state.confirmSwitches >= 2 then return false end
  if not snapshot or not gameInfo.isSnapshotValid(snapshot) or snapshot.targetUncertain or snapshot.locked or snapshot.teleported then return false end
  local target = userId(snapshot.targetId)
  if not target then return false end
  if target ~= localPlayer.UserId and target ~= state.partner then return deactivate(state, "target_changed", time) end
  if not state.confirmPacketAt or time < state.confirmPacketAt or time - state.confirmPacketAt > 0.4 then state.confirmSince = time end
  state.confirmPacketAt = time
  if target ~= state.confirmTarget then
    state.confirmTarget = target; state.confirmSwitches += 1
    if state.confirmSwitches >= 2 then return false end
  end
  local ping = gameInfo.getAveragePing()
  if not finite(ping) or ping < 0 then ping = 0 end
  if closeClashProtected(state, time, CONFIG.DEACTIVATION.CLOSE_OPPONENT_PROTECTION_RADIUS) then
    state.confirmSince = time; return false
  end
  local speed = snapshotSpeed(snapshot)
  local geometry = finite(speed) and speed > 0 and gameInfo.getDeflectGeometry(speed, "game", 1, false)
  local physics = gameInfo.getDefensePhysics()
  local window = geometry and geometry.deflectWindow or 0
  local grace = physics and physics.grace or 0
  local budget = math.max(0.3, window + grace) + ping
  if state.confirmSince and time - state.confirmSince >= budget then
    return deactivate(state, "exchange_unconfirmed", time)
  end
  return false
end
local function checkDeactivation(state, snapshot, time)
  if not state.active then return false end
  local reason = deactivationReason(state, snapshot, time)
  return reason ~= nil and deactivate(state, reason, time)
end

-- target-tracking
ownBallClose = function(state, snapshot, time)
  if
    not state.root.Parent
    or not snapshot
    or snapshot.targetUncertain
    or snapshot.targetId ~= localPlayer.UserId
    or snapshot.locked
    or snapshot.teleported
    or not gameInfo.isSnapshotValid(snapshot)
    or gameInfo.getBallFrozen() == true
    or typeof(snapshot.position) ~= "Vector3"
    or typeof(snapshot.velocity) ~= "Vector3"
  then
    return false
  end
  local candidate = state.proximityPartner
    and finite(state.proximityAt)
    and time >= state.proximityAt
    and time - state.proximityAt <= CONFIG.ACTIVATION.OWN_BALL_CANDIDATE_MAX_AGE
    and state.target == localPlayer.UserId
  local toward, distance = state.root.Position - snapshot.position, (state.root.Position - snapshot.position).Magnitude
  if state.proximityPartner and not state.active then
    local movingAway = state.proximityLastDistance and distance > state.proximityLastDistance + 0.25
    if not candidate or distance > CONFIG.ACTIVATION.OWN_BALL_OPPONENT_RADIUS or movingAway then
      state.proximityPartner, state.proximityAt, state.proximityLastDistance, state.proximitySequence = nil, nil, nil, nil; candidate = false
    else
      state.proximityLastDistance = distance
    end
  end
  local partner = state.active and state.partner or (state.pending and state.pending.partner or (candidate and state.proximityPartner)); local opponent = partner and gameInfo.getPlayerMotion(partner)
  if
    not partner
    or partner == localPlayer.UserId
    or typeof(opponent) ~= "Vector3"
    or (opponent - state.root.Position).Magnitude > CONFIG.ACTIVATION.OWN_BALL_OPPONENT_RADIUS
  then
    return false
  end
  local speed = snapshot.velocity.Magnitude; return distance <= CONFIG.ACTIVATION.OWN_BALL_CLOSE_RADIUS and distance >= 0.05 and speed >= 8 and snapshot.velocity:Dot(toward) / distance > 2
end
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
  local toward, distance = state.root.Position - snapshot.position, (state.root.Position - snapshot.position).Magnitude; local value = activationGeometry(state, snapshot, state.pending.partner, time)
  if not value or distance > value.fullRadius then return false end
  if distance <= 0 or typeof(snapshot.velocity) ~= "Vector3" then return false end
  local closingSpeed = snapshot.velocity:Dot(toward) / distance; return finite(closingSpeed)
    and closingSpeed > 0
    and math.max(0, distance - value.noWindowParryRadius) / closingSpeed <= value.effectiveWindow
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
  local uncertainty = finite(state.departedServerAt) and finite(serverTime) and 0 or gameInfo.getAveragePing()
  local startedNear = (snapshot.position - state.root.Position).Magnitude <= value.fullRadius; local fastReturn = duration <= returnWindow(window, speed, CONFIG.ACTIVATION.RETURN, uncertainty)
  if startedNear and not fastReturn then return end
  state.pending = { partner = previous, startedNear = startedNear, fastReturn = fastReturn }
end
local function targetChanged(state, target, time, snapshot, serverTime)
  if not target or target == state.target then return end
  if state.timeoutBlocked and target ~= state.timeoutBlockedTarget then state.timeoutBlocked, state.timeoutBlockedTarget = false, nil end
  local previous, ownId = state.target, localPlayer.UserId; local switchedToMe = target == ownId and previous and previous ~= ownId
  local exchangeReady
  if
    previous
    and state.exchangeFrom == target
    and state.exchangeTo == previous
    and (target == ownId or previous == ownId)
    and state.exchangeAt
    and time >= state.exchangeAt
    and time - state.exchangeAt <= CONFIG.ACTIVATION.EXCHANGE_MAX_INTERVAL
  then
    exchangeReady = target == ownId and previous or target
  end
  state.exchangePartner, state.exchangeReadyAt = exchangeReady, exchangeReady and time or nil
  if previous and (previous == ownId or target == ownId) then state.exchangeFrom, state.exchangeTo, state.exchangeAt = previous, target, time
  else state.exchangeFrom, state.exchangeTo, state.exchangeAt = nil, nil, nil end
  state.proximityPartner, state.proximityAt, state.proximityLastDistance, state.proximitySequence = nil, nil, nil, nil
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
  if switchedToMe then
    watchOpponent(state, previous); local opponent = previous and gameInfo.getPlayerMotion(previous)
    if
      utils.getConfigValue("AutoSpam") == true
      and not state.active
      and snapshot
      and gameInfo.isSnapshotValid(snapshot)
      and not snapshot.targetUncertain
      and not snapshot.locked
      and not snapshot.teleported
      and gameInfo.getBallFrozen() ~= true
      and typeof(snapshot.position) == "Vector3"
      and (snapshot.position - state.root.Position).Magnitude <= CONFIG.ACTIVATION.INSTANT_TARGET_SWITCH_RADIUS
      and playerIsAlive(previous)
      and typeof(opponent) == "Vector3"
      and (opponent - state.root.Position).Magnitude <= CONFIG.ACTIVATION.OWN_BALL_OPPONENT_RADIUS
    then
      activate(state, "close_target_switch", previous, time, serverTime, snapshot)
    end
    if snapshot and typeof(snapshot.position) == "Vector3" and playerIsAlive(previous) then
      state.proximityPartner, state.proximityAt, state.proximitySequence = previous, time, state.sequence; state.proximityLastDistance = (snapshot.position - state.root.Position).Magnitude
    end
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
  local speed = snapshot and (snapshot.syncSpeed or snapshot.speed) or 16
  local radius = gameInfo.getPlayerRawRadius(localPlayer.UserId, speed, true) or select(1, gameInfo.getDeflectRangeParameters()) or 16
  for _, player in ipairs(players:GetPlayers()) do
    if player ~= localPlayer and playerIsAlive(player.UserId) then
      local position = gameInfo.getPlayerMotion(player.UserId)
      if typeof(position) ~= "Vector3" or (position - state.root.Position).Magnitude <= radius then return end
    end
  end
  if snapshot and gameInfo.isSnapshotValid(snapshot) and snapshot.targetId == localPlayer.UserId then return end
  state.pendingReset, state.stoppedPartner, state.pending, state.dashSwitchPartner = false, nil, nil, nil
end
local function evaluate(state, time, fresh, serverTime, snapshot, blocked, autoEnabled)
  if current ~= state or not state.root.Parent then return end
  if not utils.isActive() then
    deactivate(state, "hub_inactive", time); state.stoppedPartner, state.pendingReset = nil, false
    return
  end
  if autoEnabled == nil then autoEnabled = utils.getConfigValue("AutoSpam") == true end
  if not autoEnabled then
    if state.active then deactivate(state, "disabled", time) end
    state.timeoutBlocked, state.timeoutBlockedTarget = false, nil
    resetExchange(state)
  end
  if gameInfo.getBallFrozen() == true then
    if state.active then deactivate(state, "ball_frozen", time) end
    resetExchange(state); state.target = nil
    return
  end
  snapshot = snapshot or gameInfo.getSnapshotAt(time)
  if state.active and not blocked and checkDeactivation(state, snapshot, time) then blocked = true end
  if snapshot and gameInfo.isSnapshotValid(snapshot) and snapshot.targetUncertain ~= true and not snapshot.teleported and not snapshot.locked
    and (not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or (time >= snapshot.syncAt and time - snapshot.syncAt <= CONFIG.SHARED.SNAPSHOT_MAX_AGE)) then
    local confirmedTarget = userId(snapshot.targetId)
    if confirmedTarget then targetChanged(state, confirmedTarget, time, snapshot, fresh and serverTime or nil) end
  end
  sampleOwnDash(state, time)
  if not snapshot or not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return end
  if finite(snapshot.syncAt) and snapshot.syncAt > 0 and time - snapshot.syncAt > CONFIG.SHARED.SNAPSHOT_MAX_AGE then return end
  if fresh then clashStatsModule.observe(state, snapshot, time, true); clashStats = clashStatsModule.get() end
  local risk = danger.sample(state, snapshot, time, localPlayer.UserId)
  if state.active and state.dangerActivation and (state.confirmSwitches and state.confirmSwitches >= 2
    or closeClashProtected(state, time, CONFIG.DEACTIVATION.CLOSE_OPPONENT_PROTECTION_RADIUS)) then state.dangerActivation = false end
  if state.active and state.dangerActivation and risk.phase == "resolved" then deactivate(state, "danger_defended", time); return end
  if not autoEnabled or blocked or state.active then return end
  if risk.urgent then
    local partner = state.pending and state.pending.partner or state.proximityPartner
    if not partner then local context = gameInfo.getClashContext(); partner = context and context.partnerId end
    if partner and activate(state, "danger_deadline", partner, time, serverTime, snapshot) then return end
  end
  -- Keep the intercept within the same fixed proximity bounds as the close
  -- target-switch gate; speed must not expand these activation distances.
  local context = gameInfo.getClashContext()
  if context and context.partnerId and snapshot.targetId == localPlayer.UserId and snapshot.targetUncertain ~= true
    and typeof(snapshot.position) == "Vector3" and typeof(snapshot.velocity) == "Vector3" then
    local delta = state.root.Position - snapshot.position; local distance = delta.Magnitude
    local closing = distance > 0 and snapshot.velocity:Dot(delta) / distance or 0
    local opponent = gameInfo.getPlayerMotion(context.partnerId)
    if finite(closing) and closing > 0 and distance <= CONFIG.ACTIVATION.INSTANT_TARGET_SWITCH_RADIUS
      and typeof(opponent) == "Vector3" and (opponent - state.root.Position).Magnitude <= CONFIG.ACTIVATION.OWN_BALL_OPPONENT_RADIUS then
      activate(state, "clash_intercept", context.partnerId, time, serverTime or snapshot.serverTime, snapshot)
    end
  end
  -- Retry a close confirmed switch after the reactivation cooldown instead
  -- of losing the one packet on which the switch was first observed.
  if not state.active and state.proximityPartner and state.target == localPlayer.UserId and finite(state.proximityAt)
    and time >= state.proximityAt and time - state.proximityAt <= CONFIG.ACTIVATION.OWN_BALL_CANDIDATE_MAX_AGE
    and snapshot.targetId == localPlayer.UserId and snapshot.targetUncertain ~= true and typeof(snapshot.position) == "Vector3"
    and (snapshot.position - state.root.Position).Magnitude <= CONFIG.ACTIVATION.INSTANT_TARGET_SWITCH_RADIUS then
    local opponent = gameInfo.getPlayerMotion(state.proximityPartner)
    if typeof(opponent) == "Vector3" and (opponent - state.root.Position).Magnitude <= CONFIG.ACTIVATION.OWN_BALL_OPPONENT_RADIUS then
      activate(state, "close_target_switch", state.proximityPartner, time, serverTime or snapshot.serverTime, snapshot)
    end
  end
  if ownBallClose(state, snapshot, time) then
    activate(state, "own_ball_proximity", state.pending and state.pending.partner or state.proximityPartner, time, serverTime or snapshot.serverTime, snapshot)
  end
  if not state.active and not blocked and canActivateReturn(state, snapshot, time) then activate(state, "return_target", state.pending.partner, time, serverTime or snapshot.serverTime, snapshot) end
end
local function watchCharacter(state, player, character)
  if state.watchedDeath then forget(state, state.watchedDeath) end
  if state.watchedChild then forget(state, state.watchedChild) end
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
  if type(deps) ~= "table" or not deps.Utils or not deps.GameInfo or not deps.ClashStats or not deps.Danger then return false, "dependências ausentes" end
  if current then detach("setup") end
  utils, gameInfo, clashStatsModule, danger = deps.Utils, deps.GameInfo, deps.ClashStats, deps.Danger; players, runService, localPlayer = utils.getPlayers(), utils.getRunService(), utils.getLocalPlayer()
  if not players or not runService or not localPlayer then
    utils, gameInfo, clashStatsModule, players, runService, localPlayer = nil, nil, nil, nil, nil, nil; return false, "serviços indisponíveis"
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
    if player.UserId == state.partner then deactivate(state, "opponent_left", now()) end
    if player.UserId == state.watchedId then state.watchedPlayer = nil; watchOpponent(state, nil) end
  end)
  listen(state, runService.Heartbeat, function()
    if current ~= state then return end
    local time = now(); local autoEnabled = utils.getConfigValue("AutoSpam") == true
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
      if time - state.lobbySince >= 1 and not state.active then state.stoppedPartner, state.pending, state.dashSwitchPartner, state.pendingReset = nil, nil, nil, false end
    else
      state.lobbySince = nil
    end
    evaluate(state, time, false, nil, snapshot, nil, autoEnabled)
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
  clashStats = nil; utils, gameInfo, danger, players, runService, localPlayer = nil, nil, nil, nil, nil, nil
end
function AutoSpam.onBallSync(data)
  local state = current
  if not state or type(data) ~= "table" or (data.Source ~= "packet" and data.Teleported ~= true) then return end
  local time = now()
  if gameInfo.getBallFrozen() == true then
    if state.active then deactivate(state, "ball_frozen", time) end
    resetExchange(state); state.target = nil
    return
  end
  local sequence = data.Sequence or data.TeleportSequence
  if finite(sequence) and finite(state.sequence) then
    local delta = (sequence - state.sequence) % CONFIG.SHARED.SEQUENCE_MODULUS
    if delta == 0 or delta >= CONFIG.SHARED.SEQUENCE_HALF then return end
  end
  if finite(sequence) then state.sequence = sequence end
  if data.Teleported == true then
    state.timeoutBlocked, state.timeoutBlockedTarget = false, nil
    state.target, state.stoppedPartner = nil, nil; resetExchange(state)
    state.haunterPartner, state.haunterUntil = nil, nil; return
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
    snapshot = table.clone(snapshot)
    snapshot.syncAt, snapshot.serverTime, snapshot.syncSequence, snapshot.teleported = time, serverTime, sequence, false
    if type(data.Locked) == "boolean" then snapshot.locked = data.Locked end
    if finite(speed) and speed > 0 then snapshot.syncSpeed = speed end
  end
  local target = snapshot and snapshot.targetUncertain ~= true and userId(snapshot.targetId) or nil; local blocked = state.active and checkDeactivation(state, snapshot, time) or false
  if not blocked and state.active and data.Source == "packet" then blocked = checkExchangeConfirmation(state, snapshot, time) end
  if target and snapshot and gameInfo.isSnapshotValid(snapshot) and not snapshot.teleported then targetChanged(state, target, time, snapshot, serverTime) end
  evaluate(state, time, true, serverTime, snapshot, blocked, autoEnabled)
end

-- public-api
function AutoSpam.isActive() return current ~= nil and current.active end
function AutoSpam.canSend()
  local state = current
  if not state or not state.active then return false end
  if not state.dangerActivation then return true end
  local time = now()
  if closeClashProtected(state, time, CONFIG.DEACTIVATION.CLOSE_OPPONENT_PROTECTION_RADIUS) then state.dangerActivation = false; return true end
  local snapshot = gameInfo.getSnapshotAt(time)
  local risk = danger.sample(state, snapshot, time, localPlayer.UserId)
  if risk.phase == "resolved" or risk.phase == "moving_away" or risk.phase == "not_target" or risk.phase == "suspended" or risk.phase == "unavailable" then return false end
  return risk.allowSend ~= false
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
  local state = current
  local time = utils and now() or 0; local snapshot = gameInfo and gameInfo.getSnapshotAt(time)
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
    danger = state and state.danger and {
      phase = state.danger.phase, urgent = state.danger.urgent, protected = state.danger.protect,
      remainingMs = state.danger.remaining and state.danger.remaining * 1000,
      deliveryMs = state.danger.delivery and state.danger.delivery * 1000,
      graceMs = state.danger.grace and state.danger.grace * 1000,
      enteredAt = state.danger.enteredAt,
    } or nil,
  }
end

-- contract
AutoSpam.__contract = {
  requires = {
    Utils = "utils",
    GameInfo = "gameinfo",
    ClashStats = "clashstats",
    Danger = "danger",
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
      "getPlayerMotion",
      "getHaunterEvent",
      "getDeflectGeometry",
      "getDefensePhysics",
      "getDeflectRangeParameters",
      "isPlayerDashing",
      "getLocalDashState",
      "getDeflectCooldownState",
      "getPlayerDeflectRange",
      "getPlayerRawRadius",
      "getBallFrozen",
      "getBall",
      "getAveragePing",
      "getTargetId",
      "getBallSpeedLimits",
      "getClashContext",
    },
    ClashStats = { "begin", "finish", "observe", "freeze", "get", "waitForNextClash" },
    Danger = { "sample" },
  },
  provides = {
    "setup",
    "bindCharacter",
    "detachCharacter",
    "teardown",
    "onBallSync",
    "isActive",
    "canSend",
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
