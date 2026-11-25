local active = true
local timers, previews = {}, {}
local viewportPasses, rankLookups, textMeasurements = 0, 0, 0
C_Timer = {After = function(_, callback) timers[#timers + 1] = callback end}
local function tick()
    assert(#timers > 0)
    table.remove(timers, 1)()
end
local function drain()
    local rounds = 0
    while #timers > 0 do
        tick()
        rounds = rounds + 1
        assert(rounds <= 30, "profit work did not settle")
    end
end

local function font(width, left, title)
    local region = {
        width = width, title = title, text = title or "",
        GetLeft = function() return left end,
        GetWidth = function(self) return self.width end,
        GetStringWidth = function(self)
            textMeasurements = textMeasurements + 1
            local text, textures = self.text:gsub("|T.-|t", "")
            return #text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") * 6 + textures * 9
        end,
        SetWidth = function(self, value) self.width = value end,
        SetJustifyH = function() end,
        SetText = function(self, value) self.text, self.writes = value, (self.writes or 0) + 1 end,
        SetTextColor = function(self, r, g, b) self.color = {r, g, b} end,
        SetPoint = function(self, anchor, _, _, x) self.point = {anchor, x} end,
        ClearAllPoints = function(self) self.point = nil end,
        IsShown = function(self) return not self.hidden end,
        Hide = function(self) self.hidden, self.hides = true, (self.hides or 0) + 1 end,
        Show = function(self) self.hidden = false end,
    }
    region.GetUnboundedStringWidth = region.GetStringWidth
    return region
end
local function row(id, learned)
    return {
        id = id, learned = learned, width = 285,
        GetWidth = function(self) return self.width end, GetLeft = function() return 80 end,
        Label = font(223, 111, "Very long native recipe name"),
        Count = font(30, 334, " [4] "),
        LockedIcon = font(17, 347, ""),
        HookScript = function(self, _, callback) self.hover = callback end,
        CreateFontString = function(self)
            assert(not self.profit, "allocated a second font string for a recycled row")
            self.profit = font(0, 0)
            return self.profit
        end,
    }
end
local function element(row)
    if not row then
        return {GetData = function() return {categoryInfo = {name = "Materials"}} end}
    end
    return {GetData = function() return {recipeInfo = {recipeID = row.id, learned = row.learned}} end}
end

local first, favorite, missing, unlearned = row(11, true), row(11, true), row(21, true), row(31, false)
local rows = {first, favorite, missing, unlearned}
local scrollBox = {ForEachFrame = function(_, callback)
    viewportPasses = viewportPasses + 1
    callback({}, element())
    for _, frame in ipairs(rows) do callback(frame, element(frame)) end
end}
local list = {
    ScrollBox = scrollBox, handlers = {},
    IsVisible = function() return true end,
    HookScript = function(self, event, callback) self.handlers[event] = callback end,
}
local hooks = 0
ScrollUtil = {
    AddInitializedFrameCallback = function(box, callback, owner)
        assert(box == scrollBox); hooks = hooks + 1
        box.initialized = function(frame) callback(owner, frame, element(frame)) end
    end,
    AddReleasedFrameCallback = function(box, callback, owner)
        assert(box == scrollBox); hooks = hooks + 1
        box.released = function(frame) callback(owner, frame, element(frame)) end
    end,
}
Professions = {GetHighestLearnedRecipe = function(recipe)
    rankLookups = rankLookups + 1
    return recipe.recipeID == 11 and {recipeID = 12, learned = true} or nil
end}
local known = {
    [12] = {id = 12, learned = true, completeness = "complete", yield = 3},
    [21] = {id = 21, learned = true, completeness = "complete", yield = 1},
    [42] = {id = 42, learned = true, completeness = "complete", yield = 2},
}
local profitable = true
local reliable = true
local itemReady = false
local versions = {catalog = 1, inventory = 1, queue = 1, market = 1, owner = 1, bank = 1, vendor = 1}
local preferences = {provider = "auto", objective = "value", market = {}}
local merchantUpdate
Flux = {RestockPolicy = {GetRevision = function() return versions.owner end}}
FluxRestock = {Inv = {Bank = {GetGeneration = function() return versions.bank end}}}
FluxVendorAuto = {
    GetMerchantIndexGeneration = function() return versions.vendor end,
    RegisterMerchantIndexListener = function(listener) merchantUpdate = listener end,
}
local ns
local function projectRecipe(args, price, cost)
    local plan = {rootItemID = args.recipeId, summary = {output = args.quantity, fullValue = cost}}
    local projection = ns.Pricing.Project(plan, {saleQuote = {itemID = args.recipeId, unitPrice = price}})
    return plan, {projection = projection}
end
ns = {
    Catalog = {Snapshot = function() return {revision = versions.catalog, recipesById = known, byOutput = {[321] = {21}}} end},
    InventoryAdapter = {GetRevision = function() return versions.inventory end,
        GetStatus = function() return {reliable = reliable} end},
    Queue = {GetRevision = function() return versions.queue end},
    MarketAdapter = {GetRevision = function() return versions.market end},
    Logistics = {GetSettings = function() return preferences end, Preview = function(args)
        assert(args.previewOnly == true and args.inspectUnavailable == true and args.intent == "additional")
        assert(args.quantity == known[args.recipeId].yield)
        previews[#previews + 1] = args.recipeId
        if args.recipeId == 12 and profitable then return projectRecipe(args, 8000, 12000) end
        if args.recipeId == 42 then return projectRecipe(args, 2500, 10000) end
        if args.recipeId == 21 and itemReady then return projectRecipe(args, 10000, 5000) end
        return {}, {projection = {}}
    end},
}
assert(loadfile("FluxCraft/Locale.lua"))("FluxLogistics", ns)
assert(loadfile("FluxCraft/Pricing.lua"))("FluxLogistics", ns)
assert(loadfile("FluxCraft/RecipeProfit.lua"))("FluxLogistics", ns)
local nativeMoney = "100|TInterface\\MoneyFrame\\UI-CopperIcon:10:10|t"
C_CurrencyInfo = {GetCoinTextureString = function(copper, height)
    assert(copper == 100 and height == 10)
    return nativeMoney
end}
assert(ns.Pricing.FormatCopper(100) == nativeMoney)
C_CurrencyInfo = nil
local positive = ns.Pricing.FormatProfit(12345)
assert(positive:find("|cff55ff70+1|r|TInterface\\MoneyFrame\\UI-GoldIcon", 1, true))
assert(positive:find("|cff55ff7023|r|TInterface\\MoneyFrame\\UI-SilverIcon", 1, true))
assert(positive:find("|cff55ff7045|r|TInterface\\MoneyFrame\\UI-CopperIcon", 1, true))
assert(ns.Pricing.FormatProfit(0):find("|cffc6c6c60|r", 1, true))
assert(ns.Pricing.FormatProfitPercent(0) == "|cffc6c6c60%|r" and ns.Pricing.FormatProfitPercent(nil) == nil)
local netPositive = ns.Pricing.FormatProfit(10800) .. " (|cff55ff70+90%|r)"
ns.RecipeProfit.Attach(list, function() return active end)
ns.RecipeProfit.Attach(list, function() return active end)
assert(hooks == 2 and #previews == 0)
tick()
assert(#previews == 1 and previews[1] == 12, "rank resolution or per-tick bound failed")
drain()
assert(#previews == 2 and previews[2] == 21, "same favorite recipe should be quoted once")
assert(viewportPasses == 1 and rankLookups == #rows,
    ("a pricing pass should read each visible row once, got %d sweeps and %d rank lookups"):format(viewportPasses, rankLookups))
assert(first.profit.text == netPositive and favorite.profit.text == first.profit.text)
assert(missing.profit.text == "—" and not unlearned.profit)
assert(first.Label.text == first.Label.title and first.Count.text == " [4] ")
assert(first.Label.width < 223 and first.profit.point[2] == -21)
local passes, lookups, measurements = viewportPasses, rankLookups, textMeasurements
ns.RecipeProfit.Refresh()
ns.RecipeProfit.Refresh()
drain()
assert(#previews == 2 and not first.profit.hidden, "selection refresh discarded the unchanged price cache")
assert(viewportPasses == passes and rankLookups == lookups and textMeasurements == measurements,
    "an unchanged refresh must not visit or remeasure visible rows")
local writes, hides = first.profit.writes, first.profit.hides
for _, source in ipairs({"bank", "inventory", "owner", "market"}) do
    versions[source] = versions[source] + 1
    ns.RecipeProfit.Refresh()
    tick()
    assert(first.profit.writes == writes and first.profit.hides == hides and not favorite.profit.hidden,
        "refresh churn must keep stable values in place")
end
drain()
local knownVisits = 0
for _, id in ipairs(previews) do if id == 21 then knownVisits = knownVisits + 1 end end
assert(knownVisits > 1, "repeated invalidation must leave time for later visible rows")
reliable = false
versions.inventory = versions.inventory + 1
ns.RecipeProfit.Refresh()
drain()
assert(first.profit.writes == writes and first.profit.hides == hides, "inventory settling must keep the previous display")
local measuredPreviews = #previews
favorite.Label:SetWidth(0)
unlearned.Label:SetWidth(0)
list.handlers.OnSizeChanged()
drain()
assert(favorite.Label.width > 40 and unlearned.Label.width > 40 and not favorite.profit.hidden
    and #previews == measuredPreviews,
    "a resized viewport recovers zero-width recipe names even while inventory is settling")
favorite.width = 115
list.handlers.OnSizeChanged()
drain()
assert(favorite.Label.width > 0 and favorite.profit.hidden, "in a tight row the recipe name takes priority over profit")
favorite.width = 285
favorite.Label:SetWidth(223)
scrollBox.initialized(favorite)
drain()
assert(favorite.Label.width > 56 and not favorite.profit.hidden and #previews == measuredPreviews,
    "growing and reinitializing the same row restores the profit without requoting")
reliable = true
scrollBox.released(first)
assert(first.profit.hidden and first.Label.width == 223)
first.id = 42
first.Label:SetWidth(193)
scrollBox.initialized(first)
drain()
assert(first.profit.text == ns.Pricing.FormatProfit(-5250) .. " (|cffff5555-53%|r)"
    and first.profit.text:find("|cffff5555-52|r|T", 1, true))
profitable = false
versions.inventory = versions.inventory + 1
ns.RecipeProfit.Refresh()
drain()
assert(favorite.profit.text == "—", "a stale profit survived invalidation")
for _, source in ipairs({"catalog", "queue", "market", "owner", "bank", "vendor"}) do
    local before = #previews
    versions[source] = versions[source] + 1
    ns.RecipeProfit.Refresh()
    drain()
    assert(#previews == before + 3, source .. " revision did not invalidate visible prices")
end
local before = #previews
preferences.market = {rate = 40}
ns.RecipeProfit.Refresh()
drain()
assert(#previews == before, "retired auction-cut preferences must not invalidate recipe estimates")
profitable = true
versions.market = versions.market + 1
ns.RecipeProfit.Refresh()
drain()
assert(#previews == before + 3 and favorite.profit.text == netPositive)
GameTooltip = {
    IsShown = function(self) return self.shown end,
    IsOwned = function(self, owner) return self.owner == owner end,
    SetOwner = function(self, owner) self.owner = owner end,
    SetText = function(self, value) self.heading = value end,
    AddLine = function(self, value) self.detail = value; self.materials = self.materials or value end,
    Show = function(self) self.shown = true end,
}
favorite.hover()
assert(GameTooltip.detail:find("5% included", 1, true))
assert(GameTooltip.materials == ns.L.recipeProfitMaterials:format(ns.Pricing.FormatCopper(12000)))
GameTooltip.shown = false
first.hover()
assert(GameTooltip.detail:find("5% included", 1, true))
GameTooltip.shown = false
missing.hover()
assert(GameTooltip.detail == ns.L.recipeProfitUnavailable)
GameTooltip = nil
before = #previews
preferences.provider = "tsm"
ns.RecipeProfit.Refresh()
drain()
assert(#previews == before + 3, "provider setting did not invalidate visible prices")
before = #previews
passes, lookups = viewportPasses, rankLookups
merchantUpdate()
drain()
assert(#previews == before + 3, "live offer refresh did not force updated quotes")
assert(viewportPasses == passes + 1 and rankLookups == lookups + #rows,
    "a complete invalidation must price each visible recipe without repeated viewport scans")
before = #previews
active = false
ns.RecipeProfit.Hide()
assert(favorite.Label.width == 223 and first.Label.width == 193 and first.profit.hidden)
active = true
ns.RecipeProfit.Refresh()
drain()
assert(#previews == before and not first.profit.hidden, "show did not reuse the valid cache")
itemReady = true
ns.RecipeProfit.ItemDataLoaded(999)
drain()
assert(#previews == before and missing.profit.text == "—")
ns.RecipeProfit.ItemDataLoaded(321)
drain()
assert(#previews == before + 1 and previews[#previews] == 21
    and missing.profit.text == ns.Pricing.FormatProfit(4500) .. " (|cff55ff70+90%|r)",
    "an exact output price must be retried after that item's data loads")
print("Forever recipe profit estimates, ranks, pooling and native controls passed")
