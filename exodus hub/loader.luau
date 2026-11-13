-- [[ loader ]]

-- module
local Loader = {}
local function printRawError(moduleName, message, filePath)
  local output = ("[%s] %s: %s"):format(tostring(filePath or "loader.luau"), tostring(moduleName), tostring(message))
  if type(warn) == "function" then warn(output) elseif type(print) == "function" then print(output) end
end
local function printStartup(message)
  if type(print) == "function" then print(message) end
end
local function fallbackNotification(message, key, kind, duration)
  local players = game:GetService("Players"); local player = players.LocalPlayer
  local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
  if not playerGui then return end
  local gui = playerGui:FindFirstChild("ExodusPersistentNotifications")
  if not gui then
    gui = Instance.new("ScreenGui"); gui.Name = "ExodusPersistentNotifications"
    gui.DisplayOrder = 2147483647; gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true; gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    gui.Parent = playerGui
  end
  local layer = gui:FindFirstChild("NotificationLayer")
  if not layer then
    layer = Instance.new("Frame"); layer.Name = "NotificationLayer"
    layer.Size = UDim2.fromScale(1, 1); layer.BackgroundTransparency = 1
    layer.Parent = gui
  end
  local safeKey = tostring(key or "critical"):gsub("[^%w_%-]", "_"); local card = layer:FindFirstChild("Notification_" .. safeKey)
  if not card then
    card = Instance.new("CanvasGroup"); card.Name = "Notification_" .. safeKey
    card:SetAttribute("ExodusNotificationKey", safeKey); card.AnchorPoint = Vector2.new(0.5, 1)
    card.Position = UDim2.new(0.5, 0, 1, -24); card.Size = UDim2.fromOffset(320, 38)
    card.BackgroundColor3 = kind == "critical" and Color3.fromRGB(153, 27, 27) or Color3.fromRGB(45, 55, 130); card.BackgroundTransparency = 0.12
    card.ZIndex = 100; card.Parent = layer
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = card; local label = Instance.new("TextLabel")
    label.Name = "Message"; label.Size = UDim2.new(1, -20, 1, 0)
    label.Position = UDim2.fromOffset(10, 0); label.BackgroundTransparency = 1
    label.TextColor3 = Color3.new(1, 1, 1); label.TextSize = 13
    label.Font = Enum.Font.GothamBold; label.TextXAlignment = Enum.TextXAlignment.Center
    label.Parent = card
  end
  local label = card:FindFirstChild("Message")
  if label then label.Text = tostring(message) end
  if duration == nil and key ~= "dumper" then duration = 2.5 end
  card.GroupTransparency = 0; card.Visible = true
  if duration and duration > 0 then
    task.delay(duration, function()
      if card.Parent then card:Destroy() end
    end)
  end
end
local function notifyPersistent(message, key, kind, duration)
  local show = _G.ExodusShowPersistentNotification
  if type(show) == "function" then
    local ok = pcall(show, message, key, kind, duration)
    if ok then return end
  end
  fallbackNotification(message, key, kind, duration)
end
local function clearPersistent(key)
  local clear = _G.ExodusClearPersistentNotification
  if type(clear) == "function" then
    local ok = pcall(clear, key)
    if ok then return end
  end
  local player = game:GetService("Players").LocalPlayer; local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
  local gui = playerGui and playerGui:FindFirstChild("ExodusPersistentNotifications"); local layer = gui and gui:FindFirstChild("NotificationLayer")
  local safeKey = tostring(key or "critical"):gsub("[^%w_%-]", "_"); local card = layer and layer:FindFirstChild("Notification_" .. safeKey)
  if card then card:Destroy() end
end
local function notifyCritical(moduleName)
  notifyPersistent(("Critical error in %s. Check the console."):format(tostring(moduleName or "the hub")), "critical", "critical")
end
local function closeUpdateChannel()
  local stop = _G.ExodusUpdateStop; _G.ExodusUpdateStop = nil
  if type(stop) == "function" then pcall(stop) end
  local socket = _G.ExodusUpdateSocket; _G.ExodusUpdateSocket = nil
  _G.ExodusUpdateToken = nil
  if socket then
    local close = socket.Close or socket.close
    if type(close) == "function" then pcall(close, socket) end
  end
end
local Exodus = type(_G.Exodus) == "table" and _G.Exodus or {}
local Modules = type(Exodus.Modules) == "table" and Exodus.Modules or {}

-- configuration
local CONFIG = {
  DELIVERY_BASE_URL = "https://repp35.github.io/Exodus-v2/",
  MANIFEST_URL = "https://repp35.github.io/Exodus-v2/manifest.json",
  PROJECT_PATH = "exodus%20hub/",
  AUTHORIZATION_PATH = "security/entitlements.luau",
  MODULES = {
    { name = "permissions", path = "modules/logic/aux/permissions.luau" },
    { name = "config", path = "modules/front/config.luau" },
    { name = "uiconfig", path = "modules/front/uiconfig.luau" },
    { name = "utils", path = "modules/logic/aux/utils.luau" },
    { name = "gameinfo", path = "modules/logic/aux/gameinfo.luau" },
    { name = "clashstats", path = "modules/logic/aux/clashstats.luau" },
    { name = "autodark", path = "modules/logic/extras/autodark.luau" },
    { name = "movement", path = "modules/logic/aux/movement.luau" },
    { name = "autojump", path = "modules/logic/extras/autojump.luau" },
    { name = "camera", path = "modules/logic/extras/camera.luau" },
    { name = "infinitejump", path = "modules/logic/extras/universal/infinitejump.luau" },
    { name = "noclip", path = "modules/logic/extras/universal/noclip.luau" },
    { name = "fly", path = "modules/logic/extras/universal/fly.luau" },
    { name = "invisicam", path = "modules/logic/extras/universal/invisicam.luau" },
    { name = "speed", path = "modules/logic/extras/universal/speed.luau" },
    { name = "gravity", path = "modules/logic/extras/universal/gravity.luau" },
    { name = "remote", path = "modules/logic/aux/remote.luau" },
    { name = "autofierce", path = "modules/logic/extras/autofierce.luau" },
    { name = "autoparry", path = "modules/logic/autoparry.luau" },
    { name = "danger", path = "modules/logic/aux/danger.luau" },
    { name = "dash", path = "modules/logic/aux/dash.luau" },
    { name = "autospam", path = "modules/logic/autospam.luau" },
    { name = "autodash", path = "modules/logic/extras/autodash.luau" },
    { name = "spam", path = "modules/logic/spam.luau" },
    { name = "character", path = "modules/logic/aux/character.luau" },
    { name = "dumper", path = "modules/logic/extras/universal/dumper.luau" },
    { name = "servers", path = "modules/logic/extras/universal/servers.luau" },
    { name = "ui", path = "modules/front/ui.luau" },
  },
}

local PROJECT_PATH = CONFIG.PROJECT_PATH
local AUTHORIZATION_PATH = CONFIG.AUTHORIZATION_PATH
local BASE_URL = CONFIG.DELIVERY_BASE_URL
local MANIFEST_URL = CONFIG.MANIFEST_URL
local HttpService = game:GetService("HttpService")
local UPDATE_WS_URL = "wss://ntfy.sh/exodus-v2-live-9f36c3d1e8b24a7c/ws"
local cacheSequence = 0
local function cacheBuster()
  cacheSequence += 1; return ("%d-%d-%d"):format(os.time(), math.floor(os.clock() * 1000000), cacheSequence)
end
local MODULE_MANIFEST = CONFIG.MODULES
local MODULE_ORDER = {}
local MODULE_BY_NAME = {}
for _, entry in ipairs(MODULE_MANIFEST) do
  MODULE_BY_NAME[entry.name] = entry
  if entry.name ~= "ui" and entry.name ~= "permissions" then MODULE_ORDER[#MODULE_ORDER + 1] = entry.name end
end

-- http
local function getRequestFunction()
  local environment = type(getgenv) == "function" and getgenv() or _G; local synApi = type(environment.syn) == "table" and environment.syn or nil
  local fluxusApi = type(environment.fluxus) == "table" and environment.fluxus or nil
  for _, candidate in ipairs({
    environment.request or false,
    environment.http_request or false,
    synApi and synApi.request or false,
    fluxusApi and fluxusApi.request or false,
  }) do
    if type(candidate) == "function" then return candidate end
  end
  return nil
end
local requestFunction = getRequestFunction()
local function validateExecutor()
  if type(requestFunction) ~= "function" then return false, "executor sem request HTTP suportado" end
  if type(loadstring) ~= "function" then return false, "executor sem loadstring" end
  if type(game) ~= "userdata" and type(game) ~= "table" then return false, "ambiente Roblox indisponível" end
  if type(game.GetService) ~= "function" then return false, "executor sem acesso aos serviços Roblox" end
  return true
end
local function isRetryableHttp(message)
  local statusCode = tonumber(string.match(tostring(message), "HTTP%s+(%d+)"))
  return statusCode == nil or statusCode == 408 or statusCode == 425 or statusCode == 429 or (statusCode and statusCode >= 500 and statusCode <= 599)
end
local function waitBeforeRetry(attempt)
  if type(task) == "table" and type(task.wait) == "function" then local delays = { 0.25, 0.75, 1.5 }; task.wait(delays[attempt] or delays[#delays]) end
end
local function headerValue(headers, expected)
  for key, value in pairs(type(headers) == "table" and headers or {}) do
    if string.lower(tostring(key)) == string.lower(expected) then return value end
  end
  return nil
end
local function retryAfter(headers)
  local delay = tonumber(headerValue(headers, "retry-after"))
  if delay and delay >= 0 then return delay end
  local reset = tonumber(headerValue(headers, "x-ratelimit-reset")); return reset and math.max(0, reset - os.time()) or 5
end
local function requestOnce(url, headers)
  if not requestFunction then return nil, "Nenhum serviço HTTP disponível" end
  local ok, response = pcall(requestFunction, { Url = url, Method = "GET", Headers = headers })
  if not ok then return nil, tostring(response) end
  if type(response) ~= "table" then return nil, "Resposta HTTP inválida" end
  local statusCode = tonumber(response.StatusCode or response.status_code); local responseHeaders = response.Headers or response.headers
  local responseBody = response.Body or response.body or response.ResponseBody
  if not statusCode or statusCode < 200 or statusCode >= 300 then
    local remaining = tonumber(headerValue(responseHeaders, "x-ratelimit-remaining")); local details = string.lower(tostring(responseBody or ""))
    local limited = statusCode == 429
      or (
        statusCode == 403
        and (
          remaining == 0
          or headerValue(responseHeaders, "retry-after") ~= nil
          or headerValue(responseHeaders, "x-ratelimit-reset") ~= nil
          or details:find("rate limit", 1, true) ~= nil
        )
      )
    return nil,
      "HTTP " .. tostring(statusCode or "sem status"),
      limited and { rateLimited = true, retryAfter = retryAfter(responseHeaders), statusCode = statusCode } or {
        statusCode = statusCode,
      }
  end
  if type(responseBody) ~= "string" or responseBody == "" then return nil, "Corpo HTTP vazio ou inválido" end
  return responseBody
end
local function request(url, headers)
  if type(url) ~= "string" or url == "" then return nil, "URL inválida" end
  if not requestFunction then return nil, "Nenhum serviço HTTP disponível" end
  local lastError, lastMeta
  for attempt = 1, 3 do
    local body, err, meta = requestOnce(url, headers)
    if body then return body end
    lastError, lastMeta = err, meta
    if meta and meta.rateLimited then return nil, lastError, lastMeta end
    if not isRetryableHttp(lastError) then break end
    if attempt < 3 then waitBeforeRetry(attempt) end
  end
  local message = lastError or "Nenhum serviço HTTP disponível"; return nil, message, lastMeta
end
local function validRevision(value) return type(value) == "string" and #value == 40 and value:match("^[%x]+$") ~= nil end
local SIGNATURE_ROOT = "Exodus Hub/Signatures"
local releaseSignatures
local function fingerprint(source)
  local a, b = 1, 0
  for i = 1, #source do
    a = (a + string.byte(source, i)) % 65521; b = (b + a) % 65521
  end
  return string.format("%04x%04x", b, a)
end
local function signatureFor(path) return type(releaseSignatures) == "table" and releaseSignatures["exodus hub/" .. path] or nil end
local function signatureValid(value) return type(value) == "string" and #value == 8 and value:match("^[%x]+$") ~= nil end
local function storedSource(signature, relativePath)
  if not signatureValid(signature) or type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end
  local path = SIGNATURE_ROOT .. "/" .. signature .. "/" .. relativePath
  local ok, source = pcall(function() return isfile(path) and readfile(path) or nil end)
  return ok and type(source) == "string" and fingerprint(source) == signature and source or nil
end
local function storeSource(signature, relativePath, source)
  if type(writefile) ~= "function" or type(makefolder) ~= "function" or type(isfolder) ~= "function" then return end
  if fingerprint(source) ~= signature then return end
  pcall(function()
    local root = ""; local fullPath = SIGNATURE_ROOT .. "/" .. signature .. "/" .. relativePath
    local directory = fullPath:match("^(.*)/[^/]+$")
    for part in directory:gmatch("[^/]+") do
      root = root == "" and part or (root .. "/" .. part)
      if not isfolder(root) then makefolder(root) end
    end
    writefile(fullPath, source)
  end)
end

-- registry
local function register(name, module)
  Modules[name] = module; return module
end
local function clearRegistry()
  for _, name in ipairs(MODULE_ORDER) do
    Modules[name] = nil
  end
  Modules.ui = nil; Modules.permissions = nil
  Modules.Loader = Loader; Exodus.Utils = nil
  Exodus.State = nil; Exodus.Config = nil
  Exodus.ModuleURLs = nil; Exodus.Runtime = nil
  Exodus.Context = nil; Exodus.UI = nil
  Exodus.Diagnostics = nil; Exodus.Version = nil
  Exodus.Revision = nil; Exodus.StartError = nil
  Exodus.StartErrorModule = nil; Exodus.UIReady = false
  Exodus.Started = false; _G.ExodusOnBurst = nil
end
local function cleanupCall(name, action)
  local ok, result = pcall(action)
  if not ok then printRawError(name, "falha na limpeza: " .. tostring(result)) end
  return ok, result
end
local function stopPreviousRuntime()
  local clean = true; closeUpdateChannel()
  local function attempt(name, action)
    local ok, result = cleanupCall(name, action)
    if not ok then clean = false end
    return ok, result
  end
  if type(Modules.gameinfo) == "table" and type(Modules.gameinfo.stopMaintenance) == "function" then attempt("gameinfo", Modules.gameinfo.stopMaintenance) end
  for _, name in ipairs({
    "servers",
    "universal",
    "infinitejump",
    "noclip",
    "fly",
    "invisicam",
    "speed",
    "gravity",
    "dumper",
    "character",
    "spam",
    "autodash",
    "autospam",
    "danger",
    "clashstats",
    "autodark",
    "autofierce",
    "autojump",
    "camera",
    "movement",
    "dash",
    "autoparry",
  }) do
    local module = Modules[name]
    if type(module) == "table" then
      if type(module.teardown) == "function" then attempt(name, module.teardown) elseif type(module.resetState) == "function" then attempt(name, module.resetState) end
    end
  end
  local stopped = false
  if type(_G.ExodusStop) == "function" then local ok, result = attempt("Utils", _G.ExodusStop); stopped = ok and result == true end
  if not stopped and type(_G.ExodusUICleanup) == "function" then attempt("UI", _G.ExodusUICleanup) end
  return clean
end

-- loading
local function compile(name, source)
  if type(loadstring) ~= "function" then return nil, "loadstring indisponível" end
  local chunk, compileError = loadstring(source, name)
  if not chunk then return nil, compileError end
  return chunk
end
local function execute(name, chunk)
  local module = chunk()
  if type(module) ~= "table" then error(name .. " não retornou uma tabela", 2) end
  return module
end
local function resolveLatestRevision()
  local body, requestError, requestMeta =
    request(MANIFEST_URL .. "?exodus_cache=" .. cacheBuster(), { ["Accept"] = "application/json", ["User-Agent"] = "Exodus-Hub-Loader" })
  if body then
    local ok, document = pcall(HttpService.JSONDecode, HttpService, body); local sha = ok and type(document) == "table" and document.revision
    if validRevision(sha) and type(document.signatures) == "table" then return sha, nil, nil, document.signatures end
  end
  return nil, requestError or "manifesto de versão indisponível", requestMeta
end
local function buildURLs(revision)
  local root = BASE_URL .. revision .. "/" .. PROJECT_PATH; local urls = {}
  for _, entry in ipairs(MODULE_MANIFEST) do
    urls[entry.name] = root .. entry.path
  end
  return urls
end
local function buildCDNURL(url)
  local repository, version, path = string.match(url, "^https://raw%.githubusercontent%.com/([^/]+/[^/]+)/([^/]+)/(.+)$")
  if not repository or not version or not path then return nil end
  return "https://cdn.jsdelivr.net/gh/" .. repository .. "@" .. version .. "/" .. path
end
local function loadModule(name, relativePath, url)
  local signature = signatureFor(relativePath)
  if not signatureValid(signature) then return nil, "assinatura inválida: " .. relativePath end
  local saved = storedSource(signature, relativePath)
  if saved then
    local cachedChunk = compile(name .. " [verified]", saved)
    if cachedChunk then return cachedChunk, nil, "verified" end
  end
  local source, fetchError
  if url then source, fetchError = request(url) end
  local sourceKind = "delivery"
  if not source then
    local fallbackURL = buildCDNURL(url)
    if fallbackURL then
      local fallbackSource, fallbackError = request(fallbackURL)
      if fallbackSource then source, fetchError, sourceKind = fallbackSource, nil, "cdn" else fetchError = tostring(fetchError or "falha no GitHub Raw") .. "; CDN: " .. tostring(fallbackError) end
    end
  end
  if source then
    local chunk, compileError = compile(name, source)
    if chunk and fingerprint(source) == signature then storeSource(signature, relativePath, source); return chunk, nil, sourceKind end
    if chunk then return nil, "assinatura divergente: " .. relativePath end
    fetchError = compileError
  end
  return nil, fetchError or "origem remota indisponível"
end
local function authorizationURL(revision) return BASE_URL .. revision .. "/" .. AUTHORIZATION_PATH end
local function setContains(set, value)
  if type(set) ~= "table" then return false end
  if set[value] == true or set[tostring(value)] == true then return true end
  for _, item in pairs(set) do
    if tostring(item) == tostring(value) then return true end
  end
  return false
end
local function waitForAuthorizationPlayer(timeout)
  local players = game:GetService("Players")
  if players.LocalPlayer then return players.LocalPlayer end
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    if type(task) == "table" and type(task.wait) == "function" then task.wait() end
    if players.LocalPlayer then return players.LocalPlayer end
  end
  return nil
end
local function authorizeRevision(revision)
  if not validRevision(revision) then return false, "revisão de autorização inválida" end
  local player = waitForAuthorizationPlayer(10)
  if not player or type(player.UserId) ~= "number" then return false, "LocalPlayer/UserId indisponível" end
  local source, fetchError = request(authorizationURL(revision), { ["Accept"] = "text/plain", ["User-Agent"] = "Exodus-Hub-Authorization" })
  if not source then return false, "autorização indisponível: " .. tostring(fetchError) end
  local chunk, compileError = compile("Exodus authorization", source)
  if not chunk then return false, "autorização inválida: " .. tostring(compileError) end
  local executed, entitlements = pcall(chunk)
  if not executed or type(entitlements) ~= "table" then return false, "manifesto de autorização inválido" end
  if entitlements.schema ~= 1 or entitlements.product ~= "Exodus-v2" or entitlements.revision ~= revision then return false, "manifesto de autorização incompatível" end
  if type(entitlements.blockedUserIds) ~= "table" then return false, "manifesto de bloqueio inválido" end
  if setContains(entitlements.blockedUserIds, player.UserId) then return false, "usuário bloqueado" end
  if type(entitlements.gameIds) == "table" and next(entitlements.gameIds) ~= nil and not setContains(entitlements.gameIds, game.GameId) then return false, "experiência não autorizada" end
  if type(entitlements.placeIds) == "table" and next(entitlements.placeIds) ~= nil and not setContains(entitlements.placeIds, game.PlaceId) then return false, "lugar não autorizado" end
  local expiresAt = tonumber(entitlements.expiresAt or 0) or 0
  if expiresAt > 0 and os.time() > expiresAt then return false, "autorização expirada" end
  return true
end
local function orderModulesByDependencies(loaded)
  local positions, state, ordered = {}, {}, {}
  for index, name in ipairs(MODULE_ORDER) do
    positions[name] = index
  end
  local function visit(name)
    if state[name] == 2 then return end
    if state[name] == 1 then error("dependência circular entre módulos: " .. name, 2) end
    if not positions[name] or type(loaded[name]) ~= "table" then error("dependência não inicializável: " .. tostring(name), 2) end
    state[name] = 1; local dependencies = {}
    for _, source in pairs(loaded[name].__contract.requires or {}) do
      if source ~= "permissions" then dependencies[#dependencies + 1] = source end
    end
    table.sort(dependencies, function(a, b) return (positions[a] or math.huge) < (positions[b] or math.huge) end)
    for _, source in ipairs(dependencies) do
      visit(source)
    end
    state[name] = 2; ordered[#ordered + 1] = name
  end
  for _, name in ipairs(MODULE_ORDER) do
    visit(name)
  end
  table.clear(MODULE_ORDER)
  for _, name in ipairs(ordered) do
    MODULE_ORDER[#MODULE_ORDER + 1] = name
  end
end
local function loadModules(urls)
  local loaded, results = {}, {}
  local function load(name)
    local entry = MODULE_BY_NAME[name]; local chunk, loadError = loadModule(name, entry.path, urls[name])
    results[name] = { chunk = chunk, error = loadError }
  end
  if type(task) == "table" and type(task.spawn) == "function" and type(task.wait) == "function" then
    local pending = #MODULE_MANIFEST; local deadline = os.clock() + 30
    for _, entry in ipairs(MODULE_MANIFEST) do
      local name = entry.name
      task.spawn(function()
        local ok, err = xpcall(function() load(name) end, function(value) return debug.traceback(tostring(value), 2) end)
        if not ok then results[name] = { error = err } end
        pending -= 1
      end)
    end
    while pending > 0 do
      if os.clock() >= deadline then return nil, "Loader", "tempo limite ao baixar os módulos" end
      task.wait()
    end
  else
    for _, entry in ipairs(MODULE_MANIFEST) do
      load(entry.name)
    end
  end
  for _, entry in ipairs(MODULE_MANIFEST) do
    local result = results[entry.name]
    if not result or not result.chunk then error(("%s: %s"):format(entry.name, tostring(result and result.error or "carregamento incompleto")), 2) end
  end
  local permissions = execute("permissions", results.permissions.chunk); permissions.validate("permissions", permissions)
  loaded.permissions = register("permissions", permissions)
  for _, entry in ipairs(MODULE_MANIFEST) do
    local name = entry.name
    if name ~= "permissions" then
      local module = execute(name, results[name].chunk); permissions.validate(name, module)
      loaded[name] = register(name, module)
    end
  end
  orderModulesByDependencies(loaded); return loaded
end

-- setup
local function contractOf(module)
  if type(module) ~= "table" then return {} end
  return module.__contract or {}
end
local function collectCharacterBinds(loaded)
  local binds = {}
  for _, name in ipairs(MODULE_ORDER) do
    local module = loaded[name]
    if name ~= "utils" and type(module) == "table" then
      local contract = contractOf(module); local hasBindFlag = contract.bindCharacter == true
      local hasBindFn = type(module.bindCharacter) == "function"; local hasDetachFn = type(module.detachCharacter) == "function"
      if hasBindFlag and hasBindFn and hasDetachFn then binds[#binds + 1] = { name = name, bind = module.bindCharacter, detach = module.detachCharacter }
      elseif hasBindFlag then return nil, name, "contrato bindCharacter incompleto" end
    end
  end
  return binds
end
local function initializeModules(loaded)
  local characterBinds, bindModule, bindError = collectCharacterBinds(loaded)
  if not characterBinds then error(("%s: %s"):format(tostring(bindModule), tostring(bindError)), 2) end
  for _, name in ipairs(MODULE_ORDER) do
    if name ~= "utils" and name ~= "config" and name ~= "uiconfig" then
      local module = loaded[name]
      if type(module) ~= "table" or type(module.setup) ~= "function" then error("API interna ausente: " .. name .. ".setup", 2) end
      local deps = loaded.permissions.resolve(name, loaded)
      if name == "character" then deps.characterBinds = characterBinds end
      local initialized, setupError = module.setup(deps)
      if initialized ~= true then error(("%s.setup falhou: %s"):format(name, tostring(setupError or initialized)), 2) end
    end
  end
  return true
end

-- runtime
local function bindRuntime(loaded)
  local utils = loaded.utils; local gameInfo = loaded.gameinfo
  local remote = loaded.remote
  if
    type(gameInfo) ~= "table"
    or type(gameInfo.applySync) ~= "function"
    or type(gameInfo.installBallWatcher) ~= "function"
    or type(gameInfo.getSyncData) ~= "function"
    or type(remote) ~= "table"
    or type(gameInfo.bindBallSync) ~= "function"
    or type(gameInfo.startMaintenance) ~= "function"
    or type(gameInfo.stopMaintenance) ~= "function"
  then
    return nil, "contrato de runtime incompleto"
  end
  local ballSyncSubscribers = {}
  for _, name in ipairs(MODULE_ORDER) do
    local module = loaded[name]
    if name ~= "utils" and type(module) == "table" then
      local contract = contractOf(module)
      if contract.onBallSync == true and type(module.onBallSync) ~= "function" then return nil, "contrato BallSync incompleto: " .. name end
      if contract.onBallSync == true then
        ballSyncSubscribers[#ballSyncSubscribers + 1] = {
          name = name,
          handler = module.onBallSync,
        }
      end
    end
  end
  local syncPriority = { autoparry = 1, autospam = 2 }
  table.sort(ballSyncSubscribers, function(a, b)
    local left, right = syncPriority[a.name] or 3, syncPriority[b.name] or 3; return left == right and a.name < b.name or left < right
  end)
  local syncErrors = {}
  local function notifyBallSync(decodedData)
    if type(decodedData) ~= "table" then return end
    for _, sub in ipairs(ballSyncSubscribers) do
      local ok, result, detail = pcall(sub.handler, decodedData)
      if not ok or result == false then
        local message = not ok and debug.traceback(tostring(result), 2) or tostring(detail or "handler retornou false"); local time = os.clock()
        if not syncErrors[sub.name] or time - syncErrors[sub.name] >= 1 then
          syncErrors[sub.name] = time; local reported, reportError = pcall(utils.recordError, sub.name .. ".onBallSync", message)
          if not reported then printRawError(sub.name, reportError) end
        end
      end
    end
  end
  local pendingSyncRefresh = false
  local function scheduleSyncRefresh()
    if pendingSyncRefresh then return end
    pendingSyncRefresh = true
    task.defer(function()
      pendingSyncRefresh = false
      if not utils.isActive() then return end
      local refreshed = gameInfo.applySync(nil)
      if type(refreshed) == "table" then notifyBallSync(refreshed) end
    end)
  end
  local lastClashPacketSequence
  local function onBallSync(...)
    local argCount = select("#", ...)
    local data
    for index = 1, argCount do
      local value = select(index, ...)
      if typeof(value) == "buffer" then
        if type(gameInfo.decodeBallPacket) == "function" then
          local packet = gameInfo.decodeBallPacket(value)
          if type(packet) == "table" and type(packet.Sequence) == "number" then
            local sequence = packet.Sequence; local current = gameInfo.getSyncSequence and gameInfo.getSyncSequence()
            local forward = not lastClashPacketSequence or (sequence - lastClashPacketSequence) % 65536; local currentDelta = type(current) == "number" and (sequence - current) % 65536 or 0
            if (forward == true or forward < 32768) and currentDelta < 32768 then
              lastClashPacketSequence = sequence; packet.Source = "packet"
              if type(gameInfo.applyPacket) == "function" then gameInfo.applyPacket(packet) end
              notifyBallSync(packet)
            end
          end
        end
        if buffer.len(value) >= 92 and bit32.btest(buffer.readu8(value, 0), 1) then
          local sequence = buffer.readu16(value, 1); local current = gameInfo.getSyncSequence and gameInfo.getSyncSequence()
          if type(current) ~= "number" or (sequence - current) % 65536 < 32768 then notifyBallSync({ Teleported = true, TeleportSequence = sequence }) end
        end
        scheduleSyncRefresh(); return
      end
      if type(value) == "table" then data = value; break end
      if type(value) == "string" then
        local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, value)
        if decodedOk and type(decoded) == "table" then data = decoded; break end
      end
    end
    local decodedData = gameInfo.applySync(data)
    if type(decodedData) ~= "table" then scheduleSyncRefresh(); return end
    decodedData = table.clone(decodedData); decodedData.Source = "packet"
    notifyBallSync(decodedData)
  end
  local watcherReady = gameInfo.installBallWatcher(utils.trackGlobal)
  if watcherReady ~= true then error("GameInfo.installBallWatcher falhou", 2) end
  local syncReady = gameInfo.bindBallSync(onBallSync)
  local maintenanceReady = gameInfo.startMaintenance({
    isActive = utils.isActive,
    onBallSync = onBallSync,
  })
  if maintenanceReady ~= true then error("GameInfo.startMaintenance falhou", 2) end
  local parryReady = gameInfo.getDeflectAbility() ~= nil
  return {
    parryRemote = parryReady,
    parryInitialized = parryReady,
    watcher = watcherReady == true,
    ballSync = syncReady == true,
    maintenance = maintenanceReady == true,
    ballSyncSubscribers = #ballSyncSubscribers,
  }
end

-- interface
local function loadInterface(loaded, controls)
  local interface = loaded.ui
  if type(interface) ~= "table" then return false, "UI", "módulo não carregado" end
  if type(interface.setup) ~= "function" then return false, "UI", "setup ausente" end
  local function navigate(method)
    local function status(message) notifyPersistent(message, "server_navigation", "info", 5) end
    local ok, detail = loaded.servers[method](status)
    if not ok then
      loaded.utils.recordError("Servers", tostring(detail))
      notifyPersistent(tostring(detail), "server_navigation", "warning", 5)
    end
  end
  controls.onRejoin = function() navigate("rejoin") end
  controls.onServerHop = function() navigate("hop") end
  local dependencies = loaded.permissions.resolve("ui", loaded); dependencies.Controls = controls
  local setupResult, setupError = interface.setup(dependencies)
  if setupResult ~= true then return false, "UI", setupError end
  return true
end
local function stopStartup(utils, moduleName, reason)
  utils.stop(); return false, moduleName, reason
end
local function configureModules(loaded, utils, urls)
  for _, entry in ipairs(MODULE_MANIFEST) do
    local module = loaded[entry.name]
    if type(module) == "table" and module.__config and not loaded.config.register(entry.name, module.__config) then return false, "Config", "schema duplicado ou inválido: " .. entry.name end
  end
  if type(utils.setConfigModule) ~= "function" or not utils.setConfigModule(loaded.config) then return false, "Utils", "schema de Config indisponível" end
  local defaults = loaded.config.defaults()
  if type(defaults) ~= "table" then return false, "Config", "defaults inválidos" end
  local configValid, configReason = loaded.config.validate(defaults)
  if configValid ~= true then return false, "Config", configReason end
  utils.setLifecyclePhase("configuring")
  if not utils.setConfig(defaults) then return false, "Utils", "setConfig rejeitou a configuração inicial" end
  if type(utils.loadConfig) == "function" then utils.loadConfig() end
  if not utils.setModuleURLs(urls) then return false, "Utils", "setModuleURLs rejeitou as URLs dos módulos" end
  return true
end

-- startup
local activeLoaded
local function waitForLocalPlayer(timeout)
  local players = game:GetService("Players")
  if players.LocalPlayer then return true end
  local deadline = os.clock() + timeout
  repeat
    task.wait()
    if players.LocalPlayer then return true end
  until os.clock() >= deadline
  return false, "LocalPlayer indisponível após esperar " .. timeout .. "s"
end
local reloadInFlight = false
local function reloadLatest(onFailure, requestedRevision, automatic)
  local function fail(message)
    warn("[Exodus Reload] " .. tostring(message))
    if automatic then clearPersistent("update"); notifyPersistent("Update failed. Check the console.", "critical", "critical") end
    if automatic and type(_G.ExodusUIRestore) == "function" then pcall(_G.ExodusUIRestore, message) end
    if type(onFailure) == "function" then task.defer(onFailure, message) end
    reloadInFlight = false
  end
  if reloadInFlight then return false, "reload already in progress" end
  reloadInFlight = true
  if automatic then notifyPersistent("Updating...", "update", "info") end
  task.spawn(function()
    local revision = validRevision(requestedRevision) and requestedRevision
    local revisionError
    if not revision then revision, revisionError = resolveLatestRevision() end
    if not revision then fail(revisionError or "Version manifest unavailable"); return end
    local source, fetchError = request(BASE_URL .. revision .. "/" .. PROJECT_PATH .. "loader.luau")
    if not source then fail(fetchError); return end
    if automatic and type(_G.ExodusUIFadeOut) == "function" then
      local faded, fadeError = pcall(_G.ExodusUIFadeOut)
      if not faded then warn("[Exodus Reload] Fade out failed: " .. tostring(fadeError)) end
    end
    local chunk, compileError = compile("reload loader", source)
    if not chunk then fail(compileError); return end
    _G.ExodusRequestedRevision = revision
    local ok, executionError = xpcall(chunk, function(err) return debug.traceback(tostring(err), 2) end)
    if not ok then
      _G.ExodusRequestedRevision = nil; fail(executionError)
      return
    end
    reloadInFlight = false
  end)
  return true
end
local startupPerformed = false
local function startInternal()
  local wasStarted = Exodus.Started == true; local requestedRevision = validRevision(_G.ExodusRequestedRevision) and _G.ExodusRequestedRevision or nil
  _G.ExodusRequestedRevision = nil; local version, _, _, signatures = resolveLatestRevision()
  if requestedRevision and version ~= requestedRevision then return false, "Loader", "revisão solicitada não é a atual" end
  releaseSignatures = signatures
  if not version then return false, "Authorization", "revisão de distribuição indisponível" end
  local authorized, authorizationError = authorizeRevision(version)
  if not authorized then return false, "Authorization", authorizationError end
  startupPerformed = true; printStartup("Exodus: Initializing...")
  _G.ExodusShutdownReason = requestedRevision and "update" or "restart"
  if not stopPreviousRuntime() then _G.ExodusShutdownReason = nil; return false, "Loader", "failed to stop the previous session" end
  _G.ExodusShutdownReason = nil; clearRegistry()
  local playerReady, playerError = waitForLocalPlayer(10)
  if not playerReady then return false, "Loader", playerError end
  local urls = buildURLs(version); local loaded, moduleName, loadError = loadModules(urls)
  if not loaded then return false, moduleName, loadError end
  activeLoaded = loaded; local utils = loaded.utils
  if type(utils.start) ~= "function" or type(utils.setLifecyclePhase) ~= "function" then return false, "Utils", "contrato de inicialização incompleto" end
  utils.start(); utils.setLifecyclePhase("loading")
  Exodus.Utils = utils; Exodus.State = utils.getStateSnapshot()
  local configured, configModuleName, configError = configureModules(loaded, utils, urls)
  if not configured then return stopStartup(utils, configModuleName, configError) end
  Exodus.Config = utils.getConfigSnapshot(); Exodus.ModuleURLs = utils.getModuleURLsSnapshot()
  utils.setLifecyclePhase("initializing"); local modulesReady, failedModule, modulesError = initializeModules(loaded)
  if not modulesReady then return stopStartup(utils, failedModule, modulesError) end
  if not utils.setDiagnosticsModules(loaded) then return stopStartup(utils, "Utils", "setDiagnosticsModules rejeitou os módulos") end
  utils.setLifecyclePhase("binding"); local runtime, runtimeError = bindRuntime(loaded)
  if type(runtime) ~= "table" then return stopStartup(utils, "Runtime", runtimeError) end
  Exodus.Runtime = runtime; _G.ExodusOnBurst = loaded.autoparry.fire
  local uiReady, uiModule, uiError = loadInterface(loaded, {
    onAutoDarkChanged = function() loaded.autodark.sync() end,
    onAutoJumpChanged = function() loaded.autojump.sync() end,
    onUpDash = function()
      local ok, err = loaded.movement.upDash()
      if not ok then utils.recordError("UpDash", err or "Dash indisponível") end
    end,
    onUniversalToggle = function(feature, enabled)
      local module = loaded[feature:lower()]
      if not module then return end
      local ok, err = module.setEnabled(enabled)
      if not ok then utils.recordError("Universal." .. tostring(feature), err or "falha ao alterar recurso") end
    end,
    onUniversalValue = function(feature, value)
      local module = loaded[feature:lower()]
      if not module or type(module.setValue) ~= "function" then return end
      local ok, err = module.setValue(value)
      if not ok then utils.recordError("Universal." .. tostring(feature), err or "falha ao alterar valor") end
    end,
    onPanic = function()
      loaded.autoparry.resetState(); loaded.autospam.stopSpam()
    end,
    onClose = function() utils.stop() end,
    onReload = reloadLatest,
  })
  if not uiReady then return stopStartup(utils, uiModule, uiError) end
  Exodus.Context = loaded; Exodus.UIReady = uiReady == true
  Exodus.UI = Modules.ui; utils.setLifecyclePhase(uiReady == true and "ready" or "runtime_ready")
  Exodus.Started = true; Exodus.Version = utils.version()
  Exodus.Revision = version; _G.ExodusLastLoadedRevision = version
  if requestedRevision then clearPersistent("update"); printStartup("Exodus: Update completed.") elseif wasStarted then printStartup("Exodus: Reloaded.") else printStartup("Exodus: Initialized.") end
  return true
end

-- rollback
local function rollbackLoaded(loaded)
  if type(loaded) ~= "table" then return end
  for index = #MODULE_ORDER, 1, -1 do
    local name = MODULE_ORDER[index]; local module = loaded[name]
    if type(module) == "table" then
      if type(module.teardown) == "function" then cleanupCall(name, module.teardown)
      elseif type(module.detachCharacter) == "function" then cleanupCall(name, module.detachCharacter)
      elseif type(module.resetState) == "function" then cleanupCall(name, module.resetState) end
    end
  end
  if type(loaded.gameinfo) == "table" and type(loaded.gameinfo.stopMaintenance) == "function" then cleanupCall("gameinfo", loaded.gameinfo.stopMaintenance) end
  if type(loaded.utils) == "table" and type(loaded.utils.stop) == "function" then cleanupCall("utils", loaded.utils.stop) end
end
local startLock = false
local startToken = {}
function Loader.start()
  if startLock or _G.ExodusLoaderStartToken then return false, "Loader", "startup já em andamento" end
  local ready, reason = validateExecutor()
  if not ready then return false, "Loader", reason end
  startLock = true; startupPerformed = false
  _G.ExodusLoaderStartToken = startToken; Exodus.Modules = Modules
  _G.Exodus = Exodus; _G.ExodusModules = Modules
  local ok, started, moduleName, startError = xpcall(startInternal, function(err) return debug.traceback(tostring(err), 2) end)
  startLock = false
  if _G.ExodusLoaderStartToken == startToken then _G.ExodusLoaderStartToken = nil end
  if not ok then
    rollbackLoaded(activeLoaded); activeLoaded = nil
    clearRegistry(); return false, "Loader", started
  end
  if started ~= true then
    rollbackLoaded(activeLoaded); activeLoaded = nil
    clearRegistry(); return started, moduleName, startError
  end
  if startupPerformed then
    Exodus.Loader = Loader; Modules.Loader = Loader
    _G.ExodusLoaderSessionToken = startToken
  end
  activeLoaded = nil; return started, moduleName, startError
end
local function startSafely()
  local started, moduleName, startError = Loader.start()
  if started ~= true then
    moduleName = moduleName or "Loader"; startError = startError or started
    local entry = MODULE_BY_NAME[moduleName]; printRawError(moduleName, startError, entry and entry.path or "loader.luau")
    notifyCritical(moduleName)
    Loader.lastError = startError
    Loader.lastErrorModule = moduleName
    Exodus.StartError = startError
    Exodus.StartErrorModule = moduleName; error(("%s: %s"):format(tostring(moduleName), tostring(startError)), 2)
  end
  Loader.lastError = nil; Loader.lastErrorModule = nil
  Exodus.StartError = nil; Exodus.StartErrorModule = nil
  return true
end
local function startUpdateChannel()
  closeUpdateChannel(); local sessionToken = _G.ExodusLoaderSessionToken
  local token = {}; _G.ExodusUpdateToken = token
  local messageConnection, closeConnection, socket, connecting, checking = nil, nil, nil, false, false
  local function active() return _G.ExodusUpdateToken == token and _G.ExodusLoaderSessionToken == sessionToken and Exodus.Started == true end
  local function disconnectSocket()
    if messageConnection then pcall(messageConnection.Disconnect, messageConnection); messageConnection = nil end
    if closeConnection then pcall(closeConnection.Disconnect, closeConnection); closeConnection = nil end
    local old = socket; socket = nil
    if _G.ExodusUpdateSocket == old then _G.ExodusUpdateSocket = nil end
    if old then pcall(function() old:Close() end) end
  end
  local function checkRevision()
    if not active() or checking or reloadInFlight then return end
    checking = true
    task.spawn(function()
      local ok, revision = pcall(resolveLatestRevision)
      checking = false
      if ok and active() and validRevision(revision) and revision ~= (_G.ExodusLastLoadedRevision or Exodus.Revision) then
        reloadLatest(nil, revision, true)
      end
    end)
  end
  local function connectSocket()
    if not active() or socket or connecting or type(WebSocket) ~= "table" or type(WebSocket.connect) ~= "function" then return end
    connecting = true
    task.spawn(function()
      local ok, candidate = pcall(WebSocket.connect, UPDATE_WS_URL); connecting = false
      if not active() then if candidate then pcall(function() candidate:Close() end) end; return end
      if not ok or not candidate or not candidate.OnMessage or type(candidate.OnMessage.Connect) ~= "function" then
        if candidate then pcall(function() candidate:Close() end) end; return
      end
      socket, _G.ExodusUpdateSocket = candidate, candidate
      messageConnection = candidate.OnMessage:Connect(function(raw)
        local decoded, event = pcall(HttpService.JSONDecode, HttpService, tostring(raw))
        if decoded and type(event) == "table" and event.event == "message" and validRevision(tostring(event.message or "")) then checkRevision() end
      end)
      if candidate.OnClose and type(candidate.OnClose.Connect) == "function" then
        closeConnection = candidate.OnClose:Connect(function() if socket == candidate then disconnectSocket() end end)
      end
      checkRevision()
    end)
  end
  _G.ExodusUpdateStop = function()
    if _G.ExodusUpdateToken == token then _G.ExodusUpdateToken = nil end
    disconnectSocket()
  end
  task.spawn(function()
    while active() do
      connectSocket(); checkRevision()
      task.wait(5)
    end
  end)
  return true
end
local started = startSafely()
Exodus.Started = started == true
if started and startupPerformed then startUpdateChannel() end

return Loader

