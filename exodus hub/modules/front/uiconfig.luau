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
      sections = {
        {
          title = "Developer Tools",
          components = {
            {
              kind = "click",
              title = "Dumper",
              description = "Salva scripts e informações acessíveis do jogo.",
              action = "dumper",
            },
          },
        },
        {
          title = "Universal Controls",
          components = {
            { kind = "click", title = "Lay", description = "Deita o personagem.", action = "Lay" },
            { kind = "toggle", title = "Infinite Jump", description = "Permite pular no ar.", key = "UniversalInfiniteJump", feature = "InfiniteJump" },
            { kind = "toggle", title = "Fly", description = "Permite voar livremente.", key = "UniversalFly", feature = "Fly" },
            { kind = "scroll", title = "Speed", description = "Ajusta a velocidade do personagem.", key = "UniversalSpeed", feature = "Speed", min = 0, max = 200, increment = 1, valueName = "WalkSpeed" },
            { kind = "scroll", title = "Gravity", description = "Ajusta a gravidade do personagem.", key = "UniversalGravity", feature = "Gravity", min = 0, max = 400, increment = 1, valueName = "studs/s²" },
            { kind = "toggle", title = "Invisicam", description = "Remove o personagem da visão da câmera.", key = "UniversalInvisicam", feature = "Invisicam" },
            { kind = "toggle", title = "Noclip", description = "Permite atravessar objetos.", key = "UniversalNoclip", feature = "Noclip" },
          },
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
