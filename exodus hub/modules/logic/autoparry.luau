return function(ctx)
    local lastTarget, fired, awaySeen, retryAt = nil, false, false, 0
    local parry = {}
    function parry:reset()
        lastTarget, fired, awaySeen, retryAt = nil, false, false, 0
    end
    function parry:observe(target, teleported)
        if teleported then self:reset(); return end
        if not target then return end
        local me = ctx.player.UserId
        if target ~= me then
            awaySeen = true
        elseif awaySeen then
            fired, awaySeen = false, false
        end
        lastTarget = target
    end
    function parry:radius(snapshot, factor, gameWindow)
        local fraction = math.clamp((snapshot.speed - snapshot.minimumSpeed) / (snapshot.maximumSpeed - snapshot.minimumSpeed), 0, 1)
        local window = gameWindow or (0.5 - 0.27 * fraction)
        return snapshot.range + snapshot.speed * (window + snapshot.ping) * factor
    end
    function parry:step(snapshot, now)
        if not ctx.config:get("AutoParry") or ctx.state.manualSpam or ctx.state.autoSpam then return end
        if not snapshot or snapshot.teleported or not snapshot.targeted or lastTarget ~= ctx.player.UserId or fired or now < retryAt then return end
        local offset = snapshot.root - snapshot.position
        local distance = offset.Magnitude
        if snapshot.speed < 1 or (distance > 0 and snapshot.velocity:Dot(offset) <= 0) then return end
        local radius = self:radius(snapshot, ctx.config:get("AutoParryWindowFactor"))
        if distance > radius or ctx.info:cooldown(now) then return end
        retryAt = now + 0.1
        if ctx.remote:fireParry(now) then fired = true end
    end
    return parry
end
