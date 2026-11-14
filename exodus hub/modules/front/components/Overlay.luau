local Base = require(script.Parent.Base)
local Overlay = {}
function Overlay.Notify(ctx, options)
  options = options or {}
  ctx.notifications = ctx.notifications or {}
  if options.id and ctx.notifications[options.id] then
    ctx.notifications[options.id]:Destroy()
  end
  local scope = ctx.scope:Child()
  local handle = { scope = scope }
  local card = scope:Add(ctx:Create("Frame", {
    Name = "Notification",
    BackgroundColor3 = ctx.theme.colors.elevated,
    BorderSizePixel = 0,
    Size = UDim2.fromOffset(320, 92),
    ZIndex = 110,
  }, ctx.overlays))
  ctx:Round(card, ctx.theme.radius.card)
  local border = ctx:Outline(card)
  local label =
    ctx:Text(card, options.title or "Notification", { Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -56, 0, 24), Font = ctx.theme.font.bold })
  local description = ctx:Text(card, options.message or "", {
    Position = UDim2.fromOffset(12, 36),
    Size = UDim2.new(1, -24, 0, 44),
    TextSize = ctx.theme.text.caption,
    TextYAlignment = Enum.TextYAlignment.Top,
  })
  local close = ctx:Create("TextButton", {
    Text = "×",
    Size = UDim2.fromOffset(32, 32),
    Position = UDim2.new(1, -40, 0, 8),
    BackgroundTransparency = 1,
    TextSize = 22,
    TextColor3 = ctx.theme.colors.muted,
    AutoButtonColor = false,
  }, card)
  function handle:Destroy() scope:Destroy() end
  function handle:SetText(text) description.Text = text end
  ctx.notificationOrder = ctx.notificationOrder or {}
  table.insert(ctx.notificationOrder, handle)
  handle.root = card
  if options.id then
    ctx.notifications[options.id] = handle
  end
  local function reflow()
    local width = math.min(320, math.max(120, ctx.root.AbsoluteSize.X - 24))
    local maxVisible = math.max(1, math.floor((ctx.root.AbsoluteSize.Y - 24) / 100))
    for i, item in ipairs(ctx.notificationOrder) do
      item.root.Visible = i > #ctx.notificationOrder - math.min(4, maxVisible)
      item.root.Size = UDim2.fromOffset(width, 92)
      item.root.Position = UDim2.new(1, -width - 12, 1, -12 - (#ctx.notificationOrder - i + 1) * 100)
    end
  end
  scope:Add(function()
    if options.id and ctx.notifications[options.id] == handle then
      ctx.notifications[options.id] = nil
    end
    local at = table.find(ctx.notificationOrder, handle)
    if at then
      table.remove(ctx.notificationOrder, at)
    end
    reflow()
  end)
  scope:Add(close.Activated:Connect(function() handle:Destroy() end))
  scope:Add(ctx.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(reflow))
  ctx:WatchTheme(scope, function(t)
    card.BackgroundTransparency = t.transparency.card
    card.BackgroundColor3 = t.colors.elevated
    label.TextColor3 = t.colors.text
    description.TextColor3 = t.colors.muted
    border.Color = t.colors[options.variant or "accent"] or t.colors.accent
  end)
  reflow()
  -- Bound the queue as well as the visible stack.
  if #ctx.notificationOrder > 8 then
    ctx.notificationOrder[1]:Destroy()
  end
  if options.duration ~= 0 then
    scope:Delay(options.duration or 4, function() handle:Destroy() end)
  end
  return handle
end
function Overlay.Dialog(ctx, options)
  options = options or {}
  ctx:ClosePopup()
  ctx:CancelCapture()
  if ctx.modal then
    ctx.modal:Destroy()
  end
  local scope = ctx.scope:Child()
  local handle = {}
  ctx.modal = handle
  local previous = ctx.guiService.SelectedObject
  local shield = scope:Add(ctx:Create("TextButton", {
    Name = "ModalShield",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0.35,
    Text = "",
    Modal = true,
    AutoButtonColor = false,
    ZIndex = 120,
  }, ctx.overlays))
  local card = ctx:Create("Frame", {
    Name = "Dialog",
    Size = UDim2.fromOffset(400, 204),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundColor3 = ctx.theme.colors.surface,
    BorderSizePixel = 0,
    ZIndex = 121,
  }, shield)
  ctx:Round(card, ctx.theme.radius.window)
  ctx:Outline(card)
  local title = ctx:Text(card, options.title or "Confirm", {
    Position = UDim2.fromOffset(16, 16),
    Size = UDim2.new(1, -32, 0, 28),
    Font = ctx.theme.font.bold,
    TextSize = ctx.theme.text.title,
  })
  local body = ctx:Text(card, options.message or "", {
    Position = UDim2.fromOffset(16, 52),
    Size = UDim2.new(1, -32, 1, -116),
    TextYAlignment = Enum.TextYAlignment.Top,
  })
  local proxy = { ctx = ctx }
  local cancel = Base.button(proxy, card, options.cancelText or "Cancel", { Position = UDim2.new(0, 16, 1, -56), Size = UDim2.new(0.5, -24, 0, 40) })
  local confirm = Base.button(proxy, card, options.confirmText or "Confirm", { Position = UDim2.new(0.5, 8, 1, -56), Size = UDim2.new(0.5, -24, 0, 40) })
  function handle:Destroy() scope:Destroy() end
  local function finish(accepted)
    if scope.destroyed then
      return
    end
    handle:Destroy()
    local callback = accepted and options.onConfirm or options.onCancel
    if callback then
      local ok, err = pcall(callback)
      if not ok then
        ctx.onError(err)
      end
    end
  end
  scope:Add(cancel.Activated:Connect(function() finish(false) end))
  scope:Add(confirm.Activated:Connect(function() finish(true) end))
  scope:Add(ctx.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.Escape then
      finish(false)
    end
  end))
  -- Keep directional/gamepad selection inside the dialog.
  cancel.NextSelectionLeft = confirm
  cancel.NextSelectionRight = confirm
  cancel.NextSelectionUp = confirm
  cancel.NextSelectionDown = confirm
  confirm.NextSelectionLeft = cancel
  confirm.NextSelectionRight = cancel
  confirm.NextSelectionUp = cancel
  confirm.NextSelectionDown = cancel
  ctx.guiService.SelectedObject = cancel
  scope:Add(function()
    if ctx.modal == handle then
      ctx.modal = nil
    end
    if previous and previous.Parent then
      ctx.guiService.SelectedObject = previous
    else
      ctx.guiService.SelectedObject = nil
    end
  end)
  local function resize()
    card.Size = UDim2.fromOffset(math.min(400, math.max(100, ctx.root.AbsoluteSize.X - 24)), math.min(204, math.max(100, ctx.root.AbsoluteSize.Y - 24)))
  end
  scope:Add(ctx.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
  resize()
  ctx:WatchTheme(scope, function(t)
    card.BackgroundTransparency = t.transparency.header
    card.BackgroundColor3 = t.colors.surface
    title.TextColor3 = t.colors.text
    body.TextColor3 = t.colors.muted
    cancel.BackgroundColor3 = t.colors.hover
    cancel.TextColor3 = t.colors.text
    confirm.BackgroundColor3 = t.colors[options.variant or "accent"] or t.colors.accent
    confirm.TextColor3 = t.colors.text
  end)
  return handle
end
function Overlay.Tooltip(ctx, anchor, options)
  local scope = ctx.scope:Child()
  local tooltip
  local function hide()
    if tooltip then
      tooltip:Destroy()
      tooltip = nil
    end
  end
  local function show()
    hide()
    tooltip = scope:Child()
    local label = tooltip:Add(ctx:Text(ctx.overlays, options.text or "", {
      Size = UDim2.fromOffset(240, 56),
      BackgroundTransparency = 0,
      BackgroundColor3 = ctx.theme.colors.elevated,
      TextSize = ctx.theme.text.caption,
      ZIndex = 130,
    }))
    ctx:Padding(label, 8)
    ctx:Round(label)
    ctx:Outline(label)
    local function position()
      local p, bounds = anchor.AbsolutePosition - ctx.root.AbsolutePosition, ctx.root.AbsoluteSize
      label.Position = UDim2.fromOffset(math.clamp(p.X, 4, math.max(4, bounds.X - 244)), math.clamp(p.Y - 60, 4, math.max(4, bounds.Y - 60)))
    end
    position()
    tooltip:Add(anchor:GetPropertyChangedSignal("AbsolutePosition"):Connect(position))
  end
  scope:Add(anchor.MouseEnter:Connect(show))
  scope:Add(anchor.MouseLeave:Connect(hide))
  scope:Add(anchor.SelectionGained:Connect(show))
  scope:Add(anchor.SelectionLost:Connect(hide))
  scope:Add(anchor.Destroying:Connect(function() scope:Destroy() end))
  return scope
end
return Overlay
