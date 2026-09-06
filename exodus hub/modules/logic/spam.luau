-- [[ spam ]]

local Spam = {}
local Remote, GameInfo, Utils
local pcall = pcall
local math_max = math.max
local math_floor = math.floor
local now = os.clock

-- tuning
local DEFLECT_COOLDOWN_THRESHOLD = 0.0
local EMA = 0.08

-- state
local heartbeatConnection
local generation = 0
local wasActive = false
local acumulador = 0
local cpfFps
local cpfCredits = 0
local cpfSent = 0
local lastMode
local lastRate
local chainRunning = false

local Scheduler = {
	phase = "stopped",
	lastRequestAt = 0,
	lastError = nil,
	lastCooldownAt = 0,
	lastCooldownValue = 0,
}

-- helpers
local function invalidate(reason)
	generation = generation + 1
	Scheduler.phase = "stopped"

	acumulador = 0
	cpfFps = nil
	cpfCredits = 0
	cpfSent = 0
	lastMode = nil
	lastRate = nil
	chainRunning = false

	if Utils
		and type(Utils.recordTransition) == "function"
		and wasActive
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
	return Utils.isActive
		and Utils.isSpamActive
		and Utils.isActive()
		and Utils.isSpamActive()
end

local function readDeflectCooldown()
	if not GameInfo
		or type(GameInfo.getDeflectCD) ~= "function"
	then
		return nil
	end

	local ok, value = pcall(GameInfo.getDeflectCD)

	if not ok then
		return nil
	end

	if type(value) ~= "number"
		or value ~= value
		or value == math.huge
	then
		return nil
	end

	return value
end

local function isOnDeflectCooldown()
	local cd = readDeflectCooldown()

	if cd == nil then
		return false
	end

	return cd > DEFLECT_COOLDOWN_THRESHOLD
end

local function requestParry()
	local ok, result = pcall(Remote.fireParry, 1)

	Scheduler.lastRequestAt =
		(Utils.now and Utils.now())
		or now()

	if not ok or result == false then
		Scheduler.lastError =
			not ok
			and tostring(result)
			or "Remote.fireParry retornou false"

		if type(Utils.recordError) == "function" then
			Utils.recordError(
				"Spam",
				Scheduler.lastError
			)
		end

		return false
	end

	Scheduler.lastError = nil
	return true
end

-- [[ CPF ]]
-- CPF = cliques por frame.
-- O FPS usado aqui é o FPS REAL medido pelo dt,
-- suavizado exclusivamente por EMA.
local function scheduleCPF(rate, dt)
	if rate <= 0
		or dt <= 0
		or dt ~= dt
		or dt == math.huge
	then
		return
	end

	local fpsNow = 1 / dt

	if not cpfFps then
		cpfFps = fpsNow
	else
		cpfFps =
			cpfFps
			+ (fpsNow - cpfFps) * EMA
	end

	-- Mantém exatamente a lógica original:
	-- rate * FPS / FPS.
	-- Não existe limite artificial de FPS.
	local fps = cpfFps
	local clicks = rate * fps / fps

	local scheduled = math_floor(clicks)

	for _ = 1, scheduled do
		requestParry()
	end
end

-- [[ CHAIN ]]
-- Uma única task persistente em vez de:
-- task -> parry -> task -> parry -> task...
local function scheduleChain()
	local currentGeneration = generation

	while isActive()
		and currentGeneration == generation
	do
		requestParry()
		task.wait()
	end

	chainRunning = false
end

-- runtime
local function tick(dt)
	if typeof(dt) ~= "number"
		or dt <= 0
		or dt ~= dt
		or dt == math.huge
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

	-- [[ COOLDOWN GUARD ]]
	local deflectCd = readDeflectCooldown()

	if deflectCd ~= nil then
		Scheduler.lastCooldownAt = now()
		Scheduler.lastCooldownValue = deflectCd

		if deflectCd > DEFLECT_COOLDOWN_THRESHOLD then
			if wasActive then
				invalidate("deflect_cooldown")

				if type(Utils.recordError) == "function" then
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

	local config =
		Utils.getConfig
		and Utils.getConfig()

	local configuredMode =
		type(config) == "table"
		and config.SpamRateMode

	local mode

	if configuredMode == "CPF" then
		mode = "CPF"
	elseif configuredMode == "CHAIN" then
		mode = "CHAIN"
	else
		mode = "CPS"
	end

	local rateKey =
		mode == "CPF"
		and "CPF"
		or "CPS"

	local rate =
		type(config) == "table"
		and tonumber(config[rateKey])
		or nil

	rate = math_max(rate or 1, 0)

	if not wasActive then
		Scheduler.phase = "running"

		if type(Utils.recordTransition) == "function" then
			Utils.recordTransition(
				"Spam",
				"stopped",
				"running",
				"spam_enabled"
			)
		end
	end

	wasActive = true

	-- [[ CHAIN ]]
	if mode == "CHAIN" then
		if not chainRunning then
			chainRunning = true
			task.spawn(scheduleChain)
		end

		return
	end

	-- Mudança de modo
	if mode ~= lastMode then
		lastMode = mode
		acumulador = 0
		lastRate = nil
		cpfCredits = 0
		cpfSent = 0
	end

	-- Mudança de rate
	if rate ~= lastRate then
		lastRate = rate

		if mode == "CPF" then
			cpfCredits = 0
			cpfSent = 0
		else
			acumulador = 0
		end
	end

	-- [[ CPF ]]
	if mode == "CPF" then
		scheduleCPF(rate, dt)
		return
	end

	-- [[ CPS ]]
	local intervaloEntreClicks =
		1 / math_max(rate, 1)

	acumulador = acumulador + dt

	local currentGeneration = generation

	while acumulador >= intervaloEntreClicks do
		if currentGeneration ~= generation
			or not isActive()
		then
			return
		end

		-- Sem task.spawn por clique.
		-- Executa diretamente para evitar criação
		-- desnecessária de coroutines.
		requestParry()

		acumulador =
			acumulador - intervaloEntreClicks
	end
end

-- setup
function Spam.setup(deps)
	if type(deps) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.Utils) ~= "table"
	then
		return false,
			"dependência ausente: Remote.fireParry ou Utils"
	end

	if heartbeatConnection then
		pcall(
			heartbeatConnection.Disconnect,
			heartbeatConnection
		)

		if type(Utils.untrackGlobal) == "function" then
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

	Spam.resetState()

	local RunService =
		Utils.getRunService
		and Utils.getRunService()
		or game:GetService("RunService")

	local signal =
		RunService.RenderStepped
		or RunService.Heartbeat

	heartbeatConnection =
		signal:Connect(tick)

	if type(Utils.trackGlobal) == "function" then
		Utils.trackGlobal(heartbeatConnection)
	end

	return true
end

-- lifecycle
function Spam.resetState()
	invalidate("reset")

	wasActive = false
	acumulador = 0
	cpfFps = nil
	cpfCredits = 0
	cpfSent = 0
	lastMode = nil
	lastRate = nil
	chainRunning = false

	Scheduler.phase = "stopped"
	Scheduler.lastRequestAt = 0
	Scheduler.lastError = nil
	Scheduler.lastCooldownAt = 0
	Scheduler.lastCooldownValue = 0
end

function Spam.getStatus()
	return {
		schema =
			Utils.apiVersion
			and Utils.apiVersion()
			or 1,

		phase = Scheduler.phase,
		lastRequestAt = Scheduler.lastRequestAt,
		lastError = Scheduler.lastError,
		lastCooldownAt = Scheduler.lastCooldownAt,
		lastCooldownValue = Scheduler.lastCooldownValue,
	}
end

Spam.__contract = {
	requires = {
		Remote = "remote",
		Utils = "utils",
		GameInfo = "gameinfo",
	},
}

return Spam