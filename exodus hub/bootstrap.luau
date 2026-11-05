return function(factories)
    local previousStop = _G.ExodusStop
    if type(previousStop) == "function" then pcall(previousStop) end
    if type(_G.ExodusUICleanup) == "function" then pcall(_G.ExodusUICleanup) end
    _G.ExodusOnBurst = nil

    local services = {
        Players = game:GetService("Players"), ReplicatedStorage = game:GetService("ReplicatedStorage"),
        RunService = game:GetService("RunService"), Workspace = game:GetService("Workspace"),
        HttpService = game:GetService("HttpService"), UserInputService = game:GetService("UserInputService"),
        CoreGui = game:GetService("CoreGui"),
    }
    local player = services.Players.LocalPlayer
    assert(player, "Players.LocalPlayer indisponível")
    local ctx = {
        active = true, player = player, services = services,
        state = { manualSpam = false, autoSpam = false, antiAfk = false, uiDirty = true },
    }
    local namespace
    local function stop()
        if not ctx.active then return end
        ctx.active = false
        if ctx.spin then ctx.spin:stop() end
        if ctx.config then ctx.config:flush() end
        if ctx.utils then ctx.utils:disconnect() end
        if ctx.ui then ctx.ui:destroy() end
        if namespace then namespace.Started = false end
        if _G.ExodusStop == stop then _G.ExodusStop = nil end
    end
    local function trace(err)
        if type(debug) == "table" and type(debug.traceback) == "function" then return debug.traceback(tostring(err), 2) end
        return tostring(err)
    end
    local ok, err = xpcall(function()
        ctx.utils = factories.utils(ctx)
        ctx.config = factories.config(ctx, factories.uiconfig)
        ctx.config:load()
        ctx.info = factories.gameinfo(ctx)
        ctx.remote = factories.remote(ctx)
        ctx.character = factories.character(ctx)
        ctx.dash = factories.dash(ctx)
        ctx.parry = factories.autoparry(ctx)
        ctx.clash = factories.autoclash(ctx)
        ctx.spam = factories.spam(ctx)
        ctx.dark = factories.autodark(ctx)
        ctx.movement = factories.movement(ctx)
        ctx.spin = factories.spin(ctx)
        ctx.ui = factories.ui(ctx, factories.uiconfig)

        local function observe(packet, now)
            if not packet then return end
            local target = packet.TargetPlayerID or packet.HighlightTargetPlayerID
            if not target and packet.Targeted then target = player.UserId end
            if not target then
                local attribute = services.Workspace:GetAttribute("GameBallTarget")
                if ctx.utils.finite(attribute) and attribute > 0 then target = attribute end
            end
            ctx.parry:observe(target, packet.Teleported)
            ctx.clash:observe(target, packet.Teleported, now, packet.ServerTime, packet.Speed)
        end
        local function antiAfkPulse()
            local success, message = pcall(function()
                local virtualUser = game:GetService("VirtualUser")
                virtualUser:CaptureController()
                virtualUser:ClickButton2(Vector2.new(0, 0))
            end)
            if not success then ctx.utils:report("Anti AFK", message) end
        end
        local function tick(dt)
            local now = os.clock()
            local character, changed = ctx.character:sample()
            ctx.frameCharacter = character
            if changed then
                ctx.info:resetLife()
                ctx.parry:reset()
                ctx.clash:reset()
                ctx.spam:reset()
                ctx.dark:reset()
                ctx.state.manualSpam = false
                ctx.state.uiDirty = true
            end
            if ctx.info:checkBall() then
                ctx.parry:reset()
                ctx.clash:reset()
            end
            ctx.remote:scan(now)
            local pulls = {}
            for _, event in ipairs(ctx.utils:drain()) do
                if not ctx.active then return end
                local kind = event.kind
                if kind == "stop" then stop(); return
                elseif kind == "set" then ctx.config:set(event.key, event.value)
                elseif kind == "toggle" then
                    local value = ctx.config:get(event.key)
                    if type(value) == "boolean" then ctx.config:set(event.key, not value) end
                elseif kind == "mode" then
                    ctx.config:set("SpamRateMode", ctx.config:get("SpamRateMode") == "CPS" and "CPF" or "CPS")
                elseif kind == "manualSpam" then
                    ctx.state.manualSpam = not ctx.state.manualSpam
                    ctx.state.uiDirty = true
                elseif kind == "panic" then
                    ctx.state.manualSpam = false
                    ctx.clash:reset()
                    ctx.parry:reset()
                    ctx.spam:reset()
                    ctx.state.uiDirty = true
                elseif kind == "upDash" then
                    ctx.movement:upDash(now, character)
                elseif kind == "antiAfk" then
                    ctx.state.antiAfk = not ctx.state.antiAfk
                    ctx.state.uiDirty = true
                elseif kind == "idled" and ctx.state.antiAfk then antiAfkPulse()
                elseif kind == "spin" then ctx.spin:set(event.crate)
                elseif kind == "spinResult" then ctx.spin:result(event, now)
                elseif kind == "cooldown" then
                    ctx.info:cooldownEvent(event.args[1], event.args[2], event.args[3], event.at or now)
                elseif kind == "parried" then ctx.info:parried(event.at or now)
                elseif kind == "manifest" then
                    local caster = event.args[1]
                    if typeof(caster) == "CFrame" then pulls[#pulls + 1] = caster.Position end
                elseif kind == "ballSync" then
                    for index = 1, event.args.n do
                        local value = event.args[index]
                        if typeof(value) == "buffer" or type(value) == "table" or type(value) == "string" then
                            local at = event.at or now
                            observe(ctx.info:accept(value, now), at)
                            break
                        end
                    end
                end
            end
            if not ctx.active then return end
            observe(ctx.info:readProvider(now), now)
            if not ctx.active then return end
            local snapshot = ctx.info:sample(now, character)
            if not ctx.active then return end
            if snapshot then
                ctx.parry:observe(snapshot.target, snapshot.teleported)
                ctx.clash:observe(snapshot.target, snapshot.teleported, now, nil, snapshot.speed)
            end
            for _, position in ipairs(pulls) do ctx.clash:pull(position, snapshot, now) end
            ctx.clash:step(snapshot, now, character.alive)
            if not ctx.active then return end
            ctx.movement:step(character)
            ctx.dark:step(now, character)
            if not ctx.active then return end
            ctx.spam:step(dt, now, character.alive)
            if not ctx.active then return end
            ctx.parry:step(snapshot, now)
            if not ctx.active then return end
            ctx.spin:step(now)
            ctx.config:flush()
            if not ctx.active then return end
            local status = not character.alive and "Aguardando personagem"
                or not snapshot and "Aguardando GameBall"
                or snapshot.teleported and "Aguardando sincronização"
                or not ctx.info:ability(1, "Deflect", now) and "Aguardando Deflect"
                or ctx.state.autoSpam and "Clash ativo" or "Pronto"
            if not ctx.active then return end
            if ctx.state.status ~= status then ctx.state.status = status; ctx.state.uiDirty = true end
            if ctx.state.uiDirty then
                ctx.state.uiDirty = false
                ctx.ui:refresh()
            end
        end
        ctx.utils:connect(player.Idled, function() ctx.utils:enqueue({ kind = "idled" }) end)
        local busy = false
        ctx.utils:connect(services.RunService.Heartbeat, function(dt)
            if busy or not ctx.active then return end
            busy = true
            local success, message = xpcall(tick, trace, dt)
            busy = false
            if not success then ctx.utils:report("Runtime", message); stop() end
        end)
        namespace = {
            Version = "3.0.0", Started = true, Stop = stop,
            Set = function(key, value) ctx.utils:enqueue({ kind = "set", key = key, value = value }) end,
            Panic = function() ctx.utils:enqueue({ kind = "panic" }) end,
        }
        _G.Exodus, _G.ExodusStop = namespace, stop
        ctx.ui:refresh()
        print("[Exodus v3] iniciado")
    end, trace)
    if not ok then stop(); error(err, 0) end
    return namespace
end
