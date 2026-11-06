-- [[ autodark ]]

-- dependencies
local AutoDark = {}
local utils, remote

-- tuning
local DARK_EVENT = 2.4141700243704228e76

-- state
local connection

-- lifecycle
local function disconnect()
	if not connection then return end
	if utils then utils.untrackGlobal(connection) end
	connection:Disconnect(); connection = nil
end
function AutoDark.sync()
	disconnect()
	if not utils or not remote or not utils.getConfigValue("AutoDark") then return true end
	local runService = utils.getRunService()
	if not runService or not runService.Heartbeat then return false, "Heartbeat indisponível" end
	connection = runService.Heartbeat:Connect(function()
		if not utils.getConfigValue("AutoDark") then return end
		local camera = utils.getWorkspace().CurrentCamera
		if camera then remote.fireDark(DARK_EVENT, camera.CFrame) end
	end)
	utils.trackGlobal(connection); return true
end
function AutoDark.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.Remote) ~= "table" then return false, "dependências ausentes: Utils ou Remote" end
	AutoDark.teardown(); utils, remote = deps.Utils, deps.Remote; return AutoDark.sync()
end
function AutoDark.teardown()
	disconnect(); utils, remote = nil, nil
end

-- contract
AutoDark.__contract = {
	requires = { Utils = "utils", Remote = "remote" },
	requiresMethods = {
		Utils = { "getConfigValue", "getWorkspace", "getRunService", "trackGlobal", "untrackGlobal" },
		Remote = { "fireDark" },
	},

	provides = { "setup", "sync", "teardown" },
}

return AutoDark
