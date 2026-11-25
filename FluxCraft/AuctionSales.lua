local _, FC = ...
if FC.disabled then return end

local L = FC.L
local isSecret = issecretvalue or function() return false end
local pending, newLines, notifications = {}, {}, {}
local auctionOpen, mailOpen, legacyRows, mailRows
local receipts, resolvedAuctions = {}, {}
local delayedInvoices = {}
local scheduled, chat, pattern, modernAH, legacyAH, queryNeeded, queryScheduled
local activeBatch, changedGroups = nil, {}
local batchSeconds = 60
local recentSeconds = 5
local payoutSeconds = 60 * 60
local pendingSeconds = 6 * payoutSeconds
local listingSeconds = 48 * 60 * 60

local function readable(value, expectedType)
    return not isSecret(value) and type(value) == expectedType
end

local function positive(value)
    return readable(value, "number") and value > 0 and value % 1 == 0
end

local function nonnegative(value)
    return readable(value, "number") and value >= 0 and value % 1 == 0
end

local function serverTime()
    return GetServerTime()
end

local function escape(text)
    return (text:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function itemName(text)
    return text:match("|h%[(.-)%]|h") or text
end

local function money(copper)
    if type(GetMoneyString) == "function" then return GetMoneyString(copper, true) end
    return ("%dg %02ds %02dc"):format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function groupText(group)
    local quantity, total, priced = 0, 0, 0
    local allQuantities, estimated, differentPrices = true, false, false
    local unitPrice
    for _, sale in ipairs(group.sales) do
        if sale.quantity then quantity = quantity + sale.quantity else allQuantities = false end
        if sale.copper and not sale.ceiling then
            total = total + sale.copper
            priced = priced + 1
            estimated = estimated or not sale.paid
            if sale.quantity then
                local unit = sale.copper / sale.quantity
                differentPrices = differentPrices or (unitPrice ~= nil and unitPrice ~= unit)
                unitPrice = unit
            end
        end
    end

    local headline = L.auctionSold:format(group.item)
    if allQuantities then
        headline = L.auctionSoldQuantity:format(quantity, group.item)
    elseif quantity > 0 then
        headline = L.auctionSoldKnownQuantity:format(quantity, group.item)
    end

    local amount = L.auctionSoldPending
    local first = group.sales[1]
    if #group.sales == 1 and first.ceiling then
        amount = L.auctionSoldMaximum:format(money(first.copper))
    elseif priced > 0 then
        amount = (estimated and "~" or "") .. money(total)
        if priced < #group.sales then
            amount = L.auctionSoldSubtotal:format(amount)
        elseif allQuantities and quantity > 1 then
            local average = group.averageOnly or differentPrices or total % quantity ~= 0
            local roundedUnit = math.floor(total / quantity + 0.5)
            local unit = (estimated or total % quantity ~= 0) and "~" .. money(roundedUnit) or money(roundedUnit)
            local unitFormat = average and L.materialUnitAverage or L.materialUnit
            return L.auctionSoldUnit:format(headline, amount, unitFormat:format(unit))
        end
    end
    return L.auctionSoldAmount:format(headline, amount)
end

local function refreshGroup(group)
    local message = groupText(group)
    if message == group.message then return end
    group.message = message
    chat:TransformMessages(function(_, _, _, _, ...)
        local marker = select("#", ...) > 3 and select(-1, ...)
        return readable(marker, "table") and marker == group
    end, function(_, ...) return message, ... end)
end

local function updateSale(sale, quantity, copper, ceiling)
    sale.quantity, sale.copper, sale.ceiling = quantity, copper, ceiling
    if sale.group.message then changedGroups[sale.group] = true end
end

local function showPayout(sale, quantity, copper)
    sale.paid = true
    updateSale(sale, positive(quantity) and quantity or sale.quantity, copper)
    if sale.auctionID then resolvedAuctions[sale.auctionID] = true end
end

local function showEstimate(sale, quantity, gross, ceiling)
    updateSale(sale, quantity, gross - math.floor(gross / 20), ceiling)
    sale.estimated = true
end

local function resolvedPrice(sale, quantity, copper)
    showEstimate(sale, quantity, copper)
    sale.priced = true
    if sale.auctionID then resolvedAuctions[sale.auctionID] = true end
end

local function ownListings()
    return _G.FluxLogisticsAuctionSalesDB
end

local function saveListings(rows)
    _G.FluxLogisticsAuctionSalesDB = rows
end

local function listingName(row)
    if readable(row.itemLink, "string") then return itemName(row.itemLink) end
    local getInfo = C_AuctionHouse.GetItemKeyInfo
    if type(getInfo) ~= "function" or not readable(row.itemKey, "table") then return end
    local info = getInfo(row.itemKey)
    if readable(info, "table") and readable(info.itemName, "string") then return info.itemName end
end

local function cacheOwnedAuctions()
    local api = C_AuctionHouse
    if type(api.HasFullOwnedAuctionResults) == "function" and not api.HasFullOwnedAuctionResults() then return end
    local rows = api.GetOwnedAuctions()
    if not readable(rows, "table") then return end
    local active = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Active
    local listings, now = {}, serverTime()
    for _, row in ipairs(rows) do
        if readable(row, "table") and readable(row.status, "number") and row.status == active
            and positive(row.quantity) and positive(row.auctionID) then
            local name = listingName(row)
            local buyout = positive(row.buyoutAmount) and row.buyoutAmount * row.quantity
            local gross = buyout
                or (positive(row.bidAmount) and row.bidAmount or row.minBid)
            if name and positive(gross) then
                local remaining = nonnegative(row.timeLeftSeconds) and row.timeLeftSeconds or listingSeconds
                local partial = row.quantity > 1
                local lowerBid = positive(row.bidAmount) and row.bidAmount < gross
                local lowerMinimum = positive(row.minBid) and row.minBid < gross
                listings[#listings + 1] = {name = name, auctionID = row.auctionID, gross = gross,
                    quantity = row.quantity, partial = partial, ceiling = partial or buyout and (lowerBid or lowerMinimum),
                    expires = now + remaining + recentSeconds}
            end
        end
    end
    saveListings(listings)
    return true
end

local function cacheLegacyAuctions()
    local count, total = GetNumAuctionItems("owner")
    if not nonnegative(count) or nonnegative(total) and count < total then return end
    local listings, now = {}, serverTime()
    for index = 1, count do
        local name, _, quantity, _, _, _, _, minBid, _, buyout, bid, _, _, _, _, status = GetAuctionItemInfo("owner", index)
        if readable(name, "string") and positive(quantity) and readable(status, "number") and status == 0 then
            local gross = positive(buyout) and buyout or (positive(bid) and bid or minBid)
            if positive(gross) then
                local ceiling = positive(buyout) and (positive(bid) and bid < buyout or positive(minBid) and minBid < buyout)
                listings[#listings + 1] = {name = name, gross = gross, quantity = quantity, ceiling = ceiling,
                    expires = now + listingSeconds}
            end
        end
    end
    saveListings(listings)
end

local function estimateFromListing(sale)
    local listings = ownListings()
    if type(listings) ~= "table" then return end
    local candidate, candidateIndex, now = nil, nil, serverTime()
    for index, listing in ipairs(listings) do
        if readable(listing, "table") and positive(listing.expires) and listing.expires >= now
            and positive(listing.quantity) and positive(listing.gross) and listing.name == sale.name then
            if sale.auctionID and sale.auctionID == listing.auctionID then
                candidate, candidateIndex = listing, index
                break
            elseif not sale.auctionID then
                if candidate and (candidate.gross ~= listing.gross or candidate.quantity ~= listing.quantity
                    or candidate.partial ~= listing.partial or candidate.ceiling ~= listing.ceiling) then return end
                if not candidate then candidate, candidateIndex = listing, index end
            end
        end
    end
    if candidate then
        showEstimate(sale, not candidate.partial and candidate.quantity or nil, candidate.gross,
            candidate.partial or candidate.ceiling)
        if not candidate.partial then table.remove(listings, candidateIndex) end
    end
end

local function requestOwnedAuctions()
    if not auctionOpen or not queryNeeded or queryScheduled then return end
    queryScheduled = true
    C_Timer.After(0.25, function()
        queryScheduled = false
        if not auctionOpen or not queryNeeded then return end
        if modernAH then
            local api = C_AuctionHouse
            if type(api.QueryOwnedAuctions) ~= "function" then return end
            if type(api.IsThrottledMessageSystemReady) == "function" and not api.IsThrottledMessageSystemReady() then return end
            queryNeeded = false
            api.QueryOwnedAuctions({})
        elseif legacyAH and type(GetOwnerAuctionItems) == "function" then
            queryNeeded = false
            GetOwnerAuctionItems()
        end
    end)
end

local function matchOwnedSales()
    if not modernAH then return end
    local api = C_AuctionHouse
    local sold = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold
    if sold == nil or not api or type(api.GetOwnedAuctions) ~= "function" then return end
    local byID = {}
    for _, sale in ipairs(pending) do
        if sale.auctionID and not sale.paid and not sale.priced and not resolvedAuctions[sale.auctionID] then
            if byID[sale.auctionID] == nil then
                byID[sale.auctionID] = sale
            else
                byID[sale.auctionID] = false
            end
        end
    end
    if next(byID) == nil then return end
    local rows = api.GetOwnedAuctions()
    if not readable(rows, "table") then return end
    for _, row in ipairs(rows) do
        if readable(row, "table") and positive(row.auctionID) and readable(row.status, "number")
            and row.status == sold and positive(row.quantity) then
            local sale = byID[row.auctionID]
            -- A winning bid can be lower than the advertised buyout. A sold commodity's
            -- buyout is already the whole sale, while an active listing uses a unit price.
            local copper = positive(row.bidAmount) and row.bidAmount or row.buyoutAmount
            if sale and not sale.priced and positive(copper) then resolvedPrice(sale, row.quantity, copper) end
        end
    end
end

local function matchesInvoice(sale, invoice, now)
    local age = now - sale.time
    if sale.name ~= invoice.name or age < 0 or age > pendingSeconds then return false end
    if invoice.eta and sale.eta and age <= payoutSeconds + 60 then
        local minutes = (invoice.eta - sale.eta) % 1440
        return minutes <= 1 or minutes >= 1439
    end
    return invoice.receivedAt and math.abs(invoice.receivedAt - sale.payoutAt) <= 60
end

local function collectInvoiceGroup(bundles, candidates, invoice)
    local first = candidates[1]
    if not first then return end
    local group = first.group
    local bundle = bundles[group]
    local eligible = #candidates > 1 and bundle ~= false and (not bundle or #bundle.sales == #candidates)
    for index, sale in ipairs(candidates) do
        if sale.group ~= group or sale.paid or (bundle and bundle.sales[index] ~= sale) then eligible = false end
    end
    if not eligible then
        for _, sale in ipairs(candidates) do bundles[sale.group] = false end
        return
    end
    bundle = bundle or {sales = candidates, invoices = {}, allQuantities = true}
    bundle.invoices[#bundle.invoices + 1] = invoice
    bundle.allQuantities = bundle.allQuantities and invoice.quantity ~= nil
    bundles[group] = bundle
end

local function matchTimedInvoices(now)
    local matches, bundles = {}, {}
    for _, invoice in ipairs(delayedInvoices) do
        local candidates = {}
        for _, sale in ipairs(pending) do
            if matchesInvoice(sale, invoice, now) then candidates[#candidates + 1] = sale end
        end
        for _, sale in ipairs(candidates) do
            if #candidates == 1 and matches[sale] == nil then matches[sale] = invoice else matches[sale] = false end
        end
        collectInvoiceGroup(bundles, candidates, invoice)
    end
    for sale, invoice in pairs(matches) do
        if invoice and not sale.paid then showPayout(sale, invoice.quantity, invoice.copper) end
    end
    -- An invoice set can prove the batch totals even when its individual sales are interchangeable.
    for group, bundle in pairs(bundles) do
        if bundle and #bundle.sales == #bundle.invoices then
            group.averageOnly = not bundle.allQuantities
            for index, sale in ipairs(bundle.sales) do
                local invoice = bundle.invoices[index]
                showPayout(sale, bundle.allQuantities and invoice.quantity or nil, invoice.copper)
            end
        end
    end
    delayedInvoices = {}
end

local function settle()
    scheduled = false
    for name, lines in pairs(newLines) do
        local ids = notifications[name]
        if ids and #ids == #lines then
            for index, sale in ipairs(lines) do sale.auctionID = ids[index] or nil end
        end
    end
    newLines, notifications = {}, {}
    matchOwnedSales()

    local recent, now = {}, GetTime()
    matchTimedInvoices(now)
    for _, sale in ipairs(pending) do
        if now - sale.time <= recentSeconds then
            local name = sale.name
            if recent[name] == nil then recent[name] = sale else recent[name] = false end
        end
    end
    for name, receipt in pairs(receipts) do
        local sale = recent[name]
        if receipt and sale and not sale.paid and math.abs(receipt.time - sale.time) <= recentSeconds then
            if receipt.mail and not receipt.eta and not receipt.receivedAt then
                showPayout(sale, receipt.quantity, receipt.copper)
            elseif not receipt.mail and not sale.priced then
                resolvedPrice(sale, receipt.quantity, receipt.copper)
            end
        end
    end
    receipts = {}

    local kept = {}
    for _, sale in ipairs(pending) do
        local age = now - sale.time
        if not sale.paid and not sale.estimated and age <= recentSeconds
            and not (sale.auctionID and resolvedAuctions[sale.auctionID]) then
            estimateFromListing(sale)
        end
        if age <= pendingSeconds then
            kept[#kept + 1] = sale
        end
    end
    pending = kept
    for group in pairs(changedGroups) do refreshGroup(group) end
    changedGroups = {}
end

local function schedule()
    if scheduled then return end
    scheduled = true
    C_Timer.After(0, settle)
end

local function publish(batch)
    if batch.published then return end
    batch.published = true
    if activeBatch == batch then activeBatch = nil end
    settle()
    local color = ChatTypeInfo.SYSTEM
    for _, group in ipairs(batch.groups) do
        group.message = groupText(group)
        chat:AddMessage(group.message, color.r, color.g, color.b, color.id, nil, nil, group)
    end
end

local function queueSale(sale)
    local batch = activeBatch
    if batch and sale.time >= batch.deadline then
        local finished = batch
        C_Timer.After(0, function() publish(finished) end)
        batch = nil
    end
    if not batch then
        batch = {deadline = sale.time + batchSeconds, groups = {}, byName = {}}
        activeBatch = batch
        local opened = batch
        C_Timer.After(batchSeconds, function() publish(opened) end)
    end
    local group = batch.byName[sale.name]
    if not group then
        group = {item = sale.item, sales = {}}
        batch.byName[sale.name] = group
        batch.groups[#batch.groups + 1] = group
    end
    group.sales[#group.sales + 1] = sale
    sale.group = group
end

local function addMessage(frame, message, _, _, _, chatType)
    if not readable(chatType, "number") or chatType ~= ChatTypeInfo.SYSTEM.id
        or not readable(message, "string") then return end
    local item = message:match(pattern)
    if not item then return end

    local last = frame:GetNumMessages()
    local latest, _, _, _, latestType = frame:GetMessageInfo(last)
    if not readable(latest, "string") or latest ~= message
        or not readable(latestType, "number") or latestType ~= chatType then return end

    -- RemoveIf visits the history from oldest to newest, including after the buffer wraps.
    local index, removed = 0, false
    frame:RemoveMessagesByPredicate(function(text, _, _, _, messageType)
        index = index + 1
        removed = index == last and readable(text, "string") and text == message
            and readable(messageType, "number") and messageType == chatType
        return removed
    end)
    if not removed then return end

    local name = itemName(item)
    local sale = { item = item, name = name, time = GetTime(), payoutAt = serverTime() + payoutSeconds }
    if type(GetGameTime) == "function" then
        local hour, minute = GetGameTime()
        if nonnegative(hour) and nonnegative(minute) then sale.eta = (hour * 60 + minute + 60) % 1440 end
    end
    queueSale(sale)
    local lines = newLines[name] or {}
    newLines[name] = lines
    lines[#lines + 1] = sale
    pending[#pending + 1] = sale
    if auctionOpen then
        queryNeeded = true
        requestOwnedAuctions()
    end
    schedule()
end

local function observe(previous, count, readRow, mail)
    if not readable(count, "number") or count < 0 then return previous end
    local rows = {}
    for index = 1, count do
        local name, quantity, copper, eta, receivedAt, freshMail = readRow(index)
        if readable(name, "string") and nonnegative(copper) and (mail or positive(quantity)) then
            quantity = positive(quantity) and quantity or nil
            local key = table.concat({name, quantity or 0, copper}, "\031")
            local seen = (rows[key] or 0) + 1
            rows[key] = seen
            local receipt = {name = name, quantity = quantity, copper = copper, time = GetTime(), mail = mail,
                eta = eta, receivedAt = receivedAt}
            if eta or receivedAt then delayedInvoices[#delayedInvoices + 1] = receipt end
            if previous and (not mail or freshMail) and seen > (previous[key] or 0) then
                if receipts[name] ~= nil then
                    receipts[name] = false
                else
                    receipts[name] = receipt
                end
            end
        end
    end
    -- Keep previously observed multiplicities across refreshes, including empty or
    -- incomplete intermediate results that can temporarily hide existing receipts.
    for key, seen in pairs(previous or {}) do rows[key] = math.max(seen, rows[key] or 0) end
    if previous or #delayedInvoices > 0 then schedule() end
    return rows
end

local function legacyRow(index)
    local name, _, quantity, _, _, _, _, _, _, _, bid, _, _, _, _, status = GetAuctionItemInfo("owner", index)
    if readable(status, "number") and status == 1 then return name, quantity, bid end
end

local function mailRow(index)
    local invoice, name, _, bid, _, deposit, cut, _, hour, minute, quantity = GetInboxInvoiceInfo(index)
    if not readable(invoice, "string") then return end
    local payout
    if nonnegative(bid) and nonnegative(deposit) and nonnegative(cut) then payout = bid + deposit - cut end
    if invoice == "seller_temp_invoice" then
        local eta = nonnegative(hour) and nonnegative(minute) and hour < 24 and minute < 60 and hour * 60 + minute
        return name, quantity, payout, eta or nil, nil, true
    elseif invoice == "seller" then
        local receivedAt
        if type(GetInboxHeaderInfo) == "function" then
            local _, _, _, _, moneyAttached, _, daysLeft = GetInboxHeaderInfo(index)
            if positive(moneyAttached) then payout = moneyAttached end
            -- Seller mail has a 30-day expiry. Match its arrival to the sale's payout time.
            if readable(daysLeft, "number") and daysLeft > 29 and daysLeft <= 30 then
                local age = (30 - daysLeft) * 86400
                if age <= pendingSeconds then receivedAt = serverTime() - age end
            end
        end
        return name, quantity, payout, nil, receivedAt
    end
end

local function onEvent(_, event, notification, item, auctionID)
    if event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION" then
        local sold = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold
        if not sold or not readable(notification, "number") or notification ~= sold
            or not readable(item, "string") then return end
        local name = itemName(item)
        local ids = notifications[name] or {}
        notifications[name] = ids
        ids[#ids + 1] = positive(auctionID) and auctionID or false
        schedule()
    elseif event == "OWNED_AUCTIONS_UPDATED" then
        if auctionOpen and cacheOwnedAuctions() then queryNeeded = false end
        if #pending > 0 then schedule() end
    elseif event == "AUCTION_HOUSE_SHOW" then
        auctionOpen, legacyRows, queryNeeded = true, nil, true
        requestOwnedAuctions()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        auctionOpen, legacyRows, queryNeeded = false, nil, false
    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" or event == "AUCTION_MULTISELL_UPDATE"
        or event == "AUCTION_CANCELED" or event == "AUCTION_HOUSE_NEW_BID_RECEIVED" then
        queryNeeded = true
        requestOwnedAuctions()
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        requestOwnedAuctions()
    elseif event == "AUCTION_OWNED_LIST_UPDATE" and auctionOpen then
        queryNeeded = false
        cacheLegacyAuctions()
        legacyRows = observe(legacyRows, GetNumAuctionItems("owner"), legacyRow)
    elseif event == "MAIL_SHOW" then
        mailOpen, mailRows = true, nil
    elseif event == "MAIL_CLOSED" then
        mailOpen, mailRows = false, nil
    elseif event == "MAIL_INBOX_UPDATE" and mailOpen then
        delayedInvoices = {}
        mailRows = observe(mailRows, GetInboxNumItems(), mailRow, true)
    end
end

local function start()
    chat = DEFAULT_CHAT_FRAME
    local template = ERR_AUCTION_SOLD_S
    if not chat or type(chat.TransformMessages) ~= "function" or type(chat.RemoveMessagesByPredicate) ~= "function"
        or type(hooksecurefunc) ~= "function"
        or not C_Timer or not ChatTypeInfo or not ChatTypeInfo.SYSTEM or type(template) ~= "string" then return end
    local first, last = template:find("%%s")
    if not first then first, last = template:find("%%1%$s") end
    if not first then return end
    pattern = "^" .. escape(template:sub(1, first - 1)) .. "(.+)" .. escape(template:sub(last + 1)) .. "$"

    hooksecurefunc(chat, "AddMessage", addMessage)
    local events = CreateFrame("Frame")
    events:SetScript("OnEvent", onEvent)
    -- Clients can share API declarations while emitting different Auction House events.
    pcall(events.RegisterEvent, events, "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION")
    legacyAH = type(GetNumAuctionItems) == "function" and type(GetAuctionItemInfo) == "function"
        and (not C_AuctionHouse or type(C_AuctionHouse.GetOwnedAuctions) ~= "function"
            or type(IsUsingLegacyAuctionClient) == "function" and IsUsingLegacyAuctionClient())
    modernAH = not legacyAH and C_AuctionHouse and type(C_AuctionHouse.GetOwnedAuctions) == "function"
    if modernAH or legacyAH then
        events:RegisterEvent("AUCTION_HOUSE_SHOW")
        events:RegisterEvent("AUCTION_HOUSE_CLOSED")
    end
    if modernAH then
        pcall(events.RegisterEvent, events, "OWNED_AUCTIONS_UPDATED")
        pcall(events.RegisterEvent, events, "AUCTION_HOUSE_AUCTION_CREATED")
        pcall(events.RegisterEvent, events, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        pcall(events.RegisterEvent, events, "AUCTION_CANCELED")
        pcall(events.RegisterEvent, events, "AUCTION_HOUSE_NEW_BID_RECEIVED")
    elseif legacyAH then
        pcall(events.RegisterEvent, events, "AUCTION_OWNED_LIST_UPDATE")
        pcall(events.RegisterEvent, events, "AUCTION_MULTISELL_UPDATE")
    end
    if type(GetInboxNumItems) == "function" and type(GetInboxInvoiceInfo) == "function" then
        events:RegisterEvent("MAIL_SHOW")
        events:RegisterEvent("MAIL_CLOSED")
        events:RegisterEvent("MAIL_INBOX_UPDATE")
    end
end

start()
