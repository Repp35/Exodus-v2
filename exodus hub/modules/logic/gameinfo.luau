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
