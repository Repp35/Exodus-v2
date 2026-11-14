-- [[ autofierce ]]

-- module
local AutoFierce = {}
local utils, gameInfo, remote, autoParry, cooldownInfo
local connections = {}
local lastFierceEpisode, localUserId
local hookedAbility, hookedRaw, hookedWrapper

-- configuration
local CONFIG = {
  SYNC_MAX_AGE = 0.25,
  WINDOW_FACTOR = 0.3,
}

-- helpers
local function track(connection)
  connections[#connections + 1] = connection; utils.trackGlobal(connection)
  return connection
end
local function enabled() return utils and utils.isActive() and utils.getConfigValue("AutoFierce") == true and gameInfo.areAbilitiesEnabled() end
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
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
    local token
    if not finite(self.Cooldown) or self.Cooldown <= 0 then
      local ok, value = pcall(autoParry.beginFierce)
      if ok then token = value end
    end
    local result = table.pack(pcall(original, self, ...))
    if not result[1] or result[2] == false then autoParry.cancelFierce(token) end
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
  local timing = autoParry.getTiming(snapshot, now, nil, CONFIG.WINDOW_FACTOR); return timing and timing.approaching and timing.distance <= timing.triggerDistance
end
local function fierceReady()
  local ability = gameInfo.getFierceDeflectAbility()
  if not ability then return false end
  return not finite(ability.Cooldown) or ability.Cooldown <= 0
end

-- detection
local function update()
  if not enabled() then return end
  local now = os.clock(); local snapshot = validTargetSnapshot(now)
  if not snapshot or not fierceReady() then return end
  local cooldown = cooldownInfo.getDeflectCooldownState()
  if not cooldown or cooldown.blocking ~= true or not cooldown.episode or cooldown.episode <= lastFierceEpisode or not incomingInWindow(snapshot, now) then return end
  local episode, ball, token = cooldown and cooldown.episode, snapshot.ball, nil
  local ok, sent = pcall(function()
    return remote.fireFierce(function()
      if not enabled() or not fierceReady() then return false end
      local currentSnapshot = validTargetSnapshot(os.clock())
      if not currentSnapshot or currentSnapshot.ball ~= ball then return false end
      local current = cooldownInfo.getDeflectCooldownState()
      if not current or current.episode ~= episode or current.blocking ~= true or not incomingInWindow(currentSnapshot, os.clock()) then return false end
      token = autoParry.beginFierce(); return true
    end)
  end)
  if ok and sent == true then
    if episode then lastFierceEpisode = math.max(lastFierceEpisode, episode) end
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
  lastFierceEpisode = 0; local player = utils.getLocalPlayer()
  localUserId = player and player.UserId; local runService = utils.getRunService()
  if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
  bindManualFierce()
  track(runService.Heartbeat:Connect(function()
    bindManualFierce(); update()
  end))
  return true
end
function AutoFierce.teardown()
  unhookManualFierce()
  for _, connection in ipairs(connections) do
    if utils then utils.untrackGlobal(connection) end
    connection:Disconnect()
  end
  connections = {}; lastFierceEpisode, localUserId = nil, nil
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
