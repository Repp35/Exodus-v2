-- [[ permissions ]]

-- module
local Permissions = {}

-- configuration
local CONFIG = {
  RESERVED = { __contract = true, __config = true },
}

-- registry
local registry = {}

-- validation
local function deny(name, action) error(("Permissão negada: %s -> %s"):format(name, action), 3) end
local function namedSet(owner, field, items)
  if type(items) ~= "table" then error(owner .. ": " .. field .. " inválido", 3) end
  local result, count = {}, 0
  for index, name in pairs(items) do
    if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or type(name) ~= "string" or name == "" or result[name] then
      error(owner .. ": " .. field .. " contém entrada inválida ou duplicada", 3)
    end
    result[name] = true; count += 1
  end
  if count ~= #items then error(owner .. ": " .. field .. " deve ser uma lista contínua", 3) end
  return result
end
local function validate(name, module)
  if type(name) ~= "string" or type(module) ~= "table" then error("Permissions: módulo inválido", 2) end
  local contract = module.__contract
  if type(contract) ~= "table" then error(name .. ": contrato ausente", 2) end
  local provides = namedSet(name, "provides", contract.provides); local data = namedSet(name, "data", contract.data or {})
  for field in pairs(data) do
    if provides[field] or type(module[field]) ~= "table" then error(name .. ": dado público inválido: " .. field, 2) end
  end
  for field in pairs(provides) do
    if type(module[field]) ~= "function" then error(name .. ": API declarada ausente: " .. field, 2) end
  end
  for field, value in pairs(module) do
    if type(value) == "function" and not provides[field] then error(name .. ": função não declarada no contrato: " .. tostring(field), 2) end
    if type(value) == "table" and not CONFIG.RESERVED[field] and not data[field] then error(name .. ": tabela pública não declarada: " .. tostring(field), 2) end
  end
  if contract.bindCharacter == true and (not provides.bindCharacter or not provides.detachCharacter) then error(name .. ": contrato bindCharacter incompleto", 2) end
  if contract.onBallSync == true and not provides.onBallSync then error(name .. ": contrato onBallSync incompleto", 2) end
  local requires = contract.requires or {}; local methods = contract.requiresMethods or {}
  local fields = contract.requiresData or {}; local versions = contract.requiresVersions or {}
  if type(requires) ~= "table" or type(methods) ~= "table" or type(fields) ~= "table" or type(versions) ~= "table" then error(name .. ": dependências inválidas", 2) end
  local uses, sources = {}, {}
  for alias, source in pairs(requires) do
    if type(alias) ~= "string" or type(source) ~= "string" or alias == "" or source == "" or sources[source] or source == name then
      error(name .. ": dependência inválida ou duplicada: " .. tostring(alias), 2)
    end
    sources[source] = true
    uses[alias] = {
      source = source,
      methods = namedSet(name, alias .. ".requiresMethods", methods[alias] or {}),
      data = namedSet(name, alias .. ".requiresData", fields[alias] or {}),
    }
    for field in pairs(uses[alias].methods) do
      if uses[alias].data[field] then error(name .. ": método e dado duplicados: " .. field, 2) end
    end
  end
  for alias in pairs(methods) do
    if not uses[alias] then error(name .. ": requiresMethods sem dependência: " .. tostring(alias), 2) end
  end
  for alias in pairs(fields) do
    if not uses[alias] then error(name .. ": requiresData sem dependência: " .. tostring(alias), 2) end
  end
  for alias, minimum in pairs(versions) do
    if not uses[alias] or type(minimum) ~= "number" or minimum < 0 or minimum ~= minimum then error(name .. ": versão de dependência inválida: " .. tostring(alias), 2) end
    uses[alias].minimum = minimum
  end
  if contract.version ~= nil and (type(contract.version) ~= "number" or contract.version < 0 or contract.version ~= contract.version) then error(name .. ": versão do contrato inválida", 2) end
  registry[name] = { module = module, provides = provides, data = data, uses = uses, version = contract.version }; return true
end
local function readonly(value, visited)
  if type(value) ~= "table" then return value end
  visited = visited or {}
  if visited[value] then return visited[value] end
  local copy = {}; visited[value] = copy
  for key, item in pairs(value) do
    copy[readonly(key, visited)] = readonly(item, visited)
  end
  return table.freeze(copy)
end
local function wrap(consumer, source, provider)
  local entry, exposed = registry[consumer], registry[source]
  if not entry or not exposed or exposed.module ~= provider then error("Permissions: módulo não validado: " .. tostring(source), 2) end
  local use
  for _, dependency in pairs(entry.uses) do
    if dependency.source == source then use = dependency; break end
  end
  if not use then deny(consumer, "api.consume." .. source) end
  local members = {}
  for method in pairs(use.methods) do
    if not exposed.provides[method] then deny(consumer, "api.consume." .. source .. "." .. method) end
    members[method] = provider[method]
    if type(members[method]) ~= "function" then error("Permissions: API ausente: " .. source .. "." .. method, 2) end
  end
  for field in pairs(use.data) do
    if not exposed.data[field] then deny(consumer, "api.consume." .. source .. "." .. field, 2) end
    if type(provider[field]) ~= "table" then error("Permissions: dado ausente: " .. source .. "." .. field, 2) end
    members[field] = readonly(provider[field])
  end
  table.freeze(members); local view = {}
  setmetatable(view, {
    __index = function(_, field)
      local value = members[field]
      if value ~= nil then return value end
      deny(consumer, "api.consume." .. source .. "." .. tostring(field))
    end,
    __newindex = function(_, field) deny(consumer, "api.write." .. source .. "." .. tostring(field)) end,
    __metatable = "locked",
  })
  return view
end

-- resolution
local function resolve(consumer, loaded)
  local entry = registry[consumer]
  if type(loaded) ~= "table" or not entry or entry.module ~= loaded[consumer] then error("Permissions: módulo não validado: " .. tostring(consumer), 2) end
  local dependencies = {}
  for alias, use in pairs(entry.uses) do
    local provider, source = loaded[use.source], registry[use.source]
    if not source or source.module ~= provider then error(("API interna ausente: dependência %s (%s)"):format(alias, use.source), 2) end
    if use.minimum and (type(source.version) ~= "number" or source.version < use.minimum) then
      error(("API incompatível: %s requer versão %s; encontrada %s"):format(alias, tostring(use.minimum), tostring(source.version)), 2)
    end
    dependencies[alias] = wrap(consumer, use.source, provider)
  end
  return dependencies
end

-- introspection
local function policy(name)
  local entry = registry[name]
  if not entry then error("Permissions: módulo não registrado: " .. tostring(name), 2) end
  local result = { provides = {}, consumes = {} }
  for method in pairs(entry.provides) do
    result.provides[#result.provides + 1] = method
  end
  table.sort(result.provides)
  for _, use in pairs(entry.uses) do
    local members = {}
    for method in pairs(use.methods) do
      members[#members + 1] = method
    end
    for field in pairs(use.data) do
      members[#members + 1] = field
    end
    table.sort(members); result.consumes[use.source] = members
  end
  return result
end

-- public-api
Permissions.validate = validate
Permissions.wrap = wrap
Permissions.resolve = resolve
Permissions.policy = policy

-- contract
Permissions.__contract = {
  provides = { "validate", "wrap", "resolve", "policy" },
  requires = {},
}

return Permissions
