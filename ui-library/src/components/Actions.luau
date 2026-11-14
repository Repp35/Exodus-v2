local Base = require(script.Parent.Base)
local Actions = {}
function Actions.Button(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local button = Base.button(self, self.content, options.text or "Run")
  local border = button:FindFirstChildOfClass("UIStroke")
  local function render(disabled, focused, pressed)
    local t = ctx.theme
    local tone = t.colors[options.variant or "accent"] or t.colors.accent
    button.Text = self.loading and (options.loadingText or "Loading…") or options.text or "Run"
    button.Active = not disabled
    button.TextTransparency = disabled and 0.5 or 0
    border.Color = focused and t.colors.outlineStart or tone
    ctx:Animate(self.scope, button, {
      BackgroundColor3 = disabled and t.colors.hover
        or ((focused or pressed) and tone:Lerp(t.colors.text, pressed and 0.16 or 0.08) or tone),
    }, t.motion.fast)
  end
  local paint = ctx:Interactive(self.scope, button, function()
    return self:IsDisabled()
  end, render)
  self.render = paint
  self.scope:Add(button.Activated:Connect(function()
    if self:IsDisabled() then
      return
    end
    self.Activated:Fire()
    ctx.Events:Fire("activate", options.id)
    if options.onClick then
      local ok, err = pcall(options.onClick, self)
      if not ok then
        ctx.onError(err)
        self:SetError(tostring(err))
      end
    end
  end))
  self.button = button
  return self
end
function Actions.Toggle(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local button = Base.button(self, self.content, "")
  local track = ctx:Create(
    "Frame",
    { Size = UDim2.fromOffset(44, 24), Position = UDim2.new(1, -54, 0.5, -12), BorderSizePixel = 0 },
    button
  )
  ctx:Round(track, 12)
  local thumb = ctx:Create("Frame", {
    Size = UDim2.fromOffset(18, 18),
    Position = UDim2.fromOffset(3, 3),
    BackgroundColor3 = ctx.theme.colors.text,
    BorderSizePixel = 0,
  }, track)
  ctx:Round(thumb, 9)
  local state = ctx:Text(button, "", { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -76, 1, 0) })
  local border = button:FindFirstChildOfClass("UIStroke")
  local paint = ctx:Interactive(self.scope, button, function()
    return self:IsDisabled()
  end, function(disabled, focused)
    local t = ctx.theme
    button.BackgroundColor3 = focused and t.colors.hover or t.colors.input
    button.Active = not disabled
    border.Color = focused and t.colors.accent or t.colors.border
    state.TextColor3 = t.colors.text
    state.TextTransparency = disabled and 0.5 or 0
    state.Text = self.value and (options.onText or "Enabled") or (options.offText or "Disabled")
    ctx:Animate(
      self.scope,
      track,
      { BackgroundColor3 = self.value and t.colors.accent or t.colors.border },
      t.motion.fast
    )
    ctx:Animate(self.scope, thumb, { Position = UDim2.fromOffset(self.value and 23 or 3, 3) }, t.motion.fast)
  end)
  self.scope:Add(button.Activated:Connect(function()
    if not self:IsDisabled() then
      self:SetValue(not self.value)
    end
  end))
  self:Initialize(function(value)
    if value == nil then
      return false
    end
    if type(value) ~= "boolean" then
      return nil, "Expected boolean"
    end
    return value
  end, paint)
  self.button = button
  return self
end
function Actions.Keybind(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local button = Base.button(self, self.content, "")
  local capturing = false
  local function render()
    local t = ctx.theme
    button.Text = capturing and "Press a key · Esc to cancel"
      or (self.value == Enum.KeyCode.Unknown and "Unbound" or self.value.Name)
    button.BackgroundColor3 = capturing and t.colors.accent or t.colors.input
    button.TextColor3 = t.colors.text
    button.TextTransparency = self:IsDisabled() and 0.5 or 0
  end
  self.scope:Add(button.Activated:Connect(function()
    if self:IsDisabled() then
      return
    end
    capturing = true
    render()
    ctx:Capture(self.scope, function(key, cancelled)
      capturing = false
      if not cancelled then
        self:SetValue(key)
      end
      render()
    end)
  end))
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  self:Initialize(function(value)
    if value == nil then
      return Enum.KeyCode.Unknown
    end
    if
      typeof(value) ~= "EnumItem"
      or (
        value.EnumType ~= Enum.KeyCode
        and value ~= Enum.UserInputType.MouseButton1
        and value ~= Enum.UserInputType.MouseButton2
        and value ~= Enum.UserInputType.MouseButton3
      )
    then
      return nil, "Expected KeyCode"
    end
    return value
  end, render)
  if options.onTrigger then
    ctx:BindKey(self.scope, function()
      return self.value
    end, function(down)
      if not self:IsDisabled() or not down then
        options.onTrigger(down)
      end
    end, options.hold)
  end
  return self
end
function Actions.Checkbox(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local button = Base.button(self, self.content, "")
  local function render()
    button.Text = (self.value and "☑  " or "☐  ") .. (options.text or "Selected")
    button.TextColor3 = self.value and ctx.theme.colors.text or ctx.theme.colors.muted
    button.BackgroundColor3 = self.value and ctx.theme.colors.accent or ctx.theme.colors.input
    button.TextTransparency = self:IsDisabled() and 0.5 or 0
  end
  self.scope:Add(button.Activated:Connect(function()
    if not self:IsDisabled() then
      self:SetValue(not self.value)
    end
  end))
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  self.button = button
  return self:Initialize(function(value)
    if value == nil then
      return false
    end
    if type(value) ~= "boolean" then
      return nil, "Expected boolean"
    end
    return value
  end, render)
end
return Actions
