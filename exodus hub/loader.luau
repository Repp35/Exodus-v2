-- [[ Loader ]]

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
        local ok, responseBody = pcall(function()
            local response = _G.request({
                Url = url,
                Method = "GET",
                Headers = headers,
            })

            if type(response) ~= "table" or type(response.Body) ~= "string" then
                error("Resposta HTTP inválida")
            end

            if type(response.StatusCode) == "number"
                and response.StatusCode ~= 200
            then
                error("HTTP " .. tostring(response.StatusCode))
            end

            return response.Body
        end)

        if ok and type(responseBody) == "string" and responseBody ~= "" then
            return responseBody
        end

        lastError = tostring(responseBody)
    end

    if type(game.HttpGet) == "function" then
        local ok, responseBody = pcall(function()
            return game:HttpGet(url)
        end)

        if ok and type(responseBody) == "string" and responseBody ~= "" then
            return responseBody
        end

        lastError = tostring(responseBody)
    end

    return nil, lastError or "Nenhum serviço HTTP disponível"
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

local function stopPreviousRuntime()
    if type(Modules.Remote) == "table"
        and type(Modules.Remote.stopMaintenance) == "function"
    then
        pcall(Modules.Remote.stopMaintenance)
    end

    local stopped = false

    if type(_G.ExodusStop) == "function" then
        pcall(_G.ExodusStop)
        stopped = true
    end

    if not stopped and type(_G.ExodusUICleanup) == "function" then
        pcall(_G.ExodusUICleanup)
    end
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

local function loadModules(urls, log)
    local loaded = {}

    for _, name in ipairs(MODULE_ORDER) do
        if name ~= "Utils" then
            local module, loadError = loadModule(name, urls[name])

            if not module then
                log.warn(("%s falhou: %s"):format(name, tostring(loadError)))
                return nil
            end

            loaded[name] = module
            log.info(("%s carregado"):format(name))
        end
    end

    loaded.Utils = log
    return loaded
end

-- setup
local function initializeModules(loaded, log)
    local setupOrder = {
        { "Remote", { Utils = loaded.Utils } },
        { "GameInfo", { Utils = loaded.Utils } },
        {
            "AutoParry",
            {
                Remote = loaded.Remote,
                GameInfo = loaded.GameInfo,
                Utils = loaded.Utils,
            },
        },
        {
            "AutoClash",
            {
                GameInfo = loaded.GameInfo,
                Utils = loaded.Utils,
                AutoParry = loaded.AutoParry,
            },
        },
        {
            "Spam",
            {
                Remote = loaded.Remote,
                Utils = loaded.Utils,
            },
        },
        {
            "Character",
            {
                AutoParry = loaded.AutoParry,
                AutoClash = loaded.AutoClash,
                Spam = loaded.Spam,
                Utils = loaded.Utils,
            },
        },
    }

    for _, entry in ipairs(setupOrder) do
        local name = entry[1]
        local module = loaded[name]

        if type(module) ~= "table" or type(module.setup) ~= "function" then
            log.warn(name .. " não possui setup")
            return false
        end

        local ok, initialized = pcall(module.setup, entry[2])

        if not ok or initialized ~= true then
            log.warn(("%s falhou ao inicializar: %s")
                :format(name, tostring(initialized)))
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

    local function callSync(name, handler, data)
        local ok, errorMessage = pcall(handler, data)

        if not ok then
            log.warn(("BallSync %s falhou: %s")
                :format(name, tostring(errorMessage)))
        end
    end

    local function onBallSync(data)
        callSync("GameInfo", gameInfo.applySync, data)
        callSync("AutoParry", loaded.AutoParry.onBallSync, data)
        callSync("AutoClash", loaded.AutoClash.onBallSync, data)
    end

    local watcherReady = gameInfo.installBallWatcher(utils.trackGlobal)

    if watcherReady then
        log.info("GameInfo conectado à bola")
    else
        log.warn("GameInfo não encontrou o observador da bola")
    end

    local syncReady = remote.bindBallSync(onBallSync)

    if syncReady then
        log.info("Remote conectado ao BallSyncData")
    else
        log.warn("Remote BallSyncData indisponível")
    end

    local maintenanceOk, maintenanceReady = pcall(remote.startMaintenance, {
        isActive = utils.isActive,
        onBallSync = onBallSync,
    })

    if not maintenanceOk or maintenanceReady ~= true then
        log.warn("manutenção do Remote falhou: " .. tostring(maintenanceReady))
    else
        log.info("manutenção do Remote iniciada")
    end

    return {
        watcher = watcherReady == true,
        ballSync = syncReady == true,
        maintenance = maintenanceOk and maintenanceReady == true,
    }
end

-- interface
local function loadInterface(url, utils, controls)
    local interface, loadError = loadModule("UI", url)

    if not interface then
        utils.warn("Exodus UI falhou: " .. tostring(loadError))
        return false
    end

    if type(interface.setup) ~= "function" then
        utils.warn("Exodus UI não possui setup")
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

    utils.info("Exodus UI carregada")
    return true
end

-- start
function Loader.start()
    stopPreviousRuntime()
    clearRegistry()

    local version = latestVersion()
    local urls = buildURLs(version)
    local utils, utilsError = loadModule("Utils", urls.Utils)

    if not utils then
        return false, utilsError
    end

    utils.start()
    Exodus.Utils = utils
    Exodus.State = utils.getState()

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
            loaded.AutoClash.resetState()
            utils.setManualSpamActive(false)
            utils.setAutoSpamActive(false)
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
