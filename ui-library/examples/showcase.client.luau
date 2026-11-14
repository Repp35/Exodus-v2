-- Run as a LocalScript with UILibrary in ReplicatedStorage (Rojo project included).
local Library = require(game:GetService("ReplicatedStorage"):WaitForChild("UILibrary"))
local ui = Library.new({ values = { enabled = true, volume = 0.6 } })
local window = ui:Window({ title = "UI Library", subtitle = "Independent component showcase" })
local forms = window:Page({ id = "forms", title = "Forms" })
local controls = forms:Section({ title = "Consistent controls" })
controls:Add("Toggle", { title = "Enable feature", key = "enabled" })
controls:Add("Checkbox", { title = "Agreement", text = "I agree" })
controls:Add("Slider", { title = "Volume", key = "volume", min = 0, max = 1, step = 0.05 })
controls:Add("Input", { title = "Name", placeholder = "Your name", maxLength = 40 })
controls:Add("TextArea", { title = "Notes", placeholder = "Write something…" })
controls:Add("NumberInput", { title = "Amount", value = 8, min = 0, max = 20, step = 1 })
controls:Add(
  "Dropdown",
  { title = "Mode", options = { "Automatic", "Manual", "Scheduled" }, searchable = true }
)
controls:Add(
  "MultiSelect",
  { title = "Channels", options = { "Updates", "Messages", "Alerts" }, value = { "Updates" } }
)
controls:Add("Segmented", { title = "Quality", options = { "Low", "Medium", "High" } })
controls:Add("RadioGroup", { title = "Visibility", options = { "Private", "Team", "Public" } })
controls:Add("ColorPicker", {
  title = "Accent",
  value = ui.theme.colors.accent,
  onChange = function(color)
    ui:SetTheme({ colors = { accent = color } })
  end,
})
controls:Add("Keybind", {
  title = "Open window",
  value = Enum.KeyCode.RightShift,
  onTrigger = function()
    window:Toggle()
  end,
})
local system = window:Page({ id = "system", title = "System" })
local feedback = system:Section({ title = "Feedback" })
for _, variant in ipairs({ "info", "success", "warning", "danger" }) do
  feedback:Add("Alert", {
    title = variant,
    description = "Shared spacing, typography, radius and semantic colors.",
    variant = variant,
  })
end
feedback:Add("Progress", { title = "Download", value = 0.65 })
feedback:Add("Stat", { title = "Active users", value = 1240 })
feedback:Add("Skeleton", {})
feedback:Add("EmptyState", {})
feedback:Add("Button", {
  title = "Notification",
  text = "Show toast",
  onClick = function()
    ui:Notify({ title = "Saved", message = "Your changes are ready.", variant = "success" })
  end,
})
feedback:Add("Button", {
  title = "Confirmation",
  text = "Open dialog",
  variant = "secondary",
  onClick = function()
    ui:Dialog({
      title = "Apply changes?",
      message = "This is an independent UI example.",
      onConfirm = function()
        ui:Notify({ message = "Applied" })
      end,
    })
  end,
})
feedback:Add("Toggle", {
  title = "Reduced motion",
  onChange = function(value)
    ui:SetReducedMotion(value)
  end,
})
local layouts = window:Page({ id = "layouts", title = "Layouts" })
local grid = layouts:Add("Grid", { columns = 2, cellHeight = 108 })
for index = 1, 4 do
  grid:Add("Stat", { title = "Metric " .. index, value = index * 10 })
end
local accordion = layouts:Add("Accordion", { title = "Expandable section", value = true })
accordion:Add("Label", { text = "Every child has an explicit lifetime." })
local tabs = layouts:Add("Tabs", {})
tabs:Tab({ id = "first", title = "First" }):Add("Label", { text = "First tab content" })
tabs:Tab({ id = "second", title = "Second" }):Add("Label", { text = "Second tab content" })
layouts:Add("Table", {
  columns = { { key = "name", title = "Name" }, { key = "score", title = "Score" } },
  value = { { name = "Alpha", score = 42 }, { name = "Beta", score = 18 } },
})
local launcher = ui:FloatingButton({
  text = "UI",
  position = UDim2.fromOffset(16, 100),
  onClick = function()
    window:Toggle()
  end,
})
ui:Tooltip(launcher.button, { text = "Open the component showcase" })
-- ui:Destroy() disposes the entire tree, subscriptions, tweens and pending timers.
