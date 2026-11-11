-- [[ uiconfig ]]

-- module
local UIConfig = {}

-- configuration
local CONFIG = {
  PANEL_TOGGLES = {
    {
      kind = "toggle",
      label = "Auto Parry",
      key = "AutoParry",
    },
    {
      kind = "toggle",
      label = "Mini Parry UI",
      key = "ParryBallVisible",
      mobileOnly = true,
    },
    {
      kind = "toggle",
      label = "Auto Spam",
      key = "AutoSpam",
    },
    {
      kind = "toggle",
      label = "Mini Clash UI",
      key = "ClashBallVisible",
      mobileOnly = true,
    },
  },
  PANEL_COMPONENTS = {
    {
      kind = "rate_selector",
    },
    {
      kind = "keybind_selector",
    },
    {
      kind = "off_on",
      label = "Manual Spam",
      mobileKey = "MiniSpamVisible",
      desktopKey = "ManualSpamEnabled",
      shortcutKey = "SpamKeybind",
      mobileToast = "Manual Spam UI",
    },
  },
  SETTINGS = {
    schema = {
      MobileNotifications = "boolean",
      DesktopNotifications = "boolean",
      AutoParry = "boolean",
      AutoParryWindowFactor = "windowFactor",
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
  },
}

-- public-api
UIConfig.panelToggles = CONFIG.PANEL_TOGGLES
UIConfig.panelComponents = CONFIG.PANEL_COMPONENTS
UIConfig.__config = CONFIG.SETTINGS

-- contract
UIConfig.__contract = {
  provides = {},
  data = { "panelToggles", "panelComponents" },
  requires = {},
}

return UIConfig
