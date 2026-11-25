local _, FC = ...

local Comparison = {}
FC.Comparison = Comparison

local function compare(craft, buy)
    if type(craft) ~= "number" or type(buy) ~= "number" then return "unknown" end
    if craft < buy then return "make" end
    if buy < craft then return "buy" end
    return "equal"
end

-- Independent counterfactual for this node's full quantity. It uses the
-- original observation snapshot and stock policy of the preview. The rows
-- are comparisons; only the selected plan allocates stock across branches.
function Comparison.BuildForNode(plan, node, observations, characterKey, choices)
    if not (plan and plan.summary and node and observations and observations.catalog) then return end
    local buy, _, auction = FC.Planner.DirectCost(observations.quotes, node.itemID, node.required,
        observations.auctionDepth)
    local make, recipeId, complete
    if node == plan.tree and plan.rootRecipeId then
        make = plan.summary.fullValue
        recipeId = plan.rootRecipeId
        complete = plan.summary.optimality == "exact"
    else
        local alternative = FC.Planner.PreviewManufacture({
            catalog = observations.catalog,
            inventory = observations.inventory,
            quotes = observations.quotes,
            auctionDepth = observations.auctionDepth,
            auctionDepthIncomplete = observations.auctionDepthIncomplete,
            acquisitions = observations.acquisitions,
            vendorEstimates = observations.vendorEstimates,
            characterKey = characterKey,
            choices = choices,
            objective = "value",
            now = observations.now,
            limits = observations.limits or {states = 1000},
        }, node.itemID, node.required)
        make = alternative.summary and alternative.summary.fullValue
        local output = alternative.tree
        recipeId = output and output.recipeId
        complete = alternative.summary and alternative.summary.optimality == "exact"
    end
    local selectedSavings = buy and node.fullValue and buy - node.fullValue or nil
    return {itemID = node.itemID, quantity = node.required, selectedSource = node.source,
        buy = buy, make = make, recipeId = recipeId, cheaper = compare(make, buy),
        makeSavings = buy and make and buy - make or nil,
        makeSavingsPercent = buy and buy > 0 and make and 100 * (buy - make) / buy or nil,
        selectedSavings = selectedSavings,
        selectedSavingsPercent = selectedSavings and buy > 0 and 100 * selectedSavings / buy or nil,
        comparisonIncomplete = observations.comparisonLimited or observations.auctionDepthIncomplete
            or auction and auction.observed and not auction.complete or not complete or buy == nil or make == nil,
        basis = FC.L.planner.comparison}
end

function Comparison.Build(plan, catalog, inventory, quotes, characterKey, acquisitions, vendorEstimates)
    local result = {revision = plan and plan.revision, intermediates = {},
        hasCheaperCraftedReagent = false}
    if not (plan and plan.tree and plan.summary and catalog and inventory and quotes) then return result end
    local observations = {catalog = catalog, inventory = inventory, quotes = quotes,
        acquisitions = acquisitions, vendorEstimates = vendorEstimates}
    result.root = Comparison.BuildForNode(plan, plan.tree, observations, characterKey)
    result.root.craft = result.root.make
    result.root.objective = plan.summary.objective
    result.root.objectiveKey = plan.summary.objectiveKey

    local inspected = {}
    for _, node in ipairs(plan.tree.children) do
        local producers = catalog.byOutput and catalog.byOutput[node.itemID]
        if producers and #producers > 0 and not inspected[node.itemID] then
            inspected[node.itemID] = true
            local entry = Comparison.BuildForNode(plan, node, observations, characterKey)
            result.intermediates[#result.intermediates + 1] = entry
            if entry.cheaper == "make" and not entry.comparisonIncomplete then
                result.hasCheaperCraftedReagent = true
            end
            if #result.intermediates >= 8 then break end
        end
    end
    return result
end

return Comparison
