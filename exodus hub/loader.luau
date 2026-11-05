-- The standalone bundle passes its modules here. This source loader can also
-- load a complete local checkout or one immutable GitHub revision.
local modules = ...
if type(modules) ~= "table" then
    local manifest = {
        { "uiconfig", "modules/front/uiconfig.luau" },
        { "config", "modules/front/config.luau" },
        { "utils", "modules/logic/utils.luau" },
        { "gameinfo", "modules/logic/gameinfo.luau" },
        { "remote", "modules/logic/remote.luau" },
        { "character", "modules/logic/character.luau" },
        { "dash", "modules/logic/dash.luau" },
        { "autoparry", "modules/logic/autoparry.luau" },
        { "autoclash", "modules/logic/autoclash.luau" },
        { "spam", "modules/logic/spam.luau" },
        { "autodark", "modules/logic/autodark.luau" },
        { "movement", "modules/logic/movement.luau" },
        { "spin", "modules/logic/spin.luau" },
        { "ui", "modules/front/ui.luau" },
        { "bootstrap", "bootstrap.luau" },
    }
    local root
    if type(isfile) == "function" and type(readfile) == "function" then
        for _, candidate in ipairs({ "exodus hub", "Exodus-v2/exodus hub", "Exodus-v2-main/exodus hub" }) do
            local complete = true
            for _, entry in ipairs(manifest) do
                local ok, exists = pcall(isfile, candidate .. "/" .. entry[2])
                if not ok or not exists then complete = false; break end
            end
            if complete then root = candidate; break end
        end
    end
    local function get(url)
        local requestFunction = type(request) == "function" and request or (type(http_request) == "function" and http_request or nil)
        if requestFunction then
            local response = requestFunction({ Url = url, Method = "GET", Headers = { ["Accept"] = "application/vnd.github+json" } })
            local status = response and tonumber(response.StatusCode or response.status_code)
            assert(status and status >= 200 and status < 300, "HTTP " .. tostring(status))
            return response.Body or response.body or response.ResponseBody
        end
        return game:HttpGet(url)
    end
    local revision
    if not root then
        revision = _G.EXODUS_REVISION
        if not revision then
            local body = get("https://api.github.com/repos/Repp35/Exodus-v2/commits/main")
            revision = game:GetService("HttpService"):JSONDecode(body).sha
        end
        assert(type(revision) == "string" and #revision == 40 and revision:match("^[%da-fA-F]+$"), "revisão GitHub inválida")
    end
    modules = {}
    for _, entry in ipairs(manifest) do
        local source
        if root then source = readfile(root .. "/" .. entry[2])
        else source = get("https://raw.githubusercontent.com/Repp35/Exodus-v2/" .. revision .. "/exodus%20hub/" .. entry[2]) end
        assert(type(source) == "string" and source ~= "", "módulo vazio: " .. entry[1])
        local chunk, compileError = loadstring(source, "Exodus/" .. entry[1])
        assert(chunk, compileError)
        modules[entry[1]] = chunk()
    end
end
return modules.bootstrap(modules)
