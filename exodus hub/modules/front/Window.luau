local Signal = require(script.Parent.core.Signal)
local Layout = require(script.Parent.components.Layout)
local Window = {}
Window.__index = Window
function Window.new(ctx, options)
  options = options or {}
  local self = setmetatable(
    { ctx = ctx, scope = ctx.scope:Child(), pages = {}, order = {}, options = options, visible = options.visible ~= false, generation = 0 },
    Window
  )
  self.Changed = self.scope:Add(Signal.new(ctx.onError))
  local t = ctx.theme
  self.root = self.scope:Add(ctx:Create("CanvasGroup", {
    Name = options.id or "Window",
    Size = UDim2.fromOffset(options.width or t.size.windowWidth, options.height or t.size.windowHeight),
    Position = UDim2.fromScale(0.5, 0.5),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = t.colors.background,
    BackgroundTransparency = t.transparency.window,
    BorderSizePixel = 0,
    Visible = self.visible,
    ClipsDescendants = true,
    ZIndex = 1,
  }, ctx.root))
  ctx:Round(self.root, t.radius.window)
  local border = ctx:Outline(self.root, t.colors.accent)
  border.Thickness = 1.5
  local gradient = ctx:Create("UIGradient", { Color = ColorSequence.new(t.colors.outlineStart, t.colors.outlineEnd), Rotation = 25 }, border)
  local header = ctx:Create("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, t.size.header),
    BackgroundColor3 = t.colors.surface,
    BackgroundTransparency = t.transparency.header,
    BorderSizePixel = 0,
  }, self.root)
  ctx:Round(header, t.radius.window)
  local titleGroup = ctx:Create("Frame", { Size = UDim2.new(1, -96, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1 }, header)
  self.title = ctx:Text(titleGroup, options.title or "UI Library", {
    Size = UDim2.new(options.subtitle and 0.57 or 1, 0, 1, 0),
    Font = t.font.bold,
    TextSize = t.text.title,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextWrapped = false,
  })
  local subtitle = ctx:Text(titleGroup, options.subtitle or "", {
    Size = UDim2.new(0.43, 0, 1, 0),
    Position = UDim2.fromScale(0.57, 0),
    TextColor3 = t.colors.muted,
    TextSize = t.text.body,
    TextTruncate = Enum.TextTruncate.AtEnd,
    TextWrapped = false,
  })
  local function button(parent, name, text, size, position, callback)
    local control = ctx:Create("TextButton", {
      Name = name,
      Text = text,
      Size = size,
      Position = position,
      BackgroundColor3 = t.colors.hover,
      BackgroundTransparency = t.transparency.button,
      BorderSizePixel = 0,
      TextColor3 = t.colors.text,
      TextSize = t.text.body,
      Font = t.font.bold,
      AutoButtonColor = false,
    }, parent)
    ctx:Round(control, t.radius.control)
    ctx:Interactive(self.scope, control, function() return false end, function(_, focused)
      control.TextColor3 = ctx.theme.colors.text
      control.BackgroundTransparency = focused and 0 or ctx.theme.transparency.button
    end)
    self.scope:Add(control.Activated:Connect(callback))
    return control
  end
  self.minimize = button(header, "Minimize", "−", UDim2.fromOffset(30, 30), UDim2.new(1, -44, 0.5, -15), function() self:SetVisible(false) end)
  self.settings = button(header, "Settings", "⚙", UDim2.fromOffset(30, 30), UDim2.new(1, -80, 0.5, -15), function()
    if options.settingsPage and self.pages[options.settingsPage] then
      self:SelectPage(options.settingsPage)
    end
  end)
  self.settings.Visible = options.settingsPage ~= nil
  self.body = ctx:Create(
    "Frame",
    { Name = "Body", Position = UDim2.fromOffset(144, 64), Size = UDim2.new(1, -158, 1, -110), BackgroundTransparency = 1, ClipsDescendants = true },
    self.root
  )
  self.footer =
    ctx:Create("Frame", { Name = "Footer", Position = UDim2.new(0, 14, 1, -40), Size = UDim2.new(1, -28, 0, 26), BackgroundTransparency = 1 }, self.root)
  self.nav = ctx:Create("ScrollingFrame", {
    Name = "Navigation",
    Active = true,
    Position = UDim2.fromOffset(14, 64),
    Size = UDim2.new(0, 112, 1, -78),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    CanvasSize = UDim2.new(),
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = t.colors.accent,
  }, self.root)
  ctx:Padding(self.nav, 2)
  self.navLayout = ctx:List(self.nav, false, 6)
  self.pageLabel = ctx:Text(
    self.footer,
    "",
    { Position = UDim2.fromOffset(0, 0), Size = UDim2.new(0, 110, 1, 0), TextSize = 10, Font = t.font.bold, TextTruncate = Enum.TextTruncate.AtEnd }
  )
  self.actions = {}
  for index, action in ipairs(options.actions or {}) do
    local control = button(
      self.footer,
      action.id or "Action",
      action.text,
      UDim2.new(0, 108, 1, 0),
      UDim2.new(1, -(#options.actions - index + 1) * 114 + 6, 0, 0),
      function() action.onClick(self) end
    )
    self.actions[index] = { button = control, definition = action }
  end
  self.dragged = ctx:Drag(self.scope, header, self.root, options.onMove)
  local function responsive()
    local bounds, theme = ctx.root.AbsoluteSize, ctx.theme
    local width = math.min(options.width or theme.size.windowWidth, math.max(200, bounds.X - 24))
    local height = math.min(options.height or theme.size.windowHeight, math.max(200, bounds.Y - 24))
    self.root.Size = UDim2.fromOffset(width, height)
    local compact = width < theme.size.breakpoint
    for _, page in pairs(self.pages) do
      local stacked = compact and #page.columns > 1
      page.root.AutomaticCanvasSize = stacked and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
      for index, col in ipairs(page.columns) do
        col.root.ScrollingEnabled = not stacked
        col.root.AutomaticCanvasSize = not stacked and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
        col.root.Size = stacked and UDim2.new(1, 0, 0, col.layout.AbsoluteContentSize.Y + 8)
          or UDim2.new(1 / #page.columns, -12 * (#page.columns - 1) / #page.columns, 1, 0)
        local y = 0
        if stacked then
          for previous = 1, index - 1 do
            y += page.columns[previous].layout.AbsoluteContentSize.Y + 24
          end
        end
        col.root.Position = stacked and UDim2.fromOffset(0, y) or UDim2.new((index - 1) / #page.columns, 12 * (index - 1) / #page.columns, 0, 0)
      end
    end
    local navWidth = compact and 80 or theme.size.sidebar
    local left = 14 + navWidth + 16
    self.nav.Size = UDim2.new(0, navWidth, 1, -78)
    self.body.Position = UDim2.fromOffset(left, 64)
    self.body.Size = UDim2.new(1, -left - 14, 1, -110)
    self.footer.Position = UDim2.new(0, left, 1, -40)
    self.footer.Size = UDim2.new(1, -left - 14, 0, 26)
    self.pageLabel.Visible = not compact
    for _, page in pairs(self.pages) do
      page.button.Size = UDim2.new(1, -4, 0, 30)
      page.button.TextSize = compact and theme.text.caption or theme.text.body
    end
    for index, item in ipairs(self.actions) do
      item.button.Position = UDim2.new(1, -(#self.actions - index + 1) * 114 + 6, 0, 0)
      item.button.Size = UDim2.fromOffset(108, 26)
      if compact then
        item.button.Position = UDim2.new((index - 1) / #self.actions, 0, 0, 0)
        item.button.Size = UDim2.new(1 / #self.actions, -4, 1, 0)
      end
    end
    if self.root.AnchorPoint == Vector2.zero then
      self.root.Position = UDim2.fromOffset(
        math.clamp(self.root.Position.X.Offset, 0, math.max(0, bounds.X - width)),
        math.clamp(self.root.Position.Y.Offset, 0, math.max(0, bounds.Y - height))
      )
    end
  end
  self.responsive = responsive
  self.scope:Add(ctx.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(responsive))
  ctx:WatchTheme(self.scope, function(theme)
    self.root.BackgroundColor3 = theme.colors.background
    self.root.BackgroundTransparency = theme.transparency.window
    header.BackgroundColor3 = theme.colors.surface
    header.BackgroundTransparency = theme.transparency.header
    self.title.TextColor3 = theme.colors.text
    subtitle.TextColor3 = theme.colors.muted
    gradient.Color = ColorSequence.new(theme.colors.outlineStart, theme.colors.outlineEnd)
    border.Color = theme.colors.accent
    self.minimize.BackgroundColor3 = theme.colors.hover
    self.settings.BackgroundColor3 = theme.colors.hover
    self.pageLabel.TextColor3 = theme.colors.text
    for _, item in ipairs(self.actions) do
      item.button.BackgroundColor3 = theme.colors[item.definition.variant or "button"] or theme.colors.button
    end
    responsive()
  end)
  return self
end
function Window:Page(options)
  assert(type(options.id) == "string" and not self.pages[options.id], "Page requires unique id")
  local ctx, scope = self.ctx, self.scope:Child()
  local group = scope:Add(
    ctx:Create(
      "CanvasGroup",
      { Name = options.id .. "Transition", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 0, Visible = false },
      self.body
    )
  )
  local frame = scope:Add(ctx:Create("ScrollingFrame", {
    Name = options.id,
    Active = true,
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = ctx.theme.colors.accent,
    CanvasSize = UDim2.new(),
    Visible = false,
    ScrollingDirection = Enum.ScrollingDirection.Y,
  }, group))
  local page = { group = group, root = frame, scope = scope, columns = {}, window = self, title = options.title or options.id }
  local function column()
    local root = ctx:Create("ScrollingFrame", {
      Name = "Column" .. (#page.columns + 1),
      Active = true,
      BackgroundTransparency = 1,
      BorderSizePixel = 0,
      ScrollBarThickness = 2,
      ScrollBarImageColor3 = ctx.theme.colors.accent,
      CanvasSize = UDim2.new(),
      AutomaticCanvasSize = Enum.AutomaticSize.Y,
      ScrollingDirection = Enum.ScrollingDirection.Y,
    }, frame)
    ctx:Padding(root, 2)
    local list = ctx:List(root, false, 14)
    local col = { root = root, layout = list, sections = {} }
    function col:Section(props)
      props = table.clone(props or {})
      props.scope = scope
      props.order = #self.sections + 1
      local section = Layout.Section(ctx, root, props)
      table.insert(self.sections, section)
      return section
    end
    function col:Add(kind, props)
      props = table.clone(props or {})
      props.scope = scope
      props.order = #self.sections + 1
      local component = ctx:Component(kind, root, props)
      table.insert(self.sections, component)
      return component
    end
    scope:Add(list:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(self.responsive))
    table.insert(page.columns, col)
    return col
  end
  for _ = 1, options.columns or 1 do
    column()
  end
  function page:Column(index)
    assert(self.columns[index], "Unknown column")
    return self.columns[index]
  end
  function page:Section(props) return self.columns[1]:Section(props) end
  function page:Add(kind, props) return self.columns[1]:Add(kind, props) end
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
    window:UpdateNavigation()
  end
  page.button = ctx:Create("TextButton", {
    Name = options.id,
    Text = page.title,
    Size = UDim2.new(1, -4, 0, 30),
    BackgroundColor3 = ctx.theme.colors.hover,
    BackgroundTransparency = 0.55,
    BorderSizePixel = 0,
    Font = ctx.theme.font.medium,
    TextColor3 = ctx.theme.colors.muted,
    TextSize = ctx.theme.text.body,
    AutoButtonColor = false,
    TextTruncate = Enum.TextTruncate.AtEnd,
    LayoutOrder = #self.order + 1,
  }, self.nav)
  ctx:Round(page.button, ctx.theme.radius.control)
  scope:Add(page.button)
  scope:Add(page.button.Activated:Connect(function() self:SelectPage(options.id) end))
  local focus = ctx:Outline(page.button)
  ctx:Interactive(scope, page.button, function() return false end, function(_, focused)
    focus.Color = ctx.theme.colors.outlineStart
    focus.Transparency = focused and 0.1 or 1
  end)
  ctx:WatchTheme(scope, function(t)
    page.button.TextColor3 = self.active == options.id and t.colors.text or t.colors.muted
    page.button.BackgroundColor3 = self.active == options.id and t.colors.accent or t.colors.hover
    page.button.BackgroundTransparency = self.active == options.id and 0.15 or 0.65
  end)
  self.pages[options.id] = page
  table.insert(self.order, options.id)
  if not self.active then
    self:SelectPage(options.id)
  end
  self.responsive()
  self:UpdateNavigation()
  return page
end
function Window:UpdateNavigation()
  local page = self.pages[self.active]
  self.pageLabel.Text = page and page.title or ""

end
function Window:Step(direction)
  if #self.order == 0 then
    return
  end
  local index = table.find(self.order, self.active) or 1
  local id = self.order[math.clamp(index + direction, 1, #self.order)]
  if id then
    self:SelectPage(id)
  end
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
    page.group.Visible = key == id
    if key == id then
      page.group.GroupTransparency = self.ctx.reducedMotion and 0 or 1
      page.group.Position = UDim2.fromOffset(self.ctx.reducedMotion and 0 or 12, 0)
      self.ctx:Animate(page.scope, page.group, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) }, self.ctx.theme.motion.normal)
    end
    page.button.TextColor3 = key == id and self.ctx.theme.colors.text or self.ctx.theme.colors.muted
    page.button.BackgroundColor3 = key == id and self.ctx.theme.colors.accent or self.ctx.theme.colors.hover
    page.button.BackgroundTransparency = key == id and 0.15 or 0.65
  end
  self:UpdateNavigation()
  self.Changed:Fire(id)
  self.ctx.Events:Fire("page", id)
end
function Window:SetVisible(visible)
  self.generation += 1
  local generation = self.generation
  self.visible = visible == true
  if self.visible then
    self.root.Visible = true
    self.root.GroupTransparency = 1
    self.ctx:Animate(self.scope, self.root, { GroupTransparency = 0 }, 0.26)
  else
    self.ctx:ClosePopup()
    self.ctx:CancelCapture()
    self.ctx:Animate(self.scope, self.root, { GroupTransparency = 1 }, 0.2)
    if self.ctx.reducedMotion then
      self.root.Visible = false
    else
      self.scope:Delay(0.2, function()
        if self.generation == generation then
          self.root.Visible = false
        end
      end)
    end
  end
  self.ctx.Events:Fire("visibility", self.options.id, self.visible)
end
function Window:Toggle() self:SetVisible(not self.visible) end
function Window:Destroy() self.scope:Destroy() end
return Window
