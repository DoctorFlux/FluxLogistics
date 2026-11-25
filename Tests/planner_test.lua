-- Synthetic fixtures only. No IDs or prices here assert a live WoW recipe.
_G.FluxCraft = {}
assert(loadfile("FluxCraft/Locale.lua"))("FluxLogistics", FluxCraft)
dofile("FluxCraft/Planner.lua")
dofile("FluxCraft/Pricing.lua")
local Planner = FluxCraft.Planner
local Pricing = FluxCraft.Pricing

local function g(value) return value * 10000 end
local function equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end
local function yes(value, label) if not value then error(label) end end
local function quote(itemID, gold)
    return {itemID = itemID, unitPrice = g(gold), unit = "item", source = "synthetic", estimate = true}
end
local function recipe(id, profession, output, yield, reagents, character)
    return {id = id, professionId = profession, professionName = profession,
        outputItemID = output, outputKind = "item", yield = yield,
        reagents = reagents, learned = true, characterKey = character or "current",
        completeness = "complete", revision = 1}
end
local function catalog(recipes)
    local result = {recipesById = {}, byOutput = {}, revision = 1}
    for _, entry in ipairs(recipes) do
        result.recipesById[entry.id] = entry
        result.byOutput[entry.outputItemID] = result.byOutput[entry.outputItemID] or {}
        table.insert(result.byOutput[entry.outputItemID], entry.id)
    end
    return result
end
local function findTask(plan, recipeId)
    for _, task in ipairs(plan.tasks or {}) do if task.recipeId == recipeId then return task end end
end
local function sourceQuantity(plan, itemID)
    for _, item in ipairs(plan.requirements or {}) do
        if item.itemID == itemID then return item.quantity end
    end
    return 0
end
local function run(request)
    request.characterKey = request.characterKey or "current"
    request.revisions = {catalog = 1, inventory = 1, prices = 1}
    local plan = Planner.Preview(request)
    yes(plan.status ~= "blocked", plan.blocker or "blocked plan")
    return plan
end

-- A/B: price comparisons propagate through the final recipe and respect overrides.
local boltCatalog = catalog({
    recipe(2, "Tailoring", 200, 1, {{itemID = 100, quantity = 4}}),
    recipe(3, "Tailoring", 300, 1, {{itemID = 200, quantity = 10}, {itemID = 400, quantity = 1}}),
})
local boltQuotes = {[100] = quote(100, 1), [200] = quote(200, 3), [400] = quote(400, 5)}
local base = {rootRecipeId = 3, quantity = 1, catalog = boltCatalog, inventory = {}, quotes = boltQuotes}
local bought = run(base)
equal(bought.summary.fullValue, g(35), "A buy bolt cost")
equal(sourceQuantity(bought, 200), 10, "A buy bolt requirement")
equal(findTask(bought, 2), nil, "A no bolt craft")
local made = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog, inventory = {},
    quotes = boltQuotes, choices = {[200] = {source = "Make"}}})
equal(made.summary.fullValue, g(45), "A make bolt cost")
equal(made.tree.fullValue, made.summary.fullValue, "A tree and parent cost agree")
equal(findTask(made, 2).executions, 10, "A queue bolt count")
equal(made.tree.children[1].craftCount, 10, "A tree bolt count")
equal(findTask(made, 3).dependencies[1], findTask(made, 2).taskId, "A dependency feeds final")
equal(made.tasks[1].recipeId, 2, "A prerequisite precedes final in task order")
yes(made.revision ~= bought.revision, "A source choice changes plan revision")
local quoteA = {itemID = 400, unitPrice = g(5), source = "synthetic",
    marketContext = {realm = "A", faction = "B"}}
local quoteB = {itemID = 400, unitPrice = g(5), source = "synthetic",
    marketContext = {faction = "B", realm = "A"}}
local stableA = Planner.Preview({rootRecipeId = 3, quantity = 1, catalog = boltCatalog,
    inventory = {}, quotes = {[100] = boltQuotes[100], [200] = boltQuotes[200], [400] = quoteA},
    characterKey = "current"})
local stableB = Planner.Preview({rootRecipeId = 3, quantity = 1, catalog = boltCatalog,
    inventory = {}, quotes = {[100] = boltQuotes[100], [200] = boltQuotes[200], [400] = quoteB},
    characterKey = "current"})
equal(stableA.revision, stableB.revision, "A equivalent quote records have stable revision")

local reverse = {[100] = quote(100, 0.5), [200] = quote(200, 3), [400] = quote(400, 5)}
local reverseAuto = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog, inventory = {}, quotes = reverse})
equal(reverseAuto.summary.fullValue, g(25), "B make wins")
equal(findTask(reverseAuto, 2).executions, 10, "B auto makes")
local reverseBuy = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog, inventory = {},
    quotes = reverse, choices = {[200] = {source = "Buy"}}})
equal(reverseBuy.summary.fullValue, g(35), "B forced Buy")

-- C: integer batches permit a mixed craft and purchase.
local mixCatalog = catalog({
    recipe(11, "Alchemy", 510, 10, {{itemID = 511, quantity = 1}}),
    recipe(12, "Tailoring", 512, 1, {{itemID = 510, quantity = 11}}),
})
local mixed = run({rootRecipeId = 12, quantity = 1, catalog = mixCatalog, inventory = {},
    quotes = {[510] = quote(510, 1), [511] = quote(511, 6)}})
equal(mixed.summary.fullValue, g(7), "C mixed optimum")
equal(findTask(mixed, 11).executions, 1, "C one craft")
equal(sourceQuantity(mixed, 510), 1, "C one purchase")
equal(mixed.tree.children[1].source, "Mixed", "C mixed tree")
equal(mixed.tree.fullValue, mixed.summary.fullValue, "C tree and parent cost agree")

-- D/H: additional outputs do not subtract finished stock; stock-up does.
local yieldCatalog = catalog({recipe(21, "Alchemy", 600, 2, {})})
local yieldPlan = run({rootRecipeId = 21, quantity = 5, catalog = yieldCatalog,
    inventory = {[600] = 50}, quotes = {}})
equal(yieldPlan.summary.executions, 3, "D executions")
equal(yieldPlan.summary.output, 6, "D output")
equal(yieldPlan.summary.surplus, 1, "D surplus")
local stockPlan = run({rootRecipeId = 21, quantity = 5, intent = "stockUpTo",
    catalog = yieldCatalog, inventory = {[600] = 2}, committedCoverage = {[600] = 6}, quotes = {}})
equal(#stockPlan.tasks, 0, "H stock-up complete")
equal(#stockPlan.requirements, 0, "H covered stock-up has no purchases")
equal(#stockPlan.allocations, 0, "H covered stock-up does not reserve more bags")
equal(stockPlan.tree.required, 5, "H covered stock-up can display the target")
equal(stockPlan.tree.ownedUsed, 2, "H covered stock-up displays carried units")
equal(stockPlan.tree.committed, 3, "H covered stock-up keeps commitments separate from carried units")

-- E: current-character cross-profession production, alt knowledge excluded.
local crossCatalog = catalog({
    recipe(31, "Alchemy", 700, 1, {{itemID = 701, quantity = 1}}),
    recipe(32, "Tailoring", 702, 1, {{itemID = 700, quantity = 1}}),
})
local crossPlan = run({rootRecipeId = 32, quantity = 1, catalog = crossCatalog,
    inventory = {}, quotes = {[700] = quote(700, 10), [701] = quote(701, 1)}})
yes(findTask(crossPlan, 31), "E Alchemy task exists")
equal(findTask(crossPlan, 32).dependencies[1], findTask(crossPlan, 31).taskId, "E cross profession dependency")
local alt = recipe(31, "Alchemy", 700, 1, {{itemID = 701, quantity = 1}}, "alt")
local altPlan = run({rootRecipeId = 32, quantity = 1, catalog = catalog({alt, crossCatalog.recipesById[32]}),
    inventory = {}, quotes = {[700] = quote(700, 10), [701] = quote(701, 1)}})
equal(findTask(altPlan, 31), nil, "E alt recipe excluded")

-- F: one owned stack and one planned surplus are each consumed at most once.
local sharedCatalog = catalog({
    recipe(41, "Tailoring", 801, 1, {{itemID = 800, quantity = 1}}),
    recipe(42, "Tailoring", 802, 1, {{itemID = 800, quantity = 1}}),
    recipe(43, "Tailoring", 803, 1, {{itemID = 801, quantity = 1}, {itemID = 802, quantity = 1}}),
})
local shared = run({rootRecipeId = 43, quantity = 1, catalog = sharedCatalog,
    inventory = {[800] = 1}, quotes = {[800] = quote(800, 1), [801] = quote(801, 10), [802] = quote(802, 10)}})
equal(sourceQuantity(shared, 800), 1, "F shared input sourced once")
equal(shared.summary.ownedValue, g(1), "F one owned input")
local surplusCatalog = catalog({
    recipe(44, "Alchemy", 804, 2, {{itemID = 805, quantity = 1}}),
    recipe(45, "Tailoring", 806, 1, {{itemID = 804, quantity = 1}, {itemID = 804, quantity = 1}}),
})
local surplus = run({rootRecipeId = 45, quantity = 1, catalog = surplusCatalog,
    inventory = {}, quotes = {[804] = quote(804, 10), [805] = quote(805, 1)}})
equal(findTask(surplus, 44).executions, 1, "F surplus credited once")
equal(sourceQuantity(surplus, 805), 1, "F one reagent for surplus batch")

-- G: owned intermediate terminates its branch but keeps its economic value.
local owned = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog,
    inventory = {[200] = 10}, quotes = boltQuotes})
equal(owned.summary.fullValue, g(35), "G full value")
equal(owned.summary.additionalCash, g(5), "G additional cash")
equal(owned.summary.ownedValue, g(30), "G owned value")
equal(findTask(owned, 2), nil, "G no hypothetical cloth consumption")
local forcedSkillup = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog,
    inventory = {[200] = 10}, quotes = boltQuotes, choices = {[200] = {source = "Make"}}})
equal(findTask(forcedSkillup, 2).executions, 10, "G forced Make remains available with owned stock")
local cashPlan = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog,
    inventory = {[200] = 10}, quotes = boltQuotes, objective = "cash"})
equal(cashPlan.summary.additionalCash, g(5), "G cash objective")
equal(cashPlan.summary.fullValue, g(35), "G cash objective keeps full value")

-- I: an absent or stale quote is unknown, not free or guaranteed profit.
local absent = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog,
    inventory = {}, quotes = {[100] = boltQuotes[100], [200] = boltQuotes[200]}})
equal(absent.summary.fullValue, nil, "I unknown full value")
equal(absent.summary.additionalCash, nil, "I unknown cash")
local stale = run({rootRecipeId = 3, quantity = 1, catalog = boltCatalog,
    inventory = {}, quotes = {[100] = boltQuotes[100], [200] = boltQuotes[200],
        [400] = {itemID = 400, unitPrice = 0, stale = true}}})
equal(stale.summary.fullValue, nil, "I stale quote unknown")
local projection = Pricing.Project(absent, {saleQuote = quote(300, 100), market = {cutRate = 0.05}})
equal(projection.estimatedProfit, nil, "I no guaranteed profit")
local valued = Pricing.Project(bought, {saleQuote = quote(300, 50),
    market = {cutRate = 0.05, deposit = g(2), depositRefundable = true}})
equal(valued.estimatedProfit, g(12.5), "I refundable deposit not lost")
equal(valued.realizedProfit, nil, "I no realized profit without evidence")

-- J: a conversion cycle terminates; a direct purchase remains viable.
local cycleCatalog = catalog({
    recipe(51, "Alchemy", 901, 1, {{itemID = 902, quantity = 1}}),
    recipe(52, "Alchemy", 902, 1, {{itemID = 901, quantity = 1}}),
})
local cycle = run({rootRecipeId = 51, quantity = 1, catalog = cycleCatalog,
    inventory = {}, quotes = {[901] = quote(901, 10), [902] = quote(902, 5)}})
equal(cycle.summary.fullValue, g(5), "J purchase breaks cycle")
yes(cycle.diagnostics.cycle, "J cycle detected")
equal(cycle.summary.optimality, "incomplete", "J cycle labels comparison")

-- Vendor bundles retain fractional unit values and count unspent units once.
local bundleCatalog = catalog({recipe(61, "Tailoring", 960, 1,
    {{itemID = 961, quantity = 3}, {itemID = 961, quantity = 1}})})
local bundle = run({rootRecipeId = 61, quantity = 1, catalog = bundleCatalog,
    inventory = {}, acquisitions = {[961] = {{itemID = 961, kind = "vendor",
        offerId = "vendor:mock:961", locationKey = "vendor:mock", actorKey = "current",
        bundleSize = 5, bundlePrice = g(4), unit = "item", qualified = true}}}})
equal(sourceQuantity(bundle, 961), 5, "bundle purchased once")
equal(bundle.summary.additionalCash, g(4), "bundle cost paid once")
equal(bundle.tree.fullValue, bundle.summary.fullValue, "bundle tree agrees")

-- Adapter boundary: the real normalizer's complete cached snapshot can feed
-- the planner without a second profession scan or hand-built recipe IDs.
FluxCraft.state = {characterKey = "synthetic-current", build = 16001}
_G.FluxCraftDB = nil
_G.GetProfessions = function() return 1, 2 end
_G.GetProfessionInfo = function(index)
    if index == 1 then return "Alchemy", nil, nil, nil, nil, nil, 171 end
    return "Tailoring", nil, nil, nil, nil, nil, 197
end
local openProfession = 171
local observedRows = {
        {recipeID = 2001, skillLineID = 171, skillName = "Alchemy", learned = true,
            outputItemID = 990, quantityMin = 1, quantityMax = 1,
            reagents = {{itemID = 989, count = 1}}},
        {recipeID = 2002, skillLineID = 197, skillName = "Tailoring", learned = true,
            outputItemID = 991, quantityMin = 1, quantityMax = 1,
            reagents = {{itemID = 990, count = 1}}},
}
_G.C_TradeSkillUI = {
    GetBaseProfessionInfo = function() return {professionID = openProfession} end,
    IsTradeSkillReady = function() return true end,
    GetRecipeInfo = function(id) return {recipeID = id, learned = true} end,
    GetProfessionInfoByRecipeID = function(id)
        return {professionID = id == 2001 and 171 or 197}
    end,
    GetRecipeSchematic = function(id)
        local row = id == 2001 and observedRows[1] or observedRows[2]
        return {outputItemID = row.outputItemID, quantityMin = 1, quantityMax = 1,
            reagentSlotSchematics = {{quantityRequired = 1,
                reagents = {{itemID = row.reagents[1].itemID}}}}}
    end,
}
_G.Flux = {Inventory = {Professions = {
    ListCachedRecipes = function(professionID)
        local rows = {}
        for _, row in ipairs(observedRows) do
            if row.skillLineID == professionID then rows[#rows + 1] = row end
        end
        return rows
    end,
    GetCompleteness = function() return "cached" end,
}}}
local Catalog = assert(loadfile("FluxCraft/Catalog.lua"))("FluxCraft", FluxCraft)
equal(Catalog.Refresh(), true, "catalog Alchemy session refresh")
openProfession = 197
equal(Catalog.Refresh(), true, "catalog Tailoring session refresh")
local normalized = Catalog.Snapshot()
equal(normalized.recipesById[2001].completeness, "complete", "catalog normalized completeness")
local integrated = run({rootRecipeId = 2002, quantity = 1, catalog = normalized,
    characterKey = "synthetic-current", inventory = {},
    quotes = {[989] = quote(989, 1), [990] = quote(990, 10)}})
equal(findTask(integrated, 2001).professionId, 171, "catalog cross-profession task")
equal(integrated.summary.fullValue, g(1), "catalog planner cost")

print("FluxCraft planner synthetic fixtures: PASS")
