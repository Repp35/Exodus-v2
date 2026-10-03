--!strict
--!optimize 2
-- [[ spam ]]

local Spam = {}

local Remote
local GameInfo
local Utils
local AutoParry
local AutoClash

local clock = os.clock
local max = math.max
local floor = math.floor

-- tuning
local T = {
	DEFLECT_COOLDOWN_THRESHOLD = 0,

	SPAM_PARRY_RADIUS_GUARD = false,
	SPAM_PARRY_WINDOW_FACTOR = 1.1,
}

-- runtime
local connection
local generation = 0
local wasActive = false

local lastMode
local lastRate

-- CPF
local cpfClicks = 0

-- CPS
local cpsInterval = 0
local cpsNext = 0
local cpsRate = 0
local cpsGeneration = 0

-- CHAIN
local chainRunning = false

local Scheduler = {
	phase = "stopped",

	lastRequestAt = 0,
	lastError = nil,

	lastCooldownAt = 0,
	lastCooldownValue = 0,

	lastErrorAt = 0,

	cpfFps = 0,
	cpfClicks = 0,
	cpfCompensation = false,

	parryRadiusGuard = false,
	antiDashRadiusBypass = false,
	parryRadiusTTI = 0,
	parryRadiusLimit = 0,
}

----------------------------------------------------------------
-- time
----------------------------------------------------------------

local function now()
	if Utils and type(Utils.now) == "function" then
		return Utils.now()
	end

	return clock()
end

----------------------------------------------------------------
-- state
----------------------------------------------------------------

local function clearCPS()
	cpsInterval = 0
	cpsNext = 0
	cpsRate = 0
	cpsGeneration = generation
end

local function clearRuntime()
	lastMode = nil
	lastRate = nil

	cpfClicks = 0

	clearCPS()

	chainRunning = false

	Scheduler.cpfFps = 0
	Scheduler.cpfClicks = 0
	Scheduler.cpfCompensation = false

	Scheduler.parryRadiusGuard = false
	Scheduler.antiDashRadiusBypass = false
	Scheduler.parryRadiusTTI = 0
	Scheduler.parryRadiusLimit = 0
end

local function invalidate(reason)
	generation += 1

	Scheduler.phase = "stopped"

	clearRuntime()

	if
		wasActive
		and Utils
		and type(Utils.recordTransition) == "function"
	then
		Utils.recordTransition(
			"Spam",
			"running",
			"stopped",
			reason or "invalidated"
		)
	end
end

----------------------------------------------------------------
-- active
----------------------------------------------------------------

local function isActive()
	if
		not Utils
		or type(Utils.isActive) ~= "function"
		or type(Utils.isSpamActive) ~= "function"
	then
		return false
	end

	return Utils.isActive() and Utils.isSpamActive()
end

local function isRegularSpamActive()
	if
		not Utils
		or type(Utils.isActive) ~= "function"
		or not Utils.isActive()
	then
		return false
	end

	local manual =
		type(Utils.isManualSpamActive) == "function"
		and Utils.isManualSpamActive()

	local automatic =
		type(Utils.isAutoSpamActive) == "function"
		and Utils.isAutoSpamActive()

	return manual or automatic
end

----------------------------------------------------------------
-- cooldown
----------------------------------------------------------------

local function getDeflectCooldown()
	if
		not GameInfo
		or type(GameInfo.getDeflectCD) ~= "function"
	then
		return nil
	end

	local ok, value = pcall(GameInfo.getDeflectCD)

	if
		not ok
		or type(value) ~= "number"
		or value ~= value
		or value == math.huge
		or value == -math.huge
	then
		return nil
	end

	return value
end

----------------------------------------------------------------
-- radius guard
----------------------------------------------------------------

local function dashBypass()
	if
		not AutoClash
		or type(AutoClash.getDashData) ~= "function"
	then
		Scheduler.antiDashRadiusBypass = false
		return false
	end

	local ok, data = pcall(AutoClash.getDashData)

	if
		not ok
		or type(data) ~= "table"
		or data.dangerous ~= true
	then
		Scheduler.antiDashRadiusBypass = false
		return false
	end

	Scheduler.antiDashRadiusBypass = true

	return true
end

local function radiusAllowed()
	Scheduler.antiDashRadiusBypass = false

	if not T.SPAM_PARRY_RADIUS_GUARD then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		Scheduler.parryRadiusLimit = 0

		return true
	end

	if dashBypass() then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		Scheduler.parryRadiusLimit = 0

		return true
	end

	if
		not AutoParry
		or type(AutoParry.getTiming) ~= "function"
		or type(AutoParry.getRadius) ~= "function"
		or not GameInfo
		or type(GameInfo.getSnapshot) ~= "function"
	then
		return true
	end

	local t = now()

	local okSnapshot, snapshot =
		pcall(GameInfo.getSnapshot, nil, t)

	if
		not okSnapshot
		or type(snapshot) ~= "table"
	then
		return true
	end

	local okTiming, timing =
		pcall(AutoParry.getTiming, snapshot, t)

	if
		not okTiming
		or type(timing) ~= "table"
	then
		return true
	end

	local distance = tonumber(timing.distance)
	local speed = tonumber(timing.speed)

	if
		not distance
		or not speed
		or speed <= 0
		or distance ~= distance
		or speed ~= speed
	then
		return true
	end

	local okRadius, radius =
		pcall(
			AutoParry.getRadius,
			"geometry",
			T.SPAM_PARRY_WINDOW_FACTOR,
			speed
		)

	if
		not okRadius
		or type(radius) ~= "table"
	then
		return true
	end

	local fullRadius = tonumber(radius.fullRadius)

	if
		not fullRadius
		or fullRadius ~= fullRadius
	then
		return true
	end

	Scheduler.parryRadiusLimit = 0

	if distance <= fullRadius then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0

		return true
	end

	local tti = (distance - fullRadius) / speed

	Scheduler.parryRadiusGuard = true
	Scheduler.parryRadiusTTI = tti

	return false
end

----------------------------------------------------------------
-- click
----------------------------------------------------------------

local function click()
	if
		not Remote
		or type(Remote.fireParry) ~= "function"
	then
		Scheduler.lastError = "Remote.fireParry ausente"
		Scheduler.lastErrorAt = now()

		return false
	end

	local ok, result = pcall(Remote.fireParry, 1)

	Scheduler.lastRequestAt = now()

	if ok and result ~= false then
		Scheduler.lastError = nil
		return true
	end

	Scheduler.lastError =
		ok
		and "Remote.fireParry retornou false"
		or tostring(result)

	Scheduler.lastErrorAt = now()

	return false
end

----------------------------------------------------------------
-- config
----------------------------------------------------------------

local function getConfig()
	if not Utils or type(Utils.getConfig) ~= "function" then
		return "CPS", 1
	end

	local config = Utils.getConfig()

	if type(config) ~= "table" then
		return "CPS", 1
	end

	local mode =
		config.SpamRateMode == "CPF"
		and "CPF"
		or config.SpamRateMode == "CHAIN"
		and "CHAIN"
		or "CPS"

	local key = mode == "CPF" and "CPF" or "CPS"

	local rate = tonumber(config[key]) or 0

	return mode, max(rate, 0)
end

----------------------------------------------------------------
-- CPF
--
-- Literal:
--
-- CPF 1 = 1 click/frame
-- CPF 2 = 2 clicks/frame
-- CPF 3 = 3 clicks/frame
--
-- Decimal values are floored because
-- fractional clicks do not exist.
----------------------------------------------------------------

local function runCPF(rate, dt)
	local clicks = floor(rate)

	cpfClicks = clicks

	Scheduler.cpfClicks = clicks
	Scheduler.cpfFps = 1 / dt
	Scheduler.cpfCompensation = false

	if clicks <= 0 then
		return
	end

	for _ = 1, clicks do
		if not isRegularSpamActive() then
			return
		end

		if not radiusAllowed() then
			return
		end

		click()
	end
end

----------------------------------------------------------------
-- CPS
--
-- Literal:
--
-- CPS 1  = 1 click / 1s
-- CPS 2  = 1 click / 0.5s
-- CPS 10 = 1 click / 0.1s
-- CPS 20 = 1 click / 0.05s
--
-- Never catches up with multiple clicks.
----------------------------------------------------------------

local function runCPS(rate)
	if rate <= 0 then
		clearCPS()
		return
	end

	local t = now()

	if
		cpsRate ~= rate
		or cpsGeneration ~= generation
		or cpsNext <= 0
	then
		cpsRate = rate
		cpsInterval = 1 / rate
		cpsGeneration = generation

		cpsNext = t + cpsInterval

		return
	end

	if t < cpsNext then
		return
	end

	if not isRegularSpamActive() then
		clearCPS()
		return
	end

	if not radiusAllowed() then
		clearCPS()
		return
	end

	-- exactly one click
	click()

	-- resynchronize from now;
	-- never dump accumulated clicks.
	cpsNext = t + cpsInterval
end

----------------------------------------------------------------
-- CHAIN
----------------------------------------------------------------

local function runChain()
	local currentGeneration = generation

	while
		currentGeneration == generation
		and isRegularSpamActive()
	do
		if not radiusAllowed() then
			break
		end

		click()

		task.wait()
	end

	chainRunning = false
end

----------------------------------------------------------------
-- tick
----------------------------------------------------------------

local function tick(dt)
	if
		type(dt) ~= "number"
		or dt <= 0
		or dt ~= dt
		or dt == math.huge
		or dt == -math.huge
	then
		return
	end

	------------------------------------------------------------
	-- inactive
	------------------------------------------------------------

	if not isActive() then
		if wasActive then
			invalidate("spam_disabled")
		end

		wasActive = false
		return
	end

	------------------------------------------------------------
	-- cooldown
	------------------------------------------------------------

	local cooldown = getDeflectCooldown()

	if cooldown ~= nil then
		Scheduler.lastCooldownAt = clock()
		Scheduler.lastCooldownValue = cooldown

		if cooldown > T.DEFLECT_COOLDOWN_THRESHOLD then
			if wasActive then
				invalidate("deflect_cooldown")
			end

			wasActive = false
			Scheduler.phase = "cooldown"

			return
		end
	end

	------------------------------------------------------------
	-- regular spam
	------------------------------------------------------------

	if not isRegularSpamActive() then
		wasActive = false
		Scheduler.phase = "stopped"

		return
	end

	if not radiusAllowed() then
		if wasActive then
			invalidate("parry_radius_tti")
		end

		wasActive = false
		Scheduler.phase = "radius_guard"

		return
	end

	------------------------------------------------------------
	-- activation
	------------------------------------------------------------

	if not wasActive then
		Scheduler.phase = "running"

		if Utils and type(Utils.recordTransition) == "function" then
			Utils.recordTransition(
				"Spam",
				"stopped",
				"running",
				"spam_active"
			)
		end
	end

	wasActive = true

	------------------------------------------------------------
	-- config
	------------------------------------------------------------

	local mode, rate = getConfig()

	------------------------------------------------------------
	-- mode change
	------------------------------------------------------------

	if mode ~= lastMode then
		lastMode = mode
		lastRate = nil

		cpfClicks = 0
		clearCPS()
	end

	------------------------------------------------------------
	-- rate change
	------------------------------------------------------------

	if rate ~= lastRate then
		lastRate = rate

		if mode == "CPF" then
			cpfClicks = 0
		elseif mode == "CPS" then
			clearCPS()
		end
	end

	------------------------------------------------------------
	-- CPF
	------------------------------------------------------------

	if mode == "CPF" then
		runCPF(rate, dt)
		return
	end

	------------------------------------------------------------
	-- CPS
	------------------------------------------------------------

	if mode == "CPS" then
		runCPS(rate)
		return
	end

	------------------------------------------------------------
	-- CHAIN
	------------------------------------------------------------

	if mode == "CHAIN" and not chainRunning then
		chainRunning = true
		task.spawn(runChain)
	end
end

----------------------------------------------------------------
-- setup
----------------------------------------------------------------

function Spam.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.Utils) ~= "table"
	then
		return false,
			"dependência ausente: Remote ou Utils"
	end

	if connection then
		pcall(connection.Disconnect, connection)

		if
			Utils
			and type(Utils.untrackGlobal) == "function"
		then
			pcall(Utils.untrackGlobal, connection)
		end

		connection = nil
	end

	Remote = deps.Remote
	Utils = deps.Utils

	GameInfo =
		type(deps.GameInfo) == "table"
		and deps.GameInfo
		or nil

	AutoParry =
		type(deps.AutoParry) == "table"
		and deps.AutoParry
		or nil

	AutoClash =
		type(deps.AutoClash) == "table"
		and deps.AutoClash
		or nil

	if not GameInfo then
		return false, "dependência ausente: GameInfo"
	end

	Spam.resetState()

	local RunService

	if type(Utils.getRunService) == "function" then
		RunService = Utils.getRunService()
	end

	if not RunService then
		RunService = game:GetService("RunService")
	end

	local signal =
		RunService.RenderStepped
		or RunService.Heartbeat

	connection = signal:Connect(tick)

	if type(Utils.trackGlobal) == "function" then
		Utils.trackGlobal(connection)
	end

	return true
end

----------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------

function Spam.resetState()
	invalidate("reset")

	wasActive = false

	Scheduler.phase = "stopped"

	Scheduler.lastRequestAt = 0
	Scheduler.lastError = nil
	Scheduler.lastCooldownAt = 0
	Scheduler.lastCooldownValue = 0
	Scheduler.lastErrorAt = 0

	Scheduler.cpfFps = 0
	Scheduler.cpfClicks = 0
	Scheduler.cpfCompensation = false

	Scheduler.parryRadiusGuard = false
	Scheduler.antiDashRadiusBypass = false
	Scheduler.parryRadiusTTI = 0
	Scheduler.parryRadiusLimit = 0
end

function Spam.teardown()
	if connection then
		if
			Utils
			and type(Utils.untrackGlobal) == "function"
		then
			Utils.untrackGlobal(connection)
		end

		pcall(connection.Disconnect, connection)

		connection = nil
	end

	Spam.resetState()

	Remote = nil
	GameInfo = nil
	Utils = nil
	AutoParry = nil
	AutoClash = nil
end

----------------------------------------------------------------
-- status
----------------------------------------------------------------

function Spam.getStatus()
	return {
		schema =
			Utils
			and type(Utils.apiVersion) == "function"
			and Utils.apiVersion()
			or 1,

		phase = Scheduler.phase,

		lastRequestAt = Scheduler.lastRequestAt,
		lastError = Scheduler.lastError,

		lastCooldownAt = Scheduler.lastCooldownAt,
		lastCooldownValue = Scheduler.lastCooldownValue,

		cpfFps = Scheduler.cpfFps,
		cpfClicks = Scheduler.cpfClicks,
		cpfCompensation = Scheduler.cpfCompensation,

		parryRadiusGuard = Scheduler.parryRadiusGuard,
		antiDashRadiusBypass = Scheduler.antiDashRadiusBypass,
		parryRadiusTTI = Scheduler.parryRadiusTTI,
		parryRadiusLimit = Scheduler.parryRadiusLimit,
	}
end

----------------------------------------------------------------
-- contract
----------------------------------------------------------------

Spam.__contract = {
	requires = {
		Remote = "remote",
		Utils = "utils",
		GameInfo = "gameinfo",
		AutoParry = "autoparry",
		AutoClash = "autoclash",
	},
}

return Spam