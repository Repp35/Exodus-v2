local Base = require(script.Parent.Base)
local Data = {}
function Data.Table(ctx, parent, options)
  assert(type(options.columns) == "table" and #options.columns > 0, "Expected columns")
  local props = table.clone(options)
  props.height = options.height or 260
  local self = Base.new(ctx, parent, props, true)
  local header = ctx:Create("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1 }, self.root)
  local body = ctx:Create("ScrollingFrame", {
    Position = UDim2.fromOffset(0, 44),
    Size = UDim2.new(1, 0, 1, -44),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness = 4,
  }, self.root)
  ctx:List(body, false, 4)
  local rowScope
  local sortKey, descending, query = options.sortKey, false, ""
  function self:SetFilter(text)
    query = string.lower(tostring(text))
    self.render()
  end
  function self:Sort(key, reverse)
    sortKey = key
    descending = reverse == true
    self.render()
  end
  local function render()
    if rowScope then
      rowScope:Destroy()
    end
    rowScope = self.scope:Child()
    local rows = {}
    for _, row in ipairs(self.value) do
      local visible = query == ""
      for _, column in ipairs(options.columns) do
        if string.find(string.lower(tostring(row[column.key] or "")), query, 1, true) then
          visible = true
        end
      end
      if visible then
        table.insert(rows, row)
      end
    end
    if sortKey then
      table.sort(rows, function(a, b)
        local left, right = a[sortKey], b[sortKey]
        if type(left) ~= "number" or type(right) ~= "number" then
          left, right = tostring(left or ""), tostring(right or "")
        end
        return if descending then left > right else left < right
      end)
    end
    for index, row in ipairs(rows) do
      local frame = rowScope:Add(ctx:Create("Frame", {
        Size = UDim2.new(1, -4, 0, 40),
        BackgroundColor3 = index % 2 == 0 and ctx.theme.colors.input or ctx.theme.colors.elevated,
        BorderSizePixel = 0,
        LayoutOrder = index,
      }, body))
      for col, column in ipairs(options.columns) do
        ctx:Text(
          frame,
          column.format and column.format(row[column.key], row) or tostring(row[column.key] or "—"),
          {
            Position = UDim2.new((col - 1) / #options.columns, 8, 0, 0),
            Size = UDim2.new(1 / #options.columns, -16, 1, 0),
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextWrapped = false,
          }
        )
      end
    end
    if #rows == 0 then
      rowScope:Add(
        ctx:Text(
          body,
          options.emptyText or "No results",
          { Size = UDim2.new(1, 0, 0, 48), TextXAlignment = Enum.TextXAlignment.Center }
        )
      )
    end
    body.ScrollBarImageColor3 = ctx.theme.colors.accent
  end
  for index, column in ipairs(options.columns) do
    local button = Base.button(self, header, column.title or column.key, {
      Position = UDim2.new((index - 1) / #options.columns, 0, 0, 0),
      Size = UDim2.new(1 / #options.columns, -4, 1, 0),
    })
    ctx:WatchTheme(self.scope, function(t)
      button.BackgroundColor3 = t.colors.input
      button.TextColor3 = t.colors.text
    end)
    self.scope:Add(button.Activated:Connect(function()
      if self:IsDisabled() or column.sortable == false then
        return
      end
      descending = sortKey == column.key and not descending or false
      sortKey = column.key
      render()
    end))
  end
  self.scope:Add(ctx.ThemeChanged:Connect(render))
  return self:Initialize(function(value)
    if value == nil then
      return {}
    end
    if type(value) ~= "table" then
      return nil, "Expected rows"
    end
    local result = {}
    for _, row in ipairs(value) do
      if type(row) ~= "table" then
        return nil, "Expected row table"
      end
      table.insert(result, table.clone(row))
    end
    return result
  end, render)
end
return Data
