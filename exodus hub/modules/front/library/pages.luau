-- [[ uipages ]]

-- module
local Pages = {}

-- configuration
local CONFIG = { COLUMNS = { [1] = true, [2] = true } }

-- setup
function Pages.setup() return true end

-- validation
function Pages.validate(definitions, components)
  assert(type(definitions) == "table" and #definitions > 0, "UI pages must be a non-empty ordered list"); local ids, normal = {}, 0
  for _, page in ipairs(definitions) do
    assert(type(page.id) == "string" and page.id ~= "" and not ids[page.id], "UI page id must be unique")
    assert(type(page.title) == "string" and type(page.sections) == "table", "UI page requires title and sections: " .. page.id)
    assert(CONFIG.COLUMNS[page.columns], "UI page columns must be 1 or 2: " .. page.id); ids[page.id] = true
    if not page.utility then normal += 1 end
    local keys, parents = {}, {}
    for _, section in ipairs(page.sections) do
      assert((section.column or 1) >= 1 and (section.column or 1) <= page.columns, "Invalid column in " .. page.id)
      for _, definition in ipairs(section.components or {}) do
        assert(type(components[definition.kind]) == "function", "Unknown UI component: " .. tostring(definition.kind) .. " in " .. page.id)
        if definition.key then assert(not keys[definition.key], "Duplicate UI key in " .. page.id .. ": " .. definition.key); keys[definition.key] = true end
        if definition.parentKey then parents[definition.key or definition] = definition.parentKey end
      end
    end
    for key, parent in pairs(parents) do
      local visited = { [key] = true }
      while parent do
        assert(keys[parent] and not visited[parent], "Missing or cyclic parentKey in " .. page.id); visited[parent] = true
        parent = parents[parent]
      end
    end
  end
  assert(normal > 0, "UI needs at least one primary page"); return true
end

-- rendering
function Pages.create(kit, parent, definitions, context)
  context = context or {}; context.read = context.read or kit.read
  Pages.validate(definitions, kit.Components); local T, inst = kit.Theme, kit.instance
  local width = T.PANEL_W - T.PAD * 2; local height = T.PANEL_H - T.TITLE_H - 60
  local origin = UDim2.fromOffset(T.PAD, T.TITLE_H + T.PAD); local registry, normal, rows, bindings = {}, {}, {}, {}
  local active, returnId, generation = nil, nil, 0; local tweens, transitioning = {}, false
  local alive = true; local controller = {}
  local lifetime = kit.scope.child(); local motion = kit.createMotion(lifetime)
  local refreshDisclosure
  local function list(parent, gap)
    return inst(
      "UIListLayout",
      { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap or T.CARD_GAP), HorizontalAlignment = Enum.HorizontalAlignment.Center },
      parent
    )
  end
  local function stack(parent, name)
    local root =
      inst("Frame", { Name = name, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, ZIndex = 6 }, parent)
    list(root); return root
  end
  local function included(definition) return not (context.desktop and definition.mobileOnly) and not (not context.desktop and definition.desktopOnly) end
  for _, definition in ipairs(definitions) do
    local root = inst("CanvasGroup", {
      Name = "Page_" .. definition.id,
      Size = UDim2.fromOffset(width, height),
      Position = origin,
      BackgroundTransparency = 1,
      Visible = false,
      GroupTransparency = 1,
      ClipsDescendants = true,
      ZIndex = 6,
    }, parent)
    local page = { Root = root, definition = definition, columns = {}, rows = {} }; registry[definition.id] = page
    if not definition.utility then normal[#normal + 1] = definition.id end
    local pageWidth = definition.width or width; local columnWidth = (pageWidth - T.GAP * (definition.columns - 1)) / definition.columns
    for column = 1, definition.columns do
      local scroll = inst("ScrollingFrame", {
        Name = "Column" .. column,
        Size = UDim2.fromOffset(columnWidth, height),
        Position = UDim2.fromOffset((width - pageWidth) / 2 + (column - 1) * (columnWidth + T.GAP), 0),
        BackgroundTransparency = 1,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = T.SCROLLBAR,
        ScrollBarImageColor3 = T.COLORS.accent,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ClipsDescendants = true,
        Active = true,
        ZIndex = 6,
      }, root)
      inst(
        "UIPadding",
        { PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, T.CARD_GAP) },
        scroll
      )
      list(scroll); page.columns[column] = scroll
    end
    local keyed, pending = {}, {}
    for sectionIndex, section in ipairs(definition.sections) do
      if included(section) then
        local sectionRoot = stack(page.columns[section.column or 1], "Section" .. sectionIndex); sectionRoot.LayoutOrder = sectionIndex
        if section.title then local label = kit.Components.label(sectionRoot, { text = section.title }); label.Root.LayoutOrder = 0 end
        for index, source in ipairs(section.components or {}) do
          if included(source) then
            local options = table.clone(source)
            if context.resolve then options = context.resolve(options) or options end
            local row = stack(sectionRoot, "Row_" .. tostring(source.key or source.action or index)); row.LayoutOrder = index
            local handle = kit.Components[options.kind](row, options); handle.Root.LayoutOrder = 0
            local entry = { Root = row, handle = handle, definition = source, parentKey = source.parentKey }; rows[#rows + 1] = entry
            page.rows[#page.rows + 1] = entry
            if source.key then keyed[source.key] = entry; bindings[source.key] = handle end
            if source.parentKey then pending[#pending + 1] = entry end
            if context.onComponent then context.onComponent(source, handle) end
          end
        end
      end
    end
    for _, entry in ipairs(pending) do
      local owner = keyed[entry.parentKey]; assert(owner, "Visible child requires a visible parent: " .. entry.parentKey)
      if not owner.children then
        owner.children = inst("CanvasGroup", {
          Name = "Children",
          Size = UDim2.new(1, -12, 0, 0),
          BackgroundTransparency = 1,
          GroupTransparency = 1,
          Visible = false,
          ClipsDescendants = true,
          LayoutOrder = 1,
          ZIndex = 6,
        }, owner.Root)
        owner.childContent = stack(owner.children, "Content"); local layout = owner.childContent:FindFirstChildOfClass("UIListLayout")
        inst("UIPadding", {
          PaddingTop = UDim.new(0, T.CHILD_VERTICAL_PADDING),
          PaddingBottom = UDim.new(0, T.CHILD_VERTICAL_PADDING),
        }, owner.childContent)
        lifetime.connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
          if refreshDisclosure then refreshDisclosure(entry.parentKey, owner) end
        end)
      end
      entry.Root.Parent = owner.childContent
    end
    page.keyed = keyed
  end
  local shield = inst("TextButton", {
    Name = "PageInputShield",
    Size = UDim2.fromOffset(width, height),
    Position = origin,
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
    Visible = false,
    ZIndex = 20,
  }, parent)
  local function cancel()
    generation += 1
    for _, tween in ipairs(tweens) do
      motion.cancel(tween)
    end
    tweens = {}
  end
  local function settle()
    for id, page in pairs(registry) do
      page.Root.Visible = id == active; page.Root.GroupTransparency = id == active and 0 or 1
      page.Root.Position = origin
    end
    transitioning = false; shield.Visible = false
  end
  local function notify()
    if context.onNavigate then context.onNavigate(controller.state()) end
  end
  function controller.state()
    local index = table.find(normal, active); return { id = active, title = registry[active].definition.title, index = index, count = #normal, utility = index == nil, transitioning = transitioning }
  end
  function controller.select(id, animated)
    assert(registry[id], "Unknown UI page: " .. tostring(id))
    if not alive or kit.suspended or (id == active and animated ~= false) then return end
    kit.dismiss(); cancel()
    local old = active; local oldIndex, nextIndex = table.find(normal, old), table.find(normal, id)
    local direction = oldIndex and nextIndex and (nextIndex > oldIndex and 1 or -1) or (nextIndex and -1 or 1)
    if oldIndex and not nextIndex then returnId = old end
    active = id
    if not old or animated == false then
      settle(); notify()
      return
    end
    transitioning = true; shield.Visible = true
    notify(); local revision = generation
    local pending = 0; local targets = {}
    for key, page in pairs(registry) do
      local root = page.Root
      if key == active then
        if not root.Visible then root.Position = UDim2.fromOffset(T.PAD + T.PAGE_OFFSET * direction, T.TITLE_H + T.PAD); root.GroupTransparency = 1 end
        root.Visible = true; targets[#targets + 1] = { root = root, position = origin, transparency = 0 }
      elseif root.Visible then
        targets[#targets + 1] = { root = root, position = UDim2.fromOffset(T.PAD - T.PAGE_OFFSET * direction, T.TITLE_H + T.PAD), transparency = 1 }
      end
    end
    pending = #targets
    local function complete()
      if not alive or revision ~= generation then return end
      pending -= 1
      if pending == 0 then
        tweens = {}; settle()
        notify()
      end
    end
    for _, target in ipairs(targets) do
      local tween = motion.play(target.root, "page", { Position = target.position, GroupTransparency = target.transparency }, complete)
      if tween then tweens[#tweens + 1] = tween end
    end
  end
  function controller.step(direction)
    local index = table.find(normal, active)
    if index then controller.select(normal[math.clamp(index + direction, 1, #normal)]) end
  end
  function controller.toggle(id)
    if active == id then controller.select(returnId or normal[1]) else controller.select(id) end
  end
  refreshDisclosure = function(key, owner, immediate)
    local expanded = context.read and context.read(key) == true or false; local layout = owner.childContent:FindFirstChildOfClass("UIListLayout")
    local scale, ancestor = 1, owner.childContent
    while ancestor do
      for _, child in ipairs(ancestor:GetChildren()) do
        if child:IsA("UIScale") then scale *= child.Scale end
      end
      ancestor = ancestor.Parent
    end
    local height = expanded and (layout.AbsoluteContentSize.Y / math.max(scale, 0.001) + T.CHILD_VERTICAL_PADDING * 2) or 0
    if not immediate and owner.expanded == expanded and owner.targetHeight == height then return end
    owner.expanded, owner.targetHeight = expanded, height; owner.revision = (owner.revision or 0) + 1
    local revision = owner.revision
    if expanded then owner.children.Visible = true end
    motion.play(owner.children, immediate and 0 or "control", {
      Size = UDim2.new(1, -12, 0, height),
      GroupTransparency = expanded and 0 or 1,
    }, function()
      if alive and revision == owner.revision then owner.children.Visible = expanded end
    end)
  end
  function controller.refresh()
    for _, entry in ipairs(rows) do
      local definition = entry.definition; local visible = not definition.abilityOnly or not context.abilitiesEnabled or context.abilitiesEnabled()
      if definition.visibleWhen and context.read then visible = visible and context.read(definition.visibleWhen) == true end
      entry.Root.Visible = visible
    end
    for _, page in pairs(registry) do
      for key, owner in pairs(page.keyed) do
        if owner.children then refreshDisclosure(key, owner, owner.expanded == nil) end
      end
    end
  end
  function controller.get(id) return registry[id] end
  function controller.getControl(key) return bindings[key] end
  function controller.snapshot()
    local snapshot = { page = active, returnId = returnId, scroll = {} }
    for id, page in pairs(registry) do
      snapshot.scroll[id] = {}
      for index, column in ipairs(page.columns) do
        snapshot.scroll[id][index] = column.CanvasPosition
      end
    end
    return snapshot
  end
  function controller.restore(snapshot)
    if not snapshot then return end
    if snapshot.page and registry[snapshot.page] then controller.select(snapshot.page, false) end
    if snapshot.returnId and registry[snapshot.returnId] then returnId = snapshot.returnId end
    for id, columns in pairs(snapshot.scroll or {}) do
      if registry[id] then
        for index, position in ipairs(columns) do
          if registry[id].columns[index] and typeof(position) == "Vector2" then registry[id].columns[index].CanvasPosition = position end
        end
      end
    end
  end
  function controller.suspend()
    cancel(); settle()
    for _, page in pairs(registry) do
      for key, owner in pairs(page.keyed) do
        if owner.children then refreshDisclosure(key, owner, true) end
      end
    end
  end
  function controller.destroy()
    if not alive then return end
    alive = false; cancel()
    lifetime.destroy(); kit.scope.remove(controller.destroy)
    for _, page in pairs(registry) do
      for _, entry in ipairs(page.rows) do
        entry.handle.destroy()
      end
      page.Root:Destroy()
    end
    shield:Destroy()
  end
  lifetime.add(kit.observe(controller.refresh)); kit.scope.add(controller.destroy)
  controller.select(context.initialPage or normal[1], false); controller.refresh()
  return controller
end

-- contract
Pages.__contract = { provides = { "setup", "validate", "create" }, requires = {} }

return Pages
