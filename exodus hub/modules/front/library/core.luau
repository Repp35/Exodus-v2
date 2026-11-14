-- [[ uikit ]]

-- module
local UIKit = {}
local Theme
local Runtime
local Icons
local Display
local ControlComponents
local Inputs
local Selection
local Dropdown
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

-- configuration
local CONFIG = {}

-- setup
function UIKit.setup(deps)
  Theme, Runtime, Icons = deps.Theme.tokens, deps.Runtime, deps.Icons
  Display, ControlComponents, Inputs, Selection, Dropdown = deps.Display, deps.ControlComponents, deps.Inputs, deps.Selection, deps.Dropdown; return true
end

-- helpers
local function finite(value)
  local number = tonumber(value); return number and number == number and number > -math.huge and number < math.huge and number or nil
end
local function choiceValue(choice) return type(choice) == "table" and choice.value or choice end
local function choiceLabel(choice) return tostring(type(choice) == "table" and (choice.label or choice.value) or choice) end
local function keyName(value)
  if value == Enum.KeyCode.Unknown then return "—" end
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
  local bindings, components, drags, observers = {}, {}, {}, {}; local feedback = {}
  local popup, capture, capturedInput = {}, nil, nil; local kit = { icon = Icons.create, Theme = Theme, Components = components, scope = scope, motion = motion, suspended = false }
  local motions = { [motion] = true }
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
  function kit.isCapturing(input) return capture ~= nil or (input ~= nil and capturedInput == input) end
  function kit.cancelCapture()
    local pending = capture; capture = nil
    if pending then
      pending.restore()
      if options.onCapture then options.onCapture(false) end
    end
  end
  function kit.dismiss()
    for _, reset in pairs(feedback) do
      reset()
    end
    for cancel in pairs(drags) do
      cancel()
    end
    if popup.close then popup.close() end
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
      if input.KeyCode == Enum.KeyCode.Escape then
        capturedInput = input; kit.cancelCapture()
        return
      end
      if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete then binding = Enum.KeyCode.Unknown
      elseif input.KeyCode ~= Enum.KeyCode.Unknown then binding = input.KeyCode end
    elseif
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.MouseButton2
      or input.UserInputType == Enum.UserInputType.MouseButton3
    then
      binding = input.UserInputType
    end
    if binding then
      capturedInput = input; local pending = capture
      kit.cancelCapture(); pending.pick(binding)
    end
  end)
  scope.connect(UIS.WindowFocusReleased, kit.cancelCapture)
  function kit.feedback(lifetime, target, paint, enabled)
    local hovered, held = false, nil
    local function refresh()
      local allowed = not kit.suspended and (not enabled or enabled()); paint(allowed and (hovered or held ~= nil), allowed and held ~= nil)
    end
    local function reset()
      hovered, held = false, nil; refresh()
    end
    local function release(input)
      if held == input then
        if held.UserInputType == Enum.UserInputType.Touch then hovered = false end
        held = nil; refresh()
      end
    end
    feedback[release] = reset
    lifetime.add(function() feedback[release] = nil end)
    lifetime.connect(target.MouseEnter, function()
      hovered = true; refresh()
    end)
    lifetime.connect(target.MouseLeave, function()
      hovered = false; refresh()
    end)
    lifetime.connect(target.InputBegan, function(input)
      if held or kit.suspended or (enabled and not enabled()) then return end
      if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if input.UserInputType == Enum.UserInputType.Touch then hovered = false end
        held = input; refresh()
      end
    end)
    return refresh, reset
  end
  scope.connect(UIS.InputEnded, function(input)
    for release in pairs(feedback) do
      release(input)
    end
  end)
  scope.connect(UIS.WindowFocusReleased, function()
    for _, reset in pairs(feedback) do
      reset()
    end
  end)
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
    local handle = { Root = root, Border = border, scope = childScope, motion = childMotion, enabled = true }
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
        Position = UDim2.fromOffset(14, definition.expandedDescription and 42 or 26),
        Size = UDim2.new(1, -(28 + (definition.expandedDescription and 0 or (rightSpace or 0))), 0, height - (definition.expandedDescription and 48 or 30)),
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
  local function shortcut(handle, key, xOffset, topAligned)
    if not key then return end
    local cap = button(handle.Root, keyName(read(key)), {
      Name = "Shortcut_" .. key,
      Position = topAligned and UDim2.new(1, xOffset or -126, 0, 10) or UDim2.new(1, xOffset or -126, 0.5, -13),
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
          if options.validateShortcut then
            local ok, reason = options.validateShortcut(key, value)
            if not ok then
              if options.notify then options.notify(reason or "Shortcut already assigned", true, { category = "system" }) end
              return
            end
          end
          if not options.write or options.write(key, value) ~= false then paint(value) end
        end,
      }

      if options.onCapture then options.onCapture(true) end
    end)
    handle.scope.add(function()
      if capture and capture.owner == handle then kit.cancelCapture() end
    end)
  end
  local context = {
    drags = drags,
    kit = kit,
    Theme = Theme,
    Runtime = Runtime,
    UIS = UIS,
    RunService = RunService,
    options = options,
    components = components,
    C = C,
    FONT = FONT,
    TEXT = TEXT,
    inst = inst,
    text = text,
    control = control,
    title = title,
    button = button,
    hitbox = hitbox,
    commit = commit,
    shortcut = shortcut,
    bind = bind,
    read = read,
    finite = finite,
    choiceValue = choiceValue,
    choiceLabel = choiceLabel,
    keyName = keyName,
    popup = popup,
  }

  Display.install(context); ControlComponents.install(context)
  Inputs.install(context); Selection.install(context)
  Dropdown.install(context); components.tabs = components.segmented
  components.click = components.button; components.scroll = components.slider
  components.off_on = components.toggle; components.keybind_selector = components.button
  return kit
end

-- contract
UIKit.__contract = {
  provides = { "setup", "create" },
  requires = {
    Theme = "uitheme",
    Runtime = "uiruntime",
    Icons = "uiicons",
    Display = "uidisplay",
    ControlComponents = "uicontrols",
    Inputs = "uiinputs",
    Selection = "uiselection",
    Dropdown = "uidropdown",
  },
  requiresData = { Theme = { "tokens" } },
  requiresMethods = {
    Runtime = { "scope", "motion", "isVisible", "bindDrag" },
    Icons = { "create" },
    Display = { "install" },
    ControlComponents = { "install" },
    Inputs = { "install" },
    Selection = { "install" },
    Dropdown = { "install" },
  },
}

return UIKit
