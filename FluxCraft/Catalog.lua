-- Character-owned recipe memory, normalized from FluxUI's profession cache.
-- FluxUI owns profession observation; this module adds stable identities and
-- stores previously observed skills without reading another character's cache.
local _, ns = ...
ns = ns or {}

local Catalog = {}
ns.Catalog = Catalog
local snapshotCache
local L = ns.L.catalog

local function CharacterKey()
    if ns.state and ns.state.characterKey then
        return ns.state.characterKey
    end
    local guid = UnitGUID and UnitGUID("player")
    if guid then return guid end
    local realm = GetRealmName and GetRealmName() or "unknown-realm"
    local name = UnitName and UnitName("player") or "unknown-character"
    return realm .. ":" .. name
end

local function Build()
    if ns.state and ns.state.build then return ns.state.build end
    return GetBuildInfo and select(4, GetBuildInfo()) or "unknown-build"
end

local function Store()
    if ns.state and ns.state.catalogBuildStore then
        return ns.state.catalogBuildStore
    end
    _G.FluxLogisticsDB = _G.FluxLogisticsDB or {}
    local db = _G.FluxLogisticsDB
    db.catalog = db.catalog or { characters = {} }
    db.catalog.characters = db.catalog.characters or {}
    local chars = db.catalog.characters
    local key = CharacterKey()
    chars[key] = chars[key] or { builds = {} }
    local builds = chars[key].builds
    local build = Build()
    builds[build] = builds[build] or { professions = {}, revision = 0 }
    return builds[build]
end

local function ProfStore()
    local store = Store()
    store.professions = store.professions or {}
    return store, store.professions
end

local function InventoryProfessions()
    local flux = rawget(_G, "Flux")
    local inv = flux and flux.Inventory
    return inv and inv.Professions or nil
end

function Catalog.IsForeignSession()
    if type(IsTradeSkillLinked) == "function" then
        local ok, linked = pcall(IsTradeSkillLinked)
        if not ok or linked then return true end
    end
    local api = rawget(_G, "C_TradeSkillUI")
    if type(api) == "table" then
        for _, method in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting" }) do
            if type(api[method]) == "function" then
                local ok, shown = pcall(api[method])
                if not ok or shown then return true end
            end
        end
    end
    return false
end

local function PositiveInteger(n)
    n = tonumber(n)
    return n and n > 0 and n < math.huge and n == math.floor(n) and n or nil
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return PositiveInteger(link:match("item:(%d+)"))
end

local function SpellIDFromRecipeLink(link)
    if type(link) ~= "string" then return nil end
    return PositiveInteger(link:match("|Henchant:(%d+)"))
        or PositiveInteger(link:match("|Hspell:(%d+)"))
end

local function NormalizeReagents(rows)
    if type(rows) ~= "table" then return nil end
    local totals, reagents = {}, {}
    for _, r in ipairs(rows) do
        local id = PositiveInteger(r and r.itemID)
        local quantity = PositiveInteger(r and (r.quantity or r.count))
        if not id or not quantity then return nil end
        totals[id] = (totals[id] or 0) + quantity
    end
    for id, quantity in pairs(totals) do
        reagents[#reagents + 1] = { itemID = id, quantity = quantity }
    end
    table.sort(reagents, function(a, b)
        return a.itemID < b.itemID
    end)
    return reagents
end

local function Call(api, name, ...)
    if api and type(api[name]) == "function" then
        local ok, a, b, c, d = pcall(api[name], ...)
        if ok then return a, b, c, d end
    end
end

-- Captured from the native skill source only after FluxUI has observed the recipe.
-- Shape is saved with the recipe, while availability is re-read for each action.
local function CaptureCooldown(seconds, dayCooldown, charges, maxCharges)
    local now = GetServerTime and GetServerTime() or (time and time())
    local expires = type(seconds) == "number" and seconds > 0 and now
        and math.floor(now + seconds + 0.5) or nil
    local limited = dayCooldown == true or (type(maxCharges) == "number" and maxCharges > 0)
    local limit
    if limited then
        limit = type(charges) == "number" and math.max(0, math.floor(charges))
            or (expires and 0 or 1)
    end
    local maxExecutions = limit
    if limit == 0 and expires then maxExecutions = nil end
    return {
        cooldownUntil = (not limit or limit == 0) and expires or nil,
        cooldownRechargeAt = limit and limit > 0 and expires or nil,
        maxExecutions = maxExecutions,
        cooldownCharges = limit,
        maxCooldownCharges = type(maxCharges) == "number" and maxCharges > 0 and maxCharges or nil,
        sharedCooldownUnverified = limited or nil,
    }
end

local function ReadRequirements(recipeID, legacyIndex)
    if legacyIndex then
        if type(GetTradeSkillTools) == "function" then
            local requirements = {}
            local function CollectTools(...)
                for index = 1, select("#", ...), 2 do
                    local name, available = select(index, ...)
                    if type(name) == "string" and name ~= "" then
                        requirements[#requirements + 1] = { name = name, met = not not available }
                    end
                end
            end
            CollectTools(GetTradeSkillTools(legacyIndex))
            return requirements
        end
        return
    end
    local nativeRequirements = Call(C_TradeSkillUI, "GetRecipeRequirements", recipeID)
    if type(nativeRequirements) ~= "table" then return end
    local requirements = {}
    for _, requirement in ipairs(nativeRequirements) do
        requirements[#requirements + 1] = { name = requirement.name, met = requirement.met, kind = requirement.type }
    end
    return requirements
end

function Catalog.ReadConstraints(recipeID, legacyIndex)
    local seconds, dayCooldown, charges, maxCharges
    if legacyIndex then
        seconds, dayCooldown = Call(_G, "GetTradeSkillCooldown", legacyIndex)
    else
        seconds, dayCooldown, charges, maxCharges = Call(C_TradeSkillUI, "GetRecipeCooldown", recipeID)
    end
    local result = CaptureCooldown(seconds, dayCooldown, charges, maxCharges)
    result.requirements = ReadRequirements(recipeID, legacyIndex)
    for _, requirement in ipairs(result.requirements or {}) do
        if requirement.met == false then result.requirementsMet = false; break end
    end
    return result
end

local function ReagentChoices(schematic)
    local types = Enum and Enum.CraftingReagentType
    local slotTypes = Enum and Enum.TradeskillSlotDataType
    local choices = { { reagents = {} } }
    for index, slot in ipairs(schematic.reagentSlotSchematics) do
        local basic = not types or slot.reagentType == nil or slot.reagentType == types.Basic
        if basic or slot.required == true then
            local quantity = PositiveInteger(slot.quantityRequired)
            local slotIndex = PositiveInteger(slot.slotIndex) or index
            if not quantity or (type(slot.variableQuantities) == "table" and next(slot.variableQuantities)) then
                return nil, L.variableReagents
            end
            local options, seen = {}, {}
            for _, reagent in ipairs(slot.reagents or {}) do
                local id = PositiveInteger(reagent.itemID)
                if not id then
                    return nil, L.nonItemReagents
                end
                if not seen[id] then options[#options + 1] = id; seen[id] = true end
            end
            if #options == 0 then return nil, L.slotsLoading end
            if #options > 1 and slotTypes and slot.dataSlotType ~= slotTypes.ModifiedReagent then
                return nil, L.alternateSlotUnsupported
            end
            if #choices * #options > 128 then
                return nil, L.reagentLimit
            end
            table.sort(options)
            local expanded = {}
            for _, choice in ipairs(choices) do
                for _, id in ipairs(options) do
                    local reagents = {}
                    for i, reagent in ipairs(choice.reagents) do reagents[i] = reagent end
                    reagents[#reagents + 1] = { itemID = id, quantity = quantity, slotIndex = slotIndex }
                    expanded[#expanded + 1] = { reagents = reagents }
                end
            end
            choices = expanded
        end
    end
    return choices
end

function Catalog.GetSupersedingRank(info, recipeID)
    if ns.target ~= "forever" or type(info) ~= "table"
        or info.recipeID ~= recipeID or info.learned ~= true or not PositiveInteger(info.nextRecipeID) then return end
    local highest = Call(Professions, "GetHighestLearnedRecipe", info)
    local highestID = type(highest) == "table" and highest.learned == true and PositiveInteger(highest.recipeID)
    if not highestID or highestID == recipeID then return end
    -- A partial rank chain can stop before the input rank. Only a positive
    -- higher learned rank makes the exact lower recipe unavailable.
    local currentRank = PositiveInteger(Call(Professions, "GetRecipeRank", info))
    local highestRank = PositiveInteger(Call(Professions, "GetRecipeRank", highest))
    if currentRank and highestRank and highestRank > currentRank then return highestID end
end

function Catalog.ReadModernRecipe(recipeID, professionID)
    local api = C_TradeSkillUI
    local info = Call(api, "GetRecipeInfo", recipeID)
    if type(info) ~= "table" or info.learned ~= true or (info.recipeID and info.recipeID ~= recipeID) then
        return nil, L.recipeUnavailable
    end
    local profession = Call(api, "GetProfessionInfoByRecipeID", recipeID)
    local parent = type(profession) == "table" and (PositiveInteger(profession.parentProfessionID)
        or PositiveInteger(profession.professionID))
    if not parent then return nil, L.missingProfession end
    if parent and parent ~= professionID then return nil, L.differentProfession end
    local schematic = Call(api, "GetRecipeSchematic", recipeID, false)
    local result = { info = info, schematic = schematic, supersededByRecipeID = Catalog.GetSupersedingRank(info, recipeID) }
    if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
        result.loading = true
        result.blocker = L.schematicLoading
        return result
    end
    if #schematic.reagentSlotSchematics == 0 and Call(api, "HasNoReagentCost", recipeID) ~= true then
        result.loading = true
        result.blocker = L.emptyReagents
        return result
    end
    result.minYield = PositiveInteger(schematic.quantityMin)
    result.maxYield = PositiveInteger(schematic.quantityMax)
    local output = Call(api, "GetRecipeOutputItemData", recipeID)
    local outputLink = type(output) == "table" and output.hyperlink
    result.outputItemID = PositiveInteger(schematic.outputItemID)
        or (type(output) == "table" and (PositiveInteger(output.itemID) or ItemIDFromLink(outputLink)))
    if not result.outputItemID or ItemIDFromLink(outputLink) ~= result.outputItemID then
        outputLink = Call(api, "GetRecipeItemLink", recipeID)
        local linkItemID = ItemIDFromLink(outputLink)
        result.outputItemID = result.outputItemID or linkItemID
        if linkItemID ~= result.outputItemID then outputLink = nil end
    end
    result.outputLink = outputLink
    result.qualityOutput = info.supportsQualities == true
        or (type(info.qualityItemIDs) == "table" and #info.qualityItemIDs > 1)
    if info.isDummyRecipe or info.isGatheringRecipe or info.isEnchantingRecipe
        or info.isSalvageRecipe or info.isRecraft or schematic.isRecraft
        or (Enum and Enum.TradeskillRecipeType and schematic.recipeType ~= nil
            and schematic.recipeType ~= Enum.TradeskillRecipeType.Item) then
        result.special = true
        result.blocker = L.nativeOnly
    elseif result.qualityOutput or info.supportsCraftingStats == true then
        result.blocker = L.qualityVariant
    elseif (tonumber(info.unlockedRecipeLevel) or 0) > 1 then
        result.blocker = L.levelVariant
    elseif not result.outputItemID or not result.minYield or not result.maxYield or result.maxYield < result.minYield then
        result.blocker = L.missingOutput
    else
        result.choices, result.blocker = ReagentChoices(schematic)
    end
    result.constraints = Catalog.ReadConstraints(recipeID)
    result.constraints.canCreateMultiple = info.canCreateMultiple ~= false
    if info.disabled == true or info.craftable == false then
        result.constraints.requirementsMet = false
        result.constraints.blockedReason = info.disabledReason or L.missingRequirements
    end
    return result
end

local function Fingerprint(outputItemID, minYield, maxYield, reagents)
    if not PositiveInteger(outputItemID) or not PositiveInteger(minYield)
        or not PositiveInteger(maxYield) or type(reagents) ~= "table" then
        return nil
    end
    local parts = { tostring(outputItemID), tostring(minYield), tostring(maxYield) }
    for _, r in ipairs(reagents) do
        parts[#parts + 1] = tostring(r.itemID) .. "x" .. tostring(r.quantity)
    end
    return table.concat(parts, ":")
end

local function LegacyRow(index)
    index = PositiveInteger(index)
    if not index or not GetTradeSkillInfo then return nil end
    local name, kind = GetTradeSkillInfo(index)
    if not name or kind == "header" or kind == "subheader" then return nil end
    local outputLink = GetTradeSkillItemLink and GetTradeSkillItemLink(index)
    local outputItemID = ItemIDFromLink(outputLink)
    local qtyMin, qtyMax
    if GetTradeSkillNumMade then
        qtyMin, qtyMax = GetTradeSkillNumMade(index)
    end
    qtyMin = PositiveInteger(qtyMin)
    qtyMax = PositiveInteger(qtyMax or qtyMin)
    local reagents = {}
    if not (GetTradeSkillNumReagents and GetTradeSkillReagentInfo and GetTradeSkillReagentItemLink) then
        reagents = nil
    else
        local reagentCount = GetTradeSkillNumReagents(index)
        if type(reagentCount) ~= "number" then return nil end
        for reagentIndex = 1, reagentCount do
            local _, _, count = GetTradeSkillReagentInfo(index, reagentIndex)
            local link = GetTradeSkillReagentItemLink(index, reagentIndex)
            local id = ItemIDFromLink(link)
            count = PositiveInteger(count)
            if not id or not count then
                reagents = nil
                break
            end
            reagents[#reagents + 1] = { itemID = id, quantity = count }
        end
        reagents = NormalizeReagents(reagents)
    end
    local recipeLink = Call(_G, "GetTradeSkillRecipeLink", index)
    return {
        name = name,
        outputLink = outputLink,
        difficulty = kind,
        canSkillUp = kind == "optimal" or kind == "medium" or kind == "easy",
        outputItemID = outputItemID,
        yieldMin = qtyMin,
        yieldMax = qtyMax,
        reagents = reagents,
        legacySpellID = SpellIDFromRecipeLink(recipeLink),
        legacyFingerprint = Fingerprint(outputItemID, qtyMin, qtyMax, reagents),
    }
end

local function matchesLegacyProfession(recipe)
    if recipe.professionName and GetTradeSkillLine then
        local openName = GetTradeSkillLine()
        if openName ~= recipe.professionName and not (ns.Clients and tonumber(recipe.professionId)
            and ns.Clients.CurrentProfessionID() == tonumber(recipe.professionId)) then return false end
    end
    return true
end

local function matchesLegacyRow(recipe, rowIndex)
    local row = LegacyRow(rowIndex)
    if not row then return false end
    if recipe.legacySpellID then
        if recipe.legacySpellID ~= row.legacySpellID then return false end
    elseif recipe.name ~= row.name then return false end
    return recipe.legacyFingerprint ~= nil
        and recipe.legacyFingerprint == row.legacyFingerprint
end

function Catalog.MatchLegacyLive(recipe, rowIndex)
    return type(recipe) == "table" and recipe.legacy == true and matchesLegacyProfession(recipe)
        and matchesLegacyRow(recipe, rowIndex)
end

-- Returns a fresh row index only after unique identity matching.
function Catalog.ResolveLive(recipe)
    if type(recipe) ~= "table" then return nil, L.missingRecipe end
    if Catalog.IsForeignSession() then return nil, L.ownProfession end
    if not recipe.legacy then
        local api = rawget(_G, "C_TradeSkillUI")
        if not (api and type(api.GetRecipeInfo) == "function") then
            return nil, L.modernUnavailable
        end
        local id = PositiveInteger(recipe.recipeID or recipe.id)
        if not id then return nil, L.missingRecipeID end
        local ok, info = pcall(api.GetRecipeInfo, id)
        if not ok or type(info) ~= "table" or info.learned ~= true then
            return nil, L.notLearned
        end
        return id
    end
    if not (GetNumTradeSkills and GetTradeSkillInfo) then
        return nil, L.closed
    end
    if not matchesLegacyProfession(recipe) then return nil, L.notVisible end
    local found
    for i = 1, (GetNumTradeSkills() or 0) do
        if matchesLegacyRow(recipe, i) then
            if found then return nil, L.ambiguous end
            found = i
        end
    end
    if not found then return nil, L.notVisible end
    return found
end

function Catalog.ReadLiveRequirements(recipe, legacyIndex)
    if Catalog.IsForeignSession() then return end
    if not recipe.legacy then
        local id = PositiveInteger(recipe.recipeID or recipe.id)
        if id then return ReadRequirements(id) end
        return
    end
    if not legacyIndex or not Catalog.MatchLegacyLive(recipe, legacyIndex) then
        legacyIndex = Catalog.ResolveLive(recipe)
    end
    if legacyIndex then return ReadRequirements(nil, legacyIndex), legacyIndex end
end

local function KnownProfessions()
    if ns.Clients and ns.Clients.ListProfessions then return ns.Clients.ListProfessions() end
    local out = {}
    if not (GetProfessions and GetProfessionInfo) then return out end
    local count = select("#", GetProfessions())
    local indices = { GetProfessions() }
    for slot = 1, count do
        local index = indices[slot]
        if index then
            local name, _, _, _, _, _, skillLineID = GetProfessionInfo(index)
            if name then
                out[#out + 1] = { id = PositiveInteger(skillLineID), name = name, index = index }
            end
        end
    end
    return out
end

function Catalog.KnownProfessions()
    return KnownProfessions()
end

local function OpenOwnProfession(known)
    if Catalog.IsForeignSession() then return nil, L.ownProfession end
    local id, name
    if ns.Clients then
        id = ns.Clients.CurrentProfessionID(known)
        if id and ns.target ~= "forever" and GetTradeSkillLine then name = GetTradeSkillLine() end
    elseif C_TradeSkillUI and type(C_TradeSkillUI.GetBaseProfessionInfo) == "function" then
        if type(C_TradeSkillUI.IsTradeSkillReady) == "function"
            and not C_TradeSkillUI.IsTradeSkillReady() then return nil, L.stillLoading end
        local info = Call(C_TradeSkillUI, "GetBaseProfessionInfo")
        id = type(info) == "table" and PositiveInteger(info.professionID)
    elseif GetTradeSkillLine and GetNumTradeSkills and (GetNumTradeSkills() or 0) > 0 then
        name = GetTradeSkillLine()
    end
    for _, profession in ipairs(known) do
        if profession.id and (profession.id == id or (not id and name and name == profession.name)) then
            if name and name ~= profession.name then return {id = profession.id, name = name} end
            return profession
        end
    end
    return nil, L.readyProfession
end

local function LegacyRecipe(row, open)
    local index = PositiveInteger(row.recipeID)
    local live = index and LegacyRow(index)
    if not live then return nil end
    local signature = Fingerprint(row.outputItemID or ItemIDFromLink(row.outputLink),
        row.quantityMin, row.quantityMax, NormalizeReagents(row.reagents))
    if not (live.legacySpellID or live.legacyFingerprint) then return nil end
    if signature ~= live.legacyFingerprint or (not signature and live.name ~= row.name) then
        -- Cached legacy rows can have changed indices after search or filter changes.
        return nil
    end
    local id = live.legacySpellID and "legacy:spell:" .. live.legacySpellID
        or "legacy:fp:" .. open.id .. ":" .. live.legacyFingerprint
    local complete = live.legacyFingerprint ~= nil
    return {
        id = id,
        legacy = true,
        legacySpellID = live.legacySpellID,
        legacyFingerprint = live.legacyFingerprint,
        name = live.name,
        outputKind = live.outputItemID and "item" or "special",
        outputItemID = live.outputItemID,
        outputLink = live.outputLink,
        yield = live.yieldMin,
        yieldMin = live.yieldMin,
        yieldMax = live.yieldMax,
        reagents = live.reagents or {},
        difficulty = live.difficulty,
        canSkillUp = live.canSkillUp,
        constraints = Catalog.ReadConstraints(nil, index),
        completeness = complete and "complete" or "partial",
        blocker = not complete and L.incompleteRecipe or nil,
    }
end

local function ModernRecipe(row, open)
    local id = PositiveInteger(row.recipeID)
    if not id then return nil end
    local live = Catalog.ReadModernRecipe(id, open.id)
    if not live then return nil end
    local info = live.info
    return {
        id = id,
        recipeID = id,
        name = info.name or row.name,
        outputKind = live.outputItemID and not live.special and "item" or "special",
        outputItemID = live.outputItemID or PositiveInteger(row.outputItemID),
        outputLink = live.outputLink or (ItemIDFromLink(row.outputLink) == live.outputItemID and row.outputLink or nil),
        yield = live.minYield,
        yieldMin = live.minYield,
        yieldMax = live.maxYield,
        reagents = live.choices and NormalizeReagents(live.choices[1].reagents)
            or NormalizeReagents(row.reagents) or {},
        reagentChoices = live.choices,
        constraints = live.constraints or {},
        supersededByRecipeID = live.supersededByRecipeID,
        difficulty = info.relativeDifficulty,
        canSkillUp = info.canSkillUp,
        numSkillUps = PositiveInteger(info.numSkillUps),
        maxTrivialLevel = PositiveInteger(info.maxTrivialLevel),
        categoryID = info.categoryID,
        completeness = live.choices and "complete" or "partial",
        blocker = live.blocker,
        -- Only incomplete loading reads may preserve the previous qualified shape.
        loading = live.loading,
    }
end

local function NormalizeRow(row, open, completeness)
    if type(row) ~= "table" or row.learned == false then return nil end
    if row.legacy then
        if row.skillName ~= open.name then return nil end
    elseif tonumber(row.skillLineID) ~= open.id
        and (row.skillLineID ~= nil or row.skillName ~= open.name) then
        return nil
    end
    local recipe
    if row.legacy then recipe = LegacyRecipe(row, open)
    else recipe = ModernRecipe(row, open) end
    if not recipe then return nil end
    recipe.professionId = open.id
    recipe.professionName = open.name
    recipe.characterKey = CharacterKey()
    recipe.build = Build()
    recipe.learned = true
    recipe.observationSource = completeness or "cached"
    return recipe
end

local function EqualValue(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for key, value in pairs(a) do
        if not EqualValue(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function SameRecipeShape(a, b)
    return a.id == b.id and a.recipeID == b.recipeID
        and a.legacySpellID == b.legacySpellID and a.legacyFingerprint == b.legacyFingerprint
        and a.professionId == b.professionId and a.outputKind == b.outputKind
        and a.outputItemID == b.outputItemID and a.yield == b.yield
        and a.yieldMax == b.yieldMax and a.completeness == b.completeness
        and a.learned == b.learned and EqualValue(a.reagents, b.reagents)
        and EqualValue(a.reagentChoices, b.reagentChoices)
end

local function MergeRecipe(old, new, lostRecipes)
    local higherID = new.supersededByRecipeID
    if not higherID and old and old.learned and not lostRecipes[old.supersededByRecipeID] then
        higherID = old.supersededByRecipeID
    end
    if old and new.loading then
        if old.supersededByRecipeID == higherID or not old.learned then return old end
        new = {}
        for key, value in pairs(old) do new[key] = value end
    end
    new.supersededByRecipeID = higherID
    if higherID then
        new.blockedReason = ns.L.clients.supersededRank
    elseif old and old.supersededByRecipeID then
        new.blockedReason = nil
    end
    if not old then new.revision = 1; return new end
    local revision = tonumber(old.revision) or 0
    if SameRecipeShape(old, new) then
        new.revision = revision
        -- Both updates describe the same cooldown when native seconds round differently.
        for _, key in ipairs({"cooldownUntil", "cooldownRechargeAt"}) do
            local before = old.constraints and old.constraints[key]
            local after = new.constraints and new.constraints[key]
            if before and after and math.abs(before - after) <= 1 then new.constraints[key] = before end
        end
        if EqualValue(old, new) then return old end
    else
        new.revision = revision + 1
    end
    return new
end

local function Revocation(bucket, id, reason)
    local recipe = bucket.recipesById and bucket.recipesById[id]
    if not recipe or recipe.learned == false then return false end
    local retired = {}
    for key, value in pairs(recipe) do retired[key] = value end
    retired.learned = false
    retired.revision = (tonumber(recipe.revision) or 0) + 1
    retired.blocker = reason
    bucket.recipesById[id] = retired
    return true
end

local function RevokeProfession(bucket)
    local changed = false
    for id in pairs(bucket.recipesById or {}) do
        if Revocation(bucket, id, L.unlearnedProfession) then changed = true end
    end
    return changed
end

local function Changed(store)
    store.revision = (tonumber(store.revision) or 0) + 1
    snapshotCache = nil
end

local function RecordLosses(prof, professions)
    local changed, lostProfessions, lostRecipes = false, {}, {}
    for _, bucket in pairs(professions) do
        local learned = Call(prof, "GetProfessionKnowledge", bucket.name, bucket.id)
        if learned == false then
            if bucket.id then lostProfessions[bucket.id] = true end
            if RevokeProfession(bucket) then changed = true end
        elseif type(prof.GetSkillInfo) == "function" then
            -- FluxUI publishes retained tombstones from an owned, settled native scan.
            local idData = Call(prof, "GetSkillInfo", bucket.id)
            local nameData = bucket.name and Call(prof, "GetSkillInfo", bucket.name)
            for id, recipe in pairs(bucket.recipesById or {}) do
                local modernID = recipe.recipeID
                local function WasRevoked(data)
                    return type(data) == "table" and type(data.unlearnedRecipeIDs) == "table"
                        and data.unlearnedRecipeIDs[modernID] == true
                end
                if modernID and (WasRevoked(idData) or WasRevoked(nameData)) then
                    lostRecipes[id] = true
                    if Revocation(bucket, id, L.unlearnedRecipe) then changed = true end
                end
            end
        end
    end
    return changed, lostProfessions, lostRecipes
end

function Catalog.Refresh()
    local prof = InventoryProfessions()
    if not (prof and type(prof.ListCachedRecipes) == "function") then
        return false, L.noProvider
    end
    local store, professions = ProfStore()
    local known = KnownProfessions()
    local roster = {}
    for _, profession in ipairs(known) do
        roster[#roster + 1] = tostring(profession.id) .. "=" .. profession.name
    end
    local rosterKey = table.concat(roster, ";")
    if rosterKey ~= Catalog.rosterKey then
        Catalog.rosterKey = rosterKey
        snapshotCache = nil
    end
    local changed, lostProfessions, lostRecipes = RecordLosses(prof, professions)
    local open, reason = OpenOwnProfession(known)
    if not open then
        if changed then Changed(store) end
        return false, reason
    end
    if lostProfessions[open.id] then
        if changed then Changed(store) end
        return false, L.unlearnedProfession
    end
    local rows, completeness = prof.ListCachedRecipes(open.id)
    if (type(rows) ~= "table" or #rows == 0) and open.name then
        rows, completeness = prof.ListCachedRecipes(open.name)
    end
    if type(rows) ~= "table" then
        if changed then Changed(store) end
        return false, L.noRecipes
    end

    local observed, duplicate, higherRanks = {}, {}, {}
    local professionKey = tostring(open.id)
    local bucket = professions[professionKey]
    for _, row in ipairs(rows) do
        local recipe = NormalizeRow(row, open, completeness)
        if recipe and not lostRecipes[recipe.id] then
            if observed[recipe.id] then duplicate[recipe.id] = true end
            observed[recipe.id] = recipe
            if recipe.supersededByRecipeID then higherRanks[recipe.supersededByRecipeID] = true end
        end
    end
    -- The native list may supply only the first rank. Qualify a directly
    -- observed higher sibling against the same open profession before using it.
    for id in pairs(higherRanks) do
        if not observed[id] and not lostRecipes[id] then
            observed[id] = NormalizeRow({recipeID = id, skillLineID = open.id}, open, completeness)
        end
    end
    for id, recipe in pairs(observed) do
        if not bucket then
            bucket = { id = open.id, name = open.name, recipesById = {}, observed = true }
            professions[professionKey] = bucket
        end
        bucket.recipesById = bucket.recipesById or {}
        bucket.name = open.name
        bucket.observed = true
        if recipe.legacy and duplicate[id] then
            recipe.completeness = "partial"
            recipe.blocker = L.duplicateIdentity
        end
        local old = bucket.recipesById[id]
        local merged = MergeRecipe(old, recipe, lostRecipes)
        if old ~= merged then
            bucket.recipesById[id] = merged
            changed = true
        end
    end
    if changed then Changed(store) end
    return true, changed
end

function Catalog.Snapshot()
    local store, professions = ProfStore()
    if snapshotCache and snapshotCache.store == store and snapshotCache.revision == store.revision then
        return snapshotCache.value
    end
    local snapshot = {
        recipesById = {}, byOutput = {}, unobservedProfessions = {}, invalidatedRecipes = {},
        revision = tonumber(store.revision) or 0,
        characterKey = CharacterKey(), build = Build(),
    }
    local rank = {}
    for _, bucket in pairs(professions) do
        for id, recipe in pairs(bucket.recipesById or {}) do
            local quality = recipe.learned ~= true and 0 or (recipe.completeness == "complete" and 2 or 1)
            if rank[id] == nil or quality > rank[id] then
                rank[id] = quality
                snapshot.recipesById[id] = recipe
            end
        end
    end
    for id, recipe in pairs(snapshot.recipesById) do
        if recipe.learned == false then
            snapshot.invalidatedRecipes[id] = recipe.blocker or true
        elseif recipe.learned == true and recipe.outputKind == "item" and recipe.outputItemID
            and not recipe.supersededByRecipeID then
            local list = snapshot.byOutput[recipe.outputItemID]
            if not list then list = {}; snapshot.byOutput[recipe.outputItemID] = list end
            list[#list + 1] = id
        end
    end
    for _, list in pairs(snapshot.byOutput) do
        table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
    end
    for _, profession in ipairs(KnownProfessions()) do
        local bucket = profession.id and professions[tostring(profession.id)]
        if not (bucket and bucket.observed) then
            snapshot.unobservedProfessions[#snapshot.unobservedProfessions + 1] = {
                id = profession.id, name = profession.name,
                message = L.discover:format(profession.name),
            }
        end
    end
    snapshotCache = { store = store, revision = store.revision, value = snapshot }
    return snapshot
end

function Catalog.Get(recipeId)
    return Catalog.Snapshot().recipesById[recipeId]
end

-- Read-only summaries for UI; never included in Snapshot/eligible planning.
function Catalog.OtherCharacters()
    local db = rawget(_G, "FluxLogisticsDB")
    local chars = db and db.catalog and db.catalog.characters or {}
    local out = {}
    for key, record in pairs(chars) do
        if key ~= CharacterKey() then
            local builds = record.builds or {}
            local current = builds[Build()]
            if current then
                local professionCount, recipeCount = 0, 0
                for _, bucket in pairs(current.professions or {}) do
                    professionCount = professionCount + 1
                    for _ in pairs(bucket.recipesById or {}) do recipeCount = recipeCount + 1 end
                end
                out[#out + 1] = { characterKey = key, professionCount = professionCount,
                    recipeCount = recipeCount, informationalOnly = true }
            end
        end
    end
    return out
end

return Catalog
