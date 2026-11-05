-- [[ autodark ]]

local AutoDark = {}

local Utils, GameInfo
local generation = 0
local connections = {}
local DARK_SEAL_EVENT = 2.4141700243704228e76
local function disconnectAll()
	for i = #connections, 1, -1 do
		local connection = connections[i]; connections[i] = nil
		if Utils then Utils.untrackGlobal(connection) end
		connection:Disconnect()
	end
end
local function track(connection)
	connections[#connections + 1] = connection; Utils.trackGlobal(connection)
end
function AutoDark.sync()
	generation += 1; disconnectAll(); local current = generation
	if not Utils or not GameInfo or Utils.getConfigValue("AutoDark") ~= true or not Utils.isActive() then return true end
	local players = Utils.getPlayers(); local localPlayer = Utils.getLocalPlayer(); local runService = Utils.getRunService()
	if not players or not localPlayer or not runService or not runService.Heartbeat then return false, "Players ou Heartbeat indisponível" end
	local trackedPlayers = {}
	track(players.PlayerAdded:Connect(function(player) if player ~= localPlayer then trackedPlayers[player] = true end end))
	track(players.PlayerRemoving:Connect(function(player) trackedPlayers[player] = nil end))
	for _, player in ipairs(players:GetPlayers()) do
		if player ~= localPlayer then trackedPlayers[player] = true end
	end
	local function otherDarkActive()
		for player in pairs(trackedPlayers) do
			if player:GetAttribute("DarkSealed") == true then return true end
		end
		return false
	end
	local lastError, lastErrorAt, missingAbility, busy = nil, nil, false, false
	track(runService.Heartbeat:Connect(function()
		if busy or current ~= generation or not Utils or not GameInfo or not Utils.isActive() or Utils.getConfigValue("AutoDark") ~= true then return end
		busy = true
		local ok, err = pcall(function()
			if otherDarkActive() then return end
			local ability = GameInfo.getDarkSealAbility()
			if current ~= generation or not Utils or not GameInfo or not Utils.isActive() or Utils.getConfigValue("AutoDark") ~= true then return end
			local workspace = Utils.getWorkspace(); local camera = workspace and workspace.CurrentCamera
			if not ability and not missingAbility then Utils.recordError("AutoDark", "Dark Seal não está equipada ou ainda não carregou"); missingAbility = true end
			if ability then missingAbility = false end
			if ability and camera and not otherDarkActive() then ability:SendEvent(DARK_SEAL_EVENT, camera.CFrame) end
		end)
		busy = false
		if not ok and Utils then
			local time = os.clock(); local message = tostring(err)
			if message ~= lastError or not lastErrorAt or time - lastErrorAt >= 5 then Utils.recordError("AutoDark", message); lastError = message; lastErrorAt = time end
		elseif ok then
			lastError = nil
		end
	end))
	return true
end
function AutoDark.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes: Utils ou GameInfo" end
	Utils, GameInfo = deps.Utils, deps.GameInfo; return AutoDark.sync()
end
function AutoDark.teardown()
	generation += 1; disconnectAll(); Utils, GameInfo = nil, nil
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
