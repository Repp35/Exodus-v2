-- [[ danger ]]

-- module
local Danger = {}
local gameInfo, autoParry
local CONFIG = { FRAME = 1 / 60, JITTER = 0.015, MAX_SAMPLE_AGE = 0.2, RETRY = 0.04 }
local function finite(x) return type(x) == "number" and x == x and x > -math.huge and x < math.huge end
local function vector(x) return typeof(x) == "Vector3" end
local function arrival(distance, closing, acceleration)
  if distance <= 0 then return 0 end
  if closing <= 0 then return math.huge end
  if acceleration > 0.0001 then return 2 * distance / (closing + math.sqrt(closing * closing + 2 * acceleration * distance)) end
  return distance / closing
end

-- lifecycle
function Danger.setup(deps)
  if not deps.GameInfo or not deps.AutoParry then return false, "dependências ausentes" end
  gameInfo, autoParry = deps.GameInfo, deps.AutoParry; return true
end
function Danger.teardown() gameInfo, autoParry = nil, nil end

-- monitor
function Danger.sample(owner, value, time, ownId, sendDelay)
  local m = owner.danger
  if not m or m.ball ~= (value and value.ball) or time < m.sampledAt then
    m = { ball = value and value.ball, sampledAt = time, phase = "outside", enteredAt = nil, lastRequestAt = 0, lastParriedAt = 0 }
    owner.danger = m
  end
  local frame = time > m.sampledAt and math.clamp(time - m.sampledAt, CONFIG.FRAME, 0.12) or (m.frame or CONFIG.FRAME)
  m.sampledAt, m.frame, m.urgent, m.protect, m.allowSend, m.pending = time, frame, false, false, true, false
  if not value or not gameInfo.isSnapshotValid(value) or not owner.root or not owner.root.Parent then m.phase = "unavailable"; return m end
  if value.mode == "training" or value.teleported or value.locked or gameInfo.getBallFrozen() == true then
    m.phase, m.enteredAt, m.deadline, m.graceDeadline = "suspended", nil, nil, nil; return m
  end
  if value.targetUncertain or value.targetId ~= ownId then
    m.phase = "not_target"
    if not value.targetUncertain then m.enteredAt, m.deadline, m.graceDeadline, m.resolvedAt = nil, nil, nil, nil end
    return m
  end
  if not vector(value.position) or not vector(value.velocity) then m.phase = "unavailable"; return m end
  local physics = gameInfo.getDefensePhysics(); local ap = autoParry.getDefenseState(value)
  local delta = owner.root.Position - value.position; local distance = delta.Magnitude
  local rootVelocity = owner.root.AssemblyLinearVelocity
  local relative = value.velocity - (vector(rootVelocity) and rootVelocity or Vector3.zero)
  local closing = distance > 0.001 and relative:Dot(delta) / distance or 0
  local nominal = finite(value.syncSpeed) and value.syncSpeed or value.speed
  local geometry = finite(nominal) and gameInfo.getDeflectGeometry(nominal, "game", 1, false)
  if not geometry then m.phase = "unavailable"; return m end
  local age = finite(value.serverTime) and math.max(0, physics.serverNow - value.serverTime) or nil
  local fresh = age ~= nil and age <= CONFIG.MAX_SAMPLE_AGE
  local direction = value.syncDirection
  local rawDistance, rawClosing
  if fresh and vector(value.realPosition) and vector(direction) and direction.Magnitude > 0.01 then
    local rawDelta = owner.root.Position - value.realPosition; local d = rawDelta.Magnitude
    if d > 0.001 then
      local alignment = direction.Unit:Dot(rawDelta / d)
      if alignment > 0.8 then
        local acceleration = finite(value.syncAcceleration) and math.max(0, value.syncAcceleration) or 0
        rawDistance = math.max(0, d - nominal * alignment * age - 0.5 * acceleration * age * age)
        rawClosing = nominal * alignment - (vector(rootVelocity) and rootVelocity:Dot(rawDelta / d) or 0)
      end
    end
  end
  -- Confirmation ends this arrival, never an arbitrary call to Deflect.
  if finite(ap.lastParriedAt) and ap.lastParriedAt > m.lastParriedAt then
    m.lastParriedAt = ap.lastParriedAt
    if m.enteredAt and ap.lastParriedAt >= m.enteredAt then
      m.resolvedAt, m.resolvedServerAt = time, physics.serverNow - physics.uplink
      m.outboundSeen = false
    end
  end
  if m.resolvedAt then
    if closing < -2 then m.outboundSeen = true end
    local newFlight = fresh and value.serverTime > m.resolvedServerAt + 0.001 and closing > 2
      and (m.outboundSeen or rawClosing and rawClosing > 2)
    if not newFlight then
      m.phase, m.protect, m.allowSend = "resolved", true, false; return m
    end
    m.enteredAt, m.deadline, m.graceDeadline, m.resolvedAt = nil, nil, nil, nil
    m.previousFlightRequest = finite(ap.lastRequestAt) and ap.lastRequestAt or 0
  end
  if not m.graceDeadline and closing <= 0 and (not rawClosing or rawClosing <= 0) then
    m.phase, m.enteredAt, m.deadline = "moving_away", nil, nil; return m
  end
  local modelDistance = rawDistance and math.min(distance, rawDistance) or distance
  local modelClosing = math.max(closing, rawClosing or 0)
  if not m.graceDeadline and modelDistance > geometry.fullRadius then
    m.phase, m.enteredAt, m.deadline = "outside", nil, nil; return m
  end
  m.enteredAt = m.enteredAt or time
  local acceleration = fresh and finite(value.syncAcceleration) and math.max(0, value.syncAcceleration) or 0
  local toKill = arrival(math.max(0, modelDistance - physics.killRadius), modelClosing, acceleration)
  local deadline = time + toKill + physics.grace
  if value.grace then
    -- The packet carries only a boolean, not the grace expiry. Preserve the
    -- earliest estimated deadline and subtract the age of its observation.
    m.graceDeadline = math.min(m.graceDeadline or math.huge, time + math.max(0, physics.grace - (age or physics.ping)))
  end
  if m.graceDeadline then deadline = math.min(deadline, m.graceDeadline) end
  m.deadline = deadline
  local delay = finite(sendDelay) and math.max(0, sendDelay) or 0
  local delivery = physics.uplink + frame + CONFIG.JITTER + delay
  local remaining = m.deadline - time
  local request = finite(ap.lastRequestAt) and ap.lastRequestAt or 0
  if request > m.lastRequestAt then m.lastRequestAt = request end
  local pending = request > (m.previousFlightRequest or -math.huge) and request >= m.enteredAt - frame and time - request < CONFIG.RETRY
  local blocked = not ap.enabled or not ap.armed or ap.blocking or finite(ap.retryAt) and ap.retryAt > time
  local missed = finite(ap.triggerDistance) and distance <= ap.triggerDistance and not pending
  if missed and not blocked then m.missedAt = m.missedAt or time else m.missedAt = nil end
  local overdue = m.missedAt and time - m.missedAt >= frame
  local critical = remaining <= delivery
  m.urgent = not pending and fresh and (critical or overdue or missed and blocked)
  m.protect = ap.enabled and not blocked and not missed and not critical or pending and not critical
  m.phase = critical and "critical" or m.urgent and "danger" or pending and "pending" or missed and "expected" or "watching"
  m.remaining, m.delivery, m.toKill, m.distance, m.closing = remaining, delivery, toKill, modelDistance, modelClosing
  m.grace, m.sampleAge, m.pending = physics.grace, age, pending
  m.allowSend = not pending and m.urgent
  return m
end

-- contract
Danger.__contract = {
  requires = { GameInfo = "gameinfo", AutoParry = "autoparry" },
  requiresMethods = {
    GameInfo = { "isSnapshotValid", "getDefensePhysics", "getDeflectGeometry", "getBallFrozen" },
    AutoParry = { "getDefenseState" },
  },
  provides = { "setup", "teardown", "sample" },
}
return Danger
