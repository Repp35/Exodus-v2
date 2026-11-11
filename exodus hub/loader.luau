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
local Exodus = type(_G.Exodus) == "table" and _G.Exodus or {}
local Modules = type(Exodus.Modules) == "table" and Exodus.Modules or {}

-- configuration
local CONFIG = {
  DELIVERY_BASE_URL = "https://repp35.github.io/Exodus-v2/",
  MANIFEST_URL = "https://repp35.github.io/Exodus-v2/manifest.json",
  PROJECT_PATH = "exodus%20hub/",
  AUTHORIZATION_PATH = "security/entitlements.luau",
  LOCAL_ROOTS = { "Exodus-v2/exodus hub", "Exodus-v2-main/exodus hub", "exodus hub", "Exodus Hub" },
  CACHE_ROOT = "Exodus Hub/Cache",
  VERSION_FILE = "Exodus Hub/current_version.txt",
  ALLOW_LOCAL_FALLBACK = false,
  MODULES = {
    { name = "permissions", path = "modules/logic/permissions.luau" },
    { name = "config", path = "modules/front/config.luau" },
    { name = "uiconfig", path = "modules/front/uiconfig.luau" },
    { name = "utils", path = "modules/logic/utils.luau" },
    { name = "gameinfo", path = "modules/logic/gameinfo.luau" },
    { name = "clashstats", path = "modules/logic/clashstats.luau" },
    { name = "autodark", path = "modules/logic/extras/autodark.luau" },
    { name = "movement", path = "modules/logic/movement.luau" },
    { name = "autojump", path = "modules/logic/extras/autojump.luau" },
    { name = "camera", path = "modules/logic/extras/camera.luau" },
    { name = "remote", path = "modules/logic/remote.luau" },
    { name = "autofierce", path = "modules/logic/extras/autofierce.luau" },
    { name = "autoparry", path = "modules/logic/autoparry.luau" },
    { name = "dash", path = "modules/logic/dash.luau" },
    { name = "autospam", path = "modules/logic/autospam.luau" },
    { name = "autodash", path = "modules/logic/extras/autodash.luau" },
    { name = "spam", path = "modules/logic/spam.luau" },
    { name = "character", path = "modules/logic/character.luau" },
    { name = "ui", path = "modules/front/ui.luau" },
  },
}

local PROJECT_PATH = CONFIG.PROJECT_PATH
local AUTHORIZATION_PATH = CONFIG.AUTHORIZATION_PATH
local LOCAL_ROOTS = CONFIG.LOCAL_ROOTS
local CACHE_ROOT, VERSION_FILE = CONFIG.CACHE_ROOT, CONFIG.VERSION_FILE
local BASE_URL = CONFIG.DELIVERY_BASE_URL
local MANIFEST_URL = CONFIG.MANIFEST_URL
local CACHE_BUSTER = tostring(os.time())
local HttpService = game:GetService("HttpService")
local MODULE_MANIFEST = CONFIG.MODULES
local MODULE_ORDER = {}
local MODULE_BY_NAME = {}
for _, entry in ipairs(MODULE_MANIFEST) do
  MODULE_BY_NAME[entry.name] = entry
  if entry.name ~= "ui" and entry.name ~= "permissions" then MODULE_ORDER[#MODULE_ORDER + 1] = entry.name end
end
local ALLOW_LOCAL_FALLBACK = CONFIG.ALLOW_LOCAL_FALLBACK

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
local function findCompleteLocalRoot()
  if not ALLOW_LOCAL_FALLBACK or type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end
  for _, root in ipairs(LOCAL_ROOTS) do
    local complete = true
    for _, entry in ipairs(MODULE_MANIFEST) do
      if not isfile(root .. "/" .. entry.path) then complete = false; break end
    end
    if complete then return root end
  end
  return nil
end
local function validRevision(value) return type(value) == "string" and #value == 40 and value:match("^[%x]+$") ~= nil end
local function persistentStorageAvailable()
  return type(isfile) == "function"
    and type(readfile) == "function"
    and type(writefile) == "function"
    and type(isfolder) == "function"
    and type(makefolder) == "function"
end
local function ensureFolder(path)
  if isfolder(path) then return true end
  local ok = pcall(makefolder, path); return ok or isfolder(path)
end
local function cachePath(revision) return CACHE_ROOT .. "/" .. revision end
local function ensureCacheRoot(revision)
  if not persistentStorageAvailable() or not validRevision(revision) then return nil end
  local ok, root = pcall(function()
    if not ensureFolder(CONFIG.CACHE_ROOT:match("^([^/]+)") or CONFIG.CACHE_ROOT) or not ensureFolder(CACHE_ROOT) or not ensureFolder(cachePath(revision)) then return nil end
    return cachePath(revision)
  end)
  return ok and root or nil
end
local function findCompleteCacheRoot(revision)
  if not persistentStorageAvailable() or not validRevision(revision) then return nil end
  local root = cachePath(revision)
  for _, entry in ipairs(MODULE_MANIFEST) do
    if not isfile(root .. "/" .. entry.path) then return nil end
  end
  return root
end
local function readSavedRevision()
  if not persistentStorageAvailable() or not isfile(VERSION_FILE) then return nil end
  local ok, value = pcall(readfile, VERSION_FILE); value = ok and type(value) == "string" and value:match("([%x]+)") or nil
  return validRevision(value) and value or nil
end
local function saveCurrentRevision(revision)
  if not persistentStorageAvailable() or not validRevision(revision) then return false end
  local ok = pcall(function()
    ensureFolder(CONFIG.CACHE_ROOT:match("^([^/]+)") or CONFIG.CACHE_ROOT); writefile(VERSION_FILE, revision)
  end)
  return ok
end
local function saveCacheFile(revision, relativePath, source)
  local root = ensureCacheRoot(revision)
  if not root or type(source) ~= "string" then return false end
  local directory = root; local parts = {}
  for part in string.gmatch(relativePath, "[^/]+") do
    parts[#parts + 1] = part
  end
  for index = 1, #parts - 1 do
    directory = directory .. "/" .. parts[index]
    if not ensureFolder(directory) then return false end
  end
  local ok = pcall(writefile, root .. "/" .. relativePath, source); return ok
end
local function readCacheFile(revision, relativePath)
  if not persistentStorageAvailable() or not validRevision(revision) then return nil end
  local ok, source = pcall(readfile, cachePath(revision) .. "/" .. relativePath); return ok and type(source) == "string" and source ~= "" and source or nil
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
  local clean = true; _G.ExodusUpdaterToken = nil
  local function attempt(name, action)
    local ok, result = cleanupCall(name, action)
    if not ok then clean = false end
    return ok, result
  end
  if type(Modules.gameinfo) == "table" and type(Modules.gameinfo.stopMaintenance) == "function" then attempt("gameinfo", Modules.gameinfo.stopMaintenance) end
  for _, name in ipairs({
    "character",
    "spam",
    "autodash",
    "autospam",
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
    request(MANIFEST_URL .. "?exodus_cache=" .. CACHE_BUSTER, { ["Accept"] = "application/json", ["User-Agent"] = "Exodus-Hub-Loader" })
  if body then
    local ok, document = pcall(HttpService.JSONDecode, HttpService, body); local valid = ok and type(document) == "table" and document.schema == 1 and document.product == "Exodus-v2"
    local sha = valid and document.revision or nil
    if validRevision(sha) then return sha end
    if ok and type(document) == "table" and not valid then requestError = "manifesto de versão incompatível" end
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
local function loadModule(name, relativePath, url, sourceRoot, cacheRevision)
  if sourceRoot then
    local path = sourceRoot .. "/" .. relativePath; local source = readfile(path)
    if type(source) ~= "string" or source == "" then error("Arquivo local inválido: " .. path, 2) end
    local chunk, compileError = compile(name .. " [local]", source); return chunk, compileError, "local"
  end
  if cacheRevision then
    local cachedSource = readCacheFile(cacheRevision, relativePath)
    if cachedSource then
      local cachedChunk, cachedError = compile(name .. " [cache]", cachedSource)
      if cachedChunk then return cachedChunk, nil, "cache" end
      if not url then return nil, cachedError end
    end
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
    if chunk then
      if cacheRevision then saveCacheFile(cacheRevision, relativePath, source) end
      return chunk, nil, sourceKind
    end
    fetchError = compileError
  end
  return nil, fetchError or "origem remota indisponível"
end
local function authorizationURL(revision) return BASE_URL .. revision .. "/" .. AUTHORIZATION_PATH .. "?exodus_cache=" .. CACHE_BUSTER end
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
  local source = readCacheFile(revision, AUTHORIZATION_PATH)
  local fetchError
  if not source then
    source, fetchError = request(authorizationURL(revision), { ["Accept"] = "text/plain", ["User-Agent"] = "Exodus-Hub-Authorization" })
    if source then saveCacheFile(revision, AUTHORIZATION_PATH, source) end
  end
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
  if expiresAt > 0 and os.time() >= expiresAt then return false, "autorização expirada" end
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
local function loadModules(urls, sourceRoot, cacheRevision)
  local loaded, results = {}, {}
  local function load(name)
    local entry = MODULE_BY_NAME[name]; local chunk, loadError = loadModule(name, entry.path, urls[name], sourceRoot, cacheRevision)
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
    or type(gameInfo.applyPacket) ~= "function"
    or type(gameInfo.decodeBallPacket) ~= "function"
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
  local syncPriority = { autospam = 1, autoparry = 2 }
  table.sort(ballSyncSubscribers, function(a, b)
    local left, right = syncPriority[a.name] or 3, syncPriority[b.name] or 3; return left == right and a.name < b.name or left < right
  end)
  local syncErrors = {}
  local function notifyBallSync(decodedData)
    if type(decodedData) ~= "table" then return end
    for _, sub in ipairs(ballSyncSubscribers) do
      local ok, err = xpcall(function()
        local result, detail = sub.handler(decodedData)
        if result == false then error(tostring(detail), 0) end
      end, function(value) return debug.traceback(tostring(value), 2) end)
      if not ok then
        local time = os.clock()
        if not syncErrors[sub.name] or time - syncErrors[sub.name] >= 1 then
          syncErrors[sub.name] = time; local reported, reportError = pcall(utils.recordError, sub.name .. ".onBallSync", err)
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
  local function onBallSync(...)
    local argCount = select("#", ...)
    local data
    for index = 1, argCount do
      local value = select(index, ...)
      if typeof(value) == "buffer" then
        local decoded, packet = pcall(gameInfo.decodeBallPacket, value)
        if decoded and type(packet) == "table" and type(packet.Sequence) == "number" then
          packet.Source = "packet"; local appliedOk, applied = pcall(gameInfo.applyPacket, packet)
          if appliedOk and applied == true and not packet.Teleported then notifyBallSync(packet) end
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
local function reloadLatest(onFailure)
  local function fail(message)
    warn("[Exodus Reload] " .. tostring(message))
    if type(onFailure) == "function" then task.defer(onFailure, message) end
    reloadInFlight = false
  end
  if reloadInFlight then fail("reload já em andamento"); return false end
  reloadInFlight = true
  task.spawn(function()
    local revision, revisionError = resolveLatestRevision()
    if not revision then fail(revisionError); return end
    local source = readCacheFile(revision, "loader.luau")
    local fetchError
    if not source then source, fetchError = request(BASE_URL .. revision .. "/" .. PROJECT_PATH .. "loader.luau") end
    if not source then fail(fetchError); return end
    saveCacheFile(revision, "loader.luau", source); local chunk, compileError = compile("reload loader", source)
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
  local requestedRevision = validRevision(_G.ExodusRequestedRevision) and _G.ExodusRequestedRevision or nil; _G.ExodusRequestedRevision = nil
  local version, revisionError = requestedRevision, nil
  if not version then version, revisionError = resolveLatestRevision() end
  if not version then version = readSavedRevision() end
  if not version then return false, "Authorization", "revisão de distribuição indisponível" end
  local authorized, authorizationError = authorizeRevision(version)
  if not authorized then return false, "Authorization", authorizationError end
  local sourceRoot = version and findCompleteCacheRoot(version) or findCompleteLocalRoot(); startupPerformed = true
  printStartup("Exodus: iniciando")
  if not stopPreviousRuntime() then return false, "Loader", "falha ao encerrar a sessão anterior" end
  clearRegistry(); local playerReady, playerError = waitForLocalPlayer(10)
  if not playerReady then return false, "Loader", playerError end
  local unpinned = not validRevision(version) and not sourceRoot
  if unpinned then return false, "Loader", "revisão remota indisponível e nenhum cache/local completo: " .. tostring(revisionError) end
  local cacheRevision = validRevision(version) and version or nil
  if cacheRevision then sourceRoot = findCompleteCacheRoot(cacheRevision) end
  local urls = version and buildURLs(version) or {}; local loaded, moduleName, loadError = loadModules(urls, sourceRoot, cacheRevision)
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
  Exodus.Revision = cacheRevision
  if cacheRevision then saveCurrentRevision(cacheRevision) end
  printStartup("Exodus: iniciado"); return true
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
    Loader.lastError = startError
    Loader.lastErrorModule = moduleName
    Exodus.StartError = startError
    Exodus.StartErrorModule = moduleName; error(("%s: %s"):format(tostring(moduleName), tostring(startError)), 2)
  end
  Loader.lastError = nil; Loader.lastErrorModule = nil
  Exodus.StartError = nil; Exodus.StartErrorModule = nil
  return true
end
local started = startSafely()
Exodus.Started = started == true
if started and startupPerformed then
  local revision = Exodus.Revision or readSavedRevision()
  if not validRevision(revision) then warn("[Exodus Updater] revisão ativa indisponível; atualização automática desativada"); return end
  task.spawn(function()
    local source = validRevision(revision) and readCacheFile(revision, "updater.luau")
    local fetchError
    if not source then source, fetchError = request(BASE_URL .. revision .. "/" .. PROJECT_PATH .. "updater.luau") end
    if not source then warn("[Exodus Updater] " .. tostring(fetchError)); return end
    if _G.ExodusLoaderSessionToken ~= startToken or not Exodus.Started or (Exodus.Revision and validRevision(revision) and Exodus.Revision ~= revision) then return end
    if validRevision(revision) then saveCacheFile(revision, "updater.luau", source) end
    local chunk, compileError = compile("Exodus updater", source)
    if not chunk then warn("[Exodus Updater] " .. tostring(compileError)); return end
    local ok, updater = pcall(chunk)
    if not ok or type(updater) ~= "function" then warn("[Exodus Updater] " .. tostring(updater)); return end
    updater(revision, request, { cacheLoader = saveCacheFile })
  end)
end

return Loader
