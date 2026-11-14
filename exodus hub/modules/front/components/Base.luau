local Signal = require(script.Parent.Parent.core.Signal)
local function copy(value)
  if typeof(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end
local Base = {}
Base.__index = Base
-- Card geometry is derived from the original frontend: 48px rows, 30px controls,
-- 12px corners and one shared translucent surface. Inline and stacked are variants.
function Base.new(ctx, parent, options, bare)
  options = options or {}
  local scope = (options.scope or ctx.scope):Child()
  local t = ctx.theme
  local controlHeight = t.size[options.size or "control"] or t.size.control
  local inline = options.layout == "inline"
  local height = options.height or (inline and t.size.row or 64) + (options.description and 22 or 0)
  local self = setmetatable(
    { ctx = ctx, scope = scope, options = options, disabled = options.disabled == true, loading = options.loading == true, value = options.value },
    Base
  )
  self.Changed = scope:Add(Signal.new(ctx.onError))
  self.Activated = scope:Add(Signal.new(ctx.onError))
  self.root = scope:Add(ctx:Create("Frame", {
    Name = options.id or options.kind or "Control",
    BackgroundColor3 = t.colors.elevated,
    BackgroundTransparency = t.transparency.card,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, height),
    LayoutOrder = options.order or 0,
    Visible = options.visible ~= false,
  }, parent))
  self.corner = ctx:Round(self.root, t.radius.card)
  if not bare then
    self.outline = ctx:Outline(self.root)
    local right = options.controlWidth or 92
    self.title = ctx:Text(self.root, options.title or "", {
      Position = UDim2.fromOffset(14, inline and (options.description and 7 or 0) or 5),
      Size = inline and UDim2.new(1, -right - 40, 0, options.description and 20 or height) or UDim2.new(1, -28, 0, 18),
      TextTruncate = Enum.TextTruncate.AtEnd,
      TextWrapped = false,
      Font = t.font.medium,
      TextSize = inline and t.text.body or t.text.caption,
      TextColor3 = inline and t.colors.text or t.colors.accent,
    })
    if options.description then
      self.description = ctx:Text(self.root, options.description, {
        Position = UDim2.fromOffset(14, inline and 29 or 25),
        Size = inline and UDim2.new(1, -right - 40, 0, 30) or UDim2.new(1, -28, 0, 22),
        TextSize = t.text.caption,
        TextColor3 = t.colors.muted,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextTruncate = Enum.TextTruncate.AtEnd,
      })
    end
    self.content = ctx:Create("Frame", {
      Name = "Content",
      BackgroundTransparency = 1,
      Position = inline and UDim2.new(1, -right - 14, 0.5, -controlHeight / 2) or UDim2.new(0, 10, 1, -controlHeight - 6),
      Size = inline and UDim2.fromOffset(right, controlHeight) or UDim2.new(1, -20, 0, controlHeight),
    }, self.root)
  else
    self.content = self.root
  end
  ctx:WatchTheme(scope, function(theme)
    self.root.BackgroundColor3 = theme.colors.elevated
    self.root.BackgroundTransparency = bare and 1 or theme.transparency.card
    self.corner.CornerRadius = UDim.new(0, theme.radius.card)
    if self.outline then
      self.outline.Color = self.error and theme.colors.danger or theme.colors.border
    end
    if self.title then
      self.title.TextColor3 = inline and theme.colors.text or theme.colors.accent
      self.title.TextSize = inline and theme.text.body or theme.text.caption
      self.title.Font = inline and theme.font.medium or theme.font.bold
    end
    if self.description then
      self.description.TextColor3 = theme.colors.muted
      self.description.TextSize = theme.text.caption
    end
  end)
  return self
end
function Base.inline(options, width)
  local props = table.clone(options)
  props.layout = props.layout or "inline"
  props.controlWidth = props.controlWidth or width
  return props
end
function Base:Initialize(normalize, render)
  self.normalize = normalize
  self.render = render
  if self.options.key then
    local stored = self.ctx.store:Get(self.options.key)
    if stored ~= nil then
      self.value = stored
    end
    self.scope:Add(self.ctx.store:Subscribe(self.options.key, function(value) self:SetValue(value, true) end))
  end
  local value, reason = normalize(self.value)
  assert(reason == nil, reason)
  self.value = value
  render()
  return self
end
function Base:GetValue() return copy(self.value) end
function Base:SetValue(value, silent)
  if self.scope.destroyed then
    return false, "Control is destroyed"
  end
  local normalized, reason = self.normalize(value)
  if reason then
    self:SetError(reason)
    return false, reason
  end
  if self.options.validate then
    local ok, detail = self.options.validate(normalized)
    if not ok then
      self:SetError(detail or "Invalid value")
      return false, detail
    end
  end
  local previous = self.value
  if not silent and self.options.key then
    local ok, detail = self.ctx.store:Set(self.options.key, normalized)
    if not ok then
      self:SetError(detail)
      return false, detail
    end
  end
  self.value = normalized
  self:SetError(nil)
  if self.render then
    self.render()
  end
  if not silent and previous ~= normalized then
    self.Changed:Fire(normalized, previous)
    self.ctx.Events:Fire("change", self.options.id, normalized)
    if self.options.onChange then
      local ok, err = pcall(self.options.onChange, normalized, previous)
      if not ok then
        self.ctx.onError(err)
      end
    end
  end
  return true
end
function Base:SetDisabled(disabled)
  self.disabled = disabled == true
  if self.disabled then
    if self.ctx.popupOwner == self.scope then
      self.ctx:ClosePopup()
    end
    if self.ctx.captureOwner == self.scope then
      self.ctx:CancelCapture()
    end
  end
  if self.render then
    self.render()
  end
end
function Base:SetLoading(loading)
  self.loading = loading == true
  if self.render then
    self.render()
  end
end
function Base:IsDisabled() return self.disabled or self.loading end
function Base:SetVisible(visible)
  self.root.Visible = visible == true
  if not visible then
    self.ctx:CancelCapture()
    self.ctx:ClosePopup()
  end
end
function Base:SetText(text)
  self.options.title = text
  if self.title then
    self.title.Text = text
  end
  if self.render then
    self.render()
  end
end
function Base:SetError(message)
  local previous = self.error
  self.error = message
  if not message and not previous then
    return
  end
  if message and not previous then
    self._errorSize = self.root.Size
    self._contentPosition = self.content.Position
  end
  if message and not self.errorLabel then
    self.errorLabel = self.ctx:Text(self.root, "", {
      Position = UDim2.new(0, 12, 1, -28),
      Size = UDim2.new(1, -24, 0, 28),
      TextSize = self.ctx.theme.text.caption,
      TextColor3 = self.ctx.theme.colors.danger,
    })
  end
  if self.errorLabel then
    self.errorLabel.Text = tostring(message or "")
    self.errorLabel.Visible = message ~= nil
  end
  local size = self._errorSize
  if size then
    self.root.Size = UDim2.new(size.X.Scale, size.X.Offset, size.Y.Scale, size.Y.Offset + (message and 28 or 0))
  end
  if self.content ~= self.root and self._contentPosition then
    local p = self._contentPosition
    self.content.Position = UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset - (message and 28 * p.Y.Scale or 0))
  end
end
function Base:Destroy() self.scope:Destroy() end
function Base.button(self, parent, text, props)
  local defaults = {
    Text = text or "",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = self.ctx.theme.transparency.input,
    BackgroundColor3 = self.ctx.theme.colors.input,
    TextColor3 = self.ctx.theme.colors.text,
    Font = self.ctx.theme.font.medium,
    TextSize = self.ctx.theme.text.body,
    BorderSizePixel = 0,
    AutoButtonColor = false,
    TextTruncate = Enum.TextTruncate.AtEnd,
  }
  for k, v in pairs(props or {}) do
    defaults[k] = v
  end
  local button = self.ctx:Create("TextButton", defaults, parent)
  self.ctx:Round(button)
  if self.scope then
    local border = self.ctx:Outline(button)
    self.ctx:Interactive(self.scope, button, function() return self:IsDisabled() end, function(disabled, focused)
      border.Color = focused and self.ctx.theme.colors.outlineStart or self.ctx.theme.colors.border
      border.Transparency = disabled and 0.6 or (focused and 0 or 0.4)
      button.Selectable = not disabled
    end)
  end
  return button
end
return Base
