-- Desktop fixtures exercise the planner with the same public data shapes as
-- the workbench. Items, offers and API calls here are synthetic.
local ns = {target = "forever", state = {build = 16001}}
for _, source in ipairs({"Locale", "Planner", "Pricing", "Comparison", "AdaptersAuctionator"}) do
    assert(loadfile("FluxCraft/" .. source .. ".lua"))("FluxLogistics", ns)
end
local Planner, Market, Pricing = ns.Planner, ns.MarketAdapter, ns.Pricing
local actor = "US:Test:Current"

local function recipe(id, output, yield, reagents)
    return {id = id, outputItemID = output, yield = yield, reagents = reagents,
        characterKey = actor, learned = true, completeness = "complete"}
end

local function catalog(...)
    local result = {recipesById = {}, byOutput = {}, revision = 1}
    for _, entry in ipairs({...}) do
        result.recipesById[entry.id] = entry
        local outputs = result.byOutput[entry.outputItemID] or {}
        outputs[#outputs + 1] = entry.id
        result.byOutput[entry.outputItemID] = outputs
    end
    return result
end

local function plan(args, rootID, ...)
    args.catalog, args.rootRecipeId = catalog(...), rootID
    args.characterKey, args.quantity = actor, args.quantity or 1
    return Planner.Preview(args)
end

local function reagent(itemID, quantity)
    return {itemID = itemID, quantity = quantity}
end

local function offer(kind, id, locationKey, itemID, size, price, available)
    return {kind = kind, offerId = id, actorKey = actor, locationKey = locationKey,
        qualified = true, itemID = itemID, bundleSize = size, bundlePrice = price,
        availableUnits = available, unit = "item"}
end

-- Whole-unit comparisons at quantities one and eleven.
local batch = recipe(1, 100, 10, {reagent(101, 1)})
local finisher = recipe(2, 102, 1, {reagent(100, 1)})
local one = plan({quotes = {[100] = 10000, [101] = 60000}}, 2, batch, finisher)
assert(one.summary.fullValue == 10000 and #one.tasks == 1)
finisher.reagents[1].quantity = 11
local eleven = plan({quotes = {[100] = 10000, [101] = 60000}}, 2, batch, finisher)
assert(eleven.summary.fullValue == 70000 and #eleven.tasks == 2)
assert(eleven.requirements[1].itemID == 100 and eleven.requirements[1].quantity == 1)
local buy = plan({quotes = {[100] = 10000, [101] = 60000},
    choices = {[100] = {source = "Buy"}}}, 2, batch, finisher)
assert(buy.summary.fullValue == 110000 and #buy.tasks == 1)
assert(#buy.tree.children[1].children == 0 and #buy.requirements == 1)

-- Ownership uses the same replacement basis under either objective.
local bolt = recipe(10, 200, 1, {reagent(201, 5)})
local clothing = recipe(11, 202, 1, {reagent(200, 2)})
local function clothingPlan(objective)
    return plan({objective = objective, inventory = {[200] = 1, [201] = 5},
        quotes = {[200] = 40000, [201] = 20000}}, 11, bolt, clothing)
end
local value = clothingPlan("value")
assert(value.summary.fullValue == 80000 and value.summary.additionalCash == 40000)
local cash = clothingPlan("cash")
assert(cash.summary.fullValue == 140000 and cash.summary.additionalCash == 0)
assert(cash.tasks[2].allocations[1].kind == "owned")
assert(cash.tasks[2].allocations[2].producerTaskId == cash.tasks[1].taskId)

-- Competing recipes can both contribute to one item. A shared cooldown
-- constrains the combined count. Timed cooldowns rule out only the affected
-- producer when another route covers the need.
local low = recipe(20, 300, 2, {reagent(301, 1)})
local high = recipe(21, 300, 3, {reagent(301, 1)})
local usesFive = recipe(22, 302, 1, {reagent(300, 5)})
low.constraints, high.constraints = {maxExecutions = 1}, {maxExecutions = 1}
local function mixedCraft(now)
    return plan({now = now, quotes = {[300] = 10000, [301] = 100}}, 22, low, high, usesFive)
end
local mixed = mixedCraft(0)
assert(mixed.summary.fullValue == 200 and #mixed.tree.children[1].crafts == 2)
assert(#mixed.tasks[3].dependencies == 2 and mixed.summary.optimality == "exact")
low.constraints.cooldownPool, high.constraints.cooldownPool = "syntheticPool", "syntheticPool"
low.constraints.maxPoolExecutions = 1
assert(mixedCraft(0).summary.fullValue == 20100)
high.constraints.cooldownUntil = 5
assert(mixedCraft(4).summary.fullValue == 30100)
assert(mixedCraft(5).summary.fullValue == 20100)
local needsStation = recipe(23, 303, 1, {reagent(200, 1), reagent(204, 2)})
local requiresWheel = ns.L.clients.requires:format("Spinning Wheel")
needsStation.constraints = {requirementsMet = false, requirements = {{name = "Spinning Wheel", met = false}}}
local stationOptions = {quantity = 2, inventory = {[201] = 10},
    quotes = {[200] = 999, [201] = 1, [204] = 1}}
local missingStation = plan(stationOptions, 23, needsStation, bolt)
assert(missingStation.status == "blocked" and missingStation.blocker == requiresWheel)
stationOptions.deferRecipeRequirements = true
local deferredStation = plan(stationOptions, 23, needsStation, bolt)
assert(deferredStation.status == "sourcing" and deferredStation.craftRequirement == requiresWheel
    and #deferredStation.tasks == 2 and deferredStation.tasks[1].recipeId == bolt.id
    and deferredStation.tasks[2].recipeId == needsStation.id and deferredStation.tasks[2].executions == 2
    and deferredStation.tasks[2].dependencies[1] == deferredStation.tasks[1].taskId
    and #deferredStation.requirements == 1 and deferredStation.requirements[1].itemID == 204
    and deferredStation.requirements[1].quantity == 4)
stationOptions.bagsOnly, stationOptions.inventory[204] = true, 4
assert(plan(stationOptions, 23, needsStation, bolt).blocker == requiresWheel)
stationOptions.bagsOnly = nil
needsStation.constraints.cooldownUntil = 100
assert(plan(stationOptions, 23, needsStation, bolt).blocker == ns.L.clients.cooldown)
needsStation.constraints = {requirementsMet = false, blockedReason = "Native recipe disabled"}
assert(plan(stationOptions, 23, needsStation, bolt).status == "blocked")

local usesStationOutput = recipe(24, 305, 1, {reagent(303, 1)})
needsStation.constraints = {requirementsMet = false, requirements = {{name = "Spinning Wheel", met = false}}}
local alternative = plan({deferRecipeRequirements = true, quotes = {[303] = 500}}, 24, usesStationOutput, needsStation)
assert(alternative.status == "sourcing" and #alternative.tasks == 1
    and #alternative.requirements == 1 and alternative.requirements[1].itemID == 303)

-- Inspect a cooldown without accepting work or removing the live gate from
-- dependencies, bags-only recommendations or a direct supply order.
local cooling = recipe(25, 309, 2, {reagent(300, 1)})
cooling.constraints = {cooldownUntil = 100}
local constrainedOptions = {inspectUnavailable = true, now = 70, quantity = 4,
    quotes = {[300] = 10000, [301] = 100}}
local inspection = plan(constrainedOptions, 25, cooling, high)
assert(inspection.status == "blocked" and inspection.inspectionOnly and inspection.blocker == ns.L.clients.cooldown)
assert(inspection.tree.blocker == inspection.blocker and inspection.tree.children[1].recipeId == high.id)
assert(inspection.summary.output == 4 and inspection.summary.fullValue == 100)
assert(#inspection.tasks == 0 and #inspection.requirements == 0 and #inspection.allocations == 0)
constrainedOptions.bagsOnly = true
assert(not plan(constrainedOptions, 25, cooling, high).tree)
constrainedOptions.bagsOnly, constrainedOptions.inspectUnavailable = nil, nil
assert(not plan(constrainedOptions, 25, cooling, high).tree)
high.constraints.cooldownUntil = 100
constrainedOptions.inspectUnavailable = true
local blockedProducer = plan(constrainedOptions, 25, cooling, high)
assert(blockedProducer.summary.fullValue == 20000 and blockedProducer.tree.children[1].source == "Buy")
local directSupply = Planner.Preview({rootItemID = cooling.outputItemID, quantity = 4, now = 70,
    inspectUnavailable = true, catalog = catalog(cooling), characterKey = actor,
    quotes = {[cooling.outputItemID] = 1000}})
assert(directSupply.status == "sourcing" and not directSupply.inspectionOnly and #directSupply.tasks == 0)
local otherCharacter = recipe(26, 310, 1, {reagent(301, 1)})
otherCharacter.characterKey = "US:Test:Alt"
assert(not plan(constrainedOptions, 26, otherCharacter).tree)
high.constraints.cooldownUntil = 5
constrainedOptions.now = 101
assert(plan(constrainedOptions, 25, cooling, high).status ~= "blocked")

-- Reagent variants stay attached to the selected task, with exact slot
-- allocation. The planner can choose a known, cheaper reagent assignment.
local selectable = recipe(24, 304, 1, {reagent(306, 1)})
selectable.reagentChoices = {
    {reagents = {{itemID = 305, quantity = 1, slotIndex = 2}}},
    {reagents = {{itemID = 306, quantity = 1, slotIndex = 2}}},
}
local alternate = plan({quotes = {[305] = 10, [306] = 30}}, 24, selectable)
assert(alternate.tasks[1].reagentChoice.reagents[1].itemID == 305)
assert(alternate.tasks[1].inputs[1].slotIndex == 2 and alternate.summary.fullValue == 10)
local splitVariants = plan({quantity = 3, bagsOnly = true, inventory = {[305] = 1, [306] = 2}},
    24, selectable)
assert(splitVariants.status == "ready" and splitVariants.summary.executions == 3 and #splitVariants.tasks == 2)
assert(splitVariants.tasks[1].recipeId == 24 and splitVariants.tasks[2].recipeId == 24)
assert(splitVariants.tasks[1].inputs[1].itemID == 305 and splitVariants.tasks[1].executions == 1)
assert(splitVariants.tasks[2].inputs[1].itemID == 306 and splitVariants.tasks[2].executions == 2)
selectable.constraints = {maxExecutions = 1}
local inspectedVariants = plan({quantity = 3, inspectUnavailable = true, quotes = {[305] = 10, [306] = 30}},
    24, selectable)
assert(inspectedVariants.status == "blocked" and inspectedVariants.inspectionOnly)
assert(inspectedVariants.summary.fullValue == 30 and inspectedVariants.summary.executions == 3)
assert(inspectedVariants.tree.children[1].itemID == 305 and #inspectedVariants.tasks == 0)

-- A merchant's bundle and total capacity are shared by both consumers, and
-- its surplus is promised to the second branch rather than counted as bags.
local merch = offer("vendor", "vendor:1", "merchant:99", 401, 2, 105, 4)
local oneFromVendor = recipe(31, 402, 1, {reagent(401, 3)})
local twoFromVendor = recipe(32, 403, 1, {reagent(401, 3)})
local consumesBoth = recipe(33, 404, 1, {reagent(402, 1), reagent(403, 1)})
local vendor = plan({quotes = {[401] = 100, [402] = 1000, [403] = 1000},
    acquisitions = {[401] = {merch}}}, 33, oneFromVendor, twoFromVendor, consumesBoth)
assert(vendor.summary.additionalCash == 410)
local offers = {}
for _, entry in ipairs(vendor.requirements) do offers[entry.kind] = entry end
assert(offers.vendor.quantity == 4 and offers.auction.quantity == 2)
local merchantUnits, consumers = 0, 0
for _, quantity in pairs(offers.vendor.consumers) do
    merchantUnits, consumers = merchantUnits + quantity, consumers + 1
end
assert(merchantUnits == 4 and consumers == 2)
assert(merch.availableUnits == 4)
local overCap = Planner.Preview({rootItemID = 401, quantity = 1, characterKey = actor,
    quotes = {[401] = 100}, acquisitions = {[401] = {merch}}, unitCaps = {[401] = 50}})
assert(overCap.requirements[1].kind == "manual" and overCap.requirements[1].maxUnitPrice == 50)
assert(overCap.summary.fullValue == nil and overCap.tree.blocker == ns.L.planner.overCap)

-- An out-of-context vendor estimate supplies costing terms without live
-- access, and tracks an accepted whole-bundle cap for later matching.
local knownVendor = {itemID = 407, source = "vendor", unit = "item", unitPrice = 8,
    bundleSize = 5, bundlePrice = 40, provenance = "fixture catalogue", estimate = true}
local outOfContext = {rootItemID = 407, quantity = 6, characterKey = actor,
    quotes = {[407] = 20}, vendorEstimates = {[407] = knownVendor}}
local mixedEstimate = Planner.Preview(outOfContext)
assert(mixedEstimate.summary.fullValue == 60 and mixedEstimate.summary.surplus == 0
    and #mixedEstimate.requirements == 2 and mixedEstimate.tree.source == "Mixed")
local mixedUnit, mixedAverage = Pricing.MaterialUnitPrice(mixedEstimate.tree)
assert(mixedUnit == 10 and mixedAverage, "mixed AH and vendor units use their weighted prices")
local auctionRemainder = mixedEstimate.requirements[1]
assert(auctionRemainder.kind == "auction" and auctionRemainder.quantity == 1
    and auctionRemainder.maxUnitPrice == 20 and auctionRemainder.maxTotalPrice == 20
    and auctionRemainder.estimate and auctionRemainder.offer == nil)
outOfContext.choices = {[407] = {source = "Vendor"}}
local estimated = Planner.Preview(outOfContext)
local pendingVendor = estimated.requirements[1]
assert(estimated.status == "sourcing" and estimated.summary.optimality == "incomplete")
assert(estimated.summary.fullValue == 80 and estimated.summary.additionalCash == 80 and estimated.summary.surplus == 4)
assert(#estimated.requirements == 1 and pendingVendor.kind == "vendor" and pendingVendor.estimate)
assert(pendingVendor.requirementId == "407/vendor/estimate" and pendingVendor.availability == "unknown")
assert(pendingVendor.quantity == 10 and pendingVendor.goalQuantity == 6 and pendingVendor.offerId == nil)
assert(pendingVendor.maxUnitPrice == 8 and pendingVendor.maxTotalPrice == 80 and pendingVendor.locationKey == nil)
assert(pendingVendor.offer.bundleSize == 5 and pendingVendor.offer.bundlePrice == 40
    and pendingVendor.offer.provenance == knownVendor.provenance and not pendingVendor.offer.qualified
    and not pendingVendor.offer.actorKey and not pendingVendor.offer.availableUnits)
local bundleUnit, bundleAverage = Pricing.MaterialUnitPrice(estimated.tree)
assert(bundleUnit == 8 and not bundleAverage, "unit price divides by the full vendor bundle, including surplus")
outOfContext.quantity = 1
outOfContext.choices = nil
assert(Planner.Preview(outOfContext).requirements[1].kind == "auction", "one item is cheaper on the AH")
outOfContext.choices = {[407] = {source = "Vendor"}}
assert(Planner.Preview(outOfContext).requirements[1].maxTotalPrice == 40)
outOfContext.unitCaps = {[407] = 7}
assert(Planner.Preview(outOfContext).status == "blocked", "estimate must respect the target's caps")
outOfContext.unitCaps, outOfContext.choices = nil, nil
outOfContext.quantity = 6
local liveVendor = offer("vendor", "vendor:407", "merchant:99", 407, 2, 18, 2)
outOfContext.acquisitions = {[407] = {liveVendor}}
local liveWins = Planner.Preview(outOfContext)
assert(#liveWins.requirements == 2 and liveWins.summary.additionalCash == 98)
local liveRequirements = {}
for _, entry in ipairs(liveWins.requirements) do liveRequirements[entry.kind] = entry end
assert(liveRequirements.vendor.offerId == liveVendor.offerId and not liveRequirements.vendor.estimate)
assert(liveRequirements.auction.quantity == 4 and liveRequirements.vendor.quantity == 2)
liveVendor.availableUnits = 0
assert(Planner.Preview(outOfContext).summary.additionalCash == 120, "an exhausted live offer cannot fall back to itself")
outOfContext.acquisitions = nil
knownVendor.bundleSize, knownVendor.bundlePrice = 1, 8
assert(estimated.revision ~= Planner.Preview(outOfContext).revision, "changed denomination invalidates the preview")
knownVendor.unitPrice = 2
assert(Planner.Preview(outOfContext).requirements[1].kind == "auction", "inconsistent vendor terms are ignored")
outOfContext.vendorEstimates = nil
outOfContext.quotes = {[407] = {source = "merchant", unitPrice = 1, availability = "actual"}}
local unqualified = Planner.Preview(outOfContext)
assert(unqualified.requirements[1].kind == "manual" and unqualified.summary.additionalCash == nil)
assert(Pricing.MaterialUnitPrice(unqualified.tree) == nil)

-- Held units use the lower quoted replacement value, while comparison with
-- selling those same items retains their auction value.
local bottled = recipe(37, 419, 1, {reagent(418, 1)})
local vialEstimate = {itemID = 418, source = "vendor", unit = "item", unitPrice = 4,
    bundleSize = 5, bundlePrice = 20, provenance = "fixture catalogue", estimate = true}
local vialQuotes = {[418] = 5}
local heldVial = plan({inventory = {[418] = 1}, quotes = vialQuotes, vendorEstimates = {[418] = vialEstimate}}, 37, bottled)
assert(heldVial.summary.fullValue == 4 and heldVial.summary.additionalCash == 0
    and heldVial.summary.ownedAuctionValue == 5 and Pricing.MaterialUnitPrice(heldVial.tree.children[1]) == 4)
local vialSale = Pricing.Project(heldVial, {saleQuote = {itemID = 419, unitPrice = 100}})
assert(vialSale.estimatedProfit == 91 and vialSale.liquidationEstimate == 4.75)
local onlyVendor = plan({inventory = {[418] = 1}, vendorEstimates = {[418] = vialEstimate}}, 37, bottled)
assert(onlyVendor.summary.fullValue == 4 and not Pricing.Project(onlyVendor,
    {saleQuote = {itemID = 419, unitPrice = 100}}).liquidationEstimate)
local emptyLive = offer("vendor", "vendor:vial", "merchant:99", 418, 5, 15, 0)
local unavailableVial = plan({inventory = {[418] = 1}, quotes = vialQuotes,
    vendorEstimates = {[418] = vialEstimate}, acquisitions = {[418] = {emptyLive}}}, 37, bottled)
assert(unavailableVial.summary.fullValue == 5, "exhausted live stock suppresses that item's vendor replacement")
local oneVial = plan({quotes = vialQuotes, vendorEstimates = {[418] = vialEstimate}}, 37, bottled)
assert(oneVial.requirements[1].kind == "auction" and oneVial.summary.additionalCash == 5)
local fiveVials = plan({quantity = 5, quotes = vialQuotes, vendorEstimates = {[418] = vialEstimate}}, 37, bottled)
assert(fiveVials.requirements[1].kind == "vendor" and fiveVials.summary.additionalCash == 20
    and Pricing.MaterialUnitPrice(fiveVials.tree.children[1]) == 4)

local part = recipe(34, 416, 2, {reagent(415, 2)})
part.yieldMax = 3
local assembled = recipe(35, 417, 1, {reagent(416, 1)})
local manufactured = plan({quotes = {[415] = 30}, inventory = {[415] = 2}}, 35, part, assembled)
local manufacturedNode = manufactured.tree.children[1]
assert(manufacturedNode.required == 1 and manufacturedNode.fullValue == 60
    and Pricing.MaterialUnitPrice(manufacturedNode) == 30, "divide by guaranteed craft output even when one unit was requested")
assert(Pricing.MaterialUnitPrice({fullValue = 0, surplusUsed = 2}) == nil)

do
    local itemID = 420
    local request = {rootItemID = itemID, quantity = 10, intent = "supply", characterKey = actor,
        vendorEstimates = {[itemID] = {itemID = itemID, source = "vendor", unit = "item", unitPrice = 5,
            bundleSize = 5, bundlePrice = 25, provenance = "fixture catalog", estimate = true}}}
    local function atAuctionPrice(unitPrice, objective)
        request.objective = objective
        request.auctionDepth = {[itemID] = {itemID = itemID, commodity = true, complete = true,
            offers = {{quantity = 10, unitPrice = unitPrice}}}}
        return Planner.Preview(request)
    end
    for _, objective in ipairs({"value", "cash"}) do
        local cheaper = atAuctionPrice(4, objective)
        assert(cheaper.summary.fullValue == 40 and cheaper.requirements[1].kind == "auction")
        local equal = atAuctionPrice(5, objective)
        assert(equal.summary.fullValue == 50 and #equal.requirements == 1 and equal.requirements[1].kind == "vendor")
        local dearer = atAuctionPrice(6, objective)
        assert(dearer.summary.fullValue == 50 and dearer.requirements[1].kind == "vendor")
    end
end

-- Quantity comparison can choose one projected merchant bundle plus a craft.
local component = recipe(38, 408, 5, {reagent(409, 1)})
local mixedVendor = Planner.Preview({rootItemID = 408, quantity = 8, characterKey = actor, catalog = catalog(component),
    quotes = {[408] = 10, [409] = 9},
    vendorEstimates = {[408] = {itemID = 408, source = "vendor", unit = "item", unitPrice = 7 / 3,
        bundleSize = 3, bundlePrice = 7, provenance = "fixture catalogue", estimate = true}}})
assert(mixedVendor.summary.fullValue == 16 and mixedVendor.summary.surplus == 0 and #mixedVendor.tasks == 1)
assert(mixedVendor.tree.source == "Mixed" and mixedVendor.requirements[1].kind == "vendor")
assert(mixedVendor.requirements[1].quantity == 3 and mixedVendor.requirements[1].maxTotalPrice == 7)

-- Visiting priced routes first preserves a useful cost estimate even when
-- there are too many unpriced AH fallbacks to exhaust the search.
local manyInputs, manyVendorEstimates = {}, {}
for id = 451, 464 do
    manyInputs[#manyInputs + 1] = reagent(id, 1)
    manyVendorEstimates[id] = {itemID = id, source = "vendor", unit = "item", unitPrice = 2,
        bundleSize = 1, bundlePrice = 2, provenance = "fixture catalogue", estimate = true}
end
local manyVendor = plan({vendorEstimates = manyVendorEstimates, limits = {states = 600}},
    39, recipe(39, 465, 1, manyInputs))
assert(manyVendor.diagnostics.bounded and manyVendor.summary.optimality == "incomplete")
assert(manyVendor.summary.fullValue == 28 and manyVendor.summary.additionalCash == 28)

-- A live bank withdrawal is a sourcing requirement and a zero-gold
-- alternative with the same full stock value as the replacement quote.
local withdraw = offer("bank", "bank:1", "bank", 405, 1, nil, 3)
local bankRecipe = recipe(36, 406, 1, {reagent(405, 3)})
local bank = plan({quotes = {[405] = 20}, choices = {[405] = {source = "Bank"}},
    acquisitions = {[405] = {withdraw}}}, 36, bankRecipe)
assert(bank.status == "sourcing" and bank.requirements[1].kind == "bank")
assert(bank.summary.fullValue == 60 and bank.summary.additionalCash == 0)
local autoBank = plan({quotes = {[405] = 20}, acquisitions = {[405] = {withdraw}}}, 36, bankRecipe)
assert(autoBank.requirements[1].kind == "bank" and autoBank.summary.additionalCash == 0)
withdraw.observedAt = 5
local sameOffer = plan({quotes = {[405] = 20}, choices = {[405] = {source = "Bank"}},
    acquisitions = {[405] = {withdraw}}}, 36, bankRecipe)
assert(bank.revision == sameOffer.revision)
withdraw.availableUnits = 4
local changedOffer = plan({quotes = {[405] = 20}, choices = {[405] = {source = "Bank"}},
    acquisitions = {[405] = {withdraw}}}, 36, bankRecipe)
assert(bank.revision ~= changedOffer.revision)
withdraw.actorKey = "US:Test:Alt"
local foreign = plan({quotes = {[405] = 20}, acquisitions = {[405] = {withdraw}}}, 36, bankRecipe)
assert(foreign.requirements[1].kind == "auction")

-- Bags-only routes can succeed with no price feed. Future coverage applies
-- only to a stock target; production for a destination retains its identity.
local bagRecipe = recipe(40, 500, 1, {reagent(501, 1)})
local inBags = plan({bagsOnly = true, inventory = {[501] = 1}}, 40, bagRecipe)
assert(inBags.status == "ready" and inBags.summary.fullValue == nil)
assert(plan({bagsOnly = true}, 40, bagRecipe).status == "blocked")
local stock = plan({intent = "stockUpTo", quantity = 40,
    inventory = {[500] = 12}, committedCoverage = {[500] = 18}}, 40, bagRecipe)
assert(stock.goal.required == 10 and stock.summary.requested == 10)
local deliver = plan({intent = "delivery", destination = {actorKey = "alt", locationKey = "bags"},
    quantity = 10, inventory = {[500] = 50}}, 40, bagRecipe)
assert(deliver.tree.required == 10 and deliver.goal.destination.actorKey == "alt")
assert(plan({intent = "delivery"}, 40, bagRecipe).status == "blocked")

-- A restock item can be supplied with no final recipe, and a mixed supply
-- goal wraps genuine craft tasks and acquisition directly.
local shopping = Planner.Preview({rootItemID = 800, quantity = 4, intent = "stockUpTo",
    characterKey = actor, inventory = {[800] = 1}, quotes = {[800] = 200}})
assert(shopping.status == "sourcing" and #shopping.tasks == 0)
assert(shopping.goal.required == 3 and shopping.requirements[1].goalQuantity == 3)
assert(shopping.allocations[1].goal and not shopping.allocations[1].consumerTaskId)
local supplyBatch = Planner.Preview({rootItemID = 100, quantity = 11, catalog = catalog(batch),
    characterKey = actor, quotes = {[100] = 10000, [101] = 60000}})
assert(supplyBatch.summary.fullValue == 70000 and #supplyBatch.tasks == 1)
assert(supplyBatch.tasks[1].recipeId == batch.id and supplyBatch.goal.recipeId == nil)
assert(supplyBatch.requirements[1].goalQuantity == 1)
local deliveryStock = Planner.Preview({rootItemID = 800, quantity = 4, intent = "delivery",
    characterKey = actor, inventory = {[800] = 4}, destination = {actorKey = "alt", locationKey = "bags"}})
assert(deliveryStock.status == "ready" and #deliveryStock.tasks == 0 and #deliveryStock.requirements == 0)
assert(deliveryStock.allocations[1].kind == "owned" and deliveryStock.allocations[1].goal)

-- Bounded search and an unpriced eligible alternative must never establish
-- a proven cheapest route.
local unpriced = plan({quotes = {[100] = 10000}}, 2, batch, finisher)
assert(unpriced.summary.fullValue == 110000 and unpriced.summary.optimality == "incomplete")
local bounded = plan({quotes = {[100] = 10000, [101] = 1},
    limits = {craftChoices = 1}}, 2, batch, finisher)
assert(bounded.diagnostics.bounded and bounded.summary.optimality == "incomplete")

-- The lazy exact-quantity comparison and predicted profit refer to the
-- same requested quantity and never assume a sale of surplus output.
local comparisonRecipe = recipe(45, 600, 2, {reagent(601, 1)})
local comparisonParent = recipe(46, 602, 1, {reagent(600, 1)})
local comparisonCatalog = catalog(comparisonRecipe, comparisonParent)
local comparisonArgs = {catalog = comparisonCatalog, inventory = {},
    quotes = {[600] = 1000000, [601] = 600000}, characterKey = actor,
    rootRecipeId = 46, quantity = 1}
local presented = Planner.Preview(comparisonArgs)
local compare = ns.Comparison.BuildForNode(presented, presented.tree.children[1], comparisonArgs, actor)
assert(compare.makeSavings == 400000 and compare.makeSavingsPercent == 40)
local vendorComparison = {
    catalog = comparisonCatalog, inventory = {}, quotes = {[600] = 1000000}, characterKey = actor,
    rootRecipeId = 46, quantity = 1,
    vendorEstimates = {[601] = {itemID = 601, source = "vendor", unit = "item", unitPrice = 600000,
        bundleSize = 1, bundlePrice = 600000, provenance = "fixture catalogue", estimate = true}},
}
local vendorPlan = Planner.Preview(vendorComparison)
local vendorMake = ns.Comparison.BuildForNode(vendorPlan, vendorPlan.tree.children[1], vendorComparison, actor)
assert(vendorMake.makeSavings == 400000 and vendorMake.makeSavingsPercent == 40)
assert(vendorMake.make == vendorPlan.tree.children[1].fullValue and vendorMake.comparisonIncomplete)
comparisonArgs.rootRecipeId = 45
local sale = Planner.Preview(comparisonArgs)
local projected = Pricing.Project(sale, {saleQuote = {itemID = 600, unitPrice = 1000000},
    market = {cutRate = 0.1}})
assert(projected.estimatedNetSaleProceeds == 900000 and projected.saleAssumptions.quantity == 1)
assert(projected.estimatedGrossSaleProceeds == 1000000 and projected.estimatedGrossSaleUnitPrice == 1000000)
assert(projected.estimatedProfit == 300000 and projected.profitOnCostPercent == 50)
assert(Pricing.FormatCopper(-30152) == "-3g 1s 52c")
GetCoinTextureString = function(copper, size) assert(copper == 30152 and size == 10); return "coins" end
assert(Pricing.FormatCopper(-30152) == "-coins")
GetCoinTextureString = nil
local standardFees = Pricing.Project(sale, {saleQuote = {itemID = 600, unitPrice = 1000000}})
assert(standardFees.saleAssumptions.cutRate == 0.05 and standardFees.estimatedNetSaleProceeds == 950000)
assert(standardFees.estimatedProfit == 350000 and standardFees.estimatedGrossProfit == 400000)
local accepted = {summary = sale.summary, projection = projected}
local displayed = Pricing.AcceptedJobProjection(accepted)
assert(displayed.estimatedProfit == 350000 and displayed.profitOnCostPercent == standardFees.profitOnCostPercent)
assert(accepted.projection.estimatedProfit == 300000 and accepted.projection.saleAssumptions.cutRate == 0.10)
assert(not Pricing.AcceptedJobProjection({summary = sale.summary, projection = {estimatedProfit = 500}}))
local noMaterialValue = Pricing.AcceptedJobProjection({summary = {fullValue = 0},
    projection = {estimatedGrossSaleProceeds = 100}})
assert(noMaterialValue.estimatedProfit == 95 and noMaterialValue.profitOnCostPercent == nil)
local savedGrossOnly = Pricing.AcceptedJobProjection({summary = {requested = 5, output = 6, valueKnown = false},
    projection = {estimatedGrossSaleProceeds = 1000}})
assert(savedGrossOnly.estimatedGrossSaleProceeds == 1000 and savedGrossOnly.estimatedGrossSaleUnitPrice == 200
    and savedGrossOnly.saleAssumptions.quantity == 5 and not savedGrossOnly.estimatedProfit,
    "older accepted jobs can show the frozen auction price even with unknown crafting costs")

-- Optional providers are independently qualified by their public method
-- shape. Unknown and invalid prices remain missing on explicit selection.
_G.Auctionator, _G.TSM_API = nil, nil
assert(Market.GetQuote(100) == nil)
local called
_G.Auctionator = {API = {v1 = {
    GetAuctionPriceByItemID = function(caller, itemID)
        called = caller
        if itemID == 100 then return 5000 end
    end,
    GetAuctionPriceByItemLink = function(_, _) return 7000 end,
    IsAuctionDataExactByItemLink = function(_, _) return true end,
    GetAuctionAgeByItemID = function(_, _) return 2 end,
}}}
local default = Market.GetQuote(100)
assert(default.unitPrice == 5000 and default.estimate and default.age == 2 and called == "FluxLogistics")
local searchCount = 0
GetItemInfo = function(itemID) if itemID == 100 then return "Fixture Thread" end end
Auctionator.API.v1.MultiSearchExact = function(caller, terms)
    assert(caller == "FluxLogistics" and #terms == 1 and terms[1] == "Fixture Thread")
    searchCount = searchCount + 1
end
assert(not ns.AuctionatorAdapter.SearchExact(100) and searchCount == 0)
AuctionHouseFrame = {IsShown = function() return true end}
assert(ns.AuctionatorAdapter.SearchExact(100) and searchCount == 1)
assert(not ns.AuctionatorAdapter.SearchExact(101) and searchCount == 1)
local requestedItem, batchTerms, batchNames
GetItemInfo = function(itemID)
    if itemID == 100 then return "Fixture Thread" end
    if itemID == 103 or itemID == 104 then return "Ambiguous cloth" end
end
C_Item = {
    GetItemNameByID = function(itemID) if itemID == 101 then return "Fixture Dye" end end,
    RequestLoadItemDataByID = function(itemID) requestedItem = itemID end,
}
Auctionator.API.v1.MultiSearchAdvanced = function(caller, terms)
    assert(caller == "FluxLogistics" and batchTerms == nil)
    batchTerms = terms
end
local shopping = {{itemID = 100, quantity = 14}, {itemID = 101, quantity = 6, maxUnitPrice = 2500},
    {itemID = 102, quantity = 3}, {itemID = 103, quantity = 1}, {itemID = 104, quantity = 2},
    {itemID = 105, quantity = 0}}
local opened, forwarded, skipped = ns.AuctionatorAdapter.SearchList(shopping)
assert(opened and forwarded and skipped == 4 and requestedItem == 102 and #batchTerms == 2)
assert(batchTerms[1].searchString == "Fixture Thread" and batchTerms[1].isExact
    and batchTerms[1].quantity == 14 and batchTerms[1].maxPrice == nil)
assert(batchTerms[2].searchString == "Fixture Dye" and batchTerms[2].isExact
    and batchTerms[2].quantity == 6 and batchTerms[2].maxPrice == 2500)
Auctionator.API.v1.MultiSearchAdvanced = nil
Auctionator.API.v1.MultiSearchExact = function(caller, names)
    assert(caller == "FluxLogistics" and batchNames == nil)
    batchNames = names
end
opened, forwarded, skipped = ns.AuctionatorAdapter.SearchList(shopping)
assert(opened and not forwarded and skipped == 4 and #batchNames == 2
    and batchNames[1] == "Fixture Thread" and batchNames[2] == "Fixture Dye")
assert(not ns.AuctionatorAdapter.SearchList({shopping[3]}) and requestedItem == 102)
C_Item = nil
AuctionHouseFrame, GetItemInfo = nil, nil
assert(not ns.AuctionatorAdapter.SearchList(shopping))
assert(Market.GetQuote(100, nil, "tsm") == nil)
_G.TSM_API = {
    GetCustomPriceValue = function(expression, itemString)
        assert(expression == "DBMarket")
        if itemString == "i:100" then return 3000 end
        if itemString == "i:101:42" then return 4000 end
    end,
    ToItemString = function() return "i:101:42" end,
}
assert(Market.GetQuote(100).provider == "auctionator")
local tsm = Market.GetQuote(100, nil, "tsm")
assert(tsm.unitPrice == 3000 and tsm.expression == "DBMarket" and tsm.ageUnknown)
local variant = Market.GetQuote(101, {itemLink = "item:101", variantKey = "suffix:42", requireExact = true}, "tsm")
assert(variant.unitPrice == 4000 and variant.variantKey == "suffix:42")
_G.Auctionator.API.v1.GetAuctionPriceByItemID = function() error("not ready") end
assert(Market.GetQuote(100, nil, "auctionator") == nil)
assert(Market.GetQuote(100, nil, "auctionator", true).fallbackFrom == "auctionator")
_G.Auctionator = nil
assert(Market.GetQuote(100).provider == "tsm")
_G.TSM_API.GetCustomPriceValue = function() return 0 / 0 end
assert(Market.GetQuote(100) == nil)

-- An explicit output variant cannot use the cached price for a base item.
-- An ordinary item can still use its ID quote for an inexact or missing link quote.
do
    local link = "|Hitem:600:0:0:0:0:0:42:0:70:0:0:0:0|h[Variant output]|h"
    local ordinary = "|Hitem:600:0:0:0:0:0:0:0:70:0:0:0:0|h[Ordinary output]|h"
    local configuredPrice, basePrice, isExact = 100000, 100000, false
    local baseAge, linkAge, failBase
    local baseQueries = 0
    _G.Auctionator = {API = {v1 = {
        GetAuctionPriceByItemID = function(_, id)
            if id == 601 then return 100 end
            if id == 600 then
                baseQueries = baseQueries + 1
                if failBase then error("item ID query failed") end
                return basePrice
            end
        end,
        GetAuctionPriceByItemLink = function(_, itemLink)
            if itemLink == link then return configuredPrice end
            if itemLink == ordinary then return 20 end
        end,
        IsAuctionDataExactByItemLink = function() return isExact end,
        GetAuctionAgeByItemID = function() return baseAge end,
        GetAuctionAgeByItemLink = function() return linkAge end,
    }}}
    local output = recipe(40, 600, 1, {reagent(601, 1)})
    output.outputLink = link
    local fixture = {L = ns.L, Planner = Planner, Pricing = Pricing, MarketAdapter = Market,
        state = {characterKey = actor, db = {}, build = 16001}, On = function() end}
    fixture.InventoryAdapter = {
        GetStatus = function() return {source = "builtin"} end,
        GetRevision = function() return "bags:1" end,
        Snapshot = function() return {[601] = 1} end,
    }
    for _, source in ipairs({"Queue", "Logistics"}) do
        assert(loadfile("FluxCraft/" .. source .. ".lua"))("FluxLogistics", fixture)
    end
    assert(fixture.Queue.Initialize({}))
    local function preview()
        local plan, context = fixture.Logistics.Preview({recipeId = 40, quantity = 1}, catalog(output))
        assert(plan.status == "ready" and plan.summary.fullValue == 100)
        return context
    end
    local missing = preview()
    assert(missing.missingQuotes[600] == ns.L.market.auctionatorVariant and not missing.quotes[600])
    assert(not missing.projection.estimatedGrossProfit and baseQueries == 0)
    local mismatched = Pricing.Project({rootItemID = 600, summary = {output = 1, fullValue = 100}}, {
        saleQuote = {itemID = 600, itemLink = link, variantExact = false, unitPrice = 100000},
        market = {cutRate = 0.10},
    })
    assert(not mismatched.estimatedGrossProfit and not mismatched.estimatedProfit)
    local cached, requests = false, 0
    C_Item = {
        IsItemDataCachedByID = function(itemID) return itemID ~= 600 or cached end,
        RequestLoadItemDataByID = function(itemID)
            assert(itemID == 600)
            requests = requests + 1
        end,
    }
    isExact = true -- Auctionator's public exact method can report its base key during loading.
    local loading = preview()
    assert(not loading.projection.estimatedGrossProfit and not loading.quotes[600] and requests == 1)
    cached = true
    local aliased = preview()
    assert(not aliased.quotes[600] and aliased.missingQuotes[600] == ns.L.market.auctionatorVariant
        and not aliased.projection.estimatedGrossProfit,
        "a cached link can still use the base key even when Auctionator calls it exact")
    baseAge, linkAge = 2, 2
    assert(not preview().quotes[600], "equal price and age do not identify a distinct record")
    linkAge = 1
    local separatedByAge = preview()
    assert(separatedByAge.quotes[600].variantExact and separatedByAge.quotes[600].age == 1,
        "equal prices with distinct observed ages can identify different records")

    local baseAgeCalls = 0
    Auctionator.API.v1.GetAuctionAgeByItemID = function()
        baseAgeCalls = baseAgeCalls + 1
        return baseAgeCalls == 1 and 0 or 1
    end
    assert(not preview().quotes[600], "a change in base age while checking identity is ambiguous")
    Auctionator.API.v1.GetAuctionAgeByItemID = function() return baseAge end
    linkAge = baseAge
    TSM_API = {ToItemString = function() return "i:600:42" end,
        GetCustomPriceValue = function() return 200 end}
    assert(not Market.GetQuote(600, link, "auctionator"))
    local fallback = Market.GetQuote(600, link, "auctionator", true)
    assert(fallback.provider == "tsm" and fallback.fallbackFrom == "auctionator" and fallback.variantExact)
    TSM_API = nil

    configuredPrice = 50
    local exact = preview()
    assert(exact.quotes[600].variantExact and exact.quotes[600].variantKey)
    assert(exact.projection.estimatedGrossProfit == -50)
    failBase = true
    assert(not preview().quotes[600], "a failed item ID lookup provides no proof of identity")
    failBase, basePrice = false, nil
    assert(preview().quotes[600].variantExact, "a successful lookup without a base price preserves a distinct link quote")
    output.outputLink = ordinary
    isExact, basePrice, baseQueries = false, 100000, 0
    local base = preview()
    assert(base.quotes[600].requestedItemLink == ordinary and base.projection.estimatedGrossProfit == 99900)
    assert(baseQueries == 1)
    _G.Auctionator.API.v1.GetAuctionPriceByItemLink = nil
    assert(preview().projection.estimatedGrossProfit == 99900 and baseQueries == 2)

    local function bonusLink(suffix, upgrade, context, bonuses)
        return ("|Hitem:600:0:0:0:0:0:%d:0:70:0:%d:%d:%s|h[Fixture output]|h")
            :format(suffix, upgrade, context, bonuses)
    end
    local defaultTree = "1:3524:0:0:0:0:0:0"
    local ordinaryForever = bonusLink(0, 0, 0, defaultTree)
    output.outputLink = ordinaryForever
    cached = false
    local defaultPrice = preview()
    assert(defaultPrice.quotes[600].requestedItemLink == ordinaryForever
        and not defaultPrice.quotes[600].variantKey
        and defaultPrice.projection.estimatedGrossProfit == 99900 and requests == 1,
        "Forever recipe outputs with only the default bonus tree can use the item ID quote")

    isExact = true
    Auctionator.API.v1.GetAuctionPriceByItemLink = function() return 300 end
    assert(preview().projection.estimatedGrossProfit == 200,
        "a public full-link price is preferred when available for the default tree")

    cached = true
    Auctionator.API.v1.GetAuctionPriceByItemLink = function() return basePrice end
    for _, explicitVariant in ipairs({
        bonusLink(42, 0, 0, defaultTree),
        bonusLink(0, 1, 0, defaultTree),
        bonusLink(0, 0, 1, defaultTree),
        bonusLink(0, 0, 0, "2:3524:9999:0:0:0:0:0:0"),
        bonusLink(0, 0, 0, "1:3524:1:9:60:0"),
    }) do
        assert(not Market.GetQuote(600, explicitVariant, "auctionator"))
    end
    assert(not Market.GetQuote(600, {itemLink = ordinaryForever, requireExact = true,
        variantKey = "explicit"}, "auctionator"))
    ns.target = "classic"
    assert(not Market.GetQuote(600, ordinaryForever, "auctionator"))
    ns.target = "forever"
    Auctionator, C_Item = nil, nil
end

-- Five slots with two choices repeat producers 32 times per schematic. The
-- observation budget counts distinct reachable recipes, not repeated edges.
do
    local function withVariants(id, output, firstInput)
        local choices = {}
        for mask = 0, 31 do
            local inputs = {}
            for slot = 1, 5 do
                local variant = math.floor(mask / 2 ^ (slot - 1)) % 2
                inputs[slot] = {itemID = firstInput + (slot - 1) * 2 + variant, quantity = 1, slotIndex = slot}
            end
            choices[#choices + 1] = {reagents = inputs}
        end
        local data = recipe(id, output, 1, choices[1].reagents)
        data.reagentChoices = choices
        return data
    end

    local recipes = {withVariants(100, 1000, 2000)}
    for i = 0, 9 do
        recipes[#recipes + 1] = withVariants(110 + i, 2000 + i, 3000)
        recipes[#recipes + 1] = recipe(120 + i, 3000 + i, 1, {reagent(4000 + i, 1)})
    end
    local observed, expected, stocked = {}, 31, true
    local fixture = {L = ns.L, Planner = Planner, Pricing = Pricing,
        state = {characterKey = actor, db = {}, build = 16001}, On = function() end}
    fixture.InventoryAdapter = {
        GetStatus = function() return {source = "builtin"} end,
        GetRevision = function() return "bags:1" end,
        Snapshot = function(items)
            local stock = {}
            for _, itemID in ipairs(items) do
                assert(not observed[itemID], "inventory was queried twice for the same item")
                observed[itemID], stock[itemID] = true, stocked and 1 or 0
            end
            assert(#items == expected)
            return stock
        end,
    }
    fixture.MarketAdapter = {QuoteItems = function(items)
        local prices = {}
        for _, itemID in ipairs(items) do prices[itemID] = {itemID = itemID, unitPrice = 10, unit = "item"} end
        return prices
    end}
    for _, source in ipairs({"Queue", "Logistics"}) do
        assert(loadfile("FluxCraft/" .. source .. ".lua"))("FluxLogistics", fixture)
    end
    assert(fixture.Queue.Initialize({}))
    fixture.Logistics.GetSettings().market = {rate = 40, context = "Legacy settings"}
    local draft, context = fixture.Logistics.Preview({recipeId = 100, quantity = 1}, catalog(table.unpack(recipes)))
    assert(draft.status == "ready" and draft.summary.fullValue == 50 and observed[4009])
    assert(context.projection.saleAssumptions.cutRate == 0.05 and context.projection.estimatedProfit == -40.5,
        "existing saved rates cannot override the standard Auction House cut")

    -- Optional manufacturing comparisons can exceed the observation limit
    -- while an explicit source or producer still describes a small plan.
    local wideRecipes = {recipe(100, 1000, 1, {reagent(2000, 1)})}
    for index = 1, 90 do
        local inputs = {}
        for slot = 1, 8 do inputs[slot] = reagent(3000 + index * 8 + slot, 1) end
        wideRecipes[#wideRecipes + 1] = recipe(100 + index, 2000, 1, inputs)
    end
    local wideCatalog = catalog(table.unpack(wideRecipes))
    observed, expected, stocked = {}, 2, false
    local request = {recipeId = 100, quantity = 1}
    local oversized, reason = fixture.Logistics.Preview(request, wideCatalog)
    assert(not oversized and reason == ns.L.observationLimit and not next(observed))

    request.choices = {["2000"] = {source = "Buy"}}
    local bought, boughtContext = fixture.Logistics.Preview(request, wideCatalog)
    assert(bought.status == "sourcing" and #bought.tasks == 1 and bought.summary.fullValue == 10)
    assert(bought.requirements[1].itemID == 2000 and not observed[3009])
    assert(ns.Comparison.BuildForNode(bought, bought.tree.children[1], boughtContext, actor).comparisonIncomplete)

    observed, expected = {}, 10
    request.choices["2000"] = {source = "Make", recipeId = "102"}
    local pinned, pinnedContext = fixture.Logistics.Preview(request, wideCatalog)
    assert(pinned.status == "sourcing" and #pinned.tasks == 2 and pinned.tasks[1].recipeId == 102)
    assert(pinned.summary.fullValue == 80 and observed[3017] and not observed[3009]
        and pinnedContext.comparisonLimited)
end

do
    local bolts = recipe(800, 8000, 1, {reagent(8001, 5)})
    local clothing = recipe(801, 8002, 1, {reagent(8000, 1)})
    local books = {
        [8000] = {itemID = 8000, commodity = true, complete = true, offers = {
            {quantity = 50, unitPrice = 50}, {quantity = 10, unitPrice = 20},
        }},
        [8001] = {itemID = 8001, commodity = true, complete = true, offers = {
            {quantity = 50, unitPrice = 5}, {quantity = 400, unitPrice = 100},
        }},
    }
    local args = {quantity = 24, auctionDepth = books, quotes = {[8000] = 20, [8001] = 5}}
    local hybrid = plan(args, 801, bolts, clothing)
    local intermediate = hybrid.tree.children[1]
    assert(hybrid.summary.fullValue == 650 and hybrid.summary.optimality == "exact")
    assert(intermediate.source == "Mixed" and intermediate.craftCount == 10 and intermediate.buy == 14)
    local boughtBolts, boughtCloth = hybrid.requirements[1], hybrid.requirements[2]
    assert(boughtBolts.quantity == 14 and boughtBolts.maxTotalPrice == 400 and boughtBolts.maxUnitPrice == 50)
    assert(boughtCloth.quantity == 50 and boughtCloth.maxTotalPrice == 250 and boughtCloth.maxUnitPrice == 5)
    local onlyBuy, units, observed = Planner.DirectCost(args.quotes, 8000, 24, books)
    assert(onlyBuy == 900 and units == 24 and observed.complete and observed.maxUnitPrice == 50)
    local comparison = ns.Comparison.BuildForNode(hybrid, intermediate,
        {catalog = args.catalog, quotes = args.quotes, auctionDepth = books}, actor)
    assert(comparison.buy == 900 and comparison.make == 7250 and not comparison.comparisonIncomplete)
    assert(comparison.selectedSavings == 250 and math.abs(comparison.selectedSavingsPercent - 250 / 9) < 0.0001)
    args.quantity = 6
    assert(plan(args, 801, bolts, clothing).summary.fullValue == 120)
    args.quantity = 40
    local bounded = plan(args, 801, bolts, clothing)
    assert(bounded.tree.children[1].craftCount == 10 and bounded.summary.fullValue == 1450)
    assert(bounded.summary.optimality == "incomplete" and bounded.summary.searchBounded)

    local repeated = recipe(802, 8003, 1, {reagent(8000, 6), reagent(8000, 8)})
    args.quantity = 1
    local sharedDepth = plan(args, 802, repeated)
    assert(sharedDepth.summary.fullValue == 400 and #sharedDepth.requirements == 1)
    assert(sharedDepth.tree.children[1].fullValue == 120 and sharedDepth.tree.children[2].fullValue == 280)
    assert(sharedDepth.requirements[1].maxTotalPrice == 400 and sharedDepth.requirements[1].maxUnitPrice == 50)
    local unit, average = Pricing.MaterialUnitPrice(sharedDepth.tree.children[2])
    assert(unit == 35 and average, "shared demand labels the average of its remaining price tiers")
    books[8000].at = 100
    assert(plan(args, 802, repeated).revision == sharedDepth.revision)
    books[8000].complete = false
    local partial = plan(args, 802, repeated)
    assert(partial.summary.fullValue == 400 and partial.summary.optimality == "incomplete")
    books[8000].offers = {{quantity = 10, unitPrice = 20}}
    local insufficient = plan(args, 802, repeated)
    assert(insufficient.summary.fullValue == nil and insufficient.summary.knownValueSubtotal == 200)
    assert(insufficient.requirements[1].kind == "auction" and insufficient.requirements[1].quantity == 10
        and insufficient.requirements[1].maxTotalPrice == 200)
    assert(insufficient.requirements[2].kind == "manual" and insufficient.requirements[2].quantity == 4
        and insufficient.requirements[2].maxTotalPrice == nil)
    books[8000].offers = {}
    books[8000].complete = true
    local empty = plan(args, 802, repeated)
    assert(empty.summary.fullValue == nil and empty.requirements[1].kind == "manual"
        and empty.requirements[1].maxTotalPrice == nil)
    assert(Planner.DirectCost(args.quotes, 8000, 14, books) == nil)
end

do
    local clothID, boltID = 4338, 4339
    local bolts = recipe(820, boltID, 1, {reagent(clothID, 5)})
    local bags = recipe(821, 10051, 1, {reagent(boltID, 5)})
    local books = {[clothID] = {itemID = clothID, commodity = true, complete = true, offers = {
        {quantity = 882, unitPrice = 504}, {quantity = 2, unitPrice = 456},
        {quantity = 348, unitPrice = 500}, {quantity = 14, unitPrice = 501}, {quantity = 3, unitPrice = 502},
    }}}
    local args = {quantity = 20, auctionDepth = books, quotes = {[clothID] = 3},
        choices = {[boltID] = {source = "Make"}}}
    local large = plan(args, bags.id, bolts, bags)
    local requirement = large.requirements[1]
    local unit, average = Pricing.MaterialUnitPrice(large.tree.children[1].children[1])
    assert(large.summary.fullValue == 250464 and large.summary.additionalCash == 250464)
    assert(requirement.quantity == 500 and requirement.maxTotalPrice == 250464 and requirement.maxUnitPrice == 504)
    assert(unit == 250464 / 500 and average, "label one purchase across several tiers as a weighted unit price")

    args.quantity = 1
    local small = plan(args, bags.id, bolts, bags)
    assert(small.summary.fullValue == 12412 and small.requirements[1].quantity == 25
        and small.requirements[1].maxUnitPrice == 500, "the price depends on the requested craft quantity")

    local smallCraft = recipe(822, 10052, 1, {reagent(clothID, 2)})
    local flat = plan(args, smallCraft.id, smallCraft)
    unit, average = Pricing.MaterialUnitPrice(flat.tree.children[1])
    assert(unit == 456 and not average, "the same book uses a flat unit price if the lowest tier covers the full demand")
end

do
    local lots = {[8100] = {itemID = 8100, commodity = false, complete = true, offers = {
        {quantity = 2, total = 1, count = 1}, {quantity = 3, total = 9, count = 1},
        {quantity = 5, total = 8, count = 1},
    }}}
    local cost, quantity, metadata = Planner.DirectCost({}, 8100, 5, lots)
    assert(cost == 8 and quantity == 5 and metadata.complete and metadata.maxUnitPrice == 2)
    assert(Planner.DirectCost({}, 8100, 7, lots) == 9)
    assert(Planner.DirectCost({}, 8100, 4, lots) == nil)
    cost, quantity = Planner.DirectCost({}, 8100, 4, lots, {allowOverbuy = true})
    assert(cost == 8 and quantity == 5)

    local exact = recipe(810, 8101, 1, {reagent(8100, 5)})
    local basket = plan({auctionDepth = lots}, 810, exact)
    local requirement = basket.requirements[1]
    assert(basket.summary.fullValue == 8 and requirement.quantity == 5 and requirement.maxUnitPrice == 2)
    local unit, average = Pricing.MaterialUnitPrice(basket.tree.children[1])
    assert(unit == 1.6 and not average, "one stack has a single unit price even when the purchase cap rounds up")
    assert(#requirement.auctionLots == 1 and requirement.auctionLots[1].quantity == 5
        and requirement.auctionLots[1].total == 8 and requirement.auctionLots[1].count == 1)

    lots[8100].offers = {{quantity = 4, total = 5, count = 1}}
    exact.reagents = {reagent(8100, 2), reagent(8100, 2)}
    local shared = plan({auctionDepth = lots}, 810, exact)
    assert(shared.summary.fullValue == 5 and shared.requirements[1].quantity == 4)
    assert(shared.requirements[1].auctionLots[1].count == 1 and shared.tree.children[2].surplusUsed == 2)
    exact.reagents[2] = nil
    local excess = plan({auctionDepth = lots}, 810, exact)
    assert(excess.summary.fullValue == nil and excess.requirements[1].kind == "manual")
    local optedIn = plan({auctionDepth = lots, auctionAllowOverbuy = true}, 810, exact)
    assert(optedIn.summary.fullValue == 5 and optedIn.requirements[1].quantity == 4)
end

print("Milestone 1 sourcing, allocation, economics and provider fixtures passed")
