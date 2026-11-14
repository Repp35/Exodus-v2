local Base = require(script.Parent.Base)
local Choice = {}
local function optionsList(options)
  assert(type(options.options) == "table" and #options.options > 0, "Expected non-empty options")
  local result, seen = {}, {}
  for _, option in ipairs(options.options) do
    local item = type(option) == "table" and table.clone(option) or { value = option, label = tostring(option) }
    assert(item.value ~= nil and not seen[item.value], "Duplicate or missing option value")
    item.label = item.label or tostring(item.value)
    seen[item.value] = true
    table.insert(result, item)
  end
  return result, seen
end
function Choice.Segmented(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local items, valid = optionsList(options)
  local track = ctx:Create("Frame", {
    Name = "Track",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = ctx.theme.colors.input,
    BackgroundTransparency = ctx.theme.transparency.input,
    BorderSizePixel = 0,
  }, self.content)
  ctx:Round(track, options.pill and 999 or ctx.theme.radius.control)
  ctx:Outline(track)
  local thumb = ctx:Create("Frame", {
    Name = "Selection",
    Size = UDim2.new(1 / #items, -4, 1, -4),
    Position = UDim2.fromOffset(2, 2),
    BorderSizePixel = 0,
    BackgroundColor3 = ctx.theme.colors.accent,
  }, track)
  ctx:Round(thumb, options.pill and 999 or 7)
  local buttons = {}
  for index, item in ipairs(items) do
    local button = Base.button(
      self,
      track,
      item.label,
      { Position = UDim2.fromScale((index - 1) / #items, 0), Size = UDim2.new(1 / #items, 0, 1, 0), BackgroundTransparency = 1, ZIndex = 2 }
    )
    button:FindFirstChildOfClass("UIStroke").Enabled = false
    self.scope:Add(button.Activated:Connect(function()
      if not self:IsDisabled() and not item.disabled then
        self:SetValue(item.value)
      end
    end))
    buttons[index] = button
  end
  local function render()
    local t = ctx.theme
    track.BackgroundColor3 = t.colors.input
    for index, button in ipairs(buttons) do
      local selected = self.value == items[index].value
      button.Active = not self:IsDisabled() and not items[index].disabled
      button.TextColor3 = selected and t.colors.text or t.colors.muted
      button.TextTransparency = button.Active and 0 or 0.5
      if selected then
        ctx:Animate(
          self.scope,
          thumb,
          { Position = UDim2.new((index - 1) / #items, 2, 0, 2), BackgroundColor3 = t.colors[items[index].variant or "accent"] or t.colors.accent },
          t.motion.normal
        )
      end
    end
  end
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(function(value)
    value = if value == nil then items[1].value else value
    if not valid[value] then
      return nil, "Unknown option"
    end
    return value
  end, render)
end
function Choice.Dropdown(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local items, valid = optionsList(options)
  local button = Base.button(self, self.content, "")
  local function normalize(value)
    if options.multiple then
      if value == nil then
        return {}
      end
      if type(value) ~= "table" then
        return nil, "Expected selection list"
      end
      local result, seen = {}, {}
      for _, v in ipairs(value) do
        if not valid[v] or seen[v] then
          return nil, "Invalid selection"
        end
        result[#result + 1] = v
        seen[v] = true
      end
      return result
    end
    if value == nil then
      return items[1].value
    end
    if not valid[value] then
      return nil, "Unknown option"
    end
    return value
  end
  local function selected(item) return if options.multiple then table.find(self.value, item.value) ~= nil else self.value == item.value end
  local function render()
    local labels = {}
    for _, item in ipairs(items) do
      if selected(item) then
        table.insert(labels, item.label)
      end
    end
    button.Text = (#labels > 0 and table.concat(labels, ", ") or options.placeholder or "Select…") .. "  ▾"
    button.TextColor3 = ctx.theme.colors.text
    button.BackgroundColor3 = ctx.theme.colors.input
    button.Active = not self:IsDisabled()
    button.TextTransparency = self:IsDisabled() and 0.5 or 0
  end
  self.scope:Add(button.Activated:Connect(function()
    if self:IsDisabled() then
      return
    end
    local popup, scope = ctx:Popup(self.scope, button, math.min(280, #items * 44 + (options.searchable and 52 or 8)))
    local filter
    if options.searchable then
      filter = ctx:Create("TextBox", {
        Name = "Search",
        Size = UDim2.new(1, -8, 0, 40),
        Text = "",
        PlaceholderText = "Search…",
        BackgroundColor3 = ctx.theme.colors.input,
        BorderSizePixel = 0,
        TextColor3 = ctx.theme.colors.text,
        PlaceholderColor3 = ctx.theme.colors.muted,
        TextSize = ctx.theme.text.body,
        Font = ctx.theme.font.regular,
        ClearTextOnFocus = false,
        LayoutOrder = 0,
      }, popup)
      ctx:Round(filter)
    end
    local buttons = {}
    for index, item in ipairs(items) do
      local option = Base.button({
        ctx = ctx,
        scope = scope,
        IsDisabled = function() return item.disabled == true end,
      }, popup, "", { Size = UDim2.new(1, -8, 0, 40), LayoutOrder = index })
      buttons[index] = option
      local function paint()
        option.Text = (selected(item) and "✓  " or "") .. item.label
        option.BackgroundColor3 = selected(item) and ctx.theme.colors.accent or ctx.theme.colors.input
        option.TextTransparency = item.disabled and 0.5 or 0
      end
      paint()
      scope:Add(option.Activated:Connect(function()
        if item.disabled or self:IsDisabled() then
          return
        end
        if options.multiple then
          local nextValue = table.clone(self.value)
          local at = table.find(nextValue, item.value)
          if at then
            table.remove(nextValue, at)
          else
            table.insert(nextValue, item.value)
          end
          self:SetValue(nextValue)
          for i, b in ipairs(buttons) do
            b.Text = (selected(items[i]) and "✓  " or "") .. items[i].label
            b.BackgroundColor3 = selected(items[i]) and ctx.theme.colors.accent or ctx.theme.colors.input
          end
        else
          self:SetValue(item.value)
          ctx:ClosePopup()
        end
      end))
    end
    if filter then
      scope:Add(filter:GetPropertyChangedSignal("Text"):Connect(function()
        for i, option in ipairs(buttons) do
          option.Visible = string.find(string.lower(items[i].label), string.lower(filter.Text), 1, true) ~= nil
        end
      end))
    end
    ctx.guiService.SelectedObject = filter or buttons[1]
  end))
  self.button = button
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(normalize, render)
end
function Choice.MultiSelect(ctx, parent, options)
  local props = table.clone(options)
  props.multiple = true
  return Choice.Dropdown(ctx, parent, props)
end
function Choice.RadioGroup(ctx, parent, options)
  local items = optionsList(options)
  local props = table.clone(options)
  props.height = 30 + #items * 34
  local self = Base.new(ctx, parent, props)
  self.content.Position = UDim2.fromOffset(10, 24)
  self.content.Size = UDim2.new(1, -20, 0, #items * 34)
  local valid, buttons = {}, {}
  for index, item in ipairs(items) do
    valid[item.value] = true
    local button = Base.button(self, self.content, item.label, { Position = UDim2.fromOffset(0, (index - 1) * 34), Size = UDim2.new(1, 0, 0, 30) })
    buttons[index] = button
    self.scope:Add(button.Activated:Connect(function()
      if not self:IsDisabled() and not item.disabled then
        self:SetValue(item.value)
      end
    end))
  end
  local function render()
    for index, button in ipairs(buttons) do
      button.Text = (self.value == items[index].value and "●  " or "○  ") .. items[index].label
      button.BackgroundColor3 = ctx.theme.colors.input
      button.TextColor3 = ctx.theme.colors.text
      button.TextTransparency = (self:IsDisabled() or items[index].disabled) and 0.5 or 0
    end
  end
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(function(value)
    value = if value == nil then items[1].value else value
    if not valid[value] then
      return nil, "Unknown option"
    end
    return value
  end, render)
end
function Choice.ColorPicker(ctx, parent, options)
  local self = Base.new(ctx, parent, options)
  local preview = ctx:Create("Frame", { Size = UDim2.fromOffset(30, 30), BorderSizePixel = 0 }, self.content)
  ctx:Round(preview)
  local box = ctx:Create("TextBox", {
    Position = UDim2.fromOffset(38, 0),
    Size = UDim2.new(1, -38, 1, 0),
    Text = "",
    ClearTextOnFocus = false,
    TextColor3 = ctx.theme.colors.text,
    BackgroundColor3 = ctx.theme.colors.input,
    TextSize = ctx.theme.text.body,
    Font = ctx.theme.font.medium,
    BorderSizePixel = 0,
  }, self.content)
  ctx:Round(box)
  local function render()
    preview.BackgroundColor3 = self.value
    box.Text = "#" .. self.value:ToHex()
    box.BackgroundColor3 = ctx.theme.colors.input
    box.TextColor3 = ctx.theme.colors.text
    box.TextEditable = not self:IsDisabled()
  end
  self.scope:Add(box.FocusLost:Connect(function()
    if self:IsDisabled() then
      render()
      return
    end
    local hex = box.Text:gsub("^#", "")
    if #hex ~= 6 or not hex:match("^%x+$") then
      self:SetError("Use a six digit hex color")
      render()
      return
    end
    self:SetValue(Color3.fromHex(hex))
  end))
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(function(value)
    if value == nil then
      return ctx.theme.colors.accent
    end
    if typeof(value) ~= "Color3" then
      return nil, "Expected Color3"
    end
    return value
  end, render)
end
-- Numeric input with selectable unit/mode; bindings and colors are supplied by the host.
function Choice.UnitInput(ctx, parent, options)
  local self = Choice.Segmented(ctx, parent, options)
  local items = optionsList(options)
  self.content.Size = UDim2.new(1, -96, 0, 30)
  local box = ctx:Create("TextBox", {
    Name = "Value",
    Size = UDim2.fromOffset(64, 30),
    Position = UDim2.new(1, -74, 1, -36),
    BackgroundColor3 = ctx.theme.colors.input,
    BackgroundTransparency = ctx.theme.transparency.input,
    TextColor3 = ctx.theme.colors.text,
    TextSize = ctx.theme.text.body,
    Font = ctx.theme.font.bold,
    ClearTextOnFocus = false,
    Text = "",
    BorderSizePixel = 0,
  }, self.root)
  ctx:Round(box)
  ctx:Outline(box)
  local function current()
    for _, item in ipairs(items) do
      if item.value == self.value then
        return item
      end
    end
  end
  local function refresh()
    local item = current()
    box.TextEditable = item.key ~= nil and not self:IsDisabled()
    box.Text = item.key and tostring(ctx.store:Get(item.key) or 0) or item.label
    box.BackgroundColor3 = ctx.theme.colors.input
    box.TextColor3 = ctx.theme.colors.text
  end
  self.scope:Add(self.Changed:Connect(refresh))
  self.scope:Add(ctx.store.Changed:Connect(refresh))
  self.scope:Add(ctx.ThemeChanged:Connect(refresh))
  self.scope:Add(box.FocusLost:Connect(function()
    local item = current()
    local value = tonumber(box.Text)
    if not item.key or self:IsDisabled() then
      refresh()
      return
    end
    if not value or value ~= value or math.abs(value) == math.huge or value < (options.min or 0) then
      self:SetError("Enter a valid number")
      refresh()
      return
    end
    local ok, reason = ctx.store:Set(item.key, value)
    self:SetError(ok and nil or reason)
    refresh()
  end))
  self.input = box
  refresh()
  return self
end
return Choice
