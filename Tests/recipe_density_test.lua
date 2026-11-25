local ns = {}
assert(loadfile("FluxCraft/RecipeDensity.lua"))("FluxLogistics", ns)

local function node(data)
    return {GetData = function() return data end}
end
local category = node({categoryInfo = {}})
local recipe = node({recipeInfo = {recipeID = 1}})
local divider = node({dividerHeight = 30})
local nodes = {category, recipe, recipe, divider}
local function nativeExtent(_, element)
    local data = element:GetData()
    return data.recipeInfo and 20 or data.categoryInfo and 25 or data.dividerHeight
end

local function region(height)
    return {height = height, GetHeight = function(self) return self.height end,
        SetHeight = function(self, value) self.height = value end}
end
local categoryRow = region(25)
local recipeRow = region(20)
recipeRow.GetOrderIndex = function() return 3 end
recipeRow.SelectedOverlay, recipeRow.HighlightOverlay = region(20), region(21)

local calculator, cached = nativeExtent, true
local view = {}
function view:GetElementExtentCalculator() return calculator end
function view:SetElementExtentCalculator(fn) calculator, cached = fn, false end
function view:ResizeFrame(_, row, index, element) row:SetHeight(calculator(index, element)) end

local box = {position = 50, updates = 0}
function box:GetView() return view end
function box:GetDataIndexBegin() return 3 end
function box:GetDerivedScrollOffset() return self.position end
function box:GetElementExtent(index) return calculator(index, nodes[index]) end
function box:GetExtentUntil(index)
    assert(cached, "scroll anchor must be read before invalidating native extents")
    local extent = 0
    for i = 1, index - 1 do extent = extent + calculator(i, nodes[i]) + 1 end
    return extent
end
function box:ForEachFrame(callback)
    callback(categoryRow, category)
    callback(recipeRow, recipe)
end
function box:FullUpdate(immediately)
    assert(immediately)
    self.updates, cached = self.updates + 1, true
end
function box:ScrollToOffset(offset, noInterpolation)
    assert(noInterpolation)
    self.position = offset
end

local initialized, released
ScrollUtil = {
    AddInitializedFrameCallback = function(_, callback) initialized = callback end,
    AddReleasedFrameCallback = function(_, callback) released = callback end,
}

local setActive = assert(ns.RecipeDensity.Attach({ScrollBox = box}))
setActive(true)
assert(recipeRow.height == 15 and recipeRow.SelectedOverlay.height == 15 and recipeRow.HighlightOverlay.height == 15)
assert(categoryRow.height == 25 and calculator(1, category) == 25 and calculator(4, divider) == 30)
assert(box.updates == 1 and box.position == 44.25, "toggle must preserve the first visible recipe and its relative offset")
setActive(true)
assert(box.updates == 1, "identical visibility must not refresh the native view")

released(nil, recipeRow)
assert(recipeRow.SelectedOverlay.height == 20 and recipeRow.HighlightOverlay.height == 21)
initialized(nil, recipeRow, recipe)
assert(recipeRow.SelectedOverlay.height == 15 and recipeRow.HighlightOverlay.height == 15)

setActive(false)
assert(calculator == nativeExtent and box.updates == 2 and box.position == 50)
assert(recipeRow.height == 20 and recipeRow.SelectedOverlay.height == 20 and recipeRow.HighlightOverlay.height == 21)
initialized(nil, recipeRow, recipe)
assert(recipeRow.HighlightOverlay.height == 21, "released workbench must leave native rows alone")
print("Forever compact recipe rows preserve scroll and restore native sizes")
