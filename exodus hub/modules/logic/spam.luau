-- [[ spam ]]

-- module
local Spam = {}
local utils, remote, gameInfo, autoSpam, spamObserver, configObserver
local function traceback(err) return debug.traceback(tostring(err), 2) end
local generation, running, inFlight = 0, false, false
local currentMode, currentRate
local nextAllowedAt = 0
local status = { phase = "stopped", lastRequestAt = 0, lastError = nil, lastErrorAt = -math.huge }
local samples, sampleIndex = {}, 0

-- configuration
local CONFIG = {
  POLL_INTERVAL = 0.01,
  ERROR_RETRY_INTERVAL = 0.03,
}

-- helpers
local function readRate()
  local selected = utils.getConfigValue("SpamRateMode"); local mode = (selected == "Auto" or selected == "CPF" or selected == "MS") and selected or "CPS"
  if mode == "Auto" then return mode, 1 end
  local rate = tonumber(utils.getConfigValue(mode)) or 0
  if rate ~= rate or rate <= 0 or rate == math.huge then return mode, 0 end
  if mode == "MS" and 1000 / rate == math.huge then return mode, 0 end
  if mode == "CPF" and rate * 60 == math.huge then return mode, 0 end
  return mode, rate
end

-- state-control
local function transition(active, reason)
  local phase = active and "running" or "stopped"
  if status.phase == phase then return end
  local previous = status.phase; status.phase = phase
  if utils and type(utils.recordTransition) == "function" then utils.recordTransition("Spam", previous, phase, reason) end
end
local function cancel(reason)
  generation += 1; running, currentMode, currentRate = false, nil, nil
  transition(false, reason)
end

-- dispatch
local function request(boundUtils, boundRemote, token, guard, minimum)
  if inFlight then return end
  inFlight = true; status.lastRequestAt = os.clock()
  local ok, result, detail = xpcall(boundRemote.fireParry, traceback, 1, guard); nextAllowedAt = os.clock() + minimum
  inFlight = false; sampleIndex = sampleIndex % 256 + 1
  samples[sampleIndex] = { at = status.lastRequestAt, accepted = ok and result == true }
  if not ok then error(result, 0) end
  if token ~= generation or utils ~= boundUtils then return end
  if result == true then status.lastError = nil; return end
  local message = tostring(detail or "Remote.fireParry indisponível"); status.lastError = message
  local time = os.clock()
  if time - status.lastErrorAt >= 1 then
    status.lastErrorAt = time
    if type(boundUtils.recordError) == "function" then boundUtils.recordError("Spam", message) end
  end
end

-- scheduler
local function sync()
  if not utils or not remote then return end
  local mode, rate = readRate(); local enabled = utils.isActive() and (utils.isManualSpamActive() or utils.isAutoSpamActive()) and rate > 0
  if not enabled then
    if running then cancel("spam_disabled") end
    return
  end
  if running and currentMode == mode and currentRate == rate then return end
  if running then cancel("rate_changed") end
  generation += 1; local token, boundUtils, boundRemote, boundGameInfo = generation, utils, remote, gameInfo
  running, currentMode, currentRate = true, mode, rate; transition(true, "spam_active")
  task.spawn(function()
    local boundAutoSpam = autoSpam
    local function guard() return token == generation and boundUtils.isActive() and (boundUtils.isManualSpamActive() or boundUtils.isAutoSpamActive()) end
    local function allowed() return guard() and (boundUtils.isManualSpamActive() or boundAutoSpam.canSend()) end
    local ok, err = xpcall(function()
      local credit, previous = 0, os.clock()
      while guard() do
        if mode ~= "Auto" then
          task.wait(); local time = os.clock()
          local delta = math.max(0, time - previous); previous = time
          if allowed() then
            credit += mode == "CPF" and rate or (mode == "MS" and 1000 / rate or rate) * delta; local count = math.floor(credit)
            credit = credit - count
            for _ = 1, count do
              if not allowed() then break end
              request(boundUtils, boundRemote, token, allowed, 0)
            end
          else
            credit = 0
          end
        else
          local time = os.clock(); local minimum = boundGameInfo.getMinimumSpamInterval()
          local gameDelay = boundGameInfo.getAutoSpamDelay()
          if inFlight or not allowed() or gameDelay == nil then
            task.wait(CONFIG.POLL_INTERVAL)
          else
            local readyAt = math.max(nextAllowedAt, time)
            if type(gameDelay) == "number" and gameDelay == gameDelay and gameDelay > 0 and gameDelay < math.huge then readyAt = math.max(readyAt, time + gameDelay) end
            if time >= readyAt then request(boundUtils, boundRemote, token, allowed, minimum) else task.wait(math.min(readyAt - time, CONFIG.POLL_INTERVAL)) end
          end
        end
      end
    end, traceback)
    if token ~= generation then return end
    cancel(ok and "spam_disabled" or "spam_error")
    if not ok then
      status.lastError = tostring(err); local time = os.clock()
      if time - status.lastErrorAt >= 1 then
        status.lastErrorAt = time; local reported, reportError = pcall(boundUtils.recordError, "Spam", status.lastError)
        if not reported then warn("[Spam] " .. tostring(reportError)) end
      end
      local retryToken = generation
      task.delay(CONFIG.ERROR_RETRY_INTERVAL, function()
        if retryToken == generation and utils == boundUtils and boundUtils.isActive() then sync() end
      end)
    end
  end)
end

-- lifecycle
function Spam.setup(deps)
  if
    type(deps) ~= "table"
    or type(deps.Utils) ~= "table"
    or type(deps.Remote) ~= "table"
    or type(deps.GameInfo) ~= "table"
    or type(deps.AutoSpam) ~= "table"
    or type(deps.AutoSpam.canSend) ~= "function"
    or type(deps.GameInfo.getAutoSpamDelay) ~= "function"
    or type(deps.GameInfo.getMinimumSpamInterval) ~= "function"
    or type(deps.Remote.fireParry) ~= "function"
    or type(deps.Utils.getConfigValue) ~= "function"
    or type(deps.Utils.isActive) ~= "function"
    or type(deps.Utils.isManualSpamActive) ~= "function"
    or type(deps.Utils.isAutoSpamActive) ~= "function"
    or type(deps.Utils.observeSpam) ~= "function"
    or type(deps.Utils.observeConfig) ~= "function"
  then
    return false, "dependência ausente: Remote ou Utils"
  end
  Spam.teardown(); utils, remote, gameInfo, autoSpam = deps.Utils, deps.Remote, deps.GameInfo, deps.AutoSpam
  spamObserver = utils.observeSpam(sync)
  configObserver = utils.observeConfig(function(changes)
    if changes.SpamRateMode ~= nil or changes.CPS ~= nil or changes.CPF ~= nil or changes.MS ~= nil then sync() end
  end)
  utils.trackGlobal(spamObserver); utils.trackGlobal(configObserver)
  sync(); return true
end
function Spam.resetState()
  cancel("reset"); status.lastError, status.lastErrorAt = nil, -math.huge
  table.clear(samples); sampleIndex = 0
  local token = generation
  task.defer(function()
    if token == generation then sync() end
  end)
end
function Spam.teardown()
  cancel("teardown"); table.clear(samples)
  sampleIndex = 0
  if utils then
    if spamObserver then utils.untrackGlobal(spamObserver); spamObserver:Disconnect() end
    if configObserver then utils.untrackGlobal(configObserver); configObserver:Disconnect() end
  end
  spamObserver, configObserver, utils, remote, gameInfo, autoSpam = nil, nil, nil, nil, nil, nil
end

-- public-api
function Spam.getStatus()
  local now, attempts, accepted = os.clock(), 0, 0
  for _, sample in pairs(samples) do
    if now >= sample.at and now - sample.at < 1 then
      attempts += 1
      if sample.accepted then accepted += 1 end
    end
  end
  return {
    schema = utils and utils.apiVersion() or 1,
    phase = status.phase,
    lastRequestAt = status.lastRequestAt,
    lastError = status.lastError,
    attemptsLastSecond = attempts,
    acceptedLastSecond = accepted,
    cpfFps = 0,
    cpfClicks = 0,
    cpfCompensation = false,
  }
end

-- contract
Spam.__contract = {
  requires = {
    Remote = "remote",
    Utils = "utils",
    GameInfo = "gameinfo",
    AutoSpam = "autospam",
  },
  requiresMethods = {
    Remote = { "fireParry" },
    AutoSpam = { "canSend" },
    GameInfo = { "getAutoSpamDelay", "getMinimumSpamInterval" },
    Utils = {
      "apiVersion",
      "getConfigValue",
      "isActive",
      "isManualSpamActive",
      "isAutoSpamActive",
      "observeSpam",
      "observeConfig",
      "trackGlobal",
      "untrackGlobal",
      "recordError",
      "recordTransition",
    },
  },
  provides = { "setup", "resetState", "teardown", "getStatus" },
}

return Spam
