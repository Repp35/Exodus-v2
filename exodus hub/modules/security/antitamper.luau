--!strict
--!optimize 2
-- [[ antitamper ]]

-- Helpers
local AntiTamper = {}
local PCall = pcall
local Type = type
local ToString = tostring
local RawGet = rawget
local RawEqual = rawequal
local Next = next
local GlobalEnv = _G
local DebugTable = debug
local DebugInfo = Type(DebugTable) == "table" and DebugTable.info or nil
local DebugGetUpvalue = Type(DebugTable) == "table" and DebugTable.getupvalue or nil
local TaskTable = task
local TaskSpawn = Type(TaskTable) == "table" and TaskTable.spawn or nil
local TaskWait = Type(TaskTable) == "table" and TaskTable.wait or nil
local GetGenv = rawget(GlobalEnv, "getgenv")
local Freeze = (Type(table) == "table" and Type(table.freeze) == "function" and table.freeze)
	or function(value) return value end

-- Environment
local T = Freeze({
	INTERVAL = 0.5,
	KICK_MESSAGE = "Exodus: violacao de integridade detectada.",
	TABLE_DEPTH = 4,
	UPVALUE_DEPTH = 3,
	MAX_UPVALUES = 128,
	MAX_FUNCTIONS = 8192,
	MAX_TABLES = 4096,
	REQUIRE_DEBUG_INFO = true,
	CHECK_UPVALUES = false,
	CHECK_UPVALUE_TYPES = false,
	KICK_AFTER = 1,
	WATCHDOGS = 2,
})

local State = {
	ready = false,
	passed = false,
	watching = false,
	kicked = false,
	generation = 0,
	violations = 0,
	fingerprints = 0,
	tables = 0,
	lastFailure = nil,
	lastViolation = nil,
}

local Utils
local UtilsGetLocalPlayer
local UtilsApiVersion
local LocalPlayer
local LocalPlayerKick
local Baseline = nil

-- Roots
local function safeCall(fn, ...)
	if Type(fn) ~= "function" then return false, nil end
	return PCall(fn, ...)
end
local function sameValue(a, b)
	if a == b then return true end
	if Type(a) == "number" and Type(b) == "number" then return a ~= a and b ~= b end
	return RawEqual(a, b)
end
local function valueKind(value) return Type(value) end
local function formatKey(key)
	local ok, result = PCall(ToString, key)
	if ok then return result end
	return "<unknown>"
end

-- Watchdog
local function getEnvironment()
	if Type(GetGenv) ~= "function" then return nil end
	local ok, environment = PCall(GetGenv)
	if not ok or Type(environment) ~= "table" then return nil end
	return environment
end

-- Run
-- API
local function fail(reason)
	State.passed = false; State.lastFailure = reason; return false, reason
end
local function kick()
	if State.kicked then return end
	State.kicked = true; State.watching = false
	if not LocalPlayer or Type(LocalPlayerKick) ~= "function" then return end
	PCall(LocalPlayerKick, LocalPlayer, T.KICK_MESSAGE)
end
local function violation(reason)
	if State.kicked then return end
	State.violations += 1; State.lastViolation = reason; State.passed = false; State.watching = false
	if State.violations >= T.KICK_AFTER then kick() end
end
local function getRoots()
	local roots = {}; local seen = {}
	local function add(name, value)
		if Type(value) ~= "table" then return end
		if seen[value] then return end
		seen[value] = true
		roots[#roots + 1] = {
			name = name,
			value = value,
		}

	end
	local exodusModules = RawGet(GlobalEnv, "ExodusModules"); add("ExodusModules", exodusModules); local exodus = RawGet(GlobalEnv, "Exodus")
	if Type(exodus) == "table" then add("Exodus.Modules", RawGet(exodus, "Modules")) end
	return roots
end
local function getFunctionInfo(fn)
	if Type(DebugInfo) ~= "function" then return nil end
	local ok, source, line, name, argc, variadic = PCall(DebugInfo, fn, "slna")
	if not ok then return nil end
	return {
		source = source,
		line = line,
		name = name,
		argc = argc,
		variadic = variadic,
	}
end
local function sameFunctionInfo(a, b)
	if not a or not b then return true end
	return a.source == b.source
		and a.line == b.line
		and a.name == b.name
		and a.argc == b.argc
		and a.variadic == b.variadic
end
local function snapshotFunction(fn, baseline, seen, depth)
	if Type(fn) ~= "function" then return true end
	if seen[fn] then return true end
	if #baseline.functions >= T.MAX_FUNCTIONS then return false, "limite de fingerprints atingido" end
	seen[fn] = true
	local entry = {
		fn = fn,
		info = getFunctionInfo(fn),
		upvalues = {},
	}

	baseline.functions[#baseline.functions + 1] = entry
	if not T.CHECK_UPVALUES then return true end
	if Type(DebugGetUpvalue) ~= "function" then return true end
	for index = 1, T.MAX_UPVALUES do
		local ok, name, value = PCall(DebugGetUpvalue, fn, index)
		if not ok then break end
		if not name then break end
		local kind = valueKind(value)
		local upvalue = {
			index = index,
			name = name,
			kind = kind,
			reference = (kind == "function" or kind == "table" or kind == "thread" or kind == "userdata") and value
				or nil,
		}

		entry.upvalues[#entry.upvalues + 1] = upvalue
		if depth < T.UPVALUE_DEPTH and kind == "function" then
			local okNested, err = snapshotFunction(value, baseline, seen, depth + 1)
			if not okNested then return false, err end
		end
	end
	return true
end
local function snapshotTable(tbl, baseline, seenTables, seenFunctions, depth, path)
	if Type(tbl) ~= "table" then return true end
	if seenTables[tbl] then return true end
	if #baseline.tables >= T.MAX_TABLES then return false, "limite de tabelas monitoradas atingido" end
	seenTables[tbl] = true
	for key, value in Next, tbl do
		local currentPath = path .. "[" .. formatKey(key) .. "]"; local kind = Type(value)
		if kind == "table" then
			baseline.tableEdges[#baseline.tableEdges + 1] = {
				owner = tbl,
				key = key,
				value = value,
				path = currentPath,
			}
			local ok, err = snapshotTable(value, baseline, seenTables, seenFunctions, depth + 1, currentPath)
			if not ok then return false, err end
		elseif kind == "function" then
			baseline.functionEdges[#baseline.functionEdges + 1] = {
				owner = tbl,
				key = key,
				fn = value,
				path = currentPath,
			}
			local ok, err = snapshotFunction(value, baseline, seenFunctions, 0)
			if not ok then return false, err end
		end
		if #baseline.functions >= T.MAX_FUNCTIONS then return false, "limite de fingerprints atingido" end
	end
	return true
end
local function buildBaseline()
	local roots = getRoots()
	if #roots == 0 then return nil, "nenhum root do Exodus encontrado" end
	local baseline = {
		roots = {},
		tables = {},
		tableEdges = {},
		functionEdges = {},
		functions = {},
	}

	local seenTables = {}; local seenFunctions = {}
	for _, root in ipairs(roots) do
		baseline.roots[#baseline.roots + 1] = {
			owner = GlobalEnv,
			key = root.name,
			value = root.value,
			path = root.name,
		}

		local ok, err = snapshotTable(root.value, baseline, seenTables, seenFunctions, 0, root.name)
		if not ok then return nil, err end
	end
	if #baseline.functions == 0 then return nil, "nenhuma funcao encontrada para fingerprint" end
	return baseline
end
local function verifyRoots()
	for _, entry in ipairs(Baseline.roots) do
		local current = RawGet(entry.owner, entry.key)
		if not RawEqual(current, entry.value) then return false, ("root alterado: %s"):format(entry.path) end
	end
	return true
end
local function verifyTables()
	for _, entry in ipairs(Baseline.tableEdges) do
		local current = RawGet(entry.owner, entry.key)
		if not RawEqual(current, entry.value) then return false, ("tabela alterada: %s"):format(entry.path) end
	end
	return true
end
local function verifyFunctionEdges()
	for _, entry in ipairs(Baseline.functionEdges) do
		local current = RawGet(entry.owner, entry.key)
		if not RawEqual(current, entry.fn) then return false, ("funcao substituida: %s"):format(entry.path) end
	end
	return true
end
local function verifyFunctions()
	for _, entry in ipairs(Baseline.functions) do
		local fn = entry.fn
		if Type(fn) ~= "function" then return false, "fingerprint perdeu referencia de funcao" end
		if DebugInfo and entry.info then
			local currentInfo = getFunctionInfo(fn)
			if currentInfo and not sameFunctionInfo(entry.info, currentInfo) then return false, "metadados de funcao alterados" end
		end

		-- upvalues
		if T.CHECK_UPVALUES and Type(DebugGetUpvalue) == "function" then
			for _, saved in ipairs(entry.upvalues) do
				local ok, name, value = PCall(DebugGetUpvalue, fn, saved.index)
				if not ok then break end
				if name ~= saved.name then return false, ("upvalue renomeado: %s"):format(saved.name) end
				if saved.reference ~= nil then
					if not RawEqual(value, saved.reference) then return false, ("referencia de upvalue alterada: %s"):format(saved.name) end
				elseif T.CHECK_UPVALUE_TYPES then
					if Type(value) ~= saved.kind then return false, ("tipo de upvalue alterado: %s"):format(saved.name) end
				end
			end
		end
	end
	return true
end
local function verifyRuntimeAPIs()
	if Type(debug) ~= "table" or not RawEqual(debug, DebugTable) then return false, "tabela debug alterada" end
	if Type(DebugInfo) == "function" then
		if debug.info ~= DebugInfo then return false, "debug.info alterado" end
	end
	if Type(task) ~= "table" or not RawEqual(task, TaskTable) then return false, "tabela task alterada" end
	if Type(TaskSpawn) == "function" and task.spawn ~= TaskSpawn then return false, "task.spawn alterado" end
	if Type(TaskWait) == "function" and task.wait ~= TaskWait then return false, "task.wait alterado" end
	return true
end
local function verify()
	if not Baseline then return false, "baseline inexistente" end
	local ok, reason = verifyRuntimeAPIs()
	if not ok then return false, reason end
	ok, reason = verifyRoots()
	if not ok then return false, reason end
	ok, reason = verifyTables()
	if not ok then return false, reason end
	ok, reason = verifyFunctionEdges()
	if not ok then return false, reason end
	ok, reason = verifyFunctions()
	if not ok then return false, reason end
	return true
end
local function startWatchdog(delayTime)
	local generation = State.generation
	TaskSpawn(function()
		if delayTime > 0 then TaskWait(delayTime) end
		while State.watching and generation == State.generation do
			local ok, passed, reason = PCall(verify)
			if not ok then violation("erro interno do watchdog"); break end
			if not passed then violation(reason or "falha de integridade"); break end
			TaskWait(T.INTERVAL)
		end
	end)
end
local function watch()
	if Type(TaskSpawn) ~= "function" or Type(TaskWait) ~= "function" then return fail("task.spawn/task.wait indisponivel") end
	State.watching = true; State.generation += 1
	for index = 1, T.WATCHDOGS do
		startWatchdog((index - 1) * (T.INTERVAL / T.WATCHDOGS))
	end
end
local function run()
	if T.REQUIRE_DEBUG_INFO and Type(DebugInfo) ~= "function" then return fail("debug.info indisponivel") end
	if Type(TaskSpawn) ~= "function" or Type(TaskWait) ~= "function" then return fail("task API indisponivel") end
	local baseline, reason = buildBaseline()
	if not baseline then return fail(reason) end
	Baseline = baseline; State.fingerprints = #baseline.functions; State.tables = #baseline.tables; local ok, verifyReason = verify()
	if not ok then return fail(verifyReason) end
	State.passed = true; State.lastFailure = nil; watch(); return true
end
function AntiTamper.setup(_)
	State.ready = true; State.passed = true; State.kicked = false; State.watching = false
	State.generation += 1; State.violations = 0; State.fingerprints = 0; State.tables = 0
	State.lastFailure = nil; State.lastViolation = nil; Baseline = nil
	return true
end
function AntiTamper.teardown()
	State.ready = false; State.passed = false; State.watching = false; State.kicked = false
	State.generation += 1; State.violations = 0; State.fingerprints = 0; State.tables = 0
	State.lastFailure = nil; State.lastViolation = nil; Baseline = nil; LocalPlayer = nil
	LocalPlayerKick = nil; UtilsGetLocalPlayer = nil; UtilsApiVersion = nil
	Utils = nil
end
function AntiTamper.isPassed() return State.ready == true and State.passed == true and State.kicked == false end
function AntiTamper.getStatus()
	local schema = 1
	if Type(UtilsApiVersion) == "function" then
		local ok, result = PCall(UtilsApiVersion)
		if ok then schema = result or 1 end
	end
	return {
		schema = schema,
		ready = State.ready,
		passed = State.passed,
		watching = State.watching,
		kicked = State.kicked,
		violations = State.violations,
		fingerprints = State.fingerprints,
		tables = State.tables,
		lastViolation = State.lastViolation,
		lastFailure = State.lastFailure,
		generation = State.generation,
	}
end
AntiTamper.__contract = {
	requires = {
		Utils = "utils",
	},

}

return AntiTamper
