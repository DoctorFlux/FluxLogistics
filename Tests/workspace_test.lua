local readProfessionSurface, layeredSurface, layeredDock, actionChanged, action, clickedAction
local restockLayer = {
    SetProfessionSurfaceReader = function(reader) readProfessionSurface = reader end,
    RefreshProfessionLayer = function()
        if not readProfessionSurface then return end
        local surface, _, dock = readProfessionSurface()
        layeredSurface, layeredDock = surface, dock
    end,
    RegisterProfessionWindowListener = function(listener) actionChanged = listener end,
    GetProfessionWindowAction = function() return action end,
    ClickProfessionWindowAction = function(shown) clickedAction = shown end,
}
FluxAuctionRestock = {Followup = restockLayer}
local ns, flush = dofile("Tests/ui_fixture.lua")("classic")
local ui = ns.UI
assert(ui.classic:IsVisible() and TradeSkillFrame:IsShown() and TradeSkillFrame:GetAlpha() == 0)
assert(readProfessionSurface() == ui.window, "the HUD must layer above the workbench content")
assert(ui.graph.frame:IsVisible() and ui.window.parent == ui.classic)
assert(ui.craftOne:IsVisible() and ui.craftOne.enabled and ui.craftAll:IsVisible() and ui.craftAll.enabled)
assert(ui.queuePane:IsVisible() and ui.queueRows[1].caption:GetText() == ns.L.queueEmpty)
assert(ui.process:GetText() == ns.L.processShort, "Classic keeps its existing process action")
assert(ui.queueAll.points.BOTTOMLEFT[1] == ui.plan and ui.queuePlan.points.BOTTOMRIGHT[1] == ui.plan
    and ui.craftAll.points.BOTTOMLEFT[1] == ui.plan and ui.graphShoppingButton.points.BOTTOMRIGHT
    and ui.process.points.BOTTOMLEFT and ui.queueClear.points.LEFT[1] == ui.process
    and ui.recipeAuctionator.parent == ui.plan.parent,
    "craft controls, queue and shopping actions must share the compact footer")
assert(not ui.craftNext:IsShown())
action = {kind = "craft", name = "A queued item", canAct = true}
actionChanged()
assert(ui.craftNext:IsVisible() and ui.craftNext.points.BOTTOM[1] == ui.plan
    and ui.craftNext:GetText() == ns.L.craftNext and ui.craftNext.enabled)
ui.craftNext:Fire("OnClick")
assert(clickedAction == action and not ns.processed, "the bottom shared action uses the exact painted owner token")
action = {kind = "craft", name = "A queued item", nativeCraft = true, nativeCraftPrepared = 9, canAct = false}
actionChanged()
assert(ui.craftNext:GetText() == ns.L.useNativeCreate and not ui.craftNext.enabled)
clickedAction = nil
ui.craftNext:Fire("OnClick")
assert(not clickedAction, "prepared guidance cannot initiate native Create")
action = nil
actionChanged()
assert(not ui.craftNext:IsShown())
local previousFlux, attachedProxy, refreshedProxy = Flux
Flux = {SecureClickProxy = {
    Attach = function(button, options) assert(button == ui.craftNext); attachedProxy = options end,
    Refresh = function(button) assert(button == ui.craftNext); refreshedProxy = button end,
}}
action = {kind = "profession", name = "A tracked switch", canAct = true,
    profession = {}, logistics = {queueSwitch = true}}
actionChanged()
ui.craftNext:Fire("OnClick")
assert(not attachedProxy and clickedAction == action, "tracked switches keep the shared ordinary dispatch")
action = {kind = "profession", name = "A profession", canAct = true, profession = {spellID = 3949}}
actionChanged()
assert(attachedProxy and attachedProxy.spell() == 3949 and attachedProxy.enabled()
    and attachedProxy.clicks == "LeftButtonUp" and refreshedProxy == ui.craftNext)
action = nil
actionChanged()
assert(not attachedProxy.enabled() and attachedProxy.spell() == nil and not ui.craftNext:IsShown())
Flux = previousFlux
ui.window:Hide()
local overviewSurface, hasWorkbenchFooter = readProfessionSurface()
assert(overviewSurface == ui.classic and hasWorkbenchFooter == false,
    "the Classic overview supplies a surface without claiming the hidden workbench's action")
ui.window:Show()

restockLayer.HasProfessionReminderDock = true
local _, _, emptyDock = readProfessionSurface()
local originalQueueBottom = ui.queuePane.points.BOTTOMLEFT[2]
assert(not emptyDock and not ui.professionReminderDock, "an empty reminder reserves no Flowcraft space")
action = {kind = "craft", name = "A queued item", canAct = true}
actionChanged()
local dockedSurface, _, reminderDock = readProfessionSurface()
assert(dockedSurface == ui.window and reminderDock and reminderDock == ui.professionReminderDock and reminderDock:IsVisible()
    and reminderDock.parent == ui.plan and reminderDock.points.BOTTOM[4] == originalQueueBottom
    and ui.queuePane.points.BOTTOMLEFT[2] == originalQueueBottom + reminderDock:GetHeight(),
    "the craft reminder sits wholly in the row between Flowcraft's queue and controls")
clickedAction = nil
ui.craftNext:Fire("OnClick")
assert(not ui.craftNext:IsVisible() and not clickedAction,
    "an owner with the reminder dock retires the older Flowcraft action")
action = {kind = "crafting", name = "A queued item", quantity = 2, canAct = false}
actionChanged()
local _, _, progressDock = readProfessionSurface()
assert(progressDock == reminderDock, "readonly crafting progress reuses the same dock row")
ui.window:Hide()
local dockOverview, _, hiddenDock = readProfessionSurface()
assert(dockOverview == ui.classic and not hiddenDock and not reminderDock:IsShown(),
    "leaving the workbench releases its reminder to the visible profession shell")
ui.window:Show()
assert(layeredDock == reminderDock and layeredDock:IsVisible(), "the workbench restores the anchor before requesting a layer refresh")
action = nil
actionChanged()
assert(not reminderDock:IsShown() and ui.queuePane.points.BOTTOMLEFT[2] == originalQueueBottom,
    "retiring the reminder gives its row back to the queue")
restockLayer.HasProfessionReminderDock = nil

ui.craftOne:Fire("OnClick")
assert(ns.directCraft[1] == ui.selectedRecipeId and ns.directCraft[2] == false and ns.directCraft[3] == 1)
ui.quantityUp:Fire("OnClick", "LeftButton")
ui.craftOne:Fire("OnClick")
assert(ui.quantity:GetText() == "2" and ns.directCraft[3] == 2, "Craft must use the entered quantity")
ui.craftAll:Fire("OnClick")
assert(ns.directCraft[1] == ui.selectedRecipeId and ns.directCraft[2] == true and ns.directCraft[3] == nil)
ui.quantityDown:Fire("OnClick", "RightButton")
assert(ui.quantity:GetText() == "1", "quantity adjustment must clamp at one")
ui.quantityLast:Fire("OnClick", "LeftButton")
assert(ui.quantity:GetText() == "11")
ui.quantityFirst:Fire("OnClick", "LeftButton")
assert(ui.quantity:GetText() == "1")
for _, width in ipairs({270, 340}) do
    ui.plan:Fire("OnSizeChanged", width, 400)
    assert(ui.quantityUp:IsShown() and ui.quantity.points.LEFT[1] == ui.quantityType)
    assert(ui.craftOne:GetWidth() * 2 + ui.quantityUp.parent:GetWidth() < width)
end
flush()
local graph = ui.graph
assert(graph.frame.clips == true)
assert(#graph.layout == 3 and graph.layout[3].parent == graph.layout[2])
local oldSelection, oldView = ui.selectedRecipeId, graph.position
graph:Zoom(0.12)
local oldZoom = graph.position.zoom
graph:Toggle(graph.layout[2].path)
assert(#graph.layout == 2)
ns:Emit("INVENTORY_CHANGED")
flush()
assert(ui.selectedRecipeId == oldSelection and graph.position == oldView and graph.position.zoom == oldZoom)
assert(#graph.layout == 2, "fold state lost in bag refresh")

local mooncloth = ui.recipeRows[2]
assert(mooncloth.record.recipe.id == 33)
mooncloth:Fire("OnClick", "RightButton")
ui.menu.actions[1]:Fire("OnClick")
assert(ui.saved.recipeMeta["33"].favorite and ui.selectedRecipeId == oldSelection)
mooncloth:Fire("OnClick", "RightButton")
ui.menu.actions[2]:Fire("OnClick")
ui.menu.editor:SetText("  Cooldowns  ")
ui.menu.editor:Fire("OnEnterPressed")
assert(ui.saved.recipeMeta["33"].group == "Cooldowns")
mooncloth:Fire("OnClick", "RightButton")
ui.menu.actions[3]:Fire("OnClick")
ui.menu.editor:SetText("Weekly material")
ui.menu.editor:Fire("OnEnterPressed")
assert(ui.saved.recipeMeta["33"].note == "Weekly material" and ui.saved.recipeMeta[tostring(oldSelection)] == nil)
ui.groups:Fire("OnClick")
assert(ui.groups:GetText() == "Cooldowns" and ui.recipeRows[1].record.recipe.id == 33)
ui.groups:Fire("OnClick")
ui.search:SetText("weekly material")
ui.search:Fire("OnTextChanged", true)
flush()
assert(ui.recipeRows[1].record.recipe.id == 33 and not ui.recipeRows[2]:IsShown())
ui.search:SetText("")
ui.search:Fire("OnTextChanged", true)
flush()
ui.filter:Fire("OnClick")
assert(ui.filter:GetText() == ns.L.favorites and ui.recipeRows[1].record.recipe.id == 33)
ui.recipeRows[1]:Fire("OnClick", "RightButton")
ui.menu.actions[1]:Fire("OnClick")
assert(not ui.saved.recipeMeta["33"].favorite and not ui.recipeRows[1]:IsShown())

ui.queuePlan:Fire("OnClick")
flush()
local job = ui.job
assert(job and #job.tasks == 2 and ui.graph.frame:IsVisible() and ui.queuePane:IsVisible(),
    "queueing should show the accepted graph and queue together")
assert(#ns.Queue.GetJobs() == 1)
local acceptedObjective, acceptedRevision = job.summary.objectiveKey, job.planRevision
ui.estimate:Fire("OnClick", "RightButton")
ui.menu.actions[2]:Fire("OnClick")
assert(ns.Logistics.GetSettings().objective == "cash" and ui.job == job
    and job.summary.objectiveKey == acceptedObjective and job.planRevision == acceptedRevision,
    "changing the pricing objective must preserve the accepted job and its estimates")
ui.estimate:Fire("OnClick", "RightButton")
ui.menu.actions[1]:Fire("OnClick")
ui.queuePlan:Fire("OnClick")
assert(#ns.Queue.GetJobs() == 1, "double-click queued duplicate")
assert(ui.queuePane.parent == ui.plan and ui.plan.parent.parent == ui.window)
ui.process:Fire("OnClick")
assert(ns.processed and ns.processed[1] == job and ns.processed[2] == job.tasks[1],
    "processing the selected job must start its prerequisite")
ui.queueToggle:Fire("OnClick")
assert(not ui.queuePane:IsVisible() and ui.graph.frame:IsVisible() and ui.process:IsVisible() and ui.process.enabled)
ui.process:Fire("OnClick")
assert(not ui.queuePane:IsVisible() and ns.processed[1] == job,
    "Process runs the queue without opening or replacing any part of the main view")

local supplyArgs = {itemID = 100, quantity = 9, intent = "supply", choices = {[100] = {source = "Buy"}}}
local supply = assert(ns.Queue.Accept(ns.Logistics.Preview(supplyArgs), function()
    return ns.Logistics.Preview(supplyArgs)
end))
ui.job, ui.requirement = supply, ns.Queue.GetRequirements(supply)[1]
local mail, purchases, ready, mailVerified = 4, {}, false, true
ns.Logistics.GetAuctionNeed = function(entry)
    assert(entry.job == supply)
    return {remaining = entry.quantity, pendingMail = mail, pendingIncoming = mail,
        toBuy = mailVerified and entry.quantity - mail or nil,
        mailKnown = mailVerified, mailUsable = mailVerified, ready = ready, maxUnitPrice = 100, maxTotalPrice = 900,
        quote = ready and {quantity = 3, totalCopper = 240} or nil}
end
ns.Logistics.BuyAuction = function(entry, quantity)
    purchases[#purchases + 1] = {entry = entry, quantity = quantity}
    return true, "Fixture purchase"
end
ns.Logistics.PrepareAuction = function() return true, "searching" end
FluxAuctionRestock = {PrepareLogistics = function() end, ExecuteLogistics = function() end, Followup = restockLayer}
AuctionFrame = CreateFrame("Frame", nil, UIParent)
ui.RenderQueue()
ui.process:Fire("OnClick")
local pane = ui.auctionShopping
assert(pane:IsVisible() and pane.entries[1].quantity == 5 and pane.entries[1].incoming == 4 and ui.graph.frame:IsVisible())
assert(pane.anchorSide == "below" and pane.points.TOPLEFT[1] == AuctionFrame
    and pane.points.TOPLEFT[2] == "BOTTOMLEFT" and pane.points.TOPLEFT[4] <= -30,
    "the combined layout leaves room for the native auction tabs")
AuctionFrame.top = 695
ns:Emit("INVENTORY_CHANGED")
assert(pane.anchorSide == "right" and pane.points.TOPLEFT[2] == "TOPRIGHT",
    "a low auction window repositions the panel beside it without losing the selection")
AuctionFrame.top = nil
ns:Emit("INVENTORY_CHANGED")
assert(pane.anchorSide == "below" and pane.entry.job == supply)
assert(pane.rows[1].action:GetText() == ns.L.shoppingFindOffer)
ready = true
ns:Emit("ACQUISITION_CHANGED", "auctionState", ui.requirement)
pane.rows[1].action:Fire("OnClick")
assert(#purchases == 1 and purchases[1].quantity == 5 and purchases[1].entry.job == supply)

AuctionFrame:Hide()
ui.ShowNative()
assert(not ui.classic:IsShown() and TradeSkillFrame:IsShown() and TradeSkillFrame:GetAlpha() == 1)
ui.ShowWorkbench(true)
assert(ui.classic:IsVisible() and layeredSurface == ui.window)
TradeSkillFrame:Hide()
assert(not ui.classic:IsVisible())
assert(not readProfessionSurface() and not layeredSurface, "the closed workbench must release the higher HUD layer")
local auctionOwner = CreateFrame("Frame", nil, UIParent)
AuctionFrame = auctionOwner
ready = false
local selected = {itemID = 100, jobId = supply.id, id = 1, planRevision = supply.planRevision}
assert(not ui.OpenAuctionShopping(auctionOwner, {itemID = 100, jobId = supply.id, id = 1, planRevision = -1}))
assert(ui.OpenAuctionShopping(auctionOwner, selected))
local shopping = ui.auctionShopping
assert(shopping:IsVisible() and shopping.parent == UIParent and shopping.anchor == auctionOwner and not ui.classic:IsVisible())
assert(shopping.entries[1].quantity == 5 and shopping.rows[1].action:GetText() == ns.L.shoppingFindOffer)
ready = true
ns:Emit("ACQUISITION_CHANGED", "auctionState", ui.requirement)
assert(shopping.status:GetText():find("3 for", 1, true))
assert(shopping.rows[1].action:GetText() == ns.L.shoppingBuyQuantity:format(3))
shopping.rows[1].action:Fire("OnClick")
assert(#purchases == 2 and purchases[2].quantity == 5)
mail = 7
ns:Emit("INVENTORY_CHANGED")
assert(shopping.entries[1].quantity == 2, "mail updates must reduce the remainder")
mail, mailVerified = 9, false
ns:Emit("INVENTORY_CHANGED", {mail = true})
assert(shopping.entries[1].incoming == 9 and shopping.entries[1].quantity == 0
    and not shopping.rows[1].action.enabled and shopping.status:GetText() == ns.L.shoppingCollectMail,
    "a qualified complete delivery is visible and blocks redundant buying while full mailbox verification is pending")
auctionOwner:Hide()
assert(not shopping:IsShown())
FluxAuctionRestock = nil

local bundleRecipe = {id = 61, professionId = 5, outputItemID = 600, outputKind = "item", yield = 1,
    learned = true, completeness = "complete", characterKey = ns.state.characterKey,
    reagents = {{itemID = 601, quantity = 2}}}
local catalogue = {recipesById = {[61] = bundleRecipe}, byOutput = {[600] = {61}}, revision = 3}
Flux = {RestockPolicy = {GetVendorPriceEstimate = function(itemID)
    if itemID == 601 then return {unit = "item", bundleSize = 5, bundlePrice = 10, unitPrice = 2, source = "fixture"} end
end}}
local shortlistRow = {recipe = bundleRecipe}
ns.RecipeList.Evaluate(shortlistRow, "fromBags", "name", catalogue)
assert(shortlistRow.score == -2 and shortlistRow.badge == ns.L.shortage:format(2),
    "the shortlist must count missing materials, not unallocated vendor bundle surplus")
bundleRecipe.difficulty, bundleRecipe.canSkillUp = "optimal", false
local skillRow = {recipe = bundleRecipe}
ns.RecipeList.Evaluate(skillRow, "best", "difficulty", catalogue)
assert(skillRow.score == nil, "Best picks must omit a recipe with no observed skill-up eligibility from the skill ranking")
bundleRecipe.canSkillUp = true
skillRow = {recipe = bundleRecipe}
ns.RecipeList.Evaluate(skillRow, "best", "difficulty", catalogue)
assert(skillRow.score == -1, "Best picks must use the observed Classic difficulty for an eligible skill-up recipe")
print("Classic workbench, graph state and persistent queue fixtures passed")

do
    local fixture, _, stock = dofile("Tests/ui_fixture.lua")("classic")
    local workbench, queue = fixture.UI, fixture.Queue
    stock[200] = 10
    local function carriedPlan()
        return fixture.Logistics.Preview({recipeId = 11, directMaximum = 5, bagsOnly = true})
    end
    fixture.Execution.CraftSelected = function()
        local job = assert(queue.Accept(carriedPlan(), carriedPlan))
        return true, "Created first batch", job
    end
    workbench.queueToggle:Fire("OnClick")
    assert(not workbench.queuePane:IsShown())
    workbench.craftAll:Fire("OnClick")
    assert(workbench.job == queue.GetJobs()[1] and workbench.queuePane:IsShown()
        and workbench.queueRows[1].line.job == workbench.job,
        "Create All selects its saved job and opens the compact queue in place")
    local job, task = workbench.job, workbench.job.tasks[1]
    local header = workbench.queueRows[1]
    assert(header.caption:GetText():match("^5× "))
    assert(queue.Begin(job, task, {beforeOutput = 0, batch = 5}))
    fixture.Execution.GetActiveCast = function(selectedJob, selectedTask)
        assert(selectedJob == job and selectedTask == task)
        return {startTimeMs = 1000, endTimeMs = 46000}
    end
    fixture:Emit("CRAFT_CAST_CHANGED")
    assert(header.progress:GetText():find("(45.0s)", 1, true), "the order shows its measured cast duration")
    fixture.Execution.GetActiveCast = function() return nil, true end
    fixture:Emit("CRAFT_CAST_CHANGED")
    assert(header.caption:GetText():match("^5× ") and header.progress:GetText():find("Verifying", 1, true),
        "a cast without a receipt keeps its remaining count visible")
    fixture.Execution.GetActiveCast = nil
    queue.CraftEvent(job, task, 1, 1)
    assert(not queue.Reconcile(job, task, 1))
    assert(task.completedExecutions == 0 and queue.OutstandingOutput(job) == 5 and header.caption:GetText():match("^4× ")
        and header.progress:IsVisible() and header.progress:GetText():find("1/1  Crafting 4", 1, true)
        and header.icon:IsShown(),
        "a verified carried result updates the visible count while the batch is still active")
    header.detail:Fire("OnClick")
    assert(workbench.menu:IsShown() and not (workbench.queueRows[2] and workbench.queueRows[2]:IsShown())
        and header:GetHeight() == 20)
    queue.MarkUncertain(job, task)
    assert(header.caption:GetText():match("^4× ") and header.message:find("Stopped at 4", 1, true)
        and header.caption:GetText():find(fixture.L.uncertain, 1, true),
        "the one-line interrupted order keeps its observed output and exposes the stopped step")
    assert(queue.ReconcilePartial(job, task) and header.caption:GetText():match("^4× ")
        and header.message:find("Next 4", 1, true),
        "settling the partial batch keeps the remaining count and shows the next step")
    assert(queue.Begin(job, task, {beforeOutput = 1, batch = 4}))
    queue.CraftEvent(job, task, 4, 4)
    assert(queue.Reconcile(job, task, 5) and header.caption:GetText() == fixture.L.queueEmpty
        and not header.progress:IsShown() and not header.icon:IsShown() and workbench.graph.outputAmount == "0",
        "the final verified result removes the order and leaves no outstanding graph output")
end

do
    local setup = dofile("Tests/ui_fixture.lua")
    local function directChoiceWithStock(ownedNominal, createAll, acceptNominal)
        local fixture, _, stock = setup("forever", {}, function(ns)
            local recipe = ns.Catalog.Get(11)
            local nominal = {{itemID = 8100, quantity = 1, slotIndex = 1}}
            local alternate = {{itemID = 8101, quantity = 1, slotIndex = 1}}
            recipe.reagents = nominal
            recipe.reagentChoices = {{reagents = nominal}, {reagents = alternate}}
            ns.MarketAdapter.QuoteItems = function()
                return {[8100] = 1, [8101] = 20, [100] = 100}
            end
        end)
        local workbench, queue = fixture.UI, fixture.Queue
        stock[8100], stock[8101] = ownedNominal, 3
        if not createAll then workbench.quantity:SetText("2") end
        workbench.Refresh()
        assert(workbench.preview.tasks[1].reagentChoice.reagents[1].itemID == 8100,
            "the economic preview prefers the cheap auction reagent even if it must be bought")
        local prior
        if acceptNominal then
            workbench.queuePlan:Fire("OnClick")
            prior = assert(workbench.job)
            assert(prior.reservations["8100"] == 1)
        end

        assert(loadfile("FluxCraft/Execution.lua"))("FluxLogistics", fixture)
        fixture.Clients.Resolve = function(task)
            return {kind = "forever", recipeID = task.recipeId, maxYield = task.yield}
        end
        local submitted
        fixture.Clients.Craft = function(task, _, count, beforeClick)
            assert(beforeClick(count))
            submitted = {count = count, itemID = task.reagentChoice.reagents[1].itemID}
            return true, nil, count
        end
        local button = createAll and workbench.craftAll or workbench.craftOne
        button:Fire("OnClick")
        local job = assert(workbench.job)
        local itemID = prior and 8100 or 8101
        local count = prior and 1 or createAll and 3 or 2
        assert(submitted and submitted.itemID == itemID and submitted.count == count
            and job.tasks[1].executions == count and job.reservations[tostring(itemID)] == count
            and #job.requirements == 0, "Create uses eligible carried materials for the requested count")
        assert(not prior or prior ~= job and prior.reservations["8100"] == 1
            and queue.Reserved()["8100"] == 2 and not queue.Reserved()["8101"],
            "an accepted plan pins its exact reagent and does not spend that job's reservation")
    end
    directChoiceWithStock(0, true)
    directChoiceWithStock(1, true)
    directChoiceWithStock(1, false)
    directChoiceWithStock(2, true, true)
end

do
    local fixture, _, stock, events = dofile("Tests/ui_fixture.lua")("forever", {}, function(ns)
        ns.Catalog.Get(11).reagents = {{itemID = 6100, quantity = 2}}
        ns.MarketAdapter.QuoteItems = function() return {[6100] = 50, [100] = 200} end
    end)
    local workbench, queue = fixture.UI, fixture.Queue
    stock[6100] = 6
    local function reserve()
        return fixture.Logistics.Preview({recipeId = 11, directMaximum = 1, bagsOnly = true})
    end
    local other = assert(queue.Accept(reserve(), reserve))
    assert(other.reservations["6100"] == 2)

    assert(loadfile("FluxCraft/Execution.lua"))("FluxLogistics", fixture)
    fixture.Clients.Resolve = function(task)
        return {kind = "forever", recipeID = task.recipeId, maxYield = task.yield}
    end
    local casts = {}
    fixture.Clients.Craft = function(task, _, count, beforeClick)
        local job = queue.GetJobs()[2]
        assert(task == job.tasks[1] and queue.CanProcess(job, task, count)
            and not queue.CanProcess(job, task, count + 1) and beforeClick(count))
        casts[#casts + 1] = count
        stock[6100], stock[100] = stock[6100] - 2 * count, (stock[100] or 0) + count
        events.TRADE_SKILL_CRAFT_BEGIN:Fire("OnEvent", "TRADE_SKILL_CRAFT_BEGIN", task.recipeId)
        events.TRADE_SKILL_ITEM_CRAFTED_RESULT:Fire("OnEvent", "TRADE_SKILL_ITEM_CRAFTED_RESULT",
            {itemID = 100, quantity = count, operationID = #casts})
        return true, nil, count
    end

    workbench.quantity:SetText("5")
    workbench.craftOne:Fire("OnClick")
    local first = assert(workbench.job)
    assert(first == queue.GetJobs()[2] and first.summary.requested == 5 and first.tasks[1].executions == 5
        and first.tasks[1].completedExecutions == 2 and first.tasks[1].remainingExecutions == 3 and casts[1] == 2
        and first.requirements[1].remaining == 6 and other.reservations["6100"] == 2 and stock[6100] == 2,
        "Create starts its own carried prefix and keeps the whole entered order with exact sourcing quantities")

    workbench.craftOne:Fire("OnClick")
    local second = assert(workbench.job)
    assert(second == queue.GetJobs()[3] and second.tasks[1].remainingExecutions == 5 and #casts == 1
        and second.requirements[1].remaining == 10 and queue.CanGroup(first, second),
        "Create accepts a compatible full order with zero free materials and does not craft someone else's stock")

    fixture.Execution.InventoryChanged({reliable = true}, {regions = {bags = true}})
    stock[6100] = stock[6100] + 6
    fixture.Execution.InventoryChanged({reliable = true}, {regions = {bags = true}})
    assert(first.requirements[1].remaining == 0 and second.requirements[1].remaining == 10 and #casts == 1,
        "arrival credits the oldest order once and never starts a craft in the background")
    assert(fixture.Execution.ProcessNext(first) and first.status == "complete"
        and first.tasks[1].completedExecutions == 5 and casts[2] == 3
        and second.tasks[1].remainingExecutions == 5 and stock[6100] == 2 and other.reservations["6100"] == 2,
        "Process creates the exact remaining batch from the newly acquired stock")
end

do
    local nextFixture = dofile("Tests/ui_fixture.lua")("classic")
    local workbench, queue = nextFixture.UI, nextFixture.Queue
    workbench.queuePlan:Fire("OnClick")
    local finished = assert(workbench.job)
    local function nextPreview() return nextFixture.Logistics.Preview({recipeId = 22, quantity = 2}) end
    local nextJob = assert(queue.Accept(nextPreview(), nextPreview))
    while finished.status ~= "complete" do
        local job, task = queue.NextTask(nil, finished)
        assert(job == finished and task)
        local batch = task.remainingExecutions
        assert(queue.Begin(finished, task, {beforeOutput = 0, batch = batch}))
        queue.CraftEvent(finished, task, batch, batch * task.yield)
        assert(queue.Reconcile(finished, task, batch * task.yield))
    end
    assert(workbench.job == finished and workbench.process.enabled)
    workbench.process:Fire("OnClick")
    assert(nextFixture.processed and nextFixture.processed[1] == nextJob and workbench.job == finished,
        "Process should advance another job while leaving the completed one selected for inspection")
    local function buyPreview()
        return nextFixture.Logistics.Preview({itemID = 100, quantity = 2, intent = "supply", choices = {[100] = {source = "Buy"}}})
    end
    local cancelled = assert(queue.Accept(buyPreview(), buyPreview))
    workbench.job, workbench.requirement = cancelled, assert(queue.GetRequirements(cancelled)[1])
    assert(queue.Cancel(cancelled.id))
    nextFixture.processed = nil
    workbench.process:Fire("OnClick")
    assert(not workbench.requirement and nextFixture.processed and nextFixture.processed[1] == nextJob,
        "a cancelled acquisition must release the selected Process action")

    local reordered = assert(queue.Accept(buyPreview(), buyPreview))
    workbench.job = reordered
    workbench.queueToggle:Fire("OnClick", "RightButton")
    assert(workbench.menu.actions[2]:GetText() == nextFixture.L.moveUp)
    workbench.menu.actions[2]:Fire("OnClick")
    assert(queue.GetJobs()[2] == reordered and reordered.status == "queued")
    workbench.queueToggle:Fire("OnClick", "RightButton")
    assert(workbench.menu.actions[3]:GetText() == nextFixture.L.moveDown)
    workbench.menu.actions[3]:Fire("OnClick")
    assert(queue.GetJobs()[2] == nextJob and reordered.status == "queued")
    workbench.RenderQueue()
    for _, row in ipairs(workbench.queueRows) do
        if row.line and row.line.job == reordered then row.remove:Fire("OnClick"); break end
    end
    assert(reordered.status == "cancelled" and queue.GetJob(reordered.id) == reordered,
        "removing a row releases its pending work and keeps its journal")

    local pending = assert(queue.Accept(buyPreview(), buyPreview))
    local task = nextJob.tasks[1]
    assert(queue.Begin(nextJob, task, {beforeOutput = 0, batch = 1}))
    workbench.queueClear:Fire("OnClick")
    assert(queue.IsClearing(nextJob) and pending.status == "cancelled"
        and workbench.queueRows[1].caption:GetText() == nextFixture.L.queueEmpty,
        "Clear hides pending work immediately while preserving the submitted native result")
    queue.CraftEvent(nextJob, task, 1, task.yield)
    assert(queue.Reconcile(nextJob, task, task.yield))
    assert(task.completedExecutions == 1 and not queue.IsClearing(nextJob))
    local latest = assert(queue.Accept(buyPreview(), buyPreview))
    workbench.queueClear:Fire("OnClick")
    assert(finished.status == "complete" and nextJob.status == "complete" and pending.status == "cancelled"
        and latest.status == "cancelled" and #queue.GetJobs() == 6 and not workbench.menu:IsShown(),
        "one click clears pending work and preserves the queue history")
end

do
    local fixture, _, stock = dofile("Tests/ui_fixture.lua")("classic")
    local workbench, queue = fixture.UI, fixture.Queue
    local recipe = fixture.Catalog.Get(11)
    recipe.name, recipe.professionName = "Green Silk Pack", "Tailoring"
    stock[300] = 20
    workbench.Refresh()
    workbench.queuePlan:Fire("OnClick")
    local first = assert(workbench.job)
    workbench.quantityUp:Fire("OnClick", "LeftButton")
    workbench.quantityDown:Fire("OnClick", "LeftButton")
    workbench.queuePlan:Fire("OnClick")
    local second = assert(workbench.job)
    local firstRow = workbench.queueRows[1]
    assert(first ~= second and #queue.GetJobs() == 2 and firstRow.caption:GetText() == "2× Green Silk Pack (Tailoring)"
        and not (workbench.queueRows[2] and workbench.queueRows[2]:IsShown()) and firstRow.icon:IsShown(),
        "compatible Green Silk Pack orders share one icon row with the summed output")
    assert(firstRow.message:find(fixture.Catalog.Get(second.tasks[1].recipeId).name, 1, true),
        "the row tooltip includes its actual next producer recipe")
    firstRow.detail:Fire("OnClick")
    for _, action in ipairs(workbench.menu.actions) do
        if action:IsShown() and action:GetText() == fixture.L.queueNextOrder:format(1, 2) then action:Fire("OnClick"); break end
    end
    workbench.process:Fire("OnClick")
    assert(fixture.processed[1] == first and fixture.processed[2] == first.tasks[1],
        "a selected row processes its exact job")

    local function complete(job, task)
        local count = task.remainingExecutions
        assert(queue.Begin(job, task, {beforeOutput = 0, batch = count}))
        queue.CraftEvent(job, task, count, count * task.yield)
        assert(queue.Reconcile(job, task, count * task.yield))
    end
    complete(first, first.tasks[1])
    assert(first.tasks[1].status == "complete" and firstRow.caption:GetText():match("^2× ")
        and not firstRow.message:find(fixture.Catalog.Get(first.tasks[1].recipeId).name, 1, true),
        "completion updates the next-step text on the same single job row")

    for _, task in ipairs(second.tasks) do complete(second, task) end
    assert(second.status == "complete" and workbench.job == first and firstRow.caption:GetText():match("^1× "),
        "settlement removes one lot from the visible total and retains the active group selection")
    local function differentPlan()
        return fixture.Logistics.Preview({recipeId = 11, quantity = 2, choices = {[200] = {source = "Buy"}}})
    end
    local different = assert(queue.Accept(differentPlan(), differentPlan))
    local headers = {}
    for _, row in ipairs(workbench.queueRows) do
        if row.line then headers[#headers + 1] = row.line end
    end
    assert(#headers == 2 and headers[2].job == different and workbench.queueRows[2].caption:GetText():match("^2× "),
        "a different source choice stays in a separate row for the same recipe")
    complete(first, first.tasks[2])
    assert(first.status == "complete" and firstRow.line.job == different and not workbench.queueRows[2]:IsShown()
        and queue.GetJob(first.id) == first and queue.GetJob(second.id) == second,
        "completed lots disappear from the active rows while their journals remain available")
end

do
    local fixture, flush, stock = dofile("Tests/ui_fixture.lua")("forever")
    local workbench, queue = fixture.UI, fixture.Queue
    local alternate = fixture.Catalog.Get(33)
    alternate.constraints = nil
    stock[200], stock[300] = 20, 20
    local function accept(recipeID)
        local function preview() return fixture.Logistics.Preview({recipeId = recipeID, quantity = 2}) end
        return assert(queue.Accept(preview(), preview))
    end
    local first, second = accept(11), accept(33)
    local stopped = first.tasks[1]
    assert(queue.Begin(first, stopped, {batch = 1, beforeOutput = 0}))
    queue.MarkUncertain(first, stopped)
    assert(stopped.status == "uncertain")
    flush()
    local row = workbench.queueRows[2]
    row:Fire("OnClick", "LeftButton")
    row:Fire("OnClick", "LeftButton")
    assert(workbench.job == second and row.selected:IsShown() and row.progress:IsVisible()
        and row.progress:GetText():find("1/1  Next", 1, true), "the selected queue row keeps its exact job selected")
    fixture.Execution.ReconcileUncertain = function() error("another order must not take the selected action") end
    workbench.process:Fire("OnClick")
    assert(fixture.processed[1] == second and fixture.processed[2] == second.tasks[1] and stopped.status == "uncertain",
        "an unrelated interrupted row must not redirect Process")
end

do
    local fixture, _, stock = dofile("Tests/ui_fixture.lua")("classic")
    local workbench, queue, catalog = fixture.UI, fixture.Queue, fixture.Catalog.Snapshot()
    stock[300], stock[301] = 20, 20
    fixture.MarketAdapter.QuoteItems = function() return {[200] = 90, [300] = 1, [301] = 1} end
    local function accept(quantity)
        local function preview() return fixture.Logistics.Preview({recipeId = 11, quantity = quantity}) end
        return assert(queue.Accept(preview(), preview))
    end
    local first = accept(1)
    stock[200] = 4
    local carried = accept(2)
    workbench.job = carried
    catalog.recipesById[22].constraints = {cooldownUntil = 1000}
    catalog.recipesById[23] = {id = 23, outputItemID = 200, professionId = 6, yield = 2,
        completeness = "complete", learned = true, characterKey = fixture.state.characterKey,
        reagents = {{itemID = 301, quantity = 1}}}
    catalog.byOutput[200][2] = 23
    local alternate = accept(3)
    assert(first.tasks[1].recipeId == 22 and #carried.tasks == 1 and alternate.tasks[1].recipeId == 23)
    assert(workbench.queueRows[1].caption:GetText():match("^3× ") and workbench.queueRows[1].line.job == carried
        and workbench.queueRows[2].line.job == alternate,
        "a carried intermediate may join the first producer group without joining a different exact producer")
    workbench.queueRows[1].detail:Fire("OnClick")
    for _, action in ipairs(workbench.menu.actions) do
        if action:IsShown() and action:GetText() == fixture.L.queueNextOrder:format(1, 2) then action:Fire("OnClick"); break end
    end
    workbench.queueRows[1].detail:Fire("OnClick")
    for _, action in ipairs(workbench.menu.actions) do
        if action:IsShown() and action:GetText() == fixture.L.queueCancelOrder then action:Fire("OnClick"); break end
    end
    assert(first.status == "cancelled" and carried.status == "queued" and alternate.status == "queued"
        and workbench.queueRows[1].line.job == carried,
        "the selected order can be cancelled without cancelling another accepted lot")
    assert(queue.SetPaused(alternate.id, true))
    local compatible = accept(4)
    assert(queue.CanGroup(carried, compatible) and workbench.queueRows[1].caption:GetText():match("^6× "))
    workbench.queueRows[1].remove:Fire("OnClick")
    assert(carried.status == "cancelled" and compatible.status == "cancelled" and alternate.status == "paused",
        "the grouped row X cancels exactly the compatible orders in that row")
end

do
    local fixture, _, stock = dofile("Tests/ui_fixture.lua")("classic")
    local workbench, queue = fixture.UI, fixture.Queue
    stock[200], stock[300] = 500, 500
    local catalog = fixture.Catalog.Snapshot()
    local jobs = {}
    for quantity = 1, 10 do
        local recipeID, itemID = 400 + quantity, 500 + quantity
        local recipe = {}
        for key, value in pairs(fixture.Catalog.Get(11)) do recipe[key] = value end
        recipe.id, recipe.recipeID, recipe.outputItemID = recipeID, recipeID, itemID
        catalog.recipesById[recipeID], catalog.byOutput[itemID] = recipe, {recipeID}
        local function preview() return fixture.Logistics.Preview({recipeId = recipeID, quantity = quantity}) end
        jobs[quantity] = assert(queue.Accept(preview(), preview))
    end
    workbench.queueRows[1]:Fire("OnClick", "LeftButton")
    workbench.plan:SetHeight(255)
    assert(workbench.queueLater:IsShown() and workbench.queueRows[1].line.job == jobs[1])
    workbench.queueLater:Fire("OnClick")
    assert(workbench.queueOffset == 1 and workbench.queueRows[1].line.job == jobs[2], "overflow scrolls fixed single rows")
    workbench.plan:SetHeight(620)
    assert(not workbench.queueLater:IsShown() and workbench.queueOffset == 0
        and workbench.queueRows[10].line.job == jobs[10] and workbench.queueRows[10].icon:IsShown(),
        "a tall workbench shows more than six jobs and clamps the previous scroll offset")
    local expandedGraph = workbench.graph.frame:GetHeight()
    workbench.graph:Toggle(workbench.graph.layout[1].path)
    assert(workbench.graph.frame:GetHeight() <= expandedGraph and workbench.queueRows[10]:IsVisible(),
        "a folded diagram retains the larger queue viewport")
end

do
    local fixture, _, stock = dofile("Tests/ui_fixture.lua")("forever")
    local workbench = fixture.UI
    local recipe = fixture.Catalog.Get(11)
    local inexpensive = {reagents = {{itemID = 300, quantity = 1, slotIndex = 1}}}
    local stocked = {reagents = {{itemID = 301, quantity = 1, slotIndex = 1}}}
    recipe.reagents, recipe.reagentChoices = inexpensive.reagents, {inexpensive, stocked}
    stock[300], stock[301] = 1, 8
    fixture.MarketAdapter.QuoteItems = function()
        return {[100] = {unitPrice = 100, unit = "item", provider = "Auctionator"}, [300] = 1, [301] = 10}
    end
    fixture.Clients.Resolve = function(task)
        assert(task.recipeId == 11)
        return {maxExecutions = 10}
    end
    assert(loadfile("FluxCraft/Execution.lua"))("FluxLogistics", fixture)
    workbench.Refresh()
    local entered = workbench.quantity:GetText()
    assert(workbench.queueAll.enabled and workbench.preview.tasks[1].reagentChoice.reagents[1].itemID == 300,
        "the ordinary preview should keep the cheapest eligible material choice")
    workbench.queueAll:Fire("OnClick")
    assert(workbench.job.tasks[1].executions == 8 and workbench.job.tasks[1].reagentChoice.reagents[1].itemID == 301
        and workbench.quantity:GetText() == entered and workbench.job.status == "queued" and workbench.queuePane:IsVisible(),
        "Queue All must seal the largest eligible batch without changing the entered amount or crafting")
end

local function menuEntry(label, invoke)
    local entry = {label = label, invoke = invoke, children = {}}
    function entry:CreateButton(text, callback)
        local child = menuEntry(text, callback)
        self.children[#self.children + 1] = child
        return child
    end
    function entry:CreateDivider() self:CreateButton("divider") end
    function entry:SetEnabled(value) self.enabled = value end
    return entry
end

local function treeNode(info, collapsed)
    return {collapsed = collapsed, GetData = function() return {recipeInfo = info} end}
end

local base = {recipeID = 440, learned = true}
local highest = {recipeID = 44, learned = true}
local first = treeNode({recipeID = 11, learned = true})
local upgrade = treeNode(base, true)
local provider, generate, selected, scrolled
local function tree(nodes)
    local result = {EnumerateEntireRange = function() return ipairs(nodes) end}
    function result:FindElementDataByPredicate(predicate, excludeCollapsed)
        assert(excludeCollapsed == false)
        for _, node in ipairs(nodes) do if predicate(node) then return node end end
    end
    return result
end
local menuOpen, onMenuOpen, usesNativeFilters = false, nil, 0
local function withNativeFilter(fixture)
    local callbacks = {}
    generate = function(owner, root)
        for _, callback in ipairs(callbacks.MENU_PROFESSIONS_FILTER or {}) do callback(owner, root) end
    end
    Menu = {ModifyMenu = function(tag, callback)
        callbacks[tag] = callbacks[tag] or {}
        callbacks[tag][#callbacks[tag] + 1] = callback
    end}
    MenuResponse = {Refresh = "Refresh"}
    TreeDataProviderConstants = {IncludeCollapsed = false}
    Enum = {TradeskillRelativeDifficulty = {Optimal = 7, Medium = 4, Easy = 1}}
    Professions = {GetHighestLearnedRecipe = function(info) return info == base and highest or info end}
    NO_RESULTS_FOUND = "No results found"
    local snapshot = fixture.Catalog.Snapshot()
    snapshot.recipesById[11].difficulty, snapshot.recipesById[11].canSkillUp = Enum.TradeskillRelativeDifficulty.Easy, true
    snapshot.recipesById[44] = {id = 44, recipeID = 44, professionId = 5, outputItemID = 444, outputKind = "item",
        characterKey = fixture.state.characterKey, learned = true, completeness = "complete", yield = 2,
        difficulty = Enum.TradeskillRelativeDifficulty.Optimal, canSkillUp = true,
        name = "Silk bolts", reagents = {{itemID = 300, quantity = 2}}}
    snapshot.byOutput[444] = {44}
    fixture.MarketAdapter.QuoteItems = function()
        return {[444] = {unitPrice = 100, unit = "item", provider = "Auctionator"}, [300] = 20}
    end
    local page = ProfessionsFrame.CraftingPage
    provider = tree({first, upgrade, treeNode({recipeID = 11, learned = true, favoritesInstance = true}),
        treeNode({recipeID = 33, learned = false}), treeNode({recipeID = 33, learned = true, isRecraft = true})})
    local list = page.RecipeList
    list.ScrollBox = {GetDataProvider = function() return provider end,
        ScrollToElementData = function(_, node) scrolled, node.collapsed = node, false end}
    page.OnRecipeSelected = function(self, info, source)
        assert(source == list)
        selected = info
        self.SchematicForm.selectedID = Professions.GetHighestLearnedRecipe(info).recipeID
    end
    local dropdown = CreateFrame("Frame", nil, list)
    list.FilterDropdown = dropdown
    function dropdown:RegisterCallback(event, callback)
        assert(event == "OnMenuOpen")
        onMenuOpen = callback
    end
    function dropdown:IsMenuOpen() return menuOpen end
    function dropdown:GenerateMenu()
        local root = menuEntry()
        root:CreateButton("Native filter", function() usesNativeFilters = usesNativeFilters + 1 end)
        generate(self, root)
        self.root = root
    end
end

local forever, flushForever, _, foreverEvents = dofile("Tests/ui_fixture.lua")("forever", nil, withNativeFilter)
forever.Logistics.GetSettings().market = {rate = 5}
local recipeList = ProfessionsFrame.CraftingPage.RecipeList
local dropdown = recipeList.FilterDropdown
local foreign = menuEntry()
generate({}, foreign)
assert(#foreign.children == 0, "another page's Filter menu must remain native")
assert(not forever.UI.listPane and not forever.UI.filter, "shortlists must use the native dropdown")

local evaluate, evaluations = forever.RecipeList.Evaluate, 0
forever.RecipeList.Evaluate = function(...)
    evaluations = evaluations + 1
    return evaluate(...)
end
dropdown:GenerateMenu()
local children = dropdown.root.children
assert(#children == 5 and children[3].label == forever.L.fromBags and children[4].label == forever.L.best
    and children[5].label == forever.L.sell)
children[1].invoke()
assert(usesNativeFilters == 1 and children[3].children[1].enabled == false)
menuOpen = true
onMenuOpen()
assert(evaluations == 0, "opening Filter must defer expensive planner work")
menuOpen = false
flushForever()
assert(evaluations == 6, "shortlist work should finish once for the two exact native recipes")
dropdown:GenerateMenu()
menuOpen = true
onMenuOpen()
flushForever()
assert(evaluations == 6, "reopening Filter must reuse the complete shortlist while inputs are unchanged")
children = dropdown.root.children
local fromBags, best, sell = children[3].children, children[4].children, children[5].children
local profits, costs, skill = best[1].children, best[2].children, best[3].children
assert(#fromBags == 2 and fromBags[2].label:find(forever.L.now, 1, true))
assert(#profits == 1 and profits[1].label == forever.L.recommendation:format("Silk bolts", forever.Pricing.FormatProfit(150)))
assert(#costs == 2 and costs[1].label == forever.L.recommendation:format("Bolt of cloth", forever.Pricing.FormatCopper(20)))
assert(#skill == 2 and skill[1].label == "Silk bolts" and skill[2].label == "Bolt of cloth")
assert(#sell == 1 and sell[1].label == forever.L.recommendation:format("Silk bolts", forever.Pricing.FormatProfit(152)))
profits[1].invoke()
assert(selected == base and scrolled == upgrade and not upgrade.collapsed,
    "a recommendation must select the exact native base row for a learned upgrade outside the visible list")
foreverEvents["Professions.RecipeSelected"](ProfessionsFrame.CraftingPage, upgrade)
assert(forever.UI.selectedRecipeId == 44, "the flowchart must follow the highest learned selection")

provider = tree({first})
selected = nil
profits[1].invoke()
assert(not selected, "a stale result cannot select a recipe removed from the native filtered tree")
flushForever()
assert(dropdown.root.children[4].children[1].children[1].label == NO_RESULTS_FOUND)
forever.UI.ShowNative()
dropdown:GenerateMenu()
assert(#dropdown.root.children == 1, "Native UI mode must hide the workbench's shortlist actions")
print("Forever native shortlist reachability and multi-output economics fixtures passed")

do
    local fixture = dofile("Tests/ui_fixture.lua")("forever")
    local work = fixture.UI
    local function preview() return fixture.Logistics.Preview({recipeId = 22, quantity = 2}) end
    local order = assert(fixture.Queue.Accept(preview(), preview))
    local step = assert(order.tasks[1])
    local page = ProfessionsFrame.CraftingPage
    local current, presses = 5, 0
    fixture.Clients.CurrentProfessionID = function() return current end
    fixture.Execution.ProcessClick = function(job, task)
        assert(job == nil and task == nil, "browsing a recipe must leave Process free to find another profession")
        presses = presses + 1
        return false, fixture.L.execSwitch:format("Other"), order, "profession_switch", step
    end
    work.job = nil
    work.process:Fire("OnClick")
    assert(presses == 1 and work.job == order and page.SchematicForm.selectedID == 11)

    current = 6
    local previousTradeSkill = C_TradeSkillUI
    local learned = {recipeID = step.recipeId, learned = true}
    C_TradeSkillUI = {GetRecipeInfo = function(id) if id == step.recipeId then return learned end end}
    page.SelectRecipe = function(_, info, skipList)
        assert(info == learned and skipList == true, "open the exact native recipe without changing its list filter")
        page.SchematicForm.selectedID = info.recipeID
    end
    fixture:Emit("PROFESSION_CHANGED")
    fixture:Emit("PROFESSION_SWITCH_READY", order, step)
    assert(work.job == order and work.step == step and work.selectedRecipeId == order.rootRecipeId and presses == 1
        and page.SchematicForm.selectedID == step.recipeId,
        "a ready switch must focus the exact queued step without another Process or Create")
    C_TradeSkillUI = previousTradeSkill

    assert(fixture.Queue.Begin(order, step, {batch = 1, beforeOutput = 0}))
    fixture.Queue.MarkUncertain(order, step)
    current, work.job = 5, nil
    local opened = 0
    fixture.Execution.GetRecoveryProfession = function(job)
        if job == order and current ~= 6 then return 6, "Other" end
    end
    fixture.Execution.OpenRecoveryProfession = function(job)
        assert(job == order)
        opened = opened + 1
        return true, fixture.L.execSwitch:format("Other")
    end
    fixture.Execution.CanReplanFromBags = function(job) return job == order and current == 6 end
    fixture.Execution.ReplanFromBags = function() error("switching professions cannot replan yet") end
    work.RenderQueue()
    assert(work.process:GetText() == fixture.L.openRecoveryProfession)
    work.process:Fire("OnClick")
    assert(opened == 1 and presses == 1 and work.job == order and order.status == "uncertain")
    current = 6
    fixture:Emit("PROFESSION_CHANGED")
    work.RenderQueue()
    assert(work.process:GetText() == fixture.L.processShort and opened == 1,
        "opening the required profession returns the older stopped order to the normal Process action")
end

do
    local fixture = dofile("Tests/ui_fixture.lua")("forever")
    local work, queue = fixture.UI, fixture.Queue
    local function preview() return fixture.Logistics.Preview({recipeId = 11, quantity = 1}) end
    local job = assert(queue.Accept(preview(), preview))
    job.status = "uncertain"
    work.job = job
    local retried
    fixture.Execution.CanRetryBlockedCraft = function(selected) return selected == job and selected.status == "uncertain" end
    fixture.Execution.RetryBlockedCraft = function(selected)
        retried = selected
        selected.status = "queued"
        return true, fixture.L.execBlockedRetryReady
    end
    work.RenderQueue()
    assert(work.process:GetText() == fixture.L.processShort)
    work.process:Fire("OnClick")
    assert(retried == job and work.process:GetText() == fixture.L.processShort and not fixture.processed,
        "retrying a blocked step returns it to Process without issuing any craft")
end

do
    local previousAuction = FluxAuctionRestock
    FluxAuctionRestock = {Followup = restockLayer}
    restockLayer.HasProfessionReminderDock = true
    action = {kind = "craft", name = "Fixturesmithing", canAct = true}
    local fixture, settleUI = dofile("Tests/ui_fixture.lua")("forever")
    local work, pending, busy = fixture.UI, false, false
    local mountedSurface, _, initialDock = readProfessionSurface()
    assert(mountedSurface == work.window and initialDock and initialDock:IsVisible(),
        "an existing craft reserves the workbench reminder row before reader registration returns")
    local instruction = fixture.L.execNativeClick:format(2, "Fixturesmithing")
    fixture.Execution.HasNativeCraftPending = function() return pending end
    fixture.Execution.IsBusy = function() return busy end
    fixture.Execution.CancelNativeCraft = function() pending = false end
    fixture.Execution.CreateSelected = function()
        pending = true
        return true, instruction, nil, "native_click"
    end
    work.craftOne:Fire("OnClick")
    settleUI()
    local page = ProfessionsFrame.CraftingPage
    assert(work.window:IsShown() and work.window.points.TOPLEFT[1] == page and work.nativeCraftHint:IsVisible()
        and work.nativeCraftHint:GetText() == instruction and work.saved.nativeMode ~= true,
        "on a wide screen Flowcraft docks beside the native Create area")
    page.GetRight = function() return 1220 end
    work.ShowNativeCraft(instruction)
    assert(work.window:IsShown() and work.window.points.TOPLEFT[1] == page
        and work.window.points.BOTTOMRIGHT[3] == 376,
        "the workbench uses a compact dock when its full width cannot fit")
    page.GetRight = function() return 780 end
    work.ShowNativeCraft(instruction)
    assert(work.window:IsShown() and work.window.points.BOTTOMRIGHT[3] == 788,
        "dock width recovers its preferred size when the screen has room")
    pending, busy = false, true
    fixture:Emit("EXECUTION_CHANGED", fixture.L.execRequested)
    assert(work.window:IsShown())
    busy = false
    fixture:Emit("EXECUTION_CHANGED", fixture.L.execReconciled)
    assert(work.window:IsShown() and work.window.points.TOPLEFT[1] == page.RecipeList
        and not work.nativeCraftHint:IsShown(), "Flowcraft returns to its normal anchor when the batch settles")
    work.window:SetWidth(320)
    work.ShowNativeCraft(instruction)
    assert(work.window:IsShown() and work.window.points.BOTTOMRIGHT[3] == 338,
        "a previously narrow workbench can use the minimum dock width")
    page.GetRight = function() return 1550 end
    work.ShowNativeCraft(instruction)
    assert(not work.window:IsShown() and work.nativeCraftHint:IsVisible(),
        "an unavailable dock yields the full native Create area without changing the saved view")
    local nativeSurface, nativeFooter, nativeAnchor, placement = readProfessionSurface()
    assert(nativeSurface == ProfessionsFrame and nativeFooter == false and nativeAnchor == work.nativeCraftHint
        and placement == "above" and layeredDock == nativeAnchor and not initialDock:IsVisible(),
        "the native instructions stay below the moved reminder when there is no room for the workbench")
    action = nil
    restockLayer.HasProfessionReminderDock = nil
    FluxAuctionRestock = previousAuction
end

do
    local previousAuction = FluxAuctionRestock
    FluxAuctionRestock = {Followup = restockLayer}
    restockLayer.HasProfessionReminderDock = true
    local onNativeCountReset, originalHook = nil, hooksecurefunc
    local function withNativeCountReset()
        local page = ProfessionsFrame.CraftingPage
        page.SetupMultipleInputBox = function() end
        hooksecurefunc = function(owner, method, callback)
            if owner == page and method == "SetupMultipleInputBox" then onNativeCountReset = callback end
        end
    end
    local fixture, flushCraft, stock = dofile("Tests/ui_fixture.lua")("forever", nil, withNativeCountReset)
    hooksecurefunc = originalHook
    local after = C_Timer.After
    C_Timer.After = function(delay, callback)
        if delay == 0 then after(delay, callback) end
    end
    local root, bolts = fixture.Catalog.Get(11), fixture.Catalog.Get(22)
    root.name = "Red Mageweave Bag"
    root.reagents = {{itemID = 200, quantity = 5}, {itemID = 501, quantity = 2}, {itemID = 502, quantity = 2}}
    bolts.name, bolts.professionId, bolts.yield = "Bolt of Mageweave", root.professionId, 1
    bolts.reagents = {{itemID = 300, quantity = 5}}
    stock[300], stock[501], stock[502] = 125, 10, 10
    fixture.Clients.UsesNativeCraftHandoff = function() return true end
    fixture.Clients.Resolve = function(task)
        return {kind = "forever", recipeID = task.recipeId, maxYield = task.yield}
    end
    local prepared, nativeBatch
    fixture.Clients.Craft = function(task, _, batch, physicalPress)
        prepared = {task = task, batch = batch, physicalPress = physicalPress}
        return true, nil, "native_click", batch
    end
    local page = ProfessionsFrame.CraftingPage
    local nativeSelections = 0
    local boltInfo = {recipeID = bolts.recipeID, learned = true}
    local rootInfo = {recipeID = root.recipeID, learned = true}
    local boltNode = {GetData = function() return {recipeInfo = boltInfo} end}
    local rootNode = {GetData = function() return {recipeInfo = rootInfo} end}
    page.RecipeList.ScrollBox = {FindElementDataByPredicate = function(_, matches)
        if matches(boltNode) then return boltNode end
        if matches(rootNode) then return rootNode end
    end}
    page.SelectRecipe = function(_, info)
        assert(info == boltInfo or info == rootInfo)
        nativeSelections = nativeSelections + 1
        page.SchematicForm.selectedID = info.recipeID
    end
    fixture.Clients.PrepareNativeCraftBatch = function(recipeID, batch)
        assert(recipeID == page.SchematicForm.selectedID)
        nativeBatch = batch
        return batch
    end
    page.CreateButton:SetScript("OnClick", function() error("the addon must not click native Create") end)
    assert(loadfile("FluxCraft/Execution.lua"))("FluxLogistics", fixture)
    fixture.UI.Refresh()
    fixture.UI.queueAll:Fire("OnClick")
    local job = assert(fixture.UI.job, "Queue All must accept a whole bags-backed chain")
    assert(not prepared, "Queue All must leave the native craft for Process")
    fixture.UI.process:Fire("OnClick")
    assert(job.rootRecipeId == root.id and job.summary.executions == 5 and #job.requirements == 0 and #job.tasks == 2)
    assert(prepared and prepared.task.recipeId == bolts.id and prepared.batch == 25
        and fixture.UI.nativeCraftHint:IsVisible(), "the first native handoff must prepare the 25 bolts")
    assert(fixture.UI.nativeCraftProgress:IsVisible() and fixture.UI.nativeCraftProgress:GetText():find("1/2  Next 25", 1, true),
        "the selected queued step remains visible beside Blizzard Create")
    assert(fixture.UI.status:GetText() == fixture.L.execNativeBatchReady:format(25)
        and fixture.UI.nativeCraftHint.points.BOTTOMRIGHT[1] == page.CreateButton,
        "Process reports readiness in the workbench and beside the real Create control")
    assert(nativeSelections == 1 and page.SchematicForm.selectedID == bolts.recipeID and fixture.UI.job == job
        and nativeBatch == 25, "the native form prepares all 25 prerequisite operations")
    local anotherJob = {id = -1, rootRecipeId = 33, tree = {}, status = "queued"}
    fixture.UI.job, fixture.UI.queueDetailJob, fixture.UI.selectedRecipeId = anotherJob, anotherJob, 33
    fixture.UI.ShowNativeCraft(fixture.Execution.message, job)
    assert(fixture.UI.job == job and fixture.UI.queueDetailJob == job and fixture.UI.selectedRecipeId == root.id
        and page.SchematicForm.selectedID == bolts.recipeID,
        "the HUD handoff replaces the unrelated Flowcraft inspection with its exact approved job")
    fixture.UI.ShowNative()
    assert(not fixture.UI.window:IsVisible() and fixture.UI.nativeCraftHint:IsVisible()
        and fixture.Execution.HasNativeCraftPending() and fixture.Execution.GetNativeCraftRecipe().batch == 25,
        "switching to full native view must keep the queued amount armed for Create")
    local nativeSurface, _, nativeAnchor, placement = readProfessionSurface()
    assert(nativeSurface == ProfessionsFrame and nativeAnchor == fixture.UI.nativeCraftProgress
        and placement == "above" and layeredDock == nativeAnchor,
        "while the next queue step is visible, the reminder clears both native progress and instructions")
    nativeBatch = 1
    onNativeCountReset()
    flushCraft()
    assert(nativeBatch == 25, "Blizzard refreshing its default quantity must keep the verified queued batch")
    assert(prepared.physicalPress(25), "the user starts the first verified native batch")
    fixture.Queue.CraftEvent(job, prepared.task, 25, 25)
    stock[200], stock[300] = 25, 0
    assert(fixture.Execution.ReconcileActive(), "the carried bolts confirm the prerequisite")
    flushCraft()
    assert(job.status == "queued" and job.tasks[1].status == "complete" and job.tasks[2].status == "pending"
        and nativeSelections == 2 and page.SchematicForm.selectedID == root.recipeID
        and prepared.task == job.tasks[2] and prepared.batch == 5 and nativeBatch == 5,
        "verified output prepares the next five operations in the same job without clicking Create")
    assert(prepared.physicalPress(5), "the user starts the final verified batch")
    fixture.Queue.CraftEvent(job, prepared.task, 5, 5)
    stock[100], stock[200] = 5, 0
    assert(fixture.Execution.ReconcileActive(), "the carried bags confirm the final craft")
    flushCraft()
    assert(job.status == "complete" and not fixture.Execution.HasNativeCraftPending()
        and fixture.UI.window:IsVisible() and not fixture.UI.nativeCraftHint:IsVisible())
    nativeBatch = 1
    onNativeCountReset()
    flushCraft()
    assert(nativeBatch == 1, "native quantity belongs to the player after the queued craft settles")
    C_Timer.After = after
    restockLayer.HasProfessionReminderDock = nil
    FluxAuctionRestock = previousAuction
end

do
    local provider
    local previousAuction = FluxAuctionRestock
    FluxAuctionRestock = {Followup = {
        RegisterLogisticsCraft = function(callbacks) provider = callbacks; return true end,
        Refresh = function() end,
    }}
    local fixture, flushNative = dofile("Tests/ui_fixture.lua")("forever")
    FluxAuctionRestock = previousAuction
    local page, work = ProfessionsFrame.CraftingPage, fixture.UI
    local selection = {recipeID = 33, professionId = 5}
    local info = {recipeID = 33, learned = true}
    local node = {GetData = function() return {recipeInfo = info} end}
    local ready, picks = false, 0
    fixture.Execution.GetNativeCraftRecipe = function() return selection end
    page.RecipeList.ScrollBox = {FindElementDataByPredicate = function(_, matches)
        if ready and matches(node) then return node end
    end}
    page.SelectRecipe = function(_, recipeInfo)
        assert(recipeInfo == info)
        picks = picks + 1
        page.SchematicForm.selectedID = recipeInfo.recipeID
    end

    work.ShowNativeCraft("Native prerequisite")
    assert(picks == 0)
    ready = true
    flushNative()
    assert(picks == 1 and page.SchematicForm.selectedID == 33, "one late native list publication selects the armed recipe")
    page.SchematicForm.selectedID, ready = 11, false
    work.ShowNativeCraft("Native prerequisite")
    ready, selection = true, nil
    flushNative()
    assert(picks == 1 and page.SchematicForm.selectedID == 11, "a cancelled handoff cannot change the native selection later")
    ready = false
    assert(not work.RevealNativeCraft(33) and work.nativeCraftHint:IsVisible(),
        "an unavailable exact row still reveals native controls and lets the owner try its native fallback")
    ready = true
    fixture.Execution.HasNativeCraftPending = function() return true end
    local prepared, reason = work.RevealNativeCraft(33, 5)
    assert(not prepared and reason == "busy" and picks == 1, "an ordinary owner cannot replace the companion handoff")
    fixture.Execution.HasNativeCraftPending = nil
    fixture.Clients.PrepareNativeCraftBatch = function(recipeID, batch)
        assert(recipeID == 33 and batch == 5)
        return 4
    end
    local revealed, accepted = work.RevealNativeCraft(33, 5)
    assert(revealed and accepted == 4 and picks == 2 and page.SchematicForm.selectedID == 33
        and not fixture.Execution.GetNativeCraftRecipe(), "an ordinary owner receives its accepted batch without arming companion work")
    selection = {recipeID = 33, professionId = 5, batch = 5, name = "Mooncloth", itemID = 110, yield = 3}
    local liveAmount = 4
    page.CreateButton.IsEnabled = function(self) return self.enabled ~= false end
    page.CreateMultipleInputBox = {
        IsEnabled = function() return true end,
        GetValue = function() return liveAmount end,
    }
    local resizes, resize = 0, work.resize
    work.resize = function(...)
        resizes = resizes + 1
        return resize(...)
    end
    work.ShowNativeCraft("Native prerequisite")
    assert(resizes == 1 and work.nativeCraftHint:GetText() == fixture.L.execNativeBatchReady:format(4),
        "updating the native count hint does not resync the profession controls")
    local preparedBatch = assert(provider.GetPreparedNativeCraft())
    assert(preparedBatch.itemID == 110 and preparedBatch.quantity == 4 and preparedBatch.outputQuantity == 12,
        "the passive provider distinguishes live operations from expected output")
    liveAmount = 1
    assert(not provider.GetPreparedNativeCraft(), "an edit that changes Blizzard's amount retires the prepared guidance")
    liveAmount = 4
    page.CreateButton:SetEnabled(false)
    assert(not provider.GetPreparedNativeCraft(), "a disabled native Create cannot confirm readiness")
    page.CreateButton:SetEnabled(true)
    page:Hide()
    assert(not provider.GetPreparedNativeCraft(), "a hidden native page cannot confirm readiness")
    page:Show()
    local oldSelection = selection
    selection = {recipeID = 33, professionId = 5, batch = 5, itemID = 110, yield = 3}
    assert(not provider.GetPreparedNativeCraft(), "a new handoff cannot inherit the previous handoff's prepared count")
    selection = oldSelection
    local running = false
    fixture.Execution.IsBusy = function() return running end
    running = true
    assert(not provider.GetPreparedNativeCraft(), "a running native craft drops passive Create guidance")
    running = false

    local countReady, prepares = false, 0
    fixture.Clients.PrepareNativeCraftBatch = function(recipeID, batch)
        assert(recipeID == 33 and batch == 5)
        prepares = prepares + 1
        if countReady then liveAmount = batch; return batch end
    end
    work.ShowNativeCraft("Enter the native amount")
    assert(prepares == 1 and work.nativeCraftHint:GetText() == "Enter the native amount")
    countReady = true
    flushNative()
    assert(prepares == 2 and work.nativeCraftHint:GetText() == fixture.L.execNativeBatchReady:format(5),
        "the same armed recipe can prefill the count once its native controls settle")
    assert(provider.GetPreparedNativeCraft().quantity == 5)

    countReady = false
    work.ShowNativeCraft("Enter the native amount")
    page.SchematicForm.selectedID, countReady = 11, true
    flushNative()
    assert(prepares == 3 and work.nativeCraftHint:GetText() == "Enter the native amount",
        "a deferred fill cannot alter the amount on another selected recipe")
end

do
    local fixture, flushNative = dofile("Tests/ui_fixture.lua")("forever")
    local work, page = fixture.UI, ProfessionsFrame.CraftingPage
    local producer = fixture.Catalog.Get(22)
    producer.professionId = fixture.Clients.CurrentProfessionID()
    local armed = {recipeID = producer.recipeID, professionId = producer.professionId, batch = 25}
    fixture.Execution.GetNativeCraftRecipe = function() return armed end
    local known = {recipeID = armed.recipeID, learned = true}
    local lookup, selected, amount = 0, 0, nil
    local previousAPI = C_TradeSkillUI
    C_TradeSkillUI = {GetRecipeInfo = function(recipeID)
        assert(recipeID == armed.recipeID)
        lookup = lookup + 1
        return known
    end}
    page.RecipeList.SearchBox = CreateFrame("EditBox", nil, page.RecipeList)
    page.RecipeList.SearchBox:SetText("Red Mageweave Bag")
    page.RecipeList.ScrollBox = {FindElementDataByPredicate = function() return nil end}
    page.SelectRecipe = function(_, recipe, skipSelectInList)
        assert(recipe == known and recipe.recipeID == armed.recipeID and skipSelectInList == true)
        page.SchematicForm.selectedID = recipe.recipeID
        selected = selected + 1
    end
    page.CreateButton:SetScript("OnClick", function() error("handoff must leave native Create to the player") end)
    fixture.Clients.PrepareNativeCraftBatch = function(recipeID, batch)
        assert(recipeID == armed.recipeID and batch == armed.batch and page.SchematicForm.selectedID == recipeID)
        amount = batch
        return batch
    end

    work.ShowNativeCraft("Native prerequisite hidden by a recipe filter")
    flushNative()
    assert(lookup > 0 and selected == 1 and amount == 25 and page.SchematicForm.selectedID == producer.recipeID
        and page.RecipeList.SearchBox:GetText() == "Red Mageweave Bag" and work.window.points.TOPLEFT[1] == page,
        "a filtered-out prerequisite can prepare the exact native form without clearing the list filter")

    known, amount, page.SchematicForm.selectedID = {recipeID = 33, learned = true}, nil, 11
    work.ShowNativeCraft("Native prerequisite unavailable")
    flushNative()
    assert(selected == 1 and amount == nil and page.SchematicForm.selectedID == 11,
        "native lookup cannot substitute a different recipe for the armed craft")
    assert(work.status:GetText() == fixture.L.execNativeSelect:format(producer.recipeID))
    C_TradeSkillUI = previousAPI
end

do
    local fixture, flushReview, stock, events = dofile("Tests/ui_fixture.lua")("forever")
    local workbench = fixture.UI
    stock[300] = 20
    workbench.Refresh()
    workbench.queuePlan:Fire("OnClick")
    local job = assert(workbench.job)
    assert(workbench.process:GetText() == fixture.L.processShort and workbench.process.enabled,
        "Forever labels the normal queue action Process")
    local task = assert(job.tasks[1])
    assert(fixture.Queue.Begin(job, task, {batch = 1, beforeOutput = 0}))
    fixture.Queue.MarkUncertain(job, task)
    flushReview()
    local check
    fixture.Execution.ReconcileUncertain = function(preferredJob)
        check = preferredJob
        return false, fixture.L.execUnproved
    end
    assert(workbench.process:GetText() == fixture.L.processShort and workbench.process.enabled)
    workbench.process:Fire("OnClick")
    assert(check == job and not fixture.processed and workbench.message == fixture.L.execUnproved,
        "Process checks an unproved outcome without replaying the craft")

    local eligible, processCalls = false, 0
    fixture.Execution.CanReplanFromBags = function(candidate) return eligible and candidate == job end

    local page = ProfessionsFrame.CraftingPage
    local function browseMooncloth()
        page.SchematicForm.selectedID = 33
        events["Professions.RecipeSelected"](page)
        assert(workbench.selectedRecipeId == 33 and not workbench.job,
            "selecting an unqueued native recipe clears the inspected job")
    end
    eligible, check = false, nil
    browseMooncloth()
    assert(workbench.process:GetText() == fixture.L.processShort and workbench.process.enabled)
    workbench.process:Fire("OnClick")
    assert(check == job and workbench.job == job and not fixture.processed and page.SchematicForm.selectedID == 33,
        "the footer can check the blocked craft while browsing a different recipe")

    local function nextPreview()
        return fixture.Logistics.Preview({recipeId = job.rootRecipeId, quantity = 2})
    end
    local replacement = assert(fixture.Queue.Accept(nextPreview(), nextPreview))
    fixture.Execution.ProcessClick = function(candidate)
        assert(candidate == job)
        processCalls = processCalls + 1
        job.status, job.replacement = "replaced", replacement.id
        fixture:Emit("CRAFT_RECOVERY_REPLANNED", job, replacement)
        return true, fixture.L.execRequested, replacement
    end
    eligible = true
    browseMooncloth()
    assert(workbench.process:GetText() == fixture.L.processShort and workbench.process.enabled,
        "the globally blocked craft can recover through Process while browsing an unqueued recipe")
    workbench.process:Fire("OnClick")
    assert(processCalls == 1 and workbench.job == replacement and workbench.process:GetText() == fixture.L.processShort
        and workbench.message == fixture.L.execRequested and not fixture.processed and not fixture.directCraft
        and page.SchematicForm.selectedID == 33,
        "the one-click Process starts after recovery without changing the native recipe")
    browseMooncloth()
    fixture:Emit("CRAFT_RECOVERY_REPLANNED", job, replacement)
    assert(not workbench.job and workbench.selectedRecipeId == 33 and processCalls == 1,
        "background recovery preserves the recipe the player is browsing and dispatches no craft")
end

do
    local setup = dofile("Tests/ui_fixture.lua")
    local first, _, inventory = setup("forever")
    inventory[200] = 8
    first.UI.quantity:SetText("4")
    first.UI.quantity:Fire("OnEnterPressed")
    first.UI.queuePlan:Fire("OnClick")
    local job = assert(first.UI.job)
    local task = assert(job.tasks[1])
    assert(first.Queue.Begin(job, task, {batch = 4, beforeOutput = 0}))
    first.Queue.MarkUncertain(job, task)
    assert(first.UI.saved.queueJobId == job.id)

    local function restore(fixture)
        fixture.state.char.queueByBuild = first.state.char.queueByBuild
        fixture.Execution.GetCarriedOutputRecovery = function(candidate)
            if candidate == job and task.status == "uncertain" then
                return {quantity = 2, remainingExecutions = 2, evidence = task.evidence}
            end
        end
        fixture.Execution.ResumeWithCarriedOutput = function(candidate, selection)
            assert(candidate == job and selection.quantity == 2 and selection.evidence == task.evidence)
            candidate.status, task.status, task.completedExecutions, task.remainingExecutions = "queued", "pending", 2, 2
            return true, "Two already carried", task
        end
        fixture.Execution.ProcessClick = function(candidate, nextTask)
            assert(candidate == job and nextTask == task and task.remainingExecutions == 2)
            fixture.processed = {candidate, nextTask}
            return true, "Ready for the remaining two", candidate
        end
    end
    local reloaded = setup("forever", first.state.char.ui, restore)
    local workbench = reloaded.UI
    assert(workbench.job == job and workbench.process:GetText() == reloaded.L.processShort
        and workbench.graph.outputAmount == "2"
        and workbench.queueRows[1].caption:GetText():find("^2× ") and not reloaded.processed,
        "reload restores the exact accepted job and shows the anchored two-pack remainder before any Process click")
    workbench.process:Fire("OnClick")
    assert(reloaded.processed[1] == job and job.status == "queued" and workbench.graph.outputAmount == "2"
        and workbench.process:GetText() == reloaded.L.processShort,
        "one Process click counts the two carried packs and dispatches only the exact remainder")
end

do
    local previousAuctionator, previousAuctionFrame, previousLegacyAuctionFrame = Auctionator, AuctionHouseFrame, AuctionFrame
    Auctionator, AuctionHouseFrame, AuctionFrame = nil, nil, nil
    local function withMarket(fixture)
        assert(loadfile("FluxCraft/Locale.lua"))("FluxLogistics", fixture)
        assert(loadfile("FluxCraft/AdaptersAuctionator.lua"))("FluxLogistics", fixture)
    end
    local fixture, flushMarket, _, events = dofile("Tests/ui_fixture.lua")("forever", nil, withMarket)
    local workbench = fixture.UI
    assert(not workbench.context.projection.estimatedProfit)

    local prices, callback, subscriptions = {[200] = 90, [300] = 1}, nil, 0
    Auctionator = {API = {v1 = {
        GetAuctionPriceByItemID = function(_, id) return prices[id] end,
        RegisterForDBUpdate = function(_, listener)
            callback, subscriptions = listener, subscriptions + 1
        end,
    }}}
    events.ADDON_LOADED:Fire("OnEvent", "ADDON_LOADED", "Auctionator")
    flushMarket()
    assert(subscriptions == 1 and type(callback) == "function", "price refresh must subscribe after Auctionator loads")
    prices[100] = 100
    callback()
    flushMarket()
    local scanProfit = assert(workbench.context.projection.estimatedProfit)

    local forcedRefreshes = 0
    local refresh = fixture.RecipeProfit.Refresh
    fixture.RecipeProfit.Refresh = function(force)
        if force then forcedRefreshes = forcedRefreshes + 1 end
        return refresh(force)
    end
    prices[100] = 120
    events.AUCTION_HOUSE_CLOSED:Fire("OnEvent", "AUCTION_HOUSE_CLOSED")
    flushMarket()
    assert(workbench.context.projection.estimatedProfit == scanProfit + 19 and forcedRefreshes == 1,
        "quotes learned during an auction session must reach the preview and invalidate the recipe profit cache")
    workbench.queuePlan:Fire("OnClick")
    local job = assert(workbench.job)
    local accepted = assert(job.projection.estimatedProfit)
    prices[100] = 500
    callback()
    flushMarket()
    assert(workbench.job == job and job.projection.estimatedProfit == accepted,
        "market refresh must preserve the accepted estimate")
    Auctionator, AuctionHouseFrame, AuctionFrame = previousAuctionator, previousAuctionFrame, previousLegacyAuctionFrame
end

do
    local fixture, flushList = dofile("Tests/ui_fixture.lua")("classic")
    local workbench, catalog = fixture.UI, fixture.Catalog.Snapshot()
    local bagRevision, prices = 1, {}
    fixture.InventoryAdapter.GetRevision = function() return "bags:" .. bagRevision end
    fixture.MarketAdapter.QuoteItems = function(items)
        local quotes = {}
        for _, itemID in ipairs(items) do quotes[itemID] = prices[itemID] or 1 end
        return quotes
    end
    for index = 1, 34 do
        local id, output, reagent = 1000 + index, 2000 + index, 3000 + index
        catalog.recipesById[id] = {id = id, recipeID = id, professionId = workbench.professionID,
            characterKey = fixture.state.characterKey, learned = true, completeness = "complete",
            outputKind = "item", outputItemID = output, name = ("Test recipe %02d"):format(index), yield = 1,
            reagents = {{itemID = reagent, quantity = 1}}}
        catalog.byOutput[output], prices[reagent] = {id}, 50 - index
    end
    local pref = workbench.saved.perProfession[tostring(workbench.professionID)]
    pref.filter, pref.sort, pref.scroll = "all", "cost", 5
    catalog.revision = catalog.revision + 1
    workbench.Refresh()
    flushList()
    local top = workbench.recipeRows[1]
    local anchor, caption = top.record.recipe.id, top:GetText()
    local selected, graphPosition = workbench.selectedRecipeId, workbench.graph.position
    assert(pref.scroll == 5 and anchor == 1030)

    bagRevision = bagRevision + 1
    workbench.Refresh()
    assert(top.record.recipe.id == anchor and top:GetText() == caption,
        "a bag refresh keeps the visible ranked recipes and their settled costs during evaluation")
    flushList()
    assert(top.record.recipe.id == anchor and pref.scroll == 5)

    prices[3001] = 0
    workbench.marketRevision = (workbench.marketRevision or 0) + 1
    workbench.Refresh()
    assert(top.record.recipe.id == anchor)
    flushList()
    assert(top.record.recipe.id == anchor and pref.scroll == 6
        and workbench.selectedRecipeId == selected and workbench.graph.position == graphPosition,
        "a changed ranking keeps the same visible anchor and graph selection")

    workbench.sort:Fire("OnClick")
    flushList()
    assert(pref.sort == "name" and pref.scroll == 0 and top.record.recipe.id ~= anchor,
        "changing the chosen sort explicitly opens that order from the top")
end

for _, target in ipairs({"forever", "classic"}) do
    local stationMet, ticker, stationReads = false, nil, 0
    local station = "Test Loom"
    local function configure(fixture)
        local gloves, bolt = fixture.Catalog.Get(11), fixture.Catalog.Get(22)
        gloves.name, bolt.name = "Dreamweave Gloves", "Bolt of Cloth"
        bolt.professionId = gloves.professionId
        gloves.reagents = {{itemID = bolt.outputItemID, quantity = 2}, {itemID = 400, quantity = 1}}
        gloves.constraints = {
            requirementsMet = false,
            requirements = {{name = station, met = false}},
            cooldownUntil = 100,
        }
        fixture.Catalog.ReadLiveRequirements = function(recipe)
            if recipe ~= gloves then return {} end
            stationReads = stationReads + 1
            return {{name = station, met = stationMet}}
        end
        C_Timer.NewTicker = function(delay, callback)
            if delay == 1 then return {Cancel = function() end} end -- cooldown display
            assert(delay == 0.75, "the visible station refresh should match the native cadence")
            assert(not ticker or ticker.cancelled, "station refresh must use only one active ticker")
            ticker = {run = callback, Cancel = function(self) self.cancelled = true end}
            return ticker
        end
    end

    local fixture, flushQueue, stock = dofile("Tests/ui_fixture.lua")(target, nil, configure)
    local workbench, queue = fixture.UI, fixture.Queue
    local gloves, bolt = fixture.Catalog.Get(11), fixture.Catalog.Get(22)
    if target == "classic" then
        for _, row in ipairs(workbench.recipeRows) do
            if row.record and row.record.recipe == gloves then
                row:Fire("OnClick", "LeftButton")
                break
            end
        end
        flushQueue()
    end
    assert(workbench.preview.inspectionOnly and workbench.preview.blocker == fixture.L.clients.cooldown
        and not workbench.queuePlan.enabled, target .. " Queue must still respect the cooldown")

    gloves.constraints.cooldownUntil = nil
    workbench.Refresh()
    flushQueue()
    local draft = workbench.preview
    local requirement = fixture.L.clients.requires:format(station)
    assert(requirement:match("^|cffff5959"), "the required station warning must use red text")
    assert(not draft.inspectionOnly and draft.status == "sourcing" and draft.craftRequirement == requirement
        and workbench.status:GetText() == requirement
        and workbench.queuePlan.enabled, target .. " Queue should stay available away from the required station")
    workbench.queuePlan:Fire("OnClick")
    flushQueue()

    local job = assert(workbench.job, target .. " Queue should accept the station-dependent order")
    local precursor, final = job.tasks[1], job.tasks[2]
    assert(#queue.GetJobs() == 1 and #job.tasks == 2 and precursor.recipeId == bolt.id
        and final.recipeId == gloves.id and final.dependencies[1] == precursor.taskId,
        target .. " Queue must preserve the producer and final craft dependency")
    local shopping = queue.GetRequirements(job)
    assert(#shopping == 1 and shopping[1].itemID == 400 and shopping[1].quantity == 1,
        target .. " Queue must retain the material shortage in Shopping List")
    assert(not fixture.directCraft and not fixture.processed, target .. " Queue must not dispatch a craft")
    assert(workbench.status:GetText() ~= requirement, "a later station must not obscure the current prerequisite")

    stock[400] = 1
    assert(queue.CreditAcquisition(job, shopping[1].id, 1, 1) == 1)
    assert(queue.Begin(job, precursor, {beforeOutput = 0, batch = 1}))
    queue.CraftEvent(job, precursor, 1, 2)
    stock[300], stock[bolt.outputItemID] = stock[300] - 1, 2
    assert(queue.Reconcile(job, precursor, 2))
    workbench.Refresh()
    flushQueue()

    assert(workbench.job == job and final.status == "pending" and workbench.status:GetText():find(requirement, 1, true) == 1
        and ticker and not ticker.cancelled, "the live warning belongs to the now-current final craft")
    local changes = 0
    fixture:On("CRAFT_REQUIREMENT_CHANGED", function() changes = changes + 1 end)
    ticker.run()
    flushQueue()
    assert(changes == 0, "unchanged station availability should not refresh the HUD")

    local processAttempts = 0
    fixture.Execution.ProcessClick = function(selectedJob, selectedTask)
        if not selectedTask then selectedJob, selectedTask = queue.NextTask(workbench.professionID, selectedJob) end
        assert(selectedJob == job and selectedTask == final, "Process should target the station-dependent craft")
        processAttempts = processAttempts + 1
        return false, requirement
    end
    workbench.process:Fire("OnClick")
    assert(processAttempts == 1 and workbench.status:GetText() == requirement and workbench.message == requirement,
        "Process should surface the failed live requirement for the same queued task")

    stationMet = true
    ticker.run()
    flushQueue()
    assert(not workbench.status:GetText():find(requirement, 1, true) and workbench.message ~= requirement
        and workbench.job == job and changes == 1,
        "moving into station range should clear the warning without replanning the accepted job")
    stationMet = false
    ticker.run()
    flushQueue()
    assert(workbench.status:GetText() == requirement and changes == 2 and not fixture.processed,
        "moving away should restore the red warning without dispatching a craft")

    local visibleTicker, readsBeforeHide = ticker, stationReads
    workbench.ShowNative()
    assert(not workbench.window:IsVisible())
    if workbench.window:IsShown() then
        -- The Classic shell hides its child. The fixture only fires OnHide on the frame it hides directly.
        workbench.window:Fire("OnHide")
    end
    flushQueue()
    visibleTicker.run()
    assert(visibleTicker.cancelled and stationReads == readsBeforeHide,
        target .. " Flowcraft must retire its station refresh when hidden")
end
