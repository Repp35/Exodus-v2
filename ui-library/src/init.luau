local Context = require(script.core.Context)
local Store = require(script.core.Store)
local Theme = require(script.core.Theme)
local Window = require(script.Window)
local Actions = require(script.components.Actions)
local Fields = require(script.components.Fields)
local Choice = require(script.components.Choice)
local Display = require(script.components.Display)
local Data = require(script.components.Data)
local Layout = require(script.components.Layout)
local Overlay = require(script.components.Overlay)
local Floating = require(script.components.Floating)
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
    assert(
      type(name) == "string" and type(factory) == "function" and not registry[name],
      "Invalid or duplicate component"
    )
    registry[name] = factory
  end
  function ctx:Component(kind, parent, props)
    assert(registry[kind], "Unknown component: " .. tostring(kind))
    return registry[kind](self, parent, props or {})
  end
  function ctx:Window(props)
    return Window.new(self, props)
  end
  function ctx:Notify(props)
    return Overlay.Notify(self, props)
  end
  function ctx:Dialog(props)
    return Overlay.Dialog(self, props)
  end
  function ctx:Tooltip(anchor, props)
    return Overlay.Tooltip(self, anchor, props)
  end
  function ctx:FloatingButton(props)
    return Floating.Button(self, props or {})
  end
  return ctx
end
-- Optional host capability declaration; no host dependencies.
Library.__contract = { provides = { "new" }, data = { "Theme", "Store" }, requires = {} }
return Library
