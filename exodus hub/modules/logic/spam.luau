-- [[ spam ]]

local Spam = {}

local Utils, Remote
local connection
local generation = 0
local workerGeneration = 0
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

local function now() return Utils and Utils.now() or os.clock() end

local function setActive(value, reason)
	if active == value then return end
	generation += 1; active = value; phase = 0; lastMode, lastRate = nil, nil
	status.phase = value and "running" or "stopped"
	if Utils and type(Utils.recordTransition) == "function" then Utils.recordTransition("Spam", value and "stopped" or "running", status.phase, reason) end
end

local function requestParry()
	local time = now(); status.lastRequestAt = time; local ok, result, detail = pcall(Remote.fireParry, 1)
	if ok and result == true then status.lastError = nil; return end
	local message = tostring(ok and (detail or "Remote.fireParry indisponível") or result); status.lastError = message
	if time - status.lastErrorAt >= 1 then
		status.lastErrorAt = time
		if type(Utils.recordError) == "function" then Utils.recordError("Spam", message) end
	end
end
local function sendScheduled(expectedGeneration)
	if expectedGeneration == generation and Utils and Remote and Utils.isActive() and Utils.isSpamActive() then requestParry() end
end

local function tick(dt)
	if type(dt) ~= "number" or dt ~= dt or dt <= 0 or dt == math.huge then return end
	local selectedMode = type(Utils.getConfigValue) == "function" and Utils.getConfigValue("SpamRateMode") or Utils.getConfig().SpamRateMode
	if selectedMode == "CPF" then return end
	if not Utils.isActive() or not Utils.isSpamActive() then setActive(false, "spam_disabled"); return end
	if not active then setActive(true, "spam_active") end
	local rate
	if type(Utils.getConfigValue) == "function" then rate = tonumber(Utils.getConfigValue("CPS")) or 0 else rate = tonumber(Utils.getConfig().CPS) or 0 end
	if rate ~= rate or rate == math.huge or rate < 0 then rate = 0 end
	if lastMode ~= "CPS" or rate ~= lastRate then generation += 1; phase = 0; lastMode, lastRate = "CPS", rate end
	local clicks = 0
	if rate > 0 then phase += rate * dt; clicks = math.floor(phase + 1e-9); phase -= clicks end
	status.cpfFps, status.cpfClicks = 0, 0
	local currentGeneration = generation
	if clicks > 0 then
		requestParry()
		if clicks > 1 and currentGeneration == generation and Utils and Remote and Utils.isActive() and Utils.isSpamActive() then
			local spacing = dt / clicks
			for index = 2, clicks do
				task.delay(spacing * (index - 1), sendScheduled, currentGeneration)
			end
		end
	end
end
local function startCpfWorker()
	workerGeneration += 1; local worker = workerGeneration
	local due, previousRate
	task.spawn(function()
		while worker == workerGeneration do
			local mode, rate
			if type(Utils.getConfigValue) == "function" then mode = Utils.getConfigValue("SpamRateMode"); rate = tonumber(Utils.getConfigValue("CPF"))
			else local config = Utils.getConfig(); mode = config.SpamRateMode; rate = tonumber(config.CPF) end
			if mode == "CPF" and Utils.isActive() and Utils.isSpamActive() and rate and rate == rate and rate > 0 and rate < math.huge then
				if not active then setActive(true, "spam_active") end
				if lastMode ~= "CPF" or lastRate ~= rate then generation += 1; phase = 0; lastMode, lastRate = "CPF", rate; due, previousRate = nil, nil end
				local time = now(); local interval = 1 / (rate * 60)
				if previousRate ~= rate or due == nil then due = time + interval; previousRate = rate end
				if time >= due then
					requestParry(); due += interval
					if due <= time then due = time + interval end
				end
			else
				due, previousRate = nil, nil
				if mode == "CPF" then setActive(false, "spam_disabled") end
			end
			task.wait()
		end
	end)
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
	Spam.teardown(); Utils, Remote = deps.Utils, deps.Remote; local runService = Utils.getRunService(); local signal = runService and (runService.RenderStepped or runService.Heartbeat)
	if not signal then return false, "RunService indisponível" end
	connection = signal:Connect(tick)
	if type(Utils.trackGlobal) == "function" then Utils.trackGlobal(connection) end
	startCpfWorker(); return true
end

function Spam.resetState()
	generation += 1; setActive(false, "reset"); phase = 0; lastMode, lastRate = nil, nil
	status.phase = "stopped"; status.lastRequestAt = 0; status.lastError = nil; status.lastErrorAt = -math.huge
	status.cpfFps, status.cpfClicks = 0, 0
end

function Spam.teardown()
	workerGeneration += 1
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
