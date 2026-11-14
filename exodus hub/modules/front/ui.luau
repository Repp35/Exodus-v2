-- [[ ui ]]

-- module
local ExodusUI = {}
local Utils
local UIConfig
local GameInfo
local AutoSpam
local UIKit
local UIPages
local UIActions
local Runtime
local uiKit
local pageController
local shellScope
local shellMotion
local Controls = {}
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Camera = workspace.CurrentCamera
local _wait = task.wait
local _spawn = task.spawn
local UIState = {
  connections = {},
  panelOpen = false,
  spamOn = false,
  clashBallOn = false,
  btnIsDragging = function() return false end,
  panelTween = nil,
  btnTween = nil,
  miniTween = nil,
  miniGeneration = 0,
  desktop = false,
  closing = false,
  toastGeneration = 0,
  toastTween = nil,
  keyCapture = false,
  manualHoldInput = nil,
}

local setSpam
local showToast
local showPersistentNotification
local clearPersistentNotification
local screenGui
local informationGui
local floatingButton
local floatingButtonStroke
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
local killBtn
local toastLayer
local toastCard
local toastLabel
local persistentGui
local persistentLayer
local persistentOrder = {}
local persistentTweens = {}
local persistentGeneration = 0
local responsiveScale
local outlineGradients = setmetatable({}, { __mode = "k" })
local fadeRestore, fadeEvent, fadeDone = {}, nil, false

-- configuration
local CONFIG = {}
local C, GRAD

-- helpers
local pulseButton
local function inst(cls, props, parent)
  local o = Instance.new(cls)
  if props then
    for k, v in pairs(props) do
      o[k] = v
    end
  end
  if parent then o.Parent = parent end
  local buttonName = props and props.Name
  if
    cls == "TextButton"
    and pulseButton
    and buttonName ~= "CardHitbox"
    and buttonName ~= "SpamButton"
    and buttonName ~= "ExodusFloatingButton"
    and buttonName ~= "ExodusClashBall"
    and buttonName ~= "ExodusParryBall"
    and buttonName ~= "ExodusDarkBall"
    and buttonName ~= "ExodusJumpBall"
    and buttonName ~= "ExodusUpDashBall"
  then
    pulseButton(o)
  end
  return o
end
local function corner(obj, r) return inst("UICorner", { CornerRadius = UDim.new(0, r) }, obj) end
local function stroke(obj, col, th)
  local line = inst("UIStroke", { Color = col, Thickness = th or 1 }, obj)
  if col == C.accent or col == C.border then
    local gradient = inst("UIGradient", { Rotation = 0 }, line)
    gradient.Color = ColorSequence.new({
      ColorSequenceKeypoint.new(0, GRAD[1]),
      ColorSequenceKeypoint.new(0.5, GRAD[2]),
      ColorSequenceKeypoint.new(1, GRAD[3]),
    })
    outlineGradients[gradient] = true
  end
  return line
end
local function twPlay(obj, duration, props)
  if not obj or obj.Parent == nil then return nil end
  if shellMotion and shellScope.alive then
    if obj:IsA("CanvasGroup") and props.GroupTransparency ~= nil then return shellMotion.group(obj, duration, props) end
    return shellMotion.play(obj, duration, props)
  end
  local profile = CONFIG.MOTION[type(duration) == "string" and duration or "control"]
  local tween = TweenService:Create(obj, TweenInfo.new(type(duration) == "number" and duration or profile.duration, profile.style, profile.direction), props); tween:Play()
  return tween
end
local function safeCancel(t)
  if t then t:Cancel() end
end
local function setTextIfChanged(label, text)
  if label.Text ~= text then label.Text = text end
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
local connectionIndexes = {}
local function trackConn(c)
  if c and type(c.Disconnect) == "function" and not connectionIndexes[c] then
    local index = #UIState.connections + 1; UIState.connections[index] = c
    connectionIndexes[c] = index
  end
  return c
end
local function untrackConn(c)
  local index = connectionIndexes[c]
  if not index then return end
  local last = #UIState.connections; local moved = UIState.connections[last]
  UIState.connections[index] = moved; UIState.connections[last] = nil
  connectionIndexes[c] = nil
  if index ~= last then connectionIndexes[moved] = index end
end
local function safeDisconnect(c)
  if c then c:Disconnect() end
end
pulseButton = function(button)
  local scale = inst("UIScale", { Name = "PressScale", Scale = 1 }, button)
  local activeTween
  trackConn(button.Activated:Connect(function()
    safeCancel(activeTween); scale.Scale = 1
    local tween = twPlay(scale, "press", { Scale = 0.94 }); activeTween = tween
    if not tween then return end
    local connection
    connection = trackConn(tween.Completed:Connect(function(playbackState)
      safeDisconnect(connection); untrackConn(connection)
      if playbackState == Enum.PlaybackState.Completed and button.Parent then activeTween = twPlay(scale, "feedback", { Scale = 1 }) end
    end))
  end))
end
local function disconnectUIConnections()
  for i = #UIState.connections, 1, -1 do
    local connection = UIState.connections[i]; safeDisconnect(connection)
    connectionIndexes[connection] = nil; UIState.connections[i] = nil
  end
end
local function watchTweens(tweens, callback)
  local pending, connections, finished = 0, {}, false
  local function finish()
    if finished then return end
    pending -= 1
    if pending > 0 then return end
    finished = true
    for _, connection in ipairs(connections) do
      safeDisconnect(connection); untrackConn(connection)
    end
    callback()
  end
  for _, tween in ipairs(tweens or {}) do
    if tween then pending += 1; connections[#connections + 1] = trackConn(tween.Completed:Connect(finish)) end
  end
  if pending == 0 then callback() end
  return pending
end
local function awaitTweens(tweens)
  local signal = Instance.new("BindableEvent")
  local pending = watchTweens(tweens, function() signal:Fire() end)
  if pending > 0 then signal.Event:Wait() end
  signal:Destroy()
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
    elseif isKey(input, spamKey) then
      if config.ManualSpamMode == "Hold" then
        if not UIState.manualHoldInput then UIState.manualHoldInput = input; setSpam(true) end
      else
        setSpam(not UIState.spamOn)
      end
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
  trackConn(UIS.InputEnded:Connect(function(input)
    local held = UIState.manualHoldInput
    if held and (held == input or (inputBinding(held) and inputBinding(held) == inputBinding(input))) then UIState.manualHoldInput = nil; setSpam(false) end
  end))
  trackConn(UIS.WindowFocusReleased:Connect(function()
    if UIState.manualHoldInput then UIState.manualHoldInput = nil; setSpam(false) end
  end))
end

-- dragging
local function makeDraggable(handle, target, onDragEnd, disableOnMobile, coordinateScale, onDragMove)
  local dragInput, dragOffX, dragOffY = nil, 0, 0; local state, wasDragged, startX, startY = "Idle", false, 0, 0
  local THRESH_SQ = CONFIG.DRAG_THRESHOLD_SQ
  trackConn(handle.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    if disableOnMobile and UIS.TouchEnabled then return end
    if state ~= "Idle" then return end
    state, wasDragged, dragInput = "Pressed", false, input; local abs = target.AbsolutePosition
    local anchor = target.AnchorPoint; dragOffX, dragOffY = input.Position.X - abs.X - target.AbsoluteSize.X * anchor.X, input.Position.Y - abs.Y - target.AbsoluteSize.Y * anchor.Y
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
      local vp, sz = viewport(), target.AbsoluteSize; local scale = coordinateScale and coordinateScale() or (responsiveScale and responsiveScale.Scale or 1)
      scale = math.max(scale, 0.01)
      target.Position = UDim2.new(
        0,
        math.clamp((input.Position.X - dragOffX) / scale, 0, math.max(0, (vp.X - sz.X) / scale)),
        0,
        math.clamp((input.Position.Y - dragOffY) / scale, 0, math.max(0, (vp.Y - sz.Y) / scale))
      )
      if onDragMove then onDragMove() end
    end
  end))
  trackConn(UIS.InputEnded:Connect(function(input)
    if input ~= dragInput or state == "Idle" then return end
    state, dragInput = "Idle", nil
    if wasDragged and onDragEnd then onDragEnd() end
    task.defer(function()
      if state == "Idle" then wasDragged = false end
    end)
  end))
  return function() return state == "Dragging" or wasDragged end
end

-- visuals
local function animateOutlines()
  local elapsed = 0
  trackConn(RunService.Heartbeat:Connect(function(dt)
    elapsed += dt
    if elapsed < 0.05 then return end
    elapsed = 0; local offset = Vector2.new(math.sin(os.clock() * 0.14) * 0.35, 0)
    for gradient in pairs(outlineGradients) do
      if gradient.Parent then gradient.Offset = offset else outlineGradients[gradient] = nil end
    end
  end))
end

-- floating-controls
local BTN_SIZE
local function btnPos()
  local config = Utils.getConfig(); local x, y = config.BtnX, config.BtnY
  if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
  return UDim2.new(1, -70, 0.5, -28)
end
local CLASH_SIZE, OFFSCREEN_X
local function paintBall(ball, value, onText, offText, onColor, offColor, onSize, offSize)
  if not ball or not ball.Parent then return end
  ball.Text = value and onText or offText
  if onSize then ball.TextSize = value and onSize or offSize end
  twPlay(ball, "control", { BackgroundColor3 = value and onColor or offColor })
end
local function paintParryBall(value) paintBall(parryBall, value, "PARRY\nON", "PARRY\nOFF", C.green, C.red, 14, 14) end
local function showBall(ball, visible, visibleKey, xKey, yKey, defaultX, defaultY)
  local config = Utils.getConfig(); local x = config[xKey] or defaultX
  local y = config[yKey] or defaultY; local shouldShow = visible and not UIState.desktop
  twPlay(ball, "control", { Position = shouldShow and UDim2.new(0, x, 0, y) or UDim2.new(0, OFFSCREEN_X, 0, y) })
end
local function pulseBall(ball)
  local shrink = twPlay(ball, "press", { Size = UDim2.new(0, CLASH_SIZE - 6, 0, CLASH_SIZE - 6) })
  if not shrink then return end
  local connection
  connection = trackConn(shrink.Completed:Connect(function(playbackState)
    safeDisconnect(connection); untrackConn(connection)
    if playbackState == Enum.PlaybackState.Completed and ball and ball.Parent then twPlay(ball, "feedback", { Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE) }) end
  end))
end
local function showParryBall(value) showBall(parryBall, value, "ParryBallVisible", "ParryBallX", "ParryBallY", 14, viewport().Y / 2 - CLASH_SIZE - 40) end
local function paintClashBall() paintBall(clashBall, UIState.clashBallOn, "ON", "OFF", C.green, C.red, 18, 16) end
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
  paintDarkBall(v); pulseBall(darkBall)
  if showToast then showToast("Auto Dark " .. (v and "On" or "Off")) end
end
local function showMovementBall(ball, visible, visibleKey, xKey, yKey, yOffset)
  showBall(ball, visible, visibleKey, xKey, yKey, CLASH_SIZE + 22, viewport().Y / 2 + yOffset)
end
local function showJumpBall(v) showMovementBall(jumpBall, v, "JumpBallVisible", "JumpBallX", "JumpBallY", -CLASH_SIZE / 2) end
local function showUpDashBall(v) showMovementBall(upDashBall, v, "UpDashBallVisible", "UpDashBallX", "UpDashBallY", CLASH_SIZE / 2 + 8) end
local function paintJumpBall(v) paintBall(jumpBall, v, "JUMP\nON", "JUMP\nOFF", C.jumpOn, C.jumpOff) end
local function setJumpBall(v)
  if not setConfigValue("AutoJump", v) then return end
  if type(Controls.onAutoJumpChanged) == "function" then Controls.onAutoJumpChanged() end
  paintJumpBall(v)
  if showToast then showToast("Auto Jump " .. (v and "On" or "Off")) end
end
local MINI_W, MINI_H
local function miniScreenScale() return responsiveScale and responsiveScale.Scale or 1 end
local function miniLayout(scale)
  local view, screenScale = viewport(), math.max(miniScreenScale(), 0.01); local screenWidth, screenHeight = view.X / screenScale, view.Y / screenScale
  local config = Utils.getConfig(); local width = math.min(MINI_W * scale * (tonumber(config.MiniSpamWidth) or 1), screenWidth)
  local height = math.min(MINI_H * scale * (tonumber(config.MiniSpamHeight) or 1), screenHeight); local x = math.clamp(config.MiniX or (screenWidth - width - 14), 0, math.max(0, screenWidth - width))
  local y = math.clamp(config.MiniY or (screenHeight / 2 - height / 2), 0, math.max(0, screenHeight - height)); return x, y, width, height, screenWidth
end
local function applyMiniScale(value)
  if not miniGui or not miniGui.Parent then return end
  local scale = math.clamp(tonumber(value) or 1, 0.5, 2); local x, y, width, height = miniLayout(scale)
  twPlay(miniGui, "feedback", { Size = UDim2.fromOffset(width, height) })
  if miniGui.Visible then twPlay(miniGui, "feedback", { Position = UDim2.fromOffset(x, y) }) end
end
local function showMini(v)
  if UIState.desktop then v = false end
  if not miniGui or not miniGui.Parent then return end
  local config = Utils.getConfig(); local miniX, miniY, _, _, screenWidth = miniLayout(tonumber(config.MiniSpamScale) or 1)
  local hiddenPosition = UDim2.new(0, screenWidth + 30, 0, miniY); UIState.miniGeneration += 1
  local generation = UIState.miniGeneration; safeCancel(UIState.miniTween)
  if v then
    if not miniGui.Visible then
      miniGui.Position = hiddenPosition; miniGui.GroupTransparency = 1
      miniGui.Visible = true
    end
    UIState.miniTween = twPlay(miniGui, "control", {
      Position = UDim2.new(0, miniX, 0, miniY),
      GroupTransparency = 0,
    })
    return UIState.miniTween
  end
  if UIState.manualHoldInput then UIState.manualHoldInput = nil; setSpam(false) end
  if not miniGui.Visible then return end
  local tween = twPlay(miniGui, "control", {
    Position = hiddenPosition,
    GroupTransparency = 1,
  })
  UIState.miniTween = tween
  if tween then
    local connection
    connection = trackConn(tween.Completed:Connect(function(playbackState)
      safeDisconnect(connection); untrackConn(connection)
      if playbackState == Enum.PlaybackState.Completed and generation == UIState.miniGeneration and miniGui and miniGui.Parent then miniGui.Visible = false end
    end))
  else
    miniGui.Visible = false
  end
  return tween
end
setSpam = function(v)
  UIState.spamOn = v; Utils.setManualSpamActive(v)
  local spamButton = miniGui and miniGui:FindFirstChild("SpamButton")
  if spamButton then
    spamButton.Text = v and "ON" or "OFF"; twPlay(spamButton, "control", { BackgroundColor3 = v and C.green or C.red })
    local shrink = twPlay(spamButton, "press", { Size = UDim2.new(1, -14, 0.78, -12) })
    if shrink then
      local connection
      connection = trackConn(shrink.Completed:Connect(function(playbackState)
        safeDisconnect(connection); untrackConn(connection)
        if playbackState == Enum.PlaybackState.Completed and spamButton.Parent then twPlay(spamButton, "feedback", { Size = UDim2.new(1, -12, 0.78, -8) }) end
      end))
    end
  end
end
local PW, PH, TITLE_H, PAD

-- panel
local function panelPos()
  local config = Utils.getConfig(); local x, y = config.PanelX, config.PanelY
  if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
  return UDim2.new(0.5, -PW / 2, 0.5, -PH / 2)
end
local PARTICLE_COLORS

-- cleanup
local function cleanupUI()
  if UIState.manualHoldInput and Utils then Utils.setManualSpamActive(false) end
  if pageController then pageController.destroy(); pageController = nil end
  if uiKit then uiKit.destroy(); uiKit = nil end
  if shellScope then
    shellScope.destroy(); shellScope = nil
    shellMotion = nil
  end
  table.clear(outlineGradients); safeCancel(UIState.panelTween)
  safeCancel(UIState.btnTween); safeCancel(UIState.miniTween)
  UIState.miniTween = nil; UIState.miniGeneration += 1
  disconnectUIConnections(); UIState.connections = {}
  table.clear(connectionIndexes); UIState.panelOpen = false
  UIState.clashBallOn = false; UIState.closing = false
  UIState.keyCapture = false; UIState.manualHoldInput = nil
  UIState.panelTween = nil; UIState.btnTween = nil
  UIState.toastGeneration += 1; safeCancel(UIState.toastTween)
  UIState.toastTween = nil
  UIState.btnIsDragging = function() return false end
  local current = screenGui
  if current then current:Destroy() end
  local overlay = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
  if overlay then
    local oldOverlay = overlay:FindFirstChild("ExodusInformationOverlay")
    if oldOverlay then oldOverlay:Destroy() end
  end
  informationGui = nil; clearPersistentNotification("closing")
  screenGui = nil; floatingButton = nil
  floatingButtonStroke = nil; clashBall = nil
  parryBall = nil; darkBall = nil
  jumpBall = nil; upDashBall = nil
  miniGui = nil; configPanel = nil
  toastCard = nil; toastLabel = nil
  particleLayer = nil; titleBar = nil
  minimizeButton = nil; reloadButton = nil
  killBtn = nil; toastLayer = nil
  responsiveScale = nil; fadeRestore, fadeEvent, fadeDone = {}, nil, false
  if _G.ExodusUICleanup == cleanupUI then
    _G.ExodusUICleanup = nil; _G.ExodusUIFadeOut = nil
    _G.ExodusUIRestore = nil
  end
  if _G.ExodusShowPersistentNotification == showPersistentNotification then _G.ExodusShowPersistentNotification = nil end
  if _G.ExodusClearPersistentNotification == clearPersistentNotification then _G.ExodusClearPersistentNotification = nil end
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
  local endX = math.clamp(dot.Position.X.Scale + (math.random() - 0.5) * 0.15, 0, 1); twPlay(dot, "panel", { BackgroundTransparency = math.max(startTrans - 0.1, 0.05) })
  local travel = twPlay(dot, dur, {
    Position = UDim2.new(endX, 0, -0.1, 0),
    BackgroundTransparency = 1,
  })
  if travel then
    local connection
    connection = trackConn(travel.Completed:Connect(function()
      safeDisconnect(connection); untrackConn(connection)
      if dot.Parent then dot:Destroy() end
    end))
  end
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

-- notifications
local function persistentKey(value) return tostring(value or "general"):gsub("[^%w_%-]", "_") end
local function persistentPalette(kind)
  if kind == "critical" then return C.redDark, C.red end
  if kind == "success" then return Color3.fromRGB(20, 92, 58), C.green end
  if kind == "warning" then return Color3.fromRGB(100, 67, 18), Color3.fromRGB(245, 158, 11) end
  return C.btnBlue, C.accent
end
local function persistentLayerForPlayer()
  local player = Players.LocalPlayer; local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
  if not playerGui then return nil end
  persistentGui = playerGui:FindFirstChild("ExodusPersistentNotifications")
  if not persistentGui then
    persistentGui = inst("ScreenGui", {
      Name = "ExodusPersistentNotifications",
      DisplayOrder = 2147483647,
      ResetOnSpawn = false,
      IgnoreGuiInset = true,
      ZIndexBehavior = Enum.ZIndexBehavior.Global,
      Parent = playerGui,
    })
  end
  persistentLayer = persistentGui:FindFirstChild("NotificationLayer")
  if not persistentLayer then
    persistentLayer = inst("Frame", {
      Name = "NotificationLayer",
      Size = UDim2.fromScale(1, 1),
      BackgroundTransparency = 1,
      ZIndex = 100,
      Parent = persistentGui,
    })
  end
  for _, child in ipairs(persistentLayer:GetChildren()) do
    local key = child:GetAttribute("ExodusNotificationKey")
    if key and not table.find(persistentOrder, key) then persistentOrder[#persistentOrder + 1] = key end
  end
  return persistentLayer
end
local function reflowPersistentNotifications(animated)
  local layer = persistentLayer or persistentLayerForPlayer()
  if not layer then return end
  for index = #persistentOrder, 1, -1 do
    local key = persistentOrder[index]
    if not layer:FindFirstChild("Notification_" .. key) then table.remove(persistentOrder, index) end
  end
  for index, key in ipairs(persistentOrder) do
    local card = layer:FindFirstChild("Notification_" .. key)
    if card then
      safeCancel(persistentTweens[key]); local target = UDim2.new(0.5, 0, 1, -24 - (index - 1) * 46)
      persistentTweens[key] = twPlay(card, animated and "control" or 0, { Position = target, GroupTransparency = 0 })
    end
  end
end
clearPersistentNotification = function(key)
  local safeKey = persistentKey(key); local layer = persistentLayer
  if not layer then
    local player = Players.LocalPlayer; local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local gui = playerGui and playerGui:FindFirstChild("ExodusPersistentNotifications"); layer = gui and gui:FindFirstChild("NotificationLayer")
  end
  if not layer then return end
  local card = layer:FindFirstChild("Notification_" .. safeKey)
  for index = #persistentOrder, 1, -1 do
    if persistentOrder[index] == safeKey then table.remove(persistentOrder, index) end
  end
  if not card then
    persistentTweens[safeKey] = nil; reflowPersistentNotifications(true)
    return
  end
  safeCancel(persistentTweens[safeKey])
  local fade = twPlay(card, "control", {
    Position = UDim2.new(card.Position.X.Scale, card.Position.X.Offset, card.Position.Y.Scale, card.Position.Y.Offset + 18),
    GroupTransparency = 1,
  })
  persistentTweens[safeKey] = fade
  local function remove()
    if persistentTweens[safeKey] ~= fade then return end
    persistentTweens[safeKey] = nil
    if card.Parent then card:Destroy() end
    reflowPersistentNotifications(true)
  end
  if fade then
    local connection
    connection = fade.Completed:Connect(function()
      safeDisconnect(connection); remove()
    end)
  else
    remove()
  end
end
showPersistentNotification = function(message, key, kind, duration)
  local safeKey = persistentKey(key or message); local layer = persistentLayerForPlayer()
  if not layer then return false end
  local card = layer:FindFirstChild("Notification_" .. safeKey); local background, border = persistentPalette(kind)
  if not card then
    card = inst("CanvasGroup", {
      Name = "Notification_" .. safeKey,
      AnchorPoint = Vector2.new(0.5, 1),
      Position = UDim2.new(0.5, 0, 1, 18),
      Size = UDim2.fromOffset(320, 38),
      BackgroundColor3 = background,
      BackgroundTransparency = 0.12,
      GroupTransparency = 1,
      ZIndex = 100,
      Parent = layer,
    })
    card:SetAttribute("ExodusNotificationKey", safeKey); corner(card, 10)
    stroke(card, border, 1)
    inst("TextLabel", {
      Name = "Message",
      Size = UDim2.new(1, -20, 1, 0),
      Position = UDim2.fromOffset(10, 0),
      BackgroundTransparency = 1,
      TextColor3 = Color3.new(1, 1, 1),
      TextSize = 13,
      Font = Enum.Font.GothamBold,
      TextXAlignment = Enum.TextXAlignment.Center,
      TextYAlignment = Enum.TextYAlignment.Center,
      ZIndex = 101,
      Parent = card,
    })
    persistentOrder[#persistentOrder + 1] = safeKey
  end
  card.BackgroundColor3 = background; local cardStroke = card:FindFirstChildOfClass("UIStroke")
  if cardStroke then cardStroke.Color = border end
  local label = card:FindFirstChild("Message")
  if label then label.Text = tostring(message) end
  if duration == nil and safeKey ~= "dumper" then duration = 2.5 end
  persistentGeneration += 1; local generation = persistentGeneration
  card:SetAttribute("ExodusNotificationGeneration", generation); reflowPersistentNotifications(true)
  if duration and duration > 0 then
    task.delay(duration, function()
      if card.Parent and card:GetAttribute("ExodusNotificationGeneration") == generation then clearPersistentNotification(safeKey) end
    end)
  end
  return true
end
showToast = function(message, important)
  local notificationKey = UIState.desktop and "DesktopNotifications" or "MobileNotifications"
  if not important and Utils.getConfigValue(notificationKey) ~= true then return end
  if not toastLayer or not toastLayer.Parent then return end
  UIState.toastGeneration += 1; local generation = UIState.toastGeneration
  safeCancel(UIState.toastTween); local isOff = string.find(tostring(message), " Off", 1, true) ~= nil
  if not toastCard or not toastCard.Parent or toastCard.Parent ~= toastLayer then
    toastCard = inst("CanvasGroup", {
      Name = "ExodusToast",
      AnchorPoint = Vector2.new(0.5, 1),
      Position = UDim2.new(0.5, 0, 1, 18),
      Size = UDim2.fromOffset(190, 34),
      BackgroundTransparency = 0.18,
      GroupTransparency = 1,
      ZIndex = 200,
      Parent = toastLayer,
    })
    corner(toastCard, 10); stroke(toastCard, C.accent, 1)
    toastLabel = inst("TextLabel", {
      Size = UDim2.new(1, -16, 1, 0),
      Position = UDim2.new(0, 8, 0, 0),
      BackgroundTransparency = 1,
      TextColor3 = Color3.new(1, 1, 1),
      TextSize = 13,
      Font = Enum.Font.GothamBold,
      TextXAlignment = Enum.TextXAlignment.Center,
      ZIndex = 201,
      Parent = toastCard,
    })
  end
  toastCard.BackgroundColor3 = isOff and C.redDark or C.btnBlue; local toastStroke = toastCard:FindFirstChildOfClass("UIStroke")
  if toastStroke then toastStroke.Color = isOff and C.red or C.accent end
  if toastLabel then toastLabel.Text = tostring(message) end
  toastCard.Position = UDim2.new(0.5, 0, 1, 18); toastCard.GroupTransparency = 1
  local toast = toastCard; UIState.toastTween = twPlay(toast, "control", { Position = UDim2.new(0.5, 0, 1, -24), GroupTransparency = 0 })
  task.delay(1.35, function()
    if generation ~= UIState.toastGeneration or not toast.Parent then return end
    local fade = twPlay(toast, "control", { Position = UDim2.new(0.5, 0, 1, 18), GroupTransparency = 1 }); UIState.toastTween = fade
    if fade then
      local connection
      connection = trackConn(fade.Completed:Connect(function(playbackState)
        safeDisconnect(connection); untrackConn(connection)
        if playbackState ~= Enum.PlaybackState.Completed then return end
        if generation == UIState.toastGeneration and toast == toastCard then
          toastCard = nil; toastLabel = nil
          UIState.toastTween = nil
          if toast.Parent then toast:Destroy() end
        end
      end))
    end
  end)
end

-- public-components
local Components = {}
for _, name in ipairs({
  "label",
  "button",
  "textInput",
  "number",
  "toggle",
  "divider",
  "progressBar",
  "dropdown",
  "slider",
  "segmented",
  "tabs",
  "rate_selector",
}) do
  Components[name] = function(parent, options)
    assert(uiKit, "Call ExodusUI.setup before creating components, or use UIKit.create for a standalone library"); return uiKit.Components[name](parent, options)
  end
end
ExodusUI.Components = Components
local function togglePanel()
  if not configPanel or not configPanel.Parent or not floatingButton or not floatingButton.Parent then return end
  UIState.panelOpen = not UIState.panelOpen; safeCancel(UIState.panelTween)
  safeCancel(UIState.btnTween)
  if uiKit then uiKit.dismiss() end
  if pageController then pageController.suspend() end
  if UIState.panelOpen then
    if not configPanel.Visible then configPanel.GroupTransparency = 1; configPanel.Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97) end
    configPanel.Visible = true; UIState.panelTween = twPlay(configPanel, "panel", { Size = UDim2.new(0, PW, 0, PH), GroupTransparency = 0 })
    UIState.btnTween = twPlay(floatingButton, "control", { BackgroundTransparency = 0.6, TextTransparency = 0, Size = UDim2.new(0, 44, 0, 44) })
  else
    UIState.panelTween = twPlay(configPanel, "panel", { Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97), GroupTransparency = 1 })
    UIState.btnTween = twPlay(floatingButton, "control", { BackgroundTransparency = 0.1, TextTransparency = 0, Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE) })
    if UIState.panelTween then
      local conn
      conn = trackConn(UIState.panelTween.Completed:Connect(function()
        if not UIState.panelOpen then
          configPanel.Visible = false; configPanel.Size = UDim2.new(0, PW, 0, PH)
          configPanel.GroupTransparency = 0
        end
        safeDisconnect(conn); untrackConn(conn)
      end))
    else
      configPanel.Visible = false; configPanel.Size = UDim2.new(0, PW, 0, PH)
      configPanel.GroupTransparency = 0
    end
  end
end
local function restoreAfterReloadFailure(message)
  if not configPanel or not configPanel.Parent then return end
  if uiKit then uiKit.resume() end
  for object, properties in pairs(fadeRestore) do
    if object.Parent then
      for key, value in pairs(properties) do
        pcall(function() object[key] = value end)
      end
    end
  end
  fadeRestore, fadeEvent, fadeDone = {}, nil, false; UIState.closing = false
  UIState.panelOpen = true; configPanel.Visible = true
  configPanel.Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97); configPanel.GroupTransparency = 1
  if floatingButton and floatingButton.Parent then
    floatingButton.Size = UDim2.new(0, 42, 0, 42); floatingButton.BackgroundTransparency = 1
    floatingButton.TextTransparency = 1
  end
  twPlay(configPanel, "panel", { Size = UDim2.new(0, PW, 0, PH), GroupTransparency = 0 })
  if floatingButton and floatingButton.Parent then twPlay(floatingButton, "control", { BackgroundTransparency = 0.6, TextTransparency = 0, Size = UDim2.new(0, 44, 0, 44) }) end
  local config = Utils.getConfig()
  if not UIState.desktop then
    showClashBall(config.ClashBallVisible == true); showParryBall(config.ParryBallVisible == true)
    showDarkBall(config.DarkBallVisible == true); showJumpBall(config.JumpBallVisible == true)
    showUpDashBall(config.UpDashBallVisible == true); showMini(config.MiniSpamVisible == true)
  end
  if clearPersistentNotification then clearPersistentNotification("update") end
  if showPersistentNotification then showPersistentNotification("Update failed. Check the console.", "critical", "critical") end
  if showToast then showToast("Reload failed", true) end
  warn("[Exodus Reload] " .. tostring(message))
end
local function fadeGuiTree(root, tweens, duration)
  if not root or not root.Parent then return end
  local objects = { root }
  for _, object in ipairs(root:GetDescendants()) do
    objects[#objects + 1] = object
  end
  for _, object in ipairs(objects) do
    local props = {}
    if object:IsA("CanvasGroup") then
      props.GroupTransparency = 1
    elseif object:IsA("UIStroke") then
      props.Transparency = 1
    elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
      props.TextTransparency = 1; props.TextStrokeTransparency = 1
      props.BackgroundTransparency = 1
    elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
      props.ImageTransparency = 1; props.BackgroundTransparency = 1
    elseif object:IsA("ScrollingFrame") then
      props.BackgroundTransparency = 1; props.ScrollBarImageTransparency = 1
    elseif object:IsA("Frame") or object:IsA("ViewportFrame") then
      props.BackgroundTransparency = 1
    end
    if next(props) then
      if not fadeRestore[object] then
        local original = {}
        for key in pairs(props) do
          original[key] = object[key]
        end
        fadeRestore[object] = original
      end
      local tween = twPlay(object, duration, props)
      if tween then tweens[#tweens + 1] = tween end
    end
  end
end
local function fadeOutForReplacement(preserveUpdate)
  if UIState.closing then
    if fadeEvent and not fadeDone then fadeEvent.Event:Wait() end
    return
  end
  if not screenGui or not screenGui.Parent then return end
  UIState.closing = true; fadeDone = false
  if pageController then pageController.suspend() end
  if uiKit then uiKit.suspend() end
  if shellMotion then
    shellMotion.cancelAll(function(object) return preserveUpdate ~= false and object:GetAttribute("ExodusNotificationKey") == "update" end)
  end
  fadeEvent = Instance.new("BindableEvent"); safeCancel(UIState.panelTween)
  safeCancel(UIState.btnTween); safeCancel(UIState.miniTween)
  safeCancel(UIState.toastTween); local tweens = {}
  fadeGuiTree(screenGui, tweens, "panel"); fadeGuiTree(informationGui, tweens, "panel")
  if persistentLayer and persistentLayer.Parent then
    for _, card in ipairs(persistentLayer:GetChildren()) do
      local key = card:GetAttribute("ExodusNotificationKey")
      if key ~= "update" or preserveUpdate == false then
        if key then safeCancel(persistentTweens[key]); persistentTweens[key] = nil end
        fadeGuiTree(card, tweens, "panel")
      end
    end
  end
  awaitTweens(tweens); local oldKeys = {}
  for _, key in ipairs(persistentOrder) do
    if key ~= "update" or preserveUpdate == false then oldKeys[#oldKeys + 1] = key end
  end
  for _, key in ipairs(oldKeys) do
    local card = persistentLayer and persistentLayer:FindFirstChild("Notification_" .. key)
    if card then card:Destroy() end
    local index = table.find(persistentOrder, key)
    if index then table.remove(persistentOrder, index) end
  end
  if persistentLayer and persistentLayer.Parent then
    for _, card in ipairs(persistentLayer:GetChildren()) do
      if card:GetAttribute("ExodusNotificationKey") ~= "update" or preserveUpdate == false then card:Destroy() end
    end
  end
  fadeDone = true; local completed = fadeEvent
  completed:Fire()
  _spawn(function()
    _wait(); completed:Destroy()
  end)
end
local function animateClose(action)
  if UIState.closing then return end
  _G.ExodusShutdownReason = action == "close" and "close" or "reload"
  if action == "reload" and showPersistentNotification then showPersistentNotification("Updating...", "update", "info") end
  if type(print) == "function" then print("[Exodus] Closing...") end
  fadeOutForReplacement(action == "reload")
  if not UIState.closing then return end
  if action == "reload" and type(Controls.onReload) == "function" then Controls.onReload(restoreAfterReloadFailure)
  elseif type(Controls.onClose) == "function" then Controls.onClose()
  elseif Utils and type(Utils.stop) == "function" then Utils.stop() end
end

-- setup
function ExodusUI.setup(deps, preview)
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
    or type(deps.UIConfig.pages) ~= "table"
    or type(deps.GameInfo) ~= "table"
    or type(deps.AutoSpam) ~= "table"
    or type(deps.UIKit) ~= "table"
    or type(deps.UIPages) ~= "table"
    or type(deps.UIActions) ~= "table"
    or type(deps.Runtime) ~= "table"
    or type(deps.Theme) ~= "table"
  then
    return false, "missing UI dependency"
  end
  Utils = deps.Utils; UIConfig = deps.UIConfig
  GameInfo = deps.GameInfo; AutoSpam = deps.AutoSpam
  UIKit, UIPages, UIActions, Runtime = deps.UIKit, deps.UIPages, deps.UIActions, deps.Runtime; CONFIG = deps.Theme.tokens
  C, GRAD = CONFIG.COLORS, CONFIG.GRADIENT; BTN_SIZE, CLASH_SIZE = CONFIG.BTN_SIZE, CONFIG.CLASH_SIZE
  OFFSCREEN_X = -CLASH_SIZE - 40; MINI_W, MINI_H = CONFIG.MINI_W, CONFIG.MINI_H
  PW, PH, TITLE_H, PAD = CONFIG.PANEL_W, CONFIG.PANEL_H, CONFIG.TITLE_H, CONFIG.PAD; PARTICLE_COLORS = CONFIG.PARTICLE_COLORS
  Controls = deps.Controls; local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
  if type(_G.ExodusUICleanup) == "function" then
    if not preview and type(_G.ExodusUIFadeOut) == "function" then pcall(_G.ExodusUIFadeOut) end
    _G.ExodusUICleanup()
  else
    local old = playerGui:FindFirstChild("ExodusUISystem")
    if old then old:Destroy() end
  end
  shellScope = Runtime.scope(); shellMotion = Runtime.motion(shellScope)
  UIState.panelOpen = false; UIState.spamOn = false
  UIState.clashBallOn = false; UIState.closing = false
  UIState.desktop = Utils.getConfigValue("ForcePCUI") == true or UIS.KeyboardEnabled or UIS.MouseEnabled or not UIS.TouchEnabled; UIState.panelTween = nil
  UIState.btnTween = nil; _G.ExodusUIRestore = restoreAfterReloadFailure
  persistentLayerForPlayer(); _G.ExodusUICleanup = cleanupUI
  _G.ExodusUIFadeOut = fadeOutForReplacement; _G.ExodusShowPersistentNotification = showPersistentNotification
  _G.ExodusClearPersistentNotification = clearPersistentNotification
  screenGui = inst("ScreenGui", {
    Name = "ExodusUISystem",
    DisplayOrder = 100,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = playerGui,
  })
  uiKit = UIKit.create({
    parent = screenGui,
    read = Utils.getConfigValue,
    write = setConfigValue,
    observe = Utils.observeConfig,
    notify = showToast,
    onCapture = function(active) UIState.keyCapture = active end,
    onOutline = function(gradient) outlineGradients[gradient] = true end,
  })
  animateOutlines(); responsiveScale = inst("UIScale", { Scale = 1, Parent = screenGui })
  local function updateResponsiveScale()
    local size = viewport(); responsiveScale.Scale = math.min(1, math.max(0.1, math.min((size.X - 20) / PW, (size.Y - 20) / PH)))
    if miniGui and miniGui.Visible then applyMiniScale(Utils.getConfigValue("MiniSpamScale")) end
  end
  updateResponsiveScale(); local currentCamera = workspace.CurrentCamera or Camera
  if currentCamera then trackConn(currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveScale)) end
  informationGui = inst("ScreenGui", {
    Name = "ExodusInformationOverlay",
    DisplayOrder = 2147483647,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Global,
    Parent = playerGui,
  })
  toastLayer = inst("Frame", {
    Name = "ExodusToastLayer",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ZIndex = 199,
    Parent = informationGui,
  })
  local textService = game:GetService("TextService")
  local function compactInformation(label)
    local paddingX, paddingY = 8, 5; label.TextSize = 14
    label.TextWrapped = false; label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top; label.BorderSizePixel = 0
    label.ZIndex = 100; label.BackgroundTransparency = 1
    label.TextTransparency = 1; label.Visible = false
    corner(label, 8)
    inst("UIPadding", {
      PaddingLeft = UDim.new(0, paddingX),
      PaddingRight = UDim.new(0, paddingX),
      PaddingTop = UDim.new(0, paddingY),
      PaddingBottom = UDim.new(0, paddingY),
      Parent = label,
    })
    local function resize()
      local bounds = textService:GetTextSize(label.Text, label.TextSize, label.Font, Vector2.new(1000, 1000))
      label.Size = UDim2.fromOffset(math.ceil(bounds.X) + paddingX * 2, math.ceil(bounds.Y) + paddingY * 2)
    end
    trackConn(label:GetPropertyChangedSignal("Text"):Connect(resize)); resize()
    local shown, activeTween = false, nil
    return function(visible)
      if shown == visible then return end
      shown = visible
      if activeTween then activeTween:Cancel() end
      if visible then label.Visible = true end
      local transition = twPlay(label, "control", {
        BackgroundTransparency = visible and 0.2 or 1,
        TextTransparency = visible and 0 or 1,
      })
      activeTween = transition
      if transition then
        local connection
        connection = trackConn(transition.Completed:Connect(function(playbackState)
          safeDisconnect(connection); untrackConn(connection)
          if activeTween ~= transition then return end
          activeTween = nil
          if playbackState == Enum.PlaybackState.Completed and not shown then label.Visible = false end
        end))
      elseif not shown then
        label.Visible = false
      end
    end
  end
  local distanceLabel = inst("TextLabel", {
    Name = "ClashDistance",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 0),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 0.2,
    Text = "Current SPD: —\nClash: —\nCPS: —",
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
    Text = "Ball travel time: —",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = Utils.getConfigValue("ClashTravelTimeVisible") == true,
    ZIndex = 20,
    Parent = informationGui,
  })
  local gateLabel = inst("TextLabel", {
    Name = "AutoSpamGateInfo",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 0, 0.5, 0),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 1,
    TextTransparency = 1,
    Text = "",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = false,
    ZIndex = 20,
    Parent = informationGui,
  })
  local setDistanceVisible = compactInformation(distanceLabel); local setTravelVisible = compactInformation(travelLabel)
  local setGateVisible = compactInformation(gateLabel); local nextGateUpdate, nextTravelUpdate, nextDistanceUpdate = 0, 0, 0
  local function validGate(value)
    return type(value) == "string" and value ~= "" and value ~= "null" and value ~= "nil" and value ~= "inactive" and value ~= "detached"
  end
  local telemetryAt, telemetryStatus, telemetrySnapshot = -math.huge, nil, nil
  local function getTelemetry(time)
    if time < telemetryAt or time - telemetryAt >= 1 / 30 then telemetryAt, telemetryStatus, telemetrySnapshot = time, AutoSpam.getStatus(), GameInfo.getSnapshotAt(time) end
    return telemetryStatus, telemetrySnapshot
  end
  local function formatSpeed(snapshot)
    if not GameInfo.isSnapshotValid(snapshot) then return "—" end
    local speed = tonumber(snapshot.syncSpeed)
    if not speed or speed ~= speed or speed <= 0 or speed == math.huge then speed = snapshot.speed end
    return type(speed) == "number" and speed == speed and speed >= 0 and speed < math.huge and string.format("%.0f", speed) or "—"
  end
  local function updateInformation()
    if not informationGui.Parent then return end
    local time = os.clock(); local gateEnabled = Utils.getConfigValue("ClashGateInfoVisible") == true
    local travelVisible = Utils.getConfigValue("ClashTravelTimeVisible") == true; local distanceVisible = Utils.getConfigValue("ClashDistanceVisible") == true
    if not gateEnabled and not travelVisible and not distanceVisible then
      setGateVisible(false); setTravelVisible(false)
      setDistanceVisible(false); return
    end
    if gateEnabled and time >= nextGateUpdate then
      nextGateUpdate = time + 0.1; local status = AutoSpam.getStatus()
      local lines = { "AutoSpam: " .. (status and status.active == true and "ACTIVE" or "WAITING") }
      if status and validGate(status.lastGate) then lines[#lines + 1] = "State: " .. status.lastGate end
      if status and validGate(status.lastActivationReason) then lines[#lines + 1] = "Activation: " .. status.lastActivationReason end
      if status and validGate(status.lastStopReason) then lines[#lines + 1] = "Deactivation: " .. status.lastStopReason end
      setTextIfChanged(gateLabel, table.concat(lines, "\n"))
    end
    local gateVisible = gateEnabled and gateLabel.Text ~= ""; setGateVisible(gateVisible)
    setTravelVisible(travelVisible)
    if travelVisible and time >= nextTravelUpdate then
      nextTravelUpdate = time + 0.05; local status, snapshot = getTelemetry(time)
      local stats = status and status.clashStats; local speedText = formatSpeed(snapshot)
      if not stats then
        setTextIfChanged(travelLabel, "Current SPD: " .. speedText .. "\nBall travel time: —")
      else
        local me = Players.LocalPlayer and Players.LocalPlayer.UserId
        local text
        if stats.frozen then
          if stats.deceasedId then
            local who = stats.deceasedId == me and "You" or "Opponent"; local value = stats.fatalTravelTime and string.format("%.0f ms", stats.fatalTravelTime * 1000) or "unavailable"
            local previousWho = stats.penultimateTarget == me and "you" or (stats.penultimateTarget == stats.partnerId and "opponent" or "—")
            local previous = stats.penultimateTravelTime and string.format("%.0f ms", stats.penultimateTravelTime * 1000) or "unavailable"
            text = who .. " died\nTarget time to death: " .. value .. "\nPrevious (" .. previousWho .. "): " .. previous
          else
            text = "Clash ended\nFinal time: unavailable"
          end
        else
          local value = stats.travelStartedAt and string.format("%.0f ms", math.max(0, time - stats.travelStartedAt) * 1000) or "—"
          local who = stats.travelTarget == me and "You" or (stats.travelTarget == stats.partnerId and "Opponent" or "—")
          local last = stats.lastTravelTime and string.format("%.0f ms", stats.lastTravelTime * 1000) or "—"
          local lastWho = stats.lastTravelTarget == me and "you" or (stats.lastTravelTarget == stats.partnerId and "opponent" or "—")
          text = "Target: " .. who .. " | Time: " .. value .. "\nLast exchange (" .. lastWho .. "): " .. last
        end
        setTextIfChanged(travelLabel, "Current SPD: " .. speedText .. "\n" .. text)
      end
    end
    setDistanceVisible(distanceVisible)
    if not distanceVisible or time < nextDistanceUpdate then return end
    nextDistanceUpdate = time + 0.1; local status, snapshot = getTelemetry(time)
    local stats = status and status.clashStats; local speedText = formatSpeed(snapshot)
    local text
    if stats and (not stats.frozen or stats.endReason == "jogador morreu") then
      local function sampleText(sample)
        if not sample then return "—" end
        local distance = type(sample.distance) == "number" and string.format("%.1f", sample.distance) or "?"
        local speed = type(sample.speed) == "number" and string.format("%.0f", sample.speed) or "?"; return distance .. " studs | SPD " .. speed
      end
      local cps = type(stats.currentCps) == "number" and string.format("%.2f", stats.currentCps) or "—"
      text = string.format(
        "Current SPD: %s\nStart: %s\n%s: %s\nCurrent CPS: %s | %.2fs",
        speedText,
        sampleText(stats.startSample),
        stats.frozen and (stats.endReason == "jogador morreu" and "Player died" or (stats.endReason == "oponente morreu" and "Opponent died" or "End"))
          or "Current",
        sampleText(stats.endSample),
        cps,
        stats.duration or 0
      )
    else
      text = "Current SPD: " .. speedText .. "\nClash: —\nCurrent CPS: —"
    end
    setTextIfChanged(distanceLabel, text)
  end
  trackConn(RunService.Heartbeat:Connect(updateInformation)); bindInput()
  floatingButton = inst("TextButton", {
    Name = "ExodusFloatingButton",
    Size = UDim2.fromOffset(BTN_SIZE * 0.7, BTN_SIZE * 0.7),
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
  corner(floatingButton, 999); floatingButtonStroke = stroke(floatingButton, C.accent, 2)
  floatingButtonStroke.Transparency = 1
  task.defer(function()
    if not floatingButton or not floatingButton.Parent then return end
    twPlay(floatingButton, "panel", { BackgroundTransparency = 0.1, TextTransparency = 0, Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE) }); twPlay(floatingButtonStroke, "panel", { Transparency = 0 })
  end)
  local config = Utils.getConfig(); local clashX = config.ClashBallX or 14
  local clashY = config.ClashBallY or (viewport().Y / 2 - CLASH_SIZE / 2)
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
  corner(clashBall, 999); stroke(clashBall, Color3.new(0, 0, 0), 2)
  UIState.clashBallOn = config.AutoSpam or false; clashBall.Text = UIState.clashBallOn and "ON" or "OFF"
  clashBall.TextSize = UIState.clashBallOn and 18 or 16; clashBall.BackgroundColor3 = UIState.clashBallOn and C.green or C.red
  paintClashBall(); local parryX = config.ParryBallX or 14
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
  local isClashDragging = makeDraggable(clashBall, clashBall, function()
    setConfigValue("ClashBallX", clashBall.Position.X.Offset); setConfigValue("ClashBallY", clashBall.Position.Y.Offset)
  end)
  trackConn(clashBall.Activated:Connect(function() setClashBall(not UIState.clashBallOn) end))
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
  paintJumpBall(config.AutoJump == true); local _, miniY, miniWidth, miniHeight, miniScreenWidth = miniLayout(tonumber(config.MiniSpamScale) or 1)
  local MINI_OFF_X = miniScreenWidth + 30
  miniGui = inst("CanvasGroup", {
    Name = "ExodusSpamMini",
    Visible = false,
    GroupTransparency = 1,
    Size = UDim2.fromOffset(miniWidth, miniHeight),
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
  stroke(miniGui, C.accent, 1.5)
  local miniTitleBar = inst("Frame", {
    Size = UDim2.new(1, 0, 0.22, 0),
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
  local spamButton = inst("TextButton", {
    Name = "SpamButton",
    Size = UDim2.new(1, -12, 0.78, -8),
    Position = UDim2.new(0, 6, 0.22, 3),
    BackgroundColor3 = UIState.spamOn and C.green or C.red,
    BorderSizePixel = 0,
    Text = UIState.spamOn and "ON" or "OFF",
    TextColor3 = Color3.new(1, 1, 1),
    TextScaled = true,
    Font = Enum.Font.GothamBold,
    ZIndex = 16,
    Parent = miniGui,
  })
  corner(spamButton, 10); inst("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 12 }, spamButton)
  trackConn(spamButton.Activated:Connect(function()
    if Utils.getConfigValue("ManualSpamMode") ~= "Hold" then setSpam(not UIState.spamOn) end
  end))
  trackConn(spamButton.InputBegan:Connect(function(input)
    if Utils.getConfigValue("ManualSpamMode") ~= "Hold" or UIState.manualHoldInput then return end
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then UIState.manualHoldInput = input; setSpam(true) end
  end))
  miniGui.Position = UDim2.new(0, MINI_OFF_X, 0, miniY)
  local function saveMiniPosition() Utils.setConfig({ MiniX = miniGui.Position.X.Offset, MiniY = miniGui.Position.Y.Offset }) end
  makeDraggable(miniTitleBar, miniGui, saveMiniPosition, false, miniScreenScale, saveMiniPosition)
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
    Text = ("%s | v%s"):format(Utils.name(), Utils.version()),
    TextColor3 = C.text,
    TextSize = CONFIG.TITLE_TEXT_SIZE,
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
    Text = "— " .. Utils.author(),
    TextColor3 = C.text,
    TextTransparency = CONFIG.AUTHOR_TRANSPARENCY,
    TextSize = CONFIG.AUTHOR_TEXT_SIZE,
    Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
    Parent = titleGroup,
  })
  minimizeButton = inst("TextButton", {
    Name = "MinimizePanel",
    Size = UDim2.new(0, 30, 0, 30),
    Position = UDim2.new(1, -PAD - 30, 0.5, -15),
    BackgroundColor3 = C.btnDark,
    BackgroundTransparency = 0.3,
    Text = "",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = titleBar,
  })
  corner(minimizeButton, 8); uiKit.icon(minimizeButton, "minimize")
  trackConn(minimizeButton.MouseEnter:Connect(function() twPlay(minimizeButton, "feedback", { BackgroundTransparency = 0 }) end))
  trackConn(minimizeButton.MouseLeave:Connect(function() twPlay(minimizeButton, "feedback", { BackgroundTransparency = 0.3 }) end))
  trackConn(minimizeButton.Activated:Connect(function()
    if UIState.panelOpen then togglePanel() end
  end))
  local settingsButton = inst("TextButton", {
    Name = "HubSettingsButton",
    Size = UDim2.new(0, 30, 0, 30),
    Position = UDim2.new(1, -PAD - 66, 0.5, -15),
    BackgroundColor3 = C.btnDark,
    BackgroundTransparency = 0.3,
    Text = "",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 18,
    Font = Enum.Font.GothamBold,
    ZIndex = 9,
    Parent = titleBar,
  })
  corner(settingsButton, 8); uiKit.icon(settingsButton, "settings")
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
  local previous = inst("TextButton", {
    Name = "PreviousPage",
    Size = UDim2.new(0, 32, 0, 26),
    Position = UDim2.new(0, PAD, 1, -PAD - 26),
    BackgroundColor3 = C.btnDark,
    Text = "",
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
    Text = "1/5 Main",
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
    Text = "",
    TextColor3 = C.text,
    TextSize = 20,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = configPanel,
  })
  corner(previous, 6); corner(nextPage, 6)
  local previousIcon = uiKit.icon(previous, "chevron", { Rotation = 90 }); local nextIcon = uiKit.icon(nextPage, "chevron", { Rotation = -90 })
  local actions
  local rebuildQueued = false
  local function rebuild(reset)
    if rebuildQueued then return end
    rebuildQueued = true; local owner = screenGui
    local wasOpen = UIState.panelOpen; local snapshot = pageController and pageController.snapshot()
    task.defer(function()
      if screenGui ~= owner or not owner.Parent or UIState.closing then return end
      local ok, reason = ExodusUI.setup(deps, { snapshot = not reset and snapshot or nil, open = wasOpen })
      if not ok then warn("[Exodus] Falha ao atualizar interface: " .. tostring(reason)) end
    end)
  end
  actions = UIActions.create({
    scope = uiKit.scope,
    controls = Controls,
    desktop = UIState.desktop,
    notify = showToast,
    persistent = showPersistentNotification,
    setSpam = setSpam,
    showMini = showMini,
    rebuild = rebuild,
  })
  local function updateNavigation(state)
    pageLabel.Text = state.utility and state.title or tostring(state.index) .. "/" .. tostring(state.count) .. " " .. state.title; previous.Visible = not state.utility
    nextPage.Visible = not state.utility; previous.Active = state.index ~= nil and state.index > 1
    previous.Selectable = previous.Active; nextPage.Active = state.index ~= nil and state.index < state.count
    nextPage.Selectable = nextPage.Active; previousIcon.ImageTransparency = previous.Active and 0 or 0.7
    nextIcon.ImageTransparency = nextPage.Active and 0 or 0.7; settingsButton.BackgroundColor3 = state.id == "config" and C.accent or C.btnDark
  end
  pageController = UIPages.create(uiKit, configPanel, UIConfig.pages, {
    desktop = UIState.desktop,
    read = Utils.getConfigValue,
    resolve = actions.resolve,
    onComponent = actions.attach,
    abilitiesEnabled = GameInfo.areAbilitiesEnabled,
    onNavigate = updateNavigation,
  })
  local function updateAbilityVisibility()
    pageController.refresh(); local enabled = GameInfo.areAbilitiesEnabled() and not UIState.desktop
    darkBall.Visible = enabled; jumpBall.Visible = enabled
    upDashBall.Visible = enabled
  end
  updateAbilityVisibility(); trackConn(GameInfo.observeAbilityMode(updateAbilityVisibility))
  trackConn(settingsButton.Activated:Connect(function() pageController.toggle("config") end))
  trackConn(previous.Activated:Connect(function() pageController.step(-1) end))
  trackConn(nextPage.Activated:Connect(function() pageController.step(1) end))
  if preview and preview.snapshot then pageController.restore(preview.snapshot) end
  if not UIState.desktop and config.ClashBallVisible then twPlay(clashBall, "control", { Position = UDim2.new(0, clashX, 0, clashY) }) end
  if not UIState.desktop and config.ParryBallVisible then twPlay(parryBall, "control", { Position = UDim2.new(0, parryX, 0, parryY) }) end
  if not UIState.desktop and config.DarkBallVisible then twPlay(darkBall, "control", { Position = UDim2.new(0, darkX, 0, darkY) }) end
  if not UIState.desktop and config.JumpBallVisible then twPlay(jumpBall, "control", { Position = UDim2.new(0, jumpX, 0, jumpY) }) end
  if not UIState.desktop and config.UpDashBallVisible then twPlay(upDashBall, "control", { Position = UDim2.new(0, upDashX, 0, upDashY) }) end
  showMini(config.MiniSpamVisible == true)
  trackConn(Utils.observeSpam(function()
    local manual = Utils.isManualSpamActive()
    if UIState.spamOn ~= manual then setSpam(manual) end
    actions.refreshManual()
  end))
  trackConn(Utils.observeConfig(function(changes)
    if changes.AutoSpam ~= nil then UIState.clashBallOn = changes.AutoSpam == true; paintClashBall() end
    if changes.AutoParry ~= nil then paintParryBall(changes.AutoParry == true) end
    if changes.AutoDark ~= nil then paintDarkBall(changes.AutoDark == true) end
    if changes.AutoJump ~= nil then paintJumpBall(changes.AutoJump == true) end
    local visibility = {
      ParryBallVisible = showParryBall,
      ClashBallVisible = showClashBall,
      DarkBallVisible = showDarkBall,
      JumpBallVisible = showJumpBall,
      UpDashBallVisible = showUpDashBall,
      MiniSpamVisible = showMini,
    }

    for key, show in pairs(visibility) do
      if changes[key] ~= nil then show(changes[key] == true) end
    end
    if changes.MiniSpamScale ~= nil or changes.MiniSpamWidth ~= nil or changes.MiniSpamHeight ~= nil then applyMiniScale(Utils.getConfigValue("MiniSpamScale")) end
    if changes.ManualSpamMode ~= nil then UIState.manualHoldInput = nil; setSpam(false) end
    actions.refreshManual()
    if changes.ForcePCUI ~= nil then rebuild() end
  end))
  local function refreshDevice()
    local desktop = Utils.getConfigValue("ForcePCUI") == true or UIS.KeyboardEnabled or UIS.MouseEnabled or not UIS.TouchEnabled
    if desktop ~= UIState.desktop and not UIState.closing then rebuild() end
  end
  for _, property in ipairs({ "KeyboardEnabled", "MouseEnabled", "TouchEnabled" }) do
    trackConn(UIS:GetPropertyChangedSignal(property):Connect(refreshDevice))
  end
  setSpam(Utils.isManualSpamActive(), true); _G.ExodusUIReturnAfterUpdate = nil
  if preview and preview.open then togglePanel() end
  return true
end

-- contract
ExodusUI.__contract = {
  requires = {
    Utils = "utils",
    UIConfig = "uiconfig",
    GameInfo = "gameinfo",
    AutoSpam = "autospam",
    UIKit = "uikit",
    UIPages = "uipages",
    UIActions = "uiactions",
    Runtime = "uiruntime",
    Theme = "uitheme",
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
    },
    AutoSpam = { "getStatus" },
    UIKit = { "create" },
    UIPages = { "create" },
    UIActions = { "create" },
    Runtime = { "scope", "motion" },
  },
  requiresData = { UIConfig = { "pages" }, Theme = { "tokens" } },
  data = { "Components" },
  provides = { "setup" },
}

return ExodusUI
