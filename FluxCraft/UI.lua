local _, FC = ...
local L = FC.L
local UI = {history = {}, recipeRows = {}, queueRows = {}, queueOffset = 0}
local QUEUE_ACTION_HEIGHT = 120
local PROFESSION_REMINDER_HEIGHT = 46
local QUEUE_ROW_HEIGHT = 20
local COMPACT_QUEUE_ROW_HEIGHT = 34
local QUEUE_PADDING, GRAPH_GAP = 4, 4
local CLASSIC_RAIL_INSET = 53
local CLASSIC_BOOK_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local CLASSIC_UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local RECIPE_SKILL_COLORS = {{1, 0, 0}, {1, 0.50, 0.25}, {1, 1, 0}, {0.25, 0.75, 0.25}, {0.50, 0.50, 0.50}}
FC.UI = UI
if FC.disabled then return end

local function refreshRestockProfessionLayer()
    local auction = _G.FluxAuctionRestock
    local followup = auction and auction.Followup
    if followup and followup.RefreshProfessionLayer then followup.RefreshProfessionLayer() end
end

local function professionFollowup()
    local auction = _G.FluxAuctionRestock
    return auction and auction.Followup
end

local function nativeReminderAnchor()
    if not (UI.forever and UI.forever:IsVisible()) then return end
    if UI.nativeCraftProgress and UI.nativeCraftProgress:IsVisible() then return UI.nativeCraftProgress end
    if UI.nativeCraftHint and UI.nativeCraftHint:IsVisible() then return UI.nativeCraftHint end
end

local function professionSpell()
    local action = UI.shownProfessionAction
    local profession = action and action.kind == "profession" and action.profession
    local spellID = profession and profession.spellID
    if not (issecretvalue and issecretvalue(spellID)) and type(spellID) == "number"
        and spellID > 0 and spellID < math.huge and spellID % 1 == 0 then return spellID end
end

local function refreshProfessionClick()
    local button = UI.craftNext
    local proxy = button.professionClickProxy
    if not proxy then
        local owner = _G.Flux
        proxy = owner and owner.SecureClickProxy
        if not button:IsVisible() or not professionSpell() or not proxy or not proxy.Attach or not proxy.Refresh then return end
        proxy.Attach(button, {
            spell = professionSpell,
            enabled = function()
                return button:IsVisible() and UI.shownProfessionAction and UI.shownProfessionAction.canAct == true
                    and professionSpell() ~= nil
            end,
            clicks = "LeftButtonUp",
        })
        button.professionClickProxy = proxy
    end
    proxy.Refresh(button)
end

local function setProfessionReminderDock(shown)
    local dock = UI.professionReminderDock
    if not dock then
        if not shown then return end
        dock = CreateFrame("Frame", nil, UI.plan)
        dock:SetSize(196, PROFESSION_REMINDER_HEIGHT)
        dock:SetPoint("BOTTOM", UI.plan, "BOTTOM", 0, QUEUE_ACTION_HEIGHT)
        dock:EnableMouse(false)
        dock:Hide()
        UI.professionReminderDock = dock
    end
    if dock:IsShown() == shown then return end
    dock:SetShown(shown)
    UI.queuePane:SetPoint("BOTTOMLEFT", 0, QUEUE_ACTION_HEIGHT + (shown and PROFESSION_REMINDER_HEIGHT or 0))
    UI.RenderQueue()
end

local function refreshProfessionAction()
    if not UI.craftNext then return end
    local followup = professionFollowup()
    local action = UI.window:IsVisible() and followup and followup.GetProfessionWindowAction
        and followup.GetProfessionWindowAction()
    local ownsDock = followup and followup.HasProfessionReminderDock == true
    setProfessionReminderDock(not not (action and ownsDock))
    if ownsDock then action = nil end
    UI.shownProfessionAction = action
    if action then
        local caption = L.craftNext
        if action.kind == "profession" then caption = L.openProfessionAction
        elseif action.logistics and action.logistics.resume then caption = L.processShort
        elseif action.nativeCraftPrepared then caption = L.useNativeCreate
        elseif action.nativeCraft then caption = L.openRecipeAction end
        UI.craftNext:SetText(caption)
        UI.craftNext:SetEnabled(action.canAct == true and not action.nativeCraftPrepared)
    end
    UI.craftNext:SetShown(not not action)
    refreshProfessionClick()
end

local function label(parent, value, font)
    local field = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    field:SetText(value or "")
    field:SetJustifyH("LEFT")
    field:SetJustifyV("TOP")
    return field
end

local function button(parent, value, width, onClick)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(width, 21)
    control:SetText(value)
    control:SetScript("OnClick", onClick)
    return control
end

local function edit(parent, width, hint, onEnter)
    local control = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    control:SetSize(width, 20)
    control:SetAutoFocus(false)
    control:SetScript("OnEnterPressed", function(self)
        onEnter(self:GetText())
        self:ClearFocus()
    end)
    control:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if hint then
        local placeholder = label(control, hint)
        placeholder:SetPoint("LEFT", 6, 0)
        control:HookScript("OnTextChanged", function(self) placeholder:SetShown(self:GetText() == "") end)
        control:HookScript("OnEditFocusGained", function() placeholder:Hide() end)
        control:HookScript("OnEditFocusLost", function(self) placeholder:SetShown(self:GetText() == "") end)
    end
    return control
end

local function place(control, left, gap)
    control:SetPoint("LEFT", left, "RIGHT", gap or 3, 0)
end

local function tint(parent, r, g, b)
    local texture = parent:CreateTexture(nil, "BACKGROUND")
    texture:SetAllPoints()
    if texture.SetColorTexture then texture:SetColorTexture(r, g, b, 1)
    else texture:SetTexture(r, g, b, 1) end
end

local function professionArt(parent)
    local name = "Professions-background-summarylist"
    if FC.target ~= "forever" or not C_Texture or not C_Texture.GetAtlasInfo or not C_Texture.GetAtlasInfo(name) then return end
    local texture = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
    texture:SetAllPoints()
    texture:SetAtlas(name)
    texture:SetAlpha(0.5)
end

local function itemInfo(id)
    if not id then return L.unknown, "Interface\\Icons\\INV_Misc_QuestionMark" end
    local name = GetItemInfo and GetItemInfo(id)
    local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id))
        or (GetItemIcon and GetItemIcon(id))
    return name or L.item:format(id), icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function recipeName(recipe)
    return recipe.name or itemInfo(recipe.outputItemID)
end

local function amount(value)
    return value and FC.Pricing.FormatCopper(value) or L.unknown
end

local function totalAndUnit(total, unit)
    local text = total ~= nil and amount(total) or L.unknown
    if unit ~= nil then return L.materialCostPair:format(text, L.materialUnit:format(amount(unit))) end
    return text
end

local function paintStatus()
    local text = not UI.job and UI.pendingDraft and not UI.preview and L.calculatingPlan or UI.message or ""
    local warning = UI.craftRequirement
    if warning and warning ~= text then text = text == "" and warning or warning .. "\n" .. text end
    if UI.status and UI.status:GetText() ~= text then UI.status:SetText(text) end
end

local function notify(message)
    UI.message = message
    paintStatus()
end

local function addPriceEvidence(quote, missing)
    if type(quote) == "table" and quote.source then
        GameTooltip:AddLine(L.marketEstimateSource:format(quote.source), 0.85, 0.80, 0.67, true)
        if quote.ageUnit == "days" and type(quote.age) == "number" then
            GameTooltip:AddLine(L.marketEstimateAge:format(quote.age), 0.85, 0.80, 0.67)
        end
    elseif type(missing) == "string" then
        GameTooltip:AddLine(missing, 0.85, 0.80, 0.67, true)
    end
end

local function itemPriceEvidence(context, itemID)
    if not context or not itemID then return end
    return context.quotes and context.quotes[itemID], context.missingQuotes and context.missingQuotes[itemID]
end

local function tooltip(owner, itemID, link, node, recipeMeta, marketPrice)
    if not itemID or not GameTooltip then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if link then GameTooltip:SetHyperlink(link)
    elseif GameTooltip.SetItemByID then GameTooltip:SetItemByID(itemID)
    else GameTooltip:SetHyperlink("item:" .. itemID) end
    if node then
        local required, fromBags = node.required or 0, node.ownedUsed or 0
        if node.source == "Covered" then
            GameTooltip:AddLine(L.tooltipStockCoverage:format(fromBags, node.committed or 0, 0), 1, 0.85, 0.66)
        elseif UI.job then
            GameTooltip:AddLine(L.tooltipAcceptedQuantities:format(required, fromBags), 1, 0.85, 0.66)
        else
            local remaining = math.max(0, required - fromBags - (node.surplusUsed or 0))
            GameTooltip:AddLine(L.tooltipQuantities:format(required, fromBags, remaining), 1, 0.85, 0.66)
        end
        if node.costStatus then GameTooltip:AddLine(L.planCost:format(amount(node.fullValue), amount(node.additionalCash))) end
        local unit, average = FC.Pricing.MaterialUnitPrice(node)
        if unit then GameTooltip:AddLine((average and L.materialUnitAverage or L.materialUnit):format(amount(unit))) end
        if node.professionName then GameTooltip:AddLine(node.professionName, 1, 1, 1) end
        local context = not UI.job and UI.context
        local quote, missing = itemPriceEvidence(context, itemID)
        local selectedQuote = node.quote
        if selectedQuote and (selectedQuote.kind == "bank" or selectedQuote.kind == "vendor") then selectedQuote = nil end
        addPriceEvidence(selectedQuote or quote, missing)
        local vendor = FC.Pricing.FormatVendor(FC.Pricing.GetVendorPrice(itemID, context and context.acquisitions))
        if vendor then GameTooltip:AddLine(vendor, 1, 0.85, 0.66) end
        if context and node.source ~= "Covered" and FC.Comparison.BuildForNode then
            local comparison = FC.Comparison.BuildForNode(UI.preview, node, context, FC.state.characterKey)
            if comparison then
                GameTooltip:AddLine(L.comparison:format(amount(comparison.make), amount(comparison.buy)), 0.9, 0.9, 0.9)
                if comparison.makeSavingsPercent then
                    GameTooltip:AddLine(L.savings:format(amount(comparison.makeSavings), comparison.makeSavingsPercent), 0.9, 0.9, 0.9)
                end
                if comparison.selectedSource == "Mixed" and comparison.selectedSavingsPercent then
                    GameTooltip:AddLine(L.mixedSavings:format(amount(comparison.selectedSavings),
                        comparison.selectedSavingsPercent), 0.9, 0.9, 0.9)
                end
                if comparison.comparisonIncomplete then GameTooltip:AddLine(L.incompletePrices, 0.82, 0.71, 0.55) end
            end
        end
        if node.blocker then GameTooltip:AddLine(node.blocker, 1, 0.62, 0.39, true) end
        local bank = FC.InventoryAdapter.InformationalBankCount(itemID)
        if bank and bank > 0 then GameTooltip:AddLine(L.bankObserved:format(bank), 0.68, 0.78, 1) end
        if node.children and #node.children > 0 then GameTooltip:AddLine(L.foldHint, 0.85, 0.78, 0.62) end
    end
    if recipeMeta then
        if recipeMeta.group then GameTooltip:AddLine(L.recipeGroup:format(recipeMeta.group)) end
        if recipeMeta.note then GameTooltip:AddLine(L.recipeNote:format(recipeMeta.note), 1, 1, 1, true) end
        GameTooltip:AddLine(L.recipeMenuHint, 0.85, 0.78, 0.62)
    elseif not node then
        if marketPrice then
            local unit = amount(marketPrice.totalCopper / marketPrice.quantity)
            GameTooltip:AddLine(L.shoppingListedCost:format(marketPrice.quantity, amount(marketPrice.totalCopper),
                (marketPrice.average and L.materialUnitAverage or L.materialUnit):format(unit)))
        end
        local vendor = FC.Pricing.GetVendorPrice(itemID)
        if vendor and type(vendor.unitPrice) == "number" then
            local format = vendor.estimate and L.vendorEstimateUnit or L.vendorLiveUnit
            GameTooltip:AddLine(format:format(amount(vendor.unitPrice)), 1, 0.85, 0.66)
        end
    end
    GameTooltip:Show()
end

local function preferences()
    local key = tostring(UI.professionID or "")
    UI.saved.perProfession[key] = UI.saved.perProfession[key] or {}
    return UI.saved.perProfession[key]
end

local function selectedRecipe()
    return UI.catalog and UI.catalog.recipesById[UI.selectedRecipeId]
end

local function isOpenProfession(recipe)
    local profession = recipe and FC.Clients.CurrentProfessionID()
    return profession ~= nil and tostring(recipe.professionId) == tostring(profession)
end

local function paintRecipeSkillRanges(bar)
    local width = bar:GetWidth()
    local minimum, maximum = bar.minimum, bar.maximum
    local scale = width and width > 0 and maximum and width / (maximum - minimum)
    local limits = bar.yellow and {bar.orange or minimum, bar.yellow, bar.green, bar.gray, maximum}
    local from = minimum
    for index, region in ipairs(bar.ranges) do
        local limit = scale and limits and math.max(minimum, math.min(limits[index], maximum))
        region:SetShown(not not (limit and limit > from))
        if limit and limit > from then
            region:SetPoint("TOPLEFT", bar, "TOPLEFT", (from - minimum) * scale, 0)
            region:SetWidth((limit - from) * scale)
        end
        from = limit or from
    end
    local progress = scale and (bar.rank - minimum) * scale
    bar.progress:SetShown(not not (progress and progress > 0 and not limits))
    bar.marker:SetShown(not not scale)
    if scale then
        local offset = math.min(math.max(0, width - 2), math.max(0, progress - 1))
        bar.marker:SetPoint("TOPLEFT", bar, "TOPLEFT", offset, 0)
        if not limits then
            local color = RECIPE_SKILL_COLORS[bar.tier + 1]
            bar.progress:SetColorTexture(color[1], color[2], color[3])
            bar.progress:SetWidth(progress)
        end
    end
end

local function createRecipeSkillStrip(parent, rankBar, height)
    if not rankBar then return end
    local bar = CreateFrame("Frame", nil, parent)
    -- The Forever border atlas has padding below the visible fill.
    local edge = rankBar.Fill or rankBar
    bar:SetHeight(height)
    bar:SetPoint("TOPLEFT", edge, "BOTTOMLEFT", 0, -1)
    bar:SetPoint("TOPRIGHT", edge, "BOTTOMRIGHT", 0, -1)
    bar:SetFrameLevel(math.max(parent:GetFrameLevel() + 3, rankBar:GetFrameLevel() + 1))
    tint(bar, 0.27, 0.25, 0.22)
    bar.rankBar, bar.ranges = rankBar, {}
    for index, color in ipairs(RECIPE_SKILL_COLORS) do
        local region = bar:CreateTexture(nil, "ARTWORK")
        region:SetHeight(height)
        region:SetColorTexture(color[1], color[2], color[3])
        bar.ranges[index] = region
    end
    bar.progress = bar:CreateTexture(nil, "ARTWORK")
    bar.progress:SetPoint("TOPLEFT")
    bar.progress:SetHeight(height)
    bar.marker = bar:CreateTexture(nil, "OVERLAY")
    bar.marker:SetSize(2, height)
    bar.marker:SetColorTexture(1, 1, 1)
    bar:HookScript("OnSizeChanged", paintRecipeSkillRanges)
    if bar.EnableMouseMotion then bar:EnableMouseMotion(true) else bar:EnableMouse(true) end
    bar:SetScript("OnEnter", function(self)
        if not GameTooltip or not self.recipe then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText((recipeName(self.recipe)))
        local color = RECIPE_SKILL_COLORS[self.tier + 1]
        GameTooltip:AddLine(self.rankText, color[1], color[2], color[3])
        if self.thresholdText then GameTooltip:AddLine(self.thresholdText) end
        GameTooltip:Show()
    end)
    local function hideTooltip(self)
        if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end
    bar:SetScript("OnLeave", hideTooltip)
    bar:SetScript("OnHide", hideTooltip)
    bar:Hide()
    UI.recipeSkill = bar
end

local function updateRecipeSkill(recipe)
    local bar = UI.recipeSkill
    if not bar then return end
    if UI.nativeCraftMessage or not (UI.window:IsVisible() and bar.rankBar:IsVisible()) then
        bar:Hide()
        return
    end
    if UI.job then
        local id = UI.job.rootRecipeId or UI.job.tree and UI.job.tree.recipeId
        recipe = id and FC.Catalog.Get(id)
    end
    local tier = recipe and recipe.learned and FC.RecipeList.SkillUpRank(recipe)
    local rank, maximum
    if tier and tostring(recipe.professionId) == tostring(UI.professionID) and FC.Clients.GetRecipeSkillProgress then
        rank, maximum = FC.Clients.GetRecipeSkillProgress(recipe)
    end
    local shown = not (issecretvalue and (issecretvalue(rank) or issecretvalue(maximum)))
        and type(rank) == "number" and type(maximum) == "number" and rank >= 0 and rank < maximum
    if shown then
        local minimum = 0
        if bar.rankBar.GetMinMaxValues then
            local nativeMin, nativeMax = bar.rankBar:GetMinMaxValues()
            if not (issecretvalue and (issecretvalue(nativeMin) or issecretvalue(nativeMax)))
                and nativeMax == maximum and type(nativeMin) == "number" and nativeMin <= rank then
                minimum = nativeMin
            end
        end
        local yellow, green, gray, orange
        local spellID = recipe.recipeID
        if recipe.legacy then spellID = recipe.legacySpellID end
        if spellID and FC.SkillRanges then yellow, green, gray, orange = FC.SkillRanges.Get(spellID, recipe.professionId) end
        if yellow then
            local observed = rank < yellow and 1 or rank < green and 2 or rank < gray and 3 or 4
            if tier ~= observed or recipe.maxTrivialLevel and gray ~= recipe.maxTrivialLevel then
                yellow, green, gray, orange = nil, nil, nil, nil
            elseif orange and (orange > rank or orange <= minimum) then
                orange = nil
            end
        end
        local changed = bar.minimum ~= minimum or bar.maximum ~= maximum or bar.rank ~= rank or bar.tier ~= tier
            or bar.orange ~= orange or bar.yellow ~= yellow or bar.green ~= green or bar.gray ~= gray
        bar.minimum, bar.maximum, bar.rank, bar.tier = minimum, maximum, rank, tier
        bar.orange, bar.yellow, bar.green, bar.gray = orange, yellow, green, gray
        bar.recipe = recipe
        bar.thresholdText = orange and L.recipeSkillFullThresholds:format(orange, orange, yellow, green, gray)
            or yellow and L.recipeSkillThresholds:format(yellow, yellow, green, gray)
        local gain = recipe.numSkillUps and math.min(recipe.numSkillUps, maximum - rank)
        bar.rankText = gain and gain > 0 and L.recipeSkillGain:format(rank, maximum, gain) or L.recipeSkillRank:format(rank, maximum)
        if changed then paintRecipeSkillRanges(bar) end
    end
    bar:SetShown(shown)
end

local function checkCraftRequirement(refreshRestock)
    local recipe = UI.requirementRecipe
    local requirements
    if recipe then
        if FC.Catalog.ReadLiveRequirements then
            requirements, UI.requirementLegacyIndex = FC.Catalog.ReadLiveRequirements(recipe, UI.requirementLegacyIndex)
        end
        requirements = requirements or recipe.constraints and recipe.constraints.requirements
    end
    local warning = FC.MissingCraftRequirement(requirements)
    local previous = UI.craftRequirement
    if warning == previous then return end
    UI.craftRequirement = warning
    if previous and UI.message == previous then UI.message = nil end
    paintStatus()
    if refreshRestock then FC:Emit("CRAFT_REQUIREMENT_CHANGED") end
end

local function trackCraftRequirement(recipe)
    local requirements = recipe and recipe.constraints and recipe.constraints.requirements
    if not (requirements and #requirements > 0 and UI.window:IsVisible() and isOpenProfession(recipe)) then recipe = nil end
    if UI.requirementRecipe ~= recipe then
        UI.requirementRecipe, UI.requirementLegacyIndex = recipe, nil
    end
    if not recipe and UI.requirementTicker then
        UI.requirementTicker:Cancel()
        UI.requirementTicker = nil
    elseif recipe and not UI.requirementTicker and FC.Catalog.ReadLiveRequirements and C_Timer and C_Timer.NewTicker then
        UI.requirementTicker = C_Timer.NewTicker(0.75, function() checkCraftRequirement(true) end)
    end
    checkCraftRequirement(false)
end

local function nativeSelectedRecipeID()
    local form = UI.forever.CraftingPage.SchematicForm
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    local id = info and info.recipeID
    if type(id) == "number" and not (issecretvalue and issecretvalue(id)) then return id end
end

local function isNativeRecipeSelected(recipe)
    if not UI.forever then return true end
    local id = nativeSelectedRecipeID()
    return id ~= nil and id == recipe.recipeID and isOpenProfession(recipe)
end

local function nativeRecipeInfo(node)
    local data = node and node:GetData()
    local info = data and data.recipeInfo
    if not info or not info.learned or info.isRecraft then return end
    local resolved = Professions and Professions.GetHighestLearnedRecipe and Professions.GetHighestLearnedRecipe(info)
    return info, (resolved or info).recipeID
end

local function selectNativeRecipe(recipe)
    if not UI.forever or not isOpenProfession(recipe) or nativeSelectedRecipeID() == recipe.recipeID then return end
    if FC.Execution.IsBusy and FC.Execution.IsBusy() then
        UI.pendingNativeRecipeID = recipe.recipeID
        return
    end
    local page = UI.forever.CraftingPage
    local scrollBox = page.RecipeList.ScrollBox
    if not scrollBox or not scrollBox.FindElementDataByPredicate or not page.SelectRecipe then return end
    local node = scrollBox:FindElementDataByPredicate(function(entry)
        local _, id = nativeRecipeInfo(entry)
        return id == recipe.recipeID
    end)
    if node then page:SelectRecipe(node:GetData().recipeInfo) end
end

local selectRecipe

local function selectNativeRecommendation(page, recipe)
    if not UI.window:IsVisible() or not isOpenProfession(recipe) then return end
    if UI.dispatching then return end
    if FC.Execution.IsBusy and FC.Execution.IsBusy() then
        selectRecipe(recipe.id, true)
        return
    end
    local list = page.RecipeList
    local scrollBox = list.ScrollBox
    if not scrollBox or not scrollBox.GetDataProvider or not scrollBox.ScrollToElementData
        or not page.OnRecipeSelected or not TreeDataProviderConstants then return end
    local tree = scrollBox:GetDataProvider()
    if not tree or not tree.FindElementDataByPredicate then return end
    local node = tree:FindElementDataByPredicate(function(entry)
        local _, id = nativeRecipeInfo(entry)
        return id == recipe.recipeID
    end, TreeDataProviderConstants.IncludeCollapsed)
    if not node then return end
    -- The tree view expands this row's ancestors before scrolling to it.
    scrollBox:ScrollToElementData(node)
    page:OnRecipeSelected(node:GetData().recipeInfo, list)
end

local function cancelCooldownWake()
    local wake = UI.cooldownWake
    if not wake then return end
    UI.cooldownWake = nil
    wake.timer:Cancel()
end

local function serverTime()
    return GetServerTime and GetServerTime() or type(time) == "function" and time() or nil
end

local function recipeCooling(recipe)
    local constraints = recipe and recipe.constraints or {}
    local blockedUntil, now = constraints.cooldownUntil, serverTime()
    local expires = blockedUntil or constraints.cooldownRechargeAt
    local cooling = type(blockedUntil) == "number" and (not now or blockedUntil > now)
    if type(expires) == "number" and now and expires > now and C_Timer and C_Timer.NewTimer then
        local wake = UI.cooldownWake
        if not wake or wake.recipeID ~= recipe.id or wake.expires ~= expires then
            cancelCooldownWake()
            local window = UI.window
            wake = {recipeID = recipe.id, expires = expires}
            UI.cooldownWake = wake
            wake.timer = C_Timer.NewTimer(expires - now + 0.5, function()
                if UI.cooldownWake ~= wake then return end
                UI.cooldownWake = nil
                if UI.window ~= window or not window:IsVisible() or UI.selectedRecipeId ~= wake.recipeID then return end
                local current = serverTime()
                if current and current >= wake.expires then
                    FC.Catalog.Refresh()
                    FC.Queue.InvalidateRecipes(FC.Catalog.Snapshot())
                end
                UI.Refresh()
            end)
        end
    else
        cancelCooldownWake()
    end
    return cooling or constraints.cooldownCharges == 0 or constraints.maxExecutions == 0
end

local function stopCooldownTicker()
    if not UI.cooldownTicker then return end
    UI.cooldownTicker:Cancel()
    UI.cooldownTicker = nil
end

local function updatePlanCooldown(recipe)
    local constraints = recipe and recipe.constraints or {}
    local now = serverTime()
    local expires = constraints.cooldownUntil or constraints.cooldownRechargeAt
    local remaining = expires and now and math.max(0, math.ceil(expires - now)) or 0
    local duration
    if remaining >= 86400 then
        duration = L.planCooldownDays:format(math.floor(remaining / 86400), math.floor(remaining / 3600) % 24)
    elseif remaining >= 3600 then
        duration = L.planCooldownHours:format(math.floor(remaining / 3600), math.floor(remaining / 60) % 60)
    elseif remaining > 0 then
        duration = ("%d:%02d"):format(math.floor(remaining / 60), remaining % 60)
    end
    local text, blocked = "", constraints.cooldownCharges == 0 or constraints.maxExecutions == 0
        or constraints.cooldownUntil and (not now or remaining > 0)
    if constraints.cooldownUntil and duration then
        text = L.planCooldownTime:format(duration)
    elseif blocked then
        text = L.planCooldownPending
    elseif constraints.maxCooldownCharges and constraints.cooldownCharges then
        text = L.planCharges:format(constraints.cooldownCharges, constraints.maxCooldownCharges)
        if duration then text = L.planRecharge:format(text, duration) end
    end
    if UI.planCooldown:GetText() ~= text then
        UI.planCooldown:SetText(text)
        UI.planCooldown:SetTextColor(1, blocked and 0.35 or 0.82, blocked and 0.28 or 0.15)
    end
    UI.planCooldown:SetShown(text ~= "")
    UI.planCost:SetPoint("TOPRIGHT", text ~= "" and -139 or 0, 0)
    if remaining > 0 and UI.plan:IsVisible() and C_Timer and C_Timer.NewTicker then
        if not UI.cooldownTicker then
            UI.cooldownTicker = C_Timer.NewTicker(1, function()
                if UI.plan:IsVisible() then updatePlanCooldown(selectedRecipe()) else stopCooldownTicker() end
            end)
        end
    else
        stopCooldownTicker()
    end
end

local function viewFor(id)
    local views = UI.saved.graphs
    local key = tostring(id)
    views[key] = views[key] or {position = {}, collapsed = {}}
    return views[key]
end

local function activeQueueJob(job)
    return job and job.status ~= "complete" and job.status ~= "cancelled" and job.status ~= "replaced"
        and not FC.Queue.IsClearing(job)
end

local function currentTree()
    if UI.job then return UI.job.tree end
    return UI.preview and UI.preview.tree
end

local function taskFits(node, task)
    if node.taskId == task.taskId then return true end
    for _, craft in ipairs(node.crafts or {}) do
        if craft.taskId == task.taskId then return true end
    end
end

local function graphTask(node)
    if not UI.job or not node then return end
    for _, task in ipairs(UI.job.tasks) do
        if taskFits(node, task) and FC.Queue.CanProcess(UI.job, task) then return task end
    end
end

local function graphOutputRecipe(recipe, job)
    if not job then return recipe end
    if not job.rootRecipeId then return end
    for _, task in ipairs(job.tasks) do
        if task.recipeId == job.rootRecipeId and task.outputItemID == job.rootItemID then return task end
    end
end

local updateRecipeAuctionator

local function canAcceptPreview()
    if UI.auctionPriceScan or UI.pendingDraft then return false end
    local plan = not UI.job and UI.preview
    return plan and (#(plan.tasks or {}) + #(plan.requirements or {}) + #(plan.allocations or {})) > 0
        and (plan.status == "ready" or plan.status == "sourcing") or false
end

local function inspect()
    local root = currentTree()
    UI.saved.queueJobId = activeQueueJob(UI.job) and UI.job.id or false
    local view = viewFor(UI.job and ("job-" .. UI.job.id) or UI.selectedRecipeId or "")
    local nextID, requirementRecipe
    if UI.job then
        local job, task = FC.Queue.NextTask(UI.professionID, UI.job)
        if job == UI.job then
            nextID = task.taskId
            requirementRecipe = FC.Catalog.Get(task.recipeId)
        end
        if UI.step and UI.step.status == "pending" then requirementRecipe = FC.Catalog.Get(UI.step.recipeId) end
    elseif UI.preview and UI.preview.status ~= "blocked" then
        for _, task in ipairs(UI.preview.tasks or {}) do
            if #(task.dependencies or {}) == 0 and not next(task.sourcingRequirements or {}) then
                nextID = task.taskId
                break
            end
        end
    end
    local context = not UI.job and UI.context
    updateRecipeAuctionator()
    local recipe = selectedRecipe()
    if not UI.job then requirementRecipe = recipe end
    trackCraftRequirement(requirementRecipe)
    local outputRecipe = graphOutputRecipe(recipe, UI.job)
    updateRecipeSkill(recipe)
    local summary = UI.job and UI.job.summary or UI.preview and UI.preview.summary
    local covered = root and root.source == "Covered"
    local outputAmount = FC.Graph.OutputAmount(outputRecipe, summary)
    if outputAmount and UI.job and UI.job.status == "complete" then
        outputAmount = "0"
    elseif outputAmount and activeQueueJob(UI.job) then
        local recovery = UI.carriedRecoveryJob == UI.job and UI.carriedRecovery
        local produced = outputRecipe and FC.Queue.VisibleCompletedExecutions(outputRecipe) > 0
        if recovery or produced then
            local remaining = FC.Queue.VisibleOutstandingOutput(UI.job) - (recovery and recovery.quantity or 0)
            outputAmount = tostring(math.max(0, remaining))
        end
    end
    local cost = summary and totalAndUnit(summary.valueKnown ~= false and summary.fullValue or nil,
        FC.Pricing.OutputUnitCost(summary))
    local sale = context and context.projection or UI.job and FC.Pricing.AcceptedJobProjection(UI.job)
    local saleQuantity = sale and sale.saleAssumptions and sale.saleAssumptions.quantity
    local prices
    if outputAmount then
        local price = totalAndUnit(sale and sale.estimatedGrossSaleProceeds, sale and sale.estimatedGrossSaleUnitPrice)
        prices = {cost = L.outputCost:format(cost), auction = saleQuantity and saleQuantity ~= summary.output
            and L.outputAuctionQuantity:format(saleQuantity, price) or L.outputAuction:format(price)}
    end
    local path = UI.nodePath or root and tostring(root.itemID)
    local node = UI.graph:Render(root, view.position, view.collapsed, path, nextID, UI.job, outputAmount, prices)
    UI.nodePath = node and node.path
    UI.emptyPlan:SetShown(root == nil)
    UI.emptyPlan:SetText(not UI.job and UI.pendingDraft and L.calculatingPlan or UI.message or L.pickRecipe)
    local cooling = recipeCooling(recipe)
    local canCraft = recipe and recipe.learned == true and recipe.completeness == "complete"
        and isNativeRecipeSelected(recipe) and not cooling and not (FC.Execution.IsBusy and FC.Execution.IsBusy())
    UI.craftOne:SetEnabled(not not (canCraft and FC.Execution.CreateSelected))
    UI.craftAll:SetEnabled(not not (canCraft and FC.Execution.CraftSelected))
    UI.queueAll:SetEnabled(not not (canCraft and FC.Execution.QueueAllSelected))
    UI.queuePlan:SetEnabled(canAcceptPreview())
    local demandId = UI.job and UI.job.goal and UI.job.goal.demandId or UI.demandId
    local demand = FC.Logistics.GetDemand(demandId)
    UI.planSummary = summary and L.plannedActions:format(summary.requested or 0, summary.executions or 0,
        summary.output or 0, summary.surplus or 0) or (recipe and recipe.blocker or "")
    if demand then UI.planSummary = L.restockSummary:format(demand.ready, demand.target, demand.covered, demand.uncovered) end
    if summary and outputRecipe and type(outputRecipe.yield) == "number" and type(outputRecipe.yieldMax) == "number"
        and outputRecipe.yieldMax > outputRecipe.yield then
        UI.planSummary = UI.planSummary .. "\n" .. L.variableYieldPlan
    end
    local profit = sale and sale.estimatedProfit
    local profitText = profit and FC.Pricing.FormatProfit(profit)
    local percent = sale and FC.Pricing.FormatProfitPercent(sale.profitOnCostPercent)
    local percentText = percent and L.planProfitRate:format(percent) or ""
    local netSale = sale and sale.estimatedNetSaleProceeds
    UI.planCostDetail = summary and L.planCost:format(cost, amount(summary.additionalCash))
    UI.planObjective = summary and summary.objective
    UI.planPrice, UI.planPriceUnknown = itemPriceEvidence(context, root and root.itemID)
    if UI.job then UI.planPrice = sale and sale.saleAssumptions end
    UI.planProfitDetail = profitText and L.planProfitNet:format(profitText, percentText)
    UI.planSaleDetail = netSale and (saleQuantity and L.planSaleQuantity:format(saleQuantity, amount(netSale))
        or L.planSale:format(amount(netSale)))
    UI.planSurplusDetail = saleQuantity and summary and summary.output > saleQuantity
        and L.planSurplusValue:format(summary.output - saleQuantity)
    UI.planCost:SetText(covered and L.alreadyCovered or cost and L.planToCraft:format(cost) or "")
    UI.planProfit:SetText(not covered and summary and L.planProfitCompact:format(profitText or L.unknown, percentText) or "")
    updatePlanCooldown(recipe)
end

local function enteredQuantity()
    local count = tonumber(UI.quantity:GetText())
    return count and count == math.floor(count) and count >= 1 and count <= 9999 and count or nil
end

local function buildArgs()
    local count = enteredQuantity()
    if not count then return nil, L.quantityError end
    local recipe = selectedRecipe()
    if not recipe then return nil, L.pickRecipe end
    local intent = UI.saved.intent
    UI.saved.quantity = count
    if UI.saved.quantityMode == "Crafts" then
        if not recipe.yield or recipe.yield < 1 then return nil, L.yieldUnknown end
        count, intent = count * recipe.yield, "additional"
    end
    return {recipeId = intent ~= "delivery" and recipe.id or nil, itemID = recipe.outputItemID,
        quantity = count, intent = intent, replaces = UI.replaces, inspectUnavailable = true,
        deferRecipeRequirements = true,
        choices = UI.saved.choices[tostring(recipe.id)]}
end

local function preview(sliced, onComplete)
    local id = UI.selectedRecipeId
    local function showPreview(plan, context)
        UI.preview, UI.context, UI.previewRecipeId = plan, plan and context or nil, plan and id or nil
        if not plan then notify(context); return end
        local summary = plan.summary or {}
        if plan.blocker then notify(plan.blocker)
        elseif #(plan.tasks or {}) + #(plan.requirements or {}) + #(plan.allocations or {}) == 0 then notify(L.covered)
        elseif plan.craftRequirement then notify()
        elseif plan.status == "sourcing" then notify(L.sourcing)
        elseif summary.searchBounded or (plan.diagnostics and plan.diagnostics.bounded) then notify(L.bounded)
        elseif summary.optimality and summary.optimality ~= "exact" then notify(L.incompletePrices)
        else notify(L.ready) end
    end
    local args, reason = buildArgs()
    if not args then showPreview(nil, reason); return end
    local displayed = UI.preview and UI.preview.goal
    if not (sliced and id == UI.previewRecipeId and displayed and displayed.quantity == args.quantity
        and displayed.intent == args.intent) then
        UI.preview, UI.context, UI.previewRecipeId = nil, nil, nil
    end
    args.browse = true
    if not (sliced and C_Timer and C_Timer.After and coroutine) then
        showPreview(FC.Logistics.Preview(args, UI.catalog))
        return
    end
    args.pauseSearch = coroutine.yield
    local catalog = UI.catalog
    local draft = {id = id, worker = coroutine.create(function() return FC.Logistics.Preview(args, catalog) end)}
    UI.pendingDraft = draft
    local deferred
    local function advance()
        if UI.pendingDraft ~= draft then return end
        if UI.job or UI.selectedRecipeId ~= id or not UI.window:IsVisible() then
            UI.pendingDraft, UI.recipeSelectionPending = nil, nil
            paintStatus()
            return
        end
        local ok, plan, context = coroutine.resume(draft.worker)
        local failure
        if not ok then
            args.pauseSearch = nil
            ok, plan, context = pcall(FC.Logistics.Preview, args, FC.Catalog.Snapshot())
            if not ok then failure, plan, context = plan, nil, L.previewFailed end
        end
        -- Catalog or inventory callbacks can have scheduled work during a native observation.
        if UI.pendingDraft ~= draft then return end
        if coroutine.status(draft.worker) == "dead" then
            UI.pendingDraft, UI.recipeSelectionPending = nil, nil
            showPreview(plan, context)
            if deferred then onComplete() end
            if draft.refresh and UI.selectedRecipeId == id and not UI.job then UI.Schedule() end
            if failure and geterrorhandler then geterrorhandler()(failure) end
        else
            if not deferred then paintStatus() end
            deferred, UI.recipeSelectionPending = true, true
            C_Timer.After(0, advance)
        end
    end
    advance()
end

local function clearDraft()
    UI.job, UI.requirement, UI.step = nil, nil, nil
    UI.demandId = nil
    UI.preview, UI.context, UI.previewRecipeId, UI.pendingDraft = nil, nil, nil, nil
end

local function scheduleRecipePreview()
    UI.saved.queueJobId = false
    UI.recipeSelectionPending = true
    UI.Schedule(nil, true)
end

local function changePreview(defer)
    clearDraft()
    if defer == true then UI.Schedule() else UI.Refresh() end
end

local function draftRemaining(job)
    local editable, reason = FC.Queue.CanReplace(job)
    if not editable then notify(reason and L[reason] or L.offerChanged); return false end
    UI.replaces, UI.selectedRecipeId = job, job.rootRecipeId
    UI.saved.intent, UI.saved.quantityMode = "additional", "Items"
    UI.quantityType:SetText(L.itemCount)
    UI.quantity:SetText(tostring(math.max(1, FC.Queue.OutstandingOutput(job, true))))
    changePreview()
    notify(L.reviseHint)
    return true
end

selectRecipe = function(id, remember)
    if not id then return end
    if UI.menu then UI.menu:Hide() end
    if remember and UI.selectedRecipeId ~= id then UI.history[#UI.history + 1] = UI.selectedRecipeId end
    UI.selectedRecipeId, UI.nodePath, UI.pendingNativeRecipeID = id, nil, nil
    UI.replaces = nil
    local recipe = selectedRecipe()
    if recipe and tostring(recipe.professionId) == tostring(UI.professionID) then preferences().recipeId = id end
    -- Native SelectRecipe can synchronously echo this selection.
    clearDraft()
    selectNativeRecipe(recipe)
    scheduleRecipePreview()
end

local function listScroll(delta)
    local pref = preferences()
    pref.scroll = math.max(0, (pref.scroll or 0) + delta)
    UI.RenderRecipes()
end

local showRecipeMenu
local CLASSIC_RECIPE_HEIGHT, CLASSIC_RECIPE_TOP = 19, 79

local function priceClassicRows(visible)
    local profit, catalog = FC.RecipeProfit, UI.catalog
    if not profit or not catalog or not UI.window:IsVisible() then return end
    local settings = preferences()
    if settings.filter == "best" or settings.filter == "sell" or settings.filter == "fromBags"
        or settings.sort == "cost" then return end
    local status = FC.InventoryAdapter.GetStatus()
    if not status.reliable then return end
    local key = profit.Revision(catalog, status)
    local prices = UI.classicProfit
    if not prices or prices.key ~= key then
        prices = {key = key, entries = {}, previous = prices and prices.entries}
        UI.classicProfit = prices
    end
    if prices.pending then return end
    for index = 1, visible do
        local row = UI.recipeRows[index]
        local recipe = row.record and row.record.recipe
        if recipe and not prices.entries[recipe.id] then
            prices.pending = true
            C_Timer.After(0, function()
                prices.pending = nil
                if UI.classicProfit ~= prices or not UI.window:IsVisible() then return end
                if row:IsShown() and row.record and row.record.recipe == recipe and UI.catalog == catalog then
                    prices.entries[recipe.id] = profit.Quote(recipe, catalog)
                end
                UI.RenderRecipes()
            end)
            return
        end
    end
end

function UI.RenderRecipes()
    local pref = preferences()
    local rows = UI.list or {}
    local visible = math.max(1, math.min(48,
        math.floor((UI.listPane:GetHeight() - CLASSIC_RECIPE_TOP - 17) / CLASSIC_RECIPE_HEIGHT)))
    pref.scroll = math.max(0, math.min(pref.scroll or 0, #rows - visible))
    for index = 1, visible do
        local row = UI.recipeRows[index]
        if not row then
            row = CreateFrame("Button", nil, UI.listPane)
            row:SetHeight(CLASSIC_RECIPE_HEIGHT)
            row:SetScript("OnClick", function(self, mouse)
                if not self.record then return end
                local recipe = self.record.recipe
                if mouse == "RightButton" then
                    showRecipeMenu(self, recipe.id)
                elseif IsShiftKeyDown and IsShiftKeyDown() and recipe.outputLink and ChatEdit_InsertLink then
                    ChatEdit_InsertLink(recipe.outputLink)
                else
                    selectRecipe(recipe.id, true)
                end
            end)
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:EnableMouseWheel(true)
            row:SetScript("OnMouseWheel", function(_, delta) listScroll(-delta) end)
            row:SetScript("OnEnter", function(self)
                if self.record then
                    local recipe = self.record.recipe
                    tooltip(self, recipe.outputItemID, recipe.outputLink, nil,
                        UI.saved.recipeMeta[tostring(recipe.id)] or {})
                end
            end)
            row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
            local y = -CLASSIC_RECIPE_TOP - (index - 1) * CLASSIC_RECIPE_HEIGHT
            row:SetPoint("TOPLEFT", 4, y)
            row:SetPoint("TOPRIGHT", UI.listPane, "TOPRIGHT", -4, y)
            row.selection = row:CreateTexture(nil, "BACKGROUND")
            row.selection:SetAllPoints()
            row.selection:SetColorTexture(0.57, 0.41, 0.18, 0.38)
            local highlight = row:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints()
            highlight:SetColorTexture(0.65, 0.50, 0.25, 0.18)
            row.caption = label(row, nil, "GameFontHighlightSmall")
            row.caption:SetPoint("LEFT", 6, 0)
            row.caption:SetWordWrap(false)
            row.value = label(row, nil, "GameFontHighlightSmall")
            row.value:SetPoint("RIGHT", -5, 0)
            row.value:SetJustifyH("RIGHT")
            row.value:SetWordWrap(false)
            UI.recipeRows[index] = row
        end
        local record = rows[index + pref.scroll]
        row.record = record
        if record then
            local name = record.favorite and "★ " .. record.name or record.name
            local value
            if record.money then
                local profit = pref.filter == "sell" or pref.filter == "best" and pref.sort ~= "cost"
                value = profit and FC.Pricing.FormatProfit(record.money) or amount(record.money)
            elseif record.badge then value = record.badge
            elseif UI.classicProfit then
                local prices, id = UI.classicProfit, record.recipe.id
                local quote = prices.entries[id] or prices.previous and prices.previous[id]
                value = quote and quote.text
            end
            row.selection:SetShown(record.recipe.id == UI.selectedRecipeId)
            row.caption:SetPoint("RIGHT", value and -106 or -5, 0)
            row.caption:SetText(name)
            row.value:SetText(value or "")
            row:Show()
        else row:Hide() end
    end
    for i = visible + 1, #UI.recipeRows do UI.recipeRows[i]:Hide() end
    UI.recipeEarlier:SetShown(#rows > visible)
    UI.recipeLater:SetShown(#rows > visible)
    UI.recipeEarlier:SetEnabled(pref.scroll > 0)
    UI.recipeLater:SetEnabled(pref.scroll + visible < #rows)
    local menu = UI.menu
    if menu:IsShown() and menu.recipeId then
        local row = menu.owner
        if not row:IsShown() or not row.record or row.record.recipe.id ~= menu.recipeId then menu:Hide() end
    end
    UI.filter:SetText(L[pref.filter] or L.all)
    UI.sort:SetText(pref.sort == "difficulty" and L.sortDifficulty or pref.sort == "cost" and L.sortCost
        or pref.filter == "best" and L.sortProfit or L.sortName)
    UI.groups:SetText(pref.group or L.allGroups)
    if not UI.search:HasFocus() and UI.search:GetText() ~= (pref.search or "") then UI.search:SetText(pref.search or "") end
    priceClassicRows(visible)
end

local function showRecipeRows(rows, pref, preserveScroll)
    local anchor = preserveScroll and UI.list and UI.list[(pref.scroll or 0) + 1]
    if anchor then
        for index, row in ipairs(rows) do
            if row.recipe.id == anchor.recipe.id then
                pref.scroll = index - 1
                break
            end
        end
    end
    UI.list = rows
end

local function refreshList()
    local pref = preferences()
    local settings = FC.Logistics.GetSettings()
    local market = settings.market or {}
    local filter, sort, catalog = pref.filter, pref.sort, UI.catalog
    local needsPlans = filter == "fromBags" or filter == "best" or filter == "sell" or sort == "cost"
    local viewKey = table.concat({tostring(UI.professionID), pref.search or "",
        filter or "", pref.group or "", sort or ""}, "\030")
    local key = table.concat({viewKey, tostring(catalog.revision), UI.metaRevision or 0,
        needsPlans and FC.InventoryAdapter.GetRevision() or "",
        needsPlans and FC.Queue.GetRevision() or "", UI.marketRevision or 0,
        settings.provider or "", tostring(settings.allowFallback == true), settings.objective or "", market.rate or ""}, "\030")
    if key == UI.listRevision then return end
    local preserveScroll = UI.listViewKey == viewKey
    UI.listRevision, UI.listViewKey = key, viewKey
    local list, groups = FC.RecipeList.Select(catalog, UI.professionID, pref, UI.saved.recipeMeta, recipeName)
    UI.groupNames = groups
    if needsPlans and preserveScroll and UI.list then
        -- Keep the settled order and badges visible until the new ranking is ready.
        local byID, retained = {}, {}
        for _, row in ipairs(list) do byID[row.recipe.id] = row end
        for _, old in ipairs(UI.list) do
            local fresh = byID[old.recipe.id]
            if fresh then
                retained[#retained + 1] = {recipe = fresh.recipe, name = fresh.name, favorite = fresh.favorite,
                    badge = old.badge, money = old.money}
                byID[old.recipe.id] = nil
            end
        end
        for _, row in ipairs(list) do
            if byID[row.recipe.id] then
                retained[#retained + 1] = {recipe = row.recipe, name = row.name, favorite = row.favorite}
            end
        end
        showRecipeRows(retained, pref, true)
    else
        showRecipeRows(list, pref, preserveScroll)
    end
    UI.listProgress:SetText("")
    if needsPlans then
        local index = 1
        local function batch()
            if UI.listRevision ~= key or not UI.window:IsVisible() then
                if UI.listRevision == key then UI.listRevision = nil end
                return
            end
            if list[index] then FC.RecipeList.Evaluate(list[index], filter, sort, catalog) end
            index = index + 1
            if index <= #list then
                UI.listProgress:SetText(L.measuring:format(index - 1, #list))
                if C_Timer and C_Timer.After then C_Timer.After(0.02, batch) end
            else
                UI.listProgress:SetText("")
                FC.RecipeList.Rank(list)
                showRecipeRows(list, pref, preserveScroll)
                UI.RenderRecipes()
            end
        end
        batch()
    end
end

local function queueScroll(delta)
    UI.queueOffset = math.max(0, UI.queueOffset + delta)
    UI.RenderQueue()
end

local function activeAuctionHouse()
    local modern, legacy = _G.AuctionHouseFrame, _G.AuctionFrame
    if modern and modern:IsVisible() then return modern end
    if legacy and legacy:IsVisible() then return legacy end
end

local function auctionEntry(entry, checkVendor)
    return entry and (entry.kind == "auction" or entry.kind == "buy"
        or checkVendor and entry.kind == "vendor" and activeAuctionHouse() and FC.Logistics.IsAuctionShoppingEntry(entry))
end

local function canBuyAuction(entry, need)
    return entry and entry.job and not entry.searchOnly and not entry.job.acquisition
        and not entry.requirement.auctionNeedsReplan and need and need.mailUsable
        and type(need.toBuy) == "number" and need.toBuy > 0
        and not need.lotBlocked and type(need.maxUnitPrice) == "number" and need.maxUnitPrice > 0
        and type(need.maxTotalPrice) == "number" and need.maxTotalPrice > 0
end

local function auctionOfferRevision(entry, need)
    if need.groupRevision then return need.groupRevision end
    return table.concat({entry.job.id, entry.id, entry.job.planRevision, need.toBuy,
        need.maxUnitPrice, need.maxTotalPrice, need.minQuantity or 0, need.stackSize or 0,
        need.stackMaxTotalPrice or 0, need.livePrice and 1 or 0}, ":")
end

local function recordAuctionFailure(selection, entry, need, reason)
    if not selection or not canBuyAuction(entry, need) or reason ~= "noOffer" and reason ~= "overCap" then return end
    if need.groupRevision then
        if selection.failedGroups[entry.itemID] == need.groupRevision then return end
        selection.failedGroups[entry.itemID] = need.groupRevision
        return true
    end
    selection.failedOffers = selection.failedOffers or {}
    local revision = auctionOfferRevision(entry, need)
    if selection.failedOffers[entry.requirement] == revision then return end
    selection.failedOffers[entry.requirement] = revision
    return true
end

local function queueAuctionEntries(preferred, compareVendors)
    local entries, needs = FC.Logistics.GetAuctionShoppingEntries(preferred, compareVendors)
    for _, entry in ipairs(entries) do
        local kind = entry.requirement.kind
        entry.searchOnly = (kind ~= "auction" and kind ~= "vendor") or entry.job.status ~= "queued"
    end
    return entries, needs
end

local function draftAuctionEntries(compareVendors)
    local entries = {}
    local plan = not UI.job and UI.preview
    if not plan or not UI.window or not UI.window:IsVisible() then return entries end
    for index, requirement in ipairs(plan.requirements or {}) do
        if requirement.kind == "auction" or requirement.kind == "buy" or requirement.kind == "manual"
            or compareVendors and requirement.kind == "vendor" then
            entries[#entries + 1] = {itemID = requirement.itemID, quantity = requirement.quantity,
                requirement = requirement, searchOnly = true, preview = plan, id = index}
        end
    end
    return entries
end

local function shoppingEntries(previewOnly, preferred, compareVendors)
    if previewOnly then return draftAuctionEntries(compareVendors) end
    local entries, needs = queueAuctionEntries(preferred, compareVendors)
    if #entries > 0 then return entries, needs end
    for _, job in ipairs(FC.Queue.GetJobs()) do
        if job.status == "queued" or job.status == "paused" or job.status == "running" or job.status == "uncertain" then
            return entries
        end
    end
    return draftAuctionEntries(compareVendors)
end

local function draftHasPurchaseLimit(entry)
    if not entry or not entry.preview or entry.requirement.kind ~= "auction" then return false end
    local unit, total = entry.requirement.maxUnitPrice, entry.requirement.maxTotalPrice
    return type(unit) == "number" and unit >= 1 and unit < math.huge
        and type(total) == "number" and total >= 1 and total < math.huge
end

local function groupAuctionEntries(entries, failures, preferred, needs, failedGroups)
    local groups, byItem = {}, {}
    needs = needs or FC.Logistics.GetAuctionNeeds(entries)
    for _, entry in ipairs(entries) do
        local itemID = entry.itemID
        local group = byItem[itemID]
        if not group then
            group = {itemID = itemID, entry = entry, quantity = 0, incoming = 0, budget = 0, members = {}}
            groups[#groups + 1], byItem[itemID] = group, group
        end
        group.members[#group.members + 1] = entry
        local need = needs[entry]
        local quantity = FC.Logistics.GetAuctionSearchQuantity(entry, need)
        local eligible = canBuyAuction(entry, need)
        local failed = eligible and failures[entry.requirement] == auctionOfferRevision(entry, need)
        local acquisition = entry.job and entry.job.acquisition
        if acquisition and acquisition.kind == "auction" and acquisition.status == "issued"
            and acquisition.index == entry.id then group.pending = entry end
        -- A paid requirement can stay in the list while its delivery is pending.
        -- Keep failed selections as a fallback so another job can quote the same item.
        if preferred and entry.job == preferred.job and entry.id == preferred.id and quantity > 0 then
            if failed then group.failedPreferred = entry else group.preferred = entry end
        end
        if draftHasPurchaseLimit(entry) and quantity > 0 then
            group.draft = group.draft or entry
        end
        if eligible then
            group.eligible = group.eligible or entry
            if not failed then group.actionable = group.actionable or entry end
        elseif not entry.searchOnly and group.entry.searchOnly then
            group.entry = entry
        end
        local incoming = need and need.pendingIncoming or entry.requirement.auctionAwaiting or 0
        group.incoming = group.incoming + incoming
        group.quantity = group.quantity + quantity
        if quantity > 0 and group.budget then
            local total = need and need.maxTotalPrice or entry.requirement.maxTotalPrice
            local unit = need and need.maxUnitPrice or entry.requirement.maxUnitPrice
            if need and need.livePrice then
                group.budget = nil
            elseif type(total) == "number" and total >= 0 and type(unit) == "number" and unit > 0 then
                group.budget = group.budget + math.min(math.floor(total), math.floor(unit) * quantity)
            else group.budget = nil end
        end
    end
    local visible = {}
    for _, group in ipairs(groups) do
        if group.quantity > 0 or group.incoming > 0 or group.pending then
            group.entry = group.pending or group.preferred or group.actionable or group.failedPreferred
                or group.eligible or group.draft or group.entry
            group.need = needs[group.entry]
            group.offerFailed = group.eligible ~= nil and group.actionable == nil
            if failedGroups and not group.pending and #group.members > 1 and FC.Logistics.GetGroupedAuctionNeed then
                local need = FC.Logistics.GetGroupedAuctionNeed(group.members, needs)
                if need and need.groupRevision ~= failedGroups[group.itemID] then
                    group.entry, group.need, group.actionable = need.entry, need, need.entry
                    group.grouped, group.offerFailed = true, false
                end
            end
            visible[#visible + 1] = group
        end
    end
    return visible
end

local function currentShoppingNeed(group)
    local entry = group and group.entry
    if not entry or entry.searchOnly then return end
    if group.grouped then return FC.Logistics.GetGroupedAuctionNeed(group.members) end
    return FC.Logistics.GetAuctionNeed(entry)
end

local function shoppingPriceItems(pane)
    local entries, needs = shoppingEntries(pane.previewOnly, pane.preferred, true)
    local items, byItem = {}, {}
    needs = needs or FC.Logistics.GetAuctionNeeds(entries)
    for _, entry in ipairs(entries) do
        local quantity = FC.Logistics.GetAuctionSearchQuantity(entry, needs[entry])
        if quantity > 0 then
            local item = byItem[entry.itemID]
            if item then item.quantity = item.quantity + quantity
            else
                item = {itemID = entry.itemID, quantity = quantity}
                byItem[entry.itemID] = item
                items[#items + 1] = item
            end
        end
    end
    return items
end

local function auctionWaiting(need)
    local phase = need and need.phase
    return phase == "searching" or phase == "classifying" or phase == "quoting" or phase == "buying"
end

local function auctionatorListAvailable()
    local adapter = FC.AuctionatorAdapter
    return adapter and adapter.CanSearchList and adapter.CanSearchList()
end

local function auctionatorSearchRunning()
    local shopping = _G.AuctionatorShoppingFrame
    return shopping and shopping.IsVisible and shopping:IsVisible() and shopping.searchRunning == true
end

local function shoppingStatus(group, entry, need, auctionOpen)
    if not group then return "" end
    if group.pending then return L.auctionFeedback.buying end
    if group.quantity == 0 then return L.shoppingCollectMail end
    if not auctionOpen then return L.shoppingOpenAuction end
    if entry.searchOnly then return L.shoppingManual end
    if entry.job.acquisition and entry.job.acquisition.status == "uncertain" then return L.acquisitionUncertain end
    if entry.requirement.auctionNeedsReplan then return L.offerChanged end
    if not need or not need.mailUsable then return need and need.mailBlocker or L.auctionMailboxUnknown end
    if need.toBuy == 0 and (need.pendingIncoming or 0) > 0 then return L.shoppingCollectMail end
    if need.quote then return L.auctionLiveOffer:format(need.quote.quantity, amount(need.quote.totalCopper)) end
    if need.phase and L.auctionFeedback[need.phase] then return L.auctionFeedback[need.phase] end
    if need.vendorCost and (need.reason == "noOffer" or need.reason == "overCap" or need.maxTotalPrice <= 0) then
        return L.shoppingVendorPrice:format(amount(need.vendorCost))
    end
    if need.reason and L.auctionFeedback[need.reason] then return L.auctionFeedback[need.reason] end
    if not need.maxUnitPrice or not need.maxTotalPrice then return L.auctionCapUnknown end
    if need.maxTotalPrice <= 0 then return L.auctionFeedback.overLimit end
    if not need.mailKnown then return L.auctionMailboxCached end
    return ""
end

local SHOPPING_ROW_HEIGHT = 24
local SHOPPING_ACTION_WIDTH = 79
local SHOPPING_HEADER_HEIGHT = 44
local SHOPPING_FOOTER_HEIGHT = 29
local SHOPPING_TAB_GAP = 34
local acceptPlan

local function positionShopping(pane, anchor)
    if not anchor or pane.dragged then return end
    local scale = anchor:GetEffectiveScale() / pane:GetEffectiveScale()
    local bottom = anchor.GetBottom and anchor:GetBottom() or anchor:GetTop() and anchor:GetTop() - anchor:GetHeight()
    local profession = UI.window and UI.window:IsVisible()
        or UI.forever and UI.forever:IsVisible() or UI.classicNative and UI.classicNative:IsVisible()
    local dockRows = bottom and math.floor((bottom * scale - SHOPPING_TAB_GAP - SHOPPING_HEADER_HEIGHT
        - SHOPPING_FOOTER_HEIGHT - 24) / SHOPPING_ROW_HEIGHT)
    local dock = profession and anchor == activeAuctionHouse() and dockRows and dockRows >= 2
    local width = dock and math.max(385, math.min(540, anchor:GetWidth() * scale)) or 385
    local side = dock and "below" or "right"
    if not dock then
        local screenScale = anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
        local right, left = anchor:GetRight(), anchor:GetLeft()
        if right and right * screenScale + width + 7 > UIParent:GetWidth() and left and left * screenScale >= width then
            side = "left"
        end
    end
    pane.maxRows = dock and math.min(#pane.rows, dockRows) or #pane.rows
    if pane.layoutAnchor == anchor and pane.anchorSide == side and pane:GetWidth() == width then return end
    pane.layoutAnchor, pane.anchorSide = anchor, side
    pane:SetWidth(width)
    pane:ClearAllPoints()
    if side == "below" then
        pane:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -SHOPPING_TAB_GAP)
    elseif side == "left" then
        pane:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -7, -82)
    else
        pane:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 7, -82)
    end
end

local function displayShoppingStatus(pane, text)
    local show = text and text ~= ""
    pane.status:SetText(text or "")
    pane.status:SetShown(not not show)
    local footer = SHOPPING_FOOTER_HEIGHT + (show and 16 or 0)
    pane.list:SetPoint("BOTTOMRIGHT", -7, footer)
    pane:SetHeight(SHOPPING_HEADER_HEIGHT + math.max(2, pane.rowCount or 0) * SHOPPING_ROW_HEIGHT + 6 + footer)
end

local function canQueueShopping(entry)
    return draftHasPurchaseLimit(entry) and entry.preview == UI.preview and canAcceptPreview()
end

local function shoppingBusy()
    return FC.Logistics.IsWorkflowBusy() or FC.Execution.IsBusy and FC.Execution.IsBusy()
end

local function prepareShoppingOffer(pane, group, need, key, explicit, review)
    pane.prepareKey, pane.preparing = key, true
    local ok, reason
    if need.groupRevision then ok, reason = FC.Logistics.PrepareGroupedAuction(group.members, explicit)
    else ok, reason = FC.Logistics.PrepareAuction(group.entry, need.toBuy, explicit, review) end
    pane.preparing = nil
    if not ok and (reason == "openAH" or reason == "combat" or reason == "busy" or reason == "otherSearch"
        or reason == "loading" or reason == L.workflowBusy) then pane.prepareKey = nil end
    return ok, reason
end

local function canReviewAuctionPrice(entry, need)
    return FC.Logistics.CanReviewAuctionPrice and FC.Logistics.CanReviewAuctionPrice(entry, need)
end

local function setShoppingAction(row, need, auctionOpen, canSearchList, busy, deferred)
    local auction = _G.FluxAuctionRestock
    local canSearch = canSearchList or auction and auction.PrepareLogisticsSearch
    local group = row.entry
    local label, action, offer, revision = L.shoppingFindItem
    if group then
        local entry = group.entry
        local eligible = canBuyAuction(entry, need)
        local reviewable = not group.grouped and canReviewAuctionPrice(entry, need)
        if group.pending or deferred and deferred.requirement == entry.requirement then
            label = L.pending
        elseif group.quantity <= 0 then
            label = L.reviseCollect
        elseif auction and auction.ExecuteLogistics and canQueueShopping(entry) then
            label, action = L.queuePlan, "queue"
        elseif auction and auction.ExecuteLogistics and auction.PrepareLogistics and (eligible or reviewable)
            and (need.ready or need.livePrice or not group.offerFailed or not canSearch
                or reviewable) then
            if auctionWaiting(need) then
                label = L.pending
            elseif need.ready and need.quote then
                label, action = L.shoppingBuyQuantity:format(need.quote.quantity), "buy"
                offer, revision = need.quote, auctionOfferRevision(entry, need)
            elseif (not eligible or group.offerFailed or need.livePrice) and reviewable then
                label, action = L.shoppingFindLiveOffer, "reviewQuote"
            else
                label, action = L.shoppingFindOffer, "quote"
            end
        elseif canSearch then
            action = "search"
        end
    end
    row.actionKind = auctionOpen and not busy and action or nil
    row.quotedOffer, row.quoteRevision = offer, revision
    row.livePrice = need and need.livePrice == true
    row.action:SetText(label)
    row.action:SetEnabled(row.actionKind ~= nil)
    row.action:SetShown(group ~= nil)
    if row.price then
        local maximum = group and group.quantity > 0 and group.budget
        local vendor = group and (group.offerFailed or not canBuyAuction(group.entry, need)) and need and need.vendorCost
        local live = group and group.marketPrice and group.marketPrice.totalCopper
        local showVendor = vendor and (not live or vendor <= live)
        row.price:SetText(offer and amount(offer.totalCopper) or showVendor and L.shoppingVendorCost:format(amount(vendor))
            or live and amount(live)
            or maximum and L.shoppingBudget:format(amount(maximum)) or "")
    end
end

local function updateShoppingRowActions(pane, selected, selectedNeed, auctionOpen, canSearchList)
    local busy = shoppingBusy()
    for _, row in ipairs(pane.rows) do
        local group = row.entry
        setShoppingAction(row, group == selected and selectedNeed or group and group.need,
            auctionOpen, canSearchList, busy, pane.deferredQuote)
    end
    if pane.primary then
        pane.primary.entry = selected
        setShoppingAction(pane.primary, selectedNeed or selected and selected.need,
            auctionOpen, canSearchList, busy, pane.deferredQuote)
    end
end

local function refreshShoppingPane(pane)
    if not pane or not pane:IsVisible() or pane.refreshing then return end
    pane.refreshing = true
    positionShopping(pane, pane.anchor)
    local previous = pane.entry
    if previous and pane.prepareKey then
        local need = currentShoppingNeed(pane.group)
        if canBuyAuction(previous, need) and (not need.livePrice or pane.continueOffers)
            and pane.prepareKey == auctionOfferRevision(previous, need) then
            if recordAuctionFailure(pane, previous, need, need.reason) then pane.advance = true end
        end
    end
    local candidates, needs = shoppingEntries(pane.previewOnly, pane.preferred)
    local entries = groupAuctionEntries(candidates, pane.failedOffers, pane.preferred, needs, pane.failedGroups)
    local index, nextIndex
    for i, group in ipairs(entries) do
        if group.itemID == pane.itemID then index = i end
        if group.actionable and not nextIndex then nextIndex = i end
    end
    if not index and not pane.advance then pane.detail = nil end
    if not index or pane.advance and not (entries[index].actionable or entries[index].pending) then
        index = nextIndex or index or 1
    end
    local group, previousID = entries[index], pane.itemID
    local entry = group and group.entry
    if not (group and group.pending) then pane.advance = nil end
    pane.itemID, pane.entries, pane.index, pane.entry = group and group.itemID, entries, index, entry
    pane.group = group
    local rowCount = math.min(pane.maxRows or #pane.rows, #entries)
    pane.rowCount = rowCount
    local lastOffset = math.max(0, #entries - rowCount)
    if not pane.scrolling and pane.detail and previousID ~= pane.itemID and (index <= pane.offset or index > pane.offset + rowCount) then
        pane.offset = index - 1
    end
    pane.offset = math.max(0, math.min(pane.offset, lastOffset))
    pane.prev:SetShown(lastOffset > 0)
    pane.next:SetShown(lastOffset > 0)
    pane.prev:SetEnabled(pane.offset > 0)
    pane.next:SetEnabled(pane.offset < lastOffset)
    local hasShortage, budget, listedTotal = false, 0, 0
    for _, item in ipairs(entries) do
        if item.quantity > 0 then
            hasShortage = true
            budget = budget and item.budget and budget + item.budget
            item.marketPrice = FC.Logistics.GetObservedAuctionPrice(item.itemID, item.quantity)
            local price = item.marketPrice
            listedTotal = listedTotal and price and price.complete and listedTotal + price.totalCopper or nil
        end
    end
    for i, row in ipairs(pane.rows) do
        local item = i <= rowCount and entries[i + pane.offset] or nil
        row.entry = item
        row:SetShown(item ~= nil)
        if item then
            row:SetPoint("TOPRIGHT", lastOffset > 0 and -21 or -4, -3 - (i - 1) * SHOPPING_ROW_HEIGHT)
            row.quantity:SetText(item.quantity > 0 and tostring(item.quantity) or "")
            local name, icon = itemInfo(item.itemID)
            row.icon:SetTexture(icon)
            row.name:SetText(name)
            row.name:SetPoint("RIGHT", -(SHOPPING_ACTION_WIDTH + (item.incoming > 0 and 154 or 86)), 0)
            row.incoming:SetText(item.incoming > 0 and L.shoppingIncoming:format(item.incoming) or "")
            row.selection:SetShown(not not (pane.detail and item == group))
        end
    end
    pane.empty:SetShown(group == nil)
    local auctionOpen = activeAuctionHouse()
    local need = pane.detail and currentShoppingNeed(group)
    local eligible = canBuyAuction(entry, need)
    local auction = _G.FluxAuctionRestock
    local canQueue = auctionOpen and auction and auction.ExecuteLogistics and pane.detail and group and group.quantity > 0
        and canQueueShopping(entry)
    local status = pane.detail and (canQueue and L.shoppingQueueBeforeBuy or shoppingStatus(group, entry, need, auctionOpen))
    displayShoppingStatus(pane, pane.notice or status)
    local canSearchList = auctionOpen and auctionatorListAvailable()
    updateShoppingRowActions(pane, group, need, auctionOpen, canSearchList)
    pane.budgetText:SetText(hasShortage and (listedTotal and L.shoppingListedTotal:format(amount(listedTotal))
        or budget and L.shoppingBudgetLabel:format(L.shoppingBudget:format(amount(budget)))) or "")
    pane.search:SetText(canSearchList and L.auctionatorButton or L.searchAuction)
    local compare = canSearchList and (hasShortage or #shoppingPriceItems(pane) > 0)
    pane.search:SetShown(not not (compare or auctionOpen and group and auction and auction.PrepareLogisticsSearch))
    pane.search:SetEnabled(not not (compare or not canSearchList and group and group.quantity > 0))
    pane.refreshing = nil

    if not (auctionOpen and auction and auction.PrepareLogistics and eligible) or pane.externalSearch or pane.preparing
        or pane.deferredQuote or need.livePrice and not pane.continueOffers or auctionatorSearchRunning() or shoppingBusy() then return end
    local key = auctionOfferRevision(entry, need)
    if auctionWaiting(need) then pane.prepareKey = key; return end
    if need.ready or pane.prepareKey == key or pane.failedOffers[entry.requirement] == key then return end
    local ok, reason = prepareShoppingOffer(pane, group, need, key, pane.ownerSession or pane.continueOffers)
    if not ok and recordAuctionFailure(pane, entry, need, reason) then
        pane.advance = true
        C_Timer.After(0, function() refreshShoppingPane(pane) end)
    elseif pane.entry == entry then
        local current = currentShoppingNeed(group)
        local statusText = not ok and reason and (L.auctionFeedback[reason] or reason)
            or shoppingStatus(group, entry, current, auctionOpen)
        displayShoppingStatus(pane, statusText)
        updateShoppingRowActions(pane, group, current, auctionOpen, canSearchList)
    else
        C_Timer.After(0, function() refreshShoppingPane(pane) end)
    end
end

local function resetShopping(pane)
    pane.prepareKey, pane.externalSearch, pane.advance = nil, nil, nil
    pane.deferredQuote = nil
    pane.detail, pane.notice, pane.itemID = nil, nil, nil
    pane.preferred, pane.previewOnly, pane.ownerSession, pane.continueOffers = nil, nil, nil, nil
    pane.group, pane.offset, pane.failedOffers, pane.failedGroups = nil, 0, {}, {}
end

local shoppingAnchorHooks = {}

local function showShopping(pane, anchor, itemID, previewOnly, preferred)
    local returning = not pane:IsShown() and pane.returnFromSearch == anchor and pane.previewOnly == previewOnly
    pane.returnFromSearch = nil
    if not returning and (not pane:IsShown() or pane.previewOnly ~= previewOnly) then resetShopping(pane) end
    if returning then pane.prepareKey, pane.notice = nil, nil end
    pane.previewOnly = previewOnly
    if itemID then
        pane.itemID, pane.detail, pane.notice, pane.preferred = itemID, true, nil, preferred
        pane.prepareKey, pane.externalSearch, pane.advance = nil, nil, nil
        pane.deferredQuote = nil
    end
    if pane.anchor ~= anchor then
        pane.anchor = anchor
        pane.dragged = nil
        positionShopping(pane, anchor)
        if not shoppingAnchorHooks[anchor] then
            shoppingAnchorHooks[anchor] = true
            anchor:HookScript("OnHide", function(self)
                if pane.anchor == self then pane:Hide() end
            end)
        end
    end
    pane:Show()
    refreshShoppingPane(pane)
end

local function hideShopping(pane, auctionSearch)
    if pane then
        pane.returnFromSearch = auctionSearch
        pane.deferredQuote = nil
        pane:Hide()
    end
end

local function coversAuction(pane, auction)
    local referenceScale = UIParent:GetEffectiveScale()
    local auctionScale = auction:GetEffectiveScale() / referenceScale
    if pane.dragged then
        local paneScale = pane:GetEffectiveScale() / referenceScale
        local left, right = pane:GetLeft(), pane:GetRight()
        local auctionLeft, auctionRight = auction:GetLeft(), auction:GetRight()
        if not left or not right or not auctionLeft or not auctionRight
            or left * paneScale >= auctionRight * auctionScale or right * paneScale <= auctionLeft * auctionScale then return false end
        local bottom, auctionBottom = pane.GetBottom and pane:GetBottom(), auction.GetBottom and auction:GetBottom()
        local top, auctionTop = pane:GetTop(), auction:GetTop()
        return not (bottom and auctionTop and bottom * paneScale >= auctionTop * auctionScale
            or top and auctionBottom and top * paneScale <= auctionBottom * auctionScale)
    end
    if pane.anchor == auction and pane.anchorSide == "below" then return false end
    local width = pane:GetWidth() * pane:GetEffectiveScale() / referenceScale
    if pane.anchorSide == "left" then
        local left = auction:GetLeft()
        return left and left * auctionScale < width
    end
    local right = auction:GetRight()
    return right and right * auctionScale + width > UIParent:GetWidth()
end

local function createShoppingPane()
    local name = "FluxLogisticsShoppingList"
    local pane = CreateFrame("Frame", name, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    pane.rows = {}
    resetShopping(pane)
    pane:Hide()
    pane:HookScript("OnHide", function() pane.deferredQuote = nil end)
    pane:EnableMouse(true)
    pane:SetSize(385, 128)
    pane:SetClampedToScreen(true)
    pane:SetMovable(true)
    pane:SetFrameStrata("DIALOG")
    if pane.SetBackdrop then
        pane:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 16,
            insets = {left = 4, right = 4, top = 4, bottom = 4}})
    else tint(pane, 0.09, 0.07, 0.05) end
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, name) end
    local header = CreateFrame("Frame", nil, pane)
    header:SetPoint("TOPLEFT", 5, -4)
    header:SetPoint("TOPRIGHT", -5, -4)
    header:SetHeight(24)
    tint(header, 0.21, 0.15, 0.08)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() pane:StartMoving() end)
    header:SetScript("OnDragStop", function() pane:StopMovingOrSizing(); pane.dragged = true end)
    local title = label(header, L.auctionShopping, "GameFontNormal")
    title:SetPoint("CENTER")
    label(pane, L.shoppingQty):SetPoint("TOPLEFT", 30, -30)
    label(pane, L.shoppingMaterial):SetPoint("TOPLEFT", 63, -30)
    label(pane, L.shoppingCost):SetPoint("TOPRIGHT", -(SHOPPING_ACTION_WIDTH + 23), -30)
    local close = CreateFrame("Button", nil, pane, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", -1, -1)
    close:SetScript("OnClick", function() hideShopping(pane) end)

    local function scroll(delta)
        pane.scrolling = true
        pane.offset = pane.offset + delta
        refreshShoppingPane(pane)
        pane.scrolling = nil
    end
    pane:EnableMouseWheel(true)
    pane:SetScript("OnMouseWheel", function(_, delta) scroll(delta > 0 and -1 or 1) end)

    local list = CreateFrame("Frame", nil, pane, BackdropTemplateMixin and "BackdropTemplate" or nil)
    pane.list = list
    list:SetPoint("TOPLEFT", 7, -SHOPPING_HEADER_HEIGHT)
    list:SetPoint("BOTTOMRIGHT", -7, SHOPPING_FOOTER_HEIGHT)
    if list.SetBackdrop then
        list:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
            insets = {left = 2, right = 2, top = 2, bottom = 2}})
        list:SetBackdropColor(0.035, 0.024, 0.015, 1)
        list:SetBackdropBorderColor(0.45, 0.33, 0.19, 1)
    else tint(list, 0.035, 0.024, 0.015) end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta) scroll(delta > 0 and -1 or 1) end)
    pane.prev = button(list, "^", 17, function() scroll(-(pane.rowCount or #pane.rows)) end)
    pane.prev:SetSize(17, 17)
    pane.prev:SetPoint("TOPRIGHT", -2, -3)
    pane.next = button(list, "v", 17, function() scroll(pane.rowCount or #pane.rows) end)
    pane.next:SetSize(17, 17)
    pane.next:SetPoint("BOTTOMRIGHT", -2, 3)
    local function selectRow(group, keepFailedOffer)
        pane.itemID, pane.detail, pane.notice = group.itemID, true, nil
        pane.prepareKey, pane.externalSearch, pane.advance = nil, nil, nil
        pane.deferredQuote = nil
        local entry = group.entry
        pane.preferred = keepFailedOffer and entry.job and {job = entry.job, id = entry.id} or nil
        if not keepFailedOffer then
            for requirement in pairs(pane.failedOffers) do
                if requirement.itemID == pane.itemID then pane.failedOffers[requirement] = nil end
            end
        end
    end
    local function sameOffer(left, right)
        return left and right and left.quantity == right.quantity and left.totalCopper == right.totalCopper
    end
    local function prepareRowOffer(group, review)
        local entry = group and group.entry
        local need = currentShoppingNeed(group)
        if not need or need.ready or auctionWaiting(need) then return end
        if review then
            if not canReviewAuctionPrice(entry, need) then return end
        elseif not canBuyAuction(entry, need) then return end
        if auctionatorSearchRunning() then
            local wait = {anchor = activeAuctionHouse(), job = entry.job, requirement = entry.requirement}
            pane.deferredQuote, pane.notice = wait, L.shoppingWaitingAuctionator
            local ticks = 0
            local function resume()
                if pane.deferredQuote ~= wait then return end
                if not pane:IsVisible() or activeAuctionHouse() ~= wait.anchor or not pane.entry
                    or pane.entry.job ~= wait.job or pane.entry.requirement ~= wait.requirement then
                    pane.deferredQuote, pane.notice = nil, nil
                    if pane:IsVisible() then refreshShoppingPane(pane) end
                    return
                end
                if auctionatorSearchRunning() and ticks < 59 then
                    ticks = ticks + 1
                    C_Timer.After(0.25, resume)
                    return
                end
                pane.deferredQuote, pane.notice = nil, nil
                if auctionatorSearchRunning() then pane.notice = L.auctionFeedback.otherSearch
                elseif not shoppingBusy() then prepareRowOffer(pane.group, review) end
                refreshShoppingPane(pane)
            end
            C_Timer.After(0.25, resume)
            return
        end
        local ok, reason = prepareShoppingOffer(pane, group, need, auctionOfferRevision(entry, need), true, review)
        if not ok and reason then
            if not review and recordAuctionFailure(pane, entry, need, reason) then pane.advance = true end
            pane.notice = L.auctionFeedback[reason] or reason
        end
    end
    local function runRowAction(row, pressed)
        local group, action = row.entry, row.actionKind
        local auctionHouse, auction = activeAuctionHouse(), _G.FluxAuctionRestock
        if not (group and action and auctionHouse) or shoppingBusy() then return end
        local entry = group.entry
        if pressed then
            if pressed.requirement ~= entry.requirement then return end
            local refreshOnly = pressed.action == "buy" and (action == "quote" or action == "reviewQuote")
            if not refreshOnly and (pressed.action ~= action or pressed.revision ~= row.quoteRevision
                or pressed.offer and not sameOffer(pressed.offer, row.quotedOffer)) then return end
        end
        if action == "buy" then
            local need = currentShoppingNeed(group)
            if not (canBuyAuction(entry, need) and need.ready and sameOffer(need.quote, row.quotedOffer)
                and auctionOfferRevision(entry, need) == row.quoteRevision) then
                local review = row.livePrice
                selectRow(group, review)
                prepareRowOffer(group, review)
                refreshShoppingPane(pane)
                return
            end
            pane.notice, pane.externalSearch = nil, nil
            pane.advance = true
            pane.prepareKey = row.quoteRevision
            local continued = pane.continueOffers
            pane.continueOffers = true
            local ok, reason
            if need.groupRevision then ok, reason = FC.Logistics.BuyGroupedAuction(group.members, need.quote)
            else ok, reason = FC.Logistics.BuyAuction(entry, need.toBuy, need.quote) end
            if not ok then
                pane.continueOffers = continued
                recordAuctionFailure(pane, entry, need, reason)
            end
            if reason and not ok then pane.notice = L.auctionFeedback[reason] or reason end
            refreshShoppingPane(pane)
            return
        end
        local reviewPrice = not group.grouped and (action == "reviewQuote" or action == "quote" and pane.externalSearch
            and canReviewAuctionPrice(entry, FC.Logistics.GetAuctionNeed(entry)))
        selectRow(group, reviewPrice or action == "search")
        if action == "queue" then
            local job, reason = acceptPlan(entry)
            if job and pane.entry and pane.entry.job == job and pane.entry.id == entry.id then
                prepareRowOffer(pane.group)
            elseif not job and reason then
                pane.notice = reason
            end
            refreshShoppingPane(pane)
        elseif action == "search" then
            pane.externalSearch = true
            local opened
            if auctionatorListAvailable() then
                local forwarded
                opened, forwarded = FC.AuctionatorAdapter.SearchExact(group.itemID, group.quantity)
                if opened then
                    pane.notice = not forwarded and L.shoppingListExactOnly or nil
                    if coversAuction(pane, auctionHouse) then hideShopping(pane, auctionHouse) end
                end
            end
            if not opened and auction and auction.PrepareLogisticsSearch then
                local name
                opened, name = auction.PrepareLogisticsSearch(group.itemID)
                pane.notice = opened and L.shoppingNativeReady:format(name) or name or L.auctionatorSearchUnavailable
            elseif not opened then
                pane.notice = L.auctionatorSearchUnavailable
            end
            if not opened then pane.externalSearch = nil end
            refreshShoppingPane(pane)
        else
            prepareRowOffer(group, reviewPrice)
            refreshShoppingPane(pane)
        end
    end
    local function shoppingButton(parent, row, width)
        local control = button(parent, L.shoppingFindItem, width, function(self)
            local pressed = self.pressed
            self.pressed = nil
            runRowAction(row, pressed)
        end)
        control:RegisterForClicks("LeftButtonUp")
        control:SetScript("OnMouseDown", function(self, mouse)
            if mouse == "LeftButton" and row.entry then
                self.pressed = {requirement = row.entry.entry.requirement, action = row.actionKind,
                    revision = row.quoteRevision, offer = row.quotedOffer}
            end
        end)
        return control
    end
    for i = 1, 6 do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(SHOPPING_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -3 - (i - 1) * SHOPPING_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -4, -3 - (i - 1) * SHOPPING_ROW_HEIGHT)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetPoint("LEFT", 3, 0)
        row.icon:SetSize(19, 19)
        row.quantity = label(row)
        row.quantity:SetPoint("LEFT", 23, 0)
        row.quantity:SetWidth(27)
        row.quantity:SetJustifyH("RIGHT")
        row.name = label(row)
        row.name:SetPoint("LEFT", 53, 0)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetWordWrap(false)
        row.price = label(row)
        row.price:SetPoint("RIGHT", -(SHOPPING_ACTION_WIDTH + 7), 0)
        row.price:SetJustifyH("RIGHT")
        row.incoming = label(row)
        row.incoming:SetPoint("RIGHT", -(SHOPPING_ACTION_WIDTH + 86), 0)
        row.incoming:SetTextColor(0.8, 0.73, 0.59)
        row.action = shoppingButton(row, row, SHOPPING_ACTION_WIDTH)
        row.action:SetHeight(20)
        row.action:SetPoint("RIGHT", -3, 0)
        row.selection = row:CreateTexture(nil, "BACKGROUND")
        row.selection:SetAllPoints()
        row.selection:SetColorTexture(0.58, 0.41, 0.17, 0.32)
        local divider = row:CreateTexture(nil, "BORDER")
        divider:SetPoint("BOTTOMLEFT", 1, 0)
        divider:SetPoint("BOTTOMRIGHT", -1, 0)
        divider:SetHeight(1)
        divider:SetColorTexture(0.43, 0.31, 0.15, 0.35)
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(0.84, 0.67, 0.4, 0.15)
        row:SetScript("OnClick", function(self)
            if not self.entry then return end
            local externalSearch = pane.externalSearch
            pane.failedGroups[self.entry.itemID] = nil
            selectRow(self.entry)
            pane.externalSearch = externalSearch
            refreshShoppingPane(pane)
        end)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta) scroll(delta > 0 and -1 or 1) end)
        row:SetScript("OnEnter", function(self)
            local group = self.entry
            if group then tooltip(self, group.itemID, nil, nil, nil, group.marketPrice) end
        end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        pane.rows[i] = row
    end
    pane.empty = label(pane, L.auctionShoppingEmpty)
    pane.empty:SetPoint("TOPLEFT", list, "TOPLEFT", 7, -8)
    pane.empty:SetPoint("TOPRIGHT", list, "TOPRIGHT", -7, -8)
    pane.status = label(pane)
    pane.status:SetPoint("BOTTOMLEFT", 9, 29)
    pane.status:SetPoint("BOTTOMRIGHT", -8, 29)
    pane.status:SetWordWrap(false)
    pane.search = button(pane, L.auctionatorButton, 87, function()
        local auctionHouse = activeAuctionHouse()
        if not auctionHouse then return end
        if FC.Logistics.IsWorkflowBusy() then displayShoppingStatus(pane, L.workflowBusy); return end
        pane.externalSearch = true
        pane.deferredQuote = nil
        pane.notice = nil
        refreshShoppingPane(pane)
        if not auctionatorListAvailable() then
            local auction, entry = _G.FluxAuctionRestock, pane.entry
            if not (auction and auction.PrepareLogisticsSearch and entry) then return end
            local ok, name = auction.PrepareLogisticsSearch(entry.itemID)
            pane.notice = ok and L.shoppingNativeReady:format(name) or name or L.auctionatorSearchUnavailable
            displayShoppingStatus(pane, pane.notice)
            if not ok then pane.externalSearch = nil end
            return
        end
        local materials = shoppingPriceItems(pane)
        local opened, forwarded, skipped
        if #materials > 0 then opened, forwarded, skipped = FC.AuctionatorAdapter.SearchList(materials) end
        if opened then
            pane.notice = skipped and skipped > 0 and L.shoppingListPartial:format(skipped)
                or not forwarded and L.shoppingListExactOnly
            if pane.notice then displayShoppingStatus(pane, pane.notice) end
            if coversAuction(pane, auctionHouse) then hideShopping(pane, auctionHouse)
            elseif C_Timer and C_Timer.After then
                C_Timer.After(0, function()
                    if pane:IsVisible() and pane.externalSearch and activeAuctionHouse() == auctionHouse
                        and coversAuction(pane, auctionHouse) then hideShopping(pane, auctionHouse) end
                end)
            end
        else
            pane.externalSearch = nil
            pane.notice = #materials > 0 and L.auctionatorSearchUnavailable or L.alreadyCovered
            displayShoppingStatus(pane, pane.notice)
        end
    end)
    pane.search:SetPoint("BOTTOMLEFT", 7, 4)
    pane.primary = {}
    pane.primary.action = shoppingButton(pane, pane.primary, 96)
    pane.primary.action:SetPoint("BOTTOMRIGHT", -7, 4)
    pane.budgetText = label(pane)
    pane.budgetText:SetPoint("LEFT", pane.search, "RIGHT", 4, 0)
    pane.budgetText:SetPoint("RIGHT", pane.primary.action, "LEFT", -4, 0)
    pane.budgetText:SetWordWrap(false)
    return pane
end

local function refreshShopping()
    refreshShoppingPane(UI.auctionShopping)
end

local function openShoppingAt(anchor, itemID, previewOnly, preferred)
    if not UI.auctionShopping then UI.auctionShopping = createShoppingPane() end
    showShopping(UI.auctionShopping, anchor, itemID, previewOnly, preferred)
end

function UI.OpenAuctionShopping(parent, selected)
    parent = activeAuctionHouse() or parent
    if not parent or not parent:IsVisible() then return false, L.auctionFeedback.openAH end
    local preferred
    if selected then
        for _, entry in ipairs(FC.Queue.GetRequirements()) do
            if entry.job.id == selected.jobId and entry.id == selected.id and entry.itemID == selected.itemID
                and entry.job.planRevision == selected.planRevision and FC.Logistics.IsAuctionShoppingEntry(entry) then
                if entry.job.status == "paused" then return false, L.paused end
                preferred = entry
                break
            end
        end
        if not preferred then return false, L.alreadyCovered end
    end
    openShoppingAt(parent, preferred and preferred.itemID, nil, preferred)
    local auction = _G.FluxAuctionRestock
    if preferred and auction and auction.active and UI.auctionShopping then
        UI.auctionShopping.ownerSession = true
        refreshShoppingPane(UI.auctionShopping)
    end
    return true
end

local function shoppingAnchor()
    return activeAuctionHouse() or UI.window and UI.window:IsVisible() and (UI.forever or UI.classic or UI.window)
end

local function toggleShoppingList()
    local pane = UI.auctionShopping
    if pane and pane:IsVisible() then hideShopping(pane)
    else
        if UI.recipeSelectionPending then UI.Refresh() end
        local anchor = shoppingAnchor()
        if anchor then UI.OpenAuctionShopping(anchor) end
    end
end

updateRecipeAuctionator = function()
    local house, recipe = activeAuctionHouse(), selectedRecipe()
    if UI.recipeAuctionator then
        UI.recipeAuctionator:SetShown(not not (house and auctionatorListAvailable()))
        UI.recipeAuctionator:SetEnabled(not not recipe)
    end
    if UI.auctionPriceButton then
        UI.auctionPriceButton:SetShown(not not (house and FC.Logistics.HasAuctionPriceScan()))
        UI.auctionPriceButton:SetEnabled(not not (house and recipe and not UI.auctionPriceScan))
    end
    if UI.layoutToolbar then UI.layoutToolbar(UI.plan:GetWidth()) end
end

local function checkAuctionPrices()
    if not activeAuctionHouse() or UI.auctionPriceScan or not FC.Logistics.HasAuctionPriceScan() then return end
    if UI.job then
        if not UI.job.rootRecipeId or UI.job.goal and UI.job.goal.demandId then return end
        if not draftRemaining(UI.job) then return end
    end
    local args, reason = buildArgs()
    if not args then notify(reason); return end
    local scan = {recipe = UI.selectedRecipeId, replaces = UI.replaces}
    UI.auctionPriceScan = scan
    local ok, status = FC.Logistics.ScanAuctionPrices(args, function(found, incomplete, failure)
        if UI.auctionPriceScan ~= scan then return end
        UI.auctionPriceScan = nil
        if not UI.job and UI.selectedRecipeId == scan.recipe and UI.replaces == scan.replaces then
            if found then
                UI.Refresh()
                notify(incomplete and L.auctionPricesPartial or L.auctionPricesReady)
            else notify(L.auctionFeedback[failure] or failure or L.auctionFeedback.noOffer) end
        end
        inspect()
    end)
    if not ok then
        UI.auctionPriceScan = nil
        notify(L.auctionFeedback[status] or status)
    elseif UI.auctionPriceScan == scan then notify(L.auctionCheckingPrices) end
    inspect()
end

local function searchCurrentRecipe()
    local recipe, auction = selectedRecipe(), activeAuctionHouse()
    if not recipe or not auction or not auctionatorListAvailable() then return end
    if FC.Logistics.IsWorkflowBusy() then notify(L.workflowBusy); return end
    local plan = UI.job or UI.preview
    local inputs, output = {}, 0
    for _, candidate in ipairs(plan and plan.tasks or {}) do
        if candidate.recipeId == recipe.id and candidate.outputItemID == recipe.outputItemID then
            output = output + (candidate.outputQuantity or candidate.executions * candidate.yield)
            for _, input in ipairs(candidate.inputs or {}) do inputs[#inputs + 1] = input end
        end
    end
    if output == 0 then
        if plan and plan.inspectionOnly and plan.rootRecipeId == recipe.id and plan.tree and plan.summary then
            -- A blocked recipe can still have a priced graph with exact inputs.
            output = plan.summary.output
            for _, reagent in ipairs(plan.tree.children or {}) do
                inputs[#inputs + 1] = {itemID = reagent.itemID, quantity = reagent.required}
            end
        else
            output = recipe.yield or 1
            local choice = recipe.reagentChoices and recipe.reagentChoices[1]
            inputs = choice and choice.reagents or recipe.reagents or {}
        end
    end
    local materials, byItem = {}, {}
    local function add(itemID, quantity)
        if not itemID or not quantity or quantity < 1 then return end
        local term = byItem[itemID]
        if term then term.quantity = term.quantity + quantity
        else
            term = {itemID = itemID, quantity = quantity}
            byItem[itemID] = term
            materials[#materials + 1] = term
        end
    end
    add(recipe.outputItemID, output)
    local tree = plan and plan.rootRecipeId == recipe.id and plan.tree
    if tree and tree.children and #tree.children > 0 then
        local function addChildren(node)
            for _, child in ipairs(node.children or {}) do
                add(child.itemID, child.required)
                addChildren(child)
            end
        end
        addChildren(tree)
    else
        for _, input in ipairs(inputs) do add(input.itemID, input.quantity) end
    end
    -- Unselected production routes supply comparison prices without a buy quantity.
    for _, itemID in ipairs(FC.Logistics.GetRecipePriceItems(recipe.id, recipe.outputItemID) or {}) do
        if not byItem[itemID] then materials[#materials + 1] = {itemID = itemID} end
    end
    local pane = UI.auctionShopping
    if pane then pane.externalSearch = true end
    local opened, forwarded, skipped = FC.AuctionatorAdapter.SearchList(materials)
    if opened then
        if pane and coversAuction(pane, auction) then hideShopping(pane, auction) end
        if skipped and skipped > 0 then notify(L.shoppingListPartial:format(skipped))
        elseif not forwarded then notify(L.shoppingListExactOnly) end
    else
        if pane then pane.externalSearch = nil end
        notify(L.auctionatorSearchUnavailable)
    end
end

local function openQueuedShopping()
    local auction = activeAuctionHouse()
    local pane = UI.auctionShopping
    if auction and (pane and pane:IsVisible() or #groupAuctionEntries(queueAuctionEntries(), {}) > 0) then
        UI.OpenAuctionShopping(auction)
    elseif pane and pane:IsVisible() and pane.previewOnly then
        UI.OpenAuctionShopping(pane.anchor)
    end
end

local function selectedAcquisition()
    local entry = UI.requirement
    if entry and (entry.job ~= UI.job or entry.job.status ~= "queued"
        or FC.Queue.AcquisitionRemaining(entry.job, entry.requirement) <= 0) then
        UI.requirement = nil
    end
    return UI.requirement
end

local function queueJobLabel(job, status)
    local recipe = job.rootRecipeId and FC.Catalog.Get(job.rootRecipeId)
    local profession = recipe and recipe.professionName
    if not profession then
        for _, task in ipairs(job.tasks or {}) do
            if task.recipeId == job.rootRecipeId then profession = task.professionName; break end
        end
    end
    local text = recipe and recipeName(recipe) or itemInfo(job.rootItemID)
    if profession and profession ~= "" then text = text .. L.queueProfession:format(profession) end
    if status and status ~= "queued" then text = text .. L.queueJobState:format(L[status] or status) end
    return text
end

local function needsReview(job)
    return job and (job.status == "uncertain" or job.acquisition and job.acquisition.status == "uncertain")
end

local function canRetryBlockedCraft(job)
    return job and FC.Execution.CanRetryBlockedCraft and FC.Execution.CanRetryBlockedCraft(job)
end

local function canReplanFromBags(job)
    return job and FC.Execution.CanReplanFromBags and FC.Execution.CanReplanFromBags(job)
end

local function queueReviewJob()
    if activeQueueJob(UI.job) then return needsReview(UI.job) and UI.job or nil end
    local job, task = FC.Queue.NextTask(UI.professionID)
    if task and task.status == "uncertain" then return job end
end

local function renderQueueAction(hasJobs)
    local job = queueReviewJob()
    local recovery = job and FC.Execution.GetCarriedOutputRecovery and FC.Execution.GetCarriedOutputRecovery(job)
    UI.carriedRecovery, UI.carriedRecoveryJob = recovery, recovery and job or nil
    local canResume = canReplanFromBags(job)
    local recoveryID, recoveryName
    if not recovery and not canResume and job and FC.Execution.GetRecoveryProfession then
        recoveryID, recoveryName = FC.Execution.GetRecoveryProfession(job)
    end
    UI.recoveryProfession, UI.recoveryProfessionJob = recoveryName, recoveryID and job or nil
    local width = UI.recoveryProfession and 103 or 67
    if UI.process:GetWidth() ~= width then UI.process:SetWidth(width) end
    local caption = L.processShort
    if UI.recoveryProfession then caption = L.openRecoveryProfession
    end
    UI.process:SetText(caption)
    if hasJobs ~= nil then UI.process:SetEnabled(hasJobs) end
end

local function queueJobState(job)
    if needsReview(job) then return "uncertain" end
    if job.status == "running" then return "queued" end
    return job.status
end

local function fitsQueueGroup(group, job)
    if group.state ~= "queued" then return false end
    for _, member in ipairs(group.jobs) do
        if not FC.Queue.CanGroup(member, job) then return false end
    end
    return true
end

local function queueGroups()
    local groups, byItem = {}, {}
    for _, job in ipairs(FC.Queue.GetJobs()) do
        if activeQueueJob(job) then
            local state = queueJobState(job)
            local item = tostring(job.rootItemID)
            local candidates = byItem[item] or {}
            local group
            if state == "queued" then
                for _, candidate in ipairs(candidates) do
                    if fitsQueueGroup(candidate, job) then group = candidate; break end
                end
            end
            if not group then
                group = {job = job, jobs = {}, count = 0, state = state, removable = true}
                groups[#groups + 1] = group
                if state == "queued" then
                    byItem[item] = candidates
                    candidates[#candidates + 1] = group
                end
            end
            group.jobs[#group.jobs + 1] = job
            group.count = group.count + FC.Queue.VisibleOutstandingOutput(job)
            if job == UI.job then group.job = job end
            if job.status == "running" then group.running = job end
            if job.status == "running" or FC.Queue.HasIssuedAcquisition(job) then
                group.removable = false
            end
        end
    end
    return groups
end

local function queueCurrentStep(job)
    if job.status == "invalidated" then return end
    local tasks = job.tasks or {}
    local function describe(task, index, caption)
        local recipe = FC.Catalog.Get(task.recipeId)
        local name = recipe and recipeName(recipe) or itemInfo(task.outputItemID)
        local remaining = task.executions - FC.Queue.VisibleCompletedExecutions(task)
        local recovery = UI.carriedRecoveryJob == job and UI.carriedRecovery
        if recovery and recovery.taskId == task.taskId then
            remaining, caption = recovery.remainingExecutions, L.queueResumeStep
        end
        local cast, waiting
        if task.status == "in_flight" and FC.Execution.GetActiveCast then
            cast, waiting = FC.Execution.GetActiveCast(job, task)
        end
        local text = (waiting or remaining == 0) and L.queueVerifyingCraft:format(name) or caption:format(remaining, name)
        if cast then text = L.queueCastDuration:format(text, (cast.endTimeMs - cast.startTimeMs) / 1000) end
        return L.queueStepPosition:format(index, #tasks, text)
    end
    local pending, ready
    for index, task in ipairs(tasks) do
        if task.status == "in_flight" or task.status == "uncertain" then
            local caption = task.status == "in_flight" and L.queueCraftingStep or L.queueStoppedStep
            return describe(task, index, caption)
        elseif task.status == "pending" then
            pending = pending or index
            if not ready and FC.Queue.CanProcess(job, task) then ready = index end
        end
    end
    local requirement = not ready and FC.Queue.GetRequirements(job)[1]
    if requirement then
        local source = requirement.kind == "bank" and L.Bank
            or requirement.kind == "vendor" and L.Vendor or L.Buy
        local caption = job.acquisition and job.acquisition.status == "uncertain" and L.queueVerifyMaterial
            or L.queueMaterialStep
        return caption:format(source, requirement.quantity, itemInfo(requirement.itemID))
    end
    local index = ready or pending
    if index then return describe(tasks[index], index, L.queueNextStep) end
end

local function refreshNativeQueueProgress()
    if not UI.nativeCraftProgress then return end
    local job = UI.nativeCraftJob
    local step = UI.nativeCraftMessage and activeQueueJob(job) and queueCurrentStep(job)
    UI.nativeCraftProgress:SetText(step or "")
    UI.nativeCraftProgress:SetShown(not not step)
    local followup = professionFollowup()
    if not (followup and followup.HasProfessionReminderDock == true) then return end
    local anchor = nativeReminderAnchor()
    if UI.nativeReminderAnchor == anchor then return end
    UI.nativeReminderAnchor = anchor
    if not (UI.window and UI.window:IsVisible()) then refreshRestockProfessionLayer() end
end

local function queueViewport(rowCount, rowHeight, expanded)
    local dock = UI.professionReminderDock
    local footerHeight = QUEUE_ACTION_HEIGHT + (dock and dock:IsShown() and PROFESSION_REMINDER_HEIGHT or 0)
    local available = math.max(1, UI.plan:GetHeight() - footerHeight)
    local graphHeight = available
    if expanded then
        local desired = UI.graph.root and math.max(96, UI.graph.height) or 54
        local minQueue = rowHeight + QUEUE_PADDING
        local queueShare = rowHeight == COMPACT_QUEUE_ROW_HEIGHT and 0.40 or 0.60
        local queueDemand = math.max(minQueue,
            math.min(rowCount * rowHeight + QUEUE_PADDING, math.floor(available * queueShare)))
        graphHeight = math.min(desired, math.max(1, available - queueDemand - GRAPH_GAP))
    end
    if UI.graph.frame:GetHeight() ~= graphHeight then UI.graph.frame:SetHeight(graphHeight) end
    return math.max(1, math.floor((available - graphHeight - GRAPH_GAP - QUEUE_PADDING) / rowHeight))
end

function UI.RenderQueue()
    if not UI.queuePane or not UI.ensureQueueRow then return end
    local groups = queueGroups()
    local selected = UI.job
    if selected and selected.status == "complete" then
        for _, group in ipairs(groups) do
            if fitsQueueGroup(group, selected) then
                local job = group.job
                if UI.queueDetailJob == selected then UI.queueDetailJob = job end
                UI.job, UI.step, UI.requirement, UI.nodePath = job, nil, nil, nil
                break
            end
        end
    end
    if UI.step and UI.step.status == "complete" then UI.step = nil end
    UI.queuePaintedJob = UI.job
    selectedAcquisition()
    local expanded = UI.queueExpanded ~= false
    UI.queueToggle:SetText((expanded and L.collapse or L.expand) .. " " .. tostring(#groups))
    renderQueueAction(#groups > 0)
    UI.queueClear:SetEnabled(#groups > 0)
    local rowCount = math.max(1, #groups)
    local compact = #groups > 0 and UI.plan:GetWidth() < 360
    local rowHeight = compact and COMPACT_QUEUE_ROW_HEIGHT or QUEUE_ROW_HEIGHT
    local capacity = queueViewport(rowCount, rowHeight, expanded)
    if not expanded then
        UI.queuePane:Hide()
        UI.queueEarlier:Hide()
        UI.queueLater:Hide()
        return
    end
    local visible = math.min(rowCount, capacity)
    local overflow = rowCount > visible
    local stepWidth = math.max(88, math.min(240, math.floor(UI.queuePane:GetWidth() * 0.44)))
    UI.queueOffset = math.min(UI.queueOffset, math.max(0, rowCount - visible))
    UI.queueEarlier:SetShown(overflow)
    UI.queueLater:SetShown(overflow)
    UI.queueEarlier:SetEnabled(UI.queueOffset > 0)
    UI.queueLater:SetEnabled(UI.queueOffset + visible < rowCount)
    for index = #UI.queueRows + 1, visible do UI.ensureQueueRow(index) end
    for index, row in ipairs(UI.queueRows) do
        local group = index <= visible and groups[index + UI.queueOffset]
        local job = group and group.job
        row.line = group or nil
        if index <= visible then
            local offset = 2 + (index - 1) * rowHeight
            row:SetHeight(rowHeight)
            row:SetPoint("TOPLEFT", 3, -offset)
            row:SetPoint("TOPRIGHT", overflow and -22 or -4, -offset)
            local state = group and (group.running and "running" or group.state)
            local step = group and queueCurrentStep(group.running or job)
            local count = group and group.count
            if job and job == UI.carriedRecoveryJob then
                state = "resumeReady"
                count = math.max(0, count - UI.carriedRecovery.quantity)
            end
            row.caption:SetText(job and L.queueRowTitle:format(count, queueJobLabel(job, state)) or L.queueEmpty)
            row.caption:SetPoint("TOPLEFT", job and 22 or 4, -3)
            row.progress:ClearAllPoints()
            if compact then
                row.caption:SetPoint("TOPRIGHT", -42, -3)
                row.progress:SetPoint("TOPLEFT", 22, -17)
                row.progress:SetPoint("TOPRIGHT", -6, -17)
            elseif step then
                row.progress:SetPoint("TOPRIGHT", -42, -3)
                row.caption:SetPoint("TOPRIGHT", row.progress, "TOPLEFT", -7, 0)
                row.progress:SetWidth(stepWidth)
            else row.caption:SetPoint("TOPRIGHT", -42, -3) end
            row.caption:SetTextColor(job and 1 or 0.65, job and 0.82 or 0.62, job and 0.42 or 0.56)
            if job then
                local _, icon = itemInfo(job.rootItemID)
                row.icon:SetTexture(icon)
            end
            row.icon:SetShown(job ~= nil)
            row.message = step
            row.progress:SetText(step or "")
            row.progress:SetShown(step ~= nil)
            row.detail:SetShown(job ~= nil)
            row.remove:SetShown(job ~= nil)
            row.remove:SetEnabled(group and group.removable == true or false)
            row.selected:SetShown(job ~= nil and job == UI.job)
            row:Show()
        else row:Hide() end
    end
    UI.queuePane:Show()
end

local function showAuctionRequirement(entry)
    local anchor = shoppingAnchor()
    if anchor then openShoppingAt(anchor, entry.itemID, nil, entry.job and entry or nil) end
end

local function queueSelection(line)
    local job = line.job
    if not activeQueueJob(job) or FC.Queue.GetJob(job.id) ~= job then return end
    UI.job = job
    UI.replaces, UI.demandId, UI.pendingNativeRecipeID = nil, nil, nil
    UI.step, UI.requirement, UI.nodePath = line.task, line.entry, nil
    UI.selectedRecipeId = job.rootRecipeId
    local execution = FC.Execution
    if UI.nativeCraftJob and UI.nativeCraftJob ~= job and execution.CancelNativeCraft
        and execution.HasNativeCraftPending and execution.HasNativeCraftPending()
        and not (execution.IsBusy and execution.IsBusy()) then
        UI.nativeCraftSequence = nil
        execution.CancelNativeCraft()
    end
    if line.task then
        for _, entry in ipairs(FC.Graph.Layout(currentTree(), {})) do
            if taskFits(entry.node, line.task) then UI.nodePath = entry.path; break end
        end
    end
    UI.Refresh()
    if auctionEntry(line.entry, true) then showAuctionRequirement(line.entry) end
end

local function focusCraftJob(job)
    if not job or job == UI.job then return end
    if UI.queueDetailJob then UI.queueDetailJob = job end
    UI.job, UI.step, UI.requirement, UI.replaces, UI.demandId = job, nil, nil, nil, nil
    UI.nodePath, UI.pendingNativeRecipeID = nil, nil
    UI.selectedRecipeId = job.rootRecipeId or UI.selectedRecipeId
    UI.queueOffset, UI.queueExpanded = 0, true
end

local function dispatchCraft(job, task)
    UI.dispatching = true
    local ok, message, acceptedJob, phase = FC.Execution.ProcessClick(job, task)
    UI.dispatching = nil
    if phase == "native_click" then message = UI.ShowNativeCraft(message, acceptedJob or job) or message
    else focusCraftJob(acceptedJob) end
    return ok, message
end

local function acceptedReagentChoice(recipe)
    local plan = UI.job
    if not plan or not plan.tree or (plan.status ~= "queued" and plan.status ~= "paused") then return end
    for _, task in ipairs(plan.tasks or {}) do
        if task.recipeId == recipe.id and taskFits(plan.tree, task) then return task.reagentChoice end
    end
end

local function craftSelected(all)
    local recipe = selectedRecipe()
    if not recipe or not isNativeRecipeSelected(recipe) then return end
    local quantity
    if all then
        if not FC.Execution.CraftSelected then return end
    else
        if not FC.Execution.CreateSelected then return end
        quantity = enteredQuantity()
        if not quantity then notify(L.quantityError); return end
        if UI.saved.quantityMode == "Crafts" then
            if not recipe.yield or recipe.yield < 1 then notify(L.yieldUnknown); return end
            quantity = quantity * recipe.yield
        end
    end
    local choice = acceptedReagentChoice(recipe)
    local _, message, job, phase
    UI.dispatching = true
    if all then
        _, message, job, phase = FC.Execution.CraftSelected(recipe.id, true, choice, nil, true)
    else
        _, message, job, phase = FC.Execution.CreateSelected(recipe.id, quantity, choice, UI.saved.choices[tostring(recipe.id)], true)
    end
    UI.dispatching = nil
    if job then
        UI.job, UI.step, UI.requirement, UI.replaces, UI.queueDetailJob = job, nil, nil, nil, job
        UI.queueOffset, UI.queueExpanded = 0, true
        UI.Layout()
        if not all then openQueuedShopping() end
    end
    if phase == "native_click" then message = UI.ShowNativeCraft(message, job) or message end
    notify(message)
    UI.Schedule()
end

local function review(job)
    job = job or UI.job
    local ok, message
    if job and job.acquisition then ok, message = FC.Logistics.ResolveAcquisition(job)
    elseif canRetryBlockedCraft(job) then ok, message = FC.Execution.RetryBlockedCraft(job)
    else ok, message = FC.Execution.ReconcileUncertain(job) end
    notify(message)
    UI.RenderQueue()
    inspect()
    return ok
end

local function queuedTask(job)
    return FC.Queue.NextTask(UI.professionID, job)
end

local function queuedRequirement(job)
    if activeAuctionHouse() then
        for _, entry in ipairs(FC.Logistics.GetAuctionShoppingRequirements()) do
            if entry.job.status == "queued" and (not job or entry.job == job) then return entry, true end
        end
    end
    for _, entry in ipairs(FC.Queue.GetRequirements(job)) do
        if entry.job.status == "queued" then return entry end
    end
end

local function processNext()
    local stopped = queueReviewJob()
    local recovery = UI.carriedRecovery
    if recovery then
        if stopped ~= UI.carriedRecoveryJob then
            UI.RenderQueue()
            notify(L.execCarriedOutputChanged)
            return
        end
        local ok, feedback, task = FC.Execution.ResumeWithCarriedOutput(stopped, recovery)
        if ok then
            focusCraftJob(stopped)
            UI.step, UI.requirement = nil, nil
            if task and FC.Queue.CanProcess(stopped, task) then
                local _, craftMessage = dispatchCraft(stopped, task)
                feedback = craftMessage or feedback
            end
        end
        UI.RenderQueue()
        inspect()
        notify(feedback)
        return
    end
    if UI.recoveryProfessionJob then
        local result = L.execReplanUnavailable
        if stopped == UI.recoveryProfessionJob then
            focusCraftJob(stopped)
            local _, feedback = FC.Execution.OpenRecoveryProfession(stopped)
            result = feedback or result
        end
        UI.RenderQueue()
        notify(result)
        return
    end
    if stopped then
        focusCraftJob(stopped)
        if not canReplanFromBags(stopped) then
            local blocked = canRetryBlockedCraft(stopped)
            if not review(stopped) or blocked or stopped.status ~= "queued" then return end
        end
    end
    local job, requirement = UI.job, selectedAcquisition()
    if job and job.status ~= "queued" and job.status ~= "running"
        and job.status ~= "uncertain" and job.status ~= "paused" then
        job = nil
    end
    local message
    if requirement then
        if auctionEntry(requirement) then
            showAuctionRequirement(requirement)
        else
            local _, result = FC.Logistics.Acquire(requirement)
            message = result
        end
    elseif job and UI.step and FC.Queue.CanProcess(job, UI.step) then
        local _, result = dispatchCraft(job, UI.step)
        if result == L.execMissingMaterials then _, result = dispatchCraft(job) end
        message = result
    else
        local nextJob, task = queuedTask(job)
        if task then
            local _, result = dispatchCraft(job and nextJob or nil)
            message = result
        else
            message = L.noReadyCraft
            local entry, atAuction = queuedRequirement(job)
            if entry then
                UI.job, UI.requirement, UI.step = entry.job, entry, nil
                UI.selectedRecipeId = entry.job.rootRecipeId or UI.selectedRecipeId
                if atAuction then
                    showAuctionRequirement(entry)
                    message = nil
                else
                    local _, result = FC.Logistics.Acquire(entry)
                    message = result
                end
            end
        end
    end
    notify(message)
    UI.RenderQueue()
    inspect()
end

local function layoutClassicTabs()
    local height = math.max(1, UI.classic:GetHeight() - 43)
    local size = math.max(23, math.min(37, math.floor(height / (#UI.classicProfessions + 1)) - 3))
    UI.overviewTab:SetSize(35, size)
    for _, tab in ipairs(UI.professionTabs) do tab:SetSize(35, size) end
end

function UI.Layout()
    if not UI.window then return end
    local width, height = UI.window:GetSize()
    if width < 1 or height < 1 then return end
    if UI.classic then
        UI.listPane:SetWidth(math.max(218, math.min(320, math.floor(width * 0.35))))
        UI.RenderRecipes()
    end
    UI.RenderQueue()
    inspect()
end

local function toggleQueue()
    if UI.menu then UI.menu:Hide() end
    UI.queueExpanded = not (UI.queuePane and UI.queuePane:IsShown())
    UI.RenderQueue()
end

local function showAcceptedJob(job, context, draft)
    job.projection = context and context.projection
    UI.job, UI.queueOffset, UI.replaces, UI.queueExpanded = job, 0, nil, true
    UI.Layout()
    local auction = draft and activeAuctionHouse()
    if auction then openShoppingAt(auction, draft.itemID, nil, {job = job, id = draft.id})
    else openQueuedShopping() end
    notify(L.queueAccepted:format(job.id))
    return job
end

acceptPlan = function(draft)
    if draft and (UI.pendingDraft or UI.job or draft.preview ~= UI.preview or enteredQuantity() ~= UI.saved.quantity
        or draft.requirement ~= UI.preview.requirements[draft.id]) then
        UI.Refresh()
        return nil, L.shoppingPreviewChanged
    end
    if enteredQuantity() ~= UI.saved.quantity then changePreview()
    elseif UI.recipeSelectionPending then UI.Refresh() end
    local args, reason = buildArgs()
    if not args then notify(reason); return nil, reason end
    local job, why = FC.Queue.Accept(UI.preview, function() return FC.Logistics.Preview(args) end, UI.replaces)
    if not job then UI.Refresh(); notify(why); return nil, why end
    return showAcceptedJob(job, UI.context, draft)
end

local function queueAllSelected()
    local recipe = selectedRecipe()
    if not recipe or not FC.Execution.QueueAllSelected or not isNativeRecipeSelected(recipe) then return end
    local job, reason, context = FC.Execution.QueueAllSelected(recipe.id)
    if not job then notify(reason); return end
    return showAcceptedJob(job, context)
end

local function availableSources(node)
    local sources = {"Auto"}
    if #(UI.catalog.byOutput[node.itemID] or {}) > 0 then sources[#sources + 1] = "Make" end
    sources[#sources + 1] = "Buy"
    local seen = {}
    for _, offer in ipairs(UI.context and UI.context.acquisitions[node.itemID] or {}) do
        local name = offer.kind == "vendor" and "Vendor" or offer.kind == "bank" and "Bank"
        if name and not seen[name] and (not offer.availableUnits or offer.availableUnits > 0) then
            sources[#sources + 1], seen[name] = name, true
        end
    end
    if not seen.Vendor and UI.context and UI.context.vendorEstimates and UI.context.vendorEstimates[node.itemID] then
        sources[#sources + 1] = "Vendor"
    end
    return sources
end

local function chooseSource(node, source)
    local key = tostring(UI.selectedRecipeId)
    local choices = UI.saved.choices[key] or {}
    UI.saved.choices[key] = choices
    local previous = choices[node.itemID] or choices[tostring(node.itemID)]
    local choice = {source = source}
    if source == "Make" and previous then choice.recipeId = previous.recipeId end
    if source == "next" then
        local recipes = UI.catalog.byOutput[node.itemID]
        local current = 0
        for i, id in ipairs(recipes) do
            if id == (previous and previous.recipeId or node.recipeId) then current = i; break end
        end
        choice.recipeId, choice.source = recipes[current % #recipes + 1], "Make"
    end
    choices[node.itemID] = choice
    changePreview()
end

local function placeMenu(owner, recipeId)
    local menu = UI.menu
    menu:Hide()
    menu:SetFrameLevel(UI.window:GetFrameLevel() + 60)
    menu:ClearAllPoints()
    if owner == UI.estimate then menu:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, 4)
    elseif recipeId then menu:SetPoint("TOPLEFT", UI.plan, "TOPLEFT", 4, -4)
    else menu:SetPoint("TOPRIGHT", UI.plan, "TOPRIGHT", -4, -4) end
    menu.owner, menu.recipeId = owner, recipeId
    return menu
end

local function openMenu(owner, actions, recipeId)
    if #actions == 0 then return end
    local menu = placeMenu(owner, recipeId)
    menu:SetHeight(8 + #actions * 23)
    for index, action in ipairs(actions) do
        local control = menu.actions[index]
        if not control then
            control = button(menu, "", 155, function(self)
                menu:Hide()
                if self.activate then self.activate() end
            end)
            control:SetPoint("TOPLEFT", 4, -4 - (index - 1) * 23)
            menu.actions[index] = control
        end
        control:SetText(action[1])
        control.activate = action[2]
        control:Show()
    end
    for index = #actions + 1, #menu.actions do menu.actions[index]:Hide() end
    if GameTooltip then GameTooltip:Hide() end
    menu:Show()
end

local function clearQueue()
    if UI.menu then UI.menu:Hide() end
    local ok, reason = FC.Queue.Clear()
    if not ok then notify(reason); return end
    UI.queueDetailJob, UI.replaces = nil, nil
    changePreview()
    notify(L.queueCleared)
end

local function showPricingMenu(owner)
    if UI.menu:IsShown() and UI.menu.owner == owner then UI.menu:Hide(); return end
    local settings = FC.Logistics.GetSettings()
    local actions = {}
    local function choice(text, field, value, selected)
        actions[#actions + 1] = {(selected and "> " or "") .. text, function()
            settings[field] = value
            UI.Refresh()
            if UI.job then notify(L.pricingPreviewOnly) end
        end}
    end
    local objective, provider = settings.objective or "value", settings.provider or "auto"
    choice(L.planner.minValue, "objective", "value", objective == "value")
    choice(L.planner.minCash, "objective", "cash", objective == "cash")
    choice(L.pricesAuto, "provider", "auto", provider == "auto")
    choice(L.pricesAuctionator, "provider", "auctionator", provider == "auctionator")
    choice(L.pricesTSM, "provider", "tsm", provider == "tsm")
    if provider ~= "auto" then
        choice(L.pricesFallback, "allowFallback", settings.allowFallback ~= true, settings.allowFallback == true)
    end
    openMenu(owner, actions)
end

local function saveRecipeMeta(recipeId, key, value)
    local records = UI.saved.recipeMeta
    local id = tostring(recipeId)
    local meta = records[id] or {}
    meta[key] = value
    records[id] = next(meta) and meta or nil
    UI.metaRevision = (UI.metaRevision or 0) + 1
    UI.Refresh(true)
end

local function editRecipeMeta(recipeId, key, prompt, limit)
    local menu = UI.menu
    if not menu.editor then
        local field = edit(menu, 149, nil, function(value)
            local trimmed = value:match("^%s*(.-)%s*$")
            saveRecipeMeta(menu.recipeId, menu.metaKey, trimmed ~= "" and trimmed or nil)
            menu:Hide()
        end)
        field:SetPoint("TOPLEFT", 7, -22)
        field:SetAutoFocus(true)
        field:SetScript("OnEscapePressed", function() menu:Hide() end)
        menu.editor = field
        menu.editorPrompt = label(menu, "", "GameFontNormalSmall")
        menu.editorPrompt:SetPoint("TOPLEFT", 7, -5)
        menu:HookScript("OnHide", function()
            field:ClearFocus()
            field:Hide()
            menu.editorPrompt:Hide()
        end)
    end
    for _, control in ipairs(menu.actions) do control:Hide() end
    menu.metaKey = key
    menu:SetHeight(48)
    menu.editorPrompt:SetText(prompt)
    local meta = UI.saved.recipeMeta[tostring(recipeId)]
    menu.editor:SetMaxLetters(limit)
    menu.editor:SetText(meta and meta[key] or "")
    menu.editor:Show()
    menu.editorPrompt:Show()
    menu:Show()
end

local function registerNativeRecipeMetadata(page)
    if not Menu or not Menu.ModifyMenu then return end
    local list = page.RecipeList
    local function rowRecipeID(owner)
        local scrollBox = list.ScrollBox
        if not UI.window:IsVisible() or not scrollBox or not scrollBox.FindFrame
            or not owner or not owner.GetElementData then return end
        local node = owner:GetElementData()
        if not node or scrollBox:FindFrame(node) ~= owner then return end
        local _, id = nativeRecipeInfo(node)
        return id
    end
    Menu.ModifyMenu("MENU_PROFESSIONS_RECIPE_LIST_FAVORITE", function(owner, root)
        local id = rowRecipeID(owner)
        if not id or not FC.Catalog.Get(id) then return end
        local meta = UI.saved.recipeMeta[tostring(id)]
        local function editField(key, labelText, prompt, limit)
            root:CreateButton(labelText, function()
                if rowRecipeID(owner) ~= id then return end
                placeMenu(owner, id)
                editRecipeMeta(id, key, prompt, limit)
            end)
        end
        root:CreateDivider()
        editField("group", meta and meta.group and L.recipeGroup:format(meta.group) or L.group, L.groupHint, 48)
        editField("note", L.editNote, L.note, 160)
    end)
    Menu.ModifyMenu("MENU_PROFESSIONS_FILTER", function(owner, root)
        if not owner or owner ~= list.FilterDropdown or not UI.window:IsVisible()
            or not next(UI.saved.recipeMeta) then return end
        local scrollBox = list.ScrollBox
        local tree = scrollBox and scrollBox.GetDataProvider and scrollBox:GetDataProvider()
        if not tree or not tree.EnumerateEntireRange then return end
        local names, groups, seen = {}, {}, {}
        for _, node in tree:EnumerateEntireRange() do
            local _, id = nativeRecipeInfo(node)
            local meta = id and UI.saved.recipeMeta[tostring(id)]
            local recipe = meta and meta.group and FC.Catalog.Get(id)
            if recipe and not seen[id] then
                local name = meta.group
                if not groups[name] then
                    groups[name] = {}
                    names[#names + 1] = name
                end
                groups[name][#groups[name] + 1], seen[id] = recipe, true
            end
        end
        if #names == 0 then return end
        table.sort(names)
        local menu = root:CreateButton(L.customGroups)
        menu:SetScrollMode(220)
        for _, name in ipairs(names) do
            local submenu = menu:CreateButton(name)
            submenu:SetScrollMode(220)
            for _, recipe in ipairs(groups[name]) do
                submenu:CreateButton(recipeName(recipe), function() selectNativeRecommendation(page, recipe) end)
            end
        end
    end)
end

showRecipeMenu = function(row, recipeId)
    local menu = UI.menu
    if menu:IsShown() and menu.owner == row and menu.recipeId == recipeId then menu:Hide(); return end
    local meta = UI.saved.recipeMeta[tostring(recipeId)] or {}
    openMenu(row, {
        {meta.favorite and L.unfavorite or L.favorite, function()
            saveRecipeMeta(recipeId, "favorite", not meta.favorite and true or nil)
        end},
        {L.group, function() editRecipeMeta(recipeId, "group", L.groupHint, 48) end},
        {L.editNote, function() editRecipeMeta(recipeId, "note", L.note, 160) end},
    }, recipeId)
end

local function showNodeMenu(node, path, owner)
    if UI.recipeSelectionPending then return end
    if UI.menu:IsShown() and UI.menu.owner == owner and UI.nodePath == path then
        UI.menu:Hide()
        return
    end
    UI.nodePath = path
    inspect()
    local actions = {}
    local auction = activeAuctionHouse()
    if auction and node == currentTree() and #draftAuctionEntries() > 0 then
        actions[#actions + 1] = {L.shoppingThisCraft, function()
            if activeAuctionHouse() == auction then openShoppingAt(auction, nil, true) end
        end}
    end
    if UI.job and auction then
        for _, entry in ipairs(FC.Queue.GetRequirements(UI.job)) do
            if entry.itemID == node.itemID and auctionEntry(entry, true) then
                actions[#actions + 1] = {entry.kind == "vendor" and L.shoppingFindOffer or L.auctionShopping, function()
                    showAuctionRequirement(entry)
                end}
                break
            end
        end
    end
    if node ~= currentTree() then
        local producers = UI.catalog.byOutput[node.itemID] or {}
        if not UI.job and UI.preview and not UI.preview.inspectionOnly then
            local choices = UI.saved.choices[tostring(UI.selectedRecipeId)]
            local choice = choices and (choices[node.itemID] or choices[tostring(node.itemID)])
            for _, source in ipairs(availableSources(node)) do
                local key = source
                local name = (source == (choice and choice.source or "Auto") and "> " or "") .. L[source]
                actions[#actions + 1] = {name, function() chooseSource(node, key) end}
            end
            if #producers > 1 then
                actions[#actions + 1] = {L.alternative, function() chooseSource(node, "next") end}
            end
        end
        if #producers > 0 then
            local recipeID = node.recipeId or producers[1]
            local canOpen = not UI.forever or isOpenProfession(UI.catalog.recipesById[recipeID])
            actions[#actions + 1] = {canOpen and L.navigate or L.inspectRecipe, function() selectRecipe(recipeID, true) end}
        end
    end
    local task = graphTask(node)
    if task then
        actions[#actions + 1] = {L.craftThis, function()
            local _, message = dispatchCraft(UI.job, task)
            notify(message)
        end}
    end
    if #UI.history > 0 then
        actions[#actions + 1] = {L.back, function() selectRecipe(table.remove(UI.history), false) end}
    end
    openMenu(owner, actions)
end

local function cycle(values, field)
    local pref = preferences()
    local current = 1
    for i, value in ipairs(values) do if pref[field] == value then current = i; break end end
    pref[field], pref.scroll = values[current % #values + 1], 0
    UI.Refresh()
end

local function foreverLevel(page)
    local base = page:GetFrameLevel() + 30
    local prices = _G.AuctionatorCraftingInfoProfessionsFrame
    if prices and prices.GetParent and prices:GetParent() == page.SchematicForm and prices.GetFrameLevel then
        return math.max(base, prices:GetFrameLevel() + 30)
    end
    return base
end

local function createWorkspace(parent, top, nativeList)
    local content = CreateFrame("Frame", nil, parent)
    if nativeList then content:SetPoint("TOPLEFT", nativeList, "TOPRIGHT", 4, 0)
    else content:SetPoint("TOPLEFT", 5, top) end
    content:SetPoint("BOTTOMRIGHT", UI.classic and -CLASSIC_RAIL_INSET or -6, 5)
    content:SetFrameLevel(nativeList and foreverLevel(parent) or parent:GetFrameLevel() + 30)
    if content.SetClipsChildren then content:SetClipsChildren(true) end
    tint(content, 0.112, 0.089, 0.069)
    if nativeList then professionArt(content) end
    content:EnableMouse(true)
    UI.window = content

    local work = CreateFrame("Frame", nil, content)
    work:SetPoint("TOPLEFT", nativeList and 9 or 194, -8)
    work:SetPoint("BOTTOMRIGHT", -8, 7)
    local native = button(work, L.native, 72, function() UI.ShowNative() end)
    native:SetPoint("TOPRIGHT", 0, 0)
    UI.status = label(work)
    UI.status:SetPoint("BOTTOMLEFT", 1, 2)
    UI.status:SetPoint("BOTTOMRIGHT", -1, 2)
    UI.status:SetHeight(26)

    local plan = CreateFrame("Frame", nil, work)
    UI.plan = plan
    plan:SetPoint("TOPLEFT", 0, -25)
    plan:SetPoint("BOTTOMRIGHT", 0, 32)
    if plan.SetClipsChildren then plan:SetClipsChildren(true) end
    UI.graph = FC.Graph.New(plan, itemInfo, showNodeMenu,
        function(owner, node) tooltip(owner, node.itemID, nil, node) end)
    UI.graph.compact = nativeList ~= nil or UI.classic ~= nil
    UI.graph.frame:SetPoint("TOPLEFT", plan, "TOPLEFT", 0, 0)
    UI.graph.frame:SetPoint("TOPRIGHT", plan, "TOPRIGHT", 0, 0)
    UI.graph.onExtentChanged = UI.RenderQueue
    UI.emptyPlan = label(plan, L.pickRecipe)
    UI.emptyPlan:SetPoint("TOPLEFT", UI.graph.frame, "TOPLEFT", 13, -14)
    UI.emptyPlan:SetPoint("TOPRIGHT", UI.graph.frame, "TOPRIGHT", -13, -14)
    UI.recipeAuctionator = button(work, L.auctionatorButton, 88, searchCurrentRecipe)
    UI.recipeAuctionator:SetPoint("TOPLEFT")
    UI.auctionPriceButton = button(work, L.auctionCheckPrices, 94, checkAuctionPrices)
    place(UI.auctionPriceButton, UI.recipeAuctionator, 2)
    updateRecipeAuctionator()
    UI.menu = CreateFrame("Frame", nil, nativeList and plan or work)
    UI.menu:SetSize(163, 30)
    UI.menu:EnableMouse(true)
    UI.menu.actions = {}
    tint(UI.menu, 0.172, 0.127, 0.082)
    UI.menu:Hide()

    local estimate = CreateFrame("Button", nil, plan)
    UI.estimate = estimate
    estimate:SetHeight(28)
    estimate:RegisterForClicks("RightButtonUp")
    estimate:SetScript("OnClick", showPricingMenu)
    UI.planCost = label(estimate)
    UI.planProfit = label(estimate)
    UI.planCooldown = label(estimate)
    UI.planCost:SetPoint("TOPLEFT")
    UI.planProfit:SetPoint("TOPLEFT", 0, -13)
    UI.planProfit:SetPoint("TOPRIGHT", 0, -13)
    UI.planCooldown:SetPoint("TOPRIGHT")
    UI.planCooldown:SetWidth(136)
    UI.planCooldown:SetJustifyH("RIGHT")
    for _, field in ipairs({UI.planCost, UI.planProfit, UI.planCooldown}) do
        field:SetWordWrap(false)
    end
    estimate:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.planEconomicsHint)
        if UI.planSummary and UI.planSummary ~= "" then GameTooltip:AddLine(UI.planSummary) end
        if UI.planCostDetail then GameTooltip:AddLine(UI.planCostDetail) end
        if UI.planObjective then GameTooltip:AddLine(UI.planObjective) end
        if UI.planSaleDetail then GameTooltip:AddLine(UI.planSaleDetail) end
        if UI.planSurplusDetail then GameTooltip:AddLine(UI.planSurplusDetail) end
        if UI.planProfitDetail then GameTooltip:AddLine(UI.planProfitDetail) end
        addPriceEvidence(UI.planPrice, UI.planPriceUnknown)
        if UI.planCooldown:IsShown() then GameTooltip:AddLine(UI.planCooldown:GetText()) end
        GameTooltip:AddLine(L.pricingMenuHint, 0.85, 0.78, 0.62)
        GameTooltip:Show()
    end)
    estimate:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local zoomOut = button(work, L.zoomOut, 20, function() UI.graph:Zoom(-0.12) end)
    local zoomIn = button(work, L.zoomIn, 20, function() UI.graph:Zoom(0.12) end)
    local fit = button(work, L.fit, 35, function(_, mouse) UI.graph:Fit(mouse == "RightButton") end)
    UI.fit = fit
    fit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    fit:SetPoint("RIGHT", native, "LEFT", -7, 0)
    zoomIn:SetPoint("RIGHT", fit, "LEFT", -3, 0)
    zoomOut:SetPoint("RIGHT", zoomIn, "LEFT", -3, 0)
    local toolbarWrapped, auctionatorShown
    UI.layoutToolbar = function(width)
        local auctionator = UI.recipeAuctionator:IsShown()
        local checkPrices = UI.auctionPriceButton:IsShown()
        local marketWidth = (auctionator and UI.recipeAuctionator:GetWidth() or 0)
            + (checkPrices and UI.auctionPriceButton:GetWidth() or 0) + (auctionator and checkPrices and 2 or 0)
        local toolsWidth = native:GetWidth() + fit:GetWidth() + zoomIn:GetWidth() + zoomOut:GetWidth() + 13
        local wrap = marketWidth > 0 and width < marketWidth + toolsWidth + 4
        if toolbarWrapped == wrap and auctionatorShown == auctionator then return end
        toolbarWrapped, auctionatorShown = wrap, auctionator
        local offset = wrap and -22 or 0
        UI.recipeAuctionator:SetPoint("TOPLEFT", 0, offset)
        UI.auctionPriceButton:ClearAllPoints()
        if auctionator then place(UI.auctionPriceButton, UI.recipeAuctionator, 2)
        else UI.auctionPriceButton:SetPoint("TOPLEFT", 0, offset) end
        plan:SetPoint("TOPLEFT", 0, wrap and -47 or -25)
    end
    fit:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.outline)
        GameTooltip:Show()
    end)
    fit:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    UI.quantity = edit(plan, 33, nil, changePreview)
    UI.quantity:SetMaxLetters(4)
    UI.quantity:SetNumeric(true)
    UI.quantity:SetText(tostring(UI.saved.quantity or 1))
    UI.quantity:HookScript("OnTextChanged", function(_, byUser) if byUser then changePreview(true) end end)
    UI.craftOne = button(plan, L.craft, 82, function() craftSelected(false) end)
    UI.craftAll = button(plan, L.craftAll, 82, function() craftSelected(true) end)
    UI.queuePlan = button(plan, L.queue, 82, function() acceptPlan() end)
    for _, control in ipairs({UI.craftOne, UI.craftAll}) do
        control:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self == UI.craftOne and L.craftHint or L.craftAllHint, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        control:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    UI.quantityType = button(plan, UI.saved.quantityMode == "Crafts" and L.craftCount or L.itemCount, 55, function(self)
        if UI.menu:IsShown() and UI.menu.owner == self then UI.menu:Hide(); return end
        local function mode(units, intent)
            UI.saved.quantityMode, UI.saved.intent = units, intent
            self:SetText(units == "Crafts" and L.craftCount or L.itemCount)
            changePreview()
        end
        openMenu(self, {
            {L.itemCount, function() mode("Items", UI.saved.intent) end},
            {L.craftCount, function() mode("Crafts", "additional") end},
            {L.additional, function() mode("Items", "additional") end},
            {L.stockUpTo, function() mode("Items", "stockUpTo") end},
            {L.delivery, function() mode("Items", "delivery") end},
        })
    end)
    UI.quantityType:SetScript("OnEnter", function(self)
        if not GameTooltip or not UI.planSummary or UI.planSummary == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(UI.planSummary, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    UI.quantityType:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local function stepQuantity(delta)
        local current = enteredQuantity() or 1
        local nextCount = math.min(9999, math.max(1, current + delta))
        if enteredQuantity() == nextCount then return end
        UI.quantity:SetText(tostring(nextCount))
        changePreview()
    end
    local steps = CreateFrame("Frame", nil, plan)
    steps:SetSize(94, 18)
    UI.quantityFirst = button(steps, L.zoomOut .. "10", 25, function() stepQuantity(-10) end)
    UI.quantityDown = button(steps, L.zoomOut, 18, function(_, mouse) stepQuantity(mouse == "RightButton" and -10 or -1) end)
    UI.quantityUp = button(steps, L.zoomIn, 18, function(_, mouse) stepQuantity(mouse == "RightButton" and 10 or 1) end)
    UI.quantityLast = button(steps, L.zoomIn .. "10", 25, function() stepQuantity(10) end)
    UI.quantityDown:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI.quantityUp:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI.quantityFirst:SetPoint("LEFT")
    place(UI.quantityDown, UI.quantityFirst, 2)
    place(UI.quantityUp, UI.quantityDown, 2)
    UI.quantityLast:SetPoint("RIGHT")
    for _, control in ipairs({UI.quantityFirst, UI.quantityDown, UI.quantityUp, UI.quantityLast}) do
        control:SetHeight(18)
    end
    plan:HookScript("OnHide", stopCooldownTicker)

    if not nativeList then
        UI.listPane = CreateFrame("Frame", nil, content)
        tint(UI.listPane, 0.095, 0.075, 0.057)
        UI.listPane:SetPoint("TOPLEFT", 7, -8)
        UI.listPane:SetPoint("BOTTOMLEFT", 7, 8)
        UI.listPane:SetWidth(248)
        work:ClearAllPoints()
        work:SetPoint("TOPLEFT", UI.listPane, "TOPRIGHT", 9, 0)
        work:SetPoint("BOTTOMRIGHT", -8, 7)
        UI.listPane:EnableMouseWheel(true)
        UI.listPane:SetScript("OnMouseWheel", function(_, delta) listScroll(-delta) end)
        UI.search = edit(UI.listPane, 135, L.search, function() end)
        UI.search:SetPoint("TOPLEFT", 9, -4)
        UI.search:SetPoint("TOPRIGHT", -5, -4)
        UI.search:HookScript("OnTextChanged", function(self, user)
            if not user then return end
            local pref = preferences()
            pref.search, pref.scroll = self:GetText(), 0
            UI.Schedule(true)
        end)
        UI.filter = button(UI.listPane, L.all, 88, function()
            cycle({"all", "favorites", "fromBags", "best", "sell"}, "filter")
        end)
        UI.filter:SetPoint("TOPLEFT", 4, -28)
        UI.sort = button(UI.listPane, L.sortName, 65, function() cycle({"name", "difficulty", "cost"}, "sort") end)
        place(UI.sort, UI.filter)
        UI.groups = button(UI.listPane, L.allGroups, 130, function()
            local current, names = preferences(), UI.groupNames or {}
            local index = 0
            for i, name in ipairs(names) do if current.group == name then index = i; break end end
            current.group, current.scroll = names[index + 1], 0
            UI.Refresh()
        end)
        UI.groups:SetPoint("TOPLEFT", 4, -52)
        UI.groups:SetPoint("TOPRIGHT", -5, -52)
        UI.listProgress = label(UI.listPane)
        UI.listProgress:SetPoint("BOTTOMLEFT", 6, 2)
        UI.listProgress:SetPoint("BOTTOMRIGHT", -48, 2)
        UI.listProgress:SetWordWrap(false)
        UI.recipeLater = button(UI.listPane, "▼", 18, function() listScroll(1) end)
        UI.recipeLater:SetSize(18, 16)
        UI.recipeLater:SetPoint("BOTTOMRIGHT", -4, 0)
        UI.recipeEarlier = button(UI.listPane, "▲", 18, function() listScroll(-1) end)
        UI.recipeEarlier:SetSize(18, 16)
        UI.recipeEarlier:SetPoint("RIGHT", UI.recipeLater, "LEFT", -2, 0)
    end

    local queue = CreateFrame("Frame", nil, plan, "BackdropTemplate")
    queue:SetPoint("BOTTOMLEFT", 0, QUEUE_ACTION_HEIGHT)
    queue:SetPoint("TOPRIGHT", UI.graph.frame, "BOTTOMRIGHT", 0, -GRAPH_GAP)
    UI.queuePane = queue
    tint(queue, 0.055, 0.045, 0.034)
    if queue.SetBackdrop then
        queue:SetBackdrop({edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 9})
        queue:SetBackdropBorderColor(0.60, 0.44, 0.26, 0.9)
    end
    queue:EnableMouseWheel(true)
    queue:SetScript("OnMouseWheel", function(_, delta) queueScroll(-delta) end)
    queue:Hide()
    local function cancelQueueOrder(job, group)
        local selected, detail = UI.job == job, UI.queueDetailJob == job
        local ok, reason
        if group then
            for _, member in ipairs(group.jobs) do
                selected = selected or UI.job == member
                detail = detail or UI.queueDetailJob == member
            end
            ok, reason = FC.Queue.CancelGroup(group.jobs)
        else
            ok, reason = FC.Queue.Cancel(job.id)
        end
        if not ok then notify(reason); return end
        if detail then UI.queueDetailJob = nil end
        if selected then changePreview() end
    end
    local function manageQueue(self, job, group)
        if UI.menu:IsShown() and UI.menu.owner == self then UI.menu:Hide(); return end
        local actions = {{canRetryBlockedCraft(job) and L.retryBlockedCraft or L.review, function() review(job) end}}
        if job then
            if job.status == "paused" or job.status == "queued" then
                actions[#actions + 1] = {L.moveUp, function() FC.Queue.Move(job.id, -1) end}
                actions[#actions + 1] = {L.moveDown, function() FC.Queue.Move(job.id, 1) end}
                actions[#actions + 1] = {job.status == "paused" and L.resume or L.pause,
                    function() FC.Queue.SetPaused(job.id, job.status ~= "paused") end}
            end
            local editable, reason = FC.Queue.CanReplace(job)
            if job.rootRecipeId and not (job.goal and job.goal.demandId) and (editable or reason) then
                actions[#actions + 1] = {reason == "reviseAfterDelivery" and L.reviseCollect or L.revise, function()
                    if not editable then notify(L[reason]); return end
                    draftRemaining(job)
                end}
            end
            local taskJob, task = FC.Queue.NextTask(UI.professionID, job)
            if task and taskJob == job then
                actions[#actions + 1] = {L.queueInspectCraft, function() queueSelection({job = job, task = task}) end}
            end
            local requirement = FC.Queue.GetRequirements(job)[1]
            if requirement then
                actions[#actions + 1] = {L.queueInspectMaterials,
                    function() queueSelection({job = job, entry = requirement}) end}
            end
            if group and #group.jobs > 1 then
                for index, member in ipairs(group.jobs) do
                    if member == job then
                        local nextIndex = index % #group.jobs + 1
                        local nextOrder = group.jobs[nextIndex]
                        actions[#actions + 1] = {L.queueNextOrder:format(nextIndex, #group.jobs), function()
                            if not activeQueueJob(nextOrder) then return end
                            queueSelection({job = nextOrder})
                        end}
                        break
                    end
                end
                actions[#actions + 1] = {L.queueCancelOrder, function() cancelQueueOrder(job) end}
            end
        end
        openMenu(self, actions)
    end
    UI.queueLater = button(queue, "v", 18, function() queueScroll(1) end)
    UI.queueLater:SetSize(18, 17)
    UI.queueLater:SetPoint("BOTTOMRIGHT", -2, 1)
    UI.queueEarlier = button(queue, "^", 18, function() queueScroll(-1) end)
    UI.queueEarlier:SetSize(18, 17)
    UI.queueEarlier:SetPoint("TOPRIGHT", -2, -1)

    UI.process = button(plan, L.processShort, 67, processNext)
    UI.process:SetPoint("BOTTOMLEFT")
    UI.queueClear = button(plan, L.queueClear, 45, clearQueue)
    place(UI.queueClear, UI.process, 4)
    UI.graphShoppingButton = button(plan, L.auctionShopping, 97, function() toggleShoppingList() end)
    UI.graphShoppingButton:SetPoint("BOTTOMRIGHT")
    UI.queueToggle = button(plan, L.queued, 37, function(self, mouse)
        if mouse == "RightButton" then manageQueue(self, UI.job) else toggleQueue() end
    end)
    UI.queueToggle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI.queueToggle:SetPoint("RIGHT", UI.graphShoppingButton, "LEFT", -4, 0)

    UI.craftAll:SetPoint("BOTTOMLEFT", plan, "BOTTOMLEFT", 0, 23)
    UI.craftOne:SetPoint("BOTTOMRIGHT", plan, "BOTTOMRIGHT", 0, 23)
    UI.queuePlan:SetPoint("BOTTOMRIGHT", plan, "BOTTOMRIGHT", 0, 44)
    UI.queueAll = button(plan, L.queueAll, 82, queueAllSelected)
    UI.queueAll:SetPoint("BOTTOMLEFT", plan, "BOTTOMLEFT", 0, 44)
    UI.craftNext = button(plan, L.craftNext, 94, function()
        local followup, shown = professionFollowup(), UI.shownProfessionAction
        if shown and shown.canAct == true and not shown.nativeCraftPrepared
            and followup and followup.ClickProfessionWindowAction then
            followup.ClickProfessionWindowAction(shown)
        end
    end)
    UI.craftNext:SetHeight(18)
    UI.craftNext:SetPoint("BOTTOM", plan, "BOTTOM", 0, 44)
    UI.craftNext:Hide()
    steps:SetPoint("BOTTOM", plan, "BOTTOM", 0, 23)
    UI.quantityType:SetPoint("BOTTOMRIGHT", plan, "BOTTOM", 8, 65)
    place(UI.quantity, UI.quantityType, 6)
    local craftControls = {UI.queueAll, UI.queuePlan, UI.craftAll, UI.craftOne, UI.quantityType}
    for _, control in ipairs(craftControls) do control:SetHeight(18) end
    local function layoutCraftControls(_, width)
        local actionWidth = math.max(62, math.min(104, math.floor((width - 106) / 2)))
        for i = 1, 4 do craftControls[i]:SetWidth(actionWidth) end
        UI.layoutToolbar(width)
        UI.RenderQueue()
    end
    plan:HookScript("OnSizeChanged", layoutCraftControls)
    layoutCraftControls(plan, plan:GetWidth())
    estimate:SetPoint("BOTTOMLEFT", plan, "BOTTOMLEFT", 2, 89)
    estimate:SetPoint("BOTTOMRIGHT", plan, "BOTTOMRIGHT", -2, 89)

    local function hint(control, text)
        control:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            local value = type(text) == "function" and text() or text
            if type(value) ~= "string" then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(value)
            GameTooltip:Show()
        end)
        control:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    hint(UI.queueAll, L.queueAllHint)
    hint(UI.queueToggle, L.queueToggleHint)
    hint(UI.process, function()
        local recovery = UI.carriedRecovery
        if recovery then
            if recovery.remainingExecutions == 0 then return L.queueResumeFinishHint:format(recovery.quantity) end
            return L.queueResumeHint:format(recovery.quantity)
        end
        if UI.recoveryProfession then return L.openRecoveryProfessionHint:format(UI.recoveryProfession) end
        local stopped = queueReviewJob()
        if stopped and not canReplanFromBags(stopped) then return L.processStoppedHint end
        if FC.target == "forever" then return L.processQueueHint end
    end)
    hint(UI.craftNext, function()
        local action = UI.shownProfessionAction
        if not action then return end
        local selection = action.logistics
        if selection and selection.resume then
            if selection.remainingOutput == 0 then return L.queueResumeFinishHint:format(selection.carriedOutput) end
            return L.queueResumeHint:format(selection.carriedOutput)
        end
        if action.nativeCraftPrepared then return L.craftNextPreparedHint:format(action.nativeCraftPrepared) end
        return L.craftNextHint:format(action.name or "")
    end)
    UI.ensureQueueRow = function(index)
        local row = CreateFrame("Button", nil, queue)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, mouse)
            local line = self.line
            if not line or not line.job then return end
            if mouse == "RightButton" then
                if UI.job ~= line.job then queueSelection(line) end
                manageQueue(self, line.job, line)
            else queueSelection(line) end
        end)
        row:SetHeight(QUEUE_ROW_HEIGHT)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 2, 0)
        row.caption = label(row)
        row.caption:SetPoint("TOPRIGHT", -42, -3)
        row.caption:SetWordWrap(false)
        row.progress = label(row, nil, "GameFontHighlightSmall")
        row.progress:SetPoint("TOPRIGHT", -42, -3)
        row.progress:SetWordWrap(false)
        row:SetScript("OnEnter", function(self)
            if not GameTooltip or not self.line then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.caption:GetText())
            if self.message then GameTooltip:AddLine(self.message, 1, 1, 1, true) end
            GameTooltip:AddLine(L.queueSelectHint, 0.95, 0.82, 0.58, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        row.selected = row:CreateTexture(nil, "BACKGROUND")
        row.selected:SetAllPoints()
        if row.selected.SetColorTexture then row.selected:SetColorTexture(0.58, 0.41, 0.17, 0.32)
        else row.selected:SetTexture(0.58, 0.41, 0.17, 0.32) end
        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        if highlight.SetColorTexture then highlight:SetColorTexture(0.84, 0.67, 0.4, 0.15)
        else highlight:SetTexture(0.84, 0.67, 0.4, 0.15) end
        row.detail = button(row, "…", 18, function(self)
            local line = row.line
            if not line then return end
            if UI.job ~= line.job then queueSelection(line) end
            manageQueue(self, line.job, line)
        end)
        row.detail:SetSize(18, 17)
        row.detail:SetPoint("TOPRIGHT", -19, -1)
        hint(row.detail, L.queueJobActions)
        row.remove = button(row, "X", 18, function()
            local group = row.line
            if not group then return end
            cancelQueueOrder(group.job, #group.jobs > 1 and group or nil)
        end)
        row.remove:SetSize(18, 17)
        row.remove:SetPoint("TOPRIGHT", 0, -1)
        hint(row.remove, function()
            return row.line and #row.line.jobs > 1 and L.queueCancelRow or L.cancel
        end)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta) queueScroll(-delta) end)
        UI.queueRows[index] = row
    end
    content:HookScript("OnShow", function()
        refreshProfessionAction()
        refreshRestockProfessionLayer()
        UI.Schedule()
    end)
    content:HookScript("OnHide", function()
        UI.pendingDraft, UI.recipeSelectionPending = nil, nil
        paintStatus()
        if UI.recipeSkill then UI.recipeSkill:Hide() end
        refreshProfessionAction()
        refreshRestockProfessionLayer()
        cancelCooldownWake()
        stopCooldownTicker()
        trackCraftRequirement(nil)
    end)
end

local function attachResize(frame, minWidth, minHeight, native)
    local grip = CreateFrame("Button", nil, UI.window)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetSize(16, 16)
    grip:SetFrameLevel(UI.window:GetFrameLevel() + 3)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    UI.resizeGrip = grip

    local active, changing, pending
    local nativeWidth, nativeHeight, appliedWidth, appliedHeight
    local drag
    local function canResize()
        return not (InCombatLockdown and InCombatLockdown())
    end
    local function near(a, b)
        return a and b and math.abs(a - b) < 0.75
    end
    local function updatePanelPosition()
        if native and frame:IsVisible() and UpdateUIPanelPositions then UpdateUIPanelPositions(frame) end
    end
    local function setSize(width, height)
        local oldWidth, oldHeight = frame:GetSize()
        if near(oldWidth, width) and near(oldHeight, height) then return false end
        changing = true
        frame:SetSize(width, height)
        changing = false
        return not near(oldWidth, width)
    end
    local function apply(width, height)
        local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
        local right = UIParent:GetWidth() * ratio - (frame:GetLeft() or 0)
        local top = frame:GetTop() or UIParent:GetHeight() * ratio
        local maxWidth = math.max(minWidth, math.min(1600, right - (native and 44 or 8)))
        local maxHeight = math.max(minHeight, math.min(1100, top - 8))
        appliedWidth = math.floor(math.max(minWidth, math.min(maxWidth, width)) + 0.5)
        appliedHeight = math.floor(math.max(minHeight, math.min(maxHeight, height)) + 0.5)
        return setSize(appliedWidth, appliedHeight)
    end
    local function finish(save)
        if not drag then return end
        local start = drag
        drag = nil
        grip:SetScript("OnUpdate", nil)
        local width, height = frame:GetSize()
        if save and not (near(width, start.width) and near(height, start.height)) then
            UI.saved.workbenchSize = {width = width, height = height}
            if not near(width, start.width) then updatePanelPosition() end
        end
    end
    local function updateDrag()
        if not canResize() then finish(false); return end
        local x, y = GetCursorPosition()
        if x == drag.x and y == drag.y and not drag.moved then return end
        drag.moved = true
        local scale = frame:GetEffectiveScale()
        apply(drag.width + (x - drag.x) / scale, drag.height + (drag.y - y) / scale)
    end
    grip:SetScript("OnMouseDown", function(_, mouse)
        if mouse ~= "LeftButton" or not active or not canResize() or not GetCursorPosition then return end
        local x, y = GetCursorPosition()
        local width, height = frame:GetSize()
        drag = {x = x, y = y, width = width, height = height}
        grip:SetScript("OnUpdate", function()
            updateDrag()
            if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then finish(true) end
        end)
    end)
    grip:SetScript("OnMouseUp", function(_, mouse)
        if mouse ~= "LeftButton" or not drag then return end
        updateDrag()
        finish(true)
    end)
    grip:SetScript("OnHide", function() finish(false) end)
    grip:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.resizeWorkbench)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local function sync(show)
        active = show
        if not show then finish(false) end
        if not canResize() then return end
        local width, height = frame:GetSize()
        if not show then
            if nativeWidth then
                local restoreWidth = near(width, appliedWidth) and nativeWidth or width
                local restoreHeight = near(height, appliedHeight) and nativeHeight or height
                nativeWidth, nativeHeight, appliedWidth, appliedHeight = nil, nil, nil, nil
                if setSize(restoreWidth, restoreHeight) then updatePanelPosition() end
            end
        elseif not drag then
            if native and not nativeWidth then nativeWidth, nativeHeight = width, height end
            local saved = UI.saved.workbenchSize
            if type(saved) == "table" and type(saved.width) == "number" and saved.width > 0
                and type(saved.height) == "number" and saved.height > 0 then
                if apply(saved.width, saved.height) then updatePanelPosition() end
            end
        end
    end
    frame:HookScript("OnSizeChanged", function(_, width, height)
        if not native or not active or changing or drag or not nativeWidth then return end
        if near(width, appliedWidth) and near(height, appliedHeight) then return end
        if not near(width, appliedWidth) then nativeWidth = width end
        if not near(height, appliedHeight) then nativeHeight = height end
        if pending or not appliedWidth then return end
        pending = true
        local function reapply()
            pending = nil
            if active then sync(true) end
        end
        if C_Timer and C_Timer.After then C_Timer.After(0, reapply) else reapply() end
    end)
    return sync
end

local function refreshForeverLayer()
    if not UI.forever then return end
    local base = foreverLevel(UI.forever.CraftingPage)
    if UI.window:GetFrameLevel() ~= base then
        UI.window:SetFrameLevel(base)
        UI.resizeGrip:SetFrameLevel(base + 3)
        refreshRestockProfessionLayer()
    end
end

local function readNativeRecipe(explicitSelection)
    if not UI.forever then return end
    local id = nativeSelectedRecipeID()
    if not id then return end
    if UI.dispatching then
        UI.nativeRecipeId = id
        return
    end
    local busy = FC.Execution.IsBusy and FC.Execution.IsBusy()
    if busy and not explicitSelection then return end
    local changed = id ~= UI.nativeRecipeId
    UI.nativeRecipeId = id
    if busy and not changed then return end
    if not changed and UI.selectedRecipeId and not explicitSelection then return end
    if UI.job and not explicitSelection then return end
    if explicitSelection and UI.selectedRecipeId == id and (UI.preview and UI.preview.tree or UI.recipeSelectionPending)
        and not (UI.job or UI.replaces or UI.demandId or UI.pendingNativeRecipeID
            or UI.nodePath and UI.nodePath:find("/", 1, true)) then return end
    UI.selectedRecipeId, UI.nodePath, UI.replaces = id, nil, nil
    if explicitSelection then
        UI.pendingNativeRecipeID = nil
        clearDraft()
        return true
    end
end

local function applyPendingNativeRecipe()
    if not UI.pendingNativeRecipeID or UI.dispatching or (FC.Execution.IsBusy and FC.Execution.IsBusy()) then return end
    local pending = UI.pendingNativeRecipeID
    UI.pendingNativeRecipeID = nil
    local recipe = not UI.job and selectedRecipe()
    if recipe and recipe.recipeID == pending then selectNativeRecipe(recipe) end
end

function UI.Refresh(listOnly, selectionOnly, deferred)
    if not UI.window or not UI.window:IsVisible() then return end
    if not listOnly then
        UI.pendingRefresh, UI.recipeSelectionPending, UI.pendingDraft = nil, nil, nil
        paintStatus()
    end
    refreshForeverLayer()
    UI.catalog = FC.Catalog.Snapshot()
    if UI.forever then
        applyPendingNativeRecipe()
        readNativeRecipe(false)
    end
    if UI.classic then
        refreshList()
        if UI.classic and not UI.job and not UI.selectedRecipeId and UI.list and UI.list[1] then
            UI.selectedRecipeId = UI.list[1].recipe.id
            preferences().recipeId = UI.selectedRecipeId
        end
        UI.RenderRecipes()
    end
    if UI.forever and FC.RecipeProfit and not selectionOnly then FC.RecipeProfit.Refresh() end
    if not listOnly then
        local function render()
            if not selectionOnly then UI.RenderQueue() end
            inspect()
            if selectionOnly and UI.queuePaintedJob ~= UI.job then UI.RenderQueue() end
            refreshShopping()
        end
        if not UI.job then preview(deferred, render) end
        render()
    end
end

function UI.Schedule(listOnly, nextFrame)
    if not UI.window or not UI.window:IsVisible() then return end
    local draft = UI.pendingDraft
    if not listOnly and not nextFrame and draft and not UI.job and UI.selectedRecipeId == draft.id then
        -- Publish the current search before reading any observations that arrived while it ran.
        draft.refresh = true
        return
    end
    if not listOnly then UI.pendingDraft = nil end
    local pending = UI.pendingRefresh
    if pending and (not nextFrame or pending.nextFrame) then
        pending.full = pending.full or not listOnly
        pending.selectionOnly = pending.selectionOnly and nextFrame == true
        return
    end
    local request = {full = not listOnly or pending and pending.full, nextFrame = nextFrame,
        selectionOnly = nextFrame == true and (not pending or pending.selectionOnly)}
    UI.pendingRefresh = request
    local function execute()
        if UI.pendingRefresh ~= request then return end
        UI.pendingRefresh = nil
        UI.Refresh(not request.full, request.selectionOnly, true)
    end
    if C_Timer and C_Timer.After then C_Timer.After(nextFrame and 0 or 0.12, execute) else execute() end
end

local showOverview, switchClassic

local function classicTab(parent, onClick)
    local tab = CreateFrame("CheckButton", nil, parent)
    tab:RegisterForClicks("LeftButtonUp")
    tab:SetScript("OnClick", onClick)
    local backing = tab:CreateTexture(nil, "BACKGROUND")
    backing:SetAllPoints()
    backing:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
    if backing.SetTexCoord then backing:SetTexCoord(0, 0.66, 0.16, 0.82) end
    tab.icon = tab:CreateTexture(nil, "ARTWORK")
    tab.icon:SetPoint("TOPLEFT", 4, -4)
    tab.icon:SetPoint("BOTTOMRIGHT", -5, 4)
    if tab.icon.SetTexCoord then tab.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
    tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    tab:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    if tab.SetCheckedTexture then tab:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight", "ADD") end
    tab:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        local prof = self.prof
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(prof and prof.name or L.overview)
        if prof and prof.rank and prof.maxRank then
            GameTooltip:AddLine(tostring(prof.rank) .. "/" .. tostring(prof.maxRank), 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return tab
end

local function selectClassicTab()
    local overview = UI.book.frame:IsShown()
    local prof = UI.classicActiveProfession
    UI.overviewTab:SetChecked(overview)
    for _, tab in ipairs(UI.professionTabs) do
        tab:SetChecked(not overview and tab.prof ~= nil and tab.prof == prof)
        if tab.proxy then tab.proxy.Refresh(tab) end
    end
    UI.classicTitle:SetText(overview and L.overview or prof and prof.name or L.title)
    UI.classicPortrait:SetTexture(overview and CLASSIC_BOOK_ICON or prof and prof.texture or CLASSIC_UNKNOWN_ICON)
    local rank, maximum = prof and tonumber(prof.rank), prof and tonumber(prof.maxRank)
    UI.classicSkillBar:SetShown(not overview)
    UI.classicSkill:SetText(rank and maximum and (rank .. "/" .. maximum) or "")
    if UI.classicSkillBar.SetMinMaxValues then
        UI.classicSkillBar:SetMinMaxValues(0, math.max(1, maximum or 1))
        UI.classicSkillBar:SetValue(rank or 0)
    end
end

local function updateClassicTabs(known, current)
    local profs, tabs = {}, UI.professionTabs
    for _, prof in ipairs(known) do
        if prof.opensTradeSkill ~= false then profs[#profs + 1] = prof end
    end
    UI.classicProfessions, UI.classicActiveProfession = profs, nil
    for index, prof in ipairs(profs) do
        local tab = tabs[index]
        if not tab then
            tab = classicTab(UI.professionRail, function(self) switchClassic(self.prof) end)
            tab:SetPoint("TOP", tabs[index - 1] or UI.overviewTab, "BOTTOM", 0, -3)
            tabs[index] = tab
        end
        tab.prof = prof
        tab.icon:SetTexture(prof.texture or CLASSIC_UNKNOWN_ICON)
        tab:Show()
        if current and tostring(current) == tostring(prof.id) then UI.classicActiveProfession = prof end
        local proxy = Flux and Flux.SecureClickProxy
        if not tab.proxy and prof.spellID and proxy and proxy.Attach and proxy.Refresh then
            tab.proxy = proxy
            proxy.Attach(tab, {
                spell = function() return tab.prof and tab.prof.spellID end,
                enabled = function() return tab.prof ~= nil and tab.prof ~= UI.classicActiveProfession end,
                clicks = "LeftButtonUp",
            })
        end
    end
    for index = #profs + 1, #tabs do
        local tab = tabs[index]
        tab.prof = nil
        tab:Hide()
    end
    layoutClassicTabs()
    if current and UI.book.frame:IsShown() and tostring(current) ~= tostring(UI.overviewProfession) then
        showOverview(false)
    else selectClassicTab() end
    UI.book:Render(profs, FC.Catalog.Snapshot(), current)
end

local function updateProfession()
    local profs = UI.classic and UI.classic:IsVisible() and FC.Clients.ListProfessions() or nil
    local current, sourceCounter = FC.Clients.CurrentProfessionID(profs)
    local sameSession = current ~= nil and tostring(current) == tostring(UI.professionID)
        and sourceCounter == UI.professionSourceCounter
    UI.professionSourceCounter = sourceCounter
    if profs then updateClassicTabs(profs, current) end
    if not current then
        if UI.classic and UI.professionID then
            UI.professionID, UI.listRevision = nil, nil
            if not UI.job then UI.selectedRecipeId, UI.nodePath = nil, nil end
            UI.Schedule()
        end
        notify(L.loading)
        return
    end
    if tostring(current) ~= tostring(UI.professionID) then
        UI.professionID, UI.listRevision, UI.nativeRecipeId = current, nil, nil
        UI.pendingNativeRecipeID = nil
        if not UI.job then
            UI.selectedRecipeId = not UI.forever and preferences().recipeId or nil
            UI.nodePath = nil
        end
    end
    if not sameSession or UI.catalog ~= FC.Catalog.Snapshot()
        or UI.forever and nativeSelectedRecipeID() ~= UI.nativeRecipeId then
        UI.Schedule()
    elseif UI.window and UI.window:IsVisible() then
        updateRecipeSkill(selectedRecipe())
    end
end

local function setNativeCraftDock(page, allowed)
    local work = UI.window
    local minimum = 330
    local width
    if allowed and page.GetRight and UIParent.GetRight then
        local pageRight, screenRight = page:GetRight(), UIParent:GetRight()
        local scale = page:GetEffectiveScale()
        UI.nativeCraftDockWanted = UI.nativeCraftDockWanted or math.max(minimum, work:GetWidth())
        if pageRight and screenRight and scale > 0 then
            local available = screenRight * UIParent:GetEffectiveScale() / scale - pageRight - 12
            local fit = math.min(UI.nativeCraftDockWanted, available)
            if fit >= minimum then width = fit end
        end
    end
    if width ~= UI.nativeCraftDockWidth then
        UI.nativeCraftDockWidth = width
        work:ClearAllPoints()
        if width then
            work:SetPoint("TOPLEFT", page, "TOPRIGHT", 8, 0)
            work:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", width + 8, 5)
        else
            work:SetPoint("TOPLEFT", page.RecipeList, "TOPRIGHT", 4, 0)
            work:SetPoint("BOTTOMRIGHT", -6, 5)
        end
    end
    return width ~= nil
end

local nativeCraftControls = {"SchematicForm", "CreateAllButton", "CreateButton", "CreateMultipleInputBox",
    "ViewGuildCraftersButton"}

local function layoutNativeBackdrop(page, surface)
    if surface.layingOut or not page.GetRegions then return end
    -- Reading a region's size can force layout and fire OnSizeChanged immediately.
    surface.layingOut = true
    if not surface.art then
        for _, region in ipairs({page:GetRegions()}) do
            if region.GetAtlas and region:GetAtlas() == "Profession-Background-Template2" then
                local width, height = region:GetSize()
                if type(width) == "number" and width > 0 and type(height) == "number" and height > 0 then
                    surface.art, surface.width, surface.height = region, width, height
                end
                break
            end
        end
    end
    local pageWidth, pageHeight = page:GetSize()
    local ready = surface.art and type(pageWidth) == "number" and pageWidth > 0
        and type(pageHeight) == "number" and pageHeight > 0
    if ready and UI.coveredNativeSurface == surface then
        -- The fixed-size Camelot atlas starts 3 pixels in and 21 pixels down.
        local width = math.max(1, math.min(surface.width, pageWidth - 3))
        local height = math.max(1, math.min(surface.height, pageHeight - 21))
        local currentWidth, currentHeight = surface.art:GetSize()
        if UI.coveredNativeSurface == surface and (width ~= currentWidth or height ~= currentHeight) then
            surface.art:SetSize(width, height)
        end
    elseif not ready and not surface.retriedLayout and C_Timer and C_Timer.After then
        surface.retriedLayout = true
        C_Timer.After(0, function()
            if UI.coveredNativeSurface == surface then layoutNativeBackdrop(page, surface) end
        end)
    end
    surface.layingOut = nil
end

local function syncNativeCraftSurface(page, covered)
    local surface = UI.coveredNativeSurface
    if not covered then
        if not surface then return end
        UI.coveredNativeSurface = nil
        for _, entry in ipairs(surface.controls) do
            entry.control:SetAlpha(entry.alpha)
            if entry.click ~= nil then entry.control:SetMouseClickEnabled(entry.click) end
            if entry.motion ~= nil then entry.control:SetMouseMotionEnabled(entry.motion) end
        end
        if surface.art then surface.art:SetSize(surface.width, surface.height) end
        return
    end
    if not surface then
        surface = {controls = {}}
        UI.coveredNativeSurface = surface
        for _, key in ipairs(nativeCraftControls) do
            local control = page[key]
            if control and control.SetAlpha then
                local entry = {control = control, alpha = control:GetAlpha()}
                surface.controls[#surface.controls + 1] = entry
                control:SetAlpha(0)
                if not control.IsProtected or not control:IsProtected() then
                    if control.IsMouseClickEnabled and control.SetMouseClickEnabled then
                        entry.click = control:IsMouseClickEnabled()
                        control:SetMouseClickEnabled(false)
                    end
                    if control.IsMouseMotionEnabled and control.SetMouseMotionEnabled then
                        entry.motion = control:IsMouseMotionEnabled()
                        control:SetMouseMotionEnabled(false)
                    end
                end
            end
        end
    end
    layoutNativeBackdrop(page, surface)
end

local function syncForever()
    local page = UI.forever.CraftingPage
    local gamepad = InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()
    local hasList = UI.forever:IsVisible() and page:IsShown() and page.RecipeList and page.RecipeList:IsShown()
    local allowed = hasList and not UI.saved.nativeMode and not UI.conflict and not gamepad
    local nativeCraft = UI.nativeCraftMessage ~= nil
    if not nativeCraft then UI.nativeCraftHideWorkbench, UI.nativeCraftDockWanted = nil, nil end
    local embedded = allowed and not nativeCraft
    if UI.resize then UI.resize(embedded) end
    syncNativeCraftSurface(page, embedded)
    local docked = setNativeCraftDock(page, allowed and nativeCraft and not UI.nativeCraftHideWorkbench)
    local show = allowed and (not nativeCraft or docked)
    UI.window:SetShown(show)
    UI.returnButton:SetShown(hasList and (not show or docked) and not gamepad)
    if UI.nativeCraftHint then
        UI.nativeCraftHint:SetText(UI.nativeCraftMessage or "")
        UI.nativeCraftHint:SetShown(not not (hasList and UI.nativeCraftMessage))
        refreshNativeQueueProgress()
    end
    if UI.setRecipeDensity then UI.setRecipeDensity(not not (show and not nativeCraft)) end
    if show then
        refreshForeverLayer()
        updateProfession()
        readNativeRecipe(false)
        UI.Layout()
        if FC.RecipeProfit then FC.RecipeProfit.Refresh() end
    else
        UI.menu:Hide()
        if FC.RecipeProfit then FC.RecipeProfit.Hide() end
    end
end

local function conflictLoaded()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    return isLoaded and (isLoaded("Skillet") or isLoaded("Skillet-Classic") or isLoaded("ATSW"))
end

local function registerNativeShortlists(page)
    local list = page.RecipeList
    local dropdown, scrollBox = list.FilterDropdown, list.ScrollBox
    if not Menu or not Menu.ModifyMenu or not dropdown or not dropdown.RegisterCallback
        or not dropdown.IsMenuOpen or not dropdown.GenerateMenu or not scrollBox or not scrollBox.GetDataProvider
        or not TreeDataProviderConstants then return end

    local modes = {"fromBags", "best", "sell"}
    local shortlist
    local function inputs()
        if not UI.window:IsVisible() then return end
        local profession = FC.Clients.CurrentProfessionID()
        local tree = scrollBox:GetDataProvider()
        if not profession or not tree or not tree.EnumerateEntireRange then return end
        local catalog = FC.Catalog.Snapshot()
        local settings = FC.Logistics.GetSettings()
        local key = table.concat({tostring(profession), catalog.revision, FC.InventoryAdapter.GetRevision(),
            FC.Queue.GetRevision(), UI.marketRevision or 0, settings.provider or "", tostring(settings.allowFallback),
            settings.objective or "", (settings.market or {}).rate or ""}, "\030")
        return key, tree, catalog, profession
    end

    local function start()
        local key, tree, catalog, profession = inputs()
        if not key or (shortlist and shortlist.key == key and shortlist.tree == tree) then return end
        local result = {key = key, tree = tree, lists = {}}
        shortlist = result
        local eligible = {}
        for _, node in tree:EnumerateEntireRange() do
            local _, id = nativeRecipeInfo(node)
            if id then eligible[id] = true end
        end
        local candidates = {}
        for _, row in ipairs(FC.RecipeList.Select(catalog, profession, {}, UI.saved.recipeMeta, recipeName)) do
            if eligible[row.recipe.recipeID] then candidates[#candidates + 1] = row end
        end
        local modeIndex, index, rows = 1, 1, {}
        local costs, skillUps = {}, {}
        local function batch()
            if shortlist ~= result then return end
            local currentKey, currentTree = inputs()
            if currentKey ~= key or currentTree ~= tree then
                shortlist = nil
                if dropdown:IsMenuOpen() then
                    dropdown:GenerateMenu()
                    start()
                end
                return
            end
            local mode, candidate = modes[modeIndex], candidates[index]
            if candidate then
                local row = {recipe = candidate.recipe, name = candidate.name}
                FC.RecipeList.Evaluate(row, mode, "name", catalog)
                if row.score ~= nil then rows[#rows + 1] = row end
                if row.cost then
                    costs[#costs + 1] = {recipe = row.recipe, name = row.name, score = -row.cost, money = row.cost}
                end
                if row.skillRank then
                    skillUps[#skillUps + 1] = {recipe = row.recipe, name = row.name, score = -row.skillRank}
                end
                index = index + 1
            else
                FC.RecipeList.Rank(rows)
                result.lists[mode] = rows
                if mode == "best" then
                    FC.RecipeList.Rank(costs)
                    FC.RecipeList.Rank(skillUps)
                    result.lists.bestCost, result.lists.bestSkill = costs, skillUps
                end
                if dropdown:IsMenuOpen() then dropdown:GenerateMenu() end
                modeIndex, index, rows = modeIndex + 1, 1, {}
            end
            if modeIndex <= #modes then C_Timer.After(0, batch) end
        end
        C_Timer.After(0, batch)
    end

    -- Forever's Filter dropdown owns this tag, including Blizzard's existing filters.
    Menu.ModifyMenu("MENU_PROFESSIONS_FILTER", function(owner, root)
        if owner ~= dropdown or not UI.window:IsVisible() then return end
        if not C_Timer or not C_Timer.After then return end
        local key, tree = inputs()
        local result = shortlist and shortlist.key == key and shortlist.tree == tree and shortlist
        local function addResults(submenu, mode, formatAmount)
            local rows = result and result.lists[mode]
            if not rows or #rows == 0 then
                local empty = submenu:CreateButton(not key and L.recipeUnavailable
                    or not rows and L.hourglass or (_G.NO_RESULTS_FOUND or L.unknown))
                empty:SetEnabled(false)
            else
                for index = 1, math.min(#rows, 8) do
                    local row = rows[index]
                    local value = row.badge or row.money and formatAmount(row.money)
                    local text = value and L.recommendation:format(row.name, value) or row.name
                    submenu:CreateButton(text, function()
                        local currentKey, currentTree = inputs()
                        if currentKey == key and currentTree == tree then
                            selectNativeRecommendation(page, row.recipe)
                        else
                            dropdown:GenerateMenu()
                            start()
                            return MenuResponse.Refresh
                        end
                    end)
                end
            end
        end
        root:CreateDivider()
        addResults(root:CreateButton(L.fromBags), "fromBags")
        local best = root:CreateButton(L.best)
        addResults(best:CreateButton(L.sortProfit), "best", FC.Pricing.FormatProfit)
        addResults(best:CreateButton(L.sortCost), "bestCost", FC.Pricing.FormatCopper)
        addResults(best:CreateButton(L.sortDifficulty), "bestSkill")
        addResults(root:CreateButton(L.sell), "sell", FC.Pricing.FormatProfit)
    end)
    dropdown:RegisterCallback("OnMenuOpen", function()
        if C_Timer and C_Timer.After then start() end
    end, UI)
end

local function attachForever(frame)
    local page = frame and frame.CraftingPage
    if not page or not page.RecipeList or UI.window then return end
    UI.forever = frame
    createRecipeSkillStrip(page, page.RankBar, 5)
    createWorkspace(page, nil, page.RecipeList)
    UI.resize = attachResize(frame, 640, 462, true)
    UI.returnButton = button(page, L.workbench, 91, function() UI.ShowWorkbench(true) end)
    UI.returnButton:SetPoint("TOPRIGHT", -13, -73)
    UI.returnButton:SetFrameLevel(page:GetFrameLevel() + 32)
    UI.nativeCraftHint = label(UI.returnButton, "", "GameFontNormalSmall")
    if page.CreateButton then UI.nativeCraftHint:SetPoint("BOTTOMRIGHT", page.CreateButton, "TOPRIGHT", 0, 4)
    else UI.nativeCraftHint:SetPoint("TOPRIGHT", UI.returnButton, "BOTTOMRIGHT", 0, -4) end
    UI.nativeCraftHint:SetWidth(310)
    UI.nativeCraftHint:SetJustifyH("RIGHT")
    UI.nativeCraftHint:SetWordWrap(true)
    UI.nativeCraftProgress = label(UI.returnButton, nil, "GameFontHighlightSmall")
    UI.nativeCraftProgress:SetPoint("BOTTOMRIGHT", UI.nativeCraftHint, "TOPRIGHT", 0, 3)
    UI.nativeCraftProgress:SetWidth(310)
    UI.nativeCraftProgress:SetJustifyH("RIGHT")
    UI.nativeCraftProgress:SetWordWrap(false)
    if hooksecurefunc and type(page.SetupMultipleInputBox) == "function" and C_Timer and C_Timer.After then
        local pending
        hooksecurefunc(page, "SetupMultipleInputBox", function()
            local recipe = UI.nativeCraftSequence
            local getRecipe = FC.Execution.GetNativeCraftRecipe
            if not recipe or not getRecipe or getRecipe() ~= recipe or pending == recipe then return end
            pending = recipe
            C_Timer.After(0, function()
                if pending ~= recipe then return end
                pending = nil
                UI.RefreshNativeCraftBatch(recipe)
            end)
        end)
    end
    local input = page.CreateMultipleInputBox
    if hooksecurefunc and input and type(input.SetValue) == "function" then
        hooksecurefunc(input, "SetValue", function()
            if UI.nativeCraftPrepared then FC:Emit("NATIVE_CRAFT_PREPARED_CHANGED") end
        end)
    end
    frame:HookScript("OnShow", syncForever)
    frame:HookScript("OnHide", syncForever)
    page:HookScript("OnShow", syncForever)
    page:HookScript("OnHide", syncForever)
    page.RecipeList:HookScript("OnShow", syncForever)
    page.RecipeList:HookScript("OnHide", syncForever)
    if FC.RecipeDensity then UI.setRecipeDensity = FC.RecipeDensity.Attach(page.RecipeList) end
    if FC.RecipeProfit then
        FC.RecipeProfit.Attach(page.RecipeList, function() return UI.window:IsVisible() end)
    end
    registerNativeShortlists(page)
    registerNativeRecipeMetadata(page)
    page:HookScript("OnSizeChanged", function()
        local surface = UI.coveredNativeSurface
        if surface then layoutNativeBackdrop(page, surface) end
        if UI.window:IsVisible() then UI.Layout() end
    end)
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("Professions.CraftingDisplayRefresh", function()
            updateRecipeSkill(selectedRecipe())
        end, UI)
        EventRegistry:RegisterCallback("Professions.RecipeSelected", function(_, selectedPage)
            if selectedPage ~= page then return end
            local sequence = UI.nativeCraftSequence
            if sequence and not UI.dispatching and nativeSelectedRecipeID() ~= sequence.recipeID then
                UI.nativeCraftSequence = nil
                if FC.Execution.HasNativeCraftPending and FC.Execution.HasNativeCraftPending() then
                    FC.Execution.CancelNativeCraft()
                    UI.nativeCraftMessage, UI.nativeCraftJob = nil, nil
                    syncForever()
                end
            end
            if not UI.window:IsVisible() then return end
            if UI.menu then UI.menu:Hide() end
            if readNativeRecipe(true) then scheduleRecipePreview() end
        end, UI)
    end
    syncForever()
end

showOverview = function(overview)
    UI.overviewProfession = overview and UI.professionID or nil
    UI.window:SetShown(not overview)
    UI.book.frame:SetShown(overview)
    UI.resize(not overview)
    selectClassicTab()
    UI.Schedule()
end

switchClassic = function(prof)
    if not prof then return end
    showOverview(false)
    if tostring(prof.id) == tostring(FC.Clients.CurrentProfessionID()) then return end
    local ok, message = FC.Clients.SwitchProfession(prof.id)
    if not ok then notify(message) end
end

local function syncClassic()
    local frame, shell = UI.classicNative, UI.classic
    local visible = frame:IsVisible()
    local gamepad = InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()
    local show = visible and not UI.saved.nativeMode and not UI.conflict and not gamepad
    if show then
        if UI.nativeAlpha == nil then
            UI.nativeAlpha = frame:GetAlpha()
            frame:SetAlpha(0)
        end
        if not shell:IsShown() then
            shell:Show()
            showOverview(false)
        end
        updateProfession()
        UI.Layout()
    else
        if UI.nativeAlpha ~= nil then
            frame:SetAlpha(UI.nativeAlpha)
            UI.nativeAlpha = nil
        end
        UI.resize(false)
        shell:Hide()
        UI.menu:Hide()
        for _, tab in ipairs(UI.professionTabs) do if tab.proxy then tab.proxy.Refresh(tab) end end
    end
    UI.returnButton:SetShown(not not (visible and not show and not gamepad))
end

local function attachClassic(frame)
    if not frame or UI.window then return end
    UI.classicNative = frame
    local shell = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    shell:Hide()
    local width = math.min(862, math.max(730, UIParent:GetWidth() - 50))
    local height = math.min(666, math.max(458, UIParent:GetHeight() - 62))
    shell:SetSize(width, height)
    local scale = math.min(1, (UIParent:GetWidth() - 30) / width, (UIParent:GetHeight() - 30) / height)
    if scale > 0 then shell:SetScale(scale) end
    shell:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    shell:SetClampedToScreen(true)
    shell:SetFrameStrata("DIALOG")
    shell:EnableMouse(true)
    if shell.SetBackdrop then
        shell:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 20,
            insets = {left = 4, right = 4, top = 4, bottom = 4}})
    else tint(shell, 0.09, 0.07, 0.05) end
    UI.classic = shell
    local title = label(shell, L.title, "GameFontNormal")
    title:SetPoint("TOPLEFT", 57, -10)
    title:SetPoint("TOPRIGHT", -CLASSIC_RAIL_INSET, -10)
    title:SetJustifyH("CENTER")
    UI.classicTitle = title
    local portrait = shell:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(36, 36)
    portrait:SetPoint("TOPLEFT", 11, -10)
    portrait:SetTexture(CLASSIC_UNKNOWN_ICON)
    if shell.CreateMaskTexture and portrait.AddMaskTexture then
        local mask = shell:CreateMaskTexture()
        mask:SetAllPoints(portrait)
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        portrait:AddMaskTexture(mask)
    end
    UI.classicPortrait = portrait
    local skill = CreateFrame("StatusBar", nil, shell)
    skill:SetPoint("TOPLEFT", 57, -29)
    skill:SetPoint("TOPRIGHT", -CLASSIC_RAIL_INSET, -29)
    skill:SetHeight(16)
    tint(skill, 0.14, 0.11, 0.08)
    if skill.SetStatusBarTexture then
        skill:SetStatusBarTexture("Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar")
        skill:SetStatusBarColor(0.17, 0.57, 0.62)
        skill:SetMinMaxValues(0, 1)
        skill:SetValue(0)
    end
    UI.classicSkillBar, UI.classicSkill = skill, label(skill, "", "GameFontHighlightSmall")
    UI.classicSkill:SetPoint("CENTER")
    createRecipeSkillStrip(shell, skill, 3)
    local close = CreateFrame("Button", nil, shell, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        if HideUIPanel then HideUIPanel(frame) else frame:Hide() end
    end)
    local rail = CreateFrame("Frame", nil, shell)
    rail:SetPoint("TOPRIGHT", -7, -35)
    rail:SetPoint("BOTTOMRIGHT", -7, 8)
    rail:SetWidth(41)
    UI.professionRail, UI.professionTabs, UI.classicProfessions = rail, {}, {}
    UI.overviewTab = classicTab(rail, function() showOverview(true) end)
    UI.overviewTab:SetPoint("TOP", rail, "TOP", 0, 0)
    UI.overviewTab.icon:SetTexture(CLASSIC_BOOK_ICON)
    createWorkspace(shell, -52)
    UI.resize = attachResize(shell, 730, 458, false)
    UI.book = FC.BookMixin.New(shell, switchClassic, CLASSIC_RAIL_INSET)
    shell:HookScript("OnSizeChanged", function()
        layoutClassicTabs()
        if UI.window:IsVisible() then UI.Layout() end
    end)
    shell:HookScript("OnShow", refreshRestockProfessionLayer)
    shell:HookScript("OnHide", refreshRestockProfessionLayer)
    UI.returnButton = button(frame, L.workbench, 92, function() UI.ShowWorkbench(true) end)
    UI.returnButton:SetPoint("TOPLEFT", frame, "TOPRIGHT", 3, -27)
    UI.returnButton:SetFrameLevel(frame:GetFrameLevel() + 12)
    frame:HookScript("OnShow", syncClassic)
    frame:HookScript("OnHide", syncClassic)
    syncClassic()
end

function UI.ShowNative()
    if not UI.saved then return end
    if UI.forever and UI.nativeCraftMessage and UI.nativeCraftSequence then
        UI.nativeCraftHideWorkbench = true
        syncForever()
        return
    end
    if UI.nativeCraftMessage and FC.Execution.CancelNativeCraft then FC.Execution.CancelNativeCraft() end
    UI.nativeCraftSequence, UI.nativeCraftMessage, UI.nativeCraftJob = nil, nil, nil
    UI.saved.nativeMode = true
    if UI.forever then syncForever()
    elseif UI.classic then syncClassic() end
end

local function revealNativeCraft(message)
    if not UI.forever then return false end
    UI.nativeCraftMessage = message
    syncForever()
    return true
end

local function selectNativeCraftRecipe(recipe)
    if not recipe then return false end
    local dispatching = UI.dispatching
    UI.dispatching = true
    local ok, failure = pcall(function()
        selectNativeRecipe(recipe)
        if isNativeRecipeSelected(recipe) or not isOpenProfession(recipe) then return end
        local page = UI.forever.CraftingPage
        local tradeskill = C_TradeSkillUI
        local info = tradeskill and tradeskill.GetRecipeInfo and tradeskill.GetRecipeInfo(recipe.recipeID)
        if not page.SelectRecipe or type(info) ~= "table" or (issecretvalue and issecretvalue(info.recipeID))
            or info.recipeID ~= recipe.recipeID or info.learned ~= true or info.isRecraft then return end
        local highest = Professions and Professions.GetHighestLearnedRecipe and Professions.GetHighestLearnedRecipe(info)
        if highest and ((issecretvalue and issecretvalue(highest.recipeID)) or highest.recipeID ~= recipe.recipeID) then return end
        -- Initialize the native form even when the current filters hide this recipe.
        page:SelectRecipe(info, true)
    end)
    UI.dispatching = dispatching
    if not ok then
        if geterrorhandler then geterrorhandler()(failure) end
        return false
    end
    return isNativeRecipeSelected(recipe)
end

local function prepareNativeCraftBatch(recipeID, quantity)
    local prepare = FC.Clients.PrepareNativeCraftBatch
    if prepare and quantity then return prepare(recipeID, quantity) end
end

local function announceNativeCraft(text)
    UI.nativeCraftMessage = text
    if UI.nativeCraftHint then UI.nativeCraftHint:SetText(text) end
    notify(text)
    return text
end

local function setPreparedNativeCraft(recipe, quantity)
    if UI.nativeCraftPrepared == recipe and UI.nativeCraftPreparedQuantity == quantity then return end
    UI.nativeCraftPrepared, UI.nativeCraftPreparedQuantity = recipe, quantity
    FC:Emit("NATIVE_CRAFT_PREPARED_CHANGED")
end

local function positiveCraftCount(value)
    return not (issecretvalue and issecretvalue(value)) and type(value) == "number"
        and value > 0 and value < math.huge and value % 1 == 0
end

function UI.GetPreparedNativeCraft()
    local execution = FC.Execution
    local recipe, quantity = UI.nativeCraftPrepared, UI.nativeCraftPreparedQuantity
    if not recipe or UI.nativeCraftSequence ~= recipe or not UI.nativeCraftMessage
        or not execution.GetNativeCraftRecipe or execution.GetNativeCraftRecipe() ~= recipe
        or (execution.IsBusy and execution.IsBusy()) then return end
    local page = UI.forever and UI.forever.CraftingPage
    local create = page and page.CreateButton
    if not page or not page:IsVisible() or not create or not create:IsVisible() or not create.IsEnabled
        or not create:IsEnabled() or not positiveCraftCount(recipe.itemID)
        or not positiveCraftCount(recipe.yield) or not positiveCraftCount(quantity) then return end
    local form = page.SchematicForm
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    if not info or not positiveCraftCount(info.recipeID) or info.recipeID ~= recipe.recipeID then return end
    local trade = C_TradeSkillUI
    if info.canCreateMultiple == false or (trade and trade.HasNoReagentCost
        and trade.HasNoReagentCost(recipe.recipeID) == true) then
        if quantity ~= 1 then return end
    else
        local input = page.CreateMultipleInputBox
        local value = input and input.IsEnabled and input:IsEnabled() and input.GetValue and input:GetValue()
        if not positiveCraftCount(value) or value ~= quantity then return end
    end
    return {itemID = recipe.itemID, quantity = quantity, outputQuantity = quantity * recipe.yield}
end

function UI.RefreshNativeCraftBatch(recipe)
    local getRecipe = FC.Execution.GetNativeCraftRecipe
    if not UI.nativeCraftMessage or UI.nativeCraftSequence ~= recipe or getRecipe() ~= recipe
        or nativeSelectedRecipeID() ~= recipe.recipeID then return end
    local accepted, reason = prepareNativeCraftBatch(recipe.recipeID, recipe.batch)
    if accepted and UI.nativeCraftSequence == recipe and getRecipe() == recipe then
        setPreparedNativeCraft(recipe, accepted)
        return announceNativeCraft(L.execNativeBatchReady:format(accepted))
    end
    if UI.nativeCraftPrepared == recipe then setPreparedNativeCraft(nil) end
    return nil, reason
end

function UI.ShowNativeCraft(message, job)
    focusCraftJob(job)
    UI.nativeCraftJob = job
    setPreparedNativeCraft(nil)
    if not revealNativeCraft(message) then return end
    local getRecipe = FC.Execution.GetNativeCraftRecipe
    local recipe = getRecipe and getRecipe()
    UI.nativeCraftSequence = recipe
    if not recipe then return message end
    local function prepareRecipe()
        if not selectNativeCraftRecipe(recipe) then return nil, L.execNativeSelect:format(recipe.name or recipe.recipeID) end
        if UI.nativeCraftSequence ~= recipe or getRecipe() ~= recipe then return message end
        if not recipe.batch then return message end
        local prepared, reason = UI.RefreshNativeCraftBatch(recipe)
        if UI.nativeCraftSequence ~= recipe or getRecipe() ~= recipe then return message end
        return prepared, reason or L.execNativeAmountUnavailable:format(recipe.batch)
    end
    local ready, failure = prepareRecipe()
    if ready then return ready end
    -- Native recipe data and controls can refresh after selection. Stop when
    -- the player selects something else or the queued handoff changes.
    if C_Timer and type(C_Timer.After) == "function" then
        local function retry(delay, last)
            local selected = nativeSelectedRecipeID()
            C_Timer.After(delay, function()
                if UI.nativeCraftMessage ~= message or UI.nativeCraftSequence ~= recipe or getRecipe() ~= recipe
                    or nativeSelectedRecipeID() ~= selected then return end
                local prepared, reason = prepareRecipe()
                if prepared then return end
                if last then announceNativeCraft(reason) else retry(0.25, true) end
            end)
        end
        retry(0, false)
    else return announceNativeCraft(failure)
    end
    return message
end

function UI.RevealNativeCraft(recipeID, batch)
    if not UI.forever or (issecretvalue and issecretvalue(recipeID))
        or type(recipeID) ~= "number" or recipeID <= 0 or recipeID % 1 ~= 0 then return false end
    local execution = FC.Execution
    if (execution.IsBusy and execution.IsBusy())
        or (execution.HasNativeCraftPending and execution.HasNativeCraftPending()) then return false, "busy" end
    UI.nativeCraftSequence, UI.nativeCraftJob = nil, nil
    if not revealNativeCraft(L.execNativeCreate) then return false end
    if nativeSelectedRecipeID() ~= recipeID
        and not selectNativeCraftRecipe(FC.Catalog.Snapshot().recipesById[recipeID]) then return false end
    if not batch then return true end
    local accepted = prepareNativeCraftBatch(recipeID, batch)
    return accepted ~= nil, accepted
end

function UI.ShowWorkbench(explicit)
    if explicit then
        UI.nativeCraftSequence = nil
        UI.saved.nativeMode, UI.conflict, UI.nativeCraftMessage, UI.nativeCraftJob = false, false, nil, nil
        if FC.Execution.CancelNativeCraft then FC.Execution.CancelNativeCraft() end
    end
    if UI.forever then syncForever()
    elseif UI.classic then syncClassic() end
end

local function attach()
    if FC.target == "forever" then attachForever(_G.ProfessionsFrame)
    else attachClassic(_G.TradeSkillFrame) end
end

local function slash(message)
    message = (message or ""):lower()
    if message == "native" then UI.ShowNative()
    elseif message == "show" then
        attach()
        UI.ShowWorkbench(true)
        if not UI.window or not UI.window:IsVisible() then print(L.openProfession) end
    elseif message == "queue" then
        toggleQueue()
    elseif message == "status" then
        if FC.Diagnostics then FC.Diagnostics.Print() end
    else print(L.help) end
end

local function refreshMarket(force)
    UI.marketRevision = (UI.marketRevision or 0) + 1
    if force == true and FC.RecipeProfit then FC.RecipeProfit.Refresh(true) end
    UI.Schedule()
    if UI.auctionShopping and UI.auctionShopping:IsVisible() and not (UI.window and UI.window:IsVisible())
        and C_Timer and C_Timer.After then C_Timer.After(0, refreshShopping) end
end

local function startMarket()
    local adapter = FC.MarketAdapter or FC.AuctionatorAdapter
    if adapter and adapter.Start then adapter.Start(refreshMarket) end
end

FC:On("READY", function()
    local char = FC.state.char
    char.ui = char.ui or {}
    local saved = char.ui
    saved.perProfession, saved.choices = saved.perProfession or {}, saved.choices or {}
    saved.graphs, saved.recipeMeta = saved.graphs or {}, saved.recipeMeta or {}
    if saved.graphLayout ~= 2 then
        for _, view in pairs(saved.graphs) do
            if type(view) == "table" then view.position = {} end
        end
        saved.graphLayout = 2
    end
    saved.quantityMode = saved.quantityMode or "Items"
    if not L[saved.intent] then saved.intent = "additional" end
    UI.saved = saved
    UI.inventoryReliable = FC.InventoryAdapter.GetStatus().reliable
    local selected
    if type(saved.queueJobId) == "number" then selected = FC.Queue.GetJob(saved.queueJobId)
    elseif saved.queueJobId == nil then
        local job, task = FC.Queue.NextTask()
        if task and task.status == "uncertain" then selected = job end
    end
    if activeQueueJob(selected) and selected.characterKey == FC.state.characterKey
        and selected.build == tostring(FC.state.build) then
        UI.job, UI.selectedRecipeId = selected, selected.rootRecipeId
    end
    local settings = FC.Logistics.GetSettings()
    if not settings.objective then settings.objective = saved.objective == "cash" and "cash" or "value" end
    UI.conflict = conflictLoaded()
    SLASH_FLUXLOGISTICS1, SLASH_FLUXLOGISTICS2 = "/fluxlogistics", "/fluxcraft"
    SlashCmdList.FLUXLOGISTICS = slash
    attach()
    openQueuedShopping()
    startMarket()
    if UI.conflict then print(L.nativeConflict) end
    local auction = _G.FluxAuctionRestock
    local followup = auction and auction.Followup
    refreshProfessionAction()
    if followup and followup.SetProfessionSurfaceReader then
        followup.SetProfessionSurfaceReader(function()
            if UI.window and UI.window:IsVisible() then
                local dock = UI.professionReminderDock
                return UI.window, true, dock and dock:IsVisible() and dock or nil
            end
            if UI.classic and UI.classic:IsVisible() then return UI.classic, false end
            if followup.HasProfessionReminderDock == true then
                local anchor = nativeReminderAnchor()
                if anchor then return UI.forever, false, anchor, "above" end
            end
        end)
    end
    if followup and followup.RegisterProfessionWindowListener then
        followup.RegisterProfessionWindowListener(refreshProfessionAction)
    end
end)

FC:On("PROFESSION_CHANGED", function()
    if FC.state.ready then attach(); updateProfession() end
end)
FC:On("PROFESSION_SWITCH_READY", function(_, job, task)
    if not UI.saved or not job or FC.Queue.GetJob(job.id) ~= job or not FC.Queue.CanPrepareCraft(job, task) then return end
    focusCraftJob(job)
    queueSelection({job = job, task = task})
    if UI.forever and UI.forever:IsVisible() then
        local recipe = FC.Catalog.Snapshot().recipesById[task.recipeId]
        if recipe then selectNativeCraftRecipe(recipe) end
    end
end)
FC:On("CRAFT_RECOVERY_REPLANNED", function(_, previous, replacement)
    if UI.job ~= previous then return end
    focusCraftJob(replacement)
    UI.Refresh()
end)
FC:On("INVENTORY_CHANGED", function(_, status, context)
    local regions = context and context.regions
    local readinessChanged = status and UI.inventoryReliable ~= nil and status.reliable ~= UI.inventoryReliable
    if status then UI.inventoryReliable = status.reliable end
    if not regions or regions.bags or regions.bank or regions.warband or readinessChanged or status and status.handover then
        UI.Schedule()
        refreshShopping()
    elseif regions.mail then
        refreshShopping()
    end
end)
FC:On("CRAFT_CAST_CHANGED", function()
    refreshNativeQueueProgress()
    if UI.window and UI.window:IsVisible() then UI.RenderQueue() end
end)
FC:On("QUEUE_CHANGED", function()
    refreshNativeQueueProgress()
    if UI.window and UI.window:IsVisible() then
        UI.RenderQueue()
        if UI.job then
            if UI.forever and FC.RecipeProfit then FC.RecipeProfit.Refresh() end
            inspect()
        else UI.Schedule() end
    end
    refreshShopping()
end)
FC:On("EXECUTION_CHANGED", function(_, message)
    local execution = FC.Execution
    if UI.nativeCraftPrepared and (not execution.GetNativeCraftRecipe
        or UI.nativeCraftPrepared ~= execution.GetNativeCraftRecipe()
        or (execution.IsBusy and execution.IsBusy())) then setPreparedNativeCraft(nil) end
    if UI.nativeCraftMessage and FC.Execution.HasNativeCraftPending and not FC.Execution.HasNativeCraftPending()
        and not (FC.Execution.IsBusy and FC.Execution.IsBusy()) then
        UI.nativeCraftMessage, UI.nativeCraftJob = nil, nil
        syncForever()
    end
    notify(message)
    if UI.pendingNativeRecipeID then UI.Schedule() end
    if UI.window and UI.window:IsVisible() then UI.RenderQueue(); inspect() end
end)
FC:On("NATIVE_CRAFT_SETTLED", function(_, job, recipe)
    if UI.nativeCraftSequence ~= recipe or not C_Timer or not C_Timer.After then return end
    C_Timer.After(0, function()
        if UI.nativeCraftSequence ~= recipe then return end
        UI.nativeCraftSequence = nil
        if not UI.forever or not UI.forever:IsVisible() or UI.saved.nativeMode or UI.conflict
            or nativeSelectedRecipeID() ~= recipe.recipeID
            or (UI.auctionShopping and UI.auctionShopping:IsVisible())
            or (activeQueueJob(UI.job) and UI.job ~= job)
            or FC.Queue.GetJob(job.id) ~= job or job.status ~= "queued"
            or #FC.Queue.GetRequirements(job) > 0 or FC.Execution.IsBusy()
            or FC.Execution.HasNativeCraftPending()
            or not FC.Clients.UsesNativeCraftHandoff or not FC.Clients.UsesNativeCraftHandoff() then return end
        local task = FC.Execution.GetReadyRestockCraft(job)
        local profession = FC.Clients.CurrentProfessionID()
        if not task or tonumber(task.professionId) ~= tonumber(profession) then return end
        local _, feedback, acceptedJob, phase = FC.Execution.ProcessNext(job, task)
        if phase == "native_click" then UI.ShowNativeCraft(feedback, acceptedJob or job) end
    end)
end)
FC:On("ACQUISITION_CHANGED", function(_, status, entry, _, message)
    local pane = UI.auctionShopping
    if pane and pane.entry and entry and pane.entry.job == entry.job and pane.entry.id == entry.id then
        if status == "auctionPurchased" then
            pane.advance, pane.continueOffers = true, true
        elseif status == "issued" and entry.job.acquisition and entry.job.acquisition.kind == "auction" then
            pane.continueOffers = true
        end
    end
    if type(message) == "string" then
        message = L.auctionFeedback[message] or message
        notify(message)
    end
    UI.RenderQueue()
    refreshShopping()
end)
FC:On("RESTOCK_POLICY_CHANGED", function(_, reason)
    refreshShopping()
    if reason == "coverage" then return end
    if UI.window and UI.window:IsVisible() then
        if UI.job then
            if UI.forever and FC.RecipeProfit then FC.RecipeProfit.Refresh() end
            UI.RenderQueue()
            inspect()
        else UI.Schedule() end
    end
end)
FC:On("RESTOCK_AUCTION_CHECK", function(_, accepted, message, job)
    if accepted and job and activeAuctionHouse() then
        local entries = FC.Logistics.GetAuctionShoppingRequirements()
        for _, entry in ipairs(entries) do
            if entry.job == job then
                UI.OpenAuctionShopping(nil, {jobId = job.id, id = entry.id, itemID = entry.itemID,
                    planRevision = job.planRevision})
                break
            end
        end
    end
    notify(message)
end)
FC:On("RESTOCK_VIEW", function(_, demand, job)
    UI.demandId = demand.id
    UI.job, UI.step, UI.requirement = job, nil, nil
    if job then UI.selectedRecipeId = job.rootRecipeId end
    UI.queueExpanded = true
    UI.Layout()
    if not UI.window or not UI.window:IsVisible() then print(L.openProfession) end
end)

local events = CreateFrame("Frame")
for _, name in ipairs({"ADDON_LOADED", "TRADE_SKILL_SHOW", "GET_ITEM_INFO_RECEIVED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED", "PLAYER_REGEN_ENABLED", "INPUT_DEVICE_INTERFACE_TRANSITION",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "COMMODITY_PURCHASED"}) do
    pcall(events.RegisterEvent, events, name)
end
if FC.target == "forever" then
    pcall(events.RegisterEvent, events, "ITEM_DATA_LOAD_RESULT")
else
    pcall(events.RegisterEvent, events, "SPELLS_CHANGED")
end
events:SetScript("OnEvent", function(_, event, itemID, loaded)
    if not FC.state.ready then return end
    if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
        local reprice = loaded == true and UI.forever and FC.RecipeProfit and FC.RecipeProfit.ItemDataLoaded(itemID)
        if reprice or event == "GET_ITEM_INFO_RECEIVED" then UI.Schedule() end
        if loaded or event == "GET_ITEM_INFO_RECEIVED" then refreshShopping() end
    elseif event == "INPUT_DEVICE_INTERFACE_TRANSITION" then
        if UI.forever then syncForever()
        elseif UI.classic then syncClassic() end
    elseif event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
        if UI.forever and UI.nativeCraftMessage then syncForever()
        elseif UI.resize then UI.resize(UI.window:IsVisible()) end
        refreshShopping()
    elseif event == "TRADE_SKILL_SHOW" then attach(); updateProfession(); refreshShopping()
    elseif event == "SPELLS_CHANGED" then
        if UI.classic and UI.classic:IsVisible() then updateProfession() end
    elseif event == "AUCTION_HOUSE_SHOW" then
        updateRecipeAuctionator()
        if activeAuctionHouse() then openQueuedShopping()
        else
            C_Timer.After(0, function()
                updateRecipeAuctionator()
                openQueuedShopping()
            end)
        end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED"
        or event == "COMMODITY_PURCHASED" then
        if not activeAuctionHouse() then return end
        local changed
        if event == "COMMODITY_PURCHASED" then changed = FC.Logistics.InvalidateAuctionDepth(itemID)
        else changed = FC.Logistics.ObserveCommodityDepth(itemID) end
        if changed and not UI.pendingAuctionDepthRefresh then
            UI.pendingAuctionDepthRefresh = true
            C_Timer.After(0, function()
                UI.pendingAuctionDepthRefresh = nil
                refreshMarket()
            end)
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        hideShopping(UI.auctionShopping)
        FC.Logistics.ClearAuctionPrices()
        UI.auctionPriceScan = nil
        if UI.recipeAuctionator then UI.recipeAuctionator:Hide() end
        if UI.auctionPriceButton then UI.auctionPriceButton:Hide() end
        -- Some selling lookups update prices outside Auctionator's scan callback.
        if FC.AuctionatorAdapter and FC.AuctionatorAdapter.IsAvailable() then refreshMarket(true) end
        UI.Schedule()
    else
        attach()
        updateRecipeAuctionator()
        if itemID == "Auctionator" then
            startMarket()
            refreshMarket(true)
        else UI.Schedule() end
    end
end)
