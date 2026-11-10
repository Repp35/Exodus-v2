-- [[ ui ]]

-- services
local ExodusUI = {}
local Utils
local UIConfig
local GameInfo
local AutoSpam
local AutoParry
local Controls: any = {}
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
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
	pageGeneration = 0,
	pageTweens = {},
}

local setSpam
local screenGui
local floatingButton
local clashBall
local parryBall
local darkBall
local jumpBall
local upDashBall
local miniGui
local configPanel
local particleLayer
local titleBar
local closeButton
local colLeft
local colRight
local killBtn
local flowingTweens = {}

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
	darkOn = Color3.fromRGB(151, 66, 221),
	darkOff = Color3.fromRGB(52, 34, 87),
	jumpOn = Color3.fromRGB(16, 154, 201),
	jumpOff = Color3.fromRGB(24, 72, 105),
	upDash = Color3.fromRGB(226, 135, 36),
	hold = Color3.fromRGB(236, 72, 153),
	inputBg = Color3.fromRGB(16, 16, 38),
}

local GRAD = {
	Color3.fromRGB(56, 189, 248),
	Color3.fromRGB(139, 92, 246),
	Color3.fromRGB(236, 72, 153),
}

local EASE_OUT, EASE_SINE = Enum.EasingStyle.Cubic, Enum.EasingStyle.Sine
local DIR_OUT, DIR_IN, DIR_INOUT = Enum.EasingDirection.Out, Enum.EasingDirection.In, Enum.EasingDirection.InOut

-- helpers
local function inst(cls, props, parent)
	local o = Instance.new(cls)
	if props then
		for k, v in pairs(props) do
			o[k] = v
		end
	end
	if parent then o.Parent = parent end
	return o
end
local function corner(obj, r) return inst("UICorner", { CornerRadius = UDim.new(0, r) }, obj) end
local function stroke(obj, col, th) return inst("UIStroke", { Color = col, Thickness = th or 1 }, obj) end

-- animation
local function attachFlow(s)
	local g = inst("UIGradient", { Rotation = 0 }, s)
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, GRAD[1]),
		ColorSequenceKeypoint.new(0.5, GRAD[2]),
		ColorSequenceKeypoint.new(1, GRAD[3]),
	})
	return g
end
local function twPlay(obj, t, props, style, dir)
	if not obj or obj.Parent == nil then return nil end
	local tween = TweenService:Create(obj, TweenInfo.new(t, style or EASE_OUT, dir or DIR_OUT), props); tween:Play(); return tween
end

-- safety
local function safeCancel(t)
	if t then t:Cancel() end
end

-- layout
local function viewport()
	local currentCamera = workspace.CurrentCamera or Camera; return currentCamera and currentCamera.ViewportSize or Vector2.new(1920, 1080)
end
local function setConfigValue(key, value) return Utils.setConfig({ [key] = value }) end

-- connections
local function trackConn(c)
	if c and type(c.Disconnect) == "function" then UIState.connections[#UIState.connections + 1] = c end
	return c
end
local function safe(fn, ...) return fn(...) end
local function untrackConn(c)
	for i = #UIState.connections, 1, -1 do
		if UIState.connections[i] == c then table.remove(UIState.connections, i); return end
	end
end
local function safeDisconnect(c)
	if c then safe(function() c:Disconnect() end) end
end
local function disconnectUIConnections()
	for i = #UIState.connections, 1, -1 do
		safeDisconnect(UIState.connections[i]); UIState.connections[i] = nil
	end
end
local function isKey(input, keyCode) return input and keyCode and input.KeyCode == keyCode end

-- input
local function bindInput()
	trackConn(UIS.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		local config = Utils.getConfig() or {}; local panicKey = config.Keybind; local spamKey = config.SpamKeybind
		if isKey(input, panicKey) then
			setSpam(false)
			if type(Controls.onPanic) == "function" then safe(Controls.onPanic) end
		elseif isKey(input, spamKey) then
			setSpam(not UIState.spamOn)
		end
	end))
end

-- drag
local function makeDraggable(handle, target, onDragEnd, disableOnMobile)
	local dragInput, dragOffX, dragOffY = nil, 0, 0; local state, wasDragged, startX, startY = "Idle", false, 0, 0; local THRESH_SQ = 100
	trackConn(handle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
		if disableOnMobile and UIS.TouchEnabled then return end
		if state ~= "Idle" then return end
		state, wasDragged, dragInput = "Pressed", false, input; local abs = target.AbsolutePosition; dragOffX, dragOffY = input.Position.X - abs.X, input.Position.Y - abs.Y; startX, startY = input.Position.X, input.Position.Y
	end))
	trackConn(UIS.InputChanged:Connect(function(input)
		if state == "Idle" or not dragInput then return end
		local isMouseDrag = dragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement; local isTouchDrag = dragInput.UserInputType == Enum.UserInputType.Touch and input == dragInput
		if not isMouseDrag and not isTouchDrag then return end
		local dx, dy = input.Position.X - startX, input.Position.Y - startY
		if state == "Pressed" and (dx * dx + dy * dy) >= THRESH_SQ then state, wasDragged = "Dragging", true end
		if state == "Dragging" then
			local vp, sz = viewport(), target.AbsoluteSize
			target.Position = UDim2.new(
				0,
				math.clamp(input.Position.X - dragOffX, 0, math.max(0, vp.X - sz.X)),
				0,
				math.clamp(input.Position.Y - dragOffY, 0, math.max(0, vp.Y - sz.Y))
			)
		end
	end))
	trackConn(UIS.InputEnded:Connect(function(input)
		if input ~= dragInput or state == "Idle" then return end
		state, dragInput = "Idle", nil
		if wasDragged and onDragEnd then safe(onDragEnd) end
		wasDragged = false
	end))
	return function() return state == "Dragging" end
end

-- effects
local function registerFlow(obj)
	local gradient = attachFlow(obj); local tween = TweenService:Create(gradient, TweenInfo.new(12, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 }); flowingTweens[#flowingTweens + 1] = tween; tween:Play()
end
local BTN_SIZE = 56
local function btnPos()
	local config = Utils.getConfig(); local x, y = config.BtnX, config.BtnY
	if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
	return UDim2.new(1, -70, 0.5, -28)
end
local CLASH_SIZE = 64
local OFFSCREEN_X = -CLASH_SIZE - 40
local autoClashTrack, autoClashThumb, autoParrySetVisual, autoDarkSetVisual, autoJumpSetVisual
local function paintParryBall(value)
	if not parryBall or not parryBall.Parent then return end
	parryBall.Text = value and "PARRY\nON" or "PARRY\nOFF"; parryBall.TextSize = 14; twPlay(parryBall, 0.28, { BackgroundColor3 = value and C.green or C.red }, EASE_SINE, DIR_INOUT)
end
local function showParryBall(value)
	setConfigValue("ParryBallVisible", value); local config = Utils.getConfig(); local x = config.ParryBallX or 14; local y = config.ParryBallY or (viewport().Y / 2 - CLASH_SIZE - 40); twPlay(parryBall, value and 0.22 or 0.18, { Position = value and UDim2.new(0, x, 0, y) or UDim2.new(0, OFFSCREEN_X, 0, y) }, EASE_OUT, DIR_OUT)
end
local function paintClashBall()
	if not clashBall or not clashBall.Parent then return end
	twPlay(clashBall, 0.28, { BackgroundColor3 = UIState.clashBallOn and C.green or C.red }, EASE_SINE, DIR_INOUT); clashBall.Text = UIState.clashBallOn and "ON" or "OFF"; clashBall.TextSize = UIState.clashBallOn and 18 or 16
end
local function syncAutoSpamToggle()
	if not (autoClashTrack and autoClashThumb) then return end
	local v = UIState.clashBallOn; twPlay(autoClashTrack, 0.22, { BackgroundColor3 = v and C.toggleOn or C.toggleOff }, EASE_SINE, DIR_INOUT); twPlay(autoClashThumb, 0.32, { Position = v and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10) }, EASE_OUT, DIR_OUT)
end
local function setClashBall(v, silent)
	UIState.clashBallOn = v; setConfigValue("AutoSpam", v)
	if silent then return end
	paintClashBall(); twPlay(clashBall, 0.08, { Size = UDim2.new(0, CLASH_SIZE - 6, 0, CLASH_SIZE - 6) }, EASE_SINE, DIR_OUT)
	task.delay(0.08, function() twPlay(clashBall, 0.28, { Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE) }, EASE_OUT, DIR_OUT) end)
end
local function showClashBall(v)
	setConfigValue("ClashBallVisible", v); local config = Utils.getConfig(); local clashX = config.ClashBallX or 14; local clashY = config.ClashBallY or (viewport().Y / 2 - CLASH_SIZE / 2); twPlay(clashBall, (v and 0.22) or 0.18, { Position = v and UDim2.new(0, clashX, 0, clashY) or UDim2.new(0, OFFSCREEN_X, 0, clashY) }, EASE_OUT, DIR_OUT)
end
local function paintDarkBall(v)
	if not darkBall or not darkBall.Parent then return end
	twPlay(darkBall, 0.28, { BackgroundColor3 = v and C.darkOn or C.darkOff }, EASE_SINE, DIR_INOUT); darkBall.Text = v and "ON" or "OFF"; darkBall.TextSize = v and 18 or 16
end
local function showDarkBall(v)
	setConfigValue("DarkBallVisible", v); local config = Utils.getConfig(); local x = config.DarkBallX or 14; local y = config.DarkBallY or (viewport().Y / 2 + CLASH_SIZE / 2 + 8); twPlay(darkBall, v and 0.22 or 0.18, { Position = v and UDim2.new(0, x, 0, y) or UDim2.new(0, OFFSCREEN_X, 0, y) }, EASE_OUT, DIR_OUT)
end
local function setDarkBall(v)
	if not setConfigValue("AutoDark", v) then return end
	if type(Controls.onAutoDarkChanged) == "function" then Controls.onAutoDarkChanged() end
	paintDarkBall(v)
	if autoDarkSetVisual then autoDarkSetVisual(v) end
	twPlay(darkBall, 0.08, { Size = UDim2.new(0, CLASH_SIZE - 6, 0, CLASH_SIZE - 6) }, EASE_SINE, DIR_OUT)
	task.delay(0.08, function() twPlay(darkBall, 0.28, { Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE) }, EASE_OUT, DIR_OUT) end)
end
local function showMovementBall(ball, visible, visibleKey, xKey, yKey, yOffset)
	setConfigValue(visibleKey, visible); local config = Utils.getConfig(); local x = config[xKey] or (CLASH_SIZE + 22); local y = config[yKey] or (viewport().Y / 2 + yOffset); twPlay(ball, visible and 0.22 or 0.18, { Position = visible and UDim2.new(0, x, 0, y) or UDim2.new(0, OFFSCREEN_X, 0, y) }, EASE_OUT, DIR_OUT)
end
local function showJumpBall(v) showMovementBall(jumpBall, v, "JumpBallVisible", "JumpBallX", "JumpBallY", -CLASH_SIZE / 2) end
local function showUpDashBall(v) showMovementBall(upDashBall, v, "UpDashBallVisible", "UpDashBallX", "UpDashBallY", CLASH_SIZE / 2 + 8) end
local function paintJumpBall(v)
	if autoJumpSetVisual then autoJumpSetVisual(v) end
	if jumpBall and jumpBall.Parent then jumpBall.Text = v and "JUMP\nON" or "JUMP\nOFF"; twPlay(jumpBall, 0.2, { BackgroundColor3 = v and C.jumpOn or C.jumpOff }, EASE_SINE, DIR_INOUT) end
end
local function setJumpBall(v)
	if not setConfigValue("AutoJump", v) then return end
	if type(Controls.onAutoJumpChanged) == "function" then Controls.onAutoJumpChanged() end
	paintJumpBall(v)
end
local MINI_W, MINI_H = 120, 90
local function showMini(v, visBtn)
	setConfigValue("MiniSpamVisible", v); local config = Utils.getConfig(); local miniX = config.MiniX or (viewport().X - MINI_W - 14); local miniY = config.MiniY or (viewport().Y / 2 - MINI_H / 2); local MINI_OFF_X = viewport().X + 30; miniGui.Visible = v == true
	if v then twPlay(miniGui, 0.22, { Position = UDim2.new(0, miniX, 0, miniY) }, EASE_OUT, DIR_OUT) else miniGui.Position = UDim2.new(0, MINI_OFF_X, 0, miniY) end
	if visBtn and visBtn.Parent then visBtn.Text = v and "Mini UI: Visivel" or "Mini UI: Oculto"; twPlay(visBtn, 0.15, { BackgroundColor3 = v and Color3.fromRGB(0, 130, 65) or C.btnDark }) end
end
setSpam = function(v)
	UIState.spamOn = v; Utils.setManualSpamActive(v)
	if not miniGui or not miniGui.Parent then return end
	local spamBtn = miniGui:FindFirstChild("SpamButton")
	if spamBtn then
		spamBtn.Text = v and "ON" or "OFF"; twPlay(spamBtn, 0.25, { BackgroundColor3 = v and C.green or C.red }, EASE_SINE, DIR_INOUT); twPlay(spamBtn, 0.08, { Size = UDim2.new(1, -22, 0, 44) }, EASE_SINE, DIR_OUT)
		task.delay(0.08, function() twPlay(spamBtn, 0.28, { Size = UDim2.new(1, -16, 0, 48) }, EASE_OUT, DIR_OUT) end)
	end
end
local PW, PH = 540, 380
local TITLE_H, PAD, GAP, CARD_GAP = 50, 14, 12, 8
local INNER_PAD, CARD_H, RATE_CARD_H, SPAM_CARD_H = 14, 52, 68, 118
local CONTENT_H = PH - TITLE_H - 60
local COL_W = math.floor((PW - PAD * 2 - GAP) / 2)
local function nextCardY(yPos, cardHeight) return yPos + cardHeight + CARD_GAP end

-- panel
local function panelPos()
	local config = Utils.getConfig(); local x, y = config.PanelX, config.PanelY
	if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
	return UDim2.new(0.5, -PW / 2, 0.5, -PH / 2)
end
local PARTICLE_COLORS = {
	Color3.fromRGB(85, 90, 140),
	Color3.fromRGB(110, 95, 150),
	Color3.fromRGB(150, 95, 130),
	Color3.fromRGB(95, 130, 165),
}

-- cleanup
local function cleanupUI()
	safeCancel(UIState.panelTween); safeCancel(UIState.btnTween); disconnectUIConnections(); UIState.connections = {}; UIState.pageGeneration += 1
	for _, tween in ipairs(UIState.pageTweens) do
		safeCancel(tween)
	end
	UIState.pageTweens = {}; UIState.panelOpen = false; UIState.clashBallOn = false; UIState.panelTween = nil; UIState.btnTween = nil
	UIState.btnIsDragging = function() return false end
	for i = #flowingTweens, 1, -1 do
		safeCancel(flowingTweens[i]); flowingTweens[i] = nil
	end
	local current = screenGui
	if current then current:Destroy() end
	local overlay = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if overlay then
		local oldOverlay = overlay:FindFirstChild("ExodusInformationOverlay")
		if oldOverlay then oldOverlay:Destroy() end
	end
	screenGui = nil; floatingButton = nil; clashBall = nil; parryBall = nil; darkBall = nil; jumpBall = nil; upDashBall = nil; miniGui = nil; configPanel = nil; particleLayer = nil; titleBar = nil; closeButton = nil; colLeft = nil; colRight = nil; killBtn = nil; autoClashTrack = nil; autoClashThumb = nil; autoParrySetVisual = nil; autoDarkSetVisual = nil; autoJumpSetVisual = nil
	if _G.ExodusUICleanup == cleanupUI then _G.ExodusUICleanup = nil end
end

-- particles
local function spawnParticle()
	if not particleLayer or not particleLayer.Parent then return end
	local isFar = math.random() < 0.6; local size = isFar and math.random(2, 3) or math.random(4, 6); local startTrans = isFar and 0.5 or 0.2; local color = PARTICLE_COLORS[math.random(1, #PARTICLE_COLORS)]
	local dot = inst("Frame", {
		Size = UDim2.new(0, size, 0, size),
		Position = UDim2.new(math.random(), 0, 1, 0),
		BackgroundColor3 = color,
		BackgroundTransparency = startTrans,
		ZIndex = 4,
		Parent = particleLayer,
	})
	corner(dot, 999); local dur = isFar and math.random(5, 9) or math.random(3, 5); local endX = math.clamp(dot.Position.X.Scale + (math.random() - 0.5) * 0.15, 0, 1); twPlay(dot, 0.6, { BackgroundTransparency = math.max(startTrans - 0.1, 0.05) }, EASE_SINE, DIR_OUT); twPlay(dot, dur, { Position = UDim2.new(endX, 0, -0.1, 0), BackgroundTransparency = 1 }, EASE_SINE, DIR_INOUT)
	task.delay(dur + 0.2, function()
		if dot.Parent then dot:Destroy() end
	end)
end

-- cards
local function cardFrame(yPos, h, parent)
	local f = inst("Frame", {
		Size = UDim2.new(1, 0, 0, h),
		Position = UDim2.new(0, 0, 0, yPos),
		BackgroundColor3 = C.card,
		BackgroundTransparency = 0.1,
		ZIndex = 6,
		Parent = parent,
	})
	corner(f, 12); local s = stroke(f, C.border, 1)
	trackConn(f.MouseEnter:Connect(function()
		twPlay(s, 0.22, { Color = C.accent }, EASE_SINE, DIR_INOUT); twPlay(f, 0.22, { BackgroundColor3 = Color3.fromRGB(24, 24, 50) }, EASE_SINE, DIR_INOUT)
	end))
	trackConn(f.MouseLeave:Connect(function()
		twPlay(s, 0.25, { Color = C.border }, EASE_SINE, DIR_INOUT); twPlay(f, 0.25, { BackgroundColor3 = C.card }, EASE_SINE, DIR_INOUT)
	end))
	return f
end
local function cardLabel(text, parent)
	inst("TextLabel", {
		Size = UDim2.new(1, -10, 0, 16),
		Position = UDim2.new(0, 10, 0, 5),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = C.accent,
		TextSize = 10,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 7,
		Parent = parent,
	})
end
local function makeBtn(text, x, y, w, h, parent, bg)
	local b = inst("TextButton", {
		Size = UDim2.new(0, w, 0, h),
		Position = UDim2.new(0, x, 0, y),
		BackgroundColor3 = bg or C.btnBlue,
		BackgroundTransparency = 0.1,
		Text = text,
		TextColor3 = C.text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = parent,
	})
	corner(b, 8); return b
end
local function makeToggle(trackParent, initial)
	local track = inst("Frame", {
		Size = UDim2.new(0, 48, 0, 26),
		Position = UDim2.new(1, -INNER_PAD - 48, 0.5, -13),
		BackgroundColor3 = initial and C.toggleOn or C.toggleOff,
		BackgroundTransparency = 0.1,
		ZIndex = 7,
		Parent = trackParent,
	})
	corner(track, 999)
	local thumb = inst("Frame", {
		Size = UDim2.new(0, 20, 0, 20),
		Position = initial and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 8,
		Parent = track,
	})
	corner(thumb, 999)
	local function setVisual(v)
		twPlay(track, 0.22, { BackgroundColor3 = v and C.toggleOn or C.toggleOff }, EASE_SINE, DIR_INOUT); twPlay(thumb, 0.25, { Position = v and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10) }, EASE_SINE, DIR_INOUT)
	end
	return track, thumb, setVisual
end

-- keybind
local function bindKeyCapture(btn, onPicked)
	local listening = false
	trackConn(btn.Activated:Connect(function()
		if listening then return end
		listening = true; btn.Text = "..."; twPlay(btn, 0.1, { BackgroundColor3 = Color3.fromRGB(80, 85, 160) })
		local conn
		conn = trackConn(UIS.InputBegan:Connect(function(input, gpe)
			if gpe then return end
			if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
			safe(onPicked, input.KeyCode); listening = false; safeDisconnect(conn); untrackConn(conn)
		end))
	end))
end

-- cards
local function createToggleCard(labelText, configKey, yPos, parent, onAfter)
	local f = cardFrame(yPos, CARD_H, parent)
	inst("TextLabel", {
		Size = UDim2.new(0.55, 0, 1, 0),
		Position = UDim2.new(0, 14, 0, 0),
		BackgroundTransparency = 1,
		Text = labelText,
		TextColor3 = C.text,
		TextSize = (labelText == "Auto Deflexo Feroz" or labelText == "Distância do clash") and 11 or 14,
		Font = Enum.Font.GothamSemibold,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 7,
		Parent = f,
	})
	local config = Utils.getConfig(); local initial = configKey and config[configKey] or false; local toggleTrack, toggleThumb, setVisual = makeToggle(f, initial)
	if configKey == "AutoSpam" then autoClashTrack = toggleTrack; autoClashThumb = toggleThumb end
	if configKey == "AutoParry" then autoParrySetVisual = setVisual end
	if configKey == "AutoDark" then autoDarkSetVisual = setVisual end
	if configKey == "AutoJump" then autoJumpSetVisual = setVisual end
	trackConn(inst("TextButton", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 9,
		Parent = f,
	}).Activated:Connect(function()
		local current = Utils.getConfig(); local state = not (configKey and current[configKey] == true)
		if not configKey or setConfigValue(configKey, state) then
			setVisual(state)
			if onAfter then onAfter(state) end
		end
	end))
	return nextCardY(yPos, CARD_H), f
end
local function createActionToggleCard(labelText, yPos, parent, onToggle)
	local f = cardFrame(yPos, CARD_H, parent); cardLabel(labelText, f); local _, _, setVisual = makeToggle(f, false)
	trackConn(inst("TextButton", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 9,
		Parent = f,
	}).Activated:Connect(onToggle))
	return setVisual
end
local function createParryTimingCard(yPos, parent)
	local f = cardFrame(yPos, CARD_H, parent)
	inst("TextLabel", {
		Size = UDim2.new(1, -100, 1, 0),
		Position = UDim2.new(0, 14, 0, 0),
		BackgroundTransparency = 1,
		Text = "Antecipação AP (%)",
		TextColor3 = C.text,
		TextSize = 13,
		Font = Enum.Font.GothamSemibold,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 7,
		Parent = f,
	})
	local config = Utils.getConfig(); local initial = tonumber(config.AutoParryWindowFactor) or 0.4
	local input = inst("TextBox", {
		Size = UDim2.new(0, 62, 0, 30),
		Position = UDim2.new(1, -74, 0.5, -15),
		BackgroundColor3 = C.inputBg,
		BackgroundTransparency = 0.1,
		Text = tostring(math.clamp(initial, 0, 1) * 100),
		ClearTextOnFocus = false,
		TextColor3 = C.text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = f,
	})
	corner(input, 8); stroke(input, C.border, 1)
	trackConn(input.FocusLost:Connect(function()
		local value = tonumber(input.Text)
		if not value or value ~= value or value == math.huge or value == -math.huge then value = (tonumber(Utils.getConfig().AutoParryWindowFactor) or 0.4) * 100 end
		value = math.clamp(value, 0, 100); setConfigValue("AutoParryWindowFactor", value / 100); input.Text = tostring(value)
	end))
	return nextCardY(yPos, CARD_H)
end
local function createCameraSensitivityCard(yPos, parent)
	local f = cardFrame(yPos, CARD_H, parent); cardLabel("Sensibilidade da câmera", f)
	local input = inst("TextBox", {
		Size = UDim2.new(0, 62, 0, 30),
		Position = UDim2.new(1, -74, 0.5, -15),
		BackgroundColor3 = C.inputBg,
		Text = tostring(Utils.getConfigValue("CameraSensitivity") or 1),
		ClearTextOnFocus = false,
		TextColor3 = C.text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = f,
	})
	corner(input, 8); stroke(input, C.border, 1)
	trackConn(input.FocusLost:Connect(function()
		local value = tonumber(input.Text)
		if not value or value ~= value or value == math.huge or value == -math.huge or value < 0 then value = Utils.getConfigValue("CameraSensitivity") or 1 end
		setConfigValue("CameraSensitivity", value); input.Text = tostring(value)
	end))
	return nextCardY(yPos, CARD_H)
end
local function createRateSelector(yPos, parent)
	local f = cardFrame(yPos, RATE_CARD_H, parent); local config = Utils.getConfig(); config.CPS = Utils.normalizeSpamRate(config.CPS, 25.5); config.CPF = Utils.normalizeSpamRate(config.CPF, 0.3917); config.SpamRateMode = config.SpamRateMode == "Auto" and "Auto" or (config.SpamRateMode == "CPF" and "CPF" or "CPS")
	Utils.setConfig({
		CPS = config.CPS,
		CPF = config.CPF,
		SpamRateMode = config.SpamRateMode,
	})
	cardLabel("Taxa do Spam", f); local currentMode = config.SpamRateMode
	local modeTrack = inst("Frame", {
		Size = UDim2.new(0, 144, 0, 28),
		Position = UDim2.new(0, 12, 0, 32),
		BackgroundColor3 = C.inputBg,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 7,
		Parent = f,
	})
	corner(modeTrack, 999); stroke(modeTrack, C.border, 1)
	local modeThumb = inst("Frame", {
		Size = UDim2.new(0, 44, 0, 24),
		Position = UDim2.new(0, currentMode == "CPS" and 2 or (currentMode == "CPF" and 50 or 98), 0.5, -12),
		BackgroundColor3 = currentMode == "CPS" and C.accent or C.accentPink,
		BorderSizePixel = 0,
		ZIndex = 8,
		Parent = modeTrack,
	})
	corner(modeThumb, 999); stroke(modeThumb, C.text, 1); local modeButtons = {}
	for index, mode in ipairs({ "CPS", "CPF", "Auto" }) do
		local button = inst("TextButton", {
			Size = UDim2.new(0, 48, 1, 0),
			Position = UDim2.new(0, (index - 1) * 48, 0, 0),
			BackgroundTransparency = 1,
			Text = mode,
			TextColor3 = mode == currentMode and C.text or C.subtext,
			TextSize = 12,
			Font = Enum.Font.GothamBold,
			ZIndex = 9,
			Parent = modeTrack,
		})
		modeButtons[mode] = button
	end
	local inputBox = inst("TextBox", {
		Size = UDim2.new(0, 62, 0, 30),
		Position = UDim2.new(1, -74, 0, 31),
		BackgroundColor3 = C.inputBg,
		BackgroundTransparency = 0.1,
		Text = currentMode == "Auto" and "Auto" or tostring(config[currentMode]),
		TextEditable = currentMode ~= "Auto",
		PlaceholderText = "Taxa",
		ClearTextOnFocus = false,
		TextColor3 = C.text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = f,
	})
	corner(inputBox, 8); local inputStroke = stroke(inputBox, C.border, 1)
	local function paintRateMode(animated)
		local isCPS = currentMode == "CPS"; local targetPosition = UDim2.new(0, isCPS and 2 or (currentMode == "CPF" and 50 or 98), 0.5, -12); local duration = animated and 0.32 or 0
		twPlay(modeThumb, duration, {
			Position = targetPosition,
			BackgroundColor3 = isCPS and C.accent or C.accentPink,
		}, EASE_OUT, DIR_OUT)
		for mode, button in pairs(modeButtons) do
			twPlay(button, animated and 0.2 or 0, {
				TextColor3 = mode == currentMode and C.text or C.subtext,
			}, EASE_SINE, DIR_INOUT)
		end
	end
	local function selectRateMode(mode)
		if mode ~= "CPS" and mode ~= "CPF" and mode ~= "Auto" or currentMode == mode then return end
		currentMode = mode; config.SpamRateMode = mode; inputBox.TextEditable = mode ~= "Auto"; inputBox.Text = mode == "Auto" and "Auto" or tostring(config[mode]); setConfigValue("SpamRateMode", mode); paintRateMode(true)
	end
	for mode, button in pairs(modeButtons) do
		trackConn(button.Activated:Connect(function() selectRateMode(mode) end))
	end
	trackConn(inputBox.Focused:Connect(function() twPlay(inputStroke, 0.15, { Color = C.accent }) end))
	trackConn(inputBox.FocusLost:Connect(function()
		twPlay(inputStroke, 0.15, { Color = C.border })
		if currentMode == "Auto" then inputBox.Text = "Auto"; return end
		local value = tonumber(inputBox.Text); local key = currentMode; local fallback = config[key]; local normalized = Utils.normalizeSpamRate(value, fallback); setConfigValue(key, normalized); inputBox.Text = tostring(normalized)
	end))
	return nextCardY(yPos, RATE_CARD_H)
end
local function createKeybindSelector(yPos, parent)
	local f = cardFrame(yPos, CARD_H, parent)
	inst("TextLabel", {
		Size = UDim2.new(0.55, 0, 1, 0),
		Position = UDim2.new(0, 14, 0, 0),
		BackgroundTransparency = 1,
		Text = "Tecla de Atalho",
		TextColor3 = C.text,
		TextSize = 14,
		Font = Enum.Font.GothamSemibold,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 7,
		Parent = f,
	})
	local config = Utils.getConfig(); local kbBtn = makeBtn(config.Keybind and config.Keybind.Name or "V", 0, 0, 88, 30, f, C.btnBlue); kbBtn.Position = UDim2.new(1, -100, 0.5, -15)
	bindKeyCapture(kbBtn, function(keyCode)
		setConfigValue("Keybind", keyCode); kbBtn.Text = keyCode.Name; twPlay(kbBtn, 0.18, { BackgroundColor3 = C.btnBlue }, EASE_OUT)
	end)
	return nextCardY(yPos, CARD_H)
end
local function createSpamCard(yPos, parent)
	local f = cardFrame(yPos, SPAM_CARD_H, parent); cardLabel("Manual Spam", f); local visible = Utils.getConfigValue("MiniSpamVisible") == true; local visBtn = makeBtn(visible and "Mini UI: Visivel" or "Mini UI: Oculto", 8, 24, COL_W - 16, 30, f, visible and Color3.fromRGB(0, 130, 65) or C.btnDark); visBtn.TextSize = 11
	trackConn(visBtn.Activated:Connect(function() showMini(Utils.getConfigValue("MiniSpamVisible") ~= true, visBtn) end))
	local config = Utils.getConfig(); local kbBtn = makeBtn(config.SpamKeybind and config.SpamKeybind.Name or "X", 8, 64, COL_W - 16, 32, f, C.btnBlue)
	bindKeyCapture(kbBtn, function(keyCode)
		setConfigValue("SpamKeybind", keyCode); kbBtn.Text = keyCode.Name; twPlay(kbBtn, 0.18, { BackgroundColor3 = C.btnBlue }, EASE_OUT)
	end)
	return nextCardY(yPos, SPAM_CARD_H)
end
local function togglePanel()
	if not configPanel or not configPanel.Parent or not floatingButton or not floatingButton.Parent then return end
	UIState.panelOpen = not UIState.panelOpen; safeCancel(UIState.panelTween); safeCancel(UIState.btnTween)
	if UIState.panelOpen then
		if not configPanel.Visible then configPanel.GroupTransparency = 1; configPanel.Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97) end
		configPanel.Visible = true; UIState.panelTween = twPlay(configPanel, 0.28, { Size = UDim2.new(0, PW, 0, PH), GroupTransparency = 0 }, EASE_OUT, DIR_OUT); UIState.btnTween = twPlay(floatingButton, 0.2, { BackgroundTransparency = 0.6, TextTransparency = 0, Size = UDim2.new(0, 44, 0, 44) }, EASE_OUT, DIR_IN)
	else
		UIState.panelTween = twPlay(configPanel, 0.22, { Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97), GroupTransparency = 1 }, EASE_OUT, DIR_IN)
		UIState.btnTween =
			twPlay(floatingButton, 0.22, { BackgroundTransparency = 0.1, TextTransparency = 0, Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE) }, EASE_OUT, DIR_OUT)
		if UIState.panelTween then
			local conn
			conn = trackConn(UIState.panelTween.Completed:Connect(function()
				if not UIState.panelOpen then configPanel.Visible = false; configPanel.Size = UDim2.new(0, PW, 0, PH); configPanel.GroupTransparency = 0 end
				safeDisconnect(conn); untrackConn(conn)
			end))
		else
			configPanel.Visible = false; configPanel.Size = UDim2.new(0, PW, 0, PH); configPanel.GroupTransparency = 0
		end
	end
end

-- setup
function ExodusUI.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.Utils.getConfig) ~= "function"
		or type(deps.Utils.setConfig) ~= "function"
		or type(deps.Utils.normalizeSpamRate) ~= "function"
		or type(deps.Utils.isManualSpamActive) ~= "function"
		or type(deps.Utils.setManualSpamActive) ~= "function"
		or type(deps.Controls) ~= "table"
		or type(deps.Utils.stop) ~= "function"
		or type(deps.Utils.name) ~= "function"
		or type(deps.Utils.version) ~= "function"
		or type(deps.Utils.author) ~= "function"
		or type(deps.UIConfig) ~= "table"
		or type(deps.UIConfig.panelToggles) ~= "table"
		or type(deps.UIConfig.panelComponents) ~= "table"
		or type(deps.GameInfo) ~= "table"
		or type(deps.AutoSpam) ~= "table"
		or type(deps.AutoParry) ~= "table"
	then
		return false, "dependência ausente: Utils, Controls ou UIConfig"
	end
	Utils = deps.Utils; UIConfig = deps.UIConfig; GameInfo = deps.GameInfo; AutoSpam = deps.AutoSpam; AutoParry = deps.AutoParry; Controls = type(deps.Controls) == "table" and deps.Controls or {}; local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	if type(_G.ExodusUICleanup) == "function" then
		_G.ExodusUICleanup()
	else
		local old = playerGui:FindFirstChild("ExodusUISystem")
		if old then old:Destroy() end
	end
	UIState.panelOpen = false; UIState.spamOn = false; UIState.clashBallOn = false; UIState.panelTween = nil; UIState.btnTween = nil; _G.ExodusUICleanup = cleanupUI
	screenGui = inst("ScreenGui", {
		Name = "ExodusUISystem",
		DisplayOrder = 100,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	local informationGui = inst("ScreenGui", {
		Name = "ExodusInformationOverlay",
		DisplayOrder = 2147483647,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Global,
		Parent = playerGui,
	})
	local textService = game:GetService("TextService")
	local function compactInformation(label)
		local paddingX, paddingY = 8, 5; label.TextSize = 14; label.TextWrapped = false; label.TextXAlignment = Enum.TextXAlignment.Left; label.TextYAlignment = Enum.TextYAlignment.Top; label.BorderSizePixel = 0; label.ZIndex = 100
		local padding = inst("UIPadding", {
			PaddingLeft = UDim.new(0, paddingX),
			PaddingRight = UDim.new(0, paddingX),
			PaddingTop = UDim.new(0, paddingY),
			PaddingBottom = UDim.new(0, paddingY),
			Parent = label,
		})
		local function resize()
			local bounds = textService:GetTextSize(label.Text, label.TextSize, label.Font, Vector2.new(1000, 1000)); label.Size = UDim2.fromOffset(math.ceil(bounds.X) + paddingX * 2, math.ceil(bounds.Y) + paddingY * 2)
		end
		trackConn(label:GetPropertyChangedSignal("Text"):Connect(resize)); resize()
	end
	local distanceLabel = inst("TextLabel", {
		Name = "ClashDistance",
		Size = UDim2.fromOffset(1, 1),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		BackgroundColor3 = C.header,
		BackgroundTransparency = 0.2,
		Text = "SPD atual: —\nClash: —\nCPS: —",
		TextColor3 = C.text,
		TextSize = 14,
		Font = Enum.Font.GothamSemibold,
		Visible = Utils.getConfigValue("ClashDistanceVisible") == true,
		ZIndex = 20,
		Parent = informationGui,
	})
	local travelLabel = inst("TextLabel", {
		Name = "ClashTravelTime",
		Size = UDim2.fromOffset(1, 1),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		BackgroundColor3 = C.header,
		BackgroundTransparency = 0.2,
		Text = "Tempo da bola: —",
		TextColor3 = C.text,
		TextSize = 14,
		Font = Enum.Font.GothamSemibold,
		Visible = Utils.getConfigValue("ClashTravelTimeVisible") == true,
		ZIndex = 20,
		Parent = informationGui,
	})
	compactInformation(distanceLabel); compactInformation(travelLabel); corner(travelLabel, 8); local nextTravelUpdate = 0
	local apCpsLabel = inst("TextLabel", {
		Name = "AutoParryCps",
		Size = UDim2.fromOffset(1, 1),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		BackgroundColor3 = C.header,
		BackgroundTransparency = 0.2,
		Text = "CPS do AP: 0.00 | Fator: normal",
		TextColor3 = C.text,
		TextSize = 14,
		Font = Enum.Font.GothamSemibold,
		Visible = Utils.getConfigValue("AutoParryCpsVisible") == true,
		ZIndex = 20,
		Parent = informationGui,
	})
	compactInformation(apCpsLabel); corner(apCpsLabel, 8); local nextApCpsUpdate = 0
	trackConn(RunService.Heartbeat:Connect(function()
		if not apCpsLabel.Parent or os.clock() < nextApCpsUpdate then return end
		nextApCpsUpdate = os.clock() + 0.1; apCpsLabel.Visible = Utils.getConfigValue("AutoParryCpsVisible") == true
		if not apCpsLabel.Visible then return end
		local status = AutoParry.getCpsStatus(); apCpsLabel.Position = UDim2.new(0.5, 0, 0, distanceLabel.Visible and (distanceLabel.AbsoluteSize.Y + 12) or 12); apCpsLabel.Text = string.format("CPS do AP: %.2f | Fator: %s", status.cps, status.boosted and "1.0" or "normal")
	end))
	trackConn(RunService.Heartbeat:Connect(function()
		if not travelLabel.Parent then return end
		local visible = Utils.getConfigValue("ClashTravelTimeVisible") == true; travelLabel.Visible = visible; local time = os.clock()
		if not visible or time < nextTravelUpdate then return end
		nextTravelUpdate = time + 0.05; local status = AutoSpam.getStatus(); local stats = status and status.clashStats; local snapshot = GameInfo.getSnapshotAt(time)
		local speed
		if GameInfo.isSnapshotValid(snapshot) then
			speed = tonumber(snapshot.syncSpeed)
			if not speed or speed ~= speed or speed <= 0 or speed == math.huge then speed = snapshot.speed end
		end
		local speedText = type(speed) == "number" and speed == speed and speed >= 0 and speed < math.huge and string.format("%.0f", speed) or "—"
		if not stats then travelLabel.Text = "SPD atual: " .. speedText .. "\nTempo da bola: —"; return end
		local me = Players.LocalPlayer and Players.LocalPlayer.UserId
		if stats.frozen then
			if stats.deceasedId then
				local who = stats.deceasedId == me and "Você" or "Oponente"; local value = stats.fatalTravelTime and string.format("%.0f ms", stats.fatalTravelTime * 1000) or "indisponível"; local previousWho = stats.penultimateTarget == me and "você" or (stats.penultimateTarget == stats.partnerId and "oponente" or "—")
				local previous = stats.penultimateTravelTime and string.format("%.0f ms", stats.penultimateTravelTime * 1000) or "indisponível"; travelLabel.Text = who .. " morreu\nTarget até a morte: " .. value .. "\nPenúltimo (" .. previousWho .. "): " .. previous
			else
				travelLabel.Text = "Clash encerrado\nTempo final: indisponível"
			end
		else
			local value = stats.travelStartedAt and string.format("%.0f ms", math.max(0, time - stats.travelStartedAt) * 1000) or "—"; local who = stats.travelTarget == me and "Você" or (stats.travelTarget == stats.partnerId and "Oponente" or "—"); local last = stats.lastTravelTime and string.format("%.0f ms", stats.lastTravelTime * 1000) or "—"
			local lastWho = stats.lastTravelTarget == me and "você" or (stats.lastTravelTarget == stats.partnerId and "oponente" or "—"); travelLabel.Text = "Target: " .. who .. " | Tempo: " .. value .. "\nÚltima troca (" .. lastWho .. "): " .. last
		end
		travelLabel.Text = "SPD atual: " .. speedText .. "\n" .. travelLabel.Text
	end))
	corner(distanceLabel, 8); local nextDistanceUpdate = 0
	trackConn(RunService.Heartbeat:Connect(function()
		if not distanceLabel.Parent then return end
		local visible = Utils.getConfigValue("ClashDistanceVisible") == true; distanceLabel.Visible = visible; local time = os.clock()
		if not visible or time < nextDistanceUpdate then return end
		nextDistanceUpdate = time + 0.1; local status = AutoSpam.getStatus(); local stats = status and status.clashStats; local snapshot = GameInfo.getSnapshotAt(time)
		local currentSpeed
		if GameInfo.isSnapshotValid(snapshot) then
			currentSpeed = tonumber(snapshot.syncSpeed)
			if not currentSpeed or currentSpeed ~= currentSpeed or currentSpeed <= 0 or currentSpeed == math.huge then currentSpeed = snapshot.speed end
		end
		local speedText = type(currentSpeed) == "number" and currentSpeed == currentSpeed and currentSpeed < math.huge and string.format("%.0f", currentSpeed)
			or "—"
		if stats and (not stats.frozen or stats.endReason == "jogador morreu") then
			local function sampleText(sample)
				if not sample then return "—" end
				local distance = type(sample.distance) == "number" and string.format("%.1f", sample.distance) or "?"; local speed = type(sample.speed) == "number" and string.format("%.0f", sample.speed) or "?"; return distance .. " studs | SPD " .. speed
			end
			local cps = type(stats.currentCps) == "number" and string.format("%.2f", stats.currentCps) or "—"
			distanceLabel.Text = string.format(
				"SPD atual: %s\nInício: %s\n%s: %s\nCPS atual: %s | %.2fs",
				speedText,
				sampleText(stats.startSample),
				stats.frozen and (stats.endReason or "Fim") or "Atual",
				sampleText(stats.endSample),
				cps,
				stats.duration or 0
			)
		else
			distanceLabel.Text = "SPD atual: " .. speedText .. "\nClash: —\nCPS atual: —"
		end
	end))
	bindInput()
	floatingButton = inst("TextButton", {
		Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE),
		Position = btnPos(),
		BackgroundColor3 = C.header,
		BackgroundTransparency = 1,
		Text = "E",
		TextColor3 = C.text,
		TextTransparency = 1,
		TextSize = 26,
		Font = Enum.Font.GothamBold,
		Active = true,
		ZIndex = 10,
		Parent = screenGui,
	})
	corner(floatingButton, 999); local floatingStroke = stroke(floatingButton, C.accent, 2); floatingStroke.Transparency = 1; registerFlow(floatingStroke)
	task.defer(function()
		if not floatingButton or not floatingButton.Parent then return end
		twPlay(floatingButton, 0.38, { BackgroundTransparency = 0.1, TextTransparency = 0 }, EASE_OUT, DIR_OUT); twPlay(floatingStroke, 0.42, { Transparency = 0 }, EASE_OUT, DIR_OUT)
	end)
	local config = Utils.getConfig(); local clashX = config.ClashBallX or 14; local clashY = config.ClashBallY or (viewport().Y / 2 - CLASH_SIZE / 2)
	clashBall = inst("TextButton", {
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
		Parent = screenGui,
	})
	corner(clashBall, 999); stroke(clashBall, Color3.new(0, 0, 0), 2); UIState.clashBallOn = config.AutoSpam or false; clashBall.Text = UIState.clashBallOn and "ON" or "OFF"; clashBall.TextSize = UIState.clashBallOn and 18 or 16; clashBall.BackgroundColor3 = UIState.clashBallOn and C.green or C.red; local parryX = config.ParryBallX or 14
	local parryY = config.ParryBallY or (viewport().Y / 2 - CLASH_SIZE - 40)
	parryBall = inst("TextButton", {
		Name = "ExodusParryBall",
		Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
		Position = UDim2.new(0, OFFSCREEN_X, 0, parryY),
		BackgroundColor3 = config.AutoParry and C.green or C.red,
		Text = config.AutoParry and "PARRY\nON" or "PARRY\nOFF",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		Active = true,
		ZIndex = 8,
		Parent = screenGui,
	})
	corner(parryBall, 999); stroke(parryBall, Color3.new(0, 0, 0), 2)
	local isParryDragging = makeDraggable(parryBall, parryBall, function()
		setConfigValue("ParryBallX", parryBall.Position.X.Offset); setConfigValue("ParryBallY", parryBall.Position.Y.Offset)
	end)
	trackConn(parryBall.Activated:Connect(function()
		if not isParryDragging() then setConfigValue("AutoParry", Utils.getConfigValue("AutoParry") ~= true) end
	end))
	UIState.btnIsDragging = makeDraggable(floatingButton, floatingButton, function()
		setConfigValue("BtnX", floatingButton.Position.X.Offset); setConfigValue("BtnY", floatingButton.Position.Y.Offset)
	end)
	trackConn(floatingButton.Activated:Connect(function()
		if UIState.btnIsDragging() then return end
		togglePanel()
	end))
	makeDraggable(clashBall, clashBall, function()
		setConfigValue("ClashBallX", clashBall.Position.X.Offset); setConfigValue("ClashBallY", clashBall.Position.Y.Offset)
	end)
	trackConn(clashBall.Activated:Connect(function()
		setClashBall(not UIState.clashBallOn); syncAutoSpamToggle()
	end))
	local darkX = config.DarkBallX or 14; local darkY = config.DarkBallY or (viewport().Y / 2 + CLASH_SIZE / 2 + 8)
	darkBall = inst("TextButton", {
		Name = "ExodusDarkBall",
		Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
		Position = UDim2.new(0, OFFSCREEN_X, 0, darkY),
		BackgroundColor3 = config.AutoDark and C.darkOn or C.darkOff,
		Text = config.AutoDark and "ON" or "OFF",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = config.AutoDark and 18 or 16,
		Font = Enum.Font.GothamBold,
		Active = true,
		ZIndex = 8,
		Parent = screenGui,
	})
	corner(darkBall, 999); stroke(darkBall, Color3.new(0, 0, 0), 2)
	local isDarkDragging = makeDraggable(darkBall, darkBall, function()
		setConfigValue("DarkBallX", darkBall.Position.X.Offset); setConfigValue("DarkBallY", darkBall.Position.Y.Offset)
	end)
	trackConn(darkBall.Activated:Connect(function()
		if isDarkDragging() then return end
		setDarkBall(Utils.getConfigValue("AutoDark") ~= true)
	end))
	local function createMovementBall(name, text, color, xKey, yKey, yOffset, onClick)
		local x = config[xKey] or (CLASH_SIZE + 22); local y = config[yKey] or (viewport().Y / 2 + yOffset)
		local ball = inst("TextButton", {
			Name = name,
			Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
			Position = UDim2.new(0, OFFSCREEN_X, 0, y),
			BackgroundColor3 = color,
			Text = text,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 15,
			Font = Enum.Font.GothamBold,
			Active = true,
			ZIndex = 8,
			Parent = screenGui,
		})
		corner(ball, 999); stroke(ball, Color3.new(0, 0, 0), 2)
		local dragging = makeDraggable(ball, ball, function()
			setConfigValue(xKey, ball.Position.X.Offset); setConfigValue(yKey, ball.Position.Y.Offset)
		end)
		trackConn(ball.Activated:Connect(function()
			if not dragging() then onClick(ball) end
		end))
		return ball, x, y
	end
	local jumpX, jumpY, upDashX, upDashY
	jumpBall, jumpX, jumpY = createMovementBall(
		"ExodusJumpBall",
		config.AutoJump and "JUMP\nON" or "JUMP\nOFF",
		config.AutoJump and C.jumpOn or C.jumpOff,
		"JumpBallX",
		"JumpBallY",
		-CLASH_SIZE / 2,
		function() setJumpBall(Utils.getConfigValue("AutoJump") ~= true) end
	)
	upDashBall, upDashX, upDashY = createMovementBall(
		"ExodusUpDashBall",
		"DASH\n↑",
		C.upDash,
		"UpDashBallX",
		"UpDashBallY",
		CLASH_SIZE / 2 + 8,
		function(ball)
			if type(Controls.onUpDash) == "function" then Controls.onUpDash() end
			twPlay(ball, 0.08, { Size = UDim2.new(0, CLASH_SIZE - 6, 0, CLASH_SIZE - 6) }, EASE_SINE, DIR_OUT)
			task.delay(0.08, function() twPlay(ball, 0.28, { Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE) }, EASE_OUT, DIR_OUT) end)
		end
	)
	local miniY = config.MiniY or (viewport().Y / 2 - MINI_H / 2); local MINI_OFF_X = viewport().X + 30
	miniGui = inst("Frame", {
		Name = "ExodusSpamMini",
		Visible = config.MiniSpamVisible == true,
		Size = UDim2.new(0, MINI_W, 0, MINI_H),
		BackgroundColor3 = C.header,
		BorderSizePixel = 0,
		ZIndex = 15,
		Parent = screenGui,
	})
	corner(miniGui, 14)
	corner(
		inst("Frame", {
			Size = UDim2.new(1, 8, 1, 8),
			Position = UDim2.new(0, -4, 0, -4),
			BackgroundColor3 = C.accent,
			BackgroundTransparency = 0.92,
			BorderSizePixel = 0,
			ZIndex = 14,
			Parent = miniGui,
		}),
		18
	)
	registerFlow(stroke(miniGui, C.accent, 1.5))
	local miniTitleBar = inst("Frame", {
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Color3.fromRGB(20, 20, 46),
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 16,
		Parent = miniGui,
	})
	corner(miniTitleBar, 14)
	inst("Frame", {
		Size = UDim2.new(1, 0, 0, 12),
		Position = UDim2.new(0, 0, 1, -12),
		BackgroundColor3 = Color3.fromRGB(20, 20, 46),
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 16,
		Parent = miniTitleBar,
	})
	corner(
		inst("Frame", {
			Size = UDim2.new(0.5, 0, 0, 2),
			Position = UDim2.new(0.25, 0, 0, 0),
			BackgroundColor3 = C.accentPink,
			BorderSizePixel = 0,
			ZIndex = 17,
			Parent = miniTitleBar,
		}),
		1
	)
	inst("TextLabel", {
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.new(0, 8, 0, 0),
		BackgroundTransparency = 1,
		Text = "Spam",
		TextColor3 = C.subtext,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Enum.Font.GothamBold,
		ZIndex = 17,
		Parent = miniTitleBar,
	})
	local spamBtn = inst("TextButton", {
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
		Parent = miniGui,
	})
	corner(spamBtn, 10)
	trackConn(spamBtn.Activated:Connect(function() setSpam(not UIState.spamOn) end))
	miniGui.Position = UDim2.new(0, config.MiniSpamVisible and (config.MiniX or (viewport().X - MINI_W - 14)) or MINI_OFF_X, 0, miniY)
	makeDraggable(miniTitleBar, miniGui, function()
		setConfigValue("MiniX", miniGui.Position.X.Offset); setConfigValue("MiniY", miniGui.Position.Y.Offset)
	end)
	configPanel = inst("CanvasGroup", {
		Name = "ExodusPanel",
		Size = UDim2.new(0, PW, 0, PH),
		Position = panelPos(),
		BackgroundColor3 = C.bg,
		BackgroundTransparency = 0.08,
		GroupTransparency = 0,
		Visible = false,
		ZIndex = 5,
		ClipsDescendants = true,
		Parent = screenGui,
	})
	corner(configPanel, 16); stroke(configPanel, C.accent, 1.5)
	particleLayer = inst("Frame", {
		Name = "ParticleLayer",
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		ZIndex = 4,
		ClipsDescendants = true,
		Parent = configPanel,
	})
	local particlePanel = configPanel
	_spawn(function()
		while configPanel == particlePanel and particlePanel.Parent do
			_wait(math.random() * 0.6 + 0.15)
			if configPanel == particlePanel and particlePanel.Parent and particlePanel.Visible then spawnParticle() end
		end
	end)
	titleBar = inst("Frame", {
		Size = UDim2.new(1, 0, 0, TITLE_H),
		BackgroundColor3 = C.header,
		Active = true,
		ZIndex = 6,
		Parent = configPanel,
	})
	corner(titleBar, 16)
	makeDraggable(titleBar, configPanel, function()
		setConfigValue("PanelX", configPanel.Position.X.Offset); setConfigValue("PanelY", configPanel.Position.Y.Offset)
	end)
	local titleGroup = inst("Frame", {
		Size = UDim2.new(0, 280, 1, 0),
		Position = UDim2.new(0.5, -140, 0, 0),
		BackgroundTransparency = 1,
		ZIndex = 7,
		Parent = titleBar,
	})
	inst("TextLabel", {
		Size = UDim2.new(1, -58, 1, 0),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		Text = ("%s - v%s"):format(Utils.name(), Utils.version()),
		TextColor3 = C.text,
		TextSize = 16,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 7,
		Parent = titleGroup,
	})
	inst("TextLabel", {
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
		Parent = titleGroup,
	})
	closeButton = inst("TextButton", {
		Size = UDim2.new(0, 30, 0, 30),
		Position = UDim2.new(1, -PAD - 30, 0.5, -15),
		BackgroundColor3 = C.red,
		BackgroundTransparency = 0.3,
		Text = "X",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 14,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = titleBar,
	})
	corner(closeButton, 8)
	trackConn(closeButton.MouseEnter:Connect(function() twPlay(closeButton, 0.12, { BackgroundTransparency = 0 }) end))
	trackConn(closeButton.MouseLeave:Connect(function() twPlay(closeButton, 0.12, { BackgroundTransparency = 0.3 }) end))
	trackConn(closeButton.Activated:Connect(togglePanel)); local pageGroups = {}
	for index = 1, 4 do
		pageGroups[index] = inst("CanvasGroup", {
			Name = "Page" .. index,
			Size = UDim2.new(0, PW - PAD * 2, 0, CONTENT_H),
			Position = UDim2.new(0, PAD, 0, TITLE_H + PAD),
			BackgroundTransparency = 1,
			GroupTransparency = index == 1 and 0 or 1,
			Visible = index == 1,
			ClipsDescendants = true,
			ZIndex = 6,
			Parent = configPanel,
		})
	end
	colLeft = inst("ScrollingFrame", {
		Size = UDim2.new(0, COL_W, 0, CONTENT_H),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		ZIndex = 6,
		Parent = pageGroups[1],
	})
	colRight = inst("Frame", {
		Size = UDim2.new(0, COL_W, 0, CONTENT_H),
		Position = UDim2.new(0, COL_W + GAP, 0, 0),
		BackgroundTransparency = 1,
		ZIndex = 6,
		Parent = pageGroups[1],
	})
	killBtn = inst("TextButton", {
		Size = UDim2.new(0, 124, 0, 26),
		Position = UDim2.new(0.5, -62, 1, -PAD - 26),
		BackgroundColor3 = C.redDark,
		BackgroundTransparency = 0.15,
		Text = "Fechar Script",
		TextColor3 = Color3.fromRGB(255, 200, 200),
		TextSize = 11,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = configPanel,
	})
	corner(killBtn, 6)
	trackConn(killBtn.Activated:Connect(function() Utils.stop() end))
	local yL = 4
	local toggleCallbacks = {
		AutoParry = paintParryBall,
		ParryBallVisible = showParryBall,
		AutoSpam = function(value)
			setClashBall(value, true); paintClashBall()
		end,
		ClashBallVisible = showClashBall,
	}

	for _, definition in ipairs(UIConfig.panelToggles) do
		if definition.kind == "toggle" then yL = createToggleCard(definition.label, definition.key, yL, colLeft, toggleCallbacks[definition.key]) end
	end
	colLeft.CanvasSize = UDim2.new(0, 0, 0, yL); local yR = 4
	local components = {
		rate_selector = createRateSelector,
		keybind_selector = createKeybindSelector,
		manual_spam = createSpamCard,
	}

	for _, definition in ipairs(UIConfig.panelComponents) do
		local createComponent = components[definition.kind]
		if createComponent then yR = createComponent(yR, colRight) end
	end
	local settingsLeft = inst("Frame", {
		Size = UDim2.new(0, COL_W, 0, CONTENT_H),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		Visible = true,
		ZIndex = 6,
		Parent = pageGroups[2],
	})
	local settingsRight = inst("Frame", {
		Size = UDim2.new(0, COL_W, 0, CONTENT_H),
		Position = UDim2.new(0, COL_W + GAP, 0, 0),
		BackgroundTransparency = 1,
		Visible = true,
		ZIndex = 6,
		Parent = pageGroups[2],
	})
	local utilities = inst("Frame", {
		Size = UDim2.new(0, COL_W, 0, CONTENT_H),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		Visible = true,
		ZIndex = 6,
		Parent = pageGroups[3],
	})
	local autosLeft = inst("Frame", {
		Size = UDim2.new(0, COL_W, 0, CONTENT_H),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundTransparency = 1,
		ZIndex = 6,
		Parent = pageGroups[4],
	})
	local autosRight = inst("Frame", {
		Size = UDim2.new(0, COL_W, 0, CONTENT_H),
		Position = UDim2.new(0, COL_W + GAP, 0, 0),
		BackgroundTransparency = 1,
		Visible = true,
		ZIndex = 6,
		Parent = pageGroups[4],
	})
	local darkYPos, darkCard = createToggleCard("Auto Dark", "AutoDark", 4, autosLeft, function(value)
		paintDarkBall(value)
		if type(Controls.onAutoDarkChanged) == "function" then Controls.onAutoDarkChanged() end
	end)
	local fierceYPos, miniDarkCard = createToggleCard("Mini Dark UI", "DarkBallVisible", darkYPos, autosLeft, showDarkBall); local aimYPos, fierceCard = createToggleCard("Auto Fierce", "AutoFierce", fierceYPos, autosLeft); createToggleCard("Auto Aim Lock", "AutoAimLock", aimYPos, autosLeft)
	local jumpYPos = createToggleCard("Auto Jump", "AutoJump", 4, autosRight, function(value)
		paintJumpBall(value)
		if type(Controls.onAutoJumpChanged) == "function" then Controls.onAutoJumpChanged() end
	end)
	local dashYPos = createToggleCard("Mini Auto Jump", "JumpBallVisible", jumpYPos, autosRight, showJumpBall); local upDashYPos, upDashCard = createToggleCard("Mini Up Dash", "UpDashBallVisible", dashYPos, autosRight, showUpDashBall); local _, autoUpDashCard = createToggleCard("Auto Dash (clash)", "AutoClashUpDash", upDashYPos, autosRight); local parryYPos = createParryTimingCard(4, settingsLeft)
	createCameraSensitivityCard(parryYPos, settingsLeft); local travelYPos = createToggleCard("Distância do clash", "ClashDistanceVisible", 4, settingsRight); local apCpsYPos = createToggleCard("Tempo da bola", "ClashTravelTimeVisible", travelYPos, settingsRight); createToggleCard("CPS do AP flutuante", "AutoParryCpsVisible", apCpsYPos, settingsRight)
	local function updateAbilityVisibility(enabled)
		darkCard.Visible, miniDarkCard.Visible, upDashCard.Visible, fierceCard.Visible, autoUpDashCard.Visible = enabled, enabled, enabled, enabled, enabled
		darkBall.Visible, upDashBall.Visible = enabled, enabled
	end
	updateAbilityVisibility(GameInfo.areAbilitiesEnabled()); trackConn(GameInfo.observeAbilityMode(updateAbilityVisibility))

	-- anti-afk
	local antiConnection
	local antiGeneration = 0
	local paintAnti
	paintAnti = createActionToggleCard("Anti AFK", 0, utilities, function()
		if antiConnection then antiGeneration += 1; antiConnection:Disconnect(); untrackConn(antiConnection); antiConnection = nil; paintAnti(false); return end
		local player = Utils.getLocalPlayer(); local ok, virtualUser = pcall(game.GetService, game, "VirtualUser")
		if not player then Utils.recordError("AntiAFK", "Jogador indisponível"); return end
		local function pulse()
			local inputOk, err = pcall(function()
				if not ok or not virtualUser then error("VirtualUser indisponível") end
				virtualUser:CaptureController(); virtualUser:ClickButton2(Vector2.new(0, 0))
			end)
			if not inputOk then
				local fallback, fallbackErr = pcall(function()
					local vim = game:GetService("VirtualInputManager"); vim:SendMouseButtonEvent(0, 0, 1, true, game, 0); vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
				end)
				if not fallback then Utils.recordError("AntiAFK", tostring(err) .. " | " .. tostring(fallbackErr)) end
			end
		end
		antiConnection = trackConn(player.Idled:Connect(pulse)); antiGeneration += 1; local generation = antiGeneration
		task.spawn(function()
			while generation == antiGeneration and screenGui and screenGui.Parent and Utils.isActive() do
				task.wait(20)
				if generation == antiGeneration and screenGui and screenGui.Parent and Utils.isActive() then pulse() end
			end
		end)
		paintAnti(true)
	end)
	local spinActive, spinGeneration, spinButtons = nil, 0, {}; local spinModes = { { "Espada", "SwordCrate" }, { "Emote", "EmoteCrate" }, { "Explosão", "FinisherCrate" } }
	local function paintSpin()
		for _, mode in ipairs(spinModes) do
			if spinButtons[mode[2]] then spinButtons[mode[2]](spinActive == mode[2]) end
		end
	end
	for index, mode in ipairs(spinModes) do
		local crate = mode[2]
		spinButtons[crate] = createActionToggleCard(mode[1], CARD_H + 8 + (index - 1) * (CARD_H + 8), utilities, function()
			spinGeneration += 1
			if spinActive == crate then spinActive = nil else spinActive = crate end
			paintSpin()
			if not spinActive then return end
			local generation = spinGeneration
			task.spawn(function()
				local network = GameInfo.createCrateNetwork()
				if generation ~= spinGeneration or spinActive ~= crate then return end
				while generation == spinGeneration and spinActive == crate and screenGui and screenGui.Parent and Utils.isActive() do
					local sent = GameInfo.spinCrate(network, crate, function() return generation == spinGeneration and spinActive == crate end)
					if not sent then break end
					task.wait(0.3)
				end
			end)
		end)
	end
	local page = 1
	local pageInputShield = inst("TextButton", {
		Name = "PageInputShield",
		Size = UDim2.new(0, PW - PAD * 2, 0, CONTENT_H),
		Position = UDim2.new(0, PAD, 0, TITLE_H + PAD),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Visible = false,
		ZIndex = 20,
		Parent = configPanel,
	})
	local previous = inst("TextButton", {
		Name = "PreviousPage",
		Size = UDim2.new(0, 32, 0, 26),
		Position = UDim2.new(0, PAD, 1, -PAD - 26),
		BackgroundColor3 = C.btnDark,
		Text = "‹",
		TextColor3 = C.text,
		TextSize = 20,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = configPanel,
	})
	local pageLabel = inst("TextLabel", {
		Name = "PageLabel",
		Size = UDim2.new(0, 108, 0, 26),
		Position = UDim2.new(0, PAD + 34, 1, -PAD - 26),
		BackgroundTransparency = 1,
		Text = "1/4 Principal",
		TextColor3 = C.text,
		TextSize = 10,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = configPanel,
	})
	local nextPage = inst("TextButton", {
		Name = "NextPage",
		Size = UDim2.new(0, 32, 0, 26),
		Position = UDim2.new(0, PAD + 144, 1, -PAD - 26),
		BackgroundColor3 = C.btnDark,
		Text = "›",
		TextColor3 = C.text,
		TextSize = 20,
		Font = Enum.Font.GothamBold,
		ZIndex = 7,
		Parent = configPanel,
	})
	corner(previous, 6); corner(nextPage, 6); local pageNames = { "Principal", "Ajustes", "Utilidades", "Automáticos" }
	local function updateNavigation()
		pageLabel.Text = tostring(page) .. "/" .. tostring(#pageGroups) .. " " .. pageNames[page]; previous.TextTransparency = page == 1 and 0.65 or 0; nextPage.TextTransparency = page == #pageGroups and 0.65 or 0
	end
	updateNavigation()
	local function changePage(direction)
		local target = page + direction
		if target < 1 or target > #pageGroups then return end
		page = target; UIState.pageGeneration += 1; local generation = UIState.pageGeneration
		for _, tween in ipairs(UIState.pageTweens) do
			safeCancel(tween)
		end
		UIState.pageTweens = {}; pageInputShield.Visible = true; updateNavigation()
		local incoming
		for index, group in ipairs(pageGroups) do
			if index == page then
				if not group.Visible then group.Position = UDim2.new(0, PAD + 20 * direction, 0, TITLE_H + PAD); group.GroupTransparency = 1; group.Visible = true end
				incoming = twPlay(group, 0.28, { Position = UDim2.new(0, PAD, 0, TITLE_H + PAD), GroupTransparency = 0 }, EASE_OUT, DIR_INOUT)
				if incoming then UIState.pageTweens[#UIState.pageTweens + 1] = incoming end
			elseif group.Visible then
				local outgoing =
					twPlay(group, 0.28, { Position = UDim2.new(0, PAD - 20 * direction, 0, TITLE_H + PAD), GroupTransparency = 1 }, EASE_OUT, DIR_INOUT)
				if outgoing then UIState.pageTweens[#UIState.pageTweens + 1] = outgoing end
			end
		end
		local conn
		local function finish()
			if conn then safeDisconnect(conn); untrackConn(conn); conn = nil end
			if generation ~= UIState.pageGeneration or not pageInputShield.Parent then return end
			for index, group in ipairs(pageGroups) do
				group.Visible = index == page; group.GroupTransparency = index == page and 0 or 1; group.Position = UDim2.new(0, PAD, 0, TITLE_H + PAD)
			end
			UIState.pageTweens = {}; pageInputShield.Visible = false
		end
		if incoming then conn = trackConn(incoming.Completed:Connect(finish)); task.delay(0.5, finish) else finish() end
	end
	trackConn(previous.Activated:Connect(function() changePage(-1) end))
	trackConn(nextPage.Activated:Connect(function() changePage(1) end))
	if config.ClashBallVisible then clashBall.Position = UDim2.new(0, clashX, 0, clashY) end
	if config.ParryBallVisible then parryBall.Position = UDim2.new(0, parryX, 0, parryY) end
	if config.DarkBallVisible then darkBall.Position = UDim2.new(0, darkX, 0, darkY) end
	if config.JumpBallVisible then jumpBall.Position = UDim2.new(0, jumpX, 0, jumpY) end
	if config.UpDashBallVisible then upDashBall.Position = UDim2.new(0, upDashX, 0, upDashY) end
	if type(Utils.observeSpam) == "function" then
		trackConn(Utils.observeSpam(function()
			local manual = Utils.isManualSpamActive()
			if UIState.spamOn ~= manual then setSpam(manual) end
		end))
	end
	if type(Utils.observeConfig) == "function" then
		trackConn(Utils.observeConfig(function(changes)
			if changes.AutoSpam ~= nil then UIState.clashBallOn = changes.AutoSpam == true; paintClashBall(); syncAutoSpamToggle() end
			if changes.AutoParry ~= nil then
				paintParryBall(changes.AutoParry == true)
				if autoParrySetVisual then autoParrySetVisual(changes.AutoParry == true) end
			end
		end))
	end
	setSpam(Utils.isManualSpamActive()); return true
end

-- contract
ExodusUI.__contract = {
	requires = { Utils = "utils", UIConfig = "uiconfig", GameInfo = "gameinfo", AutoSpam = "autospam", AutoParry = "autoparry" },
	requiresMethods = {
		Utils = {
			"getConfig",
			"getConfigValue",
			"getLocalPlayer",
			"isActive",
			"isManualSpamActive",
			"setConfig",
			"setManualSpamActive",
			"normalizeSpamRate",
			"observeConfig",
			"observeSpam",
			"recordError",
			"stop",
			"name",
			"version",
			"author",
		},
		GameInfo = { "areAbilitiesEnabled", "observeAbilityMode", "getSnapshotAt", "isSnapshotValid", "createCrateNetwork", "spinCrate" },
		AutoSpam = { "getStatus" },
		AutoParry = { "getCpsStatus" },
	},

	provides = { "setup" },
}

return ExodusUI
