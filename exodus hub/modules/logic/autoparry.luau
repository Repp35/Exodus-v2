-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

local T = {
 BASE_RADIUS = 8.5,
 BASE_WINDOW = 0.5,
 MIN_WINDOW = 0.4,
 WINDOW_FACTOR = 0.5,
 MIN_SPEED = 1,
 RESILIENCE_STEP = 0.225,
 RESILIENCE_MAX = 7.5,
}

local S = {
 generation = 0, phase = "detached", reason = "initial", connections = {},
 player = nil, character = nil, root = nil, bound = false, alive = false,
 ball = nil, position = nil, positionAt = nil, velocity = Vector3.zero,
 speed = 0, distance = 0, ping = 0, pingAt = -math.huge,
 targeted = false, targetId = -1, targetKnown = false, away = false,
 cycle = 0, fired = false, inFlight = false, lastFireAt = 0,
 lastRetryRevision = 0, lastSequence = nil, teleport = false,
 approaching = false, lead = 0, resilience = 0,
 clicks = {}, returns = {}, awayAt = nil, awayId = nil,
}

local function finite(n)
 return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function vector(v)
 return typeof(v) == "Vector3"
end

local function safe(fn, ...)
 if type(fn) ~= "function" then return nil end
 local ok, value = pcall(fn, ...)
 if ok then return value end
 return nil
end

local function setPhase(phase, reason)
 S.phase, S.reason = phase, reason
end

local function disconnect()
 for i = #S.connections, 1, -1 do
  local c = S.connections[i]
  pcall(function() c:Disconnect() end)
  S.connections[i] = nil
 end
end

local function clearMotion()
 S.ball = nil
 S.position = nil
 S.positionAt = nil
 S.velocity = Vector3.zero
 S.speed = 0
 S.distance = 0
 S.approaching = false
end

local function resetCycle()
 S.fired = false
 S.inFlight = false
end

local function resetState()
 clearMotion()
 resetCycle()
 S.targeted = false
 S.targetId = -1
 S.targetKnown = false
 S.away = false
 S.teleport = false
 S.lastSequence = nil
 S.lastRetryRevision = 0
 S.resilience = 0
 S.cycle = 0
 S.awayAt, S.awayId = nil, nil
 table.clear(S.clicks)
 table.clear(S.returns)
end

local function observeTarget(id)
 if not finite(id) or id <= 0 or not S.player then return end
 if id ~= S.player.UserId then
  if not S.away then
   S.awayAt, S.awayId = os.clock(), id
  elseif S.awayId ~= id then
   S.awayAt, S.awayId = nil, nil
  end
  S.away = true
 elseif S.away then
  local elapsed = S.awayAt and os.clock() - S.awayAt
  if elapsed and elapsed > 0 and elapsed <= 3 and S.awayId then
   table.insert(S.returns, {at = os.clock(), interval = elapsed})
   if #S.returns > 32 then table.remove(S.returns, 1) end
  end
  S.away = false
  S.awayAt, S.awayId = nil, nil
  S.cycle += 1
  resetCycle()
 end
end

local function getConfig()
 return Utils and safe(Utils.getConfig) or {}
end

local function enabled()
 local c = getConfig()
 return c.AutoParry ~= false and safe(Utils.isActive) == true and safe(Utils.isSpamActive) ~= true
end

local function factor(override)
 local c = getConfig()
 local value = tonumber(override) or tonumber(c.ParryWindowFactor) or T.WINDOW_FACTOR
 return math.clamp(value, 0, 1)
end

local function minSpeed()
 local limits = GameInfo and safe(GameInfo.getBallSpeedLimits)
 if type(limits) == "table" then
  local n = tonumber(limits.min or limits.minimum)
  if finite(n) and n > 0 then return n end
 end
 return T.MIN_SPEED
end

local function samplePing(now)
 if now - S.pingAt < 1 then return end
 S.pingAt = now
 local value = GameInfo and safe(GameInfo.getLocalPing)
 if finite(value) then S.ping = math.max(0, value) end
end

local function resilience(now)
 local range = GameInfo and safe(GameInfo.getDeflectRange)
 local value = tonumber(range)
 S.resilience = finite(value) and math.clamp(value - T.BASE_RADIUS, 0, T.RESILIENCE_MAX) or 0
 return S.resilience
end

local function radius(speed, windowFactor, baseWindow)
 speed = finite(speed) and math.max(0, speed) or 0
 local win = math.max(T.MIN_WINDOW, T.BASE_WINDOW)
 local actual = GameInfo and safe(GameInfo.getDeflectWindow, speed)
 if finite(actual) and actual > 0 then win = actual end
 if finite(baseWindow) and baseWindow > 0 then win = baseWindow end
 local ping = math.max(0, S.ping)
 local f = factor(windowFactor)
 local bonus = resilience(os.clock())
 local base = T.BASE_RADIUS + bonus
 local pingRadius = speed * ping * f
 local full = base + speed * win * f + pingRadius
 return full, win + ping, base, pingRadius, win, win * f, f
end

local function positionOf(ball, snapshot)
 if snapshot and vector(snapshot.position) then return snapshot.position end
 return GameInfo and safe(GameInfo.getBallPosition, ball)
end

local function velocityOf(ball, snapshot, pos, now)
 local velocity = GameInfo and safe(GameInfo.getBallVelocity, ball)
 if not vector(velocity) or velocity.Magnitude < 0.1 then
  velocity = snapshot and snapshot.velocity
 end
 if (not vector(velocity) or velocity.Magnitude < 0.1) and vector(S.position) and finite(S.positionAt) then
  local elapsed = now - S.positionAt
  if elapsed > 0 then velocity = (pos - S.position) / elapsed end
 end
 S.position, S.positionAt = pos, now
 return vector(velocity) and velocity or Vector3.zero
end

local function cooldown()
 return GameInfo and safe(GameInfo.getDeflectCooldownState)
end

local function readSnapshot(now)
 local snapshot = GameInfo and (safe(GameInfo.getSnapshotAt, now) or safe(GameInfo.getSnapshot))
 if type(snapshot) == "table" and safe(GameInfo.isSnapshotValid, snapshot, now) == false then snapshot = nil end
 local ball = snapshot and snapshot.ball or (GameInfo and safe(GameInfo.getBall))
 if typeof(ball) ~= "Instance" or not ball:IsA("BasePart") or not ball.Parent then return nil end
 return ball, snapshot
end

local function fire(ball)
 if S.inFlight or S.fired or S.teleport or not S.bound or not S.alive then return false end
 if not enabled() or not S.approaching or S.speed < minSpeed() or S.ball ~= ball then return false end
 local cd = cooldown()
 if cd and (cd.active or cd.blocking) then return false end
 S.inFlight = true
 local cycle = S.cycle
 local ok, result = pcall(Remote.fireParry, 1)
 local success = ok and result ~= false
 if cycle == S.cycle and S.ball == ball then
  if success then
   S.fired = true
   S.lastFireAt = os.clock()
   local f = factor()
   local actual = S.speed > 0 and S.lead > 0 and math.max(0, (S.distance - T.BASE_RADIUS - S.resilience) / (S.speed * S.lead)) or f
   table.insert(S.clicks, {at = S.lastFireAt, factor = actual, configured = math.max(f, 0.001), speed = S.speed})
   if #S.clicks > 32 then table.remove(S.clicks, 1) end
  end
 end
 S.inFlight = false
 return success
end

local function onHeartbeat(character, root, dt, generation)
 if generation ~= S.generation or not S.bound or not S.alive then return end
 if not character.Parent or not root.Parent then return end
 local now = os.clock()
 samplePing(now)
 local cd = cooldown()
 if cd and finite(cd.retryRevision) and cd.retryRevision > S.lastRetryRevision then
  S.lastRetryRevision = cd.retryRevision
  if not cd.blocking and not S.away then resetCycle() end
 end
 local sync = GameInfo and safe(GameInfo.getSyncData)
 if type(sync) == "table" and sync.Teleported == true then S.teleport = true end
 if S.teleport then setPhase("waiting", "teleport_lock"); return end
 if not enabled() then setPhase("waiting", "disabled"); return end
 local ball, snapshot = readSnapshot(now)
 if not ball then clearMotion(); setPhase("waiting", "no_ball"); return end
 if ball ~= S.ball then
  clearMotion()
  resetCycle()
  S.ball = ball
 end
 local targetId = snapshot and tonumber(snapshot.targetId) or (GameInfo and safe(GameInfo.getTargetId))
 if finite(targetId) and targetId > 0 then
  observeTarget(targetId)
  S.targetId, S.targetKnown = targetId, true
 end
 local targeted = snapshot and snapshot.targeted == true
 if not snapshot then targeted = S.player and targetId == S.player.UserId end
 S.targeted = targeted == true
 if not S.targeted then setPhase("waiting", "not_targeted"); return end
 local pos = positionOf(ball, snapshot)
 local rootPos = GameInfo and safe(GameInfo.getRootPosition, root)
 if not vector(pos) or not vector(rootPos) then setPhase("waiting", "position_unavailable"); return end
 local velocity = velocityOf(ball, snapshot, pos, now)
 local delta = rootPos - pos
 local speed, distance = velocity.Magnitude, delta.Magnitude
 S.velocity, S.speed, S.distance = velocity, speed, distance
 S.approaching = speed >= minSpeed() and distance > 0 and velocity:Dot(delta) > 0
 local full, lead = radius(speed)
 S.lead = lead
 if not S.approaching then setPhase("waiting", "not_approaching"); return end
 if cd and (cd.active or cd.blocking) then setPhase("waiting", "deflect_cooldown"); return end
 if S.fired or S.inFlight then setPhase("waiting", "already_fired"); return end
 if distance <= full then
  setPhase("parrying", "within_radius")
  fire(ball)
 else
  setPhase("tracking", "approaching")
 end
end

local function detach(reason)
 S.generation += 1
 disconnect()
 S.character, S.root = nil, nil
 S.bound, S.alive = false, false
 resetState()
 setPhase("detached", reason or "detach")
end

function AutoParry.setup(deps)
 if type(deps) ~= "table" then return false, "dependencias invalidas" end
 for _, name in ipairs({"Remote", "GameInfo", "Utils"}) do
  if type(deps[name]) ~= "table" then return false, "dependencia ausente: " .. name end
 end
 if type(deps.Remote.fireParry) ~= "function" then return false, "Remote.fireParry ausente" end
 Remote, GameInfo, Utils = deps.Remote, deps.GameInfo, deps.Utils
 detach("setup")
 S.player = safe(Utils.getLocalPlayer)
 if not S.player then return false, "LocalPlayer indisponivel" end
 return true
end

function AutoParry.bindCharacter(character)
 if not Utils or not GameInfo or not Remote then return false, "setup pendente" end
 detach("rebind")
 if not character or not character.Parent then return false, "personagem indisponivel" end
 local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
 if not root or not root:IsA("BasePart") then return false, "HumanoidRootPart indisponivel" end
 local run = safe(Utils.getRunService)
 local signal = run and (run.PostSimulation or run.Heartbeat)
 if not signal then return false, "RunService indisponivel" end
 S.character, S.root, S.bound, S.alive = character, root, true, true
 local generation = S.generation
 table.insert(S.connections, signal:Connect(function(dt) onHeartbeat(character, root, dt, generation) end))
 table.insert(S.connections, character.AncestryChanged:Connect(function(_, parent)
  if not parent and generation == S.generation then detach("character_removed") end
 end))
 setPhase("waiting", "character_bound")
 return true
end

function AutoParry.detachCharacter() detach("detach") end
function AutoParry.resetState() detach("reset") end
function AutoParry.teardown()
 detach("teardown")
 Remote, GameInfo, Utils = nil, nil, nil
 S.player = nil
end

function AutoParry.fire()
 return S.ball and fire(S.ball) or false
end

function AutoParry.onBallSync(data)
 if type(data) ~= "table" or not S.bound then return end
 local seq = tonumber(data.Sequence or data.TeleportSequence)
 if finite(seq) and seq >= 0 and seq < 65536 and seq % 1 == 0 then
  if S.lastSequence ~= nil then
   local delta = (seq - S.lastSequence) % 65536
   if delta == 0 or delta >= 32768 then return true end
  end
  S.lastSequence = seq
 end
 if data.Teleported == true then
  S.teleport = true
  clearMotion()
  resetCycle()
  return true
 end
 S.teleport = false
 local id = tonumber(data.TargetPlayerID)
 if not id then id = GameInfo and safe(GameInfo.getTargetId) end
 if finite(id) then
  observeTarget(id)
  S.targetId, S.targetKnown = id, true
 end
 if data.Source == "packet" and S.player and id == S.player.UserId and S.character and S.root then
  onHeartbeat(S.character, S.root, 0, S.generation)
 end
 return true
end

function AutoParry.getTargetStatus()
 return {
  armed = not S.fired and not S.inFlight,
  firedForTarget = S.fired,
  lastTargeted = S.targeted,
  targeted = S.targeted,
  approaching = S.approaching,
  targetId = S.targetId,
  targetKnown = S.targetKnown,
  cooldown = cooldown(),
 }
end

function AutoParry.getTiming(snapshot, now, rootPosition, windowFactor, baseWindow)
 if type(snapshot) ~= "table" then return nil end
 local pos = snapshot.position
 if not vector(pos) then pos = positionOf(snapshot.ball, snapshot) end
 if not vector(rootPosition) and S.root then rootPosition = safe(GameInfo.getRootPosition, S.root) end
 if not vector(pos) or not vector(rootPosition) then return nil end
 local velocity = snapshot.velocity
 if not vector(velocity) then velocity = S.velocity end
 local speed = vector(velocity) and velocity.Magnitude or tonumber(snapshot.speed) or 0
 local distance = (rootPosition - pos).Magnitude
 local full, lead, base, pingRadius, win, effective, f = radius(speed, windowFactor, baseWindow)
 return {
  distance = distance, speed = speed, velocity = velocity,
  parryRadius = full, fullRadius = full, pureRadius = T.BASE_RADIUS,
  noWindowParryRadius = base, pingRadius = pingRadius,
  resilienceBonus = S.resilience, leadTime = lead,
  deflectWindow = win, effectiveWindow = effective, windowFactor = f,
  distanceToParryRadius = distance - full,
  tti = speed > 0 and math.max(distance - full, 0) / speed or math.huge,
  approaching = vector(velocity) and velocity:Dot(rootPosition - pos) > 0,
  targeted = snapshot.targeted == true,
 }
end

function AutoParry.getRadius(mode, windowFactor, speedOverride, baseWindow)
 mode = mode == "tti" or mode == "speed_distance" and mode or "geometry"
 local speed = tonumber(speedOverride) or S.speed
 local full, lead, base, pingRadius, win, effective, f = radius(speed, windowFactor, baseWindow)
 local tti = speed > 0 and math.max(S.distance - full, 0) / speed or math.huge
 local value = full
 if mode == "tti" then value = tti
 elseif mode == "speed_distance" then value = {speed = speed, distance = S.distance} end
 return {
  mode = mode, value = value, pureRadius = T.BASE_RADIUS,
  noWindowParryRadius = base, pingRadius = pingRadius,
  resilience = {bonus = S.resilience}, fullRadius = full,
  deflectWindow = win, windowFactor = f, effectiveWindow = effective,
  leadTime = lead, distance = S.distance, speed = speed, tti = tti,
 }
end

function AutoParry.getPressure()
 local now = os.clock()
 local clicks, returns = {}, {}
 for _, sample in ipairs(S.clicks) do
  if now - sample.at <= 3 then table.insert(clicks, sample) end
 end
 for _, sample in ipairs(S.returns) do
  if now - sample.at <= 3 then table.insert(returns, sample) end
 end
 local factorSum, configuredSum, speedSum, ratioSum, intervalSum = 0, 0, 0, 0, 0
 for _, sample in ipairs(clicks) do
  factorSum += sample.factor
  configuredSum += sample.configured
  speedSum += sample.speed
  ratioSum += math.clamp(sample.factor / sample.configured, 0, 1)
 end
 for _, sample in ipairs(returns) do intervalSum += sample.interval end
 local n, m = #clicks, #returns
 local latest = clicks[n]
 local lastReturn = returns[m]
 local level = n >= 3 and m >= 2 and math.clamp(1 - ratioSum / n, 0, 1) or nil
 return {
  samples = n, cps = n / 3,
  averageFactor = n > 0 and factorSum / n or nil,
  configuredFactor = n > 0 and configuredSum / n or nil,
  averageSpeed = n > 0 and speedSum / n or nil,
  returnSamples = m, averageReturnTime = m > 0 and intervalSum / m or nil,
  level = level, currentFactor = latest and latest.factor or nil,
  currentLevel = level, factorDrop = nil,
  latestReturnTime = lastReturn and lastReturn.interval or nil,
 }
end

function AutoParry.getStatus()
 local r = AutoParry.getRadius("geometry")
 return {
  api = {name = "AutoParry", version = 11, endpoints = {"getRadius", "getTiming", "getStatus", "getTargetStatus"}, radiusModes = {"geometry", "tti", "speed_distance"}, defaultWindowFactor = T.WINDOW_FACTOR, windowFactorRange = {min = 0, max = 1}},
  lifecycle = {phase = S.phase, reason = S.reason, bound = S.bound, alive = S.alive, generation = S.generation, lifeGeneration = S.generation},
  radius = r, resilience = {bonus = S.resilience},
  timing = {tti = r.tti, ti = r.tti, speed = S.speed, distance = S.distance, distanceToRadius = S.distance - r.fullRadius, deflectWindow = r.deflectWindow, effectiveWindow = r.effectiveWindow, leadTime = S.lead, noWindowParryRadius = r.noWindowParryRadius, pingRadius = r.pingRadius, approaching = S.approaching},
  ping = {oneWay = S.ping, raw = S.ping},
  target = AutoParry.getTargetStatus(), pressure = AutoParry.getPressure(),
  cycle = {fired = S.fired, armed = not S.fired, lastFireAt = S.lastFireAt, lastTTI = r.tti},
  config = {baseRadius = T.BASE_RADIUS, baseWindow = T.BASE_WINDOW, defaultWindowFactor = T.WINDOW_FACTOR, windowFactorRange = {min = 0, max = 1}, minBallSpeed = minSpeed()},
  timestamp = os.clock(),
 }
end

AutoParry.__contract = {
 requires = {Remote = "remote", GameInfo = "gameinfo", Utils = "utils"},
 requiresMethods = {
  Remote = {"fireParry"},
  GameInfo = {"getSnapshot", "isSnapshotValid", "getBall", "getSyncData", "getTargetId", "getDeflectRange", "getDeflectCooldownState", "getLocalPing", "getBallPosition", "getBallVelocity", "getRootPosition"},
  Utils = {"getLocalPlayer", "getRunService", "getConfig", "isActive", "isSpamActive", "trackCharacter", "untrackCharacter", "trackGlobal", "untrackGlobal"},
 },
 provides = {"setup", "bindCharacter", "detachCharacter", "onBallSync", "fire", "resetState", "getRadius", "getTiming", "getStatus"},
 onBallSync = true, bindCharacter = true, version = 11,
}

return AutoParry
