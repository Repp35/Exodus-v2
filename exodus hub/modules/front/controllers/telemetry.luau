-- [[ telemetry ]]

-- module
local Controller = {}

-- configuration
local CONFIG = {}

-- setup
function Controller.setup() return true end

-- controller
function Controller.create(context)
  local playerGui = context.playerGui; local Utils = context.deps.Utils
  local GameInfo = context.deps.GameInfo; local AutoSpam = context.deps.AutoSpam
  local C = context.theme.COLORS; local RunService = context.services.RunService
  local Players = context.services.Players; local inst = context.inst
  local corner = context.corner; local twPlay = context.twPlay
  local setTextIfChanged = context.setTextIfChanged; local trackConn = context.trackConn
  local untrackConn = context.untrackConn; local safeDisconnect = context.safeDisconnect
  context.refs.informationGui = inst("ScreenGui", {
    Name = "ExodusInformationOverlay",
    DisplayOrder = 2147483647,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Global,
    Parent = playerGui,
  })
  context.refs.toastLayer = inst("Frame", {
    Name = "ExodusToastLayer",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    ZIndex = 199,
    Parent = context.refs.informationGui,
  })
  local textService = game:GetService("TextService")
  local function compactInformation(label)
    local paddingX, paddingY = 8, 5; label.TextSize = 14
    label.TextWrapped = false; label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top; label.BorderSizePixel = 0
    label.ZIndex = 100; label.BackgroundTransparency = 1
    label.TextTransparency = 1; label.Visible = false
    corner(label, 8)
    inst("UIPadding", {
      PaddingLeft = UDim.new(0, paddingX),
      PaddingRight = UDim.new(0, paddingX),
      PaddingTop = UDim.new(0, paddingY),
      PaddingBottom = UDim.new(0, paddingY),
      Parent = label,
    })
    local function resize()
      local bounds = textService:GetTextSize(label.Text, label.TextSize, label.Font, Vector2.new(1000, 1000))
      label.Size = UDim2.fromOffset(math.ceil(bounds.X) + paddingX * 2, math.ceil(bounds.Y) + paddingY * 2)
    end
    trackConn(label:GetPropertyChangedSignal("Text"):Connect(resize)); resize()
    local shown, activeTween = false, nil
    return function(visible)
      if shown == visible then return end
      shown = visible
      if activeTween then activeTween:Cancel() end
      if visible then label.Visible = true end
      local transition = twPlay(label, "control", {
        BackgroundTransparency = visible and 0.2 or 1,
        TextTransparency = visible and 0 or 1,
      })
      activeTween = transition
      if transition then
        local connection
        connection = trackConn(transition.Completed:Connect(function(playbackState)
          safeDisconnect(connection); untrackConn(connection)
          if activeTween ~= transition then return end
          activeTween = nil
          if playbackState == Enum.PlaybackState.Completed and not shown then label.Visible = false end
        end))
      elseif not shown then
        label.Visible = false
      end
    end
  end
  local distanceLabel = inst("TextLabel", {
    Name = "ClashDistance",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 0),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 0.2,
    Text = "Current SPD: —\nClash: —\nCPS: —",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = Utils.getConfigValue("ClashDistanceVisible") == true,
    ZIndex = 20,
    Parent = context.refs.informationGui,
  })
  local travelLabel = inst("TextLabel", {
    Name = "ClashTravelTime",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -20),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 0.2,
    Text = "Ball travel time: —",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = Utils.getConfigValue("ClashTravelTimeVisible") == true,
    ZIndex = 20,
    Parent = context.refs.informationGui,
  })
  local gateLabel = inst("TextLabel", {
    Name = "AutoSpamGateInfo",
    Size = UDim2.fromOffset(1, 1),
    AnchorPoint = Vector2.new(0, 0.5),
    Position = UDim2.new(0, 0, 0.5, 0),
    BackgroundColor3 = C.header,
    BackgroundTransparency = 1,
    TextTransparency = 1,
    Text = "",
    TextColor3 = C.text,
    TextSize = 14,
    Font = Enum.Font.GothamSemibold,
    Visible = false,
    ZIndex = 20,
    Parent = context.refs.informationGui,
  })
  local setDistanceVisible = compactInformation(distanceLabel); local setTravelVisible = compactInformation(travelLabel)
  local setGateVisible = compactInformation(gateLabel); local nextGateUpdate, nextTravelUpdate, nextDistanceUpdate = 0, 0, 0
  local function validGate(value)
    return type(value) == "string" and value ~= "" and value ~= "null" and value ~= "nil" and value ~= "inactive" and value ~= "detached"
  end
  local telemetryAt, telemetryStatus, telemetrySnapshot = -math.huge, nil, nil
  local function getTelemetry(time)
    if time < telemetryAt or time - telemetryAt >= 1 / 30 then telemetryAt, telemetryStatus, telemetrySnapshot = time, AutoSpam.getStatus(), GameInfo.getSnapshotAt(time) end
    return telemetryStatus, telemetrySnapshot
  end
  local function formatSpeed(snapshot)
    if not GameInfo.isSnapshotValid(snapshot) then return "—" end
    local speed = tonumber(snapshot.syncSpeed)
    if not speed or speed ~= speed or speed <= 0 or speed == math.huge then speed = snapshot.speed end
    return type(speed) == "number" and speed == speed and speed >= 0 and speed < math.huge and string.format("%.0f", speed) or "—"
  end
  local function updateInformation()
    if not context.refs.informationGui.Parent then return end
    local time = os.clock(); local gateEnabled = Utils.getConfigValue("ClashGateInfoVisible") == true
    local travelVisible = Utils.getConfigValue("ClashTravelTimeVisible") == true; local distanceVisible = Utils.getConfigValue("ClashDistanceVisible") == true
    if not gateEnabled and not travelVisible and not distanceVisible then
      setGateVisible(false); setTravelVisible(false)
      setDistanceVisible(false); return
    end
    if gateEnabled and time >= nextGateUpdate then
      nextGateUpdate = time + 0.1; local status = AutoSpam.getStatus()
      local lines = { "AutoSpam: " .. (status and status.active == true and "ACTIVE" or "WAITING") }
      if status and validGate(status.lastGate) then lines[#lines + 1] = "State: " .. status.lastGate end
      if status and validGate(status.lastActivationReason) then lines[#lines + 1] = "Activation: " .. status.lastActivationReason end
      if status and validGate(status.lastStopReason) then lines[#lines + 1] = "Deactivation: " .. status.lastStopReason end
      setTextIfChanged(gateLabel, table.concat(lines, "\n"))
    end
    local gateVisible = gateEnabled and gateLabel.Text ~= ""; setGateVisible(gateVisible)
    setTravelVisible(travelVisible)
    if travelVisible and time >= nextTravelUpdate then
      nextTravelUpdate = time + 0.05; local status, snapshot = getTelemetry(time)
      local stats = status and status.clashStats; local speedText = formatSpeed(snapshot)
      if not stats then
        setTextIfChanged(travelLabel, "Current SPD: " .. speedText .. "\nBall travel time: —")
      else
        local me = Players.LocalPlayer and Players.LocalPlayer.UserId
        local text
        if stats.frozen then
          if stats.deceasedId then
            local who = stats.deceasedId == me and "You" or "Opponent"; local value = stats.fatalTravelTime and string.format("%.0f ms", stats.fatalTravelTime * 1000) or "unavailable"
            local previousWho = stats.penultimateTarget == me and "you" or (stats.penultimateTarget == stats.partnerId and "opponent" or "—")
            local previous = stats.penultimateTravelTime and string.format("%.0f ms", stats.penultimateTravelTime * 1000) or "unavailable"
            text = who .. " died\nTarget time to death: " .. value .. "\nPrevious (" .. previousWho .. "): " .. previous
          else
            text = "Clash ended\nFinal time: unavailable"
          end
        else
          local value = stats.travelStartedAt and string.format("%.0f ms", math.max(0, time - stats.travelStartedAt) * 1000) or "—"
          local who = stats.travelTarget == me and "You" or (stats.travelTarget == stats.partnerId and "Opponent" or "—")
          local last = stats.lastTravelTime and string.format("%.0f ms", stats.lastTravelTime * 1000) or "—"
          local lastWho = stats.lastTravelTarget == me and "you" or (stats.lastTravelTarget == stats.partnerId and "opponent" or "—")
          text = "Target: " .. who .. " | Time: " .. value .. "\nLast exchange (" .. lastWho .. "): " .. last
        end
        setTextIfChanged(travelLabel, "Current SPD: " .. speedText .. "\n" .. text)
      end
    end
    setDistanceVisible(distanceVisible)
    if not distanceVisible or time < nextDistanceUpdate then return end
    nextDistanceUpdate = time + 0.1; local status, snapshot = getTelemetry(time)
    local stats = status and status.clashStats; local speedText = formatSpeed(snapshot)
    local text
    if stats and (not stats.frozen or stats.endReason == "jogador morreu") then
      local function sampleText(sample)
        if not sample then return "—" end
        local distance = type(sample.distance) == "number" and string.format("%.1f", sample.distance) or "?"
        local speed = type(sample.speed) == "number" and string.format("%.0f", sample.speed) or "?"; return distance .. " studs | SPD " .. speed
      end
      local cps = type(stats.currentCps) == "number" and string.format("%.2f", stats.currentCps) or "—"
      text = string.format(
        "Current SPD: %s\nStart: %s\n%s: %s\nCurrent CPS: %s | %.2fs",
        speedText,
        sampleText(stats.startSample),
        stats.frozen and (stats.endReason == "jogador morreu" and "Player died" or (stats.endReason == "oponente morreu" and "Opponent died" or "End"))
          or "Current",
        sampleText(stats.endSample),
        cps,
        stats.duration or 0
      )
    else
      text = "Current SPD: " .. speedText .. "\nClash: —\nCurrent CPS: —"
    end
    setTextIfChanged(distanceLabel, text)
  end
  trackConn(RunService.Heartbeat:Connect(updateInformation)); return {}
end

-- contract
Controller.__contract = { provides = { "setup", "create" }, requires = {} }

return Controller
