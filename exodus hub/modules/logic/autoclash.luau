local AutoClash = {}

-- dependencies supplied by the Exodus API
local GameInfo
local Utils
local AutoParry
local Remote

-- tuning copied from Astru's behavior
local RED_HOLD = 0.25
local SPAM_INTERVAL = 0.05

local TARGET_RETURN_MAX_LO = 0.280
local TARGET_RETURN_MIN_HI = 0.170
local TARGET_RETURN_SPD_LO = 60
local TARGET_RETURN_SPD_HI = 200

local PHYS_SPD_REF = 120
local PHYS_DOT_EMA = 0.25
local PHYS_THRESH = 0.14
local PHYS_RAD_SLACK = 1.22
local ACT_RADIUS_MULT = 1.32
local SYNC_TARGET_RADIUS_MULT = 1.05
local DEACT_RADIUS_MULT = 1.15

-- state
local S = {
    enabled = false,
    active = false,
    activeAt = 0,
    lastValidAt = 0,
    lastTargetAt = 0,
    lastTargetId = nil,
    wasMeTarget = false,
    lostMeAt = 0,
    physDotEma = 0,
    bound = false,
    _lastFire = 0,
}

-- connections
local _tickConn
local _setupDone = false

-- helpers
local function now()
    if Utils and type(Utils.now) == "function" then
        local ok, value = pcall(Utils.now)

        if ok and type(value) == "number" then
            return value
        end
    end

    return os.clock()
end

local function getLP()
    if Utils and type(Utils.getLocalPlayer) == "function" then
        local ok, player = pcall(Utils.getLocalPlayer)

        if ok and player then
            return player
        end
    end

    return game:GetService("Players").LocalPlayer
end

local function getBall()
    if GameInfo and type(GameInfo.getBall) == "function" then
        local ok, ball = pcall(GameInfo.getBall)

        if ok then
            return ball
        end
    end

    return nil
end

local function getConfig()
    if Utils and type(Utils.getConfig) == "function" then
        local ok, config = pcall(Utils.getConfig)

        if ok and type(config) == "table" then
            return config
        end
    end

    return {}
end

local function uiEnabled()
    return getConfig().AutoClash == true
end

local function getSync()
    if AutoParry and type(AutoParry.getSync) == "function" then
        local ok, sync = pcall(AutoParry.getSync)

        if ok and sync then
            return sync
        end
    end

    return nil
end

local function getBallSpeed(ball)
    if not ball or not ball.Parent then
        return 0
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        return 0
    end

    return velocity.Magnitude
end

local function getParrySpeed(t, ball)
    local sync = getSync()
    local syncSpeed = sync and tonumber(sync.Speed)

    if type(syncSpeed) == "number" and syncSpeed >= 0 then
        return syncSpeed, sync
    end

    if ball and GameInfo and type(GameInfo.ballSpeed) == "function" then
        local ok, speed = pcall(GameInfo.ballSpeed, ball, t)

        if ok and type(speed) == "number" and speed >= 0 then
            return speed, sync
        end
    end

    return 0, sync
end

local FALLBACK_DEFLECT_R = 8.5
local FALLBACK_RAD_FLOOR = 14
local FALLBACK_RAD_CAP = 30
local FALLBACK_RAD_SPD_REF = 200

local function computeParryRadius(spd, t)
    if AutoParry and type(AutoParry.getParryRadius) == "function" then
        local ok, parryRadius = pcall(AutoParry.getParryRadius, spd, t)

        if ok and type(parryRadius) == "number" and parryRadius > 0 then
            return parryRadius
        end
    end

    if AutoParry and type(AutoParry.computeParryRadius) == "function" then
        local ok, parryRadius = pcall(AutoParry.computeParryRadius, spd)

        if ok and type(parryRadius) == "number" and parryRadius > 0 then
            return parryRadius
        end
    end

    spd = tonumber(spd) or 0

    local spdFactor = math.clamp(spd / FALLBACK_RAD_SPD_REF, 0, 1)
    local parryRadius = FALLBACK_DEFLECT_R
        + (FALLBACK_RAD_FLOOR - FALLBACK_DEFLECT_R) * spdFactor

    return math.clamp(parryRadius, FALLBACK_DEFLECT_R, FALLBACK_RAD_CAP)
end

local function isBallTargeted(ctx)
    if ctx and typeof(ctx.targeted) == "boolean" then
        return ctx.targeted
    end

    if AutoParry and type(AutoParry.isTargeted) == "function" then
        local ok, targeted = pcall(AutoParry.isTargeted)
        return ok and targeted == true
    end

    return false
end

local function ballInRange(hr, ball, distance)
    if not (hr and ball) then
        return false
    end

    if type(distance) ~= "number" or distance <= 0 then
        return false
    end

    local ok, currentDistance = pcall(function()
        return (hr.Position - ball.Position).Magnitude
    end)

    return ok
        and typeof(currentDistance) == "number"
        and currentDistance <= distance
end

local function getDeactivationRadius(ctx)
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return 8
    end

    return radius * DEACT_RADIUS_MULT
end

local function getActivationRadius(ctx)
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return 8
    end

    return radius * ACT_RADIUS_MULT
end

local function nearestInRange(myHRP, distance)
    if not (myHRP and type(distance) == "number" and distance > 0) then
        return false
    end

    local localPlayer = getLP()

    for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")

            if hrp then
                local ok, currentDistance = pcall(function()
                    return (myHRP.Position - hrp.Position).Magnitude
                end)

                if ok
                    and typeof(currentDistance) == "number"
                    and currentDistance <= distance
                then
                    return true
                end
            end
        end
    end

    return false
end

-- context
local function getParryContext(t, hr, ball)
    local speed, sync = getParrySpeed(t, ball)
    local targeted = false

    if AutoParry and type(AutoParry.isTargeted) == "function" then
        local ok, value = pcall(AutoParry.isTargeted)
        targeted = ok and value == true
    end

    return {
        time = t,
        hr = hr,
        ball = ball,
        targeted = targeted,
        parryRadius = computeParryRadius(speed, t),
        sync = sync,
        spd = speed,
    }
end

local function getTargetReturnWindow(speed)
    if speed >= TARGET_RETURN_SPD_HI then
        return TARGET_RETURN_MIN_HI
    end

    if speed <= TARGET_RETURN_SPD_LO then
        return TARGET_RETURN_MAX_LO
    end

    local alpha = (speed - TARGET_RETURN_SPD_LO)
        / (TARGET_RETURN_SPD_HI - TARGET_RETURN_SPD_LO)

    return TARGET_RETURN_MAX_LO
        + (TARGET_RETURN_MIN_HI - TARGET_RETURN_MAX_LO) * alpha
end

local function tickPhysical(ctx)
    local hr = ctx and ctx.hr
    local ball = ctx and ctx.ball

    if not (hr and hr.Parent and ball and ball.Parent) then
        S.physDotEma = 0
        return false
    end

    local ok, velocity = pcall(function()
        return ball.AssemblyLinearVelocity
    end)

    if not ok or typeof(velocity) ~= "Vector3" then
        S.physDotEma = 0
        return false
    end

    local speed = velocity.Magnitude

    if speed <= 1 then
        S.physDotEma = 0
        return false
    end

    local offset = hr.Position - ball.Position
    local distance = offset.Magnitude

    if distance < 0.001 then
        S.physDotEma = 0
        return false
    end

    local radius = getActivationRadius(ctx)
    local dot = velocity:Dot(offset.Unit)

    if distance <= radius * PHYS_RAD_SLACK then
        S.physDotEma = S.physDotEma * (1 - PHYS_DOT_EMA)
            + dot * PHYS_DOT_EMA
    else
        S.physDotEma = 0
    end

    return distance <= radius and S.physDotEma > PHYS_THRESH
end

-- lifecycle
local function activate(t)
    S.active = true
    S.activeAt = t
    S.lastValidAt = t
end

local function deactivate()
    S.active = false
    S.activeAt = 0
    S.lastValidAt = 0
end

local function shouldDeactivate(t, ctx)
    if not (ctx and ctx.hr and ctx.ball) then
        return true
    end

    if not isBallTargeted(ctx) then
        return true
    end

    local radius = getDeactivationRadius(ctx)

    if not ballInRange(ctx.hr, ctx.ball, radius) then
        return true
    end

    if not nearestInRange(ctx.hr, radius) then
        return true
    end

    local lastValid = S.lastValidAt or S.activeAt or 0

    return (t - lastValid) >= RED_HOLD
end

-- additional target-sync activation gate
local function syncCloseActivationGate(t, targetId, previousTarget)
    if type(targetId) ~= "number" then
        return false
    end

    local localPlayer = getLP()

    if not localPlayer
        or targetId ~= localPlayer.UserId
        or previousTarget == targetId
    then
        return false
    end

    local character = localPlayer.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    local ball = getBall()

    if not (hrp and hrp.Parent and ball and ball.Parent) then
        return false
    end

    local ctx = getParryContext(t, hrp, ball)
    local radius = ctx and ctx.parryRadius

    if type(radius) ~= "number" or radius <= 0 then
        return false
    end

    radius = radius * SYNC_TARGET_RADIUS_MULT

    if not ballInRange(hrp, ball, radius) then
        return false
    end

    activate(t)
    return true
end

local function onTeleport()
    deactivate()
end

local function onTarget(targetId)
    local t = now()
    local previousTarget = S.lastTargetId

    S.lastTargetAt = t
    S.lastTargetId = targetId
    syncCloseActivationGate(t, targetId, previousTarget)

    if type(targetId) ~= "number" then
        if S.wasMeTarget and S.lostMeAt == 0 then
            S.lostMeAt = t
        end

        return
    end

    local localPlayer = getLP()

    if not localPlayer then
        return
    end

    local isMe = targetId == localPlayer.UserId

    if isMe then
        local lostAt = S.lostMeAt or 0

        if lostAt > 0 then
            local character = localPlayer.Character
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            local ball = getBall()

            if hrp and ball and ball.Parent then
                local speed = getBallSpeed(ball)
                local window = getTargetReturnWindow(speed)
                local elapsed = t - lostAt

                if elapsed <= window then
                    local syncSpeed = 0
                    local sync = getSync()

                    if sync then
                        syncSpeed = tonumber(sync.Speed) or 0
                    end

                    local baseRadius = computeParryRadius(syncSpeed, t)
                    local activationRadius = baseRadius * ACT_RADIUS_MULT

                    local okDistance, distance = pcall(function()
                        return (hrp.Position - ball.Position).Magnitude
                    end)

                    if okDistance and distance <= activationRadius then
                        activate(t)
                    end
                end
            end
        end

        S.wasMeTarget = true
        S.lostMeAt = 0
        return
    end

    if S.wasMeTarget then
        S.lostMeAt = t
    end
end

-- Exodus target/teleport event adapter
function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end

    if data.Teleported == true then
        onTeleport()
        return
    end

    onTarget(data.TargetPlayerID)
end

-- fire through Exodus's own API
local function fireParry()
    if AutoParry and type(AutoParry.fire) == "function" then
        return AutoParry.fire()
    end

    if not Remote then
        local ex = type(_G.Exodus) == "table" and _G.Exodus.Modules

        if type(ex) == "table" then
            Remote = ex.Remote
        end
    end

    if Remote and type(Remote.fireParry) == "function" then
        return Remote.fireParry(1)
    end

    return false
end

-- per-character heartbeat; this preserves Exodus's lifecycle API while
-- following Astru's evaluate -> active -> spam flow.
local function tickCharacter()
    if not uiEnabled() then
        if S.enabled or S.active then
            S.enabled = false
            deactivate()
        end

        return
    end

    S.enabled = true

    local localPlayer = getLP()

    if not localPlayer then
        return
    end

    local character = localPlayer.Character

    if not character or not character.Parent then
        return
    end

    local hr = character:FindFirstChild("HumanoidRootPart")

    if not hr or not hr.Parent then
        return
    end

    local ball = getBall()

    if not (ball and ball.Parent) then
        return
    end

    local t = now()
    local ctx = getParryContext(t, hr, ball)

    if S.active then
        local radius = getDeactivationRadius(ctx)

        if isBallTargeted(ctx)
            and ballInRange(ctx.hr, ctx.ball, radius)
            and nearestInRange(ctx.hr, radius)
        then
            S.lastValidAt = t
        end

        if shouldDeactivate(t, ctx) then
            deactivate()
        end
    elseif tickPhysical(ctx) then
        activate(t)
    end

    if S.active and t - S._lastFire >= SPAM_INTERVAL then
        pcall(fireParry)
        S._lastFire = t
    end
end

-- bind
function AutoClash.bindCharacter(character)
    if not (character and character.Parent) then
        return false
    end

    if not (Utils and type(Utils.getRunService) == "function") then
        return false
    end

    AutoClash.detachCharacter()

    S.bound = true
    S._lastFire = 0

    local runService = Utils.getRunService()

    if not runService or not runService.Heartbeat then
        S.bound = false
        return false
    end

    _tickConn = runService.Heartbeat:Connect(tickCharacter)

    if type(Utils.trackCharacter) == "function" then
        Utils.trackCharacter(_tickConn)
    elseif type(Utils.trackGlobal) == "function" then
        Utils.trackGlobal(_tickConn)
    end

    if type(Utils.setOnClashOn) == "function" then
        Utils.setOnClashOn(function()
            return S.active
        end)
    end

    return true
end

function AutoClash.detachCharacter()
    if _tickConn then
        pcall(function()
            _tickConn:Disconnect()
        end)

        if Utils and type(Utils.untrackGlobal) == "function" then
            Utils.untrackGlobal(_tickConn)
        elseif Utils and type(Utils.untrackCharacter) == "function" then
            Utils.untrackCharacter(_tickConn)
        end

        _tickConn = nil
    end

    S.bound = false
    deactivate()

    if Utils and type(Utils.setOnClashOn) == "function" then
        Utils.setOnClashOn(nil)
    end
end

function AutoClash.resetState()
    S.enabled = false
    S.lastTargetAt = 0
    S.lastTargetId = nil
    S.wasMeTarget = false
    S.lostMeAt = 0
    S.physDotEma = 0
    S._lastFire = 0

    deactivate()
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table" then
        if Utils and type(Utils.warn) == "function" then
            Utils.warn("AutoClash.setup precisa de tabela de deps")
        else
            warn("[Exodus] AutoClash.setup precisa de tabela de deps")
        end

        return false
    end

    if deps.GameInfo then
        GameInfo = deps.GameInfo
    end

    if deps.Utils then
        Utils = deps.Utils
    end

    if deps.AutoParry then
        AutoParry = deps.AutoParry
    end

    if deps.Remote then
        Remote = deps.Remote
    end

    if not (GameInfo and Utils and AutoParry) then
        local missing = {}

        if not GameInfo then
            missing[#missing + 1] = "GameInfo"
        end

        if not Utils then
            missing[#missing + 1] = "Utils"
        end

        if not AutoParry then
            missing[#missing + 1] = "AutoParry"
        end

        local msg = "AutoClash deps ausentes: " .. table.concat(missing, ", ")

        if Utils and type(Utils.warn) == "function" then
            Utils.warn(msg)
        else
            warn("[Exodus] " .. msg)
        end

        return false
    end

    _setupDone = true
    return true
end

-- API
function AutoClash.clashOn()
    return S.active == true
end

function AutoClash.getState()
    return {
        active = S.active,
        activeAt = S.activeAt,
        enabled = S.enabled,
        lastValidAt = S.lastValidAt,
    }
end

function AutoClash.evaluate(t, hr, ball, config)
    if not uiEnabled() then
        if S.enabled or S.active then
            S.enabled = false
            deactivate()
        end

        return
    end

    S.enabled = true

    if not (hr and hr.Parent) or not (ball and ball.Parent) then
        return
    end

    local ctx = getParryContext(t, hr, ball)

    if S.active then
        local radius = getDeactivationRadius(ctx)

        if isBallTargeted(ctx)
            and ballInRange(ctx.hr, ctx.ball, radius)
            and nearestInRange(ctx.hr, radius)
        then
            S.lastValidAt = t
        end

        if shouldDeactivate(t, ctx) then
            deactivate()
        end
    elseif tickPhysical(ctx) then
        activate(t)
    end
end

return AutoClash
