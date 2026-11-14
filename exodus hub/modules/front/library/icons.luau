-- [[ uiicons ]]

-- module
local Icons = {}
local Theme
local cache = {}

-- configuration
local CONFIG = {
  ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
  DIRECTORY = "ExodusUIAssets",
  VERSION = "156617de5cbf",
  IMAGES = {
    settings = {
      png = "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",
      fallback = "rbxasset://textures/ui/Settings/MenuBarIcons/GameSettingsTab.png",
    },
    chevron = {
      png = "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAABNklEQVR4nO2XMU7DQBBF4zgNQuIeQaKDgrtQQKTcKeJcVByAEgo6EvwoMiNPrBjF3kGMYZ5k7cqW/v4/67V3Z7MkSZIkSZLkfwBUQDVJfWBu+vWk9LUqQA2cdwd00J8f0feZCSN+DTwBL8BK7i0c9BfS3hj9Bzt2iXgl1xnwzCHr0hAd869G+xO4LA5hXp0L4A3YAVtpi0L0mN8CH9K/ledl60EFgHsR3kmFRofoMa/FAdjIzPusM7MO1qUhTjD/qGPi+Uk1A48OMcB87WreI8Svmy8JEcb8mBDhzA8NEdL8gBB3wBX7f0gs8yeEQNp3049lXukJ0dDShDWvfDMTDe32IKZ55UiI+JXv0gmhld/IvdjmFdoN4JJ2V/mjx1F3ODwiTse4hf2O0v38nCRJkiRJkvwRvgDtG80g9ENmrgAAAABJRU5ErkJggg==",
      fallback = "rbxasset://textures/ui/Settings/DropDown/DropDown.png",
    },
    minimize = {
      png = "iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAA8klEQVR4nO3VsUoEMRSF4XN2RhAUtBEEa7Gy9H18D9/DVt/HykbwPWxE3N9iZyDITgzOzmpxviZDZpJ7bzIkUkRERERERMRyAAP+j/F+/AhY2V6Pz3OTa1HE62x//nqicRWADjjeUX4tcXvgqMxhyuTLceWBG0mPkk4kvdbG7NC5pFNJd7Yfyr/gu63JFFUfSnqWdLlElg3Wkq5tv0wV0U+NtA1wIOls6PpYKMmt4Ye212bny742QDe0t8A7f+MeWFE5PKpVAR524krShTZbuq/j9M320+xZatUvjYa7oGk1hyL2dpGNZt0BEREREREREXVfcjPipu/0aSgAAAAASUVORK5CYII=",
      fallback = "rbxasset://textures/ui/Settings/Slider/Less.png",
    },
  },
}

-- setup
function Icons.setup(deps)
  Theme = deps.Theme.tokens; return true
end

-- assets
local function decode(encoded)
  local output, buffer, bits = {}, 0, 0
  for index = 1, #encoded do
    local digit = CONFIG.ALPHABET:find(encoded:sub(index, index), 1, true)
    if digit then
      buffer = buffer * 64 + digit - 1; bits += 6
      if bits >= 8 then
        bits -= 8; local divisor = 2 ^ bits
        output[#output + 1] = string.char(math.floor(buffer / divisor))
        buffer = buffer % divisor
      end
    end
  end
  return table.concat(output)
end
local function resolve(name)
  if cache[name] then return cache[name] end
  local definition = assert(CONFIG.IMAGES[name], "Unknown UI icon: " .. tostring(name)); local asset = getcustomasset or getsynasset
  local path = definition.fallback
  if type(asset) == "function" and type(writefile) == "function" and type(makefolder) == "function" then
    local ok, result = pcall(function()
      if type(isfolder) ~= "function" or not isfolder(CONFIG.DIRECTORY) then makefolder(CONFIG.DIRECTORY) end
      local file = CONFIG.DIRECTORY .. "/" .. CONFIG.VERSION .. "-" .. name .. ".png"; writefile(file, decode(definition.png))
      return asset(file)
    end)
    if ok and type(result) == "string" and result ~= "" then path = result end
  end
  cache[name] = path; return path
end

-- public-api
function Icons.create(parent, name, properties)
  local icon = Instance.new("ImageLabel"); icon.Name = "Icon_" .. name
  icon.BackgroundTransparency = 1; icon.Active = false
  icon.Selectable = false; icon.BorderSizePixel = 0
  icon.Image = resolve(name); icon.ImageColor3 = Theme.COLORS.text
  icon.ScaleType = Enum.ScaleType.Fit; icon.AnchorPoint = Vector2.new(0.5, 0.5)
  icon.Position = UDim2.fromScale(0.5, 0.5); icon.Size = UDim2.fromOffset(18, 18)
  icon.ZIndex = parent.ZIndex + 1
  for key, value in pairs(properties or {}) do
    icon[key] = value
  end
  icon.Parent = parent; return icon
end

-- contract
Icons.__contract = {
  provides = { "setup", "create" },
  requires = { Theme = "uitheme" },
  requiresData = { Theme = { "tokens" } },
}

return Icons
