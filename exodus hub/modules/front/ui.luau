-- [[ ui library ]]

local UI = {}

-- configuration
local CONFIG = {
  WIDTH = 520, HEIGHT = 540,
  KINDS = { label = true, paragraph = true, section = true, separator = true, button = true, toggle = true, textbox = true, number = true, slider = true, progress = true, dropdown = true, multiselect = true, keybind = true, color = true },
  THEME = {
    background = Color3.fromRGB(8, 8, 22), header = Color3.fromRGB(14, 14, 34),
    card = Color3.fromRGB(20, 20, 44), accent = Color3.fromRGB(139, 92, 246),
    text = Color3.fromRGB(240, 240, 255), muted = Color3.fromRGB(150, 150, 190),
    border = Color3.fromRGB(55, 55, 100), danger = Color3.fromRGB(153, 27, 27),
  },
}
local windows = {}
local function finite(v) return type(v) == "number" and v == v and v > -math.huge and v < math.huge end
local function clamp(v, a, b) return math.max(a, math.min(v, b)) end
local function copy(t) local r = {}; for k, v in pairs(t or {}) do r[k] = v end; return r end
local function create(class, props, parent)
  local object = Instance.new(class)
  for key, value in pairs(props or {}) do if key ~= "Parent" then object[key] = value end end
  object.Parent = parent or (props and props.Parent); return object
end
local function round(object, radius) create("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, object) end
local function keyName(key) return key and key.Name or "None" end

-- standalone-window
function UI.new(options)
  options = options or {}
  local parent = options.parent
  if not parent then
    local player = game:GetService("Players").LocalPlayer
    parent = player and player:FindFirstChildOfClass("PlayerGui")
  end
  assert(parent, "UI.new: parent or PlayerGui required")
  local input = game:GetService("UserInputService")
  local run = game:GetService("RunService")
  local theme = copy(CONFIG.THEME); for k, v in pairs(options.theme or {}) do theme[k] = v end
  local width, height = options.width or CONFIG.WIDTH, options.height or CONFIG.HEIGHT
  assert(finite(width) and finite(height) and width > 120 and height > 180, "invalid window dimensions")
  local alive, closing, visible = true, false, options.visible ~= false
  local connections, cleanups, pages, handles, bindings, notices = {}, {}, {}, {}, {}, {}
  local capturing, activePage, order, elapsed = nil, nil, 0, 0
  local api = {}
  local gui = create("ScreenGui", { Name = options.name or "HubUI", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, parent)
  local panel = create("CanvasGroup", { Name = "Window", Size = UDim2.fromOffset(width, height), AnchorPoint = Vector2.new(0.5, 0.5), Position = options.position or UDim2.new(0.5, 0, 0.5, 0), BackgroundColor3 = theme.background, BorderSizePixel = 0, Visible = visible }, gui)
  round(panel, 12)
  local scale = create("UIScale", { Scale = 1 }, panel)
  local header = create("Frame", { Active = true, Name = "Header", Size = UDim2.new(1, 0, 0, 44), BackgroundColor3 = theme.header, BorderSizePixel = 0 }, panel)
  round(header, 12)
  local title = create("TextLabel", { Size = UDim2.new(1, -110, 1, 0), Position = UDim2.fromOffset(14, 0), BackgroundTransparency = 1, Text = options.title or "Interface", Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = theme.text, TextXAlignment = Enum.TextXAlignment.Left }, header)
  local tabs = create("ScrollingFrame", { Size = UDim2.new(1, -20, 0, 36), Position = UDim2.fromOffset(10, 50), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2, AutomaticCanvasSize = Enum.AutomaticSize.X, CanvasSize = UDim2.new() }, panel)
  create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, tabs)
  local content = create("Frame", { Size = UDim2.new(1, -20, 1, -140), Position = UDim2.fromOffset(10, 94), BackgroundTransparency = 1, ClipsDescendants = true }, panel)
  local footer = create("Frame", { Size = UDim2.new(1, -20, 0, 32), Position = UDim2.new(0, 10, 1, -38), BackgroundTransparency = 1 }, panel)
  create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, footer)
  local noticeLayer = create("Frame", { Size = UDim2.new(0, 310, 1, -28), Position = UDim2.new(1, -324, 0, 14), BackgroundTransparency = 1 }, gui)
  create("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Bottom }, noticeLayer)
  local function watch(signal, callback)
    local c = signal:Connect(function(...) if alive then callback(...) end end)
    connections[#connections + 1] = c; return c
  end
  local function report(message)
    if options.onError then options.onError(tostring(message)) else warn("[UI] " .. tostring(message)) end
  end
  local function call(callback, ...)
    if not alive or type(callback) ~= "function" then return true end
    local ok, result = pcall(callback, ...)
    if not ok then report(result); return false end
    return result ~= false
  end
  local function button(parentObject, text, size)
    local b = create("TextButton", { Size = size or UDim2.fromOffset(90, 30), BackgroundColor3 = theme.card, BorderSizePixel = 0, Text = text or "", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = theme.text, AutoButtonColor = true }, parentObject)
    round(b, 7); return b
  end
  local function responsive()
    local camera = workspace.CurrentCamera
    if camera then
      local size = camera.ViewportSize
      scale.Scale = math.min(1, math.max(0.35, math.min((size.X - 24) / width, (size.Y - 24) / height)))
    end
  end
  local function draggable(grip, object, onMove)
    local start, origin, drag, moved, lastMoved = nil, nil, nil, false, -math.huge
    watch(grip.InputBegan, function(event)
      if event.UserInputType == Enum.UserInputType.MouseButton1 or event.UserInputType == Enum.UserInputType.Touch then
        start, origin, drag, moved = event.Position, object.Position, event, false
      end
    end)
    watch(input.InputChanged, function(event)
      if not drag then return end
      if event ~= drag and not (drag.UserInputType == Enum.UserInputType.MouseButton1 and event.UserInputType == Enum.UserInputType.MouseMovement) then return end
      local delta = event.Position - start
      if delta.Magnitude < 6 and not moved then return end
      moved = true; lastMoved = os.clock()
      object.Position = UDim2.new(origin.X.Scale, origin.X.Offset + delta.X, origin.Y.Scale, origin.Y.Offset + delta.Y)
    end)
    watch(input.InputEnded, function(event)
      if event ~= drag then return end
      drag = nil
      if moved then lastMoved = os.clock(); call(onMove, object.Position) end
    end)
    return function() return moved and drag ~= nil or os.clock() - lastMoved < 0.15 end
  end
  draggable(header, panel, options.onMove)
  local minimized = button(header, "−", UDim2.fromOffset(30, 28)); minimized.Position = UDim2.new(1, -72, 0, 8)
  local close = button(header, "×", UDim2.fromOffset(30, 28)); close.Position = UDim2.new(1, -36, 0, 8)
  function api.setVisible(value) visible = value == true; if alive then panel.Visible = visible; panel.GroupTransparency = 0 end end
  function api.isVisible() return visible end
  function api.isAlive() return alive end
  function api.toggle() api.setVisible(not visible) end
  function api.restore(message) closing = false; gui.Enabled = true; api.setVisible(true); if message then api.notify(message, "error", 4) end end
  function api.fadeOut()
    if not alive then return false end
    gui.Enabled = false
    return true
  end
  function api.destroy()
    if not alive then return end
    alive = false
    for _, callback in ipairs(cleanups) do local ok, err = pcall(callback); if not ok then report(err) end end
    for _, c in ipairs(connections) do c:Disconnect() end
    table.clear(connections); table.clear(cleanups); windows[api] = nil; gui:Destroy()
  end
  function api.addCleanup(callback) assert(type(callback) == "function", "cleanup callback required"); cleanups[#cleanups + 1] = callback end
  local function closeRequested()
    if closing then return end; closing = true
    if options.onClose then if not call(options.onClose) and alive then closing = false end else api.destroy() end
  end
  watch(minimized.Activated, api.toggle); watch(close.Activated, closeRequested)
  function api.notify(message, kind, duration, id)
    if not alive then return end
    id = id or ("notice_" .. tostring(os.clock()))
    local notice = notices[id]
    if not notice then
      local label = create("TextLabel", { Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = kind == "error" and theme.danger or theme.card, BorderSizePixel = 0, TextColor3 = theme.text, Font = Enum.Font.Gotham, TextSize = 12, TextWrapped = true }, noticeLayer)
      round(label); notice = { instance = label, revision = 0 }; notices[id] = notice
    end
    notice.instance.Text = tostring(message); notice.revision = notice.revision + 1
    local revision = notice.revision
    if duration == nil then duration = 3 end
    if duration > 0 then task.delay(duration, function() if alive and notices[id] == notice and notice.revision == revision then api.clearNotification(id) end end) end
    return id
  end
  function api.clearNotification(id) local n = notices[id]; if n then n.instance:Destroy(); notices[id] = nil end end
  function api.get(id) return handles[id] end
  function api.set(id, value, notify)
    local handle = handles[id]; if not handle then return false end
    return handle.set(value, notify)
  end
  function api.setControlVisible(id, value) local handle = handles[id]; if handle then handle.setVisible(value); return true end; return false end
  function api.bindKey(id, key, callback, release)
    bindings[id] = { key = key, callback = callback, release = release }; return id
  end
  function api.unbindKey(id) bindings[id] = nil end
  function api.action(text, callback)
    local b = button(footer, text, UDim2.fromOffset(110, 30)); watch(b.Activated, function() call(callback) end); return b
  end
  function api.page(id, pageTitle)
    assert(not pages[id], "duplicate page: " .. tostring(id))
    local scroller = create("ScrollingFrame", { Name = tostring(id), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), Visible = false }, content)
    create("UIListLayout", { Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder }, scroller)
    local tab = button(tabs, pageTitle or tostring(id), UDim2.fromOffset(90, 30))
    local page = { instance = scroller, tab = tab }
    function page.select()
      for _, item in pairs(pages) do item.instance.Visible = false; item.tab.BackgroundColor3 = theme.card end
      scroller.Visible = true; tab.BackgroundColor3 = theme.accent; activePage = id
    end
    watch(tab.Activated, page.select); pages[id] = page
    if not activePage then page.select() end
    function page.add(definition) return api.add(scroller, definition) end
    return page
  end
  function api.selectPage(id) if not pages[id] then return false end; pages[id].select(); return true end

  -- component-factory
  function api.add(parentObject, definition)
    assert(alive, "window destroyed")
    local d = definition or {}; local kind = d.kind or "label"
    assert(CONFIG.KINDS[kind], "unknown UI component: " .. tostring(kind))
    assert(not d.id or not handles[d.id], "duplicate control: " .. tostring(d.id))
    order = order + 1
    local row = create("Frame", { Name = d.id or kind, LayoutOrder = order, Size = UDim2.new(1, -6, 0, kind == "separator" and 2 or (d.description and 74 or 54)), BackgroundColor3 = theme.card, BorderSizePixel = 0, Visible = d.visible ~= false }, parentObject)
    round(row)
    local label = create("TextLabel", { Size = UDim2.new(1, -20, 0, 24), Position = UDim2.fromOffset(10, 4), BackgroundTransparency = 1, Text = tostring(d.title or ""), Font = Enum.Font.GothamSemibold, TextSize = 13, TextColor3 = theme.text, TextXAlignment = Enum.TextXAlignment.Left }, row)
    local descriptionLabel
    if d.description then descriptionLabel = create("TextLabel", { Size = UDim2.new(1, -20, 0, 22), Position = UDim2.new(0, 10, 1, -24), BackgroundTransparency = 1, Text = tostring(d.description), TextColor3 = theme.muted, TextSize = 10, Font = Enum.Font.Gotham, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left }, row) end
    local handle = { instance = row }; local value = d.value; local render = function() end
    local function set(nextValue, notify)
      local previous = value; value = nextValue; render()
      if notify and not call(d.onChange, value) then value = previous; render(); return false end
      return true
    end
    function handle.set(v, notify) return set(v, notify == true) end
    function handle.get() return value end
    function handle.setVisible(v) row.Visible = v == true end
    function handle.setTitle(v) label.Text = tostring(v) end
    function handle.setDescription(v) if descriptionLabel then descriptionLabel.Text = tostring(v) end end
    if d.id then handles[d.id] = handle end
    if kind == "label" or kind == "paragraph" or kind == "section" then
      row.BackgroundTransparency = kind == "section" and 1 or 0
      if kind == "paragraph" then row.Size = UDim2.new(1, -6, 0, d.height or 76); label.Size = UDim2.new(1, -20, 1, -12); label.TextWrapped = true end
      if kind == "section" then row.Size = UDim2.new(1, -6, 0, 28); label.Font = Enum.Font.GothamBold end
      render = function() if value ~= nil then label.Text = tostring(value) end end
    elseif kind == "separator" then label.Visible = false; row.BackgroundColor3 = theme.border
    elseif kind == "button" then
      local b = button(row, d.title or "Run", UDim2.new(1, -14, 0, 34)); b.Position = UDim2.fromOffset(7, 5); label.Visible = false
      watch(b.Activated, function() call(d.onClick) end)
    elseif kind == "toggle" then
      label.Size = UDim2.new(1, -100, 0, 24)
      local b = button(row, "", UDim2.fromOffset(70, 30)); b.Position = UDim2.new(1, -80, 0, 6)
      render = function() value = value == true; b.Text = value and "ON" or "OFF"; b.BackgroundColor3 = value and theme.accent or theme.header end
      watch(b.Activated, function() set(not value, true) end)
    elseif kind == "textbox" or kind == "number" then
      label.Size = UDim2.new(0.5, -10, 0, 24)
      local box = create("TextBox", { Size = UDim2.new(0.5, -14, 0, 30), Position = UDim2.new(0.5, 4, 0, 6), BackgroundColor3 = theme.header, TextColor3 = theme.text, BorderSizePixel = 0, Font = Enum.Font.Gotham, TextSize = 13, Text = "", ClearTextOnFocus = false, PlaceholderText = d.placeholder or "" }, row); round(box, 5)
      render = function() box.Text = tostring(value == nil and "" or value) end
      local normalize = function(v)
        if kind ~= "number" then return tostring(v or "") end
        v = tonumber(v); if not finite(v) then return nil end
        if finite(d.min) then v = math.max(d.min, v) end; if finite(d.max) then v = math.min(d.max, v) end
        return v
      end
      function handle.set(v, notify) local n = normalize(v); if n == nil then return false end; return set(n, notify == true) end
      watch(box.FocusLost, function() if not handle.set(box.Text, true) then render() end end)
    elseif kind == "slider" or kind == "progress" then
      local minimum, maximum, step = d.min or 0, d.max or 100, d.step or 1
      assert(finite(minimum) and finite(maximum) and maximum > minimum and finite(step) and step > 0, "invalid range")
      local text = create("TextLabel", { Size = UDim2.fromOffset(90, 20), Position = UDim2.new(1, -100, 0, 3), BackgroundTransparency = 1, TextColor3 = theme.text, TextSize = 12, Font = Enum.Font.Gotham }, row)
      local track = create("Frame", { Size = UDim2.new(1, -24, 0, 6), Position = UDim2.fromOffset(12, 36), BackgroundColor3 = theme.header, BorderSizePixel = 0 }, row); round(track)
      local fill = create("Frame", { Size = UDim2.new(), BackgroundColor3 = theme.accent, BorderSizePixel = 0 }, track); round(fill)
      local function normalize(v) v = tonumber(v); if not finite(v) then return nil end; return clamp(minimum + math.floor((v - minimum) / step + 0.5) * step, minimum, maximum) end
      render = function() value = normalize(value) or minimum; fill.Size = UDim2.new((value - minimum) / (maximum - minimum), 0, 1, 0); text.Text = tostring(math.floor(value * 1000 + 0.5) / 1000) .. (d.suffix or "") end
      function handle.set(v, notify) local n = normalize(v); if not n then return false end; return set(n, notify == true) end
      if kind == "slider" then
        local hit = create("TextButton", { Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, -9), BackgroundTransparency = 1, Text = "" }, track)
        local drag
        local function update(event) if track.AbsoluteSize.X > 0 then handle.set(minimum + clamp((event.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1) * (maximum - minimum), true) end end
        watch(hit.InputBegan, function(event) if event.UserInputType == Enum.UserInputType.MouseButton1 or event.UserInputType == Enum.UserInputType.Touch then drag = event; update(event) end end)
        watch(input.InputChanged, function(event) if drag and (event == drag or drag.UserInputType == Enum.UserInputType.MouseButton1 and event.UserInputType == Enum.UserInputType.MouseMovement) then update(event) end end)
        watch(input.InputEnded, function(event) if event == drag then drag = nil end end)
      end
    elseif kind == "dropdown" or kind == "multiselect" then
      local choices = d.options or {}; assert(#choices > 0, "selection options required")
      row.Size = UDim2.new(1, -6, 0, 54)
      local b = button(row, "", UDim2.new(0.5, -14, 0, 30)); b.Position = UDim2.new(0.5, 4, 0, 6); label.Size = UDim2.new(0.5, -10, 0, 24)
      local menu = create("Frame", { Size = UDim2.new(1, -14, 0, #choices * 32), Position = UDim2.fromOffset(7, 48), BackgroundColor3 = theme.header, BorderSizePixel = 0, Visible = false }, row)
      create("UIListLayout", { Padding = UDim.new(0, 2) }, menu)
      local buttons = {}
      local function contains(v, target) for _, item in ipairs(type(v) == "table" and v or {}) do if item == target then return true end end; return false end
      if value == nil then value = kind == "multiselect" and {} or choices[1] end
      render = function()
        if kind == "multiselect" then b.Text = type(value) == "table" and table.concat(value, ", ") or "None" else b.Text = tostring(value or choices[1]) end
        for i, choice in ipairs(choices) do buttons[i].BackgroundColor3 = (kind == "multiselect" and contains(value, choice) or value == choice) and theme.accent or theme.card end
      end
      for i, choice in ipairs(choices) do
        local item = button(menu, tostring(choice), UDim2.new(1, 0, 0, 30)); buttons[i] = item
        watch(item.Activated, function()
          if kind == "multiselect" then
            local nextValue = {}; local has = contains(value, choice)
            for _, existing in ipairs(type(value) == "table" and value or {}) do if existing ~= choice then nextValue[#nextValue + 1] = existing end end
            if not has then nextValue[#nextValue + 1] = choice end; set(nextValue, true)
          else set(choice, true); menu.Visible = false; row.Size = UDim2.new(1, -6, 0, 54) end
        end)
      end
      function handle.set(v, notify)
        if kind == "dropdown" then local valid = false; for _, choice in ipairs(choices) do if choice == v then valid = true end end; if not valid then return false end end
        if kind == "multiselect" and type(v) ~= "table" then return false end
        return set(v, notify == true)
      end
      watch(b.Activated, function() menu.Visible = not menu.Visible; row.Size = UDim2.new(1, -6, 0, menu.Visible and 52 + #choices * 32 or 54) end)
    elseif kind == "keybind" then
      local b = button(row, "", UDim2.fromOffset(90, 30)); b.Position = UDim2.new(1, -100, 0, 6); label.Size = UDim2.new(1, -110, 0, 24)
      render = function() b.Text = keyName(value) end
      watch(b.Activated, function() capturing = { handle = handle, button = b }; b.Text = "..." end)
    elseif kind == "color" then
      function handle.set(v, notify) if typeof(v) ~= "Color3" then return false end; return set(v, notify == true) end
      local boxes = {}; label.Size = UDim2.new(0.4, -10, 0, 24)
      render = function()
        if typeof(value) ~= "Color3" then value = Color3.new(1, 1, 1) end
        for i, channel in ipairs({ value.R, value.G, value.B }) do boxes[i].Text = tostring(math.floor(channel * 255 + 0.5)) end
      end
      for i = 1, 3 do
        local box = create("TextBox", { Size = UDim2.new(0.19, -3, 0, 30), Position = UDim2.new(0.4 + (i - 1) * 0.19, 0, 0, 6), BackgroundColor3 = theme.header, BorderSizePixel = 0, TextColor3 = theme.text, Font = Enum.Font.Gotham, TextSize = 12, Text = "", ClearTextOnFocus = false }, row); round(box, 4); boxes[i] = box
        watch(box.FocusLost, function()
          local r, g, b = tonumber(boxes[1].Text), tonumber(boxes[2].Text), tonumber(boxes[3].Text)
          if not finite(r) or not finite(g) or not finite(b) then render(); return end
          set(Color3.fromRGB(clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255)), true)
        end)
      end
    else error("unknown UI component: " .. tostring(kind)) end
    render(); return handle
  end

  -- floating-controls
  function api.floating(d)
    assert(d.id and not handles[d.id], "unique floating id required")
    local b = button(gui, d.title or "", UDim2.fromOffset(d.width or 54, d.height or 44)); b.Name = d.id; b.Position = d.position or UDim2.fromOffset(12, 100); b.Visible = d.visible ~= false
    local value = d.value == true; local moved = draggable(b, b, d.onMove)
    local handle = { instance = b, floating = true }
    function handle.set(v, notify)
      local previous = value; value = v == true; b.BackgroundColor3 = value and theme.accent or theme.card
      if notify and not call(d.onChange, value) then value = previous; b.BackgroundColor3 = value and theme.accent or theme.card; return false end
      return true
    end
    function handle.get() return value end
    function handle.setVisible(v) b.Visible = v == true end
    function handle.setTitle(v) b.Text = tostring(v) end
    watch(b.Activated, function() if moved() then return end; if d.onClick then call(d.onClick) else handle.set(not value, true) end end)
    handle.set(value, false); handles[d.id] = handle; return handle
  end
  function api.overlay(d)
    assert(d.id and not handles[d.id], "unique overlay id required")
    local label = create("TextLabel", { Name = d.id, Size = UDim2.fromOffset(d.width or 250, d.height or 80), Position = d.position or UDim2.fromOffset(12, 20), BackgroundColor3 = theme.header, BackgroundTransparency = 0.15, TextColor3 = theme.text, Font = Enum.Font.GothamSemibold, TextSize = 12, TextWrapped = true, Text = d.text or "", Visible = d.visible ~= false }, gui); round(label)
    local handle = { instance = label }
    function handle.set(v) label.Text = tostring(v or ""); return true end
    function handle.get() return label.Text end
    function handle.setVisible(v) label.Visible = v == true end
    handles[d.id] = handle; return handle
  end
  watch(input.InputBegan, function(event, processed)
    if capturing then
      local capture = capturing; capturing = nil
      if event.KeyCode == Enum.KeyCode.Escape then capture.handle.set(capture.handle.get(), false); return end
      local key = event.UserInputType == Enum.UserInputType.Keyboard and event.KeyCode or event.UserInputType
      if key == Enum.UserInputType.MouseButton1 or key == Enum.UserInputType.MouseButton2 or event.UserInputType == Enum.UserInputType.Keyboard then capture.handle.set(key, true) else capture.handle.set(capture.handle.get(), false) end
      return
    end
    if processed or input:GetFocusedTextBox() then return end
    for _, binding in pairs(bindings) do if event.KeyCode == binding.key or event.UserInputType == binding.key then call(binding.callback) end end
  end)
  watch(input.InputEnded, function(event)
    for _, binding in pairs(bindings) do if binding.release and (event.KeyCode == binding.key or event.UserInputType == binding.key) then call(binding.release) end end
  end)
  watch(input.WindowFocusReleased, function() for _, binding in pairs(bindings) do if binding.release then call(binding.release) end end end)
  watch(run.Heartbeat, function(dt)
    elapsed = elapsed + dt
    if elapsed >= 0.25 then elapsed = 0; responsive() end
    if options.onUpdate then call(options.onUpdate, dt, api) end
  end)
  if options.launcher ~= false then
    local launch = api.floating({ id = "__launcher", title = options.icon or "≡", position = options.launcherPosition or UDim2.fromOffset(14, 80), onMove = options.onLauncherMove, onClick = api.toggle })
    launch.instance.Visible = true
  end
  for _, p in ipairs(options.pages or {}) do local page = api.page(p.id, p.title); for _, d in ipairs(p.components or {}) do page.add(d) end end
  responsive(); windows[api] = true
  api.gui, api.panel = gui, panel; return api
end

-- module-lifecycle
function UI.setup() return true end
function UI.teardown() local active = {}; for window in pairs(windows) do active[#active + 1] = window end; for _, window in ipairs(active) do window.destroy() end; return true end
UI.__contract = { requires = {}, provides = { "new", "setup", "teardown" } }
return UI
