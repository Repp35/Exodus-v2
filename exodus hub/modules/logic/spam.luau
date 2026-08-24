-- [[ Spam ]]

local Spam = {}

local Remote
local Utils

-- tuning
local EMA = 0.08

-- state
local heartbeatConnection
local generation = 0
local _fps
local wasActive = false

local Scheduler = {
    phase = "stopped",
    lastRequestAt = 0,
    lastError = nil,
}

-- helpers
local function invalidate(reason)
    generation = generation + 1
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
    return Utils.isActive()
        and Utils.isSpamActive()
end

local function requestParry()
    local ok, result = pcall(
        Remote.fireParry,
        1
    )

    Scheduler.lastRequestAt = Utils.now()

    if not ok then
        Scheduler.lastError = tostring(result)

        if type(Utils.recordError) == "function" then
            Utils.recordError(
                "Spam",
                result
            )
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

    if not isActive() then
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
        or dt <= 0
        or dt ~= dt
        or dt == math.huge
        or dt == -math.huge
    then
        return
    end

    -- FPS smoothing
    local fpsNow = 1 / dt

    _fps =
        _fps
        and (
            _fps
            + (fpsNow - _fps) * EMA
        )
        or fpsNow

    local fps =
        math.max(
            _fps or fpsNow,
            1
        )

    -- [[ Spam Rate ]]
    --
    -- A lógica é baseada no scheduler antigo:
    --
    -- FPS >= 60:
    --     mantém a quantidade configurada por frame.
    --
    -- FPS < 60:
    --     aumenta a quantidade por frame para
    --     compensar a perda de FPS.
    --
    -- Exemplo com CPS = 1:
    --
    -- 60 FPS -> 1 click/frame
    -- 30 FPS -> 2 clicks/frame
    -- 20 FPS -> 3 clicks/frame
    --
    -- Em FPS acima de 60, não reduz a quantidade.
    local rate =
        math.max(
            tonumber(config.CPS) or 1,
            1
        )

    local clicks =
        rate
        * math.max(60, fps)
        / fps

    local wholeClicks =
        math.floor(clicks)

    if wholeClicks <= 0 then
        return
    end

    local currentGeneration = generation

    -- Mantém todos os disparos deste tick
    -- pertencendo à mesma geração.
    for index = 1, wholeClicks do
        if currentGeneration ~= generation
            or not isActive()
        then
            return
        end

        requestParry()
    end
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

    _fps = nil
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

        fps =
            _fps,
    }
end

return Spam