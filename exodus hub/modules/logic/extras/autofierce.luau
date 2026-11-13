-- [[ autofierce ]]

-- module
local AutoFierce = {}
local utils, gameInfo, remote, autoParry
local connections = {}
local parriedConnection
local nextSignalAt, parryGeneration, lastParriedAt, lastFiercePressAt, localUserId
local observedPressAt, missDeadline

-- configuration
local CONFIG = {
  SIGNAL_RETRY = 0.5,
  SYNC_MAX_AGE = 0.25,
  NOOB_WINDOW_EXTRA = 0.15,
  WINDOW_FACTOR = 0.3,
}

-- helpers
local function track(connection)
  connections[#connections + 1] = connection; utils.trackGlobal(connection)
  return connection
end
local function enabled() return utils and utils.isActive() and utils.getConfigValue("AutoFierce") == true and gameInfo.areAbilitiesEnabled() end

-- signals
local function onParried()
  parryGeneration += 1
  lastParriedAt = os.clock()
end
local function clearDisconnectedSignal()
  if not parriedConnection or parriedConnection.Connected ~= false then return end
  if utils then utils.untrackGlobal(parriedConnection) end
  table.remove(connections, table.find(connections, parriedConnection)); parriedConnection = nil
end
local function connectSignals(now)
  clearDisconnectedSignal()
  if now < nextSignalAt or parriedConnection then return end
  nextSignalAt = now + CONFIG.SIGNAL_RETRY; local signals = gameInfo.getDeflectServerEvents()
  if signals and signals.parried then parriedConnection = track(signals.parried:Connect(onParried)) end
end
local function incomingInWindow(now)
  local snapshot = gameInfo.getSnapshotAt(now)
  if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported or snapshot.locked or snapshot.targetUncertain then return false end
  if localUserId == nil or snapshot.targetId ~= localUserId or gameInfo.getBallFrozen() ~= false then return false end
  if type(snapshot.syncAt) ~= "number" or snapshot.syncAt <= 0 or now < snapshot.syncAt or now - snapshot.syncAt > CONFIG.SYNC_MAX_AGE then return false end
  local timing = autoParry.getTiming(snapshot, now, nil, CONFIG.WINDOW_FACTOR)
  return timing and timing.approaching and timing.distance <= timing.triggerDistance
end
local function confirmedMiss(now)
  local pressedAt = gameInfo.getLastDeflectPressAt()
  if type(pressedAt) ~= "number" or pressedAt ~= pressedAt or pressedAt <= 0 then pressedAt = observedPressAt end
  if not pressedAt or pressedAt > now then return false end
  if not observedPressAt or pressedAt > observedPressAt + 0.05 then
    observedPressAt, missDeadline = pressedAt, nil
    local window = gameInfo.getDeflectWindow(nil, false)
    local ping = gameInfo.getLocalPing()
    if type(ping) ~= "number" or ping ~= ping or ping < 0 then ping = 0 end
    if type(window) == "number" and window == window and window > 0 and window < math.huge then
      missDeadline = pressedAt + window + CONFIG.NOOB_WINDOW_EXTRA + 2 * ping
    end
  end
  local cooldown = gameInfo.getDeflectCooldownState()
  return observedPressAt > lastParriedAt and observedPressAt > lastFiercePressAt and missDeadline ~= nil and now > missDeadline
    and cooldown and cooldown.blocking == true and cooldown.predictedReset ~= true
end

-- detection
local function update()
  local now = os.clock()
  if not enabled() then return end
  if not parriedConnection or parriedConnection.Connected == false then connectSignals(now) end
  if not parriedConnection or not confirmedMiss(now) or not incomingInWindow(now) then return end
  local generation, pressedAt = parryGeneration, observedPressAt
  local token
  local ok, sent = pcall(function()
    return remote.fireFierce(function()
      if not enabled() or parryGeneration ~= generation or not confirmedMiss(os.clock()) or observedPressAt ~= pressedAt or not incomingInWindow(os.clock()) then return false end
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
  nextSignalAt, parryGeneration, lastParriedAt, lastFiercePressAt, observedPressAt, missDeadline = 0, 0, 0, 0, nil, nil; local player = utils.getLocalPlayer()
  localUserId = player and player.UserId; local runService = utils.getRunService()
  if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
  track(runService.Heartbeat:Connect(update)); return true
end
function AutoFierce.teardown()
  for _, connection in ipairs(connections) do
    if utils then utils.untrackGlobal(connection) end
    connection:Disconnect()
  end
  connections = {}; parriedConnection, nextSignalAt, parryGeneration, lastParriedAt, lastFiercePressAt, localUserId = nil, nil, nil, nil, nil, nil
  observedPressAt, missDeadline = nil, nil
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
      "getDeflectServerEvents",
      "getLastDeflectPressAt",
      "getDeflectWindow",
      "getDeflectCooldownState",
      "getLocalPing",
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

