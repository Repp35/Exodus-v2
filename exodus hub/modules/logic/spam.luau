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

-- helpers
local function invalidate()
    generation = generation + 1
    pendingClicks = 0
end

local function isActive()
    return Utils.isActive() and Utils.isSpamActive()
end

local function requestParry()
    pcall(Remote.fireParry, 1)
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
        return
    end

    local active = isActive()

    if not active then
        if wasActive then
            invalidate()
        end

        wasActive = false
        return
    end

    wasActive = true

    if type(dt) ~= "number" or dt <= 0 then
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
    pendingClicks = pendingClicks + increment

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
        or type(deps.Utils.isSpamActive) ~= "function"
        or type(deps.Utils.getConfig) ~= "function"
        or type(deps.Utils.normalizeSpamRate) ~= "function"
        or type(deps.Utils.setConfig) ~= "function"
        or type(deps.Utils.getRunService) ~= "function"
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
    invalidate()
    resetRateState()
    wasActive = false
end

return Spam
