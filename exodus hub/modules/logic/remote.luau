-- [[ remote ]]

-- state
local Remote = {}
local Utils
local ballSyncConnection
local ballSyncRemote
local parryRemote
local parryInitialized = false
local maintenanceGeneration = 0
local parryRemoteSource
local remoteState = "uninitialized"
local captureEnabled = false
local HttpService = game:GetService("HttpService")
local T = {
	STORAGE_SCHEMA = 1,
	STORAGE_FILE = "deflect_remotes.json",
	MAX_CAPTURED_REMOTES = 128,
}

local Storage = {
	initialized = false,
	available = false,
	writeBlocked = false,
	flushQueued = false,
	path = T.STORAGE_FILE,
	captures = {},
	lastWriteAt = 0,
	lastError = nil,
	errorReported = false,
}

local CapturedRemotes = setmetatable({}, { __mode = "k" })
local function reportStorageError(message)
	Storage.lastError = tostring(message)
	if not Storage.errorReported and Utils and type(Utils.recordError) == "function" then Storage.errorReported = true; Utils.recordError("RemoteStorage", Storage.lastError) end
end
local function safeInstanceInfo(instance)
	if typeof(instance) ~= "Instance" then return nil end
	local info = {}
	local okName, name = pcall(function() return instance.Name end)
	local okClass, className = pcall(function() return instance.ClassName end)
	local okFullName, fullName = pcall(function() return instance:GetFullName() end)
	if okName then info.name = name end
	if okClass then info.className = className end
	if okFullName then info.fullName = fullName end
	return info
end
local function safeValue(value, depth)
	depth = depth or 0
	if value == nil then return nil end
	if type(value) == "boolean" or type(value) == "string" then return value end
	if type(value) == "number" then
		if value == value and value < math.huge and value > -math.huge then return value end
		return tostring(value)
	end
	if depth >= 3 then return tostring(value) end
	local valueType = typeof(value)
	if valueType == "Vector3" then return { type = valueType, x = value.X, y = value.Y, z = value.Z } end
	if valueType == "Color3" then return { type = valueType, r = value.R, g = value.G, b = value.B } end
	if valueType == "CFrame" then return { type = valueType, components = { value:GetComponents() } } end
	if valueType == "EnumItem" then return { type = valueType, enumType = tostring(value.EnumType), name = value.Name, value = value.Value } end
	if valueType == "Instance" then return safeInstanceInfo(value) end
	if type(value) == "table" then
		local result = {}
		for key, item in pairs(value) do
			local safeKey = type(key) == "string" and key or tostring(key); result[safeKey] = safeValue(item, depth + 1)
		end
		return result
	end
	return tostring(value)
end
local function safeAttributes(remote)
	local ok, attributes = pcall(function() return remote:GetAttributes() end)
	if not ok or type(attributes) ~= "table" then return {} end
	return safeValue(attributes) or {}
end
local function safeAncestry(remote)
	local ancestry = {}; local current = remote
	for _ = 1, 64 do
		local info = safeInstanceInfo(current)
		if not info then break end
		table.insert(ancestry, 1, info)
		local ok, parent = pcall(function() return current.Parent end)
		if not ok then break end
		current = parent
	end
	return ancestry
end
local function emptyStorageDocument()
	return {
		schema = T.STORAGE_SCHEMA,
		hub = "Exodus Hub",
		file = T.STORAGE_FILE,
		captures = {},
	}

end
local function writeStorage()
	if not Storage.available or Storage.writeBlocked then return false end
	local document = emptyStorageDocument(); document.captures = Storage.captures; local encodeOk, body = pcall(HttpService.JSONEncode, HttpService, document)
	if not encodeOk or type(body) ~= "string" then Storage.writeBlocked = true; reportStorageError("falha ao codificar " .. Storage.path); return false end
	local writeOk, writeResult = pcall(writefile, Storage.path, body)
	if not writeOk or writeResult == false then Storage.writeBlocked = true; reportStorageError(writeResult or ("falha ao gravar " .. Storage.path)); return false end
	Storage.lastWriteAt = os.time(); Storage.lastError = nil; return true
end
local function initializeStorage()
	if Storage.initialized then return Storage.available end
	Storage.initialized = true; local folderOk, folderPath = Utils.ensureDataFolder()
	if not folderOk then reportStorageError(folderPath); return false end
	Storage.path = folderPath .. "/" .. T.STORAGE_FILE
	if type(isfile) ~= "function" or type(readfile) ~= "function" or type(writefile) ~= "function" then reportStorageError("APIs de arquivo do executor indisponíveis"); return false end
	local fileOk, fileExists = pcall(isfile, Storage.path)
	if not fileOk then reportStorageError(fileExists); return false end
	local body = ""
	if fileExists then
		local readOk
		readOk, body = pcall(readfile, Storage.path)
		if not readOk then reportStorageError(body); return false end
		if body ~= "" then
			local decodeOk, document = pcall(HttpService.JSONDecode, HttpService, body)
			if
				not decodeOk
				or type(document) ~= "table"
				or document.schema ~= T.STORAGE_SCHEMA
				or type(document.captures) ~= "table"
			then
				reportStorageError(Storage.path .. " possui JSON inválido ou schema incompatível"); return false
			end
			local firstCapture = math.max(1, #document.captures - T.MAX_CAPTURED_REMOTES + 1)
			for index = firstCapture, #document.captures do
				local capture = document.captures[index]
				if type(capture) == "table" then Storage.captures[#Storage.captures + 1] = capture end
			end
		end
	end
	Storage.available = true
	if not fileExists or body == "" then writeStorage() end
	return true
end
local function queueStorageWrite()
	if not initializeStorage() or Storage.writeBlocked or Storage.flushQueued then return end
	Storage.flushQueued = true
	task.spawn(function()
		Storage.flushQueued = false; writeStorage()
	end)
end
local function captureRemote(remote)
	if not captureEnabled then return end
	if CapturedRemotes[remote] then return end
	CapturedRemotes[remote] = true
	task.spawn(function()
		local ok, errorMessage = pcall(function()
			if not initializeStorage() then return end
			local parent
			local parentOk = pcall(function() parent = remote.Parent end)
			local remoteInfo = safeInstanceInfo(remote)
			if not remoteInfo then return end
			local capture = {
				id = #Storage.captures + 1,
				capturedAt = os.time(),
				source = "phantomballz",
				name = remoteInfo.name,
				className = remoteInfo.className,
				fullName = remoteInfo.fullName,
				parent = parentOk and safeInstanceInfo(parent) or nil,
				ancestry = safeAncestry(remote),
				attributes = safeAttributes(remote),
				requirements = {
					className = "RemoteEvent",
					methods = { "FireServer" },
					source = "ReplicatedStorage.TouchTap",
					resolution = {
						"getconnections",
						"getfenv",
						"debug.getupvalues",
					},
					globalKey = "did2",
					upvalueKey = "did",
					owner = "LocalPlayer",
					baseDistance = 8.5,
					payloadFlags = { 1, 2 },
				},
			}

			if #Storage.captures >= T.MAX_CAPTURED_REMOTES then table.remove(Storage.captures, 1) end
			Storage.captures[#Storage.captures + 1] = capture; queueStorageWrite()
		end)
		if not ok then reportStorageError(errorMessage) end
	end)
end
local function getStorageStatus()
	return {
		schema = T.STORAGE_SCHEMA,
		enabled = captureEnabled == true,
		available = captureEnabled == true and Storage.available == true or false,
		path = captureEnabled == true and Storage.path or nil,
		captures = captureEnabled == true and #Storage.captures or 0,
		lastWriteAt = captureEnabled == true and Storage.lastWriteAt or 0,
		lastError = captureEnabled == true and Storage.lastError or nil,
	}
end
local function isAlive(remote)
	return remote and typeof(remote) == "Instance" and remote:IsA("RemoteEvent") and remote.Parent ~= nil
end

-- discovery
local function resolvePhantomBallzRemote()
	if isAlive(parryRemote) then return parryRemote end
	parryRemote = nil; local ReplicatedStorage = Utils.getReplicatedStorage(); local touchTap = ReplicatedStorage and ReplicatedStorage:FindFirstChild("TouchTap")
	if not touchTap or not touchTap:IsA("BindableEvent") then return nil end
	if type(getconnections) ~= "function" then return nil end
	local okConnections, connections = pcall(getconnections, touchTap.Event)
	if not okConnections or type(connections) ~= "table" then return nil end
	local lp = game:GetService("Players").LocalPlayer
	for _, connection in ipairs(connections) do
		local fn = connection.Function
		if type(fn) == "function" then
			if type(getfenv) == "function" then
				local okEnv, env = pcall(getfenv, fn)
				if okEnv and type(env) == "table" then
					local globalEnv = rawget(env, "_G"); local did = type(globalEnv) == "table" and rawget(globalEnv, "did2") or nil
					if isAlive(did) then
						parryRemote = did; parryRemoteSource = "phantomballz:getfenv:_G.did2"; remoteState = "captured"; captureRemote(did)
						return did
					end
				end
			end
			if debug and type(debug.getupvalues) == "function" then
				local okUps, upvalues = pcall(debug.getupvalues, fn)
				if okUps and type(upvalues) == "table" then
					for _, value in pairs(upvalues) do
						if
							type(value) == "table"
							and rawget(value, "Owner") == lp
							and rawget(value, "BaseDistance") == 8.5
						then
							local did = rawget(value, "did")
							if isAlive(did) then
								parryRemote = did; parryRemoteSource = "phantomballz:getupvalues:did"; remoteState = "captured"; captureRemote(did)
								return did
							end
						end
					end
				end
			end
		end
	end
	return nil
end

-- payload
local function payloadFor(flag)
	local value = flag == 2 and "\x02" or "\x01"
	if type(buffer) == "table" and type(buffer.fromstring) == "function" then return buffer.fromstring(value) end
	return value
end
function Remote.setParryRemote(remote)
	if not isAlive(remote) then return false end
	parryRemote = remote; parryRemoteSource = "external"; parryInitialized = false; remoteState = "captured"
	captureRemote(remote); return true
end

-- setup
function Remote.setup(deps)
	if type(deps) ~= "table" or not deps.Utils then return false, "dependência ausente: Utils" end
	Utils = deps.Utils; captureEnabled = deps.captureDiagnostics == true; remoteState = "phantomballz"; return true
end

-- parry
function Remote.fireParry(flag)
	local remote = resolvePhantomBallzRemote()
	if not remote then return false end
	local ok = pcall(function() remote:FireServer(payloadFor(flag)) end)
	if not ok then parryRemote = nil; parryInitialized = false; remoteState = "lost" end
	return ok
end
function Remote.initParry()
	local remote = resolvePhantomBallzRemote()
	if not remote then return false end
	if parryInitialized then return true end
	local ok = pcall(function() remote:FireServer(payloadFor(2)) end)
	parryInitialized = ok
	if ok then remoteState = "initialized" end
	return ok
end
function Remote.getRemote()
	if not isAlive(parryRemote) then parryRemote = nil; parryInitialized = false end
	return resolvePhantomBallzRemote()
end
function Remote.getStatus()
	return {
		schema = Utils.apiVersion(),
		state = remoteState,
		initialized = parryInitialized == true,
		source = parryRemoteSource,
		hasBallSync = ballSyncConnection ~= nil and ballSyncConnection.Connected == true and ballSyncRemote ~= nil,
		storage = getStorageStatus(),
	}
end
local function locateBallSync()
	local remotes = Utils.getReplicatedStorage():FindFirstChild("Remotes"); local candidate = remotes and remotes:FindFirstChild("BallSyncData")
	return candidate and candidate:IsA("RemoteEvent") and candidate or nil
end
local function disconnectBallSync()
	if ballSyncConnection then
		pcall(function() ballSyncConnection:Disconnect() end)
		if Utils and Utils.untrackGlobal then Utils.untrackGlobal(ballSyncConnection) end
	end
	ballSyncConnection = nil; ballSyncRemote = nil
end
function Remote.bindBallSync(handler)
	if type(handler) ~= "function" then return false end
	local candidate = locateBallSync()
	if not candidate then
		if ballSyncRemote and not isAlive(ballSyncRemote) then disconnectBallSync() end
		return ballSyncConnection ~= nil and ballSyncConnection.Connected
	end
	if ballSyncConnection and ballSyncConnection.Connected and ballSyncRemote == candidate then return true end
	disconnectBallSync()
	local ok, connection = pcall(function() return candidate.OnClientEvent:Connect(handler) end)
	if not ok or not connection then ballSyncConnection = nil; ballSyncRemote = nil; return false end
	ballSyncConnection = connection; ballSyncRemote = candidate
	if Utils then Utils.trackGlobal(ballSyncConnection) end
	return true
end

-- maintenance
function Remote.startMaintenance(options)
	options = type(options) == "table" and options or {}; local onBallSync = options.onBallSync; local isActive = options.isActive
	if type(isActive) ~= "function" then return false end
	maintenanceGeneration = maintenanceGeneration + 1; local currentGeneration = maintenanceGeneration
	task.spawn(function()
		while currentGeneration == maintenanceGeneration and isActive() do
			local remote = Remote.getRemote()
			if remote and not isAlive(remote) then parryRemote = nil; parryInitialized = false; remote = nil end
			if remote then Remote.initParry() end
			if type(onBallSync) == "function" then Remote.bindBallSync(onBallSync) end
			task.wait(remote and 3 or 1)
		end
	end)
	return true
end
function Remote.stopMaintenance()
	maintenanceGeneration = maintenanceGeneration + 1; disconnectBallSync()
end
Remote.__contract = {
	requires = { Utils = "utils" },
	ballSync = true,
	remoteResolution = "PhantomBallz",
}

return Remote
