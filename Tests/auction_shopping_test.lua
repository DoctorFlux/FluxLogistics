local setup = dofile("Tests/ui_fixture.lua")

local function fixture(target, ownerName, professionName)
    local ns, flush, stock, events = setup(target)
    local market = ns.MarketAdapter
    assert(loadfile("FluxCraft/AdaptersAuctionator.lua"))("FluxLogistics", ns)
    ns.MarketAdapter = market
    local ctx = {ns = ns, ui = ns.UI, flush = flush, stock = stock, events = events, mail = {}, prices = {},
        requests = {}, purchases = {}, searches = {}, mailKnown = true}
    stock[300] = 0
    GetMoney = function() return 100000 end
    ns.MarketAdapter.QuoteItems = function(items)
        local quotes = {}
        for _, itemID in ipairs(items) do
            quotes[itemID] = {itemID = itemID, unitPrice = ctx.prices[itemID] or 10, source = "fixture"}
        end
        return quotes
    end
    Flux = {
        Inventory = {
            GetSnapshotGeneration = function() return 1 end,
            Mail = {
                GetCount = function(itemID) return ctx.mail[itemID] or 0 end,
                HasObservedInbox = function() return ctx.mailKnown end,
            },
        },
        RestockPolicy = {
            version = 1,
            IsWorkflowBusy = function() return ctx.busy end,
            GetVendorPriceEstimate = function(itemID)
                if itemID == 159 then
                    return {kind = "vendor", itemID = itemID, unit = "item", bundleSize = 5,
                        bundlePrice = 25, unitPrice = 5, source = "vendor", estimate = true, provenance = "fixture"}
                end
                if itemID == 500 then
                    return {kind = "vendor", itemID = itemID, unit = "item", bundleSize = 1,
                        bundlePrice = 2, unitPrice = 2, source = "vendor", estimate = true, provenance = "fixture"}
                end
                if itemID == 2321 or itemID == 2605 then
                    local price = ctx.vendorPrice or 90
                    return {kind = "vendor", itemID = itemID, unit = "item", bundleSize = 1,
                        bundlePrice = price, unitPrice = price, source = "vendor", estimate = true, provenance = "merchant"}
                end
            end,
        },
    }
    Auctionator = {API = {v1 = {
        MultiSearchAdvanced = function(caller, terms)
            assert(caller == "FluxLogistics")
            ctx.searches[#ctx.searches + 1] = terms
        end,
    }}}

    local function same(quote, request, quantity)
        local previous = quote and quote.request
        return previous and previous.jobId == request.jobId and previous.id == request.id
            and previous.itemID == request.itemID and previous.planRevision == request.planRevision
            and previous.groupRevision == request.groupRevision
            and previous.maxUnitPrice == request.maxUnitPrice and previous.maxTotalPrice == request.maxTotalPrice
            and previous.minQuantity == request.minQuantity
            and quote.quantity == quantity
    end
    local function prepare(request, quantity, authorize, observe, explicit)
        assert(authorize(request, quantity), "a quote must use the still-authorized outstanding quantity")
        if same(ctx.quote, request, quantity) then return true, ctx.quote.phase end
        if ctx.restockActive and not explicit then return false, "otherSearch" end
        local quote = {request = request, quantity = quantity, phase = "searching", observe = observe,
            explicit = explicit, authorize = authorize}
        ctx.quote = quote
        ctx.requests[#ctx.requests + 1] = quote
        return true, "searching"
    end
    FluxAuctionRestock = {
        GetPolicyCoverage = function(_, _, itemID) return ctx.mail[itemID] or 0 end,
        PrepareLogistics = prepare,
        GetLogisticsState = function(request, quantity)
            if same(ctx.quote, request, quantity) then
                local units = ctx.liveOffer and ctx.liveOffer.quantity or request.stackSize or (target == "classic" and 1 or quantity)
                local total = ctx.liveOffer and ctx.liveOffer.totalCopper or request.stackMaxTotalPrice or units
                return ctx.quote.phase, nil,
                    ctx.quote.phase == "ready" and {quantity = units, totalCopper = total} or nil
            end
            if same(ctx.lastQuote, request, quantity) then return nil, ctx.lastQuote.reason end
        end,
        ExecuteLogistics = function(request, quantity, authorize, observe)
            if not same(ctx.quote, request, quantity) or ctx.quote.phase ~= "ready" then
                return prepare(request, quantity, authorize, observe)
            end
            local units = ctx.liveOffer and ctx.liveOffer.quantity or request.stackSize or (target == "classic" and 1 or quantity)
            local total = ctx.liveOffer and ctx.liveOffer.totalCopper or request.stackMaxTotalPrice or units
            assert(not authorize(request, quantity + 1, units), "an owner cannot buy more than the exact accepted amount")
            assert(not authorize(request, units, request.maxUnitPrice * units + 1), "unit price cap must still apply at purchase")
            assert(authorize(request, units, total))
            local receipt = {jobId = request.jobId, id = request.id, planRevision = request.planRevision,
                groupRevision = request.groupRevision,
                itemID = request.itemID, quantity = units, totalCopper = total, attemptID = #ctx.purchases + 1}
            ctx.purchases[#ctx.purchases + 1] = receipt
            ctx.quote = nil
            observe("submitted", receipt)
            if ctx.deferConfirmation then
                ctx.confirmPurchase = function() observe("confirmed", receipt) end
            else
                observe("confirmed", receipt)
            end
            return true, "buying"
        end,
    }

    function ctx:accept(itemID, quantity, selection)
        local args = {itemID = itemID, quantity = quantity, intent = "supply",
            choices = {[itemID] = {source = selection or "Buy"}}}
        local function preview() return ns.Logistics.Preview(args) end
        return assert(ns.Queue.Accept(preview(), preview))
    end

    function ctx:open(keepProfession)
        if not keepProfession then _G[professionName]:Hide() end
        self.house = CreateFrame("Frame", nil, UIParent)
        _G[ownerName] = self.house
        events.AUCTION_HOUSE_SHOW:Fire("OnEvent", "AUCTION_HOUSE_SHOW")
        flush()
        return self.ui.auctionShopping
    end

    function ctx:settleQuote(phase, reason)
        local quote = assert(self.quote)
        local request = quote.request
        if reason then
            quote.reason, self.lastQuote, self.quote = reason, quote, nil
        else
            quote.phase = phase
        end
        quote.observe("state", {jobId = request.jobId, id = request.id, itemID = request.itemID,
            planRevision = request.planRevision, groupRevision = request.groupRevision, phase = phase, reason = reason})
        flush()
    end

    function ctx:inventoryChanged()
        ns:Emit("INVENTORY_CHANGED")
        flush()
    end

    function ctx:close()
        self.house:Hide()
        events.AUCTION_HOUSE_CLOSED:Fire("OnEvent", "AUCTION_HOUSE_CLOSED")
        flush()
        Flux, FluxAuctionRestock, GetMoney, Auctionator, _G[ownerName] = nil, nil, nil, nil, nil
    end
    return ctx
end

local function findItem(pane, itemID)
    for _, item in ipairs(pane.entries or {}) do if item.itemID == itemID then return item end end
end

local function visibleRow(pane, itemID)
    for _, row in ipairs(pane.rows) do
        if row:IsVisible() and row.entry and row.entry.itemID == itemID then return row end
    end
end

local function rowAction(pane, itemID)
    return assert(visibleRow(pane, itemID or pane.itemID)).action
end

local function selectItem(ctx, pane, itemID)
    for _ = 1, #pane.entries do
        local row = visibleRow(pane, itemID)
        if row then row:Fire("OnClick"); ctx.flush(); return end
        assert(pane.next:IsVisible() and pane.next.enabled, "remaining items must be reachable by paging")
        pane.next:Fire("OnClick")
        ctx.flush()
    end
    error("could not select shopping item " .. itemID)
end

local function startQuote(ctx, pane, jobID, quantity)
    if not ctx.quote then rowAction(pane):Fire("OnClick"); ctx.flush() end
    local quote = assert(ctx.quote, "the purchase control must prepare an exact offer")
    assert(quote.request.jobId == jobID and quote.quantity == quantity)
    return quote
end

local function buy(ctx, pane, jobID, quoteQuantity, purchasedQuantity)
    startQuote(ctx, pane, jobID, quoteQuantity)
    local before = #ctx.purchases
    ctx:settleQuote("ready")
    assert(rowAction(pane).enabled and rowAction(pane):GetText() == ctx.ns.L.shoppingBuyQuantity:format(purchasedQuantity),
        "the ready offer must be actionable on its material row")
    rowAction(pane):Fire("OnClick")
    ctx.flush()
    assert(#ctx.purchases == before + 1 and ctx.purchases[#ctx.purchases].jobId == jobID
        and ctx.purchases[#ctx.purchases].quantity == purchasedQuantity,
        "each native Buy press may make exactly one authorized purchase")
end

local function runFallback(target, ownerName, professionName)
    local ctx = fixture(target, ownerName, professionName)
    local job
    for index = 1, 9 do job = ctx:accept(600 + index, 8) end
    -- Purchases already acknowledged by the owner remain in transit during a cold inbox.
    job.requirements[1].auctionAwaiting = 3
    ctx.mailKnown = false
    local pane = assert(ctx:open(false), "opening the Auction House should show the queue without a profession")
    assert(pane:IsVisible() and pane.parent == UIParent and pane.anchor == ctx.house and not ctx.ui.window:IsVisible()
        and #pane.entries == 9 and not pane.empty:IsShown())
    assert(#ctx.purchases == 0 and #ctx.searches == 0 and #ctx.requests == 0 and not pane.status:IsShown(),
        "opening the detached list should show amounts and Auctionator without launching an offer or buying")
    assert(rowAction(pane, 601):GetText() == ctx.ns.L.shoppingFindItem and pane.search.enabled,
        "an unverified inbox holds purchases while leaving search available")
    selectItem(ctx, pane, 609)
    assert(findItem(pane, 609).quantity == 5, "the list must deduct this job's acknowledged receipt even without a live inbox")
    assert(#ctx.purchases == 0 and #ctx.requests == 0)
    pane.search:Fire("OnClick")
    local sent = assert(ctx.searches[1])
    local counts = {}
    assert(#sent == 9 and #ctx.purchases == 0 and #ctx.ns.Queue.GetJobs() == 9)
    for _, record in ipairs(sent) do
        assert(record.isExact and record.maxPrice == nil)
        counts[record.searchString] = record.quantity
    end
    assert(counts["Fixture item 601"] == 8 and counts["Fixture item 609"] == 5,
        "search list must forward all pages with the queue's quantities and leave spending to Auctionator")
    assert(pane:IsVisible() and ctx.house:IsVisible(), "the shopping quantities should stay beside Auctionator results")
    local openedNative
    FluxAuctionRestock.PrepareLogisticsSearch = function(itemID)
        openedNative = itemID
        return true, "Fixture item " .. itemID
    end
    rowAction(pane, 609):Fire("OnClick")
    local one = assert(ctx.searches[2])
    assert(#one == 1 and one[1].searchString == "Fixture item 609" and one[1].quantity == 5
        and #ctx.purchases == 0 and #ctx.requests == 0 and not openedNative,
        "a row forwards its exact amount to Auctionator even when FluxUI also supports native search")
    Auctionator.API.v1.MultiSearchAdvanced = function() error("Search unavailable") end
    rowAction(pane, 609):Fire("OnClick")
    assert(openedNative == 609 and #ctx.purchases == 0 and #ctx.requests == 0,
        "if Auctionator cannot search, that row still prefills the native Auction House search")
    ctx:close()
    assert(not pane:IsVisible(), "closing the Auction House must close its shopping list")
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local job = ctx:accept(300, 2)
    ctx.restockActive = true
    local pane = assert(ctx:open(false))
    selectItem(ctx, pane, 300)
    assert(not ctx.quote and #ctx.requests == 0, "selecting a row must not interrupt the Restock tab")
    rowAction(pane, 300):Fire("OnClick")
    assert(startQuote(ctx, pane, job.id, 2).explicit and #ctx.requests == 1 and #ctx.purchases == 0,
        "the row's deliberate quote click can use the Restock service without buying")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local first = ctx:accept(300, 2)
    ctx.prices[400] = 14
    local second = ctx:accept(400, 3)
    local pane = assert(ctx:open(false))
    local firstAction, secondAction = rowAction(pane, 300), rowAction(pane, 400)
    firstAction:Fire("OnMouseDown", "LeftButton")
    selectItem(ctx, pane, 300)
    assert(startQuote(ctx, pane, first.id, 2))
    ctx:settleQuote("ready")
    firstAction:Fire("OnClick")
    assert(#ctx.purchases == 0, "a press that began before the quote was ready cannot buy it")
    secondAction:Fire("OnMouseDown", "LeftButton")
    secondAction:Fire("OnClick")
    local quote = startQuote(ctx, pane, second.id, 3)
    assert(quote.request.maxUnitPrice == 14 and quote.request.maxTotalPrice == 42 and #ctx.purchases == 0,
        "a row click prepares its own accepted request even when another row has a ready quote")
    ctx:settleQuote("ready")
    ctx.restockActive = true
    ctx.quote = nil
    secondAction:Fire("OnClick")
    assert(#ctx.purchases == 0 and ctx.quote and ctx.quote.explicit and ctx.quote.request.jobId == second.id,
        "the stale Buy click must explicitly refresh the same offer without submitting in the active Restock tab")
    buy(ctx, pane, second.id, 3, 3)
    assert(not first.lastAcquisition and second.lastAcquisition and #ctx.purchases == 1)
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local first, selected = ctx:accept(300, 2), ctx:accept(400, 4)
    local pane = assert(ctx:open(false))
    selectItem(ctx, pane, 400)
    assert(pane.entry.job == selected)
    pane.dragged, pane.left = true, ctx.house:GetLeft() + 1
    pane.search:Fire("OnClick")
    ctx.flush()
    assert(not pane:IsVisible() and #ctx.searches == 1)
    ctx.quote = nil
    assert(ctx.ui.OpenAuctionShopping(ctx.house))
    assert(pane:IsVisible() and pane.entry.job == selected and pane.detail and not ctx.quote,
        "returning to Shopping in the same AH session restores the exact selected job without requerying")
    assert(startQuote(ctx, pane, selected.id, 4) and not first.lastAcquisition and #ctx.purchases == 0)
    ctx:close()
end

do
    local ctx = fixture("classic", "AuctionFrame", "TradeSkillFrame")
    local first, second = ctx:accept(300, 2), ctx:accept(400, 3)
    ctx.restockActive = true
    local pane = assert(ctx:open(false))
    local oldAfter, oldShopping = C_Timer.After, AuctionatorShoppingFrame
    local waits = {}
    C_Timer.After = function(delay, callback)
        if delay == 0.25 then waits[#waits + 1] = callback else oldAfter(delay, callback) end
    end
    AuctionatorShoppingFrame = CreateFrame("Frame", nil, UIParent)
    AuctionatorShoppingFrame.searchRunning = true
    rowAction(pane, 300):Fire("OnClick")
    assert(#waits == 1 and #ctx.requests == 0 and pane.status:GetText() == ctx.ns.L.shoppingWaitingAuctionator)
    table.remove(waits, 1)()
    assert(#waits == 1 and #ctx.requests == 0)
    selectItem(ctx, pane, 400)
    table.remove(waits, 1)()
    assert(#waits == 0 and #ctx.requests == 0, "another selection cancels the earlier exact quote request")
    rowAction(pane, 400):Fire("OnClick")
    AuctionatorShoppingFrame.searchRunning = false
    table.remove(waits, 1)()
    ctx.flush()
    assert(#ctx.requests == 1 and startQuote(ctx, pane, second.id, 3).explicit
        and #ctx.purchases == 0 and not first.lastAcquisition,
        "after Auctionator settles, the deferred click prepares only the selected exact job")
    C_Timer.After, AuctionatorShoppingFrame = oldAfter, oldShopping
    ctx:close()
end

local function runWhileCrafting(target, ownerName, professionName)
    local ctx = fixture(target, ownerName, professionName)
    local ui = ctx.ui
    local closedInset = ui.graph.frame.points.TOPLEFT[4]
    ui.quantity:SetText("4")
    ui.quantity:Fire("OnEnterPressed")
    ui.queuePlan:Fire("OnClick")
    ctx.flush()
    local job = assert(ui.job)
    assert(#ctx.ns.Queue.GetJobs() == 1 and ui.graph.frame:IsVisible() and ui.queuePane:IsVisible(),
        "queueing should keep both graph and queue in the profession workbench")
    assert(not ui.recipeAuctionator:IsShown(), "recipe search belongs to the Auction House context")
    ui.graphShoppingButton:Fire("OnClick")
    local pane = assert(ui.auctionShopping)
    assert(pane:IsVisible() and (pane.anchor == _G[professionName] or pane.anchor == ui.classic))
    ctx.mail[300] = 1
    assert(ctx:open(true) == pane, "the same shopping window follows the Auction House")
    assert(pane:IsVisible() and ui.graph.frame:IsVisible()
        and pane.anchor == ctx.house and pane.parent == UIParent, "shopping opens beside the Auction House with crafting still visible")
    local shoppingAnchor = ui.graph.frame.points.TOPLEFT
    assert(shoppingAnchor[1] == ui.plan and shoppingAnchor[2] == "TOPLEFT" and shoppingAnchor[4] == closedInset)
    assert(findItem(pane, 300).quantity == 3 and #ctx.purchases == 0)
    ui.graphShoppingButton:Fire("OnClick")
    assert(not pane:IsVisible() and ui.graph.frame:IsVisible() and ui.graph.frame.points.TOPLEFT[4] == closedInset)
    ui.graphShoppingButton:Fire("OnClick")
    assert(pane:IsVisible() and ui.graph.frame:IsVisible())
    selectItem(ctx, pane, 300)
    ctx.busy = true
    rowAction(pane):Fire("OnClick")
    pane.search:Fire("OnClick")
    assert(#ctx.purchases == 0 and #ctx.searches == 0 and #ctx.ns.Queue.GetJobs() == 1,
        "a busy workflow cannot dispatch a purchase, replace a search or add another plan")
    ctx.busy = false
    buy(ctx, pane, job.id, 3, target == "classic" and 1 or 3)
    local remaining = target == "classic" and 2 or 0
    local group = findItem(pane, 300)
    assert((group and group.quantity or 0) == remaining and #ctx.ns.Queue.GetJobs() == 1,
        "a confirmed receipt must update the same sealed plan immediately")
    ctx.stock[200] = 8
    assert(ui.recipeAuctionator:IsVisible() and ui.recipeAuctionator:GetText() == ctx.ns.L.auctionatorButton)
    ui.recipeAuctionator:Fire("OnClick")
    local recipeTerms = assert(ctx.searches[1])
    assert(#recipeTerms == 3 and recipeTerms[1].searchString == "Fixture item 100" and recipeTerms[1].quantity == 4
        and recipeTerms[2].searchString == "Fixture item 200" and recipeTerms[2].quantity == 8
        and recipeTerms[3].searchString == "Fixture item 300" and recipeTerms[3].quantity == 4,
        "recipe search lists the selected output and the full accepted ingredient quantities")
    assert(pane:IsVisible() and pane.anchorSide == "below" and ui.graph.frame:IsVisible()
        and #ctx.purchases == 1 and #ctx.ns.Queue.GetJobs() == 1,
        "recipe search leaves the docked list and accepted job visible")
    ctx:close()
    assert(not pane:IsVisible())
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local recipe = assert(ctx.ns.Catalog.Get(11))
    recipe.reagents = {{itemID = 200, quantity = 2}, {itemID = 500, quantity = 1}, {itemID = 601, quantity = 2}}
    ctx.stock[300] = 2
    ctx.ui.Refresh()
    ctx.ui.queuePlan:Fire("OnClick")
    ctx.flush()
    local job = assert(ctx.ui.job)
    local _, prerequisite = ctx.ns.Queue.NextTask(6, job)
    assert(prerequisite and prerequisite.recipeId == 22 and #job.tasks == 2)
    local pane = ctx:open(true)
    assert(findItem(pane, 601).quantity == 2 and not findItem(pane, 500),
        "the queue shows later auction inputs and leaves the cheaper vendor material to the merchant")
    selectItem(ctx, pane, 601)
    buy(ctx, pane, job.id, 2, 2)
    local _, stillReady = ctx.ns.Queue.NextTask(6, job)
    assert(stillReady == prerequisite and prerequisite.status == "pending" and not ctx.ns.processed,
        "buying a consumer's materials must be independent of processing its earlier craft")
    ctx:close()
end

for _, estimated in ipairs({6, 30}) do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.prices[159] = estimated
    local job = ctx:accept(159, 2, "Auto")
    local requirement = job.requirements[1]
    assert(requirement.kind == (estimated == 6 and "auction" or "vendor"))
    local pane = ctx:open(false)
    if estimated == 30 then
        assert(not pane or not findItem(pane, 159))
        assert(ctx.ui.OpenAuctionShopping(ctx.house, {jobId = job.id, id = 1, itemID = 159,
            planRevision = job.planRevision}))
        pane = ctx.ui.auctionShopping
        ctx.flush()
    end
    assert(pane)
    assert(findItem(pane, 159).quantity == 2, "shopping needs two waters, even if the vendor would deliver five")
    ctx.liveOffer = {quantity = 2, totalCopper = 16}
    local quote = startQuote(ctx, pane, job.id, 2)
    assert(quote.request.minQuantity == 2 and quote.request.maxUnitPrice == 24
        and quote.request.maxTotalPrice == 24 and #ctx.purchases == 0,
        "two waters at a higher market unit price can still cost less than the actual merchant pack")
    assert(not quote.authorize(quote.request, 1, 8) and not quote.authorize(quote.request, 2, 25),
        "a partial purchase that still needs the vendor pack and a full purchase at the vendor cost are rejected")
    buy(ctx, pane, job.id, 2, 2)
    assert(requirement.auctionSpent == 16 and requirement.auctionAwaiting == 2
        and findItem(pane, 159).quantity == 0 and findItem(pane, 159).incoming == 2)
    assert(not ctx.ns.Logistics.Acquire({kind = requirement.kind, job = job,
        requirement = requirement, id = 1, itemID = 159}, true), "paid incoming prevents a merchant purchase")
    ctx.stock[159] = 2
    ctx:inventoryChanged()
    assert(job.status == "complete" and requirement.auctionAwaiting == 0,
        "auction receipt clears the same accepted vendor or auction requirement without counting its bundle surplus")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.vendorPrice, ctx.prices[2321], ctx.prices[2605] = 100, 110, 110
    for _ = 1, 3 do
        assert(ctx:accept(2321, 3, "Auto").requirements[1].kind == "vendor")
        assert(ctx:accept(2605, 1, "Auto").requirements[1].kind == "vendor")
    end
    ctx:accept(4234, 9, "Auto")
    ctx:accept(4306, 60, "Auto")
    ctx.vendorPrice, ctx.prices[2321], ctx.prices[2605], ctx.mailKnown = 90, 96, 90, false
    local pane = assert(ctx:open(true))
    assert(#pane.entries == 2 and not findItem(pane, 2321) and not findItem(pane, 2605)
        and findItem(pane, 4234).quantity == 9 and findItem(pane, 4306).quantity == 60,
        "the saved Fine Thread and Green Dye stay with the cheaper or equal merchant despite an unverified inbox")
    local shopping = ctx.ns.Logistics.GetAuctionShoppingRequirements()
    assert(#shopping == 2 and #ctx.requests == 0,
        "the FluxUI Shopping projection also excludes merchant supplies without searching or spending")

    ctx.prices[2321] = 89
    ctx:inventoryChanged()
    assert(findItem(pane, 2321).quantity == 9 and not findItem(pane, 2605),
        "an auction estimate below the newest merchant price can surface the exact queued shortage")

    ctx.mailKnown = true
    local book
    FluxAuctionRestock.ScanLogisticsBooks = function(items, callback)
        assert(#items == 1 and items[1] == 2321)
        callback({[2321] = {itemID = 2321, complete = true, commodity = true, offers = book}})
        return true
    end
    local function updateBook(offers)
        book = offers
        assert(ctx.ns.Logistics.ScanAuctionPrices({itemID = 2321}, function(found) assert(found) end))
        ctx:inventoryChanged()
    end
    updateBook({{quantity = 1, unitPrice = 89}, {quantity = 20, unitPrice = 96}})
    assert(not findItem(pane, 2321), "one cheap listing does not cover a three-thread requirement below the vendor total")
    updateBook({{quantity = 20, unitPrice = 89}})
    assert(findItem(pane, 2321).quantity == 9 and #ctx.purchases == 0,
        "a cheaper read-only book makes the queued thread visible without spending")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.prices[159] = 6
    local job = ctx:accept(159, 2, "Auto")
    local pane = assert(ctx:open(false))
    assert(startQuote(ctx, pane, job.id, 2).request.maxTotalPrice == 24)
    ctx:settleQuote(nil, "noOffer")
    local row = assert(visibleRow(pane, 159))
    assert(row.price:GetText() == ctx.ns.L.shoppingVendorCost:format(ctx.ns.Pricing.FormatCopper(25)))
    assert(row.action:GetText() == ctx.ns.L.shoppingFindItem and #ctx.purchases == 0,
        "when no auction beats the complete vendor pack the row displays its vendor cost and keeps the search")
    ctx:close()
end

local function runQueue(target, ownerName, professionName, blocked)
    local ctx = fixture(target, ownerName, professionName)
    ctx.mail[300], ctx.prices[300] = 3, 10
    local first = ctx:accept(300, 5)
    ctx.prices[300] = 14
    local second = ctx:accept(300, 5)
    local other = ctx:accept(400, 3)
    local vendor = ctx:accept(500, 4, "Vendor")
    assert(vendor.requirements[1].kind == "vendor")
    if blocked == "uncertain" then
        first.acquisition = {kind = "auction", index = 1, quantity = 1, status = "uncertain"}
    elseif blocked == "budget" then
        first.requirements[1].maxTotalPrice = nil
    end

    local pane = assert(ctx:open(true))
    local item = assert(findItem(pane, 300))
    assert(#pane.entries == 2 and item.quantity == 7 and item.incoming == 3 and findItem(pane, 400).quantity == 3,
        "combine duplicated items across the sealed jobs and exclude the vendor requirement")
    local row = visibleRow(pane, 300)
    assert(row.quantity:GetText() == "7" and row.name:GetText() == "Fixture item 300"
        and row.incoming:GetText() == "3 incoming")
    assert(rowAction(pane, 300):GetText() == ctx.ns.L.shoppingFindOffer and rowAction(pane, 400):IsShown()
        and not pane.status:IsShown() and #ctx.requests == 0)
    rowAction(pane, 300):Fire("OnClick")
    ctx.flush()
    assert(pane.status:IsShown(), "each material can prepare its offer directly from the row")
    if blocked == "uncertain" or blocked == "budget" then
        assert(startQuote(ctx, pane, second.id, 5).request.maxUnitPrice == 14 and #ctx.purchases == 0,
            "an unresolved or unpriced first job must not block a later eligible job")
    elseif blocked then
        startQuote(ctx, pane, first.id, 2)
        ctx:settleQuote("idle", blocked)
        assert(startQuote(ctx, pane, second.id, 5).request.maxUnitPrice == 14,
            "a terminal offer failure must pass to the next eligible requirement")
        local requestCount = #ctx.requests
        ctx.ui.Refresh()
        ctx.ui.Refresh()
        assert(#ctx.requests == requestCount, "passive refreshes must not retry the rejected offer")
        buy(ctx, pane, second.id, 5, target == "classic" and 1 or 5)
        selectItem(ctx, pane, 300)
        assert(startQuote(ctx, pane, first.id, 2) and #ctx.purchases == 1,
            "explicitly reselecting the material retries its rejected offer without spending")
    else
        assert(startQuote(ctx, pane, first.id, 2).request.maxUnitPrice == 10)
        if target == "classic" then buy(ctx, pane, first.id, 2, 1) end
        buy(ctx, pane, first.id, target == "classic" and 1 or 2, target == "classic" and 1 or 2)
        item = assert(findItem(pane, 300))
        assert(item.quantity == 5 and item.incoming == 5, "pending inbox and own purchase receipts must each count once")
        assert(startQuote(ctx, pane, second.id, 5).request.maxUnitPrice == 14)
        local presses = target == "classic" and 5 or 1
        for press = 1, presses do
            buy(ctx, pane, second.id, target == "classic" and 6 - press or 5, target == "classic" and 1 or 5)
        end
        item = findItem(pane, 300)
        assert(not item or item.quantity == 0 and item.incoming == 10)
        assert(startQuote(ctx, pane, other.id, 3) and #ctx.purchases == (target == "classic" and 7 or 2),
            "the list advances to the next item without issuing a purchase")
        local previous = #ctx.purchases
        assert(pane.search.enabled)
        pane.search:Fire("OnClick")
        local terms = assert(ctx.searches[1])
        assert(#terms == 2 and terms[1].searchString == "Fixture item 400" and terms[1].quantity == 3
            and terms[2].searchString == "Fixture item 500" and terms[2].quantity == 4
            and terms[1].isExact and terms[2].isExact and terms[1].maxPrice == nil and terms[2].maxPrice == nil
            and #ctx.purchases == previous, "Auctionator compares vendor materials but leaves covered incoming stock out")
        local actionLabel = target == "forever" and ctx.ns.L.prepareShort or ctx.ns.L.processShort
        assert(ctx.ui.graph.frame:IsVisible() and ctx.ui.process:GetText() == actionLabel)
    end
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local vendor = ctx:accept(500, 4, "Vendor")
    assert(vendor.requirements[1].kind == "vendor")
    local pane = ctx:open(false)
    assert(not pane or not pane:IsVisible(), "a vendor-only queue should not open Auction House shopping")
    assert(ctx.ui.OpenAuctionShopping(ctx.house))
    pane = assert(ctx.ui.auctionShopping)
    assert(pane.search:IsShown() and pane.search.enabled)
    pane.search:Fire("OnClick")
    assert(#ctx.searches == 1 and #ctx.searches[1] == 1 and ctx.searches[1][1].quantity == 4
        and ctx.searches[1][1].searchString == "Fixture item 500")
    assert(#ctx.purchases == 0 and #ctx.requests == 0)
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local ui = ctx.ui
    ctx.ns.Catalog.Get(11).reagents = {{itemID = 300, quantity = 2}, {itemID = 500, quantity = 1}}
    ui.quantity:SetText("3")
    ui.quantity:Fire("OnEnterPressed")
    ctx.flush()
    assert(not ctx:open(true), "a preview without accepted work must not auto-open the detached list")
    ctx.house.left = 240
    ctx.house:SetWidth(1120)
    ui.graphShoppingButton:Fire("OnClick")
    local pane = assert(ui.auctionShopping)
    assert(pane:IsVisible() and #pane.entries == 1 and findItem(pane, 300).quantity == 6
        and rowAction(pane, 300):GetText() == ctx.ns.L.queuePlan and not findItem(pane, 500),
        "a manually opened preview lists the requested non-vendor shortage without accepting jobs")
    ctx.mail[300], ctx.mailKnown = 2, false
    ctx:inventoryChanged()
    assert(findItem(pane, 300).quantity == 6, "an unverified inbox cannot cover a draft shortage")
    ctx.mailKnown = true
    ctx:inventoryChanged()
    assert(findItem(pane, 300).quantity == 4 and findItem(pane, 300).incoming == 2,
        "draft shopping must use the same verified incoming materials as the accepted queue")
    selectItem(ctx, pane, 300)
    assert(rowAction(pane).enabled and rowAction(pane):GetText() == ctx.ns.L.queuePlan and #ctx.requests == 0)
    pane.search:Fire("OnClick")
    local sent = assert(ctx.searches[1])
    assert(#sent == 2 and sent[1].searchString == "Fixture item 300" and sent[1].isExact and sent[1].quantity == 4
        and sent[2].searchString == "Fixture item 500" and sent[2].isExact and sent[2].quantity == 3
        and #ctx.purchases == 0 and #ctx.ns.Queue.GetJobs() == 0
        and pane:IsVisible() and pane.anchorSide == "below",
        "the docked draft stays visible while comparing auction and vendor shortages without spending")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.mailKnown, ctx.mail[300] = false, 2
    Flux.Inventory.Mail.GetObservedCount = function(itemID)
        if ctx.mailKnown then return ctx.mail[itemID] or 0 end
        return nil, ctx.mail[itemID]
    end
    local job = ctx:accept(300, 5)
    local pane = assert(ctx:open(false))
    local entry = assert(ctx.ns.Queue.GetRequirements(job)[1])
    local need = ctx.ns.Logistics.GetAuctionNeed(entry)
    assert(not need.mailKnown and need.mailUsable and need.pendingIncoming == 2 and need.pendingMail == 0)
    pane.search:Fire("OnClick")
    assert(ctx.searches[1][1].quantity == 3 and #ctx.purchases == 0)
    buy(ctx, pane, job.id, 3, 3)
    assert(#ctx.purchases == 1 and findItem(pane, 300).quantity == 0 and findItem(pane, 300).incoming == 5,
        "an explicit Buy uses the known incoming count before a mailbox scan and adds the new receipt once")
    ctx.mailKnown, ctx.mail[300] = true, 5
    ctx:inventoryChanged()
    need = ctx.ns.Logistics.GetAuctionNeed(entry)
    assert(need.mailKnown and need.pendingIncoming == 5 and need.pendingMail == 5 and need.toBuy == 0
        and #ctx.purchases == 1, "the first full inbox scan reconciles the cached and purchased quantities")
    ctx:close()
end

local function runDraftPurchase(target, ownerName, professionName)
    local ctx = fixture(target, ownerName, professionName)
    local ui, recipe = ctx.ui, ctx.ns.Catalog.Get(11)
    recipe.reagents = {{itemID = 300, quantity = 2}, {itemID = 500, quantity = 1}}
    ctx.prices[300] = 7
    local older = ctx:accept(300, 4)
    ctx.prices[300] = 10
    ctx.mail[300] = 2
    ui.quantity:SetText("3")
    ui.quantity:Fire("OnEnterPressed")
    ctx.flush()
    local pane = assert(ctx:open(true))
    assert(findItem(pane, 300).quantity == 2 and findItem(pane, 300).entry.job == older)

    ui.graph.cards[1]:Fire("OnClick", "LeftButton")
    local action
    for _, control in ipairs(ui.menu.actions) do
        if control:IsShown() and control:GetText() == ctx.ns.L.shoppingThisCraft then action = control; break end
    end
    assert(action, "the selected recipe's output card must offer its own shopping list")
    action:Fire("OnClick")
    assert(pane.previewOnly and findItem(pane, 300).quantity == 6 and #ctx.requests == 0,
        "the current recipe must use incoming stock only after existing queue coverage")
    assert(rowAction(pane, 300).enabled and rowAction(pane, 300):GetText() == ctx.ns.L.queuePlan)
    ui.quantity:SetText("4")
    ui.quantity:Fire("OnTextChanged", true)
    rowAction(pane, 300):Fire("OnClick")
    ctx.flush()
    assert(#ctx.ns.Queue.GetJobs() == 1 and #ctx.requests == 0 and findItem(pane, 300).quantity == 8,
        "an old shopping row must refresh before accepting a changed draft")

    rowAction(pane, 300):Fire("OnClick")
    ctx.flush()
    local queued = assert(ui.job)
    assert(queued ~= older and #ctx.ns.Queue.GetJobs() == 2 and queued.summary.output == 4)
    assert(not pane.previewOnly and pane.entry.job == queued and not rowAction(pane, 300).enabled
        and #ctx.requests == 1 and #ctx.purchases == 0,
        "accepting from Shopping must prepare the exact new order and wait for a purchase click")
    local quote = startQuote(ctx, pane, queued.id, 8)
    assert(quote.request.maxUnitPrice == 10 and quote.request.maxTotalPrice == 80)
    ctx.deferConfirmation = target == "forever"
    buy(ctx, pane, queued.id, 8, target == "classic" and 1 or 8)
    if ctx.deferConfirmation then
        local group = assert(findItem(pane, 300))
        assert(group.pending and group.entry.job == queued and not rowAction(pane, 300).enabled and #ctx.requests == 1,
            "the same grouped row stays pending until the selected job's issued purchase is confirmed")
        ctx.deferConfirmation = false
        ctx.confirmPurchase()
        ctx.flush()
    end
    assert(not older.lastAcquisition and queued.lastAcquisition and #ctx.ns.Queue.GetJobs() == 2)
    if target == "classic" then
        for remaining = 7, 1, -1 do
            assert(pane.entry.job == queued, "the chosen job retains its exact offer through each legacy stack")
            buy(ctx, pane, queued.id, remaining, 1)
        end
    end
    local group = assert(findItem(pane, 300))
    assert(group.quantity == 2 and group.incoming == 10 and group.entry.job == older and not older.lastAcquisition,
        "the preferred job's paid incoming units must not hide another job's remaining shortage")
    local nextQuote = startQuote(ctx, pane, older.id, 2)
    assert(nextQuote.phase == "searching" and nextQuote.request.maxUnitPrice == 7 and nextQuote.request.maxTotalPrice == 28,
        "advancing prepares the older job's own limit without buying it")
    buy(ctx, pane, older.id, 2, target == "classic" and 1 or 2)
    ctx:close()
end

runDraftPurchase("forever", "AuctionHouseFrame", "ProfessionsFrame")
runDraftPurchase("classic", "AuctionFrame", "TradeSkillFrame")

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local ui, ns = ctx.ui, ctx.ns
    local recipe, bolts = ns.Catalog.Get(11), ns.Catalog.Get(22)
    recipe.reagents = {{itemID = 200, quantity = 5}}
    bolts.yield, bolts.reagents = 1, {{itemID = 300, quantity = 5}}
    ctx.prices[100], ctx.prices[200], ctx.prices[300] = 17898, 3000, 300
    ui.saved.choices[tostring(recipe.id)] = {[200] = {source = "Make"}}
    local function setOutput(quantity)
        ui.quantity:SetText(tostring(quantity))
        ui.quantity:Fire("OnEnterPressed")
        ctx.flush()
    end
    setOutput(20)
    ctx:open(true)
    assert(ui.preview.summary.fullValue == 150000, "the fixture starts with the cached scalar price")

    local previousAH, previousTime = C_AuctionHouse, GetTime
    local now, count, completed = 100, 2, false
    local tiers = {
        {itemID = 300, quantity = 6, unitPrice = 1, containsAccountItem = true},
        {itemID = 300, quantity = 3, unitPrice = 456, numOwnerItems = 1},
        {itemID = 300, quantity = 348, unitPrice = 500},
        {itemID = 300, quantity = 14, unitPrice = 501},
        {itemID = 300, quantity = 3, unitPrice = 502},
        {itemID = 300, quantity = 882, unitPrice = 504},
    }
    GetTime = function() return now end
    C_AuctionHouse = {
        GetNumCommoditySearchResults = function(itemID) assert(itemID == 300); return count end,
        GetCommoditySearchResultInfo = function(_, index) return tiers[index] end,
        HasFullCommoditySearchResults = function() return completed end,
    }
    local function receive(event)
        ctx.events[event]:Fire("OnEvent", event, 300)
        ctx.flush()
    end
    receive("COMMODITY_SEARCH_RESULTS_UPDATED")
    assert(not ui.preview.summary.valueKnown and not ns.Logistics.GetObservedAuctionPrice(300, 500),
        "a partial book with only two cheap items cannot price 500 units")
    completed, count = true, #tiers
    receive("COMMODITY_SEARCH_RESULTS_ADDED")
    local cost = 250464
    local material = ui.preview.tree.children[1].children[1]
    local unit, average = ns.Pricing.MaterialUnitPrice(material)
    local expectedProfit = 20 * 17898 * 0.95 - cost
    assert(material.required == 500 and material.fullValue == cost and unit == cost / 500 and average)
    assert(ui.preview.summary.fullValue == cost and ui.planCost:GetText():find(ns.Pricing.FormatCopper(cost), 1, true))
    assert(math.abs(ui.context.projection.estimatedProfit - expectedProfit) < 0.001
        and math.abs(ui.context.projection.profitOnCostPercent - 100 * expectedProfit / cost) < 0.001
        and ui.planProfit:GetText():find(ns.Pricing.FormatProfitPercent(100 * expectedProfit / cost), 1, true),
        "To Craft and after-fee profit percentage use the tiered input total")
    setOutput(1)
    assert(ui.preview.summary.fullValue == 12412, "a smaller batch reuses the same observed tiers at its actual quantity")
    setOutput(20)

    ui.queuePlan:Fire("OnClick")
    ctx.flush()
    local job = assert(ui.job)
    assert(job.requirements[1].quantity == 500 and job.requirements[1].maxTotalPrice == cost
        and job.requirements[1].maxUnitPrice == 504 and #ctx.purchases == 0)
    assert(ui.OpenAuctionShopping(ctx.house))
    local pane = ui.auctionShopping
    local row = assert(visibleRow(pane, 300))
    assert(row.entry.marketPrice.totalCopper == cost and row.entry.marketPrice.average
        and row.price:GetText() == ns.Pricing.FormatCopper(cost))
    assert(pane.budgetText:GetText() == ns.L.shoppingListedTotal:format(ns.Pricing.FormatCopper(cost)))

    receive("COMMODITY_PURCHASED")
    assert(not ns.Logistics.GetObservedAuctionPrice(300, 500) and not row.entry.marketPrice,
        "the shopping list drops the observed book after a purchase")
    tiers[2].quantity = 1
    receive("COMMODITY_SEARCH_RESULTS_UPDATED")
    assert(row.entry.marketPrice.totalCopper == cost + 96 and job.requirements[1].maxTotalPrice == cost,
        "new shopping prices keep the accepted job's existing purchase limit")
    now = 221
    assert(not ns.Logistics.GetObservedAuctionPrice(300, 500), "old market tiers expire per item")
    ctx:close()
    C_AuctionHouse, GetTime = previousAH, previousTime
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local ui = ctx.ui
    local receiveBooks
    FluxAuctionRestock.ScanLogisticsBooks = function(items, callback)
        local ids = {}
        for _, itemID in ipairs(items) do ids[itemID] = true end
        assert(ids[200] and ids[300] and not ids[100],
            "price comparison must scan both an intermediate and the materials to make it")
        receiveBooks = callback
        return true, "searching"
    end
    ui.quantity:SetText("3")
    ui.quantity:Fire("OnEnterPressed")
    ctx.flush()
    ctx:open(true)
    assert(ui.auctionPriceButton:IsVisible())
    ui.auctionPriceButton:Fire("OnClick")
    assert(receiveBooks and not ui.queuePlan.enabled and #ctx.purchases == 0 and #ctx.ns.Queue.GetJobs() == 0)
    receiveBooks({
        [200] = {itemID = 200, complete = true, commodity = true, offers = {{quantity = 6, unitPrice = 10}}},
        [300] = {itemID = 300, complete = true, commodity = true,
            offers = {{quantity = 1, unitPrice = 2}, {quantity = 20, unitPrice = 40}}},
    })
    ctx.flush()
    local required = {}
    for _, entry in ipairs(ui.preview.requirements) do required[entry.itemID] = entry.quantity end
    assert(required[200] == 4 and required[300] == 1 and ui.preview.summary.fullValue == 42
        and ui.queuePlan.enabled and #ctx.purchases == 0,
        "the fresh plan uses the cheap material for two intermediates and buys the remaining four")
    ui.queuePlan:Fire("OnClick")
    ctx.flush()
    assert(ui.job and ui.job.summary.fullValue == 42 and #ctx.purchases == 0,
        "accepting the quantity quote only reserves the mixed plan")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local recipe = ctx.ns.Catalog.Get(11)
    recipe.reagents = {{itemID = 200, quantity = 2}, {itemID = 500, quantity = 1}}
    for id = 800, 826 do recipe.reagents[#recipe.reagents + 1] = {itemID = id, quantity = 1} end
    ctx:open(false)
    local batches, checked = {}, {}
    FluxAuctionRestock.ScanLogisticsBooks = function(items, callback)
        batches[#batches + 1] = #items
        local books = {}
        for _, itemID in ipairs(items) do
            assert(not checked[itemID])
            checked[itemID] = true
            books[itemID] = {itemID = itemID, complete = true, commodity = true, offers = {}}
        end
        callback(books)
        return true
    end
    local completed
    assert(ctx.ns.Logistics.ScanAuctionPrices({recipeId = 11, quantity = 2, choices = {[200] = {source = "Buy"}}},
        function(found, incomplete) completed = found and not incomplete end))
    ctx.flush()
    assert(completed and #batches == 2 and batches[1] == 24 and batches[2] == 6
        and checked[200] and checked[300] and checked[500] and checked[826] and #ctx.purchases == 0,
        "a wide live scan prices all reachable materials including the make route for a buy-selected intermediate")
    ctx:close()
end

do
    local ctx = fixture("classic", "AuctionFrame", "TradeSkillFrame")
    ctx:open(false)
    FluxAuctionRestock.ScanLogisticsBooks = function(_, callback)
        callback({[610] = {itemID = 610, complete = true, commodity = false, offers = {
            {quantity = 2, total = 6, count = 1}, {quantity = 3, total = 12, count = 1},
            {quantity = 5, total = 20, count = 1},
        }}})
        return true, "searching"
    end
    assert(ctx.ns.Logistics.ScanAuctionPrices({itemID = 610}, function(found) assert(found) end))
    local job = ctx:accept(610, 5)
    assert(job.summary.fullValue == 18 and #job.requirements[1].auctionLots == 2)
    assert(ctx.ui.OpenAuctionShopping(ctx.house))
    local pane = ctx.ui.auctionShopping
    pane.primary.action:Fire("OnClick")
    local request = startQuote(ctx, pane, job.id, 5).request
    assert(request.stackSize + (request.stackSize == 2 and 3 or 2) == 5)
    local firstSize = request.stackSize
    local firstTotal = request.stackMaxTotalPrice
    buy(ctx, pane, job.id, 5, firstSize)
    local left = startQuote(ctx, pane, job.id, 5 - firstSize).request
    assert(left.stackSize == 5 - firstSize and left.stackMaxTotalPrice == 18 - firstTotal
        and left.maxTotalPrice == 18 - firstTotal and #ctx.purchases == 1)
    buy(ctx, pane, job.id, 5 - firstSize, 5 - firstSize)
    assert(job.requirements[1].auctionSpent == 18 and #ctx.purchases == 2)
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local first, second = ctx:accept(610, 2), ctx:accept(611, 3)
    local previousIcon = GetItemIcon
    GetItemIcon = function(id) return id + 2000 end
    local pane = assert(ctx:open(false))
    local control = pane.primary.action
    ctx.restockActive = true
    local row = assert(visibleRow(pane, 610))
    local format = ctx.ns.Pricing.FormatCopper
    assert(row.icon.texture == 2610 and row.price:GetText() == ctx.ns.L.shoppingBudget:format(format(20))
        and pane.budgetText:GetText():find(format(50), 1, true), "shopping rows label item icons and the remaining coin budget")
    assert(control:GetText() == ctx.ns.L.shoppingFindOffer)
    control:Fire("OnClick")
    assert(startQuote(ctx, pane, first.id, 2) and #ctx.purchases == 0)
    ctx:settleQuote("ready")
    assert(control:GetText() == ctx.ns.L.shoppingBuyQuantity:format(2) and row.price:GetText() == format(2),
        "the ready row displays the exact transaction price beside its Buy quantity")
    control:Fire("OnClick")
    ctx.flush()
    assert(#ctx.purchases == 1 and ctx.purchases[1].jobId == first.id and pane.entry.job == second,
        "the same main button advances to the next item without buying it")
    assert(ctx.quote and ctx.quote.request.jobId == second.id and ctx.quote.quantity == 3
        and ctx.quote.explicit and #ctx.purchases == 1,
        "a confirmed purchase prepares the next offer even with the owner Restock tab active")
    ctx:settleQuote("ready")
    control:Fire("OnClick")
    ctx.flush()
    assert(#ctx.purchases == 2 and ctx.purchases[2].jobId == second.id)
    ctx:close()
    GetItemIcon = previousIcon
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.prices[300] = 3
    local selected = ctx:accept(300, 2)
    ctx.prices[300] = 12
    local other = ctx:accept(300, 4)
    local pane = assert(ctx:open(false))
    assert(ctx.ui.OpenAuctionShopping(ctx.house, {jobId = selected.id, id = 1, itemID = 300,
        planRevision = selected.planRevision}))
    assert(startQuote(ctx, pane, selected.id, 2).request.maxUnitPrice == 3)
    ctx:settleQuote(nil, "overCap")
    assert(findItem(pane, 300).quantity == 6 and #ctx.requests == 2 and #ctx.purchases == 0,
        "a failed selected cap must leave both shortages visible and look for the other job's offer")
    local nextQuote = startQuote(ctx, pane, other.id, 4)
    assert(nextQuote.request.maxUnitPrice == 12 and nextQuote.request.maxTotalPrice == 48)
    buy(ctx, pane, other.id, 4, 4)
    assert(not selected.lastAcquisition and other.lastAcquisition,
        "the click can only buy the other job's independently authorized offer")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.prices[300] = 3
    local job = ctx:accept(300, 2)
    local pane = assert(ctx:open(false))
    local control = rowAction(pane, 300)
    control:Fire("OnClick")
    assert(startQuote(ctx, pane, job.id, 2))
    ctx:settleQuote(nil, "noOffer")
    assert(control:GetText() == ctx.ns.L.shoppingFindLiveOffer and control.enabled,
        "an ordinary cached order with no eligible offer offers exact live review")
    pane.search:Fire("OnClick")
    local term = assert(ctx.searches[1] and ctx.searches[1][1])
    assert(#ctx.searches[1] == 1 and term.searchString == "Fixture item 300" and term.isExact and term.quantity == 2)
    assert(term.maxPrice == nil and job.requirements[1].maxUnitPrice == 3 and not job.lastAcquisition
        and #ctx.purchases == 0 and #ctx.requests == 1,
        "viewing current listings does not retry the rejected quote, raise its limit, or buy anything")
    control:Fire("OnClick")
    assert(startQuote(ctx, pane, job.id, 2).explicit and #ctx.purchases == 0 and #ctx.requests == 2)
    assert(visibleRow(pane, 300).price:GetText() == "" and pane.budgetText:GetText() == "",
        "the provisional review limit is not presented as an approved amount")
    ctx.liveOffer = {quantity = 2, totalCopper = 9}
    ctx:settleQuote("ready")
    local price = assert(visibleRow(pane, 300)).price
    assert(control:GetText() == ctx.ns.L.shoppingBuyQuantity:format(2) and price:GetText() == ctx.ns.Pricing.FormatCopper(9))
    assert(not ctx.ns.Logistics.BuyAuction(pane.entry, 2, {quantity = 2, totalCopper = 8}) and #ctx.purchases == 0,
        "the reviewed purchase rejects a different displayed total")
    control:Fire("OnClick")
    assert(#ctx.purchases == 1 and ctx.purchases[1].totalCopper == 9 and job.requirements[1].maxTotalPrice == 6,
        "a second deliberate click buys only the displayed live price, leaving the original estimate intact")
    ctx:close()
end

do
    local ctx = fixture("classic", "AuctionFrame", "TradeSkillFrame")
    ctx.prices[300], ctx.restockActive = 3, true
    local job = ctx:accept(300, 3)
    local pane = assert(ctx:open(false))
    local nextOffer = pane.primary.action
    nextOffer:Fire("OnClick")
    assert(ctx.quote and ctx.quote.quantity == 3)
    ctx:settleQuote(nil, "noOffer")
    nextOffer:Fire("OnClick")
    ctx.liveOffer = {quantity = 2, totalCopper = 10}
    ctx:settleQuote("ready")
    nextOffer:Fire("OnClick")
    assert(#ctx.purchases == 1 and ctx.purchases[1].quantity == 2 and ctx.quote and ctx.quote.quantity == 1,
        "the same button prepares the next live stack after a confirmed purchase")
    ctx.liveOffer = {quantity = 1, totalCopper = 7}
    ctx:settleQuote("ready")
    assert(nextOffer:GetText() == ctx.ns.L.shoppingBuyQuantity:format(1) and #ctx.purchases == 1)
    nextOffer:Fire("OnClick")
    assert(#ctx.purchases == 2 and job.requirements[1].auctionAwaiting == 3)
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.prices[300] = 3
    local job = ctx:accept(300, 2)
    job.requirements[1].auctionSpent = 6
    local pane = assert(ctx:open(false))
    local nextOffer = pane.primary.action
    assert(nextOffer:GetText() == ctx.ns.L.shoppingFindLiveOffer and nextOffer.enabled)
    nextOffer:Fire("OnClick")
    assert(ctx.quote and ctx.quote.explicit and #ctx.purchases == 0,
        "after reopening, a used-up cached estimate still permits an explicitly reviewed live price")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    ctx.prices[300] = 3
    local job = ctx:accept(300, 2)
    local pane = assert(ctx:open(false))
    pane.search:Fire("OnClick")
    local row = assert(visibleRow(pane, 300))
    row:Fire("OnClick")
    assert(#ctx.requests == 0 and row.action:GetText() == ctx.ns.L.shoppingFindOffer)
    row.action:Fire("OnClick")
    assert(ctx.quote and ctx.quote.request.maxTotalPrice > 6 and #ctx.requests == 1 and #ctx.purchases == 0,
        "Search then Find offer prepares the live price in a single read-only lookup")
    ctx.liveOffer = {quantity = 2, totalCopper = 9}
    ctx:settleQuote("ready")
    row.action:Fire("OnClick")
    assert(#ctx.purchases == 1 and ctx.purchases[1].totalCopper == 9
        and job.requirements[1].maxTotalPrice == 6)
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local recipe = assert(ctx.ns.Catalog.Get(11))
    recipe.reagents[#recipe.reagents + 1] = {itemID = 500, quantity = 1}
    ctx.stock[200], ctx.stock[500] = 2, 1
    ctx.ui.Refresh()
    assert(not ctx:open(true) and ctx.ui.recipeAuctionator:IsVisible())
    ctx.ui.recipeAuctionator:Fire("OnClick")
    local terms = assert(ctx.searches[1])
    assert(#terms == 4 and terms[1].searchString == "Fixture item 100" and terms[2].searchString == "Fixture item 200"
        and terms[2].quantity == 2 and terms[3].searchString == "Fixture item 500" and terms[3].quantity == 1
        and terms[4].searchString == "Fixture item 300" and terms[4].quantity == nil and #ctx.ns.Queue.GetJobs() == 0,
        "the recipe search includes the vendor reagent and prices the alternative inputs for an on-hand intermediate")
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local demand = {id = "fixture-target", itemID = 300, target = 6, ready = 0, bank = 0, covered = 6, countBank = true}
    Flux.RestockPolicy.GetDemand = function(id) if id == demand.id then return demand end end
    local function preview()
        return ctx.ns.Logistics.Preview({itemID = 300, quantity = 6, intent = "stockUpTo", demand = demand})
    end
    assert(ctx.ns.Queue.Accept(preview(), preview))
    demand.bank = 6
    local pane = ctx:open(true)
    assert((not pane or not pane:IsShown()) and #ctx.requests == 0,
        "a stock target covered by the bank must not open shopping or ask the player to collect nonexistent mail")
    ctx.ui.graphShoppingButton:Fire("OnClick")
    pane = assert(ctx.ui.auctionShopping)
    assert(pane.empty:IsShown() and #pane.entries == 0 and not pane.rows[1].action:IsShown())
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local ui, recipe = ctx.ui, assert(ctx.ns.Catalog.Get(11))
    local vendor = {itemID = 500, quantity = 1, slotIndex = 2}
    recipe.reagents = {{itemID = 701, quantity = 1, slotIndex = 1}, vendor}
    recipe.reagentChoices = {
        {reagents = recipe.reagents},
        {reagents = {{itemID = 702, quantity = 1, slotIndex = 1}, vendor}},
    }
    ctx.stock[701], ctx.stock[702], ctx.stock[500] = 1, 2, 4
    ui.quantity:SetText("3")
    ui.quantity:Fire("OnEnterPressed")
    ui.queuePlan:Fire("OnClick")
    ctx.flush()
    local job = assert(ui.job)
    assert(#job.tasks == 2 and job.summary.output == 3 and #job.requirements == 0)
    ctx:open(true)
    ui.recipeAuctionator:Fire("OnClick")
    local function terms(index)
        local count, quantities = 0, {}
        for _, term in ipairs(assert(ctx.searches[index])) do
            count = count + 1
            assert(term.isExact and quantities[term.searchString] == nil)
            quantities[term.searchString] = term.quantity
        end
        return count, quantities
    end
    local count, quantities = terms(1)
    assert(count == 4 and quantities["Fixture item 100"] == 3 and quantities["Fixture item 701"] == 1
        and quantities["Fixture item 702"] == 2 and quantities["Fixture item 500"] == 3,
        "recipe search uses exact quantities across the selected craft batches, including the vendor material")

    assert(ctx.ns.Queue.Cancel(job.id))
    recipe.constraints = {cooldownUntil = 100}
    ui.quantity:SetText("4")
    ui.quantity:Fire("OnEnterPressed")
    ctx.flush()
    assert(ui.preview and ui.preview.inspectionOnly and #ui.preview.tasks == 0)
    ui.recipeAuctionator:Fire("OnClick")
    count, quantities = terms(2)
    assert(quantities["Fixture item 100"] == 4
        and (quantities["Fixture item 701"] or 0) + (quantities["Fixture item 702"] or 0) == 4
        and quantities["Fixture item 500"] == 4 and #ctx.purchases == 0,
        "a cooldown recipe must search its displayed target and direct ingredients without accepting or buying")
    ctx:close()
end

local function runGroupedPackShopping(scenario)
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local recipe = ctx.ns.Catalog.Get(11)
    recipe.name, recipe.professionName = "Green Silk Pack", "Tailoring"
    recipe.reagents = {{itemID = 4306, quantity = 20}, {itemID = 4234, quantity = 3}}
    local function preview()
        return ctx.ns.Logistics.Preview({recipeId = 11, quantity = 1})
    end
    local first = assert(ctx.ns.Queue.Accept(preview(), preview))
    local second = assert(ctx.ns.Queue.Accept(preview(), preview))
    assert(ctx.ns.Queue.CanGroup(first, second))
    local pane = assert(ctx:open(false))
    assert(findItem(pane, 4306).quantity == 40 and findItem(pane, 4234).quantity == 6)
    selectItem(ctx, pane, 4306)
    assert(startQuote(ctx, pane, first.id, 40) and #ctx.purchases == 0)
    if scenario == "stale" then
        ctx:settleQuote("ready")
        local action = rowAction(pane, 4306)
        action:Fire("OnMouseDown", "LeftButton")
        assert(ctx.ns.Queue.Cancel(second.id))
        assert(ctx.ns.Queue.Accept(preview(), preview))
        ctx.flush()
        action:Fire("OnClick")
        ctx.flush()
        assert(#ctx.purchases == 0 and findItem(pane, 4306).quantity == 40,
            "replacing a group member with the same quantity invalidates a previous Buy press")
    elseif scenario == "fallback" then
        ctx:settleQuote(nil, "noOffer")
        assert(startQuote(ctx, pane, first.id, 20) and #ctx.purchases == 0,
            "a grouped offer failure falls back to the next approved individual listing")
        buy(ctx, pane, first.id, 20, 20)
        assert(findItem(pane, 4306).quantity == 20 and findItem(pane, 4306).incoming == 20,
            "only the purchased share moves to pending before another press")
    else
        buy(ctx, pane, first.id, 40, 40)
        assert(#ctx.purchases == 1 and findItem(pane, 4306).quantity == 0 and findItem(pane, 4306).incoming == 40,
            "one approved Silk Cloth offer covers both packs")
        selectItem(ctx, pane, 4234)
        buy(ctx, pane, first.id, 6, 6)
        assert(#ctx.purchases == 2 and findItem(pane, 4234).quantity == 0 and findItem(pane, 4234).incoming == 6,
            "one approved Heavy Leather offer covers both packs")
    end
    ctx:close()
end

local function runSharedMaterialShopping(legacy, fallback)
    local target, owner, profession = "forever", "AuctionHouseFrame", "ProfessionsFrame"
    if legacy then target, owner, profession = "classic", "AuctionFrame", "TradeSkillFrame" end
    local ctx = fixture(target, owner, profession)
    local firstRecipe, secondRecipe = ctx.ns.Catalog.Get(11), ctx.ns.Catalog.Get(33)
    firstRecipe.reagents = {{itemID = 4306, quantity = 20}}
    secondRecipe.reagents, secondRecipe.constraints = {{itemID = 4306, quantity = 30}}, nil
    if legacy then
        ctx:open(true)
        FluxAuctionRestock.ScanLogisticsBooks = function(_, callback)
            callback({[4306] = {itemID = 4306, complete = true, commodity = false, offers = {
                {quantity = 20, total = 160, count = 1}, {quantity = 30, total = 270, count = 1},
            }}})
            return true, "searching"
        end
    end
    local function accept(recipe, price)
        ctx.prices[4306] = price
        if legacy then
            assert(ctx.ns.Logistics.ScanAuctionPrices({recipeId = recipe.id}, function(found) assert(found) end))
        end
        local function preview() return ctx.ns.Logistics.Preview({recipeId = recipe.id, quantity = 1}) end
        return assert(ctx.ns.Queue.Accept(preview(), preview))
    end
    local first, second = accept(firstRecipe, 8), accept(secondRecipe, 9)
    assert(first.rootItemID ~= second.rootItemID and not ctx.ns.Queue.CanGroup(first, second))
    if legacy then
        assert(first.requirements[1].auctionLots[1].quantity == 20 and second.requirements[1].auctionLots[1].quantity == 30)
        assert(ctx.ui.OpenAuctionShopping(ctx.house))
    else
        assert(ctx:open(false))
    end
    local pane = ctx.ui.auctionShopping
    assert(#pane.entries == 1 and findItem(pane, 4306).quantity == 50,
        "separate finished products must share one material row")
    selectItem(ctx, pane, 4306)
    local request = startQuote(ctx, pane, first.id, 50).request
    assert(request.groupRevision and request.maxUnitPrice == 8 and request.maxTotalPrice == 400
        and request.stackSize == (legacy and 50 or nil),
        "the combined offer preserves the strictest accepted limit and any whole-lot restriction")
    if fallback then
        ctx:settleQuote("idle", "noOffer")
        local individual = startQuote(ctx, pane, first.id, 20).request
        assert(individual.stackSize == 20 and individual.stackMaxTotalPrice == 160 and not individual.groupRevision
            and findItem(pane, 4306).quantity == 50 and #ctx.purchases == 0,
            "a missing whole combined listing falls back to an approved individual lot and retains the summed row")
    else
        ctx.liveOffer, ctx.deferConfirmation = {quantity = 50, totalCopper = 399}, true
        buy(ctx, pane, first.id, 50, 50)
        assert(first.acquisition.quantity == 20 and second.acquisition.quantity == 30
            and first.acquisition.totalCopper == 159 and second.acquisition.totalCopper == 240
            and first.acquisition.attemptID == second.acquisition.attemptID,
            "one native quote journals the exact quantities and apportions every paid copper across both orders")
        ctx.confirmPurchase()
        ctx.flush()
        assert(first.requirements[1].auctionAwaiting == 20 and second.requirements[1].auctionAwaiting == 30
            and first.requirements[1].auctionSpent == 159 and second.requirements[1].auctionSpent == 240
            and findItem(pane, 4306).quantity == 0 and findItem(pane, 4306).incoming == 50)
        if legacy then
            assert(first.requirements[1].auctionLotsFilled[1] == 1 and second.requirements[1].auctionLotsFilled[1] == 1)
        end
        ctx.stock[4306] = 50
        ctx:inventoryChanged()
        assert(first.requirements[1].remaining == 0 and second.requirements[1].remaining == 0,
            "one carried delivery clears both accepted requirement shares without double counting")
    end
    ctx:close()
end

do
    local ctx = fixture("forever", "AuctionHouseFrame", "ProfessionsFrame")
    local ui = ctx.ui
    ctx.ns.Catalog.Get(11).reagents = {{itemID = 4306, quantity = 20}}
    local second = ctx.ns.Catalog.Get(33)
    second.reagents, second.constraints = {{itemID = 4306, quantity = 30}}, nil
    ui.Refresh()
    ui.graphShoppingButton:Fire("OnClick")
    local pane = assert(ui.auctionShopping)
    assert(pane:IsVisible() and findItem(pane, 4306).quantity == 20)
    ui.queuePlan:Fire("OnClick")
    ctx.flush()
    assert(ui.auctionShopping == pane and pane:IsVisible() and findItem(pane, 4306).quantity == 20)
    local page = ProfessionsFrame.CraftingPage
    page.SchematicForm.selectedID = 33
    ctx.events["Professions.RecipeSelected"](page)
    ctx.flush()
    ui.queuePlan:Fire("OnClick")
    ctx.flush()
    assert(ui.auctionShopping == pane and pane:IsVisible() and #pane.entries == 1
        and findItem(pane, 4306).quantity == 50 and #ctx.requests == 0 and #ctx.purchases == 0,
        "keeping shopping open while Queue accepts a different recipe refreshes the existing row without bidding")
    ctx:open(false)
    ctx:close()
end

runGroupedPackShopping()
runGroupedPackShopping("fallback")
runGroupedPackShopping("stale")
runSharedMaterialShopping(false)
runSharedMaterialShopping(true)
runSharedMaterialShopping(true, true)
runFallback("forever", "AuctionHouseFrame", "ProfessionsFrame")
runFallback("classic", "AuctionFrame", "TradeSkillFrame")
runWhileCrafting("forever", "AuctionHouseFrame", "ProfessionsFrame")
runWhileCrafting("classic", "AuctionFrame", "TradeSkillFrame")
runQueue("forever", "AuctionHouseFrame", "ProfessionsFrame")
runQueue("classic", "AuctionFrame", "TradeSkillFrame")
runQueue("forever", "AuctionHouseFrame", "ProfessionsFrame", "noOffer")
runQueue("classic", "AuctionFrame", "TradeSkillFrame", "overCap")
runQueue("forever", "AuctionHouseFrame", "ProfessionsFrame", "uncertain")
runQueue("classic", "AuctionFrame", "TradeSkillFrame", "budget")
print("Queue shopping opens in one window, forwards exact quantities, and limits native purchases to the active plan")
