--[[ Spam ]]

-- state
local Spam = {}
local Remote, AutoClash, Utils

-- counters
local _heartbeat
local _cpsElapsed = 0
local _cpsSent = 0
local _cpfCredits = 0
local _cpfSent = 0
local _cpfGeneration = 0
local _lastMode
local _lastRate
local RATE_EPSILON = 1e-7
local MAX_CPF_SCHEDULE_PER_TICK = 4096

local function invalidateCPF()
    _cpfGeneration = _cpfGeneration + 1
    _cpfCredits = 0
    _cpfSent = 0
end

local function cpfActive()
    return Utils.isActive() and (Utils.isManualSpamActive() or (AutoClash and AutoClash.clashOn()))
end

local function scheduleCPF(rate, dt)
    if rate <= 0 then
        invalidateCPF()
        return
    end
    _cpfCredits = _cpfCredits + rate
    local target = math.floor(_cpfCredits + RATE_EPSILON)
    local clicks = math.max(target - _cpfSent, 0)
    if clicks <= 0 then return end
    local scheduled = math.min(clicks, MAX_CPF_SCHEDULE_PER_TICK)
    _cpfSent = _cpfSent + scheduled
    local generation = _cpfGeneration
    local spacing = dt / scheduled
    for index = 1, scheduled do
        local delay = spacing * (index - 0.5)
        task.delay(delay, function()
            if generation ~= _cpfGeneration or not cpfActive() then return end
            Remote.fireParry(1)
        end)
    end
end

-- runtime
local function tick(dt)
    local cfg = Utils.getConfig()
    if type(cfg) ~= "table" then return end
    if not Utils.isManualSpamActive() and not (AutoClash and AutoClash.clashOn()) then
        if _lastMode == "CPF" then invalidateCPF() end
        return
    end
    if type(dt) ~= "number" or dt <= 0 then return end
    local mode = cfg.SpamRateMode == "CPS" and "CPS" or "CPF"
    if mode ~= _lastMode then
        _lastMode = mode
        _cpsElapsed = 0
        _cpsSent = 0
        _lastRate = nil
        invalidateCPF()
    end
    local rateKey = mode == "CPS" and "CPS" or "CPF"
    local fallback = mode == "CPS" and 4 or 16
    local rate = Utils.normalizeSpamRate(cfg[rateKey], fallback)
    if cfg[rateKey] ~= rate then
        Utils.setConfig({[rateKey] = rate})
    end
    local clicks
    if mode == "CPS" then
        if rate ~= _lastRate then
            _lastRate = rate
            _cpsElapsed = 0
            _cpsSent = 0
        end
        _cpsElapsed = _cpsElapsed + dt
        local target = math.floor(_cpsElapsed * rate + RATE_EPSILON)
        clicks = math.max(target - _cpsSent, 0)
        _cpsSent = _cpsSent + clicks
    else
        if rate ~= _lastRate then
            _lastRate = rate
            invalidateCPF()
        end
        scheduleCPF(rate, dt)
        return
    end
    for _ = 1, clicks do Remote.fireParry(1) end
end

-- setup
function Spam.setup(deps)
    if type(deps) ~= "table" or not deps.Remote or not deps.AutoClash or not deps.Utils then
        return false
    end
    Remote = deps.Remote
    AutoClash = deps.AutoClash
    Utils = deps.Utils
    Spam.resetState()
    if _heartbeat then
        pcall(function()
            _heartbeat:Disconnect()
        end)
    end
    _heartbeat = Utils.getRunService().Heartbeat:Connect(tick)
    Utils.trackGlobal(_heartbeat)
    return true
end

-- lifecycle
function Spam.resetState()
    _cpsElapsed = 0
    _cpsSent = 0
    _lastMode = nil
    _lastRate = nil
    invalidateCPF()
end
return Spam
