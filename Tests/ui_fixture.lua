local events, timers = {}, {}
local methods = {}

local function frame(parent)
    return setmetatable({parent = parent, scripts = {}, hooks = {}, points = {}, shown = true,
        alpha = 1, level = 10, text = "", width = 780, height = 595}, {__index = methods})
end

function methods:Fire(name, ...)
    if self.scripts[name] then self.scripts[name](self, ...) end
    for _, hook in ipairs(self.hooks[name] or {}) do hook(self, ...) end
end
function methods:SetScript(name, callback) self.scripts[name] = callback end
function methods:HookScript(name, callback)
    self.hooks[name] = self.hooks[name] or {}
    table.insert(self.hooks[name], callback)
end
function methods:RegisterEvent(event) events[event] = self end
function methods:SetPoint(key, ...) self.points[key] = {...} end
function methods:ClearAllPoints() self.points = {} end
function methods:SetSize(w, h)
    if w == self.width and h == self.height then return end
    self.width, self.height = w, h
    self:Fire("OnSizeChanged", w, h)
end
function methods:SetWidth(w) self:SetSize(w, self.height) end
function methods:SetHeight(h) self:SetSize(self.width, h) end
function methods:GetSize() return self.width, self.height end
function methods:GetWidth() return self.width end
function methods:GetHeight() return self.height end
function methods:GetLeft() return self.left or 0 end
function methods:GetRight() return self:GetLeft() + self:GetWidth() end
function methods:GetTop() return self.top or (self.parent and self.parent:GetTop()) or self.height end
function methods:SetScale(scale) self.scale = scale end
function methods:GetEffectiveScale() return (self.scale or 1) * (self.parent and self.parent:GetEffectiveScale() or 1) end
function methods:GetFrameLevel() return self.level end
function methods:SetFrameLevel(level) self.level = level end
function methods:GetParent() return self.parent end
function methods:SetStatusBarTexture(texture) self.statusBarTexture = texture end
function methods:SetStatusBarColor(r, g, b) self.statusBarColor = {r, g, b} end
function methods:SetMinMaxValues(minimum, maximum) self.minimum, self.maximum = minimum, maximum end
function methods:SetValue(value) self.value = value end
function methods:SetText(value)
    assert(value == nil or type(value) == "string" or type(value) == "number",
        "SetText expects text, got " .. type(value))
    self.text = value or ""
    self:Fire("OnTextChanged", false)
end
function methods:GetText() return self.text end
function methods:SetShown(shown)
    if shown == self.shown then return end
    self.shown = shown
    self:Fire(shown and "OnShow" or "OnHide")
end
function methods:Show() self:SetShown(true) end
function methods:Hide() self:SetShown(false) end
function methods:IsShown() return self.shown end
function methods:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
function methods:SetAlpha(value) self.alpha = value end
function methods:GetAlpha() return self.alpha end
function methods:SetEnabled(value) self.enabled = value end
function methods:SetClipsChildren(value) self.clips = value end
function methods:CreateFontString() return frame(self) end
function methods:CreateTexture() return frame(self) end
function methods:HasFocus() return false end
function methods:SetChecked(checked) self.checked = checked end
function methods:GetChecked() return self.checked end
for _, method in ipairs({"SetAllPoints", "SetColorTexture", "SetTexture", "SetWordWrap", "SetJustifyV",
    "SetJustifyH", "SetAutoFocus", "EnableMouse", "EnableMouseWheel", "SetNumeric", "SetMaxLetters",
    "RegisterForClicks", "SetClampedToScreen", "SetFrameStrata", "ClearFocus", "SetTextColor",
    "SetNormalTexture", "SetHighlightTexture", "SetPushedTexture", "SetMovable", "RegisterForDrag",
    "StartMoving", "StopMovingOrSizing", "SetBackdropColor", "SetBackdropBorderColor"}) do
    methods[method] = function() end
end
function methods:SetTexture(texture) self.texture = texture end

CreateFrame = function(_, _, parent) return frame(parent) end
UIParent = frame()
UIParent:SetSize(1600, 900)
SlashCmdList = {}
C_Timer = {After = function(_, callback) timers[#timers + 1] = callback end}

local function flush()
    local limit = 100
    while #timers > 0 do
        limit = limit - 1
        assert(limit > 0, "Refresh callback loop")
        table.remove(timers, 1)()
    end
end

local function setup(target, savedUI, configure)
    local callbacks = {}
    EventRegistry = {RegisterCallback = function(_, event, callback, owner)
        events[event] = function(...) callback(owner, ...) end
    end}
    GetItemInfo = function(id) return "Fixture item " .. id end
    local ns = {target = target, state = {ready = true, characterKey = "fixture-player", build = 16001,
        char = {ui = savedUI}, db = {}}}
    function ns:On(event, callback)
        callbacks[event] = callbacks[event] or {}
        table.insert(callbacks[event], callback)
    end
    function ns:Emit(event, ...)
        for _, callback in ipairs(callbacks[event] or {}) do callback(self, ...) end
    end
    local known = {
        [11] = {id = 11, recipeID = 11, professionId = 5, outputItemID = 100, outputKind = "item",
            characterKey = ns.state.characterKey, learned = true, completeness = "complete", yield = 1,
            name = "Bolt of cloth", reagents = {{itemID = 200, quantity = 2}}},
        [22] = {id = 22, recipeID = 22, professionId = 6, outputItemID = 200, outputKind = "item",
            characterKey = ns.state.characterKey, learned = true, completeness = "complete", yield = 2,
            name = "Thread", reagents = {{itemID = 300, quantity = 1}}},
        [33] = {id = 33, recipeID = 33, professionId = 5, outputItemID = 110, outputKind = "item",
            characterKey = ns.state.characterKey, learned = true, completeness = "complete", yield = 1,
            name = "Mooncloth", reagents = {{itemID = 300, quantity = 1}}, constraints = {cooldownUntil = 100}},
    }
    local snapshot = {recipesById = known, byOutput = {[100] = {11}, [200] = {22}, [110] = {33}},
        revision = 1, characterKey = ns.state.characterKey}
    ns.Catalog = {Snapshot = function() return snapshot end, Get = function(id) return known[id] end}
    ns.Clients = {
        CurrentProfessionID = function() return 5 end,
        ListProfessions = function() return {{id = 5, name = "Tailoring", rank = 200}, {id = 6, name = "Other"}} end,
    }
    local stock = {[300] = 3}
    ns.InventoryAdapter = {
        GetRevision = function() return "bags:1" end,
        GetStatus = function() return {ready = true, reliable = true, source = "builtin"} end,
        Snapshot = function() return stock end,
        Count = function(id) return stock[id] or 0 end,
        InformationalBankCount = function() return 0 end,
    }
    ns.Execution = {ProcessNext = function(job, task)
        if not task then job, task = ns.Queue.NextTask(ns.Clients.CurrentProfessionID(), job) end
        ns.processed = {job, task}
        return true, "Processed a fixture action"
    end, CraftSelected = function(recipeId, all, _, maximum)
        ns.directCraft = {recipeId, all, maximum}
        return true, "Crafted a fixture action"
    end, CreateSelected = function(recipeId, quantity)
        ns.directCraft = {recipeId, false, quantity}
        return true, "Queued a fixture action"
    end}
    ns.Execution.ProcessClick = function(...) return ns.Execution.ProcessNext(...) end
    ns.MarketAdapter = {QuoteItems = function()
        return {[100] = {unitPrice = 100, unit = "item", provider = "Auctionator"}, [200] = 90, [300] = 1}
    end}
    GetServerTime = function() return 50 end
    ProfessionsFrame, TradeSkillFrame = nil, nil
    if target == "forever" then
        ProfessionsFrame = frame(UIParent)
        local page = frame(ProfessionsFrame)
        ProfessionsFrame.CraftingPage = page
        page.RecipeList = frame(page)
        page.RecipeList:SetWidth(304)
        ProfessionsFrame.BookPage = frame(ProfessionsFrame)
        ProfessionsFrame.BookPage:Hide()
        page.SchematicForm = frame(page)
        page.SchematicForm.selectedID = 11
        page.SchematicForm.GetRecipeInfo = function(self)
            return {recipeID = self.selectedID}
        end
        page.SchematicForm.Reagents = frame(page.SchematicForm)
        page.CreateButton = frame(page)
    else
        TradeSkillFrame = frame(UIParent)
    end
    if configure then configure(ns) end
    for _, name in ipairs({"Locale", "Queue", "Planner", "Pricing", "Comparison", "Book",
        "Logistics", "RecipeList", "RecipeProfit", "Graph", "UI"}) do
        assert(loadfile("FluxCraft/" .. name .. ".lua"))("FluxLogistics", ns)
    end
    assert(ns.Queue.Initialize(ns.state.char))
    ns:Emit("READY")
    flush()
    return ns, flush, stock, events
end

return setup
