-- [[ dropdown ]]

-- module
local Components = {}

-- configuration
local CONFIG = { DROPDOWN_ROWS = 4 }

-- setup
function Components.setup() return true end

-- components
function Components.install(context)
  local kit = context.kit; local Theme = context.Theme
  local Runtime = context.Runtime; local UIS = context.UIS
  local RunService = context.RunService; local options = context.options
  local components = context.components; local C = context.C
  local TEXT = context.TEXT; local inst = context.inst
  local text = context.text; local control = context.control
  local title = context.title; local button = context.button
  local commit = context.commit; local bind = context.bind
  local read = context.read; local choiceValue = context.choiceValue
  local choiceLabel = context.choiceLabel; local popup = context.popup
  function components.dropdown(parent, definition)
    definition = definition or {}; local choices = definition.options or definition.choices or {}
    local handle = control(parent, definition, Theme.RATE_CARD_H); title(handle, definition, 0, 24)
    local trigger = button(handle.Root, "", { Name = "Select", Size = UDim2.new(1, -20, 0, 28), Position = UDim2.fromOffset(10, 29) })
    local selectedLabel = text(trigger, "", {
      Name = "Selected",
      Position = UDim2.fromOffset(10, 0),
      Size = UDim2.new(1, -38, 1, 0),
      ZIndex = 11,
    })
    local arrow = kit.icon(trigger, "chevron", { Position = UDim2.new(1, -16, 0.5, 0), Size = UDim2.fromOffset(14, 14) })
    local value, openScope, menu, menuMotion
    local selecting, closing, optionViews = false, false, {}
    local close
    local function finishClose(owner)
      if openScope ~= owner then return end
      if popup.close == close then popup.close = nil end
      openScope, menu, menuMotion = nil, nil, nil; selecting, closing, optionViews = false, false, {}
      owner.destroy()
    end
    close = function(animated)
      if not openScope then return end
      handle.motion.play(arrow, "feedback", { Rotation = 0 }); local owner = openScope
      if animated == true then
        if closing then return end
        closing = true
        menuMotion.group(menu, "feedback", { GroupTransparency = 1 }, function() finishClose(owner) end)
      else
        if popup.close == close then popup.close = nil end
        finishClose(owner)
      end
    end
    kit.feedback(
      handle.scope,
      trigger,
      function(active) handle.motion.play(handle.Border, "feedback", { Color = active and C.accent or C.border }) end,
      function() return handle.enabled end
    )
    function handle.setValue(nextValue)
      value = nextValue; local label = tostring(value or definition.placeholder or "Select")
      for _, choice in ipairs(choices) do
        if choiceValue(choice) == value then label = choiceLabel(choice); break end
      end
      selectedLabel.Text = label
      for _, refresh in ipairs(optionViews) do
        refresh()
      end
    end
    function handle.getValue() return value end
    local function open()
      if not handle.enabled or kit.suspended or #choices == 0 or not options.parent or not Runtime.isVisible(handle.Root) then return end
      kit.dismiss(); openScope = Runtime.scope()
      popup.close = close
      local portal = inst("ScreenGui", {
        Name = "ExodusDropdown",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = options.parent.DisplayOrder + 1,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
      }, options.parent.Parent)
      menu = inst("CanvasGroup", { BackgroundColor3 = C.card, GroupTransparency = 1, ZIndex = 1 }, portal); kit.corner(menu)
      kit.stroke(menu)
      local list = inst("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Active = true,
        CanvasSize = UDim2.new(),
        ScrollBarThickness = Theme.SCROLLBAR,
        ScrollBarImageColor3 = C.accent,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ZIndex = 2,
      }, menu)
      menuMotion = kit.createMotion(openScope)
      openScope.add(portal, function() portal:Destroy() end)
      local ensureRoom = true
      local function position()
        if not trigger.Parent or not Runtime.isVisible(trigger) then close(); return end
        local camera = workspace.CurrentCamera; local view = camera and camera.ViewportSize or Vector2.new(1920, 1080)
        local pos, size = trigger.AbsolutePosition, trigger.AbsoluteSize; local ancestor = trigger.Parent
        local scroll
        while ancestor and ancestor ~= options.parent do
          if
            ancestor:IsA("ScrollingFrame") and (pos.Y + size.Y <= ancestor.AbsolutePosition.Y or pos.Y >= ancestor.AbsolutePosition.Y + ancestor.AbsoluteSize.Y)
          then
            close(); return
          end
          if not scroll and ancestor:IsA("ScrollingFrame") then
            scroll = ancestor
          end
          ancestor = ancestor.Parent
        end
        local layout = Theme.DROPDOWN; local scale = math.max(0.1, size.Y / 28)
        local row, gap, pad = layout.rowHeight * scale, layout.rowGap * scale, layout.padding * scale
        local desired = math.min(#choices, definition.maxVisible or CONFIG.DROPDOWN_ROWS) * (row + gap) + pad * 2
        local bottom = math.max(pos.Y + size.Y, handle.Root.AbsolutePosition.Y + handle.Root.AbsoluteSize.Y); local margin, spacing = layout.margin, layout.gap * scale
        local below = math.max(0, view.Y - bottom - spacing - margin); local moved = false
        if ensureRoom and scroll and below < desired then
          local room = math.max(0, handle.Root.AbsolutePosition.Y - scroll.AbsolutePosition.Y - pad); local shift = math.min(desired - below, room)
          if shift > 0 then scroll.CanvasPosition = Vector2.new(scroll.CanvasPosition.X, scroll.CanvasPosition.Y + shift / scale); moved = true end
        end
        ensureRoom = false; local height = math.min(desired, below)
        if height <= 0 and not moved then close(); return end
        local width = math.min(size.X, math.max(1, view.X - margin * 2)); menu.AnchorPoint = Vector2.zero
        menu.Size = UDim2.fromOffset(width, height); menu.Position = UDim2.fromOffset(math.clamp(pos.X, margin, math.max(margin, view.X - width - margin)), bottom + spacing)
        list.CanvasSize = UDim2.fromOffset(0, #choices * (row + gap) + pad * 2)
        for index, item in ipairs(list:GetChildren()) do
          if item:IsA("TextButton") then
            item.Size = UDim2.new(1, -pad * 2 - Theme.SCROLLBAR, 0, row); item.Position = UDim2.fromOffset(pad, pad + (item.LayoutOrder - 1) * (row + gap))
            item.TextSize = math.max(10, TEXT.body * scale)
          end
        end
      end
      local activeItem, resetActive
      for index, choice in ipairs(choices) do
        local selected = choiceValue(choice) == value
        local item = button(list, choiceLabel(choice), {
          LayoutOrder = index,
          BackgroundColor3 = C.cardHover,
          BackgroundTransparency = 1,
          TextColor3 = selected and C.text or C.subtext,
          ZIndex = 3,
        })
        local border = kit.stroke(item); border.Transparency = 1
        local reset
        local refresh
        refresh, reset = kit.feedback(openScope, item, function(active, pressed)
          if active and activeItem ~= item then
            if resetActive then resetActive() end
            activeItem, resetActive = item, reset
          elseif not active and activeItem == item then
            activeItem, resetActive = nil, nil
          end
          local selectedNow = selecting and choiceValue(choice) == value
          menuMotion.play(border, "feedback", { Transparency = (active or selectedNow) and 0 or 1, Color = active and C.accent or C.border })
          menuMotion.play(item, "feedback", {
            BackgroundTransparency = (selectedNow or active) and 0.1 or 1,
            TextColor3 = (active or selectedNow) and C.text or C.subtext,
          })
        end, function() return not selecting and not closing end)
        optionViews[#optionViews + 1] = refresh
        openScope.connect(item.Activated, function()
          if selecting or closing then return end
          if not commit(handle, definition, choiceValue(choice)) then return end
          selecting = true; handle.setValue(choiceValue(choice))
          local owner = openScope
          task.delay(Theme.DROPDOWN.selectionDelay, function()
            if owner.alive and openScope == owner then close(true) end
          end)
        end)
      end
      position()
      if not openScope then return end
      menuMotion.group(menu, "feedback", { GroupTransparency = 0 }); handle.motion.play(arrow, "feedback", { Rotation = 180 })
      openScope.connect(RunService.Heartbeat, position)
      openScope.connect(UIS.InputBegan, function(input)
        if input.KeyCode == Enum.KeyCode.Escape then close(); return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local function inside(root)
          local pos, size = root.AbsolutePosition, root.AbsoluteSize
          return input.Position.X >= pos.X and input.Position.X <= pos.X + size.X and input.Position.Y >= pos.Y and input.Position.Y <= pos.Y + size.Y
        end
        if not inside(menu) and not inside(trigger) then close() end
      end)
    end
    handle.scope.add(close)
    handle.scope.connect(trigger.Activated, function()
      if openScope then close() else open() end
    end)
    handle.setValue(read(definition.key, definition.value)); bind(handle, definition.key, handle.setValue)
    return handle
  end
end

-- contract
Components.__contract = { provides = { "setup", "install" }, requires = {} }

return Components
