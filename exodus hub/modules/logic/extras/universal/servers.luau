-- [[ server navigation ]]

local Servers = {}
local utils, failureConnection
local generation, busy, busyUntil, reporter = 0, false, 0, nil

-- configuration
local CONFIG = { MAX_PING_MS = 100, MAX_PAGES = 3, PAGE_SIZE = 100, PAGE_DELAY = 0.5, TELEPORT_TIMEOUT = 15 }

-- helpers
local function finite(v) return type(v) == "number" and v == v and v > -math.huge and v < math.huge end
local function begin(callback)
  if not utils or not utils.isActive() then return nil, "Hub inativo" end
  if busy and os.clock() < busyUntil then return nil, "Já existe uma busca ou um teleporte em andamento" end
  generation = generation + 1
  busy, busyUntil, reporter = true, os.clock() + 60, callback
  return generation
end
local function report(message) if type(reporter) == "function" then reporter(message) end end
local function teleport(serverId, token)
  if token ~= generation or not utils or not utils.isActive() then return false, "Operação cancelada" end
  local player = utils.getLocalPlayer()
  if not player then busy = false; return false, "Jogador indisponível" end
  busyUntil = os.clock() + CONFIG.TELEPORT_TIMEOUT
  local ok, err = pcall(function() game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, serverId, player) end)
  if not ok then busy = false; return false, tostring(err) end
  return true
end

-- actions
function Servers.rejoin(callback)
  local token, err = begin(callback); if not token then return false, err end
  if type(game.JobId) ~= "string" or game.JobId == "" then busy = false; return false, "Servidor atual indisponível" end
  report("Reconectando ao servidor atual...")
  return teleport(game.JobId, token)
end
function Servers.hop(callback)
  local token, err = begin(callback); if not token then return false, err end
  local http = game:GetService("HttpService"); local best, cursor
  report("Buscando servidores com ping informado de até " .. CONFIG.MAX_PING_MS .. " ms...")
  for page = 1, CONFIG.MAX_PAGES do
    if token ~= generation or not utils or not utils.isActive() then return false, "Operação cancelada" end
    local url = ("https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Asc&limit=%d&excludeFullGames=true"):format(tostring(game.PlaceId), CONFIG.PAGE_SIZE)
    if cursor then url = url .. "&cursor=" .. http:UrlEncode(cursor) end
    local ok, result = pcall(function() return http:JSONDecode(game:HttpGet(url)) end)
    if not ok or type(result) ~= "table" or type(result.data) ~= "table" then
      busy = false; return false, "Falha ao consultar servidores: " .. tostring(result)
    end
    for _, server in ipairs(result.data) do
      if type(server) == "table" and type(server.id) == "string" and server.id ~= "" and server.id ~= game.JobId
        and finite(server.playing) and finite(server.maxPlayers) and server.playing < server.maxPlayers
        and finite(server.ping) and server.ping > 0 and server.ping <= CONFIG.MAX_PING_MS then
        if not best or server.ping < best.ping then best = server end
      end
    end
    cursor = result.nextPageCursor
    if type(cursor) ~= "string" or cursor == "" then break end
    if page < CONFIG.MAX_PAGES then task.wait(CONFIG.PAGE_DELAY) end
  end
  if token ~= generation or not utils or not utils.isActive() then return false, "Operação cancelada" end
  if not best then busy = false; return false, "Nenhum outro servidor com vaga e ping informado de até " .. CONFIG.MAX_PING_MS .. " ms foi encontrado" end
  report(("Entrando no servidor com menor ping informado: %.0f ms..."):format(best.ping))
  return teleport(best.id, token)
end

-- lifecycle
function Servers.teardown()
  generation = generation + 1; busy, reporter = false, nil
  if failureConnection then if utils then utils.untrackGlobal(failureConnection) end; failureConnection:Disconnect(); failureConnection = nil end
  utils = nil; return true
end
function Servers.setup(deps)
  Servers.teardown()
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "Utils ausente" end
  utils = deps.Utils
  failureConnection = game:GetService("TeleportService").TeleportInitFailed:Connect(function(player, _, message, placeId)
    if not utils or player ~= utils.getLocalPlayer() or placeId ~= game.PlaceId or not busy then return end
    busy = false; report("Teleporte falhou: " .. tostring(message)); utils.recordError("Servers", message)
  end)
  utils.trackGlobal(failureConnection); return true
end
-- contract
Servers.__contract = {
  requires = { Utils = "utils" },
  requiresMethods = { Utils = { "getLocalPlayer", "isActive", "trackGlobal", "untrackGlobal", "recordError" } },
  provides = { "setup", "teardown", "rejoin", "hop" },
}
return Servers
