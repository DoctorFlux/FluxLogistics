local _, FC = ...
local Logistics = {}
FC.Logistics = Logistics
local priceScan, lastPriceScan, liveAuctionReview
local marketDepth, depthRevision, lastDepthSweep = {}, 0, 0
local DEPTH_LIFETIME = 120
local draftCatalog, recentDrafts, draftOrder
local DRAFT_LIMIT = 12

local function policy()
    local owner = Flux and Flux.RestockPolicy
    if owner and owner.version == 1 then return owner end
end

function Logistics.GetSettings()
    local db = FC.state.db
    db.preferences = db.preferences or {}
    return db.preferences
end

function Logistics.GetDemand(id)
    local owner = policy()
    return id and owner and owner.GetDemand and owner.GetDemand(id)
end

local function inputsFor(catalog, recipe, output, actor, choices, rootReagentChoice)
    local items, seenItems, scheduled, pending = {}, {}, {}, {}
    local links, expanded = {}, {}
    local timedRecipe
    local function schedule(producer)
        if producer and not scheduled[producer.id] then
            scheduled[producer.id] = true
            pending[#pending + 1] = producer
        end
    end
    local function add(itemID)
        if itemID and not seenItems[itemID] then
            seenItems[itemID] = true
            items[#items + 1] = itemID
        end
    end
    local function input(itemID)
        if not itemID or expanded[itemID] then return end
        expanded[itemID] = true
        add(itemID)
        local source, choice = FC.Planner.GetSourceChoice(choices, itemID)
        if source == "auto" or source == "make" then
            for _, producer in ipairs(FC.Planner.GetProducingRecipes(catalog, itemID, actor, choice.recipeId)) do
                schedule(producer)
            end
        end
    end
    if recipe then
        links[output] = recipe.outputLink
        schedule(recipe)
        add(output)
    else
        input(output)
    end
    local index = 1
    while index <= #pending do
        local current = pending[index]
        timedRecipe = timedRecipe or current.constraints and current.constraints.cooldownUntil ~= nil
        add(current.outputItemID)
        local selected = current == recipe and rootReagentChoice
        if selected then
            for _, reagent in ipairs(selected.reagents or {}) do input(reagent.itemID) end
        else
            for _, reagent in ipairs(current.reagents or {}) do input(reagent.itemID) end
            for _, choice in ipairs(current.reagentChoices or {}) do
                for _, reagent in ipairs(choice.reagents or {}) do input(reagent.itemID) end
            end
        end
        if #items > 700 or index > 1600 then return nil end
        index = index + 1
    end
    return items, links, timedRecipe
end

function Logistics.HasAuctionPriceScan()
    local auction = _G.FluxAuctionRestock
    return auction and type(auction.ScanLogisticsBooks) == "function"
end

function Logistics.ClearAuctionPrices()
    priceScan, lastPriceScan, liveAuctionReview = nil, nil, nil
    marketDepth, depthRevision, lastDepthSweep = {}, depthRevision + 1, 0
end

function Logistics.GetAuctionDepthRevision()
    return depthRevision
end

local function marketTime()
    return GetTime and GetTime() or 0
end

local function depthIsFresh(entry, now)
    return entry and entry.at <= now and now - entry.at < DEPTH_LIFETIME
end

local function storeAuctionDepth(itemID, book)
    local now = marketTime()
    local at = type(book.at) == "number" and book.at or now
    if at > now or now - at >= DEPTH_LIFETIME then return false end
    if now - lastDepthSweep >= DEPTH_LIFETIME then
        for id, entry in pairs(marketDepth) do
            if not depthIsFresh(entry, now) then marketDepth[id] = nil end
        end
        lastDepthSweep = now
    end
    local previous = marketDepth[itemID]
    if previous and previous.at > at then return false end
    marketDepth[itemID] = {book = book, at = at}
    depthRevision = depthRevision + 1
    return true
end

function Logistics.InvalidateAuctionDepth(itemID)
    if type(itemID) ~= "number" or (issecretvalue and issecretvalue(itemID)) or not marketDepth[itemID] then return false end
    marketDepth[itemID] = nil
    depthRevision = depthRevision + 1
    return true
end

local function observedAuctionBook(itemID, now)
    local entry = marketDepth[itemID]
    if depthIsFresh(entry, now) then return entry.book end
end

function Logistics.GetObservedAuctionPrice(itemID, quantity)
    local book = observedAuctionBook(itemID, marketTime())
    if not book or quantity <= 0 then return end
    local cost, units, evidence = FC.Planner.DirectCost({}, itemID, quantity, {[itemID] = book})
    if cost and units > 0 then
        return {totalCopper = cost, quantity = units, complete = evidence.complete, average = evidence.average}
    end
end

function Logistics.GetRecipePriceItems(recipeID, itemID)
    local catalog = FC.Catalog.Snapshot()
    local recipe = recipeID and catalog.recipesById[recipeID]
    local output = itemID or recipe and recipe.outputItemID
    if not output then return end
    local items = inputsFor(catalog, recipe, output, FC.state.characterKey)
    return items, output, recipe
end

function Logistics.ScanAuctionPrices(args, callback)
    local auction = _G.FluxAuctionRestock
    if not Logistics.HasAuctionPriceScan() then return false, "unavailable" end
    if priceScan or Logistics.IsWorkflowBusy() then return false, "busy" end
    local items, output, recipe = Logistics.GetRecipePriceItems(args.recipeId, args.itemID)
    if not items then return false, FC.L.observationLimit end
    local scan = {recipeId = args.recipeId, output = output, items = {}, books = {}}
    for _, id in ipairs(items) do
        if id ~= output or not recipe then scan.items[#scan.items + 1] = id end
    end
    if #scan.items == 0 then return false, FC.L.auctionNoMaterials end
    local function finish(failure)
        priceScan = nil
        local found = next(scan.books) ~= nil
        local incomplete = failure ~= nil
        if found then
            for _, id in ipairs(scan.items) do
                local book = scan.books[id]
                if book then storeAuctionDepth(id, book) end
                if not book or not book.complete then incomplete = true end
            end
            lastPriceScan = {recipeId = scan.recipeId, output = scan.output, at = marketTime()}
        end
        callback(found, incomplete, failure)
    end
    local function scanBatch(first)
        if priceScan ~= scan then return end
        local batch, last = {}, math.min(first + 23, #scan.items)
        for index = first, last do batch[#batch + 1] = scan.items[index] end
        return auction.ScanLogisticsBooks(batch, function(books, failure)
            if priceScan ~= scan then return end
            for _, id in ipairs(batch) do
                if type(books) == "table" and books[id] then scan.books[id] = books[id] end
            end
            scan.failure = scan.failure or failure
            if last == #scan.items or failure == "openAH" or failure == "otherSearch" then
                finish(scan.failure)
                return
            end
            local function scanNext()
                if priceScan ~= scan then return end
                local ok, reason = scanBatch(last + 1)
                if not ok then finish(reason or scan.failure or "loading") end
            end
            if C_Timer and C_Timer.After then C_Timer.After(0, scanNext) else scanNext() end
        end)
    end
    priceScan = scan
    local ok, reason = scanBatch(1)
    if not ok then priceScan = nil end
    return ok, reason
end

local function auctionDepthFor(args, itemID, items)
    if args.bagsOnly or args.directMaximum then return end
    local now = marketTime()
    local checked = depthIsFresh(lastPriceScan, now) and lastPriceScan.output == itemID and lastPriceScan.recipeId == args.recipeId
    local depth, incomplete = {}, false
    for _, id in ipairs(items) do
        if id ~= itemID or not args.recipeId then
            local book = observedAuctionBook(id, now)
            if book then depth[id] = book else incomplete = incomplete or checked == true end
        end
    end
    return next(depth) and depth or nil, incomplete
end

local function observationsFor(items, actor, demand, replaces)
    local owner = policy()
    local acquisitions = {}
    if not owner or not owner.GetAcquisitions then return acquisitions end
    local reserved, liveOffers = {}, false
    for _, entry in ipairs(FC.Queue.GetRequirements()) do
        if entry.job ~= replaces and entry.offerId then
            reserved[entry.offerId] = (reserved[entry.offerId] or 0) + entry.quantity
        end
    end
    for _, itemID in ipairs(items) do
        local offers = {}
        for _, offer in ipairs(owner.GetAcquisitions(itemID, actor) or {}) do
            if offer.availableUnits and reserved[offer.offerId] then
                offer.availableUnits = math.max(0, offer.availableUnits - reserved[offer.offerId])
            end
            if not demand or offer.kind ~= "bank" or itemID ~= demand.itemID
                or not demand.countBank and demand.bankRestock then
                offers[#offers + 1] = offer
                liveOffers = true
            end
        end
        acquisitions[itemID] = offers
    end
    return acquisitions, liveOffers
end

local function browsePlan(request, catalog, recipe, pause)
    if draftCatalog ~= catalog then draftCatalog, recentDrafts, draftOrder = catalog, {}, {} end
    local id = recipe.id
    local previous = recentDrafts[id]
    local plan = FC.Planner.Preview(request, previous, pause)
    -- A newer catalog may have completed its own search while this one slept.
    if draftCatalog ~= catalog then return plan end
    if previous == plan then return plan end
    if not previous then
        if #draftOrder >= DRAFT_LIMIT then recentDrafts[table.remove(draftOrder, 1)] = nil end
        draftOrder[#draftOrder + 1] = id
    end
    recentDrafts[id] = plan
    return plan
end

local function maximumBagsPlan(request, recipe, maximum)
    local limit = math.min(maximum, 999)
    local selected = request.rootReagentChoice
    local reagents = selected and selected.reagents or recipe.reagents
    if type(reagents) == "table" and #reagents == 0 and (selected or #(recipe.reagentChoices or {}) <= 1) then
        limit = 1
    end
    local capacityBounded
    local function probe(crafts)
        request.quantity = crafts * recipe.yield
        local plan = FC.Planner.Preview(request)
        if plan.status == "ready" and #plan.requirements == 0 and plan.summary.executions == crafts
            and plan.summary.additionalCash == 0 then return plan end
        if plan.diagnostics and plan.diagnostics.bounded then capacityBounded = true end
        return nil, plan.blocker or FC.L.planner.bags
    end

    local best, reason = probe(1)
    if not best then return nil, reason end
    local low, high = 1, math.min(2, limit)
    while low < high do
        local plan = probe(high)
        if not plan then break end
        best, low = plan, high
        high = math.min(high * 2, limit)
    end
    while high - low > 1 do
        local middle = math.floor((low + high) / 2)
        local plan = probe(middle)
        if plan then best, low = plan, middle else high = middle end
    end
    if capacityBounded then best.summary.capacityBounded = true end
    return best
end

function Logistics.Preview(args, catalog)
    catalog = catalog or FC.Catalog.Snapshot()
    local recipe = args.recipeId and catalog.recipesById[args.recipeId]
    local itemID = args.itemID or recipe and recipe.outputItemID
    if not itemID then return nil, recipe and recipe.blocker or FC.L.pickRecipe end
    local actor = FC.state.characterKey
    local items, links, timedRecipe
    local rootReagentChoice = args.availableMaximum and args.reagentChoice
    if args.directMaximum and recipe then
        items = FC.Planner.DirectReagentItems(recipe)
        items[#items + 1] = itemID
        links = {[itemID] = recipe.outputLink}
    else
        items, links, timedRecipe = inputsFor(catalog, recipe, itemID, actor, nil, rootReagentChoice)
    end
    local comparisonLimited
    if not items and type(args.choices) == "table" and next(args.choices) then
        -- Keep the wider material snapshot when it fits, since the graph
        -- compares against routes that the player chose not to use.
        items, links, timedRecipe = inputsFor(catalog, recipe, itemID, actor, args.choices, rootReagentChoice)
        comparisonLimited = true
    end
    if not items then return nil, FC.L.observationLimit end
    local counts, reason = FC.InventoryAdapter.Snapshot(items)
    if not counts then return nil, reason end
    local settings = Logistics.GetSettings()
    local inventory = FC.Queue.AvailableInventory(counts, args.replaces, args.batchOrders)
    local provider = FC.MarketAdapter or FC.AuctionatorAdapter
    local quotes, missing = {}, {}
    if provider then quotes, missing = provider.QuoteItems(items, links, settings.provider, settings.allowFallback) end
    if type(quotes) ~= "table" then quotes = {} end
    local auctionDepth, auctionDepthIncomplete = auctionDepthFor(args, itemID, items)
    local acquisitions, liveOffers
    if args.bagsOnly then acquisitions = {}
    else acquisitions, liveOffers = observationsFor(items, actor, args.demand, args.replaces) end
    local vendorEstimates = {}
    local owner = policy()
    if owner and owner.GetVendorPriceEstimate then
        for _, id in ipairs(items) do vendorEstimates[id] = owner.GetVendorPriceEstimate(id) end
    end
    local autoBuyVendor = settings.autoBuyVendor ~= false and args.autoBuyVendor ~= false
    local destination = args.destination or {actorKey = actor, locationKey = "bags"}
    local intent = args.intent or "additional"
    local covered = {}
    if intent == "stockUpTo" then
        -- Pending production stays distinct from physical bags. The accepted
        -- goal and any unallocated guaranteed batch units can cover this target.
        for _, job in ipairs(FC.Queue.GetJobs()) do
            local goal = job.goal
            if job ~= args.replaces and goal and job.rootItemID == itemID
                and goal.destination and goal.destination.actorKey == destination.actorKey
                and goal.destination.locationKey == destination.locationKey then
                covered[itemID] = (covered[itemID] or 0) + FC.Queue.OutstandingOutput(job)
                    + FC.Queue.PendingCarriedSurplus(job)
            end
        end
    end
    local now = GetServerTime and GetServerTime() or type(time) == "function" and time() or nil
    local request = {
        catalog = catalog, rootRecipeId = args.recipeId, rootItemID = itemID, quantity = args.quantity,
        characterKey = actor, intent = intent, destination = destination,
        inventory = inventory, quotes = quotes, acquisitions = acquisitions,
        auctionDepth = auctionDepth, auctionDepthIncomplete = auctionDepthIncomplete,
        vendorEstimates = vendorEstimates,
        unitCaps = args.demand and {[itemID] = tonumber(args.demand.maxPrice)},
        committedCoverage = covered, choices = args.choices or {}, rootReagentChoice = args.reagentChoice,
        bagsOnly = args.bagsOnly,
        inspectUnavailable = args.inspectUnavailable == true,
        deferRecipeRequirements = args.deferRecipeRequirements == true,
        objective = args.availableMaximum and "cash" or settings.objective or "value",
        limits = args.limits, now = now,
        revisions = {
            catalog = catalog.revision,
            inventory = FC.InventoryAdapter.GetRevision() .. "/" .. FC.Queue.GetRevision(),
            policy = {autoBuyVendor = autoBuyVendor, demandRevision = args.demand and args.demand.revision},
        },
    }
    local plan, quantity = nil, args.quantity
    if args.directMaximum then
        local blocker
        plan, blocker = FC.Planner.PreviewDirect(request, args.directMaximum, args.reagentChoice)
        if not plan then return nil, blocker end
        plan.goal.directCraft = nil
        quantity = plan.summary.requested
    elseif args.availableMaximum then
        if not recipe or type(recipe.yield) ~= "number" or recipe.yield < 1 or recipe.yield % 1 ~= 0 then
            return nil, FC.L.yieldUnknown
        end
        local blocker
        plan, blocker = maximumBagsPlan(request, recipe, args.availableMaximum)
        if not plan then return nil, blocker end
        quantity = plan.summary.requested
    elseif args.browse and recipe and not timedRecipe and not liveOffers then
        plan = browsePlan(request, catalog, recipe, args.pauseSearch)
    else
        plan = FC.Planner.Preview(request, nil, args.pauseSearch)
    end
    plan.goal = plan.goal or {}
    plan.goal.intent, plan.goal.quantity, plan.goal.destination = intent, quantity, destination
    plan.goal.actor = FC.state.actor
    plan.goal.inventorySource = FC.InventoryAdapter.GetStatus().source
    plan.goal.autoBuyVendor = autoBuyVendor
    plan.goal.auctionRestock = args.auctionRestock == true or nil
    local choices = args.choices or {}
    for chosenItem in pairs(choices) do
        local source, choice = FC.Planner.GetSourceChoice(choices, chosenItem)
        if source ~= "auto" or choice.recipeId or choice.ignoreOwned == true or choice.useOwned == false then
            plan.goal.sourceChoices = plan.goal.sourceChoices or {}
            local useOwned = choice.useOwned
            if type(useOwned) ~= "boolean" then useOwned = nil end
            plan.goal.sourceChoices[tostring(chosenItem)] = {source = source,
                recipeId = choice.recipeId and tostring(choice.recipeId), ignoreOwned = choice.ignoreOwned == true,
                useOwned = useOwned}
        end
    end
    for _, requirement in ipairs(plan.requirements or {}) do
        local choice = choices[requirement.itemID] or choices[tostring(requirement.itemID)]
        if requirement.kind == "auction" and type(choice) == "table"
            and type(choice.source) == "string" and choice.source:lower() == "buy" then
            plan.goal.auctionOnly = plan.goal.auctionOnly or {}
            plan.goal.auctionOnly[requirement.itemID] = true
        end
    end
    plan.goal.demandId = args.demand and args.demand.id
    plan.goal.ownerRevision = args.demand and args.demand.revision
    plan.goal.maxUnitPrice = args.demand and tonumber(args.demand.maxPrice)
    local projection = FC.Pricing.Project(plan, {saleQuote = quotes[itemID]})
    return plan, {
        catalog = catalog, counts = counts, inventory = inventory, quotes = quotes,
        acquisitions = acquisitions, projection = projection, now = now, missingQuotes = missing,
        vendorEstimates = vendorEstimates, comparisonLimited = comparisonLimited,
        auctionDepth = auctionDepth, auctionDepthIncomplete = auctionDepthIncomplete,
    }
end

function Logistics.PreviewAvailableCrafts(recipeID, maximum, choice, catalog)
    if type(maximum) ~= "number" or maximum < 1 or maximum >= math.huge or maximum % 1 ~= 0 then
        return nil, FC.L.quantityError
    end
    if choice and (type(choice) ~= "table" or type(choice.reagents) ~= "table") then
        return nil, FC.L.clients.staleReagents
    end
    return Logistics.Preview({recipeId = recipeID, availableMaximum = maximum, reagentChoice = choice,
        bagsOnly = true, autoBuyVendor = false}, catalog)
end

local function acquiring(allowPendingVendor)
    for _, job in ipairs(FC.Queue.GetJobs()) do
        if job.acquisition then
            for _, action in ipairs(FC.Queue.Acquisitions(job)) do
                if action.status == "issued"
                    and (not allowPendingVendor or action.kind ~= "vendor" or action.dispatching) then return true end
            end
        end
    end
    return false
end

function Logistics.IsWorkflowBusy(allowPendingVendor)
    local owner = policy()
    return priceScan ~= nil or acquiring(allowPendingVendor == true)
        or owner and owner.IsWorkflowBusy and owner.IsWorkflowBusy("planner") or false
end

local function readClock()
    return type(time) == "function" and time() or 0
end

local function currentEntry(entry, forDisplay)
    local job, requirement = entry and entry.job, entry and entry.requirement
    local status = job and job.status
    return job and requirement and (status == "queued" or forDisplay
        and (status == "paused" or status == "running" or status == "uncertain"))
        and job.characterKey == FC.state.characterKey
        and job.build == tostring(FC.state.build) and FC.Queue.GetJob(job.id) == job
        and job.requirements[entry.id] == requirement and requirement.itemID == entry.itemID
        and (entry.kind == requirement.kind or requirement.kind == "manual" and entry.kind == "auction")
end

local function directRestockGoal(entry)
    local job, requirement = entry.job, entry.requirement
    if job.goal and job.goal.demandId and entry.itemID == job.rootItemID
        and (requirement.goalQuantity or 0) > 0 and not next(requirement.consumers or {}) then
        return job.goal.demandId
    end
end

local function eligibleForRestock(demand, itemID)
    return (demand.units == "item" or demand.units == "items")
        and (demand.itemID == itemID or demand.tierKind and demand.eligible
            and demand.eligible(demand.tierKind, itemID))
end

local function destinationStock(demand, itemID, observed)
    -- Use the newest exact carried stock if no other location is counted.
    -- Keep the owner's combined observation for bags-plus-bank targets so a
    -- newer bag report does not count units that also remain in its bank cache.
    if not demand.tierKind and not demand.countBank and demand.itemID == itemID and observed then return observed end
    return demand.ready + demand.bank
end

local restockSourceOrder = {bank = 1, vendor = 2, auction = 3, manual = 4}

local function restockAllowance(entry, wanted, surface)
    local id = directRestockGoal(entry)
    if not id or wanted == 0 then return wanted end
    local demand = Logistics.GetDemand(id)
    if not demand or not eligibleForRestock(demand, entry.itemID)
        or surface == "bank" and (demand.countBank or not demand.bankRestock) then return 0 end
    local room = demand.target - destinationStock(demand, entry.itemID, FC.InventoryAdapter.Count(entry.itemID))
    if room <= 0 then return 0 end
    local free = room - demand.covered
    if free >= 0 then return math.min(wanted, room) end
    local earlier, foundJob = 0, false
    local entryOrder = restockSourceOrder[entry.requirement.kind] or math.huge
    -- The owner's coverage includes all accepted jobs. Reallocate only
    -- unpaid direct requirements. Preserve paid receipts and planned crafts.
    -- Earlier jobs keep priority, with bank and vendor stock used first
    -- when the same accepted job has multiple direct sources.
    for _, queued in ipairs(FC.Queue.GetRequirements()) do
        local requirement = queued.requirement
        local sameJob = queued.job == entry.job
        if sameJob then foundJob = true end
        local same = sameJob and queued.id == entry.id
        if directRestockGoal(queued) == id and (same or not queued.job.acquisition)
            and (requirement.kind ~= "bank" or not demand.countBank)
            and eligibleForRestock(demand, queued.itemID) then
            local needed = FC.Queue.AcquisitionRemaining(queued.job, requirement)
            local unpaid = math.max(0, needed - (requirement.auctionAwaiting or 0))
            free = free + unpaid
            local queuedOrder = restockSourceOrder[requirement.kind] or math.huge
            if not foundJob or sameJob and (queuedOrder < entryOrder
                or queuedOrder == entryOrder and queued.id < entry.id) then earlier = earlier + unpaid end
        end
    end
    return math.max(0, math.min(wanted, room, free - earlier))
end

local function restockOrderSize(entry, needed, kind, bundle)
    local allowed = restockAllowance(entry, needed, kind)
    return math.ceil(allowed / bundle) * bundle
end

local function acquisitionUpdate(status, job, action, quantity, message)
    local requirement = job.requirements[action.index]
    local entry = {job = job, requirement = requirement, id = action.index,
        itemID = requirement.itemID, kind = requirement.kind}
    FC:Emit("ACQUISITION_CHANGED", status, entry, quantity, message)
end

local function markUncertain(job, action)
    if FC.Queue.GetAcquisition(job, action.index) ~= action or action.status ~= "issued" then return end
    action.status = "uncertain"
    if action.kind == "vendor" then
        local requirement = job.requirements[action.index]
        action.blocksAutomaticPurchase = not requirement.autoBuyBlocked
        requirement.autoBuyBlocked = true
    end
    acquisitionUpdate("uncertain", job, action, action.credited or 0, FC.L.acquisitionUncertain)
end

local function inspectAcquisition(job, action)
    action = action or job.acquisition
    if not action or action.dispatching or action.kind == "auction" then return 0 end
    if FC.Queue.GetAcquisition(job, action.index) ~= action then return 0 end
    local requirement = job.requirements[action.index]
    if not requirement then return 0 end
    local taken = 0
    local status = FC.InventoryAdapter.GetStatus()
    if action.source and status.source ~= action.source then action.baselineInvalid = true end
    if not action.baselineInvalid then
        local count = FC.InventoryAdapter.Count(requirement.itemID)
        if count ~= nil then
            local increment = math.max(0, count - action.before - (action.credited or 0))
            taken = FC.Queue.CreditAcquisition(job, action.index, math.min(increment,
                action.quantity - (action.credited or 0)), count)
        end
    end
    if action.status == "confirmed" and action.blocksAutomaticPurchase then
        requirement.autoBuyBlocked = nil
    end
    if taken > 0 and action.auto then
        acquisitionUpdate("confirmed", job, action, taken, FC.L.acquisitionConfirmed)
    end
    if FC.Queue.GetAcquisition(job, action.index) == action and readClock() - action.startedAt >= 15 then
        markUncertain(job, action)
    end
    return taken
end

local function acceptedVendor(job, requirement)
    local owner = policy()
    return job.goal and job.goal.autoBuyVendor == true and not requirement.autoBuyBlocked
        and type(job.goal.inventorySource) == "string" and job.goal.inventorySource ~= "none"
        and Logistics.GetSettings().autoBuyVendor ~= false
        and (not (owner and owner.AllowsAutomaticVendorPurchase) or owner.AllowsAutomaticVendorPurchase() == true)
end

local function validAmount(value)
    return type(value) == "number" and not (issecretvalue and issecretvalue(value))
        and value >= 0 and value < math.huge
end

local function validCount(value)
    return validAmount(value) and value % 1 == 0
end

-- Read the same native search results used by the open auction pane. This
-- consumes no search or purchase throttle and does not use Auctionator frames.
function Logistics.ObserveCommodityDepth(itemID)
    local auction = C_AuctionHouse
    if not validCount(itemID) or itemID == 0 or not auction or not auction.GetNumCommoditySearchResults
        or not auction.GetCommoditySearchResultInfo or not auction.HasFullCommoditySearchResults then return false end
    local count = auction.GetNumCommoditySearchResults(itemID)
    -- An empty update can precede the results for a new search.
    if not validCount(count) or count == 0 then return false end
    local maximum = math.min(count, 600)
    local full = auction.HasFullCommoditySearchResults(itemID)
    local complete = not (issecretvalue and issecretvalue(full)) and full == true and count == maximum
    local offers, seen = {}, false
    for index = 1, maximum do
        local row = auction.GetCommoditySearchResultInfo(itemID, index)
        if type(row) == "table" and validCount(row.itemID) and row.itemID == itemID and validCount(row.quantity)
            and validCount(row.unitPrice) and row.unitPrice > 0
            and not (issecretvalue and (issecretvalue(row.containsAccountItem) or issecretvalue(row.numOwnerItems))) then
            local owned = row.numOwnerItems or 0
            if validCount(owned) and owned <= row.quantity then
                seen = true
                if not row.containsAccountItem and row.quantity > owned then
                    offers[#offers + 1] = {quantity = row.quantity - owned, unitPrice = row.unitPrice}
                end
            else complete = false end
        else complete = false end
    end
    if not seen then return false end
    return storeAuctionDepth(itemID, {itemID = itemID, commodity = true, offers = offers, complete = complete})
end

local function validVendorComparison(offer, itemID)
    return type(offer) == "table" and offer.itemID == itemID and offer.unit == "item"
        and (not offer.kind or offer.kind == "vendor")
        and validCount(offer.bundleSize) and offer.bundleSize > 0
        and validCount(offer.bundlePrice) and offer.bundlePrice > 0
        and (not offer.extraCurrency or type(offer.extraCurrency) == "table" and not next(offer.extraCurrency))
end

local function vendorComparison(entry, quantity)
    local job, requirement = entry.job, entry.requirement
    local goal = job.goal or {}
    local selected = goal.sourceChoices and goal.sourceChoices[tostring(entry.itemID)]
    if selected and selected.source ~= "auto" or goal.auctionOnly and goal.auctionOnly[entry.itemID] then return end
    if requirement.kind ~= "vendor" and requirement.kind ~= "auction" then return end
    local owner = policy()
    local accepted = requirement.kind == "vendor" and requirement.offer
    local observed = owner and owner.GetVendorPriceEstimate and owner.GetVendorPriceEstimate(entry.itemID)
    if not validVendorComparison(observed, entry.itemID) then observed = nil end
    if not validVendorComparison(accepted, entry.itemID) then return observed end
    if not observed then return accepted end
    quantity = quantity or FC.Queue.AcquisitionRemaining(job, requirement)
    local acceptedCost = math.ceil(quantity / accepted.bundleSize) * accepted.bundlePrice
    local observedCost = math.ceil(quantity / observed.bundleSize) * observed.bundlePrice
    return observedCost <= acceptedCost and observed or accepted
end

function Logistics.IsAuctionShoppingEntry(entry)
    return entry.kind == "auction" or entry.kind == "buy" or entry.kind == "manual"
        or entry.kind == "vendor" and ((entry.requirement.auctionAwaiting or 0) > 0 or vendorComparison(entry) ~= nil)
end

local function canUseVendorForAuction(entry)
    local job, requirement = entry.job, entry.requirement
    local cap = requirement.maxUnitPrice
    return job.goal and requirement.kind == "auction" and not requirement.auctionNeedsReplan
        and (requirement.auctionAwaiting or 0) == 0
        and not (job.goal.auctionOnly and job.goal.auctionOnly[entry.itemID])
        and type(cap) == "number" and not (issecretvalue and issecretvalue(cap)) and cap > 0 and cap < math.huge
end

local function vendorAlternative(entry)
    if not canUseVendorForAuction(entry) then return end
    local need = Logistics.GetAuctionNeed(entry, nil, {})
    if need and need.mailKnown and need.pendingIncoming == 0 and need.toBuy > 0 then
        if need.vendorCost then
            need.maxUnitPrice = need.vendorUnitPrice
            need.maxTotalPrice = need.vendorCost
            need.vendorBundle = true
            return need
        end
        -- Vendor bundles can have a fractional unit price. Use the actual
        -- accepted ceiling here, independently of the AH's whole-coin field.
        need.maxUnitPrice = entry.requirement.maxUnitPrice
        if need.maxTotalPrice and need.maxTotalPrice > 0 then return need end
    end
end

local function vendorReceiptBlocks(allowPendingVendor)
    local items, demands, waiting = {}, {}, false
    for _, job in ipairs(FC.Queue.GetJobs()) do
        if job.acquisition and job.status ~= "cancelled" and job.status ~= "replaced" and job.status ~= "complete" then
            for _, action in ipairs(FC.Queue.Acquisitions(job)) do
                if action.status ~= "uncertain"
                    and not (allowPendingVendor and action.kind == "vendor"
                        and action.status == "issued" and not action.dispatching) then return end
                if action.status == "issued" then waiting = true end
                local requirement = job.requirements and job.requirements[action.index]
                if not requirement or not requirement.itemID then return end
                items[requirement.itemID] = true
                local demandID = job.goal and job.goal.demandId
                if demandID then demands[demandID] = true end
            end
        end
    end
    return items, demands, waiting
end

local function canIssueVendor(entry, allowPendingVendor)
    local job = entry.job
    if not job.acquisition then return true end
    if not allowPendingVendor then return false end
    for _, action in ipairs(FC.Queue.Acquisitions(job)) do
        local requirement = job.requirements[action.index]
        if action.kind ~= "vendor" or action.status ~= "issued" or action.dispatching
            or not requirement or requirement.itemID == entry.itemID then return false end
    end
    return true
end

local function validAcquisitionOffer(live, entry, kind, cap)
    return live.qualified == true and live.offerId and live.kind == kind
        and live.itemID == entry.itemID and live.actorKey == entry.job.characterKey
        and live.unit == "item" and live.marketContext and live.locationKey
        and validCount(live.bundlePrice) and validCount(live.bundleSize) and live.bundleSize > 0
        and (not live.extraCurrency or type(live.extraCurrency) == "table" and not next(live.extraCurrency))
        and (not cap or cap <= 0 or live.bundlePrice / live.bundleSize <= cap)
        and (live.availableUnits == nil or validCount(live.availableUnits))
end

local function matchesVendorAlternative(offer, entry, need)
    return type(offer) == "table" and validAcquisitionOffer(offer, entry, "vendor", need.maxUnitPrice)
        and (need.vendorBundle or offer.bundlePrice < need.maxUnitPrice * offer.bundleSize)
end

local function vendorOrderQuantity(offer, quantity, budget)
    local units = math.min(quantity, offer.availableUnits or quantity)
    local bundles = math.floor(units / offer.bundleSize)
    if offer.bundlePrice > 0 then
        local money = GetMoney and GetMoney()
        if type(money) ~= "number" or issecretvalue and issecretvalue(money) then return end
        bundles = math.min(bundles, math.floor(math.min(money, budget) / offer.bundlePrice))
    end
    return bundles * offer.bundleSize
end

local function substitutedVendorQuantity(requirement, offer, need)
    if need.vendorBundle then return math.ceil(need.toBuy / offer.bundleSize) * offer.bundleSize end
    return math.min(need.toBuy, requirement.quantity - (requirement.vendorIssuedUnits or 0))
end

local creditCarriedRequirements

local function vendorBudget(requirement, quoted)
    local credited = requirement.quantity - (requirement.remaining or requirement.quantity)
    local units = requirement.vendorIssuedUnits or math.ceil(credited / quoted.bundleSize) * quoted.bundleSize
    local copper = requirement.vendorIssuedCopper or units / quoted.bundleSize * quoted.bundlePrice
    local budget = (requirement.maxTotalPrice or requirement.quantity / quoted.bundleSize * quoted.bundlePrice)
        - copper - (requirement.auctionSpent or 0)
    return units, copper, budget
end

local function matchesApprovedOffer(live, entry, kind, cap, quoted, offerId, estimatedVendor)
    if type(live) ~= "table" or not validAcquisitionOffer(live, entry, kind, cap)
        or quoted.kind ~= live.kind or quoted.itemID ~= live.itemID or quoted.unit ~= live.unit
        or quoted.itemLink and live.itemLink ~= quoted.itemLink then return false end
    if estimatedVendor then
        return validAmount(quoted.bundlePrice) and validCount(quoted.bundleSize) and quoted.bundleSize > 0
            and live.bundlePrice / live.bundleSize <= quoted.bundlePrice / quoted.bundleSize
    end
    return live.offerId == offerId and quoted.actorKey == live.actorKey
        and live.bundleSize == quoted.bundleSize and live.bundlePrice == quoted.bundlePrice
        and live.marketContext == quoted.marketContext and live.locationKey == quoted.locationKey
end

local function executeAcquisition(owner, offer, quantity, validate, batch)
    local maximum = batch and offer.kind == "vendor" and offer.availableUnits == nil
        and validCount(offer.slot) and offer.slot > 0 and GetMerchantItemMaxStack
        and GetMerchantItemMaxStack(offer.slot)
    local stack = validCount(maximum) and math.floor(maximum / offer.bundleSize) * offer.bundleSize
    if not stack or stack == 0 or quantity <= stack then
        return pcall(owner.ExecuteAcquisition, offer, quantity, validate)
    end
    -- Unlimited stock can be sent in native-sized chunks before the bags
    -- update. Keep one receipt and the original quantity and budget limits.
    local total = 0
    for _ = 1, 12 do
        local requested = math.min(stack, quantity - total)
        local approved
        local called, ok, reason, issued = pcall(owner.ExecuteAcquisition, offer, requested, function(live, units, copper)
            if not validCount(units) or units < 1 or units > requested or not validate(live, units, copper) then return false end
            approved = units
            return true
        end)
        if not called or ok and (not approved or issued ~= nil and issued ~= approved) then
            return false, false, reason, total + (approved or requested), true
        end
        if not ok then return true, total > 0, reason, total > 0 and total or nil, true end
        total = total + approved
        if total == quantity or approved < requested then break end
    end
    return true, true, nil, total, true
end

local function acquire(entry, automatic, selection, batch)
    if not currentEntry(entry) then return false, FC.L.alreadyCovered end
    local job, requirement = entry.job, entry.requirement
    if automatic and not acceptedVendor(job, requirement) then return false, FC.L.offerChanged end
    local bankSelection = selection and selection.kind == "bank" and selection
    local vendorSelected = selection ~= nil and selection.kind == "vendor"
    local substituted = entry.kind == "auction" and (automatic == true or vendorSelected)
    local kind = bankSelection and "bank" or substituted and "vendor" or entry.kind
    local parallelVendor = kind == "vendor" and batch ~= nil and canIssueVendor(entry, true)
    local owner = policy()
    local liveOffers
    if substituted then
        if not canUseVendorForAuction(entry) or not (owner and owner.GetAcquisitions and owner.ExecuteAcquisition) then
            return false, FC.L.offerUnavailable
        end
        if vendorSelected then
            liveOffers = {selection.offer}
        else
            for _, offer in ipairs(owner.GetAcquisitions(entry.itemID, job.characterKey) or {}) do
                if offer.kind == "vendor" then
                    liveOffers = {offer}
                    break
                end
            end
        end
        if not liveOffers then return false, FC.L.offerUnavailable end
    end
    if (not job.acquisition or parallelVendor) and (kind == "bank" or kind == "vendor") then
        creditCarriedRequirements(entry.itemID)
    end
    local needed, orderQuantity = FC.Queue.AcquisitionRemaining(job, requirement)
    if needed <= 0 then
        return false, FC.L.alreadyCovered
    end
    local authorized
    if substituted then
        authorized = vendorAlternative(entry)
        if not authorized then return false, FC.L.offerUnavailable end
    elseif kind == "vendor" and (not job.acquisition or parallelVendor) then
        local auctionNeed = Logistics.GetAuctionNeed(entry, nil, {})
        if (requirement.auctionAwaiting or 0) > 0 or auctionNeed and (auctionNeed.pendingIncoming or 0) > 0 then
            return false, FC.L.shoppingCollectMail
        end
    elseif automatic and entry.kind ~= "vendor" then
        return false, FC.L.offerUnavailable
    end
    entry.quantity = orderQuantity
    local observation = FC.InventoryAdapter.GetStatus()
    local function sameObservation()
        local live = FC.InventoryAdapter.GetStatus()
        return live.reliable and live.source == observation.source
            and live.sourceGeneration == observation.sourceGeneration
    end
    if (automatic or substituted or batch) and (not observation.reliable or observation.source == "none") then
        return false, observation.reason or FC.L.loading
    end
    local count, reason = FC.InventoryAdapter.Count(entry.itemID)
    if count == nil then return false, reason end
    if job.acquisition and not parallelVendor then
        local credited = inspectAcquisition(job, FC.Queue.GetAcquisition(job, entry.id))
        if job.acquisition and job.acquisition.status == "uncertain" then
            return false, FC.L.acquisitionUncertain
        end
        return credited > 0, credited > 0 and FC.L.acquisitionConfirmed or FC.L.acquisitionPending
    end
    if Logistics.IsWorkflowBusy(batch ~= nil) or FC.Execution.IsBusy and FC.Execution.IsBusy() then
        return false, FC.L.workflowBusy
    end
    if (automatic or substituted or batch) and not sameObservation() then return false, FC.L.offerChanged end
    if automatic and not directRestockGoal(entry) then
        -- Both reliable providers report absolute carried units for this actor.
        -- Compare that stock only when no purchase for this job is in flight.
        local baseline = requirement.baseline or count
        requirement.baseline = math.min(baseline, count)
        local gained = count - baseline
        if gained > 0 then
            local credited = FC.Queue.CreditAcquisition(job, entry.id, gained, count)
            if credited > 0 then
                FC:Emit("ACQUISITION_CHANGED", "confirmed", entry, credited, FC.L.acquisitionConfirmed)
                return true, FC.L.acquisitionConfirmed
            end
        end
    end
    if kind ~= "bank" and kind ~= "vendor" then
        local additional = count - (requirement.baseline or count)
        if additional > 0 and FC.Queue.CreditAcquisition(job, entry.id, additional, count) > 0 then
            return true, FC.L.acquisitionConfirmed
        end
        if owner and owner.OpenAuctionRequirement then
            local selection = entry
            if owner.GetShoppingRequirements then
                selection = nil
                for _, candidate in ipairs(owner.GetShoppingRequirements("auction")) do
                    if candidate.jobId == job.id and candidate.id == entry.id
                        and candidate.itemID == entry.itemID and candidate.planRevision == job.planRevision then
                        selection = candidate
                        break
                    end
                end
                if not selection then return false, FC.L.alreadyCovered end
            end
            local opened, why = owner.OpenAuctionRequirement(selection)
            if opened then return true, why end
        end
        return false, FC.L.acquireManually
    end
    if not (owner and owner.ExecuteAcquisition and owner.GetAcquisitions) then
        return false, FC.L.ownerUnavailable
    end
    local quoted = bankSelection and bankSelection.offer or requirement.offer or requirement.quote or requirement
    local offerId = bankSelection and quoted.offerId or entry.offerId
    local estimatedVendor = kind == "vendor" and offerId == nil and requirement.estimate == true
    local cap = authorized and authorized.maxUnitPrice or requirement.maxUnitPrice
        or entry.itemID == job.rootItemID and job.goal and job.goal.maxUnitPrice
    local function matches(live)
        if substituted then return matchesVendorAlternative(live, entry, authorized) end
        return matchesApprovedOffer(live, entry, kind, cap, quoted, offerId, estimatedVendor)
    end
    local offer, changed
    for _, candidate in ipairs(liveOffers or owner.GetAcquisitions(entry.itemID, job.characterKey) or {}) do
        if candidate.offerId == offerId or (estimatedVendor or substituted) and candidate.kind == "vendor" then
            if matches(candidate) then offer = candidate; break end
            changed = true
        end
    end
    if not offer then return false, changed and not substituted and FC.L.offerChanged or FC.L.offerUnavailable end
    local quantity = bankSelection and math.min(needed, bankSelection.quantity) or orderQuantity
    if estimatedVendor then quantity = math.ceil(needed / offer.bundleSize) * offer.bundleSize end
    local vendor = offer.kind == "vendor"
    if substituted then quantity = substitutedVendorQuantity(requirement, offer, authorized)
    elseif directRestockGoal(entry) then
        quantity = math.min(quantity, restockOrderSize(entry, needed, kind, offer.bundleSize))
    end
    if quantity <= 0 then return false, FC.L.alreadyCovered end
    local issuedUnits, issuedCopper, budget
    if vendor then
        -- Older saved plans did not distinguish already credited units from
        -- purchased ones. Count those units conservatively towards the cap.
        if substituted then
            issuedUnits, issuedCopper = requirement.vendorIssuedUnits or 0, requirement.vendorIssuedCopper or 0
            budget = authorized.maxTotalPrice
        else
            issuedUnits, issuedCopper, budget = vendorBudget(requirement, quoted)
        end
        local available = substituted and authorized.vendorBundle and quantity or math.min(quantity, requirement.quantity - issuedUnits)
        quantity = vendorOrderQuantity(offer, available, batch and math.min(batch.funds, budget) or budget)
        if not quantity or vendorSelected and quantity ~= selection.quantity then
            return false, FC.L.offerChanged
        end
        if quantity <= 0 then return false, FC.L.offerUnavailable end
    else
        quantity = math.min(quantity, offer.availableUnits or quantity)
        if quantity <= 0 then return false, FC.L.offerUnavailable end
    end
    local action = {kind = kind, index = entry.id, quantity = quantity, before = count, startedAt = readClock(),
        credited = 0, status = "issued", dispatching = true, auto = automatic == true,
        addonVersion = FC.version, clientBuild = FC.state.clientBuild,
        source = observation.source, substitutedAuction = substituted or nil}
    local revision = job.planRevision
    if vendor then
        if not FC.Queue.AddVendorAcquisition(job, action) then return false, FC.L.acquisitionPending end
    else job.acquisition = action end
    local function recordIssue(units)
        if not vendor then return end
        local copper = units / offer.bundleSize * offer.bundlePrice
        action.totalCopper = copper
        requirement.vendorIssuedUnits = issuedUnits + units
        requirement.vendorIssuedCopper = issuedCopper + copper
        if batch then batch.funds = math.max(0, batch.funds - copper) end
    end
    local function validate(live, units, totalCopper)
        if not live or not matches(live) or type(units) ~= "number"
            or units <= 0 or units % live.bundleSize ~= 0 then return false end
        local total = live.bundlePrice * (units / live.bundleSize)
        local outstanding = FC.Queue.AcquisitionRemaining(job, requirement)
        if substituted then
            local current = vendorAlternative(entry)
            if not current or current.maxUnitPrice ~= cap or current.maxTotalPrice ~= budget
                or substitutedVendorQuantity(requirement, live, current) < units then return false end
        elseif directRestockGoal(entry) and units > restockOrderSize(entry, outstanding, kind, live.bundleSize) then
            return false
        end
        return FC.Queue.GetAcquisition(job, entry.id) == action and action.status == "issued"
            and currentEntry(entry) and job.planRevision == revision
            and live.offerId == offer.offerId and live.bundleSize == offer.bundleSize and live.bundlePrice == offer.bundlePrice
            and live.marketContext == offer.marketContext and live.locationKey == offer.locationKey
            and (not automatic or acceptedVendor(job, requirement))
            and (not (automatic or substituted or batch) or sameObservation())
            and units <= quantity
            and (vendor and outstanding == needed or not vendor and sameObservation()
                and units <= outstanding and units <= action.quantity - action.credited)
            and (totalCopper == nil or totalCopper == total)
            and (not batch or total <= batch.funds)
            and (not vendor or total <= budget)
    end
    local called, ok, why, issued = executeAcquisition(owner, offer, quantity, validate, batch)
    action.dispatching = nil
    if not called then
        -- The owner may have issued the native action before throwing.
        action.quantity = issued or quantity
        recordIssue(action.quantity)
        markUncertain(job, action)
        return false, FC.L.acquisitionUncertain, true
    end
    if not ok then
        FC.Queue.RemoveAcquisition(job, action)
        FC.Queue.FinishDeferredInvalidation(job)
        return false, why, true
    end
    if issued ~= nil and (type(issued) ~= "number" or issued <= 0 or issued > quantity or issued % offer.bundleSize ~= 0) then
        recordIssue(quantity)
        markUncertain(job, action)
        return false, FC.L.acquisitionUncertain, true
    end
    action.quantity = issued or quantity
    recordIssue(action.quantity)
    if automatic then acquisitionUpdate("issued", job, action, action.quantity, FC.L.acquisitionPending) end
    inspectAcquisition(job, action)
    if C_Timer and C_Timer.After then
        C_Timer.After(16, function()
            if FC.Queue.GetAcquisition(job, entry.id) == action then
                inspectAcquisition(job, action)
                FC:Emit("ACQUISITION_CHANGED")
            end
        end)
    end
    return true, FC.L.acquisitionPending, true
end

local function vendorShare(entry, offers, automatic, action, allowAlternative, allowPendingVendor)
    local substituted = allowAlternative and entry.kind == "auction"
    if not currentEntry(entry) or FC.Queue.IsClearing(entry.job) or entry.kind ~= "vendor" and not substituted
        or action and FC.Queue.GetAcquisition(entry.job, entry.id) ~= action
        or not action and not canIssueVendor(entry, allowPendingVendor) then return end
    local job, req = entry.job, entry.requirement
    if automatic and not acceptedVendor(job, req) then return end
    if substituted then
        local need = vendorAlternative(entry)
        if not need then return end
        for _, offer in ipairs(offers) do
            if matchesVendorAlternative(offer, entry, need) then
                local requested = substitutedVendorQuantity(req, offer, need)
                local quantity = vendorOrderQuantity(offer, requested, need.maxTotalPrice)
                -- Shares stay on bundle boundaries so each charge and receipt
                -- can be credited without rounding across accepted caps.
                if quantity and quantity > 0 and quantity == requested and quantity <= need.toBuy then
                    return {entry = entry, offer = offer, needed = need.toBuy, requested = requested, quantity = quantity,
                        issuedUnits = req.vendorIssuedUnits or 0, issuedCopper = req.vendorIssuedCopper or 0,
                        budget = need.maxTotalPrice, revision = job.planRevision, substitutedAuction = true}
                end
            end
        end
        return
    end
    local incoming = Logistics.GetAuctionNeed(entry, nil, {})
    if (req.auctionAwaiting or 0) > 0 or incoming and incoming.pendingIncoming > 0 then return end
    local needed, requested = FC.Queue.AcquisitionRemaining(job, req)
    if needed <= 0 then return end
    local quoted = req.offer or req.quote or req
    if not validCount(quoted.bundleSize) or quoted.bundleSize < 1 or not validAmount(quoted.bundlePrice) then return end
    local estimated = entry.offerId == nil and req.estimate == true
    local cap = req.maxUnitPrice or entry.itemID == job.rootItemID and job.goal and job.goal.maxUnitPrice
    for _, offer in ipairs(offers) do
        if matchesApprovedOffer(offer, entry, "vendor", cap, quoted, entry.offerId, estimated) then
            local issuedUnits, issuedCopper, budget = vendorBudget(req, quoted)
            local quantity = estimated and math.ceil(needed / offer.bundleSize) * offer.bundleSize or requested
            if directRestockGoal(entry) then
                quantity = math.min(quantity, restockOrderSize(entry, needed, "vendor", offer.bundleSize))
            end
            quantity = math.min(quantity, req.quantity - issuedUnits)
            local purchasable = vendorOrderQuantity(offer, quantity, budget)
            if purchasable and purchasable > 0 then
                return {entry = entry, offer = offer, needed = needed, requested = quantity, quantity = purchasable,
                    issuedUnits = issuedUnits, issuedCopper = issuedCopper, budget = budget, revision = job.planRevision}
            end
        end
    end
end

local function sameVendorTerms(left, right)
    return left.offerId == right.offerId and left.itemID == right.itemID and left.bundleSize == right.bundleSize
        and left.bundlePrice == right.bundlePrice and left.locationKey == right.locationKey
        and left.marketContext == right.marketContext and left.revision == right.revision
        and left.availableUnits == right.availableUnits
end

local function quoteVendorGroup(entry, candidates, owner, automatic, batch, allowAlternative)
    if directRestockGoal(entry) then return end
    local blockedItems = vendorReceiptBlocks(batch ~= nil)
    if not blockedItems or blockedItems[entry.itemID] then return end
    local offers = owner.GetAcquisitions(entry.itemID, entry.job.characterKey) or {}
    local first = vendorShare(entry, offers, automatic, nil, allowAlternative, batch ~= nil)
    if not first or first.quantity ~= first.requested then return end
    local shares, jobs, quantity = {}, {}, 0
    local selected
    for _, candidate in ipairs(candidates or FC.Queue.GetRequirements()) do
        local other = candidate.entry or candidate
        local alternative = candidate.entry ~= nil or automatic == true and other.kind == "auction"
        if not candidate.pending and other.itemID == entry.itemID and (other.kind == "vendor" or alternative)
            and not jobs[other.job] and not directRestockGoal(other) then
            local isSelected = other.job == entry.job and other.id == entry.id
            local share = isSelected and first
                or other.job ~= entry.job and vendorShare(other, offers, automatic, nil, alternative, batch ~= nil)
            if share and share.quantity == share.requested and sameVendorTerms(first.offer, share.offer) then
                shares[#shares + 1], jobs[other.job], quantity = share, true, quantity + share.quantity
                if isSelected then selected = true end
            end
        end
    end
    if not selected or #shares < 2 then return end
    local offer = first.offer
    local total = quantity / offer.bundleSize * offer.bundlePrice
    if batch and total > batch.funds or vendorOrderQuantity(offer, quantity, total) ~= quantity then return end
    local positions = {}
    for index, job in ipairs(FC.Queue.GetJobs()) do positions[job] = index end
    table.sort(shares, function(left, right) return positions[left.entry.job] < positions[right.entry.job] end)
    return shares, quantity
end

local function buyVendorGroup(shares, quantity, owner, automatic, batch)
    local offer = shares[1].offer
    local before, reason = FC.InventoryAdapter.Count(offer.itemID)
    if not validCount(before) then return false, reason or FC.L.loading end
    local stock = FC.InventoryAdapter.GetStatus()
    if not stock.reliable or stock.source == "none" then return false, stock.reason or FC.L.loading end
    for index, share in ipairs(shares) do
        local entry = share.entry
        share.action = {kind = "vendor", index = entry.id, quantity = share.quantity, before = before,
            startedAt = readClock(), credited = 0, status = "issued", dispatching = true, auto = automatic == true,
            addonVersion = FC.version, clientBuild = FC.state.clientBuild, source = stock.source,
            substitutedAuction = share.substitutedAuction}
        if not FC.Queue.AddVendorAcquisition(entry.job, share.action) then
            for previous = 1, index - 1 do
                local prior = shares[previous]
                FC.Queue.RemoveAcquisition(prior.entry.job, prior.action)
            end
            return false, FC.L.acquisitionPending
        end
    end

    local authorized
    local function validate(live, units, totalCopper)
        local now = FC.InventoryAdapter.GetStatus()
        if type(live) ~= "table" or not sameVendorTerms(offer, live) or not now.reliable
            or now.source ~= stock.source or now.sourceGeneration ~= stock.sourceGeneration
            or FC.InventoryAdapter.Count(offer.itemID) ~= before or not validCount(units)
            or units <= 0 or units > quantity or units % offer.bundleSize ~= 0 then return false end
        local total = units / offer.bundleSize * offer.bundlePrice
        local money = GetMoney and GetMoney()
        if totalCopper ~= nil and totalCopper ~= total
            or batch and total > batch.funds
            or total > 0 and (not validCount(money) or money < total) then return false end
        for _, share in ipairs(shares) do
            local current = vendorShare(share.entry, {live}, automatic, share.action, share.substitutedAuction)
            if not current or current.revision ~= share.revision or current.needed ~= share.needed
                or current.quantity ~= share.quantity or current.budget ~= share.budget
                or current.issuedUnits ~= share.issuedUnits or current.issuedCopper ~= share.issuedCopper then
                return false
            end
        end
        authorized = units
        return true
    end

    local called, ok, why, issued, chunked = executeAcquisition(owner, offer, quantity, validate, batch)
    local uncertain = not called or ok and not chunked and (not authorized or issued ~= nil and issued ~= authorized)
    local remaining = (ok or uncertain) and (chunked and issued or authorized or quantity) or 0
    local receivedBefore, started = before, {}
    for _, share in ipairs(shares) do
        local entry, action = share.entry, share.action
        local units = math.min(remaining, share.quantity)
        remaining, action.dispatching = remaining - units, nil
        if units > 0 then
            action.before, action.quantity = receivedBefore, units
            receivedBefore = receivedBefore + units
            local copper = units / offer.bundleSize * offer.bundlePrice
            action.totalCopper = copper
            entry.requirement.vendorIssuedUnits = share.issuedUnits + units
            entry.requirement.vendorIssuedCopper = share.issuedCopper + copper
            if batch then batch.funds = math.max(0, batch.funds - copper) end
            started[#started + 1] = share
        else FC.Queue.RemoveAcquisition(entry.job, action) end
    end
    for _, share in ipairs(shares) do FC.Queue.FinishDeferredInvalidation(share.entry.job) end
    if uncertain then
        for _, share in ipairs(started) do markUncertain(share.entry.job, share.action) end
        return false, FC.L.acquisitionUncertain, true
    end
    if not ok then return false, why, true end
    for _, share in ipairs(started) do
        local job, action = share.entry.job, share.action
        acquisitionUpdate("issued", job, action, action.quantity, FC.L.acquisitionPending)
        inspectAcquisition(job, action)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(16, function()
            for _, share in ipairs(started) do
                inspectAcquisition(share.entry.job, share.action)
            end
        end)
    end
    return true, FC.L.acquisitionPending, true
end

function Logistics.Acquire(entry, automatic, candidates, batch, selection)
    local owner = policy()
    local allowAlternative = selection ~= nil or automatic == true and entry and entry.kind == "auction"
    if currentEntry(entry) and (entry.kind == "vendor" or allowAlternative) and canIssueVendor(entry, batch ~= nil)
        and owner and owner.GetAcquisitions and owner.ExecuteAcquisition
        and not Logistics.IsWorkflowBusy(batch ~= nil) and not (FC.Execution.IsBusy and FC.Execution.IsBusy()) then
        local shares, quantity = quoteVendorGroup(entry, candidates, owner, automatic, batch, allowAlternative)
        if shares then
            creditCarriedRequirements(entry.itemID)
            shares, quantity = quoteVendorGroup(entry, candidates, owner, automatic, batch, allowAlternative)
            if shares then return buyVendorGroup(shares, quantity, owner, automatic, batch) end
        end
    end
    return acquire(entry, automatic, selection, batch)
end

function Logistics.ResolveAcquisition(job)
    if not job or not job.acquisition then return false, FC.L.noAcquisition end
    for _, pending in ipairs(FC.Queue.Acquisitions(job)) do inspectAcquisition(job, pending) end
    if not job.acquisition then return true, FC.L.acquisitionConfirmed end
    local action = job.acquisition
    if action.status ~= "uncertain" then return false, FC.L.acquisitionPending end
    local requirement = job.requirements[action.index]
    if action.baselineInvalid then requirement.baseline = FC.InventoryAdapter.Count(requirement.itemID) end
    if action.kind == "auction" then
        requirement.auctionNeedsReplan = true
    elseif action.kind == "vendor" then
        requirement.autoBuyBlocked = true
        if action.substitutedAuction then requirement.auctionNeedsReplan = true end
    end
    FC.Queue.CloseAcquisition(job)
    return true, FC.L.acquisitionReviewed
end

local function verifiedMailboxInventory()
    local inventory = Flux and Flux.Inventory
    local mail = inventory and inventory.Mail
    if not (mail and type(mail.HasObservedInbox) == "function") then return nil, FC.L.auctionMailboxOwner end
    local generation = inventory.GetSnapshotGeneration and inventory.GetSnapshotGeneration("mail")
    if not (validCount(generation) and generation > 0 and type(mail.GetCount) == "function"
        and FC.InventoryAdapter.GetStatus().reliable) then return end
    local observed, complete = pcall(mail.HasObservedInbox)
    if not observed or complete ~= true then return end
    return inventory
end

function Logistics.MailboxStatus()
    local inventory, blocker = verifiedMailboxInventory()
    if inventory then return FC.L.diagnosticInboxVerified end
    return blocker and FC.L.diagnosticInboxUpdate or FC.L.diagnosticInboxUnverified
end

local function auctionMailbox(itemID)
    local inventory = Flux and Flux.Inventory
    local mail = inventory and inventory.Mail
    local observed = mail and mail.GetObservedCount
    local mailbox, cached
    if type(observed) == "function" then
        local ok, count, pending = pcall(observed, itemID)
        if ok and validCount(count) then
            mailbox = count
        elseif ok and validCount(pending) then
            cached = pending
        end
    end

    local verifiedInventory, blocker = verifiedMailboxInventory()
    local auction = _G.FluxAuctionRestock
    local function displayOnly()
        return mailbox or (cached and 0), math.max(mailbox or 0, cached or 0), blocker
    end
    if not (auction and auction.GetPolicyCoverage and mail and type(mail.GetCount) == "function"
        and (verifiedInventory or not blocker and type(observed) == "function" and FC.InventoryAdapter.GetStatus().reliable)) then
        return displayOnly()
    end
    local ok, providerCount = pcall(mail.GetCount, itemID)
    if not ok or not validCount(providerCount) then return displayOnly() end
    if type(observed) ~= "function" then
        -- Older FluxUI publishes predicted built-in deliveries in the same count.
        local predicted = 0
        local builtin = inventory.Builtin and inventory.Builtin.Mail
        if builtin and builtin.GetPredictedCount then
            local known, quantity = pcall(builtin.GetPredictedCount, itemID)
            if not known or not validCount(quantity) then return end
            predicted = quantity
        end
        mailbox = math.max(0, providerCount - predicted)
    end
    local known, ownerPending = pcall(auction.GetPolicyCoverage, {}, "item", itemID)
    if not known or not validCount(ownerPending) then return displayOnly() end
    -- An explicit purchase can subtract available coverage while the inbox
    -- is unverified. Only an observed count labels a delivery as collectable.
    return mailbox or 0, math.max(mailbox or 0, cached or 0, providerCount, ownerPending), nil, true,
        mailbox ~= nil and verifiedInventory ~= nil
end

local function matchedReceipt(requirement, observed, baselineKey)
    -- Both selected providers report this character's inbox in item units.
    -- A confirmed purchase can overlap the settled snapshot after a handover.
    local awaiting = math.min(requirement.auctionAwaiting or 0, requirement.remaining or requirement.quantity)
    local delta = math.max(0, observed - (requirement[baselineKey] or observed))
    return math.min(awaiting, delta)
end

local function detachedAuctionReceipts(itemID, actorKey)
    local entries = {}
    for _, job in ipairs(FC.Queue.GetJobs()) do
        -- Older closed jobs never reconciled their saved awaiting quantity. A
        -- fresh release records that the receipt is still being tracked.
        if job.characterKey == actorKey and job.auctionReceiptsReleased then
            for index, requirement in ipairs(job.requirements or {}) do
                if (requirement.auctionAwaiting or 0) > 0
                    and (not itemID or itemID == requirement.itemID) then
                    entries[#entries + 1] = {job = job, id = index, itemID = requirement.itemID, requirement = requirement}
                end
            end
        end
    end
    return entries
end

local function restockIncoming()
    local items = {}
    local actorKey, build = FC.state.characterKey, tostring(FC.state.build)
    local function addReceipt(entry)
        local itemID, quantity = entry.itemID, entry.requirement.auctionAwaiting
        if entry.job.characterKey == actorKey and entry.job.build == build
            and validCount(itemID) and itemID > 0 and validCount(quantity) and quantity > 0 then
            items[itemID] = (items[itemID] or 0) + quantity
        end
    end
    -- Planning coverage can include unrelated mail. Only paid order receipts
    -- belong to the HUD, including purchases released by cancelled work.
    for _, entry in ipairs(FC.Queue.GetRequirements()) do addReceipt(entry) end
    for _, entry in ipairs(detachedAuctionReceipts(nil, actorKey)) do addReceipt(entry) end
    return items
end

local function matchIncoming(itemID, actorKey, mailbox, pending)
    local candidates, receipts, detached = {}, {}, {}
    for _, candidate in ipairs(FC.Queue.GetRequirements()) do
        if candidate.itemID == itemID and candidate.job.characterKey == actorKey and Logistics.IsAuctionShoppingEntry(candidate) then
            local quantity = FC.Queue.AcquisitionRemaining(candidate.job, candidate.requirement)
            local known = math.min(quantity, candidate.requirement.auctionAwaiting or 0)
            local item = {entry = candidate, incoming = known, mailed = 0, observed = 0}
            item.quantity = quantity
            candidates[#candidates + 1] = item
            if known > 0 then receipts[#receipts + 1] = item end
        end
    end
    for _, entry in ipairs(detachedAuctionReceipts(itemID, actorKey)) do
        local item = {entry = entry, incoming = entry.requirement.auctionAwaiting}
        receipts[#receipts + 1] = item
        detached[#detached + 1] = item
    end
    -- Keep matching independent of the order in which jobs are displayed. Match
    -- the lowest external-inbound baseline first, then spend each observation once.
    table.sort(receipts, function(a, b)
        local left, right = a.entry, b.entry
        local first = left.requirement.auctionOwnerBaseline or math.huge
        local second = right.requirement.auctionOwnerBaseline or math.huge
        if first ~= second then return first < second end
        if left.job.id ~= right.job.id then return left.job.id < right.job.id end
        return left.id < right.id
    end)
    for _, item in ipairs(receipts) do
        local requirement = item.entry.requirement
        item.mailed = matchedReceipt(requirement, mailbox, "auctionMailboxBaseline")
        item.observed = math.max(item.mailed, matchedReceipt(requirement, pending, "auctionOwnerBaseline"))
        mailbox = mailbox - item.mailed
        pending = math.max(mailbox, pending - item.observed)
    end
    return candidates, mailbox, pending, detached
end

local function incomingByRequirement(itemID, actorKey, mailbox, pending)
    local result = {}
    local candidates, observedPool, overallPool, detached = matchIncoming(itemID, actorKey, mailbox, pending)
    -- A cancelled job does not reserve its confirmed purchase. Return these
    -- units to the shared pool after removing the provider's copy of the receipt.
    for _, receipt in ipairs(detached) do
        observedPool, overallPool = observedPool + receipt.mailed, overallPool + receipt.incoming
    end
    for _, candidate in ipairs(candidates) do
        local queued = candidate.entry
        -- A restock shortage already excludes all pre-existing owner inbound
        -- to its final target. Other queue inputs may use that inbound once.
        if not (queued.job.goal and queued.job.goal.demandId and queued.job.rootItemID == queued.itemID) then
            local incoming = math.min(overallPool, candidate.quantity - candidate.incoming)
            local mailed = math.min(observedPool, incoming)
            candidate.incoming, candidate.mailed = candidate.incoming + incoming, candidate.mailed + mailed
            overallPool, observedPool = overallPool - incoming, observedPool - mailed
        end
        result[queued.requirement] = candidate
    end
    return result, overallPool, observedPool
end

local function observeAuctionIncoming(itemID, characterKey, observations)
    local observation = observations and observations[itemID]
    if observation then return observation end
    local mailbox, pending, blocker, usable, verified = auctionMailbox(itemID)
    local matched, available, availableMail
    if mailbox ~= nil then matched, available, availableMail = incomingByRequirement(itemID, characterKey, mailbox, pending) end
    observation = {blocker = blocker, matched = matched, available = available, availableMail = availableMail,
        usable = usable, verified = verified}
    if observations then observations[itemID] = observation end
    return observation
end

-- The approved plan can contain several indivisible listings. After an outside
-- purchase or a bag gain choose only a lot from a feasible remaining subset.
local function nextAuctionLot(requirement, wanted)
    local candidates, total = {}, 0
    local filled = requirement.auctionLotsFilled or {}
    for index, lot in ipairs(requirement.auctionLots) do
        if validCount(lot.quantity) and lot.quantity > 0 and validCount(lot.total) and lot.total > 0
            and validCount(lot.count) and validCount(filled[index] or 0) then
            local count = math.max(0, lot.count - (filled[index] or 0))
            total = total + count * lot.quantity
            if count > 0 and lot.quantity <= wanted then
                candidates[#candidates + 1] = {index = index, count = count, quantity = lot.quantity}
            end
        end
    end
    if total == wanted then return candidates[1] and candidates[1].index end
    if total < wanted or wanted * #candidates > 200000 then return end
    local firstLot = {[0] = 0}
    for _, lot in ipairs(candidates) do
        local unused = {}
        for amount = 0, wanted do
            if firstLot[amount] ~= nil then
                unused[amount] = lot.count
            else
                local previous = amount - lot.quantity
                if (unused[previous] or 0) > 0 then
                    unused[amount] = unused[previous] - 1
                    firstLot[amount] = firstLot[previous] == 0 and lot.index or firstLot[previous]
                end
            end
        end
        if firstLot[wanted] then return firstLot[wanted] end
    end
end

local function auctionIntent(entry, need)
    return {jobId = entry.job.id, id = entry.id, itemID = entry.itemID, kind = "auction", quantity = need.remaining,
        planRevision = entry.job.planRevision, actorKey = entry.job.characterKey, unit = "item",
        minQuantity = need.minQuantity,
        stackSize = need.stackSize, stackMaxTotalPrice = need.stackMaxTotalPrice,
        maxUnitPrice = need.maxUnitPrice, maxTotalPrice = need.maxTotalPrice}
end

function Logistics.CanReviewAuctionPrice(entry, need)
    if not currentEntry(entry) or entry.searchOnly or entry.job.acquisition or not need or not need.mailUsable
        or not need.toBuy or need.toBuy <= 0 or need.vendorCost then return false end
    local requirement, goal = entry.requirement, entry.job.goal or {}
    return requirement.kind == "auction" and requirement.estimate == true and not requirement.auctionLots
        and not requirement.auctionNeedsReplan and not goal.demandId
end

local function vendorCosts(entry, quantity)
    if quantity <= 0 then return end
    local comparison = vendorComparison(entry, quantity)
    if not comparison then return end
    local goalCap = entry.itemID == entry.job.rootItemID and entry.job.goal and entry.job.goal.maxUnitPrice
    local unit = comparison.bundlePrice / comparison.bundleSize
    if not validAmount(goalCap) or unit <= goalCap then
        return math.ceil(quantity / comparison.bundleSize) * comparison.bundlePrice, unit, comparison.bundleSize, goalCap
    end
end

function Logistics.GetAuctionNeed(entry, quantity, observations)
    if not currentEntry(entry, observations ~= nil) or not Logistics.IsAuctionShoppingEntry(entry) then return end
    local requirement = entry.requirement
    local remaining = FC.Queue.AcquisitionRemaining(entry.job, requirement)
    if remaining <= 0 then return end
    local cap = requirement.maxUnitPrice
    if validAmount(cap) and cap > 0 then cap = math.floor(cap) else cap = nil end
    local budget = requirement.maxTotalPrice
    local auctionSpent, vendorSpent = requirement.auctionSpent or 0, requirement.vendorIssuedCopper or 0
    if validAmount(budget) and validCount(auctionSpent) and validCount(vendorSpent) then
        -- Provider estimates retain fractional copper. Authorize only whole
        -- copper at or below the accepted estimate and deduct actual receipts.
        budget = math.max(0, math.floor(budget) - auctionSpent - vendorSpent)
    else budget = nil end
    local result = {remaining = remaining, maxUnitPrice = cap, maxTotalPrice = budget, ready = false}
    local observation = observeAuctionIncoming(entry.itemID, entry.job.characterKey, observations)
    result.mailKnown = observation.verified == true
    result.mailUsable = observation.usable == true
    result.mailBlocker = observation.blocker
    local incoming = observation.matched and observation.matched[requirement]
    result.pendingMail = incoming and incoming.mailed or 0
    result.pendingIncoming = incoming and incoming.incoming or math.min(remaining, requirement.auctionAwaiting or 0)
    if not result.mailUsable then
        result.vendorCost, result.vendorUnitPrice = vendorCosts(entry, remaining)
        return result
    end
    local wanted = math.max(0, remaining - result.pendingIncoming)
    result.toBuy = restockAllowance(entry, wanted, "auction")
    result.targetLimited = result.toBuy < wanted
    local vendorCost, vendorUnit, bundleSize, goalCap = vendorCosts(entry, result.toBuy)
    result.vendorCost, result.vendorUnitPrice = vendorCost, vendorUnit
    if vendorCost and type(requirement.auctionLots) ~= "table" then
        local cheaper = vendorCost - 1
        if requirement.kind == "vendor" and budget then cheaper = math.min(cheaper, budget) end
        result.minQuantity = bundleSize == 1 and 1 or result.toBuy
        result.maxTotalPrice = cheaper
        -- With a whole replacement the aggregate cap is decisive,
        -- including when an auction stack has a fractional unit price.
        result.maxUnitPrice = bundleSize == 1 and math.floor(cheaper / result.toBuy) or cheaper
        if validAmount(goalCap) then result.maxUnitPrice = math.min(result.maxUnitPrice, math.floor(goalCap)) end
    end
    if type(requirement.auctionLots) == "table" and not result.minQuantity and result.toBuy > 0 then
        result.stackIndex = nextAuctionLot(requirement, result.toBuy)
        local lot = result.stackIndex and requirement.auctionLots[result.stackIndex]
        if not lot then
            result.lotBlocked = true
            result.reason = "lotsChanged"
            return result
        end
        result.stackSize, result.stackMaxTotalPrice = lot.quantity, lot.total
    end
    local review = liveAuctionReview
    if review and review.job == entry.job and review.requirement == requirement
        and review.revision == entry.job.planRevision and Logistics.CanReviewAuctionPrice(entry, result) then
        local available = GetMoney and GetMoney()
        if validCount(available) and available > 0 then
            result.livePrice = true
            result.maxUnitPrice, result.maxTotalPrice = available, available
        end
    end
    local auction = _G.FluxAuctionRestock
    if not observations and auction and auction.GetLogisticsState and (result.maxUnitPrice or 0) > 0
        and (result.maxTotalPrice or 0) > 0 then
        local wanted = validCount(quantity) and math.min(quantity, result.toBuy) or result.toBuy
        if wanted > 0 then
            local phase, reason, quote = auction.GetLogisticsState(auctionIntent(entry, result), wanted)
            result.phase, result.reason, result.quote = phase, reason, quote
        end
        result.ready = result.phase == "ready"
    end
    return result
end

function Logistics.GetAuctionNeeds(entries)
    local result, observations = {}, {}
    for _, entry in ipairs(entries) do
        if entry.job then
            result[entry] = Logistics.GetAuctionNeed(entry, nil, observations)
        elseif entry.searchOnly and validCount(entry.quantity) and entry.quantity > 0 then
            local observation = observeAuctionIncoming(entry.itemID, FC.state.characterKey, observations)
            if observation.available ~= nil then
                local incoming = math.min(observation.available, entry.quantity)
                local mailed = math.min(observation.availableMail, incoming)
                observation.available, observation.availableMail = observation.available - incoming, observation.availableMail - mailed
                result[entry] = {pendingIncoming = incoming, pendingMail = mailed, toBuy = entry.quantity - incoming}
            end
        end
    end
    return result
end

function Logistics.GetAuctionSearchQuantity(entry, need)
    local incoming = need and need.pendingIncoming or entry.requirement.auctionAwaiting or 0
    return need and (need.toBuy or math.max(0, need.remaining - incoming)) or math.max(0, entry.quantity - incoming)
end

-- Price observations decide which shortages belong in Shopping. An estimate
-- can surface a row, but only the live owner quote can authorize a purchase.
function Logistics.GetAuctionShoppingEntries(preferred, compareVendors)
    local entries = FC.Queue.GetRequirements()
    local needs = Logistics.GetAuctionNeeds(entries)
    local candidates, items, seen = {}, {}, {}
    for _, entry in ipairs(entries) do
        if Logistics.IsAuctionShoppingEntry(entry) or compareVendors and entry.kind == "vendor" then
            local requirement, need = entry.requirement, needs[entry]
            local action = entry.job.acquisition
            local pending = (requirement.auctionAwaiting or 0) > 0 or need and (need.pendingIncoming or 0) > 0
                or action and action.kind == "auction" and action.index == entry.id
            local selected = preferred and entry.job == preferred.job and entry.id == preferred.id
            local vendorCost = not (compareVendors or selected or pending) and need and need.vendorCost
            candidates[#candidates + 1] = {entry = entry, vendorCost = vendorCost}
            if vendorCost and not seen[entry.itemID] then
                seen[entry.itemID] = true
                items[#items + 1] = entry.itemID
            end
        end
    end
    local quotes, depth = {}, {}
    if #items > 0 then
        local provider, settings = FC.MarketAdapter or FC.AuctionatorAdapter, Logistics.GetSettings()
        if provider then quotes = provider.QuoteItems(items, nil, settings.provider, settings.allowFallback) or {} end
        local now = marketTime()
        for _, id in ipairs(items) do depth[id] = observedAuctionBook(id, now) end
    end
    local shopping = {}
    for _, candidate in ipairs(candidates) do
        local entry, vendorCost = candidate.entry, candidate.vendorCost
        local keep = not vendorCost
        local quantity = Logistics.GetAuctionSearchQuantity(entry, needs[entry])
        if vendorCost and quantity > 0 then
            local auctionCost, _, evidence = FC.Planner.DirectCost(quotes, entry.itemID, quantity, depth)
            keep = auctionCost and auctionCost < vendorCost
                or not auctionCost and not (evidence and evidence.complete) and entry.kind ~= "vendor"
        end
        if keep then shopping[#shopping + 1] = entry end
    end
    return shopping, needs
end

function Logistics.GetAuctionShoppingRequirements()
    local entries, needs = Logistics.GetAuctionShoppingEntries()
    local shopping = {}
    for _, entry in ipairs(entries) do
        local quantity = Logistics.GetAuctionSearchQuantity(entry, needs[entry])
        if quantity > 0 then
            entry.quantity = quantity
            shopping[#shopping + 1] = entry
        end
    end
    return shopping
end

local function groupedAuction(entries, needs)
    needs = needs or Logistics.GetAuctionNeeds(entries)
    local candidates = {}
    for _, entry in ipairs(entries) do
        local need, req = needs[entry], entry.requirement
        if currentEntry(entry) and entry.job.rootRecipeId and not FC.Queue.IsClearing(entry.job) and not entry.searchOnly
            and req.kind == "auction" and not entry.job.acquisition
            and not directRestockGoal(entry) and not req.auctionNeedsReplan
            and need and need.mailUsable and not need.livePrice and not need.lotBlocked
            and not need.vendorCost and not need.minQuantity
            and validCount(need.toBuy) and need.toBuy > 0 and validCount(need.maxUnitPrice)
            and validCount(need.maxTotalPrice) then
            local quantity = need.stackSize or need.toBuy
            local total = math.min(need.maxTotalPrice, need.stackMaxTotalPrice or math.huge)
            local cap = math.min(need.maxUnitPrice, math.floor(total / quantity))
            if cap > 0 then
                candidates[#candidates + 1] = {entry = entry, need = need, cap = cap, quantity = quantity}
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.entry.job.id ~= b.entry.job.id then return a.entry.job.id < b.entry.job.id end
        return a.entry.id < b.entry.id
    end)

    local groups, byItem = {}, {}
    for _, candidate in ipairs(candidates) do
        local entry = candidate.entry
        local group = byItem[entry.itemID]
        if not group then
            group = {shares = {}, jobs = {}}
            groups[#groups + 1], byItem[entry.itemID] = group, group
        end
        -- Each accepted job can hold one live acquisition. Recipes and final
        -- outputs can differ as long as the shared material is the same SKU.
        if not group.jobs[entry.job] then
            group.jobs[entry.job] = true
            group.shares[#group.shares + 1] = candidate
        end
    end
    for _, group in ipairs(groups) do
        local shares = group.shares
        if #shares > 1 then
            local leader = shares[1].entry
            local quantity, remaining, incoming, limit, revisions = 0, 0, 0, math.huge, {}
            local wholeStack, verified = nil, true
            for _, share in ipairs(shares) do
                local entry, need = share.entry, share.need
                quantity, remaining = quantity + share.quantity, remaining + need.toBuy
                incoming = incoming + need.pendingIncoming
                limit = math.min(limit, share.cap)
                verified = verified and need.mailKnown
                if need.stackSize then wholeStack = true end
                revisions[#revisions + 1] = ("%d/%d/%q/%d/%d/%d/%d/%d/%d"):format(entry.job.id, entry.id,
                    tostring(entry.job.planRevision), need.toBuy, need.maxUnitPrice, need.maxTotalPrice,
                    need.stackIndex or 0, need.stackSize or 0, need.stackMaxTotalPrice or 0)
            end
            if not validCount(quantity * limit) then return end
            local need = {entry = leader, remaining = remaining, toBuy = quantity, pendingIncoming = incoming,
                mailKnown = verified, mailUsable = true, maxUnitPrice = limit, maxTotalPrice = quantity * limit, ready = false,
                groupRevision = table.concat(revisions, "|")}
            if wholeStack then
                -- Each split must still fund one compatible accepted whole
                -- lot. A smaller combined listing would break that approval.
                need.stackSize, need.stackMaxTotalPrice = quantity, need.maxTotalPrice
            end
            local request = auctionIntent(leader, need)
            request.groupRevision = need.groupRevision
            return need, request, shares
        end
    end
end

local function groupedAuctionState(need, request)
    local auction = _G.FluxAuctionRestock
    if auction and auction.GetLogisticsState then
        need.phase, need.reason, need.quote = auction.GetLogisticsState(request, need.toBuy)
        need.ready = need.phase == "ready" and need.quote ~= nil
    end
    return need
end

function Logistics.GetGroupedAuctionNeed(entries, needs)
    local need, request = groupedAuction(entries or {}, needs)
    return need and groupedAuctionState(need, request)
end

local function restockAuctionRows()
    local entries, needs = Logistics.GetAuctionShoppingEntries()
    local rows, byItem, displayed = {}, {}, {}
    for _, entry in ipairs(entries) do
        local members = byItem[entry.itemID] or {}
        byItem[entry.itemID], members[#members + 1] = members, entry
    end
    for _, members in pairs(byItem) do
        if #members > 1 then
            local group, request, shares = groupedAuction(members, needs)
            if group then
                groupedAuctionState(group, request)
                if group.reason ~= "noOffer" and group.reason ~= "overCap" then
                    for _, share in ipairs(shares) do displayed[share.entry] = group end
                end
            end
        end
    end
    for _, entry in ipairs(entries) do
        local group = displayed[entry]
        if not group or entry == group.entry then
            local need = needs[entry]
            local quantity = group and group.remaining or Logistics.GetAuctionSearchQuantity(entry, need)
            local incoming = group and group.pendingIncoming or need and need.pendingIncoming or entry.requirement.auctionAwaiting or 0
            if quantity > 0 or incoming > 0 then
                rows[#rows + 1] = {itemID = entry.itemID, quantity = quantity, incoming = incoming,
                    jobId = entry.job.id, id = entry.id, planRevision = entry.job.planRevision,
                    groupRevision = group and group.groupRevision,
                    price = group and group.maxUnitPrice or entry.requirement.unitPrice or entry.requirement.maxUnitPrice}
            end
        end
    end
    return rows
end

creditCarriedRequirements = function(itemID)
    local entries, counts, creditedReceipts = {}, {}, {}
    local function observe(entry)
        local id, requirement = entry.itemID, entry.requirement
        if counts[id] == nil then counts[id] = FC.InventoryAdapter.Count(id) or false end
        local count = counts[id]
        if count and (not requirement.baseline or count < requirement.baseline) then requirement.baseline = count end
    end
    for _, entry in ipairs(FC.Queue.GetRequirements()) do
        if not itemID or entry.itemID == itemID then
            observe(entry)
            entries[#entries + 1] = entry
        end
    end
    local detached = detachedAuctionReceipts(itemID, FC.state.characterKey)
    for _, entry in ipairs(detached) do observe(entry) end
    local function credit(entry, limit)
        local count, requirement = counts[entry.itemID], entry.requirement
        if count and requirement.baseline and count > requirement.baseline then
            return FC.Queue.CreditAcquisition(entry.job, entry.id, math.min(limit, count - requirement.baseline), count)
        end
        return 0
    end
    -- A bag gain goes to an order's acknowledged purchase before other jobs
    -- can use it as newly available stock.
    for _, entry in ipairs(entries) do
        local awaiting = entry.requirement.auctionAwaiting or 0
        if awaiting > 0 then
            local id = entry.itemID
            creditedReceipts[id] = (creditedReceipts[id] or 0) + credit(entry, awaiting)
        end
    end
    local detachedSettled = false
    for _, entry in ipairs(detached) do
        local id, requirement = entry.itemID, entry.requirement
        local count, credited = counts[id], creditedReceipts[id] or 0
        if count then
            local gain = math.max(0, count - (requirement.baseline or count) - credited)
            local arrived = math.min(requirement.auctionAwaiting, gain)
            requirement.auctionAwaiting = requirement.auctionAwaiting - arrived
            creditedReceipts[id] = credited + arrived
            if arrived > 0 then detachedSettled = true end
        end
    end
    for _, entry in ipairs(detached) do
        local count, requirement = counts[entry.itemID], entry.requirement
        if count then
            requirement.baseline = math.min(count, (requirement.baseline or count) + (creditedReceipts[entry.itemID] or 0))
        end
    end
    for _, entry in ipairs(entries) do
        local job, action = entry.job, entry.job.acquisition
        local restock = job.goal and job.goal.demandId and job.rootItemID == entry.itemID
        local demand = restock and not action and directRestockGoal(entry) and Logistics.GetDemand(job.goal.demandId)
        -- Existing inbox and bank coverage could become carried stock after
        -- acceptance. Such a transfer alone cannot satisfy another commitment.
        -- Once the destination meets the whole target, observed unclaimed bag
        -- gains can close its remaining direct order without another purchase.
        if (not action or action.kind == "auction" or canIssueVendor(entry, true)) and (not restock or demand
            and eligibleForRestock(demand, entry.itemID)
            and destinationStock(demand, entry.itemID, counts[entry.itemID]) >= demand.target) then
            local needed = FC.Queue.AcquisitionRemaining(job, entry.requirement)
            if needed > 0 then credit(entry, needed) end
        end
    end
    if detachedSettled then FC:Emit("QUEUE_CHANGED") end
end

local function creditAuctionReceipt(entry, action, quantity, totalCopper)
    local job, req = entry.job, entry.requirement
    if not req.auctionAwaiting or req.auctionAwaiting == 0 then
        req.auctionOwnerBaseline, req.auctionMailboxBaseline = action.ownerPendingBefore, action.mailboxBefore
    else
        req.auctionOwnerBaseline = math.min(req.auctionOwnerBaseline or action.ownerPendingBefore, action.ownerPendingBefore)
        req.auctionMailboxBaseline = math.min(req.auctionMailboxBaseline or action.mailboxBefore, action.mailboxBefore)
    end
    req.auctionAwaiting = (req.auctionAwaiting or 0) + quantity
    req.auctionSpent = (req.auctionSpent or 0) + totalCopper
    Logistics.InvalidateAuctionDepth(entry.itemID)
    if action.stackIndex then
        req.auctionLotsFilled = req.auctionLotsFilled or {}
        req.auctionLotsFilled[action.stackIndex] = (req.auctionLotsFilled[action.stackIndex] or 0) + 1
    end
    action.status, job.lastAcquisition, job.acquisition = "confirmed", action, nil
end

local function auctionAction(entry, quantity, prepareOnly, explicit, reviewPrice, shownOffer)
    if not currentEntry(entry) or not Logistics.IsAuctionShoppingEntry(entry) then return false, FC.L.alreadyCovered end
    if entry.job.acquisition then return false, FC.L.acquisitionPending end
    if Logistics.IsWorkflowBusy() or FC.Execution.IsBusy and FC.Execution.IsBusy() then
        return false, FC.L.workflowBusy
    end
    local auction = _G.FluxAuctionRestock
    local execute = auction and (prepareOnly and auction.PrepareLogistics or not prepareOnly and auction.ExecuteLogistics)
    if not execute then return false, FC.L.acquireManually end
    if not prepareOnly then creditCarriedRequirements(entry.itemID) end
    local need = Logistics.GetAuctionNeed(entry)
    if not need then return false, FC.L.alreadyCovered end
    if not need.mailUsable then return false, need.mailBlocker or FC.L.auctionMailboxUnknown end
    if reviewPrice then
        if not explicit or not Logistics.CanReviewAuctionPrice(entry, need) then return false, FC.L.offerChanged end
        local money = GetMoney and GetMoney()
        if not validCount(money) or money <= 0 then return false, "money" end
        liveAuctionReview = {job = entry.job, requirement = entry.requirement, revision = entry.job.planRevision}
        need = Logistics.GetAuctionNeed(entry)
    end
    if need.lotBlocked then return false, "lotsChanged" end
    if (entry.requirement.kind ~= "auction" and entry.requirement.kind ~= "vendor") or not need.maxUnitPrice or need.maxUnitPrice <= 0
        or not need.maxTotalPrice or need.maxTotalPrice <= 0
        or entry.requirement.auctionNeedsReplan then return false, FC.L.auctionCapUnknown or FC.L.offerChanged end
    if not validCount(quantity) or quantity <= 0 then return false, FC.L.quantityError end
    quantity = math.min(quantity, need.toBuy)
    if quantity <= 0 then return false, FC.L.alreadyCovered end
    if quantity < (need.stackSize or need.minQuantity or 1) then return false, FC.L.quantityError end
    local approvedOffer
    if prepareOnly and need.livePrice then
        approvedOffer = need.quote
    elseif need.livePrice then
        local latest = need.quote
        if not latest or not shownOffer or shownOffer.quantity ~= latest.quantity
            or shownOffer.totalCopper ~= latest.totalCopper then return false, "changed" end
        approvedOffer = {quantity = latest.quantity, totalCopper = latest.totalCopper}
    end
    local job = entry.job
    local request = auctionIntent(entry, need)
    local action = {kind = "auction", index = entry.id, quantity = quantity, startedAt = readClock(),
        addonVersion = FC.version, clientBuild = FC.state.clientBuild,
        status = "issued", credited = 0, stackIndex = need.stackIndex, source = FC.InventoryAdapter.GetStatus().source}
    local function sameReference(other)
        return other and other.jobId == request.jobId and other.id == request.id and other.itemID == request.itemID
            and other.planRevision == request.planRevision
    end
    local function authorize(live, units, totalCopper)
        if not (currentEntry(entry) and sameReference(live) and not job.acquisition and not acquiring()
            and not (FC.Execution.IsBusy and FC.Execution.IsBusy())
            and job.planRevision == request.planRevision
            and FC.InventoryAdapter.GetStatus().source == action.source
            and validCount(units) and units > 0 and units <= quantity) then return false end
        local current = Logistics.GetAuctionNeed(entry)
        if not current or not current.mailUsable or current.lotBlocked or units > current.toBuy
            or current.maxUnitPrice ~= request.maxUnitPrice or current.maxTotalPrice ~= request.maxTotalPrice
            or current.minQuantity ~= request.minQuantity or units < (current.minQuantity or 1)
            or current.stackIndex ~= action.stackIndex or current.stackSize ~= request.stackSize
            or current.stackMaxTotalPrice ~= request.stackMaxTotalPrice then return false end
        if totalCopper == nil then return true end
        if current.stackSize and (units ~= current.stackSize or totalCopper > current.stackMaxTotalPrice) then return false end
        if approvedOffer and (units ~= approvedOffer.quantity or totalCopper > approvedOffer.totalCopper) then return false end
        local money = GetMoney and GetMoney()
        if not validCount(totalCopper) or totalCopper > current.maxTotalPrice
            or totalCopper > units * current.maxUnitPrice or not validCount(money) or totalCopper > money then return false end
        local mailbox, pending, _, usable = auctionMailbox(entry.itemID)
        if not usable then return false end
        -- A later purchase's baseline must exclude matching stock from earlier
        -- purchases. Collecting an earlier delivery leaves that baseline intact.
        local _, externalMail, externalPending = matchIncoming(entry.itemID, job.characterKey, mailbox, pending)
        action.mailboxBefore, action.ownerPendingBefore = externalMail, externalPending
        action.authorized = {quantity = units, totalCopper = totalCopper}
        return true
    end
    local function observe(event, receipt)
        if not receipt or not sameReference(receipt) then return end
        if event == "state" then
            if prepareOnly and need.livePrice and receipt.phase == "ready" then
                local latest = Logistics.GetAuctionNeed(entry)
                approvedOffer = latest and latest.quote
            end
            local message = receipt.reason or receipt.phase
            FC:Emit("ACQUISITION_CHANGED", "auctionState", entry, nil, FC.L.auctionFeedback[message])
            return
        end
        if event == "submitted" then
            if not currentEntry(entry) or job.acquisition then return end
            local approved = action.authorized
            job.acquisition = action
            if not approved or not validCount(receipt.attemptID) or receipt.attemptID <= 0
                or receipt.quantity ~= approved.quantity or receipt.totalCopper ~= approved.totalCopper then
                markUncertain(job, action)
                return
            end
            action.attemptID, action.quantity = receipt.attemptID, receipt.quantity
            acquisitionUpdate("issued", job, action, action.quantity, FC.L.acquisitionPending)
            return
        end
        if job.acquisition ~= action or action.status ~= "issued" or receipt.attemptID ~= action.attemptID then return end
        if event == "confirmed" and action.authorized and receipt.quantity == action.authorized.quantity
            and receipt.totalCopper == action.authorized.totalCopper then
            creditAuctionReceipt(entry, action, receipt.quantity, receipt.totalCopper)
            if not FC.Queue.FinishDeferredInvalidation(job) then FC:Emit("QUEUE_CHANGED") end
            acquisitionUpdate("auctionPurchased", job, action, receipt.quantity, FC.L.auctionPurchased or FC.L.acquisitionConfirmed)
        elseif event == "failed" then
            action.status, job.lastAcquisition, job.acquisition = "failed", action, nil
            FC.Queue.FinishDeferredInvalidation(job)
            acquisitionUpdate("blocked", job, action, 0, receipt.reason or FC.L.offerChanged)
        else
            markUncertain(job, action)
        end
    end
    if prepareOnly then return execute(request, quantity, authorize, observe, explicit == true) end
    return execute(request, quantity, authorize, observe)
end

function Logistics.PrepareAuction(entry, quantity, explicit, reviewPrice)
    return auctionAction(entry, quantity, true, explicit, reviewPrice)
end

function Logistics.BuyAuction(entry, quantity, shownOffer)
    return auctionAction(entry, quantity, false, nil, nil, shownOffer)
end

local function splitGroupedPurchase(shares, quantity, totalCopper, mailbox, pending, source)
    local actions, units, paid = {}, 0, 0
    for _, share in ipairs(shares) do
        local entry, need = share.entry, share.need
        local take = math.min(quantity - units, share.quantity)
        if take <= 0 then break end
        units = units + take
        -- Apportion the one real price across the approved shares. The final
        -- share receives any rounding remainder, so no copper is created or lost.
        local cumulative = units == quantity and totalCopper or math.floor(totalCopper * units / quantity)
        local copper = cumulative - paid
        if not validCount(copper) or copper > take * need.maxUnitPrice or copper > need.maxTotalPrice
            or need.stackSize and (take ~= need.stackSize or copper > need.stackMaxTotalPrice) then return end
        paid = cumulative
        actions[#actions + 1] = {entry = entry, action = {kind = "auction", index = entry.id,
            quantity = take, totalCopper = copper, startedAt = readClock(), status = "issued", credited = 0,
            addonVersion = FC.version, clientBuild = FC.state.clientBuild, source = source,
            mailboxBefore = mailbox, ownerPendingBefore = pending, stackIndex = need.stackIndex}}
    end
    if units == quantity and paid == totalCopper then return actions end
end

local function runGroupedAuction(entries, prepareOnly, explicit, shownOffer)
    if Logistics.IsWorkflowBusy() or FC.Execution.IsBusy and FC.Execution.IsBusy() then return false, FC.L.workflowBusy end
    local auction = _G.FluxAuctionRestock
    local run = auction and (prepareOnly and auction.PrepareLogistics or not prepareOnly and auction.ExecuteLogistics)
    if not run then return false, FC.L.acquireManually end
    local need, request, shares = groupedAuction(entries or {})
    if not need then return false, FC.L.offerChanged end
    if not prepareOnly then
        local revision = need.groupRevision
        creditCarriedRequirements(request.itemID)
        need, request, shares = groupedAuction(entries)
        if not need or need.groupRevision ~= revision then return false, FC.L.offerChanged end
        groupedAuctionState(need, request)
        if not need.ready or not shownOffer or shownOffer.quantity ~= need.quote.quantity
            or shownOffer.totalCopper ~= need.quote.totalCopper then return false, "changed" end
    end
    local status = FC.InventoryAdapter.GetStatus()
    local approved, published
    local function sameReference(other)
        return other and other.jobId == request.jobId and other.id == request.id and other.itemID == request.itemID
            and other.planRevision == request.planRevision
            and (other.groupRevision == nil or other.groupRevision == request.groupRevision)
    end
    local function authorize(other, quantity, totalCopper)
        local currentStatus = FC.InventoryAdapter.GetStatus()
        if not sameReference(other) or acquiring() or FC.Execution.IsBusy and FC.Execution.IsBusy()
            or not currentStatus.reliable or currentStatus.source ~= status.source
            or currentStatus.sourceGeneration ~= status.sourceGeneration
            or not validCount(quantity) or quantity <= 0 or quantity > need.toBuy
            or need.stackSize and quantity ~= need.stackSize then return false end
        local current = groupedAuction(entries)
        if not current or current.groupRevision ~= need.groupRevision then return false end
        if totalCopper == nil then return true end
        local money = GetMoney and GetMoney()
        if not validCount(totalCopper) or totalCopper <= 0 or totalCopper > need.maxTotalPrice
            or totalCopper > quantity * need.maxUnitPrice or not validCount(money) or totalCopper > money
            or shownOffer and (quantity ~= shownOffer.quantity or totalCopper > shownOffer.totalCopper) then
            return false
        end
        local mailbox, pending, _, usable = auctionMailbox(request.itemID)
        if not usable then return false end
        local _, externalMail, externalPending = matchIncoming(request.itemID, request.actorKey, mailbox, pending)
        local actions = splitGroupedPurchase(shares, quantity, totalCopper, externalMail, externalPending, status.source)
        if not actions then return false end
        approved = {quantity = quantity, totalCopper = totalCopper, actions = actions}
        return true
    end
    local function notifyMembers(actions, state, reason)
        for _, member in ipairs(actions) do
            acquisitionUpdate(state, member.entry.job, member.action, member.action.quantity, reason)
        end
    end
    local function uncertain(actions)
        for _, member in ipairs(actions) do
            if member.entry.job.acquisition == member.action then member.action.status = "uncertain" end
        end
        notifyMembers(actions, "uncertain", FC.L.acquisitionUncertain)
    end
    local function observe(event, receipt)
        if not sameReference(receipt) then return end
        if event == "state" then
            FC:Emit("ACQUISITION_CHANGED", "auctionState", need.entry, nil,
                FC.L.auctionFeedback[receipt.reason or receipt.phase], need.groupRevision)
            return
        end
        if event == "submitted" then
            if published or not approved then return end
            published = approved
            local attached = true
            for _, member in ipairs(published.actions) do
                local job = member.entry.job
                if currentEntry(member.entry) and not job.acquisition then
                    job.acquisition = member.action
                    member.action.attemptID = receipt.attemptID
                else
                    attached = false
                end
            end
            if not attached or not validCount(receipt.attemptID) or receipt.attemptID <= 0
                or receipt.quantity ~= published.quantity or receipt.totalCopper ~= published.totalCopper then
                published.invalid = true
                uncertain(published.actions)
            else
                published.attemptID = receipt.attemptID
                notifyMembers(published.actions, "issued", FC.L.acquisitionPending)
            end
            return
        end
        local purchase = published
        if not purchase or purchase.invalid or receipt.attemptID ~= purchase.attemptID then return end
        published = nil
        for _, member in ipairs(purchase.actions) do
            if member.entry.job.acquisition ~= member.action or member.action.status ~= "issued" then
                uncertain(purchase.actions)
                return
            end
        end
        if event == "confirmed" and receipt.quantity == purchase.quantity and receipt.totalCopper == purchase.totalCopper then
            for _, member in ipairs(purchase.actions) do
                local action = member.action
                creditAuctionReceipt(member.entry, action, action.quantity, action.totalCopper)
            end
            for _, member in ipairs(purchase.actions) do FC.Queue.FinishDeferredInvalidation(member.entry.job) end
            FC:Emit("QUEUE_CHANGED")
            notifyMembers(purchase.actions, "auctionPurchased", FC.L.auctionPurchased or FC.L.acquisitionConfirmed)
        elseif event == "failed" then
            for _, member in ipairs(purchase.actions) do
                local job, action = member.entry.job, member.action
                action.status, job.lastAcquisition, job.acquisition = "failed", action, nil
            end
            for _, member in ipairs(purchase.actions) do FC.Queue.FinishDeferredInvalidation(member.entry.job) end
            notifyMembers(purchase.actions, "blocked", receipt.reason or FC.L.offerChanged)
        else
            uncertain(purchase.actions)
        end
    end
    if prepareOnly then return run(request, need.toBuy, authorize, observe, explicit == true) end
    return run(request, need.toBuy, authorize, observe)
end

function Logistics.PrepareGroupedAuction(entries, explicit)
    return runGroupedAuction(entries, true, explicit)
end

function Logistics.BuyGroupedAuction(entries, shownOffer)
    return runGroupedAuction(entries, false, nil, shownOffer)
end

local function coverageWithOwner(demand, ownerQuantity, ownerItemID)
    local rows = FC.Queue.Coverage(demand)
    local observedItem = ownerItemID or demand.itemID
    if not validCount(ownerQuantity) or not validCount(observedItem) or observedItem == 0
        or not eligibleForRestock(demand, observedItem) then return rows end
    local matches, _, _, detached = matchIncoming(observedItem, demand.actorKey or FC.state.characterKey, 0, ownerQuantity)
    local overlaps = {}
    for _, match in ipairs(matches) do
        local entry = match.entry
        local job = entry.job
        if job.goal and job.goal.demandId == demand.id and job.rootItemID == observedItem then
            local rowID = "FluxLogistics/" .. job.id
            overlaps[rowID] = (overlaps[rowID] or 0) + math.min(entry.requirement.goalQuantity or 0, match.observed)
        end
    end
    for _, row in ipairs(rows) do row.quantity = math.max(0, row.quantity - (overlaps[row.id] or 0)) end
    for _, receipt in ipairs(detached) do
        local entry = receipt.entry
        local job = entry.job
        local outstanding = math.max(0, math.min(entry.requirement.goalQuantity or 0, receipt.incoming) - receipt.observed)
        if outstanding > 0 and job.goal and job.goal.demandId == demand.id and job.rootItemID == observedItem then
            rows[#rows + 1] = {id = "FluxLogistics/auction/" .. job.id .. "/" .. entry.id, quantity = outstanding}
        end
    end
    return rows
end

local refreshAuctionRestock

local function merchantOpen()
    local inventory = Flux and Flux.Inventory
    if inventory and inventory.IsMerchantOpen then return inventory.IsMerchantOpen() == true end
    return MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown() == true or false
end

local vendorScheduled, merchantVisitOpen, vendorPass
local declinedVendor = {}
local reportedVendor = {}
local scheduleVendor, runVendorPass, startVendorPass
local VENDOR_RETRIES = 20
local VENDOR_FRAME_RETRIES = 3

local function retryVendor(retries, workflowBusy)
    if retries <= 0 then return end
    -- The owner's merchant startup can hold the workflow for a few frames.
    local delay = workflowBusy and retries > VENDOR_RETRIES - VENDOR_FRAME_RETRIES and 0 or 0.15
    scheduleVendor(delay, retries - 1)
end

local function vendorWorkflowBlocked(retries, allowPendingVendor)
    if FC.Execution.IsBusy and FC.Execution.IsBusy()
        or InCombatLockdown and InCombatLockdown() or GetCursorInfo and GetCursorInfo() then
        retryVendor(retries, false)
        return true
    end
    if Logistics.IsWorkflowBusy(allowPendingVendor) then
        retryVendor(retries, true)
        return true
    end
end

local function hasAutomaticVendorNeed()
    for _, entry in ipairs(FC.Queue.GetRequirements()) do
        if currentEntry(entry) and canIssueVendor(entry, true) and not declinedVendor[entry.requirement]
            and (entry.kind == "vendor" or canUseVendorForAuction(entry))
            and acceptedVendor(entry.job, entry.requirement) then return true end
    end
    return false
end

local function runVendorPurchases(retries)
    if not merchantOpen() or Logistics.GetSettings().autoBuyVendor == false then return end
    local blockedItems, blockedDemands = vendorReceiptBlocks()
    if not blockedItems then return end
    local queued, alternatives = {}, {}
    for _, entry in ipairs(FC.Queue.GetRequirements()) do
        local job = entry.job
        local demandID = job.goal and job.goal.demandId
        -- Unresolved receipts can affect other jobs covering the same stock.
        if not job.acquisition and not blockedItems[entry.itemID] and not blockedDemands[demandID]
            and currentEntry(entry) and acceptedVendor(job, entry.requirement) and not declinedVendor[entry.requirement] then
            if entry.kind == "vendor" then
                queued[#queued + 1] = entry
            elseif canUseVendorForAuction(entry) then
                alternatives[#alternatives + 1] = entry
            end
        end
    end
    for _, entry in ipairs(alternatives) do queued[#queued + 1] = entry end
    if #queued == 0 then return end
    if vendorWorkflowBlocked(retries) then return end
    for _, entry in ipairs(queued) do
        local ok, message, attempted = Logistics.Acquire(entry, true, queued)
        if ok or entry.job.acquisition then return end
        if attempted then declinedVendor[entry.requirement] = true end
        if (attempted or message == FC.L.offerChanged) and not reportedVendor[entry.requirement] then
            reportedVendor[entry.requirement] = true
            FC:Emit("ACQUISITION_CHANGED", "blocked", entry, 0, message)
        end
    end
end

scheduleVendor = function(delay, retries, prepareIndex)
    if not C_Timer or not C_Timer.After or not (prepareIndex or merchantOpen()) then return end
    delay = delay or 0
    if vendorScheduled and (vendorScheduled.delay == 0 or delay > 0) then
        if prepareIndex then vendorScheduled.prepareIndex = true end
        return
    end
    local scheduled = {delay = delay, prepareIndex = prepareIndex}
    vendorScheduled = scheduled
    C_Timer.After(delay, function()
        if vendorScheduled ~= scheduled then return end
        vendorScheduled = nil
        if not merchantOpen() then return end
        merchantVisitOpen = true
        local remaining = retries or VENDOR_RETRIES
        local automaticNeed = (scheduled.prepareIndex or not vendorPass) and hasAutomaticVendorNeed()
        if scheduled.prepareIndex and automaticNeed then
            local vendor = _G.FluxVendorAuto
            local ensureIndex = vendor and (vendor.EnsureMerchantIndex or vendor.GetMerchantItemIndex)
            local slots = ensureIndex and GetMerchantNumItems and GetMerchantNumItems()
            -- Leave a merchant whose slots have not loaded to FluxUI's update pipeline.
            if validCount(slots) and slots > 0 then ensureIndex(false) end
        end
        if vendorPass then
            runVendorPass(vendorPass, remaining)
        elseif automaticNeed then
            local owner = policy()
            if owner and owner.BuyVendorRequirements then startVendorPass(true, remaining)
            else runVendorPurchases(remaining) end
        end
    end)
end

local function closeVendorVisit()
    merchantVisitOpen, vendorScheduled, vendorPass = false, nil, nil
    declinedVendor, reportedVendor = {}, {}
    for _, job in ipairs(FC.Queue.GetJobs()) do
        for _, action in ipairs(FC.Queue.Acquisitions(job)) do
            if action.status == "issued" and action.kind == "vendor" then
                inspectAcquisition(job, action)
                markUncertain(job, action)
            end
        end
    end
end

local function merchantChanged()
    if refreshAuctionRestock then refreshAuctionRestock() end
    if merchantOpen() then
        scheduleVendor()
    elseif merchantVisitOpen then
        closeVendorVisit()
    end
end

local function groupBankRequirements(rows)
    local result, groups = {}, {}
    for _, row in ipairs(rows) do
        local offer, entry = row.offer, row.entry
        local groupKey = row.pending and ("pending:" .. row.itemID)
            or offer and not directRestockGoal(entry) and offer.offerId
        local group = groupKey and groups[groupKey]
        if group and not group.jobs[row.job] then
            group.members[#group.members + 1] = row
            group.jobs[row.job] = true
            group.quantity = group.quantity + row.quantity
        elseif not group and groupKey then
            -- Preserve the queue position of the first qualified share.
            group = {kind = "bank", job = row.job, id = row.id, itemID = row.itemID, quantity = row.quantity,
                pending = row.pending, offer = offer, entry = entry, members = {row}, jobs = {[row.job] = true}}
            result[#result + 1], groups[groupKey] = group, group
        else
            result[#result + 1] = row
        end
    end
    for _, row in ipairs(result) do
        if row.members and #row.members > 1 then
            local stamp = {tostring(row.offer and row.offer.offerId), tostring(row.offer and row.offer.revision)}
            for _, member in ipairs(row.members) do
                stamp[#stamp + 1] = ("%d/%d/%q/%d"):format(member.job.id, member.id,
                    tostring(member.job.planRevision), member.quantity)
            end
            row.groupKey, row.groupCount = table.concat(stamp, "|"), #row.members
        else
            row.members = nil
        end
        row.jobs = nil
    end
    return result
end

local function bankRequirements()
    local owner = policy()
    if not owner or not owner.GetAcquisitions then return {} end
    local entries = FC.Queue.GetRequirements()
    local reserved, matching, alternatives, offers, result = {}, {}, {}, {}, {}
    local matched, blocked = {}, {}
    for _, entry in ipairs(entries) do
        local list = entry.kind == "bank" and matching or alternatives
        list[#list + 1] = entry
        local bankReserved = entry.kind == "bank" and restockAllowance(entry, entry.quantity, "bank") or 0
        local action = entry.job.acquisition
        if currentEntry(entry) and action and action.index == entry.id and action.status == "uncertain" then
            blocked[entry.itemID] = true
        end
        if currentEntry(entry) and action and action.kind == "bank" and action.index == entry.id then
            local quantity = math.min(entry.quantity, action.quantity - (action.credited or 0))
            if quantity > 0 then
                local itemID = entry.itemID
                result[#result + 1] = {kind = "bank", job = entry.job, itemID = itemID, id = entry.id,
                    quantity = quantity, pending = true}
                matched[itemID] = (matched[itemID] or 0) + quantity
                bankReserved = math.max(bankReserved, quantity)
            end
        end
        reserved[entry.itemID] = (reserved[entry.itemID] or 0) + bankReserved
    end

    local function add(entry, taken)
        if not currentEntry(entry) or entry.job.acquisition or blocked[entry.itemID] then return end
        local itemID, job, requirement = entry.itemID, entry.job, entry.requirement
        local needed = FC.Queue.AcquisitionRemaining(job, requirement)
        needed = restockAllowance(entry, needed, "bank")
        if needed <= 0 then return end
        if entry.kind ~= "bank" then
            if (requirement.auctionAwaiting or 0) > 0 then return end
            if job.rootItemID == itemID and job.goal and job.goal.demandId then
                local demand = Logistics.GetDemand(job.goal.demandId)
                if not demand or demand.countBank or not demand.bankRestock then return end
            end
            if Logistics.IsAuctionShoppingEntry(entry) then
                local quote = Logistics.GetAuctionNeed(entry)
                if quote and quote.mailKnown then needed = math.min(needed, quote.toBuy) end
            end
        end
        if offers[itemID] == nil then
            offers[itemID] = false
            for _, offer in ipairs(owner.GetAcquisitions(itemID, job.characterKey) or {}) do
                if offer.kind == "bank" and offer.qualified == true and offer.offerId
                    and offer.actorKey == job.characterKey and offer.itemID == itemID and offer.unit == "item"
                    and offer.bundlePrice == 0 and offer.bundleSize == 1 and validCount(offer.availableUnits) then
                    offers[itemID] = offer
                    break
                end
            end
        end
        local offer = offers[itemID]
        if not offer or entry.kind == "bank" and entry.offerId ~= offer.offerId then return end
        local available = offer.availableUnits - (taken[itemID] or 0)
        local quantity = math.min(needed, available)
        if quantity <= 0 then return end
        result[#result + 1] = {kind = "bank", job = job, itemID = itemID, id = entry.id,
            quantity = quantity, offer = offer, entry = entry}
        taken[itemID] = (taken[itemID] or 0) + quantity
    end
    for _, entry in ipairs(matching) do add(entry, matched) end
    for _, entry in ipairs(alternatives) do add(entry, reserved) end
    return groupBankRequirements(result)
end

local function moveBankGroup(row)
    local owner = policy()
    if not owner or not owner.ExecuteAcquisition or Logistics.IsWorkflowBusy()
        or FC.Execution.IsBusy and FC.Execution.IsBusy() then return false, FC.L.workflowBusy end
    local offer, quantity = row.offer, row.quantity
    local observation = FC.InventoryAdapter.GetStatus()
    local before = FC.InventoryAdapter.Count(row.itemID)
    if not observation.reliable or observation.source == "none" or not validCount(before) then
        return false, observation.reason or FC.L.loading
    end
    for _, member in ipairs(row.members) do
        if not currentEntry(member.entry) or member.job.acquisition then return false, FC.L.offerChanged end
    end
    local offset = 0
    for _, member in ipairs(row.members) do
        local action = {kind = "bank", index = member.id, quantity = member.quantity,
            before = before + offset, credited = 0, startedAt = readClock(), status = "issued",
            dispatching = true, addonVersion = FC.version, clientBuild = FC.state.clientBuild,
            source = observation.source}
        member.action, member.revision, member.job.acquisition = action, member.job.planRevision, action
        offset = offset + member.quantity
    end
    local function validate(live, units, copper)
        local inventory = FC.InventoryAdapter.GetStatus()
        if not live or not validAcquisitionOffer(live, row.entry, "bank") or live.offerId ~= offer.offerId
            or live.marketContext ~= offer.marketContext or live.locationKey ~= offer.locationKey
            or live.bundleSize ~= 1 or live.bundlePrice ~= 0 or copper ~= nil and copper ~= 0
            or not validCount(units) or units < 1 or not inventory.reliable
            or inventory.source ~= observation.source or inventory.sourceGeneration ~= observation.sourceGeneration then
            return false
        end
        local available = 0
        for _, member in ipairs(row.members) do
            local job, action = member.job, member.action
            if action.status ~= "confirmed" then
                local requirement = member.entry.requirement
                if job.acquisition ~= action or action.status ~= "issued" or not currentEntry(member.entry)
                    or job.planRevision ~= member.revision or (requirement.auctionAwaiting or 0) > 0 then return false end
                local needed = FC.Queue.AcquisitionRemaining(job, requirement)
                available = available + math.min(needed, action.quantity - action.credited)
            end
        end
        return units <= available
    end
    local called, ok, reason, issued = pcall(owner.ExecuteAcquisition, offer, quantity, validate)
    local uncertain = not called or ok and issued ~= nil and (not validCount(issued) or issued < 1 or issued > quantity)
    local remaining = uncertain and quantity or ok and (issued or quantity) or 0
    for _, member in ipairs(row.members) do
        local job, action = member.job, member.action
        action.dispatching = nil
        local units = math.min(remaining, member.quantity)
        remaining = remaining - units
        if units > 0 then
            action.quantity = units
            if uncertain then markUncertain(job, action)
            else inspectAcquisition(job) end
        elseif job.acquisition == action then
            job.acquisition = nil
            FC.Queue.FinishDeferredInvalidation(job)
        end
    end
    if uncertain then return false, FC.L.acquisitionUncertain end
    if not ok then return false, reason end
    if C_Timer and C_Timer.After then
        C_Timer.After(16, function()
            for _, member in ipairs(row.members) do
                if member.job.acquisition == member.action then inspectAcquisition(member.job) end
            end
        end)
    end
    return true, FC.L.acquisitionPending
end

local function vendorAlternativeRow(entry, owner, blockedItems, blockedDemands, allowPendingVendor)
    local job, requirement = entry.job, entry.requirement
    local action = FC.Queue.GetAcquisition(job, entry.id)
    if action and action.kind == "vendor" and action.substitutedAuction then
        local quantity = math.min(entry.quantity, action.quantity - (action.credited or 0))
        if quantity > 0 then
            return {kind = "vendor", job = job, itemID = entry.itemID, id = entry.id, quantity = quantity, pending = true}
        end
    end
    if action or not canIssueVendor(entry, allowPendingVendor) or not blockedItems or blockedItems[entry.itemID]
        or blockedDemands[job.goal and job.goal.demandId] or not canUseVendorForAuction(entry) then return end
    local need = vendorAlternative(entry)
    if not need then return end
    for _, offer in ipairs(owner.GetAcquisitions(entry.itemID, job.characterKey) or {}) do
        if matchesVendorAlternative(offer, entry, need) then
            local quantity = vendorOrderQuantity(offer, substitutedVendorQuantity(requirement, offer, need), need.maxTotalPrice)
            if quantity and quantity > 0 then
                return {kind = "vendor", job = job, itemID = entry.itemID, id = entry.id,
                    quantity = quantity, entry = entry, offer = offer}
            end
        end
    end
end

local function vendorRequirements(allowPendingVendor)
    local rows = {}
    local owner = merchantOpen() and policy()
    local blockedItems, blockedDemands
    if owner and owner.GetAcquisitions and owner.ExecuteAcquisition then
        blockedItems, blockedDemands = vendorReceiptBlocks(allowPendingVendor)
    else
        owner = nil
    end
    local alternatives = {}
    for _, entry in ipairs(FC.Queue.GetRequirements()) do
        if entry.kind == "vendor" then
            local job, requirement = entry.job, entry.requirement
            local action = FC.Queue.GetAcquisition(job, entry.id)
            entry.pending = action and action.kind == "vendor" or nil
            if entry.pending and validCount(action.quantity) then
                entry.quantity = math.min(entry.quantity, action.quantity - (action.credited or 0))
            end
            local need = not action and Logistics.GetAuctionNeed(entry, nil, {})
            if not action and ((requirement.auctionAwaiting or 0) > 0 or need and (need.pendingIncoming or 0) > 0) then
                entry.quantity = 0
            end
            if not job.acquisition and directRestockGoal(entry) then
                local quoted = requirement.offer or requirement.quote or requirement
                local bundle = type(quoted.bundleSize) == "number" and quoted.bundleSize >= 1 and quoted.bundleSize or 1
                local needed = FC.Queue.AcquisitionRemaining(job, requirement)
                entry.quantity = math.min(entry.quantity,
                    restockOrderSize(entry, needed, "vendor", bundle))
            end
            if entry.quantity > 0 then rows[#rows + 1] = entry end
        elseif entry.kind == "auction" and owner and currentEntry(entry) then
            local alternative = vendorAlternativeRow(entry, owner, blockedItems, blockedDemands, allowPendingVendor)
            if alternative then alternatives[#alternatives + 1] = alternative end
        end
    end
    for _, row in ipairs(alternatives) do rows[#rows + 1] = row end
    return rows
end

local function vendorPassEntries(pass)
    local rows = {}
    for _, row in ipairs(vendorRequirements(true)) do
        local entry = row.entry or row
        local permission = pass.requirements and pass.requirements[entry.requirement]
        if currentEntry(entry) and not entry.requirement.autoBuyBlocked
            and (not pass.requirements or permission and permission.job == entry.job
                and permission.revision == entry.job.planRevision)
            and not pass.declined[entry.requirement]
            and (not pass.automatic or acceptedVendor(entry.job, entry.requirement)) then
            rows[#rows + 1] = row
        end
    end
    return rows
end

function runVendorPass(pass, retries)
    if vendorPass ~= pass or not merchantOpen() then return false, FC.L.offerUnavailable end
    if pass.running then return true, FC.L.acquisitionPending end
    local owner = policy()
    if pass.automatic and (Logistics.GetSettings().autoBuyVendor == false
        or owner.AllowsAutomaticVendorPurchase and not owner.AllowsAutomaticVendorPurchase()) then
        vendorPass = nil
        return false, FC.L.offerUnavailable
    end
    if vendorWorkflowBlocked(retries, true) then return true, FC.L.workflowBusy end
    pass.running = true
    local rows = vendorPassEntries(pass)
    local started, reason
    for _, row in ipairs(rows) do
        local entry = row.entry or row
        local items, demands = vendorReceiptBlocks(true)
        if not items or vendorPass ~= pass then break end
        if canIssueVendor(entry, true) and not row.pending and not items[entry.itemID]
            and not demands[entry.job.goal and entry.job.goal.demandId] then
            local ok, feedback, attempted = Logistics.Acquire(entry, pass.automatic, rows, pass, row.entry and row)
            if ok then started = true
            elseif feedback then reason = feedback end
            if attempted and not ok then pass.declined[entry.requirement] = true end
            if pass.automatic and not ok and (attempted or feedback == FC.L.offerChanged)
                and not reportedVendor[entry.requirement] then
                reportedVendor[entry.requirement] = true
                FC:Emit("ACQUISITION_CHANGED", "blocked", entry, 0, feedback)
            end
        end
    end
    pass.running = nil
    local _, _, waiting = vendorReceiptBlocks(true)
    if started or waiting then
        if not waiting then scheduleVendor() end
        return true, FC.L.acquisitionPending
    end
    if vendorPass == pass then vendorPass = nil end
    return false, reason or FC.L.offerUnavailable
end

startVendorPass = function(automatic, retries)
    if not merchantOpen() then return false, FC.L.offerUnavailable end
    local owner = policy()
    if not owner or not owner.ExecuteAcquisition or not owner.GetAcquisitions then return false, FC.L.ownerUnavailable end
    if vendorPass and (automatic == true or not vendorPass.automatic) then return runVendorPass(vendorPass, retries) end
    if automatic then
        if Logistics.GetSettings().autoBuyVendor == false
            or owner.AllowsAutomaticVendorPurchase and not owner.AllowsAutomaticVendorPurchase() then
            return false, FC.L.offerUnavailable
        end
        if vendorWorkflowBlocked(retries, true) then return true, FC.L.workflowBusy end
    end
    local money = GetMoney and GetMoney()
    if not validCount(money) then return false, FC.L.loading end
    -- The wallet can still show its previous value while merchant receipts land.
    for _, job in ipairs(FC.Queue.GetJobs()) do
        for _, action in ipairs(FC.Queue.Acquisitions(job)) do
            if action.kind == "vendor" and action.status == "issued" then
                if not validCount(action.totalCopper) then return false, FC.L.acquisitionPending end
                money = math.max(0, money - action.totalCopper)
            end
        end
    end
    if vendorPass then money = math.min(money, vendorPass.funds) end
    local pass = {automatic = automatic == true, funds = money,
        declined = automatic == true and declinedVendor or {}}
    if not pass.automatic then
        pass.requirements = {}
        for _, row in ipairs(vendorRequirements(true)) do
            local entry = row.entry or row
            if currentEntry(entry) then
                pass.requirements[entry.requirement] = {job = entry.job, revision = entry.job.planRevision}
            end
        end
        if not next(pass.requirements) then return false, FC.L.offerUnavailable end
    end
    merchantVisitOpen, vendorPass = true, pass
    return runVendorPass(pass, retries)
end

function Logistics.BuyVendorRequirements(automatic)
    return startVendorPass(automatic, VENDOR_RETRIES)
end

local function vendorStage()
    local items, revisions, candidates = {}, {}, {}
    local blockedItems, blockedDemands = vendorReceiptBlocks()
    local owner = merchantOpen() and policy()
    local reliable = FC.InventoryAdapter.GetStatus().reliable
    local canBuy = reliable and blockedItems and owner and owner.GetAcquisitions and owner.ExecuteAcquisition
        and not Logistics.IsWorkflowBusy() and not (FC.Execution.IsBusy and FC.Execution.IsBusy())
        and not (InCombatLockdown and InCombatLockdown()) and not (GetCursorInfo and GetCursorInfo())
    local selected, selectedOffer, selectedShares, ordered
    for _, row in ipairs(vendorRequirements()) do
        local entry = row.entry or row
        local demandID = entry.job.goal and entry.job.goal.demandId
        if not entry.job.acquisition and not row.pending and currentEntry(entry)
            and (not blockedItems or not blockedItems[row.itemID] and not blockedDemands[demandID]) then
            items[row.itemID] = (items[row.itemID] or 0) + row.quantity
            revisions[#revisions + 1] = ("%d/%d/%q/%d"):format(entry.job.id, entry.id, tostring(entry.job.planRevision), row.quantity)
            candidates[#candidates + 1] = row
            if canBuy and not selected then
                local share
                if row.entry then
                    selected, selectedOffer, ordered = row, row.offer, row.quantity
                else
                    share = vendorShare(row, owner.GetAcquisitions(row.itemID, row.job.characterKey) or {})
                    if share then selected, selectedOffer, ordered = row, share.offer, share.quantity end
                end
            end
        end
    end
    if not next(items) then return end
    if selected then
        local shares, quantity = quoteVendorGroup(selected.entry or selected, candidates, owner, nil, nil, selected.entry ~= nil)
        if shares then selectedShares, ordered = shares, quantity end
    end
    if selected then
        revisions[#revisions + 1] = ("%d/%q/%q/%d/%d"):format(selected.itemID, tostring(selectedOffer.offerId),
            tostring(selectedOffer.revision), selectedOffer.bundlePrice, ordered)
        for _, share in ipairs(selectedShares or {}) do
            revisions[#revisions + 1] = ("%d/%d/%d/%q"):format(share.entry.job.id, share.entry.id, share.quantity, tostring(share.budget))
        end
    end
    return {items = items, key = table.concat(revisions, "|"), canBuy = selected ~= nil}, selected, candidates
end

function Logistics.GetVendorStage()
    local stage = vendorStage()
    return stage
end

function Logistics.BuyVendorStage(key)
    local stage, row, candidates = vendorStage()
    if not stage or not stage.canBuy or stage.key ~= key then return false, FC.L.offerChanged end
    local owner, vendor = policy(), _G.FluxVendorAuto
    if owner and type(owner.BuyVendorRequirements) == "function"
        and vendor and type(vendor.DoRestockManual) == "function" then
        return vendor.DoRestockManual()
    end
    return Logistics.Acquire(row.entry or row, false, candidates, nil, row.entry and row)
end

local function acquireRequirement(surface, selection)
    if surface == "bank" then creditCarriedRequirements(selection.itemID) end
    local rows = surface == "bank" and bankRequirements() or vendorRequirements()
    for _, row in ipairs(rows) do
        if not row.pending and row.kind == surface and row.job.id == selection.jobId and row.id == selection.id
            and row.itemID == selection.itemID and row.quantity == selection.quantity
            and row.job.planRevision == selection.planRevision and row.groupKey == selection.groupKey then
            if surface == "bank" and row.members then return moveBankGroup(row) end
            if surface == "vendor" then
                return Logistics.Acquire(row.entry or row, false, rows, nil, row.entry and row)
            end
            if row.entry then return acquire(row.entry, false, row) end
        end
    end
    return false, FC.L.offerChanged
end

local function matchingDemand(demand, context, refresh)
    local owner = policy()
    local manual = not context or context.manual ~= false
    for _, row in ipairs(owner and owner.GetDemands({manual = manual, context = context}) or {}) do
        if row.id == demand.id and row.itemID == demand.itemID and row.uncovered == demand.uncovered then
            if row.revision == demand.revision then return row end
            if not refresh then return end
            -- The owner publishes a coverage revision when the scan starts.
            -- Reuse the demand only if its actual purchasing policy stayed the same.
            for _, key in ipairs({"actorKey", "destination", "target", "trigger", "mode", "units", "maxPrice",
                "countBank", "bankRestock", "bankStash", "tierKind", "owner"}) do
                if row[key] ~= demand[key] then return end
            end
            return row
        end
    end
end

local function acceptRestockPlan(args, demand, context)
    local plan, details = Logistics.Preview(args)
    if not plan then return false, details end
    if plan.status ~= "ready" and plan.status ~= "sourcing" then
        return false, plan.blocker or FC.L.noKnownCraft
    end
    local job, why = FC.Queue.Accept(plan, function()
        local current = matchingDemand(demand, context)
        if current then
            args.demand = current
            return Logistics.Preview(args)
        end
    end)
    if not job then return false, why end
    job.projection = details.projection
    if not context or context.manual ~= false then FC:Emit("RESTOCK_VIEW", demand, job) end
    return true, FC.L.queueAccepted:format(job.id), job
end

local function request(demand, action, context)
    if action == "view" then
        local job
        for _, current in ipairs(FC.Queue.GetJobs()) do
            if current.goal and current.goal.demandId == demand.id and FC.Queue.OutstandingOutput(current) > 0 then
                job = current
                break
            end
        end
        FC:Emit("RESTOCK_VIEW", demand, job)
        return true, FC.L.openProfession
    end
    if demand.units and demand.units ~= "item" and demand.units ~= "items" then
        return false, FC.L.unsupportedRestockUnits
    end
    if (tonumber(demand.uncovered) or 0) <= 0 then return false, FC.L.alreadyCovered end
    if not demand.itemID then return false, FC.L.noKnownCraft end
    local args = {quantity = demand.uncovered, itemID = demand.itemID, intent = "supply", demand = demand}
    if action == "craft" then
        args.choices = {[demand.itemID] = {source = "Make"}}
        args.deferRecipeRequirements = not context or context.manual ~= false
    end
    if context and context.manual == false then
        args.limits, args.autoBuyVendor = {states = 600}, false
    end
    if context and context.manual ~= false and context.source == "auction" and Logistics.HasAuctionPriceScan() then
        args.auctionRestock = true
        local ok, reason = Logistics.ScanAuctionPrices(args, function(found, _, failure)
            local current = found and matchingDemand(demand, context, true)
            if current then
                args.demand = current
                local accepted, message, job = acceptRestockPlan(args, current, context)
                FC:Emit("RESTOCK_AUCTION_CHECK", accepted, message, job)
            else
                local message = found and FC.L.offerChanged or FC.L.auctionFeedback[failure] or failure
                    or FC.L.auctionFeedback.noOffer
                FC:Emit("RESTOCK_AUCTION_CHECK", false, message)
            end
        end)
        return ok, ok and FC.L.auctionCheckingPrices or FC.L.auctionFeedback[reason] or reason
    end
    return acceptRestockPlan(args, demand, context)
end

local function readyRestockCraft()
    local execution = FC.Execution
    if not execution or not execution.GetReadyRestockCraft then return end
    local ui = FC.UI
    local retryNative = execution.HasNativeCraftPending and execution.HasNativeCraftPending()
        and ui and ui.GetPreparedNativeCraft and not ui.GetPreparedNativeCraft()
    local task, batch, job, direct, reprepareNative = execution.GetReadyRestockCraft(nil, retryNative)
    if task then
        return {jobId = job.id, planRevision = job.planRevision, taskId = task.taskId,
            itemID = task.outputItemID, quantity = batch, outputQuantity = batch * task.yield,
            direct = direct == true or nil}, job, task, nil, reprepareNative
    end
    if not execution.GetCarriedOutputRecovery or not execution.ResumeWithCarriedOutput then return end
    job, task = FC.Queue.NextTask()
    if not task or task.status ~= "uncertain" then return end
    local recovery = execution.GetCarriedOutputRecovery(job)
    if not recovery or recovery.taskId ~= task.taskId then return end
    local remaining = recovery.remainingExecutions * task.yield
    return {
        jobId = job.id, planRevision = job.planRevision, taskId = task.taskId, itemID = task.outputItemID,
        quantity = math.max(1, recovery.remainingExecutions),
        outputQuantity = remaining > 0 and remaining or recovery.quantity,
        resume = tostring(recovery.evidence) .. ":" .. tostring(recovery.outputCount),
        carriedOutput = recovery.quantity, remainingOutput = remaining,
    }, job, task, recovery
end

local function processRestockCraft(selection)
    local current, job, task, recovery, reprepareNative = readyRestockCraft()
    if not current or not selection or current.jobId ~= selection.jobId
        or current.planRevision ~= selection.planRevision or current.taskId ~= selection.taskId
        or current.quantity ~= selection.quantity or current.itemID ~= selection.itemID
        or current.outputQuantity ~= selection.outputQuantity or current.resume ~= selection.resume
        or current.carriedOutput ~= selection.carriedOutput or current.remainingOutput ~= selection.remainingOutput
        or selection.direct == true and current.direct ~= true then
        return false, FC.L.offerChanged
    end
    local execution = FC.Execution
    if recovery then
        local ok, message, resumed = execution.ResumeWithCarriedOutput(job, recovery)
        if not ok or current.remainingOutput == 0 then return ok, message, job end
        local nextTask, _, readyJob = execution.GetReadyRestockCraft(job)
        if readyJob ~= job or nextTask ~= (resumed or task) then return true, message, job end
        current.direct = nil
        task = nextTask
    end
    -- Older FluxUI builds advertise the native handoff and omit the direct mode.
    local dispatch = (reprepareNative or current.direct and selection.direct ~= true)
        and execution.ProcessNext or execution.ProcessClick
    local ok, message, acceptedJob, phase = dispatch(job, task, true)
    if phase == "native_click" and FC.UI and FC.UI.ShowNativeCraft then
        message = FC.UI.ShowNativeCraft(message, acceptedJob or job) or message
    end
    return ok, message, acceptedJob, phase
end

local function revealNativeCraft(recipeID, batch)
    if FC.UI and FC.UI.RevealNativeCraft then return FC.UI.RevealNativeCraft(recipeID, batch) end
    return false
end

local function getPreparedNativeCraft()
    if FC.UI and FC.UI.GetPreparedNativeCraft then return FC.UI.GetPreparedNativeCraft() end
end

local function getRestockProfession()
    local selection = FC.Execution.GetRestockProfession()
    if selection and FC.target == "forever" and C_TradeSkillUI and type(C_TradeSkillUI.OpenTradeSkill) == "function" then
        selection.queueSwitch = true
    end
    return selection
end

local function isNativeCraftBusy()
    local execution = FC.target == "forever" and FC.Execution
    return execution and ((execution.IsBusy and execution.IsBusy())
        or (execution.HasNativeCraftPending and execution.HasNativeCraftPending())) or false
end

if FC.disabled then return end
FC:On("READY", function()
    local events = Flux and Flux.Events
    if events and events.Register then
        events.Register("MERCHANT_SHOW", function() scheduleVendor(0, nil, true) end)
        events.Register("MERCHANT_CLOSED", function()
            closeVendorVisit()
            if refreshAuctionRestock then refreshAuctionRestock() end
        end)
    end
    local auction = _G.FluxAuctionRestock
    local followup = auction and auction.Followup
    local execution = FC.Execution
    local registeredCraft = followup and followup.RegisterLogisticsCraft and followup.Refresh
        and followup.RegisterLogisticsCraft({
            GetReady = readyRestockCraft, Process = processRestockCraft, GetIncoming = restockIncoming,
            GetProfession = execution and execution.GetRestockProfession and getRestockProfession,
            OpenProfession = execution and execution.OpenRestockProfession,
            RevealNativeCraft = revealNativeCraft, IsNativeCraftBusy = isNativeCraftBusy,
            GetPreparedNativeCraft = getPreparedNativeCraft,
            GetVendorStage = Logistics.GetVendorStage, BuyVendorStage = Logistics.BuyVendorStage,
        })
    local registeredRows = auction and auction.RegisterLogisticsRows and auction.RefreshLogisticsRows
        and auction.RegisterLogisticsRows({GetRows = restockAuctionRows, Select = function(row)
            if FC.UI and FC.UI.OpenAuctionShopping then return FC.UI.OpenAuctionShopping(nil, row) end
        end})
    if registeredCraft or registeredRows then
        local pending, incomingChanged
        local function refresh()
            local refreshIncoming = incomingChanged
            pending, incomingChanged = nil, nil
            if registeredCraft then
                if refreshIncoming and followup.RefreshLogistics then followup.RefreshLogistics()
                else followup.Refresh() end
            end
            if registeredRows then auction.RefreshLogisticsRows() end
        end
        refreshAuctionRestock = function(receiptsChanged)
            if receiptsChanged then incomingChanged = true end
            if pending then return end
            pending = true
            if C_Timer and C_Timer.After then C_Timer.After(0, refresh) else refresh() end
        end
        refreshAuctionRestock(true)
    end
    local owner = policy()
    if owner and owner.RegisterPlanner then
        owner.RegisterPlanner({
            GetCoverage = coverageWithOwner,
            Request = request,
            GetRequirements = FC.Queue.GetRequirements,
            GetCraftMaterialIDs = FC.Queue.GetCraftMaterialIDs,
            GetShoppingRequirements = Logistics.GetAuctionShoppingRequirements,
            GetVendorStage = Logistics.GetVendorStage,
            BuyVendorRequirements = Logistics.BuyVendorRequirements,
            GetAcquisitionRequirements = function(surface)
                if surface == "bank" then return bankRequirements() end
                if surface == "vendor" then return vendorRequirements() end
            end,
            AcquireRequirement = acquireRequirement,
            OpenAuctionShopping = function(parent, entry)
                if FC.UI and FC.UI.OpenAuctionShopping then return FC.UI.OpenAuctionShopping(parent, entry) end
            end,
            GetPlanStatus = function(demand)
                local coverage = FC.Queue.Coverage(demand)
                if coverage[1] then return FC.L.restockProgress:format(demand.covered, demand.uncovered) end
            end,
            IsWorkflowBusy = function() return priceScan ~= nil or acquiring() or FC.Execution.IsBusy and FC.Execution.IsBusy() end,
        })
        if owner.Subscribe then
            owner.Subscribe("FluxLogistics.Workbench", function(_, reason)
                FC:Emit("RESTOCK_POLICY_CHANGED", reason)
                merchantChanged()
            end)
        end
        local vendor = _G.FluxVendorAuto
        if vendor and vendor.RegisterMerchantIndexListener then
            vendor.RegisterMerchantIndexListener(function()
                -- Run after the owner has queued its native vendor work.
                scheduleVendor()
                if refreshAuctionRestock then refreshAuctionRestock() end
            end)
        end
    end
end)
FC:On("QUEUE_CHANGED", function()
    local owner = policy()
    if owner and owner.NotifyCoverageChanged then owner.NotifyCoverageChanged() end
    scheduleVendor()
    if refreshAuctionRestock then refreshAuctionRestock(true) end
end)
FC:On("ACQUISITION_CHANGED", function(_, state, entry, quantity, message, groupRevision)
    if refreshAuctionRestock and (entry or groupRevision) then refreshAuctionRestock() end
end)
FC:On("PROFESSION_CHANGED", function() if refreshAuctionRestock then refreshAuctionRestock() end end)
FC:On("CRAFT_REQUIREMENT_CHANGED", function() if refreshAuctionRestock then refreshAuctionRestock() end end)
FC:On("EXECUTION_CHANGED", function()
    if not (FC.Execution.IsBusy and FC.Execution.IsBusy()) then scheduleVendor() end
    if refreshAuctionRestock then refreshAuctionRestock() end
end)
FC:On("NATIVE_CRAFT_PREPARED_CHANGED", function() if refreshAuctionRestock then refreshAuctionRestock() end end)
FC:On("INVENTORY_CHANGED", function(_, status, context)
    local regions = context and context.regions
    if regions and regions.mail then
        local owner = policy()
        if owner and owner.NotifyCoverageChanged then owner.NotifyCoverageChanged() end
    end
    for _, job in ipairs(FC.Queue.GetJobs()) do
        for _, action in ipairs(FC.Queue.Acquisitions(job)) do
            if action.kind ~= "auction" and (action.status == "issued" or action.status == "uncertain") then
                if status and status.handover then
                    action.baselineInvalid = true
                    markUncertain(job, action)
                elseif not regions or regions.bags then
                    inspectAcquisition(job, action)
                end
            end
        end
    end
    if not (status and status.handover) and (not regions or regions.bags) then creditCarriedRequirements() end
    scheduleVendor()
    if refreshAuctionRestock and (not regions or regions.bags or regions.mail) then
        refreshAuctionRestock(not regions or regions.bags)
    end
end)
