-- [[ utils ]]

local Utils = {}

-- services
local players = game:GetService("Players")
local replicated = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")
local workspace = game:GetService("Workspace")
local http = game:GetService("HttpService")
local API_VERSION, VERSION, NAME, AUTHOR = 1, "3.0.0", "Exodus Hub", "delta"

-- tuning
local T = { FOLDER = "Exodus Hub", HISTORY_LIMIT = 32 }

-- state
local state = {
	active = false,
	config = {},
	urls = {},
	globalConnections = {},
	characterConnections = {},
	manualSpam = false,
	autoSpam = false,
	lifecycle = { phase = "stopped", generation = 0, startedAt = 0, stoppedAt = 0 },
	diagnostics = { errors = {}, transitions = {}, lastTransitionAt = 0 },
}

local configModule, modules, persistenceReady = nil, {}, false
local savePending, saveToken, saveDirty = false, 0, false
local refreshPending, refreshing = false, false
local spamObservers, configObservers = {}, {}

-- helpers
local function copy(value, depth)
	if type(value) ~= "table" then return value end
	depth = depth or 0
	if depth > 8 then return value end
	local result = {}
	for key, item in pairs(value) do
		result[copy(key, depth + 1)] = copy(item, depth + 1)
	end
	return result
end
local function snapshot(value) return type(value) == "table" and copy(value) or {} end
local function append(list, value)
	list[#list + 1] = value
	if #list > T.HISTORY_LIMIT then table.remove(list, 1) end
end
local function setValues(target, source)
	for key, value in pairs(source or {}) do
		target[key] = value
	end
end

-- observers
local function connectObserver(list, observer)
	if type(observer) ~= "function" then error("Observer precisa ser uma função", 2) end
	local connection = { Connected = true }; list[#list + 1] = connection; connection.callback = observer
	function connection:Disconnect()
		if not self.Connected then return end
		self.Connected = false; local index = table.find(list, self)
		if index then table.remove(list, index) end
	end
	return connection
end
local function notify(list, value)
	if #list == 0 then return end
	for _, observer in ipairs(table.clone(list)) do
		if observer.Connected then observer.callback(value) end
	end
end
function Utils.observeSpam(observer) return connectObserver(spamObservers, observer) end
function Utils.observeConfig(observer) return connectObserver(configObservers, observer) end
local function track(list, connection)
	if not connection or type(connection.Disconnect) ~= "function" then error("Conexão inválida", 2) end
	if not table.find(list, connection) then list[#list + 1] = connection end
	return connection
end
local function untrack(list, connection)
	for i = #list, 1, -1 do
		if list[i] == connection then table.remove(list, i); return true end
	end
	return false
end
local function disconnectAll(list)
	for i = #list, 1, -1 do
		local connection = list[i]; list[i] = nil
		if connection then
			local ok, err = pcall(connection.Disconnect, connection)
			if not ok then warn("Falha ao desconectar: " .. tostring(err)) end
		end
	end
end

-- snapshots
local function lifecycleSnapshot()
	local result = snapshot(state.lifecycle)
	result.schema, result.generatedAt = API_VERSION, os.clock()
	return result
end
local function stateSnapshot()
	return {
		schema = API_VERSION,
		generatedAt = os.clock(),
		active = state.active,
		manualSpamActive = state.manualSpam,
		autoSpamActive = state.autoSpam,
		lifecycle = snapshot(state.lifecycle),
		config = snapshot(state.config),
		moduleURLs = snapshot(state.urls),
		connectionCounts = { global = #state.globalConnections, character = #state.characterConnections },
	}
end
local function diagnosticsSnapshot()
	local statuses = {}; local names = {}
	for name in pairs(modules) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local module = modules[name]
		if type(module) == "table" and type(module.getStatus) == "function" then
			local ok, status = pcall(module.getStatus)
			if ok and type(status) == "table" then statuses[name] = snapshot(status) end
		end
	end
	local diagnostics = state.diagnostics
	return {
		schema = API_VERSION,
		generatedAt = os.clock(),
		lastError = snapshot(diagnostics.lastError),
		lastTransition = snapshot(diagnostics.lastTransition),
		lastTransitionAt = diagnostics.lastTransitionAt,
		errors = snapshot(diagnostics.errors),
		transitions = snapshot(diagnostics.transitions),
		lifecycle = lifecycleSnapshot(),
		runtime = { active = state.active, manualSpamActive = state.manualSpam, autoSpamActive = state.autoSpam },
		modules = statuses,
	}
end

-- environment
local function refreshNamespace()
	if refreshing then return end
	refreshing = true; local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
	namespace.Name, namespace.InternalName, namespace.Version, namespace.ApiVersion, namespace.Author = NAME, "Exodus", VERSION, API_VERSION, AUTHOR
	namespace.State, namespace.Config, namespace.ModuleURLs, namespace.Diagnostics =
		stateSnapshot(), snapshot(state.config), snapshot(state.urls), diagnosticsSnapshot()
	_G.Exodus = namespace; refreshing = false
end

-- diagnostics
local function recordTransition(source, fromState, toState, reason)
	local item = {
		source = tostring(source or "Unknown"),
		from = tostring(fromState or ""),
		to = tostring(toState or ""),
		reason = tostring(reason or ""),
		at = os.clock(),
	}

	state.diagnostics.lastTransition, state.diagnostics.lastTransitionAt = item, item.at
	append(state.diagnostics.transitions, item)
	if state.active and not refreshPending then
		refreshPending = true; local generation = state.lifecycle.generation
		task.delay(0.1, function()
			refreshPending = false
			if state.active and state.lifecycle.generation == generation then refreshNamespace() end
		end)
	end
end

-- persistence
function Utils.ensureDataFolder()
	if type(makefolder) ~= "function" then error("API externa ausente: makefolder", 2) end
	if type(isfolder) ~= "function" then error("API externa ausente: isfolder", 2) end
	if not isfolder(T.FOLDER) then makefolder(T.FOLDER) end
	return true, T.FOLDER
end
function Utils.createClashLog(partnerId, startedDate)
	if type(writefile) ~= "function" or type(isfile) ~= "function" then error("APIs externas ausentes: writefile/isfile", 2) end
	local _, folder = Utils.ensureDataFolder(); local directory = folder .. "/Clashes"
	if not isfolder(directory) then makefolder(directory) end
	local stamp = os.date("!%Y%m%d_%H%M%S"); local prefix = directory .. "/clash_" .. stamp .. "_" .. tostring(partnerId); local index, path = 1, prefix .. ".txt"
	while isfile(path) do
		index += 1; path = prefix .. "_" .. index .. ".txt"
	end
	local header = "EXODUS - CLASH\nData (UTC): " .. (startedDate or os.date("!%Y-%m-%d %H:%M:%S")) .. "\n"; writefile(path, header)
	local content
	if type(appendfile) ~= "function" then content = header end
	return { path = path, content = content }
end
function Utils.appendClashLog(log, value)
	if type(log) ~= "table" or type(log.path) ~= "string" or type(value) ~= "string" then error("Dados inválidos para o registro de clash", 2) end
	if type(appendfile) == "function" and log.content == nil then appendfile(log.path, value) else log.content = (log.content or "") .. value; writefile(log.path, log.content) end
	return true
end
local function serializeConfig(config)
	local data = {}
	for key, value in pairs(config) do
		if typeof(value) == "EnumItem" then data[key] = value.EnumType == Enum.KeyCode and { keyCode = value.Name } or { mouseButton = value.Name } else data[key] = value end
	end
	return http:JSONEncode(data)
end
local function persistenceAvailable()
	return type(isfile) == "function"
		and type(readfile) == "function"
		and type(writefile) == "function"
		and type(isfolder) == "function"
		and type(makefolder) == "function"
end
local function decodeKeyCode(value)
	if type(value) == "table" and type(value.mouseButton) == "string" then
		local buttons =
			{ MouseButton1 = Enum.UserInputType.MouseButton1, MouseButton2 = Enum.UserInputType.MouseButton2, MouseButton3 = Enum.UserInputType.MouseButton3 }
		return buttons[value.mouseButton]
	end
	if type(value) ~= "table" or type(value.keyCode) ~= "string" then return value end
	local name = value.keyCode
	local ok, keyCode = pcall(function() return Enum.KeyCode[name] end)
	if ok and keyCode then return keyCode end
	warn("Config ignorada: KeyCode inválido " .. tostring(name)); return nil
end
local function migrateConfig(data)
	local migrated = data.AutoClash ~= nil or data.AutoClashActivationMs ~= nil or data.AutoClashDeactivationMs ~= nil
	if data.AutoSpam == nil and type(data.AutoClash) == "boolean" then data.AutoSpam, migrated = data.AutoClash, true end
	if data.AutoParryFactor08Applied ~= true then
		data.AutoParryWindowFactor, data.AutoParryFactor08Applied, migrated = 0.8, true, true
	end
	local patch = {}
	for key, value in pairs(data) do
		if key ~= "AutoClash" and key ~= "AutoClashActivationMs" and key ~= "AutoClashDeactivationMs" then
			value = decodeKeyCode(value)
			if value ~= nil then
				local valid, reason = configModule.validatePatch({ [key] = value })
				if valid then patch[key] = value else warn("Config ignorada: " .. tostring(reason)) end
			end
		end
	end
	return patch, migrated
end
local function saveConfig()
	if not persistenceReady or not saveDirty then return end
	if type(writefile) ~= "function" then error("API externa ausente: writefile", 2) end
	local _, folder = Utils.ensureDataFolder(); local body = serializeConfig(state.config); writefile(folder .. "/config.json", body); saveDirty = false
end
local function queueSave()
	if not persistenceReady then return end
	saveDirty = true
	if savePending then return end
	savePending = true; saveToken += 1; local token = saveToken
	task.delay(0.25, function()
		if token ~= saveToken then return end
		savePending = false; saveConfig()
	end)
end
local function flushSave()
	saveToken += 1; savePending = false; saveConfig()
end

-- lifecycle
function Utils.start()
	local previous = state.lifecycle.phase; state.active = true; state.lifecycle.generation += 1
	state.lifecycle.startedAt, state.lifecycle.stoppedAt, state.lifecycle.phase = os.clock(), 0, "starting"
	recordTransition("Utils", previous, "starting", "start")
	if _G.ExodusOnBurst == nil then _G.ExodusOnBurst = function() end end
	refreshNamespace(); return stateSnapshot()
end
function Utils.stop()
	local previous = state.lifecycle.phase
	state.active, state.manualSpam, state.autoSpam = false, false, false
	local notified, notifyError = pcall(notify, spamObservers)
	if not notified then warn("Falha ao avisar observadores: " .. tostring(notifyError)) end
	local saved, saveError = pcall(flushSave)
	if not saved then warn("Falha ao salvar configuração: " .. tostring(saveError)) end
	state.lifecycle.stoppedAt = os.clock()
	_G.ExodusOnBurst = function() end
	if type(_G.ExodusUICleanup) == "function" then
		local cleaned, cleanupError = pcall(_G.ExodusUICleanup)
		if not cleaned then warn("Falha ao limpar interface: " .. tostring(cleanupError)) end
	end
	disconnectAll(state.characterConnections); disconnectAll(state.globalConnections)
	state.config, state.urls, modules = {}, {}, {}
	persistenceReady, saveDirty = false, false; table.clear(spamObservers); table.clear(configObservers)
	if type(_G.Exodus) == "table" then
		local exodus = _G.Exodus
		exodus.Started, exodus.UIReady, exodus.Runtime, exodus.UI = false, false, nil, nil
		if type(exodus.RemoteHooks) == "table" then exodus.RemoteHooks.register = nil end
		if type(exodus.AutoParryHitbox) == "table" then
			local hitbox = exodus.AutoParryHitbox
			if hitbox.connection then hitbox.connection:Disconnect() end
			hitbox.connection, hitbox.handler = nil, nil
		end
	end
	state.lifecycle.phase = "stopped"; recordTransition("Utils", previous, "stopped", "stop"); refreshNamespace(); return true
end
function Utils.isActive() return state.active end
function Utils.getStateSnapshot() return stateSnapshot() end
function Utils.getConfig() return snapshot(state.config) end
function Utils.getConfigValue(key) return state.config[key] end
function Utils.getConfigSnapshot() return snapshot(state.config) end
function Utils.getModuleURLsSnapshot() return snapshot(state.urls) end
function Utils.getLifecycle() return lifecycleSnapshot() end
function Utils.getDiagnostics() return diagnosticsSnapshot() end
function Utils.setDiagnosticsModules(value)
	if type(value) ~= "table" then error("Módulos de diagnóstico inválidos", 2) end
	modules = table.clone(value); refreshNamespace(); return true
end
function Utils.setLifecyclePhase(value)
	if type(value) ~= "string" or value == "" then return false end
	local previous = state.lifecycle.phase
	if previous ~= value then state.lifecycle.phase = value; recordTransition("Lifecycle", previous, value, "phase_change") end
	return true
end
function Utils.recordTransition(source, fromState, toState, reason) recordTransition(source, fromState, toState, reason) end
function Utils.recordError(source, message)
	local item = { source = tostring(source or "Unknown"), message = tostring(message or ""), at = os.clock() }; state.diagnostics.lastError = item; append(state.diagnostics.errors, item); warn(("[%s] %s"):format(item.source, item.message)); refreshNamespace(); return true
end
function Utils.isManualSpamActive() return state.manualSpam end
function Utils.isAutoSpamActive() return state.autoSpam end
function Utils.isSpamActive() return state.manualSpam or state.autoSpam end
local function setSpam(key, value, source, reason)
	value = value == true
	if state[key] == value then return false end
	local previous = state[key]; state[key] = value; notify(spamObservers); recordTransition(source, previous and "active" or "inactive", value and "active" or "inactive", reason); return true
end
function Utils.setManualSpamActive(value) return setSpam("manualSpam", value, "Spam", "manual_toggle") end
function Utils.setAutoSpamActive(value) return setSpam("autoSpam", value, "AutoSpam", "automatic_toggle") end
function Utils.stopAllSpam()
	local changed = state.manualSpam or state.autoSpam
	state.manualSpam, state.autoSpam = false, false
	if changed then notify(spamObservers) end
	return true
end
function Utils.isFiniteNumber(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
function Utils.isNonNegativeFiniteNumber(value) return Utils.isFiniteNumber(value) and value >= 0 end

-- config
function Utils.normalizeSpamRate(value, fallback)
	local rate = tonumber(value)
	if not Utils.isFiniteNumber(rate) then rate = tonumber(fallback) end
	if not Utils.isFiniteNumber(rate) then rate = 0 end
	return math.max(rate, 0)
end
function Utils.setConfig(patch)
	if type(patch) ~= "table" then error("Config patch inválido: esperado table", 2) end
	local normalized
	if configModule then
		local result, reason = configModule.normalizePatch(patch)
		if type(result) ~= "table" then error("Config inválida: " .. tostring(reason), 2) end
		normalized = result
	else
		normalized = snapshot(patch)
	end
	setValues(state.config, normalized); notify(configObservers, normalized)
	if normalized.SpamRateMode ~= nil or normalized.CPS ~= nil or normalized.CPF ~= nil then notify(spamObservers) end
	refreshNamespace(); queueSave(); return true
end
function Utils.loadConfig()
	if not persistenceAvailable() then warn("Persistência indisponível; usando configuração da sessão"); return true end
	local ok, folder = pcall(function()
		local _, path = Utils.ensureDataFolder(); return path
	end)
	if not ok then warn("Persistência indisponível: " .. tostring(folder)); return true end
	local path = folder .. "/config.json"; local migrated = false; local checked, exists = pcall(isfile, path)
	if not checked then warn("Não foi possível verificar a configuração: " .. tostring(exists)); return true end
	if exists then
		local loaded, data = pcall(function() return http:JSONDecode(readfile(path)) end)
		if not loaded or type(data) ~= "table" then warn("Configuração salva inválida ou inacessível; usando padrões"); return true end
		local patch
		patch, migrated = migrateConfig(data); Utils.setConfig(patch)
	end
	persistenceReady = true
	if migrated then queueSave() end
	return true
end
function Utils.setConfigModule(module)
	if type(module) ~= "table" or type(module.normalizePatch) ~= "function" or type(module.validate) ~= "function" then error("API interna ausente: Config.normalizePatch/validate", 2) end
	configModule = module; return true
end
function Utils.setModuleURLs(urls)
	if type(urls) ~= "table" then error("URLs de módulos inválidas", 2) end
	setValues(state.urls, urls); refreshNamespace(); return true
end
function Utils.trackGlobal(connection) return track(state.globalConnections, connection) end
function Utils.untrackGlobal(connection) return untrack(state.globalConnections, connection) end
function Utils.trackCharacter(connection) return track(state.characterConnections, connection) end
function Utils.untrackCharacter(connection) return untrack(state.characterConnections, connection) end
function Utils.disconnectCharacterConnections() disconnectAll(state.characterConnections) end
function Utils.getPlayers() return players end
function Utils.getReplicatedStorage() return replicated end
function Utils.getRunService() return runService end
function Utils.getWorkspace() return workspace end
function Utils.getLocalPlayer() return players.LocalPlayer end
function Utils.now() return os.clock() end
function Utils.name() return NAME end
function Utils.version() return VERSION end
function Utils.apiVersion() return API_VERSION end
function Utils.author() return AUTHOR end
_G.ExodusStop = Utils.stop

-- contract
Utils.__contract = {
	requires = {},
	provides = {
		"start",
		"stop",
		"ensureDataFolder",
		"loadConfig",
		"getDiagnostics",
		"getLifecycle",
		"isFiniteNumber",
		"isNonNegativeFiniteNumber",
		"isActive",
		"getConfig",
		"getConfigValue",
		"setConfig",
		"setConfigModule",
		"setModuleURLs",
		"setDiagnosticsModules",
		"setLifecyclePhase",
		"getStateSnapshot",
		"getConfigSnapshot",
		"getModuleURLsSnapshot",
		"getPlayers",
		"getLocalPlayer",
		"createClashLog",
		"appendClashLog",
		"getRunService",
		"getReplicatedStorage",
		"getWorkspace",
		"now",
		"apiVersion",
		"name",
		"author",
		"version",
		"trackGlobal",
		"untrackGlobal",
		"trackCharacter",
		"untrackCharacter",
		"disconnectCharacterConnections",
		"recordError",
		"recordTransition",
		"isSpamActive",
		"isManualSpamActive",
		"isAutoSpamActive",
		"setManualSpamActive",
		"setAutoSpamActive",
		"stopAllSpam",
		"observeConfig",
		"observeSpam",
		"normalizeSpamRate",
	},

}

return Utils
