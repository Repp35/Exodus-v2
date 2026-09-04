-- [[ spam ]]

local Spam = {}
local Remote
local Utils
local pcall = pcall
local math_max = math.max
local now = os.clock

-- state
local heartbeatConnection
local generation = 0
local wasActive = false
local acumulador = 0
local cpfFps
local cpfCredits = 0
local cpfSent = 0
local cpfFracCarry = 0
local lastMode
local lastRate
local chainRunning = false
local EMA = 0.08
-- distribution tweaks
local JITTER_MIN = 0.85
local JITTER_RANGE = 0.30
local Scheduler = {
    phase = "stopped",
    lastRequestAt = 0,
    lastError = nil,
}

-- helpers
local function invalidate(reason)
    generation = generation + 1
    Scheduler.phase = "stopped"
    acumulador = 0
    cpfFps = nil
    cpfCredits = 0
    cpfSent = 0
    cpfFracCarry = 0
    lastMode = nil
    lastRate = nil
    chainRunning = false
    if Utils and type(Utils.recordTransition) == "function" and wasActive then
        Utils.recordTransition("Spam", "running", "stopped", reason or "invalidated")
    end
end

local function isActive()
    return Utils.isActive and Utils.isSpamActive and Utils.isActive() and Utils.isSpamActive()
end

local function requestParry()
    local ok, result = pcall(Remote.fireParry, 1)
    Scheduler.lastRequestAt = Utils.now and Utils.now() or now()
    if not ok or result == false then
        Scheduler.lastError = not ok and tostring(result) or "Remote.fireParry retornou false"
        if type(Utils.recordError) == "function" then
            Utils.recordError("Spam", Scheduler.lastError)
        end
        return false
    end
    Scheduler.lastError = nil
    return true
end

local function scheduleCPF(rate, dt)
    if rate <= 0 then
        return
    end
    local fpsNow = 1 / dt
    if not cpfFps then
        cpfFps = fpsNow
    else
        cpfFps = cpfFps + (fpsNow - cpfFps) * EMA
    end
    local fps = math_max(cpfFps, 1)
    local clicks = rate * math_max(60, fps) / fps + cpfFracCarry
    cpfFracCarry = clicks - math.floor(clicks)
    local scheduled = math.floor(clicks)
    if scheduled <= 0 then
        return
    end
    local batched = 0
    task.spawn(function()
        for _ = 1, scheduled do
            requestParry()
            batched = batched + 1
        end
    end)
end

local function scheduleChain()
    if not isActive() then
        chainRunning = false
        return
    end

    local currentGeneration = generation

    requestParry()

    if currentGeneration ~= generation or not isActive() then
        chainRunning = false
        return
    end

    task.spawn(scheduleChain)
end

-- runtime
local function tick(dt)
    if typeof(dt) ~= "number" or dt <= 0 or dt ~= dt or dt == math.huge then
        return
    end

    if not isActive() then
        if wasActive then
            invalidate("spam_disabled")
        end
        wasActive = false
        return
    end

    local config = Utils.getConfig and Utils.getConfig()
    local configuredMode = type(config) == "table" and config.SpamRateMode
    local mode

    if configuredMode == "CPF" then
        mode = "CPF"
    elseif configuredMode == "CHAIN" then
        mode = "CHAIN"
    else
        mode = "CPS"
    end

    local rateKey = mode == "CPF" and "CPF" or "CPS"
    local rate = type(config) == "table" and tonumber(config[rateKey]) or nil
    rate = math_max(rate or 1, 0)

    if not wasActive then
        Scheduler.phase = "running"
        if type(Utils.recordTransition) == "function" then
            Utils.recordTransition("Spam", "stopped", "running", "spam_enabled")
        end
    end

    wasActive = true

    if mode == "CHAIN" then
        if not chainRunning then
            chainRunning = true
            task.spawn(scheduleChain)
        end
        return
    end

    if mode ~= lastMode then
        lastMode = mode
        acumulador = 0
        lastRate = nil
        cpfCredits = 0
        cpfSent = 0
    end

    if rate ~= lastRate then
        lastRate = rate
        if mode == "CPF" then
            cpfCredits = 0
            cpfSent = 0
        else
            acumulador = 0
        end
    end

    if mode == "CPF" then
        scheduleCPF(rate, dt)
        return
    end

    local intervaloEntreClicks = 1 / math_max(rate, 1)
    acumulador = acumulador + dt
    local currentGeneration = generation

    local scheduled = 0
    while acumulador >= intervaloEntreClicks do
        if currentGeneration ~= generation or not isActive() then
            break
        end
        scheduled = scheduled + 1
        local jitter = JITTER_MIN + JITTER_RANGE * math.random()
        acumulador = acumulador - intervaloEntreClicks * jitter
    end

    if scheduled > 0 then
        task.spawn(function()
            for _ = 1, scheduled do
                if currentGeneration ~= generation or not isActive() then
                    return
                end
                requestParry()
            end
        end)
    end
end

-- setup
function Spam.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Remote) ~= "table"
        or type(deps.Remote.fireParry) ~= "function"
        or type(deps.Utils) ~= "table"
    then
        return false, "dependência ausente: Remote.fireParry ou Utils"
    end

    if heartbeatConnection then
        pcall(heartbeatConnection.Disconnect, heartbeatConnection)
        if type(deps.Utils.untrackGlobal) == "function" then
            pcall(deps.Utils.untrackGlobal, heartbeatConnection)
        end
        heartbeatConnection = nil
    end

    Remote = deps.Remote
    Utils = deps.Utils
    Spam.resetState()

    local RunService = Utils.getRunService and Utils.getRunService() or game:GetService("RunService")
    local signal = RunService.RenderStepped or RunService.Heartbeat

    heartbeatConnection = signal:Connect(tick)

    if type(Utils.trackGlobal) == "function" then
        Utils.trackGlobal(heartbeatConnection)
    end

    return true
end

-- lifecycle
function Spam.resetState()
    invalidate("reset")
    wasActive = false
    acumulador = 0
    cpfFps = nil
    cpfCredits = 0
    cpfSent = 0
    cpfFracCarry = 0
    lastMode = nil
    lastRate = nil
    chainRunning = false
    Scheduler.phase = "stopped"
    Scheduler.lastRequestAt = 0
    Scheduler.lastError = nil
end

function Spam.getStatus()
    return {
        schema = Utils.apiVersion and Utils.apiVersion() or 1,
        phase = Scheduler.phase == "running" and "running" or "stopped",
        lastRequestAt = Scheduler.lastRequestAt,
        lastError = Scheduler.lastError,
    }
end

Spam.__contract = {
    requires = {
        Remote = "remote",
        Utils = "utils",
    },
}

return Spam