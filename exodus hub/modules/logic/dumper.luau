-- [[ dumper ]]

-- module
local Dumper = {}
local activeToken
local activeCallbacks
local status = {
  running = false,
  startedAt = 0,
  folder = nil,
  total = 0,
  processed = 0,
  saved = 0,
  failed = 0,
  bytecode = 0,
}

-- configuration
local CONFIG = {
  PREFIX = "SrcDump",
  YIELD_EVERY = 50,
  PROGRESS_EVERY = 25,
  SAVE_BYTECODE = true,
  SAVE_DISASSEMBLY = true,
  INCLUDE_NIL_INSTANCES = true,
  MAX_SOURCE_BYTES = 4_000_000,
}

local SCRIPT_CLASSES = {
  Script = true,
  LocalScript = true,
  ModuleScript = true,
}

local REMOTE_CLASSES = {
  RemoteEvent = true,
  RemoteFunction = true,
  UnreliableRemoteEvent = true,
  BindableEvent = true,
  BindableFunction = true,
}

local SYSTEM_NAMES = {
  CoreGui = true,
  CorePackages = true,
  RobloxGui = true,
  RobloxReplicatedStorage = true,
  CoreScripts = true,
  RobloxDefault = true,
  RobloxPlayerScript = true,
}

-- helpers
local function emit(callbacks, name, ...)
  local callback = callbacks and callbacks[name]
  if type(callback) == "function" then pcall(callback, ...) end
end
local function yieldIfNeeded(index)
  if index % CONFIG.YIELD_EVERY == 0 then task.wait() end
end
local function line(value) return tostring(value):gsub("[\r\n]", " ") end
local function safeProperty(object, key, fallback)
  local ok, value = pcall(function() return object[key] end)
  return ok and value ~= nil and value or fallback
end
local function objectName(object) return tostring(safeProperty(object, "Name", "Unnamed")) end
local function objectClass(object) return tostring(safeProperty(object, "ClassName", "Unknown")) end
local function objectPath(object)
  local ok, value = pcall(function() return object:GetFullName() end)
  return ok and value or objectName(object)
end
local function isInstance(object) return typeof(object) == "Instance" end
local function safeFilename(value)
  local result = tostring(value):gsub("[^%w%._%-]", "_"):gsub("_+", "_"):sub(1, 110); return result ~= "" and result or "unnamed"
end
local function getEnvironment()
  if type(getfenv) == "function" then
    local ok, environment = pcall(getfenv)
    if ok and type(environment) == "table" then return environment end
  end
  if type(getgenv) == "function" then
    local ok, environment = pcall(getgenv)
    if ok and type(environment) == "table" then return environment end
  end
  return type(_G) == "table" and _G or {}
end
local function lookup(name)
  local environment = getEnvironment(); local value = environment[name]
  if type(value) == "function" then return value end
  if type(_G) == "table" and type(_G[name]) == "function" then return _G[name] end
  return nil
end
local function ensureFolder(path)
  if type(isfolder) == "function" then
    local ok, exists = pcall(isfolder, path)
    if ok and exists then return true end
  end
  if type(makefolder) ~= "function" then return false, "makefolder is unavailable" end
  local ok, err = pcall(makefolder, path)
  if ok then return true end
  if type(isfolder) == "function" then
    local checked, exists = pcall(isfolder, path)
    if checked and exists then return true end
  end
  return false, tostring(err)
end
local function saveFile(path, content)
  if type(writefile) ~= "function" then return false, "writefile is unavailable" end
  local ok, err = pcall(writefile, path, content); return ok, ok and nil or tostring(err)
end
local function allowed(object, allowDetached)
  if not isInstance(object) then return false end
  local current = object
  for _ = 1, 200 do
    if current == game then return true end
    if SYSTEM_NAMES[objectName(current)] then return false end
    local parent = safeProperty(current, "Parent")
    if not isInstance(parent) then return allowDetached == true end
    current = parent
  end
  return false
end
local function serialize(value)
  if type(value) == "string" then return string.format("%q", value) end
  local ok, result = pcall(tostring, value); return ok and line(result) or "<unavailable>"
end
local function attributes(object)
  local ok, values = pcall(function() return object:GetAttributes() end)
  if not ok or type(values) ~= "table" then return "{}" end
  local result = {}
  for key, value in pairs(values) do
    result[#result + 1] = line(key) .. "=" .. serialize(value)
  end
  table.sort(result); return "{" .. table.concat(result, ", ") .. "}"
end
local function tags(object, collection)
  if not collection then return "[]" end
  local ok, values = pcall(function() return collection:GetTags(object) end)
  if not ok or type(values) ~= "table" then return "[]" end
  table.sort(values); return "[" .. table.concat(values, ", ") .. "]"
end
local function errorText(value)
  local text = type(value) == "string" and value or ("returned " .. type(value)); return line(text)
end
local SOURCE_ERRORS = {
  "failed to get script bytecode",
  "failed to get bytecode",
  "failed to decompile",
  "failed to extract",
  "decompilation failed",
  "decompiler error",
  "decompiler timed out",
  "script has no bytecode",
  "no bytecode available",
  "empty bytecode",
  "server scripts are impossible",
  "invalid argument",
  "server error",
  "decompilation error",
}

local function sourceError(value)
  local lower = tostring(value):lower():gsub("^%s*%-%-%[%[", ""):gsub("^%s*%-%-+%s*", ""):gsub("^%s+", "")
  for _, phrase in ipairs(SOURCE_ERRORS) do
    if lower:sub(1, #phrase) == phrase then return line(value) end
  end
  return nil
end
local function nextFolder()
  local base = CONFIG.PREFIX .. "_" .. tostring(game.PlaceId) .. "_" .. tostring(os.time())
  if type(isfolder) ~= "function" then return base end
  local candidate, index = base, 1
  while true do
    local ok, exists = pcall(isfolder, candidate)
    if not ok or not exists then return candidate end
    index += 1; candidate = base .. "_" .. index
  end
end
local function addDiscovery(api, catalog, candidates, seen, errors, token)
  local ok, values = pcall(api)
  if not ok or type(values) ~= "table" then errors[#errors + 1] = "discovery failed: " .. errorText(values); return end
  for _, object in pairs(values) do
    if token.cancelled then return end
    if allowed(object, CONFIG.INCLUDE_NIL_INSTANCES) and not seen[object] then
      seen[object] = true; local item = { instance = object, path = objectPath(object), origin = "executor" }
      catalog[#catalog + 1] = item
      if SCRIPT_CLASSES[objectClass(object)] then candidates[#candidates + 1] = item end
    end
  end
end

-- dump
local function run(token, callbacks)
  if type(writefile) ~= "function" or type(makefolder) ~= "function" then return nil, "writefile and makefolder are required" end
  local base = nextFolder()
  for _, path in ipairs({ base, base .. "/scripts", base .. "/remotes" }) do
    local ok, err = ensureFolder(path)
    if not ok then return nil, "cannot create " .. path .. ": " .. tostring(err) end
  end
  if CONFIG.SAVE_BYTECODE then
    local ok, err = ensureFolder(base .. "/bytecode")
    if not ok then return nil, "cannot create bytecode folder: " .. tostring(err) end
  end
  if CONFIG.SAVE_DISASSEMBLY then
    local ok, err = ensureFolder(base .. "/disassembly")
    if not ok then return nil, "cannot create disassembly folder: " .. tostring(err) end
  end
  emit(callbacks, "onStatus", "Collecting instances..."); local catalog, candidates, seen, discoveryErrors = {}, {}, {}, {}
  local function add(object, origin, detached)
    if not allowed(object, detached) or seen[object] then return end
    seen[object] = true; local item = { instance = object, path = objectPath(object), origin = origin }
    catalog[#catalog + 1] = item
    if SCRIPT_CLASSES[objectClass(object)] then candidates[#candidates + 1] = item end
  end
  add(game, "game", false)
  local ok, descendants = pcall(function() return game:GetDescendants() end)
  if ok then
    for index, object in ipairs(descendants) do
      if token.cancelled then return nil, "Dump canceled" end
      add(object, "game:GetDescendants", false); yieldIfNeeded(index)
    end
  else
    discoveryErrors[#discoveryErrors + 1] = "game:GetDescendants: " .. errorText(descendants)
  end
  for _, name in ipairs({ "getinstances", "getnilinstances", "getloadedmodules" }) do
    local api = lookup(name)
    if api then addDiscovery(api, catalog, candidates, seen, discoveryErrors, token) end
  end
  for _, name in ipairs({ "gethui", "get_hidden_gui" }) do
    local api = lookup(name)
    if api then
      local success, hiddenGui = pcall(api)
      if success then
        add(hiddenGui, name, true)
        local descendantsOk, descendants = pcall(function() return hiddenGui:GetDescendants() end)
        if descendantsOk then
          for index, object in ipairs(descendants) do
            add(object, name .. ":GetDescendants", true); yieldIfNeeded(index)
          end
        end
      else
        discoveryErrors[#discoveryErrors + 1] = name .. ": " .. errorText(hiddenGui)
      end
    end
  end
  status.total = #candidates
  local collection
  pcall(function() collection = game:GetService("CollectionService") end)
  local tree = { "SrcDump - instances", "total=" .. #catalog, "" }; local remotes = { "SrcDump - remotes and bindables", "" }
  local remoteCount = 0
  for index, item in ipairs(catalog) do
    if token.cancelled then return nil, "Dump canceled" end
    local object = item.instance
    local detail = ("[%s] %s | discovered=%s | attributes=%s | tags=%s"):format(
      objectClass(object),
      line(item.path),
      item.origin,
      attributes(object),
      tags(object, collection)
    )
    tree[#tree + 1] = detail
    if REMOTE_CLASSES[objectClass(object)] then remoteCount += 1; remotes[#remotes + 1] = detail end
    yieldIfNeeded(index)
  end
  remotes[2] = "total=" .. remoteCount; local treeOk, treeError = saveFile(base .. "/tree.txt", table.concat(tree, "\n") .. "\n")
  if not treeOk then return nil, "cannot save tree.txt: " .. tostring(treeError) end
  local remoteOk, remoteError = saveFile(base .. "/remotes/remotes.txt", table.concat(remotes, "\n") .. "\n")
  if not remoteOk then return nil, "cannot save remotes.txt: " .. tostring(remoteError) end
  local info = {
    "SrcDump - game information",
    "place_id=" .. tostring(game.PlaceId),
    "game_id=" .. tostring(game.GameId),
    "job_id=" .. tostring(game.JobId),
    "game_name=" .. line(game.Name),
    "creator_id=" .. tostring(game.CreatorId),
    "creator_type=" .. tostring(game.CreatorType),
    "place_version=" .. tostring(game.PlaceVersion),
    "instances=" .. #catalog,
    "scripts=" .. #candidates,
    "remotes=" .. remoteCount,
  }

  local productOk, product = pcall(function() return game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId) end)
  info[#info + 1] = "product_name=" .. (productOk and type(product) == "table" and line(product.Name) or "unavailable")
  local infoOk, infoError = saveFile(base .. "/game_info.txt", table.concat(info, "\n") .. "\n")
  if not infoOk then return nil, "cannot save game_info.txt: " .. tostring(infoError) end
  local decompiler, disassembler = lookup("decompile"), lookup("disassemble"); local closureReaders, readers = {}, {}
  for _, name in ipairs({ "getscriptclosure", "getscriptfunction" }) do
    local fn = lookup(name)
    if fn then closureReaders[#closureReaders + 1] = { name = name, fn = fn } end
  end
  for _, name in ipairs({ "getscriptbytecode", "dumpstring" }) do
    local fn = lookup(name)
    if fn then readers[#readers + 1] = { name = name, fn = fn } end
  end
  local manifest, errors = {}, discoveryErrors; local saved, failed, bytecodes = 0, 0, 0
  for index, item in ipairs(candidates) do
    if token.cancelled then return nil, "Dump canceled" end
    local object, attempts = item.instance, {}
    local source, method, bytecode, closure
    local function attempt(label, fn, argument, validateSource)
      local success, value = pcall(fn, argument)
      if not success then attempts[#attempts + 1] = label .. ": error: " .. errorText(value); return nil end
      if type(value) ~= "string" or #value == 0 then attempts[#attempts + 1] = label .. ": empty or invalid return (" .. type(value) .. ")"; return nil end
      if validateSource then
        local problem = sourceError(value)
        if problem then attempts[#attempts + 1] = label .. ": " .. problem; return nil end
        if #value > CONFIG.MAX_SOURCE_BYTES then attempts[#attempts + 1] = label .. ": source exceeds size limit"; return nil end
      end
      attempts[#attempts + 1] = label .. ": returned " .. #value .. " bytes"; return value
    end
    local sourceOk, directSource = pcall(function() return object.Source end)
    if sourceOk and type(directSource) == "string" and directSource:match("%S") then source, method = directSource, "Source"; attempts[#attempts + 1] = "Source: available"
    else attempts[#attempts + 1] = "Source: " .. (sourceOk and "empty or unavailable" or errorText(directSource)) end
    if not source and decompiler then
      source = attempt("decompile(instance)", decompiler, object, true)
      if source then method = "decompile(instance)" end
    end
    if (not source or CONFIG.SAVE_BYTECODE) and #readers > 0 then
      for _, reader in ipairs(readers) do
        bytecode = attempt(reader.name .. "(instance)", reader.fn, object, false)
        if bytecode then break end
      end
    end
    if not source and bytecode and decompiler then
      source = attempt("decompile(bytecode)", decompiler, bytecode, true)
      if source then method = "decompile(bytecode)" end
    end
    if not source and decompiler then
      for _, reader in ipairs(closureReaders) do
        local success, value = pcall(reader.fn, object)
        if success and type(value) == "function" then
          closure = value; attempts[#attempts + 1] = reader.name .. ": function obtained"
          source = attempt("decompile(" .. reader.name .. ")", decompiler, closure, true)
          if source then method = "decompile(" .. reader.name .. ")"; break end
        else
          attempts[#attempts + 1] = reader.name .. ": " .. (success and ("returned " .. type(value)) or errorText(value))
        end
      end
    end
    if not decompiler then attempts[#attempts + 1] = "decompile: unavailable" end
    if #readers == 0 then attempts[#attempts + 1] = "bytecode readers unavailable" end
    local stem = ("%04d_%s_%s"):format(index, objectClass(object), safeFilename(item.path))
    if bytecode and CONFIG.SAVE_BYTECODE then
      local byteOk, byteError = saveFile(base .. "/bytecode/" .. stem .. ".bin", bytecode)
      if byteOk then bytecodes += 1 else attempts[#attempts + 1] = "save bytecode: " .. tostring(byteError) end
    end
    if not source and CONFIG.SAVE_DISASSEMBLY and disassembler then
      local assembly = attempt("disassemble(instance)", disassembler, object, true)
      if not assembly and bytecode then assembly = attempt("disassemble(bytecode)", disassembler, bytecode, true) end
      if not assembly and closure then assembly = attempt("disassemble(closure)", disassembler, closure, true) end
      if assembly then saveFile(base .. "/disassembly/" .. stem .. ".txt", assembly .. "\n") end
    end
    local context = line(safeProperty(object, "RunContext", "unavailable"))
    local header = table.concat({
      "-- SrcDump",
      "-- index: " .. index,
      "-- class: " .. objectClass(object),
      "-- path: " .. line(item.path),
      "-- discovered_by: " .. item.origin,
      "-- run_context: " .. context,
      "-- method: " .. tostring(method or "none"),
      "",
    }, "\n")
    if source then
      local savedOk, saveError = saveFile(base .. "/scripts/" .. stem .. ".lua", header .. source .. "\n")
      if savedOk then saved += 1 else failed += 1; errors[#errors + 1] = "[WRITE_ERROR] " .. line(item.path) .. " | " .. tostring(saveError) end
      if savedOk then manifest[#manifest + 1] = "[OK] " .. line(item.path) .. " | " .. method .. " | scripts/" .. stem .. ".lua"
      else manifest[#manifest + 1] = "[ERROR] " .. line(item.path) .. " | write failed" end
    else
      failed += 1; errors[#errors + 1] = "[SOURCE_ERROR] " .. line(item.path) .. " | " .. objectClass(object) .. "\n  " .. table.concat(attempts, "\n  ")
      manifest[#manifest + 1] = "[ERROR] " .. line(item.path) .. " | source unavailable"
    end
    status.processed, status.saved, status.failed, status.bytecode = index, saved, failed, bytecodes
    if index % CONFIG.PROGRESS_EVERY == 0 then emit(callbacks, "onProgress", index, #candidates, item.path) end
    yieldIfNeeded(index)
  end
  saveFile(base .. "/manifest.txt", table.concat(manifest, "\n") .. "\n"); saveFile(base .. "/errors.txt", #errors > 0 and table.concat(errors, "\n\n") .. "\n" or "No errors.\n")
  saveFile(
    base .. "/summary.txt",
    table.concat({
      "SrcDump",
      "folder=" .. base,
      "total_found=" .. #candidates,
      "decompiled_and_saved=" .. saved,
      "failed=" .. failed,
      "bytecode_saved=" .. bytecodes,
      "instances=" .. #catalog,
      "remotes=" .. remoteCount,
      "note=Only content accessible to the client environment can be captured.",
      "",
    }, "\n")
  )
  return { folder = base, total = #candidates, saved = saved, failed = failed, bytecode = bytecodes }
end

-- lifecycle
function Dumper.setup()
  Dumper.stop(); return true
end
function Dumper.start(callbacks)
  if activeToken then return false, "A dump is already running" end
  if type(callbacks) ~= "table" then callbacks = {} end
  local token = { cancelled = false }; activeToken, activeCallbacks = token, callbacks
  status = {
    running = true,
    startedAt = os.clock(),
    folder = nil,
    total = 0,
    processed = 0,
    saved = 0,
    failed = 0,
    bytecode = 0,
  }

  task.spawn(function()
    local ok, result, reason = xpcall(
      function() return run(token, callbacks) end,
      function(errorValue) return debug and type(debug.traceback) == "function" and debug.traceback(tostring(errorValue), 2) or tostring(errorValue) end
    )
    if activeToken ~= token then return end
    local callbacks = activeCallbacks; activeToken, activeCallbacks = nil, nil
    status.running = false
    if token.cancelled then emit(callbacks, "onCanceled"); return end
    if not ok or not result then emit(callbacks, "onError", not ok and result or reason or "Dump failed"); return end
    status.folder = result.folder; status.total, status.saved, status.failed, status.bytecode = result.total, result.saved, result.failed, result.bytecode
    emit(callbacks, "onComplete", table.clone(result))
  end)
  return true
end
function Dumper.stop()
  if activeToken then
    local callbacks = activeCallbacks; activeToken.cancelled = true
    activeToken, activeCallbacks = nil, nil; emit(callbacks, "onCanceled")
  end
  status.running = false; return true
end
function Dumper.isRunning() return activeToken ~= nil end
function Dumper.getStatus() return table.clone(status) end
function Dumper.teardown() return Dumper.stop() end

-- contract
Dumper.__contract = {
  requires = {},
  provides = { "setup", "start", "stop", "isRunning", "getStatus", "teardown" },
}

return Dumper
