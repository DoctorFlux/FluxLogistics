-- Optional Auctionator public API boundary. A cached quote is an estimate,
-- never an offer or proof of available market depth.
local addonName, ns = ...
ns = ns or {}
local caller = type(addonName) == "string" and addonName or "FluxLogistics"
local L = ns.L.market

local Adapter = {}
ns.AuctionatorAdapter = Adapter
local revision = 0
local registered = false
local onUpdate

local function PublicAPI()
    local auctionator = rawget(_G, "Auctionator")
    local api = type(auctionator) == "table" and auctionator.API
    local v1 = type(api) == "table" and api.v1
    return type(v1) == "table" and v1 or nil
end

local function ValidPrice(value)
    return type(value) == "number" and value > 0 and value < math.huge and value == value
end

function Adapter.IsAvailable()
    local api = PublicAPI()
    return api ~= nil and type(api.GetAuctionPriceByItemID) == "function"
end

local function OptionalNumber(api, method, arg)
    if type(api[method]) ~= "function" then return nil end
    local ok, value = pcall(api[method], caller, arg)
    if ok and type(value) == "number" and value == value
        and value >= 0 and value < math.huge then
        return value
    end
    return nil
end

local function ExactVariant(api, itemLink)
    if not itemLink or type(api.IsAuctionDataExactByItemLink) ~= "function" then
        return nil
    end
    local ok, exact = pcall(api.IsAuctionDataExactByItemLink, caller, itemLink)
    if ok and type(exact) == "boolean" then return exact end
    return nil
end

local function DistinctLinkQuote(api, itemID, itemLink, price)
    local getBasePrice = api.GetAuctionPriceByItemID
    if type(getBasePrice) ~= "function" then return false end
    local ok, basePrice = pcall(getBasePrice, caller, itemID)
    if not ok or basePrice ~= nil and not ValidPrice(basePrice) then return false end
    if price ~= basePrice then return true end

    -- Auctionator can report a resolved base key as exact. Equal prices
    -- distinguish records only if their public ages can be told apart.
    local baseAge = OptionalNumber(api, "GetAuctionAgeByItemID", itemID)
    if baseAge == nil then return false end
    local linkAge = OptionalNumber(api, "GetAuctionAgeByItemLink", itemLink)
    return linkAge ~= nil and linkAge ~= baseAge
        and baseAge == OptionalNumber(api, "GetAuctionAgeByItemID", itemID)
end

local function HasOnlyDefaultBonusTree(fields, bonusCount)
    -- Forever includes 3524 for the item's default bonus tree. Its presence
    -- alone does not identify a different market item.
    if ns.target ~= "forever" or bonusCount ~= 1 or tonumber(fields[14]) ~= 3524
        or (tonumber(fields[12]) or 0) ~= 0 then
        return false
    end
    for index = 2, 6 do
        if (tonumber(fields[index]) or 0) ~= 0 then return false end
    end
    for index = 15, #fields do
        if (tonumber(fields[index]) or 0) ~= 0 then return false end
    end
    return true
end

local function LinkVariantIdentity(itemLink)
    local payload = itemLink:match("item:([%d:%-]+)")
    if not payload then return nil end
    local fields = {}
    for field in (payload .. ":"):gmatch("([^:]*):") do
        fields[#fields + 1] = field
    end
    -- Link level and instance difficulty alone do not identify a different item.
    local suffixID = tonumber(fields[7]) or 0
    local upgradeID = tonumber(fields[11]) or 0
    local bonusCount = tonumber(fields[13]) or 0
    if suffixID ~= 0 or upgradeID ~= 0 or bonusCount > 0 and not HasOnlyDefaultBonusTree(fields, bonusCount) then
        return {itemLink = itemLink, requireExact = true, variantKey = payload}
    end
end

local function VariantItemDataReady(itemID)
    local isCached = C_Item and C_Item.IsItemDataCachedByID
    if ns.target ~= "forever" or not isCached or isCached(itemID) then return true end
    -- Auctionator's level key resolves asynchronously when this data is absent.
    -- Its public exactness method can mark the base-item price as exact in that window.
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return false
end

local function marketContext(database)
    return {
        realm = GetRealmName and GetRealmName() or "unknown",
        faction = UnitFactionGroup and UnitFactionGroup("player") or "unknown",
        region = GetCurrentRegion and GetCurrentRegion() or nil,
        build = ns.state and ns.state.build or nil,
        database = database,
    }
end

local function QuoteRecord(api, itemID, itemLink, price, method, variantKey)
    local ageMethod = itemLink and "GetAuctionAgeByItemLink" or "GetAuctionAgeByItemID"
    local age = OptionalNumber(api, ageMethod, itemLink or itemID)
    return {
        itemID = itemID,
        itemLink = itemLink,
        variantKey = variantKey,
        unitPrice = price, -- copper per single item, retained at API precision
        unit = "item",
        provider = "auctionator",
        source = "Auctionator API v1 " .. method,
        estimate = true,
        actualOffer = false,
        availability = "unknown",
        age = age, -- days; nil is unknown or beyond API's 21-day window
        ageUnit = "days",
        ageUnknown = age == nil,
        stale = false,
        variantExact = ExactVariant(api, itemLink), -- Database identity at Auctionator's granularity.
        marketContext = marketContext("Auctionator local price database"),
        revision = revision,
    }
end

function Adapter.GetQuote(itemID, itemLink, identity)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then
        return nil, L.invalidItem
    end
    local api = PublicAPI()
    if not api then
        return nil, L.auctionatorUnavailable
    end
    local requireExact = identity and identity.requireExact
    if requireExact and type(itemLink) == "string" and not VariantItemDataReady(itemID) then
        return nil, L.auctionatorVariant
    end
    -- Link-specific method is used only when the running release exposes it.
    if type(itemLink) == "string" and type(api.GetAuctionPriceByItemLink) == "function" then
        local ok, price = pcall(api.GetAuctionPriceByItemLink, caller, itemLink)
        if ok and ValidPrice(price) then
            local quote = QuoteRecord(api, itemID, itemLink, price, "GetAuctionPriceByItemLink",
                identity and identity.variantKey)
            if requireExact then
                if quote.variantExact == true and DistinctLinkQuote(api, itemID, itemLink, price) then return quote end
            elseif quote.variantExact ~= false then
                return quote
            end
        end
    end
    if requireExact then return nil, L.auctionatorVariant end
    if type(api.GetAuctionPriceByItemID) ~= "function" then
        return nil, L.auctionatorMissingMethod
    end
    local ok, price = pcall(api.GetAuctionPriceByItemID, caller, itemID)
    if not ok or not ValidPrice(price) then
        return nil, L.auctionatorUnknown
    end
    local quote = QuoteRecord(api, itemID, nil, price, "GetAuctionPriceByItemID")
    if type(itemLink) == "string" then
        quote.requestedItemLink = itemLink
        quote.variantExact = false
    end
    return quote
end

function Adapter.GetRevision()
    return revision
end

local function SearchAPI()
    local api = PublicAPI()
    local modern, legacy = _G.AuctionHouseFrame, _G.AuctionFrame
    if api and (modern and modern:IsShown() or legacy and legacy:IsShown()) then return api end
end

function Adapter.CanSearchList()
    local api = SearchAPI()
    return api and (type(api.MultiSearchAdvanced) == "function" or type(api.MultiSearchExact) == "function")
end

local function ValidSearchQuantity(quantity)
    return type(quantity) == "number" and quantity >= 1 and quantity <= 9999999 and quantity % 1 == 0
end

local function SearchTerm(name, quantity, maxUnitPrice)
    local term = {searchString = name, isExact = true, quantity = quantity}
    if ValidPrice(maxUnitPrice) then term.maxPrice = maxUnitPrice end
    return term
end

local function OpenSearch(api, names, terms)
    if terms and type(api.MultiSearchAdvanced) == "function" then
        local opened = pcall(api.MultiSearchAdvanced, caller, terms)
        return opened, opened
    end
    if type(api.MultiSearchExact) ~= "function" then return false end
    local opened = pcall(api.MultiSearchExact, caller, names)
    return opened, false
end

local function SearchName(itemID)
    if type(itemID) ~= "number" or itemID <= 0 or itemID % 1 ~= 0 then return end
    local name = GetItemInfo and GetItemInfo(itemID)
    if not name and C_Item and C_Item.GetItemNameByID then name = C_Item.GetItemNameByID(itemID) end
    if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    if type(name) == "string" and name ~= "" and not name:find("[;^]") and not name:match('^%s*".*"%s*$') then
        return name
    end
end

function Adapter.SearchExact(itemID, quantity, maxUnitPrice)
    local api = SearchAPI()
    if not api then return false end
    if quantity ~= nil and not ValidSearchQuantity(quantity) then return false end
    local name = SearchName(itemID)
    if not name then return false end
    local terms = quantity and {SearchTerm(name, quantity, maxUnitPrice)}
    return OpenSearch(api, {name}, terms)
end

function Adapter.SearchList(items)
    local api = SearchAPI()
    if not api or type(items) ~= "table" then return false, false, 0 end
    local candidates, countByName, skipped = {}, {}, 0
    for _, item in ipairs(items) do
        local name = type(item) == "table" and (item.quantity == nil or ValidSearchQuantity(item.quantity))
            and SearchName(item.itemID)
        if name then
            candidates[#candidates + 1] = SearchTerm(name, item.quantity, item.maxUnitPrice)
            countByName[name] = (countByName[name] or 0) + 1
        else
            skipped = skipped + 1
        end
    end
    local names, terms = {}, {}
    for _, term in ipairs(candidates) do
        local name = term.searchString
        -- Auctionator searches by name. Two distinct IDs with one name do not
        -- identify separate, quantity-qualified shopping rows.
        if countByName[name] == 1 then
            names[#names + 1], terms[#terms + 1] = name, term
        else
            skipped = skipped + 1
        end
    end
    if #terms == 0 then return false, false, skipped end
    local opened, forwarded = OpenSearch(api, names, terms)
    return opened, not not forwarded, skipped
end

-- Version 341's public callback fires after scan price processing. It cannot
-- prove any particular item has a current offer, so existing accepted plans
-- keep their captured quote revision until the user explicitly replans.
function Adapter.Start(callback)
    onUpdate = callback
    if registered then return true end
    local api = PublicAPI()
    if not (api and type(api.RegisterForDBUpdate) == "function") then
        return false, L.auctionatorMissingCallback
    end
    local ok = pcall(api.RegisterForDBUpdate, caller, function()
        revision = revision + 1
        if type(onUpdate) == "function" then onUpdate(revision) end
    end)
    registered = ok
    if ok then return true end
    return false, L.auctionatorFailedCallback
end

function Adapter.QuoteItems(itemIDs)
    local quotes, missing = {}, {}
    for _, itemID in ipairs(itemIDs or {}) do
        local quote, reason = Adapter.GetQuote(itemID)
        if quote then
            quotes[tonumber(itemID)] = quote
        else
            missing[tonumber(itemID)] = reason
        end
    end
    return quotes, missing
end

local Market = {}
ns.MarketAdapter = Market

local function tsmAPI()
    local api = rawget(_G, "TSM_API")
    if type(api) == "table" and type(api.GetCustomPriceValue) == "function" then return api end
end

local function tsmQuote(itemID, itemLink, identity)
    local api = tsmAPI()
    if not api then return nil, L.tsmUnavailable end
    local itemString = "i:" .. tostring(itemID)
    if type(itemLink) == "string" and type(api.ToItemString) == "function" then
        local ok, converted = pcall(api.ToItemString, itemLink)
        if ok and type(converted) == "string" and tonumber(converted:match("^i:(%d+)")) == itemID then
            itemString = converted
        end
    end
    local variantSpecific = itemString ~= "i:" .. tostring(itemID)
    if identity and identity.requireExact and not variantSpecific then
        return nil, L.tsmVariant
    end
    local ok, amount = pcall(api.GetCustomPriceValue, "DBMarket", itemString)
    if not ok or not ValidPrice(amount) then return nil, L.tsmUnknown end
    return {itemID = itemID, itemLink = itemLink, itemString = itemString, unitPrice = amount,
        unit = "item", provider = "tsm", source = "TradeSkillMaster DBMarket", expression = "DBMarket",
        estimate = true, actualOffer = false, availability = "unknown", ageUnknown = true,
        variantKey = identity and identity.variantKey,
        variantExact = variantSpecific and true or nil,
        marketContext = marketContext("TradeSkillMaster realm market estimate")}
end

function Market.GetQuote(itemID, itemLink, provider, allowFallback)
    local identity
    if type(itemLink) == "table" then
        identity = itemLink
        itemLink = identity.itemLink
    elseif type(itemLink) == "string" then
        identity = LinkVariantIdentity(itemLink)
    end
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 or itemID >= math.huge or itemID ~= math.floor(itemID) then
        return nil, L.invalidItem
    end
    if type(itemLink) == "string" then
        local linkID = tonumber(itemLink:match("item:(%d+)"))
        if linkID and linkID ~= itemID then return nil, L.invalidLink end
    end
    provider = type(provider) == "string" and string.lower(provider) or "auto"
    local primary, alternate = Adapter.GetQuote, tsmQuote
    if provider == "tsm" then primary, alternate = tsmQuote, Adapter.GetQuote
    elseif provider ~= "auto" and provider ~= "auctionator" then return nil, L.unknownProvider end
    local quote, reason = primary(itemID, itemLink, identity)
    if quote or (provider ~= "auto" and not allowFallback) then return quote, reason end
    local fallback, why = alternate(itemID, itemLink, identity)
    if fallback then
        fallback.fallbackFrom = provider == "auto" and "auctionator" or provider
        fallback.fallbackReason = reason
        return fallback
    end
    return nil, reason or why
end

function Market.QuoteItems(itemIDs, links, provider, allowFallback)
    local quotes, missing = {}, {}
    for _, itemID in ipairs(itemIDs or {}) do
        local link = links and (links[itemID] or links[tostring(itemID)])
        local quote, reason = Market.GetQuote(itemID, link, provider, allowFallback)
        if quote then quotes[itemID] = quote else missing[itemID] = reason end
    end
    return quotes, missing
end

Market.GetRevision = Adapter.GetRevision
Market.Start = Adapter.Start

return Adapter
