-- [[ lifecycle ]]

-- module
local Controller = {}

-- configuration
local CONFIG = {}

-- setup
function Controller.setup() return true end

-- controller
function Controller.create(context)
  local Utils = context.deps.Utils; local Controls = context.deps.Controls
  local UIState = context.state; local PW = context.theme.PANEL_W
  local PH = context.theme.PANEL_H; local twPlay = context.twPlay
  local safeCancel = context.safeCancel; local awaitTweens = context.awaitTweens
  local _wait = task.wait; local _spawn = task.spawn
  local fadeRestore, fadeEvent, fadeDone = {}, nil, false; local state = context.notifications.state
  local function restoreAfterReloadFailure(message)
    if not context.refs.configPanel or not context.refs.configPanel.Parent then return end
    if context.kit then context.kit.resume() end
    for object, properties in pairs(fadeRestore) do
      if object.Parent then
        for key, value in pairs(properties) do
          pcall(function() object[key] = value end)
        end
      end
    end
    fadeRestore, fadeEvent, fadeDone = {}, nil, false; UIState.closing = false
    UIState.panelOpen = true; context.refs.configPanel.Visible = true
    context.refs.configPanel.Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97); context.refs.configPanel.GroupTransparency = 1
    if context.refs.floatingButton and context.refs.floatingButton.Parent then
      context.refs.floatingButton.Size = UDim2.new(0, 42, 0, 42); context.refs.floatingButton.BackgroundTransparency = 1
      context.refs.floatingButton.TextTransparency = 1
    end
    twPlay(context.refs.configPanel, "panel", { Size = UDim2.new(0, PW, 0, PH), GroupTransparency = 0 })
    if context.refs.floatingButton and context.refs.floatingButton.Parent then
      twPlay(context.refs.floatingButton, "control", { BackgroundTransparency = 0.6, TextTransparency = 0, Size = UDim2.new(0, 44, 0, 44) })
    end
    local config = Utils.getConfig()
    if not UIState.desktop then
      context.floating.showClashBall(config.ClashBallVisible == true); context.floating.showParryBall(config.ParryBallVisible == true)
      context.floating.showDarkBall(config.DarkBallVisible == true); context.floating.showJumpBall(config.JumpBallVisible == true)
      context.floating.showUpDashBall(config.UpDashBallVisible == true); context.floating.showMini(config.MiniSpamVisible == true)
    end
    if context.notifications.clear then context.notifications.clear("update") end
    if context.notifications.persistent then context.notifications.persistent("Update failed. Check the console.", "critical", "critical") end
    if context.notifications.toast then context.notifications.toast("Reload failed", true) end
    warn("[Exodus Reload] " .. tostring(message))
  end
  local function fadeGuiTree(root, tweens, duration)
    if not root or not root.Parent then return end
    local objects = { root }
    for _, object in ipairs(root:GetDescendants()) do
      objects[#objects + 1] = object
    end
    for _, object in ipairs(objects) do
      local props = {}
      if object:IsA("CanvasGroup") then
        props.GroupTransparency = 1
      elseif object:IsA("UIStroke") then
        props.Transparency = 1
      elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
        props.TextTransparency = 1; props.TextStrokeTransparency = 1
        props.BackgroundTransparency = 1
      elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
        props.ImageTransparency = 1; props.BackgroundTransparency = 1
      elseif object:IsA("ScrollingFrame") then
        props.BackgroundTransparency = 1; props.ScrollBarImageTransparency = 1
      elseif object:IsA("Frame") or object:IsA("ViewportFrame") then
        props.BackgroundTransparency = 1
      end
      if next(props) then
        if not fadeRestore[object] then
          local original = {}
          for key in pairs(props) do
            original[key] = object[key]
          end
          fadeRestore[object] = original
        end
        local tween = twPlay(object, duration, props)
        if tween then tweens[#tweens + 1] = tween end
      end
    end
  end
  local function fadeOutForReplacement(preserveUpdate)
    if UIState.closing then
      if fadeEvent and not fadeDone then fadeEvent.Event:Wait() end
      return
    end
    if not context.refs.screenGui or not context.refs.screenGui.Parent then return end
    UIState.closing = true; fadeDone = false
    if context.pages then context.pages.suspend() end
    if context.kit then context.kit.suspend() end
    if context.motion then
      context.motion.cancelAll(function(object) return preserveUpdate ~= false and object:GetAttribute("ExodusNotificationKey") == "update" end)
    end
    fadeEvent = Instance.new("BindableEvent"); safeCancel(UIState.panelTween)
    safeCancel(UIState.btnTween); safeCancel(UIState.miniTween)
    safeCancel(UIState.toastTween); local tweens = {}
    fadeGuiTree(context.refs.screenGui, tweens, "panel"); fadeGuiTree(context.refs.informationGui, tweens, "panel")
    if state.layer and state.layer.Parent then
      for _, card in ipairs(state.layer:GetChildren()) do
        local key = card:GetAttribute("ExodusNotificationKey")
        if key ~= "update" or preserveUpdate == false then
          if key then safeCancel(state.tweens[key]); state.tweens[key] = nil end
          fadeGuiTree(card, tweens, "panel")
        end
      end
    end
    awaitTweens(tweens); local oldKeys = {}
    for _, key in ipairs(state.order) do
      if key ~= "update" or preserveUpdate == false then oldKeys[#oldKeys + 1] = key end
    end
    for _, key in ipairs(oldKeys) do
      local card = state.layer and state.layer:FindFirstChild("Notification_" .. key)
      if card then card:Destroy() end
      local index = table.find(state.order, key)
      if index then table.remove(state.order, index) end
    end
    if state.layer and state.layer.Parent then
      for _, card in ipairs(state.layer:GetChildren()) do
        if card:GetAttribute("ExodusNotificationKey") ~= "update" or preserveUpdate == false then card:Destroy() end
      end
    end
    fadeDone = true; local completed = fadeEvent
    completed:Fire()
    _spawn(function()
      _wait(); completed:Destroy()
    end)
  end
  local function animateClose(action)
    if UIState.closing then return end
    _G.ExodusShutdownReason = action == "close" and "close" or "reload"
    if action == "reload" and context.notifications.persistent then context.notifications.persistent("Updating...", "update", "info") end
    if type(print) == "function" then print("[Exodus] Closing...") end
    fadeOutForReplacement(action == "reload")
    if not UIState.closing then return end
    if action == "reload" and type(Controls.onReload) == "function" then Controls.onReload(restoreAfterReloadFailure)
    elseif type(Controls.onClose) == "function" then Controls.onClose()
    elseif Utils and type(Utils.stop) == "function" then Utils.stop() end
  end
  return { restore = restoreAfterReloadFailure, fade = fadeOutForReplacement, animateClose = animateClose }
end

-- contract
Controller.__contract = { provides = { "setup", "create" }, requires = {} }

return Controller
