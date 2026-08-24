-- [[ Spam ]]

local Spam = {}
local Remote
local Utils

-- tuning
local RATE_EPSILON = 1e-7
local REFERENCE_FPS = 60

-- state
local heartbeatConnection
local schedulerThread
local generation = 0
local pendingClicks = 0
local scheduledTimes = {}
local scheduledHead = 1
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
    scheduledTimes = {}
    scheduledHead = 1

    Scheduler.phase = "stopped"

    if Utils
        and type(Utils.recordTransition) == "function"
        and wasActive
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
        Scheduler.lastError =
            "Remote.fireParry retornou false"

        if type(Utils.recordError) == "function" then
            Utils.recordError(
                "Spam",
                Scheduler.lastError
            )
        end

        return false
    end

    Scheduler.lastError = nil

    return true
end

-- Adiciona ações à fila temporal.
--
-- Cada ação recebe um timestamp próprio.
-- Isso evita criar vários task.spawn competindo
-- entre si ao mesmo tempo.
local function schedule(clicks, dt, startTime, currentGeneration)
    if clicks <= 0 then
        return
    end

    local spacing = dt / clicks

    for index = 1, clicks do
        if currentGeneration ~= generation then
            return
        end

        local targetTime =
            startTime
            + spacing * (index - 0.5)

        scheduledTimes[#scheduledTimes + 1] =
            targetTime
    end
end

-- Worker único do scheduler.
--
-- Existe somente uma rotina consumindo a fila,
-- portanto diferentes Heartbeats não criam
-- vários grupos de parries simultâneos.
local function schedulerWorker(currentGeneration)
    while currentGeneration == generation do
        if not isActive() then
            return
        end

        local targetTime =
            scheduledTimes[scheduledHead]

        if targetTime == nil then
            task.wait()
            continue
        end

        local now = Utils.now()
        local remaining = targetTime - now

        if remaining > 0 then
            task.wait(remaining)
        else
            scheduledHead = scheduledHead + 1

            requestParry()
        end

        -- Limpeza periódica da fila consumida.
        if scheduledHead > 128
            and scheduledHead > (#scheduledTimes / 2)
        then
            local newQueue = {}

            for index = scheduledHead, #scheduledTimes do
                newQueue[#newQueue + 1] =
                    scheduledTimes[index]
            end

            scheduledTimes = newQueue
            scheduledHead = 1
        end
    end
end

local function ensureScheduler()
    if schedulerThread then
        return
    end

    local currentGeneration = generation

    schedulerThread = task.spawn(function()
        schedulerWorker(currentGeneration)
        schedulerThread = nil
    end)
end

local function resetRateState()
    pendingClicks = 0
    scheduledTimes = {}
    scheduledHead = 1

    lastMode = nil
    lastRate = nil
end

-- runtime
local function tick(dt)
    local config = Utils.getConfig()

    if type(config) ~= "table" then
        if type(Utils.recordError) == "function" then
            Utils.recordError(
                "Spam",
                "configuração indisponível"
            )
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
            Utils.recordTransition(
                "Spam",
                "stopped",
                "running",
                "spam_enabled"
            )
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

    local mode =
        config.SpamRateMode == "CPS"
        and "CPS"
        or "CPF"

    local fallback =
        mode == "CPS"
        and 4
        or 1

    local rateKey = mode

    local rate =
        Utils.normalizeSpamRate(
            config[rateKey],
            fallback
        )

    if config[rateKey] ~= rate then
        Utils.setConfig({
            [rateKey] = rate
        })
    end

    if mode ~= lastMode
        or rate ~= lastRate
    then
        resetRateState()

        lastMode = mode
        lastRate = rate
    end

    -- ============================================
    -- RATE CONVERSION
    -- ============================================
    --
    -- CPF:
    --
    -- 1 CPF = 1 click por frame a 60 FPS
    -- 2 CPF = 2 clicks por frame a 60 FPS
    -- 0.5 CPF = 30 clicks/s
    --
    -- Portanto:
    --
    -- CPF -> CPS = CPF * 60
    --
    -- CPS:
    --
    -- permanece diretamente como clicks/segundo.
    --
    local ratePerSecond

    if mode == "CPF" then
        ratePerSecond = rate * REFERENCE_FPS
    else
        ratePerSecond = rate
    end

    -- Acumulador temporal.
    --
    -- Não existe limite artificial.
    pendingClicks =
        pendingClicks
        + ratePerSecond * dt

    local clicks =
        math.floor(
            pendingClicks + RATE_EPSILON
        )

    if clicks <= 0 then
        ensureScheduler()
        return
    end

    pendingClicks =
        pendingClicks - clicks

    -- Distribui todas as ações desse intervalo.
    --
    -- Exemplo:
    -- 60 FPS + 1 CPF:
    --   1 ação dentro de cada frame.
    --
    -- 30 FPS + 1 CPF:
    --   2 ações dentro de cada frame,
    --   separadas por metade do frame.
    --
    -- 60 CPS:
    --   1 ação por aproximadamente 16.67 ms.
    --
    schedule(
        clicks,
        dt,
        Utils.now(),
        generation
    )

    ensureScheduler()
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
        pcall(
            heartbeatConnection.Disconnect,
            heartbeatConnection
        )

        deps.Utils.untrackGlobal(
            heartbeatConnection
        )

        heartbeatConnection = nil
    end

    Remote = deps.Remote
    Utils = deps.Utils

    Spam.resetState()

    heartbeatConnection =
        Utils.getRunService()
        .Heartbeat
        :Connect(tick)

    Utils.trackGlobal(
        heartbeatConnection
    )

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

        phase =
            Scheduler.phase == "running"
            and "running"
            or "stopped",

        lastRequestAt =
            Scheduler.lastRequestAt,

        lastError =
            Scheduler.lastError,

        pendingClicks =
            pendingClicks,

        queuedClicks =
            math.max(
                #scheduledTimes
                - scheduledHead
                + 1,
                0
            ),

        mode =
            lastMode,

        rate =
            lastRate,
    }
end

return Spam