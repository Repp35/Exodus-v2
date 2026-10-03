--!strict
--!optimize 2
-- [[ ball_sync_diagnostic ]]

-- Configuration
local CONFIG = {
	TAG = "[BallSyncDiag]",
	LOG_PATH = "BallSyncDiagnostic.txt",
	DURATION = 30,
	POLL_INTERVAL = 0.10,
	FILE_FLUSH_INTERVAL = 0.50,
	MAX_DEPTH = 5,
	MAX_NODES = 300,
	MAX_OUTPUT_BYTES = 2_000_000,
	MAX_EVENTS_PER_REMOTE = 600,
	STRING_LIMIT = 512,
	SYNC_KEYWORDS = {
		"sync",
		"replicat",
		"ball",
		"physics",
		"velocity",
	},
}

do
	local previous = rawget(_G, "ExodusBallSyncDiagnostic")
	if type(previous) == "table" and type(previous.stop) == "function" then pcall(previous.stop) end
end
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local Runtime = {
	startedAt = os.clock(),
	stopped = false,
	lines = {},
	outputBytes = 0,
	truncated = false,
	lastFileFlushAt = 0,
	eventConnections = {},
	remoteStates = {},
	lastReplicatorSignature = nil,
	lastGameInfoSignature = nil,
}

-- Services
local function saveFile()
	if type(writefile) ~= "function" then return false, "writefile unavailable" end
	local content = table.concat(Runtime.lines, "\n")
	if content ~= "" then
		content ..= "\n"
	end
	local ok, err = pcall(writefile, CONFIG.LOG_PATH, content)
	if ok then return true, nil end
	return false, tostring(err)
end

-- Runtime
local function appendOutput(message)
	message = tostring(message); local extraBytes = #message + 1
	if Runtime.outputBytes + extraBytes <= CONFIG.MAX_OUTPUT_BYTES then Runtime.lines[#Runtime.lines + 1] = message; Runtime.outputBytes += extraBytes; return true end
	if not Runtime.truncated then local marker = "[output truncated: 2MB cap reached]"; Runtime.lines[#Runtime.lines + 1] = marker; Runtime.outputBytes += #marker + 1; Runtime.truncated = true end
	return false
end

-- Logging
local function log(message)
	message = tostring(message); appendOutput(message); print(CONFIG.TAG .. " " .. message)
end
local function safeCall(callback, ...)
	if type(callback) ~= "function" then return false, nil end
	return pcall(callback, ...)
end
local function getChild(parent, name)
	if not parent then return nil end
	local ok, child = pcall(function() return parent:FindFirstChild(name) end)
	if not ok then return nil end
	return child
end
local function safePath(instance)
	if typeof(instance) ~= "Instance" then return "nil" end
	local ok, path = pcall(function() return instance:GetFullName() end)
	if ok then return path end
	return "<path unavailable>"
end

-- Signatures
local function safeRequire(moduleScript)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then return nil, "module_missing" end
	local ok, result = pcall(require, moduleScript)
	if not ok then return nil, "require_failed: " .. tostring(result) end
	if type(result) ~= "table" then return nil, "module_returned_" .. type(result) end
	return result, nil
end
local function formatValue(value)
	if value == nil then return "nil" end
	local valueType = type(value)
	if valueType == "string" then
		if #value > CONFIG.STRING_LIMIT then value = string.sub(value, 1, CONFIG.STRING_LIMIT) .. "...<truncated>" end
		return string.format("%q", value)
	end
	if valueType == "number" then return ("%.17g"):format(value) end
	if valueType == "boolean" then return tostring(value) end
	if typeof(value) == "Instance" then return ("Instance<%s> %s"):format(value.ClassName, safePath(value)) end
	local ok, result = pcall(tostring, value)
	if ok then return result end
	return "<value unavailable>"
end
local function sortedKeys(value)
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end
local function appendTree(value, label, depth, visited, nodeState, output)
	depth = depth or 0; visited = visited or {}
	nodeState = nodeState or {
		count = 0,
	}

	output = output or {}; nodeState.count += 1; local indent = string.rep("  ", depth); local valueKind = typeof(value)

	-- Instance
	if valueKind == "Instance" then output[#output + 1] = ("%s%s: Instance<%s> %s"):format(indent, label, value.ClassName, safePath(value)); return output end

	-- Primitive
	if type(value) ~= "table" then
		output[#output + 1] = ("%s%s: typeof=%s type=%s value=%s"):format(
			indent,
			label,
			tostring(valueKind),
			type(value),
			formatValue(value)
		)
		return output
	end

	-- Cycle
	if visited[value] then output[#output + 1] = ("%s%s: table<cycle>"):format(indent, label); return output end
	if depth >= CONFIG.MAX_DEPTH then output[#output + 1] = ("%s%s: table<depth-limit>"):format(indent, label); return output end
	if nodeState.count >= CONFIG.MAX_NODES then output[#output + 1] = ("%s%s: table<node-limit>"):format(indent, label); return output end
	visited[value] = true; local keys = sortedKeys(value); output[#output + 1] = ("%s%s: table (%d keys)"):format(indent, label, #keys)
	for _, key in ipairs(keys) do
		if nodeState.count >= CONFIG.MAX_NODES then output[#output + 1] = indent .. "  ... node limit reached"; break end
		local ok, item = pcall(function() return value[key] end)
		local keyLabel = "[" .. tostring(key) .. "]"
		if not ok then output[#output + 1] = indent .. "  " .. keyLabel .. ": <read failed>"
		else appendTree(item, keyLabel, depth + 1, visited, nodeState, output) end
	end
	visited[value] = nil; return output
end
local function structure(value, label)
	local output = appendTree(value, label, 0, {}, {
		count = 0,
	}, {})
	return table.concat(output, "\n")
end
local function recordStructure(label, value)
	local text = structure(value, label); appendOutput(text); log(label .. " structure written to TXT"); return text
end

-- Cleanup
local function getSignature(value) return structure(value, "payload") end
local function inspectRemote(remote, ...)
	local state = Runtime.remoteStates[remote]
	if not state then return end
	if state.events >= CONFIG.MAX_EVENTS_PER_REMOTE then return end
	state.events += 1; local elapsed = os.clock() - Runtime.startedAt; local argumentCount = select("#", ...)
	local sections = {
		("RAW RESPONSE %s #%d elapsed=%.3fs args=%d"):format(state.path, state.events, elapsed, argumentCount),
	}

	for index = 1, argumentCount do
		local value = select(index, ...); sections[#sections + 1] = structure(value, "arg" .. tostring(index))
	end
	appendOutput(table.concat(sections, "\n"))
end
local function connectRemote(remote)
	if Runtime.remoteStates[remote] then return false end
	local state = {
		path = safePath(remote),
		events = 0,
	}

	Runtime.remoteStates[remote] = state; log(("SYNC REMOTE: %s (%s)"):format(state.path, remote.ClassName))
	local ok, connection = pcall(function()
		return remote.OnClientEvent:Connect(function(...) inspectRemote(remote, ...) end)
	end)
	if not ok or not connection then log(("could not observe %s: %s"):format(state.path, tostring(connection))); Runtime.remoteStates[remote] = nil; return false end
	Runtime.eventConnections[#Runtime.eventConnections + 1] = connection; return true
end
local function looksSyncRelated(instance)
	local name = tostring(instance.Name); local path = safePath(instance); local text = (name .. " " .. path):lower()
	for _, keyword in ipairs(CONFIG.SYNC_KEYWORDS) do
		if string.find(text, keyword, 1, true) then return true end
	end
	return false
end
local function scanReplicatedStorage()
	local descendants = {}
	local ok = pcall(function() descendants = ReplicatedStorage:GetDescendants() end)
	if not ok then log("failed to enumerate ReplicatedStorage"); return 0, 0 end
	local remoteCount = 0; local moduleCount = 0
	for _, instance in ipairs(descendants) do
		if looksSyncRelated(instance) then
			if instance:IsA("RemoteEvent") then
				if connectRemote(instance) then remoteCount += 1 end
			elseif instance:IsA("ModuleScript") then
				moduleCount += 1; log(("SYNC MODULE (listed, not required): %s"):format(safePath(instance)))
			end
		end
	end
	return remoteCount, moduleCount
end
local function inspectGameInfo(moduleScript)
	local gameInfo, err = safeRequire(moduleScript)
	if not gameInfo then log("TS.GameInfo unavailable: " .. tostring(err)); return nil end
	local provider = gameInfo.GameInfo; local ballModel = type(provider) == "table" and provider.BallModel or nil; Runtime.lastGameInfoSignature = getSignature(provider)
	log("TS.GameInfo module=" .. safePath(moduleScript)); recordStructure("TS.GameInfo.GameInfo", provider)
	log(
		("BallModel class=%s; path=%s"):format(
			typeof(ballModel) == "Instance" and ballModel.ClassName or tostring(typeof(ballModel)),
			safePath(ballModel)
		)
	)
	return gameInfo
end
local function inspectBallReplicator(moduleScript)
	local replicator, err = safeRequire(moduleScript)
	if not replicator then log("TS.BallReplicator unavailable: " .. tostring(err)); return nil end
	local provider = replicator.BallReplicator
	local syncData = type(provider) == "table" and provider.syncData or nil; Runtime.lastReplicatorSignature = getSignature(syncData); log("TS.BallReplicator module=" .. safePath(moduleScript))
	recordStructure("TS.BallReplicator.BallReplicator.syncData", syncData)

	return replicator
end
local function pollGameInfo(gameInfo)
	if not gameInfo then return end
	local provider = gameInfo.GameInfo; local signature = getSignature(provider)
	if signature == Runtime.lastGameInfoSignature then return end
	Runtime.lastGameInfoSignature = signature; recordStructure("TS.GameInfo.GameInfo (changed)", provider); local ballModel = type(provider) == "table" and provider.BallModel or nil
	log(
		("BallModel class=%s; path=%s"):format(
			typeof(ballModel) == "Instance" and ballModel.ClassName or tostring(typeof(ballModel)),
			safePath(ballModel)
		)
	)
end
local function pollBallReplicator(ballReplicator)
	if not ballReplicator then return end
	local provider = ballReplicator.BallReplicator
	local syncData = type(provider) == "table" and provider.syncData or nil; local signature = getSignature(syncData)
	if signature == Runtime.lastReplicatorSignature then return end
	Runtime.lastReplicatorSignature = signature; recordStructure("TS.BallReplicator.BallReplicator.syncData (changed)", syncData)
end
local function disconnectAll()
	for index, connection in ipairs(Runtime.eventConnections) do
		if connection then pcall(function() connection:Disconnect() end) end
		Runtime.eventConnections[index] = nil
	end
	Runtime.remoteStates = {}
end
local function stop(reason)
	if Runtime.stopped then return end
	Runtime.stopped = true; disconnectAll()
	for _, state in pairs(Runtime.remoteStates) do
		log(("REMOTE SUMMARY %s: captured=%d limit=%d"):format(state.path, state.events, CONFIG.MAX_EVENTS_PER_REMOTE))
	end
	log("observation ended: " .. tostring(reason or "manual")); local ok, err = saveFile()
	if ok then print(CONFIG.TAG .. " saved " .. CONFIG.LOG_PATH)
	else warn(CONFIG.TAG .. " could not save TXT: " .. tostring(err)) end
end
local API = {
	stop = stop,
}

_G.ExodusBallSyncDiagnostic = API
local initialOk, initialError = saveFile()
log(
	("start; placeId=%s; gameId=%s; player=%s"):format(
		tostring(game.PlaceId),
		tostring(game.GameId),
		LocalPlayer and tostring(LocalPlayer.UserId) or "nil"
	)
)
if not initialOk then log("TXT write unavailable at start: " .. tostring(initialError)) end
local TS = getChild(ReplicatedStorage, "TS")
local Remotes = getChild(ReplicatedStorage, "Remotes")
local GameInfoModule = getChild(TS, "GameInfo")
local BallReplicatorFolder = getChild(TS, "BallReplicator")
local BallReplicatorModule = getChild(BallReplicatorFolder, "BallReplicator")
local GameInfo = inspectGameInfo(GameInfoModule)
local BallReplicator = inspectBallReplicator(BallReplicatorModule)
local remoteCount = scanReplicatedStorage()
if not Remotes then log("ReplicatedStorage.Remotes folder not found") end
if remoteCount == 0 then log("No sync-named RemoteEvents found under ReplicatedStorage") end
log(("listening for %d sync-related RemoteEvents for %d seconds"):format(remoteCount, CONFIG.DURATION))
task.spawn(function()
	while not Runtime.stopped and os.clock() - Runtime.startedAt < CONFIG.DURATION do
		pollBallReplicator(BallReplicator); pollGameInfo(GameInfo); local currentTime = os.clock()
		if currentTime - Runtime.lastFileFlushAt >= CONFIG.FILE_FLUSH_INTERVAL then
			local ok, err = saveFile(); Runtime.lastFileFlushAt = currentTime
			if not ok and type(writefile) == "function" then log("TXT save failed: " .. tostring(err)) end
		end
		task.wait(CONFIG.POLL_INTERVAL)
	end
	if not Runtime.stopped then stop("30-second observation complete") end
end)
