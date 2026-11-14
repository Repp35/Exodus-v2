-- Standalone library extracted from the Exodus frontend.
-- No game modules are imported here. The host adapter is ui.luau.
-- local ui = Library.new({ parent = playerGui, values = {}, write = function(patch) ... end })
-- local page = ui:Window({ title = "Hub" }):Page({ id = "main", title = "Main" })
-- page:Section({ title = "Controls" }):Add("Toggle", { title = "Feature", key = "enabled" })
-- ui:Destroy() releases the tree, subscriptions, animations and timers.
local Context = require(script.Parent.core.Context)
local Store = require(script.Parent.core.Store)
local Theme = require(script.Parent.core.Theme)
local Window = require(script.Parent.Window)
local Actions = require(script.Parent.components.Actions)
local Fields = require(script.Parent.components.Fields)
local Choice = require(script.Parent.components.Choice)
local Display = require(script.Parent.components.Display)
local Data = require(script.Parent.components.Data)
local Layout = require(script.Parent.components.Layout)
local Overlay = require(script.Parent.components.Overlay)
local Floating = require(script.Parent.components.Floating)
local Library = {}
Library.version = "1.0.0"
Library.Theme = Theme
Library.Store = Store
function Library.new(options)
  local ctx = Context.new(options)
  local registry = {}
  for _, group in ipairs({ Actions, Fields, Choice, Display, Layout, Data }) do
    for name, factory in pairs(group) do
      registry[name] = factory
    end
  end
  function ctx:Register(name, factory)
    assert(type(name) == "string" and type(factory) == "function" and not registry[name], "Invalid or duplicate component")
    registry[name] = factory
  end
  function ctx:Component(kind, parent, props)
    assert(registry[kind], "Unknown component: " .. tostring(kind))
    return registry[kind](self, parent, props or {})
  end
  function ctx:Window(props) return Window.new(self, props) end
  function ctx:Notify(props) return Overlay.Notify(self, props) end
  function ctx:Dialog(props) return Overlay.Dialog(self, props) end
  function ctx:Tooltip(anchor, props) return Overlay.Tooltip(self, anchor, props) end
  function ctx:FloatingButton(props) return Floating.Button(self, props or {}) end
  return ctx
end
-- Optional host capability declaration; no host dependencies.
Library.__contract = { provides = { "new" }, data = { "Theme", "Store" }, requires = {} }
return Library
