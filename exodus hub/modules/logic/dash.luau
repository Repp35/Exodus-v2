-- [[ dash ]]

local Dash = {}

-- dependencies
local utils, gameInfo, players, handler
local records, connections = {}, {}
local generation, lastTick = 0, -math.huge

-- tuning
local T = {
	MIN_SPEED = 80,
	MIN_INCREASE = 15,
	MAX_MEASURED_SPEED = 400,
	MAX_SAMPLE_GAP = 0.15,
	SIGNAL_GRACE = 0.22,
	DETECTION_GAP = 0.25,
	TICK_INTERVAL = 1 / 120,
}

-- helpers
local function now() return utils and utils.now() or os.clock() end
local function horizontal(v) return math.sqrt(v.X * v.X + v.Z * v.Z) end
local function rootOf(player)
	local character = player.Character; return character and character:FindFirstChild("HumanoidRootPart")
end
local function disconnect(connection)
	if connection then connection:Disconnect() end
end
local function windEffect(root)
	local effect = root:FindFirstChild("WindDash")
	if not effect then return false end
	if effect:IsA("ParticleEmitter") or effect:IsA("Beam") or effect:IsA("Trail") then return effect.Enabled end
	for _, item in ipairs(effect:GetDescendants()) do
		if (item:IsA("ParticleEmitter") or item:IsA("Beam") or item:IsA("Trail")) and item.Enabled then return true end
	end
	return false
end
local function emit(player, record, position, velocity, previous, time)
	if time - (record.lastDetection or -math.huge) < T.DETECTION_GAP then return end
	record.lastDetection = time
	if handler then
		handler({
			player = player,
			userId = player.UserId,
			detectedAt = time,
			position = position,
			velocity = velocity,
			previousPosition = previous,
		})
	end
end
local function resetCharacter(record, character)
	disconnect(record.attributeConnection)
	record.character, record.attributeConnection = character, nil
	record.position, record.positionAt, record.speed, record.fast = nil, nil, nil, false
	record.lastDetection, record.signalAt, record.signalActive = nil, -math.huge, false
	record.effectActive = false
end
local function observe(player, record, time)
	local character = player.Character
	if record.character ~= character then resetCharacter(record, character) end
	if not character or not character.Parent then return end
	local root = rootOf(player)
	if not root then
		record.position, record.positionAt, record.speed, record.fast = nil, nil, nil, false
		return
	end
	local position, velocity = root.Position, root.AssemblyLinearVelocity; local previous, previousAt = record.position, record.positionAt; local delta = previousAt and time - previousAt
	if previous and delta and delta > 0 and delta <= T.MAX_SAMPLE_GAP then
		local measured = (position - previous) / delta
		if measured.Magnitude > velocity.Magnitude and measured.Magnitude < T.MAX_MEASURED_SPEED then velocity = measured end
	end
	local attribute = player ~= players.LocalPlayer and character:GetAttribute("IsDashing") == true; local ability = player == players.LocalPlayer and gameInfo and gameInfo.getDashAbility() or nil
	local localDash = ability and ability.Dashing == true or false; local signal = attribute or localDash
	if signal and not record.signalActive then record.signalAt = time end
	record.signalActive = signal; local effect = windEffect(root)
	if effect and not record.effectActive then record.signalAt = time end
	record.effectActive = effect; local speed, previousSpeed = velocity.Magnitude, record.speed or 0; local fast = speed >= T.MIN_SPEED
	local burst = fast and (not record.fast or speed - previousSpeed >= T.MIN_INCREASE); local signaled = time - record.signalAt <= T.SIGNAL_GRACE
	if (burst or (signaled and fast)) and (fast or horizontal(velocity) >= T.MIN_SPEED) then emit(player, record, position, velocity, previous, time) end
	record.speed, record.fast, record.position, record.positionAt = speed, fast, position, time
end
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
	for _, player in ipairs(players:GetPlayers()) do
		addPlayer(player)
	end
	return true
end
function Dash.setHandler(callback)
	handler = type(callback) == "function" and callback or nil; return true
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
	generation += 1; disconnect(connections.added); disconnect(connections.removing); connections = {}
	for player in pairs(records) do
		removePlayer(player)
	end
	players, lastTick = nil, -math.huge
end
function Dash.teardown()
	Dash.resetState(); utils, gameInfo, handler = nil, nil, nil
end
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
	requiresMethods = { Utils = { "getPlayers", "now" }, GameInfo = { "getDashAbility" } },
	provides = { "setup", "setHandler", "tick", "resetState", "teardown", "getStatus" },
}

return Dash
