-- [[ context ]]

-- module
local Context = {}

-- configuration
local CONFIG = {}

-- setup
function Context.setup() return true end

-- context
function Context.create(deps)
  local CONFIG = deps.Theme.tokens; local C, GRAD = CONFIG.COLORS, CONFIG.GRADIENT
  local PW, PH = CONFIG.PANEL_W, CONFIG.PANEL_H; local UIS, RunService, Players = game:GetService("UserInputService"), game:GetService("RunService"), game:GetService("Players")
  local TweenService = game:GetService("TweenService"); local Camera = workspace.CurrentCamera
  local Utils = deps.Utils; local outlineGradients = setmetatable({}, { __mode = "k" })
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

  local context = { deps = deps, theme = CONFIG, state = UIState, refs = {}, outlines = outlineGradients }; context.services = { UIS = UIS, RunService = RunService, Players = Players }
  context.scope = deps.Runtime.scope(); context.motion = deps.Runtime.motion(context.scope)
  UIState.desktop = Utils.getConfigValue("ForcePCUI") == true or UIS.KeyboardEnabled or UIS.MouseEnabled or not UIS.TouchEnabled
  local function trackConn(connection) return context.scope.add(connection) end
  local function untrackConn(connection) context.scope.forget(connection) end
  local function safeDisconnect(connection)
    if connection then connection:Disconnect() end
  end
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
    if context.motion and context.scope.alive then
      if obj:IsA("CanvasGroup") and props.GroupTransparency ~= nil then return context.motion.group(obj, duration, props) end
      return context.motion.play(obj, duration, props)
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
  local function viewport()
    local currentCamera = workspace.CurrentCamera or workspace.CurrentCamera; return currentCamera and currentCamera.ViewportSize or Vector2.new(1920, 1080)
  end
  local function setConfigValue(key, value) return Utils.setConfig({ [key] = value }) end
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
        local vp, sz = viewport(), target.AbsoluteSize; local scale = coordinateScale and coordinateScale() or (context.refs.responsiveScale and context.refs.responsiveScale.Scale or 1)
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
  context.inst = inst; context.corner = corner
  context.stroke = stroke; context.twPlay = twPlay
  context.safeCancel = safeCancel; context.setTextIfChanged = setTextIfChanged
  context.viewport = viewport; context.setConfigValue = setConfigValue
  context.trackConn = trackConn; context.untrackConn = untrackConn
  context.safeDisconnect = safeDisconnect; context.watchTweens = watchTweens
  context.awaitTweens = awaitTweens; context.makeDraggable = makeDraggable
  context.makeBtn = makeBtn; local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
  context.playerGui = playerGui
  context.refs.screenGui = inst("ScreenGui", {
    Name = "ExodusUISystem",
    DisplayOrder = 100,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = playerGui,
  })
  context.kit = deps.UIKit.create({
    parent = context.refs.screenGui,
    read = Utils.getConfigValue,
    write = setConfigValue,
    observe = Utils.observeConfig,
    notify = function(...) return context.notifications.toast(...) end,
    validateShortcut = function(key, binding) return context.actions.validateShortcut(key, binding) end,
    onCapture = function(active) UIState.keyCapture = active end,
    onOutline = function(gradient) outlineGradients[gradient] = true end,
  })
  animateOutlines(); context.refs.responsiveScale = inst("UIScale", { Scale = 1, Parent = context.refs.screenGui })
  local function updateResponsiveScale()
    local size = viewport(); context.refs.responsiveScale.Scale = math.min(1, math.max(0.1, math.min((size.X - 20) / PW, (size.Y - 20) / PH)))
    if context.refs.miniGui and context.refs.miniGui.Visible then context.floating.applyMiniScale(Utils.getConfigValue("MiniSpamScale")) end
  end
  updateResponsiveScale(); local currentCamera = workspace.CurrentCamera or Camera
  if currentCamera then trackConn(currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveScale)) end
  function context.destroy()
    if not context.scope.alive then return end
    if UIState.manualHoldInput then Utils.setManualSpamActive(false) end
    if context.pages then context.pages.destroy() end
    if context.kit then context.kit.destroy() end
    context.scope.destroy(); table.clear(outlineGradients)
    if context.refs.screenGui then context.refs.screenGui:Destroy() end
    if context.refs.informationGui then context.refs.informationGui:Destroy() end
    if context.notifications then context.notifications.clear("closing") end
    table.clear(context.refs)
  end
  return context
end

-- contract
Context.__contract = { provides = { "setup", "create" }, requires = {} }

return Context
