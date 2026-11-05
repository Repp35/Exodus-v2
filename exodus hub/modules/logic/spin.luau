return function(ctx)
    local mode, generation, pending, nextAt, cachedNetwork = nil, 0, false, 0, nil
    local spin = {}
    function spin:set(crate)
        generation += 1
        if mode == crate then mode = nil else mode = crate end
        pending, nextAt = false, 0
        ctx.state.spin = mode
        ctx.state.uiDirty = true
    end
    function spin:stop()
        generation += 1
        mode, pending, nextAt = nil, false, 0
        ctx.state.spin = nil
        ctx.state.uiDirty = true
    end
    function spin:step(now)
        if not ctx.active or not mode or pending or now < nextAt then return end
        pending = true
        local requestGeneration, crate, existingNetwork = generation, mode, cachedNetwork
        task.spawn(function()
            local ok, network, owned = pcall(function()
                local client = existingNetwork
                if not client then
                    local storage = ctx.services.ReplicatedStorage
                    local ts = storage:FindFirstChild("TS")
                    local folder = ts and ts:FindFirstChild("Network")
                    local module = folder and folder:FindFirstChild("Network")
                    if not module or not module:IsA("ModuleScript") then error("Network indisponível") end
                    local provider = require(module)
                    client = provider.Network.new()
                end
                return client, client:CSendFunction(4.702176977990345e76, crate)
            end)
            ctx.utils:enqueue({ kind = "spinResult", generation = requestGeneration, crate = crate, ok = ok, network = network, owned = owned })
        end)
    end
    function spin:result(event, now)
        if event.generation ~= generation or event.crate ~= mode or not pending then return end
        pending = false
        if not event.ok then ctx.utils:report("Auto Spin", event.network); self:stop(); return end
        cachedNetwork = event.network
        local code = event.owned == true and 1.796923298985336e75 or 1.0038569313364564e77
        local ok, err = pcall(event.network.CSendEvent, event.network, code, mode)
        if not ok then ctx.utils:report("Auto Spin", err); self:stop(); return end
        nextAt = now + 0.3
    end
    return spin
end
