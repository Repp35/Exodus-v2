local Base = require(script.Parent.Base)
local Display = {}
function Display.Label(ctx, parent, options)
  local props = table.clone(options)
  props.height = props.height or 44
  local self = Base.new(ctx, parent, props, true)
  local label = ctx:Text(self.root, options.text or options.title, {
    Position = UDim2.fromOffset(12, 0),
    Size = UDim2.new(1, -24, 1, 0),
    TextYAlignment = Enum.TextYAlignment.Center,
  })
  self.title = label
  function self:SetText(text)
    label.Text = text
  end
  return self
end
function Display.Badge(ctx, parent, options)
  local self = Display.Label(ctx, parent, options)
  ctx:WatchTheme(self.scope, function(t)
    local color = t.colors[options.variant or "accent"] or t.colors.accent
    self.root.BackgroundColor3 = color:Lerp(t.colors.background, 0.8)
    self.title.TextColor3 = color
  end)
  return self
end
function Display.Alert(ctx, parent, options)
  local props = table.clone(options)
  props.height = props.height or 88
  local self = Base.new(ctx, parent, props, true)
  self.title = ctx:Text(
    self.root,
    options.title or "Information",
    { Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 24), Font = ctx.theme.font.bold }
  )
  local description = ctx:Text(self.root, options.description or "", {
    Position = UDim2.fromOffset(12, 34),
    Size = UDim2.new(1, -24, 1, -42),
    TextSize = ctx.theme.text.caption,
    TextYAlignment = Enum.TextYAlignment.Top,
  })
  ctx:WatchTheme(self.scope, function(t)
    local color = t.colors[options.variant or "info"] or t.colors.info
    self.root.BackgroundColor3 = color:Lerp(t.colors.background, 0.85)
    self.title.TextColor3 = color
    description.TextColor3 = t.colors.text
  end)
  return self
end
function Display.Progress(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local rail = ctx:Create(
    "Frame",
    { Position = UDim2.new(0, 0, 0.5, -4), Size = UDim2.new(1, -56, 0, 8), BorderSizePixel = 0 },
    self.content
  )
  ctx:Round(rail, 4)
  local fill = ctx:Create("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0 }, rail)
  ctx:Round(fill, 4)
  local value = ctx:Text(self.content, "", {
    Position = UDim2.new(1, -48, 0, 0),
    Size = UDim2.new(0, 48, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Right,
  })
  local function render()
    ctx:Animate(self.scope, fill, {
      Size = UDim2.fromScale(self.value, 1),
      BackgroundColor3 = ctx.theme.colors[options.variant or "accent"] or ctx.theme.colors.accent,
    })
    rail.BackgroundColor3 = ctx.theme.colors.border
    value.TextColor3 = ctx.theme.colors.muted
    value.Text = string.format("%d%%", self.value * 100)
  end
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(function(v)
    v = v or 0
    if type(v) ~= "number" or v ~= v or math.abs(v) == math.huge then
      return nil, "Expected finite ratio"
    end
    return math.clamp(v, 0, 1)
  end, render)
end
function Display.Separator(ctx, parent, options)
  local props = table.clone(options)
  props.height = 16
  local self = Base.new(ctx, parent, props, true)
  self.root.BackgroundTransparency = 1
  local line = ctx:Create(
    "Frame",
    { Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 1), BorderSizePixel = 0 },
    self.root
  )
  ctx:WatchTheme(self.scope, function(t)
    line.BackgroundColor3 = t.colors.border
  end)
  return self
end
function Display.Stat(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local label = ctx:Text(
    self.content,
    "",
    { Size = UDim2.fromScale(1, 1), TextSize = ctx.theme.text.heading, Font = ctx.theme.font.bold }
  )
  local function render()
    label.Text = tostring(self.value)
    label.TextColor3 = ctx.theme.colors[options.variant or "text"] or ctx.theme.colors.text
  end
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(function(v)
    return if v == nil then "—" else v
  end, render)
end
function Display.Image(ctx, parent, options)
  local props = table.clone(options)
  props.height = props.height or 160
  local self = Base.new(ctx, parent, props, true)
  local picture = ctx:Create("ImageLabel", {
    Image = options.image or "",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ScaleType = Enum.ScaleType.Fit,
  }, self.root)
  self.image = picture
  return self
end
function Display.Skeleton(ctx, parent, options)
  local self = Base.new(ctx, parent, options, true)
  for index, width in ipairs({ 0.45, 0.85, 0.65 }) do
    local line = ctx:Create("Frame", {
      Position = UDim2.fromOffset(12, 12 + (index - 1) * 20),
      Size = UDim2.new(width, -24, 0, 10),
      BorderSizePixel = 0,
    }, self.root)
    ctx:Round(line, 4)
    ctx:WatchTheme(self.scope, function(t)
      line.BackgroundColor3 = t.colors.hover
    end)
  end
  return self
end
function Display.EmptyState(ctx, parent, options)
  local props = table.clone(options)
  props.title = options.title or "Nothing here yet"
  props.description = options.description or "Add an item to get started."
  return Display.Alert(ctx, parent, props)
end
return Display
