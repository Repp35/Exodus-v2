-- [[ anti lag ]]

-- module
local AntiLag = {}
local Utils, GameInfo

-- configuration
local CONFIG = {
  schema = {
    AntiLagEnabled = "boolean",
    AntiLagFloorCull = "boolean",
    AntiLagRenderDistance = "rate",
    AntiLagRemoveSwordSounds = "boolean",
    AntiLagHideLobby = "boolean",
    AntiLagRemoveEffects = "boolean",
  },
  defaults = {
    AntiLagEnabled = false,
    AntiLagFloorCull = true,
    AntiLagRenderDistance = 128,
    AntiLagRemoveSwordSounds = true,
    AntiLagHideLobby = true,
    AntiLagRemoveEffects = true,
  },
}

-- profile
local PROFILE = {
  StartEnabled = false,
  ShowMenu = false,
  CullEnabled = true,
  CullView = false,
  CullVertical = false,
  CullAbove = 200,
  CullBelow = 100,
  CullVerticalMargin = 20,
  HideLobbyInMatch = true,
  GameSwordSounds = false,
  CullDistance = 128,
  CullKeepNear = 16,
  CullViewPadding = 12,
  CullViewDegrees = 8,
  CullHideDelay = 0.15,
  CullInterval = 0.1,
  CullBudgetMs = 0.8,
  GameGenerators = true,
  GameNoVFX = true,
  GameKeepIndicators = true,
  GameCosmeticAudio = true,
  GameKeepCombatAudio = true,
  GameMuteMusic = true,
  GameMuteAmbience = true,
  GameReducedUI = true,
  GameReducedHeadLook = true,
  Particles = true,
  TrailsAndBeams = true,
  LegacyEffects = true,
  PostEffects = true,
  Lights = true,
  Shadows = true,
  FlatLighting = true,
  FlatSky = true,
  Atmosphere = true,
  Clouds = true,
  NoFog = false,
  Water = true,
  TransparentWater = true,
  TerrainDecoration = true,
  FlatMaterials = false,
  HideTaggedDecorations = false,
  LowestGraphics = false,
  MaintainEffects = true,
  RestoreLatest = false,
  ShowFPS = false,
  FlatSkyTexture = "",
  BudgetMs = 1.5,
  MaxItemsPerFrame = 160,
  ReapplyInterval = 0.25,
}

local function createOptimizer(services, initialConfig)
  local Workspace = services.Workspace; local Lighting = services.Lighting
  local roots = services.Roots or { Workspace, Lighting }; local CollectionService = services.CollectionService
  local Heartbeat = services.RunService.Heartbeat; local options = table.clone(initialConfig)
  local controller = {}; local enabled, alive, destroying = false, true, false
  local journal, records = {}, {}; local connections = {}
  local pending, queued, head, tail = {}, {}, 1, 0; local scan = {}
  local dirty = {}; local delayed = false
  local workerRunning = false; local generation = 0
  local unsupported = {}; local unsupportedCount, restoreFailures, runtimeFailures = 0, 0, 0
  local changedProperties = 0
  local scheduleWorker, enqueue, process, restartScan
  local oneSequence = NumberSequence.new(1); local zeroLifetime = NumberRange.new(0)
  local white, black = Color3.new(1, 1, 1), Color3.new(0, 0, 0); local skyProperties = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" }
  local function read(object, property)
    return pcall(function() return object[property] end)
  end
  local function write(object, property, value)
    return pcall(function() object[property] = value end)
  end
  local function reportUnavailable(key)
    if not unsupported[key] then
      unsupported[key] = true; unsupportedCount += 1
      if key ~= "Terrain.Decoration" then warn("[AntiLag] Ajuste indisponivel neste cliente: " .. key) end
    end
  end
  local function unavailable(object, property) reportUnavailable(object.ClassName .. "." .. property) end
  local function inScope(object)
    for _, root in ipairs(roots) do
      if object == root or object:IsDescendantOf(root) then return true end
    end
    return false
  end
  local function desiredFor(object)
    local target = {}; local watch = true
    if object == services.GameSettings then
      if options.LowestGraphics then target.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1 end
      return target, false
    elseif object == Lighting then
      if options.Shadows then target.GlobalShadows = false end
      if options.FlatLighting then
        target.Ambient, target.OutdoorAmbient = white, white; target.Brightness, target.ExposureCompensation = 0, 0
        target.EnvironmentDiffuseScale, target.EnvironmentSpecularScale = 0, 0; target.ColorShift_Top, target.ColorShift_Bottom = black, black
        local ok, soft = pcall(function() return Enum.LightingStyle.Soft end)
        if ok then target.LightingStyle = soft end
        target.PrioritizeLightingQuality = false
      end
      if options.NoFog then target.FogStart, target.FogEnd = 0, 1000000 end
    elseif object:IsA("Terrain") then
      if options.Water then
        target.WaterWaveSize, target.WaterWaveSpeed, target.WaterReflectance = 0, 0, 0
        target.WaterTransparency = if options.TransparentWater then 1 else 0
      end
      if options.TerrainDecoration then target.Decoration = false end
    elseif object:IsA("ParticleEmitter") then
      if options.Particles then
        target.Enabled = false; target.Lifetime = zeroLifetime
        target.Transparency = oneSequence; target.LocalTransparencyModifier = 1
      end
    elseif object:IsA("Trail") or object:IsA("Beam") then
      if options.TrailsAndBeams then target.Enabled, target.Transparency = false, oneSequence end
    elseif object:IsA("Smoke") then
      if options.LegacyEffects then target.Enabled, target.Opacity, target.LocalTransparencyModifier = false, 0, 1 end
    elseif object:IsA("Fire") then
      if options.LegacyEffects then target.Enabled, target.LocalTransparencyModifier = false, 1 end
    elseif object:IsA("Sparkles") then
      if options.LegacyEffects then target.Enabled, target.LocalTransparencyModifier = false, 1 end
    elseif object:IsA("Highlight") then
      if options.LegacyEffects then target.Enabled = false end
    elseif object:IsA("ForceField") or object:IsA("Explosion") then
      if options.LegacyEffects then target.Visible = false end
    elseif object:IsA("PostEffect") then
      if options.PostEffects then target.Enabled = false end
    elseif object:IsA("Light") then
      if options.Lights then target.Enabled = false end
      if options.Shadows then target.Shadows = false end
    elseif object:IsA("Atmosphere") then
      if options.Atmosphere then target.Density, target.Haze, target.Glare = 0, 0, 0 end
    elseif object:IsA("Clouds") then
      if options.Clouds then target.Enabled = false end
    elseif object:IsA("Sky") then
      if options.FlatSky then
        target.CelestialBodiesShown, target.StarCount = false, 0
        for _, property in ipairs(skyProperties) do
          target[property] = options.FlatSkyTexture
        end
      end
    elseif object:IsA("BasePart") then
      watch = false
      if options.Shadows then target.CastShadow = false end
      if options.FlatMaterials then target.Material = Enum.Material.SmoothPlastic; target.MaterialVariant, target.Reflectance = "", 0 end
      if options.HideTaggedDecorations and CollectionService:HasTag(object, "AntiLagDecoration") then target.LocalTransparencyModifier = 1 end
    end
    return target, watch and options.MaintainEffects
  end
  local function removeEntry(entry)
    if entry.connection then entry.connection:Disconnect(); entry.connection = nil end
    journal[entry.object] = nil; local index = entry.index
    local last = records[#records]; records[index] = last
    if last then last.index = index end
    records[#records] = nil
  end
  local function restoreProperty(object, property, saved)
    local ok, current = read(object, property)
    if options.RestoreLatest and ok and current ~= saved.applied then saved.original = current end
    if ok and current == saved.original then return end
    if not write(object, property, saved.original) then restoreFailures += 1 end
  end
  local function restoreEntry(entry)
    removeEntry(entry)
    for property, saved in pairs(entry.properties) do
      restoreProperty(entry.object, property, saved); changedProperties -= 1
    end
  end
  local function delayDirty()
    if delayed then return end
    delayed = true
    task.delay(options.ReapplyInterval, function()
      delayed = false; local batch = dirty
      dirty = {}
      if not alive or not enabled then return end
      for object in pairs(batch) do
        enqueue(object)
      end
    end)
  end
  local function updateWatcher(entry, watch)
    if not watch then
      if entry.connection then entry.connection:Disconnect(); entry.connection = nil end
      return
    end
    if entry.connection then return end
    entry.connection = entry.object.Changed:Connect(function(property)
      if not enabled or not alive or journal[entry.object] ~= entry then return end
      local saved = entry.properties[property]
      if not saved then return end
      local ok, current = read(entry.object, property)
      if not ok or current == saved.applied then return end
      if options.RestoreLatest then saved.original = current end
      dirty[entry.object] = true; delayDirty()
    end)
  end
  process = function(object)
    local special = object == services.GameSettings
    if not enabled or (not special and not inScope(object)) then
      if journal[object] then restoreEntry(journal[object]) end
      return
    end
    local target, watch = desiredFor(object)
    if services.ExtraPolicy then target, watch = services.ExtraPolicy(object, target, watch, options) end
    local entry = journal[object]
    if entry then
      for property, saved in pairs(entry.properties) do
        if target[property] == nil then
          entry.properties[property] = nil; restoreProperty(object, property, saved)
          changedProperties -= 1
        end
      end
    end
    for property, value in pairs(target) do
      if unsupported[object.ClassName .. "." .. property] then continue end
      local ok, current = read(object, property)
      if not ok then unavailable(object, property); continue end
      local saved = entry and entry.properties[property]
      if not saved and current == value and not watch then continue end
      if not entry then entry = { object = object, properties = {}, index = #records + 1 }; journal[object], records[entry.index] = entry, entry end
      if not saved then
        saved = { original = current, applied = current }; entry.properties[property] = saved
        changedProperties += 1
      elseif options.RestoreLatest and current ~= saved.applied then
        saved.original = current
      end
      if current ~= value then
        local previous = saved.applied; saved.applied = value
        if not write(object, property, value) then
          saved.applied = previous; unavailable(object, property)
          if saved.original == current then entry.properties[property] = nil; changedProperties -= 1 end
        end
      else
        saved.applied = value
      end
    end
    if entry then
      if next(entry.properties) == nil then removeEntry(entry) else updateWatcher(entry, watch) end
    end
  end
  local function popPending()
    if head > tail then return nil end
    local object = pending[head]; pending[head] = nil
    head += 1; queued[object] = nil
    if head > tail then pending, head, tail = {}, 1, 0 end
    return object
  end
  local function nextScan()
    while #scan > 0 do
      local frame = scan[#scan]; local object = frame.items[frame.index]
      if not object then scan[#scan] = nil; continue end
      frame.index += 1
      local ok, children = pcall(function() return object:GetChildren() end)
      if ok and #children > 0 then scan[#scan + 1] = { items = children, index = 1 } end
      return object
    end
    return nil
  end
  local function workAvailable() return if enabled then head <= tail or #scan > 0 else #records > 0 end
  local function finishDestroy()
    alive = false
    for _, connection in ipairs(connections) do
      connection:Disconnect()
    end
    connections, dirty, pending, queued, scan = {}, {}, {}, {}, {}
  end
  scheduleWorker = function()
    if workerRunning or not alive then return end
    workerRunning = true
    task.defer(function()
      while alive and workAvailable() do
        local deadline = os.clock() + options.BudgetMs / 1000; local count = 0
        repeat
          if not enabled then
            local entry = records[#records]
            if entry then restoreEntry(entry) end
          else
            local object
            if count % 2 == 0 then object = popPending() or nextScan() else object = nextScan() or popPending() end
            if object then
              local ok, message = pcall(process, object)
              if not ok then
                runtimeFailures += 1
                if runtimeFailures <= 3 then warn("[AntiLag] " .. tostring(message)) end
              end
            end
          end
          count += 1
        until count >= options.MaxItemsPerFrame or os.clock() >= deadline or not workAvailable()
        if workAvailable() then Heartbeat:Wait() end
      end
      workerRunning = false
      if destroying and not enabled and #records == 0 then finishDestroy() end
    end)
  end
  enqueue = function(object)
    if not alive or not enabled or queued[object] then return end
    tail += 1; pending[tail], queued[object] = object, true
    scheduleWorker()
  end
  restartScan = function()
    generation += 1; scan = { { items = table.clone(roots), index = 1 } }
    if services.GameSettings then enqueue(services.GameSettings) end
    if options.LowestGraphics and not services.GameSettings then reportUnavailable("UserGameSettings.SavedQualityLevel") end
    scheduleWorker()
  end
  for _, root in ipairs(roots) do
    connections[#connections + 1] = root.DescendantAdded:Connect(enqueue)
    connections[#connections + 1] = root.DescendantRemoving:Connect(function(object)
      if journal[object] then enqueue(object) end
    end)
  end
  for _, signal in ipairs({
    CollectionService:GetInstanceAddedSignal("AntiLagDecoration"),
    CollectionService:GetInstanceRemovedSignal("AntiLagDecoration"),
  }) do
    connections[#connections + 1] = signal:Connect(enqueue)
  end
  connections[#connections + 1] = Workspace.DescendantAdded:Connect(function(object)
    if enabled and object:IsA("Humanoid") and object.Parent then scan[#scan + 1] = { items = { object.Parent }, index = 1 }; scheduleWorker() end
  end)
  function controller:RefreshInstance(object, immediate)
    if not enabled or not alive then return end
    if immediate then
      local ok, message = pcall(process, object)
      if not ok then
        runtimeFailures += 1
        if runtimeFailures <= 3 then warn("[AntiLag] " .. tostring(message)) end
      end
    else
      enqueue(object)
    end
  end
  function controller:RefreshSubtree(object)
    if enabled and alive and object then scan[#scan + 1] = { items = { object }, index = 1 }; scheduleWorker() end
  end
  function controller:SetEnabled(value)
    if not alive or destroying or enabled == value then return end
    enabled = value; generation += 1
    if enabled then restartScan() else pending, queued, scan, dirty, head, tail = {}, {}, {}, {}, 1, 0; scheduleWorker() end
  end
  function controller:SetOption(key, value)
    if not alive or destroying or options[key] == nil then return false end
    if typeof(value) ~= typeof(options[key]) then return false end
    if type(value) == "number" and (value ~= value or math.abs(value) == math.huge) then return false end
    if key == "BudgetMs" then value = math.clamp(value, 0.25, 4) end
    if key == "MaxItemsPerFrame" then value = math.floor(math.clamp(value, 8, 1000)) end
    if key == "ReapplyInterval" then value = math.clamp(value, 0.1, 2) end
    local bounds = {
      CullDistance = { 1, 1200 },
      CullKeepNear = { 8, 128 },
      CullViewPadding = { 0, 100 },
      CullViewDegrees = { 2, 30 },
      CullHideDelay = { 0.05, 2 },
      CullInterval = { 0.06, 0.35 },
      CullBudgetMs = { 0.2, 1.5 },
      CullAbove = { 80, 600 },
      CullBelow = { 50, 400 },
      CullVerticalMargin = { 5, 30 },
    }

    if bounds[key] then value = math.clamp(value, bounds[key][1], bounds[key][2]) end
    if options[key] == value then return true end
    options[key] = value; local noScan = key == "ShowFPS"
      or key == "ShowMenu"
      or key == "StartEnabled"
      or key == "BudgetMs"
      or key == "MaxItemsPerFrame"
      or key == "ReapplyInterval"
      or key == "RestoreLatest"
      or string.sub(key, 1, 4) == "Cull"
      or key == "HideLobbyInMatch"
    if enabled and not noScan then restartScan() end
    return true
  end
  function controller:GetOption(key) return options[key] end
  function controller:GetStatus()
    return {
      Enabled = enabled,
      Alive = alive,
      Destroying = destroying,
      Busy = workerRunning or workAvailable(),
      Instances = #records,
      Properties = changedProperties,
      Unsupported = unsupportedCount,
      UnsupportedProperties = table.clone(unsupported),
      RestoreFailures = restoreFailures,
      RuntimeFailures = runtimeFailures,
      Generation = generation,
    }
  end
  function controller:Destroy()
    if not alive or destroying then return end
    self:SetEnabled(false); destroying = true
    if #records == 0 then finishDestroy() else scheduleWorker() end
  end
  for _, key in ipairs({ "BudgetMs", "MaxItemsPerFrame", "ReapplyInterval" }) do
    controller:SetOption(key, options[key])
  end
  controller:SetEnabled(options.StartEnabled); return controller
end
local function createGameAdapter(services, getOption)
  local adapter = {}; local active, alive = false, true
  local modules = {}; local patches, attributes = {}, {}
  local connections = {}; local scheduled = false
  local refresh
  local stats = { DroppedVFX = 0, DroppedAudio = 0, RestoreConflicts = 0, Failures = 0 }; local Workspace = services.Workspace
  local player = services.Player
  local function enabledOption(key) return active and getOption(key) == true end
  local function deferRefresh()
    if scheduled or not alive then return end
    scheduled = true
    task.delay(0.25, function()
      scheduled = false
      if alive and active then refresh() end
    end)
  end
  local function reconcileAttribute(object, key, desired, wanted)
    local byKey = attributes[object]; local saved = byKey and byKey[key]
    if not wanted then
      if saved then
        byKey[key] = nil
        if saved.connection then saved.connection:Disconnect() end
        local ok = pcall(function() object:SetAttribute(key, saved.original) end)
        if not ok then stats.Failures += 1 end
        if next(byKey) == nil then attributes[object] = nil end
      end
      return
    end
    if not saved then
      local ok, original = pcall(function() return object:GetAttribute(key) end)
      if not ok then stats.Failures += 1; return end
      if not byKey then byKey = {}; attributes[object] = byKey end
      saved = { original = original, applied = desired }; byKey[key] = saved
      saved.connection = object:GetAttributeChangedSignal(key):Connect(function()
        if not active or not alive then return end
        local value = object:GetAttribute(key)
        if value ~= saved.applied then
          if getOption("RestoreLatest") then saved.original = value end
          deferRefresh()
        end
      end)
    end
    saved.applied = desired
    local ok = pcall(function()
      if object:GetAttribute(key) ~= desired then object:SetAttribute(key, desired) end
    end)
    if not ok then stats.Failures += 1 end
  end
  local function removePatch(id)
    local patch = patches[id]
    if not patch then return end
    patches[id] = nil
    if patch.object[patch.key] == patch.wrapper then
      local ok = pcall(function() patch.object[patch.key] = patch.original end)
      if not ok then stats.Failures += 1 end
    else
      stats.RestoreConflicts += 1
    end
  end
  local function ensurePatch(moduleName, key, shouldBlock, category, replacement)
    local id = moduleName .. "." .. key; local object = modules[moduleName]
    local wanted = active and getOption("GameGenerators") and type(object) == "table"
    if not wanted then removePatch(id); return end
    local existing = patches[id]
    if existing and existing.object == object and object[key] == existing.wrapper then return end
    if existing then removePatch(id) end
    local original = object[key]
    if type(original) ~= "function" then return end
    local wrapper = function(...)
      if alive and active and getOption("GameGenerators") and shouldBlock(...) then
        if category then stats[category] += 1 end
        if replacement then return replacement(...) end
        return nil
      end
      return original(...)
    end
    local ok = pcall(function() object[key] = wrapper end)
    if ok then patches[id] = { object = object, key = key, original = original, wrapper = wrapper } else stats.Failures += 1 end
  end
  refresh = function()
    if not alive then return end
    if not active then
      for object, byKey in pairs(attributes) do
        for key in pairs(byKey) do
          reconcileAttribute(object, key, nil, false)
        end
      end
    end
    local noVFX = enabledOption("GameNoVFX"); local quiet = enabledOption("GameCosmeticAudio")
    local reducedUI = enabledOption("GameReducedUI")
    local flags = {
      PB_PerfEnabled = active,
      PB_PerfNoVFX = noVFX,
      PB_PerfReducedUI = reducedUI,
      PB_PerfMuteMusic = enabledOption("GameMuteMusic"),
      PB_PerfCosmeticAudio = quiet,
      PB_PerfKeepCombatAudio = getOption("GameKeepCombatAudio") == true,
      PB_PerfReducedHeadLook = enabledOption("GameReducedHeadLook"),
      PB_PerfSwordSounds = getOption("GameSwordSounds") ~= false,
    }

    for key, value in pairs(flags) do
      reconcileAttribute(Workspace, key, value, active)
    end
    reconcileAttribute(player, "Setting_WeaponVFX", false, noVFX); reconcileAttribute(player, "Setting_ExplosionVFX", false, noVFX)
    reconcileAttribute(player, "Setting_KillSounds", false, quiet or active and getOption("GameSwordSounds") == false)
    reconcileAttribute(player, "Setting_SwordSounds", false, active and getOption("GameSwordSounds") == false)
    for _, method in ipairs({ "Spawn", "SpawnAtCFrame", "SpawnSwordEffect", "Emit", "Toggle" }) do
      ensurePatch("VFX", method, function() return enabledOption("GameNoVFX") end, "DroppedVFX")
    end
    ensurePatch("LowQuality", "CanSpawn", function() return enabledOption("GameNoVFX") end, nil, function() return false end)
    ensurePatch("VFXBudget", "Take", function() return enabledOption("GameNoVFX") end, nil, function() return false end)
    ensurePatch("WindowAnim", "ReducedMotion", function() return enabledOption("GameReducedUI") end, nil, function() return true end)
    ensurePatch("SFX", "SpawnSwordSFX", function(_, _, action)
      if getOption("GameSwordSounds") == false then return true end
      if not enabledOption("GameCosmeticAudio") then return false end
      if getOption("GameKeepCombatAudio") and (action == "BallHit" or action == "Block") then return false end
      return true
    end, "DroppedAudio")
    local emitter = services.PlayerScripts:FindFirstChild("Emitter2D"); local emitterModule = emitter and emitter:FindFirstChild("Emitter2D")
    if emitterModule and emitterModule:IsA("ModuleScript") then reconcileAttribute(emitterModule, "Enabled", false, reducedUI) end
  end
  function adapter:SetModule(name, value)
    if not alive or type(value) ~= "table" then return false end
    if modules[name] ~= value then
      local prefix = name .. "."
      for id in pairs(patches) do
        if id:sub(1, #prefix) == prefix then removePatch(id) end
      end
    end
    modules[name] = value
    if active then refresh() end
    return true
  end
  function adapter:SetEnabled(value)
    if not alive then return end
    active = value; refresh()
  end
  function adapter:Refresh()
    if active and alive then refresh() end
  end
  function adapter:GetStatus()
    local patchCount, attributeCount = 0, 0
    for _ in pairs(patches) do
      patchCount += 1
    end
    for _, entries in pairs(attributes) do
      for _ in pairs(entries) do
        attributeCount += 1
      end
    end
    return {
      Active = active,
      Patches = patchCount,
      Attributes = attributeCount,
      DroppedVFX = stats.DroppedVFX,
      DroppedAudio = stats.DroppedAudio,
      RestoreConflicts = stats.RestoreConflicts,
      Failures = stats.Failures,
    }
  end
  function adapter:Destroy()
    if not alive then return end
    self:SetEnabled(false); alive = false
    for _, connection in ipairs(connections) do
      connection:Disconnect()
    end
  end
  connections[#connections + 1] = services.PlayerScripts.DescendantAdded:Connect(function(object)
    if active and object.Name == "Emitter2D" then deferRefresh() end
  end)
  return adapter
end
local function applyGamePolicy(object, target, watch, options)
  if options.GameKeepIndicators then
    local critical = false
    if object:IsA("Highlight") then
      critical = object.Name == "PlayerBallHighlight" or object.Name == "LocalBlockCharacterHighlight"; local parent = object.Parent
      if parent then critical = critical or parent.Name == "GameBall" or parent.Name == "TrainingBall" or parent.Name == "ResilienceHitbox" end
    elseif object:IsA("Beam") then
      critical = object.Name == "PossessTether" or object.Name == "DarkForceChain"
    end
    if critical then target.Enabled, target.Transparency = nil, nil; watch = false end
  end
  if object:IsA("BasePart") then
    local ancestor = object
    while ancestor do
      if ancestor.Name == "GameBall" or ancestor.Name == "TrainingBall" then
        target.Material, target.MaterialVariant, target.Reflectance = nil, nil, nil; target.LocalTransparencyModifier = nil
        break
      end
      ancestor = ancestor.Parent
    end
  elseif object:IsA("SoundGroup") then
    if object.Parent and object.Parent.Name == "Master" then
      local mute = object.Name == "Music" and options.GameMuteMusic
        or object.Name == "Emotes" and options.GameCosmeticAudio
        or object.Name == "Ambience" and options.GameMuteAmbience
      if mute then target.Volume = 0; watch = options.MaintainEffects end
    end
  elseif object:IsA("Sound") then
    local kind = object:GetAttribute("SFXKind"); local swordMuted = options.GameSwordSounds == false and (kind == "SwordSounds" or kind == "KillSounds")
    if swordMuted or object.Name == "PB_LobbyTheme_Christmas" and options.GameMuteMusic then target.Volume = 0; watch = options.MaintainEffects end
  end
  return target, watch
end
local function verticalDecision(minY, maxY, cameraY, previous, options)
  if options.CullFloorY and maxY < options.CullFloorY then return "floor" end
  if not options.CullVertical then return nil end
  local margin = options.CullVerticalMargin or 20
  local above = (options.CullAbove or 200) - (if previous == "above" then margin else 0)
  local below = (options.CullBelow or 100) - (if previous == "below" then margin else 0)
  local anchorY = options.CullAnchorY or cameraY
  if minY > math.max(cameraY, anchorY) + above then return "above" end
  if maxY < math.min(cameraY, anchorY) - below then return "below" end
  return nil
end
local function boundsHalf(frame, size)
  local right, up, look = frame.RightVector, frame.UpVector, frame.LookVector
  return Vector3.new(
    (math.abs(right.X) * size.X + math.abs(up.X) * size.Y + math.abs(look.X) * size.Z) * 0.5,
    (math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y + math.abs(look.Y) * size.Z) * 0.5,
    (math.abs(right.Z) * size.X + math.abs(up.Z) * size.Y + math.abs(look.Z) * size.Z) * 0.5
  )
end
local function cameraPlanes(view)
  local normals = {
    view.look,
    view.look * view.options.ViewTanX + view.right,
    view.look * view.options.ViewTanX - view.right,
    view.look * view.options.ViewTanY + view.up,
    view.look * view.options.ViewTanY - view.up,
  }

  local planes = {}
  for _, normal in ipairs(normals) do
    planes[#planes + 1] = { normal = normal, padding = view.options.CullViewPadding * normal.Magnitude }
  end
  return planes
end
local function inCameraView(delta, half, view)
  for _, plane in ipairs(view.planes) do
    local normal = plane.normal; local support = math.abs(normal.X) * half.X + math.abs(normal.Y) * half.Y + math.abs(normal.Z) * half.Z
    if normal:Dot(delta) + support + plane.padding < 0 then return false end
  end
  return true
end
local function renderDecision(position, half, previous, outsideSince, now, view, turnHold)
  local delta = position - view.position; local options = view.options
  local origin = view.focus or view.position; local rangeDelta = position - origin
  local dx, dy, dz = math.max(0, math.abs(rangeDelta.X) - half.X), math.max(0, math.abs(rangeDelta.Y) - half.Y), math.max(0, math.abs(rangeDelta.Z) - half.Z)
  local surfaceDistance = math.sqrt(dx * dx + dy * dy + dz * dz)
  if surfaceDistance > options.CullDistance then return "distance", nil end
  local vertical = verticalDecision(position.Y - half.Y, position.Y + half.Y, view.position.Y, previous, options)
  if vertical then return vertical, nil end
  if turnHold or inCameraView(delta, half, view) then return nil, nil end
  if not options.CullView or surfaceDistance <= options.CullKeepNear then return nil, nil end
  outsideSince = outsideSince or now
  if now - outsideSince >= options.CullHideDelay then return "view", outsideSince end
  return nil, outsideSince
end
local function createSpatialController(services, getOption)
  local Workspace, player = services.Workspace, services.Player; local controller = {}
  local roots = services.Roots or { Workspace }
  local function inScope(object)
    for _, root in ipairs(roots) do
      if object == root or object:IsDescendantOf(root) then return true end
    end
    return false
  end
  local active, alive = false, true; local records, chunks, chunkList = {}, {}, {}
  local stack, pending, queued = {}, {}, {}; local head, tail, chunkIndex = 1, 0, 1
  local work, driver
  local connections = {}; local hiddenCount, trackedCount = 0, 0
  local lobbyHidden, lastLobby = false, nil; local elapsed, holdUntil, lastLook = 1, 0, nil
  local nextCycleAt, cycling = 0, false; local stepsLeft = 0
  local cameraSnapshot, lastCameraFrame
  local hiddenEntries, hiddenCursor = {}, 1
  local function option(key, fallback)
    local value = getOption(key)
    return if value == nil then fallback else value
  end
  local function setHidden(entry, hidden)
    if entry.hidden == hidden then return end
    entry.hidden = hidden
    if hidden then
      entry.hiddenIndex = #hiddenEntries + 1; hiddenEntries[entry.hiddenIndex] = entry
    elseif entry.hiddenIndex then
      local index = entry.hiddenIndex; local last = hiddenEntries[#hiddenEntries]
      hiddenEntries[index] = last
      if last then last.hiddenIndex = index end
      hiddenEntries[#hiddenEntries] = nil; entry.hiddenIndex = nil
    end
    hiddenCount += if hidden then 1 else -1
    services.OnHidden(entry.object, hidden)
  end
  local function forget(object)
    local entry = records[object]
    if not entry then return end
    setHidden(entry, false); records[object] = nil
    trackedCount -= 1; local chunk = entry.chunk
    local last = chunk.parts[#chunk.parts]; chunk.parts[entry.index] = last
    if last then last.index = entry.index end
    chunk.parts[#chunk.parts] = nil
    if #chunk.parts == 0 then
      chunks[chunk.key] = nil; local lastChunk = chunkList[#chunkList]
      chunkList[chunk.index] = lastChunk
      if lastChunk then lastChunk.index = chunk.index end
      chunkList[#chunkList] = nil
      if work and work.chunk == chunk then work = nil end
    end
  end
  local function lobbyRoot()
    local root = Workspace:FindFirstChild("Game"); return root and root:FindFirstChild("Lobby")
  end
  local function updateLobby()
    local root = lobbyRoot(); local lives = tonumber(player:GetAttribute("Lives")) or 0
    local hidden = active and option("HideLobbyInMatch", true) and Workspace:GetAttribute("MatchStatus") == 6 and lives > 0 and root ~= nil
    if hidden ~= lobbyHidden or root ~= lastLobby then lobbyHidden, lastLobby = hidden, root; services.OnLobbyHidden(hidden, root) end
  end
  local modelBounds = setmetatable({}, { __mode = "k" })
  local function visualBounds(object)
    if object:IsA("BasePart") and not object:IsA("Terrain") then return object.Position, boundsHalf(object.CFrame, object.Size) end
    if object:IsA("Explosion") then return object.Position, Vector3.zero end
    if object:IsA("Beam") or object:IsA("Trail") then
      local first, second = object.Attachment0, object.Attachment1
      if first and second then local a, b = first.WorldPosition, second.WorldPosition; return (a + b) * 0.5, Vector3.new(math.abs(a.X - b.X), math.abs(a.Y - b.Y), math.abs(a.Z - b.Z)) * 0.5 end
    end
    local subject = object
    if object:IsA("Highlight") or object:IsA("BillboardGui") or object:IsA("SurfaceGui") or object:IsA("PVAdornment") then subject = object.Adornee or object.Parent end
    while subject and subject ~= Workspace do
      if subject:IsA("Attachment") then return subject.WorldPosition, Vector3.zero end
      if subject:IsA("BasePart") then return subject.Position, boundsHalf(subject.CFrame, subject.Size) end
      if subject:IsA("Model") then
        local cached = modelBounds[subject]
        if not cached then
          local frame, size = subject:GetBoundingBox(); cached = { frame.Position, boundsHalf(frame, size) }
          modelBounds[subject] = cached
        end
        return cached[1], cached[2]
      end
      subject = subject.Parent
    end
  end
  local function eligible(object)
    return (object:IsA("BasePart") and not object:IsA("Terrain"))
      or object:IsA("ParticleEmitter")
      or object:IsA("Beam")
      or object:IsA("Trail")
      or object:IsA("Smoke")
      or object:IsA("Fire")
      or object:IsA("Sparkles")
      or object:IsA("Light")
      or object:IsA("Highlight")
      or object:IsA("ForceField")
      or object:IsA("Explosion")
      or object:IsA("BillboardGui")
      or object:IsA("SurfaceGui")
      or object:IsA("PVAdornment")
      or object:IsA("Humanoid")
      or object:IsA("Decal")
      or object:IsA("Texture")
  end
  local function register(object)
    if records[object] then return end
    if not eligible(object) then return end
    local position = visualBounds(object) or Vector3.zero; local size = 64
    local x, y, z = math.floor(position.X / size), math.floor(position.Y / size), math.floor(position.Z / size); local key = x .. ":" .. y .. ":" .. z
    local chunk = chunks[key]
    if not chunk then
      chunk = {
        key = key,
        index = #chunkList + 1,
        parts = {},
      }

      chunks[key], chunkList[chunk.index] = chunk, chunk
    end
    local entry = { object = object, position = position, chunk = chunk, index = #chunk.parts + 1, hidden = false }; chunk.parts[entry.index], records[object] = entry, entry
    trackedCount += 1
    if cameraSnapshot then
      local actualPosition, half = visualBounds(object)
      if actualPosition then entry.reason, entry.outsideSince = renderDecision(actualPosition, half, nil, nil, os.clock(), cameraSnapshot, false); setHidden(entry, entry.reason ~= nil) end
    end
  end
  local function enqueue(object)
    if not active or not option("CullEnabled", true) or queued[object] then return end
    tail += 1; pending[tail], queued[object] = object, true
  end
  local function nextNode()
    if head <= tail then
      local object = pending[head]; pending[head], queued[object] = nil, nil
      head += 1
      if head > tail then pending, head, tail = {}, 1, 0 end
      return object, false
    end
    while #stack > 0 do
      local frame = stack[#stack]; local object = frame.items[frame.index]
      if not object then stack[#stack] = nil; continue end
      frame.index += 1; return object, true
    end
    return nil, false
  end
  local function currentOptions(camera)
    local aspect = camera.ViewportSize.X / math.max(camera.ViewportSize.Y, 1); local margin = math.rad(option("CullViewDegrees", PROFILE.CullViewDegrees))
    local vertical = math.rad(camera.FieldOfView * 0.5); local horizontal = math.atan(math.tan(vertical) * aspect)
    return {
      CullDistance = option("CullDistance", PROFILE.CullDistance),
      CullKeepNear = option("CullKeepNear", PROFILE.CullKeepNear),
      CullView = option("CullView", true),
      CullViewPadding = option("CullViewPadding", PROFILE.CullViewPadding),
      CullHideDelay = option("CullHideDelay", PROFILE.CullHideDelay),
      ViewTanX = math.tan(math.min(math.rad(89), horizontal + margin)),
      ViewTanY = math.tan(math.min(math.rad(89), vertical + margin)),
      CullVertical = option("CullVertical", false),
      CullAbove = option("CullAbove", PROFILE.CullAbove),
      CullBelow = option("CullBelow", PROFILE.CullBelow),
      CullVerticalMargin = option("CullVerticalMargin", PROFILE.CullVerticalMargin),
    }
  end
  local function processChunk(now)
    if not work then
      if stepsLeft <= 0 or #chunkList == 0 then cycling = false; return false end
      if chunkIndex > #chunkList then chunkIndex = 1 end
      local chunk = chunkList[chunkIndex]; chunkIndex += 1
      stepsLeft -= 1; work = { chunk = chunk, index = 1 }
    end
    local job = work; local entry = job.chunk.parts[job.index]
    if not entry then work = nil; return true end
    local object = entry.object
    if not object.Parent then
      forget(object)
    else
      local position, half = visualBounds(object)
      local reason, outsideSince
      if position then reason, outsideSince = renderDecision(position, half, entry.reason, entry.outsideSince, now, cameraSnapshot, now < holdUntil) end
      entry.reason, entry.outsideSince = reason, outsideSince; setHidden(entry, reason ~= nil)
      job.index += 1
    end
    return true
  end
  function controller:Tick(now, camera)
    table.clear(modelBounds)
    if not active or not alive or not option("CullEnabled", true) then return end
    local deadline = os.clock() + option("CullBudgetMs", 2) / 1000; local count = 0
    local scanDeadline = os.clock() + option("CullBudgetMs", 2) / 2000
    while count < 80 and os.clock() < scanDeadline do
      local object, descend = nextNode()
      if not object then break end
      if inScope(object) then
        if descend then
          local children = object:GetChildren()
          if #children > 0 then stack[#stack + 1] = { items = children, index = 1 } end
        end
        register(object)
      end
      count += 1
    end
    if not camera then return end
    local look = camera.CFrame.LookVector
    if lastLook and look:Dot(lastLook) < 0.75 then holdUntil = now + 0.15; nextCycleAt = 0 end
    lastLook = look
    cameraSnapshot = {
      position = camera.CFrame.Position,
      focus = services.GetFocusPosition and services.GetFocusPosition(),
      look = look,
      right = camera.CFrame.RightVector,
      up = camera.CFrame.UpVector,
      options = currentOptions(camera),
    }

    lastCameraFrame = camera.CFrame; cameraSnapshot.planes = cameraPlanes(cameraSnapshot)
    if services.GetFocusY then cameraSnapshot.options.CullAnchorY = services.GetFocusY() end
    if services.GetFloorY then cameraSnapshot.options.CullFloorY = services.GetFloorY() end
    if not active or not alive then return end
    local restoreLimit = math.min(#hiddenEntries, 32); local restoreDeadline = os.clock() + math.max(0, deadline - os.clock()) * 0.5
    for _ = 1, restoreLimit do
      if #hiddenEntries == 0 or os.clock() >= restoreDeadline then break end
      if hiddenCursor > #hiddenEntries then hiddenCursor = 1 end
      local entry = hiddenEntries[hiddenCursor]; local object = entry.object
      if not object.Parent then
        forget(object)
      else
        local position, half = visualBounds(object); local reason = position and renderDecision(position, half, entry.reason, entry.outsideSince, now, cameraSnapshot, now < holdUntil)
        if not reason then entry.reason, entry.outsideSince = nil, nil; setHidden(entry, false) else hiddenCursor += 1 end
      end
    end
    if not cycling and now >= nextCycleAt then cycling, stepsLeft = true, #chunkList; nextCycleAt = now + option("CullInterval", PROFILE.CullInterval) end
    while cycling and count < 160 and os.clock() < deadline do
      if not processChunk(now) then break end
      count += 1
    end
  end
  local function clearSpatial()
    for _, entry in pairs(records) do
      setHidden(entry, false)
    end
    records, chunks, chunkList, stack, pending, queued = {}, {}, {}, {}, {}, {}; head, tail, chunkIndex, trackedCount = 1, 0, 1, 0
    work, cycling, lastLook = nil, false, nil; nextCycleAt, elapsed = 0, 1
    hiddenEntries, hiddenCursor, lastCameraFrame = {}, 1, nil
  end
  local function refreshDriver()
    if driver then driver:Disconnect(); driver = nil end
    if not active or not option("CullEnabled", true) then return end
    driver = services.RunService.Heartbeat:Connect(function(dt)
      elapsed += dt
      if elapsed >= option("CullInterval", 0.1) then elapsed = 0; controller:Tick(os.clock(), Workspace.CurrentCamera) end
    end)
  end
  function controller:SetEnabled(value)
    if not alive then return end
    active = value; clearSpatial()
    if active and option("CullEnabled", true) then stack = { { items = table.clone(roots), index = 1 } } end
    updateLobby(); refreshDriver()
    if active then self:Tick(os.clock(), Workspace.CurrentCamera) end
  end
  function controller:Refresh()
    if not active then return end
    nextCycleAt, cycling, work = 0, false, nil; updateLobby()
  end
  function controller:GetStatus()
    return { Tracked = trackedCount, Hidden = hiddenCount, Chunks = #chunkList, LobbyHidden = lobbyHidden, Indexing = #stack > 0 or head <= tail }
  end
  function controller:Destroy()
    if not alive then return end
    self:SetEnabled(false); alive = false
    for _, connection in ipairs(connections) do
      connection:Disconnect()
    end
  end
  for _, root in ipairs(roots) do
    connections[#connections + 1] = root.DescendantAdded:Connect(function(object)
      enqueue(object)
      if object.Name == "Lobby" then updateLobby() end
    end)
    connections[#connections + 1] = root.DescendantRemoving:Connect(function(object) forget(object) end)
  end
  connections[#connections + 1] = Workspace:GetAttributeChangedSignal("MatchStatus"):Connect(updateLobby)
  connections[#connections + 1] = player:GetAttributeChangedSignal("Lives"):Connect(updateLobby); return controller
end
local function applyScenePolicy(object, target, watch, options, masks, lobbyHidden, lobby)
  if masks[object] then
    if object:IsA("BasePart") then target.LocalTransparencyModifier = 1
    elseif object:IsA("Decal") or object:IsA("Texture") then target.Transparency = 1
    elseif object:IsA("Humanoid") then target.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    elseif object:IsA("ForceField") or object:IsA("Explosion") or object:IsA("PVAdornment") then target.Visible = false
    else target.Enabled = false end
    watch = not object:IsA("BasePart")
  end
  if lobbyHidden and lobby and object:IsDescendantOf(lobby) then
    if object:IsA("BasePart") and not object:IsA("Terrain") then
      target.LocalTransparencyModifier = 1
    elseif
      object:IsA("BillboardGui")
      or object:IsA("SurfaceGui")
      or object:IsA("Highlight")
      or object:IsA("Light")
      or object:IsA("ParticleEmitter")
      or object:IsA("Trail")
      or object:IsA("Beam")
      or object:IsA("Smoke")
      or object:IsA("Fire")
      or object:IsA("Sparkles")
    then
      target.Enabled = false
    end
  end
  return target, watch
end

-- lifecycle
local session, observer, shutdown
local working, revision = false, 0
local function setting(key)
  local value = Utils and Utils.getConfigValue(key)
  if value == nil then return CONFIG.defaults[key] end
  return value
end
local function requestedProfile()
  local profile = table.clone(PROFILE); local distance = tonumber(setting("AntiLagRenderDistance"))
  if not distance or distance ~= distance or math.abs(distance) == math.huge then distance = CONFIG.defaults.AntiLagRenderDistance end
  profile.CullDistance = math.clamp(distance, 1, 1200); local removeEffects = setting("AntiLagRemoveEffects") == true
  profile.GameSwordSounds = not setting("AntiLagRemoveSwordSounds"); profile.HideLobbyInMatch = setting("AntiLagHideLobby")
  profile.Particles, profile.TrailsAndBeams, profile.LegacyEffects = removeEffects, removeEffects, removeEffects; profile.GameNoVFX, profile.GameReducedUI = removeEffects, removeEffects
  return profile
end
local function loadNativeModules(owner)
  if not owner.compatible then return end
  for _, spec in ipairs({
    { "VFX", "Core", "VFX", "VFX" },
    { "SFX", "Core", "SFX", "SFX" },
    { "LowQuality", "Core", "LowQuality", "LowQuality" },
    { "VFXBudget", "Core", "VFXBudget" },
    { "WindowAnim", "UI", "WindowAnim" },
  }) do
    task.spawn(function()
      local deadline, nativeModule = os.clock() + 10, nil
      repeat
        if owner.closed then return end
        local shared = owner.replicated:FindFirstChild("Shared"); local branch = shared and shared:FindFirstChild(spec[2])
        nativeModule = branch and branch:FindFirstChild(spec[3])
        if nativeModule then break end
        task.wait(0.25)
      until os.clock() >= deadline
      if owner.closed or not nativeModule or not nativeModule:IsA("ModuleScript") then return end
      local ok, result = pcall(require, nativeModule)
      if owner.closed then return end
      if ok and type(result) == "table" then
        owner.adapter:SetModule(spec[1], if spec[4] then result[spec[4]] else result)
      else
        warn("[Exodus AntiLag] Adaptador indisponível: " .. spec[1])
      end
    end)
  end
end
local function startSession()
  local player = Utils.getLocalPlayer(); assert(player, "LocalPlayer indisponível")
  local workspace = game:GetService("Workspace"); local lighting, runService = game:GetService("Lighting"), game:GetService("RunService")
  local replicated = game:GetService("ReplicatedStorage")
  local owner = {
    masks = setmetatable({}, { __mode = "k" }),
    closed = false,
    lobbyHidden = false,
    profile = requestedProfile(),
    runService = runService,
    replicated = replicated,
    compatible = game.PlaceId == 12979690461 or runService:IsStudio(),
  }

  session = owner
  local gameSettings
  pcall(function() gameSettings = UserSettings():GetService("UserGameSettings") end)
  local visualRoots = { workspace }; local playerGui = player:FindFirstChildOfClass("PlayerGui")
  if playerGui then visualRoots[#visualRoots + 1] = playerGui end
  local optimizerRoots = table.clone(visualRoots); optimizerRoots[#optimizerRoots + 1], optimizerRoots[#optimizerRoots + 2] = lighting, game:GetService("SoundService")
  owner.engine = createOptimizer({
    Workspace = workspace,
    Lighting = lighting,
    RunService = runService,
    CollectionService = game:GetService("CollectionService"),
    GameSettings = gameSettings,
    Roots = optimizerRoots,
    ExtraPolicy = function(object, target, watch, options)
      if owner.compatible then target, watch = applyGamePolicy(object, target, watch, options) end
      return applyScenePolicy(object, target, watch, options, owner.masks, owner.lobbyHidden, owner.lobby)
    end,
  }, owner.profile)
  local function getOption(key) return owner.engine:GetOption(key) end
  if owner.compatible then
    local scripts = player:FindFirstChild("PlayerScripts") or player:WaitForChild("PlayerScripts", 10); assert(scripts, "PlayerScripts indisponível")
    owner.adapter = createGameAdapter({ Workspace = workspace, Player = player, PlayerScripts = scripts }, getOption)
  end
  local function viewedCharacter() return player.Character end
  owner.spatial = createSpatialController({
    Workspace = workspace,
    Roots = visualRoots,
    Player = player,
    RunService = runService,
    GetFocusY = function()
      local character = viewedCharacter(); local root = character and character:FindFirstChild("HumanoidRootPart")
      return root and root.Position.Y or nil
    end,
    GetFloorY = function()
      local character = viewedCharacter(); local humanoid = character and character:FindFirstChildOfClass("Humanoid")
      local root = character and character:FindFirstChild("HumanoidRootPart")
      if root and humanoid and humanoid.Health > 0 then
        local footY = root.Position.Y - humanoid.HipHeight - root.Size.Y * 0.5; owner.floorY = owner.floorY and math.min(owner.floorY, footY) or footY
      end
      return owner.floorY and owner.floorY - 2 or nil
    end,
    GetFocusPosition = function()
      local character = viewedCharacter(); local root = character and character:FindFirstChild("HumanoidRootPart")
      return root and root.Position or nil
    end,
    OnHidden = function(object, hidden)
      owner.masks[object] = if hidden then true else nil
      owner.engine:RefreshInstance(object, true)
      if hidden and (object:IsA("ParticleEmitter") or object:IsA("Trail")) then
        pcall(function() object:Clear() end)
      end
    end,
    OnLobbyHidden = function(hidden, lobby)
      local previous = owner.lobby; owner.lobbyHidden, owner.lobby = hidden, lobby
      if previous then owner.engine:RefreshSubtree(previous) end
      if lobby and lobby ~= previous then owner.engine:RefreshSubtree(lobby) end
    end,
  }, getOption)
  owner.engine:SetEnabled(true)
  if owner.adapter then owner.adapter:SetEnabled(true) end
  owner.spatial:SetEnabled(true); loadNativeModules(owner)
end
local function stopSession()
  local owner = session
  if not owner then return end
  owner.closed = true
  if owner.spatial then owner.spatial:Destroy() end
  if owner.adapter then owner.adapter:Destroy() end
  if owner.engine then
    owner.engine:Destroy()
    while owner.engine:GetStatus().Alive do
      owner.runService.Heartbeat:Wait()
    end
  end
  if session == owner then session = nil end
end
local function updateSession()
  local profile, owner = requestedProfile(), session; local spatialChanged = profile.CullDistance ~= owner.profile.CullDistance or profile.HideLobbyInMatch ~= owner.profile.HideLobbyInMatch
  for key, value in pairs(profile) do
    if owner.profile[key] ~= value then owner.engine:SetOption(key, value) end
  end
  owner.profile = profile
  if owner.adapter then owner.adapter:Refresh() end
  if spatialChanged then owner.spatial:Refresh() end
end
local function reconcile()
  revision += 1
  if working then return end
  working = true
  task.defer(function()
    local seen
    repeat
      seen = revision
      local ok, err = pcall(function()
        if Utils and Utils.isActive() and setting("AntiLagEnabled") then
          if session then updateSession() else startSession() end
        else
          stopSession()
        end
      end)
      if not ok then
        local reporting = Utils; local cleaned, cleanupError = pcall(stopSession)
        if reporting then reporting.recordError("AntiLag", tostring(err)) end
        if not cleaned then warn("[Exodus AntiLag] Falha ao restaurar: " .. tostring(cleanupError)) end
      end
    until seen == revision
    working = false
  end)
end

-- public-api
function AntiLag.setEnabled(enabled)
  if not Utils then return false, "recurso indisponível" end
  return Utils.setConfig({ AntiLagEnabled = enabled == true })
end
function AntiLag.getStatus()
  local owner = session
  return {
    enabled = owner ~= nil and not owner.closed,
    busy = working,
    engine = owner and owner.engine and owner.engine:GetStatus() or nil,
    spatial = owner and owner.spatial and owner.spatial:GetStatus() or nil,
    generators = owner and owner.adapter and owner.adapter:GetStatus() or nil,
  }
end
function AntiLag.teardown()
  local previous = Utils; Utils = nil
  revision += 1
  if observer then observer:Disconnect(); observer = nil end
  if shutdown then
    shutdown.Connected = false
    if previous then previous.untrackGlobal(shutdown) end
    shutdown = nil
  end
  while working do
    game:GetService("RunService").Heartbeat:Wait()
  end
  stopSession(); return true
end
function AntiLag.setup(deps)
  if type(deps) ~= "table" or type(deps.Utils) ~= "table" or type(deps.GameInfo) ~= "table" then return false, "dependência ausente: Utils ou GameInfo" end
  AntiLag.teardown(); Utils, GameInfo = deps.Utils, deps.GameInfo
  observer = Utils.observeConfig(function(changes)
    for key in pairs(changes) do
      if CONFIG.schema[key] then
        if session or setting("AntiLagEnabled") then reconcile() end
        return
      end
    end
  end)
  shutdown = { Connected = true }
  function shutdown:Disconnect()
    if not self.Connected then return end
    self.Connected = false; AntiLag.teardown()
  end
  Utils.trackGlobal(shutdown)
  if setting("AntiLagEnabled") then reconcile() end
  return true
end
AntiLag.__config = CONFIG
AntiLag.__contract = {
  requires = {
    Utils = "utils",
    GameInfo = "gameinfo",
  },
  requiresMethods = {
    GameInfo = { "getBall" },
    Utils = { "getConfigValue", "setConfig", "getLocalPlayer", "isActive", "observeConfig", "trackGlobal", "untrackGlobal", "recordError" },
  },
  provides = { "setup", "teardown", "setEnabled", "getStatus" },
}

return AntiLag
