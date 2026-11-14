-- Deterministic dispatch. Disconnecting during dispatch is safe; new listeners wait.
local Signal = {}
Signal.__index = Signal
function Signal.new(onError) return setmetatable({ _listeners = {}, _next = 0, _destroyed = false, _onError = onError or warn }, Signal) end
function Signal:Connect(callback)
  assert(not self._destroyed, "Signal is destroyed")
  assert(type(callback) == "function", "Expected callback")
  self._next += 1
  local id, owner = self._next, self
  local connection = { Connected = true }
  function connection:Disconnect()
    if not self.Connected then
      return
    end
    self.Connected = false
    owner._listeners[id] = nil
  end
  self._listeners[id] = { callback = callback, connection = connection }
  return connection
end
function Signal:Fire(...)
  if self._destroyed then
    return
  end
  local snapshot = {}
  for id, listener in pairs(self._listeners) do
    snapshot[#snapshot + 1] = { id, listener }
  end
  table.sort(snapshot, function(a, b) return a[1] < b[1] end)
  for _, item in ipairs(snapshot) do
    if item[2].connection.Connected then
      local ok, err = pcall(item[2].callback, ...)
      if not ok then
        self._onError(err)
      end
    end
  end
end
function Signal:Destroy()
  if self._destroyed then
    return
  end
  self._destroyed = true
  for _, listener in pairs(self._listeners) do
    listener.connection.Connected = false
  end
  table.clear(self._listeners)
end
return Signal
