local addonName, FluxCraft = ...
if type(FluxCraft) ~= "table" then
    FluxCraft = _G.FluxCraft or {}
    _G.FluxCraft = FluxCraft
end

local Planner = {}
FluxCraft.Planner = Planner
local L = FluxCraft.L.planner
local forkedLedgers = {"pending", "owned", "taskOrder", "crafted", "craftedPools",
    "allocations", "unknownPrices", "auctionUse"}

-- Pure planning code. Amounts are item units and prices are copper, including
-- fractional copper internally. A quote is an estimate, never an AH order.
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function shallow(value)
    local result = {}
    for key, child in pairs(value) do result[key] = child end
    return result
end

-- Fork mutable ledgers at a source decision. Quote records, exact inputs,
-- observed reagent assignments and allocation entries are immutable here.
local function fork(state)
    local branch = shallow(state)
    for _, key in ipairs(forkedLedgers) do
        branch[key] = shallow(state[key])
    end
    branch.surplus = copy(state.surplus)
    branch.tasks = {}
    for id, task in pairs(state.tasks) do
        local nextTask = shallow(task)
        nextTask.dependencies = shallow(task.dependencies)
        nextTask.allocations = shallow(task.allocations)
        nextTask.sourcingRequirements = shallow(task.sourcingRequirements)
        branch.tasks[id] = nextTask
    end
    branch.nodes = {}
    for id, node in pairs(state.nodes) do
        local nextNode = shallow(node)
        nextNode.children = shallow(node.children)
        nextNode.purchases = shallow(node.purchases)
        nextNode.crafts = shallow(node.crafts)
        branch.nodes[id] = nextNode
    end
    branch.requirements = {}
    for id, requirement in pairs(state.requirements) do
        local nextRequirement = shallow(requirement)
        nextRequirement.consumers = shallow(requirement.consumers)
        if requirement.auctionLots then nextRequirement.auctionLots = shallow(requirement.auctionLots) end
        branch.requirements[id] = nextRequirement
    end
    return branch
end

local function field(map, key)
    if not map then return nil end
    return map[key] or map[tostring(key)]
end

local function itemKey(itemID)
    return tostring(itemID)
end

function Planner.GetSourceChoice(choices, itemID)
    local choice = field(choices, itemID)
    if type(choice) ~= "table" then choice = {} end
    local source = type(choice.source) == "string" and choice.source:lower()
    if source ~= "make" and source ~= "buy" and source ~= "bank" and source ~= "vendor" then source = "auto" end
    return source, choice
end

local function integer(value)
    return type(value) == "number" and value >= 0 and value < math.huge and value == math.floor(value)
end

local function money(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

local function positiveInteger(value)
    return integer(value) and value > 0
end

local function appendUnique(list, value)
    if value == nil then return end
    for i = 1, #list do if list[i] == value then return end end
    list[#list + 1] = value
end

local function reagentListUsable(reagents)
    if type(reagents) ~= "table" then return false end
    for _, reagent in ipairs(reagents) do
        if not reagent.itemID or not positiveInteger(reagent.quantity) then return false end
    end
    return true
end

local function recipeUsable(recipe, characterKey)
    if type(recipe) ~= "table" or recipe.learned ~= true then return false end
    if not characterKey or recipe.characterKey ~= characterKey then return false end
    if recipe.outputKind and recipe.outputKind ~= "item" then return false end
    if not recipe.id or not recipe.outputItemID or not positiveInteger(recipe.yield) then return false end
    if recipe.completeness ~= true and recipe.completeness ~= "complete" then return false end
    return reagentListUsable(recipe.reagents)
end

local function constraintsFor(recipe)
    return recipe.constraints or recipe
end

local function reagentChoices(recipe)
    if type(recipe.reagentChoices) ~= "table" or #recipe.reagentChoices == 0 then
        return {{reagents = recipe.reagents}}
    end
    local choices = {}
    for _, choice in ipairs(recipe.reagentChoices) do
        if reagentListUsable(choice.reagents) then choices[#choices + 1] = choice end
    end
    return choices
end

local function quoteFor(quotes, itemID)
    local quote = field(quotes, itemID)
    if type(quote) == "number" then quote = {unitPrice = quote, itemID = itemID} end
    if type(quote) ~= "table" or quote.stale or quote.valid == false then return nil end
    if quote.kind == "vendor" or quote.source == "merchant" or quote.source == "vendor" then return nil end
    if quote.itemID and tostring(quote.itemID) ~= tostring(itemID) then return nil end
    if quote.unit and quote.unit ~= "item" then return nil end
    if quote.extraCurrency and (type(quote.extraCurrency) ~= "table"
        or next(quote.extraCurrency) ~= nil) then return nil end
    if positiveInteger(quote.bundleSize) and money(quote.bundlePrice) then
        quote = copy(quote)
        quote.unitPrice = quote.bundlePrice / quote.bundleSize
    end
    if not money(quote.unitPrice) then return nil end
    return quote
end

-- Depth is separate from replacement quotes. An observed empty book is
-- evidence about available purchases, not a price for inventory already owned.
local function depthRecord(quotes, auctionDepth, itemID)
    local price = field(quotes, itemID)
    return field(auctionDepth, itemID) or type(price) == "table" and price.depth or nil
end

local function auctionDepthFor(quotes, auctionDepth, itemID, cap)
    local book = depthRecord(quotes, auctionDepth, itemID)
    if type(book) ~= "table" or itemKey(book.itemID) ~= itemKey(itemID)
        or book.stale or book.valid == false or type(book.commodity) ~= "boolean"
        or type(book.offers) ~= "table" then return nil end
    if not money(cap) or cap == 0 then cap = nil end
    local depth = {commodity = book.commodity, complete = book.complete == true, groups = {}, available = 0}
    local groups = {}
    for _, offer in ipairs(book.offers) do
        local record = type(offer) == "table" and offer or {}
        local size = book.commodity and 1 or record.quantity
        local price = book.commodity and record.unitPrice or not book.commodity and record.total
        local count = book.commodity and record.quantity or not book.commodity and (record.count or 1)
        if positiveInteger(size) and positiveInteger(price) and positiveInteger(count) then
            local limit = math.ceil(price / size)
            if not cap or limit <= cap then
                local group = groups[size]
                if not group then
                    group = {size = size, prices = {}, levels = {}, count = 0}
                    groups[size] = group
                    depth.groups[#depth.groups + 1] = group
                end
                group.prices[price] = (group.prices[price] or 0) + count
                depth.available = depth.available + size * count
            end
        else
            depth.complete = false
        end
    end
    for _, group in ipairs(depth.groups) do
        local prices = {}
        for price in pairs(group.prices) do prices[#prices + 1] = price end
        table.sort(prices)
        local total = 0
        for _, price in ipairs(prices) do
            local count = group.prices[price]
            group.count = group.count + count
            total = total + count * price
            group.levels[#group.levels + 1] = {price = price, count = group.count, total = total}
        end
        group.prices = nil
    end
    table.sort(depth.groups, function(a, b)
        local aPrice, bPrice = a.levels[1].price / a.size, b.levels[1].price / b.size
        if aPrice ~= bPrice then return aPrice < bPrice end
        return a.size > b.size
    end)
    return depth
end

local function depthPrefix(group, count)
    if count == 0 then return 0 end
    local first, last = 1, #group.levels
    while first < last do
        local middle = math.floor((first + last) / 2)
        if count <= group.levels[middle].count then last = middle else first = middle + 1 end
    end
    local level = group.levels[first]
    return level.total - (level.count - count) * level.price, first
end

local function marketLotPurchase(group, used, count)
    local endingCost, last = depthPrefix(group, used + count)
    local lastPrice = group.levels[last].price
    return {group = group, used = used, count = count, quantity = group.size * count,
        total = endingCost - depthPrefix(group, used), limit = math.ceil(lastPrice / group.size),
        lastPrice = lastPrice}
end

local function addCost(state, kind, itemID, amount, quote, fullPrice, depthFallback)
    if amount <= 0 then return end
    if quote then
        local cost = fullPrice or quote.unitPrice * amount
        state.partialValue = state.partialValue + cost
        if kind == "buy" then state.partialCash = state.partialCash + cost
        else state.partialOwned = state.partialOwned + cost end
    else
        state.unknownPrices[itemKey(itemID)] = true
        if not depthFallback then state.independentUnpriced = true end
        state.valueKnown = false
        if kind == "buy" then state.cashKnown = false
        else state.ownedKnown = false end
    end
end

local function putDependency(state, consumerId, producerId)
    if not consumerId or not producerId or consumerId == producerId then return end
    appendUnique(state.tasks[consumerId].dependencies, producerId)
end

local function allocate(state, taskId, allocation)
    if allocation.quantity <= 0 then return end
    state.allocations[#state.allocations + 1] = allocation
    if taskId then
        allocation.consumerTaskId = taskId
        local allocations = state.tasks[taskId].allocations
        allocations[#allocations + 1] = copy(allocation)
    else
        allocation.goal = true
    end
end

local function consumeSurplus(state, itemID, requested, consumerId)
    local entries = state.surplus[itemKey(itemID)] or {}
    local used = 0
    local index = 1
    while index <= #entries and used < requested do
        local entry = entries[index]
        local take = math.min(entry.quantity, requested - used)
        entry.quantity = entry.quantity - take
        used = used + take
        putDependency(state, consumerId, entry.taskId)
        allocate(state, consumerId, {kind = entry.taskId and "production" or "acquisition",
            itemID = itemID, quantity = take, producerTaskId = entry.taskId,
            requirementId = entry.requirementId, actorKey = state.actorKey})
        if entry.requirementId and consumerId then
            local sourcing = state.tasks[consumerId].sourcingRequirements
            local key = itemKey(itemID)
            sourcing[key] = (sourcing[key] or 0) + take
            local consumers = state.requirements[entry.requirementId].consumers
            consumers[consumerId] = (consumers[consumerId] or 0) + take
        end
        if entry.quantity == 0 then table.remove(entries, index) else index = index + 1 end
    end
    return used
end

local function directOffer(quote)
    local kind = quote and "auction" or "manual"
    return {kind = kind, offerId = kind, quote = quote,
        bundleSize = quote and positiveInteger(quote.bundleSize) and quote.bundleSize or 1,
        availableUnits = quote and quote.availability == "actual" and quote.availableUnits or nil}
end

local function qualifiedOffer(record, itemID, actorKey, replacementQuote)
    if type(record) ~= "table" or record.qualified ~= true or record.estimate == true or record.stale or record.valid == false
        or (record.kind ~= "bank" and record.kind ~= "vendor")
        or record.offerId == nil or tostring(record.itemID) ~= itemKey(itemID)
        or record.actorKey ~= actorKey or not record.locationKey
        or (record.unit and record.unit ~= "item")
        or (record.extraCurrency and (type(record.extraCurrency) ~= "table"
            or next(record.extraCurrency) ~= nil))
        or (record.availableUnits ~= nil and not integer(record.availableUnits)) then return end
    local size = record.bundleSize or 1
    if not positiveInteger(size) then return end
    local quote
    if record.kind == "bank" then
        if not integer(record.availableUnits) then return end
        quote = replacementQuote
    elseif money(record.bundlePrice) then
        quote = copy(record)
        quote.unitPrice = record.bundlePrice / size
    else
        return
    end
    return {kind = record.kind, offerId = record.offerId, bundleSize = size,
        availableUnits = record.availableUnits, quote = quote, offer = record}
end

local function estimatedVendorOffer(record, itemID)
    if type(record) ~= "table" or record.estimate ~= true or record.source ~= "vendor"
        or record.stale or record.valid == false or record.unit ~= "item"
        or tostring(record.itemID) ~= itemKey(itemID) or not positiveInteger(record.bundleSize)
        or not positiveInteger(record.bundlePrice) or record.unitPrice ~= record.bundlePrice / record.bundleSize
        or type(record.provenance) ~= "string" or record.provenance == ""
        or record.qualified or record.actorKey or record.locationKey or record.offerId or record.availableUnits
        or (record.extraCurrency and (type(record.extraCurrency) ~= "table"
            or next(record.extraCurrency) ~= nil)) then return end
    local terms = {kind = "vendor", source = "vendor", itemID = record.itemID, unit = "item",
        bundleSize = record.bundleSize, bundlePrice = record.bundlePrice, unitPrice = record.unitPrice,
        provenance = record.provenance, profile = record.profile, estimate = true}
    return {kind = "vendor", estimatedVendor = true, bundleSize = terms.bundleSize, offer = terms,
        quote = terms, maxUnitPrice = terms.unitPrice}
end

local function offerKey(itemID, offer)
    return itemKey(itemID) .. "/" .. offer.kind .. "/" .. (offer.estimatedVendor and "estimate" or tostring(offer.offerId))
end

local function maxBundles(state, itemID, offer, demand)
    local bundles = math.ceil(demand / offer.bundleSize)
    if integer(offer.availableUnits) then
        local previous = state.requirements[offerKey(itemID, offer)]
        local left = offer.availableUnits - (previous and previous.quantity or 0)
        bundles = math.min(bundles, math.floor(math.max(0, left) / offer.bundleSize))
    end
    return bundles
end

local function acquireUnits(state, demand, offer, bundles, covered)
    local itemID, consumerId = demand.itemID, demand.parentTaskId
    local quote, node = offer.quote, state.nodes[demand.nodeId]
    local acquired = bundles * offer.bundleSize
    local pricedAuction = offer.kind == "auction" and quote ~= nil
    local fullPrice = quote and offer.kind ~= "bank" and money(quote.bundlePrice) and quote.bundlePrice * bundles
        or quote and quote.unitPrice * acquired
    local cap = offer.marketLimit or pricedAuction and math.min(quote.unitPrice,
        offer.maxUnitPrice or quote.unitPrice) or offer.maxUnitPrice
    local requirementId = offerKey(itemID, offer)
    local requirement = state.requirements[requirementId]
    if not requirement then
        requirement = {requirementId = requirementId, itemID = itemID, quantity = 0,
            actorKey = state.actorKey, kind = offer.kind, offer = copy(offer.offer),
            offerId = offer.offerId, source = quote and quote.source or offer.kind,
            locationKey = offer.offer and offer.offer.locationKey, consumers = {},
            unitPrice = quote and quote.unitPrice, maxUnitPrice = cap,
            availability = offer.estimatedVendor and "unknown" or offer.offer and "actual"
                or quote and quote.availability or "unknown",
            estimate = offer.estimatedVendor or offer.offer == nil and (not quote or quote.estimate ~= false)}
        state.requirements[requirementId] = requirement
    end
    requirement.quantity = requirement.quantity + acquired
    if offer.estimatedVendor or pricedAuction then
        requirement.maxTotalPrice = (requirement.maxTotalPrice or 0) + fullPrice
    end
    if offer.marketLimit then
        requirement.maxUnitPrice = math.max(requirement.maxUnitPrice or 0, offer.marketLimit)
        requirement.unitPrice = requirement.maxTotalPrice / requirement.quantity
        if offer.marketLots then
            local lots = requirement.auctionLots or {}
            requirement.auctionLots = lots
            for _, lot in ipairs(offer.marketLots) do
                local found
                for index, current in ipairs(lots) do
                    if current.quantity == lot.quantity and current.total == lot.total then
                        lots[index] = {quantity = lot.quantity, total = lot.total, count = current.count + lot.count}
                        found = true
                        break
                    end
                end
                if not found then lots[#lots + 1] = lot end
            end
        end
    end
    allocate(state, consumerId, {kind = "acquisition", itemID = itemID, quantity = covered,
        requirementId = requirementId, actorKey = state.actorKey, locationKey = requirement.locationKey})
    if consumerId then
        local sourcing = state.tasks[consumerId].sourcingRequirements
        sourcing[itemKey(itemID)] = (sourcing[itemKey(itemID)] or 0) + covered
        requirement.consumers[consumerId] = (requirement.consumers[consumerId] or 0) + covered
    else
        requirement.goalQuantity = (requirement.goalQuantity or 0) + covered
    end
    node.buy = node.buy + covered
    node.purchased = (node.purchased or 0) + acquired
    node.purchases[#node.purchases + 1] = {kind = offer.kind, requirementId = requirementId,
        required = covered, purchased = acquired, quote = copy(quote), fullPrice = fullPrice}
    if offer.kind == "manual" then node.blocker = offer.overCap and L.overCap or L.manual end
    if not offer.depthFallback or not node.quote then node.quote = copy(quote) end
    addCost(state, offer.kind == "bank" and "owned" or "buy", itemID, acquired, quote, fullPrice,
        offer.depthFallback)
    local surplus = acquired - covered
    if surplus > 0 then
        local key = itemKey(itemID)
        state.surplus[key] = state.surplus[key] or {}
        state.surplus[key][#state.surplus[key] + 1] = {quantity = surplus, requirementId = requirementId,
            marketLot = offer.marketLots ~= nil}
    end
end

local function marketGroupKey(itemID, group)
    return itemKey(itemID) .. "/" .. group.size
end

local function marketPriceIsAverage(purchases)
    local unitPrice
    for _, purchase in ipairs(purchases) do
        local lastUnitPrice = purchase.lastPrice / purchase.group.size
        if purchase.total ~= purchase.lastPrice * purchase.count or unitPrice and unitPrice ~= lastUnitPrice then
            return true
        end
        unitPrice = lastUnitPrice
    end
    return false
end

local function acquireMarketDepth(state, demand, purchases, quantity, cost, limit, covered, depth)
    local lots = not depth.commodity and {} or nil
    for _, purchase in ipairs(purchases) do
        local group = purchase.group
        state.auctionUse[marketGroupKey(demand.itemID, group)] = purchase.used + purchase.count
        if lots then
            local before, ending = purchase.used, purchase.used + purchase.count
            local _, level = depthPrefix(group, before + 1)
            while before < ending do
                local terms = group.levels[level]
                local taken = math.min(ending, terms.count) - before
                lots[#lots + 1] = {quantity = group.size, total = terms.price, count = taken}
                before, level = before + taken, level + 1
            end
        end
    end
    local quote = {itemID = demand.itemID, unit = "item", unitPrice = cost / quantity,
        bundleSize = quantity, bundlePrice = cost, source = "auction", availability = "actual",
        estimate = not depth.complete, isUnitPriceAverage = marketPriceIsAverage(purchases)}
    local offer = directOffer(quote)
    offer.marketLimit, offer.marketLots = limit, lots
    acquireUnits(state, demand, offer, 1, covered)
end

local function addTask(state, recipe, reagentChoice, executions, parentTaskId, parentNodeId)
    state.nextTaskId = state.nextTaskId + 1
    local taskId = "t" .. state.nextTaskId
    local task = {
        taskId = taskId,
        recipeId = recipe.id,
        professionId = recipe.professionId,
        professionName = recipe.professionName,
        outputItemID = recipe.outputItemID,
        executions = executions,
        yield = recipe.yield,
        yieldMax = recipe.yieldMax or recipe.yield,
        outputQuantity = executions * recipe.yield,
        dependencies = {},
        inputs = {},
        allocations = {},
        sourcingRequirements = {},
        actorKey = state.actorKey,
        status = "planned",
        outputKind = recipe.outputKind or "item",
        recipeRevision = recipe.revision,
        reagentChoice = recipe.reagentChoices and copy(reagentChoice) or nil,
    }
    for _, reagent in ipairs(reagentChoice.reagents) do
        local input = copy(reagent)
        input.quantity = reagent.quantity * executions
        task.inputs[#task.inputs + 1] = input
    end
    state.tasks[taskId] = task
    state.taskOrder[#state.taskOrder + 1] = taskId
    putDependency(state, parentTaskId, taskId)
    local node = state.nodes[parentNodeId]
    if node.craftCount == 0 then
        node.recipeId = recipe.id
        node.professionId = recipe.professionId
        node.professionName = recipe.professionName
        node.yield = recipe.yield
    end
    node.craftCount = node.craftCount + executions
    node.crafts[#node.crafts + 1] = {taskId = taskId, recipeId = recipe.id,
        executions = executions, yield = recipe.yield, outputQuantity = task.outputQuantity,
        professionId = recipe.professionId, professionName = recipe.professionName}
    state.crafted[recipe.id] = (state.crafted[recipe.id] or 0) + executions
    local pool = constraintsFor(recipe).cooldownPool
    if pool then
        state.craftedPools[pool] = (state.craftedPools[pool] or 0) + executions
    end
    return taskId
end

function Planner.GetProducingRecipes(catalog, itemID, characterKey, selectedRecipeId, stack, stats)
    local raw = field(catalog.byOutput, itemID) or {}
    local result = {}
    local seen = {}
    for _, entry in ipairs(raw) do
        local recipe = type(entry) == "table" and entry or field(catalog.recipesById, entry)
        if recipe and recipe.id then
            local key = tostring(recipe.id)
            if not seen[key] and (not selectedRecipeId or key == tostring(selectedRecipeId)) then
                seen[key] = true
                if recipeUsable(recipe, characterKey) then
                    if stack and stack[itemKey(itemID)] then
                        if stats then stats.cycle = true end
                    else
                        result[#result + 1] = recipe
                    end
                elseif stats and recipe.learned ~= false and (not recipe.characterKey or recipe.characterKey == characterKey) then
                    stats.incompleteRecipe = true
                end
            end
        end
    end
    table.sort(result, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return result
end

local function sourceName(node)
    local count = 0
    if node.ownedUsed > 0 then count = count + 1 end
    if node.surplusUsed > 0 then count = count + 1 end
    local purchases = #node.purchases
    if purchases == 2 and node.purchases[1].kind == "auction" and node.purchases[2].kind == "manual" then
        purchases = 1
    end
    count = count + purchases + #node.crafts
    if count > 1 then return "Mixed" end
    if node.ownedUsed > 0 then return "Owned" end
    if node.surplusUsed > 0 then return "Surplus" end
    if node.craftCount > 0 then return "Make" end
    if node.buy > 0 then
        local kind = node.purchases[1].kind
        return kind == "vendor" and "Vendor" or kind == "bank" and "Bank" or "Buy"
    end
    return "None"
end

local function capExecutions(state, recipe, count, now, catalog, deferRequirement)
    local constraints = constraintsFor(recipe)
    if recipe.blockedReason or recipe.blocker or constraints.requirementsMet == false and not deferRequirement then
        return 0
    end
    local cooldownUntil = constraints.cooldownUntil
    if type(cooldownUntil) == "number" and (not now or cooldownUntil > now) then return 0 end
    if integer(constraints.maxExecutions) then
        count = math.min(count, constraints.maxExecutions - (state.crafted[recipe.id] or 0))
    end
    local pool = constraints.cooldownPool
    if pool then
        local limit = state.poolCaps[pool]
        if limit == nil then
            limit = math.huge
            for _, member in pairs(catalog.recipesById or {}) do
                local shared = constraintsFor(member)
                if shared.cooldownPool == pool and integer(shared.maxPoolExecutions)
                    and recipeUsable(member, state.actorKey) then
                    limit = math.min(limit, shared.maxPoolExecutions)
                end
            end
            state.poolCaps[pool] = limit
        end
        count = math.min(count, limit - (state.craftedPools[pool] or 0))
    end
    return math.max(0, count)
end

local function missingRequirement(constraints)
    if constraints.requirementsMet == false then
        return FluxCraft.MissingCraftRequirement(constraints.requirements)
    end
end

local function constraintBlocker(recipe, now)
    local constraints = constraintsFor(recipe)
    if recipe.blockedReason or recipe.blocker then return recipe.blockedReason or recipe.blocker end
    local cooldownUntil = constraints.cooldownUntil
    if type(cooldownUntil) == "number" and (not now or cooldownUntil > now)
        or constraints.maxExecutions == 0 then return FluxCraft.L.clients.cooldown end
    return missingRequirement(constraints) or L.constraints
end

local function enqueueCraft(state, recipe, reagentChoice, executions, demand, covered, pending)
    local taskId = addTask(state, recipe, reagentChoice, executions, demand.parentTaskId, demand.nodeId)
    local stack = copy(demand.stack)
    stack[itemKey(recipe.outputItemID)] = true
    for _, input in ipairs(state.tasks[taskId].inputs) do
        pending[#pending + 1] = {kind = "item", itemID = input.itemID, quantity = input.quantity,
            parentTaskId = taskId, parentNodeId = demand.nodeId, stack = stack}
    end
    pending[#pending + 1] = {kind = "complete", taskId = taskId, itemID = recipe.outputItemID,
        surplus = executions * recipe.yield - covered}
    allocate(state, demand.parentTaskId, {kind = "production", itemID = recipe.outputItemID,
        quantity = covered, producerTaskId = taskId, actorKey = state.actorKey})
    if money(recipe.cashCost) and recipe.cashCost > 0 then
        local cost = recipe.cashCost * executions
        state.partialCash = state.partialCash + cost
        state.partialValue = state.partialValue + cost
        local node = state.nodes[demand.nodeId]
        node.recipeCashCost = (node.recipeCashCost or 0) + cost
    end
end

local function newNode(id, itemID, quantity, available)
    return {nodeId = id, itemID = itemID, required = quantity, ownedEligible = available,
        source = "Unknown", ownedUsed = 0, buy = 0, surplusUsed = 0,
        craftCount = 0, children = {}, purchases = {}, crafts = {}}
end

local function initialState(itemID, requested, inventory, actorKey)
    local owned = {}
    for itemID, count in pairs(inventory or {}) do
        if integer(count) then owned[itemKey(itemID)] = count end
    end
    return {
        pending = {}, owned = owned, surplus = {}, tasks = {}, taskOrder = {},
        nodes = {[1] = newNode(1, itemID, requested, field(inventory, itemID) or 0)},
        nextNodeId = 1, nextTaskId = 0, requirements = {}, crafted = {}, craftedPools = {}, poolCaps = {},
        allocations = {}, auctionUse = {}, actorKey = actorKey,
        partialValue = 0, partialCash = 0, partialOwned = 0,
        valueKnown = true, cashKnown = true, ownedKnown = true, unknownPrices = {},
    }
end

local function addNode(state, demand)
    state.nextNodeId = state.nextNodeId + 1
    local nodeId = state.nextNodeId
    state.nodes[nodeId] = newNode(nodeId, demand.itemID, demand.quantity, state.owned[itemKey(demand.itemID)] or 0)
    state.nodes[demand.parentNodeId].children[#state.nodes[demand.parentNodeId].children + 1] = nodeId
    demand.nodeId = nodeId
end

local function taskList(state)
    local result, visited = {}, {}
    local function append(id)
        if visited[id] then return end
        visited[id] = true
        local task = state.tasks[id]
        for _, dependency in ipairs(task.dependencies) do append(dependency) end
        result[#result + 1] = task
    end
    for _, id in ipairs(state.taskOrder) do append(id) end
    return result
end

local function treeFor(state)
    local function nest(id)
        local node = copy(state.nodes[id])
        node.children = {}
        local value = (node.recipeCashCost or 0) + (node.ownedValue or 0)
        local cash = node.recipeCashCost or 0
        local knownValue = node.ownedUsed == 0 or node.ownedValue ~= nil
        local knownCash = true
        for _, purchase in ipairs(node.purchases) do
            if purchase.quote then
                local purchaseCost = purchase.fullPrice
                value = value + purchaseCost
                if purchase.kind ~= "bank" then cash = cash + purchaseCost end
            else
                knownValue = false
                if purchase.kind ~= "bank" then knownCash = false end
            end
        end
        for _, childId in ipairs(state.nodes[id].children) do
            local child = nest(childId)
            node.children[#node.children + 1] = child
            value = value + child.knownValueSubtotal
            cash = cash + child.knownCashSubtotal
            if child.fullValue == nil then knownValue = false end
            if child.additionalCash == nil then knownCash = false end
        end
        node.knownValueSubtotal = value
        node.knownCashSubtotal = cash
        node.fullValue = knownValue and value or nil
        node.additionalCash = knownCash and cash or nil
        node.costStatus = knownValue and "estimated" or "unknown"
        if not knownValue and not node.blocker then
            node.blocker = L.unknownInputs
        end
        return node
    end
    return nest(1)
end

local function requirementsList(state)
    local list = {}
    for _, requirement in pairs(state.requirements) do list[#list + 1] = requirement end
    table.sort(list, function(a, b) return a.requirementId < b.requirementId end)
    return list
end

local function unknownList(state)
    local list = {}
    for itemID in pairs(state.unknownPrices) do list[#list + 1] = itemID end
    table.sort(list)
    return list
end

local function discoveryPrompts(unobserved)
    local prompts = {}
    for _, profession in ipairs(unobserved or {}) do
        if type(profession) == "table" and profession.name then
            prompts[#prompts + 1] = profession.message
                or FluxCraft.L.catalog.discover:format(profession.name)
        elseif type(profession) == "string" then
            prompts[#prompts + 1] = FluxCraft.L.catalog.discover:format(profession)
        end
    end
    return prompts
end

local function routeScore(state, objective)
    local known = objective == "cash" and state.cashKnown or objective ~= "cash" and state.valueKnown
    local value = objective == "cash" and state.partialCash or state.partialValue
    -- Unpriced routes remain candidates; a priced route is preferred while
    -- optimum comparison is explicitly marked incomplete.
    return known, value, #state.taskOrder
end

-- On equal known costs, use the merchant for an otherwise equivalent
-- quantity. Compare allocated units so unused units in a pack do not vote.
local function vendorTie(candidate, best)
    local changes = {}
    local function count(route, direction)
        for _, allocation in ipairs(route.allocations) do
            local requirement = route.requirements[allocation.requirementId]
            local kind = requirement and requirement.kind
            if kind == "auction" or kind == "vendor" then
                local key = itemKey(allocation.itemID)
                local item = changes[key] or {auction = 0, vendor = 0}
                changes[key] = item
                item[kind] = item[kind] + direction * allocation.quantity
            end
        end
    end
    count(candidate, 1)
    count(best, -1)
    local preferred
    for _, item in pairs(changes) do
        if item.vendor + item.auction ~= 0 then return end
        if item.vendor ~= 0 then
            local moreVendor = item.vendor > 0
            if preferred ~= nil and preferred ~= moreVendor then return end
            preferred = moreVendor
        end
    end
    return preferred
end

local function better(candidate, best, objective)
    if not best then return true end
    local ck, cv, ct = routeScore(candidate, objective)
    local bk, bv, bt = routeScore(best, objective)
    if ck ~= bk then return ck end
    if ck and cv ~= bv then return cv < bv end
    local costsKnown
    if ck then
        local secondary = objective == "cash" and "value" or "cash"
        local alternateKnown, alternateValue = routeScore(candidate, secondary)
        local bestAlternateKnown, bestAlternateValue = routeScore(best, secondary)
        if alternateKnown ~= bestAlternateKnown then return alternateKnown end
        if alternateKnown and alternateValue ~= bestAlternateValue then return alternateValue < bestAlternateValue end
        costsKnown = alternateKnown
    else
        local function externalUnits(route)
            local total = 0
            for _, requirement in pairs(route.requirements) do total = total + requirement.quantity end
            return total
        end
        local candidateExternal, bestExternal = externalUnits(candidate), externalUnits(best)
        if candidateExternal ~= bestExternal then return candidateExternal < bestExternal end
    end
    if ct ~= bt then return ct < bt end
    if costsKnown then
        local merchantPreferred = vendorTie(candidate, best)
        if merchantPreferred ~= nil then return merchantPreferred end
    end
    return #requirementsList(candidate) < #requirementsList(best)
end

local function orderedKeys(map)
    local keys = {}
    for key in pairs(map or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) < type(b) end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function stableValue(value, depth)
    if type(value) ~= "table" then return type(value) .. ":" .. string.format("%q", tostring(value)) end
    if depth >= 8 then return "[nested]" end
    local parts = {}
    for _, key in ipairs(orderedKeys(value)) do
        -- Re-reading the same offer during acceptance advances its query
        -- time. Supplier revision, price, source and availability still
        -- participate in validation.
        if key ~= "observedAt" and key ~= "queriedAt" and key ~= "queryTime"
            and (key ~= "at" or type(value.commodity) ~= "boolean" or type(value.offers) ~= "table") then
            parts[#parts + 1] = stableValue(key, depth + 1) .. "=" .. stableValue(value[key], depth + 1)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function revisionOf(request)
    local revisions = request.revisions or {}
    local observedDepth = {}
    for itemID, book in pairs(request.auctionDepth or {}) do
        if type(book) == "table" then
            observedDepth[itemID] = {itemID = book.itemID, commodity = book.commodity,
                complete = book.complete, offers = book.offers, stale = book.stale, valid = book.valid}
        end
    end
    return stableValue({recipeId = request.rootRecipeId, itemID = request.rootItemID, quantity = request.quantity,
        actor = request.characterKey, intent = request.intent, objective = request.objective,
        catalog = revisions.catalog or (request.catalog and request.catalog.revision),
        inventoryRevision = revisions.inventory, priceRevision = revisions.prices,
        policyRevision = revisions.policy, inventory = request.inventory,
        quotes = request.quotes, acquisitions = request.acquisitions, vendorEstimates = request.vendorEstimates,
        auctionDepth = observedDepth, auctionDepthIncomplete = request.auctionDepthIncomplete,
        auctionAllowOverbuy = request.auctionAllowOverbuy,
        choices = request.choices,
        rootReagentChoice = request.rootReagentChoice,
        unitCaps = request.unitCaps,
        coverage = request.committedCoverage, destination = request.destination,
        bagsOnly = request.bagsOnly}, 0)
end

local function bounded(value, default, ceiling)
    if not positiveInteger(value) then return default end
    return math.min(value, ceiling)
end

local function countsFor(maximum, cap, stats, candidates)
    if maximum == 0 then return {} end
    if maximum > cap then
        stats.bounded = true
        local counts, seen = {maximum}, {[maximum] = true}
        for _, candidate in ipairs(candidates or {}) do
            for count = math.floor(candidate), math.ceil(candidate) do
                if count >= 1 and count <= maximum and not seen[count] then
                    counts[#counts + 1], seen[count] = count, true
                    if #counts >= math.max(1, cap - 2) then break end
                end
            end
            if #counts >= math.max(1, cap - 2) then break end
        end
        for _, count in ipairs({math.floor(maximum / 2), 1}) do
            if not seen[count] then counts[#counts + 1], seen[count] = count, true end
        end
        return counts
    end
    local counts = {}
    for count = maximum, 1, -1 do counts[#counts + 1] = count end
    return counts
end

-- For any one stack size its cheapest remaining listings dominate costlier
-- ones. Different sizes are distinct choices because every native bid buys a
-- whole listing. Searching those counts also permits later demands to use
-- leftover units from a selected lot without buying that lot twice.
local function searchMarketDepth(depth, quantity, used, allowOverbuy, cap, stats, hasBudget, visit)
    local purchases = {}
    local groups = depth.groups
    local last = math.min(#groups, 32)
    if last < #groups then stats.bounded = true end
    local function choose(index, remaining, bought, cost, limit)
        if not hasBudget() then return end
        if remaining <= 0 then
            visit(purchases, bought, cost, limit)
            return
        end
        local group = groups[index]
        if index > last then return end
        local before = used(group)
        local packs = remaining / group.size
        local maximum = math.min(group.count - before, allowOverbuy and math.ceil(packs) or math.floor(packs))
        local function take(count)
            local sale = marketLotPurchase(group, before, count)
            purchases[#purchases + 1] = sale
            choose(index + 1, remaining - sale.quantity, bought + sale.quantity,
                cost + sale.total, math.max(limit, sale.limit))
            purchases[#purchases] = nil
        end
        if index == last then
            if maximum > 0 and maximum * group.size >= remaining then take(maximum) end
            return
        end
        local candidates = {}
        if maximum > cap then
            for _, level in ipairs(group.levels) do candidates[#candidates + 1] = level.count - before end
            local nextGroup = groups[index + 1]
            candidates[#candidates + 1] = (remaining - (nextGroup.count - used(nextGroup)) * nextGroup.size)
                / group.size
        end
        for _, count in ipairs(countsFor(maximum, cap, stats, candidates)) do take(count) end
        choose(index + 1, remaining, bought, cost, limit)
    end
    choose(1, quantity, 0, 0, 0)
end

function Planner.DirectCost(quotes, itemID, quantity, auctionDepth, options)
    if not integer(quantity) then return nil end
    options = options or {}
    local depth = auctionDepthFor(quotes, auctionDepth, itemID, options.maxUnitPrice)
    if depth then
        local stats = {bounded = false}
        local cost, purchased, cap, average, visited = nil, nil, nil, nil, 0
        searchMarketDepth(depth, quantity, function() return 0 end, options.allowOverbuy == true, 96, stats,
            function()
                if visited >= 3200 then stats.bounded = true; return false end
                visited = visited + 1
                return true
            end,
            function(purchases, units, total, limit)
                if not cost or total < cost or total == cost and units < purchased then
                    cost, purchased, cap = total, units, limit
                    average = marketPriceIsAverage(purchases)
                end
            end)
        return cost, purchased, {observed = true, complete = depth.complete and not stats.bounded,
            available = depth.available, maxUnitPrice = cap, bounded = stats.bounded, average = average}
    end
    local quote = quoteFor(quotes, itemID)
    if not quote then return nil end
    if money(options.maxUnitPrice) and options.maxUnitPrice > 0 and quote.unitPrice > options.maxUnitPrice then
        return nil
    end
    local direct = directOffer(quote)
    local purchased = math.ceil(quantity / direct.bundleSize) * direct.bundleSize
    if integer(direct.availableUnits) and purchased > direct.availableUnits then return nil end
    local metadata = {observed = false, complete = false, maxUnitPrice = quote.unitPrice}
    if money(quote.bundlePrice) then return purchased / direct.bundleSize * quote.bundlePrice, purchased, metadata end
    return purchased * quote.unitPrice, purchased, metadata
end

function Planner.Preview(request, previous, pause)
    request = request or {}
    local catalog = request.catalog or {}
    local inventory = request.inventory or {}
    local quotes = request.quotes or {}
    local recipe = field(catalog.recipesById, request.rootRecipeId)
    local produces = request.rootRecipeId ~= nil
    local characterKey = request.characterKey
    local revision
    local function blocked(reason, diagnostics)
        return {status = "blocked", blocker = reason, revision = revision or revisionOf(request),
            diagnostics = diagnostics}
    end
    if produces and not recipeUsable(recipe, characterKey) then
        return blocked(recipe and (recipe.blockedReason or recipe.blocker) or L.unqualified)
    end
    local outputItemID = recipe and recipe.outputItemID or request.rootItemID
    if not (positiveInteger(outputItemID) or type(outputItemID) == "string" and outputItemID ~= "") then
        return blocked(L.pickItem)
    end
    if recipe and request.rootItemID and itemKey(request.rootItemID) ~= itemKey(recipe.outputItemID) then
        return blocked(L.wrongOutput)
    end
    if not positiveInteger(request.quantity) then
        return blocked(L.positiveQty)
    end
    revision = revisionOf(request)
    if previous and previous.revision == revision then return previous end
    local intent = request.intent or (produces and "additional" or "supply")
    local desired = request.quantity
    local destination = request.destination
    local inBags, committed = field(inventory, outputItemID) or 0,
        field(request.committedCoverage, outputItemID) or 0
    if intent == "stockUpTo" then
        inBags = integer(inBags) and inBags or 0
        committed = integer(committed) and committed or 0
        desired = math.max(0, desired - inBags - committed)
    elseif intent == "delivery" then
        if type(destination) ~= "table" or not destination.actorKey or not destination.locationKey then
            return blocked(L.destination)
        end
    elseif intent ~= "additional" and (intent ~= "supply" or produces) then
        return blocked(L.unknownIntent)
    end
    local goal = {type = intent, intent = intent, quantity = request.quantity, required = desired,
        recipeId = recipe and recipe.id, itemID = outputItemID, actorKey = characterKey,
        destination = copy(destination), priority = request.priority}
    if desired == 0 then
        local onHand = math.min(inBags, request.quantity)
        local tree = {itemID = outputItemID, required = request.quantity, source = "Covered",
            ownedUsed = onHand, committed = request.quantity - onHand}
        return {status = "ready", revision = revision, goal = goal, tree = tree, tasks = {},
            requirements = {}, allocations = {}, rootRecipeId = recipe and recipe.id, rootItemID = outputItemID,
            summary = {requested = 0, executions = 0, output = 0, surplus = 0,
                fullValue = 0, additionalCash = 0, ownedValue = 0, valueKnown = true,
                cashKnown = true, optimality = "exact"}}
    end
    local executions = recipe and math.ceil(desired / recipe.yield)
    local limits = request.limits or {}
    local maxStates = bounded(limits.states or request.maxStates, 3200, 20000)
    local maxCraftChoices = bounded(limits.craftChoices or request.maxCraftChoices, 32, 128)
    local maxDepth = bounded(limits.depth or request.maxDepth, 20, 32)
    local objective = request.objective == "cash" and "cash" or "value"
    local stats = {visited = 0, bounded = false, cycle = false, unknownAlternative = false,
        invalidRecipe = false, incompleteRecipe = false,
        auctionDepthIncomplete = request.auctionDepthIncomplete == true and not request.bagsOnly,
        sharedCooldownUnverified = recipe and constraintsFor(recipe).sharedCooldownUnverified or false,
        catalogIncomplete = catalog.unobservedProfessions and next(catalog.unobservedProfessions) ~= nil or false}
    local best
    local origin = initialState(outputItemID, desired, inventory, characterKey)
    local vendorTerms = {}
    local marketDepth = {}
    -- A player can commit to the selected craft before its tool or station is available.
    local deferRequirements = request.deferRecipeRequirements and not request.bagsOnly
    local craftRequirement = recipe and deferRequirements and missingRequirement(constraintsFor(recipe)) or nil
    local rootBlocker
    if recipe and capExecutions(origin, recipe, executions, request.now, catalog, craftRequirement ~= nil) < executions then
        rootBlocker = constraintBlocker(recipe, request.now)
        if not request.inspectUnavailable or request.bagsOnly then return blocked(rootBlocker) end
    end

    local search
    local function hasBudget()
        if stats.visited >= maxStates then
            stats.bounded = true
            return false
        end
        stats.visited = stats.visited + 1
        if pause and stats.visited % 96 == 0 then pause() end
        return true
    end

    local function finishDemand(state, demand, pending)
        local node = state.nodes[demand.nodeId]
        node.source = sourceName(node)
        if #pending > 0 then
            for _, continuation in ipairs(state.pending) do pending[#pending + 1] = continuation end
            state.pending = pending
        end
        search(state)
    end

    local function unitCap(itemID)
        local cap = field(request.unitCaps, itemID)
        return money(cap) and cap > 0 and cap or nil
    end

    local function getDepth(itemID)
        if request.bagsOnly then return end
        local key = itemKey(itemID)
        if marketDepth[key] == nil then
            marketDepth[key] = auctionDepthFor(quotes, request.auctionDepth, itemID, unitCap(itemID)) or false
        end
        return marketDepth[key] or nil
    end

    local function availableOptions(demand, forced, choice, auctionQuote, replacement, estimatedVendor)
        local options, direct, seen = {}, nil, {}
        local cap = unitCap(demand.itemID)
        if not request.bagsOnly and (forced == "auto" or forced == "buy") then
            local depth = getDepth(demand.itemID)
            if depth then
                direct = {kind = "auction", depth = depth}
                if not depth.complete then stats.auctionDepthIncomplete = true end
            elseif cap and auctionQuote and auctionQuote.unitPrice > cap then
                direct = directOffer(nil)
                direct.overCap = true
            else
                direct = directOffer(auctionQuote)
            end
            direct.maxUnitPrice = cap
        end
        local liveVendor = false
        if not request.bagsOnly and (forced == "auto" or forced == "bank" or forced == "vendor") then
            for _, record in ipairs(field(request.acquisitions, demand.itemID) or {}) do
                local offer = qualifiedOffer(record, demand.itemID, characterKey, replacement)
                if offer and offer.kind == "vendor" then liveVendor = true end
                if offer and (forced == "auto" or forced == offer.kind)
                    and (offer.kind == "bank" or not cap or offer.quote.unitPrice <= cap) then
                    offer.maxUnitPrice = cap
                    local key = offerKey(demand.itemID, offer)
                    if not seen[key] then
                        seen[key] = true
                        options[#options + 1] = {offer = offer}
                    end
                end
            end
        end
        -- Known catalog or remembered terms can guide planning without claiming
        -- access. Live merchant evidence replaces this fallback for the SKU.
        if not request.bagsOnly and not liveVendor and estimatedVendor
            and (forced == "auto" or forced == "vendor")
            and (not cap or estimatedVendor.quote.unitPrice <= cap) then
            stats.estimatedVendor = true
            options[#options + 1] = {offer = estimatedVendor}
        end
        if forced == "auto" or forced == "make" then
            local recipes = demand.isRoot and recipe and {recipe}
                or Planner.GetProducingRecipes(catalog, demand.itemID, characterKey, choice.recipeId, demand.stack, stats)
            local ancestryDepth = 0
            for _ in pairs(demand.stack) do ancestryDepth = ancestryDepth + 1 end
            if #recipes > 0 and ancestryDepth >= maxDepth then
                stats.bounded = true
            else
                for _, producer in ipairs(recipes) do
                    local constraints = constraintsFor(producer)
                    if constraints.sharedCooldownUnverified then
                        stats.sharedCooldownUnverified = true
                    end
                    local deferRequirement = deferRequirements and demand.isRoot and forced == "make"
                        and missingRequirement(constraints) ~= nil
                    for _, reagents in ipairs(reagentChoices(producer)) do
                        options[#options + 1] = {recipe = producer, reagentChoice = reagents,
                            deferRequirement = deferRequirement}
                    end
                end
            end
        end
        if #options > 24 then
            stats.bounded = true
            for index = #options, 25, -1 do options[index] = nil end
        end
        return options, direct
    end

    local function marketBreakpoints(state, demand, direct, remaining, producer, reagents)
        local result = {}
        if direct and direct.depth then
            for _, group in ipairs(direct.depth.groups) do
                local used = state.auctionUse[marketGroupKey(demand.itemID, group)] or 0
                for index = #group.levels, 1, -1 do
                    local coverage = (group.levels[index].count - used) * group.size
                    if coverage > 0 then result[#result + 1] = (remaining - coverage) / producer.yield end
                end
            end
        end
        for _, reagent in ipairs(reagents.reagents or {}) do
            local depth = getDepth(reagent.itemID)
            local group = depth and depth.groups[1]
            if group and #depth.groups == 1 and group.size == 1 then
                local used = state.auctionUse[marketGroupKey(reagent.itemID, group)] or 0
                local owned = state.owned[itemKey(reagent.itemID)] or 0
                for index = #group.levels, 1, -1 do
                    local coverage = owned + math.max(0, group.levels[index].count - used)
                    result[#result + 1] = coverage / reagent.quantity
                end
            end
        end
        return result
    end

    local function buyAtDepth(state, demand, remaining, depth, pending)
        local available, fullBasket = 0, false
        local function unitsUsed(group)
            return state.auctionUse[marketGroupKey(demand.itemID, group)] or 0
        end
        for _, group in ipairs(depth.groups) do
            available = available + (group.count - unitsUsed(group)) * group.size
        end
        if available < remaining then
            -- There is no complete buy alternative. Keep the observed front
            -- of the book actionable and leave the uncovered balance unpriced.
            local purchases, knownCost, highest = {}, 0, 0
            for _, group in ipairs(depth.groups) do
                local used = unitsUsed(group)
                if group.count > used then
                    local purchase = marketLotPurchase(group, used, group.count - used)
                    purchases[#purchases + 1] = purchase
                    knownCost = knownCost + purchase.total
                    highest = math.max(highest, purchase.limit)
                end
            end
            if available > 0 then
                acquireMarketDepth(state, demand, purchases, available, knownCost, highest, available, depth)
                remaining = remaining - available
            end
        else
            local allowOverbuy = request.auctionAllowOverbuy == true
                or #pending > 0 or #state.pending > 0
            searchMarketDepth(depth, remaining, unitsUsed, allowOverbuy, maxCraftChoices, stats, hasBudget,
                function(basket, quantity, total, limit)
                    if quantity == remaining then fullBasket = true end
                    local branch = fork(state)
                    acquireMarketDepth(branch, demand, basket, quantity, total, limit, remaining, depth)
                    finishDemand(branch, demand, shallow(pending))
                end)
        end
        if not fullBasket then
            -- Keep unavailable amounts on the shopping list without pricing
            -- unobserved units or authorizing them against cached prices.
            local fallback = directOffer(nil)
            fallback.depthFallback = true
            acquireUnits(state, demand, fallback, remaining, remaining)
            finishDemand(state, demand, pending)
        end
    end

    local function selectSources(state, demand, remaining, options, direct, index, pending)
        if not hasBudget() then return end
        if remaining == 0 then
            finishDemand(state, demand, pending)
            return
        end
        local option = options[index]
        if not option then
            if direct and direct.depth then
                buyAtDepth(state, demand, remaining, direct.depth, pending)
            elseif direct then
                local bundles = math.ceil(remaining / direct.bundleSize)
                if bundles <= maxBundles(state, demand.itemID, direct, remaining) then
                    acquireUnits(state, demand, direct, bundles, remaining)
                    finishDemand(state, demand, pending)
                end
            end
            return
        end
        local producer = option.recipe
        local offer = option.offer
        -- Get a fully priced candidate before spending the search budget on
        -- combinations of manual acquisitions with no observed price.
        local deferManual = direct and direct.kind == "manual" and offer and offer.quote
        if not deferManual then
            if direct or options[index + 1] then
                selectSources(fork(state), demand, remaining, options, direct, index + 1, shallow(pending))
            elseif not hasBudget() then
                return
            end
        end
        local requested = producer and math.ceil(remaining / producer.yield)
        local maximum = requested and (demand.isRoot and rootBlocker and requested
            or capExecutions(state, producer, requested, request.now, catalog, option.deferRequirement))
            or maxBundles(state, demand.itemID, offer, remaining)
        local candidates = producer and maximum > maxCraftChoices
            and marketBreakpoints(state, demand, direct, remaining, producer, option.reagentChoice)
        local counts = countsFor(maximum, maxCraftChoices, stats, candidates)
        for position, count in ipairs(counts) do
            if stats.visited >= maxStates then stats.bounded = true; return end
            local branch, work = state, pending
            -- The last branch can take ownership of the ledgers unless the
            -- unpriced route still needs the original state afterwards.
            if deferManual or position < #counts then branch, work = fork(state), shallow(pending) end
            local covered = math.min(remaining, count * (producer and producer.yield or offer.bundleSize))
            if producer then
                enqueueCraft(branch, producer, option.reagentChoice, count, demand, covered, work)
            else
                acquireUnits(branch, demand, offer, count, covered)
            end
            selectSources(branch, demand, remaining - covered, options, direct, index + 1, work)
        end
        if deferManual then
            selectSources(state, demand, remaining, options, direct, index + 1, pending)
        end
    end

    search = function(state)
        if not hasBudget() then return end
        if best then
            local currentKnown, currentValue = routeScore(state, objective)
            local bestKnown, bestValue = routeScore(best, objective)
            if bestKnown and currentKnown and currentValue > bestValue then return end
        end
        local demand = table.remove(state.pending, 1)
        if not demand then
            if request.auctionAllowOverbuy ~= true then
                for _, available in pairs(state.surplus) do
                    for _, entry in ipairs(available) do
                        if entry.marketLot then return end
                    end
                end
            end
            if state.independentUnpriced then stats.unknownAlternative = true end
            if better(state, best, objective) then best = state end
            return
        end
        if demand.kind == "complete" then
            if demand.surplus > 0 then
                local key = itemKey(demand.itemID)
                state.surplus[key] = state.surplus[key] or {}
                state.surplus[key][#state.surplus[key] + 1] = {quantity = demand.surplus, taskId = demand.taskId}
            end
            search(state)
            return
        end
        demand = shallow(demand)
        if not demand.isRoot then addNode(state, demand) end
        local node = state.nodes[demand.nodeId]
        local key = itemKey(demand.itemID)
        local forced, choice = Planner.GetSourceChoice(request.choices, demand.itemID)
        if demand.isRoot and recipe then forced = "make" end
        node.surplusUsed = consumeSurplus(state, demand.itemID, demand.quantity, demand.parentTaskId)
        local afterSurplus = demand.quantity - node.surplusUsed
        local useOwned = not choice.ignoreOwned and choice.useOwned ~= false
            and (forced ~= "make" or choice.useOwned == true)
            and (not demand.isRoot or intent == "delivery" and not recipe)
        node.ownedUsed = useOwned and math.min(afterSurplus, state.owned[key] or 0) or 0
        if vendorTerms[key] == nil then
            local estimate = estimatedVendorOffer(field(request.vendorEstimates, demand.itemID), demand.itemID)
            local hasLive, liveValue
            for _, record in ipairs(field(request.acquisitions, demand.itemID) or {}) do
                if type(record) == "table" and record.kind == "vendor" then
                    local live = qualifiedOffer(record, demand.itemID, characterKey)
                    if live then
                        hasLive = true
                        if (not live.availableUnits or live.availableUnits >= live.bundleSize)
                            and (not liveValue or live.quote.unitPrice < liveValue.unitPrice) then
                            liveValue = live.quote
                        end
                    end
                end
            end
            vendorTerms[key] = {estimate = estimate, replacement = liveValue or not hasLive and estimate and estimate.quote}
        end
        local auctionQuote = quoteFor(quotes, demand.itemID)
        local vendor = vendorTerms[key]
        local quote = vendor.replacement
        if auctionQuote and (not quote or auctionQuote.unitPrice <= quote.unitPrice) then quote = auctionQuote end
        if node.ownedUsed > 0 then
            state.owned[key] = state.owned[key] - node.ownedUsed
            node.ownedValue = quote and quote.unitPrice * node.ownedUsed or nil
            addCost(state, "owned", demand.itemID, node.ownedUsed, quote)
            allocate(state, demand.parentTaskId, {kind = "owned", itemID = demand.itemID,
                quantity = node.ownedUsed, actorKey = characterKey, locationKey = "bags"})
        end
        local remaining = afterSurplus - node.ownedUsed
        if remaining == 0 then
            finishDemand(state, demand, {})
            return
        end
        local options, direct = availableOptions(demand, forced, choice, auctionQuote, quote, vendor.estimate)
        if #options == 0 and forced == "make" then stats.invalidRecipe = true end
        selectSources(state, demand, remaining, options, direct, 1, {})
    end

    local rootReagents = recipe and reagentChoices(recipe)
    if recipe and request.rootReagentChoice then
        local selected = stableValue(request.rootReagentChoice.reagents, 0)
        local exact
        for _, choice in ipairs(rootReagents) do
            if stableValue(choice.reagents, 0) == selected then exact = choice; break end
        end
        if not exact then return blocked(FluxCraft.L.clients.staleReagents) end
        rootReagents = {exact}
    end
    if rootReagents and #rootReagents == 1 then
        enqueueCraft(origin, recipe, rootReagents[1], executions,
            {nodeId = 1, stack = {}}, desired, origin.pending)
        origin.nodes[1].source = "Make"
        search(origin)
    else
        origin.pending[1] = {kind = "item", itemID = outputItemID, quantity = desired,
            nodeId = 1, stack = {}, isRoot = true}
        search(origin)
    end
    if not best then
        return blocked(rootBlocker or stats.invalidRecipe and L.forcedMake or request.bagsOnly and L.bags or L.noRoute,
            stats)
    end
    local missing = unknownList(best)
    local comparisonIncomplete = stats.unknownAlternative or stats.bounded or stats.cycle
        or stats.incompleteRecipe or stats.sharedCooldownUnverified
        or stats.catalogIncomplete or stats.estimatedVendor or stats.auctionDepthIncomplete
        or not best.valueKnown or not best.cashKnown
    local root = best.nodes[1]
    local output = root.ownedUsed + (root.purchased or 0)
    for _, craft in ipairs(root.crafts) do output = output + craft.outputQuantity end
    local summary = {
        requested = desired, executions = root.craftCount, output = output,
        surplus = output - desired,
        fullValue = best.valueKnown and best.partialValue or nil,
        additionalCash = best.cashKnown and best.partialCash or nil,
        ownedValue = best.ownedKnown and best.partialOwned or nil,
        knownValueSubtotal = best.partialValue, knownCashSubtotal = best.partialCash,
        valueKnown = best.valueKnown, cashKnown = best.cashKnown,
        missingPriceItemIDs = missing,
        optimality = comparisonIncomplete and "incomplete" or "exact",
        searchBounded = stats.bounded,
        objectiveKey = objective, objective = objective == "cash" and L.minCash or L.minValue,
        valuationBasis = L.valuation,
    }
    local requirements = requirementsList(best)
    summary.ownedUnits, summary.ownedAuctionValue = 0, 0
    local function recordOwned(itemID, quantity)
        summary.ownedUnits = summary.ownedUnits + quantity
        if summary.ownedAuctionValue == nil then return end
        local quote = quoteFor(quotes, itemID)
        summary.ownedAuctionValue = quote and summary.ownedAuctionValue + quote.unitPrice * quantity or nil
    end
    for _, allocation in ipairs(best.allocations) do
        if allocation.kind == "owned" then recordOwned(allocation.itemID, allocation.quantity) end
    end
    for _, requirement in ipairs(requirements) do
        if requirement.kind == "bank" then recordOwned(requirement.itemID, requirement.quantity) end
    end
    local tree = treeFor(best)
    if rootBlocker then
        tree.blocker = rootBlocker
        return {
            status = "blocked", blocker = rootBlocker, inspectionOnly = true,
            revision = revision, rootRecipeId = recipe.id, rootItemID = outputItemID, goal = goal,
            tree = tree, tasks = {}, requirements = {}, allocations = {}, summary = summary,
            discoveryPrompts = discoveryPrompts(catalog.unobservedProfessions), diagnostics = stats,
        }
    end
    if not recipe and deferRequirements then
        for _, craft in ipairs(root.crafts) do
            local producer = field(catalog.recipesById, craft.recipeId)
            craftRequirement = producer and missingRequirement(constraintsFor(producer))
            if craftRequirement then break end
        end
    end
    return {status = #requirements > 0 and "sourcing" or "ready",
        revision = revision, rootRecipeId = recipe and recipe.id, rootItemID = outputItemID, goal = goal,
        tree = tree, tasks = taskList(best), requirements = requirements, allocations = best.allocations,
        summary = summary, craftRequirement = craftRequirement,
        discoveryPrompts = discoveryPrompts(catalog.unobservedProfessions),
        diagnostics = stats}
end

-- Compare manufacturing using the same final-item sourcing path, keeping
-- the output's Make override distinct from its ingredient preferences.
function Planner.PreviewManufacture(request, itemID, quantity)
    local input = {}
    for key, value in pairs(request) do input[key] = value end
    input.choices = copy(request.choices or {})
    input.choices[itemID] = {source = "Make"}
    input.rootRecipeId, input.rootItemID, input.quantity, input.intent = nil, itemID, quantity, "supply"
    return Planner.Preview(input)
end

function Planner.DirectReagentItems(recipe)
    local ids, seen = {}, {}
    for _, choice in ipairs(reagentChoices(recipe)) do
        for _, reagent in ipairs(choice.reagents or {}) do
            if not seen[reagent.itemID] then
                ids[#ids + 1], seen[reagent.itemID] = reagent.itemID, true
            end
        end
    end
    return ids
end

-- Direct actions prepare a single native batch from unreserved carried stock.
-- Select one exact reagent combination, then build the usual task and allocations.
function Planner.PreviewDirect(request, maximum, requestedChoice)
    local catalog, inventory = request.catalog, request.inventory
    local recipe = field(catalog.recipesById, request.rootRecipeId)
    if not recipeUsable(recipe, request.characterKey) then return nil, L.unqualified end
    if (recipe.cashCost or 0) > 0 then return nil, L.bags end
    local state = initialState(recipe.outputItemID, recipe.yield, inventory, request.characterKey)
    local limit = capExecutions(state, recipe, bounded(maximum, 1, 999), request.now, catalog)
    if limit < 1 then return nil, constraintBlocker(recipe, request.now) end

    local required = requestedChoice and stableValue(requestedChoice.reagents, 0)
    local selection, largest = nil, 0
    for _, choice in ipairs(reagentChoices(recipe)) do
        if not required or required == stableValue(choice.reagents, 0) then
            local totals, batches = {}, #choice.reagents == 0 and 1 or limit
            for _, reagent in ipairs(choice.reagents) do
                local key = itemKey(reagent.itemID)
                totals[key] = (totals[key] or 0) + reagent.quantity
            end
            for key, quantity in pairs(totals) do
                batches = math.min(batches, math.floor((state.owned[key] or 0) / quantity))
            end
            if batches > largest then selection, largest = choice, batches end
            if largest == limit then break end
        end
    end
    if not selection then return nil, FluxCraft.L.execMissingMaterials end

    local exact = shallow(recipe)
    exact.reagents = selection.reagents
    if recipe.reagentChoices then exact.reagentChoices = {selection} end
    local plan = Planner.Preview({catalog = {recipesById = {[recipe.id] = exact}, revision = catalog.revision},
        rootRecipeId = recipe.id, inventory = inventory, quantity = largest * recipe.yield,
        characterKey = request.characterKey, now = request.now, revisions = request.revisions,
        quotes = request.quotes, vendorEstimates = request.vendorEstimates, objective = request.objective,
        bagsOnly = true})
    if plan.status ~= "ready" or #plan.tasks ~= 1 or #plan.requirements > 0 then
        return nil, plan.blocker or FluxCraft.L.execMissingMaterials
    end
    plan.goal.directCraft = true
    return plan
end

return Planner
