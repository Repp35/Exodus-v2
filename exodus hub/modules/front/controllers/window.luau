-- [[ window ]]

-- module
local Controller = {}

-- configuration
local CONFIG = {}

-- setup
function Controller.setup() return true end

-- controller
function Controller.create(context)
  local Utils = context.deps.Utils; local UIState = context.state
  local CONFIG = context.theme; local C = context.theme.COLORS
  local PW = context.theme.PANEL_W; local PH = context.theme.PANEL_H
  local TITLE_H = context.theme.TITLE_H; local PAD = context.theme.PAD
  local BTN_SIZE = context.theme.BTN_SIZE; local PARTICLE_COLORS = context.theme.PARTICLE_COLORS
  local inst = context.inst; local corner = context.corner
  local stroke = context.stroke; local twPlay = context.twPlay
  local safeCancel = context.safeCancel; local setConfigValue = context.setConfigValue
  local trackConn = context.trackConn; local untrackConn = context.untrackConn
  local safeDisconnect = context.safeDisconnect; local makeDraggable = context.makeDraggable
  local makeBtn = context.makeBtn; local _wait = task.wait
  local _spawn = task.spawn
  local function panelPos()
    local config = Utils.getConfig(); local x, y = config.PanelX, config.PanelY
    if type(x) == "number" and type(y) == "number" then return UDim2.new(0, x, 0, y) end
    return UDim2.new(0.5, -PW / 2, 0.5, -PH / 2)
  end
  local function spawnParticle()
    if not context.refs.particleLayer or not context.refs.particleLayer.Parent then return end
    local isFar = math.random() < 0.6; local size = isFar and math.random(2, 3) or math.random(4, 6)
    local startTrans = isFar and 0.5 or 0.2; local color = PARTICLE_COLORS[math.random(1, #PARTICLE_COLORS)]
    local dot = inst("Frame", {
      Size = UDim2.new(0, size, 0, size),
      Position = UDim2.new(math.random(), 0, 1, 0),
      BackgroundColor3 = color,
      BackgroundTransparency = startTrans,
      ZIndex = 4,
      Parent = context.refs.particleLayer,
    })
    corner(dot, 999); local dur = isFar and math.random(5, 9) or math.random(3, 5)
    local endX = math.clamp(dot.Position.X.Scale + (math.random() - 0.5) * 0.15, 0, 1); twPlay(dot, "panel", { BackgroundTransparency = math.max(startTrans - 0.1, 0.05) })
    local travel = twPlay(dot, dur, {
      Position = UDim2.new(endX, 0, -0.1, 0),
      BackgroundTransparency = 1,
    })
    if travel then
      local connection
      connection = trackConn(travel.Completed:Connect(function()
        safeDisconnect(connection); untrackConn(connection)
        if dot.Parent then dot:Destroy() end
      end))
    end
  end
  local function togglePanel()
    if not context.refs.configPanel or not context.refs.configPanel.Parent or not context.refs.floatingButton or not context.refs.floatingButton.Parent then return end
    UIState.panelOpen = not UIState.panelOpen; safeCancel(UIState.panelTween)
    safeCancel(UIState.btnTween)
    if context.kit then context.kit.dismiss() end
    if context.pages then context.pages.suspend() end
    if UIState.panelOpen then
      if not context.refs.configPanel.Visible then context.refs.configPanel.GroupTransparency = 1; context.refs.configPanel.Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97) end
      context.refs.configPanel.Visible = true; UIState.panelTween = twPlay(context.refs.configPanel, "panel", { Size = UDim2.new(0, PW, 0, PH), GroupTransparency = 0 })
      UIState.btnTween = twPlay(context.refs.floatingButton, "control", { BackgroundTransparency = 0.6, TextTransparency = 0, Size = UDim2.new(0, 44, 0, 44) })
    else
      UIState.panelTween = twPlay(context.refs.configPanel, "panel", { Size = UDim2.new(0, PW * 0.97, 0, PH * 0.97), GroupTransparency = 1 })
      UIState.btnTween =
        twPlay(context.refs.floatingButton, "control", { BackgroundTransparency = 0.1, TextTransparency = 0, Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE) })
      if UIState.panelTween then
        local conn
        conn = trackConn(UIState.panelTween.Completed:Connect(function()
          if not UIState.panelOpen then
            context.refs.configPanel.Visible = false; context.refs.configPanel.Size = UDim2.new(0, PW, 0, PH)
            context.refs.configPanel.GroupTransparency = 0
          end
          safeDisconnect(conn); untrackConn(conn)
        end))
      else
        context.refs.configPanel.Visible = false; context.refs.configPanel.Size = UDim2.new(0, PW, 0, PH)
        context.refs.configPanel.GroupTransparency = 0
      end
    end
  end
  context.refs.configPanel = inst("CanvasGroup", {
    Name = "ExodusPanel",
    Size = UDim2.new(0, PW, 0, PH),
    Position = panelPos(),
    BackgroundColor3 = C.bg,
    BackgroundTransparency = 0.03,
    GroupTransparency = 0,
    Visible = false,
    ZIndex = context.theme.LAYERS.panel,
    ClipsDescendants = true,
    Parent = context.refs.screenGui,
  })
  corner(context.refs.configPanel, 16); stroke(context.refs.configPanel, C.accent, 1.5)
  context.refs.particleLayer = inst("Frame", {
    Name = "ParticleLayer",
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    ZIndex = 4,
    ClipsDescendants = true,
    Parent = context.refs.configPanel,
  })
  local particlePanel = context.refs.configPanel
  _spawn(function()
    while context.refs.configPanel == particlePanel and particlePanel.Parent do
      _wait(math.random() * 0.6 + 0.15)
      if context.refs.configPanel == particlePanel and particlePanel.Parent and particlePanel.Visible then spawnParticle() end
    end
  end)
  context.refs.titleBar = inst("Frame", {
    Size = UDim2.new(1, 0, 0, TITLE_H),
    BackgroundColor3 = C.header,
    Active = true,
    ZIndex = 6,
    Parent = context.refs.configPanel,
  })
  corner(context.refs.titleBar, 16)
  makeDraggable(context.refs.titleBar, context.refs.configPanel, function()
    setConfigValue("PanelX", context.refs.configPanel.Position.X.Offset); setConfigValue("PanelY", context.refs.configPanel.Position.Y.Offset)
  end)
  local titleGroup = inst("Frame", {
    Size = UDim2.new(1, -CONFIG.TITLE_SIDE_MARGIN * 2, 1, 0),
    Position = UDim2.new(0, CONFIG.TITLE_SIDE_MARGIN, 0, 0),
    BackgroundTransparency = 1,
    ZIndex = 7,
    Parent = context.refs.titleBar,
  })
  inst("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, CONFIG.TITLE_SPACING),
    Parent = titleGroup,
  })
  inst("TextLabel", {
    Size = UDim2.new(0, 0, 1, 0),
    LayoutOrder = 1,
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundTransparency = 1,
    Text = ("%s | v%s"):format(Utils.name(), Utils.version()),
    TextColor3 = C.text,
    TextSize = CONFIG.TITLE_TEXT_SIZE,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 7,
    Parent = titleGroup,
  })
  inst("TextLabel", {
    Size = UDim2.new(0, 0, 1, 0),
    LayoutOrder = 2,
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundTransparency = 1,
    Text = "— " .. Utils.author(),
    TextColor3 = C.text,
    TextTransparency = CONFIG.AUTHOR_TRANSPARENCY,
    TextSize = CONFIG.AUTHOR_TEXT_SIZE,
    Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 7,
    Parent = titleGroup,
  })
  context.refs.minimizeButton = inst("TextButton", {
    Name = "MinimizePanel",
    Size = UDim2.new(0, 30, 0, 30),
    Position = UDim2.new(1, -PAD - 30, 0.5, -15),
    BackgroundColor3 = C.btnDark,
    BackgroundTransparency = 0.3,
    Text = "",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 14,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = context.refs.titleBar,
  })
  corner(context.refs.minimizeButton, 8); context.kit.icon(context.refs.minimizeButton, "minimize")
  trackConn(context.refs.minimizeButton.MouseEnter:Connect(function() twPlay(context.refs.minimizeButton, "feedback", { BackgroundTransparency = 0 }) end))
  trackConn(context.refs.minimizeButton.MouseLeave:Connect(function() twPlay(context.refs.minimizeButton, "feedback", { BackgroundTransparency = 0.3 }) end))
  trackConn(context.refs.minimizeButton.Activated:Connect(function()
    if UIState.panelOpen then togglePanel() end
  end))
  local settingsButton = inst("TextButton", {
    Name = "HubSettingsButton",
    Size = UDim2.new(0, 30, 0, 30),
    Position = UDim2.new(1, -PAD - 66, 0.5, -15),
    BackgroundColor3 = C.btnDark,
    BackgroundTransparency = 0.3,
    Text = "",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 18,
    Font = Enum.Font.GothamBold,
    ZIndex = 9,
    Parent = context.refs.titleBar,
  })
  corner(settingsButton, 8); context.kit.icon(settingsButton, "settings")
  context.refs.killBtn = inst("TextButton", {
    Size = UDim2.new(0, 124, 0, 26),
    Position = UDim2.new(1, -PAD - 124, 1, -PAD - 26),
    BackgroundColor3 = C.redDark,
    BackgroundTransparency = 0.15,
    Text = "Close Script",
    TextColor3 = Color3.fromRGB(255, 200, 200),
    TextSize = 11,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = context.refs.configPanel,
  })
  corner(context.refs.killBtn, 6)
  trackConn(context.refs.killBtn.Activated:Connect(function() context.lifecycle.animateClose("close") end))
  context.refs.reloadButton = makeBtn("Reload", 0, 0, 124, 26, context.refs.configPanel, C.btnBlue); context.refs.reloadButton.Name = "ReloadHub"
  context.refs.reloadButton.Position = UDim2.new(1, -PAD - 256, 1, -PAD - 26); context.refs.reloadButton.TextSize = 11
  trackConn(context.refs.reloadButton.Activated:Connect(function() context.lifecycle.animateClose("reload") end))
  local previous = inst("TextButton", {
    Name = "PreviousPage",
    Size = UDim2.new(0, 32, 0, 26),
    Position = UDim2.new(0, PAD, 1, -PAD - 26),
    BackgroundColor3 = C.btnDark,
    Text = "",
    TextColor3 = C.text,
    TextSize = 20,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = context.refs.configPanel,
  })
  local pageLabel = inst("TextLabel", {
    Name = "PageLabel",
    Size = UDim2.new(0, 82, 0, 26),
    Position = UDim2.new(0, PAD + 34, 1, -PAD - 26),
    BackgroundTransparency = 1,
    Text = "1/5 Main",
    TextColor3 = C.text,
    TextSize = 9,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = context.refs.configPanel,
  })
  local nextPage = inst("TextButton", {
    Name = "NextPage",
    Size = UDim2.new(0, 32, 0, 26),
    Position = UDim2.new(0, PAD + 118, 1, -PAD - 26),
    BackgroundColor3 = C.btnDark,
    Text = "",
    TextColor3 = C.text,
    TextSize = 20,
    Font = Enum.Font.GothamBold,
    ZIndex = 7,
    Parent = context.refs.configPanel,
  })
  corner(previous, 6); corner(nextPage, 6)
  local previousIcon = context.kit.icon(previous, "chevron", { Rotation = 90 }); local nextIcon = context.kit.icon(nextPage, "chevron", { Rotation = -90 })
  local function updateNavigation(state)
    pageLabel.Text = state.utility and state.title or tostring(state.index) .. "/" .. tostring(state.count) .. " " .. state.title; previous.Visible = not state.utility
    nextPage.Visible = not state.utility; previous.Active = state.index ~= nil and state.index > 1
    previous.Selectable = previous.Active; nextPage.Active = state.index ~= nil and state.index < state.count
    nextPage.Selectable = nextPage.Active; previousIcon.ImageTransparency = previous.Active and 0 or 0.7
    nextIcon.ImageTransparency = nextPage.Active and 0 or 0.7; settingsButton.BackgroundColor3 = state.id == "config" and C.accent or C.btnDark
  end
  trackConn(settingsButton.Activated:Connect(function() context.pages.toggle("config") end))
  trackConn(previous.Activated:Connect(function() context.pages.step(-1) end))
  trackConn(nextPage.Activated:Connect(function() context.pages.step(1) end))
  return { toggle = togglePanel, updateNavigation = updateNavigation }
end

-- contract
Controller.__contract = { provides = { "setup", "create" }, requires = {} }

return Controller
