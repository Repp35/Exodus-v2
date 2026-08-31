-- [[ Auto Clash ]]
--
-- Responsabilidade única: detectar o clash e controlar o ciclo do Auto Clash.
-- Quando ativa, a rotina liga diretamente o Manual Spam para reutilizar
-- exatamente o mesmo motor de disparo.
--
-- Pipeline de dados (sem intermediários redundantes):
--   remote.onBallSync → GameInfo.applySync  (snapshot atualizado)
--   remote.onBallSync → AutoClash.onBallSync (detecta transição de target)
--   character Heartbeat → AutoClash.evaluate (decide ativar/desativar)
--
-- Regras:
--   ATIVAÇÃO  → target era meu → deixou de ser → voltou dentro de
--               returnWindow (lerp por speed + ping factor).
--               Após ativar, NÃO reavalia o target. Spam fica ON
--               indefinidamente até a regra de desativação disparar.
--   DESATIVAÇÃO → independente do target. Mede distância bola→root.
--               Se ficou fora do parryRadius durante
--               activationTime * DEACT_TIME_FACTOR, desativa.
--   TOGGLE     → se config.AutoClash == false, desativa imediatamente
--               e ignora qualquer transição.

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
	RETURN_WIN_START = 0.110,
	RETURN_WIN_END = 0.060,
	RETURN_SPD_START = 60,
	RETURN_SPD_END = 600,
	PING_FACTOR = 0.3,
	ACTIVATION_ADDITIONAL_TIME = 0.250,
	DEACT_TIME_FACTOR = 1.1,
	MIN_EVAL_INTERVAL = 1 / 120,
	TELEPORT_GRACE_TIME = 0.20,
}

-- runtime
local R = {
	generation = 0,
	bound = false,
	active = false,
	ownsSpam = false,
	phase = "detached",
	boundRoot = nil,
	localUserId = nil,
	lastTarget = -1,
	lastSpeed = 0,
	parryRadius = 0,
	lostMeAt = 0,
	armed = false,
	outsideParryAt = 0,
	lastEvalAt = 0,
	teleportLockUntil = 0,
	connections = {},
	lastGate = "none",
}

-- helpers
local function lerp(a, b, alpha)
	return a + (b - a) * alpha
end

local function getNow()
	return Utils and Utils.now() or os.clock()
end

local function getPingOneWay()
	if not AutoParry or type(AutoParry.getPingOneWay) ~= "function" then
		return 0
	end
	local ok, ping = pcall(AutoParry.getPingOneWay)
	return ok and (tonumber(ping) or 0) or 0
end

local function getActivationTime()
	return T.ACTIVATION_ADDITIONAL_TIME + getPingOneWay() * T.PING_FACTOR
end

local function getDeactivationTime()
	return getActivationTime() * T.DEACT_TIME_FACTOR
end

local function returnWindow(speed)
	speed = tonumber(speed) or 0
	local span = T.RETURN_SPD_END - T.RETURN_SPD_START
	local alpha = 0
	if span > 0 then
		alpha = math.clamp((speed - T.RETURN_SPD_START) / span, 0, 1)
	end
	return lerp(T.RETURN_WIN_START, T.RETURN_WIN_END, alpha)
		+ getPingOneWay() * T.PING_FACTOR
end

local function setPhase(phase, reason)
	if R.phase == phase then
		return
	end
	local previous = R.phase
	R.phase = phase
	if Utils and type(Utils.recordTransition) == "function" then
		pcall(Utils.recordTransition, "AutoClash", previous, phase, reason)
	end
end

local function setActive(active, reason)
	active = active == true
	if R.active == active then
		return
	end
	if Utils and type(Utils.setManualSpamActive) == "function" then
		if active then
			-- Auto Clash usa exatamente o mesmo caminho do Manual Spam.
			local ok, accepted = pcall(Utils.setManualSpamActive, true, "autoclash")
			if not ok or accepted == false then
				return
			end
			R.ownsSpam = true
		elseif R.ownsSpam then
			R.ownsSpam = false
			pcall(Utils.setManualSpamActive, false, "autoclash")
		end
	end
	R.active = active
	setPhase(active and "active" or "idle", reason)
end

local function disconnectConnections()
	for i = #R.connections, 1, -1 do
		local connection = R.connections[i]
		R.connections[i] = nil
		if Utils and type(Utils.untrackCharacter) == "function" then
			pcall(Utils.untrackCharacter, connection)
		end
		pcall(function()
			connection:Disconnect()
		end)
	end
end

local function clearArmed(reason)
	if R.armed then
		R.armed = false
	end
	R.lostMeAt = 0
	if reason then
		R.lastGate = reason
	end
end

local function clearOutsideParry()
	R.outsideParryAt = 0
end

local function resetRuntime(reason)
	R.generation = R.generation + 1
	if R.active then
		setActive(false, reason or "reset")
	end
	disconnectConnections()
	R.bound = false
	R.boundRoot = nil
	R.lastTarget = -1
	R.lastSpeed = 0
	R.parryRadius = 0
	clearArmed("reset")
	clearOutsideParry()
	R.lastEvalAt = 0
	R.teleportLockUntil = 0
	R.lastGate = "detached"
	setPhase("detached", reason or "reset")
end

local function isCharacterValid(character, root)
	return character
		and character.Parent
		and root
		and root.Parent
end

local function getConfigEnabled()
	if not Utils or type(Utils.getConfig) ~= "function" then
		return false
	end
	local config = Utils.getConfig()
	return type(config) == "table" and config.AutoClash == true
end

-- desativação: puramente distância da bola ao root.
-- se ficar fora do parryRadius por getDeactivationTime() → desativa.
local function evaluateDeactivation(t, ball, root)
	if not (ball and ball.Parent) then
		clearOutsideParry()
		R.lastGate = "no_ball"
		return false
	end
	local ballPos = ball.Position
	local rootPos = root.Position
	if not (ballPos and rootPos) then
		clearOutsideParry()
		R.lastGate = "no_position"
		return false
	end
	local distance = (ballPos - rootPos).Magnitude
	if R.parryRadius <= 0 then
		clearOutsideParry()
		R.lastGate = "no_radius"
		return false
	end
	if distance <= R.parryRadius then
		clearOutsideParry()
		R.lastGate = "inside_parry_radius"
		return false
	end
	-- fora do raio: começar (ou continuar) a contar
	if R.outsideParryAt <= 0 then
		R.outsideParryAt = t
		R.lastGate = "outside_parry_started"
		return false
	end
	local elapsed = t - R.outsideParryAt
	if elapsed < getDeactivationTime() then
		R.lastGate = "outside_parry_waiting"
		return false
	end
	R.lastGate = "outside_parry_timeout"
	return true
end

-- ativação: usa o snapshot do GameInfo (fonte canônica do alvo).
-- se armed=true E snapshot.targeted=true → ativa. Uma vez. Sem reavaliar.
local function evaluateActivation(snapshot)
	if R.armed ~= true then
		R.lastGate = "awaiting_armed"
		return false
	end
	if not snapshot then
		R.lastGate = "no_snapshot"
		return false
	end
	if snapshot.targeted ~= true then
		R.lastGate = "snapshot_not_targeted"
		return false
	end
	R.armed = false
	R.lostMeAt = 0
	R.lastGate = "target_returned"
	return true
end

-- loop principal: roda a cada frame do Heartbeat do character.
-- depois de ativo, NÃO consulta mais a regra de ativação: só desativação.
local function onHeartbeat(generation, character, root)
	if generation ~= R.generation then
		return
	end
	if not isCharacterValid(character, root) then
		if R.active then
			setActive(false, "character_invalid")
		end
		clearArmed("character_invalid")
		clearOutsideParry()
		return
	end

	local t = getNow()

	-- hub inativo / AutoClash desativado / manual spam ligado / teleport grace:
	-- apenas limpa estado local e desativa. Não arma nada.
	if not Utils.isActive() then
		if R.active then
			setActive(false, "hub_inactive")
		end
		clearArmed("hub_inactive")
		clearOutsideParry()
		R.lastGate = "hub_inactive"
		return
	end

	if not getConfigEnabled() then
		if R.active then
			setActive(false, "auto_clash_disabled")
		end
		clearArmed("auto_clash_disabled")
		clearOutsideParry()
		R.lastGate = "auto_clash_disabled"
		return
	end

	if Utils.isManualSpamActive() and not R.active then
		clearArmed("manual_spam_active")
		clearOutsideParry()
		R.lastGate = "manual_spam_active"
		return
	end

	if t < R.teleportLockUntil then
		if R.active then
			setActive(false, "teleport_grace")
		end
		clearArmed("teleport_grace")
		clearOutsideParry()
		R.lastGate = "teleport_grace"
		return
	end

	-- throttle: se tickar antes do intervalo mínimo, não faz nada.
	if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
		return
	end
	R.lastEvalAt = t

	-- snapshot do GameInfo: fonte canônica da bola, posição, target.
	local snapshot = GameInfo.getSnapshot(R.lastTarget, t)
	if not snapshot or not GameInfo.isSnapshotValid(snapshot, t) then
		-- se estávamos ativos, mantemos; a desativação por distância usa só
		-- o ball + root, não o snapshot. Mas sem ball válido não dá pra
		-- desativar com critério de distância. Mantém estado anterior.
		if R.active then
			-- sem ball válido: NÃO desativa, mantém spam.
			R.lastGate = "active_no_snapshot"
		else
			R.lastGate = "no_snapshot"
		end
		return
	end

	-- atualizar raio de parry REAL (não detection) usando o AP
	R.lastSpeed = tonumber(snapshot.speed) or 0
	if AutoParry and type(AutoParry.getParryRadius) == "function" then
		local ok, radius = pcall(AutoParry.getParryRadius, R.lastSpeed, t)
		if ok and tonumber(radius) and tonumber(radius) > 0 then
			R.parryRadius = tonumber(radius)
		end
	end

	-- regra de desativação (independente de target)
	if R.active then
		if evaluateDeactivation(t, snapshot.ball, root) then
			setActive(false, "outside_parry_timeout")
			clearArmed("deactivated")
			clearOutsideParry()
		end
		return
	end

	-- regra de ativação (só se inativo)
	if evaluateActivation(snapshot) then
		setActive(true, "target_returned")
		clearOutsideParry()
	end
end

local function bindCharacter(character)
	resetRuntime("rebind")
	if not character or not character.Parent then
		return false
	end
	local generation = R.generation

	local root =
		character:FindFirstChild("HumanoidRootPart")
		or character:WaitForChild("HumanoidRootPart", 1)

	if generation ~= R.generation or not root or not root.Parent then
		return false
	end

	R.boundRoot = root
	R.lastGate = "waiting_for_character"

	local heartbeat = Utils.getRunService().Heartbeat:Connect(function()
		onHeartbeat(generation, character, root)
	end)
	R.connections[#R.connections + 1] = heartbeat
	Utils.trackCharacter(heartbeat)

	local ancestry = character.AncestryChanged:Connect(function(_, parent)
		if parent or generation ~= R.generation then
			return
		end
		if R.active then
			setActive(false, "character_removed")
		end
		resetRuntime("character_removed")
		R.lastGate = "character_removed"
	end)
	R.connections[#R.connections + 1] = ancestry
	Utils.trackCharacter(ancestry)

	R.bound = true
	setPhase("waiting", "character_bound")
	return true
end

-- setup
function AutoClash.setup(deps)
	if type(deps) ~= "table"
		or not deps.AutoParry
		or not deps.GameInfo
		or not deps.Utils
	then
		return false
	end

	local ap = deps.AutoParry
	local gi = deps.GameInfo
	local u = deps.Utils

	local required = {
		{ ap, "getParryRadius" },
		{ ap, "getPingOneWay" },
		{ gi, "getSnapshot" },
		{ gi, "isSnapshotValid" },
		{ u, "now" },
		{ u, "getConfig" },
		{ u, "getRunService" },
		{ u, "recordTransition" },
		{ u, "setManualSpamActive" },
		{ u, "trackCharacter" },
		{ u, "untrackCharacter" },
		{ u, "isActive" },
		{ u, "isManualSpamActive" },
		{ u, "getLocalPlayer" },
		{ u, "apiVersion" },
	}

	for i = 1, #required do
		local object = required[i][1]
		local name = required[i][2]
		if type(object[name]) ~= "function" then
			return false, "dependência ausente: " .. tostring(name)
		end
	end

	if Utils then
		resetRuntime("setup")
	end

	AutoParry = ap
	GameInfo = gi
	Utils = u

	local player = Utils.getLocalPlayer()
	R.localUserId = player and player.UserId or nil

	R.generation = 0
	R.bound = false
	R.active = false
	R.ownsSpam = false
	R.phase = "detached"
	R.boundRoot = nil
	R.lastTarget = -1
	R.lastSpeed = 0
	R.parryRadius = 0
	R.lostMeAt = 0
	R.armed = false
	R.outsideParryAt = 0
	R.lastEvalAt = 0
	R.teleportLockUntil = 0
	R.connections = {}
	R.lastGate = "none"

	return true
end

-- api
function AutoClash.bindCharacter(character)
	if not Utils then
		return false
	end
	return bindCharacter(character)
end

function AutoClash.detachCharacter()
	resetRuntime("detach")
end

function AutoClash.teardown()
	resetRuntime("teardown")
	AutoParry = nil
	GameInfo = nil
	Utils = nil
end

-- onBallSync: única fonte que detecta transição de target.
-- aqui apenas armamos o estado; a ativação no heartbeat liga o Manual Spam.
function AutoClash.onBallSync(data)
	if type(data) ~= "table" or not Utils then
		return
	end

	local nowTime = getNow()

	-- teleport: zera tudo
	if data.Teleported == true then
		R.teleportLockUntil = nowTime + T.TELEPORT_GRACE_TIME
		clearArmed("teleport")
		clearOutsideParry()
		if R.active then
			setActive(false, "teleport_grace")
		end
		R.lastGate = "teleport"
		return
	end

	-- atualiza speed (vem do payload do sync)
	if Utils.isFiniteNumber and Utils.isFiniteNumber(data.Speed) then
		R.lastSpeed = data.Speed
	end

	-- resolver targetId do payload
	local target = data.TargetPlayerID
	local targetId
	if type(target) == "number" then
		targetId = target
	elseif type(target) == "string" then
		targetId = tonumber(target)
	end

	if not targetId then
		R.lastTarget = -1
		clearArmed("invalid_target")
		clearOutsideParry()
		R.lastGate = "invalid_target"
		return
	end

	R.lastTarget = targetId

	if not R.localUserId then
		return
	end

	local isMe = targetId == R.localUserId
	local wasMe = R._wasMeTarget == true

	-- transição "era meu → não sou": arma lostMeAt
	if wasMe and not isMe then
		R.lostMeAt = nowTime
		R.armed = false
		R.lastGate = "lost_target"
	elseif not wasMe and isMe then
		-- transição "não era meu → voltei a ser":
		-- só arma se lostMeAt > 0 e elapsed dentro da return window
		if R.lostMeAt > 0 then
			local elapsed = nowTime - R.lostMeAt
			local window = returnWindow(R.lastSpeed)
			if elapsed >= 0 and elapsed <= window then
				R.armed = true
				R.lastGate = "armed"
			else
				R.lostMeAt = 0
				R.armed = false
				R.lastGate = "return_window_missed"
			end
		end
		-- se lostMeAt == 0 (target=eu desde o primeiro sync), não arma.
		-- isso evita o bug de "ativar do nada sem o target ter saído".
	end

	R._wasMeTarget = isMe
end

function AutoClash.isActive()
	return R.active == true
end

function AutoClash.getStatus()
	return {
		schema = Utils and Utils.apiVersion() or nil,
		phase = R.phase,
		bound = R.bound == true,
		active = R.active == true,
		parryRadius = R.parryRadius,
		lastTarget = R.lastTarget,
		armed = R.armed == true,
		lastGate = R.lastGate,
	}
end

AutoClash.__contract = {
	requires = {
		AutoParry = "autoparry",
		GameInfo = "gameinfo",
		Utils = "utils",
	},
	onBallSync = true,
	bindCharacter = true,
}

return AutoClash
