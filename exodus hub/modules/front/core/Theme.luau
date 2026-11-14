-- Semantic design tokens. No component owns a private palette or motion scale.
local Theme = {}
Theme.default = {
  colors = {
    background = Color3.fromRGB(8, 8, 22),
    surface = Color3.fromRGB(14, 14, 34),
    elevated = Color3.fromRGB(20, 20, 44),
    input = Color3.fromRGB(16, 16, 38),
    hover = Color3.fromRGB(30, 30, 65),
    border = Color3.fromRGB(55, 55, 100),
    accent = Color3.fromRGB(99, 102, 241),
    secondary = Color3.fromRGB(236, 72, 153),
    toggleOn = Color3.fromRGB(139, 92, 246),
    toggleOff = Color3.fromRGB(45, 45, 80),
    button = Color3.fromRGB(45, 55, 130),
    text = Color3.fromRGB(240, 240, 255),
    muted = Color3.fromRGB(160, 160, 200),
    success = Color3.fromRGB(34, 197, 94),
    danger = Color3.fromRGB(239, 68, 68),
    destructive = Color3.fromRGB(153, 27, 27),
    warning = Color3.fromRGB(245, 183, 64),
    info = Color3.fromRGB(16, 154, 201),
    outlineStart = Color3.fromRGB(178, 215, 255),
    outlineEnd = Color3.fromRGB(227, 198, 255),
  },
  space = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 },
  radius = { small = 6, control = 8, card = 12, window = 16, pill = 999 },
  transparency = { window = 0.16, header = 0.08, card = 0.1, input = 0.15, button = 0.1 },
  size = { small = 26, control = 30, large = 36, row = 48, header = 50, sidebar = 112, breakpoint = 440, windowWidth = 600, windowHeight = 400 },
  text = { caption = 10, body = 13, title = 16, heading = 18 },
  font = { regular = Enum.Font.Gotham, medium = Enum.Font.GothamMedium, bold = Enum.Font.GothamBold },
  motion = { fast = 0.12, normal = 0.2, slow = 0.3 },
}
local function merge(base, patch)
  local result = {}
  for k, value in pairs(base) do
    local override = patch and patch[k]
    if typeof(value) == "table" then
      result[k] = merge(value, override)
    else
      if override ~= nil then
        assert(typeof(override) == typeof(value), "Invalid theme token: " .. tostring(k))
        if type(override) == "number" then
          assert(override == override and override >= 0 and override < math.huge, "Invalid numeric theme token")
        end
      end
      result[k] = if override ~= nil then override else value
    end
  end
  for k in pairs(patch or {}) do
    assert(base[k] ~= nil, "Unknown theme token: " .. tostring(k))
  end
  return result
end
function Theme.resolve(patch) return merge(Theme.default, patch) end
return Theme
