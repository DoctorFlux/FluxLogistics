local FC = {target = "forever", state = {characterKey = "actor", build = 16001, catalogStore = {}}}
local function loadModule(module)
    return assert(loadfile("FluxCraft/" .. module .. ".lua"))("FluxLogistics", FC)
end
loadModule("Locale")
loadModule("Catalog")
loadModule("Clients")

local openProfession, ready, foreign = 171, true, false
local recipeID, outputID, cooldown, requirementsMet = 9221, 621, nil, true
local recipeInfo = {recipeID = recipeID, learned = true, canCreateMultiple = true, craftable = true}
local schematic = {recipeType = 1, quantityMin = 2, quantityMax = 3, outputItemID = outputID,
    reagentSlotSchematics = {
        {reagentType = 1, quantityRequired = 1, slotIndex = 1, dataSlotIndex = 11, dataSlotType = 1,
            reagents = {{itemID = 410}}},
        {reagentType = 1, quantityRequired = 2, slotIndex = 2, dataSlotIndex = 12, dataSlotType = 2,
            reagents = {{itemID = 420}, {itemID = 430}}},
        {reagentType = 2, quantityRequired = 1, slotIndex = 3, dataSlotIndex = 13, dataSlotType = 2,
            reagents = {{itemID = 440}}},
    },
}
_G.Enum = {
    TradeskillRecipeType = {Item = 1},
    CraftingReagentType = {Basic = 1, Optional = 2},
    TradeskillSlotDataType = {Reagent = 1, ModifiedReagent = 2},
}
_G.C_TradeSkillUI = {
    GetChildProfessionInfo = function() return {professionID = 1001, parentProfessionID = openProfession, sourceCounter = 5} end,
    IsTradeSkillReady = function() return ready end,
    IsNPCCrafting = function() return foreign end,
    GetRecipeInfo = function(id) if id == recipeID then return recipeInfo end end,
    GetRecipeSchematic = function(id) if id == recipeID then return schematic end end,
    GetProfessionInfoByRecipeID = function() return {professionID = 171} end,
    GetRecipeCooldown = function() return cooldown, cooldown ~= nil, cooldown and 0, cooldown and 1 end,
    GetRecipeRequirements = function() return {{name = "Test station", met = requirementsMet}} end,
}
_G.GetServerTime = function() return 300 end

local selected, spinner, clicks, submitted, freeSlots, nativeCap = nil, 0, 0, nil, 2, 30
local nativePress = false
local allocations = {}
local transaction = {
    OverwriteAllocation = function(_, slot, reagent, quantity)
        allocations[slot] = {dataSlotIndex = schematic.reagentSlotSchematics[slot].dataSlotIndex,
            reagent = reagent, quantity = quantity}
    end,
    HasAnyAllocations = function(_, slot) return allocations[slot] ~= nil end,
    CreateReagentInfoTbl = function() return {allocations[1]} end,
    CreateCraftingReagentInfoTbl = function() return {allocations[2], allocations[3]} end,
}
local shown = function() return true end
local page = {
    IsShown = shown,
    SchematicForm = {
        GetRecipeInfo = function() return selected end,
        GetTransaction = function() return transaction end,
    },
    SelectRecipe = function(_, info) selected = info end,
    SetOverrideCastBarActive = function() end,
    CreateInternal = function(self)
        assert(nativePress, "the adapter activated Blizzard Create")
        self:SetOverrideCastBarActive(true)
        clicks = clicks + 1
    end,
    CreateButton = {
        IsShown = shown,
        IsEnabled = shown,
        Click = function() error("the adapter must not synthesize a Forever button click") end,
    },
    GetCraftableCount = function() return nativeCap end,
    CreateMultipleInputBox = {
        IsEnabled = shown,
        SetValue = function(_, number) spinner = number end,
        GetValue = function() return spinner end,
    },
}
_G.hooksecurefunc = function(object, method, callback)
    local original = assert(object[method])
    object[method] = function(...)
        original(...)
        callback(...)
    end
end
local function createNatively(id, count)
    nativePress = true
    page:CreateInternal(id, count, 1)
    nativePress = false
end
local switchedTo = nil
_G.ProfessionsFrame = {IsShown = shown, CraftingPage = page, rightProfessionTabs = {
    {IsShown = shown, skillLine = 197, OnClick = function() switchedTo = 197 end},
}}
local locations = {}
_G.Flux = {
    Inventory = {
        Containers = {
            GetCarriedBagIDs = function() return {0, 1, 2, 5, -1} end,
            IsReagentBag = function(bag) return bag == 5 end,
            IsKeyringBag = function(bag) return bag == -1 end,
        },
        Find = function(_, options)
            assert(options.bags and not options.bank)
            return locations
        end,
    },
    Container = {
        GetNumFreeSlots = function(bag)
            if bag == 0 then return freeSlots, nil end
            if bag == 1 then return 12, 32 end
            if bag == 2 then return 12, nil end
            return 6, 0 -- fixture uses explicit owner identity for these special bags
        end,
    },
}
_G.FluxInv = {
    GetTotalFreeBagSlots = function()
        return freeSlots + 36 -- installed legacy helper does not qualify output bags
    end,
}
_G.C_Item = {GetItemMaxStackSizeByID = function() return 5 end}

local clients = FC.Clients
assert(clients.CurrentProfessionID() == 171, "uses the child's parent profession")
ready = false
assert(clients.CurrentProfessionID() == nil, "unready native source has no qualified profession")
ready, foreign = true, true
assert(clients.CurrentProfessionID() == nil, "NPC data source excluded")
foreign = false
do
    local frame = ProfessionsFrame
    local tab = frame.rightProfessionTabs[1]
    assert(not clients.SwitchProfession(197) and switchedTo == 197,
        "a visible tab that merely opens Recipes is not an acknowledged skill switch")
    local originalClick = tab.OnClick
    local nativeChanging = false
    C_TradeSkillUI.IsDataSourceChanging = function() return nativeChanging end
    tab.OnClick = function() nativeChanging = true end
    assert(clients.SwitchProfession(197) and not clients.CurrentProfessionID(),
        "the exact tab fallback can report a witnessed asynchronous transition")
    nativeChanging = false
    tab.OnClick = function() openProfession = 197 end
    assert(clients.SwitchProfession(197) and clients.CurrentProfessionID() == 197,
        "the exact tab fallback can verify a synchronous open")
    openProfession = 171

    local attempts, opened = 0, true
    local tabAttempts = 0
    tab.OnClick = function() tabAttempts = tabAttempts + 1; error("native tab unavailable") end
    C_TradeSkillUI.GetBaseProfessionInfo = function() return {professionID = openProfession} end
    C_TradeSkillUI.OpenTradeSkill = function(skillLineID)
        attempts = attempts + 1
        assert(skillLineID == 197, "open receives the exact saved base skill line")
        return opened
    end
    assert(clients.SwitchProfession(197) and attempts == 1 and tabAttempts == 0,
        "a different visible skill uses the acknowledged native opener, not the tab")
    opened = false
    assert(not clients.SwitchProfession(197) and attempts == 2 and tabAttempts == 0,
        "the refused cross-switch cannot fall through to a second action")
    opened = true

    local pageShown = false
    openProfession = 197
    page.IsShown = function() return pageShown end
    tab.OnClick = function() tabAttempts = tabAttempts + 1; pageShown = true end
    assert(clients.SwitchProfession(197) and pageShown and tabAttempts == 1 and attempts == 2,
        "the retained Book skill uses its exact tab to reveal Recipes without recasting")
    pageShown = false
    tab.OnClick = function() tabAttempts = tabAttempts + 1; error("native tab unavailable") end
    local bootstrap = OpenProfessionUIToSkillLine
    OpenProfessionUIToSkillLine = function(id) assert(id == openProfession); pageShown = true end
    assert(clients.SwitchProfession(197) and pageShown and tabAttempts == 2 and attempts == 2,
        "the retained Book skill uses the native reveal if its tab errors")
    OpenProfessionUIToSkillLine = bootstrap
    tab.OnClick = originalClick
    page.IsShown, openProfession = shown, 171

    frame.IsShown = function() return false end
    assert(clients.SwitchProfession(197) and attempts == 3 and clicks == 0, "one press opens a hidden native profession")
    ProfessionsFrame = nil
    assert(clients.SwitchProfession(197) and attempts == 4 and clicks == 0, "cold profession window opens by skill line")
    opened = false
    assert(not clients.SwitchProfession(197) and attempts == 5, "a refused open is not reported as a pending switch")
    opened = nil
    assert(not clients.SwitchProfession(197) and attempts == 6, "the native acknowledgement is required")
    InCombatLockdown = function() return true end
    assert(not clients.SwitchProfession(197) and attempts == 6, "combat blocks opening")
    InCombatLockdown = nil
    assert(not clients.SwitchProfession(0) and attempts == 6, "invalid skill lines do not reach the opener")
    local auction = FluxAuctionRestock
    local sharedCalls, sharedOpened = 0, true
    FluxAuctionRestock = {Followup = {OpenProfession = function(skillLineID)
        assert(skillLineID == 197)
        sharedCalls = sharedCalls + 1
        return sharedOpened
    end}}
    assert(clients.SwitchProfession(197) and sharedCalls == 1 and attempts == 6, "the shared owner handles cold opens")
    sharedOpened = false
    assert(not clients.SwitchProfession(197) and sharedCalls == 2 and attempts == 6,
        "a refusal from the shared owner never starts a second open route")
    FluxAuctionRestock = auction
    C_TradeSkillUI.OpenTradeSkill, C_TradeSkillUI.GetBaseProfessionInfo, C_TradeSkillUI.IsDataSourceChanging = nil, nil, nil
    ProfessionsFrame = frame
    frame.IsShown = shown
end

local exactRecipe = {id = recipeID, recipeID = recipeID, learned = true, completeness = "complete",
    outputKind = "item", yield = 2, yieldMax = 3, professionId = 171}
do
    local api = C_TradeSkillUI
    local base, byID = api.GetBaseProfessionInfo, api.GetProfessionInfoByRecipeID
    local native = Professions
    api.GetBaseProfessionInfo = function() return {professionID = 171, skillLevel = 261, maxSkillLevel = 300} end
    api.GetProfessionInfoByRecipeID = function() return {professionID = 171, skillLevel = 0, maxSkillLevel = 0} end
    local rank, maximum = clients.GetRecipeSkillProgress(exactRecipe)
    assert(rank == 261 and maximum == 300, "missing recipe ranks use the exact open profession progress")
    Professions = {GetProfessionInfo = function()
        return {professionID = 2948, parentProfessionID = 197, skillLevel = 237, maxSkillLevel = 300}
    end}
    assert(clients.GetRecipeSkillProgress(exactRecipe) == 261,
        "the native rank bar cannot lend its rank to a different profession")
    exactRecipe.professionId = 197
    api.GetProfessionInfoByRecipeID = function() return {professionID = 197, skillLevel = 300, maxSkillLevel = 300} end
    rank, maximum = clients.GetRecipeSkillProgress(exactRecipe)
    assert(rank == 237 and maximum == 300, "the difficulty strip shares the native Tailoring bar's skill scale")
    Professions = native
    api.GetProfessionInfoByRecipeID = function() return {professionID = 171, skillLevel = 0, maxSkillLevel = 0} end
    assert(not clients.GetRecipeSkillProgress(exactRecipe), "another profession must not supply the visible rank")
    exactRecipe.professionId = 171
    api.GetBaseProfessionInfo, api.GetProfessionInfoByRecipeID = base, byID
end
local liveFacts = assert(FC.Catalog.ReadModernRecipe(recipeID, openProfession))
assert(not liveFacts.blocker and #liveFacts.choices == 2, "only supported required choices are enumerated")
assert(liveFacts.minYield == 2 and liveFacts.maxYield == 3, "guaranteed yield and possible maximum preserved")
local task = {recipeId = recipeID, professionId = openProfession, outputItemID = outputID,
    outputKind = "item", executions = 4, yield = 2, reagentChoice = liveFacts.choices[2],
    inputs = {{itemID = 410, quantity = 4}, {itemID = 430, quantity = 8}}}
local function record(count) submitted = count; return true end

requirementsMet = false
local required, station = clients.Resolve(task, exactRecipe)
assert(required == nil and station == FC.L.clients.requires:format("Test station"),
    "required station blocks live execution with the named warning")
assert(FC.Catalog.ReadLiveRequirements(exactRecipe)[1].met == false)
requirementsMet, cooldown = true, 60
assert(FC.Catalog.ReadLiveRequirements(exactRecipe)[1].met == true, "the warning reads the current native requirement")
assert(clients.Resolve(task, exactRecipe) == nil, "cooldown blocks live execution")
cooldown = nil
task.inputs[2].quantity = 4
assert(clients.Resolve(task, exactRecipe) == nil, "stale recipe quantities cannot craft")
task.inputs[2].quantity = 8

local live = assert(clients.Resolve(task, exactRecipe))
freeSlots = 0
local wantedLink = "|Hitem:621:1|h[Bolt]|h"
live.outputLink = wantedLink
locations = {
    {region = "bags", link = "|Hitem:621:2|h[Different Bolt]|h", count = 1},
    {region = "bank", link = wantedLink, count = 1},
}
local started, reason = clients.Craft(task, live, 4, record)
assert(not started and reason == FC.L.clients.noCapacity and clicks == 0 and submitted == nil,
    "specialty bags, reagent bags, keyring, bank and a different variant cannot supply output space")
locations = {}
freeSlots = 2
allocations[3] = {dataSlotIndex = 13, reagent = {itemID = 440}, quantity = 1}
local dispatch, permitted, mismatch
local function observe(count, blocker) submitted, mismatch = count, blocker; return count ~= nil end
started, reason, dispatch, permitted = clients.Craft(task, live, 4, observe)
assert(started and not reason and dispatch == "native_click" and permitted == 3 and clicks == 0
    and not selected and spinner == 0 and not submitted and not allocations[1] and not allocations[2],
    "preparation reports the bag-limited batch without changing the native form or invoking Create")
selected = recipeInfo
C_TradeSkillUI.GetRemainingRecasts = function() return 2 end
local recasts, nativeTransaction = clients.ReadNativeCraftRecasts(recipeID)
assert(recasts == 2 and nativeTransaction == transaction and not clients.ReadNativeCraftRecasts(recipeID + 1),
    "read the client repeat count only on the same native recipe transaction")
transaction:OverwriteAllocation(1, {itemID = 410}, 1)
transaction:OverwriteAllocation(2, {itemID = 430}, 2)
assert(not clients.PrepareNativeCraftBatch(recipeID, 3) and spinner == 0,
    "preparation preserves the user's input when the reagent allocations disagree")
createNatively(recipeID, 3)
assert(clicks == 1 and not submitted and mismatch == FC.L.clients.staleReagents and allocations[3],
    "the observer ignores a native craft with an unexpected optional reagent")
allocations[3] = nil
assert(clients.Craft(task, live, 4, observe))
createNatively(recipeID, 4)
assert(clicks == 2 and not submitted and mismatch == FC.L.clients.changedAmount,
    "only a batch within the queue's material and output limit can be correlated")
assert(clients.Craft(task, live, 4, observe))
createNatively(recipeID + 1, 3)
assert(clicks == 3 and not submitted and mismatch == FC.L.clients.sessionChanged,
    "an unrelated native Create cannot use the armed recipe")
local entries = 0
assert(clients.Craft(task, live, 4, observe, function()
    assert(nativePress and clicks == 3, "native entry is observable before submission")
    entries = entries + 1
end))
page:SetOverrideCastBarActive(false)
assert(entries == 0, "the native cast-bar reset cannot open a craft observation")
spinner = 1
assert(clients.PrepareNativeCraftBatch(recipeID, 3) == 3 and spinner == 3 and clicks == 3,
    "the default single craft is replaced with the verified native batch")
spinner, nativeCap = 30, 2
assert(clients.PrepareNativeCraftBatch(recipeID, 3) == 2 and spinner == 2 and clicks == 3,
    "the live native count caps a previously larger input without starting a craft")
spinner, nativeCap = 0, 30
createNatively(recipeID, 3)
assert(clicks == 4 and submitted == 3 and not mismatch and spinner == 0 and entries == 1,
    "the exact native recipe, selected inputs and limited amount are observed after the player click")

freeSlots = 0
locations = {{region = "bags", link = wantedLink, count = 2}}
submitted = nil
started, reason, dispatch, permitted = clients.Craft(task, live, 4, observe)
assert(started and permitted == 1 and clicks == 4 and not submitted,
    "a matching carried stack supplies only its remaining capacity")
clients.CancelNativeCraft()
createNatively(recipeID, 1)
assert(clicks == 5 and not submitted, "cancelling the handoff leaves the native Create independent")
freeSlots, locations = 2, {}

do
    local first, second = schematic.reagentSlotSchematics[1], schematic.reagentSlotSchematics[2]
    local firstDataIndex, secondDataIndex, secondDataType = first.dataSlotIndex, second.dataSlotIndex, second.dataSlotType
    first.dataSlotIndex, second.dataSlotIndex, second.dataSlotType = 0, 0, Enum.TradeskillSlotDataType.Reagent
    transaction:OverwriteAllocation(1, {itemID = 410}, 1)
    transaction:OverwriteAllocation(2, {itemID = 430}, 2)
    local function allocation(itemID, quantity)
        return {GetReagent = function() return {itemID = itemID} end, GetQuantity = function() return quantity end}
    end
    local liveSlots = {{allocation(410, 1)}, {allocation(430, 2)}, {}}
    transaction.EnumerateAllocations = function(_, slot)
        return ipairs(assert(liveSlots[slot]))
    end
    local craftInfo, reagentInfo = transaction.CreateCraftingReagentInfoTbl, transaction.CreateReagentInfoTbl
    transaction.CreateCraftingReagentInfoTbl = function() return {} end
    transaction.CreateReagentInfoTbl = function() return {allocations[1], allocations[2]} end
    assert(clients.Craft(task, live, 4, observe))
    assert(clients.PrepareNativeCraftBatch(recipeID, 3) == 3 and spinner == 3 and clicks == 5,
        "ordinary native reagent slots with the same serialized index still prefill their exact batch")
    liveSlots[1], liveSlots[2] = liveSlots[2], liveSlots[1]
    assert(not clients.PrepareNativeCraftBatch(recipeID, 3),
        "the accepted reagent totals cannot substitute for the exact assignment by native slot")
    liveSlots[1], liveSlots[2] = liveSlots[2], {allocation(430, 1)}
    assert(not clients.PrepareNativeCraftBatch(recipeID, 3), "a short native allocation cannot authorize the batch")
    liveSlots[2], liveSlots[3] = {allocation(430, 1), allocation(420, 1)}, {}
    assert(not clients.PrepareNativeCraftBatch(recipeID, 3), "a second reagent variant cannot fill the same accepted slot")
    liveSlots[2], liveSlots[3] = {allocation(430, 2)}, {allocation(440, 1)}
    assert(not clients.PrepareNativeCraftBatch(recipeID, 3), "an extra optional allocation blocks the native handoff")
    liveSlots[3] = {}
    for _, method in ipairs({"IsRecraft", "IsApplyingConcentration", "GetEnchantAllocation"}) do
        transaction[method] = function() return true end
        assert(not clients.PrepareNativeCraftBatch(recipeID, 3), "unsupported native modes remain blocked")
        transaction[method] = nil
    end
    clients.CancelNativeCraft()
    transaction.EnumerateAllocations = nil
    transaction.CreateCraftingReagentInfoTbl, transaction.CreateReagentInfoTbl = craftInfo, reagentInfo
    first.dataSlotIndex, second.dataSlotIndex, second.dataSlotType = firstDataIndex, secondDataIndex, secondDataType
end

do
    local slots = schematic.reagentSlotSchematics
    local api = C_TradeSkillUI
    local attempts, requested, available, response = 0, nil, 2, nil
    local function accept(batch)
        requested = batch
        return true
    end
    api.GetCraftableCount = function(id)
        assert(id == recipeID)
        return available
    end
    api.CraftRecipe = function(id, count, reagents, level, orderID, concentration)
        assert(nativePress and requested == count and id == recipeID)
        assert(type(reagents) == "table" and not next(reagents) and level == 0
            and orderID == nil and concentration == false)
        attempts = attempts + 1
        return response
    end
    assert(not clients.CanDispatchQueuedCraft(live), "modified or optional reagent slots keep their native handoff")
    schematic.reagentSlotSchematics = {slots[1]}
    local directTask = {
        recipeId = recipeID, professionId = openProfession, outputItemID = outputID,
        outputKind = "item", executions = 4, yield = 2, inputs = {{itemID = 410, quantity = 4}},
    }
    local direct = assert(clients.Resolve(directTask, exactRecipe))
    assert(clients.CanDispatchQueuedCraft(direct), "one exact ordinary basic slot qualifies for a direct Process press")
    local function press(callback)
        nativePress = true
        local ok, blocker, phase = clients.DispatchQueuedCraft(directTask, direct, 4, callback or accept)
        nativePress = false
        return ok, blocker, phase
    end

    local ok, blocker, phase = press()
    assert(ok and not blocker and phase == 2 and attempts == 1 and clicks == 5,
        "the native available count caps one direct call after the queue records the exact amount")
    ok, blocker, phase = press(function() return false end)
    assert(not ok and blocker == FC.L.clients.queueIntent and phase == "not_submitted" and attempts == 1)
    ok, blocker, phase = press(function(count)
        available = count - 1
        return accept(count)
    end)
    assert(not ok and blocker == FC.L.clients.nothingAvailable and phase == "not_submitted" and attempts == 1)
    available = 4
    ok, blocker, phase = press(function(count)
        openProfession = 197
        return accept(count)
    end)
    assert(not ok and blocker == FC.L.clients.sessionChanged and phase == "not_submitted" and attempts == 1)
    openProfession = 171
    response = false
    ok, blocker, phase = press()
    assert(not ok and blocker == FC.L.clients.noSubmission and phase == "attempted" and requested == 3
        and attempts == 2 and clicks == 5, "a native refusal makes one attempt without a follow-up Create press")
    recipeInfo.nextRecipeID = recipeID + 1
    assert(not clients.CanDispatchQueuedCraft(direct), "direct Process never guesses a recipe rank")
    recipeInfo.nextRecipeID = nil
    FC.target = "classic"
    assert(not clients.CanDispatchQueuedCraft(direct), "Classic retains its existing process adapter")
    FC.target = "forever"
    api.GetCraftableCount, api.CraftRecipe = nil, nil
    schematic.reagentSlotSchematics = slots
end

schematic.reagentSlotSchematics, allocations = {}, {}
assert(FC.Catalog.ReadModernRecipe(recipeID, openProfession).blocker,
    "an empty schematic without client confirmation is still loading")
C_TradeSkillUI.HasNoReagentCost = function(id) return id == recipeID end
local freeTask = {recipeId = recipeID, professionId = openProfession, outputItemID = outputID,
    outputKind = "item", executions = 3, yield = 2, inputs = {}}
local freeCraft = assert(clients.Resolve(freeTask, exactRecipe))

spinner = 0
page.CreateMultipleInputBox.SetValue = function() error("single Create rewrote the hidden quantity") end
started, reason, dispatch, permitted = clients.Craft(freeTask, freeCraft, 3, record)
assert(started and not reason and dispatch == "native_click" and permitted == 1 and clicks == 5,
    "the no-cost recipe prepares one exact execution without clicking native Create")
assert(clients.PrepareNativeCraftBatch(recipeID, permitted) == 1 and spinner == 0)
createNatively(recipeID, 0)
assert(submitted == 1 and clicks == 6 and spinner == 0,
    "a client-confirmed no-cost recipe uses native single Create even though its batch count is zero")

-- An accepted exact rank may be superseded after the recipe was resolved.
local higherID = recipeID + 1
local higher = {recipeID = higherID, previousRecipeID = recipeID, learned = true}
recipeInfo.nextRecipeID = higherID
Professions = {
    GetHighestLearnedRecipe = function(info) return info == recipeInfo and higher or info end,
    GetRecipeRank = function(info) return info == higher and 2 or 1 end,
}
local selectionAttempts = 0
page.SelectRecipe = function(_, info)
    selectionAttempts = selectionAttempts + 1
    selected = Professions.GetHighestLearnedRecipe(info) or info
end
local unavailable, unavailableReason = clients.Resolve(freeTask, exactRecipe)
assert(not unavailable and unavailableReason == FC.L.clients.supersededRank,
    "an exact accepted lower rank cannot resolve to the higher recipe")
submitted, selected = nil, nil
started, reason = clients.Craft(freeTask, freeCraft, 1, record)
assert(not started and reason == FC.L.clients.supersededRank and selectionAttempts == 0
    and not selected and not submitted and clicks == 6,
    "newly learned rank blocks a stale prepared craft before native selection or intent")

FC.target = "era"
local bookName, bookSlot = "Schneiderei", 7
local legacyProfessionID = 3904
_G.C_TradeSkillUI = nil
_G.GetNumSpellTabs = function() return 1 end
_G.GetSpellTabInfo = function() return "Allgemein", nil, bookSlot - 1, 1 end
_G.GetSpellBookItemName = function(slot) assert(slot == bookSlot); return bookName end
_G.GetSpellBookItemInfo = function(slot) assert(slot == bookSlot); return "SPELL", legacyProfessionID end
_G.GetTradeSkillLine = function() return bookName, 115, 150 end
local castSlot
_G.CastSpell = function(slot) castSlot = slot end
local native, chosen = 0, 2
_G.TradeSkillFrame = {IsShown = shown}
_G.TradeSkillCreateButton = {
    IsEnabled = shown,
    Click = function()
        assert(TradeSkillFrame.selectedSkill == chosen and submitted == native)
        clicks = clicks + 1
    end,
}
_G.TradeSkillInputBox = {
    SetNumber = function(_, n) native = n end,
    GetNumber = function() return native end,
}
_G.TradeSkillFrame_SetSelection = function(row) TradeSkillFrame.selectedSkill = row end
_G.GetTradeSkillSelectionIndex = function() return TradeSkillFrame.selectedSkill end
_G.GetTradeSkillInfo = function(i) if i == chosen then return "Synthetic Bolt", "optimal", 2 end end
_G.GetNumTradeSkills = function() return 2 end
_G.GetTradeSkillItemLink = function() return "|Hitem:621|h[Bolt]|h" end
_G.GetTradeSkillNumMade = function() return 2, 2 end
_G.GetTradeSkillNumReagents = function() return 1 end
_G.GetTradeSkillReagentInfo = function() return "Synthetic Cloth", nil, 2 end
_G.GetTradeSkillReagentItemLink = function() return "|Hitem:410|h[Cloth]|h" end
_G.GetTradeSkillRecipeLink = function() return "|Henchant:8101|h[Synthetic Bolt]|h" end
assert(clients.CurrentProfessionID() == legacyProfessionID, "classic uses a stable spell in the observed profession")
bookSlot = bookSlot + 2
assert(clients.SwitchProfession(legacyProfessionID) and castSlot == bookSlot, "switch re-resolves moved spell book slots")
local legacy = {id = "legacy:spell:8101", professionName = bookName, professionId = legacyProfessionID,
    outputKind = "item", yield = 2, yieldMax = 2, completeness = "complete", learned = true,
    legacy = true, legacySpellID = 8101, legacyFingerprint = "621:2:2:410x2",
    reagents = {{itemID = 410, quantity = 2}}}
local legacyTask = {recipeId = legacy.id, professionId = legacyProfessionID, outputItemID = 621,
    outputKind = "item", executions = 4, yield = 2, inputs = {{itemID = 410, quantity = 8}}}
local legacyLive = assert(clients.Resolve(legacyTask, legacy))
assert(legacyLive.index == 2, "classic maps exact identity to latest visible row")
local nearLoom = false
GetTradeSkillTools = function(index)
    assert(index == chosen, "station checks must follow the observed recipe row")
    return "Spinning Wheel", nearLoom
end
local tools, knownIndex = FC.Catalog.ReadLiveRequirements(legacy)
assert(knownIndex == 2 and tools[1].met == false and tools[1].name == "Spinning Wheel")
chosen = 1
nearLoom = true
tools, knownIndex = FC.Catalog.ReadLiveRequirements(legacy, knownIndex)
assert(knownIndex == 1 and tools[1].met == true)
GetTradeSkillTools = nil
assert(not clients.Craft(legacyTask, legacyLive, 4, record) and clicks == 6,
    "classic row changed between resolving and clicking")
legacyLive = assert(clients.Resolve(legacyTask, legacy))
started, reason, dispatch = clients.Craft(legacyTask, legacyLive, 4, function(count)
    record(count)
    TradeSkillFrame.selectedSkill = 2
    return true
end)
assert(not started and reason == FC.L.clients.classicSelection and dispatch == "not_submitted" and clicks == 6,
    "a different Classic selection after recording intent must abort before Create")
assert(clients.Craft(legacyTask, legacyLive, 4, record) and native == 2 and clicks == 7,
    "classic issues native exact recipe and caps at reported availability")
legacy.name, legacy.legacySpellID, GetTradeSkillRecipeLink = "Synthetic Bolt", nil, nil
legacyLive = assert(clients.Resolve(legacyTask, legacy))
assert(clients.Craft(legacyTask, legacyLive, 4, record) and native == 2 and clicks == 8,
    "an unlinked but uniquely verified recipe can issue the same native craft")
local expansions = 0
chosen = nil
ExpandTradeSkillSubClass = function(index)
    assert(index == 0)
    expansions, chosen = expansions + 1, 2
end
assert(not clients.Resolve(legacyTask, legacy) and expansions == 0, "passive recipe resolution leaves native groups alone")
assert(clients.Resolve(legacyTask, legacy, true).index == 2 and expansions == 1,
    "an explicit craft can expand the native groups and resolve the exact row")

do
    local names = {[3908] = "Schneiderei", [3909] = "Schneiderei", [2018] = "Schmiedekunst",
        [2259] = "Alchemie", [7411] = "Verzauberkunst", [2550] = "Kochkunst", [3273] = "Erste Hilfe",
        [2656] = "Verhüttung", [2575] = "Bergbau", [7620] = "Angeln",
        [9901] = "Mehrdeutig", [9902] = "Mehrdeutig"}
    local slots = {3909, 3908, 2259, 7411, 2550, 3273, 2656, 2575, 7620, 2018, 9901, 9902}
    local current = "UNKNOWN"
    GetTradeSkillLine = function() return current, 115, 150 end
    GetSpellTabInfo = function() return "Allgemein", nil, 0, #slots end
    GetSpellBookItemName = function(slot) return names[slots[slot]] end
    GetSpellBookItemTexture = function(slot) return slots[slot] + 1000 end
    GetSpellBookItemInfo = function(slot)
        local id = slots[slot]
        return id == 2018 and "FUTURESPELL" or "SPELL", id
    end
    C_SpellBook = {FindBaseSpellByID = function(id) return id == 3909 and 3908 or id end}
    C_Spell = {GetSpellName = function(id) return names[id] end}
    local function byID()
        local byID = {}
        for _, profession in ipairs(clients.ListProfessions()) do byID[profession.id] = profession end
        return byID
    end
    local known = byID()
    assert(known[2259] and known[7411] and known[2550] and known[3273] and known[2656]
        and not known[2018] and not known[2575] and not known[7620],
        "the closed localized spellbook yields all learned crafting openers and excludes gathering and future spells")
    assert(known[3908].spellSlot == 2 and not known[3909] and known[2550].texture == 3550,
        "the canonical learned cast wins over equal localized rank names")
    current = names[2575]
    assert(clients.CurrentProfessionID() == 2656 and clients.SwitchProfession(2656) and castSlot == 7,
        "the Mining line is an alias for the learned Smelting action")

    GetProfessions = function() return 1, 2 end
    GetProfessionInfo = function(index)
        if index == 1 then return names[2575], nil, 100, 150, 1, 7, 186 end
        return names[9901], nil, 100, 150, 1, 10, 9900
    end
    known = byID()
    assert(known[186].spellSlot == 7 and known[186].spellID == 2656 and not known[2656] and known[7411],
        "the native profession line ID stays stable while supplementing a partially reported roster")
    assert(clients.CurrentProfessionID() == 186 and clients.SwitchProfession(186) and castSlot == 7)
    assert(known[9900].opensTradeSkill == false and not clients.SwitchProfession(9900) and castSlot == 7,
        "an ambiguous native named action never silently falls back to its first offset")

    current = names[2656]
    local recipe = {legacy = true, legacyFingerprint = legacy.legacyFingerprint, name = legacy.name,
        professionId = 186, professionName = names[2575]}
    assert(clients.CurrentProfessionID() == 186 and FC.Catalog.MatchLegacyLive(recipe, chosen),
        "a saved Mining name still matches Smelting after verifying the native skill ID and exact row")
    slots[7] = 6000
    assert(not clients.SwitchProfession(186) and castSlot == 7,
        "the native Mining offset cannot dispatch a gathering spell without Smelting learned")
end
print("client action and availability tests passed")
