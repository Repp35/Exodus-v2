-- [[ utils ]]

local Utils = {}
local players = game:GetService("Players")
local replicated = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")
local workspace = game:GetService("Workspace")
local http = game:GetService("HttpService")
local API_VERSION, VERSION, NAME, AUTHOR = 1, "3.0.0", "Exodus Hub", "delta"
local FOLDER, HISTORY_LIMIT = "Exodus Hub", 32
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
local savePending, saveToken, saveWriting, saveDirty, saveSnapshot = false, 0, false, false, nil
local refreshPending, refreshing = false, false
local spamObservers, configObservers = {}, {}
local function copy(value, depth)
	if type(value) ~= "table" or (depth or 0) > 8 then return value end
	local result = {}
	for key, item in pairs(value) do
		result[copy(key, (depth or 0) + 1)] = copy(item, (depth or 0) + 1)
	end
	return result
end
local function snapshot(value) return type(value) == "table" and copy(value) or {} end
local function append(list, value)
	list[#list + 1] = value
	if #list > HISTORY_LIMIT then table.remove(list, 1) end
end
local function connectObserver(list, observer)
	if type(observer) ~= "function" then return nil end
	if not table.find(list, observer) then table.insert(list, observer) end
	return {
		Disconnect = function()
			local index = table.find(list, observer)
			if index then table.remove(list, index) end
		end,
	}
end
local function notify(list, label, value)
	for _, observer in ipairs(table.clone(list)) do
		local ok, err = pcall(observer, value)
		if not ok then warn("[" .. label .. "] " .. tostring(err)) end
	end
end
function Utils.observeSpam(observer) return connectObserver(spamObservers, observer) end
function Utils.observeConfig(observer) return connectObserver(configObservers, observer) end
local function track(list, connection)
	if connection and type(connection.Disconnect) == "function" then list[#list + 1] = connection end
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
		local connection = list[i]; list[i] = nil; pcall(connection.Disconnect, connection)
	end
end
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
			if ok and type(status) == "table" then statuses[name] = snapshot(status) elseif not ok then statuses[name] = { ok = false, error = tostring(status) } end
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
local function refreshNamespace()
	if refreshing then return end
	refreshing = true
	pcall(function()
		local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
		namespace.Name, namespace.InternalName, namespace.Version, namespace.ApiVersion, namespace.Author = NAME, "Exodus", VERSION, API_VERSION, AUTHOR
		namespace.State, namespace.Config, namespace.ModuleURLs, namespace.Diagnostics =
			stateSnapshot(), snapshot(state.config), snapshot(state.urls), diagnosticsSnapshot()
		_G.Exodus = namespace
	end)
	refreshing = false
end
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
	if not refreshPending then
		refreshPending = true
		task.delay(0.1, function()
			refreshPending = false; refreshNamespace()
		end)
	end
end
function Utils.ensureDataFolder()
	if type(makefolder) ~= "function" or type(isfolder) ~= "function" then return false, "APIs de pasta do executor indisponíveis" end
	local ok, exists = pcall(isfolder, FOLDER)
	if not ok then return false, tostring(exists) end
	if not exists then
		local created, err = pcall(makefolder, FOLDER)
		if not created then return false, tostring(err or ("falha ao criar " .. FOLDER)) end
	end
	return true, FOLDER
end
local function saveConfig(config)
	if not persistenceReady or type(writefile) ~= "function" then return end
	local ok, folder = Utils.ensureDataFolder()
	if not ok then Utils.recordError("Config", folder); return end
	local data = {}
	for key, value in pairs(config) do
		data[key] = typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode and { keyCode = value.Name } or value
	end
	local encoded, body = pcall(http.JSONEncode, http, data)
	if not encoded then Utils.recordError("Config", body); return end
	local written, err = pcall(writefile, folder .. "/config.json", body)
	if not written or err == false then Utils.recordError("Config", err or "falha ao salvar") end
end
local function flushSave()
	if saveWriting then return end
	saveWriting = true
	while saveDirty do
		local config = saveSnapshot; saveDirty = false; saveConfig(config)
	end
	saveWriting = false
end
local function queueSave()
	if not persistenceReady or type(writefile) ~= "function" then return end
	saveSnapshot, saveDirty = snapshot(state.config), true
	if savePending or saveWriting then return end
	savePending = true; saveToken += 1; local token = saveToken
	task.delay(0.25, function()
		if token ~= saveToken then return end
		savePending = false; flushSave()
	end)
end
function Utils.start()
	local previous = state.lifecycle.phase; state.active = true; state.lifecycle.generation += 1
	state.lifecycle.startedAt, state.lifecycle.stoppedAt, state.lifecycle.phase = os.clock(), 0, "starting"
	recordTransition("Utils", previous, "starting", "start")
	if _G.ExodusOnBurst == nil then _G.ExodusOnBurst = function() end end
	refreshNamespace(); return stateSnapshot()
end
function Utils.stop()
	local previous = state.lifecycle.phase
	state.active, state.autoSpam = false, false
	notify(spamObservers, "Spam")
	if savePending then saveToken += 1; savePending = false end
	if saveDirty then flushSave() end
	state.lifecycle.stoppedAt = os.clock()
	_G.ExodusOnBurst = function() end
	if type(_G.ExodusUICleanup) == "function" then pcall(_G.ExodusUICleanup) end
	disconnectAll(state.characterConnections); disconnectAll(state.globalConnections)
	state.config, state.urls, modules = {}, {}, {}
	if type(_G.Exodus) == "table" then
		local exodus = _G.Exodus
		exodus.Started, exodus.UIReady, exodus.Runtime, exodus.UI = false, false, nil, nil
		if type(exodus.RemoteHooks) == "table" then exodus.RemoteHooks.register = nil end
		if type(exodus.AutoParryHitbox) == "table" then
			local hitbox = exodus.AutoParryHitbox
			if hitbox.connection then pcall(hitbox.connection.Disconnect, hitbox.connection) end
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
	if type(value) ~= "table" then return false end
	modules = snapshot(value); refreshNamespace(); return true
end
function Utils.setLifecyclePhase(value)
	if type(value) ~= "string" or value == "" then return false end
	local previous = state.lifecycle.phase
	if previous ~= value then state.lifecycle.phase = value; recordTransition("Lifecycle", previous, value, "phase_change") end
	return true
end
function Utils.recordTransition(source, fromState, toState, reason) recordTransition(source, fromState, toState, reason) end
function Utils.recordError(source, message)
	local item = { source = tostring(source or "Unknown"), message = tostring(message or ""), at = os.clock() }; state.diagnostics.lastError = item; append(state.diagnostics.errors, item)
	warn(("[%s] %s"):format(item.source, item.message)); refreshNamespace(); return true
end
function Utils.isManualSpamActive() return state.manualSpam end
function Utils.isAutoSpamActive() return state.autoSpam end
function Utils.isSpamActive() return state.manualSpam or state.autoSpam end
local function setSpam(key, value, source, reason)
	value = value == true
	if state[key] == value then return false end
	local previous = state[key]; state[key] = value; notify(spamObservers, "Spam"); recordTransition(source, previous and "active" or "inactive", value and "active" or "inactive", reason)
	return true
end
function Utils.setManualSpamActive(value) return setSpam("manualSpam", value, "Spam", "manual_toggle") end
function Utils.setAutoSpamActive(value) return setSpam("autoSpam", value, "AutoSpam", "automatic_toggle") end
function Utils.stopAllSpam()
	local changed = state.manualSpam or state.autoSpam
	state.manualSpam, state.autoSpam = false, false
	if changed then notify(spamObservers, "Spam") end
	return true
end
function Utils.isFiniteNumber(value) return type(value) == "number" and value == value and value > -math.huge and value < math.huge end
function Utils.isNonNegativeFiniteNumber(value) return Utils.isFiniteNumber(value) and value >= 0 end
function Utils.normalizeSpamRate(value, fallback)
	local rate = tonumber(value)
	if not Utils.isFiniteNumber(rate) then rate = tonumber(fallback) end
	if not Utils.isFiniteNumber(rate) then rate = 0 end
	return math.max(rate, 0)
end
function Utils.setConfig(patch)
	if type(patch) ~= "table" then return false end
	local normalized = snapshot(patch)
	if configModule then
		local ok, result, reason = pcall(configModule.normalizePatch, patch)
		if not ok then return false, result end
		if type(result) ~= "table" then return false, reason end
		normalized = result
	end
	for key, value in pairs(normalized) do
		state.config[key] = value
	end
	notify(configObservers, "Config", normalized)
	if normalized.SpamRateMode ~= nil or normalized.CPF ~= nil then notify(spamObservers, "Spam") end
	refreshNamespace(); queueSave(); return true
end
function Utils.loadConfig()
	if type(isfile) == "function" and type(readfile) == "function" then
		local ok, folder = Utils.ensureDataFolder()
		if ok then
			local path = folder .. "/config.json"; local existsOk, exists = pcall(isfile, path)
			if existsOk and exists then
				local readOk, body = pcall(readfile, path); local decoded, data = false, nil
				if readOk then decoded, data = pcall(http.JSONDecode, http, body) end
				if decoded and type(data) == "table" then
					local keys = {}
					for key in pairs(data) do
						if type(key) == "string" then keys[#keys + 1] = key end
					end
					table.sort(keys)
					for _, key in ipairs(keys) do
						local value = data[key]
						if type(value) == "table" and type(value.keyCode) == "string" then
							local found, item = pcall(function() return Enum.KeyCode[value.keyCode] end)
							value = found and item or nil
						end
						if key ~= "AutoClashActivationMs" and key ~= "AutoClashDeactivationMs" and value ~= nil then Utils.setConfig({ [key] = value }) end
					end
				else
					Utils.recordError("Config", tostring(readOk and data or body))
				end
			end
		end
	end
	persistenceReady = true; return true
end
function Utils.setConfigModule(module)
	if type(module) ~= "table" or type(module.normalizePatch) ~= "function" or type(module.validate) ~= "function" then return false end
	configModule = module; return true
end
function Utils.setModuleURLs(urls)
	if type(urls) ~= "table" then return false end
	for key, value in pairs(urls) do
		state.urls[key] = value
	end
	refreshNamespace(); return true
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
Utils.__contract = {
	requires = {},
	provides = {
		"start",
		"stop",
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
		"getRunService",
		"getReplicatedStorage",
		"getWorkspace",
		"now",
		"apiVersion",
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
		"normalizeSpamRate",
	},

}

return Utils
