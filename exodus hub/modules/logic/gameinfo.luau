-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

-- tuning
local Tuning = {
        -- radius
        DEFLECT_RADIUS = 7,
        PARRY_WINDOW = 0.160,
        MIN_BALL_SPEED = 8,
        RES_PER_PARRY = 0.19,
        RES_CAP_STUDS = 32,
        HITBOX_OWN_WINDOW = 0.5,
        HITBOX_PROXIMITY = 12,
        HITBOX_GAP = 0.4,

        -- movement
        STATIONARY_MULT = 1.50,
        STATIONARY_SPEED = 1.5,
        STATIONARY_DWELL = 0.20,

        -- cooldown propagation
        CLIENT_CD_PROPAGATION = 0.30,
        APPROACH_REFIRE_COOLDOWN = 0.070,
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
        approachFireAt = 0,
        approachFiredBall = nil,
        cooldownObservedAt = 0,
        phase = PHASE_DETACHED,
        bound = false,
}

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
                Utils.recordTransition(
                        "AutoParry",
                        PHASE_STRINGS[previous] or "detached",
                        phaseString,
                        reason
                )
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
        Runtime.approachFireAt = 0
        Runtime.approachFiredBall = nil
        Resilience.lastFireBall = nil
        Resilience.lastFireAt = 0
end

local function disconnectConnections()
        local connections = Runtime.connections

        for i = #connections, 1, -1 do
                local connection = connections[i]
                connections[i] = nil

                if connection then
                        if Utils and type(Utils.untrackCharacter) == "function" then
                                pcall(Utils.untrackCharacter, connection)
                        end

                        pcall(function()
                                connection:Disconnect()
                        end)
                end
        end
end

local function isValidBall(ball)
        return ball ~= nil and ball.Parent ~= nil
end

local function getDistanceSquared(a, b)
        local delta = a - b
        return delta:Dot(delta)
end

-- ping
local function samplePing()
        local stats = game:GetService("Stats")
        local okItem, pingItem = pcall(function()
                return stats.Network.ServerStatsItem["Data Ping"]
        end)

        if not okItem or not pingItem then
                return
        end

        local ok, ping = pcall(pingItem.GetValue, pingItem)

        if not ok or type(ping) ~= "number" then
                return
        end

        ping = ping / 1000

        if not Utils.isFiniteNumber(ping) or ping <= 0 or ping >= 0.5 then
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

        Runtime.resilienceBonus = math.min(
                Resilience.stack * Tuning.RES_PER_PARRY,
                Tuning.RES_CAP_STUDS
        )

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

                Runtime.approachFireAt = 0
                Runtime.approachFiredBall = nil

                Resilience.lastFireBall = nil
                Resilience.lastFireAt = 0

                return
        end

        local targetId = data.TargetPlayerID

        if not Utils.isFiniteNumber(targetId) then
                targetId = tonumber(targetId) or -1
        end

        Runtime.lastTarget = targetId
end

local function requestParry()
        local time = now()

        if type(Remote.fireParry) ~= "function" then
                if type(Utils.recordError) == "function" then
                        Utils.recordError("AutoParry", "Remote.fireParry indisponível")
                end

                setPhase(PHASE_WAITING, "remote_unavailable")
                return false
        end

        local ok, result = pcall(Remote.fireParry, 1)

        if not ok or result == false then
                if type(Utils.recordError) == "function" then
                        Utils.recordError("AutoParry", "Remote.fireParry falhou")
                end

                setPhase(PHASE_WAITING, "remote_failed")
                return false
        end

        Runtime.lastFireAt = time
        Runtime.cooldownObservedAt = 0

        setPhase(PHASE_FIRED, "parry_requested")

        local ball = GameInfo.getBall()

        if isValidBall(ball) then
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
        if typeof(instance) ~= "Instance" then
                return
        end

        if not Utils.isActive() or instance.Name ~= "HitboxGrow" then
                return
        end

        local time = now()

        if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW then
                return
        end

        if time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP then
                return
        end

        local ball = Resilience.lastFireBall

        if not isValidBall(ball) then
                return
        end

        local ok, position, ballPosition = pcall(function()
                return instance.Position, ball.Position
        end)

        if not ok then
                return
        end

        if typeof(position) ~= "Vector3" or typeof(ballPosition) ~= "Vector3" then
                return
        end

        if getDistanceSquared(ballPosition, position) > Tuning.HITBOX_PROXIMITY ^ 2 then
                return
        end

        Resilience.lastHitboxAt = time

        local maxStack = math.floor(
                Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY
        )

        Resilience.stack = math.min(
                Resilience.stack + 1,
                maxStack
        )

        Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
        if HitboxState.connection then
                return true
        end

        local workspaceService = Utils.getWorkspace()

        if not workspaceService then
                return false
        end

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

        if type(Utils.trackGlobal) == "function" then
                Utils.trackGlobal(connection)
        end

        return true
end

-- character
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

        local root = character:FindFirstChild("HumanoidRootPart")

        if not root then
                root = character:WaitForChild("HumanoidRootPart", 1)
        end

        if generation ~= Runtime.generation or not (root and root.Parent) then
                return false
        end

        local humanoid = character:FindFirstChildOfClass("Humanoid")

        if humanoid then
                local connection = humanoid.Died:Connect(function()
                        resetResilience()
                        clearCycle()
                end)

                Runtime.connections[#Runtime.connections + 1] = connection
                Utils.trackCharacter(connection)
        end

        local getConfig = Utils.getConfig
        local isSpamActive = Utils.isSpamActive
        local heartbeat = Utils.getRunService().Heartbeat

        local heartbeatConnection = heartbeat:Connect(function(dt)
                if generation ~= Runtime.generation then
                        return
                end

                if not character.Parent or not root.Parent then
                        return
                end

                local config = getConfig()

                if type(config) ~= "table" or config.AutoParry ~= true then
                        clearCycle()
                        setPhase(PHASE_WAITING, "disabled_or_locked")
                        return
                end

                local timeNow = now()

                if timeNow < Runtime.teleportLockUntil then
                        clearCycle()
                        setPhase(PHASE_WAITING, "teleport_lock")
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

                local snapshot = GameInfo.getSnapshot(
                        Runtime.lastTarget,
                        timeNow
                )

                if not GameInfo.isSnapshotValid(snapshot, timeNow) then
                        setPhase(PHASE_WAITING, "snapshot_invalid")
                        return
                end

                if type(snapshot) ~= "table" then
                        setPhase(PHASE_WAITING, "snapshot_invalid")
                        return
                end

                local ball = snapshot.ball

                local deflectCooldown = GameInfo.getDeflectCD()

                if type(deflectCooldown) ~= "number" or not Utils.isFiniteNumber(deflectCooldown) then
                        deflectCooldown = 0
                end

                if deflectCooldown > 0 then
                        if Runtime.cooldownObservedAt <= 0 then
                                Runtime.cooldownObservedAt = timeNow
                        end

                        setPhase(PHASE_COOLDOWN, "cooldown_observed")

                        if timeNow - Runtime.cooldownObservedAt < Tuning.CLIENT_CD_PROPAGATION then
                                return
                        end

                        if ParryState.armed then
                                if not (
                                        isValidBall(ball)
                                        and ball == ParryState.armedBall
                                ) then
                                        clearArmed()
                                end
                        end

                        return
                end

                Runtime.cooldownObservedAt = 0

                if ParryState.armed then
                        if not (
                                isValidBall(ball)
                                and ball == ParryState.armedBall
                        ) then
                                clearArmed()
                                setPhase(PHASE_WAITING, "armed_context_invalid")
                        else
                                if requestParry() then
                                        ParryState.fired = true
                                        ParryState.firedBall = ball
                                        ParryState.firedAt = timeNow
                                        Runtime.approachFireAt = timeNow
                                        Runtime.approachFiredBall = ball
                                end

                                clearArmed()
                                return
                        end
                end

                if not isValidBall(ball) then
                        setPhase(PHASE_WAITING, "ball_invalid")
                        return
                end

                local speed = tonumber(snapshot.speed)

                if not speed or not Utils.isFiniteNumber(speed) or speed < Tuning.MIN_BALL_SPEED then
                        setPhase(PHASE_WAITING, "ball_too_slow")
                        return
                end

                local position = snapshot.position

                if typeof(position) ~= "Vector3" then
                        setPhase(PHASE_WAITING, "position_unavailable")
                        return
                end

                local parryRadius = computeParryRadius(timeNow)
                local rootPos = root.Position
                local parryWindow = Tuning.PARRY_WINDOW

                do
                        local dtRoot = math.max(
                                timeNow - Runtime.lastRootPosAt,
                                0
                        )

                        local rootVel = Vector3.zero

                        if Runtime.lastRootPos and dtRoot > 0 then
                                rootVel = (rootPos - Runtime.lastRootPos) / dtRoot
                        end

                        Runtime.lastRootPos = rootPos
                        Runtime.lastRootPosAt = timeNow

                        local horizontalVel = Vector3.new(
                                rootVel.X,
                                0,
                                rootVel.Z
                        )

                        local horizontalSpeed = horizontalVel.Magnitude

                        if horizontalSpeed < Tuning.STATIONARY_SPEED then
                                if Runtime.stationarySince == 0 then
                                        Runtime.stationarySince = timeNow
                                end
                        else
                                Runtime.stationarySince = 0
                        end

                        local isStationary =
                                Runtime.stationarySince > 0
                                and timeNow - Runtime.stationarySince >= Tuning.STATIONARY_DWELL

                        Runtime.stationary = isStationary

                        if isStationary then
                                parryWindow =
                                        Tuning.PARRY_WINDOW
                                        * Tuning.STATIONARY_MULT
                        end
                end

                Runtime.parryRadius =
                        parryRadius + speed * parryWindow

                local distance = math.sqrt(
                        getDistanceSquared(rootPos, position)
                )

                local toBall = position - rootPos
                local dirMag = toBall.Magnitude
                local approachingSpeed = 0

                if dirMag > 0 and typeof(snapshot.velocity) == "Vector3" then
                        approachingSpeed = snapshot.velocity:Dot(toBall / dirMag)
                end

                if approachingSpeed <= 0 then
                        setPhase(PHASE_WAITING, "ball_not_approaching")
                        return
                end

                local tti = math.max(
                        0,
                        (distance - parryRadius) / speed
                )

                if tti > parryWindow then
                        setPhase(PHASE_WAITING, "outside_ping_window")
                        return
                end

                if ParryState.fired and ParryState.firedBall == ball then
                        if timeNow - ParryState.firedAt < Tuning.APPROACH_REFIRE_COOLDOWN then
                                setPhase(PHASE_WAITING, "approach_refire_cooldown")
                                return
                        end

                        clearFired()
                end

                if ParryState.fired and (
                        not isValidBall(ParryState.firedBall)
                        or ParryState.firedBall ~= ball
                ) then
                        clearFired()
                end

                if requestParry() then
                        ParryState.fired = true
                        ParryState.firedBall = ball
                        ParryState.firedAt = timeNow
                        Runtime.approachFireAt = timeNow
                        Runtime.approachFiredBall = ball
                end
        end)

        Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
        Utils.trackCharacter(heartbeatConnection)

        local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
                if not parent and generation == Runtime.generation then
                        Runtime.generation += 1
                        Runtime.bound = false
                        disconnectConnections()
                        clearCycle()
                        setPhase(PHASE_DETACHED, "character_removed")
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
        Runtime.lastFireAt = 0
        Runtime.approachFireAt = 0
        Runtime.approachFiredBall = nil
        Runtime.cooldownObservedAt = 0
        Runtime.bound = false

        setPhase(PHASE_DETACHED, "reset")
end

-- setup
function AutoParry.setup(deps)
        if type(deps) ~= "table" then
                return false, "dependências inválidas"
        end

        local remote = deps.Remote
        local gameInfo = deps.GameInfo
        local utils = deps.Utils

        if type(remote) ~= "table"
                or type(remote.fireParry) ~= "function"
        then
                return false, "dependência ausente: Remote.fireParry"
        end

        if type(gameInfo) ~= "table"
                or type(gameInfo.getDeflectCD) ~= "function"
                or type(gameInfo.getBall) ~= "function"
                or type(gameInfo.getSnapshot) ~= "function"
                or type(gameInfo.isSnapshotValid) ~= "function"
        then
                return false, "dependência ausente: GameInfo"
        end

        if type(utils) ~= "table"
                or type(utils.now) ~= "function"
                or type(utils.apiVersion) ~= "function"
                or type(utils.isFiniteNumber) ~= "function"
                or type(utils.getConfig) ~= "function"
                or type(utils.getLocalPlayer) ~= "function"
                or type(utils.getWorkspace) ~= "function"
                or type(utils.getRunService) ~= "function"
                or type(utils.trackCharacter) ~= "function"
                or type(utils.untrackCharacter) ~= "function"
                or type(utils.trackGlobal) ~= "function"
                or type(utils.isActive) ~= "function"
                or type(utils.isSpamActive) ~= "function"
        then
                return false, "dependência ausente: Utils"
        end

        Remote = remote
        GameInfo = gameInfo
        Utils = utils

        local localPlayer = Utils.getLocalPlayer()

        Runtime.localUserId =
                localPlayer and tonumber(localPlayer.UserId) or -1

        HitboxState.handler = handleHitbox

        resetResilience()
        resetState()

        if not installHitboxHook() then
                if type(Utils.warn) == "function" then
                        Utils.warn("hook de hitbox indisponível")
                end
        end

        return true
end

function AutoParry.fire()
        if not Remote or not GameInfo or not Utils then
                return false
        end

        return requestParry()
end

function AutoParry.bindCharacter(character)
        if not Remote or not GameInfo or not Utils then
                return false
        end

        return bindCharacter(character)
end

function AutoParry.resetState()
        if not Utils then
                return
        end

        resetState()
end

function AutoParry.detachCharacter()
        Runtime.generation += 1
        Runtime.bound = false

        disconnectConnections()
        resetState()
end

function AutoParry.onBallSync(data)
        if not Utils then
                return
        end

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
                schema = Utils and Utils.apiVersion() or nil,
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