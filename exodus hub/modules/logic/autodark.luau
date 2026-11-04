-- [[ autodark ]]

local AutoDark = {}
local Utils, GameInfo
local generation = 0
local DARK_SEAL_EVENT = 2.4141700243704228e76

function AutoDark.sync()
	generation += 1
	local current = generation
	if not Utils or not GameInfo or Utils.getConfigValue("AutoDark") ~= true or not Utils.isActive() then return true end
	task.spawn(function()
		local lastError, lastErrorAt, missingAbility = nil, nil, false
		while current == generation and Utils and GameInfo and Utils.isActive() and Utils.getConfigValue("AutoDark") == true do
			local ok, err = pcall(function()
				local ability = GameInfo.getDarkSealAbility()
				local workspace = Utils.getWorkspace()
				local camera = workspace and workspace.CurrentCamera
				if not ability and not missingAbility then Utils.recordError("AutoDark", "Dark Seal não está equipada ou ainda não carregou"); missingAbility = true end
				if ability then missingAbility = false end
				if ability and camera then ability:SendEvent(DARK_SEAL_EVENT, camera.CFrame) end
			end)
			if not ok then
				local time = os.clock(); local message = tostring(err)
				if message ~= lastError or not lastErrorAt or time - lastErrorAt >= 5 then Utils.recordError("AutoDark", message); lastError = message; lastErrorAt = time end
			else
				lastError = nil
			end
			task.wait(0.05)
		end
	end)
	return true
end

function AutoDark.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes: Utils ou GameInfo" end
	Utils, GameInfo = deps.Utils, deps.GameInfo
	return AutoDark.sync()
end

function AutoDark.teardown()
	generation += 1; Utils, GameInfo = nil, nil
end

AutoDark.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = {
		Utils = { "getConfigValue", "getWorkspace", "isActive", "recordError" },
		GameInfo = { "getDarkSealAbility" },
	},
	provides = { "setup", "sync", "teardown" },
}

return AutoDark
