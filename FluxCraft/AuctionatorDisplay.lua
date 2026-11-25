local _, FC = ...

-- Adds a clearly sourced recursive estimate to Auctionator's crafting block.
-- Auctionator's own To Craft and Profit calculations remain direct-reagent values.
local Display = {}
FC.AuctionatorDisplay = Display

local function amount(value)
    if type(value) ~= "number" or value < 0 or value == math.huge then return "?" end
    if type(GetMoneyString) == "function" then
        return GetMoneyString(math.floor(value + 0.5), true)
    end
    return FC.Pricing.FormatCopper(value)
end

local function itemName(itemID)
    local name = type(GetItemInfo) == "function" and GetItemInfo(itemID)
    return name or ("Item #" .. tostring(itemID))
end

local function costEnabled()
    local auctionator = rawget(_G, "Auctionator")
    local config = auctionator and auctionator.Config
    local option = config and config.Options and config.Options.CRAFTING_INFO_SHOW_COST
    if not (option and type(config.Get) == "function") then return false end
    local ok, enabled = pcall(config.Get, option)
    return ok and enabled == true
end

function Display.Lines(comparison, nativeHasProfit)
    if not comparison or not comparison.root then return {} end
    local root = comparison.root
    if type(root.craft) ~= "number" then return {} end
    local basis = root.objective == "Lowest additional cash" and "cash route estimate"
        or "recursive input value estimate"
    if root.comparisonIncomplete then basis = basis .. "; alternatives incomplete" end
    local lines = {"FluxCraft To Craft: " .. amount(root.craft) .. " (" .. basis .. ")"}
    if root.buy then
        local verdict = root.comparisonIncomplete and "comparison incomplete"
            or root.cheaper == "make" and "craft est. cheaper"
            or root.cheaper == "buy" and "buy est. cheaper" or "equal estimate"
        lines[#lines + 1] = "Finished item: Buy " .. amount(root.buy)
            .. " / Craft " .. amount(root.craft) .. " — " .. verdict
    end
    for i = 1, math.min(#comparison.intermediates, 3) do
        local entry = comparison.intermediates[i]
        if entry.buy and entry.make then
            local verdict = entry.comparisonIncomplete and "comparison incomplete"
                or entry.cheaper == "make" and "make est. cheaper"
                or entry.cheaper == "buy" and "buy est. cheaper" or "equal estimate"
            lines[#lines + 1] = itemName(entry.itemID) .. ": Buy " .. amount(entry.buy)
                .. " / Make " .. amount(entry.make) .. " — " .. verdict
        end
    end
    if nativeHasProfit then lines[#lines + 1] = "Profit above: direct reagents" end
    return lines
end

local function matchesCurrentRecipe(frame, isModern)
    local ui = FC.UI
    local catalog = ui and ui.currentCatalog
    local recipe = catalog and catalog.recipesById[ui.selectedRecipeId]
    if not (recipe and ui.currentPlan and ui.currentComparison
        and ui.currentComparison.revision == ui.currentPlan.revision) then return false end
    if isModern then
        local native = _G.ProfessionsFrame
        local form = native and native.CraftingPage and native.CraftingPage.SchematicForm
        if frame:GetParent() ~= form or not form
            or type(form.GetRecipeInfo) ~= "function" then return false end
        local info = form:GetRecipeInfo()
        return info and tostring(info.recipeID) == tostring(recipe.recipeID or recipe.id)
    end
    if frame ~= _G.AuctionatorCraftingInfo
        or not (GetTradeSkillSelectionIndex and FC.Catalog.MatchLegacyLive) then return false end
    return FC.Catalog.MatchLegacyLive(recipe, GetTradeSkillSelectionIndex())
end

function Display.Update(frame, isModern)
    if not frame or not frame.Total or not costEnabled()
        or not matchesCurrentRecipe(frame, isModern) then return end
    local nativeText = frame.Total:GetText() or ""
    local profitLabel = rawget(_G, "AUCTIONATOR_L_PROFIT_COLON")
    local nativeHasProfit = type(profitLabel) == "string" and profitLabel ~= ""
        and nativeText:find(profitLabel, 1, true) ~= nil
    local lines = Display.Lines(FC.UI.currentComparison, nativeHasProfit)
    if #lines == 0 then return end
    -- UpdateTotal starts from Auctionator's own text each time. Do not rewrite
    -- its direct-reagent number or profit, and do not append twice.
    if nativeText:find("FluxCraft To Craft:", 1, true) then return end
    if type(frame.Total.SetWidth) == "function" and type(frame.GetWidth) == "function" then
        local width = frame:GetWidth()
        if type(width) == "number" and width >= 180 then frame.Total:SetWidth(width) end
    end
    frame.Total:SetText(nativeText .. (nativeText ~= "" and "\n" or "")
        .. table.concat(lines, "\n"))
    local nativeLines = 0
    if nativeText ~= "" then
        nativeLines = 1
        for _ in nativeText:gmatch("\n") do nativeLines = nativeLines + 1 end
    end
    local measured = type(frame.Total.GetStringHeight) == "function"
        and frame.Total:GetStringHeight() or nil
    frame:SetHeight(math.max(16, measured or (nativeLines + #lines) * 16))
    if not isModern and type(frame.AdjustPosition) == "function" then
        frame:AdjustPosition()
    end
end

function Display.Install()
    if type(hooksecurefunc) ~= "function" then return end
    local modern = rawget(_G, "AuctionatorCraftingInfoProfessionsFrame")
    if modern and type(modern.UpdateTotal) == "function"
        and Display.modernFrame ~= modern then
        local ok = pcall(hooksecurefunc, modern, "UpdateTotal", function(frame)
            Display.Update(frame, true)
        end)
        if ok then Display.modernFrame = modern end
    end
    local classic = rawget(_G, "AuctionatorCraftingInfo")
    if classic and type(classic.UpdateTotal) == "function"
        and Display.classicFrame ~= classic then
        local ok = pcall(hooksecurefunc, classic, "UpdateTotal", function(frame)
            Display.Update(frame, false)
        end)
        if ok then Display.classicFrame = classic end
    end
end

function Display.Refresh()
    Display.Install()
    local isModern = FC.target == "forever" or FC.target == "retail"
    local frame = isModern and _G.AuctionatorCraftingInfoProfessionsFrame
        or _G.AuctionatorCraftingInfo
    if frame and type(frame.UpdateTotal) == "function" and frame:IsShown() then
        frame:UpdateTotal()
    end
end

return Display
