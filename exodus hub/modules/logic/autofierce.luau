-- [[ autofierce ]]

-- dependencies
local AutoFierce = {}
local utils, gameInfo, remote

-- tuning
local T = {
	SIGNAL_RETRY = 0.5,
	NOOB_WINDOW_MAX = 0.15,
}

-- state
local connections = {}
local cooldownConnection, parriedConnection
local pending, nextSignalAt

-- helpers
local function track(connection)
	connections[#connections + 1] = connection; utils.trackGlobal(connection); return connection
end
local function enabled() return utils and utils.isActive() and utils.getConfigValue("AutoFierce") == true and gameInfo.areAbilitiesEnabled() end
local function targeted()
	local player = utils.getLocalPlayer(); return player ~= nil and gameInfo.getTargetId() == player.UserId
end

-- tracking
local function onCooldown(abilityId, eventId, value)
	local kind, duration = gameInfo.decodeDeflectServerEvent(abilityId, eventId, value)
	if not kind then return end
	if kind ~= "started" then pending = nil; return end
	pending = nil
	if not enabled() then return end
	local window = gameInfo.getDeflectWindow()
	if type(window) ~= "number" or window ~= window or window <= 0 then return end
	local now = os.clock(); pending = { deadline = now + window + T.NOOB_WINDOW_MAX, cooldownEnd = now + duration }
end
local function onParried() pending = nil end
local function connectSignals(now)
	if now < nextSignalAt then return end
	nextSignalAt = now + T.SIGNAL_RETRY; local signals = gameInfo.getDeflectServerEvents()
	if not signals or not signals.cooldown or not signals.parried then return end
	if not cooldownConnection then cooldownConnection = track(signals.cooldown:Connect(onCooldown)) end
	if not parriedConnection then parriedConnection = track(signals.parried:Connect(onParried)) end
end

-- activation
local function update()
	local now = os.clock()
	if not cooldownConnection or not parriedConnection then connectSignals(now) end
	if not enabled() then pending = nil; return end
	local attempt = pending
	if not attempt then return end
	if now >= attempt.cooldownEnd then pending = nil; return end
	if now < attempt.deadline or not targeted() then return end
	pending = nil
	remote.fireFierce(function() return enabled() and targeted() and os.clock() < attempt.cooldownEnd end)
end

-- lifecycle
function AutoFierce.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" or type(deps.Remote) ~= "table" then return false, "dependências ausentes: Utils, GameInfo ou Remote" end
	AutoFierce.teardown(); utils, gameInfo, remote = deps.Utils, deps.GameInfo, deps.Remote; pending, nextSignalAt = nil, 0; local runService = utils.getRunService()
	if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
	track(utils.observeConfig(function()
		if not enabled() then pending = nil end
	end))
	track(runService.Heartbeat:Connect(update)); return true
end
function AutoFierce.teardown()
	for _, connection in ipairs(connections) do
		if utils then utils.untrackGlobal(connection) end
		connection:Disconnect()
	end
	connections = {}; cooldownConnection, parriedConnection, pending, nextSignalAt = nil, nil, nil, nil; utils, gameInfo, remote = nil, nil, nil
end

-- contract
AutoFierce.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Remote = "remote" },
	requiresMethods = {
		Utils = { "getConfigValue", "getLocalPlayer", "getRunService", "isActive", "observeConfig", "trackGlobal", "untrackGlobal" },
		GameInfo = { "areAbilitiesEnabled", "getDeflectServerEvents", "decodeDeflectServerEvent", "getDeflectWindow", "getTargetId" },
		Remote = { "fireFierce" },
	},

	provides = { "setup", "teardown" },
}

return AutoFierce
