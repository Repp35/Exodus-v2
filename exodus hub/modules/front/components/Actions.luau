local Base = require(script.Parent.Base)
local Actions = {}
function Actions.Button(ctx, parent, options)
  local self = Base.new(ctx, parent, Base.inline(options, 92))
  local button = Base.button(self, self.content, options.text or "Run")
  local border = button:FindFirstChildOfClass("UIStroke")
  local function render(disabled, focused, pressed)
    local t = ctx.theme
    local tone = t.colors[options.variant or "button"] or t.colors.accent
    button.Text = self.loading and (options.loadingText or "Loading…") or options.text or "Run"
    button.Active = not disabled
    button.TextTransparency = disabled and 0.5 or 0
    border.Color = focused and t.colors.outlineStart or tone
    ctx:Animate(self.scope, button, {
      BackgroundColor3 = disabled and t.colors.hover or ((focused or pressed) and tone:Lerp(t.colors.text, pressed and 0.16 or 0.08) or tone),
    }, t.motion.fast)
  end
  local paint = ctx:Interactive(self.scope, button, function() return self:IsDisabled() end, render)
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
  ctx:Press(self.scope, button, self.root)
  self.button = button
  return self
end
function Actions.Toggle(ctx, parent, options)
  local width = options.variant == "status" and 44 or (options.shortcutKey and 102 or 48)
  local self = Base.new(ctx, parent, Base.inline(options, width))
  self.content.ZIndex = 3
  local hitbox = Base.button(self, self.root, "", { Name = "CardHitbox", BackgroundTransparency = 1, ZIndex = 2 })
  hitbox:FindFirstChildOfClass("UIStroke").Enabled = false
  local track = ctx:Create("Frame", {
    Name = "Track",
    Size = UDim2.fromOffset(48, 30),
    Position = UDim2.new(0, 0, 0.5, -15),
    BorderSizePixel = 0,
    BackgroundTransparency = ctx.theme.transparency.button,
  }, self.content)
  ctx:Round(track, 999)
  track.Visible = options.variant ~= "status"
  local thumb = ctx:Create(
    "Frame",
    { Name = "Thumb", Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(3, 5), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 },
    track
  )
  ctx:Round(thumb, 999)
  if options.shortcutKey then
    local keycap = Base.button(self, self.content, "", { Name = "Shortcut", Position = UDim2.new(1, -44, 0, 0), Size = UDim2.fromOffset(44, 28), ZIndex = 3 })
    local function keyText(value) keycap.Text = value and value.Name or "—" end
    self.scope:Add(ctx.store:Subscribe(options.shortcutKey, keyText, true))
    self.scope:Add(keycap.Activated:Connect(function()
      if self:IsDisabled() then
        return
      end
      keycap.Text = "…"
      ctx:Capture(self.scope, function(key, cancelled)
        if not cancelled then
          ctx.store:Set(options.shortcutKey, key)
        end
        keyText(ctx.store:Get(options.shortcutKey))
      end)
    end))
    self.keycap = keycap
    local function fit()
      local show = self.root.AbsoluteSize.X >= 280 or options.variant == "status"
      keycap.Visible = show
      local w = options.variant == "status" and 44 or (show and 102 or 48)
      self.content.Size = UDim2.fromOffset(w, 30)
      self.content.Position = UDim2.new(1, -w - 14, 0.5, -15)
      self.title.Size = UDim2.new(1, -w - 40, 0, options.description and 20 or (self.root.Size.Y.Offset - (self.error and 28 or 0)))
    end
    self.scope:Add(self.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit))
    fit()
  end
  local paint = ctx:Interactive(self.scope, hitbox, function() return self:IsDisabled() end, function(disabled, focused)
    local t = ctx.theme
    hitbox.Active = not disabled
    self.title.TextTransparency = disabled and 0.5 or 0
    if options.variant == "status" then
      self.title.RichText = true
      local title = tostring(options.title or ""):gsub("&", "&amp;"):gsub("<", "&lt;")
      self.title.Text = title
        .. ': <font color="#'
        .. (self.value and t.colors.success or t.colors.danger):ToHex()
        .. '">'
        .. (self.value and "ON" or "OFF")
        .. "</font>"
    end
    self.outline.Color = focused and t.colors.accent or t.colors.border
    ctx:Animate(
      self.scope,
      track,
      { BackgroundColor3 = self.value and t.colors.toggleOn or t.colors.toggleOff, BackgroundTransparency = disabled and 0.5 or t.transparency.button },
      t.motion.normal
    )
    ctx:Animate(self.scope, thumb, { Position = UDim2.fromOffset(self.value and 25 or 3, 5) }, t.motion.normal)
  end)
  self.scope:Add(hitbox.Activated:Connect(function()
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
  ctx:Press(self.scope, hitbox, self.root)
  self.button, self.track, self.thumb = hitbox, track, thumb
  return self
end
function Actions.Keybind(ctx, parent, options)
  local self = Base.new(ctx, parent, Base.inline(options, 68))
  local button = Base.button(self, self.content, "")
  local capturing = false
  local function render()
    local t = ctx.theme
    button.Text = capturing and "Press a key · Esc to cancel" or (self.value == Enum.KeyCode.Unknown and "Unbound" or self.value.Name)
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
    ctx:BindKey(self.scope, function() return self.value end, function(down)
      if not self:IsDisabled() or not down then
        options.onTrigger(down)
      end
    end, options.hold)
  end
  return self
end
function Actions.Checkbox(ctx, parent, options)
  local props = Base.inline(options, 26)
  props.title = options.title or options.text or "Selected"
  local self = Base.new(ctx, parent, props)
  local button = Base.button(self, self.content, "", { Size = UDim2.fromOffset(24, 24), Position = UDim2.new(0, 0, 0.5, -12) })
  local function render()
    button.Text = self.value and "✓" or ""
    button.TextColor3 = ctx.theme.colors.text
    button.BackgroundColor3 = self.value and ctx.theme.colors.toggleOn or ctx.theme.colors.input
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
