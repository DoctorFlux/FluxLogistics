local _, FC = ...

-- FluxCraft's Classic book view. Blizzard owns the Forever/Retail BookPage.
local BookMixin = {}
FC.BookMixin = BookMixin

function BookMixin.BuildEntries(professions, catalog)
    local counts, missing, entries = {}, {}, {}
    for _, recipe in pairs(catalog and catalog.recipesById or {}) do
        if recipe.learned == true and recipe.characterKey == catalog.characterKey
            and recipe.professionId then
            local key = tostring(recipe.professionId)
            counts[key] = (counts[key] or 0) + 1
        end
    end
    for _, profession in ipairs(catalog and catalog.unobservedProfessions or {}) do
        missing[tostring(profession.id)] = profession.message
    end
    for _, profession in ipairs(professions or {}) do
        entries[#entries + 1] = {
            id = profession.id, name = profession.name, texture = profession.texture,
            rank = profession.rank, maxRank = profession.maxRank,
            recipeCount = counts[tostring(profession.id)] or 0,
            discoveryPrompt = missing[tostring(profession.id)],
        }
    end
    return entries
end

function BookMixin:Initialize(parent, onSelect, rightInset)
    self.frame = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    self.frame:SetPoint("TOPLEFT", 9, -52)
    self.frame:SetPoint("BOTTOMRIGHT", -rightInset, 6)
    if self.frame.SetBackdrop then
        self.frame:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 20,
            insets = {left = 5, right = 5, top = 5, bottom = 5}})
    else
        local background = self.frame:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints()
        background:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background")
    end
    self.frame:Hide()
    self.cards = {}
    for i = 1, 8 do
        local card = CreateFrame("Button", nil, self.frame, "UIPanelButtonTemplate")
        card:SetHeight(65)
        local y = -11 - math.floor((i - 1) / 2) * 71
        if i % 2 == 1 then
            card:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 12, y)
            card:SetPoint("TOPRIGHT", self.frame, "TOP", -4, y)
        else
            card:SetPoint("TOPLEFT", self.frame, "TOP", 4, y)
            card:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -12, y)
        end
        card:SetText("")
        card.icon = card:CreateTexture(nil, "ARTWORK")
        card.icon:SetSize(38, 38)
        card.icon:SetPoint("LEFT", 12, 0)
        card.name = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.name:SetPoint("TOPLEFT", 60, -13)
        card.name:SetPoint("TOPRIGHT", -10, -13)
        card.name:SetJustifyH("LEFT")
        card.status = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.status:SetPoint("TOPLEFT", 60, -34)
        card.status:SetPoint("TOPRIGHT", -10, -34)
        card.status:SetJustifyH("LEFT")
        card:SetScript("OnClick", function()
            if card.entry then onSelect(card.entry) end
        end)
        self.cards[i] = card
    end
end

function BookMixin:Render(professions, catalog, currentProfessionID)
    local entries = self.BuildEntries(professions, catalog)
    for i, card in ipairs(self.cards) do
        local entry = entries[i]
        card.entry = entry
        if entry then
            card.icon:SetTexture(entry.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            card.name:SetText((tostring(entry.id) == tostring(currentProfessionID) and "|cffffd36b▶ |r" or "")
                .. tostring(entry.name or FC.L.title))
            card.status:SetText(entry.discoveryPrompt or
                FC.L.professionBookProgress:format(tostring(entry.rank or "?"), tostring(entry.maxRank or "?"), entry.recipeCount))
            card:Show()
        else
            card:Hide()
        end
    end
end

function BookMixin.New(parent, onSelect, rightInset)
    local instance = setmetatable({}, {__index = BookMixin})
    instance:Initialize(parent, onSelect, rightInset)
    return instance
end
