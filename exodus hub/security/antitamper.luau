-- [[ antitamper ]]

local AntiTamper = {}
local Utils
local T = {
	INTERVAL = 0.5,
	KICK_MESSAGE = "Exodus: violacao de integridade detectada.",
	UPVALUE_DEPTH = 2,
	MAX_UPVALUES = 128,
	MAX_FINGERPRINTS = 8192,
	GUARD_S = true,
	GUARD_F = true,
}

local State = {
	ready = false,
	passed = false,
	watching = false,
	hooked = false,
	kicked = false,
	generation = 0,
	violations = 0,
	lastFailure = nil,
	lastViolation = nil,
}

local Owned = setmetatable({}, { __mode = "k" })
local realInfo = nil

-- env
local function getEnvironment()
	if type(getgenv) ~= "function" then return nil end
	local ok, environment = pcall(getgenv); return ok and type(environment) == "table" and environment or nil
end
local function getRequest()
	local environment = getEnvironment(); local synApi = environment and type(environment.syn) == "table" and environment.syn or nil
	local fluxusApi = environment and type(environment.fluxus) == "table" and environment.fluxus or nil
	for _, candidate in ipairs({
		environment and environment.request,
		environment and environment.http_request,
		synApi and synApi.request,
		fluxusApi and fluxusApi.request,
	}) do
		if type(candidate) == "function" then return candidate end
	end
	return nil
end

-- report
local function recordError(reason)
	if Utils and type(Utils.recordError) == "function" then pcall(Utils.recordError, "AntiTamper", reason) end
end
local function fail(reason)
	State.passed = false; State.lastFailure = reason; recordError(reason); return false, reason
end
local function kick()
	if State.kicked then return end
	State.kicked = true
	local ok, player = pcall(function()
		return Utils and type(Utils.getLocalPlayer) == "function" and Utils.getLocalPlayer() or nil
	end)
	if ok and player and type(player.Kick) == "function" then
		pcall(function() player:Kick(T.KICK_MESSAGE) end)
	end
end
local function violation(reason)
	State.violations += 1; State.lastViolation = reason; State.passed = false; recordError(reason)
	kick()
end

-- fingerprint
local function own(fn)
	if type(fn) ~= "function" then return false end
	if Owned[fn] then return true end
	if State.fingerprints >= T.MAX_FINGERPRINTS then return false end
	Owned[fn] = true; State.fingerprints = (State.fingerprints or 0) + 1; return true
end
local function collectUpvalues(fn, depth)
	if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return end
	if depth >= T.UPVALUE_DEPTH then return end
	pcall(function()
		local index = 1
		while index <= T.MAX_UPVALUES do
			local name, value = debug.getupvalue(fn, index)
			if not name then break end
			if type(value) == "function" then own(value) end
			index += 1
		end
	end)
end
local function fingerprint()
	local roots = {}
	if type(_G.ExodusModules) == "table" then roots[#roots + 1] = _G.ExodusModules end
	if type(_G.Exodus) == "table" and type(_G.Exodus.Modules) == "table" then roots[#roots + 1] = _G.Exodus.Modules end
	for _, root in ipairs(roots) do
		for _, module in pairs(root) do
			if type(module) == "table" then
				for _, fn in pairs(module) do
					if own(fn) then collectUpvalues(fn, 0) end
				end
			end
		end
	end
end

-- guard
local function decoy(field)
	if field == "s" then return "" end
	if field == "f" then return "=[Exodus]" end
	return ""
end
local function guardedInfo(...)
	local target, field = ...
	if Owned[target] == true then
		if (field == "s" and T.GUARD_S) or (field == "f" and T.GUARD_F) then violation(("leitura de codigo via debug.info('%s')"):format(tostring(field))); return decoy(field) end
	end
	return realInfo(...)
end
local function hookDebug()
	if type(debug) ~= "table" or type(debug.info) ~= "function" then return false end
	if not realInfo then realInfo = debug.info end
	local ok = pcall(function() debug.info = guardedInfo end)
	State.hooked = ok and debug.info == guardedInfo; return State.hooked
end

-- watchdog
local function watch()
	State.watching = true; State.generation += 1; local generation = State.generation
	task.spawn(function()
		while State.watching and generation == State.generation do
			if not State.hooked then hookDebug() end
			pcall(fingerprint); task.wait(T.INTERVAL)
		end
	end)
end

-- run
local function run()
	if type(loadstring) ~= "function" then return fail("loadstring indisponível") end
	if type(getRequest()) ~= "function" then return fail("request indisponível") end
	local okCompile, chunk = pcall(loadstring, "return true", "ExodusIntegrity")
	if not okCompile or type(chunk) ~= "function" then return fail("compilação de integridade falhou") end
	local okRun, result = pcall(chunk)
	if not okRun or result ~= true then return fail("execução de integridade falhou") end
	hookDebug(); watch(); State.passed = true; State.lastFailure = nil
	return true
end

-- api
function AntiTamper.setup(deps)
	if type(deps) ~= "table" or type(deps.Utils) ~= "table" then return false, "dependência ausente: Utils" end
	Utils = deps.Utils; State.ready = true; State.fingerprints = 0; return run()
end
function AntiTamper.teardown()
	State.ready = false; State.passed = false; State.watching = false; State.generation += 1
	State.hooked = false; State.violations = 0; State.kicked = false; State.lastViolation = nil
	for key in pairs(Owned) do Owned[key] = nil end
	Utils = nil
end
function AntiTamper.isPassed()
	return State.ready == true and State.passed == true
end
function AntiTamper.getStatus()
	return {
		schema = Utils and Utils.apiVersion and Utils.apiVersion() or 1,
		ready = State.ready,
		passed = State.passed,
		hooked = State.hooked,
		kicked = State.kicked,
		violations = State.violations,
		lastViolation = State.lastViolation,
		fingerprints = State.fingerprints or 0,
		lastFailure = State.lastFailure,
	}

end
AntiTamper.__contract = {
	requires = { Utils = "utils" },
}

return AntiTamper
