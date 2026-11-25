-- Run from the FluxLogistics root. Production planner, logistics, profit and graph
-- modules run on generated recipes and the repository's desktop UI host fixture.
-- An optional first argument overlays captured versions of these production modules.
local originalLoad, captured = loadfile, arg[1]
if captured then
    local overlay = {Planner = true, Logistics = true, RecipeList = true, RecipeProfit = true, Graph = true, UI = true}
    loadfile = function(path)
        local module = path:match("^FluxCraft/(%a+)%.lua$")
        if overlay[module] then return originalLoad(captured .. "/" .. module .. ".lua") end
        return originalLoad(path)
    end
end
local ns, flushWorkspace, _, events = dofile("Tests/ui_fixture.lua")("forever")
loadfile = originalLoad
local workspaceTimer = C_Timer
local actor = ns.state.characterKey
local catalog = {revision = 1, characterKey = actor, recipesById = {}, byOutput = {}}
local count, quotes, inventory = 0, {}, {}

local function recipe(id, output, yield, profession, inputIDs)
    local inputs = {}
    for i, itemID in ipairs(inputIDs) do
        inputs[i] = {itemID = itemID, quantity = 1, slotIndex = i}
    end
    local data = {id = id, recipeID = id, characterKey = actor, professionId = profession,
        outputItemID = output, outputKind = "item", yield = yield, learned = true, completeness = "complete",
        name = "Fixture technique " .. id, reagents = inputs}
    catalog.recipesById[id] = data
    local outputRecipes = catalog.byOutput[output] or {}
    catalog.byOutput[output] = outputRecipes
    outputRecipes[#outputRecipes + 1] = id
    count = count + 1
    return data
end

local function price(itemID, copper)
    quotes[itemID] = {itemID = itemID, unit = "item", unitPrice = copper, source = "fixture"}
end

for i = 1, 48 do
    price(30000 + i, 100 + i * 3)
    inventory[30000 + i] = i % 3
    price(20000 + i, 230 + i * 8)
    recipe(2000 + i, 20000 + i, 2, i % 2 + 5, {30000 + i, 30000 + (i % 48 + 1)})
    if i % 4 == 0 then
        recipe(3000 + i, 20000 + i, 1, (i + 1) % 2 + 5, {30000 + (i % 48 + 1)})
    end
end

local finalCount = 1536
for i = 1, finalCount do
    local primary = (i * 7) % 48 + 1
    price(10000 + i, 11000 + i * 11)
    recipe(i, 10000 + i, i % 3 + 1, i % 2 + 5, {20000 + primary, 20000 + (primary % 48 + 1), 30000 + primary})
end

local deepChoices, graphRecipeID = {}, 4000
local function graphRecipe(depth)
    graphRecipeID = graphRecipeID + 1
    local id = graphRecipeID
    local itemID = 40000 + id
    price(itemID, 1000 + id)
    if depth > 0 then
        local children = {}
        for i = 1, 3 do children[i] = graphRecipe(depth - 1) end
        recipe(id, itemID, 1, id % 2 + 5, children)
        deepChoices[itemID] = {source = "Make"}
    end
    return itemID, id
end

local _, rootID = graphRecipe(4)

local requests = {stock = 0, quote = 0, maximumItems = 0}
ns.Catalog.Snapshot = function() return catalog end
ns.InventoryAdapter.Snapshot = function(items)
    requests.stock = requests.stock + 1
    requests.maximumItems = math.max(requests.maximumItems, #items)
    local result = {}
    for _, id in ipairs(items) do result[id] = inventory[id] or 0 end
    return result
end
ns.MarketAdapter.QuoteItems = function(items)
    requests.quote = requests.quote + 1
    local result = {}
    for _, id in ipairs(items) do result[id] = quotes[id] end
    return result
end

local maxDepthPlans, maxi = {}, {perTick = 0, plannerMS = 0, visits = 0}
local previews, visits = 0, 0
local original = ns.Planner.Preview
ns.Planner.Preview = function(request, ...)
    local started = os.clock()
    local plan = original(request, ...)
    local elapsed = (os.clock() - started) * 1000
    previews = previews + 1
    maxi.plannerMS = math.max(maxi.plannerMS, elapsed)
    local observed = plan.diagnostics and plan.diagnostics.visited or 0
    visits = visits + observed
    maxi.visits = math.max(maxi.visits, observed)
    assert(plan.tree and plan.summary.valueKnown)
    if request.rootRecipeId == rootID then maxDepthPlans[#maxDepthPlans + 1] = plan end
    return plan
end

local durations = {}
local timers = {}
C_Timer = {After = function(_, callback) timers[#timers + 1] = callback end}
local function drain()
    local frames = 0
    while #timers > 0 do
        local before = previews
        local started = os.clock()
        table.remove(timers, 1)()
        durations[#durations + 1] = (os.clock() - started) * 1000
        local evaluated = previews - before
        maxi.perTick = math.max(maxi.perTick, evaluated)
        assert(evaluated <= 1 and #timers <= 1, "viewport did excess scheduled work")
        frames = frames + 1
        assert(frames <= 25, "the fixture did not settle within one tick per row")
    end
    return frames
end

local list = ProfessionsFrame.CraftingPage.RecipeList
local rowCount, visibleRows, allocations = 22, {}, 0
local function titleWidth(self)
    local label, icons = self:GetText():gsub("|T.-|t", "")
    label = label:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (utf8.len(label) or #label) * 6 + icons * 9
end
local function newFont(frame, width, left, text)
    local field = frame:CreateFontString()
    field:SetWidth(width)
    field:SetText(text or "")
    field.GetLeft = function() return left end
    field.GetStringWidth = titleWidth
    return field
end
local longName = string.rep("Forstærket månelysvævet armstykke ", 3)
for i = 1, rowCount do
    local row = CreateFrame("Button", nil, list)
    row.nativeWidth = 230
    row.GetLeft = function() return 4 end
    row.Label = newFont(row, row.nativeWidth, 35, longName)
    row.Count = newFont(row, 28, 0, " [120] ")
    row.LockedIcon = newFont(row, 16, 0)
    local createFont = row.CreateFontString
    row.CreateFontString = function(self)
        assert(not self.profit, "recycled native row allocated an additional font string")
        allocations = allocations + 1
        local field = createFont(self)
        field.GetStringWidth = titleWidth
        self.profit = field
        return field
    end
    visibleRows[i] = row
end

local function element(row)
    return {GetData = function() return {recipeInfo = {recipeID = row.recipeId, learned = true}} end}
end

local visibleVisits = 0
local scrollBox = {ForEachFrame = function(_, fn)
    for _, row in ipairs(visibleRows) do
        visibleVisits = visibleVisits + 1
        fn(row, element(row))
    end
end}
list.ScrollBox = scrollBox
ScrollUtil = {
    AddInitializedFrameCallback = function(box, fn, owner)
        box.initialized = function(row) fn(owner, row, element(row)) end
    end,
    AddReleasedFrameCallback = function(box, fn, owner)
        box.released = function(row) fn(owner, row, element(row)) end
    end,
}

local function viewport(first, width, initial)
    for i, row in ipairs(visibleRows) do
        if not initial then
            scrollBox.released(row)
            assert(row.Label:GetWidth() == row.nativeWidth, "release left stale recipe-title geometry")
        end
        row.recipeId = first + i - 1
        row:SetWidth(width)
        if not initial then scrollBox.initialized(row) end
    end
    local before = previews
    local frames = drain()
    for _, row in ipairs(visibleRows) do
        assert(row.Label:GetText() == longName, "long recipe label text changed")
        assert(row.Count:GetText() == " [120] ", "native availability changed")
        assert(row.profit:GetText():find("|cff55ff70+", 1, true), "evaluated profit lost its positive value")
        local room = width - 31 - row.Count:GetStringWidth() - row.LockedIcon:GetWidth() - 12
        local profitWidth = row.profit:GetStringWidth()
        local shown = row.profit:IsShown()
        assert(shown == (room - profitWidth >= 56), "profit must leave room for the native title")
        local titleWidth = row.Label:GetWidth()
        assert(titleWidth > 0 and titleWidth + (shown and profitWidth or 0) <= room,
            "recipe title and profit overlap native content")
    end
    return previews - before, frames
end

ns.RecipeProfit.Attach(list, function() return true end)
local cold, frames = viewport(1, 285, true)
assert(cold == rowCount and frames == rowCount)
for _ = 1, 200 do ns.RecipeProfit.Refresh() end
assert(#timers == 1, "same-revision bursts were not coalesced")
local before = previews
assert(drain() == 1 and previews == before, "warm repeated updates reran the planner")
assert(viewport(9, 300) == 8, "overlapping viewport stopped reusing visible cached rows")
for i = 1, 9 do
    assert(viewport(9 + 15 * i, ({285, 332, 396})[(i % 3) + 1]) == 15)
end
assert(viewport(finalCount - rowCount + 1, 396) == rowCount)
assert(viewport(finalCount - rowCount + 1, 118) == 0)
assert(viewport(finalCount - rowCount + 1, 285) == 0)
before = previews
catalog.revision = catalog.revision + 1
ns.RecipeProfit.Refresh()
drain()
assert(previews - before == rowCount and allocations == rowCount)
assert(requests.stock == previews and requests.quote == previews)
local rowPreviews, rowMaxMS, rowMaxVisits, rowTotalVisits, rowItems = previews, maxi.plannerMS, maxi.visits, visits, requests.maximumItems
table.sort(durations)
local p95 = durations[math.ceil(#durations * 0.95)]

local plan, reason = ns.Logistics.Preview({recipeId = rootID, quantity = 1, intent = "additional", choices = deepChoices}, catalog)
assert(plan and not plan.diagnostics.bounded, type(reason) == "string" and reason or "large graph planning bounded")
assert(#plan.tasks == 40)
assert(#maxDepthPlans == 1)
local maxCards, maxLines = 0, 0
local stats = {}
for _, dim in ipairs({{260, 300}, {342, 420}, {460, 560}}) do
    local graph = ns.Graph.New(UIParent, function(id) return longName .. id, 9 end)
    graph.compact = true
    graph.frame:SetSize(dim[1], dim[2])
    local started = os.clock()
    graph:Render(plan.tree, {}, {}, nil, nil, nil, nil)
    assert(#graph.layout == 121 and graph.height < 4500)
    local rowStep = graph.layout[3].y - graph.layout[2].y
    local smallestScale = graph.zoom
    for i = 2, #graph.layout do
        local previous, card = graph.layout[i - 1], graph.layout[i]
        assert(card.y > previous.y + previous.height and card.parent and card.x >= card.parent.x)
    end
    for i = 1, 12 do graph:Pan(0, -700) end
    graph:Zoom(0.2)
    graph:Zoom(-0.1)
    graph:Fit(true)
    graph:Toggle(graph.layout[1].path)
    assert(#graph.layout == 1)
    graph:Toggle(graph.layout[1].path)
    assert(#graph.layout == 121)
    local elapsed = (os.clock() - started) * 1000
    assert(#graph.cards <= math.ceil(dim[2] / (rowStep * smallestScale)) + 3, "graph allocated offscreen cards")
    maxCards, maxLines = math.max(maxCards, #graph.cards), math.max(maxLines, #graph.lines)
    stats[#stats + 1] = ("%dx%d cards=%d segments=%d paint sequence=%.2fms"):format(dim[1], dim[2], #graph.cards, #graph.lines, elapsed)
end

print(("catalog=%d learned recipes across two professions, output list=%d, viewport=%d, cold ticks=%d, evaluations=%d, plans per tick max=%d, pooled prices=%d, visible row visits=%d"):format(
    count, finalCount, rowCount, frames, rowPreviews, maxi.perTick, allocations, visibleVisits))
print(("rows roots up to %d observed items, max %d planner states, total %d states; CPU cold max=%.2fms, timer p95=%.2fms (%d ticks)"):format(
    rowItems, rowMaxVisits, rowTotalVisits, rowMaxMS, p95, #durations))
print(("graph=%d cards / %d craft tasks, %d planner states, maximum %d pooled visible cards / %d line segments; "):format(
    121, #plan.tasks, plan.diagnostics.visited, maxCards, maxLines) .. table.concat(stats, " | "))

C_Timer = workspaceTimer
local work, page = ns.UI, ProfessionsFrame.CraftingPage
local function selectNative(id)
    page.SchematicForm.selectedID = id
    events["Professions.RecipeSelected"](page)
end
selectNative(2)
flushWorkspace()
assert(work.preview and work.preview.rootRecipeId == 2)

local drafts, rowPrices, paints, queuePaints = 0, 0, 0, 0
local preview, paint = ns.Logistics.Preview, work.graph.Paint
ns.Logistics.Preview = function(args, ...)
    if args.previewOnly then rowPrices = rowPrices + 1 else drafts = drafts + 1 end
    return preview(args, ...)
end
work.graph.Paint = function(self)
    paints = paints + 1
    return paint(self)
end
local renderQueue, onExtentChanged = work.RenderQueue, work.graph.onExtentChanged
work.RenderQueue = function(...)
    queuePaints = queuePaints + 1
    return renderQueue(...)
end
work.graph.onExtentChanged = function(...)
    queuePaints = queuePaints + 1
    return onExtentChanged(...)
end
local function measure(label, repetitions, action)
    local startDrafts, startRowPrices, startPaints = drafts, rowPrices, paints
    local started = os.clock()
    for index = 1, repetitions do
        action(index)
        flushWorkspace()
    end
    local changes = drafts - startDrafts
    print(("workspace %s (%d): drafts=%d row prices=%d graph paints=%d cpu=%.2fms"):format(label,
        repetitions, changes, rowPrices - startRowPrices, paints - startPaints, (os.clock() - started) * 1000))
    return changes, rowPrices - startRowPrices, paints - startPaints
end

local distinct, previous, queueBefore = 0, {}, queuePaints
local _, _, switchPaints = measure("settled native recipe switches", 12, function(index)
    local current = work.preview
    local id = current.rootRecipeId
    if previous[id] ~= current then distinct, previous[id] = distinct + 1, current end
    selectNative(index % 2 == 1 and 4 or 2)
end)
local switchQueuePaints = queuePaints - queueBefore
print(("workspace switching reused displayed plans (%d unique plans, %d queue paints)"):format(distinct, switchQueuePaints))
assert(work.preview.rootRecipeId == 2 and work.graph.root == work.preview.tree, "the selected recipe's graph failed to settle")
assert(captured or switchPaints == 12, "each settled selection should paint the resized graph once")
assert(captured or distinct == 2, "unchanged recipes are planned only once while browsing")
assert(captured or switchQueuePaints <= 12, "recipe switches must not repaint an unchanged queue twice")
local burst, _, burstPaints = measure("rapid native recipe selections", 1, function()
    for index = 1, 9 do selectNative(index % 2 == 1 and 4 or 2) end
end)
assert(burst <= 1 and work.preview.rootRecipeId == 4, "rapid switches planned an obsolete selection")
assert(captured or burstPaints == 1, "a resize caused by the last selection should not paint twice")
local function publishIdle()
    ns:Emit("PROFESSION_CHANGED")
    ns:Emit("INVENTORY_CHANGED", ns.InventoryAdapter.GetStatus(), {regions = {mail = true}})
end
local idleDrafts, idlePrices, idlePaints = measure("unchanged profession and mail notifications", 12, publishIdle)
assert(work.preview.rootRecipeId == 4, "background notifications changed the selected recipe")
assert(captured or idleDrafts == 0 and idlePrices == 0 and idlePaints == 0,
    "unchanged background notifications should not replan or repaint the workbench")
local clock, elapsed = GetServerTime, 0
local openedAt = GetServerTime()
GetServerTime = function() return openedAt + elapsed end
local longDrafts, longPrices, longPaints = measure("30-minute modeled idle with a notification every five seconds", 360, function()
    elapsed = elapsed + 5
    publishIdle()
end)
GetServerTime = clock
assert(work.preview.rootRecipeId == 4 and (captured or longDrafts == 0 and longPrices == 0 and longPaints == 0),
    "the open workbench repeated planning or painting over time")
catalog = {revision = catalog.revision + 1, characterKey = actor,
    recipesById = catalog.recipesById, byOutput = catalog.byOutput}
local catalogDrafts = measure("changed profession catalog", 1, function() ns:Emit("PROFESSION_CHANGED") end)
assert(catalogDrafts == 1 and work.catalog == catalog, "a catalog change in the same profession must refresh the draft")
local material = catalog.recipesById[4].reagents[1].itemID
inventory[material] = (inventory[material] or 0) + 1
local bagRevision = ns.InventoryAdapter.GetRevision() .. ":material changed"
ns.InventoryAdapter.GetRevision = function() return bagRevision end
local updated = measure("changed carried material", 1, function()
    ns:Emit("INVENTORY_CHANGED", ns.InventoryAdapter.GetStatus(), {regions = {bags = true}})
end)
assert(updated == 1 and work.context.counts[material] == inventory[material], "a bag change must refresh the exact draft")

work.quantity:SetText("50")
local heavyPlans = {}
local heavyCount = 0
local after = C_Timer.After
local switchCallbacks, worstCallback = 0, 0
C_Timer.After = function(delay, callback)
    after(delay, function()
        local started = os.clock()
        callback()
        switchCallbacks = switchCallbacks + 1
        worstCallback = math.max(worstCallback, (os.clock() - started) * 1000)
    end)
end
measure("large alternate sourcing plans", 8, function(index)
    selectNative(index % 2 == 1 and rootID or rootID + 1)
    flushWorkspace()
    local current = assert(work.preview)
    assert(current.tree and current.summary.requested == 50)
    if not heavyPlans[current] then heavyCount = heavyCount + 1; heavyPlans[current] = true end
end)
C_Timer.After = after
print(("workspace large-plan search results (%d unique plans, %d callbacks, worst callback %.2fms)")
    :format(heavyCount, switchCallbacks, worstCallback))
assert(captured or heavyCount == 2, "unchanged large plans should not rerun their route search")
assert(captured or switchCallbacks > 8, "cold route searches must yield between frames")
local previousDraft = work.preview
local output = previousDraft.rootItemID
price(output, quotes[output].unitPrice + 5000)
selectNative(rootID)
flushWorkspace()
selectNative(rootID + 1)
flushWorkspace()
assert(work.preview ~= previousDraft and work.context.quotes[output].unitPrice == quotes[output].unitPrice,
    "browsing must re-observe prices even when the provider did not send a notification")

if not captured then
    local cancelled
    work.quantity:SetText("51")
    C_Timer.After = function(delay, callback)
        after(delay, function()
            callback()
            if not cancelled and work.pendingDraft then
                cancelled = work.pendingDraft
                selectNative(2)
            end
        end)
    end
    selectNative(rootID)
    flushWorkspace()
    C_Timer.After = after
    assert(cancelled and not work.pendingDraft and work.preview.rootRecipeId == 2,
        "an unfinished search must yield to a newer recipe selection")
end

ProfessionsFrame:Hide()
flushWorkspace()
local hiddenDrafts, hiddenPrices, hiddenPaints = measure("hidden window notifications", 12, publishIdle)
assert(hiddenDrafts == 0 and hiddenPrices == 0 and hiddenPaints == 0, "hidden workbench performed visible work")
