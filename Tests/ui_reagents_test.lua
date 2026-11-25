GetCoinTextureString = function(copper, size) assert(size == 10); return "coin[" .. copper .. "]" end
local nativeMenuHooks = {}
Menu = {ModifyMenu = function(tag, callback)
    nativeMenuHooks[tag] = nativeMenuHooks[tag] or {}
    table.insert(nativeMenuHooks[tag], callback)
end}
local ns, flush, stock, events = dofile("Tests/ui_fixture.lua")("forever")
local host = ProfessionsFrame
local page, ui = host.CraftingPage, ns.UI
assert(ui.window.parent == page, "workbench must be a native CraftingPage child")
local anchor = ui.window.points.TOPLEFT
assert(anchor[1] == page.RecipeList and anchor[2] == "TOPRIGHT" and anchor[3] == 4,
    "workbench must begin to the right of the actual native recipe list")
assert(page.RecipeList:IsVisible() and page.RecipeList:GetWidth() == 304 and page.RecipeList:GetAlpha() == 1)
assert(ui.window.points.BOTTOMRIGHT[2] == 5)
assert(ui.window:IsVisible() and ui.graph.frame:IsVisible())
assert(ui.queuePane:IsVisible() and not ui.listPane and ui.queuePane:GetParent() == ui.plan,
    "the Forever workbench keeps the queue inside the crafting view beside the native list")
assert(page.SchematicForm.Reagents:IsShown() and page.SchematicForm.Reagents:GetAlpha() == 1)
assert(page.SchematicForm:GetAlpha() == 0 and page.CreateButton:IsShown() and page.CreateButton:GetAlpha() == 0,
    "the native form stays initialized behind the workbench")
assert(#ui.graph.layout == 3 and #ui.graph.lines > 0, "default view must be the connected graph")
assert(ui.graph.layout[1].x < ui.graph.layout[2].x and ui.graph.layout[1].y < ui.graph.layout[2].y)
local example = {itemID = 51, required = 2, source = "Make", children = {
    {itemID = 1, required = 10, source = "Make", fullValue = 1400, crafts = {{outputQuantity = 10}},
        children = {{itemID = 6, required = 40, source = "Buy"}}},
    {itemID = 2, required = 6, source = "Buy"}, {itemID = 3, required = 6, source = "Vendor"},
    {itemID = 4, required = 2, source = "Owned"}, {itemID = 5, required = 1, source = "Bank"},
}}
local cards, width, height = ns.Graph.Layout(example, {}, 304)
assert(#cards == 7 and width <= 328 and height < 280, "a nested recipe and five direct inputs must fit a compact pane")
for index = 2, #cards do
    assert(cards[index].y > cards[index - 1].y + cards[index - 1].height, "compact cards overlap")
    assert(cards[1].height > cards[index].height and cards[1].width > cards[index].width,
        "finished goods should be more prominent than materials")
end
assert(cards[3].parent == cards[2] and cards[2].parent == cards[1] and cards[4].parent == cards[1],
    "nested material connections must retain their actual parents")
local compact = ns.Graph.New(page, GetItemInfo, function() end)
compact.compact = true
compact.frame:SetSize(334, 280)
compact:Render(example, {}, {}, nil, nil)
for index, value in ipairs({"2", "10", "40", "6", "6", "2", "1"}) do
    local card = compact.cards[index]
    assert(card.count:GetText() == value and card.count.points.BOTTOMRIGHT[1] == card.icon,
        "every quantity belongs to its icon")
    assert(not card.counts and not card.source:GetText():find("×", 1, true), "compact cards should only show the total once")
end
assert(compact.cards[1].icon:GetWidth() > compact.cards[2].icon:GetWidth(), "the output icon must remain larger")
assert(compact.cards[2].cost:GetText() == "coin[1400]  ·  coin[140] ea",
    "manufactured ingredients should show both the route total and its unit cost")
Flux = {RestockPolicy = {version = 1, GetVendorPriceEstimate = function(id)
    if id == 300 then return {estimate = true, unitPrice = 2, bundlePrice = 10, bundleSize = 5} end
end}}
ns:Emit("RESTOCK_POLICY_CHANGED")
flush()
local tooltipLines = {}
GameTooltip = {
    SetOwner = function(self, owner) self.owner = owner end,
    SetItemByID = function() end,
    IsOwned = function(self, owner) return self.owner == owner end,
    AddLine = function(_, line) tooltipLines[line] = true end,
    Show = function() end,
    Hide = function() end,
}
ui.graph.cards[3]:Fire("OnEnter")
assert(tooltipLines["Vendor est. 5 for coin[10]"] and tooltipLines["From bags"],
    "vendor pricing and source breakdown must stay accessible on hover")
local graphTooltip = GameTooltip
GameTooltip = nil

do
    local task = {taskId = "partial", status = "in_flight", executions = 4,
        completedExecutions = 0, yield = 1, outputQuantity = 4, evidence = {carriedProgress = 2}}
    local root = {itemID = 100, required = 4, source = "Make", crafts = {{taskId = task.taskId, executions = 4}}}
    local view = ns.Graph.New(page, GetItemInfo, function() end, function(card)
        GameTooltip:SetOwner(card)
    end)
    view.frame:SetSize(250, 180)
    view:Render(root, {zoom = 1}, {}, nil, nil, {status = "running", tasks = {task}})
    GameTooltip, tooltipLines = graphTooltip, {}
    view:ShowTooltip(view.cards[1])
    assert(tooltipLines[ns.L.nodeProgress:format(2, 4)] and tooltipLines[ns.L.in_flight],
        "the graph's tooltip must show two observed outputs while the batch is still settling")
    GameTooltip = nil
end

local function pricePair(total, unit)
    return ns.L.materialCostPair:format(ns.Pricing.FormatCopper(total), ns.L.materialUnit:format(ns.Pricing.FormatCopper(unit)))
end
local total = ui.preview.summary.fullValue
local expectedCost = pricePair(total, total / ui.preview.summary.output)
local expectedProfit = ns.Pricing.FormatProfit(ui.context.projection.estimatedProfit)
assert(ui.planCost:GetText():find("To Craft:", 1, true) and ui.planCost:GetText():find(expectedCost, 1, true))
assert(ui.planProfit:GetText():find("Profit:", 1, true) and ui.planProfit:GetText():find(expectedProfit, 1, true)
    and ui.planProfit:GetText():find("%%"), "show the after-fee profit and percentage below the material cost")
for index = 2, 3 do
    local card = ui.graph.cards[index]
    local node = card.entry.node
    local unit, average = ns.Pricing.MaterialUnitPrice(node)
    local unitText = (average and ns.L.materialUnitAverage or ns.L.materialUnit):format(ns.Pricing.FormatCopper(unit))
    assert(unit and card.cost:IsVisible() and card.cost:GetText():find(ns.Pricing.FormatCopper(node.fullValue), 1, true)
        and card.cost:GetText():find(unitText, 1, true),
        "the material card must show the planned total and the unit cost")
end
local output = ui.graph.cards[1]
assert(output.cost:IsVisible() and output.cost:GetText() == ns.L.outputCost:format(expectedCost),
    "show total and per-item crafting costs on the output card")
assert(output.auction:IsVisible() and output.auction:GetText() == ns.L.outputAuction:format(pricePair(100, 100))
    and output.cost.points.BOTTOMLEFT[2] > output.auction.points.BOTTOMLEFT[2],
    "show gross auction totals and per-item prices on a separate line")
assert(compact.cards[5].cost:GetText() == ns.L.unknown, "expose missing material prices")
local previousQuotes, owner = ns.MarketAdapter.QuoteItems, Flux
ns.MarketAdapter.QuoteItems = function() return {[100] = {unitPrice = 100, unit = "item", provider = "Auctionator"}} end
Flux = nil
ui.Refresh()
assert(ui.graph.cards[1].cost:GetText() == ns.L.outputCost:format(ns.L.unknown)
    and ui.graph.cards[1].auction:GetText() == ns.L.outputAuction:format(pricePair(100, 100)),
    "missing input prices must leave known auction prices visible")
ns.MarketAdapter.QuoteItems, Flux = previousQuotes, owner
ui.Refresh()
assert(ns.Pricing.OutputUnitCost({fullValue = 0, output = 4}) == 0)
assert(not ns.Pricing.OutputUnitCost({fullValue = 4, output = 2, valueKnown = false}))

local function chooseMenu(text, defer)
    for _, action in ipairs(ui.menu.actions) do
        if action:IsShown() and action:GetText() == text then
            action:Fire("OnClick")
            if not defer then flush() end
            return
        end
    end
    error("Missing graph action: " .. text)
end

stock[100] = 2
ui.quantityType:Fire("OnClick")
chooseMenu(ns.L.stockUpTo)
ui.quantity:SetText("2")
ui.quantity:Fire("OnEnterPressed")
flush()
assert(#ui.graph.layout == 1 and ui.graph.cards[1].count:GetText() == "2"
    and ui.graph.cards[1].source:GetText() == ns.L.Covered
    and not ui.graph.cards[1].cost:IsShown()
    and not ui.graph.cards[1].auction:IsShown()
    and not ui.queuePlan.enabled and not ui.emptyPlan:IsShown()
    and ui.planCost:GetText() == ns.L.alreadyCovered and ui.planProfit:GetText() == "",
    "a covered stock target must show the item without offering another queue order")
GameTooltip = graphTooltip
ui.graph.cards[1]:Fire("OnEnter")
assert(tooltipLines[ns.L.tooltipStockCoverage:format(2, 0, 0)])
GameTooltip = nil
stock[100] = nil
ui.quantityType:Fire("OnClick")
chooseMenu(ns.L.additional)
ui.quantity:SetText("1")
ui.quantity:Fire("OnEnterPressed")
flush()

local quoteItems = ns.MarketAdapter.QuoteItems
local calledProvider, fallbackAllowed
ns.MarketAdapter.QuoteItems = function(items, links, provider, fallback)
    calledProvider, fallbackAllowed = provider, fallback
    if provider == "tsm" and not fallback then return {}, {[100] = ns.L.market.tsmUnavailable} end
    return quoteItems(items, links, provider, fallback)
end
ui.estimate:Fire("OnClick", "RightButton")
chooseMenu(ns.L.planner.minCash)
assert(ui.preview.summary.objectiveKey == "cash" and ns.Logistics.GetSettings().objective == "cash")
ui.estimate:Fire("OnClick", "RightButton")
chooseMenu(ns.L.pricesTSM)
assert(calledProvider == "tsm" and not fallbackAllowed and ui.planPriceUnknown == ns.L.market.tsmUnavailable,
    "an explicit unavailable source must stay selected and show why the price is unknown")
assert(ui.graph.cards[1].auction:GetText() == ns.L.outputAuction:format(ns.L.unknown))
ui.estimate:Fire("OnClick", "RightButton")
chooseMenu(ns.L.pricesFallback)
assert(calledProvider == "tsm" and fallbackAllowed and ui.context.projection.estimatedProfit,
    "enable fallback only through the explicit choice")
ui.estimate:Fire("OnClick", "RightButton")
chooseMenu(ns.L.pricesAuctionator)
assert(calledProvider == "auctionator")
ui.estimate:Fire("OnClick", "RightButton")
chooseMenu(ns.L.pricesAuto)
ui.estimate:Fire("OnClick", "RightButton")
chooseMenu(ns.L.planner.minValue)
ns.MarketAdapter.QuoteItems = quoteItems

AuctionatorCraftingInfoProfessionsFrame = CreateFrame("Frame", nil, page.SchematicForm)
AuctionatorCraftingInfoProfessionsFrame:SetFrameLevel(520)
events.ADDON_LOADED:Fire("OnEvent", "ADDON_LOADED", "Auctionator")
flush()
assert(ui.window:GetFrameLevel() >= 550, "Auctionator can paint through the workbench")
assert(AuctionatorCraftingInfoProfessionsFrame:GetAlpha() == 1)

ui.graph.cards[2]:Fire("OnClick", "LeftButton")
assert(ui.menu:IsVisible() and ui.graph.frame:IsVisible(), "source actions should stay on the graph")
chooseMenu(ns.L.inspectRecipe, true)
assert(ui.selectedRecipeId == 22 and ui.preview == nil and page.SchematicForm.selectedID == 11)
ui.craftOne:Fire("OnClick")
assert(not ns.directCraft, "a stale click must not craft a different profession's recipe")
flush()
assert(ui.preview.rootRecipeId == 22)
assert(not ui.craftOne.enabled and not ui.craftAll.enabled,
    "a producer from another profession is inspectable without offering a direct craft")
events["Professions.RecipeSelected"](page, {recipeID = 11})
flush()
assert(ui.selectedRecipeId == 11 and ui.craftOne.enabled,
    "reselecting the same native row must exit cross-profession inspection")

local producer = ns.Catalog.Get(22)
producer.professionId = 5
local baseInfo = {recipeID = 2200, learned = true, favoritesInstance = true}
local rankedInfo = {recipeID = 22, learned = true}
local visibleNode = {GetData = function() return {recipeInfo = baseInfo} end}
local nativeSelectionCount = 0
page.RecipeList.ScrollBox = {FindElementDataByPredicate = function(_, matches)
    if visibleNode and matches(visibleNode) then return visibleNode end
end}
Professions = {GetHighestLearnedRecipe = function(info)
    if info == baseInfo then return rankedInfo end
end}
page.SelectRecipe = function(_, info)
    assert(info == baseInfo, "select the existing native row with its favorite instance")
    nativeSelectionCount = nativeSelectionCount + 1
    page.SchematicForm.selectedID = rankedInfo.recipeID
    events["Professions.RecipeSelected"](page, visibleNode)
end
ui.graph.cards[2]:Fire("OnClick", "LeftButton")
chooseMenu(ns.L.navigate, true)
assert(nativeSelectionCount == 1 and page.SchematicForm.selectedID == 22 and ui.selectedRecipeId == 22)
flush()
assert(ui.craftOne.enabled and ui.craftAll.enabled and not ns.directCraft, "navigation must not craft")

page.SchematicForm.selectedID = nil
ui.craftAll:Fire("OnClick")
assert(not ns.directCraft, "direct craft must recheck the live selected recipe before the next UI update")
page.SchematicForm.selectedID = 11
events["Professions.RecipeSelected"](page, {recipeID = 11})
flush()
visibleNode = nil
ui.graph.cards[2]:Fire("OnClick", "LeftButton")
chooseMenu(ns.L.navigate, true)
assert(nativeSelectionCount == 1 and page.SchematicForm.selectedID == 11 and ui.selectedRecipeId == 22)
flush()
assert(not ui.craftOne.enabled and not ui.craftAll.enabled, "a filtered producer remains an inspection")
producer.professionId = 6
Professions = nil
events["Professions.RecipeSelected"](page, {recipeID = 11})
flush()

ui.graph:Zoom(0.2)
assert(ui.graph.zoom > 1)
ui.fit:Fire("OnClick", "RightButton")
assert(ui.graph.zoom == 1 and ui.graph.position.zoom == 1)
ui.graph.cards[2]:Fire("OnClick", "LeftButton")
ui.queueToggle:Fire("OnClick")
assert(not ui.queuePane:IsVisible() and ui.graph.frame:IsVisible() and not ui.menu:IsShown())
ui.queueToggle:Fire("OnClick")
assert(ui.queuePane:IsVisible() and ui.graph.frame:IsVisible() and not ui.menu:IsShown())
local now, catalogReads, wakes, tickers = 50, 0, {}, {}
GetServerTime = function() return now end
C_Timer.NewTimer = function(delay, callback)
    local wake = {delay = delay, callback = callback, Cancel = function(self) self.cancelled = true end}
    wakes[#wakes + 1] = wake
    return wake
end
C_Timer.NewTicker = function(delay, callback)
    assert(delay == 1)
    local ticker = {callback = callback, Cancel = function(self) self.cancelled = true end}
    tickers[#tickers + 1] = ticker
    return ticker
end
ns.Catalog.Refresh = function()
    catalogReads = catalogReads + 1
    ns.Catalog.Get(33).constraints = {cooldownCharges = 1, maxCooldownCharges = 2, maxExecutions = 1,
        cooldownRechargeAt = 161}
end
page.SchematicForm.selectedID = 33
events["Professions.RecipeSelected"](page, {recipeID = 9999})
assert(ui.selectedRecipeId == 33 and ui.preview == nil and ui.context == nil,
    "the native selection must immediately discard the stale draft before Shopping can use it")
flush()
assert(ui.graph.frame:IsVisible() and not ui.listPane)
assert(ui.preview.rootRecipeId == 33 and ui.preview.inspectionOnly and #ui.graph.layout == 2,
    "cooling Mooncloth should keep the materials graph")
assert(not ui.queuePlan.enabled and not ui.craftOne.enabled and not ui.graph.nextTask,
    "a cooled recipe is inspectable only")
assert(#wakes == 1 and wakes[1].delay >= 50 and wakes[1].delay < 51,
    "the selected cooldown should schedule only one wake at expiry")
assert(ui.planCooldown:IsVisible() and ui.planCooldown:GetText() == "Cooldown 0:50" and #tickers == 1)
assert(ui.planCost:IsVisible() and ui.planProfit:IsVisible(), "show cooldown and economics together")
now = 54
tickers[1].callback()
assert(ui.planCooldown:GetText() == "Cooldown 0:46" and catalogReads == 0 and #wakes == 1,
    "visible countdown ticks must update only the label")

page.SchematicForm.selectedID = 11
events["Professions.RecipeSelected"](page, {recipeID = 11})
flush()
assert(wakes[1].cancelled and ui.selectedRecipeId == 11)
assert(tickers[1].cancelled and not ui.planCooldown:IsVisible() and ui.planCost:IsVisible())
wakes[1].callback()
assert(catalogReads == 0 and ui.selectedRecipeId == 11, "a previous recipe's wake must leave the new selection alone")
page.SchematicForm.selectedID = 33
events["Professions.RecipeSelected"](page, {recipeID = 33})
flush()
assert(#wakes == 2)

ui.ShowNative()
assert(not ui.window:IsShown() and ui.returnButton:IsShown())
assert(page.RecipeList:IsVisible() and AuctionatorCraftingInfoProfessionsFrame:IsVisible())
assert(page.SchematicForm.Reagents:IsShown() and page.SchematicForm.Reagents:GetAlpha() == 1)
assert(page.SchematicForm:GetAlpha() == 1 and page.CreateButton:IsShown() and page.CreateButton:GetAlpha() == 1)
assert(wakes[2].cancelled)
assert(tickers[2].cancelled)
wakes[2].callback()
assert(catalogReads == 0, "hidden workbench must not refresh from a stale wake")
ui.ShowWorkbench(true)
assert(ui.window:IsVisible())
flush()
assert(#wakes == 3 and ui.preview.inspectionOnly and not ui.craftOne.enabled)
now = 101
wakes[3].callback()
assert(catalogReads == 1 and #wakes == 4 and not ui.preview.inspectionOnly
    and ui.queuePlan.enabled and ui.craftOne.enabled,
    "expiry should refresh readiness and controls without an unrelated event")
assert(ui.planCooldown:GetText() == "1/2 charges  •  Next charge 1:00",
    "an available charge can be used while displaying the next cooldown")
ui.quantity:SetText("2")
ui.quantity:Fire("OnEnterPressed")
assert(ui.preview.inspectionOnly and not ui.queuePlan.enabled and ui.craftOne.enabled and ui.craftAll.enabled,
    "one remaining charge must allow direct crafting when the larger queue preview is blocked")
page:Hide()
host.BookPage:Show()
assert(not ui.window:IsVisible() and host.BookPage:IsVisible())
page:Show()
host.BookPage:Hide()
flush()
assert(ui.window:IsVisible())
InputUtil = {IsGamepadUIEnabled = function() return true end}
events.INPUT_DEVICE_INTERFACE_TRANSITION:Fire("OnEvent", "INPUT_DEVICE_INTERFACE_TRANSITION")
assert(page:IsShown() and not ui.window:IsShown() and not ui.returnButton:IsShown())
assert(not ui.saved.nativeMode, "automatic gamepad transition changed saved view preference")
InputUtil.IsGamepadUIEnabled = function() return false end
events.INPUT_DEVICE_INTERFACE_TRANSITION:Fire("OnEvent", "INPUT_DEVICE_INTERFACE_TRANSITION")
assert(ui.window:IsShown())
local recipe = ns.Catalog.Get(11)
recipe.yield, recipe.yieldMax = 2, 2
ns.Catalog.Snapshot().revision = ns.Catalog.Snapshot().revision + 1
ns:Emit("PROFESSION_CHANGED")
page.SchematicForm.selectedID = 11
events["Professions.RecipeSelected"](page, {recipeID = 11})
flush()
assert(ui.graph.cards[1].count:GetText() == "2" and ui.graph.cards[1].count.points.BOTTOMRIGHT[1] == ui.graph.cards[1].icon)
ui.quantity:SetText("10")
ui.quantity:Fire("OnEnterPressed")
assert(ui.graph.cards[1].count:GetText() == "10", "the icon must show the full planned output")
total = ui.preview.summary.fullValue
assert(ui.graph.cards[1].cost:GetText() == ns.L.outputCost:format(pricePair(total, total / 10)))
assert(ui.graph.cards[1].auction:GetText() == ns.L.outputAuction:format(pricePair(1000, 100)))
recipe.yieldMax = 5
ui.quantity:SetText("5")
ui.quantity:Fire("OnEnterPressed")
assert(ui.graph.cards[1].count:GetText() == "6–15" and ui.preview.summary.executions == 3
    and ui.preview.summary.output == 6 and ui.planSummary:find(ns.L.variableYieldPlan, 1, true),
    "the range must be visible while planning against guaranteed output")
total = ui.preview.summary.fullValue
local guaranteedCost = ns.L.outputCost:format(pricePair(total, total / 6))
local plannedSale = ns.L.outputAuctionQuantity:format(5, pricePair(500, 100))
assert(ui.graph.cards[1].cost:GetText() == guaranteedCost, "cost per item must use the guaranteed output, including surplus")
assert(ui.graph.cards[1].auction:GetText() == plannedSale, "mark the sale quantity when it differs from output")
assert(ui.planSaleDetail:find("sale of 5", 1, true) and ui.planSurplusDetail == ns.L.planSurplusValue:format(1),
    "explain which units fund the sale estimate and what the full batch costs cover")
ui.queuePlan:Fire("OnClick")
assert(ui.job and ui.graph.cards[1].count:GetText() == "6–15")
GameTooltip, tooltipLines = graphTooltip, {}
local acceptedOutput = ui.graph.cards[1].entry.node
ui.graph.cards[1]:Fire("OnEnter")
assert(tooltipLines[ns.L.tooltipAcceptedQuantities:format(acceptedOutput.required, acceptedOutput.ownedUsed or 0)],
    "an accepted graph must show original allocations as plan data")
for line in pairs(tooltipLines) do
    assert(not line:find("still to source", 1, true), "accepted tooltips cannot show the original deficit as current")
end
GameTooltip = nil
recipe.yieldMax = 9
ns.MarketAdapter.QuoteItems = function() return {[100] = {unitPrice = 500, unit = "item"}} end
ui.Refresh()
assert(ui.graph.cards[1].count:GetText() == "6–15", "saved jobs keep their accepted total yield range")
assert(ui.graph.cards[1].cost:GetText() == guaranteedCost, "saved jobs display their accepted cost per output")
assert(ui.graph.cards[1].auction:GetText() == plannedSale, "saved jobs display their accepted auction prices")
ns.MarketAdapter.QuoteItems = previousQuotes
assert(ui.planSaleDetail:find("sale of 5", 1, true) and ui.planSurplusDetail == ns.L.planSurplusValue:format(1),
    "accepted price evidence keeps the original sale quantity")
assert(not ns.Graph.OutputAmount({outputKind = "special", yield = 4}), "special-action input amounts are not yields")
page.RecipeList:Hide()
assert(not ui.window:IsShown(), "minimized native list must hand back the working area")
page.RecipeList:Show()
assert(ui.window:IsShown())
host:Hide()
assert(not ui.window:IsVisible())

local firstNode = {GetData = function() return {recipeInfo = {recipeID = 11, learned = true}} end}
local secondNode = {GetData = function() return {recipeInfo = {recipeID = 33, learned = true}} end}
local activeRow = firstNode
local nativeRow = {GetElementData = function() return activeRow end}
local tree = {
    EnumerateEntireRange = function() return ipairs({firstNode, firstNode, secondNode}) end,
    FindElementDataByPredicate = function(_, predicate)
        for _, node in ipairs({firstNode, secondNode}) do if predicate(node) then return node end end
    end,
}
TreeDataProviderConstants = {IncludeCollapsed = true}
page.RecipeList.FilterDropdown = CreateFrame("Button", nil, page.RecipeList)
page.RecipeList.ScrollBox = {
    FindFrame = function(_, node) return node == activeRow and nativeRow or nil end,
    GetDataProvider = function() return tree end,
    ScrollToElementData = function(_, node) assert(node == firstNode) end,
}
local selected
page.OnRecipeSelected = function(_, info, list)
    assert(list == page.RecipeList)
    selected = info.recipeID
end
host:Show()
local function menuDescription()
    local menu = {items = {}}
    function menu:CreateDivider() end
    function menu:SetScrollMode() end
    function menu:CreateButton(caption, click)
        local item = menuDescription()
        item.caption, item.click = caption, click
        self.items[#self.items + 1] = item
        return item
    end
    return menu
end
local rowMenu = menuDescription()
rowMenu:CreateButton("Native favorite")
for _, hook in ipairs(nativeMenuHooks.MENU_PROFESSIONS_RECIPE_LIST_FAVORITE) do hook(nativeRow, rowMenu) end
assert(#rowMenu.items == 3 and rowMenu.items[1].caption == "Native favorite")
activeRow = secondNode
rowMenu.items[3].click()
assert(not ui.menu:IsShown(), "a recycled native row cannot edit the wrong recipe")
activeRow = firstNode
rowMenu.items[3].click()
ui.menu.editor:SetText("  Keep a bolt for the next craft  ")
ui.menu.editor:Fire("OnEnterPressed")
rowMenu.items[2].click()
ui.menu.editor:SetText("Tailoring stock")
ui.menu.editor:Fire("OnEnterPressed")
local meta = ui.saved.recipeMeta["11"]
assert(meta.note == "Keep a bolt for the next craft" and meta.group == "Tailoring stock")
local filter = menuDescription()
filter:CreateButton("Native filters")
for _, hook in ipairs(nativeMenuHooks.MENU_PROFESSIONS_FILTER) do hook(page.RecipeList.FilterDropdown, filter) end
local groupMenu = filter.items[#filter.items]
assert(filter.items[1].caption == "Native filters" and groupMenu.caption == ns.L.customGroups)
assert(groupMenu.items[1].caption == "Tailoring stock" and #groupMenu.items[1].items == 1,
    "a native Favorites copy must not duplicate a custom group result")
groupMenu.items[1].items[1].click()
assert(selected == 11)
local unrelated = menuDescription()
for _, hook in ipairs(nativeMenuHooks.MENU_PROFESSIONS_RECIPE_LIST_FAVORITE) do hook({}, unrelated) end
assert(#unrelated.items == 0, "other profession lists retain their native menus")
ui.ShowNative()
local fallback = menuDescription()
for _, hook in ipairs(nativeMenuHooks.MENU_PROFESSIONS_FILTER) do hook(page.RecipeList.FilterDropdown, fallback) end
assert(#fallback.items == 0, "Native UI fallback keeps Blizzard's Filter menu by itself")

do
    local setup = dofile("Tests/ui_fixture.lua")
    local fixture, drain, carried, nativeEvents = setup("forever")
    local workbench, crafting = fixture.UI, ProfessionsFrame.CraftingPage
    fixture.Catalog.Get(22).professionId = 5
    carried[200] = 2
    workbench.Refresh()
    workbench.queuePlan:Fire("OnClick")
    local activeJob = assert(workbench.job)
    local activeTask = activeJob.tasks[1]
    assert(activeTask.recipeId == 11 and fixture.Queue.Begin(activeJob, activeTask, {beforeOutput = 0, batch = 1}))
    local busy = true
    fixture.Execution.IsBusy = function() return busy end
    crafting.SchematicForm.selectedID = 22
    workbench.Refresh()
    assert(workbench.selectedRecipeId == 11 and workbench.job == activeJob,
        "a passive in-flight refresh must preserve the current view until the explicit native selection")
    nativeEvents["Professions.RecipeSelected"](crafting, {recipeID = 22})
    drain()
    assert(workbench.selectedRecipeId == 22 and workbench.preview.rootRecipeId == 22 and not workbench.job
        and activeTask.status == "in_flight" and activeTask.recipeId == 11 and not workbench.craftOne.enabled,
        "a native row choice can refresh the addon preview while the exact active recipe stays in the queue")
    fixture.Queue.CraftEvent(activeJob, activeTask, 1, 1)
    assert(fixture.Queue.Reconcile(activeJob, activeTask, 1))
    busy = false
    fixture:Emit("EXECUTION_CHANGED", "Craft settled")
    drain()
    assert(workbench.selectedRecipeId == 22 and workbench.craftOne.enabled,
        "the native row chosen during an active craft remains available after settlement")

    fixture, drain, _, nativeEvents = setup("forever")
    workbench, crafting = fixture.UI, ProfessionsFrame.CraftingPage
    fixture.Catalog.Get(22).professionId = 5
    workbench.Refresh()
    local producerInfo = {recipeID = 22, learned = true}
    local producerNode = {GetData = function() return {recipeInfo = producerInfo} end}
    crafting.RecipeList.ScrollBox = {FindElementDataByPredicate = function(_, matches)
        if matches(producerNode) then return producerNode end
    end}
    local nativeWrites = 0
    crafting.SelectRecipe = function(_, info)
        assert(info == producerInfo and not busy)
        nativeWrites = nativeWrites + 1
        crafting.SchematicForm.selectedID = info.recipeID
        nativeEvents["Professions.RecipeSelected"](crafting, producerNode)
    end
    busy = true
    fixture.Execution.IsBusy = function() return busy end
    workbench.graph.cards[2]:Fire("OnClick", "LeftButton")
    for _, action in ipairs(workbench.menu.actions) do
        if action:IsShown() and action:GetText() == fixture.L.navigate then action:Fire("OnClick"); break end
    end
    assert(workbench.selectedRecipeId == 22 and workbench.preview == nil
        and crafting.SchematicForm.selectedID == 11 and nativeWrites == 0,
        "addon navigation changes the selected preview without disturbing an active native craft")
    drain()
    assert(workbench.preview.rootRecipeId == 22
        and crafting.SchematicForm.selectedID == 11 and nativeWrites == 0 and not workbench.craftOne.enabled,
        "addon navigation previews the next recipe without writing native selection while crafting")
    busy = false
    fixture:Emit("EXECUTION_CHANGED", "Craft settled")
    drain()
    assert(workbench.selectedRecipeId == 22 and crafting.SchematicForm.selectedID == 22 and nativeWrites == 1
        and workbench.craftOne.enabled, "the deferred native selection runs once after settlement")
end

do
    local fixture, drain = dofile("Tests/ui_fixture.lua")("classic")
    local workbench = fixture.UI
    fixture.Execution.IsBusy = function() return true end
    local mooncloth = workbench.recipeRows[2]
    assert(mooncloth.record.recipe.id == 33)
    mooncloth:Fire("OnClick", "LeftButton")
    drain()
    assert(workbench.selectedRecipeId == 33 and workbench.preview.rootRecipeId == 33
        and not workbench.craftOne.enabled and not fixture.directCraft,
        "Classic addon rows already browse without changing an active native craft")
end

do
    local fixture = dofile("Tests/ui_fixture.lua")("classic", nil, function(setup)
        setup.Catalog.Get(11).reagents[1].quantity = 11
        setup.Catalog.Get(22).yield = 10
        setup.MarketAdapter.QuoteItems = function()
            return {[100] = 150000, [200] = 10000, [300] = 60000}
        end
    end)
    local workbench = fixture.UI
    GameTooltip, tooltipLines = graphTooltip, {}
    local intermediate = workbench.graph.cards[2]
    assert(intermediate.entry.node.source == "Mixed")
    intermediate:Fire("OnEnter")
    local format = fixture.Pricing.FormatCopper
    assert(tooltipLines[fixture.L.savings:format(format(-10000), -100 / 11)]
        and tooltipLines[fixture.L.mixedSavings:format(format(40000), 400 / 11)],
        "the mixed plan shows its own savings beside the unchanged pure Make comparison")
    tooltipLines = {}
    workbench.graph.cards[1]:Fire("OnEnter")
    for line in pairs(tooltipLines) do
        assert(not line:find("Selected savings", 1, true), "pure routes need no duplicate comparison")
    end
    GameTooltip = nil
end

do
    local setup = dofile("Tests/ui_fixture.lua")
    local createFrame, previousEnum = CreateFrame, Enum
    CreateFrame = function(kind, ...)
        local widget = createFrame(kind, ...)
        local createTexture = widget.CreateTexture
        function widget:CreateTexture(...)
            local texture = createTexture(self, ...)
            function texture:SetColorTexture(r, g, b) self.color = {r, g, b} end
            return texture
        end
        return widget
    end
    -- Non-sequential values catch accidental comparisons against enum ordinals.
    local native = {Optimal = 7, Medium = 4, Easy = 1, Trivial = 9}
    Enum = {TradeskillRelativeDifficulty = native}
    for _, target in ipairs({"forever", "classic"}) do
        local difficulty = target == "forever" and native
            or {Optimal = "optimal", Medium = "medium", Easy = "easy", Trivial = "trivial"}
        local rank, cap, currentProfession = 218, 300, 5
        local rangeAvailable, spellID = false, target == "forever" and 11 or 12067
        local nativePage, fill
        local fixture, drain = setup(target, nil, function(config)
            local recipe = config.Catalog.Get(11)
            recipe.difficulty, recipe.canSkillUp = difficulty.Optimal, true
            if target == "forever" then
                recipe.numSkillUps = 3
                nativePage = ProfessionsFrame.CraftingPage
                nativePage:SetFrameLevel(40)
                nativePage.RankBar = CreateFrame("StatusBar", nil, nativePage)
                nativePage.RankBar:SetSize(453, 18)
                nativePage.RankBar:SetPoint("TOPLEFT", 110, -40)
                nativePage.RankBar:SetFrameLevel(10)
                fill = nativePage.RankBar:CreateTexture()
                fill:SetSize(441, 18)
                fill:SetPoint("TOPLEFT", 5, -3)
                local border = nativePage.RankBar:CreateTexture()
                border:SetSize(451, 29)
                border:SetPoint("TOPLEFT")
                nativePage.RankBar.Fill, nativePage.RankBar.Border = fill, border
            else
                recipe.legacy, recipe.legacySpellID = true, spellID
            end
            config.Clients.CurrentProfessionID = function() return currentProfession end
            config.Clients.GetRecipeSkillProgress = function(selected)
                if selected == recipe then return rank, cap end
            end
            config.SkillRanges = {Get = function(id, profession)
                if rangeAvailable and id == spellID and profession == recipe.professionId then
                    return 210, 225, 240, 200
                end
            end}
        end)
        local workbench, recipe = fixture.UI, fixture.Catalog.Get(11)
        local bar = assert(workbench.recipeSkill, target .. " workbench is missing the recipe skill strip")
        local anchor = fill or workbench.classicSkillBar
        local parent = nativePage or workbench.classic
        assert(bar:GetParent() == parent, target .. " header strip belongs to the profession page")
        assert(bar:GetHeight() == (nativePage and 5 or 3), target .. " the header strip must use the client-specific height")
        assert(bar.progress:GetHeight() == bar:GetHeight() and bar.marker:GetWidth() == 2
            and bar.marker:GetHeight() == bar:GetHeight(), target .. " fallback progress and marker must fit the header strip")
        if nativePage then
            assert(bar:GetFrameLevel() >= nativePage:GetFrameLevel() + 3,
                "the Forever strip must render above the header, even with a lower native rank frame")
        end
        for _, side in ipairs({"LEFT", "RIGHT"}) do
            local point = bar.points["TOP" .. side]
            assert(point[1] == anchor and point[2] == "BOTTOM" .. side and point[3] == 0 and point[4] == -1,
                target .. " header strip must follow both ends of the profession rank bar")
        end
        bar:SetWidth(300) -- Mock frames do not resolve their two horizontal anchors.
        local function assertMarker(expected)
            local point = bar.marker.points.TOPLEFT
            assert(bar:IsVisible() and bar.marker:IsVisible() and point[1] == bar and math.abs(point[3] - expected) < 1,
                target .. " the current rank marker must follow the profession scale")
            local color = bar.marker.color
            assert(color[1] == 1 and color[2] == 1 and color[3] == 1, target .. " the rank marker stays white")
        end
        local function assertProgress(expected)
            assert(bar.progress:IsVisible() and math.abs(bar.progress:GetWidth() - expected) < 1,
                target .. " fallback difficulty must fill the strip from zero to the current rank")
            return bar.progress.color
        end
        assertMarker(217)
        local color = assertProgress(218)
        assert(color[1] > color[2] and color[2] > color[3], target .. " optimal recipes use orange fallback progress")
        local rankText = target == "forever" and fixture.L.recipeSkillGain:format(rank, cap, 3)
            or fixture.L.recipeSkillRank:format(rank, cap)
        assert(bar.rankText == rankText, target .. " the hover readout must show the observed rank and available gain")
        assert(workbench.plan.points.TOPLEFT[2] == -25, target .. " the header strip must leave the graph's toolbar spacing alone")

        local draft = workbench.preview
        rank = 219
        fixture:Emit("PROFESSION_CHANGED")
        drain()
        assertMarker(218)
        assertProgress(219)
        assert(workbench.preview == draft, target .. " a rank-only update must preserve the current plan")

        local function refreshSkill()
            local snapshot = {}
            for key, value in pairs(fixture.Catalog.Snapshot()) do snapshot[key] = value end
            snapshot.revision = snapshot.revision + 1
            fixture.Catalog.Snapshot = function() return snapshot end
            fixture:Emit("PROFESSION_CHANGED")
            drain()
        end
        rank, recipe.difficulty = 220, difficulty.Medium
        refreshSkill()
        color = assertProgress(220)
        assertMarker(219)
        assert(color[1] > 0.6 and color[2] > 0.6 and color[3] < 0.4, target .. " medium recipes use yellow fallback progress")

        recipe.difficulty = difficulty.Easy
        refreshSkill()
        color = assertProgress(220)
        assert(color[2] > color[1] and color[2] > color[3], target .. " easy recipes use green fallback progress")

        recipe.difficulty = difficulty.Trivial
        refreshSkill()
        assert(not bar:IsShown(), target .. " trivial recipes must hide the bar even with stale skill-up eligibility")
        assert(workbench.plan.points.TOPLEFT[2] == -25, target .. " hiding the strip must leave the graph in place")

        recipe.difficulty, recipe.canSkillUp = difficulty.Optimal, false
        refreshSkill()
        assert(not bar:IsShown(), target .. " recipes without possible skill-ups must hide the bar")

        rank, recipe.canSkillUp = cap, true
        refreshSkill()
        assert(not bar:IsShown(), target .. " the bar must hide at the profession cap")

        local function assertFallback()
            assert(bar:IsVisible() and not bar.thresholdText,
                target .. " contradictory thresholds must leave single-color difficulty visible")
            for _, band in ipairs(bar.ranges) do assert(not band:IsVisible()) end
        end

        rangeAvailable = true
        rank, recipe.difficulty = 236, difficulty.Easy
        if target == "forever" then recipe.maxTrivialLevel = 240 end
        bar:SetWidth(300)
        refreshSkill()
        assert(bar:IsVisible() and #bar.ranges == 5 and not bar.progress:IsShown(),
            target .. " a matching recipe spell must show five skill bands")
        assertMarker(235)
        for _, threshold in ipairs({"200", "210", "225", "240"}) do
            assert(bar.thresholdText:find(threshold, 1, true), target .. " the tooltip must expose every observed threshold")
        end
        local hoverLines, previousTooltip = {}, GameTooltip
        GameTooltip = {
            SetOwner = function(_, owner) assert(owner == bar) end,
            SetText = function(_, title) assert(title == recipe.name) end,
            AddLine = function(_, text) hoverLines[#hoverLines + 1] = text end,
            Show = function() end,
        }
        bar:Fire("OnEnter")
        GameTooltip = previousTooltip
        assert(hoverLines[1] == bar.rankText and hoverLines[2] == bar.thresholdText,
            target .. " hovering the strip must report rank and all observed thresholds")
        local start = 0
        for index, expected in ipairs({200, 10, 15, 15, 60}) do
            local band = bar.ranges[index]
            local anchor = band.points.TOPLEFT
            assert(band:IsVisible() and anchor[1] == bar and math.abs(anchor[3] - start) < 1
                and math.abs(band:GetWidth() - expected) < 1,
                target .. " each color band must cover only its own rank interval")
            start = start + expected
        end
        local red, orange, yellow, green, gray = bar.ranges[1].color, bar.ranges[2].color,
            bar.ranges[3].color, bar.ranges[4].color, bar.ranges[5].color
        assert(red[1] > red[2] and math.abs(red[2] - red[3]) < 0.08
            and orange[1] > orange[2] and orange[2] > orange[3]
            and yellow[1] > yellow[3] and yellow[2] > yellow[3]
            and green[2] > green[1] and green[2] > green[3]
            and math.max(gray[1], gray[2], gray[3]) - math.min(gray[1], gray[2], gray[3]) < 0.08,
            target .. " range mode must show red, orange, yellow, green, and gray in order")

        bar:SetWidth(150)
        assertMarker(117)
        assert(math.abs(bar.ranges[1]:GetWidth() - 100) < 1 and math.abs(bar.ranges[2]:GetWidth() - 5) < 1,
            target .. " resizing the header must scale the marker and the bands together")

        rank, cap = 226, 230
        bar:SetWidth(230)
        refreshSkill()
        assert(bar.ranges[4]:IsVisible() and math.abs(bar.ranges[4]:GetWidth() - 5) < 1
            and not bar.ranges[5]:IsVisible() and bar.thresholdText:find("240", 1, true),
            target .. " band geometry clips at the profession cap while retaining the actual gray threshold")

        rank, cap, recipe.difficulty = 236, 300, difficulty.Medium
        refreshSkill()
        assertFallback()
        color = assertProgress(236 * 230 / 300)
        assert(color[1] > 0.6 and color[2] > 0.6 and color[3] < 0.4,
            target .. " the live yellow tier takes priority over contradictory data")
        if target == "forever" then
            recipe.difficulty, recipe.maxTrivialLevel = difficulty.Easy, 245
            refreshSkill()
            assertFallback()
            color = assertProgress(236 * 230 / 300)
            assert(color[2] > color[1] and color[2] > color[3],
                "a conflicting live trivial cutoff must fall back to the live green tier")
        end

        currentProfession = 6
        refreshSkill()
        assert(not bar:IsVisible(), target .. " a different profession must hide the previous recipe strip")
        currentProfession = 5
        if nativePage then
            refreshSkill()
            assert(bar:IsVisible())
            workbench.ShowNative()
            assert(not bar:IsVisible(), "showing the native recipe view must hide the custom header strip")
            workbench.ShowWorkbench(true)
            drain()
            assert(bar:IsVisible())

            local host = ProfessionsFrame
            nativePage:Hide()
            host.BookPage:Show()
            assert(not bar:IsVisible(), "opening the profession book must hide the recipe strip")
            host.BookPage:Hide()
            nativePage:Show()
            drain()
            assert(bar:IsVisible())

            workbench.ShowNativeCraft(fixture.L.execNativeCreate)
            assert(workbench.window:IsVisible() and not bar:IsVisible(),
                "the docked workbench must leave the native craft header alone")
            workbench.ShowWorkbench(true)
            drain()
            assert(bar:IsVisible())

            local catalog = fixture.Catalog.Snapshot()
            catalog.recipesById[11], catalog.byOutput[recipe.outputItemID] = nil, nil
            recipe.id, recipe.recipeID, recipe.professionId, recipe.outputItemID = 18405, 18405, 197, 14046
            recipe.name, recipe.difficulty, recipe.maxTrivialLevel = "Runecloth Bag", difficulty.Medium, 260
            catalog.recipesById[18405], catalog.byOutput[14046] = recipe, {18405}
            rank, cap, currentProfession = 237, 300, 197
            nativePage.SchematicForm.selectedID = recipe.recipeID
            assert(loadfile("FluxCraft/SkillRanges.lua"))("FluxLogistics", fixture)
            bar:SetWidth(fill:GetWidth())
            refreshSkill()
            assertMarker(237 * 441 / 300 - 1)
            assert(bar.rank == 237 and bar.yellow == 230 and bar.green == 245 and bar.gray == 260
                and bar.ranges[3]:IsVisible() and math.abs(bar.ranges[3]:GetWidth() - 15 * 441 / 300) < 1,
                "Runecloth Bag at the reported Forever rank must paint the real yellow threshold band")
        end
    end
    CreateFrame, Enum = createFrame, previousEnum
end

for _, target in ipairs({"forever", "classic", "anniversary", "era"}) do
    local fixture = {target = target}
    assert(loadfile("FluxCraft/SkillRanges.lua"))("FluxLogistics", fixture)
    local yellow, green, gray = fixture.SkillRanges.Get(12067, 197)
    if target == "forever" then
        assert(yellow == 205 and green == 220 and gray == 235)
    else
        assert(yellow == 240 and green == 255 and gray == 270)
    end
end

print("Forever native host, overview and escape fixtures passed")
