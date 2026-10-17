-- [[ loader ]]

local function printRawError(moduleName, message, filePath)
	local output = ("[%s] %s: %s"):format(tostring(filePath or "loader.luau"), tostring(moduleName), tostring(message))
	if type(debug) == "table" and type(debug.traceback) == "function" then
		local ok, trace = pcall(debug.traceback, output, 2)
		if ok and type(trace) == "string" then
			output = trace
		end
	end
	local warned = false
	if type(warn) == "function" then
		warned = pcall(warn, output)
	end
	if not warned and type(print) == "function" then
		pcall(print, output)
	end
end
local function printStartup(message)
	if type(print) == "function" then
		pcall(print, message)
	end
end
local Exodus = type(_G.Exodus) == "table" and _G.Exodus or {}
local Modules = type(Exodus.Modules) == "table" and Exodus.Modules or {}
local Loader = {}

-- metadata
local REPOSITORY = "Repp35/Exodus-v2"
local BRANCH = "main"
local PROJECT_PATH = "exodus%20hub/"
local LOCAL_ROOTS = { "Exodus-v2/exodus hub", "Exodus-v2-main/exodus hub", "exodus hub", "Exodus Hub" }
local BASE_URL = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/"
local CACHE_BUSTER = tostring(os.time())
local HttpService = game:GetService("HttpService")
local MODULE_MANIFEST = {
	{ name = "config", path = "modules/front/config.luau" },
	{ name = "uiconfig", path = "modules/front/uiconfig.luau" },
	{ name = "utils", path = "modules/logic/utils.luau" },
	{ name = "antitamper", path = "modules/security/antitamper.luau" },
	{ name = "gameinfo", path = "modules/logic/gameinfo.luau" },
	{ name = "remote", path = "modules/logic/remote.luau" },
	{ name = "autoparry", path = "modules/logic/autoparry.luau" },
	{ name = "dash", path = "modules/logic/dash.luau" },
	{ name = "autoclash", path = "modules/logic/autoclash.luau" },
	{ name = "spam", path = "modules/logic/spam.luau" },
	{ name = "character", path = "modules/logic/character.luau" },
	{ name = "ui", path = "modules/front/ui.luau" },
}

local MODULE_ORDER = {}
local MODULE_BY_NAME = {}
for _, entry in ipairs(MODULE_MANIFEST) do
	MODULE_BY_NAME[entry.name] = entry
	if entry.name ~= "ui" then
		MODULE_ORDER[#MODULE_ORDER + 1] = entry.name
	end
end
local ALLOW_LOCAL_FALLBACK = true

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
		{ environment.request },
		{ environment.http_request },
		{ synApi and synApi.request },
		{ fluxusApi and fluxusApi.request },
	}
	for _, item in ipairs(candidates) do
		local candidate = item[1]
		if type(candidate) == "function" then
			return candidate
		end
	end
	return nil
end
local function validateExecutor()
	local requestFunction = getRequestFunction()
	if
		type(requestFunction) ~= "function"
		and not (ALLOW_LOCAL_FALLBACK and type(isfile) == "function" and type(readfile) == "function")
	then
		return false, "executor sem request ou arquivos locais suportados"
	end
	if type(loadstring) ~= "function" then
		return false, "executor sem loadstring"
	end
	local okCompile, chunk = pcall(loadstring, "return true", "ExodusPreflight")
	if not okCompile or type(chunk) ~= "function" then
		return false, "loadstring rejeitou o preflight"
	end
	local okRun, result = pcall(chunk)
	if not okRun or result ~= true then
		return false, "preflight de compilação falhou"
	end
	return true
end
local function isRetryableHttp(message)
	local statusCode = tonumber(string.match(tostring(message), "HTTP%s+(%d+)"))
	return statusCode == nil
		or statusCode == 408
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
		return nil, "URL inválida"
	end
	local lastError
	local requestFunction = getRequestFunction()
	for attempt = 1, 3 do
		if requestFunction then
			local ok, responseBody = pcall(function()
				local response = requestFunction({
					Url = url,
					Method = "GET",
					Headers = headers,
				})

				if type(response) ~= "table" then
					error("Resposta HTTP inválida")
				end
				local statusCode = tonumber(response.StatusCode or response.status_code)
				if not statusCode or statusCode < 200 or statusCode >= 300 then
					error("HTTP " .. tostring(statusCode or "sem status"))
				end
				local body = response.Body or response.body or response.ResponseBody
				if type(body) ~= "string" or body == "" then
					error("Corpo HTTP vazio ou inválido")
				end
				return body
			end)
			if ok and type(responseBody) == "string" and responseBody ~= "" then
				return responseBody
			end
			lastError = tostring(responseBody)
		end
		if not isRetryableHttp(lastError) then
			break
		end
		waitBeforeRetry(attempt)
	end
	local message = lastError or "Nenhum serviço HTTP disponível"
	return nil, message
end
local function findCompleteLocalRoot()
	if not ALLOW_LOCAL_FALLBACK or type(isfile) ~= "function" or type(readfile) ~= "function" then
		return nil
	end
	for _, root in ipairs(LOCAL_ROOTS) do
		local complete = true
		for _, entry in ipairs(MODULE_MANIFEST) do
			local ok, exists = pcall(isfile, root .. "/" .. entry.path)
			if not ok or not exists then
				complete = false
				break
			end
		end
		if complete then
			return root
		end
	end
	return nil
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
	Exodus.Diagnostics = nil
	Exodus.Version = nil
	Exodus.StartError = nil
	Exodus.StartErrorModule = nil
	Exodus.UIReady = false
	Exodus.Started = false
	_G.ExodusOnBurst = nil
end
local function stopPreviousRuntime()
	if type(Modules.remote) == "table" and type(Modules.remote.stopMaintenance) == "function" then
		pcall(Modules.remote.stopMaintenance)
	end
	for _, name in ipairs({ "character", "spam", "autoclash", "dash", "autoparry", "antitamper" }) do
		local module = Modules[name]
		if type(module) == "table" then
			if type(module.teardown) == "function" then
				pcall(module.teardown)
			elseif type(module.resetState) == "function" then
				pcall(module.resetState)
			end
		end
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
	if type(loadstring) ~= "function" then
		return nil, "loadstring indisponível"
	end
	local chunk, compileError = loadstring(source, name)
	if not chunk then
		return nil, compileError
	end
	return chunk
end
local function execute(name, chunk)
	local ok, module = pcall(chunk)
	if not ok then
		return nil, module
	end
	if type(module) ~= "table" then
		return nil, name .. " não retornou uma tabela"
	end
	return module
end

-- urls
local function resolveLatestRevision()
	local url = "https://api.github.com/repos/"
		.. REPOSITORY
		.. "/commits/"
		.. BRANCH
		.. "?exodus_cache="
		.. CACHE_BUSTER
	local body, requestError = request(url, {
		["Accept"] = "application/vnd.github+json",
		["User-Agent"] = "Exodus-Hub-Loader",
	})
	if not body then
		return nil, requestError or "SHA mais recente indisponível"
	end
	local ok, document = pcall(HttpService.JSONDecode, HttpService, body)
	if
		not ok
		or type(document) ~= "table"
		or type(document.sha) ~= "string"
		or not string.match(document.sha, "^[a-fA-F0-9]+$")
		or #document.sha ~= 40
	then
		return nil, "resposta do SHA mais recente inválida"
	end
	return document.sha
end
local function buildURLs(revision)
	local root = BASE_URL .. revision .. "/" .. PROJECT_PATH
	local urls = {}
	for _, entry in ipairs(MODULE_MANIFEST) do
		urls[entry.name] = root .. entry.path
	end
	return urls
end
local function buildCDNURL(url)
	local repository, version, path =
		string.match(url, "^https://raw%.githubusercontent%.com/([^/]+/[^/]+)/([^/]+)/(.+)$")
	if not repository or not version or not path then
		return nil
	end
	return "https://cdn.jsdelivr.net/gh/" .. repository .. "@" .. version .. "/" .. path
end
local function loadModule(name, relativePath, url, localRoot)
	if localRoot then
		local path = localRoot .. "/" .. relativePath
		local ok, source = pcall(readfile, path)
		if not ok or type(source) ~= "string" or source == "" then
			return nil, "falha ao ler " .. path
		end
		local chunk, compileError = compile(name .. " [local]", source)
		return chunk, compileError, "local"
	end
	local source, fetchError
	if url then
		source, fetchError = request(url)
	end
	local sourceKind = "github"
	if not source then
		local fallbackURL = buildCDNURL(url)
		if fallbackURL then
			local fallbackSource, fallbackError = request(fallbackURL)
			if fallbackSource then
				source, fetchError, sourceKind = fallbackSource, nil, "cdn"
			else
				fetchError = tostring(fetchError or "falha no GitHub Raw") .. "; CDN: " .. tostring(fallbackError)
			end
		end
	end
	if source then
		local chunk, compileError = compile(name, source)
		if chunk then
			return chunk, nil, sourceKind
		end
		fetchError = compileError
	end
	return nil, fetchError or "origem remota indisponível"
end
local function loadModules(urls, localRoot)
	local loaded = {}
	local names = {}
	for _, name in ipairs(MODULE_ORDER) do
		names[#names + 1] = name
	end
	names[#names + 1] = "ui"
	local results = {}
	local function load(name)
		local entry = MODULE_BY_NAME[name]
		if not entry then
			results[name] = { error = "módulo ausente no manifesto" }
			return
		end
		local chunk, loadError, source = loadModule(name, entry.path, urls[name], localRoot)
		results[name] = {
			chunk = chunk,
			error = loadError,
			source = source,
		}
	end
	if type(task) == "table" and type(task.spawn) == "function" and type(task.wait) == "function" then
		local pending = #names
		local deadline = os.clock() + 30
		for _, name in ipairs(names) do
			task.spawn(function()
				local ok, loadError = xpcall(function()
					load(name)
				end, function(errorValue)
					return errorValue
				end)
				if not ok then
					results[name] = { error = loadError }
				end
				pending -= 1
			end)
		end
		while pending > 0 do
			if os.clock() >= deadline then
				return nil, "Loader", "tempo limite ao baixar os módulos"
			end
			task.wait()
		end
	else
		for _, name in ipairs(names) do
			load(name)
		end
	end
	for _, name in ipairs(names) do
		local result = results[name]
		if not result or not result.chunk then
			return nil, name, result and result.error or "resultado de carregamento ausente"
		end
	end
	for _, name in ipairs(names) do
		local module, executeError = execute(name, results[name].chunk)
		if not module then
			clearRegistry()
			return nil, name, executeError
		end
		loaded[name] = module
		register(name, module)
	end
	return loaded
end

-- setup
local function resolveDeps(loaded, requires)
	local deps = {}
	if type(requires) ~= "table" then
		return deps
	end
	for depName, sourceKey in pairs(requires) do
		local dependency = loaded[sourceKey]
		if dependency == nil then
			return nil, sourceKey
		end
		deps[depName] = dependency
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
	for _, name in ipairs(MODULE_ORDER) do
		local module = loaded[name]
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
			elseif hasBindFlag then
				return nil, name, "contrato bindCharacter incompleto"
			end
		end
	end
	return binds
end
local function initializeModules(loaded)
	local characterBinds, bindModule, bindError = collectCharacterBinds(loaded)
	if not characterBinds then
		return false, bindModule, bindError
	end
	for _, name in ipairs(MODULE_ORDER) do
		if name ~= "utils" and name ~= "config" and name ~= "uiconfig" then
			local module = loaded[name]
			if type(module) ~= "table" or type(module.setup) ~= "function" then
				return false, name, "setup ausente"
			end
			local contract = contractOf(module)
			local deps, missingDependency = resolveDeps(loaded, contract.requires)
			if not deps then
				local message = ("%s depende de %s, mas esse módulo não foi carregado"):format(
					name,
					tostring(missingDependency)
				)
				return false, name, message
			end
			if name == "character" then
				deps.characterBinds = characterBinds
			end
			local ok, initialized, setupError = pcall(module.setup, deps)
			if not ok or initialized ~= true then
				return false, name, ok and setupError or initialized
			end
		end
	end
	return true
end

-- runtime
local function bindRuntime(loaded, log)
	local utils = loaded.utils
	local gameInfo = loaded.gameinfo
	local remote = loaded.remote
	if
		type(gameInfo) ~= "table"
		or type(gameInfo.applySync) ~= "function"
		or type(gameInfo.installBallWatcher) ~= "function"
		or type(gameInfo.getSyncData) ~= "function"
		or type(remote) ~= "table"
		or type(remote.bindBallSync) ~= "function"
		or type(remote.getRemote) ~= "function"
		or type(remote.initParry) ~= "function"
		or type(remote.startMaintenance) ~= "function"
	then
		return nil, "contrato de runtime incompleto"
	end
	-- Remotes may not exist yet when the loader starts; maintenance discovers them later.
	local remoteCallOk, parryRemote = pcall(remote.getRemote)
	local initCallOk, initialized = false, false
	if remoteCallOk and parryRemote then
		initCallOk, initialized = pcall(remote.initParry)
	end
	local ballSyncSubscribers = {}
	for _, name in ipairs(MODULE_ORDER) do
		local module = loaded[name]
		if name ~= "utils" and type(module) == "table" then
			local contract = contractOf(module)
			if contract.onBallSync == true and type(module.onBallSync) ~= "function" then
				return nil, "contrato BallSync incompleto: " .. name
			end
			if contract.onBallSync == true then
				ballSyncSubscribers[#ballSyncSubscribers + 1] = {
					name = name,
					handler = module.onBallSync,
				}
			end
		end
	end
	local function callSync(name, handler, data)
		local ok, result, detail = pcall(handler, data)
		if not ok or result == false then
			local message = result == false and detail or result
			if message == nil then
				message = result
			end
			local entry = MODULE_BY_NAME[name]
			printRawError(name, message, entry and entry.path or "loader.luau")
			return nil
		end
		return detail or data
	end
	local function notifyBallSync(decodedData)
		if type(decodedData) ~= "table" then
			return
		end
		for _, sub in ipairs(ballSyncSubscribers) do
			callSync(sub.name, sub.handler, decodedData)
		end
	end
	local pendingSyncRefresh = false
	local function onBallSync(...)
		-- O RemoteEvent pode enviar a tabela como argumento extra ou como string JSON:
		-- procura o primeiro argumento utilizável antes de desistir.
		local argCount = select("#", ...)
		local data
		for index = 1, argCount do
			local value = select(index, ...)
			if type(value) == "table" then
				data = value
				break
			end
			if type(value) == "string" then
				local decodedOk, decoded = pcall(HttpService.JSONDecode, HttpService, value)
				if decodedOk and type(decoded) == "table" then
					data = decoded
					break
				end
			end
		end
		local ok, decodedData = pcall(gameInfo.applySync, data)
		if not ok then
			local entry = MODULE_BY_NAME.gameinfo
			printRawError("GameInfo", decodedData, entry and entry.path or "loader.luau")
			return
		end
		if type(decodedData) ~= "table" then
			-- O evento também pode conter bytes ou apenas sinalizar uma atualização
			-- posterior do BallReplicator. Releia uma vez após os outros callbacks.
			if not pendingSyncRefresh then
				pendingSyncRefresh = true
				task.defer(function()
					pendingSyncRefresh = false
					if type(utils.isActive) == "function" and not utils.isActive() then
						return
					end
					local retryOk, refreshed = pcall(gameInfo.applySync, nil)
					if retryOk and type(refreshed) == "table" then
						notifyBallSync(refreshed)
					end
				end)
			end
			return
		end
		notifyBallSync(decodedData)
	end
	local watcherCallOk, watcherReady = pcall(gameInfo.installBallWatcher, utils.trackGlobal)
	if not watcherCallOk or watcherReady ~= true then
		local reason = watcherCallOk and "observador da bola indisponível" or tostring(watcherReady)
		return nil, "GameInfo: " .. reason
	end
	local syncCallOk, syncReady = pcall(remote.bindBallSync, onBallSync)
	if not syncCallOk then
		printRawError("Remote", syncReady, MODULE_BY_NAME.remote.path)
	end
	local maintenanceOk, maintenanceReady = pcall(remote.startMaintenance, {
		isActive = utils.isActive,
		onBallSync = onBallSync,
	})
	if not maintenanceOk or maintenanceReady ~= true then
		local message = maintenanceReady
		return nil, "Remote: " .. tostring(message)
	end
	return {
		parryRemote = remoteCallOk and parryRemote ~= nil,
		parryInitialized = initCallOk and initialized == true,
		watcher = watcherCallOk and watcherReady == true,
		ballSync = syncCallOk and syncReady == true,
		maintenance = maintenanceOk and maintenanceReady == true,
		ballSyncSubscribers = #ballSyncSubscribers,
	}
end

-- interface
local function loadInterface(interface, utils, controls, uiConfig)
	if type(interface) ~= "table" then
		return false, "UI", "módulo não carregado"
	end
	if type(interface.setup) ~= "function" then
		return false, "UI", "setup ausente"
	end
	local ok, setupResult, setupError = pcall(interface.setup, {
		Utils = utils,
		Controls = controls,
		UIConfig = uiConfig,
	})
	if not ok or setupResult ~= true then
		return false, "UI", ok and setupError or setupResult
	end
	return true
end

-- start
local activeLoaded
local function waitForLocalPlayer(timeout)
	local ok, players = pcall(game.GetService, game, "Players")
	if not ok or not players then
		return false, "serviço Players indisponível"
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
	return false, "LocalPlayer indisponível após esperar " .. tostring(timeout or 10) .. "s"
end
local function startInternal()
	printStartup("Exodus: iniciando")
	stopPreviousRuntime()
	clearRegistry()
	local playerReady, playerError = waitForLocalPlayer(10)
	if not playerReady then
		return false, "Loader", playerError
	end
	local localRoot = findCompleteLocalRoot()
	local version, revisionError
	if not localRoot then
		version, revisionError = resolveLatestRevision()
	end
	if not localRoot and not version then
		return false, "Loader", "SHA indisponível e nenhum conjunto local completo: " .. tostring(revisionError)
	end
	local urls = version and buildURLs(version) or {}
	local loaded, moduleName, loadError = loadModules(urls, localRoot)
	if not loaded then
		return false, moduleName, loadError
	end
	activeLoaded = loaded
	local utils = loaded.utils
	if type(utils.start) ~= "function" or type(utils.setLifecyclePhase) ~= "function" then
		return false, "Utils", "contrato de inicialização incompleto"
	end
	utils.start()
	utils.setLifecyclePhase("loading")
	Exodus.Utils = utils
	Exodus.State = utils.getStateSnapshot()
	for _, entry in ipairs(MODULE_MANIFEST) do
		local module = loaded[entry.name]
		if type(module) == "table" and module.__config and not loaded.config.register(entry.name, module.__config) then
			utils.stop()
			return false, "Config", "schema duplicado ou inválido: " .. entry.name
		end
	end
	if type(utils.setConfigModule) ~= "function" or not utils.setConfigModule(loaded.config) then
		utils.stop()
		return false, "Utils", "schema de Config indisponível"
	end
	local defaultsOk, defaults = pcall(loaded.config.defaults)
	if not defaultsOk or type(defaults) ~= "table" then
		utils.stop()
		return false, "Config", defaults
	end
	local configCallOk, configValid, configReason = pcall(loaded.config.validate, defaults)
	if not configCallOk or configValid ~= true then
		utils.stop()
		return false, "Config", configCallOk and configReason or configValid
	end
	utils.setLifecyclePhase("configuring")
	if not utils.setConfig(defaults) then
		utils.stop()
		return false, "Utils", "setConfig rejeitou a configuração inicial"
	end
	if not utils.setModuleURLs(urls) then
		utils.stop()
		return false, "Utils", "setModuleURLs rejeitou as URLs dos módulos"
	end
	Exodus.Config = utils.getConfigSnapshot()
	Exodus.ModuleURLs = utils.getModuleURLsSnapshot()
	utils.setLifecyclePhase("initializing")
	local modulesReady, moduleName, modulesError = initializeModules(loaded)
	if not modulesReady then
		utils.stop()
		return false, moduleName, modulesError
	end
	if not utils.setDiagnosticsModules(loaded) then
		utils.stop()
		return false, "Utils", "setDiagnosticsModules rejeitou os módulos"
	end
	utils.setLifecyclePhase("binding")
	local runtimeOk, runtime = pcall(bindRuntime, loaded, utils)
	if not runtimeOk or type(runtime) ~= "table" then
		utils.stop()
		return false, "Runtime", runtime
	end
	Exodus.Runtime = runtime
	_G.ExodusOnBurst = loaded.autoparry.fire
	local uiReady, uiModule, uiError = loadInterface(loaded.ui, utils, {
		onPanic = function()
			loaded.autoparry.resetState()
			utils.setManualSpamActive(false)
			utils.setAutoSpamActive(false)
		end,
	}, loaded.uiconfig)
	if not uiReady then
		utils.stop()
		return false, uiModule, uiError
	end
	Exodus.Context = loaded
	Exodus.UIReady = uiReady == true
	Exodus.UI = Modules.ui
	utils.setLifecyclePhase(uiReady == true and "ready" or "runtime_ready")
	Exodus.Started = true
	Exodus.Version = utils.version()
	printStartup("Exodus: iniciado")
	return true
end
local function rollbackLoaded(loaded)
	if type(loaded) ~= "table" then
		return
	end
	for index = #MODULE_ORDER, 1, -1 do
		local module = loaded[MODULE_ORDER[index]]
		if type(module) == "table" then
			if type(module.teardown) == "function" then
				pcall(module.teardown)
			elseif type(module.detachCharacter) == "function" then
				pcall(module.detachCharacter)
			elseif type(module.resetState) == "function" then
				pcall(module.resetState)
			end
		end
	end
	if type(loaded.remote) == "table" and type(loaded.remote.stopMaintenance) == "function" then
		pcall(loaded.remote.stopMaintenance)
	end
	if type(loaded.utils) == "table" and type(loaded.utils.stop) == "function" then
		pcall(loaded.utils.stop)
	end
end
local startLock = false
function Loader.start()
	if startLock then
		return false, "Loader", "startup já em andamento"
	end
	local ready, reason = validateExecutor()
	if not ready then
		return false, "Loader", reason
	end
	startLock = true
	Exodus.Modules = Modules
	_G.Exodus = Exodus
	_G.ExodusModules = Modules
	Exodus.Loader = Loader
	Modules.Loader = Loader
	local ok, started, moduleName, startError = xpcall(startInternal, function(errorValue)
		return errorValue
	end)
	startLock = false
	if not ok or started ~= true then
		rollbackLoaded(activeLoaded)
		activeLoaded = nil
		clearRegistry()
		if not ok then
			return false, "Loader", started
		end
		return started, moduleName, startError
	end
	activeLoaded = nil
	return started, moduleName, startError
end
local function startSafely()
	local ok, started, moduleName, startError = xpcall(Loader.start, function(errorValue)
		return errorValue
	end)
	if not ok then
		startError = started
		moduleName = "Loader"
		started = false
	end
	if started ~= true then
		moduleName = moduleName or "Loader"
		startError = startError or started
		local entry = MODULE_BY_NAME[moduleName]
		printRawError(moduleName, startError, entry and entry.path or "loader.luau")
		Loader.lastError = startError
		Loader.lastErrorModule = moduleName
		Exodus.StartError = startError
		Exodus.StartErrorModule = moduleName
		return false
	end
	Loader.lastError = nil
	Loader.lastErrorModule = nil
	Exodus.StartError = nil
	Exodus.StartErrorModule = nil
	return true
end
local started = startSafely()
Exodus.Started = started == true

return Loader
