-- [[ uitheme ]]

-- module
local Theme = {}

-- configuration
local CONFIG = {
  COLORS = {
    bg = Color3.fromRGB(8, 8, 22),
    header = Color3.fromRGB(14, 14, 34),
    card = Color3.fromRGB(20, 20, 44),
    accent = Color3.fromRGB(99, 102, 241),
    accentPink = Color3.fromRGB(236, 72, 153),
    autoMode = Color3.fromRGB(16, 154, 201),
    green = Color3.fromRGB(34, 197, 94),
    red = Color3.fromRGB(239, 68, 68),
    redDark = Color3.fromRGB(153, 27, 27),
    text = Color3.fromRGB(240, 240, 255),
    subtext = Color3.fromRGB(140, 140, 200),
    border = Color3.fromRGB(55, 55, 100),
    btnBlue = Color3.fromRGB(45, 55, 130),
    btnDark = Color3.fromRGB(30, 30, 65),
    toggleOn = Color3.fromRGB(139, 92, 246),
    toggleOff = Color3.fromRGB(45, 45, 80),
    darkOn = Color3.fromRGB(151, 66, 221),
    darkOff = Color3.fromRGB(52, 34, 87),
    jumpOn = Color3.fromRGB(16, 154, 201),
    jumpOff = Color3.fromRGB(24, 72, 105),
    upDash = Color3.fromRGB(226, 135, 36),
    hold = Color3.fromRGB(236, 72, 153),
    inputBg = Color3.fromRGB(16, 16, 38),
  },
  GRADIENT = {
    Color3.fromRGB(178, 215, 255),
    Color3.fromRGB(227, 198, 255),
    Color3.fromRGB(178, 215, 255),
  },
  PARTICLE_COLORS = {
    Color3.fromRGB(85, 90, 140),
    Color3.fromRGB(110, 95, 150),
    Color3.fromRGB(150, 95, 130),
    Color3.fromRGB(95, 130, 165),
  },
  BTN_SIZE = 56,
  CLASH_SIZE = 64,
  MINI_W = 112,
  MINI_H = 96,
  PANEL_W = 540,
  PANEL_H = 380,
  TITLE_H = 50,
  PAD = 14,
  GAP = 12,
  CARD_GAP = 8,
  CARD_H = 48,
  RATE_CARD_H = 64,
  DRAG_THRESHOLD_SQ = 100,
  TITLE_SIDE_MARGIN = 90,
  TITLE_SPACING = 7,
  TITLE_TEXT_SIZE = 16,
  AUTHOR_TEXT_SIZE = 14,
  AUTHOR_TRANSPARENCY = 0.22,
}

CONFIG.COLORS.cardHover = Color3.fromRGB(24, 24, 50)
CONFIG.RADIUS = { panel = 16, card = 12, control = 8, pill = 999 }
CONFIG.FONT = { body = Enum.Font.Gotham, label = Enum.Font.GothamSemibold, strong = Enum.Font.GothamBold }
CONFIG.TEXT = { body = 12, caption = 10, control = 13, title = 16 }
CONFIG.MOTION = {
  press = {
    duration = 0.08,
    style = Enum.EasingStyle.Cubic,
    direction = Enum.EasingDirection.Out,
  },
  feedback = {
    duration = 0.16,
    style = Enum.EasingStyle.Cubic,
    direction = Enum.EasingDirection.Out,
  },
  control = {
    duration = 0.22,
    style = Enum.EasingStyle.Cubic,
    direction = Enum.EasingDirection.Out,
  },
  page = {
    duration = 0.28,
    style = Enum.EasingStyle.Cubic,
    direction = Enum.EasingDirection.Out,
  },
  panel = {
    duration = 0.28,
    style = Enum.EasingStyle.Cubic,
    direction = Enum.EasingDirection.Out,
  },
}
CONFIG.SELECTOR_COLORS = {
  CPS = CONFIG.COLORS.accent,
  CPF = CONFIG.COLORS.accentPink,
  MS = Color3.fromRGB(234, 179, 8),
  Auto = CONFIG.COLORS.autoMode,
  Toggle = CONFIG.COLORS.accent,
  Hold = CONFIG.COLORS.hold,
}
CONFIG.DROPDOWN = { gap = 5, margin = 6, rowHeight = 32, rowGap = 3, padding = 4, selectionDelay = 0.18 }
CONFIG.PAGE_OFFSET = 18
CONFIG.SCROLLBAR = 3
CONFIG.LAYERS = { panel = 30 }
CONFIG.CHILD_VERTICAL_PADDING = 6

-- public-api
Theme.tokens = CONFIG

-- setup
function Theme.setup() return true end

-- contract
Theme.__contract = { provides = { "setup" }, data = { "tokens" }, requires = {} }

return Theme
