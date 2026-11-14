-- Every connection, child scope, timer and instance has one owner.
local Scope = {}
Scope.__index = Scope
local function dispose(resource)
  if type(resource) == "function" then
    resource()
  elseif typeof(resource) == "RBXScriptConnection" or (type(resource) == "table" and resource.Disconnect) then
    resource:Disconnect()
  elseif type(resource) == "thread" then
    if coroutine.status(resource) ~= "dead" and resource ~= coroutine.running() then
      task.cancel(resource)
    end
  elseif resource.Destroy then
    resource:Destroy()
  end
end
function Scope.new(onError)
  return setmetatable({ _items = {}, _next = 0, destroyed = false, onError = onError or warn }, Scope)
end
function Scope:Add(resource)
  if self.destroyed then
    dispose(resource)
    return resource
  end
  self._next += 1
  self._items[self._next] = resource
  return resource
end
function Scope:Remove(resource)
  for id, item in pairs(self._items) do
    if item == resource then
      self._items[id] = nil
      return
    end
  end
end
function Scope:Child()
  local child = self:Add(Scope.new(self.onError))
  child:Add(function()
    self:Remove(child)
  end)
  return child
end
function Scope:Delay(seconds, callback)
  local thread
  thread = task.delay(seconds, function()
    self:Remove(thread)
    if not self.destroyed then
      callback()
    end
  end)
  return self:Add(thread)
end
function Scope:Destroy()
  if self.destroyed then
    return
  end
  self.destroyed = true
  for id = self._next, 1, -1 do
    local resource = self._items[id]
    self._items[id] = nil
    if resource then
      local ok, err = pcall(dispose, resource)
      if not ok then
        self.onError(err)
      end
    end
  end
end
return Scope
