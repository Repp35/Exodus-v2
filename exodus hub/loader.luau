-- [[ loader ]]

-- logging
local function printRawError(moduleName, message, filePath)
	local output = ("[%s] %s: %s"):format(tostring(filePath or "loader.luau"), tostring(moduleName), tostring(message))
	if type(warn) == "function" then warn(output) elseif type(print) == "function" then print(output) end
end
local function printStartup(message)
	if type(print) == "function" then print(message) end
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
	{ name = "permissions", path = "modules/logic/permissions.luau" },
	{ name = "config", path = "modules/front/config.luau" },
	{ name = "uiconfig", path = "modules/front/uiconfig.luau" },
	{ name = "utils", path = "modules/logic/utils.luau" },
	{ name = "gameinfo", path = "modules/logic/gameinfo.luau" },
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
}

local MODULE_ORDER = {}
local MODULE_BY_NAME = {}
for _, entry in ipairs(MODULE_MANIFEST) do
	MODULE_BY_NAME[entry.name] = entry
	if entry.name ~= "ui" and entry.name ~= "permissions" then MODULE_ORDER[#MODULE_ORDER + 1] = entry.name end
end
local ALLOW_LOCAL_FALLBACK = true

-- http
local function getRequestFunction()
	local environment = type(getgenv) == "function" and getgenv() or _G; local synApi = type(environment.syn) == "table" and environment.syn or nil; local fluxusApi = type(environment.fluxus) == "table" and environment.fluxus or nil
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
	if not requestFunction and not (ALLOW_LOCAL_FALLBACK and type(isfile) == "function" and type(readfile) == "function") then return false, "executor sem request ou arquivos locais suportados" end
	if type(loadstring) ~= "function" then return false, "executor sem loadstring" end
	return true
end
local function isRetryableHttp(message)
	local statusCode = tonumber(string.match(tostring(message), "HTTP%s+(%d+)")); return statusCode == nil or statusCode == 408 or statusCode == 425 or statusCode == 429 or (statusCode and statusCode >= 500 and statusCode <= 599)
end
local function waitBeforeRetry(attempt)
	if type(task) == "table" and type(task.wait) == "function" then local delays = { 0.25, 0.75, 1.5 }; task.wait(delays[attempt] or delays[#delays]) end
end
local function request(url, headers)
	if type(url) ~= "string" or url == "" then return nil, "URL inválida" end
	local lastError
	for attempt = 1, 3 do
		if requestFunction then
			local ok, responseBody = pcall(function()
				local response = requestFunction({
					Url = url,
					Method = "GET",
					Headers = headers,
				})
				if type(response) ~= "table" then error("Resposta HTTP inválida") end
				local statusCode = tonumber(response.StatusCode or response.status_code)
				if not statusCode or statusCode < 200 or statusCode >= 300 then error("HTTP " .. tostring(statusCode or "sem status")) end
				local body = response.Body or response.body or response.ResponseBody
				if type(body) ~= "string" or body == "" then error("Corpo HTTP vazio ou inválido") end
				return body
			end)
			if ok and type(responseBody) == "string" and responseBody ~= "" then return responseBody end
			lastError = tostring(responseBody)
		end
		if not isRetryableHttp(lastError) then break end
		if attempt < 3 then waitBeforeRetry(attempt) end
	end
	local message = lastError or "Nenhum serviço HTTP disponível"; return nil, message
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

-- registry
local function register(name, module)
	Modules[name] = module; return module
end
local function clearRegistry()
	for _, name in ipairs(MODULE_ORDER) do
		Modules[name] = nil
	end
	Modules.ui = nil; Modules.permissions = nil; Modules.Loader = Loader; Exodus.Utils = nil; Exodus.State = nil; Exodus.Config = nil; Exodus.ModuleURLs = nil; Exodus.Runtime = nil; Exodus.Context = nil; Exodus.UI = nil; Exodus.Diagnostics = nil; Exodus.Version = nil; Exodus.Revision = nil; Exodus.StartError = nil; Exodus.StartErrorModule = nil; Exodus.UIReady = false; Exodus.Started = false
	_G.ExodusOnBurst = nil
end
local function cleanupCall(name, action)
	local ok, result = pcall(action)
	if not ok then printRawError(name, "falha na limpeza: " .. tostring(result)) end
	return ok, result
end
local function stopPreviousRuntime()
	local clean = true
	local function attempt(name, action)
		local ok, result = cleanupCall(name, action)
		if not ok then clean = false end
		return ok, result
	end
	if type(Modules.gameinfo) == "table" and type(Modules.gameinfo.stopMaintenance) == "function" then attempt("gameinfo", Modules.gameinfo.stopMaintenance) end
	for _, name in ipairs({ "character", "spam", "autodash", "autospam", "autodark", "autofierce", "autojump", "camera", "movement", "dash", "autoparry" }) do
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

-- compiler
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

-- urls
local function resolveLatestRevision()
	local url = "https://api.github.com/repos/" .. REPOSITORY .. "/commits/" .. BRANCH .. "?exodus_cache=" .. CACHE_BUSTER
	local body, requestError = request(url, {
		["Accept"] = "application/vnd.github+json",
		["User-Agent"] = "Exodus-Hub-Loader",
	})
	if not body then return nil, requestError or "SHA mais recente indisponível" end
	local ok, document = pcall(HttpService.JSONDecode, HttpService, body)
	if not ok or type(document) ~= "table" or type(document.sha) ~= "string" or not string.match(document.sha, "^[a-fA-F0-9]+$") or #document.sha ~= 40 then return nil, "resposta do SHA mais recente inválida" end
	return document.sha
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
local function loadModule(name, relativePath, url, localRoot)
	if localRoot then
		local path = localRoot .. "/" .. relativePath; local source = readfile(path)
		if type(source) ~= "string" or source == "" then error("Arquivo local inválido: " .. path, 2) end
		local chunk, compileError = compile(name .. " [local]", source); return chunk, compileError, "local"
	end
	local source, fetchError
	if url then source, fetchError = request(url) end
	local sourceKind = "github"
	if not source then
		local fallbackURL = buildCDNURL(url)
		if fallbackURL then
			local fallbackSource, fallbackError = request(fallbackURL)
			if fallbackSource then source, fetchError, sourceKind = fallbackSource, nil, "cdn" else fetchError = tostring(fetchError or "falha no GitHub Raw") .. "; CDN: " .. tostring(fallbackError) end
		end
	end
	if source then
		local chunk, compileError = compile(name, source)
		if chunk then return chunk, nil, sourceKind end
		fetchError = compileError
	end
	return nil, fetchError or "origem remota indisponível"
end
local function loadModules(urls, localRoot)
	local loaded, results = {}, {}
	local function load(name)
		local entry = MODULE_BY_NAME[name]; local chunk, loadError = loadModule(name, entry.path, urls[name], localRoot); results[name] = { chunk = chunk, error = loadError }
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
	local permissions = execute("permissions", results.permissions.chunk); permissions.validate("permissions", permissions); loaded.permissions = register("permissions", permissions)
	for _, entry in ipairs(MODULE_MANIFEST) do
		local name = entry.name
		if name ~= "permissions" then local module = execute(name, results[name].chunk); permissions.validate(name, module); loaded[name] = register(name, module) end
	end
	return loaded
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
			local contract = contractOf(module); local hasBindFlag = contract.bindCharacter == true; local hasBindFn = type(module.bindCharacter) == "function"; local hasDetachFn = type(module.detachCharacter) == "function"
			if hasBindFlag and hasBindFn and hasDetachFn then local api = loaded.permissions.wrap("character", name, module); binds[#binds + 1] = { name = name, bind = api.bindCharacter, detach = api.detachCharacter } elseif hasBindFlag then return nil, name, "contrato bindCharacter incompleto" end
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
	local utils = loaded.utils; local gameInfo = loaded.gameinfo; local remote = loaded.remote
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
			if contract.onBallSync == true then ballSyncSubscribers[#ballSyncSubscribers + 1] = {
				name = name,
				handler = module.onBallSync,
			} end
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
						local sequence = packet.Sequence; local current = gameInfo.getSyncSequence and gameInfo.getSyncSequence(); local forward = not lastClashPacketSequence or (sequence - lastClashPacketSequence) % 65536; local currentDelta = type(current) == "number" and (sequence - current) % 65536 or 0
						if (forward == true or forward < 32768) and currentDelta < 32768 then
							lastClashPacketSequence = sequence; packet.Source = "packet"
							if type(gameInfo.applyPacket) == "function" then gameInfo.applyPacket(packet) end
							if not packet.Teleported then notifyBallSync(packet) end
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
		decodedData = table.clone(decodedData); decodedData.Source = "packet"; notifyBallSync(decodedData)
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
	local dependencies = loaded.permissions.resolve("ui", loaded); dependencies.Controls = controls; local setupResult, setupError = interface.setup(dependencies)
	if setupResult ~= true then return false, "UI", setupError end
	return true
end

-- start
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
local function startInternal()
	printStartup("Exodus: iniciando")
	if not stopPreviousRuntime() then return false, "Loader", "falha ao encerrar a sessão anterior" end
	clearRegistry(); local playerReady, playerError = waitForLocalPlayer(10)
	if not playerReady then return false, "Loader", playerError end
	local localRoot = findCompleteLocalRoot()
	local version, revisionError
	if not localRoot then version, revisionError = resolveLatestRevision() end
	if not localRoot and not version then return false, "Loader", "SHA indisponível e nenhum conjunto local completo: " .. tostring(revisionError) end
	local urls = version and buildURLs(version) or {}; local loaded, moduleName, loadError = loadModules(urls, localRoot)
	if not loaded then return false, moduleName, loadError end
	activeLoaded = loaded; local utils = loaded.utils
	if type(utils.start) ~= "function" or type(utils.setLifecyclePhase) ~= "function" then return false, "Utils", "contrato de inicialização incompleto" end
	utils.start(); utils.setLifecyclePhase("loading"); Exodus.Utils = utils; Exodus.State = utils.getStateSnapshot()
	for _, entry in ipairs(MODULE_MANIFEST) do
		local module = loaded[entry.name]
		if type(module) == "table" and module.__config and not loaded.config.register(entry.name, module.__config) then utils.stop(); return false, "Config", "schema duplicado ou inválido: " .. entry.name end
	end
	if type(utils.setConfigModule) ~= "function" or not utils.setConfigModule(loaded.config) then utils.stop(); return false, "Utils", "schema de Config indisponível" end
	local defaults = loaded.config.defaults()
	if type(defaults) ~= "table" then utils.stop(); return false, "Config", "defaults inválidos" end
	local configValid, configReason = loaded.config.validate(defaults)
	if configValid ~= true then utils.stop(); return false, "Config", configReason end
	utils.setLifecyclePhase("configuring")
	if not utils.setConfig(defaults) then utils.stop(); return false, "Utils", "setConfig rejeitou a configuração inicial" end
	if type(utils.loadConfig) == "function" then utils.loadConfig() end
	if not utils.setModuleURLs(urls) then utils.stop(); return false, "Utils", "setModuleURLs rejeitou as URLs dos módulos" end
	Exodus.Config = utils.getConfigSnapshot(); Exodus.ModuleURLs = utils.getModuleURLsSnapshot(); utils.setLifecyclePhase("initializing"); local modulesReady, failedModule, modulesError = initializeModules(loaded)
	if not modulesReady then utils.stop(); return false, failedModule, modulesError end
	if not utils.setDiagnosticsModules(loaded) then utils.stop(); return false, "Utils", "setDiagnosticsModules rejeitou os módulos" end
	utils.setLifecyclePhase("binding"); local runtime, runtimeError = bindRuntime(loaded, utils)
	if type(runtime) ~= "table" then utils.stop(); return false, "Runtime", runtimeError end
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
	})
	if not uiReady then utils.stop(); return false, uiModule, uiError end
	Exodus.Context = loaded; Exodus.UIReady = uiReady == true; Exodus.UI = Modules.ui; utils.setLifecyclePhase(uiReady == true and "ready" or "runtime_ready"); Exodus.Started = true; Exodus.Version = utils.version(); Exodus.Revision = version; printStartup("Exodus: iniciado"); return true
end

-- rollback
local function rollbackLoaded(loaded)
	if type(loaded) ~= "table" then return end
	for index = #MODULE_ORDER, 1, -1 do
		local name = MODULE_ORDER[index]; local module = loaded[name]
		if type(module) == "table" then
			if type(module.teardown) == "function" then cleanupCall(name, module.teardown) elseif type(module.detachCharacter) == "function" then cleanupCall(name, module.detachCharacter) elseif type(module.resetState) == "function" then cleanupCall(name, module.resetState) end
		end
	end
	if type(loaded.gameinfo) == "table" and type(loaded.gameinfo.stopMaintenance) == "function" then cleanupCall("gameinfo", loaded.gameinfo.stopMaintenance) end
	if type(loaded.utils) == "table" and type(loaded.utils.stop) == "function" then cleanupCall("utils", loaded.utils.stop) end
end
local startLock = false
function Loader.start()
	if startLock then return false, "Loader", "startup já em andamento" end
	local ready, reason = validateExecutor()
	if not ready then return false, "Loader", reason end
	startLock = true; Exodus.Modules = Modules; _G.Exodus = Exodus; _G.ExodusModules = Modules; Exodus.Loader = Loader; Modules.Loader = Loader
	local ok, started, moduleName, startError = xpcall(startInternal, function(err) return debug.traceback(tostring(err), 2) end)
	startLock = false
	if not ok then rollbackLoaded(activeLoaded); activeLoaded = nil; clearRegistry(); return false, "Loader", started end
	if started ~= true then rollbackLoaded(activeLoaded); activeLoaded = nil; clearRegistry(); return started, moduleName, startError end
	activeLoaded = nil; return started, moduleName, startError
end
local function startSafely()
	local started, moduleName, startError = Loader.start()
	if started ~= true then
		moduleName = moduleName or "Loader"; startError = startError or started; local entry = MODULE_BY_NAME[moduleName]; printRawError(moduleName, startError, entry and entry.path or "loader.luau")
		Loader.lastError = startError
		Loader.lastErrorModule = moduleName
		Exodus.StartError = startError
		Exodus.StartErrorModule = moduleName; error(("%s: %s"):format(tostring(moduleName), tostring(startError)), 2)
	end
	Loader.lastError = nil; Loader.lastErrorModule = nil; Exodus.StartError = nil; Exodus.StartErrorModule = nil; return true
end
local started = startSafely()
Exodus.Started = started == true
if started and Exodus.Revision then
	local revision = Exodus.Revision
	task.spawn(function()
		local source, fetchError = request(BASE_URL .. revision .. "/" .. PROJECT_PATH .. "updater.luau")
		if not source then warn("[Exodus Updater] " .. tostring(fetchError)); return end
		if not Exodus.Started or Exodus.Revision ~= revision then return end
		local chunk, compileError = loadstring(source, "Exodus updater")
		if not chunk then warn("[Exodus Updater] " .. tostring(compileError)); return end
		local ok, updater = pcall(chunk)
		if not ok or type(updater) ~= "function" then warn("[Exodus Updater] " .. tostring(updater)); return end
		updater(revision, request)
	end)
end

return Loader
