-- Prints aggregate checks only, using a read-only copy of FluxLogistics' own saved data.
local input = assert(io.open(assert(arg[1]), "rb"))
assert(input:seek("end") <= 8 * 1024 * 1024, "unexpected addon saved-data size")
assert(input:seek("set"))
local data = assert(input:read("*a"))
input:close()
local globals = {}
local chunk = assert(load(data, "observed FluxLogistics data", "t", globals))
debug.sethook(function() error("saved-data instruction limit exceeded") end, "", 12000000)
local loaded, problem = pcall(chunk)
debug.sethook()
assert(loaded, problem)
local root = assert(globals.FluxLogisticsDB)
local characters = assert(root.catalog.characters)

local totals = {characters = 0, professions = 0, normalized = 0, qualified = 0,
    acceptedDirect = 0, constrained = 0, directFailures = 0, professionEdges = 0,
    crossPlans = 0, withinPlans = 0, testedLists = 0}
local now = os.time()
for actor, character in pairs(characters) do
    local build = character.builds[16001] or character.builds["16001"]
    if build then
        totals.characters = totals.characters + 1
        local ns = {state = {characterKey = actor, build = 16001, catalogBuildStore = build, db = {}}, On = function() end}
        for _, name in ipairs({"Locale", "Catalog", "Planner", "Queue", "Pricing", "Logistics", "RecipeList"}) do
            assert(loadfile("FluxCraft/" .. name .. ".lua"))("FluxLogistics", ns)
        end
        local snapshot = ns.Catalog.Snapshot()
        local recipes, quotes = snapshot.recipesById, {}
        local sample, carried
        for _ in pairs(build.professions) do totals.professions = totals.professions + 1 end
        local function quote(id)
            quotes[id] = {itemID = id, unit = "item", unitPrice = 97 + id % 59, source = "desktop fixture"}
        end
        for _, recipe in pairs(recipes) do
            totals.normalized = totals.normalized + 1
            if recipe.learned and recipe.completeness == "complete" and recipe.outputKind == "item" then
                totals.qualified = totals.qualified + 1
                quote(recipe.outputItemID)
                for _, itemID in ipairs(ns.Planner.DirectReagentItems(recipe)) do quote(itemID) end
                local constraints = recipe.constraints or {}
                if constraints.requirementsMet == false or constraints.maxExecutions == 0
                    or (constraints.cooldownUntil or 0) > now or (recipe.cashCost or 0) > 0 then
                    totals.constrained = totals.constrained + 1
                else
                    local stock = {}
                    local first = recipe.reagentChoices and recipe.reagentChoices[1]
                    for _, reagent in ipairs(first and first.reagents or recipe.reagents or {}) do
                        stock[reagent.itemID] = (stock[reagent.itemID] or 0) + reagent.quantity
                    end
                    local plan = ns.Planner.PreviewDirect({catalog = snapshot, rootRecipeId = recipe.id,
                        characterKey = actor, now = now, inventory = stock}, 1)
                    if plan and plan.status == "ready" and #plan.tasks == 1 and #plan.requirements == 0
                        and plan.tasks[1].recipeId == recipe.id and plan.tasks[1].executions == 1 then
                        totals.acceptedDirect = totals.acceptedDirect + 1
                        if not sample and next(stock) then sample, carried = recipe, stock end
                    else
                        totals.directFailures = totals.directFailures + 1
                    end
                end
            end
        end

        if sample then
            ns.InventoryAdapter = {
                Snapshot = function(ids)
                    local snapshotStock = {}
                    for _, id in ipairs(ids) do snapshotStock[id] = carried[id] or 0 end
                    return snapshotStock
                end,
                Count = function(id) return carried[id] or 0 end,
                GetStatus = function() return {source = "builtin", reliable = true} end,
                GetRevision = function() return "fixture" end,
            }
            ns.MarketAdapter = {QuoteItems = function() return quotes end}
            assert(ns.Queue.Initialize({}))
            ns.Logistics.GetSettings().market = {rate = 5}
            local rows = ns.RecipeList.Select(snapshot, sample.professionId,
                {filter = "favorites", search = "example note", group = "Test group"},
                {[tostring(sample.id)] = {group = "Test group", note = "Example note", favorite = true}},
                function(recipe) return recipe.name end)
            assert(#rows == 1 and rows[1].recipe.id == sample.id)
            for _, mode in ipairs({"fromBags", "best", "sell"}) do
                local row = {recipe = sample}
                ns.RecipeList.Evaluate(row, mode, "name", snapshot)
                assert(type(row.score) == "number", "shortlist mode could not evaluate a normalized learned recipe: " .. mode)
                if mode == "fromBags" then assert(row.score == 0 and row.badge == ns.L.now) end
            end
            totals.testedLists = totals.testedLists + 1
        end

        for _, recipe in pairs(recipes) do
            if recipe.learned and recipe.completeness == "complete" and recipe.outputKind == "item" then
                for _, itemID in ipairs(ns.Planner.DirectReagentItems(recipe)) do
                    for _, producerID in ipairs(snapshot.byOutput[itemID] or {}) do
                        local producer = recipes[producerID]
                        if producer.learned and producer.completeness == "complete" and recipe.id ~= producer.id then
                            local cross = producer.professionId ~= recipe.professionId
                            if cross then totals.professionEdges = totals.professionEdges + 1 end
                            local planKey = cross and "crossPlans" or "withinPlans"
                            if totals[planKey] < 10 then
                                local request = {catalog = snapshot, rootRecipeId = recipe.id,
                                    characterKey = actor, quantity = recipe.yield, now = now, inventory = {}, quotes = quotes,
                                    choices = {[itemID] = {source = "Make", recipeId = producer.id}},
                                    limits = {states = 1200, depth = 12, craftChoices = 20}}
                                local plan = ns.Planner.Preview(request)
                                for position, task in ipairs(plan.tasks or {}) do
                                    if position < #plan.tasks and task.recipeId == producer.id
                                        and plan.tasks[#plan.tasks].recipeId == recipe.id then
                                        assert(ns.Queue.Initialize({}))
                                        local job = assert(ns.Queue.Accept(plan, function() return ns.Planner.Preview(request) end))
                                        local acceptedProducer, consumer = job.tasks[position], job.tasks[#job.tasks]
                                        local linked = false
                                        for _, allocation in ipairs(consumer.allocations or {}) do
                                            if allocation.producerTaskId == acceptedProducer.taskId then linked = true; break end
                                        end
                                        assert(linked and acceptedProducer.recipeId == producer.id and consumer.recipeId == recipe.id
                                            and not ns.Queue.CanProcess(job, consumer), "consumer went ahead of its prerequisite")
                                        totals[planKey] = totals[planKey] + 1
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
print(("Saved Forever observations: %d character catalog(s), %d profession buckets, %d recipes, %d qualified item recipes")
    :format(totals.characters, totals.professions, totals.normalized, totals.qualified))
print(("Direct planner with seeded carried materials: %d exact one-craft plans, %d with stored live constraints, %d other failures")
    :format(totals.acceptedDirect, totals.constrained, totals.directFailures))
print(("Dependency enumeration: %d candidate cross-profession links, %d verified cross-profession and %d same-profession plans (capped at 10 each)")
    :format(totals.professionEdges, totals.crossPlans, totals.withinPlans))
print(("Recipe organization and planner shortlist modes checked against %d observed catalogues"):format(totals.testedLists))
assert(totals.normalized > 0 and totals.acceptedDirect > 0, "no usable game observations")
