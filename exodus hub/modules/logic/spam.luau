-- [[ spam ]]

local Spam = {}
local MIN_CLICK_INTERVAL = 0.030
local MAX_CPS = 1 / MIN_CLICK_INTERVAL

local Utils, Remote
local connection
local spamObserver
local generation = 0
local workerGeneration = 0
local cpfWorkerRunning = false
local cpfWorkerRate
local active = false
local phase = 0
local lastMode, lastRate
local status = {
	phase = "stopped",
	lastRequestAt = 0,
	lastError = nil,
	lastErrorAt = -math.huge,
	cpfFps = 0,
	cpfClicks = 0,
	cpfCompensation = false,
}

local function now() return os.clock() end
local function setActive(value, reason)
	if active == value then return end
	generation += 1; active = value; phase = 0; lastMode, lastRate = nil, nil
	status.phase = value and "running" or "stopped"
	if Utils and type(Utils.recordTransition) == "function" then Utils.recordTransition("Spam", value and "stopped" or "running", status.phase, reason) end
end
local function requestParry()
	local time = now()
	if time - status.lastRequestAt < MIN_CLICK_INTERVAL then return end
	status.lastRequestAt = time
	local ok, result, detail = pcall(Remote.fireParry, 1)
	if ok and result == true then status.lastError = nil; return end
	local message = tostring(ok and (detail or "Remote.fireParry indisponível") or result); status.lastError = message
	if time - status.lastErrorAt >= 1 then
		status.lastErrorAt = time
		if type(Utils.recordError) == "function" then Utils.recordError("Spam", message) end
	end
end
local function readRate()
	local config = Utils.getConfig()
	local mode = type(Utils.getConfigValue) == "function" and Utils.getConfigValue("SpamRateMode") or config.SpamRateMode
	local key = mode == "CPF" and "CPF" or "CPS"
	local rate = tonumber(type(Utils.getConfigValue) == "function" and Utils.getConfigValue(key) or config[key]) or 0
	if rate ~= rate or rate == math.huge or rate <= 0 then return key, 0 end
	return key, rate
end

local function startCpfWorker()
	if cpfWorkerRunning then return end
	cpfWorkerRunning = true
	workerGeneration += 1
	local worker = workerGeneration
	task.spawn(function()
		local due, previousMode, previousRate
		while worker == workerGeneration do
			local mode, rate = readRate()
			local enabled = Utils.isActive() and Utils.isSpamActive() and rate > 0
			if enabled then
				if not active then setActive(true, "spam_active") end
				local interval = math.max(MIN_CLICK_INTERVAL, 1 / (mode == "CPF" and rate * 60 or rate))
				if previousMode ~= mode or previousRate ~= rate or due == nil then
					due = now()
					previousMode, previousRate = mode, rate
				end
				local time = now()
				if time >= due then
					requestParry()
					due = math.max(due + interval, now() + MIN_CLICK_INTERVAL)
					if due < now() then due = now() + interval end
				end
				task.wait(math.max(0, due - now()))
			else
				due, previousMode, previousRate = nil, nil, nil
				if active then setActive(false, "spam_disabled") end
				task.wait(0.01)
			end
		end
		if worker == workerGeneration then cpfWorkerRunning = false end
	end)
end

local function syncCpfWorker()
	if Utils and not cpfWorkerRunning then startCpfWorker() end
end
function Spam.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.Utils.getRunService) ~= "function"
		or type(deps.Utils.getConfig) ~= "function"
		or type(deps.Utils.isActive) ~= "function"
		or type(deps.Utils.isSpamActive) ~= "function"
		or type(deps.Utils.now) ~= "function"
	then
		return false, "dependência ausente: Remote ou Utils"
	end
	Spam.teardown()
	Utils, Remote = deps.Utils, deps.Remote
	startCpfWorker()
	return true
end
function Spam.resetState()
	generation += 1; setActive(false, "reset"); phase = 0; lastMode, lastRate = nil, nil
	status.phase = "stopped"; status.lastError = nil; status.lastErrorAt = -math.huge
	status.cpfFps, status.cpfClicks = 0, 0
end
function Spam.teardown()
	workerGeneration += 1; cpfWorkerRunning = false; cpfWorkerRate = nil
	if spamObserver then
		if Utils and type(Utils.untrackGlobal) == "function" then Utils.untrackGlobal(spamObserver) end
		spamObserver:Disconnect(); spamObserver = nil
	end
	if connection then
		if Utils and type(Utils.untrackGlobal) == "function" then Utils.untrackGlobal(connection) end
		connection:Disconnect(); connection = nil
	end
	Spam.resetState(); Utils, Remote = nil, nil
end
function Spam.getStatus()
	return {
		schema = Utils and type(Utils.apiVersion) == "function" and Utils.apiVersion() or 1,
		phase = status.phase,
		lastRequestAt = status.lastRequestAt,
		lastError = status.lastError,
		cpfFps = status.cpfFps,
		cpfClicks = status.cpfClicks,
		cpfCompensation = false,
	}
end
Spam.__contract = {
	requiresMethods = {
		Remote = { "fireParry" },
		Utils = { "getRunService", "getConfig", "isActive", "isSpamActive", "now" },
	},

	provides = { "setup", "resetState", "teardown", "getStatus" },
	requires = { Remote = "remote", Utils = "utils" },
}

return Spam
