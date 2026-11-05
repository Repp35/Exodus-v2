local AutoClash = {}
local utils, gameInfo, autoParry, dash, players, runService, localPlayer
local current
local nextGeneration = 0
local targetResetToken, returnToken = 0, 0

-- Decision thresholds are kept separate from the event-processing machinery.
local LIMIT = {
    snapshotGrace = 0.20,
    recovery = 1.0,
    pullRecovery = 2.0,
    returnSlow = 0.15,
    returnFast = 0.015,
    sampleGap = 0.10,
    minimumSpeed = 6,
    frame = 1 / 60,
}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end
local function id(value)
    if type(value) == "string" then value = tonumber(value) end
    if finite(value) and value > 0 and value % 1 == 0 then return value end
    return nil
end
local function vector(value)
    return typeof(value) == "Vector3" and finite(value.X) and finite(value.Y) and finite(value.Z)
end
local function clock() return utils and utils.now() or 0 end
local function horizontal(value) return math.sqrt(value.X * value.X + value.Z * value.Z) end
local function horizontalDistance(a, b)
    local x, z = a.X - b.X, a.Z - b.Z
    return math.sqrt(x * x + z * z)
end
local function rootPosition(s)
    return s.root and s.root.Parent and vector(s.root.Position) and s.root.Position or nil
end
local function playerRoot(userId)
    if not players or not userId or userId <= 0 then return nil, nil end
    local player = players:GetPlayerByUserId(userId)
    local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    return player, root and root.Parent and root or nil
end
local function makeState()
    return {
        generation = nextGeneration, phase = "detached", reason = "initial", bound = false, active = false,
        root = nil, character = nil, connections = {}, darkConnections = {}, queue = {}, queueHead = 1, draining = false,
        target = -1, sequence = nil, syncAt = 0, syncSource = nil, teleported = false,
        partner = -1, recentPartner = -1, recentDistance = 0, resetToken = targetResetToken,
        returnToken = returnToken, returnFrom = -1, returnAt = nil, returnServerAt = nil, returnWindow = 0,
        returnBonus = 0, returnExpires = 0, returnPending = false,
        lastSwitchAt = 0, lastSwitchServerAt = nil, intervalMs = 0, intervalAverage = nil, intervalSamples = 0,
        ping = 0, pingAt = -math.huge, speed = 0, parryRadius = 0, activationRadius = 0,
        radiusAt = 0, radiusSpeed = -1, snapshot = nil, prediction = nil,
        missingSince = nil, recoveryUntil = 0, pull = nil, pullEvent = nil,
        dashEvent = nil, dashData = nil, dashBonusUntil = 0, dashLockUntil = 0, activationLockUntil = 0,
        exitReason = nil, exitSince = 0, exitFrames = 0, exitLastAt = 0,
        ownDashPending = false, ownDashFrames = 0, ownDashDistance = nil, ownDashAt = 0, ownDashEventAt = 0,
        activation = { source = "none", reason = "none", trigger = "none", at = 0, target = -1, partner = -1, distance = 0, radius = 0, speed = 0 },
        lastGate = "none", errors = {},
    }
end
local state = makeState()
local function report(s, source, message, time)
    message = tostring(message)
    local previous = s.errors[source]
    if previous and previous.message == message and time >= previous.at and time - previous.at < 1 then return end
    s.errors[source] = { message = message, at = time }
    if utils and type(utils.recordError) == "function" then utils.recordError(source, message) else warn("[" .. source .. "] " .. message) end
end
local function setPhase(s, value, reason)
    if s.phase == value and s.reason == reason then return end
    local previous = s.phase
    s.phase, s.reason = value, reason
    if utils and previous ~= value then utils.recordTransition("AutoClash", previous, value, reason) end
end
local function ping(s, time)
    if time < s.pingAt or time - s.pingAt >= LIMIT.frame then
        s.pingAt = time
        local ok, value = pcall(gameInfo.getLocalPing)
        if current ~= s or not s.bound then return s.ping end
        if ok and finite(value) and value >= 0 then
            s.ping = value
        else
            if not ok then report(s, "GameInfo.getLocalPing", value, time) end
            local statusOk, status = pcall(autoParry.getStatus)
            local fallback = statusOk and type(status) == "table" and type(status.ping) == "table" and tonumber(status.ping.oneWay)
            if finite(fallback) and fallback >= 0 then s.ping = fallback else s.ping = 0 end
        end
    end
    return s.ping
end
local function clearReturn(s)
    s.returnFrom, s.returnAt, s.returnServerAt = -1, nil, nil
    s.returnWindow, s.returnBonus, s.returnExpires, s.returnPending = 0, 0, 0, false
    returnToken += 1
    s.returnToken = returnToken
end
local function clearExit(s)
    s.activationLockUntil, s.dashLockUntil = 0, 0
    s.exitReason, s.exitSince, s.exitFrames, s.exitLastAt = nil, 0, 0, 0
    s.ownDashPending, s.ownDashFrames, s.ownDashDistance, s.ownDashAt, s.ownDashEventAt = false, 0, nil, 0, 0
end
local function clearExchange(s)
    s.target, s.partner, s.recentPartner, s.recentDistance = -1, -1, -1, 0
    s.lastSwitchAt, s.lastSwitchServerAt, s.intervalMs, s.intervalAverage, s.intervalSamples = 0, nil, 0, nil, 0
    s.dashEvent, s.dashData, s.dashBonusUntil, s.dashLockUntil = nil, nil, 0, 0
    s.recoveryUntil = 0
    s.activation = { source = "none", reason = "none", trigger = "none", at = 0, target = -1, partner = -1, distance = 0, radius = 0, speed = 0 }
    targetResetToken += 1
    s.resetToken = targetResetToken
    clearReturn(s)
end
local function setActive(s, enabled, reason, detail, time)
    if current ~= s or not s.bound then return end
    enabled = enabled == true
    if s.active == enabled then return end
    if not enabled and s.partner > 0 then
        s.recentPartner = s.partner
        local _, root = playerRoot(s.partner)
        local own = rootPosition(s)
        if root and own and vector(root.Position) then s.recentDistance = (own - root.Position).Magnitude end
    end
    s.active = enabled
    clearExit(s)
    if enabled then
        local prediction = s.prediction
        if s.partner == -1 and s.target ~= localPlayer.UserId and s.target ~= -1 then s.partner = s.target end
        local activationRadius = s.activationRadius
        if time < s.dashBonusUntil then
            local ok, value = pcall(autoParry.getRadius, "geometry", 1.5, s.speed, "game")
            if ok and type(value) == "table" and finite(value.fullRadius) then activationRadius = value.fullRadius end
        end
        s.activation = {
            source = time < s.dashBonusUntil and "anti_dash" or "normal", reason = detail or "unknown", trigger = reason,
            at = time, target = s.target, partner = s.partner,
            distance = prediction and prediction.distance or 0, radius = activationRadius, speed = s.speed,
        }
        if prediction and s.parryRadius > 0 and prediction.distance <= s.parryRadius * 0.7 then s.activationLockUntil = time + 0.05 end
        if time < s.dashBonusUntil then s.dashLockUntil = time + 0.07 + ping(s, time) * 0.3 end
    else
        s.partner = -1
        s.dashLockUntil = 0
    end
    if current ~= s or not s.bound or s.active ~= enabled then return end
    utils.setAutoSpamActive(enabled)
    if current ~= s or not s.bound or s.active ~= enabled then return end
    setPhase(s, enabled and "active" or "idle", reason)
end
local function gate(s)
    local reason
    if utils.isManualSpamActive() then reason = "manual_spam"
    elseif not utils.isActive() then reason = "hub_inactive"
    elseif utils.getConfigValue("AutoClash") ~= true then reason = "hub_disabled" end
    if not reason then return true end
    local wasActive = s.active
    if wasActive then setActive(s, false, reason, nil, clock()) end
    if wasActive or s.lastGate ~= reason or s.target ~= -1 or s.returnPending then clearExchange(s) end
    s.lastGate = reason
    return false
end
local function closePartner(s, userId)
    if not userId or userId <= 0 or userId == localPlayer.UserId then return false end
    local _, root = playerRoot(userId)
    local own = rootPosition(s)
    if not root or not own or not vector(root.Position) or s.parryRadius <= 0 then return false end
    return (own - root.Position).Magnitude <= math.max(s.parryRadius, s.recentDistance + 2)
end
local function geometry(s, snapshot, time)
    local own = rootPosition(s)
    local position, velocity = snapshot and snapshot.position, snapshot and snapshot.velocity
    if not own or not vector(position) or not vector(velocity) then return nil end
    local speed = finite(snapshot.speed) and math.max(0, snapshot.speed) or velocity.Magnitude
    if not finite(speed) then return nil end
    if s.radiusAt <= 0 or time < s.radiusAt or time - s.radiusAt >= LIMIT.frame or math.abs(speed - s.radiusSpeed) >= 2 then
        local ok, full = pcall(autoParry.getRadius, "geometry", 1, speed, "game")
        if current ~= s or not s.bound then return nil end
        if ok and type(full) == "table" and finite(full.fullRadius) and full.fullRadius > 0 then s.parryRadius = full.fullRadius end
        if not s.active then
            local radiusOk, activation = pcall(autoParry.getRadius, "geometry", 0.8, speed, "game")
            if current ~= s or not s.bound then return nil end
            s.activationRadius = radiusOk and type(activation) == "table" and finite(activation.fullRadius) and activation.fullRadius or s.parryRadius
        end
        s.radiusAt, s.radiusSpeed = time, speed
    end
    local baseOk, info = pcall(autoParry.getRadius, "geometry", 0, speed, "game")
    if current ~= s or not s.bound then return nil end
    local valid = baseOk and type(info) == "table" and finite(info.noWindowParryRadius) and info.noWindowParryRadius >= 0
        and finite(info.deflectWindow) and info.deflectWindow > 0
    local offset = own - position
    local distance = offset.Magnitude
    local closing = distance > 0 and velocity:Dot(offset) / distance or velocity.Magnitude
    local hitRadius = valid and info.noWindowParryRadius or nil
    local window = valid and info.deflectWindow or nil
    local impact = valid and closing > 0 and math.max(distance - hitRadius, 0) / closing or math.huge
    local lead = valid and window + ping(s, time) or nil
    local alignment = velocity.Magnitude > 0 and closing / velocity.Magnitude or 0
    s.speed = speed
    local activationGate = s.parryRadius <= 0 and "no_effective_radius"
        or velocity.Magnitude < LIMIT.minimumSpeed and "ball_speed_invalid"
        or (closing <= 0 or alignment < 0.3) and "ball_not_approaching"
        or not valid and "game_window_unavailable"
        or impact > lead and "impact_not_imminent"
        or "activation_ready"
    return { position = position, velocity = velocity, distance = distance, speed = speed, closing = closing,
        impact = impact, radius = hitRadius, parryRadius = s.parryRadius, valid = valid,
        window = window, lead = lead, activationGate = activationGate,
        imminent = valid and s.parryRadius > 0 and velocity.Magnitude >= LIMIT.minimumSpeed and closing > 0 and alignment >= 0.3 and impact <= lead or false }
end
local function returnAllowance(s, partner, time)
    local latency = ping(s, time)
    if current ~= s or not s.bound then return 0, 0 end
    local low, high = gameInfo.getBallSpeedLimits()
    if current ~= s or not s.bound then return 0, 0 end
    local fraction = finite(low) and finite(high) and high > low and math.clamp((s.speed - low) / (high - low), 0, 1) or 0
    local base = LIMIT.returnSlow + (LIMIT.returnFast - LIMIT.returnSlow) * fraction
    local bonus = 0
    if type(autoParry.getPressure) == "function" then
        local ok, pressure = pcall(autoParry.getPressure)
        if ok and type(pressure) == "table" and finite(pressure.currentLevel) and finite(pressure.latestReturnTime)
            and pressure.latestReturnTime > 0 and pressure.latestReturnTime <= 0.5 then
            if pressure.currentLevel >= 0.6 then bonus = 0.5 elseif pressure.currentLevel >= 0.4 then bonus = 0.3 elseif pressure.currentLevel >= 0.2 then bonus = 0.15 end
            local drop = pressure.factorDrop
            if finite(drop) then
                if drop >= 0.5 then bonus = math.max(bonus, 0.5) elseif drop >= 0.25 then bonus = math.max(bonus, 0.3) end
            end
        end
    end
    return math.max(base + latency * 0.3, 2 / 60) * (1 + bonus), bonus
end
local function updateSwitch(s, previous, target, time, serverTime)
    if not s.active or s.partner <= 0 or previous == -1 or target == previous then return end
    local me = localPlayer.UserId
    local previousPartner, currentPartner = previous == s.partner, target == s.partner
    if previousPartner == currentPartner or (previous == me) == (target == me) or not (previousPartner or currentPartner) then return end
    if s.lastSwitchAt > 0 then
        local interval = time - s.lastSwitchAt
        if finite(serverTime) and finite(s.lastSwitchServerAt) then interval = serverTime - s.lastSwitchServerAt end
        if finite(interval) and interval >= 0 then
            s.intervalMs = interval * 1000
            s.intervalAverage = s.intervalAverage and s.intervalAverage * 0.6 + interval * 0.4 or interval
            s.intervalSamples += 1
        end
    end
    s.lastSwitchAt, s.lastSwitchServerAt = time, finite(serverTime) and serverTime or nil
end
local function stopForPull(s, position, reason, time)
    local own = rootPosition(s)
    if not own or not vector(position) or s.parryRadius <= 0 or (own - position).Magnitude <= s.parryRadius then return false end
    local partner = s.partner ~= -1 and s.partner or (s.target ~= localPlayer.UserId and s.target or -1)
    if s.active then
        s.pull = { partner = partner, at = time, lastTarget = s.target, switched = false }
        setActive(s, false, reason, nil, time)
        if current ~= s or not s.bound then return false end
        clearReturn(s)
        utils.stopAllSpam()
    elseif utils.isManualSpamActive() then utils.stopAllSpam() end
    s.pullEvent, s.lastGate = { reason = reason, at = time, position = position }, reason
    return true
end
local confirmInvalidTarget
local function observeTarget(s, target, explicit, serverTime, time)
    local me = localPlayer.UserId
    if not target then
        if explicit then
            if s.active then setActive(s, false, "invalid_target", nil, time) end
            clearExchange(s)
        elseif s.active and confirmInvalidTarget(s, time) then
            setActive(s, false, "invalid_target", nil, time)
        end
        s.lastGate = "invalid_target"
        return
    end
    local previous = s.target
    if target == previous then return end
    updateSwitch(s, previous, target, time, serverTime)
    s.target = target
    if s.pull then
        if (target == me or target == s.pull.partner) and target ~= s.pull.lastTarget then s.pull.switched = true end
        s.pull.lastTarget = target
        return "pull"
    end
    if previous == me and target ~= me then
        if s.active and s.partner > 0 and target ~= s.partner and not closePartner(s, target) then setActive(s, false, "target_redirected", nil, time) end
        local window, bonus = returnAllowance(s, target, time)
        if current ~= s or not s.bound then return end
        if time < s.dashBonusUntil then window *= 10 end
        s.returnFrom, s.returnAt, s.returnServerAt, s.returnWindow, s.returnBonus = target, time, serverTime, window, bonus
        s.returnExpires, s.returnPending = time + window + 2 * ping(s, time) + 1 / 30, false
        returnToken += 1
        s.returnToken = returnToken
        if s.active or s.recentPartner == -1 then s.partner = target end
        s.exitReason, s.exitSince, s.exitFrames, s.exitLastAt = nil, 0, 0, 0
        s.lastGate = "target_lost"
    elseif previous > 0 and previous ~= me and target == me then
        local elapsed = s.returnAt and time - s.returnAt or nil
        if finite(serverTime) and finite(s.returnServerAt) then elapsed = serverTime - s.returnServerAt end
        if s.returnFrom == previous and finite(elapsed) and elapsed >= 0 and elapsed <= s.returnWindow and time <= s.returnExpires then
            s.partner, s.returnPending, s.lastGate = previous, true, "target_return"
        else
            clearReturn(s)
            s.lastGate = "return_too_late"
        end
    elseif previous > 0 and previous ~= me and target ~= me then
        clearReturn(s)
        if s.active then setActive(s, false, "target_redirected", nil, time) end
        s.partner = -1
        s.lastGate = "target_redirected"
    else
        clearReturn(s)
        s.lastGate = target == me and "initial_me" or "initial_not_me"
    end
end
local function sequenceAccepted(s, sequence)
    if sequence == nil then return true end
    if not finite(sequence) or sequence < 0 or sequence >= 65536 or sequence % 1 ~= 0 then return true end
    if s.sequence ~= nil then
        local delta = (sequence - s.sequence) % 65536
        if delta == 0 or delta >= 32768 then return false end
    end
    s.sequence = sequence
    return true
end
local function snapshotCurrent(s, snapshot, time)
    local target, sequence = id(snapshot.targetId), snapshot.syncSequence
    if finite(sequence) and finite(s.sequence) then
        local delta = (sequence - s.sequence) % 65536
        if delta >= 32768 or (delta == 0 and target and s.target > 0 and target ~= s.target) then return false end
    elseif sequence == nil and s.syncSource == "event" and target and s.target > 0 and target ~= s.target and time - s.syncAt < LIMIT.snapshotGrace then
        return false
    end
    return true
end
local function readSnapshot(s, time)
    local method = type(gameInfo.getSnapshotAt) == "function" and gameInfo.getSnapshotAt or function(t) return gameInfo.getSnapshot(nil, t) end
    local ok, value = pcall(method, time)
    if not ok then report(s, "GameInfo.getSnapshot", value, time); return nil end
    local validOk, valid = pcall(gameInfo.isSnapshotValid, value, time)
    if not validOk then report(s, "GameInfo.isSnapshotValid", valid, time); return nil end
    if valid ~= true then return nil end
    return value
end
local function missingSnapshot(s, time, reason)
    if not s.missingSince then s.missingSince = time end
    if s.active and (time < s.missingSince or time - s.missingSince >= LIMIT.snapshotGrace) then
        s.recoveryUntil = time + LIMIT.recovery
        setActive(s, false, reason, nil, time)
    end
    s.lastGate = reason
end
local function radiusAt(s, factor)
    local ok, value = pcall(autoParry.getRadius, "geometry", factor, s.speed, "game")
    if ok and type(value) == "table" and finite(value.fullRadius) and value.fullRadius >= 0 then return value.fullRadius end
    return s.parryRadius
end
local function extendReturnForDash(s, time)
    if not s.returnAt or s.returnPending or time > s.returnExpires then return end
    local window, bonus = returnAllowance(s, s.returnFrom, time)
    window *= 10
    s.returnBonus = bonus
    if window > s.returnWindow then
        s.returnWindow = window
        s.returnExpires = s.returnAt + window + 2 * ping(s, time) + 1 / 30
    end
end
local function trackDash(s, event, time)
    if type(event) ~= "table" or event.userId ~= s.partner then return end
    s.dashEvent, s.dashData = event, nil
    if not event.player or s.partner == -1 or s.parryRadius <= 0 or not vector(event.position) or not vector(event.velocity) then return end
    local own = rootPosition(s)
    if not own then return end
    local distance, speed = horizontalDistance(own, event.position), horizontal(event.velocity)
    if distance <= 0 or speed <= 0 then return end
    local dx, dz = own.X - event.position.X, own.Z - event.position.Z
    local closing = (event.velocity.X * dx + event.velocity.Z * dz) / distance
    if closing / speed < 0.3 then return end
    local acceptRadius, detectRadius = radiusAt(s, 1.15), radiusAt(s, 1.5)
    if current ~= s or not s.bound then return end
    if acceptRadius <= 0 or detectRadius <= 0 then return end
    if distance > detectRadius and distance - closing * (0.25 + ping(s, time)) > acceptRadius then return end
    local target = id(s.target)
    if target ~= localPlayer.UserId and target ~= event.userId then return end
    local detected = finite(event.detectedAt) and event.detectedAt or time
    local expiry = detected + 0.25 + ping(s, time) * 0.3
    s.dashData = {
        player = event.player, userId = event.userId, detectedAt = detected, expiresAt = expiry,
        position = event.position, velocity = event.velocity, previousPosition = event.previousPosition,
        distanceAtDetection = distance, confirmRadius = acceptRadius, targetAtDetection = target,
        dangerous = distance <= acceptRadius,
    }
    if s.dashData.dangerous then
        s.dashBonusUntil = detected + 0.7 + ping(s, time) * 0.3
        extendReturnForDash(s, detected)
    end
end
local function confirmDash(s, time)
    local data = s.dashData
    if not data then return end
    if data.userId ~= s.partner or time < data.detectedAt or time > data.expiresAt then s.dashData = nil; return end
    if data.dangerous then return end
    local own = rootPosition(s)
    local player, root = playerRoot(data.userId)
    if own and root and player == data.player and vector(root.Position) and horizontalDistance(own, root.Position) <= data.confirmRadius then
        data.dangerous, data.confirmedAt = true, time
        s.dashBonusUntil = data.detectedAt + 0.7 + ping(s, time) * 0.3
        extendReturnForDash(s, time)
    end
end
confirmInvalidTarget = function(s, time)
    local reason = "invalid_target"
    if s.exitReason ~= reason or time < s.exitSince or time - s.exitLastAt > LIMIT.sampleGap then
        s.exitReason, s.exitSince, s.exitFrames, s.exitLastAt = reason, time, 1, time
        return false
    end
    s.exitFrames += 1
    s.exitLastAt = time
    if s.exitFrames >= 2 and time - s.exitSince >= 0.05 then
        s.exitReason, s.exitSince, s.exitFrames, s.exitLastAt = nil, 0, 0, 0
        return true
    end
    return false
end
local function evaluate(s, snapshot, time)
    if current ~= s or not s.bound or not gate(s) then return end
    local prediction = geometry(s, snapshot, time)
    if current ~= s or not s.bound then return end
    if not prediction then missingSnapshot(s, time, "geometry_unavailable"); return end
    s.snapshot, s.prediction, s.missingSince = snapshot, prediction, nil
    local target, me = id(snapshot.targetId), localPlayer.UserId
    local targeted = target and target == me or (not target and snapshot.targeted == true)
    local aimed = s.target == me and targeted and prediction.imminent
    if not s.active and s.recentPartner > 0 and (target == s.recentPartner or targeted) and closePartner(s, s.recentPartner)
        and prediction.distance <= prediction.parryRadius then
        s.partner = s.recentPartner
        setActive(s, true, "known_clash_return", "near_partner_target_switch", time)
        return
    end
    if not s.active and s.recoveryUntil > 0 and time <= s.recoveryUntil and aimed then
        s.recoveryUntil = 0; clearReturn(s); setActive(s, true, "recovered", "snapshot_recovered", time); return
    end
    if s.pull then
        local pull = s.pull
        if time - pull.at > LIMIT.pullRecovery then s.pull = nil
        elseif pull.partner > 0 and closePartner(s, pull.partner) and (target == pull.partner or targeted)
            and prediction.distance <= prediction.parryRadius then
            s.pull, s.partner, s.recentPartner = nil, pull.partner, pull.partner
            setActive(s, true, "pull_partner_return", "near_partner_target_switch", time)
            return
        else
            local own = rootPosition(s)
            local _, opponent = playerRoot(pull.partner)
            local inRange = own and opponent and vector(opponent.Position) and s.parryRadius > 0
                and prediction.distance <= s.parryRadius and (own - opponent.Position).Magnitude <= s.parryRadius
            if inRange and pull.switched and aimed then
                s.pull, s.partner = nil, pull.partner
                setActive(s, true, "pull_return", "pull_return", time)
            else s.lastGate = "pull_suspended" end
            return
        end
    end
    if s.active then
        if target and target ~= me and target ~= s.partner and not closePartner(s, target) then
            setActive(s, false, "target_redirected", nil, time); s.lastGate = "target_redirected"; return
        end
        if targeted then s.lastGate = "deact_targeted"; return end
        if prediction.speed <= 0 then s.lastGate = "deact_tti_unavailable"; return end
        if not prediction.valid then s.lastGate = "deact_window_unavailable"; return end
        if math.max(prediction.distance - prediction.radius, 0) / prediction.speed > math.max(prediction.window - 0.20, 0) then
            s.lastGate = "deact_tti_outside_window"
            setActive(s, false, "target_deactivated", nil, time)
        else s.lastGate = "deact_tti_inside_window" end
        return
    end
    if s.returnPending and aimed then
        local reason = time < s.dashBonusUntil and "anti_dash" or "predicted_impact"
        clearReturn(s); setActive(s, true, "activated", reason, time); return
    end
    if not targeted then s.lastGate = "act_not_targeted"
    elseif not s.returnPending then s.lastGate = "act_no_return_pending"
    elseif s.target ~= me then s.lastGate = "target_not_me"
    else s.lastGate = prediction.activationGate end
end
local function acceptSync(s, data, time, original)
    if not gate(s) or type(data) ~= "table" then return end
    if current ~= s or not s.bound then return end
    local sequence = data.Sequence or data.TeleportSequence
    if sequence == nil and (original or data) == gameInfo.getSyncData() then sequence = gameInfo.getSyncSequence() end
    if current ~= s or not s.bound then return end
    if not sequenceAccepted(s, sequence) then return end
    s.syncAt, s.syncSource = time, data.Source == "snapshot" and "snapshot" or "event"
    if data.Teleported == true then
        s.teleported = true
        if s.active then setActive(s, false, "teleported", nil, time) end
        clearExchange(s)
        s.snapshot, s.prediction = nil, nil
        s.lastGate = "teleported"
        return
    end
    s.teleported = false
    local speed = tonumber(data.Speed)
    if finite(speed) and speed > 0 then s.speed = speed end
    local possessor = id(data.PossessorId)
    if possessor and possessor ~= localPlayer.UserId then
        local _, root = playerRoot(possessor)
        if root and vector(root.Position) and stopForPull(s, root.Position, "possession_pull", time) then return end
    end
    if current ~= s or not s.bound then return end
    local target = id(data.TargetPlayerID) or id(data.HighlightTargetPlayerID)
    local explicit = data.TargetPlayerID ~= nil or data.HighlightTargetPlayerID ~= nil
    if not target and not explicit then target = id(gameInfo.getTargetId()) end
    local previous = s.target
    local outcome = observeTarget(s, target, explicit, tonumber(data.ServerTime), time)
    if current ~= s or not s.bound then return end
    if outcome == "pull" then return end
    if not target then return end
    local sameTarget = target ~= nil and target == previous
    local evaluateEvent = not sameTarget and data.Source ~= "snapshot" and (s.returnPending or (target == localPlayer.UserId and data.Source == "packet"))
        or sameTarget and not s.active and target == localPlayer.UserId and data.Source == "packet"
    if evaluateEvent then
        local snapshot = readSnapshot(s, time)
        if current == s and snapshot and not snapshot.teleported then evaluate(s, snapshot, time) end
    end
end
local function updateFrame(s, time)
    if not gate(s) or not s.root or not s.root.Parent or not s.character.Parent then return end
    if not s.returnPending and s.returnExpires > 0 and time >= s.returnExpires then clearReturn(s) end
    local snapshot = readSnapshot(s, time)
    if current ~= s or not s.bound then return end
    if not snapshot then missingSnapshot(s, time, "snapshot_missing"); return end
    s.dashOwner = coroutine.running()
    local dashOk, dashError = pcall(dash.tick, time)
    s.dashOwner = nil
    if not dashOk then error(dashError, 0) end
    if current ~= s or not s.bound then return end
    confirmDash(s, time)
    if snapshot.teleported then
        if not s.teleported then acceptSync(s, { Sequence = snapshot.syncSequence, Teleported = true, Source = "snapshot" }, time) end
        s.lastGate = "teleported"
        return
    end
    s.teleported = false
    if not snapshotCurrent(s, snapshot, time) then missingSnapshot(s, time, "snapshot_stale"); return end
    local target = id(snapshot.targetId)
    if target ~= id(s.target) then
        local sequence = snapshot.syncSequence
        if type(sequence) == "number" or (s.sequence == nil and (s.syncSource ~= "event" or time - s.syncAt >= 0.1)) then
            acceptSync(s, { Sequence = sequence, TargetPlayerID = snapshot.targetId, Speed = snapshot.syncSpeed, Source = "snapshot" }, time)
        end
    end
    if current == s and s.bound then evaluate(s, snapshot, time) end
end
local function dispatch(s, kind, data, time)
    if current ~= s or not s.bound then return true end
    s.queue[#s.queue + 1] = { kind = kind, data = data, at = time }
    if s.draining then return true end
    s.draining = true
    while current == s and s.bound and s.queueHead <= #s.queue do
        local item = s.queue[s.queueHead]
        s.queueHead += 1
        local ok, err = xpcall(function()
            if item.kind == "sync" then acceptSync(s, item.data.copy, item.at, item.data.original)
            elseif item.kind == "frame" then updateFrame(s, item.at)
            elseif item.kind == "dash" then trackDash(s, item.data, item.at)
            elseif item.kind == "pull" then stopForPull(s, item.data.position, item.data.reason, item.at) end
        end, function(value)
            if type(debug) == "table" and type(debug.traceback) == "function" then return debug.traceback(tostring(value), 2) end
            return tostring(value)
        end)
        if not ok then
            if current == s and s.bound then report(s, "AutoClash", err, item.at) end
        end
    end
    s.queue, s.queueHead, s.draining = {}, 1, false
    return true
end
local function disconnect(connection)
    if not connection then return end
    if utils then utils.untrackCharacter(connection) end
    connection:Disconnect()
end
local function detach(reason)
    local old = current
    if old then
        if old.active then setActive(old, false, reason, nil, clock()) end
        old.bound = false
        current = nil
        for i = #old.connections, 1, -1 do disconnect(old.connections[i]); old.connections[i] = nil end
        for player, connection in pairs(old.darkConnections) do disconnect(connection); old.darkConnections[player] = nil end
    end
    nextGeneration += 1
    targetResetToken += 1
    returnToken += 1
    state = makeState()
    state.reason = reason
end
local function track(s, connection)
    s.connections[#s.connections + 1] = connection
    utils.trackCharacter(connection)
end
function AutoClash.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table"
        or type(deps.AutoParry) ~= "table" or type(deps.Dash) ~= "table" then return false, "dependências inválidas" end
    if utils then detach("setup") end
    utils, gameInfo, autoParry, dash = deps.Utils, deps.GameInfo, deps.AutoParry, deps.Dash
    players, runService, localPlayer = utils.getPlayers(), utils.getRunService(), utils.getLocalPlayer()
    if not players or not runService or not localPlayer then return false, "jogador ou serviços indisponíveis" end
    dash.setHandler(function(event)
        local s = current
        if s and s.dashOwner and s.dashOwner == coroutine.running() then trackDash(s, event, clock())
        elseif s then dispatch(s, "dash", event, clock()) end
    end)
    state.lastGate = "none"
    return true
end
function AutoClash.bindCharacter(character)
    if not utils or not gameInfo or not autoParry or not dash then return false, "dependências não inicializadas" end
    detach("rebind")
    local generation = nextGeneration
    if not character or not character.Parent then return false, "personagem indisponível" end
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 1)
    if generation ~= nextGeneration or not root or not root.Parent or not root:IsA("BasePart") or not runService.Heartbeat then return false, "HumanoidRootPart indisponível" end
    local s = makeState()
    s.root, s.character, s.bound, s.phase, s.reason = root, character, true, "waiting", "character_bound"
    current, state = s, s
    track(s, runService.Heartbeat:Connect(function()
        if current == s then dispatch(s, "frame", nil, clock()) end
    end))
    local function watchDark(player)
        if current ~= s or player == localPlayer or s.darkConnections[player] then return end
        local connection = player:GetAttributeChangedSignal("DarkSealed"):Connect(function()
            if current ~= s or player:GetAttribute("DarkSealed") ~= true then return end
            local targetRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if targetRoot and targetRoot.Parent then dispatch(s, "pull", { position = targetRoot.Position, reason = "dark_seal_pull" }, clock()) end
        end)
        s.darkConnections[player] = connection
        utils.trackCharacter(connection)
    end
    track(s, players.PlayerAdded:Connect(watchDark))
    track(s, players.PlayerRemoving:Connect(function(player)
        if current ~= s then return end
        local connection = s.darkConnections[player]
        if connection then disconnect(connection); s.darkConnections[player] = nil end
    end))
    for _, player in ipairs(players:GetPlayers()) do watchDark(player) end
    local manifest = type(gameInfo.getManifestRemote) == "function" and gameInfo.getManifestRemote()
    if current ~= s or not s.bound then return false, "vinculação cancelada" end
    if manifest then
        track(s, manifest.OnClientEvent:Connect(function(caster)
            if current == s and typeof(caster) == "CFrame" then dispatch(s, "pull", { position = caster.Position, reason = "manifest_pull" }, clock()) end
        end))
    end
    track(s, character.AncestryChanged:Connect(function(_, parent)
        if current == s and not parent then detach("character_removed") end
    end))
    utils.recordTransition("AutoClash", "detached", "waiting", "character_bound")
    return true
end
function AutoClash.detachCharacter() detach("detach") end
function AutoClash.teardown()
    detach("teardown")
    if dash then dash.setHandler(nil) end
    utils, gameInfo, autoParry, dash, players, runService, localPlayer = nil, nil, nil, nil, nil, nil, nil
end
function AutoClash.onBallSync(data)
    local s = current
    if not s or type(data) ~= "table" then return end
    local copy = table.clone(data)
    if copy.Sequence == nil and copy.TeleportSequence == nil and data == gameInfo.getSyncData() then
        copy.Sequence = gameInfo.getSyncSequence()
    end
    return dispatch(s, "sync", { copy = copy, original = data }, clock())
end
function AutoClash.isActive() return state.active end
function AutoClash.getPullEvent() return state.pullEvent end
function AutoClash.stopSpam()
    local s = current
    if not s then return end
    setActive(s, false, "stop_spam", nil, clock())
    clearReturn(s)
    s.lastGate = "stop_spam"
    utils.setAutoSpamActive(false)
end
function AutoClash.getTargetSwitch()
    return { timestampMs = state.lastSwitchAt * 1000, intervalMs = state.intervalMs, partnerId = state.partner, resetToken = state.resetToken }
end
function AutoClash.getActivationContext()
    local value = state.activation
    return { active = state.active, source = value.source, reason = value.reason, trigger = value.trigger, timestamp = value.at,
        target = value.target, partner = value.partner, distance = value.distance, parryRadius = value.radius, speed = value.speed }
end
function AutoClash.getDashData()
    local data = state.dashData
    if not data or not data.player or not data.player.Parent or data.userId ~= state.partner then return nil end
    local time, target = clock(), id(state.target)
    if time < data.detectedAt or time > data.expiresAt then return nil end
    if (target ~= localPlayer.UserId and target ~= data.userId) or (data.targetAtDetection ~= localPlayer.UserId and data.targetAtDetection ~= data.userId) then return nil end
    return data
end
function AutoClash.getStatus()
    local s, value, context = state, state.activation, nil
    if gameInfo and type(gameInfo.getClashContext) == "function" then
        local ok, result = pcall(gameInfo.getClashContext)
        if ok then context = result elseif utils then report(s, "GameInfo.getClashContext", result, clock()) end
    end
    return { schema = utils and utils.apiVersion() or nil, phase = s.phase, bound = s.bound, active = s.active, gameClash = context,
        activationSource = value.source, activationReason = value.reason, activationTrigger = value.trigger,
        activationAt = value.at, activationTarget = value.target, activationPartner = value.partner,
        activationDistance = value.distance, activationRadius = value.radius, activationSpeed = value.speed,
        parryRadius = s.parryRadius, lastTarget = s.target, clashPartnerId = s.partner,
        clashIntervalEma = s.intervalAverage, clashIntervalEmaSamples = s.intervalSamples, lastGate = s.lastGate,
        ownDashEscapePending = s.ownDashPending, ownDashEscapeConfirmFrames = s.ownDashFrames,
        ownDashEscapeLastDistance = s.ownDashDistance, ownDashEscapeLastAt = s.ownDashAt,
        returnPending = s.returnPending, returnWindow = s.returnWindow, returnWindowBonus = s.returnBonus,
        returnExpiresAt = s.returnExpires, returnFromTarget = s.returnFrom, returnToken = s.returnToken,
        dashBonusUntil = s.dashBonusUntil, dashDeactLockedUntil = s.dashLockUntil,
        deactivationCandidate = s.exitReason, deactivationConfirmFrames = s.exitFrames, deactivationCandidateAt = s.exitSince }
end
AutoClash.__contract = {
    requires = { AutoParry = "autoparry", Dash = "dash", GameInfo = "gameinfo", Utils = "utils" },
    requiresMethods = {
        AutoParry = { "getRadius", "getStatus" }, Dash = { "setHandler", "tick" },
        GameInfo = { "getSnapshot", "isSnapshotValid", "getBallSpeedLimits", "getSyncData", "getSyncSequence", "getTargetId", "getLocalPing" },
        Utils = { "now", "getConfig", "getConfigValue", "getRunService", "getPlayers", "recordTransition", "recordError", "setAutoSpamActive", "stopAllSpam", "trackCharacter", "untrackCharacter", "isActive", "isManualSpamActive", "getLocalPlayer", "apiVersion" },
    },
    provides = { "setup", "bindCharacter", "detachCharacter", "onBallSync", "getStatus", "getTargetSwitch", "getDashData", "getPullEvent", "stopSpam" },
    onBallSync = true, bindCharacter = true, minAutoParryVersion = 10, requiresVersions = { AutoParry = 10 },
}
return AutoClash
