-- [[ spam ]]

-- dependencies
local Spam = {}
local utils, remote, spamObserver, configObserver

-- state
local workers = {
	manual = { generation = 0, running = false, inFlight = false },
	auto = { generation = 0, running = false, inFlight = false },
}

local status = {
	phase = "stopped",
	lastRequestAt = 0,
	lastError = nil,
	lastErrorAt = -math.huge,
	cpfFps = 0,
	cpfClicks = 0,
}

-- tuning
local T = {
	CPF_REFERENCE_FPS = 60,
	ERROR_INTERVAL = 1,
}

-- rates
local function readRate()
	local config = utils.getConfig(); local mode = config.SpamRateMode == "CPF" and "CPF" or "CPS"; local rate = tonumber(config[mode]) or 0
	if rate ~= rate or rate <= 0 or rate == math.huge or rate == -math.huge then return mode, 0 end
	if mode == "CPF" and rate * T.CPF_REFERENCE_FPS == math.huge then return mode, 0 end
	return mode, rate
end
local function isEnabled(kind, boundUtils)
	if kind == "manual" then return boundUtils.isManualSpamActive() end
	return boundUtils.isAutoSpamActive()
end

-- lifecycle
local function updatePhase(reason)
	local phase = (workers.manual.running or workers.auto.running) and "running" or "stopped"
	if status.phase == phase then return end
	local previous = status.phase; status.phase = phase
	if utils and type(utils.recordTransition) == "function" then utils.recordTransition("Spam", previous, phase, reason) end
end
local function stopWorker(kind, reason)
	local worker = workers[kind]; worker.generation += 1; worker.running = false; worker.mode = nil
	worker.rate = nil; updatePhase(reason)
end

-- dispatch
local function click(kind, boundUtils, boundRemote, token)
	local worker = workers[kind]
	if worker.inFlight then return end
	worker.inFlight = true; status.lastRequestAt = os.clock()
	local ok, success, detail = pcall(
		boundRemote.fireParry,
		1,
		function() return token == worker.generation and boundUtils.isActive() and isEnabled(kind, boundUtils) end
	)
	worker.inFlight = false
	if token ~= worker.generation or boundUtils ~= utils then return end
	if ok and success == true then status.lastError = nil; return end
	local message = tostring(ok and (detail or "Remote.fireParry indisponível") or success); status.lastError = message; local now = os.clock()
	if now - status.lastErrorAt >= T.ERROR_INTERVAL then
		status.lastErrorAt = now
		if type(boundUtils.recordError) == "function" then boundUtils.recordError("Spam." .. kind, message) end
	end
end
local function startWorker(kind, mode, rate)
	local worker = workers[kind]; worker.generation += 1; local token, boundUtils, boundRemote = worker.generation, utils, remote
	worker.running, worker.mode, worker.rate = true, mode, rate
	updatePhase(kind .. "_enabled")
	task.spawn(function()
		local frequency = mode == "CPF" and rate * T.CPF_REFERENCE_FPS or rate; local interval = 1 / frequency; local due = os.clock()
		while token == worker.generation and boundUtils.isActive() and isEnabled(kind, boundUtils) do
			local now = os.clock()
			if now >= due then click(kind, boundUtils, boundRemote, token); local elapsed = math.floor((now - due) / interval) + 1; due += elapsed * interval end
			if token == worker.generation then task.wait(math.max(0, due - os.clock())) end
		end
		if token == worker.generation then stopWorker(kind, kind .. "_disabled") end
	end)
end
local function sync()
	if not utils or not remote then return end
	local mode, rate = readRate()
	for _, kind in ipairs({ "manual", "auto" }) do
		local worker = workers[kind]; local enabled = utils.isActive() and isEnabled(kind, utils) and rate > 0
		if not enabled then
			if worker.running then stopWorker(kind, kind .. "_disabled") end
		elseif not worker.running then
			startWorker(kind, mode, rate)
		elseif worker.mode ~= mode or worker.rate ~= rate then
			stopWorker(kind, "rate_changed"); startWorker(kind, mode, rate)
		end
	end
end

-- public-api
function Spam.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Utils) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.Utils.getConfig) ~= "function"
		or type(deps.Utils.isActive) ~= "function"
		or type(deps.Utils.isManualSpamActive) ~= "function"
		or type(deps.Utils.isAutoSpamActive) ~= "function"
		or type(deps.Utils.observeSpam) ~= "function"
		or type(deps.Utils.observeConfig) ~= "function"
	then
		return false, "dependência ausente: Remote ou Utils"
	end
	Spam.teardown(); utils, remote = deps.Utils, deps.Remote; spamObserver = utils.observeSpam(sync)
	configObserver = utils.observeConfig(function(changes)
		if changes.SpamRateMode ~= nil or changes.CPS ~= nil or changes.CPF ~= nil then sync() end
	end)
	utils.trackGlobal(spamObserver); utils.trackGlobal(configObserver); sync(); return true
end
function Spam.resetState()
	stopWorker("manual", "reset"); stopWorker("auto", "reset")
	status.lastError, status.lastErrorAt = nil, -math.huge
	status.cpfFps, status.cpfClicks = 0, 0
	local manualToken, autoToken = workers.manual.generation, workers.auto.generation
	task.defer(function()
		if workers.manual.generation == manualToken and workers.auto.generation == autoToken then sync() end
	end)
end
function Spam.teardown()
	stopWorker("manual", "teardown"); stopWorker("auto", "teardown")
	if utils then
		if spamObserver then utils.untrackGlobal(spamObserver); spamObserver:Disconnect() end
		if configObserver then utils.untrackGlobal(configObserver); configObserver:Disconnect() end
	end
	spamObserver, configObserver, utils, remote = nil, nil, nil, nil
end
function Spam.getStatus()
	return {
		schema = utils and utils.apiVersion() or 1,
		phase = status.phase,
		manualRunning = workers.manual.running,
		autoRunning = workers.auto.running,
		lastRequestAt = status.lastRequestAt,
		lastError = status.lastError,
		cpfFps = status.cpfFps,
		cpfClicks = status.cpfClicks,
		cpfCompensation = false,
	}
end

-- contract
Spam.__contract = {
	requires = { Remote = "remote", Utils = "utils" },
	requiresMethods = {
		Remote = { "fireParry" },
		Utils = {
			"getConfig",
			"isActive",
			"isManualSpamActive",
			"isAutoSpamActive",
			"observeSpam",
			"observeConfig",
			"trackGlobal",
			"untrackGlobal",
		},
	},

	provides = { "setup", "resetState", "teardown", "getStatus" },
}

return Spam
