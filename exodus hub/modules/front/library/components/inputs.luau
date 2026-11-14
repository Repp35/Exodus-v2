-- [[ inputs ]]

-- module
local Components = {}

-- configuration
local CONFIG = { INPUT_WIDTH = 62 }

-- setup
function Components.setup() return true end

-- components
function Components.install(context)
  local drags = context.drags; local kit = context.kit
  local Theme = context.Theme; local Runtime = context.Runtime
  local UIS = context.UIS; local components = context.components
  local C = context.C; local FONT = context.FONT
  local TEXT = context.TEXT; local inst = context.inst
  local text = context.text; local control = context.control
  local title = context.title; local button = context.button
  local commit = context.commit; local bind = context.bind
  local read = context.read; local finite = context.finite
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
end

-- contract
Components.__contract = { provides = { "setup", "install" }, requires = {} }

return Components
