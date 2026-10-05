-- [[ read_current_values ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local output = {}
local function safe(label, fn)
	local ok, value = pcall(fn)
	if ok then local line = ("[CurrentValues] %-28s %s"):format(label, tostring(value)); output[#output + 1] = line; print(line); return value end
	local line = ("[CurrentValues] %-28s <indisponível: %s>"):format(label, tostring(value)); output[#output + 1] = line; warn(line); return nil
end
local function requirePath(...)
	local current = ReplicatedStorage; local parts = { ... }
	for _, name in ipairs(parts) do
		current = current:FindFirstChild(name)
		if not current then return nil end
	end
	if not current:IsA("ModuleScript") then return nil end
	local ok, result = pcall(require, current); return ok and result or nil
end
local function getNested(module, key)
	if type(module) ~= "table" then return nil end
	if type(module[key]) == "table" then return module[key] end
	return module
end
print("[CurrentValues] ===== leitura da sessão atual =====")
safe("PlaceId", function() return game.PlaceId end)
safe("GameId", function() return game.GameId end)
safe("Player", function() return LocalPlayer and (LocalPlayer.Name .. " / " .. LocalPlayer.UserId) or "nil" end)
local ballReplicator = requirePath("TS", "BallReplicator", "BallReplicator")
local replicator = getNested(ballReplicator, "BallReplicator")
local syncData = replicator and replicator.syncData
if type(syncData) == "table" then
	for _, key in ipairs({
		"Speed",
		"MaxSpeed",
		"Accel",
		"TargetPlayerID",
		"Locked",
		"Grace",
		"OldGrace",
		"Teleported",
		"TeleportPosition",
		"RealPosition",
		"DirectionInterp",
		"DeflectDirectionInterp",
	}) do

		safe("syncData." .. key, function() return syncData[key] end)
	end
else
	warn("[CurrentValues] BallReplicator.syncData não está disponível")
end
local gameInfoModule = requirePath("TS", "GameInfo")
local gameInfo = getNested(gameInfoModule, "GameInfo")
local ball = gameInfo and gameInfo.BallModel
if ball then
	safe("Ball.Position", function() return ball.Position end)
	safe("Ball.AssemblyLinearVelocity", function() return ball.AssemblyLinearVelocity end)
	safe("Ball.SpeedMagnitude", function() return ball.AssemblyLinearVelocity.Magnitude end)
else
	warn("[CurrentValues] GameInfo.BallModel não está disponível")
end
local bindableModule = requirePath("TS", "BindableManager")
local bindableManager = getNested(bindableModule, "BindableManager")
local getAbility = bindableManager
	and bindableManager.GetFunction
	and safe("Bindable.GetAbility", function() return bindableManager:GetFunction("AbilityManager::GetAbility") end)
local ability
if getAbility and type(getAbility.Invoke) == "function" then
	ability = safe("DeflectAbility", function()
		local ok, result = pcall(getAbility.Invoke, getAbility, "Deflect")
		if ok and result then return result end
		return getAbility:Invoke("Block")
	end)
end
if ability then
	for _, key in ipairs({
		"BaseDistance",
		"DeflectDistance",
		"DeflectingWindow",
		"Cooldown",
		"LastCooldown",
		"cd",
	}) do
		safe("Ability." .. key, function() return ability[key] end)
	end
	if type(ability.GetDeflectionWindow) == "function" then
		safe("Ability.GetDeflectionWindow", function() return ability:GetDeflectionWindow(LocalPlayer) end)
	end
end
if bindableManager and type(bindableManager.GetFunction) == "function" then
	for _, name in ipairs({
		"Ball::GetCombinedSpeed",
		"Ball::GetBaseSpeed",
		"Ball::GetMaxSpeed",
		"Ball::GetSpeedOverTime",
		"Ball::GetSpeedOnDeflect",
		"Ball::GetKillDistance",
		"IsPlayerNoob",
	}) do
		local fn = safe("Bindable." .. name, function() return bindableManager:GetFunction(name) end)
		if fn and type(fn.Invoke) == "function" then
			safe("Invoke." .. name, function()
				if name == "IsPlayerNoob" then return fn:Invoke(LocalPlayer) end

				return fn:Invoke()
			end)
		end
	end
end
print("[CurrentValues] ===== fim da leitura =====")
output[#output + 1] = "[CurrentValues] ===== fim da leitura ====="
local fileName = "ExodusCurrentValues.txt"
if type(writefile) == "function" then
	local ok, errorMessage = pcall(writefile, fileName, table.concat(output, "\n") .. "\n")
	if ok then print("[CurrentValues] TXT salvo em " .. fileName)
	else warn("[CurrentValues] Não foi possível salvar o TXT: " .. tostring(errorMessage)) end
else
	warn("[CurrentValues] writefile indisponível; o resultado ficou apenas no console")
end
