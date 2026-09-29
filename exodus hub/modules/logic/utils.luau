-- [[ utils ]]

local Utils = {}
local ConfigModule

-- services
local PlayersService = game:GetService("Players")
local ReplicatedStorageService = game:GetService("ReplicatedStorage")
local RunServiceService = game:GetService("RunService")
local WorkspaceService = game:GetService("Workspace")

-- metadata
local M = {
	SCRIPT_VERSION = "35.28",
	API_VERSION = 1,
	SCRIPT_NAME = "Exodus Hub",
	INTERNAL_NAME = "Exodus",
	SCRIPT_AUTHOR = "ppzudo",
}

-- tuning
local T = {
	SPAM_RATE_MIN = 0,
	SPAM_RATE_MAX = 5000000000,
	MAX_DIAGNOSTIC_ENTRIES = 32,
	DATA_FOLDER = "Exodus Hub",
	CONSOLE_ERROR_COOLDOWN = 2,
}

-- bootstrap
task.defer(function()
	pcall(function() workspace:SetAttribute("CPS_LIMIT", 9999) end)
end)
-- state
local DiagnosticsModules = {}
local ConsoleErrorAt = {}
local ConsoleErrorCount = 0
local State = {
	active = false,
	connections = {},
	characterConnections = {},
	config = {},
	moduleURLs = {},
	manualSpamActive = false,
	autoSpamActive = false,
	dynamicSpamActive = false,
	lifecycle = {
		phase = "stopped",
		generation = 0,
		startedAt = 0,
		stoppedAt = 0,
	},
	diagnostics = {
		lastError = nil,
		lastTransition = nil,
		lastTransitionAt = 0,
		errors = {},
		transitions = {},
	},
}

-- helpers
local function disconnectAll(list)
	for index = #list, 1, -1 do
		local connection = list[index]; list[index] = nil
		if connection and type(connection.Disconnect) == "function" then pcall(connection.Disconnect, connection) end
	end
end
local function track(list, connection)
	if connection and type(connection.Disconnect) == "function" then list[#list + 1] = connection end
	return connection
end
local function untrack(list, connection)
	for index = #list, 1, -1 do
		if list[index] == connection then table.remove(list, index); return true end
	end
	return false
end
local function copyMap(source)
	local result = {}
	if type(source) ~= "table" then return result end
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end
local function copyList(source)
	local result = {}
	if type(source) ~= "table" then return result end
	for index, value in ipairs(source) do
		if type(value) == "table" then result[index] = copyMap(value)
		else result[index] = value end
	end
	return result
end
local function getModuleStatuses()
	local result = {}
	for name, module in pairs(DiagnosticsModules) do
		if type(module) == "table" and type(module.getStatus) == "function" then
			local ok, status = pcall(module.getStatus)
			if ok and type(status) == "table" then result[name] = status end
		end
	end
	return result
end
local function updateNamespace()
	local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}; namespace.Name = M.SCRIPT_NAME; namespace.InternalName = M.INTERNAL_NAME; namespace.Version = M.SCRIPT_VERSION
	namespace.ApiVersion = M.API_VERSION; namespace.Author = M.SCRIPT_AUTHOR; namespace.State = Utils.getStateSnapshot(); namespace.Config = Utils.getConfigSnapshot()
	namespace.ModuleURLs = Utils.getModuleURLsSnapshot(); namespace.Diagnostics = Utils.getDiagnostics(); _G.Exodus = namespace
end
local function setLifecyclePhase(phase)
	if type(phase) ~= "string" or phase == "" then return false end
	State.lifecycle.phase = phase; return true
end
local function recordTransition(source, fromState, toState, reason)
	State.diagnostics.lastTransition = {
		source = tostring(source),
		from = tostring(fromState),
		to = tostring(toState),
		reason = tostring(reason or ""),
	}

	State.diagnostics.lastTransitionAt = os.clock(); table.insert(State.diagnostics.transitions, State.diagnostics.lastTransition)
	if #State.diagnostics.transitions > T.MAX_DIAGNOSTIC_ENTRIES then table.remove(State.diagnostics.transitions, 1) end
	updateNamespace()
end
local function recordError(source, message)
	source = tostring(source)
	message = tostring(message)
	State.diagnostics.lastError = {
		source = source,
		message = message,
		at = os.clock(),
	}
	table.insert(State.diagnostics.errors, State.diagnostics.lastError)
	if #State.diagnostics.errors > T.MAX_DIAGNOSTIC_ENTRIES then table.remove(State.diagnostics.errors, 1) end
	updateNamespace()

	local key = source .. "\0" .. message
	local now = os.clock()
	local previous = ConsoleErrorAt[key]
	if previous and now - previous < T.CONSOLE_ERROR_COOLDOWN then return end
	if not previous then
		ConsoleErrorCount += 1
		if ConsoleErrorCount > 128 then ConsoleErrorAt = {}; ConsoleErrorCount = 1 end
	end
	ConsoleErrorAt[key] = now

	local output = ("[Exodus][%s] %s"):format(source, message)
	if type(debug) == "table" and type(debug.traceback) == "function" then
		local ok, trace = pcall(debug.traceback, output, 3)
		if ok and type(trace) == "string" then output = trace end
	end
	if type(task) == "table" and type(task.spawn) == "function" then
		local ok = pcall(task.spawn, function() error(output, 0) end)
		if ok then return end
	end
	if type(warn) == "function" then pcall(warn, output)
	elseif type(print) == "function" then pcall(print, output) end
end

-- filesystem
local function ensureDataFolder()
	if type(makefolder) ~= "function" or type(isfolder) ~= "function" then return false, "APIs de pasta do executor indisponíveis" end
	local folderOk, folderExists = pcall(isfolder, T.DATA_FOLDER)
	if not folderOk then return false, tostring(folderExists) end
	if not folderExists then
		local makeOk, makeError = pcall(makefolder, T.DATA_FOLDER)
		if not makeOk then return false, tostring(makeError or ("falha ao criar " .. T.DATA_FOLDER)) end
	end
	return true, T.DATA_FOLDER
end
function Utils.ensureDataFolder() return ensureDataFolder() end

-- lifecycle
function Utils.start()
	local previousPhase = State.lifecycle.phase; State.lifecycle.generation = State.lifecycle.generation + 1; State.lifecycle.startedAt = os.clock(); State.lifecycle.stoppedAt = 0
	State.active = true; setLifecyclePhase("starting"); recordTransition("Utils", previousPhase, "starting", "start")
	if _G.ExodusOnBurst == nil then _G.ExodusOnBurst = function() end end
	return Utils.getStateSnapshot()
end
function Utils.stop()
	local previousPhase = State.lifecycle.phase; State.active = false; State.manualSpamActive = false; State.autoSpamActive = false
	State.dynamicSpamActive = false; DiagnosticsModules = {}; State.lifecycle.stoppedAt = os.clock(); setLifecyclePhase("stopped")
	recordTransition("Utils", previousPhase, "stopped", "stop")
	if type(_G.ExodusUICleanup) == "function" then pcall(_G.ExodusUICleanup) end
	disconnectAll(State.characterConnections); disconnectAll(State.connections)
	_G.ExodusOnBurst = function() end
	if type(_G.Exodus) == "table" then
		_G.Exodus.Started = false; _G.Exodus.UIReady = false; _G.Exodus.Runtime = nil; _G.Exodus.UI = nil
		if type(_G.Exodus.RemoteHooks) == "table" then _G.Exodus.RemoteHooks.register = nil end
		if type(_G.Exodus.AutoParryHitbox) == "table" then
			local connection = _G.Exodus.AutoParryHitbox.connection
			if connection then pcall(connection.Disconnect, connection) end
			_G.Exodus.AutoParryHitbox.connection = nil; _G.Exodus.AutoParryHitbox.handler = nil
		end
	end
	updateNamespace()
end
function Utils.isActive() return State.active == true end
function Utils.getConfig() return copyMap(State.config) end
function Utils.getConfigSnapshot() return copyMap(State.config) end
function Utils.getModuleURLsSnapshot() return copyMap(State.moduleURLs) end
function Utils.setDiagnosticsModules(modules)
	if type(modules) ~= "table" then return false end
	DiagnosticsModules = copyMap(modules); updateNamespace(); return true
end
function Utils.getDiagnostics()
	return {
		schema = M.API_VERSION,
		generatedAt = os.clock(),
		lastError = State.diagnostics.lastError and copyMap(State.diagnostics.lastError) or nil,
		lastTransition = State.diagnostics.lastTransition and copyMap(State.diagnostics.lastTransition) or nil,
		lastTransitionAt = State.diagnostics.lastTransitionAt,
		errors = copyList(State.diagnostics.errors),
		transitions = copyList(State.diagnostics.transitions),
		lifecycle = Utils.getLifecycle(),
		runtime = {
			active = State.active,
			manualSpamActive = State.manualSpamActive,
			autoSpamActive = State.autoSpamActive,
			dynamicSpamActive = State.dynamicSpamActive,
		},
		modules = getModuleStatuses(),
	}

end
function Utils.getLifecycle()
	local snapshot = copyMap(State.lifecycle); snapshot.schema = M.API_VERSION; snapshot.generatedAt = os.clock(); return snapshot
end
function Utils.getStateSnapshot()
	return {
		schema = M.API_VERSION,
		generatedAt = os.clock(),
		active = State.active,
		manualSpamActive = State.manualSpamActive,
		autoSpamActive = State.autoSpamActive,
		dynamicSpamActive = State.dynamicSpamActive,
		lifecycle = copyMap(State.lifecycle),
		config = copyMap(State.config),
		moduleURLs = copyMap(State.moduleURLs),
		connectionCounts = {
			global = #State.connections,
			character = #State.characterConnections,
		},

	}
end
function Utils.setLifecyclePhase(phase)
	local previous = State.lifecycle.phase; local changed = setLifecyclePhase(phase)
	if changed and previous ~= phase then recordTransition("Lifecycle", previous, phase, "phase_change") end
	return changed
end
function Utils.recordTransition(source, fromState, toState, reason) recordTransition(source, fromState, toState, reason) end
function Utils.recordError(source, message) recordError(source, message) end
function Utils.isManualSpamActive() return State.manualSpamActive == true end
function Utils.isAutoSpamActive() return State.autoSpamActive == true end
function Utils.isSpamActive()
	return State.manualSpamActive == true or State.autoSpamActive == true or State.dynamicSpamActive == true
end
function Utils.isDynamicSpamActive() return State.dynamicSpamActive == true end
function Utils.setAutoSpamActive(value)
	local nextValue = value == true
	if State.autoSpamActive == nextValue then return end
	local previous = State.autoSpamActive; State.autoSpamActive = nextValue
	recordTransition(
		"AutoClash",
		previous and "active" or "inactive",
		nextValue and "active" or "inactive",
		"automatic_toggle"
	)
end
function Utils.setManualSpamActive(value)
	local nextValue = value == true
	if State.manualSpamActive == nextValue then return end
	local previous = State.manualSpamActive; State.manualSpamActive = nextValue; recordTransition("Spam", previous and "active" or "inactive", nextValue and "active" or "inactive", "manual_toggle")
end
function Utils.setDynamicSpamActive(value)
	local nextValue = value == true
	if State.dynamicSpamActive == nextValue then return end
	local previous = State.dynamicSpamActive; State.dynamicSpamActive = nextValue
	recordTransition(
		"DynamicParry",
		previous and "active" or "inactive",
		nextValue and "active" or "inactive",
		"dynamic_spam_toggle"
	)
end

function Utils.isFiniteNumber(value)
	return type(value) == "number" and value == value and value < math.huge and value > -math.huge
end
function Utils.isNonNegativeFiniteNumber(value)
	return Utils.isFiniteNumber(value) and value >= 0
end
function Utils.normalizeSpamRate(value, fallback)
	local rate = tonumber(value)
	if not Utils.isFiniteNumber(rate) then rate = tonumber(fallback) end
	if not Utils.isFiniteNumber(rate) then rate = T.SPAM_RATE_MIN end
	return math.clamp(rate, T.SPAM_RATE_MIN, T.SPAM_RATE_MAX)
end
function Utils.setConfig(config)
	if type(config) ~= "table" then return false end
	local normalized, reason
	if ConfigModule and type(ConfigModule.normalizePatch) == "function" then normalized, reason = ConfigModule.normalizePatch(config)
	else normalized = copyMap(config) end
	if type(normalized) ~= "table" then
		if type(Utils.recordError) == "function" then Utils.recordError("Config", reason or "configuração inválida") end
		return false
	end
	for key, value in pairs(normalized) do
		State.config[key] = value
	end
	updateNamespace(); return true
end
function Utils.setConfigModule(module)
	if type(module) ~= "table" or type(module.normalizePatch) ~= "function" or type(module.validate) ~= "function" then return false end
	ConfigModule = module; return true
end
function Utils.setModuleURLs(urls)
	if type(urls) ~= "table" then return false end
	for key, value in pairs(urls) do
		State.moduleURLs[key] = value
	end
	updateNamespace(); return true
end
function Utils.trackGlobal(connection) return track(State.connections, connection) end
function Utils.untrackGlobal(connection) return untrack(State.connections, connection) end
function Utils.trackCharacter(connection) return track(State.characterConnections, connection) end
function Utils.untrackCharacter(connection) return untrack(State.characterConnections, connection) end
function Utils.disconnectCharacterConnections() disconnectAll(State.characterConnections) end
function Utils.getPlayers() return PlayersService end
function Utils.getReplicatedStorage() return ReplicatedStorageService end
function Utils.getRunService() return RunServiceService end
function Utils.getWorkspace() return WorkspaceService end
function Utils.getLocalPlayer() return PlayersService.LocalPlayer end
function Utils.now() return os.clock() end
function Utils.name() return M.SCRIPT_NAME end
function Utils.version() return M.SCRIPT_VERSION end
function Utils.apiVersion() return M.API_VERSION end
function Utils.author() return M.SCRIPT_AUTHOR end
function Utils.log(level, message)
	local text = ("[%s] %s"):format(M.INTERNAL_NAME, tostring(message))
	if level == "warn" then warn(text)
	else print(text) end
end
function Utils.info(message) Utils.log("info", message) end
function Utils.warn(message) Utils.log("warn", message) end
_G.ExodusStop = Utils.stop
Utils.__contract = { requires = {} }

return Utils
