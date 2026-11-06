-- [[ autodark ]]

local AutoDark = {}

local utils, gameInfo
local connections, watched = {}, {}
local epoch, sealedCount = 0, 0
local EVENT = 2.4141700243704228e76
local function track(connection)
	connections[#connections + 1] = connection; utils.trackGlobal(connection)
end
local function clear()
	epoch += 1
	for _, record in pairs(watched) do
		if utils then utils.untrackGlobal(record.connection) end
		record.connection:Disconnect()
	end
	for i = #connections, 1, -1 do
		local connection = connections[i]
		if utils then utils.untrackGlobal(connection) end
		connection:Disconnect(); connections[i] = nil
	end
	table.clear(watched); sealedCount = 0
end
function AutoDark.sync()
	clear()
	if not utils or not gameInfo or not utils.isActive() or utils.getConfigValue("AutoDark") ~= true then return true end
	local players, player, runService = utils.getPlayers(), utils.getLocalPlayer(), utils.getRunService()
	if not players or not player or not runService or not runService.Heartbeat then return false, "Players ou Heartbeat indisponível" end
	local current = epoch
	local function update(other)
		local record = watched[other]
		if not record then return end
		local sealed = other:GetAttribute("DarkSealed") == true
		if sealed ~= record.sealed then record.sealed = sealed; sealedCount += sealed and 1 or -1 end
	end
	local function add(other)
		if current ~= epoch or not utils or other == player or watched[other] then return end
		local record = { sealed = false }; watched[other] = record
		record.connection = other:GetAttributeChangedSignal("DarkSealed"):Connect(function()
			if current == epoch then update(other) end
		end)
		utils.trackGlobal(record.connection); update(other)
	end
	local function remove(other)
		if current ~= epoch or not utils then return end
		local record = watched[other]
		if not record then return end
		watched[other] = nil
		if record.sealed then sealedCount -= 1 end
		utils.untrackGlobal(record.connection); record.connection:Disconnect()
	end
	track(players.PlayerAdded:Connect(add)); track(players.PlayerRemoving:Connect(remove))
	for _, other in ipairs(players:GetPlayers()) do
		add(other)
	end
	local busy, missing, lastError, lastErrorAt = false, false, nil, 0
	track(runService.Heartbeat:Connect(function()
		if busy or current ~= epoch or not utils.isActive() or utils.getConfigValue("AutoDark") ~= true or sealedCount > 0 then return end
		busy = true
		local ok, err = pcall(function()
			local ability = gameInfo.getDarkSealAbility()
			if current ~= epoch or not utils.isActive() or utils.getConfigValue("AutoDark") ~= true then return end
			if not ability then
				if not missing then utils.recordError("AutoDark", "Dark Seal não está equipada ou ainda não carregou"); missing = true end
				return
			end
			missing = false; local camera = utils.getWorkspace().CurrentCamera
			if camera and sealedCount == 0 then ability:SendEvent(EVENT, camera.CFrame) end
		end)
		busy = false
		if not ok and current == epoch then
			local now = os.clock()
			if err ~= lastError or now - lastErrorAt >= 5 then lastError, lastErrorAt = err, now; utils.recordError("AutoDark", tostring(err)) end
		elseif ok then
			lastError = nil
		end
	end))
	return true
end
function AutoDark.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes: Utils ou GameInfo" end
	AutoDark.teardown(); utils, gameInfo = deps.Utils, deps.GameInfo; return AutoDark.sync()
end
function AutoDark.teardown()
	clear(); utils, gameInfo = nil, nil
end
AutoDark.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = {
		Utils = { "getConfigValue", "getWorkspace", "getPlayers", "getLocalPlayer", "getRunService", "trackGlobal", "untrackGlobal", "isActive", "recordError" },
		GameInfo = { "getDarkSealAbility" },
	},

	provides = { "setup", "sync", "teardown" },
}

return AutoDark
