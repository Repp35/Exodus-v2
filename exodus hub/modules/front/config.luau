-- [[ config ]]

-- module
local Config = {}
local Registry = {}
local Keys = {}

-- configuration
local CONFIG = {
  RATE_MIN = 0,
  DELAY_MIN = 0,
  DELAY_MAX = 5,
  DELAY_MS_MAX = 400,
  POSITION_MIN = -10000,
  POSITION_MAX = 10000,
  ERRORS = {
    boolean = "flag inválida: %s",
    rate = "taxa inválida: %s",
    delay = "atraso inválido: %s",
    delayMs = "tempo inválido: %s",
    position = "posição inválida: %s",
    keyCode = "keybind inválido: %s",
    rateMode = "SpamRateMode inválido",
  },
}

-- validation
local function isFiniteNumber(value) return type(value) == "number" and value == value and value < math.huge and value > -math.huge end
local function validKeyCode(value)
  return typeof(value) == "EnumItem"
    and (
      value.EnumType == Enum.KeyCode
      or value == Enum.UserInputType.MouseButton1
      or value == Enum.UserInputType.MouseButton2
      or value == Enum.UserInputType.MouseButton3
    )
end
local validationErrors = CONFIG.ERRORS
local validators = {
  boolean = function(value) return type(value) == "boolean" end,
  rate = function(value) return isFiniteNumber(value) and value >= CONFIG.RATE_MIN end,
  delay = function(value) return isFiniteNumber(value) and value >= CONFIG.DELAY_MIN and value <= CONFIG.DELAY_MAX end,
  delayMs = function(value) return isFiniteNumber(value) and value >= CONFIG.DELAY_MIN and value <= CONFIG.DELAY_MS_MAX end,
  position = function(value) return isFiniteNumber(value) and value >= CONFIG.POSITION_MIN and value <= CONFIG.POSITION_MAX end,
  keyCode = validKeyCode,
  rateMode = function(value) return value == "CPS" or value == "CPF" or value == "Auto" end,
}

local function validateValue(key, kind, value)
  local validator = validators[kind]
  if validator and validator(value) then return true end
  local message = validationErrors[kind] or "valor inválido: %s"; return false, message:find("%s", 1, true) and message:format(key) or message
end
local function copy(source)
  local result = {}
  for key, value in pairs(source or {}) do
    result[key] = value
  end
  return result
end

-- registration
function Config.register(name, definition)
  if type(name) ~= "string" or type(definition) ~= "table" or Registry[name] then return false end
  local schema = type(definition.schema) == "table" and definition.schema or {}; local defaults = type(definition.defaults) == "table" and definition.defaults or {}
  for key, kind in pairs(schema) do
    if type(key) ~= "string" or not validators[kind] or Keys[key] then return false end
  end
  for key, value in pairs(defaults) do
    local kind = schema[key]
    if not kind or not validateValue(key, kind, value) then return false end
  end
  for key, kind in pairs(schema) do
    Keys[key] = kind
  end
  Registry[name] = { schema = copy(schema), defaults = copy(defaults) }; return true
end

-- defaults
function Config.defaults()
  local result = {}
  for _, definition in pairs(Registry) do
    for key, value in pairs(definition.defaults) do
      result[key] = value
    end
  end
  return result
end

-- validation-api
function Config.validatePatch(patch)
  if type(patch) ~= "table" then return false, "configuração não é uma tabela" end
  for key, value in pairs(patch) do
    local kind = Keys[key]
    if not kind then return false, "chave de configuração desconhecida: " .. tostring(key) end
    local ok, reason = validateValue(key, kind, value)
    if not ok then return false, reason end
  end
  return true
end
function Config.normalizePatch(patch)
  local ok, reason = Config.validatePatch(patch)
  if not ok then return nil, reason end
  return copy(patch)
end
function Config.validate(config)
  if type(config) ~= "table" then return false, "configuração não é uma tabela" end
  local ok, reason = Config.validatePatch(config)
  if not ok then return false, reason end
  return true
end

-- public-api
function Config.getRegistry()
  local result = {}
  for name, definition in pairs(Registry) do
    result[name] = { schema = copy(definition.schema), defaults = copy(definition.defaults) }
  end
  return result
end


-- hub-settings
Config.__config = {
    schema = {
      MobileNotifications = "boolean",
      DesktopNotifications = "boolean",
      AutoParry = "boolean",
      AutoParryWindowFactor = "rate",
      AutoParryFactor08Applied = "boolean",
      AutoParryFactor03Applied = "boolean",
      CameraSensitivity = "rate",
      ParryBallVisible = "boolean",
      ParryBallX = "position",
      ParryBallY = "position",
      AutoSpam = "boolean",
      AutoDark = "boolean",
      AutoFierce = "boolean",
      AutoJump = "boolean",
      AutoClashUpDash = "boolean",
      ClashBallVisible = "boolean",
      ClashDistanceVisible = "boolean",
      ClashTravelTimeVisible = "boolean",
      ClashGateInfoVisible = "boolean",
      MiniSpamVisible = "boolean",
      DarkBallVisible = "boolean",
      JumpBallVisible = "boolean",
      UpDashBallVisible = "boolean",
      CPS = "rate",
      CPF = "rate",
      SpamRateMode = "rateMode",
      Keybind = "keyCode",
      SpamKeybind = "keyCode",
      ManualSpamEnabled = "boolean",
      ParryKeybind = "keyCode",
      ClashKeybind = "keyCode",
      DarkKeybind = "keyCode",
      JumpKeybind = "keyCode",
      UpDashKeybind = "keyCode",
      BtnX = "position",
      BtnY = "position",
      ClashBallX = "position",
      ClashBallY = "position",
      DarkBallX = "position",
      DarkBallY = "position",
      JumpBallX = "position",
      JumpBallY = "position",
      UpDashBallX = "position",
      UpDashBallY = "position",
      MiniX = "position",
      MiniY = "position",
      PanelX = "position",
      PanelY = "position",
    },
    defaults = {
      MobileNotifications = false,
      DesktopNotifications = true,
      AutoParry = true,
      AutoParryWindowFactor = 0.3,
      AutoParryFactor08Applied = true,
      AutoParryFactor03Applied = true,
      CameraSensitivity = 1,
      ParryBallVisible = false,
      AutoSpam = true,
      AutoDark = false,
      AutoFierce = false,
      AutoJump = false,
      AutoClashUpDash = false,
      ClashBallVisible = false,
      ClashDistanceVisible = false,
      ClashTravelTimeVisible = false,
      ClashGateInfoVisible = false,
      MiniSpamVisible = false,
      DarkBallVisible = false,
      JumpBallVisible = false,
      UpDashBallVisible = false,
      CPS = 24,
      CPF = 0.36,
      SpamRateMode = "CPF",
      Keybind = Enum.KeyCode.F9,
      SpamKeybind = Enum.KeyCode.F,
      ManualSpamEnabled = false,
      ParryKeybind = Enum.KeyCode.P,
      ClashKeybind = Enum.KeyCode.C,
      DarkKeybind = Enum.KeyCode.D,
      JumpKeybind = Enum.KeyCode.J,
      UpDashKeybind = Enum.KeyCode.U,
    },
  }

-- hub-interface
local interface
function Config.teardown()
  local current = interface; interface = nil
  if current then current.destroy() end
  return true
end
function Config.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.UI) ~= "table" then return false, "UI or Utils unavailable" end
  Config.teardown()
  local utils, ui, info, spam, dumper = deps.Utils, deps.UI, deps.GameInfo, deps.AutoSpam, deps.Dumper
  local actions = deps.Controls or {}
  local player = utils.getLocalPlayer()
  local parent = player and (player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10))
  if not parent then return false, "PlayerGui unavailable" end
  local input = game:GetService("UserInputService")
  local mobile = input.TouchEnabled and not input.KeyboardEnabled and not input.MouseEnabled
  local bindings, abilityControls, connections = {}, {}, {}
  local antiConnection, antiGeneration, spinGeneration, spinActive = nil, 0, 0, nil
  local live = true
  local function get(key) return utils.getConfigValue(key) end
  local function set(key, value) return utils.setConfig({ [key] = value }) end
  local function fail(context, message) utils.recordError(context, tostring(message)) end
  local function manual(value)
    value = value == true
    if utils.isManualSpamActive() == value then return true end
    utils.setManualSpamActive(value); return utils.isManualSpamActive() == value
  end
  local function invoke(name, ...) if type(actions[name]) == "function" then return actions[name](...) end end
  local function modified(key)
    if key == "AutoDark" then invoke("onAutoDarkChanged") elseif key == "AutoJump" then invoke("onAutoJumpChanged") end
  end
  local function toggle(key)
    local value = get(key) ~= true
    if set(key, value) then modified(key); return true end
    return false
  end
  local function bind(definition, key, transform, after)
    definition.id = definition.id or key; definition.value = transform and transform(get(key)) or get(key)
    definition.onChange = function(value)
      if not set(key, value) then return false end
      if after then after(value) end
      modified(key); return true
    end
    bindings[key] = bindings[key] or {}; bindings[key][#bindings[key] + 1] = definition.id
    return definition
  end
  local function flag(title, key, ability)
    local d = bind({ kind = "toggle", title = title }, key)
    if ability then abilityControls[#abilityControls + 1] = d.id end
    return d
  end
  local function shortcut(title, key) return bind({ kind = "keybind", title = title }, key) end
  local function section(title) return { kind = "section", title = title } end
  local function notify(message, key, kind, duration)
    if not interface then return end
    local important = kind == "critical" or kind == "error" or key == "update" or key == "dumper"
    if not important and get(mobile and "MobileNotifications" or "DesktopNotifications") ~= true then return end
    interface.notify(message, kind == "critical" and "error" or kind, duration == nil and (key == "dumper" and 0 or 3) or duration, key)
  end
  local function stopAntiAFK()
    antiGeneration = antiGeneration + 1
    if antiConnection then antiConnection:Disconnect(); antiConnection = nil end
  end
  local function antiAFK(enabled)
    stopAntiAFK(); if not enabled then return true end
    local function pulse()
      local ok, err = pcall(function()
        local virtual = game:GetService("VirtualUser"); virtual:CaptureController(); virtual:ClickButton2(Vector2.new())
      end)
      if not ok then
        local fallback, other = pcall(function()
          local virtual = game:GetService("VirtualInputManager")
          virtual:SendMouseButtonEvent(0, 0, 1, true, game, 0); virtual:SendMouseButtonEvent(0, 0, 1, false, game, 0)
        end)
        if not fallback then fail("AntiAFK", tostring(err) .. " | " .. tostring(other)) end
      end
    end
    antiConnection = player.Idled:Connect(pulse)
    local token = antiGeneration
    task.spawn(function()
      while live and token == antiGeneration and utils.isActive() do
        task.wait(20)
        if live and token == antiGeneration and utils.isActive() then pulse() end
      end
    end)
    return true
  end
  local crateModes = { { "Sword", "SwordCrate" }, { "Emote", "EmoteCrate" }, { "Explosion", "FinisherCrate" } }
  local function spin(crate, enabled)
    spinGeneration = spinGeneration + 1; spinActive = enabled and crate or nil
    for _, entry in ipairs(crateModes) do if interface then interface.set("spin_" .. entry[2], spinActive == entry[2], false) end end
    if not enabled then return true end
    local token = spinGeneration
    task.spawn(function()
      local ok, err = pcall(function()
        local network = info.createCrateNetwork()
        while live and token == spinGeneration and spinActive == crate and utils.isActive() do
          local sent = info.spinCrate(network, crate, function() return live and token == spinGeneration and spinActive == crate end)
          if not sent then break end
          task.wait(0.3)
        end
      end)
      if not ok then fail("Crate", err) end
      if live and token == spinGeneration then spinActive = nil; interface.set("spin_" .. crate, false, false) end
    end)
    return true
  end
  local function runDumper()
    if dumper.isRunning() then notify("Dumping...", "dumper", "info", 0); return end
    notify("Dumping...", "dumper", "info", 0)
    local accepted, reason = dumper.start({
      onStatus = function(message) notify(message, "dumper", "info", 0) end,
      onProgress = function(done, total) notify(("Dumping... %d/%d"):format(done, total), "dumper", "info", 0) end,
      onComplete = function(result) notify(("Dump completed: %d saved, %d failed"):format(result.saved, result.failed), "dumper", "success", 4) end,
      onCanceled = function() notify("Dump canceled", "dumper", "warning", 2) end,
      onError = function(message) fail("Dumper", message); notify("Dump failed. Check the console.", "dumper", "error", 4) end,
    })
    if not accepted then notify(tostring(reason), "dumper", "error", 4) end
  end
  local combat = {
    section("Combat"), flag("Auto Parry", "AutoParry"), flag("Auto Spam", "AutoSpam"),
    { kind = "toggle", id = "manual", title = "Manual Spam", value = utils.isManualSpamActive(), onChange = manual },
    flag("Enable manual shortcut", "ManualSpamEnabled"), shortcut("Manual Spam shortcut", "SpamKeybind"),
    shortcut("Auto Parry shortcut", "ParryKeybind"), shortcut("Auto Spam shortcut", "ClashKeybind"),
    section("Spam rate"), bind({ kind = "dropdown", title = "Mode", options = { "CPS", "CPF", "Auto" } }, "SpamRateMode"),
    bind({ kind = "number", title = "CPS", min = 0 }, "CPS"), bind({ kind = "number", title = "CPF", min = 0 }, "CPF"),
    { kind = "button", title = "Stop Functions", onClick = function() manual(false); invoke("onPanic") end }, shortcut("Stop Functions shortcut", "Keybind"),
  }
  local settings = {
    section("Parry & Camera"), bind({ kind = "slider", title = "Parry window factor", min = 0, max = 0.35, step = 0.01 }, "AutoParryWindowFactor"),
    bind({ kind = "number", title = "Camera sensitivity", min = 0 }, "CameraSensitivity"),
    section("Indicators"), flag("Clash distance", "ClashDistanceVisible"), flag("Ball travel time", "ClashTravelTimeVisible"), flag("Auto Spam gates", "ClashGateInfoVisible"),
  }
  local automatic = {
    section("Automatic abilities"), flag("Auto Dark", "AutoDark", true), flag("Auto Fierce", "AutoFierce", true),
    flag("Auto Jump", "AutoJump", true), flag("Auto Dash (clash)", "AutoClashUpDash", true),
    { kind = "button", id = "updash", title = "Up Dash", onClick = function() invoke("onUpDash") end },
    shortcut("Auto Dark shortcut", "DarkKeybind"), shortcut("Auto Jump shortcut", "JumpKeybind"), shortcut("Up Dash shortcut", "UpDashKeybind"),
  }
  abilityControls[#abilityControls + 1] = "updash"
  local universal = { section("Developer tools"), { kind = "button", title = "Dumper", onClick = runDumper }, section("Universal controls") }
  for _, entry in ipairs({ { "Infinite Jump", "InfiniteJump", "UniversalInfiniteJump" }, { "Fly", "Fly", "UniversalFly" }, { "Speed", "Speed", "UniversalSpeedEnabled" }, { "Gravity", "Gravity", "UniversalGravityEnabled" }, { "Invisicam", "Invisicam", "UniversalInvisicam" }, { "Noclip", "Noclip", "UniversalNoclip" } }) do
    local title, feature, key = entry[1], entry[2], entry[3]
    universal[#universal + 1] = bind({ kind = "toggle", title = title }, key, nil, function(value) invoke("onUniversalToggle", feature, value) end)
    if feature == "Speed" or feature == "Gravity" then
      universal[#universal + 1] = bind({ kind = "slider", title = title .. " value", min = 0, max = feature == "Speed" and 200 or 400, step = 1 }, "Universal" .. feature, nil, function(value) invoke("onUniversalValue", feature, value) end)
    end
  end
  local utilities = { section("Utilities"), { kind = "toggle", title = "Anti AFK", value = false, onChange = antiAFK } }
  for _, entry in ipairs(crateModes) do local crate = entry[2]; utilities[#utilities + 1] = { kind = "toggle", id = "spin_" .. crate, title = "Spin " .. entry[1], value = false, onChange = function(enabled) return spin(crate, enabled) end } end
  local resetUntil = 0
  local hub = { section("Notifications"), flag("Mobile notifications", "MobileNotifications"), flag("Desktop notifications", "DesktopNotifications"),
    { kind = "button", title = "Reset settings", onClick = function()
      if os.clock() > resetUntil then resetUntil = os.clock() + 3; notify("Tap reset again to confirm", "reset", "warning", 3); return end
      resetUntil = 0; if not utils.resetConfig() then fail("Config", "reset rejected"); return end
      task.defer(function() if live then local ok, err = Config.setup(deps); if not ok then fail("UI", err) elseif interface then interface.setVisible(true) end end end)
    end },
  }
  local minis = { { "Mini Parry UI", "ParryBallVisible", "AutoParry", "ParryBall", "AP" }, { "Mini Clash UI", "ClashBallVisible", "AutoSpam", "ClashBall", "AC" }, { "Mini Dark UI", "DarkBallVisible", "AutoDark", "DarkBall", "Dark" }, { "Mini Auto Jump", "JumpBallVisible", "AutoJump", "JumpBall", "Jump" }, { "Mini Up Dash", "UpDashBallVisible", false, "UpDashBall", "Dash" }, { "Manual Spam UI", "MiniSpamVisible", false, "Mini", "Spam" } }
  if mobile then settings[#settings + 1] = section("Floating controls"); for _, entry in ipairs(minis) do settings[#settings + 1] = flag(entry[1], entry[2]) end end
  local function savePosition(xKey, yKey, position)
    local camera = workspace.CurrentCamera; local size = camera and camera.ViewportSize or Vector2.new()
    return utils.setConfig({ [xKey] = position.X.Offset + position.X.Scale * size.X, [yKey] = position.Y.Offset + position.Y.Scale * size.Y })
  end
  local function position(xKey, yKey, defaultX, defaultY) return UDim2.fromOffset(tonumber(get(xKey)) or defaultX, tonumber(get(yKey)) or defaultY) end
  local telemetryAt = 0
  local function telemetry(time)
    if time < telemetryAt then return end; telemetryAt = time + 0.1
    if not get("ClashGateInfoVisible") and not get("ClashDistanceVisible") and not get("ClashTravelTimeVisible") then return end
    local status = spam.getStatus(); local stats = status and status.clashStats; local sample = info.getSnapshotAt(time)
    local speed = info.isSnapshotValid(sample) and (tonumber(sample.syncSpeed) or sample.speed) or 0
    if get("ClashGateInfoVisible") then interface.set("gates", "Activation: " .. tostring(status.lastActivationReason or "—") .. "\nDeactivation: " .. tostring(status.lastStopReason or "—")) end
    if get("ClashDistanceVisible") then interface.set("distance", string.format("SPD %.0f | Distance %s studs", speed, stats and stats.distance and string.format("%.1f", stats.distance) or "—")) end
    if get("ClashTravelTimeVisible") then
      local current = stats and stats.travelStartedAt and not stats.frozen and math.max(0, time - stats.travelStartedAt) or nil
      local last = stats and stats.lastTravelTime; local previous = stats and stats.penultimateTravelTime
      interface.set("travel", "Travel: " .. (current and string.format("%.0f ms", current * 1000) or "—") .. "\nLast: " .. (last and string.format("%.0f ms", last * 1000) or "—") .. " | Previous: " .. (previous and string.format("%.0f ms", previous * 1000) or "—"))
    end
  end
  local function closeHub() invoke("onClose"); if utils.isActive() then utils.stop() end end
  local fallbackNotifications = parent:FindFirstChild("ExodusPersistentNotifications")
  if fallbackNotifications then fallbackNotifications:Destroy() end
  local view = ui.new({
    parent = parent, name = "ExodusUISystem", title = utils.name() .. " | v" .. utils.version() .. " — " .. utils.author(), icon = "EX", visible = _G.ExodusUIReturnAfterUpdate == true,
    position = get("PanelX") and position("PanelX", "PanelY", 300, 300) or nil,
    launcherPosition = position("BtnX", "BtnY", 14, 80),
    onMove = function(p) savePosition("PanelX", "PanelY", p) end, onLauncherMove = function(p) savePosition("BtnX", "BtnY", p) end,
    onClose = closeHub, onError = function(message) fail("UI", message) end,
    onUpdate = function() if live and interface then telemetry(os.clock()) end end,
    pages = { { id = "main", title = "Main", components = combat }, { id = "settings", title = "Settings", components = settings }, { id = "utilities", title = "Utilities", components = utilities }, { id = "automatic", title = "Automatic", components = automatic }, { id = "indeed", title = "Indeed", components = universal }, { id = "hub", title = "Config", components = hub } },
  })
  interface = view
  view.action("Reload", function()
    if not actions.onReload then return end
    local restore = function(message) if view.isAlive() then view.restore(message); for _, entry in ipairs(minis) do local h = view.get("mini_" .. entry[4]); if h then h.setVisible(mobile and get(entry[2]) == true) end end end end
    local ok, err = pcall(actions.onReload, restore); if not ok then restore(tostring(err)); fail("Reload", err) end
  end)
  view.action("Close Script", closeHub)
  for index, entry in ipairs(minis) do
    local visibleKey, featureKey, prefix = entry[2], entry[3], entry[4]
    local handle = view.floating({ id = "mini_" .. prefix, title = entry[5], visible = mobile and get(visibleKey) == true, value = featureKey and get(featureKey) == true or utils.isManualSpamActive(),
      position = position(prefix .. "X", prefix .. "Y", 14, 150 + (index - 1) * 50),
      onMove = function(p) savePosition(prefix .. "X", prefix .. "Y", p) end,
      onChange = function(value) if featureKey then if not set(featureKey, value) then return false end; modified(featureKey); return true elseif prefix == "Mini" then return manual(value) end; return true end,
      onClick = prefix == "UpDashBall" and function() invoke("onUpDash") end or nil,
    })
    if featureKey then bindings[featureKey][#bindings[featureKey] + 1] = "mini_" .. prefix end
  end
  view.overlay({ id = "gates", position = UDim2.fromOffset(12, 14), visible = get("ClashGateInfoVisible") == true })
  view.overlay({ id = "distance", position = UDim2.fromOffset(12, 100), visible = get("ClashDistanceVisible") == true, height = 44 })
  view.overlay({ id = "travel", position = UDim2.fromOffset(12, 150), visible = get("ClashTravelTimeVisible") == true })
  local function abilityVisibility(enabled)
    for _, id in ipairs(abilityControls) do view.setControlVisible(id, enabled) end
    for _, prefix in ipairs({ "DarkBall", "JumpBall", "UpDashBall" }) do view.setControlVisible("mini_" .. prefix, mobile and enabled and get(prefix == "DarkBall" and "DarkBallVisible" or prefix == "JumpBall" and "JumpBallVisible" or "UpDashBallVisible") == true) end
  end
  abilityVisibility(info.areAbilitiesEnabled()); connections[#connections + 1] = info.observeAbilityMode(abilityVisibility)
  local function rebindKeys()
    view.bindKey("panic", get("Keybind"), function() manual(false); invoke("onPanic") end)
    for _, entry in ipairs({ { "ParryKeybind", "AutoParry" }, { "ClashKeybind", "AutoSpam" }, { "DarkKeybind", "AutoDark" }, { "JumpKeybind", "AutoJump" } }) do
      local key, feature = entry[1], entry[2]; view.bindKey(key, get(key), function() toggle(feature) end)
    end
    view.bindKey("UpDashKeybind", get("UpDashKeybind"), function() invoke("onUpDash") end)
    view.bindKey("manual", get("SpamKeybind"), function() if get("ManualSpamEnabled") == true then manual(true) end end, function() manual(false) end)
  end
  rebindKeys()
  connections[#connections + 1] = utils.observeConfig(function(changes)
    for key, value in pairs(changes) do
      for _, id in ipairs(bindings[key] or {}) do view.set(id, value, false) end
      if tostring(key):find("Keybind", 1, true) then rebindKeys() end
    end
    for _, entry in ipairs(minis) do if changes[entry[2]] ~= nil then view.setControlVisible("mini_" .. entry[4], mobile and get(entry[2]) == true) end end
    for _, entry in ipairs({ { "ClashGateInfoVisible", "gates" }, { "ClashDistanceVisible", "distance" }, { "ClashTravelTimeVisible", "travel" } }) do if changes[entry[1]] ~= nil then view.setControlVisible(entry[2], changes[entry[1]]) end end
    if changes.ManualSpamEnabled == false then manual(false) end
    abilityVisibility(info.areAbilitiesEnabled())
  end)
  connections[#connections + 1] = utils.observeSpam(function() local active = utils.isManualSpamActive(); view.set("manual", active, false); view.set("mini_Mini", active, false) end)
  view.addCleanup(function()
    live = false; stopAntiAFK(); spinGeneration = spinGeneration + 1
    for _, connection in ipairs(connections) do if connection then connection:Disconnect() end end
    if interface == view then interface = nil end
  end)
  _G.ExodusUICleanup = Config.teardown
  _G.ExodusUIFadeOut = view.fadeOut
  _G.ExodusShowPersistentNotification = notify
  _G.ExodusClearPersistentNotification = view.clearNotification
  _G.ExodusUIReturnAfterUpdate = nil
  return true
end

-- contract
Config.__contract = {
  requires = { Utils = "utils", UI = "ui", GameInfo = "gameinfo", AutoSpam = "autospam", Dumper = "dumper" },
  requiresMethods = {
    Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "setManualSpamActive", "isManualSpamActive", "isActive", "stop", "name", "version", "author", "recordError", "resetConfig", "observeConfig", "observeSpam" },
    UI = { "new" },
    GameInfo = { "areAbilitiesEnabled", "observeAbilityMode", "getSnapshotAt", "isSnapshotValid", "createCrateNetwork", "spinCrate" },
    AutoSpam = { "getStatus" }, Dumper = { "start", "isRunning" },
  },
  provides = { "register", "defaults", "validate", "validatePatch", "normalizePatch", "getRegistry", "setup", "teardown" },
}
return Config
