-- [[ Dash ]]

local Dash = {}
local Utils
local onDetected

-- tuning
local T = {
    DETECT_WINDOW = 0.25,
    REGISTER_DEBOUNCE = 0.050,
    ANIMATION_SCAN_INTERVAL = 1 / 30,
    VELOCITY_SCAN_INTERVAL = 1 / 30,
    CLEAN_INTERVAL = 0.10,
}

local R = {
    players = nil,
    playerList = {},
    generation = 0,
    lastScanAt = 0,
    lastVelocityScanAt = 0,
    lastCleanAt = 0,
    connections = {},
    characterConnections = {},
    playerConnections = {},
    cooldown = {},
    trackSnapshot = {},
    previousSpeed = {},
    lastPosition = {},
}

-- helpers
local function now()
    if Utils and type(Utils.now) == "function" then
        return Utils.now()
    end
    return os.clock()
end
local function horizontalSpeed(value)
    if typeof(value) ~= "Vector3" then
        return 0
    end
    return math.sqrt(value.X * value.X + value.Z * value.Z)
end
local function disconnectList(list)
    for i = #list, 1, -1 do
        local connection = list[i]
        list[i] = nil
        if connection then
            pcall(connection.Disconnect, connection)
        end
    end
end
local function disconnectPlayerConnections(player)
    local characters = R.characterConnections[player]
    if characters then
        disconnectList(characters)
        R.characterConnections[player] = nil
    end
    local connections = R.playerConnections[player]
    if connections then
        disconnectList(connections)
        R.playerConnections[player] = nil
    end
end
local function addCharacterConnection(player, connection)
    local list = R.characterConnections[player]
    if not list then
        list = {}
        R.characterConnections[player] = list
    end
    list[#list + 1] = connection
end
local function isTrack(track)
    if not track or not track:IsA("AnimationTrack") then
        return false
    end
    local animation = track.Animation
    if not animation then
        return false
    end
    local name = string.lower(animation.Name or "")
    local id = string.lower(animation.AnimationId or "")
    return name:find("dash", 1, true) ~= nil
        or id:find("dash", 1, true) ~= nil
end
local function cleanCooldowns(t)
    local expiration = T.DETECT_WINDOW
    for player, last in pairs(R.cooldown) do
        if not player.Parent or t - last > expiration then
            R.cooldown[player] = nil
        end
    end
end
local function register(player, position, velocity)
    if not player or not player.Parent then
        return
    end
    local t = now()
    local last = R.cooldown[player]
	local cooldown = math.max(
		T.REGISTER_DEBOUNCE,
		T.DETECT_WINDOW
    )
    if last and t - last < cooldown then
        return
    end
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if typeof(position) ~= "Vector3" and root then
        position = root.Position
    end
    if typeof(velocity) ~= "Vector3" and root then
        velocity = root.AssemblyLinearVelocity
    end
    R.cooldown[player] = t
    local event = {
        player = player,
        userId = player.UserId,
        detectedAt = t,
        position = position,
        velocity = velocity,
        previousPosition = R.lastPosition[player],
    }
    if typeof(position) == "Vector3" then
        R.lastPosition[player] = position
    end
    if type(onDetected) == "function" then
        pcall(onDetected, event)
    end
end
local function hookAnimator(animator, player, character, generation)
    if not animator
        or not player
        or generation ~= R.generation
        or not player.Parent
        or player.Character ~= character
    then
        return
    end
    addCharacterConnection(
        player,
        animator.AnimationPlayed:Connect(function(track)
            if generation ~= R.generation
                or not player.Parent
                or player.Character ~= character
            then
                return
            end
            if isTrack(track) then
                register(player)
            end
        end)
    )
    local snapshot = R.trackSnapshot[player] or {}
    R.trackSnapshot[player] = snapshot
    table.clear(snapshot)
    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        snapshot[track] = true
    end
end
local function attachCharacter(character, player, generation)
    if generation ~= R.generation
        or not character
        or not player
        or not player.Parent
        or player.Character ~= character
    then
        return
    end
    disconnectList(R.characterConnections[player] or {})
    R.characterConnections[player] = nil
    local humanoid = character:FindFirstChildOfClass("Humanoid")
        or character:WaitForChild("Humanoid", 3)
    if generation ~= R.generation
        or player.Character ~= character
        or not humanoid
    then
        return
    end
    local animator = humanoid:FindFirstChildOfClass("Animator")
        or humanoid:WaitForChild("Animator", 3)
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 3)
    if generation ~= R.generation
        or player.Character ~= character
        or not root
    then
        return
    end
    if animator then
        hookAnimator(animator, player, character, generation)
    end
    R.previousSpeed[player] = horizontalSpeed(root.AssemblyLinearVelocity)
    R.lastPosition[player] = root.Position
end
local function hookPlayer(player, generation)
    if generation ~= R.generation or not player or not player.Parent then
        return
    end
    R.trackSnapshot[player] = {}
    R.previousSpeed[player] = nil
    R.lastPosition[player] = nil
    R.playerList[#R.playerList + 1] = player
    if player.Character then
        task.spawn(attachCharacter, player.Character, player, generation)
    end
    local list = R.playerConnections[player] or {}
    R.playerConnections[player] = list
    list[#list + 1] = player.CharacterAdded:Connect(function(character)
        if generation == R.generation then
            task.spawn(attachCharacter, character, player, generation)
        end
    end)
end
local function removePlayer(player)
    disconnectPlayerConnections(player)
    for i = #R.playerList, 1, -1 do
        if R.playerList[i] == player then
            table.remove(R.playerList, i)
        end
    end
    R.cooldown[player] = nil
    R.trackSnapshot[player] = nil
    R.previousSpeed[player] = nil
    R.lastPosition[player] = nil
end
local function scanTracks()
    for i = 1, #R.playerList do
        local player = R.playerList[i]
        if player and player.Parent then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
            if animator then
                local current = animator:GetPlayingAnimationTracks()
                local snapshot = R.trackSnapshot[player] or {}
                R.trackSnapshot[player] = snapshot
                for _, track in ipairs(current) do
                    if not snapshot[track] and isTrack(track) then
                        register(player)
                    end
                end
                table.clear(snapshot)
                for _, track in ipairs(current) do
                    snapshot[track] = true
                end
            end
        end
    end
end
local function scanVelocity()
    for i = 1, #R.playerList do
        local player = R.playerList[i]
        if player and player.Parent then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root then
                local velocity = root.AssemblyLinearVelocity
                local speed = horizontalSpeed(velocity)
                local previous = R.previousSpeed[player]
                if previous == nil then
                    previous = speed
                elseif speed >= 80 and speed - previous >= 15 then
                    register(player, root.Position, velocity)
                end
                R.previousSpeed[player] = speed
                R.lastPosition[player] = root.Position
            end
		end
	end
end

-- setup
function Dash.setup(deps)
    if type(deps) ~= "table"
        or type(deps.Utils) ~= "table"
        or type(deps.Utils.getPlayers) ~= "function"
    then
        return false, "dependência ausente: Utils"
    end
    Dash.resetState()
    Utils = deps.Utils
    local okPlayers, players = pcall(Utils.getPlayers)
    if not okPlayers or not players then
        return false, "Players indisponível"
    end
    R.players = players
    local generation = R.generation
    for _, currentPlayer in ipairs(players:GetPlayers()) do
        hookPlayer(currentPlayer, generation)
    end
    R.connections[#R.connections + 1] = players.PlayerAdded:Connect(function(currentPlayer)
        if generation == R.generation then
            hookPlayer(currentPlayer, generation)
        end
    end)
	R.connections[#R.connections + 1] = players.PlayerRemoving:Connect(removePlayer)
	return true
end

-- api
function Dash.setHandler(handler)
    onDetected = type(handler) == "function" and handler or nil
    return true
end
function Dash.tick(t)
    if not R.players then
        return
    end
    if t - R.lastCleanAt >= T.CLEAN_INTERVAL then
        R.lastCleanAt = t
        cleanCooldowns(t)
    end
    if t - R.lastScanAt >= T.ANIMATION_SCAN_INTERVAL then
        R.lastScanAt = t
        scanTracks()
    end
    if t - R.lastVelocityScanAt >= T.VELOCITY_SCAN_INTERVAL then
        R.lastVelocityScanAt = t
        scanVelocity()
    end
end

-- lifecycle
function Dash.resetState()
    R.generation += 1
    disconnectList(R.connections)
    for player in pairs(R.characterConnections) do
        disconnectPlayerConnections(player)
    end
    table.clear(R.playerList)
    table.clear(R.cooldown)
    table.clear(R.trackSnapshot)
    table.clear(R.previousSpeed)
    table.clear(R.lastPosition)
    R.players = nil
    R.lastScanAt = 0
    R.lastVelocityScanAt = 0
    R.lastCleanAt = 0
end
function Dash.teardown()
    Dash.resetState()
    Utils = nil
    onDetected = nil
end
function Dash.getStatus()
    return {
        schema = Utils and Utils.apiVersion and Utils.apiVersion() or 1,
        players = R.players ~= nil,
        detecting = R.players ~= nil,
    }
end
Dash.__contract = {
    requires = {
        Utils = "utils",
    },
}
return Dash
