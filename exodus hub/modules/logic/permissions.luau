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

-- policy-table
local POLICIES = {
	permissions = { provide = allow("validate wrap policy"), consume = {} },
	config = { provide = allow("register defaults validatePatch normalizePatch validate getRegistry"), consume = {} },
	uiconfig = { provide = allow(""), consume = {}, data = allow("panelToggles panelComponents") },
	utils = {
		provide = allow(
			"observeSpam observeConfig ensureDataFolder createClashLog appendClashLog start stop isActive getStateSnapshot getConfig getConfigValue getConfigSnapshot getModuleURLsSnapshot getLifecycle getDiagnostics setDiagnosticsModules setLifecyclePhase recordTransition recordError isManualSpamActive isAutoSpamActive isSpamActive setManualSpamActive setAutoSpamActive stopAllSpam isFiniteNumber isNonNegativeFiniteNumber normalizeSpamRate setConfig loadConfig setConfigModule setModuleURLs trackGlobal untrackGlobal trackCharacter untrackCharacter disconnectCharacterConnections getPlayers getReplicatedStorage getRunService getWorkspace getLocalPlayer now name version apiVersion author"
		),
		consume = {},
	},
	gameinfo = {
		provide = allow(
			"bindBallSync startMaintenance stopMaintenance setup getBall getBallPosition getBallVelocity getRootPosition getPlayerDistance getPlayerMotion getHaunterEvent getLocalPing areAbilitiesEnabled observeAbilityMode getDeflectRange getDeflectGeometry isBallWithinDeflectRadius getBallFrozen getDeflectAbility getLastDeflectPressAt getAutoSpamDelay getDashAbility isPlayerDashing getFierceDeflectAbility getDarkSealAbility getDeflectServerEvents decodeDeflectServerEvent getHeldDeflectServerCooldown getDeflectCooldownState getSyncData getSyncSequence applyPacket decodeBallPacket getTargetId getSnapshot getSnapshotAt isSnapshotValid applySync installBallWatcher getBallSpeedLimits getDeflectWindow getManifestRemote getClashContext getStatus"
		),
		consume = {
			utils = allow("apiVersion getPlayers getReplicatedStorage getWorkspace now recordError trackGlobal untrackGlobal"),
		},
	},
	remote = {
		provide = allow("setup fireParry fireDark fireFierce fireDash"),
		consume = { utils = allow(""), gameinfo = allow("getDeflectAbility getDarkSealAbility getFierceDeflectAbility getDashAbility") },
	},
	autoparry = {
		provide = allow(
			"setup bindCharacter fire beginFierce cancelFierce resetState detachCharacter teardown onBallSync getTargetStatus getTiming getRadius getPressure getStatus"
		),
		consume = {
			utils = allow(
				"apiVersion getConfigValue getLocalPlayer getRunService isActive isSpamActive recordError recordTransition trackCharacter untrackCharacter"
			),
			gameinfo = allow(
				"getBallPosition getBallSpeedLimits getBallVelocity getDeflectCooldownState getDeflectRange getDeflectGeometry getDeflectWindow getLocalPing getRootPosition getSnapshotAt getSyncData getSyncSequence getTargetId isSnapshotValid"
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
				"apiVersion createClashLog appendClashLog getConfig getConfigValue getLocalPlayer getPlayers getRunService isActive isManualSpamActive setManualSpamActive now recordError recordTransition setAutoSpamActive trackCharacter untrackCharacter"
			),
			gameinfo = allow(
				"areAbilitiesEnabled getBallSpeedLimits getBallFrozen getDeflectGeometry getDeflectRange getLocalPing getPlayerDistance getPlayerMotion getHaunterEvent getClashContext getDeflectAbility getDeflectWindow getManifestRemote getSnapshot getSnapshotAt getSyncData getSyncSequence getTargetId isSnapshotValid"
			),
		},
	},
	spam = {
		provide = allow("setup resetState teardown getStatus"),
		consume = {
			utils = allow(
				"apiVersion getConfig isActive isAutoSpamActive isManualSpamActive observeConfig observeSpam recordError recordTransition trackGlobal untrackGlobal"
			),
			remote = allow("fireParry"),
			gameinfo = allow("getAutoSpamDelay"),
		},
	},
	autodark = {
		provide = allow("sync setup teardown"),
		consume = {
			utils = allow("getConfigValue getRunService getWorkspace trackGlobal untrackGlobal"),
			remote = allow("fireDark"),
			gameinfo = allow("areAbilitiesEnabled"),
		},
	},
	autofierce = {
		provide = allow("setup teardown"),
		consume = {
			utils = allow("getConfigValue getLocalPlayer getRunService isActive observeConfig trackGlobal untrackGlobal"),
			gameinfo = allow(
				"areAbilitiesEnabled getDeflectServerEvents getLastDeflectPressAt getDeflectWindow getLocalPing getSnapshotAt isSnapshotValid getBallFrozen isBallWithinDeflectRadius"
			),
			autoparry = allow("beginFierce cancelFierce"),
			remote = allow("fireFierce"),
		},
	},
	movement = {
		provide = allow("upDash dashToward setup teardown"),
		consume = {
			utils = allow("isActive"),
			gameinfo = allow("getDashAbility areAbilitiesEnabled"),
			remote = allow("fireDash"),
		},
	},
	autojump = {
		provide = allow("setup sync teardown"),
		consume = { utils = allow("getConfigValue getLocalPlayer getRunService isActive trackGlobal untrackGlobal") },
	},
	camera = {
		provide = allow("setup teardown"),
		consume = { utils = allow("getConfigValue getLocalPlayer isActive") },
	},
	autodash = {
		provide = allow("setup bindCharacter detachCharacter teardown"),
		consume = {
			utils = allow("getPlayers getLocalPlayer getRunService getConfigValue isActive now trackCharacter untrackCharacter"),
			gameinfo = allow("areAbilitiesEnabled getClashContext"),
			dash = allow("setHandler tick"),
			movement = allow("upDash dashToward"),
			autospam = allow("getActivationContext"),
		},
	},
	dash = {
		provide = allow("setup setHandler tick resetState teardown getStatus"),
		consume = {
			utils = allow("apiVersion getPlayers now trackGlobal untrackGlobal"),
			gameinfo = allow("isPlayerDashing"),
		},
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
			autodash = allow("bindCharacter detachCharacter"),
		},
	},
	ui = {
		provide = allow("setup"),
		consume = {
			utils = allow(
				"apiVersion getConfig getConfigValue getLocalPlayer isActive isManualSpamActive name normalizeSpamRate observeConfig observeSpam recordError setConfig setManualSpamActive stop version author"
			),
			uiconfig = allow("panelToggles panelComponents"),
			gameinfo = allow("areAbilitiesEnabled observeAbilityMode getSnapshotAt isSnapshotValid"),
			autospam = allow("getStatus"),
		},
	},
}

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
local function wrap(consumer, source, provider)
	local entry = policy(consumer); local allowed = entry.consume[source]
	if not allowed then deny(consumer, "api.consume." .. source) end
	local exposed = policy(source); local view = {}
	for method in pairs(allowed) do
		if not exposed.provide[method] and not (exposed.data and exposed.data[method]) then deny(source, "api.expose." .. method) end
		local value = provider[method]
		if value == nil then error(("Permissions: API ausente: %s.%s"):format(source, method), 2) end
		view[method] = exposed.data and exposed.data[method] and readonly(value) or value
	end
	local metatable = {
		__index = function(_, method) deny(consumer, "api.consume." .. source .. "." .. tostring(method)) end,
		__newindex = function(_, method) deny(consumer, "api.write." .. source .. "." .. tostring(method)) end,
	}

	setmetatable(view, metatable); table.freeze(view); metatable.__metatable = "locked"; table.freeze(metatable); return view
end

-- api
Permissions.validate = validate
Permissions.wrap = wrap
Permissions.policy = function(name)
	local entry = policy(name); local result = { provides = {}, consumes = {} }
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
	table.sort(result.provides); return result
end

-- contract
Permissions.__contract = {
	provides = { "validate", "wrap", "policy" },
	requires = {},
}

return Permissions
