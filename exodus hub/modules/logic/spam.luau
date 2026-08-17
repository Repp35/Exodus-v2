-- [[ Spam ]]

local Spam = {}
local Remote
local Utils

-- tuning
local RATE_EPSILON = 1e-7
local MAX_SCHEDULED_PER_TICK = 256

-- state
local heartbeatConnection
local generation = 0
local pendingClicks = 0
local lastMode
local lastRate
local wasActive = false
local Scheduler = {
    phase = "stopped",
    lastRequestAt = 0,
    lastError = nil,
}

-- helpers
local function invalidate(reason)
    generation = generation + 1
    pendingClicks = 0
    Scheduler.phase = "stopped"
    if Utils and type(Utils.recordTransition) == "function" and wasActive then
        Utils.recordTransition("Spam", "running", "stopped", reason or "invalidated")
    end
end
local function isActive()
    return Utils.isActive() and Utils.isSpamActive()
end
local function requestParry()
    local ok, result = pcall(Remote.fireParry, 1)
    Scheduler.lastRequestAt = Utils.now()
    if not ok then
        Scheduler.lastError = tostring(result)
        if type(Utils.recordError) == "function" then
            Utils.recordError("Spam", result)
        end
        return false
    end
    if result == false then
        Scheduler.lastError = "Remote.fireParry retornou false"
        if type(Utils.recordError) == "function" then
            Utils.recordError("Spam", Scheduler.lastError)
        end
        return false
    end
    Scheduler.lastError = nil
    return true
end
local function schedule(clicks, dt, currentGeneration)
    if clicks <= 0 then
        return
    end
    local spacing = dt / clicks
    for index = 1, clicks do
        local delay = spacing * (index - 0.5)
        task.delay(delay, function()
            if currentGeneration == generation and isActive() then
                requestParry()
            end
        end)
    end
end
local function resetRateState()
    pendingClicks = 0
    lastMode = nil
    lastRate = nil
end

-- runtime
local function tick(dt)
    local config = Utils.getConfig()
    if type(config) ~= "table" then
        if type(Utils.recordError) == "function" then
            Utils.recordError("Spam", "configuração indisponível")
        end
        return
    end
    local active = isActive()
    if not active then
        if wasActive then
            invalidate("spam_disabled")
        end
        wasActive = false
        return
    end
    if not wasActive then
        Scheduler.phase = "running"
        if type(Utils.recordTransition) == "function" then
            Utils.recordTransition("Spam", "stopped", "running", "spam_enabled")
        end
    end
    wasActive = true
    if type(dt) ~= "number"
        or dt ~= dt
        or dt == math.huge
        or dt == -math.huge
        or dt <= 0
    then
        return
    end
    local mode = config.SpamRateMode == "CPS" and "CPS" or "CPF"
    local fallback = mode == "CPS" and 4 or 16
    local rateKey = mode
    local rate = Utils.normalizeSpamRate(config[rateKey], fallback)
    if config[rateKey] ~= rate then
        Utils.setConfig({ [rateKey] = rate })
    end
    if mode ~= lastMode or rate ~= lastRate then
        resetRateState()
        lastMode = mode
        lastRate = rate
    end
    local increment = mode == "CPS" and rate * dt or rate
    pendingClicks = math.min(
        pendingClicks + increment,
        MAX_SCHEDULED_PER_TICK
    )
    local clicks = math.floor(pendingClicks + RATE_EPSILON)
    if clicks <= 0 then
        return
    end
    clicks = math.min(clicks, MAX_SCHEDULED_PER_TICK)
    pendingClicks = math.max(pendingClicks - clicks, 0)
    schedule(clicks, dt, generation)
end

-- setup
function Spam.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Remote) ~= "table"
        or type(deps.Remote.fireParry) ~= "function"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.apiVersion) ~= "function"
        or type(deps.Utils.isSpamActive) ~= "function"
        or type(deps.Utils.getConfig) ~= "function"
        or type(deps.Utils.normalizeSpamRate) ~= "function"
        or type(deps.Utils.setConfig) ~= "function"
        or type(deps.Utils.getRunService) ~= "function"
        or type(deps.Utils.now) ~= "function"
        or type(deps.Utils.recordTransition) ~= "function"
        or type(deps.Utils.recordError) ~= "function"
        or type(deps.Utils.trackGlobal) ~= "function"
        or type(deps.Utils.untrackGlobal) ~= "function"
    then
        return false
    end
    if heartbeatConnection then
        pcall(heartbeatConnection.Disconnect, heartbeatConnection)
        deps.Utils.untrackGlobal(heartbeatConnection)
        heartbeatConnection = nil
    end
    Remote = deps.Remote
    Utils = deps.Utils
    Spam.resetState()
    heartbeatConnection = Utils.getRunService().Heartbeat:Connect(tick)
    Utils.trackGlobal(heartbeatConnection)
    return true
end

-- lifecycle
function Spam.resetState()
    invalidate("reset")
    resetRateState()
    wasActive = false
    Scheduler.phase = "stopped"
    Scheduler.lastRequestAt = 0
    Scheduler.lastError = nil
end
function Spam.getStatus()
    return {
        schema = Utils.apiVersion(),
        phase = Scheduler.phase == "running" and "running" or "stopped",
        lastRequestAt = Scheduler.lastRequestAt,
        lastError = Scheduler.lastError,
    }
end

return Spam
