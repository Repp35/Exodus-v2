-- [[ Spam Scheduler ]]

local Spam = {}

local Utils

-- tuning
local RATE_EPSILON = 1e-7
local TARGET_FPS = 60

-- state
local heartbeatConnection
local generation = 0
local accumulator = 0
local lastMode
local lastRate
local wasActive = false

local Scheduler = {
    phase = "stopped",
    lastRequestAt = 0,
    lastError = nil,
    totalScheduled = 0,
}

-- helpers
local function invalidate(reason)
    generation = generation + 1
    accumulator = 0

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

local function resetRateState()
    accumulator = 0
    lastMode = nil
    lastRate = nil
end

local function calculateActions(rate, dt)
    if type(rate) ~= "number"
        or type(dt) ~= "number"
        or rate ~= rate
        or dt ~= dt
        or rate <= 0
        or dt <= 0
        or rate == math.huge
        or dt == math.huge
        or dt == -math.huge
    then
        return 0
    end

    accumulator = accumulator + rate * dt

    local actions = math.floor(
        accumulator + RATE_EPSILON
    )

    accumulator = accumulator - actions

    return actions
end

local function dispatch(actions, dt, currentGeneration)
    if actions <= 0 then
        return
    end

    if currentGeneration ~= generation then
        return
    end

    -- Distribuição uniforme dentro do intervalo.
    --
    -- Exemplo:
    -- 1 ação -> 50%
    -- 2 ações -> 25%, 75%
    -- 3 ações -> 16.67%, 50%, 83.33%
    --
    -- A função aqui é deliberadamente neutra:
    -- ela informa quando cada ação deveria ocorrer,
    -- sem disparar um Remote de jogo.

    local spacing = dt / actions

    for index = 1, actions do
        if currentGeneration ~= generation then
            return
        end

        local offset = spacing * (index - 0.5)

        Scheduler.totalScheduled =
            Scheduler.totalScheduled + 1

        if type(Spam.onScheduled) == "function" then
            Spam.onScheduled(
                index,
                actions,
                offset,
                spacing
            )
        end
    end
end

-- runtime
local function tick(dt)
    if type(dt) ~= "number"
        or dt ~= dt
        or dt <= 0
        or dt == math.huge
        or dt == -math.huge
    then
        return
    end

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

    local active =
        Utils.isActive()
        and Utils.isSpamActive()

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

    local mode =
        config.SpamRateMode == "CPS"
        and "CPS"
        or "CPF"

    local fallback =
        mode == "CPS"
        and 4
        or 60

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

    -- CPF:
    -- rate = ações por frame de referência.
    --
    -- Para a referência de 60 FPS:
    -- CPF 60 = 60 ações/s.
    --
    -- CPS:
    -- rate = ações por segundo.
    --
    -- Ambos acabam convertidos para:
    -- ações = taxa * tempo decorrido.

    local ratePerSecond

    if mode == "CPF" then
        ratePerSecond = rate
    else
        ratePerSecond = rate
    end

    local actions =
        calculateActions(
            ratePerSecond,
            dt
        )

    if actions <= 0 then
        return
    end

    local currentGeneration = generation
    local frameStart = Utils.now()

    dispatch(
        actions,
        dt,
        currentGeneration
    )

    Scheduler.lastRequestAt = frameStart
end

-- setup
function Spam.setup(deps)
    if type(deps) ~= "table"
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

        pcall(
            deps.Utils.untrackGlobal,
            heartbeatConnection
        )

        heartbeatConnection = nil
    end

    Utils = deps.Utils

    Spam.resetState()

    heartbeatConnection =
        Utils.getRunService()
        .Heartbeat
        :Connect(tick)

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
    Scheduler.totalScheduled = 0
end

function Spam.getStatus()
    return {
        schema =
            Utils
            and Utils.apiVersion
            and Utils.apiVersion()
            or nil,

        phase =
            Scheduler.phase == "running"
            and "running"
            or "stopped",

        lastRequestAt =
            Scheduler.lastRequestAt,

        lastError =
            Scheduler.lastError,

        totalScheduled =
            Scheduler.totalScheduled,

        accumulator =
            accumulator,

        mode =
            lastMode,

        rate =
            lastRate,
    }
end

return Spam