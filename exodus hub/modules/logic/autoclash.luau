return function(ctx)
    local me = ctx.player.UserId
    local lastTarget, partner, awayAt, awayServer, pending = nil, nil, nil, nil, false
    local active, dashUntil, lastPing, lastSpeed, minSpeed, maxSpeed = false, 0, 0, 0, 16, 600
    local darkState, nextDarkScan = {}, 0
    local clash = {}
    local function setActive(value)
        if active == value then return end
        active = value
        ctx.state.autoSpam = value
        ctx.state.uiDirty = true
    end
    function clash:reset()
        setActive(false)
        lastTarget, partner, awayAt, awayServer, pending, dashUntil = nil, nil, nil, nil, false, 0
        ctx.dash:reset()
    end
    function clash:observe(target, teleported, now, serverTime, speed)
        if not ctx.config:get("AutoClash") or ctx.state.manualSpam then return end
        if teleported then self:reset(); return end
        if not target then self:reset(); return end
        if ctx.utils.finite(speed) and speed > 0 then lastSpeed = speed end
        if target == lastTarget then return end
        if lastTarget == me and target ~= me then
            partner, awayAt, awayServer, pending = target, now, serverTime, false
        elseif lastTarget and lastTarget ~= me and target == me then
            local elapsed = awayAt and now - awayAt
            if ctx.utils.finite(serverTime) and ctx.utils.finite(awayServer) then elapsed = serverTime - awayServer end
            local fraction = math.clamp((lastSpeed - minSpeed) / (maxSpeed - minSpeed), 0, 1)
            local window = math.max(0.15 - 0.135 * fraction + lastPing * 0.3, 2 / 60)
            if now < dashUntil then window *= 10 end
            pending = partner == lastTarget and elapsed ~= nil and elapsed >= 0 and elapsed <= window
            if not pending and not active then partner = nil end
        elseif lastTarget and lastTarget ~= me and target ~= me then
            self:reset()
        end
        if active and target ~= me and partner and target ~= partner then setActive(false) end
        lastTarget = target
    end
    function clash:pull(position, snapshot, now)
        if not snapshot or typeof(position) ~= "Vector3" then return false end
        local window = ctx.info:gameWindow(snapshot, now)
        local radius = ctx.parry:radius(snapshot, 1, window)
        if (position - snapshot.root).Magnitude <= radius then return false end
        if active or ctx.state.manualSpam then
            self:reset()
            ctx.state.manualSpam = false
            ctx.state.uiDirty = true
        end
        return true
    end
    local function scanDark(snapshot, now)
        if now < nextDarkScan then return end
        nextDarkScan = now + 0.1
        local present = {}
        for _, player in ipairs(ctx.services.Players:GetPlayers()) do
            if player ~= ctx.player then
                local id = player.UserId
                present[id] = true
                local sealed = player:GetAttribute("DarkSealed") == true
                if sealed and darkState[id] == false then
                    local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                    if root and root:IsA("BasePart") then clash:pull(root.Position, snapshot, now) end
                end
                darkState[id] = sealed
            end
        end
        for id in pairs(darkState) do if not present[id] then darkState[id] = nil end end
    end
    function clash:step(snapshot, now, alive)
        if not alive or not ctx.config:get("AutoClash") or ctx.state.manualSpam then
            self:reset()
            scanDark(snapshot, now)
            return
        end
        if not snapshot or snapshot.teleported or not snapshot.target then self:reset(); return end
        lastPing, lastSpeed = snapshot.ping, snapshot.speed
        minSpeed, maxSpeed = snapshot.minimumSpeed, snapshot.maximumSpeed
        scanDark(snapshot, now)
        if snapshot.possessor and snapshot.possessor ~= me then
            local player = ctx.services.Players:GetPlayerByUserId(snapshot.possessor)
            local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if root and root:IsA("BasePart") and self:pull(root.Position, snapshot, now) then
                self:reset()
                return
            end
        end
        local window = ctx.info:gameWindow(snapshot, now)
        local detected = ctx.dash:sample(partner, snapshot, now)
        if detected then
            local radius = ctx.parry:radius(snapshot, 1.5, window)
            if detected.distance <= radius or detected.distance - detected.closing * (0.25 + snapshot.ping) <= radius then
                dashUntil = now + 0.7 + snapshot.ping * 0.3
            end
        end
        local offset = snapshot.root - snapshot.position
        local distance, speed = offset.Magnitude, snapshot.speed
        if active then
            if snapshot.target ~= me and snapshot.target ~= partner then setActive(false); pending = false; return end
            if not snapshot.targeted and speed > 0 and math.max(distance - snapshot.range, 0) / speed > math.max(window - 0.05, 0) then
                setActive(false)
            end
            return
        end
        if not pending or not snapshot.targeted or speed < 6 then return end
        local closing = distance > 0 and snapshot.velocity:Dot(offset) / distance or speed
        if closing <= 0 or (distance > 0 and closing / speed < 0.3) then return end
        local impact = math.max(distance - snapshot.range, 0) / closing
        if impact <= window + snapshot.ping then
            pending = false
            setActive(true)
        end
    end
    return clash
end
