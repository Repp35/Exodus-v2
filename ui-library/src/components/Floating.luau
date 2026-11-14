local Base = require(script.Parent.Base)
local Floating = {}
function Floating.Button(ctx, options)
  local props = table.clone(options)
  props.height = options.height or 56
  local self = Base.new(ctx, ctx.root, props, true)
  self.root.Size = UDim2.fromOffset(options.width or 56, options.height or 56)
  self.root.Position = options.position or UDim2.fromOffset(16, 120)
  self.root.ZIndex = 20
  local button = Base.button(self, self.root, options.text or "Open")
  local border = ctx:Outline(button)
  local moved = ctx:Drag(self.scope, button, self.root, options.onMove)
  local holding
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
    if
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.Touch
    then
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
    if self:IsDisabled() or moved() then
      return
    end
    if options.onClick then
      options.onClick(self)
    end
  end))
  self.scope:Add(release)
  function self:SetText(text)
    button.Text = text
  end
  function self:SetVisible(visible)
    self.root.Visible = visible == true
    if not visible then
      release()
    end
  end
  function self:SetSize(width, height)
    self.root.Size = UDim2.fromOffset(width, height)
  end
  local function clamp()
    local bounds = ctx.root.AbsoluteSize
    self.root.Position = UDim2.fromOffset(
      math.clamp(self.root.Position.X.Offset, 0, math.max(0, bounds.X - self.root.AbsoluteSize.X)),
      math.clamp(self.root.Position.Y.Offset, 0, math.max(0, bounds.Y - self.root.AbsoluteSize.Y))
    )
  end
  self.scope:Add(ctx.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(clamp))
  self.scope:Add(self.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(clamp))
  clamp()
  ctx:WatchTheme(self.scope, function(t)
    button.BackgroundColor3 = t.colors[options.variant or "accent"] or t.colors.accent
    button.TextColor3 = t.colors.text
    border.Color = t.colors.outlineStart
  end)
  self.button = button
  return self
end
return Floating
