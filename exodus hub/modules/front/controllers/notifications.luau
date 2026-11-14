-- [[ notifications ]]

-- module
local Controller = {}

-- configuration
local CONFIG = {}

-- setup
function Controller.setup() return true end

-- controller
function Controller.create(context)
  local Utils = context.deps.Utils; local UIState = context.state
  local C = context.theme.COLORS; local Players = context.services.Players
  local inst = context.inst; local corner = context.corner
  local stroke = context.stroke; local twPlay = context.twPlay
  local safeCancel = context.safeCancel; local trackConn = context.trackConn
  local untrackConn = context.untrackConn; local safeDisconnect = context.safeDisconnect
  local NotificationPolicy = context.deps.NotificationPolicy; local state = { order = {}, tweens = {}, generation = 0 }
  local showToast, showPersistentNotification, clearPersistentNotification
  local function persistentKey(value) return tostring(value or "general"):gsub("[^%w_%-]", "_") end
  local function persistentPalette(kind)
    if kind == "critical" then return C.redDark, C.red end
    if kind == "success" then return Color3.fromRGB(20, 92, 58), C.green end
    if kind == "warning" then return Color3.fromRGB(100, 67, 18), Color3.fromRGB(245, 158, 11) end
    return C.btnBlue, C.accent
  end
  local function persistentLayerForPlayer()
    local player = Players.LocalPlayer; local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return nil end
    state.gui = playerGui:FindFirstChild("ExodusPersistentNotifications")
    if not state.gui then
      state.gui = inst("ScreenGui", {
        Name = "ExodusPersistentNotifications",
        DisplayOrder = 2147483647,
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Global,
        Parent = playerGui,
      })
    end
    state.layer = state.gui:FindFirstChild("NotificationLayer")
    if not state.layer then
      state.layer = inst("Frame", {
        Name = "NotificationLayer",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        ZIndex = 100,
        Parent = state.gui,
      })
    end
    for _, child in ipairs(state.layer:GetChildren()) do
      local key = child:GetAttribute("ExodusNotificationKey")
      if key and not table.find(state.order, key) then state.order[#state.order + 1] = key end
    end
    return state.layer
  end
  local function reflowPersistentNotifications(animated)
    local layer = state.layer or persistentLayerForPlayer()
    if not layer then return end
    for index = #state.order, 1, -1 do
      local key = state.order[index]
      if not layer:FindFirstChild("Notification_" .. key) then table.remove(state.order, index) end
    end
    for index, key in ipairs(state.order) do
      local card = layer:FindFirstChild("Notification_" .. key)
      if card then
        safeCancel(state.tweens[key]); local target = UDim2.new(0.5, 0, 1, -24 - (index - 1) * 46)
        state.tweens[key] = twPlay(card, animated and "control" or 0, { Position = target, GroupTransparency = 0 })
      end
    end
  end
  clearPersistentNotification = function(key)
    local safeKey = persistentKey(key); local layer = state.layer
    if not layer then
      local player = Players.LocalPlayer; local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
      local gui = playerGui and playerGui:FindFirstChild("ExodusPersistentNotifications"); layer = gui and gui:FindFirstChild("NotificationLayer")
    end
    if not layer then return end
    local card = layer:FindFirstChild("Notification_" .. safeKey)
    for index = #state.order, 1, -1 do
      if state.order[index] == safeKey then table.remove(state.order, index) end
    end
    if not card then
      state.tweens[safeKey] = nil; reflowPersistentNotifications(true)
      return
    end
    safeCancel(state.tweens[safeKey])
    local fade = twPlay(card, "control", {
      Position = UDim2.new(card.Position.X.Scale, card.Position.X.Offset, card.Position.Y.Scale, card.Position.Y.Offset + 18),
      GroupTransparency = 1,
    })
    state.tweens[safeKey] = fade
    local function remove()
      if state.tweens[safeKey] ~= fade then return end
      state.tweens[safeKey] = nil
      if card.Parent then card:Destroy() end
      reflowPersistentNotifications(true)
    end
    if fade then
      local connection
      connection = fade.Completed:Connect(function()
        safeDisconnect(connection); remove()
      end)
    else
      remove()
    end
  end
  showPersistentNotification = function(message, key, kind, duration)
    local safeKey = persistentKey(key or message); local category = (safeKey == "update" or safeKey == "closing") and "lifecycle" or (kind == "critical" and "critical" or "system")
    if Utils and NotificationPolicy and not NotificationPolicy.shouldShow(Utils.getConfig(), UIState.desktop, { category = category, topic = safeKey }) then return false end
    local layer = persistentLayerForPlayer()
    if not layer then return false end
    local card = layer:FindFirstChild("Notification_" .. safeKey); local background, border = persistentPalette(kind)
    if not card then
      card = inst("CanvasGroup", {
        Name = "Notification_" .. safeKey,
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, 18),
        Size = UDim2.fromOffset(320, 38),
        BackgroundColor3 = background,
        BackgroundTransparency = 0.12,
        GroupTransparency = 1,
        ZIndex = 100,
        Parent = layer,
      })
      card:SetAttribute("ExodusNotificationKey", safeKey); corner(card, 10)
      stroke(card, border, 1)
      inst("TextLabel", {
        Name = "Message",
        Size = UDim2.new(1, -20, 1, 0),
        Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1,
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 13,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextYAlignment = Enum.TextYAlignment.Center,
        ZIndex = 101,
        Parent = card,
      })
      state.order[#state.order + 1] = safeKey
    end
    card.BackgroundColor3 = background; local cardStroke = card:FindFirstChildOfClass("UIStroke")
    if cardStroke then cardStroke.Color = border end
    local label = card:FindFirstChild("Message")
    if label then label.Text = tostring(message) end
    if duration == nil and safeKey ~= "dumper" then duration = 2.5 end
    state.generation += 1; local generation = state.generation
    card:SetAttribute("ExodusNotificationGeneration", generation); reflowPersistentNotifications(true)
    if duration and duration > 0 then
      task.delay(duration, function()
        if context.scope.alive and card.Parent and card:GetAttribute("ExodusNotificationGeneration") == generation then clearPersistentNotification(safeKey) end
      end)
    end
    return true
  end
  showToast = function(message, important, event)
    event = event or { category = "interaction" }
    if important then event = { category = "critical" } end
    if not NotificationPolicy.shouldShow(Utils.getConfig(), UIState.desktop, event) then return end
    if not context.refs.toastLayer or not context.refs.toastLayer.Parent then return end
    UIState.toastGeneration += 1; local generation = UIState.toastGeneration
    safeCancel(UIState.toastTween); local isOff = string.find(tostring(message), " Off", 1, true) ~= nil
    if not context.refs.toastCard or not context.refs.toastCard.Parent or context.refs.toastCard.Parent ~= context.refs.toastLayer then
      context.refs.toastCard = inst("CanvasGroup", {
        Name = "ExodusToast",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, 18),
        Size = UDim2.fromOffset(190, 34),
        BackgroundTransparency = 0.18,
        GroupTransparency = 1,
        ZIndex = 200,
        Parent = context.refs.toastLayer,
      })
      corner(context.refs.toastCard, 10); stroke(context.refs.toastCard, C.accent, 1)
      context.refs.toastLabel = inst("TextLabel", {
        Size = UDim2.new(1, -16, 1, 0),
        Position = UDim2.new(0, 8, 0, 0),
        BackgroundTransparency = 1,
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 13,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 201,
        Parent = context.refs.toastCard,
      })
    end
    context.refs.toastCard.BackgroundColor3 = isOff and C.redDark or C.btnBlue; local toastStroke = context.refs.toastCard:FindFirstChildOfClass("UIStroke")
    if toastStroke then toastStroke.Color = isOff and C.red or C.accent end
    if context.refs.toastLabel then context.refs.toastLabel.Text = tostring(message) end
    context.refs.toastCard.Position = UDim2.new(0.5, 0, 1, 18); context.refs.toastCard.GroupTransparency = 1
    local toast = context.refs.toastCard; UIState.toastTween = twPlay(toast, "control", { Position = UDim2.new(0.5, 0, 1, -24), GroupTransparency = 0 })
    task.delay(1.35, function()
      if generation ~= UIState.toastGeneration or not toast.Parent then return end
      local fade = twPlay(toast, "control", { Position = UDim2.new(0.5, 0, 1, 18), GroupTransparency = 1 }); UIState.toastTween = fade
      if fade then
        local connection
        connection = trackConn(fade.Completed:Connect(function(playbackState)
          safeDisconnect(connection); untrackConn(connection)
          if playbackState ~= Enum.PlaybackState.Completed then return end
          if generation == UIState.toastGeneration and toast == context.refs.toastCard then
            context.refs.toastCard = nil; context.refs.toastLabel = nil
            UIState.toastTween = nil
            if toast.Parent then toast:Destroy() end
          end
        end))
      end
    end)
  end
  return { toast = showToast, persistent = showPersistentNotification, clear = clearPersistentNotification, layer = persistentLayerForPlayer, state = state }
end

-- contract
Controller.__contract = { provides = { "setup", "create" }, requires = {} }

return Controller
