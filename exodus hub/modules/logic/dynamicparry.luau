-- [[ dynamic parry ]]

local DynamicParry = {}
local Remote
local AutoParry
local Utils
local onAutoClashDisabled
local onStateChanged

local HOLD_THRESHOLD = 0.16
local AP_DELAY = 0.010
local DEFAULT_RELEASE_DELAY = 0.2

local R = {
    pressed = false,
    holding = false,
    generation = 0,
    releaseGeneration = 0,
}

local function now()
    if Utils and type(Utils.now) == "function" then
        return Utils.now()
    end
    return os.clock()
end
local function emitState(state)
    if type(onStateChanged) == "function" then
        pcall(onStateChanged, state)
    end
end
local function isReady()
    return Utils
        and type(Utils.isActive) == "function"
        and Utils.isActive()
        and Remote
        and type(Remote.fireParry) == "function"
end
local function getLastAutoParryAt()
    if AutoParry and type(AutoParry.getLastFireAt) == "function" then
        local ok, value = pcall(AutoParry.getLastFireAt)
        value = ok and tonumber(value) or 0
        if value and value == value and value > 0 then
            return value
        end
    end
    return 0
end
local function getReleaseDelay()
    local configured
    if Utils and type(Utils.getConfig) == "function" then
        local config = Utils.getConfig()
        if type(config) == "table" then
            configured = tonumber(config.DynamicParryReleaseDelay)
        end
    end
    if not configured or configured ~= configured or configured < 0 then
        return DEFAULT_RELEASE_DELAY
    end
    return math.min(configured, 5)
end
local function waitForAutoParryWindow(generation)
    local deadline = now()
    repeat
        local lastAutoParryAt = getLastAutoParryAt()
        deadline = math.max(deadline, lastAutoParryAt + AP_DELAY)
        local remaining = deadline - now()
        if remaining > 0 then
            task.wait(remaining)
        end
    until now() >= deadline
    return generation == R.generation and not R.pressed
end
local function requestParry(generation)
    if generation ~= R.generation or not isReady() then
        return false
    end
    if not waitForAutoParryWindow(generation) then
        return false
    end
    local ok, result = pcall(Remote.fireParry, 1)
    if not ok or result == false then
        if Utils and type(Utils.recordError) == "function" then
            Utils.recordError("DynamicParry", "Remote.fireParry falhou")
        end
        return false
    end
    return true
end
local function startHold(generation)
    if generation ~= R.generation
        or not R.pressed
        or R.holding
    then
        return
    end
    R.holding = true
    R.releaseGeneration += 1
    if Utils and type(Utils.setManualSpamActive) == "function" then
        Utils.setManualSpamActive(true)
    end
    emitState("holding")
end
function DynamicParry.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Remote) ~= "table"
        or type(deps.Remote.fireParry) ~= "function"
        or type(deps.AutoParry) ~= "table"
        or type(deps.AutoParry.getLastFireAt) ~= "function"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.setConfig) ~= "function"
        or type(deps.Utils.setManualSpamActive) ~= "function"
    then
        return false, "dependência ausente: Remote, AutoParry ou Utils"
    end
    Remote = deps.Remote
    AutoParry = deps.AutoParry
    Utils = deps.Utils
    DynamicParry.resetState()
    return true
end
function DynamicParry.setAutoClashDisabledHandler(handler)
    onAutoClashDisabled = type(handler) == "function" and handler or nil
end
function DynamicParry.setStateHandler(handler)
    onStateChanged = type(handler) == "function" and handler or nil
end
function DynamicParry.tap()
    if R.pressed or R.holding then
        return false
    end
    local config = Utils and type(Utils.getConfig) == "function" and Utils.getConfig() or nil
    if type(config) == "table" and config.AutoClash == true then
        emitState("released")
        return false
    end
    local generation = R.generation
    task.spawn(function()
        requestParry(generation)
    end)
    emitState("released")
    return true
end
function DynamicParry.press()
    if R.pressed then
        return false
    end
    R.pressed = true
    R.holding = false
    R.generation += 1
    R.releaseGeneration += 1
    local generation = R.generation
    emitState("pressed")
    task.delay(HOLD_THRESHOLD, function()
        startHold(generation)
    end)
    return true
end
function DynamicParry.release()
    if not R.pressed then
        return false
    end
    local generation = R.generation
    local wasHolding = R.holding
    R.pressed = false
    R.holding = false
    if wasHolding then
        R.releaseGeneration += 1
        local releaseGeneration = R.releaseGeneration
        task.delay(getReleaseDelay(), function()
            if releaseGeneration ~= R.releaseGeneration or R.pressed or R.holding then
                return
            end
            if Utils and type(Utils.setManualSpamActive) == "function" then
                Utils.setManualSpamActive(false)
            end
        end)
        emitState("released")
        return true
    end
    if Utils and type(Utils.getConfig) == "function" then
        local config = Utils.getConfig()
        if type(config) == "table" and config.AutoClash == true then
            emitState("released")
            return false
        end
    end
    task.spawn(function()
        requestParry(generation)
    end)
    emitState("released")
    return true
end
function DynamicParry.resetState()
    R.generation += 1
    R.releaseGeneration += 1
    if R.holding and Utils and type(Utils.setManualSpamActive) == "function" then
        Utils.setManualSpamActive(false)
    end
    R.pressed = false
    R.holding = false
    emitState("released")
end
function DynamicParry.teardown()
    DynamicParry.resetState()
    Remote = nil
    AutoParry = nil
    Utils = nil
    onAutoClashDisabled = nil
    onStateChanged = nil
end
function DynamicParry.getStatus()
    return {
        schema = Utils and Utils.apiVersion and Utils.apiVersion() or 1,
        pressed = R.pressed == true,
        holding = R.holding == true,
        holdThreshold = HOLD_THRESHOLD,
        releaseDelay = getReleaseDelay(),
        apDelay = AP_DELAY,
    }
end
DynamicParry.__contract = {
    requires = {
        Remote = "remote",
        AutoParry = "autoparry",
        Utils = "utils",
    },
}
return DynamicParry
