local ownerPath = arg[1] or "../_FluxUI/Inventory/Restock/Core/FluxRestockPolicy.lua"
local stock, petBank = {[501] = 12}, 10
local timers, callbacks, nativeEvents = {}, {}, {}
C_Timer = {After = function(_, fn) timers[#timers + 1] = fn end}
UnitGUID = function(unit) assert(unit == "player"); return "fixture-player" end
time = function() return 1234567 end

local FC = {version = "fixture-release", state = {characterKey = "fixture-player", build = 16001,
    clientBuild = "71037", db = {}, char = {}}}
FC.followupRefreshes, FC.receiptRefreshes = 0, 0
function FC:On(event, callback)
    callbacks[event] = callbacks[event] or {}
    table.insert(callbacks[event], callback)
end
function FC:Emit(event, ...)
    for _, listener in ipairs(callbacks[event] or {}) do listener(self, ...) end
end
local row = {itemID = 501, target = 40, name = "Fixture stock", countBank = false}
local reports, issued, opened, inventorySource = 0, 0, true, "builtin"
Flux = {Events = {Register = function(event, callback) nativeEvents[event] = callback end}, Inventory = {
    IsReady = function() return true end,
    IsReliable = function() return true end,
    GetCount = function(id, scope)
        if scope.bags then return stock[id] or 0 end
        return id == 501 and petBank or 0
    end,
    GetSource = function() return inventorySource end,
    GetSnapshotGeneration = function() return reports end,
    RegisterListener = function() end,
    Bank = {
        IsLive = function() return opened end,
        GetCount = function(id) return id == 501 and petBank or 0 end,
        GetGeneration = function() return reports end,
    },
}}
FluxRestock = {Inv = Flux.Inventory}
local merchantIndexReady
FluxVendorAuto = {
    RegisterMerchantIndexListener = function(callback) merchantIndexReady = callback end,
    GetRestockTargetItems = function()
        row.bagCount, row.bankCount = stock[501], petBank
        return {row}
    end,
    GetRestockItemFlags = function() return {bankRestock = true} end,
}
FluxAuctionRestock = {GetPolicyCoverage = function() return 8 end,
    RegisterLogisticsRows = function(provider) FC.testAuctionRows = provider; return true end,
    RefreshLogisticsRows = function() end, Followup = {
    RegisterLogisticsCraft = function(provider) FC.testRestockCraft = provider; return true end,
    Refresh = function() FC.followupRefreshes = FC.followupRefreshes + 1 end,
    RefreshLogistics = function() FC.receiptRefreshes = FC.receiptRefreshes + 1 end,
}}
FluxBankRestock = {
    StartLogistics = function(offer, amount, validate)
        assert(offer.kind == "bank" and validate(offer, amount))
        issued = issued + amount
        return true, nil, amount
    end,
}
FC.Catalog = {Snapshot = function()
    return {recipesById = {}, byOutput = {}, revision = 1, characterKey = FC.state.characterKey}
end}
FC.MarketAdapter = {QuoteItems = function()
    return {[501] = 10000, [502] = 4000, [508] = 100, [509] = 100, [510] = 100, [511] = 100, [512] = 100}, {}
end}
FC.Execution = {IsBusy = function() return false end}
FC.Execution.ProcessClick = function(...) return FC.Execution.ProcessNext(...) end
do
    function FC.Execution.GetRestockProfession() return {professionID = 197} end
    function FC.Execution.OpenRestockProfession(selection) return selection.professionID == 197 end
end
assert(loadfile(ownerPath))("_FluxUI", {Flux = Flux})
local plannerProvider
local registerPlanner = Flux.RestockPolicy.RegisterPlanner
Flux.RestockPolicy.RegisterPlanner = function(provider)
    plannerProvider = provider
    return registerPlanner(provider)
end
for _, name in ipairs({"Locale", "AdaptersInventory", "Planner", "Pricing", "Queue", "Logistics"}) do
    local path = name == "Logistics" and arg[2] or ("FluxCraft/" .. name .. ".lua")
    assert(loadfile(path))("FluxLogistics", FC)
end
assert(FC.Queue.Initialize(FC.state.char))
FC:Emit("READY")
local policy = Flux.RestockPolicy
policy.RegisterPlanner = registerPlanner
local function drain()
    local left = 200
    while #timers > 0 do
        left = left - 1
        assert(left > 0)
        table.remove(timers, 1)()
    end
end
drain()
assert(FC.receiptRefreshes == 1 and next(FC.testRestockCraft.GetIncoming()) == nil)
do
    assert(not FC.testRestockCraft.RevealNativeCraft(22), "an unattached companion has no native presentation")
    FC.UI = {RevealNativeCraft = function(recipeID, batch) return recipeID == 22 and batch == 3, batch end}
    local revealed, batch = FC.testRestockCraft.RevealNativeCraft(22, 3)
    assert(revealed and batch == 3 and not FC.testRestockCraft.RevealNativeCraft(11, 3),
        "the owner can reveal the exact native recipe separately from the craft queue")
    local target = FC.target
    FC.target = "forever"
    local nativeTradeSkill = C_TradeSkillUI
    assert(FC.testRestockCraft.GetProfession().professionID == 197 and not FC.testRestockCraft.GetProfession().queueSwitch)
    C_TradeSkillUI = {OpenTradeSkill = function() error("reading the HUD must not open a profession") end}
    local opener = FC.testRestockCraft.GetProfession()
    assert(opener.queueSwitch and opener.professionID == 197 and FC.testRestockCraft.OpenProfession(opener),
        "Forever should dispatch the accepted profession action through the queue when its public opener exists")
    FC.target = "classic"
    assert(not FC.testRestockCraft.GetProfession().queueSwitch, "the legacy owner keeps its existing profession route")
    FC.target, C_TradeSkillUI = "forever", nativeTradeSkill
    FC.Execution.HasNativeCraftPending = function() return true end
    assert(FC.testRestockCraft.IsNativeCraftBusy(), "the owner can inspect an armed companion handoff without replacing it")
    FC.Execution.HasNativeCraftPending = nil
    assert(not FC.testRestockCraft.IsNativeCraftBusy(), "an unoccupied native craft window allows the owner to prepare")
    FC.target, FC.UI = target, nil
end
FC:Emit("PROFESSION_CHANGED")
FC:Emit("EXECUTION_CHANGED")
drain()
assert(FC.receiptRefreshes == 1 and FC.followupRefreshes == 1, "craft-only notifications refresh without rebuilding receipts")
assert(policy.IsPlannerRegistered())
assert(policy.GetMode() == "normal" and not policy.AllowsPassive())
assert(policy.GetDemand("item:501").uncovered == 20)
local uncovered, coverage, ready = policy.Resolve({id = "item:501", target = 40, units = "item"}, 12, 10, {
    {id = "accepted-incoming", quantity = 8}, {id = "bank-delivery", quantity = 10, kind = "bank"},
    {id = "bank-delivery", quantity = 10, kind = "bank"},
})
assert(uncovered == 10 and coverage == 18 and ready == 12)
do
    local scanned
    FluxAuctionRestock.ScanLogisticsBooks = function(items, callback)
        assert(#items == 1 and items[1] == 501)
        scanned = callback
        return true, "searching"
    end
    assert(FC.Queue.Initialize({}))
    policy.NotifyChanged("coverage")
    assert(policy.Request("item:501", "restock", {manual = true, source = "auction"}))
    assert(#FC.Queue.GetJobs() == 0 and not policy.Request("item:501", "restock", {manual = true, source = "auction"}),
        "the existing Restock action waits for one read-only price scan without accepting duplicate work")
    scanned({[501] = {itemID = 501, complete = true, commodity = true, offers = {{quantity = 30, unitPrice = 200}}}})
    local quoted = assert(FC.Queue.GetJobs()[1])
    assert(quoted.requirements[1].quantity == 20 and quoted.requirements[1].maxTotalPrice == 4000
        and quoted.requirements[1].maxUnitPrice == 200 and not quoted.acquisition,
        "the owner action seals the observed quantity budget and waits for a separate purchase press")
    assert(FC.Queue.Initialize({}))
    policy.NotifyChanged("coverage")
    assert(policy.Request("item:501", "restock", {manual = true, source = "auction"}))
    row.target = 41
    policy.NotifyChanged()
    scanned({[501] = {itemID = 501, complete = true, commodity = true, offers = {{quantity = 30, unitPrice = 200}}}})
    assert(#FC.Queue.GetJobs() == 0, "a price scan cannot accept a target that changed while it was running")
    row.target = 40
    FluxAuctionRestock.ScanLogisticsBooks = nil
    FC.Logistics.ClearAuctionPrices()
    assert(FC.Queue.Initialize(FC.state.char))
    policy.NotifyChanged("coverage")
    drain()
end
do
    local gloves, bolt, recipeID = 10019, 4339, 12067
    local wildvine, heart, thread = 8153, 10286, 8343
    local station = "Spinning Wheel"
    local targetID = "item:" .. gloves
    local oldCatalog = FC.Catalog.Snapshot
    local oldTargets, oldCoverage = FluxVendorAuto.GetRestockTargetItems, FluxAuctionRestock.GetPolicyCoverage
    local oldResult, oldPolicy = callbacks.RESTOCK_AUCTION_CHECK, _G._FluxUI_CharSavedVars
    local checked, scanning, checkedJob
    callbacks.RESTOCK_AUCTION_CHECK = {function(_, ok, _, job)
        checked, checkedJob = ok, job
    end}
    _G._FluxUI_CharSavedVars = {}
    local stationRecipe = {id = recipeID, recipeID = recipeID, professionId = 197, outputItemID = gloves,
        learned = true, completeness = "complete", outputKind = "item", yield = 1, yieldMax = 1,
        characterKey = FC.state.characterKey, reagents = {
            {itemID = bolt, quantity = 4, slotIndex = 1}, {itemID = wildvine, quantity = 4, slotIndex = 2},
            {itemID = heart, quantity = 2, slotIndex = 3}, {itemID = thread, quantity = 2, slotIndex = 4},
        },
        constraints = {requirementsMet = false, requirements = {{name = station, met = false, kind = 0}}}}
    local catalog = {recipesById = {[recipeID] = stationRecipe}, byOutput = {[gloves] = {recipeID}}, revision = 2}
    FC.Catalog.Snapshot = function() return catalog end
    stock[gloves], stock[bolt] = 1, 3
    stock[wildvine], stock[heart], stock[thread] = 8, 4, 4
    FluxVendorAuto.GetRestockTargetItems = function()
        return {{itemID = gloves, target = 3, bagCount = stock[gloves], name = "Dreamweave Gloves"}}
    end
    FluxAuctionRestock.GetPolicyCoverage = function() return 0 end
    FluxAuctionRestock.ScanLogisticsBooks = function(items, callback)
        local seen = {}
        for _, itemID in ipairs(items) do seen[itemID] = true end
        assert(seen[bolt] and seen[wildvine] and seen[heart] and seen[thread],
            "the owner scan includes every material, including materials already in bags")
        scanning = callback
        return true, "searching"
    end
    local function completeScan()
        local callback = assert(scanning)
        scanning = nil
        callback({
            [gloves] = {itemID = gloves, complete = true, commodity = true, offers = {{quantity = 10, unitPrice = 500}}},
            [bolt] = {itemID = bolt, complete = true, commodity = true, offers = {{quantity = 25, unitPrice = 12}}},
            [wildvine] = {itemID = wildvine, complete = true, commodity = true, offers = {{quantity = 25, unitPrice = 4}}},
            [heart] = {itemID = heart, complete = true, commodity = true, offers = {{quantity = 25, unitPrice = 3}}},
            [thread] = {itemID = thread, complete = true, commodity = true, offers = {{quantity = 25, unitPrice = 8}}},
        })
    end
    assert(FC.Queue.Initialize({}))
    policy.NotifyChanged()
    assert(policy.Request(targetID, "craft", {manual = true, source = "auction"}))
    assert(#FC.Queue.GetJobs() == 0 and scanning, "Craft Missing waits for the Auction House scan")
    completeScan()
    local craft = assert(FC.Queue.GetJobs()[1])
    local task, materials = craft.tasks[1], FC.Queue.GetRequirements(craft)
    assert(checked and checkedJob == craft)
    assert(task.recipeId == recipeID and task.status == "pending" and task.executions == 2 and not task.evidence
        and craft.goal.auctionRestock and craft.goal.demandId == targetID and not craft.acquisition
        and craft.reservations[tostring(bolt)] == 3 and #materials == 1
        and materials[1].kind == "auction" and materials[1].itemID == bolt and materials[1].quantity == 5
        and materials[1].requirement.maxTotalPrice == 60 and policy.GetDemand(targetID).uncovered == 0,
        "manual Craft Missing queues only the station recipe's actual shortage and covers the target")

    assert(FC.Queue.Initialize({}))
    policy.NotifyChanged()
    assert(policy.Request(targetID, "restock", {manual = true, source = "auction"}))
    completeScan()
    local purchase = assert(FC.Queue.GetJobs()[1])
    assert(checked and checkedJob == purchase and #purchase.tasks == 0
        and purchase.requirements[1].itemID == gloves and purchase.requirements[1].quantity == 2,
        "Order Restock still buys the output instead of using the cheaper unavailable recipe")

    assert(FC.Queue.Initialize({}))
    assert(policy.SetMode("openworld") and policy.SetManaged(true))
    drain()
    local passive = assert(FC.Queue.GetJobs()[1])
    assert(#passive.tasks == 0 and passive.goal.autoBuyVendor == false and not scanning
        and passive.requirements[1].itemID == gloves and passive.requirements[1].quantity == 2,
        "passive restock keeps the normal source choices without opening an auction scan")

    FC.Catalog.Snapshot = oldCatalog
    FluxVendorAuto.GetRestockTargetItems, FluxAuctionRestock.GetPolicyCoverage = oldTargets, oldCoverage
    callbacks.RESTOCK_AUCTION_CHECK, _G._FluxUI_CharSavedVars = oldResult, oldPolicy
    FluxAuctionRestock.ScanLogisticsBooks = nil
    stock[gloves], stock[bolt], stock[wildvine], stock[heart], stock[thread] = nil, nil, nil, nil, nil
    FC.Logistics.ClearAuctionPrices()
    assert(FC.Queue.Initialize(FC.state.char))
    policy.NotifyChanged()
    drain()
end
FC.Logistics.GetSettings().objective = "cash"
assert(policy.Request("item:501", "restock", {manual = true, source = "bank"}))
local job = FC.Queue.GetJobs()[1]
assert(job and #job.tasks == 0 and FC.Queue.OutstandingOutput(job) == 20)
local bank, auction
for _, entry in ipairs(FC.Queue.GetRequirements(job)) do
    if entry.kind == "bank" then bank = entry else auction = entry end
end
assert(bank and bank.quantity == 10 and auction and auction.quantity == 10)
assert(policy.GetDemand("item:501").covered == 28 and policy.GetDemand("item:501").uncovered == 0)
assert(not policy.Request("item:501", "restock", {manual = true}))
assert(#FC.Queue.GetJobs() == 1)
row.countBank = true
policy.NotifyChanged()
assert(policy.GetDemand("item:501").covered == 18 and policy.GetDemand("item:501").uncovered == 0,
    "bank stock and its reserved withdrawal must not overlap")
row.countBank = false
policy.NotifyChanged()

opened = false
assert(not FC.Logistics.Acquire(bank) and issued == 0, "closed bank issued a withdrawal")
opened = true
local getOffers = policy.GetAcquisitions
policy.GetAcquisitions = function(...)
    local offers = getOffers(...)
    offers[1].unit = "charge"
    return offers
end
local mismatched, message = FC.Logistics.Acquire(bank)
assert(not mismatched and message == FC.L.offerChanged and issued == 0, "offer denomination changed")
policy.GetAcquisitions = function(...)
    local offers = getOffers(...)
    offers[1].kind = "vendor"
    return offers
end
mismatched, message = FC.Logistics.Acquire(bank)
assert(not mismatched and message == FC.L.offerChanged and issued == 0, "offer source kind changed")
policy.GetAcquisitions = getOffers

local startBank = FluxBankRestock.StartLogistics
FluxBankRestock.StartLogistics = function(offer, amount, validate)
    assert(amount == 10 and validate(offer, amount))
    issued = issued + 4
    error("fixture: bank owner failed after issuing four items")
end
local started, why = FC.Logistics.Acquire(bank)
assert(not started and why == FC.L.acquisitionUncertain)
assert(job.acquisition and job.acquisition.status == "uncertain")
assert(not FC.Logistics.IsWorkflowBusy(), "a failed owner call cannot hold the acquisition lease indefinitely")
assert(not FC.Logistics.Acquire(bank) and issued == 4, "uncertain withdrawal replayed without review")
stock[501], petBank, reports = 16, 6, 1
assert(FC.Logistics.ResolveAcquisition(job))
assert(not job.acquisition and bank.requirement.remaining == 6)
assert(FC.Queue.OutstandingOutput(job) == 16)
FluxBankRestock.StartLogistics = startBank
assert(FC.Logistics.Acquire(bank) and issued == 10)
assert(not FC.Logistics.Acquire(auction), "second action started before bank receipt")
assert(FC.Queue.OutstandingOutput(job) == 16, "request credited before receipt")
stock[501], petBank, reports = 22, 0, 2
FC:Emit("INVENTORY_CHANGED")
assert(FC.Queue.OutstandingOutput(job) == 10 and not FC.Queue.Reserved()["501"])
assert(policy.GetDemand("item:501").ready == 22 and policy.GetDemand("item:501").covered == 18)
stock[501], reports = 32, 3
FC:Emit("INVENTORY_CHANGED")
assert(FC.Logistics.Acquire(auction))
assert(job.status == "complete" and policy.GetDemand("item:501").uncovered == 0)

-- A visible bag gain can settle only one of two matching handoffs.
local args = {itemID = 502, intent = "supply", quantity = 1}
local first = assert(FC.Queue.Accept(FC.Logistics.Preview(args), function() return FC.Logistics.Preview(args) end))
local second = assert(FC.Queue.Accept(FC.Logistics.Preview(args), function() return FC.Logistics.Preview(args) end))
stock[502] = 1
assert(FC.Logistics.Acquire(FC.Queue.GetRequirements(first)[1]))
assert(not FC.Logistics.Acquire(FC.Queue.GetRequirements(second)[1]))
assert(FC.Queue.OutstandingOutput(second) == 1)

-- The same accepted incoming work reduces a stock preview without being bags.
local reached = assert(FC.Logistics.Preview({itemID = 502, intent = "stockUpTo", quantity = 2}))
assert(reached.summary.requested == 0 and stock[502] == 1)

do
    local item, reagent = 7201, 7202
    stock[reagent] = 3
    local recipe = {id = 7200, professionId = 171, learned = true, completeness = "complete", outputKind = "item",
        characterKey = FC.state.characterKey, outputItemID = item, yield = 2, yieldMax = 3,
        reagents = {{itemID = reagent, quantity = 1}}}
    local catalog = {recipesById = {[recipe.id] = recipe}, byOutput = {[item] = {recipe.id}}, revision = 1}
    local function original()
        return FC.Logistics.Preview({recipeId = recipe.id, intent = "additional", quantity = 5}, catalog)
    end
    local function target(quantity)
        local plan = assert(FC.Logistics.Preview({recipeId = recipe.id, intent = "stockUpTo", quantity = quantity}, catalog))
        return plan.summary.requested
    end
    local plan = assert(original())
    local batch = assert(FC.Queue.Accept(plan, original))
    local task = batch.tasks[1]
    assert(task.executions == 3 and batch.goal.quantity == 5 and batch.summary.output == 6
        and FC.Queue.OutstandingOutput(batch) == 5 and FC.Queue.PendingCarriedSurplus(batch) == 1)
    assert(target(6) == 0 and target(7) == 1 and stock[item] == nil,
        "a target should reuse guaranteed excess from an accepted batch but exclude possible proc units")

    local occupied = setmetatable({allocations = {
        {goal = true, producerTaskId = task.taskId, quantity = 5},
        {consumerTaskId = "sibling", producerTaskId = task.taskId, quantity = 1},
    }}, {__index = batch})
    assert(FC.Queue.PendingCarriedSurplus(occupied) == 0, "a sibling's promised unit is not available surplus")

    assert(FC.Queue.Begin(batch, task, {beforeOutput = 0, batch = 2, maxYield = 3}))
    assert(FC.Queue.PendingCarriedSurplus(batch) == 0)
    FC.Queue.CraftEvent(batch, task, 1, 3)
    assert(FC.Queue.PendingCarriedSurplus(batch) == 0 and target(6) == 1,
        "unconfirmed craft evidence cannot grant unallocated surplus")
    stock[item], stock[reagent] = 3, 2
    assert(not FC.Queue.Reconcile(batch, task, stock[item]) and task.evidence.carriedResult.outputCount == 3)
    FC.Queue.MarkUncertain(batch, task, "fixture interrupted batch")
    assert(FC.Queue.PendingCarriedSurplus(batch) == 0 and FC.Queue.ReconcilePartial(batch, task))
    assert(task.remainingExecutions == 2 and FC.Queue.OutstandingOutput(batch) == 3
        and FC.Queue.PendingCarriedSurplus(batch) == 1)
    assert(target(7) == 0 and target(8) == 1,
        "the received bonus is physical stock and only the remaining guaranteed crafts are forecast")
    assert(FC.Queue.Cancel(batch.id) and target(7) == 4, "cancellation must release remaining forecast")
    stock[item], stock[reagent] = nil, nil
end

-- A tier has its own withdrawal threshold and may plan eligible character
-- bank stock even without an exact-item bank-restock flag.
row = {isTierRestock = true, tierKind = "healPotion", target = 40, name = "Fixture potion tier"}
stock[501], petBank = 12, 10
local aboveBankThreshold = true
FluxRestockTiers = {
    GetTarget = function() return 40 end,
    GetCountBankFlag = function() return false end,
    IsTierEligible = function(kind) return kind == "healPotion" end,
    ItemMatchesRestockKind = function(kind, itemID) return kind == "healPotion" and itemID == 501 end,
    StackMatchesBankRestockKind = function(kind, itemID)
        return aboveBankThreshold and kind == "healPotion" and itemID == 501
    end,
}
FluxConsumableBest = {GetBestRef = function() return {itemID = 501} end}
policy.NotifyChanged()
local tier = assert(policy.GetDemand("tier:healPotion"))
assert(tier.uncovered == 20 and tier.bankRestock)
assert(policy.Request(tier.id, "restock", {manual = true, source = "bank"}))
local tierJob = FC.Queue.GetJobs()[#FC.Queue.GetJobs()]
local tierBank, tierAuction
for _, entry in ipairs(FC.Queue.GetRequirements(tierJob)) do
    if entry.kind == "bank" then tierBank = entry else tierAuction = entry end
end
assert(tierBank and tierBank.quantity == 10 and tierAuction and tierAuction.quantity == 10)
assert(not policy.Request(tier.id, "restock", {manual = true}), "tier coverage must stop repeated orders")
assert(FC.Queue.Cancel(tierJob.id))
aboveBankThreshold = false
policy.NotifyChanged()
tier = assert(policy.GetDemand(tier.id))
assert(tier.itemID == 501 and not tier.bankRestock, "eligible carried stock may be below the withdrawal threshold")
assert(policy.Request(tier.id, "restock", {manual = true, source = "bank"}))
tierJob = FC.Queue.GetJobs()[#FC.Queue.GetJobs()]
local tierRequirements = FC.Queue.GetRequirements(tierJob)
assert(#tierRequirements == 1 and tierRequirements[1].kind == "auction" and tierRequirements[1].quantity == 20)

-- Approved vendor plans wait for the current merchant's indexed gold offer,
-- issue one native stack at a time, and reconcile carried observations first.
opened = false
local merchantVisible, indexReady = false, false
local available, liveBundlePrice, money = 5, 40, 400
local vendorReceipts, vendorCalls = {}, {}
Flux.Inventory.IsMerchantOpen = function() return merchantVisible end
GetMoney = function() return money end
FluxAuctionRestock.VendorSource = function(id)
    if id >= 503 and id <= 507 then return true, 8, "fixture-tables", "fixture-gold-catalogue" end
    return false
end
FluxAuctionRestock.VendorTerms = function(id)
    if id >= 503 and id <= 507 then return 40, 5 end
end
FluxVendorAuto.GetLogisticsOffer = function(id)
    if not (merchantVisible and indexReady) or id < 503 or id > 507 then return nil end
    return {offerId = "vendor:fixture:" .. id, kind = "vendor", itemID = id, unit = "item",
        qualified = true, bundleSize = 5, bundlePrice = liveBundlePrice, availableUnits = available,
        marketContext = "vendor:fixture", locationKey = "vendor:fixture"}
end
FluxVendorAuto.BuyForLogistics = function(offer, amount, validate)
    local quantity = math.min(amount, 5)
    local cost = quantity / offer.bundleSize * offer.bundlePrice
    assert(quantity % offer.bundleSize == 0 and quantity <= available and money >= cost)
    assert(validate(offer, quantity, cost))
    assert(not validate(offer, quantity, cost + 1), "cannot issue a different total than authorized")
    money, available = money - cost, available - quantity
    vendorCalls[#vendorCalls + 1] = {itemID = offer.itemID, quantity = quantity}
    return true, nil, quantity
end
FC:On("ACQUISITION_CHANGED", function(_, status, entry, quantity)
    if status == "confirmed" then
        vendorReceipts[#vendorReceipts + 1] = {itemID = entry.itemID, quantity = quantity}
    end
end)

local function acceptVendor(item, quantity)
    local args = {itemID = item, intent = "supply", quantity = quantity,
        choices = {[item] = {source = "Vendor"}}}
    local projection = assert(FC.Logistics.Preview(args))
    assert(projection.requirements[1].kind == "vendor")
    return assert(FC.Queue.Accept(projection, function() return FC.Logistics.Preview(args) end))
end

local bundles = acceptVendor(503, 6)
assert(bundles.goal.autoBuyVendor and bundles.requirements[1].estimate and bundles.requirements[1].quantity == 10)
drain()
assert(#vendorCalls == 0)
merchantVisible = true
policy.NotifyChanged("merchant")
drain()
assert(#vendorCalls == 0, "opening before merchant data is ready cannot buy")
indexReady = true
local wasInCombat, combatLocked = InCombatLockdown, true
InCombatLockdown = function() return combatLocked end
assert(merchantIndexReady, "register for the owner's live index")
merchantIndexReady()
assert(#timers == 2, "the live index schedules vendor work and the coalesced HUD repaint")
table.remove(timers, 1)()
assert(#timers == 2 and #vendorCalls == 0, "temporarily blocked work schedules a delayed retry")
combatLocked = false
merchantIndexReady()
assert(#timers == 3, "fresh merchant data takes priority over a delayed retry without another HUD repaint")
table.remove(timers, 3)()
InCombatLockdown = wasInCombat
assert(#vendorCalls == 1, "purchase starts on the immediate index callback")
drain()
assert(#vendorCalls == 1 and vendorCalls[1].quantity == 5)
assert(bundles.requirements[1].remaining == 10, "submission is not a receipt")
available = 10
policy.NotifyChanged("merchant")
FC:Emit("INVENTORY_CHANGED")
drain()
assert(#vendorCalls == 1, "cannot issue another stack while the first receipt is unresolved")
liveBundlePrice = 41
stock[503], reports = 5, reports + 1
FC:Emit("INVENTORY_CHANGED")
drain()
assert(#vendorReceipts == 1 and vendorReceipts[1].quantity == 5 and bundles.requirements[1].remaining == 5)
assert(#vendorCalls == 1, "changed merchant terms cannot raise the accepted bundle price")
liveBundlePrice = 39
policy.NotifyChanged("merchant")
drain()
assert(#vendorCalls == 2 and vendorCalls[2].quantity == 5 and money == 321)
stock[503], reports = 10, reports + 1
FC:Emit("INVENTORY_CHANGED")
drain()
assert(bundles.status == "complete" and #vendorReceipts == 2)
assert(bundles.lastAcquisition.kind == "vendor" and bundles.lastAcquisition.status == "confirmed"
    and bundles.lastAcquisition.credited == 5 and bundles.lastAcquisition.addonVersion == "fixture-release"
    and bundles.lastAcquisition.clientBuild == "71037", "the verified vendor receipt and source must survive completion")

local whileOpen = acceptVendor(504, 5)
assert(FC.Queue.SetPaused(whileOpen.id, true))
drain()
assert(#vendorCalls == 2, "paused jobs cannot auto-buy")
assert(FC.Queue.SetPaused(whileOpen.id, false))
drain()
assert(#vendorCalls == 3 and vendorCalls[3].itemID == 504, "accepting work while open starts after resume")
merchantVisible = false
policy.NotifyChanged("merchant")
drain()
assert(whileOpen.acquisition and whileOpen.acquisition.status == "uncertain")
available, merchantVisible = 10, true
policy.NotifyChanged("merchant")
drain()
assert(#vendorCalls == 3, "reopening cannot replay an uncertain purchase")
assert(FC.Logistics.ResolveAcquisition(whileOpen))
FC:Emit("INVENTORY_CHANGED")
drain()
assert(whileOpen.requirements[1].autoBuyBlocked and #vendorCalls == 3, "a reviewed uncertainty still needs manual action")
assert(FC.Queue.Cancel(whileOpen.id))

local legacy = acceptVendor(505, 5)
legacy.goal.autoBuyVendor = nil
drain()
assert(#vendorCalls == 3, "migrated plans did not grant automatic spend")
assert(FC.Queue.Cancel(legacy.id))
local settings = FC.Logistics.GetSettings()
settings.autoBuyVendor = false
local off = acceptVendor(506, 5)
assert(not off.goal.autoBuyVendor)
settings.autoBuyVendor = true
drain()
assert(#vendorCalls == 3, "enabling the preference cannot rewrite an accepted authorization")
assert(FC.Queue.Cancel(off.id))

money = 1
local unfunded = acceptVendor(507, 5)
drain()
assert(not unfunded.acquisition and #vendorCalls == 3, "insufficient funds cannot reach the owner")
money = 400
stock[507], reports = 5, reports + 1
FC:Emit("INVENTORY_CHANGED")
drain()
assert(unfunded.status == "complete" and #vendorCalls == 3,
    "an unclaimed bag gain before dispatch satisfies a queued vendor acquisition")

local function closeMerchant()
    merchantVisible = false
    policy.NotifyChanged("merchant")
    drain()
end

local function showMerchant(quantity, gold, price)
    available, money, liveBundlePrice = quantity, gold, price
    merchantVisible = true
    policy.NotifyChanged("merchant")
    drain()
end

local function carry(itemID, quantity)
    stock[itemID], reports = quantity, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
    drain()
end

-- Manually obtained materials can replace an entire planned bundle.
closeMerchant()
local shorter = acceptVendor(505, 6)
carry(505, 2)
local purchasesBefore = #vendorCalls
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore + 1 and vendorCalls[#vendorCalls].quantity == 5)
carry(505, 7)
assert(shorter.status == "complete" and #vendorCalls == purchasesBefore + 1)
assert(shorter.requirements[1].remaining == 3 and shorter.lastAcquisition.credited == 5,
    "seven carried units meet the six allocated ones without pretending ten arrived")

-- A final partial demand can still use the authorized whole bundle.
closeMerchant()
local exactPack = acceptVendor(506, 5)
carry(506, 1)
purchasesBefore = #vendorCalls
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore + 1 and vendorCalls[#vendorCalls].quantity == 5)
carry(506, 5)
assert(exactPack.acquisition and exactPack.acquisition.credited == 4 and exactPack.status ~= "complete",
    "sufficient materials do not confirm a still-partial physical purchase")
carry(506, 6)
assert(exactPack.status == "complete" and exactPack.lastAcquisition.credited == 5)
assert(exactPack.requirements[1].vendorIssuedUnits == 5 and exactPack.requirements[1].vendorIssuedCopper == 40)

-- A second pack needs live stock, the remaining budget, and the accepted unit price.
closeMerchant()
carry(507, 0)
local twoPacks = acceptVendor(507, 6)
purchasesBefore = #vendorCalls
showMerchant(5, 40, 40)
carry(507, 5)
local missing, order = FC.Queue.AcquisitionRemaining(twoPacks, twoPacks.requirements[1])
assert(missing == 1 and order == 5 and #vendorCalls == purchasesBefore + 1 and twoPacks.status == "queued")
showMerchant(10, 0, 40)
assert(#vendorCalls == purchasesBefore + 1)
showMerchant(10, 400, 41)
assert(#vendorCalls == purchasesBefore + 1, "the remaining pack cannot exceed the approved quote")
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore + 2 and vendorCalls[#vendorCalls].quantity == 5)
carry(507, 10)
assert(twoPacks.status == "complete" and twoPacks.requirements[1].vendorIssuedCopper == 80)

-- A unit from the first bundle's surplus may already be allocated to a later craft.
closeMerchant()
carry(505, 0)
local previousCatalog = FC.Catalog.Snapshot
local root = {id = 805, professionId = 5, learned = true, completeness = "complete", yield = 1,
    characterKey = FC.state.characterKey, outputItemID = 5805, outputKind = "item",
    reagents = {{itemID = 5806, quantity = 1}, {itemID = 505, quantity = 1}}}
local intermediate = {id = 806, professionId = 5, learned = true, completeness = "complete", yield = 1,
    characterKey = FC.state.characterKey, outputItemID = 5806, outputKind = "item", reagents = {{itemID = 505, quantity = 4}}}
FC.Catalog.Snapshot = function()
    return {recipesById = {[805] = root, [806] = intermediate}, byOutput = {[5805] = {805}, [5806] = {806}},
        revision = 1, characterKey = FC.state.characterKey}
end
local nestedArgs = {recipeId = 805, quantity = 1, intent = "additional",
    choices = {[5806] = {source = "Make"}, [505] = {source = "Vendor"}}}
local function nestedPreview() return FC.Logistics.Preview(nestedArgs) end
local nested = assert(FC.Queue.Accept(nestedPreview(), nestedPreview))
assert(#nested.requirements == 1 and nested.requirements[1].quantity == 5 and #nested.tasks == 2)
local sourceNodes = nested.tree.children
assert(sourceNodes[1].surplusUsed > 0 or sourceNodes[2].surplusUsed > 0
    or sourceNodes[1].children[1] and sourceNodes[1].children[1].surplusUsed > 0,
    "the scenario must actually allocate an earlier bundle's surplus")
carry(505, 4)
purchasesBefore = #vendorCalls
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore + 1 and vendorCalls[#vendorCalls].quantity == 5)
carry(505, 9)
assert(#FC.Queue.GetRequirements(nested) == 0 and nested.reservations["505"] == 5
    and FC.Queue.CanProcess(nested, nested.tasks[1]) and not FC.Queue.CanProcess(nested, nested.tasks[2]),
    "the shared allocation must hold five real units across both crafts")
assert(FC.Queue.Cancel(nested.id))
FC.Catalog.Snapshot = previousCatalog

-- A ready replacement provider can resume approved work. Its physical bags
-- may update the shortage, but may not resolve an already issued old receipt.
local inventoryListener, handovers
local inventoryReliable = true
Flux.Inventory.Register = function(_, callback) inventoryListener = callback end
Flux.Inventory.IsReliable = function() return inventoryReliable end
assert(FC.InventoryAdapter.Start(function(status, context)
    if status.handover then handovers = (handovers or 0) + 1 end
    FC:Emit("INVENTORY_CHANGED", status, context)
end))
local function publishBags(itemID, quantity)
    stock[itemID], reports = quantity, reports + 1
    inventoryListener({regions = {bags = true}})
    drain()
end

closeMerchant()
publishBags(503, 0)
local newSyndicator = acceptVendor(503, 6)
assert(newSyndicator.goal.inventorySource == "builtin")
purchasesBefore = #vendorCalls
inventorySource, inventoryReliable = "syndicator", false
publishBags(503, 2)
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore and newSyndicator.requirements[1].remaining == 10)
inventoryReliable = true
publishBags(503, 2)
assert(handovers == 1 and #vendorCalls == purchasesBefore + 1
    and newSyndicator.requirements[1].remaining == 8 and newSyndicator.acquisition.source == "syndicator",
    "the ready replacement count is credited before a whole bundle can buy")
publishBags(503, 7)
assert(newSyndicator.status == "complete" and #vendorCalls == purchasesBefore + 1)

closeMerchant()
publishBags(505, 2)
local newBuiltin = acceptVendor(505, 5)
assert(newBuiltin.goal.inventorySource == "syndicator")
purchasesBefore = #vendorCalls
inventorySource, inventoryReliable = "builtin", false
publishBags(505, 0)
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore and newBuiltin.requirements[1].baseline == 2)
inventoryReliable = true
publishBags(505, 0)
assert(handovers == 2 and #vendorCalls == purchasesBefore + 1 and newBuiltin.requirements[1].baseline == 0,
    "a lower ready count rebases the next unissued purchase on the replacement provider")
publishBags(505, 5)
assert(newBuiltin.status == "complete" and #vendorCalls == purchasesBefore + 1)

closeMerchant()
publishBags(506, 0)
local issuedBeforeHandover = acceptVendor(506, 5)
purchasesBefore = #vendorCalls
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore + 1 and issuedBeforeHandover.acquisition.status == "issued")
inventorySource, inventoryReliable = "syndicator", false
publishBags(506, 5)
assert(issuedBeforeHandover.acquisition.status == "uncertain" and issuedBeforeHandover.acquisition.baselineInvalid)
inventoryReliable = true
publishBags(506, 5)
assert(handovers == 3 and #vendorCalls == purchasesBefore + 1 and issuedBeforeHandover.acquisition.credited == 0)
assert(FC.Logistics.ResolveAcquisition(issuedBeforeHandover))
publishBags(506, 5)
assert(issuedBeforeHandover.requirements[1].autoBuyBlocked and #vendorCalls == purchasesBefore + 1,
    "review cannot replay a vendor purchase whose source changed after issuance")
assert(FC.Queue.Cancel(issuedBeforeHandover.id))
closeMerchant()
inventorySource = "builtin"
publishBags(506, 5)

publishBags(503, 0)
local pendingDispatch = acceptVendor(503, 5)
purchasesBefore = #vendorCalls
local buyVendor = FluxVendorAuto.BuyForLogistics
local triedDispatch = false
FluxVendorAuto.BuyForLogistics = function(offer, amount, validate)
    triedDispatch = true
    inventorySource = "syndicator"
    assert(not validate(offer, amount, 40), "the provider must still match the count at native validation")
    return false, FC.L.offerChanged
end
showMerchant(10, 400, 40)
FluxVendorAuto.BuyForLogistics = buyVendor
assert(triedDispatch and #vendorCalls == purchasesBefore and not pendingDispatch.acquisition)
assert(FC.Queue.Cancel(pendingDispatch.id))
closeMerchant()
inventorySource = "builtin"
publishBags(503, 0)

local baseVendorOffer = FluxVendorAuto.GetLogisticsOffer
local livePack
FluxVendorAuto.GetLogisticsOffer = function(itemID)
    local offer = baseVendorOffer(itemID)
    if offer and livePack then offer.bundleSize = livePack end
    return offer
end
local flexiblePack = acceptVendor(503, 4)
purchasesBefore = #vendorCalls
livePack = 1
showMerchant(10, 400, 8)
assert(#vendorCalls == purchasesBefore + 1 and vendorCalls[#vendorCalls].quantity == 4
    and flexiblePack.requirements[1].vendorIssuedCopper == 32,
    "a vendor estimate must rematch a smaller pack within its unit and total limits")
publishBags(503, 4)
assert(flexiblePack.status == "complete")
closeMerchant()
publishBags(503, 0)

local oversizedPack = acceptVendor(503, 4)
livePack = 6
showMerchant(10, 400, 48)
assert(#vendorCalls == purchasesBefore + 1 and not oversizedPack.acquisition,
    "an actual pack must not exceed the accepted quantity or total cap")
closeMerchant()
assert(FC.Queue.Cancel(oversizedPack.id))
local overpricedPack = acceptVendor(503, 4)
livePack = 1
showMerchant(10, 400, 9)
assert(#vendorCalls == purchasesBefore + 1 and not overpricedPack.acquisition,
    "a smaller pack at a higher unit price must not spend inside the nominal total")
closeMerchant()
assert(FC.Queue.Cancel(overpricedPack.id))

livePack = 5
showMerchant(10, 400, 40)
local exactOfferJob = acceptVendor(503, 4)
livePack, liveBundlePrice = 1, 8
policy.NotifyChanged("merchant")
drain()
assert(#vendorCalls == purchasesBefore + 1 and not exactOfferJob.acquisition,
    "an accepted live offer must remain bound to its original pack")
closeMerchant()
assert(FC.Queue.Cancel(exactOfferJob.id))
FluxVendorAuto.GetLogisticsOffer = baseVendorOffer

local vendorVisitShifted = true
FluxVendorAuto.AllowsLogisticsAutomaticPurchase = function() return not vendorVisitShifted end
local shiftOpenJob = acceptVendor(503, 5)
purchasesBefore = #vendorCalls
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore and not shiftOpenJob.acquisition,
    "the owner Shift-open veto must suppress automatic queue purchases")
local manualEntry = assert(FC.Queue.GetRequirements(shiftOpenJob)[1])
assert(FC.Logistics.Acquire(manualEntry) and #vendorCalls == purchasesBefore + 1,
    "an explicit Process action can still buy the qualified vendor bundle")
publishBags(503, 5)
assert(shiftOpenJob.status == "complete")
closeMerchant()
publishBags(503, 0)
vendorVisitShifted = false
local ordinaryVisitJob = acceptVendor(503, 5)
showMerchant(10, 400, 40)
assert(#vendorCalls == purchasesBefore + 2 and ordinaryVisitJob.acquisition.status == "issued")
publishBags(503, 5)
assert(ordinaryVisitJob.status == "complete")
closeMerchant()
FluxVendorAuto.AllowsLogisticsAutomaticPurchase = nil
publishBags(503, 0)

for _, nativeClose in ipairs({false, true}) do
    closeMerchant()
    publishBags(503, 0)
    local retryJob = acceptVendor(503, 5)
    local buyer, attempts = FluxVendorAuto.BuyForLogistics, #vendorCalls
    local declined = 0
    FluxVendorAuto.BuyForLogistics = function(offer, quantity, validate)
        assert(validate(offer, quantity, 40))
        declined = declined + 1
        return false, "The first merchant did not submit the purchase."
    end
    showMerchant(5, 400, 40)
    assert(declined == 1 and not retryJob.acquisition and #vendorCalls == attempts)

    local previousReceipt = bundles.lastAcquisition
    merchantVisible = false
    if nativeClose then assert(nativeEvents.MERCHANT_CLOSED)() end
    policy.NotifyChanged("merchant")
    policy.NotifyCoverageChanged()
    if not nativeClose then drain() end

    FluxVendorAuto.BuyForLogistics = buyer
    showMerchant(5, 400, 40)
    assert(#vendorCalls == attempts + 1 and retryJob.acquisition and retryJob.acquisition.status == "issued",
        "a coverage update must not retain a declined purchase after the matching merchant reopens")
    assert(bundles.lastAcquisition == previousReceipt, "merchant closure must keep confirmed purchase evidence")
    publishBags(503, 5)
    assert(retryJob.status == "complete" and #vendorCalls == attempts + 1)
end
closeMerchant()
publishBags(503, 0)

local delayedReceipt = acceptVendor(503, 6)
local delayedBefore = #vendorCalls
showMerchant(5, 400, 40)
assert(#vendorCalls == delayedBefore + 1)
closeMerchant()
assert(delayedReceipt.acquisition and delayedReceipt.acquisition.status == "uncertain")
publishBags(503, 5)
assert(not delayedReceipt.acquisition and delayedReceipt.lastAcquisition.credited == 5
    and delayedReceipt.lastAcquisition.status == "confirmed",
    "a reliable bag receipt after merchant close must settle the original authorized purchase")
showMerchant(5, 400, 40)
assert(#vendorCalls == delayedBefore + 2 and delayedReceipt.acquisition,
    "a verified first receipt must release the temporary block and buy the remaining bundle once")
publishBags(503, 10)
assert(delayedReceipt.status == "complete" and #vendorCalls == delayedBefore + 2)
closeMerchant()
publishBags(503, 0)

-- Auction requests are scoped to the current accepted requirement and click.
-- The native budget is independent of both the estimate and observed mail.
merchantVisible = false
policy.NotifyChanged("merchant")
money = 1000000
local mailGeneration, submissions, calls = 0, 0, 0
local mail, predicted, ownerPending = {[508] = 3, [501] = 8}, {}, {[508] = 3, [501] = 8}
Flux.Inventory.GetSnapshotGeneration = function(region) return region == "mail" and mailGeneration or reports end
local inboxObserved = false
Flux.Inventory.Mail = {
    GetCount = function(id) return mail[id] or 0 end,
    HasObservedInbox = function() return inboxObserved end,
}
Flux.Inventory.Builtin = {Mail = {GetPredictedCount = function(id) return predicted[id] or 0 end}}
FluxAuctionRestock.GetPolicyCoverage = function(_, units, id)
    assert(units == "item")
    return ownerPending[id] or 0
end
local search, terminal
local function sameSearch(request, quantity)
    return search and request.jobId == search.request.jobId and request.id == search.request.id
        and request.planRevision == search.request.planRevision and request.kind == search.request.kind
        and request.quantity == search.request.quantity and request.itemID == search.request.itemID
        and request.maxTotalPrice == search.request.maxTotalPrice and quantity == search.quantity
end
FluxAuctionRestock.GetLogisticsState = function(request, quantity)
    if sameSearch(request, quantity) then
        return search.phase, nil, search.phase == "ready" and {quantity = quantity, totalCopper = quantity * 80} or nil
    end
end
FluxAuctionRestock.ExecuteLogistics = function(request, quantity, authorize, observe)
    calls = calls + 1
    assert(request.kind == "auction" and request.quantity > 0 and quantity <= request.quantity)
    assert(authorize(request, quantity))
    if not sameSearch(request, quantity) then
        search = {request = request, quantity = quantity, phase = "searching", observe = observe}
        return true, "searching"
    end
    assert(search.phase == "ready")
    local total = quantity * (request.maxUnitPrice - 20)
    assert(not authorize(request, quantity, quantity * request.maxUnitPrice + 1))
    assert(not authorize(request, quantity + 1, total), "the click quantity must bound the final authorization")
    if not authorize(request, quantity, total) then return false, "changed" end
    submissions = submissions + 1
    local receipt = {jobId = request.jobId, id = request.id, planRevision = request.planRevision,
        itemID = request.itemID, attemptID = submissions, quantity = quantity, totalCopper = total}
    search = nil
    observe("submitted", receipt)
    terminal = function(event) observe(event, receipt) end
    return true, "buying"
end
local function searchReady()
    search.phase = "ready"
    search.observe("state", {jobId = search.request.jobId, id = search.request.id, phase = "ready",
        itemID = search.request.itemID, planRevision = search.request.planRevision})
end
local function acceptAuction()
    local options = {itemID = 508, quantity = 5, intent = "supply"}
    return assert(FC.Queue.Accept(FC.Logistics.Preview(options), function() return FC.Logistics.Preview(options) end))
end
local auctionFirst, auctionSecond = acceptAuction(), acceptAuction()
local firstEntry, secondEntry = FC.Queue.GetRequirements(auctionFirst)[1], FC.Queue.GetRequirements(auctionSecond)[1]
assert(firstEntry and secondEntry and firstEntry.kind == "auction")
local unknown = FC.Logistics.GetAuctionNeed(firstEntry)
assert(not unknown.mailKnown and unknown.toBuy == nil and not unknown.ready)
assert(not FC.Logistics.BuyAuction(firstEntry, 1) and calls == 0, "uninitialized mail cannot authorize a purchase")
do
    local function previewSilk()
        return FC.Logistics.Preview({itemID = 4306, quantity = 60, intent = "supply"})
    end
    local oldQuotes = FC.MarketAdapter.QuoteItems
    FC.MarketAdapter.QuoteItems = function() return {[4306] = {unitPrice = 100, source = "fixture"}}, {} end
    local silk = assert(FC.Queue.Accept(previewSilk(), previewSilk))
    local silkEntry = assert(FC.Queue.GetRequirements(silk)[1])
    local physical, cached
    Flux.Inventory.Mail.GetObservedCount = function(itemID)
        if itemID == 4306 then return physical, cached end
    end
    for _, source in ipairs({"builtin", "syndicator"}) do
        inventorySource, physical, mail[4306] = source, nil, 60
        local projected = FC.Logistics.GetAuctionNeed(silkEntry)
        assert(projected.pendingMail == 0 and projected.pendingIncoming == 60 and not projected.mailKnown,
            "a predicted cache reduces orders without becoming physical inbox stock")
        if source == "syndicator" then
            cached = 60
            local pending = FC.Logistics.GetAuctionNeeds({silkEntry})[silkEntry]
            assert(pending.pendingIncoming == 60 and pending.pendingMail == 0 and not pending.mailKnown
                and FC.Logistics.GetAuctionSearchQuantity(silkEntry, pending) == 0
                and not FC.testRestockCraft.GetIncoming()[4306]
                and not FC.Logistics.BuyAuction(silkEntry, 1) and calls == 0,
                "cached Silk Cloth removes the duplicate search without creating physical mail or authorizing a buy")
        end
        physical, cached = 60, nil
        local shown = FC.Logistics.GetAuctionNeeds({silkEntry})[silkEntry]
        assert(shown.pendingMail == 60 and shown.pendingIncoming == 60 and not shown.mailKnown
            and FC.Logistics.GetAuctionSearchQuantity(silkEntry, shown) == 0,
            "each selected owner can show 60 physical Silk Cloth before full inbox qualification")
        assert(not FC.Logistics.BuyAuction(silkEntry, 1) and calls == 0)
    end
    silkEntry.requirement.auctionAwaiting, silkEntry.requirement.auctionMailboxBaseline = 60, 0
    silkEntry.requirement.auctionOwnerBaseline = 0
    local followOn = assert(FC.Queue.Accept(previewSilk(), previewSilk))
    local nextEntry = assert(FC.Queue.GetRequirements(followOn)[1])
    physical, cached = nil, 60
    local overlap = FC.Logistics.GetAuctionNeeds({silkEntry, nextEntry})
    assert(overlap[silkEntry].pendingIncoming == 60 and overlap[silkEntry].pendingMail == 0
        and overlap[nextEntry].pendingIncoming == 0, "cached stock cannot duplicate an accepted paid receipt")
    assert(FC.Queue.Cancel(followOn.id))
    physical, cached = 60, nil
    silkEntry.requirement.auctionOwnerBaseline = 8
    local shown = FC.Logistics.GetAuctionNeed(silkEntry)
    assert(shown.pendingMail == 60 and shown.pendingIncoming == 60,
        "physical Silk Cloth and the accepted confirmed payment represent one receipt")
    silkEntry.requirement.auctionAwaiting = 0
    assert(FC.Queue.Cancel(silk.id))
    FC.MarketAdapter.QuoteItems, Flux.Inventory.Mail.GetObservedCount = oldQuotes, nil
    inventorySource, mail[4306] = "builtin", nil
end
mailGeneration = 1
local coldMail, coldPending = mail, ownerPending
mail, ownerPending = {}, {}
assert(not FC.Logistics.GetAuctionNeed(firstEntry).mailKnown
    and not FC.Logistics.BuyAuction(firstEntry, 1) and calls == 0,
    "a published empty cache before inbox observation must not authorize purchases")
local ownerMethod = Flux.Inventory.Mail.HasObservedInbox
Flux.Inventory.Mail.HasObservedInbox = nil
local oldOwner = FC.Logistics.GetAuctionNeed(firstEntry)
assert(not oldOwner.mailKnown and oldOwner.mailBlocker == FC.L.auctionMailboxOwner,
    "the queue should distinguish an older owner from an unread inbox")
Flux.Inventory.Mail.HasObservedInbox = ownerMethod
inboxObserved = true
assert(FC.Logistics.GetAuctionNeed(firstEntry).mailKnown
    and FC.Logistics.GetAuctionNeed(firstEntry).toBuy == 5, "a successfully observed empty inbox is known")
mail, ownerPending = coldMail, coldPending
local need = FC.Logistics.GetAuctionNeed(firstEntry)
assert(need.remaining == 5 and need.pendingMail == 3 and need.toBuy == 2 and need.maxUnitPrice == 100)
assert(FC.testRestockCraft.GetIncoming()[508] == nil, "ordinary inbox coverage cannot activate the HUD")
assert(FC.Logistics.GetAuctionNeed(secondEntry).toBuy == 5, "two matching jobs cannot both use one mailbox count")
local accepted, phase = FC.Logistics.BuyAuction(firstEntry, 1)
assert(accepted and phase == "searching" and submissions == 0)
searchReady()
inboxObserved = false
assert(not FC.Logistics.BuyAuction(firstEntry, 1) and submissions == 0,
    "an existing quote must wait when inbox proof has been withdrawn")
inboxObserved = true
local ready = FC.Logistics.GetAuctionNeed(firstEntry, 1)
assert(ready.ready and ready.quote.totalCopper == 80 and not FC.Logistics.GetAuctionNeed(firstEntry, 2).ready)
money = 0
assert(not FC.Logistics.BuyAuction(firstEntry, 1) and submissions == 0, "funds require live revalidation")
money = 1000000
accepted, phase = FC.Logistics.BuyAuction(firstEntry, 1)
assert(accepted and phase == "buying" and submissions == 1)
assert(not FC.Logistics.BuyAuction(secondEntry, 1) and calls == 3, "another job cannot race an issued auction purchase")
assert(FC.testRestockCraft.GetIncoming()[508] == nil, "submission alone cannot activate the HUD")
do
    local receiptRefreshesBefore = FC.receiptRefreshes
    terminal("confirmed")
    terminal("confirmed")
    drain()
    assert(FC.receiptRefreshes == receiptRefreshesBefore + 1 and FC.testRestockCraft.GetIncoming()[508] == 1,
        "a confirmed shopping purchase activates the HUD once even before physical mail")
end
inboxObserved = false
assert(FC.testRestockCraft.GetIncoming()[508] == 1, "the paid receipt survives a temporary loss of inbox proof")
inboxObserved = true
need = FC.Logistics.GetAuctionNeed(firstEntry)
assert(need.remaining == 5 and need.pendingMail == 3 and need.pendingIncoming == 4 and need.toBuy == 1
    and need.maxTotalPrice == 420, "one confirmed receipt changes incoming coverage and budget immediately")
mail[508], predicted[508], ownerPending[508] = 4, 1, 4
FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
need = FC.Logistics.GetAuctionNeed(firstEntry)
assert(need.pendingMail == 3 and need.pendingIncoming == 4 and need.toBuy == 1,
    "the provider's predicted inventory is not a second purchase or observed mail")
predicted[508] = 0
assert(FC.Logistics.GetAuctionNeed(firstEntry).pendingMail == 4)
assert(FC.Logistics.BuyAuction(firstEntry, 1))
searchReady()
assert(FC.Logistics.BuyAuction(firstEntry, 1))
local secondAttempt = assert(auctionFirst.acquisition)
mail[508], ownerPending[508], stock[508], reports = 3, 3, 1, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
need = FC.Logistics.GetAuctionNeed(firstEntry)
assert(need.remaining == 4 and need.pendingIncoming == 3 and need.toBuy == 1
    and FC.Logistics.GetAuctionNeed(secondEntry).remaining == 5)
assert(auctionFirst.acquisition == secondAttempt, "delivery of the first purchase cannot settle the second attempt")
assert(FC.testRestockCraft.GetIncoming()[508] == nil, "carried confirmation retires the first receipt")
terminal("failed")
assert(FC.testRestockCraft.GetIncoming()[508] == nil, "a failed purchase supplies no receipt")
assert(not auctionFirst.acquisition and FC.Logistics.GetAuctionNeed(firstEntry).maxTotalPrice == 420)
mail[508], ownerPending[508], stock[508], reports = 1, 1, 3, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
need = FC.Logistics.GetAuctionNeed(firstEntry)
assert(need.remaining == 2 and need.pendingMail == 1 and need.toBuy == 1
    and FC.Logistics.GetAuctionNeed(secondEntry).remaining == 5,
    "already-pending mail counts as carried only once, for the first eligible job on collection")

-- A restock job's accepted shortage already excluded older owner inbox stock.
-- Only this job's confirmed incoming receipt may overlap owner coverage.
local tierEntry = tierRequirements[1]
need = FC.Logistics.GetAuctionNeed(tierEntry)
assert(need.remaining == 20 and need.pendingMail == 0 and need.toBuy == 20)
assert(FC.Logistics.BuyAuction(tierEntry, 5))
searchReady()
assert(FC.Logistics.BuyAuction(tierEntry, 5))
terminal("confirmed")
assert(policy.GetDemand("tier:healPotion").covered == 28)
mail[501], predicted[501], ownerPending[501] = 13, 5, 13
FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
assert(policy.GetDemand("tier:healPotion").covered == 28 and policy.DemandForEntry(row, 13).covered == 28)
need = FC.Logistics.GetAuctionNeed(tierEntry)
assert(need.pendingMail == 0 and need.pendingIncoming == 5 and need.toBuy == 15)
assert(FC.Logistics.BuyAuction(tierEntry, 1))
searchReady()
assert(FC.Logistics.BuyAuction(tierEntry, 1))
terminal("uncertain")
assert(not FC.Logistics.BuyAuction(tierEntry, 1))
assert(FC.Logistics.ResolveAcquisition(tierJob))
assert(not FC.Logistics.BuyAuction(tierEntry, 1), "review cannot retry an unconfirmed purchase from the old budget")

local handoverPlan = {itemID = 509, quantity = 10, intent = "supply"}
local handoverJob = assert(FC.Queue.Accept(FC.Logistics.Preview(handoverPlan), function()
    return FC.Logistics.Preview(handoverPlan)
end))
local handoverEntry = assert(FC.Queue.GetRequirements(handoverJob)[1])
assert(FC.Logistics.BuyAuction(handoverEntry, 3))
searchReady()
assert(FC.Logistics.BuyAuction(handoverEntry, 3))
terminal("confirmed")
mail[509], predicted[509], ownerPending[509] = 3, 3, 3
FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
assert(FC.Logistics.GetAuctionNeed(handoverEntry).toBuy == 7)

inventorySource, predicted[509], mailGeneration = "syndicator", 0, mailGeneration + 1
FC:Emit("INVENTORY_CHANGED", {handover = true}, {regions = {bags = true, mail = true}})
local handedOver = FC.Logistics.GetAuctionNeed(handoverEntry)
assert(handedOver.pendingMail == 3 and handedOver.pendingIncoming == 3 and handedOver.toBuy == 7,
    "the selected provider must not count its copy of a confirmed receipt a second time")

FluxVendorAuto.GetRestockTargetItems = function()
    return {{itemID = 510, target = 3, name = "Fixture reverse handover", bagCount = stock[510] or 0}}
end
policy.NotifyChanged()
assert(policy.GetDemand("item:510").uncovered == 3)
assert(policy.Request("item:510", "restock", {manual = true, source = "auction"}))
local deliveryJob = FC.Queue.GetJobs()[#FC.Queue.GetJobs()]
local deliveryEntry = assert(FC.Queue.GetRequirements(deliveryJob)[1])
assert(deliveryJob.goal.demandId == "item:510" and deliveryEntry.quantity == 3)
assert(FC.Logistics.BuyAuction(deliveryEntry, 3))
searchReady()
assert(FC.Logistics.BuyAuction(deliveryEntry, 3))
terminal("confirmed")

inventorySource, mail[510], ownerPending[510], mailGeneration = "builtin", 3, 3, mailGeneration + 1
FC:Emit("INVENTORY_CHANGED", {handover = true}, {regions = {bags = true, mail = true}})
local delivery = FC.Logistics.GetAuctionNeed(deliveryEntry)
assert(delivery.pendingMail == 3 and delivery.pendingIncoming == 3 and policy.GetDemand("item:510").covered == 3,
    "a restock receipt must overlap the built-in inbox after switching from Syndicator")

stock[510], mail[510], ownerPending[510], reports, mailGeneration = 3, 0, 0, reports + 1, mailGeneration + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
assert(deliveryJob.status == "complete" and policy.GetDemand("item:510").covered == 0,
    "carried delivery from the replacement provider must settle the same restock receipt")

local function verifyMatchingOrders(itemID, reverse)
    local args = {itemID = itemID, quantity = 5, intent = "supply"}
    local function acceptOrder()
        local job = assert(FC.Queue.Accept(FC.Logistics.Preview(args), function() return FC.Logistics.Preview(args) end))
        return assert(FC.Queue.GetRequirements(job)[1])
    end
    local function buyThree(entry)
        assert(FC.Logistics.BuyAuction(entry, 3))
        searchReady()
        assert(FC.Logistics.BuyAuction(entry, 3))
        terminal("confirmed")
    end
    local first, second = acceptOrder(), acceptOrder()
    local olderReceipt, newerReceipt = first, second
    if reverse then olderReceipt, newerReceipt = second, first end

    buyThree(olderReceipt)
    mail[itemID], ownerPending[itemID], mailGeneration = 3, 3, mailGeneration + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
    assert(FC.Logistics.GetAuctionNeed(olderReceipt).toBuy == 2
        and FC.Logistics.GetAuctionNeed(newerReceipt).toBuy == 5)

    buyThree(newerReceipt)
    mail[itemID], ownerPending[itemID], mailGeneration = 6, 6, mailGeneration + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
    for _, entry in ipairs({first, second}) do
        local status = FC.Logistics.GetAuctionNeed(entry)
        assert(status.remaining == 5 and status.pendingMail == 3 and status.pendingIncoming == 3 and status.toBuy == 2)
    end

    stock[itemID], mail[itemID], ownerPending[itemID] = 3, 3, 3
    reports, mailGeneration = reports + 1, mailGeneration + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
    local carried, awaiting = FC.Logistics.GetAuctionNeed(first), FC.Logistics.GetAuctionNeed(second)
    assert(carried.remaining == 2 and carried.pendingMail == 0 and carried.pendingIncoming == 0 and carried.toBuy == 2
        and awaiting.remaining == 5 and awaiting.pendingMail == 3 and awaiting.pendingIncoming == 3 and awaiting.toBuy == 2,
        "collecting one of two receipts must not reassign the second receipt as unowned mailbox stock")

    stock[itemID], mail[itemID], ownerPending[itemID] = 6, 0, 0
    reports, mailGeneration = reports + 1, mailGeneration + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
    for _, entry in ipairs({first, second}) do
        local status = FC.Logistics.GetAuctionNeed(entry)
        assert(status.remaining == 2 and status.pendingIncoming == 0 and status.toBuy == 2)
    end
end

verifyMatchingOrders(511, false)
verifyMatchingOrders(512, true)

-- Editing a craft cannot leave paid ingredients on a replaced job while the
-- replacement offers to buy the same units before the inbox has caught up.
local recipeID, ingredient, output = 8124, 513, 514
local depletionRecipeID, depletionIngredient, depletionOutput = 8125, 515, 516
local function oneReagentRecipe(id, reagentID, outputID)
    return {id = id, professionId = 123, outputItemID = outputID, outputKind = "item",
        yield = 1, learned = true, characterKey = FC.state.characterKey,
        completeness = "complete", reagents = {{itemID = reagentID, quantity = 1}}}
end
local recipes = {
    [recipeID] = oneReagentRecipe(recipeID, ingredient, output),
    [depletionRecipeID] = oneReagentRecipe(depletionRecipeID, depletionIngredient, depletionOutput),
}
FC.Catalog.Snapshot = function()
    return {recipesById = recipes, byOutput = {[output] = {recipeID}, [depletionOutput] = {depletionRecipeID}},
        revision = 2, characterKey = FC.state.characterKey}
end
FC.MarketAdapter.QuoteItems = function()
    return {[ingredient] = 100, [output] = 300, [depletionIngredient] = 100, [depletionOutput] = 300}, {}
end

local craft = {recipeId = recipeID, quantity = 5, intent = "additional"}
local craftJob = assert(FC.Queue.Accept(FC.Logistics.Preview(craft), function() return FC.Logistics.Preview(craft) end))
local craftEntry = assert(FC.Queue.GetRequirements(craftJob)[1])
assert(craftJob.rootRecipeId == recipeID and craftEntry.itemID == ingredient and craftEntry.quantity == 5)
assert(not FC.testRestockCraft.GetReady(), "a queue job with missing materials is not a ready follow-up")
do
    local followup = FC.testRestockCraft
    FC.Execution.GetReadyRestockCraft = function()
        return craftJob.tasks[1], 2, craftJob
    end
    FC.Execution.ProcessNext = function(job, task)
        return job == craftJob and task == craftJob.tasks[1]
    end
    local selection = assert(followup.GetReady(), "a ready queued craft does not require a previous auction purchase")
    assert(selection.itemID == output and selection.quantity == 2 and followup.Process(selection))
    FC.Execution.GetReadyRestockCraft, FC.Execution.ProcessNext = nil, nil
end
do
    local followup, task = FC.testRestockCraft, craftJob.tasks[1]
    local recovery = {evidence = {}, taskId = task.taskId, quantity = 2, remainingExecutions = 2, outputCount = 2}
    local originalJob, originalTask = craftJob.status, task.status
    local originalProcessClick = FC.Execution.ProcessClick
    local resumed, processed = 0, 0
    craftJob.status, task.status = "uncertain", "uncertain"
    FC.Execution.GetCarriedOutputRecovery = function(job)
        if job == craftJob and job.status == "uncertain" then return recovery end
    end
    FC.Execution.ResumeWithCarriedOutput = function(job, selected)
        assert(job == craftJob and selected == recovery)
        resumed = resumed + 1
        job.status, task.status = "queued", "pending"
        return true, "Two carried", task
    end
    FC.Execution.GetReadyRestockCraft = function(job)
        if job == craftJob and task.status == "pending" then return task, 2, craftJob end
    end
    FC.Execution.ProcessClick = function(job, selected, forRestock)
        assert(job == craftJob and selected == task and forRestock)
        processed = processed + 1
        return true, "Process the remaining two"
    end
    local shown = assert(followup.GetReady())
    assert(shown.resume and shown.carriedOutput == 2 and shown.remainingOutput == 2 and shown.quantity == 2)
    recovery.outputCount = 3
    assert(not followup.Process(shown) and resumed == 0 and processed == 0,
        "a changed carried observation must repaint the exact resume selection")
    recovery.outputCount = 2
    assert(followup.Process(followup.GetReady()) and resumed == 1 and processed == 1,
        "one HUD click counts the accepted carried output and dispatches only the ready remainder")
    craftJob.status, task.status = originalJob, originalTask
    FC.Execution.GetReadyRestockCraft, FC.Execution.GetCarriedOutputRecovery, FC.Execution.ResumeWithCarriedOutput = nil, nil, nil
    FC.Execution.ProcessClick = originalProcessClick
end
assert(FC.Logistics.BuyAuction(craftEntry, 3))
searchReady()
assert(FC.Logistics.BuyAuction(craftEntry, 3))
terminal("confirmed")
local shopping = FC.Logistics.GetAuctionNeed(craftEntry)
assert(shopping.pendingIncoming == 3 and shopping.toBuy == 2 and shopping.maxTotalPrice == 260)
local revise = {recipeId = recipeID, quantity = 6, intent = "additional", replaces = craftJob}
assert(not FC.Queue.CanReplace(craftJob))
assert(not FC.Queue.Accept(FC.Logistics.Preview(revise), function() return FC.Logistics.Preview(revise) end, craftJob))
assert(craftJob.status == "queued" and FC.Logistics.GetAuctionNeed(craftEntry).toBuy == 2)

mail[ingredient], ownerPending[ingredient], mailGeneration = 3, 3, mailGeneration + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
assert(not FC.Queue.CanReplace(craftJob), "observing an inbox attachment must not turn it into carried inventory")
stock[ingredient], mail[ingredient], ownerPending[ingredient], reports, mailGeneration = 3, 0, 0, reports + 1, mailGeneration + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
do
    local restockCraft = FC.testRestockCraft
    local restockCraftBatch, processedRestock = 5, 0
    local directReady
    FC.Execution.GetReadyRestockCraft = function()
        if stock[ingredient] == 5 then return craftJob.tasks[1], restockCraftBatch, craftJob, directReady end
    end
    FC.Execution.ProcessNext = function(candidate, task)
        assert(candidate == craftJob and task == craftJob.tasks[1])
        processedRestock = processedRestock + 1
        return true
    end
    assert(not restockCraft.GetReady(), "a paid material does not authorize a craft without enough carried inputs")
    stock[ingredient] = 5
    local readyCraft = assert(restockCraft.GetReady())
    assert(readyCraft.jobId == craftJob.id and readyCraft.itemID == output and readyCraft.quantity == 5)
    restockCraftBatch = 4
    assert(not restockCraft.Process(readyCraft) and processedRestock == 0, "the one-button action must recheck the previewed batch")
    assert(restockCraft.Process(assert(restockCraft.GetReady())) and processedRestock == 1)
    local displayed
    FC.Execution.ProcessNext = function(candidate, task)
        assert(candidate == craftJob and task == craftJob.tasks[1])
        return true, "Native Create", candidate, "native_click"
    end
    FC.UI = {ShowNativeCraft = function(message, acceptedJob)
        assert(message == "Native Create")
        displayed = acceptedJob
        return "Batch verified"
    end}
    local started, feedback = restockCraft.Process(assert(restockCraft.GetReady()))
    assert(started and displayed == craftJob and feedback == "Batch verified",
        "the HUD passes its exact accepted job to the shared Flowcraft presentation")
    local processClick = FC.Execution.ProcessClick
    local directClicks = 0
    FC.Execution.ProcessClick = function(candidate, task)
        assert(candidate == craftJob and task == craftJob.tasks[1])
        directClicks = directClicks + 1
        return true, "Started from the HUD", craftJob
    end
    local oldDisplay = assert(restockCraft.GetReady())
    directReady = true
    assert(restockCraft.Process(oldDisplay) and directClicks == 0,
        "the old native caption must not start a direct craft")
    local directDisplay = assert(restockCraft.GetReady())
    assert(directDisplay.direct and restockCraft.Process(directDisplay) and directClicks == 1,
        "the direct HUD action starts the displayed step using the physical click route")
    directReady = false
    assert(not restockCraft.Process(directDisplay) and directClicks == 1,
        "a stale direct HUD action must be refreshed after a client denial")
    local prepared, retried = nil, 0
    FC.UI.GetPreparedNativeCraft = function() return prepared end
    FC.Execution.HasNativeCraftPending = function() return true end
    FC.Execution.GetReadyRestockCraft = function(_, retry)
        if retry then return craftJob.tasks[1], 2, craftJob, false, true end
    end
    FC.Execution.ProcessNext = function(candidate, task, forRestock)
        assert(candidate == craftJob and task == craftJob.tasks[1] and forRestock)
        retried = retried + 1
        return true, "Native Create", candidate, "native_click"
    end
    local missingNativeControl = assert(restockCraft.GetReady(),
        "the companion reoffers the armed queue craft when the native control is unavailable")
    assert(missingNativeControl.quantity == 2 and not missingNativeControl.direct)
    prepared = {itemID = output, quantity = 2, outputQuantity = 2}
    assert(restockCraft.GetPreparedNativeCraft() == prepared and not restockCraft.GetReady()
        and not restockCraft.Process(missingNativeControl) and retried == 0,
        "a recovered native Create action invalidates the old prepare click")
    prepared = nil
    assert(restockCraft.Process(assert(restockCraft.GetReady())) and retried == 1 and directClicks == 1,
        "retrying an unavailable native form follows preparation without submitting a direct craft")
    FC.Execution.HasNativeCraftPending = nil
    FC.Execution.ProcessClick = processClick
    FC.UI = nil
    stock[ingredient] = 3
    FC.Execution.GetReadyRestockCraft, FC.Execution.ProcessNext = nil, nil
end
assert(FC.Queue.CanReplace(craftJob))
local revised = assert(FC.Queue.Accept(FC.Logistics.Preview(revise), function() return FC.Logistics.Preview(revise) end, craftJob))
local edited = assert(FC.Queue.GetRequirements(revised)[1])
assert(craftJob.status == "replaced" and revised.replaces == craftJob.id)
assert(craftEntry.requirement.auctionSpent == 240 and craftEntry.requirement.auctionAwaiting == 0
    and craftJob.lastAcquisition.status == "confirmed" and craftJob.lastAcquisition.addonVersion == "fixture-release"
    and craftJob.lastAcquisition.clientBuild == "71037", "replacing the plan must preserve the paid purchase and its source")
assert(revised.summary.requested == 6 and revised.reservations[tostring(ingredient)] == 3
    and FC.Logistics.GetAuctionNeed(edited).toBuy == 3,
    "the revised craft must use the three paid ingredients after they are carried")

do
    local target = FC.target
    FC.target = "forever"
    local owned = revised.reservations[tostring(ingredient)]
    assert(FC.Logistics.BuyAuction(edited, 2))
    searchReady()
    assert(FC.Logistics.BuyAuction(edited, 2))
    local recipe = recipes[recipeID]
    recipe.supersededByRecipeID, recipe.blockedReason = recipeID + 1, FC.L.clients.supersededRank
    FC.Queue.InvalidateRecipes(FC.Catalog.Snapshot())
    assert(revised.acquisition.status == "issued" and revised.reservations[tostring(ingredient)] == owned
        and revised.status == "queued", "an issued receipt keeps its original job and observations until confirmation")
    terminal("confirmed")
    assert(revised.status == "invalidated" and revised.invalidationReason == FC.L.clients.supersededRank
        and #FC.Queue.GetRequirements(revised) == 0 and not next(revised.reservations)
        and edited.requirement.auctionAwaiting == 2 and edited.requirement.auctionSpent == 160
        and revised.auctionReceiptsReleased and revised.lastAcquisition.status == "confirmed",
        "invalidation releases the paid receipt to shared incoming stock and preserves its exact purchase history")
    assert(not FC.Logistics.BuyAuction(edited, 1), "the stale shopping row cannot submit another purchase")
    recipe.supersededByRecipeID, recipe.blockedReason = nil, nil
    FC.target = target
end

-- A separate craft can consume the old bag stock while an acknowledged order
-- is in the mail. Collecting the receipt must still credit the new bag units.
local function acceptDepletionCraft(quantity)
    local planArgs = {recipeId = depletionRecipeID, quantity = quantity, intent = "additional"}
    return assert(FC.Queue.Accept(FC.Logistics.Preview(planArgs), function() return FC.Logistics.Preview(planArgs) end))
end
stock[depletionIngredient] = 10
local stockedCraft = acceptDepletionCraft(10)
assert(stockedCraft.reservations[tostring(depletionIngredient)] == 10)
local waitingCraft = acceptDepletionCraft(5)
local waitingEntry = assert(FC.Queue.GetRequirements(waitingCraft)[1])
assert(waitingEntry.itemID == depletionIngredient and waitingEntry.quantity == 5 and waitingEntry.requirement.baseline == 10)
assert(FC.Logistics.BuyAuction(waitingEntry, 3))
searchReady()
assert(FC.Logistics.BuyAuction(waitingEntry, 3))
terminal("confirmed")

local stockedTask = stockedCraft.tasks[1]
assert(FC.Queue.Begin(stockedCraft, stockedTask, {beforeOutput = 0, batch = 10}))
FC.Queue.CraftEvent(stockedCraft, stockedTask, 10)
assert(FC.Queue.Reconcile(stockedCraft, stockedTask, 10) and stockedCraft.status == "complete")
stock[depletionIngredient], reports = 0, reports + 1
FC:Emit("INVENTORY_CHANGED", {handover = true}, {regions = {bags = true}})
assert(waitingEntry.requirement.baseline == 10, "the provider handover notification cannot rebase the queue")
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(waitingEntry.requirement.baseline == 0, "observed material consumption must allow a later receipt to reconcile")

stock[depletionIngredient], reports = 3, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
local delivered = FC.Logistics.GetAuctionNeed(waitingEntry)
assert(delivered.remaining == 2 and delivered.pendingIncoming == 0 and delivered.toBuy == 2
    and waitingCraft.reservations[tostring(depletionIngredient)] == 3,
    "the new three units must be available to the paid queue after its original inventory was consumed")

-- Cancelling planned work releases its claim on a purchase, not the purchase
-- itself. Other work can use the in-flight items once before the inbox sees them.
local cancelledItem, cancelledRestockItem, mixedReceiptsItem = 517, 518, 519
FC.MarketAdapter.QuoteItems = function()
    return {[cancelledItem] = 100, [cancelledRestockItem] = 100, [mixedReceiptsItem] = 100}, {}
end
local function acceptSupply(itemID)
    local args = {itemID = itemID, quantity = 5, intent = "supply"}
    return assert(FC.Queue.Accept(FC.Logistics.Preview(args), function() return FC.Logistics.Preview(args) end))
end
local function acknowledgeThree(entry)
    assert(FC.Logistics.BuyAuction(entry, 3))
    searchReady()
    assert(FC.Logistics.BuyAuction(entry, 3))
    terminal("confirmed")
end
local cancelled = acceptSupply(cancelledItem)
local cancelledEntry = assert(FC.Queue.GetRequirements(cancelled)[1])
acknowledgeThree(cancelledEntry)
assert(FC.Queue.Cancel(cancelled.id) and #FC.Queue.GetRequirements(cancelled) == 0)
assert(FC.testRestockCraft.GetIncoming()[cancelledItem] == 3,
    "a paid receipt remains visible after the associated plan is cancelled")
local nextJob, laterJob = acceptSupply(cancelledItem), acceptSupply(cancelledItem)
local nextEntry = assert(FC.Queue.GetRequirements(nextJob)[1])
local laterEntry = assert(FC.Queue.GetRequirements(laterJob)[1])
local nextNeed = FC.Logistics.GetAuctionNeed(nextEntry)
assert(nextNeed.pendingMail == 0 and nextNeed.pendingIncoming == 3 and nextNeed.toBuy == 2,
    "a new job must account for a cancelled job's acknowledged purchase before the inbox publishes it")
assert(FC.Logistics.GetAuctionNeed(laterEntry).toBuy == 5, "the released purchase must be allocated only once")

assert(FC.Queue.Initialize(FC.state.char))
assert(FC.Logistics.GetAuctionNeed(nextEntry).toBuy == 2, "confirmed units must survive a reload")
assert(FC.testRestockCraft.GetIncoming()[cancelledItem] == 3, "the detached HUD receipt survives a reload")
mail[cancelledItem], ownerPending[cancelledItem], mailGeneration = 2, 2, mailGeneration + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
nextNeed = FC.Logistics.GetAuctionNeed(nextEntry)
assert(nextNeed.pendingMail == 2 and nextNeed.pendingIncoming == 3 and nextNeed.toBuy == 2,
    "published mail must not duplicate the released purchase")

stock[cancelledItem], mail[cancelledItem], ownerPending[cancelledItem], reports = 2, 0, 0, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
nextNeed = FC.Logistics.GetAuctionNeed(nextEntry)
assert(nextNeed.remaining == 3 and nextNeed.pendingIncoming == 1 and nextNeed.toBuy == 2)
assert(FC.testRestockCraft.GetIncoming()[cancelledItem] == 1, "a partial collection leaves the remaining paid units")
assert(FC.Logistics.GetAuctionNeed(laterEntry).toBuy == 5)
stock[cancelledItem], reports = 3, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
nextNeed = FC.Logistics.GetAuctionNeed(nextEntry)
assert(nextNeed.remaining == 2 and nextNeed.pendingIncoming == 0 and nextNeed.toBuy == 2)
assert(FC.testRestockCraft.GetIncoming()[cancelledItem] == nil, "the final carried units retire detached work")
assert(cancelled.status == "cancelled" and cancelledEntry.requirement.auctionAwaiting == 0
    and cancelledEntry.requirement.auctionSpent == 240 and cancelled.lastAcquisition.status == "confirmed",
    "settling a released receipt must preserve paid spend and cancelled work")
cancelled.auctionReceiptsReleased, cancelledEntry.requirement.auctionAwaiting = nil, 3
assert(FC.testRestockCraft.GetIncoming()[cancelledItem] == nil, "old closed records cannot resurrect stale reminders")
assert(FC.Logistics.GetAuctionNeed(nextEntry).toBuy == 2,
    "older closed history without live receipt tracking must not resurrect a purchase that may have arrived")
cancelled.status = "invalidated"
assert(FC.Queue.Cancel(cancelled.id) and not cancelled.auctionReceiptsReleased
    and FC.Logistics.GetAuctionNeed(nextEntry).toBuy == 2,
    "removing an archived invalidated job must not reactivate its old receipt")

local mixedCancelled = acceptSupply(mixedReceiptsItem)
local mixedCancelledEntry = assert(FC.Queue.GetRequirements(mixedCancelled)[1])
acknowledgeThree(mixedCancelledEntry)
assert(FC.Queue.Cancel(mixedCancelled.id))
local mixedActive = acceptSupply(mixedReceiptsItem)
local mixedActiveEntry = assert(FC.Queue.GetRequirements(mixedActive)[1])
assert(FC.Logistics.BuyAuction(mixedActiveEntry, 2))
searchReady()
assert(FC.Logistics.BuyAuction(mixedActiveEntry, 2))
terminal("confirmed")
stock[mixedReceiptsItem], reports = 2, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(mixedActiveEntry.requirement.auctionAwaiting == 0 and mixedCancelledEntry.requirement.auctionAwaiting == 3,
    "one bag gain cannot clear both an active and a released receipt")
assert(FC.Logistics.GetAuctionNeed(mixedActiveEntry).toBuy == 0)
stock[mixedReceiptsItem], reports = 5, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(mixedActive.status == "complete" and mixedCancelledEntry.requirement.auctionAwaiting == 0)

local restockRow = {itemID = cancelledRestockItem, target = 5, name = "Cancelled restock purchase"}
FluxVendorAuto.GetRestockTargetItems = function()
    restockRow.bagCount = stock[cancelledRestockItem] or 0
    return {restockRow}
end
policy.NotifyChanged()
local restockID = "item:" .. cancelledRestockItem
assert(policy.Request(restockID, "restock", {manual = true, source = "auction"}))
local restock = FC.Queue.GetJobs()[#FC.Queue.GetJobs()]
acknowledgeThree(assert(FC.Queue.GetRequirements(restock)[1]))
assert(FC.Queue.Cancel(restock.id))
assert(policy.GetDemand(restockID).uncovered == 2)
mail[cancelledRestockItem], ownerPending[cancelledRestockItem], mailGeneration = 3, 3, mailGeneration + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
assert(policy.GetDemand(restockID).uncovered == 2, "owner coverage must count published mail only once")
stock[cancelledRestockItem], mail[cancelledRestockItem], ownerPending[cancelledRestockItem], reports = 3, 0, 0, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
assert(policy.GetDemand(restockID).uncovered == 2 and policy.GetDemand(restockID).covered == 0,
    "carried units replace released receipt coverage without reserving them to a cancelled job")

print("FluxUI and FluxLogistics restock, acquisition, stock coverage and deduplication fixtures passed")

assert(FC.Queue.Initialize({}))
policy.NotifyCoverageChanged()
FluxVendorAuto.GetRestockTargetItems = function() return {} end
FluxVendorAuto.GetLogisticsOffer = nil
Flux.Inventory.Mail = nil
local bankRecipe = {id = 47000, professionId = 1, outputItemID = 47001, outputKind = "item",
    yield = 1, learned = true, completeness = "complete", characterKey = FC.state.characterKey,
    reagents = {{itemID = 501, quantity = 3}}}
FC.Catalog.Snapshot = function()
    return {recipesById = {[bankRecipe.id] = bankRecipe}, byOutput = {}, revision = 1}
end
FC.MarketAdapter.QuoteItems = function() return {[501] = {itemID = 501, unitPrice = 10}}, {} end
stock[501], petBank, opened, issued = 0, 4, false, 0
local function recipePreview() return FC.Logistics.Preview({recipeId = bankRecipe.id, quantity = 1}) end
local queuedRecipe = assert(FC.Queue.Accept(recipePreview(), recipePreview))
local original = assert(FC.Queue.GetRequirements(queuedRecipe)[1])
assert(original.kind == "auction" and #policy.GetAcquisitionRequirements("bank") == 0)

opened = true
local function bankPreview()
    return FC.Logistics.Preview({itemID = 501, quantity = 1, intent = "supply", choices = {[501] = {source = "Bank"}}})
end
local reservedBank = assert(FC.Queue.Accept(bankPreview(), bankPreview))
local bankRows = policy.GetAcquisitionRequirements("bank")
assert(#bankRows == 1 and bankRows[1].jobId == reservedBank.id and bankRows[1].quantity == 4
    and bankRows[1].groupCount == 2 and bankRows[1].groupKey,
    "the exact bank reservation and differently purposed craft share one qualified withdrawal")
do
    local previous = queuedRecipe.planRevision
    queuedRecipe.planRevision = tostring(previous) .. "/changed"
    local changed = assert(policy.GetAcquisitionRequirements("bank")[1])
    assert(changed.quantity == bankRows[1].quantity and changed.groupKey ~= bankRows[1].groupKey
        and not policy.AcquireRequirement("bank", bankRows[1]) and issued == 0,
        "an unchanged bank total cannot authorize a different revision of a hidden member")
    queuedRecipe.planRevision = previous
end
original.requirement.auctionAwaiting = 1
do
    local coveredBank = policy.GetAcquisitionRequirements("bank")
    assert(#coveredBank == 1 and coveredBank[1].quantity == 1 and not coveredBank[1].groupKey
        and not policy.AcquireRequirement("bank", bankRows[1]) and issued == 0,
        "a paid auction requirement cannot source twice and invalidates the previous grouped withdrawal")
end
original.requirement.auctionAwaiting = 0

local validateMove, liveBankOffer
FluxBankRestock.StartLogistics = function(offer, amount, validate)
    assert(offer.itemID == 501 and validate(offer, amount, 0))
    validateMove, liveBankOffer = validate, offer
    issued = issued + amount
    return true, nil, amount
end
assert(policy.AcquireRequirement("bank", bankRows[1]) and issued == 4
    and reservedBank.acquisition and queuedRecipe.acquisition and not policy.AcquireRequirement("bank", bankRows[1]),
    "one native bank move journals both approved shares and cannot be repeated while in flight")
stock[501], petBank, reports = 1, 3, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(reservedBank.status == "complete" and queuedRecipe.acquisition and queuedRecipe.acquisition.credited == 0
    and not policy.AcquireRequirement("bank", bankRows[1]),
    "the first carried unit credits the exact bank reservation and cannot also count for its craft")
bankRows = policy.GetAcquisitionRequirements("bank")
assert(#bankRows == 1 and bankRows[1].pending and bankRows[1].quantity == 3)
assert(not policy.AcquireRequirement("bank", bankRows[1]), "a pending withdrawal remains visible without a second action")
local unmade, fromInputBank = FC.Queue.OutstandingOutput(queuedRecipe)
assert(unmade == 1 and fromInputBank == 0, "withdrawing an input is not bank coverage of the crafted output")
assert(validateMove(liveBankOffer, 1, 0))
stock[501], petBank, reports = 2, 2, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(queuedRecipe.acquisition and queuedRecipe.acquisition.credited == 1)
bankRows = policy.GetAcquisitionRequirements("bank")
assert(#bankRows == 1 and bankRows[1].quantity == 2 and bankRows[1].pending)
assert(validateMove(liveBankOffer, 2, 0) and not validateMove(liveBankOffer, 3, 0),
    "the owner must be able to finish a later stack but cannot exceed the remaining accepted amount")
stock[501], petBank, reports = 4, 0, reports + 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(not queuedRecipe.acquisition and #policy.GetAcquisitionRequirements("bank") == 0
    and FC.Queue.CanProcess(queuedRecipe, queuedRecipe.tasks[1])
    and original.requirement.kind == "auction" and original.requirement.remaining == 0)
assert(not next(FluxVendorAuto.GetRestockTargetItems()), "withdrawals cannot create saved preset rows")

assert(FC.Queue.Initialize({}))
policy.NotifyCoverageChanged()
closeMerchant()
opened, stock[503], petBank = false, 0, 2
Flux.Inventory.Bank.GetCount = function(id) return id == 503 and petBank or 0 end
local vendorPlan = acceptVendor(503, 4)
local vendorRequirement = vendorPlan.requirements[1]
opened = true
local bankSelection = assert(policy.GetAcquisitionRequirements("bank")[1])
assert(bankSelection.itemID == 503 and bankSelection.quantity == 2 and vendorRequirement.kind == "vendor")
FluxBankRestock.StartLogistics = function(offer, quantity, validate)
    assert(validate(offer, quantity, 0))
    validateMove, liveBankOffer = validate, offer
    return true, nil, quantity
end
assert(policy.AcquireRequirement("bank", bankSelection) and vendorPlan.acquisition.kind == "bank")
closeMerchant()
assert(vendorPlan.acquisition.status == "issued" and not vendorRequirement.autoBuyBlocked,
    "closing a merchant cannot interrupt a bank withdrawal for a vendor-planned material")
for count = 1, 2 do
    assert(validateMove(liveBankOffer, 1, 0))
    stock[503], petBank = count, 2 - count
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
end
assert(not vendorPlan.acquisition and vendorPlan.lastAcquisition.kind == "bank"
    and vendorPlan.lastAcquisition.credited == 2 and FC.Queue.AcquisitionRemaining(vendorPlan, vendorRequirement) == 2
    and vendorRequirement.vendorIssuedUnits == 0 and vendorRequirement.vendorIssuedCopper == 0,
    "bank receipts reduce the material shortage without charging its vendor budget")

stock[503] = 3
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
local vendorRow = assert(policy.GetAcquisitionRequirements("vendor")[1])
assert(vendorRow.itemID == 503 and FC.Queue.AcquisitionRemaining(vendorPlan, vendorRequirement) == 1,
    "a manual bag gain must reduce the accepted vendor material shortage")
stock[503] = 4
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(#policy.GetAcquisitionRequirements("vendor") == 0 and not policy.AcquireRequirement("vendor", vendorRow))

Flux.Inventory.Bank.GetCount = function(id) return id == 501 and petBank or 0 end
stock[501], petBank = 0, 2
local manuallyRestocked = assert(FC.Queue.Accept(bankPreview(), bankPreview))
local originalBankRow = assert(policy.GetAcquisitionRequirements("bank")[1])
assert(originalBankRow.jobId == manuallyRestocked.id)
stock[501], petBank = 1, 1
FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
assert(#policy.GetAcquisitionRequirements("bank") == 0 and manuallyRestocked.status == "complete"
    and not policy.AcquireRequirement("bank", originalBankRow),
    "manual withdrawal must remove the temporary target without issuing a second pickup")

assert(FC.Queue.Initialize({}))
stock[501], petBank, opened = 12, 10, false
local scopeTarget = {itemID = 501, target = 40, countBank = false}
FluxVendorAuto.GetRestockTargetItems = function()
    scopeTarget.bagCount, scopeTarget.bankCount = stock[501], petBank
    return {scopeTarget}
end
FluxAuctionRestock.GetPolicyCoverage = function() return 8 end
policy.NotifyChanged("inventory")
local demandID = "item:501"
assert(policy.GetDemand(demandID).uncovered == 20)
assert(policy.Request(demandID, "restock", {manual = true, source = "auction"}))
local alternateBank = assert(FC.Queue.GetJobs()[1])
local originalAuction = assert(alternateBank.requirements[1])
assert(originalAuction.kind == "auction" and originalAuction.quantity == 20)
opened = true
policy.NotifyChanged("inventory")
local substitute = assert(policy.GetAcquisitionRequirements("bank")[1])
assert(substitute.jobId == alternateBank.id and substitute.quantity == 10)
assert(policy.AcquireRequirement("bank", substitute) and alternateBank.acquisition.kind == "bank")
local beforeScopeChange = policy.GetDemand(demandID)
assert(beforeScopeChange.ready == 12 and beforeScopeChange.covered == 28 and beforeScopeChange.uncovered == 0,
    "bags-only scope counts each accepted bank delivery once")

scopeTarget.target, scopeTarget.countBank = 50, true
policy.NotifyChanged("settings")
for _, moved in ipairs({0, 4, 10}) do
    stock[501], petBank, reports = 12 + moved, 10 - moved, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, bank = true}})
    policy.NotifyChanged("inventory")
    local demand = assert(policy.GetDemand(demandID))
    assert(demand.ready == 12 + moved and demand.bank == 10 - moved and demand.covered == 18 and demand.uncovered == 10,
        "a bank substitution cannot cover a Count Bank target again while its units are still in the bank")
end
local outstanding, fromClosedBank = FC.Queue.OutstandingOutput(alternateBank)
assert(outstanding == 10 and fromClosedBank == 0 and originalAuction.remaining == 10 and originalAuction.kind == "auction"
    and not alternateBank.acquisition and alternateBank.lastAcquisition.credited == 10,
    "confirmed bank receipts preserve the original requirement and do not retain temporary bank coverage")
print("Accepted bank requirements and live alternate stock handoff passed")

local function testMerchantSubstitution()
    assert(FC.Queue.Initialize({}))
    opened = false
    closeMerchant()
    local eligible, fixed, unpriced, uncertain, independent = 9301, 9302, 9303, 9304, 9305
    local learned, knownBundle = false, false
    local amounts = {}
    Flux.Inventory.Mail = {
        GetCount = function(itemID) return mail[itemID] or 0 end,
        HasObservedInbox = function() return inboxObserved end,
    }
    FC.MarketAdapter.QuoteItems = function()
        return {[eligible] = 100, [fixed] = 100, [uncertain] = 100}, {}
    end
    FluxAuctionRestock.GetPolicyCoverage = function(_, units, itemID)
        assert(units == "item")
        return ownerPending[itemID] or 0
    end
    FluxAuctionRestock.VendorSource = function(itemID)
        if itemID == unpriced and learned then return true, 80 end
        if itemID == eligible and knownBundle then return true, 80, "fixture", "fixture catalog" end
    end
    FluxAuctionRestock.VendorTerms = function(itemID)
        if itemID == unpriced and learned then return 160, 2 end
        if itemID == eligible and knownBundle then return 160, 2 end
    end
    FluxVendorAuto.GetLogisticsOffer = function(itemID)
        if not merchantVisible or not indexReady or itemID < eligible or itemID > independent then return end
        local location = "vendor:substitution"
        return {offerId = location .. ":" .. itemID, kind = "vendor", itemID = itemID, unit = "item",
            qualified = true, bundleSize = 2, bundlePrice = liveBundlePrice, availableUnits = available,
            marketContext = location, locationKey = location}
    end
    FluxVendorAuto.BuyForLogistics = function(offer, quantity, validate)
        local units = math.min(2, quantity)
        local total = units / offer.bundleSize * offer.bundlePrice
        assert(quantity <= available and money >= total and validate(offer, units, total))
        assert(not validate(offer, units, total + 1))
        amounts[#amounts + 1] = {itemID = offer.itemID, quantity = units, total = total}
        available, money = available - units, money - total
        return true, nil, units
    end
    local function accept(itemID, quantity, source, replaces)
        local args = {itemID = itemID, quantity = quantity, intent = "supply", replaces = replaces,
            choices = source and {[itemID] = {source = source}}}
        local function preview() return FC.Logistics.Preview(args) end
        return assert(FC.Queue.Accept(preview(), preview, replaces))
    end

    local job = accept(eligible, 6)
    local requirement = job.requirements[1]
    assert(requirement.kind == "auction" and requirement.maxTotalPrice == 600)
    inboxObserved = false
    showMerchant(10, 1000, 160)
    assert(#amounts == 0, "an unobserved inbox cannot rule out a paid purchase")
    inboxObserved, ownerPending[eligible] = true, 2
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {mail = true}})
    drain()
    assert(#amounts == 0, "observed pending units must be used before a merchant substitution")
    ownerPending[eligible] = 0
    showMerchant(10, 1000, 200)
    assert(#amounts == 0, "the alternative must be cheaper than the approved per-unit price")
    showMerchant(10, 1000, 160)
    assert(#amounts == 1 and requirement.remaining == 6 and job.acquisition.kind == "vendor"
        and amounts[1].quantity == 2 and amounts[1].total == 160)
    policy.NotifyChanged("merchant")
    drain()
    assert(#amounts == 1, "repeated merchant events must wait for the bag receipt")
    available = 0
    carry(eligible, 2)
    local entry = FC.Queue.GetRequirements(job)[1]
    local need = FC.Logistics.GetAuctionNeed(entry)
    assert(need.remaining == 4 and need.maxTotalPrice == 440 and requirement.kind == "auction",
        "confirmed merchant units reduce the same queued requirement and its remaining auction budget")
    closeMerchant()

    local started, phase = FC.Logistics.BuyAuction(entry, 2)
    assert(started and phase == "searching")
    searchReady()
    assert(FC.Logistics.BuyAuction(entry, 2))
    terminal("confirmed")
    assert(requirement.auctionSpent == 160 and requirement.auctionAwaiting == 2)
    showMerchant(10, 1000, 160)
    assert(#amounts == 1, "a confirmed auction receipt blocks a second sourcing route before the inbox observes it")
    carry(eligible, 4)
    assert(#amounts == 2 and amounts[2].itemID == eligible and amounts[2].quantity == 2)
    carry(eligible, 6)
    assert(job.status == "complete" and requirement.vendorIssuedCopper == 320 and requirement.auctionSpent == 160)
    closeMerchant()

    local locked = accept(fixed, 2, "Buy")
    local absent = accept(unpriced, 2)
    assert(locked.goal.auctionOnly[fixed] and absent.requirements[1].kind == "manual")
    learned = true
    showMerchant(10, 1000, 160)
    assert(#amounts == 2 and not locked.acquisition and not absent.acquisition,
        "an explicit auction route and an unpriced accepted job cannot grant new merchant spending")
    assert(#policy.GetAcquisitionRequirements("vendor") == 0,
        "locked and unpriced auction materials cannot be selected through manual Restock")
    local revised = accept(unpriced, 2, "Vendor", absent)
    drain()
    assert(#amounts == 3 and amounts[3].itemID == unpriced and revised.acquisition.kind == "vendor")
    carry(unpriced, 2)
    assert(revised.status == "complete", "an explicit vendor replan can approve newly observed terms")
    closeMerchant()

    local interrupted = accept(uncertain, 2)
    showMerchant(10, 1000, 160)
    assert(#amounts == 4 and interrupted.acquisition.kind == "vendor" and FC.Logistics.IsWorkflowBusy())
    closeMerchant()
    assert(interrupted.acquisition.status == "uncertain" and not FC.Logistics.IsWorkflowBusy())
    showMerchant(10, 1000, 160)
    local sameItem = accept(uncertain, 2, "Vendor")
    local unrelated = accept(independent, 2, "Vendor")
    drain()
    assert(#amounts == 5 and amounts[5].itemID == independent and unrelated.acquisition.status == "issued",
        "an unrelated vendor order can proceed while a different receipt needs review")
    carry(independent, 2)
    assert(not sameItem.acquisition and #amounts == 5 and interrupted.acquisition.status == "uncertain",
        "an unresolved receipt must still block automatic purchases of the same item")
    assert(FC.Queue.SetPaused(sameItem.id, true) and FC.Logistics.ResolveAcquisition(interrupted))
    local interruptedEntry = FC.Queue.GetRequirements(interrupted)[1]
    assert(interruptedEntry.requirement.auctionNeedsReplan and not FC.Logistics.BuyAuction(interruptedEntry, 2))
    showMerchant(10, 1000, 160)
    assert(#amounts == 5, "an uncertain merchant spend cannot be replayed through either surface")

    assert(FC.Queue.Initialize({}))
    closeMerchant()
    stock[eligible] = nil
    local firstManualPurchase = #amounts + 1
    FluxVendorAuto.AllowsLogisticsAutomaticPurchase = function() return false end
    local manualJob = accept(eligible, 5)
    local manualRequirement = manualJob.requirements[1]
    assert(manualRequirement.kind == "auction" and manualJob.goal.autoBuyVendor)
    inboxObserved = false
    showMerchant(10, 1000, 160)
    assert(#policy.GetAcquisitionRequirements("vendor") == 0, "manual merchant coverage also needs verified inbox stock")
    inboxObserved, ownerPending[eligible] = true, 2
    assert(#policy.GetAcquisitionRequirements("vendor") == 0, "manual merchant lookup excludes known inbound stock")
    ownerPending[eligible] = 0
    assert(#amounts < firstManualPurchase, "Shift must leave the merchant visit free of automatic purchases")
    money = 159
    assert(#policy.GetAcquisitionRequirements("vendor") == 0, "insufficient funds for a bundle hide the alternate row")
    money = 350
    local manualRow = assert(policy.GetAcquisitionRequirements("vendor")[1])
    assert(manualRow.jobId == manualJob.id and manualRow.itemID == eligible
        and manualRow.quantity == 4 and not manualRow.pending, "manual Restock offers only whole affordable bundles")
    liveBundlePrice = 200
    assert(not policy.AcquireRequirement("vendor", manualRow) and #amounts < firstManualPurchase,
        "a stale manual row cannot buy at the accepted auction unit price")
    liveBundlePrice = 160
    assert(policy.AcquireRequirement("vendor", manualRow) and #amounts == firstManualPurchase)
    assert(amounts[firstManualPurchase].quantity == 2 and amounts[firstManualPurchase].total == 160
        and manualJob.acquisition.substitutedAuction and not manualJob.acquisition.auto)
    local pending = assert(policy.GetAcquisitionRequirements("vendor")[1])
    assert(pending.pending and pending.quantity == 2 and not policy.AcquireRequirement("vendor", manualRow),
        "the manual receipt appears once while the physical delivery is pending")
    carry(eligible, 2)
    local manualEntry = FC.Queue.GetRequirements(manualJob)[1]
    assert(FC.Logistics.GetAuctionNeed(manualEntry).maxTotalPrice == 340 and manualRequirement.remaining == 3)

    FC.Logistics.GetSettings().autoBuyVendor = false
    FluxVendorAuto.AllowsLogisticsAutomaticPurchase = function() return true end
    local nextManualRow = assert(policy.GetAcquisitionRequirements("vendor")[1])
    assert(nextManualRow.quantity == 2 and policy.AcquireRequirement("vendor", nextManualRow),
        "turning off automatic merchant purchases still allows manual Restock")
    carry(eligible, 4)
    assert(manualRequirement.remaining == 1 and manualRequirement.vendorIssuedCopper == 320
        and #policy.GetAcquisitionRequirements("vendor") == 0, "a final partial demand cannot overspend on a whole bundle")
    FC.Logistics.GetSettings().autoBuyVendor = true
    FluxVendorAuto.AllowsLogisticsAutomaticPurchase = nil
    closeMerchant()

    assert(FC.Queue.Initialize({}))
    stock[eligible], knownBundle = nil, true
    local deferred = accept(eligible, 1)
    local deferredRequirement = deferred.requirements[1]
    assert(deferredRequirement.kind == "auction" and deferredRequirement.maxTotalPrice == 100)
    local deferredEntry = assert(FC.Queue.GetRequirements(deferred)[1])
    local compared = assert(FC.Logistics.GetAuctionNeed(deferredEntry))
    assert(compared.minQuantity == 1 and compared.maxTotalPrice == 159 and compared.vendorCost == 160)
    local issued = #amounts
    showMerchant(10, 1000, 162)
    assert(#amounts == issued and not deferred.acquisition, "a merchant above the known bundle price cannot issue the fallback")
    showMerchant(10, 1000, 160)
    assert(#amounts == issued + 1 and amounts[#amounts].quantity == 2 and amounts[#amounts].total == 160,
        "the next merchant can satisfy an exact shortage with a qualified whole bundle")
    carry(eligible, 2)
    assert(deferred.status == "complete" and deferredRequirement.vendorIssuedCopper == 160)
    closeMerchant()
end
testMerchantSubstitution()
print("Accepted auction materials use cheaper live merchant stock automatically or through manual Restock")

local function testDirectRestockAfterBagGains()
    assert(FC.Queue.Initialize({}))
    closeMerchant()
    opened, inboxObserved = false, true
    local itemID = 9311
    local demandID = "item:" .. itemID
    local target = {itemID = itemID, target = 40, countBank = false}
    FluxVendorAuto.GetRestockTargetItems = function()
        target.bagCount = stock[itemID]
        return {target}
    end
    FC.MarketAdapter.QuoteItems = function() return {[itemID] = 100}, {} end
    local function observe(bags, oldMail)
        stock[itemID], mail[itemID], ownerPending[itemID] = bags, oldMail, oldMail
        reports, mailGeneration = reports + 1, mailGeneration + 1
        policy.NotifyChanged("inventory")
        FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
    end
    local function accept()
        assert(policy.Request(demandID, "restock", {manual = true, source = "auction"}))
        local job = FC.Queue.GetJobs()[#FC.Queue.GetJobs()]
        return job, assert(FC.Queue.GetRequirements(job)[1])
    end
    observe(12, 8)
    local first, firstEntry = accept()
    assert(FC.Logistics.GetAuctionNeed(firstEntry).toBuy == 20)
    observe(20, 0)
    assert(firstEntry.requirement.remaining == 20 and FC.Logistics.GetAuctionNeed(firstEntry).toBuy == 20,
        "collecting the inbox stock already excluded from the accepted order cannot reduce it again")

    target.target = 50
    policy.NotifyChanged("settings")
    local second, secondEntry = accept()
    assert(FC.Logistics.GetAuctionNeed(secondEntry).toBuy == 10)

    target.target = 46
    policy.NotifyChanged("settings")
    assert(FC.Logistics.GetAuctionNeed(secondEntry).toBuy == 6)
    local nativeQuantity
    for _, row in ipairs(policy.GetShoppingRequirements("auction")) do
        if row.jobId == second.id then nativeQuantity = row.quantity end
    end
    local prepareNative = FluxAuctionRestock.PrepareLogisticsSearch
    FluxAuctionRestock.PrepareLogisticsSearch = function(id)
        assert(id == itemID)
        return true, "Fixture material"
    end
    local openedSearch, message = FC.Logistics.Acquire(secondEntry)
    FluxAuctionRestock.PrepareLogisticsSearch = prepareNative
    assert(openedSearch and message == policy.Text.shoppingReady:format("Fixture material", nativeQuantity),
        "native search receives the owner projection with both old and net-aware owner revisions")
    target.target = 50
    policy.NotifyChanged("settings")
    observe(24, 0)
    local clipped = FC.Logistics.GetAuctionNeed(secondEntry)
    assert(FC.Logistics.GetAuctionNeed(firstEntry).toBuy == 20 and clipped.targetLimited and clipped.toBuy == 6,
        "earlier accepted stock orders keep priority while a new bag gain reduces the later buy quantity")
    local shopping = FC.Logistics.GetAuctionShoppingRequirements()
    assert(#shopping == 2 and shopping[1].quantity == 20 and shopping[2].quantity == 6
        and shopping[2].job == second and shopping[2].id == secondEntry.id
        and secondEntry.requirement.remaining == 10,
        "the owner-shopping projection exposes live net quantities and preserves the accepted identity and reservation")

    target.target = 24
    policy.NotifyChanged("settings")
    assert(#FC.Logistics.GetAuctionShoppingRequirements() == 0,
        "a fully covered target must disappear from the owner's search submenu while its original plan remains queued")
    target.target = 50
    policy.NotifyChanged("settings")

    local fixedArgs = {itemID = itemID, quantity = 2, intent = "supply"}
    local function fixedPreview() return FC.Logistics.Preview(fixedArgs) end
    local fixed = assert(FC.Queue.Accept(fixedPreview(), fixedPreview))
    -- Stop before the native action to check that revalidation sees a real
    -- bag increase after the displayed offer and approved click quantity.
    local execute = FluxAuctionRestock.ExecuteLogistics
    FluxAuctionRestock.ExecuteLogistics = function(request, quantity, authorize)
        assert(quantity == 6 and authorize(request, quantity))
        stock[itemID], reports = 50, reports + 1
        -- The inventory facade's listeners can run in either order. Process
        -- the bag pulse before the owner invalidates its same-item cache.
        FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
        assert(not authorize(request, quantity, quantity * 80), "a now-full target cannot spend against stale terms")
        return false, "changed"
    end
    assert(not FC.Logistics.BuyAuction(secondEntry, 10))
    FluxAuctionRestock.ExecuteLogistics = execute
    assert(first.status == "complete" and second.status == "complete" and policy.GetDemand(demandID).covered == 0,
        "physically fulfilling the target settles the direct stock orders without creating another purchase")
    assert(fixed.goal.demandId == nil and FC.Logistics.GetAuctionNeed(FC.Queue.GetRequirements(fixed)[1]).toBuy == 2,
        "a fulfilled restock target cannot shrink a fixed supply order or claim the same bag gain twice")
    assert(not FC.Logistics.BuyAuction(secondEntry, 10))
end
testDirectRestockAfterBagGains()
print("Accepted direct auction replenishment respects updated live stock targets")

local function testDirectBankAndVendorRestockTargets()
    assert(FC.Queue.Initialize({}))
    closeMerchant()
    local itemID = 9321
    local demandID = "item:" .. itemID
    local target = {itemID = itemID, target = 40, countBank = false}
    FluxVendorAuto.GetRestockTargetItems = function()
        target.bagCount, target.bankCount = stock[itemID], petBank
        return {target}
    end
    Flux.Inventory.Bank.GetCount = function(id) return id == itemID and petBank or 0 end
    FC.MarketAdapter.QuoteItems = function() return {[itemID] = 100}, {} end
    FluxAuctionRestock.GetPolicyCoverage = function(_, units, id)
        assert(units == "item" or units == "charge")
        return ownerPending[id] or 0
    end
    local function observe(bags, oldMail)
        stock[itemID], mail[itemID], ownerPending[itemID] = bags, oldMail, oldMail
        reports, mailGeneration = reports + 1, mailGeneration + 1
        policy.NotifyChanged("inventory")
        FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true, bank = true}})
    end
    local function accept(surface)
        assert(policy.Request(demandID, "restock", {manual = true, source = surface}))
        local job = FC.Queue.GetJobs()[#FC.Queue.GetJobs()]
        return job, assert(FC.Queue.GetRequirements(job)[1])
    end

    opened, petBank = true, 50
    observe(12, 0)
    local bankJob, bankEntry = accept("bank")
    local staleBankRow = assert(policy.GetAcquisitionRequirements("bank")[1])
    assert(bankEntry.kind == "bank" and staleBankRow.quantity == 28)
    observe(39, 0)
    local bankRow = assert(policy.GetAcquisitionRequirements("bank")[1])
    assert(bankRow.quantity == 1 and not policy.AcquireRequirement("bank", staleBankRow),
        "the bank's temporary Restock row must use the live shortage and reject its stale selection")
    local bankIssued = 0
    FluxBankRestock.StartLogistics = function(offer, quantity, validate)
        assert(quantity == 1 and validate(offer, 1, 0) and not validate(offer, 2, 0))
        stock[itemID] = 40
        assert(not validate(offer, 1, 0), "a later move must stop when bags fill during the owner action")
        stock[itemID] = 39
        bankIssued = bankIssued + quantity
        return true, nil, quantity
    end
    assert(policy.AcquireRequirement("bank", bankRow) and bankIssued == 1)
    assert(policy.GetAcquisitionRequirements("bank")[1].pending and bankJob.acquisition.quantity == 1)
    petBank = 49
    observe(40, 0)
    assert(bankJob.status == "complete" and bankJob.lastAcquisition.credited == 1
        and #policy.GetAcquisitionRequirements("bank") == 0,
        "the bank receipt and an existing bag gain must settle the same direct order exactly once")

    assert(FC.Queue.Initialize({}))
    petBank = 10
    observe(12, 8)
    local mixedJob = accept("bank")
    local auctionEntry
    for _, requirement in ipairs(FC.Queue.GetRequirements(mixedJob)) do
        if requirement.kind == "auction" then auctionEntry = requirement end
    end
    assert(auctionEntry and FC.Logistics.GetAuctionNeed(auctionEntry).toBuy == 10)
    observe(28, 8)
    assert(FC.Logistics.GetAuctionNeed(auctionEntry).toBuy == 0
        and policy.GetAcquisitionRequirements("bank")[1].quantity == 4,
        "the Auction House and bank must share the four-unit remainder of the same accepted goal")

    assert(FC.Queue.Initialize({}))
    opened, petBank = false, 0
    FluxAuctionRestock.VendorSource = function(id)
        if id == itemID then return true, 4, "fixture", "fixture-gold-catalogue" end
    end
    FluxAuctionRestock.VendorTerms = function(id) if id == itemID then return 8, 2 end end
    local vendorPurchase, blockVendor = {}, false
    FluxVendorAuto.GetLogisticsOffer = function(id)
        if merchantVisible and id == itemID then
            return {offerId = "vendor:headroom:" .. id, kind = "vendor", itemID = id, unit = "item",
                qualified = true, bundleSize = 2, bundlePrice = 8, availableUnits = 50,
                marketContext = "vendor:headroom", locationKey = "vendor:headroom"}
        end
    end
    FluxVendorAuto.BuyForLogistics = function(offer, quantity, validate)
        assert(validate(offer, quantity, quantity * 4))
        if blockVendor then
            stock[itemID] = target.target
            assert(not validate(offer, 2, 8), "a newly met target must block a previously accepted vendor bundle")
            stock[itemID] = 22
            return false, "fixture changed stock"
        end
        local issued = #vendorPurchase == 0 and 2 or quantity
        vendorPurchase[#vendorPurchase + 1] = quantity
        return true, nil, issued
    end
    observe(12, 8)
    local vendorJob, vendorEntry = accept("vendor")
    assert(vendorEntry.kind == "vendor" and vendorEntry.quantity == 20)
    observe(20, 0)
    merchantVisible, money = true, 1000
    assert(FC.Logistics.Acquire(vendorEntry, true) and vendorPurchase[1] == 20
        and vendorEntry.requirement.remaining == 20,
        "automatic vendor buys must retain the approved shortage when earlier mail moves into bags")
    local pendingVendor = assert(policy.GetAcquisitionRequirements("vendor")[1])
    assert(pendingVendor.pending and pendingVendor.quantity == 2)
    observe(22, 0)
    assert(not vendorJob.acquisition and vendorJob.lastAcquisition.credited == 2)

    target.target = 22
    policy.NotifyChanged("settings")
    assert(#policy.GetAcquisitionRequirements("vendor") == 0 and not FC.Logistics.Acquire(vendorEntry, true)
        and #vendorPurchase == 1, "reducing the target without a bag delta must stop an authorized vendor order")
    target.target = 25
    policy.NotifyChanged("settings")
    local vendorRow = assert(policy.GetAcquisitionRequirements("vendor")[1])
    assert(vendorRow.quantity == 4, "a shorter three-unit shortage allows only two approved two-unit bundles")
    blockVendor = true
    assert(not policy.AcquireRequirement("vendor", vendorRow) and #vendorPurchase == 1)
    blockVendor = false
    assert(policy.AcquireRequirement("vendor", vendorRow) and vendorPurchase[2] == 4)
    observe(26, 0)
    assert(not vendorJob.acquisition and vendorJob.lastAcquisition.credited == 4
        and #policy.GetAcquisitionRequirements("vendor") == 0 and not FC.Logistics.Acquire(vendorEntry, true),
        "a whole vendor bundle can meet the target without buying the old, larger remainder")

    target.target, target.isCharge = 60, true
    policy.NotifyChanged("settings")
    assert(#policy.GetAcquisitionRequirements("vendor") == 0 and not FC.Logistics.Acquire(vendorEntry, true),
        "an item-based saved order cannot authorize a purchase after its owner target changes to charges")
    closeMerchant()
end
testDirectBankAndVendorRestockTargets()
print("Accepted direct bank and vendor replenishment share live ownership and bundle limits")

local function testTierReceiptKeepsObservedItem()
    assert(FC.Queue.Initialize({}))
    closeMerchant()
    opened, inboxObserved = false, true
    local oldItem, preferredItem = 9325, 9326
    local kind, selected, target = "healPotion", oldItem, 10
    local ruleID = "tier:" .. kind
    local row = {isTierRestock = true, tierKind = kind, target = target, bagCount = 0, bankCount = 0}
    FluxVendorAuto.GetRestockTargetItems = function() return {row} end
    FluxRestockTiers = {
        GetTarget = function() return target end,
        GetCountBankFlag = function() return false end,
        ItemMatchesRestockKind = function(tier, itemID)
            return tier == kind and (itemID == oldItem or itemID == preferredItem)
        end,
    }
    FluxConsumableBest = {GetBestRef = function() return {itemID = selected} end}
    FC.MarketAdapter.QuoteItems = function() return {[oldItem] = 100, [preferredItem] = 100}, {} end
    stock[oldItem], stock[preferredItem], money = 0, 0, 1000000
    policy.NotifyChanged("inventory")
    assert(policy.Request(ruleID, "restock", {manual = true, source = "auction"}))
    local job = FC.Queue.GetJobs()[1]
    local entry = assert(FC.Queue.GetRequirements(job)[1])
    assert(entry.itemID == oldItem and entry.quantity == 10)
    assert(FC.Logistics.BuyAuction(entry, 4))
    searchReady()
    assert(FC.Logistics.BuyAuction(entry, 4))
    terminal("confirmed")
    mail[oldItem], ownerPending[oldItem] = 4, 4
    policy.NotifyChanged("inventory")
    assert(policy.GetDemand(ruleID).covered == 10, "owner mail for the preferred SKU normally matches its paid receipt")

    target, selected, row.target = 20, preferredItem, 20
    policy.NotifyChanged("inventory")
    local demand = policy.GetDemand(ruleID)
    assert(demand.itemID == preferredItem and demand.covered == 10 and demand.uncovered == 10)
    local rows = plannerProvider.GetCoverage(demand, 4, oldItem)
    assert(#rows == 1 and rows[1].quantity == 6,
        "an explicit observation for the still-eligible former SKU must overlap its own paid quantity")
    local preferredRows = plannerProvider.GetCoverage(demand, 4)
    assert(#preferredRows == 1 and preferredRows[1].quantity == 10,
        "the two-argument bridge still interprets pending coverage as the preferred item")
end
testTierReceiptKeepsObservedItem()
print("Tier restock credits paid receipts against the observed listing SKU")

local function testFractionalAuctionBudgets()
    local saved = {}
    assert(FC.Queue.Initialize(saved))
    local fractional, belowCopper, integer = 9331, 9332, 9333
    local prices = {[fractional] = 5.75, [belowCopper] = 0.5, [integer] = 5}
    Auctionator = {API = {v1 = {GetAuctionPriceByItemID = function(_, itemID) return prices[itemID] end}}}
    assert(loadfile("FluxCraft/AdaptersAuctionator.lua"))("FluxLogistics", FC)
    FC.Logistics.GetSettings().provider = "auto"
    GetMoney = function() return 1000 end
    FluxAuctionRestock.GetPolicyCoverage = function() return 0 end
    Flux.Inventory.Mail = {GetCount = function() return 0 end, HasObservedInbox = function() return true end}

    local function accept(itemID, quantity)
        local function preview()
            return FC.Logistics.Preview({itemID = itemID, quantity = quantity, intent = "supply",
                choices = {[itemID] = {source = "Buy"}}})
        end
        local plan, context = preview()
        assert(context.quotes[itemID].provider == "auctionator" and plan.summary.fullValue == prices[itemID] * quantity)
        local job = assert(FC.Queue.Accept(plan, preview))
        return assert(FC.Queue.GetRequirements(job)[1])
    end

    local preparations, purchases = 0, 0
    FluxAuctionRestock.PrepareLogistics = function(request, units, authorize)
        preparations = preparations + 1
        assert(units == 1 and request.maxUnitPrice == 5 and authorize(request, 1, 5) and not authorize(request, 1, 6))
        if request.itemID == fractional then assert(request.maxTotalPrice == 11)
        else assert(request.itemID == integer and request.maxTotalPrice == 5) end
        return true, "searching"
    end
    FluxAuctionRestock.ExecuteLogistics = function(request, units, authorize, observe)
        purchases = purchases + 1
        assert(request.itemID == fractional and units == 1 and request.maxTotalPrice == 11)
        assert(authorize(request, 1, 5) and not authorize(request, 1, 6))
        local receipt = {jobId = request.jobId, id = request.id, itemID = request.itemID,
            planRevision = request.planRevision, quantity = 1, totalCopper = 5, attemptID = 1}
        observe("submitted", receipt)
        observe("confirmed", receipt)
        return true, "buying"
    end

    local estimated = accept(fractional, 2)
    assert(estimated.requirement.maxUnitPrice == 5.75 and estimated.requirement.maxTotalPrice == 11.5)
    assert(FC.Logistics.PrepareAuction(estimated, 1) and FC.Logistics.BuyAuction(estimated, 1))
    local need = FC.Logistics.GetAuctionNeed(estimated)
    assert(estimated.requirement.maxTotalPrice == 11.5 and estimated.requirement.auctionSpent == 5
        and need.maxTotalPrice == 6 and need.toBuy == 1 and need.pendingIncoming == 1)
    local function temporaryRow(itemID)
        for _, entry in ipairs(FC.testAuctionRows.GetRows()) do if entry.itemID == itemID then return entry end end
    end
    local displayed = assert(temporaryRow(fractional))
    assert(displayed.quantity == 1 and displayed.incoming == 1 and displayed.jobId == estimated.job.id,
        "the native Restock rows separate outstanding purchases from paid incoming units")

    local zero = accept(belowCopper, 1)
    need = FC.Logistics.GetAuctionNeed(zero)
    assert(zero.requirement.maxTotalPrice == 0.5 and need.maxUnitPrice == 0 and need.maxTotalPrice == 0)
    assert(not FC.Logistics.PrepareAuction(zero, 1) and not FC.Logistics.BuyAuction(zero, 1)
        and preparations == 1 and purchases == 1, "an estimate below one copper cannot authorize a paid listing")

    local legacy = accept(integer, 1)
    prices[integer] = 12
    assert(FC.Queue.Initialize(saved))
    local reloaded = assert(FC.Queue.GetRequirements(FC.Queue.GetJob(legacy.job.id))[1])
    assert(FC.Logistics.PrepareAuction(reloaded, 1) and preparations == 2 and purchases == 1,
        "a reloaded integer cap remains authoritative after the provider changes")
    stock[fractional], reports = 2, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
    assert(not temporaryRow(fractional), "the temporary Restock target disappears when its materials are in bags")
end
testFractionalAuctionBudgets()
print("Auctionator estimates retain fractional precision and authorize only whole copper within the accepted cap")

local function testLiveAuctionReview()
    assert(FC.Queue.Initialize({}))
    FC.Logistics.ClearAuctionPrices()
    local cloth = 4338
    stock[cloth], mail[cloth], ownerPending[cloth] = 0, 0, 0
    money, inboxObserved, mailGeneration = 124375, true, 1
    GetMoney = function() return money end
    FC.MarketAdapter.QuoteItems = function()
        return {[cloth] = {unitPrice = 300, source = "fixture", estimate = true}}, {}
    end
    local function preview() return FC.Logistics.Preview({itemID = cloth, quantity = 125, intent = "supply"}) end
    local job = assert(FC.Queue.Accept(preview(), preview))
    local entry = assert(FC.Queue.GetRequirements(job)[1])
    assert(entry.requirement.maxTotalPrice == 37500 and entry.requirement.estimate == true)

    local quote, review, attempt = {quantity = 20, totalCopper = 9880}, nil, 0
    FluxAuctionRestock.GetLogisticsState = function(request, amount)
        if review and request.maxTotalPrice == review.request.maxTotalPrice and amount == review.amount then
            return review.phase, nil, review.phase == "ready" and quote or nil
        end
    end
    FluxAuctionRestock.PrepareLogistics = function(request, amount, authorize, observe, explicit)
        assert(explicit and authorize(request, amount))
        review = {request = request, amount = amount, authorize = authorize, observe = observe, phase = "searching"}
        return true, "searching"
    end
    FluxAuctionRestock.ExecuteLogistics = function(request, amount, authorize, observe)
        assert(amount == 125 and authorize(request, quote.quantity))
        assert(not authorize(request, quote.quantity, quote.totalCopper + 1))
        assert(not authorize(request, quote.quantity - 1, quote.totalCopper - 1))
        assert(authorize(request, quote.quantity, quote.totalCopper))
        attempt = attempt + 1
        local receipt = {jobId = request.jobId, id = request.id, itemID = request.itemID,
            planRevision = request.planRevision, quantity = quote.quantity, totalCopper = quote.totalCopper, attemptID = attempt}
        review = nil
        observe("submitted", receipt)
        observe("confirmed", receipt)
        return true, "buying"
    end

    local original = FC.Logistics.GetAuctionNeed(entry)
    assert(original.maxUnitPrice == 300 and FC.Logistics.CanReviewAuctionPrice(entry, original))
    assert(not FC.Logistics.PrepareAuction(entry, 125, false, true) and not review)
    assert(FC.Logistics.PrepareAuction(entry, 125, true, true) and FC.Logistics.GetAuctionNeed(entry).livePrice)
    assert(not FC.Logistics.BuyAuction(entry, 125, quote) and attempt == 0)
    review.phase = "ready"
    review.observe("state", {phase = "ready", jobId = job.id, id = entry.id, itemID = cloth, planRevision = job.planRevision})
    assert(not review.authorize(review.request, quote.quantity, quote.totalCopper + 1),
        "FluxUI's Restock button also keeps the displayed total if the native price moves")
    assert(not FC.Logistics.BuyAuction(entry, 125) and not FC.Logistics.BuyAuction(entry, 125, {quantity = 20, totalCopper = 9800}))
    assert(FC.Logistics.BuyAuction(entry, 125, quote) and attempt == 1)
    local remaining = FC.Logistics.GetAuctionNeed(entry)
    assert(entry.requirement.maxTotalPrice == 37500 and remaining.toBuy == 105 and remaining.livePrice
        and remaining.pendingIncoming == 20, "an approved live stack updates receipts and leaves the accepted plan intact")
    FC.Logistics.ClearAuctionPrices()
    assert(not FC.Logistics.GetAuctionNeed(entry).livePrice, "closing the Auction House forgets live review")
end
testLiveAuctionReview()

local function testMaximumRecursiveCarriedCrafts()
    assert(FC.Queue.Initialize({}))
    local cloth, bolt, thread, dye, alternateThread, bag = 9101, 9102, 9103, 9104, 9105, 9106
    local primary = {reagents = {{itemID = bolt, quantity = 5, slotIndex = 1},
        {itemID = thread, quantity = 2, slotIndex = 2}, {itemID = dye, quantity = 2, slotIndex = 3}}}
    local alternate = {reagents = {primary.reagents[1],
        {itemID = alternateThread, quantity = 2, slotIndex = 2}, primary.reagents[3]}}
    local function recipe(id, profession, output, reagents)
        return {id = id, professionId = profession, outputItemID = output, outputKind = "item", yield = 1,
            learned = true, completeness = "complete", characterKey = FC.state.characterKey, reagents = reagents}
    end
    local finish = recipe(91, 197, bag, primary.reagents)
    finish.reagentChoices = {primary, alternate}
    local prepare = recipe(92, 202, bolt, {{itemID = cloth, quantity = 5}})
    local snapshot = {recipesById = {[finish.id] = finish, [prepare.id] = prepare},
        byOutput = {[bag] = {finish.id}, [bolt] = {prepare.id}}, revision = 11}
    stock[cloth], stock[bolt], stock[thread], stock[dye], stock[alternateThread] = 125, 0, 10, 10, 0
    local readStock, observations = FC.InventoryAdapter.Snapshot, 0
    FC.InventoryAdapter.Snapshot = function(items)
        observations = observations + 1
        return readStock(items)
    end
    local function preview(maximum, choice)
        return FC.Logistics.PreviewAvailableCrafts(finish.id, maximum, choice, snapshot)
    end
    local plan = assert(preview(999, primary))
    assert(observations == 1 and #FC.Queue.GetJobs() == 0,
        "capacity probes must share a single stock snapshot and cannot accept work")
    assert(plan.summary.executions == 5 and plan.summary.output == 5 and plan.summary.additionalCash == 0
        and #plan.requirements == 0 and not plan.goal.autoBuyVendor)
    local producer, consumer = plan.tasks[1], plan.tasks[2]
    assert(producer.recipeId == prepare.id and producer.executions == 25 and producer.inputs[1].quantity == 125
        and consumer.recipeId == finish.id and consumer.executions == 5 and consumer.dependencies[1] == producer.taskId
        and consumer.reagentChoice.reagents[2].itemID == thread)
    local accepted = assert(FC.Queue.Accept(plan, function() return preview(999, primary) end))
    assert(observations == 2 and accepted.reservations[tostring(cloth)] == 125
        and accepted.reservations[tostring(thread)] == 10 and accepted.reservations[tostring(dye)] == 10)
    assert(not preview(999, primary), "the next job cannot promise another job's ingredients")

    assert(FC.Queue.Initialize({}))
    stock[thread], stock[alternateThread] = 4, 6
    local pinned = assert(preview(999, primary))
    assert(pinned.summary.executions == 2 and pinned.tasks[#pinned.tasks].reagentChoice.reagents[2].itemID == thread)
    assert(assert(preview(999)).summary.executions == 5 and assert(preview(3)).summary.executions == 3)
    local invalid, reason = preview(999, {reagents = {{itemID = 9199, quantity = 1}}})
    assert(not invalid and reason == FC.L.clients.staleReagents, "an obsolete accepted choice cannot silently switch slots")
    prepare.cashCost = 1
    assert(not preview(999, primary), "a cash-bearing prerequisite cannot appear in a carried-only order")
    FC.InventoryAdapter.Snapshot = readStock
end
testMaximumRecursiveCarriedCrafts()

do (function()
    assert(FC.Queue.Initialize({}))
    local silk, leather, bolt, result = 4306, 4234, 4305, 5764
    stock[silk], stock[leather], stock[bolt], stock[result] = 0, 0, 0, 0
    stock[2321], stock[2605] = 6, 2
    mail[silk], mail[leather], ownerPending[silk], ownerPending[leather] = 0, 0, 0, 0
    inventorySource, inboxObserved, mailGeneration, money = "builtin", true, 1, 1000000
    Flux.Inventory.Mail.GetObservedCount = nil
    FC.Catalog.Snapshot = function()
        return {recipesById = {
            [6693] = {id = 6693, professionId = 197, learned = true, completeness = "complete",
                characterKey = FC.state.characterKey, outputKind = "item", outputItemID = result, yield = 1,
                reagents = {{itemID = bolt, quantity = 5}, {itemID = leather, quantity = 3},
                    {itemID = 2321, quantity = 3}, {itemID = 2605, quantity = 1}}},
            [3839] = {id = 3839, professionId = 197, learned = true, completeness = "complete",
                characterKey = FC.state.characterKey, outputKind = "item", outputItemID = bolt, yield = 1,
                reagents = {{itemID = silk, quantity = 4}}},
        }, byOutput = {[result] = {6693}, [bolt] = {3839}}, revision = 17}
    end
    local firstBudget = true
    FC.MarketAdapter.QuoteItems = function()
        return {[silk] = {unitPrice = firstBudget and 100 or 90, source = "fixture"},
            [leather] = {unitPrice = firstBudget and 50 or 60, source = "fixture"}}, {}
    end
    local function preview()
        return FC.Logistics.Preview({recipeId = 6693, quantity = 1, autoBuyVendor = false})
    end
    local first = assert(FC.Queue.Accept(preview(), preview))
    firstBudget = false
    local second = assert(FC.Queue.Accept(preview(), preview))
    assert(FC.Queue.CanGroup(first, second), "the two Green Silk Pack plans are compatible")
    local function materialEntries(itemID)
        local entries = {}
        for _, entry in ipairs(FC.Queue.GetRequirements()) do
            if entry.itemID == itemID then entries[#entries + 1] = entry end
        end
        return entries
    end
    local silkEntries, leatherEntries = materialEntries(silk), materialEntries(leather)
    assert(#silkEntries == 2 and silkEntries[1].quantity == 20 and silkEntries[2].quantity == 20)
    assert(#leatherEntries == 2 and leatherEntries[1].quantity == 3 and leatherEntries[2].quantity == 3)
    local quotes = {[silk] = {quantity = 40, totalCopper = 3401},
        [leather] = {quantity = 6, totalCopper = 241}}
    local prepared, issues = {}, {}
    FluxAuctionRestock.GetLogisticsState = function(request, quantity)
        local cached = prepared[request.itemID]
        if cached and cached.quantity == quantity and cached.maxUnitPrice == request.maxUnitPrice
            and cached.maxTotalPrice == request.maxTotalPrice and cached.groupRevision == request.groupRevision then
            return "ready", nil, quotes[request.itemID]
        end
    end
    FluxAuctionRestock.PrepareLogistics = function(request, quantity, authorize, _, explicit)
        assert(explicit and authorize(request, quantity))
        prepared[request.itemID] = request
        return true, "ready"
    end
    FluxAuctionRestock.ExecuteLogistics = function(request, quantity, authorize, observe)
        local quote = quotes[request.itemID]
        assert(authorize(request, quantity) and authorize(request, quote.quantity, quote.totalCopper))
        assert(not authorize(request, quantity + 1, quote.totalCopper))
        assert(not authorize(request, quote.quantity, (request.maxUnitPrice + 1) * quote.quantity))
        issues[request.itemID] = (issues[request.itemID] or 0) + 1
        local receipt = {jobId = request.jobId, id = request.id, itemID = request.itemID,
            planRevision = request.planRevision, quantity = quote.quantity, totalCopper = quote.totalCopper,
            attemptID = request.itemID, groupRevision = request.groupRevision}
        observe("submitted", receipt)
        assert(first.acquisition and second.acquisition and first.acquisition.attemptID == second.acquisition.attemptID,
            "one owner submission protects every paid share")
        receipt.groupRevision = "stale member selection"
        observe("confirmed", receipt)
        assert(first.acquisition and second.acquisition, "a differently identified group cannot consume the shared receipt")
        receipt.groupRevision = request.groupRevision
        observe("confirmed", receipt)
        observe("confirmed", receipt)
        return true, "buying"
    end

    local projected = {}
    for _, row in ipairs(FC.testAuctionRows.GetRows()) do
        if row.itemID == silk or row.itemID == leather then
            assert(not projected[row.itemID] and row.jobId == first.id and row.planRevision == first.planRevision)
            projected[row.itemID] = row.quantity
        end
    end
    assert(projected[silk] == 40 and projected[leather] == 6,
        "native Restock projects one exact row for each grouped input")
    assert(not FC.Logistics.GetGroupedAuctionNeed({silkEntries[1], silkEntries[1]}))
    second.rootRecipeId = 999999
    assert(FC.Logistics.GetGroupedAuctionNeed(silkEntries).toBuy == 40,
        "different accepted recipes can share a purchase for the same exact material")
    second.rootRecipeId = first.rootRecipeId
    local silkNeed = assert(FC.Logistics.GetGroupedAuctionNeed({silkEntries[2], silkEntries[1]}))
    assert(silkNeed.toBuy == 40 and silkNeed.maxUnitPrice == 90 and silkNeed.maxTotalPrice == 3600
        and silkNeed.groupRevision == FC.Logistics.GetGroupedAuctionNeed(silkEntries).groupRevision)
    assert(FC.Logistics.PrepareGroupedAuction(silkEntries, true) and not issues[silk])
    assert(not FC.Logistics.BuyGroupedAuction(silkEntries, {quantity = 40, totalCopper = 3400}) and not issues[silk])
    local unitCap = silkEntries[2].requirement.maxUnitPrice
    silkEntries[2].requirement.maxUnitPrice = unitCap - 1
    assert(not FC.Logistics.BuyGroupedAuction(silkEntries, quotes[silk]) and not issues[silk],
        "an updated order cap invalidates the displayed group quote")
    silkEntries[2].requirement.maxUnitPrice = unitCap
    assert(FC.Logistics.BuyGroupedAuction(silkEntries, quotes[silk]) and issues[silk] == 1)
    assert(silkEntries[1].requirement.auctionAwaiting == 20 and silkEntries[2].requirement.auctionAwaiting == 20
        and silkEntries[1].requirement.auctionSpent == 1700 and silkEntries[2].requirement.auctionSpent == 1701,
        "one 40-Silk purchase conserves both paid units and indivisible copper across the two caps")
    assert(FC.Logistics.PrepareGroupedAuction(leatherEntries, true))
    assert(FC.Logistics.BuyGroupedAuction(leatherEntries, quotes[leather]) and issues[leather] == 1)
    assert(leatherEntries[1].requirement.auctionAwaiting == 3 and leatherEntries[2].requirement.auctionAwaiting == 3
        and leatherEntries[1].requirement.auctionSpent == 120 and leatherEntries[2].requirement.auctionSpent == 121,
        "one 6-Leather receipt pays the two exact three-item shares")
    stock[silk], stock[leather], reports = 40, 6, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true, mail = true}})
    assert(#FC.Queue.GetRequirements(first) == 0 and #FC.Queue.GetRequirements(second) == 0
        and first.reservations[tostring(silk)] == 20 and second.reservations[tostring(silk)] == 20
        and first.reservations[tostring(leather)] == 3 and second.reservations[tostring(leather)] == 3,
        "actual carried collection settles both accepted jobs once")

    assert(FC.Queue.Initialize({}))
    stock[silk], stock[leather] = 0, 0
    firstBudget = true
    first = assert(FC.Queue.Accept(preview(), preview))
    firstBudget = false
    second = assert(FC.Queue.Accept(preview(), preview))
    leatherEntries, quotes[leather] = materialEntries(leather), {quantity = 4, totalCopper = 161}
    assert(FC.Logistics.PrepareGroupedAuction(leatherEntries, true))
    assert(FC.Logistics.BuyGroupedAuction(leatherEntries, quotes[leather]) and issues[leather] == 2
        and leatherEntries[1].requirement.auctionAwaiting == 3 and leatherEntries[2].requirement.auctionAwaiting == 1
        and FC.Logistics.GetAuctionNeed(leatherEntries[2]).toBuy == 2 and not FC.Logistics.GetGroupedAuctionNeed(leatherEntries),
        "a single smaller listing pays only its own shares and leaves the rest for a later press")
end)() end

do (function()
    local item, result, recipe = 2321, 5764, 6693
    local oldBoot = FluxAuctionRestock.VendorSource
    FluxAuctionRestock.VendorSource = function(id)
        if id == item then return true, 8, "fixture", "ordinary gold" end
        return oldBoot and oldBoot(id)
    end
    FluxAuctionRestock.VendorTerms = function(id) if id == item then return 40, 5 end end
    FC.Catalog.Snapshot = function()
        return {recipesById = {[recipe] = {id = recipe, professionId = 197, learned = true, completeness = "complete",
            characterKey = FC.state.characterKey, outputKind = "item", outputItemID = result, yield = 1,
            reagents = {{itemID = item, quantity = 5}}}}, byOutput = {[result] = {recipe}}, revision = 18}
    end
    FC.MarketAdapter.QuoteItems = function() return {}, {} end
    local calls, cap, stockLimit, price, auto = {}, nil, nil, 40, false
    FluxVendorAuto.GetLogisticsOffer = function(id)
        if id ~= item or not merchantVisible or not indexReady then return end
        return {kind = "vendor", offerId = "vendor:group:" .. id, itemID = id, unit = "item",
            qualified = true, bundleSize = 5, bundlePrice = price, availableUnits = stockLimit,
            marketContext = "vendor:group", locationKey = "vendor:group", revision = "tier:" .. price}
    end
    FluxVendorAuto.BuyForLogistics = function(offer, amount, validate)
        local quantity = math.min(amount, cap or amount)
        local cost = quantity / offer.bundleSize * offer.bundlePrice
        assert(offer.itemID == item and quantity % offer.bundleSize == 0 and validate(offer, quantity, cost))
        assert(not validate(offer, quantity, cost + 1), "a grouped vendor purchase rejects altered actual copper")
        calls[#calls + 1] = {requested = amount, issued = quantity, cost = cost}
        money = money - cost
        return true, nil, quantity
    end
    local function newJobs(automatic)
        merchantVisible, indexReady, auto = false, false, automatic
        policy.NotifyChanged("merchant")
        drain()
        assert(FC.Queue.Initialize({}))
        stock[item], money, price = 0, 400, 40
        mail[item], ownerPending[item], inboxObserved = 0, 0, true
        calls, cap, stockLimit = {}, nil, nil
        local function preview()
            return FC.Logistics.Preview({recipeId = recipe, quantity = 1, autoBuyVendor = auto})
        end
        local first = assert(FC.Queue.Accept(preview(), preview))
        local second = assert(FC.Queue.Accept(preview(), preview))
        assert(FC.Queue.CanGroup(first, second)
            and first.requirements[1].kind == "vendor" and second.requirements[1].kind == "vendor")
        return first, second
    end

    local first, second = newJobs(false)
    local closed = assert(FC.testRestockCraft.GetVendorStage())
    assert(closed.items[item] == 10 and not closed.canBuy)
    merchantVisible, indexReady = true, true
    local stage = assert(FC.testRestockCraft.GetVendorStage())
    assert(stage.items[item] == 10 and stage.canBuy and not FC.testRestockCraft.BuyVendorStage(closed.key))
    price = 39
    assert(not FC.testRestockCraft.BuyVendorStage(stage.key) and #calls == 0, "a changed visible price expires the HUD action")
    stage = assert(FC.testRestockCraft.GetVendorStage())
    assert(FC.testRestockCraft.BuyVendorStage(stage.key) and #calls == 1
        and calls[1].requested == 10 and calls[1].issued == 10 and calls[1].cost == 78
        and first.requirements[1].vendorIssuedCopper == 39 and second.requirements[1].vendorIssuedCopper == 39
        and first.acquisition and second.acquisition,
        "one manual grouped purchase preserves the two approved whole bundles and their actual price")
    assert(not FC.testRestockCraft.GetVendorStage() and not FC.testRestockCraft.BuyVendorStage(stage.key))
    stock[item], reports = 5, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
    assert(not first.acquisition and second.acquisition and first.reservations[tostring(item)] == 5
        and not second.reservations[tostring(item)], "five observed units belong to only the first paid share")
    stock[item], reports = 10, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
    assert(not first.acquisition and not second.acquisition and second.reservations[tostring(item)] == 5
        and #FC.Queue.GetRequirements(first) == 0 and #FC.Queue.GetRequirements(second) == 0 and #calls == 1,
        "the second share settles only when the rest really enters bags")

    first, second = newJobs(true)
    merchantVisible, indexReady = true, true
    policy.NotifyChanged("merchant")
    drain()
    assert(#calls == 1 and calls[1].requested == 10 and first.acquisition and second.acquisition,
        "the established automatic worker combines the same approved SKU")
    stock[item], reports = 10, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
    drain()
    assert(#calls == 1 and not first.acquisition and not second.acquisition)

    first, second = newJobs(false)
    merchantVisible, indexReady, cap = true, true, 5
    local selected = assert(FC.Queue.GetRequirements(first)[1])
    assert(FC.Logistics.Acquire(selected) and calls[1].requested == 10 and calls[1].issued == 5
        and first.acquisition and not second.acquisition and second.requirements[1].vendorIssuedUnits == 0,
        "a native stack cap pays only its first approved share")
    stock[item], reports = 5, reports + 1
    FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
    assert(not first.acquisition and not second.acquisition)

    first, second = newJobs(false)
    merchantVisible, indexReady, stockLimit = true, true, 10
    selected = assert(FC.Queue.GetRequirements(first)[1])
    assert(FC.Logistics.Acquire(selected) and calls[1].requested == 10 and second.acquisition,
        "a finite merchant offer can group orders when it covers both approved shares")

    first, second = newJobs(false)
    merchantVisible, indexReady, stockLimit = true, true, 5
    selected = assert(FC.Queue.GetRequirements(first)[1])
    assert(FC.Logistics.Acquire(selected) and calls[1].requested == 5 and not second.acquisition,
        "insufficient finite stock must not issue or debit the second accepted share")

    first, second = newJobs(false)
    local function uncertainPreview()
        return FC.Logistics.Preview({recipeId = recipe, quantity = 1, autoBuyVendor = false})
    end
    local unresolved = assert(FC.Queue.Accept(uncertainPreview(), uncertainPreview))
    unresolved.acquisition = {kind = "vendor", status = "uncertain", index = 1}
    merchantVisible, indexReady = true, true
    assert(not FC.testRestockCraft.GetVendorStage(), "another unsettled receipt blocks the same item in the HUD")
    selected = assert(FC.Queue.GetRequirements(first)[1])
    assert(FC.Logistics.Acquire(selected) and calls[1].requested == 5 and not second.acquisition,
        "a manual single order cannot widen into a group while that item's receipt is unresolved")
end)() end

do (function()
    local shared, thread, dye, extra, laterItem = 62101, 62102, 62103, 62104, 62105
    local outputs, recipes, observed, calls = {}, {}, {}, {}
    local function define(id, reagents)
        local outputID = id + 100
        outputs[outputID] = {id}
        recipes[id] = {id = id, professionId = 197, learned = true, completeness = "complete",
            characterKey = FC.state.characterKey, outputKind = "item", outputItemID = outputID, yield = 1, reagents = {}}
        for _, material in ipairs(reagents) do
            observed[material] = true
            recipes[id].reagents[#recipes[id].reagents + 1] = {itemID = material, quantity = 2}
        end
    end
    define(62201, {shared, thread})
    define(62202, {shared, dye})
    define(62203, {extra})
    define(62204, {laterItem})
    define(62205, {shared})
    define(62206, {shared})
    define(62207, {thread, dye})
    recipes[62207].reagents[1].quantity, recipes[62207].reagents[2].quantity = 30, 10
    FC.Catalog.Snapshot = function() return {recipesById = recipes, byOutput = outputs, revision = 19} end
    FC.MarketAdapter.QuoteItems = function() return {[shared] = {itemID = shared, unitPrice = 30}}, {} end
    local sharedVendorKnown = true
    FluxAuctionRestock.VendorSource = function(id)
        if observed[id] and (id ~= shared or sharedVendorKnown) then return true, 10, "fixture", "ordinary gold" end
    end
    FluxAuctionRestock.VendorTerms = function(id) if observed[id] then return 10, 1 end end
    local stackLimit, stackFailure
    FluxVendorAuto.GetLogisticsOffer = function(id)
        if observed[id] and merchantVisible and indexReady then
            return {kind = "vendor", offerId = "vendor:all:" .. id, itemID = id, unit = "item", qualified = true,
                bundleSize = 1, bundlePrice = 10, marketContext = "vendor:all", locationKey = "vendor:all", revision = "stable",
                slot = stackLimit and id or nil}
        end
    end
    FluxVendorAuto.BuyForLogistics = function(offer, amount, validate)
        if stackLimit then amount = math.min(amount, stackLimit) end
        assert(validate(offer, amount, amount * 10))
        local journaled
        for _, job in ipairs(FC.Queue.GetJobs()) do
            for _, action in ipairs(FC.Queue.Acquisitions(job)) do
                local requirement = job.requirements[action.index]
                if requirement and requirement.itemID == offer.itemID and action.dispatching then journaled = true end
            end
        end
        assert(journaled, "every native purchase has a pending accepted journal before issuance")
        calls[#calls + 1] = {itemID = offer.itemID, quantity = amount}
        if offer.itemID == thread and stackFailure and amount == 10 then
            if stackFailure == "uncertain" then error("Fixture merchant result lost") end
            return false, "Fixture merchant declines the second stack"
        end
        -- Leave the wallet stale until the mock receives observations.
        return true, nil, amount
    end
    local function enqueue(id, automatic)
        local function preview()
            return FC.Logistics.Preview({recipeId = id, quantity = 1, autoBuyVendor = automatic})
        end
        return assert(FC.Queue.Accept(preview(), preview))
    end
    local function merchant(budget)
        merchantVisible, indexReady = false, false
        nativeEvents.MERCHANT_CLOSED()
        drain()
        assert(FC.Queue.Initialize({}))
        calls, money = {}, budget
        for material in pairs(observed) do stock[material], mail[material], ownerPending[material] = 0, 0, 0 end
    end
    local function carried(id, quantity)
        stock[id], reports = quantity, reports + 1
        FC:Emit("INVENTORY_CHANGED", nil, {regions = {bags = true}})
        drain()
    end
    local function ordersOf(itemID)
        local count = 0
        for _, call in ipairs(calls) do
            if call.itemID == itemID then count = count + 1 end
        end
        return count
    end
    local function pendingItem(job)
        return job.acquisition and job.requirements[job.acquisition.index].itemID
    end
    local function receipt(job, itemID)
        for index, requirement in ipairs(job.requirements) do
            if requirement.itemID == itemID then return FC.Queue.GetAcquisition(job, index) end
        end
    end
    local function vendorTarget(job, itemID)
        for _, target in ipairs(policy.GetAcquisitionRequirements("vendor")) do
            if target.jobId == job.id and target.itemID == itemID then return target end
        end
    end
    local function outstanding(job)
        return #FC.Queue.GetRequirements(job)
    end
    local autoAllowed = false
    FluxVendorAuto.AllowsLogisticsAutomaticPurchase = function() return autoAllowed end
    local nativeVendorRestock, ownerVendorBuy, merchantPresses = FluxVendorAuto.DoRestockManual, policy.BuyVendorRequirements, 0
    policy.BuyVendorRequirements = ownerVendorBuy or function() return plannerProvider.BuyVendorRequirements(false) end
    FluxVendorAuto.DoRestockManual = function()
        merchantPresses = merchantPresses + 1
        return policy.BuyVendorRequirements()
    end
    merchant(100)
    local first, second, independent = enqueue(62201, false), enqueue(62202, false), enqueue(62203, false)
    merchantVisible, indexReady = true, true
    local stage = assert(plannerProvider.GetVendorStage())
    assert(stage.canBuy and stage.items[shared] == 4 and stage.items[thread] == 2 and stage.items[dye] == 2
        and stage.items[extra] == 2 and not FC.Queue.CanGroup(first, second))
    assert(not plannerProvider.BuyVendorRequirements(true) and #calls == 0,
        "the automatic pass respects the merchant preference even when plans are visible")
    assert(not FC.testRestockCraft.BuyVendorStage(stage.key .. "/stale") and merchantPresses == 0 and #calls == 0,
        "the pending action must reject an expired vendor stage before routing to the merchant")
    assert(FC.testRestockCraft.BuyVendorStage(stage.key) and merchantPresses == 1 and #calls == 4
        and receipt(first, shared) and receipt(second, shared) and receipt(independent, extra)
        and receipt(first, thread) and receipt(second, dye)
        and calls[1].itemID == shared and calls[1].quantity == 4
        and ordersOf(shared) == 1 and ordersOf(extra) == 1 and ordersOf(thread) == 1 and ordersOf(dye) == 1,
        "one merchant action submits every ready material before bags update and combines the shared exact offer")
    assert(vendorTarget(first, shared).pending and vendorTarget(first, thread).pending and vendorTarget(second, dye).pending,
        "owner Restock retains each temporary target with an independently pending receipt")
    local later = enqueue(62204, false)
    carried(thread, 2)
    assert(#calls == 4 and receipt(first, shared) and not receipt(first, thread) and receipt(second, dye)
        and vendorTarget(first, shared).pending and not vendorTarget(first, thread),
        "a later-issued material can arrive first and clear only its own target")
    carried(extra, 2)
    assert(#calls == 4 and not independent.acquisition and outstanding(independent) == 0,
        "the unrelated receipt cannot settle either share of the combined material")
    carried(shared, 2)
    assert(#calls == 4 and not first.acquisition and not vendorTarget(first, shared)
        and receipt(second, shared).credited == 0 and vendorTarget(second, shared).pending
        and ordersOf(shared) == 1,
        "the first share credits only its own job while the second still waits for the rest of the purchase")
    carried(dye, 2)
    assert(receipt(second, shared) and not receipt(second, dye) and not vendorTarget(second, dye))
    carried(shared, 4)
    assert(#calls == 4 and outstanding(first) == 0 and outstanding(second) == 0 and outstanding(later) == 1
        and not first.acquisition and not second.acquisition and ordersOf(laterItem) == 0,
        "the temporary requirements disappear after each carried allocation is credited once")

    do
        merchant(40)
        local job = enqueue(62201, true)
        merchantVisible, indexReady, autoAllowed = true, true, true
        assert(plannerProvider.BuyVendorRequirements(true) and #calls == 2 and #FC.Queue.Acquisitions(job) == 2,
            "automatic vendor restock submits distinct materials from one craft together")
        merchantVisible, indexReady = false, false
        nativeEvents.MERCHANT_CLOSED()
        assert(receipt(job, shared).status == "uncertain" and receipt(job, thread).status == "uncertain",
            "closing the merchant leaves all unconfirmed receipts available for reconciliation")
        carried(thread, 2)
        assert(not receipt(job, thread) and receipt(job, shared) and #calls == 2,
            "a late bag update after merchant close confirms its own material only")
        merchantVisible, indexReady = true, true
        merchantIndexReady()
        drain()
        assert(#calls == 2, "reopening the merchant cannot resubmit an uncertain receipt")
        carried(shared, 2)
        assert(not job.acquisition and outstanding(job) == 0 and #calls == 2,
            "the last late confirmation quietly clears the remaining temporary target")
    end

    do
        local merchantMaxStack = GetMerchantItemMaxStack
        GetMerchantItemMaxStack = function(slot)
            assert(slot == thread or slot == dye)
            return stackLimit
        end
        local function buyStacks(failure)
            merchant(400)
            local job = enqueue(62207, true)
            merchantVisible, indexReady, autoAllowed = true, true, true
            stackLimit, stackFailure = 20, failure
            local started = plannerProvider.BuyVendorRequirements(true)
            if not failure then assert(started) end
            return job
        end

        local job = buyStacks()
        assert(#calls == 3 and calls[1].itemID == thread and calls[1].quantity == 20
            and calls[2].itemID == thread and calls[2].quantity == 10 and calls[3].itemID == dye and calls[3].quantity == 10,
            "30 units of thread and 10 dye buy immediately using the merchant's 20-unit stack limit")
        assert(#FC.Queue.Acquisitions(job) == 2 and receipt(job, thread).quantity == 30 and receipt(job, dye).quantity == 10,
            "both thread stacks share one aggregate receipt and dye has its own receipt")
        assert(plannerProvider.BuyVendorRequirements(true) and #calls == 3, "another pass cannot duplicate unsettled stacks")
        carried(dye, 10)
        carried(thread, 20)
        assert(#calls == 3 and not vendorTarget(job, dye) and vendorTarget(job, thread).quantity == 10
            and receipt(job, thread).credited == 20, "only the undelivered part of the original quantity remains pending")
        carried(thread, 30)
        assert(#calls == 3 and not job.acquisition and outstanding(job) == 0)

        job = buyStacks("refused")
        assert(ordersOf(thread) == 2 and receipt(job, thread).status == "issued" and receipt(job, thread).quantity == 20
            and receipt(job, thread).totalCopper == 200, "a refused second request retains only the first issued stack")
        assert(plannerProvider.BuyVendorRequirements(true) and ordersOf(thread) == 2)

        job = buyStacks("uncertain")
        assert(ordersOf(thread) == 2 and receipt(job, thread).status == "uncertain" and receipt(job, thread).quantity == 30
            and receipt(job, thread).totalCopper == 300, "an ambiguous second request reserves its full possible delivery")
        local requested = ordersOf(thread)
        plannerProvider.BuyVendorRequirements(true)
        assert(ordersOf(thread) == requested, "an ambiguous stack cannot be issued again while awaiting review")
        stackLimit, stackFailure, GetMerchantItemMaxStack = nil, nil, merchantMaxStack
    end

    merchant(20)
    first, second = enqueue(62201, true), enqueue(62202, true)
    merchantVisible, indexReady, autoAllowed = true, true, true
    assert(plannerProvider.BuyVendorRequirements(true) and #calls == 1 and pendingItem(first) == shared
        and not second.acquisition, "the pass cannot spend the same unrefreshed wallet balance twice")
    autoAllowed = false
    carried(shared, 2)
    assert(#calls == 1 and outstanding(first) == 1 and outstanding(second) == 2,
        "changing the merchant preference stops further automatic issues after the current receipt")

    do
        merchant(100)
        local job = enqueue(62205, true)
        drain()
        local after, merchantSlots = C_Timer.After, GetMerchantNumItems
        local ensureIndex, followupBusy = FluxVendorAuto.EnsureMerchantIndex, FluxVendorAuto.IsAuctionFollowupBusy
        local delays, warmed, visibleSlots, busy = {}, 0, 1, true
        C_Timer.After = function(delay, callback)
            delays[callback] = delay
            after(delay, callback)
        end
        GetMerchantNumItems = function() return visibleSlots end
        FluxVendorAuto.EnsureMerchantIndex = function(force)
            assert(not force and merchantVisible and not indexReady)
            warmed, indexReady = warmed + 1, true
        end
        FluxVendorAuto.IsAuctionFollowupBusy = function() return busy end
        local function runNext(delay)
            local callback = table.remove(timers, 1)
            assert(callback and delays[callback] == delay, "unexpected merchant scheduling delay")
            callback()
        end

        autoAllowed, money = true, 0
        nativeEvents.MERCHANT_SHOW()
        assert(warmed == 0 and #calls == 0, "merchant open waits for FluxUI's native handlers")
        merchantVisible = true
        runNext(0)
        assert(warmed == 1 and #calls == 0, "the first frame joins FluxUI's index and respects native Restock")
        local targets = policy.GetAcquisitionRequirements("vendor")
        assert(#targets == 1 and targets[1].itemID == shared and targets[1].quantity == 2 and not targets[1].pending)
        busy, money = false, 100
        runNext(0)
        assert(#calls == 1 and pendingItem(job) == shared, "the next frame buys using the wallet after native Restock")
        targets = policy.GetAcquisitionRequirements("vendor")
        assert(#targets == 1 and targets[1].pending, "the temporary Restock target remains pending before bag confirmation")
        carried(shared, 2)
        assert(#calls == 1 and not job.acquisition and #policy.GetAcquisitionRequirements("vendor") == 0,
            "confirming bag stock clears the temporary Restock target")

        merchant(100)
        enqueue(62205, true)
        drain()
        visibleSlots, busy, merchantVisible = 0, true, true
        nativeEvents.MERCHANT_SHOW()
        for _ = 1, 4 do runNext(0) end
        assert(warmed == 1 and not indexReady and #calls == 0,
            "an unpopulated merchant leaves index readiness to FluxUI")
        assert(delays[timers[1]] == 0.15, "persistent ownership contention falls back to a bounded timer")
        merchantVisible = false
        nativeEvents.MERCHANT_CLOSED()
        runNext(0.15)
        drain()
        assert(#calls == 0, "closing the merchant cancels the deferred attempt")

        C_Timer.After, GetMerchantNumItems = after, merchantSlots
        FluxVendorAuto.EnsureMerchantIndex, FluxVendorAuto.IsAuctionFollowupBusy = ensureIndex, followupBusy
    end

    local function mixedOrders(plannedVendor, automatic)
        merchant(40)
        autoAllowed, inboxObserved, sharedVendorKnown = automatic, true, false
        local alternative = enqueue(62205, automatic)
        sharedVendorKnown = plannedVendor
        local secondOrder = enqueue(62206, automatic)
        sharedVendorKnown, merchantVisible, indexReady = true, true, true
        assert(alternative.requirements[1].kind == "auction"
            and secondOrder.requirements[1].kind == (plannedVendor and "vendor" or "auction"))
        return alternative, secondOrder
    end

    first, second = mixedOrders(true, false)
    local mixedStage = assert(plannerProvider.GetVendorStage())
    assert(mixedStage.canBuy and mixedStage.items[shared] == 4 and FC.testRestockCraft.BuyVendorStage(mixedStage.key)
        and #calls == 1 and calls[1].quantity == 4 and first.acquisition.substitutedAuction
        and not second.acquisition.substitutedAuction, "the manual vendor pass shares one exact live offer across both source plans")
    assert(not FC.testRestockCraft.BuyVendorStage(mixedStage.key) and #calls == 1,
        "the old mixed stage cannot submit its accepted shares again")
    carried(shared, 2)
    assert(not first.acquisition and second.acquisition and second.acquisition.credited == 0
        and first.requirements[1].kind == "auction" and first.requirements[1].vendorIssuedCopper == 20
        and second.requirements[1].vendorIssuedCopper == 20,
        "the earlier alternative takes the first carried share and each approved budget pays its own copper")
    carried(shared, 4)
    assert(#calls == 1 and outstanding(first) == 0 and outstanding(second) == 0)

    first, second = mixedOrders(false, true)
    assert(plannerProvider.BuyVendorRequirements(true) and #calls == 1 and calls[1].quantity == 4
        and first.acquisition.substitutedAuction and second.acquisition.substitutedAuction,
        "automatic restock can combine two independently approved merchant alternatives")
    carried(shared, 4)
    assert(#calls == 1 and outstanding(first) == 0 and outstanding(second) == 0)

    first, second = mixedOrders(true, false)
    first.requirements[1].auctionAwaiting = 2
    assert(plannerProvider.BuyVendorRequirements(false) and #calls == 1 and calls[1].quantity == 2
        and not first.acquisition and second.acquisition,
        "a paid auction receipt excludes just its overlapping order from the shared merchant offer")
    FluxVendorAuto.DoRestockManual, policy.BuyVendorRequirements = nativeVendorRestock, ownerVendorBuy
end)() end
