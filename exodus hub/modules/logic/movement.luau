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
