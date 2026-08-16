-- [[ UI ]]

-- services
local ExodusUI = {}
local Utils
local Controls = {}
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local Camera = workspace.CurrentCamera
local _wait = task.wait
local _spawn = task.spawn

-- state
local UIState = {
    connections = {},
    panelOpen = false,
    spamOn = false,
    clashBallOn = false,
    btnIsDragging = function() return false end,
    panelTween = nil,
    btnTween = nil,
}

-- palette
local C = {
    bg = Color3.fromRGB(8, 8, 22),
    header = Color3.fromRGB(14, 14, 34),
    card = Color3.fromRGB(20, 20, 44),
    accent = Color3.fromRGB(99, 102, 241),
    accentPink = Color3.fromRGB(236, 72, 153),
    green = Color3.fromRGB(34, 197, 94),
    red = Color3.fromRGB(239, 68, 68),
    redDark = Color3.fromRGB(153, 27, 27),
    text = Color3.fromRGB(240, 240, 255),
    subtext = Color3.fromRGB(140, 140, 200),
    border = Color3.fromRGB(55, 55, 100),
    btnBlue = Color3.fromRGB(45, 55, 130),
    btnDark = Color3.fromRGB(30, 30, 65),
    toggleOn = Color3.fromRGB(139, 92, 246),
    toggleOff = Color3.fromRGB(45, 45, 80),
    hold = Color3.fromRGB(236, 72, 153),
    inputBg = Color3.fromRGB(16, 16, 38)
}
local GRAD = {
    Color3.fromRGB(56, 189, 248),
    Color3.fromRGB(139, 92, 246),
    Color3.fromRGB(236, 72, 153)
}
local EASE_OUT, EASE_BACK, EASE_SINE = Enum.EasingStyle.Quint, Enum.EasingStyle.Back, Enum.EasingStyle.Sine
local DIR_OUT, DIR_IN, DIR_INOUT = Enum.EasingDirection.Out, Enum.EasingDirection.In, Enum.EasingDirection.InOut

-- helpers
local function inst(cls, props, parent)
    local o = Instance.new(cls)
    if props then
        for k, v in pairs(props) do
            o[k] = v
        end
    end
    if parent then
        o.Parent = parent
    end
    return o
end
local function corner(obj, r)
    return inst("UICorner", {CornerRadius = UDim.new(0, r)}, obj)
end
local function stroke(obj, col, th)
    return inst("UIStroke", {Color = col, Thickness = th or 1}, obj)
end

-- animation
local function attachFlow(s)
    local g = inst("UIGradient", {Rotation = 0}, s)
    g.Color =
        ColorSequence.new(
        {
            ColorSequenceKeypoint.new(0, GRAD[1]),
            ColorSequenceKeypoint.new(0.5, GRAD[2]),
            ColorSequenceKeypoint.new(1, GRAD[3])
        }
    )
    return g
end
local function twPlay(obj, t, props, style, dir)
    if not obj or obj.Parent == nil then
        return nil
    end
    local ok, tween = pcall(function()
        return TweenService:Create(obj, TweenInfo.new(t, style or EASE_OUT, dir or DIR_OUT), props)
    end)
    if not ok or not tween then
        return nil
    end
    tween:Play()
    return tween
end

-- safety
local function safeCancel(t)
    if t then
        pcall(
            function()
                t:Cancel()
            end
        )
    end
end

-- layout
local function viewport()
    local currentCamera = workspace.CurrentCamera or Camera
    return currentCamera and currentCamera.ViewportSize or Vector2.new(1920, 1080)
end

-- connections
local function trackConn(c)
    if c and type(c.Disconnect) == "function" then
        UIState.connections[#UIState.connections + 1] = c
    end
    return c
end
local function safe(fn, ...)
    return pcall(fn, ...)
end
local function untrackConn(c)
    for i = #UIState.connections, 1, -1 do
        if UIState.connections[i] == c then
            table.remove(UIState.connections, i)
            return
        end
    end
end
local function safeDisconnect(c)
    if c then
        safe(
            function()
                c:Disconnect()
            end
        )
    end
end
local function disconnectUIConnections()
    for i = #UIState.connections, 1, -1 do
        safeDisconnect(UIState.connections[i])
        UIState.connections[i] = nil
    end
end
local function isKey(input, keyCode)
    return input and keyCode and input.KeyCode == keyCode
end

-- input
local function bindInput()
    trackConn(UIS.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then
            return
        end
        local config = Utils.getConfig() or {}
        local panicKey = config.Keybind
        local spamKey = config.SpamKeybind
        local mode = config.SpamMode == "Hold" and "Hold" or "Toggle"
        if isKey(input, panicKey) then
            Utils.setManualSpamActive(false)
            if type(Controls.onPanic) == "function" then
                safe(Controls.onPanic)
            end
        elseif isKey(input, spamKey) then
            if mode == "Hold" then
                Utils.setManualSpamActive(true)
            else
                Utils.setManualSpamActive(not Utils.isManualSpamActive())
            end
        end
    end))
    trackConn(UIS.InputEnded:Connect(function(input)
        local config = Utils.getConfig() or {}
        if config.SpamMode == "Hold" and isKey(input, config.SpamKeybind) then
            Utils.setManualSpamActive(false)
        end
    end))
end

-- drag
local function makeDraggable(handle, target, onDragEnd)
    local dragInput, dragOffX, dragOffY = nil, 0, 0
    local state, wasDragged, startX, startY = "Idle", false, 0, 0
    local THRESH_SQ = 100
    trackConn(
        handle.InputBegan:Connect(
            function(input)
                if
                    input.UserInputType ~= Enum.UserInputType.MouseButton1 and
                        input.UserInputType ~= Enum.UserInputType.Touch
                 then
                    return
                end
                if state ~= "Idle" then
                    return
                end
                state, wasDragged, dragInput = "Pressed", false, input
                local abs = target.AbsolutePosition
                dragOffX, dragOffY = input.Position.X - abs.X, input.Position.Y - abs.Y
                startX, startY = input.Position.X, input.Position.Y
            end
        )
    )
    trackConn(
        UIS.InputChanged:Connect(
            function(input)
                if state == "Idle" or input ~= dragInput then
                    return
                end
                if
                    input.UserInputType ~= Enum.UserInputType.MouseMovement and
                        input.UserInputType ~= Enum.UserInputType.Touch
                 then
                    return
                end
                local dx, dy = input.Position.X - startX, input.Position.Y - startY
                if state == "Pressed" and (dx * dx + dy * dy) >= THRESH_SQ then
                    state, wasDragged = "Dragging", true
                end
                if state == "Dragging" then
                    local vp, sz = viewport(), target.AbsoluteSize
                    target.Position =
                        UDim2.new(
                        0,
                        math.clamp(input.Position.X - dragOffX, 0, vp.X - sz.X),
                        0,
                        math.clamp(input.Position.Y - dragOffY, 0, vp.Y - sz.Y)
                    )
                end
            end
        )
    )
    trackConn(
        UIS.InputEnded:Connect(
            function(input)
                if input ~= dragInput or state == "Idle" then
                    return
                end
                state, dragInput = "Idle", nil
                if wasDragged and onDragEnd then
                    safe(onDragEnd)
                end
                wasDragged = false
            end
        )
    )
    return function()
        return state == "Dragging"
    end
end
local flowingGradients = {}

-- effects
local function registerFlow(obj)
    flowingGradients[#flowingGradients + 1] = attachFlow(obj)
end
local function startFlowingLoop(gui)
    _spawn(
        function()
            local STEP = 0.005
            while gui.Parent do
                for off = 0, 1, STEP do
                    if not gui.Parent then
                        return
                    end
                    for i = #flowingGradients, 1, -1 do
                        local g = flowingGradients[i]
                        if g and g.Parent then
                            g.Offset = Vector2.new(off, 0)
                        else
                            table.remove(flowingGradients, i)
                        end
                    end
                    _wait(0.03)
                end
            end
        end
    )
end
local screenGui
local floatingButton
local BTN_SIZE = 56

-- floating button
local function btnPos()
    local config = Utils.getConfig()
    local x, y = config.BtnX, config.BtnY
    if type(x) == "number" and type(y) == "number" then
        return UDim2.new(0, x, 0, y)
    end
    return UDim2.new(1, -70, 0.5, -28)
end
local clashBall
local CLASH_SIZE = 64
local OFFSCREEN_X = -CLASH_SIZE - 40
local autoClashTrack, autoClashThumb

-- clash ui
local function paintClashBall()
    if not clashBall or not clashBall.Parent then
        return
    end
    twPlay(clashBall, 0.28, {BackgroundColor3 = UIState.clashBallOn and C.green or C.red}, EASE_SINE, DIR_INOUT)
    clashBall.Text = UIState.clashBallOn and "ON" or "OFF"
    clashBall.TextSize = UIState.clashBallOn and 18 or 16
end
local function syncAutoClashToggle()
    if not (autoClashTrack and autoClashThumb) then
        return
    end
    local v = UIState.clashBallOn
    twPlay(autoClashTrack, 0.22, {BackgroundColor3 = v and C.toggleOn or C.toggleOff}, EASE_SINE, DIR_INOUT)
    twPlay(
        autoClashThumb,
        0.32,
        {Position = v and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10)},
        EASE_BACK,
        DIR_OUT
    )
end
local function setClashBall(v, silent)
    UIState.clashBallOn = v
    local config = Utils.getConfig()
    config.AutoClash = v
    Utils.setConfig(config)
    if silent then
        return
    end
    paintClashBall()
    twPlay(clashBall, 0.08, {Size = UDim2.new(0, CLASH_SIZE - 6, 0, CLASH_SIZE - 6)}, EASE_SINE, DIR_OUT)
    task.delay(
        0.08,
        function()
            twPlay(clashBall, 0.28, {Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE)}, EASE_BACK, DIR_OUT)
        end
    )
end
local function showClashBall(v)
    local config = Utils.getConfig()
    config.ClashBallVisible = v
    Utils.setConfig(config)
    local clashX = config.ClashBallX or 14
    local clashY = config.ClashBallY or (viewport().Y / 2 - CLASH_SIZE / 2)
    twPlay(
        clashBall,
        (v and 0.22) or 0.18,
        {Position = v and UDim2.new(0, clashX, 0, clashY) or UDim2.new(0, OFFSCREEN_X, 0, clashY)},
        v and EASE_BACK or EASE_OUT,
        DIR_OUT
    )
end
local miniGui
local MINI_W, MINI_H = 120, 90
local function showMini(v, visBtn)
    local config = Utils.getConfig()
    local miniX = config.MiniX or (viewport().X - MINI_W - 14)
    local miniY = config.MiniY or (viewport().Y / 2 - MINI_H / 2)
    local MINI_OFF_X = viewport().X + 30
    twPlay(
        miniGui,
        (v and 0.22) or 0.18,
        {Position = v and UDim2.new(0, miniX, 0, miniY) or UDim2.new(0, MINI_OFF_X, 0, miniY)},
        v and EASE_BACK or EASE_OUT,
        DIR_OUT
    )
    if visBtn and visBtn.Parent then
        visBtn.Text = v and "Mini UI: Visivel" or "Mini UI: Oculto"
        twPlay(visBtn, 0.15, {BackgroundColor3 = v and Color3.fromRGB(0, 130, 65) or C.btnDark})
    end
end

-- spam ui
local function setSpam(v)
    UIState.spamOn = v
    Utils.setManualSpamActive(v)
    if not miniGui or not miniGui.Parent then
        return
    end
    local spamBtn = miniGui:FindFirstChild("SpamButton")
    if spamBtn then
        spamBtn.Text = v and "ON" or "OFF"
        twPlay(spamBtn, 0.25, {BackgroundColor3 = v and C.green or C.red}, EASE_SINE, DIR_INOUT)
        twPlay(spamBtn, 0.08, {Size = UDim2.new(1, -22, 0, 44)}, EASE_SINE, DIR_OUT)
        task.delay(
            0.08,
            function()
                twPlay(spamBtn, 0.28, {Size = UDim2.new(1, -16, 0, 48)}, EASE_BACK, DIR_OUT)
            end
        )
    end
end
local configPanel
local PW, PH = 540, 380
local TITLE_H, PAD, GAP, CARD_GAP = 50, 14, 12, 8
local INNER_PAD, CONTROL_GAP, CARD_H, RATE_CARD_H, SPAM_CARD_H = 14, 12, 52, 68, 118
local CONTENT_H = PH - TITLE_H - 60
local COL_W = math.floor((PW - PAD * 2 - GAP) / 2)
local LEFT_STACK_H = CARD_H * 3 + CARD_GAP * 2
local RIGHT_STACK_H = RATE_CARD_H + CARD_H + SPAM_CARD_H + CARD_GAP * 2

-- panel
local function panelPos()
    local config = Utils.getConfig()
    local x, y = config.PanelX, config.PanelY
    if type(x) == "number" and type(y) == "number" then
        return UDim2.new(0, x, 0, y)
    end
    return UDim2.new(0.5, -PW / 2, 0.5, -PH / 2)
end
local particleLayer
local PARTICLE_COLORS = {
    Color3.fromRGB(85, 90, 140),
    Color3.fromRGB(110, 95, 150),
    Color3.fromRGB(150, 95, 130),
    Color3.fromRGB(95, 130, 165)
}

-- cleanup
local function cleanupUI()
    safeCancel(UIState.panelTween)
    safeCancel(UIState.btnTween)
    disconnectUIConnections()
    UIState.connections = {}
    UIState.panelOpen = false
    UIState.spamOn = false
    UIState.clashBallOn = false
    UIState.panelTween = nil
    UIState.btnTween = nil
    UIState.btnIsDragging = function() return false end
    flowingGradients = {}
    local current = screenGui
    if current then
        pcall(function() current:Destroy() end)
    end
    screenGui = nil
    floatingButton = nil
    clashBall = nil
    miniGui = nil
    configPanel = nil
    particleLayer = nil
    titleBar = nil
    closeButton = nil
    colLeft = nil
    colRight = nil
    killBtn = nil
    autoClashTrack = nil
    autoClashThumb = nil
    if _G.ExodusUICleanup == cleanupUI then
        _G.ExodusUICleanup = nil
    end
end

-- particles
local function spawnParticle()
    if not particleLayer or not particleLayer.Parent then
        return
    end
    local isFar = math.random() < 0.6
    local size = isFar and math.random(2, 3) or math.random(4, 6)
    local startTrans = isFar and 0.5 or 0.2
    local color = PARTICLE_COLORS[math.random(1, #PARTICLE_COLORS)]
    local dot =
        inst(
        "Frame",
        {
            Size = UDim2.new(0, size, 0, size),
            Position = UDim2.new(math.random(), 0, 1, 0),
            BackgroundColor3 = color,
            BackgroundTransparency = startTrans,
            ZIndex = 4,
            Parent = particleLayer
        }
    )
    corner(dot, 999)
    local dur = isFar and math.random(5, 9) or math.random(3, 5)
    local endX = math.clamp(dot.Position.X.Scale + (math.random() - 0.5) * 0.15, 0, 1)
    twPlay(dot, 0.6, {BackgroundTransparency = math.max(startTrans - 0.1, 0.05)}, EASE_SINE, DIR_OUT)
    twPlay(dot, dur, {Position = UDim2.new(endX, 0, -0.1, 0), BackgroundTransparency = 1}, EASE_SINE, DIR_INOUT)
    task.delay(
        dur + 0.2,
        function()
            if dot.Parent then
                dot:Destroy()
            end
        end
    )
end
local titleBar
local closeButton
local colLeft
local colRight
local killBtn

-- cards
local function cardFrame(yPos, h, parent)
    local f =
        inst(
        "Frame",
        {
            Size = UDim2.new(1, 0, 0, h),
            Position = UDim2.new(0, 0, 0, yPos),
            BackgroundColor3 = C.card,
            BackgroundTransparency = 0.1,
            ZIndex = 6,
            Parent = parent
        }
    )
    corner(f, 12)
    local s = stroke(f, C.border, 1)
    trackConn(f.MouseEnter:Connect(
        function()
            twPlay(s, 0.22, {Color = C.accent}, EASE_SINE, DIR_INOUT)
            twPlay(f, 0.22, {BackgroundColor3 = Color3.fromRGB(24, 24, 50)}, EASE_SINE, DIR_INOUT)
        end
    ))
    trackConn(f.MouseLeave:Connect(
        function()
            twPlay(s, 0.25, {Color = C.border}, EASE_SINE, DIR_INOUT)
            twPlay(f, 0.25, {BackgroundColor3 = C.card}, EASE_SINE, DIR_INOUT)
        end
    ))
    return f
end
local function cardLabel(text, parent)
    inst(
        "TextLabel",
        {
            Size = UDim2.new(1, -INNER_PAD * 2, 0, 16),
            Position = UDim2.new(0, INNER_PAD, 0, 5),
            BackgroundTransparency = 1,
            Text = text,
            TextColor3 = C.accent,
            TextSize = 10,
            Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 7,
            Parent = parent
        }
    )
end
local function makeBtn(text, x, y, w, h, parent, bg)
    local b =
        inst(
        "TextButton",
        {
            Size = UDim2.new(0, w, 0, h),
            Position = UDim2.new(0, x, 0, y),
            BackgroundColor3 = bg or C.btnBlue,
            BackgroundTransparency = 0.1,
            Text = text,
            TextColor3 = C.text,
            TextSize = 13,
            Font = Enum.Font.GothamBold,
            ZIndex = 7,
            Parent = parent
        }
    )
    corner(b, 8)
    return b
end
local function makeToggle(trackParent, initial)
    local track =
        inst(
        "Frame",
        {
            Size = UDim2.new(0, 48, 0, 26),
            Position = UDim2.new(1, -INNER_PAD - 48, 0.5, -13),
            BackgroundColor3 = initial and C.toggleOn or C.toggleOff,
            BackgroundTransparency = 0.1,
            ZIndex = 7,
            Parent = trackParent
        }
    )
    corner(track, 999)
    local thumb =
        inst(
        "Frame",
        {
            Size = UDim2.new(0, 20, 0, 20),
            Position = initial and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10),
            BackgroundColor3 = Color3.new(1, 1, 1),
            ZIndex = 8,
            Parent = track
        }
    )
    corner(thumb, 999)
    local function setVisual(v)
        twPlay(track, 0.22, {BackgroundColor3 = v and C.toggleOn or C.toggleOff}, EASE_SINE, DIR_INOUT)
        twPlay(
            thumb,
            0.32,
            {Position = v and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10)},
            EASE_BACK,
            DIR_OUT
        )
        twPlay(thumb, 0.08, {Size = UDim2.new(0, 24, 0, 24)}, EASE_SINE, DIR_OUT)
        task.delay(
            0.08,
            function()
                twPlay(thumb, 0.18, {Size = UDim2.new(0, 20, 0, 20)}, EASE_BACK, DIR_OUT)
            end
        )
    end
    return track, thumb, setVisual
end

-- keybind
local function bindKeyCapture(btn, onPicked)
    local listening = false
    trackConn(
        btn.Activated:Connect(
            function()
                if listening then
                    return
                end
                listening = true
                btn.Text = "..."
                twPlay(btn, 0.1, {BackgroundColor3 = Color3.fromRGB(80, 85, 160)})
                local conn
                conn =
                    trackConn(
                    UIS.InputBegan:Connect(
                        function(input, gpe)
                            if gpe then
                                return
                            end
                            if input.UserInputType ~= Enum.UserInputType.Keyboard then
                                return
                            end
                            safe(onPicked, input.KeyCode)
                            listening = false
                            safeDisconnect(conn)
                            untrackConn(conn)
                        end
                    )
                )
            end
        )
    )
end

-- cards
local function createToggleCard(labelText, configKey, yPos, parent, onAfter)
    local f = cardFrame(yPos, CARD_H, parent)
    inst(
        "TextLabel",
        {
            Size = UDim2.new(1, -INNER_PAD * 2 - 48 - CONTROL_GAP, 1, 0),
            Position = UDim2.new(0, INNER_PAD, 0, 0),
            BackgroundTransparency = 1,
            Text = labelText,
            TextColor3 = C.text,
            TextSize = 14,
            Font = Enum.Font.GothamSemibold,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 7,
            Parent = f
        }
    )
    local config = Utils.getConfig()
    local initial = configKey and config[configKey] or false
    local state = initial
    local _, _, setVisual = makeToggle(f, initial)
    trackConn(
        inst(
            "TextButton",
            {
                Size = UDim2.new(1, 0, 1, 0),
                BackgroundTransparency = 1,
                Text = "",
                ZIndex = 9,
                Parent = f
            }
        ).Activated:Connect(
            function()
                state = not state
                if configKey then
                    config[configKey] = state
                    Utils.setConfig(config)
                end
                setVisual(state)
                if onAfter then
                    onAfter(state)
                end
            end
        )
    )
    return yPos + CARD_H + CARD_GAP
end

-- rate selector
local function createRateSelector(yPos, parent)
    local f = cardFrame(yPos, RATE_CARD_H, parent)
    local config = Utils.getConfig()
    config.CPS = Utils.normalizeSpamRate(config.CPS, 0)
    Utils.setConfig(config)
    local rateMode = config.SpamRateMode == "CPS" and "CPS" or "CPF"
    config.SpamRateMode = rateMode
    Utils.setConfig(config)
    cardLabel("Spam Rate", f)
    local rateLabel =
        inst(
        "TextLabel",
        {
            Size = UDim2.new(0, 36, 0, 30),
            Position = UDim2.new(0, 14, 0, 28),
            BackgroundTransparency = 1,
            Text = rateMode .. ":",
            TextColor3 = C.text,
            TextSize = 13,
            Font = Enum.Font.Gotham,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 7,
            Parent = f
        }
    )
    local rateInputWidth, rateModeWidth, rateDefaultWidth = 84, 34, 54
    local defBtn = makeBtn("Padrao", 52, 28, rateDefaultWidth, 30, f, C.btnBlue)
    defBtn.TextSize = 10
    local modeBtn = makeBtn(rateMode, 112, 28, rateModeWidth, 30, f, C.btnPurple)
    modeBtn.TextSize = 10
    trackConn(modeBtn.Activated:Connect(
        function()
            local currentConfig = Utils.getConfig()
            currentConfig.SpamRateMode = currentConfig.SpamRateMode == "CPS" and "CPF" or "CPS"
            Utils.setConfig(currentConfig)
            modeBtn.Text = currentConfig.SpamRateMode
            rateLabel.Text = currentConfig.SpamRateMode .. ":"
        end
    ))
    local inputBox =
        inst(
        "TextBox",
        {
            Size = UDim2.new(0, rateInputWidth, 0, 30),
            Position = UDim2.new(1, -INNER_PAD - rateInputWidth, 0, 28),
            BackgroundColor3 = C.inputBg,
            BackgroundTransparency = 0.1,
            Text = tostring(config.CPS),
            PlaceholderText = "0-5B",
            TextColor3 = C.text,
            TextSize = 13,
            Font = Enum.Font.GothamBold,
            ZIndex = 7,
            Parent = f
        }
    )
    corner(inputBox, 8)
    local inputStroke = stroke(inputBox, C.border, 1)
    trackConn(inputBox.Focused:Connect(
        function()
            twPlay(inputStroke, 0.15, {Color = C.accent})
        end
    ))
    trackConn(inputBox.FocusLost:Connect(
        function()
            twPlay(inputStroke, 0.15, {Color = C.border})
        end
    ))
    trackConn(defBtn.Activated:Connect(
        function()
            local currentConfig = Utils.getConfig()
            currentConfig.CustomCPS = false
            currentConfig.CPS = 25
            Utils.setConfig(currentConfig)
            inputBox.Text = "25"
            twPlay(defBtn, 0.15, {BackgroundColor3 = C.green})
            task.delay(
                0.5,
                function()
                    twPlay(defBtn, 0.15, {BackgroundColor3 = C.btnBlue})
                end
            )
        end
    ))
    trackConn(inputBox.FocusLost:Connect(
        function()
            local v = tonumber(inputBox.Text)
            local currentConfig = Utils.getConfig()
            if v then
                local normalized = Utils.normalizeSpamRate(v, currentConfig.CPS)
                currentConfig.CPS, currentConfig.CustomCPS = normalized, true
                Utils.setConfig(currentConfig)
                inputBox.Text = tostring(normalized)
            else
                inputBox.Text = tostring(Utils.normalizeSpamRate(currentConfig.CPS, 0))
            end
        end
    ))
    return yPos + CARD_H + CARD_GAP
end
local function createKeybindSelector(yPos, parent)
    local f = cardFrame(yPos, CARD_H, parent)
    inst(
        "TextLabel",
        {
            Size = UDim2.new(1, -INNER_PAD * 2 - 88 - CONTROL_GAP, 1, 0),
            Position = UDim2.new(0, INNER_PAD, 0, 0),
            BackgroundTransparency = 1,
            Text = "Tecla de Atalho",
            TextColor3 = C.text,
            TextSize = 14,
            Font = Enum.Font.GothamSemibold,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 7,
            Parent = f
        }
    )
    local config = Utils.getConfig()
    local kbBtn = makeBtn(config.Keybind and config.Keybind.Name or "V", 0, 0, 88, 30, f, C.btnBlue)
    kbBtn.Position = UDim2.new(1, -INNER_PAD - 88, 0.5, -15)
    bindKeyCapture(
        kbBtn,
        function(keyCode)
            local currentConfig = Utils.getConfig()
            currentConfig.Keybind = keyCode
            Utils.setConfig(currentConfig)
            kbBtn.Text = keyCode.Name
            twPlay(kbBtn, 0.18, {BackgroundColor3 = C.btnBlue}, EASE_BACK)
        end
    )
    return yPos + CARD_H + CARD_GAP
end
local function createSpamCard(yPos, parent)
    local f = cardFrame(yPos, SPAM_CARD_H, parent)
    cardLabel("Manual Spam", f)
    local halfW = math.floor((COL_W - INNER_PAD * 2 - CONTROL_GAP) / 2)
    local visBtn = makeBtn("Mini UI: Oculto", INNER_PAD, 24, COL_W - INNER_PAD * 2, 30, f, C.btnDark)
    visBtn.TextSize = 11
    trackConn(visBtn.Activated:Connect(
        function()
            showMini(miniGui.Position.X.Offset > viewport().X - 50, visBtn)
        end
    ))
    local config = Utils.getConfig()
    local kbBtn = makeBtn(config.SpamKeybind and config.SpamKeybind.Name or "X", INNER_PAD, 64, halfW, 32, f, C.btnBlue)
    bindKeyCapture(
        kbBtn,
        function(keyCode)
            local currentConfig = Utils.getConfig()
            currentConfig.SpamKeybind = keyCode
            Utils.setConfig(currentConfig)
            kbBtn.Text = keyCode.Name
            twPlay(kbBtn, 0.18, {BackgroundColor3 = C.btnBlue}, EASE_BACK)
        end
    )
    local function modeColor(mode)
        return mode == "Hold" and C.hold or C.toggleOn
    end
    local modeBtn = makeBtn(config.SpamMode or "Toggle", INNER_PAD + halfW + CONTROL_GAP, 64, halfW, 32, f, modeColor(config.SpamMode))
    trackConn(modeBtn.Activated:Connect(
        function()
            local currentConfig = Utils.getConfig()
            currentConfig.SpamMode = (currentConfig.SpamMode == "Toggle") and "Hold" or "Toggle"
            Utils.setConfig(currentConfig)
            modeBtn.Text = currentConfig.SpamMode
            twPlay(modeBtn, 0.18, {BackgroundColor3 = modeColor(currentConfig.SpamMode)}, EASE_BACK)
            if currentConfig.SpamMode == "Toggle" and Utils.isManualSpamActive() then
                setSpam(false)
            end
        end
    ))
    return yPos + SPAM_CARD_H + CARD_GAP
end

-- panel controls
local function togglePanel()
    if not configPanel or not configPanel.Parent or not floatingButton or not floatingButton.Parent then
        return
    end
    UIState.panelOpen = not UIState.panelOpen
    safeCancel(UIState.panelTween)
    safeCancel(UIState.btnTween)
    if UIState.panelOpen then
        configPanel.Visible = true
        configPanel.BackgroundTransparency = 1
        configPanel.Size = UDim2.new(0, PW * 0.88, 0, PH * 0.88)
        UIState.panelTween =
            twPlay(configPanel, 0.28, {Size = UDim2.new(0, PW, 0, PH), BackgroundTransparency = 0}, EASE_BACK, DIR_OUT)
        UIState.btnTween =
            twPlay(
            floatingButton,
            0.2,
            {BackgroundTransparency = 0.6, TextTransparency = 0, Size = UDim2.new(0, 44, 0, 44)},
            EASE_OUT,
            DIR_IN
        )
    else
        UIState.panelTween =
            twPlay(
            configPanel,
            0.22,
            {Size = UDim2.new(0, PW * 0.9, 0, PH * 0.9), BackgroundTransparency = 1},
            EASE_OUT,
            DIR_IN
        )
        UIState.btnTween =
            twPlay(
            floatingButton,
            0.22,
            {BackgroundTransparency = 0.1, TextTransparency = 0, Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE)},
            EASE_BACK,
            DIR_OUT
        )
        local conn
        conn =
            trackConn(
            UIState.panelTween.Completed:Connect(
                function()
                    if not UIState.panelOpen then
                        configPanel.Visible = false
                        configPanel.Size = UDim2.new(0, PW, 0, PH)
                        configPanel.BackgroundTransparency = 0
                    end
                    safeDisconnect(conn)
                    untrackConn(conn)
                end
            )
        )
    end
end

-- setup
function ExodusUI.setup(deps)
    if type(deps) ~= "table" or not deps.Utils then
        return false
    end
    Utils = deps.Utils
    Controls = type(deps.Controls) == "table" and deps.Controls or {}
    if type(_G.ExodusUICleanup) == "function" then
        pcall(_G.ExodusUICleanup)
    else
        local old = CoreGui:FindFirstChild("ExodusUISystem")
        if old then
            old:Destroy()
        end
    end
    UIState.panelOpen = false
    UIState.spamOn = false
    UIState.clashBallOn = false
    UIState.panelTween = nil
    UIState.btnTween = nil
    _G.ExodusUICleanup = cleanupUI
    screenGui =
        inst(
        "ScreenGui",
        {
            Name = "ExodusUISystem",
            ResetOnSpawn = false,
            IgnoreGuiInset = true,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
            Parent = CoreGui
        }
    )
    startFlowingLoop(screenGui)
    bindInput()
    floatingButton =
        inst(
        "TextButton",
        {
            Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE),
            Position = btnPos(),
            BackgroundColor3 = C.header,
            BackgroundTransparency = 1,
            Text = "E",
            TextTransparency = 1,
            TextColor3 = C.text,
            TextSize = 26,
            Font = Enum.Font.GothamBold,
            Active = true,
            ZIndex = 10,
            Parent = screenGui
        }
    )
    corner(floatingButton, 999)
    local floatingStroke = stroke(floatingButton, C.accent, 2)
    floatingStroke.Transparency = 1
    registerFlow(floatingStroke)
    UIState.btnTween = twPlay(
        floatingButton,
        0.45,
        {BackgroundTransparency = 0.1, TextTransparency = 0},
        EASE_SINE,
        DIR_OUT
    )
    twPlay(floatingStroke, 0.45, {Transparency = 0}, EASE_SINE, DIR_OUT)
    local config = Utils.getConfig()
    local clashX = config.ClashBallX or 14
    local clashY = config.ClashBallY or (viewport().Y / 2 - CLASH_SIZE / 2)
    clashBall =
        inst(
        "TextButton",
        {
            Name = "ExodusClashBall",
            Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
            Position = UDim2.new(0, OFFSCREEN_X, 0.5, -CLASH_SIZE / 2),
            BackgroundColor3 = C.red,
            Text = "OFF",
            TextColor3 = Color3.new(1, 1, 1),
            TextSize = 16,
            Font = Enum.Font.GothamBold,
            Active = true,
            ZIndex = 8,
            Parent = screenGui
        }
    )
    corner(clashBall, 999)
    stroke(clashBall, Color3.new(0, 0, 0), 2)
    UIState.clashBallOn = config.AutoClash or false
    clashBall.Text = UIState.clashBallOn and "ON" or "OFF"
    clashBall.TextSize = UIState.clashBallOn and 18 or 16
    clashBall.BackgroundColor3 = UIState.clashBallOn and C.green or C.red
    UIState.btnIsDragging =
        makeDraggable(
        floatingButton,
        floatingButton,
        function()
            local currentConfig = Utils.getConfig()
            currentConfig.BtnX = floatingButton.Position.X.Offset
            currentConfig.BtnY = floatingButton.Position.Y.Offset
            Utils.setConfig(currentConfig)
        end
    )
    trackConn(floatingButton.Activated:Connect(
        function()
            if UIState.btnIsDragging() then
                return
            end
            togglePanel()
        end
    ))
    makeDraggable(
        clashBall,
        clashBall,
        function()
            local currentConfig = Utils.getConfig()
            currentConfig.ClashBallX = clashBall.Position.X.Offset
            currentConfig.ClashBallY = clashBall.Position.Y.Offset
            Utils.setConfig(currentConfig)
        end
    )
    trackConn(clashBall.Activated:Connect(
        function()
            setClashBall(not UIState.clashBallOn)
            syncAutoClashToggle()
        end
    ))
    local miniX = config.MiniX or (viewport().X - MINI_W - 14)
    local miniY = config.MiniY or (viewport().Y / 2 - MINI_H / 2)
    local MINI_OFF_X = viewport().X + 30
    miniGui =
        inst(
        "Frame",
        {
            Name = "ExodusSpamMini",
            Size = UDim2.new(0, MINI_W, 0, MINI_H),
            BackgroundColor3 = C.header,
            BorderSizePixel = 0,
            ZIndex = 15,
            Parent = screenGui
        }
    )
    corner(miniGui, 14)
    local miniGlow =
        inst(
        "Frame",
        {
            Size = UDim2.new(1, 8, 1, 8),
            Position = UDim2.new(0, -4, 0, -4),
            BackgroundColor3 = C.accent,
            BackgroundTransparency = 0.92,
            BorderSizePixel = 0,
            ZIndex = 14,
            Parent = miniGui
        }
    )
    corner(miniGlow, 18)
    registerFlow(stroke(miniGui, C.accent, 1.5))
    local miniTitleBar =
        inst(
        "Frame",
        {
            Size = UDim2.new(1, 0, 0, 26),
            BackgroundColor3 = Color3.fromRGB(20, 20, 46),
            BackgroundTransparency = 0.05,
            BorderSizePixel = 0,
            ZIndex = 16,
            Parent = miniGui
        }
    )
    corner(miniTitleBar, 14)
    inst(
        "Frame",
        {
            Size = UDim2.new(1, 0, 0, 12),
            Position = UDim2.new(0, 0, 1, -12),
            BackgroundColor3 = Color3.fromRGB(20, 20, 46),
            BackgroundTransparency = 0.05,
            BorderSizePixel = 0,
            ZIndex = 16,
            Parent = miniTitleBar
        }
    )
    local miniAccent =
        inst(
        "Frame",
        {
            Size = UDim2.new(0.5, 0, 0, 2),
            Position = UDim2.new(0.25, 0, 0, 0),
            BackgroundColor3 = C.accentPink,
            BorderSizePixel = 0,
            ZIndex = 17,
            Parent = miniTitleBar
        }
    )
    corner(miniAccent, 1)
    inst(
        "TextLabel",
        {
            Size = UDim2.new(1, -16, 1, 0),
            Position = UDim2.new(0, 8, 0, 0),
            BackgroundTransparency = 1,
            Text = "Spam",
            TextColor3 = C.subtext,
            TextScaled = true,
            TextXAlignment = Enum.TextXAlignment.Center,
            Font = Enum.Font.GothamBold,
            ZIndex = 17,
            Parent = miniTitleBar
        }
    )
    local spamBtn =
        inst(
        "TextButton",
        {
            Name = "SpamButton",
            Size = UDim2.new(1, -16, 0, 48),
            Position = UDim2.new(0, 8, 0, 32),
            BackgroundColor3 = C.red,
            BorderSizePixel = 0,
            Text = "OFF",
            TextColor3 = Color3.new(1, 1, 1),
            TextSize = 24,
            Font = Enum.Font.GothamBold,
            ZIndex = 16,
            Parent = miniGui
        }
    )
    corner(spamBtn, 10)
    trackConn(spamBtn.Activated:Connect(
        function()
            setSpam(not UIState.spamOn)
        end
    ))
    miniGui.Position = UDim2.new(0, MINI_OFF_X, 0, miniY)
    makeDraggable(
        miniTitleBar,
        miniGui,
        function()
            local currentConfig = Utils.getConfig()
            currentConfig.MiniX = miniGui.Position.X.Offset
            currentConfig.MiniY = miniGui.Position.Y.Offset
            Utils.setConfig(currentConfig)
        end
    )
    configPanel =
        inst(
        "Frame",
        {
            Name = "ExodusPanel",
            Size = UDim2.new(0, PW, 0, PH),
            Position = panelPos(),
            BackgroundColor3 = C.bg,
            BackgroundTransparency = 0.08,
            Visible = false,
            ZIndex = 5,
            ClipsDescendants = true,
            Parent = screenGui
        }
    )
    corner(configPanel, 16)
    stroke(configPanel, C.accent, 1.5)
    particleLayer =
        inst(
        "Frame",
        {
            Name = "ParticleLayer",
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            ZIndex = 4,
            ClipsDescendants = true,
            Parent = configPanel
        }
    )
    _spawn(
        function()
            while configPanel and configPanel.Parent do
                _wait(math.random() * 0.6 + 0.15)
                if configPanel and configPanel.Parent and configPanel.Visible then
                    spawnParticle()
                end
            end
        end
    )
    titleBar =
        inst(
        "Frame",
        {
            Size = UDim2.new(1, 0, 0, TITLE_H),
            BackgroundColor3 = C.header,
            Active = true,
            ZIndex = 6,
            Parent = configPanel
        }
    )
    corner(titleBar, 16)
    makeDraggable(
        titleBar,
        configPanel,
        function()
            local currentConfig = Utils.getConfig()
            currentConfig.PanelX = configPanel.Position.X.Offset
            currentConfig.PanelY = configPanel.Position.Y.Offset
            Utils.setConfig(currentConfig)
        end
    )
    local titleGroup =
        inst(
        "Frame",
        {
            Size = UDim2.new(0, 280, 1, 0),
            Position = UDim2.new(0.5, -140, 0, 0),
            BackgroundTransparency = 1,
            ZIndex = 7,
            Parent = titleBar
        }
    )
    inst(
        "TextLabel",
        {
            Size = UDim2.new(1, -58, 1, 0),
            Position = UDim2.new(0, 0, 0, 0),
            BackgroundTransparency = 1,
            Text = ("%s - v%s"):format(Utils.name(), Utils.version()),
            TextColor3 = C.text,
            TextSize = 16,
            Font = Enum.Font.GothamBold,
            TextXAlignment = Enum.TextXAlignment.Right,
            ZIndex = 7,
            Parent = titleGroup
        }
    )
    inst(
        "TextLabel",
        {
            Size = UDim2.new(0, 58, 1, 0),
            Position = UDim2.new(1, -58, 0, 0),
            BackgroundTransparency = 1,
            Text = "  " .. Utils.author(),
            TextColor3 = C.subtext,
            TextTransparency = 0.35,
            TextSize = 10,
            Font = Enum.Font.Gotham,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 7,
            Parent = titleGroup
        }
    )
    closeButton =
        inst(
        "TextButton",
        {
            Size = UDim2.new(0, 30, 0, 30),
            Position = UDim2.new(1, -PAD - 30, 0.5, -15),
            BackgroundColor3 = C.red,
            BackgroundTransparency = 0.3,
            Text = "X",
            TextColor3 = Color3.new(1, 1, 1),
            TextSize = 14,
            Font = Enum.Font.GothamBold,
            ZIndex = 7,
            Parent = titleBar
        }
    )
    corner(closeButton, 8)
    trackConn(closeButton.MouseEnter:Connect(
        function()
            twPlay(closeButton, 0.12, {BackgroundTransparency = 0})
        end
    ))
    trackConn(closeButton.MouseLeave:Connect(
        function()
            twPlay(closeButton, 0.12, {BackgroundTransparency = 0.3})
        end
    ))
    trackConn(closeButton.Activated:Connect(togglePanel))
    colLeft =
        inst(
        "Frame",
        {
            Size = UDim2.new(0, COL_W, 0, CONTENT_H),
            Position = UDim2.new(0, PAD, 0, TITLE_H + PAD),
            BackgroundTransparency = 1,
            ZIndex = 6,
            Parent = configPanel
        }
    )
    colRight =
        inst(
        "Frame",
        {
            Size = UDim2.new(0, COL_W, 0, CONTENT_H),
            Position = UDim2.new(0, PAD + COL_W + GAP, 0, TITLE_H + PAD),
            BackgroundTransparency = 1,
            ZIndex = 6,
            Parent = configPanel
        }
    )
    killBtn =
        inst(
        "TextButton",
        {
            Size = UDim2.new(0, 124, 0, 26),
            Position = UDim2.new(0.5, -62, 1, -PAD - 26),
            BackgroundColor3 = C.redDark,
            BackgroundTransparency = 0.15,
            Text = "Fechar Script",
            TextColor3 = Color3.fromRGB(255, 200, 200),
            TextSize = 11,
            Font = Enum.Font.GothamBold,
            ZIndex = 7,
            Parent = configPanel
        }
    )
    corner(killBtn, 6)
    trackConn(killBtn.Activated:Connect(
        function()
            Utils.stop()
            cleanupUI()
        end
    ))
    local yL = math.floor(math.max(0, (CONTENT_H - LEFT_STACK_H) / 2))
    yL = createToggleCard("Auto Parry", "AutoParry", yL, colLeft)
    local function buildAutoClash(y)
        local f = cardFrame(y, CARD_H, colLeft)
        inst("TextLabel", {Size = UDim2.new(1, -INNER_PAD * 2 - 48 - CONTROL_GAP, 1, 0), Position = UDim2.new(0, INNER_PAD, 0, 0), BackgroundTransparency = 1, Text = "Auto Clash", TextColor3 = C.text, TextSize = 14, Font = Enum.Font.GothamSemibold, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 7, Parent = f})
        local track, thumb, setVisual = makeToggle(f, config.AutoClash)
        autoClashTrack, autoClashThumb = track, thumb
        trackConn(inst("TextButton", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 9, Parent = f}).Activated:Connect(function()
            config.AutoClash = not config.AutoClash
            Utils.setConfig(config)
            setVisual(config.AutoClash)
            setClashBall(config.AutoClash, true)
            paintClashBall()
        end))
        return y + CARD_H + CARD_GAP
    end
    yL = buildAutoClash(yL)
    yL = createToggleCard("Mini Clash UI", "ClashBallVisible", yL, colLeft, function(v)
        showClashBall(v)
    end)
    local yR = math.floor(math.max(0, (CONTENT_H - RIGHT_STACK_H) / 2))
    yR = createRateSelector(yR, colRight)
    yR = createKeybindSelector(yR, colRight)
    yR = createSpamCard(yR, colRight)
    if config.ClashBallVisible then
        clashBall.Position = UDim2.new(0, clashX, 0, clashY)
    end
    setSpam(Utils.isManualSpamActive())
    return true
end
return ExodusUI
