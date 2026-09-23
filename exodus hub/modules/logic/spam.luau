-- [[ Spam ]]

local Spam = {}
local Remote, GameInfo, Utils, AutoParry, AutoClash

local math_max = math.max
local math_floor = math.floor
local clock = os.clock

-- tuning
local DEFLECT_COOLDOWN_THRESHOLD = 0
local CPF_MIN_FPS = 60
local CPF_AVERAGE_ALPHA = 0.08
local TARGET_SWITCH_BOOST_ENABLED = true
local TARGET_SWITCH_BOOST_MULTIPLIER = 1.5
local TARGET_SWITCH_BOOST_DURATION = 3
local TARGET_SWITCH_MIN_CPF = 10
local TARGET_SWITCH_THRESHOLD_CPS = 15
local TARGET_SWITCH_PING_FACTOR = 1 / 3

-- parry radius guard
local SPAM_PARRY_RADIUS_GUARD = false
local SPAM_PARRY_TTI_MS = 150

-- state
local heartbeatConnection
local generation = 0
local wasActive = false
local accumulator = 0
local cpfFps
local lastMode
local lastRate
local chainRunning = false

-- click scheduler
local clickQueue = 0
local clickAccumulator = 0
local clickInterval = 0

-- cpf scheduler
local cpfAverageDt = 1 / CPF_MIN_FPS
local cpfClickAccumulator = 0
local cpfFrameTime = 1 / CPF_MIN_FPS
local cpfLastDt = 0
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

local function resetRuntime()
	accumulator = 0
	cpfFps = nil
	lastMode = nil
	lastRate = nil
	chainRunning = false

	clickQueue = 0
	clickAccumulator = 0
	clickInterval = 0

	cpfAverageDt = 1 / CPF_MIN_FPS
	cpfClickAccumulator = 0
	cpfFrameTime = 1 / CPF_MIN_FPS
	cpfLastDt = 0
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
	Scheduler.parryRadiusTTI = 0
	Scheduler.parryRadiusLimit = 0
end

local function invalidate(reason)
	generation = generation + 1
	Scheduler.phase = "stopped"

	resetRuntime()

	if wasActive
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

local function isActive()
	if not Utils
		or type(Utils.isActive) ~= "function"
		or type(Utils.isSpamActive) ~= "function"
	then
		return false
	end

	return Utils.isActive()
		and Utils.isSpamActive()
end

local function readDeflectCooldown()
	if not GameInfo
		or type(GameInfo.getDeflectCD) ~= "function"
	then
		return nil
	end

	local ok, value = pcall(GameInfo.getDeflectCD)

	if not ok
		or type(value) ~= "number"
		or value ~= value
		or value == math.huge
		or value == -math.huge
	then
		return nil
	end

	return value
end

-- parry radius guard
local function checkParryRadiusGuard()
	if not SPAM_PARRY_RADIUS_GUARD then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		Scheduler.parryRadiusLimit = 0

		return true
	end

	if not AutoParry
		or type(AutoParry.getTiming) ~= "function"
	then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0
		Scheduler.parryRadiusLimit = 0

		return true
	end

	if not GameInfo
		or type(GameInfo.getSnapshot) ~= "function"
	then
		return true
	end

	local now = getNow()

	local okSnapshot, snapshot =
		pcall(
			GameInfo.getSnapshot,
			nil,
			now
		)

	if not okSnapshot
		or type(snapshot) ~= "table"
	then
		return true
	end

	local okTiming, timing =
		pcall(
			AutoParry.getTiming,
			snapshot,
			now
		)

	if not okTiming
		or type(timing) ~= "table"
	then
		return true
	end

	local distance = tonumber(timing.distance)
	local parryRadius = tonumber(timing.parryRadius)
	local speed = tonumber(timing.speed)

	if not distance
		or not parryRadius
		or not speed
		or distance ~= distance
		or parryRadius ~= parryRadius
		or speed ~= speed
		or speed <= 0
	then
		return true
	end

	local limit = SPAM_PARRY_TTI_MS / 1000

	Scheduler.parryRadiusLimit = limit

	-- Já está dentro do raio do AutoParry.
	if distance <= parryRadius then
		Scheduler.parryRadiusGuard = false
		Scheduler.parryRadiusTTI = 0

		return true
	end

	-- Distância que falta para alcançar o raio.
	local distanceToParryRadius =
		distance - parryRadius

	-- Time To Impact até o raio.
	--
	-- Não é contador.
	-- É apenas a distância restante
	-- dividida pela velocidade atual.
	local tti =
		distanceToParryRadius / speed

	Scheduler.parryRadiusGuard = true
	Scheduler.parryRadiusTTI = tti

	return tti <= limit
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

	if timestamp - Scheduler.lastErrorAt >= 1 then
		Scheduler.lastErrorAt = timestamp

		if Utils
			and type(Utils.recordError) == "function"
		then
			Utils.recordError(
				"Spam",
				errorMessage
			)
		end
	end

	return false
end

-- click scheduler
local function queueClicks(clicks, interval)
	if clicks <= 0 then
		return
	end

	clickQueue = clickQueue + clicks

	if interval > 0 then
		clickInterval = interval
	end
end

local function processClickQueue(dt)
	if clickQueue <= 0 then
		clickAccumulator = 0
		return
	end

	if clickInterval <= 0 then
		local currentGeneration = generation

		while clickQueue > 0 do
			if currentGeneration ~= generation
				or not isActive()
				or not checkParryRadiusGuard()
			then
				clickQueue = 0
				clickAccumulator = 0
				return
			end

			requestParry()
			clickQueue = clickQueue - 1
		end

		clickAccumulator = 0
		return
	end

	clickAccumulator = clickAccumulator + dt

	local currentGeneration = generation

	while clickQueue > 0
		and clickAccumulator >= clickInterval
	do
		if currentGeneration ~= generation
			or not isActive()
			or not checkParryRadiusGuard()
		then
			clickQueue = 0
			clickAccumulator = 0
			return
		end

		clickAccumulator =
			clickAccumulator - clickInterval

		clickQueue = clickQueue - 1

		requestParry()
	end
end

-- cpf
local function scheduleCPF(rate, dt)
	if rate <= 0 then
		Scheduler.cpfClicks = 0

		cpfClickAccumulator = 0
		cpfLastDt = dt

		clickQueue = 0
		clickAccumulator = 0
		clickInterval = 0

		return
	end

	-- Média exponencial do tempo dos frames.
	if dt < 1 / CPF_MIN_FPS then
		local frameDt = dt

		cpfAverageDt =
			cpfAverageDt
			+ (frameDt - cpfAverageDt)
			* CPF_AVERAGE_ALPHA
	else
		cpfAverageDt =
			cpfAverageDt
			+ (dt - cpfAverageDt)
			* CPF_AVERAGE_ALPHA
	end

	-- O piso é 60 FPS.
	local minimumFrameTime = 1 / CPF_MIN_FPS

	if cpfAverageDt > minimumFrameTime then
		cpfFrameTime = minimumFrameTime
	else
		cpfFrameTime = cpfAverageDt
	end

	cpfFps = 1 / cpfFrameTime

	Scheduler.cpfFps = cpfFps
	Scheduler.cpfCompensation = false

	-- CPF = quantidade de clicks dentro
	-- da janela média.
	local interval = cpfFrameTime / rate

	if interval <= 0 then
		interval = cpfFrameTime
	end

	clickInterval = interval

	cpfClickAccumulator =
		cpfClickAccumulator + rate

	local clicksToQueue =
		math_floor(cpfClickAccumulator)

	if clicksToQueue > 0 then
		cpfClickAccumulator =
			cpfClickAccumulator - clicksToQueue

		queueClicks(
			clicksToQueue,
			interval
		)
	end

	Scheduler.cpfClicks = clicksToQueue
	cpfLastDt = dt
end

-- chain
local function scheduleChain()
	local currentGeneration = generation

	while currentGeneration == generation
		and isActive()
	do
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
	if not AutoClash
		or type(AutoClash.getTargetSwitch) ~= "function"
	then
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

	if not timestampMs
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
	if AutoParry and type(AutoParry.getPingOneWay) == "function" then
		local pingOk, value = pcall(AutoParry.getPingOneWay)
		if pingOk then
			pingOneWay = tonumber(value) or 0
		end
	end
	if pingOneWay ~= pingOneWay
		or pingOneWay == math.huge
		or pingOneWay == -math.huge
	then
		pingOneWay = 0
	end

	local compensationMs = math.max(pingOneWay, 0)
		* TARGET_SWITCH_PING_FACTOR
	local effectiveIntervalMs = math.max(intervalMs - compensationMs, 1)
	local cps = 1000 / effectiveIntervalMs

	return {
		intervalMs = intervalMs,
		effectiveIntervalMs = effectiveIntervalMs,
		cps = cps,
		partnerId = partnerId,
		resetToken = resetToken,
	}
end

local function applyTargetSwitchBoost(mode, rate)
	local switchRate = getTargetSwitchRate()
	if switchRate then
		Scheduler.targetSwitchIntervalMs = switchRate.intervalMs
		Scheduler.targetSwitchEffectiveIntervalMs = switchRate.effectiveIntervalMs
		Scheduler.targetSwitchCps = switchRate.cps
		if TARGET_SWITCH_BOOST_ENABLED
			and mode == "CPF"
			and rate > TARGET_SWITCH_MIN_CPF
			and switchRate.cps > TARGET_SWITCH_THRESHOLD_CPS
		then
			local partnerKey = tostring(switchRate.partnerId)
			if not boostedPartners[partnerKey] then
				boostedPartners[partnerKey] = true
				Scheduler.targetSwitchBoostUntil = getNow()
					+ TARGET_SWITCH_BOOST_DURATION
			end
		end
	end

	local active = TARGET_SWITCH_BOOST_ENABLED
		and mode == "CPF"
		and rate > TARGET_SWITCH_MIN_CPF
		and getNow() < Scheduler.targetSwitchBoostUntil
	Scheduler.targetSwitchBoost = active

	if active then
		return rate * TARGET_SWITCH_BOOST_MULTIPLIER
	end
	return rate
end

-- runtime
local function tick(dt)
	if type(dt) ~= "number"
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

		if deflectCd > DEFLECT_COOLDOWN_THRESHOLD then
			if wasActive then
				invalidate("deflect_cooldown")

				if Utils
					and type(Utils.recordError) == "function"
				then
					Utils.recordError(
						"Spam",
						string.format(
							"deflect cooldown ativo (%.3fs) — spam desligado",
							deflectCd
						)
					)
				end
			end

			wasActive = false
			Scheduler.phase = "cooldown"

			return
		end
	end

	-- Guarda geométrica:
	-- verifica diretamente o TTI até o raio
	-- do AutoParry.
	if not checkParryRadiusGuard() then
		if wasActive then
			invalidate("parry_radius_tti")
		end

		wasActive = false
		Scheduler.phase = "radius_guard"

		return
	end

	local mode, rate = getModeAndRate()
	rate = applyTargetSwitchBoost(mode, rate)

	if not wasActive then
		Scheduler.phase = "running"

		if Utils
			and type(Utils.recordTransition) == "function"
		then
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

	-- MODE CHANGE
	if mode ~= lastMode then
		lastMode = mode
		lastRate = nil

		accumulator = 0
		cpfFps = nil

		clickQueue = 0
		clickAccumulator = 0
		clickInterval = 0

		cpfAverageDt = 1 / CPF_MIN_FPS
		cpfClickAccumulator = 0
		cpfFrameTime = 1 / CPF_MIN_FPS
		cpfLastDt = 0
	end

	-- RATE CHANGE
	if rate ~= lastRate then
		lastRate = rate

		if mode == "CPF" then
			cpfFps = nil
			cpfAverageDt = 1 / CPF_MIN_FPS
			cpfClickAccumulator = 0
			cpfFrameTime = 1 / CPF_MIN_FPS
			cpfLastDt = 0
		else
			accumulator = 0
		end

		clickQueue = 0
		clickAccumulator = 0
		clickInterval = 0
	end

	-- CPF
	if mode == "CPF" then
		scheduleCPF(rate, dt)
		processClickQueue(dt)
		return
	end

	-- CPS
	if rate <= 0 then
		accumulator = 0
		clickQueue = 0
		clickAccumulator = 0
		clickInterval = 0

		return
	end

	local interval = 1 / rate

	accumulator = accumulator + dt

	local currentGeneration = generation

	if accumulator >= interval then
		local clicks =
			math_floor(
				accumulator / interval
			)

		accumulator =
			accumulator - (
				clicks * interval
			)

		if accumulator < 0 then
			accumulator = 0
		end

		if currentGeneration ~= generation
			or not isActive()
			or not checkParryRadiusGuard()
		then
			return
		end

		queueClicks(
			clicks,
			interval
		)
	end

	processClickQueue(dt)
end

-- setup
function Spam.setup(deps)
	if type(deps) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.Utils) ~= "table"
		or type(deps.AutoClash) ~= "table"
		or type(deps.AutoClash.getTargetSwitch) ~= "function"
		or type(deps.AutoParry) ~= "table"
		or type(deps.AutoParry.getPingOneWay) ~= "function"
	then
		return false, "dependência ausente: Remote, Utils, AutoClash ou AutoParry"
	end

	if heartbeatConnection then
		pcall(
			heartbeatConnection.Disconnect,
			heartbeatConnection
		)

		if Utils
			and type(Utils.untrackGlobal) == "function"
		then
			pcall(
				Utils.untrackGlobal,
				heartbeatConnection
			)
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

	if SPAM_PARRY_RADIUS_GUARD
		and (
			not AutoParry
			or type(AutoParry.getTiming) ~= "function"
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
	Scheduler.parryRadiusTTI = 0
	Scheduler.parryRadiusLimit = 0
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
		targetSwitchEffectiveIntervalMs = Scheduler.targetSwitchEffectiveIntervalMs,
		targetSwitchCps = Scheduler.targetSwitchCps,

		parryRadiusGuard = Scheduler.parryRadiusGuard,
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
	},
}

return Spam
