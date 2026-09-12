-- [[ autoclash ]]

local AutoClash = {}

-- dependencies
local AutoParry
local GameInfo
local Utils

-- configuration
local T = {
    -- activation
    RETURN_WIN_LO = 0.115,
    RETURN_WIN_MIN_FACTOR = 0.10,
    RETURN_SPD_LO = 60,
    RETURN_SPD_HI = 600,
    PING_FACTOR = 0.3,
    ACT_RADIUS_MIN = 15,
    REACTIVATE_COOLDOWN = 0.070,
    ACT_DEACT_LOCK_RADIUS_FACTOR = 0.70,
    ACT_DEACT_LOCK_TIME = 0.05,
    DASH_DETECT_WINDOW = 0.25,
    OWN_DASH_ESCAPE_CONFIRM_FRAMES = 2,
    DASH_RETURN_WINDOW = 0.400,
    DASH_RETURN_DOT = 0.3,
    DASH_RETURN_RADIUS_MULT = 3.0,
    DASH_DEACT_LOCK_TIME = 0.070,
    DASH_RADIUS_BONUS_TIME = 0.400,
    DASH_BONUS_RETURN_MULT = 3.0,
    OWN_DASH_ESCAPE_DOT = -0.3,

    -- deactivation
    DEACT_DIRECTION_MAX_LO = 0.044,
    DEACT_DIRECTION_MAX_MIN_FACTOR = 0.10,
    DEACT_DIRECTION_SPD_LO = 60,
    DEACT_DIRECTION_SPD_HI = 600,
    DEACT_DIRECTION_MIN_RADIUS_FACTOR = 0.50,
    DEACT_TRAVEL_MAX_LO = 0.46,
    DEACT_TRAVEL_MAX_MIN_FACTOR = 0.10,
    DEACT_TRAVEL_SPD_LO = 60,
    DEACT_TRAVEL_SPD_HI = 600,
    DEACT_TRAVEL_HOLD = 0.015,
    DEACT_CONFIRM_HOLD = 0.025,
    DEACT_CONFIRM_FRAMES = 2,
    DEACT_CONFIRM_MAX_GAP = 0.100,
    CLASH_CADENCE_INTERVAL_LO = 1 / 14,
    CLASH_CADENCE_INTERVAL_HI = 0.0435,
    CLASH_CADENCE_BUFF_HI = 95 / 55,

    -- system
    MIN_EVAL_INTERVAL = 1 / 120,
}

-- constants
local DASH_PARTS = {
    DashEffect = true,
    WindDash = true,
    Dash = true,
}

-- runtime
local R = {
    -- lifecycle
    generation = 0,
    bound = false,
    active = false,
    phase = "detached",
    boundRoot = nil,
    localUserId = nil,

    -- ball
    lastTarget = -1,
    clashPartnerId = -1,
    lastSpeed = 0,
    parryRadius = 0,
    dashBonusUntil = 0,
    dashDeactLockedUntil = 0,

    -- target
    wasMeTarget = nil,
    lostMeAt = 0,
    returnExpiresAt = 0,
    returnWindow = 0,
    returnPending = false,
    returnFromTarget = -1,
    returnToken = 0,

    -- deactivation
    travelSince = 0,
    lastSyncAt = 0,
    activationDeactLockedUntil = 0,
    reactivateBlockedUntil = 0,
    lastDirectionSwitchAt = 0,
    lastClashSwitchAt = 0,
    clashIntervalMs = 0,
    deactivationCandidate = nil,
    deactivationCandidateAt = 0,
    deactivationConfirmFrames = 0,
    deactivationLastConfirmAt = 0,

    -- evaluation
    lastEvalAt = 0,
    lastDashScanAt = 0,
    lastGate = "none",

    -- escape
    ownDashEscapePending = false,
    ownDashEscapeDetectedAt = 0,
    ownDashEscapeConfirmFrames = 0,
    ownDashEscapeLastDist = nil,
    ownDashEscapeFartherStreak = 0,

    -- connections
    connections = {},
    dashConnections = {},
    dashCharacterConnections = {},
    dashPlayerConnections = {},
    dashGeneration = 0,

    -- cache
    dashEvents = {},
    dashCooldown = {},
    dashTrackSnap = {},
    dashVelAnterior = {},
}

-- helpers
local function now()
    if not Utils or type(Utils.now) ~= "function" then
        return 0
    end
    local ok, value = pcall(Utils.now)
    if not ok then
        return 0
    end
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return 0
    end
    return value
end

local function normalizeTarget(target)
    if type(target) == "string" then
        target = tonumber(target)
    end
    if type(target) ~= "number"
        or target ~= target
        or target == math.huge
        or target == -math.huge
        or target < 1
        or target % 1 ~= 0 then
        return nil
    end
    return target
end

local function lerpBySpeed(speed, low, high, speedLow, speedHigh)
    speed = tonumber(speed) or 0
    if speed ~= speed
        or speed == math.huge
        or speed == -math.huge then
        speed = 0
    end
    if speedHigh <= speedLow then
        return low
    end
    local alpha = math.clamp(
        (speed - speedLow) / (speedHigh - speedLow),
        0,
        1
    )
    return low + (high - low) * alpha
end

local function horizontalSpeed(velocity)
    if typeof(velocity) ~= "Vector3" then
        return 0
    end
    return math.sqrt(
        velocity.X * velocity.X +
        velocity.Z * velocity.Z
    )
end

-- position
local function getRootPosition()
    local root = R.boundRoot
    if not root or not root.Parent then
        return nil
    end
    local ok, position = pcall(function()
        return root.Position
    end)
    if not ok or typeof(position) ~= "Vector3" then
        return nil
    end
    return position
end

local function getSnapshotPosition(snapshot)
    local position = snapshot and snapshot.position
    return typeof(position) == "Vector3" and position or nil
end

local function getDataPosition(data)
    local position = data and data.RealPosition
    return typeof(position) == "Vector3" and position or nil
end

-- timing
local function getPingOneWay()
    if not AutoParry or type(AutoParry.getPingOneWay) ~= "function" then
        return 0
    end
    local ok, value = pcall(AutoParry.getPingOneWay)
    if not ok then
        return 0
    end
    value = tonumber(value)
    if not value
        or value ~= value
        or value == math.huge
        or value == -math.huge then
        return 0
    end
    return math.max(value, 0)
end

local function pingCompensation()
    return getPingOneWay() * T.PING_FACTOR
end

local function getReturnWindow(speed)
    local base = lerpBySpeed(
        speed,
        T.RETURN_WIN_LO,
        T.RETURN_WIN_LO * T.RETURN_WIN_MIN_FACTOR,
        T.RETURN_SPD_LO,
        T.RETURN_SPD_HI
    )
    return math.max(base + pingCompensation(), 2 / 60)
end

-- phase
local function setPhase(phase, reason)
    if R.phase == phase then
        return
    end
    local previous = R.phase
    R.phase = phase
    if Utils and type(Utils.recordTransition) == "function" then
        pcall(Utils.recordTransition, "AutoClash", previous, phase, reason)
    end
end

-- connections
local function addConnection(list, connection)
    if connection then
        list[#list + 1] = connection
    end
    return connection
end

local function disconnectList(list, trackCharacter)
    for i = #list, 1, -1 do
        local connection = list[i]
        list[i] = nil
        if connection then
            if trackCharacter
                and Utils
                and type(Utils.untrackCharacter) == "function" then
                pcall(Utils.untrackCharacter, connection)
            end
            pcall(function()
                connection:Disconnect()
            end)
        end
    end
end

local function disconnectCharacterConnections()
    disconnectList(R.connections, true)
end

local function disconnectDashCharacterConnections()
    for player, connections in pairs(R.dashCharacterConnections) do
        disconnectList(connections, false)
        R.dashCharacterConnections[player] = nil
    end
end

local function disconnectDashPlayerConnections()
    for player, connections in pairs(R.dashPlayerConnections) do
        disconnectList(connections, false)
        R.dashPlayerConnections[player] = nil
    end
end

local function disconnectDashConnections()
    disconnectDashCharacterConnections()
    disconnectDashPlayerConnections()
    disconnectList(R.dashConnections, false)
    R.dashGeneration += 1
end

local function addDashCharacterConnection(player, connection)
    if not player or not connection then
        return connection
    end
    local connections = R.dashCharacterConnections[player]
    if not connections then
        connections = {}
        R.dashCharacterConnections[player] = connections
    end
    connections[#connections + 1] = connection
    return connection
end

local function addDashPlayerConnection(player, connection)
    if not player or not connection then
        return connection
    end
    local connections = R.dashPlayerConnections[player]
    if not connections then
        connections = {}
        R.dashPlayerConnections[player] = connections
    end
    connections[#connections + 1] = connection
    return connection
end

-- reset
local function clearReturnState()
    R.lostMeAt = 0
    R.returnExpiresAt = 0
    R.returnWindow = 0
    R.returnPending = false
    R.returnFromTarget = -1
    R.returnToken += 1
end

local function resetTargetState()
    R.lastTarget = -1
    R.clashPartnerId = -1
    R.dashBonusUntil = 0
    R.wasMeTarget = nil
    clearReturnState()
    R.lastDirectionSwitchAt = 0
    R.lastClashSwitchAt = 0
    R.clashIntervalMs = 0
end

local function resetOwnDashState()
    R.ownDashEscapePending = false
    R.ownDashEscapeDetectedAt = 0
    R.ownDashEscapeConfirmFrames = 0
    R.ownDashEscapeLastDist = nil
    R.ownDashEscapeFartherStreak = 0
end

local function resetDeactivationState()
    resetOwnDashState()
    R.travelSince = 0
    R.dashDeactLockedUntil = 0
    R.deactivationCandidate = nil
    R.deactivationCandidateAt = 0
    R.deactivationConfirmFrames = 0
    R.deactivationLastConfirmAt = 0
end

local function clearDashState()
    table.clear(R.dashEvents)
    table.clear(R.dashCooldown)
    table.clear(R.dashTrackSnap)
    table.clear(R.dashVelAnterior)
end

-- active
local function setActivationLock(t, snapshot)
    R.activationDeactLockedUntil = 0
    local root = getRootPosition()
    local position = getSnapshotPosition(snapshot)
    if not root or not position or R.parryRadius <= 0 then
        return
    end
    if (root - position).Magnitude
        <= R.parryRadius * T.ACT_DEACT_LOCK_RADIUS_FACTOR then
        R.activationDeactLockedUntil =
            t + T.ACT_DEACT_LOCK_TIME
    end
end

local function setActive(active, reason, snapshot)
    active = active == true
    if R.active == active then
        return
    end
    R.active = active
    resetDeactivationState()
    local t = now()
    if active then
        if R.clashPartnerId == -1
            and R.lastTarget ~= R.localUserId
            and R.lastTarget ~= -1 then
            R.clashPartnerId = R.lastTarget
        end
        R.lastDirectionSwitchAt = t
        setActivationLock(t, snapshot)
        if t < R.dashBonusUntil then
            R.dashDeactLockedUntil =
                t +
                T.DASH_DEACT_LOCK_TIME +
                pingCompensation()
        else
            R.dashDeactLockedUntil = 0
        end
    else
        R.clashPartnerId = -1
        R.reactivateBlockedUntil =
            t +
            T.REACTIVATE_COOLDOWN +
            pingCompensation()
        R.activationDeactLockedUntil = 0
        R.dashDeactLockedUntil = 0
        resetTargetState()
    end
    if Utils and type(Utils.setAutoSpamActive) == "function" then
        pcall(Utils.setAutoSpamActive, active)
    end
    setPhase(active and "active" or "idle", reason)
end

-- runtime
local function resetRuntime(reason, keepDashDetection)
    R.generation += 1
    if R.active then
        setActive(false, reason or "reset")
    end
    disconnectCharacterConnections()
    if not keepDashDetection then
        disconnectDashConnections()
    end
    R.bound = false
    R.boundRoot = nil
    R.lastSpeed = 0
    R.parryRadius = 0
    R.lastSyncAt = 0
    R.lastEvalAt = 0
    R.lastDashScanAt = 0
    R.reactivateBlockedUntil = 0
    R.activationDeactLockedUntil = 0
    resetTargetState()
    resetDeactivationState()
    clearDashState()
    R.lastGate = "detached"
    setPhase("detached", reason or "reset")
end

-- parry
local function refreshParryRadius(t)
    if not AutoParry
        or type(AutoParry.getParryRadius) ~= "function" then
        return
    end
    local ok, radius =
        pcall(AutoParry.getParryRadius, t)
    radius = ok and tonumber(radius) or nil
    if radius
        and radius == radius
        and radius ~= math.huge
        and radius ~= -math.huge
        and radius >= 0 then
        R.parryRadius = radius
    end
end

local function updateParryState(t, snapshot)
    local speed = tonumber(snapshot and snapshot.speed) or 0
    if speed ~= speed
        or speed == math.huge
        or speed == -math.huge then
        speed = 0
    end
    R.lastSpeed = math.max(speed, 0)
    refreshParryRadius(t)
end

-- activation
local function canReactivate(t)
    t = t or now()
    if t < R.reactivateBlockedUntil then
        R.lastGate = "reactivate_cooldown"
        return false
    end
    return true
end

local function getDashActivationRadius(t)
    local baseRadius = math.max(
        R.parryRadius,
        T.ACT_RADIUS_MIN
    )
    if t >= R.dashBonusUntil
        or R.lastSpeed <= 0 then
        return baseRadius
    end
    local dashBonus =
        R.lastSpeed * T.DASH_RETURN_WINDOW
    return baseRadius + dashBonus
end

local function shouldActivate(snapshot, t)
    if not snapshot
        or not snapshot.ball
        or not snapshot.ball.Parent then
        R.lastGate = "no_ball"
        return false
    end
    local root = getRootPosition()
    if not root then
        R.lastGate = "no_root"
        return false
    end
    if snapshot.targeted ~= true then
        R.lastGate = "target_not_me"
        return false
    end
    local position =
        getSnapshotPosition(snapshot)
    if not position then
        R.lastGate = "no_position"
        return false
    end
    if R.parryRadius <= 0 then
        R.lastGate = "no_effective_radius"
        return false
    end
    local effectiveRadius =
        getDashActivationRadius(t)
    if (root - position).Magnitude > effectiveRadius then
        R.lastGate = "outside_effective_radius"
        return false
    end
    R.lastGate = "activation_ready"
    return true
end

-- target
local function tryReturnActivate(snapshot, t)
    if not R.returnPending then
        return false
    end
    if R.lostMeAt <= 0
        or R.returnExpiresAt <= 0
        or R.returnToken <= 0 then
        clearReturnState()
        R.lastGate = "return_without_loss"
        return false
    end
    if t < R.lostMeAt then
        clearReturnState()
        R.lastGate = "return_invalid_time"
        return false
    end
    if t >= R.returnExpiresAt then
        clearReturnState()
        R.lastGate = "return_expired"
        return false
    end
    if not canReactivate(t) then
        return false
    end
    return shouldActivate(snapshot, t)
end

-- rally
local function rallyCheck(data)
    if not R.active
        or type(data) ~= "table" then
        return true
    end
    local target =
        normalizeTarget(data.TargetPlayerID)
    if not target
        or target == R.localUserId
        or target == R.clashPartnerId then
        return true
    end
    local position =
        getDataPosition(data)
    if not position then
        return true
    end
    local root =
        getRootPosition()
    if not root then
        return true
    end
    if R.parryRadius <= 0 then
        return true
    end
    local effectiveRadius =
        math.max(
            R.parryRadius,
            T.ACT_RADIUS_MIN
        )
    if (root - position).Magnitude > effectiveRadius then
        setActive(
            false,
            "rally_outside_effective_radius"
        )
        return false
    end
    R.clashPartnerId = target
    return true
end

-- dash
local Dash = {}

function Dash.cleanExpired(t)
    local expiration =
        T.DASH_DETECT_WINDOW +
        pingCompensation()
    for i = #R.dashEvents, 1, -1 do
        local event = R.dashEvents[i]
        if not event
            or not event.player
            or not event.player.Parent
            or t - event.detectedAt > expiration then
            table.remove(
                R.dashEvents,
                i
            )
        end
    end
    for player, last in pairs(R.dashCooldown) do
        if not player.Parent
            or t - last > expiration then
            R.dashCooldown[player] = nil
        end
    end
end

function Dash.register(
    player,
    position,
    velocity
)
    if not player or not player.Parent then
        return
    end
    local t = now()
    local last =
        R.dashCooldown[player]
    local cooldown =
        T.DASH_DETECT_WINDOW +
        pingCompensation()
    if last and t - last < cooldown then
        return
    end
    local character = player.Character
    local root =
        character
        and character:FindFirstChild(
            "HumanoidRootPart"
        )
    if typeof(position) ~= "Vector3"
        and root then
        position = root.Position
    end
    if typeof(velocity) ~= "Vector3"
        and root then
        velocity =
            root.AssemblyLinearVelocity
    end
    R.dashCooldown[player] = t
    Dash.cleanExpired(t)
    R.dashEvents[#R.dashEvents + 1] = {
        player = player,
        userId = player.UserId,
        detectedAt = t,
        position = position,
        velocity = velocity,
    }
    if R.clashPartnerId ~= -1
        and player.UserId == R.clashPartnerId
        and R.parryRadius > 0
        and typeof(position) == "Vector3"
        and typeof(velocity) == "Vector3" then
        local localRoot =
            getRootPosition()
        if localRoot then
            local toRoot =
                localRoot - position
            local toRootMagnitude =
                math.sqrt(
                    toRoot.X * toRoot.X +
                    toRoot.Z * toRoot.Z
                )
            local velocityMagnitude =
                horizontalSpeed(velocity)
            if toRootMagnitude > 0
                and velocityMagnitude > 0 then
                local dot =
                    (
                        velocity.X /
                        velocityMagnitude
                    ) *
                    (
                        toRoot.X /
                        toRootMagnitude
                    ) +
                    (
                        velocity.Z /
                        velocityMagnitude
                    ) *
                    (
                        toRoot.Z /
                        toRootMagnitude
                    )
                if dot >= T.DASH_RETURN_DOT
                    and toRootMagnitude
                    <= R.parryRadius *
                    T.DASH_RETURN_RADIUS_MULT then
                    R.dashBonusUntil =
                        t +
                        T.DASH_RADIUS_BONUS_TIME +
                        pingCompensation()
                    if R.returnPending
                        and R.returnWindow > 0 then
                        local baseWindow =
                            getReturnWindow(
                                R.lastSpeed
                            )
                        R.returnWindow =
                            baseWindow *
                            T.DASH_BONUS_RETURN_MULT
                        R.returnExpiresAt =
                            math.max(
                                R.returnExpiresAt,
                                t + R.returnWindow
                            )
                    end
                end
            end
        end
    end
end

function Dash.isTrack(track)
    if not track
        or not track:IsA("AnimationTrack") then
        return false
    end
    local animation =
        track.Animation
    if not animation then
        return false
    end
    local name =
        string.lower(
            animation.Name or ""
        )
    local id =
        string.lower(
            animation.AnimationId or ""
        )
    return name:find(
        "dash",
        1,
        true
    ) ~= nil
        or id:find(
            "dash",
            1,
            true
        ) ~= nil
end

function Dash.hookAnimator(
    animator,
    player,
    character,
    generation
)
    if not animator or not player then
        return
    end
    if generation ~= R.dashGeneration
        or not player.Parent
        or player.Character ~= character then
        return
    end
    local connections =
        R.dashCharacterConnections[player]
    if not connections then
        connections = {}
        R.dashCharacterConnections[player] =
            connections
    end
    local connection =
        animator.AnimationPlayed:Connect(
            function(track)
                if generation ~= R.dashGeneration
                    or not player.Parent
                    or player.Character ~= character then
                    return
                end
                if Dash.isTrack(track) then
                    Dash.register(player)
                end
            end
        )
    addDashCharacterConnection(
        player,
        connection
    )
    local snapshot =
        R.dashTrackSnap[player]
    if not snapshot then
        snapshot = {}
        R.dashTrackSnap[player] =
            snapshot
    end
    table.clear(snapshot)
    for _, track in ipairs(
        animator:GetPlayingAnimationTracks()
    ) do
        snapshot[track] = true
    end
end

function Dash.hookRoot(
    root,
    player,
    character,
    generation
)
    if not root
        or not player
        or not character then
        return
    end
    if generation ~= R.dashGeneration
        or player.Character ~= character
        or not player.Parent then
        return
    end
    R.dashVelAnterior[player] =
        horizontalSpeed(
            root.AssemblyLinearVelocity
        )
end

function Dash.scanTracks(players)
    if not players then
        return
    end
    for _, player in ipairs(
        players:GetPlayers()
    ) do
        if not player.Parent then
            continue
        end
        local character =
            player.Character
        if not character then
            continue
        end
        local humanoid =
            character:FindFirstChildOfClass(
                "Humanoid"
            )
        if not humanoid then
            continue
        end
        local animator =
            humanoid:FindFirstChildOfClass(
                "Animator"
            )
        if not animator then
            continue
        end
        local current =
            animator:GetPlayingAnimationTracks()
        local snapshot =
            R.dashTrackSnap[player]
        if not snapshot then
            snapshot = {}
            R.dashTrackSnap[player] =
                snapshot
        end
        for _, track in ipairs(current) do
            if not snapshot[track]
                and Dash.isTrack(track) then
                Dash.register(player)
            end
        end
        table.clear(snapshot)
        for _, track in ipairs(current) do
            snapshot[track] = true
        end
    end
end

function Dash.scanVelocity(players)
    if not players then
        return
    end
    for _, player in ipairs(
        players:GetPlayers()
    ) do
        if not player.Parent then
            continue
        end
        local character =
            player.Character
        if not character then
            continue
        end
        local root =
            character:FindFirstChild(
                "HumanoidRootPart"
            )
        if not root then
            continue
        end
        local velocity =
            root.AssemblyLinearVelocity
        local speed =
            horizontalSpeed(
                velocity
            )
        local previous =
            R.dashVelAnterior[player] or 0
        local delta =
            speed - previous
        if speed >= 80
            and delta >= 15 then
            Dash.register(
                player,
                root.Position,
                velocity
            )
        end
        R.dashVelAnterior[player] =
            speed
    end
end

function Dash.attachCharacter(
    character,
    player,
    generation
)
    if generation ~= R.dashGeneration
        or not character
        or not player
        or not player.Parent
        or player.Character ~= character then
        return
    end
    local oldConnections =
        R.dashCharacterConnections[player]
    if oldConnections then
        disconnectList(
            oldConnections,
            false
        )
        R.dashCharacterConnections[player] =
            nil
    end
    local humanoid =
        character:FindFirstChildOfClass(
            "Humanoid"
        )
        or character:WaitForChild(
            "Humanoid",
            5
        )
    if generation ~= R.dashGeneration
        or player.Character ~= character
        or not humanoid then
        return
    end
    local animator =
        humanoid:FindFirstChildOfClass(
            "Animator"
        )
        or humanoid:WaitForChild(
            "Animator",
            5
        )
    if generation ~= R.dashGeneration
        or player.Character ~= character then
        return
    end
    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )
        or character:WaitForChild(
            "HumanoidRootPart",
            5
        )
    if generation ~= R.dashGeneration
        or player.Character ~= character
        or not root then
        return
    end
    if animator then
        Dash.hookAnimator(
            animator,
            player,
            character,
            generation
        )
    end
    Dash.hookRoot(
        root,
        player,
        character,
        generation
    )
    R.dashVelAnterior[player] =
        horizontalSpeed(
            root.AssemblyLinearVelocity
        )
end

function Dash.hookPlayer(
    player,
    generation
)
    if generation ~= R.dashGeneration
        or not player
        or not player.Parent then
        return
    end
    R.dashTrackSnap[player] = {}
    R.dashVelAnterior[player] = nil
    if player.Character then
        task.spawn(
            Dash.attachCharacter,
            player.Character,
            player,
            generation
        )
    end
    local connection =
        player.CharacterAdded:Connect(
            function(character)
                if generation ==
                    R.dashGeneration then
                    task.spawn(
                        Dash.attachCharacter,
                        character,
                        player,
                        generation
                    )
                end
            end
        )
    addDashPlayerConnection(
        player,
        connection
    )
end

function Dash.init(players)
    if not players then
        return
    end
    disconnectDashConnections()
    local generation =
        R.dashGeneration
    for _, player in ipairs(
        players:GetPlayers()
    ) do
        Dash.hookPlayer(
            player,
            generation
        )
    end
    local playerAdded =
        players.PlayerAdded:Connect(
            function(player)
                if generation ==
                    R.dashGeneration then
                    Dash.hookPlayer(
                        player,
                        generation
                    )
                end
            end
        )
    addConnection(
        R.dashConnections,
        playerAdded
    )
    local playerRemoving =
        players.PlayerRemoving:Connect(
            function(player)
                local characterConnections =
                    R.dashCharacterConnections[player]
                if characterConnections then
                    disconnectList(
                        characterConnections,
                        false
                    )
                    R.dashCharacterConnections[player] =
                        nil
                end
                local playerConnections =
                    R.dashPlayerConnections[player]
                if playerConnections then
                    disconnectList(
                        playerConnections,
                        false
                    )
                    R.dashPlayerConnections[player] =
                        nil
                end
                R.dashCooldown[player] =
                    nil
                R.dashTrackSnap[player] =
                    nil
                R.dashVelAnterior[player] =
                    nil
                for i = #R.dashEvents, 1, -1 do
                    local event =
                        R.dashEvents[i]
                    if event
                        and event.player == player then
                        table.remove(
                            R.dashEvents,
                            i
                        )
                    end
                end
            end
        )
    addConnection(
        R.dashConnections,
        playerRemoving
    )
end

function Dash.tick(players, t)
    if not players
        or t - R.lastDashScanAt <
        T.MIN_EVAL_INTERVAL then
        return
    end
    R.lastDashScanAt = t
    Dash.cleanExpired(t)
    Dash.scanTracks(players)
    Dash.scanVelocity(players)
end

-- escape
local OwnDash = {}

function OwnDash.getOpponent()
    if R.clashPartnerId == -1
        or R.clashPartnerId == R.localUserId then
        return nil
    end
    if not Utils
        or type(Utils.getPlayers) ~= "function" then
        return nil
    end
    local ok, players =
        pcall(Utils.getPlayers)
    if not ok or not players then
        return nil
    end
    local opponent =
        players:GetPlayerByUserId(
            R.clashPartnerId
        )
    if not opponent
        or not opponent.Parent then
        return nil
    end
    local character =
        opponent.Character
    local root =
        character
        and character:FindFirstChild(
            "HumanoidRootPart"
        )
    if not root or not root.Parent then
        return nil
    end
    return opponent, root
end

function OwnDash.directionDot(
    velocity,
    fromPosition,
    toPosition
)
    if typeof(velocity) ~= "Vector3"
        or typeof(fromPosition) ~= "Vector3"
        or typeof(toPosition) ~= "Vector3" then
        return nil
    end
    local velocityMagnitude =
        horizontalSpeed(velocity)
    if velocityMagnitude <= 0 then
        return nil
    end
    local delta =
        toPosition - fromPosition
    local distance =
        math.sqrt(
            delta.X * delta.X +
            delta.Z * delta.Z
        )
    if distance <= 0 then
        return nil
    end
    return
        (
            velocity.X /
            velocityMagnitude
        ) *
        (
            delta.X /
            distance
        ) +
        (
            velocity.Z /
            velocityMagnitude
        ) *
        (
            delta.Z /
            distance
        )
end

function OwnDash.getRecentThreat(t)
    if not R.active
        or R.clashPartnerId == -1
        or R.clashPartnerId == R.localUserId then
        return nil
    end
    local _, opponentRoot =
        OwnDash.getOpponent()
    if not opponentRoot then
        return nil
    end
    local latest
    local expiration =
        T.DASH_DETECT_WINDOW +
        pingCompensation()
    for i = #R.dashEvents, 1, -1 do
        local event =
            R.dashEvents[i]
        if event
            and event.userId == R.localUserId then
            local age =
                t - event.detectedAt
            if age >= 0
                and age <= expiration then
                latest = event
                break
            end
        end
    end
    if not latest then
        return nil
    end
    if typeof(latest.velocity) == "Vector3"
        and typeof(latest.position) == "Vector3" then
        local dot =
            OwnDash.directionDot(
                latest.velocity,
                latest.position,
                opponentRoot.Position
            )
        if dot ~= nil
            and dot > T.OWN_DASH_ESCAPE_DOT then
            return nil
        end
    end
    return latest
end

function OwnDash.shouldDeactivate(t)
    if not R.active then
        resetOwnDashState()
        return false
    end
    if R.wasMeTarget then
        resetOwnDashState()
        R.lastGate =
            "own_dash_escape_targeted_skip"
        return false
    end
    local ownRoot =
        getRootPosition()
    if not ownRoot then
        resetOwnDashState()
        R.lastGate =
            "own_dash_escape_no_root"
        return false
    end
    local opponent, opponentRoot =
        OwnDash.getOpponent()
    if not opponent or not opponentRoot then
        resetOwnDashState()
        R.lastGate =
            "own_dash_escape_no_opponent"
        return false
    end
    local event =
        OwnDash.getRecentThreat(t)
    if not event then
        if R.ownDashEscapePending then
            if t - R.ownDashEscapeDetectedAt
                > T.DASH_DETECT_WINDOW +
                pingCompensation() then
                resetOwnDashState()
            else
                R.lastGate =
                    "own_dash_escape_waiting"
            end
        else
            R.lastGate =
                "own_dash_escape_no_dash"
        end
        return false
    end
    if not R.ownDashEscapePending
        or R.ownDashEscapeDetectedAt ~=
        event.detectedAt then
        R.ownDashEscapePending = true
        R.ownDashEscapeDetectedAt =
            event.detectedAt
        R.ownDashEscapeConfirmFrames = 0
        R.ownDashEscapeFartherStreak = 0
        R.ownDashEscapeLastDist =
            (ownRoot - opponentRoot.Position).Magnitude
        R.lastGate =
            "own_dash_escape_detected"
        return false
    end
    local currentDistance =
        (ownRoot - opponentRoot.Position).Magnitude
    local previousDistance =
        R.ownDashEscapeLastDist
    if not previousDistance then
        R.ownDashEscapeLastDist =
            currentDistance
        R.ownDashEscapeFartherStreak = 0
        R.lastGate =
            "own_dash_escape_first"
        return false
    end
    if currentDistance > previousDistance then
        R.ownDashEscapeFartherStreak += 1
        R.ownDashEscapeConfirmFrames =
            R.ownDashEscapeFartherStreak
        R.ownDashEscapeLastDist =
            currentDistance
        R.lastGate =
            "own_dash_escape_farther_"
            .. R.ownDashEscapeFartherStreak
        return
            R.ownDashEscapeFartherStreak
            >= T.OWN_DASH_ESCAPE_CONFIRM_FRAMES
    end
    R.ownDashEscapeFartherStreak = 0
    R.ownDashEscapeConfirmFrames = 0
    R.ownDashEscapeLastDist =
        currentDistance
    R.lastGate =
        "own_dash_escape_not_farther"
    return false
end

-- deactivation
local Deactivation = {}

function Deactivation.ballStopped(speed)
    return speed <= 0
end

function Deactivation.clearConfirmation()
    R.deactivationCandidate = nil
    R.deactivationCandidateAt = 0
    R.deactivationConfirmFrames = 0
    R.deactivationLastConfirmAt = 0
end

function Deactivation.confirm(t, reason)
    if R.deactivationCandidate ~= reason then
        R.deactivationCandidate = reason
        R.deactivationCandidateAt = t
        R.deactivationConfirmFrames = 1
        R.deactivationLastConfirmAt = t
        R.lastGate =
            reason ..
            "_confirming_1"
        return false
    end

    local elapsed =
        t - R.deactivationCandidateAt
    local gap =
        t - R.deactivationLastConfirmAt

    if elapsed < 0
        or gap > T.DEACT_CONFIRM_MAX_GAP then
        Deactivation.clearConfirmation()
        R.deactivationCandidate = reason
        R.deactivationCandidateAt = t
        R.deactivationConfirmFrames = 1
        R.deactivationLastConfirmAt = t
        R.lastGate =
            reason ..
            "_confirming_1"
        return false
    end

    R.deactivationConfirmFrames += 1
    R.deactivationLastConfirmAt = t

    if elapsed < T.DEACT_CONFIRM_HOLD
        or R.deactivationConfirmFrames <
        T.DEACT_CONFIRM_FRAMES then
        R.lastGate =
            reason ..
            "_confirming_"
            .. R.deactivationConfirmFrames
        return false
    end

    Deactivation.clearConfirmation()
    R.lastGate = reason
    return true
end

function Deactivation.direction(
    t,
    snapshot,
    distance,
    radius,
    speed
)
    if snapshot.targeted == true then
        R.lastGate =
            "deact_direction_targeted"
        return false
    end
    local minimumRadius =
        radius *
        T.DEACT_DIRECTION_MIN_RADIUS_FACTOR
    if distance <= minimumRadius then
        R.lastGate =
            "deact_direction_inside_radius"
        return false
    end
    local ping =
        pingCompensation()
    local directionMax =
        math.max(
            lerpBySpeed(
                speed,
                T.DEACT_DIRECTION_MAX_LO +
                ping,
                (
                    T.DEACT_DIRECTION_MAX_LO +
                    ping
                ) *
                T.DEACT_DIRECTION_MAX_MIN_FACTOR,
                T.DEACT_DIRECTION_SPD_LO,
                T.DEACT_DIRECTION_SPD_HI
            ),
            T.MIN_EVAL_INTERVAL * 1.5
        )
    if R.active
        and R.lastClashSwitchAt > 0
        and R.clashIntervalMs > 0 then
        local intervalSec =
            R.clashIntervalMs / 1000
        local lo =
            T.CLASH_CADENCE_INTERVAL_LO
        local hi =
            T.CLASH_CADENCE_INTERVAL_HI
        local buff = 1
        if intervalSec >= lo then
            buff = 1
        elseif intervalSec <= hi then
            buff =
                T.CLASH_CADENCE_BUFF_HI
        else
            local alpha =
                (intervalSec - hi) /
                (lo - hi)
            buff =
                T.CLASH_CADENCE_BUFF_HI +
                (1 - T.CLASH_CADENCE_BUFF_HI) *
                alpha
        end
        directionMax *= buff
    end
    if R.lastDirectionSwitchAt <= 0 then
        return false
    end
    if R.lastSyncAt - R.lastDirectionSwitchAt
        > directionMax then
        return true
    end
    return false
end

function Deactivation.shouldDeactivate(
    t,
    snapshot
)
    if OwnDash.shouldDeactivate(t) then
        if Deactivation.confirm(
            t,
            "own_dash_escape"
        ) then
            return true
        end
        return false
    end

    if t < R.activationDeactLockedUntil then
        Deactivation.clearConfirmation()
        R.lastGate =
            "deact_activation_lock"
        return false
    end

    if t < R.dashDeactLockedUntil then
        Deactivation.clearConfirmation()
        R.lastGate =
            "deact_dash_lock"
        return false
    end

    local root =
        getRootPosition()
    local position =
        getSnapshotPosition(snapshot)
    if not root or not position then
        Deactivation.clearConfirmation()
        R.lastGate =
            "deact_no_position"
        return false
    end

    local radius =
        R.parryRadius
    if radius <= 0 then
        Deactivation.clearConfirmation()
        R.lastGate =
            "deact_no_radius"
        return false
    end

    local speed =
        math.max(R.lastSpeed, 0)
    local distance =
        (root - position).Magnitude

    if Deactivation.ballStopped(speed) then
        if Deactivation.confirm(
            t,
            "deact_ball_stopped"
        ) then
            return true
        end
        return false
    end

    local ping =
        pingCompensation()
    local travelMax =
        lerpBySpeed(
            speed,
            T.DEACT_TRAVEL_MAX_LO +
            ping,
            (
                T.DEACT_TRAVEL_MAX_LO +
                ping
            ) *
            T.DEACT_TRAVEL_MAX_MIN_FACTOR,
            T.DEACT_TRAVEL_SPD_LO,
            T.DEACT_TRAVEL_SPD_HI
        )

    if speed > 0
        and distance / speed > travelMax then
        if R.travelSince == 0 then
            R.travelSince = t
        end
        if t - R.travelSince
            >= T.DEACT_TRAVEL_HOLD +
            ping then
            if Deactivation.confirm(
                t,
                "deact_travel"
            ) then
                R.travelSince = 0
                return true
            end
            return false
        end
    else
        R.travelSince = 0
    end

    if Deactivation.direction(
        t,
        snapshot,
        distance,
        radius,
        speed
    ) then
        if Deactivation.confirm(
            t,
            "deact_direction"
        ) then
            return true
        end
        return false
    end

    Deactivation.clearConfirmation()
    R.lastGate =
        "deact_none"
    return false
end

-- evaluation
local function evaluateClash(
    t,
    snapshot
)
    if not R.boundRoot
        or not R.boundRoot.Parent
        or not snapshot
        or not snapshot.ball
        or not snapshot.ball.Parent then
        return
    end

    updateParryState(
        t,
        snapshot
    )

    if R.active then
        if Deactivation.shouldDeactivate(
            t,
            snapshot
        ) then
            setActive(
                false,
                "target_deactivated"
            )
        end
        return
    end

    if R.returnPending
        and t >= R.returnExpiresAt then
        clearReturnState()
        R.lastGate =
            "return_expired"
        return
    end

    if tryReturnActivate(
        snapshot,
        t
    ) then
        clearReturnState()
        setActive(
            true,
            "activated",
            snapshot
        )
    end
end

-- players
local function getPlayersService()
    if not Utils
        or type(Utils.getPlayers) ~= "function" then
        return nil
    end
    local ok, players =
        pcall(Utils.getPlayers)
    return ok and players or nil
end

-- hub
local function checkHubState()
    if not Utils then
        R.lastGate =
            "no_utils"
        return false
    end

    local ok, manual =
        pcall(
            Utils.isManualSpamActive
        )

    if not ok or manual then
        if R.active then
            setActive(
                false,
                "manual_spam"
            )
        end
        resetTargetState()
        R.lastGate =
            "manual_spam"
        return false
    end

    ok, manual =
        pcall(Utils.isActive)

    if not ok or not manual then
        if R.active then
            setActive(
                false,
                "hub_inactive"
            )
        end
        resetTargetState()
        R.lastGate =
            "hub_inactive"
        return false
    end

    local config
    ok, config =
        pcall(Utils.getConfig)

    if not ok
        or type(config) ~= "table"
        or config.AutoClash ~= true then
        if R.active then
            setActive(
                false,
                "hub_disabled"
            )
        end
        resetTargetState()
        R.lastGate =
            "hub_disabled"
        return false
    end

    return true
end

-- heartbeat
local function heartbeatStep(
    generation,
    character,
    root
)
    if generation ~= R.generation
        or not character.Parent
        or not root.Parent then
        return
    end

    local t = now()

    if not checkHubState() then
        return
    end

    local players =
        getPlayersService()

    if players then
        Dash.tick(
            players,
            t
        )
    end

    if R.returnPending
        and t >= R.returnExpiresAt then
        clearReturnState()
        R.lastGate =
            "return_expired"
    end

    if t - R.lastEvalAt <
        T.MIN_EVAL_INTERVAL then
        return
    end

    R.lastEvalAt = t

    if not GameInfo
        or type(GameInfo.getSnapshot) ~= "function"
        or type(GameInfo.isSnapshotValid) ~= "function" then
        R.lastGate =
            "no_gameinfo"
        return
    end

    local ok, snapshot =
        pcall(
            GameInfo.getSnapshot,
            R.lastTarget,
            t
        )

    if not ok
        or type(snapshot) ~= "table" then
        R.lastGate =
            "snapshot_error"
        return
    end

    local validOk, valid =
        pcall(
            GameInfo.isSnapshotValid,
            snapshot,
            t
        )

    if not validOk
        or valid ~= true then
        return
    end

    local target =
        normalizeTarget(
            snapshot.targetId
        )

    if target then
        R.lastTarget = target
    end

    evaluateClash(
        t,
        snapshot
    )
end

-- character
local function bindCharacter(character)
    resetRuntime(
        "rebind",
        true
    )

    local generation =
        R.generation

    if not character
        or not character.Parent then
        return false
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )
        or character:WaitForChild(
            "HumanoidRootPart",
            1
        )

    if generation ~= R.generation
        or not root
        or not root.Parent then
        return false
    end

    R.boundRoot = root
    R.lastGate =
        "waiting_for_character"

    if not Utils
        or type(Utils.getRunService) ~= "function" then
        R.boundRoot = nil
        R.lastGate =
            "no_run_service"
        return false
    end

    local ok, runService =
        pcall(
            Utils.getRunService
        )

    if not ok
        or not runService
        or not runService.Heartbeat then
        R.boundRoot = nil
        R.lastGate =
            "no_run_service"
        return false
    end

    local heartbeat =
        runService.Heartbeat:Connect(
            function()
                heartbeatStep(
                    generation,
                    character,
                    root
                )
            end
        )

    addConnection(
        R.connections,
        heartbeat
    )

    if type(Utils.trackCharacter) == "function" then
        pcall(
            Utils.trackCharacter,
            heartbeat
        )
    end

    local ancestry =
        character.AncestryChanged:Connect(
            function(_, parent)
                if parent then
                    return
                end
                resetRuntime(
                    "character_removed",
                    false
                )
                R.lastGate =
                    "character_removed"
            end
        )

    addConnection(
        R.connections,
        ancestry
    )

    if type(Utils.trackCharacter) == "function" then
        pcall(
            Utils.trackCharacter,
            ancestry
        )
    end

    R.bound = true

    setPhase(
        "waiting",
        "character_bound"
    )

    local players =
        getPlayersService()

    if players and #R.dashConnections == 0 then
        Dash.init(players)
    end

    return true
end

-- sync
function AutoClash.onBallSync(data)
    if type(data) ~= "table"
        or not Utils
        or not R.localUserId then
        return
    end

    local t = now()
    R.lastSyncAt = t

    if data.Teleported == true then
        if R.active then
            setActive(
                false,
                "teleported"
            )
        end
        resetTargetState()
        R.lastGate =
            "teleported"
        return
    end

    local target =
        normalizeTarget(
            data.TargetPlayerID
        )

    if not target then
        if R.active then
            setActive(
                false,
                "invalid_target"
            )
        end
        resetTargetState()
        R.lastGate =
            "invalid_target"
        return
    end

    local previousTarget =
        R.lastTarget

    local wasMe =
        R.wasMeTarget

    local isMe =
        target == R.localUserId

    R.lastTarget =
        target

    if R.active
        and R.clashPartnerId ~= -1
        and R.clashPartnerId ~= R.localUserId then
        local previousWasPartner =
            previousTarget ==
            R.clashPartnerId

        local currentIsPartner =
            target ==
            R.clashPartnerId

        local partnerSideChanged =
            previousWasPartner ~=
            currentIsPartner

        local meSideChanged =
            (wasMe == true) ~=
            isMe

        if partnerSideChanged
            and meSideChanged
            and (
                previousWasPartner
                or currentIsPartner
            ) then
            if R.lastClashSwitchAt > 0
                and t >= R.lastClashSwitchAt then
                R.clashIntervalMs =
                    (
                        t -
                        R.lastClashSwitchAt
                    ) *
                    1000
            end
            R.lastClashSwitchAt =
                t
        end
    end

    if wasMe == nil then
        R.wasMeTarget = isMe
        clearReturnState()

        if isMe then
            R.lastGate =
                "initial_me"
        else
            R.lastGate =
                "initial_not_me"
        end

        return
    end

    if wasMe ~= isMe then
        R.lastDirectionSwitchAt =
            t
    end

    if wasMe and not isMe then
        R.lostMeAt =
            t

        local returnWindow =
            getReturnWindow(
                R.lastSpeed
            )

        if t < R.dashBonusUntil then
            returnWindow *=
                T.DASH_BONUS_RETURN_MULT
        end

        R.returnWindow =
            returnWindow

        R.returnExpiresAt =
            t + returnWindow

        R.returnFromTarget =
            target

        R.returnPending =
            false

        R.returnToken += 1

        if R.active then
            if not rallyCheck(data) then
                R.wasMeTarget =
                    isMe
                return
            end
        else
            R.clashPartnerId =
                target
        end

        R.lastGate =
            "target_lost"

    elseif not wasMe and isMe then
        if R.lostMeAt <= 0
            or R.returnExpiresAt <= 0
            or R.returnToken <= 0 then
            clearReturnState()
            R.lastGate =
                "return_without_loss"
        elseif t < R.lostMeAt then
            clearReturnState()
            R.lastGate =
                "return_invalid_time"
        elseif t >= R.returnExpiresAt then
            clearReturnState()
            R.lastGate =
                "return_too_late"
        else
            if previousTarget ~= -1
                and previousTarget ~=
                R.localUserId then
                R.clashPartnerId =
                    previousTarget
            end

            local cooldownEnd =
                math.max(
                    t,
                    R.reactivateBlockedUntil
                )

            R.returnExpiresAt =
                cooldownEnd +
                R.returnWindow

            R.returnPending =
                true

            R.lastGate =
                "target_return"
        end
    end

    R.wasMeTarget =
        isMe
end

-- setup
function AutoClash.setup(deps)
    if type(deps) ~= "table" then
        return false
    end

    local required = {
        { "AutoParry", "getParryRadius" },
        { "AutoParry", "getPingOneWay" },
        { "GameInfo", "getSnapshot" },
        { "GameInfo", "isSnapshotValid" },
        { "Utils", "now" },
        { "Utils", "getConfig" },
        { "Utils", "getRunService" },
        { "Utils", "getPlayers" },
        { "Utils", "recordTransition" },
        { "Utils", "setAutoSpamActive" },
        { "Utils", "trackCharacter" },
        { "Utils", "untrackCharacter" },
        { "Utils", "isActive" },
        { "Utils", "isManualSpamActive" },
        { "Utils", "getLocalPlayer" },
        { "Utils", "apiVersion" },
    }

    for _, requirement in ipairs(required) do
        local object =
            deps[requirement[1]]

        if not object
            or type(
                object[
                    requirement[2]
                ]
            ) ~= "function" then
            return false
        end
    end

    if Utils then
        resetRuntime(
            "setup",
            false
        )
    else
        disconnectDashConnections()
        disconnectCharacterConnections()
    end

    AutoParry =
        deps.AutoParry

    GameInfo =
        deps.GameInfo

    Utils =
        deps.Utils

    local player

    local ok =
        pcall(function()
            player =
                Utils.getLocalPlayer()
        end)

    if not ok or not player then
        AutoParry = nil
        GameInfo = nil
        Utils = nil
        return false
    end

    R.localUserId =
        player.UserId

    R.generation = 0
    R.bound = false
    R.active = false
    R.phase = "detached"
    R.boundRoot = nil
    R.lastSpeed = 0
    R.parryRadius = 0
    R.lastSyncAt = 0
    R.lastEvalAt = 0
    R.lastDashScanAt = 0
    R.reactivateBlockedUntil = 0
    R.activationDeactLockedUntil = 0

    R.connections = {}
    R.dashConnections = {}
    R.dashCharacterConnections = {}
    R.dashPlayerConnections = {}
    R.dashGeneration = 0

    resetTargetState()
    resetDeactivationState()
    clearDashState()

    R.lastGate =
        "none"

    local players =
        getPlayersService()

    if players then
        Dash.init(players)
    end

    return true
end

-- character
function AutoClash.bindCharacter(character)
    return bindCharacter(character)
end

function AutoClash.detachCharacter()
    resetRuntime(
        "detach",
        false
    )
end

function AutoClash.teardown()
    resetRuntime(
        "teardown",
        false
    )
    AutoParry = nil
    GameInfo = nil
    Utils = nil
end

-- state
function AutoClash.isActive()
    return R.active == true
end

function AutoClash.getStatus()
    local schema

    if Utils
        and type(Utils.apiVersion) == "function" then
        local ok, value =
            pcall(
                Utils.apiVersion
            )

        if ok then
            schema = value
        end
    end

    return {
        schema = schema,
        phase = R.phase,
        bound = R.bound == true,
        active = R.active == true,
        parryRadius = R.parryRadius,
        lastTarget = R.lastTarget,
        clashPartnerId = R.clashPartnerId,
        lastGate = R.lastGate,
        ownDashEscapePending =
            R.ownDashEscapePending == true,
        ownDashEscapeConfirmFrames =
            R.ownDashEscapeConfirmFrames,
        returnPending =
            R.returnPending == true,
        returnWindow =
            R.returnWindow,
        returnExpiresAt =
            R.returnExpiresAt,
        returnFromTarget =
            R.returnFromTarget,
        returnToken =
            R.returnToken,
        dashBonusUntil =
            R.dashBonusUntil,
        dashDeactLockedUntil =
            R.dashDeactLockedUntil,
        deactivationCandidate =
            R.deactivationCandidate,
        deactivationConfirmFrames =
            R.deactivationConfirmFrames,
        deactivationCandidateAt =
            R.deactivationCandidateAt,
    }
end

-- contract
AutoClash.__contract = {
    requires = {
        AutoParry = "autoparry",
        GameInfo = "gameinfo",
        Utils = "utils",
    },
    onBallSync = true,
    bindCharacter = true,
}

return AutoClash