-- [[ dynamicparry ]]

local DynamicParry = {}
local AutoParry
local Spam
local Utils
local onStateChanged
local onEarlyClickStateChanged

-- tuning
local HOLD_THRESHOLD = 0.10
local AP_DELAY = 0.010
local EARLY_CLICK_WINDOW = 0.20
local DEFAULT_RELEASE_DELAY = 0.20
local MAX_RELEASE_DELAY = 5

-- state
local State = {
	pressed = false,
	holding = false,
	pendingClick = false,
	pendingClickToken = 0,
	firing = false,
	fireToken = 0,
	generation = 0,
	releaseGeneration = 0,
}

-- helpers
local function now()
	if Utils and type(Utils.now) == "function" then return Utils.now() end
	return os.clock()
end
local function emit(state)
	if type(onStateChanged) == "function" then pcall(onStateChanged, state) end
end
local function emitEarlyClickState(state)
	if type(onEarlyClickStateChanged) == "function" then pcall(onEarlyClickStateChanged, state, EARLY_CLICK_WINDOW) end
end
local function ready()
	local config = Utils and type(Utils.getConfig) == "function" and Utils.getConfig() or nil; return type(config) == "table"
		and config.DynamicParry == true
		and Utils
		and type(Utils.isActive) == "function"
		and Utils.isActive()
		and Spam
		and type(Spam.isDynamicParryAllowed) == "function"
		and type(Spam.getDynamicClickCooldown) == "function"
		and type(Spam.getDynamicClickReadyAt) == "function"
		and type(Spam.requestDynamicClick) == "function"
end
local function lastAutoParry()
	if not AutoParry or type(AutoParry.getStatus) ~= "function" then return 0 end
	local ok, status = pcall(AutoParry.getStatus); local value = ok and type(status) == "table" and status.cycle and tonumber(status.cycle.lastFireAt) or 0
	if value and value == value and value > 0 then return value end
	return 0
end
local function releaseDelay()
	if Utils and type(Utils.getConfig) == "function" then
		local config = Utils.getConfig()
		if type(config) == "table" then
			local value = tonumber(config.DynamicParryReleaseDelay)
			if value and value == value and value >= 0 then return math.min(value, MAX_RELEASE_DELAY) end
		end
	end
	return DEFAULT_RELEASE_DELAY
end
local function earlyClickWindow() return EARLY_CLICK_WINDOW end
local function isInsideDynamicRadius()
	local ok, allowed = pcall(Spam.isDynamicParryAllowed); return ok and allowed == true
end
local function fire(generation, deadline)
	if generation ~= State.generation or not ready() or not isInsideDynamicRadius() or State.firing then return false end
	State.fireToken += 1; local fireToken = State.fireToken; State.firing = true
	while generation == State.generation and fireToken == State.fireToken do
		local nextClickAt = math.max(Spam.getDynamicClickReadyAt(), lastAutoParry() + AP_DELAY); local remaining = nextClickAt - now()
		if remaining <= 0 then break end
		if deadline and now() + remaining > deadline then break end
		task.wait(math.min(remaining, 0.005))
	end
	if
		generation ~= State.generation
		or fireToken ~= State.fireToken
		or not ready()
		or (deadline and now() > deadline)
		or not isInsideDynamicRadius()
	then
		if fireToken == State.fireToken then State.firing = false end
		return false
	end
	local ok, result = pcall(Spam.requestDynamicClick)
	if fireToken == State.fireToken then State.firing = false end
	if not ok then
		if Utils and type(Utils.recordError) == "function" then Utils.recordError("DynamicParry", tostring(result)) end
		return false
	end
	if result == false then return false end
	return true
end
local function cancelPendingClick()
	local wasPending = State.pendingClick; State.pendingClickToken += 1; State.pendingClick = false
	if wasPending then emitEarlyClickState("cancelled") end
	State.fireToken += 1; State.firing = false
end
local function requestClick(generation)
	if generation ~= State.generation or not ready() then return false end
	if isInsideDynamicRadius() then task.spawn(fire, generation); return true end
	if State.pendingClick then return false end
	local window = earlyClickWindow()
	if window <= 0 then return false end
	State.pendingClick = true; emitEarlyClickState("pending"); State.pendingClickToken += 1; local token = State.pendingClickToken
	local deadline = now() + window
	task.spawn(function()
		while generation == State.generation and token == State.pendingClickToken and State.pendingClick do
			if not ready() then break end
			local remaining = deadline - now()
			if remaining <= 0 then break end
			if isInsideDynamicRadius() then
				State.pendingClick = false; State.pendingClickToken += 1; emitEarlyClickState("accepted"); fire(generation, deadline)
				return
			end
			task.wait(math.min(0.005, remaining))
		end
		if token == State.pendingClickToken then State.pendingClick = false; State.pendingClickToken += 1; emitEarlyClickState(now() >= deadline and "expired" or "cancelled") end
	end)
	return true
end
local function enableHold(generation)
	if generation ~= State.generation or not State.pressed or State.holding then return end
	State.holding = true; State.releaseGeneration += 1
	if Utils and type(Utils.setDynamicSpamActive) == "function" then Utils.setDynamicSpamActive(true) end
	emit("holding")
end

-- setup
function DynamicParry.setup(deps)
	if
		type(deps) ~= "table"
		or type(deps.AutoParry) ~= "table"
		or type(deps.AutoParry.getStatus) ~= "function"
		or type(deps.Spam) ~= "table"
		or type(deps.Spam.isDynamicParryAllowed) ~= "function"
		or type(deps.Spam.getDynamicClickCooldown) ~= "function"
		or type(deps.Spam.getDynamicClickReadyAt) ~= "function"
		or type(deps.Spam.requestDynamicClick) ~= "function"
		or type(deps.Utils) ~= "table"
		or type(deps.Utils.isActive) ~= "function"
		or type(deps.Utils.getConfig) ~= "function"
		or type(deps.Utils.setDynamicSpamActive) ~= "function"
	then
		return false, "dependência ausente: AutoParry, Spam ou Utils"
	end
	AutoParry = deps.AutoParry; Spam = deps.Spam; Utils = deps.Utils; DynamicParry.resetState()
	return true
end

-- api
function DynamicParry.setStateHandler(handler) onStateChanged = type(handler) == "function" and handler or nil end
function DynamicParry.setEarlyClickStateHandler(handler)
	onEarlyClickStateChanged = type(handler) == "function" and handler or nil
end
function DynamicParry.tap()
	if State.pressed or State.holding then return false end
	cancelPendingClick(); local generation = State.generation; local accepted = requestClick(generation); emit("released")
	return accepted
end
function DynamicParry.press()
	if State.pressed then return false end
	cancelPendingClick(); State.pressed = true; State.holding = false; Utils.setDynamicSpamActive(false)
	State.generation += 1; State.releaseGeneration += 1; local generation = State.generation; emit("pressed")
	requestClick(generation)
	task.delay(HOLD_THRESHOLD, function() enableHold(generation) end)
	return true
end
function DynamicParry.release()
	if not State.pressed then return false end
	local wasHolding = State.holding; State.pressed = false; State.holding = false; State.releaseGeneration += 1
	if wasHolding then
		local generation = State.releaseGeneration; local delayTime = releaseDelay()
		task.delay(delayTime, function()
			if generation ~= State.releaseGeneration or State.pressed or State.holding then return end
			if Utils and type(Utils.setDynamicSpamActive) == "function" then Utils.setDynamicSpamActive(false) end
		end)
	end
	emit("released"); return true
end

-- lifecycle
function DynamicParry.resetState()
	State.generation += 1; State.releaseGeneration += 1; State.pressed = false; State.holding = false
	if Utils and type(Utils.setDynamicSpamActive) == "function" then Utils.setDynamicSpamActive(false) end
	cancelPendingClick(); emit("released")
end
function DynamicParry.cancel() DynamicParry.resetState() end
function DynamicParry.teardown()
	DynamicParry.resetState(); AutoParry = nil; Spam = nil; Utils = nil
	onStateChanged = nil; onEarlyClickStateChanged = nil
end
function DynamicParry.getStatus()
	return {
		schema = Utils and Utils.apiVersion and Utils.apiVersion() or 1,
		pressed = State.pressed,
		holding = State.holding,
		holdThreshold = HOLD_THRESHOLD,
		releaseDelay = releaseDelay(),
		dynamicSpamActive = Utils and type(Utils.isDynamicSpamActive) == "function" and Utils.isDynamicSpamActive()
			or false,
		pendingClick = State.pendingClick,
		clickCooldown = Spam and type(Spam.getDynamicClickCooldown) == "function" and Spam.getDynamicClickCooldown()
			or 0.010,
		earlyClickWindow = earlyClickWindow(),
	}
end
DynamicParry.__contract = {
	requires = {
		AutoParry = "autoparry",
		Spam = "spam",
		Utils = "utils",
	},

}

return DynamicParry
