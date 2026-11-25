-- Load the real addon manifest in order. The desktop fixture supplies only the
-- widget and owner surfaces needed by the addon. No test addon code is in the TOC.
local folder = arg[1] or "."
local packageTarget = arg[2]
local expected = {
    forever = {version = "1.60.1", build = "71037", interface = 16001},
    classic = {version = "5.5.4", build = "70631", interface = 50504},
    anniversary = {version = "2.5.6", build = "70577", interface = 20506},
    era = {version = "1.15.9", build = "70576", interface = 11509},
}
assert(not packageTarget or packageTarget == "retail" or expected[packageTarget], "unknown package target")

local function readManifest(name)
    local files, interfaces, requiresFluxUI = {}, {}, false
    for line in io.lines(folder .. "/" .. name) do
        local list = line:match("^## Interface:%s*(.+)$")
        if list then
            for number in list:gmatch("%d+") do interfaces[tonumber(number)] = true end
        end
        if line:match("^## Dependencies:%s*_FluxUI%s*$") then requiresFluxUI = true end
        local path = line:match("^%s*([^#%s].-)%s*$")
        if path then
            files[#files + 1] = path:gsub("\\", "/")
            assert(not path:match("Tests"), "test source is declared in the runtime TOC")
        end
    end
    return files, interfaces, requiresFluxUI
end

local function checkRetailManifest(name)
    local files, interfaces, requiresFluxUI = readManifest(name)
    assert(interfaces[120105], "Retail TOC is missing the current Retail interface")
    interfaces[120105] = nil
    assert(not next(interfaces), "Retail TOC advertises another client")
    assert(not requiresFluxUI, "Retail auction messages require no companion addon")
    assert(#files == 2 and files[1] == "FluxCraft/Locale.lua" and files[2] == "FluxCraft/AuctionSales.lua",
        "Retail must load only the localized auction sale feature")
    for _, path in ipairs(files) do assert(loadfile(folder .. "/" .. path)) end
end

if packageTarget == "retail" then
    checkRetailManifest("FluxLogistics.toc")
    print("Retail auction sale package TOC passed")
    return
end
if not packageTarget then checkRetailManifest("FluxLogistics_Standard.toc") end

local files, interfaces, requiresFluxUI = readManifest("FluxLogistics.toc")
assert(requiresFluxUI, "FluxUI must remain a mandatory TOC dependency")
assert(files[1] == "FluxCraft/Target.lua", "check the client before registering runtime services")
assert(files[2] == "FluxCraft/Locale.lua" and files[3] == "FluxCraft/AuctionSales.lua",
    "auction sale messages must load after their locale catalog")
assert(not interfaces[120105] and next(interfaces), "Retail is advertised in the planner TOC")
for name, target in pairs(expected) do
    if not packageTarget or packageTarget == name then
        assert(interfaces[target.interface], "TOC is missing the current " .. name .. " interface")
    else
        assert(not interfaces[target.interface], "a per-client package advertises another client")
    end
end

local permittedTemplates = {UIPanelButtonTemplate = true, UIPanelCloseButton = true,
    UICheckButtonTemplate = true, InputBoxTemplate = true, BackdropTemplate = true}

local function run(client, info, enabled)
    dofile("Tests/ui_fixture.lua")
    local baseFrame = CreateFrame
    local frames, allowed = {}, enabled
    local subscriptions, plannerRegistrations, clientCallbacks = 0, 0, {}
    local gamepad = false
    local timers = {}
    C_Timer.After = function(_, callback) timers[#timers + 1] = callback end
    local function settleEvents()
        for _ = 1, 100 do
            if #timers == 0 then return end
            table.remove(timers, 1)()
        end
        error("profession update did not settle")
    end
    GetBuildInfo = function() return info.version, info.build, "Nov 21 2026", info.interface end
    IsLoggedIn = function() return true end
    UnitGUID = function() return "Player-0-C0D3" end
    BackdropTemplateMixin = {}
    geterrorhandler = function()
        return function(errorText) error(errorText, 0) end
    end
    CreateFrame = function(kind, name, parent, template)
        assert(allowed, "unsupported client created a frame")
        assert(not template or permittedTemplates[template], "unknown fixture template " .. tostring(template))
        local widget = baseFrame(kind, name, parent, template)
        if template == "BackdropTemplate" then
            widget.SetBackdrop = function(self, backdrop) self.backdrop = backdrop end
        end
        local register = widget.RegisterEvent
        widget.subscribed = {}
        widget.RegisterEvent = function(self, event)
            self.subscribed[event] = true
            register(self, event)
        end
        frames[#frames + 1] = widget
        return widget
    end
    local function dispatch(event, ...)
        for _, frame in ipairs(frames) do
            if frame.subscribed[event] then frame:Fire("OnEvent", event, ...) end
        end
    end
    local function unexpectedSettings() error("FluxLogistics must not expose a Settings page") end
    Settings = {RegisterCanvasLayoutCategory = unexpectedSettings, RegisterAddOnCategory = unexpectedSettings,
        OpenToCategory = unexpectedSettings}
    EventRegistry = {
        RegisterCallback = function(_, event, callback, owner)
            assert(allowed and type(callback) == "function" and type(owner) == "table")
            clientCallbacks[event] = (clientCallbacks[event] or 0) + 1
        end,
    }
    Flux = {
        Inventory = {
            GetCount = function() return 0 end,
            GetSource = function() return "builtin" end,
            IsReady = function() return true end,
            IsReliable = function() return true end,
            GetUniqueItems = function() return {} end,
            Register = function()
                assert(allowed)
                subscriptions = subscriptions + 1
            end,
            Professions = {ListCachedRecipes = function() return {} end},
        },
        RestockPolicy = {
            version = 1,
            RegisterPlanner = function(provider)
                assert(allowed and type(provider.GetCraftMaterialIDs) == "function")
                assert(not next(provider.GetCraftMaterialIDs()), "an empty starting queue must not protect any items")
                plannerRegistrations = plannerRegistrations + 1
            end,
        },
    }
    InputUtil = client == "forever" and {IsGamepadUIEnabled = function() return gamepad end} or nil
    ProfessionsFrame, TradeSkillFrame, C_TradeSkillUI = nil, nil, nil
    FluxLogisticsDB, FluxLogisticsCharDB = nil, nil
    FluxCraftDB, FluxCraftCharDB = {legacyData = {bookmark = true}}, {bookmark = "retained"}
    if client ~= "forever" then FluxCraftCharDB.ui = {nativeMode = true} end
    SLASH_FLUXLOGISTICS1, SLASH_FLUXLOGISTICS2 = nil, nil
    local ns = {}
    for _, path in ipairs(files) do
        assert(loadfile(folder .. "/" .. path))("FluxLogistics", ns)
    end
    if not enabled then
        assert(ns.disabled and not ns.state.ready)
        assert(next(ns.listeners) == nil and #frames == 0)
        assert(not SlashCmdList.FLUXLOGISTICS and not FluxLogisticsDB and not FluxLogisticsCharDB)
        assert(subscriptions == 0 and plannerRegistrations == 0)
        assert(next(clientCallbacks) == nil)
        assert(FluxCraftDB.legacyData.bookmark and FluxCraftCharDB.bookmark == "retained")
        return
    end
    assert(ns.target == client and not ns.disabled and not ns.state.ready)
    dispatch("ADDON_LOADED", "UnrelatedAddon")
    assert(not ns.state.ready)
    dispatch("ADDON_LOADED", "FluxLogistics")
    assert(ns.state.ready and ns.state.build == info.interface and ns.state.characterKey == "Player-0-C0D3")
    assert(FluxLogisticsDB.legacyData.bookmark and FluxLogisticsDB.legacyData ~= FluxCraftDB.legacyData)
    assert(FluxLogisticsCharDB.bookmark == "retained")
    assert(type(SlashCmdList.FLUXLOGISTICS) == "function" and SLASH_FLUXLOGISTICS1 == "/fluxlogistics")
    assert(subscriptions == 1 and plannerRegistrations == 1 and not ns.Options)
    local lines = ns.Diagnostics.Lines()
    assert(lines[1]:find(tostring(info.build), 1, true) and lines[2]:find("builtin", 1, true)
        and lines[4]:find("FluxUI bridge 1", 1, true), "loaded diagnostics did not report actual providers and build")
    assert(lines[2]:find("inbox requires FluxUI update", 1, true))
    local inboxObserved = false
    Flux.Inventory.GetSnapshotGeneration = function() return 1 end
    Flux.Inventory.Mail = {GetCount = function() return 0 end, HasObservedInbox = function() return inboxObserved end}
    assert(ns.Diagnostics.Lines()[2]:find("inbox unverified", 1, true))
    inboxObserved = true
    assert(ns.Diagnostics.Lines()[2]:find("inbox verified", 1, true))
    local actualJobs = ns.Queue.GetJobs
    local lastAcquisition = {kind = "auction", status = "confirmed", index = 1, quantity = 3, startedAt = 1}
    ns.Queue.GetJobs = function()
        return {{id = 1, lastAcquisition = lastAcquisition,
            requirements = {{itemID = 123, quantity = 5, remaining = 4, auctionAwaiting = 2}}}}
    end
    local receipt = ns.Diagnostics.Lines()[5]
    assert(receipt:find("1 arrived of 5 needed", 1, true) and receipt:find("2 awaiting mail", 1, true)
        and not receipt:find("recorded by", 1, true), "older receipts must remain readable without claiming a source version")
    lastAcquisition.addonVersion, lastAcquisition.clientBuild = "older-version", "older-build"
    assert(ns.Diagnostics.Lines()[5]:find("recorded by older-version on build older-build", 1, true),
        "a past action keeps its source versions after the addon reloads")
    ns.Queue.GetJobs = actualJobs
    dispatch("PLAYER_LOGIN")
    assert(subscriptions == 1 and plannerRegistrations == 1, "duplicate login initialized services again")

    GetProfessions = function() return 1 end
    GetProfessionInfo = function() return "Fixturesmithing", nil, 50, 100, 1, 0, 5 end
    GetTradeSkillLine = function() return "Fixturesmithing", 50, 100 end
    if client == "forever" then
        C_TradeSkillUI = {
            GetBaseProfessionInfo = function() return {professionID = 5} end,
            IsTradeSkillReady = function() return true end,
        }
        ProfessionsFrame = CreateFrame("Frame", nil, UIParent)
        ProfessionsFrame.CraftingPage = CreateFrame("Frame", nil, ProfessionsFrame)
        ProfessionsFrame.CraftingPage:SetFrameLevel(100)
        ProfessionsFrame.CraftingPage.RecipeList = CreateFrame("Frame", nil, ProfessionsFrame.CraftingPage)
        ProfessionsFrame.BookPage = CreateFrame("Frame", nil, ProfessionsFrame)
        ProfessionsFrame.BookPage:Hide()
    else
        local professions = {
            {name = "Fixturesmithing", rank = 50, maxRank = 100, id = 164, spell = 2018, texture = 1234,
                recipe = "Fixture Buckle", recipeSpell = 2672, output = 2862, reagent = 2835},
            {name = "Fixturetailoring", rank = 70, maxRank = 150, id = 197, spell = 3908, texture = 2345,
                recipe = "Fixture Bolt", recipeSpell = 2963, output = 2996, reagent = 2589},
            {name = "Fixture Cooking", rank = 30, maxRank = 75, id = 185, spell = 2550, texture = 3456,
                recipe = "Fixture Roast", recipeSpell = 2538, output = 2679, reagent = 2672},
            {name = "Fixture First Aid", rank = 30, maxRank = 75, id = 129, spell = 3273, texture = 4567},
            {name = "Fixture Fishing", rank = 15, maxRank = 75, id = 356, spell = 7620, texture = 5678},
            {name = "Fixture Enchanting", rank = 5, maxRank = 75, id = 333, spell = 7411, texture = 6789},
        }
        local spellSlots = {professions[1], professions[2], professions[4], professions[5]}
        local cookingLearned = false
        local active, requested
        local casts = 0
        local tabActions = {}
        Flux.SecureClickProxy = {
            Attach = function(tab, options)
                assert(not tabActions[tab], "a pooled tab must only attach its secure action once")
                tabActions[tab] = options
            end,
            Refresh = function(tab) assert(tabActions[tab]) end,
        }
        GetTradeSkillLine = function()
            if active then return active.name, active.rank, active.maxRank end
            return "UNKNOWN", 0, 0
        end
        if client == "classic" then
            GetProfessions = function() return 1, 2, nil, 5, cookingLearned and 3 or nil, 4 end
            GetProfessionInfo = function(index)
                local profession = professions[index]
                local slot
                for i, entry in ipairs(spellSlots) do if entry == profession then slot = i end end
                return profession.name, profession.texture, profession.rank, profession.maxRank, 1, slot - 1, profession.id
            end
        else
            GetProfessions, GetProfessionInfo = nil, nil
        end
        GetNumSpellTabs = function() return 1 end
        GetSpellTabInfo = function() return "General", nil, 0, #spellSlots end
        GetSpellBookItemName = function(index) return spellSlots[index].name end
        GetSpellBookItemInfo = function(index) return "SPELL", spellSlots[index].spell end
        GetSpellBookItemTexture = function(index) return spellSlots[index].texture end
        CastSpell = function(index)
            requested = assert(spellSlots[index], "switch must use a learned profession's native spell")
            active, casts = nil, casts + 1
            if requested == professions[6] then
                TradeSkillFrame:Hide()
                CraftFrame = CreateFrame("Frame", nil, UIParent)
            end
        end
        -- The first legacy SHOW can precede both the live rows and the owner cache.
        GetNumTradeSkills = function() return active and 1 or 0 end
        GetTradeSkillInfo = function(index)
            if index == 1 and active then return active.recipe, "optimal", 5 end
        end
        GetTradeSkillItemLink = function() return "item:" .. active.output end
        GetTradeSkillRecipeLink = client ~= "era" and function()
            return "|Henchant:" .. active.recipeSpell .. "|h[" .. active.recipe .. "]|h"
        end or nil
        GetTradeSkillNumMade = function() return 1, 1 end
        GetTradeSkillNumReagents = function() return 1 end
        GetTradeSkillReagentInfo = function() return "Fixture reagent", nil, 2, 10 end
        GetTradeSkillReagentItemLink = function() return "item:" .. active.reagent end
        Flux.Inventory.GetCount = function() return 10 end
        Flux.Inventory.Professions.ListCachedRecipes = function(skill)
            if not active or skill ~= active.name then return {} end
            return {{legacy = true, recipeID = 1, skillName = active.name, outputItemID = active.output,
                quantityMin = 1, quantityMax = 1, reagents = {{itemID = active.reagent, count = 2}}}}, "complete"
        end
        TradeSkillFrame = CreateFrame("Frame", nil, UIParent)
        TradeSkillFrame:SetAlpha(0.65)
        TradeSkillFrame_SetSelection = function(index) TradeSkillFrame.selectedSkill = index end
        assert(not ns.UI.window, "legacy workbench should wait for Blizzard's load-on-demand frame")
        dispatch("ADDON_LOADED", "Blizzard_TradeSkillUI")
        dispatch("TRADE_SKILL_SHOW")
        settleEvents()
        local ui = ns.UI
        local shell, returnButton = ui.classic, ui.returnButton
        assert(shell and not shell:IsVisible() and TradeSkillFrame:GetAlpha() == 0.65
            and returnButton and returnButton:IsVisible(), "saved Native UI keeps Blizzard visible with a Workbench button")
        returnButton:Fire("OnClick")
        settleEvents()
        assert(shell == ui.classic and shell:IsVisible() and ui.window:IsVisible() and ui.graph.frame:IsVisible()
            and TradeSkillFrame:GetAlpha() == 0 and not returnButton:IsVisible(),
            "Workbench reveals the same shell even before legacy recipe data is ready")
        assert(ui.window.parent == shell and shell.backdrop and ui.book.frame.backdrop,
            "legacy workbench and overview use their registered native-style backdrop")

        local function tabFor(profession)
            for _, candidate in ipairs(ui.professionTabs) do
                if candidate:IsVisible() and candidate.prof and candidate.prof.name == profession.name then return candidate end
            end
        end
        local function checkTab(profession)
            local tab = assert(tabFor(profession), "missing learned profession tab for " .. profession.name)
            assert(tab.parent == ui.professionRail and tab.icon.texture == profession.texture,
                "the profession rail must show the learned spell's own icon")
            assert(tabActions[tab] and tabActions[tab].spell() == profession.spell,
                "the secure action must reference the current tab's exact learned opening spell")
            return tab
        end
        for _, index in ipairs({1, 2, 4}) do
            assert(not checkTab(professions[index]):GetChecked(), "the profession source has not started loading")
        end
        assert(not tabFor(professions[3]) and not tabFor(professions[5]) and casts == 0,
            "the tab rail mirrors the learned crafting openers before any recipe observation")

        local function observe(profession)
            active = profession
            TradeSkillFrame.selectedSkill = 1
            dispatch("TRADE_SKILL_UPDATE")
            settleEvents()
            local name = ui.classicTitle:GetText()
            assert(name:find(profession.name, 1, true), "legacy update did not refresh the profession header")
            assert(ui.classicSkill:GetText() == profession.rank .. "/" .. profession.maxRank,
                "legacy update did not refresh the visible skill rank")
            local recipeID = client == "era" and ("legacy:fp:%d:%d:1:1:%dx2"):format(profession.spell, profession.output,
                profession.reagent) or "legacy:spell:" .. profession.recipeSpell
            local recipe = ns.Catalog.Get(recipeID)
            assert(recipe and recipe.completeness == "complete" and ui.selectedRecipeId == recipeID
                and ui.preview and ui.preview.rootRecipeId == recipeID,
                "the live legacy recipe did not reach the selected Flowcraft graph")
            for _, tab in ipairs(ui.professionTabs) do
                if tab:IsVisible() then
                    local selected = tab.prof.name == profession.name
                    assert((not not tab:GetChecked()) == selected and tabActions[tab].enabled() == (not selected),
                        "only the currently open native profession should be selected")
                end
            end
        end
        observe(professions[1])
        ui.overviewTab:Fire("OnClick")
        assert(ui.overviewTab:GetChecked() and ui.book.frame:IsVisible() and not ui.window:IsVisible())
        checkTab(professions[1]):Fire("OnClick")
        assert(casts == 0 and not ui.overviewTab:GetChecked() and ui.window:IsVisible(),
            "returning from the overview to the current profession should not cast it again")
        checkTab(professions[2]):Fire("OnClick")
        assert(requested == professions[2] and casts == 1, "an unopened profession tab must reach its learned spell")
        observe(requested)
        cookingLearned = true
        -- Inserting a newly learned spell also changes the later spellbook slots.
        table.insert(spellSlots, 2, professions[3])
        dispatch("SPELLS_CHANGED")
        settleEvents()
        checkTab(professions[3]):Fire("OnClick")
        assert(requested == professions[3] and casts == 2)
        observe(requested)
        checkTab(professions[2]):Fire("OnClick")
        assert(requested == professions[2] and casts == 3, "an existing tab must resolve the moved spellbook slot")
        observe(requested)
        cookingLearned = false
        table.remove(spellSlots, 2)
        dispatch("SPELLS_CHANGED")
        settleEvents()
        assert(not tabFor(professions[3]), "the rail must hide an unlearned profession even after its recipes were observed")
        checkTab(professions[1]):Fire("OnClick")
        assert(requested == professions[1] and casts == 4)
        observe(requested)

        ui.ShowNative()
        assert(not shell:IsVisible() and TradeSkillFrame:GetAlpha() == 0.65 and returnButton:IsVisible())
        TradeSkillFrame:Hide()
        dispatch("TRADE_SKILL_CLOSE")
        settleEvents()
        assert(not shell:IsVisible() and not returnButton:IsVisible(), "closing Blizzard must hide both views")
        TradeSkillFrame:Show()
        dispatch("TRADE_SKILL_SHOW")
        settleEvents()
        assert(not shell:IsVisible() and returnButton:IsVisible(), "reopening must preserve the selected native view")
        returnButton:Fire("OnClick")
        settleEvents()
        assert(ui.classic == shell and shell:IsVisible() and TradeSkillFrame:GetAlpha() == 0)
        InputUtil = {IsGamepadUIEnabled = function() return gamepad end}
        gamepad = true
        dispatch("INPUT_DEVICE_INTERFACE_TRANSITION", 1, 0)
        assert(not shell:IsVisible() and not returnButton:IsVisible() and TradeSkillFrame:GetAlpha() == 0.65
            and not ui.saved.nativeMode, "legacy controller handoff should preserve the customized mouse view")
        gamepad = false
        dispatch("INPUT_DEVICE_INTERFACE_TRANSITION", 0, 1)
        settleEvents()
        assert(shell:IsVisible() and TradeSkillFrame:GetAlpha() == 0)
        if client ~= "classic" then
            spellSlots[2] = professions[6]
            dispatch("SPELLS_CHANGED")
            settleEvents()
            assert(not tabFor(professions[2]), "the native rail should replace a forgotten primary profession")
            checkTab(professions[6]):Fire("OnClick")
            assert(requested == professions[6] and casts == 5 and CraftFrame and CraftFrame:IsVisible()
                and not shell:IsVisible() and not returnButton:IsVisible() and not next(ns.Queue.GetJobs()),
                "Enchanting's learned opener should leave the separate native craft panel usable")
            CraftFrame:Hide()
            CraftFrame = nil
        end
        TradeSkillFrame:Hide()
        assert(not shell:IsVisible() and TradeSkillFrame:GetAlpha() == 0.65,
            "closing an active workbench must restore the original native alpha")
        assert(not ns.state.lastError, ns.state.lastError)
        return
    end
    dispatch("ADDON_LOADED", client == "forever" and "Blizzard_Professions" or "Blizzard_TradeSkillUI")
    dispatch("TRADE_SKILL_SHOW")
    assert(ns.UI.window:IsVisible() and ns.UI.graph.frame:IsVisible(), "workbench does not attach after Blizzard load-on-demand")
    if client == "forever" then
        assert(ns.UI.window.parent == ProfessionsFrame.CraftingPage)
        assert(ns.UI.window:GetFrameLevel() > ProfessionsFrame.CraftingPage:GetFrameLevel())
        assert(clientCallbacks["Professions.RecipeSelected"] == 1, "duplicate native recipe hook")
        local savedMode = ns.UI.saved.nativeMode
        gamepad = true
        dispatch("INPUT_DEVICE_INTERFACE_TRANSITION", 1, 0)
        assert(not ns.UI.window:IsVisible() and not ns.UI.returnButton:IsShown()
            and ProfessionsFrame.CraftingPage:IsVisible(),
            "controller interface did not hand back the visible native working region")
        assert(ns.UI.saved.nativeMode == savedMode, "controller interface changed the user's saved view")
        gamepad = false
        dispatch("INPUT_DEVICE_INTERFACE_TRANSITION", 0, 1)
        assert(ns.UI.window:IsVisible(), "mouse and keyboard interface did not restore the previous workbench view")
    end
end

for client, info in pairs(expected) do
    run(client, info, not packageTarget or packageTarget == client)
end
run("retail", {version = "12.1.5", build = "70961", interface = 120105}, false)
run("unexpected-version", {version = "9.9.9", build = "99999", interface = 16001}, false)
print("runtime TOC load without a Settings page, late native host and disabled-client checks passed")
