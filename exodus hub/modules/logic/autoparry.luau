-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils, StatsService
local TargetTracker

-- tuning
local Tuning = {
        DEFLECT_RADIUS = 8.5,

        MIN_BALL_SPEED = 16,

        RES_PER_PARRY = 0.225,
        RES_CAP_STUDS = 32,

        HITBOX_OWN_WINDOW = 0.5,
        HITBOX_PROXIMITY = 12,
        HITBOX_GAP = 0.4,

        -- window:
        -- 16 spd  = 820 ms
        -- 600 spd = 200 ms
        -- above 600: continues linearly downward
        WINDOW_LOW_SPEED = 16,
        WINDOW_LOW = 0.820,

        WINDOW_REFERENCE_SPEED = 600,
        WINDOW_REFERENCE = 0.200,

        -- what is actually used for the click
        WINDOW_FACTOR = 0.7,

        -- ping remains separate from the window
        PING_WINDOW_FACTOR = 1,
        PING_WINDOW_CAP = 0.400,

        CLIENT_CD_PROPAGATION = 0.30,

        PING_SAMPLE_INTERVAL = 0.35,
        PING_EMA_ALPHA = 0.08,
        DEFAULT_PING_ONE_WAY = 0.030,

        TELEPORT_LOCK_BASE = 0.400,
        TARGET_DEBOUNCE = 0.180,
}

local WINDOW_SLOPE =
        (Tuning.WINDOW_REFERENCE - Tuning.WINDOW_LOW)
        / (Tuning.WINDOW_REFERENCE_SPEED - Tuning.WINDOW_LOW_SPEED)

local MAX_RES_STACK = math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY)
local HITBOX_PROXIMITY_SQ = Tuning.HITBOX_PROXIMITY * Tuning.HITBOX_PROXIMITY

local PHASE_DETACHED = 1
local PHASE_WAITING = 2
local PHASE_COOLDOWN = 3
local PHASE_FIRED = 4

local PHASE_STRINGS = {
        [PHASE_DETACHED] = "detached",
        [PHASE_WAITING] = "waiting",
        [PHASE_COOLDOWN] = "cooldown",
        [PHASE_FIRED] = "fired",
}

local phaseString = "detached"

local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}

local HitboxState =
        type(namespace.AutoParryHitbox) == "table"
        and namespace.AutoParryHitbox
        or {
                connection = nil,
                handler = nil,
        }

namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

local Resilience = {
        stack = 0,
        lastFireBall = nil,
        lastFireAt = 0,
        lastHitboxAt = 0,
        hitboxConfirmed = false,
        lifeGeneration = 0,
}

local Runtime = {
        generation = 0,
        lifeGeneration = 0,
        alive = false,
        bound = false,

        localUserId = -1,
        player = nil,
        character = nil,
        root = nil,
        workspace = nil,

        lastTarget = -1,
        lastWasMe = nil,
        targetId = -1,
        targetKnown = false,

        teleportLockUntil = 0,

        connections = {},

        pingTimer = 0,
        pingOneWay = Tuning.DEFAULT_PING_ONE_WAY,
        minPing = nil,

        resilienceBonus = 0,
        resilienceBonusAt = -1,

        parryRadius = 0,
        baseParryRadius = Tuning.DEFLECT_RADIUS,
        noWindowParryRadius = Tuning.DEFLECT_RADIUS,
        pingRadius = 0,

        deflectWindow = 0,
        effectiveWindow = 0,

        lastTTI = math.huge,
        lastDistance = 0,
        lastDistanceToParryRadius = 0,
        lastSpeed = 0,

        lastFireAt = 0,
        cooldownObservedAt = 0,

        phase = PHASE_DETACHED,

        passivePhase = "idle",
        passiveCycleStart = 0,
        passiveBallAtValid = false,
}

-- HELPERS

local function now()
        return Utils and Utils.now and Utils.now() or os.clock()
end

local function setPhase(phase, reason)
        if Runtime.phase == phase then
                return
        end

        local old = Runtime.phase
        Runtime.phase = phase
        phaseString = PHASE_STRINGS[phase] or "detached"

        if Utils and Utils.recordTransition then
                Utils.recordTransition(
                        "AutoParry",
                        PHASE_STRINGS[old] or "detached",
                        phaseString,
                        reason
                )
        end
end

local function isValidBall(ball)
        return ball ~= nil and ball.Parent ~= nil
end

local function disconnectConnections()
        for i = #Runtime.connections, 1, -1 do
                local connection = Runtime.connections[i]
                Runtime.connections[i] = nil

                if connection then
                        if Utils and Utils.untrackCharacter then
                                pcall(Utils.untrackCharacter, connection)
                        end

                        pcall(function()
                                connection:Disconnect()
                        end)
                end
        end
end

local function distanceSquared(a, b)
        local x = a.X - b.X
        local y = a.Y - b.Y
        local z = a.Z - b.Z

        return x * x + y * y + z * z
end

-- RESILIENCE

local function resetResilience()
        Resilience.stack = 0
        Resilience.lastFireBall = nil
        Resilience.lastFireAt = 0
        Resilience.lastHitboxAt = 0
        Resilience.hitboxConfirmed = false
        Resilience.lifeGeneration = Runtime.lifeGeneration

        Runtime.resilienceBonus = 0
        Runtime.resilienceBonusAt = -1
end

local function invalidateLife()
        Runtime.lifeGeneration += 1
        Runtime.alive = false
        Runtime.bound = false

        TargetTracker.reset("life_invalidated")
        resetResilience()
end

local function isResilienceUsable()
        if
                not Runtime.alive
                or not Runtime.bound
                or Resilience.lifeGeneration ~= Runtime.lifeGeneration
        then
                Resilience.stack = 0
                Resilience.lastFireBall = nil
                Resilience.lastFireAt = 0
                Resilience.lastHitboxAt = 0

                Runtime.resilienceBonus = 0
                Runtime.resilienceBonusAt = Runtime.lifeGeneration

                return false
        end

        local stack = Resilience.stack

        if
                type(stack) ~= "number"
                or stack < 0
                or stack > MAX_RES_STACK
        then
                Resilience.stack = 0
                Runtime.resilienceBonus = 0
                Runtime.resilienceBonusAt = Runtime.lifeGeneration

                return false
        end

        return true
end

local function getResilienceBonus(time)
        if not isResilienceUsable() then
                return 0
        end

        if Runtime.resilienceBonusAt == time then
                return Runtime.resilienceBonus
        end

        Runtime.resilienceBonus =
                math.min(
                        Resilience.stack * Tuning.RES_PER_PARRY,
                        Tuning.RES_CAP_STUDS
                )

        Runtime.resilienceBonusAt = time

        return Runtime.resilienceBonus
end

-- PING

local function samplePing()
        if not StatsService then
                return
        end

        local ok, item = pcall(function()
                return StatsService.Network.ServerStatsItem["Data Ping"]
        end)

        if not ok or not item then
                return
        end

        local valid, ping = pcall(item.GetValue, item)

        if not valid or type(ping) ~= "number" then
                return
        end

        ping *= 0.001

        if
                ping <= 0
                or ping >= 0.5
                or not Utils.isFiniteNumber(ping)
        then
                return
        end

        if not Runtime.minPing or ping < Runtime.minPing then
                Runtime.minPing = ping
        end

        -- Preserve the existing EMA/ping system.
        local oneWay = ping * 0.5

        Runtime.pingOneWay +=
                (oneWay - Runtime.pingOneWay)
                * Tuning.PING_EMA_ALPHA
end

-- TIMING

-- Fixed two-point timing.
-- No inverse curve, no A/B curve, no low-speed multiplier.
--
-- 16 speed  -> 0.820 s
-- 600 speed -> 0.200 s
-- >600      -> keeps decreasing linearly.
local function computeDeflectWindow(speed)
        local raw = tonumber(speed) or 0

        if raw <= Tuning.WINDOW_LOW_SPEED then
                return Tuning.WINDOW_LOW
        end

        local window =
                Tuning.WINDOW_LOW
                + (raw - Tuning.WINDOW_LOW_SPEED) * WINDOW_SLOPE

        return math.max(window, 0)
end

local function computePingRadius(speed)
        local rawSpeed = tonumber(speed) or 0

        if rawSpeed <= 0 then
                return 0
        end

        return rawSpeed
                * math.min(
                        Runtime.pingOneWay
                                * 2
                                * Tuning.PING_WINDOW_FACTOR,
                        Tuning.PING_WINDOW_CAP
                )
end

local function computeNoWindowParryRadius(speed, resilience)
        return Tuning.DEFLECT_RADIUS
                + (resilience or 0)
                + computePingRadius(speed)
end

local function computeTiming(rootPosition, position, speed, time)
        if
                typeof(rootPosition) ~= "Vector3"
                or typeof(position) ~= "Vector3"
                or type(speed) ~= "number"
                or speed <= 0
        then
                return nil
        end

        local resilience = getResilienceBonus(time)

        -- Base window is the fixed 16 -> 600 timing.
        local deflectWindow = computeDeflectWindow(speed)

        -- Only the window used for the actual click is reduced by 0.45x.
        local effectiveWindow =
                deflectWindow * Tuning.WINDOW_FACTOR

        -- Ping stays separate from the 0.45x click multiplier.
        local pingRadius = computePingRadius(speed)

        local noWindowParryRadius =
                computeNoWindowParryRadius(
                        speed,
                        resilience
                )

        local parryRadius =
                Tuning.DEFLECT_RADIUS
                + resilience
                + pingRadius
                + speed * effectiveWindow

        local distSq =
                distanceSquared(
                        rootPosition,
                        position
                )

        local distance = math.sqrt(distSq)

        local delta =
                distance - parryRadius

        local tti =
                delta <= 0
                and 0
                or delta / speed

        return {
                parryRadius = parryRadius,

                pureRadius = Tuning.DEFLECT_RADIUS,

                noWindowParryRadius = noWindowParryRadius,

                pingRadius = pingRadius,

                resilienceBonus = resilience,

                deflectWindow = deflectWindow,

                effectiveWindow = effectiveWindow,

                tti = tti,

                speed = speed,

                distance = distance,

                distanceSquared = distSq,

                distanceToParryRadius = delta,

                pingOneWay = Runtime.pingOneWay,

                stationary = false,
        }
end

local function getSnapshot(time)
        local snapshot = GameInfo.getSnapshot(nil, time)

        if
                type(snapshot) ~= "table"
                or not GameInfo.isSnapshotValid(snapshot, time)
        then
                return nil
        end

        return snapshot
end

local function isBallInParryWindow(time)
        local snapshot = getSnapshot(time)

        if not snapshot then
                return false, false
        end

        local ball = snapshot.ball

        if not isValidBall(ball) then
                return false, false
        end

        local speed = tonumber(snapshot.speed)

        if
                not speed
                or speed < Tuning.MIN_BALL_SPEED
                or not Utils.isFiniteNumber(speed)
        then
                return false, false
        end

        local position = snapshot.position
        local root = Runtime.root

        if
                typeof(position) ~= "Vector3"
                or not root
                or not root.Parent
        then
                return false, false
        end

        local timing =
                computeTiming(
                        root.Position,
                        position,
                        speed,
                        time
                )

        if not timing then
                return false, false
        end

        return (
                timing.distance <= timing.parryRadius
        ), true
end

-- PARRY

local function requestParry(ball)
        if not Runtime.alive or not Runtime.bound then
                return false
        end

        if
                not Remote
                or type(Remote.fireParry) ~= "function"
        then
                if Utils and Utils.recordError then
                        Utils.recordError(
                                "AutoParry",
                                "Remote.fireParry indisponivel"
                        )
                end

                setPhase(
                        PHASE_WAITING,
                        "remote_unavailable"
                )

                return false
        end

        local time = now()

        local ok = pcall(
                Remote.fireParry,
                1
        )

        if not ok then
                if Utils and Utils.recordError then
                        Utils.recordError(
                                "AutoParry",
                                "Remote.fireParry falhou"
                        )
                end

                setPhase(
                        PHASE_WAITING,
                        "remote_failed"
                )

                return false
        end

        Runtime.lastFireAt = time
        Runtime.cooldownObservedAt = 0

        if Resilience.hitboxConfirmed then
                Resilience.hitboxConfirmed = false
        end

        local firedBall = ball

        if not isValidBall(firedBall) then
                local okBall, currentBall =
                        pcall(GameInfo.getBall)

                if okBall then
                        firedBall = currentBall
                end
        end

        if
                isValidBall(firedBall)
                and Runtime.alive
                and Runtime.bound
                and Resilience.lifeGeneration
                        == Runtime.lifeGeneration
        then
                Resilience.lastFireBall = firedBall
                Resilience.lastFireAt = time
        else
                Resilience.lastFireBall = nil
                Resilience.lastFireAt = 0
        end

        setPhase(
                PHASE_FIRED,
                "parry_requested"
        )

        return true
end

-- PARRY SLOT

local SLOT_OPEN = "open"
local SLOT_LOCKED = "locked"

local ParrySlot = {}
ParrySlot.__index = ParrySlot

local function newSlot(generation)
        return setmetatable({
                generation = generation,
                state = SLOT_OPEN,
                destroyed = false,
                createdAt = now(),
                lockedAt = 0,
        }, ParrySlot)
end

function ParrySlot:isLocked()
        return self.state == SLOT_LOCKED
end

function ParrySlot:lock()
        if
                self.destroyed
                or self.state == SLOT_LOCKED
        then
                return
        end

        self.state = SLOT_LOCKED
        self.lockedAt = now()
end

function ParrySlot:destroy()
        self.destroyed = true
end

-- TARGET TRACKER

TargetTracker = {
        generation = 0,
        confirmed = false,
        pendingLost = nil,
        currentSlot = nil,
}

local function destroySlot()
        local slot = TargetTracker.currentSlot
        TargetTracker.currentSlot = nil

        if slot then
                slot:destroy()
        end
end

function TargetTracker.observe(isMe, at)
        local time = tonumber(at) or now()

        if isMe then
                if TargetTracker.pendingLost then
                        TargetTracker.pendingLost = nil
                end

                if TargetTracker.confirmed then
                        return
                end

                TargetTracker.confirmed = true
                TargetTracker.generation += 1
                TargetTracker.currentSlot =
                        newSlot(
                                TargetTracker.generation
                        )

                return
        end

        if not TargetTracker.confirmed then
                return
        end

        if TargetTracker.pendingLost then
                return
        end

        TargetTracker.pendingLost = {
                startedAt = time,
                expiresAt =
                        time + Tuning.TARGET_DEBOUNCE,
        }
end

function TargetTracker.tick(time)
        local pending =
                TargetTracker.pendingLost

        if not pending then
                return
        end

        if
                (tonumber(time) or now())
                        < pending.expiresAt
        then
                return
        end

        TargetTracker.pendingLost = nil
        TargetTracker.confirmed = false

        destroySlot()
end

function TargetTracker.reset()
        TargetTracker.confirmed = false
        TargetTracker.pendingLost = nil

        destroySlot()
end

function TargetTracker.getStatus()
        local pending =
                TargetTracker.pendingLost

        local slot =
                TargetTracker.currentSlot

        return {
                confirmed =
                        TargetTracker.confirmed == true,

                generation =
                        TargetTracker.generation,

                debounce =
                        Tuning.TARGET_DEBOUNCE,

                pendingLost =
                        pending ~= nil,

                pendingLostIn =
                        pending
                        and math.max(
                                pending.expiresAt - now(),
                                0
                        )
                        or 0,

                slot =
                        slot
                        and {
                                generation =
                                        slot.generation,

                                state =
                                        slot.state,

                                locked =
                                        slot:isLocked(),

                                createdAt =
                                        slot.createdAt,

                                lockedAt =
                                        slot.lockedAt,
                        }
                        or nil,
        }
end

-- SYNC

local function onBallSync(data)
        if
                typeof(data) ~= "table"
                or not Runtime.alive
                or not Runtime.bound
        then
                return
        end

        local time = now()

        if data.Teleported == true then
                Runtime.teleportLockUntil =
                        math.max(
                                Runtime.teleportLockUntil,
                                time
                                        + Tuning.TELEPORT_LOCK_BASE
                                        + Runtime.pingOneWay
                        )

                TargetTracker.reset()

                Runtime.passivePhase = "idle"
                Runtime.passiveBallAtValid = false

                setPhase(
                        PHASE_WAITING,
                        "teleport_lock"
                )

                return
        end

        local targetId =
                tonumber(data.TargetPlayerID)
                or -1

        Runtime.targetId = targetId
        Runtime.targetKnown = true

        local previousTarget =
                Runtime.lastTarget

        local previousWasMe =
                Runtime.lastWasMe

        if
                targetId == previousTarget
                and previousWasMe ~= nil
        then
                if
                        Utils.isSpamActive()
                        and Runtime.passivePhase
                                == "awaiting_leave"
                then
                        local inside, valid =
                                isBallInParryWindow(time)

                        if valid and inside then
                                Runtime.passiveBallAtValid = true
                        end
                end

                return
        end

        Runtime.lastTarget = targetId

        local isMe =
                targetId == Runtime.localUserId

        Runtime.lastWasMe = isMe

        if Utils.isSpamActive() then
                if not isMe then
                        if
                                Runtime.passivePhase
                                        == "awaiting_leave"
                        then
                                if
                                        Runtime.passiveBallAtValid
                                        and isResilienceUsable()
                                then
                                        Resilience.stack =
                                                math.min(
                                                        Resilience.stack + 1,
                                                        MAX_RES_STACK
                                                )

                                        Runtime.resilienceBonusAt =
                                                -1
                                end

                                Runtime.passivePhase = "idle"
                                Runtime.passiveBallAtValid = false
                        end
                else
                        if previousWasMe ~= true then
                                Runtime.passivePhase =
                                        "awaiting_leave"

                                Runtime.passiveCycleStart =
                                        time

                                local inside, valid =
                                        isBallInParryWindow(time)

                                Runtime.passiveBallAtValid =
                                        valid and inside
                        else
                                local inside, valid =
                                        isBallInParryWindow(time)

                                if valid and inside then
                                        Runtime.passiveBallAtValid =
                                                true
                                end
                        end
                end
        else
                Runtime.passivePhase = "idle"
                Runtime.passiveBallAtValid = false
        end

        TargetTracker.observe(
                isMe,
                time
        )
end

-- HEARTBEAT

local function onHeartbeat(
        character,
        root,
        getConfig,
        isSpamActive,
        getSnapshotRef,
        isSnapshotValid,
        finite,
        dt
)
        if
                not character.Parent
                or not root.Parent
        then
                return
        end

        local timeNow = now()

        local config = getConfig()

        if
                type(config) ~= "table"
                or config.AutoParry ~= true
        then
                TargetTracker.reset()
                return
        end

        if
                timeNow < Runtime.teleportLockUntil
        then
                TargetTracker.reset()
                return
        end

        if isSpamActive() then
                TargetTracker.reset()
                return
        end

        Runtime.pingTimer +=
                math.max(dt, 0)

        if
                Runtime.pingTimer
                        >= Tuning.PING_SAMPLE_INTERVAL
        then
                Runtime.pingTimer = 0
                samplePing()
        end

        TargetTracker.tick(timeNow)

        local snapshot =
                getSnapshotRef(
                        nil,
                        timeNow
                )

        if
                type(snapshot) ~= "table"
                or not isSnapshotValid(
                        snapshot,
                        timeNow
                )
        then
                return
        end

        local targeted =
                snapshot.targeted == true

        Runtime.targetId =
                tonumber(snapshot.targetId)
                or -1

        Runtime.targetKnown =
                snapshot.targetId ~= nil

        Runtime.lastTarget =
                tonumber(snapshot.targetId)
                or -1

        TargetTracker.observe(
                targeted,
                timeNow
        )

        if not targeted then
                setPhase(
                        PHASE_WAITING,
                        "not_targeted"
                )

                return
        end

        local ball = snapshot.ball

        if not isValidBall(ball) then
                return
        end

        local speed =
                tonumber(snapshot.speed)

        if
                not speed
                or speed < Tuning.MIN_BALL_SPEED
                or not finite(speed)
        then
                return
        end

        local position =
                snapshot.position

        if typeof(position) ~= "Vector3" then
                return
        end

        local deflectCooldown =
                tonumber(
                        GameInfo.getDeflectCD()
                )
                or 0

        if deflectCooldown > 0 then
                if Runtime.cooldownObservedAt <= 0 then
                        Runtime.cooldownObservedAt =
                                timeNow
                end

                if
                        timeNow
                                - Runtime.cooldownObservedAt
                                >= Tuning.CLIENT_CD_PROPAGATION
                then
                        setPhase(
                                PHASE_COOLDOWN,
                                "cooldown_propagation"
                        )
                else
                        setPhase(
                                PHASE_COOLDOWN,
                                "cooldown_observed"
                        )
                end

                return
        end

        Runtime.cooldownObservedAt = 0

        local timing =
                computeTiming(
                        root.Position,
                        position,
                        speed,
                        timeNow
                )

        if not timing then
                return
        end

        Runtime.parryRadius =
                timing.parryRadius

        Runtime.baseParryRadius =
                timing.pureRadius

        Runtime.noWindowParryRadius =
                timing.noWindowParryRadius

        Runtime.pingRadius =
                timing.pingRadius

        Runtime.resilienceBonus =
                timing.resilienceBonus

        Runtime.deflectWindow =
                timing.deflectWindow

        Runtime.effectiveWindow =
                timing.effectiveWindow

        Runtime.lastTTI =
                timing.tti

        Runtime.lastDistance =
                timing.distance

        Runtime.lastDistanceToParryRadius =
                timing.distanceToParryRadius

        Runtime.lastSpeed =
                timing.speed

        if
                timing.distance
                        > timing.parryRadius
        then
                setPhase(
                        PHASE_WAITING,
                        "outside_radius"
                )

                return
        end

        local slot =
                TargetTracker.currentSlot

        if
                not slot
                or slot:isLocked()
        then
                return
        end

        if not requestParry(ball) then
                return
        end

        slot:lock()
end

-- HITBOX

local function handleHitbox(instance)
        if
                typeof(instance) ~= "Instance"
                or instance.Name ~= "HitboxGrow"
                or not Utils.isActive()
                or Resilience.hitboxConfirmed
        then
                return
        end

        if not isResilienceUsable() then
                return
        end

        local time = now()

        if
                time - Resilience.lastFireAt
                        > Tuning.HITBOX_OWN_WINDOW
                or time - Resilience.lastHitboxAt
                        < Tuning.HITBOX_GAP
        then
                return
        end

        local ball =
                Resilience.lastFireBall

        if not isValidBall(ball) then
                return
        end

        local position = instance.Position
        local ballPosition = ball.Position

        if
                typeof(position) ~= "Vector3"
                or typeof(ballPosition) ~= "Vector3"
        then
                return
        end

        if
                distanceSquared(
                        ballPosition,
                        position
                ) > HITBOX_PROXIMITY_SQ
        then
                return
        end

        if
                not Runtime.alive
                or not Runtime.bound
                or Resilience.lifeGeneration
                        ~= Runtime.lifeGeneration
        then
                return
        end

        Resilience.hitboxConfirmed = true
        Resilience.lastHitboxAt = time

        Resilience.stack =
                math.min(
                        Resilience.stack + 1,
                        MAX_RES_STACK
                )

        Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
        if HitboxState.connection then
                return true
        end

        local workspaceService =
                Runtime.workspace

        if not workspaceService then
                return false
        end

        local ok, connection =
                pcall(function()
                        return workspaceService.DescendantAdded:Connect(
                                function(instance)
                                        local handler =
                                                HitboxState.handler

                                        if handler then
                                                handler(instance)
                                        end
                                end
                        )
                end)

        if not ok or not connection then
                return false
        end

        HitboxState.connection = connection

        Utils.trackGlobal(connection)

        return true
end

-- CHARACTER

local function bindCharacter(character)
        if
                not Remote
                or not GameInfo
                or not Utils
        then
                return false,
                        "dependencias nao inicializadas"
        end

        Runtime.generation += 1

        local generation =
                Runtime.generation

        disconnectConnections()
        invalidateLife()

        setPhase(
                PHASE_DETACHED,
                "rebind_start"
        )

        if not character or not character.Parent then
                return false
        end

        local root =
                character:FindFirstChild(
                        "HumanoidRootPart"
                )

        if not root then
                root =
                        character:WaitForChild(
                                "HumanoidRootPart",
                                1
                        )
        end

        if
                generation ~= Runtime.generation
                or not root
                or not root.Parent
        then
                return false
        end

        local humanoid =
                character:FindFirstChildOfClass(
                        "Humanoid"
                )

        if
                humanoid
                and humanoid.Health <= 0
        then
                return false
        end

        Runtime.character = character
        Runtime.root = root

        if humanoid then
                local diedConnection =
                        humanoid.Died:Connect(
                                function()
                                        if
                                                generation
                                                        ~= Runtime.generation
                                        then
                                                return
                                        end

                                        Runtime.generation += 1
                                        invalidateLife()

                                        setPhase(
                                                PHASE_DETACHED,
                                                "character_died"
                                        )
                                end
                        )

                Runtime.connections[
                        #Runtime.connections + 1
                ] = diedConnection

                Utils.trackCharacter(
                        diedConnection
                )
        end

        local runService =
                Utils.getRunService()

        local heartbeat =
                runService.Heartbeat

        local getConfig =
                Utils.getConfig

        local isSpamActive =
                Utils.isSpamActive

        local getSnapshotRef =
                GameInfo.getSnapshot

        local isSnapshotValid =
                GameInfo.isSnapshotValid

        local finite =
                Utils.isFiniteNumber

        local heartbeatConnection =
                heartbeat:Connect(
                        function(dt)
                                if
                                        generation
                                                ~= Runtime.generation
                                        or not Runtime.alive
                                        or not Runtime.bound
                                then
                                        return
                                end

                                onHeartbeat(
                                        character,
                                        root,
                                        getConfig,
                                        isSpamActive,
                                        getSnapshotRef,
                                        isSnapshotValid,
                                        finite,
                                        dt
                                )
                        end
                )

        Runtime.connections[
                #Runtime.connections + 1
        ] = heartbeatConnection

        Utils.trackCharacter(
                heartbeatConnection
        )

        local ancestryConnection =
                character.AncestryChanged:Connect(
                        function(_, parent)
                                if
                                        not parent
                                        and generation
                                                == Runtime.generation
                                then
                                        Runtime.generation += 1

                                        invalidateLife()
                                        disconnectConnections()

                                        Runtime.character = nil
                                        Runtime.root = nil

                                        setPhase(
                                                PHASE_DETACHED,
                                                "character_removed"
                                        )
                                end
                        end
                )

        Runtime.connections[
                #Runtime.connections + 1
        ] = ancestryConnection

        Utils.trackCharacter(
                ancestryConnection
        )

        Runtime.bound = true
        Runtime.alive = true

        Resilience.lifeGeneration =
                Runtime.lifeGeneration

        setPhase(
                PHASE_WAITING,
                "character_bound"
        )

        return true
end

-- RESET

local function resetState()
        invalidateLife()

        Runtime.teleportLockUntil = 0

        Runtime.lastTarget = -1
        Runtime.lastWasMe = nil

        Runtime.targetId = -1
        Runtime.targetKnown = false

        Runtime.pingTimer = 0
        Runtime.minPing = nil
        Runtime.pingOneWay =
                Tuning.DEFAULT_PING_ONE_WAY

        Runtime.parryRadius = 0

        Runtime.baseParryRadius =
                Tuning.DEFLECT_RADIUS

        Runtime.noWindowParryRadius =
                Tuning.DEFLECT_RADIUS

        Runtime.pingRadius = 0
        Runtime.resilienceBonus = 0
        Runtime.resilienceBonusAt = -1

        Runtime.deflectWindow = 0
        Runtime.effectiveWindow = 0

        Runtime.lastTTI = math.huge
        Runtime.lastDistance = 0
        Runtime.lastDistanceToParryRadius = 0
        Runtime.lastSpeed = 0

        Runtime.lastFireAt = 0
        Runtime.cooldownObservedAt = 0

        setPhase(
                PHASE_DETACHED,
                "reset"
        )
end

-- SETUP

function AutoParry.setup(deps)
        if type(deps) ~= "table" then
                return false,
                        "dependencias invalidas"
        end

        local remote = deps.Remote
        local gameInfo = deps.GameInfo
        local utils = deps.Utils

        if
                type(remote) ~= "table"
                or type(remote.fireParry) ~= "function"
        then
                return false,
                        "dependencia ausente: Remote.fireParry"
        end

        if
                type(gameInfo) ~= "table"
                or type(gameInfo.getDeflectCD)
                        ~= "function"
                or type(gameInfo.getBall)
                        ~= "function"
                or type(gameInfo.getSnapshot)
                        ~= "function"
                or type(gameInfo.isSnapshotValid)
                        ~= "function"
        then
                return false,
                        "dependencia ausente: GameInfo"
        end

        if
                type(utils) ~= "table"
                or type(utils.now) ~= "function"
                or type(utils.apiVersion) ~= "function"
                or type(utils.isFiniteNumber)
                        ~= "function"
                or type(utils.getConfig)
                        ~= "function"
                or type(utils.getLocalPlayer)
                        ~= "function"
                or type(utils.getWorkspace)
                        ~= "function"
                or type(utils.getRunService)
                        ~= "function"
                or type(utils.trackCharacter)
                        ~= "function"
                or type(utils.untrackCharacter)
                        ~= "function"
                or type(utils.trackGlobal)
                        ~= "function"
                or type(utils.isActive)
                        ~= "function"
                or type(utils.isSpamActive)
                        ~= "function"
        then
                return false,
                        "dependencia ausente: Utils"
        end

        Remote = remote
        GameInfo = gameInfo
        Utils = utils

        StatsService =
                game:GetService("Stats")

        Runtime.player =
                Utils.getLocalPlayer()

        Runtime.localUserId =
                Runtime.player
                and tonumber(
                        Runtime.player.UserId
                )
                or -1

        Runtime.workspace =
                Utils.getWorkspace()

        HitboxState.handler =
                handleHitbox

        resetState()

        if
                not installHitboxHook()
                and Utils.warn
        then
                Utils.warn(
                        "hook de hitbox indisponivel"
                )
        end

        return true
end

-- PUBLIC

function AutoParry.fire()
        if
                not Remote
                or not GameInfo
                or not Utils
                or not Runtime.alive
                or not Runtime.bound
        then
                return false
        end

        local ok =
                requestParry(
                        GameInfo.getBall()
                )

        local slot =
                TargetTracker
                and TargetTracker.currentSlot

        if ok and slot then
                slot:lock()
        end

        return ok
end

function AutoParry.bindCharacter(character)
        if
                not Remote
                or not GameInfo
                or not Utils
        then
                return false
        end

        return bindCharacter(character)
end

function AutoParry.resetState()
        if Utils then
                resetState()
        end
end

function AutoParry.detachCharacter()
        if not Utils then
                return
        end

        Runtime.generation += 1

        disconnectConnections()
        invalidateLife()

        Runtime.character = nil
        Runtime.root = nil

        setPhase(
                PHASE_DETACHED,
                "detach"
        )
end

function AutoParry.teardown()
        AutoParry.detachCharacter()

        if HitboxState.connection then
                if
                        Utils
                        and type(
                                Utils.untrackGlobal
                        ) == "function"
                then
                        Utils.untrackGlobal(
                                HitboxState.connection
                        )
                end

                pcall(
                        HitboxState.connection.Disconnect,
                        HitboxState.connection
                )

                HitboxState.connection = nil
        end

        Remote = nil
        GameInfo = nil
        Utils = nil
end

function AutoParry.onBallSync(data)
        if Utils then
                onBallSync(data)
        end
end

function AutoParry.getTargetStatus()
        if not Utils then
                return nil
        end

        return TargetTracker.getStatus()
end

-- API

local function getResilienceStatus()
        local usable =
                isResilienceUsable()

        return {
                stack =
                        usable
                        and Resilience.stack
                        or 0,

                size =
                        usable
                        and Runtime.resilienceBonus
                        or 0,

                perParry =
                        Tuning.RES_PER_PARRY,

                cap =
                        Tuning.RES_CAP_STUDS,

                maxStack =
                        MAX_RES_STACK,
        }
end

function AutoParry.getRadius(
        mode,
        windowFactor,
        speedOverride
)
        mode = mode or "geometry"

        if
                mode ~= "geometry"
                and mode ~= "tti"
                and mode ~= "speed_distance"
        then
                mode = "geometry"
        end

        local speed =
                tonumber(speedOverride)

        if
                not speed
                or not Utils.isFiniteNumber(speed)
                or speed < 0
        then
                speed = Runtime.lastSpeed
        end

        local distance =
                Runtime.lastDistance

        local tti =
                speed > 0
                and distance / speed
                or math.huge

        -- Kept for API compatibility.
        -- Actual click multiplier stays fixed at 0.45x.
        local requestedFactor =
                tonumber(windowFactor)

        if
                not requestedFactor
                or not Utils.isFiniteNumber(
                        requestedFactor
                )
        then
                requestedFactor =
                        Tuning.WINDOW_FACTOR
        end

        requestedFactor =
                math.clamp(
                        requestedFactor,
                        0,
                        1.5
                )

        local deflectWindow =
                computeDeflectWindow(speed)

        local effectiveWindow =
                deflectWindow
                * Tuning.WINDOW_FACTOR

        local resilience =
                getResilienceBonus(now())

        local pingRadius =
                computePingRadius(speed)

        local noWindowParryRadius =
                computeNoWindowParryRadius(
                        speed,
                        resilience
                )

        local fullRadius =
                Tuning.DEFLECT_RADIUS
                + resilience
                + pingRadius
                + speed * effectiveWindow

        local value = fullRadius

        if mode == "tti" then
                value =
                        math.max(
                                distance - fullRadius,
                                0
                        )
                        / math.max(
                                speed,
                                1
                        )

        elseif mode == "speed_distance" then
                value = {
                        speed = speed,
                        distance = distance,
                }
        end

        return {
                mode = mode,

                value = value,

                pureRadius =
                        Tuning.DEFLECT_RADIUS,

                noWindowParryRadius =
                        noWindowParryRadius,

                pingRadius =
                        pingRadius,

                resilience =
                        getResilienceStatus(),

                fullRadius =
                        fullRadius,

                deflectWindow =
                        deflectWindow,

                windowFactor =
                        Tuning.WINDOW_FACTOR,

                effectiveWindow =
                        effectiveWindow,

                distance =
                        distance,

                speed =
                        speed,

                tti =
                        tti,
        }
end

function AutoParry.getTiming(
        snapshot,
        time,
        rootPosition
)
        if
                not Utils
                or type(snapshot) ~= "table"
        then
                return nil
        end

        time =
                tonumber(time)
                or now()

        if typeof(rootPosition) ~= "Vector3" then
                local root =
                        Runtime.root

                if
                        root
                        and root.Parent
                then
                        rootPosition =
                                root.Position
                else
                        local player =
                                Runtime.player

                        local character =
                                player
                                and player.Character

                        local newRoot =
                                character
                                and character:FindFirstChild(
                                        "HumanoidRootPart"
                                )

                        if newRoot then
                                rootPosition =
                                        newRoot.Position
                        end
                end
        end

        local speed =
                tonumber(snapshot.speed)

        local position =
                snapshot.position

        if
                not speed
                or not Utils.isFiniteNumber(speed)
                or speed <= 0
                or typeof(position) ~= "Vector3"
                or typeof(rootPosition) ~= "Vector3"
        then
                return nil
        end

        return computeTiming(
                rootPosition,
                position,
                speed,
                time
        )
end

function AutoParry.getStatus()
        local target =
                TargetTracker.getStatus()

        return {
                schema =
                        Utils
                        and Utils.apiVersion
                        and Utils.apiVersion()
                        or nil,

                api = {
                        name = "AutoParry",

                        version = 5,

                        endpoints = {
                                "getRadius",
                                "getTiming",
                                "getStatus",
                                "getTargetStatus",
                        },
                },

                lifecycle = {
                        phase =
                                phaseString,

                        bound =
                                Runtime.bound == true,

                        alive =
                                Runtime.alive == true,

                        lifeGeneration =
                                Runtime.lifeGeneration,
                },

                radius =
                        AutoParry.getRadius(
                                "geometry"
                        ),

                resilience =
                        getResilienceStatus(),

                timing = {
                        tti =
                                Runtime.lastTTI,

                        speed =
                                Runtime.lastSpeed,

                        distance =
                                Runtime.lastDistance,

                        distanceToRadius =
                                Runtime.lastDistanceToParryRadius,

                        deflectWindow =
                                Runtime.deflectWindow,

                        effectiveWindow =
                                Runtime.effectiveWindow,

                        noWindowParryRadius =
                                Runtime.noWindowParryRadius,

                        pingRadius =
                                Runtime.pingRadius,
                },

                ping = {
                        oneWay =
                                Runtime.pingOneWay,

                        minimum =
                                Runtime.minPing,
                },

                target =
                        target,

                cycle = {
                        fired =
                                target.slot ~= nil
                                and target.slot.locked
                                        == true,

                        lastFireAt =
                                Runtime.lastFireAt,

                        lastTTI =
                                Runtime.lastTTI,
                },
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