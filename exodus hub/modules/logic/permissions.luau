-- [[ permissions ]]

-- policies
local Permissions = {}
local function allow(names)
	local items = {}
	for name in string.gmatch(names or "", "%S+") do
		items[name] = true
	end
	return items
end
local POLICIES = {
	permissions = { provide = allow("validate wrap environment policy"), consume = {} },
	config = { provide = allow("register defaults validatePatch normalizePatch validate getRegistry"), consume = {} },
	uiconfig = { provide = allow(""), consume = {}, data = allow("panelToggles panelComponents") },
	utils = {
		provide = allow(
			"observeSpam observeConfig ensureDataFolder start stop isActive getStateSnapshot getConfig getConfigValue getConfigSnapshot getModuleURLsSnapshot getLifecycle getDiagnostics setDiagnosticsModules setLifecyclePhase recordTransition recordError isManualSpamActive isAutoSpamActive isSpamActive setManualSpamActive setAutoSpamActive stopAllSpam isFiniteNumber isNonNegativeFiniteNumber normalizeSpamRate setConfig loadConfig setConfigModule setModuleURLs trackGlobal untrackGlobal trackCharacter untrackCharacter disconnectCharacterConnections getPlayers getReplicatedStorage getRunService getWorkspace getLocalPlayer now name version apiVersion author"
		),
		consume = {},
		services = allow("Players ReplicatedStorage RunService Workspace HttpService"),
		globalRead = allow("Exodus ExodusOnBurst ExodusUICleanup"),
		globalWrite = allow("Exodus ExodusStop ExodusOnBurst"),
		filesystem = true,
	},
	gameinfo = {
		provide = allow(
			"bindBallSync startMaintenance stopMaintenance setup getBall getBallPosition getBallVelocity getRootPosition getLocalPing getDeflectRange getDeflectAbility getDashAbility getFierceDeflectAbility getDarkSealAbility getDeflectServerEvents decodeDeflectServerEvent getHeldDeflectServerCooldown getDeflectCooldownState getSyncData getSyncSequence applyPacket decodeBallPacket getTargetId getSnapshot getSnapshotAt isSnapshotValid applySync installBallWatcher getBallSpeedLimits getDeflectWindow getManifestRemote getClashContext getStatus"
		),
		consume = {
			utils = allow("apiVersion getPlayers getReplicatedStorage getWorkspace now recordError trackGlobal untrackGlobal"),
		},
		imports = true,
	},
	remote = {
		provide = allow("setup fireParry fireDark fireFierce fireDash"),
		consume = { utils = allow(""), gameinfo = allow("getDeflectAbility getDarkSealAbility getFierceDeflectAbility getDashAbility") },
	},
	autoparry = {
		provide = allow("setup bindCharacter fire resetState detachCharacter teardown onBallSync getTargetStatus getTiming getRadius getPressure getStatus"),
		consume = {
			utils = allow(
				"apiVersion getConfigValue getLocalPlayer getRunService isActive isSpamActive recordError recordTransition trackCharacter untrackCharacter"
			),
			gameinfo = allow(
				"getBallPosition getBallSpeedLimits getBallVelocity getDeflectCooldownState getDeflectRange getDeflectWindow getLocalPing getRootPosition getSnapshotAt getSyncData getSyncSequence getTargetId isSnapshotValid"
			),
			remote = allow("fireParry"),
		},
	},
	autospam = {
		provide = allow(
			"setup bindCharacter detachCharacter teardown onBallSync isActive getPullEvent stopSpam getTargetSwitch getActivationContext getDashData getStatus"
		),
		consume = {
			utils = allow(
				"apiVersion getConfig getConfigValue getLocalPlayer getPlayers getRunService isActive now recordError recordTransition setAutoSpamActive trackCharacter untrackCharacter"
			),
			gameinfo = allow(
				"getBallSpeedLimits getClashContext getDeflectAbility getDeflectWindow getLocalPing getManifestRemote getSnapshot getSnapshotAt getSyncData getSyncSequence getTargetId isSnapshotValid"
			),
			autoparry = allow("getPressure getRadius getStatus"),
			dash = allow("setHandler tick"),
		},
		objectRead = { getDeflectAbility = allow("DeflectDistance"), getManifestRemote = allow("OnClientEvent") },
	},
	spam = {
		provide = allow("setup resetState teardown getStatus"),
		consume = {
			utils = allow(
				"apiVersion getConfig isActive isAutoSpamActive isManualSpamActive observeConfig observeSpam recordError recordTransition trackGlobal untrackGlobal"
			),
			remote = allow("fireParry"),
		},
	},
	autodark = {
		provide = allow("sync setup teardown"),
		consume = {
			utils = allow("getConfigValue getRunService getWorkspace trackGlobal untrackGlobal"),
			remote = allow("fireDark"),
		},
	},
	movement = {
		provide = allow("syncJump upDash setup teardown"),
		consume = {
			utils = allow("getConfigValue getLocalPlayer getRunService isActive trackGlobal untrackGlobal"),
			gameinfo = allow("getDashAbility"),
			remote = allow("fireDash"),
		},
		objectRead = { getDashAbility = allow("Dashing") },
		objectWrite = { getDashAbility = allow("MoveDir") },
	},
	dash = {
		provide = allow("setup setHandler tick resetState teardown getStatus"),
		consume = {
			utils = allow("apiVersion getPlayers now"),
			gameinfo = allow("getDashAbility"),
		},
		objectRead = { getDashAbility = allow("Dashing") },
	},
	character = {
		provide = allow("setup teardown getStatus"),
		consume = {
			utils = allow(
				"apiVersion disconnectCharacterConnections getLocalPlayer isActive recordError recordTransition setAutoSpamActive setManualSpamActive trackCharacter trackGlobal untrackGlobal"
			),
			spam = allow("resetState"),
			autoparry = allow("bindCharacter detachCharacter"),
			autospam = allow("bindCharacter detachCharacter"),
		},
	},
	ui = {
		provide = allow("setup"),
		consume = {
			utils = allow(
				"apiVersion getConfig getConfigValue getLocalPlayer isActive isManualSpamActive name normalizeSpamRate observeConfig observeSpam recordError setConfig setManualSpamActive stop version author"
			),
			uiconfig = allow("panelToggles panelComponents"),
		},
		services = allow("UserInputService TweenService CoreGui VirtualUser VirtualInputManager ReplicatedStorage"),
		globalRead = allow("ExodusUICleanup"),
		globalWrite = allow("ExodusUICleanup"),
		workspace = true,
		imports = true,
	},
}

local GLOBALS = allow(
	"assert error pcall xpcall print warn type typeof tostring tonumber pairs ipairs next select unpack setmetatable getmetatable rawequal math table string utf8 coroutine os task bit32 buffer Enum Vector2 Vector3 CFrame UDim UDim2 Color3 ColorSequence ColorSequenceKeypoint NumberSequence NumberSequenceKeypoint NumberRange Rect RaycastParams OverlapParams PhysicalProperties TweenInfo Instance Font BrickColor DateTime Random"
)

-- validation
local function policy(name)
	local entry = POLICIES[name]
	if not entry then error("Permissions: módulo não registrado: " .. tostring(name), 2) end
	return entry
end
local function deny(name, action) error(("Permissão negada: %s -> %s"):format(name, action), 3) end
local function validate(name, module)
	local entry = policy(name)
	if type(module) ~= "table" then error("Permissions: retorno inválido de " .. name, 2) end
	local contract = module.__contract
	if type(contract) ~= "table" or type(contract.provides) ~= "table" then error(name .. ": __contract.provides ausente", 2) end
	for key, value in pairs(module) do
		if type(value) == "function" and not entry.provide[key] then deny(name, "api.expose." .. tostring(key)) end
	end
	for _, method in ipairs(contract.provides) do
		if not entry.provide[method] then deny(name, "api.expose." .. tostring(method)) end
		if type(module[method]) ~= "function" then error(name .. ": API declarada ausente: " .. method, 2) end
	end
	for dependencyName, source in pairs(contract.requires or {}) do
		if not entry.consume[source] then deny(name, "api.consume." .. tostring(source)) end
		local requirements = contract.requiresMethods and contract.requiresMethods[dependencyName]
		for _, method in ipairs(requirements or {}) do
			if not entry.consume[source][method] then deny(name, "api.consume." .. source .. "." .. method) end
		end
	end
	return true
end

-- capabilities
local function readonly(value)
	if type(value) ~= "table" then return value end
	local copied = {}
	for key, item in pairs(value) do
		copied[key] = readonly(item)
	end
	return table.freeze(copied)
end
local function objectView(consumer, method, getter, readable, writable)
	local previous, cached
	return function(...)
		local object = getter(...)
		if object == nil then return nil end
		if previous == object then return cached end
		previous = object
		cached = setmetatable({}, {
			__index = function(_, field)
				if not readable[field] then deny(consumer, "game.data.read." .. method .. "." .. tostring(field)) end
				return object[field]
			end,
			__newindex = function(_, field, value)
				if not (writable and writable[field]) then deny(consumer, "game.data.write." .. method .. "." .. tostring(field)) end
				object[field] = value
			end,
			__metatable = "locked",
		})
		return cached
	end
end
local function wrap(consumer, source, provider)
	local entry = policy(consumer); local allowed = entry.consume[source]
	if not allowed then deny(consumer, "api.consume." .. source) end
	local exposed = policy(source); local view = {}
	for method in pairs(allowed) do
		if not exposed.provide[method] and not (exposed.data and exposed.data[method]) then deny(source, "api.expose." .. method) end
		local value = provider[method]
		if value == nil then error(("Permissions: API ausente: %s.%s"):format(source, method), 2) end
		if exposed.data and exposed.data[method] then view[method] = readonly(value) elseif source == "gameinfo" and entry.objectRead and entry.objectRead[method] then view[method] = objectView(consumer, method, value, entry.objectRead[method], entry.objectWrite and entry.objectWrite[method]) else view[method] = value end
	end
	setmetatable(view, {
		__index = function(_, method) deny(consumer, "api.consume." .. source .. "." .. tostring(method)) end,
		__newindex = function(_, method) deny(consumer, "api.write." .. source .. "." .. tostring(method)) end,
		__metatable = "locked",
	})
	return table.freeze(view)
end
local function environment(name, base)
	local entry = policy(name); local env = {}
	for global in pairs(GLOBALS) do
		if base[global] ~= nil then env[global] = base[global] end
	end
	local optionalGlobals = entry.filesystem and allow("makefolder isfolder isfile readfile writefile") or {}
	for key in pairs(optionalGlobals) do env[key] = base[key] end
	if entry.imports then env.require = base.require end
	if entry.services then
		local proxy = {}
		proxy.GetService = function(_, service)
			if not entry.services[service] then deny(name, "game.service." .. tostring(service)) end
			return game:GetService(service)
		end
		env.game = table.freeze(setmetatable(proxy, {
			__index = function(_, key) deny(name, "game." .. tostring(key)) end,
			__newindex = function(_, key) deny(name, "game." .. tostring(key)) end,
			__metatable = "locked",
		}))
	end
	if entry.workspace then env.workspace = workspace end
	if entry.globalRead or entry.globalWrite then
		env._G = setmetatable({}, {
			__index = function(_, key)
				if not (entry.globalRead and entry.globalRead[key]) then deny(name, "global.read." .. tostring(key)) end
				return _G[key]
			end,
			__newindex = function(_, key, value)
				if not (entry.globalWrite and entry.globalWrite[key]) then deny(name, "global.write." .. tostring(key)) end
				_G[key] = value
			end,
			__metatable = "locked",
		})
	end
	return setmetatable(env, {
		__index = function(_, key)
			if optionalGlobals[key] then return nil end
			deny(name, "global.read." .. tostring(key))
		end,
		__newindex = function(_, key) deny(name, "global.write." .. tostring(key)) end,
		__metatable = "locked",
	})
end

-- api
Permissions.validate = validate
Permissions.wrap = wrap
Permissions.environment = environment
Permissions.policy = function(name)
	local entry = policy(name); local result = { provides = {}, consumes = {}, services = {} }
	for method in pairs(entry.provide) do
		result.provides[#result.provides + 1] = method
	end
	for source, methods in pairs(entry.consume) do
		local copy = {}
		for method in pairs(methods) do
			copy[#copy + 1] = method
		end
		table.sort(copy); result.consumes[source] = copy
	end
	for service in pairs(entry.services or {}) do
		result.services[#result.services + 1] = service
	end
	table.sort(result.provides); table.sort(result.services); return result
end

-- contract
Permissions.__contract = {
	provides = { "validate", "wrap", "environment", "policy" },
	requires = {},
}

return Permissions
