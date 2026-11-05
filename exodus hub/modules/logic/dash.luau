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
