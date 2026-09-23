-- [[ Loader ]]

local function printRawError(moduleName, message)
	local output = tostring(moduleName) .. ": " .. tostring(message)
	if type(warn) == "function" then
		pcall(warn, output)
	elseif type(print) == "function" then
		pcall(print, output)
	end
end
local Exodus = type(_G.Exodus) == "table" and _G.Exodus or {}
local Modules = type(Exodus.Modules) == "table" and Exodus.Modules or {}
Exodus.Modules = Modules
_G.Exodus = Exodus
_G.ExodusModules = Modules
local Loader = {}

-- metadata
local REPOSITORY = "Repp35/Exodus-v2"
local BRANCH = "main"
local PROJECT_PATH = "exodus%20hub/"
local LOCAL_ROOTS = { "Exodus-v2", "exodus hub", "Exodus Hub" }
local BASE_URL = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/"
local MODULE_ORDER = {
	"config",
	"uiconfig",
	"utils",
	"gameinfo",
	"remote",
	"autoparry",
	"dynamicparry",
	"dash",
	"autoclash",
	"spam",
	"character",
}

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
	return statusCode == 408 or statusCode == 425 or statusCode == 429 or (statusCode and statusCode >= 500 and statusCode <= 599)
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
	for attempt = 1, 3 do
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
				return responseBody
			end
			lastError = tostring(responseBody)
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
				return responseBody
			end
			lastError = tostring(responseBody)
		end
		if not isRetryableHttp(lastError) then
			break
		end
		waitBeforeRetry(attempt)
	end
	local message = lastError or "Nenhum servi莽o HTTP dispon铆vel"
	return nil, message
end
local function localBaseName(path)
	return string.match(path, "[^\\/]+$") or path
end
local function findLocalModule(name)
	if type(listfiles) ~= "function" or type(isfile) ~= "function" or type(isfolder) ~= "function" or type(readfile) ~= "function" then
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
		end
	end
	if #matches == 0 then
		return nil, name .. ".luau n茫o encontrado; pastas verificadas: " .. table.concat(availableRoots, ", ")
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
	local ok, module = pcall(chunk)
	if not ok then
		return nil, module
	end
	if type(module) ~= "table" then
		return nil, "módulo não retornou uma tabela"
	end
	return module
end

-- urls
local function buildURLs(version)
	local root = BASE_URL .. (version or ("refs/heads/" .. BRANCH)) .. "/" .. PROJECT_PATH .. "modules/"
	local query = "?t=" .. tostring(os.time())
	return {
		config = root .. "front/config.luau" .. query,
		uiconfig = root .. "front/uiconfig.luau" .. query,
		utils = root .. "logic/utils.luau" .. query,
		gameinfo = root .. "logic/gameinfo.luau" .. query,
		remote = root .. "logic/remote.luau" .. query,
		autoparry = root .. "logic/autoparry.luau" .. query,
		dynamicparry = root .. "logic/dynamicparry.luau" .. query,
		dash = root .. "logic/dash.luau" .. query,
		autoclash = root .. "logic/autoclash.luau" .. query,
		spam = root .. "logic/spam.luau" .. query,
		character = root .. "logic/character.luau" .. query,
		ui = root .. "front/ui.luau" .. query,
	}
end
local function loadModule(name, url)
	local source, fetchError = request(url)
	if source then
		local module, compileError = compile(name, source)
		if module then
			return register(name, module), nil, "github"
		end
		fetchError = compileError
	end
	local localSource, localPath = findLocalModule(name)
	if localSource then
		local module, compileError = compile(name .. " [local]", localSource)
		if module then
			return register(name, module), nil, "local"
		end
		return nil, compileError
	end
	return nil, fetchError or localPath
end
local function loadModules(urls)
	local loaded = {}
	local names = {}
	for _, name in ipairs(MODULE_ORDER) do
		names[#names + 1] = name
	end
	names[#names + 1] = "ui"

	local results = {}
	local function load(name)
		local module, loadError, source = loadModule(name, urls[name])
		results[name] = {
			module = module,
			error = loadError,
			source = source,
		}
	end
	if type(task) == "table"
		and type(task.spawn) == "function"
		and type(task.wait) == "function"
	then
		local pending = #names
		for _, name in ipairs(names) do
			task.spawn(function()
				load(name)
				pending -= 1
			end)
		end
		while pending > 0 do
			task.wait()
		end
	else
		for _, name in ipairs(names) do
			load(name)
		end
	end

	for _, name in ipairs(names) do
		local result = results[name]
		if not result or not result.module then
			return nil, name, result and result.error or "resultado de carregamento ausente"
		end
		loaded[name] = result.module
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
				local message = ("%s depende de %s, mas esse módulo não foi carregado"):format(name, tostring(missingDependency))
				return false, name, message
			end
			if name == "character" then
				deps.characterBinds = characterBinds
			end
			local ok, initialized = pcall(module.setup, deps)
			if not ok or initialized ~= true then
				return false, name, initialized
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
	if type(gameInfo) ~= "table" or type(gameInfo.applySync) ~= "function" or type(gameInfo.installBallWatcher) ~= "function" or type(remote) ~= "table" or type(remote.bindBallSync) ~= "function" or type(remote.startMaintenance) ~= "function" then
		return nil, "contrato de runtime incompleto"
	end
	local ballSyncSubscribers = {}
	for _, name in ipairs(MODULE_ORDER) do
		local module = loaded[name]
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
			local message = result
			if type(log.recordError) == "function" then
				log.recordError(name, tostring(message))
			end
			printRawError(name, message)
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
		if type(log.recordError) == "function" then
			log.recordError("GameInfo", "observador da bola indispon铆vel")
		end
		printRawError("GameInfo", "observador da bola indisponível")
	end
	local syncReady = remote.bindBallSync(onBallSync)
	if syncReady then
		log.info("Remote conectado ao BallSyncData")
		log.info(("%d assinantes de BallSync"):format(#ballSyncSubscribers))
	else
		if type(log.recordError) == "function" then
			log.recordError("Remote", "BallSyncData indispon铆vel")
		end
		printRawError("Remote", "BallSyncData indisponível")
	end
	local maintenanceOk, maintenanceReady = pcall(remote.startMaintenance, {
		isActive = utils.isActive,
		onBallSync = onBallSync,
	})
	if not maintenanceOk or maintenanceReady ~= true then
		local message = maintenanceReady
		if type(log.recordError) == "function" then
			log.recordError("Remote", tostring(message))
		end
		printRawError("Remote", message)
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
local function loadInterface(interface, utils, controls, uiConfig)
	if type(interface) ~= "table" then
		return false, "UI", "módulo não carregado"
	end
	if type(interface.setup) ~= "function" then
		return false, "UI", "setup ausente"
	end
	local ok, setupError = pcall(interface.setup, {
		Utils = utils,
		Controls = controls,
		UIConfig = uiConfig,
	})
	if not ok or setupError ~= true then
		return false, "UI", setupError
	end
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
	stopPreviousRuntime()
	clearRegistry()
	local playerReady, playerError = waitForLocalPlayer(10)
	if not playerReady then
		return false, "Loader", playerError
	end
	local version = "refs/heads/" .. BRANCH
	local urls = buildURLs(version)
	local loaded, moduleName, loadError = loadModules(urls)
	if not loaded then
		return false, moduleName, loadError
	end
	local utils = loaded.utils
	utils.start()
	if type(utils.log) == "function" then
		utils.log = function() end
	end
	utils.setLifecyclePhase("loading")
	Exodus.Utils = utils
	Exodus.State = utils.getStateSnapshot()
	Exodus.Context = loaded
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
			loaded.dynamicparry.resetState()
			utils.setManualSpamActive(false)
			utils.setAutoSpamActive(false)
			utils.setConfig({ DynamicParry = false })
		end,
		DynamicParry = loaded.dynamicparry,
	}, loaded.uiconfig)
	if not uiReady then
		utils.stop()
		return false, uiModule, uiError
	end
	Exodus.UIReady = uiReady == true
	Exodus.UI = Modules.ui
	utils.setLifecyclePhase(uiReady == true and "ready" or "runtime_ready")
	Exodus.Started = true
	Exodus.Version = utils.version()
	utils.info(("%s %s inicializado"):format(utils.name(), utils.version()))
	return true
end
Exodus.Loader = Loader
Modules.Loader = Loader
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
		printRawError(moduleName, startError)
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
