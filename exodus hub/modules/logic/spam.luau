-- [[ spam ]]

local Spam = {}
local Utils, Remote
local frameConnection, spamObserver
local generation, workerGeneration = 0, 0
local workerRunning = false
local active, phase = false, 0
local lastMode, lastRate
local status = {
    phase = "stopped",
    lastRequestAt = 0,
    lastError = nil,
    lastErrorAt = -math.huge,
    cpfFps = 0,
    cpfClicks = 0,
    cpfCompensation = false,
}

local function now()
    return Utils and Utils.now() or os.clock()
end

local function configValue(key)
    if type(Utils.getConfigValue) == "function" then return Utils.getConfigValue(key) end
    return Utils.getConfig()[key]
end

local function validRate(rate)
    rate = tonumber(rate)
    if not rate or rate ~= rate or rate == math.huge or rate < 0 then return 0 end
    return rate
end

local function setActive(value, reason)
    if active == value then return end
    local before = active and "running" or "stopped"
    active = value
    generation += 1
    phase = 0
    lastMode, lastRate = nil, nil
    status.phase = value and "running" or "stopped"
    if type(Utils.recordTransition) == "function" then
        Utils.recordTransition("Spam", before, status.phase, reason)
    end
end

local function requestParry()
    local time = now()
    status.lastRequestAt = time
    local ok, sent, detail = pcall(Remote.fireParry, 1)
    if ok and sent == true then
        status.lastError = nil
        return
    end

    local message = tostring(ok and (detail or "Remote.fireParry indisponível") or sent)
    status.lastError = message
    if time - status.lastErrorAt >= 1 then
        status.lastErrorAt = time
        if type(Utils.recordError) == "function" then Utils.recordError("Spam", message) end
    end
end

local function sendScheduled(token)
    if token == generation and Utils and Remote and Utils.isActive() and Utils.isSpamActive() then
        requestParry()
    end
end

local function updateMode(mode, rate)
    if lastMode == mode and lastRate == rate then return end
    generation += 1
    phase = 0
    lastMode, lastRate = mode, rate
end

local function frame(dt)
    if type(dt) ~= "number" or dt ~= dt or dt <= 0 or dt == math.huge then return end
    if configValue("SpamRateMode") == "CPF" then return end
    if not Utils.isActive() or not Utils.isSpamActive() then
        setActive(false, "spam_disabled")
        return
    end

    setActive(true, "spam_active")
    local rate = validRate(configValue("CPS"))
    updateMode("CPS", rate)
    status.cpfFps, status.cpfClicks = 0, 0

    if rate == 0 then return end
    phase += rate * dt
    local clicks = math.floor(phase + 1e-9)
    phase -= clicks
    if clicks == 0 then return end

    requestParry()
    local token = generation
    for i = 2, clicks do
        task.delay(dt * (i - 1) / clicks, sendScheduled, token)
    end
end

local function startWorker()
    if workerRunning then return end
    workerGeneration += 1
    local token = workerGeneration
    workerRunning = true

    task.spawn(function()
        local due, previousRate
        while token == workerGeneration do
            local mode = configValue("SpamRateMode")
            local rate = validRate(configValue("CPF"))
            local enabled = mode == "CPF" and Utils.isActive() and Utils.isSpamActive() and rate > 0

            if enabled then
                setActive(true, "spam_active")
                if lastMode ~= "CPF" or lastRate ~= rate then
                    updateMode("CPF", rate)
                    due, previousRate = nil, nil
                end

                local time = now()
                local interval = 1 / (rate * 60)
                if due == nil or previousRate ~= rate then
                    due = time + interval
                    previousRate = rate
                end

                if time >= due then
                    requestParry()
                    due += interval
                    if due <= time then due = time + interval end
                end
            else
                due, previousRate = nil, nil
                if mode == "CPF" then setActive(false, "spam_disabled") end
            end

            if due then task.wait(math.max(0, due - now())) else task.wait() end
        end
        if token == workerGeneration then workerRunning = false end
    end)
end

local function stopWorker()
    workerGeneration += 1
    workerRunning = false
end

local function syncWorker()
    if not Utils then return end
    local rate = validRate(configValue("CPF"))
    local enabled = configValue("SpamRateMode") == "CPF"
        and rate > 0 and Utils.isActive() and Utils.isSpamActive()

    if enabled then
        startWorker()
    else
        if workerRunning then stopWorker() end
        if configValue("SpamRateMode") == "CPF" then
            setActive(false, "spam_disabled")
        end
    end
end

function Spam.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Remote) ~= "table"
        or type(deps.Remote.fireParry) ~= "function"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.getRunService) ~= "function"
        or type(deps.Utils.getConfig) ~= "function"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.isSpamActive) ~= "function"
        or type(deps.Utils.now) ~= "function" then
        return false, "dependência ausente: Remote ou Utils"
    end

    Spam.teardown()
    Utils, Remote = deps.Utils, deps.Remote
    local runService = Utils.getRunService()
    local signal = runService and (runService.RenderStepped or runService.Heartbeat)
    if not signal then return false, "RunService indisponível" end

    frameConnection = signal:Connect(frame)
    if type(Utils.trackGlobal) == "function" then Utils.trackGlobal(frameConnection) end

    if type(Utils.observeSpam) == "function" then
        spamObserver = Utils.observeSpam(syncWorker)
        if type(Utils.trackGlobal) == "function" then Utils.trackGlobal(spamObserver) end
        syncWorker()
    else
        startWorker()
    end
    return true
end

function Spam.resetState()
    generation += 1
    setActive(false, "reset")
    phase, lastMode, lastRate = 0, nil, nil
    status.phase = "stopped"
    status.lastRequestAt = 0
    status.lastError = nil
    status.lastErrorAt = -math.huge
    status.cpfFps, status.cpfClicks = 0, 0
end

function Spam.teardown()
    stopWorker()
    for _, connection in ipairs({spamObserver, frameConnection}) do
        if Utils and type(Utils.untrackGlobal) == "function" then Utils.untrackGlobal(connection) end
        connection:Disconnect()
    end
    spamObserver, frameConnection = nil, nil
    Spam.resetState()
    Utils, Remote = nil, nil
end

function Spam.getStatus()
    return {
        schema = Utils and type(Utils.apiVersion) == "function" and Utils.apiVersion() or 1,
        phase = status.phase,
        lastRequestAt = status.lastRequestAt,
        lastError = status.lastError,
        cpfFps = status.cpfFps,
        cpfClicks = status.cpfClicks,
        cpfCompensation = false,
    }
end

Spam.__contract = {
    requires = {Remote = "remote", Utils = "utils"},
    requiresMethods = {
        Remote = {"fireParry"},
        Utils = {"getRunService", "getConfig", "isActive", "isSpamActive", "now"},
    },
    provides = {"setup", "resetState", "teardown", "getStatus"},
}

return Spam
