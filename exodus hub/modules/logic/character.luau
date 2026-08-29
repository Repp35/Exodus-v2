-- [[ Character ]]

local Character = {}
local Utils
local Spam
local characterBinds = {}

-- state
local generation = 0
local characterAddedConnection
local phase = "stopped"

-- helpers
local function setPhase(nextPhase, reason)
    if phase == nextPhase then
        return
    end
    local previous = phase
    phase = nextPhase
    if Utils and type(Utils.recordTransition) == "function" then
        Utils.recordTransition("Character", previous, nextPhase, reason)
    end
end
local function detachAllBinds()
    for index = #characterBinds, 1, -1 do
        pcall(characterBinds[index].detach)
    end
end
local function resetModules()
    detachAllBinds()
    if Spam and type(Spam.resetState) == "function" then
        pcall(Spam.resetState)
    end
    Utils.setManualSpamActive(false)
    Utils.setAutoSpamActive(false)
end
local function disconnectCharacterRuntime()
    Utils.disconnectCharacterConnections()
    resetModules()
end
local function bind(character, currentGeneration)
    setPhase("binding", "character_bind_start")
    if currentGeneration ~= generation then
        return
    end
    if not character or not character.Parent or not Utils.isActive() then
        setPhase("stopped", "bind_cancelled")
        return
    end
    local root = character:WaitForChild("HumanoidRootPart", 10)
    if currentGeneration ~= generation then
        return
    end
    if not root or not root.Parent or not Utils.isActive() then
        Utils.disconnectCharacterConnections()
        setPhase("invalid", "root_unavailable")
        return
    end
    local boundCount = 0
    for index, entry in ipairs(characterBinds) do
        local ok, result = pcall(entry.bind, character)
        if not ok or result ~= true then
            local message = ("%s não vinculou o personagem: %s")
                :format(entry.name, tostring(result))
            Utils.warn(message)
            if type(Utils.recordError) == "function" then
                Utils.recordError("Character", message)
            end
            for detachIndex = boundCount, 1, -1 do
                pcall(characterBinds[detachIndex].detach)
            end
            Utils.disconnectCharacterConnections()
            Utils.setManualSpamActive(false)
            Utils.setAutoSpamActive(false)
            setPhase("invalid", "bind_failed")
            return
        end
        boundCount = index
    end
    setPhase("bound", "character_bound")
end
local function setupCharacter(character)
    if not character then
        return
    end
    generation = generation + 1
    local currentGeneration = generation
    disconnectCharacterRuntime()
    local deactivated = false
    local function deactivate()
        if deactivated or currentGeneration ~= generation then
            return
        end
        deactivated = true
        setPhase("cleaning", "character_invalidated")
        generation = generation + 1
        disconnectCharacterRuntime()
        setPhase("stopped", "character_cleaned")
    end
    Utils.trackCharacter(character.AncestryChanged:Connect(function(_, parent)
        if not parent then
            deactivate()
        end
    end))
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        Utils.trackCharacter(humanoid.Died:Connect(deactivate))
    end
    task.defer(bind, character, currentGeneration)
end

-- setup
function Character.getStatus()
    return {
        schema = Utils.apiVersion(),
        phase = phase,
        generation = generation,
    }
end
function Character.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.getLocalPlayer) ~= "function"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.apiVersion) ~= "function"
        or type(deps.Utils.trackGlobal) ~= "function"
        or type(deps.Utils.disconnectCharacterConnections) ~= "function"
        or type(deps.Utils.trackCharacter) ~= "function"
        or type(deps.Utils.setManualSpamActive) ~= "function"
        or type(deps.Utils.setAutoSpamActive) ~= "function"
        or type(deps.Utils.warn) ~= "function"
        or type(deps.Utils.recordTransition) ~= "function"
        or type(deps.Utils.recordError) ~= "function"
        or type(deps.Spam) ~= "table"
        or type(deps.Spam.resetState) ~= "function"
        or type(deps.characterBinds) ~= "table"
    then
        return false, "dependência ausente: Utils, Spam ou characterBinds"
    end
    Utils = deps.Utils
    Spam = deps.Spam
    characterBinds = deps.characterBinds
    local player = Utils.getLocalPlayer()
    if not player then
        Utils.recordError("Character", "LocalPlayer indisponível")
        setPhase("invalid", "player_unavailable")
        return false, "Players.LocalPlayer indisponível"
    end
    if characterAddedConnection then
        Utils.untrackGlobal(characterAddedConnection)
        pcall(characterAddedConnection.Disconnect, characterAddedConnection)
    end
    generation = generation + 1
    setPhase("ready", "character_controller_ready")
    characterAddedConnection = player.CharacterAdded:Connect(setupCharacter)
    Utils.trackGlobal(characterAddedConnection)
    if player.Character then
        setupCharacter(player.Character)
    end
    return true
end
Character.__contract = {
    requires = {
        Spam = "spam",
        Utils = "utils",
    },
}
return Character
