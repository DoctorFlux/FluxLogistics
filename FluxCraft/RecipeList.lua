local _, FC = ...
local L = FC.L
local RecipeList = {}
FC.RecipeList = RecipeList

local function matches(recipe, filter, search, group, meta, name)
    if filter == "favorites" and not meta.favorite then return false end
    if group and group ~= meta.group then return false end
    if search == "" then return true end
    local text = table.concat({name(recipe), meta.note or "", meta.group or ""}, " ")
    return text:lower():find(search, 1, true) ~= nil
end

local difficulty = {optimal = 1, orange = 1, medium = 2, yellow = 2, easy = 3, green = 3,
    trivial = 4, gray = 4, grey = 4}

local function rankDifficulty(recipe)
    local value = recipe.difficulty
    return type(value) == "number" and value or difficulty[value] or 99
end

function RecipeList.SkillUpRank(recipe)
    if not recipe or recipe.canSkillUp ~= true then return end
    local value = recipe.difficulty
    local native = Enum and Enum.TradeskillRelativeDifficulty
    if native and type(value) == "number" then
        if value == native.Optimal then return 1 end
        if value == native.Medium then return 2 end
        if value == native.Easy then return 3 end
    end
    local rank = difficulty[value]
    if rank and rank <= 3 then return rank end
end

function RecipeList.Select(catalog, profession, preferences, metadata, name)
    local rows, groups = {}, {}
    local search = (preferences.search or ""):lower()
    for key, recipe in pairs(catalog.recipesById or {}) do
        if recipe.learned and tostring(recipe.professionId) == tostring(profession) then
            local meta = metadata[tostring(key)] or {}
            if meta.group and meta.group ~= "" then groups[meta.group] = true end
            if matches(recipe, preferences.filter, search, preferences.group, meta, name) then
                rows[#rows + 1] = {recipe = recipe, name = name(recipe), favorite = meta.favorite}
            end
        end
    end
    table.sort(rows, function(a, b)
        if preferences.sort == "difficulty" then
            local ra, rb = rankDifficulty(a.recipe), rankDifficulty(b.recipe)
            if ra ~= rb then return ra < rb end
        end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.recipe.id) < tostring(b.recipe.id)
    end)
    local sorted = {}
    for group in pairs(groups) do sorted[#sorted + 1] = group end
    table.sort(sorted)
    return rows, sorted
end

-- Value the identical inputs consumed by the selected route. Decline a verdict
-- when the route needs purchased stock or an input lacks a liquidation quote.
function RecipeList.SellComparison(plan, context)
    if plan.status == "ready" then return context.projection.sellOrCraftDifference end
end

local function sourceUnits(plan)
    local count = 0
    if plan.allocations then
        for _, allocation in ipairs(plan.allocations) do
            if allocation.requirementId then count = count + allocation.quantity end
        end
    else
        for _, requirement in ipairs(plan.requirements or {}) do count = count + requirement.quantity end
    end
    return count
end

function RecipeList.Evaluate(row, filter, sort, catalog)
    local output = row.recipe.yield
    if type(output) ~= "number" or output < 1 then
        row.badge = L.unknown
        return
    end
    local args = {recipeId = row.recipe.id, quantity = output, intent = "additional",
        bagsOnly = filter == "fromBags" or filter == "sell", limits = {states = 600, craftChoices = 30, depth = 16}}
    local plan, context = FC.Logistics.Preview(args, catalog)
    if plan and plan.status == "blocked" and filter == "fromBags" then
        args.bagsOnly = false
        plan, context = FC.Logistics.Preview(args, catalog)
    end
    if not plan or not plan.summary or (plan.status ~= "ready" and plan.status ~= "sourcing") then
        row.badge = L.unknown
        return
    end
    local summary = plan.summary
    if filter == "fromBags" then
        row.score = -sourceUnits(plan)
        row.badge = plan.status == "ready" and (#plan.tasks == 1 and L.now or L.intermediates)
            or L.shortage:format(-row.score)
    elseif filter == "sell" then
        row.score = RecipeList.SellComparison(plan, context)
        row.money = row.score
    elseif filter == "best" and sort == "difficulty" then
        local rank = RecipeList.SkillUpRank(row.recipe)
        if rank then row.score = -rank end
    elseif sort == "cost" then
        row.score = summary.fullValue and -summary.fullValue
        row.money = summary.fullValue
    elseif filter == "best" then
        row.score = context.projection.estimatedProfit
        row.money = row.score
        row.cost = summary.fullValue
        row.skillRank = RecipeList.SkillUpRank(row.recipe)
    end
    if not row.badge and not row.score then row.badge = L.unknown end
end

function RecipeList.Rank(rows)
    table.sort(rows, function(a, b)
        local av, bv = a.score or -math.huge, b.score or -math.huge
        if av ~= bv then return av > bv end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.recipe.id) < tostring(b.recipe.id)
    end)
end
