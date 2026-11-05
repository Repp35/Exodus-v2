-- Exodus v3: arquivo gerado por tools/bundle.py. Não edite diretamente.
local modules = {}

modules["uiconfig"] = (function()
-- The order is also the order used by the settings panel and persistence.
return {
    { key = "AutoParry", label = "Auto Parry", default = true, kind = "boolean" },
    { key = "AutoClash", label = "Auto Clash", default = true, kind = "boolean" },
    { key = "AutoDark", label = "Auto Dark", default = false, kind = "boolean" },
    { key = "AutoJump", label = "Auto Jump", default = false, kind = "boolean" },
    { key = "ClashBallVisible", label = "Mini Clash", default = false, kind = "boolean" },
    { key = "DarkBallVisible", label = "Mini Dark", default = false, kind = "boolean" },
    { key = "JumpBallVisible", label = "Mini Jump", default = false, kind = "boolean" },
    { key = "UpDashBallVisible", label = "Mini Up Dash", default = false, kind = "boolean" },
    { key = "MiniSpamVisible", label = "Mini Spam", default = false, kind = "boolean" },
    { key = "AutoParryWindowFactor", default = 0.5, kind = "factor" },
    { key = "CPS", default = 24, kind = "cps" },
    { key = "CPF", default = 0.36, kind = "cpf" },
    { key = "SpamRateMode", default = "CPF", kind = "mode" },
    { key = "Keybind", default = Enum.KeyCode.F9, kind = "key" },
    { key = "SpamKeybind", default = Enum.KeyCode.F, kind = "key" },
    { key = "BtnX", kind = "position" }, { key = "BtnY", kind = "position" },
    { key = "ClashBallX", kind = "position" }, { key = "ClashBallY", kind = "position" },
    { key = "DarkBallX", kind = "position" }, { key = "DarkBallY", kind = "position" },
    { key = "JumpBallX", kind = "position" }, { key = "JumpBallY", kind = "position" },
    { key = "UpDashBallX", kind = "position" }, { key = "UpDashBallY", kind = "position" },
    { key = "MiniX", kind = "position" }, { key = "MiniY", kind = "position" },
    { key = "PanelX", kind = "position" }, { key = "PanelY", kind = "position" },
}

end)()

modules["config"] = (function()
return function(ctx, definitions)
    local values, schema = {}, {}
    local http = ctx.services.HttpService
    local folder, path = "Exodus Hub", "Exodus Hub/config.json"
    local dirty, writable = false, false

    local function finite(n)
        return type(n) == "number" and n == n and n > -math.huge and n < math.huge
    end
    local function valid(kind, value)
        if kind == "boolean" then return type(value) == "boolean" end
        if kind == "key" then return typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode and value ~= Enum.KeyCode.Unknown end
        if kind == "mode" then return value == "CPS" or value == "CPF" end
        if not finite(value) then return false end
        if kind == "factor" then return value >= 0 and value <= 1 end
        if kind == "cps" then return value >= 0 and value <= 120 end
        if kind == "cpf" then return value >= 0 and value <= 4 end
        if kind == "position" then return value >= -10000 and value <= 10000 end
        return false
    end
    for _, entry in ipairs(definitions) do
        schema[entry.key] = entry.kind
        values[entry.key] = entry.default
    end

    local config = {}
    function config:get(key) return values[key] end
    function config:set(key, value)
        if not schema[key] or not valid(schema[key], value) then return false end
        if values[key] ~= value then values[key] = value; dirty = true; ctx.state.uiDirty = true end
        return true
    end
    function config:load()
        if type(isfolder) ~= "function" or type(makefolder) ~= "function" or type(isfile) ~= "function"
            or type(readfile) ~= "function" or type(writefile) ~= "function" then return end
        local ok, exists = pcall(isfolder, folder)
        if not ok then return end
        if not exists then
            local created = pcall(makefolder, folder)
            if not created then return end
        end
        writable = true
        local fileOk, fileExists = pcall(isfile, path)
        if not fileOk or not fileExists then return end
        local readOk, body = pcall(readfile, path)
        if not readOk then return end
        local decoded, data = pcall(http.JSONDecode, http, body)
        if not decoded or type(data) ~= "table" then return end
        for _, entry in ipairs(definitions) do
            local value = data[entry.key]
            if entry.kind == "key" then
                if type(value) == "table" then value = value.keyCode end
                if type(value) == "string" then
                    local found, key = pcall(function() return Enum.KeyCode[value] end)
                    value = found and key or nil
                end
            end
            if value ~= nil and valid(entry.kind, value) then values[entry.key] = value end
        end
    end
    function config:flush()
        if not dirty then return end
        dirty = false
        if not writable then return end
        local encoded, body = pcall(function()
            local parts = {}
            for _, entry in ipairs(definitions) do
                local value = values[entry.key]
                if entry.kind == "key" and value then value = { keyCode = value.Name } end
                if value ~= nil then
                    parts[#parts + 1] = http:JSONEncode(entry.key) .. ":" .. http:JSONEncode(value)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end)
        if not encoded then ctx.utils:report("Config", body); return end
        local ok, result = pcall(writefile, path, body)
        if not ok or result == false then ctx.utils:report("Config", result or "falha ao salvar") end
    end
    return config
end

end)()

modules["utils"] = (function()
return function(ctx)
    local connections, events = {}, {}
    local utils = {}

    function utils:connect(signal, callback)
        local connection = signal:Connect(callback)
        connections[#connections + 1] = connection
        return connection
    end
    function utils:enqueue(event)
        if ctx.active then events[#events + 1] = event end
    end
    function utils:drain()
        local current = events
        events = {}
        return current
    end
    function utils:report(source, message)
        local text = tostring(source) .. ": " .. tostring(message)
        if ctx.state.error == text then return end
        ctx.state.error = text
        ctx.state.uiDirty = true
        warn("[Exodus v3] " .. text)
    end
    function utils:disconnect()
        for index = #connections, 1, -1 do
            connections[index]:Disconnect()
            connections[index] = nil
        end
        events = {}
    end
    function utils.finite(value)
        return type(value) == "number" and value == value and value > -math.huge and value < math.huge
    end
    return utils
end

end)()

modules["gameinfo"] = (function()
return function(ctx)
    local storage, world = ctx.services.ReplicatedStorage, ctx.services.Workspace
    local finite = ctx.utils.finite
    local info = {}
    local abilitiesModule, abilities, providerModule, provider, gameBallModule, gameBall
    local nextAbilities, nextProvider, nextGameBall, nextBall = 0, 0, 0, 0
    local ball, lastBall, lastPosition, lastAt, measuredVelocity, lastMoved
    local sync, sequence
    local cooldownUntil, cooldownEventAt = 0, -math.huge
    local minSpeed, maxSpeed = 16, 600
    local ping, nextPing = 0, 0

    local function child(parent, name) return parent and parent:FindFirstChild(name) end
    local function requireTable(module)
        if not module or not module:IsA("ModuleScript") then return nil end
        local ok, value = pcall(require, module)
        if ok and type(value) == "table" then return value end
        if not ok then ctx.utils:report(module.Name, value) end
        return nil
    end
    function info:ability(index, method, now)
        if not ctx.active then return nil end
        now = now or os.clock()
        local module = child(child(storage, "TS"), "ClientAbilities")
        if module ~= abilitiesModule then abilitiesModule, abilities, nextAbilities = module, nil, 0 end
        if not abilities and now >= nextAbilities then
            nextAbilities = now + 1
            local loaded = requireTable(module)
            if loaded and type(loaded.Abilities) == "table" then abilities = loaded.Abilities end
        end
        local ability = abilities and abilities[index]
        if type(ability) == "table" and type(ability[method]) == "function" then return ability end
        return nil
    end
    local function getProvider(now)
        local folder = child(child(storage, "TS"), "BallReplicator")
        local module = folder and (folder:IsA("ModuleScript") and folder or child(folder, "BallReplicator"))
        if module ~= providerModule then providerModule, provider, nextProvider = module, nil, 0 end
        if not provider and now >= nextProvider then
            nextProvider = now + 1
            local loaded = requireTable(module)
            if loaded then provider = type(loaded.BallReplicator) == "table" and loaded.BallReplicator or loaded end
        end
        return provider
    end
    local function getGameBall(now)
        local module = child(child(child(storage, "TS"), "Gameplay"), "GameBall")
        if module ~= gameBallModule then gameBallModule, gameBall, nextGameBall = module, nil, 0 end
        if now >= nextGameBall then
            nextGameBall = now + 1
            if not gameBall then
                local loaded = requireTable(module)
                gameBall = loaded and loaded.GameBall
            end
            if type(gameBall) == "table" and type(gameBall.GetBaseSpeed) == "function" and type(gameBall.GetMaxSpeed) == "function" then
                local ok, minimum, maximum = pcall(function() return gameBall:GetBaseSpeed(), gameBall:GetMaxSpeed() end)
                if ok and finite(minimum) and finite(maximum) and minimum > 0 and maximum > minimum then
                    minSpeed, maxSpeed = minimum, maximum
                end
            end
        end
        return gameBall
    end
    local function targetId(value)
        if typeof(value) == "Instance" and value:IsA("Player") then return value.UserId end
        local number = type(value) == "number" and value or (type(value) == "string" and tonumber(value) or nil)
        if finite(number) and number > 0 and number % 1 == 0 then return number end
        return nil
    end
    local function normalize(data, packetSequence)
        return {
            Sequence = packetSequence or data.Sequence or data.seq,
            ServerTime = data.ServerTime or data.serverTime,
            Teleported = data.Teleported == true or data.teleported == true,
            Grace = data.Grace == true or data.grace == true,
            OldGrace = data.OldGrace == true or data.oldGrace == true,
            TargetPlayerID = targetId(data.TargetPlayerID or data.targetId),
            HighlightTargetPlayerID = targetId(data.HighlightTargetPlayerID or data.highlightId),
            Targeted = data.Targeted == true,
            PossessorId = targetId(data.PossessorId or (data.possessed and data.possessorId)),
            RealPosition = data.RealPosition or data.position,
            Speed = data.Speed or data.speed,
        }
    end
    function info:accept(data, now, packetSequence)
        if typeof(data) == "buffer" then
            local source = getProvider(now)
            if not source or type(source.Decode) ~= "function" then return nil end
            local ok, decoded = pcall(source.Decode, source, data)
            if not ok or type(decoded) ~= "table" then return nil end
            data = decoded
        elseif type(data) == "string" then
            local ok, decoded = pcall(ctx.services.HttpService.JSONDecode, ctx.services.HttpService, data)
            if not ok then return nil end
            data = decoded
        end
        if type(data) ~= "table" then return nil end
        if type(data.syncData) == "table" then data = data.syncData end
        local incoming = normalize(data, packetSequence)
        local nextSequence = incoming.Sequence
        if nextSequence ~= nil then
            if not finite(nextSequence) or nextSequence < 0 or nextSequence >= 65536 or nextSequence % 1 ~= 0 then return nil end
            if sequence ~= nil then
                local delta = (nextSequence - sequence) % 65536
                if delta == 0 or delta >= 32768 then return nil end
            end
            sequence = nextSequence
        end
        sync = incoming
        if incoming.Teleported then lastPosition, lastAt, measuredVelocity, lastMoved = nil, nil, nil, nil end
        return incoming
    end
    function info:readProvider(now)
        local source = getProvider(now)
        if source and source.hasState == true and type(source.syncData) == "table" then
            if source.lastSeq == nil and sync ~= nil then return nil end
            return self:accept(source.syncData, now, source.lastSeq)
        end
        return nil
    end
    function info:cooldownEvent(abilityId, eventId, value, now)
        if abilityId ~= 1 then return end
        if eventId == 5.93848805167512e76 and finite(value) then
            cooldownEventAt = now
            cooldownUntil = value > 0 and now + value or 0
        elseif eventId == 6.60750295352893e76 then
            cooldownEventAt, cooldownUntil = now, 0
        end
    end
    function info:parried(now)
        cooldownEventAt, cooldownUntil = now, 0
    end
    function info:cooldown(now)
        local ability = self:ability(1, "Deflect", now)
        if not ability then return false end
        local duration, receivedAt = ability.HeldServerCooldown, ability.HeldServerCooldownAt
        if finite(duration) and duration > 0 and finite(receivedAt) and receivedAt <= now and receivedAt > cooldownEventAt then
            cooldownEventAt, cooldownUntil = receivedAt, receivedAt + duration
        end
        return now < cooldownUntil or (finite(ability.Cooldown) and ability.Cooldown > 0)
    end
    local function findBall(now)
        if ball and ball:IsDescendantOf(world) then return ball end
        ball = nil
        if now < nextBall then return nil end
        nextBall = now + 0.5
        local best, bestName, ambiguous, bestDirect
        for _, item in ipairs(world:GetDescendants()) do
            if item.Name == "GameBall" and item:IsA("BasePart") then
                local name = item:GetFullName()
                local direct = item.Parent == world
                if not bestName or (direct and not bestDirect) or (direct == bestDirect and name < bestName) then
                    best, bestName, ambiguous, bestDirect = item, name, false, direct
                elseif direct == bestDirect and name == bestName then ambiguous = true end
            end
        end
        if not ambiguous then ball = best end
        return ball
    end
    function info:sample(now, character)
        local currentBall = findBall(now)
        if not currentBall or not character.root then return nil end
        local position, velocity = currentBall.Position, currentBall.AssemblyLinearVelocity
        local function validVector(v)
            return typeof(v) == "Vector3" and finite(v.X) and finite(v.Y) and finite(v.Z)
        end
        if not validVector(position) or not validVector(character.root.Position) then return nil end
        if not validVector(velocity) then velocity = Vector3.zero end
        if currentBall ~= lastBall then
            lastBall, lastPosition, lastAt, measuredVelocity, lastMoved = currentBall, nil, nil, Vector3.zero, nil
        end
        local speedHint = sync and sync.Speed
        if type(speedHint) == "string" then speedHint = tonumber(speedHint) end
        if not finite(speedHint) or speedHint <= 0 then speedHint = maxSpeed end
        local limit = speedHint * 2.5 + 30
        if lastPosition and lastAt and now > lastAt then
            local dt = now - lastAt
            local measured = (position - lastPosition) / dt
            if dt <= 0.25 and measured.Magnitude > 0.1 and measured.Magnitude <= limit then
                measuredVelocity, lastMoved = measured, now
            elseif not lastMoved or now - lastMoved >= 0.1 or measured.Magnitude > limit then
                measuredVelocity = Vector3.zero
            end
        end
        lastPosition, lastAt = position, now
        if velocity.Magnitude > limit then velocity = Vector3.zero end
        if velocity.Magnitude < 0.1 then velocity = measuredVelocity or Vector3.zero end
        local target = sync and (sync.TargetPlayerID or sync.HighlightTargetPlayerID)
        if not target and sync and sync.Targeted then target = ctx.player.UserId end
        if not target then target = targetId(world:GetAttribute("GameBallTarget")) end
        if now >= nextPing then
            nextPing = now + 0.25
            local ok, value = pcall(ctx.player.GetNetworkPing, ctx.player)
            if ok and finite(value) and value >= 0 then ping = math.min(value, 0.5) end
        end
        local range = ctx.player:GetAttribute("DeflectRange")
        if not finite(range) then range = 8.5 end
        getGameBall(now)
        return {
            ball = currentBall, position = position, velocity = velocity, speed = velocity.Magnitude,
            target = target, targeted = target == ctx.player.UserId, teleported = sync and sync.Teleported == true,
            grace = sync and sync.Grace == true, possessor = sync and sync.PossessorId,
            root = character.root.Position, ping = ping, range = math.clamp(range, 8.5, 16),
            minimumSpeed = minSpeed, maximumSpeed = maxSpeed,
        }
    end
    function info:gameWindow(snapshot, now)
        local fraction = math.clamp((snapshot.speed - minSpeed) / (maxSpeed - minSpeed), 0, 1)
        local window = 0.85 - 0.65 * fraction
        local gameplay = getGameBall(now)
        if type(gameplay) == "table" and type(gameplay.GetClashMinWindow) == "function" then
            local ok, minimum = pcall(gameplay.GetClashMinWindow, gameplay, snapshot.speed)
            if ok and finite(minimum) then window = math.max(window, minimum) end
        end
        window += math.clamp((snapshot.range - 8.5) / 7.5, 0, 1) * 0.12
        if type(gameplay) == "table" and type(gameplay.IsInClash) == "function" and type(gameplay.GetClashWindowScale) == "function" then
            local ok, inClash = pcall(gameplay.IsInClash, gameplay, ctx.player)
            if ok and inClash then
                local scaleOk, scale = pcall(gameplay.GetClashWindowScale, gameplay)
                if scaleOk and finite(scale) and scale > 0 then window *= scale end
            end
        end
        return window
    end
    function info:resetLife()
        lastBall, lastPosition, lastAt, measuredVelocity, lastMoved = nil, nil, nil, nil, nil
    end
    function info:resetBall()
        ball, sync, sequence, nextBall = nil, nil, nil, 0
        self:resetLife()
    end
    function info:checkBall()
        if ball and not ball:IsDescendantOf(world) then self:resetBall(); return true end
        return false
    end
    return info
end

end)()

modules["remote"] = (function()
return function(ctx)
    local storage = ctx.services.ReplicatedStorage
    local bound, nextScan = {}, 0
    local remote = {}

    local function child(parent, name) return parent and parent:FindFirstChild(name) end
    local function findBallSync()
        local direct = child(child(storage, "Remotes"), "BallSyncData")
        if direct and direct:IsA("RemoteEvent") then return direct end
        direct = child(storage, "BallSyncData")
        if direct and direct:IsA("RemoteEvent") then return direct end
        local previous = bound.ballSync and bound.ballSync.instance
        if previous and previous:IsDescendantOf(storage) then return previous end
        local best, path, ambiguous
        for _, item in ipairs(storage:GetDescendants()) do
            if item.Name == "BallSyncData" and item:IsA("RemoteEvent") then
                local name = item:GetFullName()
                if not path or name < path then best, path, ambiguous = item, name, false
                elseif name == path then ambiguous = true end
            end
        end
        if not ambiguous then return best end
        return nil
    end
    local function attach(kind, instance)
        if instance and not instance:IsA("RemoteEvent") then instance = nil end
        local existing = bound[kind]
        if existing and existing.instance == instance and existing.connection.Connected then return end
        if existing then existing.connection:Disconnect(); bound[kind] = nil end
        if not instance then return end
        local connection = ctx.utils:connect(instance.OnClientEvent, function(...)
            ctx.utils:enqueue({ kind = kind, at = os.clock(), args = table.pack(...) })
        end)
        bound[kind] = { instance = instance, connection = connection }
    end
    function remote:scan(now)
        if now < nextScan then return end
        nextScan = now + 0.5
        local generated = child(child(storage, "TS"), "GeneratedNetworkRemotes")
        attach("ballSync", findBallSync())
        attach("cooldown", child(generated, "RE_" .. tostring(5.520474058077904e76)))
        attach("parried", child(generated, "RE_" .. tostring(9.611859444202098e76)))
        attach("manifest", child(generated, "RE_" .. tostring(9.318024238496386e76)))
    end
    function remote:fireParry(now)
        local ability = ctx.info:ability(1, "Deflect", now)
        if not ctx.active or not ability or not ctx.character:current(ctx.frameCharacter) then return false end
        local ok, result = pcall(ability.Deflect, ability)
        if not ok then ctx.utils:report("Deflect", result); return false end
        return result ~= false
    end
    return remote
end

end)()

modules["character"] = (function()
return function(ctx)
    local previousCharacter, previousRoot, previousHumanoid, wasAlive
    local character = {}

    function character:sample()
        local model = ctx.player.Character
        local humanoid = model and model:FindFirstChildOfClass("Humanoid")
        local root = model and model:FindFirstChild("HumanoidRootPart")
        if root and not root:IsA("BasePart") then root = nil end
        local alive = model ~= nil and model.Parent ~= nil and root ~= nil and root.Parent ~= nil
            and humanoid ~= nil and humanoid.Health > 0
        local changed = model ~= previousCharacter or root ~= previousRoot or humanoid ~= previousHumanoid or alive ~= wasAlive
        previousCharacter, previousRoot, previousHumanoid, wasAlive = model, root, humanoid, alive
        if not alive then root, humanoid = nil, nil end
        return { model = model, root = root, humanoid = humanoid, alive = alive }, changed
    end
    function character:current(frame)
        return frame ~= nil and frame.alive and ctx.player.Character == frame.model
            and frame.model.Parent ~= nil and frame.root.Parent == frame.model
            and frame.humanoid.Parent == frame.model and frame.humanoid.Health > 0
    end
    return character
end

end)()

modules["dash"] = (function()
return function(ctx)
    local previousId, previousPosition, previousAt, previousSpeed, lastDetection
    local dash = {}
    local function horizontal(v) return math.sqrt(v.X * v.X + v.Z * v.Z) end
    function dash:reset()
        previousId, previousPosition, previousAt, previousSpeed, lastDetection = nil, nil, nil, nil, nil
    end
    function dash:sample(partnerId, snapshot, now)
        if not partnerId or not snapshot then self:reset(); return nil end
        local player = ctx.services.Players:GetPlayerByUserId(partnerId)
        local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if not root or not root:IsA("BasePart") then self:reset(); return nil end
        if previousId ~= partnerId then self:reset(); previousId = partnerId end
        local position, velocity = root.Position, root.AssemblyLinearVelocity
        if previousPosition and previousAt and now > previousAt and now - previousAt <= 0.15 then
            local measured = (position - previousPosition) / (now - previousAt)
            if horizontal(measured) > horizontal(velocity) and horizontal(measured) < 400 then velocity = measured end
        end
        local speed = horizontal(velocity)
        local detected = previousSpeed and speed >= 80 and (previousSpeed < 80 or speed - previousSpeed >= 15)
        previousPosition, previousAt, previousSpeed = position, now, speed
        if not detected or (lastDetection and now - lastDetection < 0.25) then return nil end
        local offset = snapshot.root - position
        local distance = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
        if distance == 0 or speed == 0 then return nil end
        local dot = (velocity.X * offset.X + velocity.Z * offset.Z) / (speed * distance)
        if dot < 0.3 then return nil end
        lastDetection = now
        return { player = player, position = position, velocity = velocity, distance = distance, closing = speed * dot }
    end
    return dash
end

end)()

modules["autoparry"] = (function()
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

end)()

modules["autoclash"] = (function()
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

end)()

modules["spam"] = (function()
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

end)()

modules["autodark"] = (function()
return function(ctx)
    local nextAttempt = 0
    local dark = {}
    function dark:reset() nextAttempt = 0 end
    function dark:step(now, character)
        if not character.alive or not ctx.config:get("AutoDark") or now < nextAttempt then return end
        nextAttempt = now + 0.3
        for _, player in ipairs(ctx.services.Players:GetPlayers()) do
            if player ~= ctx.player and player:GetAttribute("DarkSealed") == true then return end
        end
        local ability = ctx.info:ability(20, "SendEvent", now)
        local camera = ctx.services.Workspace.CurrentCamera
        if not ctx.active or not ability or not camera or not ctx.character:current(character) then return end
        local ok, err = pcall(ability.SendEvent, ability, 2.4141700243704228e76, camera.CFrame)
        if not ok then ctx.utils:report("Auto Dark", err) end
    end
    return dark
end

end)()

modules["movement"] = (function()
return function(ctx)
    local movement = {}
    function movement:step(character)
        local humanoid = character.humanoid
        if ctx.character:current(character) and ctx.config:get("AutoJump") and humanoid and humanoid.FloorMaterial ~= Enum.Material.Air
            and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
    function movement:upDash(now, character)
        if not character.alive then return false end
        local ability = ctx.info:ability(2, "Dash", now)
        if not ctx.active or not ability or ability.Dashing or not ctx.character:current(character) then return false end
        local ok, err = pcall(ability.Dash, ability)
        if not ok then ctx.utils:report("Up Dash", err); return false end
        if not ability.Dashing then return false end
        ability.MoveDir = Vector3.new(0, 1, 0)
        return true
    end
    return movement
end

end)()

modules["spin"] = (function()
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

end)()

modules["ui"] = (function()
return function(ctx, definitions)
    local input = ctx.services.UserInputService
    local screen = Instance.new("ScreenGui")
    screen.Name = "ExodusV3"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local parent
    if type(gethui) == "function" then
        local ok, value = pcall(gethui)
        if ok then parent = value end
    end
    if not parent then parent = ctx.services.CoreGui end
    local ok = pcall(function() screen.Parent = parent end)
    if not ok then
        local playerGui = ctx.player:FindFirstChildOfClass("PlayerGui")
        assert(playerGui, "PlayerGui indisponível")
        screen.Parent = playerGui
    end

    local colors = {
        background = Color3.fromRGB(19, 22, 34), button = Color3.fromRGB(38, 43, 63),
        enabled = Color3.fromRGB(24, 126, 95), accent = Color3.fromRGB(95, 119, 235),
        text = Color3.fromRGB(240, 242, 250), muted = Color3.fromRGB(165, 172, 194),
    }
    local function round(object, radius)
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, radius or 7)
        corner.Parent = object
    end
    local function button(parentObject, text, size)
        local item = Instance.new("TextButton")
        item.Size = size or UDim2.new(1, 0, 0, 31)
        item.BackgroundColor3 = colors.button
        item.BorderSizePixel = 0
        item.TextColor3 = colors.text
        item.Font = Enum.Font.GothamMedium
        item.TextSize = 13
        item.Text = text
        item.AutoButtonColor = true
        item.Parent = parentObject
        round(item)
        return item
    end
    local function enqueue(kind, fields)
        fields = fields or {}
        fields.kind = kind
        ctx.utils:enqueue(fields)
    end
    local function draggable(handle, target, xKey, yKey)
        local dragging, startInput, startPosition, moved, suppress = false, nil, nil, false, false
        ctx.utils:connect(handle.InputBegan, function(event)
            if event.UserInputType ~= Enum.UserInputType.MouseButton1 and event.UserInputType ~= Enum.UserInputType.Touch then return end
            dragging, startInput, startPosition, moved = event, event.Position, target.AbsolutePosition, false
        end)
        ctx.utils:connect(input.InputChanged, function(event)
            if not dragging then return end
            local matches = dragging.UserInputType == Enum.UserInputType.Touch and event == dragging
                or dragging.UserInputType == Enum.UserInputType.MouseButton1 and event.UserInputType == Enum.UserInputType.MouseMovement
            if not matches then return end
            local delta = event.Position - startInput
            if delta.Magnitude >= 5 then moved = true end
            if moved then target.Position = UDim2.fromOffset(math.floor(startPosition.X + delta.X), math.floor(startPosition.Y + delta.Y)) end
        end)
        ctx.utils:connect(input.InputEnded, function(event)
            if not dragging or event ~= dragging then return end
            dragging = nil
            if moved then
                suppress = true
                enqueue("set", { key = xKey, value = target.Position.X.Offset })
                enqueue("set", { key = yKey, value = target.Position.Y.Offset })
            end
        end)
        return function()
            if suppress then suppress = false; return true end
            return false
        end
    end

    local launcher = button(screen, "E", UDim2.fromOffset(48, 48))
    launcher.Position = UDim2.fromOffset(ctx.config:get("BtnX") or 14, ctx.config:get("BtnY") or 80)
    launcher.TextSize = 21
    launcher.BackgroundColor3 = colors.accent
    local launcherDragged = draggable(launcher, launcher, "BtnX", "BtnY")
    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(310, 430)
    panel.Position = UDim2.fromOffset(ctx.config:get("PanelX") or 70, ctx.config:get("PanelY") or 70)
    panel.BackgroundColor3 = colors.background
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.Parent = screen
    round(panel, 10)
    local header = button(panel, "EXODUS V3     •     arraste para mover", UDim2.new(1, -16, 0, 34))
    header.Position = UDim2.fromOffset(8, 8)
    header.BackgroundColor3 = colors.accent
    draggable(header, panel, "PanelX", "PanelY")
    ctx.utils:connect(launcher.Activated, function()
        if not launcherDragged() then panel.Visible = not panel.Visible end
    end)

    local list = Instance.new("ScrollingFrame")
    list.Position = UDim2.fromOffset(8, 50)
    list.Size = UDim2.new(1, -16, 1, -58)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 4
    list.CanvasSize = UDim2.new()
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Parent = panel
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 5)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = list
    local order = 0
    local function place(object)
        order += 1
        object.LayoutOrder = order
        return object
    end
    local function label(text)
        local item = Instance.new("TextLabel")
        item.Size = UDim2.new(1, 0, 0, 23)
        item.BackgroundTransparency = 1
        item.TextColor3 = colors.muted
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.Font = Enum.Font.GothamBold
        item.TextSize = 12
        item.Text = text
        item.Parent = list
        return place(item)
    end
    local toggleButtons = {}
    label("AUTOMAÇÕES E ATALHOS")
    for _, entry in ipairs(definitions) do
        if entry.kind == "boolean" then
            local key = entry.key
            local item = place(button(list, entry.label))
            toggleButtons[key] = { item = item, label = entry.label }
            ctx.utils:connect(item.Activated, function() enqueue("toggle", { key = key }) end)
        end
    end
    local manual = place(button(list, "Spam manual"))
    ctx.utils:connect(manual.Activated, function() enqueue("manualSpam") end)
    local upDash = place(button(list, "Up Dash"))
    ctx.utils:connect(upDash.Activated, function() enqueue("upDash") end)

    label("AJUSTES")
    local mode = place(button(list, "Taxa: CPF"))
    ctx.utils:connect(mode.Activated, function() enqueue("mode") end)
    local fields = {}
    local function field(key, title, multiplier)
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 31)
        row.BackgroundColor3 = colors.button
        row.BorderSizePixel = 0
        row.Parent = list
        round(row)
        place(row)
        local caption = Instance.new("TextLabel")
        caption.Size = UDim2.new(0.6, -6, 1, 0)
        caption.Position = UDim2.fromOffset(8, 0)
        caption.BackgroundTransparency = 1
        caption.TextColor3 = colors.text
        caption.TextXAlignment = Enum.TextXAlignment.Left
        caption.Font = Enum.Font.GothamMedium
        caption.TextSize = 12
        caption.Text = title
        caption.Parent = row
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(0.4, -12, 1, -6)
        box.Position = UDim2.new(0.6, 4, 0, 3)
        box.BackgroundColor3 = colors.background
        box.TextColor3 = colors.text
        box.Font = Enum.Font.Gotham
        box.TextSize = 12
        box.ClearTextOnFocus = false
        box.Parent = row
        round(box, 4)
        fields[key] = { box = box, multiplier = multiplier }
        ctx.utils:connect(box.FocusLost, function()
            local value = tonumber(box.Text)
            if value then enqueue("set", { key = key, value = value / multiplier }) end
            ctx.state.uiDirty = true
        end)
    end
    field("AutoParryWindowFactor", "Janela do parry (%)", 100)
    field("CPS", "Cliques por segundo (0–120)", 1)
    field("CPF", "Cliques/frame, base 60 FPS", 1)
    local binding
    local panicKey = place(button(list, "Tecla de emergência"))
    local spamKey = place(button(list, "Tecla do spam"))
    ctx.utils:connect(panicKey.Activated, function() binding = "Keybind"; ctx.state.uiDirty = true end)
    ctx.utils:connect(spamKey.Activated, function() binding = "SpamKeybind"; ctx.state.uiDirty = true end)

    label("UTILIDADES")
    local antiAfk = place(button(list, "Anti AFK"))
    ctx.utils:connect(antiAfk.Activated, function() enqueue("antiAfk") end)
    local spinButtons = {}
    for _, choice in ipairs({ { "Espada", "SwordCrate" }, { "Emote", "EmoteCrate" }, { "Explosão", "FinisherCrate" } }) do
        local crate = choice[2]
        local item = place(button(list, "Auto Spin: " .. choice[1]))
        spinButtons[#spinButtons + 1] = { item = item, label = choice[1], crate = crate }
        ctx.utils:connect(item.Activated, function() enqueue("spin", { crate = crate }) end)
    end
    local panic = place(button(list, "Parar spam / emergência"))
    ctx.utils:connect(panic.Activated, function() enqueue("panic") end)
    local close = place(button(list, "Fechar Exodus"))
    ctx.utils:connect(close.Activated, function() enqueue("stop") end)
    local status = label("Pronto")
    status.TextWrapped = true
    status.Size = UDim2.new(1, -4, 0, 45)

    local minis = {}
    local function mini(title, visibilityKey, action, xKey, yKey, defaultX, defaultY)
        local item = button(screen, title, UDim2.fromOffset(66, 42))
        item.Position = UDim2.fromOffset(ctx.config:get(xKey) or defaultX, ctx.config:get(yKey) or defaultY)
        item.TextSize = 11
        local dragged = draggable(item, item, xKey, yKey)
        ctx.utils:connect(item.Activated, function() if not dragged() then action() end end)
        minis[#minis + 1] = { item = item, title = title, visibility = visibilityKey }
    end
    mini("CLASH", "ClashBallVisible", function() enqueue("toggle", { key = "AutoClash" }) end, "ClashBallX", "ClashBallY", 14, 160)
    mini("DARK", "DarkBallVisible", function() enqueue("toggle", { key = "AutoDark" }) end, "DarkBallX", "DarkBallY", 14, 210)
    mini("JUMP", "JumpBallVisible", function() enqueue("toggle", { key = "AutoJump" }) end, "JumpBallX", "JumpBallY", 14, 260)
    mini("UP DASH", "UpDashBallVisible", function() enqueue("upDash") end, "UpDashBallX", "UpDashBallY", 14, 310)
    mini("SPAM", "MiniSpamVisible", function() enqueue("manualSpam") end, "MiniX", "MiniY", 14, 360)

    ctx.utils:connect(input.InputBegan, function(event, processed)
        if binding then
            if event.UserInputType == Enum.UserInputType.Keyboard and event.KeyCode ~= Enum.KeyCode.Unknown then
                enqueue("set", { key = binding, value = event.KeyCode })
                binding = nil
                ctx.state.uiDirty = true
            end
            return
        end
        if processed or input:GetFocusedTextBox() then return end
        if event.KeyCode == ctx.config:get("Keybind") then enqueue("panic")
        elseif event.KeyCode == ctx.config:get("SpamKeybind") then enqueue("manualSpam") end
    end)

    local ui = {}
    function ui:refresh()
        for key, entry in pairs(toggleButtons) do
            local enabled = ctx.config:get(key)
            entry.item.Text = entry.label .. (enabled and "  •  ON" or "  •  OFF")
            entry.item.BackgroundColor3 = enabled and colors.enabled or colors.button
        end
        manual.Text = "Spam manual  •  " .. (ctx.state.manualSpam and "ON" or "OFF")
        manual.BackgroundColor3 = ctx.state.manualSpam and colors.enabled or colors.button
        mode.Text = "Taxa do spam: " .. ctx.config:get("SpamRateMode")
        for key, fieldInfo in pairs(fields) do
            if not fieldInfo.box:IsFocused() then fieldInfo.box.Text = tostring(ctx.config:get(key) * fieldInfo.multiplier) end
        end
        panicKey.Text = binding == "Keybind" and "Pressione a tecla de emergência..." or "Emergência: " .. ctx.config:get("Keybind").Name
        spamKey.Text = binding == "SpamKeybind" and "Pressione a tecla do spam..." or "Spam: " .. ctx.config:get("SpamKeybind").Name
        antiAfk.Text = "Anti AFK  •  " .. (ctx.state.antiAfk and "ON" or "OFF")
        antiAfk.BackgroundColor3 = ctx.state.antiAfk and colors.enabled or colors.button
        for _, entry in ipairs(spinButtons) do
            local enabled = ctx.state.spin == entry.crate
            entry.item.Text = "Auto Spin: " .. entry.label .. (enabled and "  •  ON" or "  •  OFF")
            entry.item.BackgroundColor3 = enabled and colors.enabled or colors.button
        end
        for _, entry in ipairs(minis) do
            local item = entry.item
            item.Visible = ctx.config:get(entry.visibility) == true
            local enabled = entry.title == "CLASH" and ctx.config:get("AutoClash")
                or entry.title == "DARK" and ctx.config:get("AutoDark")
                or entry.title == "JUMP" and ctx.config:get("AutoJump")
                or entry.title == "SPAM" and ctx.state.manualSpam
            item.BackgroundColor3 = enabled and colors.enabled or colors.button
            item.Text = entry.title .. (entry.title ~= "UP DASH" and (enabled and "\nON" or "\nOFF") or "")
        end
        status.Text = ctx.state.error and ("Último erro: " .. ctx.state.error) or (ctx.state.status or "Iniciando")
    end
    function ui:destroy() screen:Destroy() end
    return ui
end

end)()

modules["bootstrap"] = (function()
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

end)()

local function launch(...)
-- The standalone bundle passes its modules here. This source loader can also
-- load a complete local checkout or one immutable GitHub revision.
local modules = ...
if type(modules) ~= "table" then
    local manifest = {
        { "uiconfig", "modules/front/uiconfig.luau" },
        { "config", "modules/front/config.luau" },
        { "utils", "modules/logic/utils.luau" },
        { "gameinfo", "modules/logic/gameinfo.luau" },
        { "remote", "modules/logic/remote.luau" },
        { "character", "modules/logic/character.luau" },
        { "dash", "modules/logic/dash.luau" },
        { "autoparry", "modules/logic/autoparry.luau" },
        { "autoclash", "modules/logic/autoclash.luau" },
        { "spam", "modules/logic/spam.luau" },
        { "autodark", "modules/logic/autodark.luau" },
        { "movement", "modules/logic/movement.luau" },
        { "spin", "modules/logic/spin.luau" },
        { "ui", "modules/front/ui.luau" },
        { "bootstrap", "bootstrap.luau" },
    }
    local root
    if type(isfile) == "function" and type(readfile) == "function" then
        for _, candidate in ipairs({ "exodus hub", "Exodus-v2/exodus hub", "Exodus-v2-main/exodus hub" }) do
            local complete = true
            for _, entry in ipairs(manifest) do
                local ok, exists = pcall(isfile, candidate .. "/" .. entry[2])
                if not ok or not exists then complete = false; break end
            end
            if complete then root = candidate; break end
        end
    end
    local function get(url)
        local requestFunction = type(request) == "function" and request or (type(http_request) == "function" and http_request or nil)
        if requestFunction then
            local response = requestFunction({ Url = url, Method = "GET", Headers = { ["Accept"] = "application/vnd.github+json" } })
            local status = response and tonumber(response.StatusCode or response.status_code)
            assert(status and status >= 200 and status < 300, "HTTP " .. tostring(status))
            return response.Body or response.body or response.ResponseBody
        end
        return game:HttpGet(url)
    end
    local revision
    if not root then
        revision = _G.EXODUS_REVISION
        if not revision then
            local body = get("https://api.github.com/repos/Repp35/Exodus-v2/commits/main")
            revision = game:GetService("HttpService"):JSONDecode(body).sha
        end
        assert(type(revision) == "string" and #revision == 40 and revision:match("^[%da-fA-F]+$"), "revisão GitHub inválida")
    end
    modules = {}
    for _, entry in ipairs(manifest) do
        local source
        if root then source = readfile(root .. "/" .. entry[2])
        else source = get("https://raw.githubusercontent.com/Repp35/Exodus-v2/" .. revision .. "/exodus%20hub/" .. entry[2]) end
        assert(type(source) == "string" and source ~= "", "módulo vazio: " .. entry[1])
        local chunk, compileError = loadstring(source, "Exodus/" .. entry[1])
        assert(chunk, compileError)
        modules[entry[1]] = chunk()
    end
end
return modules.bootstrap(modules)

end
return launch(modules)
