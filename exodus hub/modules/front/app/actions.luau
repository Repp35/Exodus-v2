-- [[ uiactions ]]

-- module
local Actions = {}
local Utils
local GameInfo
local Dumper

-- configuration
local CONFIG = {
  AFK_INTERVAL = 20,
  SPIN_INTERVAL = 0.3,
  CONFIRM_SECONDS = 3,
}

-- setup
function Actions.setup(deps)
  Utils, GameInfo, Dumper = deps.Utils, deps.GameInfo, deps.Dumper; return true
end

-- actions
function Actions.create(context)
  local scope, controls = context.scope, context.controls; local shortcuts = {}
  local handles, callbacks, states = {}, {}, {}; local antiConnection, antiGeneration, spinActive, spinGeneration = nil, 0, nil, 0
  local resetPending, resetGeneration = false, 0
  local function notify(message, important)
    if scope.alive then context.notify(message, important) end
  end
  local function persistent(message, kind, duration)
    if scope.alive then context.persistent(message, "dumper", kind, duration) end
  end
  local function invoke(name, ...)
    if type(controls[name]) == "function" then return controls[name](...) end
  end
  callbacks.panic = function()
    context.setSpam(false); invoke("onPanic")
  end
  callbacks.upDash = function() invoke("onUpDash") end
  callbacks.rejoin = function() invoke("onRejoin") end
  callbacks.serverHop = function() invoke("onServerHop") end
  callbacks.resetCharacter = function()
    local player = Utils.getLocalPlayer(); local character = player and player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 then humanoid.Health = 0 else notify("Personagem indisponível", true) end
  end
  callbacks.resetSettings = function()
    local handle = handles.resetSettings
    if not resetPending then
      resetPending = true; resetGeneration += 1
      local revision = resetGeneration; handle.setText("Tap again to confirm")
      task.delay(CONFIG.CONFIRM_SECONDS, function()
        if scope.alive and revision == resetGeneration then resetPending = false; handle.setText("Reset settings") end
      end)
      return
    end
    resetPending = false; resetGeneration += 1
    local ok, result = pcall(Utils.resetConfig)
    if not ok or not result then
      notify("Reset failed", true); warn("[Exodus] Reset settings: " .. tostring(result))
      handle.setText("Reset settings"); return
    end
    context.rebuild(true)
  end
  callbacks.dumper = function()
    persistent("Dumping...", "info")
    if Dumper.isRunning() then return end
    local accepted, reason = Dumper.start({
      onStatus = function(message) persistent(tostring(message), "info") end,
      onProgress = function(processed, total) persistent(("Dumping... %d/%d"):format(processed, total), "info") end,
      onComplete = function() persistent("Dumping completed.", "success", 2.2) end,
      onCanceled = function() persistent("Dumping canceled.", "warning", 1.5) end,
      onError = function(message)
        warn("[Exodus Dumper] " .. tostring(message)); persistent("Dumper failed. Check the console.", "critical", 2.5)
      end,
    })
    if not accepted then warn("[Exodus Dumper] " .. tostring(reason)); persistent("Dumper is already running.", "warning", 2) end
  end
  states.antiAFK = function() return antiConnection ~= nil end
  callbacks.antiAFK = function(enabled)
    antiGeneration += 1
    if antiConnection then scope.remove(antiConnection); antiConnection = nil end
    if not enabled then return true end
    local player = Utils.getLocalPlayer(); local ok, virtualUser = pcall(game.GetService, game, "VirtualUser")
    if not player then Utils.recordError("AntiAFK", "Player unavailable"); return false end
    local function pulse()
      local inputOk, err = pcall(function()
        if not ok or not virtualUser then error("VirtualUser unavailable") end
        virtualUser:CaptureController(); virtualUser:ClickButton2(Vector2.new(0, 0))
      end)
      if not inputOk then
        local fallback, fallbackErr = pcall(function()
          local vim = game:GetService("VirtualInputManager"); vim:SendMouseButtonEvent(0, 0, 1, true, game, 0)
          vim:SendMouseButtonEvent(0, 0, 1, false, game, 0)
        end)
        if not fallback then Utils.recordError("AntiAFK", tostring(err) .. " | " .. tostring(fallbackErr)) end
      end
    end
    antiConnection = scope.connect(player.Idled, pulse); local generation = antiGeneration
    task.spawn(function()
      while scope.alive and generation == antiGeneration and Utils.isActive() do
        task.wait(CONFIG.AFK_INTERVAL)
        if scope.alive and generation == antiGeneration and Utils.isActive() then pulse() end
      end
    end)
    return true
  end
  local modes = { spinSword = "SwordCrate", spinEmote = "EmoteCrate", spinExplosion = "FinisherCrate" }
  local function paintSpin()
    for action, crate in pairs(modes) do
      if handles[action] then handles[action].setValue(spinActive == crate) end
    end
  end
  for action, crate in pairs(modes) do
    states[action] = function() return spinActive == crate end
    callbacks[action] = function(enabled)
      spinGeneration += 1
      if enabled then spinActive = crate elseif spinActive == crate then spinActive = nil end
      paintSpin()
      if not enabled then return true end
      local generation = spinGeneration
      task.spawn(function()
        local network = GameInfo.createCrateNetwork()
        while scope.alive and generation == spinGeneration and spinActive == crate and Utils.isActive() do
          local sent = GameInfo.spinCrate(network, crate, function() return scope.alive and generation == spinGeneration and spinActive == crate end)
          if not sent then break end
          task.wait(CONFIG.SPIN_INTERVAL)
        end
        if scope.alive and generation == spinGeneration then spinActive = nil; paintSpin() end
      end)
      return true
    end
  end
  callbacks.manualSpam = function(enabled)
    if context.desktop then
      if Utils.getConfigValue("ManualSpamMode") ~= "Hold" then context.setSpam(enabled) end
    else
      context.showMini(enabled)
    end
    return true
  end
  states.manualSpam = function()
    if context.desktop then return Utils.isManualSpamActive() end
    return Utils.getConfigValue("MiniSpamVisible") == true
  end
  local after = {
    AutoDark = function() invoke("onAutoDarkChanged") end,
    AutoJump = function() invoke("onAutoJumpChanged") end,
    ForcePCUI = function() context.rebuild() end,
  }

  local result = {}
  function result.resolve(definition)
    definition.toast = false; definition.expandedDescription = context.desktop and definition.desktopExpanded == true
    if not context.desktop then definition.shortcutKey = nil end
    if definition.action == "notifications" then definition.key = context.desktop and "DesktopNotifications" or "MobileNotifications" end
    if definition.action == "manualSpam" and not context.desktop then definition.key = "MiniSpamVisible" end
    if definition.action then
      assert(definition.action == "notifications" or callbacks[definition.action], "Unknown UI action: " .. tostring(definition.action)); definition.onClick = callbacks[definition.action]
      definition.onChange = callbacks[definition.action]; definition.getState = states[definition.action]
    end
    if definition.feature then
      definition.onChange = function(value) invoke(definition.kind == "toggle" and "onUniversalToggle" or "onUniversalValue", definition.feature, value) end
    elseif after[definition.key] then
      definition.onChange = after[definition.key]
    end
    return definition
  end
  function result.attach(definition, handle)
    if definition.action then handles[definition.action] = handle end
    if context.desktop and definition.shortcutKey then
      local entry = { definition = definition, handle = handle }
      if definition.action == "panic" then table.insert(shortcuts, 1, entry) else shortcuts[#shortcuts + 1] = entry end
    end
  end
  function result.validateShortcut(key, binding)
    if binding == Enum.KeyCode.Unknown then return true end
    for _, entry in ipairs(shortcuts) do
      local definition = entry.definition
      if definition.shortcutKey ~= key and Utils.getConfigValue(definition.shortcutKey) == binding then return false, "Shortcut already used: " .. definition.title end
    end
    return true
  end
  function result.triggerShortcut(binding)
    if not context.desktop or binding == Enum.KeyCode.Unknown then return false end
    for _, entry in ipairs(shortcuts) do
      local definition, handle = entry.definition, entry.handle
      if Utils.getConfigValue(definition.shortcutKey) == binding then
        if definition.abilityOnly and context.abilitiesEnabled and not context.abilitiesEnabled() then return false end
        if not handle.activate or not handle.activate() then return false end
        if definition.action ~= "manualSpam" and definition.action ~= "upDash" then
          local message = definition.title
          if definition.kind == "toggle" then message = message .. (handle.getValue() and " On" or " Off") end
          context.notify(message, false, { category = "shortcut", topic = definition.action or definition.key })
        end
        return true
      end
    end
    return false
  end
  function result.refreshManual()
    if handles.manualSpam then handles.manualSpam.setValue(states.manualSpam()) end
  end
  scope.add(function()
    antiGeneration += 1; spinGeneration += 1
    resetGeneration += 1
  end)
  return result
end

-- contract
Actions.__contract = {
  provides = { "setup", "create" },
  requires = { Utils = "utils", GameInfo = "gameinfo", Dumper = "dumper" },
  requiresMethods = {
    Utils = { "getConfigValue", "getLocalPlayer", "isActive", "isManualSpamActive", "resetConfig", "recordError" },
    GameInfo = { "createCrateNetwork", "spinCrate" },
    Dumper = { "start", "isRunning" },
  },
}

return Actions
