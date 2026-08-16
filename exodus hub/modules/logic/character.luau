-- [[ Character ]]

local Character = {}
local Utils
local AutoParry
local AutoClash
local Spam

-- state
local generation = 0
local characterAddedConnection

-- helpers
local function resetModules()
    pcall(AutoParry.detachCharacter)
    pcall(AutoClash.detachCharacter)
    pcall(Spam.resetState)
    Utils.setManualSpamActive(false)
end

local function disconnectCharacterRuntime()
    Utils.disconnectCharacterConnections()
    resetModules()
end

local function bind(character, currentGeneration)
    if currentGeneration ~= generation
        or not character
        or not character.Parent
        or not Utils.isActive()
    then
        return
    end

    local root = character:WaitForChild("HumanoidRootPart", 10)

    if currentGeneration ~= generation
        or not root
        or not root.Parent
        or not Utils.isActive()
    then
        return
    end

    local parryOk, parryBound = pcall(AutoParry.bindParry, character)

    if not parryOk or parryBound ~= true then
        Utils.warn("AutoParry não vinculou o personagem: " .. tostring(parryBound))
        return
    end

    local clashOk, clashBound = pcall(AutoClash.bindCharacter, character)

    if not clashOk or clashBound ~= true then
        Utils.warn("AutoClash não vinculou o personagem: " .. tostring(clashBound))
    end
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
        generation = generation + 1
        disconnectCharacterRuntime()
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
function Character.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.getLocalPlayer) ~= "function"
        or type(deps.Utils.isActive) ~= "function"
        or type(deps.Utils.trackGlobal) ~= "function"
        or type(deps.Utils.disconnectCharacterConnections) ~= "function"
        or type(deps.Utils.trackCharacter) ~= "function"
        or type(deps.Utils.setManualSpamActive) ~= "function"
        or type(deps.AutoParry) ~= "table"
        or type(deps.AutoParry.bindParry) ~= "function"
        or type(deps.AutoParry.detachCharacter) ~= "function"
        or type(deps.AutoClash) ~= "table"
        or type(deps.AutoClash.bindCharacter) ~= "function"
        or type(deps.AutoClash.detachCharacter) ~= "function"
        or type(deps.Spam) ~= "table"
        or type(deps.Spam.resetState) ~= "function"
    then
        return false
    end

    Utils = deps.Utils
    AutoParry = deps.AutoParry
    AutoClash = deps.AutoClash
    Spam = deps.Spam

    local player = Utils.getLocalPlayer()

    if not player then
        return false
    end

    if characterAddedConnection then
        Utils.untrackGlobal(characterAddedConnection)
        pcall(characterAddedConnection.Disconnect, characterAddedConnection)
    end

    generation = generation + 1
    characterAddedConnection = player.CharacterAdded:Connect(setupCharacter)
    Utils.trackGlobal(characterAddedConnection)

    if player.Character then
        setupCharacter(player.Character)
    end

    return true
end

return Character
