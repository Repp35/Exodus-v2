-- [[ ui ]]

local UI = {}

-- configuration
local CONFIG = {
  WINDOW_WIDTH = 600,
  WINDOW_HEIGHT = 400,
  TELEMETRY_INTERVAL = 0.1,
  IDLE_INTERVAL = 0.5,
}

local current
function UI.setup(deps, preview)
  if type(deps) ~= "table" or not deps.Library or not deps.Utils or not deps.Controls then return false, "Missing UI dependencies" end
  local utils, controls, info, auto, dumper = deps.Utils, deps.Controls, deps.GameInfo, deps.AutoSpam, deps.Dumper; local old = current
  if old then old:Destroy() end
  if type(_G.ExodusUICleanup) == "function" then _G.ExodusUICleanup() end
  local ctx
  local ok, detail = xpcall(function()
    ctx = deps.Library.new({
      name = "ExodusUISystem",
      values = utils.getConfig(),
      write = utils.setConfig,
      onError = function(err) utils.recordError("UI", tostring(err)) end,
    })
    current = ctx
    local function get(key) return ctx.store:Get(key) end
    local function set(key, value)
      local accepted, reason = ctx.store:Set(key, value)
      if not accepted then ctx:Notify({ title = "Configuration", message = tostring(reason), variant = "danger" }) end
      return accepted
    end
    local function call(name, ...)
      if type(controls[name]) == "function" then return controls[name](...) end
    end
    local function desktop() return get("ForcePCUI") == true or ctx.input.KeyboardEnabled or ctx.input.MouseEnabled or not ctx.input.TouchEnabled end
    local function toast(text)
      if get(desktop() and "DesktopNotifications" or "MobileNotifications") then ctx:Notify({ title = utils.name(), message = text, duration = 2 }) end
    end
    local function manual(value) utils.setManualSpamActive(value == true) end
    local function toggle(key, callback)
      if set(key, not get(key)) then
        if callback then callback() end
        toast(key .. (get(key) and " On" or " Off"))
      end
    end
    local window = ctx:Window({
      id = "exodus",
      width = CONFIG.WINDOW_WIDTH,
      height = CONFIG.WINDOW_HEIGHT,
      title = utils.name() .. " | v" .. utils.version(),
      subtitle = "— " .. utils.author(),
      settingsPage = "hub",
      actions = {
        {
          text = "Reload",
          onClick = function(win)
            call("onReload", function(message)
              win:SetVisible(true); toast(tostring(message))
            end)
          end,
        },
        { text = "Close Script", variant = "destructive", onClick = function(win) win.options.onClose(win) end },
      },
      visible = preview ~= nil,
      onMove = function(position) ctx.store:Patch({ PanelX = position.X.Offset, PanelY = position.Y.Offset }) end,
      onClose = function()
        ctx:Dialog({
          title = "Close Exodus?",
          message = "The interface and active functions will stop.",
          variant = "danger",
          confirmText = "Close script",
          onConfirm = function() call("onClose") end,
        })
      end,
    })
    if type(get("PanelX")) == "number" and type(get("PanelY")) == "number" then
      window.root.AnchorPoint = Vector2.zero; window.root.Position = UDim2.fromOffset(get("PanelX"), get("PanelY"))
      window.responsive()
    end
    local launcher = ctx:FloatingButton({
      text = "E",
      textSize = 26,
      variant = "surface",
      shape = "circle",
      position = UDim2.fromOffset(get("BtnX") or 16, get("BtnY") or 180),
      onClick = function() window:Toggle() end,
      onMove = function(position) ctx.store:Patch({ BtnX = position.X.Offset, BtnY = position.Y.Offset }) end,
    })
    ctx.scope:Add(ctx.Events:Connect(function(event, _, visible)
      if event == "visibility" then launcher:SetSize(visible and 44 or 56, visible and 44 or 56); launcher.button.BackgroundTransparency = visible and 0.6 or 0.1 end
    end))
    ctx:Tooltip(launcher.button, { text = "Open or minimize " .. utils.name() .. ". Drag to reposition." }); local pages = {}
    for _, item in ipairs({
      { "main", "Main" },
      { "settings", "Settings" },
      { "utilities", "Utilities" },
      { "automatic", "Automatic" },
      { "indeed", "Indeed" },
      { "hub", "Hub" },
    }) do
      pages[item[1]] = window:Page({ id = item[1], title = item[2] })
    end
    local function bind(section, kind, props)
      props = table.clone(props); local component = section:Add(kind, props)
      if props.parentKey then
        local function refresh() component:SetDisabled(get(props.parentKey) ~= true) end
        ctx.scope:Add(ctx.store:Subscribe(props.parentKey, refresh)); refresh()
      end
      return component
    end
    local combat = pages.main:Section({ title = "Combat" })
    for _, definition in ipairs(deps.UIConfig.panelToggles) do
      if not definition.mobileOnly then
        local props = table.clone(definition); props.shortcutKey = props.key == "AutoParry" and "ParryKeybind" or (props.key == "AutoSpam" and "ClashKeybind" or nil)
        bind(combat, "Toggle", props)
      end
    end
    local rate = pages.main:Section({ title = "Spam" })
    bind(rate, "UnitInput", {
      title = "Spam Rate",
      key = "SpamRateMode",
      pill = true,
      options = {
        { value = "CPS", label = "CPS", key = "CPS", variant = "accent" },
        { value = "CPF", label = "CPF", key = "CPF", variant = "secondary" },
        { value = "MS", label = "MS", key = "MS", variant = "warning" },
        { value = "Auto", label = "Auto", variant = "info" },
      },
    })
    for _, definition in ipairs(deps.UIConfig.panelComponents) do
      if definition.kind == "dropdown" then bind(rate, "Dropdown", definition) end
    end
    local manualSection = pages.main:Section({ title = "Manual Spam" })
    local manualToggle = manualSection:Add(
      "Toggle",
      { title = "Manual Spam", variant = "status", shortcutKey = "SpamKeybind", value = utils.isManualSpamActive(), onChange = manual }
    )
    for _, definition in ipairs(deps.UIConfig.panelComponents) do
      if definition.kind == "segmented" then bind(manualSection, "Segmented", definition) end
    end
    local floating = pages.hub:Section({ title = "Floating controls" }); local visibilityControls = {}
    local function mobileControl(key, title)
      local c = bind(floating, "Toggle", { title = title, key = key }); visibilityControls[#visibilityControls + 1] = c
    end
    for _, item in ipairs({
      { "MiniSpamVisible", "Manual spam" },
      { "ParryBallVisible", "Parry" },
      { "ClashBallVisible", "Clash" },
      { "DarkBallVisible", "Dark" },
      { "JumpBallVisible", "Jump" },
      { "UpDashBallVisible", "Up dash" },
    }) do
      mobileControl(item[1], item[2])
    end
    for _, definition in ipairs(deps.UIConfig.panelComponents) do
      if definition.kind == "scroll" then
        local props = table.clone(definition); props.step = definition.increment
        bind(floating, "Slider", props)
      end
    end
    local shortcuts = pages.settings:Section({ title = "Shortcuts" })
    local bindings = {
      {
        "Keybind",
        "Stop functions",
        function()
          manual(false); call("onPanic")
        end,
      },
      {
        "SpamKeybind",
        "Manual spam",
        function(down)
          if get("ManualSpamMode") == "Hold" then manual(down) elseif down then manual(not utils.isManualSpamActive()) end
        end,
        true,
      },
      { "ParryKeybind", "Auto parry", function() toggle("AutoParry") end },
      { "ClashKeybind", "Auto spam", function() toggle("AutoSpam") end },
      { "DarkKeybind", "Auto dark", function() toggle("AutoDark", controls.onAutoDarkChanged) end },
      { "JumpKeybind", "Auto jump", function() toggle("AutoJump", controls.onAutoJumpChanged) end },
      { "UpDashKeybind", "Up dash", function() call("onUpDash") end },
    }

    for _, item in ipairs(bindings) do
      bind(shortcuts, "Keybind", { title = item[2], key = item[1] })
      ctx:BindKey(ctx.scope, function() return get(item[1]) end, function(down)
        if desktop() and (down or item[4]) then item[3](down) end
      end, item[4])
    end
    local tuning = pages.settings:Section({ title = "Tuning" })
    bind(tuning, "Slider", {
      title = "AP lead",
      description = "Factor applied to the parry timing window.",
      key = "AutoParryWindowFactor",
      min = 0,
      max = 0.35,
      step = 0.01,
      format = function(value) return string.format("%.0f%%", value * 100) end,
    })
    bind(tuning, "NumberInput", { title = "Camera sensitivity", key = "CameraSensitivity", min = 0, max = 100, step = 0.05 })
    local telemetry = pages.settings:Section({ title = "Telemetry overlays" })
    for _, item in ipairs({
      { "ClashDistanceVisible", "Clash distance" },
      { "ClashTravelTimeVisible", "Ball travel time" },
      { "ClashGateInfoVisible", "Auto spam gates" },
    }) do
      bind(telemetry, "Toggle", { key = item[1], title = item[2] })
    end
    local automatic = pages.automatic:Section({ title = "Automatic actions" }); local abilityControls = {}
    for _, item in ipairs({
      { "AutoDark", "Auto dark", "onAutoDarkChanged", true },
      { "AutoFierce", "Auto fierce", nil, true },
      { "AutoJump", "Auto jump", "onAutoJumpChanged" },
      { "AutoClashUpDash", "Auto dash (clash)", nil, true },
    }) do
      local c = bind(automatic, "Toggle", {
        title = item[2],
        key = item[1],
        onChange = function()
          if item[3] then call(item[3]) end
        end,
      })
      if item[4] then table.insert(abilityControls, c) end
    end
    local dash = automatic:Add("Button", { title = "Up dash", text = "Activate", onClick = function() call("onUpDash") end })
    table.insert(abilityControls, dash)
    for _, section in ipairs(deps.UIConfig.pages.indeed.sections) do
      local target = pages.indeed:Section({ title = section.title })
      for _, definition in ipairs(section.components) do
        local props = table.clone(definition)
        if props.kind == "click" then
          props.text = "Run"
          props.onClick = function(button)
            if dumper.isRunning() then toast("Dumper is already running"); return end
            button:SetLoading(true)
            local accepted, reason = dumper.start({
              onStatus = function(message)
                if not ctx.scope.destroyed then ctx:Notify({ id = "dumper", title = "Dumper", message = tostring(message), duration = 0 }) end
              end,
              onProgress = function(done, total)
                if not ctx.scope.destroyed then ctx:Notify({ id = "dumper", title = "Dumper", message = string.format("%d / %d scripts", done, total), duration = 0 }) end
              end,
              onComplete = function(result)
                if ctx.scope.destroyed then return end
                button:SetLoading(false)
                ctx:Notify({
                  id = "dumper",
                  title = "Dumper",
                  message = type(result) == "table" and tostring(result.folder or result.path or "Dump completed") or tostring(result),
                  variant = "success",
                })
              end,
              onError = function(message)
                if ctx.scope.destroyed then return end
                button:SetLoading(false); ctx:Notify({ id = "dumper", title = "Dumper", message = tostring(message), variant = "danger" })
              end,
            })
            if not accepted then button:SetLoading(false); button:SetError(tostring(reason)) end
          end
          bind(target, "Button", props)
        else
          props.step = props.increment
          props.onChange = function(value) call(props.kind == "toggle" and "onUniversalToggle" or "onUniversalValue", props.feature, value) end
          bind(target, props.kind == "toggle" and "Toggle" or "Slider", props)
        end
      end
    end
    local utility = pages.utilities:Section({ title = "Utilities" })
    local antiScope
    utility:Add("Toggle", {
      title = "Anti AFK",
      onChange = function(enabled)
        if antiScope then antiScope:Destroy(); antiScope = nil end
        if not enabled then return end
        antiScope = ctx.scope:Child()
        local function pulse()
          local success, err = pcall(function()
            local virtual = game:GetService("VirtualUser"); virtual:CaptureController()
            virtual:ClickButton2(Vector2.zero)
          end)
          if not success then utils.recordError("AntiAFK", tostring(err)) end
        end
        antiScope:Add(utils.getLocalPlayer().Idled:Connect(pulse))
        local function schedule()
          antiScope:Delay(20, function()
            pulse(); schedule()
          end)
        end
        schedule()
      end,
    })
    local crate = utility:Add("Dropdown", {
      title = "Crate",
      options = { { value = "SwordCrate", label = "Sword" }, { value = "EmoteCrate", label = "Emote" }, { value = "FinisherCrate", label = "Explosion" } },
    })
    local spinScope, spinControl
    local function stopSpin()
      if spinScope then spinScope:Destroy(); spinScope = nil end
    end
    spinControl = utility:Add("Toggle", {
      title = "Auto open crate",
      onChange = function(enabled)
        stopSpin()
        if not enabled then return end
        local owner = ctx.scope:Child(); spinScope = owner
        owner:Add(task.spawn(function()
          local success, err = pcall(function()
            local network = info.createCrateNetwork()
            while not owner.destroyed and utils.isActive() do
              if not info.spinCrate(network, crate:GetValue(), function() return not owner.destroyed end) then break end
              task.wait(0.3)
            end
          end)
          if not owner.destroyed then spinControl:SetValue(false, true) end
          if not success then utils.recordError("Crates", tostring(err)) end
        end))
      end,
    })
    local hub = pages.hub:Section({ title = "Preferences" })
    for _, item in ipairs({
      { "DesktopNotifications", "Desktop notifications" },
      { "MobileNotifications", "Mobile notifications" },
      { "ForcePCUI", "Desktop controls on touch devices" },
    }) do
      bind(hub, "Toggle", { key = item[1], title = item[2] })
    end
    hub:Add("Toggle", { title = "Reduced motion", onChange = function(value) ctx:SetReducedMotion(value) end })
    local session = pages.hub:Section({ title = "Session" })
    session:Add("Button", {
      title = "Reset character",
      text = "Reset",
      variant = "danger",
      onClick = function()
        ctx:Dialog({
          title = "Reset character?",
          message = "Your current character will respawn.",
          variant = "danger",
          onConfirm = function()
            local character = utils.getLocalPlayer().Character; local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if humanoid then humanoid.Health = 0 end
          end,
        })
      end,
    })
    for _, item in ipairs({ { "Rejoin", "onRejoin" }, { "Server hop", "onServerHop" } }) do
      session:Add("Button", { title = item[1], text = "Connect", onClick = function() call(item[2]) end })
    end
    session:Add("Button", {
      title = "Reset settings",
      text = "Restore defaults",
      variant = "danger",
      onClick = function()
        ctx:Dialog({
          title = "Reset settings?",
          message = "All hub settings will return to their defaults.",
          variant = "danger",
          onConfirm = function()
            manual(false); utils.resetConfig()
            UI.setup(deps, { page = "hub" })
          end,
        })
      end,
    })
    local floatButtons = {}
    local definitions = {
      { "Parry", "AutoParry", "ParryBallVisible", "ParryBall", "success" },
      { "Clash", "AutoSpam", "ClashBallVisible", "ClashBall", "accent" },
      { "Dark", "AutoDark", "DarkBallVisible", "DarkBall", "secondary", "onAutoDarkChanged", true },
      { "Jump", "AutoJump", "JumpBallVisible", "JumpBall", "info", "onAutoJumpChanged" },
      { "Dash", nil, "UpDashBallVisible", "UpDashBall", "warning", "onUpDash", true },
    }

    for index, definition in ipairs(definitions) do
      local d = definition
      local button = ctx:FloatingButton({
        text = d[1],
        variant = d[5],
        shape = "circle",
        width = 64,
        height = 64,
        position = UDim2.fromOffset(
          get(d[4] .. "X") or (index >= 4 and math.max(14, ctx.root.AbsoluteSize.X - 78) or 14),
          get(d[4] .. "Y") or (ctx.root.AbsoluteSize.Y / 2 + (index == 1 and -104 or index == 2 and -32 or index == 3 and 40 or index == 4 and -32 or 40))
        ),
        onClick = function()
          if d[2] then toggle(d[2], d[6] and controls[d[6]]) else call(d[6]) end
        end,
        onMove = function(position) ctx.store:Patch({ [d[4] .. "X"] = position.X.Offset, [d[4] .. "Y"] = position.Y.Offset }) end,
      })
      floatButtons[index] = button
    end
    local mini = ctx:FloatingButton({
      text = "OFF",
      title = "Spam",
      shape = "mini",
      variant = "danger",
      width = 112,
      height = 96,
      position = UDim2.fromOffset(get("MiniX") or 100, get("MiniY") or 180),
      onClick = function()
        if get("ManualSpamMode") ~= "Hold" then manual(not utils.isManualSpamActive()) end
      end,
      onHold = function(down)
        if get("ManualSpamMode") == "Hold" then manual(down) end
      end,
      onMove = function(position) ctx.store:Patch({ MiniX = position.X.Offset, MiniY = position.Y.Offset }) end,
    })
    local function refreshFloating()
      for index, definition in ipairs(definitions) do
        floatButtons[index]:SetVisible(not desktop() and get(definition[3]) == true and (not definition[7] or info.areAbilitiesEnabled()))
        floatButtons[index]:SetText(definition[1] .. (definition[2] and (get(definition[2]) and "\nON" or "\nOFF") or ""))
        floatButtons[index]:SetTone(definition[2] and (get(definition[2]) and (index <= 2 and "success" or definition[5]) or "danger") or definition[5])
      end
      mini:SetVisible(not desktop() and get("MiniSpamVisible") == true)
      mini:SetSize(112 * (get("MiniSpamScale") or 1) * (get("MiniSpamWidth") or 1), 96 * (get("MiniSpamScale") or 1) * (get("MiniSpamHeight") or 1))
      for _, component in ipairs(visibilityControls) do
        component:SetDisabled(desktop())
      end
      for _, component in ipairs(abilityControls) do
        component:SetVisible(info.areAbilitiesEnabled())
      end
    end
    ctx.scope:Add(info.observeAbilityMode(refreshFloating))
    ctx.scope:Add(ctx.store.Changed:Connect(function(changes)
      refreshFloating()
      if changes.ManualSpamMode ~= nil or changes.SpamKeybind ~= nil then manual(false) end
    end))
    ctx.scope:Add(utils.observeConfig(function(changes) ctx.store:Patch(changes, true) end))
    local function refreshSpam()
      local active = utils.isManualSpamActive(); manualToggle:SetValue(active, true)
      mini:SetText(active and "ON" or "OFF"); mini:SetTone(active and "success" or "danger")
    end
    ctx.scope:Add(utils.observeSpam(refreshSpam)); refreshSpam()
    refreshFloating()
    for _, property in ipairs({ "KeyboardEnabled", "MouseEnabled", "TouchEnabled" }) do
      ctx.scope:Add(ctx.input:GetPropertyChangedSignal(property):Connect(refreshFloating))
    end
    local telemetryLabels = {}
    for index, key in ipairs({ "ClashDistanceVisible", "ClashTravelTimeVisible", "ClashGateInfoVisible" }) do
      local label = ctx:Component("Readout", ctx.root, { text = "—" }); label.root.ZIndex = 30
      if index == 1 then label.root.AnchorPoint = Vector2.new(0.5, 0); label.root.Position = UDim2.new(0.5, 0, 0, 8)
      elseif index == 2 then label.root.AnchorPoint = Vector2.new(0.5, 1); label.root.Position = UDim2.new(0.5, 0, 1, -20)
      else label.root.AnchorPoint = Vector2.new(0, 0.5); label.root.Position = UDim2.new(0, 8, 0.5, 0) end
      telemetryLabels[key] = label
    end
    local function sample()
      local anyVisible = false
      for key, label in pairs(telemetryLabels) do
        label.root.Visible = get(key) == true; anyVisible = anyVisible or label.root.Visible
      end
      if anyVisible then
        local time = os.clock(); local status = auto.getStatus() or {}
        local stats = status.clashStats or {}; local snapshot = info.getSnapshotAt(time)
        local speed = info.isSnapshotValid(snapshot) and (snapshot.syncSpeed or snapshot.speed) or 0
        if type(speed) ~= "number" or speed ~= speed or math.abs(speed) == math.huge then speed = 0 end
        local travel = stats.frozen and stats.fatalTravelTime or (stats.travelStartedAt and math.max(0, time - stats.travelStartedAt))
        local messages = {
          ClashDistanceVisible = string.format(
            "SPD: %.0f | CPS: %.2f\nDistance: %s | Duration: %.2fs",
            speed or 0,
            stats.currentCps or 0,
            stats.endSample and tostring(stats.endSample.distance) or "—",
            stats.duration or 0
          ),
          ClashTravelTimeVisible = string.format(
            "Travel: %s\nPrevious: %s",
            travel and string.format("%.0f ms", travel * 1000) or "—",
            stats.lastTravelTime and string.format("%.0f ms", stats.lastTravelTime * 1000) or "—"
          ),
          ClashGateInfoVisible = string.format(
            "%s\nState: %s\nActivation: %s",
            status.active and "ACTIVE" or "WAITING",
            tostring(status.lastGate or "—"),
            tostring(status.lastActivationReason or "—")
          ),
        }

        for key, label in pairs(telemetryLabels) do
          label:SetText(messages[key])
        end
      end
      ctx.scope:Delay(anyVisible and CONFIG.TELEMETRY_INTERVAL or CONFIG.IDLE_INTERVAL, sample)
    end
    sample()
    local function cleanup()
      if current == ctx then current = nil end
      manual(false); ctx:Destroy()
      if _G.ExodusUICleanup == cleanup then
        _G.ExodusUICleanup = nil; _G.ExodusUIFadeOut = nil
        _G.ExodusUIRestore = nil; _G.ExodusShowPersistentNotification = nil
        _G.ExodusClearPersistentNotification = nil
      end
    end
    _G.ExodusUICleanup = cleanup
    _G.ExodusUIFadeOut = function()
      _G.ExodusUIReturnAfterUpdate = window.visible; window:SetVisible(false)
    end
    _G.ExodusUIRestore = function(message)
      window:SetVisible(true)
      if message then toast(tostring(message)) end
    end
    _G.ExodusShowPersistentNotification = function(message, id, kind, duration)
      ctx:Notify({
        id = id,
        title = utils.name(),
        message = tostring(message),
        variant = kind == "critical" and "danger" or kind,
        duration = duration or (id == "dumper" and 0 or 2.5),
      })
      return true
    end
    _G.ExodusClearPersistentNotification = function(id)
      if ctx.notifications and ctx.notifications[id] then ctx.notifications[id]:Destroy() end
    end
    if _G.ExodusUIReturnAfterUpdate then window:SetVisible(true) end
    _G.ExodusUIReturnAfterUpdate = nil
    if preview and preview.page then window:SelectPage(preview.page) end
  end, function(err) return debug.traceback(tostring(err), 2) end)
  if not ok then
    if ctx then ctx:Destroy() end
    current = nil; return false, detail
  end
  return true
end

-- contract
UI.__contract = {
  provides = { "setup" },
  requires = {
    Library = "uilibrary",
    Utils = "utils",
    UIConfig = "uiconfig",
    GameInfo = "gameinfo",
    AutoSpam = "autospam",
    Dumper = "dumper",
  },
  requiresMethods = {
    Library = { "new" },
    Utils = {
      "getConfig",
      "getLocalPlayer",
      "isActive",
      "isManualSpamActive",
      "setConfig",
      "resetConfig",
      "setManualSpamActive",
      "observeConfig",
      "observeSpam",
      "recordError",
      "name",
      "version",
      "author",
    },
    GameInfo = { "areAbilitiesEnabled", "observeAbilityMode", "getSnapshotAt", "isSnapshotValid", "createCrateNetwork", "spinCrate" },
    AutoSpam = { "getStatus" },
    Dumper = { "start", "isRunning" },
  },
  requiresData = { UIConfig = { "panelToggles", "panelComponents", "pages" } },
}

return UI
