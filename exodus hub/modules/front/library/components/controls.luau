-- [[ controls ]]

-- module
local Components = {}

-- configuration
local CONFIG = {}

-- setup
function Components.setup() return true end

-- components
function Components.install(context)
  local kit = context.kit; local Theme = context.Theme
  local options = context.options; local components = context.components
  local C = context.C; local inst = context.inst
  local text = context.text; local control = context.control
  local title = context.title; local button = context.button
  local hitbox = context.hitbox; local commit = context.commit
  local shortcut = context.shortcut; local bind = context.bind
  local read = context.read
  function components.button(parent, definition)
    definition = definition or {}; local height = definition.description and Theme.CARD_H + 22 or Theme.CARD_H
    local handle = control(parent, definition, height); title(handle, definition, definition.shortcutKey and 64 or 0, height)
    function handle.activate()
      if not handle.enabled or kit.suspended then return false end
      if definition.onClick then return definition.onClick() ~= false end
      return true
    end
    hitbox(handle, handle.activate); shortcut(handle, definition.shortcutKey, -64)
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
    function handle.activate()
      if not handle.enabled or kit.suspended then return false end
      local current = value
      if definition.getState then current = definition.getState() end
      local requested = not current
      if commit(handle, definition, requested) then
        if definition.getState then handle.setValue(definition.getState()) else handle.setValue(requested) end
        if options.notify and definition.toast ~= false then options.notify(tostring(definition.title or definition.text or "Option") .. (handle.getValue() and " On" or " Off")) end
        return true
      end
      return false
    end
    hitbox(handle, handle.activate); shortcut(handle, definition.shortcutKey)
    if definition.getState then handle.setValue(definition.getState()) else handle.setValue(read(definition.key, definition.value)) end
    bind(handle, definition.key, handle.setValue); return handle
  end
end

-- contract
Components.__contract = { provides = { "setup", "install" }, requires = {} }

return Components
