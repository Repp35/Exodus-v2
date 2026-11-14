-- [[ selection ]]

-- module
local Components = {}

-- configuration
local CONFIG = {}

-- setup
function Components.setup() return true end

-- components
function Components.install(context)
  local kit = context.kit; local Theme = context.Theme
  local UIS = context.UIS; local options = context.options
  local components = context.components; local C = context.C
  local FONT = context.FONT; local TEXT = context.TEXT
  local inst = context.inst; local text = context.text
  local control = context.control; local title = context.title
  local button = context.button; local commit = context.commit
  local bind = context.bind; local read = context.read
  local finite = context.finite; local choiceValue = context.choiceValue
  local choiceLabel = context.choiceLabel
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
        if selected then
          local color = type(choice) == "table" and choice.color or nil; color = color or (definition.colors and definition.colors[value]) or Theme.SELECTOR_COLORS[value] or C.accent
          handle.motion.play(thumb, "control", { Position = UDim2.new((index - 1) / #choices, 2, 0, 2), BackgroundColor3 = color })
        end
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
end

-- contract
Components.__contract = { provides = { "setup", "install" }, requires = {} }

return Components
