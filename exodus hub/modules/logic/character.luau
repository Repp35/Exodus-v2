-- [[ character ]]

-- dependencies and state
local Character = {}
local utils, spam, binds = nil, nil, {}

local added, removing, currentLife
local generation, setupEpoch, phase, workerRunning = 0, 0, "stopped", false
-- lifecycle
local function setPhase(nextPhase, reason)
	if phase == nextPhase then return end
	local previous = phase; phase = nextPhase
	if utils then utils.recordTransition("Character", previous, nextPhase, reason) end
end
local function detach(entry)
	if entry and type(entry.detach) == "function" then pcall(entry.detach) end
end
local function detachBound(life)
	if not life then return end
	for i = #life.bound, 1, -1 do
		detach(life.bound[i]); life.bound[i] = nil
	end
end
local function clearLife()
	local life = currentLife; currentLife = nil; detachBound(life)
	if utils then utils.disconnectCharacterConnections(); utils.setManualSpamActive(false); utils.setAutoSpamActive(false) end
	if spam then spam.resetState() end
end
local function valid(life) return currentLife == life and utils ~= nil and utils.isActive() and life.character.Parent ~= nil end
-- character binding
local function startWorker()
	if workerRunning then return end
	workerRunning = true
	task.spawn(function()
		while currentLife and not currentLife.attempted do
			local life = currentLife; life.attempted = true; setPhase("binding", "character_bind_start"); local root = life.character:FindFirstChild("HumanoidRootPart")
			local deadline = os.clock() + 10
			while valid(life) and not root and os.clock() < deadline do
				task.wait(); root = life.character:FindFirstChild("HumanoidRootPart")
			end
			if valid(life) and root and root.Parent and root:IsA("BasePart") then
				local failed = false
				for index, entry in ipairs(binds) do
					if not valid(life) then break end
					local ok, result, detail = pcall(entry.bind, life.character)
					if not valid(life) then detach(entry); break end
					if not ok or result ~= true then
						local message = ("%s não vinculou o personagem: %s"):format(entry.name or ("bind_" .. index), tostring(ok and detail or result)); utils.recordError("Character", message)
						detach(entry); detachBound(life); utils.disconnectCharacterConnections(); utils.setManualSpamActive(false)
						utils.setAutoSpamActive(false)
						if spam then spam.resetState() end
						currentLife = nil; setPhase("invalid", "bind_failed"); failed = true; break
					end
					life.bound[#life.bound + 1] = entry
				end
				if not failed and valid(life) then setPhase("bound", "character_bound") end
			elseif valid(life) then
				clearLife(); setPhase("invalid", "root_unavailable")
			end
		end
		workerRunning = false
		if currentLife and not currentLife.attempted then startWorker() end
	end)
end
-- character events
local function setupCharacter(character)
	if not character or not utils then return end
	generation += 1; clearLife(); local life = { character = character, bound = {}, attempted = false, humanoids = {} }; currentLife = life
	local function deactivate(reason)
		if currentLife ~= life then return end
		generation += 1; setPhase("cleaning", reason); clearLife(); setPhase("stopped", "character_cleaned")
	end
	utils.trackCharacter(character.AncestryChanged:Connect(function(_, parent)
		if not parent then deactivate("character_removed") end
	end))
	local function watchHumanoid(humanoid)
		if currentLife ~= life or life.humanoids[humanoid] then return end
		life.humanoids[humanoid] = true
		utils.trackCharacter(humanoid.Died:Connect(function() deactivate("character_died") end))
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then watchHumanoid(humanoid) end
	utils.trackCharacter(character.ChildAdded:Connect(function(child)
		if child:IsA("Humanoid") then watchHumanoid(child) end
	end))
	startWorker()
end
-- public API
function Character.getStatus() return { schema = utils and utils.apiVersion() or nil, phase = phase, generation = generation } end
function Character.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.Spam) ~= "table"
		or type(deps.Spam.resetState) ~= "function"
		or type(deps.characterBinds) ~= "table"
	then
		return false, "dependência ausente: Utils, Spam ou characterBinds"
	end
	for index, entry in ipairs(deps.characterBinds) do
		if type(entry) ~= "table" or type(entry.bind) ~= "function" or type(entry.detach) ~= "function" then return false, ("characterBinds[%d] inválido"):format(index) end
	end
	Character.teardown(); utils, spam, binds = deps.Utils, deps.Spam, deps.characterBinds; local player = utils.getLocalPlayer()
	if not player then setPhase("invalid", "player_unavailable"); return false, "Players.LocalPlayer indisponível" end
	setPhase("ready", "character_controller_ready"); local owner = setupEpoch
	added = player.CharacterAdded:Connect(function(character)
		if owner == setupEpoch then setupCharacter(character) end
	end)
	removing = player.CharacterRemoving:Connect(function(character)
		if owner ~= setupEpoch then return end
		if currentLife and currentLife.character == character then generation += 1; setPhase("cleaning", "character_removing"); clearLife(); setPhase("stopped", "character_removed") end
	end)
	utils.trackGlobal(added); utils.trackGlobal(removing)
	if player.Character then setupCharacter(player.Character) end
	return true
end
function Character.teardown()
	generation += 1; setupEpoch += 1
	if utils then
		if added then utils.untrackGlobal(added); added:Disconnect() end
		if removing then utils.untrackGlobal(removing); removing:Disconnect() end
		setPhase("cleaning", "character_controller_teardown"); clearLife()
	else
		if added then added:Disconnect() end
		if removing then removing:Disconnect() end
	end
	setPhase("stopped", "character_controller_stopped"); added, removing, utils, spam, binds = nil, nil, nil, nil, {}
end
-- contract
Character.__contract = {
	requires = { Spam = "spam", Utils = "utils" },
	requiresMethods = {
		Utils = {
			"getLocalPlayer",
			"isActive",
			"apiVersion",
			"trackGlobal",
			"untrackGlobal",
			"trackCharacter",
			"disconnectCharacterConnections",
			"setManualSpamActive",
			"setAutoSpamActive",
			"recordTransition",
			"recordError",
		},
		Spam = { "resetState" },
	},

	provides = { "setup", "teardown", "getStatus" },
}

return Character
