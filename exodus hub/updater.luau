-- [[ atualização automática ]]

-- runtime

return function(loadedRevision, request, options)
	options = type(options) == "table" and options or {}; local players = game:GetService("Players"); local token = {}; _G.ExodusUpdaterToken = token
	local function running() return _G.ExodusUpdaterToken == token and type(_G.Exodus) == "table" and _G.Exodus.Started == true end
	local function currentRevision()
		local exodus = _G.Exodus; return exodus and exodus.Revision or loadedRevision
	end
	local function safeToUpdate()
		local exodus = _G.Exodus; local modules = exodus and exodus.Modules; local info = modules and modules.gameinfo; local auto = modules and modules.autospam; local player = players.LocalPlayer
		if not player or not info or not auto then return false end
		if
			type(info.getTargetId) ~= "function"
			or type(info.getBallTargetAttribute) ~= "function"
			or type(info.getClashContext) ~= "function"
			or type(auto.isActive) ~= "function"
		then
			return false
		end
		local target = info.getTargetId()
		if target == player.UserId or info.getBallTargetAttribute() == player.UserId then return false end
		if auto.isActive() or info.getClashContext() then return false end
		return true
	end
	local function latestRevision()
		local body, requestError, requestMeta = request(
			"https://api.github.com/repos/Repp35/Exodus-v2/commits/main?exodus_cache=" .. tostring(os.time()),
			{ ["Accept"] = "application/vnd.github+json", ["User-Agent"] = "Exodus-Hub-Updater" }
		)
		if body then
			local ok, document = pcall(function() return game:GetService("HttpService"):JSONDecode(body) end)
			local sha = ok and type(document) == "table" and document.sha
			if type(sha) == "string" and #sha == 40 and sha:match("^[%x]+$") then return sha end
		end
		local feed, feedError, feedMeta = request(
			"https://github.com/Repp35/Exodus-v2/commits/main.atom?exodus_cache=" .. tostring(os.time()),
			{ ["Accept"] = "application/atom+xml", ["User-Agent"] = "Exodus-Hub-Updater" }
		)
		local entry = feed and feed:match("<entry[%s>].-</entry>"); local sha = entry and entry:match("Grit::Commit/([%x]+)")
		if sha and #sha == 40 then return sha end
		return nil, feedError or requestError or "SHA mais recente indisponível", feedMeta or requestMeta
	end
	local function retryAt(now, metadata)
		if metadata and metadata.rateLimited then return now + math.max(0, tonumber(metadata.retryAfter) or 5) end
		return now + 5
	end
	task.spawn(function()
		local pendingRevision
		local pendingSource
		local nextCheck = os.clock() + 5
		while running() do
			local now = os.clock()
			if now >= nextCheck and not pendingRevision then
				local revision, checkError, checkMetadata = latestRevision()
				if not running() then return end
				if revision then
					local current = currentRevision()
					if revision ~= current and revision ~= loadedRevision then pendingRevision = revision; nextCheck = now else nextCheck = now + 5 end
				else
					nextCheck = retryAt(now, checkMetadata); warn("[Exodus Updater] " .. tostring(checkError))
				end
			end
			if pendingRevision and not pendingSource and os.clock() >= nextCheck then
				local source, fetchError, fetchMetadata = request(
					"https://raw.githubusercontent.com/Repp35/Exodus-v2/" .. pendingRevision .. "/exodus%20hub/loader.luau?exodus_cache=" .. tostring(os.time()),
					{ ["User-Agent"] = "Exodus-Hub-Updater" }
				)
				if not running() then return end
				if source then
					local chunk, compileError = loadstring(source, "Exodus updater loader")
					if chunk then
						pendingSource = chunk
						if type(options.cacheLoader) == "function" then pcall(options.cacheLoader, pendingRevision, source) end
					else
						warn("[Exodus Updater] " .. tostring(compileError)); pendingRevision = nil; nextCheck = os.clock() + 5
					end
				elseif fetchMetadata and fetchMetadata.rateLimited then
					nextCheck = retryAt(os.clock(), fetchMetadata); warn("[Exodus Updater] " .. tostring(fetchError))
				else
					warn("[Exodus Updater] " .. tostring(fetchError)); pendingRevision = nil; nextCheck = os.clock() + 5
				end
			end
			if pendingRevision and pendingSource and running() then
				local safe = false; local ok, result = pcall(safeToUpdate)
				if ok then safe = result == true end
				if safe and running() and pendingRevision ~= currentRevision() and not _G.ExodusLoaderStartToken then
					print("[Exodus] Atualizando hub...")
					if type(_G.ExodusUIFadeOut) == "function" then
						local fadeOk, fadeError = pcall(_G.ExodusUIFadeOut)
						if not fadeOk then warn("[Exodus Updater] Transição: " .. tostring(fadeError)) end
					end
					if not running() then return end
					_G.ExodusRequestedRevision = pendingRevision
					local executed, executionError = xpcall(pendingSource, function(err) return debug.traceback(tostring(err), 2) end)
					if not executed then _G.ExodusRequestedRevision = nil; warn("[Exodus Updater] " .. tostring(executionError)) end
					return
				end
			end
			task.wait(pendingSource and 0.25 or math.max(0.05, math.min(5, nextCheck - os.clock())))
		end
	end)
end
