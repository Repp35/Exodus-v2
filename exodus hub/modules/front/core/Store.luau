local Signal = require(script.Parent.Signal)
local Store = {}
Store.__index = Store
local function copy(value)
  if typeof(value) ~= "table" then
    return value
  end
  local result = {}
  for k, v in pairs(value) do
    result[k] = copy(v)
  end
  return result
end
local function equal(a, b)
  if typeof(a) ~= typeof(b) then
    return false
  end
  if typeof(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end
function Store.new(options)
  options = options or {}
  local self = setmetatable({
    _values = copy(options.values or {}),
    _validate = options.validate,
    _write = options.write,
    Changed = Signal.new(options.onError),
  }, Store)
  return self
end
function Store:Get(key) return copy(self._values[key]) end
function Store:Snapshot() return copy(self._values) end
function Store:Patch(patch, external)
  assert(type(patch) == "table", "Expected patch table")
  local changes = {}
  for key, value in pairs(patch) do
    if type(key) ~= "string" then
      return false, "Keys must be strings"
    end
    if self._validate then
      local safe, ok, reason = pcall(self._validate, key, copy(value))
      if not safe then
        return false, tostring(ok)
      end
      if not ok then
        return false, reason or ("Invalid value: " .. key)
      end
    end
    if not equal(self._values[key], value) then
      changes[key] = copy(value)
    end
  end
  if next(changes) == nil then
    return true
  end
  if self._write and not external then
    local ok, accepted, reason = pcall(self._write, copy(changes))
    if not ok then
      return false, tostring(accepted)
    end
    if accepted == false then
      return false, reason or "Update rejected"
    end
  end
  local committed = {}
  for key, value in pairs(changes) do
    if not equal(self._values[key], value) then
      self._values[key] = copy(value)
      committed[key] = copy(value)
    end
  end
  if next(committed) then
    self.Changed:Fire(copy(committed), self:Snapshot())
  end
  return true
end
function Store:Set(key, value) return self:Patch({ [key] = value }) end
function Store:Subscribe(key, callback, immediate)
  local connection = self.Changed:Connect(function(changes)
    if changes[key] ~= nil then
      callback(self:Get(key))
    end
  end)
  if immediate then
    callback(self:Get(key))
  end
  return connection
end
function Store:Destroy() self.Changed:Destroy() end
return Store
