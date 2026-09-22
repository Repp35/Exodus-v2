-- [[ spam ]]

local Spam = {}
local Remote, GameInfo, Utils

local math_max = math.max
local math_floor = math.floor
local clock = os.clock

-- tuning
local DEFLECT_COOLDOWN_THRESHOLD = 0
local CPF_REFERENCE_FPS = 60
local CPF_COMPENSATION_ENABLED = true
local CPF_MAX_CATCHUP_CLICKS = 4
local CPF_MIN_INTERVAL = 0.0005
local CPF_MAX_INTERVAL = 0.25

-- state
local heartbeatConnection
local generation = 0
local wasActive = false
local accumulator = 0
local cpfFps
local lastMode
local lastRate
local lastCompensation
local chainRunning = false

-- click scheduler
local clickQueue = 0
local clickAccumulator = 0
local clickInterval = 0

-- CPF scheduler
local cpfClickAccumulator = 0
local cpfTimeAccumulator = 0
local cpfLastDt = 0

local Scheduler = {
    phase = "stopped",
    lastRequestAt = 0,
    lastError = nil,
    lastCooldownAt = 0,
    lastCooldownValue = 0,
    lastErrorAt = 0,
    cpfFps = 0,
    cpfClicks = 0,
    cpfCompensation = false,
}

-- helpers
local function getNow()
    if Utils and type(Utils.now) == "function" then
        return Utils.now()
    end

    return clock()
end

local function resetRuntime()
    accumulator = 0
    cpfFps = nil
    lastMode = nil
    lastRate = nil
    lastCompensation = nil
    chainRunning = false

    clickQueue = 0
    clickAccumulator = 0
    clickInterval = 0

    cpfClickAccumulator = 0
    cpfTimeAccumulator = 0
    cpfLastDt = 0

    Scheduler.cpfFps = 0
    Scheduler.cpfClicks = 0
    Scheduler.cpfCompensation = false
end

local function invalidate(reason)
    generation = generation + 1
    Scheduler.phase = "stopped"

    resetRuntime()

    if wasActive
        and Utils
        and type(Utils.recordTransition) == "function"
    then
        Utils.recordTransition(
            "Spam",
            "running",
            "stopped",
            reason or "invalidated"
        )
    end
end

local function isActive()
    if not Utils
        or type(Utils.isActive) ~= "function"
        or type(Utils.isSpamActive) ~= "function"
    then
        return false
    end

    return Utils.isActive() and Utils.isSpamActive()
end

local function readDeflectCooldown()
    if not GameInfo
        or type(GameInfo.getDeflectCD) ~= "function"
    then
        return nil
    end

    local ok, value = pcall(GameInfo.getDeflectCD)

    if not ok
        or type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
    then
        return nil
    end

    return value
end

local function requestParry()
    local ok, result = pcall(Remote.fireParry, 1)
    local timestamp = getNow()

    Scheduler.lastRequestAt = timestamp

    if ok and result ~= false then
        Scheduler.lastError = nil
        return true
    end

    local errorMessage

    if not ok then
        errorMessage = tostring(result)
    else
        errorMessage = "Remote.fireParry retornou false"
    end

    Scheduler.lastError = errorMessage

    if timestamp - Scheduler.lastErrorAt >= 1 then
        Scheduler.lastErrorAt = timestamp

        if Utils
            and type(Utils.recordError) == "function"
        then
            Utils.recordError("Spam", errorMessage)
        end
    end

    return false
end

-- CLICK SCHEDULER
local function queueClicks(clicks, interval)
    if clicks <= 0 then
        return
    end

    clickQueue = clickQueue + clicks

    if interval > 0 then
        clickInterval = interval
    end
end

local function processClickQueue(dt)
    if clickQueue <= 0 then
        clickAccumulator = 0
        return
    end

    if clickInterval <= 0 then
        local currentGeneration = generation

        while clickQueue > 0 do
            if currentGeneration ~= generation
                or not isActive()
            then
                clickQueue = 0
                clickAccumulator = 0
                return
            end

            requestParry()
            clickQueue = clickQueue - 1
        end

        clickAccumulator = 0
        return
    end

    clickAccumulator = clickAccumulator + dt

    local currentGeneration = generation

    while clickQueue > 0
        and clickAccumulator >= clickInterval
    do
        if currentGeneration ~= generation
            or not isActive()
        then
            clickQueue = 0
            clickAccumulator = 0
            return
        end

        clickAccumulator = clickAccumulator - clickInterval
        clickQueue = clickQueue - 1

        requestParry()
    end

    if clickQueue <= 0
        and clickAccumulator > clickInterval
    then
        clickAccumulator = clickInterval
    end
end

-- CPF
local function scheduleCPF(rate, dt, compensation)
    if rate <= 0 then
        Scheduler.cpfClicks = 0
        cpfClickAccumulator = 0
        cpfTimeAccumulator = 0
        clickQueue = 0
        clickAccumulator = 0
        return
    end

    local fpsNow = 1 / dt

    if fpsNow < 1 then
        fpsNow = 1
    end

    cpfFps = fpsNow
    Scheduler.cpfFps = fpsNow
    Scheduler.cpfCompensation = compensation == true

    local effectiveRate = rate

    if compensation then
        local fpsRatio = fpsNow / CPF_REFERENCE_FPS

        if fpsRatio > 0 then
            effectiveRate = rate * fpsRatio
        end
    end

    if effectiveRate < 0 then
        effectiveRate = 0
    end

    local interval = 1 / effectiveRate

    if interval < CPF_MIN_INTERVAL then
        interval = CPF_MIN_INTERVAL
    elseif interval > CPF_MAX_INTERVAL then
        interval = CPF_MAX_INTERVAL
    end

    clickInterval = interval

    cpfTimeAccumulator = cpfTimeAccumulator + dt

    local desiredClicks = cpfTimeAccumulator / interval

    if desiredClicks >= 1 then
        local wholeClicks = math_floor(desiredClicks)

        if wholeClicks > CPF_MAX_CATCHUP_CLICKS then
            wholeClicks = CPF_MAX_CATCHUP_CLICKS
        end

        cpfTimeAccumulator = cpfTimeAccumulator - (wholeClicks * interval)

        if cpfTimeAccumulator < 0 then
            cpfTimeAccumulator = 0
        end

        cpfClickAccumulator = cpfClickAccumulator + wholeClicks
    end

    local clicksToQueue = math_floor(cpfClickAccumulator)

    if clicksToQueue > 0 then
        cpfClickAccumulator = cpfClickAccumulator - clicksToQueue

        queueClicks(
            clicksToQueue,
            interval
        )
    end

    Scheduler.cpfClicks = clicksToQueue
    cpfLastDt = dt
end

-- CHAIN
local function scheduleChain()
    local currentGeneration = generation

    while currentGeneration == generation
        and isActive()
    do
        requestParry()
        task.wait()
    end

    chainRunning = false
end

-- CONFIG
local function getModeAndRate()
    local config

    if Utils and type(Utils.getConfig) == "function" then
        config = Utils.getConfig()
    end

    if type(config) ~= "table" then
        return "CPS", 1, CPF_COMPENSATION_ENABLED
    end

    local configuredMode = config.SpamRateMode
    local mode

    if configuredMode == "CPF" then
        mode = "CPF"
    elseif configuredMode == "CHAIN" then
        mode = "CHAIN"
    else
        mode = "CPS"
    end

    local rateKey = mode == "CPF" and "CPF" or "CPS"
    local rate = tonumber(config[rateKey]) or 1

    local compensation = CPF_COMPENSATION_ENABLED

    if config.CPFCompensation ~= nil then
        compensation = config.CPFCompensation == true
    end

    return mode, math_max(rate, 0), compensation
end

-- RUNTIME
local function tick(dt)
    if type(dt) ~= "number"
        or dt <= 0
        or dt ~= dt
        or dt == math.huge
        or dt == -math.huge
    then
        return
    end

    if not isActive() then
        if wasActive then
            invalidate("spam_disabled")
        end

        wasActive = false
        return
    end

    local deflectCd = readDeflectCooldown()

    if deflectCd ~= nil then
        Scheduler.lastCooldownAt = clock()
        Scheduler.lastCooldownValue = deflectCd

        if deflectCd > DEFLECT_COOLDOWN_THRESHOLD then
            if wasActive then
                invalidate("deflect_cooldown")

                if Utils
                    and type(Utils.recordError) == "function"
                then
                    Utils.recordError(
                        "Spam",
                        string.format(
                            "deflect cooldown ativo (%.3fs) — spam desligado",
                            deflectCd
                        )
                    )
                end
            end

            wasActive = false
            Scheduler.phase = "cooldown"
            return
        end
    end

    local mode, rate, compensation = getModeAndRate()

    if not wasActive then
        Scheduler.phase = "running"

        if Utils
            and type(Utils.recordTransition) == "function"
        then
            Utils.recordTransition(
                "Spam",
                "stopped",
                "running",
                "spam_active"
            )
        end
    end

    wasActive = true

    -- CHAIN
    if mode == "CHAIN" then
        if not chainRunning then
            chainRunning = true
            task.spawn(scheduleChain)
        end

        return
    end

    -- MODE CHANGE
    if mode ~= lastMode then
        lastMode = mode
        lastRate = nil
        lastCompensation = nil

        accumulator = 0
        cpfFps = nil

        clickQueue = 0
        clickAccumulator = 0
        clickInterval = 0

        cpfClickAccumulator = 0
        cpfTimeAccumulator = 0
        cpfLastDt = 0
    end

    -- RATE CHANGE
    if rate ~= lastRate then
        lastRate = rate

        if mode == "CPF" then
            cpfFps = nil
            cpfClickAccumulator = 0
            cpfTimeAccumulator = 0
            cpfLastDt = 0
        else
            accumulator = 0
        end

        clickQueue = 0
        clickAccumulator = 0
        clickInterval = 0
    end

    -- CPF COMPENSATION CHANGE
    if compensation ~= lastCompensation then
        lastCompensation = compensation

        cpfFps = nil
        cpfClickAccumulator = 0
        cpfTimeAccumulator = 0
        cpfLastDt = 0

        clickQueue = 0
        clickAccumulator = 0
        clickInterval = 0
    end

    -- CPF
    if mode == "CPF" then
        scheduleCPF(
            rate,
            dt,
            compensation
        )

        processClickQueue(dt)
        return
    end

    -- CPS
    if rate <= 0 then
        accumulator = 0
        clickQueue = 0
        clickAccumulator = 0
        clickInterval = 0
        return
    end

    local interval = 1 / rate

    accumulator = accumulator + dt

    local currentGeneration = generation

    if accumulator >= interval then
        local clicks = math_floor(
            accumulator / interval
        )

        accumulator = accumulator - (
            clicks * interval
        )

        if accumulator < 0 then
            accumulator = 0
        end

        if currentGeneration ~= generation
            or not isActive()
        then
            return
        end

        queueClicks(
            clicks,
            interval
        )
    end

    processClickQueue(dt)
end

-- SETUP
function Spam.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Remote) ~= "table"
        or type(deps.Remote.fireParry) ~= "function"
        or type(deps.Utils) ~= "table"
    then
        return false, "dependência ausente: Remote.fireParry ou Utils"
    end

    if heartbeatConnection then
        pcall(
            heartbeatConnection.Disconnect,
            heartbeatConnection
        )

        if Utils
            and type(Utils.untrackGlobal) == "function"
        then
            pcall(
                Utils.untrackGlobal,
                heartbeatConnection
            )
        end

        heartbeatConnection = nil
    end

    Remote = deps.Remote
    Utils = deps.Utils

    GameInfo =
        type(deps.GameInfo) == "table"
        and deps.GameInfo
        or nil

    if not GameInfo then
        return false, "dependência ausente: GameInfo"
    end

    Spam.resetState()

    local RunService

    if type(Utils.getRunService) == "function" then
        RunService = Utils.getRunService()
    end

    if not RunService then
        RunService = game:GetService("RunService")
    end

    local signal =
        RunService.RenderStepped
        or RunService.Heartbeat

    heartbeatConnection = signal:Connect(tick)

    if type(Utils.trackGlobal) == "function" then
        Utils.trackGlobal(heartbeatConnection)
    end

    return true
end

-- LIFECYCLE
function Spam.resetState()
    invalidate("reset")

    wasActive = false

    Scheduler.phase = "stopped"
    Scheduler.lastRequestAt = 0
    Scheduler.lastError = nil
    Scheduler.lastCooldownAt = 0
    Scheduler.lastCooldownValue = 0
    Scheduler.lastErrorAt = 0
    Scheduler.cpfFps = 0
    Scheduler.cpfClicks = 0
    Scheduler.cpfCompensation = false
end

function Spam.getStatus()
    return {
        schema =
            Utils
            and type(Utils.apiVersion) == "function"
            and Utils.apiVersion()
            or 1,

        phase = Scheduler.phase,
        lastRequestAt = Scheduler.lastRequestAt,
        lastError = Scheduler.lastError,
        lastCooldownAt = Scheduler.lastCooldownAt,
        lastCooldownValue = Scheduler.lastCooldownValue,

        cpfFps = Scheduler.cpfFps,
        cpfClicks = Scheduler.cpfClicks,
        cpfCompensation = Scheduler.cpfCompensation,
    }
end

Spam.__contract = {
    requires = {
        Remote = "remote",
        Utils = "utils",
        GameInfo = "gameinfo",
    },
}

return Spam