-- [[ floating ]]

-- module
local Controller = {}

-- configuration
local CONFIG = {}

-- setup
function Controller.setup() return true end

-- controller
function Controller.create(context)
  local Utils = context.deps.Utils; local GameInfo = context.deps.GameInfo
  local AutoSpam = context.deps.AutoSpam; local Controls = context.deps.Controls
  local UIState = context.state; local C = context.theme.COLORS
  local BTN_SIZE = context.theme.BTN_SIZE; local CLASH_SIZE = context.theme.CLASH_SIZE
  local OFFSCREEN_X = (-context.theme.CLASH_SIZE - 40); local MINI_W = context.theme.MINI_W
  local MINI_H = context.theme.MINI_H; local inst = context.inst
  local corner = context.corner; local stroke = context.stroke
  local twPlay = context.twPlay; local safeCancel = context.safeCancel
  local viewport = context.viewport; local setConfigValue = context.setConfigValue
  local trackConn = context.trackConn; local untrackConn = context.untrackConn
  local safeDisconnect = context.safeDisconnect; local makeDraggable = context.makeDraggable
  local setSpam
  local function btnPos()
    local config = Utils.getConfig(); local x, y = config.BtnX, config.BtnY
    if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
    return UDim2.new(1, -70, 0.5, -28)
  end
  local function paintBall(ball, value, onText, offText, onColor, offColor, onSize, offSize)
    if not ball or not ball.Parent then return end
    ball.Text = value and onText or offText
    if onSize then ball.TextSize = value and onSize or offSize end
    twPlay(ball, "control", { BackgroundColor3 = value and onColor or offColor })
  end
  local function paintParryBall(value) paintBall(context.refs.parryBall, value, "PARRY\nON", "PARRY\nOFF", C.green, C.red, 14, 14) end
  local function showBall(ball, visible, visibleKey, xKey, yKey, defaultX, defaultY)
    local config = Utils.getConfig(); local x = config[xKey] or defaultX
    local y = config[yKey] or defaultY; local shouldShow = visible and not UIState.desktop
    twPlay(ball, "control", { Position = shouldShow and UDim2.new(0, x, 0, y) or UDim2.new(0, OFFSCREEN_X, 0, y) })
  end
  local function pulseBall(ball)
    local shrink = twPlay(ball, "press", { Size = UDim2.new(0, CLASH_SIZE - 6, 0, CLASH_SIZE - 6) })
    if not shrink then return end
    local connection
    connection = trackConn(shrink.Completed:Connect(function(playbackState)
      safeDisconnect(connection); untrackConn(connection)
      if playbackState == Enum.PlaybackState.Completed and ball and ball.Parent then twPlay(ball, "feedback", { Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE) }) end
    end))
  end
  local function showParryBall(value)
    showBall(context.refs.parryBall, value, "ParryBallVisible", "ParryBallX", "ParryBallY", 14, viewport().Y / 2 - CLASH_SIZE - 40)
  end
  local function paintClashBall() paintBall(context.refs.clashBall, UIState.clashBallOn, "ON", "OFF", C.green, C.red, 18, 16) end
  local function setClashBall(v, silent)
    UIState.clashBallOn = v; setConfigValue("AutoSpam", v)
    if silent then return end
    paintClashBall(); pulseBall(context.refs.clashBall)
    if context.notifications.toast then context.notifications.toast("Auto Spam " .. (v and "On" or "Off")) end
  end
  local function showClashBall(v) showBall(context.refs.clashBall, v, "ClashBallVisible", "ClashBallX", "ClashBallY", 14, viewport().Y / 2 - CLASH_SIZE / 2) end
  local function paintDarkBall(v) paintBall(context.refs.darkBall, v, "ON", "OFF", C.darkOn, C.darkOff, 18, 16) end
  local function showDarkBall(v) showBall(context.refs.darkBall, v, "DarkBallVisible", "DarkBallX", "DarkBallY", 14, viewport().Y / 2 + CLASH_SIZE / 2 + 8) end
  local function setDarkBall(v)
    if not setConfigValue("AutoDark", v) then return end
    if type(Controls.onAutoDarkChanged) == "function" then Controls.onAutoDarkChanged() end
    paintDarkBall(v); pulseBall(context.refs.darkBall)
    if context.notifications.toast then context.notifications.toast("Auto Dark " .. (v and "On" or "Off")) end
  end
  local function showMovementBall(ball, visible, visibleKey, xKey, yKey, yOffset)
    showBall(ball, visible, visibleKey, xKey, yKey, CLASH_SIZE + 22, viewport().Y / 2 + yOffset)
  end
  local function showJumpBall(v) showMovementBall(context.refs.jumpBall, v, "JumpBallVisible", "JumpBallX", "JumpBallY", -CLASH_SIZE / 2) end
  local function showUpDashBall(v) showMovementBall(context.refs.upDashBall, v, "UpDashBallVisible", "UpDashBallX", "UpDashBallY", CLASH_SIZE / 2 + 8) end
  local function paintJumpBall(v) paintBall(context.refs.jumpBall, v, "JUMP\nON", "JUMP\nOFF", C.jumpOn, C.jumpOff) end
  local function setJumpBall(v)
    if not setConfigValue("AutoJump", v) then return end
    if type(Controls.onAutoJumpChanged) == "function" then Controls.onAutoJumpChanged() end
    paintJumpBall(v)
    if context.notifications.toast then context.notifications.toast("Auto Jump " .. (v and "On" or "Off")) end
  end
  local function miniScreenScale() return context.refs.responsiveScale and context.refs.responsiveScale.Scale or 1 end
  local function miniLayout(scale)
    local view, screenScale = viewport(), math.max(miniScreenScale(), 0.01); local screenWidth, screenHeight = view.X / screenScale, view.Y / screenScale
    local config = Utils.getConfig(); local width = math.min(MINI_W * scale * (tonumber(config.MiniSpamWidth) or 1), screenWidth)
    local height = math.min(MINI_H * scale * (tonumber(config.MiniSpamHeight) or 1), screenHeight)
    local x = math.clamp(config.MiniX or (screenWidth - width - 14), 0, math.max(0, screenWidth - width))
    local y = math.clamp(config.MiniY or (screenHeight / 2 - height / 2), 0, math.max(0, screenHeight - height)); return x, y, width, height, screenWidth
  end
  local function applyMiniScale(value)
    if not context.refs.miniGui or not context.refs.miniGui.Parent then return end
    local scale = math.clamp(tonumber(value) or 1, 0.5, 2); local x, y, width, height = miniLayout(scale)
    twPlay(context.refs.miniGui, "feedback", { Size = UDim2.fromOffset(width, height) })
    if context.refs.miniGui.Visible then twPlay(context.refs.miniGui, "feedback", { Position = UDim2.fromOffset(x, y) }) end
  end
  local function showMini(v)
    if UIState.desktop then v = false end
    if not context.refs.miniGui or not context.refs.miniGui.Parent then return end
    local config = Utils.getConfig(); local miniX, miniY, _, _, screenWidth = miniLayout(tonumber(config.MiniSpamScale) or 1)
    local hiddenPosition = UDim2.new(0, screenWidth + 30, 0, miniY); UIState.miniGeneration += 1
    local generation = UIState.miniGeneration; safeCancel(UIState.miniTween)
    if v then
      if not context.refs.miniGui.Visible then
        context.refs.miniGui.Position = hiddenPosition; context.refs.miniGui.GroupTransparency = 1
        context.refs.miniGui.Visible = true
      end
      UIState.miniTween = twPlay(context.refs.miniGui, "control", {
        Position = UDim2.new(0, miniX, 0, miniY),
        GroupTransparency = 0,
      })
      return UIState.miniTween
    end
    if UIState.manualHoldInput then UIState.manualHoldInput = nil; setSpam(false) end
    if not context.refs.miniGui.Visible then return end
    local tween = twPlay(context.refs.miniGui, "control", {
      Position = hiddenPosition,
      GroupTransparency = 1,
    })
    UIState.miniTween = tween
    if tween then
      local connection
      connection = trackConn(tween.Completed:Connect(function(playbackState)
        safeDisconnect(connection); untrackConn(connection)
        if playbackState == Enum.PlaybackState.Completed and generation == UIState.miniGeneration and context.refs.miniGui and context.refs.miniGui.Parent then context.refs.miniGui.Visible = false end
      end))
    else
      context.refs.miniGui.Visible = false
    end
    return tween
  end
  setSpam = function(v)
    UIState.spamOn = v; Utils.setManualSpamActive(v)
    local spamButton = context.refs.miniGui and context.refs.miniGui:FindFirstChild("SpamButton")
    if spamButton then
      spamButton.Text = v and "ON" or "OFF"; twPlay(spamButton, "control", { BackgroundColor3 = v and C.green or C.red })
      local shrink = twPlay(spamButton, "press", { Size = UDim2.new(1, -14, 0.78, -12) })
      if shrink then
        local connection
        connection = trackConn(shrink.Completed:Connect(function(playbackState)
          safeDisconnect(connection); untrackConn(connection)
          if playbackState == Enum.PlaybackState.Completed and spamButton.Parent then twPlay(spamButton, "feedback", { Size = UDim2.new(1, -12, 0.78, -8) }) end
        end))
      end
    end
  end
  context.refs.floatingButton = inst("TextButton", {
    Name = "ExodusFloatingButton",
    Size = UDim2.fromOffset(BTN_SIZE * 0.7, BTN_SIZE * 0.7),
    Position = btnPos(),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 1,
    Text = "E",
    TextColor3 = C.text,
    TextTransparency = 1,
    TextSize = 26,
    Font = Enum.Font.GothamBold,
    Active = true,
    ZIndex = 10,
    Parent = context.refs.screenGui,
  })
  corner(context.refs.floatingButton, 999); context.refs.floatingButtonStroke = stroke(context.refs.floatingButton, C.accent, 2)
  context.refs.floatingButtonStroke.Transparency = 1
  task.defer(function()
    if not context.refs.floatingButton or not context.refs.floatingButton.Parent then return end
    twPlay(context.refs.floatingButton, "panel", { BackgroundTransparency = 0.1, TextTransparency = 0, Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE) })
    twPlay(context.refs.floatingButtonStroke, "panel", { Transparency = 0 })
  end)
  local config = Utils.getConfig(); local clashX = config.ClashBallX or 14
  local clashY = config.ClashBallY or (viewport().Y / 2 - CLASH_SIZE / 2)
  context.refs.clashBall = inst("TextButton", {
    Name = "ExodusClashBall",
    Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
    Position = UDim2.new(0, OFFSCREEN_X, 0.5, -CLASH_SIZE / 2),
    BackgroundColor3 = C.red,
    Text = "OFF",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 16,
    Font = Enum.Font.GothamBold,
    Active = true,
    ZIndex = 8,
    Parent = context.refs.screenGui,
  })
  corner(context.refs.clashBall, 999); stroke(context.refs.clashBall, Color3.new(0, 0, 0), 2)
  UIState.clashBallOn = config.AutoSpam or false; context.refs.clashBall.Text = UIState.clashBallOn and "ON" or "OFF"
  context.refs.clashBall.TextSize = UIState.clashBallOn and 18 or 16; context.refs.clashBall.BackgroundColor3 = UIState.clashBallOn and C.green or C.red
  paintClashBall(); local parryX = config.ParryBallX or 14
  local parryY = config.ParryBallY or (viewport().Y / 2 - CLASH_SIZE - 40)
  context.refs.parryBall = inst("TextButton", {
    Name = "ExodusParryBall",
    Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
    Position = UDim2.new(0, OFFSCREEN_X, 0, parryY),
    BackgroundColor3 = config.AutoParry and C.green or C.red,
    Text = config.AutoParry and "PARRY\nON" or "PARRY\nOFF",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    Active = true,
    ZIndex = 8,
    Parent = context.refs.screenGui,
  })
  corner(context.refs.parryBall, 999); stroke(context.refs.parryBall, Color3.new(0, 0, 0), 2)
  paintParryBall(config.AutoParry == true)
  local isParryDragging = makeDraggable(context.refs.parryBall, context.refs.parryBall, function()
    setConfigValue("ParryBallX", context.refs.parryBall.Position.X.Offset); setConfigValue("ParryBallY", context.refs.parryBall.Position.Y.Offset)
  end)
  trackConn(context.refs.parryBall.Activated:Connect(function()
    if not isParryDragging() then
      local value = Utils.getConfigValue("AutoParry") ~= true
      if setConfigValue("AutoParry", value) and context.notifications.toast then context.notifications.toast("Auto Parry " .. (value and "On" or "Off")) end
    end
  end))
  UIState.btnIsDragging = makeDraggable(context.refs.floatingButton, context.refs.floatingButton, function()
    setConfigValue("BtnX", context.refs.floatingButton.Position.X.Offset); setConfigValue("BtnY", context.refs.floatingButton.Position.Y.Offset)
  end)
  trackConn(context.refs.floatingButton.Activated:Connect(function()
    if UIState.btnIsDragging() then return end
    context.window.toggle()
  end))
  local isClashDragging = makeDraggable(context.refs.clashBall, context.refs.clashBall, function()
    setConfigValue("ClashBallX", context.refs.clashBall.Position.X.Offset); setConfigValue("ClashBallY", context.refs.clashBall.Position.Y.Offset)
  end)
  trackConn(context.refs.clashBall.Activated:Connect(function() setClashBall(not UIState.clashBallOn) end))
  local darkX = config.DarkBallX or 14; local darkY = config.DarkBallY or (viewport().Y / 2 + CLASH_SIZE / 2 + 8)
  context.refs.darkBall = inst("TextButton", {
    Name = "ExodusDarkBall",
    Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
    Position = UDim2.new(0, OFFSCREEN_X, 0, darkY),
    BackgroundColor3 = config.AutoDark and C.darkOn or C.darkOff,
    Text = config.AutoDark and "ON" or "OFF",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = config.AutoDark and 18 or 16,
    Font = Enum.Font.GothamBold,
    Active = true,
    ZIndex = 8,
    Parent = context.refs.screenGui,
  })
  corner(context.refs.darkBall, 999); stroke(context.refs.darkBall, Color3.new(0, 0, 0), 2)
  paintDarkBall(config.AutoDark == true)
  local isDarkDragging = makeDraggable(context.refs.darkBall, context.refs.darkBall, function()
    setConfigValue("DarkBallX", context.refs.darkBall.Position.X.Offset); setConfigValue("DarkBallY", context.refs.darkBall.Position.Y.Offset)
  end)
  trackConn(context.refs.darkBall.Activated:Connect(function()
    if isDarkDragging() then return end
    setDarkBall(Utils.getConfigValue("AutoDark") ~= true)
  end))
  local function createMovementBall(name, text, color, xKey, yKey, yOffset, onClick)
    local x = config[xKey] or (CLASH_SIZE + 22); local y = config[yKey] or (viewport().Y / 2 + yOffset)
    local ball = inst("TextButton", {
      Name = name,
      Size = UDim2.new(0, CLASH_SIZE, 0, CLASH_SIZE),
      Position = UDim2.new(0, OFFSCREEN_X, 0, y),
      BackgroundColor3 = color,
      Text = text,
      TextColor3 = Color3.new(1, 1, 1),
      TextSize = 15,
      Font = Enum.Font.GothamBold,
      Active = true,
      ZIndex = 8,
      Parent = context.refs.screenGui,
    })
    corner(ball, 999); stroke(ball, Color3.new(0, 0, 0), 2)
    local dragging = makeDraggable(ball, ball, function()
      setConfigValue(xKey, ball.Position.X.Offset); setConfigValue(yKey, ball.Position.Y.Offset)
    end)
    trackConn(ball.Activated:Connect(function()
      if not dragging() then onClick(ball) end
    end))
    return ball, x, y
  end
  local jumpX, jumpY, upDashX, upDashY
  context.refs.jumpBall, jumpX, jumpY = createMovementBall(
    "ExodusJumpBall",
    config.AutoJump and "JUMP\nON" or "JUMP\nOFF",
    config.AutoJump and C.jumpOn or C.jumpOff,
    "JumpBallX",
    "JumpBallY",
    -CLASH_SIZE / 2,
    function() setJumpBall(Utils.getConfigValue("AutoJump") ~= true) end
  )
  context.refs.upDashBall, upDashX, upDashY = createMovementBall(
    "ExodusUpDashBall",
    "DASH\n↑",
    C.upDash,
    "UpDashBallX",
    "UpDashBallY",
    CLASH_SIZE / 2 + 8,
    function(ball)
      if type(Controls.onUpDash) == "function" then Controls.onUpDash() end
      pulseBall(ball)
      if context.notifications.toast then context.notifications.toast("Up Dash") end
    end
  )
  paintJumpBall(config.AutoJump == true); local _, miniY, miniWidth, miniHeight, miniScreenWidth = miniLayout(tonumber(config.MiniSpamScale) or 1)
  local MINI_OFF_X = miniScreenWidth + 30
  context.refs.miniGui = inst("CanvasGroup", {
    Name = "ExodusSpamMini",
    Visible = false,
    GroupTransparency = 1,
    Size = UDim2.fromOffset(miniWidth, miniHeight),
    BackgroundColor3 = C.header,
    BorderSizePixel = 0,
    ZIndex = 15,
    Parent = context.refs.screenGui,
  })
  corner(context.refs.miniGui, 14)
  corner(
    inst("Frame", {
      Size = UDim2.new(1, 8, 1, 8),
      Position = UDim2.new(0, -4, 0, -4),
      BackgroundColor3 = C.accent,
      BackgroundTransparency = 0.92,
      BorderSizePixel = 0,
      ZIndex = 14,
      Parent = context.refs.miniGui,
    }),
    18
  )
  stroke(context.refs.miniGui, C.accent, 1.5)
  local miniTitleBar = inst("Frame", {
    Size = UDim2.new(1, 0, 0.22, 0),
    BackgroundColor3 = Color3.fromRGB(20, 20, 46),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    ZIndex = 16,
    Parent = context.refs.miniGui,
  })
  corner(miniTitleBar, 14)
  inst("Frame", {
    Size = UDim2.new(1, 0, 0, 12),
    Position = UDim2.new(0, 0, 1, -12),
    BackgroundColor3 = Color3.fromRGB(20, 20, 46),
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    ZIndex = 16,
    Parent = miniTitleBar,
  })
  corner(
    inst("Frame", {
      Size = UDim2.new(0.5, 0, 0, 2),
      Position = UDim2.new(0.25, 0, 0, 0),
      BackgroundColor3 = C.accentPink,
      BorderSizePixel = 0,
      ZIndex = 17,
      Parent = miniTitleBar,
    }),
    1
  )
  inst("TextLabel", {
    Size = UDim2.new(1, -16, 1, 0),
    Position = UDim2.new(0, 8, 0, 0),
    BackgroundTransparency = 1,
    Text = "Spam",
    TextColor3 = C.subtext,
    TextScaled = true,
    TextXAlignment = Enum.TextXAlignment.Center,
    Font = Enum.Font.GothamBold,
    ZIndex = 17,
    Parent = miniTitleBar,
  })
  local spamButton = inst("TextButton", {
    Name = "SpamButton",
    Size = UDim2.new(1, -12, 0.78, -8),
    Position = UDim2.new(0, 6, 0.22, 3),
    BackgroundColor3 = UIState.spamOn and C.green or C.red,
    BorderSizePixel = 0,
    Text = UIState.spamOn and "ON" or "OFF",
    TextColor3 = Color3.new(1, 1, 1),
    TextScaled = true,
    Font = Enum.Font.GothamBold,
    ZIndex = 16,
    Parent = context.refs.miniGui,
  })
  corner(spamButton, 10); inst("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 12 }, spamButton)
  trackConn(spamButton.Activated:Connect(function()
    if Utils.getConfigValue("ManualSpamMode") ~= "Hold" then setSpam(not UIState.spamOn) end
  end))
  trackConn(spamButton.InputBegan:Connect(function(input)
    if Utils.getConfigValue("ManualSpamMode") ~= "Hold" or UIState.manualHoldInput then return end
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then UIState.manualHoldInput = input; setSpam(true) end
  end))
  context.refs.miniGui.Position = UDim2.new(0, MINI_OFF_X, 0, miniY)
  local function saveMiniPosition() Utils.setConfig({ MiniX = context.refs.miniGui.Position.X.Offset, MiniY = context.refs.miniGui.Position.Y.Offset }) end
  makeDraggable(miniTitleBar, context.refs.miniGui, saveMiniPosition, false, miniScreenScale, saveMiniPosition)
  local function sync(changes)
    if changes.AutoSpam ~= nil then UIState.clashBallOn = changes.AutoSpam == true; paintClashBall() end
    if changes.AutoParry ~= nil then paintParryBall(changes.AutoParry == true) end
    if changes.AutoDark ~= nil then paintDarkBall(changes.AutoDark == true) end
    if changes.AutoJump ~= nil then paintJumpBall(changes.AutoJump == true) end
    local visibility = {
      ParryBallVisible = showParryBall,
      ClashBallVisible = showClashBall,
      DarkBallVisible = showDarkBall,
      JumpBallVisible = showJumpBall,
      UpDashBallVisible = showUpDashBall,
      MiniSpamVisible = showMini,
    }

    for key, show in pairs(visibility) do
      if changes[key] ~= nil then show(changes[key] == true) end
    end
    if changes.MiniSpamScale ~= nil or changes.MiniSpamWidth ~= nil or changes.MiniSpamHeight ~= nil then applyMiniScale(Utils.getConfigValue("MiniSpamScale")) end
    if changes.ManualSpamMode ~= nil then UIState.manualHoldInput = nil; setSpam(false) end
  end
  local function updateAbilityVisibility()
    context.pages.refresh(); local enabled = GameInfo.areAbilitiesEnabled() and not UIState.desktop
    context.refs.darkBall.Visible = enabled; context.refs.jumpBall.Visible = enabled
    context.refs.upDashBall.Visible = enabled
  end
  if not UIState.desktop and config.ClashBallVisible then twPlay(context.refs.clashBall, "control", { Position = UDim2.new(0, clashX, 0, clashY) }) end
  if not UIState.desktop and config.ParryBallVisible then twPlay(context.refs.parryBall, "control", { Position = UDim2.new(0, parryX, 0, parryY) }) end
  if not UIState.desktop and config.DarkBallVisible then twPlay(context.refs.darkBall, "control", { Position = UDim2.new(0, darkX, 0, darkY) }) end
  if not UIState.desktop and config.JumpBallVisible then twPlay(context.refs.jumpBall, "control", { Position = UDim2.new(0, jumpX, 0, jumpY) }) end
  if not UIState.desktop and config.UpDashBallVisible then twPlay(context.refs.upDashBall, "control", { Position = UDim2.new(0, upDashX, 0, upDashY) }) end
  showMini(config.MiniSpamVisible == true); setSpam(Utils.isManualSpamActive(), true)
  return {
    setSpam = setSpam,
    showMini = showMini,
    applyMiniScale = applyMiniScale,
    showClashBall = showClashBall,
    showParryBall = showParryBall,
    showDarkBall = showDarkBall,
    showJumpBall = showJumpBall,
    showUpDashBall = showUpDashBall,
    sync = sync,
    refreshAbilities = function()
      updateAbilityVisibility(); trackConn(GameInfo.observeAbilityMode(updateAbilityVisibility))
    end,
  }
end

-- contract
Controller.__contract = { provides = { "setup", "create" }, requires = {} }

return Controller
