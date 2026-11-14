local passed = 0
local function check(condition, message)
  assert(condition, message)
  passed += 1
end
local function eq(actual, expected, message) check(actual == expected, message or (tostring(actual) .. " ~= " .. tostring(expected))) end
local errors = {}
local function onError(err) table.insert(errors, err) end
local signal = Signal.new(onError)
local calls = {}
local second
signal:Connect(function()
  table.insert(calls, 1)
  second:Disconnect()
  signal:Connect(function() table.insert(calls, 3) end)
end)
second = signal:Connect(function() table.insert(calls, 2) end)
signal:Fire()
eq(#calls, 1, "Disconnect during dispatch")
signal:Fire()
eq(#calls, 3, "New listener waits until next dispatch")
signal:Destroy()
signal:Fire()
eq(#calls, 3)
local scope = Scope.new(onError)
local disposed = 0
local child = scope:Child()
child:Add(function()
  disposed += 1
end)
child:Destroy()
eq(Mock.countResources(scope), 0, "Child removed from parent")
scope:Destroy()
scope:Destroy()
eq(disposed, 1, "Idempotent disposal")
local store = Store.new({
  values = { a = false, count = 2 },
  validate = function(key, value) return key ~= "count" or value >= 0, "negative" end,
})
local updates = 0
store.Changed:Connect(function()
  updates += 1
end)
check(not store:Patch({ a = true, count = -1 }), "Reject invalid transaction")
eq(store:Get("a"), false)
eq(updates, 0)
check(store:Set("count", 4))
eq(updates, 1)
store:Set("count", 4)
eq(updates, 1, "No-op update")
local rejected = Store.new({
  values = { a = 1 },
  write = function() return false, "rejected" end,
})
check(not rejected:Set("a", 2))
eq(rejected:Get("a"), 1)
local cyclicWrite
cyclicWrite = Store.new({
  values = { a = 1 },
  write = function(patch)
    cyclicWrite:Patch(patch, true)
    return true
  end,
})
local commits = 0
cyclicWrite.Changed:Connect(function()
  commits += 1
end)
cyclicWrite:Set("a", 2)
eq(commits, 1, "Synchronous host echoes produce one update")
local liveBefore = Mock.live()
local ctx = Library.new({ values = { enabled = false }, onError = onError })
local window = ctx:Window({ title = "Test" })
local main = window:Page({ id = "main", title = "Main" })
local other = window:Page({ id = "other" })
local section = main:Section({ title = "Controls" })
-- Regression checks for the original visual grammar and the requested navigation.
eq(window.root.Size.X.Offset, 600, "Bounded window width")
eq(window.root.Size.Y.Offset, 400, "Bounded window height")
check(window.root.BackgroundTransparency > 0, "Window remains translucent")
check(window.nav.Position.X.Offset < window.body.Position.X.Offset, "Navigation stays on the left")
eq(#main.columns, 1, "Page content is one vertical flow")
check(main.columns[1].root.ScrollingEnabled, "Page scrolls vertically")
eq(main.columns[1].layout.FillDirection, Enum.FillDirection.Vertical)
local changed = 0
local toggle = section:Add("Toggle", {
  key = "enabled",
  title = "Enabled",
  onChange = function()
    changed += 1
  end,
})
eq(toggle.root.Size.Y.Offset, 48, "Toggle uses one compact row")
eq(toggle.content.Size.Y.Offset, 30)
eq(toggle.track.Size.X.Offset, 48)
eq(toggle.track.Size.Y.Offset, 30)
eq(toggle.track:FindFirstChildOfClass("UICorner").CornerRadius.Offset, 999, "Switch remains pill shaped")
check(toggle.root.BackgroundTransparency > 0)
eq(toggle.root:FindFirstChildOfClass("UICorner").CornerRadius.Offset, 12)
toggle.button.Activated:Fire()
eq(ctx.store:Get("enabled"), true)
eq(changed, 1, "Bound callback runs once")
ctx.store:Set("enabled", false)
eq(toggle:GetValue(), false)
eq(changed, 1, "External writes do not trigger callbacks")
toggle:SetDisabled(true)
toggle.button.Activated:Fire()
eq(toggle:GetValue(), false)
toggle:SetDisabled(false)
local slider = section:Add("Slider", { title = "Ratio", min = 0, max = 1, step = 0.1, value = 0.4 })
slider:SetValue(99)
eq(slider:GetValue(), 1)
check(not slider:SetValue(0 / 0))
eq(slider:GetValue(), 1)
local number = section:Add("NumberInput", { min = 0, max = 5, value = 2, step = 0.25 })
number:SetValue(2.37)
eq(number:GetValue(), 2.25)
number.input.Text = "nan"
number.input.FocusLost:Fire()
eq(number:GetValue(), 2.25)
local input = section:Add("Input", { maxLength = 3, value = "abc" })
check(not input:SetValue("long"))
local segmented = section:Add("Segmented", { options = { "a", "b" } })
check(not segmented:SetValue("c"))
eq(segmented:GetValue(), "a")
local dropdown = section:Add("Dropdown", { options = { "a", "b" }, searchable = true })
local popup, popupScope = ctx:Popup(dropdown.scope, toggle.button, 200)
check(ctx.popup == popupScope)
ctx:ClosePopup()
check(popupScope.destroyed)
local multi = section:Add("MultiSelect", { options = { "a", "b" }, value = { "a" } })
check(not multi:SetValue({ "a", "a" }))
check(multi:SetValue({ "b" }))
local radio = section:Add("RadioGroup", { options = { "a", "b" } })
eq(radio:GetValue(), "a")
local color = section:Add("ColorPicker", { value = Color3.fromRGB(99, 102, 241) })
eq(color:GetValue():ToHex(), "6366F1")
local triggers = 0
local keybind = section:Add("Keybind", {
  value = Enum.KeyCode.K,
  onTrigger = function(down)
    triggers += down and 1 or -1
  end,
  hold = true,
})
local key = Mock.fire(ctx, Enum.KeyCode.K)
eq(triggers, 1)
ctx.InputEnded:Fire(nil)
eq(triggers, 0, "Lost focus releases held action")
local captured
local captureOwner = ctx.scope:Child()
ctx:Capture(captureOwner, function(value) captured = value end)
Mock.services.UserInputService.InputBegan:Fire(Mock.input(Enum.KeyCode.P), false)
eq(captured, Enum.KeyCode.P)
local ownerCount = Mock.countResources(captureOwner)
for _ = 1, 100 do
  ctx:Capture(captureOwner, function() end)
end
eq(Mock.countResources(captureOwner), ownerCount, "Repeated rebind does not accumulate resources")
captureOwner:Destroy()
eq(ctx.capture, nil)
for _, kind in ipairs({
  "Label",
  "Badge",
  "Alert",
  "Progress",
  "Separator",
  "Stat",
  "Image",
  "Skeleton",
  "EmptyState",
}) do
  section:Add(kind, { title = kind })
end
local stack = other:Add("Stack", {})
stack:Add("Label", { text = "Nested" })
local grid = other:Add("Grid", {})
grid:Add("Toggle", {})
local accordion = other:Add("Accordion", { title = "Fold" })
accordion:Add("Label", {})
accordion:SetValue(false)
eq(accordion.content.Visible, false)
check(accordion.content.Position.Y.Offset >= accordion.root:FindFirstChildOfClass("TextButton").Size.Y.Offset, "Accordion content clears its header")
local card = other:Add("Card", { title = "Card" })
card:Add("Button", { onClick = function() end })
window:SelectPage("other")
eq(main.root.Visible, false)
eq(other.root.Visible, true)
other:Destroy()
eq(window.active, "main")
ctx:SetTheme({ colors = { accent = Color3.fromRGB(255, 0, 0) } })
eq(ctx.theme.colors.accent:ToHex(), "FF0000")
check(not pcall(function() ctx:SetTheme({ colors = { typo = Color3.new(0, 0, 0) } }) end), "Unknown token rejected")
local notify = ctx:Notify({ id = "one", message = "First", duration = 0 })
local replacement = ctx:Notify({ id = "one", message = "Second", duration = 0 })
check(notify.scope.destroyed)
eq(#ctx.notificationOrder, 1)
replacement:Destroy()
eq(#ctx.notificationOrder, 0)
local mode =
  section:Add("UnitInput", { title = "Rate", key = "mode", options = { { value = "A", key = "number", label = "A" }, { value = "B", label = "Automatic" } } })
ctx.store:Set("number", 12)
eq(mode.input.Text, "12")
mode:SetValue("B")
eq(mode.input.TextEditable, false)
mode:SetValue("A")
mode.input.Text = "24"
mode.input.FocusLost:Fire()
eq(ctx.store:Get("number"), 24)
local circle = ctx:FloatingButton({ width = 64, height = 64 })
eq(circle.root.Size.X.Offset, circle.root.Size.Y.Offset)
eq(circle.button:FindFirstChildOfClass("UICorner").CornerRadius.Offset, 999, "Floating actions remain circular")
local mini = ctx:FloatingButton({ shape = "mini", title = "Action", text = "OFF", width = 112, height = 96 })
eq(mini.root.Size.X.Offset, 112)
eq(mini.root.Size.Y.Offset, 96)
check(mini.root.BackgroundTransparency > 0)
eq(mini.button.Position.Y.Offset, 22, "Mini panel has a separate drag header")
eq(mini.button:FindFirstChildOfClass("UICorner").CornerRadius.Offset, 10)
mini:SetTone("success")
eq(mini.button.BackgroundColor3, ctx.theme.colors.success)
local readout = ctx:Component("Readout", ctx.root, { text = "Initial" })
readout:SetText("Updated")
eq(readout.label.Text, "Updated")
eq(readout.root.AutomaticSize, Enum.AutomaticSize.XY)
local held = false
local floating = ctx:FloatingButton({
  onHold = function(down) held = down end,
})
floating.button.InputBegan:Fire({ UserInputType = Enum.UserInputType.MouseButton1 })
check(held)
floating:SetVisible(false)
eq(held, false)
local dialog = ctx:Dialog({ title = "Dialog" })
check(ctx.modal == dialog)
Mock.fire(ctx, Enum.KeyCode.K)
eq(triggers, 0, "Modal blocks shortcuts")
dialog:Destroy()
eq(ctx.modal, nil)
local checkbox = section:Add("Checkbox", { value = false, size = "small" })
checkbox.button.Activated:Fire()
eq(checkbox:GetValue(), true)
eq(checkbox.content.Size.Y.Offset, 26, "Small size token")
local textarea = section:Add("TextArea", { value = "Notes", maxLength = 5 })
local areaPosition = textarea.content.Position.Y.Offset
check(not textarea:SetValue("Too long"))
check(textarea:SetValue("OK"))
eq(textarea.content.Position.Y.Offset, areaPosition, "Validation preserves custom content geometry")
local radioPosition = radio.content.Position.Y.Offset
radio:SetValue("b")
eq(radio.content.Position.Y.Offset, radioPosition, "Radio remains aligned after update")
local tabs = main:Add("Tabs", {})
tabs:Tab({ id = "a" }):Add("Label", { text = "A" })
tabs:Tab({ id = "b" }):Add("Label", { text = "B" })
tabs:SelectTab("b")
eq(tabs.active, "b")
local data = main:Add("Table", {
  columns = { { key = "name" }, { key = "count" } },
  value = { { name = "B", count = 2 }, { name = "A", count = 1 } },
})
data:Sort("count", true)
data:SetFilter("A")
local dataResources = Mock.countResources(data.scope)
for _ = 1, 100 do
  data:SetFilter("B")
  data:Sort("name", false)
end
eq(Mock.countResources(data.scope), dataResources, "Table rebuild replaces owned rows")
local dataCopy = data:GetValue()
dataCopy[1].name = "Changed"
eq(data:GetValue()[1].name, "B", "Returned values are snapshots")
dropdown.content:FindFirstChildOfClass("TextButton").Activated:Fire()
check(ctx.popup ~= nil)
dropdown:SetDisabled(true)
eq(ctx.popup, nil, "Disabling dropdown dismisses its active menu")
dropdown:SetDisabled(false)
local dropdownResources = Mock.countResources(dropdown.scope)
for _ = 1, 50 do
  dropdown.content:FindFirstChildOfClass("TextButton").Activated:Fire()
  check(ctx.popup ~= nil)
  ctx:ClosePopup()
end
eq(Mock.countResources(dropdown.scope), dropdownResources, "Popup interactions do not accumulate resources")
for _, bounds in ipairs({ Vector2.new(320, 568), Vector2.new(568, 320), Vector2.new(1024, 768) }) do
  ctx.root._size = bounds
  ctx.root:GetPropertyChangedSignal("AbsoluteSize"):Fire()
  check(window.root.Size.X.Offset <= bounds.X - 24, "Window fits viewport width")
  check(window.root.Size.Y.Offset <= bounds.Y - 24, "Window fits viewport height")
  eq(window.navLayout.FillDirection, Enum.FillDirection.Vertical)
end
local external = Library.new({ onError = onError })
external.gui:Destroy()
check(external.scope.destroyed, "Externally destroyed ScreenGui releases its scope")
local timed = ctx:Notify({ message = "Timer" })
check(Mock.pending() > 0)
ctx:Destroy()
ctx:Destroy()
eq(Mock.pending(), 0, "All timers cancelled")
eq(Mock.live(), liveBefore, "All UI instances destroyed")
eq(#errors, 0, table.concat(errors, "\n"))
print(string.format("PASS · %d assertions · state, controls, overlays, keyboard, ownership", passed))
-- Real host contract + full adapter mounting (no game actions executed).
local configValues = UIConfig.__config.defaults
local configChanged = Signal.new(onError)
local spamChanged = Signal.new(onError)
local activeManual = false
local hostErrors = {}
local utils = {
  getConfig = function() return table.clone(configValues) end,
  getLocalPlayer = function() return Mock.services.Players.LocalPlayer end,
  isActive = function() return true end,
  isManualSpamActive = function() return activeManual end,
  setConfig = function(patch)
    for k, v in pairs(patch) do
      configValues[k] = v
    end
    configChanged:Fire(patch)
    return true
  end,
  resetConfig = function() return true end,
  setManualSpamActive = function(value)
    activeManual = value
    spamChanged:Fire()
  end,
  observeConfig = function(callback) return configChanged:Connect(callback) end,
  observeSpam = function(callback) return spamChanged:Connect(callback) end,
  recordError = function(_, message) table.insert(hostErrors, message) end,
  name = function() return "Exodus" end,
  version = function() return "2" end,
  author = function() return "Author" end,
}
local gameInfo = {
  areAbilitiesEnabled = function() return true end,
  observeAbilityMode = function(callback) return Signal.new(onError):Connect(callback) end,
  getSnapshotAt = function() return {} end,
  isSnapshotValid = function() return false end,
  createCrateNetwork = function() return {} end,
  spinCrate = function() return false end,
}
local modules = {
  uilibrary = Library,
  ui = Adapter,
  utils = utils,
  gameinfo = gameInfo,
  uiconfig = UIConfig,
  autospam = {
    getStatus = function() return {} end,
  },
  dumper = {
    start = function() return true end,
    isRunning = function() return false end,
  },
}
for name, module in pairs(modules) do
  if not module.__contract then
    local methods = {}
    for method in pairs(module) do
      table.insert(methods, method)
    end
    module.__contract = { provides = methods }
  end
  Permissions.validate(name, module)
end
local dependencies = Permissions.resolve("ui", modules)
dependencies.Controls = {}
local beforeAdapter = Mock.live()
local success, errorMessage = Adapter.setup(dependencies)
check(success, errorMessage)
check(type(_G.ExodusUICleanup) == "function")
_G.ExodusShowPersistentNotification("Test", "test", "info", 0)
_G.ExodusClearPersistentNotification("test")
_G.ExodusUIFadeOut()
_G.ExodusUIRestore()
local secondSuccess, secondError = Adapter.setup(dependencies, { page = "hub" })
check(secondSuccess, secondError)
_G.ExodusUICleanup()
eq(Mock.pending(), 0, "Adapter timers cancelled after remount")
eq(Mock.live(), beforeAdapter, "Adapter has no remaining UI instances")
eq(#hostErrors, 0, table.concat(hostErrors, "\n"))
eq(_G.ExodusUICleanup, nil, "Host compatibility hooks removed")
print("PASS · full Exodus adapter mounts through actual permission views and cleans up after remount")
print(string.format("PASS · %d total assertions", passed))
