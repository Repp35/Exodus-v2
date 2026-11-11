-- [[ autofierce ]]

-- dependencies
local AutoFierce = {}
local utils, gameInfo, remote, autoParry

-- CONFIGURACAO DESTE MODULO (edite os valores abaixo)
local CONFIG = {
	SIGNAL_RETRY = 0.5,
	SYNC_MAX_AGE = 0.25,
	NOOB_WINDOW_EXTRA = 0.15,
}

-- state
local connections = {}
local parriedConnection
local nextSignalAt, graceHandled, parryGeneration, lastParriedAt, lastFiercePressAt, localUserId

-- helpers
local function track(connection)
	connections[#connections + 1] = connection; utils.trackGlobal(connection); return connection
end
local function enabled() return utils and utils.isActive() and utils.getConfigValue("AutoFierce") == true and gameInfo.areAbilitiesEnabled() end

-- tracking
local function onParried()
	graceHandled = true; parryGeneration += 1; lastParriedAt = os.clock()
end
local function connectSignals(now)
	if now < nextSignalAt or parriedConnection then return end
	nextSignalAt = now + CONFIG.SIGNAL_RETRY; local signals = gameInfo.getDeflectServerEvents()
	if signals and signals.parried then parriedConnection = track(signals.parried:Connect(onParried)) end
end
local function graceDanger(now)
	local snapshot = gameInfo.getSnapshotAt(now)
	if not gameInfo.isSnapshotValid(snapshot) or snapshot.teleported then return false, nil end
	local fresh = type(snapshot.syncAt) == "number" and snapshot.syncAt > 0 and now >= snapshot.syncAt and now - snapshot.syncAt <= CONFIG.SYNC_MAX_AGE
	if not fresh then return false, nil end
	local grace = snapshot.grace == true; local danger = grace and localUserId ~= nil and snapshot.targetId == localUserId and gameInfo.getBallFrozen() ~= true; return danger, grace
end
local function deflectPending(now)
	local pressedAt = gameInfo.getLastDeflectPressAt()
	if type(pressedAt) ~= "number" or pressedAt ~= pressedAt then return true end
	if pressedAt <= 0 or pressedAt <= lastParriedAt or pressedAt <= lastFiercePressAt then return true end
	if pressedAt > now then return true end
	local window = gameInfo.getDeflectWindow()
	if type(window) ~= "number" or window ~= window or window <= 0 then return true end
	local ping = gameInfo.getLocalPing()
	if type(ping) ~= "number" or ping ~= ping or ping < 0 then ping = 0 end
	return now - pressedAt <= window + CONFIG.NOOB_WINDOW_EXTRA + 2 * ping
end

-- activation
local function update()
	local now = os.clock()
	if not enabled() then graceHandled = false; return end
	if not parriedConnection then connectSignals(now) end
	if not parriedConnection then return end
	local danger, grace = graceDanger(now)
	if grace == nil then return end
	if not grace then graceHandled = false; return end
	if not danger or graceHandled or deflectPending(now) then return end
	graceHandled = true; local generation = parryGeneration; local pressedAt = gameInfo.getLastDeflectPressAt()
	local token
	local ok, sent = pcall(function()
		return remote.fireFierce(function()
			if not enabled() or parryGeneration ~= generation or deflectPending(os.clock()) then return false end
			local stillDanger = graceDanger(os.clock())
			if not stillDanger then return false end
			token = autoParry.beginFierce(); return true
		end)
	end)
	if ok and sent == true then lastFiercePressAt = pressedAt end
	if not ok or sent ~= true then
		autoParry.cancelFierce(token)
		if parryGeneration == generation then graceHandled = false end
	end
	if not ok then error(sent, 0) end
end

-- lifecycle
function AutoFierce.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.GameInfo) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.AutoParry) ~= "table"
	then
		return false, "dependências ausentes: Utils, GameInfo ou Remote"
	end
	AutoFierce.teardown(); utils, gameInfo, remote, autoParry = deps.Utils, deps.GameInfo, deps.Remote, deps.AutoParry; nextSignalAt, graceHandled, parryGeneration, lastParriedAt, lastFiercePressAt = 0, false, 0, 0, 0; local player = utils.getLocalPlayer(); localUserId = player and player.UserId; local runService = utils.getRunService()
	if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
	track(utils.observeConfig(function()
		if not enabled() then graceHandled = false end
	end))
	track(runService.Heartbeat:Connect(update)); return true
end
function AutoFierce.teardown()
	for _, connection in ipairs(connections) do
		if utils then utils.untrackGlobal(connection) end
		connection:Disconnect()
	end
	connections = {}; parriedConnection, nextSignalAt, graceHandled, parryGeneration, lastParriedAt, lastFiercePressAt, localUserId = nil, nil, nil, nil, nil, nil, nil; utils, gameInfo, remote, autoParry = nil, nil, nil, nil
end

-- contract
AutoFierce.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo", Remote = "remote", AutoParry = "autoparry" },
	requiresMethods = {
		Utils = { "getConfigValue", "getLocalPlayer", "getRunService", "isActive", "observeConfig", "trackGlobal", "untrackGlobal" },
		GameInfo = {
			"areAbilitiesEnabled",
			"getDeflectServerEvents",
			"getLastDeflectPressAt",
			"getDeflectWindow",
			"getLocalPing",
			"getSnapshotAt",
			"isSnapshotValid",
			"getBallFrozen",
		},
		AutoParry = { "beginFierce", "cancelFierce" },
		Remote = { "fireFierce" },
	},

	provides = { "setup", "teardown" },
}

return AutoFierce
