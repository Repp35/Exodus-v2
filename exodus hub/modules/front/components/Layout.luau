local Base = require(script.Parent.Base)
local Layout = {}
function Layout.Stack(ctx, parent, options)
  local self = Base.new(ctx, parent, options, true)
  self.root.BackgroundTransparency = options.surface and ctx.theme.transparency.card or 1
  self.root.Size = UDim2.new(1, 0, 0, 0)
  self.root.AutomaticSize = Enum.AutomaticSize.Y
  self.content = ctx:Create("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, self.root)
  ctx:List(self.content, false, options.gap)
  self.children = {}
  function self:Add(kind, props)
    props = table.clone(props or {})
    props.scope = self.scope
    props.order = #self.children + 1
    local component = ctx:Component(kind, self.content, props)
    table.insert(self.children, component)
    return component
  end
  return self
end
function Layout.Section(ctx, parent, options)
  local self = Layout.Stack(ctx, parent, options)
  if options.surface then
    ctx:Padding(self.root)
  end
  self.title = ctx:Text(
    self.root,
    options.title or "Section",
    { Size = UDim2.new(1, 0, 0, 18), Font = ctx.theme.font.bold, TextSize = ctx.theme.text.caption, TextColor3 = ctx.theme.colors.accent }
  )
  ctx:WatchTheme(self.scope, function(t)
    self.title.TextColor3 = t.colors.accent
    self.title.TextSize = t.text.caption
    self.title.Font = t.font.bold
  end)
  self.content.Position = UDim2.fromOffset(0, 24)
  -- Explicit height from list avoids offset + AutomaticSize feedback loops.
  self.root.AutomaticSize = Enum.AutomaticSize.None
  local layout = self.content:FindFirstChildOfClass("UIListLayout")
  local function resize() self.root.Size = UDim2.new(1, 0, 0, layout.AbsoluteContentSize.Y + 24 + (options.surface and 24 or 0)) end
  self.scope:Add(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(resize))
  resize()
  return self
end
function Layout.Card(ctx, parent, options)
  local props = table.clone(options)
  props.surface = true
  return Layout.Section(ctx, parent, props)
end
function Layout.Accordion(ctx, parent, options)
  local self = Layout.Section(ctx, parent, options)
  local header = Base.button(self, self.root, options.title or "Section", { Size = UDim2.new(1, 0, 0, 32), TextXAlignment = Enum.TextXAlignment.Left })
  self.title.Visible = false
  self.content.Position = UDim2.fromOffset(0, 36)
  local layout = self.content:FindFirstChildOfClass("UIListLayout")
  local function render()
    self.content.Visible = self.value
    header.Text = (self.value and "▾  " or "▸  ") .. (options.title or "Section")
    header.BackgroundColor3 = ctx.theme.colors.surface
    header.TextColor3 = ctx.theme.colors.text
    self.root.Size = UDim2.new(1, 0, 0, self.value and layout.AbsoluteContentSize.Y + 36 or 32)
  end
  self.scope:Add(header.Activated:Connect(function()
    if not self:IsDisabled() then
      self:SetValue(not self.value)
    end
  end))
  self.scope:Add(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(render))
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(function(v) return v ~= false end, render)
end
function Layout.Grid(ctx, parent, options)
  local self = Layout.Stack(ctx, parent, options)
  self.content:FindFirstChildOfClass("UIListLayout"):Destroy()
  local grid = ctx:Create("UIGridLayout", {
    SortOrder = Enum.SortOrder.LayoutOrder,
    CellPadding = UDim2.fromOffset(ctx.theme.space.sm, ctx.theme.space.sm),
    CellSize = UDim2.new(0.5, -4, 0, options.cellHeight or 108),
  }, self.content)
  local function resize()
    local columns = self.root.AbsoluteSize.X < (options.breakpoint or 480) and 1 or (options.columns or 2)
    grid.CellSize = UDim2.new(1 / columns, -ctx.theme.space.sm * (columns - 1) / columns, 0, options.cellHeight or 108)
  end
  self.scope:Add(self.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
  resize()
  return self
end
function Layout.Tabs(ctx, parent, options)
  local props = table.clone(options)
  props.height = options.height or 320
  local self = Base.new(ctx, parent, props, true)
  local bar = ctx:Create("ScrollingFrame", {
    Size = UDim2.new(1, 0, 0, 36),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.X,
    ScrollBarThickness = 2,
  }, self.root)
  ctx:List(bar, true, 4)
  local tabs, count = {}, 0
  function self:SelectTab(id)
    assert(tabs[id], "Unknown tab")
    self.active = id
    ctx:ClosePopup()
    for key, tab in pairs(tabs) do
      tab.root.Visible = key == id
      tab.button.BackgroundColor3 = key == id and ctx.theme.colors.accent or ctx.theme.colors.input
    end
    self.Changed:Fire(id)
  end
  function self:Tab(definition)
    assert(type(definition.id) == "string" and not tabs[definition.id], "Expected unique tab id")
    count += 1
    local frame = ctx:Create("ScrollingFrame", {
      Position = UDim2.fromOffset(0, 44),
      Size = UDim2.new(1, 0, 1, -44),
      BackgroundTransparency = 1,
      BorderSizePixel = 0,
      CanvasSize = UDim2.new(),
      AutomaticCanvasSize = Enum.AutomaticSize.Y,
      ScrollBarThickness = 4,
    }, self.root)
    local stack = Layout.Stack(ctx, frame, { scope = self.scope })
    local button = Base.button(self, bar, definition.title or definition.id, { Size = UDim2.fromOffset(120, 30), LayoutOrder = count })
    tabs[definition.id] = { root = frame, button = button }
    self.scope:Add(button.Activated:Connect(function() self:SelectTab(definition.id) end))
    if not self.active then
      self:SelectTab(definition.id)
    else
      frame.Visible = false
    end
    return stack
  end
  ctx:WatchTheme(self.scope, function(t)
    for id, tab in pairs(tabs) do
      tab.button.TextColor3 = t.colors.text
      tab.button.BackgroundColor3 = id == self.active and t.colors.accent or t.colors.input
    end
  end)
  return self
end
return Layout
