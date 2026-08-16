--[[ Character ]]

local Character = {}
local Utils, AutoParry, AutoClash, Spam
local generation = 0

-- reset
local function resetModules()
    pcall(AutoParry.detachCharacter)
    pcall(AutoClash.resetState)
    pcall(Spam.resetState)
    Utils.setManualSpamActive(false)
end

-- binding
local function bind(character, currentGeneration)
    if not character or not character.Parent or currentGeneration ~= generation then return end
    local root = character:WaitForChild("HumanoidRootPart", 10)
    if currentGeneration ~= generation or not root or not root.Parent or not Utils.isActive() then return end
    local parryOk, parryError = pcall(AutoParry.bindParry, character)
    if not parryOk then Utils.warn("AutoParry não vinculou o personagem: " .. tostring(parryError)) end
    local clashOk, clashError = pcall(AutoClash.bindCharacter, character)
    if not clashOk or clashError == false then Utils.warn("AutoClash não vinculou o personagem: " .. tostring(clashError)) end
end

-- lifecycle
local function setupCharacter(character)
    if not character then return end
    generation = generation + 1
    local currentGeneration = generation
    Utils.disconnectCharacterConnections()
    resetModules()
    local deactivated = false
    local function deactivate()
        if deactivated or currentGeneration ~= generation then return end
        deactivated = true
        generation = generation + 1
        Utils.disconnectCharacterConnections()
        resetModules()
    end
    Utils.trackCharacter(character.AncestryChanged:Connect(function(_, parent)
        if not parent then deactivate() end
    end))
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then Utils.trackCharacter(humanoid.Died:Connect(deactivate)) end
    task.defer(bind, character, currentGeneration)
end

-- setup
function Character.setup(deps)
    if type(deps) ~= "table" or not deps.Utils or not deps.AutoParry or not deps.AutoClash or not deps.Spam then return false end
    Utils, AutoParry, AutoClash, Spam = deps.Utils, deps.AutoParry, deps.AutoClash, deps.Spam
    local player = Utils.getLocalPlayer()
    if not player then return false end
    Utils.trackGlobal(player.CharacterAdded:Connect(setupCharacter))
    if player.Character then setupCharacter(player.Character) end
    return true
end
return Character
