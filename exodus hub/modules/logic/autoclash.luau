-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
        -- activation
        RETURN_WIN_LO = 0.090,
        RETURN_WIN_MIN_FACTOR = 0.50,
        RETURN_SPD_LO = 60,
        RETURN_SPD_HI = 600,
        PING_FACTOR = 0.3,
        ACT_RADIUS_EXTRA_WINDOW = 0.150,
        REACTIVATE_COOLDOWN = 0.25,
        INSTANT_REACT_FACTOR = 0.25,

        -- deactivation
        DEACT_TRAVEL_GUARD_WINDOW = 0.130,
        DEACT_TRAVEL_MAX_LO = 0.085,
        DEACT_TRAVEL_MAX_MIN_FACTOR = 0.50,
        DEACT_TRAVEL_SPD_LO = 60,
        DEACT_TRAVEL_SPD_HI = 600,
        DEACT_TRAVEL_HOLD = 0.020,
        DEACT_APPROACH_WINDOW = 0.65,
        DEACT_RADIUS_FACTOR = 1.65,
        DEACT_RADIUS_EXTRA_WINDOW = 0.090,
        DEACT_OUT_WINDOW = 0.100,

        -- system
        MIN_EVAL_INTERVAL = 1 / 120,
}

-- runtime
local R = {
        generation = 0,
        bound = false,
        active = false,
        phase = "detached",
        boundRoot = nil,
        localUserId = nil,
        lastTarget = -1,
        clashPartnerId = -1,
        lastSpeed = 0,
        parryRadius = 0,
        lostMeAt = 0,
        returnPending = false,
        instantReactPending = false,
        instantReactReady = false,
        approachNegSince = 0,
        outSince = 0,
        travelSince = 0,
        wasMeTarget = nil,
        lastEvalAt = 0,
        reactivateBlockedUntil = 0,
        connections = {},
        lastGate = "none",
}

-- helpers
local function normalizeTarget(target)
        if type(target) == "string" then
                target = tonumber(target)
        end
        return type(target) == "number" and target or nil
end

local function getNow()
        if not Utils or type(Utils.now) ~= "function" then
                return 0
        end
        local ok, value = pcall(Utils.now)
        return ok and tonumber(value) or 0
end

local function getPingOneWay()
        if not AutoParry or type(AutoParry.getPingOneWay) ~= "function" then
                return 0
        end
        local ok, value = pcall(AutoParry.getPingOneWay)
        return ok and math.max(tonumber(value) or 0, 0) or 0
end

local function getRootPosition()
        local root = R.boundRoot
        if not (root and root.Parent) then
                return nil
        end
        local ok, position = pcall(function()
                return root.Position
        end)
        return ok and typeof(position) == "Vector3" and position or nil
end

local function getSnapshotPosition(snapshot)
        local position = snapshot and snapshot.position
        return typeof(position) == "Vector3" and position or nil
end

local function lerp(speed, lo, hi, speedLo, speedHi)
        speed = tonumber(speed) or 0
        if speedHi <= speedLo then
                return lo
        end
        local alpha = math.clamp((speed - speedLo) / (speedHi - speedLo), 0, 1)
        return lo + (hi - lo) * alpha
end

local function getReturnWindow(speed)
        local base = lerp(
                speed,
                T.RETURN_WIN_LO,
                T.RETURN_WIN_LO * T.RETURN_WIN_MIN_FACTOR,
                T.RETURN_SPD_LO,
                T.RETURN_SPD_HI
        )
        return math.max(base + getPingOneWay() * T.PING_FACTOR, 0)
end

local function clearReturnState()
        R.lostMeAt = 0
        R.returnPending = false
end

local function clearInstantReactState()
        R.instantReactPending = false
        R.instantReactReady = false
end

local function resetDeactivationState()
        R.approachNegSince = 0
        R.outSince = 0
        R.travelSince = 0
end

local function resetTargetState()
        R.lastTarget = -1
        R.clashPartnerId = -1
        R.wasMeTarget = nil
        clearReturnState()
        clearInstantReactState()
        resetDeactivationState()
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
        R.active = active
        resetDeactivationState()
        if active then
                if R.clashPartnerId == -1 and R.lastTarget ~= R.localUserId then
                        R.clashPartnerId = R.lastTarget
                end
        else
                R.clashPartnerId = -1
                R.reactivateBlockedUntil = getNow() + T.REACTIVATE_COOLDOWN
        end
        if Utils and type(Utils.setAutoSpamActive) == "function" then
                pcall(Utils.setAutoSpamActive, active)
        end
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

local function resetRuntime(reason)
        R.generation = R.generation + 1
        if R.active then
                setActive(false, reason or "reset")
        end
        disconnectConnections()
        R.bound = false
        R.boundRoot = nil
        R.lastSpeed = 0
        R.parryRadius = 0
        R.lastEvalAt = 0
        R.reactivateBlockedUntil = 0
        resetTargetState()
        R.lastGate = "detached"
        setPhase("detached", reason or "reset")
end

-- target / rally
local function rallyCheck(data)
        if not R.active or type(data) ~= "table" then
                return true
        end

        local newTarget = normalizeTarget(data.TargetPlayerID)

        if not newTarget or newTarget == R.localUserId or newTarget == R.clashPartnerId then
                return true
        end

        local rootPos = getRootPosition()
        local realPosition = data.RealPosition

        if not rootPos or typeof(realPosition) ~= "Vector3" then
                return true
        end

        local speed = math.max(
                tonumber(R.lastSpeed) or tonumber(data.Speed) or 0,
                0
        )

        local parryRadius = math.max(tonumber(R.parryRadius) or 0, 0)

        if parryRadius <= 0 then
                return true
        end

        local effectiveRadius = parryRadius + speed * T.ACT_RADIUS_EXTRA_WINDOW

        if (rootPos - realPosition).Magnitude > effectiveRadius then
                setActive(false, "rally_outside_effective_radius")
                clearReturnState()
                return false
        end

        R.clashPartnerId = newTarget
        return true
end

-- activation
local function shouldActivate(snapshot)
        if not (snapshot and snapshot.ball and snapshot.ball.Parent) then
                R.lastGate = "no_ball"
                return false
        end

        local rootPos = getRootPosition()

        if not rootPos then
                R.lastGate = "no_root"
                return false
        end

        if snapshot.targeted ~= true then
                R.lastGate = "target_not_me"
                return false
        end

        local position = getSnapshotPosition(snapshot)

        if not position then
                R.lastGate = "no_position"
                return false
        end

        local parryRadius = math.max(tonumber(R.parryRadius) or 0, 0)

        if parryRadius <= 0 then
                R.lastGate = "no_effective_radius"
                return false
        end

        local effectiveRadius = parryRadius + R.lastSpeed * T.ACT_RADIUS_EXTRA_WINDOW

        if (rootPos - position).Magnitude > effectiveRadius then
                R.lastGate = "outside_effective_radius"
                return false
        end

        R.lastGate = "activation_ready"
        return true
end

local function canReactivate()
        if getNow() < R.reactivateBlockedUntil then
                R.lastGate = "reactivate_cooldown"
                return false
        end
        return true
end

local function tryReturnActivate(snapshot)
        return R.returnPending and canReactivate() and shouldActivate(snapshot)
end

local function tryInstantReactivate()
        if not R.instantReactReady then
                return false
        end

        if not canReactivate() then
                return false
        end

        return true
end

-- deactivation
local function shouldDeactivate(t, snapshot)
        local rootPos = getRootPosition()
        local position = getSnapshotPosition(snapshot)

        if not (rootPos and position) then
                return false
        end

        local parryRadius = math.max(tonumber(R.parryRadius) or 0, 0)

        if parryRadius <= 0 then
                return false
        end

        local speed = math.max(tonumber(R.lastSpeed) or 0, 0)
        local distance = (rootPos - position).Magnitude

        local travelGuardRadius = math.max(
                parryRadius - speed * T.DEACT_TRAVEL_GUARD_WINDOW,
                0
        )

        if distance > travelGuardRadius then
                if speed > 0 then
                        local travelMax = lerp(
                                speed,
                                T.DEACT_TRAVEL_MAX_LO,
                                T.DEACT_TRAVEL_MAX_LO * T.DEACT_TRAVEL_MAX_MIN_FACTOR,
                                T.DEACT_TRAVEL_SPD_LO,
                                T.DEACT_TRAVEL_SPD_HI
                        )

                        if distance / speed > travelMax then
                                R.travelSince = R.travelSince > 0 and R.travelSince or t

                                if t - R.travelSince >= T.DEACT_TRAVEL_HOLD then
                                        R.lastGate = "deact_travel"
                                        R.travelSince = 0
                                        return true
                                end
                        else
                                R.travelSince = 0
                        end
                end
        end

        local approachingSpeed = snapshot.approachingSpeed

        if type(approachingSpeed) == "number" then
                if approachingSpeed < 0 then
                        R.approachNegSince = R.approachNegSince > 0 and R.approachNegSince or t

                        if t - R.approachNegSince >= getReturnWindow(speed) * T.DEACT_APPROACH_WINDOW then
                                R.lastGate = "deact_approach"
                                return true
                        end
                else
                        R.approachNegSince = 0
                end
        end

        if distance > parryRadius * T.DEACT_RADIUS_FACTOR then
                R.lastGate = "deact_radius_factor"
                return true
        end

        local deactOutRadius = parryRadius + speed * T.DEACT_RADIUS_EXTRA_WINDOW

        if distance > deactOutRadius then
                R.outSince = R.outSince > 0 and R.outSince or t

                if t - R.outSince >= T.DEACT_OUT_WINDOW then
                        R.lastGate = "deact_out_window"
                        return true
                end
        else
                R.outSince = 0
        end

        R.lastGate = "deact_none"
        return false
end

-- state update
local function updateParryState(t, snapshot)
        R.lastSpeed = math.max(tonumber(snapshot.speed) or 0, 0)

        if AutoParry and type(AutoParry.getParryRadius) == "function" then
                local ok, radius = pcall(
                        AutoParry.getParryRadius,
                        R.lastSpeed,
                        t
                )

                radius = ok and tonumber(radius)

                if radius and radius >= 0 then
                        R.parryRadius = radius
                end
        end
end

-- main evaluation
local function evaluateClash(t, snapshot)
        if not (
                R.boundRoot
                and R.boundRoot.Parent
                and snapshot
                and snapshot.ball
                and snapshot.ball.Parent
        ) then
                return
        end

        updateParryState(t, snapshot)

        if R.active then
                if shouldDeactivate(t, snapshot) then
                        setActive(false, "target_deactivated")
                        clearReturnState()
                end
        elseif tryInstantReactivate() then
                R.instantReactReady = false
                R.instantReactPending = false
                setActive(true, "instant_reactivate")
        elseif tryReturnActivate(snapshot) then
                clearReturnState()
                setActive(true, "activated")
        end
end

-- heartbeat
local function heartbeatStep(generation, character, root)
        if generation ~= R.generation or not (character.Parent and root.Parent) then
                return
        end

        if Utils.isManualSpamActive() then
                if R.active then
                        setActive(false, "manual_spam")
                end
                resetTargetState()
                R.lastGate = "manual_spam"
                return
        end

        if not Utils.isActive() then
                if R.active then
                        setActive(false, "hub_inactive")
                end
                resetTargetState()
                R.lastGate = "hub_inactive"
                return
        end

        local config = Utils.getConfig()

        if not (config and config.AutoClash) then
                if R.active then
                        setActive(false, "hub_disabled")
                end
                resetTargetState()
                R.lastGate = "hub_disabled"
                return
        end

        local t = getNow()

        if t - R.lastEvalAt < T.MIN_EVAL_INTERVAL then
                return
        end

        R.lastEvalAt = t

        local snapshot = GameInfo.getSnapshot(R.lastTarget, t)

        if not GameInfo.isSnapshotValid(snapshot, t) then
                return
        end

        local target = normalizeTarget(snapshot.targetId)

        if target then
                R.lastTarget = target
        end

        evaluateClash(t, snapshot)
end

-- character
local function bindCharacter(character)
        resetRuntime("rebind")

        local generation = R.generation

        if not (character and character.Parent) then
                return false
        end

        local root = character:FindFirstChild("HumanoidRootPart")
                or character:WaitForChild("HumanoidRootPart", 1)

        if not (generation == R.generation and root and root.Parent) then
                return false
        end

        R.boundRoot = root
        R.lastGate = "waiting_for_character"

        local heartbeat = Utils.getRunService().Heartbeat:Connect(function()
                heartbeatStep(generation, character, root)
        end)

        R.connections[#R.connections + 1] = heartbeat
        Utils.trackCharacter(heartbeat)

        local ancestry = character.AncestryChanged:Connect(function(_, parent)
                if parent then
                        return
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
        local required = {
                {"AutoParry", "getParryRadius"},
                {"AutoParry", "getPingOneWay"},
                {"GameInfo", "getSnapshot"},
                {"GameInfo", "isSnapshotValid"},
                {"Utils", "now"},
                {"Utils", "getConfig"},
                {"Utils", "getRunService"},
                {"Utils", "recordTransition"},
                {"Utils", "setAutoSpamActive"},
                {"Utils", "trackCharacter"},
                {"Utils", "untrackCharacter"},
                {"Utils", "isActive"},
                {"Utils", "isManualSpamActive"},
                {"Utils", "getLocalPlayer"},
                {"Utils", "apiVersion"},
        }

        if not deps then
                return false
        end

        for _, requirement in ipairs(required) do
                local object = deps[requirement[1]]

                if not object or type(object[requirement[2]]) ~= "function" then
                        return false
                end
        end

        if Utils then
                resetRuntime("setup")
        end

        AutoParry = deps.AutoParry
        GameInfo = deps.GameInfo
        Utils = deps.Utils

        local player = Utils.getLocalPlayer()

        R.localUserId = player and player.UserId or nil
        R.generation = 0
        R.bound = false
        R.active = false
        R.phase = "detached"
        R.boundRoot = nil
        R.lastSpeed = 0
        R.parryRadius = 0
        R.lastEvalAt = 0
        R.reactivateBlockedUntil = 0
        R.connections = {}

        resetTargetState()

        R.lastGate = "none"

        return true
end

function AutoClash.bindCharacter(character)
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

function AutoClash.onBallSync(data)
        if type(data) ~= "table" or not Utils or not R.localUserId then
                return
        end

        if data.Teleported == true then
                if R.active then
                        setActive(false, "teleported")
                end

                resetTargetState()
                R.lastGate = "teleported"
                return
        end

        local target = normalizeTarget(data.TargetPlayerID)

        if not target then
                if R.active then
                        setActive(false, "invalid_target")
                end

                resetTargetState()
                R.lastGate = "invalid_target"
                return
        end

        local previousTargetId = R.lastTarget
        R.lastTarget = target

        local wasMe = R.wasMeTarget
        local isMe = target == R.localUserId

        if wasMe == nil then
                R.wasMeTarget = isMe
                R.lastGate = isMe and "initial_me" or "initial_not_me"
                return
        end

        if wasMe and not isMe then
                if R.active then
                        if not rallyCheck(data) then
                                R.wasMeTarget = isMe
                                return
                        end
                else
                        R.clashPartnerId = target
                        R.instantReactPending = true
                        R.instantReactReady = false
                end

                R.lostMeAt = getNow()
                R.returnPending = false
                R.lastGate = "target_lost"

        elseif not wasMe and isMe then
                R.becameTargetAt = nil

                if previousTargetId ~= -1 and previousTargetId ~= R.localUserId then
                        R.clashPartnerId = previousTargetId
                end

                -- Return activation window.
                local lostAt = R.lostMeAt

                if lostAt > 0 then
                        local now = getNow()
                        local elapsed = now - lostAt
                        local window = getReturnWindow(R.lastSpeed)

                        if elapsed >= 0 and elapsed <= window then
                                R.returnPending = true
                                R.lastGate = "target_return"
                        else
                                R.lostMeAt = 0
                                R.returnPending = false
                                R.lastGate = "return_too_late"
                        end
                else
                        R.returnPending = false
                        R.lastGate = "return_without_loss"
                end

                -- Instant react:
                -- only ME -> NOT-ME -> ME can arm it.
                -- The distance is sampled exactly at this target transition.
                if R.instantReactPending then
                        local rootPos = getRootPosition()
                        local position = typeof(data.RealPosition) == "Vector3"
                                and data.RealPosition
                                or nil

                        local parryRadius = math.max(
                                tonumber(R.parryRadius) or 0,
                                0
                        )

                        if rootPos and position and parryRadius > 0 then
                                local distance = (rootPos - position).Magnitude
                                local instantRadius = parryRadius * T.INSTANT_REACT_FACTOR

                                R.instantReactReady = distance <= instantRadius
                        else
                                R.instantReactReady = false
                        end

                        R.instantReactPending = false

                        if R.instantReactReady then
                                R.lastGate = "instant_react_ready"
                        end
                else
                        R.instantReactReady = false
                end
        end

        R.wasMeTarget = isMe
end

function AutoClash.isActive()
        return R.active == true
end

function AutoClash.getStatus()
        local schema

        if Utils and type(Utils.apiVersion) == "function" then
                local ok, value = pcall(Utils.apiVersion)

                if ok then
                        schema = value
                end
        end

        return {
                schema = schema,
                phase = R.phase,
                bound = R.bound == true,
                active = R.active == true,
                parryRadius = R.parryRadius,
                lastTarget = R.lastTarget,
                clashPartnerId = R.clashPartnerId,
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