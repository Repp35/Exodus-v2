-- [[ autoparry ]]

local AutoParry = {}
local Remote, GameInfo, Utils

-- tuning
local Tuning = {
        -- radius
        DEFLECT_RADIUS = 7,
        PARRY_WINDOW = 0.15,
        MIN_BALL_SPEED = 8,
        RES_PER_PARRY = 0.19,
        RES_CAP_STUDS = 32,
        HITBOX_OWN_WINDOW = 0.5,
        HITBOX_PROXIMITY = 12,
        HITBOX_GAP = 0.4,

        -- movement
        STATIONARY_MULT = 1.30,
        STATIONARY_SPEED = 1.5,
        STATIONARY_DWELL = 0.20,

        -- cooldown propagation
        CLIENT_CD_PROPAGATION = 0.30,

        -- target detection (sem previsão)
        RED_COLOR_TOLERANCE = 0.08,        -- tolerância pra considerar "vermelho"
        BRICKCOLOR_RED_NAME = "Bright red",-- nome exato que o servidor aplica
        CHAR_HIGHLIGHT_RADIUS = 20,        -- studs: raio pra considerar
                                           -- "sou o alvo de quem tá com highlight"
}

local PING_SAMPLE_INTERVAL = 1.5
local DEFAULT_PING_ONE_WAY = 0.030
local TELEPORT_LOCK = 0.20
local MAX_RES_STACK = math.floor(Tuning.RES_CAP_STUDS / Tuning.RES_PER_PARRY)
local HITBOX_PROXIMITY_SQ = Tuning.HITBOX_PROXIMITY ^ 2
local STATIONARY_SPEED_SQ = Tuning.STATIONARY_SPEED ^ 2
local CHAR_HIGHLIGHT_RADIUS_SQ = Tuning.CHAR_HIGHLIGHT_RADIUS ^ 2

local PHASE_DETACHED = 1
local PHASE_WAITING = 2
local PHASE_COOLDOWN = 3
local PHASE_ARMED = 4
local PHASE_FIRED = 5

local PHASE_STRINGS = {
        [PHASE_DETACHED] = "detached",
        [PHASE_WAITING] = "waiting",
        [PHASE_COOLDOWN] = "cooldown",
        [PHASE_ARMED] = "armed",
        [PHASE_FIRED] = "fired",
}

local phaseString = PHASE_STRINGS[PHASE_DETACHED]

-- Target detection reasons
local REASON_SERVER_TARGET = "server_target"
local REASON_BALL_BRICKCOLOR = "ball_brickcolor_red"
local REASON_BALL_HIGHLIGHT = "ball_highlight_red"
local REASON_CHAR_HIGHLIGHT_NEAREST = "char_highlight_red_nearest"

-- Names comuns do atributo que o servidor aplica no alvo
local TARGET_ATTR_NAMES = { "target", "Target", "TargetPlayer", "TargetPlayerName" }

local namespace = type(_G.Exodus) == "table" and _G.Exodus or {}
local HitboxState = type(namespace.AutoParryHitbox) == "table"
        and namespace.AutoParryHitbox
        or {
                connection = nil,
                handler = nil,
        }

namespace.AutoParryHitbox = HitboxState
_G.Exodus = namespace

-- state
local ParryState = {
        armed = false,
        armedBall = nil,
        fired = false,
        firedBall = nil,
        firedAt = 0,
}

local Resilience = {
        stack = 0,
        lastFireBall = nil,
        lastFireAt = 0,
        lastHitboxAt = 0,
}

local Runtime = {
        generation = 0,
        localUserId = -1,
        lastTarget = -1,
        teleportLockUntil = 0,
        connections = {},
        minPing = nil,
        pingTimer = 0,
        pingOneWay = DEFAULT_PING_ONE_WAY,
        resilienceBonus = 0,
        resilienceBonusAt = -1,
        parryRadius = 0,
        stationary = false,
        stationarySince = 0,
        lastRootPos = nil,
        lastRootPosAt = 0,
        lastFireAt = 0,
        cooldownObservedAt = 0,
        phase = PHASE_DETACHED,
        bound = false,

        -- target-detection runtime
        detectedAsTarget = false,
        detectionReason = nil,
        detectionTickAt = 0,
        detectionCounts = {
                [REASON_SERVER_TARGET] = 0,
                [REASON_BALL_BRICKCOLOR] = 0,
                [REASON_BALL_HIGHLIGHT] = 0,
                [REASON_CHAR_HIGHLIGHT_NEAREST] = 0,
        },

        -- one-shot por bola vermelha (estilo Phantom Lupa)
        -- "última cor vista da bola" — se mudou desde a última vez que
        -- eu registrei um parry, libera outro. Parecido com o
        -- `lastBallColor` + `hasExecutedThisDetection` do lupa.
        lastBallIdentity = nil, -- combina brickcolor/color3/highlight pra detectar mudança
        lastParriedIdentity = nil,
}

local StatsService

-- helpers
local function now()
        return Utils.now()
end

local function setPhase(phase, reason)
        if Runtime.phase == phase then
                return
        end

        local previous = Runtime.phase
        Runtime.phase = phase
        phaseString = PHASE_STRINGS[phase] or "detached"

        if Utils and type(Utils.recordTransition) == "function" then
                Utils.recordTransition(
                        "AutoParry",
                        PHASE_STRINGS[previous] or "detached",
                        phaseString,
                        reason
                )
        end
end

local function clearArmed()
        ParryState.armed = false
        ParryState.armedBall = nil
end

local function clearFired()
        ParryState.fired = false
        ParryState.firedBall = nil
        ParryState.firedAt = 0
end

local function clearCycle()
        clearArmed()
        clearFired()
        Resilience.lastFireBall = nil
        Resilience.lastFireAt = 0
end

local function disconnectConnections()
        local connections = Runtime.connections

        for i = #connections, 1, -1 do
                local connection = connections[i]
                connections[i] = nil

                if connection then
                        if Utils and type(Utils.untrackCharacter) == "function" then
                                pcall(Utils.untrackCharacter, connection)
                        end

                        pcall(function()
                                connection:Disconnect()
                        end)
                end
        end
end

local function isValidBall(ball)
        return ball ~= nil and ball.Parent ~= nil
end

local function getDistanceSquared(a, b)
        local dx = a.X - b.X
        local dy = a.Y - b.Y
        local dz = a.Z - b.Z
        return dx * dx + dy * dy + dz * dz
end

-- ============================================================
-- TARGET DETECTION — 4 sinais (sem previsão).
-- Cada um exige uma verdade vinda do servidor. O primeiro que
-- confirmar no tick trava os outros.
-- ============================================================

local function confirmTargetIfFirst(reason, time)
        if Runtime.detectedAsTarget then
                return true
        end

        Runtime.detectedAsTarget = true
        Runtime.detectionReason = reason
        Runtime.detectionTickAt = time
        Runtime.detectionCounts[reason] = (Runtime.detectionCounts[reason] or 0) + 1
        return true
end

local function resetTargetDetection(time)
        Runtime.detectedAsTarget = false
        Runtime.detectionReason = nil
        Runtime.detectionTickAt = time
end

local function isRedColor(color)
        if typeof(color) ~= "Color3" then
                return false
        end
        local r, g, b = color.R, color.G, color.B
        if r < 1 - Tuning.RED_COLOR_TOLERANCE then
                return false
        end
        if g > Tuning.RED_COLOR_TOLERANCE then
                return false
        end
        if b > Tuning.RED_COLOR_TOLERANCE then
                return false
        end
        return true
end

local function getBallBrickColorName(ball)
        -- BrickColor é uma das formas mais usadas pelo Bola Fantasma
        -- pra sinalizar alvo. O nome exato é "Bright red" (BrickColor
        -- number 21). Esse é o sinal mais forte e estável, sem
        -- previsão: se a bola mudou de cor, o servidor já decidiu
        -- quem é o alvo.
        local ok, bc = pcall(function()
                return ball.BrickColor
        end)
        if not ok or typeof(bc) ~= "BrickColor" then
                return nil
        end
        return bc.Name
end

local function getBallHighlight(ball)
        local direct = ball:FindFirstChildOfClass("Highlight")
        if direct then
                return direct
        end
        for _, desc in ipairs(ball:GetDescendants()) do
                if desc:IsA("Highlight") then
                        return desc
                end
        end
        return nil
end

local function getBallIdentity(ball)
        -- combina tudo que identifica a bola "nesse estado de alvo".
        -- se QUALQUER coisa muda (cor, highlight, alvo), a identidade muda,
        -- então o one-shot libera um novo parry (estilo lupa).
        if not isValidBall(ball) then
                return nil
        end

        local bcName = getBallBrickColorName(ball) or "?"
        local highlightColor = "none"

        local hl = getBallHighlight(ball)
        if hl and isRedColor(hl.FillColor) and hl.FillTransparency < 1 then
                highlightColor = "red"
        end

        local attrTarget = "?"
        for _, attrName in ipairs(TARGET_ATTR_NAMES) do
                local ok, val = pcall(function()
                        return ball:GetAttribute(attrName)
                end)
                if ok and type(val) == "string" and val ~= "" then
                        attrTarget = val
                        break
                end
        end

        return string.format("%s|%s|%s", bcName, highlightColor, attrTarget)
end

local function getPlayerRoot(player)
        local character = player and player.Character
        if not character then
                return nil
        end

        local root = character:FindFirstChild("HumanoidRootPart")
        if root then
                return root
        end

        return character:FindFirstChildOfClass("BasePart")
end

local function getLocalPlayerRoot()
        local lp = Utils.getLocalPlayer()
        return getPlayerRoot(lp)
end

-- ============================================================
-- SINAL A — server target (canônico, vem do servidor)
-- ============================================================
local function detectServerTarget(ball, time)
        local targetName
        for _, attrName in ipairs(TARGET_ATTR_NAMES) do
                local ok, val = pcall(function()
                        return ball:GetAttribute(attrName)
                end)
                if ok and type(val) == "string" and val ~= "" then
                        targetName = val
                        break
                end
        end

        if not targetName then
                return false
        end

        local lp = Utils.getLocalPlayer()
        if not lp then
                return false
        end

        if targetName == lp.Name then
                return confirmTargetIfFirst(REASON_SERVER_TARGET, time)
        end

        return false
end

-- ============================================================
-- SINAL B — BrickColor vermelho na bola
-- MESMO método do Phantom Lupa v6.7:
--   ball.BrickColor == BrickColor.new("Bright red")
-- É o sinal mais direto e sem previsão.
-- ============================================================
local function detectBallBrickColor(ball, time)
        local ok, isRed = pcall(function()
                return ball.BrickColor == BrickColor.new(Tuning.BRICKCOLOR_RED_NAME)
        end)
        if not ok or not isRed then
                return false
        end

        return confirmTargetIfFirst(REASON_BALL_BRICKCOLOR, time)
end

-- ============================================================
-- SINAL C — Highlight vermelho NA BOLA
-- Fallback pra forks do Bola Fantasma que usam Highlight em vez
-- de BrickColor.
-- ============================================================
local function detectBallHighlight(ball, time)
        local hl = getBallHighlight(ball)
        if not hl then
                return false
        end

        if not isRedColor(hl.FillColor) then
                return false
        end

        if hl.FillTransparency >= 1 then
                return false
        end

        return confirmTargetIfFirst(REASON_BALL_HIGHLIGHT, time)
end

-- ============================================================
-- SINAL D — Character com Highlight vermelho é EU
-- (não estou prevendo nada da bola — o servidor JÁ marcou alguém
-- de vermelho, e checo se EU sou o marcado dentro de um raio curto.)
-- ============================================================
local function detectCharHighlightNearest(ball, time)
        local lp = Utils.getLocalPlayer()
        if not lp then
                return false
        end

        local myChar = lp.Character
        if not myChar then
                return false
        end

        local hl = myChar:FindFirstChildOfClass("Highlight")
        if not hl then
                return false
        end

        if not isRedColor(hl.FillColor) then
                return false
        end

        if hl.FillTransparency >= 1 then
                return false
        end

        return confirmTargetIfFirst(REASON_CHAR_HIGHLIGHT_NEAREST, time)
end

-- Orquestrador. Itera os 4 na ordem de prioridade (lock no primeiro).
local function runTargetDetection(ball, _ballVel, time)
        resetTargetDetection(time)

        if not isValidBall(ball) then
                return false
        end

        if detectServerTarget(ball, time) then
                return true
        end
        if detectBallBrickColor(ball, time) then
                return true
        end
        if detectBallHighlight(ball, time) then
                return true
        end
        if detectCharHighlightNearest(ball, time) then
                return true
        end

        return false
end

-- ping
local function samplePing()
        if not StatsService then
                return
        end

        local okItem, pingItem = pcall(function()
                return StatsService.Network.ServerStatsItem["Data Ping"]
        end)

        if not okItem or not pingItem then
                return
        end

        local ok, ping = pcall(pingItem.GetValue, pingItem)

        if not ok or type(ping) ~= "number" then
                return
        end

        ping *= 0.001

        if not Utils.isFiniteNumber(ping) or ping <= 0 or ping >= 0.5 then
                return
        end

        if not Runtime.minPing or ping < Runtime.minPing then
                Runtime.minPing = ping
                Runtime.pingOneWay = ping * 0.5
        end
end

-- resilience
local function getResilienceBonus(time)
        if Runtime.resilienceBonusAt == time then
                return Runtime.resilienceBonus
        end

        Runtime.resilienceBonus = math.min(
                Resilience.stack * Tuning.RES_PER_PARRY,
                Tuning.RES_CAP_STUDS
        )

        Runtime.resilienceBonusAt = time
        return Runtime.resilienceBonus
end

local function resetResilience()
        Resilience.stack = 0
        Resilience.lastFireBall = nil
        Resilience.lastFireAt = 0
        Resilience.lastHitboxAt = 0

        Runtime.resilienceBonus = 0
        Runtime.resilienceBonusAt = -1
end

local function computeParryRadius(time)
        return Tuning.DEFLECT_RADIUS + getResilienceBonus(time)
end

-- targeting (server sync via GameInfo)
local function onBallSync(data)
        if typeof(data) ~= "table" then
                return
        end

        local time = now()

        if data.Teleported == true then
                Runtime.teleportLockUntil = time + TELEPORT_LOCK
                clearCycle()
                return
        end

        local targetId = tonumber(data.TargetPlayerID) or -1

        if targetId == Runtime.lastTarget then
                return
        end

        local previousTarget = Runtime.lastTarget
        Runtime.lastTarget = targetId

        if targetId == Runtime.localUserId
                and previousTarget ~= Runtime.localUserId
        then
                clearFired()
        end
end

local function requestParry()
        if type(Remote.fireParry) ~= "function" then
                if type(Utils.recordError) == "function" then
                        Utils.recordError("AutoParry", "Remote.fireParry indisponível")
                end

                setPhase(PHASE_WAITING, "remote_unavailable")
                return false
        end

        local time = now()
        local ok, result = pcall(Remote.fireParry, 1)

        if not ok or result == false then
                if type(Utils.recordError) == "function" then
                        Utils.recordError("AutoParry", "Remote.fireParry falhou")
                end

                setPhase(PHASE_WAITING, "remote_failed")
                return false
        end

        Runtime.lastFireAt = time
        Runtime.cooldownObservedAt = 0

        local ball = GameInfo.getBall()

        if isValidBall(ball) then
                Resilience.lastFireBall = ball
                Resilience.lastFireAt = time

                -- trava one-shot: marca a bola vermelha atual como já parried
                local id = getBallIdentity(ball)
                if id then
                        Runtime.lastParriedIdentity = id
                end
        else
                Resilience.lastFireBall = nil
                Resilience.lastFireAt = 0
        end

        setPhase(PHASE_FIRED, "parry_requested")
        return true
end

-- hitbox
local function handleHitbox(instance)
        if typeof(instance) ~= "Instance"
                or instance.Name ~= "HitboxGrow"
                or not Utils.isActive()
        then
                return
        end

        local time = now()

        if time - Resilience.lastFireAt > Tuning.HITBOX_OWN_WINDOW
                or time - Resilience.lastHitboxAt < Tuning.HITBOX_GAP
        then
                return
        end

        local ball = Resilience.lastFireBall

        if not isValidBall(ball) then
                return
        end

        local position, ballPosition

        local ok = pcall(function()
                position = instance.Position
                ballPosition = ball.Position
        end)

        if not ok
                or typeof(position) ~= "Vector3"
                or typeof(ballPosition) ~= "Vector3"
        then
                return
        end

        if getDistanceSquared(ballPosition, position) > HITBOX_PROXIMITY_SQ then
                return
        end

        Resilience.lastHitboxAt = time
        Resilience.stack = math.min(
                Resilience.stack + 1,
                MAX_RES_STACK
        )

        Runtime.resilienceBonusAt = -1
end

local function installHitboxHook()
        if HitboxState.connection then
                return true
        end

        local workspaceService = Utils.getWorkspace()

        if not workspaceService then
                return false
        end

        local ok, connection = pcall(function()
                return workspaceService.DescendantAdded:Connect(function(instance)
                        local handler = HitboxState.handler

                        if type(handler) == "function" then
                                handler(instance)
                        end
                end)
        end)

        if not ok or not connection then
                return false
        end

        HitboxState.connection = connection

        if type(Utils.trackGlobal) == "function" then
                Utils.trackGlobal(connection)
        end

        return true
end

-- character
local function bindCharacter(character)
        Runtime.generation += 1

        local generation = Runtime.generation

        Runtime.bound = false
        disconnectConnections()
        clearCycle()
        setPhase(PHASE_DETACHED, "rebind_start")

        if not character or not character.Parent then
                return false
        end

        local root = character:FindFirstChild("HumanoidRootPart")

        if not root then
                root = character:WaitForChild("HumanoidRootPart", 1)
        end

        if generation ~= Runtime.generation
                or not root
                or not root.Parent
        then
                return false
        end

        local humanoid = character:FindFirstChildOfClass("Humanoid")

        if humanoid then
                local diedConnection = humanoid.Died:Connect(function()
                        resetResilience()
                        clearCycle()
                end)

                Runtime.connections[#Runtime.connections + 1] = diedConnection
                Utils.trackCharacter(diedConnection)
        end

        local heartbeat = Utils.getRunService().Heartbeat
        local getConfig = Utils.getConfig
        local isSpamActive = Utils.isSpamActive

        local heartbeatConnection = heartbeat:Connect(function(dt)
                if generation ~= Runtime.generation then
                        return
                end

                if not character.Parent or not root.Parent then
                        return
                end

                local config = getConfig()

                if type(config) ~= "table" or config.AutoParry ~= true then
                        clearCycle()
                        setPhase(PHASE_WAITING, "disabled_or_locked")
                        return
                end

                local timeNow = now()

                if timeNow < Runtime.teleportLockUntil then
                        clearCycle()
                        setPhase(PHASE_WAITING, "teleport_lock")
                        return
                end

                if isSpamActive() then
                        clearCycle()
                        setPhase(PHASE_WAITING, "spam_active")
                        return
                end

                Runtime.pingTimer += math.max(dt, 0)

                if Runtime.pingTimer >= PING_SAMPLE_INTERVAL then
                        Runtime.pingTimer = 0
                        samplePing()
                end

                local snapshot = GameInfo.getSnapshot(
                        Runtime.lastTarget,
                        timeNow
                )

                if type(snapshot) ~= "table"
                        or not GameInfo.isSnapshotValid(snapshot, timeNow)
                then
                        setPhase(PHASE_WAITING, "snapshot_invalid")
                        return
                end

                local ball = snapshot.ball
                local ballVel = snapshot.velocity
                local targetedFromGameInfo = snapshot.targeted == true

                local deflectCooldown = tonumber(GameInfo.getDeflectCD()) or 0

                if not Utils.isFiniteNumber(deflectCooldown) then
                        deflectCooldown = 0
                end

                -- =========================================
                -- NOVO: target detection multi-sinal sem previsão.
                -- - Se snapshot já diz targeted (do server sync), confirma.
                -- - Senão, roda os 4: server target attr, BrickColor vermelho
                --   na bola, Highlight vermelho na bola, Highlight vermelho
                --   no MEU char. Quem confirmar primeiro trava os outros.
                -- =========================================
                if isValidBall(ball) then
                        if targetedFromGameInfo then
                                confirmTargetIfFirst(REASON_SERVER_TARGET, timeNow)
                        else
                                runTargetDetection(ball, ballVel, timeNow)
                        end
                else
                        resetTargetDetection(timeNow)
                end

                local targeted = Runtime.detectedAsTarget
                Runtime.detectedAsTarget = false -- reset pra próximo tick

                -- one-shot por bola vermelha (estilo Phantom Lupa).
                -- Se a bola virou vermelha agora (identidade mudou),
                -- libera novo parry. Se eu já parried essa identidade
                -- e ela não mudou, NÃO parried de novo.
                local currentIdentity = isValidBall(ball) and getBallIdentity(ball) or nil
                local identityChanged = currentIdentity and currentIdentity ~= Runtime.lastBallIdentity
                Runtime.lastBallIdentity = currentIdentity

                local alreadyParriedThisOne =
                        currentIdentity ~= nil
                        and currentIdentity == Runtime.lastParriedIdentity
                        and not identityChanged

                if ParryState.armed then
                        if not (
                                isValidBall(ball)
                                and ball == ParryState.armedBall
                                and targeted
                        ) then
                                clearArmed()
                                setPhase(PHASE_WAITING, "armed_context_invalid")
                        elseif deflectCooldown <= 0 then
                                if requestParry() then
                                        ParryState.fired = true
                                        ParryState.firedBall = ball
                                        ParryState.firedAt = timeNow
                                end

                                clearArmed()
                                return
                        else
                                setPhase(PHASE_ARMED, "awaiting_deflect_cooldown")
                                return
                        end
                end

                if deflectCooldown > 0 then
                        if Runtime.cooldownObservedAt <= 0 then
                                Runtime.cooldownObservedAt = timeNow
                        elseif timeNow - Runtime.cooldownObservedAt >= Tuning.CLIENT_CD_PROPAGATION then
                                setPhase(PHASE_COOLDOWN, "cooldown_observed")
                        else
                                setPhase(PHASE_COOLDOWN, "cooldown_propagation")
                        end
                else
                        Runtime.cooldownObservedAt = 0
                end

                -- aqui é onde o one-shot entra: se já parried essa
                -- identidade e ela não mudou, ABORTA. Só age se for uma
                -- nova "ronda" da bola vermelha.
                if not (isValidBall(ball) and targeted) then
                        setPhase(PHASE_WAITING, "ball_or_target_invalid")
                        return
                end

                if alreadyParriedThisOne then
                        setPhase(PHASE_WAITING, "already_parried_this_id")
                        return
                end

                local speed = tonumber(snapshot.speed)

                if not speed
                        or not Utils.isFiniteNumber(speed)
                        or speed < Tuning.MIN_BALL_SPEED
                then
                        setPhase(PHASE_WAITING, "ball_too_slow")
                        return
                end

                local position = snapshot.position

                if typeof(position) ~= "Vector3" then
                        setPhase(PHASE_WAITING, "position_unavailable")
                        return
                end

                local rootPos = root.Position
                local parryRadius = computeParryRadius(timeNow)
                local parryWindow = Tuning.PARRY_WINDOW

                local previousPos = Runtime.lastRootPos
                local previousTime = Runtime.lastRootPosAt

                Runtime.lastRootPos = rootPos
                Runtime.lastRootPosAt = timeNow

                if previousPos and timeNow > previousTime then
                        local invDt = 1 / (timeNow - previousTime)
                        local vx = (rootPos.X - previousPos.X) * invDt
                        local vz = (rootPos.Z - previousPos.Z) * invDt
                        local horizontalSpeedSq = vx * vx + vz * vz

                        if horizontalSpeedSq < STATIONARY_SPEED_SQ then
                                if Runtime.stationarySince == 0 then
                                        Runtime.stationarySince = timeNow
                                end
                        else
                                Runtime.stationarySince = 0
                        end
                elseif Runtime.stationarySince == 0 then
                        Runtime.stationarySince = timeNow
                end

                Runtime.stationary =
                        Runtime.stationarySince > 0
                        and timeNow - Runtime.stationarySince >= Tuning.STATIONARY_DWELL

                if Runtime.stationary then
                        parryWindow *= Tuning.STATIONARY_MULT
                end

                Runtime.parryRadius = parryRadius + speed * parryWindow

                local distanceSquared = getDistanceSquared(rootPos, position)
                local distance = math.sqrt(distanceSquared)

                local tti = (distance - parryRadius) / speed

                if tti > parryWindow then
                        setPhase(PHASE_WAITING, "outside_ping_window")
                        return
                end

                if deflectCooldown > 0 then
                        if not ParryState.armed then
                                ParryState.armed = true
                                ParryState.armedBall = ball
                        end

                        setPhase(PHASE_ARMED, "awaiting_deflect_cooldown")
                        return
                end

                if ParryState.fired then
                        if ParryState.firedBall == ball then
                                setPhase(PHASE_FIRED, "ball_already_fired")
                                return
                        end

                        if not isValidBall(ParryState.firedBall)
                                or ParryState.firedBall ~= ball
                        then
                                clearFired()
                        end
                end

                if requestParry() then
                        ParryState.fired = true
                        ParryState.firedBall = ball
                        ParryState.firedAt = timeNow
                end
        end)

        Runtime.connections[#Runtime.connections + 1] = heartbeatConnection
        Utils.trackCharacter(heartbeatConnection)

        local ancestryConnection = character.AncestryChanged:Connect(function(_, parent)
                if not parent and generation == Runtime.generation then
                        Runtime.generation += 1
                        Runtime.bound = false
                        disconnectConnections()
                        clearCycle()
                        setPhase(PHASE_DETACHED, "character_removed")
                end
        end)

        Runtime.connections[#Runtime.connections + 1] = ancestryConnection
        Utils.trackCharacter(ancestryConnection)

        Runtime.bound = true
        setPhase(PHASE_WAITING, "character_bound")

        return true
end

-- lifecycle
local function resetState()
        clearCycle()

        Runtime.teleportLockUntil = 0
        Runtime.lastTarget = -1
        Runtime.pingTimer = 0
        Runtime.minPing = nil
        Runtime.pingOneWay = DEFAULT_PING_ONE_WAY
        Runtime.parryRadius = 0
        Runtime.stationary = false
        Runtime.stationarySince = 0
        Runtime.lastRootPos = nil
        Runtime.lastRootPosAt = 0
        Runtime.lastFireAt = 0
        Runtime.cooldownObservedAt = 0
        Runtime.bound = false

        Runtime.detectedAsTarget = false
        Runtime.detectionReason = nil
        Runtime.detectionTickAt = 0
        Runtime.lastBallIdentity = nil
        Runtime.lastParriedIdentity = nil

        setPhase(PHASE_DETACHED, "reset")
end

-- setup
function AutoParry.setup(deps)
        if type(deps) ~= "table" then
                return false, "dependências inválidas"
        end

        local remote = deps.Remote
        local gameInfo = deps.GameInfo
        local utils = deps.Utils

        if type(remote) ~= "table"
                or type(remote.fireParry) ~= "function"
        then
                return false, "dependência ausente: Remote.fireParry"
        end

        if type(gameInfo) ~= "table"
                or type(gameInfo.getDeflectCD) ~= "function"
                or type(gameInfo.getBall) ~= "function"
                or type(gameInfo.getSnapshot) ~= "function"
                or type(gameInfo.isSnapshotValid) ~= "function"
        then
                return false, "dependência ausente: GameInfo"
        end

        if type(utils) ~= "table"
                or type(utils.now) ~= "function"
                or type(utils.apiVersion) ~= "function"
                or type(utils.isFiniteNumber) ~= "function"
                or type(utils.getConfig) ~= "function"
                or type(utils.getLocalPlayer) ~= "function"
                or type(utils.getWorkspace) ~= "function"
                or type(utils.getRunService) ~= "function"
                or type(utils.trackCharacter) ~= "function"
                or type(utils.untrackCharacter) ~= "function"
                or type(utils.trackGlobal) ~= "function"
                or type(utils.isActive) ~= "function"
                or type(utils.isSpamActive) ~= "function"
        then
                return false, "dependência ausente: Utils"
        end

        Remote = remote
        GameInfo = gameInfo
        Utils = utils

        StatsService = game:GetService("Stats")

        local localPlayer = Utils.getLocalPlayer()
        Runtime.localUserId = localPlayer and tonumber(localPlayer.UserId) or -1

        HitboxState.handler = handleHitbox

        resetResilience()
        resetState()

        if not installHitboxHook()
                and type(Utils.warn) == "function"
        then
                Utils.warn("hook de hitbox indisponível")
        end

        return true
end

function AutoParry.fire()
        if not Remote or not GameInfo or not Utils then
                return false
        end

        return requestParry()
end

function AutoParry.bindCharacter(character)
        if not Remote or not GameInfo or not Utils then
                return false
        end

        return bindCharacter(character)
end

function AutoParry.resetState()
        if Utils then
                resetState()
        end
end

function AutoParry.detachCharacter()
        Runtime.generation += 1
        Runtime.bound = false

        disconnectConnections()
        resetState()
end

function AutoParry.onBallSync(data)
        if Utils then
                onBallSync(data)
        end
end

function AutoParry.getParryRadius()
        return Runtime.parryRadius
end

function AutoParry.getPingOneWay()
        return Runtime.pingOneWay
end

function AutoParry.getDetectedReason()
        return Runtime.detectionReason
end

function AutoParry.getDetectionCounts()
        local copy = {}
        for reason, count in pairs(Runtime.detectionCounts) do
                copy[reason] = count
        end
        return copy
end

function AutoParry.getStatus()
        return {
                schema = Utils and Utils.apiVersion() or nil,
                phase = phaseString,
                bound = Runtime.bound == true,
                armed = ParryState.armed == true,
                fired = ParryState.fired == true,
                resilienceStack = Resilience.stack,
                parryRadius = Runtime.parryRadius,
                stationary = Runtime.stationary == true,
                detectedAsTarget = Runtime.detectedAsTarget,
                detectionReason = Runtime.detectionReason,
                detectionCounts = AutoParry.getDetectionCounts(),
                lastBallIdentity = Runtime.lastBallIdentity,
                lastParriedIdentity = Runtime.lastParriedIdentity,
        }
end

AutoParry.__contract = {
        requires = {
                Remote = "remote",
                GameInfo = "gameinfo",
                Utils = "utils",
        },
        onBallSync = true,
        bindCharacter = true,
}

return AutoParry
