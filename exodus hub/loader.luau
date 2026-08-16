--[[ Loader ]]

-- bootstrap
local Exodus = type(_G.Exodus) == "table" and _G.Exodus or {}
local Modules = type(Exodus.Modules) == "table" and Exodus.Modules
    or (type(_G.ExodusModules) == "table" and _G.ExodusModules or {})
Exodus.Modules = Modules
_G.Exodus = Exodus
_G.ExodusModules = Modules
local Loader = {}
local HttpService = game:GetService("HttpService")
local REPOSITORY = "Repp35/Exodus-v2"
local BRANCH = "main"
local PROJECT_PATH = "exodus%20hub/"
local BASE_URL = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/"
local MODULE_ORDER = {
    "Config",
    "Utils",
    "GameInfo",
    "Remote",
    "AutoParry",
    "AutoClash",
    "Spam",
    "Character",
}

-- http
local function request(url, headers)
    if type(url) ~= "string" or url == "" then
        return nil, "URL inválida"
    end
    local lastError
    if type(_G.request) == "function" then
        local ok, body = pcall(function()
            local response = _G.request({
                Url = url,
                Method = "GET",
                Headers = headers,
            })
            if type(response) ~= "table" or type(response.Body) ~= "string" then
                error("Resposta HTTP inválida")
            end
            if type(response.StatusCode) == "number" and response.StatusCode ~= 200 then
                error("HTTP " .. tostring(response.StatusCode))
            end
            return response.Body
        end)
        if ok and type(body) == "string" and body ~= "" then
            return body
        end
        lastError = tostring(body)
    end
    if type(game.HttpGet) == "function" then
        local ok, body = pcall(function()
            return game:HttpGet(url)
        end)
        if ok and type(body) == "string" and body ~= "" then
            return body
        end
        lastError = tostring(body)
    end
    return nil, lastError or "Nenhum serviço HTTP disponível"
end

-- module registry
local function register(name, module)
    Exodus.Modules[name] = module
    return module
end

-- compiler
local function compile(name, source)
    if type(loadstring) ~= "function" then
        return nil, "loadstring não está disponível neste ambiente"
    end
    local chunk, compileError = loadstring(source, name)
    if not chunk then
        return nil, tostring(compileError)
    end
    local ok, module = pcall(chunk)
    if not ok then
        return nil, tostring(module)
    end
    if type(module) ~= "table" then
        return nil, "o módulo não retornou uma tabela"
    end
    return module
end

-- version
local function latestVersion()
    local url = ("https://api.github.com/repos/%s/commits/%s?t=%d"):format(REPOSITORY, BRANCH, os.time())
    local body = request(url, {
        ["User-Agent"] = "Exodus",
        ["Cache-Control"] = "no-cache",
    })
    if not body then
        return "refs/heads/" .. BRANCH
    end
    local ok, data = pcall(HttpService.JSONDecode, HttpService, body)
    if ok and type(data) == "table" and type(data.sha) == "string" and #data.sha >= 7 then
        return data.sha
    end
    return "refs/heads/" .. BRANCH
end

-- urls
local function buildURLs(version)
    local root = BASE_URL .. (version or ("refs/heads/" .. BRANCH)) .. "/" .. PROJECT_PATH .. "modules/"
    return {
        Config = root .. "front/config.luau",
        Utils = root .. "logic/utils.luau",
        GameInfo = root .. "logic/gameinfo.luau",
        Remote = root .. "logic/remote.luau",
        AutoParry = root .. "logic/autoparry.luau",
        AutoClash = root .. "logic/autoclash.luau",
        Spam = root .. "logic/spam.luau",
        Character = root .. "logic/character.luau",
        UI = root .. "front/ui.luau",
    }
end

-- module loader
local function loadModule(name, url)
    local source, fetchError = request(url)
    if not source then
        return nil, fetchError
    end
    local module, compileError = compile(name, source)
    if not module then
        return nil, compileError
    end
    return register(name, module)
end

-- registry reset
local function clearRegistry()
    for _, name in ipairs(MODULE_ORDER) do
        Modules[name] = nil
    end
    Modules.UI = nil
    Modules.Loader = Loader
    Exodus.Utils = nil
    Exodus.State = nil
    Exodus.Config = nil
    Exodus.ModuleURLs = nil
    Exodus.Runtime = nil
    Exodus.UI = nil
    Exodus.UIReady = false
    Exodus.Started = false
end

-- module setup
local function loadModules(urls, log)
    local loaded = { Utils = log }
    for _, name in ipairs(MODULE_ORDER) do
        if name ~= "Utils" then
            local url = urls[name]
            if type(url) ~= "string" then
                log.warn(("%s sem URL configurada"):format(name))
                return nil
            end
            local module, loadError = loadModule(name, url)
            if not module then
                log.warn(("%s falhou: %s"):format(name, tostring(loadError)))
                return nil
            end
            loaded[name] = module
            log.info(("%s carregado e executado"):format(name))
        end
    end
    return loaded
end

-- dependency setup
local function initializeModules(loaded, log)
    local utils = loaded.Utils
    local setup = {
        { "Remote", { Utils = utils } },
        { "GameInfo", { Utils = utils } },
        { "AutoParry", { Remote = loaded.Remote, GameInfo = loaded.GameInfo, Utils = utils } },
        { "AutoClash", { GameInfo = loaded.GameInfo, Utils = utils, AutoParry = loaded.AutoParry } },
        { "Spam", { Remote = loaded.Remote, AutoClash = loaded.AutoClash, Utils = utils } },
        { "Character", {
            AutoParry = loaded.AutoParry,
            AutoClash = loaded.AutoClash,
            Spam = loaded.Spam,
            Utils = utils,
        } },
    }
    for _, entry in ipairs(setup) do
        local name, deps = entry[1], entry[2]
        local module = loaded[name]
        if type(module) ~= "table" or type(module.setup) ~= "function" then
            log.warn(name .. " não possui setup")
            return false
        end
        local ok, initialized = pcall(module.setup, deps)
        if not ok or initialized ~= true then
            log.warn(("%s falhou ao inicializar: %s"):format(name, tostring(initialized)))
            return false
        end
        log.info(name .. " inicializado")
    end
    return true
end

-- runtime
local function bindRuntime(loaded, log)
    local utils = loaded.Utils
    local gameInfo = loaded.GameInfo
    local remote = loaded.Remote
    local autoParry = loaded.AutoParry
    local autoClash = loaded.AutoClash
    local function onBallSync(data)
        local ok, syncError = pcall(function()
            gameInfo.applySync(data)
            autoParry.onBallSync(data)
            autoClash.onBallSync(data)
        end)
        if not ok then
            log.warn("BallSync falhou: " .. tostring(syncError))
        end
    end
    local watcherReady = gameInfo.installBallWatcher(utils.trackGlobal)
    if not watcherReady then
        log.warn("GameInfo não encontrou o observador da bola")
    else
        log.info("GameInfo conectado ao observador da bola")
    end
    local syncReady = remote.bindBallSync(onBallSync)
    if not syncReady then
        log.warn("Remote BallSyncData indisponível")
    else
        log.info("Remote conectado ao BallSyncData")
    end
    local maintenanceCallOk, maintenanceReady = pcall(remote.startMaintenance, {
        isActive = utils.isActive,
        onBallSync = onBallSync,
    })
    if not maintenanceCallOk or maintenanceReady ~= true then
        log.warn("manutenção do Remote falhou: " .. tostring(maintenanceReady))
    else
        log.info("manutenção do Remote iniciada")
    end
    return {
        watcher = watcherReady == true,
        ballSync = syncReady == true,
        maintenance = maintenanceCallOk and maintenanceReady == true,
    }
end

-- interface
local function loadInterface(url, utils, controls)
    local gui, loadError = loadModule("UI", url)
    if not gui then
        utils.warn("Exodus UI falhou: " .. tostring(loadError))
        return false
    end
    if type(gui.setup) ~= "function" then
        utils.warn("Exodus UI não possui setup")
        return false
    end
    local ok, setupError = pcall(gui.setup, {
        Utils = utils,
        Controls = controls,
    })
    if not ok or setupError ~= true then
        utils.warn("Exodus UI falhou ao inicializar: " .. tostring(setupError))
        return false
    end
    utils.info("Exodus UI carregada e executada")
    return true
end

-- start
function Loader.start()
    if type(_G.ExodusUICleanup) == "function" then
        pcall(_G.ExodusUICleanup)
    end
    if type(_G.ExodusStop) == "function" then
        pcall(_G.ExodusStop)
    end
    clearRegistry()
    local version = latestVersion()
    local urls = buildURLs(version)
    local utils = loadModule("Utils", urls.Utils)
    if not utils then
        return false
    end
    utils.start()
    Exodus.Utils = utils
    Exodus.State = utils.getState()
    utils.info("Loader carregado e executado")
    utils.info("Utils carregado e executado")
    local loaded = loadModules(urls, utils)
    if not loaded then
        utils.stop()
        return false
    end
    local defaultsOk, defaults = pcall(loaded.Config.defaults)
    if not defaultsOk or type(defaults) ~= "table" then
        utils.warn("Config.defaults falhou: " .. tostring(defaults))
        utils.stop()
        return false
    end
    utils.setConfig(defaults)
    utils.setModuleURLs(urls)
    Exodus.Config = utils.getConfig()
    Exodus.ModuleURLs = utils.getModuleURLs()
    if not initializeModules(loaded, utils) then
        utils.stop()
        return false
    end
    local runtimeOk, runtime = pcall(bindRuntime, loaded, utils)
    if not runtimeOk then
        utils.warn("runtime falhou: " .. tostring(runtime))
        utils.stop()
        return false
    end
    Exodus.Runtime = runtime
    _G.ExodusOnBurst = loaded.AutoParry.fire
    local uiReady = loadInterface(urls.UI, utils, {
        onPanic = function()
            loaded.AutoParry.resetState()
            utils.setManualSpamActive(false)
        end,
    })
    Exodus.UIReady = uiReady == true
    Exodus.UI = Modules.UI
    Exodus.Started = true
    Exodus.Version = utils.version()
    utils.info(("%s %s inicializado"):format(utils.name(), utils.version()))
    return true
end
Exodus.Loader = Loader
Modules.Loader = Loader
local started = Loader.start()
Exodus.Started = started == true
return Loader
