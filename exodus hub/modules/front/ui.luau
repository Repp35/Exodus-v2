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
