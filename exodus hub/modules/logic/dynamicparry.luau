-- [[ dynamic parry ]]

local DynamicParry = {}

local Remote
local AutoParry
local Utils
local onStateChanged

local HOLD_THRESHOLD = 0.10
local AP_DELAY = 0.010
local DEFAULT_RELEASE_DELAY = 0.20
local MAX_RELEASE_DELAY = 5

local State = {
	pressed = false,
	holding = false,
	generation = 0,
	releaseGeneration = 0,
}

local function now()
	if Utils and type(Utils.now) == "function" then
		return Utils.now()
	end

	return os.clock()
end

local function emit(state)
	if type(onStateChanged) == "function" then
		pcall(onStateChanged, state)
	end
end

local function ready()
	return Utils
		and type(Utils.isActive) == "function"
		and Utils.isActive()
		and Remote
		and type(Remote.fireParry) == "function"
end

local function lastAutoParry()
	if not AutoParry or type(AutoParry.getLastFireAt) ~= "function" then
		return 0
	end

	local ok, value = pcall(AutoParry.getLastFireAt)
	value = ok and tonumber(value) or 0

	if value and value == value and value > 0 then
		return value
	end

	return 0
end

local function releaseDelay()
	if Utils and type(Utils.getConfig) == "function" then
		local config = Utils.getConfig()

		if type(config) == "table" then
			local value = tonumber(config.DynamicParryReleaseDelay)

			if value and value == value and value >= 0 then
				return math.min(value, MAX_RELEASE_DELAY)
			end
		end
	end

	return DEFAULT_RELEASE_DELAY
end

local function waitForAutoParry(generation)
	local deadline = now()
	local last = lastAutoParry()

	if last > 0 then
		deadline = math.max(deadline, last + AP_DELAY)
	end

	local remaining = deadline - now()

	if remaining > 0 then
		task.wait(remaining)
	end

	return generation == State.generation
end

local function fire(generation)
	if generation ~= State.generation or not ready() then
		return false
	end

	if not waitForAutoParry(generation) then
		return false
	end

	local ok, result = pcall(Remote.fireParry, 1)

	if not ok or result == false then
		if Utils and type(Utils.recordError) == "function" then
			Utils.recordError("DynamicParry", "Remote.fireParry falhou")
		end

		return false
	end

	return true
end

local function enableHold(generation)
	if generation ~= State.generation
		or not State.pressed
		or State.holding
	then
		return
	end

	State.holding = true
	State.releaseGeneration += 1

	if Utils and type(Utils.setManualSpamActive) == "function" then
		Utils.setManualSpamActive(true)
	end

	emit("holding")
end

function DynamicParry.setup(deps)
	if type(deps) ~= "table"
		or type(deps.Remote) ~= "table"
		or type(deps.Remote.fireParry) ~= "function"
		or type(deps.AutoParry) ~= "table"
		or type(deps.AutoParry.getLastFireAt) ~= "function"
		or type(deps.Utils) ~= "table"
		or type(deps.Utils.isActive) ~= "function"
		or type(deps.Utils.setManualSpamActive) ~= "function"
	then
		return false, "dependência ausente: Remote, AutoParry ou Utils"
	end

	Remote = deps.Remote
	AutoParry = deps.AutoParry
	Utils = deps.Utils

	DynamicParry.resetState()

	return true
end

function DynamicParry.setStateHandler(handler)
	onStateChanged = type(handler) == "function" and handler or nil
end

function DynamicParry.tap()
	if State.pressed or State.holding then
		return false
	end

	local generation = State.generation
	local accepted = fire(generation)

	emit("released")

	return accepted
end

function DynamicParry.press()
	if State.pressed then
		return false
	end

	State.pressed = true
	State.holding = false
	State.generation += 1
	State.releaseGeneration += 1

	local generation = State.generation

	emit("pressed")

	fire(generation)

	task.delay(HOLD_THRESHOLD, function()
		enableHold(generation)
	end)

	return true
end

function DynamicParry.release()
	if not State.pressed then
		return false
	end

	local wasHolding = State.holding

	State.pressed = false
	State.holding = false
	State.releaseGeneration += 1

	if wasHolding then
		local generation = State.releaseGeneration
		local delayTime = releaseDelay()

		task.delay(delayTime, function()
			if generation ~= State.releaseGeneration
				or State.pressed
				or State.holding
			then
				return
			end

			if Utils and type(Utils.setManualSpamActive) == "function" then
				Utils.setManualSpamActive(false)
			end
		end)
	end

	emit("released")

	return true
end

function DynamicParry.resetState()
	State.generation += 1
	State.releaseGeneration += 1
	State.pressed = false
	State.holding = false

	if Utils and type(Utils.setManualSpamActive) == "function" then
		Utils.setManualSpamActive(false)
	end

	emit("released")
end

function DynamicParry.teardown()
	DynamicParry.resetState()

	Remote = nil
	AutoParry = nil
	Utils = nil
	onStateChanged = nil
end

function DynamicParry.getStatus()
	return {
		schema = Utils and Utils.apiVersion and Utils.apiVersion() or 1,
		pressed = State.pressed,
		holding = State.holding,
		holdThreshold = HOLD_THRESHOLD,
		releaseDelay = releaseDelay(),
		apDelay = AP_DELAY,
	}
end

DynamicParry.__contract = {
	requires = {
		Remote = "remote",
		AutoParry = "autoparry",
		Utils = "utils",
	},
}

return DynamicParry