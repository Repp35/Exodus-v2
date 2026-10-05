-- [[ dash ]]

-- Tuning
local Dash = {}
local Utils
local onDetected
local T = {
	DETECT_WINDOW = 0.25,
	REGISTER_DEBOUNCE = 0.05,
	ANIMATION_SCAN_INTERVAL = 1 / 30,
	VELOCITY_SCAN_INTERVAL = 1 / 30,
	CLEAN_INTERVAL = 0.10,
	VELOCITY_MIN_SPEED = 80,
	VELOCITY_MIN_INCREASE = 15,
}

local R = {
	players = nil,
	playerList = {},
	playerIndex = {},
	-- Lifecycle
	generation = 0,

	-- Timers
	lastScanAt = 0,
	lastVelocityScanAt = 0,
	lastCleanAt = 0,

	-- Connections
	connections = {},
	playerConnections = {},
	characterConnections = {},
	cooldown = {},
	trackSnapshot = {},
	previousSpeed = {},
	lastPosition = {},

	-- Cache
	animationMatchCache = setmetatable({}, {
		__mode = "k",
	}),
}

local function now()
	if Utils then
		local getNow = Utils.now
		if type(getNow) == "function" then
			local ok, value = pcall(getNow)
			if ok and type(value) == "number" then return value end
		end
	end
	return os.clock()
end
local function horizontalSpeed(velocity)
	if typeof(velocity) ~= "Vector3" then return 0 end
	local x = velocity.X; local z = velocity.Z; return math.sqrt(x * x + z * z)
end
local function disconnectList(list)
	if not list then return end
	for i = #list, 1, -1 do
		local connection = list[i]; list[i] = nil
		if connection then pcall(connection.Disconnect, connection) end
	end
end
local function disconnectPlayerConnections(player)
	local characterConnections = R.characterConnections[player]
	if characterConnections then disconnectList(characterConnections); R.characterConnections[player] = nil end
	local playerConnections = R.playerConnections[player]
	if playerConnections then disconnectList(playerConnections); R.playerConnections[player] = nil end
end
local function addCharacterConnection(player, connection)
	if not connection then return end
	local list = R.characterConnections[player]
	if not list then list = {}; R.characterConnections[player] = list end
	list[#list + 1] = connection
end
local function addPlayerConnection(player, connection)
	if not connection then return end
	local list = R.playerConnections[player]
	if not list then list = {}; R.playerConnections[player] = list end
	list[#list + 1] = connection
end
local function isDashTrack(track)
	if not track or not track:IsA("AnimationTrack") then return false end
	local animation = track.Animation
	if not animation then return false end
	local cached = R.animationMatchCache[animation]
	if cached ~= nil then return cached end
	local name = string.lower(animation.Name or ""); local id = string.lower(animation.AnimationId or ""); local result = name:find("dash", 1, true) ~= nil or id:find("dash", 1, true) ~= nil
	R.animationMatchCache[animation] = result; return result
end
local function cleanCooldowns(t)
	for player, lastDetected in pairs(R.cooldown) do
		if not player.Parent or t - lastDetected > T.DETECT_WINDOW then R.cooldown[player] = nil end
	end
end
local function register(player, position, velocity)
	if not player or not player.Parent then return end
	local t = now(); local lastDetected = R.cooldown[player]
	if lastDetected and (t - lastDetected) < T.DETECT_WINDOW then return end
	local character = player.Character; local root = character and character:FindFirstChild("HumanoidRootPart")
	if typeof(position) ~= "Vector3" and root then position = root.Position end
	if typeof(velocity) ~= "Vector3" and root then velocity = root.AssemblyLinearVelocity end
	R.cooldown[player] = t; local previousPosition = R.lastPosition[player]
	local event = {
		player = player,
		userId = player.UserId,
		detectedAt = t,
		position = position,
		velocity = velocity,
		previousPosition = previousPosition,
	}

	if typeof(position) == "Vector3" then R.lastPosition[player] = position end
	if type(onDetected) == "function" then pcall(onDetected, event) end
end
local function hookAnimator(animator, player, character, generation)
	if
		not animator
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
			if generation ~= R.generation or not player.Parent or player.Character ~= character then return end
			if isDashTrack(track) then register(player) end
		end)
	)
	local snapshot = R.trackSnapshot[player]
	if not snapshot then snapshot = {}; R.trackSnapshot[player] = snapshot
	else table.clear(snapshot) end
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		snapshot[track] = true
	end
end
local function attachCharacter(character, player, generation)
	if
		generation ~= R.generation
		or not character
		or not player
		or not player.Parent
		or player.Character ~= character
	then
		return
	end
	local oldCharacterConnections = R.characterConnections[player]
	if oldCharacterConnections then disconnectList(oldCharacterConnections); R.characterConnections[player] = nil end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 3)
	if generation ~= R.generation or not player.Parent or player.Character ~= character or not humanoid then return end
	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 3)
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 3)
	if generation ~= R.generation or not player.Parent or player.Character ~= character or not root then return end
	if animator then hookAnimator(animator, player, character, generation) end
	R.previousSpeed[player] = horizontalSpeed(root.AssemblyLinearVelocity); R.lastPosition[player] = root.Position
end
local function scanTracks()
	for i = 1, #R.playerList do
		local player = R.playerList[i]
		if player and player.Parent then
			local character = player.Character; local humanoid = character and character:FindFirstChildOfClass("Humanoid"); local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			if animator then
				local currentTracks = animator:GetPlayingAnimationTracks(); local snapshot = R.trackSnapshot[player]
				if not snapshot then snapshot = {}; R.trackSnapshot[player] = snapshot end
				for _, track in ipairs(currentTracks) do
					if not snapshot[track] and isDashTrack(track) then register(player) end
				end
				table.clear(snapshot)
				for _, track in ipairs(currentTracks) do
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
			local character = player.Character; local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				local velocity = root.AssemblyLinearVelocity; local speed = horizontalSpeed(velocity); local previousSpeed = R.previousSpeed[player]
				if previousSpeed == nil then
					R.previousSpeed[player] = speed
				else
					if speed >= T.VELOCITY_MIN_SPEED and speed - previousSpeed >= T.VELOCITY_MIN_INCREASE then register(player, root.Position, velocity) end
					R.previousSpeed[player] = speed
				end
				R.lastPosition[player] = root.Position
			end
		end
	end
end
local function addPlayer(player)
	if not player or not player.Parent then return end
	if R.playerIndex[player] then return end
	local index = #R.playerList + 1; R.playerList[index] = player; R.playerIndex[player] = index; R.trackSnapshot[player] = {}
	R.previousSpeed[player] = nil; R.lastPosition[player] = nil; local generation = R.generation
	if player.Character then task.spawn(attachCharacter, player.Character, player, generation) end
	addPlayerConnection(
		player,
		player.CharacterAdded:Connect(function(character)
			if generation ~= R.generation then return end
			task.spawn(attachCharacter, character, player, generation)
		end)
	)
end
local function removePlayer(player)
	if not player then return end
	disconnectPlayerConnections(player); local index = R.playerIndex[player]
	if index then
		local lastIndex = #R.playerList; local lastPlayer = R.playerList[lastIndex]
		if index ~= lastIndex then R.playerList[index] = lastPlayer; R.playerIndex[lastPlayer] = index end
		R.playerList[lastIndex] = nil; R.playerIndex[player] = nil
	end
	R.cooldown[player] = nil; R.trackSnapshot[player] = nil; R.previousSpeed[player] = nil; R.lastPosition[player] = nil
end

-- Setup
function Dash.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.Utils.getPlayers) ~= "function" then return false, "dependência ausente: Utils" end
	Dash.resetState(); Utils = deps.Utils; local okPlayers, players = pcall(Utils.getPlayers)
	if not okPlayers or not players then Utils = nil; return false, "Players indisponível" end
	R.players = players; local generation = R.generation
	for _, player in ipairs(players:GetPlayers()) do
		addPlayer(player)
	end
	R.connections[#R.connections + 1] = players.PlayerAdded:Connect(function(player)
		if generation == R.generation then addPlayer(player) end
	end)
	R.connections[#R.connections + 1] = players.PlayerRemoving:Connect(function(player)
		if generation == R.generation then removePlayer(player) end
	end)
	return true
end

-- API
function Dash.setHandler(handler)
	onDetected = type(handler) == "function" and handler or nil; return true
end
function Dash.tick(t)
	if not R.players then return end
	if type(t) ~= "number" then t = now() end
	if t - R.lastCleanAt >= T.CLEAN_INTERVAL then R.lastCleanAt = t; cleanCooldowns(t) end
	if t - R.lastScanAt >= T.ANIMATION_SCAN_INTERVAL then R.lastScanAt = t; scanTracks() end
	if t - R.lastVelocityScanAt >= T.VELOCITY_SCAN_INTERVAL then R.lastVelocityScanAt = t; scanVelocity() end
end
function Dash.resetState()
	R.generation += 1; disconnectList(R.connections)
	for player, connections in pairs(R.characterConnections) do
		disconnectList(connections); R.characterConnections[player] = nil
	end
	for player, connections in pairs(R.playerConnections) do
		disconnectList(connections); R.playerConnections[player] = nil
	end
	table.clear(R.playerList); table.clear(R.playerIndex); table.clear(R.cooldown); table.clear(R.trackSnapshot)
	table.clear(R.previousSpeed); table.clear(R.lastPosition); table.clear(R.animationMatchCache); R.players = nil
	R.lastScanAt = 0; R.lastVelocityScanAt = 0; R.lastCleanAt = 0
end
function Dash.teardown()
	Dash.resetState(); Utils = nil; onDetected = nil
end
function Dash.getStatus()
	local schema = 1
	if Utils and type(Utils.apiVersion) == "function" then
		local ok, version = pcall(Utils.apiVersion)
		if ok and type(version) == "number" then schema = version end
	end
	return {
		schema = schema,
		players = R.players ~= nil,
		detecting = R.players ~= nil,
		playerCount = #R.playerList,
	}

end
Dash.__contract = {
	requires = {
		Utils = "utils",
	},

}

return Dash
