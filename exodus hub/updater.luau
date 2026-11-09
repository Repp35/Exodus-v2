-- [[ atualização automática ]]

-- runtime

return function(loadedRevision, request)
	local players = game:GetService("Players")
	local workspace = game:GetService("Workspace")
	local token = {}
	_G.ExodusUpdaterToken = token

	local function running()
		return _G.ExodusUpdaterToken == token
			and type(_G.Exodus) == "table"
			and _G.Exodus.Started == true
	end

	local function safeToUpdate()
		local exodus = _G.Exodus
		local modules = exodus and exodus.Modules
		local info = modules and modules.gameinfo
		local auto = modules and modules.autospam
		local player = players.LocalPlayer
		if not player or not info or not auto then return false end
		if type(info.getTargetId) ~= "function" or type(info.getClashContext) ~= "function"
			or type(auto.isActive) ~= "function" then return false end
		local target = info.getTargetId()
		if target == player.UserId or workspace:GetAttribute("GameBallTarget") == player.UserId then return false end
		if auto.isActive() or info.getClashContext() then return false end
		return true
	end

	local function latestRevision()
		local body, err = request("https://github.com/Repp35/Exodus-v2/commits/main.atom?exodus_cache=" .. tostring(os.time()), {
			["Accept"] = "application/atom+xml",
			["User-Agent"] = "Exodus-Hub-Updater",
		})
		if not body then return nil, err end
		local entry = body:match("<entry[%s>].-</entry>")
		local sha = entry and entry:match("Grit::Commit/([%x]+)")
		if not sha or #sha ~= 40 then return nil, "Feed de commits inválido" end
		return sha
	end

	task.spawn(function()
		local pending, chunk, nextCheck, failures = nil, nil, 0, 0
		while running() do
			if os.clock() >= nextCheck then
				nextCheck = os.clock() + 5
				local revision, err = latestRevision()
				if not running() then return end
				if revision then
					failures = 0
					if revision ~= loadedRevision then
						if pending ~= revision then pending, chunk = revision, nil end
					else
						pending, chunk = nil, nil
					end
				else
					failures += 1
					nextCheck = os.clock() + math.min(300, 15 * 2 ^ math.min(failures - 1, 5))
					warn("[Exodus Updater] Falha ao verificar atualização: " .. tostring(err))
				end
			end
			if pending and not chunk then
				local source, err = request("https://raw.githubusercontent.com/Repp35/Exodus-v2/" .. pending .. "/exodus%20hub/loader.luau")
				if not running() then return end
				if source then
					local compiled, compileError = loadstring(source, "Exodus loader")
					if compiled then chunk = compiled else warn("[Exodus Updater] " .. tostring(compileError)); pending = nil end
				else
					warn("[Exodus Updater] Falha ao baixar loader: " .. tostring(err)); pending = nil
				end
			end
			if chunk and running() and safeToUpdate() then
				print("[Exodus Updater] Atualizando o hub...")
				local ok, err = xpcall(chunk, function(value) return debug.traceback(tostring(value), 2) end)
				if not ok then warn("[Exodus Updater] Falha ao reiniciar: " .. tostring(err)) end
				return
			end
			task.wait(pending and 0.25 or 1)
		end
	end)
end
