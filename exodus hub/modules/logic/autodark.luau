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
