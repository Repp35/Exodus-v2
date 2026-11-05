return function(ctx, definitions)
    local values, schema = {}, {}
    local http = ctx.services.HttpService
    local folder, path = "Exodus Hub", "Exodus Hub/config.json"
    local dirty, writable = false, false

    local function finite(n)
        return type(n) == "number" and n == n and n > -math.huge and n < math.huge
    end
    local function valid(kind, value)
        if kind == "boolean" then return type(value) == "boolean" end
        if kind == "key" then return typeof(value) == "EnumItem" and value.EnumType == Enum.KeyCode and value ~= Enum.KeyCode.Unknown end
        if kind == "mode" then return value == "CPS" or value == "CPF" end
        if not finite(value) then return false end
        if kind == "factor" then return value >= 0 and value <= 1 end
        if kind == "cps" then return value >= 0 and value <= 120 end
        if kind == "cpf" then return value >= 0 and value <= 4 end
        if kind == "position" then return value >= -10000 and value <= 10000 end
        return false
    end
    for _, entry in ipairs(definitions) do
        schema[entry.key] = entry.kind
        values[entry.key] = entry.default
    end

    local config = {}
    function config:get(key) return values[key] end
    function config:set(key, value)
        if not schema[key] or not valid(schema[key], value) then return false end
        if values[key] ~= value then values[key] = value; dirty = true; ctx.state.uiDirty = true end
        return true
    end
    function config:load()
        if type(isfolder) ~= "function" or type(makefolder) ~= "function" or type(isfile) ~= "function"
            or type(readfile) ~= "function" or type(writefile) ~= "function" then return end
        local ok, exists = pcall(isfolder, folder)
        if not ok then return end
        if not exists then
            local created = pcall(makefolder, folder)
            if not created then return end
        end
        writable = true
        local fileOk, fileExists = pcall(isfile, path)
        if not fileOk or not fileExists then return end
        local readOk, body = pcall(readfile, path)
        if not readOk then return end
        local decoded, data = pcall(http.JSONDecode, http, body)
        if not decoded or type(data) ~= "table" then return end
        for _, entry in ipairs(definitions) do
            local value = data[entry.key]
            if entry.kind == "key" then
                if type(value) == "table" then value = value.keyCode end
                if type(value) == "string" then
                    local found, key = pcall(function() return Enum.KeyCode[value] end)
                    value = found and key or nil
                end
            end
            if value ~= nil and valid(entry.kind, value) then values[entry.key] = value end
        end
    end
    function config:flush()
        if not dirty then return end
        dirty = false
        if not writable then return end
        local encoded, body = pcall(function()
            local parts = {}
            for _, entry in ipairs(definitions) do
                local value = values[entry.key]
                if entry.kind == "key" and value then value = { keyCode = value.Name } end
                if value ~= nil then
                    parts[#parts + 1] = http:JSONEncode(entry.key) .. ":" .. http:JSONEncode(value)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end)
        if not encoded then ctx.utils:report("Config", body); return end
        local ok, result = pcall(writefile, path, body)
        if not ok or result == false then ctx.utils:report("Config", result or "falha ao salvar") end
    end
    return config
end
