return function(ctx)
    local credit, previousMode, previousRate, active = 0, nil, nil, false
    local spam = {}
    function spam:reset()
        credit, previousMode, previousRate, active = 0, nil, nil, false
    end
    function spam:step(dt, now, alive)
        local enabled = alive and (ctx.state.manualSpam or ctx.state.autoSpam)
        if not enabled then
            if active then self:reset() end
            return
        end
        local mode = ctx.config:get("SpamRateMode")
        local rate = ctx.config:get(mode)
        if not active or mode ~= previousMode or rate ~= previousRate then credit = 0 end
        active, previousMode, previousRate = true, mode, rate
        -- CPF is converted using the same 60 FPS baseline as v2. Bound the
        -- allowed burst and discard backlog after a slow frame.
        local perSecond = mode == "CPF" and rate * 60 or rate
        local burst = math.max(1, math.ceil(perSecond / 60))
        credit = math.min(burst, credit + perSecond * math.clamp(dt, 0, 0.25))
        local count = math.floor(credit)
        credit -= count
        for _ = 1, count do
            if not ctx.remote:fireParry(now) then credit = 0; break end
        end
    end
    return spam
end
