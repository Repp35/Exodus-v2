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
