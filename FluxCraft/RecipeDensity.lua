local _, FC = ...
local RecipeDensity = {}
FC.RecipeDensity = RecipeDensity

local recipeHeight = 15
local overlays = {"SelectedOverlay", "HighlightOverlay"}

local function isRecipe(node)
    local data = node and node.GetData and node:GetData()
    return data and data.recipeInfo
end

function RecipeDensity.Attach(recipeList)
    local box = recipeList and recipeList.ScrollBox
    local view = box and box.GetView and box:GetView()
    if not view or not view.GetElementExtentCalculator or not view.SetElementExtentCalculator
        or not view.ResizeFrame or not box.ForEachFrame or not box.FullUpdate or not ScrollUtil
        or not ScrollUtil.AddInitializedFrameCallback or not ScrollUtil.AddReleasedFrameCallback then return end

    local heights, owner = {}, {}
    local nativeExtent
    local active = false

    local function compactExtent(index, node)
        local extent = nativeExtent(index, node)
        if isRecipe(node) and type(extent) == "number" then return math.min(recipeHeight, extent) end
        return extent
    end

    local function style(row)
        local height = row:GetHeight()
        for _, key in ipairs(overlays) do
            local texture = row[key]
            if texture then
                local oldHeight = texture:GetHeight()
                if oldHeight > height then
                    local original = heights[row] or {}
                    heights[row] = original
                    original[key] = {oldHeight, height}
                    texture:SetHeight(height)
                end
            end
        end
    end

    local function restore(row)
        local original = heights[row]
        if not original then return end
        for key, sizes in pairs(original) do
            local texture = row[key]
            if texture and texture:GetHeight() == sizes[2] then texture:SetHeight(sizes[1]) end
        end
        heights[row] = nil
    end

    ScrollUtil.AddInitializedFrameCallback(box, function(_, row, node)
        if active and isRecipe(node) then style(row) end
    end, owner)
    ScrollUtil.AddReleasedFrameCallback(box, function(_, row) restore(row) end, owner)

    return function(enable)
        if active == enable then return end
        local calculator = view:GetElementExtentCalculator()
        if enable and type(calculator) ~= "function" then return end
        local first = box.GetDataIndexBegin and box:GetDataIndexBegin()
        local offset, oldHeight
        if first and first > 0 and box.GetExtentUntil and box.GetDerivedScrollOffset and box.ScrollToOffset then
            offset = box:GetDerivedScrollOffset() - box:GetExtentUntil(first)
            oldHeight = box.GetElementExtent and box:GetElementExtent(first)
        end
        if enable then
            nativeExtent = calculator
            view:SetElementExtentCalculator(compactExtent)
        elseif calculator == compactExtent then
            view:SetElementExtentCalculator(nativeExtent)
        end
        active = enable

        -- FullUpdate recalculates the view range but can keep already-visible rows.
        box:ForEachFrame(function(row, node)
            if not isRecipe(node) then return end
            restore(row)
            view:ResizeFrame(box, row, row:GetOrderIndex(), node)
            if active then style(row) end
        end)
        box:FullUpdate(true)
        if offset then
            if offset > 0 and oldHeight and oldHeight > 0 then
                local height = box:GetElementExtent(first)
                if height > 0 then offset = math.min(offset / oldHeight * height, height - 0.01) end
            end
            box:ScrollToOffset(box:GetExtentUntil(first) + offset, true)
        end
    end
end
