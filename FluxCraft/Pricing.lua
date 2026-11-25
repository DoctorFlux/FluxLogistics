local addonName, FluxCraft = ...
if type(FluxCraft) ~= "table" then
    FluxCraft = _G.FluxCraft or {}
    _G.FluxCraft = FluxCraft
end

local Pricing = {}
FluxCraft.Pricing = Pricing
local standardAuctionMarket = {cutRate = 0.05, depositRefundable = true}

local function validAmount(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

local function validSaleQuote(quote, itemID)
    if type(quote) ~= "table" or quote.stale or quote.valid == false then return false end
    if quote.itemID and tostring(quote.itemID) ~= tostring(itemID) then return false end
    if quote.unit and quote.unit ~= "item" then return false end
    if quote.itemLink and quote.variantExact == false then return false end
    return validAmount(quote.unitPrice)
end

local function projectProfit(projection, cost)
    if not validAmount(cost) then return end
    local proceeds = projection.estimatedNetSaleProceeds
    projection.estimatedProfit = proceeds - cost
    if cost > 0 then projection.profitOnCostPercent = 100 * projection.estimatedProfit / cost end
    if proceeds > 0 then projection.salesMarginPercent = 100 * projection.estimatedProfit / proceeds end
end

function Pricing.OutputUnitCost(summary)
    local output = summary and summary.output
    if validAmount(output) and output > 0 and summary.valueKnown ~= false and validAmount(summary.fullValue) then
        return summary.fullValue / output
    end
end

local function plannedSaleQuantity(summary)
    local output = summary and summary.output
    local requested = summary and summary.requested or output
    if validAmount(output) and validAmount(requested) then return math.min(output, requested) end
    return 0
end

function Pricing.AcceptedJobProjection(job)
    local gross = job and job.projection and job.projection.estimatedGrossSaleProceeds
    if not validAmount(gross) then return nil end
    local summary = job.summary
    local cost = summary and summary.valueKnown ~= false and summary.fullValue or nil
    local sale = job.projection.saleAssumptions or {}
    local quantity = sale.quantity
    if not validAmount(quantity) or quantity == 0 then quantity = plannedSaleQuantity(summary) end
    local projection = {
        manufacturingEstimate = cost,
        estimatedGrossSaleProceeds = gross,
        estimatedGrossSaleUnitPrice = quantity > 0 and gross / quantity or nil,
        estimatedNetSaleProceeds = gross * (1 - standardAuctionMarket.cutRate),
        saleAssumptions = {
            cutRate = standardAuctionMarket.cutRate, quantity = quantity > 0 and quantity or nil,
            source = sale.source, age = sale.age, ageUnit = sale.ageUnit,
        },
    }
    projectProfit(projection, cost)
    return projection
end

-- This is an estimate over the exact planner revision supplied by the caller.
-- A cached market quote does not establish sale availability or realized gain.
function Pricing.Project(plan, options)
    options = options or {}
    local summary = plan and plan.summary or {}
    local projection = {
        revision = plan and plan.revision,
        basis = summary.valuationBasis,
        manufacturingEstimate = summary.fullValue,
        costPerOutput = Pricing.OutputUnitCost(summary),
        additionalCash = summary.additionalCash,
        ownedInputValue = summary.ownedValue,
        estimateStatus = summary.valueKnown == false and "unknown" or "estimated",
        comparisonStatus = summary.optimality or "incomplete",
        realizedCost = nil,
        realizedProfit = nil,
    }
    if summary.fullValue and summary.executions and summary.executions > 0 then
        projection.costPerExecution = summary.fullValue / summary.executions
    end

    local quote = options.saleQuote
    local market = options.market or standardAuctionMarket
    local saleUnits = plannedSaleQuantity(summary)
    local gross = saleUnits > 0 and validSaleQuote(quote, plan and plan.rootItemID) and quote.unitPrice * saleUnits
    if gross then
        projection.estimatedGrossSaleProceeds = gross
        projection.estimatedGrossSaleUnitPrice = quote.unitPrice
        if summary.fullValue then projection.estimatedGrossProfit = gross - summary.fullValue end
    end
    if gross and type(market) == "table"
        and validAmount(market.cutRate) and market.cutRate <= 1
        and validAmount(market.flatFee or 0)
        and (market.depositRefundable ~= false or validAmount(market.deposit)) then
        local lostDeposit = market.depositRefundable == false and market.deposit or 0
        if validAmount(lostDeposit) then
            projection.estimatedNetSaleProceeds = gross * (1 - market.cutRate)
                - (market.flatFee or 0) - lostDeposit
            projection.saleAssumptions = {
                source = quote.source, estimate = quote.estimate ~= false,
                provider = quote.provider, itemLink = quote.itemLink or quote.requestedItemLink,
                variantKey = quote.variantKey, variantExact = quote.variantExact,
                age = quote.age, ageUnit = quote.ageUnit, ageUnknown = quote.ageUnknown, marketContext = quote.marketContext,
                userMarketContext = market.context,
                userFeeEstimate = market.userEstimate == true,
                cutRate = market.cutRate, flatFee = market.flatFee or 0,
                refundableDeposit = market.depositRefundable ~= false and market.deposit or nil,
                depositKnown = validAmount(market.deposit),
                lostDeposit = lostDeposit,
                quantity = saleUnits,
            }
            projectProfit(projection, summary.fullValue)
            if summary.ownedAuctionValue and summary.additionalCash then
                -- Matching starting stock. The sell route values only physical
                -- inputs allocated to this plan and never purchases new ones.
                local liquidation = summary.ownedAuctionValue * (1 - market.cutRate)
                if (summary.ownedUnits or 0) > 0 then
                    liquidation = liquidation - (market.flatFee or 0) - lostDeposit
                end
                projection.liquidationEstimate = liquidation
                projection.sellOrCraftDifference = projection.estimatedNetSaleProceeds
                    - summary.additionalCash - liquidation
            end
        end
    end

    local actual = options.actual
    if type(actual) == "table" and actual.complete == true
        and validAmount(actual.inputCost) and validAmount(actual.netProceeds) then
        projection.realizedCost = actual.inputCost
        projection.realizedProfit = actual.netProceeds - actual.inputCost
    end
    return projection
end

function Pricing.MaterialUnitPrice(node)
    if not node or not validAmount(node.fullValue) or node.fullValue == 0 then return nil end
    local units, components = 0, 0
    local isUnitPriceAverage = false
    local function add(quantity)
        if not validAmount(quantity) or quantity < 1 or quantity % 1 ~= 0 then return false end
        units, components = units + quantity, components + 1
        return true
    end
    if node.ownedUsed and node.ownedUsed > 0 and not add(node.ownedUsed) then return nil end
    local purchases = node.purchases or {}
    for _, purchase in ipairs(purchases) do
        if not add(purchase.purchased) then return nil end
        if type(purchase.quote) == "table" and purchase.quote.isUnitPriceAverage then isUnitPriceAverage = true end
    end
    if #purchases == 0 and (node.buy or 0) > 0 and not add(node.purchased) then return nil end
    local crafts = node.crafts or {}
    for _, craft in ipairs(crafts) do
        if not add(craft.outputQuantity) then return nil end
    end
    if #crafts == 0 and (node.craftCount or 0) > 0 then return nil end
    if units > 0 then return node.fullValue / units, isUnitPriceAverage or components > 1 end
end

-- Current gold prices come from the qualified offers in the preview.
-- The owner's remembered and catalog terms are useful for display only.
function Pricing.GetVendorPrice(itemID, acquisitions)
    local best
    for _, offer in ipairs(acquisitions and acquisitions[itemID] or {}) do
        if offer.kind == "vendor" and offer.qualified == true and offer.itemID == itemID
            and offer.unit == "item" and validAmount(offer.bundlePrice) and offer.bundlePrice > 0
            and type(offer.bundleSize) == "number" and offer.bundleSize >= 1 then
            local unitPrice = offer.bundlePrice / offer.bundleSize
            if not best or unitPrice < best.unitPrice then
                best = {unitPrice = unitPrice, bundlePrice = offer.bundlePrice, bundleSize = offer.bundleSize}
            end
        end
    end
    if best then return best end
    local owner = Flux and Flux.RestockPolicy
    if owner and owner.version == 1 and owner.GetVendorPriceEstimate then
        return owner.GetVendorPriceEstimate(itemID)
    end
end

function Pricing.FormatVendor(quote)
    if not quote then return nil end
    local L = FluxCraft.L
    if quote.bundleSize and quote.bundleSize > 1 and quote.bundlePrice then
        local format = quote.estimate and L.vendorEstimateBundle or L.vendorLiveBundle
        return format:format(quote.bundleSize, Pricing.FormatCopper(quote.bundlePrice))
    end
    local format = quote.estimate and L.vendorEstimateUnit or L.vendorLiveUnit
    return format:format(Pricing.FormatCopper(quote.unitPrice))
end

-- Currency formatting belongs at the display boundary; never round a node's
-- unit value before summing a manufacturing route.
function Pricing.FormatCopper(amount)
    if type(amount) ~= "number" or not validAmount(math.abs(amount)) then return "?" end
    local rounded = math.floor(math.abs(amount) + 0.5)
    local sign = amount < 0 and rounded > 0 and "-" or ""
    local formatCoins = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString or GetCoinTextureString
    if type(formatCoins) == "function" then
        local icons = formatCoins(rounded, 10)
        if type(icons) == "string" and icons ~= "" then return sign .. icons end
    end
    local gold = math.floor(rounded / 10000)
    local silver = math.floor((rounded % 10000) / 100)
    local copper = rounded % 100
    return string.format("%s%dg %ds %dc", sign, gold, silver, copper)
end

local profitCoins = {
    {10000, "Gold"}, {100, "Silver"}, {1, "Copper"},
}

local function profitColor(amount)
    return amount == 0 and "c6c6c6" or amount < 0 and "ff5555" or "55ff70"
end

function Pricing.FormatProfitPercent(percent)
    if type(percent) ~= "number" or not validAmount(math.abs(percent)) then return nil end
    local rounded = math.floor(math.abs(percent) + 0.5)
    if rounded == 0 then return "|cffc6c6c60%|r" end
    local sign = percent < 0 and "-" or "+"
    return ("|cff%s%s%.0f%%|r"):format(profitColor(percent), sign, rounded)
end

function Pricing.FormatProfit(amount)
    if type(amount) ~= "number" or not validAmount(math.abs(amount)) then return "?" end
    local remaining = math.floor(math.abs(amount) + 0.5)
    local color = profitColor(remaining > 0 and amount or 0)
    local sign = remaining == 0 and "" or amount < 0 and "-" or "+"
    local parts = {}
    for _, coin in ipairs(profitCoins) do
        local units = math.floor(remaining / coin[1])
        if units > 0 or coin[1] == 1 and #parts == 0 then
            parts[#parts + 1] = ("|cff%s%s%d|r|TInterface\\MoneyFrame\\UI-%sIcon:9:9|t")
                :format(color, sign, units, coin[2])
            remaining, sign = remaining % coin[1], ""
        end
    end
    return table.concat(parts, " ")
end

return Pricing
