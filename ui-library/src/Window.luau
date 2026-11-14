local Signal = require(script.Parent.core.Signal)
local Layout = require(script.Parent.components.Layout)
local Window = {}
Window.__index = Window
function Window.new(ctx, options)
  options = options or {}
  local self = setmetatable({
    ctx = ctx,
    scope = ctx.scope:Child(),
    pages = {},
    order = {},
    options = options,
    visible = options.visible ~= false,
  }, Window)
  self.Changed = self.scope:Add(Signal.new(ctx.onError))
  self.root = self.scope:Add(ctx:Create("CanvasGroup", {
    Name = options.id or "Window",
    Size = UDim2.fromOffset(options.width or 760, options.height or 540),
    Position = UDim2.fromScale(0.5, 0.5),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = ctx.theme.colors.background,
    BorderSizePixel = 0,
    Visible = self.visible,
    ClipsDescendants = true,
    ZIndex = 1,
  }, ctx.root))
  ctx:Round(self.root, ctx.theme.radius.window)
  local border = ctx:Outline(self.root)
  local gradient = ctx:Create(
    "UIGradient",
    { Color = ColorSequence.new(ctx.theme.colors.outlineStart, ctx.theme.colors.outlineEnd), Rotation = 25 },
    border
  )
  local header = ctx:Create("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 64),
    BackgroundColor3 = ctx.theme.colors.surface,
    BorderSizePixel = 0,
  }, self.root)
  self.title = ctx:Text(header, options.title or "UI Library", {
    Position = UDim2.fromOffset(16, 8),
    Size = UDim2.new(1, -136, 0, 28),
    TextSize = ctx.theme.text.title,
    Font = ctx.theme.font.bold,
    TextTruncate = Enum.TextTruncate.AtEnd,
  })
  local subtitle = ctx:Text(header, options.subtitle or "", {
    Position = UDim2.fromOffset(16, 36),
    Size = UDim2.new(1, -136, 0, 20),
    TextColor3 = ctx.theme.colors.muted,
    TextSize = ctx.theme.text.caption,
    TextTruncate = Enum.TextTruncate.AtEnd,
  })
  local function headerButton(text, x, callback)
    local button = ctx:Create("TextButton", {
      Text = text,
      Position = UDim2.new(1, x, 0, 12),
      Size = UDim2.fromOffset(40, 40),
      BackgroundColor3 = ctx.theme.colors.hover,
      TextColor3 = ctx.theme.colors.text,
      BorderSizePixel = 0,
      TextSize = 20,
      Font = ctx.theme.font.medium,
      AutoButtonColor = false,
    }, header)
    ctx:Round(button)
    self.scope:Add(button.Activated:Connect(callback))
    return button
  end
  self.minimize = headerButton("−", -96, function()
    self:SetVisible(false)
  end)
  self.close = headerButton("×", -48, function()
    if options.onClose then
      options.onClose(self)
    else
      self:Destroy()
    end
  end)
  self.nav = ctx:Create("ScrollingFrame", {
    Name = "Navigation",
    Position = UDim2.fromOffset(12, 76),
    Size = UDim2.new(0, 160, 1, -88),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 2,
  }, self.root)
  self.navLayout = ctx:List(self.nav, false, 4)
  self.body = ctx:Create("Frame", {
    Name = "Body",
    Position = UDim2.fromOffset(188, 76),
    Size = UDim2.new(1, -200, 1, -88),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
  }, self.root)
  local dragged = ctx:Drag(self.scope, header, self.root, options.onMove)
  self.scope:Add(self.root:GetPropertyChangedSignal("Visible"):Connect(function()
    if not self.root.Visible then
      ctx:ClosePopup()
      ctx:CancelCapture()
    end
  end))
  local function responsive()
    local t, bounds = ctx.theme, ctx.root.AbsoluteSize
    local width = math.max(160, math.min(options.width or 760, bounds.X - 24))
    local height = math.max(160, math.min(options.height or 540, bounds.Y - 24))
    self.root.Size = UDim2.fromOffset(width, height)
    local compact = width < t.size.breakpoint
    self.nav.Position = UDim2.fromOffset(12, 76)
    self.nav.Size = compact and UDim2.new(1, -24, 0, 44) or UDim2.new(0, t.size.sidebar, 1, -88)
    self.nav.AutomaticCanvasSize = compact and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
    self.navLayout.FillDirection = compact and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
    self.body.Position = compact and UDim2.fromOffset(12, 132) or UDim2.fromOffset(t.size.sidebar + 28, 76)
    self.body.Size = compact and UDim2.new(1, -24, 1, -144) or UDim2.new(1, -t.size.sidebar - 40, 1, -88)
    for _, page in pairs(self.pages) do
      page.button.Size = compact and UDim2.fromOffset(120, 40) or UDim2.new(1, -4, 0, 40)
    end
    if self.root.AnchorPoint == Vector2.zero then
      self.root.Position = UDim2.fromOffset(
        math.clamp(self.root.Position.X.Offset, 0, math.max(0, bounds.X - width)),
        math.clamp(self.root.Position.Y.Offset, 0, math.max(0, bounds.Y - height))
      )
    end
  end
  self.scope:Add(ctx.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(responsive))
  ctx:WatchTheme(self.scope, function(t)
    self.root.BackgroundColor3 = t.colors.background
    header.BackgroundColor3 = t.colors.surface
    self.title.TextColor3 = t.colors.text
    subtitle.TextColor3 = t.colors.muted
    gradient.Color = ColorSequence.new(t.colors.outlineStart, t.colors.outlineEnd)
    border.Color = t.colors.accent
    self.minimize.BackgroundColor3 = t.colors.hover
    self.close.BackgroundColor3 = t.colors.hover
    self.minimize.TextColor3 = t.colors.text
    self.close.TextColor3 = t.colors.text
    responsive()
  end)
  self.responsive = responsive
  self.dragged = dragged
  return self
end
function Window:Page(options)
  assert(type(options.id) == "string" and not self.pages[options.id], "Page requires unique id")
  local ctx = self.ctx
  local scope = self.scope:Child()
  local frame = scope:Add(ctx:Create("ScrollingFrame", {
    Name = options.id,
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    Visible = false,
    ScrollingDirection = Enum.ScrollingDirection.Y,
  }, self.body))
  ctx:Padding(frame, 4)
  ctx:List(frame, false, ctx.theme.space.lg)
  local button = scope:Add(ctx:Create("TextButton", {
    Text = options.title or options.id,
    Size = UDim2.new(1, -4, 0, 40),
    BackgroundColor3 = ctx.theme.colors.input,
    TextColor3 = ctx.theme.colors.text,
    BorderSizePixel = 0,
    TextSize = ctx.theme.text.body,
    Font = ctx.theme.font.medium,
    AutoButtonColor = false,
    LayoutOrder = #self.order + 1,
    TextTruncate = Enum.TextTruncate.AtEnd,
  }, self.nav))
  ctx:Round(button)
  local page = { root = frame, button = button, scope = scope, sections = {}, window = self }
  function page:Section(props)
    props = table.clone(props or {})
    props.scope = scope
    props.order = #self.sections + 1
    local section = Layout.Section(ctx, frame, props)
    table.insert(self.sections, section)
    return section
  end
  function page:Add(kind, props)
    props = table.clone(props or {})
    props.scope = scope
    props.order = #self.sections + 1
    local component = ctx:Component(kind, frame, props)
    table.insert(self.sections, component)
    return component
  end
  function page:Destroy()
    local window = self.window
    window.pages[options.id] = nil
    local at = table.find(window.order, options.id)
    if at then
      table.remove(window.order, at)
    end
    scope:Destroy()
    if window.active == options.id then
      window.active = nil
      if window.order[1] then
        window:SelectPage(window.order[1])
      end
    end
  end
  scope:Add(button.Activated:Connect(function()
    self:SelectPage(options.id)
  end))
  self.pages[options.id] = page
  table.insert(self.order, options.id)
  ctx:WatchTheme(scope, function(t)
    button.BackgroundColor3 = self.active == options.id and t.colors.accent or t.colors.surface
    button.TextColor3 = t.colors.text
    frame.ScrollBarImageColor3 = t.colors.accent
  end)
  if not self.active then
    self:SelectPage(options.id)
  end
  self.responsive()
  return page
end
function Window:SelectPage(id)
  assert(self.pages[id], "Unknown page: " .. tostring(id))
  if self.active == id then
    return
  end
  self.ctx:ClosePopup()
  self.ctx:CancelCapture()
  self.active = id
  for key, page in pairs(self.pages) do
    page.root.Visible = key == id
    page.button.BackgroundColor3 = key == id and self.ctx.theme.colors.accent or self.ctx.theme.colors.surface
  end
  self.Changed:Fire(id)
  self.ctx.Events:Fire("page", id)
end
function Window:SetVisible(visible)
  self.visible = visible == true
  self.root.Visible = self.visible
  if visible then
    self.root.GroupTransparency = 1
    self.ctx:Animate(self.scope, self.root, { GroupTransparency = 0 })
  end
  self.ctx.Events:Fire("visibility", self.options.id, self.visible)
end
function Window:Toggle()
  self:SetVisible(not self.visible)
end
function Window:Destroy()
  self.scope:Destroy()
end
return Window
