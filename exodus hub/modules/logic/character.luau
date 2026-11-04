-- [[ character ]]

local Character = {}
local Utils, Spam
local characterBinds = {}
local boundBinds = {}
local activeCharacter
local addedConnection, removingConnection
local generation = 0
local phase = "stopped"

local function setPhase(nextPhase, reason)
    if nextPhase == phase then return end
    local previous = phase
    phase = nextPhase
    if Utils and type(Utils.recordTransition) == "function" then
        pcall(Utils.recordTransition, "Character", previous, nextPhase, reason)
    end
end

local function disconnect(connection)
    if not connection then return nil end
    if Utils then pcall(Utils.untrackGlobal, connection) end
    pcall(connection.Disconnect, connection)
    return nil
end

local function valid(character, token)
    return token == generation and activeCharacter == character
        and character.Parent ~= nil and Utils ~= nil and Utils.isActive()
end

local function detach(entry)
    if entry and type(entry.detach) == "function" then pcall(entry.detach) end
end

local function cleanCharacter()
    for index = #boundBinds, 1, -1 do
        detach(boundBinds[index])
        boundBinds[index] = nil
    end
    if Utils then
        pcall(Utils.disconnectCharacterConnections)
        pcall(Utils.setManualSpamActive, false)
        pcall(Utils.setAutoSpamActive, false)
    end
    if Spam then pcall(Spam.resetState) end
    activeCharacter = nil
end

local function bind(character, token)
    if token ~= generation then return end
    setPhase("binding", "character_bind_start")
    if not valid(character, token) then
        setPhase("stopped", "bind_cancelled")
        return
    end

    local root = character:WaitForChild("HumanoidRootPart", 10)
    if not valid(character, token) then return end
    if not root or not root.Parent or not root:IsA("BasePart") then
        cleanCharacter()
        setPhase("invalid", "root_unavailable")
        return
    end

    for index, entry in ipairs(characterBinds) do
        if not valid(character, token) then
            cleanCharacter()
            return
        end

        local ok, result, detail = xpcall(entry.bind, function(err)
            return debug.traceback(tostring(err), 2)
        end, character)

        if token ~= generation then
            detach(entry)
            cleanCharacter()
            return
        end

        if not ok or result ~= true then
            local reason = ok and (detail or result) or result
            if Utils then
                Utils.recordError("Character",
                    ("%s não vinculou o personagem: %s"):format(entry.name or ("bind_" .. index), tostring(reason)))
            end
            detach(entry)
            cleanCharacter()
            setPhase("invalid", "bind_failed")
            return
        end

        boundBinds[#boundBinds + 1] = entry
    end

    if not valid(character, token) then
        cleanCharacter()
        return
    end
    setPhase("bound", "character_bound")
end

local function setupCharacter(character)
    if not character or not Utils then return end

    generation += 1
    cleanCharacter()
    activeCharacter = character
    local token = generation

    local function deactivate(reason)
        if token ~= generation then return end
        generation += 1
        setPhase("cleaning", reason)
        cleanCharacter()
        setPhase("stopped", "character_cleaned")
    end

    Utils.trackCharacter(character.AncestryChanged:Connect(function(_, parent)
        if not parent then deactivate("character_removed") end
    end))

    local function onHumanoid(humanoid)
        if token ~= generation or not humanoid.Parent then return end
        Utils.trackCharacter(humanoid.Died:Connect(function()
            deactivate("character_died")
        end))
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        onHumanoid(humanoid)
    else
        Utils.trackCharacter(character.ChildAdded:Connect(function(child)
            if token == generation and child:IsA("Humanoid") then onHumanoid(child) end
        end))
    end

    task.defer(bind, character, token)
end

local requiredUtils = {
    "getLocalPlayer", "isActive", "apiVersion", "trackGlobal", "untrackGlobal",
    "trackCharacter", "disconnectCharacterConnections", "setManualSpamActive",
    "setAutoSpamActive", "recordTransition",
}

local function validate(deps)
    if type(deps) ~= "table" then return false, "dependência ausente: deps" end

    local missing = {}
    if type(deps.Utils) ~= "table" then
        missing[#missing + 1] = "Utils"
    else
        for _, method in ipairs(requiredUtils) do
            if type(deps.Utils[method]) ~= "function" then
                missing[#missing + 1] = "Utils." .. method
            end
        end
    end

    if type(deps.Spam) ~= "table" then
        missing[#missing + 1] = "Spam"
    elseif type(deps.Spam.resetState) ~= "function" then
        missing[#missing + 1] = "Spam.resetState"
    end

    if type(deps.characterBinds) ~= "table" then
        missing[#missing + 1] = "characterBinds"
    else
        for index, entry in ipairs(deps.characterBinds) do
            if type(entry) ~= "table" or type(entry.bind) ~= "function"
                or type(entry.detach) ~= "function" then
                return false, ("characterBinds[%d] inválido"):format(index)
            end
        end
    end

    if #missing > 0 then
        return false, "dependência ausente: " .. table.concat(missing, ", ")
    end
    return true
end

function Character.getStatus()
    return {schema = Utils and Utils.apiVersion() or nil, phase = phase, generation = generation}
end

function Character.setup(deps)
    local ok, err = validate(deps)
    if not ok then return false, err end

    Character.teardown()
    Utils, Spam, characterBinds = deps.Utils, deps.Spam, deps.characterBinds

    local player = Utils.getLocalPlayer()
    if not player then
        setPhase("invalid", "player_unavailable")
        return false, "Players.LocalPlayer indisponível"
    end

    setPhase("ready", "character_controller_ready")

    addedConnection = player.CharacterAdded:Connect(setupCharacter)
    removingConnection = player.CharacterRemoving:Connect(function(character)
        if character ~= activeCharacter then return end
        generation += 1
        setPhase("cleaning", "character_removing")
        cleanCharacter()
        setPhase("stopped", "character_removed")
    end)

    Utils.trackGlobal(addedConnection)
    Utils.trackGlobal(removingConnection)
    if player.Character then setupCharacter(player.Character) end
    return true
end

function Character.teardown()
    generation += 1
    addedConnection = disconnect(addedConnection)
    removingConnection = disconnect(removingConnection)
    if Utils then
        setPhase("cleaning", "character_controller_teardown")
        cleanCharacter()
    end
    setPhase("stopped", "character_controller_stopped")
    Utils, Spam, characterBinds = nil, nil, {}
    boundBinds = {}
    activeCharacter = nil
end

Character.__contract = {
    requires = {Spam = "spam", Utils = "utils"},
    requiresMethods = {
        Utils = requiredUtils,
        Spam = {"resetState"},
    },
    provides = {"setup", "teardown"},
}

return Character
