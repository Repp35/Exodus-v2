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
