-- [[ autodark ]]

-- module
local AutoDark = {}
local utils, remote, gameInfo, world
local connection
local nextFireAt, lastErrorAt = 0, -math.huge

-- configuration
local CONFIG = {
  REQUIRE_ABILITIES_ENABLED = true,
}

-- connections
local function disconnect()
  if not connection then return end
  if utils then utils.untrackGlobal(connection) end
  connection:Disconnect(); connection = nil
  nextFireAt = 0
end

-- synchronization
function AutoDark.sync()
  disconnect()
  if not utils or not remote or not utils.getConfigValue("AutoDark") then return true end
  local runService = utils.getRunService()
  if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
  connection = runService.Heartbeat:Connect(function()
    if not utils.getConfigValue("AutoDark") or (CONFIG.REQUIRE_ABILITIES_ENABLED and not gameInfo.areAbilitiesEnabled()) then return end
    local now = os.clock()
    if now < nextFireAt then return end
    nextFireAt = now + 1 / 60; local camera = world.CurrentCamera
    if camera then
      local ok, sent, detail = pcall(remote.fireDark, gameInfo.getDarkSealEventId(), camera.CFrame)
      if (not ok or sent ~= true) and now - lastErrorAt >= 2 then lastErrorAt = now; warn("[AutoDark] " .. tostring(ok and detail or sent)) end
    end
  end)
  utils.trackGlobal(connection); return true
end

-- setup
function AutoDark.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.Remote) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes: Utils, GameInfo ou Remote" end
  AutoDark.teardown(); utils, remote, gameInfo = deps.Utils, deps.Remote, deps.GameInfo
  lastErrorAt = -math.huge; world = utils.getWorkspace()
  return AutoDark.sync()
end
function AutoDark.teardown()
  disconnect(); utils, remote, gameInfo, world = nil, nil, nil, nil
end

-- contract
AutoDark.__contract = {
  requires = { Utils = "utils", Remote = "remote", GameInfo = "gameinfo" },
  requiresMethods = {
    Utils = { "getConfigValue", "getWorkspace", "getRunService", "trackGlobal", "untrackGlobal" },
    Remote = { "fireDark" },
    GameInfo = { "areAbilitiesEnabled", "getDarkSealEventId" },
  },
  provides = { "setup", "sync", "teardown" },
}

return AutoDark
