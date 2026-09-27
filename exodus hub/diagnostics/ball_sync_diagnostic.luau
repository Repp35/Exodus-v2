--[=[
BallSync diagnostic for PhantomBallz

Run this as a one-off client-side Luau script while in a live match. It only
observes sync-related RemoteEvents and replicated tables for 30 seconds. It
does not send remotes or mutate game state.

Output file: BallSyncDiagnostic.txt (executor working directory)
The TXT includes raw sync values; review it for player IDs/text before sharing.
Console prefix: [BallSyncDiag]
Stop early with: _G.ExodusBallSyncDiagnostic.stop()
]=]

local TAG = "[BallSyncDiag]"
local LOG_PATH = "BallSyncDiagnostic.txt"
local DURATION = 30
local POLL_INTERVAL = 0.1
local FILE_FLUSH_INTERVAL = 0.5
local MAX_DEPTH = 5
local MAX_NODES = 300
local MAX_OUTPUT_BYTES = 2000000
local MAX_EVENTS_PER_REMOTE = 600

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
local outputBytes = 0
local lastFileFlushAt = 0
local eventConnections = {}
local lastReplicatorSignature
local lastGameInfoSignature

local function saveFile()
	if type(writefile) ~= "function" then return false, "writefile unavailable" end
	local ok, err = pcall(writefile, LOG_PATH, table.concat(lines, "\n") .. "\n")
	if ok then return true, nil end
	return false, tostring(err)
end

local function appendOutput(message)
	message = tostring(message)
	local extraBytes = #message + 1
	if outputBytes + extraBytes <= MAX_OUTPUT_BYTES then
		lines[#lines + 1] = message
		outputBytes += extraBytes
	elseif not truncated then
		truncated = true
		local marker = "[output truncated: 2MB cap reached]"
		lines[#lines + 1] = marker
		outputBytes += #marker + 1
	end
	return not truncated
end

local function log(message)
	appendOutput(message)
	print(TAG .. " " .. tostring(message))
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

local function rawValue(value)
	if value == nil then return "nil" end
	if type(value) == "string" then
		local truncatedValue = #value > 512 and (string.sub(value, 1, 512) .. "...<truncated>") or value
		return string.format("%q", truncatedValue)
	end
	if type(value) == "number" then return ("%.17g"):format(value) end
	if type(value) == "boolean" then return tostring(value) end
	if typeof(value) == "Instance" then return ("Instance<%s> %s"):format(value.ClassName, safePath(value)) end
	local ok, rendered = pcall(tostring, value)
	if ok then return rendered end
	return "<value unavailable>"
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
		output[#output + 1] = ("%s%s: typeof=%s type=%s value=%s"):format(indent, label, tostring(kind), type(value), rawValue(value))
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
	appendOutput(text)
	log(label .. " structure written to TXT")
	return text
end

local function safeSignature(value)
	return structure(value, "payload")
end

local remoteConnections = {}
local function inspectEvent(remote, ...)
	local state = remoteConnections[remote]
	if not state or state.events >= MAX_EVENTS_PER_REMOTE then return end
	state.events += 1
	local argCount = select("#", ...)
	local elapsed = os.clock() - startedAt
	local sections = { ("RAW RESPONSE %s #%d elapsed=%.3fs args=%d"):format(state.path, state.events, elapsed, argCount) }
	for index = 1, argCount do
		local value = select(index, ...)
		sections[#sections + 1] = structure(value, "arg" .. tostring(index))
	end
	appendOutput(table.concat(sections, "\n"))
end

local function stop(reason)
	if stopped then return end
	stopped = true
	for _, connection in ipairs(eventConnections) do
		pcall(function() connection:Disconnect() end)
	end
	eventConnections = {}
	for _, state in pairs(remoteConnections) do
		log(("REMOTE SUMMARY %s: captured=%d limit=%d"):format(state.path, state.events, MAX_EVENTS_PER_REMOTE))
	end
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

-- Observe only remotes with sync/ball/physics-related names to avoid logging
-- unrelated gameplay traffic.
local syncKeywords = { "sync", "replicat", "ball", "physics", "velocity" }
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
			local state = { path = path, events = 0 }
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
		if os.clock() - lastFileFlushAt >= FILE_FLUSH_INTERVAL then
			local okSave, saveError = saveFile()
			lastFileFlushAt = os.clock()
			if not okSave and type(writefile) == "function" then log("TXT save failed: " .. tostring(saveError)) end
		end
		task.wait(POLL_INTERVAL)
	end
	stop("30-second observation complete")
end)
