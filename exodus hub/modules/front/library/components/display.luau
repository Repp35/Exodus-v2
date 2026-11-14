-- [[ display ]]

-- module
local Components = {}

-- configuration
local CONFIG = {}

-- setup
function Components.setup() return true end

-- components
function Components.install(context)
  local kit = context.kit; local components = context.components
  local C = context.C; local TEXT = context.TEXT
  local inst = context.inst; local text = context.text
  local control = context.control; local title = context.title
  local bind = context.bind; local read = context.read
  local finite = context.finite
  function components.label(parent, definition)
    definition = definition or {}; definition = table.clone(definition)
    definition.kind = "label"; local handle = control(parent, definition, 24)
    handle.Root.BackgroundTransparency = 1; local outline = handle.Root:FindFirstChildOfClass("UIStroke")
    if outline then outline:Destroy() end
    local label = text(handle.Root, definition.title or definition.text, { Size = UDim2.fromScale(1, 1), TextSize = TEXT.caption, TextColor3 = C.accent })
    function handle.setText(value) label.Text = tostring(value) end
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
end

-- contract
Components.__contract = { provides = { "setup", "install" }, requires = {} }

return Components
