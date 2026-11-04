-- [[ dash ]]

local Dash = {}
export type DashEvent = {
    player: Player,
    userId: number,
    detectedAt: number,
    position: Vector3?,
    velocity: Vector3?,
    previousPosition: Vector3?,
}

local T = {
    DETECT_WINDOW = 0.25,
    ANIMATION_SCAN_INTERVAL = 1 / 30,
    VELOCITY_SCAN_INTERVAL = 1 / 30,
    CLEAN_INTERVAL = 0.10,
    VELOCITY_MIN_SPEED = 80,
    VELOCITY_MIN_INCREASE = 15,
}

local Utils, onDetected, players
local generation = 0
local connections = {}
local tracked, playerList = {}, {}
local animationCache = setmetatable({}, {__mode = "k"})
local lastScanAt, lastVelocityAt, lastCleanAt = 0, 0, 0

local function now()
    if Utils and type(Utils.now) == "function" then
        local ok, value = pcall(Utils.now)
        if ok and type(value) == "number" then return value end
    end
    return os.clock()
end

local function horizontalSpeed(vector)
    if typeof(vector) ~= "Vector3" then return 0 end
    return math.sqrt(vector.X * vector.X + vector.Z * vector.Z)
end

local function disconnect(list)
    for index = #list, 1, -1 do
        pcall(list[index].Disconnect, list[index])
        list[index] = nil
    end
end

local function dashAnimation(track)
    if not track or not track:IsA("AnimationTrack") then return false end
    local animation = track.Animation
    if not animation then return false end
    if animationCache[animation] ~= nil then return animationCache[animation] end

    local name = string.lower(animation.Name or "")
    local id = string.lower(animation.AnimationId or "")
    local found = name:find("dash", 1, true) ~= nil or id:find("dash", 1, true) ~= nil
    animationCache[animation] = found
    return found
end

local function register(player, state, position, velocity)
    if not player.Parent then return end
    local time = now()
    if state.lastDetected and time - state.lastDetected < T.DETECT_WINDOW then return end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if typeof(position) ~= "Vector3" and root then position = root.Position end
    if typeof(velocity) ~= "Vector3" and root then velocity = root.AssemblyLinearVelocity end
    if horizontalSpeed(velocity) < T.VELOCITY_MIN_SPEED then return end

    state.lastDetected = time
    local event: DashEvent = {
        player = player,
        userId = player.UserId,
        detectedAt = time,
        position = position,
        velocity = velocity,
        previousPosition = state.position,
    }

    if typeof(position) == "Vector3" then state.position = position end
    if onDetected then onDetected(event) end
end

local function attachCharacter(player, state, character, token)
    if token ~= generation or player.Character ~= character or not player.Parent then return end
    disconnect(state.characterConnections)
    state.animator, state.speed, state.position, state.positionAt = nil, nil, nil, nil

    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 3)
    if token ~= generation or player.Character ~= character or not player.Parent or not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 3)
    local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 3)
    if token ~= generation or player.Character ~= character or not player.Parent or not root then return end

    if animator then
        state.animator = animator
        state.characterConnections[#state.characterConnections + 1] = animator.AnimationPlayed:Connect(function(track)
            if token == generation and player.Character == character and player.Parent
                and dashAnimation(track) then
                register(player, state)
            end
        end)

        table.clear(state.tracks)
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do state.tracks[track] = true end
    end

    state.speed = horizontalSpeed(root.AssemblyLinearVelocity)
    state.position = root.Position
end

local function addPlayer(player)
    if not player or not player.Parent or tracked[player] then return end

    local state = {
        index = #playerList + 1,
        playerConnections = {},
        characterConnections = {},
        tracks = {},
    }
    tracked[player] = state
    playerList[state.index] = player

    local token = generation
    state.playerConnections[1] = player.CharacterAdded:Connect(function(character)
        if token ~= generation or tracked[player] ~= state then return end
        state.lastDetected = nil
        state.animator, state.speed, state.position, state.positionAt = nil, nil, nil, nil
        table.clear(state.tracks)
        task.spawn(attachCharacter, player, state, character, token)
    end)

    if player.Character then task.spawn(attachCharacter, player, state, player.Character, token) end
end

local function removePlayer(player)
    local state = tracked[player]
    if not state then return end

    disconnect(state.playerConnections)
    disconnect(state.characterConnections)
    local index, last = state.index, #playerList
    if index ~= last then
        local swapped = playerList[last]
        playerList[index] = swapped
        tracked[swapped].index = index
    end
    playerList[last] = nil
    tracked[player] = nil
end

local function scanAnimations()
    for _, player in ipairs(playerList) do
        if player.Parent then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
            local state = tracked[player]
            if animator and state and state.animator ~= animator then
                local tracks = animator:GetPlayingAnimationTracks()
                for _, track in ipairs(tracks) do
                    if not state.tracks[track] and dashAnimation(track) then register(player, state) end
                end
                table.clear(state.tracks)
                for _, track in ipairs(tracks) do state.tracks[track] = true end
            end
        end
    end
end

local function scanVelocity(time)
    for _, player in ipairs(playerList) do
        if player.Parent then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            local state = tracked[player]
            if root and state then
                local velocity = root.AssemblyLinearVelocity

                if state.position and state.positionAt
                    and time > state.positionAt and time - state.positionAt <= 0.15 then
                    local measured = (root.Position - state.position) / (time - state.positionAt)
                    local measuredSpeed = horizontalSpeed(measured)
                    if measuredSpeed > horizontalSpeed(velocity) and measuredSpeed < 400 then
                        velocity = measured
                    end
                end

                local speed = horizontalSpeed(velocity)
                if state.speed ~= nil and speed >= T.VELOCITY_MIN_SPEED
                    and (state.speed < T.VELOCITY_MIN_SPEED
                        or speed - state.speed >= T.VELOCITY_MIN_INCREASE) then
                    register(player, state, root.Position, velocity)
                end

                state.speed = speed
                state.position = root.Position
                state.positionAt = time
            end
        end
    end
end

function Dash.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table"
        or type(deps.Utils.getPlayers) ~= "function" then
        return false, "dependência ausente: Utils"
    end

    Dash.resetState()
    Utils = deps.Utils
    local ok, service = pcall(Utils.getPlayers)
    if not ok or not service then
        Utils = nil
        return false, "Players indisponível"
    end

    players = service
    for _, player in ipairs(players:GetPlayers()) do addPlayer(player) end

    local token = generation
    connections[1] = players.PlayerAdded:Connect(function(player)
        if token == generation then addPlayer(player) end
    end)
    connections[2] = players.PlayerRemoving:Connect(function(player)
        if token == generation then removePlayer(player) end
    end)
    return true
end

function Dash.setHandler(handler)
    onDetected = type(handler) == "function" and handler or nil
    return true
end

function Dash.tick(time)
    if not players then return end
    if type(time) ~= "number" then time = now() end

    if time - lastCleanAt >= T.CLEAN_INTERVAL then
        lastCleanAt = time
        for player, state in pairs(tracked) do
            if not player.Parent or (state.lastDetected and time - state.lastDetected > T.DETECT_WINDOW) then
                state.lastDetected = nil
            end
        end
    end

    if time - lastScanAt >= T.ANIMATION_SCAN_INTERVAL then
        lastScanAt = time
        scanAnimations()
    end

    if time - lastVelocityAt >= T.VELOCITY_SCAN_INTERVAL then
        lastVelocityAt = time
        scanVelocity(time)
    end
end

function Dash.resetState()
    generation += 1
    disconnect(connections)
    for player in pairs(tracked) do removePlayer(player) end
    table.clear(playerList)
    table.clear(animationCache)
    players = nil
    lastScanAt, lastVelocityAt, lastCleanAt = 0, 0, 0
end

function Dash.teardown()
    Dash.resetState()
    Utils, onDetected = nil, nil
end

function Dash.getStatus()
    local schema = 1
    if Utils and type(Utils.apiVersion) == "function" then
        local ok, version = pcall(Utils.apiVersion)
        if ok and type(version) == "number" then schema = version end
    end
    return {schema = schema, players = players ~= nil, detecting = players ~= nil, playerCount = #playerList}
end

Dash.__contract = {
    requiresMethods = {Utils = {"getPlayers"}},
    provides = {"setup", "setHandler", "tick", "teardown"},
    requires = {Utils = "utils"},
}

return Dash
