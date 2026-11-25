local _, FC = ...
local L = FC.L
local RecipeProfit = {}
FC.RecipeProfit = RecipeProfit

local active
local unknown = {text = L.recipeProfitUnknown}

local function positiveWidth(value)
    return not (issecretvalue and issecretvalue(value)) and type(value) == "number"
        and value > 0 and value < math.huge
end

local function clear(row, entry, reinitialized)
    if entry.label:IsShown() then entry.label:Hide() end
    if not reinitialized and entry.appliedWidth and row.Label:GetWidth() == entry.appliedWidth then
        row.Label:SetWidth(entry.nativeWidth)
    end
    entry.nativeWidth, entry.appliedWidth = nil, nil
end

local function showProfitHelp(row, entry)
    local value = entry.value
    if not value or not entry.label:IsShown() or not GameTooltip then return end
    if GameTooltip:IsShown() then
        if not (GameTooltip:IsOwned(row) or GameTooltip:IsOwned(row.Label)) then return end
    else
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.recipeProfitTooltip)
    end
    if value == unknown then
        GameTooltip:AddLine(L.recipeProfitUnavailable, 0.92, 0.86, 0.7, true)
    else
        if value.cost then GameTooltip:AddLine(L.recipeProfitMaterials:format(FC.Pricing.FormatCopper(value.cost))) end
        if value.cut then GameTooltip:AddLine(L.recipeProfitFee:format(value.cut * 100), 0.92, 0.86, 0.7, true) end
    end
    GameTooltip:Show()
end

local function fitTitle(row, entry, profitWidth)
    -- Preserve the native count beside the name and the lock at the right edge.
    local width = row:GetWidth()
    if not positiveWidth(width) then return end
    local titleLeft, rowLeft = row.Label:GetLeft(), row:GetLeft()
    local left = titleLeft and rowLeft and math.max(0, titleLeft - rowLeft)
        or (row.SkillUps and row.SkillUps:GetWidth() or 26) + 4
    local count = row.Count and row.Count:IsShown() and row.Count:GetStringWidth() or 0
    local lock = row.LockedIcon and row.LockedIcon:IsShown() and row.LockedIcon:GetWidth() or 0
    local available = width - left - count - lock - 12
    if available < 1 then return end
    local measured = row.Label.GetUnboundedStringWidth and row.Label:GetUnboundedStringWidth()
    if not positiveWidth(measured) then measured = nil end
    local current = row.Label:GetWidth()
    local native = entry and entry.appliedWidth and entry.appliedWidth == current and entry.nativeWidth or current
    -- Some rows are initialized before their anchors settle and acquire a
    -- zero-width title. Measure the text independently of that width.
    if not positiveWidth(native) or measured and native < math.min(measured, 12) then
        native = math.min(available, measured or available)
    end
    local showProfit = positiveWidth(profitWidth) and available - profitWidth >= math.min(56, measured or native)
    local fitted = math.min(math.max(native, measured or 0), showProfit and available - profitWidth or available)
    if current ~= fitted then row.Label:SetWidth(fitted) end
    if entry then
        if fitted ~= native then
            entry.nativeWidth, entry.appliedWidth = native, row.Label:GetWidth()
        else
            entry.nativeWidth, entry.appliedWidth = nil, nil
        end
    end
    return showProfit, lock
end

local function fittedProfit(state, row, id, value, initialized)
    local entry = state.rows[row]
    if entry and entry.id ~= id then
        clear(row, entry, initialized)
        entry.id, entry.value = id, nil
    elseif entry and initialized then
        -- Blizzard remeasures the title even when a pooled row keeps the same recipe.
        entry.nativeWidth, entry.appliedWidth = nil, nil
    end
    if not value then
        if not positiveWidth(row.Label:GetWidth()) then fitTitle(row) end
        return
    end
    if not entry then
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetJustifyH("RIGHT")
        entry = {label = label}
        state.rows[row] = entry
        if row.HookScript then row:HookScript("OnEnter", function() showProfitHelp(row, entry) end) end
    end
    local label = entry.label
    if not entry.value or entry.value.text ~= value.text then
        label:SetText(value.text)
        if value == unknown then label:SetTextColor(0.60, 0.60, 0.60)
        else label:SetTextColor(1, 1, 1) end
    end
    entry.value, entry.id = value, id

    local showProfit, lock = fitTitle(row, entry, label:GetStringWidth())
    if not showProfit then
        if label:IsShown() then label:Hide() end
        return
    end
    if entry.lockWidth ~= lock then
        label:ClearAllPoints()
        label:SetPoint("RIGHT", row, "RIGHT", -lock - 4, 0)
        entry.lockWidth = lock
    end
    if not label:IsShown() then label:Show() end
end

local function recipeID(element)
    local data = type(element) == "table" and element.GetData and element:GetData()
    local recipe = data and data.recipeInfo
    if not recipe then return end
    if Professions and Professions.GetHighestLearnedRecipe then
        recipe = Professions.GetHighestLearnedRecipe(recipe) or recipe
    end
    if recipe.learned and type(recipe.recipeID) == "number" then return recipe.recipeID, true end
    return nil, true
end

function RecipeProfit.Quote(recipe, catalog)
    if not recipe or recipe.learned ~= true or recipe.completeness ~= "complete"
        or type(recipe.yield) ~= "number" or recipe.yield < 1 then return unknown end
    local _, context = FC.Logistics.Preview({
        recipeId = recipe.id, quantity = recipe.yield, intent = "additional",
        previewOnly = true, inspectUnavailable = true,
        limits = {states = 600, craftChoices = 20, depth = 16},
    }, catalog)
    local projection = type(context) == "table" and context.projection
    if not projection then return unknown end
    local value = projection.estimatedProfit
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return unknown end
    local coins = FC.Pricing.FormatProfit(value)
    local percent = FC.Pricing.FormatProfitPercent(projection.profitOnCostPercent)
    return {
        text = percent and L.recipeProfitWithPercent:format(coins, percent) or coins,
        cut = projection.saleAssumptions and projection.saleAssumptions.cutRate,
        cost = projection.manufacturingEstimate,
    }
end

local function visible(state)
    return active == state and state.isActive() and state.recipeList:IsVisible()
end

local function read(source, method)
    local getter = source and source[method]
    return type(getter) == "function" and getter() or false
end

function RecipeProfit.Revision(catalog, status)
    local settings = FC.Logistics.GetSettings()
    local inventory = FC.InventoryAdapter
    local market = FC.MarketAdapter or FC.AuctionatorAdapter
    local policy = Flux and Flux.RestockPolicy
    local restock = FluxRestock and FluxRestock.Inv
    local bank = restock and restock.Bank
    local vendor = FluxVendorAuto
    local auctionator = Auctionator and Auctionator.API and Auctionator.API.v1
    local parts = {
        catalog.revision or 0, catalog.characterKey or false, catalog.build or false,
        read(inventory, "GetRevision"), status and status.reliable == true or false,
        read(FC.Queue, "GetRevision"), read(market, "GetRevision"), read(FC.Logistics, "GetAuctionDepthRevision"),
        auctionator and type(auctionator.GetAuctionPriceByItemID) == "function" or false,
        TSM_API and type(TSM_API.GetCustomPriceValue) == "function" or false,
        read(policy, "GetRevision"), read(bank, "GetGeneration"), read(bank, "IsLive"),
        read(restock, "IsMerchantOpen"), read(vendor, "GetMerchantIndexGeneration"),
        read(vendor, "IsMerchantIndexBuildPending"),
        settings.provider or "auto", settings.allowFallback == true, settings.objective or "value",
    }
    for index, value in ipairs(parts) do parts[index] = tostring(value) end
    return table.concat(parts, "\031")
end

local function rebuildViewport(state)
    local ids, rows, indices = {}, {}, {}
    state.viewportDirty = false
    state.scrollBox:ForEachFrame(function(row, element)
        local id, isRecipe = recipeID(element)
        if not isRecipe or not row.Label then return end
        if id then
            local group = rows[id]
            if not group then
                group = {}
                rows[id], ids[#ids + 1] = group, id
                indices[id] = #ids
            end
            group[#group + 1] = row
        end
        local cached = id and state.cached[id]
        fittedProfit(state, row, id, cached and cached.value)
    end)
    state.viewportIds, state.viewportRows, state.viewportIndices = ids, rows, indices
    state.cursor = 1
end

local function nextRecipe(state)
    local ids = state.viewportIds
    while state.cursor <= #ids do
        local id = ids[state.cursor]
        local cached = state.cached[id]
        if not cached or cached.epoch ~= state.epoch then return id end
        state.cursor = state.cursor + 1
    end
end

local function cacheProfit(state, id, catalog)
    if not state.cached[id] then
        if state.cacheSize >= 80 then
            -- Drop older scroll results without resolving native row identities again.
            local visibleCache, count = {}, 0
            for _, current in ipairs(state.viewportIds) do
                if state.cached[current] then
                    visibleCache[current] = state.cached[current]
                    count = count + 1
                end
            end
            state.cached, state.cacheSize = visibleCache, count
        end
        state.cacheSize = state.cacheSize + 1
    end
    local value = RecipeProfit.Quote(catalog.recipesById[id], catalog)
    state.cached[id] = {value = value, epoch = state.epoch}
    if not state.viewportDirty then
        for _, row in ipairs(state.viewportRows[id]) do fittedProfit(state, row, id, value) end
    end
end

local function schedule(state)
    if state.scheduled or not visible(state) then return end
    state.scheduled = true
    C_Timer.After(0, function()
        state.scheduled = false
        if not visible(state) then return end
        local status = read(FC.InventoryAdapter, "GetStatus")
        local canPrice = not status or status.reliable
        local catalog = canPrice and FC.Catalog.Snapshot()
        local current = canPrice and RecipeProfit.Revision(catalog, status)
        local newEpoch = canPrice and not state.refreshing and state.revision ~= current
        -- Finish the current viewport's pending quotes before consuming repeated revisions.
        if newEpoch then
            state.epoch, state.revision = state.epoch + 1, current
        end
        if newEpoch or state.viewportDirty then rebuildViewport(state) end
        if not canPrice then return end
        local id = nextRecipe(state)
        if id then
            state.cursor = state.cursor + 1
            cacheProfit(state, id, catalog)
        end
        state.refreshing = nextRecipe(state) ~= nil
        if state.refreshing or state.revision ~= current then schedule(state) end
    end)
end

local function refreshViewport(state)
    state.viewportDirty = true
    schedule(state)
end

function RecipeProfit.Hide()
    if active then
        active.viewportDirty = true
        for row, entry in pairs(active.rows) do clear(row, entry) end
    end
end

function RecipeProfit.Refresh(force)
    if not active then return end
    if force then active.revision = nil end
    schedule(active)
end

function RecipeProfit.ItemDataLoaded(itemID)
    if not active or type(itemID) ~= "number" or (issecretvalue and issecretvalue(itemID)) then return end
    local catalog = FC.Catalog.Snapshot()
    local affected = false
    local ids = catalog.byOutput and catalog.byOutput[itemID]
    for _, id in ipairs(ids or {}) do
        local cached = active.cached[id]
        if cached then
            cached.epoch, affected = nil, true
            local index = active.viewportIndices[id]
            if index then active.cursor = math.min(active.cursor, index) end
        end
    end
    if affected then schedule(active) end
    return affected
end

function RecipeProfit.Attach(recipeList, isActive)
    local scrollBox = recipeList and recipeList.ScrollBox
    if not scrollBox or not scrollBox.ForEachFrame or not C_Timer or not C_Timer.After
        or not ScrollUtil or not ScrollUtil.AddInitializedFrameCallback
        or not ScrollUtil.AddReleasedFrameCallback then return end
    if active and active.recipeList == recipeList then return end
    RecipeProfit.Hide()
    local state = {
        recipeList = recipeList, scrollBox = scrollBox, isActive = isActive,
        rows = {}, cached = {}, cacheSize = 0, epoch = 0,
        viewportDirty = true, viewportIndices = {},
    }
    active = state
    ScrollUtil.AddInitializedFrameCallback(scrollBox, function(_, row, element)
        if not visible(state) or not row.Label then return end
        local id, isRecipe = recipeID(element)
        if not isRecipe and row.GetElementData then id, isRecipe = recipeID(row:GetElementData()) end
        if not isRecipe then return end
        local cached = id and state.cached[id]
        fittedProfit(state, row, id, cached and cached.value, true)
        refreshViewport(state)
    end, state)
    ScrollUtil.AddReleasedFrameCallback(scrollBox, function(_, row)
        local entry = state.rows[row]
        if entry then clear(row, entry) end
        refreshViewport(state)
    end, state)
    recipeList:HookScript("OnHide", function()
        if active == state then RecipeProfit.Hide() end
    end)
    recipeList:HookScript("OnShow", function() refreshViewport(state) end)
    recipeList:HookScript("OnSizeChanged", function() refreshViewport(state) end)
    if scrollBox.HookScript then scrollBox:HookScript("OnSizeChanged", function() refreshViewport(state) end) end
    local vendor = FluxVendorAuto
    if vendor and vendor.RegisterMerchantIndexListener then
        vendor.RegisterMerchantIndexListener(function()
            if active == state then RecipeProfit.Refresh(true) end
        end)
    end
    schedule(state)
end
