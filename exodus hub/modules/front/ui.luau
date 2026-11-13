-- [[ ui library ]]

local UILib = {}

-- configuration
local CONFIG = {
  BACKGROUND = Color3.fromRGB(14, 14, 34),
  CONTROL = Color3.fromRGB(35, 35, 66),
  TEXT = Color3.fromRGB(240, 240, 255),
  ACCENT = Color3.fromRGB(139, 92, 246),
}

-- primitives
function UILib.create(class, properties, parent)
  local object = Instance.new(class)
  for key, value in pairs(properties or {}) do object[key] = value end
  if parent then object.Parent = parent end
  return object
end
function UILib.setup() return true end
function UILib.teardown() return true end

-- standalone interface
function UILib.new(options)
  options = options or {}
  local parent = assert(options.parent, "UI parent required")
  local gui = UILib.create("ScreenGui", { Name = options.name or "UILibrary", ResetOnSpawn = false }, parent)
  local panel = UILib.create("Frame", { Size = UDim2.fromOffset(360, 440), Position = UDim2.new(0.5, -180, 0.5, -220), BackgroundColor3 = options.background or CONFIG.BACKGROUND, BorderSizePixel = 0 }, gui)
  UILib.create("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
  UILib.create("TextLabel", { Size = UDim2.new(1, -24, 0, 38), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1, Text = options.title or "Interface", TextColor3 = CONFIG.TEXT, TextSize = 18, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left }, panel)
  local container = UILib.create("ScrollingFrame", { Size = UDim2.new(1, -20, 1, -48), Position = UDim2.fromOffset(10, 42), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new() }, panel)
  UILib.create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, container)
  local connections, destroyed, order = {}, false, 0
  local api = {}
  local function watch(signal, callback) local c = signal:Connect(callback); connections[#connections + 1] = c; return c end
  local function row(class, text, height)
    assert(not destroyed, "interface destroyed"); order += 1
    local object = UILib.create(class, { Name = "Component", LayoutOrder = order, Size = UDim2.new(1, -5, 0, height or 38), BackgroundColor3 = CONFIG.CONTROL, BorderSizePixel = 0, Text = text or "", TextColor3 = CONFIG.TEXT, TextSize = 14, Font = Enum.Font.Gotham }, container)
    UILib.create("UICorner", { CornerRadius = UDim.new(0, 6) }, object); return object
  end
  function api.label(text) return row("TextLabel", tostring(text), 30) end
  function api.button(text, callback)
    local button = row("TextButton", tostring(text)); watch(button.Activated, function() if callback then callback() end end); return button
  end
  function api.toggle(text, initial, callback)
    local value = initial == true; local button = row("TextButton", "")
    local function render() button.Text = tostring(text) .. (value and " : ON" or " : OFF") end
    local handle = { instance = button }
    function handle.set(nextValue, notify) value = nextValue == true; render(); if notify and callback then callback(value) end end
    function handle.get() return value end
    watch(button.Activated, function() handle.set(not value, true) end); render(); return handle
  end
  function api.textbox(placeholder, initial, callback)
    local box = row("TextBox", tostring(initial or "")); box.PlaceholderText = tostring(placeholder or ""); box.ClearTextOnFocus = false
    watch(box.FocusLost, function(enter) if callback then callback(box.Text, enter) end end); return box
  end
  function api.slider(text, minimum, maximum, initial, step, callback)
    assert(type(minimum) == "number" and type(maximum) == "number" and maximum > minimum, "invalid slider range")
    step = tonumber(step) or 1; assert(step > 0, "invalid slider step")
    local button = row("TextButton", ""); local value
    local handle = { instance = button }
    function handle.set(nextValue, notify)
      value = math.clamp(minimum + math.floor((tonumber(nextValue) - minimum) / step + 0.5) * step, minimum, maximum)
      button.Text = tostring(text) .. ": " .. tostring(value)
      if notify and callback then callback(value) end
    end
    function handle.get() return value end
    local dragging = false; local inputService = game:GetService("UserInputService")
    local function update(input) if button.AbsoluteSize.X > 0 then handle.set(minimum + (maximum - minimum) * math.clamp((input.Position.X - button.AbsolutePosition.X) / button.AbsoluteSize.X, 0, 1), true) end end
    watch(button.InputBegan, function(input) if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = input; update(input) end end)
    watch(inputService.InputChanged, function(input) if dragging and (input == dragging or dragging.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement) then update(input) end end)
    watch(inputService.InputEnded, function(input) if input == dragging then dragging = false end end)
    handle.set(initial or minimum, false); return handle
  end
  function api.select(text, values, initial, callback)
    assert(type(values) == "table" and #values > 0, "selection options required")
    local index = math.clamp(tonumber(initial) or 1, 1, #values); index = math.floor(index)
    local button = row("TextButton", ""); local handle = { instance = button }
    function handle.get() return values[index] end
    function handle.set(nextIndex, notify) index = math.clamp(math.floor(nextIndex), 1, #values); button.Text = tostring(text) .. ": " .. tostring(values[index]); if notify and callback then callback(values[index], index) end end
    watch(button.Activated, function() handle.set(index % #values + 1, true) end); handle.set(index, false); return handle
  end
  function api.section(text)
    local label = row("TextLabel", tostring(text), 32)
    label.BackgroundTransparency = 1; label.Font = Enum.Font.GothamBold; label.TextXAlignment = Enum.TextXAlignment.Left
    return label
  end
  function api.paragraph(title, description)
    local label = row("TextLabel", tostring(title) .. "\n" .. tostring(description or ""), 60)
    label.TextWrapped = true; label.TextXAlignment = Enum.TextXAlignment.Left
    return label
  end
  function api.separator()
    local line = UILib.create("Frame", { Size = UDim2.new(1, -5, 0, 1), BackgroundColor3 = CONFIG.ACCENT, BorderSizePixel = 0 }, container)
    order += 1; line.LayoutOrder = order; return line
  end
  function api.number(text, initial, minimum, maximum, callback)
    local value = tonumber(initial) or 0
    local box = row("TextBox", tostring(value)); box.PlaceholderText = tostring(text or ""); box.ClearTextOnFocus = false
    local handle = { instance = box }
    function handle.get() return value end
    function handle.set(nextValue, notify)
      local number = tonumber(nextValue)
      if not number or number ~= number or number == math.huge or number == -math.huge then box.Text = tostring(value); return false end
      if type(minimum) == "number" then number = math.max(minimum, number) end
      if type(maximum) == "number" then number = math.min(maximum, number) end
      value = number; box.Text = tostring(value); if notify and callback then callback(value) end; return true
    end
    watch(box.FocusLost, function() handle.set(box.Text, true) end); return handle
  end
  function api.keybind(text, initial, callback)
    local key = initial; local capturing = false; local button = row("TextButton", "")
    local function render() button.Text = tostring(text) .. ": " .. (key and key.Name or "None") end
    local handle = { instance = button }
    function handle.get() return key end
    function handle.set(value) key = value; capturing = false; render() end
    watch(button.Activated, function() capturing = true; button.Text = tostring(text) .. ": ..." end)
    watch(game:GetService("UserInputService").InputBegan, function(input, processed)
      if capturing and input.UserInputType == Enum.UserInputType.Keyboard then
        handle.set(input.KeyCode); return
      end
      if not processed and key and input.KeyCode == key and callback then callback(key) end
    end)
    render(); return handle
  end
  function api.multiselect(text, values, initial, callback)
    assert(type(values) == "table" and #values > 0, "selection options required")
    local selected = {}; for _, value in ipairs(initial or {}) do selected[value] = true end
    local current = 1; local button = row("TextButton", "")
    local handle = { instance = button }
    local function render() local value = values[current]; button.Text = tostring(text) .. ": " .. tostring(value) .. (selected[value] and " [x]" or " [ ]") end
    function handle.get() local result = {}; for _, value in ipairs(values) do if selected[value] then result[#result + 1] = value end end; return result end
    function handle.set(value, enabled, notify) selected[value] = enabled == true or nil; render(); if notify and callback then callback(handle.get()) end end
    function handle.next() current = current % #values + 1; render() end
    watch(button.Activated, function() local value = values[current]; handle.set(value, not selected[value], true); handle.next() end)
    render(); return handle
  end
  function api.setVisible(visible) gui.Enabled = visible == true end
  function api.destroy() if destroyed then return end; destroyed = true; for _, connection in ipairs(connections) do connection:Disconnect() end; table.clear(connections); gui:Destroy() end
  api.gui = gui; api.panel = panel; return api
end

-- contract
UILib.__contract = { requires = {}, provides = { "setup", "teardown", "create", "new" } }
return UILib
