-- [[ antitamper ]]

local AntiTamper = {}
local PCall, Type, RawGet, RawEqual = pcall, type, rawget, rawequal
local Debug = debug
local DebugInfo = Type(Debug) == "table" and Debug.info or nil
local Task = task
local Spawn = Type(Task) == "table" and Task.spawn or nil
local Wait = Type(Task) == "table" and Task.wait or nil

local T = {
    INTERVAL = 0.5,
    KICK_MESSAGE = "Exodus: violacao de integridade detectada.",
    UPVALUE_DEPTH = 3,
    MAX_UPVALUES = 128,
    MAX_FUNCTIONS = 8192,
    MAX_TABLES = 4096,
    REQUIRE_DEBUG_INFO = true,
    CHECK_UPVALUES = false,
    CHECK_UPVALUE_TYPES = false,
    KICK_AFTER = 1,
    WATCHDOGS = 2,
}

if Type(table.freeze) == "function" then table.freeze(T) end

local state = {
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

local Utils, getApiVersion, localPlayer, kickMethod
local baseline

local function failure(reason)
    state.passed = false
    state.lastFailure = reason
    return false, reason
end

local function kick()
    if state.kicked then return end
    state.kicked, state.watching = true, false
    state.generation += 1
    -- Integrity failures stop the watchdog but never disconnect the player.
end

local function violation(reason)
    if state.kicked then return end
    state.violations += 1
    state.lastViolation = reason
    state.passed, state.watching = false, false
    if state.violations >= T.KICK_AFTER then kick() end
end

local function functionInfo(fn)
    if Type(DebugInfo) ~= "function" then return nil end
    local ok, source, line, name, argc, variadic = PCall(DebugInfo, fn, "slna")
    if not ok then return nil end
    return {source, line, name, argc, variadic}
end

local function sameInfo(first, second)
    if not first or not second then return true end
    for index = 1, 5 do
        if first[index] ~= second[index] then return false end
    end
    return true
end

local function roots()
    local results, seen = {}, {}
    local function add(name, owner, key)
        local value = RawGet(owner, key)
        if Type(value) ~= "table" or seen[value] then return end
        seen[value] = true
        results[#results + 1] = {owner = owner, key = key, value = value, path = name}
    end
    add("ExodusModules", _G, "ExodusModules")
    local exodus = RawGet(_G, "Exodus")
    if Type(exodus) == "table" then add("Exodus.Modules", exodus, "Modules") end
    return results
end

local function snapshot()
    local found = roots()
    if #found == 0 then return nil, "nenhum root do Exodus encontrado" end

    local result = {roots = found, tables = {}, tableEdges = {}, functionEdges = {}, functions = {}}
    local seenTables, seenFunctions = {}, {}

    local function addFunction(fn)
        if seenFunctions[fn] then return true end
        if #result.functions >= T.MAX_FUNCTIONS then
            return false, "limite de fingerprints atingido"
        end
        seenFunctions[fn] = true
        result.functions[#result.functions + 1] = {fn = fn, info = functionInfo(fn)}
        return true
    end

    local function visit(owner, path)
        if seenTables[owner] then return true end
        if #result.tables >= T.MAX_TABLES then
            return false, "limite de tabelas monitoradas atingido"
        end

        seenTables[owner] = true
        result.tables[#result.tables + 1] = owner

        for key, value in next, owner do
            local ok, label = PCall(tostring, key)
            local childPath = path .. "[" .. (ok and label or "<unknown>") .. "]"

            if Type(value) == "table" then
                result.tableEdges[#result.tableEdges + 1] = {
                    owner = owner, key = key, value = value, path = childPath,
                }
                local valid, err = visit(value, childPath)
                if not valid then return false, err end
            elseif Type(value) == "function" then
                result.functionEdges[#result.functionEdges + 1] = {
                    owner = owner, key = key, fn = value, path = childPath,
                }
                local valid, err = addFunction(value)
                if not valid then return false, err end
            end

            if #result.functions >= T.MAX_FUNCTIONS then
                return false, "limite de fingerprints atingido"
            end
        end
        return true
    end

    for _, root in ipairs(found) do
        local ok, err = visit(root.value, root.path)
        if not ok then return nil, err end
    end

    if #result.functions == 0 then
        return nil, "nenhuma funcao encontrada para fingerprint"
    end
    return result
end

local function verify()
    if not baseline then return false, "baseline inexistente" end
    if Type(debug) ~= "table" or not RawEqual(debug, Debug) then
        return false, "tabela debug alterada"
    end
    if Type(DebugInfo) == "function" and debug.info ~= DebugInfo then
        return false, "debug.info alterado"
    end
    if Type(task) ~= "table" or not RawEqual(task, Task) then
        return false, "tabela task alterada"
    end
    if Type(Spawn) == "function" and task.spawn ~= Spawn then
        return false, "task.spawn alterado"
    end
    if Type(Wait) == "function" and task.wait ~= Wait then
        return false, "task.wait alterado"
    end

    for _, edge in ipairs(baseline.roots) do
        if not RawEqual(RawGet(edge.owner, edge.key), edge.value) then
            return false, "root alterado: " .. edge.path
        end
    end
    for _, edge in ipairs(baseline.tableEdges) do
        if not RawEqual(RawGet(edge.owner, edge.key), edge.value) then
            return false, "tabela alterada: " .. edge.path
        end
    end
    for _, edge in ipairs(baseline.functionEdges) do
        if not RawEqual(RawGet(edge.owner, edge.key), edge.fn) then
            return false, "funcao substituida: " .. edge.path
        end
    end
    for _, entry in ipairs(baseline.functions) do
        if Type(entry.fn) ~= "function" then
            return false, "fingerprint perdeu referencia de funcao"
        end
        if entry.info and not sameInfo(entry.info, functionInfo(entry.fn)) then
            return false, "metadados de funcao alterados"
        end
    end
    return true
end

local function watchdog(offset)
    local token = state.generation
    Spawn(function()
        if offset > 0 then Wait(offset) end
        while state.watching and token == state.generation do
            local ok, passed, reason = PCall(verify)
            if not ok then
                violation("erro interno do watchdog")
                break
            end
            if not passed then
                violation(reason or "falha de integridade")
                break
            end
            Wait(T.INTERVAL)
        end
    end)
end

local function start()
    if T.REQUIRE_DEBUG_INFO and Type(DebugInfo) ~= "function" then
        return failure("debug.info indisponivel")
    end
    if Type(Spawn) ~= "function" or Type(Wait) ~= "function" then
        return failure("task API indisponivel")
    end

    local built, err = snapshot()
    if not built then return failure(err) end
    baseline = built
    state.fingerprints = #baseline.functions
    state.tables = #baseline.tables

    local valid, reason = verify()
    if not valid then return failure(reason) end

    state.passed = true
    state.lastFailure = nil
    state.watching = true
    state.generation += 1
    for index = 1, T.WATCHDOGS do
        watchdog((index - 1) * T.INTERVAL / T.WATCHDOGS)
    end
    return true
end

function AntiTamper.setup(deps)
    if Type(deps) ~= "table" or Type(deps.Utils) ~= "table" then
        return false, "dependência ausente: Utils"
    end
    if Type(deps.Utils.getLocalPlayer) ~= "function"
        or Type(deps.Utils.apiVersion) ~= "function" then
        return false, "dependência ausente: Utils.getLocalPlayer/apiVersion"
    end

    Utils, getApiVersion = deps.Utils, deps.Utils.apiVersion
    local ok, player = PCall(Utils.getLocalPlayer)
    if not ok or not player then return false, "Players.LocalPlayer indisponível" end

    local kickOk, method = PCall(function() return player.Kick end)
    if not kickOk or Type(method) ~= "function" then
        return false, "LocalPlayer.Kick indisponível"
    end

    localPlayer, kickMethod = player, method
    state.ready = true
    state.passed, state.watching, state.kicked = false, false, false
    state.generation += 1
    state.violations, state.fingerprints, state.tables = 0, 0, 0
    state.lastFailure, state.lastViolation = nil, nil
    baseline = nil

    local passed, reason = start()
    if not passed then state.ready = false end
    return passed, reason
end

function AntiTamper.teardown()
    state.ready, state.passed, state.watching, state.kicked = false, false, false, false
    state.generation += 1
    state.violations, state.fingerprints, state.tables = 0, 0, 0
    state.lastFailure, state.lastViolation = nil, nil
    baseline, Utils, getApiVersion, localPlayer, kickMethod = nil, nil, nil, nil, nil
end

function AntiTamper.isPassed()
    return state.ready and state.passed and not state.kicked
end

function AntiTamper.getStatus()
    local schema = 1
    if Type(getApiVersion) == "function" then
        local ok, value = PCall(getApiVersion)
        if ok then schema = value or 1 end
    end
    return {
        schema = schema,
        ready = state.ready,
        passed = state.passed,
        watching = state.watching,
        kicked = state.kicked,
        violations = state.violations,
        fingerprints = state.fingerprints,
        tables = state.tables,
        lastViolation = state.lastViolation,
        lastFailure = state.lastFailure,
        generation = state.generation,
    }
end

AntiTamper.__contract = {
    requires = {Utils = "utils"},
    requiresMethods = {Utils = {"getLocalPlayer", "apiVersion"}},
    provides = {"setup", "teardown", "isPassed"},
}

return AntiTamper
