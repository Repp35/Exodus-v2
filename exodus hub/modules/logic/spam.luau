-- [[ spam ]]

local Spam = {}

local Utils, Remote
local connection
local generation = 0
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
	cpfCompensation = true,
}

local function now() return Utils and Utils.now() or os.clock() end

local function setActive(value, reason)
	if active == value then return end
	active = value; phase = 0; lastMode, lastRate = nil, nil; status.phase = value and "running" or "stopped"
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

local function tick(dt)
	if type(dt) ~= "number" or dt ~= dt or dt <= 0 or dt == math.huge then return end
	if not Utils.isActive() or not Utils.isSpamActive() then setActive(false, "spam_disabled"); return end
	setActive(true, "spam_active")
	local mode, rate
	if type(Utils.getConfigValue) == "function" then mode = Utils.getConfigValue("SpamRateMode") == "CPF" and "CPF" or "CPS"; rate = tonumber(Utils.getConfigValue(mode)) or 0
	else local config = Utils.getConfig(); mode = config.SpamRateMode == "CPF" and "CPF" or "CPS"; rate = tonumber(config[mode]) or 0 end
	if rate ~= rate or rate == math.huge or rate < 0 then rate = 0 end
	if mode ~= lastMode or rate ~= lastRate then phase = 0; lastMode, lastRate = mode, rate end
	local clicks = 0
	if rate > 0 then
		if mode == "CPF" then
			if rate >= 1 then clicks = math.max(1, math.floor(rate * 60 * dt + 0.5)) else phase += rate * math.max(1, 60 * dt); clicks = math.floor(phase + 1e-9); phase -= clicks end
		else
			phase += rate * dt; clicks = math.floor(phase + 1e-9); phase -= clicks
		end
	end
	status.cpfFps = mode == "CPF" and 1 / dt or 0; status.cpfClicks = mode == "CPF" and clicks or 0; local currentGeneration = generation
	for _ = 1, clicks do
		if currentGeneration ~= generation or not Utils.isActive() or not Utils.isSpamActive() then break end
		requestParry()
	end
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
	return true
end

function Spam.resetState()
	generation += 1; setActive(false, "reset"); phase = 0; lastMode, lastRate = nil, nil
	status.phase = "stopped"; status.lastRequestAt = 0; status.lastError = nil; status.lastErrorAt = -math.huge
	status.cpfFps, status.cpfClicks = 0, 0
end

function Spam.teardown()
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
		cpfCompensation = true,
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
