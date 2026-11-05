local AutoClash = {}
local utils, gameInfo, autoParry, dash, players, runService, localPlayer
local epoch = 0
local R = {
    phase = "detached", bound = false, active = false, root = nil, connections = {}, dark = {},
    target = -1, partner = -1, wasMe = nil, lastSpeed = 0, parryRadius = 0, activationRadius = 0,
    recentPartner = -1, recentDistance = 0, returnToken = 0, targetResetToken = 0,
    returnPending = false, returnWindow = 0, returnWindowBonus = 0, returnExpiresAt = 0, returnFrom = -1,
    lastSequence = nil, lastSyncAt = 0, lastTargetSource = nil, teleported = false,
    lastGate = "none", lastDirectionSwitch = 0, lastClashSwitch = 0, lastClashServer = nil,
    clashIntervalMs = 0, clashIntervalEma = nil, clashIntervalSamples = 0,
    dashBonusUntil = 0, dashDeactLockedUntil = 0, dashData = nil, dashEvent = nil,
    activationLockUntil = 0, recoveryUntil = 0, missingAt = nil, pullSuspension = nil, pullEvent = nil,
    activationAt = 0, activationSource = "none", activationReason = "none", activationTrigger = "none",
    activationTarget = -1, activationPartner = -1, activationDistance = 0, activationRadiusAt = 0, activationSpeed = 0,
    deactivationCandidate = nil, deactivationCandidateAt = 0, deactivationFrames = 0, deactivationLastAt = 0,
    ownDashEscapePending = false, ownDashEscapeFrames = 0, ownDashEscapeDistance = nil, ownDashEscapeAt = 0,
    ownDashDetectedAt = 0, ownDashFartherStreak = 0, ttiEma = nil, ttiEmaAt = 0,
}
local Deactivation, OwnDash = {}, {}
local function now() return utils and utils.now() or 0 end
local function finite(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
local function normalize(value)
    if type(value) == "string" then value = tonumber(value) end
    return finite(value) and value > 0 and value % 1 == 0 and value or nil
end
local function rootPosition() return R.root and R.root.Parent and R.root.Position or nil end
local function targetIsMe(snapshot)
    if not snapshot then return false end
    local target = normalize(snapshot.targetId)
    if target then return target == localPlayer.UserId end
    return snapshot.targeted == true
end
local function horizontal(vector) return math.sqrt(vector.X * vector.X + vector.Z * vector.Z) end
local function horizontalDistance(a, b)
    local x, z = a.X - b.X, a.Z - b.Z
    return math.sqrt(x * x + z * z)
end
local function setPhase(value, reason)
    if R.phase == value then return end
    local previous = R.phase
    R.phase = value
    if utils then utils.recordTransition("AutoClash", previous, value, reason) end
end
local function readPing()
    if gameInfo and type(gameInfo.getLocalPing) == "function" then
        local ok, value = pcall(gameInfo.getLocalPing)
        if ok and finite(value) and value >= 0 then return value end
    end
    if autoParry and type(autoParry.getStatus) == "function" then
        local ok, status = pcall(autoParry.getStatus)
        local value = ok and type(status) == "table" and type(status.ping) == "table" and tonumber(status.ping.oneWay)
        if finite(value) and value >= 0 then return value end
    end
    return 0
end
local lastPing, lastPingAt = 0, -math.huge
local function ping()
    local time = now()
    if time < lastPingAt or time - lastPingAt >= 1 / 60 then
        lastPing, lastPingAt = readPing(), time
    end
    return lastPing
end
local function radius(factor)
    local ok, value = pcall(autoParry.getRadius, "geometry", factor, R.lastSpeed, "game")
    if ok and type(value) == "table" and finite(value.fullRadius) and value.fullRadius >= 0 then return value.fullRadius end
    return R.parryRadius
end
local function clearReturn()
    R.lostAt, R.returnServerAt, R.returnPending = nil, nil, false
    R.returnWindow, R.returnWindowBonus, R.returnExpiresAt, R.returnFrom = 0, 0, 0, -1
    R.returnToken += 1
end
local function resetTarget()
    R.targetResetToken += 1
    R.target, R.partner, R.wasMe, R.recentPartner, R.recentDistance = -1, -1, nil, -1, 0
    R.dashBonusUntil, R.recoveryUntil, R.dashData, R.dashEvent = 0, 0, nil, nil
    R.lastDirectionSwitch, R.lastClashSwitch, R.lastClashServer = 0, 0, nil
    R.clashIntervalMs, R.clashIntervalEma, R.clashIntervalSamples = 0, nil, 0
    R.activationAt, R.activationSource, R.activationReason, R.activationTrigger = 0, "none", "none", "none"
    R.activationTarget, R.activationPartner, R.activationDistance, R.activationRadiusAt, R.activationSpeed = -1, -1, 0, 0, 0
    R.ttiEma, R.ttiEmaAt = nil, 0
    clearReturn()
end
local function resetDeactivation()
    R.activationLockUntil, R.dashDeactLockedUntil = 0, 0
    R.deactivationCandidate, R.deactivationCandidateAt, R.deactivationFrames, R.deactivationLastAt = nil, 0, 0, 0
    R.ownDashEscapePending, R.ownDashEscapeFrames, R.ownDashEscapeDistance, R.ownDashEscapeAt = false, 0, nil, 0
    R.ownDashDetectedAt, R.ownDashFartherStreak = 0, 0
end
function Deactivation.clearConfirmation()
    R.deactivationCandidate, R.deactivationCandidateAt, R.deactivationFrames, R.deactivationLastAt = nil, 0, 0, 0
end
function Deactivation.confirm(time, reason)
    local gap = time - R.deactivationLastAt
    if R.deactivationCandidate ~= reason or time < R.deactivationCandidateAt or gap > 0.1 then
        R.deactivationCandidate, R.deactivationCandidateAt, R.deactivationFrames, R.deactivationLastAt = reason, time, 1, time
        return false
    end
    R.deactivationFrames += 1
    R.deactivationLastAt = time
    if time - R.deactivationCandidateAt < 0.05 or R.deactivationFrames < 2 then return false end
    Deactivation.clearConfirmation()
    return true
end
local function returnWindow(speed)
    local low, high = gameInfo.getBallSpeedLimits()
    if not finite(low) or not finite(high) or high <= low then low, high = 16, 600 end
    local fraction = math.clamp((speed - low) / (high - low), 0, 1)
    local base = 0.15 + (0.015 - 0.15) * fraction
    local bonus = 0
    if type(autoParry.getPressure) == "function" then
        local ok, pressure = pcall(autoParry.getPressure)
        if ok and type(pressure) == "table" then
            local level, interval, drop = pressure.currentLevel, pressure.latestReturnTime, pressure.factorDrop
            if finite(level) and finite(interval) and interval > 0 and interval <= 0.5 then
                if level >= 0.6 then bonus = 0.5 elseif level >= 0.4 then bonus = 0.3 elseif level >= 0.2 then bonus = 0.15 end
                if finite(drop) then if drop >= 0.5 then bonus = math.max(bonus, 0.5) elseif drop >= 0.25 then bonus = math.max(bonus, 0.3) end end
            end
        end
    end
    R.returnWindowBonus = bonus
    return math.max(base + ping() * 0.3, 2 / 60) * (1 + bonus)
end
local function beginReturn(time, target, serverTime)
    local window = returnWindow(R.lastSpeed)
    if time < R.dashBonusUntil then window *= 10 end
    R.lostAt, R.returnWindow, R.returnFrom, R.returnServerAt, R.returnPending = time, window, target or -1, serverTime, false
    R.returnExpiresAt = time + window + 2 * ping() + 1 / 30
    R.returnToken += 1
end
local function extendReturn(time)
    if not R.lostAt or R.returnPending or time > R.returnExpiresAt then return end
    local window = returnWindow(R.lastSpeed) * 10
    if window > R.returnWindow then R.returnWindow, R.returnExpiresAt = window, R.lostAt + window + 2 * ping() + 1 / 30 end
end
local function playerRoot(id)
    local player = players and players:GetPlayerByUserId(id)
    local character = player and player.Character
    return player, character and character:FindFirstChild("HumanoidRootPart")
end
local function closePartner(id)
    if not id or id <= 0 or id == localPlayer.UserId then return false end
    local _, root = playerRoot(id)
    local own = rootPosition()
    return root ~= nil and root.Parent ~= nil and own ~= nil and R.parryRadius > 0
        and (own - root.Position).Magnitude <= math.max(R.parryRadius, math.max(R.recentDistance, 0) + 2)
end
local function setActive(active, reason, snapshot, activationReason)
    active = active == true
    if R.active == active then return end
    R.active = active
    resetDeactivation()
    local time = now()
    if active then
        R.activationAt = time
        R.activationSource = time < R.dashBonusUntil and "anti_dash" or "normal"
        R.activationReason, R.activationTrigger = activationReason or "unknown", reason or "unknown"
        R.activationTarget, R.activationSpeed = R.target, R.lastSpeed
        R.activationRadiusAt = time < R.dashBonusUntil and radius(1.5) or R.activationRadius
        if R.partner == -1 and R.target ~= localPlayer.UserId and R.target ~= -1 then R.partner = R.target end
        R.activationPartner = R.partner
        local own = rootPosition()
        if own and snapshot and typeof(snapshot.position) == "Vector3" then
            R.activationDistance = (own - snapshot.position).Magnitude
            if R.parryRadius > 0 and R.activationDistance <= R.parryRadius * 0.7 then R.activationLockUntil = time + 0.05 end
        end
        if time < R.dashBonusUntil then R.dashDeactLockedUntil = time + 0.07 + ping() * 0.3 end
    else
        if R.partner > 0 and R.partner ~= localPlayer.UserId then
            R.recentPartner = R.partner
            local _, opponent = playerRoot(R.partner)
            local own = rootPosition()
            if own and opponent then R.recentDistance = (own - opponent.Position).Magnitude end
        end
        R.partner = -1
    end
    if utils then utils.setAutoSpamActive(active) end
    setPhase(active and "active" or "idle", reason)
end
local function stopForPull(position, reason)
    local own = rootPosition()
    if typeof(position) ~= "Vector3" or not own or R.parryRadius <= 0 or (own - position).Magnitude <= R.parryRadius then return false end
    local partner = R.partner ~= -1 and R.partner or (R.target ~= localPlayer.UserId and R.target or -1)
    if R.active then
        R.pullSuspension = { partner = partner, stoppedAt = now(), lastTarget = R.target, switched = false }
        setActive(false, reason)
        clearReturn()
        utils.stopAllSpam()
    elseif utils.isManualSpamActive() then utils.stopAllSpam() end
    R.pullEvent, R.lastGate = { reason = reason, at = now(), position = position }, reason
    return true
end
local function track(connection)
    R.connections[#R.connections + 1] = connection
    utils.trackCharacter(connection)
end
local function resetRuntime(reason)
    epoch += 1
    lastPing, lastPingAt = 0, -math.huge
    if R.active then setActive(false, reason or "reset") end
    for i = #R.connections, 1, -1 do
        local connection = R.connections[i]
        if utils then utils.untrackCharacter(connection) end
        connection:Disconnect()
        R.connections[i] = nil
    end
    for player, connection in pairs(R.dark) do
        if utils then utils.untrackCharacter(connection) end
        connection:Disconnect(); R.dark[player] = nil
    end
    R.bound, R.root, R.lastSpeed, R.parryRadius, R.activationRadius = false, nil, 0, 0, 0
    R.lastSequence, R.lastSyncAt, R.lastTargetSource, R.teleported, R.missingAt = nil, 0, nil, false, nil
    R.pullSuspension, R.pullEvent = nil, nil
    resetTarget(); resetDeactivation()
    R.lastGate = "detached"
    setPhase("detached", reason or "reset")
end
local function gate()
    if not utils then R.lastGate = "no_utils"; return false end
    local reason = utils.isManualSpamActive() and "manual_spam" or not utils.isActive() and "hub_inactive"
        or utils.getConfigValue("AutoClash") ~= true and "hub_disabled" or nil
    if not reason then return true end
    local wasActive = R.active
    if wasActive then setActive(false, reason) end
    if wasActive or R.lastGate ~= reason or R.target ~= -1 or R.returnPending then resetTarget() end
    R.lastGate = reason
    return false
end
local apiErrors = {}
local function reportError(source, message, time)
    message = tostring(message)
    local previous = apiErrors[source]
    if previous and previous.message == message and time >= previous.at and time - previous.at < 1 then return end
    apiErrors[source] = { message = message, at = time }
    utils.recordError(source, message)
end
local function readSnapshot(time)
    local fn = type(gameInfo.getSnapshotAt) == "function" and gameInfo.getSnapshotAt or function(t) return gameInfo.getSnapshot(nil, t) end
    local ok, snapshot = pcall(fn, time)
    if not ok or type(snapshot) ~= "table" then
        if not ok then reportError("GameInfo.getSnapshot", snapshot, time) end
        return nil, "snapshot_error"
    end
    local validOk, valid = pcall(gameInfo.isSnapshotValid, snapshot, time)
    if not validOk or valid ~= true then
        if not validOk then reportError("GameInfo.isSnapshotValid", valid, time) end
        return nil, "snapshot_invalid"
    end
    return snapshot
end
local function updateRadius(snapshot)
    R.lastSpeed = finite(snapshot.speed) and math.max(snapshot.speed, 0) or 0
    local full = radius(1)
    if full > 0 then R.parryRadius = full end
    if not R.active then R.activationRadius = radius(0.8) end
end
local function shouldActivate(snapshot, time)
    if not snapshot or not snapshot.ball or not snapshot.ball.Parent then R.lastGate = "no_ball"; return false end
    if R.target ~= localPlayer.UserId or not targetIsMe(snapshot) then R.lastGate = "target_not_me"; return false end
    local own, position, velocity = rootPosition(), snapshot.position, snapshot.velocity
    if not own or typeof(position) ~= "Vector3" or R.parryRadius <= 0 then R.lastGate = "no_effective_radius"; return false end
    if typeof(velocity) ~= "Vector3" then velocity = snapshot.ball.AssemblyLinearVelocity end
    if typeof(velocity) ~= "Vector3" or velocity.Magnitude < 6 then R.lastGate = "ball_speed_invalid"; return false end
    local offset, distance = own - position, (own - position).Magnitude
    local closing = distance > 0 and velocity:Dot(offset) / distance or velocity.Magnitude
    if closing <= 0 or (distance > 0 and closing / velocity.Magnitude < 0.3) then R.lastGate = "ball_not_approaching"; return false end
    local data = autoParry.getRadius("geometry", 0, snapshot.speed, "game")
    local hitRadius = type(data) == "table" and tonumber(data.noWindowParryRadius)
    local window = type(data) == "table" and tonumber(data.deflectWindow)
    if not finite(hitRadius) or hitRadius < 0 or not finite(window) or window <= 0 then R.lastGate = "game_window_unavailable"; return false end
    if math.max(0, distance - hitRadius) / closing > window + ping() then R.lastGate = "impact_not_imminent"; return false end
    R.lastGate = "activation_ready"
    return true
end
function Deactivation.shouldDeactivate(_time, snapshot)
    if targetIsMe(snapshot) then R.lastGate = "deact_targeted"; return false end
    local own, position = rootPosition(), snapshot.position
    local speed = finite(snapshot.speed) and math.max(snapshot.speed, 0) or R.lastSpeed
    if not own or typeof(position) ~= "Vector3" or speed <= 0 then R.lastGate = "deact_tti_unavailable"; return false end
    local data = autoParry.getRadius("geometry", 0, speed, "game")
    local hitRadius = type(data) == "table" and tonumber(data.noWindowParryRadius)
    local window = type(data) == "table" and tonumber(data.deflectWindow)
    if not finite(hitRadius) or hitRadius < 0 or not finite(window) or window <= 0 then R.lastGate = "deact_window_unavailable"; return false end
    if math.max((position - own).Magnitude - hitRadius, 0) / speed > math.max(window - 0.05, 0) then
        R.lastGate = "deact_tti_outside_window"; return true
    end
    R.lastGate = "deact_tti_inside_window"
    return false
end
function Deactivation.direction(time, snapshot, speed)
    if targetIsMe(snapshot) then R.lastGate = "deact_direction_targeted"; return false end
    local geometry = autoParry.getRadius("geometry", 0, speed, "game")
    local hitRadius = type(geometry) == "table" and tonumber(geometry.noWindowParryRadius)
    local own, position = rootPosition(), snapshot and snapshot.position
    if not finite(hitRadius) or hitRadius < 0 or not own or typeof(position) ~= "Vector3" then
        Deactivation.clearConfirmation(); R.lastGate = "deact_direction_radius_unavailable"; return false
    end
    if (own - position).Magnitude <= hitRadius * 1.1 then
        Deactivation.clearConfirmation(); R.lastGate = "deact_direction_radius_protected"; return false
    end
    if R.lastDirectionSwitch <= 0 or R.lastSyncAt < R.lastDirectionSwitch then return false end
    local low, high = gameInfo.getBallSpeedLimits()
    if not finite(low) or not finite(high) or high <= low then low, high = 16, 600 end
    local base = 0.1 + ping() * 0.3
    local limit = math.max(base + (base * 0.1 - base) * math.clamp((speed - low) / (high - low), 0, 1), 1 / 80)
    if R.clashIntervalEma and R.clashIntervalSamples >= 4.5 then limit = math.max(limit, R.clashIntervalEma * 3) end
    if time - R.lastDirectionSwitch <= limit then return false end
    local velocity = snapshot.velocity
    if typeof(velocity) ~= "Vector3" and snapshot.ball then velocity = snapshot.ball.AssemblyLinearVelocity end
    if typeof(velocity) == "Vector3" then
        local dx, dz = own.X - position.X, own.Z - position.Z
        local distance = math.sqrt(dx * dx + dz * dz)
        local magnitude = velocity.Magnitude
        if distance > 0 and magnitude > 0 then
            local dot = (velocity.X * dx + velocity.Z * dz) / (magnitude * distance)
            if dot >= 0.3 and R.ttiEma and time - R.ttiEmaAt <= 4 / 120 and R.ttiEma <= 0.35 then
                R.lastGate = "deact_direction_still_converging"; return false
            end
        end
    end
    return true
end
local function knownClash(snapshot)
    local partner, target = R.recentPartner, normalize(snapshot.targetId)
    if R.active or partner == -1 or (target ~= partner and target ~= localPlayer.UserId) or not closePartner(partner) then return false end
    local own = rootPosition()
    if not own or typeof(snapshot.position) ~= "Vector3" or R.parryRadius <= 0 or (own - snapshot.position).Magnitude > R.parryRadius then return false end
    R.partner = partner
    setActive(true, "known_clash_return", snapshot, "near_partner_target_switch")
    return true
end
local function evaluate(time, snapshot)
    if not R.root or not R.root.Parent then return end
    if not snapshot or not snapshot.ball or not snapshot.ball.Parent then
        if R.active and time >= R.activationLockUntil then R.lastGate = "ball_lost"; setActive(false, "ball_lost") end
        return
    end
    updateRadius(snapshot)
    local own, velocity = rootPosition(), snapshot.velocity
    if own and typeof(snapshot.position) == "Vector3" and typeof(velocity) == "Vector3" then
        local offset = own - snapshot.position
        local distance = offset.Magnitude
        local closing = distance > 0 and velocity:Dot(offset) / distance or 0
        if closing > 0 then
            local tti = distance / closing
            R.ttiEma = R.ttiEma and 0.4 * tti + 0.6 * R.ttiEma or tti
            R.ttiEmaAt = time
        else R.ttiEma = nil end
    else R.ttiEma = nil end
    if knownClash(snapshot) then return end
    if not R.active and R.recoveryUntil > 0 and time <= R.recoveryUntil and shouldActivate(snapshot, time) then
        R.recoveryUntil = 0; clearReturn(); setActive(true, "recovered", snapshot, "snapshot_recovered"); return
    end
    local suspension = R.pullSuspension
    if suspension then
        local target, own = normalize(snapshot.targetId), rootPosition()
        local position = snapshot.position
        if suspension.partner > 0 and closePartner(suspension.partner) and (target == suspension.partner or targetIsMe(snapshot))
            and own and typeof(position) == "Vector3" and (own - position).Magnitude <= R.parryRadius then
            R.pullSuspension, R.recentPartner, R.partner = nil, suspension.partner, suspension.partner
            setActive(true, "pull_partner_return", snapshot, "near_partner_target_switch")
            return
        end
        if time - suspension.stoppedAt > 2 or not utils.isActive() or utils.getConfigValue("AutoClash") ~= true then
            R.pullSuspension = nil
        else
            local _, opponent = playerRoot(suspension.partner)
            local inRange = own and typeof(position) == "Vector3" and R.parryRadius > 0 and (own - position).Magnitude <= R.parryRadius
                and opponent and opponent.Parent and (own - opponent.Position).Magnitude <= R.parryRadius
            if inRange and suspension.switched and target == localPlayer.UserId and shouldActivate(snapshot, time) then
                R.pullSuspension, R.target, R.partner = nil, target, suspension.partner
                setActive(true, "pull_return", snapshot, "pull_return")
            end
            return
        end
    end
    if R.active then
        local target = normalize(snapshot.targetId)
        if target and target ~= localPlayer.UserId and target ~= R.partner and not closePartner(target) then setActive(false, "distant_target"); return end
        if Deactivation.shouldDeactivate(time, snapshot) then setActive(false, "target_deactivated") end
        return
    end
    if R.returnPending and targetIsMe(snapshot) and shouldActivate(snapshot, time) then
        local reason = time < R.dashBonusUntil and "anti_dash" or "predicted_impact"
        clearReturn(); setActive(true, "activated", snapshot, reason)
    end
end
local function onDashDetected(event)
    if type(event) ~= "table" or event.userId ~= R.partner then return end
    R.dashEvent, R.dashData = event, nil
    if not event.player or R.partner == -1 or R.parryRadius <= 0 or typeof(event.position) ~= "Vector3" or typeof(event.velocity) ~= "Vector3" then return end
    local own = rootPosition()
    if not own then return end
    local distance, speed = horizontalDistance(own, event.position), horizontal(event.velocity)
    if distance <= 0 or speed <= 0 then return end
    local dx, dz = own.X - event.position.X, own.Z - event.position.Z
    local dot = (event.velocity.X * dx + event.velocity.Z * dz) / (speed * distance)
    if dot < 0.3 then return end
    local acceptRadius, detectRadius = radius(1.15), radius(1.5)
    if acceptRadius <= 0 or detectRadius <= 0 then return end
    if distance > detectRadius and distance - speed * dot * (0.25 + ping()) > acceptRadius then return end
    local target = normalize(R.target)
    if target ~= localPlayer.UserId and target ~= event.userId then return end
    local time = finite(event.detectedAt) and event.detectedAt or now()
    local data = { player = event.player, userId = event.userId, detectedAt = time, expiresAt = time + 0.25 + ping() * 0.3,
        position = event.position, velocity = event.velocity, previousPosition = event.previousPosition,
        distanceAtDetection = distance, confirmRadius = acceptRadius, targetAtDetection = target, dangerous = false }
    R.dashData = data
    if distance <= acceptRadius then data.dangerous = true; R.dashBonusUntil = time + 0.7 + ping() * 0.3; extendReturn(time) end
end
local function processDash(time)
    local pending = R.dashData
    if not pending or pending.dangerous then return end
    if pending.userId ~= R.partner or time < pending.detectedAt or time > pending.expiresAt then R.dashData = nil; return end
    local own = rootPosition()
    local player, root = playerRoot(R.partner)
    if own and root and player == pending.player and horizontalDistance(own, root.Position) <= pending.confirmRadius then
        pending.dangerous, pending.confirmedAt = true, time
        R.dashBonusUntil = pending.detectedAt + 0.7 + ping() * 0.3
        extendReturn(time)
    end
end
function OwnDash.getOpponent()
    if R.partner <= 0 or not localPlayer or R.partner == localPlayer.UserId then return nil end
    local player, root = playerRoot(R.partner)
    if not player or not player.Parent or not root or not root.Parent then return nil end
    return player, root
end
function OwnDash.getRecentThreat(time)
    local event = R.dashEvent
    if not event or not event.player or event.userId ~= R.partner or not event.player.Parent then return nil end
    local detected = finite(event.detectedAt) and event.detectedAt or 0
    local age = time - detected
    if age < 0 or age > 0.25 + ping() * 0.3 then return nil end
    return event
end
function OwnDash.shouldDeactivate(time)
    if not R.active then
        R.ownDashEscapePending, R.ownDashEscapeFrames, R.ownDashFartherStreak = false, 0, 0
        return false
    end
    local own, event = rootPosition(), OwnDash.getRecentThreat(time)
    if not own then R.lastGate = "own_dash_escape_no_root"; return false end
    if not event then
        if R.ownDashEscapePending and time - R.ownDashDetectedAt > 0.25 + ping() * 0.3 then
            R.ownDashEscapePending, R.ownDashEscapeFrames, R.ownDashFartherStreak = false, 0, 0
        end
        R.lastGate = "own_dash_escape_no_dash"
        return false
    end
    local _, opponent = OwnDash.getOpponent()
    if not opponent then R.lastGate = "own_dash_escape_no_opponent"; return false end
    local detected = finite(event.detectedAt) and event.detectedAt or 0
    local distance = horizontalDistance(own, opponent.Position)
    if not R.ownDashEscapePending or R.ownDashDetectedAt ~= detected then
        R.ownDashEscapePending, R.ownDashDetectedAt, R.ownDashEscapeFrames, R.ownDashFartherStreak = true, detected, 0, 0
        R.ownDashEscapeDistance, R.ownDashEscapeAt, R.lastGate = distance, time, "own_dash_escape_detected"
        return false
    end
    local previous, sampleTime = R.ownDashEscapeDistance, time - R.ownDashEscapeAt
    if not previous or sampleTime <= 0 or sampleTime > 0.1 then
        R.ownDashEscapeFrames, R.ownDashFartherStreak = 0, 0
        R.ownDashEscapeDistance, R.ownDashEscapeAt, R.lastGate = distance, time, "own_dash_escape_sample_gap"
        return false
    end
    local dx, dz = own.X - opponent.Position.X, own.Z - opponent.Position.Z
    local length = math.max(distance, 0.001)
    local velocity = opponent.AssemblyLinearVelocity
    local separation = velocity.X * -dx / length + velocity.Z * -dz / length
    local measured = (distance - previous) / sampleTime
    local required = math.max(18, horizontal(velocity) * 0.08)
    R.ownDashEscapeDistance, R.ownDashEscapeAt = distance, time
    if distance > previous and math.max(separation, measured) >= required then
        R.ownDashEscapeFrames += 1
        R.ownDashFartherStreak += 1
        R.lastGate = "own_dash_escape_farther_" .. R.ownDashFartherStreak
        return time - detected >= 0.06 and R.ownDashFartherStreak >= 2
    end
    R.ownDashEscapeFrames, R.ownDashFartherStreak, R.lastGate = 0, 0, "own_dash_escape_not_farther"
    return false
end
function AutoClash.onBallSync(data)
    if type(data) ~= "table" or not utils or not localPlayer or not R.bound or not gate() then return end
    local sequence = data.Sequence or data.TeleportSequence
    if sequence == nil and data == gameInfo.getSyncData() then sequence = gameInfo.getSyncSequence() end
    if finite(sequence) and sequence >= 0 and sequence < 65536 and sequence % 1 == 0 then
        if R.lastSequence ~= nil then local delta = (sequence - R.lastSequence) % 65536; if delta == 0 or delta >= 32768 then return true end end
        R.lastSequence = sequence
    end
    local time = now()
    R.lastSyncAt, R.lastTargetSource = time, data.Source == "snapshot" and "snapshot" or "event"
    if data.Teleported == true then
        R.teleported = true
        if R.active then setActive(false, "teleported") end
        resetTarget(); R.lastGate = "teleported"; return true
    end
    R.teleported = false
    local possessor = normalize(data.PossessorId)
    if possessor and possessor ~= localPlayer.UserId then
        local _, root = playerRoot(possessor)
        if root and root.Parent and stopForPull(root.Position, "possession_pull") then return true end
    end
    local target = normalize(data.TargetPlayerID) or normalize(data.HighlightTargetPlayerID)
    local explicit = data.TargetPlayerID ~= nil or data.HighlightTargetPlayerID ~= nil
    if not target and not explicit then target = normalize(gameInfo.getTargetId()) end
    if not target then
        if explicit then
            if R.active then setActive(false, "invalid_target") end
            resetTarget()
        elseif R.active and Deactivation.confirm(time, "invalid_target") then setActive(false, "invalid_target") end
        R.lastGate = "invalid_target"; return true
    end
    local speed = tonumber(data.Speed)
    if finite(speed) and speed > 0 then R.lastSpeed = speed end
    local serverTime = tonumber(data.ServerTime)
    if not finite(serverTime) then serverTime = nil end
    local previous, wasMe, isMe = R.target, R.wasMe, target == localPlayer.UserId
    if target == previous and wasMe ~= nil then
        if isMe and not R.active and data.Source == "packet" then local snapshot = readSnapshot(time); if snapshot and not snapshot.teleported then evaluate(time, snapshot) end end
        return true
    end
    R.target = target
    if wasMe == nil then
        R.wasMe = isMe; clearReturn(); R.lastGate = isMe and "initial_me" or "initial_not_me"
        if isMe and data.Source == "packet" then local snapshot = readSnapshot(time); if snapshot and not snapshot.teleported then evaluate(time, snapshot) end end
        return true
    end
    if R.pullSuspension then
        local suspension = R.pullSuspension
        if (target == localPlayer.UserId or target == suspension.partner) and target ~= suspension.lastTarget then suspension.switched = true end
        suspension.lastTarget, R.wasMe = target, isMe
        return true
    end
    if R.active and R.partner > 0 and R.partner ~= localPlayer.UserId then
        local previousPartner, currentPartner = previous == R.partner, target == R.partner
        if previousPartner ~= currentPartner and wasMe ~= isMe and (previousPartner or currentPartner) then
            if R.lastClashSwitch > 0 and time >= R.lastClashSwitch then
                local interval = time - R.lastClashSwitch
                if serverTime and R.lastClashServer and serverTime >= R.lastClashServer then interval = serverTime - R.lastClashServer end
                R.clashIntervalMs = interval * 1000
                R.clashIntervalEma = R.clashIntervalEma and 0.4 * interval + 0.6 * R.clashIntervalEma or interval
                R.clashIntervalSamples += 1
            end
            R.lastClashSwitch, R.lastClashServer = time, serverTime
        end
    end
    if wasMe ~= isMe then R.lastDirectionSwitch = time end
    if wasMe and not isMe then
        if R.active and R.partner ~= -1 and target ~= R.partner and not closePartner(target) then setActive(false, "target_redirected") end
        beginReturn(time, target, serverTime)
        Deactivation.clearConfirmation()
        if R.active or R.recentPartner == -1 then R.partner = target end
        R.lastGate = "target_lost"
    elseif not wasMe and isMe then
        local elapsed = R.lostAt and time - R.lostAt or nil
        if serverTime and R.returnServerAt then elapsed = serverTime - R.returnServerAt end
        if elapsed == nil or R.returnFrom ~= previous or elapsed < 0 or elapsed > R.returnWindow or time > R.returnExpiresAt then
            clearReturn(); R.lastGate = "return_too_late"
        else R.partner, R.returnPending, R.lastGate = previous, true, "target_return" end
    elseif not wasMe and not isMe and target ~= previous then
        clearReturn()
        if R.active then setActive(false, "target_redirected") end
        R.partner, R.lastGate = -1, "target_redirected"
    end
    R.wasMe = isMe
    if (R.returnPending or (isMe and data.Source == "packet")) and data.Source ~= "snapshot" then
        local snapshot = readSnapshot(time)
        if snapshot and not snapshot.teleported then evaluate(time, snapshot) end
    end
    return true
end
local function waitForSnapshot(time, reason)
    R.missingAt = R.missingAt or time
    if R.active and (time < R.missingAt or time - R.missingAt >= 0.2) then
        R.recoveryUntil = time + 1
        setActive(false, reason)
    end
    R.lastGate = reason
end
local function step(generation, character, root)
    if generation ~= epoch or not character.Parent or not root.Parent or not gate() then return end
    local time = now()
    if not R.returnPending and R.returnExpiresAt > 0 and time >= R.returnExpiresAt then clearReturn(); R.lastGate = "return_expired" end
    local snapshot, reason = readSnapshot(time)
    if not snapshot then
        waitForSnapshot(time, reason)
        return
    end
    dash.tick(time)
    processDash(time)
    if snapshot.teleported then
        if not R.teleported then AutoClash.onBallSync({ Sequence = snapshot.syncSequence, Teleported = true, Source = "snapshot" }) end
        R.lastGate = "teleported"; return
    end
    R.teleported = false
    local target, sequence = normalize(snapshot.targetId), snapshot.syncSequence
    if type(sequence) == "number" and type(R.lastSequence) == "number" then
        local delta = (sequence - R.lastSequence) % 65536
        if delta >= 32768 or (delta == 0 and target and R.target > 0 and target ~= R.target) then waitForSnapshot(time, "snapshot_stale"); return end
    elseif sequence == nil and R.lastTargetSource == "event" and target and R.target > 0 and target ~= R.target and time - R.lastSyncAt < 0.2 then
        waitForSnapshot(time, "snapshot_stale"); return
    end
    R.missingAt = nil
    local changed = target and (R.wasMe == nil or target ~= R.target)
    local cleared = snapshot.targetId ~= nil and not target and (R.target ~= -1 or R.active)
    if changed or cleared then
        if type(sequence) == "number" or (R.lastSequence == nil and (R.lastTargetSource ~= "event" or time - R.lastSyncAt >= 0.1)) then
            AutoClash.onBallSync({ Sequence = sequence, TargetPlayerID = snapshot.targetId, Speed = snapshot.syncSpeed, Source = "snapshot" })
        end
    end
    evaluate(time, snapshot)
end
function AutoClash.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table"
        or type(deps.AutoParry) ~= "table" or type(deps.Dash) ~= "table" then return false, "dependências inválidas" end
    if utils then resetRuntime("setup") end
    utils, gameInfo, autoParry, dash = deps.Utils, deps.GameInfo, deps.AutoParry, deps.Dash
    localPlayer, players, runService = utils.getLocalPlayer(), utils.getPlayers(), utils.getRunService()
    if not localPlayer or not players or not runService then return false, "jogador ou serviços indisponíveis" end
    dash.setHandler(onDashDetected)
    R.lastGate = "none"
    return true
end
function AutoClash.bindCharacter(character)
    resetRuntime("rebind")
    local generation = epoch
    if not character or not character.Parent then return false end
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
    if generation ~= epoch or not root or not root.Parent or not runService.Heartbeat then return false end
    R.root = root
    track(runService.Heartbeat:Connect(function() step(generation, character, root) end))
    local function watchDark(player)
        if generation ~= epoch or not utils or player == localPlayer or R.dark[player] then return end
        local connection = player:GetAttributeChangedSignal("DarkSealed"):Connect(function()
            if generation ~= epoch or not R.bound or player:GetAttribute("DarkSealed") ~= true then return end
            local otherRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if otherRoot and otherRoot.Parent then stopForPull(otherRoot.Position, "dark_seal_pull") end
        end)
        R.dark[player] = connection
        utils.trackCharacter(connection)
    end
    for _, player in ipairs(players:GetPlayers()) do watchDark(player) end
    track(players.PlayerAdded:Connect(watchDark))
    track(players.PlayerRemoving:Connect(function(player)
        if generation ~= epoch or not utils then return end
        local connection = R.dark[player]
        if connection then utils.untrackCharacter(connection); connection:Disconnect(); R.dark[player] = nil end
    end))
    local manifest = type(gameInfo.getManifestRemote) == "function" and gameInfo.getManifestRemote()
    if manifest then
        track(manifest.OnClientEvent:Connect(function(caster)
            if generation == epoch and R.bound and typeof(caster) == "CFrame" then stopForPull(caster.Position, "manifest_pull") end
        end))
    end
    track(character.AncestryChanged:Connect(function(_, parent)
        if not parent and generation == epoch then resetRuntime("character_removed"); R.lastGate = "character_removed" end
    end))
    R.bound = true
    setPhase("waiting", "character_bound")
    return true
end
function AutoClash.detachCharacter() resetRuntime("detach") end
function AutoClash.teardown()
    resetRuntime("teardown")
    if dash then dash.setHandler(nil) end
    utils, gameInfo, autoParry, dash, players, runService, localPlayer = nil, nil, nil, nil, nil, nil, nil
end
function AutoClash.isActive() return R.active end
function AutoClash.getPullEvent() return R.pullEvent end
function AutoClash.stopSpam()
    setActive(false, "stop_spam"); clearReturn(); R.lastGate = "stop_spam"
    if utils then utils.setAutoSpamActive(false) end
end
function AutoClash.getTargetSwitch()
    return { timestampMs = R.lastClashSwitch * 1000, intervalMs = R.clashIntervalMs, partnerId = R.partner, resetToken = R.targetResetToken }
end
function AutoClash.getActivationContext()
    return { active = R.active, source = R.activationSource, reason = R.activationReason, trigger = R.activationTrigger,
        timestamp = R.activationAt, target = R.activationTarget, partner = R.activationPartner,
        distance = R.activationDistance, parryRadius = R.activationRadiusAt, speed = R.activationSpeed }
end
function AutoClash.getDashData()
    local data, time = R.dashData, now()
    if not data or not data.player or not data.player.Parent or data.userId ~= R.partner or time < data.detectedAt or time > data.expiresAt then return nil end
    local target = normalize(R.target)
    if (target ~= localPlayer.UserId and target ~= data.userId) or (data.targetAtDetection ~= localPlayer.UserId and data.targetAtDetection ~= data.userId) then return nil end
    return data
end
function AutoClash.getStatus()
    local context
    if gameInfo and type(gameInfo.getClashContext) == "function" then
        local ok, value = pcall(gameInfo.getClashContext)
        if ok then context = value elseif utils then reportError("GameInfo.getClashContext", value, now()) end
    end
    return { schema = utils and utils.apiVersion() or nil, phase = R.phase, bound = R.bound, active = R.active, gameClash = context,
        activationSource = R.activationSource, activationReason = R.activationReason, activationTrigger = R.activationTrigger,
        activationAt = R.activationAt, activationTarget = R.activationTarget, activationPartner = R.activationPartner,
        activationDistance = R.activationDistance, activationRadius = R.activationRadiusAt, activationSpeed = R.activationSpeed,
        parryRadius = R.parryRadius, lastTarget = R.target, clashPartnerId = R.partner,
        clashIntervalEma = R.clashIntervalEma, clashIntervalEmaSamples = R.clashIntervalSamples, lastGate = R.lastGate,
        ownDashEscapePending = R.ownDashEscapePending, ownDashEscapeConfirmFrames = R.ownDashEscapeFrames,
        ownDashEscapeLastDistance = R.ownDashEscapeDistance, ownDashEscapeLastAt = R.ownDashEscapeAt,
        returnPending = R.returnPending, returnWindow = R.returnWindow, returnWindowBonus = R.returnWindowBonus,
        returnExpiresAt = R.returnExpiresAt, returnFromTarget = R.returnFrom, returnToken = R.returnToken,
        dashBonusUntil = R.dashBonusUntil, dashDeactLockedUntil = R.dashDeactLockedUntil,
        deactivationCandidate = R.deactivationCandidate, deactivationConfirmFrames = R.deactivationFrames, deactivationCandidateAt = R.deactivationCandidateAt }
end
AutoClash.__contract = {
    requires = { AutoParry = "autoparry", Dash = "dash", GameInfo = "gameinfo", Utils = "utils" },
    requiresMethods = {
        AutoParry = { "getRadius", "getStatus" }, Dash = { "setHandler", "tick" },
        GameInfo = { "getSnapshot", "isSnapshotValid", "getBallSpeedLimits", "getSyncData", "getSyncSequence", "getTargetId" },
        Utils = { "now", "getConfig", "getConfigValue", "getRunService", "getPlayers", "recordTransition", "recordError", "setAutoSpamActive", "stopAllSpam", "trackCharacter", "untrackCharacter", "isActive", "isManualSpamActive", "getLocalPlayer", "apiVersion" },
    },
    provides = { "setup", "bindCharacter", "detachCharacter", "onBallSync", "getStatus", "getTargetSwitch", "getDashData", "getPullEvent", "stopSpam" },
    onBallSync = true, bindCharacter = true, minAutoParryVersion = 10, requiresVersions = { AutoParry = 10 },
}
return AutoClash
