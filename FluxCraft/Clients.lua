local _, FC = ...
if FC.disabled then return end

local Clients = {}
FC.Clients = Clients
local L = FC.L.clients
local armedCraft
local observedPages = setmetatable({}, {__mode = "k"})

local function shown(frame)
    return frame and type(frame.IsShown) == "function" and frame:IsShown()
end

local function combat()
    return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function call(object, method, ...)
    if object and type(object[method]) == "function" then
        local ok, a, b = pcall(object[method], ...)
        if ok then return a, b end
    end
end

-- Classic profession skill lines with an active spellbook action that opens a panel.
-- Gathering abilities are excluded, apart from Mining's distinct Smelting action.
local classicOpeners = {
    [129] = 3273,  -- First Aid
    [164] = 2018,  -- Blacksmithing
    [165] = 2108,  -- Leatherworking
    [171] = 2259,  -- Alchemy
    [185] = 2550,  -- Cooking
    [186] = 2656,  -- Smelting
    [197] = 3908,  -- Tailoring
    [202] = 4036,  -- Engineering
    [333] = 7411,  -- Enchanting
    [755] = 25229, -- Jewelcrafting
    [773] = 45357, -- Inscription
}
local nonCraftingSkills = {[182] = true, [356] = true, [393] = true, [794] = true}
local nonCraftingSpells = {[2366] = true, [2575] = true, [7620] = true, [8613] = true, [78670] = true}
local skillByOpener = {[2842] = 40, [53428] = 960} -- Poisons and Runeforging are class-specific.
for skillID, spellID in pairs(classicOpeners) do skillByOpener[spellID] = skillID end

local function spellName(id)
    return call(C_Spell, "GetSpellName", id) or (GetSpellInfo and GetSpellInfo(id))
end

local function bookProfessions()
    local entries = {}
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return entries end
    local function collect(...)
        for i = 1, select("#", ...) do
            local index = select(i, ...)
            if index then
                local ok, name, texture, rank, maxRank, numSpells, spellOffset, id = pcall(GetProfessionInfo, index)
                id = tonumber(id)
                if ok and type(name) == "string" and id and id > 0
                    and (FC.target == "forever" or not nonCraftingSkills[id]) then
                    entries[#entries + 1] = {id = id, name = name, texture = texture,
                        rank = rank, maxRank = maxRank, spellOffset = spellOffset,
                        numSpells = numSpells, index = index, secondary = i > 2,
                        opensTradeSkill = id ~= 186}
                end
            end
        end
    end
    collect(GetProfessions())
    return entries
end

-- A known opener must be learned in the player spellbook. Resolve names from
-- the client so the fallback works before any profession has been opened.
local function legacyBookProfessions(entries)
    if not (GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo and GetSpellBookItemName) then return end
    local observed, byName, bySkill = {}, {}, {}
    local openerByName, found = {}, {}
    local book = BOOKTYPE_SPELL or "spell"
    local currentName, rank, maxRank
    if shown(_G.TradeSkillFrame) and GetTradeSkillLine then currentName, rank, maxRank = GetTradeSkillLine() end
    if currentName and currentName ~= "" then observed[currentName] = true end
    for _, bucket in pairs(FC.state and FC.state.catalogStore or {}) do
        if bucket.name then observed[bucket.name] = bucket end
    end
    for _, profession in ipairs(entries) do
        byName[profession.name], bySkill[profession.id] = profession, profession
    end
    for id in pairs(skillByOpener) do
        local name = spellName(id)
        if type(name) == "string" and name ~= "" then openerByName[name] = id end
    end
    for tab = 1, (GetNumSpellTabs() or 0) do
        local _, _, offset, count = GetSpellTabInfo(tab)
        for slot = (offset or 0) + 1, (offset or 0) + (count or 0) do
            local kind, spellID = GetSpellBookItemInfo(slot, book)
            if kind == "SPELL" and type(spellID) == "number" and spellID > 0
                and not (IsPassiveSpell and IsPassiveSpell(slot, book)) then
                local name = GetSpellBookItemName(slot, book)
                local base = call(C_SpellBook, "FindBaseSpellByID", spellID)
                local skill = skillByOpener[spellID] or skillByOpener[base] or skillByOpener[openerByName[name]]
                local profession = bySkill[skill] or byName[name]
                local remembered = observed[name]
                if type(name) == "string" and (skill or remembered or profession)
                    and not (nonCraftingSpells[spellID] or nonCraftingSpells[base])
                    and (not profession or profession.id ~= 186 or skill == 186) then
                    -- The canonical spell wins over localized name matches. Two
                    -- different spells with only a name match remain ambiguous.
                    local key = (profession and profession.id) or skill or name
                    local priority = skillByOpener[spellID] and 3 or skillByOpener[base] and 2 or 1
                    local existing = found[key]
                    if not existing or priority > existing.priority then
                        found[key] = {name = name, slot = slot, spellID = spellID, skill = skill,
                            priority = priority, profession = profession, remembered = remembered}
                    elseif priority == existing.priority and existing.spellID ~= spellID then
                        existing.ambiguous = true
                    end
                end
            end
        end
    end
    local additional = {}
    for _, match in pairs(found) do
        if match.ambiguous then
            if match.profession then match.profession.opensTradeSkill = false end
        else
            local profession = match.profession
            if not profession then
                local remembered = type(match.remembered) == "table" and match.remembered.id
                profession = {id = remembered or match.spellID, name = match.name,
                    secondary = match.skill == 129 or match.skill == 185}
                additional[#additional + 1] = profession
            end
            profession.spellSlot, profession.spellID, profession.spellName = match.slot, match.spellID, match.name
            profession.opensTradeSkill = true
            if match.skill == 186 then profession.skillName = spellName(2575) end
            if not profession.texture and GetSpellBookItemTexture then
                profession.texture = GetSpellBookItemTexture(match.slot, book)
            end
        end
    end
    table.sort(additional, function(a, b)
        if a.secondary ~= b.secondary then return not a.secondary end
        return a.name < b.name
    end)
    for _, profession in ipairs(additional) do entries[#entries + 1] = profession end
    for _, profession in ipairs(entries) do
        if currentName and (currentName == profession.name or currentName == profession.spellName
            or currentName == profession.skillName) then
            profession.rank, profession.maxRank = rank, maxRank
        end
    end
end

function Clients.ListProfessions()
    local entries = bookProfessions()
    if FC.target ~= "forever" then
        -- Spell book slot coordinates can move; the switch action re-resolves them.
        legacyBookProfessions(entries)
    end
    return entries
end

function Clients.CurrentProfessionID(professions)
    if FC.Catalog and FC.Catalog.IsForeignSession() then return nil end
    if FC.target == "forever" then
        local frame = _G.ProfessionsFrame
        if not (shown(frame) and shown(frame.CraftingPage)) then return nil end
        local api = C_TradeSkillUI
        if call(api, "IsDataSourceChanging") == true then return nil end
        if api and type(api.IsTradeSkillReady) == "function" and call(api, "IsTradeSkillReady") ~= true then
            return nil
        end
        local info = call(api, "GetChildProfessionInfo")
        if type(info) ~= "table" or not tonumber(info.professionID) or info.professionID == 0 then
            info = call(api, "GetBaseProfessionInfo")
        end
        if type(info) == "table" then
            local id = tonumber(info.parentProfessionID)
            if not id or id == 0 then id = tonumber(info.professionID) end
            if id and id > 0 then return id, info.sourceCounter end
        end
        return nil
    end
    if shown(_G.TradeSkillFrame) and GetTradeSkillLine then
        local name = GetTradeSkillLine()
        for _, profession in ipairs(professions or Clients.ListProfessions()) do
            if name and (name == profession.name or name == profession.spellName or name == profession.skillName) then
                return profession.id
            end
        end
    end
end

local function selectForeverProfessionTab(frame, professionID, api)
    if not shown(frame) then return false end
    for _, tab in ipairs(frame.rightProfessionTabs or {}) do
        if shown(tab) and tonumber(tab.skillLine) == professionID and type(tab.OnClick) == "function" then
            if not pcall(tab.OnClick, tab) then return false end
            -- A tab always reveals Recipes, even if its spell could not open.
            return Clients.CurrentProfessionID() == professionID or call(api, "IsDataSourceChanging") == true
        end
    end
    return false
end

local function foreverProfession(professionID)
    local api, frame = C_TradeSkillUI, _G.ProfessionsFrame
    if FC.Catalog and FC.Catalog.IsForeignSession() or call(api, "IsDataSourceChanging") == true then return false end
    if Clients.CurrentProfessionID() == professionID then return true end
    local retained = call(api, "GetBaseProfessionInfo")
    if type(retained) == "table" and retained.professionID == professionID then
        if selectForeverProfessionTab(frame, professionID, api) then return true end
        -- The bootstrap only reveals Recipes when its base skill already matches.
        local current = call(api, "GetBaseProfessionInfo")
        if type(current) == "table" and current.professionID == professionID
            and type(OpenProfessionUIToSkillLine) == "function" and pcall(OpenProfessionUIToSkillLine, professionID) then
            return Clients.CurrentProfessionID() == professionID
        end
        return false
    end
    if not api or type(api.OpenTradeSkill) ~= "function" then
        return selectForeverProfessionTab(frame, professionID, api)
    end
    -- Switch directly to the exact skill. Refusal must not recast via a tab.
    local auction = _G.FluxAuctionRestock
    local followup = auction and auction.Followup
    if followup and type(followup.OpenProfession) == "function" then
        return call(followup, "OpenProfession", professionID) == true
    end
    return call(api, "OpenTradeSkill", professionID) == true
end

local function professionSkillProgress(info, professionID)
    if type(info) ~= "table" then return end
    local id = tonumber(info.parentProfessionID)
    if not id or id == 0 then id = tonumber(info.professionID) end
    local rank, maximum = info.skillLevel, info.maxSkillLevel
    if id == professionID and not (issecretvalue and (issecretvalue(rank) or issecretvalue(maximum)))
        and type(rank) == "number" and type(maximum) == "number" and rank >= 0 and maximum > 0 then
        return rank, maximum
    end
end

function Clients.GetRecipeSkillProgress(recipe)
    if recipe.legacy then
        if GetTradeSkillLine then
            local _, rank, maximum = GetTradeSkillLine()
            return rank, maximum
        end
        return
    end
    local id = tonumber(recipe.professionId)
    if not id or id <= 0 then return end
    if FC.target == "forever" then
        local rank, maximum = professionSkillProgress(call(Professions, "GetProfessionInfo"), id)
        if rank then return rank, maximum end
    end
    local api = C_TradeSkillUI
    local rank, maximum = professionSkillProgress(call(api, "GetProfessionInfoByRecipeID", recipe.recipeID), id)
    if rank then return rank, maximum end
    if FC.target ~= "forever" then return end
    rank, maximum = professionSkillProgress(call(api, "GetChildProfessionInfo"), id)
    if rank then return rank, maximum end
    return professionSkillProgress(call(api, "GetBaseProfessionInfo"), id)
end

function Clients.SwitchProfession(professionID)
    if combat() then return false, L.switchCombat end
    professionID = tonumber(professionID)
    if not professionID or professionID <= 0 or professionID % 1 ~= 0 then return false, L.professionIdentity end
    if FC.target == "forever" then
        if foreverProfession(professionID) then return true end
        return false, L.nativeTab
    end
    for _, profession in ipairs(Clients.ListProfessions()) do
        if profession.id == professionID and profession.opensTradeSkill ~= false then
            local slot = profession.spellSlot
            if not slot and profession.id ~= 186 then
                slot = profession.spellOffset and profession.spellOffset + 1
            end
            local book = BOOKTYPE_SPELL or "spell"
            if slot and type(CastSpell) == "function"
                and (not GetSpellBookItemInfo or GetSpellBookItemInfo(slot, book) == "SPELL") then
                local ok, accepted = pcall(CastSpell, slot, book)
                if ok and accepted ~= false then return true end
            end
            break
        end
    end
    return false, L.spellBook
end

local function constraintsAllow(constraints)
    if constraints.cooldownUntil or constraints.maxExecutions == 0 then
        return false, L.cooldown
    end
    if constraints.requirementsMet == false then
        return false, FC.MissingCraftRequirement(constraints.requirements) or constraints.blockedReason or L.requirements
    end
    return true
end

local function identicalChoice(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    local bySlot = {}
    for _, row in ipairs(a) do
        if not row.slotIndex then return false end
        bySlot[row.slotIndex] = row
    end
    for _, row in ipairs(b) do
        local match = bySlot[row.slotIndex]
        if not match or match.itemID ~= row.itemID or match.quantity ~= row.quantity then return false end
    end
    return true
end

-- The plan may aggregate repeated reagents, whereas native allocation identifies slots.
local function exactInputs(choice, task)
    local totals = {}
    for _, line in ipairs(choice) do
        totals[line.itemID] = (totals[line.itemID] or 0) + line.quantity * task.executions
    end
    for _, input in ipairs(task.inputs or {}) do
        local quantity = totals[input.itemID]
        if not quantity or quantity < input.quantity then return false end
        totals[input.itemID] = quantity - input.quantity
    end
    for _, remaining in pairs(totals) do
        if remaining ~= 0 then return false end
    end
    return true
end

function Clients.Resolve(task, recipe, revealLegacy)
    local catalog = FC.Catalog
    if not task or not recipe or not catalog or task.recipeId ~= recipe.id
        or recipe.learned ~= true or recipe.completeness ~= "complete" then
        return nil, L.stalePlan
    end
    if Clients.CurrentProfessionID() ~= tonumber(task.professionId) then
        return nil, L.waitProfession
    end
    if task.outputKind ~= "item" or recipe.outputKind ~= "item" then
        return nil, L.special
    end
    if FC.target == "forever" then
        local live, reason = catalog.ReadModernRecipe(recipe.recipeID, tonumber(task.professionId))
        if recipe.supersededByRecipeID or live and live.supersededByRecipeID then return nil, L.supersededRank end
        if not live or live.blocker or not live.choices then return nil, reason or (live and live.blocker) end
        if live.outputItemID ~= tonumber(task.outputItemID) or live.minYield ~= task.yield
            or live.maxYield ~= recipe.yieldMax then
            return nil, L.staleYield
        end
        local allowed, constraint = constraintsAllow(live.constraints)
        if not allowed then return nil, constraint end
        local selected
        for _, choice in ipairs(live.choices) do
            if (task.reagentChoice and identicalChoice(choice.reagents, task.reagentChoice.reagents)
                    or not task.reagentChoice and #live.choices == 1)
                and exactInputs(choice.reagents, task) then
                selected = choice.reagents
                break
            end
        end
        if not selected then return nil, L.staleReagents end
        return {kind = "forever", recipeID = recipe.recipeID, info = live.info, schematic = live.schematic,
            choice = selected, maxExecutions = live.constraints.maxExecutions,
            maxYield = live.maxYield, outputLink = recipe.outputLink}
    end
    local index, reason = catalog.ResolveLive(recipe)
    if not index and revealLegacy and reason == FC.L.catalog.notVisible and not combat()
        and type(ExpandTradeSkillSubClass) == "function" and pcall(ExpandTradeSkillSubClass, 0) then
        index, reason = catalog.ResolveLive(recipe)
    end
    if not index then return nil, reason end
    if not exactInputs(recipe.reagents or {}, task) then return nil, L.classicReagents end
    local constraints = catalog.ReadConstraints(nil, index)
    local allowed, blocker = constraintsAllow(constraints)
    if not allowed then return nil, blocker end
    return {kind = "classic", index = index, recipe = recipe, choice = recipe.reagents,
        maxExecutions = constraints.maxExecutions,
        maxYield = recipe.yieldMax, outputLink = recipe.outputLink}
end

local function genericFreeSlots(owner)
    local containers = owner and owner.Inventory and owner.Inventory.Containers
    local bags = call(containers, "GetCarriedBagIDs")
    if type(bags) ~= "table" or type(containers.IsReagentBag) ~= "function"
        or type(containers.IsKeyringBag) ~= "function" then return nil end
    local backpack = _G.BACKPACK_CONTAINER or 0
    local total
    for _, bag in ipairs(bags) do
        if not containers.IsReagentBag(bag) and not containers.IsKeyringBag(bag) then
            local free, family = call(owner.Container, "GetNumFreeSlots", bag)
            if not (issecretvalue and (issecretvalue(free) or issecretvalue(family)))
                and type(free) == "number" and free >= 0
                and (family == 0 or bag == backpack and family == nil) then
                total = (total or 0) + free
            end
        end
    end
    return total
end

-- Credit generic empty slots and identical-link partial stacks in carried bags.
local function bagLimitedBatch(task, live, batch)
    local owner = _G.Flux
    local free = genericFreeSlots(owner)
    if free == nil then return nil, L.unknownCapacity end
    local stackSize = call(C_Item, "GetItemMaxStackSizeByID", task.outputItemID)
    if not stackSize then
        local getItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
        if getItemInfo then stackSize = select(8, getItemInfo(task.outputItemID)) end
    end
    stackSize = math.max(1, tonumber(stackSize) or 1)
    local capacity = free * stackSize
    local link = live.outputLink and live.outputLink:match("|H([^|]+)|h")
    if link and stackSize > 1 then
        local stacks = call(owner.Inventory, "Find", task.outputItemID, {
            bags = true, bank = false, warband = false, equipped = false,
            mail = false, void = false, auctions = false, guild = false,
        })
        for _, stack in ipairs(type(stacks) == "table" and stacks or {}) do
            if stack.region == "bags" and stack.link and stack.link:match("|H([^|]+)|h") == link then
                capacity = capacity + math.max(0, stackSize - (tonumber(stack.count) or stackSize))
            end
        end
    end
    local limited = math.min(batch, math.floor(capacity / (live.maxYield or task.yield)))
    if limited < 1 then return nil, L.noCapacity end
    return limited
end

local function matchingNativeSlots(transaction, slots, planned)
    for index, slot in ipairs(slots) do
        local slotIndex = slot.slotIndex or index
        local line = planned[slotIndex]
        local remaining = line and line.quantity or 0
        -- Blizzard indexes allocations by the schematic's position, while the
        -- serialized dataSlotIndex can be shared by different reagent slots.
        for _, allocation in transaction:EnumerateAllocations(index) do
            local quantity = allocation:GetQuantity()
            if (issecretvalue and issecretvalue(quantity)) or type(quantity) ~= "number"
                or quantity < 0 or quantity % 1 ~= 0 then return false end
            if quantity > 0 then
                local reagent = allocation:GetReagent()
                local itemID = reagent and reagent.itemID
                if not line or (issecretvalue and issecretvalue(itemID))
                    or itemID ~= line.itemID or quantity > remaining then return false end
                remaining = remaining - quantity
            end
        end
        if remaining ~= 0 then return false end
        planned[slotIndex] = nil
    end
    return not next(planned)
end

local function matchingNativeAllocations(transaction, live)
    if not transaction then return false end
    if type(transaction.IsRecraft) == "function" and transaction:IsRecraft() then return false end
    if type(transaction.IsApplyingConcentration) == "function" and transaction:IsApplyingConcentration() then
        return false
    end
    if type(transaction.GetEnchantAllocation) == "function" and transaction:GetEnchantAllocation() then return false end
    local planned = {}
    for _, line in ipairs(live.choice) do planned[line.slotIndex] = line end
    local slots = live.schematic.reagentSlotSchematics
    if type(transaction.EnumerateAllocations) == "function" then
        return matchingNativeSlots(transaction, slots, planned)
    end
    if type(transaction.CreateCraftingReagentInfoTbl) ~= "function" then return false end
    local expected = {}
    for index, slot in ipairs(slots) do
        local slotIndex = slot.slotIndex or index
        if planned[slotIndex] then
            expected[slot.dataSlotIndex or slotIndex] = planned[slotIndex]
        elseif type(transaction.HasAnyAllocations) == "function"
            and transaction:HasAnyAllocations(slotIndex) then
            return false
        end
    end
    local function matchObserved(observed)
        if type(observed) ~= "table" then return false end
        for _, allocation in ipairs(observed) do
            local expectedLine = expected[allocation.dataSlotIndex]
            if not expectedLine or not allocation.reagent or allocation.reagent.itemID ~= expectedLine.itemID
                or allocation.quantity ~= expectedLine.quantity then return false end
            expected[allocation.dataSlotIndex] = nil
        end
        return true
    end
    if not matchObserved(transaction:CreateCraftingReagentInfoTbl()) then return false end
    if type(transaction.CreateReagentInfoTbl) == "function"
        and not matchObserved(transaction:CreateReagentInfoTbl()) then
        return false
    end
    return not next(expected)
end

function Clients.CancelNativeCraft()
    armedCraft = nil
end

local function observedCraft(page, recipeID, count, recipeLevel)
    local request = armedCraft
    if not request or request.page ~= page then return end
    armedCraft = nil
    local form = page.SchematicForm
    local selected = form and form:GetRecipeInfo()
    if (issecretvalue and (issecretvalue(recipeID) or issecretvalue(count) or issecretvalue(recipeLevel)))
        or recipeID ~= request.live.recipeID or not selected or selected.recipeID ~= recipeID
        or Clients.CurrentProfessionID() ~= tonumber(request.task.professionId) then
        request.onAttempt(nil, L.sessionChanged)
        return
    end
    if request.free and count == 0 then count = 1 end
    if type(count) ~= "number" or count < 1 or count > request.batch or count % 1 ~= 0
        or recipeLevel and recipeLevel ~= 0 and recipeLevel ~= 1 then
        request.onAttempt(nil, L.changedAmount)
        return
    end
    if not matchingNativeAllocations(form:GetTransaction(), request.live) then
        request.onAttempt(nil, L.staleReagents)
        return
    end
    request.onAttempt(count)
end

local function observeCraftEntry(page, isCrafting)
    local request = armedCraft
    if isCrafting == true and request and request.page == page and request.onEntry then
        request.onEntry()
    end
end

local function modernCraft(task, live, batch, onAttempt, onEntry)
    local page = _G.ProfessionsFrame and _G.ProfessionsFrame.CraftingPage
    if not page or not page.SchematicForm or type(page.CreateInternal) ~= "function"
        or type(hooksecurefunc) ~= "function" then return false, L.openPage end
    local currentInfo = call(C_TradeSkillUI, "GetRecipeInfo", live.recipeID)
    if FC.Catalog.GetSupersedingRank(currentInfo, live.recipeID) then return false, L.supersededRank end
    if not observedPages[page] then
        -- The pinned native CreateInternal enables its cast bar before submitting.
        -- Observe that entry separately from the final recipe and quantity check.
        if type(page.SetOverrideCastBarActive) == "function" then
            hooksecurefunc(page, "SetOverrideCastBarActive", observeCraftEntry)
        end
        hooksecurefunc(page, "CreateInternal", observedCraft)
        observedPages[page] = true
    end
    local free = #live.choice == 0 and call(C_TradeSkillUI, "HasNoReagentCost", live.recipeID) == true
    batch = math.min(batch, (free or live.info.canCreateMultiple == false) and 1 or 999)
    armedCraft = {page = page, task = task, live = live, batch = batch, free = free,
        onAttempt = onAttempt, onEntry = onEntry}
    return true, nil, "native_click", batch
end

local function positiveCount(value)
    return not (issecretvalue and issecretvalue(value)) and type(value) == "number"
        and value > 0 and value < math.huge and value % 1 == 0
end

function Clients.ReadNativeCraftRecasts(recipeID)
    if FC.target ~= "forever" then return end
    local frame = _G.ProfessionsFrame
    local page = shown(frame) and frame.CraftingPage
    local form = shown(page) and page.SchematicForm
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    if not info or not positiveCount(info.recipeID) or info.recipeID ~= recipeID then return end
    local transaction = form.GetTransaction and form:GetTransaction()
    if not transaction then return end
    local remaining = call(C_TradeSkillUI, "GetRemainingRecasts")
    if (issecretvalue and issecretvalue(remaining)) or type(remaining) ~= "number"
        or remaining < 0 or remaining % 1 ~= 0 then return end
    return remaining, transaction
end

function Clients.PrepareNativeCraftBatch(recipeID, batch)
    if FC.target ~= "forever" or combat() or not positiveCount(recipeID) or not positiveCount(batch) then return end
    local frame = _G.ProfessionsFrame
    local page = shown(frame) and frame.CraftingPage
    local form = shown(page) and page.SchematicForm
    local info = form and form.GetRecipeInfo and form:GetRecipeInfo()
    local create = page and page.CreateButton
    if not info or not positiveCount(info.recipeID) or info.recipeID ~= recipeID then return end
    if not shown(create) or not create.IsEnabled or not create:IsEnabled() then
        local tooltip = create and create.tooltipText
        if not (issecretvalue and issecretvalue(tooltip)) and type(tooltip) == "string" and tooltip ~= "" then
            return nil, tooltip
        end
        return nil, L.nativeCreateUnavailable
    end
    local request = armedCraft
    if request and (request.page ~= page or request.live.recipeID ~= recipeID
        or not matchingNativeAllocations(form:GetTransaction(), request.live)) then return nil, L.staleReagents end
    if info.canCreateMultiple == false or (request and request.free)
        or call(C_TradeSkillUI, "HasNoReagentCost", recipeID) == true then
        return 1
    end
    local cap = page.GetCraftableCount and page:GetCraftableCount()
    local input = page.CreateMultipleInputBox
    if not positiveCount(cap) or not input or not input.IsEnabled or not input:IsEnabled()
        or not input.GetValue or not input.SetValue then return end
    local quantity = math.min(batch, cap, request and request.batch or batch)
    if input:GetValue() ~= quantity then input:SetValue(quantity) end
    if input:GetValue() == quantity then return quantity end
end

function Clients.UsesNativeCraftHandoff()
    return FC.target == "forever"
end

local function ordinaryRecipeInfo(info, recipeID)
    return type(info) == "table" and positiveCount(info.recipeID) and info.recipeID == recipeID and info.learned == true
        and not (info.isRecraft or info.isDummyRecipe or info.isGatheringRecipe or info.isEnchantingRecipe)
        and not positiveCount(info.previousRecipeID) and not positiveCount(info.nextRecipeID)
        and (not positiveCount(info.unlockedRecipeLevel) or info.unlockedRecipeLevel == 1)
end

function Clients.CanDispatchQueuedCraft(live)
    local trade = C_TradeSkillUI
    local recipeTypes = Enum and Enum.TradeskillRecipeType
    local reagentTypes = Enum and Enum.CraftingReagentType
    local dataTypes = Enum and Enum.TradeskillSlotDataType
    local schematic = live and live.schematic
    local slots = schematic and schematic.reagentSlotSchematics
    if FC.target ~= "forever" or not live or live.kind ~= "forever" or not positiveCount(live.recipeID)
        or not ordinaryRecipeInfo(live.info, live.recipeID) or not trade
        or type(trade.CraftRecipe) ~= "function" or type(trade.GetCraftableCount) ~= "function"
        or not recipeTypes or recipeTypes.Item == nil or not reagentTypes or reagentTypes.Basic == nil
        or not dataTypes or dataTypes.Reagent == nil or not schematic or schematic.isRecraft
        or schematic.recipeType ~= recipeTypes.Item or type(slots) ~= "table"
        or type(live.choice) ~= "table" or #slots == 0 or #slots ~= #live.choice then return false end

    local bySlot = {}
    for _, line in ipairs(live.choice) do
        if not positiveCount(line.slotIndex) or bySlot[line.slotIndex] then return false end
        bySlot[line.slotIndex] = line
    end
    for index, slot in ipairs(slots) do
        local slotIndex = slot.slotIndex or index
        local line = bySlot[slotIndex]
        local reagents = slot.reagents
        local reagent = type(reagents) == "table" and #reagents == 1 and reagents[1]
        if slot.reagentType ~= reagentTypes.Basic or slot.dataSlotType ~= dataTypes.Reagent
            or not line or not reagent or not positiveCount(line.itemID) or line.itemID ~= reagent.itemID
            or not positiveCount(slot.quantityRequired) or line.quantity ~= slot.quantityRequired
            or type(slot.variableQuantities) == "table" and next(slot.variableQuantities) then return false end
        bySlot[slotIndex] = nil
    end
    return not next(bySlot)
end

-- Only the queue's physical Process action calls this adapter. The native
-- engine allocates every basic input for these exact, unambiguous recipes.
function Clients.DispatchQueuedCraft(task, live, batch, beforeClick)
    if not Clients.CanDispatchQueuedCraft(live) then return false, L.noCraft, "unsupported" end
    if combat() then return false, L.combat, "not_submitted" end
    local profession, session = Clients.CurrentProfessionID()
    if not task or not profession or profession ~= tonumber(task.professionId)
        or tonumber(task.recipeId) ~= live.recipeID or not positiveCount(batch)
        or type(beforeClick) ~= "function" or armedCraft then return false, L.noSession, "not_submitted" end
    if not exactInputs(live.choice, task) then return false, L.staleReagents, "not_submitted" end
    local trade, recipeID = C_TradeSkillUI, live.recipeID
    local info = call(trade, "GetRecipeInfo", recipeID)
    if not ordinaryRecipeInfo(info, recipeID) then return false, L.stalePlan, "not_submitted" end
    local available = call(trade, "GetCraftableCount", recipeID)
    if not positiveCount(available) then return false, L.nothingAvailable, "not_submitted" end
    local maximum = math.min(batch, available, live.maxExecutions or math.huge,
        info.canCreateMultiple == false and 1 or 999)
    local count, reason = bagLimitedBatch(task, live, maximum)
    if not count then return false, reason, "not_submitted" end
    if beforeClick(count) ~= true then return false, L.queueIntent, "not_submitted" end
    local currentProfession, currentSession = Clients.CurrentProfessionID()
    if combat() or profession ~= currentProfession or session ~= currentSession then
        return false, L.sessionChanged, "not_submitted"
    end
    info = call(trade, "GetRecipeInfo", recipeID)
    if not ordinaryRecipeInfo(info, recipeID) or count > 1 and info.canCreateMultiple == false then
        return false, L.stalePlan, "not_submitted"
    end
    available = call(trade, "GetCraftableCount", recipeID)
    if not positiveCount(available) or available < count then
        return false, L.nothingAvailable, "not_submitted"
    end
    -- A rejected or thrown call has entered the native path. The caller must
    -- reconcile it and wait for another player press before any alternative.
    if trade.CraftRecipe(recipeID, count, {}, 0, nil, false) == false then
        return false, L.noSubmission, "attempted"
    end
    return true, nil, count
end

local function classicCraft(task, live, batch, beforeClick)
    local frame, button, input = _G.TradeSkillFrame, _G.TradeSkillCreateButton, _G.TradeSkillInputBox
    if not shown(frame) or not button or not input or type(TradeSkillFrame_SetSelection) ~= "function" then
        return false, L.classicWindow
    end
    TradeSkillFrame_SetSelection(live.index)
    if type(GetTradeSkillSelectionIndex) ~= "function" or GetTradeSkillSelectionIndex() ~= live.index
        or frame.selectedSkill ~= live.index or not FC.Catalog.MatchLegacyLive(live.recipe, live.index) then
        return false, L.classicSelection
    end
    local _, kind, available = GetTradeSkillInfo(live.index)
    if kind == "header" or kind == "subheader" or not button:IsEnabled() or (tonumber(available) or 0) < 1 then
        return false, L.classicUnavailable
    end
    batch = math.min(batch, available, 999)
    input:SetNumber(batch)
    if input:GetNumber() ~= batch then return false, L.changedAmount end
    if beforeClick(batch) == false then return false, L.queueIntent end
    if Clients.CurrentProfessionID() ~= tonumber(task.professionId) or frame.selectedSkill ~= live.index
        or input:GetNumber() ~= batch or not button:IsEnabled() or not FC.Catalog.MatchLegacyLive(live.recipe, live.index) then
        return false, L.classicSelection, "not_submitted"
    end
    local ok = pcall(button.Click, button)
    if not ok then return false, L.noSubmission end
    return true, nil, batch
end

function Clients.Craft(task, live, batch, beforeClick, onNativeEntry)
    if combat() then return false, L.combat end
    if not live or batch < 1 or type(beforeClick) ~= "function"
        or Clients.CurrentProfessionID() ~= tonumber(task.professionId) then
        return false, L.noSession
    end
    batch = math.min(batch, live.maxExecutions or math.huge)
    local limited, reason = bagLimitedBatch(task, live, batch)
    if not limited then return false, reason end
    if live.kind == "forever" then return modernCraft(task, live, limited, beforeClick, onNativeEntry) end
    if live.kind == "classic" then return classicCraft(task, live, limited, beforeClick) end
    return false, L.noCraft
end
