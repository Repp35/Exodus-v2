-- [[ Spam ]]

-- state
local Spam = {}
local Remote, AutoClash, Utils

-- state
local _fps, _heartbeat
local _cpsCarry = 0
local _lastMode
local EMA = 0.08

-- runtime
local function tick(dt)
    local cfg = Utils.getConfig()
    if type(cfg) ~= "table" then return end
    if not Utils.isManualSpamActive() and not (AutoClash and AutoClash.clashOn()) then return end
    if type(dt) ~= "number" or dt <= 0 then return end
    local mode = cfg.SpamRateMode == "CPS" and "CPS" or "CPF"
    if mode ~= _lastMode then
        _lastMode = mode
        _cpsCarry = 0
        _fps = nil
    end
    local rate = Utils.normalizeSpamRate(cfg.CPS, 0)
    if cfg.CPS ~= rate then
        Utils.setConfig({CPS = rate})
    end
    local clicks
    if mode == "CPS" then
        _cpsCarry = _cpsCarry + rate * dt
        clicks = math.floor(_cpsCarry)
        _cpsCarry = _cpsCarry - clicks
    else
        local fpsNow = 1 / dt
        _fps = _fps and (_fps + (fpsNow - _fps) * EMA) or fpsNow
        local fps = math.max(_fps or fpsNow, 1)
        clicks = math.floor(rate * math.max(60, fps) / fps)
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
    _fps = nil
    _cpsCarry = 0
    _lastMode = nil
end
return Spam
