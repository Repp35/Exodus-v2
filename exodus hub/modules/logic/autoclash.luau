-- [[ AutoClash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Dash
local Utils

-- tuning
local T = {
        -- activation
        RETURN_WIN_LO = 0.15,
        RETURN_WIN_MIN_FACTOR = 0.10,
        RETURN_SPD_LO = 60,
        RETURN_SPD_HI = 600,
        PING_FACTOR = 0.3,
        ACT_RADIUS_MIN = 15,
        ACT_RADIUS_WINDOW = 0.150,
        REACTIVATE_COOLDOWN = 0.070,
        ACT_DEACT_LOCK_RADIUS_FACTOR = 0.70,
        ACT_DEACT_LOCK_TIME = 0.05,
        PROXIMITY_RADIUS = 6,
        PROXIMITY_WINDOW_MULT = 2.0,
        DASH_DETECT_WINDOW = 0.25,
        OWN_DASH_ESCAPE_CONFIRM_FRAMES = 2,
        DASH_RETURN_DOT = 0.3,
        DASH_RETURN_RADIUS_MULT = 3.0,
        DASH_DEACT_LOCK_TIME = 0.070,
        DASH_RADIUS_BONUS_TIME = 0.700,
        DASH_BONUS_RETURN_MULT = 10.0,
        APPROACH_RETURN_MULT = 1.60,
        APPROACH_BALL_WINDOW = 0.150,
        OWN_DASH_ESCAPE_DOT = -0.3,
        DASH_REGISTER_DEBOUNCE = 0.050,
        OWN_DASH_ESCAPE_HOLD = 0.060,
        OWN_DASH_ESCAPE_MIN_SEPARATION_SPEED = 18,
        OWN_DASH_ESCAPE_SPEED_FACTOR = 0.08,
        -- deactivation
        DEACT_DIRECTION_MAX_LO = 0.11,
        DEACT_DIRECTION_MAX_MIN_FACTOR = 0.10,
        DEACT_DIRECTION_SPD_LO = 60,
        DEACT_DIRECTION_SPD_HI = 600,
        DEACT_CONFIRM_HOLD = 0.025,
        DEACT_CONFIRM_FRAMES = 2,
        DEACT_CONFIRM_MAX_GAP = 0.100,
        CLASH_CADENCE_INTERVAL_LO = 1 / 14,
        CLASH_CADENCE_INTERVAL_HI = 0.0435,
        CLASH_CADENCE_BUFF_HI = 95 / 55,
        -- system
        MIN_EVAL_INTERVAL = 1 / 120,
        DASH_ANIMATION_SCAN_INTERVAL = 1 / 30,
        DASH_VELOCITY_SCAN_INTERVAL = 1 / 30,
        DASH_CLEAN_INTERVAL = 0.10,
}

-- runtime
local R = {
        generation = 0,
        bound = false,
        active = false,
        phase = "detached",
        boundRoot = nil,
        localUserId = nil,
        players = nil,
        playerList = {},
        lastTarget = -1,
        clashPartnerId = -1,
        lastSpeed = 0,
        parryRadius = 0,
        dashBonusUntil = 0,
        dashDeactLockedUntil = 0,
        wasMeTarget = nil,
        lostMeAt = 0,
        returnExpiresAt = 0,
        returnWindow = 0,
        returnPending = false,
        returnFromTarget = -1,
        returnToken = 0,
        lastSyncAt = 0,
        -- activation
        activationDeactLockedUntil = 0,
        reactivateBlockedUntil = 0,

        -- clash
        lastDirectionSwitchAt = 0,
        lastClashSwitchAt = 0,
        clashIntervalMs = 0,
        targetResetToken = 0,

        -- deactivation
        deactivationCandidate = nil,
        deactivationCandidateAt = 0,
        deactivationConfirmFrames = 0,
        deactivationLastConfirmAt = 0,

        -- activation timing
        becameMeAt = 0,

        -- approach
        approachBonusUntil = 0,
        opponentWasOutside = false,
        ballLeftRadiusDuring = false,

        -- evaluation
        lastEvalAt = 0,

        -- debug
        lastGate = "none",
        ownDashEscapePending = false,
        ownDashEscapeDetectedAt = 0,
        ownDashEscapeConfirmFrames = 0,
        ownDashEscapeLastDist = nil,
        ownDashEscapeLastAt = 0,
        ownDashEscapeFartherStreak = 0,
        lastActivationAt = 0,
        lastActivationSource = "none",
        lastDashEvent = nil,

        -- connections
        connections = {},
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
        if not value
                or value ~= value
                or value == math.huge
                or value == -math.huge then
                return 0
        end
        return value
end
local function finiteNumber(value, fallback)
        value = tonumber(value)
        if not value
                or value ~= value
                or value == math.huge
                or value == -math.huge then
                return fallback or 0
        end
        return value
end
local function normalizeTarget(target)
        if type(target) == "string" then
                target = tonumber(target)
        end
        if type(target) ~= "number"
                or target ~= target
                or target < 1
                or target == math.huge
                or target == -math.huge
                or target % 1 ~= 0 then
                return nil
        end
        return target
end
local function lerpBySpeed(speed, low, high, speedLow, speedHigh)
        speed = finiteNumber(speed, 0)
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
local function horizontalSpeed(v)
        if typeof(v) ~= "Vector3" then
                return 0
        end
        return math.sqrt(v.X * v.X + v.Z * v.Z)
end
local function getRootPosition()
        local root = R.boundRoot
        if not root or not root.Parent then
                return nil
        end
        local position = root.Position
        return typeof(position) == "Vector3" and position or nil
end
local function getSnapshotPosition(snapshot)
        local position = snapshot and snapshot.position
        return typeof(position) == "Vector3" and position or nil
end
local function getDataPosition(data)
        local position = data and data.RealPosition
        return typeof(position) == "Vector3" and position or nil
end
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
                or value <= 0
                or value == math.huge
                or value == -math.huge then
                return 0
        end
        return value
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
        return math.max(
                base + pingCompensation(),
                2 / 60
        )
end
local function setPhase(phase, reason)
        if R.phase == phase then
                return
        end
        local previous = R.phase
        R.phase = phase
        if Utils and type(Utils.recordTransition) == "function" then
                pcall(
                        Utils.recordTransition,
                        "AutoClash",
                        previous,
                        phase,
                        reason
                )
        end
end
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
-- state
local function clearReturnState()
        R.lostMeAt = 0
        R.returnExpiresAt = 0
        R.returnWindow = 0
        R.returnPending = false
        R.returnFromTarget = -1
        R.returnToken += 1
end
local function resetTargetState()
        R.targetResetToken += 1
        R.lastTarget = -1
        R.clashPartnerId = -1
        R.dashBonusUntil = 0
        R.wasMeTarget = nil
        clearReturnState()
        R.lastClashSwitchAt = 0
        R.clashIntervalMs = 0
        R.approachBonusUntil = 0
        R.opponentWasOutside = false
        R.ballLeftRadiusDuring = false
        R.becameMeAt = 0
        R.lastDashEvent = nil
        R.lastActivationAt = 0
        R.lastActivationSource = "none"
end
local function resetOwnDashState()
        R.ownDashEscapePending = false
        R.ownDashEscapeDetectedAt = 0
        R.ownDashEscapeConfirmFrames = 0
        R.ownDashEscapeLastDist = nil
        R.ownDashEscapeLastAt = 0
        R.ownDashEscapeFartherStreak = 0
end
local function resetDeactivationState()
        resetOwnDashState()
        R.dashDeactLockedUntil = 0
        R.deactivationCandidate = nil
        R.deactivationCandidateAt = 0
        R.deactivationConfirmFrames = 0
        R.deactivationLastConfirmAt = 0
end

-- activation
local function setActivationLock(t, snapshot)
        R.activationDeactLockedUntil = 0
        local root = getRootPosition()
        local position = getSnapshotPosition(snapshot)
        if not root
                or not position
                or R.parryRadius <= 0 then
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
                R.lastActivationAt = t
                R.lastActivationSource =
                        t < R.dashBonusUntil
                        and "anti_dash"
                        or "normal"
                if R.clashPartnerId == -1
                        and R.lastTarget ~= R.localUserId
                        and R.lastTarget ~= -1 then
                        R.clashPartnerId = R.lastTarget
                end
                setActivationLock(t, snapshot)
                if t < R.dashBonusUntil then
                        R.dashDeactLockedUntil =
                                t
                                + T.DASH_DEACT_LOCK_TIME
                                + pingCompensation()
                end
        else
                R.clashPartnerId = -1
				local candidateBlock =
						t
						+ T.REACTIVATE_COOLDOWN
				if R.reactivateBlockedUntil < candidateBlock then
                        R.reactivateBlockedUntil = candidateBlock
                end
				R.activationDeactLockedUntil = 0
				R.dashDeactLockedUntil = 0
		end
        if Utils and type(Utils.setAutoSpamActive) == "function" then
                pcall(Utils.setAutoSpamActive, active)
        end
        setPhase(
                active and "active" or "idle",
                reason
        )
end
local function resetRuntime(reason, keepDashDetection)
        R.generation += 1
        if R.active then
                setActive(false, reason or "reset")
        end
        disconnectList(R.connections, true)
        R.bound = false
        R.boundRoot = nil
        R.lastSpeed = 0
        R.parryRadius = 0
        R.lastSyncAt = 0
        R.lastEvalAt = 0
        R.reactivateBlockedUntil = 0
        R.activationDeactLockedUntil = 0
        resetTargetState()
        resetDeactivationState()
        R.lastGate = "detached"
        setPhase(
                "detached",
                reason or "reset"
        )
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
                and radius >= 0
                and radius < math.huge then
                R.parryRadius = radius
        end
end
local function updateParryState(t, snapshot)
        R.lastSpeed = math.max(
                finiteNumber(
                        snapshot and snapshot.speed,
                        0
                ),
                0
        )
        refreshParryRadius(t)
end

-- activation
local function canReactivate(t, targetId)
        if t < R.reactivateBlockedUntil then
                R.lastGate = "reactivate_cooldown"
                return false
        end
        return true
end
local function getDashActivationRadius(t)
        local base =
                math.max(
                        R.parryRadius,
                        T.ACT_RADIUS_MIN
                )
        local speedBonus =
                R.lastSpeed * T.ACT_RADIUS_WINDOW
        base += speedBonus
        if t < R.dashBonusUntil
                and R.lastSpeed > 0 then
                base += speedBonus
        end
        return base
end
local function shouldActivate(snapshot, t)
        if not snapshot
                or not snapshot.ball
                or not snapshot.ball.Parent then
                R.lastGate = "no_ball"
                return false
        end
        if snapshot.targeted ~= true then
                R.lastGate = "target_not_me"
                return false
        end
        local root = getRootPosition()
        local position =
                getSnapshotPosition(snapshot)
        if not root then
                R.lastGate = "no_root"
                return false
        end
        if not position
                or R.parryRadius <= 0 then
                R.lastGate = "no_effective_radius"
                return false
        end
        local distance =
                (root - position).Magnitude
        local effectiveRadius =
                getDashActivationRadius(t)
        if distance <= T.PROXIMITY_RADIUS then
                effectiveRadius *=
                        T.PROXIMITY_WINDOW_MULT
        end
        if distance > effectiveRadius then
                R.lastGate =
                        "outside_effective_radius"
                return false
        end
        R.lastGate = "activation_ready"
        return true
end
local function tryReturnActivate(snapshot, t)
        if not snapshot
                or snapshot.targeted ~= true then
                R.lastGate = "act_not_targeted"
                return false
        end
        if not R.returnPending then
                R.lastGate = "act_no_return_pending"
                return false
        end
        if R.returnExpiresAt <= 0
                or t >= R.returnExpiresAt then
                R.lastGate = "act_return_expired"
                return false
        end
        return canReactivate(t, R.lastTarget)
                and shouldActivate(snapshot, t)
end

-- deactivation
local Deactivation = {}
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
                        reason
                        .. "_confirming_1"
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
                        reason
                        .. "_confirming_1"
                return false
        end
        R.deactivationConfirmFrames += 1
        R.deactivationLastConfirmAt = t
        if elapsed < T.DEACT_CONFIRM_HOLD
                or R.deactivationConfirmFrames
                        < T.DEACT_CONFIRM_FRAMES then
                R.lastGate =
                        reason
                        .. "_confirming_"
                        .. R.deactivationConfirmFrames
                return false
        end
        Deactivation.clearConfirmation()
        R.lastGate = reason
        return true
end
function Deactivation.direction(t, snapshot, speed)
        if snapshot.targeted == true then
                R.lastGate =
                        "deact_direction_targeted"
                return false
        end
        if R.lastDirectionSwitchAt <= 0 then
                return false
        end
        if R.lastSyncAt < R.lastDirectionSwitchAt then
                return false
        end
        local ping = pingCompensation()
        local base =
                T.DEACT_DIRECTION_MAX_LO
                + ping
        local directionMax =
                math.max(
                        lerpBySpeed(
                                speed,
                                base,
                                base
                                        * T.DEACT_DIRECTION_MAX_MIN_FACTOR,
                                T.DEACT_DIRECTION_SPD_LO,
                                T.DEACT_DIRECTION_SPD_HI
                        ),
                        T.MIN_EVAL_INTERVAL * 1.5
                )
        return
                t - R.lastDirectionSwitchAt
                > directionMax
end

-- rally
local function rallyCheck(data, t)
        if not R.active
                or type(data) ~= "table" then
                return true
        end
        local target =
                normalizeTarget(
                        data.TargetPlayerID
                )
        if not target
                or target == R.localUserId
                or target == R.clashPartnerId then
                return true
        end
        local position =
                getDataPosition(data)
        local root =
                getRootPosition()
        if not position
                or not root
                or R.parryRadius <= 0 then
                return true
        end
        local radius =
                math.max(
                        R.parryRadius,
                        T.ACT_RADIUS_MIN
                )
                + R.lastSpeed
                        * T.ACT_RADIUS_WINDOW
        if (root - position).Magnitude > radius then
                return not Deactivation.confirm(
                        t,
                        "rally_outside_effective_radius"
                )
        end
        Deactivation.clearConfirmation()
        R.clashPartnerId = target
        return true
end

-- dash
local function getHorizontalDistance(a, b)
        if typeof(a) ~= "Vector3" or typeof(b) ~= "Vector3" then
                return math.huge
        end
        local x = a.X - b.X
        local z = a.Z - b.Z
        return math.sqrt(x * x + z * z)
end

local function onDashDetected(event)
        if type(event) == "table" then
                R.lastDashEvent = event
        end
        if type(event) ~= "table"
                or not event.player
                or R.clashPartnerId == -1
                or event.userId ~= R.clashPartnerId
                or R.parryRadius <= 0
                or typeof(event.position) ~= "Vector3"
                or typeof(event.velocity) ~= "Vector3" then
                return
        end
        local localRoot = getRootPosition()
        if not localRoot then
                return
        end
        local distance = getHorizontalDistance(localRoot, event.position)
        local speed = horizontalSpeed(event.velocity)
        if distance <= 0 or speed <= 0 then
                return
        end
        local toRoot = localRoot - event.position
        local dot = (
                event.velocity.X * toRoot.X
                + event.velocity.Z * toRoot.Z
        ) / (speed * distance)
        if dot < T.DASH_RETURN_DOT
                or distance > R.parryRadius * T.DASH_RETURN_RADIUS_MULT
                or math.abs(event.velocity.Y) > speed * 0.75 then
                return
        end
        if typeof(event.previousPosition) == "Vector3"
                and distance >= getHorizontalDistance(localRoot, event.previousPosition) then
                return
        end
        local t = event.detectedAt
        R.dashBonusUntil = t + T.DASH_RADIUS_BONUS_TIME + pingCompensation()
        if R.returnPending and R.returnWindow > 0 then
                R.returnWindow = getReturnWindow(R.lastSpeed) * T.DASH_BONUS_RETURN_MULT
                R.returnExpiresAt = math.max(R.returnExpiresAt, t + R.returnWindow)
        end
end

local OwnDash = {}
function OwnDash.getOpponent()
        local id =
                R.clashPartnerId
        if id == -1
                or id == R.localUserId
                or not R.players then
                return nil
        end
        local opponent =
                R.players:GetPlayerByUserId(id)
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
        if not root
                or not root.Parent then
                return nil
        end
        return opponent, root
end
function OwnDash.getRecentThreat(t)
        local event = R.lastDashEvent
        if not event
                or not event.player
                or event.userId ~= R.clashPartnerId
                or not event.player.Parent then
                return nil
        end
        local age = t - event.detectedAt
        if age < 0
                or age > T.DASH_DETECT_WINDOW + pingCompensation() then
                return nil
        end
        return event
end
function OwnDash.shouldDeactivate(t)
        if not R.active then
                resetOwnDashState()
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
        local _, opponentRoot =
                OwnDash.getOpponent()
        if not opponentRoot then
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
                                > T.DASH_DETECT_WINDOW
                                        + pingCompensation() then
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
                or R.ownDashEscapeDetectedAt
                        ~= event.detectedAt then
                R.ownDashEscapePending = true
                R.ownDashEscapeDetectedAt =
                        event.detectedAt
                R.ownDashEscapeConfirmFrames = 0
                R.ownDashEscapeFartherStreak = 0
                R.ownDashEscapeLastDist =
                        (ownRoot - opponentRoot.Position).Magnitude
                R.ownDashEscapeLastAt = t
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
                R.ownDashEscapeLastAt = t
                R.lastGate =
                        "own_dash_escape_first"
                return false
        end
        local sampleDt = t - R.ownDashEscapeLastAt
        if sampleDt <= 0 or sampleDt > T.DEACT_CONFIRM_MAX_GAP then
                R.ownDashEscapeFartherStreak = 0
                R.ownDashEscapeConfirmFrames = 0
                R.ownDashEscapeLastDist = currentDistance
                R.ownDashEscapeLastAt = t
                R.lastGate =
                        "own_dash_escape_sample_gap"
                return false
        end
        local deltaDistance = currentDistance - previousDistance
        local awayX = (ownRoot.Position.X - opponentRoot.Position.X)
                / math.max(currentDistance, 0.001)
        local awayZ = (ownRoot.Position.Z - opponentRoot.Position.Z)
                / math.max(currentDistance, 0.001)
        local opponentVelocity = opponentRoot.AssemblyLinearVelocity
        local separationSpeed =
                opponentVelocity.X * -awayX
                + opponentVelocity.Z * -awayZ
        local requiredSeparationSpeed = math.max(
                T.OWN_DASH_ESCAPE_MIN_SEPARATION_SPEED,
                horizontalSpeed(opponentVelocity)
                        * T.OWN_DASH_ESCAPE_SPEED_FACTOR
        )
        local measuredSeparationSpeed =
                deltaDistance / sampleDt
        local effectiveSeparationSpeed = math.max(
                separationSpeed,
                measuredSeparationSpeed
        )
        local isMeaningfulEscape =
                deltaDistance > 0
                and effectiveSeparationSpeed >= requiredSeparationSpeed
        R.ownDashEscapeLastDist = currentDistance
        R.ownDashEscapeLastAt = t
        if isMeaningfulEscape then
                R.ownDashEscapeFartherStreak += 1
                R.ownDashEscapeConfirmFrames += 1
                R.lastGate =
                        "own_dash_escape_farther_"
                        .. R.ownDashEscapeFartherStreak
                return
                        t - R.ownDashEscapeDetectedAt
                                >= T.OWN_DASH_ESCAPE_HOLD
                        and R.ownDashEscapeFartherStreak
                                >= T.OWN_DASH_ESCAPE_CONFIRM_FRAMES
        end
        R.ownDashEscapeFartherStreak = 0
        R.ownDashEscapeConfirmFrames = 0
        R.ownDashEscapeLastDist =
                currentDistance
        R.ownDashEscapeLastAt = t
        R.lastGate =
                "own_dash_escape_not_farther"
        return false
end

-- deactivation
function Deactivation.shouldDeactivate(
        t,
        snapshot
)
        if OwnDash.shouldDeactivate(t) then
                R.lastGate =
                        "own_dash_escape"
                return true
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
        if not root
                or not position
                or R.parryRadius <= 0 then
                Deactivation.clearConfirmation()
                R.lastGate =
                        "deact_no_position"
                return false
        end
        local speed =
                R.lastSpeed
        if speed <= 0 then
                R.lastGate =
                        "deact_ball_stopped"
                return true
        end
        if Deactivation.direction(
                t,
                snapshot,
                speed
        ) then
                R.lastGate =
                        "deact_direction"
                return true
        end
        Deactivation.clearConfirmation()
        R.lastGate =
                "deact_none"
        return false
end

-- evaluation
local function evaluateApproach(
        t,
        snapshot
)
        if R.lastDirectionSwitchAt <= 0
                or R.parryRadius <= 0
                or R.lastSpeed <= 0 then
                return
        end
        local root =
                getRootPosition()
        local position =
                getSnapshotPosition(snapshot)
        if not root or not position then
                return
        end
        local _, opponentRoot =
                OwnDash.getOpponent()
        if not opponentRoot then
                return
        end
        local effectiveRadius =
                R.parryRadius
                + R.lastSpeed
                        * T.APPROACH_BALL_WINDOW
        local ballDistance =
                (root - position).Magnitude
        local opponentDistance =
                (root - opponentRoot.Position).Magnitude
        if ballDistance > effectiveRadius then
                R.ballLeftRadiusDuring = true
        end
        if opponentDistance > effectiveRadius then
                R.opponentWasOutside = true
                R.ballLeftRadiusDuring = false
        end
        if R.opponentWasOutside
                and opponentDistance <= effectiveRadius
                and not R.ballLeftRadiusDuring then
                R.approachBonusUntil =
                        t + T.APPROACH_BALL_WINDOW
                R.opponentWasOutside = false
                R.ballLeftRadiusDuring = false
        end
end
local function evaluateClash(
        t,
        snapshot
)
        if not R.boundRoot
                or not R.boundRoot.Parent then
                return
        end
        local snapshotUsable =
                snapshot
                and snapshot.ball
                and snapshot.ball.Parent
        if R.active
                and not snapshotUsable then
                if t >= R.activationDeactLockedUntil then
                        R.lastGate = "ball_lost"
                        setActive(
                                false,
                                "ball_lost"
                        )
                else
                        R.lastGate =
                                "ball_lost_pending"
                end
                return
        end
        if not snapshotUsable then
                clearReturnState()
                R.lastGate = "no_ball"
                return
        end
        updateParryState(
                t,
                snapshot
        )
        evaluateApproach(
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

-- services
local function getPlayersService()
        if R.players
                and R.players.Parent then
                return R.players
        end
        if not Utils
                or type(Utils.getPlayers)
                        ~= "function" then
                return nil
        end
        local ok, players =
                pcall(Utils.getPlayers)
        if ok and players then
                R.players = players
        end
        return R.players
end

-- hub
local function checkHubState()
        if not Utils then
                R.lastGate = "no_utils"
                return false
        end
        local ok, state =
                pcall(Utils.isManualSpamActive)
        if not ok or state then
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
        ok, state =
                pcall(Utils.isActive)
        if not ok or not state then
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
        Dash.tick(t)
        if R.returnPending
                and t >= R.returnExpiresAt then
                clearReturnState()
                R.lastGate =
                        "return_expired"
        end
        if t - R.lastEvalAt
                < T.MIN_EVAL_INTERVAL then
                return
        end
        R.lastEvalAt = t
        if not GameInfo
                or type(GameInfo.getSnapshot)
                        ~= "function"
                or type(GameInfo.isSnapshotValid)
                        ~= "function" then
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
        if not Utils
                or type(Utils.getRunService)
                        ~= "function" then
                R.boundRoot = nil
                R.lastGate =
                        "no_run_service"
                return false
        end
        local ok, runService =
                pcall(Utils.getRunService)
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
        if type(Utils.trackCharacter)
                == "function" then
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
        if type(Utils.trackCharacter)
                == "function" then
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
                        if Deactivation.confirm(
                                t,
                                "invalid_target"
                        ) then
                                setActive(
                                        false,
                                        "invalid_target"
                                )
                        end
                else
                        clearReturnState()
                end
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
        R.lastTarget = target
        if R.active
                and R.clashPartnerId ~= -1
                and R.clashPartnerId ~= R.localUserId then
                local previousWasPartner =
                        previousTarget
                        == R.clashPartnerId
                local currentIsPartner =
                        target
                        == R.clashPartnerId
                if previousWasPartner
                                ~= currentIsPartner
                        and (wasMe == true)
                                ~= isMe
                        and (
                                previousWasPartner
                                or currentIsPartner
                        ) then
                        if R.lastClashSwitchAt > 0
                                and t >= R.lastClashSwitchAt then
                                R.clashIntervalMs =
                                        (
                                                t
                                                - R.lastClashSwitchAt
                                        ) * 1000
                        end
                        R.lastClashSwitchAt = t
                end
        end
        if wasMe == nil then
                R.wasMeTarget = isMe
                clearReturnState()
                R.lastGate =
                        isMe
                        and "initial_me"
                        or "initial_not_me"
                return
        end
        if wasMe ~= isMe then
                R.lastDirectionSwitchAt = t
                if isMe then
                        R.becameMeAt = t
                end
        end
        if wasMe and not isMe then
                R.lostMeAt = t
                local returnWindow =
                        getReturnWindow(
                                R.lastSpeed
                        )
                if t < R.dashBonusUntil then
                        returnWindow *=
                                T.DASH_BONUS_RETURN_MULT
                end
                if t < R.approachBonusUntil then
                        returnWindow *=
                                T.APPROACH_RETURN_MULT
                end
                R.returnWindow =
                        returnWindow
                R.returnExpiresAt =
                        t + returnWindow
                R.returnFromTarget =
                        target
                R.returnPending = false
                R.returnToken += 1
                if R.active then
                        if t >= R.activationDeactLockedUntil
                                and t >= R.dashDeactLockedUntil then
                                setActive(
                                        false,
                                        "target_switched"
                                )
                                R.lastGate =
                                        "target_switched"
                                R.wasMeTarget =
                                        isMe
                                return
                        end
                        if not rallyCheck(
                                data,
                                t
                        ) then
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
                        or R.returnExpiresAt <= 0 then
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
                                and previousTarget
                                        ~= R.localUserId then
                                R.clashPartnerId =
                                        previousTarget
                        end
                        R.returnPending = true
                        R.lastGate =
                                "target_return"
                end
        end
        R.wasMeTarget = isMe
end

-- setup
function AutoClash.setup(deps)
        if type(deps) ~= "table" then
                return false, "dependências inválidas"
        end
        local required = {
                { "AutoParry", "getParryRadius" },
                { "AutoParry", "getPingOneWay" },
                { "Dash", "setHandler" },
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

        for i = 1, #required do
                local requirement =
                        required[i]
                local object =
                        deps[requirement[1]]
                if not object
                        or type(object[requirement[2]])
                                ~= "function" then
                        return false, requirement[1] .. "." .. requirement[2] .. " ausente"
                end
        end
        if Utils then
                resetRuntime(
                        "setup",
                        false
                )
        else
                disconnectList(
                        R.connections,
                        true
                )
        end
        AutoParry =
                deps.AutoParry
        Dash =
                deps.Dash
        GameInfo =
                deps.GameInfo
        Utils =
                deps.Utils
        Dash.setHandler(onDashDetected)
        local ok, player =
                pcall(
                        Utils.getLocalPlayer
                )
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
        R.players = nil
        R.lastSpeed = 0
        R.parryRadius = 0
        R.lastSyncAt = 0
        R.lastEvalAt = 0
        R.reactivateBlockedUntil = 0
        R.activationDeactLockedUntil = 0
        R.connections = {}
        resetTargetState()
        resetDeactivationState()
        R.players = getPlayersService()
        R.lastGate = "none"
        return true
end

-- character
function AutoClash.bindCharacter(
        character
)
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
        if Dash and type(Dash.setHandler) == "function" then
                Dash.setHandler(nil)
        end
        AutoParry = nil
        GameInfo = nil
        Dash = nil
        Utils = nil
        R.players = nil
        R.localUserId = nil
end

-- state
function AutoClash.isActive()
        return R.active == true
end
function AutoClash.getTargetSwitch()
        return {
                timestampMs = R.lastClashSwitchAt * 1000,
                intervalMs = R.clashIntervalMs,
                partnerId = R.clashPartnerId,
                resetToken = R.targetResetToken,
        }
end
function AutoClash.getActivationContext()
        return {
                active = R.active == true,
                source = R.lastActivationSource,
                timestamp = R.lastActivationAt,
        }
end
function AutoClash.getStatus()
        local schema
        if Utils
                and type(Utils.apiVersion)
                        == "function" then
                local ok, value =
                        pcall(Utils.apiVersion)
                if ok then
                        schema = value
                end
        end
        return {
                schema = schema,
                phase = R.phase,
                bound = R.bound == true,
                active = R.active == true,
                activationSource = R.lastActivationSource,
                activationAt = R.lastActivationAt,
                parryRadius = R.parryRadius,
                lastTarget = R.lastTarget,
                clashPartnerId =
                        R.clashPartnerId,
                lastGate = R.lastGate,
                ownDashEscapePending =
                        R.ownDashEscapePending == true,
                ownDashEscapeConfirmFrames =
                        R.ownDashEscapeConfirmFrames,
                ownDashEscapeLastDistance =
                        R.ownDashEscapeLastDist,
                ownDashEscapeLastAt =
                        R.ownDashEscapeLastAt,
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
                Dash = "dash",
                GameInfo = "gameinfo",
                Utils = "utils",
        },

        onBallSync = true,
        bindCharacter = true,
}

return AutoClash
