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
