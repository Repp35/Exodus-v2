-- [[ uiconfig ]]

-- module
local UIConfig = {}

-- configuration
local CONFIG = {
  PANEL_TOGGLES = {
    {
      kind = "toggle",
      title = "Auto Parry",
      description = "Automatically deflect incoming attacks.",
      key = "AutoParry",
    },
    {
      kind = "toggle",
      title = "Mini Parry UI",
      description = "Show the compact Auto Parry control.",
      key = "ParryBallVisible",
      mobileOnly = true,
    },
    {
      kind = "toggle",
      title = "Auto Spam",
      description = "Enable automatic clash spam.",
      key = "AutoSpam",
    },
    {
      kind = "toggle",
      title = "Mini Clash UI",
      description = "Show the compact Auto Spam control.",
      key = "ClashBallVisible",
      mobileOnly = true,
    },
  },
  PANEL_COMPONENTS = {
    {
      kind = "rate_selector",
      title = "Spam Rate",
      description = "Choose the spam rate mode and value.",
    },
    {
      kind = "keybind_selector",
      title = "Stop Functions",
      description = "Assign a shortcut that stops active functions.",
    },
    {
      kind = "toggle",
      control = "status",
      title = "Manual Spam",
      description = "Show or enable the manual spam control.",
      mobileKey = "MiniSpamVisible",
      desktopKey = "ManualSpamEnabled",
      shortcutKey = "SpamKeybind",
      mobileToast = "Manual Spam UI",
    },
  },
  PAGES = {
    indeed = {
      title = "Indeed",
      components = {
        {
          kind = "click",
          title = "Dumper",
          description = "Capture accessible client scripts, remotes and metadata.",
          action = "dumper",
          actionText = "Run",
        },
      },
    },
  },
  SETTINGS = {
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
  },
}

-- public-api
UIConfig.panelToggles = CONFIG.PANEL_TOGGLES
UIConfig.panelComponents = CONFIG.PANEL_COMPONENTS
UIConfig.pages = CONFIG.PAGES
UIConfig.__config = CONFIG.SETTINGS

-- contract
UIConfig.__contract = {
  provides = {},
  data = { "panelToggles", "panelComponents", "pages" },
  requires = {},
}

return UIConfig
