-- [[ Loader ]]

local function bootstrapPrint(message)
    local text = tostring(message)
    local essential = text == "loader.luau iniciado"
        or text == "hub inicializado com sucesso"
        or string.find(text, "^ERRO no ponto de entrada:") ~= nil
        or string.find(text, "^[%w_]+ não foi carregado:") ~= nil
    if not essential then
        return
    end
    local output = "[Exodus] " .. text
    if type(print) == "function" then
        pcall(print, output)
    elseif type(warn) == "function" then
        pcall(warn, output)
    end
end
bootstrapPrint("loader.luau iniciado")

local Exodus = type(_G.Exodus) == "table" and _G.Exodus or {}
local Modules = type(Exodus.Modules) == "table" and Exodus.Modules or {}
Exodus.Modules = Modules
_G.Exodus = Exodus
_G.ExodusModules = Modules
local Loader = {}
local HttpService = game:GetService("HttpService")

-- metadata
local REPOSITORY = "Repp35/Exodus-v2"
local BRANCH = "main"
local PROJECT_PATH = "exodus%20hub/"
local LOCAL_ROOTS = { "Exodus-v2", "exodus hub", "Exodus Hub" }
local BASE_URL = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/"
local MODULE_ORDER = {
    "config",
    "utils",
    "gameinfo",
    "remote",
    "autoparry",
    "autoclash",
    "spam",
    "character",
}

-- contrato por m贸dulo: cada m贸dulo declara o pr贸prio via __contract.
-- campos:
--   requires      : deps injetadas no setup(deps). chaves = nomes l贸gicos, valores = chaves em `loaded`.
--   onBallSync    : se true, o m贸dulo recebe BallSyncData automaticamente (precisa exportar onBallSync).
--   ballSync      : se true, o m贸dulo 茅 fornecedor de BallSyncData (ex: remote, gameinfo).
--   bindCharacter : se true, recebe bindCharacter(character) ao spawnar (precisa exportar bind+detach).
-- o loader auto-descobre via __contract 鈥� adicionar m贸dulo novo 茅 s贸 (1) nome em MODULE_ORDER
-- e (2) __contract exportado no pr贸prio m贸dulo.

-- http
local function getGlobalEnvironment()
    if type(getgenv) == "function" then
        local ok, environment = pcall(getgenv)
        if ok and type(environment) == "table" then
            return environment
        end
    end
    return _G
end
local function getRequestFunction()
    local environment = getGlobalEnvironment()
    local synApi = type(environment.syn) == "table" and environment.syn or nil
    local fluxusApi = type(environment.fluxus) == "table" and environment.fluxus or nil
    local candidates = {
        environment.request,
        environment.http_request,
        synApi and synApi.request,
        fluxusApi and fluxusApi.request,
    }
    for _, candidate in ipairs(candidates) do
        if type(candidate) == "function" then
            return candidate
        end
    end
    return nil
end
local function isRetryableHttp(message)
    local statusCode = tonumber(string.match(tostring(message), "HTTP%s+(%d+)"))
    return statusCode == 408
        or statusCode == 425
        or statusCode == 429
        or (statusCode and statusCode >= 500 and statusCode <= 599)
end
local function waitBeforeRetry(attempt)
    if type(task) == "table" and type(task.wait) == "function" then
        local delays = { 0.25, 0.75, 1.5 }
        task.wait(delays[attempt] or delays[#delays])
    end
end
local function request(url, headers)
    if type(url) ~= "string" or url == "" then
        return nil, "URL inv谩lida"
    end
    local lastError
    local requestFunction = getRequestFunction()
    bootstrapPrint("baixando: " .. url)
    for attempt = 1, 3 do
        bootstrapPrint(("tentativa HTTP %d: %s"):format(attempt, url))
        if requestFunction then
            local ok, responseBody = pcall(function()
                local response = requestFunction({
                    Url = url,
                    Method = "GET",
                    Headers = headers,
                })
                if type(response) ~= "table" then
                    error("Resposta HTTP inv谩lida")
                end
                local statusCode = tonumber(response.StatusCode or response.status_code)
                if statusCode and statusCode >= 400 then
                    error("HTTP " .. tostring(statusCode))
                end
                local body = response.Body or response.body or response.ResponseBody
                if type(body) ~= "string" or body == "" then
                    error("Corpo HTTP vazio ou inv谩lido")
                end
                return body
            end)
            if ok and type(responseBody) == "string" and responseBody ~= "" then
                bootstrapPrint(("HTTP OK via request: %d bytes"):format(#responseBody))
                return responseBody
            end
            lastError = tostring(responseBody)
            bootstrapPrint("request falhou: " .. lastError)
        end
        local httpGet
        local httpGetOk = pcall(function()
            httpGet = game.HttpGet
        end)
        if httpGetOk and type(httpGet) == "function" then
            local ok, responseBody = pcall(function()
                return game:HttpGet(url)
            end)
            if ok and type(responseBody) == "string" and responseBody ~= "" then
                bootstrapPrint(("HTTP OK via game:HttpGet: %d bytes"):format(#responseBody))
                return responseBody
            end
            lastError = tostring(responseBody)
            bootstrapPrint("game:HttpGet falhou: " .. lastError)
        end
        if not isRetryableHttp(lastError) then
            break
        end
        waitBeforeRetry(attempt)
    end
    local message = lastError or "Nenhum servi莽o HTTP dispon铆vel"
    bootstrapPrint("download falhou definitivamente: " .. message)
    return nil, message
end

-- local fallback
local function localBaseName(path)
    return string.match(path, "[^\\/]+$") or path
end
local function findLocalModule(name)
    if type(listfiles) ~= "function"
        or type(isfile) ~= "function"
        or type(isfolder) ~= "function"
        or type(readfile) ~= "function"
    then
        return nil, "APIs de filesystem do executor indispon铆veis"
    end
    local target = string.lower(name .. ".luau")
    local matches = {}
    local visited = {}
    local function walk(folder, depth)
        if depth > 32 or visited[folder] then
            return
        end
        visited[folder] = true
        local listOk, entries = pcall(listfiles, folder)
        if not listOk or type(entries) ~= "table" then
            return
        end
        for _, entry in ipairs(entries) do
            if type(entry) == "string" then
                local fileOk, fileExists = pcall(isfile, entry)
                if fileOk and fileExists then
                    if string.lower(localBaseName(entry)) == target then
                        matches[#matches + 1] = entry
                    end
                else
                    local folderOk, folderExists = pcall(isfolder, entry)
                    if folderOk and folderExists then
                        walk(entry, depth + 1)
                    end
                end
            end
        end
    end
    local availableRoots = {}
    for _, root in ipairs(LOCAL_ROOTS) do
        local rootOk, rootExists = pcall(isfolder, root)
        if rootOk and rootExists then
            availableRoots[#availableRoots + 1] = root
            walk(root, 0)
            if #matches > 0 then
                break
            end
        end
    end
    if #matches == 0 then
        return nil, name .. ".luau n茫o encontrado; pastas verificadas: "
            .. table.concat(availableRoots, ", ")
    end
    if #matches > 1 then
        return nil, name .. ".luau amb铆guo: " .. tostring(#matches) .. " arquivos encontrados"
    end
    local readOk, source = pcall(readfile, matches[1])
    if not readOk or type(source) ~= "string" or source == "" then
        return nil, "falha ao ler " .. matches[1]
    end
    return source, matches[1]
end

-- registry
local function register(name, module)
    Modules[name] = module
    return module
end
local function clearRegistry()
    for _, name in ipairs(MODULE_ORDER) do
        Modules[name] = nil
    end
    Modules.ui = nil
    Modules.Loader = Loader
    Exodus.Utils = nil
    Exodus.State = nil
    Exodus.Config = nil
    Exodus.ModuleURLs = nil
    Exodus.Runtime = nil
    Exodus.Context = nil
    Exodus.UI = nil
    Exodus.UIReady = false
    Exodus.Started = false
end
local function stopPreviousRuntime()
    if type(Modules.remote) == "table"
        and type(Modules.remote.stopMaintenance) == "function"
    then
        pcall(Modules.remote.stopMaintenance)
    end
    local stopped = false
    if type(_G.ExodusStop) == "function" then
        local ok = pcall(_G.ExodusStop)
        stopped = ok == true
    end
    if not stopped and type(_G.ExodusUICleanup) == "function" then
        pcall(_G.ExodusUICleanup)
    end
end

-- compiler
local function compile(name, source)
    bootstrapPrint("loadstring: " .. name)
    if type(loadstring) ~= "function" then
        local message = "loadstring n茫o est谩 dispon铆vel neste ambiente"
        bootstrapPrint("ERRO: " .. message)
        return nil, message
    end
    local chunk, compileError = loadstring(source, name)
    if not chunk then
        local message = tostring(compileError)
        bootstrapPrint("ERRO ao compilar " .. name .. ": " .. message)
        return nil, message
    end
    local ok, module = pcall(chunk)
    if not ok then
        local message = tostring(module)
        bootstrapPrint("ERRO ao executar " .. name .. ": " .. message)
        return nil, message
    end
    if type(module) ~= "table" then
        local message = "o m贸dulo n茫o retornou uma tabela"
        bootstrapPrint("ERRO em " .. name .. ": " .. message)
        return nil, message
    end
    bootstrapPrint("OK: " .. name .. " executado por loadstring")
    return module
end

-- version
local function latestVersion()
    local url = ("https://api.github.com/repos/%s/commits/%s?t=%d")
        :format(REPOSITORY, BRANCH, os.time())
    local body = request(url, {
        ["User-Agent"] = "Exodus",
        ["Cache-Control"] = "no-cache",
    })
    if not body then
        return "refs/heads/" .. BRANCH
    end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, body)
    if ok and type(data) == "table"
        and type(data.sha) == "string"
        and #data.sha >= 7
    then
        return data.sha
    end
    return "refs/heads/" .. BRANCH
end

-- urls
local function buildURLs(version)
    local root = BASE_URL
        .. (version or ("refs/heads/" .. BRANCH))
        .. "/"
        .. PROJECT_PATH
        .. "modules/"
    return {
        config = root .. "front/config.luau",
        utils = root .. "logic/utils.luau",
        gameinfo = root .. "logic/gameinfo.luau",
        remote = root .. "logic/remote.luau",
        autoparry = root .. "logic/autoparry.luau",
        autoclash = root .. "logic/autoclash.luau",
        spam = root .. "logic/spam.luau",
        character = root .. "logic/character.luau",
        ui = root .. "front/ui.luau",
    }
end
local function loadModule(name, url)
    bootstrapPrint(("m贸dulo %s | URL %s"):format(name, tostring(url)))
    local source, fetchError = request(url)
    if source then
        local module, compileError = compile(name, source)
        if module then
            return register(name, module), nil, "github"
        end
        fetchError = compileError
    end
    bootstrapPrint("fallback local para " .. name .. ": " .. tostring(fetchError))
    local localSource, localPath = findLocalModule(name)
    if localSource then
        local module, compileError = compile(name .. " [local]", localSource)
        if module then
            return register(name, module), nil, "local"
        end
        return nil, "GitHub: " .. tostring(fetchError)
            .. "; local: " .. tostring(compileError)
    end
    return nil, "GitHub: " .. tostring(fetchError)
        .. "; local: " .. tostring(localPath)
end
local function loadModules(urls, log)
    local loaded = {}
    for _, name in ipairs(MODULE_ORDER) do
        if name ~= "utils" then
            local module, loadError, source = loadModule(name, urls[name])
            if not module then
                local message = ("%s falhou: %s"):format(name, tostring(loadError))
                log.warn(message)
                return nil, message
            end
            loaded[name] = module
            log.info(("%s carregado%s"):format(
                name,
                source == "local" and " localmente" or ""
            ))
        end
    end
    loaded.utils = log
    return loaded
end

-- setup
local function resolveDeps(loaded, requires)
    local deps = {}
    if type(requires) ~= "table" then
        return deps
    end
    for depName, sourceKey in pairs(requires) do
        deps[depName] = loaded[sourceKey]
    end
    return deps
end

local function contractOf(module)
    if type(module) ~= "table" then
        return {}
    end
    return module.__contract or {}
end

local function collectCharacterBinds(loaded)
    local binds = {}
    for name, module in pairs(loaded) do
        if name ~= "utils" and type(module) == "table" then
            local contract = contractOf(module)
            local hasBindFlag = contract.bindCharacter == true
            local hasBindFn = type(module.bindCharacter) == "function"
            local hasDetachFn = type(module.detachCharacter) == "function"
            if hasBindFlag and hasBindFn and hasDetachFn then
                binds[#binds + 1] = {
                    name = name,
                    bind = module.bindCharacter,
                    detach = module.detachCharacter,
                }
            elseif hasBindFlag and not hasBindFn then
                -- Diagn贸stico: o m贸dulo declara que quer bind de personagem
                -- mas n茫o exporta a fun莽茫o com o nome certo. Sem isso o
                -- m贸dulo fica silenciosamente inativo (nunca 茅 chamado no
                -- spawn do character). Logado como erro pra aparecer nos
                -- diagnostics em _G.Exodus.Diagnostics.
                if type(loaded.utils) == "table" and type(loaded.utils.recordError) == "function" then
                    loaded.utils.recordError(
                        "Loader",
                        ("%s declara bindCharacter no contrato mas n茫o exporta m贸dulo.bindCharacter(): o m贸dulo nunca ser谩 vinculado ao personagem")
                            :format(name)
                    )
                end
            end
        end
    end
    return binds
end

local function initializeModules(loaded, log)
    -- descobre todos os binds de personagem uma vez e injeta no deps do character
    local characterBinds = collectCharacterBinds(loaded)
    log.info(("%d m贸dulos com bind de personagem"):format(#characterBinds))
    for _, name in ipairs(MODULE_ORDER) do
        if name ~= "utils" and name ~= "config" then
            local module = loaded[name]
            if type(module) ~= "table" or type(module.setup) ~= "function" then
                log.warn(name .. " n茫o possui setup")
                if type(log.recordError) == "function" then
                    log.recordError("Loader", name .. " n茫o possui setup")
                end
                return false, name .. " não possui setup()"
            end
            local contract = contractOf(module)
            local deps = resolveDeps(loaded, contract.requires)
            if name == "character" then
                deps.characterBinds = characterBinds
            end
            local ok, initialized = pcall(module.setup, deps)
            if not ok or initialized ~= true then
                log.warn(("%s falhou ao inicializar: %s")
                    :format(name, tostring(initialized)))
                if type(log.recordError) == "function" then
                    log.recordError("Loader", name .. " falhou: " .. tostring(initialized))
                end
                return false, ("%s.setup falhou: %s"):format(
                    name,
                    tostring(initialized or "motivo não informado pelo módulo")
                )
            end
            log.info(name .. " inicializado")
        end
    end
    return true
end

-- runtime
local function bindRuntime(loaded, log)
    local utils = loaded.utils
    local gameInfo = loaded.gameinfo
    local remote = loaded.remote
    if type(gameInfo) ~= "table"
        or type(gameInfo.applySync) ~= "function"
        or type(gameInfo.installBallWatcher) ~= "function"
        or type(remote) ~= "table"
        or type(remote.bindBallSync) ~= "function"
        or type(remote.startMaintenance) ~= "function"
    then
        return nil, "contrato de runtime incompleto"
    end
    -- descobre automaticamente todos os m贸dulos com onBallSync via __contract
    local ballSyncSubscribers = {}
    for name, module in pairs(loaded) do
        if name ~= "utils" and type(module) == "table" then
            local contract = contractOf(module)
            if contract.onBallSync == true and type(module.onBallSync) == "function" then
                ballSyncSubscribers[#ballSyncSubscribers + 1] = {
                    name = name,
                    handler = module.onBallSync,
                }
            end
        end
    end
    local function callSync(name, handler, data)
        local ok, result = pcall(handler, data)
        if not ok or result == false then
            local message = ("BallSync %s falhou: %s")
                :format(name, tostring(result))
            log.warn(message)
            if type(log.recordError) == "function" then
                log.recordError(name, message)
            end
        end
    end
    local function onBallSync(data)
        callSync("GameInfo", gameInfo.applySync, data)
        for _, sub in ipairs(ballSyncSubscribers) do
            callSync(sub.name, sub.handler, data)
        end
    end
    local watcherReady = gameInfo.installBallWatcher(utils.trackGlobal)
    if watcherReady then
        log.info("GameInfo conectado 脿 bola")
    else
        log.warn("GameInfo n茫o encontrou o observador da bola")
        if type(log.recordError) == "function" then
            log.recordError("GameInfo", "observador da bola indispon铆vel")
        end
    end
    local syncReady = remote.bindBallSync(onBallSync)
    if syncReady then
        log.info("Remote conectado ao BallSyncData")
        log.info(("%d assinantes de BallSync"):format(#ballSyncSubscribers))
    else
        log.warn("Remote BallSyncData indispon铆vel")
        if type(log.recordError) == "function" then
            log.recordError("Remote", "BallSyncData indispon铆vel")
        end
    end
    local maintenanceOk, maintenanceReady = pcall(remote.startMaintenance, {
        isActive = utils.isActive,
        onBallSync = onBallSync,
    })
    if not maintenanceOk or maintenanceReady ~= true then
        local message = "manuten莽茫o do Remote falhou: " .. tostring(maintenanceReady)
        log.warn(message)
        if type(log.recordError) == "function" then
            log.recordError("Remote", message)
        end
    else
        log.info("manuten莽茫o do Remote iniciada")
    end
    return {
        watcher = watcherReady == true,
        ballSync = syncReady == true,
        maintenance = maintenanceOk and maintenanceReady == true,
        ballSyncSubscribers = #ballSyncSubscribers,
    }
end

-- interface
local function loadInterface(url, utils, controls)
    local interface, loadError, source = loadModule("ui", url)
    if not interface then
        utils.warn("Exodus UI falhou: " .. tostring(loadError))
        return false
    end
    if type(interface.setup) ~= "function" then
        utils.warn("Exodus UI n茫o possui setup")
        return false
    end
    local ok, setupError = pcall(interface.setup, {
        Utils = utils,
        Controls = controls,
    })
    if not ok or setupError ~= true then
        utils.warn("Exodus UI falhou ao inicializar: " .. tostring(setupError))
        return false
    end
    utils.info(source == "local" and "Exodus UI carregada localmente" or "Exodus UI carregada")
    return true
end

-- start
local function waitForLocalPlayer(timeout)
    local ok, players = pcall(game.GetService, game, "Players")
    if not ok or not players then
        return false, "servi莽o Players indispon铆vel"
    end
    local deadline = os.clock() + (tonumber(timeout) or 10)
    repeat
        local playerOk, player = pcall(function()
            return players.LocalPlayer
        end)
        if playerOk and player then
            return true
        end
        if type(task) ~= "table" or type(task.wait) ~= "function" then
            break
        end
        task.wait()
    until os.clock() >= deadline
    return false, "LocalPlayer indispon铆vel ap贸s esperar " .. tostring(timeout or 10) .. "s"
end
function Loader.start()
    bootstrapPrint("inicializa莽茫o do hub iniciada")
    stopPreviousRuntime()
    clearRegistry()
    local playerReady, playerError = waitForLocalPlayer(10)
    if not playerReady then
        return false, playerError
    end
    local version = latestVersion()
    bootstrapPrint("vers茫o remota: " .. tostring(version))
    local urls = buildURLs(version)
    local utils, utilsError = loadModule("utils", urls.utils)
    if not utils then
        bootstrapPrint("ERRO fatal ao carregar utils: " .. tostring(utilsError))
        return false, utilsError
    end
    bootstrapPrint("utils carregado; iniciando o restante")
    utils.start()
    if type(utils.log) == "function" then
        local originalLog = utils.log
        utils.log = function(level, message)
            if level == "warn" then
                return originalLog(level, message)
            end
        end
    end
    utils.setLifecyclePhase("loading")
    Exodus.Utils = utils
    Exodus.State = utils.getStateSnapshot()
    local loaded, loadError = loadModules(urls, utils)
    if not loaded then
        local message = loadError or utilsError or "motivo não informado"
        bootstrapPrint("ERRO ao carregar módulos: " .. tostring(message))
        utils.recordError("Loader", tostring(message))
        utils.stop()
        return false, tostring(message)
    end
    Exodus.Context = loaded
    local defaultsOk, defaults = pcall(loaded.config.defaults)
    if not defaultsOk or type(defaults) ~= "table" then
        local message = "Config.defaults falhou: " .. tostring(defaults)
        utils.warn(message)
        utils.recordError("Config", message)
        utils.stop()
        return false, message
    end
    local configCallOk, configValid, configReason = pcall(loaded.config.validate, defaults)
    if not configCallOk or configValid ~= true then
        local message = "Config.validate falhou: "
            .. tostring(configCallOk and configReason or configValid)
        utils.warn(message)
        utils.recordError("Config", message)
        utils.stop()
        return false, message
    end
    utils.setLifecyclePhase("configuring")
    if not utils.setConfig(defaults) then
        local message = "Utils.setConfig rejeitou a configuração inicial"
        utils.recordError("Loader", message)
        utils.stop()
        return false, message
    end
    if not utils.setModuleURLs(urls) then
        local message = "Utils.setModuleURLs rejeitou as URLs dos módulos"
        utils.recordError("Loader", message)
        utils.stop()
        return false, message
    end
    Exodus.Config = utils.getConfigSnapshot()
    Exodus.ModuleURLs = utils.getModuleURLsSnapshot()
    utils.setLifecyclePhase("initializing")
    local modulesReady, modulesError = initializeModules(loaded, utils)
    if not modulesReady then
        local message = modulesError or "motivo não informado pelo módulo"
        utils.recordError("Loader", message)
        utils.stop()
        return false, message
    end
    if not utils.setDiagnosticsModules(loaded) then
        utils.recordError("Loader", "falha ao registrar diagn贸stico dos m贸dulos")
        utils.stop()
        return false, "falha ao registrar diagnóstico dos módulos"
    end
    utils.setLifecyclePhase("binding")
    local runtimeOk, runtime = pcall(bindRuntime, loaded, utils)
    if not runtimeOk or type(runtime) ~= "table" then
        local message = "runtime falhou: " .. tostring(runtime)
        utils.warn(message)
        utils.recordError("Runtime", message)
        utils.stop()
        return false, message
    end
    Exodus.Runtime = runtime
    _G.ExodusOnBurst = loaded.autoparry.fire
    bootstrapPrint("m贸dulos inicializados; carregando UI")
    local uiReady = loadInterface(urls.ui, utils, {
        onPanic = function()
            loaded.autoparry.resetState()
            utils.setManualSpamActive(false)
            utils.setAutoSpamActive(false)
        end,
    })
    Exodus.UIReady = uiReady == true
    Exodus.UI = Modules.ui
    utils.setLifecyclePhase(uiReady == true and "ready" or "runtime_ready")
    Exodus.Started = true
    Exodus.Version = utils.version()
    utils.info(('%s %s inicializado'):format(utils.name(), utils.version()))
    bootstrapPrint("hub inicializado com sucesso")
    return true
end
Exodus.Loader = Loader
Modules.Loader = Loader
local function formatLoadFailure(message)
    message = tostring(message or "motivo não informado")
    local moduleName, reason = string.match(
        message,
        "^([%w_]+)%.setup falhou:%s*(.*)$"
    )
    if not moduleName then
        moduleName, reason = string.match(
            message,
            "^([%w_]+) falhou:%s*(.*)$"
        )
    end
    if moduleName then
        return moduleName .. " não foi carregado: "
            .. (reason ~= "" and reason or "motivo não informado")
    end
    return "loader não foi carregado: " .. message
end
local function startSafely()
    local ok, started, startError = xpcall(
        Loader.start,
        function(errorValue)
            local message = tostring(errorValue)
            if type(debug) == "table" and type(debug.traceback) == "function" then
                return debug.traceback(message, 2)
            end
            return message
        end
    )
    if not ok then
        startError = started
        started = false
    end
    if started ~= true then
        local diagnostics = type(Exodus.Diagnostics) == "table" and Exodus.Diagnostics or nil
        local lastError = diagnostics and diagnostics.lastError
        local diagnosticMessage = lastError
            and ((tostring(lastError.source) .. ": " .. tostring(lastError.message)))
            or nil
        local message = tostring(startError or diagnosticMessage or "falha desconhecida ao iniciar")
        local formattedMessage = formatLoadFailure(message)
        bootstrapPrint(formattedMessage)
        Loader.lastError = formattedMessage
        Exodus.StartError = formattedMessage
        return false
    end
    Loader.lastError = nil
    Exodus.StartError = nil
    return true
end
local started = startSafely()
Exodus.Started = started == true

return Loader
