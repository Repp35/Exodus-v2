-- [[ uikit ]]

-- module
local UIKit = {}
local Theme
local Runtime
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

-- configuration
local CONFIG = {
  INPUT_WIDTH = 62,
  DROPDOWN_ROWS = 4,
}

-- setup
function UIKit.setup(deps)
  Theme, Runtime = deps.Theme.tokens, deps.Runtime; return true
end

-- helpers
local function finite(value)
  local number = tonumber(value); return number and number == number and number > -math.huge and number < math.huge and number or nil
end
local function choiceValue(choice) return type(choice) == "table" and choice.value or choice end
local function choiceLabel(choice) return tostring(type(choice) == "table" and (choice.label or choice.value) or choice) end
local function keyName(value)
  local names = {
    MouseButton1 = "M1",
    MouseButton2 = "M2",
    MouseButton3 = "M3",
    LeftControl = "LCtrl",
    RightControl = "RCtrl",
    LeftShift = "LShift",
    RightShift = "RShift",
  }

  local name = typeof(value) == "EnumItem" and value.Name or tostring(value or "—"); return names[name] or name
end

-- library
function UIKit.create(options)
  options = options or {}; local scope = Runtime.scope()
  local motion = Runtime.motion(scope, options.reducedMotion); local C, FONT, TEXT = Theme.COLORS, Theme.FONT, Theme.TEXT
  local bindings, components, drags, observers = {}, {}, {}, {}
  local popupClose, capture
  local kit = { Theme = Theme, Components = components, scope = scope, motion = motion, suspended = false }; local motions = { [motion] = true }
  function kit.createMotion(lifetime)
    local owned = Runtime.motion(lifetime, options.reducedMotion); motions[owned] = true
    lifetime.add(function() motions[owned] = nil end)
    return owned
  end
  local function read(key, fallback)
    local value = key and options.read and options.read(key)
    if value == nil then return fallback end
    return value
  end
  kit.read = read
  function kit.observe(callback)
    local connection = {}; observers[connection] = callback
    function connection.Disconnect() observers[connection] = nil end
    return connection
  end
  scope.add(function() table.clear(observers) end)
  function kit.instance(class, properties, parent)
    local object = Instance.new(class)
    if object:IsA("GuiObject") then object.BorderSizePixel = 0 end
    if object:IsA("GuiButton") then object.AutoButtonColor = false end
    for key, value in pairs(properties or {}) do
      object[key] = value
    end
    object.Parent = parent; return object
  end
  local inst = kit.instance
  function kit.corner(root, radius) return inst("UICorner", { CornerRadius = UDim.new(0, radius or Theme.RADIUS.control) }, root) end
  function kit.stroke(root, color)
    local line = inst("UIStroke", { Color = color or C.border, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, root)
    if color == nil or color == C.border or color == C.accent then
      local gradient = inst("UIGradient", {
        Color = ColorSequence.new({
          ColorSequenceKeypoint.new(0, Theme.GRADIENT[1]),
          ColorSequenceKeypoint.new(0.5, Theme.GRADIENT[2]),
          ColorSequenceKeypoint.new(1, Theme.GRADIENT[3]),
        }),
      }, line)
      if options.onOutline then options.onOutline(gradient) end
    end
    return line
  end
  local function text(parent, value, properties)
    local props = {
      BackgroundTransparency = 1,
      Text = tostring(value or ""),
      TextColor3 = C.text,
      TextSize = TEXT.body,
      Font = FONT.label,
      TextXAlignment = Enum.TextXAlignment.Left,
      TextTruncate = Enum.TextTruncate.AtEnd,
      ZIndex = 8,
    }

    for key, value in pairs(properties or {}) do
      props[key] = value
    end
    return inst("TextLabel", props, parent)
  end
  function kit.cancelCapture()
    local pending = capture; capture = nil
    if pending then
      pending.restore()
      if options.onCapture then options.onCapture(false) end
    end
  end
  function kit.dismiss()
    for cancel in pairs(drags) do
      cancel()
    end
    if popupClose then popupClose() end
    kit.cancelCapture()
  end
  function kit.suspend()
    kit.suspended = true; kit.dismiss()
    for owned in pairs(motions) do
      owned.pause()
    end
  end
  function kit.resume()
    kit.suspended = false
    for owned in pairs(motions) do
      owned.resume()
    end
    kit.refresh()
  end
  function kit.destroy()
    kit.dismiss(); scope.destroy()
  end
  scope.add(kit.dismiss)
  local function bind(handle, key, refresh)
    if not key then return end
    local listeners = bindings[key] or {}; bindings[key] = listeners
    listeners[refresh] = handle
    handle.scope.add(function()
      listeners[refresh] = nil
      if not next(listeners) then bindings[key] = nil end
    end)
  end
  function kit.refresh(changes)
    for key, listeners in pairs(bindings) do
      if not changes or changes[key] ~= nil then
        for refresh, handle in pairs(listeners) do
          if handle.scope.alive then refresh(read(key)) end
        end
      end
    end
    for _, observer in pairs(observers) do
      observer(changes)
    end
  end
  if options.observe then scope.add(options.observe(kit.refresh)) end
  scope.connect(UIS.InputBegan, function(input)
    if not capture then return end
    local binding
    if input.UserInputType == Enum.UserInputType.Keyboard then
      if input.KeyCode == Enum.KeyCode.Escape then kit.cancelCapture(); return end
      if input.KeyCode ~= Enum.KeyCode.Unknown then binding = input.KeyCode end
    elseif
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.MouseButton2
      or input.UserInputType == Enum.UserInputType.MouseButton3
    then
      binding = input.UserInputType
    end
    if binding then
      local pending = capture; kit.cancelCapture()
      pending.pick(binding)
    end
  end)
  scope.connect(UIS.WindowFocusReleased, kit.cancelCapture)
  local function control(parent, definition, height, class)
    definition = definition or {}
    local root = inst(class or "Frame", {
      Name = definition.name or definition.key or definition.kind or "Control",
      Size = definition.size or UDim2.new(1, -8, 0, height),
      BackgroundColor3 = C.card,
      BackgroundTransparency = 0.1,
      ZIndex = 6,
    }, parent)
    kit.corner(root, Theme.RADIUS.card); local border = kit.stroke(root)
    local childScope = Runtime.scope(); local childMotion = kit.createMotion(childScope)
    local handle = { Root = root, scope = childScope, motion = childMotion, enabled = true }
    scope.add(handle, function() handle.destroy() end)
    childScope.add(function() scope.forget(handle) end)
    childScope.connect(root.Destroying, childScope.destroy)
    childScope.connect(root.MouseEnter, function()
      if definition.kind == "label" or definition.kind == "divider" then return end
      if not handle.enabled or kit.suspended then return end
      childMotion.play(border, "control", { Color = C.accent }); childMotion.play(root, "control", { BackgroundColor3 = C.cardHover })
    end)
    childScope.connect(root.MouseLeave, function()
      if definition.kind == "label" or definition.kind == "divider" then return end
      childMotion.play(border, "control", { Color = C.border }); childMotion.play(root, "control", { BackgroundColor3 = C.card })
    end)
    function handle.setEnabled(enabled)
      handle.enabled = enabled == true; root.Active = handle.enabled
      if not handle.enabled and capture and capture.owner == handle then kit.cancelCapture() end
      for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("GuiButton") then descendant.Active = handle.enabled; descendant.Selectable = handle.enabled end
        if descendant:IsA("TextBox") then descendant.TextEditable = handle.enabled end
      end
    end
    function handle.setVisible(visible) root.Visible = visible == true end
    function handle.destroy()
      childScope.destroy(); root:Destroy()
    end
    if definition.enabled == false then handle.setEnabled(false) end
    return handle
  end
  local function title(handle, definition, rightSpace, height)
    local root = handle.Root; local hasDescription = definition.description and definition.description ~= ""
    text(root, definition.title or definition.text, {
      Name = "Title",
      Position = UDim2.fromOffset(14, hasDescription and 5 or 0),
      Size = UDim2.new(1, -(28 + (rightSpace or 0)), 0, hasDescription and 18 or height),
    })
    if hasDescription then
      text(root, definition.description, {
        Name = "Description",
        Position = UDim2.fromOffset(14, 26),
        Size = UDim2.new(1, -(28 + (rightSpace or 0)), 0, height - 30),
        TextColor3 = C.subtext,
        TextSize = TEXT.caption,
        Font = FONT.body,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None,
        TextYAlignment = Enum.TextYAlignment.Top,
      })
    end
  end
  local function button(parent, label, properties)
    local props = {
      Text = tostring(label),
      TextColor3 = C.text,
      TextSize = TEXT.control,
      Font = FONT.strong,
      BackgroundColor3 = C.inputBg,
      ZIndex = 10,
    }

    for key, value in pairs(properties or {}) do
      props[key] = value
    end
    local root = inst("TextButton", props, parent); kit.corner(root)
    return root
  end
  local function hitbox(handle, callback, height)
    local root = button(handle.Root, "", {
      Name = "CardHitbox",
      Size = UDim2.new(1, 0, height and 0 or 1, height or 0),
      BackgroundTransparency = 1,
      ZIndex = 10,
    })
    local scale = inst("UIScale", { Scale = 1 }, handle.Root)
    handle.scope.connect(root.Activated, function()
      if not handle.enabled or kit.suspended then return end
      handle.motion.play(scale, "press", { Scale = 0.97 }, function() handle.motion.play(scale, "feedback", { Scale = 1 }) end)
      callback()
    end)
    return root
  end
  local function commit(handle, definition, value)
    if not handle.enabled or kit.suspended then return false end
    if definition.key and options.write and options.write(definition.key, value) == false then
      if options.notify then options.notify("Unable to update " .. tostring(definition.title or definition.key), true) end
      return false
    end
    local result
    if definition.onChange then result = definition.onChange(value) end
    if result == false and not definition.key then return false end
    return true
  end
  local function shortcut(handle, key, xOffset)
    if not key then return end
    local cap = button(handle.Root, keyName(read(key)), {
      Name = "Shortcut_" .. key,
      Position = UDim2.new(1, xOffset or -126, 0.5, -13),
      Size = UDim2.fromOffset(50, 26),
      BackgroundColor3 = C.btnDark,
      TextSize = 11,
      ZIndex = 12,
    })
    local function paint(value) cap.Text = keyName(value) end
    bind(handle, key, paint)
    handle.scope.connect(cap.Activated, function()
      if not handle.enabled or kit.suspended then return end
      kit.cancelCapture(); cap.Text = "..."
      capture = {
        restore = function()
          if cap.Parent then paint(read(key)) end
        end,
        owner = handle,
        pick = function(value)
          if not options.write or options.write(key, value) ~= false then paint(value) end
        end,
      }

      if options.onCapture then options.onCapture(true) end
    end)
    handle.scope.add(function()
      if capture and capture.owner == handle then kit.cancelCapture() end
    end)
  end
  function components.label(parent, definition)
    definition = definition or {}; definition = table.clone(definition)
    definition.kind = "label"; local handle = control(parent, definition, 24)
    handle.Root.BackgroundTransparency = 1; local outline = handle.Root:FindFirstChildOfClass("UIStroke")
    if outline then outline:Destroy() end
    local label = text(handle.Root, definition.title or definition.text, { Size = UDim2.fromScale(1, 1), TextSize = TEXT.caption, TextColor3 = C.accent })
    function handle.setText(value) label.Text = tostring(value) end
    return handle
  end
  function components.button(parent, definition)
    definition = definition or {}; local height = definition.description and Theme.CARD_H + 22 or Theme.CARD_H
    local handle = control(parent, definition, height); title(handle, definition, definition.shortcutKey and 64 or 0, height)
    hitbox(handle, function()
      if definition.onClick then definition.onClick() end
    end)
    shortcut(handle, definition.shortcutKey, -64)
    function handle.setText(value) handle.Root.Title.Text = tostring(value) end
    return handle
  end
  function components.toggle(parent, definition)
    definition = definition or {}; local height = definition.description and Theme.CARD_H + 22 or Theme.CARD_H
    local handle = control(parent, definition, height); title(handle, definition, definition.shortcutKey and 120 or 58, height)
    local track =
      inst("Frame", { Size = UDim2.fromOffset(48, 30), Position = UDim2.new(1, -62, 0.5, -15), BackgroundColor3 = C.toggleOff, ZIndex = 8 }, handle.Root)
    kit.corner(track, Theme.RADIUS.pill); local thumb = inst("Frame", { Size = UDim2.fromOffset(20, 20), BackgroundColor3 = C.text, ZIndex = 9 }, track)
    kit.corner(thumb, Theme.RADIUS.pill); local value = false
    function handle.setValue(nextValue)
      value = nextValue == true; handle.motion.play(track, "control", { BackgroundColor3 = value and C.toggleOn or C.toggleOff })
      handle.motion.play(thumb, "control", { Position = UDim2.new(0, value and 24 or 4, 0.5, -10) })
    end
    function handle.getValue() return value end
    hitbox(handle, function()
      local current = value
      if definition.getState then current = definition.getState() end
      local requested = not current
      if commit(handle, definition, requested) then
        if definition.getState then handle.setValue(definition.getState()) else handle.setValue(requested) end
        if options.notify and definition.toast ~= false then options.notify(tostring(definition.title or definition.text or "Option") .. (handle.getValue() and " On" or " Off")) end
      end
    end)
    shortcut(handle, definition.shortcutKey)
    if definition.getState then handle.setValue(definition.getState()) else handle.setValue(read(definition.key, definition.value)) end
    bind(handle, definition.key, handle.setValue); return handle
  end
  function components.textInput(parent, definition)
    definition = definition or {}; local height = definition.description and Theme.CARD_H + 22 or Theme.CARD_H
    local handle = control(parent, definition, height); title(handle, definition, 76, height)
    local input = inst("TextBox", {
      Name = "Input",
      Size = UDim2.fromOffset(CONFIG.INPUT_WIDTH, 30),
      Position = UDim2.new(1, -76, 0.5, -15),
      BackgroundColor3 = C.inputBg,
      TextColor3 = C.text,
      TextSize = TEXT.control,
      Font = FONT.strong,
      ClearTextOnFocus = false,
      PlaceholderText = definition.placeholder or "",
      ZIndex = 11,
    }, handle.Root)
    kit.corner(input); local border = kit.stroke(input)
    local value
    function handle.setValue(nextValue)
      value = nextValue
      if UIS:GetFocusedTextBox() == input then return end
      input.Text = tostring(definition.format and definition.format(value) or value or "")
    end
    function handle.getValue() return value end
    function handle.setText(nextText) input.Text = tostring(nextText) end
    function handle.getText() return input.Text end
    handle.scope.connect(input.Focused, function() handle.motion.play(border, "feedback", { Color = C.accent }) end)
    handle.scope.connect(input.FocusLost, function(enterPressed)
      handle.motion.play(border, "feedback", { Color = C.border }); local nextValue = input.Text
      if definition.parse then nextValue = definition.parse(input.Text) end
      if definition.numeric then
        nextValue = finite(input.Text)
        if nextValue then nextValue = math.clamp(nextValue, definition.min or 0, definition.max or math.huge); nextValue = nextValue / (definition.displayScale or 1) end
      end
      if nextValue ~= nil and commit(handle, definition, nextValue) then value = nextValue end
      handle.setValue(read(definition.key, value))
      if definition.onSubmit then definition.onSubmit(input.Text, enterPressed) end
    end)
    handle.setValue(read(definition.key, definition.value)); bind(handle, definition.key, handle.setValue)
    return handle
  end
  components.number = function(parent, definition)
    local copy = table.clone(definition); copy.numeric = true
    copy.format = function(value) return tostring((finite(value) or 0) * (definition.displayScale or 1)) end
    return components.textInput(parent, copy)
  end
  function components.slider(parent, definition)
    definition = definition or {}; local minimum, maximum = finite(definition.min) or 0, finite(definition.max) or 100
    local step = finite(definition.increment or definition.step) or 1; assert(maximum > minimum and step > 0, "slider requires max > min and increment > 0")
    local height = definition.compact and Theme.CARD_H or (definition.description and 88 or 68); local handle = control(parent, definition, height)
    title(handle, definition, 72, math.min(height - 24, 70))
    local label = text(handle.Root, "", {
      Name = "Value",
      Size = UDim2.fromOffset(68, 20),
      Position = UDim2.new(1, -82, 0, 5),
      TextSize = TEXT.caption,
      TextXAlignment = Enum.TextXAlignment.Right,
    })
    local track = inst(
      "Frame",
      { Name = "Track", Size = UDim2.new(1, -28, 0, 6), Position = UDim2.new(0, 14, 1, -17), BackgroundColor3 = C.inputBg, ZIndex = 8 },
      handle.Root
    )
    kit.corner(track, Theme.RADIUS.pill); local fill = inst("Frame", { Name = "Fill", BackgroundColor3 = C.accent, Size = UDim2.new(), ZIndex = 9 }, track)
    kit.corner(fill, Theme.RADIUS.pill)
    local knob =
      inst("Frame", { Name = "Thumb", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = C.text, ZIndex = 10 }, track)
    kit.corner(knob, Theme.RADIUS.pill)
    local hit = button(
      handle.Root,
      "",
      { Name = "SliderHitbox", Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 1, -28), BackgroundTransparency = 1, ZIndex = 11 }
    )
    local value
    local function normalize(nextValue)
      return math.clamp(minimum + math.floor(((finite(nextValue) or minimum) - minimum) / step + 0.5) * step, minimum, maximum)
    end
    function handle.setValue(nextValue)
      value = normalize(nextValue); local alpha = (value - minimum) / (maximum - minimum)
      fill.Size = UDim2.fromScale(alpha, 1); knob.Position = UDim2.new(alpha, 0, 0.5, 0)
      label.Text = tostring(math.floor(value * 1000 + 0.5) / 1000) .. (definition.valueName and " " .. definition.valueName or "")
    end
    function handle.getValue() return value end
    local function change(nextValue)
      local normalized = normalize(nextValue)
      if normalized ~= value and commit(handle, definition, normalized) then handle.setValue(normalized) end
    end
    local cancelDrag = Runtime.bindDrag(handle.scope, hit, function(input)
      if handle.enabled and track.AbsoluteSize.X > 0 then change(minimum + math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1) * (maximum - minimum)) end
    end)
    drags[cancelDrag] = true
    handle.scope.add(function() drags[cancelDrag] = nil end)
    handle.scope.connect(hit.InputBegan, function(input)
      if input.KeyCode == Enum.KeyCode.Left then change(value - step) end
      if input.KeyCode == Enum.KeyCode.Right then change(value + step) end
    end)
    handle.setValue(read(definition.key, definition.value)); bind(handle, definition.key, handle.setValue)
    return handle
  end
  function components.segmented(parent, definition)
    definition = definition or {}; local choices = definition.options or definition.choices or {}
    assert(#choices > 0, "segmented requires options"); local handle = control(parent, definition, Theme.RATE_CARD_H)
    title(handle, definition, 0, 24)
    local track = inst(
      "Frame",
      { Name = "Track", Size = UDim2.new(1, -20, 0, 30), Position = UDim2.fromOffset(10, 28), BackgroundColor3 = C.inputBg, ZIndex = 8 },
      handle.Root
    )
    kit.corner(track); local thumb = inst("Frame", { Name = "Thumb", Size = UDim2.new(1 / #choices, -4, 1, -4), BackgroundColor3 = C.accent, ZIndex = 9 }, track)
    kit.corner(thumb); local buttons, value = {}, nil
    function handle.setValue(nextValue)
      if value == nextValue then return end
      value = nextValue
      for index, choice in ipairs(choices) do
        local selected = choiceValue(choice) == value
        if selected then handle.motion.play(thumb, "control", { Position = UDim2.new((index - 1) / #choices, 2, 0, 2) }) end
        handle.motion.play(buttons[index], "control", { TextColor3 = selected and C.text or C.subtext })
      end
    end
    function handle.getValue() return value end
    for index, choice in ipairs(choices) do
      local item = button(
        track,
        choiceLabel(choice),
        { Size = UDim2.new(1 / #choices, 0, 1, 0), Position = UDim2.fromScale((index - 1) / #choices, 0), BackgroundTransparency = 1, ZIndex = 10 }
      )
      buttons[index] = item
      handle.scope.connect(item.Activated, function()
        local nextValue = choiceValue(choice)
        if nextValue ~= value and commit(handle, definition, nextValue) then handle.setValue(nextValue) end
      end)
    end
    handle.setValue(read(definition.key, definition.value or choiceValue(choices[1]))); bind(handle, definition.key, handle.setValue)
    return handle
  end
  function components.dropdown(parent, definition)
    definition = definition or {}; local choices = definition.options or definition.choices or {}
    local handle = control(parent, definition, Theme.RATE_CARD_H); title(handle, definition, 0, 24)
    local trigger = button(handle.Root, "", { Name = "Select", Size = UDim2.new(1, -20, 0, 28), Position = UDim2.fromOffset(10, 29) })
    local value, openScope
    local function close()
      if popupClose == close then popupClose = nil end
      if openScope then openScope.destroy(); openScope = nil end
    end
    function handle.setValue(nextValue)
      value = nextValue; local label = tostring(value or definition.placeholder or "Select")
      for _, choice in ipairs(choices) do
        if choiceValue(choice) == value then label = choiceLabel(choice); break end
      end
      trigger.Text = label .. " ▾"
    end
    function handle.getValue() return value end
    local function open()
      if not handle.enabled or kit.suspended or #choices == 0 or not options.parent or not Runtime.isVisible(handle.Root) then return end
      kit.dismiss(); openScope = Runtime.scope()
      popupClose = close
      local portal = inst("ScreenGui", {
        Name = "ExodusDropdown",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = options.parent.DisplayOrder + 1,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
      }, options.parent.Parent)
      local menu = inst("CanvasGroup", { BackgroundColor3 = C.card, GroupTransparency = 1, ZIndex = 1 }, portal); kit.corner(menu)
      kit.stroke(menu, C.accent)
      local list = inst("ScrollingFrame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        CanvasSize = UDim2.new(),
        ScrollBarThickness = Theme.SCROLLBAR,
        ScrollBarImageColor3 = C.accent,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ZIndex = 2,
      }, menu)
      local menuMotion = kit.createMotion(openScope)
      openScope.add(portal, function() portal:Destroy() end)
      local function position()
        if not trigger.Parent or not Runtime.isVisible(trigger) then close(); return end
        local camera = workspace.CurrentCamera; local view = camera and camera.ViewportSize or Vector2.new(1920, 1080)
        local pos, size = trigger.AbsolutePosition, trigger.AbsoluteSize; local ancestor = trigger.Parent
        while ancestor and ancestor ~= options.parent do
          if
            ancestor:IsA("ScrollingFrame") and (pos.Y + size.Y <= ancestor.AbsolutePosition.Y or pos.Y >= ancestor.AbsolutePosition.Y + ancestor.AbsoluteSize.Y)
          then
            close(); return
          end
          ancestor = ancestor.Parent
        end
        local scale = math.max(0.1, size.Y / 28); local row, gap, pad = 32 * scale, 3 * scale, 4 * scale
        local desired = math.min(#choices, definition.maxVisible or CONFIG.DROPDOWN_ROWS) * (row + gap) + pad * 2
        local below, above = math.max(0, view.Y - pos.Y - size.Y - 12), math.max(0, pos.Y - 12); local down = below >= desired or below >= above
        local height = math.min(desired, down and below or above); local width = math.min(size.X, math.max(1, view.X - 12))
        menu.Size = UDim2.fromOffset(width, height); menu.Position = UDim2.fromOffset(math.clamp(pos.X, 6, math.max(6, view.X - width - 6)), down and pos.Y + size.Y + 5 or pos.Y - height - 5)
        list.CanvasSize = UDim2.fromOffset(0, #choices * (row + gap) + pad * 2)
        for index, item in ipairs(list:GetChildren()) do
          if item:IsA("TextButton") then
            item.Size = UDim2.new(1, -pad * 2 - Theme.SCROLLBAR, 0, row); item.Position = UDim2.fromOffset(pad, pad + (item.LayoutOrder - 1) * (row + gap))
            item.TextSize = math.max(10, TEXT.body * scale)
          end
        end
      end
      for index, choice in ipairs(choices) do
        local selected = choiceValue(choice) == value
        local item = button(list, choiceLabel(choice), {
          LayoutOrder = index,
          BackgroundColor3 = C.accent,
          BackgroundTransparency = selected and 0.25 or 1,
          TextColor3 = selected and C.text or C.subtext,
          ZIndex = 3,
        })
        openScope.connect(item.Activated, function()
          if commit(handle, definition, choiceValue(choice)) then handle.setValue(choiceValue(choice)); close() end
        end)
      end
      position()
      if not openScope then return end
      menuMotion.play(menu, "feedback", { GroupTransparency = 0 }); openScope.connect(RunService.Heartbeat, position)
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
  function components.progressBar(parent, definition)
    definition = definition or {}; local handle = control(parent, definition, 8)
    handle.Root.ClipsDescendants = true; local fill = inst("Frame", { Name = "Fill", BackgroundColor3 = definition.color or C.accent, Size = UDim2.fromScale(0, 1), ZIndex = 8 }, handle.Root)
    kit.corner(fill)
    local value
    function handle.setValue(nextValue)
      value = math.clamp(finite(nextValue) or 0, 0, 1); handle.motion.play(fill, "control", { Size = UDim2.fromScale(value, 1) })
    end
    function handle.getValue() return value end
    handle.setValue(read(definition.key, definition.value)); bind(handle, definition.key, handle.setValue)
    return handle
  end
  function components.divider(parent, definition)
    local handle = components.label(parent, definition or {}); handle.Root.Size = UDim2.new(1, -8, 0, 1)
    handle.Root.BackgroundTransparency = 0; handle.Root.BackgroundColor3 = C.border
    return handle
  end
  function components.rate_selector(parent, definition)
    local modes = { { value = "CPS", label = "CPS" }, { value = "CPF", label = "CPF" }, { value = "MS", label = "MS" }, { value = "Auto", label = "Auto" } }
    local handle = components.segmented(parent, { title = definition.title or "Spam Rate", key = "SpamRateMode", options = modes }); local updateMode = handle.setValue
    local track = handle.Root.Track; track.Size = UDim2.new(1, -88, 0, 30)
    local input = inst("TextBox", {
      Name = "RateInput",
      Size = UDim2.fromOffset(58, 30),
      Position = UDim2.new(1, -68, 0, 28),
      BackgroundColor3 = C.inputBg,
      TextColor3 = C.text,
      TextSize = TEXT.control,
      Font = FONT.strong,
      ClearTextOnFocus = false,
      ZIndex = 11,
    }, handle.Root)
    kit.corner(input)
    local function paint()
      local mode = read("SpamRateMode", "CPF"); updateMode(mode)
      input.TextEditable = mode ~= "Auto"
      if UIS:GetFocusedTextBox() ~= input then input.Text = mode == "Auto" and "Auto" or tostring(read(mode, 0)) end
    end
    for _, key in ipairs({ "SpamRateMode", "CPS", "CPF", "MS" }) do
      bind(handle, key, paint)
    end
    handle.scope.connect(input.FocusLost, function()
      local mode = read("SpamRateMode", "CPF"); local value = finite(input.Text)
      if mode ~= "Auto" and value and value >= 0 and options.write then options.write(mode, value) end
      paint()
    end)
    paint(); return handle
  end
  components.tabs = components.segmented; components.click = components.button
  components.scroll = components.slider; components.off_on = components.toggle
  components.keybind_selector = components.button; return kit
end

-- contract
UIKit.__contract = {
  provides = { "setup", "create" },
  requires = { Theme = "uitheme", Runtime = "uiruntime" },
  requiresData = { Theme = { "tokens" } },
  requiresMethods = { Runtime = { "scope", "motion", "isVisible", "bindDrag" } },
}

return UIKit
