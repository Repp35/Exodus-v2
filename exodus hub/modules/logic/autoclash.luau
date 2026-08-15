-- [[ AutoClash ]]

-- constants
local AutoClash = {}
local GameInfo
local Utils
local AutoParry
local heartbeatConnection
local bindGeneration = 0

-- tuning
local C = {
	DET_RAD_MIN = 14,
	DET_RAD_MAX = 32,
	DET_RAD_SPD_REF = 120,
	DET_DOT_EMA = 0.25,
	DET_DOT_THRESH = 0.15,
	DET_RADIUS_SLACK = 1.20,
	TARGET_RETURN_MAX_LO = 0.110,
	TARGET_RETURN_MIN_HI = 0.060,
	TARGET_RETURN_SPD_LO = 60,
	TARGET_RETURN_SPD_HI = 200,
	INV_DIST_CAP = 25,
	INV_APPROACH_SPD_MIN = 50,
	INV_DOT_MIN = 0.35,
	ACTIVE_LOCK = 0.080,
	INACTIVE_LOCK = 0.080,
}

-- state
local S = {
	enabled = false,
	active = false,
	activeAt = 0,
	inactiveAt = 0,
	detDotEma = 0,
	detSignal = false,
	lastTarget = -999,
	lastTargetAt = 0,
	wasMeTarget = false,
	lostMeAt = 0,
	teleportLockUntil = 0,
}
local function now()
	return Utils.now()
end
local function getLocalPlayer()
	return Utils.getLocalPlayer()
end
local function getBall()
	return GameInfo.getBall()
end
local function getBallVelocity(ball)
	if not ball or not ball.Parent then
		return nil
	end
	local ok, velocity = pcall(function()
		return ball.AssemblyLinearVelocity
	end)
	if not ok or typeof(velocity) ~= "Vector3" then
		return nil
	end
	return velocity
end
local function getBallSpeed(ball)
	local velocity = getBallVelocity(ball)
	return velocity and velocity.Magnitude or 0
end
local function lerpBySpeed(speed, speedLow, speedHigh, valueLow, valueHigh)
	if speedHigh <= speedLow then
		return valueLow
	end
	local alpha = math.clamp(
		(speed - speedLow) / (speedHigh - speedLow),
		0,
		1
	)
	return valueLow + (valueHigh - valueLow) * alpha
end
local function resetDetector()
	S.detDotEma = 0
	S.detSignal = false
end
local function activate(t)
	if S.active then
		return false
	end
	if t - S.inactiveAt < C.INACTIVE_LOCK then
		return false
	end
	S.active = true
	S.activeAt = t
	S.inactiveAt = 0
	resetDetector()
	return true
end
local function deactivate(t)
	if not S.active then
		return false
	end
	if t - S.activeAt < C.ACTIVE_LOCK then
		return false
	end
	S.active = false
	S.activeAt = 0
	S.inactiveAt = t
	resetDetector()
	return true
end
local function forceDeactivate(t)
	if not S.active then
		return false
	end
	S.active = false
	S.activeAt = 0
	S.inactiveAt = t
	resetDetector()
	return true
end
local function getDetectorRadius(speed)
	local alpha = math.clamp(
		speed / C.DET_RAD_SPD_REF,
		0,
		1
	)
	return C.DET_RAD_MIN
		+ (C.DET_RAD_MAX - C.DET_RAD_MIN) * alpha
end

-- detector
local function tickDetector(hr, ball)
	S.detSignal = false
	if not (
		hr
		and hr.Parent
		and ball
		and ball.Parent
	) then
		S.detDotEma = 0
		return false
	end
	local velocity = getBallVelocity(ball)
	if not velocity or velocity.Magnitude <= 1 then
		S.detDotEma = 0
		return false
	end
	local speed = velocity.Magnitude
	local offset = hr.Position - ball.Position
	local distance = offset.Magnitude
	if distance < 0.001 then
		S.detDotEma = 0
		return false
	end
	local radius = getDetectorRadius(speed)
	local dot = velocity:Dot(offset.Unit)
	if distance <= radius * C.DET_RADIUS_SLACK then
		S.detDotEma =
			S.detDotEma * (1 - C.DET_DOT_EMA)
			+ dot * C.DET_DOT_EMA
	else
		S.detDotEma = 0
	end
	if distance <= radius
		and S.detDotEma > C.DET_DOT_THRESH
	then
		S.detSignal = true
	end
	return S.detSignal
end
local function invisibleGate(hr, ball)
	if not (
		hr
		and hr.Parent
		and ball
		and ball.Parent
	) then
		return false
	end
	local velocity = getBallVelocity(ball)
	if not velocity then
		return false
	end
	local speed = velocity.Magnitude
	if speed < C.INV_APPROACH_SPD_MIN then
		return false
	end
	local offset = hr.Position - ball.Position
	local distance = offset.Magnitude
	if distance > C.INV_DIST_CAP then
		return false
	end
	if distance < 0.001 then
		return true
	end
	local dot = velocity:Dot(offset.Unit)
	return dot >= C.INV_DOT_MIN * speed
end

-- activation
local function shouldActivate(t, hr, ball)
	if not (
		hr
		and hr.Parent
		and ball
		and ball.Parent
	) then
		return false
	end
	local targeted = AutoParry.isTargeted()
	if not targeted then
		return false
	end
	if tickDetector(hr, ball) then
		return true
	end
	if invisibleGate(hr, ball) then
		return true
	end
	return false
end

-- deactivation
local function shouldDeactivate(t, hr, ball)
	if t < S.teleportLockUntil then
		return true
	end
	return not (
		hr
		and hr.Parent
		and ball
		and ball.Parent
	)
end

-- evaluation
local function evaluate(t, hr, ball, config)
	local enabled =
		config
		and config.AutoClash ~= false
		and not Utils.isManualSpamActive()
	if not enabled then
		S.enabled = false
		forceDeactivate(now())
		return
	end
	if GameInfo.isGrace() then
		forceDeactivate(now())
		return
	end
	S.enabled = true
	if not hr or not hr.Parent then
		forceDeactivate(now())
		return
	end
	if not ball or not ball.Parent then
		forceDeactivate(now())
		return
	end
	if t < S.teleportLockUntil then
		forceDeactivate(now())
		return
	end
	if S.active then
		if shouldDeactivate(t, hr, ball) then
			deactivate(t)
		end
		return
	end
	if shouldActivate(t, hr, ball) then
		activate(t)
	end
end
local function getTargetReturnWindow(speed)
	return lerpBySpeed(
		speed,
		C.TARGET_RETURN_SPD_LO,
		C.TARGET_RETURN_SPD_HI,
		C.TARGET_RETURN_MAX_LO,
		C.TARGET_RETURN_MIN_HI
	)
end

-- target
local function onTarget(newTarget, t)
	if type(newTarget) ~= "number" then
		return
	end
	local previousTarget = S.lastTarget
	local player = getLocalPlayer()
	local userId = player and player.UserId
	if not userId then
		return
	end
	S.lastTarget = newTarget
	S.lastTargetAt = t
	local getState = AutoParry.getState
	if type(getState) == "function" then
		local state = getState()
		if state then
			state.armed = newTarget == userId
		end
	end
	local isMe = newTarget == userId
	local wasMe = previousTarget == userId
	if wasMe and not isMe then
		S.wasMeTarget = true
		S.lostMeAt = t
		return
	end
	if not isMe or wasMe or not S.wasMeTarget then
		return
	end
	local ball = getBall()
	local speed = getBallSpeed(ball)
	local window = getTargetReturnWindow(speed)
	local elapsed = t - S.lostMeAt
	if elapsed <= window then
		activate(t)
	end
	S.wasMeTarget = false
	S.lostMeAt = 0
end

-- teleport
local function onTeleport()
	local t = now()
	S.teleportLockUntil = t + 0.5
	forceDeactivate(t)
end

-- lifecycle
local function disconnectHeartbeat()
    if heartbeatConnection then
        pcall(function()
            heartbeatConnection:Disconnect()
        end)
        heartbeatConnection = nil
    end
end
local function bindCharacter(character)
    bindGeneration = bindGeneration + 1
    local currentGeneration = bindGeneration
    disconnectHeartbeat()
    if not (character and character.Parent) then
        return false
    end
    local root = character:FindFirstChild("HumanoidRootPart")
        or character:WaitForChild("HumanoidRootPart", 1)
    if not (root and root.Parent) then
        return false
    end
    heartbeatConnection = Utils.getRunService().Heartbeat:Connect(function()
        if currentGeneration ~= bindGeneration or not Utils.isActive() then
            return
        end
        if not (character.Parent and root.Parent) then
            forceDeactivate(now())
            return
        end
        local timestamp = now()
        evaluate(timestamp, root, GameInfo.getBall(), Utils.getConfig())
    end)
    Utils.trackCharacter(heartbeatConnection)
    return true
end

-- setup
function AutoClash.setup(deps)
	if type(deps) ~= "table" then
		return false
	end
	GameInfo = deps.GameInfo
	Utils = deps.Utils
	AutoParry = deps.AutoParry
	if not GameInfo or not Utils or not AutoParry then
		return false
	end
	Utils.setOnClashOn(function()
		return S.active
	end)
    return true
end
function AutoClash.bindCharacter(character)
    return bindCharacter(character)
end

-- public
function AutoClash.clashOn()
	return S.active
end
function AutoClash.onBallSync(data)
    if typeof(data) ~= "table" then
        return
    end
    if data.Teleported == true then
        onTeleport()
        return
    end
    onTarget(data.TargetPlayerID or -999, now())
end
function AutoClash.resetState()
    bindGeneration = bindGeneration + 1
    disconnectHeartbeat()
    S.enabled = false
	S.active = false
	S.activeAt = 0
	S.inactiveAt = 0
	S.detDotEma = 0
	S.detSignal = false
	S.lastTarget = -999
	S.lastTargetAt = 0
	S.wasMeTarget = false
	S.lostMeAt = 0
	S.teleportLockUntil = 0
end
return AutoClash
