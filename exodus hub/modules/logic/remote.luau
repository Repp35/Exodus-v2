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
local HttpService = game:GetService("HttpService")
local STORAGE_SCHEMA = 1
local STORAGE_FILE = "deflect_remotes.json"
local MAX_CAPTURED_REMOTES = 128

-- remote discovery
local RemoteConfig = {
	METHOD = "index",
	INDEX = 27,
	NAME = "RemoteEvent",
}

-- ==========================================================
-- 💜 HEARTBURST "auto" — MESMA LÓGICA DO HEART, SÓ COM PAYLOAD MENOR
-- "hook" continua EXATAMENTE igual abaixo.
-- Troque na config: METHOD = "hook"  (atual)
--                   METHOD = "auto"  (Heartburst com payload menor)
-- ==========================================================
local AUTO_PAYLOAD_SIZE   = 50000     -- menor que o HEART (300000)
local AUTO_THREADS        = 12
local AUTO_CYCLE_WAIT     = 0.155
local AUTO_LOT_SIZE       = 40
local AUTO_INTER_SHOT     = 0.001
local AUTO_INTER_LOT      = 0.008
local AUTO_THREAD_STAGGER = 0.015
local AUTO_LOT_COUNT      = 4

local autoActive  = false
local autoThreads = {}

-- Storage
local Storage = {
	initialized = false,
	available = false,
	writeBlocked = false,
	flushQueued = false,
	path = STORAGE_FILE,
	captures = {},
	lastWriteAt = 0,
	lastError = nil,
	errorReported = false,
}

local CapturedRemotes = setmetatable({}, { __mode = "k" })

local function reportStorageError(message)
	Storage.lastError = tostring(message)
	if not Storage.errorReported and Utils and type(Utils.recordError) == "function" then
		Storage.errorReported = true
		Utils.recordError("RemoteStorage", Storage.lastError)
	end
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

	if valueType == "Vector3" then
		return { type = valueType, x = value.X, y = value.Y, z = value.Z }
	end

	if valueType == "Color3" then
		return { type = valueType, r = value.R, g = value.G, b = value.B }
	end

	if valueType == "CFrame" then
		return { type = valueType, components = { value:GetComponents() } }
	end

	if valueType == "EnumItem" then
		return {
			type = valueType,
			enumType = tostring(value.EnumType),
			name = value.Name,
			value = value.Value,
		}
	end

	if valueType == "Instance" then
		return safeInstanceInfo(value)
	end

	if type(value) == "table" then
		local result = {}
		for key, item in pairs(value) do
			local safeKey = type(key) == "string" and key or tostring(key)
			result[safeKey] = safeValue(item, depth + 1)
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
	local ancestry = {}
	local current = remote

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
		schema = STORAGE_SCHEMA,
		hub = "Exodus Hub",
		file = STORAGE_FILE,
		captures = {},
	}
end

local function writeStorage()
	if not Storage.available or Storage.writeBlocked then return false end

	local document = emptyStorageDocument()
	document.captures = Storage.captures

	local encodeOk, body = pcall(HttpService.JSONEncode, HttpService, document)

	if not encodeOk or type(body) ~= "string" then
		Storage.writeBlocked = true
		reportStorageError("falha ao codificar " .. Storage.path)
		return false
	end

	local writeOk, writeResult = pcall(writefile, Storage.path, body)

	if not writeOk or writeResult == false then
		Storage.writeBlocked = true
		reportStorageError(writeResult or ("falha ao gravar " .. Storage.path))
		return false
	end

	Storage.lastWriteAt = os.time()
	Storage.lastError = nil

	return true
end

local function initializeStorage()
	if Storage.initialized then return Storage.available end

	Storage.initialized = true

	local folderOk, folderPath = Utils.ensureDataFolder()

	if not folderOk then
		reportStorageError(folderPath)
		return false
	end

	Storage.path = folderPath .. "/" .. STORAGE_FILE

	if
		type(isfile) ~= "function"
		or type(readfile) ~= "function"
		or type(writefile) ~= "function"
	then
		reportStorageError("APIs de arquivo do executor indisponíveis")
		return false
	end

	local fileOk, fileExists = pcall(isfile, Storage.path)

	if not fileOk then
		reportStorageError(fileExists)
		return false
	end

	local body = ""

	if fileExists then
		local readOk
		readOk, body = pcall(readfile, Storage.path)

		if not readOk then
			reportStorageError(body)
			return false
		end

		if body ~= "" then
			local decodeOk, document = pcall(HttpService.JSONDecode, HttpService, body)

			if
				not decodeOk
				or type(document) ~= "table"
				or document.schema ~= STORAGE_SCHEMA
				or type(document.captures) ~= "table"
			then
				reportStorageError(Storage.path .. " possui JSON inválido ou schema incompatível")
				return false
			end

			local firstCapture = math.max(1, #document.captures - MAX_CAPTURED_REMOTES + 1)

			for index = firstCapture, #document.captures do
				local capture = document.captures[index]
				if type(capture) == "table" then
					Storage.captures[#Storage.captures + 1] = capture
				end
			end
		end
	end

	Storage.available = true

	if not fileExists or body == "" then
		writeStorage()
	end

	return true
end

local function queueStorageWrite()
	if not initializeStorage() or Storage.writeBlocked or Storage.flushQueued then return end

	Storage.flushQueued = true

	task.spawn(function()
		Storage.flushQueued = false
		writeStorage()
	end)
end

local function captureRemote(remote)
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
				source = "remote_hook",
				name = remoteInfo.name,
				className = remoteInfo.className,
				fullName = remoteInfo.fullName,
				parent = parentOk and safeInstanceInfo(parent) or nil,
				ancestry = safeAncestry(remote),
				attributes = safeAttributes(remote),
				requirements = {
					className = "RemoteEvent",
					methods = { "FireServer" },
					events = { "OnClientEvent" },
					payloadFlags = { 1, 2 },
				},
			}

			if #Storage.captures >= MAX_CAPTURED_REMOTES then
				table.remove(Storage.captures, 1)
			end

			Storage.captures[#Storage.captures + 1] = capture
			queueStorageWrite()
		end)

		if not ok then
			reportStorageError(errorMessage)
		end
	end)
end

local function getStorageStatus()
	return {
		schema = STORAGE_SCHEMA,
		available = Storage.available == true,
		path = Storage.path,
		captures = #Storage.captures,
		lastWriteAt = Storage.lastWriteAt,
		lastError = Storage.lastError,
	}
end

local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}

local HookState = type(namespace.RemoteHooks) == "table"
	and namespace.RemoteHooks
	or {
		installed = false,
		register = nil,
	}

namespace.RemoteHooks = HookState
_G.Exodus = namespace

local function isAlive(remote)
	return remote
		and typeof(remote) == "Instance"
		and remote:IsA("RemoteEvent")
		and remote.Parent ~= nil
end

-- discovery
local function registerRemote(remote)
	if
		isAlive(remote)
		and (
			not isAlive(parryRemote)
			or RemoteConfig.METHOD == "hook"
		)
	then
		parryRemote = remote
		parryRemoteSource = "hook"
		parryInitialized = false
		remoteState = "captured"
		captureRemote(remote)
	end
end

local function getRemotesFolder()
	local replicatedStorage = Utils.getReplicatedStorage()
	return replicatedStorage and replicatedStorage:FindFirstChild("Remotes")
end

local function findRemoteByIndex()
	local remotes = getRemotesFolder()
	if not remotes then return nil end

	local children = remotes:GetChildren()
	local index = tonumber(RemoteConfig.INDEX) or 1
	local candidate = children[index]

	if candidate and candidate:IsA("RemoteEvent") then
		return candidate
	end

	for i, child in ipairs(children) do
		if child:IsA("RemoteEvent") then
			RemoteConfig.INDEX = i
			return child
		end
	end

	return nil
end

local function findRemoteByName()
	local remotes = getRemotesFolder()
	if not remotes then return nil end

	local name = tostring(RemoteConfig.NAME or "")

	if name ~= "" then
		local candidate = remotes:FindFirstChild(name)

		if candidate and candidate:IsA("RemoteEvent") then
			return candidate
		end
	end

	return nil
end

local function findRemoteByHook()
	if isAlive(parryRemote) and parryRemoteSource == "hook" then
		return parryRemote
	end

	return nil
end

local function locateBallSync()
	local remotes = getRemotesFolder()
	local candidate = remotes and remotes:FindFirstChild("BallSyncData")

	return candidate
		and candidate:IsA("RemoteEvent")
		and candidate
		or nil
end

local function discoverRemote()
	local method = tostring(RemoteConfig.METHOD or "auto")
	local candidate

	if method == "index" then
		candidate = findRemoteByIndex()

	elseif method == "name" then
		candidate = findRemoteByName()

	elseif method == "hook" then
		candidate = findRemoteByHook()

	elseif method == "ballSync" then
		candidate = locateBallSync()

	elseif method == "auto" then
		candidate = findRemoteByIndex()
			or findRemoteByName()
			or findRemoteByHook()
			or locateBallSync()
	end

	if candidate and isAlive(candidate) then
		parryRemote = candidate
		parryRemoteSource = method
		parryInitialized = false
		remoteState = "captured"
		captureRemote(candidate)
		return candidate
	end

	return nil
end

local function clearRemovedRemote(remote)
	if parryRemote == remote and not isAlive(remote) then
		parryRemote = nil
		parryInitialized = false
		remoteState = "uninitialized"
	end
end

-- payload (hook — EXATAMENTE igual ao atual)
local function payloadFor(flag)
	local value = flag == 2 and "\x02" or "\x01"

	if
		type(buffer) == "table"
		and type(buffer.fromstring) == "function"
	then
		return buffer.fromstring(value)
	end

	return value
end

-- payload do HEARTBURST "auto" — IGUAL ao Heart só com tamanho menor
local function payloadForAuto()
	local body = string.rep("\x01", AUTO_PAYLOAD_SIZE)

	if
		type(buffer) == "table"
		and type(buffer.fromstring) == "function"
	then
		return buffer.fromstring(body)
	end

	return body
end

-- ==========================================================
-- 🔒 MÉTODO HOOK — NÃO MEXER, fica EXATAMENTE igual ✅
-- ==========================================================
local function installHooks()
	if HookState.installed then return true end
	if type(hookmetamethod) ~= "function" then return false end

	local ok = pcall(function()
		local oldNamecall

		oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
			local method = getnamecallmethod()
			local args = { ... }

			if
				not checkcaller()
				and (method == "FireServer" or method == "fireServer")
			then
				local isPayload = false

				if args[1] then
					if
						typeof(args[1]) == "buffer"
						or (
							typeof(args[1]) == "string"
							and (
								string.find(args[1], "\x01")
								or string.find(args[1], "\x02")
							)
						)
					then
						isPayload = true
					end
				end

				if isPayload or self.Name == "RemoteEvent" then
					if type(HookState.register) == "function" then
						HookState.register(self)
					end
				end
			end

			return oldNamecall(self, ...)
		end)

		local oldIndex

		oldIndex = hookmetamethod(game, "__index", function(self, key)
			if
				not checkcaller()
				and (key == "FireServer" or key == "fireServer")
				and typeof(self) == "Instance"
				and self:IsA("RemoteEvent")
			then
				if
					self.Name == "RemoteEvent"
					or (
						self.Parent
						and string.find(self.Parent.Name, "Remote")
					)
				then
					if type(HookState.register) == "function" then
						task.spawn(HookState.register, self)
					end
				end
			end

			return oldIndex(self, key)
		end)
	end)

	if ok then
		HookState.installed = true
	end

	return HookState.installed == true
end

-- ==========================================================
-- 💜 HEARTBURST "auto" — MESMA LÓGICA DO HEART, payload menor
-- 12 THREADS | 4×40 disparos | 1ms entre shots | 8ms entre lotes | 155ms entre ciclos
-- ==========================================================
local function startAutoParry()
	if autoActive then return true end
	if not isAlive(parryRemote) then return false end

	autoActive = true
	table.clear(autoThreads)

	local payload    = payloadForAuto()
	local fireServer = parryRemote.FireServer
	local event      = parryRemote
	local wait       = task.wait

	for id = 1, AUTO_THREADS do
		task.wait(id * AUTO_THREAD_STAGGER)

		autoThreads[id] = task.spawn(function()
			while autoActive do
				for lote = 1, AUTO_LOT_COUNT do
					if not autoActive then return end
					for j = 1, AUTO_LOT_SIZE do
						if not autoActive then return end
						fireServer(event, payload)
						wait(AUTO_INTER_SHOT)
					end
					task.wait(AUTO_INTER_LOT)
				end
				task.wait(AUTO_CYCLE_WAIT)
			end
		end)
	end

	return true
end

local function stopAutoParry()
	autoActive = false
	table.clear(autoThreads)
end

function Remote.setDiscoveryMethod(method, options)
	method = tostring(method or "")

	if
		method ~= "index"
		and method ~= "name"
		and method ~= "hook"
		and method ~= "ballSync"
		and method ~= "auto"
	then
		return false
	end

	-- ao trocar de método, sempre encerra o auto se estiver rodando
	stopAutoParry()

	RemoteConfig.METHOD = method

	if type(options) == "table" then
		if options.index ~= nil then
			RemoteConfig.INDEX = tonumber(options.index) or RemoteConfig.INDEX
		end

		if options.name ~= nil then
			RemoteConfig.NAME = tostring(options.name)
		end
	end

	parryRemote = nil
	parryInitialized = false
	remoteState = "uninitialized"

	return discoverRemote() ~= nil
end

function Remote.getDiscoveryConfig()
	return {
		method = RemoteConfig.METHOD,
		index = RemoteConfig.INDEX,
		name = RemoteConfig.NAME,
	}
end

-- setup
function Remote.setup(deps)
	if type(deps) ~= "table" or not deps.Utils then
		return false, "dependência ausente: Utils"
	end

	Utils = deps.Utils
	HookState.register = registerRemote

	if not installHooks() then
		HookState.register = nil
		Utils.warn("hooks do Remote indisponíveis")
		return false, "hooks indisponíveis"
	end

	remoteState = "hooked"
	initializeStorage()
	discoverRemote()

	return true
end

-- parry
function Remote.fireParry(flag)
	-- 💜 HEARTBURST "auto" — liga o loop contínuo
	if RemoteConfig.METHOD == "auto" then
		if not isAlive(parryRemote) then
			clearRemovedRemote(parryRemote)
			parryRemote = discoverRemote()
		end

		if not isAlive(parryRemote) then return false end
		return startAutoParry()
	end

	-- hook (atual, EXATAMENTE igual)
	if not isAlive(parryRemote) then
		clearRemovedRemote(parryRemote)
		parryRemote = discoverRemote()
	end

	if not isAlive(parryRemote) then return false end

	local ok = pcall(function()
		parryRemote:FireServer(payloadFor(flag))
	end)

	return ok
end

function Remote.initParry()
	-- 💜 HEARTBURST "auto" — liga o loop contínuo
	if RemoteConfig.METHOD == "auto" then
		if not isAlive(parryRemote) then
			clearRemovedRemote(parryRemote)
			parryRemote = discoverRemote()
		end

		if not isAlive(parryRemote) then return false end
		if parryInitialized then return true end

		local ok = startAutoParry()
		parryInitialized = ok
		return ok
	end

	-- hook (atual, EXATAMENTE igual)
	if not isAlive(parryRemote) then
		clearRemovedRemote(parryRemote)
		parryRemote = discoverRemote()
	end

	if not isAlive(parryRemote) then return false end
	if parryInitialized then return true end

	local ok = pcall(function()
		parryRemote:FireServer(payloadFor(2))
	end)

	parryInitialized = ok
	return ok
end

function Remote.getRemote()
	if not isAlive(parryRemote) then
		clearRemovedRemote(parryRemote)
		parryRemote = discoverRemote()
	end

	return parryRemote
end

function Remote.getStatus()
	return {
		schema = Utils.apiVersion(),
		state = remoteState,
		initialized = parryInitialized == true,
		source = parryRemoteSource,
		discovery = {
			method = RemoteConfig.METHOD,
			index = RemoteConfig.INDEX,
			name = RemoteConfig.NAME,
		},
		hasBallSync =
			ballSyncConnection ~= nil
			and ballSyncConnection.Connected == true
			and ballSyncRemote ~= nil,
		auto = {
			active = autoActive == true,
			threads = #autoThreads,
			payloadSize = AUTO_PAYLOAD_SIZE,
		},
		storage = getStorageStatus(),
	}
end

local function disconnectBallSync()
	if ballSyncConnection then
		pcall(function()
			ballSyncConnection:Disconnect()
		end)

		if Utils and Utils.untrackGlobal then
			Utils.untrackGlobal(ballSyncConnection)
		end
	end

	ballSyncConnection = nil
	ballSyncRemote = nil
end

function Remote.bindBallSync(handler)
	if type(handler) ~= "function" then return false end

	local candidate = locateBallSync()

	if not candidate then
		if ballSyncRemote and not isAlive(ballSyncRemote) then
			disconnectBallSync()
		end

		return
			ballSyncConnection ~= nil
			and ballSyncConnection.Connected
	end

	if
		ballSyncConnection
		and ballSyncConnection.Connected
		and ballSyncRemote == candidate
	then
		return true
	end

	disconnectBallSync()

	local ok, connection = pcall(function()
		return candidate.OnClientEvent:Connect(handler)
	end)

	if not ok or not connection then
		ballSyncConnection = nil
		ballSyncRemote = nil
		return false
	end

	ballSyncConnection = connection
	ballSyncRemote = candidate

	if Utils then
		Utils.trackGlobal(ballSyncConnection)
	end

	return true
end

-- ==========================================================
-- 💜 controle externo do HEARTBURST "auto"
-- ==========================================================
function Remote.startAuto()
	if not isAlive(parryRemote) then
		clearRemovedRemote(parryRemote)
		parryRemote = discoverRemote()
	end
	return isAlive(parryRemote) and startAutoParry() or false
end

function Remote.stopAuto()
	stopAutoParry()
	return true
end

function Remote.isAutoActive()
	return autoActive == true
end

-- maintenance
function Remote.startMaintenance(options)
	options = type(options) == "table" and options or {}

	local onBallSync = options.onBallSync
	local isActive = options.isActive

	if type(isActive) ~= "function" then return false end

	maintenanceGeneration = maintenanceGeneration + 1

	local currentGeneration = maintenanceGeneration

	task.spawn(function()
		while currentGeneration == maintenanceGeneration and isActive() do
			local remote = Remote.getRemote()

			if remote and not isAlive(remote) then
				clearRemovedRemote(remote)
				remote = nil
			end

			if remote then
				Remote.initParry()
			end

			if type(onBallSync) == "function" then
				Remote.bindBallSync(onBallSync)
			end

			task.wait(remote and 3 or 1)
		end
	end)

	return true
end

function Remote.stopMaintenance()
	maintenanceGeneration = maintenanceGeneration + 1
	disconnectBallSync()
	stopAutoParry()
end

Remote.__contract = {
	requires = { Utils = "utils" },
	ballSync = true,
}

return Remote