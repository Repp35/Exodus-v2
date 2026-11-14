-- Small deterministic Roblox boundary used by the Luau CLI integration suite.
-- It exercises state/events/ownership, not Roblox rasterization or text metrics.
local Mock = {}
function Mock.install(env)
  env._G = {}
  local function event()
    local self = { listeners = {} }
    function self:Connect(callback)
      local connection = { Connected = true }
      self.listeners[connection] = callback
      function connection:Disconnect()
        self.Connected = false
      end
      return connection
    end
    function self:Fire(...)
      local snapshot = table.clone(self.listeners)
      for connection, callback in pairs(snapshot) do
        if connection.Connected then
          callback(...)
        end
      end
    end
    return self
  end
  Mock.event = event
  local enums = {}
  env.Enum = setmetatable({}, {
    __index = function(_, kind)
      if enums[kind] then
        return enums[kind]
      end
      local category = {}
      setmetatable(category, {
        __index = function(_, name)
          local item = { Name = name, EnumType = category, __type = "EnumItem" }
          rawset(category, name, item)
          return item
        end,
      })
      enums[kind] = category
      return category
    end,
  })
  local vector = {}
  vector.__index = function(v, key)
    if key == "Magnitude" then
      return math.sqrt(v.X * v.X + v.Y * v.Y)
    end
    return vector[key]
  end
  vector.__add = function(a, b)
    return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y }, vector)
  end
  vector.__sub = function(a, b)
    return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y }, vector)
  end
  env.Vector2 = {
    new = function(x, y)
      return setmetatable({ X = x, Y = y }, vector)
    end,
  }
  env.Vector2.zero = env.Vector2.new(0, 0)
  env.UDim = {
    new = function(scale, offset)
      return { Scale = scale, Offset = offset }
    end,
  }
  env.UDim2 = {
    new = function(xs, xo, ys, yo)
      return { X = env.UDim.new(xs, xo), Y = env.UDim.new(ys, yo) }
    end,
  }
  env.UDim2.fromOffset = function(x, y)
    return env.UDim2.new(0, x, 0, y)
  end
  env.UDim2.fromScale = function(x, y)
    return env.UDim2.new(x, 0, y, 0)
  end
  local color = {}
  color.__index = color
  function color:Lerp(other, t)
    return env.Color3.new(
      self.R + (other.R - self.R) * t,
      self.G + (other.G - self.G) * t,
      self.B + (other.B - self.B) * t
    )
  end
  function color:ToHex()
    return string.format(
      "%02X%02X%02X",
      math.round(self.R * 255),
      math.round(self.G * 255),
      math.round(self.B * 255)
    )
  end
  env.Color3 = {
    new = function(r, g, b)
      return setmetatable({ R = r, G = g, B = b, __type = "Color3" }, color)
    end,
  }
  env.Color3.fromRGB = function(r, g, b)
    return env.Color3.new(r / 255, g / 255, b / 255)
  end
  env.Color3.fromHex = function(hex)
    return env.Color3.fromRGB(
      tonumber(hex:sub(1, 2), 16),
      tonumber(hex:sub(3, 4), 16),
      tonumber(hex:sub(5, 6), 16)
    )
  end
  env.ColorSequence = {
    new = function(...)
      return { ... }
    end,
  }
  env.TweenInfo = {
    new = function(...)
      return { ... }
    end,
  }
  local nativeTypeof = typeof
  env.typeof = function(value)
    return type(value) == "table" and value.__type or nativeTypeof(value)
  end
  local events = {
    Activated = true,
    MouseEnter = true,
    MouseLeave = true,
    SelectionGained = true,
    SelectionLost = true,
    InputBegan = true,
    InputChanged = true,
    InputEnded = true,
    Focused = true,
    FocusLost = true,
    Destroying = true,
    Idled = true,
    WindowFocusReleased = true,
  }
  local all = {}
  local mt = {}
  mt.__index = function(self, key)
    if events[key] then
      return self._events[key]
    end
    if key == "Parent" then
      return self._parent
    end
    if key == "AbsoluteSize" then
      return self._size or env.Vector2.new(760, 540)
    end
    if key == "AbsolutePosition" or key == "AbsoluteContentSize" then
      return env.Vector2.new(0, 0)
    end
    if key == "GetPropertyChangedSignal" then
      return function(_, name)
        self._changes[name] = self._changes[name] or event()
        return self._changes[name]
      end
    end
    if key == "IsA" then
      return function(_, name)
        return name == self.ClassName
      end
    end
    if key == "GetChildren" then
      return function()
        local children = {}
        for _, item in ipairs(all) do
          if item._parent == self and not item._dead then
            table.insert(children, item)
          end
        end
        return children
      end
    end
    if key == "FindFirstChildOfClass" then
      return function(_, name)
        for _, item in ipairs(self:GetChildren()) do
          if item.ClassName == name then
            return item
          end
        end
      end
    end
    if key == "Destroy" then
      return function()
        if self._dead then
          return
        end
        self._events.Destroying:Fire()
        for _, item in ipairs(self:GetChildren()) do
          item:Destroy()
        end
        for _, e in pairs(self._events) do
          for conn in pairs(e.listeners) do
            conn:Disconnect()
          end
        end
        self._dead = true
        self._parent = nil
      end
    end
  end
  mt.__newindex = function(self, key, value)
    if key == "Parent" then
      rawset(self, "_parent", value)
    else
      rawset(self, key, value)
    end
  end
  env.Instance = {
    new = function(class)
      local instance =
        setmetatable({ ClassName = class, _events = {}, _changes = {}, __type = "Instance" }, mt)
      for name in pairs(events) do
        instance._events[name] = event()
      end
      table.insert(all, instance)
      return instance
    end,
  }
  local services = { UserInputService = env.Instance.new("UserInputService"), GuiService = {} }
  services.UserInputService.GetFocusedTextBox = function()
    return nil
  end
  services.UserInputService.KeyboardEnabled = true
  services.UserInputService.MouseEnabled = true
  services.UserInputService.TouchEnabled = false
  local player = env.Instance.new("Player")
  local playerGui = env.Instance.new("PlayerGui")
  player.WaitForChild = function()
    return playerGui
  end
  services.Players = { LocalPlayer = player }
  services.TweenService = {
    Create = function(_, object, _, properties)
      local tween = { Completed = event() }
      function tween:Play()
        for k, v in pairs(properties) do
          object[k] = v
        end
        self.Completed:Fire()
      end
      function tween:Cancel() end
      return tween
    end,
  }
  env.game = {
    GetService = function(_, name)
      assert(services[name], name)
      return services[name]
    end,
  }
  env.warn = function(message)
    error("Unexpected warning: " .. tostring(message))
  end
  local pending = {}
  env.task = {
    delay = function(_, callback)
      local co = coroutine.create(callback)
      pending[co] = true
      return co
    end,
    cancel = function(co)
      pending[co] = nil
    end,
    spawn = function(callback)
      local co = coroutine.create(callback)
      pending[co] = true
      return co
    end,
    wait = function()
      coroutine.yield()
    end,
  }
  function Mock.pending()
    local count = 0
    for _ in pairs(pending) do
      count += 1
    end
    return count
  end
  function Mock.live()
    local count = 0
    for _, item in ipairs(all) do
      if not item._dead then
        count += 1
      end
    end
    return count
  end
  function Mock.input(key)
    return { KeyCode = key, UserInputType = env.Enum.UserInputType.Keyboard, Position = env.Vector2.new(0, 0) }
  end
  function Mock.fire(ctx, key, ended)
    local input = Mock.input(key);
    (ended and ctx.InputEnded or ctx.InputBegan):Fire(input, false)
    return input
  end
  function Mock.countResources(scope)
    local n = 0
    for _ in pairs(scope._items) do
      n += 1
    end
    return n
  end
  Mock.services = services
end
return Mock
