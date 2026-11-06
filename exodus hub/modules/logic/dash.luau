-- [[ dash ]]

local Dash = {}

local utils, players, onDetected
local playerConnections, records, order = {}, {}, {}
local lastScan, generation = 0, 0
local MIN_SPEED, MIN_INCREASE, DETECT_WINDOW = 80, 15, 0.25
local function now()
	if utils and type(utils.now) == "function" then
		local ok, value = pcall(utils.now)
		if ok and type(value) == "number" then
			return value
		end
	end
	return os.clock()
end
local function horizontal(vector)
	if typeof(vector) ~= "Vector3" then
		return 0
	end
	return math.sqrt(vector.X * vector.X + vector.Z * vector.Z)
end
local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end
local function rootOf(player)
	local character = player and player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end
local function dashAnimation(track)
	if not track or not track:IsA("AnimationTrack") or not track.Animation then
		return false
	end
	local animation = track.Animation
	return string.find(string.lower(animation.Name or ""), "dash", 1, true) ~= nil
		or string.find(string.lower(animation.AnimationId or ""), "dash", 1, true) ~= nil
end
local function register(player, record, position, velocity, time)
	if not player.Parent or records[player] ~= record then
		return
	end
	if record.lastDetection and time - record.lastDetection < DETECT_WINDOW then
		return
	end
	local root = rootOf(player)
	position = typeof(position) == "Vector3" and position or (root and root.Position)
	velocity = typeof(velocity) == "Vector3" and velocity or (root and root.AssemblyLinearVelocity)
	if horizontal(velocity) < MIN_SPEED then
		return
	end
	record.lastDetection = time
	local previous = record.position
	if typeof(position) == "Vector3" then
		record.position = position
	end
	if onDetected then
		onDetected({ player = player, userId = player.UserId, detectedAt = time, position = position, velocity = velocity, previousPosition = previous })
	end
end
local function resetCharacter(record, character)
	disconnect(record.animationConnection)
	record.character, record.animator, record.animationConnection = character, nil, nil
	record.speed, record.position, record.positionAt, record.lastDetection = nil, nil, nil, nil
end
local function observeCharacter(player, record, time)
	local character = player.Character
	if record.character ~= character then
		resetCharacter(record, character)
	end
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator ~= record.animator then
		disconnect(record.animationConnection)
		record.animator = animator
		record.animationConnection = nil
		if animator then
			local capturedGeneration = generation
			record.animationConnection = animator.AnimationPlayed:Connect(function(track)
				if capturedGeneration == generation and player.Character == record.character and dashAnimation(track) then
					register(player, record, nil, nil, now())
				end
			end)
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				if dashAnimation(track) then
					register(player, record, nil, nil, time)
				end
			end
		end
	end
	local root = rootOf(player)
	if not root then
		record.speed, record.position, record.positionAt = nil, nil, nil
		return
	end
	local position, velocity = root.Position, root.AssemblyLinearVelocity
	if record.position and record.positionAt and time > record.positionAt and time - record.positionAt <= 0.15 then
		local measured = (position - record.position) / (time - record.positionAt)
		if horizontal(measured) > horizontal(velocity) and horizontal(measured) < 400 then
			velocity = measured
		end
	end
	local speed, previous = horizontal(velocity), record.speed
	if speed >= MIN_SPEED and (previous == nil or previous < MIN_SPEED or speed - previous >= MIN_INCREASE) then
		register(player, record, position, velocity, time)
	end
	record.speed, record.position, record.positionAt = speed, position, time
end
local function addPlayer(player)
	if records[player] then
		return
	end
	local record = { character = nil }
	records[player] = record
	table.insert(order, player)
	table.sort(order, function(a, b)
		return a.UserId < b.UserId
	end)
	playerConnections[player] = player.CharacterAdded:Connect(function(character)
		if records[player] == record then
			resetCharacter(record, character)
		end
	end)
end
local function removePlayer(player)
	local record = records[player]
	if not record then
		return
	end
	records[player] = nil
	disconnect(record.animationConnection)
	disconnect(playerConnections[player])
	playerConnections[player] = nil
	local index = table.find(order, player)
	if index then
		table.remove(order, index)
	end
end
function Dash.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.Utils.getPlayers) ~= "function" then
		return false, "dependência ausente: Utils"
	end
	Dash.resetState()
	utils = deps.Utils
	players = utils.getPlayers()
	if not players then
		utils = nil
		return false, "Players indisponível"
	end
	local capturedGeneration = generation
	playerConnections.added = players.PlayerAdded:Connect(function(player)
		if capturedGeneration == generation then
			addPlayer(player)
		end
	end)
	playerConnections.removing = players.PlayerRemoving:Connect(function(player)
		if capturedGeneration == generation then
			removePlayer(player)
		end
	end)
	for _, player in ipairs(players:GetPlayers()) do
		addPlayer(player)
	end
	return true
end
function Dash.setHandler(handler)
	onDetected = type(handler) == "function" and handler or nil
	return true
end
function Dash.tick(time)
	if not players then
		return
	end
	if type(time) ~= "number" then
		time = now()
	end
	if time >= lastScan and time - lastScan < 1 / 120 then
		return
	end
	lastScan = time
	for _, player in ipairs(order) do
		local record = records[player]
		if record and player.Parent then
			observeCharacter(player, record, time)
		end
	end
end
function Dash.resetState()
	generation += 1
	disconnect(playerConnections.added)
	disconnect(playerConnections.removing)
	for _, player in ipairs(order) do
		local record = records[player]
		if record then
			disconnect(record.animationConnection)
		end
		disconnect(playerConnections[player])
	end
	table.clear(playerConnections)
	table.clear(records)
	table.clear(order)
	players, lastScan = nil, 0
end
function Dash.teardown()
	Dash.resetState()
	utils, onDetected = nil, nil
end
function Dash.getStatus()
	return { schema = utils and utils.apiVersion and utils.apiVersion() or 1, players = players ~= nil, detecting = players ~= nil, playerCount = #order }
end
Dash.__contract = {
	requires = { Utils = "utils" },
	requiresMethods = { Utils = { "getPlayers" } },
	provides = { "setup", "setHandler", "tick", "teardown" },
}

return Dash
