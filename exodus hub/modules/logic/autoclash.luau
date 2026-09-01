-- [[ Auto Clash ]]

local AutoClash = {}
local AutoParry
local GameInfo
local Utils

-- tuning
local T = {
RETURN_WIN_LO = 0.100,
RETURN_WIN_HI = 0.060,
RETURN_SPD_LO = 60,
RETURN_SPD_HI = 600,
PING_FACTOR = 0.3,
DEACT_FACTOR = 1.4,
DEACT_DISTANCE_EMA_ALPHA = 0.20,
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
lastSpeed = 0,
parryRadius = 0,
lostMeAt = 0,
returnPending = false,
deactOutsideAt = 0,
deactDistanceEMA = nil,
wasMeTarget = nil,
lastEvalAt = 0,
connections = {},
lastGate = "none",
}

-- helpers
local function lerp(speed, lo, hi, spdLo, spdHi)
speed = tonumber(speed) or 0

if spdHi <= spdLo then
    return lo
end

local alpha = math.clamp(
    (speed - spdLo) / (spdHi - spdLo),
    0,
    1
)

return lo + (hi - lo) * alpha

end

local function getPingOneWay()
if not AutoParry
or type(AutoParry.getPingOneWay) ~= "function"
then
return 0
end

local ok, ping =
    pcall(AutoParry.getPingOneWay)

if not ok then
    return 0
end

ping = tonumber(ping) or 0

return math.max(ping, 0)

end

local function returnWindow(speed)
local base = lerp(
speed,
T.RETURN_WIN_LO,
T.RETURN_WIN_HI,
T.RETURN_SPD_LO,
T.RETURN_SPD_HI
)

local window =
    base
    + getPingOneWay()
    * T.PING_FACTOR

return math.max(window, 0)

end

local function deactivationWindow(speed)
return math.max(
returnWindow(speed)
* T.DEACT_FACTOR,
0
)
end

local function setPhase(phase, reason)
if R.phase == phase then
return
end

local previous = R.phase
R.phase = phase

if Utils
    and type(Utils.recordTransition) == "function"
then
    pcall(
        Utils.recordTransition,
        "AutoClash",
        previous,
        phase,
        reason
    )
end

end

local function setActive(active, reason)
active = active == true

if R.active == active then
    return
end

R.active = active

if Utils
    and type(Utils.setAutoSpamActive) == "function"
then
    pcall(
        Utils.setAutoSpamActive,
        active
    )
end

setPhase(
    active and "active" or "idle",
    reason
)

end

local function resetTargetState()
R.lastTarget = -1
R.lostMeAt = 0
R.returnPending = false
R.deactOutsideAt = 0
R.deactDistanceEMA = nil
R.wasMeTarget = nil
end

local function resetDeactivationState()
R.deactOutsideAt = 0
R.deactDistanceEMA = nil
end

local function disconnectConnections()
for i = #R.connections, 1, -1 do
local connection = R.connections[i]
R.connections[i] = nil

    if Utils
        and type(Utils.untrackCharacter) == "function"
    then
        pcall(
            Utils.untrackCharacter,
            connection
        )
    end

    pcall(function()
        connection:Disconnect()
    end)
end

end

local function resetRuntime(reason)
R.generation = R.generation + 1

if R.active then
    setActive(
        false,
        reason or "reset"
    )
end

disconnectConnections()

R.bound = false
R.boundRoot = nil
R.lastSpeed = 0
R.parryRadius = 0
R.lastEvalAt = 0
R.lastGate = "detached"

resetTargetState()

setPhase(
    "detached",
    reason or "reset"
)

end

-- activation
local function shouldActivate(snapshot)
if not (
snapshot
and snapshot.ball
and snapshot.ball.Parent
) then
R.lastGate = "no_ball"
return false
end

if not (
    R.boundRoot
    and R.boundRoot.Parent
) then
    R.lastGate = "no_root"
    return false
end

if snapshot.targeted ~= true then
    R.lastGate = "target_not_me"
    return false
end

if not R.returnPending then
    R.lastGate = "awaiting_return"
    return false
end

R.returnPending = false
R.lostMeAt = 0

resetDeactivationState()

R.lastGate = "target_return"

return true

end

-- deactivation
local function shouldDeactivate(t, snapshot)
local root = R.boundRoot
local position =
snapshot
and snapshot.position

if not (
    root
    and root.Parent
    and position
) then
    return false
end

local ok, rootPosition =
    pcall(function()
        return root.Position
    end)

if not (
    ok
    and typeof(rootPosition) == "Vector3"
    and typeof(position) == "Vector3"
) then
    return false
end

local distance =
    (rootPosition - position).Magnitude

local alpha =
    math.clamp(
        tonumber(T.DEACT_DISTANCE_EMA_ALPHA) or 0,
        0,
        1
    )

if R.deactDistanceEMA == nil then
    R.deactDistanceEMA = distance
else
    R.deactDistanceEMA =
        R.deactDistanceEMA
        + (
            distance
            - R.deactDistanceEMA
        )
        * alpha
end

if R.deactDistanceEMA <= R.parryRadius then
    R.deactOutsideAt = 0
    return false
end

if R.deactOutsideAt <= 0 then
    R.deactOutsideAt = t
    return false
end

local elapsed =
    t - R.deactOutsideAt

if elapsed < 0 then
    R.deactOutsideAt = t
    return false
end

return elapsed
    >= deactivationWindow(
        R.lastSpeed
    )

end

-- main evaluation
local function evaluateClash(t, snapshot)
if not (
R.boundRoot
and R.boundRoot.Parent
) then
return
end

if not (
    snapshot
    and snapshot.ball
    and snapshot.ball.Parent
) then
    return
end

R.lastSpeed =
    math.max(
        tonumber(snapshot.speed) or 0,
        0
    )

if AutoParry
    and type(AutoParry.getParryRadius) == "function"
then
    local ok, radius =
        pcall(
            AutoParry.getParryRadius,
            R.lastSpeed,
            t
        )

    if ok then
        radius = tonumber(radius)

        if radius
            and radius >= 0
        then
            R.parryRadius = radius
        end
    end
end

if R.active then
    if shouldDeactivate(
        t,
        snapshot
    ) then
        setActive(
            false,
            "target_deactivated"
        )

        resetDeactivationState()
        R.returnPending = false
        R.lostMeAt = 0
    end

    return
end

if shouldActivate(snapshot) then
    setActive(
        true,
        "activated"
    )
end

end

-- character
local function bindCharacter(character)
resetRuntime("rebind")

local generation =
    R.generation

if not (
    character
    and character.Parent
) then
    return false
end

local root =
    character:FindFirstChild(
        "HumanoidRootPart"
    )
    or character:WaitForChild(
        "HumanoidRootPart",
        1
    )

if not (
    generation == R.generation
    and root
    and root.Parent
) then
    return false
end

R.boundRoot = root
R.lastGate =
    "waiting_for_character"

local heartbeat =
    Utils.getRunService()
        .Heartbeat
        :Connect(function()
            if generation
                ~= R.generation
            then
                return
            end

            if not (
                character.Parent
                and root.Parent
            ) then
                return
            end

            if Utils.isManualSpamActive() then
                if R.active then
                    setActive(
                        false,
                        "manual_spam"
                    )
                end

                resetTargetState()
                R.lastGate = "manual_spam"
                return
            end

            if not Utils.isActive() then
                if R.active then
                    setActive(
                        false,
                        "hub_inactive"
                    )
                end

                resetTargetState()
                R.lastGate = "hub_inactive"
                return
            end

            local config =
                Utils.getConfig()

            if not (
                config
                and config.AutoClash
            ) then
                if R.active then
                    setActive(
                        false,
                        "hub_disabled"
                    )
                end

                resetTargetState()
                R.lastGate = "hub_disabled"
                return
            end

            local t =
                Utils.now()

            if t - R.lastEvalAt
                < T.MIN_EVAL_INTERVAL
            then
                return
            end

            R.lastEvalAt = t

            local snapshot =
                GameInfo.getSnapshot(
                    R.lastTarget,
                    t
                )

            if not GameInfo
                .isSnapshotValid(
                    snapshot,
                    t
                )
            then
                return
            end

            if type(
                snapshot.targetId
            ) == "number"
            then
                R.lastTarget =
                    snapshot.targetId
            elseif type(
                snapshot.targetId
            ) == "string"
            then
                R.lastTarget =
                    tonumber(
                        snapshot.targetId
                    )
                    or R.lastTarget
            end

            evaluateClash(
                t,
                snapshot
            )
        end)

R.connections[
    #R.connections + 1
] = heartbeat

Utils.trackCharacter(
    heartbeat
)

local ancestry =
    character.AncestryChanged
        :Connect(function(_, parent)
            if parent then
                return
            end

            resetRuntime(
                "character_removed"
            )

            R.lastGate =
                "character_removed"
        end)

R.connections[
    #R.connections + 1
] = ancestry

Utils.trackCharacter(
    ancestry
)

R.bound = true

setPhase(
    "waiting",
    "character_bound"
)

return true

end

-- setup
function AutoClash.setup(deps)
if not (
deps
and deps.AutoParry
and type(
deps.AutoParry.getParryRadius
) == "function"
and type(
deps.AutoParry.getPingOneWay
) == "function"
and deps.GameInfo
and type(
deps.GameInfo.getSnapshot
) == "function"
and type(
deps.GameInfo.isSnapshotValid
) == "function"
and deps.Utils
and type(
deps.Utils.now
) == "function"
and type(
deps.Utils.getConfig
) == "function"
and type(
deps.Utils.getRunService
) == "function"
and type(
deps.Utils.recordTransition
) == "function"
and type(
deps.Utils.setAutoSpamActive
) == "function"
and type(
deps.Utils.trackCharacter
) == "function"
and type(
deps.Utils.untrackCharacter
) == "function"
and type(
deps.Utils.isActive
) == "function"
and type(
deps.Utils.isManualSpamActive
) == "function"
and type(
deps.Utils.getLocalPlayer
) == "function"
and type(
deps.Utils.apiVersion
) == "function"
) then
return false
end

if Utils then
    resetRuntime("setup")
end

AutoParry = deps.AutoParry
GameInfo = deps.GameInfo
Utils = deps.Utils

local player =
    Utils.getLocalPlayer()

R.localUserId =
    player
    and player.UserId
    or nil

R.generation = 0
R.bound = false
R.active = false
R.phase = "detached"
R.boundRoot = nil
R.lastTarget = -1
R.lastSpeed = 0
R.parryRadius = 0
R.lostMeAt = 0
R.returnPending = false
R.deactOutsideAt = 0
R.deactDistanceEMA = nil
R.wasMeTarget = nil
R.lastEvalAt = 0
R.connections = {}
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
if type(data) ~= "table"
or not Utils
or not R.localUserId
then
return
end

if data.Teleported == true then
    if R.active then
        setActive(
            false,
            "teleported"
        )
    end

    resetTargetState()
    R.lastGate = "teleported"
    return
end

local target = data.TargetPlayerID

if type(target) == "string" then
    target = tonumber(target)
end

if type(target) ~= "number" then
    if R.active then
        setActive(
            false,
            "invalid_target"
        )
    end

    resetTargetState()
    R.lastGate = "invalid_target"
    return
end

R.lastTarget = target

local isMe =
    target == R.localUserId

if R.wasMeTarget == nil then
    R.wasMeTarget = isMe

    R.lastGate =
        isMe
        and "initial_me"
        or "initial_not_me"

    return
end

if R.wasMeTarget and not isMe then
    R.lostMeAt =
        Utils.now()

    R.returnPending = false
    resetDeactivationState()

    R.lastGate = "target_lost"

elseif not R.wasMeTarget and isMe then
    local lostAt =
        R.lostMeAt

    if lostAt > 0 then
        local now =
            Utils.now()

        local elapsed =
            now - lostAt

        local window =
            returnWindow(
                R.lastSpeed
            )

        if elapsed >= 0
            and elapsed <= window
        then
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
end

R.wasMeTarget = isMe

end

function AutoClash.isActive()
return R.active == true
end

function AutoClash.getStatus()
local schema

if Utils
    and type(Utils.apiVersion) == "function"
then
    local ok, value =
        pcall(Utils.apiVersion)

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