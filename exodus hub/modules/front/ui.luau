-- [[ ui ]]

-- module
local ExodusUI = {}
local active

-- configuration
local CONFIG = {}

-- public-components
local Components = {}
for _, name in ipairs({
  "label",
  "button",
  "textInput",
  "number",
  "toggle",
  "divider",
  "progressBar",
  "dropdown",
  "slider",
  "segmented",
  "tabs",
  "rate_selector",
}) do
  Components[name] = function(parent, options)
    assert(active and active.kit and active.scope.alive, "Call ExodusUI.setup before creating components, or use UIKit.create for a standalone library")
    return active.kit.Components[name](parent, options)
  end
end
ExodusUI.Components = Components

-- composition
function ExodusUI.setup(deps, preview)
  if type(deps) ~= "table" or type(deps.Controls) ~= "table" then return false, "missing UI dependencies" end
  for alias in pairs(ExodusUI.__contract.requires) do
    if type(deps[alias]) ~= "table" then return false, "missing UI dependency: " .. alias end
  end
  for alias, methods in pairs(ExodusUI.__contract.requiresMethods) do
    for _, method in ipairs(methods) do
      if type(deps[alias][method]) ~= "function" then return false, "missing UI method: " .. alias .. "." .. method end
    end
  end
  if type(_G.ExodusUICleanup) == "function" then
    if not preview and type(_G.ExodusUIFadeOut) == "function" then pcall(_G.ExodusUIFadeOut) end
    _G.ExodusUICleanup()
  else
    local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui"); local old = playerGui:FindFirstChild("ExodusUISystem")
    if old then old:Destroy() end
  end
  local context = deps.Context.create(deps); active = context
  context.notifications = deps.Notifications.create(context); context.notifications.layer()
  context.floating = deps.Floating.create(context); context.window = deps.Window.create(context)
  deps.Telemetry.create(context); context.lifecycle = deps.Lifecycle.create(context)
  local function cleanup()
    context.destroy()
    if _G.ExodusUICleanup == cleanup then
      _G.ExodusUICleanup, _G.ExodusUIFadeOut, _G.ExodusUIRestore = nil, nil, nil; _G.ExodusShowPersistentNotification, _G.ExodusClearPersistentNotification = nil, nil
    end
  end
  _G.ExodusUICleanup = cleanup; _G.ExodusUIFadeOut = context.lifecycle.fade
  _G.ExodusUIRestore = context.lifecycle.restore; _G.ExodusShowPersistentNotification = context.notifications.persistent
  _G.ExodusClearPersistentNotification = context.notifications.clear; local rebuildQueued = false
  local function rebuild(reset)
    if rebuildQueued then return end
    rebuildQueued = true; local owner = context.refs.screenGui
    local wasOpen, snapshot = context.state.panelOpen, context.pages.snapshot()
    task.defer(function()
      if not context.scope.alive or not owner.Parent or context.state.closing then return end
      local ok, reason = ExodusUI.setup(deps, { snapshot = not reset and snapshot or nil, open = wasOpen })
      if not ok then warn("[Exodus] Falha ao atualizar interface: " .. tostring(reason)) end
    end)
  end
  context.actions = deps.UIActions.create({
    scope = context.kit.scope,
    controls = deps.Controls,
    desktop = context.state.desktop,
    notify = context.notifications.toast,
    persistent = context.notifications.persistent,
    setSpam = context.floating.setSpam,
    showMini = context.floating.showMini,
    rebuild = rebuild,
    abilitiesEnabled = deps.GameInfo.areAbilitiesEnabled,
  })
  context.pages = deps.UIPages.create(context.kit, context.refs.configPanel, deps.UIConfig.pages, {
    desktop = context.state.desktop,
    read = deps.Utils.getConfigValue,
    resolve = context.actions.resolve,
    onComponent = context.actions.attach,
    abilitiesEnabled = deps.GameInfo.areAbilitiesEnabled,
    onNavigate = context.window.updateNavigation,
  })
  context.floating.refreshAbilities(); deps.Input.create(context)
  if preview and preview.snapshot then context.pages.restore(preview.snapshot) end
  context.scope.add(deps.Utils.observeSpam(function()
    local manual = deps.Utils.isManualSpamActive()
    if context.state.spamOn ~= manual then context.floating.setSpam(manual) end
    context.actions.refreshManual()
  end))
  context.scope.add(deps.Utils.observeConfig(function(changes)
    context.floating.sync(changes); context.actions.refreshManual()
    if changes.ForcePCUI ~= nil then rebuild() end
  end))
  local function refreshDevice()
    local input = context.services.UIS; local desktop = deps.Utils.getConfigValue("ForcePCUI") == true or input.KeyboardEnabled or input.MouseEnabled or not input.TouchEnabled
    if desktop ~= context.state.desktop and not context.state.closing then rebuild() end
  end
  for _, property in ipairs({ "KeyboardEnabled", "MouseEnabled", "TouchEnabled" }) do
    context.scope.connect(context.services.UIS:GetPropertyChangedSignal(property), refreshDevice)
  end
  _G.ExodusUIReturnAfterUpdate = nil
  if preview and preview.open then context.window.toggle() end
  return true
end

-- contract
ExodusUI.__contract = {
  requires = {
    Utils = "utils",
    UIConfig = "uiconfig",
    GameInfo = "gameinfo",
    AutoSpam = "autospam",
    UIKit = "uikit",
    UIPages = "uipages",
    UIActions = "uiactions",
    NotificationPolicy = "uinotifications",
    Runtime = "uiruntime",
    Theme = "uitheme",
    Context = "uicontext",
    Window = "uiwindow",
    Floating = "uifloating",
    Notifications = "uinotificationview",
    Telemetry = "uitelemetry",
    Input = "uiinput",
    Lifecycle = "uilifecycle",
  },
  requiresMethods = {
    Utils = {
      "getConfig",
      "getConfigValue",
      "getLocalPlayer",
      "isActive",
      "isManualSpamActive",
      "setConfig",
      "resetConfig",
      "setManualSpamActive",
      "normalizeSpamRate",
      "observeConfig",
      "observeSpam",
      "recordError",
      "stop",
      "name",
      "version",
      "author",
    },
    GameInfo = {
      "areAbilitiesEnabled",
      "observeAbilityMode",
      "getSnapshotAt",
      "isSnapshotValid",
    },
    AutoSpam = { "getStatus" },
    UIKit = { "create" },
    UIPages = { "create" },
    UIActions = { "create" },
    NotificationPolicy = { "shouldShow" },
    Runtime = { "scope", "motion" },
    Context = { "create" },
    Window = { "create" },
    Floating = { "create" },
    Notifications = { "create" },
    Telemetry = { "create" },
    Input = { "create" },
    Lifecycle = { "create" },
  },
  requiresData = { UIConfig = { "pages" }, Theme = { "tokens" } },
  data = { "Components" },
  provides = { "setup" },
}

return ExodusUI
