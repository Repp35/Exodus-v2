-- [[ input ]]

-- module
local Controller = {}

-- configuration
local CONFIG = {}

-- setup
function Controller.setup() return true end

-- controller
function Controller.create(context)
  local Utils = context.deps.Utils; local UIState = context.state
  local UIS = context.services.UIS; local trackConn = context.trackConn
  local function inputBinding(input)
    if input.UserInputType == Enum.UserInputType.Keyboard then return input.KeyCode end
    if
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.MouseButton2
      or input.UserInputType == Enum.UserInputType.MouseButton3
    then
      return input.UserInputType
    end
    return nil
  end
  local function isKey(input, binding) return input and binding and binding ~= Enum.KeyCode.Unknown and inputBinding(input) == binding end
  local function bindInput(actions)
    trackConn(UIS.InputBegan:Connect(function(input, gameProcessed)
      if gameProcessed or UIState.keyCapture or context.kit.isCapturing(input) or UIS:GetFocusedTextBox() or not UIState.desktop or not inputBinding(input) then return end
      if UIState.closing then return end
      local config = Utils.getConfig() or {}
      if isKey(input, config.Keybind) then
        actions.triggerShortcut(inputBinding(input))
      elseif isKey(input, config.SpamKeybind) then
        if config.ManualSpamMode == "Hold" then
          if not UIState.manualHoldInput then UIState.manualHoldInput = input; context.floating.setSpam(true) end
        else
          context.floating.setSpam(not UIState.spamOn)
        end
      else
        actions.triggerShortcut(inputBinding(input))
      end
    end))
    trackConn(UIS.InputEnded:Connect(function(input)
      local held = UIState.manualHoldInput
      if held and (held == input or (inputBinding(held) and inputBinding(held) == inputBinding(input))) then UIState.manualHoldInput = nil; context.floating.setSpam(false) end
    end))
    trackConn(UIS.WindowFocusReleased:Connect(function()
      if UIState.manualHoldInput then UIState.manualHoldInput = nil; context.floating.setSpam(false) end
    end))
  end
  bindInput(context.actions); return {}
end

-- contract
Controller.__contract = { provides = { "setup", "create" }, requires = {} }

return Controller
