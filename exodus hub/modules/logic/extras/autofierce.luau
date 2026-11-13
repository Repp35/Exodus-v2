-- [[ autofierce ]]

-- module
local AutoFierce = {}
local utils, gameInfo, remote, autoParry
local connections = {}
local lastFiercePressAt, localUserId

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

local function incomingInWindow(now)
  local snapshot = gameInfo.getSnapshotAt(now)
  if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported or snapshot.locked or snapshot.targetUncertain then return false end
  if localUserId == nil or snapshot.targetId ~= localUserId or gameInfo.getBallFrozen() ~= false then return false end
  if type(snapshot.syncAt) ~= "number" or snapshot.syncAt <= 0 or now < snapshot.syncAt or now - snapshot.syncAt > CONFIG.SYNC_MAX_AGE then return false end
  local timing = autoParry.getTiming(snapshot, now, nil, CONFIG.WINDOW_FACTOR); return timing and timing.approaching and timing.distance <= timing.triggerDistance
end
-- detection
local function update()
  if not enabled() then return end
  local now = os.clock(); local cooldown = gameInfo.getDeflectCooldownState()
  if not cooldown or cooldown.missConfirmed ~= true or cooldown.blocking ~= true or not cooldown.pressAt or cooldown.pressAt <= lastFiercePressAt or not incomingInWindow(now) then return end
  local pressedAt, token = cooldown.pressAt, nil
  local ok, sent = pcall(function()
    return remote.fireFierce(function()
      local current = gameInfo.getDeflectCooldownState()
      if not enabled() or not current or current.pressAt ~= pressedAt or current.missConfirmed ~= true or current.blocking ~= true or not incomingInWindow(os.clock()) then return false end
      token = autoParry.beginFierce(); return true
    end)
  end)
  if ok and sent == true then lastFiercePressAt = pressedAt end
  if not ok or sent ~= true then autoParry.cancelFierce(token) end
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
  then
    return false, "dependências ausentes: Utils, GameInfo ou Remote"
  end
  AutoFierce.teardown(); utils, gameInfo, remote, autoParry = deps.Utils, deps.GameInfo, deps.Remote, deps.AutoParry
  lastFiercePressAt = 0; local player = utils.getLocalPlayer()
  localUserId = player and player.UserId; local runService = utils.getRunService()
  if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
  track(runService.Heartbeat:Connect(update)); return true
end
function AutoFierce.teardown()
  for _, connection in ipairs(connections) do
    if utils then utils.untrackGlobal(connection) end
    connection:Disconnect()
  end
  connections = {}; lastFiercePressAt, localUserId = nil, nil
  utils, gameInfo, remote, autoParry = nil, nil, nil, nil
end

-- contract
AutoFierce.__contract = {
  requires = {
    Utils = "utils",
    GameInfo = "gameinfo",
    Remote = "remote",
    AutoParry = "autoparry",
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
      "getDeflectCooldownState",
      "getSnapshotAt",
      "isSnapshotValid",
      "getBallFrozen",
    },
    AutoParry = { "beginFierce", "cancelFierce", "getTiming" },
    Remote = { "fireFierce" },
  },
  provides = { "setup", "teardown" },
}

return AutoFierce

