-- Original circular launcher/action balls and compact mini panel, parameterized.
local Base = require(script.Parent.Base)
local Floating = {}
function Floating.Button(ctx, options)
  local self = Base.new(ctx, ctx.root, options, true)
  local mini = options.shape == "mini"
  self.root.Name = options.id or "FloatingControl"
  self.root.Size = UDim2.fromOffset(options.width or 56, options.height or 56)
  self.root.Position = options.position or UDim2.fromOffset(14, 120)
  self.root.ZIndex = 20
  self.corner.CornerRadius = UDim.new(0, mini and 12 or (options.shape == "rounded" and 12 or 999))
  local dragHandle = self.root
  local header
  if mini then
    header = ctx:Create("Frame", { Name = "Header", Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1 }, self.root)
    ctx:Text(header, options.title or "Action", {
      Size = UDim2.fromScale(1, 1),
      TextSize = 10,
      Font = ctx.theme.font.bold,
      TextColor3 = ctx.theme.colors.muted,
      TextXAlignment = Enum.TextXAlignment.Center,
    })
    dragHandle = header
  end
  local button = Base.button(self, self.root, options.text or "E", {
    Name = "Action",
    Size = mini and UDim2.new(1, -12, 1, -28) or UDim2.fromScale(1, 1),
    Position = mini and UDim2.fromOffset(6, 22) or UDim2.fromOffset(0, 0),
    TextSize = options.textSize or (mini and 26 or 14),
    TextWrapped = true,
    TextTruncate = Enum.TextTruncate.None,
  })
  button:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0, mini and 10 or (options.shape == "rounded" and 12 or 999))
  local border = button:FindFirstChildOfClass("UIStroke")
  border.Thickness = 1.5
  if not mini then
    dragHandle = button
  end
  local moved = ctx:Drag(self.scope, dragHandle, self.root, options.onMove)
  local holding, tone = nil, options.variant or "surface"
  local function release()
    if holding then
      holding = nil
      if options.onHold then
        options.onHold(false)
      end
    end
  end
  self.scope:Add(button.InputBegan:Connect(function(input)
    if self:IsDisabled() then
      return
    end
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
      holding = input
      if options.onHold then
        options.onHold(true)
      end
    end
  end))
  self.scope:Add(ctx.InputEnded:Connect(function(input)
    if input == nil or input == holding then
      release()
    end
  end))
  self.scope:Add(button.Activated:Connect(function()
    if not self:IsDisabled() and not moved() and options.onClick then
      options.onClick(self)
    end
  end))
  self.scope:Add(release)
  function self:SetText(text) button.Text = text end
  function self:SetVisible(visible)
    self.root.Visible = visible == true
    if not visible then
      release()
    end
  end
  local function clamp()
    local bounds, size, position = ctx.root.AbsoluteSize, self.root.Size, self.root.Position
    self.root.Position = UDim2.fromOffset(
      math.clamp(position.X.Scale * bounds.X + position.X.Offset, 0, math.max(0, bounds.X - size.X.Offset)),
      math.clamp(position.Y.Scale * bounds.Y + position.Y.Offset, 0, math.max(0, bounds.Y - size.Y.Offset))
    )
  end
  function self:SetSize(width, height)
    self.root.Size = UDim2.fromOffset(width, height)
    clamp()
  end
  local function render()
    local t = ctx.theme
    self.root.BackgroundColor3 = t.colors.surface
    self.root.BackgroundTransparency = mini and t.transparency.card or 1
    button.BackgroundColor3 = t.colors[tone] or t.colors.surface
    button.BackgroundTransparency = options.transparency or t.transparency.button
    button.TextColor3 = t.colors.text
    border.Color = mini and t.colors.border or t.colors.accent
    if mini then
      self.corner.CornerRadius = UDim.new(0, t.radius.card)
    else
      self.corner.CornerRadius = UDim.new(0, options.shape == "rounded" and t.radius.card or 999)
    end
  end
  function self:SetTone(value)
    tone = value
    render()
  end
  ctx:WatchTheme(self.scope, render)
  self.scope:Add(ctx.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(clamp))
  clamp()
  self.button = button
  return self
end
return Floating
