-- Synthetic prices and recipes; these are not live game data.
local FC = {}
for _, path in ipairs({"Locale", "Planner", "Pricing", "Comparison", "AuctionatorDisplay"}) do
    assert(loadfile("FluxCraft/" .. path .. ".lua"))("FluxLogistics", FC)
end

local function recipe(id, output, reagents)
    return {id = id, professionId = 1, outputItemID = output,
        outputKind = "item", yield = 1, reagents = reagents,
        learned = true, characterKey = "current", completeness = "complete"}
end
local bolt = recipe(2, 200, {{itemID = 100, quantity = 4}})
local final = recipe(3, 300, {{itemID = 200, quantity = 10},
    {itemID = 400, quantity = 1}})
local cat = {recipesById = {[2] = bolt, [3] = final},
    byOutput = {[200] = {2}, [300] = {3}}, revision = 1}
local function q(id, gold)
    return {itemID = id, unitPrice = gold * 10000, unit = "item"}
end
local function compare(root, quotes)
    local plan = FC.Planner.Preview({rootRecipeId = root, quantity = 1,
        catalog = cat, inventory = {}, quotes = quotes, objective = "value",
        characterKey = "current", revisions = {catalog = 1}})
    assert(plan.status ~= "blocked")
    return FC.Comparison.Build(plan, cat, {}, quotes, "current")
end

local prices = {[100] = q(100, 1), [200] = q(200, 3),
    [300] = q(300, 50), [400] = q(400, 5)}
local simple = compare(2, prices)
assert(simple.root.cheaper == "buy" and not simple.hasCheaperCraftedReagent)
assert(#simple.intermediates == 0) -- Cloth is raw: no recursive view.

local bought = compare(3, prices)
assert(bought.intermediates[1].buy == 300000)
assert(bought.intermediates[1].make == 400000)
assert(bought.intermediates[1].cheaper == "buy")
assert(not bought.hasCheaperCraftedReagent)
local lines = FC.AuctionatorDisplay.Lines(bought)
assert(table.concat(lines, "\n"):find("buy est. cheaper", 1, true))

local showCost = true
_G.Auctionator = {Config = {Options = {CRAFTING_INFO_SHOW_COST = "cost"},
    Get = function() return showCost end}}
_G.AUCTIONATOR_L_PROFIT_COLON = "Profit:"
local form = {GetRecipeInfo = function() return {recipeID = 3} end}
_G.ProfessionsFrame = {CraftingPage = {SchematicForm = form}}
FC.UI = {selectedRecipeId = 3, currentCatalog = cat,
    currentPlan = {revision = bought.revision}, currentComparison = bought}
local textValue = "To Craft: direct estimate\nProfit: direct estimate"
local frame = {Total = {
    GetText = function() return textValue end,
    SetText = function(_, value) textValue = value end,
}, GetParent = function() return form end, SetHeight = function() end}
FC.AuctionatorDisplay.Update(frame, true)
assert(textValue:find("To Craft: direct estimate", 1, true))
assert(textValue:find("FluxCraft To Craft:", 1, true))
assert(textValue:find("Profit above: direct reagents", 1, true))
local once = textValue
FC.AuctionatorDisplay.Update(frame, true)
assert(textValue == once) -- A repeated hook must not duplicate the estimate.
showCost = false
textValue = "To Craft: direct estimate"
FC.AuctionatorDisplay.Update(frame, true)
assert(textValue == "To Craft: direct estimate")
showCost = true
form.GetRecipeInfo = function() return {recipeID = 999} end
FC.AuctionatorDisplay.Update(frame, true)
assert(textValue == "To Craft: direct estimate") -- Late recipe updates cannot label another recipe.

prices[100] = q(100, 0.5)
local made = compare(3, prices)
assert(made.intermediates[1].make == 200000)
assert(made.intermediates[1].cheaper == "make")
assert(made.hasCheaperCraftedReagent)

prices[200] = nil
local unknown = compare(3, prices)
assert(unknown.intermediates[1].cheaper == "unknown")
assert(not unknown.hasCheaperCraftedReagent)
print("recursive route comparison fixtures passed")
