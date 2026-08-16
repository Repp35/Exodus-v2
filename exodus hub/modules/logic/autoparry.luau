-- [[ AutoParry ]]

-- parameters
local AutoParry = {}
local Remote, GameInfo, Utils

-- tuning
local P = {
    FIRE_LOCK = 0.080,
    FIRE_TIMEOUT = 2.0,
    MIN_SPD = 5,
    DEFLECT_R = 8.5,
    RAD_FLOOR = 14,
    RAD_CAP = 30,
    PING_FLOOR = 0.030,
    PING_CAP = 0.150,
    RAD_SPD_REF = 200,
    EARLY_PARRY_T = 0.130,
    RES_BASE = 0,
    RES_PER_PARRY = 0.225,
    RES_CAP = 6.0,
    RES_HOLD_T = 1.2,
    RES_DECAY_T = 4.0,
    RES_HITBOX_OWN_WINDOW = 0.5,
    RES_HITBOX_PROX = 12,
    RES_HITBOX_GAP = 0.4,
}

-- hitbox state
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table" and namespace.AutoParryHitbox or {
    connection = nil,
    handler = nil,
}
namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- parry state
local AP = {
    armed = false,
    armedBall = nil,
    armedAt = 0,
    armedSig = nil,
    fired = false,
    firedAt = 0,
}
local RES = {
    stack = 0,
    lastFireBallRef = nil,
    lastFireBallAt = 0,
    lastHitboxAt = 0,
    lastStackAt = 0,
}
local _activeConns = {}
local _teleportLockUntil = 0
local _apBind = 0
local _localUserId = -1
local _lastTargetSeen = -999
local _smoothPing = 0.060
local _pingTimer = 0
local PING_SAMPLE = 1.5
local PING_EMA = 0.3
local _pingOneWayCached = 0.030
local _pingOneWayStamp = 0
local Stats = game:GetService("Stats")

-- ping
local function samplePing()
    local ok, p = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() / 1000
    end)
    if ok and type(p) == "number" and p > 0 and p < 0.5 then
        _smoothPing = _smoothPing * (1 - PING_EMA) + p * PING_EMA
    end
end
local _resBonusCache = 0
local _resBonusStamp = -1
local function resRadiusBonus(t)
    if t == _resBonusStamp then
        return _resBonusCache
    end
    _resBonusCache = math.min(
        RES.stack * P.RES_PER_PARRY,
        P.RES_CAP
    )
    _resBonusStamp = t
    return _resBonusCache
end
local function tickResilience(t)
    if RES.stack <= 0 then
        return
    end
    local since = t - RES.lastStackAt
    if since > P.RES_HOLD_T + P.RES_DECAY_T then
        RES.stack = 0
        return
    end
    if since > P.RES_HOLD_T then
        local frac = 1 - (since - P.RES_HOLD_T) / P.RES_DECAY_T
        if frac <= 0 then
            RES.stack = 0
        else
            local decayed = math.floor(RES.stack * frac + 0.5)
            if decayed ~= RES.stack then
                RES.stack = decayed
            end
        end
    end
end
local function getDeflectCD()
    return GameInfo.getDeflectCD()
end
local function isTargeted()
    if not GameInfo or type(GameInfo.isTargeted) ~= "function" then
        return false
    end
    return GameInfo.isTargeted(_lastTargetSeen)
end

-- radius
local function computeParryRadius(spd, t)
    spd = tonumber(spd) or 0
    t = tonumber(t) or Utils.now()
    local pingOneWay = math.clamp(
        _smoothPing * 0.5,
        P.PING_FLOOR,
        P.PING_CAP
    )
    if t - _pingOneWayStamp > 0.25 then
        _pingOneWayCached = pingOneWay
        _pingOneWayStamp = t
    end
    local spdFactor = math.clamp(
        spd / P.RAD_SPD_REF,
        0,
        1
    )
    local resBonus = resRadiusBonus(t)
    local parryRad =
        P.DEFLECT_R
        + (P.RAD_FLOOR - P.DEFLECT_R) * spdFactor
        + resBonus
    parryRad = math.clamp(
        parryRad,
        P.DEFLECT_R,
        P.RAD_CAP
    )
    local detectRad =
        parryRad
        + spd * (
            _pingOneWayCached
            + P.EARLY_PARRY_T
            + 0.016
        )
    return parryRad, detectRad
end

-- parry
local function sendParry()
    local t = Utils.now()
    if not Remote.fireParry(1) then
        return false
    end
    local b = GameInfo.getBall()
    if b and b.Parent then
        RES.lastFireBallRef = b
        RES.lastFireBallAt = t
    end
    return true
end

-- reset
local function resetState()
    AP.armed = false
    AP.armedBall = nil
    AP.armedAt = 0
    AP.armedSig = nil
    AP.fired = false
    AP.firedAt = 0
    RES.stack = 0
    RES.lastFireBallRef = nil
    RES.lastFireBallAt = 0
    RES.lastHitboxAt = 0
    RES.lastStackAt = 0
    _teleportLockUntil = 0
    _lastTargetSeen = -999
    _resBonusCache = 0
    _resBonusStamp = -1
end
local function disconnectAll()
    for i = #_activeConns, 1, -1 do
        local c = _activeConns[i]
        _activeConns[i] = nil
        if c and type(c.Disconnect) == "function" then
            pcall(function()
                c:Disconnect()
            end)
        end
    end
end
local function onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end
    local t = Utils.now()
    if data.Teleported == true then
        _teleportLockUntil = t + 0.20
        AP.fired = false
        return
    end
    local newTarget = data.TargetPlayerID
    if type(newTarget) ~= "number" then
        newTarget = -999
    end
    if newTarget == _lastTargetSeen then
        return
    end
    local previousTarget = _lastTargetSeen
    _lastTargetSeen = newTarget
    if newTarget == _localUserId then
        AP.fired = false
    elseif newTarget ~= -999 then
        if previousTarget == _localUserId then
            AP.fired = false
        end
    else
        AP.fired = false
    end
end

-- character
local function bindParry(character)
    _apBind = _apBind + 1
    local currentBindId = _apBind
    disconnectAll()
    if not (character and character.Parent) then
        return
    end
    local hrp =
        character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)
    if currentBindId ~= _apBind or not (hrp and hrp.Parent) then
        return
    end
    AP.fired = false
    AP.armed = false
    local heartbeatConn
    heartbeatConn = Utils.getRunService().Heartbeat:Connect(function(dt)
        if currentBindId ~= _apBind then
            return
        end
        if not (character.Parent and hrp.Parent) then
            return
        end
        local Config = Utils.getConfig()
        if not Config or Config.AutoParry ~= true then
            AP.armed = false
            AP.armedBall = nil
            AP.armedAt = 0
            AP.armedSig = nil
            AP.fired = false
            return
        end
        local t = Utils.now()
        if t < _teleportLockUntil then
            AP.armed = false
            AP.armedBall = nil
            AP.armedAt = 0
            AP.armedSig = nil
            return
        end
        if Utils.isClashActive() or Utils.isManualSpamActive() then
            return
        end
        tickResilience(t)
        _pingTimer = _pingTimer + dt
        if _pingTimer >= PING_SAMPLE then
            _pingTimer = 0
            samplePing()
        end
        if AP.armed then
            local curBall = GameInfo.getBall()
            local stillTargeted = GameInfo.isTargeted(_lastTargetSeen)
            local ballAlive = AP.armedBall and AP.armedBall.Parent ~= nil
            local sameBall = curBall == AP.armedBall
            if not (stillTargeted and ballAlive and sameBall) then
                AP.armed = false
                AP.armedBall = nil
                AP.armedAt = 0
                AP.armedSig = nil
            elseif getDeflectCD() <= 0 then
                if AP.fired then
                    if t - AP.firedAt >= P.FIRE_TIMEOUT then
                        AP.fired = false
                    end
                end
                if not AP.fired then
                    if sendParry() then
                        AP.fired = true
                        AP.firedAt = t
                    end
                end
                AP.armed = false
                AP.armedBall = nil
                AP.armedAt = 0
                AP.armedSig = nil
                return
            else
                return
            end
        end
        local ball = GameInfo.getBall()
        if not (ball and ball.Parent) then
            return
        end
        if not GameInfo.isTargeted(_lastTargetSeen) then
            AP.armed = false
            return
        end
        local spd = GameInfo.ballSpeed(ball, t)
        if spd < P.MIN_SPD then
            return
        end
        local bp = GameInfo.ballPos(ball, t)
        if not bp then
            return
        end
        if t - _pingOneWayStamp > 0.25 then
            _pingOneWayCached = math.clamp(
                _smoothPing * 0.5,
                P.PING_FLOOR,
                P.PING_CAP
            )
            _pingOneWayStamp = t
        end
        local parryRad, detectRad = computeParryRadius(spd, t)
        local hp = hrp.Position
        local dx = hp.X - bp.X
        local dy = hp.Y - bp.Y
        local dz = hp.Z - bp.Z
        local distSq = dx * dx + dy * dy + dz * dz
        if distSq > detectRad * detectRad then
            return
        end
        local dist = math.sqrt(distSq)
        local tImp = (dist - parryRad) / spd
        if tImp < 0 then
            tImp = 0
        end
        if tImp > P.EARLY_PARRY_T then
            return
        end
        if getDeflectCD() > 0 then
            AP.armed = true
            AP.armedBall = ball
            AP.armedAt = t
            AP.armedSig = true
            return
        end
        if AP.fired then
            if t - AP.firedAt < P.FIRE_LOCK then
                return
            end
            if t - AP.firedAt < P.FIRE_TIMEOUT then
                return
            end
            AP.fired = false
        end
        if sendParry() then
            AP.fired = true
            AP.firedAt = t
        else
            AP.fired = false
        end
    end)
    _activeConns[#_activeConns + 1] = heartbeatConn
    Utils.trackCharacter(heartbeatConn)
    local ancestryConn
    ancestryConn = character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            _apBind = _apBind + 1
        end
    end)
    _activeConns[#_activeConns + 1] = ancestryConn
    Utils.trackCharacter(ancestryConn)
end

-- hitbox
local function handleHitbox(d)
    if not Utils or not Utils.isActive() then
        return
    end
    if d.Name ~= "HitboxGrow" then
        return
    end
    local ok, hitboxPosition = pcall(function()
        return d.Position
    end)
    if not ok or typeof(hitboxPosition) ~= "Vector3" then
        return
    end
    local t = Utils.now()
    if t - RES.lastFireBallAt > P.RES_HITBOX_OWN_WINDOW then
        return
    end
    if not (RES.lastFireBallRef and RES.lastFireBallRef.Parent) then
        return
    end
    if t - RES.lastHitboxAt < P.RES_HITBOX_GAP then
        return
    end
    if (RES.lastFireBallRef.Position - hitboxPosition).Magnitude > P.RES_HITBOX_PROX then
        return
    end
    RES.lastHitboxAt = t
    RES.lastStackAt = t
    RES.stack = RES.stack + 1
    local cap = math.floor(
        (P.RES_CAP - P.RES_BASE) / P.RES_PER_PARRY
    )
    if RES.stack > cap then
        RES.stack = cap
    end
    _resBonusCache = 0
    _resBonusStamp = -1
end
local function installHitboxHook()
    if HitboxState.connection then
        return
    end
    local ws = game:GetService("Workspace")
    local ok, connection = pcall(function()
        return ws.DescendantAdded:Connect(function(d)
            local handler = HitboxState.handler
            if type(handler) == "function" then
                handler(d)
            end
        end)
    end)
    if ok and connection then
        HitboxState.connection = connection
        if Utils then
            Utils.trackGlobal(connection)
        end
    end
    return HitboxState.connection ~= nil
end

-- setup
function AutoParry.setup(deps)
    if type(deps) ~= "table" or not deps.Remote or not deps.GameInfo or not deps.Utils then
        return false
    end
    Remote = deps.Remote
    GameInfo = deps.GameInfo
    Utils = deps.Utils
    local player = Utils.getLocalPlayer()
    _localUserId = player and player.UserId or -1
    HitboxState.handler = handleHitbox
    if not installHitboxHook() then
        Utils.warn("hook de hitbox indisponível")
    end
    return true
end
function AutoParry.fire()
    return sendParry()
end
function AutoParry.bindParry(character)
    bindParry(character)
end
function AutoParry.resetState()
    resetState()
end
function AutoParry.detachCharacter()
    _apBind = _apBind + 1
    disconnectAll()
    resetState()
end
function AutoParry.onBallSync(data)
    onBallSync(data)
end
function AutoParry.getState()
    return AP
end
function AutoParry.isTargeted()
    return isTargeted()
end
function AutoParry.computeParryRadius(spd, t)
    return computeParryRadius(spd, t)
end
return AutoParry
