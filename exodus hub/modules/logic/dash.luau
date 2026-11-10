-- [[ dash ]]

local Dash = {}

-- dependencies
local utils, gameInfo, players, handler

-- state
local records, connections = {}, {}
local generation, lastTick = 0, -math.huge

-- tuning
local T = {
	MIN_SPEED = 70,
	MAX_MEASURED_SPEED = 400,
	MAX_SAMPLE_GAP = 0.15,
	SIGNAL_GRACE = 0.22,
	DETECTION_GAP = 0.06,
	TICK_INTERVAL = 1 / 120,
}

-- helpers
local function now() return utils and utils.now() or os.clock() end
local function rootOf(player)
	local character = player.Character; return character and character:FindFirstChild("HumanoidRootPart")
end
local function disconnect(connection)
	if connection then
		if utils then utils.untrackGlobal(connection) end
		connection:Disconnect()
	end
end
local function emit(player, record, position, velocity, previous, time, confirmed)
	local newConfirmation = confirmed and record.confirmedSignalAt ~= record.signalAt
	if not newConfirmation and time - (record.lastDetection or -math.huge) < T.DETECTION_GAP then return end
	if confirmed then record.confirmedSignalAt = record.signalAt end
	record.lastDetection = time
	if handler then
		handler({
			player = player,
			userId = player.UserId,
			detectedAt = time,
			position = position,
			velocity = velocity,
			confirmed = confirmed,
			signalAt = record.signalAt,
			signalActive = record.signalActive,
			previousPosition = previous,
		})
	end
end
local function resetCharacter(record, character)
	record.character = character
	record.position, record.positionAt, record.speed, record.fast = nil, nil, nil, false
	record.lastDetection, record.signalAt, record.signalActive, record.confirmedSignalAt = nil, -math.huge, false, nil
end
local function observe(player, record, time, suppliedRoot)
	local character = player.Character
	if record.character ~= character then resetCharacter(record, character) end
	if not character or not character.Parent then return end
	local root = suppliedRoot or rootOf(player)
	if not root then
		record.position, record.positionAt, record.speed, record.fast = nil, nil, nil, false
		return
	end
	local position, velocity = root.Position, root.AssemblyLinearVelocity; local previous, previousAt = record.position, record.positionAt; local delta = previousAt and time - previousAt
	if previous and delta and delta > 0 and delta <= T.MAX_SAMPLE_GAP then
		local measured = (position - previous) / delta
		if measured.Magnitude > velocity.Magnitude and measured.Magnitude < T.MAX_MEASURED_SPEED then velocity = measured end
	end
	local signal = gameInfo.isPlayerDashing(player)
	if signal and not record.signalActive then record.signalAt = time end
	record.signalActive = signal; local speed = velocity.Magnitude; local fast = speed >= T.MIN_SPEED; local signaled = signal or time - record.signalAt <= T.SIGNAL_GRACE
	if signaled and fast then emit(player, record, position, velocity, previous, time, true) end
	record.speed, record.fast, record.position, record.positionAt = speed, fast, position, time
end

-- lifecycle
local function removePlayer(player)
	local record = records[player]
	if not record then return end
	resetCharacter(record, nil); disconnect(record.characterConnection); records[player] = nil
end
local function addPlayer(player)
	if records[player] then return end
	local record = { signalAt = -math.huge }; records[player] = record
	record.characterConnection = player.CharacterAdded:Connect(function(character)
		if records[player] == record then resetCharacter(record, character) end
	end)
	utils.trackGlobal(record.characterConnection)
end
function Dash.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependências ausentes: Utils ou GameInfo" end
	Dash.teardown(); utils, gameInfo, players = deps.Utils, deps.GameInfo, deps.Utils.getPlayers()
	if not players then return false, "Players indisponível" end
	local token = generation
	connections.added = players.PlayerAdded:Connect(function(player)
		if token == generation then addPlayer(player) end
	end)
	connections.removing = players.PlayerRemoving:Connect(function(player)
		if token == generation then removePlayer(player) end
	end)
	utils.trackGlobal(connections.added); utils.trackGlobal(connections.removing)
	for _, player in ipairs(players:GetPlayers()) do
		addPlayer(player)
	end
	return true
end
function Dash.setHandler(callback)
	handler = type(callback) == "function" and callback or nil; return true
end
function Dash.tick(time, excludeLocal, center, radius)
	if not players then return end
	time = type(time) == "number" and time or now()
	if time - lastTick < T.TICK_INTERVAL then return end
	lastTick = time
	if type(center) == "number" then
		local player = players:GetPlayerByUserId(center); local record = player and records[player]
		if record and player.Parent and (not excludeLocal or player ~= players.LocalPlayer) then observe(player, record, time) end
		return
	end
	local limit = typeof(center) == "Vector3" and type(radius) == "number" and radius > 0 and radius * radius or nil
	for player, record in pairs(records) do
		if player.Parent and (not excludeLocal or player ~= players.LocalPlayer) then
			if not limit then
				observe(player, record, time)
			else
				local root = rootOf(player)
				if root and root.Parent then
					local delta = root.Position - center
					if delta:Dot(delta) <= limit then
						observe(player, record, time, root)
					else
						record.position, record.positionAt, record.signalActive, record.signalAt = nil, nil, false, -math.huge
					end
				end
			end
		end
	end
end
function Dash.resetState()
	generation += 1; disconnect(connections.added); disconnect(connections.removing); connections = {}
	for player in pairs(records) do
		removePlayer(player)
	end
	players, lastTick = nil, -math.huge
end
function Dash.teardown()
	Dash.resetState(); utils, gameInfo, handler = nil, nil, nil
end

-- status
function Dash.getStatus()
	local count = 0
	for _ in pairs(records) do
		count += 1
	end
	return { schema = utils and utils.apiVersion and utils.apiVersion() or 1, players = players ~= nil, detecting = players ~= nil, playerCount = count }
end

-- contract
Dash.__contract = {
	requires = { Utils = "utils", GameInfo = "gameinfo" },
	requiresMethods = { Utils = { "apiVersion", "getPlayers", "now", "trackGlobal", "untrackGlobal" }, GameInfo = { "isPlayerDashing" } },
	provides = { "setup", "setHandler", "tick", "resetState", "teardown", "getStatus" },
}

return Dash
