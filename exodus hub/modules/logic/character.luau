-- [[ character ]]

-- module
local Character = {}
local utils, spam, binds
local added, removing, currentLife
local generation, setupEpoch, phase, workerRunning = 0, 0, "stopped", false

-- configuration
local CONFIG = {
  BIND_TIMEOUT = 10,
  ROOT_POLL_INTERVAL = 1 / 60,
}

-- state-tracking
local function setPhase(value, reason)
  if phase == value then return end
  local previous = phase; phase = value
  if utils then utils.recordTransition("Character", previous, value, reason) end
end

-- lifecycle
local function detach(entry)
  local ok, err = pcall(entry.detach)
  if not ok and utils then utils.recordError("Character", ("%s: falha ao desvincular: %s"):format(entry.name or "bind", tostring(err))) end
end
local function clearLife()
  local life = currentLife; currentLife = nil
  if life then
    for i = #life.bound, 1, -1 do
      detach(life.bound[i]); life.bound[i] = nil
    end
  end
  if not utils then return end
  utils.disconnectCharacterConnections(); utils.setManualSpamActive(false)
  utils.setAutoSpamActive(false)
  if spam then spam.resetState() end
end
local function deactivate(life, reason)
  if currentLife ~= life then return end
  generation += 1; setPhase("cleaning", reason)
  clearLife(); setPhase("stopped", "character_cleaned")
end
local function valid(life) return currentLife == life and utils ~= nil and utils.isActive() and life.character.Parent ~= nil end
local function bindLife(life)
  life.attempted = true
  if not valid(life) then return end
  setPhase("binding", "character_bind_start"); local root = life.character:FindFirstChild("HumanoidRootPart")
  local deadline = os.clock() + CONFIG.BIND_TIMEOUT
  while valid(life) and (not root or not root:IsA("BasePart") or not root.Parent) and os.clock() < deadline do
    task.wait(CONFIG.ROOT_POLL_INTERVAL); root = life.character:FindFirstChild("HumanoidRootPart")
  end
  if not valid(life) then return end
  if not root or not root:IsA("BasePart") or not root.Parent then
    deactivate(life, "root_unavailable"); setPhase("invalid", "root_unavailable")
    return
  end
  for index, entry in ipairs(binds) do
    if not valid(life) then return end
    local ok, result, detail = pcall(entry.bind, life.character)
    if not ok then detail, result = result, false end
    if not valid(life) then detach(entry); return end
    if result ~= true then
      utils.recordError("Character", ("%s não vinculou o personagem: %s"):format(entry.name or ("bind_" .. index), tostring(detail or result))); detach(entry)
      deactivate(life, "bind_failed"); setPhase("invalid", "bind_failed")
      return
    end
    life.bound[#life.bound + 1] = entry
  end
  if valid(life) then setPhase("bound", "character_bound") end
end
local function startWorker()
  if workerRunning then return end
  workerRunning = true
  task.spawn(function()
    while currentLife and not currentLife.attempted do
      bindLife(currentLife)
    end
    workerRunning = false
    if currentLife and not currentLife.attempted then startWorker() end
  end)
end
local function setupCharacter(character)
  if not character or not utils or (currentLife and currentLife.character == character) then return end
  generation += 1; clearLife()
  local life = { character = character, bound = {}, attempted = false, humanoids = {} }; currentLife = life
  utils.trackCharacter(character.AncestryChanged:Connect(function(_, parent)
    if not parent then deactivate(life, "character_removed") end
  end))
  local function watchHumanoid(humanoid)
    if currentLife ~= life or life.humanoids[humanoid] then return end
    life.humanoids[humanoid] = true
    utils.trackCharacter(humanoid.Died:Connect(function() deactivate(life, "character_died") end))
    if humanoid.Health <= 0 then deactivate(life, "character_died") end
  end
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if humanoid then watchHumanoid(humanoid) end
  if currentLife ~= life then return end
  utils.trackCharacter(character.ChildAdded:Connect(function(child)
    if child:IsA("Humanoid") then watchHumanoid(child) end
  end))
  startWorker()
end
function Character.setup(deps)
  if
    type(deps) ~= "table"
    or type(deps.Utils) ~= "table"
    or type(deps.Spam) ~= "table"
    or type(deps.Spam.resetState) ~= "function"
    or type(deps.characterBinds) ~= "table"
  then
    return false, "dependência ausente: Utils, Spam ou characterBinds"
  end
  for index, entry in ipairs(deps.characterBinds) do
    if type(entry) ~= "table" or type(entry.bind) ~= "function" or type(entry.detach) ~= "function" then return false, ("characterBinds[%d] inválido"):format(index) end
  end
  Character.teardown(); utils, spam, binds = deps.Utils, deps.Spam, deps.characterBinds
  local player = utils.getLocalPlayer()
  if not player then setPhase("invalid", "player_unavailable"); return false, "Players.LocalPlayer indisponível" end
  setPhase("ready", "character_controller_ready"); local owner = setupEpoch
  added = player.CharacterAdded:Connect(function(character)
    if owner == setupEpoch then setupCharacter(character) end
  end)
  removing = player.CharacterRemoving:Connect(function(character)
    if owner == setupEpoch and currentLife and currentLife.character == character then deactivate(currentLife, "character_removing") end
  end)
  utils.trackGlobal(added); utils.trackGlobal(removing)
  if player.Character then setupCharacter(player.Character) end
  return true
end
function Character.teardown()
  generation += 1; setupEpoch += 1
  if utils then
    if added then utils.untrackGlobal(added) end
    if removing then utils.untrackGlobal(removing) end
  end
  if added then added:Disconnect() end
  if removing then removing:Disconnect() end
  added, removing = nil, nil; setPhase("cleaning", "character_controller_teardown")
  clearLife(); setPhase("stopped", "character_controller_stopped")
  utils, spam, binds = nil, nil, nil
end

-- public-api
function Character.getStatus() return { schema = utils and utils.apiVersion() or nil, phase = phase, generation = generation } end

-- contract
Character.__contract = {
  requires = { Spam = "spam", Utils = "utils" },
  requiresMethods = {
    Utils = {
      "getLocalPlayer",
      "isActive",
      "apiVersion",
      "trackGlobal",
      "untrackGlobal",
      "trackCharacter",
      "disconnectCharacterConnections",
      "setManualSpamActive",
      "setAutoSpamActive",
      "recordTransition",
      "recordError",
    },
    Spam = { "resetState" },
  },
  provides = { "setup", "teardown", "getStatus" },
}

return Character
