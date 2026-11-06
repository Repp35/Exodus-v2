-- [[ dash ]]

local Dash = {}

-- dependencies and state
local utils, players, handler
local records, connections = {}, {}
local generation, lastTick = 0, -math.huge

-- tuning
local T = {
	MIN_SPEED = 80,
	MIN_INCREASE = 15,
	MAX_MEASURED_SPEED = 400,
	MAX_SAMPLE_GAP = 0.15,
	ANIMATION_GRACE = 0.20,
	DETECTION_GAP = 0.25,
	TICK_INTERVAL = 1 / 120,
}

-- helpers
local function now() return utils and utils.now() or os.clock() end
local function horizontal(v)
	if typeof(v) ~= "Vector3" then return 0 end
	return math.sqrt(v.X * v.X + v.Z * v.Z)
end
local function rootOf(player)
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end
local function isDashAnimation(track)
	local animation = track and track.Animation
	if not animation then return false end
	local name = string.lower(animation.Name or "")
	local id = string.lower(animation.AnimationId or "")
	return name:find("dash", 1, true) ~= nil or id:find("dash", 1, true) ~= nil
end
local function disconnect(connection)
	if connection then connection:Disconnect() end
end

-- event dispatch
local function emit(player, record, position, velocity, time)
	if not handler or time - (record.lastDetection or -math.huge) < T.DETECTION_GAP then return end
	record.lastDetection = time
	handler({
		player = player,
		userId = player.UserId,
		detectedAt = time,
		position = position,
		velocity = velocity,
		previousPosition = record.previousPosition,
	})
end

-- character tracking
local function resetCharacter(record, character)
	disconnect(record.animationConnection)
	record.character, record.animator, record.animationConnection = character, nil, nil
	record.root, record.position, record.positionAt = nil, nil, nil
	record.speed, record.movingFast, record.animationUntil = nil, false, 0
	record.previousPosition = nil
end
local function watchAnimator(player, record, time)
	local humanoid = record.character and record.character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator == record.animator then return end
	disconnect(record.animationConnection)
	record.animator, record.animationConnection = animator, nil
	if not animator then return end

	local token = generation
	record.animationConnection = animator.AnimationPlayed:Connect(function(track)
		if token ~= generation or records[player] ~= record or player.Character ~= record.character then return end
		if isDashAnimation(track) then record.animationUntil = now() + T.ANIMATION_GRACE end
	end)
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if isDashAnimation(track) then
			record.animationUntil = time + T.ANIMATION_GRACE
			break
		end
	end
end

-- motion detection
local function observe(player, record, time)
	local character = player.Character
	if record.character ~= character then resetCharacter(record, character) end
	if not character or not character.Parent then return end
	watchAnimator(player, record, time)

	local root = rootOf(player)
	if not root then
		record.position, record.positionAt, record.speed, record.movingFast = nil, nil, nil, false
		return
	end
	local position, velocity = root.Position, root.AssemblyLinearVelocity
	local previousPosition, previousTime = record.position, record.positionAt
	local delta = previousTime and (time - previousTime) or nil
	if previousPosition and delta and delta > 0 and delta <= T.MAX_SAMPLE_GAP then
		local measured = (position - previousPosition) / delta
		local measuredSpeed = horizontal(measured)
		if measuredSpeed > horizontal(velocity) and measuredSpeed < T.MAX_MEASURED_SPEED then velocity = measured end
	end

	local speed = horizontal(velocity)
	local previousSpeed = record.speed or 0
	local fast = speed >= T.MIN_SPEED
	local began = fast and not record.movingFast
	local burst = fast and speed - previousSpeed >= T.MIN_INCREASE
	local animation = fast and time <= record.animationUntil and not record.animationDetected
	if began or burst or animation then
		record.previousPosition = previousPosition
		emit(player, record, position, velocity, time)
		if animation then record.animationDetected = true end
	end
	if time > record.animationUntil then record.animationDetected = false end
	record.movingFast, record.speed, record.position, record.positionAt = fast, speed, position, time
end

-- player lifecycle
local function removePlayer(player)
	local record = records[player]
	if not record then return end
	disconnect(record.animationConnection)
	disconnect(record.characterConnection)
	records[player] = nil
end
local function addPlayer(player)
	if records[player] then return end
	local record = { character = nil, movingFast = false, animationUntil = 0, animationDetected = false }
	records[player] = record
	record.characterConnection = player.CharacterAdded:Connect(function(character)
		if records[player] == record then resetCharacter(record, character) end
	end)
end

-- public API
function Dash.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.Utils.getPlayers) ~= "function" then
		return false, "dependência ausente: Utils"
	end
	Dash.teardown()
	utils, players = deps.Utils, deps.Utils.getPlayers()
	if not players then return false, "Players indisponível" end
	local token = generation
	connections.added = players.PlayerAdded:Connect(function(player)
		if token == generation then addPlayer(player) end
	end)
	connections.removing = players.PlayerRemoving:Connect(function(player)
		if token == generation then removePlayer(player) end
	end)
	for _, player in ipairs(players:GetPlayers()) do addPlayer(player) end
	return true
end
function Dash.setHandler(callback)
	handler = type(callback) == "function" and callback or nil
	return true
end
function Dash.tick(time)
	if not players then return end
	time = type(time) == "number" and time or now()
	if time - lastTick < T.TICK_INTERVAL then return end
	lastTick = time
	for player, record in pairs(records) do
		if player.Parent then observe(player, record, time) end
	end
end
function Dash.resetState()
	generation += 1
	disconnect(connections.added); disconnect(connections.removing)
	connections = {}
	for player in pairs(records) do removePlayer(player) end
	players, lastTick = nil, -math.huge
end
function Dash.teardown()
	Dash.resetState()
	utils, handler = nil, nil
end
function Dash.getStatus()
	local count = 0
	for _ in pairs(records) do count += 1 end
	return { schema = utils and utils.apiVersion and utils.apiVersion() or 1, players = players ~= nil, detecting = players ~= nil, playerCount = count }
end

-- contract
Dash.__contract = {
	requires = { Utils = "utils" },
	requiresMethods = { Utils = { "getPlayers" } },
	provides = { "setup", "setHandler", "tick", "resetState", "teardown", "getStatus" },
}

return Dash
