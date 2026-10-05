-- [[ utils ]]

local Utils = {}

-- services
local PlayersService = game:GetService("Players")
local ReplicatedStorageService = game:GetService("ReplicatedStorage")
local RunServiceService = game:GetService("RunService")
local WorkspaceService = game:GetService("Workspace")

-- metadata
local M = {
	SCRIPT_VERSION = "35.42",
	API_VERSION = 1,
	SCRIPT_NAME = "Exodus Hub",
	INTERNAL_NAME = "Exodus",
	SCRIPT_AUTHOR = "delta",
}

-- tuning
local T = {
	SPAM_RATE_MIN = 0,
	SPAM_RATE_MAX = 5000000000,
	MAX_DIAGNOSTIC_ENTRIES = 32,
	MAX_CONSOLE_ERROR_KEYS = 128,
	DATA_FOLDER = "Exodus Hub",
	CONSOLE_ERROR_COOLDOWN = 2,
}

-- dependencies
local ConfigModule

-- state
local State = {
	active = false,
	connections = {},
	characterConnections = {},
	config = {},
	moduleURLs = {},
	manualSpamActive = false,
	autoSpamActive = false,
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

local DiagnosticsModules = {}
local ConsoleErrorAt = {}
local ConsoleErrorCount = 0
local NamespaceUpdating = false

-- bootstrap
task.defer(function()
	pcall(function() WorkspaceService:SetAttribute("CPS_LIMIT", 9999) end)
end)
local function isConnection(value) return value ~= nil and type(value.Disconnect) == "function" end
local function disconnect(connection)
	if not isConnection(connection) then return false end
	local ok = pcall(connection.Disconnect, connection); return ok
end
local function disconnectAll(list)
	if type(list) ~= "table" then return end
	for index = #list, 1, -1 do
		local connection = list[index]; list[index] = nil; disconnect(connection)
	end
end
local function track(list, connection)
	if not isConnection(connection) then return connection end
	list[#list + 1] = connection; return connection
end
local function untrack(list, connection)
	if type(list) ~= "table" or connection == nil then return false end
	for index = #list, 1, -1 do
		if list[index] == connection then table.remove(list, index); return true end
	end
	return false
end
local function copyValue(value, depth)
	depth = depth or 0
	if depth > 8 then return value end
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do
		result[copyValue(key, depth + 1)] = copyValue(item, depth + 1)
	end
	return result
end
local function copyMap(source)
	if type(source) ~= "table" then return {} end
	return copyValue(source)
end
local function copyList(source)
	if type(source) ~= "table" then return {} end
	return copyValue(source)
end
local function appendLimited(list, value, limit)
	list[#list + 1] = value
	if #list > limit then table.remove(list, 1) end
end
local function safeCall(callback, ...)
	if type(callback) ~= "function" then return false, "callback is not a function" end
	return pcall(callback, ...)
end
local function getModuleStatuses()
	local result = {}
	for name, module in pairs(DiagnosticsModules) do
		if type(module) == "table" and type(module.getStatus) == "function" then
			local ok, status = pcall(module.getStatus)
			if ok and type(status) == "table" then
				result[name] = copyMap(status)
			elseif not ok then
				result[name] = {
					ok = false,
					error = tostring(status),
				}

			end
		end
	end
	return result
end
local function getLifecycleSnapshot()
	local snapshot = copyMap(State.lifecycle); snapshot.schema = M.API_VERSION; snapshot.generatedAt = os.clock(); return snapshot
end
local function getDiagnosticsSnapshot()
	return {
		schema = M.API_VERSION,
		generatedAt = os.clock(),
		lastError = copyMap(State.diagnostics.lastError),
		lastTransition = copyMap(State.diagnostics.lastTransition),
		lastTransitionAt = State.diagnostics.lastTransitionAt,
		errors = copyList(State.diagnostics.errors),
		transitions = copyList(State.diagnostics.transitions),
		lifecycle = getLifecycleSnapshot(),
		runtime = {
			active = State.active,
			manualSpamActive = State.manualSpamActive,
			autoSpamActive = State.autoSpamActive,
		},

		modules = getModuleStatuses(),
	}
end
local function getStateSnapshotInternal()
	return {
		schema = M.API_VERSION,
		generatedAt = os.clock(),
		active = State.active,
		manualSpamActive = State.manualSpamActive,
		autoSpamActive = State.autoSpamActive,
		lifecycle = copyMap(State.lifecycle),
		config = copyMap(State.config),
		moduleURLs = copyMap(State.moduleURLs),
		connectionCounts = {
			global = #State.connections,
			character = #State.characterConnections,
		},

	}
end
local function updateNamespace()
	if NamespaceUpdating then return end
	NamespaceUpdating = true
	pcall(function()
		local namespace
		if type(_G.Exodus) == "table" then namespace = _G.Exodus
		else namespace = {} end
		namespace.Name = M.SCRIPT_NAME; namespace.InternalName = M.INTERNAL_NAME; namespace.Version = M.SCRIPT_VERSION; namespace.ApiVersion = M.API_VERSION
		namespace.Author = M.SCRIPT_AUTHOR; namespace.State = getStateSnapshotInternal(); namespace.Config = copyMap(State.config); namespace.ModuleURLs = copyMap(State.moduleURLs)
		namespace.Diagnostics = getDiagnosticsSnapshot(); _G.Exodus = namespace
	end)
	NamespaceUpdating = false
end
local function setLifecyclePhaseInternal(phase)
	if type(phase) ~= "string" or phase == "" then return false end
	if State.lifecycle.phase == phase then return true end
	State.lifecycle.phase = phase; return true
end
local function recordTransitionInternal(source, fromState, toState, reason)
	local transition = {
		source = tostring(source or "Unknown"),
		from = tostring(fromState or ""),
		to = tostring(toState or ""),
		reason = tostring(reason or ""),
		at = os.clock(),
	}

	State.diagnostics.lastTransition = transition; State.diagnostics.lastTransitionAt = transition.at; appendLimited(State.diagnostics.transitions, transition, T.MAX_DIAGNOSTIC_ENTRIES)
	updateNamespace()
end
local function ensureDataFolder()
	if type(makefolder) ~= "function" or type(isfolder) ~= "function" then return false, "APIs de pasta do executor indisponíveis" end
	local ok, exists = pcall(isfolder, T.DATA_FOLDER)
	if not ok then return false, tostring(exists) end
	if exists then return true, T.DATA_FOLDER end
	local created, err = pcall(makefolder, T.DATA_FOLDER)
	if not created then return false, tostring(err or ("falha ao criar " .. T.DATA_FOLDER)) end
	return true, T.DATA_FOLDER
end
function Utils.ensureDataFolder() return ensureDataFolder() end
function Utils.start()
	local previousPhase = State.lifecycle.phase; State.lifecycle.generation += 1; State.lifecycle.startedAt = os.clock(); State.lifecycle.stoppedAt = 0
	State.active = true; setLifecyclePhaseInternal("starting"); recordTransitionInternal("Utils", previousPhase, "starting", "start")
	if _G.ExodusOnBurst == nil then _G.ExodusOnBurst = function() end end
	updateNamespace(); return Utils.getStateSnapshot()
end
function Utils.stop()
	local previousPhase = State.lifecycle.phase; State.active = false; State.manualSpamActive = false; State.autoSpamActive = false
	State.lifecycle.stoppedAt = os.clock()
	_G.ExodusOnBurst = function() end
	if type(_G.ExodusUICleanup) == "function" then safeCall(_G.ExodusUICleanup) end

	-- Connections
	disconnectAll(State.characterConnections); disconnectAll(State.connections); State.config = {}; State.moduleURLs = {}
	DiagnosticsModules = {}
	if type(_G.Exodus) == "table" then
		_G.Exodus.Started = false; _G.Exodus.UIReady = false; _G.Exodus.Runtime = nil; _G.Exodus.UI = nil
		if type(_G.Exodus.RemoteHooks) == "table" then _G.Exodus.RemoteHooks.register = nil end
		if type(_G.Exodus.AutoParryHitbox) == "table" then
			local hitbox = _G.Exodus.AutoParryHitbox
			if hitbox.connection then disconnect(hitbox.connection) end
			hitbox.connection = nil; hitbox.handler = nil
		end
	end
	setLifecyclePhaseInternal("stopped"); recordTransitionInternal("Utils", previousPhase, "stopped", "stop"); updateNamespace(); return true
end
function Utils.isActive() return State.active == true end
function Utils.getStateSnapshot() return getStateSnapshotInternal() end
function Utils.getConfig() return copyMap(State.config) end
function Utils.getConfigSnapshot() return copyMap(State.config) end
function Utils.getModuleURLsSnapshot() return copyMap(State.moduleURLs) end
function Utils.getLifecycle() return getLifecycleSnapshot() end
function Utils.getDiagnostics() return getDiagnosticsSnapshot() end
function Utils.setDiagnosticsModules(modules)
	if type(modules) ~= "table" then return false end
	DiagnosticsModules = copyMap(modules); updateNamespace(); return true
end
function Utils.setLifecyclePhase(phase)
	if type(phase) ~= "string" or phase == "" then return false end
	local previous = State.lifecycle.phase
	if previous == phase then return true end
	setLifecyclePhaseInternal(phase); recordTransitionInternal("Lifecycle", previous, phase, "phase_change"); return true
end
function Utils.recordTransition(source, fromState, toState, reason)
	recordTransitionInternal(source, fromState, toState, reason)
end
function Utils.isManualSpamActive() return State.manualSpamActive == true end
function Utils.isAutoSpamActive() return State.autoSpamActive == true end
function Utils.isSpamActive() return State.manualSpamActive == true or State.autoSpamActive == true end
function Utils.setAutoSpamActive(value)
	local nextValue = value == true
	if State.autoSpamActive == nextValue then return false end
	local previous = State.autoSpamActive; State.autoSpamActive = nextValue
	recordTransitionInternal(
		"AutoClash",
		previous and "active" or "inactive",
		nextValue and "active" or "inactive",
		"automatic_toggle"
	)
	return true
end
function Utils.setManualSpamActive(value)
	local nextValue = value == true
	if State.manualSpamActive == nextValue then return false end
	local previous = State.manualSpamActive; State.manualSpamActive = nextValue
	recordTransitionInternal(
		"Spam",
		previous and "active" or "inactive",
		nextValue and "active" or "inactive",
		"manual_toggle"
	)
	return true
end
function Utils.isFiniteNumber(value)
	return type(value) == "number" and value == value and value < math.huge and value > -math.huge
end
function Utils.isNonNegativeFiniteNumber(value) return Utils.isFiniteNumber(value) and value >= 0 end
function Utils.normalizeSpamRate(value, fallback)
	local rate = tonumber(value)
	if not Utils.isFiniteNumber(rate) then rate = tonumber(fallback) end
	if not Utils.isFiniteNumber(rate) then rate = T.SPAM_RATE_MIN end
	return math.clamp(rate, T.SPAM_RATE_MIN, T.SPAM_RATE_MAX)
end
function Utils.setConfig(config)
	if type(config) ~= "table" then return false end
	local normalized
	local reason
	if ConfigModule and type(ConfigModule.normalizePatch) == "function" then
		local ok, result, resultReason = pcall(ConfigModule.normalizePatch, config)
		if not ok then return false end
		normalized = result; reason = resultReason
	else
		normalized = copyMap(config)
	end
	if type(normalized) ~= "table" then return false end
	for key, value in pairs(normalized) do
		State.config[key] = value
	end
	updateNamespace(); return true
end
function Utils.setConfigModule(module)
	if type(module) ~= "table" then return false end
	if type(module.normalizePatch) ~= "function" or type(module.validate) ~= "function" then return false end
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
_G.ExodusStop = Utils.stop
Utils.__contract = {
	requires = {},
}

return Utils
