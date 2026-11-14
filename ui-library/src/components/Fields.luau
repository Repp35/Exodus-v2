local Base = require(script.Parent.Base)
local Fields = {}
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function numberNormalizer(options)
  local min, max, step = options.min or 0, options.max or 100, options.step or 1
  assert(finite(min) and finite(max) and max > min and finite(step) and step > 0, "Invalid numeric range")
  return function(value)
    value = if value == nil then min else tonumber(value)
    if not finite(value) then
      return nil, "Enter a finite number"
    end
    value = math.clamp(value, min, max)
    return math.clamp(min + math.round((value - min) / step) * step, min, max)
  end
end
function Fields.Input(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local box = ctx:Create("TextBox", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = ctx.theme.colors.input,
    BorderSizePixel = 0,
    TextColor3 = ctx.theme.colors.text,
    Font = ctx.theme.font.regular,
    TextSize = ctx.theme.text.body,
    Text = "",
    PlaceholderText = options.placeholder or "Enter value…",
    PlaceholderColor3 = ctx.theme.colors.muted,
    ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Left,
    MultiLine = options.multiline == true,
  }, self.content)
  ctx:Round(box)
  ctx:Padding(box, 8)
  local border = ctx:Outline(box)
  local focused = false
  local function render()
    local t = ctx.theme
    box.TextEditable = not self:IsDisabled() and not options.readOnly
    box.TextColor3 = t.colors.text
    box.PlaceholderColor3 = t.colors.muted
    box.BackgroundColor3 = t.colors.input
    box.TextTransparency = self:IsDisabled() and 0.5 or 0
    border.Color = self.error and t.colors.danger or (focused and t.colors.accent or t.colors.border)
    if not focused then
      box.Text = tostring(self.value or "")
    end
  end
  local normalize = options.numeric and numberNormalizer(options)
    or function(value)
      if value == nil then
        return ""
      end
      if type(value) ~= "string" then
        return nil, "Expected text"
      end
      if options.maxLength and utf8.len(value) and utf8.len(value) > options.maxLength then
        return nil, "Text is too long"
      end
      return value
    end
  self.scope:Add(box.Focused:Connect(function()
    focused = true
    render()
  end))
  self.scope:Add(box.FocusLost:Connect(function()
    focused = false
    if not self:IsDisabled() and not options.readOnly then
      self:SetValue(box.Text)
    end
    render()
  end))
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  self.input = box
  return self:Initialize(normalize, render)
end
function Fields.NumberInput(ctx, parent, options)
  local props = table.clone(options)
  props.numeric = true
  return Fields.Input(ctx, parent, props)
end
function Fields.Slider(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local normalize = numberNormalizer(options)
  local min, max = options.min or 0, options.max or 100
  local rail = Base.button(self, self.content, "", { Size = UDim2.new(1, -88, 1, 0) })
  local line = ctx:Create(
    "Frame",
    { Size = UDim2.new(1, -16, 0, 6), Position = UDim2.new(0, 8, 0.5, -3), BorderSizePixel = 0 },
    rail
  )
  ctx:Round(line, 3)
  local fill = ctx:Create("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0 }, line)
  ctx:Round(fill, 3)
  local thumb = ctx:Create("Frame", {
    Size = UDim2.fromOffset(16, 16),
    Position = UDim2.new(0, 0, 0.5, 0),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BorderSizePixel = 0,
  }, line)
  ctx:Round(thumb, 8)
  local value = ctx:Text(self.content, "", {
    Position = UDim2.new(1, -80, 0, 0),
    Size = UDim2.new(0, 80, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Right,
  })
  local active
  local function update(input)
    if self:IsDisabled() or line.AbsoluteSize.X <= 0 then
      return
    end
    local ratio = math.clamp((input.Position.X - line.AbsolutePosition.X) / line.AbsoluteSize.X, 0, 1)
    self:SetValue(min + ratio * (max - min))
  end
  self.scope:Add(rail.InputBegan:Connect(function(input)
    if
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.Touch
    then
      active = input
      update(input)
    end
  end))
  self.scope:Add(ctx.InputChanged:Connect(function(input)
    if
      active
      and (
        input == active
        or (
          active.UserInputType ~= Enum.UserInputType.Touch
          and input.UserInputType == Enum.UserInputType.MouseMovement
        )
      )
    then
      update(input)
    end
  end))
  self.scope:Add(ctx.InputEnded:Connect(function(input)
    if input == nil or input == active then
      active = nil
    end
  end))
  self.scope:Add(rail.SelectionGained:Connect(function()
    self.selected = true
  end))
  self.scope:Add(rail.SelectionLost:Connect(function()
    self.selected = false
  end))
  self.scope:Add(ctx.InputBegan:Connect(function(input)
    if not self.selected or self:IsDisabled() then
      return
    end
    local key = input.KeyCode
    if key == Enum.KeyCode.Left or key == Enum.KeyCode.DPadLeft then
      self:SetValue(self.value - (options.step or 1))
    elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.DPadRight then
      self:SetValue(self.value + (options.step or 1))
    end
  end))
  local function render()
    local t = ctx.theme
    local ratio = (self.value - min) / (max - min)
    fill.Size = UDim2.fromScale(ratio, 1)
    thumb.Position = UDim2.new(ratio, 0, 0.5, 0)
    fill.BackgroundColor3 = t.colors.accent
    thumb.BackgroundColor3 = t.colors.text
    line.BackgroundColor3 = t.colors.border
    rail.BackgroundColor3 = t.colors.input
    rail.Active = not self:IsDisabled()
    value.TextColor3 = t.colors.muted
    value.Text = options.format and options.format(self.value)
      or string.format("%.3g%s", self.value, options.suffix or "")
    thumb.BackgroundTransparency = self:IsDisabled() and 0.5 or 0
  end
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(normalize, render)
end
function Fields.TextArea(ctx, parent, options)
  local props = table.clone(options)
  props.multiline = true
  props.height = options.height or 168
  local self = Fields.Input(ctx, parent, props)
  self.content.Position = UDim2.fromOffset(12, options.description and 60 or 36)
  self.content.Size = UDim2.new(1, -24, 1, options.description and -68 or -44)
  self.input.TextYAlignment = Enum.TextYAlignment.Top
  self.input.TextWrapped = true
  return self
end
return Fields
