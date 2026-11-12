-- [[ uiconfig ]]

-- module
local UIConfig = {}

-- configuration
local CONFIG = {
  PANEL_TOGGLES = {
    {
      kind = "toggle",
      title = "Auto Parry",
      key = "AutoParry",
    },
    {
      kind = "toggle",
      title = "Auto Spam",
      key = "AutoSpam",
    },
    {
      kind = "toggle",
      title = "Mini Parry UI",
      description = "Exibe um botão compacto para controlar o parry.",
      key = "ParryBallVisible",
      mobileOnly = true,
    },
    {
      kind = "toggle",
      title = "Mini Clash UI",
      description = "Exibe um botão compacto para controlar o spam.",
      key = "ClashBallVisible",
      mobileOnly = true,
    },
  },
  PANEL_COMPONENTS = {
    {
      kind = "rate_selector",
      title = "Spam Rate",
    },
    {
      kind = "off_on",
      title = "Manual Spam",
      mobileKey = "MiniSpamVisible",
      desktopKey = "ManualSpamEnabled",
      shortcutKey = "SpamKeybind",
      mobileToast = "Manual Spam UI",
    },
    {
      kind = "keybind_selector",
      title = "Stop Functions",
    },
  },
  PAGES = {
    indeed = {
      title = "Indeed",
      components = {
        {
          kind = "click",
          title = "Dumper",
          description = "Salva scripts e informações acessíveis do jogo.",
          action = "dumper",
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
