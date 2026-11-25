-- Synthetic, desktop-only contracts for FluxCraft's external boundaries.
-- Run: lua FluxCraft/Tests/AdaptersCatalog.lua
local ns = { state = {} }
local function loadModule(path)
    return assert(loadfile(path))("FluxCraft", ns)
end
loadModule("FluxCraft/Locale.lua")
local Inventory = loadModule("FluxCraft/AdaptersInventory.lua")
local Auctionator = loadModule("FluxCraft/AdaptersAuctionator.lua")
local Catalog = loadModule("FluxCraft/Catalog.lua")

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "assertion") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function useCharacter(key, build)
    _G.FluxLogisticsDB = _G.FluxLogisticsDB or { catalog = { characters = {} } }
    local chars = _G.FluxLogisticsDB.catalog.characters
    chars[key] = chars[key] or { builds = {} }
    local builds = chars[key].builds
    builds[build] = builds[build] or { professions = {}, revision = 0 }
    ns.state.characterKey = key
    ns.state.build = build
    ns.state.catalogBuildStore = builds[build]
end

-- FluxUI is required: missing facade never triggers independent scanning.
_G.Flux = nil
equal(Inventory.Start(), false, "missing FluxUI refuses binding")
equal(Inventory.Count(100), nil, "missing FluxUI has no eligible count")
equal(Auctionator.GetQuote(100), nil, "missing Auctionator quote remains unknown")

local previousServerTime, previousTradeSkillAPI = GetServerTime, C_TradeSkillUI
GetServerTime = function() return 1000 end
C_TradeSkillUI = {GetRecipeCooldown = function() return 60, false, 1, 2 end}
local charges = Catalog.ReadConstraints(100)
equal(charges.cooldownRechargeAt, 1060, "an available charge still tracks its recharge")
equal(charges.cooldownUntil, nil, "a recharge cannot block an available charge")
equal(charges.maxExecutions, 1, "one charge permits exactly one craft")
equal(charges.maxCooldownCharges, 2, "charge display preserves the native maximum")
C_TradeSkillUI.GetRecipeCooldown = function() return 60, true, 0, 2 end
charges = Catalog.ReadConstraints(100)
equal(charges.cooldownUntil, 1060, "zero charges block until the cooldown expires")
equal(charges.cooldownRechargeAt, nil, "blocked recharge is represented once")
GetServerTime, C_TradeSkillUI = previousServerTime, previousTradeSkillAPI

local source, ready, reliable = "builtin", true, true
local currentCounts = { [100] = 3, [200] = 7 }
local listener
_G.Flux = { Inventory = {
    IsReady = function() return ready end,
    IsReliable = function() return reliable end,
    GetSource = function() return source end,
    GetSnapshotGeneration = function() return 4 end,
    GetCount = function(itemID, opts)
        equal(opts.bank, false, "eligible inventory excludes bank")
        equal(opts.warband, false, "eligible inventory excludes warband")
        return currentCounts[itemID] or 0
    end,
    GetUniqueItems = function() return { [100] = { count = currentCounts[100] or 0 },
        [200] = { count = currentCounts[200] or 0 } } end,
    Register = function(key, callback) listener = callback end,
    Unregister = function() listener = nil end,
} }
local changes = {}
equal(Inventory.Start(function(status) changes[#changes + 1] = status end), true,
    "binds FluxUI facade")
equal(Inventory.Count(100), 3, "builtin bags count")
local snap = Inventory.Snapshot()
equal(snap[200], 7, "detached snapshot")
source, currentCounts = "syndicator", { [100] = 5, [200] = 1 }
listener({ regions = { bags = true }, source = source })
equal(changes[1].handover, true, "backend handover reported")
equal(Inventory.Count(100), 5, "selected facade count, no duplicate sum")
reliable = false
equal(Inventory.Count(100), nil, "settling snapshot cannot reserve")
reliable = true
Inventory.Stop()
equal(listener, nil, "listener removed")

local updatePrices
_G.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(caller, id)
        equal(caller, "FluxCraft", "caller ID")
        return id == 100 and 125.5 or 0
    end,
    GetAuctionAgeByItemID = function() return 2 end,
    GetAuctionPriceByItemLink = function(_, link)
        if link == "|Hitem:100:0:0:0|h[item]|h" then return 150 end
    end,
    GetAuctionAgeByItemLink = function() return 1 end,
    IsAuctionDataExactByItemLink = function() return false end,
    RegisterForDBUpdate = function(_, callback) updatePrices = callback end,
} } }
local quote = Auctionator.GetQuote(100)
equal(quote.unitPrice, 125.5, "preserves API price precision")
equal(quote.age, 2, "verified public quote age")
equal(quote.estimate, true, "cached quote is estimate")
equal(quote.availability, "unknown", "cached quote does not prove depth")
equal(Auctionator.GetQuote(200), nil, "zero is unknown price")
local linkedQuote = Auctionator.GetQuote(100, "|Hitem:100:0:0:0|h[item]|h")
equal(linkedQuote.unitPrice, 125.5, "inexact link uses the ordinary item ID price")
equal(linkedQuote.variantExact, false, "fallback identity remains labeled")
equal(linkedQuote.itemLink, nil, "inexact quote identifies its actual item ID basis")
equal(linkedQuote.requestedItemLink, "|Hitem:100:0:0:0|h[item]|h", "requested link remains available")
equal(linkedQuote.age, 2, "item ID price age used")
_G.Auctionator.API.v1.IsAuctionDataExactByItemLink = function() return true end
local exactQuote = Auctionator.GetQuote(100, "|Hitem:100:0:0:0|h[item]|h")
equal(exactQuote.unitPrice, 150, "link-specific price used for an exact quote")
equal(exactQuote.age, 1, "link-specific age used")
_G.Auctionator.API.v1.GetAuctionAgeByItemID = nil
local noAgeQuote = Auctionator.GetQuote(100)
equal(noAgeQuote.stale, false, "missing age method does not discard priced estimate")
equal(noAgeQuote.ageUnknown, true, "missing age method disclosed")
_G.Auctionator.API.v1.GetAuctionAgeByItemID = function() return 2 end
local priceRevision
equal(Auctionator.Start(function(revision) priceRevision = revision end), true,
    "public price update callback registered")
updatePrices()
equal(priceRevision, 1, "price revision advances after DB update")

useCharacter("A", 16001)
local rows = {
    { recipeID = 10, skillLineID = 171, skillName = "Alchemy", learned = true,
      outputItemID = 300, quantityMin = 1, quantityMax = 1,
      reagents = { { itemID = 200, count = 2 } } },
    { recipeID = 11, skillLineID = 197, skillName = "Tailoring", learned = true,
      outputItemID = 400, quantityMin = 2, quantityMax = 2,
      reagents = { { itemID = 300, count = 1 } } },
}
_G.Flux.Inventory.Professions = {
    ListCachedRecipes = function(skillKey)
        local result = {}
        for _, row in ipairs(rows) do
            if tostring(row.skillLineID) == tostring(skillKey) or row.skillName == skillKey then
                result[#result + 1] = row
            end
        end
        return result
    end,
    GetCompleteness = function() return "cached" end,
}
_G.GetProfessions = function() return 1, 2, nil, 3 end
_G.GetProfessionInfo = function(index)
    if index == 1 then return "Alchemy", nil, nil, nil, nil, nil, 171 end
    if index == 2 then return "Tailoring", nil, nil, nil, nil, nil, 197 end
    if index == 3 then return "Cooking", nil, nil, nil, nil, nil, 185 end
end
local openProfessionID = 171
local nativeOutputLink = "|Hitem:300:0:0:0:0:0:42:0|h[Fresh output]|h"
rows[1].outputLink = "|Hitem:300:0:0:0:0:0:41:0|h[Cached output]|h"
rows[2].outputLink = "|Hitem:999|h[Unrelated cached output]|h"
_G.C_TradeSkillUI = {
    GetBaseProfessionInfo = function() return { professionID = openProfessionID } end,
    IsTradeSkillReady = function() return true end,
    GetRecipeInfo = function(recipeID)
        if recipeID == 13 then
            return { learned = true, qualityItemIDs = { 601, 602 },
                supportsCraftingStats = true }
        end
        return { learned = true }
    end,
    GetRecipeSchematic = function(recipeID)
        local details = { [10] = { 300, 1, 200, 2 },
            [11] = { 400, 2, 300, 1 }, [12] = { 500, 1, 100, 1 },
            [13] = { 601, 1, 100, 1 } }
        local d = details[recipeID]
        return { outputItemID = d[1], quantityMin = d[2], quantityMax = d[2],
            reagentSlotSchematics = { { quantityRequired = d[4],
                reagents = { { itemID = d[3] } } } } }
    end,
    GetProfessionInfoByRecipeID = function(recipeID)
        return { professionID = (recipeID == 10 or recipeID == 12 or recipeID == 13)
            and 171 or 197 }
    end,
    GetRecipeOutputItemData = function(recipeID)
        if recipeID == 10 then return {itemID = 300, hyperlink = nativeOutputLink} end
    end,
}
equal(Catalog.Refresh(), true, "catalog refresh from FluxUI")
openProfessionID = 197
Catalog.Refresh()
local catalog = Catalog.Snapshot()
equal(catalog.byOutput[300][1], 10, "alchemy recipe indexed")
equal(catalog.byOutput[400][1], 11, "tailoring recipe indexed")
equal(catalog.recipesById[10].outputLink, nativeOutputLink, "current output variant replaces the owner's cached link")
equal(catalog.recipesById[11].outputLink, nil, "a stale link for another output cannot replace the current item")
equal(catalog.unobservedProfessions[1].name, "Cooking", "sparse secondary discovered")
local revision = catalog.revision
Catalog.Refresh()
equal(Catalog.Snapshot().revision, revision, "unchanged observations do not churn revision")

-- Partial/filtered observations retain prior professions and recipes.
rows = { rows[2] }
Catalog.Refresh()
equal(Catalog.Snapshot().byOutput[300][1], 10, "filtered list does not erase Alchemy")
local retiredRecipe
local learnedProfession = true
_G.Flux.Inventory.Professions.GetProfessionKnowledge = function(_, skillID)
    if skillID == 171 then return learnedProfession end
end
_G.Flux.Inventory.Professions.GetSkillInfo = function(skillID)
    if tonumber(skillID) == 197 and retiredRecipe then
        return {unlearnedRecipeIDs = {[11] = true}}
    end
end
retiredRecipe = true
Catalog.Refresh()
equal(Catalog.Snapshot().recipesById[11].learned, false, "owner tombstone invalidates despite a stale cached row")
equal(Catalog.Snapshot().invalidatedRecipes[11] ~= nil, true, "loss reason exposed to the queue")
equal(Catalog.Snapshot().byOutput[400], nil, "revoked recipe cannot supply an intermediate")
local invalidatedRevision = Catalog.Snapshot().recipesById[11].revision
retiredRecipe = false
Catalog.Refresh()
equal(Catalog.Snapshot().recipesById[11].learned, true, "fresh owned live observation activates relearned recipe")
equal(Catalog.Snapshot().recipesById[11].revision > invalidatedRevision, true, "relearn requires a new accepted revision")
learnedProfession = false
Catalog.Refresh()
equal(Catalog.Snapshot().recipesById[10].learned, false, "authoritative profession loss retires all its recipes")
equal(Catalog.Snapshot().byOutput[300], nil, "retired profession excluded from planning")
learnedProfession = true
rows[2] = { recipeID = 10, skillLineID = 171, skillName = "Alchemy", learned = true,
    outputItemID = 300, quantityMin = 1, quantityMax = 1,
    reagents = { { itemID = 200, count = 2 } } }
openProfessionID = 171
Catalog.Refresh()
equal(Catalog.Snapshot().recipesById[10].learned, true, "fresh own-session recipe restores profession data")
useCharacter("B", 16001)
rows = { { recipeID = 12, skillLineID = 171, skillName = "Alchemy", learned = true,
    outputItemID = 500, quantityMin = 1, quantityMax = 1,
    reagents = { { itemID = 100, count = 1 } } } }
openProfessionID = 171
Catalog.Refresh()
equal(Catalog.Snapshot().byOutput[300], nil, "alt recipes excluded from current snapshot")
useCharacter("A", 16001)
equal(Catalog.Snapshot().byOutput[300][1], 10, "other character login preserves prior memory")
equal(Catalog.OtherCharacters()[1].informationalOnly, true, "alt memory informational")
rows = { { recipeID = 13, skillLineID = 171, skillName = "Alchemy", learned = true,
    outputItemID = 601, quantityMin = 1, quantityMax = 1,
    reagents = { { itemID = 100, count = 1 } } } }
openProfessionID = 171
Catalog.Refresh()
equal(Catalog.Snapshot().recipesById[13].completeness, "partial",
    "quality and proc recipe cannot claim exact deterministic output")
_G.IsTradeSkillLinked = function() return true end
local beforeLinked = Catalog.Snapshot().revision
equal(Catalog.Refresh(), false, "linked profession does not enter current character cache")
equal(Catalog.Snapshot().revision, beforeLinked, "linked view leaves catalog unchanged")
_G.IsTradeSkillLinked = nil

-- Forever can expose the first rank in a filtered recipe list. Once the
-- higher sibling is learned, the native page always opens its schematic.
ns.target = "forever"
useCharacter("Ranks", 16001)
local Planner = loadModule("FluxCraft/Planner.lua")
loadModule("FluxCraft/Queue.lua")
local Queue = ns.Queue
assert(Queue.Initialize({}))
local lowerRank = {recipeID = 41, nextRecipeID = 42, learned = true}
local higherRank = {recipeID = 42, previousRecipeID = 41, learned = false}
local destinationRecipe = {recipeID = 43, learned = true}
rows = {{recipeID = 41, skillLineID = 171, learned = true},
    {recipeID = 43, skillLineID = 197, learned = true}}
local recipeInfo = {[41] = lowerRank, [42] = higherRank, [43] = destinationRecipe}
local craftFacts = {[41] = {800, 811, 2}, [42] = {800, 812, 1}, [43] = {900, 800, 1}}
local lowerSchematicReady = true
C_TradeSkillUI.GetRecipeInfo = function(id) return recipeInfo[id] end
C_TradeSkillUI.GetRecipeSchematic = function(id)
    if id == 41 and not lowerSchematicReady then return end
    local facts = craftFacts[id]
    return {outputItemID = facts[1], quantityMin = 1, quantityMax = 1,
        reagentSlotSchematics = {{quantityRequired = facts[3], reagents = {{itemID = facts[2]}}}}}
end
C_TradeSkillUI.GetProfessionInfoByRecipeID = function(id) return {professionID = id == 43 and 197 or 171} end
local rankAPI = {
    GetHighestLearnedRecipe = function(info)
        return (info == lowerRank or info == higherRank) and higherRank.learned and higherRank or info
    end,
    GetRecipeRank = function(info) return info == higherRank and 2 or 1 end,
}
Professions = rankAPI
assert(Catalog.Refresh())
local oldLower = Catalog.Get(41)
equal(oldLower.supersededByRecipeID, nil, "an unlearned higher rank keeps the exact lower rank available")
openProfessionID = 197
assert(Catalog.Refresh())
local function rankedPreview(recipeID)
    return Planner.Preview({catalog = Catalog.Snapshot(), rootRecipeId = recipeID or 43, characterKey = "Ranks",
        quantity = 1, inventory = {[811] = 2, [812] = 1},
        quotes = {[800] = 100, [811] = 1, [812] = 20}, inspectUnavailable = true})
end
local oldJob = assert(Queue.Accept(rankedPreview(), rankedPreview))
local _, oldProducer = Queue.NextTask(171, oldJob)
equal(oldProducer.recipeId, 41, "queue originally records the exact then-available prerequisite")

openProfessionID, higherRank.learned, lowerSchematicReady = 171, true, false
assert(Catalog.Refresh())
local retainedLower = Catalog.Get(41)
equal(retainedLower.supersededByRecipeID, 42, "learned sibling can qualify during a partial schematic read")
equal(retainedLower.completeness, "complete", "lower rank remains inspectable with its saved shape")
equal(retainedLower.revision, oldLower.revision, "rank availability does not change the saved recipe shape")
equal(Catalog.Snapshot().byOutput[800][1], 42, "highest rank can be qualified from the positively linked sibling")
equal(#Catalog.Snapshot().byOutput[800], 1, "superseded lower rank cannot supply another recipe")
local lowerPreview = rankedPreview(41)
equal(lowerPreview.status, "blocked", "an explicit lower-rank preview is blocked")
equal(lowerPreview.tree.itemID, 800, "blocked lower preview retains its output for inspection")
equal(lowerPreview.blocker, ns.L.clients.supersededRank, "inspectable lower rank gives a specific reason")

lowerSchematicReady, Professions = true, nil
assert(Catalog.Refresh())
equal(Catalog.Get(41).supersededByRecipeID, 42, "missing live rank API does not discard qualified evidence")
openProfessionID = 197
assert(Catalog.Refresh())
local nextJob = assert(Queue.Accept(rankedPreview(), rankedPreview))
local _, nextProducer = Queue.NextTask(171, nextJob)
equal(nextProducer.recipeId, 42, "new cross-profession queue uses the executable learned prerequisite")
equal(oldProducer.recipeId, 41, "existing accepted prerequisite is never retargeted")

local previousSkillInfo = Flux.Inventory.Professions.GetSkillInfo
Flux.Inventory.Professions.GetSkillInfo = function(skillID)
    if tonumber(skillID) == 171 then return {unlearnedRecipeIDs = {[42] = true}} end
end
higherRank.learned = false
assert(Catalog.Refresh())
equal(Catalog.Get(41).supersededByRecipeID, 42, "closed profession awaits an owned lower-rank recheck")
openProfessionID, Professions = 171, rankAPI
assert(Catalog.Refresh())
equal(Catalog.Get(42).learned, false, "authoritative owner tombstone retires the higher rank")
equal(Catalog.Get(41).supersededByRecipeID, nil, "authoritative unlearning clears old rank availability")
equal(Catalog.Get(41).completeness, "complete", "requalified lower rank keeps the exact recipe shape")
equal(Catalog.Snapshot().byOutput[800][1], 41, "remaining learned lower rank can supply future plans")
equal(nextProducer.recipeId, 42, "the previously accepted higher-rank task is left exact")
Flux.Inventory.Professions.GetSkillInfo = previousSkillInfo

ns.target, Professions = nil, nil
useCharacter("A", 16001)

-- Classic's cached list index is transient. A recipe link identifies the spell;
-- an exact live signature must still be re-resolved after a filter change.
local liveRows = {
    { output = 600, reagent = 200, count = 2, spell = 9001 },
}
_G.C_TradeSkillUI = nil
_G.GetTradeSkillLine = function() return "Tailoring" end
_G.GetNumTradeSkills = function() return #liveRows end
_G.GetTradeSkillInfo = function(i) return liveRows[i] and "Synthetic Bolt", "optimal" end
_G.GetTradeSkillItemLink = function(i) return "|Hitem:" .. liveRows[i].output .. "|h[item]|h" end
_G.GetTradeSkillNumMade = function() return 1, 1 end
_G.GetTradeSkillNumReagents = function() return 1 end
_G.GetTradeSkillReagentInfo = function(i) return "Synthetic Cloth", nil, liveRows[i].count end
_G.GetTradeSkillReagentItemLink = function(i) return "|Hitem:" .. liveRows[i].reagent .. "|h[item]|h" end
_G.GetTradeSkillRecipeLink = function(i) return "|Henchant:" .. liveRows[i].spell .. "|h[recipe]|h" end
rows = { { recipeID = 1, legacy = true, skillLineID = 197, skillName = "Tailoring",
    outputItemID = 600, quantityMin = 1, quantityMax = 1,
    reagents = { { itemID = 200, count = 2 } }, learned = true } }
Catalog.Refresh()
local legacy = Catalog.Snapshot().recipesById["legacy:spell:9001"]
equal(legacy ~= nil, true, "legacy stable spell ID captured")
liveRows = { { output = 700, reagent = 100, count = 1, spell = 9002 },
    { output = 600, reagent = 200, count = 2, spell = 9001 } }
equal(Catalog.MatchLegacyLive(legacy, 1), false, "stale row rejected")
equal(Catalog.ResolveLive(legacy), 2, "exact recipe found at new row")
liveRows[3] = { output = 600, reagent = 200, count = 2, spell = 9001 }
equal(Catalog.ResolveLive(legacy), nil, "ambiguous duplicate live recipe blocked")

liveRows = {{output = 600, reagent = 200, count = 2}}
_G.GetTradeSkillRecipeLink = function() return nil end
local fingerprint = "legacy:fp:197:600:1:1:200x2"
local stored = ns.state.catalogBuildStore.professions["197"].recipesById
stored[fingerprint] = {id = fingerprint, name = "Synthetic Bolt", completeness = "partial", revision = 1}
Catalog.Refresh()
local unlinked = Catalog.Snapshot().recipesById[fingerprint]
equal(unlinked.completeness, "complete", "refresh upgrades a saved unlinked recipe in place")
equal(unlinked.legacySpellID, nil, "the observed shape does not invent a spell identity")
equal(Catalog.ResolveLive(unlinked), 1, "the native row can be selected by its exact name and shape")
liveRows[2] = {output = 600, reagent = 200, count = 2}
equal(Catalog.ResolveLive(unlinked), nil, "matching raw output and reagents alone cannot choose between duplicates")

print("FluxCraft adapter/catalog fixtures passed")
