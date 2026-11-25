-- FluxCraft's only inventory source is FluxUI's selected inventory facade.
-- Counts used for crafting are carried-bag counts for the current character.
local _, ns = ...
ns = ns or {}

local Adapter = {}
ns.InventoryAdapter = Adapter

local listenerKey = "FluxCraft.Inventory"
local boundInventory
local onChange
local revision = 0
local sourceGeneration = 0
local lastSource

local function Inventory()
    local flux = rawget(_G, "Flux")
    return flux and flux.Inventory or nil
end

local function Status()
    local inv = Inventory()
    if not inv or type(inv.GetCount) ~= "function" then
        return { ready = false, reliable = false, source = "none", reason = "FluxUI inventory unavailable" }
    end
    local ready = type(inv.IsReady) == "function" and inv.IsReady() == true
    local reliable = ready and (type(inv.IsReliable) ~= "function" or inv.IsReliable() == true)
    local source = type(inv.GetSource) == "function" and inv.GetSource() or "none"
    local bagGeneration = type(inv.GetSnapshotGeneration) == "function"
        and (tonumber(inv.GetSnapshotGeneration("bags")) or 0) or 0
    return {
        ready = ready,
        reliable = reliable,
        source = source,
        bagGeneration = bagGeneration,
        sourceGeneration = sourceGeneration,
        revision = revision,
        reason = not ready and "FluxUI inventory initializing"
            or not reliable and "FluxUI inventory settling" or nil,
    }
end

function Adapter.GetStatus()
    return Status()
end

function Adapter.GetRevision()
    local status = Status()
    return tostring(status.source) .. ":" .. tostring(status.sourceGeneration)
        .. ":" .. tostring(status.bagGeneration) .. ":" .. tostring(status.revision)
end

local function HandleChange(ctx)
    local status = Status()
    if status.source ~= lastSource then
        lastSource = status.source
        sourceGeneration = sourceGeneration + 1
        status.sourceGeneration = sourceGeneration
        status.handover = true
    end
    revision = revision + 1
    status.revision = revision
    if type(onChange) == "function" then
        onChange(status, ctx)
    end
end

function Adapter.Start(callback)
    if callback ~= nil then
        onChange = callback
    end
    local inv = Inventory()
    if not inv or type(inv.Register) ~= "function" or type(inv.GetCount) ~= "function" then
        return false, "FluxUI inventory unavailable"
    end
    if boundInventory and boundInventory ~= inv and type(boundInventory.Unregister) == "function" then
        boundInventory.Unregister(listenerKey)
    end
    boundInventory = inv
    inv.Register(listenerKey, HandleChange, { tier = "light", regions = { "bags", "professions", "mail" } })
    local source = type(inv.GetSource) == "function" and inv.GetSource() or "none"
    if source ~= lastSource then
        lastSource = source
        sourceGeneration = sourceGeneration + 1
        revision = revision + 1
    end
    return true, Status()
end

function Adapter.Stop()
    if boundInventory and type(boundInventory.Unregister) == "function" then
        boundInventory.Unregister(listenerKey)
    end
    boundInventory = nil
    onChange = nil
end

local bagsOnly = {
    bags = true, bank = false, warband = false, equipped = false,
    mail = false, void = false, auctions = false, guild = false,
}

local function CarriedCount(inv, itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then
        return nil, "invalid item ID"
    end
    local ok, count = pcall(inv.GetCount, itemID, bagsOnly)
    if not ok or type(count) ~= "number" or count < 0 then
        return nil, "FluxUI count unavailable"
    end
    return math.floor(count), nil
end

function Adapter.Count(itemID)
    local status = Status()
    if not status.reliable then return nil, status.reason end
    return CarriedCount(Inventory(), itemID)
end

-- Returns a detached map. No direct Syndicator or FluxUI snapshot handles escape.
function Adapter.Snapshot(itemIDs)
    local status = Status()
    if not status.reliable then
        return nil, status.reason, status
    end
    local inv = Inventory()
    local counts = {}
    if type(itemIDs) == "table" then
        for _, itemID in ipairs(itemIDs) do
            local count, reason = CarriedCount(inv, itemID)
            if count == nil then
                return nil, reason, status
            end
            counts[tonumber(itemID)] = count
        end
    elseif type(inv.GetUniqueItems) == "function" then
        local ok, items = pcall(inv.GetUniqueItems, bagsOnly)
        if not ok or type(items) ~= "table" then
            return nil, "FluxUI item snapshot unavailable", status
        end
        for itemID, record in pairs(items) do
            local id = tonumber(itemID)
            local count = record and tonumber(record.count)
            if id and count and count > 0 then
                counts[id] = math.floor(count)
            end
        end
    else
        return nil, "FluxUI item snapshot unavailable", status
    end
    local current = Status()
    if not current.reliable or current.source ~= status.source or current.sourceGeneration ~= status.sourceGeneration
        or current.bagGeneration ~= status.bagGeneration or Inventory() ~= inv then
        return nil, current.reason or "FluxUI inventory changed during capture", current
    end
    return counts, nil, status
end

-- Cached bank stock is informational. The planner never calls this method.
function Adapter.InformationalBankCount(itemID)
    local inv = Inventory()
    if not inv or type(inv.GetCount) ~= "function" then
        return nil
    end
    local ok, count = pcall(inv.GetCount, itemID, {
        bags = false, bank = true, warband = false, equipped = false,
        mail = false, void = false, auctions = false, guild = false,
    })
    return ok and tonumber(count) or nil
end

return Adapter
