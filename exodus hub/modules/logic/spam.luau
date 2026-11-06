-- [[ spam ]]

local Spam = {}

local utils, remote, spamObserver, configObserver
local generation, running, inFlight = 0, false, false
local currentMode, currentRate
local status = { phase = "stopped", lastRequestAt = 0, lastError = nil, lastErrorAt = -math.huge, cpfFps = 0, cpfClicks = 0 }

-- tuning
local T = { REFERENCE_FRAME = 1 / 60, ERROR_INTERVAL = 1 }

-- rates
local function validRate(value)
	local rate = tonumber(value); return rate and rate == rate and rate > 0 and rate < math.huge and rate or 0
end
local function cpsInterval(config)
	local cps = validRate(config.CPS); return cps > 0 and 1 / cps or nil
end
local function cpfInterval(config)
	local cpf = validRate(config.CPF)
	if cpf == 0 then return nil end
	local interval = T.REFERENCE_FRAME / cpf; return interval > 0 and interval < math.huge and interval or nil
end
local function readRate()
	local config = utils.getConfig(); local mode = config.SpamRateMode == "CPF" and "CPF" or "CPS"; local rate = validRate(config[mode])
	local interval = mode == "CPF" and cpfInterval(config) or cpsInterval(config); return mode, rate, interval
end
local function transition(active, reason)
	local phase = active and "running" or "stopped"
	if status.phase == phase then return end
	local previous = status.phase; status.phase = phase
	if utils and type(utils.recordTransition) == "function" then utils.recordTransition("Spam", previous, phase, reason) end
end
local function cancel(reason)
	generation += 1; running, currentMode, currentRate = false, nil, nil; transition(false, reason)
end
local function request(boundUtils, boundRemote, token)
	if inFlight then return end
	inFlight = true; status.lastRequestAt = os.clock()
	local ok, result, detail = pcall(
		boundRemote.fireParry,
		1,
		function() return token == generation and boundUtils.isActive() and (boundUtils.isManualSpamActive() or boundUtils.isAutoSpamActive()) end
	)
	inFlight = false
	if token ~= generation or utils ~= boundUtils then return end
	if ok and result == true then status.lastError = nil; return end
	local message = tostring(ok and (detail or "Remote.fireParry indisponível") or result); status.lastError = message; local time = os.clock()
	if time - status.lastErrorAt >= T.ERROR_INTERVAL then
		status.lastErrorAt = time
		if type(boundUtils.recordError) == "function" then boundUtils.recordError("Spam", message) end
	end
end
local function sync()
	if not utils or not remote then return end
	local mode, rate, interval = readRate(); local enabled = utils.isActive() and (utils.isManualSpamActive() or utils.isAutoSpamActive()) and interval ~= nil
	if not enabled then
		if running then cancel("spam_disabled") end
		return
	end
	if running and currentMode == mode and currentRate == rate then return end
	if running then cancel("rate_changed") end
	generation += 1; local token, boundUtils, boundRemote = generation, utils, remote; running, currentMode, currentRate = true, mode, rate; transition(true, "spam_active")
	task.spawn(function()
		local due = os.clock()
		while token == generation and boundUtils.isActive() and (boundUtils.isManualSpamActive() or boundUtils.isAutoSpamActive()) do
			local time = os.clock()
			if time >= due then local pending = math.floor((time - due) / interval) + 1; request(boundUtils, boundRemote, token); due += pending * interval end
			if token == generation then task.wait(math.max(0, due - os.clock())) end
		end
		if token == generation then cancel("spam_disabled") end
	end)
end
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
	cancel("reset")
	status.lastError, status.lastErrorAt = nil, -math.huge
	status.cpfFps, status.cpfClicks = 0, 0
	local token = generation
	task.defer(function()
		if token == generation then sync() end
	end)
end
function Spam.teardown()
	cancel("teardown")
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
		lastRequestAt = status.lastRequestAt,
		lastError = status.lastError,
		cpfFps = status.cpfFps,
		cpfClicks = status.cpfClicks,
		cpfCompensation = false,
	}
end
Spam.__contract = {
	requires = { Remote = "remote", Utils = "utils" },
	requiresMethods = {
		Remote = { "fireParry" },
		Utils = { "getConfig", "isActive", "isManualSpamActive", "isAutoSpamActive", "observeSpam", "observeConfig", "trackGlobal", "untrackGlobal" },
	},

	provides = { "setup", "resetState", "teardown", "getStatus" },
}

return Spam
