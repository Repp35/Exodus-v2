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
local pendingRequests = 0
local dispatching = false
local lastMode
local lastRate
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
    pendingRequests = 0
    lastMode = nil
    lastRate = nil
    if Utils and type(Utils.recordTransition) == "function" and wasActive then
        Utils.recordTransition("Spam", "running", "stopped", reason or "invalidated")
    end
end
local function isActive()
    return Utils.isActive and Utils.isSpamActive and Utils.isActive() and Utils.isSpamActive()
end
local function requestParry()
    if not isActive() then
        return false
    end
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
    acumulador = acumulador + rate * dt
    local scheduled = math.floor(acumulador)
    acumulador = acumulador - scheduled
    pendingRequests = pendingRequests + scheduled
end
local function dispatchPending(currentGeneration)
    if dispatching then
        return
    end
    if pendingRequests > 0 then
        if currentGeneration ~= generation or not isActive() then
            pendingRequests = 0
            return
        end
        pendingRequests = pendingRequests - 1
        requestParry()
    end
    if pendingRequests <= 0 then
        return
    end
    dispatching = true
    task.spawn(function()
        local processed = 0
        while pendingRequests > 0 do
            if currentGeneration ~= generation or not isActive() then
                pendingRequests = 0
                break
            end
            pendingRequests = pendingRequests - 1
            requestParry()
            processed = processed + 1
            if processed >= 64 then
                processed = 0
                task.wait()
            end
        end
        dispatching = false
    end)
end

-- runtime
local function tick(dt)
    if typeof(dt) ~= "number" or dt <= 0 or dt ~= dt or dt == math.huge then
        return
    end
    if not isActive() then
        if wasActive then invalidate("spam_disabled") end
        wasActive = false
        return
    end
    if not wasActive then
        Scheduler.phase = "running"
        pendingRequests = pendingRequests + 1
        if type(Utils.recordTransition) == "function" then
            Utils.recordTransition("Spam", "stopped", "running", "spam_enabled")
        end
    end
    wasActive = true
    local config = Utils.getConfig and Utils.getConfig()
    local mode = type(config) == "table" and config.SpamRateMode == "CPF" and "CPF" or "CPS"
    local rateKey = mode == "CPF" and "CPF" or "CPS"
    local rate = type(config) == "table" and tonumber(config[rateKey]) or nil
    rate = math_max(rate or 0, 0)
    if mode ~= lastMode then
        lastMode = mode
        acumulador = 0
        pendingRequests = 0
        lastRate = nil
    end
    if mode == "CPF" then
        if rate ~= lastRate then
            lastRate = rate
            acumulador = 0
            pendingRequests = 0
        end
        scheduleCPF(rate, dt)
        dispatchPending(generation)
        return
    end
    if rate ~= lastRate then
        lastRate = rate
        acumulador = 0
        pendingRequests = 0
    end
    if rate <= 0 then
        return
    end
    local intervaloEntreClicks = 1 / math_max(rate, 1)
    acumulador = acumulador + dt
    while acumulador >= intervaloEntreClicks do
        acumulador = acumulador - intervaloEntreClicks
        pendingRequests = pendingRequests + 1
    end
    dispatchPending(generation)
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
    pendingRequests = 0
    lastMode = nil
    lastRate = nil
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
