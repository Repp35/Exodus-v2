--[=[
BallSync diagnostic for PhantomBallz

Run this as a one-off client-side Luau script while in a live match. It only
observes sync-related RemoteEvents and replicated tables for 30 seconds. It
does not send remotes or mutate game state.

Output file: BallSyncDiagnostic.txt (executor working directory)
Console prefix: [BallSyncDiag]
Stop early with: _G.ExodusBallSyncDiagnostic.stop()
]=]

local TAG = "[BallSyncDiag]"
local LOG_PATH = "BallSyncDiagnostic.txt"
local DURATION = 30
local POLL_INTERVAL = 0.5
local MAX_DEPTH = 5
local MAX_NODES = 300
local MAX_LINES = 6000
local MAX_SAMPLES_PER_REMOTE = 12

local old = rawget(_G, "ExodusBallSyncDiagnostic")
if type(old) == "table" and type(old.stop) == "function" then
	pcall(old.stop)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local startedAt = os.clock()
local stopped = false
local lines = {}
local truncated = false
local eventConnections = {}
local lastReplicatorSignature
local lastGameInfoSignature

local function saveFile()
	if type(writefile) ~= "function" then return false, "writefile unavailable" end
	local ok, err = pcall(writefile, LOG_PATH, table.concat(lines, "\n") .. "\n")
	return ok, ok and nil or tostring(err)
end

local function log(message)
	message = tostring(message)
	if #lines < MAX_LINES then
		lines[#lines + 1] = message
	elseif not truncated then
		truncated = true
		lines[#lines + 1] = "[output truncated: line cap reached]"
	end
	print(TAG .. " " .. message)
end

local function getChild(parent, name)
	if not parent then return nil end
	local ok, child = pcall(function() return parent:FindFirstChild(name) end)
	return ok and child or nil
end

local function safePath(instance)
	if typeof(instance) ~= "Instance" then return "nil" end
	local ok, value = pcall(function() return instance:GetFullName() end)
	return ok and value or "<path unavailable>"
end

local function safeRequire(instance)
	if not instance or not instance:IsA("ModuleScript") then return nil, "module_missing" end
	local ok, result = pcall(require, instance)
	if not ok then return nil, "require_failed: " .. tostring(result) end
	if type(result) ~= "table" then return nil, "module_returned_" .. type(result) end
	return result
end

local function sortedKeys(value)
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function appendTree(value, label, depth, visited, nodeCount, output)
	depth = depth or 0
	visited = visited or {}
	nodeCount = nodeCount or { count = 0 }
	output = output or {}
	nodeCount.count += 1
	local indent = string.rep("  ", depth)
	local kind = typeof(value)

	if kind == "Instance" then
		output[#output + 1] = ("%s%s: Instance<%s> %s"):format(indent, label, value.ClassName, safePath(value))
		return output, nodeCount
	end
	if type(value) ~= "table" then
		output[#output + 1] = ("%s%s: typeof=%s type=%s"):format(indent, label, tostring(kind), type(value))
		return output, nodeCount
	end
	if visited[value] then
		output[#output + 1] = ("%s%s: table<cycle>"):format(indent, label)
		return output, nodeCount
	end
	if depth >= MAX_DEPTH then
		output[#output + 1] = ("%s%s: table<depth-limit>"):format(indent, label)
		return output, nodeCount
	end
	if nodeCount.count >= MAX_NODES then
		output[#output + 1] = ("%s%s: table<node-limit>"):format(indent, label)
		return output, nodeCount
	end

	visited[value] = true
	local keys = sortedKeys(value)
	output[#output + 1] = ("%s%s: table (%d keys)"):format(indent, label, #keys)
	for _, key in ipairs(keys) do
		if nodeCount.count >= MAX_NODES then
			output[#output + 1] = indent .. "  ... node limit reached"
			break
		end
		local ok, item = pcall(function() return value[key] end)
		local keyLabel = "[" .. tostring(key) .. "]"
		if not ok then
			output[#output + 1] = indent .. "  " .. keyLabel .. ": <read failed>"
		else
			appendTree(item, keyLabel, depth + 1, visited, nodeCount, output)
		end
	end
	visited[value] = nil
	return output, nodeCount
end

local function structure(value, label)
	local output = appendTree(value, label, 0, {}, { count = 0 }, {})
	return table.concat(output, "\n")
end

local function recordStructure(label, value)
	local text = structure(value, label)
	log(text)
	return text
end

local function safeSignature(value)
	return structure(value, "payload")
end

local remoteConnections = {}
local function inspectEvent(remote, ...)
	local state = remoteConnections[remote]
	if not state or state.samples >= MAX_SAMPLES_PER_REMOTE then return end
	state.events += 1
	local argCount = select("#", ...)
	local sections = { ("%s args=%d"):format(state.path, argCount) }
	for index = 1, argCount do
		local value = select(index, ...)
		sections[#sections + 1] = structure(value, "arg" .. tostring(index))
	end
	local signature = table.concat(sections, "\n")
	if signature ~= state.lastSignature then
		state.lastSignature = signature
		state.samples += 1
		log("EVENT SHAPE\n" .. signature)
	end
end

local function stop(reason)
	if stopped then return end
	stopped = true
	for _, connection in ipairs(eventConnections) do
		pcall(function() connection:Disconnect() end)
	end
	eventConnections = {}
	log("observation ended: " .. tostring(reason or "manual"))
	local ok, err = saveFile()
	if ok then print(TAG .. " saved " .. LOG_PATH)
	else warn(TAG .. " could not save TXT: " .. tostring(err)) end
end

local api = { stop = stop }
_G.ExodusBallSyncDiagnostic = api

local okInitial, initialError = saveFile()
log("start; placeId=" .. tostring(game.PlaceId) .. "; gameId=" .. tostring(game.GameId) .. "; player=" .. (LocalPlayer and tostring(LocalPlayer.UserId) or "nil"))
if not okInitial then log("TXT write unavailable at start: " .. tostring(initialError)) end

local ts = getChild(ReplicatedStorage, "TS")
local remotes = getChild(ReplicatedStorage, "Remotes")
local gameInfoModule = getChild(ts, "GameInfo")
local ballReplicatorFolder = getChild(ts, "BallReplicator")
local ballReplicatorModule = getChild(ballReplicatorFolder, "BallReplicator")

local gameInfo, gameInfoError = safeRequire(gameInfoModule)
if gameInfo then
	local provider = gameInfo.GameInfo
	local ball = type(provider) == "table" and provider.BallModel or nil
	lastGameInfoSignature = safeSignature(provider)
	log("TS.GameInfo module=" .. safePath(gameInfoModule))
	recordStructure("TS.GameInfo.GameInfo", provider)
	log("BallModel class=" .. (typeof(ball) == "Instance" and ball.ClassName or tostring(typeof(ball))) .. "; path=" .. safePath(ball))
else
	log("TS.GameInfo unavailable: " .. tostring(gameInfoError))
end

local ballReplicator, ballReplicatorError = safeRequire(ballReplicatorModule)
if ballReplicator then
	local provider = ballReplicator.BallReplicator
	local syncData = type(provider) == "table" and provider.syncData or nil
	lastReplicatorSignature = safeSignature(syncData)
	log("TS.BallReplicator module=" .. safePath(ballReplicatorModule))
	recordStructure("TS.BallReplicator.BallReplicator.syncData", syncData)
else
	log("TS.BallReplicator unavailable: " .. tostring(ballReplicatorError))
end

-- Inventory replicated remotes and module names without requiring unknown modules.
local syncKeywords = { "sync", "replicat" }
local function looksSyncRelated(instance)
	local text = (instance.Name .. " " .. safePath(instance)):lower()
	for _, keyword in ipairs(syncKeywords) do
		if string.find(text, keyword, 1, true) then return true end
	end
	return false
end

local descendants = {}
pcall(function() descendants = ReplicatedStorage:GetDescendants() end)
for _, instance in ipairs(descendants) do
	if instance:IsA("RemoteEvent") and looksSyncRelated(instance) then
		local path = safePath(instance)
		log(("SYNC REMOTE: %s (%s)"):format(path, instance.ClassName))
		local state = { path = path, events = 0, samples = 0, lastSignature = nil }
		remoteConnections[instance] = state
		local connected, connection = pcall(function()
			return instance.OnClientEvent:Connect(function(...) inspectEvent(instance, ...) end)
		end)
		if connected and connection then
			eventConnections[#eventConnections + 1] = connection
		else
			log("could not observe " .. path .. ": " .. tostring(connection))
		end
	end
end

for _, instance in ipairs(descendants) do
	if instance:IsA("ModuleScript") and looksSyncRelated(instance) then
		log(("SYNC MODULE (listed, not required): %s"):format(safePath(instance)))
	end
end

if not remotes then log("ReplicatedStorage.Remotes folder not found") end
if not next(remoteConnections) then log("No sync-named RemoteEvents found under ReplicatedStorage") end
log(("listening for %d sync-related RemoteEvents for %d seconds"):format(#eventConnections, DURATION))

-- Poll public replicated tables and periodically flush the complete TXT.
task.spawn(function()
	while not stopped and os.clock() - startedAt < DURATION do
		if ballReplicator then
			local provider = ballReplicator.BallReplicator
			local syncData = type(provider) == "table" and provider.syncData or nil
			local signature = safeSignature(syncData)
			if signature ~= lastReplicatorSignature then
				lastReplicatorSignature = signature
				recordStructure("TS.BallReplicator.BallReplicator.syncData (changed)", syncData)
			end
		end
		if gameInfo then
			local provider = gameInfo.GameInfo
			local ball = type(provider) == "table" and provider.BallModel or nil
			local signature = safeSignature(provider)
			if signature ~= lastGameInfoSignature then
				lastGameInfoSignature = signature
				recordStructure("TS.GameInfo.GameInfo (changed)", provider)
				log("BallModel class=" .. (typeof(ball) == "Instance" and ball.ClassName or tostring(typeof(ball))) .. "; path=" .. safePath(ball))
			end
		end
		local okSave, saveError = saveFile()
		if not okSave and type(writefile) == "function" then log("TXT save failed: " .. tostring(saveError)) end
		task.wait(POLL_INTERVAL)
	end
	stop("30-second observation complete")
end)
