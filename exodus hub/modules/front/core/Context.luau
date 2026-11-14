local Scope = require(script.Parent.Scope)
local Signal = require(script.Parent.Signal)
local Store = require(script.Parent.Store)
local Theme = require(script.Parent.Theme)
local Context = {}
Context.__index = Context
function Context.new(options)
  options = options or {}
  local self = setmetatable({}, Context)
  self.onError = options.onError or function(err) warn("[UI Library] " .. tostring(err)) end
  self.scope = Scope.new(self.onError)
  self.theme = Theme.resolve(options.theme)
  self.ThemeChanged = self.scope:Add(Signal.new(self.onError))
  self.Events = self.scope:Add(Signal.new(self.onError))
  self.reducedMotion = options.reducedMotion == true
  self.input = game:GetService("UserInputService")
  self.guiService = game:GetService("GuiService")
  self.tweenService = game:GetService("TweenService")
  self.store = options.store
    or self.scope:Add(Store.new({
      values = options.values,
      validate = options.validate,
      write = options.write,
      onError = self.onError,
    }))
  local parent = options.parent
  if not parent then
    parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
  end
  self.gui = self.scope:Add(Instance.new("ScreenGui"))
  self.gui.Name = options.name or "UILibrary"
  self.gui.ResetOnSpawn = false
  self.gui.IgnoreGuiInset = false
  self.gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
  self.gui.DisplayOrder = options.displayOrder or 100
  self.gui.Parent = parent
  self.root = self:Create("Frame", { Name = "Root", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, self.gui)
  self.overlays = self:Create("Frame", { Name = "Overlays", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 100 }, self.root)
  self.InputBegan = self.scope:Add(Signal.new(self.onError))
  self.InputChanged = self.scope:Add(Signal.new(self.onError))
  self.InputEnded = self.scope:Add(Signal.new(self.onError))
  self.scope:Add(self.input.InputBegan:Connect(function(input, processed)
    if self.capture then
      local capture = self.capture
      if input.KeyCode == Enum.KeyCode.Escape then
        self.capture = nil
        capture(nil, true)
      elseif input.KeyCode ~= Enum.KeyCode.Unknown then
        self.capture = nil
        capture(input.KeyCode, false)
      elseif
        input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.MouseButton2
        or input.UserInputType == Enum.UserInputType.MouseButton3
      then
        self.capture = nil
        capture(input.UserInputType, false)
      end
      return
    end
    self.InputBegan:Fire(input, processed)
  end))
  self.scope:Add(self.input.InputChanged:Connect(function(input) self.InputChanged:Fire(input) end))
  self.scope:Add(self.input.InputEnded:Connect(function(input) self.InputEnded:Fire(input) end))
  self.scope:Add(self.input.WindowFocusReleased:Connect(function() self.InputEnded:Fire(nil) end))
  self.scope:Add(function()
    self:ClosePopup()
    self:CancelCapture()
  end)
  self.scope:Add(self.gui.Destroying:Connect(function() self:Destroy() end))
  return self
end
function Context:Create(class, properties, parent)
  local object = Instance.new(class)
  for key, value in pairs(properties or {}) do
    object[key] = value
  end
  object.Parent = parent
  return object
end
function Context:Round(object, radius) return self:Create("UICorner", { CornerRadius = UDim.new(0, radius or self.theme.radius.control) }, object) end
function Context:Outline(object, color)
  return self:Create("UIStroke", {
    Color = color or self.theme.colors.border,
    Thickness = 1,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
  }, object)
end
function Context:Padding(object, size)
  size = size or self.theme.space.md
  return self:Create("UIPadding", {
    PaddingLeft = UDim.new(0, size),
    PaddingRight = UDim.new(0, size),
    PaddingTop = UDim.new(0, size),
    PaddingBottom = UDim.new(0, size),
  }, object)
end
function Context:List(object, horizontal, gap)
  return self:Create("UIListLayout", {
    FillDirection = horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
    SortOrder = Enum.SortOrder.LayoutOrder,
    Padding = UDim.new(0, gap or self.theme.space.sm),
  }, object)
end
function Context:Text(parent, text, props)
  local defaults = {
    BackgroundTransparency = 1,
    Text = text or "",
    TextColor3 = self.theme.colors.text,
    TextSize = self.theme.text.body,
    Font = self.theme.font.regular,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
    TextWrapped = true,
    Size = UDim2.new(1, 0, 0, 24),
  }
  for k, v in pairs(props or {}) do
    defaults[k] = v
  end
  return self:Create("TextLabel", defaults, parent)
end
function Context:WatchTheme(scope, render)
  scope:Add(self.ThemeChanged:Connect(render))
  render(self.theme)
end
function Context:SetTheme(patch)
  self.theme = Theme.resolve(patch)
  self.ThemeChanged:Fire(self.theme)
end
function Context:SetReducedMotion(value) self.reducedMotion = value == true end
function Context:Animate(scope, object, properties, duration)
  if scope.destroyed then
    return
  end
  scope._tweens = scope._tweens or setmetatable({}, { __mode = "k" })
  local previous = scope._tweens[object]
  if previous then
    previous:Cancel()
  end
  if self.reducedMotion or duration == 0 then
    for key, value in pairs(properties) do
      object[key] = value
    end
    return
  end
  local tween =
    self.tweenService:Create(object, TweenInfo.new(duration or self.theme.motion.normal, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), properties)
  scope._tweens[object] = tween
  local connection, cancel
  cancel = function()
    if connection then
      connection:Disconnect()
      scope:Remove(connection)
    end
    tween:Cancel()
    if scope._tweens[object] == tween then
      scope._tweens[object] = nil
    end
    scope:Remove(cancel)
  end
  connection = tween.Completed:Connect(function() cancel() end)
  scope:Add(connection)
  scope:Add(cancel)
  tween:Play()
end
function Context:Interactive(scope, button, disabled, render)
  local hovered, focused, pressed = false, false, false
  local function paint() render(disabled(), hovered or focused, pressed) end
  button.AutoButtonColor = false
  button.Selectable = true
  scope:Add(button.MouseEnter:Connect(function()
    hovered = true
    paint()
  end))
  scope:Add(button.MouseLeave:Connect(function()
    hovered = false
    pressed = false
    paint()
  end))
  scope:Add(button.SelectionGained:Connect(function()
    focused = true
    paint()
  end))
  scope:Add(button.SelectionLost:Connect(function()
    focused = false
    pressed = false
    paint()
  end))
  scope:Add(button.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
      pressed = true
      paint()
    end
  end))
  scope:Add(self.InputEnded:Connect(function()
    if pressed then
      pressed = false
      paint()
    end
  end))
  scope:Add(self.ThemeChanged:Connect(paint))
  paint()
  return paint
end
-- The original short card press, with one owned scale and cancellable work.
function Context:Press(scope, button, target)
  local scale = self:Create("UIScale", { Name = "PressScale", Scale = 1 }, target)
  local generation = 0
  scope:Add(button.Activated:Connect(function()
    if self.reducedMotion then
      return
    end
    generation += 1
    local current = generation
    self:Animate(scope, scale, { Scale = 0.97 }, 0.07)
    scope:Delay(0.07, function()
      if generation == current then
        self:Animate(scope, scale, { Scale = 1 }, 0.15)
      end
    end)
  end))
end
function Context:CancelCapture()
  if self.capture then
    local callback = self.capture
    self.capture = nil
    callback(nil, true)
  end
end
function Context:Capture(scope, callback)
  self:CancelCapture()
  self.capture = callback
  local cancel = function()
    if self.capture == callback then
      self:CancelCapture()
    end
  end
  if not scope._captureCleanup then
    scope._captureCleanup = true
    scope:Add(function()
      if self.captureOwner == scope then
        self:CancelCapture()
      end
    end)
  end
  self.captureOwner = scope
  return cancel
end
function Context:BindKey(scope, getKey, callback, hold)
  local active
  scope:Add(self.InputBegan:Connect(function(input, processed)
    if processed or self.input:GetFocusedTextBox() or self.modal or self.popup or self.capture then
      return
    end
    local key = getKey()
    if key ~= Enum.KeyCode.Unknown and (input.KeyCode == key or input.UserInputType == key) and not active then
      active = input
      callback(true)
    end
  end))
  scope:Add(self.InputEnded:Connect(function(input)
    if active and (input == nil or input == active or input.KeyCode == active.KeyCode) then
      active = nil
      if hold then
        callback(false)
      end
    end
  end))
  scope:Add(function()
    if active and hold then
      callback(false)
    end
  end)
end
function Context:Drag(scope, handle, target, onEnd)
  local active, origin, initial, moved = nil, nil, nil, false
  handle.Active = true
  scope:Add(handle.InputBegan:Connect(function(input)
    if self.modal or self.popup then
      return
    end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
      active, origin, initial, moved = input, input.Position, target.AbsolutePosition - self.root.AbsolutePosition, false
    end
  end))
  scope:Add(self.InputChanged:Connect(function(input)
    if not active then
      return
    end
    if input ~= active and input.UserInputType ~= Enum.UserInputType.MouseMovement then
      return
    end
    if active.UserInputType == Enum.UserInputType.Touch and input ~= active then
      return
    end
    local delta = input.Position - origin
    if delta.Magnitude > 6 then
      moved = true
    end
    if not moved then
      return
    end
    local bounds, size = self.root.AbsoluteSize, target.AbsoluteSize
    local x = math.clamp(initial.X + delta.X, 0, math.max(0, bounds.X - size.X))
    local y = math.clamp(initial.Y + delta.Y, 0, math.max(0, bounds.Y - size.Y))
    target.AnchorPoint = Vector2.zero
    target.Position = UDim2.fromOffset(x, y)
  end))
  scope:Add(self.InputEnded:Connect(function(input)
    if active and (input == nil or input == active) then
      active = nil
      if moved and onEnd then
        onEnd(target.Position)
      end
    end
  end))
  return function() return moved end
end
function Context:ClosePopup()
  local popup = self.popup
  self.popup = nil
  self.popupOwner = nil
  if popup then
    popup:Destroy()
  end
end
function Context:Popup(ownerScope, anchor, height)
  self:ClosePopup()
  local scope = ownerScope:Child()
  self.popup = scope
  self.popupOwner = ownerScope
  local shield = scope:Add(self:Create("TextButton", {
    Name = "DismissPopup",
    Size = UDim2.fromScale(1, 1),
    Text = "",
    BackgroundTransparency = 1,
    AutoButtonColor = false,
    ZIndex = 101,
  }, self.overlays))
  local frame = self:Create("ScrollingFrame", {
    Name = "Popup",
    BackgroundColor3 = self.theme.colors.elevated,
    BorderSizePixel = 0,
    Size = UDim2.fromOffset(240, height),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 4,
    ZIndex = 102,
  }, shield)
  self:Round(frame)
  self:Outline(frame)
  self:Padding(frame, 4)
  self:List(frame, false, 4)
  local function position()
    local rootPos, bounds = self.root.AbsolutePosition, self.root.AbsoluteSize
    local p, s = anchor.AbsolutePosition - rootPos, anchor.AbsoluteSize
    local width = math.min(math.max(s.X, 180), math.max(1, bounds.X - 16))
    local h = math.min(height, math.max(40, bounds.Y - 16))
    local y = p.Y + s.Y + 4
    if y + h > bounds.Y - 8 then
      y = p.Y - h - 4
    end
    frame.Position = UDim2.fromOffset(math.clamp(p.X, 8, math.max(8, bounds.X - width - 8)), math.clamp(y, 8, math.max(8, bounds.Y - h - 8)))
    frame.Size = UDim2.fromOffset(width, h)
  end
  position()
  scope:Add(anchor:GetPropertyChangedSignal("AbsolutePosition"):Connect(position))
  scope:Add(self.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(position))
  scope:Add(shield.Activated:Connect(function() self:ClosePopup() end))
  scope:Add(self.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.Escape then
      self:ClosePopup()
    end
  end))
  local previous = self.guiService.SelectedObject
  scope:Add(function()
    if self.popup == scope then
      self.popup = nil
      self.popupOwner = nil
    end
    if anchor.Parent then
      self.guiService.SelectedObject = previous
    end
  end)
  return frame, scope
end
function Context:Destroy() self.scope:Destroy() end
return Context
