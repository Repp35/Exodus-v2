-- [[ autofierce ]]

-- module
local AutoFierce = {}
local utils, gameInfo, remote, autoParry, cooldownInfo
local connections = {}
local lastFierceEpisode, localUserId
local graceState
local hookedAbility, hookedRaw, hookedWrapper

-- configuration
local CONFIG = {
  SYNC_MAX_AGE = 0.25,
  WINDOW_FACTOR = 0.3,
  GRACE_MAX_PACKET_GAP = 0.15,
  GRACE_FRAME_MARGIN = 2 / 60,
  GRACE_RANGE_TOLERANCE = 1,
}

-- helpers
local function track(connection)
  connections[#connections + 1] = connection; utils.trackGlobal(connection)
  return connection
end
local function enabled() return utils and utils.isActive() and utils.getConfigValue("AutoFierce") == true and gameInfo.areAbilitiesEnabled() end
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
-- The game calls ActivateAndBlock for the UI and keybind as well as the hub.
-- Wrap the current ability instance so AutoParry is held before its Deflect call.
local function unhookManualFierce()
  local ability, wrapper, raw = hookedAbility, hookedWrapper, hookedRaw
  if ability and wrapper then
    pcall(function()
      if ability.ActivateAndBlock == wrapper then ability.ActivateAndBlock = raw end
    end)
  end
  hookedAbility, hookedRaw, hookedWrapper = nil, nil, nil
end
local function bindManualFierce()
  local ability = gameInfo.getFierceDeflectAbility()
  if ability == hookedAbility and ability and ability.ActivateAndBlock == hookedWrapper then return end
  unhookManualFierce()
  if type(ability) ~= "table" or type(ability.ActivateAndBlock) ~= "function" then return end
  local original, raw = ability.ActivateAndBlock, rawget(ability, "ActivateAndBlock")
  local wrapper = function(self, ...)
    local token; local wasHandled = graceState and graceState.handled
    if not finite(self.Cooldown) or self.Cooldown <= 0 then
      local ok, value = pcall(autoParry.beginFierce)
      if ok then token = value end
      if graceState and graceState.active then graceState.handled = true end
    end
    local result = table.pack(pcall(original, self, ...))
    if not result[1] or result[2] == false then
      autoParry.cancelFierce(token)
      if graceState then graceState.handled = wasHandled end
    end
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
  end
  local ok = pcall(function() ability.ActivateAndBlock = wrapper end)
  if ok and ability.ActivateAndBlock == wrapper then hookedAbility, hookedRaw, hookedWrapper = ability, raw, wrapper end
end
local function validTargetSnapshot(now)
  local snapshot = gameInfo.getSnapshotAt(now)
  if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported or snapshot.locked or snapshot.targetUncertain then return nil end
  if localUserId == nil or snapshot.targetId ~= localUserId or gameInfo.getBallFrozen() ~= false then return nil end
  if not finite(snapshot.syncAt) or snapshot.syncAt <= 0 or now < snapshot.syncAt or now - snapshot.syncAt > CONFIG.SYNC_MAX_AGE then return nil end
  return snapshot
end
local function incomingInWindow(snapshot, now)
  local timing = autoParry.getTiming(snapshot, now, nil, CONFIG.WINDOW_FACTOR)
  return timing and timing.approaching and timing.distance <= timing.triggerDistance
end
local function fierceReady()
  local ability = gameInfo.getFierceDeflectAbility()
  if not ability then return false end
  return not finite(ability.Cooldown) or ability.Cooldown <= 0
end
local function observeGrace(snapshot)
  if not snapshot or snapshot.mode == "training" then return end
  local state = graceState
  if state.ball ~= snapshot.ball then
    state.ball, state.active, state.handled, state.lastSafeServer, state.startedAfter = snapshot.ball, false, false, nil, nil
  end
  if snapshot.grace ~= true then
    state.active, state.handled, state.startedAfter = false, false, nil
    if finite(snapshot.serverTime) and (not state.lastSafeServer or snapshot.serverTime > state.lastSafeServer) then state.lastSafeServer = snapshot.serverTime end
    return
  end
  if not state.active then
    state.active, state.handled = true, false
    local stamp, previous = snapshot.serverTime, state.lastSafeServer
    if finite(stamp) and finite(previous) and stamp >= previous and stamp - previous <= CONFIG.GRACE_MAX_PACKET_GAP then
      state.startedAfter = previous
    else
      state.startedAfter = nil
    end
  end
end
local function graceEmergency(snapshot, now, cooldown)
  local state = graceState
  if not snapshot or snapshot.mode == "training" or snapshot.grace ~= true or not state.active or state.handled then return false end
  local timing = autoParry.getTiming(snapshot, now, nil, 0)
  if not timing or not finite(timing.distance) or not finite(timing.noWindowParryRadius)
    or timing.distance > timing.noWindowParryRadius + CONFIG.GRACE_RANGE_TOLERANCE then return false end
  if cooldown and cooldown.predictedReset == true then return false end
  local ok, physics = pcall(gameInfo.getDefensePhysics)
  local known = ok and type(physics) == "table" and finite(physics.grace) and physics.grace > 0 and finite(physics.serverNow)
  local ping = known and finite(physics.ping) and math.max(0, physics.ping) or 0
  local margin = ping + CONFIG.GRACE_FRAME_MARGIN
  local remaining = known and state.startedAfter and (state.startedAfter + physics.grace - physics.serverNow) or 0
  -- A valid normal deflect that lasts until the grace deadline is already protection.
  if cooldown and cooldown.phase == "reversible" and finite(cooldown.missDeadline)
    and cooldown.missDeadline - now >= math.max(0, remaining) + margin then return false end
  return remaining <= margin
end

-- detection
local function update()
  if not enabled() then
    graceState.ball, graceState.active, graceState.handled, graceState.lastSafeServer, graceState.startedAfter = nil, false, false, nil, nil
    return
  end
  local now = os.clock(); local observed = gameInfo.getSnapshotAt(now)
  if gameInfo.isSnapshotValid(observed) and observed.targetUncertain ~= true and observed.targetId ~= localUserId then
    graceState.ball, graceState.active, graceState.handled, graceState.lastSafeServer, graceState.startedAfter = nil, false, false, nil, nil
  end
  local snapshot = validTargetSnapshot(now)
  if not snapshot then return end
  observeGrace(snapshot)
  if not fierceReady() then return end
  local cooldown = cooldownInfo.getDeflectCooldownState()
  local emergency = graceEmergency(snapshot, now, cooldown)
  local miss = cooldown and cooldown.miss == true and cooldown.blocking == true and cooldown.episode
    and cooldown.episode > lastFierceEpisode and incomingInWindow(snapshot, now)
  if not emergency and not miss then return end
  local episode, ball, token = cooldown and cooldown.episode, snapshot.ball, nil
  local ok, sent = pcall(function()
    return remote.fireFierce(function()
      if not enabled() or not fierceReady() then return false end
      local currentSnapshot = validTargetSnapshot(os.clock())
      if not currentSnapshot or currentSnapshot.ball ~= ball then return false end
      local current = cooldownInfo.getDeflectCooldownState()
      if emergency then
        if not graceEmergency(currentSnapshot, os.clock(), current) then return false end
      elseif not current or current.episode ~= episode or current.miss ~= true or current.blocking ~= true or not incomingInWindow(currentSnapshot, os.clock()) then
        return false
      end
      token = autoParry.beginFierce(); return true
    end)
  end)
  if ok and sent == true then
    if episode then lastFierceEpisode = math.max(lastFierceEpisode, episode) end
    if graceState.active then graceState.handled = true end
  else
    autoParry.cancelFierce(token)
  end
  if not ok then error(sent, 0) end
end

-- lifecycle
function AutoFierce.setup(deps)
  if
    type(deps) ~= "table"
    or type(deps.Utils) ~= "table"
    or type(deps.GameInfo) ~= "table"
    or type(deps.Remote) ~= "table"
    or type(deps.AutoParry) ~= "table"
    or type(deps.Cooldown) ~= "table"
  then
    return false, "dependências ausentes: Utils, GameInfo ou Remote"
  end
  AutoFierce.teardown(); utils, gameInfo, remote, autoParry, cooldownInfo = deps.Utils, deps.GameInfo, deps.Remote, deps.AutoParry, deps.Cooldown
  lastFierceEpisode = 0; graceState = { active = false, handled = false }; local player = utils.getLocalPlayer()
  localUserId = player and player.UserId; local runService = utils.getRunService()
  if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
  bindManualFierce()
  track(runService.Heartbeat:Connect(function() bindManualFierce(); update() end)); return true
end
function AutoFierce.teardown()
  unhookManualFierce()
  for _, connection in ipairs(connections) do
    if utils then utils.untrackGlobal(connection) end
    connection:Disconnect()
  end
  connections = {}; lastFierceEpisode, localUserId, graceState = nil, nil, nil
  utils, gameInfo, remote, autoParry, cooldownInfo = nil, nil, nil, nil, nil
end

-- contract
AutoFierce.__contract = {
  requires = {
    Utils = "utils",
    GameInfo = "gameinfo",
    Remote = "remote",
    AutoParry = "autoparry",
    Cooldown = "cooldown",
  },
  requiresMethods = {
    Utils = {
      "getConfigValue",
      "getLocalPlayer",
      "getRunService",
      "isActive",
      "observeConfig",
      "trackGlobal",
      "untrackGlobal",
    },
    GameInfo = {
      "areAbilitiesEnabled",
      "getFierceDeflectAbility",
      "getDefensePhysics",
      "getSnapshotAt",
      "isSnapshotValid",
      "getBallFrozen",
    },
    Cooldown = { "getDeflectCooldownState" },
    AutoParry = { "beginFierce", "cancelFierce", "getTiming" },
    Remote = { "fireFierce" },
  },
  provides = { "setup", "teardown" },
}

return AutoFierce

