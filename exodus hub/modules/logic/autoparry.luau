-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

-- tuning
local Tuning = {

        -- radius
        DEFLECT_RADIUS = 8.5,
        PARRY_WINDOW = 0.160,
        MIN_BALL_SPEED = 7,
        RES_PER_PARRY = 0.225,
        RES_CAP_STUDS = 32,
        HITBOX_OWN_WINDOW = 0.5,
        HITBOX_PROXIMITY = 12,
        HITBOX_GAP = 0.4,

 -- movement
 STATIONARY_MULT = 1.50,
 STATIONARY_SPEED = 1.5,
 STATIONARY_DWELL = 0.20,

        -- local rate limit (must be < server CPS_LIMIT-derived threshold)
        LOCAL_FIRE_INTERVAL = 0.10,
}

local PING_SAMPLE_INTERVAL = 1.5
local DEFAULT_PING_ONE_WAY = 0.030
local TELEPORT_LOCK = 0.20
local PHASE_DETACHED = 1
local PHASE_WAITING = 2
local PHASE_COOLDOWN = 3
local PHASE_ARMED = 4
local PHASE_FIRED = 5
local PHASE_STRINGS = {
        [PHASE_DETACHED] = "detached",
        [PHASE_WAITING] = "waiting",
        [PHASE_COOLDOWN] = "cooldown",
        [PHASE_ARMED] = "armed",
        [PHASE_FIRED] = "fired",
}

local phaseString = PHASE_STRINGS[PHASE_DETACHED]
local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table" and namespace.AutoParryHitbox or {
        connection = nil,
        handler = nil,
}
namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- state
local ParryState = {
        armed = false,
        armedBall = nil,
        fired = false,
        firedBall = nil,
        firedAt = 0,
}

local Resilience = {
        stack = 0,
        lastFireBall = nil,
        lastFireAt = 0,
        lastHitboxAt = 0,
}

local Runtime = {
        generation = 0,
        localUserId = -1,
        lastTarget = -1,
        teleportLockUntil = 0,
        connections = {},
        minPing = nil,
        pingTimer = 0,
        pingOneWay = DEFAULT_PING_ONE_WAY,
        resilienceBonus = 0,
        resilienceBonusAt = -1,
        parryRadius = 0,
        stationary = false,
        stationarySince = 0,
        lastRootPos = nil,
        lastRootPosAt = 0,
        lastFireAt = 0,
        phase = PHASE_DETACHED,
        bound = false,
}

local Stats = game:GetService("Stats")
local PingItem = Stats.Network.ServerStatsItem["Data Ping"]

-- helpers
local function now()
        return Utils.now()
end
local function setPhase(phase, reason)
        if Runtime.phase == phase then
                return
        end
        local previous = Runtime.phase
        Runtime.phase = phase
        phaseString = PHASE_STRINGS[phase] or "detached"
        if Utils and type(Utils.recordTransition) == "function" then
                Utils.recordTransition("AutoParry", PHASE_STRINGS[previous] or "detached", phaseString, reason)
        end
end
local function clearArmed()
        ParryState.armed = false
        ParryState.armedBall = nil
end
local function clearFired()
        ParryState.fired = false
        ParryState.firedBall = nil
        ParryState.firedAt = 0
end
local function clearCycle()
        clearArmed()
        clearFired()
        Resilience.lastFireBall = nil
        Resilience.lastFireAt = 0
end
local function disconnectConnections()
        local connections = Runtime.connections
        for i = #connections, 1, -1 do
                local connection = connections[i]
                connections[i] = nil
                Utils.untrackCharacter(connection)
                pcall(connection.Disconnect, connection)
        end
end

-- ping
local function samplePing()
        local ok, ping = pcall(PingItem.GetValue, PingItem)
        ping = ok and ping / 1000 or nil
        if type(ping) ~= "number" or not Utils.isFiniteNumber(ping) or ping <= 0 or ping >= 0.5 then
                return
        end
        if not Runtime.minPing or ping < Runtime.minPing then
                Runtime.minPing = ping
                Runtime.pingOneWay = ping * 0.5
        end
end
local function getPingOneWay()
        return Runtime.pingOneWay
end

-- resilience
local function getResilienceBonus(time)
        if Runtime.resilienceBonusAt == time then
                return Runtime.resilienceBonus
        end
        Runtime.resilienceBonus = math.min(Resilience.stack * Tuning.RES_PER_PARRY, Tuning.RES_CAP_STUDS)
        Runtime.resilienceBonusAt = time
        return Runtime.resilienceBonus
end
local function resetResilience()
        Resilience.stack = 0
        Resilience.lastFireBall = nil
        Resilience.lastFireAt = 0
        Resilience.lastHitboxAt = 0
        Runtime.resilienceBonus = 0
        Runtime.resilienceBonusAt = -1
end

-- radius
local function computeParryRadius(time)
        time = Utils.isFiniteNumber(time) and time or now()
        return Tuning.DEFLECT_RADIUS + getResilienceBonus(time)
end

-- targeting
local function onBallSync(data)
        if typeof(data) ~= "table" then
                return
        end
        local time = now()
        if data.Teleported == true then
                Runtime.teleportLockUntil = time + TELEPORT_LOCK
                clearArmed()
                clearFired()
                Resilience.lastFireBall = nil
                Resilience.lastFireAt = 0
                return
        end
        local targetId = data.TargetPlayerID
        if not Utils.isFiniteNumber(targetId) then
                targetId = tonumber(targetId) or -1
        end
        if targetId == Runtime.lastTarget then
                return
        end
        local previousTarget = Runtime.lastTarget
        Runtime.lastTarget = targetId
        if targetId == Runtime.localUserId and previousTarget ~= Runtime.localUserId then
                clearFired()
        end
end
local function requestParry()
        local time = now()
        -- Local rate limit: don't fire faster than the server's CPS_LIMIT
        -- (so ClickInstances never grow past the threshold where the server
        -- silently drops all fires). Server cooldown is enforced by the game.
        if Runtime.lastFireAt and (time - Runtime.lastFireAt) < Tuning.LOCAL_FIRE_INTERVAL then
                return false
        end
        if not Remote.fireParry(1) then
                if Utils and type(Utils.recordError) == "function" then
                        Utils.recordError("AutoParry", "Remote.fireParry falhou")
                end
                setPhase(PHASE_WAITING, "remote_failed")
                return false
        end
        Runtime.lastFireAt = time
        setPhase(PHASE_FIRED, "parry_requested")
        local ball = GameInfo.getBall()
        if ball and ball.Parent then
                Resilience.lastFireBall = ball
                Resilience.lastFireAt = time
        else
                Resilience.lastFireBall = nil
                Resilience.lastFireAt = 0
        end
        return true
end

-- hitbox
local function handleHitbox(instance)
        if typeof(instance) ~= "Instance" or not Utils.isActive() or instance.Name ~= "HitboxGrow" then
                return
        end
        local time = now()
        if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW or time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP then
                return
        end
        local ball = Resilience.lastFireBall
        if not (ball and ball.Parent) then
                return
        end
        local ok, position, ballPosition = pcall(function()
                return instance.Position, ball.Position
        end)
        if not ok or typeof(position) ~= "Vector3" or typeof(ballPosition) ~= "Vector3" then
                return
        end
        local delta = ballPosition - position
        if delta:Dot(delta) > Tuning.HITBOX_PROXIMITY ^ 2 then
                return
        end
        Resilience.lastHitboxAt = time
        Resilience.stack = math.min(Resilience.stack + 1, math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY))
        Runtime.resilienceBonusAt = -1
end
local function installHitboxHook()
        if HitboxState.connection then
                return true
        end
        local workspaceService = Utils.getWorkspace()
        local ok, connection = pcall(function()
                return workspaceService.DescendantAdded:Connect(function(instance)
                        local handler = HitboxState.handler
                        if type(handler) == "function" then
                                handler(instance)
                        end
                end)
        end)
        if not ok or not connection then
                return false
        end
        HitboxState.connection = connection
        Utils.trackGlobal(connection)
        return true
end
local function bindCharacter(character)
        Runtime.generation += 1
        local generation = Runtime.generation
        Runtime.bound = false
        setPhase(PHASE_DETACHED, "rebind_start")
        disconnectConnections()
        clearCycle()
        if not (character and character.Parent) then
                return false
        end
        local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
        if generation ~= Runtime.generation or not (root and root.Parent) then
                return false
        end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then
                local connection = humanoid.Died:Connect(resetResilience)
                Runtime.connections[#Runtime.connections + 1] = connection
                Utils.trackCharacter(connection)
        end
        local getConfig = Utils.getConfig
        local isSpamActive = Utils.isSpamActive
        local heartbeat = Utils.getRunService().Heartbeat
        local heartbeatConnection = heartbeat:Connect(function(dt)
                if generation ~= Runtime.generation or not (character.Parent and root.Parent) then
                        return
                end
                local config = getConfig()
                if config.AutoParry ~= true then
                        clearCycle()
                        setPhase(PHASE_WAITING, "disabled_or_locked")
                        return
                end
                local timeNow = now()
                if timeNow < Runtime.teleportLockUntil then
                        clearCycle()
                        setPhase(PHASE_WAITING, "disabled_or_locked")
                        return
                end
                if isSpamActive() then
                        clearCycle()
                        setPhase(PHASE_WAITING, "spam_active")
                        return
                end
                Runtime.pingTimer += math.max(dt, 0)
                if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then
                        Runtime.pingTimer = 0
                        samplePing()
                end
                local snapshot = GameInfo.getSnapshot(Runtime.lastTarget, timeNow)
                if not GameInfo.isSnapshotValid(snapshot, timeNow) then
                        setPhase(PHASE_WAITING, "snapshot_invalid")
                        return
                end
                local ball = snapshot.ball
                local targeted = snapshot.targeted == true
                local deflectCooldown = GameInfo.getDeflectCD()
                if ParryState.armed then
                        if not (ball and ball.Parent and ball == ParryState.armedBall and targeted) then
                                clearArmed()
                                setPhase(PHASE_WAITING, "armed_context_invalid")
                        elseif deflectCooldown > 0 then
                                setPhase(PHASE_COOLDOWN, "deflect_cooldown")
                                return
                        else
                                if requestParry() then
                                        ParryState.fired = true
                                        ParryState.firedBall = ball
                                        ParryState.firedAt = timeNow
                                end
                                clearArmed()
                                return
                        end
                end
                if not (ball and ball.Parent and targeted) then
                        setPhase(PHASE_WAITING, "ball_or_target_invalid")
                        return
                end
                local speed = snapshot.speed
                if speed < Tuning.MIN_BALL_SPEED then
                        setPhase(PHASE_WAITING, "ball_too_slow")
                        return
                end
                local position = snapshot.position
                if not position then
                        setPhase(PHASE_WAITING, "position_unavailable")
                        return
                end
                local parryRadius = computeParryRadius(timeNow)
                local rootPos = root.Position
                local parryWindow = Tuning.PARRY_WINDOW
                do
                        local dtRoot = math.max(timeNow - Runtime.lastRootPosAt, 0)
                        local rootVel = Vector3.zero
                        if Runtime.lastRootPos and dtRoot > 0 then
                                rootVel = (rootPos - Runtime.lastRootPos) / dtRoot
                        end
                        Runtime.lastRootPos = rootPos
                        Runtime.lastRootPosAt = timeNow
                        local horizontalVel = Vector3.new(rootVel.X, 0, rootVel.Z)
                        local horizontalSpeed = horizontalVel.Magnitude
                        if horizontalSpeed < Tuning.STATIONARY_SPEED then
                                if Runtime.stationarySince == 0 then
                                        Runtime.stationarySince = timeNow
                                end
                        else
                                Runtime.stationarySince = 0
                        end
                        local isStationary = Runtime.stationarySince > 0 and (timeNow - Runtime.stationarySince) >= Tuning.STATIONARY_DWELL
                        Runtime.stationary = isStationary
                        if isStationary then
                                parryWindow = Tuning.PARRY_WINDOW * Tuning.STATIONARY_MULT
                        end
                end
                local effectiveParryRadius = parryRadius + speed * parryWindow
                Runtime.parryRadius = effectiveParryRadius
                local delta = root.Position - position
                local distanceSquared = delta:Dot(delta)
                local distance = math.sqrt(distanceSquared)
                local tti = math.max(0, (distance - parryRadius) / speed)
                if tti > parryWindow then
                        setPhase(PHASE_WAITING, "outside_ping_window")
                        return
                end
                if deflectCooldown > 0 then
                        ParryState.armed = true
                        ParryState.armedBall = ball
                        setPhase(PHASE_ARMED, "awaiting_deflect_cooldown")
                        return
                end
                -- cooldown zered: clear any stale fired lock so we can retry.
                -- without this, if we missed (server rejected) and the ball
                -- stayed on us, ParryState.fired would stay true forever and
                -- the app would never click again until the target switched.
                clearFired()
                if ParryState.fired and ParryState.firedBall == ball then
                        setPhase(PHASE_WAITING, "ball_already_fired")
                        return
                end
                if requestParry() then
                        ParryState.fired = true
                        ParryState.firedBall = ball
                        ParryState.firedAt = timeNow
                end
        end)
        Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
        Utils.trackCharacter(heartbeatConnection)
        local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
                if not parent then
                        Runtime.generation += 1
                end
        end)
        Runtime.connections[#Runtime.connections + 1] = ancestryConnection
        Utils.trackCharacter(ancestryConnection)
        Runtime.bound = true
        setPhase(PHASE_WAITING, "character_bound")
        return true
end

-- lifecycle
local function resetState()
        clearCycle()
        Runtime.teleportLockUntil = 0
        Runtime.lastTarget = -1
        Runtime.pingTimer = 0
        Runtime.minPing = nil
        Runtime.pingOneWay = DEFAULT_PING_ONE_WAY
        Runtime.parryRadius = 0
        Runtime.stationary = false
        Runtime.stationarySince = 0
        Runtime.lastRootPos = nil
        Runtime.lastRootPosAt = 0
        Runtime.bound = false
        setPhase(PHASE_DETACHED, "reset")
end

-- setup
function AutoParry.setup(deps)
        if type(deps) ~= "table" or type(deps.Remote) ~= "table" or type(deps.Remote.fireParry) ~= "function" or type(deps.GameInfo) ~= "table" or type(deps.GameInfo.getDeflectCD) ~= "function" or type(deps.GameInfo.getBall) ~= "function" or type(deps.GameInfo.getSnapshot) ~= "function" or type(deps.GameInfo.isSnapshotValid) ~= "function" or type(deps.Utils) ~= "table" or type(deps.Utils.now) ~= "function" or type(deps.Utils.apiVersion) ~= "function" or type(deps.Utils.isFiniteNumber) ~= "function" or type(deps.Utils.getConfig) ~= "function" or type(deps.Utils.getLocalPlayer) ~= "function" or type(deps.Utils.getWorkspace) ~= "function" or type(deps.Utils.getRunService) ~= "function" or type(deps.Utils.trackCharacter) ~= "function" or type(deps.Utils.untrackCharacter) ~= "function" or type(deps.Utils.trackGlobal) ~= "function" or type(deps.Utils.isActive) ~= "function" or type(deps.Utils.isSpamActive) ~= "function" then
                return false, "dependência ausente: Remote.fireParry, GameInfo, Utils ou uma API obrigatória"
        end
        Remote = deps.Remote
        GameInfo = deps.GameInfo
        Utils = deps.Utils
        local localPlayer = Utils.getLocalPlayer()
        Runtime.localUserId = localPlayer and localPlayer.UserId or -1
        HitboxState.handler = handleHitbox
        resetResilience()
        resetState()
        if not installHitboxHook() then
                Utils.warn("hook de hitbox indisponível")
        end
        return true
end
function AutoParry.fire()
        return requestParry()
end
function AutoParry.bindCharacter(character)
        return bindCharacter(character)
end
function AutoParry.resetState()
        resetState()
end
function AutoParry.detachCharacter()
        Runtime.generation += 1
        Runtime.bound = false
        disconnectConnections()
        resetState()
end
function AutoParry.onBallSync(data)
        onBallSync(data)
end
function AutoParry.getParryRadius()
        return Runtime.parryRadius
end
function AutoParry.getPingOneWay()
        return Runtime.pingOneWay
end
function AutoParry.getStatus()
        return {
                schema = Utils.apiVersion(),
                phase = phaseString,
                bound = Runtime.bound == true,
                armed = ParryState.armed == true,
                fired = ParryState.fired == true,
                resilienceStack = Resilience.stack,
                parryRadius = Runtime.parryRadius,
                stationary = Runtime.stationary == true,
        }
end
AutoParry.__contract = {
        requires = {
                Remote = "remote",
                GameInfo = "gameinfo",
                Utils = "utils",
        },
        onBallSync = true,
        bindCharacter = true,
}

return AutoParry