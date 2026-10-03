--!strict
--!optimize 2
-- [[ character ]]

local Character = {}
type UtilsModule = {
	getLocalPlayer: () -> Player?,
	isActive: () -> boolean,
	apiVersion: () -> any,
	trackGlobal: (RBXScriptConnection) -> (),
	untrackGlobal: (RBXScriptConnection) -> (),
	trackCharacter: (RBXScriptConnection) -> (),
	disconnectCharacterConnections: () -> (),
	setManualSpamActive: (boolean) -> (),
	setAutoSpamActive: (boolean) -> (),
	warn: (string) -> (),
	recordTransition: (string, string, string, string?) -> (),
	recordError: (string, string) -> (),
}

type SpamModule = {
	resetState: () -> (),
}
type CharacterBind = {
	name: string?,
	bind: (Model) -> boolean,
	detach: () -> (),
}
local Utils: UtilsModule?
local Spam: SpamModule?
local characterBinds: { CharacterBind } = {}
local boundBinds: { CharacterBind } = {}

-- state
local generation = 0
local phase = "stopped"
local activeCharacter: Model?
local characterAddedConnection: RBXScriptConnection?
local characterRemovingConnection: RBXScriptConnection?

-- helpers
local function setPhase(nextPhase: string, reason: string?)
	if phase == nextPhase then return end
	local previous = phase; phase = nextPhase
	if Utils and type(Utils.recordTransition) == "function" then pcall(Utils.recordTransition, "Character", previous, nextPhase, reason) end
end
local function isGenerationCurrent(currentGeneration: number): boolean return currentGeneration == generation end
local function isCharacterValid(character: Model, currentGeneration: number): boolean
	if not isGenerationCurrent(currentGeneration) then return false end
	if activeCharacter ~= character then return false end
	if not character.Parent then return false end
	if not Utils or not Utils.isActive() then return false end
	return true
end
local function detachBind(entry: CharacterBind)
	if type(entry.detach) ~= "function" then return end
	pcall(entry.detach)
end
local function detachBoundBinds()
	for index = #boundBinds, 1, -1 do
		local entry = boundBinds[index]; boundBinds[index] = nil
		if entry then detachBind(entry) end
	end
end
local function resetModules()
	if Spam and type(Spam.resetState) == "function" then pcall(Spam.resetState) end
	if Utils then pcall(Utils.setManualSpamActive, false); pcall(Utils.setAutoSpamActive, false) end
end
local function disconnectCharacterRuntime()
	detachBoundBinds()
	if Utils and type(Utils.disconnectCharacterConnections) == "function" then pcall(Utils.disconnectCharacterConnections) end
	resetModules(); activeCharacter = nil
end
local function disconnectGlobalConnection(
	connection: RBXScriptConnection?,
	untrack: ((RBXScriptConnection) -> ())?
): nil
	if not connection then return nil end
	if untrack then pcall(untrack, connection) end
	pcall(connection.Disconnect, connection); return nil
end
local function recordError(message: string)
	if Utils then
		if type(Utils.warn) == "function" then pcall(Utils.warn, message) end
		if type(Utils.recordError) == "function" then pcall(Utils.recordError, "Character", message) end
	end
end
local function rollbackFailedBind(failedEntry: CharacterBind?)
	if failedEntry then detachBind(failedEntry) end
	detachBoundBinds()
	if Utils then pcall(Utils.disconnectCharacterConnections) end
	resetModules(); activeCharacter = nil
end
local function bind(character: Model, currentGeneration: number)
	if not isGenerationCurrent(currentGeneration) then return end
	setPhase("binding", "character_bind_start")
	if not isCharacterValid(character, currentGeneration) then setPhase("stopped", "bind_cancelled"); return end
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not isCharacterValid(character, currentGeneration) then return end
	if not root or not root.Parent or not root:IsA("BasePart") then
		recordError("HumanoidRootPart indisponível; personagem não foi vinculado"); rollbackFailedBind(nil)
		if isGenerationCurrent(currentGeneration) then setPhase("invalid", "root_unavailable") end
		return
	end
	local successfullyBound = 0
	for index, entry in ipairs(characterBinds) do
		if not isCharacterValid(character, currentGeneration) then detachBoundBinds(); return end
		local ok, result = pcall(entry.bind, character)
		if not ok then
			local message = ("%s não vinculou o personagem: %s"):format(
				entry.name or ("bind_" .. index),
				tostring(result)
			)
			recordError(message); rollbackFailedBind(entry)
			if isGenerationCurrent(currentGeneration) then setPhase("invalid", "bind_failed") end
			return
		end
		if not isGenerationCurrent(currentGeneration) then detachBind(entry); detachBoundBinds(); return end
		if result ~= true then
			local message = ("%s não vinculou o personagem: %s"):format(
				entry.name or ("bind_" .. index),
				tostring(result)
			)
			recordError(message); rollbackFailedBind(entry)
			if isGenerationCurrent(currentGeneration) then setPhase("invalid", "bind_failed") end
			return
		end
		table.insert(boundBinds, entry); successfullyBound = successfullyBound + 1
	end
	if not isCharacterValid(character, currentGeneration) then detachBoundBinds(); return end
	if successfullyBound ~= #characterBinds then
		recordError(("Quantidade de binds inconsistente: %d/%d"):format(successfullyBound, #characterBinds)); rollbackFailedBind(nil)
		if isGenerationCurrent(currentGeneration) then setPhase("invalid", "bind_count_mismatch") end
		return
	end
	setPhase("bound", "character_bound")
end
local function setupCharacter(character: Model?)
	if not character or not Utils then return end
	generation = generation + 1; local currentGeneration = generation; disconnectCharacterRuntime(); activeCharacter = character
	local deactivated = false
	local function deactivate(reason: string)
		if deactivated then return end
		if currentGeneration ~= generation then return end
		deactivated = true; generation = generation + 1; setPhase("cleaning", reason); disconnectCharacterRuntime()
		setPhase("stopped", "character_cleaned")
	end
	Utils.trackCharacter(character.AncestryChanged:Connect(function(_, parent)
		if not parent then deactivate("character_removed") end
	end))
	local function connectHumanoid(humanoid: Humanoid)
		if currentGeneration ~= generation then return end
		if not humanoid.Parent then return end
		Utils.trackCharacter(humanoid.Died:Connect(function() deactivate("character_died") end))
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		connectHumanoid(humanoid)
	else
		Utils.trackCharacter(character.ChildAdded:Connect(function(child)
			if currentGeneration ~= generation then return end
			if child:IsA("Humanoid") then connectHumanoid(child) end
		end))
	end
	task.defer(bind, character, currentGeneration)
end
local function validateDependencies(deps: any): (boolean, string?)
	if type(deps) ~= "table" then return false, "dependência ausente: deps" end
	local missing = {}
	local requiredUtils = {
		"getLocalPlayer",
		"isActive",
		"apiVersion",
		"trackGlobal",
		"untrackGlobal",
		"trackCharacter",
		"disconnectCharacterConnections",
		"setManualSpamActive",
		"setAutoSpamActive",
		"warn",
		"recordTransition",
		"recordError",
	}

	if type(deps.Utils) ~= "table" then
		table.insert(missing, "Utils")
	else
		for _, name in ipairs(requiredUtils) do
			if type(deps.Utils[name]) ~= "function" then table.insert(missing, "Utils." .. name) end
		end
	end
	if type(deps.Spam) ~= "table" then table.insert(missing, "Spam")
	elseif type(deps.Spam.resetState) ~= "function" then table.insert(missing, "Spam.resetState") end
	if type(deps.characterBinds) ~= "table" then
		table.insert(missing, "characterBinds")
	else
		for index, entry in ipairs(deps.characterBinds) do
			if type(entry) ~= "table" then return false, ("characterBinds[%d] inválido"):format(index) end
			if type(entry.bind) ~= "function" then return false, ("characterBinds[%d].bind ausente"):format(index) end
			if type(entry.detach) ~= "function" then return false, ("characterBinds[%d].detach ausente"):format(index) end
		end
	end
	if #missing > 0 then return false, "dependência ausente: " .. table.concat(missing, ", ") end
	return true
end

-- setup
function Character.getStatus()
	return {
		schema = Utils and Utils.apiVersion() or nil,
		phase = phase,
		generation = generation,
	}
end
function Character.setup(deps: any)
	local valid, validationError = validateDependencies(deps)
	if not valid then return false, validationError end
	generation = generation + 1
	if Utils then
		characterAddedConnection = disconnectGlobalConnection(characterAddedConnection, Utils.untrackGlobal)
		characterRemovingConnection = disconnectGlobalConnection(characterRemovingConnection, Utils.untrackGlobal); disconnectCharacterRuntime()
	else
		characterAddedConnection = disconnectGlobalConnection(characterAddedConnection); characterRemovingConnection = disconnectGlobalConnection(characterRemovingConnection)
	end
	Utils = deps.Utils :: UtilsModule; Spam = deps.Spam :: SpamModule; characterBinds = deps.characterBinds :: { CharacterBind }; local player = Utils.getLocalPlayer()
	if not player then recordError("LocalPlayer indisponível"); setPhase("invalid", "player_unavailable"); return false, "Players.LocalPlayer indisponível" end
	setPhase("ready", "character_controller_ready")
	characterAddedConnection = player.CharacterAdded:Connect(function(character) setupCharacter(character) end)
	characterRemovingConnection = player.CharacterRemoving:Connect(function(character)
		if character ~= activeCharacter then return end
		local currentGeneration = generation; generation = generation + 1; setPhase("cleaning", "character_removing")
		if currentGeneration <= generation then disconnectCharacterRuntime() end
		setPhase("stopped", "character_removed")
	end)
	Utils.trackGlobal(characterAddedConnection); Utils.trackGlobal(characterRemovingConnection); local currentCharacter = player.Character
	if currentCharacter then setupCharacter(currentCharacter) end
	return true
end
function Character.teardown()
	generation = generation + 1
	if Utils then
		characterAddedConnection = disconnectGlobalConnection(characterAddedConnection, Utils.untrackGlobal)
		characterRemovingConnection = disconnectGlobalConnection(characterRemovingConnection, Utils.untrackGlobal); setPhase("cleaning", "character_controller_teardown"); disconnectCharacterRuntime()
	else
		characterAddedConnection = disconnectGlobalConnection(characterAddedConnection); characterRemovingConnection = disconnectGlobalConnection(characterRemovingConnection)
	end
	setPhase("stopped", "character_controller_stopped"); Utils = nil; Spam = nil; characterBinds = {}
	boundBinds = {}; activeCharacter = nil
end
Character.__contract = {
	requires = {
		Spam = "spam",
		Utils = "utils",
	},
}

return Character
