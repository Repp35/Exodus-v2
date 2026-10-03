--!strict
--!optimize 2
-- [[ spam ]]

local Spam = {}
local Remote, GameInfo, Utils, AutoParry, AutoClash
local math_max = math.max
local math_floor = math.floor
local clock = os.clock

-- tuning
local T = {
	DEFLECT_COOLDOWN_THRESHOLD = 0,
	TARGET_SWITCH_BOOST_ENABLED = true,
	TARGET_SWITCH_BOOST_MULTIPLIER = 1.5,
	TARGET_SWITCH_BOOST_DURATION = 3,
	TARGET_SWITCH_MIN_CPF = 10,
	TARGET_SWITCH_THRESHOLD_CPS = 15,
	TARGET_SWITCH_PING_FACTOR = 1 / 3,
	SPAM_PARRY_RADIUS_GUARD = false,
	SPAM_PARRY_WINDOW_FACTOR = 1.1,
}

-- state
local heartbeatConnection
local generation = 0
local wasActive = false
local accumulator = 0
local cpfFps
local cpfClickCarry = 0
local lastMode
local lastRate
local chainRunning = false

-- literal CPF/CPS scheduler
local cpsNextClickAt = 0
local cpsScheduledRate = 0
local cpsSchedulerGeneration = 0

local lastTargetSwitchTimestampMs = 0
local lastTargetResetToken
local boostedPartners = {}

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
	targetSwitchBoost = false,
	targetSwitchBoostUntil = 0,
	targetSwitchIntervalMs = 0,
	targetSwitchEffectiveIntervalMs = 0,
	targetSwitchCps = 0,
	parryRadiusGuard = false,
	antiDashRadiusBypass = false,
	parryRadiusTTI = 0,
	parryRadiusLimit = 0,
}

-- helpers
local function getNow()
	if Utils and type(Utils.now) == "function" then
		return Utils.now()
	end

	return clock()
end

local function clearCPSScheduler()
	cpsNextClickAt = 0
	cpsScheduledRate = 0
	cpsSchedulerGeneration = generation
end

local function resetRuntime()
	accumulator = 0
	cpfFps = nil
	cpfClickCarry = 0
	lastMode = nil
	lastRate = nil
	chainRunning = false

	clearCPSScheduler()

	lastTargetSwitchTimestampMs = 0
	lastTargetResetToken = nil
	boostedPartners = {}

	Scheduler.cpfFps = 0
	Scheduler.cpfClicks = 0
	Scheduler.cpfCompensation = false
	Scheduler.targetSwitchBoost = false
	Scheduler.targetSwitchBoostUntil = 0
	Scheduler.targetSwitchIntervalMs = 0
	Scheduler.targetSwitchEffectiveIntervalMs = 0
	Scheduler.targetSwitchCps = 0
	Scheduler.parryRadiusGuard = false
	Scheduler.antiDashRadiusBypass = false
	Scheduler.parryRadiusTTI = 0
	Scheduler.parryRadiusLimit = 0
end

local function invalidate(reason)
	generation = generation + 1
	Scheduler.phase = "stopped"
	resetRuntime()

	if wasActive and Utils and type(Utils.recordTransition) == "function" then
		Utils.recordTransition(
			"Spam",
			"running",
			"stopped",
			reason or "invalidated"
		)
	end
end

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

local function readDeflectCooldown()
	if not GameInfo or type(GameInfo.getDeflectCD) ~= "function" then
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

local function isDashRadiusBypass()
	if not AutoClash or type(AutoClash.getDashData) ~= "function" then
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

local function checkParryRadiusGuard()
	local now = getNow()
	Scheduler.antiDashRadiusBypass = false

	if not T.SPAM_PARRY_RADIUS_GUARD then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		Scheduler.parryRadiusLimit = 0
		return true
	end

	if isDashRadiusBypass() then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		Scheduler.parryRadiusLimit = 0
		return true
	end

	if
		not AutoParry
		or type(AutoParry.getTiming) ~= "function"
		or type(AutoParry.getRadius) ~= "function"
	then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		Scheduler.parryRadiusLimit = 0
		return true
	end

	if not GameInfo or type(GameInfo.getSnapshot) ~= "function" then
		return true
	end

	local okSnapshot, snapshot =
		pcall(GameInfo.getSnapshot, nil, now)

	if not okSnapshot or type(snapshot) ~= "table" then
		return true
	end

	local okTiming, timing =
		pcall(AutoParry.getTiming, snapshot, now)

	if not okTiming or type(timing) ~= "table" then
		return true
	end

	local distance = tonumber(timing.distance)
	local speed = tonumber(timing.speed)

	local okRadius, radiusStatus =
		pcall(
			AutoParry.getRadius,
			"geometry",
			T.SPAM_PARRY_WINDOW_FACTOR,
			speed
		)

	local parryRadius =
		okRadius
		and type(radiusStatus) == "table"
		and tonumber(radiusStatus.fullRadius)
		or nil

	if
		not distance
		or not parryRadius
		or not speed
		or distance ~= distance
		or parryRadius ~= parryRadius
		or speed ~= speed
		or speed <= 0
	then
		return true
	end

	Scheduler.parryRadiusLimit = 0

	if distance <= parryRadius then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		return true
	end

	local distanceToParryRadius = distance - parryRadius
	local tti = distanceToParryRadius / speed

	Scheduler.parryRadiusGuard = true
	Scheduler.parryRadiusTTI = tti

	return false
end

local function requestParry()
	local ok, result = pcall(Remote.fireParry, 1)
	local timestamp = getNow()

	Scheduler.lastRequestAt = timestamp

	if ok and result ~= false then
		Scheduler.lastError = nil
		return true
	end

	local errorMessage

	if not ok then
		errorMessage = tostring(result)
	else
		errorMessage = "Remote.fireParry retornou false"
	end

	Scheduler.lastError = errorMessage
	return false
end

-- CPF
-- Literal: N clicks por frame.
local function scheduleCPF(rate, dt)
	if rate <= 0 then
		Scheduler.cpfClicks = 0
		return
	end

	local clicks = math_floor(rate)

	Scheduler.cpfFps = 1 / dt
	Scheduler.cpfCompensation = false
	Scheduler.cpfClicks = clicks

	for _ = 1, clicks do
		if not isRegularSpamActive() then
			return
		end

		if not checkParryRadiusGuard() then
			return
		end

		requestParry()
	end
end

-- chain
local function scheduleChain()
	local currentGeneration = generation

	while currentGeneration == generation and isRegularSpamActive() do
		if not checkParryRadiusGuard() then
			invalidate("parry_radius_tti")
			break
		end

		requestParry()
		task.wait()
	end

	chainRunning = false
end

-- config
local function getModeAndRate()
	local config

	if Utils and type(Utils.getConfig) == "function" then
		config = Utils.getConfig()
	end

	if type(config) ~= "table" then
		return "CPS", 1
	end

	local configuredMode = config.SpamRateMode
	local mode

	if configuredMode == "CPF" then
		mode = "CPF"
	elseif configuredMode == "CHAIN" then
		mode = "CHAIN"
	else
		mode = "CPS"
	end

	local rateKey = mode == "CPF" and "CPF" or "CPS"
	local rate = tonumber(config[rateKey]) or 1

	return mode, math_max(rate, 0)
end

local function getTargetSwitchRate()
	if not AutoClash or type(AutoClash.getTargetSwitch) ~= "function" then
		return nil
	end

	local ok, switch = pcall(AutoClash.getTargetSwitch)

	if not ok or type(switch) ~= "table" then
		return nil
	end

	local timestampMs = tonumber(switch.timestampMs)
	local intervalMs = tonumber(switch.intervalMs)
	local partnerId = tonumber(switch.partnerId)
	local resetToken = tonumber(switch.resetToken)

	if not resetToken then
		return nil
	end

	if resetToken ~= lastTargetResetToken then
		lastTargetResetToken = resetToken
		boostedPartners = {}
	end

	if
		not timestampMs
		or not intervalMs
		or not partnerId
		or timestampMs <= 0
		or intervalMs <= 0
		or partnerId == -1
	then
		return nil
	end

	if timestampMs <= lastTargetSwitchTimestampMs then
		return nil
	end

	lastTargetSwitchTimestampMs = timestampMs

	local pingOneWay = 0

	if AutoParry and type(AutoParry.getStatus) == "function" then
		local pingOk, status = pcall(AutoParry.getStatus)

		if
			pingOk
			and type(status) == "table"
			and type(status.ping) == "table"
		then
			pingOneWay = tonumber(status.ping.oneWay) or 0
		end
	end

	if
		pingOneWay ~= pingOneWay
		or pingOneWay == math.huge
		or pingOneWay == -math.huge
	then
		pingOneWay = 0
	end

	local compensationMs =
		math.max(pingOneWay, 0)
		* T.TARGET_SWITCH_PING_FACTOR

	local effectiveIntervalMs =
		math.max(intervalMs - compensationMs, 1)

	local cps = 1000 / effectiveIntervalMs

	return {
		intervalMs = intervalMs,
		effectiveIntervalMs = effectiveIntervalMs,
		cps = cps,
		partnerId = partnerId,
		resetToken = resetToken,
	}
end

-- Mantido apenas para atualizar os dados do target switch.
-- NÃO altera mais o CPF/CPS configurado.
local function updateTargetSwitchStatus()
	local switchRate = getTargetSwitchRate()

	if not switchRate then
		Scheduler.targetSwitchBoost = false
		return
	end

	Scheduler.targetSwitchIntervalMs = switchRate.intervalMs
	Scheduler.targetSwitchEffectiveIntervalMs =
		switchRate.effectiveIntervalMs
	Scheduler.targetSwitchCps = switchRate.cps

	local active =
		T.TARGET_SWITCH_BOOST_ENABLED
		and getNow() < Scheduler.targetSwitchBoostUntil

	if active then
		Scheduler.targetSwitchBoost = true
	else
		Scheduler.targetSwitchBoost = false
	end
end

-- CPS
-- Literal: 1 click a cada 1 / rate segundos.
-- Nunca acumula clicks atrasados.
local function clearCPSSchedulerState()
	cpsNextClickAt = 0
	cpsScheduledRate = 0
	cpsSchedulerGeneration = generation
end

local function scheduleNaturalCPS(rate)
	if rate <= 0 then
		clearCPSSchedulerState()
		return
	end

	local now = getNow()

	if
		cpsNextClickAt <= 0
		or cpsScheduledRate ~= rate
		or cpsSchedulerGeneration ~= generation
	then
		cpsScheduledRate = rate
		cpsSchedulerGeneration = generation

		local interval = 1 / rate
		cpsNextClickAt = now + interval

		return
	end

	if now < cpsNextClickAt then
		return
	end

	if not isRegularSpamActive() or not checkParryRadiusGuard() then
		clearCPSSchedulerState()
		return
	end

	-- exatamente 1 click
	requestParry()

	-- próximo click exatamente 1/CPS depois deste.
	-- sem catch-up e sem enviar vários de uma vez.
	cpsNextClickAt = now + (1 / rate)
end

-- runtime
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

	if not isActive() then
		if wasActive then
			invalidate("spam_disabled")
		end

		wasActive = false
		return
	end

	local deflectCd = readDeflectCooldown()

	if deflectCd ~= nil then
		Scheduler.lastCooldownAt = clock()
		Scheduler.lastCooldownValue = deflectCd

		if deflectCd > T.DEFLECT_COOLDOWN_THRESHOLD then
			if wasActive then
				invalidate("deflect_cooldown")
			end

			wasActive = false
			Scheduler.phase = "cooldown"

			return
		end
	end

	local manualSpamActive =
		Utils
		and type(Utils.isManualSpamActive) == "function"
		and Utils.isManualSpamActive()

	local autoSpamActive =
		Utils
		and type(Utils.isAutoSpamActive) == "function"
		and Utils.isAutoSpamActive()

	local regularSpamActive =
		manualSpamActive or autoSpamActive

	if regularSpamActive and not checkParryRadiusGuard() then
		if wasActive then
			invalidate("parry_radius_tti")
		end

		wasActive = false
		Scheduler.phase = "radius_guard"

		return
	end

	if not regularSpamActive then
		wasActive = false
		Scheduler.phase = "stopped"
		return
	end

	local mode, rate = getModeAndRate()

	-- Atualiza target-switch sem modificar a taxa literal.
	updateTargetSwitchStatus()

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

	-- CHAIN
	if mode == "CHAIN" then
		if not chainRunning then
			chainRunning = true
			task.spawn(scheduleChain)
		end

		return
	end

	if mode ~= lastMode then
		lastMode = mode
		lastRate = nil
		accumulator = 0
		cpfClickCarry = 0

		clearCPSSchedulerState()
	end

	if rate ~= lastRate then
		lastRate = rate

		if mode == "CPF" then
			cpfClickCarry = 0
		else
			accumulator = 0
			clearCPSSchedulerState()
		end
	end

	-- CPF
	if mode == "CPF" then
		scheduleCPF(rate, dt)
		return
	end

	-- CPS
	if rate <= 0 then
		accumulator = 0
		clearCPSSchedulerState()
		return
	end

	scheduleNaturalCPS(rate)
end

-- setup
function Spam.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.Utils) ~= "table"
		or type(deps.AutoClash) ~= "table"
		or type(deps.AutoClash.getTargetSwitch) ~= "function"
		or type(deps.AutoClash.getDashData) ~= "function"
		or type(deps.AutoParry) ~= "table"
		or type(deps.AutoParry.getStatus) ~= "function"
		or type(deps.AutoParry.getRadius) ~= "function"
	then
		return false, "dependência ausente: Remote, Utils, AutoClash ou AutoParry"
	end

	if heartbeatConnection then
		pcall(heartbeatConnection.Disconnect, heartbeatConnection)

		if Utils and type(Utils.untrackGlobal) == "function" then
			pcall(Utils.untrackGlobal, heartbeatConnection)
		end

		heartbeatConnection = nil
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

	AutoClash = deps.AutoClash

	if not GameInfo then
		return false, "dependência ausente: GameInfo"
	end

	if
		T.SPAM_PARRY_RADIUS_GUARD
		and (
			not AutoParry
			or type(AutoParry.getTiming) ~= "function"
			or type(AutoParry.getRadius) ~= "function"
		)
	then
		return false, "dependência ausente: AutoParry.getTiming"
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

	heartbeatConnection = signal:Connect(tick)

	if type(Utils.trackGlobal) == "function" then
		Utils.trackGlobal(heartbeatConnection)
	end

	return true
end

-- lifecycle
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
	Scheduler.targetSwitchBoost = false
	Scheduler.targetSwitchBoostUntil = 0
	Scheduler.targetSwitchIntervalMs = 0
	Scheduler.targetSwitchEffectiveIntervalMs = 0
	Scheduler.targetSwitchCps = 0
	Scheduler.parryRadiusGuard = false
	Scheduler.antiDashRadiusBypass = false
	Scheduler.parryRadiusTTI = 0
	Scheduler.parryRadiusLimit = 0
end

function Spam.teardown()
	if heartbeatConnection then
		if Utils and type(Utils.untrackGlobal) == "function" then
			Utils.untrackGlobal(heartbeatConnection)
		end

		pcall(heartbeatConnection.Disconnect, heartbeatConnection)
		heartbeatConnection = nil
	end

	Spam.resetState()

	Remote = nil
	GameInfo = nil
	Utils = nil
	AutoParry = nil
	AutoClash = nil
end

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

		targetSwitchBoost = Scheduler.targetSwitchBoost,
		targetSwitchBoostUntil = Scheduler.targetSwitchBoostUntil,
		targetSwitchIntervalMs = Scheduler.targetSwitchIntervalMs,
		targetSwitchEffectiveIntervalMs =
			Scheduler.targetSwitchEffectiveIntervalMs,
		targetSwitchCps = Scheduler.targetSwitchCps,

		parryRadiusGuard = Scheduler.parryRadiusGuard,
		antiDashRadiusBypass = Scheduler.antiDashRadiusBypass,
		parryRadiusTTI = Scheduler.parryRadiusTTI,
		parryRadiusLimit = Scheduler.parryRadiusLimit,
	}
end

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