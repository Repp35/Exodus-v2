-- [[ ui ]]

-- module
local ExodusUI = {}
local Utils
local UIConfig
local GameInfo
local AutoSpam
local Controls = {}
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local Camera = workspace.CurrentCamera
local _wait = task.wait
local _spawn = task.spawn
local UIState = {
  connections = {},
  panelOpen = false,
  reopenAllowed = false,
  initialized = false,
  reducedMotion = false,
  spamOn = false,
  clashBallOn = false,
  btnIsDragging = function() return false end,
  panelTween = nil,
  btnTween = nil,
  pageGeneration = 0,
  pageTweens = {},
  transitionGeneration = 0,
  lifecycleGeneration = 0,
  desktop = false,
  closing = false,
  toastGeneration = 0,
  toastTween = nil,
  keyCapture = false,
  distanceVisible = false,
  travelVisible = false,
  gatesVisible = false,
}

local setSpam
local showToast
local screenGui
local menuGui
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
local minimizeButton
local reloadButton
local colLeft
local colRight
local killBtn
local toastLayer
local responsiveScale
local flowingTweens = {}
local ballVisibilityGenerations = {}
local miniVisibilityGeneration = 0
local shortcutLabels = {}
local offOnVisuals = {}

-- configuration
local CONFIG = {
  COLORS = {
    bg = Color3.fromRGB(8, 10, 24),
    header = Color3.fromRGB(14, 17, 38),
    surface = Color3.fromRGB(16, 20, 44),
    card = Color3.fromRGB(20, 24, 52),
    cardHover = Color3.fromRGB(27, 32, 66),
    accent = Color3.fromRGB(99, 102, 241),
    accentPink = Color3.fromRGB(236, 72, 153),
    autoMode = Color3.fromRGB(16, 154, 201),
    green = Color3.fromRGB(34, 197, 94),
    red = Color3.fromRGB(239, 68, 68),
    redDark = Color3.fromRGB(153, 27, 27),
    text = Color3.fromRGB(240, 240, 255),
    subtext = Color3.fromRGB(140, 140, 200),
    muted = Color3.fromRGB(104, 110, 158),
    border = Color3.fromRGB(60, 66, 116),
    borderSubtle = Color3.fromRGB(42, 47, 88),
    focus = Color3.fromRGB(125, 211, 252),
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
  },
  GRADIENT = {
    Color3.fromRGB(56, 189, 248),
    Color3.fromRGB(139, 92, 246),
    Color3.fromRGB(236, 72, 153),
  },
  PARTICLE_COLORS = {
    Color3.fromRGB(85, 90, 140),
    Color3.fromRGB(110, 95, 150),
    Color3.fromRGB(150, 95, 130),
    Color3.fromRGB(95, 130, 165),
  },
  BTN_SIZE = 56,
  CLASH_SIZE = 64,
  MINI_W = 120,
  MINI_H = 90,
  PANEL_W = 540,
  PANEL_H = 380,
  TITLE_H = 50,
  PAGE_HEAD_H = 34,
  PAD = 14,
  GAP = 12,
  CARD_GAP = 8,
  INNER_PAD = 14,
  CARD_H = 48,
  RATE_CARD_H = 64,
  SPAM_CARD_H = 118,
  CARD_SCALE = 1,
  DRAG_THRESHOLD_SQ = 100,
  VIEWPORT_MARGIN = 16,
  MIN_SCALE = 0.55,
  MOTION = {
    FAST = 0.12,
    CONTROL = 0.18,
    STANDARD = 0.24,
    PANEL = 0.28,
    SLOW = 0.34,
  },
  TITLE_SIDE_MARGIN = 90,
  TITLE_SPACING = 7,
  TITLE_TEXT_SIZE = 16,
  AUTHOR_TEXT_SIZE = 14,
  AUTHOR_TRANSPARENCY = 0.22,
}

-- palette
local C = CONFIG.COLORS
local GRAD = CONFIG.GRADIENT
local EASE_OUT, EASE_SINE, EASE_BACK = Enum.EasingStyle.Cubic, Enum.EasingStyle.Sine, Enum.EasingStyle.Back
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
local function attachFlow(s)
  local g = inst("UIGradient", { Rotation = 0 }, s)
  g.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, GRAD[1]),
    ColorSequenceKeypoint.new(0.5, GRAD[2]),
    ColorSequenceKeypoint.new(1, GRAD[3]),
  })
  return g
end
local function twPlay(obj, t, props, style, dir, completed)
  if not obj or obj.Parent == nil then return nil end
  local duration = UIState.reducedMotion and 0 or t; local tween = TweenService:Create(obj, TweenInfo.new(duration, style or EASE_OUT, dir or DIR_OUT), props)
  if type(completed) == "function" then
    local connection
    connection = tween.Completed:Connect(function(playbackState)
      if connection then connection:Disconnect(); connection = nil end
      completed(playbackState)
    end)
  end
  tween:Play(); return tween
end
local function safeCancel(t)
  if t then t:Cancel() end
end
local function setTextIfChanged(label, text)
  if label.Text ~= text then label.Text = text end
end
local function detectReducedMotion()
  local ok, value = pcall(function() return UserSettings():GetService("UserGameSettings").ReducedMotion end)
  return ok and value == true
end
local function createTweenGroup()
  local pending = 0
  local callback
  local function finish()
    if pending ~= 0 or not callback then return end
    local done = callback; callback = nil
    done()
  end
  local function play(obj, duration, props, style, direction)
    pending += 1
    local tween = twPlay(obj, duration, props, style, direction, function()
      pending -= 1; finish()
    end)
    if not tween then pending -= 1 end
    return tween
  end
  local function waitForCompletion()
    while pending > 0 do
      RunService.Heartbeat:Wait()
    end
  end
  local function onComplete(done)
    callback = type(done) == "function" and done or nil; finish()
  end
  return play, waitForCompletion, onComplete
end

-- layout
local function viewport()
  local currentCamera = workspace.CurrentCamera or Camera; return currentCamera and currentCamera.ViewportSize or Vector2.new(1920, 1080)
end
local function setConfigValue(key, value) return Utils.setConfig({ [key] = value }) end
local function toggleSetting(key, label, after)
  local state = Utils.getConfigValue(key) ~= true
  if not setConfigValue(key, state) then return false end
  if after then after(state) end
  if showToast then showToast(label .. (state and " On" or " Off")) end
  return state
end

-- connections
local function trackConn(c)
  if c and type(c.Disconnect) == "function" then UIState.connections[#UIState.connections + 1] = c end
  return c
end
local function untrackConn(c)
  for i = #UIState.connections, 1, -1 do
    if UIState.connections[i] == c then table.remove(UIState.connections, i); return end
  end
end
local function safeDisconnect(c)
  if c then c:Disconnect() end
end
local function disconnectUIConnections()
  for i = #UIState.connections, 1, -1 do
    safeDisconnect(UIState.connections[i]); UIState.connections[i] = nil
  end
end
local function bindButtonFeedback(button)
  if not button or not button:IsA("TextButton") or button:GetAttribute("ExodusFeedback") then return end
  button:SetAttribute("ExodusFeedback", true); button.AutoButtonColor = false
  button.Selectable = true; local baseColor, baseTransparency = button.BackgroundColor3, button.BackgroundTransparency
  local focusRing = button:FindFirstChild("ExodusFocusRing")
  if not focusRing then
    focusRing = stroke(button, C.focus, 1.5); focusRing.Name = "ExodusFocusRing"
    focusRing.Transparency = 1
  end
  local hovering, pressed, focused = false, false, false
  local function paint()
    local active = pressed or hovering or focused
    local color = baseColor
    if pressed and baseTransparency < 1 then color = baseColor:Lerp(Color3.new(0, 0, 0), 0.12) elseif active and baseTransparency < 1 then color = baseColor:Lerp(Color3.new(1, 1, 1), 0.08) end
    twPlay(button, CONFIG.MOTION.FAST, { BackgroundColor3 = color }, EASE_SINE, DIR_INOUT)
    twPlay(focusRing, CONFIG.MOTION.FAST, { Transparency = focused and 0.08 or (active and 0.45 or 1) }, EASE_SINE, DIR_INOUT)
  end
  trackConn(button.MouseEnter:Connect(function()
    hovering = true; paint()
  end))
  trackConn(button.MouseLeave:Connect(function()
    hovering, pressed = false, false; paint()
  end))
  trackConn(button.MouseButton1Down:Connect(function()
    pressed = true; paint()
  end))
  trackConn(button.MouseButton1Up:Connect(function()
    pressed = false; paint()
  end))
  trackConn(button.SelectionGained:Connect(function()
    focused = true; paint()
  end))
  trackConn(button.SelectionLost:Connect(function()
    focused, pressed = false, false; paint()
  end))
  trackConn(button.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then pressed = true; paint() end
  end))
  trackConn(button.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch then pressed = false; paint() end
  end))
end
local function bindTextBoxFeedback(box)
  if not box or not box:IsA("TextBox") or box:GetAttribute("ExodusFeedback") then return end
  box:SetAttribute("ExodusFeedback", true); box.Selectable = true
  local focusRing = box:FindFirstChild("ExodusFocusRing")
  if not focusRing then
    focusRing = stroke(box, C.focus, 1.5); focusRing.Name = "ExodusFocusRing"
    focusRing.Transparency = 1
  end
  trackConn(box.Focused:Connect(function() twPlay(focusRing, CONFIG.MOTION.FAST, { Transparency = 0.08 }, EASE_SINE, DIR_OUT) end))
  trackConn(box.FocusLost:Connect(function() twPlay(focusRing, CONFIG.MOTION.FAST, { Transparency = 1 }, EASE_SINE, DIR_IN) end))
end
local function enhanceInteractiveControls(root)
  if not root then return end
  for _, descendant in ipairs(root:GetDescendants()) do
    if descendant:IsA("TextButton") then bindButtonFeedback(descendant) elseif descendant:IsA("TextBox") then bindTextBoxFeedback(descendant) end
  end
end

-- input
local function inputBinding(input)
  if input.UserInputType == Enum.UserInputType.Keyboard then return input.KeyCode end
  if
    input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.MouseButton2
    or input.UserInputType == Enum.UserInputType.MouseButton3
  then
    return input.UserInputType
  end
  return nil
end
local function isKey(input, binding) return input and binding and inputBinding(input) == binding end
local function bindInput()
  trackConn(UIS.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or UIState.keyCapture or UIS:GetFocusedTextBox() or not UIState.desktop or not inputBinding(input) then return end
    local config = Utils.getConfig() or {}; local panicKey = config.Keybind
    local spamKey = config.SpamKeybind
    if isKey(input, panicKey) then
      setSpam(false)
      if type(Controls.onPanic) == "function" then Controls.onPanic() end
    elseif isKey(input, spamKey) and config.ManualSpamEnabled == true then
      setSpam(not UIState.spamOn)
    elseif isKey(input, config.ParryKeybind) then
      toggleSetting("AutoParry", "Auto Parry")
    elseif isKey(input, config.ClashKeybind) then
      toggleSetting("AutoSpam", "Auto Spam")
    elseif isKey(input, config.DarkKeybind) then
      toggleSetting("AutoDark", "Auto Dark", Controls.onAutoDarkChanged)
    elseif isKey(input, config.JumpKeybind) then
      toggleSetting("AutoJump", "Auto Jump", Controls.onAutoJumpChanged)
    elseif isKey(input, config.UpDashKeybind) then
      if type(Controls.onUpDash) == "function" then Controls.onUpDash() end
      if showToast then showToast("Up Dash") end
    end
  end))
end

-- dragging
local function makeDraggable(handle, target, onDragEnd, disableOnMobile)
  local dragInput, dragOffX, dragOffY = nil, 0, 0; local state, wasDragged, startX, startY = "Idle", false, 0, 0
  local THRESH_SQ = CONFIG.DRAG_THRESHOLD_SQ
  trackConn(handle.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    if disableOnMobile and UIS.TouchEnabled then return end
    if state ~= "Idle" then return end
    state, wasDragged, dragInput = "Pressed", false, input; local abs = target.AbsolutePosition
    local scale = math.max(responsiveScale and responsiveScale.Scale or 1, 0.01); dragOffX, dragOffY = (input.Position.X - abs.X) / scale, (input.Position.Y - abs.Y) / scale
    startX, startY = input.Position.X, input.Position.Y
  end))
  trackConn(UIS.InputChanged:Connect(function(input)
    if state == "Idle" or not dragInput then return end
    local isMouseDrag = dragInput.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement
    local isTouchDrag = dragInput.UserInputType == Enum.UserInputType.Touch and input == dragInput
    if not isMouseDrag and not isTouchDrag then return end
    local dx, dy = input.Position.X - startX, input.Position.Y - startY
    if state == "Pressed" and (dx * dx + dy * dy) >= THRESH_SQ then state, wasDragged = "Dragging", true end
    if state == "Dragging" then
      local scale = math.max(responsiveScale and responsiveScale.Scale or 1, 0.01); local vp, sz, margin = viewport() / scale, target.AbsoluteSize / scale, CONFIG.VIEWPORT_MARGIN / scale
      local pointerX, pointerY = input.Position.X / scale, input.Position.Y / scale
      target.Position = UDim2.new(
        0,
        math.clamp(pointerX - dragOffX, margin, math.max(margin, vp.X - sz.X - margin)),
        0,
        math.clamp(pointerY - dragOffY, margin, math.max(margin, vp.Y - sz.Y - margin))
      )
    end
  end))
  trackConn(UIS.InputEnded:Connect(function(input)
    if input ~= dragInput or state == "Idle" then return end
    state, dragInput = "Idle", nil
    if wasDragged and onDragEnd then onDragEnd() end
    wasDragged = false
  end))
  return function() return state == "Dragging" end
end

-- visuals
local function registerFlow(obj)
  if UIState.reducedMotion then return end
  local gradient = attachFlow(obj); local tween = TweenService:Create(gradient, TweenInfo.new(12, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 })
  flowingTweens[#flowingTweens + 1] = tween; tween:Play()
end

-- floating-controls
local BTN_SIZE = CONFIG.BTN_SIZE
local function btnPos()
  local config = Utils.getConfig(); local x, y = config.BtnX, config.BtnY
  if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
  return UDim2.new(1, -(BTN_SIZE + CONFIG.VIEWPORT_MARGIN), 0.5, -BTN_SIZE / 2)
end
local CLASH_SIZE = CONFIG.CLASH_SIZE
local OFFSCREEN_X = -CLASH_SIZE - 40
local autoClashTrack, autoClashThumb, autoParrySetVisual, autoDarkSetVisual, autoJumpSetVisual
local function paintBall(ball, value, onText, offText, onColor, offColor, onSize, offSize)
  if not ball or not ball.Parent then return end
  ball.Text = value and onText or offText
  if onSize then ball.TextSize = value and onSize or offSize end
  twPlay(ball, CONFIG.MOTION.STANDARD, { BackgroundColor3 = value and onColor or offColor }, EASE_SINE, DIR_INOUT)
end
local function paintParryBall(value) paintBall(parryBall, value, "PARRY\nON", "PARRY\nOFF", C.green, C.red, 14, 14) end
local function showBall(ball, visible, visibleKey, xKey, yKey, defaultX, defaultY)
  setConfigValue(visibleKey, visible); local config = Utils.getConfig()
  local x = config[xKey] or defaultX; local y = config[yKey] or defaultY
  local shouldShow = visible and not UIState.desktop
  if not ball then return end
  local generation = (ballVisibilityGenerations[ball] or 0) + 1; ballVisibilityGenerations[ball] = generation
  if shouldShow then ball.Visible = true elseif not ball.Visible then return end
  local tween = twPlay(
    ball,
    shouldShow and CONFIG.MOTION.CONTROL or CONFIG.MOTION.FAST,
    { Position = shouldShow and UDim2.new(0, x, 0, y) or UDim2.new(0, OFFSCREEN_X, 0, y) },
    EASE_OUT,
    DIR_OUT,
    function()
      if not shouldShow and generation == ballVisibilityGenerations[ball] and ball.Parent then ball.Visible = false end
    end
  )
  if not tween and not shouldShow then ball.Visible = false end
end
local function pulseBall(ball)
  twPlay(
    ball,
    CONFIG.MOTION.FAST,
    { Size = UDim2.new(0, CLASH_SIZE - 6, 0, CLASH_SIZE - 6) },
    EASE_SINE,
    DIR_OUT,
    function() twPlay(ball, CONFIG.MOTION.STANDARD, { Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE) }, EASE_OUT, DIR_OUT) end
  )
end
local function showParryBall(value) showBall(parryBall, value, "ParryBallVisible", "ParryBallX", "ParryBallY", 14, viewport().Y / 2 - CLASH_SIZE - 40) end
local function paintClashBall() paintBall(clashBall, UIState.clashBallOn, "ON", "OFF", C.green, C.red, 18, 16) end
local function syncAutoSpamToggle()
  if not (autoClashTrack and autoClashThumb) then return end
  local v = UIState.clashBallOn; twPlay(autoClashTrack, CONFIG.MOTION.CONTROL, { BackgroundColor3 = v and C.toggleOn or C.toggleOff }, EASE_SINE, DIR_INOUT)
  twPlay(autoClashThumb, CONFIG.MOTION.SLOW, { Position = v and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10) }, EASE_OUT, DIR_OUT)
end
local function setClashBall(v, silent)
  UIState.clashBallOn = v; setConfigValue("AutoSpam", v)
  if silent then return end
  paintClashBall(); pulseBall(clashBall)
  if showToast then showToast("Auto Spam " .. (v and "On" or "Off")) end
end
local function showClashBall(v) showBall(clashBall, v, "ClashBallVisible", "ClashBallX", "ClashBallY", 14, viewport().Y / 2 - CLASH_SIZE / 2) end
local function paintDarkBall(v) paintBall(darkBall, v, "ON", "OFF", C.darkOn, C.darkOff, 18, 16) end
local function showDarkBall(v) showBall(darkBall, v, "DarkBallVisible", "DarkBallX", "DarkBallY", 14, viewport().Y / 2 + CLASH_SIZE / 2 + 8) end
local function setDarkBall(v)
  if not setConfigValue("AutoDark", v) then return end
  if type(Controls.onAutoDarkChanged) == "function" then Controls.onAutoDarkChanged() end
  paintDarkBall(v)
  if autoDarkSetVisual then autoDarkSetVisual(v) end
  pulseBall(darkBall)
  if showToast then showToast("Auto Dark " .. (v and "On" or "Off")) end
end
local function showMovementBall(ball, visible, visibleKey, xKey, yKey, yOffset)
  showBall(ball, visible, visibleKey, xKey, yKey, CLASH_SIZE + 22, viewport().Y / 2 + yOffset)
end
local function showJumpBall(v) showMovementBall(jumpBall, v, "JumpBallVisible", "JumpBallX", "JumpBallY", -CLASH_SIZE / 2) end
local function showUpDashBall(v) showMovementBall(upDashBall, v, "UpDashBallVisible", "UpDashBallX", "UpDashBallY", CLASH_SIZE / 2 + 8) end
local function paintJumpBall(v)
  if autoJumpSetVisual then autoJumpSetVisual(v) end
  paintBall(jumpBall, v, "JUMP\nON", "JUMP\nOFF", C.jumpOn, C.jumpOff)
end
local function setJumpBall(v)
  if not setConfigValue("AutoJump", v) then return end
  if type(Controls.onAutoJumpChanged) == "function" then Controls.onAutoJumpChanged() end
  paintJumpBall(v)
  if showToast then showToast("Auto Jump " .. (v and "On" or "Off")) end
end
local MINI_W, MINI_H = CONFIG.MINI_W, CONFIG.MINI_H
local function showMini(v)
  if UIState.desktop then v = false end
  local config = Utils.getConfig(); local miniX = config.MiniX or (viewport().X - MINI_W - CONFIG.VIEWPORT_MARGIN)
  local miniY = config.MiniY or (viewport().Y / 2 - MINI_H / 2); local MINI_OFF_X = viewport().X + 30
  miniVisibilityGeneration += 1; local generation = miniVisibilityGeneration
  if v == true then
    miniGui.Visible = true; twPlay(miniGui, CONFIG.MOTION.CONTROL, { Position = UDim2.new(0, miniX, 0, miniY) }, EASE_OUT, DIR_OUT)
    return
  end
  if not miniGui.Visible then miniGui.Position = UDim2.new(0, MINI_OFF_X, 0, miniY); return end
  local tween = twPlay(miniGui, CONFIG.MOTION.FAST, { Position = UDim2.new(0, MINI_OFF_X, 0, miniY) }, EASE_OUT, DIR_IN, function()
    if generation == miniVisibilityGeneration and miniGui.Parent then miniGui.Visible = false end
  end)
  if not tween then miniGui.Visible = false end
end
local function paintManualSpam()
  local spamButton = miniGui and miniGui:FindFirstChild("SpamButton")
  if not spamButton then return end
  local active = UIState.spamOn == true
  spamButton.Text = active and "ON" or "OFF"
  -- Set the state color directly so overlapping tweens cannot leave the wrong color.
  spamButton.BackgroundColor3 = active and C.green or C.red
end
setSpam = function(v)
  v = v == true
  UIState.spamOn = v
  Utils.setManualSpamActive(v)
  UIState.spamOn = Utils.isManualSpamActive()
  paintManualSpam()
end

local PW, PH = CONFIG.PANEL_W, CONFIG.PANEL_H
local TITLE_H, PAD, GAP, CARD_GAP = CONFIG.TITLE_H, CONFIG.PAD, CONFIG.GAP, CONFIG.CARD_GAP
local INNER_PAD, CARD_H, RATE_CARD_H, SPAM_CARD_H = CONFIG.INNER_PAD, CONFIG.CARD_H, CONFIG.RATE_CARD_H, CONFIG.SPAM_CARD_H
local CONTENT_H = PH - TITLE_H - 60
local PAGE_HEAD_H = CONFIG.PAGE_HEAD_H
local COL_W = math.floor((PW - PAD * 2 - GAP) / 2)
local CARD_SCALE = CONFIG.CARD_SCALE
local CARD_MAX_H = CARD_H
local function cardHeight(height) return math.max(0, height or CARD_MAX_H) end
local function offOnText(labelText, value)
  local color = value and "#22C55E" or "#EF4444"; return labelText .. ': <font color="' .. color .. '">' .. (value and "ON" or "OFF") .. "</font>"
end
local function nextCardY(yPos, height) return yPos + cardHeight(height) * CARD_SCALE + CARD_GAP end

-- panel
local function panelPos()
  local config = Utils.getConfig(); local x, y = config.PanelX, config.PanelY
  if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
  return UDim2.new(0.5, -PW / 2, 0.5, -PH / 2)
end
local PARTICLE_COLORS = CONFIG.PARTICLE_COLORS

-- cleanup
local function cleanupUI()
  safeCancel(UIState.panelTween); safeCancel(UIState.btnTween)
  disconnectUIConnections(); UIState.connections = {}
  UIState.pageGeneration += 1
  for _, tween in ipairs(UIState.pageTweens) do
    safeCancel(tween)
  end
  UIState.pageTweens = {}; UIState.panelOpen = false
  UIState.transitionGeneration += 1; UIState.lifecycleGeneration += 1
  UIState.reopenAllowed = false; UIState.clashBallOn = false
  UIState.closing = false; UIState.keyCapture = false
  UIState.panelTween = nil; UIState.btnTween = nil
  UIState.toastGeneration += 1; safeCancel(UIState.toastTween)
  UIState.toastTween = nil
  UIState.btnIsDragging = function() return false end
  for i = #flowingTweens, 1, -1 do
    safeCancel(flowingTweens[i]); flowingTweens[i] = nil
  end
  local current = screenGui
  if current then current:Destroy() end
  if menuGui then menuGui:Destroy(); menuGui = nil end
  local overlay = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
  if overlay then
    local oldOverlay = overlay:FindFirstChild("ExodusInformationOverlay")
    if oldOverlay then oldOverlay:Destroy() end
  end
  screenGui = nil; floatingButton = nil
  clashBall = nil; parryBall = nil
  darkBall = nil; jumpBall = nil
  upDashBall = nil; miniGui = nil
  configPanel = nil; particleLayer = nil
  titleBar = nil; minimizeButton = nil
  reloadButton = nil; colLeft = nil
  colRight = nil; killBtn = nil
  toastLayer = nil; responsiveScale = nil
  shortcutLabels = {}; offOnVisuals = {}
  ballVisibilityGenerations = {}; miniVisibilityGeneration += 1
  autoClashTrack = nil; autoClashThumb = nil
  autoParrySetVisual = nil; autoDarkSetVisual = nil
  autoJumpSetVisual = nil
  if _G.ExodusUICleanup == cleanupUI then _G.ExodusUICleanup = nil; _G.ExodusUIFadeOut = nil end
end

-- particles
local function spawnParticle()
  if not particleLayer or not particleLayer.Parent then return end
  local isFar = math.random() < 0.6; local size = isFar and math.random(2, 3) or math.random(4, 6)
  local startTrans = isFar and 0.5 or 0.2; local color = PARTICLE_COLORS[math.random(1, #PARTICLE_COLORS)]
  local dot = inst("Frame", {
    Size = UDim2.new(0, size, 0, size),
    Position = UDim2.new(math.random(), 0, 1, 0),
    BackgroundColor3 = color,
    BackgroundTransparency = startTrans,
    ZIndex = 4,
    Parent = particleLayer,
  })
  corner(dot, 999); local dur = isFar and math.random(5, 9) or math.random(3, 5)
  local endX = math.clamp(dot.Position.X.Scale + (math.random() - 0.5) * 0.15, 0, 1); twPlay(dot, 0.6, { BackgroundTransparency = math.max(startTrans - 0.1, 0.05) }, EASE_SINE, DIR_OUT)
  twPlay(dot, dur, { Position = UDim2.new(endX, 0, -0.1, 0), BackgroundTransparency = 1 }, EASE_SINE, DIR_INOUT)
  task.delay(dur + 0.2, function()
    if dot.Parent then dot:Destroy() end
  end)
end

-- card-primitives
local function cardFrame(yPos, h, parent)
  local f = inst("Frame", {
    Size = UDim2.new(1, -22, 0, cardHeight(h)),
    Position = UDim2.new(0, 2, 0, yPos),
    BackgroundColor3 = C.card,
    BackgroundTransparency = 0.04,
    BorderSizePixel = 0,
    ZIndex = 6,
    Parent = parent,
  })
  inst("UIScale", { Scale = CARD_SCALE }, f); corner(f, 12)
  local s = stroke(f, C.borderSubtle, 1)
  trackConn(f.MouseEnter:Connect(function()
    twPlay(s, CONFIG.MOTION.CONTROL, { Color = C.accent }, EASE_SINE, DIR_INOUT); twPlay(f, CONFIG.MOTION.CONTROL, { BackgroundColor3 = C.cardHover }, EASE_SINE, DIR_INOUT)
  end))
  trackConn(f.MouseLeave:Connect(function()
    twPlay(s, CONFIG.MOTION.STANDARD, { Color = C.borderSubtle }, EASE_SINE, DIR_INOUT); twPlay(f, CONFIG.MOTION.STANDARD, { BackgroundColor3 = C.card }, EASE_SINE, DIR_INOUT)
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
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 7,
    Parent = parent,
  })
end
local function makeBtn(text, x, y, w, h, parent, bg)
  local b = inst("TextButton", {
    Size = UDim2.new(0, w, 0, h),
    Position = UDim2.new(0, x, 0, y),
    BackgroundColor3 = bg or C.btnBlue,
    BackgroundTransparency = 0.04,
    BorderSizePixel = 0,
    Text = text,
    TextColor3 = C.text,
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 7,
    Parent = parent,
  })
  corner(b, 8); return b
end

-- notifications
showToast = function(message, important)
  local notificationKey = UIState.desktop and "DesktopNotifications" or "MobileNotifications"
  if not important and Utils.getConfigValue(notificationKey) ~= true then return end
  if not toastLayer or not toastLayer.Parent then return end
  UIState.toastGeneration += 1; local generation = UIState.toastGeneration
  safeCancel(UIState.toastTween)
  for _, child in ipairs(toastLayer:GetChildren()) do
    child:Destroy()
  end
  local isOff = string.find(tostring(message), " Off", 1, true) ~= nil
  local toast = inst("CanvasGroup", {
    Name = "ExodusToast",
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, 18),
    Size = UDim2.fromOffset(214, 38),
    BackgroundColor3 = isOff and C.redDark or C.surface,
    BackgroundTransparency = 0.06,
    GroupTransparency = 1,
    ZIndex = 200,
    Parent = toastLayer,
  })
  corner(toast, 10); stroke(toast, isOff and C.red or C.accent, 1)
  inst("TextLabel", {
    Size = UDim2.new(1, -16, 1, 0),
    Position = UDim2.new(0, 8, 0, 0),
    BackgroundTransparency = 1,
    Text = tostring(message),
    TextColor3 = C.text,
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 201,
    Parent = toast,
  })
  UIState.toastTween = twPlay(toast, CONFIG.MOTION.CONTROL, { Position = UDim2.new(0.5, 0, 1, -28), GroupTransparency = 0 }, EASE_OUT, DIR_OUT)
  task.delay(1.35, function()
    if generation ~= UIState.toastGeneration or not toast.Parent then return end
    local fade = twPlay(toast, CONFIG.MOTION.CONTROL, { Position = UDim2.new(0.5, 0, 1, 10), GroupTransparency = 1 }, EASE_OUT, DIR_IN)
    if fade then
      local connection
      connection = fade.Completed:Connect(function()
        if connection then connection:Disconnect() end
        if toast.Parent then toast:Destroy() end
      end)
    end
  end)
end
local function makeToggle(trackParent, initial)
  local track = inst("Frame", {
    Size = UDim2.new(0, 48, 0, 30),
    Position = UDim2.new(1, -INNER_PAD - 48, 0.5, -15),
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
    twPlay(track, CONFIG.MOTION.CONTROL, { BackgroundColor3 = v and C.toggleOn or C.toggleOff }, EASE_SINE, DIR_INOUT)
    twPlay(thumb, CONFIG.MOTION.STANDARD, { Position = v and UDim2.new(0, 25, 0.5, -10) or UDim2.new(0, 3, 0.5, -10) }, EASE_SINE, DIR_INOUT)
  end
  return track, thumb, setVisual
end

-- keybinds
local function bindKeyCapture(btn, onPicked)
  local listening = false
  trackConn(btn.Activated:Connect(function()
    if listening or UIState.keyCapture then return end
    local previousText, restColor = btn.Text, btn.BackgroundColor3; listening = true
    UIState.keyCapture = true; btn.Text = "..."
    twPlay(btn, CONFIG.MOTION.FAST, { BackgroundColor3 = Color3.fromRGB(80, 85, 160) })
    local conn
    conn = trackConn(UIS.InputBegan:Connect(function(input, gpe)
      local binding = inputBinding(input)
      if not binding then return end
      if input.KeyCode == Enum.KeyCode.Escape then btn.Text = previousText else onPicked(binding) end
      listening = false; UIState.keyCapture = false
      safeDisconnect(conn); untrackConn(conn)
      twPlay(btn, CONFIG.MOTION.FAST, { BackgroundColor3 = restColor })
    end))
  end))
end
local function keyName(value)
  local names = {
    MouseButton1 = "M1",
    MouseButton2 = "M2",
    MouseButton3 = "M3",
    LeftControl = "LCtrl",
    RightControl = "RCtrl",
    LeftShift = "LShift",
    RightShift = "RShift",
  }

  local name = typeof(value) == "EnumItem" and value.Name or tostring(value or "—"); return names[name] or name
end
local function makeKeycap(parent, configKey, rightAligned, baseHeight)
  local keycap = makeBtn(keyName(Utils.getConfigValue(configKey)), 0, 0, 32, 28, parent, C.btnDark); keycap.Name = "Shortcut_" .. configKey
  keycap.Position = UDim2.new(1, -132, 0, 10); keycap.TextSize = 9
  keycap.ZIndex = 11; shortcutLabels[configKey] = keycap
  local arrow = makeBtn("⌄", 0, 0, 24, 28, parent, C.btnDark); arrow.Name = "ShortcutSettings"
  arrow.Position = UDim2.new(1, -96, 0, 10); arrow.ZIndex = 11
  local editor = makeBtn("Shortcut: " .. keyName(Utils.getConfigValue(configKey)), 10, (baseHeight or CARD_H) + 4, 0, 30, parent, C.btnBlue); editor.Size = UDim2.new(1, -20, 0, 30)
  editor.Name = "ShortcutEditor"; editor.Visible = false
  editor.ZIndex = 11; editor.TextSize = 12
  local expanded = false
  if rightAligned then keycap.Position = UDim2.new(1, -68, 0, 10); arrow.Position = UDim2.new(1, -32, 0, 10) end
  local function expand()
    expanded = not expanded; local delta = expanded and 44 or -44
    editor.Visible = expanded; arrow.Text = expanded and "⌃" or "⌄"
    parent.Size += UDim2.fromOffset(0, delta); local layoutDelta = delta * CARD_SCALE
    for _, sibling in ipairs(parent.Parent:GetChildren()) do
      if sibling:IsA("GuiObject") and sibling ~= parent and sibling.Position.Y.Offset > parent.Position.Y.Offset then sibling.Position += UDim2.fromOffset(0, layoutDelta) end
    end
    if parent.Parent:IsA("ScrollingFrame") then parent.Parent.CanvasSize += UDim2.fromOffset(0, layoutDelta) end
  end
  trackConn(arrow.Activated:Connect(expand)); trackConn(keycap.Activated:Connect(expand))
  bindKeyCapture(editor, function(binding)
    if setConfigValue(configKey, binding) then keycap.Text = keyName(binding); editor.Text = "Shortcut: " .. keyName(binding) end
  end)
  return keycap
end

-- cards
local function createToggleCard(labelText, configKey, yPos, parent, onAfter, shortcutKey)
  local f = cardFrame(yPos, CARD_H, parent)
  local label = inst("TextLabel", {
    Size = UDim2.new(1, UIState.desktop and shortcutKey and -148 or -78, 0, CARD_H),
    Position = UDim2.new(0, 14, 0, 0),
    BackgroundTransparency = 1,
    Text = labelText,
    TextColor3 = C.text,
    TextSize = UIState.desktop and shortcutKey and 11 or 13,
    TextScaled = false,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Font = Enum.Font.GothamSemibold,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
    Parent = f,
  })
  if UIState.desktop and shortcutKey then inst("UITextSizeConstraint", { MaxTextSize = 11 }, label) end
  local config = Utils.getConfig(); local initial = configKey and config[configKey] or false
  local toggleTrack, toggleThumb, setVisual = makeToggle(f, initial); toggleTrack.Position = UDim2.new(1, -INNER_PAD - 48, 0, 9)
  if UIState.desktop and shortcutKey then makeKeycap(f, shortcutKey) end
  if configKey == "AutoSpam" then autoClashTrack = toggleTrack; autoClashThumb = toggleThumb end
  if configKey == "AutoParry" then autoParrySetVisual = setVisual end
  if configKey == "AutoDark" then autoDarkSetVisual = setVisual end
  if configKey == "AutoJump" then autoJumpSetVisual = setVisual end
  trackConn(inst("TextButton", {
    Size = UDim2.new(1, 0, 0, CARD_H),
    BackgroundTransparency = 1,
    Text = "",
    ZIndex = 9,
    Parent = f,
  }).Activated:Connect(function()
    local current = Utils.getConfig(); local state = not (configKey and current[configKey] == true)
    if not configKey or setConfigValue(configKey, state) then
      setVisual(state)
      if onAfter then onAfter(state) end
      if showToast then showToast(labelText .. (state and " On" or " Off")) end
    end
  end))
  return nextCardY(yPos, CARD_H), f
end
local function createOffOnCard(labelText, yPos, parent, options)
  options = options or {}; local cardHeight = CARD_H
  local configKey, state = options.configKey, false
  local function readState()
    if options.getState then return options.getState() == true end
    if configKey then return Utils.getConfigValue(configKey) == true end
    return state
  end
  state = readState(); local f = cardFrame(yPos, cardHeight, parent)
  local control = inst("TextButton", {
    Size = UDim2.new(1, options.rightAligned and -72 or 0, 0, cardHeight),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Text = offOnText(labelText, state),
    TextColor3 = C.text,
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    RichText = true,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 9,
    Parent = f,
  })
  local function setVisual(value)
    state = value == true; control.Text = offOnText(labelText, state)
  end
  if configKey then offOnVisuals[configKey] = setVisual end
  if UIState.desktop and options.shortcutKey then makeKeycap(f, options.shortcutKey, options.rightAligned, cardHeight) end
  trackConn(control.Activated:Connect(function()
    local requested = not readState()
    if configKey and not setConfigValue(configKey, requested) then return end
    local result = options.onToggle and options.onToggle(requested); local nextState = type(result) == "boolean" and result or requested
    if configKey and result == false then setConfigValue(configKey, false) end
    setVisual(nextState)
    if options.toastLabel and showToast then showToast(options.toastLabel .. (nextState and " On" or " Off")) end
  end))
  return nextCardY(yPos, cardHeight), f, setVisual
end
local function createActionShortcutCard(labelText, yPos, parent, configKey, onActivate)
  local f = cardFrame(yPos, CARD_H, parent); cardLabel(labelText, f)
  local label = f:FindFirstChildOfClass("TextLabel")
  if label then
    label.Size = UDim2.new(1, -148, 0, CARD_H); label.Position = UDim2.fromOffset(14, 0)
    label.TextColor3 = C.text; label.TextSize = 11
  end
  if UIState.desktop and configKey then makeKeycap(f, configKey) end
  trackConn(inst("TextButton", {
    Size = UDim2.new(1, 0, 0, CARD_H),
    BackgroundTransparency = 1,
    Text = "",
    ZIndex = 9,
    Parent = f,
  }).Activated:Connect(function()
    onActivate()
    if showToast then showToast(labelText .. " On") end
  end))
  return nextCardY(yPos, CARD_H), f
end
local function createParryTimingCard(yPos, parent)
  local f = cardFrame(yPos, CARD_H, parent)
  inst("TextLabel", {
    Size = UDim2.new(1, -100, 1, 0),
    Position = UDim2.new(0, 14, 0, 0),
    BackgroundTransparency = 1,
    Text = "AP Lead (%)",
    TextColor3 = C.text,
    TextSize = 13,
    Font = Enum.Font.GothamSemibold,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
    Parent = f,
  })
  local config = Utils.getConfig(); local initial = tonumber(config.AutoParryWindowFactor) or 0.3
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
    if not value or value ~= value or value == math.huge or value == -math.huge then value = (tonumber(Utils.getConfig().AutoParryWindowFactor) or 0.3) * 100 end
    value = math.clamp(value, 0, 35); setConfigValue("AutoParryWindowFactor", value / 100)
    input.Text = tostring(value)
  end))
  return nextCardY(yPos, CARD_H)
end
local function createCameraSensitivityCard(yPos, parent)
  local f = cardFrame(yPos, CARD_H, parent); cardLabel("Camera Sensitivity", f)
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
  local f = cardFrame(yPos, RATE_CARD_H, parent); local config = Utils.getConfig()
  config.CPS = Utils.normalizeSpamRate(config.CPS, 25.5); config.CPF = Utils.normalizeSpamRate(config.CPF, 0.3917)
  config.SpamRateMode = config.SpamRateMode == "Auto" and "Auto" or (config.SpamRateMode == "CPF" and "CPF" or "CPS")
  Utils.setConfig({
    CPS = config.CPS,
    CPF = config.CPF,
    SpamRateMode = config.SpamRateMode,
  })
  cardLabel("Spam Rate", f); local currentMode = config.SpamRateMode
  local modeTrack = inst("Frame", {
    Size = UDim2.new(0, 120, 0, 28),
    Position = UDim2.new(0, 10, 0, 29),
    BackgroundColor3 = C.inputBg,
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    ZIndex = 7,
    Parent = f,
  })
  corner(modeTrack, 999); stroke(modeTrack, C.border, 1)
  local modeThumb = inst("Frame", {
    Size = UDim2.new(0, 36, 0, 24),
    Position = UDim2.new(0, currentMode == "CPS" and 2 or (currentMode == "CPF" and 42 or 82), 0.5, -12),
    BackgroundColor3 = currentMode == "CPS" and C.accent or (currentMode == "CPF" and C.accentPink or C.autoMode),
    BorderSizePixel = 0,
    ZIndex = 8,
    Parent = modeTrack,
  })
  corner(modeThumb, 999); stroke(modeThumb, C.text, 1)
  local modeButtons = {}
  for index, mode in ipairs({ "CPS", "CPF", "Auto" }) do
    local button = inst("TextButton", {
      Size = UDim2.new(0, 40, 1, 0),
      Position = UDim2.new(0, (index - 1) * 40, 0, 0),
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
    Size = UDim2.new(0, 54, 0, 28),
    Position = UDim2.new(1, -64, 0, 29),
    BackgroundColor3 = C.inputBg,
    BackgroundTransparency = 0.1,
    Text = currentMode == "Auto" and "Auto" or tostring(config[currentMode]),
    TextEditable = currentMode ~= "Auto",
    PlaceholderText = "Rate",
    ClearTextOnFocus = false,
    TextColor3 = C.text,
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = f,
  })
  corner(inputBox, 8); local inputStroke = stroke(inputBox, C.border, 1)
  local function paintRateMode(animated)
    local isCPS = currentMode == "CPS"; local targetPosition = UDim2.new(0, isCPS and 2 or (currentMode == "CPF" and 42 or 82), 0.5, -12)
    local duration = animated and 0.32 or 0
    twPlay(modeThumb, duration, {
      Position = targetPosition,
      BackgroundColor3 = isCPS and C.accent or (currentMode == "CPF" and C.accentPink or C.autoMode),
    }, EASE_OUT, DIR_OUT)
    for mode, button in pairs(modeButtons) do
      twPlay(button, animated and 0.2 or 0, {
        TextColor3 = mode == currentMode and C.text or C.subtext,
      }, EASE_SINE, DIR_INOUT)
    end
  end
  local function selectRateMode(mode)
    if mode ~= "CPS" and mode ~= "CPF" and mode ~= "Auto" or currentMode == mode then return end
    currentMode = mode; config.SpamRateMode = mode
    inputBox.TextEditable = mode ~= "Auto"; inputBox.Text = mode == "Auto" and "Auto" or tostring(config[mode])
    setConfigValue("SpamRateMode", mode); paintRateMode(true)
  end
  for mode, button in pairs(modeButtons) do
    trackConn(button.Activated:Connect(function() selectRateMode(mode) end))
  end
  trackConn(inputBox.Focused:Connect(function() twPlay(inputStroke, CONFIG.MOTION.FAST, { Color = C.accent }) end))
  trackConn(inputBox.FocusLost:Connect(function()
    twPlay(inputStroke, CONFIG.MOTION.FAST, { Color = C.border })
    if currentMode == "Auto" then inputBox.Text = "Auto"; return end
    local value = tonumber(inputBox.Text); local key = currentMode
    local fallback = config[key]; local normalized = Utils.normalizeSpamRate(value, fallback)
    setConfigValue(key, normalized); inputBox.Text = tostring(normalized)
  end))
  return nextCardY(yPos, RATE_CARD_H)
end
local function createKeybindSelector(yPos, parent)
  return createActionShortcutCard("Stop Functions", yPos, parent, "Keybind", function()
    setSpam(false)
    if type(Controls.onPanic) == "function" then Controls.onPanic() end
  end)
end
local offOnCallbacks = {
  MiniSpamVisible = showMini,
  ManualSpamEnabled = function(enabled)
    if not enabled then setSpam(false) end
  end,
}

local function togglePanel(closedByButton)
  if not configPanel or not configPanel.Parent or not floatingButton or not floatingButton.Parent then return end
  UIState.panelOpen = not UIState.panelOpen; UIState.transitionGeneration += 1
  local generation = UIState.transitionGeneration; safeCancel(UIState.panelTween)
  safeCancel(UIState.btnTween)
  if UIState.panelOpen then
    UIState.reopenAllowed = false; floatingButton.Visible = false
    if not configPanel.Visible then configPanel.GroupTransparency = 1; configPanel.Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97) end
    configPanel.Visible = true; UIState.panelTween = twPlay(configPanel, CONFIG.MOTION.PANEL, { Size = UDim2.new(0, PW, 0, PH), GroupTransparency = 0 }, EASE_OUT, DIR_OUT)
  else
    UIState.reopenAllowed = closedByButton == true; floatingButton.Visible = UIState.reopenAllowed
    UIState.panelTween = twPlay(configPanel, CONFIG.MOTION.CONTROL, { Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97), GroupTransparency = 1 }, EASE_OUT, DIR_IN)
    UIState.btnTween = twPlay(
      floatingButton,
      CONFIG.MOTION.CONTROL,
      { BackgroundTransparency = 0.1, TextTransparency = 0, Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE) },
      EASE_OUT,
      DIR_OUT
    )
    if UIState.panelTween then
      local conn
      conn = trackConn(UIState.panelTween.Completed:Connect(function()
        if generation == UIState.transitionGeneration and not UIState.panelOpen then
          configPanel.Visible = false; configPanel.Size = UDim2.new(0, PW, 0, PH)
          configPanel.GroupTransparency = 0
        end
        safeDisconnect(conn); untrackConn(conn)
      end))
    else
      if generation == UIState.transitionGeneration then
        configPanel.Visible = false; configPanel.Size = UDim2.new(0, PW, 0, PH)
        configPanel.GroupTransparency = 0
      end
    end
  end
end
local function restoreAfterReloadFailure(message)
  if not configPanel or not configPanel.Parent then return end
  UIState.closing = false; UIState.panelOpen = true
  UIState.reopenAllowed = false; configPanel.Visible = true
  configPanel.Size = UDim2.new(0, PW * 0.96, 0, PH * 0.96); configPanel.GroupTransparency = 1
  if floatingButton and floatingButton.Parent then
    floatingButton.Visible = false; floatingButton.Size = UDim2.new(0, 42, 0, 42)
    floatingButton.BackgroundTransparency = 1; floatingButton.TextTransparency = 1
  end
  twPlay(configPanel, CONFIG.MOTION.PANEL, { Size = UDim2.new(0, PW, 0, PH), GroupTransparency = 0 }, EASE_OUT, DIR_OUT); local config = Utils.getConfig()
  if not UIState.desktop then
    showClashBall(config.ClashBallVisible == true); showParryBall(config.ParryBallVisible == true)
    showDarkBall(config.DarkBallVisible == true); showJumpBall(config.JumpBallVisible == true)
    showUpDashBall(config.UpDashBallVisible == true); showMini(config.MiniSpamVisible == true)
  end
  if showToast then showToast("Reload failed", true) end
  warn("[Exodus Reload] " .. tostring(message))
end
local function fadeOutForReplacement()
  if not screenGui or not screenGui.Parent or UIState.closing then return end
  UIState.closing = true; safeCancel(UIState.panelTween)
  safeCancel(UIState.btnTween); local duration = CONFIG.MOTION.SLOW
  local playTween, waitForCompletion = createTweenGroup()
  if configPanel and configPanel.Parent and configPanel.Visible then playTween(configPanel, duration, { GroupTransparency = 1, Size = UDim2.fromOffset(PW * 0.96, PH * 0.96) }, EASE_OUT, DIR_IN) end
  if floatingButton and floatingButton.Parent then playTween(floatingButton, duration, { BackgroundTransparency = 1, TextTransparency = 1 }, EASE_OUT, DIR_IN) end
  for _, element in ipairs({ clashBall, parryBall, darkBall, jumpBall, upDashBall, miniGui }) do
    if element and element.Parent then playTween(element, duration, { Position = UDim2.new(0, OFFSCREEN_X, element.Position.Y.Scale, element.Position.Y.Offset) }, EASE_OUT, DIR_IN) end
  end
  waitForCompletion()
end
local function animateClose(action)
  if UIState.closing then return end
  UIState.closing = true; safeCancel(UIState.panelTween)
  safeCancel(UIState.btnTween); local playTween, waitForCompletion = createTweenGroup()
  if configPanel and configPanel.Parent then
    UIState.panelTween = playTween(configPanel, CONFIG.MOTION.PANEL, { Size = UDim2.new(0, PW * 0.96, 0, PH * 0.96), GroupTransparency = 1 }, EASE_OUT, DIR_IN)
  end
  if floatingButton and floatingButton.Parent then
    UIState.btnTween =
      playTween(floatingButton, CONFIG.MOTION.CONTROL, { Size = UDim2.new(0, 42, 0, 42), BackgroundTransparency = 1, TextTransparency = 1 }, EASE_OUT, DIR_IN)
  end
  for _, ball in ipairs({ clashBall, parryBall, darkBall, jumpBall, upDashBall, miniGui }) do
    if ball and ball.Parent then playTween(ball, CONFIG.MOTION.CONTROL, { Position = UDim2.new(0, OFFSCREEN_X, ball.Position.Y.Scale, ball.Position.Y.Offset) }, EASE_OUT, DIR_IN) end
  end
  _spawn(function()
    waitForCompletion()
    if not UIState.closing then return end
    if action == "reload" and type(Controls.onReload) == "function" then Controls.onReload(restoreAfterReloadFailure)
    elseif type(Controls.onClose) == "function" then Controls.onClose()
    elseif Utils and type(Utils.stop) == "function" then Utils.stop() end
  end)
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
  then
    return false, "missing dependency: Utils, Controls or UIConfig"
  end
  Utils = deps.Utils; UIConfig = deps.UIConfig
  GameInfo = deps.GameInfo; AutoSpam = deps.AutoSpam
  Controls = type(deps.Controls) == "table" and deps.Controls or {}; local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
  local restoreMinimized = UIState.reopenAllowed == true or (not UIState.initialized and _G.ExodusLoaderSessionToken ~= nil)
  if type(_G.ExodusUICleanup) == "function" then
    if type(_G.ExodusUIFadeOut) == "function" then pcall(_G.ExodusUIFadeOut) end
    _G.ExodusUICleanup()
  else
    local old = playerGui:FindFirstChild("ExodusUISystem")
    if old then old:Destroy() end
    local oldMenu = playerGui:FindFirstChild("ExodusMenuLayer")
    if oldMenu then oldMenu:Destroy() end
  end
  UIState.lifecycleGeneration += 1; UIState.panelOpen = false
  UIState.spamOn = false; UIState.clashBallOn = false
  UIState.closing = false; UIState.reducedMotion = detectReducedMotion()
  UIState.desktop = UIS.KeyboardEnabled or UIS.MouseEnabled or not UIS.TouchEnabled; UIState.panelTween = nil
  UIState.btnTween = nil; shortcutLabels = {}
  _G.ExodusUICleanup = cleanupUI; _G.ExodusUIFadeOut = fadeOutForReplacement
  screenGui = inst("ScreenGui", {
    Name = "ExodusUISystem",
    DisplayOrder = 100,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = playerGui,
  })
  menuGui = inst("ScreenGui", {
    Name = "ExodusMenuLayer",
    DisplayOrder = 2147483647,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = playerGui,
  })
  local menuScale = inst("UIScale", { Scale = 1, Parent = menuGui }); responsiveScale = inst("UIScale", { Scale = 1, Parent = screenGui })
  local informationScale
  local informationResizers = {}
  local function updateResponsiveScale()
    local size = viewport(); local availableWidth = math.max(1, size.X - CONFIG.VIEWPORT_MARGIN * 2)
    local availableHeight = math.max(1, size.Y - CONFIG.VIEWPORT_MARGIN * 2); local scale = math.clamp(math.min(availableWidth / PW, availableHeight / PH), CONFIG.MIN_SCALE, 1)
    responsiveScale.Scale = scale; menuScale.Scale = scale
    if informationScale then informationScale.Scale = scale end
    for _, resize in ipairs(informationResizers) do
      resize()
    end
  end
  local currentCamera, cameraViewportConnection
  local function bindViewportCamera()
    if cameraViewportConnection then
      safeDisconnect(cameraViewportConnection); untrackConn(cameraViewportConnection)
      cameraViewportConnection = nil
    end
    currentCamera = workspace.CurrentCamera or Camera
    if currentCamera then cameraViewportConnection = trackConn(currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveScale)) end
    updateResponsiveScale()
  end
  trackConn(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewportCamera)); bindViewportCamera()
  local informationGui = inst("ScreenGui", {
    Name = "ExodusInformationOverlay",
    DisplayOrder = 2147483646,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Global,
    Parent = playerGui,
  })
  informationScale = inst("UIScale", { Scale = responsiveScale.Scale, Parent = informationGui }); updateResponsiveScale()
  toastLayer = inst("Frame", {
    Name = "ExodusToastLayer",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ZIndex = 199,
    Parent = informationGui,
  })
  local textService = TextService
  local function compactInformation(label)
    local paddingX, paddingY = 8, 5; label.TextSize = 14
    label.TextWrapped = false; label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top; label.BorderSizePixel = 0
    label.ZIndex = 100
    local padding = inst("UIPadding", {
      PaddingLeft = UDim.new(0, paddingX),
      PaddingRight = UDim.new(0, paddingX),
      PaddingTop = UDim.new(0, paddingY),
      PaddingBottom = UDim.new(0, paddingY),
      Parent = label,
    })
    local function resize()
      local scale = responsiveScale and math.max(responsiveScale.Scale, 0.01) or 1; local maxWidth = math.min(360, math.max(160, (viewport().X - CONFIG.VIEWPORT_MARGIN * 2) / scale))
      local bounds = textService:GetTextSize(label.Text, label.TextSize, label.Font, Vector2.new(maxWidth - paddingX * 2, 1000)); label.TextWrapped = bounds.X >= maxWidth - paddingX * 2
      label.Size = UDim2.fromOffset(math.min(maxWidth, math.ceil(bounds.X) + paddingX * 2), math.ceil(bounds.Y) + paddingY * 2)
    end
    informationResizers[#informationResizers + 1] = resize; trackConn(label:GetPropertyChangedSignal("Text"):Connect(resize))
    resize()
  end
  UIState.distanceVisible = Utils.getConfigValue("ClashDistanceVisible") == true; UIState.travelVisible = Utils.getConfigValue("ClashTravelTimeVisible") == true
  UIState.gatesVisible = Utils.getConfigValue("AutoSpamGatesVisible") == true
  local distanceLabel = inst("TextLabel", {
    Name = "ClashDistance",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, CONFIG.VIEWPORT_MARGIN),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 0.2,
    Text = "Current SPD: —\nClash: —\nCPS: —",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = UIState.distanceVisible,
    ZIndex = 20,
    Parent = informationGui,
  })
  local travelLabel = inst("TextLabel", {
    Name = "ClashTravelTime",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -CONFIG.VIEWPORT_MARGIN),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 0.2,
    Text = "Ball travel time: —",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = UIState.travelVisible,
    ZIndex = 20,
    Parent = informationGui,
  })
  local gatesLabel = inst("TextLabel", {
    Name = "AutoSpamGates",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, CONFIG.VIEWPORT_MARGIN, 0.5, 0),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 0.2,
    Text = "Auto Spam\nActivation: —\nDeactivation: —",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = UIState.gatesVisible,
    ZIndex = 20,
    Parent = informationGui,
  })
  compactInformation(distanceLabel); compactInformation(travelLabel)
  compactInformation(gatesLabel); corner(distanceLabel, 8)
  corner(travelLabel, 8); corner(gatesLabel, 8)
  local nextTravelUpdate, nextDistanceUpdate, nextGatesUpdate = 0, 0, 0; local telemetryAt, telemetryStatus, telemetrySnapshot = -math.huge, nil, nil
  local function validNumber(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
  local function milliseconds(value, fallback) return validNumber(value) and string.format("%.0f ms", math.max(0, value) * 1000) or fallback end
  local function getTelemetry(time)
    if time < telemetryAt or time - telemetryAt >= 0.05 then
      telemetryAt = time; local statusOk, status = pcall(AutoSpam.getStatus)
      telemetryStatus = statusOk and status or nil; local snapshotOk, snapshot = pcall(GameInfo.getSnapshotAt, time)
      telemetrySnapshot = snapshotOk and snapshot or nil
    end
    return telemetryStatus, telemetrySnapshot
  end
  local function snapshotSpeed(snapshot)
    local validOk, valid = pcall(GameInfo.isSnapshotValid, snapshot)
    if not validOk or not valid then return nil end
    local speed = tonumber(snapshot.syncSpeed)
    if not validNumber(speed) or speed <= 0 then speed = snapshot.speed end
    return validNumber(speed) and speed >= 0 and speed or nil
  end
  local function renderTravel(time, status, snapshot)
    local stats = type(status) == "table" and type(status.clashStats) == "table" and status.clashStats or nil; local speed = snapshotSpeed(snapshot)
    local speedText = validNumber(speed) and string.format("%.0f", speed) or "—"
    if not stats then setTextIfChanged(travelLabel, "Current SPD: " .. speedText .. "\nBall travel time: —"); return end
    local me = Players.LocalPlayer and Players.LocalPlayer.UserId
    local text
    if stats.frozen then
      if stats.deceasedId then
        local who = stats.deceasedId == me and "You" or "Opponent"; local previousWho = stats.penultimateTarget == me and "you" or (stats.penultimateTarget == stats.partnerId and "opponent" or "—")
        text = who
          .. " died\nTarget time to death: "
          .. milliseconds(stats.fatalTravelTime, "unavailable")
          .. "\nPrevious ("
          .. previousWho
          .. "): "
          .. milliseconds(stats.penultimateTravelTime, "unavailable")
      else
        text = "Clash ended\nFinal time: unavailable"
      end
    else
      local elapsed = validNumber(stats.travelStartedAt) and milliseconds(math.max(0, time - stats.travelStartedAt), "—") or "—"
      local who = stats.travelTarget == me and "You" or (stats.travelTarget == stats.partnerId and "Opponent" or "—"); local last = milliseconds(stats.lastTravelTime, "—")
      local lastWho = stats.lastTravelTarget == me and "you" or (stats.lastTravelTarget == stats.partnerId and "opponent" or "—")
      text = "Target: " .. who .. " | Time: " .. elapsed .. "\nLast exchange (" .. lastWho .. "): " .. last
    end
    setTextIfChanged(travelLabel, "Current SPD: " .. speedText .. "\n" .. text)
  end
  local function renderDistance(status, snapshot)
    local stats = type(status) == "table" and type(status.clashStats) == "table" and status.clashStats or nil; local speed = snapshotSpeed(snapshot)
    local speedText = validNumber(speed) and string.format("%.0f", speed) or "—"
    local function sampleText(sample)
      if type(sample) ~= "table" then return "—" end
      local distance = validNumber(sample.distance) and string.format("%.1f", sample.distance) or "?"; local sampleSpeed = validNumber(sample.speed) and string.format("%.0f", sample.speed) or "?"
      return distance .. " studs | SPD " .. sampleSpeed
    end
    local text
    if stats and (not stats.frozen or stats.endReason == "jogador morreu") then
      local cps = validNumber(stats.currentCps) and string.format("%.2f", stats.currentCps) or "—"; local duration = validNumber(stats.duration) and stats.duration or 0
      local result = stats.frozen
          and (stats.endReason == "jogador morreu" and "Player died" or (stats.endReason == "oponente morreu" and "Opponent died" or "End"))
        or "Current"
      text = string.format(
        "Current SPD: %s\nStart: %s\n%s: %s\nCurrent CPS: %s | %.2fs",
        speedText,
        sampleText(stats.startSample),
        result,
        sampleText(stats.endSample),
        cps,
        duration
      )
    else
      text = "Current SPD: " .. speedText .. "\nClash: —\nCurrent CPS: —"
    end
    setTextIfChanged(distanceLabel, text)
  end
  trackConn(RunService.Heartbeat:Connect(function()
    if not informationGui.Parent then return end
    if distanceLabel.Visible ~= UIState.distanceVisible then distanceLabel.Visible = UIState.distanceVisible end
    if travelLabel.Visible ~= UIState.travelVisible then travelLabel.Visible = UIState.travelVisible end
    if not UIState.distanceVisible and not UIState.travelVisible and not UIState.gatesVisible then return end
    local time = os.clock()
    local status, snapshot
    if UIState.travelVisible and time >= nextTravelUpdate then
      nextTravelUpdate = time + 0.05; status, snapshot = getTelemetry(time)
      renderTravel(time, status, snapshot)
    end
    if UIState.distanceVisible and time >= nextDistanceUpdate then
      nextDistanceUpdate = time + 0.1
      if not status then status, snapshot = getTelemetry(time) end
      renderDistance(status, snapshot)
    end
    if UIState.gatesVisible and time >= nextGatesUpdate then
      nextGatesUpdate = time + 0.2
      if not status then local ok, result = pcall(AutoSpam.getStatus); status = ok and result or nil end
      local activation = type(status) == "table" and status.lastActivationReason or nil; local deactivation = type(status) == "table" and status.lastStopReason or nil
      setTextIfChanged(gatesLabel, "Auto Spam\nActivation: " .. tostring(activation or "—") .. "\nDeactivation: " .. tostring(deactivation or "—"))
    end
  end))
  bindInput()
  floatingButton = inst("TextButton", {
    Visible = false,
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
  corner(floatingButton, 999); local floatingStroke = stroke(floatingButton, C.accent, 2)
  registerFlow(floatingStroke); local config = Utils.getConfig()
  local clashX = config.ClashBallX or 14; local clashY = config.ClashBallY or (viewport().Y / 2 - CLASH_SIZE / 2)
  clashBall = inst("TextButton", {
    Name = "ExodusClashBall",
    Visible = not UIState.desktop and config.ClashBallVisible == true,
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
  corner(clashBall, 999); stroke(clashBall, Color3.new(0, 0, 0), 2)
  UIState.clashBallOn = config.AutoSpam or false; clashBall.Text = UIState.clashBallOn and "ON" or "OFF"
  clashBall.TextSize = UIState.clashBallOn and 18 or 16; clashBall.BackgroundColor3 = UIState.clashBallOn and C.green or C.red
  paintClashBall(); local parryX = config.ParryBallX or 14
  local parryY = config.ParryBallY or (viewport().Y / 2 - CLASH_SIZE - 40)
  parryBall = inst("TextButton", {
    Name = "ExodusParryBall",
    Visible = not UIState.desktop and config.ParryBallVisible == true,
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
  paintParryBall(config.AutoParry == true)
  local isParryDragging = makeDraggable(parryBall, parryBall, function()
    setConfigValue("ParryBallX", parryBall.Position.X.Offset); setConfigValue("ParryBallY", parryBall.Position.Y.Offset)
  end)
  trackConn(parryBall.Activated:Connect(function()
    if not isParryDragging() then
      local value = Utils.getConfigValue("AutoParry") ~= true
      if setConfigValue("AutoParry", value) and showToast then showToast("Auto Parry " .. (value and "On" or "Off")) end
    end
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
    Visible = not UIState.desktop and config.DarkBallVisible == true,
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
  paintDarkBall(config.AutoDark == true)
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
  upDashBall, upDashX, upDashY = createMovementBall("ExodusUpDashBall", "DASH\n↑", C.upDash, "UpDashBallX", "UpDashBallY", CLASH_SIZE / 2 + 8, function(ball)
    if type(Controls.onUpDash) == "function" then Controls.onUpDash() end
    pulseBall(ball)
    if showToast then showToast("Up Dash") end
  end)
  jumpBall.Visible = not UIState.desktop and config.JumpBallVisible == true; upDashBall.Visible = not UIState.desktop and config.UpDashBallVisible == true
  paintJumpBall(config.AutoJump == true); local miniY = config.MiniY or (viewport().Y / 2 - MINI_H / 2)
  local MINI_OFF_X = viewport().X + 30
  miniGui = inst("Frame", {
    Name = "ExodusSpamMini",
    Visible = not UIState.desktop and config.MiniSpamVisible == true,
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
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Center,
    Font = Enum.Font.GothamBold,
    ZIndex = 17,
    Parent = miniTitleBar,
  })
  local spamButton = inst("TextButton", {
    Name = "SpamButton",
    Size = UDim2.new(1, -16, 0, 48),
    Position = UDim2.new(0, 8, 0, 32),
    BackgroundColor3 = UIState.spamOn and C.green or C.red,
    BorderSizePixel = 0,
    Text = UIState.spamOn and "ON" or "OFF",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 24,
    Font = Enum.Font.GothamBold,
    ZIndex = 16,
    Parent = miniGui,
  })
  corner(spamButton, 10)
  trackConn(spamButton.Activated:Connect(function() setSpam(not UIState.spamOn) end))
  miniGui.Position = UDim2.new(0, MINI_OFF_X, 0, miniY)
  makeDraggable(miniTitleBar, miniGui, function()
    setConfigValue("MiniX", miniGui.Position.X.Offset); setConfigValue("MiniY", miniGui.Position.Y.Offset)
  end)
  configPanel = inst("CanvasGroup", {
    Name = "ExodusPanel",
    Size = UDim2.new(0, PW, 0, PH),
    Position = panelPos(),
    BackgroundColor3 = C.bg,
    BackgroundTransparency = 0.03,
    GroupTransparency = 0,
    Visible = false,
    ZIndex = 5,
    ClipsDescendants = true,
    Parent = menuGui,
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
  if not UIState.reducedMotion then
    local particleGeneration = UIState.lifecycleGeneration
    _spawn(function()
      while particleGeneration == UIState.lifecycleGeneration and configPanel == particlePanel and particlePanel.Parent do
        _wait(math.random() * 0.6 + 0.15)
        if particleGeneration == UIState.lifecycleGeneration and configPanel == particlePanel and particlePanel.Parent and particlePanel.Visible then spawnParticle() end
      end
    end)
  end
  titleBar = inst("Frame", {
    Size = UDim2.new(1, 0, 0, TITLE_H),
    BackgroundColor3 = C.header,
    BorderSizePixel = 0,
    Active = true,
    ZIndex = 6,
    Parent = configPanel,
  })
  corner(titleBar, 16)
  local headerAccent = inst("Frame", {
    Size = UDim2.new(0.42, 0, 0, 2),
    Position = UDim2.new(0.29, 0, 1, -2),
    BackgroundColor3 = C.accentPink,
    BorderSizePixel = 0,
    ZIndex = 8,
    Parent = titleBar,
  })
  corner(headerAccent, 2)
  local readyBadge = inst("TextLabel", {
    Size = UDim2.fromOffset(66, 22),
    Position = UDim2.fromOffset(PAD, 14),
    BackgroundColor3 = C.surface,
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Text = "● READY",
    TextColor3 = C.green,
    TextSize = 9,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 8,
    Parent = titleBar,
  })
  corner(readyBadge, 999); stroke(readyBadge, C.borderSubtle, 1)
  makeDraggable(titleBar, configPanel, function()
    setConfigValue("PanelX", configPanel.Position.X.Offset); setConfigValue("PanelY", configPanel.Position.Y.Offset)
  end)
  local titleText = Utils.name(); local authorText = ("v%s  •  %s"):format(Utils.version(), Utils.author())
  local titleFontSize, authorFontSize = CONFIG.TITLE_TEXT_SIZE, CONFIG.AUTHOR_TEXT_SIZE
  local titleGroup = inst("Frame", {
    Size = UDim2.new(1, -CONFIG.TITLE_SIDE_MARGIN * 2, 1, 0),
    Position = UDim2.new(0, CONFIG.TITLE_SIDE_MARGIN, 0, 0),
    BackgroundTransparency = 1,
    ZIndex = 7,
    Parent = titleBar,
  })
  inst("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, CONFIG.TITLE_SPACING),
    Parent = titleGroup,
  })
  inst("TextLabel", {
    Size = UDim2.new(0, 0, 1, 0),
    LayoutOrder = 1,
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundTransparency = 1,
    Text = titleText,
    TextColor3 = C.text,
    TextSize = titleFontSize,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 7,
    Parent = titleGroup,
  })
  inst("TextLabel", {
    Size = UDim2.new(0, 0, 1, 0),
    LayoutOrder = 2,
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundTransparency = 1,
    Text = authorText,
    TextColor3 = C.subtext,
    TextTransparency = CONFIG.AUTHOR_TRANSPARENCY,
    TextSize = authorFontSize,
    Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
    Parent = titleGroup,
  })
  minimizeButton = inst("TextButton", {
    Size = UDim2.new(0, 30, 0, 30),
    Position = UDim2.new(1, -PAD - 30, 0.5, -15),
    BackgroundColor3 = C.btnDark,
    BackgroundTransparency = 0.3,
    Text = "—",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = titleBar,
  })
  corner(minimizeButton, 8)
  trackConn(minimizeButton.MouseEnter:Connect(function() twPlay(minimizeButton, CONFIG.MOTION.FAST, { BackgroundTransparency = 0 }) end))
  trackConn(minimizeButton.MouseLeave:Connect(function() twPlay(minimizeButton, CONFIG.MOTION.FAST, { BackgroundTransparency = 0.3 }) end))
  trackConn(minimizeButton.Activated:Connect(function()
    if UIState.panelOpen then togglePanel(true) end
  end))
  local settingsButton = inst("TextButton", {
    Name = "HubSettingsButton",
    Size = UDim2.new(0, 30, 0, 30),
    Position = UDim2.new(1, -PAD - 66, 0.5, -15),
    BackgroundColor3 = C.btnDark,
    BackgroundTransparency = 0.3,
    Text = "⚙",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 18,
    Font = Enum.Font.GothamBold,
    ZIndex = 9,
    Parent = titleBar,
  })
  corner(settingsButton, 8); local pageGroups = {}
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
  local pageDetails = {
    { "Control center", "Core reactions and quick controls" },
    { "Game settings", "Timing, visibility and presentation" },
    { "Utilities", "Small tools for a smoother session" },
    { "Automatic", "Optional assistance and automation" },
  }

  for index, detail in ipairs(pageDetails) do
    local group = pageGroups[index]
    inst("TextLabel", {
      Size = UDim2.new(1, 0, 0, 18),
      Position = UDim2.fromOffset(0, 0),
      BackgroundTransparency = 1,
      Text = detail[1],
      TextColor3 = C.text,
      TextSize = 14,
      Font = Enum.Font.GothamBold,
      TextXAlignment = Enum.TextXAlignment.Left,
      ZIndex = 7,
      Parent = group,
    })
    inst("TextLabel", {
      Size = UDim2.new(1, 0, 0, 16),
      Position = UDim2.fromOffset(0, 18),
      BackgroundTransparency = 1,
      Text = detail[2],
      TextColor3 = C.muted,
      TextSize = 10,
      Font = Enum.Font.Gotham,
      TextXAlignment = Enum.TextXAlignment.Left,
      ZIndex = 7,
      Parent = group,
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
  colRight = inst("ScrollingFrame", {
    Size = UDim2.new(0, COL_W, 0, CONTENT_H),
    Position = UDim2.new(0, COL_W + GAP, 0, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    ZIndex = 6,
    Parent = pageGroups[1],
  })
  inst("Frame", {
    Size = UDim2.new(1, -PAD * 2, 0, 1),
    Position = UDim2.new(0, PAD, 1, -PAD - 34),
    BackgroundColor3 = C.borderSubtle,
    BorderSizePixel = 0,
    ZIndex = 7,
    Parent = configPanel,
  })
  inst("TextLabel", {
    Size = UDim2.new(1, -PAD * 2 - 270, 0, 26),
    Position = UDim2.fromOffset(PAD, PH - PAD - 26),
    BackgroundTransparency = 1,
    Text = "Changes apply instantly",
    TextColor3 = C.muted,
    TextSize = 10,
    Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
    ZIndex = 7,
    Parent = configPanel,
  })
  killBtn = inst("TextButton", {
    Size = UDim2.new(0, 124, 0, 26),
    Position = UDim2.new(1, -PAD - 124, 1, -PAD - 26),
    BackgroundColor3 = C.redDark,
    BackgroundTransparency = 0.15,
    Text = "Close Script",
    TextColor3 = Color3.fromRGB(255, 200, 200),
    TextSize = 11,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = configPanel,
  })
  corner(killBtn, 6)
  trackConn(killBtn.Activated:Connect(function() animateClose("close") end))
  reloadButton = makeBtn("Reload", 0, 0, 124, 26, configPanel, C.btnBlue); reloadButton.Name = "ReloadHub"
  reloadButton.Position = UDim2.new(1, -PAD - 256, 1, -PAD - 26); reloadButton.TextSize = 11
  trackConn(reloadButton.Activated:Connect(function() animateClose("reload") end))
  local yL = 4
  local toggleCallbacks = {
    AutoParry = paintParryBall,
    ParryBallVisible = showParryBall,
    AutoSpam = function(value)
      setClashBall(value, true); paintClashBall()
    end,
    ClashBallVisible = showClashBall,
  }

  local shortcutByConfig = { AutoParry = "ParryKeybind", AutoSpam = "ClashKeybind" }
  for _, definition in ipairs(UIConfig.panelToggles) do
    if definition.kind == "toggle" and not (UIState.desktop and definition.mobileOnly) then
      yL = createToggleCard(definition.label, definition.key, yL, colLeft, toggleCallbacks[definition.key], shortcutByConfig[definition.key])
    end
  end
  colLeft.CanvasSize = UDim2.new(0, 0, 0, yL); local yR = 4
  local components = {
    rate_selector = createRateSelector,
    keybind_selector = createKeybindSelector,
    off_on = function(yPos, parent, definition)
      local configKey = UIState.desktop and definition.desktopKey or definition.mobileKey
      return createOffOnCard(definition.label, yPos, parent, {
        configKey = configKey,
        shortcutKey = UIState.desktop and definition.shortcutKey or nil,
        rightAligned = UIState.desktop,
        onToggle = offOnCallbacks[configKey],
        toastLabel = UIState.desktop and nil or definition.mobileToast,
      })
    end,
  }

  for _, definition in ipairs(UIConfig.panelComponents) do
    local createComponent = components[definition.kind]
    if createComponent and (definition.kind ~= "keybind_selector" or UIState.desktop) then yR = createComponent(yR, colRight, definition) end
  end
  colRight.CanvasSize = UDim2.new(0, 0, 0, yR)
  local settingsLeft = inst("ScrollingFrame", {
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 3,
    BorderSizePixel = 0,
    Size = UDim2.new(0, COL_W, 0, CONTENT_H),
    Position = UDim2.new(0, 0, 0, 0),
    BackgroundTransparency = 1,
    Visible = true,
    ZIndex = 6,
    Parent = pageGroups[2],
  })
  local settingsRight = inst("ScrollingFrame", {
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 3,
    BorderSizePixel = 0,
    Size = UDim2.new(0, COL_W, 0, CONTENT_H),
    Position = UDim2.new(0, COL_W + GAP, 0, 0),
    BackgroundTransparency = 1,
    Visible = true,
    ZIndex = 6,
    Parent = pageGroups[2],
  })
  local utilities = inst("ScrollingFrame", {
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 3,
    BorderSizePixel = 0,
    Size = UDim2.new(0, COL_W, 0, CONTENT_H),
    Position = UDim2.new(0, 0, 0, 0),
    BackgroundTransparency = 1,
    Visible = true,
    ZIndex = 6,
    Parent = pageGroups[3],
  })
  local autosLeft = inst("ScrollingFrame", {
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 3,
    BorderSizePixel = 0,
    Size = UDim2.new(0, COL_W, 0, CONTENT_H),
    Position = UDim2.new(0, 0, 0, 0),
    BackgroundTransparency = 1,
    ZIndex = 6,
    Parent = pageGroups[4],
  })
  local autosRight = inst("ScrollingFrame", {
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 3,
    BorderSizePixel = 0,
    Size = UDim2.new(0, COL_W, 0, CONTENT_H),
    Position = UDim2.new(0, COL_W + GAP, 0, 0),
    BackgroundTransparency = 1,
    Visible = true,
    ZIndex = 6,
    Parent = pageGroups[4],
  })
  for _, content in ipairs({ colLeft, colRight, settingsLeft, settingsRight, utilities, autosLeft, autosRight }) do
    content.Size = UDim2.new(0, COL_W, 0, CONTENT_H - PAGE_HEAD_H); content.Position = UDim2.new(0, content.Position.X.Offset, 0, PAGE_HEAD_H)
  end
  local darkYPos, darkCard = createOffOnCard("Auto Dark", 4, autosLeft, {
    configKey = "AutoDark",
    shortcutKey = UIState.desktop and "DarkKeybind" or nil,
    rightAligned = UIState.desktop,
    onToggle = function(value)
      paintDarkBall(value)
      if type(Controls.onAutoDarkChanged) == "function" then Controls.onAutoDarkChanged() end
    end,
    toastLabel = "Auto Dark",
  })
  local fierceYPos, miniDarkCard = darkYPos, nil
  if not UIState.desktop then fierceYPos, miniDarkCard = createToggleCard("Mini Dark UI", "DarkBallVisible", fierceYPos, autosLeft, showDarkBall) end
  local autoFierceYPos, fierceCard = createOffOnCard("Auto Fierce", fierceYPos, autosLeft, { configKey = "AutoFierce", toastLabel = "Auto Fierce" })
  local jumpYPos, jumpCard = createOffOnCard("Auto Jump", 4, autosRight, {
    configKey = "AutoJump",
    shortcutKey = UIState.desktop and "JumpKeybind" or nil,
    rightAligned = UIState.desktop,
    onToggle = function(value)
      paintJumpBall(value)
      if type(Controls.onAutoJumpChanged) == "function" then Controls.onAutoJumpChanged() end
    end,
    toastLabel = "Auto Jump",
  })
  local dashYPos, miniJumpCard = jumpYPos, nil
  if not UIState.desktop then dashYPos, miniJumpCard = createToggleCard("Mini Auto Jump", "JumpBallVisible", dashYPos, autosRight, showJumpBall) end
  local upDashYPos, upDashCard = dashYPos, nil
  if UIState.desktop then
    upDashYPos, upDashCard = createActionShortcutCard("Up Dash", upDashYPos, autosRight, "UpDashKeybind", function()
      if type(Controls.onUpDash) == "function" then Controls.onUpDash() end
      if showToast then showToast("Up Dash") end
    end)
  else
    upDashYPos, upDashCard = createToggleCard("Mini Up Dash", "UpDashBallVisible", upDashYPos, autosRight, showUpDashBall)
  end
  local autoDashYPos, autoUpDashCard =
    createOffOnCard("Auto Dash (clash)", upDashYPos, autosRight, { configKey = "AutoClashUpDash", toastLabel = "Auto Dash (clash)" })
  local parryYPos = createParryTimingCard(4, settingsLeft); createCameraSensitivityCard(parryYPos, settingsLeft)
  local travelYPos = createToggleCard("Clash Distance", "ClashDistanceVisible", 4, settingsRight)
  local gatesYPos = createToggleCard("Ball travel time", "ClashTravelTimeVisible", travelYPos, settingsRight); createToggleCard("Auto Spam gates", "AutoSpamGatesVisible", gatesYPos, settingsRight)
  local function updateAbilityVisibility(enabled)
    for _, card in ipairs({ darkCard, miniDarkCard, jumpCard, miniJumpCard, upDashCard, fierceCard, autoUpDashCard }) do
      if card then card.Visible = enabled end
    end
    local config = Utils.getConfig(); darkBall.Visible = enabled and not UIState.desktop and config.DarkBallVisible == true
    upDashBall.Visible = enabled and not UIState.desktop and config.UpDashBallVisible == true
  end
  updateAbilityVisibility(GameInfo.areAbilitiesEnabled()); trackConn(GameInfo.observeAbilityMode(updateAbilityVisibility))
  local antiConnection
  local antiGeneration = 0; local utilitiesY = 4
  utilitiesY = createOffOnCard("Anti AFK", utilitiesY, utilities, {
    onToggle = function(enabled)
      if not enabled then
        antiGeneration += 1
        if antiConnection then
          antiConnection:Disconnect(); untrackConn(antiConnection)
          antiConnection = nil
        end
        return false
      end
      local player = Utils.getLocalPlayer(); local ok, virtualUser = pcall(game.GetService, game, "VirtualUser")
      if not player then Utils.recordError("AntiAFK", "Player unavailable"); return false end
      local function pulse()
        local inputOk, err = pcall(function()
          if not ok or not virtualUser then error("VirtualUser unavailable") end
          virtualUser:CaptureController(); virtualUser:ClickButton2(Vector2.new(0, 0))
        end)
        if not inputOk then
          local fallback, fallbackErr = pcall(function()
            local vim = game:GetService("VirtualInputManager"); vim:SendMouseButtonEvent(0, 0, 1, true, game, 0)
            vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
          end)
          if not fallback then Utils.recordError("AntiAFK", tostring(err) .. " | " .. tostring(fallbackErr)) end
        end
      end
      antiConnection = trackConn(player.Idled:Connect(pulse)); antiGeneration += 1
      local generation, uiGeneration = antiGeneration, UIState.lifecycleGeneration
      task.spawn(function()
        while generation == antiGeneration and uiGeneration == UIState.lifecycleGeneration and screenGui and screenGui.Parent and Utils.isActive() do
          task.wait(20)
          if generation == antiGeneration and uiGeneration == UIState.lifecycleGeneration and screenGui and screenGui.Parent and Utils.isActive() then pulse() end
        end
      end)
      return true
    end,
    toastLabel = "Anti AFK",
  })
  local spinActive, spinGeneration, spinButtons = nil, 0, {}; local spinModes = { { "Sword", "SwordCrate" }, { "Emote", "EmoteCrate" }, { "Explosion", "FinisherCrate" } }
  local function paintSpin()
    for _, mode in ipairs(spinModes) do
      if spinButtons[mode[2]] then
        spinButtons[mode[2]](spinActive == mode[2])
      end
    end
  end
  for index, mode in ipairs(spinModes) do
    local crate = mode[2]
    local setSpinVisual
    utilitiesY, _, setSpinVisual = createOffOnCard(mode[1], utilitiesY, utilities, {
      getState = function() return spinActive == crate end,
      onToggle = function(enabled)
        spinGeneration += 1
        if enabled then spinActive = crate elseif spinActive == crate then spinActive = nil end
        paintSpin()
        if not enabled then return false end
        local generation, uiGeneration = spinGeneration, UIState.lifecycleGeneration
        task.spawn(function()
          local network = GameInfo.createCrateNetwork()
          if generation ~= spinGeneration or uiGeneration ~= UIState.lifecycleGeneration or spinActive ~= crate then return end
          while
            generation == spinGeneration
            and uiGeneration == UIState.lifecycleGeneration
            and spinActive == crate
            and screenGui
            and screenGui.Parent
            and Utils.isActive()
          do
            local sent = GameInfo.spinCrate(
              network,
              crate,
              function() return generation == spinGeneration and uiGeneration == UIState.lifecycleGeneration and spinActive == crate end
            )
            if not sent then break end
            task.wait(0.3)
          end
        end)
        return true
      end,
      toastLabel = mode[1],
    })
    spinButtons[crate] = setSpinVisual
  end
  utilities.CanvasSize = UDim2.fromOffset(0, utilitiesY + CARD_GAP); utilities.CanvasPosition = Vector2.zero
  local hubSettingsGroup = inst("CanvasGroup", {
    Name = "HubSettingsView",
    Size = UDim2.new(0, PW - PAD * 2, 0, CONTENT_H),
    Position = UDim2.new(0, PAD, 0, TITLE_H + PAD),
    BackgroundTransparency = 1,
    GroupTransparency = 1,
    Visible = false,
    ClipsDescendants = true,
    ZIndex = 6,
    Parent = configPanel,
  })
  local hubSettings = inst("ScrollingFrame", {
    Name = "HubSettings",
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    Active = true,
    Parent = hubSettingsGroup,
    ZIndex = 6,
  })
  local settingsColumn = inst("Frame", {
    Name = "SettingsColumn",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 0),
    Size = UDim2.fromOffset(math.min(320, PW - PAD * 2 - 16), 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    ZIndex = 6,
    Parent = hubSettings,
  })
  inst("UIPadding", {
    PaddingTop = UDim.new(0, CARD_GAP),
    PaddingBottom = UDim.new(0, CARD_GAP),
    Parent = settingsColumn,
  })
  inst("UIListLayout", {
    FillDirection = Enum.FillDirection.Vertical,
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    Padding = UDim.new(0, CARD_GAP),
    Parent = settingsColumn,
  })
  local notificationKey = UIState.desktop and "DesktopNotifications" or "MobileNotifications"; local _, notificationsCard = createToggleCard("Notifications", notificationKey, 0, settingsColumn)
  local resetCard = cardFrame(0, CARD_H, settingsColumn)
  for index, card in ipairs({ notificationsCard, resetCard }) do
    card.LayoutOrder = index; card.Size = UDim2.new(1, -16, 0, CARD_H)
    local scale = card:FindFirstChildOfClass("UIScale")
    if scale then scale.Scale = 1 end
  end
  local resetButton = makeBtn("Reset settings", 10, 9, 0, 30, resetCard, C.redDark); resetButton.Name = "ResetSettings"
  resetButton.Size = UDim2.new(1, -20, 0, 30); local resetPending = false
  trackConn(resetButton.Activated:Connect(function()
    if not resetPending then
      resetPending = true; resetButton.Text = "Tap again to confirm"
      task.delay(3, function()
        if resetButton.Parent and resetPending then resetPending = false; resetButton.Text = "Reset settings" end
      end)
      return
    end
    resetPending = false; local ok, result = pcall(Utils.resetConfig)
    if not ok or not result then
      showToast("Reset failed", true); warn("[Exodus] Reset settings: " .. tostring(result))
      resetButton.Text = "Reset settings"; return
    end
    task.defer(function()
      if not screenGui or not screenGui.Parent then return end
      local rebuilt, detail = ExodusUI.setup(deps)
      if not rebuilt then warn("[Exodus] Reset UI: " .. tostring(detail)) end
    end)
  end))
  local page = 1; local settingsOpen = false
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
    Size = UDim2.new(0, 82, 0, 26),
    Position = UDim2.new(0, PAD + 34, 1, -PAD - 26),
    BackgroundTransparency = 1,
    Text = "1/4 Main",
    TextColor3 = C.text,
    TextSize = 9,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = configPanel,
  })
  local nextPage = inst("TextButton", {
    Name = "NextPage",
    Size = UDim2.new(0, 32, 0, 26),
    Position = UDim2.new(0, PAD + 118, 1, -PAD - 26),
    BackgroundColor3 = C.btnDark,
    Text = "›",
    TextColor3 = C.text,
    TextSize = 20,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = configPanel,
  })
  corner(previous, 6); corner(nextPage, 6)
  local pageNames = { "Main", "Settings", "Utilities", "Automatic" }
  local function updateNavigation()
    local canPrevious, canNext = page > 1, page < #pageGroups; previous.Visible = not settingsOpen
    nextPage.Visible = not settingsOpen; pageLabel.Visible = not settingsOpen
    pageLabel.Text = tostring(page) .. "/" .. tostring(#pageGroups) .. " " .. pageNames[page]; previous.TextTransparency = canPrevious and 0 or 0.62
    nextPage.TextTransparency = canNext and 0 or 0.62; previous.Active, nextPage.Active = canPrevious, canNext
    previous.AutoButtonColor, nextPage.AutoButtonColor = canPrevious, canNext
  end
  updateNavigation()
  local function changePage(direction)
    if settingsOpen or hubSettingsGroup.Visible then return end
    local target = page + direction
    if target < 1 or target > #pageGroups then return end
    page = target; UIState.pageGeneration += 1
    local generation = UIState.pageGeneration
    if page == 3 then utilities.CanvasPosition = Vector2.zero end
    for _, tween in ipairs(UIState.pageTweens) do
      safeCancel(tween)
    end
    UIState.pageTweens = {}; pageInputShield.Visible = true
    updateNavigation(); local playTween, _, onComplete = createTweenGroup()
    for index, group in ipairs(pageGroups) do
      if index == page then
        if not group.Visible then
          group.Position = UDim2.new(0, PAD + 20 * direction, 0, TITLE_H + PAD); group.GroupTransparency = 1
          group.Visible = true
        end
        local incoming = playTween(group, CONFIG.MOTION.PANEL, { Position = UDim2.new(0, PAD, 0, TITLE_H + PAD), GroupTransparency = 0 }, EASE_OUT, DIR_INOUT)
        if incoming then UIState.pageTweens[#UIState.pageTweens + 1] = incoming end
      elseif group.Visible then
        local outgoing =
          playTween(group, CONFIG.MOTION.PANEL, { Position = UDim2.new(0, PAD - 20 * direction, 0, TITLE_H + PAD), GroupTransparency = 1 }, EASE_OUT, DIR_INOUT)
        if outgoing then UIState.pageTweens[#UIState.pageTweens + 1] = outgoing end
      end
    end
    local function finish()
      if generation ~= UIState.pageGeneration or not pageInputShield.Parent then return end
      for index, group in ipairs(pageGroups) do
        group.Visible = index == page; group.GroupTransparency = index == page and 0 or 1
        group.Position = UDim2.new(0, PAD, 0, TITLE_H + PAD)
      end
      UIState.pageTweens = {}; pageInputShield.Visible = false
    end
    onComplete(finish)
  end
  trackConn(settingsButton.Activated:Connect(function()
    settingsOpen = not settingsOpen; UIState.pageGeneration += 1
    local generation = UIState.pageGeneration
    for _, tween in ipairs(UIState.pageTweens) do
      safeCancel(tween)
    end
    UIState.pageTweens = {}; pageInputShield.Visible = true
    local playTween, _, onComplete = createTweenGroup()
    local function animate(group, offset, transparency)
      local tween = playTween(group, CONFIG.MOTION.PANEL, {
        Position = UDim2.new(0, PAD + offset, 0, TITLE_H + PAD),
        GroupTransparency = transparency,
      }, EASE_OUT, DIR_INOUT)
      if tween then UIState.pageTweens[#UIState.pageTweens + 1] = tween end
    end
    for index, group in ipairs(pageGroups) do
      if not settingsOpen and index == page then
        if not group.Visible then
          group.Position = UDim2.new(0, PAD - 20, 0, TITLE_H + PAD); group.GroupTransparency = 1
          group.Visible = true
        end
        animate(group, 0, 0)
      elseif group.Visible then
        animate(group, -20, 1)
      end
    end
    if settingsOpen then
      if not hubSettingsGroup.Visible then
        hubSettingsGroup.Position = UDim2.new(0, PAD + 20, 0, TITLE_H + PAD); hubSettingsGroup.GroupTransparency = 1
        hubSettingsGroup.Visible = true
      end
      animate(hubSettingsGroup, 0, 0)
    else
      animate(hubSettingsGroup, 20, 1)
    end
    updateNavigation()
    onComplete(function()
      if generation ~= UIState.pageGeneration or not pageInputShield.Parent then return end
      for index, group in ipairs(pageGroups) do
        group.Visible = not settingsOpen and index == page; group.GroupTransparency = index == page and 0 or 1
        group.Position = UDim2.new(0, PAD, 0, TITLE_H + PAD)
      end
      hubSettingsGroup.Visible = settingsOpen; hubSettingsGroup.GroupTransparency = settingsOpen and 0 or 1
      hubSettingsGroup.Position = UDim2.new(0, PAD, 0, TITLE_H + PAD); UIState.pageTweens = {}
      pageInputShield.Visible = false
    end)
  end))
  trackConn(previous.Activated:Connect(function() changePage(-1) end))
  trackConn(nextPage.Activated:Connect(function() changePage(1) end))
  if not UIState.desktop and config.ClashBallVisible then twPlay(clashBall, CONFIG.MOTION.PANEL, { Position = UDim2.new(0, clashX, 0, clashY) }, EASE_OUT, DIR_OUT) end
  if not UIState.desktop and config.ParryBallVisible then twPlay(parryBall, CONFIG.MOTION.PANEL, { Position = UDim2.new(0, parryX, 0, parryY) }, EASE_OUT, DIR_OUT) end
  if not UIState.desktop and config.DarkBallVisible then twPlay(darkBall, CONFIG.MOTION.PANEL, { Position = UDim2.new(0, darkX, 0, darkY) }, EASE_OUT, DIR_OUT) end
  if not UIState.desktop and config.JumpBallVisible then twPlay(jumpBall, CONFIG.MOTION.PANEL, { Position = UDim2.new(0, jumpX, 0, jumpY) }, EASE_OUT, DIR_OUT) end
  if not UIState.desktop and config.UpDashBallVisible then twPlay(upDashBall, CONFIG.MOTION.PANEL, { Position = UDim2.new(0, upDashX, 0, upDashY) }, EASE_OUT, DIR_OUT) end
  if not UIState.desktop and config.MiniSpamVisible then
    twPlay(
      miniGui,
      CONFIG.MOTION.PANEL,
      { Position = UDim2.new(0, config.MiniX or (viewport().X - MINI_W - CONFIG.VIEWPORT_MARGIN), 0, miniY) },
      EASE_OUT,
      DIR_OUT
    )
  end
  if type(Utils.observeSpam) == "function" then
    trackConn(Utils.observeSpam(function()
      local manual = Utils.isManualSpamActive()
      UIState.spamOn = manual
      paintManualSpam()
    end))
  end
  if type(Utils.observeConfig) == "function" then
    trackConn(Utils.observeConfig(function(changes)
      for key, label in pairs(shortcutLabels) do
        if changes[key] ~= nil then label.Text = keyName(changes[key]) end
      end
      for key, setVisual in pairs(offOnVisuals) do
        if changes[key] ~= nil then setVisual(changes[key] == true) end
      end
      if changes.AutoSpam ~= nil then
        UIState.clashBallOn = changes.AutoSpam == true; paintClashBall()
        syncAutoSpamToggle()
      end
      if changes.AutoParry ~= nil then
        paintParryBall(changes.AutoParry == true)
        if autoParrySetVisual then autoParrySetVisual(changes.AutoParry == true) end
      end
      if changes.AutoDark ~= nil then
        paintDarkBall(changes.AutoDark == true)
        if autoDarkSetVisual then autoDarkSetVisual(changes.AutoDark == true) end
      end
      if changes.AutoJump ~= nil then paintJumpBall(changes.AutoJump == true) end
      if changes.ClashDistanceVisible ~= nil then UIState.distanceVisible = changes.ClashDistanceVisible == true; distanceLabel.Visible = UIState.distanceVisible end
      if changes.ClashTravelTimeVisible ~= nil then UIState.travelVisible = changes.ClashTravelTimeVisible == true; travelLabel.Visible = UIState.travelVisible end
      if changes.AutoSpamGatesVisible ~= nil then UIState.gatesVisible = changes.AutoSpamGatesVisible == true; gatesLabel.Visible = UIState.gatesVisible end
      if changes.ManualSpamEnabled ~= nil and UIState.desktop then
        if not changes.ManualSpamEnabled then setSpam(false) end
      end
    end))
  end
  local currentGui = screenGui
  local function refreshDevice()
    local desktop = UIS.KeyboardEnabled or UIS.MouseEnabled or not UIS.TouchEnabled
    if desktop == UIState.desktop or UIState.closing then return end
    task.defer(function()
      if screenGui ~= currentGui or not currentGui.Parent then return end
      ExodusUI.setup(deps)
    end)
  end
  for _, property in ipairs({ "KeyboardEnabled", "MouseEnabled", "TouchEnabled" }) do
    trackConn(UIS:GetPropertyChangedSignal(property):Connect(refreshDevice))
  end
  enhanceInteractiveControls(screenGui); enhanceInteractiveControls(menuGui)
  enhanceInteractiveControls(informationGui); updateResponsiveScale()
  setSpam(Utils.isManualSpamActive(), true); UIState.initialized = true
  if restoreMinimized then
    UIState.reopenAllowed = true; floatingButton.Visible = true
    floatingButton.BackgroundTransparency = 0.1; floatingButton.TextTransparency = 0
  else
    togglePanel()
  end
  return true
end

-- contract
ExodusUI.__contract = {
  requires = {
    Utils = "utils",
    UIConfig = "uiconfig",
    GameInfo = "gameinfo",
    AutoSpam = "autospam",
  },
  requiresMethods = {
    Utils = {
      "getConfig",
      "getConfigValue",
      "getLocalPlayer",
      "isActive",
      "isManualSpamActive",
      "setConfig",
      "resetConfig",
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
    GameInfo = {
      "areAbilitiesEnabled",
      "observeAbilityMode",
      "getSnapshotAt",
      "isSnapshotValid",
      "createCrateNetwork",
      "spinCrate",
    },
    AutoSpam = { "getStatus" },
  },
  requiresData = { UIConfig = { "panelToggles", "panelComponents" } },
  provides = { "setup" },
}

return ExodusUI
