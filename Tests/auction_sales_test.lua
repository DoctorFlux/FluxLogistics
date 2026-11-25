local saleTemplate = "A buyer has been found for your auction of %s."
local unpackValues = table.unpack or unpack

local function fixture(client, legacy, savedListings)
    local state = {messages = {}, events = {}, timers = {}, owned = {}, inbox = {}, secrets = {}, now = 10000}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.FluxLogisticsAuctionSalesDB = savedListings
    env.ERR_AUCTION_SOLD_S = saleTemplate
    env.AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
    env.ChatTypeInfo = {SYSTEM = {r = 1, g = 1, b = 0, id = 7}}
    env.Enum = {AuctionHouseNotification = {AuctionSold = 4}, AuctionStatus = {Active = 0, Sold = 1}}
    env.issecretvalue = function(value) return state.secrets[value] == true end
    env.canaccessvalue = function(value) return not env.issecretvalue(value) end
    env.GetTime = function() return state.now end
    env.GetServerTime = function() return math.floor(state.now) end
    env.time = env.GetServerTime
    env.GetGameTime = function()
        return math.floor(state.now / 3600) % 24, math.floor(state.now / 60) % 60
    end
    env.C_Timer = {After = function(seconds, callback)
        state.timers[#state.timers + 1] = {due = state.now + seconds, callback = callback}
    end}
    env.C_EventUtils = {IsEventValid = function() return true end}
    env.IsUsingLegacyAuctionClient = function() return legacy end
    env.Flux = {Cap = {HasLegacyAuctionHouse = env.IsUsingLegacyAuctionClient, hasLegacyAuctionHouse = legacy}}
    env.IsLoggedIn = function() return true end
    env.CreateFrame = function()
        local frame = {registered = {}}
        function frame:RegisterEvent(event) self.registered[event] = true end
        function frame:UnregisterEvent(event) self.registered[event] = nil end
        function frame:SetScript(script, callback) self[script] = callback end
        state.events[#state.events + 1] = frame
        return frame
    end

    local function money(copper) return ("amount(%d)"):format(copper) end
    env.GetMoneyString, env.GetCoinTextureString = money, money
    env.C_CurrencyInfo = {GetCoinTextureString = money}
    local function ownedItem(itemID)
        for _, auction in ipairs(state.owned) do
            if auction.itemKey.itemID == itemID then return auction end
        end
    end
    env.GetItemInfo = function(item)
        if type(item) == "string" then return item:match("%[(.-)%]") end
        local auction = ownedItem(item)
        if auction then return auction.name end
    end
    env.C_Item = {GetItemInfo = env.GetItemInfo}
    env.C_AuctionHouse = {
        GetOwnedAuctions = function() return state.owned end,
        GetOwnedAuctionInfo = function(index) return state.owned[index] end,
        GetNumOwnedAuctions = function() return #state.owned end,
        HasFullOwnedAuctionResults = function() return true end,
        QueryOwnedAuctions = function(sorts)
            assert(state.auctionVisible and type(sorts) == "table", "queried owned auctions outside the Auction House")
        end,
        GetItemKeyInfo = function(key)
            local auction = ownedItem(key.itemID)
            if auction then return {itemName = auction.name, isCommodity = auction.commodity == true} end
        end,
    }
    env.AuctionHouseFrame = {IsShown = function() return state.auctionVisible end}
    env.GetNumAuctionItems = function(kind)
        assert(kind == "owner")
        return #state.owned, #state.owned
    end
    env.GetAuctionItemInfo = function(kind, index)
        assert(kind == "owner")
        local row = state.owned[index]
        return row.name, 0, row.quantity, 1, true, 0, "", 0, 0, row.buyoutAmount,
            row.bidAmount, "Buyer", "Buyer-Realm", "Seller", "Seller-Realm", row.status, row.itemKey.itemID
    end
    env.GetAuctionItemLink = function(_, index) return state.owned[index].itemLink end
    env.GetAuctionItemTimeLeft = function() return 3000 end
    env.GetInboxNumItems = function() return #state.inbox, #state.inbox end
    env.GetInboxHeaderInfo = function(index)
        local invoice = state.inbox[index]
        local attachedMoney = invoice.attachedMoney or (invoice.kind == "seller_temp_invoice" and 0
            or invoice.total + (invoice.deposit or 0) - (invoice.cut or 0))
        return 0, 0, "Auction House", env.AUCTION_SOLD_MAIL_SUBJECT:format(invoice.name),
            attachedMoney, 0, invoice.daysLeft or 30, 0, false, false, true, false, false
    end
    env.GetInboxInvoiceInfo = function(index)
        local invoice = state.inbox[index]
        local eta = invoice.eta
        local hour, minute
        if eta then hour, minute = math.floor(eta / 60), eta % 60 end
        return invoice.kind or "seller", invoice.name, "Buyer", invoice.total, invoice.total,
            invoice.deposit or 0, invoice.cut or 0, 0, hour, minute, invoice.quantity, false
    end

    local chat = {}
    function chat:AddMessage(...)
        state.messages[#state.messages + 1] = table.pack(...)
    end
    function chat:GetNumMessages() return #state.messages end
    function chat:GetMessageInfo(index)
        local message = state.messages[index]
        if message then return unpackValues(message, 1, message.n) end
    end
    function chat:TransformMessages(predicate, transform)
        for index, message in ipairs(state.messages) do
            if predicate(unpackValues(message, 1, message.n)) then
                state.messages[index] = table.pack(transform(unpackValues(message, 1, message.n)))
            end
        end
    end
    function chat:RemoveMessagesByPredicate(predicate)
        local remaining = {}
        for _, message in ipairs(state.messages) do
            if not predicate(unpackValues(message, 1, message.n)) then
                remaining[#remaining + 1] = message
            end
        end
        state.messages = remaining
    end
    env.DEFAULT_CHAT_FRAME = chat
    env.CHAT_FRAMES = {"ChatFrame1"}
    env.ChatFrame1 = chat
    env.hooksecurefunc = function(owner, method, callback)
        local original = assert(owner[method])
        owner[method] = function(...)
            original(...)
            callback(...)
        end
    end

    function state:emit(event, ...)
        if event == "AUCTION_HOUSE_SHOW" then self.auctionVisible = true end
        if event == "AUCTION_HOUSE_CLOSED" then self.auctionVisible = false end
        for _, frame in ipairs(self.events) do
            if frame.registered[event] then frame:OnEvent(event, ...) end
        end
    end
    function state:advance(seconds)
        local untilTime, passes = self.now + seconds, 0
        while true do
            local nextIndex, nextTime
            for index, timer in ipairs(self.timers) do
                if timer.due <= untilTime and (not nextTime or timer.due < nextTime) then
                    nextIndex, nextTime = index, timer.due
                end
            end
            if not nextIndex then break end
            passes = passes + 1
            assert(passes < 100, "auction sales did not settle")
            self.now = math.max(self.now, nextTime)
            table.remove(self.timers, nextIndex).callback()
        end
        self.now = untilTime
    end
    function state:flush() self:advance(0) end
    function state:chat(text, chatType)
        chat:AddMessage(text, 1, 1, 0, chatType or 7, nil, "metadata")
    end
    function state:savedListings() return env.FluxLogisticsAuctionSalesDB end
    function state:notice(item, id, chatFirst)
        local text = saleTemplate:format(item)
        if chatFirst then self:chat(text) end
        self:emit("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", env.Enum.AuctionHouseNotification.AuctionSold, item, id)
        if not chatFirst then self:chat(text) end
    end

    local addon = {target = client, state = {ready = true, char = {}}, L = {}, Pricing = {FormatCopper = money}}
    function addon:On(event, callback)
        if event == "READY" then callback(self) end
    end
    assert(loadfile("FluxCraft/Locale.lua", "t", env))("FluxLogistics", addon)
    assert(loadfile("FluxCraft/AuctionSales.lua", "t", env))("FluxLogistics", addon)
    state:emit("ADDON_LOADED", "FluxLogistics")
    state:emit("PLAYER_LOGIN")
    return state
end

local function row(id, name, quantity, total)
    return {
        auctionID = id, name = name, itemKey = {itemID = id}, itemLink = "|Hitem:" .. id .. "|h[" .. name .. "]|h",
        quantity = quantity, status = 1, bidAmount = total, buyoutAmount = total,
    }
end

local function assertSale(message, name, quantity, total, estimated, unit)
    assert(message, "missing sale summary for " .. name)
    local text = message[1]
    local totalText = "amount(" .. total .. ")"
    assert(text:find(name, 1, true), text)
    assert(text:find(totalText, 1, true), text)
    assert(text:find("×" .. quantity, 1, true) or text:find(quantity .. "×", 1, true), text)
    if unit then assert(text:find("amount(" .. unit .. ")", 1, true), text) end
    assert(not text:find("A buyer has been found", 1, true), text)
    assert((text:find("~" .. totalText, 1, true) ~= nil) == (estimated == true), text)
    assert(message[2] == 1 and message[3] == 1 and message[4] == 0 and message[5] == 7,
        "sale summary did not preserve system chat styling")
end

for _, client in ipairs({"retail", "forever"}) do
    local sales = fixture(client, false)
    local bidSale = row(41, "Red Mageweave Bag", 1, 12999)
    bidSale.buyoutAmount = 20000
    local buyoutSale = row(42, "Red Mageweave Bag", 5, 43002)
    buyoutSale.bidAmount = nil
    sales.owned = {bidSale, buyoutSale}
    sales:notice("Red Mageweave Bag", 41, false)
    sales:advance(20)
    assert(#sales.messages == 0, "individual sale lines remained visible during the batch")
    sales:notice("Red Mageweave Bag", 42, true)

    local unrelated = "Auction created."
    local secret = saleTemplate:format("Protected Chat Text")
    local playerMessage = saleTemplate:format("Player Chat Text")
    sales.secrets[secret] = true
    sales:chat(unrelated)
    sales:chat(secret)
    sales:chat(playerMessage, 16)
    local active = row(43, "Runecloth", 200, 88888)
    active.status = 0
    sales.owned[3] = active
    sales:notice("Runecloth", 43, true)
    sales:flush()
    assert(#sales.messages == 3 and sales.messages[1][1] == unrelated and sales.messages[2][1] == secret
        and sales.messages[3][1] == playerMessage, "batching affected unrelated or restricted chat")
    assert(sales.messages[1][7] == "metadata" and sales.messages[3][5] == 16)

    -- Only 12 of the 200 units sold. The owned list may arrive after the chat event.
    sales.owned[3] = row(43, "Runecloth", 12, 5330)
    sales:emit("OWNED_AUCTIONS_UPDATED")
    sales:emit("OWNED_AUCTIONS_UPDATED")
    sales:flush()
    sales:advance(39)
    assert(#sales.messages == 3, "sale summaries appeared before 60 seconds")
    sales:advance(1)
    assert(#sales.messages == 5, "each distinct item should produce one sale summary")
    assertSale(sales.messages[4], "Red Mageweave Bag", 6, 53202, true, 8867)
    assert(sales.messages[4][1]:find("avg/ea", 1, true), "the weighted average is not labeled")
    assertSale(sales.messages[5], "Runecloth", 12, 5064, true, 422)

    sales:notice("Runecloth", 43, true)
    sales.owned[4] = row(44, "Red Mageweave Bag", 1, 12000)
    sales:notice("Red Mageweave Bag", 44, true)
    sales:advance(59)
    assert(#sales.messages == 5, "the next sale did not start its own 60-second window")
    sales:advance(1)
    assert(#sales.messages == 7, "the next sale summary window added the wrong number of lines")
    assert(sales.messages[6][1]:find("payout pending", 1, true), "a second notice reused a settled sale's amount")
    assertSale(sales.messages[7], "Red Mageweave Bag", 1, 11400, true)
end

for _, client in ipairs({"classic", "anniversary", "era"}) do
    local sales = fixture(client, true)
    sales.owned = {row(50, "Linen Cloth", 20, 25000)}
    sales:emit("AUCTION_OWNED_LIST_UPDATE")
    sales:notice("Linen Cloth", nil, true)
    sales:flush()
    assert(#sales.messages == 0, "a legacy sale bypassed batching")

    sales.inbox = {{name = "Linen Cloth", quantity = 20, total = 25000, daysLeft = 29.5}}
    sales:emit("MAIL_SHOW")
    sales:emit("MAIL_INBOX_UPDATE")
    sales:flush()
    sales:notice("Wool Cloth", nil, false)
    local payoutMinute = (math.floor(sales.now / 60) + 60) % 1440
    sales.inbox[2] = {kind = "seller_temp_invoice", name = "Wool Cloth", quantity = 16,
        total = 14000, deposit = 500, cut = 680, eta = payoutMinute}
    sales:emit("MAIL_INBOX_UPDATE")
    sales:flush()

    sales:emit("AUCTION_HOUSE_SHOW")
    sales:emit("AUCTION_OWNED_LIST_UPDATE")
    sales:flush()
    sales:notice("Silk Cloth", nil, true)
    sales.owned[2] = row(51, "Silk Cloth", 10, 15000)
    sales:emit("AUCTION_OWNED_LIST_UPDATE")
    sales:advance(60)
    assert(#sales.messages == 3, "each legacy sale item should have one summary")
    local fallback = sales.messages[1][1]
    assert(fallback:find("Linen Cloth", 1, true) and fallback:find("payout pending", 1, true),
        "accepted an old same-name invoice or stale listing")
    assertSale(sales.messages[2], "Wool Cloth", 16, 13820, false, 864)
    assert(sales.messages[2][1]:find("~amount(864) avg/ea", 1, true),
        "an exact payout with a fractional unit price should mark only the average as rounded")
    assertSale(sales.messages[3], "Silk Cloth", 10, 14250, true, 1425)
end

do
    local sales = fixture("forever", false)
    sales:notice("Runecloth", nil, true)
    sales:advance(75 * 60)
    sales.inbox = {{name = "Runecloth", quantity = 12, total = 24750, deposit = 290, cut = 1250,
        attachedMoney = 23780, daysLeft = 30 - 15 * 60 / 86400}}
    sales:emit("MAIL_SHOW")
    sales:emit("MAIL_INBOX_UPDATE")
    sales:flush()
    assert(#sales.messages == 1, "delivered sale proceeds should update the original line")
    assertSale(sales.messages[1], "Runecloth", 12, 23780)
end

do
    local sales = fixture("forever", false)
    sales.now = 23 * 3600 + 42 * 60 + 28
    local payoutMinute = (math.floor(sales.now / 60) + 60) % 1440
    sales:notice("Mageweave Cloth", nil, true)
    sales:notice("Runecloth", nil, true)
    sales:advance(3 * 60)
    assert(not sales.messages[1][1]:find("amount(", 1, true))

    sales.inbox = {
        {kind = "seller_temp_invoice", name = "Mageweave Cloth", quantity = 7, total = 40000,
            deposit = 270, cut = 1950, eta = payoutMinute},
        {kind = "seller_temp_invoice", name = "Mageweave Cloth", quantity = 9, total = 35000,
            deposit = 130, cut = 1750, eta = (payoutMinute - 22) % 1440},
        {kind = "seller_temp_invoice", name = "Runecloth", quantity = 12, total = 24750,
            deposit = 290, cut = 1250, eta = (payoutMinute - 15) % 1440},
    }
    sales:emit("MAIL_SHOW")
    sales:emit("MAIL_INBOX_UPDATE")
    sales:emit("MAIL_INBOX_UPDATE")
    sales:flush()
    assert(#sales.messages == 2, "the first mailbox visit should update the existing sale line")
    assertSale(sales.messages[1], "Mageweave Cloth", 7, 38320)
    assert(not sales.messages[2][1]:find("amount(", 1, true), "matched an invoice from a different sale time")
end

do
    local sales = fixture("forever", false)
    local single = row(61, "Red Mageweave Bag", 1, 11000)
    single.status, single.bidAmount = 0, nil
    local stack = row(62, "Silk Cloth", 20, 1100)
    stack.status, stack.bidAmount, stack.commodity = 0, nil, true
    sales.owned = {single, stack}
    sales:emit("AUCTION_HOUSE_SHOW")
    sales:emit("OWNED_AUCTIONS_UPDATED")
    sales:flush()
    sales:emit("AUCTION_HOUSE_CLOSED")
    sales = fixture("forever", false, sales:savedListings())

    local payoutMinute = (math.floor(sales.now / 60) + 60) % 1440
    sales:notice("Red Mageweave Bag", nil, true)
    sales:notice("Silk Cloth", nil, true)
    sales:advance(60)
    assertSale(sales.messages[1], "Red Mageweave Bag", 1, 10450, true)
    local partial = sales.messages[2][1]
    assert(partial:find("Silk Cloth", 1, true) and partial:find("amount(20900)", 1, true), partial)
    assert(partial:find("≤", 1, true) or partial:find("up to", 1, true), partial)
    assert(not partial:find("×", 1, true), "a cached listing amount must not become a sold quantity")

    sales:advance(3 * 60)
    sales.inbox = {{kind = "seller_temp_invoice", name = "Red Mageweave Bag", quantity = 1,
        total = 11000, deposit = 125, cut = 530, eta = payoutMinute}}
    sales:emit("MAIL_SHOW")
    sales:emit("MAIL_INBOX_UPDATE")
    sales:flush()
    assert(#sales.messages == 2, "an invoice should replace the listing estimate in place")
    assertSale(sales.messages[1], "Red Mageweave Bag", 1, 10595)
end

do
    local sales = fixture("forever", false)
    local first = row(71, "Woolen Bag", 1, 3600)
    local second = row(72, "Woolen Bag", 1, 3600)
    first.status, first.bidAmount = 0, nil
    second.status, second.bidAmount = 0, nil
    sales.owned = {first, second}
    sales:emit("AUCTION_HOUSE_SHOW")
    sales:emit("OWNED_AUCTIONS_UPDATED")
    sales:flush()
    sales:emit("AUCTION_HOUSE_CLOSED")
    sales.owned = {}

    for _ = 1, 2 do sales:notice("Woolen Bag", nil, true) end
    sales:advance(60)
    assert(#sales.messages == 1, "equal-price sales without IDs did not combine")
    assertSale(sales.messages[1], "Woolen Bag", 2, 6840, true, 3420)

    sales:notice("Woolen Bag", nil, true)
    sales:advance(60)
    assert(#sales.messages == 2 and not sales.messages[2][1]:find("amount(", 1, true),
        "reused an exhausted listing estimate")
end

do
    local sales = fixture("forever", false)
    sales.owned = {row(80, "Iron Bar", 2, 7020)}
    sales:notice("Iron Bar", 80, true)
    sales:notice("Iron Bar", 81, false)
    sales:advance(60)
    assert(#sales.messages == 1, "partially known sales should still combine")
    local summary = sales.messages[1][1]
    assert(summary:find("Iron Bar", 1, true) and summary:find("amount(6669) so far", 1, true), summary)
end

do
    local sales = fixture("forever", false)
    sales.owned = {row(91, "Copper Ore", 5, 9000), row(92, "Copper Ore", 3, 6000)}
    sales:notice("Copper Ore", 91, true)
    sales:flush()

    -- The next sale can arrive in the frame that runs the overdue timer.
    sales.now = sales.now + 61
    sales:notice("Copper Ore", 92, true)
    sales:flush()
    assert(#sales.messages == 1, "an overdue timer swallowed the next window")
    assertSale(sales.messages[1], "Copper Ore", 5, 8550, true, 1710)
    sales:advance(60)
    assert(#sales.messages == 2, "the post-deadline sale did not get its own summary")
    assertSale(sales.messages[2], "Copper Ore", 3, 5700, true, 1900)
end

do
    local sales = fixture("forever", false)
    local oldLine = saleTemplate:format("Thorium Ore")
    sales.messages[1] = table.pack(oldLine, 1, 1, 0, 7)
    local payoutMinute = (math.floor(sales.now / 60) + 60) % 1440
    sales:notice("Thorium Ore", nil, true)
    sales:notice("Thorium Ore", nil, false)
    sales:advance(60)
    assert(#sales.messages == 2 and sales.messages[1][1] == oldLine,
        "suppressing the new stock messages modified an identical older line")

    sales.inbox = {{kind = "seller_temp_invoice", name = "Thorium Ore", quantity = 2, total = 4000,
        cut = 200, eta = payoutMinute}}
    sales:emit("MAIL_SHOW")
    sales:emit("MAIL_INBOX_UPDATE")
    sales:flush()
    assert(sales.messages[2][1]:find("payout pending", 1, true), "one invoice was assigned to two possible sales")
    sales.inbox[2] = {kind = "seller_temp_invoice", name = "Thorium Ore", quantity = 4, total = 10000,
        cut = 500, eta = payoutMinute}
    sales:emit("MAIL_INBOX_UPDATE")
    sales:flush()
    assert(#sales.messages == 2, "a complete set of invoices should update the existing summary")
    assertSale(sales.messages[2], "Thorium Ore", 6, 13300, false, nil)
    assert(sales.messages[2][1]:find("~amount(2217) avg/ea", 1, true), sales.messages[2][1])
end

print("auction sale chat fixtures passed")
