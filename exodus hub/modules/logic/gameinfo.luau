-- [[ gameinfo ]]

local GameInfo = {}
export type BallSnapshot = {
    schema: number,
    generatedAt: number,
    valid: boolean,
    ball: BasePart,
    ballValid: boolean,
    position: Vector3,
    velocity: Vector3,
    speed: number,
    syncSpeed: number?,
    realPosition: Vector3?,
    targetId: number,
    targeted: boolean,
    teleported: boolean,
    grace: boolean,
    oldGrace: boolean,
    syncAt: number,
    syncSequence: number?,
}

export type BallSync = {
    Sequence: number?,
    ServerTime: number?,
    TeleportSequence: number?,
    Teleported: boolean?,
    Grace: boolean?,
    OldGrace: boolean?,
    TargetPlayerID: number?,
    HighlightTargetPlayerID: number?,
    PossessorId: number?,
    RealPosition: Vector3?,
    Speed: number?,
}

local Utils, Players, Workspace
local cachedBall, ballReplicatorModule, gameBallModule
local clientAbilitiesModule, clientAbilities
local ballWatcherReady, ballSearchComplete = false, false
local nextBallSearch, nextSpeedRead = 0, 0
local speedLimitMin, speedLimitMax = 16, 600
local lastSyncData, lastPacket, lastPacketAt
local sampledBall, sampledPosition, sampledAt, sampledVelocity, movedAt
local moduleErrors = {}
local deflectConnection, deflectParriedConnection
local nextDeflectSignalCheck, nextHeldCooldownCheck = 0, 0
local deflectMissingAt, nextDeflectWarning = nil, 0

local deflectState = {
    known = false,
    active = false,
    rawActive = false,
    readyRevision = 0,
    retryRevision = 0,
    pressRevision = 0,
    lastEventAt = -math.huge,
    attempt = nil,
}

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function reportModuleError(name, message)
    local time = os.clock()
    if moduleErrors[name] and time - moduleErrors[name] < 2 then return end
    moduleErrors[name] = time
    local detail = name .. ": " .. tostring(message)
    if Utils and type(Utils.recordError) == "function" then
        Utils.recordError("GameInfo", detail)
    else
        warn("[GameInfo] " .. detail)
    end
end

local function now()
    return Utils.now()
end

local function findGameBall()
    local ball = Workspace:FindFirstChild("GameBall") or Workspace:FindFirstChild("GameBall", true)
    if typeof(ball) == "Instance" and ball:IsA("BasePart") then return ball end
    return nil
end

local function getBall()
    if cachedBall and cachedBall.Parent then return cachedBall end
    if ballWatcherReady and ballSearchComplete and os.clock() < nextBallSearch then return nil end

    cachedBall = findGameBall()
    ballSearchComplete = true
    nextBallSearch = os.clock() + 0.5
    return cachedBall
end

local function getBallReplicator()
    if ballReplicatorModule then return ballReplicatorModule end

    local storage = Utils.getReplicatedStorage()
    local ts = storage and storage:FindFirstChild("TS")
    local folder = ts and ts:FindFirstChild("BallReplicator")
    if not folder then return nil end

    local script = folder:IsA("ModuleScript") and folder or folder:FindFirstChild("BallReplicator")
    if not script or not script:IsA("ModuleScript") then return nil end

    local ok, result = pcall(require, script)
    if not ok or type(result) ~= "table" then
        reportModuleError("BallReplicator", ok and "módulo não retornou tabela" or result)
        return nil
    end

    local replicator = type(result.BallReplicator) == "table" and result.BallReplicator
        or (result.syncData ~= nil and result or nil)
    ballReplicatorModule = replicator
    return replicator
end

local function getDecodedSyncData()
    local provider = getBallReplicator()
    if lastPacket and os.clock() - lastPacketAt > 0.5 then lastPacket = nil end

    if lastPacket then
        local sequence = provider and provider.hasState == true and provider.lastSeq
        local ahead = type(sequence) ~= "number"
            or ((lastPacket.Sequence - sequence) % 65536 < 32768 and lastPacket.Sequence ~= sequence)
        if ahead then return lastPacket end
        lastPacket = nil
    end

    local data = provider and provider.hasState == true and provider.syncData or lastSyncData
    if type(data) ~= "table" then data = provider and provider.syncData or nil end
    return type(data) == "table" and data or nil
end

local function normalizeTarget(value)
    if typeof(value) == "Instance" and value:IsA("Player") then
        return tonumber(value.UserId)
    end
    if type(value) == "string" then value = tonumber(value) end
    if type(value) == "number" and value > 0 then return value end
    return nil
end

local function resolveTargetId(data)
    if type(data) == "table" then
        local target = normalizeTarget(data.TargetPlayerID) or normalizeTarget(data.HighlightTargetPlayerID)
        if target then return target end
        if data.Targeted == true and Players and Players.LocalPlayer then
            return Players.LocalPlayer.UserId
        end
    end

    local ok, value = pcall(function() return Workspace:GetAttribute("GameBallTarget") end)
    if ok then
        local target = normalizeTarget(value)
        if target then return target end
    end
    return -1
end

local function locateDeflectAbility()
    if clientAbilitiesModule and clientAbilitiesModule.Parent and clientAbilities then
        local ability = clientAbilities.Abilities[1]
        return type(ability) == "table" and type(ability.Deflect) == "function" and ability or nil
    end

    local storage = Utils.getReplicatedStorage()
    local ts = storage and storage:FindFirstChild("TS")
    local script = ts and ts:FindFirstChild("ClientAbilities")
    if not script or not script:IsA("ModuleScript") then return nil end

    if script ~= clientAbilitiesModule then
        local ok, loaded = pcall(require, script)
        if not ok or type(loaded) ~= "table" or type(loaded.Abilities) ~= "table" then
            reportModuleError("ClientAbilities", ok and "Abilities ausente ou inválido" or loaded)
            clientAbilitiesModule, clientAbilities = nil, nil
            return nil
        end
        clientAbilitiesModule, clientAbilities = script, loaded
    end

    local ability = clientAbilities.Abilities[1]
    return type(ability) == "table" and type(ability.Deflect) == "function" and ability or nil
end

local function getSnapshot(_, time, _frameTime): BallSnapshot?
    time = type(time) == "number" and time or now()
    local ball = getBall()
    if not ball then return nil end

    local position = ball.Position
    local velocity = ball.AssemblyLinearVelocity
    local sync = getDecodedSyncData()

    if ball ~= sampledBall or (sync and sync.Teleported == true) then
        sampledBall, sampledPosition, sampledAt = ball, position, time
        sampledVelocity, movedAt = Vector3.zero, nil
    elseif sampledPosition and sampledAt and time - sampledAt >= 1 / 240 then
        local elapsed = time - sampledAt
        local displacement = position - sampledPosition
        if displacement.Magnitude > 0.001 then
            local measured = displacement / elapsed
            local expected = sync and tonumber(sync.Speed)
            if elapsed <= 0.25
                and (not expected or expected <= 0 or measured.Magnitude <= expected * 2.5 + 30) then
                sampledVelocity, movedAt = measured, time
            else
                sampledVelocity, movedAt = Vector3.zero, nil
            end
        elseif movedAt and time - movedAt > 0.10 then
            sampledVelocity = Vector3.zero
        end
        sampledPosition, sampledAt = position, time
    end

    if typeof(velocity) ~= "Vector3" or velocity.Magnitude < 0.1 then
        velocity = sampledVelocity or Vector3.zero
    end

    local speed = typeof(velocity) == "Vector3" and velocity.Magnitude or 0
    local targetId = resolveTargetId(sync)
    local player = Players and Players.LocalPlayer
    local provider = getBallReplicator()

    return {
        schema = 2,
        generatedAt = time,
        valid = true,
        ball = ball,
        ballValid = true,
        position = position,
        velocity = velocity,
        speed = speed,
        syncSpeed = sync and sync.Speed or nil,
        realPosition = sync and sync.RealPosition or nil,
        targetId = targetId,
        targeted = player ~= nil and targetId == player.UserId,
        teleported = sync ~= nil and sync.Teleported == true,
        grace = sync ~= nil and sync.Grace == true,
        oldGrace = sync ~= nil and sync.OldGrace == true,
        syncAt = time,
        syncSequence = lastPacket and sync == lastPacket and lastPacket.Sequence
            or (provider and provider.hasState == true and provider.lastSeq or nil),
    }
end

local function disconnectEvent(connection)
    if not connection then return nil end
    if Utils and type(Utils.untrackGlobal) == "function" then Utils.untrackGlobal(connection) end
    connection:Disconnect()
    return nil
end

function GameInfo.setup(deps)
    if type(deps) ~= "table" or type(deps.Utils) ~= "table" then
        return false, "dependência ausente: Utils"
    end
    for _, method in ipairs({"now", "apiVersion", "getPlayers", "getReplicatedStorage", "getWorkspace"}) do
        if type(deps.Utils[method]) ~= "function" then return false, "dependência ausente: Utils" end
    end

    deflectConnection = disconnectEvent(deflectConnection)
    deflectParriedConnection = disconnectEvent(deflectParriedConnection)
    Utils = deps.Utils
    Players, Workspace = Utils.getPlayers(), Utils.getWorkspace()
    if not Players then return false, "dependência ausente: Players" end
    if not Workspace then return false, "dependência ausente: Workspace" end

    cachedBall, ballReplicatorModule, gameBallModule = nil, nil, nil
    clientAbilitiesModule, clientAbilities = nil, nil
    ballWatcherReady, ballSearchComplete = false, false
    nextBallSearch, nextSpeedRead = 0, 0
    speedLimitMin, speedLimitMax = 16, 600
    lastSyncData, lastPacket, lastPacketAt = nil, nil, nil
    sampledBall, sampledPosition, sampledAt, sampledVelocity, movedAt = nil, nil, nil, nil, nil
    deflectState = {
        known = false, active = false, rawActive = false,
        readyRevision = 0, retryRevision = 0, pressRevision = 0,
        lastEventAt = -math.huge, attempt = nil,
    }
    nextDeflectSignalCheck, nextHeldCooldownCheck = 0, 0
    deflectMissingAt, nextDeflectWarning = nil, 0
    GameInfo.getDeflectCooldownState()
    return true
end

function GameInfo.getBall() return getBall() end
function GameInfo.getBallPosition(ball) return ball.Position end
function GameInfo.getBallVelocity(ball) return ball.AssemblyLinearVelocity end
function GameInfo.getRootPosition(root) return root.Position end

function GameInfo.getLocalPing()
    local player = Players and Players.LocalPlayer
    return player and player:GetNetworkPing() or nil
end

function GameInfo.getDeflectRange()
    local player = Players and Players.LocalPlayer
    return player and player:GetAttribute("DeflectRange") or nil
end

function GameInfo.getDeflectAbility()
    return locateDeflectAbility()
end

function GameInfo.getDeflectUICooldown()
    local ability = locateDeflectAbility()
    if not ability or type(ability.Interface) ~= "table" then return nil end

    local duration = ability.LastCooldown
    if not finite(duration) or duration <= 0 then return nil end
    local bar = ability.Interface.UIAbilityCooldown
    if not bar then return nil end

    local ok, scale = pcall(function() return bar.Size.Y.Scale end)
    if not ok or not finite(scale) then return nil end
    return math.clamp(scale, 0, 1) * duration
end

local function generatedRemotes()
    local storage = Utils and Utils.getReplicatedStorage()
    local ts = storage and storage:FindFirstChild("TS")
    return ts and ts:FindFirstChild("GeneratedNetworkRemotes") or nil
end

local function generatedRemote(id)
    local remotes = generatedRemotes()
    local remote = remotes and remotes:FindFirstChild("RE_" .. tostring(id))
    return remote and remote:IsA("RemoteEvent") and remote or nil
end

function GameInfo.getDeflectServerEvents()
    local cooldown = generatedRemote(5.520474058077904e76)
    if not cooldown then return nil end
    local parried = generatedRemote(9.611859444202098e76)
    return {cooldown = cooldown.OnClientEvent, parried = parried and parried.OnClientEvent or nil}
end

function GameInfo.decodeDeflectServerEvent(abilityId, eventId, value)
    if abilityId ~= 1 then return nil end
    if eventId == 5.93848805167512e76 and finite(value) then
        if value > 0 then return "started", value end
        return "reset", 0
    end
    if eventId == 6.60750295352893e76 then return "stopped", 0 end
    return nil
end

function GameInfo.getHeldDeflectServerCooldown()
    local ability = locateDeflectAbility()
    if not ability then return nil end
    local duration, receivedAt = ability.HeldServerCooldown, ability.HeldServerCooldownAt
    if finite(duration) and duration > 0 and finite(receivedAt) then
        return duration, receivedAt
    end
    return nil
end

local function currentTargetMatches()
    local player = Players and Players.LocalPlayer
    if not player then return false end
    local sync = getDecodedSyncData()
    if type(sync) == "table" and sync.Teleported == true then return false end
    return resolveTargetId(sync) == player.UserId
end

function GameInfo.noteDeflectPress()
    local pressAt = os.clock()
    if not currentTargetMatches() or deflectState.attempt or deflectState.fierceUsedForTarget then return end

    local sync = getDecodedSyncData()
    local speed = type(sync) == "table" and tonumber(sync.Speed) or nil
    local window = GameInfo.getDeflectWindow(speed)
    if not finite(window) or window <= 0 then return end

    deflectState.pressRevision += 1
    deflectState.attempt = {
        id = deflectState.pressRevision,
        at = pressAt,
        deadline = pressAt + window,
        window = window,
        targetId = Players.LocalPlayer.UserId,
    }
    deflectState.known = true
    deflectState.active = false
end

function GameInfo.noteFierceDeflectActivation()
    deflectState.attempt = nil
    deflectState.active = false
    deflectState.fierceUsedForTarget = currentTargetMatches()
end

function GameInfo.getDeflectCooldownState()
    local time = os.clock()

    if deflectConnection and deflectConnection.Connected == false then
        deflectConnection = disconnectEvent(deflectConnection)
        deflectState.rawActive, deflectState.endsAt = false, nil
        nextDeflectSignalCheck = 0
    end
    if deflectParriedConnection and deflectParriedConnection.Connected == false then
        deflectParriedConnection = disconnectEvent(deflectParriedConnection)
    end

    if not deflectConnection and time >= nextDeflectSignalCheck then
        nextDeflectSignalCheck = time + 0.5
        local signals = GameInfo.getDeflectServerEvents()
        if signals and signals.cooldown then
            deflectConnection = signals.cooldown:Connect(function(abilityId, eventId, value)
                local kind, duration = GameInfo.decodeDeflectServerEvent(abilityId, eventId, value)
                if not kind then return end
                deflectState.known = true
                deflectState.lastEventAt = os.clock()

                if kind == "started" then
                    deflectState.rawActive = true
                    deflectState.endsAt = deflectState.lastEventAt + duration
                else
                    deflectState.rawActive, deflectState.endsAt = false, nil
                end
            end)
            if Utils and type(Utils.trackGlobal) == "function" then Utils.trackGlobal(deflectConnection) end
            deflectMissingAt = nil
        else
            if not deflectMissingAt then deflectMissingAt = time end
            if time - deflectMissingAt >= 3 and time >= nextDeflectWarning then
                nextDeflectWarning = time + 10
                reportModuleError("DeflectCooldown", "evento de cooldown do servidor indisponível")
            end
        end
    end

    if deflectConnection and not deflectParriedConnection then
        local signals = GameInfo.getDeflectServerEvents()
        if signals and signals.parried then
            deflectParriedConnection = signals.parried:Connect(function()
                deflectState.attempt, deflectState.endsAt = nil, nil
                deflectState.active, deflectState.rawActive = false, false
                deflectState.lastEventAt = os.clock()
            end)
            if Utils and type(Utils.trackGlobal) == "function" then
                Utils.trackGlobal(deflectParriedConnection)
            end
        end
    end

    if not deflectState.rawActive and time >= nextHeldCooldownCheck then
        nextHeldCooldownCheck = time + 0.05
        local duration, receivedAt = GameInfo.getHeldDeflectServerCooldown()
        if duration and receivedAt and receivedAt <= time and time < receivedAt + duration
            and receivedAt > deflectState.lastEventAt + 0.01 then
            deflectState.known = true
            deflectState.rawActive = true
            deflectState.lastEventAt = receivedAt
            deflectState.endsAt = receivedAt + duration
        end
    end

    if deflectState.rawActive and finite(deflectState.endsAt) and time >= deflectState.endsAt then
        deflectState.rawActive, deflectState.endsAt = false, nil
    end

    local ability = locateDeflectAbility()
    local localCooldown = ability and finite(ability.Cooldown) and ability.Cooldown > 0
    local cooldownRunning = deflectState.rawActive or localCooldown == true
    if localCooldown then deflectState.known = true end

    local remaining = localCooldown and ability.Cooldown or 0
    if deflectState.rawActive and finite(deflectState.endsAt) then
        remaining = math.max(remaining, deflectState.endsAt - time)
    end
    deflectState.remaining = math.max(0, remaining)

    if deflectState.fierceUsedForTarget and not currentTargetMatches() then
        deflectState.fierceUsedForTarget = false
    end

    local attempt = deflectState.attempt
    deflectState.active = false
    if attempt then
        if not currentTargetMatches() then
            deflectState.attempt = nil
        else
            local expired = time >= attempt.deadline
            attempt.expired, attempt.failed = expired, expired
            if expired and cooldownRunning then
                deflectState.active = true
            elseif expired then
                deflectState.retryRevision += 1
                deflectState.readyRevision += 1
                deflectState.attempt = nil
            end
        end
    end

    deflectState.blocking = cooldownRunning or deflectState.attempt ~= nil
        or deflectState.fierceUsedForTarget == true
    return deflectState
end

function GameInfo.getFierceDeflectAbility()
    locateDeflectAbility()
    local ability = clientAbilities and clientAbilities.Abilities[19]
    if type(ability) == "table" and type(ability.ActivateAndBlock) == "function" then
        return ability
    end
    return nil
end

function GameInfo.activateFierceDeflect(ability)
    if not ability or ability ~= GameInfo.getFierceDeflectAbility() then
        return false, "Deflexo Feroz não equipado"
    end
    if type(ability.IsAvailable) ~= "function" or not ability:IsAvailable(false) then
        return false, "Deflexo Feroz indisponível"
    end
    if type(ability.IsOwnerAlive) ~= "function" or not ability:IsOwnerAlive() then
        return false, "jogador indisponível"
    end
    ability:ActivateAndBlock()
    return true
end

function GameInfo.getDashAbility()
    locateDeflectAbility()
    local ability = clientAbilities and clientAbilities.Abilities[2]
    return type(ability) == "table" and type(ability.Dash) == "function" and ability or nil
end

function GameInfo.getDarkSealAbility()
    locateDeflectAbility()
    local ability = clientAbilities and clientAbilities.Abilities[20]
    return type(ability) == "table" and type(ability.SendEvent) == "function" and ability or nil
end

function GameInfo.getSnapshot(lastTarget, time, frameTime): BallSnapshot?
    return getSnapshot(lastTarget, time, frameTime)
end

function GameInfo.getSnapshotAt(time: number?): BallSnapshot?
    return getSnapshot(nil, time)
end

function GameInfo.getSyncData() return getDecodedSyncData() end

function GameInfo.getSyncSequence()
    local sync = getDecodedSyncData()
    if lastPacket and sync == lastPacket then return lastPacket.Sequence end
    local provider = getBallReplicator()
    return provider and provider.hasState == true and provider.lastSeq or nil
end

function GameInfo.applyPacket(packet)
    if type(packet) ~= "table" then return false end
    local sequence = packet.Sequence
    if not finite(sequence) or sequence < 0 or sequence >= 65536 or sequence % 1 ~= 0 then
        return false
    end

    local current = GameInfo.getSyncSequence()
    if type(current) == "number" then
        local delta = (sequence - current) % 65536
        if delta == 0 or delta >= 32768 then return false end
    end

    lastPacket, lastPacketAt = packet, os.clock()
    return true
end

function GameInfo.decodeBallPacket(packet): BallSync?
    local provider = getBallReplicator()
    if not provider or type(provider.Decode) ~= "function" then return nil end
    local decoded = provider:Decode(packet)
    if type(decoded) ~= "table" then return nil end

    return {
        Sequence = decoded.seq,
        ServerTime = decoded.serverTime,
        TeleportSequence = decoded.seq,
        Teleported = decoded.teleported,
        Grace = decoded.grace,
        OldGrace = decoded.oldGrace,
        TargetPlayerID = decoded.targetId,
        HighlightTargetPlayerID = decoded.highlightId,
        PossessorId = decoded.possessed and decoded.possessorId or 0,
        RealPosition = decoded.position,
        Speed = decoded.speed,
    }
end

function GameInfo.getTargetId()
    return resolveTargetId(getDecodedSyncData())
end

function GameInfo.getBallSpeedLimits()
    local time = os.clock()
    if time < nextSpeedRead then return speedLimitMin, speedLimitMax end
    nextSpeedRead = time + 0.5

    if not gameBallModule then
        local storage = Utils and Utils.getReplicatedStorage()
        local ts = storage and storage:FindFirstChild("TS")
        local gameplay = ts and ts:FindFirstChild("Gameplay")
        local script = gameplay and gameplay:FindFirstChild("GameBall")
        if not script or not script:IsA("ModuleScript") then
            reportModuleError("GameBall", "módulo de velocidade indisponível; usando últimos limites conhecidos")
            return speedLimitMin, speedLimitMax
        end

        local ok, result = pcall(require, script)
        if not ok then
            reportModuleError("GameBall", result)
            return speedLimitMin, speedLimitMax
        end
        gameBallModule = type(result) == "table" and result.GameBall or nil
    end

    local ball = gameBallModule
    if type(ball) ~= "table" or type(ball.GetBaseSpeed) ~= "function"
        or type(ball.GetMaxSpeed) ~= "function" then
        reportModuleError("GameBall", "API de velocidade indisponível")
        gameBallModule = nil
        return speedLimitMin, speedLimitMax
    end

    local ok, minimum, maximum = pcall(function()
        return ball:GetBaseSpeed(), ball:GetMaxSpeed()
    end)
    if not ok or not finite(minimum) or not finite(maximum)
        or minimum <= 0 or maximum <= minimum then
        reportModuleError("GameBall", ok and "limites de velocidade inválidos" or minimum)
        return speedLimitMin, speedLimitMax
    end

    speedLimitMin, speedLimitMax = minimum, maximum
    return minimum, maximum
end

function GameInfo.getDeflectWindow(speed)
    local minimum, maximum = GameInfo.getBallSpeedLimits()
    local ball = gameBallModule
    local sync = getDecodedSyncData()

    if not finite(speed) and type(sync) == "table" and finite(sync.Speed) then speed = sync.Speed end
    if not finite(speed) or maximum <= minimum then return nil end

    local fraction = math.clamp((speed - minimum) / (maximum - minimum), 0, 1)
    local window = 0.85 - 0.65 * fraction

    if ball and type(ball.GetClashMinWindow) == "function" then
        local ok, minimumWindow = pcall(ball.GetClashMinWindow, ball, speed)
        if ok and type(minimumWindow) == "number" then
            window = math.max(window, minimumWindow)
        end
    end

    local range = GameInfo.getDeflectRange()
    if type(range) == "number" then
        window += math.clamp((range - 8.5) / 7.5, 0, 1) * 0.12
    end

    local player = Players and Players.LocalPlayer
    if ball and player and type(ball.IsInClash) == "function" then
        local ok, clash = pcall(ball.IsInClash, ball, player)
        if ok and clash and type(ball.GetClashWindowScale) == "function" then
            local scaleOk, scale = pcall(ball.GetClashWindowScale, ball)
            if scaleOk and type(scale) == "number" and scale > 0 then window *= scale end
        end
    end
    return window
end

function GameInfo.getHaunterRemote()
    return generatedRemote(9.150098456648103e76)
end

function GameInfo.getManifestRemote()
    return generatedRemote(9.318024238496386e76)
end

function GameInfo.getClashContext()
    local player = Players and Players.LocalPlayer
    if not player or not Workspace then return nil end

    local lastAt = Workspace:GetAttribute("LastParryAt")
    local by = Workspace:GetAttribute("LastParryBy")
    local target = Workspace:GetAttribute("LastParryTarget")
    if type(lastAt) ~= "number" or type(by) ~= "number" or type(target) ~= "number" then return nil end

    local partnerId = by == player.UserId and target or (target == player.UserId and by or nil)
    if not partnerId or partnerId <= 0 or partnerId == player.UserId then return nil end

    local age = Workspace:GetServerTimeNow() - lastAt
    local current = Workspace:GetAttribute("GameBallTarget")
    if age < 0 or (age > 1 and (age > 2.5 or current ~= target)) then return nil end

    local partner = Players:GetPlayerByUserId(partnerId)
    local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local other = partner and partner.Character and partner.Character:FindFirstChild("HumanoidRootPart")
    if not root or not other or (root.Position - other.Position).Magnitude > 35 then return nil end
    return {partnerId = partnerId, lastParryAt = lastAt, age = age}
end

function GameInfo.isSnapshotValid(snapshot)
    return type(snapshot) == "table"
        and typeof(snapshot.ball) == "Instance"
        and snapshot.ball:IsA("BasePart")
        and typeof(snapshot.position) == "Vector3"
        and typeof(snapshot.velocity) == "Vector3"
        and finite(snapshot.speed) and snapshot.speed >= 0
        and type(snapshot.targetId) == "number"
        and type(snapshot.targeted) == "boolean"
end

function GameInfo.applySync(data)
    if type(data) == "table" and type(data.syncData) == "table" then data = data.syncData end
    if type(data) ~= "table" then
        local provider = getBallReplicator()
        data = provider and provider.syncData or nil
    end
    if type(data) ~= "table" then return nil end
    lastSyncData = data
    return data
end

function GameInfo.installBallWatcher(trackConnection)
    if type(trackConnection) ~= "function" then return false, "trackConnection invalido" end

    trackConnection((Workspace.DescendantAdded or Workspace.ChildAdded):Connect(function(child)
        if child.Name == "GameBall" and child:IsA("BasePart") then cachedBall = child end
    end))
    trackConnection((Workspace.DescendantRemoving or Workspace.ChildRemoved):Connect(function(child)
        if cachedBall == child then
            cachedBall = nil
            ballSearchComplete = false
        end
    end))

    cachedBall = findGameBall()
    ballSearchComplete, ballWatcherReady = true, true
    nextBallSearch = os.clock() + 0.5
    return true
end

function GameInfo.getDeflectCD()
    local ability = locateDeflectAbility()
    local cooldown = ability and ability.Cooldown
    return finite(cooldown) and cooldown or nil
end

function GameInfo.getStatus()
    local snapshot = getSnapshot(nil, now())
    return {
        schema = Utils.apiVersion(),
        generatedAt = now(),
        available = type(snapshot) == "table",
        targetId = snapshot and snapshot.targetId or -1,
        targeted = snapshot and snapshot.targeted == true or false,
        speed = snapshot and snapshot.speed or 0,
    }
end

GameInfo.__contract = {
    requires = {Utils = "utils"},
    requiresMethods = {
        Utils = {"now", "apiVersion", "getPlayers", "getReplicatedStorage", "getWorkspace"},
    },
    provides = {
        "setup", "getBall", "getBallPosition", "getBallVelocity", "getRootPosition",
        "getLocalPing", "getDeflectRange", "getDeflectWindow", "getDeflectAbility",
        "getDeflectUICooldown", "getDeflectServerEvents", "decodeDeflectServerEvent",
        "getHeldDeflectServerCooldown", "getDeflectCooldownState", "noteDeflectPress",
        "noteFierceDeflectActivation", "getFierceDeflectAbility", "activateFierceDeflect",
        "getDashAbility", "getDarkSealAbility", "getBallSpeedLimits", "getDeflectCD",
        "getSnapshot", "getSnapshotAt", "isSnapshotValid", "getSyncData",
        "getSyncSequence", "decodeBallPacket", "getTargetId", "applySync",
        "installBallWatcher",
    },
}

return GameInfo
